package app.smallthingz.dict

import android.graphics.RectF
import androidx.compose.foundation.MutatePriority
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.gestures.FlingBehavior
import androidx.compose.foundation.gestures.ScrollableDefaults
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
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.layout.onGloballyPositioned
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
    val margins: NativeTableAutoMargins,
    val containingDirection: TableContainingDirection,
    val usedMargins: NativeTableUsedMargins,
    val decoration: NativeContainerDecoration,
) {
    init {
        require(listOf(borderWidth, contentWidth, insets.top, insets.right, insets.bottom, insets.left)
            .all { it.isFinite() && it in 0f..TablePixelLimit.toFloat() })
        require(kotlin.math.abs(borderWidth.toDouble() - contentWidth - insets.left - insets.right) <=
            maxOf(.001, Math.ulp(borderWidth).toDouble() * 4))
    }

    // An unbounded maximum is a sentinel, not an edge-adjustable pixel length.
    fun contentMaxHeight(constraints: Constraints): Int = if (!constraints.hasBoundedHeight) Constraints.Infinity
        else (constraints.maxHeight - ceil(insets.top.toDouble() + insets.bottom).toInt()).coerceAtLeast(0)
}

private fun tableBlockContainerStyle(policy: TableBlockViewport, intrinsic: Boolean = false): ContainerViewportStyle {
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
    val width = checkNotNull(source.width)
    return ContainerViewportStyle(ContainerStyle(padding = source.padding,
        width = if (intrinsic && width.unit == StyleWidthUnit.Percent) ContainerWidth.Auto else ContainerWidth.Length(width),
        maxWidth = if (intrinsic && policy.maxWidth.unit == StyleWidthUnit.Percent) ContainerMaxWidth.None
            else ContainerMaxWidth.Length(policy.maxWidth), boxSizing = policy.boxSizing, border = border), source.marginValues)
}

internal fun resolveTableBlockBox(policy: TableBlockViewport, containingWidth: Float,
    density: Float, normalBodyPixels: Float): NativeTableBlockBox {
    require(containingWidth.isFinite() && containingWidth in 0f..TablePixelLimit.toFloat())
    require(density.isFinite() && density > 0f && normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
    val source = policy.boxStyle
    fun length(value: StyleLength): Float {
        val result = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density else normalBodyPixels
        if (!result.isFinite() || result !in 0.0..TablePixelLimit.toDouble())
            throw UnsupportedFloatLayout("Table block edge exceeds native geometry")
        return result.toFloat()
    }
    val resolved = tableBlockContainerStyle(policy)
    val sides = resolved.box.border.physicalEdges()
    val edges = listOf(sides.top, sides.right, sides.bottom, sides.left)
    val borderWidths = edges.map { it.usedWidth?.let(::length) ?: 0f }
    val padding = source.padding
    val insets = FloatMargins((padding?.top?.let(::length) ?: 0f) + borderWidths[0],
        (padding?.right?.let(::length) ?: 0f) + borderWidths[1],
        (padding?.bottom?.let(::length) ?: 0f) + borderWidths[2],
        (padding?.left?.let(::length) ?: 0f) + borderWidths[3])
    val direction = checkNotNull(source.containingDirection)
    val margins = resolveTableAutoMargins(checkNotNull(source.marginValues), density, normalBodyPixels)
    // Reuse the normal block scalar equation; no Container owner or second body is created.
    val used = containerBoxWidth(resolved, containingWidth, ContainerWidths(0f, 0f), density,
        normalBodyPixels, rtl = direction == TableContainingDirection.Rtl)
    val paintEdges = edges.mapIndexed { index, value ->
        val color = when (value) {
            is ContainerBorderEdge.Solid -> (value.color as ContainerColor.Rgb).value
            is ContainerBorderEdge.Dotted -> (value.color as ContainerColor.Rgb).value
            else -> null
        }
        NativeContainerPaintEdge(borderWidths[index], canonicalColorArgb(color)?.toInt(), value is ContainerBorderEdge.Dotted)
    }
    return NativeTableBlockBox(policy, used.borderBox, used.content, insets, margins, direction,
        NativeTableUsedMargins(margins.fixed.top, used.marginRight, margins.fixed.bottom, used.marginLeft),
        NativeContainerDecoration(canonicalColorArgb(source.background)?.toInt(), null, 0f, paintEdges))
}

/** Cyclic preferred/max percentages take their initial value only for intrinsic contribution.
 * The later definite containing width still resolves the original source percentages once. */
internal fun tableBlockIntrinsicWidth(policy: TableBlockViewport, innerWidth: Int,
    density: Float, normalBodyPixels: Float): Int {
    if (innerWidth !in 0..TablePixelLimit) return Constraints.Infinity
    val resolved = tableBlockContainerStyle(policy, intrinsic = true)
    val used = containerBoxWidth(resolved, 0f, ContainerWidths(innerWidth.toFloat(), innerWidth.toFloat()),
        density, normalBodyPixels, flexItem = true,
        rtl = policy.boxStyle.containingDirection == TableContainingDirection.Rtl)
    val width = used.borderBox.toDouble() + used.marginLeft + used.marginRight
    return if (!width.isFinite() || width > TablePixelLimit) Constraints.Infinity else ceil(width).toInt()
}

internal fun placeStandaloneTableBlock(box: NativeTableBlockBox, containingWidth: Float,
    borderHeight: Float, exclusions: List<NativeFloatExclusion>): NativeAutoMarginTablePlacement {
    require(borderHeight.isFinite() && borderHeight in 0f..TablePixelLimit.toFloat())
    return placeNativeAutoMarginTable(containingWidth, 0f, exclusions, box.margins, box.containingDirection,
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
)

private class TableBlockScrollOwner(private val state: ScrollState, private val scope: CoroutineScope,
    private val flingBehavior: FlingBehavior, private val invalidate: () -> Unit) : NativeHorizontalScrollTarget {
    var contentWidth = 0f
    var gridWidth = 0
    var rtl = false
    private var motion: Job? = null
    private var closed = false
    private data class Reveal(val afterRevision: Long, val completed: () -> Unit, var appliedValue: Int? = null)
    private var reveal: Reveal? = null
    private var measuredRevision = 0L

    override fun scrollBy(physicalDistance: Float): Float {
        if (closed || !physicalDistance.isFinite()) return 0f
        motion?.cancel()
        reveal = null
        val used = state.dispatchRawDelta(if (rtl) -physicalDistance else physicalDistance)
        if (used != 0f) invalidate()
        return if (rtl) -used else used
    }
    override fun fling(physicalVelocity: Float) {
        if (closed || !physicalVelocity.isFinite()) return
        motion?.cancel()
        reveal = null
        motion = scope.launch {
            state.scroll { with(flingBehavior) { performFling(if (rtl) -physicalVelocity else physicalVelocity) } }
        }
    }
    override fun cancel() {
        if (closed) return
        motion?.cancel()
        reveal = null
        motion = scope.launch { state.scroll(MutatePriority.UserInput) {} }
    }
    fun reveal(rect: RectF, completed: () -> Unit) {
        if (closed) { completed(); return }
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

private data class TableBlockSurfaceRequest(val contentWidth: Float, val maxHeight: Int)
private data class TableBlockSurfaceMeasurement(val gridWidth: Int, val gridHeight: Int,
    val captionWidth: Int, val captionHeight: Int, val gridY: Int, val height: Int,
    val extentWidth: Int, val request: TableBlockSurfaceRequest, val failure: String?)

internal val LocalTableBlockLayoutFailure = staticCompositionLocalOf<NativeLayoutInput<String?>?> { null }

/** One real caption/grid surface inside the source Table's independently sized block box. */
@Composable
internal fun TableBlockViewportBox(table: Table, policy: TableBlockViewport,
    captionMinimum: NativeLayoutInput<Int>, hasCaption: Boolean, spacing: Int,
    onPlacement: ((NativeTableBlockPlacement) -> String?)? = null, onUnavailable: () -> Unit = {},
    content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val normalBodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val input = LocalNativeTableMarginMeasureInput.current?.takeIf { it.table === table }
    val captionInput = LocalStaticCaptionInput.current.takeIf { input == null }
    val binding = remember(NativeDelegatedTableIdentity(table), policy, hasCaption, spacing) { Any() }
    SideEffect { input?.bind(binding) }
    DisposableEffect(input, binding) { onDispose { input?.unbind(binding) } }
    val parentClip = LocalNativeScrollClip.current
    val clip = remember(parentClip) { NativeScrollClip(parentClip) }
    val view = LocalView.current
    val semantic = rememberNativeSemanticMeasurement()
    val inheritedBackground = LocalAuthoredBackground.current
    val remeasure = remember { NativeLayoutInput(Unit) }
    val surfaceRequest = remember { NativeLayoutInput<TableBlockSurfaceRequest?>(null) }
    val widthInput = remember { NativeLayoutInput(0) }
    val measured = remember { arrayOfNulls<TableBlockSurfaceMeasurement>(1) }
    val painted = remember { arrayOfNulls<Pair<NativeContainerDecoration, RectF>>(1) }
    val contentClip = remember { arrayOfNulls<RectF>(1) }
    val unavailable = remember(binding) { booleanArrayOf(false) }
    val message = remember { NativeLayoutInput<String?>(null) }
    val contentFailure = remember { NativeLayoutInput<String?>(null) }
    val scroll = remember(binding) { ScrollState(0) }
    val scope = rememberCoroutineScope()
    val flingBehavior = ScrollableDefaults.flingBehavior()
    val scrollOwner = remember(binding, scroll, scope, flingBehavior, semantic) {
        TableBlockScrollOwner(scroll, scope, flingBehavior) { remeasure.invalidate(); semantic.changed() }
    }
    DisposableEffect(binding, scrollOwner) { onDispose { scrollOwner.detached() } }
    LaunchedEffect(scroll.value) { remeasure.invalidate(); semantic.changed() }
    val rtl = policy.gridDirection == TableContainingDirection.Rtl
    val direction = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr

    Layout(modifier = semantic.modifier.then(remeasure.modifier).then(input?.modifier ?: Modifier)
        .then(captionInput?.modifier ?: Modifier)
        .then(if (input != null) Modifier.testTag("compiled-table-block-viewport") else Modifier)
        .drawWithContent {
        painted[0]?.let { (decoration, bounds) -> decoration.paint(drawContext.canvas.nativeCanvas, bounds) }
        drawContent()
    }, content = {
        CompositionLocalProvider(LocalLayoutDirection provides direction,
            LocalNativeSemanticMeasurement provides semantic,
            LocalNativeScrollClip provides clip, LocalNativeContainerScrollport provides true,
            LocalTableBlockLayoutFailure provides contentFailure,
            LocalAuthoredBackground provides (policy.boxStyle.background ?: inheritedBackground),
            LocalNativeTableMarginMeasureInput provides null, LocalFloatTableWidthReference provides widthInput,
            LocalFloatMarginsConsumed provides false, LocalNativeContextMeasureInput provides null,
            LocalNativeFlowMeasureInput provides null, LocalStaticCaptionInput provides null,
            LocalNativeContextContainAtEnd provides true) {
            Layout(modifier = surfaceRequest.modifier.testTag("compiled-table-block-content").drawWithContent {
                val rect = contentClip[0]
                if (rect != null) clipRect(0f, 0f, rect.width(), rect.height()) { this@drawWithContent.drawContent() }
            }.onGloballyPositioned { coordinates ->
                val origin = coordinates.localToWindow(Offset.Zero)
                val rect = contentClip[0]
                if (rect != null) clip.update(Rect(origin.x, origin.y,
                    origin.x + rect.width(), origin.y + rect.height()), view)
            }.horizontalScroll(scroll), content = content, measurePolicy = object : MeasurePolicy {
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
                    widthInput.update(available)
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
                        scrollGeometry = tableBlockScrollGeometry(request.contentWidth,
                            maxOf(actual.measuredWidth, heading?.measuredWidth ?: 0), scroll.value, rtl)
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
                        scrollGeometry = try { tableBlockScrollGeometry(request.contentWidth, extent, scroll.value, rtl) }
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
            })
        }
        NativeLayoutMessage(message)
    }, measurePolicy = object : MeasurePolicy {
        private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
            val child = measurables.first()
            val inner = if (maximum) child.maxIntrinsicWidth(Constraints.Infinity) else child.minIntrinsicWidth(Constraints.Infinity)
            if (inner > TablePixelLimit) return Constraints.Infinity
            return tableBlockIntrinsicWidth(policy, inner, density.density, normalBodyPixels)
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semantic.measure measureBlock@{
            val viewport = measurables.first()
            val warningSource = measurables.last()
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
            try {
                if (containing == null || containing !in 0..TablePixelLimit)
                    throw UnsupportedFloatLayout("Table block requires a bounded containing width")
                val box = input?.blockBox ?: resolveTableBlockBox(policy, containing.toFloat(), density.density, normalBodyPixels)
                if (box.policy !== policy) throw UnsupportedFloatLayout("Table block policy changed during measurement")
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
                viewportX = borderLeft + box.insets.left
                viewportY = borderTop + box.insets.top
                val borderBounds = RectF(borderLeft, borderTop, borderLeft + box.borderWidth,
                    borderTop + exactBlockHeight)
                val clipBounds = RectF(viewportX, viewportY, viewportX + box.contentWidth, viewportY + body.height)
                contentClip[0] = clipBounds
                val scrolling = tableBlockScrollGeometry(box.contentWidth, body.extentWidth, scroll.value, rtl)
                scrollOwner.contentWidth = box.contentWidth
                scrollOwner.gridWidth = body.extentWidth
                scrollOwner.rtl = rtl
                publicationScroll = scroll.value
                publicationRevision = scrollOwner.measured()
                val placement = NativeTableBlockPlacement(borderBounds, clipBounds,
                    viewportX + scrolling.alignment, viewportY, scrolling.physicalTranslation,
                    body.gridWidth, body.gridHeight, body.captionWidth, body.captionHeight, 0f, body.gridY.toFloat(),
                    ownerWidth, ownerHeight, scrollOwner.takeIf { scrolling.overflow > 0f }, scrollOwner::reveal)
                onPlacement?.invoke(placement)?.let { throw UnsupportedFloatLayout(it) }
                input?.publishBlock(binding, table, blockHeight, body.gridWidth, body.gridHeight, exactBlockHeight)
                painted[0] = box.decoration to borderBounds
            } catch (error: UnsupportedFloatLayout) {
                failure = error.message ?: "Table block layout is unavailable"
            } catch (error: IllegalArgumentException) {
                failure = error.message ?: "Table block geometry exceeds the native range"
            }
            if (failure == null) {
                unavailable[0] = false
                message.update(null)
                val warning = warningSource.measure(Constraints.fixed(0, 0))
                return@measureBlock layout(ownerWidth, ownerHeight) {
                    // Run the empty warning layout so SubcomposeLayout disposes its old slot.
                    warning.place(0, 0)
                    val x = floor(viewportX).toInt(); val y = floor(viewportY).toInt()
                    checkNotNull(child).placeWithLayer(x, y) { translationX = viewportX - x; translationY = viewportY - y }
                    scrollOwner.placed(publicationRevision, publicationScroll)
                }
            }
            input?.refuse(binding)
            if (!unavailable[0]) {
                onUnavailable()
                scrollOwner.cancelPending()
                unavailable[0] = true
            }
            painted[0] = null
            if (!attempted) {
                surfaceRequest.update(TableBlockSurfaceRequest(ownerWidth.toFloat(), constraints.maxHeight))
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
                val scrollGeometry = try { tableBlockScrollGeometry(width, retained.extentWidth, scroll.value, rtl) }
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
                    scrollOwner.takeIf { scrollGeometry.overflow > 0f }, scrollOwner::reveal, unavailable = true))
                fallbackPublished = rejected == null
                }
            }
            if (!fallbackPublished) {
                onUnavailable()
                scrollOwner.cancelPending()
            }
            layout(ownerWidth, height) {
                warning.place(0, 0)
                child?.place(0, warning.measuredHeight)
                if (fallbackPublished) scrollOwner.placed(publicationRevision, publicationScroll)
            }
        }
    })
}
