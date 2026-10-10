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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.net.URLEncoder
import java.util.Properties

data class MediaFile(val file: File,val source:String,val credit:String,val ephemeral:Boolean=false)
class MediaCache internal constructor(context:Context,
    private val metadata:(String)->ByteArray={Network.read(it,2*1024*1024)},
    private val openMedia:(String)->java.io.InputStream=Network::open,
    private val directory:File=File(context.cacheDir,"media").apply{mkdirs()},
) {
    companion object { @Volatile private var instance:MediaCache?=null; fun get(context:Context)=instance?:synchronized(this){instance?:MediaCache(context.applicationContext).also{instance=it}} }
    private val lock=Mutex()
    suspend fun clear()=withContext(Dispatchers.IO){lock.withLock{directory.listFiles()?.forEach{it.delete()};Unit}}
    suspend fun trim(mb:Int)=withContext(Dispatchers.IO){lock.withLock{trimLocked(mb.toLong()*1024*1024)}}
    private fun trimLocked(max:Long,keep:File?=null){val files=directory.listFiles().orEmpty().filter{it.extension=="bin"};var total=files.sumOf{it.length()};for(f in files.sortedBy{it.lastModified()}){if(total<=max)break;if(f==keep)continue;total-=f.length();f.delete();File(directory,f.nameWithoutExtension+".meta").delete()}}
    suspend fun get(media:Media,mb:Int,edition:String=""):MediaFile=withContext(Dispatchers.IO){lock.withLock{
        val key=mediaKey(media,edition)
        val file=File(directory,"$key.bin");val meta=File(directory,"$key.meta")
        if(file.isFile&&meta.isFile){file.setLastModified(System.currentTimeMillis());val props=Properties().apply{meta.inputStream().use(::load)};return@withLock MediaFile(file,props.getProperty("source"),props.getProperty("credit",""))}
        var info:JSONObject?=null
        var resolvedHost = "commons.wikimedia.org"
        for(host in mediaHosts(edition)) {
            val title=URLEncoder.encode("File:"+media.file.removePrefix("File:"),"UTF-8")
            val response=JSONObject(metadata("https://$host/w/api.php?action=query&format=json&formatversion=2&prop=imageinfo&iiprop=url%7Cextmetadata&iiurlwidth=960&titles=$title").decodeToString())
            info=response.getJSONObject("query").getJSONArray("pages").getJSONObject(0).optJSONArray("imageinfo")?.optJSONObject(0)
            if(info!=null){resolvedHost=host;break}
        }
        val data=info?:error("Media is unavailable")
        val url=if(media.kind=="image")data.optString("thumburl").ifBlank{data.getString("url")}else data.getString("url")
        val ext=data.optJSONObject("extmetadata")
        val artist=ext?.optJSONObject("Artist")?.optString("value").orEmpty().replace(Regex("<[^>]*>"),"").take(200)
        val licence=ext?.optJSONObject("LicenseShortName")?.optString("value").orEmpty()
        val source=data.optString("descriptionurl").ifBlank{"https://$resolvedHost/wiki/"+URLEncoder.encode("File:"+media.file.removePrefix("File:"),"UTF-8").replace("+","%20")}
        val temp=File(directory,"$key.part")
        try {
            openMedia(url).use{input->temp.outputStream().use{out->val b=ByteArray(64*1024);var total=0L;while(true){currentCoroutineContext().ensureActive();val n=input.read(b);if(n<0)break;total+=n;require(total<=50L*1024*1024){"Media file is too large"};out.write(b,0,n)}}}
            val credit=listOf(artist,licence).filter{it.isNotBlank()}.joinToString(" · ")
            if(mb==0||temp.length()>mb.toLong()*1024*1024) return@withLock MediaFile(temp,source,credit,true)
            trimLocked(mb.toLong()*1024*1024-temp.length())
            require(temp.renameTo(file))
            Properties().apply{setProperty("source",source);setProperty("credit",credit)}.let{p->meta.outputStream().use{p.store(it,null)}}
            MediaFile(file,source,credit)
        } catch(e:Exception){temp.delete();throw e}
    }}
}
object MediaPlayback {
    private var player:MediaPlayer?=null
    private var temporary:File?=null
    var playing by mutableStateOf<String?>(null);private set
    fun stop(){player?.release();player=null;temporary?.delete();temporary=null;playing=null}
    fun play(key:String,file:MediaFile){SpeechPlayback.stop();stop();val next=MediaPlayer();player=next;temporary=if(file.ephemeral)file.file else null;playing=key
        try{next.setDataSource(file.file.absolutePath);next.setOnPreparedListener{if(player===it)it.start()};next.setOnCompletionListener{stop()};next.setOnErrorListener{_,_,_->stop();true};next.prepareAsync()}catch(e:Exception){stop();throw e}
    }
}
@Composable
fun MediaView(media:Media,settings:AppSettings,showFileName:Boolean=true,edition:String="",showCaption:Boolean=true) {
    val cache=MediaCache.get(LocalContext.current);val scope=rememberCoroutineScope();val uri=LocalUriHandler.current
    val key=remember(media.kind,media.file,edition){mediaKey(media,edition)}
    var resource by remember(key){mutableStateOf<MediaFile?>(null)}
    var error by remember(key){mutableStateOf<String?>(null)}
    var retry by remember(key){mutableIntStateOf(0)}
    var busy by remember(key){mutableStateOf(false)}
    var bitmap by remember(key){mutableStateOf<android.graphics.Bitmap?>(null)}
    var audioJob by remember(key){mutableStateOf<Job?>(null)}
    val allowed=if(media.kind=="image")settings.allowImages else settings.allowAudio
    LaunchedEffect(key,allowed,settings.mediaCacheMb,retry){
        if(media.kind=="image"&&allowed){busy=true;error=null;try{val loaded=cache.get(media,settings.mediaCacheMb,edition);resource=loaded
            bitmap=withContext(Dispatchers.IO){val bounds=BitmapFactory.Options().apply{inJustDecodeBounds=true};BitmapFactory.decodeFile(loaded.file.absolutePath,bounds);require(bounds.outWidth>0&&bounds.outHeight>0){"Unsupported image"};val options=BitmapFactory.Options().apply{inSampleSize= maxOf(1,maxOf(bounds.outWidth,bounds.outHeight)/1600)};BitmapFactory.decodeFile(loaded.file.absolutePath,options)}
            if(loaded.ephemeral)loaded.file.delete()
        }catch(e:CancellationException){throw e}catch(e:Exception){error=e.message}finally{busy=false}}
    }
    DisposableEffect(key){onDispose{audioJob?.cancel();if(MediaPlayback.playing==key)MediaPlayback.stop();resource?.takeIf{it.ephemeral}?.file?.delete()}}
    Column(Modifier.fillMaxWidth().animateContentSize()) {
        if(media.kind=="image"&&allowed&&(error==null||bitmap!=null)) Box(Modifier.fillMaxWidth().padding(top=12.dp).height(220.dp),contentAlignment=Alignment.Center) {
            bitmap?.let { Image(it.asImageBitmap(),media.caption.ifBlank{media.file},Modifier.fillMaxSize()) }
            if(bitmap==null && busy) CircularProgressIndicator(Modifier.size(24.dp),strokeWidth=2.dp)
        }
        Row(verticalAlignment=Alignment.CenterVertically) {
            if(media.kind!="image" || !allowed || error!=null) IconButton(enabled=allowed&&!busy,onClick={
                if(media.kind=="audio") { if(MediaPlayback.playing==key)MediaPlayback.stop() else {audioJob=scope.launch{busy=true;error=null;try{val loaded=cache.get(media,settings.mediaCacheMb,edition);resource=loaded;currentCoroutineContext().ensureActive();MediaPlayback.play(key,loaded)}catch(e:CancellationException){throw e}catch(e:Exception){error=e.message}finally{busy=false}}} }
                else if(error!=null || resource==null) retry++ else resource?.source?.let{uri.openUri(it)}
            }) { if(busy) CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp) else Icon(if(media.kind=="image")Icons.Outlined.Image else if(MediaPlayback.playing==key)Icons.Outlined.Stop else Icons.Outlined.PlayArrow,if(media.kind=="image"){if(error!=null) "Retry image" else "Image source"} else if(MediaPlayback.playing==key) "Stop pronunciation" else "Play pronunciation") }
            Column(Modifier.weight(1f)) {
                val caption=media.caption.takeUnless{it==media.file}.orEmpty()
                if(showCaption && (caption.isNotBlank() || showFileName)) Text(caption.ifBlank{media.file.substringBeforeLast('.').replace('_',' ')},style=MaterialTheme.typography.bodyMedium)
                error?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.error)}
                resource?.credit?.takeIf{it.isNotBlank()}?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
            }
            resource?.let{r->IconButton(onClick={uri.openUri(r.source)}){Icon(Icons.Outlined.OpenInNew,"Source and licence",Modifier.size(17.dp))}}
        }
    }
}
