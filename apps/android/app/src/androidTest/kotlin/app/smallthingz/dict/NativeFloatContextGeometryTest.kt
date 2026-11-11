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

    @Test fun touchTargetsSurviveAncestorRelocationWhenFocusIsAcquired() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val text = "IPA sample words for selection\n" + "A following body line\n".repeat(30)
        val clicks = mutableListOf<String>()
        val longClicks = mutableListOf<String>()
        val wrapped = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron"
        val wrappedText = "$wrapped\nNext"
        val characterOffset = wrapped.indexOf("theta") + 2
        lateinit var wrappedFragment: RectF
        lateinit var view: NativeFloatTextView
        lateinit var geometry: NativeFloatGeometry
        var focusRequests = 0
        val focusRects = mutableListOf<android.graphics.Rect>()
        var relocationArmed = false
        lateinit var root: android.widget.FrameLayout
        var rootCreated = false
        var downTime = 0L
        fun send(action: Int, x: Float, y: Float) {
            if (action == android.view.MotionEvent.ACTION_DOWN) downTime = android.os.SystemClock.uptimeMillis()
            val event = android.view.MotionEvent.obtain(downTime, android.os.SystemClock.uptimeMillis(), action, x, y, 0)
            event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            try { assertTrue(root.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
        fun point(offset: Int): Pair<Float, Float> {
            val caret = geometry.caretRect(offset)
            return view.left + view.paddingLeft + caret.left to view.top + view.paddingTop + caret.centerY()
        }
        fun padded(rect: RectF) = android.graphics.Rect().also {
            rect.roundOut(it); it.offset(view.paddingLeft, view.paddingTop)
        }
        fun focusedRect() = android.graphics.Rect().also(view::getFocusedRect)
        fun reset() {
            relocationArmed = false
            assertTrue(root.requestFocus())
            view.offsetTopAndBottom(20 - view.top)
            view.setSelection(0, 0)
            clicks.clear()
            longClicks.clear()
            focusRequests = 0
            focusRects.clear()
            relocationArmed = true
            assertFalse(view.hasFocus())
        }
        fun awaitLongPress() {
            val ready = java.util.concurrent.CountDownLatch(1)
            instrumentation.runOnMainSync {
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ ready.countDown() },
                    android.view.ViewConfiguration.getLongPressTimeout().toLong() + 100L)
            }
            assertTrue(ready.await(3, java.util.concurrent.TimeUnit.SECONDS))
        }
        fun bindWrapped(width: Int, replacement: String = wrappedText) {
            view.bind({ available ->
                NativeFloatGeometry.build(SpannableString(replacement), TextPaint().apply { textSize = 20f },
                    available, emptyList(), nodeFactory = { layout ->
                        if (replacement != wrappedText) emptyList() else listOf(
                            FloatInteractionNode(0, FloatInteractionKind.LINK, 0, wrapped.length,
                                layout.rectsForRange(0, wrapped.length), "wrapped", null, { clicks += "wrapped" },
                                onLongClick = { longClicks += "wrapped" }),
                            FloatInteractionNode(1, FloatInteractionKind.LINK, wrapped.length + 1, wrappedText.length,
                                layout.rectsForRange(wrapped.length + 1, wrappedText.length), "Next", null, { clicks += "Next" }))
                    }).also { geometry = it }
            }, 0x6633b5e5, 0xff1686c7.toInt())
            view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            view.layout(view.left, view.top, view.left + width, view.top + view.measuredHeight)
        }
        try {
            instrumentation.runOnMainSync {
                root = object : android.widget.FrameLayout(context) {
                    override fun requestChildFocus(child: View, focused: View) {
                        super.requestChildFocus(child, focused)
                        if (relocationArmed && focused === view) {
                            focusRects += android.graphics.Rect().also(focused::getFocusedRect)
                            focusRequests++
                            // A real ancestor may reposition its focused child before the next event.
                            child.offsetTopAndBottom(128)
                        }
                    }
                }.apply {
                    isFocusable = true
                    isFocusableInTouchMode = true
                    descendantFocusability = android.view.ViewGroup.FOCUS_BEFORE_DESCENDANTS
                }
                rootCreated = true
                view = NativeFloatTextView(context).apply {
                    setPadding(7, 11, 9, 13)
                    bind({ width ->
                        NativeFloatGeometry.build(SpannableString(text), TextPaint().apply { textSize = 20f },
                            width, emptyList(), nodeFactory = { layout -> listOf(
                                FloatInteractionNode(0, FloatInteractionKind.LINK, 0, 3, layout.rectsForRange(0, 3),
                                    "IPA", null, { clicks += "IPA" })) }).also { geometry = it }
                    }, 0x6633b5e5, 0xff1686c7.toInt())
                }
                view.measure(View.MeasureSpec.makeMeasureSpec(240, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                root.addView(view, android.widget.FrameLayout.LayoutParams(240, view.measuredHeight).apply {
                    leftMargin = 10; topMargin = 20
                })
                root.measure(View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(640, View.MeasureSpec.EXACTLY))
                root.layout(0, 0, 320, 640)
                reset()
                val link = geometry.nodes.single().bounds.single()
                val x = view.left + view.paddingLeft + link.centerX()
                val y = view.top + view.paddingTop + link.centerY()
                send(android.view.MotionEvent.ACTION_DOWN, x, y)
                assertFalse("An unresolved touch must not acquire focus", view.hasFocus())
                assertEquals(20, view.top)
                send(android.view.MotionEvent.ACTION_CANCEL, x, y)
                assertFalse(view.hasFocus()); assertEquals(0, focusRequests)
                assertTrue(clicks.isEmpty()); assertEquals(0, view.selectionStart); assertEquals(0, view.selectionEnd)
                send(android.view.MotionEvent.ACTION_DOWN, x, y)
                send(android.view.MotionEvent.ACTION_UP, x, y)
                assertEquals(listOf("IPA"), clicks)
                assertFalse(view.hasFocus()); assertEquals(0, focusRequests); assertEquals(20, view.top)
                assertEquals(0, view.selectionStart); assertEquals(0, view.selectionEnd)
                assertEquals(text, view.logicalText.toString())
                assertTrue(focusRects.isEmpty())
                assertEquals(padded(geometry.caretRect(0)), focusedRect())

                // An already focused link must not replace the logical caret or virtual input focus.
                val provider = view.accessibilityNodeProvider
                assertTrue(provider.performAction(0, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(view.hasFocus()); assertEquals(1, focusRequests); assertEquals(148, view.top)
                view.setSelection(8, 8)
                val priorFocus = focusedRect()
                val movedX = view.left + view.paddingLeft + link.centerX()
                val movedY = view.top + view.paddingTop + link.centerY()
                send(android.view.MotionEvent.ACTION_DOWN, movedX, movedY)
                send(android.view.MotionEvent.ACTION_UP, movedX, movedY)
                assertEquals(listOf("IPA", "IPA"), clicks)
                assertTrue(view.hasFocus()); assertEquals(1, focusRequests); assertEquals(148, view.top)
                assertEquals(8, view.selectionStart); assertEquals(8, view.selectionEnd)
                assertEquals(priorFocus, focusedRect())
                val focusedNode = requireNotNull(provider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT))
                try { assertEquals("IPA", focusedNode.text.toString()) } finally { focusedNode.recycle() }

                reset()
                val caretPoint = point(8)
                val expected = geometry.offsetForPosition(caretPoint.first - view.left - view.paddingLeft,
                    caretPoint.second - view.top - view.paddingTop)
                send(android.view.MotionEvent.ACTION_DOWN, caretPoint.first, caretPoint.second)
                send(android.view.MotionEvent.ACTION_UP, caretPoint.first, caretPoint.second)
                assertEquals(expected, view.selectionStart); assertEquals(expected, view.selectionEnd)
                assertTrue(view.hasFocus()); assertEquals(1, focusRequests); assertTrue(clicks.isEmpty())
                assertEquals(listOf(padded(geometry.caretRect(expected))), focusRects)
                assertEquals(padded(geometry.caretRect(expected)), focusedRect())

                reset()
                val word = point(7)
                send(android.view.MotionEvent.ACTION_DOWN, word.first, word.second)
                assertFalse(view.hasFocus())
            }
            // Let GestureDetector's real long-press message run without blocking the UI thread.
            awaitLongPress()
            instrumentation.runOnMainSync {
                assertTrue(view.hasFocus()); assertEquals(1, focusRequests)
                assertEquals(4, view.selectionStart); assertEquals(10, view.selectionEnd)
                assertEquals("sample", view.selectedTextForCopy())
                assertEquals(listOf(padded(geometry.caretRect(10))), focusRects)
                val end = point(16)
                send(android.view.MotionEvent.ACTION_MOVE, end.first, end.second)
                send(android.view.MotionEvent.ACTION_UP, end.first, end.second)
                assertEquals(4, view.selectionStart); assertEquals(16, view.selectionEnd)
                assertEquals("sample words", view.selectedTextForCopy())
                assertEquals(padded(geometry.caretRect(16)), focusedRect())
                assertEquals(1, focusRequests); assertTrue(clicks.isEmpty())
                assertEquals(text, view.logicalText.toString())
                val before = view.selectionStart to view.selectionEnd
                val selectedEnd = point(view.selectionEnd)
                send(android.view.MotionEvent.ACTION_DOWN, selectedEnd.first, selectedEnd.second)
                send(android.view.MotionEvent.ACTION_CANCEL, selectedEnd.first, selectedEnd.second)
                assertEquals(before, view.selectionStart to view.selectionEnd)
                assertTrue(view.hasFocus()); assertEquals(1, focusRequests); assertTrue(clicks.isEmpty())
                assertEquals(padded(geometry.caretRect(16)), focusedRect())

                // A focus-acquiring long press retains the touched fragment through reflow.
                reset()
                bindWrapped(220)
                val character = requireNotNull(geometry.characterRects(characterOffset, 1).single())
                wrappedFragment = geometry.nodes.first().bounds.single { RectF.intersects(it, character) }
                assertTrue(wrappedFragment.top > geometry.nodes.first().bounds.first().top)
                val touchX = view.left + view.paddingLeft + character.centerX()
                val touchY = view.top + view.paddingTop + character.centerY()
                send(android.view.MotionEvent.ACTION_DOWN, touchX, touchY)
                assertFalse(view.hasFocus())
            }
            awaitLongPress()
            instrumentation.runOnMainSync {
                assertTrue(view.hasFocus()); assertEquals(1, focusRequests)
                assertEquals(listOf("wrapped"), longClicks); assertTrue(clicks.isEmpty())
                val character = requireNotNull(geometry.characterRects(characterOffset, 1).single())
                send(android.view.MotionEvent.ACTION_UP,
                    view.left + view.paddingLeft + character.centerX(),
                    view.top + view.paddingTop + character.centerY())
                assertEquals(listOf(padded(wrappedFragment)), focusRects)
                assertEquals(padded(wrappedFragment), focusedRect())
                val beforeReflow = focusedRect()
                bindWrapped(160)
                val reflowedCharacter = requireNotNull(geometry.characterRects(characterOffset, 1).single())
                val reflowedFragment = geometry.nodes.first().bounds.single { RectF.intersects(it, reflowedCharacter) }
                assertNotEquals(beforeReflow, padded(reflowedFragment))
                assertEquals(padded(reflowedFragment), focusedRect())
                assertEquals(wrappedText, view.logicalText.toString())

                assertTrue(view.onKeyDown(KeyEvent.KEYCODE_TAB, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB)))
                assertEquals(padded(geometry.nodes.first().bounds.first()), focusedRect())
                assertTrue(view.onKeyDown(KeyEvent.KEYCODE_TAB, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB)))
                assertEquals(padded(geometry.nodes.last().bounds.first()), focusedRect())
                assertTrue(clicks.isEmpty()); assertEquals(listOf("wrapped"), longClicks)
                assertTrue(view.onKeyDown(KeyEvent.KEYCODE_ENTER, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)))
                assertEquals(listOf("Next"), clicks)
                view.setSelection(characterOffset, characterOffset)
                assertEquals(padded(geometry.caretRect(characterOffset)), focusedRect())

                reset()
                val provider = view.accessibilityNodeProvider
                assertTrue(provider.performAction(1, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(view.hasFocus())
                val nextRect = padded(geometry.nodes.last().bounds.first())
                assertEquals(listOf(nextRect), focusRects)
                assertEquals(nextRect, focusedRect())
                assertTrue(clicks.isEmpty())
                bindWrapped(160, "Replacement text")
                assertEquals(android.graphics.Rect().also(view::getDrawingRect), focusedRect())
                assertEquals(0, view.selectionStart); assertEquals(0, view.selectionEnd)
            }
        } finally {
            instrumentation.runOnMainSync {
                if (rootCreated) {
                    val cancel = android.view.MotionEvent.obtain(0, android.os.SystemClock.uptimeMillis(),
                        android.view.MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
                    try { root.dispatchTouchEvent(cancel) } finally { cancel.recycle() }
                    root.removeAllViews()
                }
            }
        }
    }

    @Test fun tableClearanceMovesActualChildButDoesNotAdvanceFollowingTextForAFloatingTable() {
        val left = table(id = 1, side = TableFloatSide.Left, width = 50f, height = 60f, margin = 0f)
        val right = table(id = 2, side = TableFloatSide.Right, width = 50f, height = 90f, margin = 0f)
        for ((clear, expected) in listOf(null to 0f, FigureClear.None to 0f,
            FigureClear.Left to 60f, FigureClear.Right to 90f, FigureClear.Both to 90f)) {
            for (floating in listOf(false, true)) {
                val target = NativeFloatContextPart.Child(3, NativeBlockWidth.FixedPx(40f),
                    { NativeBlockMeasure(40f, 40f, 10f) }, floatSide = if (floating) TableFloatSide.Left else null,
                    clear = clear)
                val context = NativeFloatContextGeometry.build(300, listOf(left, right, target, paragraph("Following")))
                val actual = context.children.single { it.id == 3 }
                assertEquals(expected, actual.bounds.top, 0f)
                assertEquals(40f, actual.bounds.width(), 0f)
                assertEquals(listOf(actual.bounds), context.rectsForRange(actual.offset, actual.offset + 1))
                assertEquals(actual.bounds, context.characterRects(actual.offset, 1).single())
                assertEquals(actual.offset, context.offsetForPosition(actual.bounds.centerX(), actual.bounds.centerY()))
                val textStart = context.text.indexOf("Following")
                assertTrue(textStart >= 0)
                if (floating && expected > 0f) assertTrue(context.caretRect(textStart).top < actual.bounds.top)
                else if (!floating) assertTrue(context.caretRect(textStart).top >= actual.bounds.bottom)
                assertEquals("\ufffc\n\ufffc\n\ufffc\nFollowing", context.text.toString())
                val isolated = NativeFloatContextGeometry.build(300, listOf(target))
                assertEquals(0f, isolated.children.single().bounds.top, 0f)
            }
        }
        val normal = NativeFloatContextPart.Child(3, NativeBlockWidth.FixedPx(300f),
            { NativeBlockMeasure(300f, 300f, 10f) }, clear = FigureClear.Left,
            margins = FloatMargins(15f, 0f, 7f, 0f))
        val withMargins = NativeFloatContextGeometry.build(300, listOf(left, normal, paragraph("Following")))
        assertEquals(60f, withMargins.children.single { it.id == 3 }.bounds.top, 0f)
        assertTrue(withMargins.caretRect(withMargins.text.indexOf("Following")).top >= 77f)
        assertEquals(15f, NativeFloatContextGeometry.build(300, listOf(normal)).children.single().bounds.top, 0f)
    }

    @Test fun paragraphBoxTranslatesDrawingHitsSelectionAndAccessibilityWithoutChangingLogicalText() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            var clicked = 0
            val box = ParagraphBox(ParagraphEdges(7f, 11f, 13f, 17f), ParagraphEdges(3f, 5f, 9f, 19f), 7f, 13f)
            for (rtl in listOf(false, true)) {
                val text = "\ud83d\ude80 Target"
                val part = paragraph(text, rtl, action = { clicked++ }).copy(gapAfter = box.after, box = box)
                val context = NativeFloatContextGeometry.build(320, listOf(part))
                val base = part.build(268, emptyList())
                assertEquals(text, context.text.toString())
                assertEquals(kotlin.math.ceil(base.textBottom + 32f).toInt(), context.height)
                val expected = base.rectsForRange(0, text.length).map { RectF(it).apply { offset(36f, 10f) } }
                assertEquals(expected, context.rectsForRange(0, text.length))
                assertEquals(expected, context.nodes.single().bounds)
                val boxes = context.characterRects(0, 2)
                assertNotNull(boxes[0]); assertEquals(boxes[0], boxes[1])
                val caret = context.caretRect(3)
                assertEquals(base.offsetForPosition(caret.left - 36f, caret.centerY() - 10f),
                    context.offsetForPosition(caret.left, caret.centerY()))
                val bitmap = android.graphics.Bitmap.createBitmap(320, context.height, android.graphics.Bitmap.Config.ARGB_8888)
                try {
                    context.paint(android.graphics.Canvas(bitmap))
                    val pixels = IntArray(bitmap.width * bitmap.height)
                    bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                    val ink = pixels.indices.filter { android.graphics.Color.alpha(pixels[it]) > 0 }
                    assertTrue(ink.isNotEmpty())
                    assertTrue(ink.all { it % 320 >= 35 && it / 320 >= 9 })
                } finally { bitmap.recycle() }
                val view = NativeFloatTextView(instrumentation.targetContext)
                view.bind({ context }, 0x6633b5e5, 0xff1686c7.toInt())
                view.measure(View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.AT_MOST))
                view.layout(0, 0, view.measuredWidth, view.measuredHeight)
                val host = view.accessibilityNodeProvider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID)!!
                assertEquals(text, host.text.toString())
                assertTrue(view.accessibilityNodeProvider.performAction(context.nodes.single().id, AccessibilityNodeInfo.ACTION_CLICK, null))
                val floated = NativeFloatContextGeometry.build(320, listOf(table(width = 80f, height = 100f), part))
                assertEquals("\ufffc\n$text", floated.text.toString())
                floated.characterRects(2, text.length).filterNotNull().forEach {
                    assertFalse(RectF.intersects(it, floated.children.single().bounds))
                }
            }
            assertEquals(2, clicked)
        }
    }

    @Test fun emptyParagraphBoxAddsOnlyEdgesWithoutTextNodeLineOrLogicalSeparator() {
        val box = ParagraphBox(ParagraphEdges(), ParagraphEdges(3f, 0f, 5f, 0f), 7f, 11f)
        val empty = NativeFloatContextPart.Text("", { _, _ -> error("An empty source box must not shape a text line") }, box.after, box)
        val only = NativeFloatContextGeometry.build(240, listOf(empty))
        assertEquals("", only.text.toString()); assertEquals(26, only.height)
        assertTrue(only.nodes.isEmpty()); assertTrue(only.rectsForRange(0, 0).isEmpty())
        assertTrue(only.characterRects(0, 0).isEmpty())
        val none = empty.copy(gapAfter = 0f, box = ParagraphBox(ParagraphEdges(), ParagraphEdges(), 0f, 0f))
        assertEquals(0, NativeFloatContextGeometry.build(240, listOf(none)).height)
        val fullWidth = none.copy(box = ParagraphBox(ParagraphEdges(), ParagraphEdges(left = 240f), 0f, 0f))
        assertEquals(0, NativeFloatContextGeometry.build(240, listOf(fullWidth)).height)
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeFloatContextGeometry.build(240, listOf(fullWidth.copy(text = "x")))
        }
        val tooWide = none.copy(box = ParagraphBox(ParagraphEdges(), ParagraphEdges(left = 300f), 0f, 0f))
        assertThrows(UnsupportedFloatLayout::class.java) { NativeFloatContextGeometry.build(240, listOf(tooWide)) }
        val large = none.copy(box = ParagraphBox(ParagraphEdges(50000f), ParagraphEdges(), 50000f, 0f))
        val largeGeometry = NativeFloatContextGeometry.build(240, listOf(large))
        assertEquals(50000, largeGeometry.height)
        assertEquals("", largeGeometry.text.toString()); assertTrue(largeGeometry.nodes.isEmpty())
        val normal = NativeFloatContextGeometry.build(240, listOf(paragraph("Before"), paragraph("After")))
        val withEmpty = NativeFloatContextGeometry.build(240, listOf(paragraph("Before"), empty, paragraph("After")))
        assertEquals(normal.text.toString(), withEmpty.text.toString())
        assertEquals(normal.height + 26, withEmpty.height)
        assertEquals(normal.characterRects(7, 1).single()!!.top + 26f, withEmpty.characterRects(7, 1).single()!!.top, .01f)
    }

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

    @Test fun shapedPronunciationAndItsControlsKeepSeparateCopyAndFloatOwnership() {
        fun text(value: String) = NativeFloatContextPart.Text(value, { width, carried ->
            NativeFloatGeometry.build(SpannableString(value), paint, width, emptyList(), carriedExclusions = carried)
        })
        val context = NativeFloatContextGeometry.build(240, listOf(table(width = 100f, height = 180f),
            text("IPA"), NativeFloatContextPart.Child(2, NativeBlockWidth.FixedPx(240f),
                { NativeBlockMeasure(240f, 240f, 48f) }, logicalObject = false), text("after")))
        assertEquals("\ufffc\nIPA\nafter", context.text.toString())
        val floated = context.children.first().bounds
        val control = context.children.single { it.id == 2 }
        assertFalse(control.logicalObject)
        assertTrue(context.characterRects(2, 1).single()!!.top < floated.bottom)
        assertTrue(control.bounds.top >= floated.bottom)
        assertEquals(context.text.indexOf('\n', 2), control.offset)
        assertEquals(control.offset, context.offsetForPosition(control.bounds.centerX(), control.bounds.centerY()))
        context.rectsForRange(0, context.text.length).forEach { assertFalse(RectF.intersects(it, control.bounds)) }
        context.characterRects(0, context.text.length).filterNotNull().forEach { assertFalse(RectF.intersects(it, control.bounds)) }
    }

    private fun anonymousFigure(placement: FigurePlacement): Figure {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        return Figure(FigureContent.Image(Span("link", "", "Image", image = InlineImage("Scope.svg", alt = "Scope image")), FigureSizingPolicy.Intrinsic),
            FigureFormat.Framed, placement, FigureClear.None, edges, edges, edges,
            .884f, StyleLength(StyleLengthUnit.Em, 1.2376f), FigureColor.NativeTheme, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("text", "caption אב")))
    }

    private fun measuredAnonymousFigure(width: Int = 64, caption: String = "caption אב") =
        NativeFloatGeometry.build(SpannableString(caption), TextPaint(paint).apply { textSize = 14f }, width,
            emptyList(), textDirection = TextDirectionHeuristics.RTL,
            decoration = { canvas, _ ->
                canvas.drawRect(0f, 0f, 5f, 5f, android.graphics.Paint().apply { color = android.graphics.Color.BLUE })
            })

    @Test fun anonymousScopesEncloseActualFloatObjectsOnBothSidesAcrossNativeLineReflow() {
        val before = "Latin before "
        val inside = "אב Latin one two three four five six "
        val after = " after tail"
        for (side in listOf(FigurePlacement.FloatLeft, FigurePlacement.FloatRight)) for (width in listOf(180, 260)) {
            val figure = anonymousFigure(side)
            val scope = BidiScope(BidiMode.IsolateOverride, BidiDirectionInput.Rtl, BidiResolvedDirection.Rtl, "he",
                listOf(FlowPart.Inline(listOf(Span("text", inside))), FlowPart.ImageFigure(figure),
                    FlowPart.Inline(listOf(Span("text", "אב end")))))
            val block = Block("paragraph", 0, emptyList(), flow = listOf(
                FlowPart.Inline(listOf(Span("text", before))), FlowPart.Scope(scope),
                FlowPart.Inline(listOf(Span("text", after)))))
            val content = anonymousFlowContent(block, AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
            var measurements = 0
            val geometry = NativeAnonymousFlowGeometry.build(content, paint, width,
                { SpannableString(textOf(it.spans)) }, { event, actualWidth ->
                    measurements++
                    assertEquals(width, actualWidth)
                    assertEquals("he", event.captionContext.language)
                    assertEquals(BidiResolvedDirection.Rtl, event.captionContext.direction)
                    MeasuredAnonymousFigure(measuredAnonymousFigure(), FloatMargins(3f, 7f, 5f, 11f))
                })
            assertEquals(1, measurements)
            assertEquals(before + inside + "caption אב" + "אב end" + after, geometry.text.toString())
            assertFalse(geometry.text.contains('\ufffc'))
            assertFalse(geometry.text.contains('\u2067'))
            assertFalse(geometry.text.contains('\n'))
            val child = geometry.figures.single()
            assertEquals(if (side == FigurePlacement.FloatLeft) 11f else width - 7f - 64f,
                child.bounds.left, .01f)
            val boxes = geometry.characterRects(0, geometry.text.length)
            assertTrue(boxes.filterNotNull().map { it.top }.distinct().size > 1)
            val childRange = geometry.selection.segments.filterIsInstance<AnonymousSelectionSegment.Figure>().single()
            boxes.forEachIndexed { index, rect -> if (rect != null && index !in childRange.start until childRange.end)
                assertFalse("Inline glyph overlaps real figure", RectF.intersects(rect, child.bounds)) }
            val firstHebrew = before.length
            val hebrew = geometry.characterRects(firstHebrew, 2)
            assertTrue(hebrew[0]!!.centerX() > hebrew[1]!!.centerX())
            for (offset in listOf(0, before.length, before.length + inside.length, geometry.text.length)) {
                val caret = geometry.caretRect(offset)
                assertTrue(caret.left.isFinite() && caret.top.isFinite())
                assertTrue(geometry.offsetForPosition(caret.left, caret.centerY()) in 0..geometry.text.length)
                assertTrue(geometry.visualOffset(offset, -1) in 0..geometry.text.length)
                assertTrue(geometry.visualOffset(offset, 1) in 0..geometry.text.length)
            }
            assertEquals(child.measured.geometry.rectsForRange(0, child.measured.geometry.text.length)
                .map { RectF(it).apply { offset(child.bounds.left, child.bounds.top) } },
                geometry.rectsForRange(childRange.start, childRange.end))
            val bitmap = android.graphics.Bitmap.createBitmap(width, geometry.height, android.graphics.Bitmap.Config.ARGB_8888)
            try {
                geometry.paint(android.graphics.Canvas(bitmap))
                val pixels = IntArray(width * geometry.height)
                bitmap.getPixels(pixels, 0, width, 0, 0, width, geometry.height)
                assertTrue("Measured child must actually paint", pixels.any { it == android.graphics.Color.BLUE })
            } finally { bitmap.recycle() }
            // The old Text/Child route adds semantic newlines and independent UBA owners.
            val split = NativeFloatContextGeometry.build(width, listOf(paragraph(before), table(width = 64f), paragraph(inside + "אב end" + after)))
            assertNotEquals(geometry.text.toString(), split.text.toString())
        }
    }

    @Test fun anonymousFigureOnlyCentersItsMarginBoxAndDoesNotInventAParentTextStrut() {
        val figure = anonymousFigure(FigurePlacement.Center)
        val content = anonymousFlowContent(Block("paragraph", 0, emptyList(), figure = figure),
            AnonymousFlowContext(BidiResolvedDirection.Rtl, "", CellTextAlign.Right))
        val caption = measuredAnonymousFigure(64, "x")
        val margins = FloatMargins(3f, 7f, 5f, 19f)
        val geometry = NativeAnonymousFlowGeometry.build(content, paint, 240,
            { error("No authored inline text") }, { event, _ ->
                assertEquals("", event.captionContext.language)
                assertEquals(CellTextAlign.Right, event.captionContext.textAlign)
                MeasuredAnonymousFigure(caption, margins)
            })
        assertEquals("x", geometry.text.toString())
        assertEquals("", geometry.offsets.logicalText)
        assertEquals(kotlin.math.ceil(caption.height + 8f).toInt(), geometry.height)
        val child = geometry.figures.single()
        assertEquals((240 - (64 + 19f + 7f)) / 2f + 19f, child.bounds.left, .01f)
        assertEquals(3f, child.bounds.top, .01f)
        assertTrue(geometry.characterRects(0, 0).isEmpty())
        assertTrue(geometry.rectsForRange(0, 0).isEmpty())
    }

    @Test fun anonymousPublicSelectionAndActionsUseMappedParentAndCaptionOffsets() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val authored = "A\u2067אב\u2069\ud83d\ude80"
            val block = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Scope(
                BidiScope(BidiMode.Isolate, BidiDirectionInput.Auto, BidiResolvedDirection.Ltr, null,
                    listOf(FlowPart.Inline(listOf(Span("text", authored))),
                        FlowPart.ImageFigure(anonymousFigure(FigurePlacement.FloatRight)),
                        FlowPart.Inline(listOf(Span("text", "tail"))))))))
            val content = anonymousFlowContent(block, AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
            var clicks = 0
            val geometry = NativeAnonymousFlowGeometry.build(content, paint, 240,
                { SpannableString(textOf(it.spans)) }, { _, _ ->
                    MeasuredAnonymousFigure(measuredAnonymousFigure(), FloatMargins(0f, 0f, 0f, 8f))
                }, inlineNodes = { g -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, 0, authored.length,
                    g.rectsForRange(0, authored.length), authored, null, { clicks++ })) })
            val view = NativeFloatTextView(instrumentation.targetContext)
            view.bind({ geometry }, 0x6633b5e5, 0xff1686c7.toInt())
            view.measure(View.MeasureSpec.makeMeasureSpec(240, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.AT_MOST))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            val expected = authored + "caption אב" + "tail"
            val host = view.accessibilityNodeProvider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID)!!
            try { assertEquals(expected, host.text.toString()) } finally { host.recycle() }
            view.onKeyDown(KeyEvent.KEYCODE_A, KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, 0, KeyEvent.META_CTRL_ON))
            assertEquals(0, view.selectionStart); assertEquals(expected.length, view.selectionEnd)
            assertEquals(expected, view.logicalText.subSequence(view.selectionStart, view.selectionEnd).toString())
            assertTrue(view.accessibilityNodeProvider.performAction(geometry.nodes.single().id, AccessibilityNodeInfo.ACTION_CLICK, null))
            assertEquals(1, clicks)
            val rocket = authored.indexOf("\ud83d\ude80")
            assertEquals(geometry.characterRects(rocket, 2)[0], geometry.characterRects(rocket, 2)[1])
            assertEquals(expected, view.selectedTextForCopy())
            assertEquals(1, view.logicalText.toString().windowed("caption אב".length).count { it == "caption אב" })
        }
    }

    @Test fun anonymousCaptionSelectionCrossesTheSameOrderedOwnerWithoutNativeParagraphInsertion() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val before = "before\ud83d\ude80 "
            val caption = "caption\nאב \u2067authored\u2069"
            val after = " after"
            val model = anonymousFigure(FigurePlacement.FloatRight).copy(caption = listOf(Span("text", caption)))
            val scope = BidiScope(BidiMode.Isolate, BidiDirectionInput.Auto, BidiResolvedDirection.Rtl, "he",
                listOf(FlowPart.Inline(listOf(Span("text", before))), FlowPart.ImageFigure(model),
                    FlowPart.Inline(listOf(Span("text", after)))))
            val content = anonymousFlowContent(Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Scope(scope))),
                AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
            var captionClicks = 0
            val captionGeometry = NativeFloatGeometry.build(SpannableString(caption), paint, 100, emptyList(),
                textDirection = TextDirectionHeuristics.RTL, nodeFactory = { child -> listOf(
                    FloatInteractionNode(77, FloatInteractionKind.LINK, 0, 7, child.rectsForRange(0, 7),
                        "caption", null, { captionClicks++ })) })
            val geometry = NativeAnonymousFlowGeometry.build(content, paint, 300,
                { SpannableString(textOf(it.spans)) }, { event, _ ->
                    assertEquals("he", event.captionContext.language)
                    MeasuredAnonymousFigure(captionGeometry, FloatMargins(0f, 0f, 0f, 8f))
                })
            val expected = before + caption + after
            assertEquals(expected, geometry.text.toString())
            assertEquals(1, geometry.offsets.nativeText.count { it == '\ufffc' })
            assertFalse("Rich caption newline must not split the parent paragraph", geometry.offsets.nativeText.contains('\n'))
            val placed = geometry.figures.single()
            val segment = geometry.selection.segments.filterIsInstance<AnonymousSelectionSegment.Figure>().single()
            assertEquals(before.length, segment.start); assertEquals(before.length + caption.length, segment.end)
            val range = geometry.rectsForRange(segment.start + 1, segment.start + 6)
            assertEquals(captionGeometry.rectsForRange(1, 6).map { RectF(it).apply { offset(placed.bounds.left, placed.bounds.top) } }, range)
            assertEquals(captionGeometry.characterRects(0, caption.length).map { it?.let { r -> RectF(r).apply { offset(placed.bounds.left, placed.bounds.top) } } },
                geometry.characterRects(segment.start, caption.length))
            val localCaret = captionGeometry.caretRect(3)
            assertEquals(RectF(localCaret).apply { offset(placed.bounds.left, placed.bounds.top) }, geometry.caretRect(segment.start + 3))
            assertEquals(segment.start + captionGeometry.offsetForPosition(localCaret.left, localCaret.centerY()),
                geometry.offsetForPosition(localCaret.left + placed.bounds.left, localCaret.centerY() + placed.bounds.top))
            assertEquals(segment.start + captionGeometry.visualOffset(3, 1), geometry.visualOffset(segment.start + 3, 1))
            val localLine = captionGeometry.lineRange(3)
            assertEquals(segment.start + localLine.first to segment.start + localLine.second, geometry.lineRange(segment.start + 3))
            val node = geometry.nodes.single()
            assertEquals(segment.start, node.start); assertEquals(segment.start + 7, node.end)
            val view = NativeFloatTextView(instrumentation.targetContext)
            view.bind({ geometry }, 0x6633b5e5, 0xff1686c7.toInt())
            view.measure(View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.AT_MOST))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            view.setSelection(2, expected.length - 2)
            assertEquals(expected.substring(2, expected.length - 2), view.selectedTextForCopy())
            val host = view.accessibilityNodeProvider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID)!!
            try { assertEquals(expected, host.text.toString()); assertEquals(1, host.childCount) } finally { host.recycle() }
            assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
            assertEquals(1, captionClicks)
        }
    }

    @Test fun anonymousVisualMovementEntersCaptionAtSharedAndAdjacentOwnerEndpoints() {
        for (rtl in listOf(false, true)) {
            val direction = if (rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr
            val towardPrevious = if (rtl) 1 else -1
            val towardFollowing = -towardPrevious
            val firstText = if (rtl) "אב abc גד" else "abc אב xyz"
            val secondText = if (rtl) "הו def זח" else "def גד uvw"
            val figure = anonymousFigure(FigurePlacement.FloatRight)
            val block = Block("paragraph", 0, emptyList(), flow = listOf(
                FlowPart.Inline(listOf(Span("text", if (rtl) "לפני " else "before "))),
                FlowPart.ImageFigure(figure), FlowPart.ImageFigure(figure.copy(content = (figure.content as FigureContent.Image).copy(span = figure.content.span.copy(target = "Second")))),
                FlowPart.Inline(listOf(Span("text", if (rtl) " אחרי" else " after")))))
            val content = anonymousFlowContent(block, AnonymousFlowContext(direction, if (rtl) "he" else "en", null))
            val children = listOf(firstText, secondText).map { value ->
                NativeFloatGeometry.build(SpannableString(value), paint, 120, emptyList(),
                    textDirection = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR)
            }
            val geometry = NativeAnonymousFlowGeometry.build(content, paint, 480,
                { SpannableString(textOf(it.spans)) }, { event, _ ->
                    MeasuredAnonymousFigure(children[event.id], FloatMargins(0f, 0f, 0f, 5f))
                })
            val figures = geometry.selection.segments.filterIsInstance<AnonymousSelectionSegment.Figure>()
            for ((index, segment) in figures.withIndex()) {
                val child = children[index]
                val expectedPrevious = segment.start + child.visualOffset(child.text.length, towardPrevious)
                assertTrue(expectedPrevious in segment.start until segment.end)
                assertEquals("Caption end must enter its child, not skip to the previous owner",
                    expectedPrevious, geometry.visualOffset(segment.end, towardPrevious))
                val expectedFollowing = segment.start + child.visualOffset(0, towardFollowing)
                assertTrue(expectedFollowing in (segment.start + 1)..segment.end)
                assertEquals(expectedFollowing, geometry.visualOffset(segment.start, towardFollowing))
            }
            assertEquals(figures[0].end, figures[1].start)
        }
    }

}
