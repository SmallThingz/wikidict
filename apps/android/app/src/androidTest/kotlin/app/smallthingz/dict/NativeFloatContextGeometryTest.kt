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

    @Test fun virtualActivationRejectsPendingOrDisabledOwnersButKeepsFocusCleanupAndMeasuredRecovery() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val callbacks = mutableListOf<String>()
            val view = NativeFloatTextView(instrumentation.targetContext)
            val provider = view.accessibilityNodeProvider
            val id = 71
            fun bind(owner: String) {
                view.bind({ width ->
                    NativeFloatGeometry.build(SpannableString("same label"), paint, width, emptyList(),
                        nodeFactory = { geometry -> listOf(FloatInteractionNode(id, FloatInteractionKind.LINK,
                            0, 10, geometry.rectsForRange(0, 10), "same label", null,
                            { callbacks += "$owner:click" }, onLongClick = { callbacks += "$owner:long" })) })
                }, 0x6633b5e5, 0xff1686c7.toInt())
            }
            fun measure() {
                view.measure(View.MeasureSpec.makeMeasureSpec(240, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                view.layout(0, 0, view.measuredWidth, view.measuredHeight)
                assertNotNull(view.currentMeasuredGeometry)
            }
            fun action(value: Int) = provider.performAction(id, value, null)
            fun activate(owner: String) {
                val before = callbacks.toList()
                assertTrue(action(AccessibilityNodeInfo.ACTION_CLICK))
                assertEquals(before + "$owner:click", callbacks)
                assertTrue(action(AccessibilityNodeInfo.ACTION_LONG_CLICK))
                assertEquals(before + listOf("$owner:click", "$owner:long"), callbacks)
            }
            fun rejectActivation() {
                val before = callbacks.toList()
                assertFalse(action(AccessibilityNodeInfo.ACTION_CLICK))
                assertFalse(action(AccessibilityNodeInfo.ACTION_LONG_CLICK))
                assertEquals(before, callbacks)
            }
            fun focus() {
                assertTrue(action(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS))
                assertTrue(action(AccessibilityNodeInfo.ACTION_FOCUS))
                assertTrue(view.isFocused)
                val focused = checkNotNull(provider.createAccessibilityNodeInfo(id))
                assertTrue(focused.isFocused)
                assertTrue(focused.isAccessibilityFocused)
            }
            fun clearFocus(keyboardAlreadyCleared: Boolean = false) {
                val before = checkNotNull(provider.createAccessibilityNodeInfo(id))
                assertTrue(before.isAccessibilityFocused)
                assertEquals(!keyboardAlreadyCleared, before.isFocused)
                assertTrue(action(AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS))
                if (keyboardAlreadyCleared) {
                    // Disabling the host already delivered onFocusChanged(false).
                    assertFalse(view.isFocused)
                    assertFalse(action(AccessibilityNodeInfo.ACTION_CLEAR_FOCUS))
                } else {
                    assertTrue(action(AccessibilityNodeInfo.ACTION_CLEAR_FOCUS))
                }
                val cleared = checkNotNull(provider.createAccessibilityNodeInfo(id))
                assertFalse(cleared.isFocused)
                assertFalse(cleared.isAccessibilityFocused)
            }
            bind("old"); measure(); activate("old"); focus()
            // Keep the same text, range and virtual ID: callback ownership still changes.
            bind("new")
            assertNull(view.currentMeasuredGeometry)
            rejectActivation(); clearFocus()
            assertEquals(listOf("old:click", "old:long"), callbacks)
            measure(); activate("new"); focus()
            view.isEnabled = false
            assertFalse(checkNotNull(provider.createAccessibilityNodeInfo(id)).isEnabled)
            rejectActivation(); clearFocus(keyboardAlreadyCleared = true)
            assertEquals(listOf("old:click", "old:long", "new:click", "new:long"), callbacks)
            view.isEnabled = true
            activate("new"); focus()
            view.isEnabled = false
            bind("third"); rejectActivation(); clearFocus(keyboardAlreadyCleared = true)
            measure(); rejectActivation()
            view.isEnabled = true
            activate("third")
            assertEquals(listOf("old:click", "old:long", "new:click", "new:long",
                "new:click", "new:long", "third:click", "third:long"), callbacks)
        }
    }

    /** Real View dispatch and GestureDetector timers; this fixture does not claim window attachment. */
    private class CancellationInputFixture(context: android.content.Context) {
        val text = "Action\nSelection stays here"
        val nodeId = 91
        val callbacks = mutableListOf<String>()
        val linkPaint = NativeMissingLinkPaint(MissingLinkPaint.VectorNewLinkV1, dark = false, visited = false,
            actionIdentity = MissingLinkActionIdentity(Any(), MissingLinkTarget("en", "link", "Action", null)))
        val view = NativeFloatTextView(context)
        lateinit var geometry: NativeFloatGeometry
        private var downTime = 0L
        init {
            view.setPadding(7, 11, 9, 13)
            view.bind({ width ->
                NativeFloatGeometry.build(SpannableString(text), TextPaint().apply { textSize = 20f },
                    width, emptyList(), nodeFactory = { layout -> listOf(
                        FloatInteractionNode(nodeId, FloatInteractionKind.LINK, 0, 6,
                            layout.rectsForRange(0, 6), "Action", null, { callbacks += "click" },
                            onLongClick = { callbacks += "long" }, missingLinkPaint = linkPaint))
                    }).also { geometry = it }
            }, 0x6633b5e5, 0xff1686c7.toInt())
            view.measure(View.MeasureSpec.makeMeasureSpec(280, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            assertSame(geometry, view.currentMeasuredGeometry)
        }
        fun touch(action: Int): Boolean {
            check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
            val now = android.os.SystemClock.uptimeMillis()
            if (action == android.view.MotionEvent.ACTION_DOWN) downTime = now
            val bounds = geometry.nodes.single().bounds.single()
            val event = android.view.MotionEvent.obtain(downTime, now, action,
                view.paddingLeft + bounds.centerX(), view.paddingTop + bounds.centerY(), 0)
            event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            return try { view.dispatchTouchEvent(event) } finally { event.recycle() }
        }
        fun key(action: Int): Boolean = view.dispatchKeyEvent(KeyEvent(action, KeyEvent.KEYCODE_ENTER))
        fun focus() {
            val provider = view.accessibilityNodeProvider
            val accessibilityFocus = provider.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
            if (accessibilityFocus == null)
                assertTrue(provider.performAction(nodeId, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
            else try { assertEquals("Action", accessibilityFocus.text.toString()) } finally { accessibilityFocus.recycle() }
            assertTrue(provider.performAction(nodeId, AccessibilityNodeInfo.ACTION_FOCUS, null))
        }
        fun assertFocusedSource(inputFocused: Boolean = true) {
            assertEquals(inputFocused, view.hasFocus())
            val provider = view.accessibilityNodeProvider
            if (!inputFocused) assertNull(provider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT))
            val kinds = if (inputFocused) listOf(AccessibilityNodeInfo.FOCUS_INPUT, AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
                else listOf(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
            for (kind in kinds) {
                val info = requireNotNull(provider.findFocus(kind))
                try { assertEquals("Action", info.text.toString()) } finally { info.recycle() }
            }
            val node = requireNotNull(provider.createAccessibilityNodeInfo(nodeId))
            try {
                assertEquals("Action", node.text.toString())
                assertEquals(view.isEnabled, node.isEnabled)
            } finally { node.recycle() }
            assertSame(geometry, view.currentMeasuredGeometry)
            assertEquals(text, view.logicalText.toString())
        }
    }

    private fun withCancellationInputFixture(body: (CancellationInputFixture) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var fixture: CancellationInputFixture? = null
        var primary: Throwable? = null
        try {
            instrumentation.runOnMainSync { fixture = CancellationInputFixture(instrumentation.targetContext) }
            body(checkNotNull(fixture))
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                instrumentation.runOnMainSync {
                    fixture?.let {
                        it.view.cancelPendingInputEvents()
                        it.view.isEnabled = true
                        it.touch(android.view.MotionEvent.ACTION_CANCEL)
                        it.view.clearFocus()
                    }
                }
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (cleanup !== failure) failure.addSuppressed(cleanup)
            }
        }
    }

    private fun awaitCancellationLongPressDeadline() {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper())
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        val ready = java.util.concurrent.CountDownLatch(1)
        val barrier = Runnable { ready.countDown() }
        val delay = android.view.ViewConfiguration.getLongPressTimeout().toLong() +
            android.view.ViewConfiguration.getTapTimeout().toLong() + 100L
        instrumentation.runOnMainSync { assertTrue(handler.postDelayed(barrier, delay)) }
        var primary: Throwable? = null
        try {
            assertTrue("The main looper must process the real long-press deadline",
                ready.await(delay + 2000L, java.util.concurrent.TimeUnit.MILLISECONDS))
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                instrumentation.runOnMainSync { handler.removeCallbacks(barrier) }
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (cleanup !== failure) failure.addSuppressed(cleanup)
            }
        }
    }

    @Test fun disabledDispatchAndCancelledHeldKeysPreserveSourceStateUntilFreshInput() =
        withCancellationInputFixture { fixture ->
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val view = fixture.view
                fun refocus() { fixture.focus(); view.setSelection(9, 9) }
                fun unchanged(expectedClicks: Int, inputFocused: Boolean) {
                    assertEquals(List(expectedClicks) { "click" }, fixture.callbacks)
                    assertEquals(9, view.selectionStart); assertEquals(9, view.selectionEnd)
                    assertFalse(fixture.linkPaint.active)
                    fixture.assertFocusedSource(inputFocused)
                }
                refocus()
                view.isEnabled = false
                assertFalse(fixture.touch(android.view.MotionEvent.ACTION_DOWN))
                assertFalse(fixture.touch(android.view.MotionEvent.ACTION_UP))
                unchanged(0, false)
                val provider = view.accessibilityNodeProvider
                assertTrue(provider.performAction(fixture.nodeId, AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS, null))
                assertNull(provider.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY))
                view.isEnabled = true
                refocus()

                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_DOWN))
                assertTrue(fixture.linkPaint.active)
                view.isEnabled = false
                assertFalse(fixture.touch(android.view.MotionEvent.ACTION_UP))
                unchanged(0, false)
                view.isEnabled = true

                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_DOWN))
                view.isEnabled = false
                view.isEnabled = true
                fixture.touch(android.view.MotionEvent.ACTION_UP)
                unchanged(0, false)
                // Disabling legitimately clears input focus; reacquisition is a separate action.
                refocus()
                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_DOWN))
                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_UP))
                unchanged(1, true)

                // This fixed-palette link defers keyboard activation to UP, unlike a plain link.
                assertTrue(fixture.key(KeyEvent.ACTION_DOWN))
                assertTrue(fixture.linkPaint.active)
                val focusedRect = android.graphics.Rect().also(view::getFocusedRect)
                view.cancelPendingInputEvents()
                assertFalse(fixture.linkPaint.active)
                fixture.key(KeyEvent.ACTION_UP)
                unchanged(1, true)
                assertEquals(focusedRect, android.graphics.Rect().also(view::getFocusedRect))
                view.isEnabled = false
                assertFalse(fixture.key(KeyEvent.ACTION_DOWN))
                assertFalse(fixture.key(KeyEvent.ACTION_UP))
                view.isEnabled = true
                unchanged(1, false)
                refocus()
                assertTrue(fixture.key(KeyEvent.ACTION_DOWN))
                view.isEnabled = false
                view.isEnabled = true
                fixture.key(KeyEvent.ACTION_UP)
                unchanged(1, false)
                refocus()
                assertTrue(fixture.key(KeyEvent.ACTION_DOWN))
                assertTrue(fixture.key(KeyEvent.ACTION_UP))
                unchanged(2, true)
                assertTrue(provider.performAction(fixture.nodeId, AccessibilityNodeInfo.ACTION_CLICK, null))
                unchanged(3, true)
            }
        }

    @Test fun publicCancellationAndDisableStopRealDelayedLongPressThenFreshInputRecovers() =
        withCancellationInputFixture { fixture ->
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val view = fixture.view
            instrumentation.runOnMainSync {
                view.setSelection(9, 9)
                assertFalse(view.hasFocus())
                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_DOWN))
                assertTrue(fixture.linkPaint.active)
                view.cancelPendingInputEvents()
                view.cancelPendingInputEvents()
                assertFalse(fixture.linkPaint.active)
            }
            awaitCancellationLongPressDeadline()
            instrumentation.runOnMainSync {
                assertTrue(fixture.callbacks.isEmpty()); assertFalse(view.hasFocus())
                assertEquals(9, view.selectionStart); assertEquals(9, view.selectionEnd)
                fixture.touch(android.view.MotionEvent.ACTION_UP)
                assertTrue(fixture.callbacks.isEmpty())
                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_DOWN))
                view.isEnabled = false
                // Re-enable before the timer: an enabled check alone cannot satisfy this oracle.
                view.isEnabled = true
                assertFalse(fixture.linkPaint.active)
            }
            awaitCancellationLongPressDeadline()
            instrumentation.runOnMainSync {
                assertTrue(fixture.callbacks.isEmpty()); assertFalse(view.hasFocus())
                assertEquals(9, view.selectionStart); assertEquals(9, view.selectionEnd)
                fixture.touch(android.view.MotionEvent.ACTION_UP)
                assertTrue(fixture.callbacks.isEmpty())
                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_DOWN))
            }
            awaitCancellationLongPressDeadline()
            instrumentation.runOnMainSync {
                assertEquals(listOf("long"), fixture.callbacks)
                assertTrue(view.hasFocus())
                assertEquals(9, view.selectionStart); assertEquals(9, view.selectionEnd)
                assertFalse(fixture.linkPaint.active)
                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_UP))
                assertEquals(listOf("long"), fixture.callbacks)
                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_DOWN))
                assertTrue(fixture.touch(android.view.MotionEvent.ACTION_UP))
                assertEquals(listOf("long", "click"), fixture.callbacks)
                fixture.focus()
                view.setSelection(7, fixture.text.length)
                val focusedRect = android.graphics.Rect().also(view::getFocusedRect)
                view.cancelPendingInputEvents()
                assertEquals("Selection stays here", view.selectedTextForCopy())
                assertEquals(7, view.selectionStart); assertEquals(fixture.text.length, view.selectionEnd)
                assertEquals(focusedRect, android.graphics.Rect().also(view::getFocusedRect))
                fixture.assertFocusedSource()
                assertEquals(listOf("long", "click"), fixture.callbacks)
            }
        }

    @Test fun ordinaryAbsoluteLabelsKeepNearestPaddingOriginAndSourcePaintOrder() {
        val black = android.graphics.Color.BLACK
        val calls = mutableListOf<Int>()
        val actions = List<() -> Unit>(4) { index -> { calls += index } }
        val zero = FloatMargins(0f, 0f, 0f, 0f)
        val outerId = 100
        val wrapperId = 200
        val imageId = 700
        val outerMargin = FloatMargins(7f, 0f, 0f, 9f)
        val outerPadding = FloatMargins(13f, 5f, 3f, 11f)
        data class Label(val text: String, val width: Float, val left: Float, val top: Float,
            val alignment: Layout.Alignment, val rtl: Boolean, val paint: TextPaint,
            val source: SpannableString, val action: (() -> Unit)?)
        fun label(text: String, width: Float, left: Float, top: Float,
            alignment: Layout.Alignment, rtl: Boolean, color: Int, bold: Boolean,
            action: (() -> Unit)?, noWrap: Boolean = true): Label {
            val resolved = TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                textSize = 18f
                this.color = color
                typeface = android.graphics.Typeface.create(android.graphics.Typeface.SANS_SERIF,
                    if (bold) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                if (!noWrap) {
                    isSubpixelText = true
                    letterSpacing = 1f / 32f
                }
            }
            val source = SpannableString(text).apply {
                setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(resolved),
                    NativeLineHeightPolicy.Pixels(20f), strut = true), 0, length,
                    android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (noWrap) setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap,
                    inheritedOwner = true, sourceLineStarts = listOf(0)), 0, length,
                    android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                else setSpan(NativeAuthoredTextWrap(TextWrap.Normal), 0, length,
                    android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            return Label(text, width, left, top, alignment, rtl, resolved, source, action)
        }
        fun shaped(label: Label, width: Float = label.width,
            carried: List<NativeFloatExclusion> = emptyList()): NativeFloatGeometry =
            NativeFloatGeometry.build(label.source, label.paint, kotlin.math.floor(width).toInt(),
                emptyList(), alignment = label.alignment,
                textDirection = if (label.rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
                carriedExclusions = carried, exactAvailableWidth = width, nodeFactory = { geometry ->
                    label.action?.let { action -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK,
                        0, label.text.length, geometry.rectsForRange(0, label.text.length),
                        label.text, null, action)) } ?: emptyList()
                })
        fun textPart(label: Label) = NativeFloatContextPart.Text(label.source,
            { width, carried -> shaped(label, width.toFloat(), carried) },
            buildAtWidth = { width, carried -> shaped(label, width, carried) })
        fun horizontal(content: Float, margin: Float = 0f, padding: Float = 0f, right: Float = 0f) =
            NativeContainerHorizontal(margin + padding + content + right, content,
                padding + content + right, margin, margin + padding, 0f, margin + padding + content + right)
        fun container(id: Int, width: Float, parts: List<NativeFloatContextPart>,
            margin: FloatMargins = zero, padding: FloatMargins = zero,
            containing: NativeAbsoluteContainingBlock? = null,
            absolute: NativeAbsolutePosition? = null) = NativeFloatContextPart.Container(id,
            kotlin.math.floor(width).toInt(), { _, _ -> error("Prepared source must be measured recursively") },
            margins = margin, padding = padding, preparedParts = parts,
            horizontal = horizontal(width, margin.left, padding.left, padding.right),
            fixedContentHeight = if (absolute == null) null else 20f,
            absolutePosition = absolute, absoluteContainingBlock = containing)
        val tail = label("Following normal body", 280f, 0f, 0f, Layout.Alignment.ALIGN_NORMAL,
            false, black, false, null)
        val tailReference = shaped(tail)
        data class Scene(val geometry: NativeFloatContextGeometry, val input: NativeContextPaintInput,
            val labels: List<Label>, val references: List<NativeFloatGeometry>,
            val expectedBoxes: List<RectF>, val paintSequence: List<Int>, val ranks: Map<Int, Int>,
            val normal: NativeFloatContextGeometry, val tailTop: Float)
        fun scene(marginLeft: Float, paddingLeft: Float, paddingTop: Float,
            nearer: Boolean, fractional: Boolean = false, overflow: Boolean = false,
            wrongOwner: Boolean = false): Scene {
            val fraction = if (fractional) .5f else 0f
            val labels = listOf(
                label("MMMM", 120f + fraction, 40f, 30f, Layout.Alignment.ALIGN_CENTER,
                    false, android.graphics.Color.RED, false, actions[0]),
                label("MMMM", 120f + fraction, 40f, 30f, Layout.Alignment.ALIGN_CENTER,
                    false, android.graphics.Color.BLUE, false, actions[1]),
                label(if (fractional) "\u05d0\u05d1\u05d2\u05d3" else "middle", 160f + fraction, 60f, 65f,
                    if (fractional) Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_OPPOSITE,
                    fractional, android.graphics.Color.GREEN, false, actions[2]),
                label(if (overflow) "W".repeat(40) else "MMMM", if (overflow) 340.5f else 160f + fraction,
                    70f, 90f, Layout.Alignment.ALIGN_OPPOSITE, false, android.graphics.Color.MAGENTA,
                    false, actions[3]),
                label("MMMM", 160f + fraction, 70f, 90f, Layout.Alignment.ALIGN_OPPOSITE,
                    false, black, true, null))
            val references = labels.map { shaped(it) }
            val wrapperMargin = FloatMargins(5f, 0f, 0f, marginLeft)
            val wrapperPadding = FloatMargins(paddingTop, 3f, 2f, paddingLeft)
            val owner = if (nearer && !wrongOwner) wrapperId else outerId
            val absoluteParts = labels.mapIndexed { index, value ->
                container(300 + index, value.width, listOf(textPart(value)),
                    absolute = NativeAbsolutePosition(owner, value.left, value.top))
            }
            fun body(withLabels: Boolean): List<NativeFloatContextPart> {
                val image = NativeFloatContextPart.Child(imageId, NativeBlockWidth.FixedPx(240f),
                    { request ->
                        assertEquals(240f, checkNotNull(request.requestedWidth), 0f)
                        NativeBlockMeasure(240f, 240f, 120f)
                    })
                val wrapper = container(wrapperId, 160f, if (withLabels) absoluteParts else emptyList(),
                    wrapperMargin, wrapperPadding,
                    if (nearer) NativeAbsoluteContainingBlock(paddingLeft, paddingTop) else null)
                val outer = container(outerId, 240f, listOf(image, wrapper), outerMargin, outerPadding,
                    NativeAbsoluteContainingBlock(outerPadding.left, outerPadding.top))
                return listOf(outer, textPart(tail))
            }
            val geometry = NativeFloatContextGeometry.build(280, body(true), adjoining = true)
            val normal = NativeFloatContextGeometry.build(280, body(false), adjoining = true)
            // The containing block's padding edge precedes its content edge. A static
            // wrapper changes only the traversal origin, not this CSS coordinate basis.
            val originX = if (nearer) 20f + marginLeft else 9f
            val originY = if (nearer) 20f + 120f + 5f else 7f
            val expectedBoxes = labels.map { RectF(originX + it.left, originY + it.top,
                originX + it.left + it.width, originY + it.top + 20f) }
            val tree = listOf(NativePaintOrderNode(0, positioned = true,
                children = listOf(NativePaintOrderNode(1), NativePaintOrderNode(2, positioned = nearer,
                    children = labels.indices.map { index -> NativePaintOrderNode(3 + 2 * index,
                        positioned = true, children = listOf(NativePaintOrderNode(4 + 2 * index)),
                        absolutePositionContainingBlock = if (nearer) 2 else 0) },
                    absoluteContainingBlock = nearer)), absoluteContainingBlock = true), NativePaintOrderNode(13))
            val sequence = nativeContextPaintSequence(tree)
            assertEquals(listOf(13, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12), sequence)
            val ranks = sequence.withIndex().associate { it.value to it.index }
            val leafRanks = labels.indices.associate { it + 1 to ranks.getValue(4 + 2 * it) } + (6 to ranks.getValue(13))
            val boxes = listOf(NativePaintBox(outerId, ranks.getValue(0), (0..5).toSet()),
                NativePaintBox(wrapperId, ranks.getValue(2), (1..5).toSet())) + labels.indices.map {
                NativePaintBox(300 + it, ranks.getValue(3 + 2 * it), setOf(it + 1)) }
            return Scene(geometry, NativeContextPaintInput(geometry, leafRanks,
                mapOf(imageId to ranks.getValue(1)), boxes), labels, references, expectedBoxes,
                sequence, ranks, normal, 7f + 13f + 120f + 5f + paddingTop + 2f + 3f)
        }
        fun shifted(rect: RectF, x: Float, y: Float) = RectF(rect).apply { offset(x, y) }
        fun verify(value: Scene) {
            val geometry = value.geometry
            assertEquals(280, geometry.width)
            assertEquals(value.normal.usedHeight, geometry.usedHeight, 0f)
            assertEquals(value.normal.textBottom, geometry.textBottom, 0f)
            assertEquals(value.tailTop + tailReference.textBottom, geometry.textBottom, 0f)
            assertEquals(value.normal.ownExclusions, geometry.ownExclusions)
            assertTrue(geometry.ownExclusions.isEmpty())
            assertTrue(geometry.flowChildren.isEmpty())
            assertEquals(RectF(20f, 20f, 260f, 140f), geometry.children.single().bounds)
            assertEquals(value.normal.children.single().bounds, geometry.children.single().bounds)
            assertEquals("\ufffc\n" + value.labels.joinToString("\n") { it.text } + "\n" + tail.text,
                geometry.text.toString())
            assertEquals(4, geometry.nodes.size)
            assertEquals((0..3).toList(), geometry.nodes.map { it.id })
            val leaves = geometry.inputLeaves()
            assertEquals((1..6).toList(), leaves.map { it.sourceIndex })
            value.labels.forEachIndexed { index, label ->
                val expected = value.expectedBoxes[index]
                assertEquals(expected, geometry.ordinaryBounds[300 + index])
                val leaf = leaves.single { it.sourceIndex == index + 1 }
                val reference = value.references[index]
                assertEquals(expected.left, leaf.x, 0f)
                assertEquals(expected.top, leaf.y, 0f)
                assertEquals(label.text, geometry.text.subSequence(leaf.offset, leaf.offset + label.text.length).toString())
                assertEquals(reference.rectsForRange(0, label.text.length).map { shifted(it, expected.left, expected.top) },
                    geometry.rectsForRange(leaf.offset, leaf.offset + label.text.length))
                assertEquals(reference.characterRects(0, label.text.length).map { it?.let { box -> shifted(box, expected.left, expected.top) } },
                    geometry.characterRects(leaf.offset, label.text.length))
                for (offset in 0 until label.text.length) assertEquals(
                    shifted(reference.caretRect(offset), expected.left, expected.top), geometry.caretRect(leaf.offset + offset))
                assertEquals(1, reference.shapedLineCount)
                val advance = label.paint.measureText(label.text)
                assertEquals(advance, reference.nativeLineAdvance(0), .0001f)
                val band = checkNotNull(reference.nativeRubyLineAdvanceBounds(0))
                if (label.alignment == Layout.Alignment.ALIGN_CENTER)
                    assertEquals((label.width - advance) / 2f, band.left, .0001f)
                else assertEquals(label.width, band.right, .0001f)
                if (index < 4) {
                    val node = geometry.nodes[index]
                    assertEquals(leaf.offset, node.start)
                    assertEquals(leaf.offset + label.text.length, node.end)
                    assertSame(actions[index], node.onClick)
                    assertEquals(geometry.rectsForRange(node.start, node.end), node.bounds)
                }
            }
            val tailLeaf = leaves.single { it.sourceIndex == 6 }
            assertEquals(value.tailTop, tailLeaf.y, 0f)
            assertEquals(value.tailTop + checkNotNull(tailReference.textBaselines?.first),
                checkNotNull(geometry.textBaselines?.first), 0f)
            assertEquals(geometry.text.toString(), value.input.text.toString())
            assertEquals(geometry.nodes.map { it.start to it.end }, value.input.nodes.map { it.start to it.end })
        }
        fun raster(draw: (android.graphics.Canvas) -> Unit): IntArray {
            val bitmap = android.graphics.Bitmap.createBitmap(900, 400, android.graphics.Bitmap.Config.ARGB_8888)
            var failure: Throwable? = null
            try {
                draw(android.graphics.Canvas(bitmap))
                return IntArray(bitmap.width * bitmap.height).also {
                    bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                }
            } catch (error: Throwable) { failure = error; throw error }
            finally {
                try { bitmap.recycle() } catch (cleanup: Throwable) {
                    val primary = failure
                    if (primary == null) throw cleanup
                    if (primary !== cleanup) primary.addSuppressed(cleanup)
                }
            }
        }
        fun paintScene(value: Scene) = raster { canvas ->
            value.paintSequence.forEach { source ->
                if (source == 1) canvas.drawRect(value.geometry.children.single().bounds,
                    android.graphics.Paint().apply { color = android.graphics.Color.CYAN })
                val index = when {
                    source == 13 -> 6
                    source in 4..12 && source % 2 == 0 -> (source - 4) / 2 + 1
                    else -> null
                }
                index?.let { leaf ->
                    val placed = checkNotNull(value.geometry.textPaintPart(leaf))
                    val saved = canvas.save()
                    try { canvas.translate(placed.x, placed.y); placed.geometry.paint(canvas) }
                    finally { canvas.restoreToCount(saved) }
                }
            }
        }
        fun overlappingInputAndPaint(value: Scene) {
            calls.clear()
            val actual = paintScene(value)
            val top = value.expectedBoxes[1]
            val blueReference = raster { canvas ->
                canvas.translate(top.left, top.top); value.references[1].paint(canvas)
            }
            val blue = blueReference.indices.firstOrNull { blueReference[it] == android.graphics.Color.BLUE }
            assertNotNull("The independently shaped top label must have an opaque source-color pixel", blue)
            val pixel = checkNotNull(blue)
            assertEquals(android.graphics.Color.BLUE, actual[pixel])
            val x = (pixel % 900) + .5f
            val y = (pixel / 900) + .5f
            assertTrue(value.geometry.nodes[0].contains(x, y))
            assertTrue(value.geometry.nodes[1].contains(x, y))
            assertEquals(1, checkNotNull(value.input.interactionNodeAt(x, y)).id)
            val leaf = value.geometry.inputLeaves().single { it.sourceIndex == 2 }
            assertEquals(leaf.offset + value.references[1].offsetForPosition(x - top.left, y - top.top),
                value.input.offsetForPosition(x, y))
            checkNotNull(value.input.interactionNodeAt(x, y)?.onClick).invoke()
            listOf(0, 2, 3).forEach { checkNotNull(value.geometry.nodes[it].onClick).invoke() }
            assertEquals(listOf(1, 0, 2, 3), calls)
            val under = value.geometry.nodes[3].bounds.single()
            val self = value.references[4].rectsForRange(0, value.labels[4].text.length).single().let {
                shifted(it, value.expectedBoxes[4].left, value.expectedBoxes[4].top) }
            val intersection = RectF(under)
            assertTrue(intersection.intersect(self))
            assertTrue(value.geometry.nodes[3].contains(intersection.centerX(), intersection.centerY()))
            val selfReference = raster { canvas ->
                canvas.translate(value.expectedBoxes[4].left, value.expectedBoxes[4].top)
                value.references[4].paint(canvas)
            }
            val selfPixel = selfReference.indices.firstOrNull { index ->
                selfReference[index] == black && under.contains((index % 900) + .5f, (index / 900) + .5f)
            }
            assertNotNull("Actual bold self ink must overlap the earlier source link", selfPixel)
            assertEquals(black, actual[checkNotNull(selfPixel)])
            assertNull("Later bold self text blocks the earlier link without creating a new action",
                value.input.interactionNodeAt(intersection.centerX(), intersection.centerY()))
            val selfLeaf = value.geometry.inputLeaves().single { it.sourceIndex == 5 }
            assertEquals(selfLeaf.offset + value.references[4].offsetForPosition(
                intersection.centerX() - value.expectedBoxes[4].left,
                intersection.centerY() - value.expectedBoxes[4].top),
                value.input.offsetForPosition(intersection.centerX(), intersection.centerY()))
        }
        val first = scene(17f, 19f, 7f, nearer = false)
        val changedStatic = scene(31f, 23f, 11f, nearer = false)
        val nearest = scene(31f, 23f, 11f, nearer = true)
        val fractional = scene(17f, 19f, 7f, nearer = false, fractional = true)
        listOf(first, changedStatic, nearest, fractional).forEach { verify(it); overlappingInputAndPaint(it) }
        assertEquals(first.expectedBoxes, changedStatic.expectedBoxes)
        assertNotEquals(changedStatic.expectedBoxes, nearest.expectedBoxes)
        assertThrows(UnsupportedFloatLayout::class.java) { scene(31f, 23f, 11f, nearer = true, wrongOwner = true) }
        val overflow = scene(17f, 19f, 7f, nearer = false, overflow = true)
        verify(overflow)
        assertTrue(overflow.labels[3].width > 240f)
        assertTrue(overflow.references[3].nativeLineAdvance(0) > overflow.labels[3].width)
        assertEquals(first.geometry.usedHeight, overflow.geometry.usedHeight, 0f)
        assertTrue(overflow.geometry.scrollableBounds.right >= overflow.expectedBoxes[3].right)
        assertTrue(overflow.geometry.scrollableBounds.right > overflow.geometry.width)
        assertEquals(first.geometry.children.single().bounds, overflow.geometry.children.single().bounds)

        // Normal fitting consumes the fractional width itself, independently checked
        // against the public native fitter using the complete original measured paragraph.
        val normal = label("alpha beta gamma delta epsilon", 120.5f, 0f, 0f,
            Layout.Alignment.ALIGN_CENTER, false, black, false, null, noWrap = false)
        val measured = checkNotNull(NativeFloatRowRuns(normal.source, normal.paint,
            TextDirectionHeuristics.LTR).paragraphs.single().measured)
        val breaker = android.graphics.text.LineBreaker.Builder()
            .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(android.graphics.text.LineBreaker.HYPHENATION_FREQUENCY_NONE).build()
        fun fit(width: Float) = breaker.computeLineBreaks(measured,
            android.graphics.text.LineBreaker.ParagraphConstraints().apply { setWidth(width) }, 0)
        val threshold = normal.text.indices.filter { normal.text[it] == ' ' }.drop(1)
            .map { measured.getWidth(0, it) }.firstOrNull { exact ->
                val rounded = kotlin.math.floor(exact)
                exact > rounded && fit(exact).getLineBreakOffset(0) > fit(rounded).getLineBreakOffset(0)
            }
        assertNotNull("A real ordinary word boundary must discriminate Float fitting from integer flooring", threshold)
        for (width in listOf(120.5f, checkNotNull(threshold))) {
            val result = fit(width)
            val absolute = container(901, width, listOf(textPart(normal.copy(width = width))),
                absolute = NativeAbsolutePosition(900, 0f, 0f))
            val owner = container(900, 240f, listOf(absolute), containing = NativeAbsoluteContainingBlock(0f, 0f))
            val normalContext = NativeFloatContextGeometry.build(240, listOf(owner), adjoining = true)
            val normalLeaf = normalContext.inputLeaves().single().geometry as NativeFloatGeometry
            assertTrue(result.lineCount > 1)
            assertEquals(result.lineCount, normalLeaf.shapedLineCount)
            assertEquals((0 until result.lineCount).map { result.getLineBreakOffset(it) },
                (0 until normalLeaf.shapedLineCount).map { normalLeaf.nativeRangeOfLine(it).second })
            assertEquals(normal.text, normalContext.text.toString())
            assertEquals(0f, normalContext.usedHeight, 0f)
            assertEquals(RectF(0f, 0f, width, 20f), normalContext.ordinaryBounds[901])
            assertTrue(normalContext.scrollableBounds.bottom >= normalLeaf.textBottom)
        }
        verify(scene(17f, 19f, 7f, nearer = false))
    }

    @Test
    fun soleStaticInlineUsesParentFirstFragmentThenFitsRemainingWidthWithoutFlow() {
        val containing = 100.5f
        var calls = 0
        val action: () -> Unit = { calls++ }
        fun paint(size: Float) = TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            textSize = size
            typeface = android.graphics.Typeface.MONOSPACE
            color = android.graphics.Color.BLUE
            isSubpixelText = true
        }
        data class Fixture(val prepared: NativePreparedText, val source: SpannableString,
            val child: TextPaint, val parent: TextPaint, val childHeight: Float, val parentHeight: Float,
            val rtl: Boolean, val alignment: Layout.Alignment, val noWrap: Boolean)
        fun fixture(text: String = "MMMM MMMM MMMM ", rtl: Boolean = false,
            alignment: Layout.Alignment = Layout.Alignment.ALIGN_CENTER,
            parentHeight: Float = 60f, childHeight: Float = 20f, size: Float = 18f,
            noWrap: Boolean = false, normalChild: Boolean = false): Fixture {
            val child = paint(size)
            val parent = paint(24f)
            val source = SpannableString(text).apply {
                setSpan(object : android.text.style.MetricAffectingSpan(), NativeInlineSafePaintSpan {
                    override fun updateMeasureState(target: TextPaint) { target.set(child) }
                    override fun updateDrawState(target: TextPaint) { target.set(child) }
                }, 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(child),
                    if (normalChild) NativeLineHeightPolicy.Normal else NativeLineHeightPolicy.Pixels(childHeight),
                    strut = true), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (noWrap) setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap,
                    inheritedOwner = true, sourceLineStarts = listOf(0)), 0, length,
                    android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                else setSpan(NativeAuthoredTextWrap(TextWrap.Normal), 0, length,
                    android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val prepared = NativePreparedText(child, { source }, { geometry ->
                listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, 0, text.length,
                    geometry.rectsForRange(0, text.length), text, null, action))
            }, if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
                staticInline = NativeStaticInlineText(parent, NativeLineHeightPolicy.Pixels(parentHeight),
                    if (rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr, alignment))
            return Fixture(prepared, source, child, parent, childHeight, parentHeight, rtl, alignment, noWrap)
        }
        fun real(value: Fixture, width: Float, exclusions: List<NativeFloatExclusion> = emptyList()) =
            NativeFloatGeometry.build(value.source, value.child, kotlin.math.floor(width).toInt(), emptyList(),
                textDirection = value.prepared.direction, carriedExclusions = exclusions,
                exactAvailableWidth = width, nodeFactory = value.prepared.nodes)
        fun textPart(value: Fixture) = NativeFloatContextPart.Text(value.source,
            { width, carried -> real(value, width.toFloat(), carried) },
            buildAtWidth = { width, carried -> real(value, width, carried) })
        fun horizontal(width: Float) = NativeContainerHorizontal(width, width, width, 0f, 0f, 0f, width)
        fun box(id: Int, parts: List<NativeFloatContextPart>, at: NativeAbsoluteStaticPosition? = null,
            value: Fixture? = null, relative: Boolean = false) = NativeFloatContextPart.Container(id,
            kotlin.math.floor(containing).toInt(), { _, _ -> error("Only prepared source may be measured") },
            preparedParts = parts, horizontal = horizontal(containing),
            absoluteContainingBlock = if (relative) NativeAbsoluteContainingBlock(0f, 0f) else null,
            absoluteStatic = at, staticInlineText = value?.prepared)
        fun scene(value: Fixture, carried: List<NativeFloatExclusion> = emptyList(),
            wrongParent: Boolean = false, intermediary: Boolean = false, sibling: Boolean = false): NativeFloatContextGeometry {
            val absolute = box(2, listOf(textPart(value)), NativeAbsoluteStaticPosition(if (wrongParent) 9 else 1), value)
            val body = if (intermediary) listOf(box(3, listOf(absolute)))
                else if (sibling) listOf(absolute, textPart(value)) else listOf(absolute)
            return NativeFloatContextGeometry.build(kotlin.math.floor(containing).toInt(),
                listOf(box(1, body, relative = true)), containAtEnd = false, carriedExclusions = carried,
                allowProtrudingFloats = true, adjoining = true)
        }
        // Independent platform fit oracle: native bidi style runs, real Float width,
        // and an explicit first-row line breaker, without our static-position helper.
        fun measured(value: Fixture): android.graphics.text.MeasuredText {
            val chars = value.source.toString().toCharArray()
            val bidi = android.icu.text.Bidi().apply { setPara(chars, (if (value.rtl) 1 else 0).toByte(), null) }
            val builder = android.graphics.text.MeasuredText.Builder(chars).setComputeLayout(true).setComputeHyphenation(false)
            var first = 0
            while (first < chars.size) {
                val level = bidi.getLevelAt(first)
                var last = first + 1
                while (last < chars.size && bidi.getLevelAt(last) == level) last++
                builder.appendStyleRun(value.child, last - first, level.toInt() and 1 != 0)
                first = last
            }
            return builder.build()
        }
        fun expected(value: Fixture, laneLeft: Float = 0f, laneRight: Float = containing, firstTop: Float = 0f): RectF {
            val measure = measured(value)
            val text = value.source.toString()
            val end = if (value.noWrap) text.length else {
                val breaker = android.graphics.text.LineBreaker.Builder()
                    .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(android.graphics.text.LineBreaker.HYPHENATION_FREQUENCY_NONE).build()
                breaker.computeLineBreaks(measure, android.graphics.text.LineBreaker.ParagraphConstraints().apply {
                    setWidth(laneRight - laneLeft)
                }, 0).getLineBreakOffset(0)
            }
            var visibleEnd = end
            while (end < text.length && visibleEnd > 0 && text[visibleEnd - 1] == ' ') visibleEnd--
            val visible = measure.getWidth(0, visibleEnd)
            val left = when (value.alignment) {
                Layout.Alignment.ALIGN_CENTER -> laneLeft + (laneRight - laneLeft - visible) / 2f
                Layout.Alignment.ALIGN_NORMAL -> if (value.rtl) laneRight - visible else laneLeft
                else -> if (value.rtl) laneLeft else laneRight - visible
            }
            val anchor = if (value.rtl) left + visible else left
            val maximum = measure.getWidth(0, text.length)
            var minimum = 0f
            var wordStart = 0
            for (endWord in 0..text.length) if (endWord == text.length || text[endWord] == ' ') {
                minimum = maxOf(minimum, measure.getWidth(wordStart, endWord)); wordStart = endWord + 1
            }
            if (value.noWrap) minimum = maximum
            val available = if (value.rtl) anchor else containing - anchor
            val width = minOf(maxOf(minimum, available), maximum)
            val parentMetrics = value.parent.fontMetrics
            val childMetrics = value.child.fontMetrics
            val parentTop = (parentMetrics.ascent + parentMetrics.descent - value.parentHeight) / 2f
            val childTop = (childMetrics.ascent + childMetrics.descent - value.childHeight) / 2f
            val baseline = firstTop - minOf(parentTop, childTop)
            val top = baseline + childMetrics.ascent
            val x = if (value.rtl) anchor - width else anchor
            return RectF(x, top, x + width, top + real(value, width).textBottom)
        }
        fun verify(value: Fixture, carried: List<NativeFloatExclusion> = emptyList(),
            laneLeft: Float = 0f, laneRight: Float = containing, firstTop: Float = 0f): NativeFloatContextGeometry {
            val geometry = scene(value, carried)
            val expected = expected(value, laneLeft, laneRight, firstTop)
            val actual = checkNotNull(geometry.ordinaryBounds[2])
            assertEquals(expected.left, actual.left, .0001f)
            assertEquals(expected.top, actual.top, .0001f)
            assertEquals(expected.right, actual.right, .0001f)
            assertEquals(expected.bottom, actual.bottom, .0001f)
            assertEquals(0f, geometry.usedHeight, 0f)
            assertEquals(0f, geometry.textBottom, 0f)
            assertEquals(0, geometry.height)
            assertEquals(value.source.toString(), geometry.text.toString())
            assertEquals(1, geometry.nodes.size)
            assertEquals(0 to value.source.length, geometry.nodes.single().let { it.start to it.end })
            assertSame(action, geometry.nodes.single().onClick)
            assertTrue(geometry.ownExclusions.isEmpty())
            assertTrue(geometry.children.isEmpty())
            assertTrue(geometry.flowChildren.isEmpty())
            assertNull(geometry.textBaselines)
            assertEquals(listOf(0), geometry.partOffsets)
            assertEquals(RectF(0f, 0f, containing, 0f), geometry.ordinaryBounds[1])
            val child = real(value, actual.width())
            val leaf = geometry.inputLeaves().single()
            assertEquals(0, leaf.sourceIndex)
            assertEquals(actual.left, leaf.x, 0f)
            assertEquals(actual.top, leaf.y, 0f)
            assertEquals(child.rectsForRange(0, value.source.length).map { RectF(it).apply { offset(actual.left, actual.top) } },
                geometry.rectsForRange(0, value.source.length))
            assertEquals(child.characterRects(0, value.source.length).map { it?.let { r -> RectF(r).apply { offset(actual.left, actual.top) } } },
                geometry.characterRects(0, value.source.length))
            for (offset in 0..value.source.length) assertEquals(RectF(child.caretRect(offset)).apply {
                offset(actual.left, actual.top)
            }, geometry.caretRect(offset))
            if (actual.width() > 0f) assertTrue(geometry.scrollableBounds.right >= actual.right)
            checkNotNull(geometry.nodes.single().onClick).invoke()
            return geometry
        }
        for (rtl in listOf(false, true)) for (align in listOf(Layout.Alignment.ALIGN_CENTER,
            Layout.Alignment.ALIGN_NORMAL, Layout.Alignment.ALIGN_OPPOSITE)) {
            verify(fixture(rtl = rtl, alignment = align))
            verify(fixture("MMMM \u05d0\u05d1\u05d2\u05d3 MMMM ", rtl = rtl, alignment = align))
        }
        val first = verify(fixture())
        fun raster(draw: (android.graphics.Canvas) -> Unit): IntArray {
            val bitmap = android.graphics.Bitmap.createBitmap(300, 300, android.graphics.Bitmap.Config.ARGB_8888)
            try {
                draw(android.graphics.Canvas(bitmap))
                return IntArray(300 * 300).also { bitmap.getPixels(it, 0, 300, 0, 0, 300, 300) }
            } finally { bitmap.recycle() }
        }
        val firstBox = checkNotNull(first.ordinaryBounds[2])
        val once = raster { canvas ->
            canvas.translate(firstBox.left, firstBox.top)
            real(fixture(), firstBox.width()).paint(canvas)
        }
        assertTrue("A fractional-alpha witness must distinguish duplicate replay",
            once.any { android.graphics.Color.alpha(it) in 1..254 })
        assertArrayEquals(once, raster(first::paint))
        val taller = verify(fixture(parentHeight = 90f))
        assertEquals(15f, checkNotNull(taller.ordinaryBounds[2]).top - checkNotNull(first.ordinaryBounds[2]).top, .0001f)
        val dominantChild = verify(fixture(parentHeight = 20f, childHeight = 80f))
        assertTrue(checkNotNull(dominantChild.ordinaryBounds[2]).top > checkNotNull(first.ordinaryBounds[2]).top)
        val left = listOf(NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 20.25f, 200f)))
        verify(fixture(), left, laneLeft = 21f)
        val right = listOf(NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(80.25f, 0f, containing, 200f)))
        verify(fixture(rtl = true), right, laneRight = 79.5f)
        val full = listOf(NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, containing, 17.25f)))
        verify(fixture(), full, firstTop = 17.25f)
        verify(fixture(noWrap = true), full, firstTop = 17.25f)
        verify(fixture("   "))
        verify(fixture("MMMM", size = 0f, childHeight = 0f))
        fun refused(block: () -> Unit) {
            try { block(); org.junit.Assert.fail("Unsupported source custody or line metrics must refuse") }
            catch (_: UnsupportedFloatLayout) { }
        }
        refused { scene(fixture(), wrongParent = true) }
        refused { scene(fixture(), intermediary = true) }
        refused { scene(fixture(), sibling = true) }
        refused { scene(fixture("MM\nMM")) }
        refused { scene(fixture(normalChild = true)) }
        verify(fixture())
        assertTrue(calls > 20)
    }


    @Test fun explicitMediaBoxesRetainOriginalTextWidthAndDirectionalDocumentOverflow() {
        val actions = mutableListOf<String>()
        val beforeAction: () -> Unit = { actions += "before" }
        val afterAction: () -> Unit = { actions += "after" }
        for (direction in TableContainingDirection.entries) {
            val rtl = direction == TableContainingDirection.Rtl
            fun control(width: Float, gapBefore: Float = 0f) = NativeFloatContextPart.Child(90,
                NativeBlockWidth.FixedPx(width), { request ->
                    assertEquals(180f, request.containingWidth, 0f)
                    assertEquals(width, checkNotNull(request.requestedWidth), 0f)
                    NativeBlockMeasure(width, width, 30f)
                }, gapAfter = 7f, gapBefore = gapBefore, logicalObject = false, ordinaryDirection = direction)
            fun build(width: Float) = NativeFloatContextGeometry.build(180, listOf(
                paragraph("Before source", rtl, action = beforeAction), control(width),
                paragraph("After source", rtl, action = afterAction)))
            val normal = build(180f)
            val wide = build(250f)
            assertEquals("Before source\nAfter source", wide.text.toString())
            assertEquals(normal.text.toString(), wide.text.toString())
            assertEquals(180, wide.width)
            assertEquals(normal.height, wide.height)
            assertEquals(normal.characterRects(0, normal.text.length), wide.characterRects(0, wide.text.length))
            assertEquals(normal.nodes.map { it.start to it.end }, wide.nodes.map { it.start to it.end })
            val media = wide.children.single()
            assertFalse(media.logicalObject)
            assertEquals(if (rtl) -70f else 0f, media.bounds.left, 0f)
            assertEquals(if (rtl) 180f else 250f, media.bounds.right, 0f)
            assertEquals(250f, media.bounds.width(), 0f)
            assertEquals(30f, media.bounds.height(), 0f)
            assertEquals(70, nativeDocumentHorizontalExtent(180, wide.scrollableBounds, rtl).range)
            assertEquals(0, nativeDocumentHorizontalExtent(180, normal.scrollableBounds, rtl).range)
            assertTrue(checkNotNull(wide.extents.ink).left <= media.bounds.left)
            assertTrue(checkNotNull(wide.extents.ink).right >= media.bounds.right)
            wide.characterRects(0, wide.text.length).filterNotNull().forEach {
                assertFalse("App-owned control space is not a source character", RectF.intersects(it, media.bounds))
            }
            assertEquals(listOf("Before source", "After source"), wide.nodes.map { it.label })
            wide.nodes.forEach { it.onClick?.invoke() }
            assertEquals(listOf("before", "after"), actions.takeLast(2))
            val restored = build(180f)
            assertEquals(normal.characterRects(0, normal.text.length), restored.characterRects(0, restored.text.length))
            assertEquals(0, nativeDocumentHorizontalExtent(180, restored.scrollableBounds, rtl).range)

            fun resized(containing: Int): NativeFloatContextGeometry {
                val observed = mutableListOf<Float>()
                val parts = listOf(NativeBlockWidth.FixedPx(250f), NativeBlockWidth.Percent(100f)).mapIndexed { index, rule ->
                    NativeFloatContextPart.Child(100 + index, rule, { request ->
                        observed += request.containingWidth
                        assertEquals(containing.toFloat(), request.containingWidth, 0f)
                        val requested = checkNotNull(request.requestedWidth)
                        assertEquals(if (index == 0) 250f else containing.toFloat(), requested, 0f)
                        NativeBlockMeasure(requested, requested, 30f)
                    }, logicalObject = false, ordinaryDirection = direction)
                }
                return NativeFloatContextGeometry.build(containing, parts).also {
                    assertEquals(listOf(containing.toFloat(), containing.toFloat()), observed)
                }
            }
            val initial = resized(180)
            val enlarged = resized(190)
            assertEquals(250f, initial.children[0].bounds.width(), 0f)
            assertEquals(250f, enlarged.children[0].bounds.width(), 0f)
            assertEquals(180f, initial.children[1].bounds.width(), 0f)
            assertEquals(190f, enlarged.children[1].bounds.width(), 0f)
            assertEquals(if (rtl) -60f else 0f, enlarged.children[0].bounds.left, 0f)
            assertEquals(70, nativeDocumentHorizontalExtent(180, initial.scrollableBounds, rtl).range)
            assertEquals(60, nativeDocumentHorizontalExtent(190, enlarged.scrollableBounds, rtl).range)
            assertEquals(initial.height, enlarged.height)
            assertEquals("", enlarged.text.toString())
            assertTrue(enlarged.nodes.isEmpty())

            val blocker = if (rtl) NativeFloatExclusion(TableFloatSide.Right,
                NativeFloatBounds(120.25f, 0f, 180f, 35.25f)) else NativeFloatExclusion(TableFloatSide.Left,
                NativeFloatBounds(0f, 0f, 42.25f, 35.25f))
            val fitting = NativeFloatContextGeometry.build(180, listOf(control(40f, .5f)),
                carriedExclusions = listOf(blocker))
            assertEquals(if (rtl) 80.25f else 42.25f, fitting.children.single().bounds.left, 0f)
            assertEquals(.5f, fitting.children.single().bounds.top, 0f)
            val below = NativeFloatContextGeometry.build(180, listOf(control(250f, .5f)),
                carriedExclusions = listOf(blocker))
            assertEquals(35.25f, below.children.single().bounds.top, 0f)
            assertEquals(if (rtl) -70f else 0f, below.children.single().bounds.left, 0f)
            assertEquals("", below.text.toString())
            assertTrue(below.nodes.isEmpty())
        }
    }
}
