package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class MediaRetryDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

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
