package app.smallthingz.dict

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.viewinterop.AndroidView
import kotlin.math.ceil
import kotlin.math.roundToInt

// Optional diagnostics stay outside the authored text and accessibility stream.
internal val LocalNativeFloatContextFailureObserver = staticCompositionLocalOf<((String) -> Unit)?> { null }

internal sealed interface NativeFloatContextSpec {
    data class Text(val prepared: PreparedNativeFloatText, val gapAfter: Float, val path: String? = null,
        val box: ParagraphBox? = null) : NativeFloatContextSpec
    data class Flow(val id: Int, val gapAfter: Float, val path: String?, val box: ParagraphBox?,
        val empty: Boolean,
        val content: @Composable (List<NativeFloatExclusion>, (NativeAnonymousFlowGeometry) -> Unit) -> Unit,
    ) : NativeFloatContextSpec
    /** width is the existing renderer's actual viewport allocation at the ORIGINAL parent width. */
    data class Child(val id: Int, val width: (Int) -> Int, val gapAfter: Float,
        val floatSide: TableFloatSide? = null, val margins: (Int) -> FloatMargins = { FloatMargins(0f, 0f, 0f, 0f) },
        val requiresUnobstructedText: Boolean = false, val gapBefore: Float = 0f,
        val clear: FigureClear? = null, val logicalObject: Boolean = true,
        val atomicInline: Boolean = false, val widthFromContent: Boolean = false,
        val preferredWidth: (Int) -> Int? = { null }, val overflowViewport: Boolean = false) : NativeFloatContextSpec
}

/** Keep an unavailable fallback within both the parent's bounds and Compose's packed range. */
internal fun nativeFallbackHeight(constraints: Constraints, contentHeight: Long): Int {
    require(constraints.hasBoundedWidth && contentHeight >= 0L)
    val capacity = Constraints.fitPrioritizingWidth(minWidth = constraints.maxWidth, maxWidth = constraints.maxWidth,
        minHeight = 0, maxHeight = Int.MAX_VALUE - 1).maxHeight
    return contentHeight.coerceIn(constraints.minHeight.toLong(), minOf(constraints.maxHeight, capacity).toLong()).toInt()
}

/** Real child compositions are shared by intrinsic queries, normal placement and fallback. */
@Composable
internal fun NativeFloatContextLayout(
    parts: List<NativeFloatContextSpec>, modifier: Modifier, linkColor: Color, containAtEnd: Boolean = true,
    revealIndex: Int? = null, revealToken: Any? = null, onRevealed: () -> Unit = {},
    child: @Composable (id: Int, originalContainingWidth: NativeLayoutInput<Int>) -> Unit,
) {
    val loading = parts.filterIsInstance<NativeFloatContextSpec.Text>().firstOrNull { it.prepared.geometry == null }
    Box(modifier.fillMaxWidth()) {
        if (loading != null) Text(loading.prepared.stateDescription ?: "Loading text layout")
        else {
            val slots = parts.withIndex().filter { it.value !is NativeFloatContextSpec.Text }
            val widths = mutableMapOf<Int, NativeLayoutInput<Int>>()
            val flows = mutableMapOf<Int, NativeFlowMeasureInput>()
            slots.forEach { (index, part) -> androidx.compose.runtime.key(part::class, when (part) {
                is NativeFloatContextSpec.Child -> part.id
                is NativeFloatContextSpec.Flow -> part.id
                else -> error("Text has no child slot")
            }) {
                when (part) {
                    is NativeFloatContextSpec.Child -> widths[index] = remember { NativeLayoutInput(0) }
                    is NativeFloatContextSpec.Flow -> flows[index] = remember { NativeFlowMeasureInput() }
                    else -> Unit
                }
            } }
            val auxiliary = remember { NativeLayoutInput<NativeContextPass?>(null) }
            Layout(modifier = Modifier.fillMaxWidth(), content = {
                slots.forEach { (index, part) -> androidx.compose.runtime.key(part::class, when (part) {
                    is NativeFloatContextSpec.Child -> part.id
                    is NativeFloatContextSpec.Flow -> part.id
                    else -> error("Text has no child slot")
                }) {
                    when (part) {
                        is NativeFloatContextSpec.Child -> Box { child(part.id, widths.getValue(index)) }
                        is NativeFloatContextSpec.Flow -> {
                            val input = flows.getValue(index)
                            androidx.compose.runtime.CompositionLocalProvider(LocalNativeFlowMeasureInput provides input) {
                                Box {
                                    part.content(input.carried) { input.geometry = it }
                                }
                            }
                        }
                        else -> Unit
                    }
                } }
                NativeFloatAuxiliary(auxiliary, parts, linkColor, revealIndex, revealToken, onRevealed)
            }, measurePolicy = object : MeasurePolicy {
                private fun width(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
                    val childWidths = slots.mapIndexed { slot, row -> row.index to
                        if (maximum) measurables[slot].maxIntrinsicWidth(Constraints.Infinity)
                        else measurables[slot].minIntrinsicWidth(Constraints.Infinity) }.toMap()
                    var used = 0L
                    var floatLine = 0L
                    for ((index, part) in parts.withIndex()) {
                        val content = when (part) {
                            is NativeFloatContextSpec.Text -> {
                                val native = part.prepared.native ?: return Constraints.Infinity
                                val range = nativeTextWidthRange(native.source(TablePixelLimit), native.paint, native.horizontalInsets)
                                if (maximum) range.maximum else range.minimum
                            }
                            else -> childWidths.getValue(index)
                        }
                        val box = when (part) {
                            is NativeFloatContextSpec.Text -> part.box
                            is NativeFloatContextSpec.Flow -> part.box
                            else -> null
                        }
                        val edges = box?.let { kotlin.math.ceil(it.contentLeft + it.contentRight).toLong() } ?: 0L
                        val own = content.toLong() + edges
                        if (part is NativeFloatContextSpec.Child && part.floatSide != null) {
                            if (part.clear != null && part.clear != FigureClear.None) floatLine = 0L
                            val margins = part.margins(0)
                            val extent = own + kotlin.math.ceil(margins.left + margins.right).toLong()
                            floatLine = if (maximum) floatLine + extent else maxOf(floatLine, extent)
                            used = maxOf(used, floatLine)
                        } else {
                            used = maxOf(used, if (maximum) floatLine + own else maxOf(floatLine, own))
                            if (part is NativeFloatContextSpec.Child && part.requiresUnobstructedText) floatLine = 0L
                        }
                    }
                    return if (used > TablePixelLimit) Constraints.Infinity else used.toInt()
                }
                override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = width(measurables, false)
                override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = width(measurables, true)

                override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                    val width = constraints.maxWidth.takeIf { constraints.hasBoundedWidth && it > 0 }
                    val childMeasurables = slots.mapIndexed { slot, row -> row.index to measurables[slot] }.toMap()
                    val measured = mutableMapOf<Int, Placeable>()
                    val requests = mutableMapOf<Int, Constraints>()
                    val attempted = mutableSetOf<Int>()
                    val failed = mutableMapOf<Int, UnsupportedFloatLayout>()
                    fun measurePart(index: Int, childConstraints: Constraints): Placeable {
                        measured[index]?.let {
                            if (requests[index] != childConstraints) throw UnsupportedFloatLayout("A native child requires two different measurements")
                            return it
                        }
                        failed[index]?.let { throw it }
                        check(attempted.add(index)) { "A native child was measured twice in one pass" }
                        requests[index] = childConstraints
                        return try { childMeasurables.getValue(index).measure(childConstraints).also { measured[index] = it } }
                        catch (failure: UnsupportedFloatLayout) { failed[index] = failure; throw failure }
                    }
                    widths.values.forEach { it.update(width ?: 0) }
                    val result = try {
                        if (width == null) throw UnsupportedFloatLayout("Floated table layout needs a bounded width")
                        val specifications = parts.mapIndexed { index, part -> when (part) {
                            is NativeFloatContextSpec.Text -> NativeFloatContextPart.Text(part.prepared.text,
                                { available, carried -> part.prepared.geometry!!(available, carried, false) }, part.gapAfter, part.box)
                            is NativeFloatContextSpec.Flow -> NativeFloatContextPart.Flow(part.id, { available, carried ->
                                val input = flows.getValue(index)
                                if (index in attempted && input.exclusions.value != carried)
                                    throw UnsupportedFloatLayout("An anonymous child requires two exclusion contexts")
                                input.exclusions.update(carried)
                                val placeable = measurePart(index, Constraints(minWidth = available, maxWidth = available))
                                val geometry = input.geometry ?: throw UnsupportedFloatLayout("Anonymous child geometry is not ready")
                                if (geometry.width != placeable.width || geometry.height != placeable.height)
                                    throw UnsupportedFloatLayout("Anonymous child measurement differs from its geometry")
                                geometry
                            }, part.gapAfter, part.box, part.empty)
                            is NativeFloatContextSpec.Child -> {
                                val atomic = if (part.atomicInline) measurePart(index, Constraints(maxWidth = width)) else null
                                val allocated = atomic?.width ?: if (part.widthFromContent) {
                                    val measurable = childMeasurables.getValue(index)
                                    val minimum = measurable.minIntrinsicWidth(Constraints.Infinity)
                                    val maximum = measurable.maxIntrinsicWidth(Constraints.Infinity)
                                    if (minimum > TablePixelLimit || maximum < minimum)
                                        throw UnsupportedFloatLayout("Rich child intrinsic width exceeds the native range")
                                    val margins = part.margins(width)
                                    val available = (width - ceil(margins.left + margins.right).toInt()).coerceAtLeast(0)
                                    val used = maxOf(minimum, part.preferredWidth(width) ?: minOf(available, maximum))
                                    // Only a top-level scrolling table has a viewport distinct from its
                                    // real overwide grid. Nested grids stay on their outer table's surface.
                                    if (part.overflowViewport) minOf(available, used) else used
                                } else part.width(width).coerceAtLeast(1)
                                NativeFloatContextPart.Child(part.id, NativeBlockWidth.FixedPx(allocated.toFloat()), { request ->
                                    val childWidth = ceil(request.requestedWidth ?: allocated.toFloat()).toInt()
                                    val placeable = atomic ?: measurePart(index, Constraints(minWidth = childWidth, maxWidth = childWidth))
                                    NativeBlockMeasure(placeable.width.toFloat(), placeable.width.toFloat(), placeable.height.toFloat())
                                }, part.gapAfter, part.floatSide, part.margins(width), part.requiresUnobstructedText,
                                    part.gapBefore, part.clear, part.logicalObject)
                            }
                        } }
                        val geometry = NativeFloatContextGeometry.build(width, specifications, containAtEnd)
                        try { Constraints.fixed(width, geometry.height) }
                        catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Context exceeds the native Compose measurement range") }
                        Result.success(geometry)
                    } catch (failure: UnsupportedFloatLayout) { Result.failure(failure) }
                    if (result.isFailure && width != null) slots.forEach { (index, part) ->
                        if (index !in attempted) {
                            if (part is NativeFloatContextSpec.Flow) flows.getValue(index).exclusions.update(emptyList())
                            try { measurePart(index, Constraints(maxWidth = width)) }
                            catch (_: UnsupportedFloatLayout) { }
                        }
                    }
                    val flowGeometry = flows.mapNotNull { (index, input) ->
                        val placeable = measured[index]
                        input.geometry?.takeIf { placeable != null && it.width == placeable.width && it.height == placeable.height }
                            ?.let { index to it }
                    }.toMap()
                    val pass = NativeContextPass(width, result, measured.mapValues { it.value.height }, failed, flowGeometry)
                    auxiliary.update(pass)
                    val surface = measurables.last().measure(constraints)
                    return layout(surface.width, surface.height) {
                        val geometry = result.getOrNull()
                        if (geometry == null) {
                            pass.fallbackTops.forEach { (index, top) ->
                                if (parts[index] is NativeFloatContextSpec.Flow && top < surface.height)
                                    measured[index]?.placeRelative(0, top.toInt())
                            }
                            surface.place(0, 0)
                            pass.fallbackTops.forEach { (index, top) ->
                                if (parts[index] is NativeFloatContextSpec.Child && top < surface.height)
                                    measured[index]?.placeRelative(0, top.toInt())
                            }
                        } else {
                            geometry.flowChildren.forEach { placed ->
                                val index = parts.indexOfFirst { it is NativeFloatContextSpec.Flow && it.id == placed.id }
                                measured.getValue(index).placeWithLayer(0, 0) {
                                    translationX = placed.bounds.left; translationY = placed.bounds.top
                                }
                            }
                            surface.place(0, 0)
                            geometry.children.forEach { placed ->
                                val index = parts.indexOfFirst { it is NativeFloatContextSpec.Child && it.id == placed.id }
                                measured.getValue(index).place(placed.bounds.left.roundToInt(), placed.bounds.top.roundToInt())
                            }
                        }
                    }
                }
            })
        }
        parts.filterIsInstance<NativeFloatContextSpec.Text>().forEach { it.prepared.menu() }
    }
}

private class NativeContextPass(val width: Int?, val result: Result<NativeFloatContextGeometry>,
    val heights: Map<Int, Int>, val failures: Map<Int, UnsupportedFloatLayout>,
    val flowGeometry: Map<Int, NativeAnonymousFlowGeometry>) {
    val fallbackTops = linkedMapOf<Int, Long>()
}

/** Only native surfaces and failure text are subcomposed; live child controls stay in their slots. */
@Composable
private fun NativeFloatAuxiliary(input: NativeLayoutInput<NativeContextPass?>, parts: List<NativeFloatContextSpec>,
    linkColor: Color, revealIndex: Int?, revealToken: Any?, onRevealed: () -> Unit) {
    SubcomposeLayout(input.modifier.fillMaxWidth()) { constraints ->
        val pass = checkNotNull(input.value)
        val geometry = pass.result.getOrNull()
        if (geometry == null) {
            val reason = pass.result.exceptionOrNull()?.message ?: "Float geometry unavailable"
            val message = subcompose("unsupported-flow") {
                val observer = LocalNativeFloatContextFailureObserver.current
                LaunchedEffect(reason, observer) { observer?.invoke(reason) }
                ReaderLayoutUnavailable(reason)
            }.single().measure(constraints)
            val fallback = linkedMapOf<Int, Placeable>()
            if (pass.width != null) parts.forEachIndexed { index, part ->
                if (index !in pass.heights) {
                    fallback[index] = subcompose("fallback-part-$index") {
                        val failure = pass.failures[index]
                        if (failure != null) ReaderLayoutUnavailable(failure.message ?: "Child measurement unavailable")
                        else if (part is NativeFloatContextSpec.Text) part.prepared.fallback()
                    }.single().measure(Constraints(maxWidth = pass.width))
                }
            }
            var top = message.height.toLong()
            parts.indices.forEach { index ->
                pass.fallbackTops[index] = top
                top += (pass.heights[index] ?: fallback[index]?.height ?: 0).toLong()
            }
            val height = if (constraints.hasBoundedWidth) nativeFallbackHeight(constraints, top)
                else constraints.constrainHeight(top.coerceAtMost(TablePixelLimit.toLong()).toInt())
            val flowOwners = pass.flowGeometry.mapValues { (index, flow) ->
                subcompose("fallback-flow-$index") {
                    AndroidView(factory = { NativeFloatTextView(it) }, update = { view ->
                        view.bind({ measuredWidth -> check(measuredWidth == flow.width); NoPaintGeometry(flow) },
                            linkColor.copy(alpha = .25f).toArgb(), linkColor.toArgb())
                    })
                }.single().measure(Constraints.fixed(flow.width, flow.height))
            }
            layout(message.width, height) {
                message.place(0, 0)
                fallback.forEach { (index, item) ->
                    val y = pass.fallbackTops.getValue(index)
                    if (y < height) item.placeRelative(0, y.toInt())
                }
                flowOwners.forEach { (index, owner) ->
                    val y = pass.fallbackTops.getValue(index)
                    if (y < height) owner.placeRelative(0, y.toInt())
                }
            }
        } else {
            val state = parts.filterIsInstance<NativeFloatContextSpec.Text>().mapNotNull { it.prepared.stateDescription }
                .distinct().joinToString(". ").ifEmpty { null }
            val text = subcompose("native-context") {
                var nativeView by remember { mutableStateOf<NativeFloatTextView?>(null) }
                LaunchedEffect(revealToken, revealIndex, geometry.text.toString()) {
                    if (revealIndex != null) {
                        withFrameNanos { }
                        if (nativeView?.revealLogicalOffset(geometry.partOffsets[revealIndex]) == true) onRevealed()
                    }
                }
                AndroidView(factory = { NativeFloatTextView(it).also { view -> nativeView = view } }, update = { view ->
                    view.bind({ measuredWidth -> check(measuredWidth == geometry.width); geometry },
                        linkColor.copy(alpha = .25f).toArgb(), linkColor.toArgb(), state)
                })
            }.single().measure(Constraints.fixed(geometry.width, geometry.height))
            layout(geometry.width, geometry.height) { text.place(0, 0) }
        }
    }
}
