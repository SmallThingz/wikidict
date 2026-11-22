package app.smallthingz.dict

import android.graphics.RectF
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import kotlin.math.floor

internal class CaptionCellSlot(val content: @Composable (SelectionGeometrySink) -> Unit) {
    var geometry: FloatTextGeometry? = null
}

/** A semantic caption block keeps its real child available to table-width queries. */
@Composable
internal fun FigureCaptionBlock(block: Block, previous: Block?, trailingGap: Boolean,
    context: AnonymousFlowContext, style: TextStyle, reader: FigureReaderContext,
    sink: SelectionGeometrySink, gapDp: Float = 6f,
    consumeVerticalMargins: Boolean = false, ruleMetrics: NativeRuleMetrics? = null) {
    if (consumeVerticalMargins) {
        AdjoiningCaptionBlock(block, context, style, reader, sink, ruleMetrics)
        return
    }
    val semanticMeasurement = rememberNativeSemanticMeasurement()
    val captionInput = LocalStaticCaptionInput.current
    val childCaptionInput = remember(captionInput) { StaticCaptionInput() }
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val gap = if (trailingGap) gapDp * density.density else 0f
    val preserveCompiledText = LocalNativeContainerTextContext.current?.fontFamily is ContainerFontFamily.Stack
    val box = if (block.style == null) null else paragraphBox(block, previous, gap, density.density, bodyPixels, preserveCompiledText)
    val prefix = blockPrefix(block)
    val indent = blockIndentDp(block) * density.density
    val childContext = context.copy(textAlign = block.textAlign ?: context.textAlign)
    val childStyle = when (block.kind) {
        "term" -> style.copy(fontWeight = FontWeight.Bold)
        "heading" -> style.copy(fontWeight = FontWeight.SemiBold)
        "preformatted" -> style.copy(fontFamily = FontFamily.Monospace)
        else -> style
    }
    val spans = when {
        preserveCompiledText || block.kind == "preformatted" -> block.spans
        block.style != null -> paragraphDisplaySpans(block)
        else -> ordinaryInlineDisplaySpans(block)
    }
    val geometry = remember { arrayOfNulls<FloatTextGeometry>(1) }
    val publishChild: SelectionGeometrySink = { if (geometry[0] !== it) { geometry[0] = it; semanticMeasurement.changed() } }
    val left = box?.contentLeft ?: 0f
    val right = box?.contentRight ?: 0f
    val top = (box?.before ?: 0f) + (box?.padding?.top ?: 0f)
    val bottom = (box?.after ?: gap) + (box?.padding?.bottom ?: 0f)
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semanticMeasurement) {
    Layout(modifier = semanticMeasurement.modifier.then(captionInput?.modifier ?: Modifier).fillMaxWidth(), content = {
        if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp),
            style = inheritedCellTextStyle(MaterialTheme.typography.labelMedium),
            color = nativeMarkedCellForeground()?.let { androidx.compose.ui.graphics.Color(it) } ?: MaterialTheme.colorScheme.primary)
        CompositionLocalProvider(LocalStaticCaptionInput provides childCaptionInput.takeIf { captionInput != null }) { when {
            block.table != null -> FigureCaptionTable(block.table, childContext, childStyle, reader, publishChild)
            block.container != null -> UnavailableSelectionContent("Caption container needs its original child selection geometry", publishChild)
            block.feature != null -> UnavailableSelectionContent("Caption feature needs its structured selection geometry", publishChild)
            block.kind == "preformatted" -> UnavailableSelectionContent("Preformatted caption needs its horizontal selection viewport", publishChild)
            block.kind == "rule" -> SelectionRule(publishChild)
            block.figure == null && block.flow == null && spans.isEmpty() -> SelectionEmptyBox(sink = publishChild)
            else -> AnonymousBlockView(if (block.figure != null || block.flow != null) block else Block("paragraph", 0, spans),
                Modifier, reader.onLink, reader.media, reader.settings, reader.edition,
                inherited = childContext, style = childStyle, onGeometry = publishChild, interactionOwner = false,
                nativeLineHeight = inheritedContainerFormat()?.takeIf { LocalNativeContainerTextContext.current?.cellText != null }?.lineHeight)
        } }
    }, measurePolicy = object : MeasurePolicy {
        private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
            val content = measurables.sumOf { if (maximum) it.maxIntrinsicWidth(Constraints.Infinity).toLong()
                else it.minIntrinsicWidth(Constraints.Infinity).toLong() }
            val width = content + kotlin.math.ceil(left + right + indent).toLong()
            return if (width > TablePixelLimit) Constraints.Infinity else width.toInt()
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semanticMeasurement.measure { try {
            if (!constraints.hasBoundedWidth) throw UnsupportedFloatLayout("Caption block needs a bounded width")
            val width = constraints.maxWidth
            val available = floor(width - left - right - indent).toInt()
            if (available < 0) throw UnsupportedFloatLayout("Caption block edges exceed its containing width")
            val marker = if (prefix.isEmpty()) null else measurables.first().measure(Constraints(maxWidth = available))
            val markerWidth = marker?.width ?: 0
            val rtl = context.direction == BidiResolvedDirection.Rtl
            val childX = left + if (rtl) 0f else indent + markerWidth
            captionInput?.let { childCaptionInput.update(it.exclusions, childX, top) }
            val child = measurables.last().measure(Constraints.fixedWidth(available - markerWidth))
            val exact = geometry[0] ?: throw UnsupportedFloatLayout("Caption block geometry is not ready")
            if (exact.width != child.width || exact.height != child.height)
                throw UnsupportedFloatLayout("Caption block geometry differs from its measured child")
            val height = figureCoordinate(top.toDouble() + maxOf(child.height, marker?.height ?: 0) + bottom)
            if (height > constraints.maxHeight) throw UnsupportedFloatLayout("Caption block exceeds its available height")
            val markerX = if (rtl) width - right - indent - markerWidth else left + indent
            val markerNodes = if (marker == null) emptyList() else listOf(FloatInteractionNode(0,
                FloatInteractionKind.MARKER, 0, 0, listOf(RectF(markerX, top, markerX + marker.width, top + marker.height)), prefix, null, null))
            sink(NativeSemanticGroup(width, height,
                listOf(PositionedSemanticChild(NoPaintGeometry(exact), childX, top, context.direction)), extraNodes = markerNodes))
            layout(width, height) {
                marker?.placeWithLayer(0, 0) { translationX = markerX; translationY = top }
                child.placeWithLayer(0, 0) { translationX = childX; translationY = top }
            }
        } catch (_: UnsupportedFloatLayout) { unavailableSelection(constraints, sink) } }
    })
    }
}

/** Only the admitted adjoining caption path supplies an unrounded content height. */
internal class CaptionAdjoiningGeometry(private val source: FloatTextGeometry, val usedHeight: Float,
    override val extents: NativeGeometryExtents) : FloatTextGeometry by source
internal class CaptionRetainedGeometry(source: FloatTextGeometry) : FloatTextGeometry by source

@Composable
private fun AdjoiningCaptionBlock(block: Block, context: AnonymousFlowContext, style: TextStyle,
    reader: FigureReaderContext, sink: SelectionGeometrySink, ruleMetrics: NativeRuleMetrics?) {
    val semantic = rememberNativeSemanticMeasurement()
    val captionInput = LocalStaticCaptionInput.current
    val childInput = remember(block, captionInput) { StaticCaptionInput() }
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val preserveCompiledText = LocalNativeContainerTextContext.current?.fontFamily is ContainerFontFamily.Stack
    val box = if (ruleMetrics == null) paragraphBox(block, null, 0f, density.density, bodyPixels, preserveCompiledText) else null
    val left = box?.contentLeft ?: 0f
    val right = box?.contentRight ?: 0f
    val top = box?.padding?.top ?: 0f
    val bottom = box?.padding?.bottom ?: 0f
    val empty = ruleMetrics == null && !paragraphHasContent(block, preserveCompiledText)
    val geometry = remember(block) { arrayOfNulls<FloatTextGeometry>(1) }
    val fallback = remember(block) { NativeLayoutInput<String?>(null) }
    val publish: SelectionGeometrySink = { if (geometry[0] !== it) { geometry[0] = it; semantic.changed() } }
    DisposableEffect(block) { onDispose { geometry[0] = null; sink(null) } }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semantic) {
    Layout(modifier = semantic.modifier.then(captionInput?.modifier ?: Modifier).fillMaxWidth(), content = {
        CompositionLocalProvider(LocalStaticCaptionInput provides childInput.takeIf { captionInput != null }) {
            when {
                ruleMetrics != null -> AuthoredRuleSurface(ruleMetrics, sink = publish, includeVerticalMargins = false)
                empty -> SelectionEmptyBox(sink = publish)
                else -> AnonymousBlockView(Block("paragraph", 0,
                    if (preserveCompiledText) block.spans else paragraphDisplaySpans(block)), Modifier,
                    reader.onLink, reader.media, reader.settings, reader.edition,
                    inherited = context.copy(textAlign = block.textAlign ?: context.textAlign), style = style,
                    onGeometry = publish, interactionOwner = false,
                    nativeLineHeight = inheritedContainerFormat()?.takeIf {
                        LocalNativeContainerTextContext.current?.cellText != null }?.lineHeight)
            }
        }
        // Only a child which could not return a retained Placeable uses a source projection.
        SubcomposeLayout(fallback.modifier) { constraints ->
            val reason = fallback.value
            if (reason == null) layout(0, 0) { }
            else {
                val source = subcompose("source") {
                    UnavailableAnonymousContent(block, Modifier, reason, style, reader, showWarning = false)
                }.single().measure(constraints)
                layout(source.width, source.height) { source.place(0, 0) }
            }
        }
    }, measurePolicy = object : MeasurePolicy {
        private fun intrinsic(child: IntrinsicMeasurable, maximum: Boolean): Int {
            val width = (if (maximum) child.maxIntrinsicWidth(Constraints.Infinity)
                else child.minIntrinsicWidth(Constraints.Infinity)).toDouble() + left + right
            return if (!width.isFinite() || width > TablePixelLimit) Constraints.Infinity else kotlin.math.ceil(width).toInt()
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables.first(), false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables.first(), true)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semantic.measure {
            var retained: androidx.compose.ui.layout.Placeable? = null
            var current: FloatTextGeometry? = null
            fun unavailable(reason: String): MeasureResult {
                val child = retained
                val exact = current
                if (child != null && (exact == null || exact.width == child.width && exact.height == child.height)) {
                    val width = constraints.maxWidth
                    val height = nativeFallbackHeight(constraints, kotlin.math.ceil(top.toDouble() + child.height + bottom).toLong())
                    val group = exact?.let { NativeSemanticGroup(width, height,
                        listOf(PositionedSemanticChild(NoPaintGeometry(it), left, top, context.direction))) }
                    // This marker is only for the failed column's local action overlay.
                    sink(group?.let(::CaptionRetainedGeometry))
                    fallback.update(null)
                    val auxiliary = measurables.last().measure(Constraints.fixed(0, 0))
                    return layout(width, height) {
                        child.placeWithLayer(0, 0) { translationX = left; translationY = top }
                        auxiliary.place(0, 0)
                    }
                }
                sink(null); geometry[0] = null
                fallback.update(reason)
                val source = measurables.last().measure(Constraints.fitPrioritizingWidth(
                    minWidth = 0, maxWidth = constraints.maxWidth, minHeight = 0, maxHeight = constraints.maxHeight))
                return layout(source.width, source.height) { source.place(0, 0) }
            }
            try {
                if (!constraints.hasBoundedWidth) throw UnsupportedFloatLayout("Authored caption needs its containing width")
                val width = constraints.maxWidth
                val available = floor(width.toDouble() - left - right)
                if (available < 0.0 || available > TablePixelLimit)
                    throw UnsupportedFloatLayout("Caption paragraph edges exceed its containing width")
                val childConstraints = Constraints.fixedWidth(available.toInt())
                captionInput?.let { childInput.update(it.exclusions, left, top) }
                if (ruleMetrics != null && ruleMetrics.positive && captionInput != null) {
                    val ruleLeft = ruleMetrics.margins.left
                    val ruleWidth = ruleMetrics.contentWidth(available.toFloat())
                    if (ruleWidth > 0f && childInput.exclusions.any { exclusion ->
                        val outer = exclusion.outer
                        outer.right > ruleLeft && outer.left < ruleLeft + ruleWidth &&
                            outer.bottom > 0f && outer.top < ruleMetrics.height
                    }) throw UnsupportedFloatLayout("Authored caption rule overlaps an existing float")
                }
                val child = measurables.first().measure(childConstraints)
                retained = child
                val exact = geometry[0]
                current = exact
                if (exact == null) {
                    // The native child already returned its original-source unavailable UI.
                    return@measure unavailable("Authored caption child geometry is unavailable")
                }
                if (exact.width != child.width || exact.height != child.height)
                    throw UnsupportedFloatLayout("Authored caption child geometry differs from its measured body")
                val contentHeight = when {
                    ruleMetrics != null -> ruleMetrics.height
                    empty -> 0f
                    exact is NativeAnonymousFlowGeometry -> exact.textBottom
                    else -> throw UnsupportedFloatLayout("Caption paragraph has no exact native content height")
                }
                val usedHeight = top + contentHeight + bottom
                val height = figureCoordinate(usedHeight)
                if (height < constraints.minHeight || height > constraints.maxHeight)
                    throw UnsupportedFloatLayout("Authored caption exceeds its available height")
                Constraints.fixed(width, height)
                val group = NativeSemanticGroup(width, height,
                    listOf(PositionedSemanticChild(NoPaintGeometry(exact), left, top, context.direction)))
                val published = CaptionAdjoiningGeometry(group, usedHeight, NativeGeometryExtents(width, usedHeight,
                    exact.extents.ink?.translated(left, top), exact.extents.interaction?.translated(left, top)))
                fallback.update(null)
                val auxiliary = measurables.last().measure(Constraints.fixed(0, 0))
                sink(published)
                layout(width, height) {
                    child.placeWithLayer(0, 0) { translationX = left; translationY = top }
                    auxiliary.place(0, 0)
                }
            } catch (failure: UnsupportedFloatLayout) {
                unavailable(failure.message ?: "Authored caption is unavailable")
            } catch (_: IllegalArgumentException) {
                unavailable("Authored caption exceeds native measurement range")
            }
        }
    })
    }
}

@Composable
internal fun UnavailableSelectionContent(reason: String, sink: SelectionGeometrySink) {
    val semanticMeasurement = rememberNativeSemanticMeasurement()
    Layout(modifier = semanticMeasurement.modifier, content = { ReaderLayoutUnavailable(reason) }, measurePolicy = object : MeasurePolicy {
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
            val message = measurables.single().measure(constraints)
            sink(null)
            return layout(message.width, message.height) { message.place(0, 0) }
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = Constraints.Infinity
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = Constraints.Infinity
    })
}

@Composable
private fun SelectionRule(sink: SelectionGeometrySink) {
    val semanticMeasurement = rememberNativeSemanticMeasurement()
    val height = with(LocalDensity.current) { 1.dp.roundToPx() }.coerceAtLeast(1)
    Layout(content = { HorizontalDivider() }, modifier = semanticMeasurement.modifier.fillMaxWidth(), measurePolicy = object : MeasurePolicy {
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
            val width = constraints.maxWidth
            val rule = measurables.single().measure(Constraints.fixed(width, height))
            sink(NativeSemanticGroup(width, height, emptyList()))
            return layout(width, height) { rule.place(0, 0) }
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = 0
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = 0
    })
}

@Composable
internal fun SelectionInsetsBox(left: Int, top: Int, right: Int, bottom: Int,
    direction: BidiResolvedDirection, sink: SelectionGeometrySink,
    content: @Composable (SelectionGeometrySink) -> Unit) {
    val semanticMeasurement = rememberNativeSemanticMeasurement()
    val geometry = remember { arrayOfNulls<FloatTextGeometry>(1) }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semanticMeasurement) {
    Layout(content = { content { if (geometry[0] !== it) { geometry[0] = it; semanticMeasurement.changed() } } },
        modifier = semanticMeasurement.modifier.fillMaxWidth(), measurePolicy = object : MeasurePolicy {
        private fun intrinsic(measurable: IntrinsicMeasurable, maximum: Boolean): Int {
            val child = if (maximum) measurable.maxIntrinsicWidth(Constraints.Infinity) else measurable.minIntrinsicWidth(Constraints.Infinity)
            val width = child.toLong() + left + right
            return if (width > TablePixelLimit) Constraints.Infinity else width.toInt()
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables.single(), false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables.single(), true)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semanticMeasurement.measure { try {
            if (!constraints.hasBoundedWidth || listOf(left, top, right, bottom).any { it < 0 } || left.toLong() + right > constraints.maxWidth)
                throw UnsupportedFloatLayout("Caption edges exceed available width")
            val width = constraints.maxWidth
            val child = measurables.single().measure(Constraints.fixedWidth(width - left - right))
            val exact = geometry[0] ?: throw UnsupportedFloatLayout("Caption edge child geometry is unavailable")
            if (exact.width != child.width || exact.height != child.height) throw UnsupportedFloatLayout("Caption edge geometry mismatch")
            val height = figureCoordinate(top.toDouble() + child.height + bottom)
            if (height > constraints.maxHeight) throw UnsupportedFloatLayout("Caption edges exceed available height")
            sink(NativeSemanticGroup(width, height, listOf(PositionedSemanticChild(NoPaintGeometry(exact), left.toFloat(), top.toFloat(), direction))))
            layout(width, height) { child.place(left, top) }
        } catch (_: UnsupportedFloatLayout) { unavailableSelection(constraints, sink) } }
    })
    }
}

@Composable
internal fun SelectionGridBox(direction: BidiResolvedDirection, sink: SelectionGeometrySink,
    content: @Composable (NativeLayoutInput<Int>, SelectionGeometrySink) -> Unit) {
    val semanticMeasurement = rememberNativeSemanticMeasurement()
    val widthInput = remember { NativeLayoutInput(0) }
    val geometry = remember { arrayOfNulls<FloatTextGeometry>(1) }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semanticMeasurement) {
    Layout(content = { content(widthInput) { if (geometry[0] !== it) { geometry[0] = it; semanticMeasurement.changed() } } },
        modifier = semanticMeasurement.modifier.fillMaxWidth(), measurePolicy = object : MeasurePolicy {
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = measurables.single().minIntrinsicWidth(height)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = measurables.single().maxIntrinsicWidth(height)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semanticMeasurement.measure { try {
            if (!constraints.hasBoundedWidth) throw UnsupportedFloatLayout("Caption table needs bounded width")
            val width = constraints.maxWidth
            widthInput.update(width)
            val child = measurables.single().measure(Constraints(maxWidth = width))
            val exact = geometry[0] ?: throw UnsupportedFloatLayout("Caption table selection geometry is unavailable")
            if (exact.width > width) throw UnsupportedFloatLayout("Caption table exceeds its figure width")
            if (exact.width != child.width || exact.height != child.height) throw UnsupportedFloatLayout("Caption table measured geometry mismatch")
            if (child.height > constraints.maxHeight) throw UnsupportedFloatLayout("Caption table exceeds available height")
            val left = if (direction == BidiResolvedDirection.Ltr) 0 else width - child.width
            sink(NativeSemanticGroup(width, child.height, listOf(PositionedSemanticChild(NoPaintGeometry(exact), left.toFloat(), 0f, direction))))
            layout(width, child.height) { child.place(left, 0) }
        } catch (_: UnsupportedFloatLayout) { unavailableSelection(constraints, sink) } }
    })
    }
}
