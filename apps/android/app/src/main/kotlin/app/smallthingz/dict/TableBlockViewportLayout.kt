package app.smallthingz.dict

import android.graphics.RectF
import androidx.compose.foundation.MutatePriority
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.gestures.FlingBehavior
import androidx.compose.foundation.gestures.ScrollableDefaults
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.ScrollScope
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.LayoutModifier
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.invalidateDraw
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.LayoutDirection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.ceil
import kotlin.math.floor

/** Source block geometry is independent from the anonymous grid's intrinsic width. */
internal data class NativeTableBlockBox(
    val policy: TableBlockViewport,
    val borderWidth: Float,
    val contentWidth: Float,
    val insets: FloatMargins,
    val margins: NativeTableAutoMargins?,
    val fixedMargins: FloatMargins,
    val containingDirection: TableContainingDirection,
    val usedMargins: NativeTableUsedMargins,
    val decoration: NativeContainerDecoration,
    val floatPolicy: TableFloatViewport? = null,
) {
    init {
        require((margins == null) == (floatPolicy != null))
        require(margins == null || fixedMargins == margins.fixed)
        require(listOf(borderWidth, contentWidth, insets.top, insets.right, insets.bottom, insets.left)
            .all { it.isFinite() && it in 0f..TablePixelLimit.toFloat() })
        require(kotlin.math.abs(borderWidth.toDouble() - contentWidth - insets.left - insets.right) <=
            maxOf(.001, Math.ulp(borderWidth).toDouble() * 4))
    }

    fun paddingBounds(border: NativeFloatBounds): NativeFloatBounds {
        val edges = decoration.edges
        val top = border.top + (edges?.get(0)?.width ?: decoration.borderWidth)
        val left = border.left + (edges?.get(3)?.width ?: decoration.borderWidth)
        return NativeFloatBounds(left, top,
            maxOf(left, border.right - (edges?.get(1)?.width ?: decoration.borderWidth)),
            maxOf(top, border.bottom - (edges?.get(2)?.width ?: decoration.borderWidth)))
    }

    // An unbounded maximum is a sentinel, not an edge-adjustable pixel length.
    fun contentMaxHeight(constraints: Constraints): Int = if (!constraints.hasBoundedHeight) Constraints.Infinity
        else (constraints.maxHeight - ceil(insets.top.toDouble() + insets.bottom).toInt()).coerceAtLeast(0)
}

/** The Q source overflow edge is independent of the unchanged child layout/pan origin. */
internal fun tableBlockOverflowBounds(policy: TableBlockViewport, content: NativeFloatBounds,
    corners: NativeTableCornerShape?, padding: NativeFloatBounds? = null): NativeFloatBounds {
    if (policy.intrinsicContainingDirection != null)
        return padding ?: throw UnsupportedFloatLayout("Intrinsic table padding clip is unavailable")
    if (!policy.isSeparateCornerGrid) return content
    val shape = corners ?: throw UnsupportedFloatLayout("Corner-table overflow shape is unavailable")
    return shape.paddingBox ?: NativeFloatBounds(content.left, content.top, content.left, content.top)
}

private fun tableBlockContainerStyle(policy: TableBlockViewport, intrinsic: Boolean = false,
    paired: Boolean = false): ContainerViewportStyle {
    val source = policy.boxStyle
    fun edge(value: StyleBorderEdge): ContainerBorderEdge = when (value) {
        StyleBorderEdge.None -> ContainerBorderEdge.None
        StyleBorderEdge.Hidden -> ContainerBorderEdge.Hidden
        is StyleBorderEdge.Solid -> ContainerBorderEdge.Solid(value.width, ContainerColor.Rgb(value.color))
        is StyleBorderEdge.Dotted -> ContainerBorderEdge.Dotted(value.width, ContainerColor.Rgb(value.color))
    }
    val border = when (val value = source.border) {
        null, StyleBorder.None -> ContainerBorder.None
        is StyleBorder.Solid -> ContainerBorder.Solid(value.width, ContainerColor.Rgb(value.color))
        is StyleBorder.Edges -> ContainerBorder.Edges(edge(value.top), edge(value.right), edge(value.bottom), edge(value.left))
    }
    val width = source.width
    val fitContent = paired || policy.intrinsicContainingDirection != null
    val margins = if (fitContent || policy.isSeparateCornerGrid) checkNotNull(source.margins).let { values -> ContainerMargins(
        ContainerMargin.Length(values.top), ContainerMargin.Length(values.right),
        ContainerMargin.Length(values.bottom), ContainerMargin.Length(values.left)) } else source.marginValues
    return ContainerViewportStyle(ContainerStyle(padding = source.padding,
        width = if (fitContent) ContainerWidth.FitContent else if (intrinsic && checkNotNull(width).unit == StyleWidthUnit.Percent)
            ContainerWidth.Auto else ContainerWidth.Length(checkNotNull(width)),
        maxWidth = if (intrinsic && policy.maxWidth.unit == StyleWidthUnit.Percent) ContainerMaxWidth.None
            else ContainerMaxWidth.Length(policy.maxWidth), boxSizing = policy.boxSizing, border = border), margins)
}

internal fun resolveTableBlockBox(policy: TableBlockViewport, containingWidth: Float,
    density: Float, normalBodyPixels: Float): NativeTableBlockBox {
    require(policy.intrinsicContainingDirection == null) { "Intrinsic table requires its real grid width range" }
    return resolveTableBlockBox(policy, null, containingWidth, containingWidth, ContainerWidths(0f, 0f), density, normalBodyPixels)
}

/** Fit-content consumes the assigned interval; percentage caps retain their containing-block basis. */
internal fun resolvePairedTableBlockBox(policy: TableBlockViewport, floatPolicy: TableFloatViewport,
    containingWidth: Float, assignedWidth: Float, intrinsic: ContainerWidths,
    density: Float, normalBodyPixels: Float): NativeTableBlockBox {
    require(policy.boxStyle.width == null && policy.boxStyle.margins != null && policy.boxStyle.marginValues == null &&
        policy.boxStyle.containingDirection == null && policy.focusPaint != null && floatPolicy.narrowClear == null &&
        policy.maxViewportWidthPx == floatPolicy.maxViewportWidthPx && policy.gridDirection == floatPolicy.gridDirection &&
        policy.language == floatPolicy.language) { "Paired table block policy is inconsistent" }
    require(intrinsic.maximum <= TablePixelLimit)
    return resolveTableBlockBox(policy, floatPolicy, containingWidth, assignedWidth, intrinsic, density, normalBodyPixels)
}

/** The nonfloating family uses the same fit-content scalar, without a float capability. */
internal fun resolveIntrinsicTableBlockBox(policy: TableBlockViewport, containingWidth: Float,
    assignedWidth: Float, intrinsic: ContainerWidths, density: Float, normalBodyPixels: Float): NativeTableBlockBox {
    require(policy.intrinsicContainingDirection != null && policy.boxStyle.width == null &&
        policy.boxStyle.margins != null && policy.boxStyle.marginValues == null &&
        policy.boxStyle.containingDirection == null && policy.focusPaint != null)
    require(intrinsic.maximum <= TablePixelLimit)
    return resolveTableBlockBox(policy, null, containingWidth, assignedWidth, intrinsic, density, normalBodyPixels)
}

/** Actual grid tracks are integral pixels; C/F and external margins remain physical floats. */
internal fun intrinsicTableGridWidth(available: Float, intrinsic: ContainerWidths): Int {
    if (!available.isFinite() || available < 0f || intrinsic.maximum > TablePixelLimit ||
        intrinsic.minimum != floor(intrinsic.minimum) || intrinsic.maximum != floor(intrinsic.maximum))
        throw UnsupportedFloatLayout("Intrinsic table grid width is unavailable")
    return maxOf(intrinsic.minimum.toInt(), minOf(intrinsic.maximum.toInt(), floor(available).toInt()))
}

private fun resolveTableBlockBox(policy: TableBlockViewport, floatPolicy: TableFloatViewport?,
    containingWidth: Float, assignedWidth: Float, intrinsic: ContainerWidths,
    density: Float, normalBodyPixels: Float): NativeTableBlockBox {
    require(containingWidth.isFinite() && containingWidth in 0f..TablePixelLimit.toFloat())
    require(assignedWidth.isFinite() && assignedWidth in 0f..containingWidth)
    require(density.isFinite() && density > 0f && normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
    val source = policy.boxStyle
    val corners = source.cornerRadii?.let {
        require(source.collapse == null && (source.border == StyleBorder.None || source.border is StyleBorder.Solid)) {
            "Authored table corner geometry is unavailable for this block border model"
        }
        nativeTableCornerRadii(it, density)
    }
    fun length(value: StyleLength): Float {
        val result = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density else normalBodyPixels
        if (!result.isFinite() || result !in 0.0..TablePixelLimit.toDouble())
            throw UnsupportedFloatLayout("Table block edge exceeds native geometry")
        return result.toFloat()
    }
    val resolved = tableBlockContainerStyle(policy, paired = floatPolicy != null)
    val sides = resolved.box.border.physicalEdges()
    val edges = listOf(sides.top, sides.right, sides.bottom, sides.left)
    val borderWidths = edges.map { it.usedWidth?.let(::length) ?: 0f }
    val padding = source.padding
    val insets = FloatMargins((padding?.top?.let(::length) ?: 0f) + borderWidths[0],
        (padding?.right?.let(::length) ?: 0f) + borderWidths[1],
        (padding?.bottom?.let(::length) ?: 0f) + borderWidths[2],
        (padding?.left?.let(::length) ?: 0f) + borderWidths[3])
    val direction = policy.intrinsicContainingDirection ?: floatPolicy?.containingDirection ?: checkNotNull(source.containingDirection)
    val margins = if (policy.isSeparateCornerGrid || policy.intrinsicContainingDirection != null) NativeTableAutoMargins(
        resolveTableFixedMargins(checkNotNull(source.margins), density, normalBodyPixels), false, false)
        else if (floatPolicy == null) resolveTableAutoMargins(checkNotNull(source.marginValues), density, normalBodyPixels) else null
    val fixed = margins?.fixed ?: resolveTableFixedMargins(checkNotNull(source.margins), density, normalBodyPixels)
    // The same scalar owns fit-content, source edges, caps and physical residuals once.
    val used = containerBoxWidth(resolved, assignedWidth, intrinsic, density,
        normalBodyPixels, rtl = direction == TableContainingDirection.Rtl, percentageReferenceWidth = containingWidth)
    val paintEdges = edges.mapIndexed { index, value ->
        val color = when (value) {
            is ContainerBorderEdge.Solid -> (value.color as ContainerColor.Rgb).value
            is ContainerBorderEdge.Dotted -> (value.color as ContainerColor.Rgb).value
            else -> null
        }
        NativeContainerPaintEdge(borderWidths[index], canonicalColorArgb(color)?.toInt(), value is ContainerBorderEdge.Dotted)
    }
    return NativeTableBlockBox(policy, used.borderBox, used.content, insets, margins, fixed, direction,
        NativeTableUsedMargins(fixed.top, used.marginRight, fixed.bottom, used.marginLeft),
        NativeContainerDecoration(canonicalColorArgb(source.background)?.toInt(), null, 0f, paintEdges, nativeCorners = corners), floatPolicy)
}

/** Cyclic preferred/max percentages take their initial value only for intrinsic contribution.
 * The later definite containing width still resolves the original source percentages once. */
internal fun tableBlockIntrinsicWidth(policy: TableBlockViewport, innerWidth: Int,
    density: Float, normalBodyPixels: Float, floatPolicy: TableFloatViewport? = null): Int {
    if (innerWidth !in 0..TablePixelLimit) return Constraints.Infinity
    val resolved = tableBlockContainerStyle(policy, intrinsic = true, paired = floatPolicy != null)
    val used = containerBoxWidth(resolved, 0f, ContainerWidths(innerWidth.toFloat(), innerWidth.toFloat()),
        density, normalBodyPixels, flexItem = true,
        rtl = (policy.intrinsicContainingDirection ?: floatPolicy?.containingDirection ?: policy.boxStyle.containingDirection) == TableContainingDirection.Rtl)
    val width = used.borderBox.toDouble() + used.marginLeft + used.marginRight
    return if (!width.isFinite() || width > TablePixelLimit) Constraints.Infinity else ceil(width).toInt()
}

internal fun placeStandaloneTableBlock(box: NativeTableBlockBox, containingWidth: Float,
    borderHeight: Float, exclusions: List<NativeFloatExclusion>): NativeAutoMarginTablePlacement {
    require(borderHeight.isFinite() && borderHeight in 0f..TablePixelLimit.toFloat())
    if (box.floatPolicy != null) throw UnsupportedFloatLayout("Paired table requires its native parent allocation")
    return placeNativeAutoMarginTable(containingWidth, 0f, exclusions, checkNotNull(box.margins), box.containingDirection,
        NativeBlockWidth.FixedPx(box.borderWidth), box.policy.boxStyle.clear) {
        NativeBlockMeasure(box.borderWidth, box.borderWidth, borderHeight)
    }
}

internal data class NativeTableBlockScrollGeometry(val viewportPixels: Int, val surfaceWidth: Int,
    val overflow: Float, val physicalTranslation: Float, val childTranslation: Float, val alignment: Float)

/** Compose scroll ranges are integral; the last step still reaches the exact source clip edge. */
internal fun tableBlockScrollGeometry(contentWidth: Float, gridWidth: Int, scrollValue: Int,
    rtl: Boolean): NativeTableBlockScrollGeometry {
    require(contentWidth.isFinite() && contentWidth in 0f..TablePixelLimit.toFloat())
    require(gridWidth in 0..TablePixelLimit && scrollValue >= 0)
    val viewport = ceil(contentWidth).toInt()
    val overflow = (gridWidth - contentWidth).coerceAtLeast(0f)
    val range = ceil(overflow).toInt()
    val surface = viewport.toLong() + range
    if (surface > TablePixelLimit) throw UnsupportedFloatLayout("Table scroll surface exceeds native geometry")
    val position = scrollValue.coerceAtMost(range).toFloat()
    val exact = minOf(position, overflow)
    val alignment = if (rtl) (contentWidth - gridWidth).coerceAtLeast(0f) else 0f
    val physical = if (rtl) -overflow + exact else -exact
    val correction = if (rtl) range - overflow + exact - position + alignment else position - exact
    return NativeTableBlockScrollGeometry(viewport, surface.toInt(), overflow, physical, correction, alignment)
}

internal fun tableBlockRevealValue(contentWidth: Float, gridWidth: Int, scrollValue: Int,
    rtl: Boolean, left: Float, right: Float): Int {
    require(left.isFinite() && right.isFinite() && right >= left)
    val current = tableBlockScrollGeometry(contentWidth, gridWidth, scrollValue, rtl)
    var translation = current.physicalTranslation
    if (left + translation < 0f) translation = -left
    else if (right + translation > contentWidth) translation = contentWidth - right
    translation = translation.coerceIn(-current.overflow, 0f)
    val requested = if (rtl) current.overflow + translation else -translation
    val rounded = if (requested >= scrollValue) ceil(requested).toInt() else floor(requested).toInt()
    return rounded.coerceIn(0, ceil(current.overflow).toInt())
}

internal data class NativeTableBlockPlacement(
    val borderBox: RectF,
    val contentClip: RectF,
    val contentX: Float,
    val contentY: Float,
    val physicalScrollX: Float,
    val gridWidth: Int,
    val gridHeight: Int,
    val captionWidth: Int,
    val captionHeight: Int,
    val captionY: Float,
    val gridY: Float,
    val ownerWidth: Int,
    val ownerHeight: Int,
    val scrollTarget: NativeHorizontalScrollTarget?,
    val revealContentRect: (RectF, () -> Unit) -> Unit,
    val unavailable: Boolean = false,
    val clipped: Boolean = true,
    val cornerClip: NativeTableCornerShape? = null,
)

private class TableBlockScrollOwner(private val state: ScrollState, private val scope: CoroutineScope,
    private val flingBehavior: FlingBehavior, private val manualRange: Boolean = false,
    private val invalidate: () -> Unit) : NativeHorizontalScrollTarget {
    var contentWidth = 0f
    var gridWidth = 0
    var rtl = false
    var active = true
    private var motion: Job? = null
    private var closed = false
    private var maximum = 0
    private data class Reveal(val afterRevision: Long, val completed: () -> Unit, var appliedValue: Int? = null)
    private var reveal: Reveal? = null
    private var measuredRevision = 0L

    private fun boundedDelta(delta: Float): Float = if (!manualRange) delta else
        (state.value.toFloat() + delta).coerceIn(0f, maximum.toFloat()) - state.value
    fun updateRange(value: Int) {
        if (!manualRange) return
        maximum = value
        if (state.value > value) state.dispatchRawDelta((value - state.value).toFloat())
    }
    override fun scrollBy(physicalDistance: Float): Float {
        if (closed || !active || !physicalDistance.isFinite()) return 0f
        motion?.cancel()
        reveal = null
        val used = state.dispatchRawDelta(boundedDelta(if (rtl) -physicalDistance else physicalDistance))
        if (used != 0f) invalidate()
        return if (rtl) -used else used
    }
    override fun fling(physicalVelocity: Float) {
        if (closed || !active || !physicalVelocity.isFinite()) return
        motion?.cancel()
        reveal = null
        motion = scope.launch {
            state.scroll {
                val original = this
                val target = if (!manualRange) original else object : ScrollScope {
                    override fun scrollBy(pixels: Float): Float = original.scrollBy(boundedDelta(pixels))
                }
                with(flingBehavior) { target.performFling(if (rtl) -physicalVelocity else physicalVelocity) }
            }
        }
    }
    override fun cancel() {
        if (closed) return
        motion?.cancel()
        reveal = null
        motion = scope.launch { state.scroll(MutatePriority.UserInput) {} }
    }
    fun reveal(rect: RectF, completed: () -> Unit) {
        if (closed || !active) { completed(); return }
        val target = tableBlockRevealValue(contentWidth, gridWidth, state.value, rtl, rect.left, rect.right)
        if (target == state.value) { completed(); return }
        motion?.cancel()
        val request = Reveal(measuredRevision, completed)
        reveal = request
        motion = scope.launch {
            state.scrollTo(target)
            if (reveal === request) request.appliedValue = state.value
            invalidate()
        }
    }
    fun measured(): Long { measuredRevision++; return measuredRevision }
    fun placed(revision: Long, scrollValue: Int) {
        if (closed) return
        val request = reveal ?: return
        if (revision <= request.afterRevision || request.appliedValue != scrollValue) return
        reveal = null
        request.completed()
    }
    fun cancelPending() { motion?.cancel(); reveal = null }
    fun detached() { closed = true; cancelPending() }
}

/** Paired source TABLE focus owns AX/keyboard; this modifier supplies only the existing integral scroll mechanics. */
private class PairedTableScrollLayout(private val state: ScrollState, private val owner: TableBlockScrollOwner) : LayoutModifier {
    override fun MeasureScope.measure(measurable: Measurable, constraints: Constraints): MeasureResult {
        if (!constraints.hasBoundedWidth) throw UnsupportedFloatLayout("Paired table scroll viewport must be bounded")
        val child = measurable.measure(constraints.copy(maxWidth = Constraints.Infinity))
        val width = child.width.coerceIn(constraints.minWidth, constraints.maxWidth)
        val height = child.height.coerceIn(constraints.minHeight, constraints.maxHeight)
        val range = (child.width - width).coerceAtLeast(0)
        owner.updateRange(range)
        return layout(width, height) { child.placeRelativeWithLayer(-state.value.coerceIn(0, range), 0) }
    }
    override fun IntrinsicMeasureScope.minIntrinsicWidth(measurable: IntrinsicMeasurable, height: Int) = measurable.minIntrinsicWidth(height)
    override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurable: IntrinsicMeasurable, height: Int) = measurable.maxIntrinsicWidth(height)
    override fun IntrinsicMeasureScope.minIntrinsicHeight(measurable: IntrinsicMeasurable, width: Int) = measurable.minIntrinsicHeight(width)
    override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurable: IntrinsicMeasurable, width: Int) = measurable.maxIntrinsicHeight(width)
}

private fun MeasurePolicy.withPairedHeight(enabled: Boolean,
    height: (List<IntrinsicMeasurable>, Int) -> Int): MeasurePolicy {
    if (!enabled) return this
    val source = this
    return object : MeasurePolicy by source {
        override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) = height(measurables, width)
        override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) = height(measurables, width)
    }
}

private data class TableBlockSurfaceRequest(val contentWidth: Float, val maxHeight: Int,
    val widthReference: Int = floor(contentWidth).toInt(), val clipped: Boolean = true)
private data class TableBlockSurfaceMeasurement(val gridWidth: Int, val gridHeight: Int,
    val captionWidth: Int, val captionHeight: Int, val gridY: Int, val height: Int,
    val extentWidth: Int, val request: TableBlockSurfaceRequest, val failure: String?)

internal val LocalPairedTableIntrinsicHeight = staticCompositionLocalOf { false }

internal val LocalTableBlockLayoutFailure = staticCompositionLocalOf<NativeLayoutInput<String?>?> { null }

/** Measurement publishes only final paint inputs. Draw invalidation cannot request layout. */
private class TableBlockDrawPublication {
    var decoration: Pair<NativeContainerDecoration, RectF>? = null
        private set
    data class Clip(val content: RectF?, val overflow: RectF?, val precise: NativeTextClip?)
    var clip = Clip(null, null, null)
        private set
    private var outerNode: TableBlockDrawNode? = null
    private var clipNode: TableBlockDrawNode? = null
    val outerModifier: Modifier = TableBlockDrawElement(this, false)
    val clipModifier: Modifier = TableBlockDrawElement(this, true)

    fun publish(painted: Pair<NativeContainerDecoration, RectF>?, content: RectF?,
        overflow: RectF?, precise: NativeTextClip?) {
        val nextDecoration = painted?.let { it.first to RectF(it.second) }
        val nextClip = Clip(content?.let(::RectF), overflow?.let(::RectF), precise)
        val decorationChanged = decoration != nextDecoration
        val clipChanged = clip != nextClip
        decoration = nextDecoration
        clip = nextClip
        if (decorationChanged) outerNode?.invalidateDraw()
        if (clipChanged) clipNode?.invalidateDraw()
    }

    fun attach(node: TableBlockDrawNode, clipsContent: Boolean) {
        if (clipsContent) clipNode = node else outerNode = node
        node.invalidateDraw()
    }
    fun detach(node: TableBlockDrawNode, clipsContent: Boolean) {
        if (clipsContent) { if (clipNode === node) clipNode = null }
        else if (outerNode === node) outerNode = null
    }
}

private data class TableBlockDrawElement(val publication: TableBlockDrawPublication,
    val clipsContent: Boolean) : ModifierNodeElement<TableBlockDrawNode>() {
    override fun create() = TableBlockDrawNode(publication, clipsContent)
    override fun update(node: TableBlockDrawNode) = node.update(publication, clipsContent)
}

private class TableBlockDrawNode(private var publication: TableBlockDrawPublication,
    private var clipsContent: Boolean) : Modifier.Node(), DrawModifierNode {
    override fun onAttach() = publication.attach(this, clipsContent)
    override fun onDetach() = publication.detach(this, clipsContent)
    fun update(next: TableBlockDrawPublication, nextClipsContent: Boolean) {
        if (publication === next && clipsContent == nextClipsContent) return
        if (isAttached) publication.detach(this, clipsContent)
        publication = next
        clipsContent = nextClipsContent
        if (isAttached) publication.attach(this, clipsContent)
    }
    override fun ContentDrawScope.draw() {
        if (!clipsContent) {
            publication.decoration?.let { (decoration, bounds) -> decoration.paint(drawContext.canvas.nativeCanvas, bounds) }
            drawContent()
            return
        }
        val (rect, overflow, precise) = publication.clip
        if (rect != null && precise != null) {
            val canvas = drawContext.canvas.nativeCanvas
            val checkpoint = canvas.save()
            try {
                canvas.translate(-rect.left, -rect.top)
                precise.clip(canvas)
                canvas.translate(rect.left, rect.top)
                drawContent()
            } finally { canvas.restoreToCount(checkpoint) }
        } else if (rect != null) {
            if (overflow == null) clipRect(0f, 0f, rect.width(), rect.height()) { this@draw.drawContent() }
            else clipRect(overflow.left - rect.left, overflow.top - rect.top,
                overflow.right - rect.left, overflow.bottom - rect.top) { this@draw.drawContent() }
        }
    }
}

/** One real caption/grid surface inside the source Table's independently sized block box. */
@Composable
internal fun TableBlockViewportBox(table: Table, policy: TableBlockViewport,
    captionMinimum: NativeLayoutInput<Int>, hasCaption: Boolean, spacing: Int, narrow: Boolean = true,
    onPlacement: ((NativeTableBlockPlacement) -> String?)? = null, onUnavailable: () -> Unit = {},
    content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val normalBodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val input = LocalNativeTableMarginMeasureInput.current?.takeIf { it.table === table }
    val floatPolicy = table.floatViewport
    val intrinsicTable = policy.intrinsicContainingDirection != null
    val needsHeightIntrinsics = floatPolicy != null || intrinsicTable
    val focusOwner = if (needsHeightIntrinsics || policy.isSeparateCornerGrid) rememberNativeTableScrollFocusOwner(table) else null
    val focusGrid = if (focusOwner != null) remember(NativeDelegatedTableIdentity(table)) { tableGrid(table) } else null
    val captionInput = LocalStaticCaptionInput.current.takeIf { input == null }
    val binding = remember(NativeDelegatedTableIdentity(table), policy, hasCaption, spacing) { Any() }
    SideEffect { input?.bind(binding) }
    DisposableEffect(input, binding) { onDispose { input?.unbind(binding) } }
    val parentClip = LocalNativeScrollClip.current
    val parentScrollport = LocalNativeContainerScrollport.current
    val clip = remember(parentClip) { NativeScrollClip(parentClip) }
    val view = LocalView.current
    val semantic = rememberNativeSemanticMeasurement()
    val inheritedBackground = LocalAuthoredBackground.current
    val remeasure = remember { NativeLayoutInput(Unit) }
    val surfaceRequest = remember { NativeLayoutInput<TableBlockSurfaceRequest?>(null) }
    val widthInput = remember { NativeLayoutInput(0) }
    val measured = remember { arrayOfNulls<TableBlockSurfaceMeasurement>(1) }
    val painted = remember { arrayOfNulls<Pair<NativeContainerDecoration, RectF>>(1) }
    val drawPublication = remember { TableBlockDrawPublication() }
    val contentClip = remember { arrayOfNulls<RectF>(1) }
    val overflowClip = remember { arrayOfNulls<RectF>(1) }
    val preciseContentClip = remember { arrayOfNulls<NativeTextClip>(1) }
    val unavailable = remember(binding) { booleanArrayOf(false) }
    val message = remember { NativeLayoutInput<String?>(null) }
    val contentFailure = remember { NativeLayoutInput<String?>(null) }
    val scroll = remember(binding) { ScrollState(0) }
    val scope = rememberCoroutineScope()
    val flingBehavior = ScrollableDefaults.flingBehavior()
    val scrollOwner = remember(binding, scroll, scope, flingBehavior, semantic) {
        TableBlockScrollOwner(scroll, scope, flingBehavior, manualRange = focusOwner != null) { remeasure.invalidate(); semantic.changed() }
    }
    DisposableEffect(binding, scrollOwner) { onDispose { scrollOwner.detached() } }
    SideEffect { scrollOwner.active = narrow; if (!narrow) scrollOwner.cancelPending() }
    LaunchedEffect(scroll.value) { remeasure.invalidate(); semantic.changed() }
    val pairedScrollLayout = remember(scroll, scrollOwner) { PairedTableScrollLayout(scroll, scrollOwner) }
    val drag = rememberDraggableState { scrollOwner.scrollBy(-it) }
    val rtl = policy.gridDirection == TableContainingDirection.Rtl
    val direction = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr

    // The source scroll axis is physical. The body provider below restores the independently
    // compiled grid direction, including the relative placement used by its scroll surface.
    CompositionLocalProvider(LocalLayoutDirection provides (if (focusOwner != null) LayoutDirection.Ltr else LocalLayoutDirection.current)) {
    Layout(modifier = semantic.modifier.then(remeasure.modifier).then(input?.modifier ?: Modifier)
        .then(captionInput?.modifier ?: Modifier)
        .then(if (focusOwner != null) Modifier.nativeTableScrollFocusSemantics(focusOwner,
            checkNotNull(focusGrid).rows, focusGrid.columns)
            else if (input != null) Modifier.testTag("compiled-table-block-viewport") else Modifier)
        .then(drawPublication.outerModifier), content = {
        CompositionLocalProvider(LocalLayoutDirection provides direction,
            LocalNativeSemanticMeasurement provides semantic,
            LocalNativeScrollClip provides (if (narrow) clip else parentClip),
            LocalNativeContainerScrollport provides (narrow || parentScrollport),
            LocalNativeFractionalTableCoordinates provides (LocalNativeFractionalTableCoordinates.current ||
                narrow && policy.boxStyle.cornerRadii != null),
            LocalTableBlockLayoutFailure provides contentFailure,
            LocalPairedTableIntrinsicHeight provides needsHeightIntrinsics,
            LocalAuthoredBackground provides ((if (narrow) policy.boxStyle.background else table.style?.background) ?: inheritedBackground),
            LocalNativeTableMarginMeasureInput provides null, LocalFloatTableWidthReference provides widthInput,
            LocalFloatMarginsConsumed provides false, LocalNativeContextMeasureInput provides null,
            LocalNativeFlowMeasureInput provides null, LocalStaticCaptionInput provides null,
            LocalNativeContextContainAtEnd provides true) {
            Layout(modifier = surfaceRequest.modifier.testTag("compiled-table-block-content").then(if (narrow) drawPublication.clipModifier.onGloballyPositioned { coordinates ->
                val origin = coordinates.localToWindow(Offset.Zero)
                val rect = contentClip[0]
                if (rect != null) {
                    val overflow = overflowClip[0]
                    val bounds = if (overflow == null) Rect(origin.x, origin.y,
                        origin.x + rect.width(), origin.y + rect.height()) else Rect(
                        origin.x + (overflow.left - rect.left), origin.y + (overflow.top - rect.top),
                        origin.x + (overflow.right - rect.left), origin.y + (overflow.bottom - rect.top))
                    clip.update(bounds, view,
                        preciseContentClip[0]?.translated(origin.x - rect.left, origin.y - rect.top))
                }
            }.then(if (focusOwner == null) Modifier.horizontalScroll(scroll) else
                Modifier.draggable(drag, Orientation.Horizontal, startDragImmediately = scroll.isScrollInProgress,
                    onDragStarted = { scrollOwner.cancel() }, onDragStopped = { scrollOwner.fling(-it) })
                    .then(pairedScrollLayout)) else Modifier), content = content, measurePolicy = object : MeasurePolicy {
                private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
                    val grid = measurables.getOrNull(if (hasCaption) 1 else 0) ?: return 0
                    // An ordinary table uses caption MIN as its grid floor. With no grid,
                    // the caption itself supplies both intrinsic contributions.
                    val caption = if (!hasCaption) 0 else if (maximum && table.rows.all { it.isEmpty() })
                        measurables.first().maxIntrinsicWidth(Constraints.Infinity)
                    else measurables.first().minIntrinsicWidth(Constraints.Infinity)
                    val width = if (maximum) grid.maxIntrinsicWidth(Constraints.Infinity) else grid.minIntrinsicWidth(Constraints.Infinity)
                    return maxOf(caption, width)
                }
                override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
                override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)
                override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                    if (measurables.size != if (hasCaption) 2 else 1)
                        throw UnsupportedFloatLayout("Table block content owners are inconsistent")
                    val request = surfaceRequest.value ?: throw UnsupportedFloatLayout("Table block content request is unavailable")
                    val caption = if (hasCaption) measurables.first() else null
                    val grid = measurables[if (hasCaption) 1 else 0]
                    val available = floor(request.contentWidth).toInt()
                    widthInput.update(request.widthReference)
                    val hasGrid = table.rows.any { it.isNotEmpty() }
                    var body: Placeable? = null
                    var heading: Placeable? = null
                    var attemptedBody = false
                    var attemptedHeading = false
                    var failure: String? = null
                    var gridY = 0L
                    var height = 0
                    var scrollGeometry: NativeTableBlockScrollGeometry? = null
                    try {
                        val floorWidth = caption?.minIntrinsicWidth(Constraints.Infinity) ?: 0
                        if (floorWidth !in 0..TablePixelLimit || spacing < 0)
                            throw UnsupportedFloatLayout("Table block caption minimum is invalid")
                        captionMinimum.update(floorWidth)
                        attemptedBody = true
                        body = grid.measure(Constraints(maxWidth = available, maxHeight = request.maxHeight))
                        val actual = checkNotNull(body)
                        if (actual.measuredWidth !in 0..TablePixelLimit ||
                            hasGrid && actual.measuredWidth < floorWidth && contentFailure.value == null)
                            throw UnsupportedFloatLayout("Anonymous grid did not retain its caption minimum")
                        val captionWidth = if (hasGrid) actual.measuredWidth else if (caption != null) {
                            val maximum = caption.maxIntrinsicWidth(Constraints.Infinity)
                            if (maximum !in floorWidth..TablePixelLimit)
                                throw UnsupportedFloatLayout("Empty-grid caption maximum exceeds native geometry")
                            maxOf(floorWidth, minOf(available, maximum))
                        } else 0
                        if (caption != null) {
                            attemptedHeading = true
                            heading = caption.measure(Constraints(minWidth = captionWidth,
                                maxWidth = captionWidth, maxHeight = request.maxHeight))
                        }
                        gridY = (heading?.measuredHeight ?: 0).toLong() + if (heading != null && hasGrid) spacing else 0
                        val total = gridY + actual.measuredHeight
                        if (total > request.maxHeight || total > TablePixelLimit)
                            throw UnsupportedFloatLayout("Table block content exceeds native geometry")
                        height = total.toInt()
                        val extent = maxOf(actual.measuredWidth, heading?.measuredWidth ?: 0)
                        scrollGeometry = if (request.clipped) tableBlockScrollGeometry(request.contentWidth, extent, scroll.value, rtl)
                            else NativeTableBlockScrollGeometry(extent, extent, 0f, 0f, 0f, 0f)
                        failure = contentFailure.value
                    } catch (error: UnsupportedFloatLayout) {
                        failure = error.message ?: "Table block content is unavailable"
                    } catch (error: IllegalArgumentException) {
                        failure = error.message ?: "Table block content exceeds native geometry"
                    }
                    if (scrollGeometry == null) {
                        val retainedConstraints = Constraints.fitPrioritizingWidth(minWidth = 0, maxWidth = available,
                            minHeight = 0, maxHeight = request.maxHeight)
                        if (!attemptedBody) {
                            captionMinimum.update(0)
                            body = try { grid.measure(retainedConstraints) }
                            catch (_: UnsupportedFloatLayout) { null }
                            catch (_: IllegalArgumentException) { null }
                        }
                        if (caption != null && !attemptedHeading) {
                            heading = try { caption.measure(retainedConstraints) }
                            catch (_: UnsupportedFloatLayout) { null }
                            catch (_: IllegalArgumentException) { null }
                        }
                        gridY = (heading?.measuredHeight ?: 0).toLong() + if (heading != null && hasGrid) spacing.coerceAtLeast(0) else 0
                        val extent = maxOf(body?.measuredWidth ?: 0, heading?.measuredWidth ?: 0)
                        scrollGeometry = try { if (request.clipped) tableBlockScrollGeometry(request.contentWidth, extent, scroll.value, rtl)
                            else NativeTableBlockScrollGeometry(extent, extent, 0f, 0f, 0f, 0f) }
                        catch (_: UnsupportedFloatLayout) { null }
                        catch (_: IllegalArgumentException) { null }
                        if (scrollGeometry == null) {
                            val viewportWidth = ceil(request.contentWidth).toInt()
                            val width = maxOf(viewportWidth, extent).coerceAtMost(TablePixelLimit)
                            val range = width - viewportWidth
                            val value = scroll.value.coerceIn(0, range)
                            scrollGeometry = NativeTableBlockScrollGeometry(viewportWidth, width, range.toFloat(),
                                if (rtl) (value - range).toFloat() else -value.toFloat(), 0f, 0f)
                        }
                        val fallbackConstraints = Constraints.fitPrioritizingWidth(minWidth = 0,
                            maxWidth = checkNotNull(scrollGeometry).surfaceWidth, minHeight = 0, maxHeight = request.maxHeight)
                        height = nativeFallbackHeight(fallbackConstraints, gridY + (body?.measuredHeight ?: 0))
                    }
                    val finalScroll = checkNotNull(scrollGeometry)
                    val extentWidth = maxOf(body?.measuredWidth ?: 0, heading?.measuredWidth ?: 0)
                    measured[0] = TableBlockSurfaceMeasurement(body?.measuredWidth ?: 0, body?.measuredHeight ?: 0,
                        heading?.measuredWidth ?: 0, heading?.measuredHeight ?: 0,
                        gridY.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), height, extentWidth, request,
                        failure ?: if (body == null || hasCaption && heading == null) "Table block child measurement is unavailable" else null)
                    return layout(finalScroll.surfaceWidth, height) {
                        fun Placeable.placeAt(y: Int) {
                            val left = floor(finalScroll.childTranslation).toInt()
                            placeWithLayer(left - (width - measuredWidth) / 2, y - (this.height - measuredHeight) / 2) {
                                translationX = finalScroll.childTranslation - left
                            }
                        }
                        heading?.placeAt(0)
                        if (gridY <= Int.MAX_VALUE) body?.placeAt(gridY.toInt())
                    }
                }
            }.withPairedHeight(needsHeightIntrinsics) { measurables, width ->
                    if (hasCaption || measurables.size != 1) return@withPairedHeight Constraints.Infinity
                    // HorizontalScroll forwards Infinity for height intrinsics. The parent-bound
                    // candidate retains the actual source content width across that modifier.
                    val candidate = if (narrow) input?.blockBox?.takeIf {
                        it.policy === policy && it.floatPolicy === floatPolicy
                    } ?: return@withPairedHeight Constraints.Infinity else null
                    val actualWidth = candidate?.contentWidth?.let { floor(it).toInt() } ?: width
                    if (actualWidth !in 0..TablePixelLimit) return@withPairedHeight Constraints.Infinity
                    widthInput.update(if (narrow) actualWidth else input?.containingWidth ?: return@withPairedHeight Constraints.Infinity)
                    return@withPairedHeight measurables.single().maxIntrinsicHeight(actualWidth).takeIf { it in 0..TablePixelLimit } ?: Constraints.Infinity

            })
        }
        NativeLayoutMessage(message)
        if (focusOwner != null) NativeTableScrollFocusOverlay(focusOwner)
    }, measurePolicy = object : MeasurePolicy {
        private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
            val child = measurables.first()
            val query = input?.blockIntrinsicQuery.takeIf { floatPolicy != null && narrow || intrinsicTable }
            val inner = if (query != null) {
                val minimum = child.minIntrinsicWidth(Constraints.Infinity)
                val preferred = child.maxIntrinsicWidth(Constraints.Infinity)
                if (minimum !in 0..TablePixelLimit || preferred !in minimum..TablePixelLimit) return Constraints.Infinity
                checkNotNull(input).publishBlockIntrinsics(binding, table, query, ContainerWidths(minimum.toFloat(), preferred.toFloat()))
                if (maximum) preferred else minimum
            } else if (maximum) child.maxIntrinsicWidth(Constraints.Infinity) else child.minIntrinsicWidth(Constraints.Infinity)
            if (inner > TablePixelLimit) return Constraints.Infinity
            return if (narrow) tableBlockIntrinsicWidth(policy, inner, density.density, normalBodyPixels, floatPolicy) else inner
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semantic.measure measureBlock@{
            val viewport = measurables.first()
            val warningSource = measurables[1]
            val focusSource = if (focusOwner != null) measurables[2] else null
            var focusPlaceable: Placeable? = null
            var focusAttempted = false
            var focusViewport = 0f
            var focusOffset = 0f
            var focusOverflow = 0f
            val containing = input?.containingWidth ?: constraints.maxWidth.takeIf { constraints.hasBoundedWidth }
            var failure: String? = null
            var child: Placeable? = null
            var attempted = false
            var ownerWidth = (containing ?: 0).coerceIn(0, TablePixelLimit)
            var ownerHeight = 0
            var viewportX = 0f
            var viewportY = 0f
            var publicationRevision = 0L
            var publicationScroll = 0
            painted[0] = null
            overflowClip[0] = null
            preciseContentClip[0] = null
            try {
                if (containing == null || containing !in 0..TablePixelLimit)
                    throw UnsupportedFloatLayout("Table block requires a bounded containing width")
                if (focusOwner != null && (input == null || hasCaption))
                    throw UnsupportedFloatLayout(if (policy.isSeparateCornerGrid)
                        "Corner-table focus requires its native captionless parent owner"
                        else if (intrinsicTable) "Intrinsic table requires its native captionless parent owner"
                        else "Paired table requires its native captionless parent owner")
                if (!narrow) {
                    if (focusOwner == null || input?.blockBox != null)
                        throw UnsupportedFloatLayout("Wide table source allocation is inconsistent")
                    val allocated = input?.viewportWidth ?: throw UnsupportedFloatLayout("Wide table width is unavailable")
                    if (!constraints.hasBoundedWidth || constraints.maxWidth != allocated)
                        throw UnsupportedFloatLayout("Wide table parent allocated a different border box")
                    surfaceRequest.update(TableBlockSurfaceRequest(allocated.toFloat(), constraints.maxHeight, containing, clipped = false))
                    widthInput.update(containing)
                    contentFailure.update(null); contentFailure.invalidate()
                    attempted = true
                    child = viewport.measure(Constraints(maxWidth = allocated, maxHeight = constraints.maxHeight))
                    val body = measured[0]?.takeIf { it.request == surfaceRequest.value }
                        ?: throw UnsupportedFloatLayout("Wide table content measurement is unavailable")
                    body.failure?.let { throw UnsupportedFloatLayout(it) }
                    ownerWidth = body.gridWidth
                    ownerHeight = body.height
                    focusViewport = ownerWidth.toFloat()
                    if (ownerWidth <= 0 || ownerHeight <= 0)
                        throw UnsupportedFloatLayout("Zero-area table focus owner is unavailable")
                    val bounds = RectF(0f, 0f, ownerWidth.toFloat(), ownerHeight.toFloat())
                    contentClip[0] = bounds
                    scrollOwner.active = false
                    onPlacement?.invoke(NativeTableBlockPlacement(bounds, bounds, 0f, 0f, 0f,
                        body.gridWidth, body.gridHeight, 0, 0, 0f, 0f, ownerWidth, ownerHeight, null,
                        { _, completed -> completed() }, clipped = false))?.let { throw UnsupportedFloatLayout(it) }
                    input.publish(binding, table, ownerWidth, ownerHeight, allocated, scrolling = false)
                } else {
                val box = input?.blockBox ?: resolveTableBlockBox(policy, containing.toFloat(), density.density, normalBodyPixels)
                if (box.policy !== policy || box.floatPolicy !== floatPolicy) throw UnsupportedFloatLayout("Table block policy changed during measurement")
                val borderPixels = ceil(box.borderWidth).toInt()
                if (input != null && (input.viewportWidth != borderPixels || !constraints.hasBoundedWidth ||
                    constraints.maxWidth != borderPixels))
                    throw UnsupportedFloatLayout("Table block parent allocated a different border box")
                val contentPixels = ceil(box.contentWidth).toInt()
                val availableHeight = box.contentMaxHeight(constraints)
                surfaceRequest.update(TableBlockSurfaceRequest(box.contentWidth, availableHeight))
                widthInput.update(floor(box.contentWidth).toInt())
                contentFailure.update(null)
                contentFailure.invalidate()
                attempted = true
                child = viewport.measure(Constraints(minWidth = contentPixels, maxWidth = contentPixels, maxHeight = availableHeight))
                val body = measured[0]?.takeIf { it.request == surfaceRequest.value }
                    ?: throw UnsupportedFloatLayout("Table block content measurement is unavailable")
                contentClip[0] = RectF(0f, 0f, box.contentWidth, body.height.toFloat())
                body.failure?.let { throw UnsupportedFloatLayout(it) }
                val exactBlockHeight = body.height.toFloat() + box.insets.top + box.insets.bottom
                val blockHeight = ceil(exactBlockHeight).toInt()
                val placed = if (input == null) placeStandaloneTableBlock(box, containing.toFloat(),
                    exactBlockHeight, captionInput?.exclusions.orEmpty()) else null
                val borderLeft = placed?.content?.left ?: 0f
                val borderTop = placed?.content?.top ?: 0f
                ownerWidth = if (input != null) borderPixels else containing
                ownerHeight = ceil((placed?.nextY ?: exactBlockHeight).toDouble()).toInt()
                if (ownerHeight > constraints.maxHeight || ownerHeight > TablePixelLimit)
                    throw UnsupportedFloatLayout("Table block border box exceeds native geometry")
                if (focusOwner != null && (box.borderWidth <= 0f || exactBlockHeight <= 0f))
                    throw UnsupportedFloatLayout("Zero-area table focus owner is unavailable")
                viewportX = borderLeft + box.insets.left
                viewportY = borderTop + box.insets.top
                val borderBounds = RectF(borderLeft, borderTop, borderLeft + box.borderWidth,
                    borderTop + exactBlockHeight)
                val contentBounds = RectF(viewportX, viewportY, viewportX + box.contentWidth, viewportY + body.height)
                contentClip[0] = contentBounds
                box.decoration.prepareCorners(borderBounds)
                val cornerClip = box.decoration.nativeCorners?.let { corners ->
                    NativeTableCornerShape(NativeFloatBounds(borderBounds.left, borderBounds.top, borderBounds.right, borderBounds.bottom),
                        corners, box.decoration.edges?.first()?.width ?: box.decoration.borderWidth)
                }
                val overflow = tableBlockOverflowBounds(policy, NativeFloatBounds(contentBounds.left,
                    contentBounds.top, contentBounds.right, contentBounds.bottom), cornerClip,
                    if (intrinsicTable) box.paddingBounds(NativeFloatBounds(borderBounds.left, borderBounds.top,
                        borderBounds.right, borderBounds.bottom)) else null)
                val clipBounds = RectF(overflow.left, overflow.top, overflow.right, overflow.bottom)
                if (policy.isSeparateCornerGrid || intrinsicTable) overflowClip[0] = clipBounds
                preciseContentClip[0] = cornerClip?.let { nativeTableContentClip(it, clipBounds) }
                val scrolling = tableBlockScrollGeometry(box.contentWidth, body.extentWidth, scroll.value, rtl)
                focusViewport = box.contentWidth
                focusOffset = (-scrolling.physicalTranslation).coerceIn(0f, scrolling.overflow)
                focusOverflow = scrolling.overflow
                scrollOwner.active = true
                scrollOwner.contentWidth = box.contentWidth
                scrollOwner.gridWidth = body.extentWidth
                scrollOwner.rtl = rtl
                publicationScroll = scroll.value
                publicationRevision = scrollOwner.measured()
                val placement = NativeTableBlockPlacement(borderBounds, clipBounds,
                    viewportX + scrolling.alignment, viewportY, scrolling.physicalTranslation,
                    body.gridWidth, body.gridHeight, body.captionWidth, body.captionHeight, 0f, body.gridY.toFloat(),
                    ownerWidth, ownerHeight, scrollOwner.takeIf { scrolling.overflow > 0f }, scrollOwner::reveal, cornerClip = cornerClip)
                onPlacement?.invoke(placement)?.let { throw UnsupportedFloatLayout(it) }
                input?.publishBlock(binding, table, blockHeight, body.gridWidth, body.gridHeight, exactBlockHeight)
                painted[0] = box.decoration to borderBounds
                }
                if (focusSource != null) {
                    focusAttempted = true
                    focusPlaceable = focusSource.measure(Constraints.fixed(ownerWidth, ownerHeight))
                }
            } catch (error: UnsupportedFloatLayout) {
                failure = error.message ?: "Table block layout is unavailable"
            } catch (error: IllegalArgumentException) {
                failure = error.message ?: "Table block geometry exceeds the native range"
            }
            if (failure == null) {
                unavailable[0] = false
                message.update(null)
                val warning = warningSource.measure(Constraints.fixed(0, 0))
                drawPublication.publish(painted[0], contentClip[0], overflowClip[0], preciseContentClip[0])
                return@measureBlock layout(ownerWidth, ownerHeight) {
                    // Run the empty warning layout so SubcomposeLayout disposes its old slot.
                    warning.place(0, 0)
                    val x = floor(viewportX).toInt(); val y = floor(viewportY).toInt()
                    val placedChild = checkNotNull(child)
                    val adjustX = if (!narrow) (placedChild.width - placedChild.measuredWidth) / 2 else 0
                    val adjustY = if (!narrow) (placedChild.height - placedChild.measuredHeight) / 2 else 0
                    placedChild.placeWithLayer(x - adjustX, y - adjustY) { translationX = viewportX - x; translationY = viewportY - y }
                    focusPlaceable?.place(0, 0)
                    focusOwner?.update(narrow, focusViewport, focusOffset, focusOverflow,
                        scrollOwner.takeIf { narrow }, parentClip)
                    scrollOwner.placed(publicationRevision, publicationScroll)
                }
            }
            input?.refuse(binding)
            focusOwner?.unavailable()
            if (focusSource != null && !focusAttempted) {
                val retainedFocusSize = focusOwner?.retainedUnavailableFocusSize()
                focusPlaceable = focusSource.measure(Constraints.fixed(
                    retainedFocusSize?.width ?: 0, retainedFocusSize?.height ?: 0))
            }
            if (!unavailable[0]) {
                onUnavailable()
                scrollOwner.cancelPending()
                unavailable[0] = true
            }
            painted[0] = null
            overflowClip[0] = null
            preciseContentClip[0] = null
            if (!attempted) {
                surfaceRequest.update(TableBlockSurfaceRequest(ownerWidth.toFloat(), constraints.maxHeight,
                    widthReference = containing ?: ownerWidth, clipped = narrow))
                widthInput.update(ownerWidth)
                contentClip[0] = RectF(0f, 0f, ownerWidth.toFloat(), constraints.maxHeight.toFloat())
                child = try { viewport.measure(Constraints(maxWidth = ownerWidth, maxHeight = constraints.maxHeight)) }
                catch (_: UnsupportedFloatLayout) { null }
                catch (_: IllegalArgumentException) { null }
            }
            message.update("Table block layout unavailable. " + failure)
            val warning = warningSource.measure(Constraints(maxWidth = ownerWidth, maxHeight = constraints.maxHeight))
            val height = nativeFallbackHeight(Constraints(maxWidth = ownerWidth, minHeight = constraints.minHeight,
                maxHeight = constraints.maxHeight), warning.measuredHeight.toLong() + (child?.measuredHeight ?: 0))
            val retained = measured[0]?.takeIf { child != null && it.request == surfaceRequest.value }
            var fallbackPublished = false
            if (retained != null) {
                val width = retained.request.contentWidth
                val scrollGeometry = try { if (narrow) tableBlockScrollGeometry(width, retained.extentWidth, scroll.value, rtl)
                    else NativeTableBlockScrollGeometry(retained.extentWidth, retained.extentWidth, 0f, 0f, 0f, 0f) }
                    catch (_: UnsupportedFloatLayout) { null }
                    catch (_: IllegalArgumentException) { null }
                if (scrollGeometry != null) {
                scrollOwner.contentWidth = width
                scrollOwner.gridWidth = retained.extentWidth
                scrollOwner.rtl = rtl
                val clipHeight = minOf(retained.height, (height - warning.measuredHeight).coerceAtLeast(0))
                contentClip[0] = RectF(0f, 0f, width, clipHeight.toFloat())
                publicationScroll = scroll.value
                publicationRevision = scrollOwner.measured()
                val rejected = onPlacement?.invoke(NativeTableBlockPlacement(RectF(0f, 0f, ownerWidth.toFloat(), height.toFloat()),
                    RectF(0f, warning.measuredHeight.toFloat(), width, (warning.measuredHeight + clipHeight).toFloat()),
                    scrollGeometry.alignment, warning.measuredHeight.toFloat(), scrollGeometry.physicalTranslation,
                    retained.gridWidth, retained.gridHeight, retained.captionWidth, retained.captionHeight,
                    0f, retained.gridY.toFloat(), ownerWidth, height,
                    scrollOwner.takeIf { narrow && scrollGeometry.overflow > 0f }, scrollOwner::reveal, unavailable = true, clipped = narrow))
                fallbackPublished = rejected == null
                }
            }
            if (!fallbackPublished) {
                onUnavailable()
                scrollOwner.cancelPending()
            }
            drawPublication.publish(painted[0], contentClip[0], overflowClip[0], preciseContentClip[0])
            layout(ownerWidth, height) {
                warning.place(0, 0)
                child?.let { retainedChild ->
                    if (narrow) retainedChild.place(0, warning.measuredHeight)
                    else retainedChild.place(-(retainedChild.width - retainedChild.measuredWidth) / 2,
                        warning.measuredHeight - (retainedChild.height - retainedChild.measuredHeight) / 2)
                }
                focusPlaceable?.place(0, 0)
                if (fallbackPublished) scrollOwner.placed(publicationRevision, publicationScroll)
            }
        }
    }.withPairedHeight(needsHeightIntrinsics) { measurables, width ->
            val owner = input ?: return@withPairedHeight Constraints.Infinity
            if (hasCaption || width !in 0..TablePixelLimit) return@withPairedHeight Constraints.Infinity
            val box = if (narrow) owner.blockBox ?: return@withPairedHeight Constraints.Infinity else null
            if (box != null && (box.policy !== policy || box.floatPolicy !== floatPolicy || ceil(box.borderWidth).toInt() != width))
                return@withPairedHeight Constraints.Infinity
            if (box == null && owner.viewportWidth != width) return@withPairedHeight Constraints.Infinity
            val contentWidth = box?.contentWidth?.let { floor(it).toInt() } ?: width
            val inner = measurables.first().maxIntrinsicHeight(contentWidth)
            if (inner !in 0..TablePixelLimit) return@withPairedHeight Constraints.Infinity
            val height = inner.toDouble() + (box?.insets?.top ?: 0f) + (box?.insets?.bottom ?: 0f)
            return@withPairedHeight if (height > TablePixelLimit) Constraints.Infinity else ceil(height).toInt()

    })
    }
}
