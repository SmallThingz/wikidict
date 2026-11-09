package app.smallthingz.dict

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.icu.text.BreakIterator
import android.os.Bundle
import android.os.Build
import android.view.ActionMode
import android.view.GestureDetector
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Native interaction owner for a single formatting context, hosted by AndroidView. */
internal class NativeFloatTextView(context: Context) : View(context) {
    private var geometryFactory: ((Int) -> FloatTextGeometry)? = null
    private var geometry: FloatTextGeometry? = null
    private var needsGeometry = true
    private var lastMeasuredWidth = -1
    private var hostStateDescription: CharSequence? = null
    private var unsupportedCallback: (UnsupportedFloatLayout) -> Unit = {}
    private val density = resources.displayMetrics.density
    private val highlight = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x6633b5e5 }
    private val handlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xff1686c7.toInt() }
    private var anchor = 0
    private var extent = 0
    private var selecting = false
    private var actionMode: ActionMode? = null
    private var draggedHandle = 0 // 1: anchor, 2: extent
    private var pointerId = MotionEvent.INVALID_POINTER_ID
    private var dragOffsetX = 0f
    private var dragOffsetY = 0f
    private var virtualAccessibilityFocus = View.NO_ID
    private var virtualKeyboardFocus = View.NO_ID
    private var hoveredNode = View.NO_ID
    private val nodeProvider = Nodes()
    internal val selectionStart: Int get() = min(anchor, extent)
    internal val selectionEnd: Int get() = max(anchor, extent)
    internal val logicalText: CharSequence get() = geometry?.text ?: ""
    private val hasSelection: Boolean get() = selecting && anchor != extent
    internal fun revealLogicalOffset(offset: Int): Boolean {
        val current = geometry ?: return false
        if (offset !in 0..current.text.length) return false
        val rect = Rect(); current.caretRect(offset).roundOut(rect)
        rect.offset(paddingLeft, paddingTop)
        requestRectangleOnScreen(rect, false)
        return true
    }


    init {
        isFocusable = true
        isFocusableInTouchMode = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        setWillNotDraw(false)
    }

    /** The factory captures immutable text/style/media state and accepts the actual content width. */
    fun bind(factory: (Int) -> FloatTextGeometry, selectionColor: Int, handleColor: Int,
        hostStateDescription: CharSequence? = null, onUnsupported: (UnsupportedFloatLayout) -> Unit = {}) {
        val changed = geometryFactory !== factory
        geometryFactory = factory
        highlight.color = selectionColor
        handlePaint.color = handleColor
        this.hostStateDescription = hostStateDescription
        unsupportedCallback = onUnsupported
        if (changed) {
            needsGeometry = true
            requestLayout()
        }
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val desiredWidth = if (MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED)
            resources.displayMetrics.widthPixels else MeasureSpec.getSize(widthMeasureSpec)
        val width = max(1, desiredWidth - paddingLeft - paddingRight)
        if (needsGeometry || lastMeasuredWidth != width) {
            val previous = geometry?.text?.toString()
            val attemptedFactory = geometryFactory
            lastMeasuredWidth = width
            geometry = try { attemptedFactory?.invoke(width) } catch (failure: UnsupportedFloatLayout) {
                // Report outside measure so Compose can replace the view with its failure UI.
                post {
                    if (geometryFactory === attemptedFactory && lastMeasuredWidth == width && geometry == null)
                        unsupportedCallback(failure)
                }
                null
            }
            needsGeometry = false
            if (previous != logicalText.toString()) {
                clearSelection()
                virtualAccessibilityFocus = View.NO_ID
                virtualKeyboardFocus = View.NO_ID
                hoveredNode = View.NO_ID
            }
            require(geometry?.nodes.orEmpty().all { it.id >= 0 && it.start in 0..logicalText.length && it.end in it.start..logicalText.length })
            require(geometry?.nodes.orEmpty().map { it.id }.distinct().size == geometry?.nodes.orEmpty().size)
            sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
            actionMode?.invalidateContentRect()
        }
        val desiredHeight = (geometry?.height ?: 0) + paddingTop + paddingBottom
        setMeasuredDimension(resolveSize(desiredWidth, widthMeasureSpec), resolveSize(desiredHeight, heightMeasureSpec))
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val layout = geometry ?: return
        val save = canvas.save()
        canvas.translate(paddingLeft.toFloat(), paddingTop.toFloat())
        layout.paint(canvas)
        if (hasSelection) {
            layout.rectsForRange(selectionStart, selectionEnd).forEach { canvas.drawRect(it, highlight) }
            drawHandle(canvas, anchor)
            drawHandle(canvas, extent)
        } else if (selecting && hasFocus()) {
            val caret = layout.caretRect(extent)
            canvas.drawRect(caret.left, caret.top, caret.left + max(1f, density), caret.bottom, handlePaint)
        }
        geometry?.nodes?.find { it.id == virtualKeyboardFocus }?.bounds?.forEach {
            handlePaint.style = Paint.Style.STROKE
            handlePaint.strokeWidth = density
            canvas.drawRect(it, handlePaint)
            handlePaint.style = Paint.Style.FILL
        }
        canvas.restoreToCount(save)
    }

    private fun drawHandle(canvas: Canvas, offset: Int) {
        val rect = geometry!!.caretRect(offset)
        val center = handleCenter(offset)
        canvas.drawRect(rect.left, min(rect.bottom, center.second), rect.left + density, max(rect.bottom, center.second), handlePaint)
        canvas.drawCircle(center.first, center.second, handleRadius(), handlePaint)
    }

    private fun handleRadius() = min(6 * density, min(geometry!!.width, geometry!!.height) / 2f)

    private fun handleCenter(offset: Int): Pair<Float, Float> {
        val layout = geometry!!
        val rect = layout.caretRect(offset)
        val radius = handleRadius()
        return rect.left.coerceIn(radius, max(radius, layout.width - radius)) to
            (rect.bottom + 7 * density).coerceIn(radius, max(radius, layout.height - radius))
    }

    private fun handleAt(x: Float, y: Float): Int {
        if (!hasSelection) return 0
        fun distance(offset: Int): Float {
            val center = handleCenter(offset)
            return (x - center.first) * (x - center.first) + (y - center.second) * (y - center.second)
        }
        val first = distance(anchor)
        val second = distance(extent)
        val nearest = min(first, second)
        return if (nearest > 24 * density * 24 * density) 0 else if (first <= second) 1 else 2
    }

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(event: MotionEvent) = true
        override fun onSingleTapUp(event: MotionEvent): Boolean {
            if (draggedHandle != 0) return true
            val x = event.x - paddingLeft
            val y = event.y - paddingTop
            val node = hitNode(x, y)
            if (node?.onClick != null && !hasSelection) {
                node.onClick.invoke()
                sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_CLICKED)
            } else {
                clearSelection()
                val at = geometry?.offsetForPosition(x, y) ?: 0
                setSelection(at, at, showMenu = false)
                performClick()
            }
            return true
        }
        override fun onLongPress(event: MotionEvent) {
            val layout = geometry ?: return
            val node = hitNode(event.x - paddingLeft, event.y - paddingTop)
            if (node?.onLongClick != null) {
                node.onLongClick.invoke()
                sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_LONG_CLICKED)
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                return
            }
            if (logicalText.isEmpty()) return
            val at = layout.offsetForPosition(event.x - paddingLeft, event.y - paddingTop).coerceIn(0, logicalText.length - 1)
            val range = wordAt(at)
            setSelection(range.first, range.second, showMenu = true)
            draggedHandle = 2
            dragOffsetX = 0f
            dragOffsetY = 0f
            parent?.requestDisallowInterceptTouchEvent(true)
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }
    })

    override fun performClick(): Boolean { super.performClick(); return true }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (geometry == null) return false
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            requestFocus()
            pointerId = event.getPointerId(0)
            draggedHandle = handleAt(event.x - paddingLeft, event.y - paddingTop)
            if (draggedHandle != 0) {
                val caret = geometry!!.caretRect(if (draggedHandle == 1) anchor else extent)
                dragOffsetX = event.x - paddingLeft - caret.left
                dragOffsetY = event.y - paddingTop - caret.centerY()
                parent?.requestDisallowInterceptTouchEvent(true)
            }
        }
        if (draggedHandle == 0) gestures.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_MOVE && draggedHandle != 0) {
            val index = event.findPointerIndex(pointerId)
            if (index >= 0) {
                val x = event.getX(index) - paddingLeft - dragOffsetX
                val y = event.getY(index) - paddingTop - dragOffsetY
                val at = geometry!!.offsetForPosition(x, y)
                if (draggedHandle == 1) setSelection(at, extent, false) else setSelection(anchor, at, false)
                val visible = Rect()
                geometry!!.caretRect(at).roundOut(visible)
                visible.offset(paddingLeft, paddingTop)
                visible.inset(0, -(32 * density).roundToInt())
                requestRectangleOnScreen(visible, false)
            }
        }
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL ||
            (event.actionMasked == MotionEvent.ACTION_POINTER_UP && event.getPointerId(event.actionIndex) == pointerId)) {
            if (draggedHandle != 0 && hasSelection) showSelectionMenu()
            draggedHandle = 0
            pointerId = MotionEvent.INVALID_POINTER_ID
            parent?.requestDisallowInterceptTouchEvent(false)
            // Cancel pending long-press callbacks even when handles bypass the detector.
            val cancel = MotionEvent.obtain(event)
            cancel.action = MotionEvent.ACTION_CANCEL
            gestures.onTouchEvent(cancel)
            cancel.recycle()
        }
        return true
    }

    private fun hitNode(x: Float, y: Float): FloatInteractionNode? =
        geometry?.nodes?.lastOrNull { node -> node.contains(x, y) }

    internal fun setSelection(start: Int, end: Int, showMenu: Boolean = false) {
        require(start in 0..logicalText.length && end in 0..logicalText.length)
        anchor = start
        extent = end
        selecting = true
        invalidate()
        actionMode?.invalidate()
        actionMode?.invalidateContentRect()
        if (showMenu && hasSelection) showSelectionMenu()
        val event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED)
        event.setSource(this)
        event.className = "android.widget.TextView"
        event.packageName = context.packageName
        event.fromIndex = selectionStart
        event.toIndex = selectionEnd
        event.itemCount = logicalText.length
        event.text.add(logicalText)
        parent?.requestSendAccessibilityEvent(this, event)
    }

    private fun clearSelection() {
        anchor = 0
        extent = 0
        selecting = false
        actionMode?.finish()
        actionMode = null
        invalidate()
    }

    internal fun selectedTextForCopy(): String? =
        if (hasSelection) logicalText.toString().substring(selectionStart, selectionEnd) else null

    private fun copySelection(): Boolean {
        val text = selectedTextForCopy() ?: return false
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText(null, text))
        return true
    }

    private fun showSelectionMenu() {
        if (actionMode != null) { actionMode?.invalidate(); return }
        actionMode = startActionMode(object : ActionMode.Callback2() {
            override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
                menu.add(0, android.R.id.copy, 0, android.R.string.copy).setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM)
                menu.add(0, android.R.id.selectAll, 1, android.R.string.selectAll).setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM)
                return true
            }
            override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
                menu.findItem(android.R.id.copy).isEnabled = hasSelection
                menu.findItem(android.R.id.selectAll).isEnabled = logicalText.isNotEmpty() && selectionEnd - selectionStart < logicalText.length
                return true
            }
            override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean = when (item.itemId) {
                android.R.id.copy -> copySelection().also { if (it) mode.finish() }
                android.R.id.selectAll -> { setSelection(0, logicalText.length); true }
                else -> false
            }
            override fun onDestroyActionMode(mode: ActionMode) { actionMode = null }
            override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
                val range = geometry?.rectsForRange(selectionStart, selectionEnd).orEmpty()
                val bounds = RectF()
                range.forEach { bounds.union(it) }
                bounds.roundOut(outRect)
                outRect.offset(paddingLeft, paddingTop)
            }
        }, ActionMode.TYPE_FLOATING)
    }

    private fun wordAt(offset: Int): Pair<Int, Int> {
        val iterator = BreakIterator.getWordInstance(Locale.getDefault()).apply { setText(logicalText.toString()) }
        val end = iterator.following(offset).let { if (it == BreakIterator.DONE) logicalText.length else it }
        val start = iterator.preceding(end).let { if (it == BreakIterator.DONE) 0 else it }
        return start to end
    }

    private fun boundary(offset: Int, forward: Boolean, word: Boolean): Int {
        val iterator = (if (word) BreakIterator.getWordInstance(Locale.getDefault()) else BreakIterator.getCharacterInstance(Locale.getDefault()))
            .apply { setText(logicalText.toString()) }
        val next = if (forward) iterator.following(offset) else iterator.preceding(offset)
        return if (next == BreakIterator.DONE) (if (forward) logicalText.length else 0) else next
    }

    /** Reveal the first painted fragment without changing selection or invoking its action. */
    private fun revealVirtualNode(node: FloatInteractionNode) {
        val bounds = node.bounds.firstOrNull { !it.isEmpty } ?: return
        val visible = Rect()
        bounds.roundOut(visible)
        visible.offset(paddingLeft, paddingTop)
        requestRectangleOnScreen(visible, false)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val layout = geometry ?: return super.onKeyDown(keyCode, event)
        if (event.isCtrlPressed && keyCode == KeyEvent.KEYCODE_A) { setSelection(0, logicalText.length, true); return true }
        if (event.isCtrlPressed && keyCode == KeyEvent.KEYCODE_C) return copySelection()
        if (keyCode == KeyEvent.KEYCODE_ESCAPE && selecting) { clearSelection(); return true }
        if (keyCode == KeyEvent.KEYCODE_TAB) {
            val nodes = layout.nodes.filter { it.onClick != null || it.onLongClick != null }
            val current = nodes.indexOfFirst { it.id == virtualKeyboardFocus }
            val next = if (current < 0 && event.isShiftPressed) nodes.lastIndex else current + if (event.isShiftPressed) -1 else 1
            if (next !in nodes.indices) { virtualKeyboardFocus = View.NO_ID; invalidate(); return super.onKeyDown(keyCode, event) }
            virtualKeyboardFocus = nodes[next].id
            revealVirtualNode(nodes[next])
            sendNodeEvent(virtualKeyboardFocus, AccessibilityEvent.TYPE_VIEW_FOCUSED)
            invalidate()
            return true
        }
        if (keyCode == KeyEvent.KEYCODE_MENU || (keyCode == KeyEvent.KEYCODE_F10 && event.isShiftPressed)) {
            val focused = layout.nodes.find { it.id == virtualKeyboardFocus }
            if (focused?.onLongClick != null) {
                focused.onLongClick.invoke()
                sendNodeEvent(focused.id, AccessibilityEvent.TYPE_VIEW_LONG_CLICKED)
                return true
            }
            if (hasSelection) { showSelectionMenu(); return true }
        }
        if (keyCode == KeyEvent.KEYCODE_ENTER || keyCode == KeyEvent.KEYCODE_DPAD_CENTER) {
            val focused = layout.nodes.find { it.id == virtualKeyboardFocus }
            if (focused?.onClick != null) { focused.onClick.invoke(); sendNodeEvent(focused.id, AccessibilityEvent.TYPE_VIEW_CLICKED); return true }
        }
        val caret = layout.caretRect(extent)
        val next = when (keyCode) {
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                val forward = keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                if (event.isCtrlPressed) boundary(extent, forward, true) else layout.visualOffset(extent, if (forward) 1 else -1)
            }
            KeyEvent.KEYCODE_DPAD_UP -> layout.offsetForPosition(caret.left, caret.top - max(1f, caret.height() / 2))
            KeyEvent.KEYCODE_DPAD_DOWN -> layout.offsetForPosition(caret.left, caret.bottom + max(1f, caret.height() / 2))
            KeyEvent.KEYCODE_MOVE_HOME -> if (event.isCtrlPressed) 0 else layout.lineRange(extent).first
            KeyEvent.KEYCODE_MOVE_END -> if (event.isCtrlPressed) logicalText.length else
                layout.lineRange(extent).second.let { if (it > 0 && logicalText[it - 1] == '\n') it - 1 else it }
            else -> return super.onKeyDown(keyCode, event)
        }.coerceIn(0, logicalText.length)
        virtualKeyboardFocus = View.NO_ID
        setSelection(if (event.isShiftPressed) anchor else next, next)
        val visible = Rect()
        layout.caretRect(next).roundOut(visible)
        visible.offset(paddingLeft, paddingTop)
        requestRectangleOnScreen(visible)
        return true
    }

    override fun onDetachedFromWindow() {
        actionMode?.finish()
        super.onDetachedFromWindow()
    }

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        if (!gainFocus) virtualKeyboardFocus = View.NO_ID
        invalidate()
    }

    override fun getAccessibilityNodeProvider(): AccessibilityNodeProvider = nodeProvider

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = "android.widget.TextView"
        info.text = logicalText.toString()
        AccessibilityNodeInfoCompat.wrap(info).stateDescription = hostStateDescription
        if (Build.VERSION.SDK_INT >= 33) info.isTextSelectable = true
        info.isEditable = false
        if (selecting) info.setTextSelection(selectionStart, selectionEnd)
        info.movementGranularities = AccessibilityNodeInfo.MOVEMENT_GRANULARITY_CHARACTER or
            AccessibilityNodeInfo.MOVEMENT_GRANULARITY_WORD or AccessibilityNodeInfo.MOVEMENT_GRANULARITY_LINE or
            AccessibilityNodeInfo.MOVEMENT_GRANULARITY_PARAGRAPH
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_SELECTION)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_NEXT_AT_MOVEMENT_GRANULARITY)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY)
        if (hasSelection) info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_COPY)
        info.availableExtraData = listOf(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY)
        geometry?.nodes.orEmpty().forEach { info.addChild(this, it.id) }
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        when (action) {
            AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS -> {
                if (virtualAccessibilityFocus != View.NO_ID) {
                    sendNodeEvent(virtualAccessibilityFocus, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED)
                    virtualAccessibilityFocus = View.NO_ID
                }
            }
            AccessibilityNodeInfo.ACTION_SET_SELECTION -> {
                val start = arguments?.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, -1) ?: -1
                val end = arguments?.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, -1) ?: -1
                if (start == -1 && end == -1) { clearSelection(); sendAccessibilityEvent(AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED); return true }
                if (start !in 0..logicalText.length || end !in 0..logicalText.length) return false
                setSelection(start, end)
                return true
            }
            AccessibilityNodeInfo.ACTION_COPY -> return copySelection()
            AccessibilityNodeInfo.ACTION_NEXT_AT_MOVEMENT_GRANULARITY,
            AccessibilityNodeInfo.ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY -> return moveAccessibility(action, arguments)
        }
        return super.performAccessibilityAction(action, arguments)
    }

    private fun moveAccessibility(action: Int, arguments: Bundle?): Boolean {
        val layout = geometry ?: return false
        val forward = action == AccessibilityNodeInfo.ACTION_NEXT_AT_MOVEMENT_GRANULARITY
        val granularity = arguments?.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT) ?: return false
        val start = if (selecting) extent else if (forward) 0 else logicalText.length
        val next = when (granularity) {
            AccessibilityNodeInfo.MOVEMENT_GRANULARITY_CHARACTER -> boundary(start, forward, false)
            AccessibilityNodeInfo.MOVEMENT_GRANULARITY_WORD -> boundary(start, forward, true)
            AccessibilityNodeInfo.MOVEMENT_GRANULARITY_PARAGRAPH -> if (forward) {
                logicalText.toString().indexOf('\n', start).let { if (it < 0) logicalText.length else it + 1 }
            } else {
                logicalText.toString().lastIndexOf('\n', max(-1, start - 2)).let { it + 1 }
            }
            AccessibilityNodeInfo.MOVEMENT_GRANULARITY_LINE -> {
                if (forward) layout.lineRange(start).second else
                    layout.lineRange(max(0, start - 1)).first
            }
            else -> return false
        }
        if (next == start) return false
        val extend = arguments?.getBoolean(AccessibilityNodeInfo.ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN) == true
        setSelection(if (extend && selecting) anchor else if (extend) start else next, next)
        val event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY)
        event.setSource(this)
        event.className = "android.widget.TextView"
        event.packageName = context.packageName
        event.action = action
        event.movementGranularity = granularity
        event.fromIndex = min(start, next)
        event.toIndex = max(start, next)
        event.text.add(logicalText)
        parent?.requestSendAccessibilityEvent(this, event)
        return true
    }

    override fun dispatchHoverEvent(event: MotionEvent): Boolean {
        val manager = context.getSystemService(AccessibilityManager::class.java)
        if (!manager.isEnabled || !manager.isTouchExplorationEnabled) return super.dispatchHoverEvent(event)
        val next = if (event.actionMasked == MotionEvent.ACTION_HOVER_EXIT) View.NO_ID
            else hitNode(event.x - paddingLeft, event.y - paddingTop)?.id ?: View.NO_ID
        if (next != hoveredNode) {
            if (next != View.NO_ID) sendNodeEvent(next, AccessibilityEvent.TYPE_VIEW_HOVER_ENTER)
            if (hoveredNode != View.NO_ID) sendNodeEvent(hoveredNode, AccessibilityEvent.TYPE_VIEW_HOVER_EXIT)
            hoveredNode = next
        }
        return next != View.NO_ID || super.dispatchHoverEvent(event)
    }

    private fun sendNodeEvent(id: Int, type: Int) {
        val node = geometry?.nodes?.find { it.id == id } ?: return
        val event = AccessibilityEvent.obtain(type)
        event.setSource(this, id)
        event.packageName = context.packageName
        event.className = when (node.kind) {
                    FloatInteractionKind.IMAGE -> "android.widget.ImageView"
                    FloatInteractionKind.CONTROL -> "android.widget.Button"
                    else -> "android.widget.TextView"
                }
        if (node.label != null) event.contentDescription = node.label
        parent?.requestSendAccessibilityEvent(this, event)
    }

    private inner class Nodes : AccessibilityNodeProvider() {
        override fun createAccessibilityNodeInfo(virtualViewId: Int): AccessibilityNodeInfo? {
            if (virtualViewId == HOST_VIEW_ID) return AccessibilityNodeInfo.obtain(this@NativeFloatTextView).also {
                this@NativeFloatTextView.onInitializeAccessibilityNodeInfo(it)
            }
            val node = geometry?.nodes?.find { it.id == virtualViewId } ?: return null
            return AccessibilityNodeInfo.obtain().apply {
                setSource(this@NativeFloatTextView, node.id)
                setParent(this@NativeFloatTextView)
                packageName = context.packageName
                className = when (node.kind) {
                    FloatInteractionKind.IMAGE -> "android.widget.ImageView"
                    FloatInteractionKind.CONTROL -> "android.widget.Button"
                    else -> "android.widget.TextView"
                }
                AccessibilityNodeInfoCompat.wrap(this).isHeading = node.kind == FloatInteractionKind.HEADING
                val label = node.label ?: logicalText.subSequence(node.start, node.end)
                if (node.kind == FloatInteractionKind.IMAGE) contentDescription = label else text = label
                tooltipText = node.tooltip
                AccessibilityNodeInfoCompat.wrap(this).stateDescription = node.stateDescription
                isEnabled = this@NativeFloatTextView.isEnabled
                isFocusable = true
                isFocused = virtualKeyboardFocus == node.id
                isAccessibilityFocused = virtualAccessibilityFocus == node.id
                isClickable = node.onClick != null
                isLongClickable = node.onLongClick != null
                if (isClickable) addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK)
                if (isLongClickable) addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_LONG_CLICK)
                addAction(if (isAccessibilityFocused) AccessibilityNodeInfo.AccessibilityAction.ACTION_CLEAR_ACCESSIBILITY_FOCUS else AccessibilityNodeInfo.AccessibilityAction.ACTION_ACCESSIBILITY_FOCUS)
                addAction(if (isFocused) AccessibilityNodeInfo.AccessibilityAction.ACTION_CLEAR_FOCUS else AccessibilityNodeInfo.AccessibilityAction.ACTION_FOCUS)
                val bounds = RectF()
                node.bounds.forEach { bounds.union(it) }
                val local = Rect()
                bounds.roundOut(local)
                local.offset(paddingLeft, paddingTop)
                setBoundsInParent(local)
                val screen = screenRect(bounds)
                setBoundsInScreen(screen)
                val visible = Rect()
                isVisibleToUser = isShown && getGlobalVisibleRect(visible) && Rect.intersects(visible, screen)
            }
        }

        override fun findFocus(focus: Int): AccessibilityNodeInfo? = when (focus) {
            AccessibilityNodeInfo.FOCUS_ACCESSIBILITY -> if (virtualAccessibilityFocus != View.NO_ID) createAccessibilityNodeInfo(virtualAccessibilityFocus) else if (isAccessibilityFocused) createAccessibilityNodeInfo(HOST_VIEW_ID) else null
            AccessibilityNodeInfo.FOCUS_INPUT -> if (virtualKeyboardFocus != View.NO_ID) createAccessibilityNodeInfo(virtualKeyboardFocus) else if (hasFocus()) createAccessibilityNodeInfo(HOST_VIEW_ID) else null
            else -> null
        }

        override fun findAccessibilityNodeInfosByText(text: String, virtualViewId: Int): List<AccessibilityNodeInfo> =
            geometry?.nodes.orEmpty().filter { (virtualViewId == HOST_VIEW_ID || it.id == virtualViewId) &&
                (it.label ?: logicalText.subSequence(it.start, it.end)).contains(text, ignoreCase = true) }
                .mapNotNull { createAccessibilityNodeInfo(it.id) }

        override fun performAction(virtualViewId: Int, action: Int, arguments: Bundle?): Boolean {
            if (virtualViewId == HOST_VIEW_ID) return performAccessibilityAction(action, arguments)
            val node = geometry?.nodes?.find { it.id == virtualViewId } ?: return false
            when (action) {
                AccessibilityNodeInfo.ACTION_CLICK -> { node.onClick?.invoke() ?: return false; sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_CLICKED) }
                AccessibilityNodeInfo.ACTION_LONG_CLICK -> { node.onLongClick?.invoke() ?: return false; sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_LONG_CLICKED) }
                AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS -> {
                    if (virtualAccessibilityFocus == node.id) return false
                    this@NativeFloatTextView.performAccessibilityAction(AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS, null)
                    if (virtualAccessibilityFocus != View.NO_ID) sendNodeEvent(virtualAccessibilityFocus, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED)
                    virtualAccessibilityFocus = node.id
                    revealVirtualNode(node)
                    sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED)
                }
                AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS -> {
                    if (virtualAccessibilityFocus != node.id) return false
                    virtualAccessibilityFocus = View.NO_ID
                    sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED)
                }
                AccessibilityNodeInfo.ACTION_FOCUS -> {
                    if (!requestFocus()) return false
                    virtualKeyboardFocus = node.id
                    revealVirtualNode(node)
                    sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_FOCUSED)
                }
                AccessibilityNodeInfo.ACTION_CLEAR_FOCUS -> { if (virtualKeyboardFocus != node.id) return false; virtualKeyboardFocus = View.NO_ID }
                else -> return false
            }
            invalidate()
            return true
        }

        override fun addExtraDataToAccessibilityNodeInfo(virtualViewId: Int, info: AccessibilityNodeInfo, extraDataKey: String, arguments: Bundle?) {
            if (virtualViewId != HOST_VIEW_ID || extraDataKey != AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY) return
            val start = arguments?.getInt(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX, -1) ?: -1
            val length = arguments?.getInt(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH, -1) ?: -1
            if (start < 0 || length < 0 || length > 20_000 || start > logicalText.length - length) return
            val visible = Rect()
            val shown = isShown && getGlobalVisibleRect(visible)
            val rectangles = geometry?.characterRects(start, length)?.map { rect ->
                rect?.let { screenRect(it) }?.takeIf { shown && it.intersect(visible) }?.let { RectF(it) }
            }?.toTypedArray() ?: return
            check(rectangles.size == length)
            info.extras.putParcelableArray(extraDataKey, rectangles)
        }
    }

    private fun screenRect(bounds: RectF): Rect {
        // Build the public View transform chain, including Compose host transforms.
        // Align its origin with getLocationOnScreen to include the window offset.
        val transform = Matrix()
        var current: View? = this
        while (current != null) {
            transform.postConcat(current.matrix)
            val parentView = current.parent as? View
            transform.postTranslate(current.left.toFloat() - (parentView?.scrollX ?: 0),
                current.top.toFloat() - (parentView?.scrollY ?: 0))
            current = parentView
        }
        val origin = floatArrayOf(0f, 0f)
        transform.mapPoints(origin)
        val location = IntArray(2)
        getLocationOnScreen(location)
        val screen = RectF(bounds)
        screen.offset((paddingLeft - scrollX).toFloat(), (paddingTop - scrollY).toFloat())
        transform.mapRect(screen)
        screen.offset(location[0] - origin[0], location[1] - origin[1])
        return Rect().also { screen.roundOut(it) }
    }
}
