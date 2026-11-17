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
import android.view.InputDevice
import android.view.PointerIcon
import android.view.View
import android.view.VelocityTracker
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInWindow
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Native interaction owner for a single formatting context, hosted by AndroidView. */
internal class NativeFloatTextView(context: Context, private var scrollClip: NativeScrollClip? = null) : View(context) {
    private var geometryFactory: ((Int) -> FloatTextGeometry)? = null
    private var geometry: FloatTextGeometry? = null
    private var needsGeometry = true
    internal val currentMeasuredGeometry: FloatTextGeometry? get() = geometry.takeUnless { needsGeometry }
    internal var delegatedCellOwner: NativeDelegatedCellOwner? = null
        set(value) {
            if (field === value) return
            field?.clear(this)
            field = value
            delegatedAdmissionChanged()
        }
    internal var delegatedStateOwner: NativeDelegatedTableOwner? = null
        set(value) {
            if (field === value) return
            val previous = field
            field = value
            previous?.clearRootState(this)
            invalidate()
        }
    private var tableCoordinateOwner: Any? = null
    private var tableCoordinates: LayoutCoordinates? = null
    internal fun bindTableCoordinates(owner: Any) {
        if (tableCoordinateOwner !== owner) {
            tableCoordinateOwner = owner
            tableCoordinates = null
        }
    }
    internal fun positionTableCoordinates(owner: Any, coordinates: LayoutCoordinates) {
        if (tableCoordinateOwner === owner) {
            tableCoordinates = coordinates.takeIf { it.isAttached }
            publishCitationOwner()
        }
    }
    internal fun clearTableCoordinates(owner: Any) {
        if (tableCoordinateOwner === owner) {
            tableCoordinates = null
            tableCoordinateOwner = null
            publishCitationOwner()
        }
    }
    private fun liveTableCoordinates(): LayoutCoordinates? = tableCoordinates?.takeIf {
        isAttachedToWindow && it.isAttached && it.size.width == measuredWidth && it.size.height == measuredHeight
    }
    private fun originalOwnerAvailable(): Boolean = delegatedCellOwner?.permits(this) ?: true
    internal fun delegatedMeasurementPending() {
        invalidate()
        actionMode?.invalidateContentRect()
        sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    }
    internal fun delegatedAdmissionChanged() {
        val available = originalOwnerAvailable()
        if (!available) {
            cancelCapturedOwnerSequence()
            clearPendingLinkKey("delegated-owner-unavailable")
            actionMode?.finish()
        }
        publishCitationOwner()
        isFocusable = available
        isFocusableInTouchMode = available
        importantForAccessibility = if (available) IMPORTANT_FOR_ACCESSIBILITY_YES else IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        invalidate()
        sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    }
    private var citationNavigation: NativeCitationNavigation? = null
    internal fun updateCitationNavigation(next: NativeCitationNavigation?) {
        if (citationNavigation === next) return
        citationNavigation?.remove(this)
        citationNavigation = next
        publishCitationOwner()
    }
    private fun publishCitationOwner() {
        val registry = citationNavigation ?: return
        val current = geometry
        if (needsGeometry || current == null || !isAttachedToWindow || !originalOwnerAvailable() ||
            tableCoordinateOwner != null && liveTableCoordinates() == null) {
            registry.remove(this)
            return
        }
        // Publish outside measure and authenticate the exact measured owner again after placement.
        post {
            if (citationNavigation === registry && geometry === current && !needsGeometry &&
                isAttachedToWindow && originalOwnerAvailable() &&
                (tableCoordinateOwner == null || liveTableCoordinates() != null)) registry.publish(this, current)
        }
    }
    private var citationParentReveal: NativeCitationParentReveal? = null
    internal fun updateCitationParentReveal(next: NativeCitationParentReveal?) {
        if (citationParentReveal === next) return
        finishCitationReveal(false)
        citationParentReveal = next
    }
    private class CitationReveal(val request: NativeCitationRequest, val text: String,
        val node: FloatInteractionNode, val tableOwner: Any?, val clip: NativeScrollClip?,
        val current: () -> Boolean, val completed: (Boolean) -> Unit) {
        var parentCompleted = false
        var cancelParent: (() -> Unit)? = null
    }
    private var citationReveal: CitationReveal? = null
    private var citationRevealObserver: android.view.ViewTreeObserver? = null
    private val citationPreDraw = android.view.ViewTreeObserver.OnPreDrawListener {
        checkCitationReveal()
        true
    }
    private fun removeCitationObserver() {
        citationRevealObserver?.takeIf { it.isAlive }?.removeOnPreDrawListener(citationPreDraw)
        citationRevealObserver = null
    }
    internal fun cancelCitationReveal(request: NativeCitationRequest) {
        val pending = citationReveal ?: return
        if (pending.request !== request) return
        citationReveal = null
        pending.cancelParent?.invoke()
        removeCitationObserver()
        if (pendingViewportReveal?.node?.citationMarker == request.marker) pendingViewportReveal = null
    }
    private fun finishCitationReveal(success: Boolean) {
        val pending = citationReveal ?: return
        cancelCitationReveal(pending.request)
        if (pending.current()) pending.completed(success)
    }
    private fun failCitationReveal(node: FloatInteractionNode?) {
        if (node?.citationMarker != null && citationReveal?.request?.marker == node.citationMarker)
            finishCitationReveal(false)
    }
    private fun checkCitationReveal() {
        val pending = citationReveal ?: return
        if (!pending.current()) { cancelCitationReveal(pending.request); return }
        if (!isAttachedToWindow || !isEnabled || tableCoordinateOwner !== pending.tableOwner || scrollClip !== pending.clip) {
            finishCitationReveal(false); return
        }
        if (needsGeometry || isLayoutRequested) return
        val layout = geometry
        val node = layout?.nodes?.singleOrNull { it.citationMarker == pending.request.marker }
        if (layout == null || layout.text.toString() != pending.text || !sameInputNode(pending.node, node)) {
            finishCitationReveal(false); return
        }
        if (!hasFocus() || virtualKeyboardFocus != checkNotNull(node).id) { finishCitationReveal(false); return }
        // Native clipping and the Compose parent each have an actual asynchronous completion.
        if (pendingViewportReveal != null || !pending.parentCompleted) return
        if (!originalOwnerAvailable() || tableCoordinateOwner != null && liveTableCoordinates() == null) {
            finishCitationReveal(false); return
        }
        val info = nodeProvider.createAccessibilityNodeInfo(node.id) ?: run { finishCitationReveal(false); return }
        val visible = try {
            val screen = Rect()
            info.getBoundsInScreen(screen)
            info.isFocused && info.isVisibleToUser && !screen.isEmpty
        } finally { info.recycle() }
        finishCitationReveal(visible)
    }
    private fun revealCitationParent(bounds: RectF, node: FloatInteractionNode?): Boolean {
        val pending = citationReveal ?: return false
        if (node?.citationMarker != pending.request.marker) return false
        val parent = citationParentReveal ?: run { finishCitationReveal(false); return true }
        val local = RectF(bounds).apply { offset(paddingLeft.toFloat(), paddingTop.toFloat()) }
        val screen = tableBoundsToScreen(bounds)
        pending.cancelParent = parent.reveal(local, screen) { success ->
            if (citationReveal === pending && pending.current()) {
                if (!success) finishCitationReveal(false) else {
                    pending.parentCompleted = true
                    invalidate()
                }
            }
        }
        if (citationReveal !== pending) pending.cancelParent?.invoke()
        return true
    }
    internal fun revealCitation(expected: FloatTextGeometry, request: NativeCitationRequest,
        current: () -> Boolean, completed: (Boolean) -> Unit): Boolean {
        val marker = request.marker
        if (geometry !== expected || needsGeometry || !isEnabled || !isAttachedToWindow ||
            !originalOwnerAvailable() || tableCoordinateOwner != null && liveTableCoordinates() == null) return false
        val range = expected.citationMarkerRanges.singleOrNull { it.marker == marker } ?: return false
        val node = expected.nodes.singleOrNull { it.id == range.nodeId && it.start == range.start &&
            it.end == range.end && it.citationMarker == marker && it.onClick != null } ?: return false
        citationReveal?.request?.let(::cancelCitationReveal)
        citationReveal = CitationReveal(request, expected.text.toString(), node, tableCoordinateOwner,
            scrollClip, current, completed)
        request.revealOwner = this
        request.revealStarted = true
        citationRevealObserver = viewTreeObserver.also { it.addOnPreDrawListener(citationPreDraw) }
        // This retains the existing action/selection owner; completion waits for actual visibility.
        if (!nodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null)) finishCitationReveal(false)
        invalidate()
        return true
    }
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
    // Ordinary source-link focus underline follows actual input focus; only its outline uses modality.
    private var ordinaryLinkFocusVisible = false
    private var virtualKeyboardFocus = View.NO_ID
        set(value) { field = value; updateMissingLinkPaint() }
    private var hoveredNode = View.NO_ID
        set(value) { field = value; updateMissingLinkPaint() }
    private var pressedLinkNode = View.NO_ID
        set(value) { field = value; updateMissingLinkPaint() }
    private var pendingLinkKey: NativeLinkKeyPress? = null
        set(value) { field = value; updateMissingLinkPaint() }
    private var bindGeneration = 0L
    private var measuredGeneration = -1L
    private var lastLinkKeyTransition = "none"
    private fun clearPendingLinkKey(reason: String) {
        if (pendingLinkKey != null) lastLinkKeyTransition = reason
        pendingLinkKey = null
    }
    private fun updateMissingLinkPaint() {
        geometry?.nodes?.forEach { node -> node.missingLinkPaint?.let {
            it.hovered = hoveredNode == node.id
            it.active = pressedLinkNode == node.id || pendingLinkKey?.matches(node) == true
            it.focused = hasFocus() && virtualKeyboardFocus == node.id
        } }
    }
    private var linkDownX = 0f
    private var linkDownY = 0f
    private val linkTouchSlop = android.view.ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private data class FocusRegion(val offset: Int, val nodeId: Int = View.NO_ID, val start: Int = offset, val end: Int = offset)
    private var focusRegion: FocusRegion? = null
    private val nodeProvider = Nodes()
    internal val selectionStart: Int get() = min(anchor, extent)
    internal val selectionEnd: Int get() = max(anchor, extent)
    internal val selectionActive: Boolean get() = selecting
    internal fun linkKeyState(): String = "selection=$selectionStart..$selectionEnd; selecting=$selecting; " +
        "focus=${hasFocus()}/$virtualKeyboardFocus; key=${pendingLinkKey?.keyCode}; node=${pendingLinkKey?.nodeId}; " +
        "bind=$bindGeneration; measured=$measuredGeneration; dirty=$needsGeometry; transition=$lastLinkKeyTransition"
    internal val logicalText: CharSequence get() = geometry?.text ?: ""
    private val hasSelection: Boolean get() = selecting && anchor != extent
    private data class RevealLocation(val rect: RectF, val clip: RectF?, val precise: NativeTextClip? = null)
    private data class PendingViewportReveal(val text: String, val offset: Int,
        val ownerNodes: List<FloatInteractionNode>, val node: FloatInteractionNode? = null,
        var ready: Boolean = false, var clippedScope: NativeClippedAbsoluteCoordinateScope? = null)
    private var clippedRevealCancellation: (() -> Unit)? = null
    private var pendingViewportReveal: PendingViewportReveal? = null
        set(value) {
            if (field !== value) {
                val cancel = clippedRevealCancellation
                clippedRevealCancellation = null
                field = value
                cancel?.invoke()
            }
        }
    private fun clippedRevealLocation(layout: FloatTextGeometry, pending: PendingViewportReveal): NativeClippedAbsoluteSemanticLocation? =
        pending.node?.let { saved -> layout.nodes.firstOrNull { sameInputNode(saved, it) }?.clippedAbsoluteLocation }
            ?: pending.offset.takeIf { it < layout.text.length }?.let { layout.clippedAbsoluteSemanticLocation(it, it + 1) }

    internal fun updateScrollClip(next: NativeScrollClip?) {
        if (scrollClip === next) return
        // AndroidView retains this source owner when its ancestor scrollport changes.
        scrollClip = next
        cancelCapturedOwnerSequence()
        clearPendingLinkKey("scroll-clip-changed")
        hoveredNode = View.NO_ID
        pendingViewportReveal = null
        actionMode?.invalidateContentRect()
        invalidate()
        sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    }

    internal fun revealLogicalOffset(offset: Int): Boolean {
        if (!originalOwnerAvailable()) return false
        val current = geometry ?: return false
        if (offset !in 0..current.text.length) return false
        if (offset < current.text.length && current.clippedAbsoluteSemanticLocation(offset, offset + 1) != null) {
            beginViewportReveal(PendingViewportReveal(current.text.toString(), offset, current.nodes.toList()))
            return true
        }
        if (current.clipForOffset(offset) == null) {
            pendingViewportReveal = null
            val rect = Rect(); current.caretRect(offset).roundOut(rect)
            rect.offset(paddingLeft, paddingTop)
            requestRectangleOnScreen(rect, false)
            return true
        }
        beginViewportReveal(PendingViewportReveal(current.text.toString(), offset, current.nodes.toList()))
        return true
    }

    private fun revealLocation(layout: FloatTextGeometry, pending: PendingViewportReveal): RevealLocation? {
        if (layout.text.toString() != pending.text || pending.offset !in 0..layout.text.length ||
            layout.nodes.size != pending.ownerNodes.size ||
            pending.ownerNodes.zip(layout.nodes).any { (before, after) -> !sameInputNode(before, after) }) return null
        if (pending.node != null) {
            val node = layout.nodes.firstOrNull { sameInputNode(pending.node, it) } ?: return null
            val retained = node.clippedAbsoluteLocation
            return RevealLocation(RectF(nodeRevealBounds(node) ?: layout.caretRect(node.start)),
                (retained?.clipBounds ?: node.clipBounds.takeIf { retained == null })?.let(::RectF),
                if (retained == null) node.preciseClip else retained.preciseClip)
        }
        return RevealLocation(RectF(layout.caretRect(pending.offset)), layout.clipForOffset(pending.offset)?.let(::RectF),
            layout.preciseClipForOffset(pending.offset))
    }

    private fun beginViewportReveal(pending: PendingViewportReveal) {
        val layout = geometry ?: return
        pendingViewportReveal = pending
        pending.ready = false
        if (revealLocation(layout, pending) == null) { pendingViewportReveal = null; failCitationReveal(pending.node); return }
        val completed: () -> Unit = {
            if (pendingViewportReveal === pending) {
                pending.ready = true
                postOnAnimation { finishViewportReveal() }
            }
        }
        val clipped = clippedRevealLocation(layout, pending)
        pending.clippedScope = clipped?.coordinateScope
        if (clipped != null) {
            val projected = projectClippedAbsolute(clipped, clipResult = false)
            if (projected == null) { pendingViewportReveal = null; return }
            val cancel = projected.authority.reveal(projected.screen) { success ->
                if (pendingViewportReveal === pending) {
                    if (success) completed() else { pendingViewportReveal = null; failCitationReveal(pending.node) }
                }
            }
            if (pendingViewportReveal === pending && !pending.ready) clippedRevealCancellation = cancel
        } else if (pending.node != null) layout.revealNode(pending.node.id, completed)
        else layout.revealOffset(pending.offset, completed)
    }

    private fun finishViewportReveal() {
        val pending = pendingViewportReveal ?: return
        if (!pending.ready || needsGeometry || isLayoutRequested) return
        if (!originalOwnerAvailable()) { pendingViewportReveal = null; failCitationReveal(pending.node); return }
        val layout = geometry ?: return
        val current = revealLocation(layout, pending) ?: run { pendingViewportReveal = null; failCitationReveal(pending.node); return }
        val emptyOwner = pending.node?.let { saved ->
            layout.nodes.firstOrNull { it.id == saved.id }?.let(::emptyLinkBands)
        } != null
        val clippedOwner = clippedRevealLocation(layout, pending)
        if (pending.clippedScope !== clippedOwner?.coordinateScope) {
            pendingViewportReveal = null; failCitationReveal(pending.node); return
        }
        val visible = if (clippedOwner != null) clippedAbsoluteLocalBounds(clippedOwner)
        else if (emptyOwner) clippedEmptyBand(current.rect, current.clip, current.precise)
        else RectF(current.rect).apply {
            current.clip?.let { if (!intersect(it)) setEmpty() }
            current.precise?.let { set(it.bounds(this) ?: RectF()) }
        }
        if (visible == null || clippedOwner == null && !emptyOwner && (visible.isEmpty ||
            pending.node != null && layout.nodes.firstOrNull { it.id == pending.node.id }?.bounds?.none { !it.isEmpty } == true)) {
            pendingViewportReveal = null
            failCitationReveal(pending.node)
            return
        }
        pendingViewportReveal = null
        // The authenticated containing-block owner already revealed this location. Sending
        // it through the descendant View would scroll an intervening table a second time.
        if (clippedOwner != null) return
        if (revealCitationParent(visible, pending.node)) return
        val rectangle = Rect(); visible.roundOut(rectangle)
        rectangle.offset(paddingLeft, paddingTop)
        requestRectangleOnScreen(rectangle, false)
    }


    init {
        isFocusable = true
        isFocusableInTouchMode = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        // Focus cues below preserve authored ink; the framework default tints the whole view.
        defaultFocusHighlightEnabled = false
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
            bindGeneration++
            // Factories also change on reflow. Reconcile held input against the measured
            // source/action owners; a timer or event while geometry is dirty must refuse it.
            needsGeometry = true
            citationNavigation?.remove(this)
            requestLayout()
        }
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val desiredWidth = if (MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED)
            resources.displayMetrics.widthPixels else MeasureSpec.getSize(widthMeasureSpec)
        val width = max(0, desiredWidth - paddingLeft - paddingRight)
        if (needsGeometry || lastMeasuredWidth != width) {
            val previousGeometry = geometry
            val previous = previousGeometry?.text?.toString()
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
            measuredGeneration = bindGeneration
            if (previous != logicalText.toString()) {
                clearSelection()
                focusRegion = null
                virtualAccessibilityFocus = View.NO_ID
                virtualKeyboardFocus = View.NO_ID
                hoveredNode = View.NO_ID
                pressedLinkNode = View.NO_ID
                clearPendingLinkKey("text-changed")
            } else {
                // A status node can change IDs without changing copied text. A held ID
                // must still identify the same owner before it can receive focus or a key.
                fun retainedNode(id: Int): Boolean = id == View.NO_ID ||
                    previousGeometry?.nodes?.find { it.id == id }?.let { before ->
                        sameInputNode(before, geometry?.nodes?.find { it.id == id })
                    } == true
                if (!retainedNode(virtualKeyboardFocus)) virtualKeyboardFocus = View.NO_ID
                if (!retainedNode(virtualAccessibilityFocus)) virtualAccessibilityFocus = View.NO_ID
                if (!retainedNode(hoveredNode)) hoveredNode = View.NO_ID
                if (!retainedNode(pressedLinkNode)) pressedLinkNode = View.NO_ID
                if (focusRegion?.let { !retainedNode(it.nodeId) } == true) focusRegion = null
            }
            require(geometry?.nodes.orEmpty().all { it.id >= 0 && it.start in 0..logicalText.length && it.end in it.start..logicalText.length })
            require(geometry?.nodes.orEmpty().map { it.id }.distinct().size == geometry?.nodes.orEmpty().size)
            if (hasCapturedOwnerSequence() && !capturedOwnerIsCurrent(checkDelegated = false)) cancelCapturedOwnerSequence()
            pendingLinkKey?.let { pending ->
                if (geometry?.nodes?.any(pending::matches) != true) clearPendingLinkKey("node-or-owner-changed")
                else lastLinkKeyTransition = "measured-action-retained"
            }
            updateMissingLinkPaint()
            sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
            actionMode?.invalidateContentRect()
        }
        val desiredHeight = (geometry?.height ?: 0) + paddingTop + paddingBottom
        setMeasuredDimension(resolveSize(desiredWidth, widthMeasureSpec), resolveSize(desiredHeight, heightMeasureSpec))
        if (pendingViewportReveal?.ready == true) postOnAnimation { finishViewportReveal() }
        publishCitationOwner()
    }

    override fun invalidate() {
        super.invalidate()
        delegatedCellOwner?.statePaintChanged()
        delegatedStateOwner?.statePaintChanged()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!originalOwnerAvailable()) return
        val layout = geometry ?: return
        val save = canvas.save()
        scrollClip?.preciseInView(this)?.clip(canvas)
        canvas.translate(paddingLeft.toFloat(), paddingTop.toFloat())
        layout.paint(canvas)
        if (delegatedCellOwner == null && delegatedStateOwner == null) {
            paintSelectionState(canvas, layout)
            paintFocusState(canvas, layout)
        }
        canvas.restoreToCount(save)
    }

    /** The containing native phase invokes this same owner's state after every cell's
     * media. Keys, selection, actions and accessibility remain on this original View. */
    internal fun paintDelegatedState(canvas: Canvas, focus: Boolean) {
        if (!originalOwnerAvailable()) return
        val layout = geometry ?: return
        val save = canvas.save()
        scrollClip?.preciseInView(this)?.clip(canvas)
        canvas.translate(paddingLeft.toFloat(), paddingTop.toFloat())
        try {
            if (focus) paintFocusState(canvas, layout) else paintSelectionState(canvas, layout)
        } finally { canvas.restoreToCount(save) }
    }

    private fun paintSelectionState(canvas: Canvas, layout: FloatTextGeometry) {
        if (hasSelection) {
            if (layout.hasPreciseClips) layout.paintSelection(canvas, selectionStart, selectionEnd, highlight)
            else layout.rectsForRange(selectionStart, selectionEnd).forEach { canvas.drawRect(it, highlight) }
            drawHandle(canvas, anchor)
            drawHandle(canvas, extent)
        } else if (selecting && hasFocus()) {
            withSelectionClip(canvas, layout.clipForOffset(extent), layout.preciseClipForOffset(extent)) {
                val caret = layout.caretRect(extent)
                canvas.drawRect(caret.left, caret.top, caret.left + max(1f, density), caret.bottom, handlePaint)
            }
        }
    }

    private fun paintFocusState(canvas: Canvas, layout: FloatTextGeometry) {
        layout.nodes.find { it.id == virtualKeyboardFocus }?.let { node ->
            if ((node.sourceFocusVisible || node.missingLinkPaint?.sourceSpanPaint == true) &&
                !ordinaryLinkFocusVisible) return@let
            withSelectionClip(canvas, node.clipBounds, node.preciseClip) {
            val authored = node.focusPaint
            if (authored != null) {
                paintNativeFocus(canvas, authored)
                return@withSelectionClip
            }
            val paint = if (node.missingLinkPaint == null) handlePaint else Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xff3366cc.toInt() }
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = if (node.missingLinkPaint == null) density else 2f * density
            node.bounds.forEach {
                if (node.missingLinkPaint == null) canvas.drawRect(it, paint)
                else canvas.drawRoundRect(RectF(it).apply { inset(-density, -density) }, 2f * density, 2f * density, paint)
            }
            paint.style = Paint.Style.FILL
            }
        }
        if (hasFocus() && !selecting && layout.nodes.none { it.id == virtualKeyboardFocus }) {
            // Host focus can precede a virtual node or caret (for example, Tab into this view).
            val bounds = layout.focusBounds
            val stroke = min(2f * density, min(bounds.width(), bounds.height()))
            if (stroke > 0f) {
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = handlePaint.color
                    style = Paint.Style.STROKE
                    strokeWidth = stroke
                }
                val inset = stroke / 2f
                canvas.drawRect(bounds.left + inset, bounds.top + inset,
                    bounds.right - inset, bounds.bottom - inset, paint)
            }
        }
    }

    private inline fun withSelectionClip(canvas: Canvas, clip: RectF?, precise: NativeTextClip? = null, paint: () -> Unit) {
        if (clip?.isEmpty == true) return
        val saved = canvas.save()
        try { if (clip != null) canvas.clipRect(clip); precise?.clip(canvas); paint() }
        finally { canvas.restoreToCount(saved) }
    }

    private fun drawHandle(canvas: Canvas, offset: Int) {
        withSelectionClip(canvas, geometry!!.clipForOffset(offset), geometry!!.preciseClipForOffset(offset)) {
            val rect = geometry!!.caretRect(offset)
            val center = handleCenter(offset)
            canvas.drawRect(rect.left, min(rect.bottom, center.second), rect.left + density, max(rect.bottom, center.second), handlePaint)
            canvas.drawCircle(center.first, center.second, handleRadius(), handlePaint)
        }
    }

    private fun handleRadius() = min(6 * density, min(geometry!!.width, geometry!!.height) / 2f)

    private fun handleCenter(offset: Int): Pair<Float, Float> {
        return nativeSelectionHandleCenter(geometry!!, offset, density)
    }

    private fun handleAt(x: Float, y: Float): Int {
        if (!hasSelection) return 0
        fun distance(offset: Int): Float {
            if (geometry!!.clipForOffset(offset)?.contains(x, y) == false ||
                geometry!!.preciseClipForOffset(offset)?.contains(x, y) == false ||
                !pointInScrollport(x + paddingLeft, y + paddingTop)) return Float.POSITIVE_INFINITY
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
            if (!hasCapturedOwnerSequence() || rejectedOwnerSequence || !capturedOwnerIsCurrent()) return true
            if (draggedHandle != 0) return true
            if (!pointInScrollport(event.x, event.y)) return false
            val x = event.x - paddingLeft
            val y = event.y - paddingTop
            val node = hitNode(x, y)
            if (!capturedHitIsCurrent(node)) return true
            // Acquiring focus may reposition this AndroidView in its scrolling ancestors.
            // Resolve the completed touch before focus can change its coordinate system.
            if (node?.onClick != null && !hasSelection) {
                // Like a Compose text link, activation preserves the current input focus.
                // Caret placement and selection below still acquire their own focus.
                node.onClick.invoke()
                sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_CLICKED)
            } else {
                val at = geometry?.offsetForPosition(x, y) ?: 0
                focusRegion = FocusRegion(at)
                requestFocus()
                clearSelection()
                setSelection(at, at, showMenu = false)
                performClick()
            }
            return true
        }
        override fun onLongPress(event: MotionEvent) {
            if (!hasCapturedOwnerSequence() || rejectedOwnerSequence || !capturedOwnerIsCurrent()) {
                cancelCapturedOwnerSequence()
                return
            }
            if (!pointInScrollport(event.x, event.y)) return
            pressedLinkNode = View.NO_ID
            invalidate()
            val layout = geometry ?: return
            val node = hitNode(event.x - paddingLeft, event.y - paddingTop)
            if (!capturedHitIsCurrent(node)) return
            if (node?.onLongClick != null) {
                focusRegion = nodeFocusRegion(node, event.x - paddingLeft, event.y - paddingTop)
                requestFocus()
                node.onLongClick.invoke()
                sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_LONG_CLICKED)
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                return
            }
            if (logicalText.isEmpty()) return
            val at = layout.offsetForPosition(event.x - paddingLeft, event.y - paddingTop).coerceIn(0, logicalText.length - 1)
            val range = wordAt(at)
            focusRegion = FocusRegion(range.second)
            requestFocus()
            setSelection(range.first, range.second, showMenu = true)
            draggedHandle = 2
            dragOffsetX = 0f
            dragOffsetY = 0f
            parent?.requestDisallowInterceptTouchEvent(true)
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }
    })

    override fun performClick(): Boolean { super.performClick(); return true }

    private data class PointerOwner(val text: String, val nodes: List<FloatInteractionNode>, val hit: FloatInteractionNode?)
    private var capturedPointerOwner: PointerOwner? = null
    private var rejectedOwnerSequence = false
    private var localScrollTarget: NativeHorizontalScrollTarget? = null
    private var localScrollDragging = false
    private var localScrollLastX = 0f
    private var localScrollVelocity: VelocityTracker? = null

    private fun releaseLocalScroll(cancel: Boolean) {
        if (cancel) localScrollTarget?.cancel()
        localScrollTarget = null
        localScrollDragging = false
        localScrollVelocity?.recycle()
        localScrollVelocity = null
    }

    private fun routeLocalScroll(event: MotionEvent): Boolean {
        val target = localScrollTarget ?: return false
        localScrollVelocity?.addMovement(event)
        val index = event.findPointerIndex(pointerId)
        if (event.actionMasked == MotionEvent.ACTION_MOVE && index >= 0 && draggedHandle == 0) {
            val physicalX = event.getX(index)
            val dx = physicalX - linkDownX
            val dy = event.getY(index) - linkDownY
            if (!localScrollDragging && kotlin.math.abs(dy) > linkTouchSlop && kotlin.math.abs(dy) >= kotlin.math.abs(dx)) {
                releaseLocalScroll(cancel = true)
                return false
            }
            if (!localScrollDragging && kotlin.math.abs(dx) > linkTouchSlop && kotlin.math.abs(dx) > kotlin.math.abs(dy)) {
                localScrollDragging = true
                localScrollLastX = linkDownX + kotlin.math.sign(dx) * linkTouchSlop
                pressedLinkNode = View.NO_ID
                clearPendingLinkKey("table-scroll")
                pendingViewportReveal = null
                val cancel = MotionEvent.obtain(event)
                cancel.action = MotionEvent.ACTION_CANCEL
                gestures.onTouchEvent(cancel)
                cancel.recycle()
                parent?.requestDisallowInterceptTouchEvent(true)
            }
            if (localScrollDragging) {
                if (!needsGeometry) target.scrollBy(localScrollLastX - physicalX)
                localScrollLastX = physicalX
                invalidate()
                return true
            }
        }
        val finished = event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL ||
            event.actionMasked == MotionEvent.ACTION_POINTER_UP && event.getPointerId(event.actionIndex) == pointerId
        if (finished) {
            val consumed = localScrollDragging
            if (consumed && event.actionMasked == MotionEvent.ACTION_UP && !needsGeometry) {
                localScrollVelocity?.computeCurrentVelocity(1000)
                target.fling(-(localScrollVelocity?.getXVelocity(pointerId) ?: 0f))
            }
            releaseLocalScroll(cancel = event.actionMasked != MotionEvent.ACTION_UP)
            if (consumed) {
                capturedPointerOwner = null
                rejectedOwnerSequence = false
                pointerId = MotionEvent.INVALID_POINTER_ID
                pressedLinkNode = View.NO_ID
                parent?.requestDisallowInterceptTouchEvent(false)
                invalidate()
            }
            return consumed
        }
        return localScrollDragging
    }

    private fun sameInputNode(before: FloatInteractionNode?, after: FloatInteractionNode?): Boolean {
        if (before == null || after == null) return before == null && after == null
        if (before.id != after.id || before.kind != after.kind || before.start != after.start || before.end != after.end ||
            before.label?.toString() != after.label?.toString() || before.onLongClick !== after.onLongClick ||
            before.customActions != after.customActions || before.citationMarker != after.citationMarker ||
            before.clippedAbsoluteLocation?.coordinateScope !== after.clippedAbsoluteLocation?.coordinateScope) return false
        val identity = before.missingLinkPaint?.actionIdentity
        val nextIdentity = after.missingLinkPaint?.actionIdentity
        return if (identity != null || nextIdentity != null)
            identity == nextIdentity && (before.onClick == null) == (after.onClick == null)
        else before.onClick === after.onClick
    }

    private fun hasCapturedOwnerSequence(): Boolean = capturedPointerOwner != null
    private fun capturedOwnerIsCurrent(checkDelegated: Boolean = true): Boolean {
        if (!isEnabled || checkDelegated && !originalOwnerAvailable()) return false
        val captured = capturedPointerOwner ?: return false
        val current = geometry ?: return false
        if (needsGeometry || captured.text != current.text.toString()) return false
        return if (captured.hit != null) sameInputNode(captured.hit, current.nodes.find { it.id == captured.hit.id })
        else captured.nodes.size == current.nodes.size && captured.nodes.zip(current.nodes).all { (a, b) -> sameInputNode(a, b) }
    }
    private fun capturedHitIsCurrent(node: FloatInteractionNode?): Boolean =
        capturedPointerOwner?.let { sameInputNode(it.hit, node) } == true

    private fun cancelCapturedOwnerSequence() {
        releaseLocalScroll(cancel = true)
        if (hasCapturedOwnerSequence()) rejectedOwnerSequence = true
        val now = android.os.SystemClock.uptimeMillis()
        val cancel = MotionEvent.obtain(now, now, MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
        gestures.onTouchEvent(cancel)
        cancel.recycle()
        draggedHandle = 0
        pressedLinkNode = View.NO_ID
        pointerId = MotionEvent.INVALID_POINTER_ID
        parent?.requestDisallowInterceptTouchEvent(false)
        invalidate()
    }

    override fun onCancelPendingInputEvents() {
        super.onCancelPendingInputEvents()
        // View cancels its own callbacks; this owner also schedules a GestureDetector.
        cancelCapturedOwnerSequence()
        clearPendingLinkKey("cancel-pending-input")
        invalidate()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled || !originalOwnerAvailable()) {
            cancelCapturedOwnerSequence()
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                capturedPointerOwner = null
                rejectedOwnerSequence = false
            }
            return false
        }
        if (event.actionMasked != MotionEvent.ACTION_DOWN && localScrollDragging && needsGeometry)
            return routeLocalScroll(event)
        if (event.actionMasked != MotionEvent.ACTION_DOWN && hasCapturedOwnerSequence()) {
            rejectedOwnerSequence = rejectedOwnerSequence || !capturedOwnerIsCurrent()
            if (rejectedOwnerSequence) {
                releaseLocalScroll(cancel = true)
                val cancel = MotionEvent.obtain(event)
                cancel.action = MotionEvent.ACTION_CANCEL
                gestures.onTouchEvent(cancel)
                cancel.recycle()
                draggedHandle = 0
                pressedLinkNode = View.NO_ID
                pointerId = MotionEvent.INVALID_POINTER_ID
                parent?.requestDisallowInterceptTouchEvent(false)
                invalidate()
                if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                    capturedPointerOwner = null
                    rejectedOwnerSequence = false
                }
                return true
            }
        }
        if (geometry == null) return false
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            capturedPointerOwner = null
            rejectedOwnerSequence = false
            if (needsGeometry) return false
            if (!pointInScrollport(event.x, event.y)) return false
            val x = event.x - paddingLeft
            val y = event.y - paddingTop
            if (!geometry!!.containsInput(x, y) && handleAt(x, y) == 0) return false
            ordinaryLinkFocusVisible = false
            // Include ordinary owners: an incoming replacement may acquire a fixed palette.
            // Bounds and paint are deliberately excluded so identical owners survive reflow.
            capturedPointerOwner = PointerOwner(logicalText.toString(), geometry!!.nodes.toList(), hitNode(x, y))
            linkDownX = event.x; linkDownY = event.y
            pressedLinkNode = if (hasSelection) View.NO_ID else hitNode(event.x - paddingLeft, event.y - paddingTop)
                ?.takeIf { it.missingLinkPaint != null && it.onClick != null }?.id ?: View.NO_ID
            invalidate()
            pointerId = event.getPointerId(0)
            releaseLocalScroll(cancel = true)
            localScrollTarget = geometry!!.horizontalScrollTargetAt(x, y)
            localScrollTarget?.let {
                it.cancel()
                localScrollLastX = event.x
                localScrollVelocity = VelocityTracker.obtain()
            }
            draggedHandle = handleAt(event.x - paddingLeft, event.y - paddingTop)
            if (draggedHandle != 0) {
                val caret = geometry!!.caretRect(if (draggedHandle == 1) anchor else extent)
                dragOffsetX = event.x - paddingLeft - caret.left
                dragOffsetY = event.y - paddingTop - caret.centerY()
                focusRegion = FocusRegion(if (draggedHandle == 1) anchor else extent)
                requestFocus()
                parent?.requestDisallowInterceptTouchEvent(true)
            }
        }
        if (event.actionMasked == MotionEvent.ACTION_MOVE && pressedLinkNode != View.NO_ID &&
            (kotlin.math.abs(event.x - linkDownX) > linkTouchSlop || kotlin.math.abs(event.y - linkDownY) > linkTouchSlop ||
                hitNode(event.x - paddingLeft, event.y - paddingTop)?.id != pressedLinkNode)) {
            pressedLinkNode = View.NO_ID
            invalidate()
        }
        if (routeLocalScroll(event)) return true
        if (draggedHandle == 0) gestures.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_MOVE && draggedHandle != 0) {
            val index = event.findPointerIndex(pointerId)
            if (index >= 0) {
                val x = event.getX(index) - paddingLeft - dragOffsetX
                val y = event.getY(index) - paddingTop - dragOffsetY
                val at = geometry!!.offsetForPosition(x, y)
                if (draggedHandle == 1) setSelection(at, extent, false) else setSelection(anchor, at, false)
                if (geometry!!.clipForOffset(at) == null) {
                    pendingViewportReveal = null
                    val visible = Rect()
                    geometry!!.caretRect(at).roundOut(visible)
                    visible.offset(paddingLeft, paddingTop)
                    visible.inset(0, -(32 * density).roundToInt())
                    requestRectangleOnScreen(visible, false)
                } else revealLogicalOffset(at)
            }
        }
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL ||
            (event.actionMasked == MotionEvent.ACTION_POINTER_UP && event.getPointerId(event.actionIndex) == pointerId)) {
            if (draggedHandle != 0 && hasSelection) showSelectionMenu()
            draggedHandle = 0
            pressedLinkNode = View.NO_ID
            invalidate()
            pointerId = MotionEvent.INVALID_POINTER_ID
            parent?.requestDisallowInterceptTouchEvent(false)
            // Cancel pending long-press callbacks even when handles bypass the detector.
            val cancel = MotionEvent.obtain(event)
            cancel.action = MotionEvent.ACTION_CANCEL
            gestures.onTouchEvent(cancel)
            cancel.recycle()
            capturedPointerOwner = null
            rejectedOwnerSequence = false
        }
        return true
    }

    override fun onResolvePointerIcon(event: MotionEvent, pointerIndex: Int): PointerIcon? {
        if (pointerIndex in 0 until event.pointerCount && originalOwnerAvailable()) {
            val tool = event.getToolType(pointerIndex)
            val pointer = event.isFromSource(InputDevice.SOURCE_MOUSE) ||
                tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER
            val x = event.getX(pointerIndex); val y = event.getY(pointerIndex)
            if (pointer && pointInScrollport(x, y) &&
                currentMeasuredGeometry?.cursorAt(x - paddingLeft, y - paddingTop) == InlineCursor.Help)
                return PointerIcon.getSystemIcon(context, PointerIcon.TYPE_HELP)
        }
        return super.onResolvePointerIcon(event, pointerIndex)
    }

    private fun pointInScrollport(x: Float, y: Float): Boolean =
        (scrollClip?.inView(this)?.contains(x, y) ?: true) &&
            (scrollClip?.preciseInView(this)?.contains(x, y) ?: true)

    private fun hitNode(x: Float, y: Float): FloatInteractionNode? =
        if (pointInScrollport(x + paddingLeft, y + paddingTop)) geometry?.interactionNodeAt(x, y) else null

    private fun nodeFocusRegion(node: FloatInteractionNode, x: Float? = null, y: Float? = null): FocusRegion {
        val offset = if (x == null || y == null) node.start else {
            // Character rectangles identify the touched fragment even beside a floated caption.
            geometry?.characterRects(node.start, node.end - node.start)?.withIndex()
                ?.filter { it.value?.isEmpty == false }?.minByOrNull { (_, rect) ->
                    val bounds = requireNotNull(rect)
                    val dx = max(0f, max(bounds.left - x, x - bounds.right))
                    val dy = max(0f, max(bounds.top - y, y - bounds.bottom))
                    dx * dx + dy * dy
                }?.let { node.start + it.index } ?: node.start
        }
        return FocusRegion(offset, node.id, node.start, node.end)
    }

    override fun getFocusedRect(outRect: Rect) {
        val layout = geometry
        val target = focusRegion
        if (layout == null || target == null || target.offset !in 0..layout.text.length) {
            super.getFocusedRect(outRect)
            return
        }
        val node = layout.nodes.firstOrNull {
            it.id == target.nodeId && it.start == target.start && it.end == target.end
        }
        node?.clippedAbsoluteLocation?.let { location ->
            val rectangle = clippedAbsoluteLocalBounds(location)
            if (rectangle == null) outRect.setEmpty() else {
                rectangle.roundOut(outRect)
                outRect.offset(paddingLeft, paddingTop)
            }
            return
        }
        val character = if (node != null && target.offset < node.end)
            layout.characterRects(target.offset, 1).firstOrNull() else null
        val fragment = node?.bounds?.firstOrNull { character != null && RectF.intersects(it, character) }
            ?: node?.let(::nodeRevealBounds)
        // Focus parents consume this on later passes too; resolve against the current geometry.
        val rectangle = RectF(fragment ?: layout.caretRect(target.offset))
        // This is an ancestor reveal target, not a currently visible AX rectangle.
        if (node != null && emptyLinkBands(node) != null)
            rectangle.set(clippedEmptyBand(rectangle, node.clipBounds, node.preciseClip) ?: RectF())
        else {
            (node?.clipBounds ?: layout.clipForOffset(target.offset))?.let { if (!rectangle.intersect(it)) rectangle.setEmpty() }
            (node?.preciseClip ?: layout.preciseClipForOffset(target.offset))?.let { rectangle.set(it.bounds(rectangle) ?: RectF()) }
        }
        rectangle.roundOut(outRect)
        outRect.offset(paddingLeft, paddingTop)
    }

    internal fun setSelection(start: Int, end: Int, showMenu: Boolean = false) {
        if (!originalOwnerAvailable()) return
        require(start in 0..logicalText.length && end in 0..logicalText.length)
        anchor = start
        extent = end
        selecting = true
        focusRegion = FocusRegion(end)
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
        pendingViewportReveal = null
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
        if (!originalOwnerAvailable()) return false
        val text = selectedTextForCopy() ?: return false
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText(null, text))
        return true
    }

    private fun showSelectionMenu() {
        if (!originalOwnerAvailable()) return
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

    /** Reveal the first fragment or declaring band without changing selection or invoking its action. */
    private fun revealVirtualNode(node: FloatInteractionNode) {
        if (node.clippedAbsoluteLocation != null) {
            val layout = geometry ?: return
            beginViewportReveal(PendingViewportReveal(layout.text.toString(), node.start, layout.nodes.toList(), node))
            return
        }
        if (node.clipBounds == null) {
            pendingViewportReveal = null
            val bounds = nodeRevealBounds(node) ?: run { failCitationReveal(node); return }
            if (revealCitationParent(bounds, node)) return
            val visible = Rect()
            bounds.roundOut(visible)
            visible.offset(paddingLeft, paddingTop)
            requestRectangleOnScreen(visible, false)
            return
        }
        val layout = geometry ?: return
        beginViewportReveal(PendingViewportReveal(layout.text.toString(), node.start, layout.nodes.toList(), node))
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (!isEnabled) { clearPendingLinkKey("disabled"); return false }
        if (!originalOwnerAvailable()) { clearPendingLinkKey("delegated-owner-unavailable"); return false }
        if (needsGeometry) {
            clearPendingLinkKey("keydown-before-measure")
            return false
        }
        val layout = geometry ?: return super.onKeyDown(keyCode, event)
        if (!ordinaryLinkFocusVisible) { ordinaryLinkFocusVisible = true; invalidate() }
        if (keyCode != KeyEvent.KEYCODE_ENTER && keyCode != KeyEvent.KEYCODE_DPAD_CENTER && pendingLinkKey != null) {
            clearPendingLinkKey("other-key"); invalidate()
        }
        if (event.isCtrlPressed && keyCode == KeyEvent.KEYCODE_A) { setSelection(0, logicalText.length, true); return true }
        if (event.isCtrlPressed && keyCode == KeyEvent.KEYCODE_C) return copySelection()
        if (keyCode == KeyEvent.KEYCODE_ESCAPE && selecting) { clearSelection(); return true }
        if (keyCode == KeyEvent.KEYCODE_TAB) {
            val nodes = layout.nodes.filter { it.onClick != null || it.onLongClick != null }
            val current = nodes.indexOfFirst { it.id == virtualKeyboardFocus }
            val next = if (current < 0 && event.isShiftPressed) nodes.lastIndex else current + if (event.isShiftPressed) -1 else 1
            if (next !in nodes.indices) { virtualKeyboardFocus = View.NO_ID; invalidate(); return super.onKeyDown(keyCode, event) }
            clearPendingLinkKey("focus-moved")
            virtualKeyboardFocus = nodes[next].id
            focusRegion = nodeFocusRegion(nodes[next])
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
            if (focused?.onClick != null) {
                if (focused.missingLinkPaint != null) {
                    if (event.repeatCount == 0) {
                        pendingLinkKey = NativeLinkKeyPress(focused.id, keyCode, focused.missingLinkPaint.actionIdentity, focused.onClick)
                        lastLinkKeyTransition = "keydown"
                        invalidate()
                    }
                }
                else { focused.onClick.invoke(); sendNodeEvent(focused.id, AccessibilityEvent.TYPE_VIEW_CLICKED) }
                return true
            }
        }
        val caret = layout.caretRect(extent)
        val next = when (keyCode) {
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                val forward = keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                if (event.isCtrlPressed) boundary(extent, forward, true) else layout.visualOffset(extent, if (forward) 1 else -1)
            }
            KeyEvent.KEYCODE_DPAD_UP -> layout.offsetForPosition(caret.left, caret.top - max(1f, caret.height() / 2))
            KeyEvent.KEYCODE_DPAD_DOWN -> layout.offsetForPosition(caret.left, caret.bottom + max(1f, caret.height() / 2))
            KeyEvent.KEYCODE_MOVE_HOME -> if (event.isCtrlPressed) 0 else
                layout.visualLineRanges(extent).firstOrNull()?.first ?: extent
            KeyEvent.KEYCODE_MOVE_END -> if (event.isCtrlPressed) logicalText.length else
                layout.visualLineEnd(extent)
            else -> return super.onKeyDown(keyCode, event)
        }.coerceIn(0, logicalText.length)
        virtualKeyboardFocus = View.NO_ID
        setSelection(if (event.isShiftPressed) anchor else next, next)
        if (layout.clipForOffset(next) == null) {
            pendingViewportReveal = null
            val visible = Rect()
            layout.caretRect(next).roundOut(visible)
            visible.offset(paddingLeft, paddingTop)
            requestRectangleOnScreen(visible)
        } else revealLogicalOffset(next)
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (!isEnabled) { clearPendingLinkKey("disabled"); return false }
        if (!originalOwnerAvailable()) { clearPendingLinkKey("delegated-owner-unavailable"); return false }
        val pending = pendingLinkKey
        if (pending != null && keyCode == pending.keyCode) {
            clearPendingLinkKey(if (event.isCanceled) "cancelled-keyup" else if (needsGeometry) "keyup-before-measure" else "keyup")
            invalidate()
            if (!event.isCanceled && !needsGeometry && hasFocus() && virtualKeyboardFocus == pending.nodeId) {
                geometry?.nodes?.find(pending::matches)?.let {
                    it.onClick?.invoke()
                    sendNodeEvent(it.id, AccessibilityEvent.TYPE_VIEW_CLICKED)
                }
            }
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        publishCitationOwner()
    }

    override fun onDetachedFromWindow() {
        pendingViewportReveal = null
        finishCitationReveal(false)
        citationNavigation?.remove(this)
        tableCoordinates = null
        delegatedCellOwner?.clear(this)
        delegatedStateOwner?.clearRootState(this)
        cancelCapturedOwnerSequence()
        pressedLinkNode = View.NO_ID
        clearPendingLinkKey("detached")
        hoveredNode = View.NO_ID
        actionMode?.finish()
        super.onDetachedFromWindow()
    }

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        if (!gainFocus) {
            finishCitationReveal(false)
            ordinaryLinkFocusVisible = false
            clearPendingLinkKey("focus-lost")
            virtualKeyboardFocus = View.NO_ID
            focusRegion = null
        }
        updateMissingLinkPaint()
        invalidate()
    }

    override fun getAccessibilityNodeProvider(): AccessibilityNodeProvider = nodeProvider

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        if (tableCoordinateOwner != null) {
            val visible = tableVisibleScreenBounds() ?: RectF()
            val screen = Rect().also { visible.roundOut(it) }
            info.setBoundsInScreen(screen)
            info.isVisibleToUser = isShown && !screen.isEmpty
            if (liveTableCoordinates() == null) { info.setBoundsInParent(Rect()); return }
        }
        if (!originalOwnerAvailable()) { info.isVisibleToUser = false; return }
        includeClippedAbsoluteHostBounds(info)
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
        if (tableCoordinateOwner != null && liveTableCoordinates() == null) return false
        if (!originalOwnerAvailable()) return false
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
                if (geometry?.clipForOffset(end) != null) revealLogicalOffset(end)
                else pendingViewportReveal = null
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
            AccessibilityNodeInfo.MOVEMENT_GRANULARITY_PARAGRAPH -> layout.paragraphBoundary(start, forward)
            AccessibilityNodeInfo.MOVEMENT_GRANULARITY_LINE -> {
                val fragment = layout.visualLineFragment(if (forward) start else max(0, start - 1))
                    ?: return false
                if (forward) fragment.second else fragment.first
            }
            else -> return false
        }
        if (next == start) return false
        val extend = arguments?.getBoolean(AccessibilityNodeInfo.ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN) == true
        setSelection(if (extend && selecting) anchor else if (extend) start else next, next)
        if (layout.clipForOffset(next) != null) revealLogicalOffset(next)
        else pendingViewportReveal = null
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
        if (!originalOwnerAvailable()) return false
        val manager = context.getSystemService(AccessibilityManager::class.java)
        val explore = manager.isEnabled && manager.isTouchExplorationEnabled
        val next = if (event.actionMasked == MotionEvent.ACTION_HOVER_EXIT) View.NO_ID
            else hitNode(event.x - paddingLeft, event.y - paddingTop)?.id ?: View.NO_ID
        if (next != hoveredNode) {
            if (explore && next != View.NO_ID) sendNodeEvent(next, AccessibilityEvent.TYPE_VIEW_HOVER_ENTER)
            if (explore && hoveredNode != View.NO_ID) sendNodeEvent(hoveredNode, AccessibilityEvent.TYPE_VIEW_HOVER_EXIT)
            hoveredNode = next
            invalidate()
        }
        if (event.actionMasked != MotionEvent.ACTION_HOVER_EXIT &&
            geometry?.containsInput(event.x - paddingLeft, event.y - paddingTop) == false) return false
        return explore && next != View.NO_ID || super.dispatchHoverEvent(event)
    }

    private fun sendNodeEvent(id: Int, type: Int) {
        val node = geometry?.nodes?.find { it.id == id } ?: return
        val event = AccessibilityEvent.obtain(type)
        event.setSource(this, id)
        event.packageName = context.packageName
        event.className = when (node.kind) {
                    FloatInteractionKind.IMAGE -> "android.widget.ImageView"
                    FloatInteractionKind.CONTROL -> "android.widget.Button"
                    FloatInteractionKind.SEPARATOR -> "android.view.View"
                    else -> "android.widget.TextView"
                }
        if (node.label != null) event.contentDescription = node.label
        parent?.requestSendAccessibilityEvent(this, event)
    }

    private inner class Nodes : AccessibilityNodeProvider() {
        override fun createAccessibilityNodeInfo(virtualViewId: Int): AccessibilityNodeInfo? {
            if (tableCoordinateOwner != null && liveTableCoordinates() == null) return null
            if (!originalOwnerAvailable()) return null
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
                    FloatInteractionKind.SEPARATOR -> "android.view.View"
                    else -> "android.widget.TextView"
                }
                AccessibilityNodeInfoCompat.wrap(this).isHeading = node.kind == FloatInteractionKind.HEADING
                if (node.kind == FloatInteractionKind.SEPARATOR)
                    AccessibilityNodeInfoCompat.wrap(this).roleDescription = NativeRuleAccessibilityLabel
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
                node.customActions.forEachIndexed { index, custom ->
                    addAction(AccessibilityNodeInfo.AccessibilityAction(nativeHeadingCustomActionId(index), custom.label))
                }
                addAction(if (isAccessibilityFocused) AccessibilityNodeInfo.AccessibilityAction.ACTION_CLEAR_ACCESSIBILITY_FOCUS else AccessibilityNodeInfo.AccessibilityAction.ACTION_ACCESSIBILITY_FOCUS)
                addAction(if (isFocused) AccessibilityNodeInfo.AccessibilityAction.ACTION_CLEAR_FOCUS else AccessibilityNodeInfo.AccessibilityAction.ACTION_FOCUS)
                node.clippedAbsoluteLocation?.let { location ->
                    setClippedAbsoluteAccessibilityBounds(this, location)
                    return@apply
                }
                emptyLinkBands(node)?.let { bands ->
                    setEmptyLinkAccessibilityBounds(this, node, bands)
                    return@apply
                }
                val bounds = RectF()
                node.bounds.forEach { bounds.union(it) }
                val local = Rect()
                val precise = preciseGeometryClip(node.preciseClip, node.clipBounds)
                val exactFragments = if (precise == null) node.bounds else node.bounds.mapNotNull(precise::bounds)
                if (precise != null) {
                    val visible = RectF()
                    exactFragments.forEach { fragment -> if (!fragment.isEmpty) visible.union(fragment) }
                    visible.offset(paddingLeft.toFloat(), paddingTop.toFloat())
                    visible.roundOut(local)
                } else {
                    bounds.roundOut(local)
                    local.offset(paddingLeft, paddingTop)
                    scrollClip?.inView(this@NativeFloatTextView)?.let { clip ->
                        val rectangle = Rect(); clip.roundOut(rectangle)
                        if (!local.intersect(rectangle)) local.setEmpty()
                    }
                }
                setBoundsInParent(local)
                val screen = if (precise == null) screenRect(bounds) else Rect().also { union ->
                    exactFragments.forEach { fragment -> screenRect(fragment).takeUnless { it.isEmpty }?.let(union::union) }
                }
                setBoundsInScreen(screen)
                val visible = Rect()
                isVisibleToUser = if (tableCoordinateOwner != null || precise != null) isShown && !screen.isEmpty
                    else isShown && getGlobalVisibleRect(visible) && Rect.intersects(visible, screen)
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
            if (tableCoordinateOwner != null && liveTableCoordinates() == null) return false
            if (!originalOwnerAvailable()) return false
            if (virtualViewId == HOST_VIEW_ID) return performAccessibilityAction(action, arguments)
            val node = geometry?.nodes?.find { it.id == virtualViewId } ?: return false
            val custom = node.customActions.indices.firstOrNull { nativeHeadingCustomActionId(it) == action }
            if (custom != null) {
                if (needsGeometry || !isEnabled) return false
                node.customActions[custom].onClick()
                sendNodeEvent(node.id, AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
                return true
            }
            // A virtual action can arrive after bind() but before the new owner is measured.
            // Reject only activation; stale/disabled nodes must still be able to clear focus.
            if ((action == AccessibilityNodeInfo.ACTION_CLICK || action == AccessibilityNodeInfo.ACTION_LONG_CLICK) &&
                (needsGeometry || !isEnabled)) return false
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
                    pendingViewportReveal?.let { pending ->
                        if (pending.clippedScope != null && sameInputNode(pending.node, node)) pendingViewportReveal = null
                    }
                    sendNodeEvent(node.id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED)
                }
                AccessibilityNodeInfo.ACTION_FOCUS -> {
                    val previous = focusRegion
                    focusRegion = nodeFocusRegion(node)
                    if (!requestFocus()) { focusRegion = previous; return false }
                    ordinaryLinkFocusVisible = true
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
            if (tableCoordinateOwner != null) {
                val visible = tableVisibleScreenBounds() ?: RectF()
                val layout = geometry ?: return
                val rectangles = layout.characterRects(start, length).mapIndexed { index, rect ->
                    val precise = preciseGeometryClip(layout.preciseClipForOffset(start + index), layout.clipForOffset(start + index))
                    val local = if (precise == null) rect else rect?.let(precise::bounds)
                    local?.let(::tableBoundsToScreen)?.takeIf { isShown && it.intersect(visible) }
                }.toTypedArray()
                check(rectangles.size == length)
                info.extras.putParcelableArray(extraDataKey, rectangles)
                return
            }
            val visible = Rect()
            val shown = isShown && getGlobalVisibleRect(visible)
            val layout = geometry ?: return
            val rectangles = layout.characterRects(start, length).mapIndexed { index, rect ->
                val precise = preciseGeometryClip(layout.preciseClipForOffset(start + index), layout.clipForOffset(start + index))
                val local = if (precise == null) rect else rect?.let(precise::bounds)
                local?.let { screenRect(it) }?.takeIf {
                    if (precise == null) shown && it.intersect(visible) else isShown && !it.isEmpty
                }?.let { RectF(it) }
            }.toTypedArray()
            check(rectangles.size == length)
            info.extras.putParcelableArray(extraDataKey, rectangles)
        }
    }

    /** A zero-text link owns its declaring band/point, never another owner's caret at the same offset. */
    private fun isEmptyLinkBand(rect: RectF): Boolean = rect.left.isFinite() && rect.top.isFinite() &&
        rect.right.isFinite() && rect.bottom.isFinite() && rect.left == rect.right && rect.height().isFinite() && rect.top <= rect.bottom

    private fun emptyLinkBands(node: FloatInteractionNode): List<RectF>? = node.bounds.takeIf {
        node.kind == FloatInteractionKind.LINK && node.start == node.end && it.isNotEmpty() && it.all(::isEmptyLinkBand)
    }

    private fun nodeRevealBounds(node: FloatInteractionNode): RectF? =
        node.clippedAbsoluteLocation?.bounds ?: node.bounds.firstOrNull { !it.isEmpty } ?: emptyLinkBands(node)?.firstOrNull()

    private fun clippedEmptyBand(band: RectF, rectangle: RectF?, precise: NativeTextClip?): RectF? = projectEmptyLinkBand {
        if (!isEmptyLinkBand(band)) null else {
            val clip = rectangle?.let { precise?.intersected(it) ?: NativeTextClip.rectangle(it) } ?: precise
            if (clip == null) RectF(band) else emptyLinkClipBounds(clip, band)
        }
    }

    private fun emptyLinkClipBounds(clip: NativeTextClip, band: RectF): RectF? =
        if (band.top == band.bottom) {
            if (clip.contains(band.left, band.top)) RectF(band) else null
        } else clip.segmentBounds(band.left, band.top, band.right, band.bottom)

    private fun <T> projectEmptyLinkBand(block: () -> T): T? {
        val attemptedFactory = geometryFactory
        val attemptedGeometry = geometry
        val attemptedGeneration = bindGeneration
        val attemptedScrollClip = scrollClip
        val attemptedCoordinateOwner = tableCoordinateOwner
        val attemptedCoordinates = tableCoordinates
        return try { block() } catch (failure: UnsupportedFloatLayout) {
            // AX/focus queries run after measure. Reuse the owner's deferred failure UI,
            // and never deliver an old query's refusal to a replacement source/clip owner.
            post {
                if (geometryFactory === attemptedFactory && geometry === attemptedGeometry &&
                    bindGeneration == attemptedGeneration && scrollClip === attemptedScrollClip &&
                    tableCoordinateOwner === attemptedCoordinateOwner && tableCoordinates === attemptedCoordinates)
                    unsupportedCallback(failure)
            }
            null
        }
    }

    /** Authored clipped-absolute source is retained for AX independently of its empty
     * paint/input clip and zero-flow host. Only real outer clips constrain this location. */
    private data class ClippedAbsoluteProjection(val local: RectF, val screen: RectF,
        val authority: NativeClippedAbsoluteCoordinateProjection)

    private fun clippedAbsoluteBounds(bounds: RectF, clip: NativeTextClip?): RectF? {
        if (!listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).all(Float::isFinite) ||
            bounds.left > bounds.right || bounds.top > bounds.bottom)
            throw UnsupportedFloatLayout("Clipped absolute semantic bounds are unavailable")
        if (clip == null) return RectF(bounds)
        return when {
            bounds.width() == 0f && bounds.height() == 0f ->
                RectF(bounds).takeIf { clip.contains(bounds.left, bounds.top) }
            bounds.width() == 0f || bounds.height() == 0f ->
                clip.segmentBounds(bounds.left, bounds.top, bounds.right, bounds.bottom)
            else -> clip.bounds(bounds)
        }
    }

    private fun clippedAbsoluteLocalBounds(location: NativeClippedAbsoluteSemanticLocation): RectF? =
        projectClippedAbsolute(location)?.local

    /** Public API 29+ preserves the entire Float transform through the window origin;
     * this application's API 31 minimum needs no rounded getLocationOnScreen anchor. */
    private fun semanticViewToScreen(view: View): Matrix =
        checkedSemanticMatrix(Matrix().also(view::transformMatrixToGlobal))

    private fun checkedSemanticMatrix(matrix: Matrix): Matrix {
        val values = FloatArray(9).also(matrix::getValues)
        if (!values.all(Float::isFinite) || values[6] != 0f || values[7] != 0f || values[8] != 1f ||
            !matrix.invert(Matrix()))
            throw UnsupportedFloatLayout("Clipped absolute semantic transform is unavailable")
        return matrix
    }

    private fun clippedAbsoluteToScreen(): Matrix? {
        val matrix = if (tableCoordinateOwner != null) {
            val coordinates = liveTableCoordinates() ?: return null
            val source = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f)
            val target = FloatArray(6)
            repeat(3) { index ->
                val point = coordinates.localToScreen(Offset(source[index * 2], source[index * 2 + 1]))
                target[index * 2] = point.x; target[index * 2 + 1] = point.y
            }
            val fourth = coordinates.localToScreen(Offset(1f, 1f))
            val value = Matrix()
            if (!target.all(Float::isFinite) || !value.setPolyToPoly(source, 0, target, 0, 3))
                throw UnsupportedFloatLayout("Clipped absolute table coordinates are unavailable")
            val check = floatArrayOf(1f, 1f).also(value::mapPoints)
            if (!fourth.x.isFinite() || !fourth.y.isFinite() ||
                kotlin.math.abs(check[0] - fourth.x) > .01f || kotlin.math.abs(check[1] - fourth.y) > .01f)
                throw UnsupportedFloatLayout("Clipped absolute table perspective is unavailable")
            checkedSemanticMatrix(value)
        } else semanticViewToScreen(this)
        matrix.preTranslate((paddingLeft - scrollX).toFloat(), (paddingTop - scrollY).toFloat())
        return checkedSemanticMatrix(matrix)
    }

    private fun projectClippedAbsolute(location: NativeClippedAbsoluteSemanticLocation,
        clipResult: Boolean = true): ClippedAbsoluteProjection? = projectEmptyLinkBand {
        if (!isAttachedToWindow || !isShown || windowVisibility != VISIBLE || needsGeometry || !originalOwnerAvailable())
            return@projectEmptyLinkBand null
        var ancestor: View? = this
        while (ancestor != null) {
            if (ancestor.alpha <= 0f) return@projectEmptyLinkBand null
            ancestor = ancestor.parent as? View
        }
        val sourceToScreen = clippedAbsoluteToScreen() ?: return@projectEmptyLinkBand null
        val scope = location.coordinateScope
            ?: throw UnsupportedFloatLayout("Clipped absolute containing-block authority is unavailable")
        val authority = scope.project(sourceToScreen, scrollClip, location.viewportSteps) ?: return@projectEmptyLinkBand null
        val toScreen = checkedSemanticMatrix(authority.toScreen)
        var screenClip: NativeTextClip? = if (clipResult) authority.clip else null
        if (clipResult) {
            location.clipBounds?.let { bounds ->
                val own = NativeTextClip.rectangle(bounds).transformed(toScreen)
                screenClip = screenClip?.intersected(own) ?: own
            }
            location.preciseClip?.transformed(toScreen)?.let { own ->
                screenClip = screenClip?.intersected(own) ?: own
            }
        }
        val box = location.bounds
        clippedAbsoluteBounds(box, null) // Validate even an unclipped reveal request.
        val screen = if (box.width() == 0f || box.height() == 0f) {
            val points = floatArrayOf(box.left, box.top, box.right, box.bottom).also(toScreen::mapPoints)
            if (!points.all(Float::isFinite)) throw UnsupportedFloatLayout("Clipped absolute semantic location is unavailable")
            val clip = screenClip
            if (points[0] == points[2] && points[1] == points[3])
                RectF(points[0], points[1], points[0], points[1]).takeIf { clip == null || clip.contains(points[0], points[1]) }
            else if (clip == null) RectF(minOf(points[0], points[2]), minOf(points[1], points[3]),
                maxOf(points[0], points[2]), maxOf(points[1], points[3]))
            else clip.segmentBounds(points[0], points[1], points[2], points[3])
        } else {
            val envelope = RectF(box).also { toScreen.mapRect(it) }
            screenClip?.intersected(NativeTextClip.rectangle(box).transformed(toScreen))?.bounds(envelope)
                ?: envelope.takeIf { screenClip == null }
        } ?: return@projectEmptyLinkBand null
        val screenToSource = Matrix()
        if (!sourceToScreen.invert(screenToSource)) throw UnsupportedFloatLayout("Clipped absolute source transform is unavailable")
        val local = RectF(screen).also { screenToSource.mapRect(it) }
        if (!listOf(local.left, local.top, local.right, local.bottom).all(Float::isFinite))
            throw UnsupportedFloatLayout("Clipped absolute local semantic bounds are unavailable")
        ClippedAbsoluteProjection(local, screen, authority).takeIf { authority.isCurrent() }
    }

    private fun setClippedAbsoluteAccessibilityBounds(info: AccessibilityNodeInfo,
        location: NativeClippedAbsoluteSemanticLocation) {
        val projection = projectClippedAbsolute(location)
        info.setBoundsInParent(Rect().also { out -> projection?.local?.let { local ->
            RectF(local).apply { offset(paddingLeft.toFloat(), paddingTop.toFloat()) }.roundOut(out)
        } })
        info.setBoundsInScreen(Rect().also { projection?.screen?.roundOut(it) })
        // A genuine zero-area retained semantic anchor remains discoverable. It never
        // contributes pointer area, a glyph, focus paint, or a measured View dimension.
        info.isVisibleToUser = projection != null
    }

    private fun includeClippedAbsoluteHostBounds(info: AccessibilityNodeInfo) {
        val projections = geometry?.clippedAbsoluteSemanticLocations.orEmpty().mapNotNull(::projectClippedAbsolute)
        if (projections.isEmpty()) return
        val visible = projections.map { it.screen }.toMutableList()
        if (info.isVisibleToUser) {
            val original = Rect().also(info::getBoundsInScreen)
            if (!original.isEmpty) visible += RectF(original)
        }
        val screen = RectF(visible.minOf { it.left }, visible.minOf { it.top },
            visible.maxOf { it.right }, visible.maxOf { it.bottom })
        info.setBoundsInScreen(Rect().also(screen::roundOut))
        projectEmptyLinkBand {
            val parentView = parent as? View
            if (parentView != null) {
                val inverse = Matrix()
                if (!semanticViewToScreen(parentView).invert(inverse))
                    throw UnsupportedFloatLayout("Clipped absolute semantic parent is unavailable")
                val parentBounds = RectF(screen).also { inverse.mapRect(it) }
                info.setBoundsInParent(Rect().also(parentBounds::roundOut))
            }
        }
        info.isVisibleToUser = true
    }

    private fun setEmptyLinkAccessibilityBounds(info: AccessibilityNodeInfo, node: FloatInteractionNode,
        bands: List<RectF>) {
        if (projectEmptyLinkBand { projectEmptyLinkAccessibilityBounds(info, node, bands); true } != true) {
            info.setBoundsInParent(Rect())
            info.setBoundsInScreen(Rect())
            info.isVisibleToUser = false
        }
    }

    private fun projectEmptyLinkAccessibilityBounds(info: AccessibilityNodeInfo, node: FloatInteractionNode,
        bands: List<RectF>) {
        // Declaring metadata remains located even in a zero-width host. Only the actual
        // node/ancestor clips restrict these bounds; host visibility is checked separately.
        var clip = node.preciseClip
        node.clipBounds?.let { clip = clip?.intersected(it) ?: NativeTextClip.rectangle(it) }
        scrollClip?.preciseInView(this)?.translated(-paddingLeft.toFloat(), -paddingTop.toFloat())?.let {
            clip = clip?.intersected(it) ?: it
        }
        scrollClip?.inView(this)?.let {
            it.offset(-paddingLeft.toFloat(), -paddingTop.toFloat())
            clip = clip?.intersected(it) ?: NativeTextClip.rectangle(it)
        }
        val fragments = bands.mapNotNull { band ->
            val exact = clip
            if (exact == null) RectF(band) else emptyLinkClipBounds(exact, band)
        }
        fun envelope(rectangles: List<RectF>): RectF? = rectangles.firstOrNull()?.let { first ->
            RectF(first).apply {
                rectangles.drop(1).forEach {
                    left = min(left, it.left); top = min(top, it.top)
                    right = max(right, it.right); bottom = max(bottom, it.bottom)
                }
            }
        }
        val parent = envelope(fragments)?.apply { offset(paddingLeft.toFloat(), paddingTop.toFloat()) }
        info.setBoundsInParent(Rect().also { parent?.roundOut(it) })
        val screen = envelope(fragments.mapNotNull(::emptyBandScreenBounds))
        info.setBoundsInScreen(Rect().also { screen?.roundOut(it) })
        val host = if (tableCoordinateOwner != null) {
            tableScreenToLocal(NativeTextClip.rectangle(tableVisibleScreenBounds() ?: RectF()))
                ?.translated(-paddingLeft.toFloat(), -paddingTop.toFloat())
                ?: NativeTextClip.rectangle(RectF())
        } else {
            val visible = Rect()
            if (!getLocalVisibleRect(visible)) visible.setEmpty()
            NativeTextClip.rectangle(RectF(visible).apply { offset(-paddingLeft.toFloat(), -paddingTop.toFloat()) })
        }
        val visibleClip = clip?.intersected(host) ?: host
        info.isVisibleToUser = isShown && bands.any { band ->
            band.top < band.bottom &&
                visibleClip.segmentBounds(band.left, band.top, band.right, band.bottom)?.let(::emptyBandScreenBounds) != null
        }
    }

    /** Transform the actual segment endpoints; a rotated envelope is not the source segment. */
    private fun emptyBandScreenBounds(band: RectF): RectF? {
        if (!isEmptyLinkBand(band)) return null
        val isPoint = band.top == band.bottom
        val points = floatArrayOf(band.left + paddingLeft - scrollX, band.top + paddingTop - scrollY,
            band.right + paddingLeft - scrollX, band.bottom + paddingTop - scrollY)
        if (tableCoordinateOwner != null) {
            val coordinates = liveTableCoordinates() ?: return null
            val first = coordinates.localToScreen(Offset(points[0], points[1]))
            val last = coordinates.localToScreen(Offset(points[2], points[3]))
            points[0] = first.x; points[1] = first.y; points[2] = last.x; points[3] = last.y
        } else {
            val transform = Matrix()
            var current: View? = this
            while (current != null) {
                transform.postConcat(current.matrix)
                val parent = current.parent as? View
                transform.postTranslate(current.left.toFloat() - (parent?.scrollX ?: 0),
                    current.top.toFloat() - (parent?.scrollY ?: 0))
                current = parent
            }
            val values = FloatArray(9); transform.getValues(values)
            if (values.any { !it.isFinite() } || values[6] != 0f || values[7] != 0f || values[8] != 1f) return null
            val origin = floatArrayOf(0f, 0f)
            transform.mapPoints(origin)
            val location = IntArray(2); getLocationOnScreen(location)
            transform.mapPoints(points)
            for (index in 0..2 step 2) {
                points[index] += location[0] - origin[0]
                points[index + 1] += location[1] - origin[1]
            }
        }
        if (points.any { !it.isFinite() } || !isPoint && points[0] == points[2] && points[1] == points[3]) return null
        var clip: NativeTextClip? = null
        scrollClip?.inScreen()?.let { clip = clip?.intersected(it) ?: NativeTextClip.rectangle(it) }
        scrollClip?.preciseInScreen()?.let { clip = clip?.intersected(it) ?: it }
        if (isPoint) return if (clip?.contains(points[0], points[1]) != false)
            RectF(points[0], points[1], points[0], points[1]) else null
        return clip?.segmentBounds(points[0], points[1], points[2], points[3])
            ?: if (clip != null) null else RectF(min(points[0], points[2]), min(points[1], points[3]),
                max(points[0], points[2]), max(points[1], points[3]))
    }

    /** Join shapes before bounding; bounding an inner arc first can resurrect its removed
     * corner when a later rectangular ancestor clips that envelope. Coordinates here are
     * the unchanged geometry coordinates, before the View's own padding translation. */
    private fun preciseGeometryClip(own: NativeTextClip?, rectangle: RectF?): NativeTextClip? {
        val inherited = scrollClip?.preciseInView(this)?.translated(-paddingLeft.toFloat(), -paddingTop.toFloat())
        var clip = if (own == null) inherited else if (inherited == null) own else own.intersected(inherited)
        if (clip == null) return null
        rectangle?.let { clip = checkNotNull(clip).intersected(it) }
        scrollClip?.inView(this)?.let { bounds ->
            bounds.offset(-paddingLeft.toFloat(), -paddingTop.toFloat())
            clip = checkNotNull(clip).intersected(bounds)
        }
        if (tableCoordinateOwner != null) {
            val visible = NativeTextClip.rectangle(tableVisibleScreenBounds() ?: RectF())
            val local = checkNotNull(tableScreenToLocal(visible)).translated(-paddingLeft.toFloat(), -paddingTop.toFloat())
            clip = checkNotNull(clip).intersected(local)
        } else {
            // View's public local rectangle is already in this owner's coordinates; global
            // visible bounds belong to the root View, not necessarily the screen.
            val visible = Rect()
            if (!getLocalVisibleRect(visible)) visible.setEmpty()
            val local = RectF(visible).apply { offset(-paddingLeft.toFloat(), -paddingTop.toFloat()) }
            clip = checkNotNull(clip).intersected(local)
        }
        return clip
    }

    /** The bound surface is the real NativeSurfaceGeometry extent, not its Table allocation. */
    private fun tableVisibleScreenBounds(): RectF? {
        if (tableCoordinateOwner == null) return null
        val coordinates = liveTableCoordinates() ?: return RectF()
        val window = coordinates.boundsInWindow()
        val screenOrigin = coordinates.localToScreen(Offset.Zero)
        val windowOrigin = coordinates.localToWindow(Offset.Zero)
        if (listOf(window.left, window.top, window.right, window.bottom, screenOrigin.x, screenOrigin.y,
                windowOrigin.x, windowOrigin.y).any { !it.isFinite() }) return RectF()
        val visible = RectF(window.left, window.top, window.right, window.bottom)
        visible.offset(screenOrigin.x - windowOrigin.x, screenOrigin.y - windowOrigin.y)
        scrollClip?.inScreen()?.let { if (!visible.intersect(it)) visible.setEmpty() }
        return visible
    }
    private fun tableMapBounds(bounds: RectF, toScreen: Boolean): RectF? {
        if (tableCoordinateOwner == null) return null
        val coordinates = liveTableCoordinates() ?: return RectF()
        if (bounds.isEmpty) return RectF()
        val corners = arrayOf(Offset(bounds.left, bounds.top), Offset(bounds.right, bounds.top),
            Offset(bounds.right, bounds.bottom), Offset(bounds.left, bounds.bottom)).map {
            if (toScreen) coordinates.localToScreen(it) else coordinates.screenToLocal(it)
        }
        if (corners.any { !it.x.isFinite() || !it.y.isFinite() }) return RectF()
        return RectF(corners.minOf { it.x }, corners.minOf { it.y }, corners.maxOf { it.x }, corners.maxOf { it.y })
    }
    internal fun tableScreenToLocal(bounds: RectF): RectF? = tableMapBounds(bounds, false)
    internal fun tableScreenToLocal(clip: NativeTextClip): NativeTextClip? {
        if (tableCoordinateOwner == null) return null
        val coordinates = liveTableCoordinates() ?: return NativeTextClip.rectangle(RectF())
        val origin = coordinates.screenToLocal(Offset.Zero)
        val horizontal = coordinates.screenToLocal(Offset(1f, 0f))
        val vertical = coordinates.screenToLocal(Offset(0f, 1f))
        val last = coordinates.screenToLocal(Offset(1f, 1f))
        val values = floatArrayOf(horizontal.x - origin.x, vertical.x - origin.x, origin.x,
            horizontal.y - origin.y, vertical.y - origin.y, origin.y, 0f, 0f, 1f)
        if (values.any { !it.isFinite() } || !last.x.isFinite() || !last.y.isFinite() ||
            kotlin.math.abs(last.x - (horizontal.x + vertical.x - origin.x)) > .01f ||
            kotlin.math.abs(last.y - (horizontal.y + vertical.y - origin.y)) > .01f)
            return NativeTextClip.rectangle(RectF())
        return clip.transformed(Matrix().apply { setValues(values) })
    }
    private fun tableBoundsToScreen(bounds: RectF): RectF? = tableMapBounds(RectF(bounds).apply {
        offset((paddingLeft - scrollX).toFloat(), (paddingTop - scrollY).toFloat())
    }, true)

    private fun screenRect(bounds: RectF): Rect {
        tableBoundsToScreen(bounds)?.let { screen ->
            if (!screen.intersect(tableVisibleScreenBounds() ?: RectF())) screen.setEmpty()
            scrollClip?.preciseInScreen()?.let { screen.set(it.bounds(screen) ?: RectF()) }
            return Rect().also { screen.roundOut(it) }
        }
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
        scrollClip?.inScreen()?.let { if (!screen.intersect(it)) screen.setEmpty() }
        scrollClip?.preciseInScreen()?.let { screen.set(it.bounds(screen) ?: RectF()) }
        return Rect().also { screen.roundOut(it) }
    }
}
