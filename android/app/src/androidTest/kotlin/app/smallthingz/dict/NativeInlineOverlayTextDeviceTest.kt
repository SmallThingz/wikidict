package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic native source/geometry controls; these do not qualify a producer page. */
@RunWith(AndroidJUnit4::class)
class NativeInlineOverlayTextDeviceTest {
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val one = StyleLength(StyleLengthUnit.Px, 1f)
    private val none = InlineBoxBorderEdge.None
    private val noBorders = InlineBoxBorderEdges(none, none, none, none)
    private val ownerBorders = InlineBoxBorderEdges(InlineBoxBorderEdge.Solid(one, InlineBoxColor.Rgb("#000000")), none, none, none)
    private fun paint(size: Float = 24f, color: Int = Color.BLUE) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE; textSize = size; this.color = color
    }
    private fun text(value: String, size: Float = 24f, color: String = "#0000ff") =
        Span("text", value, fontScale = size, fontScaleBasis = FontScaleBasis.CssPx, foreground = color)
    private fun overlay(value: String, at: Long = 1, size: Float = 24f, lineHeight: Float? = null,
        alignment: InlineBoxOverlayTextAlign = InlineBoxOverlayTextAlign.Start,
        insets: InlineBoxInsets = InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            bottom = InlineBoxInset(StyleWidthUnit.Percent, 67f), right = InlineBoxInset(StyleWidthUnit.Percent, 0f))) =
        InlineBoxOverlay(insets, InlineBoxBorderEdges(none,
            InlineBoxBorderEdge.Solid(one, InlineBoxColor.Rgb("#ff0000")), none, none),
            InlineBoxOverlayContent(at, InlineFontSnapshot(size, FontScaleBasis.CssPx, fontNormalized = true),
                lineHeight?.let { InlineLineHeight.Computed(InlineComputedLength(it, FontScaleBasis.CssPx)) },
                alignment, listOf(text(value, size, "#ff0000"))))
    private fun owner(overlays: List<InlineBoxOverlay>, children: List<Span> = listOf(text("スリ")), direction: String = "") =
        Span("text", "", fontScale = 24f, fontScaleBasis = FontScaleBasis.CssPx, direction = direction,
            inlineStyle = InlineTextStyle(fontNormalized = true), inlineBoxGroup = InlineBoxGroup(
                StyleEdges(one, one, one, one), ownerBorders, overlays, children))
    private class SourcePaint(private val original: TextPaint) : MetricAffectingSpan(), NativeInlineSafePaintSpan {
        override fun updateMeasureState(paint: TextPaint) { paint.set(original) }
        override fun updateDrawState(paint: TextPaint) { paint.set(original) }
    }
    private data class Fixture(val original: List<Span>, val owner: Span, val key: NativeInlineBoxOwner,
        val range: RubyTextRange, val projection: RubyTextProjection, val prepared: NativeRubyPreparedSource,
        val source: Spanned, val paint: TextPaint, val direction: TextDirectionHeuristic) {
        fun build(width: Int, onAction: (Span) -> Unit = {}): NativeFloatGeometry = NativeFloatGeometry.build(source, paint, width, emptyList(),
            textDirection = direction, includeFontPadding = false, nodeFactory = { geometry ->
                projection.ranges.filter { it.span?.kind == "link" }.mapIndexed { id, range ->
                    val original = checkNotNull(range.span)
                    FloatInteractionNode(id, FloatInteractionKind.LINK, range.start, range.end,
                        geometry.rectsForRange(range.start, range.end), original.text, original.tooltip, { onAction(original) })
                }
            })
        fun bodies(): List<RubyTextRange> = projection.ranges.filter { it.role == RubyTextRole.OverlayContent }
        fun placed(geometry: NativeFloatGeometry, index: Int = 0) =
            checkNotNull(geometry.nativeRubyRaw.nativeInlineBoxOverlay(key, index))
    }
    private fun fixture(box: Span, before: List<Span> = emptyList(), after: List<Span> = emptyList(),
        direction: TextDirectionHeuristic = TextDirectionHeuristics.FIRSTSTRONG_LTR, zoom: Float = 1f): Fixture {
        val original = before + box + after
        val projection = rubyGraphicalProjection(original)
        val range = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        val key = NativeInlineBoxOwner(box, range.path)
        fun border(value: InlineBoxBorderEdge): NativeInlineBoxBorder = when (value) {
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.Hidden -> NativeInlineBoxBorder(0f, Color.TRANSPARENT)
            is InlineBoxBorderEdge.Solid -> NativeInlineBoxBorder(value.width.value * zoom, Color.parseColor((value.color as InlineBoxColor.Rgb).value))
            is InlineBoxBorderEdge.Dotted -> error("No synthetic dotted border")
        }
        fun borders(value: InlineBoxBorderEdges) = NativeInlineBoxBorders(border(value.top), border(value.right), border(value.bottom), border(value.left))
        fun inset(value: InlineBoxInset?): NativeInlineBoxInset? = value?.let {
            NativeInlineBoxInset(if (it.unit == StyleWidthUnit.Percent) it.value else it.value * zoom,
                it.unit == StyleWidthUnit.Percent)
        }
        val nativeBox = checkNotNull(box.inlineBoxGroup).let { group -> NativeInlineBoxFormat(key,
            NativeInlineBoxEdges(zoom, zoom, zoom, zoom), borders(group.border), group.overlays.map { value ->
                NativeInlineBoxOverlay(NativeInlineBoxInsets(inset(value.insets.top), inset(value.insets.right),
                    inset(value.insets.bottom), inset(value.insets.left)), borders(value.border))
            }) }
        val root = paint(24f * zoom)
        val groups = projection.ranges.filter { it.role == RubyTextRole.BoxGroup || it.role == RubyTextRole.OverlayContent }
            .associate { part ->
                val content = part.overlayContent
                part.path to if (content == null) NativeRubyGroupFormat(root, direction, NativeLineHeightPolicy.Pixels(24f * zoom),
                    sourceDirection = box.direction, box = nativeBox)
                else NativeRubyGroupFormat(paint(content.ownerFont.fontScale!! * zoom, Color.RED), direction,
                    (content.lineHeight as? InlineLineHeight.Computed)?.let { NativeLineHeightPolicy.Pixels(it.value.value * zoom) }
                        ?: NativeLineHeightPolicy.Normal)
            }
        val logical = SpannableString(projection.text).apply {
            setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), NativeLineHeightPolicy.Pixels(24f * zoom), strut = true),
                0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            projection.ranges.filter { it.span != null && it.role != RubyTextRole.BoxGroup }.forEach { part ->
                val span = part.span!!
                setSpan(SourcePaint(paint((span.fontScale ?: 24f) * zoom, span.foreground?.let(Color::parseColor) ?: Color.BLUE)),
                    part.start, part.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        val prepared = NativeRubyPreparedSource(projection, SpannedString(logical), root, direction, groups)
        val source = SpannableString(logical).apply { setSpan(prepared, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
        return Fixture(original, box, key, range, projection, prepared, SpannedString(source), root, direction)
    }
    private fun sameRect(a: RectF, b: RectF) {
        assertEquals(a.left, b.left, .001f); assertEquals(a.top, b.top, .001f)
        assertEquals(a.right, b.right, .001f); assertEquals(a.bottom, b.bottom, .001f)
    }

    @Test fun zwspKeepsItsRealFontLineAndSourceWithoutNormalAdvanceOrManufacturedGlyphs() {
        for (size in listOf(12f, 24f, 36f)) for (height in listOf<Float?>(null, 0f, 48f)) {
            val source = owner(listOf(overlay("\u200b", size = size, lineHeight = height)))
            val value = fixture(source, listOf(text("ク")), listOf(text("ユビ")))
            val current = value.build(320)
            val oldBox = source.copy(inlineBoxGroup = source.inlineBoxGroup!!.copy(
                overlays = source.inlineBoxGroup.overlays.map { it.copy(content = null) }))
            val legacy = fixture(oldBox, listOf(text("ク")), listOf(text("ユビ"))).build(320)
            assertEquals("クスリ\u200bユビ", current.text.toString())
            assertFalse(current.nativeRubyRaw.text.contains('\u200b'))
            assertEquals(legacy.nativeRubyRaw.text.toString(), current.nativeRubyRaw.text.toString())
            assertEquals(legacy.nativeLineAdvance(0), current.nativeLineAdvance(0), .001f)
            assertEquals(legacy.textBottom, current.textBottom, .001f)
            val detached = value.placed(current)
            assertEquals("\u200b", detached.geometry.text.toString())
            assertEquals(0f, detached.geometry.nativeLineAdvance(0), .001f)
            assertEquals(size, detached.source.paint.textSize, 0f)
            assertEquals(if (height == null) NativeLineHeightPolicy.Normal else NativeLineHeightPolicy.Pixels(height), detached.source.lineHeight)
            val expectedSource = SpannableString("\u200b").apply {
                setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint(size)), detached.source.lineHeight,
                    strut = true, includePrimaryInNormal = true, independentNormalStrut = true), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val reference = NativeFloatGeometry.build(expectedSource, paint(size), 0, emptyList(),
                textDirection = TextDirectionHeuristics.LTR, includeFontPadding = false, exactAvailableWidth = 0f)
            assertEquals(reference.textBottom, detached.geometry.textBottom, .001f)
            val range = value.bodies().single()
            sameRect(RectF(reference.caretRect(0)).apply { offset(detached.x, detached.y) }, current.caretRect(range.start))
            sameRect(RectF(reference.caretRect(1)).apply { offset(detached.x, detached.y) },
                current.caretRect(NativeTextCaret(range.end, NativeTextAffinity.Upstream)))
            assertEquals(listOf(range.start to range.end), current.visualLineRanges(range.start))
            if (height == 48f) assertTrue(detached.geometry.textBottom > detached.placement.contentHeight)
        }
    }

    @Test fun completeScopeDirectionAndIndependentAlignmentDoNotUseDetachedFirstStrong() {
        val rightward = InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, -8f),
            left = InlineBoxInset(StyleWidthUnit.Px, -4f), right = InlineBoxInset(StyleWidthUnit.Px, -20f))
        for (rtl in listOf(false, true)) for (alignment in InlineBoxOverlayTextAlign.entries) {
            val body = if (rtl) "ABC" else "אבג"
            val box = owner(listOf(overlay(body, size = 12f, lineHeight = 36f, alignment = alignment, insets = rightward)),
                direction = if (rtl) "rtl" else "ltr")
            val value = fixture(box, listOf(text(if (rtl) "outer LTR " else "אב ")))
            val geometry = value.build(400)
            val placed = value.placed(geometry)
            assertEquals(rtl, placed.source.rtl)
            assertEquals(if (rtl) -1 else 1, placed.geometry.nativeRubyParagraphDirection)
            assertEquals(36f, placed.geometry.textBottom, .001f)
            val range = value.bodies().single()
            assertEquals(body, geometry.text.subSequence(range.start, range.end).toString())
            val rects = placed.geometry.rectsForRange(0, body.length)
            assertTrue(rects.isNotEmpty())
            rects.zip(geometry.rectsForRange(range.start, range.end)).forEach { (local, public) ->
                sameRect(RectF(local).apply { offset(placed.x, placed.y) }, public)
            }
            val border = checkNotNull(geometry.inlineBoxGroupRects(value.key, value.range.start, value.range.end)).single()
            assertEquals(border.left - 4f, placed.placement.border.left, .001f)
            assertEquals(border.right + 20f, placed.placement.border.right, .001f)
            assertEquals(border.top + 1f - 8f, placed.placement.border.top, .001f)
            val advance = placed.geometry.nativeLineAdvance(0)
            val available = placed.placement.contentWidth
            val expectedLeft = when (alignment) {
                InlineBoxOverlayTextAlign.Left -> 0f
                InlineBoxOverlayTextAlign.Right -> available - advance
                InlineBoxOverlayTextAlign.Center -> (available - advance) / 2f
                InlineBoxOverlayTextAlign.Start -> if (rtl) available - advance else 0f
            }
            assertEquals(expectedLeft, checkNotNull(placed.geometry.nativeRubyLineAdvanceBounds(0)).left, .001f)
        }
        // A native paragraph's first strong normal-flow text wins even when a Hebrew
        // detached body occurs first in source order. The converse uses the same full paragraph.
        for (prefix in listOf("English ", "אב ", "English\nאב ", "אב\nEnglish ")) {
            val paragraph = prefix.substringAfterLast('\n')
            val expectedRtl = !paragraph.startsWith("E")
            val box = owner(listOf(overlay(if (expectedRtl) "ABC" else "אב", at = 0)),
                children = listOf(text("...")))
            val value = fixture(box, listOf(text(prefix)))
            val geometry = value.build(400)
            assertEquals(expectedRtl, value.placed(geometry).source.rtl)
            val explicit = fixture(box.copy(direction = if (expectedRtl) "rtl" else "ltr"),
                listOf(text(prefix)))
            sameRect(value.placed(geometry).geometry.caretRect(0),
                explicit.placed(explicit.build(400)).geometry.caretRect(0))
        }
    }

    @Test fun spanningCitationIsolateDoesNotClassifyTheFollowingExternalParagraph() {
        for (isolatedRtl in listOf(false, true)) {
            val label = if (isolatedRtl) "אב\nאב " else "English\nEnglish "
            val marker = text(label).copy(kind = "link", target = "", role = "reference",
                targetFragment = "reference-1", citationMarker = CitationMarker(1L, 1L,
                    "cite-note-1-1", nowrap = false,
                    isolation = if (isolatedRtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr))
            val external = text(if (isolatedRtl) "English " else "אב ")
            val box = owner(listOf(overlay(if (isolatedRtl) "אב" else "English", at = 0)),
                children = listOf(text("...")))
            val value = fixture(box, before = listOf(marker, external))
            val geometry = value.build(600)
            val raw = geometry.nativeRubyRaw
            val expectedRtl = !isolatedRtl
            assertEquals(if (expectedRtl) -1 else 1, raw.nativeRubyLineDirection(raw.nativeLineAt(raw.text.length)))
            assertEquals(expectedRtl, value.placed(geometry).source.rtl)
            assertEquals(label + external.text + box.inlineBoxGroup!!.overlays.single().content!!.spans.single().text + "...",
                geometry.text.toString())
            assertSame(marker, value.projection.ranges.single { it.span === marker }.span)
            assertEquals(CitationMarker(1L, 1L, "cite-note-1-1", false,
                if (isolatedRtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr), marker.citationMarker)
        }
    }

    @Test fun ordinaryHardBreakIsolatesReopenOnlyForDetachedOverlayParagraphOwnership() {
        for (isolatedRtl in listOf(false, true)) {
            val label = if (isolatedRtl) "אב\nאב " else "English\nEnglish "
            val isolated = text(label).copy(direction = if (isolatedRtl) "rtl" else "ltr")
            val external = text(if (isolatedRtl) "English " else "אב ")
            val box = owner(listOf(overlay("\u200b", at = 0)), children = listOf(text("...")))
            val value = fixture(box, before = listOf(isolated, external))
            val geometry = value.build(600)
            val raw = geometry.nativeRubyRaw
            val expectedRtl = !isolatedRtl
            assertEquals(if (expectedRtl) -1 else 1, raw.nativeRubyLineDirection(raw.nativeLineAt(raw.text.length)))
            assertEquals(expectedRtl, value.placed(geometry).source.rtl)
            assertEquals(2, raw.text.count { it == if (isolatedRtl) '\u2067' else '\u2066' })
            assertEquals(label + external.text + "\u200b...", geometry.text.toString())
            assertSame(isolated, value.projection.ranges.single { it.span === isolated }.span)
            val absent = box.copy(inlineBoxGroup = box.inlineBoxGroup!!.copy(
                overlays = box.inlineBoxGroup.overlays.map { it.copy(content = null) }))
            val legacy = fixture(absent, before = listOf(isolated, external)).build(600)
            assertEquals(label + external.text + "...", legacy.text.toString())
            assertEquals(1, legacy.nativeRubyRaw.text.count { it == if (isolatedRtl) '\u2067' else '\u2066' })
        }
    }

    @Test fun detachedInkAndSelectionOverflowRemainVisibleAcrossMeasuredLtrWrappingAndResize() {
        val value = fixture(owner(listOf(overlay("MMMM", size = 24f, lineHeight = 64f))))
        val geometry = value.build(320)
        val placed = value.placed(geometry)
        assertTrue(placed.geometry.textBottom > placed.placement.contentHeight)
        val surface = NativeSurfaceBox.from(geometry.extents)
        val bitmap = Bitmap.createBitmap(surface.width + 8, surface.height + 8, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.translate(4f - surface.left, 4f - surface.top)
            geometry.paint(canvas)
            var outside = 0
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (Color.red(pixel) > 0 && Color.green(pixel) == 0 && Color.blue(pixel) == 0 &&
                    y + surface.top - 4f >= placed.placement.border.bottom) outside++
            }
            assertTrue("Real glyph ink is not clipped to the percentage-height border", outside > 0)
        } finally { bitmap.recycle() }
        val range = value.bodies().single()
        assertTrue(geometry.rectsForRange(range.start, range.end).any { it.bottom > placed.placement.border.bottom })
        val edgeOrders = mutableSetOf<Boolean>()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        for (zoom in listOf(.75f, 1f, 1.5f, 2f)) for (prefix in listOf("", "AAA ")) {
            val box = owner(listOf(overlay("\u200b")), children = listOf(text("スリ")), direction = "ltr")
            val current = fixture(box, before = listOf(text(prefix)), after = listOf(text("ユビ")), zoom = zoom)
            val nullBox = box.copy(inlineBoxGroup = box.inlineBoxGroup!!.copy(
                overlays = box.inlineBoxGroup.overlays.map { it.copy(content = null) }))
            val legacy = fixture(nullBox, before = listOf(text(prefix)), after = listOf(text("ユビ")), zoom = zoom)
            for (cssWidth in listOf(400, 60, 80, 96, 140, 400)) {
                val width = (cssWidth * zoom).toInt()
                val layout = current.build(width)
                val baseline = legacy.build(width)
                val fragments = checkNotNull(layout.inlineBoxGroupRects(current.key, current.range.start, current.range.end))
                assertTrue(fragments.isNotEmpty())
                val first = fragments.first(); val last = fragments.last()
                val detached = current.placed(layout)
                val expectedRight = maxOf(first.left, last.right)
                assertEquals(first.top + zoom, detached.placement.border.top, .001f)
                assertEquals(expectedRight, detached.placement.border.right, .001f)
                assertEquals((last.bottom - first.top - zoom) * .33f,
                    detached.placement.border.bottom - detached.placement.border.top, .002f)
                if (fragments.size > 1) edgeOrders += last.right < first.left
                assertEquals(baseline.nativeRubyRaw.text.toString(), layout.nativeRubyRaw.text.toString())
                assertEquals(baseline.textBottom, layout.textBottom, .001f)
                for (line in 0..layout.nativeRubyRaw.nativeLineAt(layout.nativeRubyRaw.text.length)) {
                    assertEquals(baseline.nativeLineAdvance(line), layout.nativeLineAdvance(line), .001f)
                }
                assertEquals(prefix + "スリ\u200bユビ", layout.text.toString())
                val body = current.bodies().single()
                val token = NativeTextCaret(body.end, NativeTextAffinity.Upstream)
                sameRect(RectF(detached.geometry.caretRect(NativeTextCaret(1, NativeTextAffinity.Upstream)))
                    .apply { offset(detached.x, detached.y) }, layout.caretRect(token))
                assertEquals(listOf(body.start to body.end), layout.visualLineRanges(token))
                instrumentation.runOnMainSync {
                    val view = NativeFloatTextView(instrumentation.targetContext)
                    view.bind({ layout }, 0x6633b5e5, 0xff1686c7.toInt())
                    view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                        View.MeasureSpec.makeMeasureSpec(2000, View.MeasureSpec.AT_MOST))
                    view.layout(0, 0, view.measuredWidth, view.measuredHeight)
                    view.setSelection(0, layout.text.length)
                    assertEquals(layout.text.toString(), view.selectedTextForCopy())
                    val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID))
                    try { assertEquals(layout.text.toString(), info.text.toString()) } finally { info.recycle() }
                }
            }
        }
        assertEquals(setOf(false, true), edgeOrders)
        val unsupported = fixture(owner(listOf(overlay("\u200b")),
            children = listOf(text("אבאבאבאבאבאב")), direction = "rtl"))
        assertThrows(UnsupportedFloatLayout::class.java) { unsupported.build(42) }
        assertEquals("אבאבאבאבאבאב\u200b", unsupported.build(400).text.toString())
    }

    @Test fun completeAnonymousParagraphAndBulletScopeOwnBoxProgressionAndDetachedDirection() {
        for (kind in listOf("paragraph", "list_item")) {
            fun make(explicit: Boolean): Pair<NativeAnonymousFlowGeometry, RubyTextRange> {
                val value = fixture(owner(listOf(overlay("\u200b")), direction = if (explicit) "ltr" else ""),
                    before = listOf(text("ク")), after = listOf(text("ユビ\n"),
                        Span("link", "IPA", "IPA"), text(" italic").copy(italic = true)),
                    direction = TextDirectionHeuristics.FIRSTSTRONG_RTL)
                val block = Block(kind, if (kind == "paragraph") 0 else 1, emptyList(),
                    listPath = if (kind == "paragraph") "" else "*", flow = listOf(FlowPart.Scope(
                        BidiScope(BidiMode.Isolate, BidiDirectionInput.Auto, BidiResolvedDirection.Ltr, null,
                            listOf(FlowPart.Inline(value.original))))))
                val content = anonymousFlowContent(block, AnonymousFlowContext(BidiResolvedDirection.Rtl, "ja", null))
                val geometry = NativeAnonymousFlowGeometry.build(content, value.paint, 320,
                    inline = { event ->
                        assertEquals(BidiResolvedDirection.Ltr, event.context.direction)
                        assertNotNull(event.containingScopeId)
                        value.source
                    }, figure = { _, _ -> error("No figure in the authenticated whole paragraph") })
                assertEquals(value.projection.text, geometry.text.toString())
                return geometry to value.bodies().single()
            }
            val (inherited, body) = make(false)
            val (explicit, ownBody) = make(true)
            assertEquals(body.start to body.end, ownBody.start to ownBody.end)
            assertEquals("クスリ\u200bユビ\nIPA italic", inherited.text.toString())
            sameRect(explicit.caretRect(ownBody.start), inherited.caretRect(body.start))
            sameRect(explicit.caretRect(NativeTextCaret(ownBody.end, NativeTextAffinity.Upstream)),
                inherited.caretRect(NativeTextCaret(body.end, NativeTextAffinity.Upstream)))
            assertEquals(explicit.rectsForRange(0, explicit.text.length), inherited.rectsForRange(0, inherited.text.length))
        }
    }

    @Test fun realViewKeepsBoundaryAffinityCopyAndAccessibilityAcrossTwoDetachedOccurrences() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val action = Span("link", "tail", "Original action", targetFragment = "section", tooltip = "unchanged hint")
            val actions = mutableListOf<Span>()
            val value = fixture(owner(listOf(overlay("\u200b"), overlay("\ud83d\ude00", at = 1,
                insets = InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, -40f), right = InlineBoxInset(StyleWidthUnit.Px, -30f)))),
                children = listOf(text("AB"), text("CD"))), after = listOf(action))
            val geometry = value.build(320) { actions += it }
            val view = NativeFloatTextView(instrumentation.targetContext)
            view.bind({ geometry }, 0x6633b5e5, 0xff1686c7.toInt())
            view.measure(View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.AT_MOST))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            val bodies = value.bodies()
            val first = bodies.first(); val second = bodies.last()
            assertEquals("AB\u200b\ud83d\ude00CDtail", geometry.text.toString())
            val upstream = NativeTextCaret(first.start, NativeTextAffinity.Upstream)
            val downstream = NativeTextCaret(first.start)
            assertNotEquals(geometry.caretRect(upstream), geometry.caretRect(downstream))
            view.setSelection(upstream, upstream)
            fun right() = view.onKeyDown(KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_RIGHT))
            assertTrue(right())
            assertEquals(downstream, view.selectionExtentCaret)
            assertTrue(right())
            assertEquals(NativeTextCaret(first.end, NativeTextAffinity.Upstream), view.selectionExtentCaret)
            assertTrue(right())
            assertEquals(NativeTextCaret(second.start), view.selectionExtentCaret)
            assertTrue(right())
            assertEquals(NativeTextCaret(second.end, NativeTextAffinity.Upstream), view.selectionExtentCaret)
            assertTrue(view.onKeyDown(KeyEvent.KEYCODE_MOVE_HOME,
                KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MOVE_HOME)))
            assertEquals(NativeTextCaret(second.start), view.selectionExtentCaret)
            assertTrue(view.onKeyDown(KeyEvent.KEYCODE_MOVE_END,
                KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MOVE_END)))
            assertEquals(NativeTextCaret(second.end, NativeTextAffinity.Upstream), view.selectionExtentCaret)
            assertTrue(right())
            assertEquals(NativeTextCaret(second.end), view.selectionExtentCaret)
            val caret = geometry.caretRect(NativeTextCaret(second.end, NativeTextAffinity.Upstream))
            assertEquals(NativeTextCaret(second.end, NativeTextAffinity.Upstream), geometry.caretAt(caret.left, caret.centerY()))
            view.setSelection(0, geometry.text.length)
            assertEquals("AB\u200b\ud83d\ude00CDtail", view.selectedTextForCopy())
            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID))
            try { assertEquals("AB\u200b\ud83d\ude00CDtail", info.text.toString()) } finally { info.recycle() }
            assertTrue(view.accessibilityNodeProvider.performAction(geometry.nodes.single().id, AccessibilityNodeInfo.ACTION_CLICK, null))
            assertSame(action, actions.single())
            assertEquals(EntryLink("Original action", "section"), actions.single().entryLink())
            val firstRect = geometry.characterRects(second.start, 2)
            assertEquals(firstRect[0], firstRect[1])
            // Native row end 2 is followed by source-only detached text. A hit
            // on that row must not remap to the next normal source piece at 3.
            val wrapped = fixture(owner(listOf(overlay("\u200b", insets = InlineBoxInsets(
                top = InlineBoxInset(StyleWidthUnit.Px, -60f), right = InlineBoxInset(StyleWidthUnit.Px, -100f)))),
                children = listOf(text("AB"))), after = listOf(text("CD")))
            val wrappedGeometry = wrapped.build(32)
            val raw = wrappedGeometry.nativeRubyRaw
            assertEquals(2, raw.nativeRangeOfLine(0).second)
            val band = wrappedGeometry.rectsForRange(0, 2).last()
            val hit = wrappedGeometry.caretAt(band.right - .1f, band.centerY())
            assertEquals(NativeTextCaret(2, NativeTextAffinity.Upstream), hit)
            val expectedCaret = checkNotNull(raw.nativeRubyLineCaret(0, 2))
            sameRect(expectedCaret, wrappedGeometry.caretRect(hit))
            assertNotEquals(wrappedGeometry.caretRect(NativeTextCaret(3)), wrappedGeometry.caretRect(hit))
        }
    }
    @Test fun positionedImageHitKeepsItsOwnUpstreamCaretWhenItOverlapsTheFollowingRow() {
        val image = object : android.text.style.ReplacementSpan(), NativeFloatInlineImage, NativeNoWrapInlineImage {
            override val nativeImageId = 82
            override val nativeImageSourceOffset = 0
            override val nativeImageWidth = 40f
            override val nativeImageHeight = 20f
            override val nativeImageOccurrence = NativeImageOccurrencePlacement(0f, 24f, 0f, 0f)
            override val nativeUsedMetrics = NativeUsedLineMetrics(-4f, 16f)
            override val nativeImageInkBounds = NativeFloatBounds(0f, 0f, 40f, 20f)
            override fun nativePaintBounds(lineTop: Float, lineBottom: Float) = nativeImageInkBounds.translated(0f, -4f)
            override fun drawNativeImage(canvas: Canvas, outer: RectF) {}
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                fm: Paint.FontMetricsInt?): Int = error("Positioned images retain fractional row ownership")
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
                x: Float, top: Int, y: Int, bottom: Int, paint: Paint) = error("Native row owns image paint")
        }
        val source = SpannableString("\ufffcA").apply {
            setSpan(image, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val geometry = NativeFloatGeometry.build(source, paint(), 40, emptyList(),
            textDirection = TextDirectionHeuristics.LTR, includeFontPadding = false)
        assertTrue(geometry is NativeFloatRowGeometry)
        assertEquals(0 to 1, geometry.nativeRangeOfLine(0))
        assertEquals(1 to 2, geometry.nativeRangeOfLine(1))
        val bounds = geometry.rectsForRange(0, 1).single()
        assertTrue(bounds.centerY() >= geometry.nativeRubyLineTop(1))
        val caret = geometry.caretAt(bounds.right - .25f, bounds.centerY())
        assertEquals(NativeTextCaret(1, NativeTextAffinity.Upstream), caret)
        sameRect(RectF(bounds.right, bounds.top, bounds.right + 1f, bounds.bottom), geometry.caretRect(caret))
        assertNotEquals(geometry.caretRect(NativeTextCaret(1)), geometry.caretRect(caret))
    }
}
