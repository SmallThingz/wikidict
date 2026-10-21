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
