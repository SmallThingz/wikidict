package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class NativeInlineBoxSourceTreeDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(amount: Int) = StyleLength(StyleLengthUnit.Px, amount.toFloat())
    private val none = InlineBoxBorderEdge.None
    private fun wrap(children: List<Span>, left: Int = 0, right: Int = 0,
        bottom: InlineBoxBorderEdge = none) = Span("text", "", inlineBoxGroup = InlineBoxGroup(
            StyleEdges(px(0), px(right), px(0), px(left)), InlineBoxBorderEdges(none, none, bottom, none), spans = children))
    private fun help() = wrap(listOf(Span("text", "c", italic = true)), bottom =
        InlineBoxBorderEdge.Dotted(px(1), InlineBoxColor.Rgb("#000000"))).copy(
            tooltip = "Cantonese", inlineStyle = InlineTextStyle(cursor = InlineCursor.Help))
    private fun link(label: String, lang: String, script: String) = Span("link", label, target = label,
        targetFragment = "Chinese", language = lang, classes = script)
    private fun classifier(): Span {
        val tips = listOf(help(), help())
        val gap = wrap(listOf(Span("text", "\u00a0")), 4, 4)
        val fill = wrap(listOf(Span("text", "("), Span("text", "Класификатор", italic = true),
            Span("text", ": "), link("隻", "zh-Hant", "Hant"), Span("text", "／"), link("只", "zh", "Hani"),
            Span("text", " "), tips[0], Span("text", ";"), gap, link("個", "zh-Hant", "Hant"),
            Span("text", "／"), link("个", "zh-Hans", "Hans"), Span("text", " "), tips[1], Span("text", ")")))
            .copy(background = "#edffff")
        return wrap(listOf(fill), 15).copy(fontScale = .8f)
    }

    @Test fun coincidentClassifierPaintAndActionsKeepTheirOriginalOwners() {
        val spans = listOf(classifier())
        val calls = mutableListOf<EntryLink>()
        var prepared: PreparedNativeFloatText? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    val style = TextStyle(fontSize = 20.sp)
                    val annotated = styledTextAnnotation(spans, null, style) { calls += it }
                    val value = prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", { calls += it },
                        nativeLineHeight = NativeLineHeightPolicy.Normal, ownerDirection = BidiResolvedDirection.Ltr)
                    SideEffect { prepared = value }
                } }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                val width = 800
                val source = checkNotNull(value.native).source(width)
                val marker = source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).single()
                val geometry = checkNotNull(value.geometry)(width, emptyList(), false)
                val projection = marker.projection
                assertEquals("(Класификатор: 隻／只 c;\u00a0個／个 c)", geometry.text.toString())
                val boxes = projection.ranges.filter { it.role == RubyTextRole.BoxGroup }
                fun rect(r: RubyTextRange) = checkNotNull(geometry.inlineBoxGroupRects(
                    checkNotNull(marker.groups.getValue(r.path).box).owner, r.start, r.end)).single()
                val outer = rect(boxes.single { it.span === spans.single() })
                val fill = rect(boxes.single { it.span?.background == "#edffff" })
                assertEquals(15f, fill.left - outer.left, .01f)
                assertEquals(fill.right, outer.right, .01f)
                val ink = Bitmap.createBitmap(width, geometry.height, Bitmap.Config.ARGB_8888)
                try {
                    ink.eraseColor(Color.WHITE)
                    geometry.paint(Canvas(ink))
                    assertEquals(Color.WHITE, ink.getPixel((outer.left + 5).toInt(), fill.centerY().toInt()))
                    val gap = geometry.characterRects(geometry.text.indexOf('\u00a0'), 1).single()!!
                    assertEquals(Color.rgb(237, 255, 255), ink.getPixel(gap.centerX().toInt(), gap.centerY().toInt()))
                    val separator = rect(boxes.single { it.span?.inlineBoxGroup?.spans?.singleOrNull()?.text == "\u00a0" })
                    assertEquals(4f, gap.left - separator.left, .01f)
                    assertEquals(4f, separator.right - gap.right, .01f)
                    for (tip in boxes.filter { it.span?.tooltip == "Cantonese" }) {
                        val r = rect(tip)
                        assertEquals(InlineCursor.Help, geometry.cursorAt(r.centerX(), r.centerY()))
                        val bottom = (kotlin.math.ceil(r.bottom).toInt() - 1).coerceIn(0, ink.height - 1)
                        val edge = (kotlin.math.ceil(r.left).toInt() until r.right.toInt()).map { ink.getPixel(it, bottom) }
                        assertTrue(edge.any { Color.red(it) < 128 }); assertTrue(edge.any { Color.red(it) > 192 })
                        assertTrue(geometry.nodes.any { it.tooltip == "Cantonese" && it.start == tip.start && it.end == tip.end })
                    }
                } finally { ink.recycle() }
                val links = geometry.nodes.filter { it.onClick != null }.sortedBy { it.start }
                assertEquals(listOf("隻", "只", "個", "个"), links.map { it.label.toString() })
                links.forEach { checkNotNull(it.onClick).invoke() }
                assertEquals(listOf("隻", "只", "個", "个").map { EntryLink(it, "Chinese") }, calls)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun coincidentThreeLevelBoxesShareBaselineAndKeepDifferentFontStruts() {
        val labels = wrap(listOf(Span("text", "Example", italic = true)), 2, 3).copy(fontScale = 1.5f)
        val fill = wrap(listOf(labels), 5).copy(background = "#edffff")
        val outer = wrap(listOf(fill), 15)
        val spans = listOf(outer)
        var prepared: PreparedNativeFloatText? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    val style = TextStyle(fontSize = 20.sp)
                    val annotation = styledTextAnnotation(spans, null, style) {}
                    val value = prepareNativeFloatText(spans, annotation, egyptianTextRuns(spans), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", {},
                        nativeLineHeight = NativeLineHeightPolicy.Normal, ownerDirection = BidiResolvedDirection.Ltr)
                    SideEffect { prepared = value }
                } }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                val source = checkNotNull(value.native).source(600)
                val marker = source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).single()
                val geometry = checkNotNull(value.geometry)(600, emptyList(), false)
                val baseline = geometry.baselineForOffset(0)
                val rects = listOf(outer, fill, labels).map { owner ->
                    val range = marker.projection.ranges.single { it.span === owner }
                    val format = marker.groups.getValue(range.path)
                    val metrics = NativePrimaryFontMetrics.from(format.paint)
                    val bounds = checkNotNull(geometry.inlineBoxGroupRects(checkNotNull(format.box).owner,
                        range.start, range.end)).single()
                    assertEquals(baseline + metrics.ascent, bounds.top, .01f)
                    assertEquals(baseline + metrics.descent, bounds.bottom, .01f)
                    bounds
                }
                assertEquals(15f, rects[1].left - rects[0].left, .01f)
                assertEquals(5f, rects[2].left - rects[1].left, .01f)
                assertTrue(rects[2].top < rects[1].top && rects[2].bottom > rects[1].bottom)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }
}
