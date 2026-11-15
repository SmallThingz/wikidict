package app.smallthingz.dict

import android.content.Context
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.RectF
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.PointerInputModifierNode
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CollectionInfo
import androidx.compose.ui.semantics.ScrollAxisRange
import androidx.compose.ui.semantics.collectionInfo
import androidx.compose.ui.semantics.focused
import androidx.compose.ui.semantics.horizontalScrollAxisRange
import androidx.compose.ui.semantics.requestFocus
import androidx.compose.ui.semantics.scrollBy
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.viewinterop.AndroidView
import kotlin.math.ceil

internal enum class NativeTableFocusTransfer { None, RetainedForWide, RestoredForNarrow, RetainedUnavailable }

private data class NativeTableFocusPlacement(
    val available: Boolean = false,
    val narrow: Boolean = false,
    val viewportWidth: Float = 0f,
    val physicalOffset: Float = 0f,
    val overflow: Float = 0f,
    val targetAvailable: Boolean = false,
)

/** The original TABLE owns this focus target in both layouts. Its View paints only the
 * platform focus highlight; the existing grid remains the sole body/action renderer.
 * The platform exposes no public default-highlight color setter; the optional source
 * color request remains in policy and may have no effect on this native appearance. */
internal class NativeTableScrollFocusOwner internal constructor(val policy: TableScrollFocusPaint) {
    private var placement by mutableStateOf(NativeTableFocusPlacement())
    private var view: NativeTableScrollFocusView? = null
    private var target: NativeHorizontalScrollTarget? = null
    internal var ancestorClip: NativeScrollClip? = null
        private set
    private var closed = false
    var isFocused by mutableStateOf(false)
        private set
    var lastTransfer by mutableStateOf(NativeTableFocusTransfer.None)
        private set
    val canAcquireFocus: Boolean get() = !closed && placement.available && placement.narrow
    val canScroll: Boolean get() = canAcquireFocus && placement.overflow > 0f && placement.targetAvailable
    val physicalOffset: Float get() = placement.physicalOffset
    val overflow: Float get() = placement.overflow
    internal val paintsFocus: Boolean get() = canAcquireFocus && policy.mode == TableScrollFocusMode.UaAuto

    /** Called only after the real border/grid placement succeeds. All values use physical
     * coordinates; an RTL grid does not reverse this source scroll axis a second time. */
    fun update(narrow: Boolean, viewportWidth: Float, physicalOffset: Float, overflow: Float,
        target: NativeHorizontalScrollTarget?, ancestorClip: NativeScrollClip?) {
        if (closed) return
        require(listOf(viewportWidth, physicalOffset, overflow).all { it.isFinite() && it >= 0f })
        require(physicalOffset <= overflow)
        val previous = placement
        this.target = target
        this.ancestorClip = ancestorClip
        placement = NativeTableFocusPlacement(true, narrow, viewportWidth, physicalOffset, overflow, target != null)
        if (isFocused && !narrow) lastTransfer = NativeTableFocusTransfer.RetainedForWide
        else if (isFocused && !previous.narrow && narrow) lastTransfer = NativeTableFocusTransfer.RestoredForNarrow
        view?.syncOwner()
    }

    fun unavailable() {
        target = null
        placement = placement.copy(available = false)
        if (isFocused) lastTransfer = NativeTableFocusTransfer.RetainedUnavailable
        view?.syncOwner()
    }

    /** Preserve an already-held native focus during a refused layout. This is the last
     * actually placed View allocation, never a new source box, paint or hit region. */
    fun retainedUnavailableFocusSize(): IntSize? {
        val current = view ?: return null
        if (closed || placement.available || !current.isFocused || current.width <= 0 || current.height <= 0) return null
        return IntSize(current.width, current.height)
    }

    internal fun attach(value: NativeTableScrollFocusView) {
        check(view == null || view === value)
        view = value
        value.syncOwner()
    }

    internal fun detach(value: NativeTableScrollFocusView) {
        if (view !== value) return
        view = null
        isFocused = false
    }

    internal fun focusChanged(value: Boolean) { isFocused = value }

    internal fun positioned(coordinates: LayoutCoordinates) { view?.positioned(coordinates) }

    fun requestSourceFocus(): Boolean {
        val current = view ?: return false
        if (!canAcquireFocus || !current.isAttachedToWindow || !current.isShown) return false
        if (current.isFocused) return true
        // The public accessibility route leaves touch mode before requesting keyboard focus.
        return current.performAccessibilityAction(AccessibilityNodeInfo.ACTION_FOCUS, null)
    }

    fun scrollBy(physicalDistance: Float): Boolean {
        if (!canScroll || !physicalDistance.isFinite() || physicalDistance == 0f) return false
        return target?.scrollBy(physicalDistance)?.let { it.isFinite() && it != 0f } == true
    }

    internal fun keyDown(event: KeyEvent, horizontalStep: Float): Boolean {
        if (!canAcquireFocus) return false
        val delta = nativeTableFocusKeyDistance(event.keyCode, event.isAltPressed, event.isShiftPressed,
            horizontalStep, placement.viewportWidth, placement.physicalOffset, placement.overflow) ?: return false
        return scrollBy(delta)
    }

    internal fun close() {
        closed = true
        unavailable()
    }
}

/** Native key distances use the public platform scroll factor and the actual source viewport. */
internal fun nativeTableFocusKeyDistance(keyCode: Int, alt: Boolean, shift: Boolean,
    horizontalStep: Float, viewportWidth: Float, physicalOffset: Float, overflow: Float): Float? {
    if (!listOf(horizontalStep, viewportWidth, physicalOffset, overflow).all { it.isFinite() && it >= 0f } ||
        physicalOffset > overflow) return null
    // ScrollState stores integral offsets. Ask the bounded target for the whole integral
    // range so one edge key reaches its exact fractional final placement in either direction.
    val edge = ceil(overflow).toFloat()
    return when (keyCode) {
        KeyEvent.KEYCODE_DPAD_LEFT -> if (alt) -edge else -horizontalStep
        KeyEvent.KEYCODE_DPAD_RIGHT -> if (alt) edge else horizontalStep
        KeyEvent.KEYCODE_PAGE_UP -> -viewportWidth
        KeyEvent.KEYCODE_PAGE_DOWN -> viewportWidth
        KeyEvent.KEYCODE_SPACE -> if (shift) -viewportWidth else viewportWidth
        KeyEvent.KEYCODE_MOVE_HOME -> -edge
        KeyEvent.KEYCODE_MOVE_END -> edge
        else -> null
    }
}

@Composable
internal fun rememberNativeTableScrollFocusOwner(table: Table): NativeTableScrollFocusOwner {
    val owner = remember(NativeDelegatedTableIdentity(table)) {
        NativeTableScrollFocusOwner(checkNotNull(table.blockViewport?.focusPaint))
    }
    DisposableEffect(owner) { onDispose { owner.close() } }
    return owner
}

/** Attach to the actual shared border-box ancestor. Paired grid/scroll children omit only
 * their duplicate collection/axis semantics; their cell and A nodes stay descendants.
 * This viewport node uses physical LTR coordinates for Compose's AX scroll bridge;
 * the inner grid independently restores its source direction. */
internal fun Modifier.nativeTableScrollFocusSemantics(owner: NativeTableScrollFocusOwner,
    rows: Int, columns: Int): Modifier = testTag("compiled-table-scroll-focus").semantics {
    collectionInfo = CollectionInfo(rows, columns)
    if (owner.canAcquireFocus || owner.isFocused) focused = owner.isFocused
    if (owner.canAcquireFocus) requestFocus { owner.requestSourceFocus() }
    if (owner.canScroll) {
        horizontalScrollAxisRange = ScrollAxisRange({ owner.physicalOffset }, { owner.overflow }, false)
        scrollBy { x, _ -> owner.scrollBy(x) }
    }
}

/** Real native input focus with no body, click action, scrollbar or duplicate AX owner. */
internal class NativeTableScrollFocusView(context: Context, internal val owner: NativeTableScrollFocusOwner) : View(context) {
    private var coordinates: LayoutCoordinates? = null
    private var clearingSourceFocus = false
    private val horizontalStep = ViewConfiguration.get(context).scaledHorizontalScrollFactor

    init {
        isFocusableInTouchMode = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        // Immutable per source TABLE. Toggling this flag while already focused does not
        // rebuild the framework's cached highlight; wide state instead suppresses draw.
        defaultFocusHighlightEnabled = owner.policy.mode == TableScrollFocusMode.UaAuto
        setWillNotDraw(false)
    }

    internal fun syncOwner() {
        // Disabling a focused View calls clearFocus(), which may focus an unrelated root
        // descendant. Retain only this source focus until Tab/platform focus moves it.
        isFocusable = owner.canAcquireFocus || isFocused
        invalidate()
    }

    internal fun positioned(value: LayoutCoordinates) {
        coordinates = value.takeIf { it.isAttached }
        invalidate()
    }

    override fun requestFocus(direction: Int, previouslyFocusedRect: Rect?): Boolean =
        !clearingSourceFocus && owner.canAcquireFocus && super.requestFocus(direction, previouslyFocusedRect)

    override fun addFocusables(views: ArrayList<View>, direction: Int, focusableMode: Int) {
        if (!clearingSourceFocus && owner.canAcquireFocus) super.addFocusables(views, direction, focusableMode)
    }

    override fun clearFocus() {
        // An explicit native/AX clear may ask the root to assign new focus. It must not
        // immediately reacquire this same source target and report a fictitious clear.
        val previous = clearingSourceFocus
        clearingSourceFocus = true
        try { super.clearFocus() } finally { clearingSourceFocus = previous }
    }

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        owner.focusChanged(gainFocus)
        if (!gainFocus && !owner.canAcquireFocus) isFocusable = false
        invalidate()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        owner.keyDown(event, horizontalStep) || super.onKeyDown(keyCode, event)

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_SCROLL && owner.canScroll && insideAncestor(event.x, event.y)) {
            val axis = when {
                event.isFromSource(InputDevice.SOURCE_CLASS_POINTER) -> if ((event.metaState and KeyEvent.META_SHIFT_ON) != 0)
                    -event.getAxisValue(MotionEvent.AXIS_VSCROLL) else event.getAxisValue(MotionEvent.AXIS_HSCROLL)
                event.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER) -> event.getAxisValue(MotionEvent.AXIS_SCROLL)
                else -> 0f
            }
            if (owner.scrollBy(axis * horizontalStep)) return true
        }
        return super.onGenericMotionEvent(event)
    }

    private fun ancestorBounds(): RectF? {
        val source = owner.ancestorClip?.inScreen() ?: return null
        val at = coordinates?.takeIf { it.isAttached && isAttachedToWindow } ?: return RectF()
        if (source.isEmpty) return RectF()
        val points = listOf(Offset(source.left, source.top), Offset(source.right, source.top),
            Offset(source.right, source.bottom), Offset(source.left, source.bottom)).map(at::screenToLocal)
        if (points.any { !it.x.isFinite() || !it.y.isFinite() }) return RectF()
        return RectF(points.minOf { it.x }, points.minOf { it.y }, points.maxOf { it.x }, points.maxOf { it.y })
    }

    internal fun tableScreenToLocal(clip: NativeTextClip): NativeTextClip {
        val at = coordinates?.takeIf { it.isAttached && isAttachedToWindow }
            ?: return NativeTextClip.rectangle(RectF())
        val origin = at.screenToLocal(Offset.Zero)
        val horizontal = at.screenToLocal(Offset(1f, 0f))
        val vertical = at.screenToLocal(Offset(0f, 1f))
        val last = at.screenToLocal(Offset(1f, 1f))
        val values = floatArrayOf(horizontal.x - origin.x, vertical.x - origin.x, origin.x,
            horizontal.y - origin.y, vertical.y - origin.y, origin.y, 0f, 0f, 1f)
        if (values.any { !it.isFinite() } || !last.x.isFinite() || !last.y.isFinite() ||
            kotlin.math.abs(last.x - (horizontal.x + vertical.x - origin.x)) > .01f ||
            kotlin.math.abs(last.y - (horizontal.y + vertical.y - origin.y)) > .01f)
            return NativeTextClip.rectangle(RectF())
        return clip.transformed(Matrix().apply { setValues(values) })
    }

    private fun insideAncestor(x: Float, y: Float): Boolean =
        (ancestorBounds()?.contains(x, y) ?: true) &&
            (owner.ancestorClip?.preciseInView(this)?.contains(x, y) ?: true)

    override fun draw(canvas: Canvas) {
        if (!owner.paintsFocus) return
        val saved = canvas.save()
        try {
            ancestorBounds()?.let { canvas.clipRect(it) }
            owner.ancestorClip?.preciseInView(this)?.clip(canvas)
            // The platform highlight is drawn after onDraw, so the ancestor clip wraps
            // the entire View draw. The source content clip must not clip its outline.
            super.draw(canvas)
        } finally { canvas.restoreToCount(saved) }
    }
}

private data object NativeTableFocusPointerSharing : ModifierNodeElement<NativeTableFocusPointerSharingNode>() {
    override fun create() = NativeTableFocusPointerSharingNode()
    override fun update(node: NativeTableFocusPointerSharingNode) = Unit
    override fun InspectorInfo.inspectableProperties() { name = "nativeTableFocusPointerSharing" }
}

private class NativeTableFocusPointerSharingNode : Modifier.Node(), PointerInputModifierNode {
    override fun sharePointerInputWithSiblings() = true
    override fun onPointerEvent(pointerEvent: PointerEvent, pass: PointerEventPass, bounds: IntSize) = Unit
    override fun onCancelPointerInput() = Unit
}

@Composable
internal fun NativeTableScrollFocusOverlay(owner: NativeTableScrollFocusOwner, modifier: Modifier = Modifier) {
    // The sharing node belongs to the direct sibling wrapper, not the nested AndroidView.
    Box(modifier.then(NativeTableFocusPointerSharing)) {
        key(owner) {
            AndroidView(factory = { NativeTableScrollFocusView(it, owner).also(owner::attach) },
                modifier = Modifier.matchParentSize().onGloballyPositioned { coordinates ->
                    owner.positioned(coordinates)
                },
                onReset = null,
                onRelease = { owner.detach(it) },
                update = { it.syncOwner() })
        }
    }
}
