package app.smallthingz.dict

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaPlayer
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.net.URLEncoder
import java.util.Properties

data class MediaFile(val file: File,val source:String,val credit:String,val ephemeral:Boolean=false,
    val originalWidth: Long? = null, val originalHeight: Long? = null, val originalMime: String? = null,
    val requiredRasterWidth: Int? = null, val requiredRasterHeight: Int? = null)
internal fun mediaRequestTitle(media: Media, canonicalFile: Boolean): String =
    "File:" + if (canonicalFile) media.file else media.file.removePrefix("File:")
internal data class DecodedMediaBitmap(val bitmap: android.graphics.Bitmap, val width: Int, val height: Int)
internal suspend fun decodeMediaBitmap(file: File, maximumSide: Int = 1600, requiredWidth: Int? = null, requiredHeight: Int? = null): DecodedMediaBitmap = withContext(Dispatchers.IO) {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.absolutePath, bounds)
    require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unsupported image" }
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
    suspend fun get(media:Media,mb:Int,edition:String=""):MediaFile=acquire(media,mb,edition,false,false,null) {}
    internal suspend fun <T> withFile(media:Media,mb:Int,edition:String="",forceRefresh:Boolean=false,canonicalFile:Boolean=false,
        rasterRequest:SvgRasterRequest?=null,action:suspend (MediaFile)->T):T {
        var owned:MediaFile?=null
        var failure:Throwable?=null
        try {
            val loaded=acquire(media,mb,edition,forceRefresh,canonicalFile,rasterRequest) { owned=it }
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
        rasterRequest:SvgRasterRequest?,acquired:(MediaFile)->Unit):MediaFile=withContext(Dispatchers.IO){lock.withLock{
        require(rasterRequest == null || canonicalFile && media.kind == "image")
        val key=mediaKey(media,edition) + (if (canonicalFile) "-canonical" else "") + rasterRequest?.cacheSuffix.orEmpty()
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
                if (variantValid) return@withLock MediaFile(file,props.getProperty("source"),props.getProperty("credit",""),
                    originalWidth=width,originalHeight=height,originalMime=props.getProperty("mime"),requiredRasterWidth=required?.width,requiredRasterHeight=required?.height).also(acquired)
            }}
        var info:JSONObject?=null
        var resolvedHost = "commons.wikimedia.org"
        val title=URLEncoder.encode(mediaRequestTitle(media,canonicalFile),"UTF-8")
        fun query(host: String, width: Int): JSONObject? {
            val variant = rasterRequest?.let { "&iiurlparam=lang${it.language}-${width}px" }.orEmpty()
            val response=JSONObject(metadata("https://$host/w/api.php?action=query&format=json&formatversion=2&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata&iiurlwidth=$width$variant&titles=$title").decodeToString())
            return response.getJSONObject("query").getJSONArray("pages").getJSONObject(0).optJSONArray("imageinfo")?.optJSONObject(0)
        }
        for(host in mediaHosts(edition)) {
            info=query(host, if (rasterRequest == null) 960 else 1)
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
        val url=if (rasterRequest != null) data.getString("thumburl")
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
            if(mb==0||temp.length()>mb.toLong()*1024*1024) return@withLock MediaFile(temp,source,credit,true,originalWidth,originalHeight,originalMime,required?.width,required?.height).also(acquired)
            trimLocked(mb.toLong()*1024*1024-temp.length())
            require(temp.renameTo(file))
            Properties().apply{setProperty("source",source);setProperty("credit",credit)
                originalWidth?.let{setProperty("width",it.toString())};originalHeight?.let{setProperty("height",it.toString())}
                originalMime?.let{setProperty("mime",it)}
                if (rasterRequest != null) {
                    setProperty("svg_language", rasterRequest.language); setProperty("raster_url", url)
                    setProperty("raster_required_width", checkNotNull(required).width.toString())
                    setProperty("raster_required_height", required.height.toString())
                    setProperty("raster_width", checkNotNull(rasterWidth).toString())
                }
            }.let{p->meta.outputStream().use{p.store(it,null)}}
            MediaFile(file,source,credit,originalWidth=originalWidth,originalHeight=originalHeight,originalMime=originalMime,requiredRasterWidth=required?.width,requiredRasterHeight=required?.height).also(acquired)
        } catch(e:Exception){temp.delete();throw e}
    }}
}
object MediaPlayback {
    private var player by mutableStateOf<MediaPlayer?>(null)
    private var generation=0L
    var playing by mutableStateOf<String?>(null);private set
    fun stop(expected:MediaPlayer?=null) {
        if(expected!=null&&player!==expected)return
        generation++;player?.release();player=null;playing=null
    }
    fun begin():Long { SpeechPlayback.stop();stop();return generation }
    fun cancel(request:Long) { if(generation==request)stop() }
    fun isCurrent(owner:MediaPlayer)=player===owner
    suspend fun play(key:String,file:MediaFile,request:Long,onError:(String)->Unit={}):MediaPlayer {
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
            next.setOnPreparedListener{if(player===it)try{it.start()}catch(e:Exception){onError("Pronunciation could not be played.");stop(it)}}
            next.setOnCompletionListener{if(player===it)stop(it)}
            next.setOnErrorListener{failed,_,_->if(player===failed){onError("Pronunciation could not be played.");stop(failed)};true}
            pending=null;player=next;playing=key
            try{next.prepareAsync()}catch(e:Exception){stop(next);throw e}
            return next
        } finally { withContext(NonCancellable+Dispatchers.IO){pending?.release()} }
    }
}
@Composable
fun MediaView(media:Media,settings:AppSettings,showFileName:Boolean=true,edition:String="",showCaption:Boolean=true,cache:MediaCache=LocalInlineImageCache.current ?: MediaCache.get(LocalContext.current),showImage:Boolean=true) {
    val scope=rememberCoroutineScope();val uri=LocalUriHandler.current
    val key=remember(media.kind,media.file,edition){mediaKey(media,edition)}
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
    val sharedState=sharedOwner?.states?.get(media.file)
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
    Column(Modifier.fillMaxWidth().animateContentSize()) {
        if(media.kind=="image"&&showImage&&allowed&&(shownError==null||shownBitmap!=null)) Box(Modifier.fillMaxWidth().padding(top=12.dp).height(220.dp),contentAlignment=Alignment.Center) {
            shownBitmap?.let { Image(it.asImageBitmap(),media.caption.ifBlank{media.file},Modifier.fillMaxSize()) }
            if(shownBitmap==null && shownBusy) CircularProgressIndicator(Modifier.size(24.dp),strokeWidth=2.dp)
        }
        Row(verticalAlignment=Alignment.CenterVertically) {
            if(media.kind!="image" || (showImage&&!allowed&&!showImageRetry)) IconButton(modifier=if(shownBusy)Modifier.semantics{contentDescription=if(media.kind=="image")"Loading image" else "Loading pronunciation"}else Modifier,enabled=allowed&&!shownBusy,onClick={
                if(media.kind=="audio") { if(MediaPlayback.playing==key)MediaPlayback.stop() else {
                    val request=MediaPlayback.begin()
                    audioJob?.cancel()
                    val nextJob=scope.launch(start=CoroutineStart.LAZY){
                        val ownedJob=currentCoroutineContext()[Job]
                        if(audioJob!==ownedJob)return@launch
                        busy=true;error=null;try{cache.withFile(media,settings.mediaCacheMb,edition){loaded->
                        if(audioJob!==ownedJob)throw CancellationException("Audio request superseded")
                        resource=loaded
                        val owner=MediaPlayback.play(key,loaded,request){error=it}
                        try{busy=false;snapshotFlow{MediaPlayback.isCurrent(owner)}.first{!it}}
                        finally{MediaPlayback.stop(owner)}
                    }}catch(e:CancellationException){throw e}catch(e:Exception){if(audioJob===ownedJob)error="Pronunciation could not be played."}finally{MediaPlayback.cancel(request);if(audioJob===ownedJob){audioJob=null;busy=false}}}
                    audioJob=nextJob;nextJob.start()
                } }
                else if(sharedOwner!=null){if(shownError!=null||shownSource==null)sharedOwner.retry(media.file)else uri.openUri(shownSource)}
                else if(error!=null || resource==null) retry++ else resource?.source?.let{uri.openUri(it)}
            }) { if(shownBusy) CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp) else Icon(if(media.kind=="image")Icons.Outlined.Image else if(MediaPlayback.playing==key)Icons.Outlined.Stop else Icons.Outlined.PlayArrow,if(media.kind=="image"){if(shownError!=null) "Retry image" else "Image source"} else if(MediaPlayback.playing==key) "Stop pronunciation" else "Play pronunciation") }
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
