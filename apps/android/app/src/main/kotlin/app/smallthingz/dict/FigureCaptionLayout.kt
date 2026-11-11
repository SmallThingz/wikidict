package app.smallthingz.dict

import android.graphics.RectF
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
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
    sink: SelectionGeometrySink, gapDp: Float = 6f) {
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val gap = if (trailingGap) gapDp * density.density else 0f
    val box = if (block.style == null) null else paragraphBox(block, previous, gap, density.density, bodyPixels)
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
        block.kind == "preformatted" -> block.spans
        block.style != null -> paragraphDisplaySpans(block)
        else -> ordinaryInlineDisplaySpans(block)
    }
    val geometry = remember { arrayOfNulls<FloatTextGeometry>(1) }
    val left = box?.contentLeft ?: 0f
    val right = box?.contentRight ?: 0f
    val top = (box?.before ?: 0f) + (box?.padding?.top ?: 0f)
    val bottom = (box?.after ?: gap) + (box?.padding?.bottom ?: 0f)
    Layout(modifier = Modifier.fillMaxWidth(), content = {
        if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp),
            style = inheritedCellTextStyle(MaterialTheme.typography.labelMedium), color = MaterialTheme.colorScheme.primary)
        when {
            block.table != null -> FigureCaptionTable(block.table, childContext, childStyle, reader) { geometry[0] = it }
            block.feature != null -> UnavailableSelectionContent("Caption feature needs its structured selection geometry") { geometry[0] = it }
            block.kind == "preformatted" -> UnavailableSelectionContent("Preformatted caption needs its horizontal selection viewport") { geometry[0] = it }
            block.kind == "rule" -> SelectionRule { geometry[0] = it }
            block.figure == null && block.flow == null && spans.isEmpty() -> SelectionEmptyBox { geometry[0] = it }
            else -> AnonymousBlockView(if (block.figure != null || block.flow != null) block else Block("paragraph", 0, spans),
                Modifier, reader.onLink, reader.media, reader.settings, reader.edition,
                inherited = childContext, style = childStyle, onGeometry = { geometry[0] = it }, interactionOwner = false)
        }
    }, measurePolicy = object : MeasurePolicy {
        private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
            val content = measurables.sumOf { if (maximum) it.maxIntrinsicWidth(Constraints.Infinity).toLong()
                else it.minIntrinsicWidth(Constraints.Infinity).toLong() }
            val width = content + kotlin.math.ceil(left + right + indent).toLong()
            return if (width > TablePixelLimit) Constraints.Infinity else width.toInt()
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = try {
            if (!constraints.hasBoundedWidth) throw UnsupportedFloatLayout("Caption block needs a bounded width")
            val width = constraints.maxWidth
            val available = floor(width - left - right - indent).toInt()
            if (available < 0) throw UnsupportedFloatLayout("Caption block edges exceed its containing width")
            val marker = if (prefix.isEmpty()) null else measurables.first().measure(Constraints(maxWidth = available))
            val markerWidth = marker?.width ?: 0
            val child = measurables.last().measure(Constraints.fixedWidth(available - markerWidth))
            val exact = geometry[0] ?: throw UnsupportedFloatLayout("Caption block geometry is not ready")
            if (exact.width != child.width || exact.height != child.height)
                throw UnsupportedFloatLayout("Caption block geometry differs from its measured child")
            val height = figureCoordinate(top.toDouble() + maxOf(child.height, marker?.height ?: 0) + bottom)
            if (height > constraints.maxHeight) throw UnsupportedFloatLayout("Caption block exceeds its available height")
            val rtl = context.direction == BidiResolvedDirection.Rtl
            val childX = left + if (rtl) 0f else indent + markerWidth
            val markerX = if (rtl) width - right - indent - markerWidth else left + indent
            val markerNodes = if (marker == null) emptyList() else listOf(FloatInteractionNode(0,
                FloatInteractionKind.MARKER, 0, 0, listOf(RectF(markerX, top, markerX + marker.width, top + marker.height)), prefix, null, null))
            sink(NativeSemanticGroup(width, height,
                listOf(PositionedSemanticChild(NoPaintGeometry(exact), childX, top, context.direction)), extraNodes = markerNodes))
            layout(width, height) {
                marker?.placeWithLayer(0, 0) { translationX = markerX; translationY = top }
                child.placeWithLayer(0, 0) { translationX = childX; translationY = top }
            }
        } catch (_: UnsupportedFloatLayout) { unavailableSelection(constraints, sink) }
    })
}

@Composable
internal fun UnavailableSelectionContent(reason: String, sink: SelectionGeometrySink) {
    Layout(content = { ReaderLayoutUnavailable(reason) }, measurePolicy = object : MeasurePolicy {
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
    val height = with(LocalDensity.current) { 1.dp.roundToPx() }.coerceAtLeast(1)
    Layout(content = { HorizontalDivider() }, modifier = Modifier.fillMaxWidth(), measurePolicy = object : MeasurePolicy {
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
    val geometry = remember { arrayOfNulls<FloatTextGeometry>(1) }
    Layout(content = { content { geometry[0] = it } }, modifier = Modifier.fillMaxWidth(), measurePolicy = object : MeasurePolicy {
        private fun intrinsic(measurable: IntrinsicMeasurable, maximum: Boolean): Int {
            val child = if (maximum) measurable.maxIntrinsicWidth(Constraints.Infinity) else measurable.minIntrinsicWidth(Constraints.Infinity)
            val width = child.toLong() + left + right
            return if (width > TablePixelLimit) Constraints.Infinity else width.toInt()
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables.single(), false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables.single(), true)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = try {
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
        } catch (_: UnsupportedFloatLayout) { unavailableSelection(constraints, sink) }
    })
}

@Composable
internal fun SelectionGridBox(direction: BidiResolvedDirection, sink: SelectionGeometrySink,
    content: @Composable (NativeLayoutInput<Int>, SelectionGeometrySink) -> Unit) {
    val widthInput = remember { NativeLayoutInput(0) }
    val geometry = remember { arrayOfNulls<FloatTextGeometry>(1) }
    Layout(content = { content(widthInput) { geometry[0] = it } }, modifier = Modifier.fillMaxWidth(), measurePolicy = object : MeasurePolicy {
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = measurables.single().minIntrinsicWidth(height)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = measurables.single().maxIntrinsicWidth(height)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = try {
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
        } catch (_: UnsupportedFloatLayout) { unavailableSelection(constraints, sink) }
    })
}
