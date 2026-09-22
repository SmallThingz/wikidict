package app.smallthingz.dict

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import androidx.compose.runtime.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.*
import java.net.URI
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

data class DictionaryInfo(val id: String, val language: String, val code: String, val kind: String, val count: Int, val bytes: Long)
data class WordHit(val dictionary: String, val title: String, val language: String, val kind: String, val offset: Long, val length: Int) {
    val key get() = "$kind\u0000$language\u0000$title"
}
data class CatalogItem(val url: String, val label: String, val bytes: Long? = null, val sha256: String? = null)
object Catalog {
    const val DEFAULT = "https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list"
    fun parse(text: String, debug: Boolean = false): List<CatalogItem> {
        require(text.toByteArray().size <= 2*1024*1024) { "Catalogue is too large" }
        return text.lineSequence().map(String::trim).filter { it.isNotEmpty() && !it.startsWith('#') }.map { line ->
            val fields = line.split('\t'); require(fields.size in 1..4) { "Invalid catalogue row" }
            val uri = URI(fields[0]); require(uri.scheme == "https" || (debug && uri.scheme == "asset")) { "Catalogue links must use HTTPS" }
            require(uri.host != null && uri.userInfo == null && uri.fragment == null)
            val size = fields.getOrNull(2)?.takeIf { it.isNotBlank() }?.toLong()?.also { require(it > 0) }
            val hash = fields.getOrNull(3)?.takeIf { it.isNotBlank() }?.lowercase()?.also { require(it.matches(Regex("[a-f0-9]{64}"))) }
            CatalogItem(fields[0], fields.getOrNull(1)?.takeIf { it.isNotBlank() } ?: uri.path.substringAfterLast('/').removeSuffix(".wikblb"), size, hash)
        }.take(10001).toList().also { require(it.size <= 10000); require(it.map { x -> x.url }.distinct().size == it.size) }
    }
}
class LibraryStore private constructor(private val context: Context) {
    companion object {
        @Volatile private var instance: LibraryStore? = null
        fun get(context: Context) = instance ?: synchronized(this) { instance ?: LibraryStore(context.applicationContext).also { instance = it } }
    }
    private val directory = File(context.filesDir, "dictionaries").apply { mkdirs() }
    private val helper = object : SQLiteOpenHelper(context, "library.db", null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE dictionaries(id TEXT PRIMARY KEY,language TEXT,code TEXT,kind TEXT,count INTEGER,bytes INTEGER)")
            db.execSQL("CREATE TABLE words(dictionary TEXT,title TEXT,normalized TEXT,payload INTEGER,length INTEGER)")
            db.execSQL("CREATE INDEX word_lookup ON words(normalized,title)")
            db.execSQL("CREATE INDEX word_dictionary ON words(dictionary)")
        }
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }.apply { setWriteAheadLoggingEnabled(true) }
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    var dictionaries by mutableStateOf<List<DictionaryInfo>>(emptyList()); private set
    var busy by mutableStateOf<String?>(null); private set
    var progress by mutableFloatStateOf(0f); private set
    var error by mutableStateOf<String?>(null); private set
    var revision by mutableIntStateOf(0); private set
    var catalog by mutableStateOf<List<CatalogItem>>(emptyList()); private set
    private val prefs = context.getSharedPreferences("library", Context.MODE_PRIVATE)
    var sources by mutableStateOf(prefs.getStringSet("sources", setOf(Catalog.DEFAULT))!!.toList()); private set
    init { scope.launch { mutex.withLock {
        val installed=helper.readableDatabase.rawQuery("SELECT id FROM dictionaries",null).use{c->buildSet{while(c.moveToNext())add(c.getString(0)+".wikblb")}}
        directory.listFiles()?.filter{it.extension=="part" || (it.extension=="wikblb" && it.name !in installed)}?.forEach{it.delete()}
        refresh()
    } } }
    private suspend fun refresh() {
        val values = helper.readableDatabase.rawQuery("SELECT * FROM dictionaries ORDER BY language", null).use { c -> buildList {
            while (c.moveToNext()) add(DictionaryInfo(c.getString(0), c.getString(1), c.getString(2), c.getString(3), c.getInt(4), c.getLong(5)))
        } }
        withContext(Dispatchers.Main) { dictionaries = values; revision++ }
    }
    fun addSource(url: String) {
        val uri = URI(url.trim()); require(uri.scheme == "https" && uri.host != null && uri.userInfo == null) { "Use an HTTPS catalogue URL" }
        sources = (sources + uri.toString()).distinct(); prefs.edit().putStringSet("sources", sources.toSet()).apply()
    }
    fun removeSource(url: String) { sources = sources - url; prefs.edit().putStringSet("sources", sources.toSet()).apply() }
    private var currentOperation: Job? = null
    fun cancel() { currentOperation?.cancel() }
    private fun operation(label: String, action: suspend () -> Unit): Job = scope.launch {
        mutex.withLock {
            withContext(Dispatchers.Main) { busy = label; error = null; progress = 0f }
            try { action() } catch (e: CancellationException) { throw e } catch (e: Exception) {
                withContext(Dispatchers.Main) { error = e.message ?: "Could not complete this operation" }
            } finally { withContext(NonCancellable + Dispatchers.Main) { busy = null } }
        }
    }.also { currentOperation = it }
    fun refreshCatalogs() = operation("Reading catalogues") {
        val entries = ArrayList<CatalogItem>()
        for (source in sources.toList()) if (BuildConfig.DEBUG && source == Catalog.DEFAULT) context.assets.open("debug-dictionaries.list").use { entries += Catalog.parse(it.bufferedReader().readText(), true) }
        else entries += Catalog.parse(Network.read(source, 2*1024*1024).decodeToString(throwOnInvalidSequence = true))
        withContext(Dispatchers.Main) { catalog = entries.distinctBy { it.url } }
    }
    fun download(item: CatalogItem) = operation("Downloading ${item.label}") {
        val temp = File(directory, "${UUID.randomUUID()}.part")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var size = 0L
            val max = minOf(directory.usableSpace - 32*1024*1024, 32L*1024*1024*1024)
            val input = if (BuildConfig.DEBUG && item.url.startsWith("asset://")) context.assets.open(item.url.removePrefix("asset://")) else Network.open(item.url)
            input.use { source -> temp.outputStream().buffered(256*1024).use { out ->
                val buffer = ByteArray(256*1024); var update = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val n = source.read(buffer); if (n < 0) break
                    size += n; require(size <= max && (item.bytes == null || size <= item.bytes)) { "Insufficient space or invalid download size" }
                    out.write(buffer, 0, n); digest.update(buffer, 0, n)
                    if (size-update > 1024*1024) { update = size; withContext(Dispatchers.Main) { progress = item.bytes?.let { size.toFloat()/it } ?: 0f } }
                }
            } }
            val hash = digest.digest().joinToString("") { "%02x".format(it) }
            require(item.bytes == null || item.bytes == size) { "Incomplete download" }
            require(item.sha256 == null || item.sha256 == hash) { "Dictionary checksum does not match" }
            withContext(Dispatchers.Main) { busy = "Indexing ${item.label}" }
            install(temp, hash)
        } finally { temp.delete() }
    }
    fun importFile(input: () -> InputStream) = operation("Importing dictionary") {
        val temp = File(directory, "${UUID.randomUUID()}.part")
        try {
            input().use { source -> temp.outputStream().use { out ->
                val buffer = ByteArray(256*1024); var total = 0L; val max = directory.usableSpace - 32*1024*1024
                while (true) { currentCoroutineContext().ensureActive(); val n = source.read(buffer); if (n < 0) break; total += n; require(total <= max); out.write(buffer,0,n) }
            } }
            val hash = temp.inputStream().use { stream -> val d=MessageDigest.getInstance("SHA-256"); val b=ByteArray(256*1024); while(true){val n=stream.read(b);if(n<0)break;d.update(b,0,n)};d.digest().joinToString(""){"%02x".format(it)} }
            install(temp, hash)
        } finally { temp.delete() }
    }
    private suspend fun install(temp: File, id: String) {
        val db = helper.writableDatabase
        if (db.rawQuery("SELECT id FROM dictionaries WHERE id=?", arrayOf(id)).use { it.moveToFirst() }) return
        var count = 0; var language = ""; var code = ""; var kind = ""
        val final = File(directory, "$id.wikblb")
        db.beginTransaction()
        try {
            CountingInput(temp.inputStream().buffered(256*1024)).use { input ->
                require(input.bytes(8).contentEquals("WIKBLB08".toByteArray())) { "Choose a WIKBLB08 dictionary" }
                kind = listOf("language","thesaurus","citations","reconstruction","rhymes","sign_gloss").getOrNull(input.read()-1) ?: error("Invalid blob kind")
                if (kind == "language") { code = input.nul(); language = input.nul(); require(language.isNotBlank()) } else language = kind.replace('_',' ')
                var previous: ByteArray? = null
                val statement = db.compileStatement("INSERT INTO words VALUES(?,?,?,?,?)")
                statement.use {
                    while (input.position < temp.length()) {
                        currentCoroutineContext().ensureActive()
                        val title = input.nul(); require(title.isNotEmpty())
                        val raw = title.toByteArray(); previous?.let { require(compareUtf8(it,raw) < 0) { "Dictionary titles are not sorted" } }; previous = raw
                        val length = input.varuint(); require(length in 4..128L*1024*1024 && length <= temp.length()-input.position) { "Invalid record size" }
                        val offset = input.position
                        require(input.bytes(4).contentEquals("DPR2".toByteArray())) { "Dictionary is not compiled presentation data" }
                        input.skipFully(length-4)
                        statement.bindString(1,id); statement.bindString(2,title); statement.bindString(3,title.lowercase(Locale.ROOT)); statement.bindLong(4,offset); statement.bindLong(5,length); statement.executeInsert(); count++
                    }
                }
            }
            require(count > 0) { "Dictionary has no entries" }
            require(temp.renameTo(final)) { "Cannot install dictionary" }
            db.execSQL("INSERT INTO dictionaries VALUES(?,?,?,?,?,?)", arrayOf<Any>(id,language,code,kind,count,final.length()))
            db.setTransactionSuccessful()
        } catch (e: Exception) { final.delete(); throw e } finally { db.endTransaction() }
        refresh()
    }
    suspend fun search(query: String, limit: Int = 80): List<WordHit> = withContext(Dispatchers.IO) {
        val q = query.trim().lowercase(Locale.ROOT)
        helper.readableDatabase.rawQuery("SELECT w.dictionary,w.title,d.language,d.kind,w.payload,w.length FROM words w JOIN dictionaries d ON d.id=w.dictionary WHERE normalized >= ? AND normalized < ? ORDER BY normalized,w.title LIMIT ?", arrayOf(q,q + String(Character.toChars(0x10ffff)),limit.coerceIn(1,500).toString())).use { c -> buildList {
            while(c.moveToNext()) add(WordHit(c.getString(0),c.getString(1),c.getString(2),c.getString(3),c.getLong(4),c.getInt(5)))
        } }
    }
    suspend fun random(): WordHit? = withContext(Dispatchers.IO) {
        val choices=dictionaries.toList(); val total=choices.sumOf{it.count.toLong()}
        if(total==0L) return@withContext null
        var pick=kotlin.random.Random.nextLong(total)
        val dictionary=choices.first { if(pick<it.count) true else {pick-=it.count;false} }
        val db=helper.readableDatabase
        val first=db.rawQuery("SELECT MIN(rowid) FROM words WHERE dictionary=?",arrayOf(dictionary.id)).use{it.moveToFirst();it.getLong(0)}
        db.rawQuery("SELECT title,payload,length FROM words WHERE rowid=? AND dictionary=?",arrayOf((first+pick).toString(),dictionary.id)).use{c ->
            if(c.moveToFirst()) WordHit(dictionary.id,c.getString(0),dictionary.language,dictionary.kind,c.getLong(1),c.getInt(2)) else null
        }
    }
    suspend fun exact(title: String, language: String? = null): WordHit? = withContext(Dispatchers.IO) {
        helper.readableDatabase.rawQuery("SELECT w.dictionary,w.title,d.language,d.kind,w.payload,w.length FROM words w JOIN dictionaries d ON d.id=w.dictionary WHERE normalized=? ORDER BY CASE WHEN d.language=? THEN 0 ELSE 1 END, CASE WHEN w.title=? THEN 0 ELSE 1 END LIMIT 1",arrayOf(title.lowercase(Locale.ROOT),language.orEmpty(),title)).use{c ->
            if(c.moveToFirst()) WordHit(c.getString(0),c.getString(1),c.getString(2),c.getString(3),c.getLong(4),c.getInt(5)) else null
        }
    }
    suspend fun lastWord(): WordHit? = prefs.getString("lastTitle",null)?.let { exact(it,prefs.getString("lastLanguage",null)) }
    suspend fun read(hit: WordHit): Entry = withContext(Dispatchers.IO) {
        val dictionary = dictionaries.firstOrNull { it.id == hit.dictionary } ?: error("Dictionary was removed")
        RandomAccessFile(File(directory,"${hit.dictionary}.wikblb"),"r").use { file ->
            file.seek(hit.offset); val data=ByteArray(hit.length);file.readFully(data)
            BlobDecoder.decode(data,hit.title,hit.kind,if(hit.kind=="language")hit.language else null,dictionary.code)
        }
    }
    fun rememberWord(hit:WordHit) { prefs.edit().putString("lastTitle",hit.title).putString("lastLanguage",hit.language).apply() }
    fun remove(id: String) = operation("Removing dictionary") {
        helper.writableDatabase.apply { beginTransaction();try { delete("words","dictionary=?",arrayOf(id));delete("dictionaries","id=?",arrayOf(id));setTransactionSuccessful() } finally { endTransaction() } }
        File(directory,"$id.wikblb").delete();refresh()
    }
}
private fun compareUtf8(a: ByteArray,b: ByteArray): Int { for(i in 0 until minOf(a.size,b.size)){val d=(a[i].toInt() and 255)-(b[i].toInt() and 255);if(d!=0)return d};return a.size-b.size }
private class CountingInput(input: InputStream): FilterInputStream(input) {
    var position=0L;private set
    override fun read():Int = super.read().also { if(it>=0)position++ }
    fun bytes(n:Int):ByteArray { val b=ByteArray(n);for(i in b.indices){val x=read();require(x>=0){"Truncated dictionary"};b[i]=x.toByte()};return b }
    fun nul():String { val b=ByteArrayOutputStream();while(true){val x=read();require(x>=0 && b.size()<65536){"Invalid title"};if(x==0)break;b.write(x)};return b.toByteArray().decodeToString(throwOnInvalidSequence=true) }
    fun varuint():Long { var value=0L;var shift=0;while(true){val x=read();require(x>=0 && shift<63);value=value or ((x and 127).toLong() shl shift);if(x and 128==0){require(shift==0||x!=0);return value};shift+=7} }
    fun skipFully(n:Long){var left=n;while(left>0){val skipped=`in`.skip(left);if(skipped==0L){require(read()>=0);left--}else{position+=skipped;left-=skipped}}}
}
