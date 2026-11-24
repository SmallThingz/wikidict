package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.RectF
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.roundToInt
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class OriginalBabuaDescriptionDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()
    private val inst get() = InstrumentationRegistry.getInstrumentation()
    private val usage = "Maloppo babuana amboku."
    private val translation = "Perut bapak saya besar."
    private val title = "babua [bug]"

    private fun source(): Entry {
        fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val temp = File.createTempFile("babua-dd-", ".wikblb.xz", inst.targetContext.cacheDir)
        val record = try {
            inst.context.assets.open("babua/description-body.wikblb.xz").use { input -> temp.outputStream().use { input.copyTo(it) } }
            assertEquals(1124L, temp.length())
            assertEquals("1229eade11cab70e392c32ca82c31d81958188b93d14e7441635f6c3bd1d462d", sha(temp.readBytes()))
            BlobSource(temp).use { source ->
                assertTrue(source.compressed); assertEquals(3575L, source.length)
                val raw = source.read(0, 3575)
                assertEquals("bb50cbacbbf832ac26438fbb69fcec6771f37edf3184b977f45c489dfa7d22de", sha(raw))
                source.read(30, 3545).also { assertEquals("57612f152e6722cbc444fa2985e4a9a48be4ca5de0bed0bed134d5abe49f37ba", sha(it)) }
            }
        } finally { check(temp.delete()) }
        val entry = BlobDecoder.decode(record, "babua", "language", "Buginese", "bug").copy(edition = "idwiktionary-20261001")
        val section = entry.sections.single { it.title == title }
        assertEquals("babua_[bug]", section.anchor)
        val owners = mutableListOf<Block>()
        val observer = PresentationSpanVisitor { _, _ -> }.apply { onBlock = { owners += it } }
        observer.blocks(section.blocks)
        val example = section.blocks.single { it.kind == "example" }
        assertEquals("#:", example.listPath); assertEquals(2, example.depth)
        val inner = owners.single { it.kind == "indent" && it.listPath == ":" && it.spans.isEmpty() && it !== example && it.descriptionBody != null }
        assertEquals(1, inner.depth)
        val native = owners.single { it.spans.joinToString("") { span -> span.text } == usage }.spans
        assertEquals(listOf(false, true, false), native.map { it.bold }); assertTrue(native.all { it.italic && it.language == "bug" })
        val translated = owners.single { it.spans.joinToString("") { span -> span.text } == translation }.spans
        assertEquals(listOf(true, false), translated.map { it.bold }); assertTrue(translated.none { it.italic })
        assertEquals(listOf("LL-Q33190 (bug)-Iripseudocorus-Babbua.wav", "Codex icon tag color-progressive.svg"), entry.media.map { it.file })
        return entry
    }

    private data class Line(val view: NativeFloatTextView, val start: Int, val chars: List<RectF?>, val ranges: List<RectF>) {
        val bounds = RectF(ranges.first()).also { all -> ranges.drop(1).forEach { all.union(it) } }
    }

    private val missing = linkedSetOf<String>()

    private fun line(text: String, origin: androidx.compose.ui.geometry.Rect, heading: Boolean = false): Line {
        val found = mutableListOf<Line>()
        fun visit(v: View) {
            if (v is NativeFloatTextView && v.isShown) v.currentMeasuredGeometry?.let { g ->
                val start = if (heading) g.nodes.singleOrNull { it.kind == FloatInteractionKind.HEADING && it.label == text }?.start ?: -1
                    else g.text.indexOf(text)
                if (start >= 0 && g.text.subSequence(start, start + text.length).toString() == text) {
                    val at = IntArray(2).also(v::getLocationInWindow)
                    fun located(r: RectF) = RectF(r).apply {
                        offset(at[0] + v.paddingLeft - origin.left, at[1] + v.paddingTop - origin.top)
                    }
                    val rects = g.characterRects(start, text.length)
                    val ranges = g.rectsForRange(start, start + text.length)
                    val bad = rects.indices.filter { rects[it]?.isEmpty != false }
                    val diagnostic = bad.joinToString { i ->
                        val offset = start + i
                        "index=$i U+${text[i].code.toString(16)} rect=${rects[i]} " +
                            "up=${g.caretRect(NativeTextCaret(offset, NativeTextAffinity.Upstream))} " +
                            "down=${g.caretRect(NativeTextCaret(offset, NativeTextAffinity.Downstream))} clip=${g.clipForOffset(offset)}"
                    }
                    inst.sendStatus(0, Bundle().apply { putString("stream", "\nBABUA_DD_GEOMETRY $text source=$start ranges=$ranges missing=$diagnostic\n") })
                    if (bad.isNotEmpty()) missing += "$text: $diagnostic"
                    // These three source strings are LTR. A styled run still exposes each
                    // interior character even when its fitting layout caches the entire run.
                    for (i in 1 until rects.size) {
                        val rect = rects[i]?.takeUnless { it.isEmpty } ?: continue
                        val offset = start + i
                        if (g.lineRange(offset - 1) != g.lineRange(offset)) continue
                        val up = g.caretRect(NativeTextCaret(offset, NativeTextAffinity.Upstream))
                        val down = g.caretRect(NativeTextCaret(offset, NativeTextAffinity.Downstream))
                        val hit = g.caretAt(rect.left + minOf(2f, rect.width() * .125f), rect.centerY())
                        if (abs(up.left - down.left) > 1f || hit.offset != offset)
                            missing += "$text offset=$offset up=$up down=$down rect=$rect hit=$hit"
                    }
                    check(ranges.isNotEmpty()) { "Empty native painted range for $text: $diagnostic" }
                    found += Line(v, start, rects.map { it?.let(::located) }, ranges.map(::located))
                }
            }
            if (v is ViewGroup) repeat(v.childCount) { visit(v.getChildAt(it)) }
        }
        visit(compose.activity.window.decorView)
        assertEquals("Actual native text owner for $text", 1, found.size)
        return found.single()
    }

    private fun near(pixel: Int, rgb: Int, slack: Int = 2) = listOf(0, 8, 16).all { shift ->
        abs((pixel ushr shift and 255) - (rgb ushr shift and 255)) <= slack }

    private fun save(frame: Bitmap, mode: String, part: String) {
        val file = File(inst.targetContext.cacheDir, "wikidict-babua-dd-$mode-$part.png")
        file.outputStream().use { assertTrue(frame.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        inst.sendStatus(0, Bundle().apply { putString("stream", "\nBABUA_DD_FRAME $mode $part ${file.name} bytes=${file.length()}\n") })
    }

    @Test fun originalDescriptionOwnersPaintBothThemesAndKeepHeadingAndExampleText() {
        val entry = source()
        val view = compose.onNodeWithTag("original-babua-dd")
        try {
            for (mode in listOf("light", "dark")) {
                var em = 0f
                var opened = false
                val request = EntryAnchorRequest(entry.key, "#babua_[bug]")
                compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                    CompositionLocalProvider(LocalDensity provides Density(2f, 1f)) {
                        DictTheme(mode) { Surface { Box(Modifier.fillMaxSize().testTag("original-babua-dd")) {
                            em = with(LocalDensity.current) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
                            EntryView(entry, false, {}, anchorRequest = request, onAnchorConsumed = { opened = it === request },
                                settings = AppSettings(collapseOtherSections = false, collapseDetails = false, allowImages = false, allowAudio = false))
                        } } }
                    }
                } }
                compose.waitUntil(10000) { opened }; compose.waitForIdle()
                val origin = view.fetchSemanticsNode().boundsInWindow
                val headingFrame = view.captureToImage().asAndroidBitmap()
                try {
                    save(headingFrame, mode, "heading")
                    val h = compose.runOnIdle { line(title, origin, heading = true) }
                    val band = compose.runOnIdle {
                        val g = checkNotNull(h.view.currentMeasuredGeometry)
                        val node = g.nodes.single { it.kind == FloatInteractionKind.HEADING && it.start == h.start }
                        val info = checkNotNull(h.view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                        assertTrue(info.isHeading)
                        assertTrue(info.actionList.any { it.label == "Collapse $title" })
                        val at = IntArray(2).also(h.view::getLocationInWindow)
                        at[1] + h.view.paddingTop - origin.top + checkNotNull(g.clipForOffset(node.start)).top
                    }
                    fun ink(rectangles: List<RectF>, color: Int): Int = rectangles.sumOf { r ->
                        var count = 0
                        for (y in maxOf(0, r.top.toInt()) until minOf(headingFrame.height, kotlin.math.ceil(r.bottom).toInt()))
                            for (x in maxOf(0, r.left.toInt()) until minOf(headingFrame.width, kotlin.math.ceil(r.right).toInt()))
                                if (near(headingFrame.getPixel(x, y), color)) count++
                        count
                    }
                    assertTrue(ink(h.chars.take(5).filterNotNull(), Color.parseColor(if (mode == "light") "#333333" else "#e0e0e0")) >= 4)
                    assertTrue(ink(h.chars.drop(6).filterNotNull(), Color.parseColor("#888888")) >= 3)
                    val stroke = Color.parseColor(if (mode == "light") "#a2a9b1" else "#72777d")
                    assertTrue("Dashed H3 edge at $band", ((band.toInt()-5)..(band.toInt()+2)).filter { it in 0 until headingFrame.height }.any { y ->
                        val row = (0 until headingFrame.width).map { x -> near(headingFrame.getPixel(x,y), stroke) }
                        row.count { it } > 12 && row.zipWithNext().count { it.first != it.second } >= 6
                    })
                } finally { headingFrame.recycle() }
                val before = compose.runOnIdle { line(translation, origin).bounds.centerY() }
                compose.onNodeWithTag("entry-scroll").performSemanticsAction(SemanticsActions.ScrollBy) { it(0f, before - origin.height * .58f) }
                compose.waitForIdle()
                val frame = view.captureToImage().asAndroidBitmap()
                try {
                    save(frame, mode, "body")
                    val (first, second) = compose.runOnIdle { line(usage, origin) to line(translation, origin) }
                    val rod = Color.parseColor(if (mode == "light") "#cccccc" else "#333333")
                    val y1 = first.bounds.centerY().roundToInt(); val y2 = second.bounds.centerY().roundToInt()
                    assertTrue(y1 in 0 until y2 && y2 < frame.height)
                    val outerX = checkNotNull(first.chars.first()) { "First usage character has no native box" }.left - em * .6f
                    val innerX = checkNotNull(second.chars.first()) { "First translation character has no native box" }.left - em * .57f
                    // At 2 physical pixels per CSS px the stripe can contain two fully covered columns.
                    fun stripe(x: Float, range: IntRange): Int {
                        val cols = ((x-2).toInt()..(x+3).toInt()).filter { col -> col in 0 until frame.width &&
                            range.all { y -> y in 0 until frame.height && near(frame.getPixel(col,y),rod) } }
                        assertTrue("Missing or over-wide $mode stroke at $x, $range: $cols", cols.size in 1..2)
                        return cols.first()
                    }
                    val outer = stripe(outerX, (y1-2)..(y2+2))
                    val inner = stripe(innerX, (y2-3)..(y2+3))
                    assertTrue(inner > outer && !near(frame.getPixel(inner,y1),rod))
                    assertEquals(.79f * em, (inner-outer).toFloat(), 3f)
                    for (owner in listOf(first,second)) compose.runOnIdle {
                        owner.view.setSelection(owner.start, owner.start+owner.chars.size)
                        assertEquals(if (owner === first) usage else translation, owner.view.selectedTextForCopy())
                        owner.view.setSelection(owner.start,owner.start)
                    }
                } finally { frame.recycle() }
            }
            assertTrue("Missing native per-character boxes: $missing", missing.isEmpty())
        } finally { compose.runOnIdle { compose.activity.setContent {} }; compose.waitForIdle() }
    }
}
