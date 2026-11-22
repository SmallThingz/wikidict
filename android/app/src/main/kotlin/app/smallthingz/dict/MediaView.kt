package app.smallthingz.dict

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaPlayer
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Image
import androidx.compose.foundation.indication
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.collect
import kotlin.math.roundToInt
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.net.URLEncoder
import java.util.Properties

data class MediaFile(val file: File,val source:String,val credit:String,val ephemeral:Boolean=false,
    val originalWidth: Long? = null, val originalHeight: Long? = null, val originalMime: String? = null,
    val requiredRasterWidth: Int? = null, val requiredRasterHeight: Int? = null,
    val exactRasterWidth: Int? = null, val exactRasterHeight: Int? = null)
internal fun mediaRequestTitle(media: Media, canonicalFile: Boolean): String =
    "File:" + if (canonicalFile) media.file else media.file.removePrefix("File:")
internal data class DecodedMediaBitmap(val bitmap: android.graphics.Bitmap, val width: Int, val height: Int)
internal suspend fun decodeMediaBitmap(file: File, maximumSide: Int = 1600, requiredWidth: Int? = null, requiredHeight: Int? = null,
    exactWidth: Int? = null, exactHeight: Int? = null): DecodedMediaBitmap = withContext(Dispatchers.IO) {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.absolutePath, bounds)
    require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unsupported image" }
    require((exactWidth == null) == (exactHeight == null))
    if (exactWidth != null) require(bounds.outWidth == exactWidth && bounds.outHeight == exactHeight &&
        bounds.outMimeType == "image/png") { "Poster PNG differs from authenticated API axes" }
    val side = maximumSide.coerceIn(1, 1600)
    require((requiredWidth == null) == (requiredHeight == null)) { "Incomplete SVG raster demand" }
    if (requiredWidth != null) require(requiredWidth > 0 && checkNotNull(requiredHeight) > 0 &&
        bounds.outWidth >= requiredWidth && bounds.outHeight >= requiredHeight && bounds.outMimeType == "image/png") {
        "SVG raster pixels or MIME do not match the request"
    }
    val options = BitmapFactory.Options().apply { inSampleSize = if (requiredWidth == null)
        maxOf(1, maxOf(bounds.outWidth, bounds.outHeight) / side) else Integer.highestOneBit(maxOf(1,
            minOf(bounds.outWidth / requiredWidth, bounds.outHeight / checkNotNull(requiredHeight)))) }
    if (requiredWidth != null) require(
        ((bounds.outWidth.toLong() + options.inSampleSize - 1) / options.inSampleSize) *
            ((bounds.outHeight.toLong() + options.inSampleSize - 1) / options.inSampleSize) <= 16L * 1024 * 1024
    ) { "SVG raster exceeds the decoder pixel budget" }
    val bitmap = requireNotNull(BitmapFactory.decodeFile(file.absolutePath, options)) { "Unsupported image" }
    if (requiredWidth != null && (bitmap.width < requiredWidth || bitmap.height < checkNotNull(requiredHeight))) { bitmap.recycle(); error("SVG decoder undersized the raster") }
    DecodedMediaBitmap(bitmap, bounds.outWidth, bounds.outHeight)
}
class MediaCache internal constructor(context:Context,
    private val metadata:(String)->ByteArray={Network.read(it,2*1024*1024)},
    private val openMedia:(String)->java.io.InputStream=Network::open,
    directory:File?=null,
    private val deleteTemporary:(File)->Boolean={it.delete()},
) {
    companion object { @Volatile private var instance:MediaCache?=null; fun get(context:Context)=instance?:synchronized(this){instance?:MediaCache(context.applicationContext).also{instance=it}} }
    // Resolve and create storage only inside the existing IO operations.
    private val cacheDirectory by lazy { directory ?: File(context.cacheDir,"media").apply{mkdirs()} }
    private val lock=Mutex()
    suspend fun clear()=withContext(Dispatchers.IO){lock.withLock{cacheDirectory.listFiles()?.forEach{it.delete()};Unit}}
    suspend fun trim(mb:Int)=withContext(Dispatchers.IO){lock.withLock{trimLocked(mb.toLong()*1024*1024)}}
    private fun trimLocked(max:Long,keep:File?=null){val files=cacheDirectory.listFiles().orEmpty().filter{it.extension=="bin"};var total=files.sumOf{it.length()};for(f in files.sortedBy{it.lastModified()}){if(total<=max)break;if(f==keep)continue;total-=f.length();f.delete();File(cacheDirectory,f.nameWithoutExtension+".meta").delete()}}
    suspend fun get(media:Media,mb:Int,edition:String=""):MediaFile=acquire(media,mb,edition,false,false,null,null,null) {}
    internal suspend fun <T> withFile(media:Media,mb:Int,edition:String="",forceRefresh:Boolean=false,canonicalFile:Boolean=false,
        rasterRequest:SvgRasterRequest?=null,posterRequest:StaticPosterRequest?=null,
        blockMediaRequest:FigureBlockMediaRequest?=null,action:suspend (MediaFile)->T):T {
        var owned:MediaFile?=null
        var failure:Throwable?=null
        try {
            val loaded=acquire(media,mb,edition,forceRefresh,canonicalFile,rasterRequest,posterRequest,blockMediaRequest) { owned=it }
            return action(loaded)
        } catch(e:Throwable) { failure=e;throw e }
        finally {
            try { withContext(NonCancellable+Dispatchers.IO) {
                owned?.takeIf{it.ephemeral}?.file?.let { file ->
                    if(file.exists()&&!deleteTemporary(file)) throw java.io.IOException("Could not remove temporary media")
                }
            } } catch(cleanup:Throwable) { if(failure!=null) failure.addSuppressed(cleanup) else throw cleanup }
        }
    }
    private suspend fun acquire(media:Media,mb:Int,edition:String,forceRefresh:Boolean,canonicalFile:Boolean,
        rasterRequest:SvgRasterRequest?,posterRequest:StaticPosterRequest?,blockMediaRequest:FigureBlockMediaRequest?,
        acquired:(MediaFile)->Unit):MediaFile=withContext(Dispatchers.IO){lock.withLock{
        if (blockMediaRequest != null) {
            require(canonicalFile && media.kind == "image" && rasterRequest == null && posterRequest == null)
            return@withLock acquireBlockMedia(media, mb, edition, forceRefresh, blockMediaRequest).also(acquired)
        }
        require(rasterRequest == null || canonicalFile && media.kind == "image")
        require(posterRequest == null || rasterRequest == null && canonicalFile && media.kind == "image" && posterRequest.image.file == media.file)
        val key=mediaKey(media,edition) + (if (canonicalFile) "-canonical" else "") + rasterRequest?.cacheSuffix.orEmpty() + posterRequest?.cacheSuffix.orEmpty()
        val file=File(cacheDirectory,"$key.bin");val meta=File(cacheDirectory,"$key.meta")
        if(!forceRefresh&&file.isFile&&meta.isFile){file.setLastModified(System.currentTimeMillis());val props=Properties().apply{meta.inputStream().use(::load)}
            val width=props.getProperty("width")?.toLongOrNull()?.takeIf{it>0}
            val height=props.getProperty("height")?.toLongOrNull()?.takeIf{it>0}
            if(!canonicalFile||(width!=null&&height!=null)) {
                val required = rasterRequest?.requiredSize(checkNotNull(width), checkNotNull(height), props.getProperty("mime"))
                val variantValid = rasterRequest == null || runCatching {
                    require(props.getProperty("svg_language") == rasterRequest.language)
                    require(props.getProperty("raster_required_width")?.toIntOrNull() == required?.width)
                    require(props.getProperty("raster_required_height")?.toIntOrNull() == required?.height)
                    val bucket = svgRasterWidth(props.getProperty("raster_url"), media.file, rasterRequest.language, checkNotNull(required).width)
                    require(props.getProperty("raster_width")?.toIntOrNull() == bucket)
                }.isSuccess
                val poster = posterRequest?.let { request -> runCatching {
                    request.validateIdentity(props.getProperty("poster_file"), props.getProperty("poster_sha1"),
                        props.getProperty("poster_timestamp"), props.getProperty("mime"), props.getProperty("poster_mediatype"))
                    request.validateRaster(props.getProperty("poster_url"), props.getProperty("poster_mime"),
                        props.getProperty("poster_width").toInt(), props.getProperty("poster_height").toInt())
                }.getOrNull() }
                if (variantValid && (posterRequest == null || poster != null)) return@withLock MediaFile(file,props.getProperty("source"),props.getProperty("credit",""),
                    originalWidth=width,originalHeight=height,originalMime=props.getProperty("mime"),
                    requiredRasterWidth=poster?.width ?: required?.width,requiredRasterHeight=poster?.height ?: required?.height,
                    exactRasterWidth=poster?.width,exactRasterHeight=poster?.height).also(acquired)
            }}
        var info:JSONObject?=null
        var resolvedHost = "commons.wikimedia.org"
        val title=URLEncoder.encode(mediaRequestTitle(media,canonicalFile),"UTF-8")
        fun query(host: String, width: Int): JSONObject? {
            val variant = rasterRequest?.let { "&iiurlparam=lang${it.language}-${width}px" }.orEmpty()
            val identity = if (posterRequest == null) "" else "%7Csha1%7Ctimestamp%7Cmediatype%7Ccanonicaltitle"
            val response=JSONObject(metadata("https://$host/w/api.php?action=query&format=json&formatversion=2&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata$identity&iiurlwidth=$width$variant&titles=$title").decodeToString())
            return response.getJSONObject("query").getJSONArray("pages").getJSONObject(0).optJSONArray("imageinfo")?.optJSONObject(0)
        }
        for(host in mediaHosts(edition)) {
            info=query(host, posterRequest?.requestWidth ?: if (rasterRequest == null) 960 else 1)
            if(info!=null){resolvedHost=host;break}
        }
        val initial=info?:error("Media is unavailable")
        val required = rasterRequest?.requiredSize(initial.optLong("width"), initial.optLong("height"), initial.optString("mime"))
        val requestWidth = required?.naturalRequestWidth(initial.optLong("width"), initial.optLong("height"))
        val data = if (requestWidth != null && requestWidth != 1) {
            val exact = query(resolvedHost, requestWidth) ?: error("SVG raster is unavailable")
            require(exact.optLong("width") == initial.optLong("width") && exact.optLong("height") == initial.optLong("height") &&
                exact.optString("mime") == initial.optString("mime")) { "SVG source dimensions changed" }
            exact
        } else initial
        val url=if (rasterRequest != null || posterRequest != null) data.getString("thumburl")
            else if(media.kind=="image")data.optString("thumburl").ifBlank{data.getString("url")}else data.getString("url")
        val rasterWidth = rasterRequest?.let {
            val demand = checkNotNull(required)
            require(data.optString("thumbmime") == "image/png" && data.optInt("thumbwidth") >= demand.width && data.optInt("thumbheight") >= demand.height) {
                "SVG response is not the requested raster"
            }
            svgRasterWidth(url, media.file, it.language, demand.width).also { bucket ->
                require(bucket >= data.optInt("thumbwidth")) { "SVG response width disagrees with its raster" }
            }
        }
        val ext=data.optJSONObject("extmetadata")
        val poster = posterRequest?.let { request ->
            request.validateIdentity(data.getString("canonicaltitle"), data.getString("sha1"), data.getString("timestamp"),
                data.getString("mime"), data.getString("mediatype"))
            request.validateRaster(url, data.getString("thumbmime"), data.getInt("thumbwidth"), data.getInt("thumbheight"))
        }
        val rasterDemand = poster ?: required
        val originalWidth=data.optLong("width").takeIf{it>0}
        val originalHeight=data.optLong("height").takeIf{it>0}
        val originalMime=data.optString("mime").takeIf{it.isNotBlank()}
        val artist=ext?.optJSONObject("Artist")?.optString("value").orEmpty().replace(Regex("<[^>]*>"),"").take(200)
        val licence=ext?.optJSONObject("LicenseShortName")?.optString("value").orEmpty()
        val source=data.optString("descriptionurl").ifBlank{"https://$resolvedHost/wiki/"+URLEncoder.encode(mediaRequestTitle(media,canonicalFile),"UTF-8").replace("+","%20")}
        val temp=File.createTempFile("$key-",".part",cacheDirectory)
        try {
            openMedia(url).use{input->temp.outputStream().use{out->val b=ByteArray(64*1024);var total=0L;while(true){currentCoroutineContext().ensureActive();val n=input.read(b);if(n<0)break;total+=n;require(total<=50L*1024*1024){"Media file is too large"};out.write(b,0,n)}}}
            val credit=listOf(artist,licence).filter{it.isNotBlank()}.joinToString(" · ")
            if(mb==0||temp.length()>mb.toLong()*1024*1024) return@withLock MediaFile(temp,source,credit,true,originalWidth,originalHeight,originalMime,
                rasterDemand?.width,rasterDemand?.height,poster?.width,poster?.height).also(acquired)
            trimLocked(mb.toLong()*1024*1024-temp.length())
            require(temp.renameTo(file))
            Properties().apply{setProperty("source",source);setProperty("credit",credit)
                originalWidth?.let{setProperty("width",it.toString())};originalHeight?.let{setProperty("height",it.toString())}
                originalMime?.let{setProperty("mime",it)}
                if (poster != null) {
                    setProperty("poster_file", data.getString("canonicaltitle")); setProperty("poster_sha1", data.getString("sha1"))
                    setProperty("poster_timestamp", data.getString("timestamp")); setProperty("poster_mediatype", data.getString("mediatype"))
                    setProperty("poster_url", url); setProperty("poster_mime", data.getString("thumbmime"))
                    setProperty("poster_width", poster.width.toString()); setProperty("poster_height", poster.height.toString())
                }
                if (rasterRequest != null) {
                    setProperty("svg_language", rasterRequest.language); setProperty("raster_url", url)
                    setProperty("raster_required_width", checkNotNull(required).width.toString())
                    setProperty("raster_required_height", required.height.toString())
                    setProperty("raster_width", checkNotNull(rasterWidth).toString())
                }
            }.let{p->meta.outputStream().use{p.store(it,null)}}
            MediaFile(file,source,credit,originalWidth=originalWidth,originalHeight=originalHeight,originalMime=originalMime,
                requiredRasterWidth=rasterDemand?.width,requiredRasterHeight=rasterDemand?.height,
                exactRasterWidth=poster?.width,exactRasterHeight=poster?.height).also(acquired)
        } catch(e:Exception){temp.delete();throw e}
    }}

    /** The compiled block occurrence selects its exact source PNG; imageinfo cannot replace it. */
    private suspend fun acquireBlockMedia(media: Media, mb: Int, edition: String, forceRefresh: Boolean,
        request: FigureBlockMediaRequest): MediaFile {
        val key = mediaKey(media, edition) + request.cacheSuffix
        val file = File(cacheDirectory, "$key.bin")
        if (!forceRefresh && file.isFile) {
            val valid = try { request.verifyBody(file); true }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { false }
            if (valid) { file.setLastModified(System.currentTimeMillis()); return request.resource(file) }
        }
        val temp = File.createTempFile("$key-", ".part", cacheDirectory)
        try {
            openMedia(request.identity.url).use { input -> temp.outputStream().use { out ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    require(total <= 50L * 1024 * 1024) { "Source Figure raster is too large" }
                    out.write(buffer, 0, count)
                }
            } }
            request.verifyBody(temp)
            if (mb == 0 || temp.length() > mb.toLong() * 1024 * 1024) return request.resource(temp, true)
            trimLocked(mb.toLong() * 1024 * 1024 - temp.length())
            require(temp.renameTo(file)) { "Could not store source Figure raster" }
            return request.resource(file)
        } catch (failure: Exception) { temp.delete(); throw failure }
    }
}
internal data class AudioPlaybackProgress(val positionMillis: Int, val durationMillis: Int, val pendingSeekMillis: Int?)

object MediaPlayback {
    private var player by mutableStateOf<MediaPlayer?>(null)
    private var generation=0L
    private var playingOccurrence by mutableStateOf<Any?>(null)
    private var preparedPlayer: MediaPlayer? = null
    private var preparedDuration = 0
    private var seekingTo: Int? = null
    private var queuedSeek: Int? = null
    private var playbackError: ((String) -> Unit)? = null
    var playing by mutableStateOf<String?>(null);private set
    fun stop(expected:MediaPlayer?=null) {
        if(expected!=null&&player!==expected)return
        generation++;player?.release();player=null;playing=null;playingOccurrence=null
        preparedPlayer=null;preparedDuration=0;seekingTo=null;queuedSeek=null;playbackError=null
    }
    fun begin():Long { SpeechPlayback.stop();stop();return generation }
    fun cancel(request:Long) { if(generation==request)stop() }
    fun isCurrent(owner:MediaPlayer)=player===owner
    fun isPlaying(key:String,occurrence:Any?=null)=playing==key&&(occurrence==null||playingOccurrence===occurrence)
    private fun fail(owner: MediaPlayer) {
        if (player !== owner) return
        playbackError?.invoke("Pronunciation could not be played.")
        stop(owner)
    }
    internal fun progress(key: String, occurrence: Any): AudioPlaybackProgress? {
        val current = player ?: return null
        if (!isPlaying(key, occurrence) || preparedPlayer !== current || preparedDuration <= 0) return null
        return try { AudioPlaybackProgress(current.currentPosition.coerceIn(0, preparedDuration), preparedDuration,
            queuedSeek ?: seekingTo) } catch (_: Exception) { fail(current); null }
    }
    internal fun seek(key: String, occurrence: Any, positionMillis: Int): Boolean {
        val current = player ?: return false
        if (!isPlaying(key, occurrence) || preparedPlayer !== current || preparedDuration <= 0) return false
        val target = positionMillis.coerceIn(0, preparedDuration)
        if (seekingTo != null) { queuedSeek = target; return true }
        return seekCurrent(current, target)
    }
    private fun seekCurrent(current: MediaPlayer, target: Int): Boolean = try {
        seekingTo = target
        current.seekTo(target.toLong(), MediaPlayer.SEEK_CLOSEST)
        true
    } catch (_: Exception) { fail(current); false }
    suspend fun play(key:String,file:MediaFile,request:Long,occurrence:Any?=null,onError:(String)->Unit={}):MediaPlayer {
        var pending:MediaPlayer?=null
        try {
            if(request!=generation)throw CancellationException("Audio request superseded")
            withContext(Dispatchers.IO) {
                pending=MediaPlayer()
                pending!!.setDataSource(file.file.absolutePath)
            }
            currentCoroutineContext().ensureActive()
            if(request!=generation)throw CancellationException("Audio request superseded")
            val next=checkNotNull(pending)
            next.setOnPreparedListener{if(player===it)try{
                if(occurrence!=null){preparedPlayer=it;preparedDuration=it.duration.coerceAtLeast(0)}
                it.start()
            }catch(e:Exception){onError("Pronunciation could not be played.");stop(it)}}
            next.setOnCompletionListener{if(player===it)stop(it)}
            next.setOnErrorListener{failed,_,_->if(player===failed){onError("Pronunciation could not be played.");stop(failed)};true}
            if(occurrence!=null)next.setOnSeekCompleteListener{current->
                if(player===current&&preparedPlayer===current){
                    val queued=queuedSeek;queuedSeek=null
                    if(queued!=null&&queued!=seekingTo)seekCurrent(current,queued)else seekingTo=null
                }
            }
            pending=null;player=next;playing=key;playingOccurrence=occurrence;playbackError=onError
            try{next.prepareAsync()}catch(e:Exception){stop(next);throw e}
            return next
        } finally { withContext(NonCancellable+Dispatchers.IO){pending?.release()} }
    }
}

// Replaying the real effective focus identity lets a replacement stock indication
// observe an already-focused control. The stock state-layer precedence is retained.
internal class PlaybackFocusInteractions : androidx.compose.foundation.interaction.InteractionSource {
    private val states = mutableListOf<androidx.compose.foundation.interaction.Interaction>()
    private val active = kotlinx.coroutines.flow.MutableStateFlow<androidx.compose.foundation.interaction.FocusInteraction.Focus?>(null)
    override val interactions: kotlinx.coroutines.flow.Flow<androidx.compose.foundation.interaction.Interaction> = kotlinx.coroutines.flow.flow {
        var previous: androidx.compose.foundation.interaction.FocusInteraction.Focus? = null
        active.collect { next ->
            previous?.let { emit(androidx.compose.foundation.interaction.FocusInteraction.Unfocus(it)) }
            next?.let { emit(it) }
            previous = next
        }
    }
    fun accept(interaction: androidx.compose.foundation.interaction.Interaction) {
        when (interaction) {
            is androidx.compose.foundation.interaction.FocusInteraction.Focus,
            is androidx.compose.foundation.interaction.HoverInteraction.Enter,
            is androidx.compose.foundation.interaction.DragInteraction.Start -> states.add(interaction)
            is androidx.compose.foundation.interaction.FocusInteraction.Unfocus -> states.remove(interaction.focus)
            is androidx.compose.foundation.interaction.HoverInteraction.Exit -> states.remove(interaction.enter)
            is androidx.compose.foundation.interaction.DragInteraction.Stop -> states.remove(interaction.start)
            is androidx.compose.foundation.interaction.DragInteraction.Cancel -> states.remove(interaction.start)
            else -> return
        }
        active.value = states.lastOrNull() as? androidx.compose.foundation.interaction.FocusInteraction.Focus
    }
    fun clear() { states.clear(); active.value = null }
}

@Composable
private fun AudioControlLayout(control: AudioControl, containingWidthPixels: (() -> Float)?, inputModifier: Modifier, overflowOwned: Boolean, density: Float,
    bodyPixels: Float, onUnavailable: (String?) -> Unit, content: @Composable () -> Unit) {
    val report by rememberUpdatedState(onUnavailable)
    val originalContainingWidth by rememberUpdatedState(containingWidthPixels)
    val policy = remember(control.width, control.height, density, bodyPixels, overflowOwned) {
        object : androidx.compose.ui.layout.MeasurePolicy {
            private fun resolvedWidth(containing: Float) = audioControlWidthPixels(control, containing, density, bodyPixels)
                ?.let { kotlin.math.ceil(it).toInt() }
            private fun resolvedHeight() = audioControlHeightPixels(control, density, bodyPixels)
                ?.let { kotlin.math.ceil(it).toInt() }
            override fun androidx.compose.ui.layout.MeasureScope.measure(measurables: List<androidx.compose.ui.layout.Measurable>,
                constraints: androidx.compose.ui.unit.Constraints): androidx.compose.ui.layout.MeasureResult {
                val childConstraints = try {
                    val containing = originalContainingWidth?.invoke() ?: if (constraints.hasBoundedWidth) constraints.maxWidth.toFloat() else Float.NaN
                    val exactWidth = audioControlWidthPixels(control, containing, density, bodyPixels)
                    val width = exactWidth?.let { kotlin.math.ceil(it).toInt() }
                    val height = resolvedHeight()
                    if (!overflowOwned && ((exactWidth != null && containing.isFinite() && exactWidth > containing) ||
                        (width != null && constraints.hasBoundedWidth && width > constraints.maxWidth) ||
                        (height != null && constraints.hasBoundedHeight && height > constraints.maxHeight)))
                        throw UnsupportedFloatLayout("Audio controls exceed their owned layout bounds")
                    val fixed = try { androidx.compose.ui.unit.Constraints(
                        minWidth = width ?: 0, maxWidth = width ?: constraints.maxWidth,
                        minHeight = height ?: 0, maxHeight = height ?: constraints.maxHeight)
                    } catch (_: IllegalArgumentException) {
                        throw UnsupportedFloatLayout("Audio control dimensions exceed Compose allocation")
                    }
                    report(null)
                    fixed
                } catch (failure: UnsupportedFloatLayout) {
                    report(failure.message ?: "Audio control layout is unavailable")
                    constraints.copy(minWidth = 0, minHeight = 0)
                }
                val child = measurables.single().measure(childConstraints)
                return layout(constraints.constrainWidth(child.width), constraints.constrainHeight(child.height)) {
                    child.placeRelative(0, 0)
                }
            }
            private fun intrinsicWidth(child: androidx.compose.ui.layout.IntrinsicMeasurable, height: Int, maximum: Boolean): Int {
                // Intrinsic queries carry no fresh containing-width lease. Never reuse
                // the previous measured C for a percentage contribution.
                val width = resolvedWidth(Float.NaN)
                if (width != null) return width
                val measuredHeight = resolvedHeight() ?: height
                return if (maximum) child.maxIntrinsicWidth(measuredHeight) else child.minIntrinsicWidth(measuredHeight)
            }
            override fun androidx.compose.ui.layout.IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<androidx.compose.ui.layout.IntrinsicMeasurable>, height: Int) =
                intrinsicWidth(measurables.single(), height, false)
            override fun androidx.compose.ui.layout.IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<androidx.compose.ui.layout.IntrinsicMeasurable>, height: Int) =
                intrinsicWidth(measurables.single(), height, true)
            override fun androidx.compose.ui.layout.IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<androidx.compose.ui.layout.IntrinsicMeasurable>, width: Int): Int =
                resolvedHeight() ?: measurables.single().minIntrinsicHeight(resolvedWidth(Float.NaN) ?: width)
            override fun androidx.compose.ui.layout.IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<androidx.compose.ui.layout.IntrinsicMeasurable>, width: Int): Int =
                resolvedHeight() ?: measurables.single().maxIntrinsicHeight(resolvedWidth(Float.NaN) ?: width)
        }
    }
    androidx.compose.ui.layout.Layout(content = content, modifier = inputModifier, measurePolicy = policy)
}

@Composable
private fun rememberPlaybackFocusInteractions(interactions: androidx.compose.foundation.interaction.MutableInteractionSource): PlaybackFocusInteractions {
    val focus = remember(interactions) { PlaybackFocusInteractions() }
    LaunchedEffect(interactions, focus) {
        try { interactions.interactions.collect(focus::accept) }
        finally { focus.clear() }
    }
    return focus
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlaybackFocusLayer(focus: AudioControlFocusPaint?, interactions: PlaybackFocusInteractions,
    inherited: RippleConfiguration?, automaticWhenNull: Boolean = false, content: @Composable (Modifier) -> Unit) {
    val paint = (focus?.mode == AudioControlFocusMode.UaAuto || (focus == null && automaticWhenNull && inherited != null)) &&
        focus?.color != FigureColor.Transparent
    val color = when (val source = focus?.color) {
        null -> inherited?.color ?: Color.Unspecified
        FigureColor.Transparent -> Color.Transparent
        is FigureColor.Rgb -> Color(checkNotNull(canonicalColorArgb(source.value)).toInt())
        else -> error("Unsupported audio focus color")
    }
    val alpha = inherited?.rippleAlpha ?: RippleDefaults.RippleAlpha
    // Replace only the indication subscription. The stock thumb/hover and button
    // nodes stay in place when the focused policy changes.
    val events = interactions.interactions
    val replay = remember(interactions, color, alpha, paint) {
        object : androidx.compose.foundation.interaction.InteractionSource {
            override val interactions = events
        }
    }
    CompositionLocalProvider(LocalRippleConfiguration provides RippleConfiguration(color, alpha)) {
        content(if (paint) Modifier.indication(replay, ripple()) else Modifier)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MediaPlaybackButton(focus: AudioControlFocusPaint?, modifier: Modifier, enabled: Boolean,
    onClick: () -> Unit, content: @Composable () -> Unit) {
    val interactions = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    val focusInteractions = rememberPlaybackFocusInteractions(interactions)
    val inherited = LocalRippleConfiguration.current
    val alpha = inherited?.rippleAlpha ?: RippleDefaults.RippleAlpha
    val ordinary = inherited?.let {
        RippleConfiguration(it.color, androidx.compose.material.ripple.RippleAlpha(
            draggedAlpha = alpha.draggedAlpha, focusedAlpha = 0f,
            hoveredAlpha = alpha.hoveredAlpha, pressedAlpha = alpha.pressedAlpha))
    }
    CompositionLocalProvider(LocalRippleConfiguration provides ordinary) {
        IconButton(onClick = onClick, modifier = modifier, enabled = enabled, interactionSource = interactions) {
            // Use the real stock inner allocation and shape clip, not a second target.
            PlaybackFocusLayer(focus, focusInteractions, inherited, automaticWhenNull = true) { indication ->
                Box(Modifier.fillMaxSize().then(indication), contentAlignment = Alignment.Center) { content() }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AudioPlaybackControls(control: AudioControl, direction: String, containingWidthPixels: (() -> Float)?, containingWidthModifier: Modifier, overflowOwned: Boolean, enabled: Boolean, busy: Boolean,
    progress: AudioPlaybackProgress?, onClick: () -> Unit, onSeek: (Int) -> Unit,
    buttonContent: @Composable () -> Unit) {
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val interactions = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    val focusInteractions = rememberPlaybackFocusInteractions(interactions)
    val inherited = LocalRippleConfiguration.current
    val inheritedDirection = LocalLayoutDirection.current
    val effectiveFocus = control.focus ?: AudioControlFocusPaint(AudioControlFocusMode.UaAuto)
    var scrub by remember { mutableStateOf<Float?>(null) }
    val seekEnabled = enabled && !busy && progress != null
    LaunchedEffect(seekEnabled) { if (!seekEnabled) scrub = null }
    var unavailable by remember { mutableStateOf<String?>(null) }
    val directionValue = when (direction) {
        "ltr" -> androidx.compose.ui.unit.LayoutDirection.Ltr
        "rtl" -> androidx.compose.ui.unit.LayoutDirection.Rtl
        else -> inheritedDirection
    }
    val directionUnavailable = direction !in listOf("", "ltr", "rtl")
    val minimum = if (control.height == null || unavailable != null || directionUnavailable) LocalMinimumInteractiveComponentSize.current else 0.dp
    CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides minimum,
        LocalLayoutDirection provides directionValue) {
        Column {
            val reason = if (directionUnavailable) "Audio control direction is unresolved" else unavailable
            reason?.let { ReaderLayoutUnavailable(it) }
            AudioControlLayout(if (directionUnavailable) control.copy(width = null, height = null) else control,
                containingWidthPixels, containingWidthModifier, overflowOwned, density.density, bodyPixels, { unavailable = it }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                MediaPlaybackButton(effectiveFocus,
                    if (busy) Modifier.semantics { contentDescription = "Loading pronunciation" } else Modifier,
                    enabled && !busy, onClick, buttonContent)
                val position = scrub ?: (progress?.pendingSeekMillis ?: progress?.positionMillis ?: 0).toFloat()
                val duration = progress?.durationMillis ?: 0
                Slider(value = position, onValueChange = { if (seekEnabled) scrub = it },
                    onValueChangeFinished = { if (seekEnabled) scrub?.let { onSeek(it.roundToInt()) }; scrub = null },
                    enabled = seekEnabled, valueRange = 0f..duration.coerceAtLeast(1).toFloat(),
                    interactionSource = interactions,
                    modifier = Modifier.weight(1f).semantics {
                        contentDescription = "Pronunciation position"
                        stateDescription = if (progress == null) "Not playing" else
                            "${(position / 1000).toInt()} of ${duration / 1000} seconds"
                    },
                    thumb = {
                        // This new media control selects the toolkit's automatic ripple
                        // on the stock thumb; the thumb remains part of Slider's one target.
                        PlaybackFocusLayer(effectiveFocus, focusInteractions, inherited) { indication ->
                            SliderDefaults.Thumb(interactions, modifier = indication, enabled = seekEnabled)
                        }
                    })
            }
            }
        }
    }
}

@Composable
fun MediaView(media:Media,settings:AppSettings,showFileName:Boolean=true,edition:String="",showCaption:Boolean=true,cache:MediaCache=LocalInlineImageCache.current ?: MediaCache.get(LocalContext.current),showImage:Boolean=true,audioControl:AudioControl?=null,audioDirection:String="",audioContainingWidthPixels:(()->Float)?=null,audioContainingWidthModifier:Modifier=Modifier,audioOverflowOwned:Boolean=false) {
    require(audioControl==null||media.kind=="audio")
    val scope=rememberCoroutineScope();val uri=LocalUriHandler.current
    val key=remember(media.kind,media.file,edition){mediaKey(media,edition)}
    val rememberedPlaybackOccurrence=remember(key){Any()}
    val playbackOccurrence=rememberedPlaybackOccurrence.takeIf{audioControl!=null}
    var resource by remember(key){mutableStateOf<MediaFile?>(null)}
    var error by remember(key){mutableStateOf<String?>(null)}
    var retry by remember(key){mutableIntStateOf(0)}
    var attemptedRetry by remember(key){mutableIntStateOf(0)}
    var busy by remember(key){mutableStateOf(false)}
    var bitmap by remember(key){mutableStateOf<android.graphics.Bitmap?>(null)}
    var audioJob by remember(key){mutableStateOf<Job?>(null)}
    var imageRequest by remember(key){mutableIntStateOf(0)}
    val allowed=if(media.kind=="image")settings.allowImages else settings.allowAudio
    val sharedOwner=LocalInlineImageOwner.current?.takeIf{media.kind=="image"&&it.owns(media.file)}
    val sharedState=sharedOwner?.let { owner -> owner.catalogueKey(media.file)?.let(owner.states::get) }
    val sharedReady=sharedState as? InlineImageAssetState.Ready
    LaunchedEffect(sharedOwner,media.file,showImage){if(showImage)sharedOwner?.ensure(media.file)}
    LaunchedEffect(key,allowed,settings.mediaCacheMb,retry,sharedOwner,showImage){
        if(media.kind=="image"&&!showImage){busy=false;return@LaunchedEffect}
        if(sharedOwner!=null){audioJob?.cancel();busy=false;return@LaunchedEffect}
        val request=++imageRequest
        // A retry must bypass bytes that already failed image decoding.
        val forceRefresh=retry!=attemptedRetry
        attemptedRetry=retry
        if(!allowed){audioJob?.cancel();busy=false;return@LaunchedEffect}
        if(media.kind=="image"&&allowed){busy=true;error=null;try{cache.withFile(media,settings.mediaCacheMb,edition,forceRefresh=forceRefresh){loaded->resource=loaded
            bitmap=decodeMediaBitmap(loaded.file).bitmap
        }}catch(e:CancellationException){throw e}catch(e:Exception){if(imageRequest==request)error=e.message}finally{if(imageRequest==request)busy=false}}
    }
    DisposableEffect(key){onDispose{audioJob?.cancel()}}
    val shownBitmap=if(sharedOwner==null)bitmap else sharedReady?.decoded?.bitmap
    val shownError=if(sharedOwner==null)error else if(sharedState==InlineImageAssetState.Failed)"Image unavailable" else null
    val shownBusy=if(sharedOwner==null)busy else allowed&&(sharedState==null||sharedState==InlineImageAssetState.Loading)
    val shownSource=if(sharedOwner==null)resource?.source else sharedReady?.source
    val shownCredit=if(sharedOwner==null)resource?.credit else sharedReady?.credit
    val showImageRetry=media.kind=="image"&&showImage&&shownError!=null
    val playbackActive=MediaPlayback.isPlaying(key,playbackOccurrence)
    val progressState=if(audioControl!=null)remember(key,playbackOccurrence){mutableStateOf<AudioPlaybackProgress?>(null)}else null
    if(progressState!=null)LaunchedEffect(key,playbackOccurrence,playbackActive){
        progressState.value=null
        if(playbackActive){
            val occurrence=checkNotNull(playbackOccurrence)
            while(MediaPlayback.isPlaying(key,occurrence)){
                progressState.value=MediaPlayback.progress(key,occurrence)
                delay(200)
            }
        }
    }
    val onMediaClick:()->Unit={
                if(media.kind=="audio") { if(MediaPlayback.isPlaying(key,playbackOccurrence))MediaPlayback.stop() else {
                    val request=MediaPlayback.begin()
                    audioJob?.cancel()
                    val nextJob=scope.launch(start=CoroutineStart.LAZY){
                        val ownedJob=currentCoroutineContext()[Job]
                        if(audioJob!==ownedJob)return@launch
                        busy=true;error=null;try{cache.withFile(media,settings.mediaCacheMb,edition){loaded->
                        if(audioJob!==ownedJob)throw CancellationException("Audio request superseded")
                        resource=loaded
                        val owner=MediaPlayback.play(key,loaded,request,playbackOccurrence){error=it}
                        try{busy=false;snapshotFlow{MediaPlayback.isCurrent(owner)}.first{!it}}
                        finally{MediaPlayback.stop(owner)}
                    }}catch(e:CancellationException){throw e}catch(e:Exception){if(audioJob===ownedJob)error="Pronunciation could not be played."}finally{MediaPlayback.cancel(request);if(audioJob===ownedJob){audioJob=null;busy=false}}}
                    audioJob=nextJob;nextJob.start()
                } }
                else if(sharedOwner!=null){if(shownError!=null||shownSource==null)sharedOwner.retry(media.file)else uri.openUri(shownSource)}
                else if(error!=null || resource==null) retry++ else resource?.source?.let{uri.openUri(it)}
            }
    Column(Modifier.fillMaxWidth().animateContentSize()) {
        if(media.kind=="image"&&showImage&&allowed&&(shownError==null||shownBitmap!=null)) Box(Modifier.fillMaxWidth().padding(top=12.dp).height(220.dp),contentAlignment=Alignment.Center) {
            shownBitmap?.let { Image(it.asImageBitmap(),media.caption.ifBlank{media.file},Modifier.fillMaxSize()) }
            if(shownBitmap==null && shownBusy) CircularProgressIndicator(Modifier.size(24.dp),strokeWidth=2.dp)
        }
        if(audioControl!=null){
            AudioPlaybackControls(audioControl,audioDirection,audioContainingWidthPixels,audioContainingWidthModifier,audioOverflowOwned,allowed,shownBusy,
                progressState?.value?.takeIf{playbackActive},onMediaClick,{position->
                    val occurrence=checkNotNull(playbackOccurrence)
                    if(MediaPlayback.seek(key,occurrence,position))progressState?.value=MediaPlayback.progress(key,occurrence)
                }) {
                if(shownBusy)CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp)
                else Icon(if(playbackActive)Icons.Outlined.Stop else Icons.Outlined.PlayArrow,
                    if(playbackActive)"Stop pronunciation" else "Play pronunciation")
            }
            Row(verticalAlignment=Alignment.CenterVertically){
                Column(Modifier.weight(1f)){
                    val caption=media.caption.takeUnless{it==media.file}.orEmpty()
                    if(showCaption&&(caption.isNotBlank()||showFileName))Text(caption.ifBlank{media.file.substringBeforeLast('.').replace('_',' ')},style=MaterialTheme.typography.bodyMedium)
                    shownError?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.error)}
                    shownCredit?.takeIf{it.isNotBlank()}?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
                }
                shownSource?.let{source->IconButton(onClick={uri.openUri(source)}){Icon(Icons.Outlined.OpenInNew,"Source and licence",Modifier.size(17.dp))}}
            }
        }else Row(verticalAlignment=Alignment.CenterVertically) {
            if(media.kind!="image" || (showImage&&!allowed&&!showImageRetry)) IconButton(modifier=if(shownBusy)Modifier.semantics{contentDescription=if(media.kind=="image")"Loading image" else "Loading pronunciation"}else Modifier,enabled=allowed&&!shownBusy,onClick=onMediaClick
            ) { if(shownBusy) CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp) else Icon(if(media.kind=="image")Icons.Outlined.Image else if(MediaPlayback.isPlaying(key,playbackOccurrence))Icons.Outlined.Stop else Icons.Outlined.PlayArrow,if(media.kind=="image"){if(shownError!=null) "Retry image" else "Image source"} else if(MediaPlayback.isPlaying(key,playbackOccurrence)) "Stop pronunciation" else "Play pronunciation") }
            Column(Modifier.weight(1f)) {
                val caption=media.caption.takeUnless{it==media.file}.orEmpty()
                if(showCaption && (caption.isNotBlank() || showFileName)) Text(caption.ifBlank{media.file.substringBeforeLast('.').replace('_',' ')},style=MaterialTheme.typography.bodyMedium)
                shownError?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.error)}
                if(showImageRetry) TextButton(
                    onClick={if(sharedOwner!=null)sharedOwner.retry(media.file)else retry++},
                    enabled=allowed&&!shownBusy,
                    modifier=Modifier.semantics{contentDescription=if(shownBusy)"Loading image" else "Retry image"},
                ) {
                    if(shownBusy) CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp)
                    else Icon(Icons.Outlined.Refresh,contentDescription=null,modifier=Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Retry image")
                }
                shownCredit?.takeIf{it.isNotBlank()}?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
            }
            shownSource?.let{source->IconButton(onClick={uri.openUri(source)}){Icon(Icons.Outlined.OpenInNew,"Source and licence",Modifier.size(17.dp))}}
        }
    }
}
