package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URI

class MediaSourceDeviceTest {
    @Test fun svgVariantsKeepLanguageAndDprBucketsDistinctAcrossOfflineReuseAndRefusal(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "svg-raster-" + java.util.UUID.randomUUID())
        try {
            assertTrue(directory.mkdir())
            val requests = java.util.Collections.synchronizedList(mutableListOf<String>())
            val downloads = java.util.Collections.synchronizedList(mutableListOf<String>())
            val mode = java.util.concurrent.atomic.AtomicReference("valid")
            val fileName = "Test map.svg"
            val media = Media(fileName, "image", "")
            val root = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Test_map.svg/"
            val cache = MediaCache(context, directory = directory, metadata = { url ->
                assertNotSame(android.os.Looper.getMainLooper().thread, Thread.currentThread())
                check(mode.get() != "offline") { "Controlled offline metadata" }
                requests += url
                val query = URI(url).rawQuery.split('&').associate { it.substringBefore('=') to it.substringAfter('=') }
                val width = query.getValue("iiurlwidth").toInt()
                val parameter = query.getValue("iiurlparam")
                val language = parameter.removePrefix("lang").substringBefore('-')
                assertEquals("lang$language-${width}px", parameter)
                val bucket = if (mode.get() == "exact-bucket") width else if (width <= 250) 250 else 500
                val rasterLanguage = if (mode.get() == "wrong-language") "de" else language
                val suffix = if (mode.get() == "generic") "${bucket}px-Test_map.svg.png" else "lang$rasterLanguage-${bucket}px-Test_map.svg.png"
                val responseWidth = when (mode.get()) {
                    "small-metadata" -> 100
                    "rounded-short-metadata" -> 6
                    else -> width
                }
                """{"query":{"pages":[{"imageinfo":[{"width":800,"height":400,"mime":"image/svg+xml","thumbmime":"image/png","thumbwidth":$responseWidth,"thumbheight":${maxOf(1, responseWidth / 2)},"thumburl":"$root$suffix","url":"https://upload.wikimedia.org/wikipedia/commons/a/ab/Test_map.svg"}]}]}}""".toByteArray()
            }, openMedia = { url ->
                check(mode.get() != "offline") { "Controlled offline image" }
                downloads += url
                val width = if (mode.get() == "small-pixels") 100 else url.substringAfterLast('/').substringBefore("px-").substringAfterLast('-').toInt()
                val bitmap = Bitmap.createBitmap(width, if (mode.get() == "short-pixels") 1 else width / 2, Bitmap.Config.ARGB_8888)
                val bytes = try {
                    bitmap.eraseColor(0xff228844.toInt())
                    ByteArrayOutputStream().also { assertTrue(bitmap.compress(if (mode.get() == "jpeg-pixels") Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG, 100, it)) }.toByteArray()
                } finally { bitmap.recycle() }
                ByteArrayInputStream(bytes)
            })
            fun demand(language: String, density: Float) = SvgRasterRequest(language, density,
                listOf(RasterImageOccurrence(InlineImage(fileName, widthPx = 200, svgLanguage = language))))
            suspend fun load(language: String, density: Float, megabytes: Int = 4, refresh: Boolean = false): File {
                var actual: File? = null
                cache.withFile(media, megabytes, "ru", forceRefresh = refresh, canonicalFile = true, rasterRequest = demand(language, density)) { loaded ->
                    assertEquals((200 * density).toInt(), loaded.requiredRasterWidth)
                    assertEquals((100 * density).toInt(), loaded.requiredRasterHeight)
                    val decoded = decodeMediaBitmap(loaded.file, requiredWidth = loaded.requiredRasterWidth, requiredHeight = loaded.requiredRasterHeight)
                    try {
                        assertTrue(decoded.bitmap.width >= (200 * density).toInt())
                        assertTrue(decoded.bitmap.height >= (100 * density).toInt())
                        assertEquals(800L, loaded.originalWidth)
                        assertEquals(400L, loaded.originalHeight)
                        actual = loaded.file
                    } finally { decoded.bitmap.recycle() }
                }
                return checkNotNull(actual)
            }
            val ru200 = load("ru", 1f)
            val en200 = load("en", 1f)
            val ru400 = load("ru", 2f)
            assertEquals(3, setOf(ru200, en200, ru400).size)
            assertEquals(6, requests.size); assertEquals(3, downloads.size)
            assertTrue(downloads[0].contains("langru-250px"))
            assertTrue(downloads[1].contains("langen-250px"))
            assertTrue(downloads[2].contains("langru-500px"))
            assertTrue(requests.any { it.contains("iiurlwidth=400&iiurlparam=langru-400px") })
            val savedBuckets = directory.listFiles().orEmpty().filter { it.extension == "meta" }.map {
                java.util.Properties().apply { it.inputStream().use(::load) }.getProperty("raster_width")
            }
            assertEquals(listOf("250", "250", "500"), savedBuckets.sorted())
            mode.set("offline")
            assertEquals(ru200, load("ru", 1f)); assertEquals(en200, load("en", 1f)); assertEquals(ru400, load("ru", 2f))
            assertEquals(6, requests.size); assertEquals(3, downloads.size)
            for (failure in listOf("wrong-language", "generic", "small-metadata")) {
                mode.set(failure)
                assertTrue(failure, runCatching { load("ru", 2f, 0, true) }.isFailure)
                assertEquals(3, downloads.size)
            }
            for (failure in listOf("small-pixels", "short-pixels", "jpeg-pixels")) {
                mode.set(failure)
                assertTrue(failure, runCatching { load("ru", 2f, 0, true) }.isFailure)
            }
            assertEquals(6, downloads.size)
            assertFalse(directory.listFiles().orEmpty().any { it.extension == "part" })
            mode.set("offline")
            assertEquals(ru400, load("ru", 2f))
            assertEquals(6, downloads.size)
            val roundedRequest = SvgRasterRequest("ru", 2f,
                listOf(RasterImageOccurrence(InlineImage(fileName, widthPx = 3, svgLanguage = "ru"))))
            suspend fun loadRounded(refresh: Boolean = false): File {
                var actual: File? = null
                cache.withFile(media, 4, "ru", forceRefresh = refresh, canonicalFile = true, rasterRequest = roundedRequest) { loaded ->
                    assertEquals(6, loaded.requiredRasterWidth)
                    assertEquals(4, loaded.requiredRasterHeight)
                    val decoded = decodeMediaBitmap(loaded.file, requiredWidth = loaded.requiredRasterWidth, requiredHeight = loaded.requiredRasterHeight)
                    try {
                        assertTrue(decoded.bitmap.width >= 6); assertTrue(decoded.bitmap.height >= 4)
                        assertEquals(8, decoded.width); assertEquals(4, decoded.height)
                        actual = loaded.file
                    } finally { decoded.bitmap.recycle() }
                }
                return checkNotNull(actual)
            }
            val beforeRounded = requests.size
            mode.set("exact-bucket")
            val rounded = loadRounded()
            assertEquals(2, requests.size - beforeRounded)
            assertTrue(requests.last().contains("iiurlwidth=8&iiurlparam=langru-8px"))
            assertTrue(downloads.last().endsWith("langru-8px-Test_map.svg.png"))
            assertNotEquals(ru400, rounded)
            assertEquals(7, downloads.size)
            mode.set("offline")
            assertEquals(rounded, loadRounded())
            assertEquals(beforeRounded + 2, requests.size); assertEquals(7, downloads.size)
            mode.set("rounded-short-metadata")
            assertTrue(runCatching { loadRounded(refresh = true) }.isFailure)
            assertEquals(7, downloads.size)
            assertFalse(directory.listFiles().orEmpty().any { it.extension == "part" })
        } finally { assertTrue(!directory.exists() || directory.deleteRecursively()) }
    }
    @Test fun ephemeralFilesStayOwnedThroughFailureCancellationHandoffAndSameKeyReplay(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            File(context.cacheDir, "media-owned-" + java.util.UUID.randomUUID()).apply { mkdirs() }
        }
        val media = Media("Owned.ogg", "audio", "")
        val metadata = """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/owned"}]}]}}""".toByteArray()
        val deletes = java.util.Collections.synchronizedList(mutableListOf<File>())
        val cache = MediaCache(context, metadata = { metadata }, openMedia = { ByteArrayInputStream(byteArrayOf(1)) },
            directory = directory, deleteTemporary = { file ->
                assertNotSame(android.os.Looper.getMainLooper().thread, Thread.currentThread())
                deletes += file
                file.delete()
            })
        suspend fun exists(file: File) = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { file.exists() }
        suspend fun empty() = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { directory.listFiles().orEmpty().isEmpty() }
        try {
            lateinit var success: File
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                cache.withFile(media, 0) { success = it.file; assertTrue(exists(it.file)) }
            }
            assertFalse(exists(success))
            lateinit var failed: File
            val failure = runCatching {
                cache.withFile(media, 0) { failed = it.file; throw java.io.IOException("owned body failure") }
            }.exceptionOrNull()
            assertEquals("owned body failure", failure?.message)
            assertFalse(exists(failed))

            val entered = kotlinx.coroutines.CompletableDeferred<File>()
            val cancelled = launch {
                cache.withFile(media, 0) { entered.complete(it.file); kotlinx.coroutines.awaitCancellation() }
            }
            val cancelledFile = entered.await()
            cancelled.cancel(); cancelled.join()
            assertFalse(exists(cancelledFile))

            val firstEntered = kotlinx.coroutines.CompletableDeferred<File>()
            val secondEntered = kotlinx.coroutines.CompletableDeferred<File>()
            val firstRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
            val secondRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
            kotlinx.coroutines.coroutineScope {
                val first = launch { cache.withFile(media, 0) { firstEntered.complete(it.file); firstRelease.await() } }
                val firstFile = firstEntered.await()
                val second = launch { cache.withFile(media, 0) { secondEntered.complete(it.file); secondRelease.await() } }
                val secondFile = secondEntered.await()
                assertNotEquals(firstFile, secondFile)
                assertTrue(exists(firstFile)); assertTrue(exists(secondFile))
                firstRelease.complete(Unit); first.join()
                assertFalse(exists(firstFile)); assertTrue(exists(secondFile))
                secondRelease.complete(Unit); second.join()
                assertFalse(exists(secondFile))
            }

            val atClose = java.util.concurrent.CountDownLatch(1)
            val releaseClose = java.util.concurrent.CountDownLatch(1)
            val handoff = MediaCache(context, metadata = { metadata }, directory = directory,
                openMedia = { object : ByteArrayInputStream(byteArrayOf(1)) {
                    override fun close() { atClose.countDown(); check(releaseClose.await(15, java.util.concurrent.TimeUnit.SECONDS)); super.close() }
                } })
            var published = false
            val pending = launch(kotlinx.coroutines.Dispatchers.Main) {
                handoff.withFile(media, 0) { published = true }
            }
            try {
                assertTrue(atClose.await(15, java.util.concurrent.TimeUnit.SECONDS))
                pending.cancel()
            } finally { releaseClose.countDown(); pending.join() }
            assertFalse(published)
            assertTrue(empty())
            assertEquals(5, deletes.size)
        } finally {
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.IO) { directory.deleteRecursively() }
        }
    }


    @Test fun defaultCacheDirectoryIsDeferredUntilAnIoOperation(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            File(context.cacheDir, "media-init-" + java.util.UUID.randomUUID()).apply { mkdirs() }
        }
        val accesses = java.util.concurrent.atomic.AtomicInteger()
        val observed = object : android.content.ContextWrapper(context) {
            override fun getCacheDir(): File {
                assertNotSame(android.os.Looper.getMainLooper().thread, Thread.currentThread())
                accesses.incrementAndGet()
                return root
            }
        }
        lateinit var cache: MediaCache
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            cache = MediaCache(observed)
            assertEquals(0, accesses.get())
        }
        try {
            cache.trim(0)
            assertEquals(1, accesses.get())
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                assertTrue(File(root, "media").isDirectory)
            }
            cache.clear()
            cache.trim(0)
            assertEquals(1, accesses.get())
            val blocked = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                File(root, "not-a-directory").apply { writeText("occupied") }
            }
            val brokenContext = object : android.content.ContextWrapper(context) {
                override fun getCacheDir(): File {
                    assertNotSame(android.os.Looper.getMainLooper().thread, Thread.currentThread())
                    return blocked
                }
            }
            val broken = MediaCache(brokenContext,
                metadata = { """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/audio"}]}]}}""".toByteArray() },
                openMedia = { ByteArrayInputStream(byteArrayOf(1)) })
            val failure = runCatching { broken.get(Media("Broken.ogg", "audio", ""), 1) }.exceptionOrNull()
            assertTrue("An unavailable cache must remain an I/O failure", failure is java.io.IOException)
        } finally {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { root.deleteRecursively() }
        }
    }

    @Test fun isolatedTransportUsesCommonsThenExactEditionAndKeepsSameNamedMediaSeparate(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir,"media-source-test").apply { mkdirs() }
        val calls = mutableListOf<String>()
        val png = ByteArrayOutputStream().also { output ->
            val bitmap = Bitmap.createBitmap(2,2,Bitmap.Config.ARGB_8888)
            try { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,output)) } finally { bitmap.recycle() }
        }.toByteArray()
        val cache = MediaCache(context,metadata={ url ->
            val host = URI(url).host
            calls += host
            when(host) {
                "commons.wikimedia.org" -> """{"query":{"pages":[{"missing":true}]}}"""
                "af.wiktionary.org", "ar.wiktionary.org" -> """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/$host","extmetadata":{"LicenseShortName":{"value":"fixture"}}}]}]}}"""
                else -> error("Unexpected source: $host")
            }.toByteArray()
        },openMedia={ url ->
            assertEquals("fixture.invalid",URI(url).host)
            ByteArrayInputStream(png)
        },directory=directory)
        try {
            val media = Media("Shared.png","image","")
            val af = cache.get(media,1,"afwiktionary-20261001")
            val ar = cache.get(media,1,"arwiktionary-20261001")
            assertEquals(listOf("commons.wikimedia.org","af.wiktionary.org","commons.wikimedia.org","ar.wiktionary.org"),calls)
            assertNotEquals(af.file,ar.file)
            assertEquals("https://af.wiktionary.org/wiki/File%3AShared.png",af.source)
            assertEquals("https://ar.wiktionary.org/wiki/File%3AShared.png",ar.source)
            assertNotNull(BitmapFactory.decodeFile(af.file.absolutePath))
            assertEquals(af.file,cache.get(media,1,"afwiktionary-20261001").file)
            assertEquals(4,calls.size)
            val missing = runCatching { cache.get(media,1) }
            assertTrue(missing.isFailure)
            assertEquals(listOf("commons.wikimedia.org"),calls.drop(4))
            cache.trim(0)
            assertFalse(af.file.exists());assertFalse(ar.file.exists())
            val ephemeral = cache.get(media,0,"afwiktionary-20261001")
            assertTrue(ephemeral.ephemeral);assertTrue(ephemeral.file.length()>0)
            ephemeral.file.delete()
        } finally { cache.clear();directory.deleteRecursively() }
    }
}
