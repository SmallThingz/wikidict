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

    @Test fun publicAccessibilityRecordingNameBindsItsCaptionAndActualAction() = checkOriginal(false)
    @Test fun finalRelativeHeadingAndCompanionKeepTheirPublicActions() = checkOriginal(true)

    @Suppress("DEPRECATION")
    private fun checkOriginal(wrapped: Boolean) {
        val inst = InstrumentationRegistry.getInstrumentation()
        val cacheDir = java.nio.file.Files.createTempDirectory(inst.targetContext.cacheDir.toPath(), "babua-public-ax-").toFile()
        val shard = File(cacheDir, "original.wikblb.xz")
        val requests = AtomicInteger()
        val layoutFailures = mutableSetOf<String>()
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
            val asset = if (wrapped) "babua/heading.wikblb.xz" else "babua/original.wikblb.xz"
            val size = if (wrapped) 2922 else 2814
            inst.context.assets.open(asset).use { input -> shard.outputStream().use { input.copyTo(it) } }
            val data = BlobSource(shard).use { require(it.compressed && it.length == 30L + size); it.read(30, size) }
            val expected = if (wrapped) "a892d7f33f3dc204696916214139c800832ece195406e7f20829aabb4faa2dcd"
                else "f3a8306ee905edc288e1bdb5c5b36de8921ce2aef1ae60651286c7edc610d463"
            assertEquals(expected, MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) })
            val entry = BlobDecoder.decode(data, "babua", "language", "Buginese", "bug").copy(edition = "idwiktionary-20261001")
            val section = entry.sections.last()
            val request = if (wrapped) EntryAnchorRequest(entry.key, "#" + section.anchor) else null
            if (wrapped) {
                val style = checkNotNull(section.headingStyle)
                val frame = checkNotNull(style.wrappers)
                assertEquals(.4f, frame.outerMarginTop.value, .00001f)
                assertEquals(1f, frame.outerTopWidth.value, 0f)
                assertEquals("#a2a9b1", frame.outerTopColor.value)
                assertEquals(1.25f, frame.innerPaddingTop.value, .00001f)
                assertEquals(3.2f, frame.titlePaddingRight.value, .00001f)
                assertEquals(ContainerPositioning.RelativeAuto, style.box.positioning)
                val runs = section.blocks.first().spans
                assertEquals(listOf("babua", " ", "[", "bug", "]"), runs.map { it.text })
                assertTrue(runs.last().subscript)
                assertTrue(runs.all { it.tooltip == "Penjabaran untuk \"babua\" dalam bahasa Bugis" })
            }
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalInlineImageCache provides cache,
                    LocalNativeFloatContextFailureObserver provides { layoutFailures += it }) {
                    DictTheme("light") { Surface { EntryView(entry, false, {}, anchorRequest = request, settings = AppSettings(
                        collapseOtherSections = false, collapseDetails = false, allowImages = false, allowAudio = enabled.value)) } }
                }
            } }
            if (wrapped) {
                compose.waitForIdle()
                val band = compose.runOnIdle {
                    val owners = mutableListOf<Pair<NativeFloatTextView, FloatInteractionNode>>()
                    fun visit(view: android.view.View) {
                        if (view is NativeFloatTextView && view.isShown) view.currentMeasuredGeometry?.nodes?.filter {
                            it.kind == FloatInteractionKind.HEADING && it.label == section.title
                        }?.forEach { owners += view to it }
                        if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
                    }
                    visit(compose.activity.window.decorView)
                    assertEquals("Original H3 heading in the full entry; native refusals=$layoutFailures", 1, owners.size)
                    val (view, node) = owners.single()
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    assertEquals(section.title, geometry.text.subSequence(node.start, node.end).toString())
                    view.setSelection(node.start, node.end)
                    assertEquals(section.title, view.selectedTextForCopy())
                    view.setSelection(node.start, node.start)
                    val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                    assertTrue(info.isHeading)
                    assertTrue(info.actionList.any { it.label == "Collapse ${section.title}" })
                    val rects = geometry.characterRects(node.start, node.end - node.start)
                    assertTrue(rects.first()?.isEmpty == false && rects.last()?.isEmpty == false)
                    val clip = checkNotNull(geometry.clipForOffset(node.start))
                    val at = IntArray(2).also(view::getLocationOnScreen)
                    val location = android.graphics.Rect().also(view::getGlobalVisibleRect)
                    Triple(location, at[1] + clip.top, at[1] + checkNotNull(rects.first()).top)
                }
                // The top physical border adjoins the outer padding clip. Sample its repeated
                // stroke/gap transitions above the heading, inside the real visible viewport.
                val shot = checkNotNull(inst.uiAutomation.takeScreenshot())
                try {
                    val (visible, edge, textTop) = band
                    val density = inst.targetContext.resources.displayMetrics.density
                    assertTrue(textTop > edge)
                    val xs = maxOf(visible.left + 2, 0) until minOf(visible.right - 2, shot.width)
                    val ys = maxOf(visible.top, kotlin.math.floor(edge - density - 2).toInt(), 0)..
                        minOf(kotlin.math.ceil(edge + 2).toInt(), visible.bottom - 1, shot.height - 1)
                    val stroke = android.graphics.Color.rgb(162, 169, 177)
                    fun near(pixel: Int) = listOf(16, 8, 0).all { shift ->
                        kotlin.math.abs((pixel shr shift and 255) - (stroke shr shift and 255)) <= 18 }
                    assertTrue("Original dashed H3 edge at y=$edge, visible=$visible textTop=$textTop", ys.any { y ->
                        val line = xs.map { x -> near(shot.getPixel(x, y)) }
                        line.count { it } > 8 && line.zipWithNext().count { it.first != it.second } >= 6
                    })
                } finally { shot.recycle() }
            }
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
