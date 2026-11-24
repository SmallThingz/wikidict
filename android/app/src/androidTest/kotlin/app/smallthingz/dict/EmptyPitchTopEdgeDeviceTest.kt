package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.material3.Surface
import androidx.test.platform.app.InstrumentationRegistry
import java.security.MessageDigest
import java.util.Locale
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class EmptyPitchTopEdgeDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()

    @Test fun originalJapanesePronunciationKeepsTheEmptyEdgeBetweenKanaAndItsSeparateLinks() {
        val inst = InstrumentationRegistry.getInstrumentation()
        val temp = java.nio.file.Files.createTempDirectory(inst.targetContext.cacheDir.toPath(), "sr-ji-").toFile()
        try {
            val shard = temp.resolve("original-ja.wikblb.xz")
            inst.context.assets.open("sr-empty/original-ja.wikblb.xz").use { input ->
                shard.outputStream().use { input.copyTo(it) }
            }
            val data = BlobSource(shard).use {
                check(it.compressed && it.length == 275981L)
                it.read(36, 275945)
            }
            assertEquals("b0523e821b9a6fb1410fc5f1971b288ef98e4d03738abbab62dd12a07f0cd721",
                MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) })
            val entry = BlobDecoder.decode(data, "日", "language", "Јапански", "ja")
            val section = entry.sections[19]
            val block = section.blocks.first()
            assertEquals("Pronunciation", section.title)
            assertEquals("list_item", block.kind)
            val edge = block.spans[4]
            assertEquals("ひ", block.spans[3].text)
            assertEquals("", edge.text)
            assertEquals("ja", edge.language)
            assertEquals("Jpan", edge.classes)
            assertEquals(1.2f, checkNotNull(edge.fontScale), .00001f)
            assertTrue(checkNotNull(edge.inlineBoxGroup).isEmptyTopEdge)
            val links = block.spans.filter { it.kind == "link" }
            assertEquals(listOf("平板型", "#reference-1"), links.map { it.target })
            assertEquals("Pronunciation_6", section.anchor)
            val request = EntryAnchorRequest(entry.key, "#" + section.anchor)
            var consumed = false
            val projection = rubyGraphicalProjection(block.spans)
            val edgeRange = projection.ranges.single { it.role == RubyTextRole.BoxGroup && it.span === edge }
            val edgeOffset = edgeRange.start
            assertEquals(edgeOffset, edgeRange.end)
            assertEquals('ひ', projection.text[edgeOffset - 1])
            val calls = mutableListOf<EntryLink>()
            var navigations = 0
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") { Surface {
                    EntryView(entry, false, {}, onLink = { calls += it }, anchorRequest = request,
                        onAnchorConsumed = { consumed = it === request },
                        settings = AppSettings(collapseOtherSections = false, collapseDetails = false),
                        onNavigate = { navigations++ })
                } }
            } }
            compose.waitUntil(10000) { consumed }
            compose.waitForIdle()
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                val visible = mutableListOf<NativeFloatTextView>()
                fun visit(view: View) {
                    if (view is NativeFloatTextView && view.isShown) visible += view
                    if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
                }
                visit(compose.activity.window.decorView)
                val owners = visible.filter { projection.text in it.logicalText }
                assertEquals("Visible owners after #${section.anchor}: ${visible.map { it.logicalText.take(90) }}", 1, owners.size)
                val view = owners.single()
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val first = geometry.text.indexOf(projection.text)
                assertEquals(first, geometry.text.lastIndexOf(projection.text))
                val end = first + projection.text.length
                val at = first + edgeOffset
                val kana = checkNotNull(geometry.characterRects(at - 1, 1).single())
                assertTrue(kana.width() > 0 && kana.height() > 0)
                assertEquals(kana.right, geometry.caretRect(NativeTextCaret(at, NativeTextAffinity.Upstream)).left, 1f)
                view.setSelection(first, end)
                assertEquals(projection.text, view.selectedTextForCopy())
                val actions = geometry.nodes.filter { it.kind == FloatInteractionKind.LINK && it.onClick != null &&
                    it.start >= first && it.end <= end }
                assertEquals(2, actions.size)
                for (link in links) {
                    val node = actions.single { geometry.text.subSequence(it.start, it.end).toString() == link.text }
                    assertTrue(node.start >= at && node.bounds.any { !it.isEmpty })
                    assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                }
                assertEquals(2, navigations)
                assertEquals(listOf(links.first().entryLink()), calls)
            }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
            temp.deleteRecursively()
        }
    }

    @Test fun historicalEmptyEdgePreservesCaretFontStrutInkAndSingleFollowingAction() {
        val data = InstrumentationRegistry.getInstrumentation().context.assets.open("sr-empty/typed-empty-top.dpry")
            .use { it.readBytes() }
        assertEquals("c84901321da9241260dac11ff6ad86464d9af7149db9f0f3c41b1235aaac7628",
            MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) })
        val spans = BlobDecoder.decode(data, "box", "supplemental", null, "").displayTitle
        val edge = spans[1]
        val group = checkNotNull(edge.inlineBoxGroup)
        assertTrue(group.isEmptyTopEdge)
        assertEquals(listOf("ひ", "", "[hì]", "Heiban"), spans.map { it.text })
        assertEquals(listOf("平板型"), spans.filter { it.kind == "link" }.map { it.target })
        assertEquals(listOf("ひ", "[hì]", "Heiban"), rubyFallbackSpans(spans).map { it.text })
        assertThrows(IllegalArgumentException::class.java) { edge.copy(kind = "link", target = "invented") }
        assertThrows(IllegalArgumentException::class.java) { edge.copy(tooltip = "invented") }
        assertThrows(IllegalArgumentException::class.java) { group.copy(border = group.border.copy(top = InlineBoxBorderEdge.None)) }
        assertThrows(IllegalArgumentException::class.java) { group.copy(border = group.border.copy(left = group.border.top)) }
        assertThrows(IllegalArgumentException::class.java) {
            group.copy(padding = group.padding.copy(left = StyleLength(StyleLengthUnit.Px, 1f)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            Span("link", "", "nested", inlineActionGroup = InlineActionGroup(listOf(edge)))
        }
        val projection = rubyGraphicalProjection(spans)
        val range = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        assertEquals(1 to 1, range.start to range.end)
        val key = NativeInlineBoxOwner(edge, range.path)
        val direction = TextDirectionHeuristics.LTR
        for (size in listOf(16f, 24f)) {
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                textSize = size; textLocale = Locale.JAPANESE; color = Color.rgb(15, 72, 104)
            }
            val zero = NativeInlineBoxBorder(0f, Color.TRANSPARENT)
            val top = NativeInlineBoxBorder(1f, paint.color)
            val box = NativeInlineBoxFormat(key, NativeInlineBoxEdges(0f, 0f, 0f, 0f),
                NativeInlineBoxBorders(top, zero, zero, zero), emptyList())
            val policy = NativeLineHeightPolicy.Normal
            fun source(withBorder: Boolean): Spanned {
                val text = SpannableString(projection.text)
                text.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), policy, strut = true),
                    0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (withBorder) {
                    val prepared = NativeRubyPreparedSource(projection, SpannedString(text), paint, direction,
                        mapOf(range.path to NativeRubyGroupFormat(paint, direction, policy, box = box)))
                    text.setSpan(prepared, 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                return SpannedString(text)
            }
            val decorated = NativeFloatGeometry.build(source(true), paint, 250, emptyList(), textDirection = direction)
            val plain = NativeFloatGeometry.build(source(false), paint, 250, emptyList(), textDirection = direction)
            assertEquals(plain.text.toString(), decorated.text.toString())
            val border = checkNotNull(decorated.inlineBoxGroupRects(key, 1, 1)).single()
            assertEquals(0f, border.width(), 0f)
            assertEquals(decorated.caretRect(1).left, border.left, .01f)
            val primary = NativePrimaryFontMetrics.from(paint)
            assertEquals(primary.descent - primary.ascent + 1f, border.height(), .01f)
            assertEquals(decorated.nativeRubyLineBaseline(0) + primary.ascent - 1f, border.top, .01f)
            assertEquals(plain.height, decorated.height)
            for (i in 0..projection.text.length) assertEquals(plain.caretRect(i), decorated.caretRect(i))
            val actual = Bitmap.createBitmap(decorated.width, decorated.height, Bitmap.Config.ARGB_8888)
            val control = Bitmap.createBitmap(plain.width, plain.height, Bitmap.Config.ARGB_8888)
            try {
                plain.paint(Canvas(control)); decorated.paint(Canvas(actual))
                assertTrue((0 until actual.height).any { y -> (0 until actual.width).any { x -> Color.alpha(actual.getPixel(x, y)) > 0 } })
                assertTrue(actual.sameAs(control))
            } finally { actual.recycle(); control.recycle() }
        }
        val calls = mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") { Surface { StyledText(spans, onLink = { calls += it }) } }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                val owners = mutableListOf<NativeFloatTextView>()
                fun visit(view: View) {
                    if (view is NativeFloatTextView && view.logicalText.toString() == projection.text) owners += view
                    if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
                }
                visit(compose.activity.window.decorView)
                val view = owners.single()
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val node = geometry.nodes.single()
                assertEquals(FloatInteractionKind.LINK, node.kind)
                assertEquals("Heiban", geometry.text.subSequence(node.start, node.end).toString())
                assertTrue(node.bounds.any { !it.isEmpty })
                view.setSelection(0, projection.text.length)
                assertEquals("ひ[hì]Heiban", view.selectedTextForCopy())
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink("平板型")), calls)
            }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }
}
