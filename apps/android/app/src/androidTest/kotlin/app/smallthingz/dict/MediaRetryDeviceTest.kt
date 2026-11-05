package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class MediaRetryDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun heightOnlyImageCanExplicitlyRefreshMissingMimeWithoutDiscardingOfflineCache(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = withContext(Dispatchers.IO) {
            File(context.cacheDir, "media-mime-retry-" + UUID.randomUUID()).apply { mkdirs() }
        }
        val png = withContext(Dispatchers.IO) {
            val bitmap = android.graphics.Bitmap.createBitmap(2, 2, android.graphics.Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(android.graphics.Color.rgb(0, 96, 160))
                ByteArrayOutputStream().use { output ->
                    check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output))
                    output.toByteArray()
                }
            } finally { bitmap.recycle() }
        }
        val mode = AtomicReference("missing")
        val metadataCalls = AtomicInteger()
        val downloads = AtomicInteger()
        val cache = MediaCache(context, directory = directory, metadata = {
            metadataCalls.incrementAndGet()
            when (mode.get()) {
                "failed" -> throw java.io.IOException("Controlled metadata outage")
                "cancelled" -> throw kotlinx.coroutines.CancellationException("Controlled metadata cancellation")
            }
            val mime = if (mode.get() == "complete") ",\"mime\":\"image/png\"" else ""
            """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/mime.png","width":2,"height":2$mime}]}]}}""".toByteArray()
        }, openMedia = { downloads.incrementAndGet(); ByteArrayInputStream(png) })
        val media = Media("Mime.png", "image", "")
        val settings = mutableStateOf(AppSettings(allowImages = false, mediaCacheMb = 1, collapseOtherSections = false))
        val entry = Entry("Image metadata recovery", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(Block("paragraph", 0, listOf(
                Span("text", "", image = InlineImage(media.file, 20, alt = "Width control")),
                Span("text", " "),
                Span("text", "", image = InlineImage(media.file, heightPx = 20, alt = "Height control"))))))),
            emptyList(), media = listOf(media))
        val images = SemanticsMatcher("Typed image state") { node ->
            node.config.getOrNull(SemanticsProperties.Role) == androidx.compose.ui.semantics.Role.Image &&
                node.config.getOrNull(SemanticsProperties.StateDescription) != null
        }
        var density = 1f
        suspend fun savedBytes() = withContext(Dispatchers.IO) {
            directory.listFiles().orEmpty().filter { it.extension in setOf("bin", "meta") }
                .associate { it.name to it.readBytes() }
        }
        fun states(width: String, height: String) {
            compose.waitUntil(15000) {
                compose.onAllNodes(images, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false)
                    .map { it.config.getOrNull(SemanticsProperties.StateDescription) } == listOf(width, height)
            }
        }
        fun retryHeight() {
            compose.onAllNodes(images, useUnmergedTree = true)[1].performClick()
            compose.onNodeWithText("Retry image").assertIsDisplayed().assertIsEnabled().performClick()
        }
        try {
            // Exercise the current producer of an incomplete sidecar, not an invented old format.
            cache.withFile(media, 1, canonicalFile = true) { assertEquals(null, it.originalMime) }
            val original = savedBytes()
            assertEquals(2, original.size)
            mode.set("cancelled")
            val cancelled = runCatching {
                cache.withFile(media, 1, forceRefresh = true, canonicalFile = true) { error("Cancelled refresh published") }
            }.exceptionOrNull()
            assertTrue(cancelled is kotlinx.coroutines.CancellationException)
            val afterCancellation = savedBytes()
            assertEquals(original.keys, afterCancellation.keys)
            original.forEach { (name, bytes) -> assertArrayEquals(bytes, afterCancellation.getValue(name)) }
            assertEquals(2, metadataCalls.get()); assertEquals(1, downloads.get())
            mode.set("failed")
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") {
                    density = LocalDensity.current.density
                    CompositionLocalProvider(LocalInlineImageCache provides cache) {
                        EntryView(entry, false, {}, settings = settings.value)
                    }
                }
            } }
            states("Images disabled", "Images disabled")
            assertEquals(2, metadataCalls.get()); assertEquals(1, downloads.get())
            compose.runOnIdle { settings.value = settings.value.copy(allowImages = true) }
            states("", "Image geometry unavailable")
            assertEquals(2, metadataCalls.get()); assertEquals(1, downloads.get())
            assertEquals(20f * density, compose.onAllNodes(images, useUnmergedTree = true)[0].fetchSemanticsNode().boundsInRoot.width, 1f)
            retryHeight()
            states("Image unavailable", "Image unavailable")
            assertEquals(3, metadataCalls.get()); assertEquals(1, downloads.get())
            val afterFailure = savedBytes()
            assertEquals(original.keys, afterFailure.keys)
            original.forEach { (name, bytes) -> assertArrayEquals(bytes, afterFailure.getValue(name)) }

            // Reopening still uses the intact width-sized offline image without an automatic fetch.
            compose.runOnIdle { settings.value = settings.value.copy(allowImages = false) }
            states("Images disabled", "Images disabled")
            compose.runOnIdle { settings.value = settings.value.copy(allowImages = true) }
            states("", "Image geometry unavailable")
            assertEquals(3, metadataCalls.get()); assertEquals(1, downloads.get())
            mode.set("missing")
            retryHeight()
            states("", "Image geometry unavailable")
            compose.waitForIdle()
            assertEquals(4, metadataCalls.get()); assertEquals(2, downloads.get())
            mode.set("complete")
            retryHeight()
            states("", "")
            compose.waitForIdle()
            assertEquals(5, metadataCalls.get()); assertEquals(3, downloads.get())
            // Original raster dimensions still cap height-only sizing; the width control is unchanged.
            assertEquals(20f * density, compose.onAllNodes(images, useUnmergedTree = true)[0].fetchSemanticsNode().boundsInRoot.width, 1f)
            assertEquals(2f * density, compose.onAllNodes(images, useUnmergedTree = true)[1].fetchSemanticsNode().boundsInRoot.width, 1f)
            cache.withFile(media, 1, canonicalFile = true) {
                assertEquals("image/png", it.originalMime)
                withContext(Dispatchers.IO) { assertArrayEquals(png, it.file.readBytes()) }
            }
            assertEquals(5, metadataCalls.get()); assertEquals(3, downloads.get())
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) { directory.deleteRecursively() }
        }
    }

    @Test fun retryImageFetchesAReplacementForAnUndecodableCachedFile(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = withContext(Dispatchers.IO) {
            File(context.cacheDir, "media-retry-" + UUID.randomUUID()).apply { mkdirs() }
        }
        val validImage = withContext(Dispatchers.IO) {
            val bitmap = android.graphics.Bitmap.createBitmap(2, 2, android.graphics.Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(android.graphics.Color.rgb(0, 96, 160))
                ByteArrayOutputStream().use { output ->
                    check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output))
                    output.toByteArray()
                }
            } finally { bitmap.recycle() }
        }
        val metadata = """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/image"}]}]}}""".toByteArray()
        val opens = AtomicInteger()
        val cache = MediaCache(context, metadata = { metadata }, directory = directory,
            openMedia = {
                ByteArrayInputStream(if (opens.incrementAndGet() == 1) "Not an image".toByteArray() else validImage)
            })
        val captureFrame: (String) -> Unit = { name ->
            require(name in setOf("media-cached-image-error.png", "media-retry-image-success.png"))
            // Capture only the owned Compose root containing this public synthetic fixture.
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            try {
                val files = context.filesDir
                val evidence = File(files, "qa-copy-evidence")
                check(evidence.mkdirs() || evidence.isDirectory)
                check(evidence.canonicalFile.parentFile == files.canonicalFile)
                val target = File(evidence, name)
                check(target.canonicalFile.parentFile == evidence.canonicalFile && !target.exists())
                target.outputStream().use { check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
            } finally { bitmap.recycle() }
        }
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent {
                    DictTheme("light") {
                        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                            MediaView(Media("Retry.png", "image", "Synthetic retry image"),
                                AppSettings(allowImages = true, mediaCacheMb = 1), cache = cache)
                        }
                    }
                }
            }
            compose.waitUntil(15000) {
                compose.onAllNodesWithContentDescription("Retry image").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            assertEquals(1, opens.get())
            assertEquals(1, withContext(Dispatchers.IO) { directory.listFiles().orEmpty().count { it.extension == "bin" } })
            compose.onNodeWithContentDescription("Retry image").assertIsEnabled()
            compose.onNodeWithText("Unsupported image").assertIsDisplayed()
            captureFrame("media-cached-image-error.png")
            compose.onNodeWithContentDescription("Retry image").performClick()
            compose.waitUntil(15000) {
                compose.onAllNodesWithContentDescription("Synthetic retry image").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onNodeWithContentDescription("Synthetic retry image").assertIsDisplayed()
            compose.onNodeWithText("Unsupported image").assertDoesNotExist()
            captureFrame("media-retry-image-success.png")
            assertEquals(2, opens.get())
            assertEquals(1, withContext(Dispatchers.IO) { directory.listFiles().orEmpty().count { it.extension == "bin" } })
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) { directory.deleteRecursively() }
        }
    }
}
