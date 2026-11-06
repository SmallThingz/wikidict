package app.smallthingz.dict

import android.graphics.RectF
import android.text.Layout
import android.text.SpannableString
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Private E controls. These exercise native geometry; genuine EU rendering is a separate required run. */
@RunWith(AndroidJUnit4::class)
class NativeFloatContextGeometryTest {
    private val paint = TextPaint().apply { textSize = 20f }
    private fun paragraph(text: String, rtl: Boolean = false, alignment: Layout.Alignment = Layout.Alignment.ALIGN_NORMAL,
        action: (() -> Unit)? = null) = NativeFloatContextPart.Text(text, { width, carried ->
        NativeFloatGeometry.build(SpannableString(text), paint, width, emptyList(), alignment = alignment,
            textDirection = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            carriedExclusions = carried, nodeFactory = { geometry ->
                if (action == null) emptyList() else listOf(FloatInteractionNode(1, FloatInteractionKind.LINK, 0, text.length,
                    geometry.rectsForRange(0, text.length), text, null, action))
            })
    })
    private fun table(id: Int = 1, side: TableFloatSide = TableFloatSide.Right, width: Float = 80f, height: Float = 100f,
        margin: Float = 20f) = NativeFloatContextPart.Child(id, NativeBlockWidth.FixedPx(width),
        { request -> assertEquals(width, request.requestedWidth); NativeBlockMeasure(width, width, height) },
        floatSide = side, margins = if (side == TableFloatSide.Right) FloatMargins(0f, 0f, 0f, margin)
            else FloatMargins(0f, margin, 0f, 0f))

    @Test fun physicalRightTableWrapsFollowingParagraphsWithoutInventedBodyGapAndReflowsOnResize() {
        val body = "one two three four five six seven eight nine ten eleven twelve"
        for (width in listOf(240, 320, 640)) for (rtl in listOf(false, true)) {
            val context = NativeFloatContextGeometry.build(width, listOf(table(), paragraph(body, rtl), paragraph("after", rtl)))
            val child = context.children.single()
            assertEquals(width - 80f, child.bounds.left, .01f)
            assertEquals(0f, child.bounds.top, .01f)
            assertEquals("\ufffc\n$body\nafter", context.text.toString())
            val first = context.characterRects(2, 1).single()!!
            assertTrue(first.top < child.bounds.bottom)
            assertTrue(first.right <= child.bounds.left - 20f + .1f)
            context.characterRects(2, body.length).filterNotNull().forEach { rect ->
                assertFalse("Body ink overlaps the table", RectF.intersects(rect, child.bounds))
            }
            assertTrue(context.height >= 100)
        }
    }

    @Test fun sameSideAndOpposingTablesKeepSourceOrderAndContainOnlyAtContextEnd() {
        val context = NativeFloatContextGeometry.build(240, listOf(table(1), table(2), paragraph("Following body")))
        val first = context.children[0].bounds; val second = context.children[1].bounds
        assertTrue(second.top >= first.top)
        assertFalse(RectF.intersects(first, second))
        // Two margin boxes fit side by side; forcing a clear would add an unjustified 100px gap.
        assertEquals(0f, second.top, .01f)
        val opposing = NativeFloatContextGeometry.build(240, listOf(table(1), table(2, TableFloatSide.Left), paragraph("word")))
        assertEquals(0f, opposing.children[1].bounds.left, .01f)
        assertEquals(160f, opposing.children[0].bounds.left, .01f)
    }

    @Test fun fullWidthFollowingTableMovesBelowOnlyTheBlockingMarginBox() {
        val context = NativeFloatContextGeometry.build(240, listOf(table(),
            NativeFloatContextPart.Child(2, NativeBlockWidth.FixedPx(240f), { NativeBlockMeasure(240f, 240f, 30f) }),
            paragraph("Tail")))
        assertEquals(100f, context.children[1].bounds.top, .01f)
        assertTrue(context.height >= 130)
    }

    @Test fun physicalParagraphAlignmentUsesAvailableFullBandEvenInRtl() {
        val left = NativeFloatGeometry.build(SpannableString("word"), paint, 240, emptyList(),
            alignment = Layout.Alignment.ALIGN_OPPOSITE, textDirection = TextDirectionHeuristics.RTL)
        val right = NativeFloatGeometry.build(SpannableString("word"), paint, 240, emptyList(),
            alignment = Layout.Alignment.ALIGN_NORMAL, textDirection = TextDirectionHeuristics.RTL)
        val center = NativeFloatGeometry.build(SpannableString("word"), paint, 240, emptyList(), alignment = Layout.Alignment.ALIGN_CENTER)
        val l = left.rectsForRange(0, 4).single(); val r = right.rectsForRange(0, 4).single(); val c = center.rectsForRange(0, 4).single()
        assertTrue(l.left < c.left && c.left < r.left)
        assertEquals(120f, c.centerX(), 1f)
    }

    @Test fun floatedContextLinksSelectionAccessibilityAndSupplementaryOffsetsRemainLogical() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            var clicked = 0
            val first = "Target"; val tail = "\ud83d\ude80 next"
            val geometry = NativeFloatContextGeometry.build(240, listOf(table(), paragraph(first, action = { clicked++ }), paragraph(tail)))
            val view = NativeFloatTextView(instrumentation.targetContext)
            view.bind({ geometry }, 0x6633b5e5, 0xff1686c7.toInt())
            view.measure(View.MeasureSpec.makeMeasureSpec(240, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.AT_MOST))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            val text = "\ufffc\n$first\n$tail"
            assertEquals(text, view.logicalText.toString())
            view.onKeyDown(KeyEvent.KEYCODE_A, KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, 0, KeyEvent.META_CTRL_ON))
            val info = view.accessibilityNodeProvider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID)!!
            assertEquals(text, info.text.toString()); assertEquals(text.length, info.textSelectionEnd)
            val node = geometry.nodes.single()
            assertEquals(2, node.start); assertEquals(8, node.end)
            assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
            assertEquals(1, clicked)
            val start = 2 + first.length + 1
            val boxes = geometry.characterRects(start, 2)
            assertNotNull(boxes[0]); assertEquals(boxes[0], boxes[1])
            assertEquals(start - 1, geometry.visualOffset(start, -1))
        }
    }
    @Test fun zeroFontOfflineAltRetainsPositiveParentInkAndRawCaptionInTableFlowText() {
        val occurrence = TextPaint().apply { textSize = 0f; color = android.graphics.Color.BLUE }
        val parent = TextPaint().apply { textSize = 20f; color = android.graphics.Color.BLACK; isAntiAlias = true }
        val image = InlineImage("EU.svg", widthPx = 13, alt = "Visible alt", tooltip = " ", border = true)
        for (state in listOf(InlineImageAssetState.Disabled, InlineImageAssetState.Failed)) {
            val alt = requireNotNull(nativeFloatImageFallbackLayout(image, state, occurrence, parent))
            assertEquals(20f, alt.paint.textSize, 0f)
            val bitmap = android.graphics.Bitmap.createBitmap(kotlin.math.ceil(alt.getLineWidth(0)).toInt().coerceAtLeast(1),
                alt.height.coerceAtLeast(1), android.graphics.Bitmap.Config.ARGB_8888)
            try {
                alt.draw(android.graphics.Canvas(bitmap))
                val pixels = IntArray(bitmap.width * bitmap.height)
                bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                assertTrue(pixels.any { android.graphics.Color.alpha(it) > 0 && android.graphics.Color.blue(it) > android.graphics.Color.red(it) })
            } finally { bitmap.recycle() }
            assertEquals(0f, occurrence.textSize, 0f)
            assertEquals("Visible alt", image.alt)
            assertEquals(" ", nativeFloatImageFallbackLayout(image.copy(alt = " "), state, occurrence, parent)!!.text.toString())
            assertNull(nativeFloatImageFallbackLayout(image.copy(alt = null), state, occurrence, parent))
            assertNull(nativeFloatImageFallbackLayout(image.copy(alt = ""), state, occurrence, parent))
        }
    }

    @Test fun sectionHeadingAndListBandsContinueBesideTheTableWithoutArtificialClear() {
        fun text(value: String, insets: NativeTextInsets) = NativeFloatContextPart.Text(value, { width, carried ->
            NativeFloatGeometry.build(SpannableString(value), paint, width, emptyList(), carriedExclusions = carried, insets = insets)
        })
        val context = NativeFloatContextGeometry.build(320, listOf(table(width = 100f, height = 180f),
            text("Ahoskera", NativeTextInsets(extraRight = 48f)),
            text("first pronunciation", NativeTextInsets(left = 16f, extraLeft = 28f)),
            text("second pronunciation", NativeTextInsets(left = 16f, extraLeft = 28f))))
        assertEquals(listOf(0, 2, 11, 31), context.partOffsets)
        val child = context.children.single().bounds
        assertEquals(0f, context.characterRects(2, 1).single()!!.top, 1f)
        val first = context.characterRects(11, 1).single()!!
        assertTrue(first.left >= 44f && first.top < child.bottom)
        context.characterRects(2, context.text.length - 2).filterNotNull().forEach { assertFalse(RectF.intersects(it, child)) }
        assertEquals("\ufffc\nAhoskera\nfirst pronunciation\nsecond pronunciation", context.text.toString())
    }

    @Test fun anUnadaptedTextBlockCannotMasqueradeAsAClearingFrame() {
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeFloatContextGeometry.build(240, listOf(table(),
                NativeFloatContextPart.Child(2, NativeBlockWidth.FixedPx(240f), { NativeBlockMeasure(240f, 240f, 30f) },
                    requiresUnobstructedText = true)))
        }
    }

}
