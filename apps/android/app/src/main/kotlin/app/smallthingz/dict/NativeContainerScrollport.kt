package app.smallthingz.dict

import android.graphics.RectF
import android.view.View
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.Constraints
import kotlin.math.ceil
import kotlin.math.floor
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.MutatePriority
import androidx.compose.foundation.gestures.FlingBehavior
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.ScrollScope
import androidx.compose.foundation.gestures.ScrollableDefaults
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.ScrollAxisRange
import androidx.compose.ui.semantics.horizontalScrollAxisRange
import androidx.compose.ui.semantics.scrollBy
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.LayoutDirection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import android.content.Context
import android.graphics.Canvas
import android.view.MotionEvent
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.key
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.PointerInputModifierNode
import androidx.compose.ui.node.LayoutAwareModifierNode
import androidx.compose.ui.node.requireLayoutCoordinates
import androidx.compose.ui.relocation.BringIntoViewModifierNode
import androidx.compose.ui.relocation.bringIntoView as bringIntoViewParent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.viewinterop.AndroidView

/** This is a reader capability restriction; stored Auto and its old wire bytes are unchanged. */
internal fun nativeScrollportUnavailable(style: ContainerStyle, flexItem: Boolean = false): String? {
    if (style.overflow == ContainerOverflow.Hidden) {
        val rules = style.screenMaxWidth?.let { listOf(it) + it.followingRules }.orEmpty()
        val numeric = style.margins?.let { listOf(it.top, it.right, it.bottom, it.left) }.orEmpty()
        return when {
            style.height != null || style.minHeight != null -> "Hidden scrollports require automatic block height"
            flexItem || style.flexItem != null || (style.layout == ContainerLayout.FlexRow || style.layout == ContainerLayout.FlexColumn) -> "Hidden scrollports in flex layout are unavailable"
            style.columns != null || style.floatSide != null || style.positionedScope != null ||
                style.positioning != null && style.positioning != ContainerPositioning.RelativeAuto ||
                style.absolutePosition != null || style.absoluteStatic != null || style.textWrap != null ->
                "This hidden scrollport formatting combination is unavailable"
            style.width != null && style.width != ContainerWidth.Auto && style.width != ContainerWidth.FitContent ->
                "Hidden scrollports require automatic or fit-content width"
            style.marginValues != null || numeric.any { it.value < 0f } -> "Unsupported external hidden scrollport margins"
            rules.any { it.lineHeight != null || it.floatSide != null || it.margins != null || it.clear != null } ->
                "This responsive hidden scrollport override is unavailable"
            else -> null
        }
    }
    if (style.overflow != ContainerOverflow.Auto) return null
    val margins = style.marginValues
    val numeric = style.margins?.let { listOf(it.top, it.right, it.bottom, it.left) }.orEmpty()
    return when {
        style.height != null || style.minHeight != null -> "Automatic scrollports require automatic block height"
        flexItem || style.flexItem != null || (style.layout == ContainerLayout.FlexRow || style.layout == ContainerLayout.FlexColumn) -> "Automatic scrollports in flex layout are unavailable"
        style.columns != null || style.positioning != null || style.floatSide != null -> "This scrollport formatting combination is unavailable"
        style.screenMaxWidth != null -> "Responsive scrollport overrides are unavailable"
        style.width != null && style.width != ContainerWidth.Auto -> "Automatic scrollports require automatic width"
        (style.maxWidth as? ContainerMaxWidth.Length)?.value?.unit == StyleWidthUnit.Percent -> "Percentage scrollport maximum width is unavailable"
        margins != null -> "Base margin values on scrollports are unavailable"
        numeric.any { it.value < 0f } -> "Negative external scrollport margins are unavailable"
        else -> null
    }
}

internal data class NativePositionedScrollportPolicy(val source: Container, val overflowX: PositionedOverflowX)
internal data class NativeOrdinaryHiddenScrollportPolicy(val source: Container)
internal data class NativeScrollportSpec(val parts: List<NativeFloatContextSpec>, val padding: FloatMargins,
    val positioned: NativePositionedScrollportPolicy? = null,
    val ordinaryHidden: NativeOrdinaryHiddenScrollportPolicy? = null) {
    init { require(positioned == null || ordinaryHidden == null) { "Conflicting scrollport owner policies" } }
}

internal data class NativeOwnedScrollportAllocation(val viewport: Int, val height: Int,
    val usedHeight: Float, val overflow: Float, val originX: Float, val originY: Float,
    val verticalOverflow: Boolean, val leadingOverflow: Boolean)

/** The authored padding box keeps its normal-flow height. Descendant overflow adds range,
 * never another contribution to that height. The old Auto allocation remains unchanged. */
internal fun nativePositionedScrollportAllocation(viewport: Int, usedHeight: Float,
    layout: NativeFloatBounds, padding: FloatMargins): NativeOwnedScrollportAllocation {
    require(viewport in 0..TablePixelLimit && usedHeight.isFinite() && usedHeight >= 0f)
    require(padding.left == 0f && padding.right == 0f)
    require(listOf(padding.top, padding.bottom).all { it.isFinite() && it >= 0f })
    val height = usedHeight.toDouble() + padding.top.toDouble() + padding.bottom.toDouble()
    val right = layout.right.toDouble() + padding.left.toDouble() + padding.right.toDouble()
    val overflow = (right - viewport).coerceAtLeast(0.0)
    if (!height.isFinite() || height > TablePixelLimit || !overflow.isFinite() || overflow > TablePixelLimit ||
        listOf(layout.left, layout.top, layout.right, layout.bottom).any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Positioned scrollport extent exceeds native geometry")
    return NativeOwnedScrollportAllocation(viewport, ceil(height).toInt(), height.toFloat(), overflow.toFloat(),
        padding.left, padding.top, layout.top.toDouble() + padding.top < 0.0 || layout.bottom.toDouble() + padding.top > height,
        layout.left.toDouble() + padding.left < 0.0)
}


/** Keep the original Float edge values separate until the final integer allocation. */
internal fun nativeOrdinaryHiddenContentWidth(viewport: Int, padding: FloatMargins): Int {
    require(viewport in 0..TablePixelLimit)
    val edges = nativeOrdinaryHiddenHorizontalPadding(padding)
    return floor((viewport.toDouble() - edges).coerceAtLeast(0.0)).toInt()
}
internal fun nativeOrdinaryHiddenIntrinsicWidth(content: Int, padding: FloatMargins): Int {
    require(content >= 0)
    return (content.toLong() + ceil(nativeOrdinaryHiddenHorizontalPadding(padding)).toLong())
        .coerceAtMost(Constraints.Infinity.toLong()).toInt()
}
private fun nativeOrdinaryHiddenHorizontalPadding(padding: FloatMargins): Double {
    require(padding.left.isFinite() && padding.right.isFinite() && padding.left >= 0f && padding.right >= 0f)
    return padding.left.toDouble() + padding.right.toDouble()
}

/** Ordinary Hidden owns its real padding box. Layout overflow supplies the programmatic
 * horizontal range; neither descendant ink nor out-of-flow overflow enlarges normal height. */
internal fun nativeOrdinaryHiddenScrollportAllocation(viewport: Int, usedHeight: Float,
    layout: NativeFloatBounds, padding: FloatMargins): NativeOwnedScrollportAllocation {
    require(viewport in 0..TablePixelLimit && usedHeight.isFinite() && usedHeight >= 0f)
    require(listOf(padding.top, padding.right, padding.bottom, padding.left).all { it.isFinite() && it >= 0f })
    val height = usedHeight.toDouble() + padding.top.toDouble() + padding.bottom.toDouble()
    val right = layout.right.toDouble() + padding.left.toDouble() + padding.right.toDouble()
    val overflow = (right - viewport).coerceAtLeast(0.0)
    if (!height.isFinite() || height > TablePixelLimit || !overflow.isFinite() || overflow > TablePixelLimit ||
        listOf(layout.left, layout.top, layout.right, layout.bottom).any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Hidden scrollport extent exceeds native geometry")
    return NativeOwnedScrollportAllocation(viewport, ceil(height).toInt(), height.toFloat(), overflow.toFloat(),
        padding.left, padding.top, layout.top.toDouble() + padding.top < 0.0 || layout.bottom.toDouble() + padding.top > height,
        layout.left.toDouble() + padding.left < 0.0)
}

internal data class NativePositionedScrollbarMetrics(val extent: Int, val range: Int, val offset: Int)

/** Quantize native UA painting only; physical content retains the exact fractional offset. */
internal fun nativePositionedScrollbarMetrics(viewport: Float, overflow: Float,
    physicalOffset: Float): NativePositionedScrollbarMetrics {
    require(viewport.isFinite() && viewport in 0f..TablePixelLimit.toFloat() &&
        overflow.isFinite() && overflow in 0f..TablePixelLimit.toFloat() &&
        physicalOffset.isFinite() && physicalOffset in 0f..overflow)
    val extent = ceil(viewport).toInt()
    val range = ceil(viewport.toDouble() + overflow.toDouble()).toInt()
    val offset = if (overflow == 0f) 0 else kotlin.math.round(
        physicalOffset.toDouble() / overflow.toDouble() * (range - extent)).toInt()
    return NativePositionedScrollbarMetrics(extent, range, offset)
}

/** Layout overflow, not glyph ink, determines the range. The first domain has no local y axis. */
internal data class NativeScrollportAllocation(val viewport: Int, val content: Int, val height: Int,
    val originX: Float, val originY: Float, val verticalOverflow: Boolean, val leadingOverflow: Boolean) {
    val range: Int get() = content - viewport
}
internal fun nativeScrollportAllocation(viewport: Int, usedHeight: Float, layout: NativeFloatBounds,
    padding: FloatMargins): NativeScrollportAllocation {
    require(viewport in 0..TablePixelLimit && usedHeight.isFinite() && usedHeight >= 0f)
    val left = minOf(0f, layout.left)
    val right = maxOf((viewport - padding.left - padding.right).coerceAtLeast(0f), layout.right)
    val top = minOf(0f, layout.top)
    val bottom = maxOf(usedHeight, layout.bottom)
    val width = ceil(right - left + padding.left + padding.right).toDouble()
    val height = ceil(bottom - top + padding.top + padding.bottom).toDouble()
    if (width > TablePixelLimit || height > TablePixelLimit)
        throw UnsupportedFloatLayout("Scrollport extent exceeds native geometry")
    return NativeScrollportAllocation(viewport, maxOf(viewport, width.toInt()), height.toInt(),
        padding.left - left, padding.top - top,
        top < -.01f || bottom > usedHeight + .01f, left < -.01f)
}

/** A viewport belongs to its real Compose owner. Native virtual descendants intersect the same
 * screen clip, including nested owners, instead of assuming the Android host window is the clip. */
internal class NativeScrollClip(private val parent: NativeScrollClip?) {
    internal val semanticParent: NativeScrollClip? get() = parent
    private var semanticCoordinates: androidx.compose.ui.layout.LayoutCoordinates? = null
    private var semanticTranslation: (() -> Offset?)? = null
    fun updateSemanticScroll(coordinates: androidx.compose.ui.layout.LayoutCoordinates, translation: () -> Offset?) {
        semanticCoordinates = coordinates; semanticTranslation = translation
    }
    fun semanticScrollTranslationInScreen(): Offset? {
        val coordinates = semanticCoordinates?.takeIf { it.isAttached } ?: return null
        val shift = semanticTranslation?.invoke() ?: return null
        if (!shift.x.isFinite() || !shift.y.isFinite())
            throw UnsupportedFloatLayout("Clipped absolute viewport translation is unavailable")
        val origin = coordinates.localToScreen(Offset.Zero)
        val moved = coordinates.localToScreen(shift)
        return (moved - origin).takeIf { it.x.isFinite() && it.y.isFinite() }
    }
    private var screen: RectF? = null
    private var preciseScreen: NativeTextClip? = null
    fun update(bounds: Rect, view: View, precise: NativeTextClip? = null) {
        val window = IntArray(2); val global = IntArray(2)
        view.getLocationInWindow(window); view.getLocationOnScreen(global)
        screen = RectF(bounds.left + global[0] - window[0], bounds.top + global[1] - window[1],
            bounds.right + global[0] - window[0], bounds.bottom + global[1] - window[1])
        preciseScreen = precise?.translated((global[0] - window[0]).toFloat(), (global[1] - window[1]).toFloat())
    }
    fun preciseInScreen(): NativeTextClip? {
        val inherited = parent?.preciseInScreen()
        val own = preciseScreen
        val result = if (own == null) inherited else if (inherited == null) own else own.intersected(inherited)
        return result?.intersected(inScreen())
    }
    fun preciseInView(view: View): NativeTextClip? = preciseInScreen()?.let { clip ->
        when (view) {
            is NativeTableScrollFocusView -> view.tableScreenToLocal(clip)
            is NativeFloatTextView -> view.tableScreenToLocal(clip)
            else -> null
        } ?: run {
            val at = IntArray(2); view.getLocationOnScreen(at)
            clip.translated(-at[0].toFloat(), -at[1].toFloat())
        }
    }
    fun inScreen(): RectF {
        val result = screen?.let(::RectF) ?: return RectF()
        parent?.inScreen()?.let { if (!result.intersect(it)) result.setEmpty() }
        return result
    }
    fun inView(view: View): RectF {
        (view as? NativeFloatTextView)?.tableScreenToLocal(inScreen())?.let { return it }
        return inScreen().apply {
            val at = IntArray(2); view.getLocationOnScreen(at); offset(-at[0].toFloat(), -at[1].toFloat())
        }
    }
}
internal val LocalNativeScrollClip = staticCompositionLocalOf<NativeScrollClip?> { null }
internal val LocalNativeContainerScrollport = staticCompositionLocalOf { false }

/** One delegated child owns the complete original prepared graph. Its Tables yield their own
 * scrollers; the existing native selection owners keep their original text and action identities. */
@Composable
internal fun NativeContainerScrollport(spec: NativeScrollportSpec, linkColor: Color,
    parentMeasureInput: NativeLayoutInput<Unit>,
    child: @Composable (Int, NativeLayoutInput<Int>) -> Unit) {
    if (spec.positioned != null || spec.ordinaryHidden != null) {
        NativeOwnedContainerScrollport(spec, linkColor, parentMeasureInput, child)
        return
    }
    val scroll = rememberScrollState()
    val parentClip = LocalNativeScrollClip.current
    val clip = remember(parentClip) { NativeScrollClip(parentClip) }
    val view = LocalView.current
    val message = remember { NativeLayoutInput<String?>(null) }
    val viewportMeasureInput = remember { NativeLayoutInput(Unit) }
    val ancestor = LocalNativeSemanticMeasurement.current
    val input = remember(ancestor, parentMeasureInput) { NativeContextMeasureInput(ancestor) {
        viewportMeasureInput.invalidate()
        parentMeasureInput.invalidate()
    } }
    val density = LocalDensity.current
    val environment = NativeFlowEnvironment(density.density, density.fontScale,
        LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
    val composition = Any()
    val request = LocalCellHeadingRequest.current
    val reached = LocalCellHeadingReached.current
    fun leaves(parts: List<NativeFloatContextSpec>): List<NativeFloatContextSpec> = parts.flatMap {
        (it as? NativeFloatContextSpec.Container)?.preparedParts?.let(::leaves) ?: listOf(it)
    }
    val revealIndex = leaves(spec.parts).indexOfFirst { when (it) {
        is NativeFloatContextSpec.Text -> it.path == request?.path
        is NativeFloatContextSpec.Flow -> it.path == request?.path
        else -> false
    } }.takeIf { request != null && it >= 0 }
    CompositionLocalProvider(LocalNativeScrollClip provides clip,
        LocalNativeContainerScrollport provides true,
        LocalTableContentWidths provides true,
        LocalNativeContextMeasureInput provides input,
        LocalNativeFlowMeasureInput provides null,
        LocalNativeContextInteractionOwner provides true,
        LocalNativeContextContainAtEnd provides true) {
        Layout(modifier = viewportMeasureInput.modifier.fillMaxWidth().clipToBounds().onGloballyPositioned {
            clip.update(it.boundsInWindow(), view)
            clip.updateSemanticScroll(it) {
                scroll.maxValue.takeIf { range -> range in 0..TablePixelLimit }?.let { range ->
                    Offset(if (environment.direction == LayoutDirection.Rtl) -range.toFloat() + scroll.value else -scroll.value.toFloat(), 0f)
                }
            }
        }.horizontalScroll(scroll), content = {
            NativeFloatContextLayout(spec.parts, Modifier, linkColor, containAtEnd = true,
                revealIndex = revealIndex, revealToken = request,
                onRevealed = { if (request != null) reached(request) }, adjoining = true,
                child = child)
            NativeLayoutMessage(message)
        }, measurePolicy = object : MeasurePolicy {
            override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                (measurables.first().minIntrinsicWidth(height).toLong() + ceil(spec.padding.left + spec.padding.right).toLong())
                    .coerceAtMost(Constraints.Infinity.toLong()).toInt()
            override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                (measurables.first().maxIntrinsicWidth(height).toLong() + ceil(spec.padding.left + spec.padding.right).toLong())
                    .coerceAtMost(Constraints.Infinity.toLong()).toInt()
            override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                // horizontalScroll retains the actual filled viewport minimum. Text shaping and
                // percentage tables receive this finite width, never its unbounded scroll maximum.
                val viewport = constraints.minWidth
                val contentWidth = floor((viewport - spec.padding.left - spec.padding.right).coerceAtLeast(0f)).toInt()
                val childConstraints = Constraints(minWidth = contentWidth, maxWidth = contentWidth)
                val request = input.request(constraints, childConstraints, environment,
                    NativeFlowParentPolicy(composition, true, null, 0f), emptyList())
                val content = measurables.first().measure(childConstraints)
                val measured = input.measured(request)
                val geometry = measured?.result?.getOrNull()
                check(geometry == null || geometry.width == content.width && geometry.height == content.height)
                val bounds = geometry?.scrollableBounds ?: measured?.fallbackBounds ?:
                    NativeFloatBounds(0f, 0f, contentWidth.toFloat(), content.height.toFloat())
                val allocation = nativeScrollportAllocation(viewport, geometry?.usedHeight ?: content.height.toFloat(), bounds, spec.padding)
                // Preserve the complete real body on an unsupported y-overflow result; its visible
                // warning and expanded fallback are not a successful local-scroll layout.
                message.update(when {
                    allocation.verticalOverflow -> "Local vertical overflow is unavailable"
                    allocation.leadingOverflow -> "Leading horizontal overflow is unavailable"
                    else -> null
                })
                val warning = measurables.last().measure(Constraints(maxWidth = viewport))
                val height = allocation.height.toLong() + warning.height
                if (height > TablePixelLimit) throw UnsupportedFloatLayout("Scrollport fallback exceeds native geometry")
                return layout(allocation.content, height.toInt()) {
                    warning.place(0, 0)
                    val x = floor(allocation.originX).toInt()
                    val y = floor(allocation.originY).toInt()
                    content.placeWithLayer(x, y + warning.height) {
                        translationX = allocation.originX - x
                        translationY = allocation.originY - y
                    }
                }
            }
        })
    }
}

private class NativePositionedScopeIdentity(private val source: Container) {
    override fun equals(other: Any?) = other is NativePositionedScopeIdentity && source === other.source
    override fun hashCode() = System.identityHashCode(source)
}

private data class NativePositionedScrollPlacement(val viewport: Float = 0f, val overflow: Float = 0f,
    val physicalOffset: Float = 0f, val userEnabled: Boolean = false)

/** One retained native scroll state; Hidden disables direct input, not source-action reveal. */
private class NativePositionedScrollOwner(private val state: ScrollState, private val scope: CoroutineScope,
    private val flingBehavior: FlingBehavior, private val invalidate: () -> Unit) : NativeHorizontalScrollTarget {
    var userEnabled = false
        private set
    private var userMotion = false
    fun selectUserMode(enabled: Boolean) {
        if (userEnabled && !enabled && userMotion) { motion?.cancel(); motion = null; userMotion = false }
        userEnabled = enabled
        bar?.syncOwner()
    }
    var available = false
    var sourceAvailable = false
    private var bar: NativePositionedScrollBarView? = null
    fun attach(value: NativePositionedScrollBarView) { bar = value; value.syncOwner() }
    fun detach(value: NativePositionedScrollBarView) { if (bar === value) bar = null }
    fun positionedBar(value: LayoutCoordinates) { bar?.positioned(value) }
    val showsBar: Boolean get() = !closed && userEnabled && available && sourceAvailable
    var rtl = false
    var viewport = 0f
    var overflow = 0f
    var paddingLeft = 0f
    private var maximum = 0
    private var closed = false
    private var motion: Job? = null
    private var revision = 0L
    private data class Placed(val revision: Long, val value: Int, val viewport: Float,
        val overflow: Float, val paddingLeft: Float, val rtl: Boolean)
    private var lastPlaced: Placed? = null
    private fun currentPlacement(): Boolean = lastPlaced?.let {
        it.revision == revision && it.value == state.value && it.viewport == viewport &&
            it.overflow == overflow && it.paddingLeft == paddingLeft && it.rtl == rtl
    } == true
    private data class Reveal(val afterRevision: Long, val complete: () -> Unit, var applied: Int? = null,
        val cancelled: (() -> Unit)? = null, var completed: Boolean = false)
    private var pending: Reveal? = null
        set(value) {
            if (field === value) return
            val previous = field; field = value
            if (previous?.completed == false) previous.cancelled?.invoke()
        }
    var placement by mutableStateOf(NativePositionedScrollPlacement())
        private set
    fun selectRange(viewport: Float, overflow: Float, paddingLeft: Float, rtl: Boolean) {
        this.viewport = viewport; this.overflow = overflow; this.paddingLeft = paddingLeft; this.rtl = rtl
        maximum = ceil(overflow).toInt()
        if (state.value > maximum) {
            state.dispatchRawDelta((maximum - state.value).toFloat())
            pending?.takeIf { it.applied != null }?.applied = state.value
        }
    }
    private fun bounded(delta: Float) = (state.value + delta).coerceIn(0f, maximum.toFloat()) - state.value
    override fun scrollBy(physicalDistance: Float): Float {
        if (closed || !available || !sourceAvailable || !userEnabled || !physicalDistance.isFinite()) return 0f
        motion?.cancel(); pending = null
        val consumed = state.dispatchRawDelta(bounded(if (rtl) -physicalDistance else physicalDistance))
        if (consumed != 0f) invalidate()
        return if (rtl) -consumed else consumed
    }
    override fun fling(physicalVelocity: Float) {
        if (closed || !available || !sourceAvailable || !userEnabled || !physicalVelocity.isFinite()) return
        motion?.cancel(); pending = null; userMotion = true
        motion = scope.launch { state.scroll {
            val original = this
            val boundedScope = object : ScrollScope {
                override fun scrollBy(pixels: Float) = if (userEnabled && sourceAvailable) original.scrollBy(bounded(pixels)) else 0f
            }
            with(flingBehavior) { boundedScope.performFling(if (rtl) -physicalVelocity else physicalVelocity) }
        } }
    }
    override fun cancel() {
        motion?.cancel(); pending = null
        if (!closed) motion = scope.launch { state.scroll(MutatePriority.UserInput) {} }
    }
    fun reveal(rect: RectF, complete: () -> Unit) { beginReveal(rect, complete, null) }
    suspend fun awaitDescendantPlacement() { revealDescendant(null) }
    suspend fun revealDescendant(rect: RectF?) {
        if (closed || !available || !sourceAvailable)
            throw CancellationException("Hidden descendant reveal owner is unavailable")
        suspendCancellableCoroutine<Unit> { continuation ->
            val cancel = beginReveal(rect, { if (continuation.isActive) continuation.resume(Unit) },
                { continuation.cancel(CancellationException("Hidden descendant reveal was replaced")) }, requirePlaced = true)
            continuation.invokeOnCancellation { cancel?.invoke() }
        }
    }
    private fun beginReveal(rect: RectF?, complete: () -> Unit, cancelled: (() -> Unit)?,
        requirePlaced: Boolean = false): (() -> Unit)? {
        if (closed || !available || rect != null && !listOf(rect.left, rect.right).all { it.isFinite() }) { complete(); return null }
        val offset = minOf(state.value.toFloat(), overflow)
        var translation = if (rtl) -overflow + offset else -offset
        if (rect != null && rect.left + paddingLeft + translation < 0f) translation = -rect.left - paddingLeft
        else if (rect != null && rect.right + paddingLeft + translation > viewport) translation = viewport - rect.right - paddingLeft
        translation = translation.coerceIn(-overflow, 0f)
        val desired = if (rtl) overflow + translation else -translation
        val target = if (rect == null) state.value else
            (if (desired >= state.value) ceil(desired).toInt() else floor(desired).toInt()).coerceIn(0, maximum)
        // Detach the previous callback before cancellation can re-enter this owner.
        motion?.cancel(); pending = null
        if (target == state.value && (!requirePlaced || currentPlacement())) { complete(); return null }
        val request = Reveal(if (requirePlaced) lastPlaced?.revision ?: -1L else revision,
            complete, cancelled = cancelled)
        pending = request; userMotion = false
        if (target == state.value) {
            request.applied = state.value
            invalidate()
        } else motion = scope.launch {
            state.scrollTo(target.coerceIn(0, maximum))
            if (pending === request) request.applied = state.value
            invalidate()
        }
        return { if (pending === request) { motion?.cancel(); pending = null } }
    }
    fun measured(): Long { revision++; return revision }
    fun placed(measuredRevision: Long, value: Int, physicalOffset: Float) {
        lastPlaced = Placed(measuredRevision, value, viewport, overflow, paddingLeft, rtl)
        placement = NativePositionedScrollPlacement(viewport, overflow, physicalOffset, userEnabled && available && sourceAvailable)
        bar?.syncOwner()
        val request = pending ?: return
        if (measuredRevision <= request.afterRevision || request.applied != value) return
        // Detach before resuming a descendant, which may begin another reveal.
        request.completed = true
        pending = null; request.complete()
    }
    fun unavailable() { available = false; sourceAvailable = false; motion?.cancel(); pending = null; bar?.syncOwner() }
    fun close() { closed = true; unavailable() }
}

/** A real descendant View/Compose reveal, independent of user scroll affordances. */
private data class NativeHiddenRevealElement(val owner: NativePositionedScrollOwner) :
    ModifierNodeElement<NativeHiddenRevealNode>() {
    override fun create() = NativeHiddenRevealNode(owner)
    override fun update(node: NativeHiddenRevealNode) = node.update(owner)
    override fun InspectorInfo.inspectableProperties() { name = "nativeHiddenDescendantReveal" }
}

private class NativeHiddenRevealNode(private var owner: NativePositionedScrollOwner) :
    Modifier.Node(), BringIntoViewModifierNode, LayoutAwareModifierNode {
    private var placed = false
    override fun onPlaced(coordinates: LayoutCoordinates) { placed = true }
    private val requests = mutableSetOf<Job>()
    private fun cancelRequests() {
        val previous = requests.toList(); requests.clear()
        previous.forEach { it.cancel() }
    }
    fun update(value: NativePositionedScrollOwner) {
        if (owner !== value) { cancelRequests(); owner = value }
    }
    override fun onDetach() { placed = false; cancelRequests() }
    override suspend fun bringIntoView(childCoordinates: LayoutCoordinates, boundsProvider: () -> Rect?) {
        val original = owner
        val job = currentCoroutineContext()[Job] ?: return
        fun currentBounds(): Rect {
            if (!placed || !isAttached || owner !== original || !original.sourceAvailable || !childCoordinates.isAttached)
                throw CancellationException("Hidden descendant reveal owner is unavailable")
            val coordinates = requireLayoutCoordinates()
            val bounds = boundsProvider() ?: throw CancellationException("Hidden descendant reveal target is unavailable")
            val points = listOf(bounds.topLeft, bounds.topRight, bounds.bottomLeft, bounds.bottomRight)
                .map { coordinates.localPositionOf(childCoordinates, it) }
            if (points.any { !it.x.isFinite() || !it.y.isFinite() })
                throw CancellationException("Hidden descendant reveal coordinates are unavailable")
            return Rect(points.minOf { it.x }, points.minOf { it.y }, points.maxOf { it.x }, points.maxOf { it.y })
        }
        cancelRequests()
        requests += job
        try {
            // A prior request can update ScrollState before the child is placed. Do
            // not map old coordinates against that newly selected scroll/range state.
            original.awaitDescendantPlacement()
            val before = currentBounds()
            // The public request is already in placed viewport coordinates. Convert only
            // for the retained owner's content-relative horizontal reveal contract.
            val contentLeft = before.left - original.paddingLeft + original.placement.physicalOffset
            val contentRight = before.right - original.paddingLeft + original.placement.physicalOffset
            original.revealDescendant(RectF(contentLeft, before.top, contentRight, before.bottom))
            currentCoroutineContext().ensureActive()
            // Forward after actual pan placement. Ancestors own vertical/root reveal; a
            // clipped horizontal remainder must not enlarge their own scroll request.
            bringIntoViewParent {
                val fresh = currentBounds()
                val width = requireLayoutCoordinates().size.width.toFloat()
                Rect(fresh.left.coerceIn(0f, width), fresh.top,
                    fresh.right.coerceIn(0f, width), fresh.bottom)
            }
        } finally { requests -= job }
    }
}

/** Platform scrollbar painting only: no source text, focus, hit or AX owner. */
private class NativePositionedScrollBarView(context: Context,
    private val owner: NativePositionedScrollOwner, private val clip: NativeScrollClip) :
    View(context, null, android.R.attr.horizontalScrollViewStyle, android.R.style.Widget_DeviceDefault_HorizontalScrollView) {
    private var coordinates: LayoutCoordinates? = null
    init {
        background = null
        foreground = null
        setPadding(0, 0, 0, 0)
        isHorizontalFadingEdgeEnabled = false
        isVerticalFadingEdgeEnabled = false
        isFocusable = false
        isFocusableInTouchMode = false
        isClickable = false
        isLongClickable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        scrollBarStyle = SCROLLBARS_INSIDE_OVERLAY
        isScrollbarFadingEnabled = false
        isVerticalScrollBarEnabled = false
        setWillNotDraw(false)
    }
    fun syncOwner() { isHorizontalScrollBarEnabled = owner.showsBar; invalidate() }
    fun positioned(value: LayoutCoordinates) { coordinates = value; invalidate() }
    private fun metrics() = nativePositionedScrollbarMetrics(owner.placement.viewport,
        owner.placement.overflow, owner.placement.physicalOffset)
    override fun computeHorizontalScrollExtent() = metrics().extent
    override fun computeHorizontalScrollRange() = metrics().range
    override fun computeHorizontalScrollOffset() = metrics().offset
    override fun dispatchTouchEvent(event: MotionEvent) = false
    override fun onGenericMotionEvent(event: MotionEvent) = false
    override fun draw(canvas: Canvas) {
        if (!owner.showsBar || horizontalScrollbarHeight <= 0) return
        val at = coordinates?.takeIf { it.isAttached && isAttachedToWindow } ?: return
        val source = clip.inScreen()
        if (source.isEmpty) return
        val corners = listOf(Offset(source.left, source.top), Offset(source.right, source.top),
            Offset(source.right, source.bottom), Offset(source.left, source.bottom)).map(at::screenToLocal)
        if (corners.any { !it.x.isFinite() || !it.y.isFinite() }) return
        val saved = canvas.save()
        try {
            canvas.clipRect(corners.minOf { it.x }, corners.minOf { it.y }, corners.maxOf { it.x }, corners.maxOf { it.y })
            // Exact zero range remains zero. Native UA policy determines whether its track
            // is visible; no fabricated thumb, CSS gutter or minimum range is introduced.
            super.draw(canvas)
        } finally { canvas.restoreToCount(saved) }
    }
}

private data object NativePositionedBarSharing : ModifierNodeElement<NativePositionedBarSharingNode>() {
    override fun create() = NativePositionedBarSharingNode()
    override fun update(node: NativePositionedBarSharingNode) = Unit
    override fun InspectorInfo.inspectableProperties() { name = "nativePositionedBarSharing" }
}
private class NativePositionedBarSharingNode : Modifier.Node(), PointerInputModifierNode {
    override fun sharePointerInputWithSiblings() = true
    override fun onPointerEvent(pointerEvent: PointerEvent, pass: PointerEventPass, bounds: IntSize) = Unit
    override fun onCancelPointerInput() = Unit
}

@Composable
private fun NativePositionedScrollBar(owner: NativePositionedScrollOwner, clip: NativeScrollClip) {
    Box(Modifier.then(NativePositionedBarSharing)) {
        key(owner, clip) {
            AndroidView(factory = { NativePositionedScrollBarView(it, owner, clip).also(owner::attach) },
                modifier = Modifier.matchParentSize().onGloballyPositioned { ownerCoordinates ->
                    // Coordinate publication is independent from body layout or scrollbar range.
                    owner.positionedBar(ownerCoordinates)
                }, onReset = null, onRelease = owner::detach, update = { it.syncOwner() })
        }
    }
}

@Composable
private fun NativeOwnedContainerScrollport(spec: NativeScrollportSpec, linkColor: Color,
    parentMeasureInput: NativeLayoutInput<Unit>, child: @Composable (Int, NativeLayoutInput<Int>) -> Unit) {
    val positioned = spec.positioned
    val ordinaryHidden = spec.ordinaryHidden
    val source = positioned?.source ?: checkNotNull(ordinaryHidden).source
    val userEnabled = positioned?.overflowX == PositionedOverflowX.Scroll
    val description = if (positioned != null) "Positioned" else "Hidden"
    val identity = NativePositionedScopeIdentity(source)
    val export = LocalNativeContextMeasureInput.current
    val sourceDirection = LocalLayoutDirection.current
    val rtl = sourceDirection == LayoutDirection.Rtl
    val density = LocalDensity.current
    val environment = NativeFlowEnvironment(density.density, density.fontScale, sourceDirection, LocalWindowInfo.current.containerSize)
    val binding = NativeFlowBinding(environment, NativeTextInsets(), 0f)
    SideEffect { export?.bind(binding) }
    DisposableEffect(export, binding) { onDispose { export?.unbind(binding) } }
    val parentClip = LocalNativeScrollClip.current
    val clip = remember(identity, parentClip) { NativeScrollClip(parentClip) }
    val view = LocalView.current
    val remeasure = remember(identity) { NativeLayoutInput(Unit) }
    val message = remember(identity) { NativeLayoutInput<String?>(null) }
    val inner = remember(identity, export, parentMeasureInput) { NativeContextMeasureInput(export?.semantic) {
        remeasure.invalidate(); parentMeasureInput.invalidate()
    } }
    val ordered = remember(identity) { arrayOfNulls<Pair<NativeFloatContextGeometry, FloatTextGeometry>>(1) }
    val composition = Any()
    val scroll = remember(identity) { ScrollState(0) }
    val scope = rememberCoroutineScope()
    val flingBehavior = ScrollableDefaults.flingBehavior()
    val owner = remember(identity, scroll, scope, flingBehavior, export) {
        NativePositionedScrollOwner(scroll, scope, flingBehavior) {
            remeasure.invalidate(); export?.semantic?.changed(); parentMeasureInput.invalidate()
        }
    }
    val publication = remember(identity, owner) { NativeTableViewportPublication() }
    SideEffect {
        owner.selectUserMode(userEnabled)
        publication.invalidate = { remeasure.invalidate(); export?.semantic?.changed(); parentMeasureInput.invalidate() }
    }
    DisposableEffect(owner, publication) { onDispose { owner.close(); publication.close() } }
    LaunchedEffect(scroll.value) { remeasure.invalidate(); export?.semantic?.changed(); parentMeasureInput.invalidate() }
    val drag = rememberDraggableState { owner.scrollBy(-it) }
    val wheelFactor = remember(view) { android.view.ViewConfiguration.get(view.context).scaledHorizontalScrollFactor }
    val clipHeight = remember(identity) { floatArrayOf(0f) }
    val semanticPan = remember(identity) { arrayOfNulls<Float>(1) }
    // Scroll actions use physical coordinates. The real child keeps its source paragraph direction.
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Layout(modifier = remeasure.modifier.then(export?.measurement?.modifier ?: Modifier).fillMaxWidth()
            .testTag(if (positioned != null) "compiled-positioned-scrollport" else "compiled-hidden-scrollport")
            .then(if (ordinaryHidden != null) NativeHiddenRevealElement(owner) else Modifier).drawWithContent {
                clipRect(0f, 0f, size.width, clipHeight[0]) { this@drawWithContent.drawContent() }
            }.onGloballyPositioned { coordinates ->
                val origin = coordinates.localToWindow(Offset.Zero)
                clip.update(Rect(origin.x, origin.y, origin.x + coordinates.size.width, origin.y + clipHeight[0]), view)
                clip.updateSemanticScroll(coordinates) { semanticPan[0]?.let { Offset(it, 0f) } }
            }.then(if (userEnabled) Modifier
                .draggable(drag, Orientation.Horizontal, startDragImmediately = scroll.isScrollInProgress,
                    onDragStarted = { owner.cancel() }, onDragStopped = { owner.fling(-it) })
                .pointerInput(owner) { awaitPointerEventScope { while (true) {
                    val event = awaitPointerEvent()
                    if (event.type == PointerEventType.Scroll) {
                        val delta = event.changes.sumOf { it.scrollDelta.x.toDouble() }.toFloat() * wheelFactor
                        if (delta != 0f && owner.scrollBy(delta) != 0f) event.changes.forEach { it.consume() }
                    }
                } } }.semantics {
                    horizontalScrollAxisRange = ScrollAxisRange({ owner.placement.physicalOffset }, { owner.placement.overflow }, false)
                    if (owner.placement.overflow > 0f && owner.placement.userEnabled) scrollBy { x, _ -> owner.scrollBy(x) != 0f }
                } else Modifier), content = {
                CompositionLocalProvider(LocalLayoutDirection provides sourceDirection,
                    LocalNativeScrollClip provides clip, LocalNativeContainerScrollport provides true,
                    LocalTableContentWidths provides true, LocalNativeContextMeasureInput provides inner,
                    LocalNativeFlowMeasureInput provides null, LocalNativeContextInteractionOwner provides (export == null),
                    LocalNativeContextContainAtEnd provides true) {
                    NativeFloatContextLayout(spec.parts, Modifier, linkColor, containAtEnd = true, adjoining = true,
                        absoluteScope = positioned != null, onInputGeometry = { raw, input -> ordered[0] = raw to input }, child = child)
                }
                NativeLayoutMessage(message)
                if (positioned != null) NativePositionedScrollBar(owner, clip)
            }, measurePolicy = object : MeasurePolicy {
                override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int): Int {
                    val content = measurables.first().minIntrinsicWidth(height)
                    return if (ordinaryHidden != null) nativeOrdinaryHiddenIntrinsicWidth(content, spec.padding) else content
                }
                override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int): Int {
                    val content = measurables.first().maxIntrinsicWidth(height)
                    return if (ordinaryHidden != null) nativeOrdinaryHiddenIntrinsicWidth(content, spec.padding) else content
                }
                override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                    semanticPan[0] = null
                    val ticket = export?.begin(binding, constraints)
                    val viewport = constraints.maxWidth.takeIf { constraints.hasBoundedWidth && it in 0..TablePixelLimit }
                        ?: throw UnsupportedFloatLayout("$description scrollport requires a bounded containing width")
                    val contentWidth = if (ordinaryHidden != null) nativeOrdinaryHiddenContentWidth(viewport, spec.padding) else viewport
                    val childConstraints = Constraints(minWidth = contentWidth, maxWidth = contentWidth)
                    val request = inner.request(constraints, childConstraints, environment,
                        NativeFlowParentPolicy(composition, true, null, 0f, NativeMarginCollapse(false, false)), emptyList())
                    val body = measurables.first().measure(childConstraints)
                    val measured = inner.measured(request)
                    val raw = measured?.result?.getOrNull()
                    val input = ordered[0]?.takeIf { it.first === raw }?.second
                    var failure = when {
                        export == null || ticket == null -> if (positioned != null) "Positioned scope has no current containing owner"
                            else "Hidden scrollport has no current containing owner"
                        raw == null || input == null -> measured?.result?.exceptionOrNull()?.message ?: "$description body geometry is unavailable"
                        raw.width != body.width || raw.height != body.height -> "$description body measurement changed"
                        else -> null
                    }
                    val retainedBounds = NativeFloatBounds(0f, 0f, contentWidth.toFloat(), body.height.toFloat())
                    val bounds = try { raw?.scrollableBounds ?: measured?.fallbackBounds ?: retainedBounds }
                    catch (error: UnsupportedFloatLayout) {
                        failure = error.message ?: "$description descendant scroll bounds are unavailable"
                        measured?.fallbackBounds ?: retainedBounds
                    } catch (error: IllegalArgumentException) {
                        failure = error.message ?: "$description descendant bounds are unavailable"
                        measured?.fallbackBounds ?: retainedBounds
                    }
                    val allocation = try {
                        if (ordinaryHidden != null) nativeOrdinaryHiddenScrollportAllocation(viewport,
                            raw?.usedHeight ?: body.height.toFloat(), bounds, spec.padding)
                        else nativePositionedScrollportAllocation(viewport, raw?.usedHeight ?: body.height.toFloat(), bounds, spec.padding)
                    } catch (error: UnsupportedFloatLayout) {
                        failure = error.message ?: "$description scroll extent is unavailable"
                        val retainedHeight = nativeFallbackHeight(constraints, body.measuredHeight.toLong())
                        NativeOwnedScrollportAllocation(viewport, retainedHeight, retainedHeight.toFloat(), 0f, 0f, 0f, false, false)
                    } catch (error: IllegalArgumentException) {
                        failure = error.message ?: "$description scroll geometry is unavailable"
                        val retainedHeight = nativeFallbackHeight(constraints, body.measuredHeight.toLong())
                        NativeOwnedScrollportAllocation(viewport, retainedHeight, retainedHeight.toFloat(), 0f, 0f, 0f, false, false)
                    }
                    if (failure == null) failure = when {
                        allocation.verticalOverflow -> "Local vertical overflow is unavailable"
                        allocation.leadingOverflow -> "Leading horizontal overflow is unavailable"
                        else -> null
                    }
                    if (failure == null && nativeFallbackHeight(constraints, allocation.height.toLong()) < allocation.height)
                        failure = "$description viewport exceeds native allocation"
                    message.update(failure?.let { "$description layout unavailable. $it" })
                    val warning = measurables[1].measure(if (failure == null) Constraints.fixed(0, 0) else Constraints(maxWidth = viewport))
                    val bodyHeight = if (failure == null) allocation.usedHeight else maxOf(allocation.usedHeight,
                        bounds.bottom + spec.padding.top, body.measuredHeight + spec.padding.top)
                    val exactHeight = bodyHeight + warning.measuredHeight
                    val allocatedHeight = if (failure == null) allocation.height.toLong() + warning.measuredHeight
                        else ceil(bodyHeight.toDouble() + warning.measuredHeight.toDouble()).toLong()
                    val height = nativeFallbackHeight(constraints, allocatedHeight)
                    clipHeight[0] = minOf(exactHeight, height.toFloat())
                    owner.selectRange(viewport.toFloat(), allocation.overflow, allocation.originX, rtl)
                    owner.available = input != null
                    owner.sourceAvailable = failure == null
                    val bar = measurables.getOrNull(2)?.measure(Constraints.fixed(viewport, height))
                    val offset = minOf(scroll.value.toFloat(), allocation.overflow)
                    val translation = if (rtl) -allocation.overflow + offset else -offset
                    semanticPan[0] = translation
                    val originY = allocation.originY + warning.measuredHeight
                    val rectangle = RectF(0f, 0f, viewport.toFloat(), clipHeight[0])
                    val placement = NativeTableBlockPlacement(rectangle, rectangle, allocation.originX, originY, translation,
                        body.width, body.height, 0, 0, 0f, 0f, viewport, height,
                        owner.takeIf { failure == null && userEnabled && allocation.overflow > 0f }, owner::reveal,
                        unavailable = failure != null, semanticScrollClip = clip)
                    val projected = input?.let { NativeTableViewportGeometry(it, placement, publication::afterPublication) }
                    val geometry = projected?.let { NativeFloatContextGeometry.viewport(it, minOf(exactHeight, height.toFloat())) }
                    val revision = owner.measured()
                    val measuredScroll = scroll.value
                    if (ticket != null && export != null) {
                        val result = if (failure == null && geometry != null) Result.success(geometry)
                            else Result.failure(UnsupportedFloatLayout(failure ?: "$description geometry is unavailable"))
                        val sealed = export.seal(ticket)
                        if (sealed != null) export.publish(sealed, result,
                            geometry?.extents?.ink, geometry.takeIf { result.isFailure })
                    }
                    publication.publish(input, placement.takeIf { geometry != null })
                    return layout(viewport, height) {
                        warning.place(0, 0)
                        val x = allocation.originX + translation
                        val ix = floor(x).toInt(); val iy = floor(originY).toInt()
                        body.placeWithLayer(ix, iy) { translationX = x - ix; translationY = originY - iy }
                        bar?.place(0, 0)
                        owner.placed(revision, measuredScroll, (-translation).coerceIn(0f, allocation.overflow))
                    }
                }
            })
    }
}
