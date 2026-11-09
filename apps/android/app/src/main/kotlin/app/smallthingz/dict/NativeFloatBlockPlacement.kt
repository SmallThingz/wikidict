package app.smallthingz.dict

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

/** Physical geometry; deliberately independent of Android for pure unit tests. */
internal data class NativeFloatBounds(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    init {
        require(listOf(left, top, right, bottom).all { it.isFinite() })
        require(right >= left && bottom >= top)
    }
    val width: Float get() = right - left
    val height: Float get() = bottom - top
    fun translated(dx: Float, dy: Float) = NativeFloatBounds(left + dx, top + dy, right + dx, bottom + dy)
}

/** A previous float's full margin box, never its content/ink rectangle. */
internal data class NativeFloatExclusion(val side: TableFloatSide, val outer: NativeFloatBounds)

/** Clearance consumes only earlier floats supplied by this containing flow. */
internal fun tableClearanceY(normalY: Float, clear: FigureClear?, exclusions: List<NativeFloatExclusion>): Float {
    require(normalY.isFinite() && normalY >= 0f)
    return maxOf(normalY, exclusions.filter { when (clear) {
        null, FigureClear.None -> false
        FigureClear.Left -> it.side == TableFloatSide.Left
        FigureClear.Right -> it.side == TableFloatSide.Right
        FigureClear.Both -> true
    } }.maxOfOrNull { it.outer.bottom } ?: normalY)
}

internal sealed interface NativeBlockWidth {
    data object Auto : NativeBlockWidth
    data class FixedPx(val value: Float) : NativeBlockWidth {
        init { require(value.isFinite() && value >= 0f) }
    }
    /** 100 means 100% of the original containing width. */
    data class Percent(val value: Float) : NativeBlockWidth {
        init { require(value.isFinite() && value >= 0f) }
    }
}

internal data class NativeBlockMeasureRequest(
    val containingWidth: Float,
    val availableWidth: Float,
    val requestedWidth: Float?,
)

internal data class NativeBlockMeasure(val usedWidth: Float, val minWidth: Float, val height: Float) {
    init {
        require(listOf(usedWidth, minWidth, height).all { it.isFinite() && it >= 0f })
        require(usedWidth + PlacementEpsilon >= minWidth) { "Actual block width cannot be below its intrinsic minimum" }
    }
}

internal data class NativeFloatBlockPlacement(
    val bounds: NativeFloatBounds,
    val measurement: NativeBlockMeasure,
    val availableLeft: Float,
    val availableRight: Float,
    val measurementCount: Int,
) {
    val nextY: Float get() = bounds.bottom
}

private const val PlacementEpsilon = 0.01f

/**
 * Measures a delegated table/block against the interval that is free for its
 * complete height. A requested px/% width is resolved once against the original
 * containing width. Only auto sizing receives a narrowed measurement constraint.
 * The callback must return actual height and intrinsic minimum, including whatever
 * outer spacing the caller chooses to include in this block placement.
 * With pixelAligned, integer child placement is resolved inside this loop: top
 * and left round outward/up, right rounds inward/down before checking fit.
 *
 * When no floats remain, an intrinsically overwide table is placed at x=0 with its
 * original width; the existing table renderer retains its normal overflow policy.
 */
internal fun placeNativeFloatBlock(
    containingWidth: Float,
    startY: Float,
    exclusions: List<NativeFloatExclusion>,
    widthRule: NativeBlockWidth = NativeBlockWidth.Auto,
    maxPasses: Int = 64,
    pixelAligned: Boolean = false,
    measure: (NativeBlockMeasureRequest) -> NativeBlockMeasure,
): NativeFloatBlockPlacement {
    require(containingWidth.isFinite() && containingWidth > 0f)
    require(startY.isFinite() && startY >= 0f && maxPasses > 0)
    val requested = when (widthRule) {
        NativeBlockWidth.Auto -> null
        is NativeBlockWidth.FixedPx -> widthRule.value
        is NativeBlockWidth.Percent -> (containingWidth.toDouble() * widthRule.value / 100.0).toFloat()
    }
    require(requested == null || requested.isFinite()) { "Requested block width exceeds native geometry" }
    var y = startY
    val fullAvailable = if (pixelAligned) floor(containingWidth) else containingWidth
    var available = fullAvailable
    var measured: NativeBlockMeasure? = null
    var count = 0
    val seen = mutableSetOf<List<Float>>()
    repeat(maxPasses) {
        // Recompute overlap after snapping y: the shifted full-height block may
        // now intersect a float that began just below its old bottom edge.
        if (pixelAligned) y = ceil(y)
        val request = NativeBlockMeasureRequest(containingWidth, if (requested == null) available else containingWidth, requested)
        if (requested == null || measured == null) {
            measured = measure(request)
            count++
            require(requested == null || measured!!.usedWidth + PlacementEpsilon >= requested) {
                "A fixed/percentage child was measured narrower than its original containing-width request"
            }
        }
        val size = checkNotNull(measured)
        val bottom = y + size.height
        if (!bottom.isFinite()) throw UnsupportedFloatLayout("Delegated block exceeds native geometry")
        val overlap = exclusions.filter {
            it.outer.height > 0f && it.outer.top < bottom && it.outer.bottom > y &&
                (if (it.side == TableFloatSide.Left) it.outer.right > 0f else it.outer.left < containingWidth)
        }
        val rawLeft = (overlap.filter { it.side == TableFloatSide.Left }.maxOfOrNull { it.outer.right } ?: 0f).coerceIn(0f, containingWidth)
        val rawRight = (overlap.filter { it.side == TableFloatSide.Right }.minOfOrNull { it.outer.left } ?: containingWidth).coerceIn(0f, containingWidth)
        val left = if (pixelAligned) ceil(rawLeft) else rawLeft
        val right = if (pixelAligned) floor(rawRight) else rawRight
        val free = max(0f, right - left)
        if (overlap.isEmpty() || (size.usedWidth <= free + PlacementEpsilon &&
                (requested != null || abs(available - free) <= PlacementEpsilon))) {
            return NativeFloatBlockPlacement(NativeFloatBounds(left, y, left + size.usedWidth, bottom), size, left, right, count)
        }
        val signature = listOf(y, available, size.usedWidth, size.minWidth, size.height, left, right)
        if (!seen.add(signature)) throw UnsupportedFloatLayout("Delegated block measurement and float interval cycle")
        if (requested == null && size.minWidth <= free + PlacementEpsilon && free > 0f &&
            abs(available - free) > PlacementEpsilon) {
            // Height can change after narrowing, so recompute the whole-height
            // interval before accepting this newly measured width.
            available = free
        } else {
            y = overlap.minOf { it.outer.bottom }
            available = fullAvailable
        }
    }
    throw UnsupportedFloatLayout("Delegated block did not converge after $maxPasses placement passes")
}


internal data class NativeFloatingTablePlacement(val outer: NativeFloatBounds, val content: NativeFloatBounds)

/** A nonfloating table clears at its border edge. Its positive top margin does
 * not become additional clearance or participate in the body's exclusion band. */
internal fun placeNativeClearedTable(containingWidth: Float, normalY: Float,
    exclusions: List<NativeFloatExclusion>, clear: FigureClear, margins: FloatMargins,
    widthRule: NativeBlockWidth, measure: (NativeBlockMeasureRequest) -> NativeBlockMeasure): NativeFloatingTablePlacement {
    val top = kotlin.math.ceil(margins.top); val right = kotlin.math.ceil(margins.right)
    val bottom = kotlin.math.ceil(margins.bottom); val left = kotlin.math.ceil(margins.left)
    val horizontal = left + right
    val requested = when (widthRule) {
        NativeBlockWidth.Auto -> null
        is NativeBlockWidth.FixedPx -> widthRule.value
        is NativeBlockWidth.Percent -> (containingWidth.toDouble() * widthRule.value / 100.0).toFloat()
    }
    if (!horizontal.isFinite() || !(normalY + top).isFinite() || (requested != null && !requested.isFinite()))
        throw UnsupportedFloatLayout("Cleared table exceeds native geometry")
    val start = tableClearanceY(normalY + top, clear, exclusions)
    val outerRule = requested?.let { NativeBlockWidth.FixedPx(it + horizontal) } ?: NativeBlockWidth.Auto
    var body: NativeBlockMeasure? = null
    val placed = placeNativeFloatBlock(containingWidth, start, exclusions, outerRule, pixelAligned = true) { request ->
        val measured = measure(NativeBlockMeasureRequest(containingWidth, max(0f, request.availableWidth - horizontal), requested))
        body = measured
        NativeBlockMeasure(kotlin.math.ceil(measured.usedWidth) + horizontal,
            kotlin.math.ceil(measured.minWidth) + horizontal, kotlin.math.ceil(measured.height) + bottom)
    }
    val measured = checkNotNull(body)
    val content = NativeFloatBounds(placed.bounds.left + left, placed.bounds.top,
        placed.bounds.left + left + measured.usedWidth, placed.bounds.top + measured.height)
    return NativeFloatingTablePlacement(NativeFloatBounds(placed.bounds.left, placed.bounds.top - top,
        placed.bounds.right, placed.bounds.bottom), content)
}

/** Table margins occur once, outside the delegated native table viewport. No normal-flow Y advance. */
internal fun placeNativeFloatingTable(containingWidth: Float, normalY: Float,
    exclusions: List<NativeFloatExclusion>, side: TableFloatSide, margins: FloatMargins,
    widthRule: NativeBlockWidth, measure: (NativeBlockMeasureRequest) -> NativeBlockMeasure): NativeFloatingTablePlacement {
    fun edge(value: Float) = kotlin.math.ceil(value)
    val top = edge(margins.top); val right = edge(margins.right)
    val bottom = edge(margins.bottom); val left = edge(margins.left)
    val horizontal = left + right; val vertical = top + bottom
    val requested = when (widthRule) {
        NativeBlockWidth.Auto -> null
        is NativeBlockWidth.FixedPx -> widthRule.value
        is NativeBlockWidth.Percent -> containingWidth.toDouble().times(widthRule.value).div(100).toFloat()
    }
    if (!horizontal.isFinite() || !vertical.isFinite() || (requested != null && !requested.isFinite()))
        throw UnsupportedFloatLayout("Floating table exceeds native geometry")
    val outerRule = requested?.let { NativeBlockWidth.FixedPx(it + horizontal) } ?: NativeBlockWidth.Auto
    // A later float cannot rise above an earlier float in source order, including one pushed below a blocker.
    val start = max(normalY, exclusions.maxOfOrNull { it.outer.top } ?: normalY)
    var content: NativeBlockMeasure? = null
    val placement = placeNativeFloatBlock(containingWidth, start, exclusions, outerRule, pixelAligned = true) { request ->
        val measured = measure(NativeBlockMeasureRequest(containingWidth,
            max(0f, request.availableWidth - horizontal), requested))
        content = measured
        NativeBlockMeasure(kotlin.math.ceil(measured.usedWidth) + horizontal,
            kotlin.math.ceil(measured.minWidth) + horizontal, kotlin.math.ceil(measured.height) + vertical)
    }
    val measured = checkNotNull(content)
    val x = if (side == TableFloatSide.Left) placement.availableLeft else placement.availableRight - placement.bounds.width
    val outer = NativeFloatBounds(x, placement.bounds.top, x + placement.bounds.width, placement.bounds.bottom)
    val body = NativeFloatBounds(x + left, outer.top + top, x + left + measured.usedWidth, outer.top + top + measured.height)
    return NativeFloatingTablePlacement(outer, body)
}
