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
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.viewinterop.AndroidView

/** This is a reader capability restriction; stored Auto and its old wire bytes are unchanged. */
internal fun nativeScrollportUnavailable(style: ContainerStyle, flexItem: Boolean = false): String? {
    if (style.overflow != ContainerOverflow.Auto) return null
    val margins = style.marginValues
    val numeric = style.margins?.let { listOf(it.top, it.right, it.bottom, it.left) }.orEmpty()
    return when {
        style.height != null || style.minHeight != null -> "Automatic scrollports require automatic block height"
        flexItem || style.flexItem != null || style.layout == ContainerLayout.FlexRow -> "Automatic scrollports in flex layout are unavailable"
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
internal data class NativeScrollportSpec(val parts: List<NativeFloatContextSpec>, val padding: FloatMargins,
    val positioned: NativePositionedScrollportPolicy? = null)

internal data class NativePositionedScrollportAllocation(val viewport: Int, val height: Int,
    val usedHeight: Float, val overflow: Float, val originX: Float, val originY: Float,
    val verticalOverflow: Boolean, val leadingOverflow: Boolean)

/** The authored padding box keeps its normal-flow height. Descendant overflow adds range,
 * never another contribution to that height. The old Auto allocation remains unchanged. */
internal fun nativePositionedScrollportAllocation(viewport: Int, usedHeight: Float,
    layout: NativeFloatBounds, padding: FloatMargins): NativePositionedScrollportAllocation {
    require(viewport in 0..TablePixelLimit && usedHeight.isFinite() && usedHeight >= 0f)
    require(padding.left == 0f && padding.right == 0f)
    require(listOf(padding.top, padding.bottom).all { it.isFinite() && it >= 0f })
    val height = usedHeight.toDouble() + padding.top.toDouble() + padding.bottom.toDouble()
    val right = layout.right.toDouble() + padding.left.toDouble() + padding.right.toDouble()
    val overflow = (right - viewport).coerceAtLeast(0.0)
    if (!height.isFinite() || height > TablePixelLimit || !overflow.isFinite() || overflow > TablePixelLimit ||
        listOf(layout.left, layout.top, layout.right, layout.bottom).any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Positioned scrollport extent exceeds native geometry")
    return NativePositionedScrollportAllocation(viewport, ceil(height).toInt(), height.toFloat(), overflow.toFloat(),
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
    if (spec.positioned != null) {
        NativePositionedContainerScrollport(spec, linkColor, parentMeasureInput, child)
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
    private data class Reveal(val afterRevision: Long, val complete: () -> Unit, var applied: Int? = null)
    private var pending: Reveal? = null
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
    fun reveal(rect: RectF, complete: () -> Unit) {
        if (closed || !available || !listOf(rect.left, rect.right).all { it.isFinite() }) { complete(); return }
        val offset = minOf(state.value.toFloat(), overflow)
        var translation = if (rtl) -overflow + offset else -offset
        if (rect.left + paddingLeft + translation < 0f) translation = -rect.left - paddingLeft
        else if (rect.right + paddingLeft + translation > viewport) translation = viewport - rect.right - paddingLeft
        translation = translation.coerceIn(-overflow, 0f)
        val desired = if (rtl) overflow + translation else -translation
        val target = (if (desired >= state.value) ceil(desired).toInt() else floor(desired).toInt()).coerceIn(0, maximum)
        if (target == state.value) { complete(); return }
        motion?.cancel()
        val request = Reveal(revision, complete); pending = request; userMotion = false
        motion = scope.launch {
            state.scrollTo(target.coerceIn(0, maximum))
            if (pending === request) request.applied = state.value
            invalidate()
        }
    }
    fun measured(): Long { revision++; return revision }
    fun placed(measuredRevision: Long, value: Int, physicalOffset: Float) {
        placement = NativePositionedScrollPlacement(viewport, overflow, physicalOffset, userEnabled && available && sourceAvailable)
        bar?.syncOwner()
        val request = pending ?: return
        if (measuredRevision <= request.afterRevision || request.applied != value) return
        pending = null; request.complete()
    }
    fun unavailable() { available = false; sourceAvailable = false; motion?.cancel(); pending = null; bar?.syncOwner() }
    fun close() { closed = true; unavailable() }
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
private fun NativePositionedContainerScrollport(spec: NativeScrollportSpec, linkColor: Color,
    parentMeasureInput: NativeLayoutInput<Unit>, child: @Composable (Int, NativeLayoutInput<Int>) -> Unit) {
    val policy = checkNotNull(spec.positioned)
    val identity = NativePositionedScopeIdentity(policy.source)
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
        owner.selectUserMode(policy.overflowX == PositionedOverflowX.Scroll)
        publication.invalidate = { remeasure.invalidate(); export?.semantic?.changed(); parentMeasureInput.invalidate() }
    }
    DisposableEffect(owner, publication) { onDispose { owner.close(); publication.close() } }
    LaunchedEffect(scroll.value) { remeasure.invalidate(); export?.semantic?.changed(); parentMeasureInput.invalidate() }
    val drag = rememberDraggableState { owner.scrollBy(-it) }
    val wheelFactor = remember(view) { android.view.ViewConfiguration.get(view.context).scaledHorizontalScrollFactor }
    val clipHeight = remember(identity) { floatArrayOf(0f) }
    // Scroll actions use physical coordinates. The real child keeps its source paragraph direction.
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Layout(modifier = remeasure.modifier.then(export?.measurement?.modifier ?: Modifier).fillMaxWidth()
            .testTag("compiled-positioned-scrollport").drawWithContent {
                clipRect(0f, 0f, size.width, clipHeight[0]) { this@drawWithContent.drawContent() }
            }.onGloballyPositioned { coordinates ->
                val origin = coordinates.localToWindow(Offset.Zero)
                clip.update(Rect(origin.x, origin.y, origin.x + coordinates.size.width, origin.y + clipHeight[0]), view)
            }.then(if (policy.overflowX == PositionedOverflowX.Scroll) Modifier
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
                        absoluteScope = true, onInputGeometry = { raw, input -> ordered[0] = raw to input }, child = child)
                }
                NativeLayoutMessage(message)
                NativePositionedScrollBar(owner, clip)
            }, measurePolicy = object : MeasurePolicy {
                override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = measurables.first().minIntrinsicWidth(height)
                override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = measurables.first().maxIntrinsicWidth(height)
                override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                    val ticket = export?.begin(binding, constraints)
                    val viewport = constraints.maxWidth.takeIf { constraints.hasBoundedWidth && it in 0..TablePixelLimit }
                        ?: throw UnsupportedFloatLayout("Positioned scrollport requires a bounded containing width")
                    val childConstraints = Constraints(minWidth = viewport, maxWidth = viewport)
                    val request = inner.request(constraints, childConstraints, environment,
                        NativeFlowParentPolicy(composition, true, null, 0f, NativeMarginCollapse(false, false)), emptyList())
                    val body = measurables.first().measure(childConstraints)
                    val measured = inner.measured(request)
                    val raw = measured?.result?.getOrNull()
                    val input = ordered[0]?.takeIf { it.first === raw }?.second
                    var failure = when {
                        export == null || ticket == null -> "Positioned scope has no current containing owner"
                        raw == null || input == null -> measured?.result?.exceptionOrNull()?.message ?: "Positioned body geometry is unavailable"
                        raw.width != body.width || raw.height != body.height -> "Positioned body measurement changed"
                        else -> null
                    }
                    val retainedBounds = NativeFloatBounds(0f, 0f, viewport.toFloat(), body.height.toFloat())
                    val bounds = try { raw?.scrollableBounds ?: measured?.fallbackBounds ?: retainedBounds }
                    catch (error: UnsupportedFloatLayout) {
                        failure = error.message ?: "Positioned descendant scroll bounds are unavailable"
                        measured?.fallbackBounds ?: retainedBounds
                    } catch (error: IllegalArgumentException) {
                        failure = error.message ?: "Positioned descendant bounds are unavailable"
                        measured?.fallbackBounds ?: retainedBounds
                    }
                    val allocation = try {
                        nativePositionedScrollportAllocation(viewport, raw?.usedHeight ?: body.height.toFloat(), bounds, spec.padding)
                    } catch (error: UnsupportedFloatLayout) {
                        failure = error.message ?: "Positioned scroll extent is unavailable"
                        val retainedHeight = nativeFallbackHeight(constraints, body.measuredHeight.toLong())
                        NativePositionedScrollportAllocation(viewport, retainedHeight, retainedHeight.toFloat(), 0f, 0f, 0f, false, false)
                    } catch (error: IllegalArgumentException) {
                        failure = error.message ?: "Positioned scroll geometry is unavailable"
                        val retainedHeight = nativeFallbackHeight(constraints, body.measuredHeight.toLong())
                        NativePositionedScrollportAllocation(viewport, retainedHeight, retainedHeight.toFloat(), 0f, 0f, 0f, false, false)
                    }
                    if (failure == null) failure = when {
                        allocation.verticalOverflow -> "Local vertical overflow is unavailable"
                        allocation.leadingOverflow -> "Leading horizontal overflow is unavailable"
                        else -> null
                    }
                    if (failure == null && nativeFallbackHeight(constraints, allocation.height.toLong()) < allocation.height)
                        failure = "Positioned viewport exceeds native allocation"
                    message.update(failure?.let { "Positioned layout unavailable. $it" })
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
                    val bar = measurables[2].measure(Constraints.fixed(viewport, height))
                    val offset = minOf(scroll.value.toFloat(), allocation.overflow)
                    val translation = if (rtl) -allocation.overflow + offset else -offset
                    val originY = allocation.originY + warning.measuredHeight
                    val rectangle = RectF(0f, 0f, viewport.toFloat(), clipHeight[0])
                    val placement = NativeTableBlockPlacement(rectangle, rectangle, allocation.originX, originY, translation,
                        viewport, body.height, 0, 0, 0f, 0f, viewport, height,
                        owner.takeIf { failure == null && policy.overflowX == PositionedOverflowX.Scroll && allocation.overflow > 0f }, owner::reveal,
                        unavailable = failure != null)
                    val projected = input?.let { NativeTableViewportGeometry(it, placement, publication::afterPublication) }
                    val geometry = projected?.let { NativeFloatContextGeometry.viewport(it, minOf(exactHeight, height.toFloat())) }
                    val revision = owner.measured()
                    val measuredScroll = scroll.value
                    if (ticket != null && export != null) {
                        val result = if (failure == null && geometry != null) Result.success(geometry)
                            else Result.failure(UnsupportedFloatLayout(failure ?: "Positioned geometry is unavailable"))
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
                        bar.place(0, 0)
                        owner.placed(revision, measuredScroll, (-translation).coerceIn(0f, allocation.overflow))
                    }
                }
            })
    }
}
