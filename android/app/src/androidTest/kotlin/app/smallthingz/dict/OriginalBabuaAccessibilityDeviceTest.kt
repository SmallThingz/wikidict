package app.smallthingz.dict

import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class OriginalBabuaAccessibilityDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()

    @Suppress("DEPRECATION")
    @Test fun publicAccessibilityRecordingNameBindsItsCaptionAndActualAction() {
        val inst = InstrumentationRegistry.getInstrumentation()
        val cacheDir = java.nio.file.Files.createTempDirectory(inst.targetContext.cacheDir.toPath(), "babua-public-ax-").toFile()
        val shard = File(cacheDir, "original.wikblb.xz")
        val requests = AtomicInteger()
        val enabled = mutableStateOf(false)
        val cache = MediaCache(inst.targetContext, directory = cacheDir, metadata = { encoded ->
            val query = java.net.URLDecoder.decode(java.net.URI(encoded).rawQuery, "UTF-8")
            assertTrue(query.contains("titles=File:LL-Q33190 (bug)-Iripseudocorus-Babbua.wav"))
            requests.incrementAndGet()
            throw java.io.IOException("Controlled recording transport error")
        })
        val name = "Play recording: Suara"
        fun publicPlayer(action: (AccessibilityNodeInfo) -> Unit): Boolean {
            val window = compose.runOnIdle {
                assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
                val info = compose.activity.window.decorView.createAccessibilityNodeInfo()
                try { info.windowId } finally { info.recycle() }
            }
            val root = inst.uiAutomation.rootInActiveWindow ?: return false
            val nodes = mutableListOf(root)
            try {
                var next = 0
                while (next < nodes.size) {
                    val node = nodes[next++]
                    if (node.windowId != window || node.packageName?.toString() != inst.targetContext.packageName) return false
                    check(nodes.size < 1024)
                    for (index in 0 until node.childCount) node.getChild(index)?.let(nodes::add)
                }
                val player = nodes.singleOrNull { it.isVisibleToUser && it.contentDescription?.toString() == name } ?: return false
                val bounds = android.graphics.Rect().also(player::getBoundsInScreen)
                assertFalse(bounds.isEmpty)
                action(player)
                return true
            } finally { nodes.forEach { it.recycle() } }
        }
        try {
            inst.context.assets.open("babua/original.wikblb.xz").use { input -> shard.outputStream().use { input.copyTo(it) } }
            val data = BlobSource(shard).use { require(it.compressed && it.length == 2844L); it.read(30, 2814) }
            assertEquals("f3a8306ee905edc288e1bdb5c5b36de8921ce2aef1ae60651286c7edc610d463",
                MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) })
            val entry = BlobDecoder.decode(data, "babua", "language", "Buginese", "bug").copy(edition = "idwiktionary-20261001")
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalInlineImageCache provides cache) {
                    DictTheme("light") { Surface { EntryView(entry, false, {}, settings = AppSettings(
                        collapseOtherSections = false, collapseDetails = false, allowImages = false, allowAudio = enabled.value)) } }
                }
            } }
            val reader = compose.onNodeWithTag("entry-scroll")
            reader.performScrollToNode(hasContentDescription(name))
            compose.waitUntil(5000) { publicPlayer { assertFalse(it.isEnabled) } }
            assertEquals(0, requests.get())
            compose.runOnIdle { enabled.value = true }
            compose.onNodeWithContentDescription(name).assertIsEnabled()
            compose.waitUntil(5000) { publicPlayer { assertTrue(it.isEnabled); assertTrue(it.isClickable) } }
            assertTrue(publicPlayer { assertTrue(it.refresh()); assertTrue(it.performAction(AccessibilityNodeInfo.ACTION_CLICK)) })
            compose.waitUntil(10000) { compose.onAllNodesWithText("Pronunciation could not be played.").fetchSemanticsNodes().isNotEmpty() }
            assertEquals(1, requests.get())
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            inst.sendStatus(0, android.os.Bundle().apply { putString("stream", "\nBABUA_AX label=Play recording: Suara disabled=true enabled=true public-click=1 controlled-error=true\n") })
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }; compose.waitForIdle()
            check(cacheDir.deleteRecursively())
        }
    }
}
