package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URI

class MediaSourceDeviceTest {
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
