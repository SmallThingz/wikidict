package app.smallthingz.dict

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.LayoutDirection
import kotlin.math.ceil
import kotlin.math.floor

internal data class NativeTableMarginBox(val borderWidth: Int, val borderHeight: Int,
    val viewportWidth: Int, val viewportHeight: Int, val minimumWidth: Int, val scrolling: Boolean,
    val blockBox: NativeTableBlockBox? = null, val gridWidth: Int? = null, val gridHeight: Int? = null,
    val actualBorderHeight: Float? = null) {
    val placementWidth: Float get() = blockBox?.borderWidth ?: borderWidth.toFloat()
    val placementHeight: Float get() = actualBorderHeight ?: borderHeight.toFloat()
    init {
        require(listOf(borderWidth, borderHeight, viewportWidth, viewportHeight, minimumWidth).all { it in 0..TablePixelLimit })
        if (blockBox == null) {
            require(gridWidth == null && gridHeight == null && actualBorderHeight == null)
            require(borderWidth >= minimumWidth && borderHeight == viewportHeight)
            require(if (scrolling) borderWidth >= viewportWidth else borderWidth == viewportWidth)
        } else {
            require(borderWidth == ceil(blockBox.borderWidth).toInt() && viewportWidth == borderWidth)
            require(borderHeight == viewportHeight && minimumWidth == borderWidth)
            require(gridWidth != null && gridWidth in 0..TablePixelLimit && gridHeight != null && gridHeight in 0..TablePixelLimit)
            require(actualBorderHeight != null && actualBorderHeight.isFinite() && actualBorderHeight in 0f..TablePixelLimit.toFloat() &&
                ceil(actualBorderHeight).toInt() == borderHeight)
        }
    }
}

/** One source owner publishes its measured border box separately from its scroll viewport. */
internal class NativeTableMarginMeasureInput(val table: Table) {
    private data class Request(val containingWidth: Int, val viewportWidth: Int, val minimumWidth: Int,
        val blockBox: NativeTableBlockBox? = null)
    private var request: Request? = null
    private var binding: Any? = null
    private var publishedBinding: Any? = null
    private var publishedRequest: Request? = null
    private var box: NativeTableMarginBox? = null
    private val input = NativeLayoutInput<Any?>(null) { clear() }
    val modifier: Modifier get() = input.modifier
    val containingWidth: Int? get() = request?.containingWidth
    val viewportWidth: Int? get() = request?.viewportWidth
    val blockBox: NativeTableBlockBox? get() = request?.blockBox

    fun bind(owner: Any) {
        if (binding === owner) return
        binding = owner
        clear()
        input.update(owner)
    }
    fun unbind(owner: Any) {
        if (binding !== owner) return
        binding = null
        clear()
        input.update(null)
    }
    private fun clear() { box = null; publishedBinding = null; publishedRequest = null }
    fun refuse(owner: Any) { if (binding === owner) clear() }
    fun begin(containingWidth: Int, viewportWidth: Int, minimumWidth: Int) {
        begin(Request(containingWidth, viewportWidth, minimumWidth))
    }
    fun beginBlock(containingWidth: Int, blockBox: NativeTableBlockBox) {
        val width = ceil(blockBox.borderWidth).toInt()
        begin(Request(containingWidth, width, width, blockBox))
    }
    private fun begin(next: Request) {
        clear()
        if (next.blockBox != null && next.blockBox.policy !== table.blockViewport)
            throw UnsupportedFloatLayout("Table block viewport source policy changed")
        if (listOf(next.containingWidth, next.viewportWidth, next.minimumWidth).any { it !in 0..TablePixelLimit })
            throw UnsupportedFloatLayout("Table automatic margin request exceeds native geometry")
        request = next
        input.update(Any())
        // The owning layout is remeasured even when a parent repeats an equal request.
        input.invalidate()
    }
    fun publish(owner: Any, source: Table, borderWidth: Int, borderHeight: Int,
        viewportWidth: Int, scrolling: Boolean) {
        val current = request ?: throw UnsupportedFloatLayout("Table automatic margin request is unavailable")
        if (source !== table || binding !== owner || current.viewportWidth != viewportWidth || current.blockBox != null)
            throw UnsupportedFloatLayout("Table automatic margin measure ownership changed")
        val actual = try { NativeTableMarginBox(borderWidth, borderHeight, viewportWidth, borderHeight,
            current.minimumWidth, scrolling) }
        catch (_: IllegalArgumentException) {
            throw UnsupportedFloatLayout("Table automatic margin border and viewport are inconsistent")
        }
        box = actual; publishedBinding = owner; publishedRequest = current
    }
    fun publishBlock(owner: Any, source: Table, blockHeight: Int, gridWidth: Int, gridHeight: Int,
        actualBorderHeight: Float = blockHeight.toFloat()) {
        val current = request ?: throw UnsupportedFloatLayout("Table block viewport request is unavailable")
        val block = current.blockBox ?: throw UnsupportedFloatLayout("Table block viewport width is unavailable")
        if (source !== table || binding !== owner)
            throw UnsupportedFloatLayout("Table block viewport measure ownership changed")
        val actual = try { NativeTableMarginBox(current.viewportWidth, blockHeight, current.viewportWidth,
            blockHeight, current.viewportWidth, true, block, gridWidth, gridHeight, actualBorderHeight) }
        catch (_: IllegalArgumentException) {
            throw UnsupportedFloatLayout("Table block viewport and anonymous grid are inconsistent")
        }
        box = actual; publishedBinding = owner; publishedRequest = current
    }
    fun ready(placeableWidth: Int, placeableHeight: Int): NativeTableMarginBox {
        val actual = box ?: throw UnsupportedFloatLayout("Table automatic margin measurement is unavailable")
        if (publishedBinding !== binding || publishedRequest != request ||
            actual.viewportWidth != placeableWidth || actual.viewportHeight != placeableHeight)
            throw UnsupportedFloatLayout("Table automatic margin viewport does not match its measured owner")
        return actual
    }
}

internal val LocalNativeTableMarginMeasureInput = staticCompositionLocalOf<NativeTableMarginMeasureInput?> { null }

/** The caption and grid share the real border width and the same existing scroll surface.
 * Only the scroll owner adopts containing direction; table tracks retain their own direction. */
@Composable
internal fun TableMarginBorderBox(table: Table, captionMinimumWidth: NativeLayoutInput<Int>,
    hasCaption: Boolean, spacing: Int, scrolling: Boolean, fixedInsets: FloatMargins,
    content: @Composable () -> Unit) {
    val direction = table.style?.containingDirection
    val gridDirection = LocalLayoutDirection.current
    // Unknown source direction keeps only the unavailable fallback's existing UI orientation.
    val scrollDirection = when (direction) {
        TableContainingDirection.Ltr -> LayoutDirection.Ltr
        TableContainingDirection.Rtl -> LayoutDirection.Rtl
        null -> gridDirection
    }
    val input = LocalNativeTableMarginMeasureInput.current?.takeIf { it.table === table }
    val needsInput = table.style?.let { !it.isInline && it.floatSide == null } == true
    val owner = remember(NativeDelegatedTableIdentity(table), hasCaption, spacing, scrolling, fixedInsets, gridDirection) { Any() }
    SideEffect { input?.bind(owner) }
    DisposableEffect(input, owner) { onDispose { input?.unbind(owner) } }
    val scroll = rememberScrollState()
    val message = remember { NativeLayoutInput<String?>(null) }
    val modifier = (input?.modifier ?: Modifier).then(if (scrolling) Modifier.fillMaxWidth().horizontalScroll(scroll) else Modifier)
    CompositionLocalProvider(LocalLayoutDirection provides if (scrolling) scrollDirection else gridDirection) {
        Layout(modifier = modifier, content = {
            CompositionLocalProvider(LocalLayoutDirection provides gridDirection,
                LocalNativeTableMarginMeasureInput provides null, content = content)
            NativeLayoutMessage(message)
        }, measurePolicy = object : MeasurePolicy {
            private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
                val minimumCaption = if (hasCaption) measurables.first().minIntrinsicWidth(Constraints.Infinity) else 0
                val grid = measurables[if (hasCaption) 1 else 0]
                val tableWidth = if (maximum) grid.maxIntrinsicWidth(Constraints.Infinity) else grid.minIntrinsicWidth(Constraints.Infinity)
                val width = maxOf(minimumCaption, tableWidth).toDouble() + fixedInsets.left + fixedInsets.right
                return if (!width.isFinite() || width > TablePixelLimit) Constraints.Infinity else ceil(width).toInt()
            }
            override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
            override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)
            override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                check(measurables.size == if (hasCaption) 3 else 2)
                val caption = measurables.firstOrNull().takeIf { hasCaption }
                val grid = measurables[if (hasCaption) 1 else 0]
                val warningSource = measurables.last()
                val viewport = input?.viewportWidth ?: if (scrolling) constraints.minWidth else
                    constraints.maxWidth.takeIf { constraints.hasBoundedWidth } ?: TablePixelLimit
                var bodyGrid: Placeable? = null
                var captionPlaceable: Placeable? = null
                var warning: Placeable? = null
                var attemptedGrid = false
                var attemptedCaption = false
                var attemptedWarning = false
                var failure: String? = null
                try {
                    if (direction == null) throw UnsupportedFloatLayout("Table containing direction is unavailable")
                    if (needsInput && input == null)
                        throw UnsupportedFloatLayout("Table automatic margin measure owner is unavailable")
                    if (viewport !in 0..TablePixelLimit || spacing < 0)
                        throw UnsupportedFloatLayout("Table automatic margin viewport or gap is invalid")
                    if (input != null) {
                        val actualViewport = if (scrolling) constraints.minWidth else
                            constraints.maxWidth.takeIf { constraints.hasBoundedWidth }
                        if (actualViewport != viewport)
                            throw UnsupportedFloatLayout("Table automatic margin viewport was changed by an intervening owner")
                    }
                    val floorWidth = caption?.minIntrinsicWidth(Constraints.Infinity) ?: 0
                    if (floorWidth !in 0..TablePixelLimit)
                        throw UnsupportedFloatLayout("Table caption minimum exceeds native geometry")
                    captionMinimumWidth.update(floorWidth)
                    val horizontal = fixedInsets.left.toDouble() + fixedInsets.right
                    if (!horizontal.isFinite() || horizontal > TablePixelLimit)
                        throw UnsupportedFloatLayout("Table margins exceed native geometry")
                    val available = (viewport - ceil(horizontal).toInt()).coerceAtLeast(0)
                    val gridConstraints = Constraints(maxWidth = available, maxHeight = constraints.maxHeight)
                    attemptedGrid = true
                    val measuredGrid = grid.measure(gridConstraints)
                    bodyGrid = measuredGrid
                    val borderWidth = measuredGrid.measuredWidth
                    if (borderWidth !in floorWidth..TablePixelLimit)
                        throw UnsupportedFloatLayout("Table grid did not retain its caption minimum")
                    if (caption != null) {
                        val captionConstraints = Constraints(minWidth = borderWidth, maxWidth = borderWidth,
                            maxHeight = constraints.maxHeight)
                        attemptedCaption = true
                        captionPlaceable = caption.measure(captionConstraints)
                    }
                    val captionHeight = captionPlaceable?.measuredHeight ?: 0
                    val gridTop = captionHeight.toLong() + if (captionPlaceable != null) spacing else 0
                    val borderHeight = gridTop + measuredGrid.measuredHeight
                    val outerWidth = ceil(borderWidth.toDouble() + horizontal)
                    val outerHeight = ceil(borderHeight.toDouble() + fixedInsets.top + fixedInsets.bottom)
                    if (borderHeight > TablePixelLimit || !outerWidth.isFinite() || !outerHeight.isFinite() ||
                        outerWidth > TablePixelLimit || outerHeight > TablePixelLimit || outerHeight > constraints.maxHeight)
                        throw UnsupportedFloatLayout("Table border box exceeds native geometry")
                    Constraints.fixed(outerWidth.toInt(), outerHeight.toInt())
                    if (input != null) {
                        if (fixedInsets != FloatMargins(0f, 0f, 0f, 0f))
                            throw UnsupportedFloatLayout("Table margins have two layout owners")
                        input.publish(owner, table, borderWidth, borderHeight.toInt(), viewport, scrolling)
                    }
                    message.update(null)
                    attemptedWarning = true
                    warningSource.measure(Constraints.fixed(0, 0))
                    return layout(outerWidth.toInt(), outerHeight.toInt()) {
                        fun Placeable.placeAt(x: Float, y: Float) {
                            val left = floor(x).toInt(); val top = floor(y).toInt()
                            placeWithLayer(left - (width - measuredWidth) / 2, top - (height - measuredHeight) / 2) {
                                translationX = x - left; translationY = y - top
                            }
                        }
                        captionPlaceable?.placeAt(fixedInsets.left, fixedInsets.top)
                        measuredGrid.placeAt(fixedInsets.left, fixedInsets.top + gridTop)
                    }
                } catch (error: UnsupportedFloatLayout) {
                    failure = error.message ?: "Table margin layout is unavailable"
                } catch (error: IllegalArgumentException) {
                    failure = error.message ?: "Table margin geometry exceeds the native range"
                }

                input?.refuse(owner)
                val fallbackViewport = viewport.coerceIn(0, TablePixelLimit)
                val childFallbackConstraints = Constraints.fitPrioritizingWidth(minWidth = 0, maxWidth = fallbackViewport,
                    minHeight = 0, maxHeight = constraints.maxHeight)
                if (!attemptedGrid) {
                    captionMinimumWidth.update(0)
                    attemptedGrid = true
                    bodyGrid = try { grid.measure(childFallbackConstraints) }
                    catch (error: UnsupportedFloatLayout) { failure += "; " + error.message; null }
                    catch (error: IllegalArgumentException) { failure += "; " + error.message; null }
                }
                if (caption != null && !attemptedCaption) {
                    attemptedCaption = true
                    captionPlaceable = try { caption.measure(childFallbackConstraints) }
                    catch (error: UnsupportedFloatLayout) { failure += "; " + error.message; null }
                    catch (error: IllegalArgumentException) { failure += "; " + error.message; null }
                }
                val fallbackWidth = maxOf(fallbackViewport, captionPlaceable?.measuredWidth ?: 0,
                    bodyGrid?.measuredWidth ?: 0).coerceAtMost(TablePixelLimit)
                val fallbackConstraints = Constraints.fitPrioritizingWidth(minWidth = 0, maxWidth = fallbackWidth,
                    minHeight = constraints.minHeight, maxHeight = constraints.maxHeight)
                message.update("Table margin layout unavailable. " + failure)
                if (!attemptedWarning) {
                    val warningConstraints = Constraints(maxWidth = fallbackViewport, maxHeight = fallbackConstraints.maxHeight)
                    attemptedWarning = true
                    warning = try { warningSource.measure(warningConstraints) }
                    catch (_: UnsupportedFloatLayout) { null }
                    catch (_: IllegalArgumentException) { null }
                }
                val warningHeight = warning?.measuredHeight ?: 0
                val captionTop = warningHeight.toLong()
                val gridTop = captionTop + (captionPlaceable?.measuredHeight ?: 0) +
                    if (captionPlaceable != null) spacing.coerceAtLeast(0) else 0
                val fallbackHeight = nativeFallbackHeight(fallbackConstraints, gridTop + (bodyGrid?.measuredHeight ?: 0))
                return layout(fallbackWidth, fallbackHeight) {
                    warning?.place(0, 0)
                    fun Placeable.retainAt(top: Long) {
                        if (top < fallbackHeight && top <= Int.MAX_VALUE) {
                            place(-(width - measuredWidth) / 2, top.toInt() - (height - measuredHeight) / 2)
                        }
                    }
                    captionPlaceable?.retainAt(captionTop)
                    bodyGrid?.retainAt(gridTop)
                }
            }
        })
    }
}
