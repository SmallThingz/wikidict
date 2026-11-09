package app.smallthingz.dict

import android.graphics.RectF
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.SubcomposeLayout
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

/** A semantic caption block keeps its reader-owned gap and publishes its exact measured edges. */
@Composable
internal fun FigureCaptionBlock(block: Block, previous: Block?, trailingGap: Boolean,
    context: AnonymousFlowContext, style: TextStyle, reader: FigureReaderContext,
    sink: SelectionGeometrySink, gapDp: Float = 6f) {
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val gap = if (trailingGap) gapDp * density.density else 0f
    val box = if (block.style == null) null else paragraphBox(block, previous, gap,
        density.density, bodyPixels)
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
    SubcomposeLayout(Modifier.fillMaxWidth()) { constraints ->
        if (!constraints.hasBoundedWidth) throw UnsupportedFloatLayout("Caption block needs a bounded width")
        val width = constraints.maxWidth
        val left = box?.contentLeft ?: 0f
        val right = box?.contentRight ?: 0f
        val top = (box?.before ?: 0f) + (box?.padding?.top ?: 0f)
        val bottom = (box?.after ?: gap) + (box?.padding?.bottom ?: 0f)
        val available = floor(width - left - right - indent).toInt()
        if (available < 0) throw UnsupportedFloatLayout("Caption block edges exceed its containing width")
        val marker = if (prefix.isEmpty()) null else subcompose("marker") {
            Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp),
                style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        }.single().measure(Constraints(maxWidth = available))
        val markerWidth = marker?.width ?: 0
        val inner = available - markerWidth
        var childGeometry: FloatTextGeometry? = null
        val child = subcompose("content") {
            when {
                block.table != null -> FigureCaptionTable(block.table, childContext, childStyle, reader) { childGeometry = it }
                block.feature != null -> throw UnsupportedFloatLayout("Caption feature needs its structured selection geometry")
                block.kind == "preformatted" -> throw UnsupportedFloatLayout("Preformatted caption needs its horizontal selection viewport")
                block.kind == "rule" -> SelectionRule(reader, childStyle) { childGeometry = it }
                block.figure == null && block.flow == null && spans.isEmpty() -> SelectionEmptyBox { childGeometry = it }
                else -> AnonymousBlockView(
                    if (block.figure != null || block.flow != null) block else Block("paragraph", 0, spans),
                    Modifier, reader.onLink, reader.media, reader.settings, reader.edition,
                    inherited = childContext, style = childStyle, onGeometry = { childGeometry = it },
                    interactionOwner = false)
            }
        }.single().measure(Constraints.fixedWidth(inner))
        val exact = childGeometry ?: throw UnsupportedFloatLayout("Caption block geometry is not ready")
        if (exact.width != child.width || exact.height != child.height)
            throw UnsupportedFloatLayout("Caption block geometry differs from its measured child")
        val contentHeight = maxOf(child.height, marker?.height ?: 0)
        val height = figureCoordinate(top.toDouble() + contentHeight + bottom)
        if (height > constraints.maxHeight) throw UnsupportedFloatLayout("Caption block exceeds its available height")
        val rtl = context.direction == BidiResolvedDirection.Rtl
        val childX = left + if (rtl) 0f else indent + markerWidth
        val markerX = if (rtl) width - right - indent - markerWidth else left + indent
        val markerNodes = if (marker == null) emptyList() else listOf(FloatInteractionNode(0,
            FloatInteractionKind.MARKER, 0, 0, listOf(RectF(markerX.toFloat(), top.toFloat(),
                (markerX + marker.width).toFloat(), (top + marker.height).toFloat())), prefix, null, null))
        sink(NativeSemanticGroup(width, height,
            listOf(PositionedSemanticChild(NoPaintGeometry(exact), childX.toFloat(), top.toFloat(), context.direction)),
            extraNodes = markerNodes))
        layout(width, height) {
            marker?.placeWithLayer(0, 0) { translationX = markerX; translationY = top }
            child.placeWithLayer(0, 0) { translationX = childX; translationY = top }
        }
    }
}

@Composable
private fun SelectionRule(reader: FigureReaderContext, style: TextStyle, sink: SelectionGeometrySink) {
    val density = LocalDensity.current
    val height = with(density) { 1.dp.roundToPx() }.coerceAtLeast(1)
    SubcomposeLayout(Modifier.fillMaxWidth()) { constraints ->
        val width = constraints.maxWidth
        val rule = subcompose("rule") { HorizontalDivider() }.single().measure(Constraints.fixed(width, height))
        sink(NativeSemanticGroup(width, height, emptyList()))
        layout(width, height) { rule.place(0, 0) }
    }
}

@Composable
internal fun SelectionInsetsBox(left: Int, top: Int, right: Int, bottom: Int,
    direction: BidiResolvedDirection, sink: SelectionGeometrySink,
    content: @Composable (SelectionGeometrySink) -> Unit) {
    SubcomposeLayout(Modifier.fillMaxWidth()) { constraints ->
        if (!constraints.hasBoundedWidth || listOf(left, top, right, bottom).any { it < 0 } ||
            left.toLong() + right > constraints.maxWidth)
            throw UnsupportedFloatLayout("Caption edges exceed available width")
        val width = constraints.maxWidth
        var geometry: FloatTextGeometry? = null
        val child = subcompose("content") { content { geometry = it } }.single()
            .measure(Constraints.fixedWidth(width - left - right))
        val exact = geometry ?: throw UnsupportedFloatLayout("Caption edge child geometry is unavailable")
        if (exact.width != child.width || exact.height != child.height)
            throw UnsupportedFloatLayout("Caption edge geometry mismatch")
        val height = figureCoordinate(top.toDouble() + child.height + bottom)
        if (height > constraints.maxHeight) throw UnsupportedFloatLayout("Caption edges exceed available height")
        sink(NativeSemanticGroup(width, height,
            listOf(PositionedSemanticChild(NoPaintGeometry(exact), left.toFloat(), top.toFloat(), direction))))
        layout(width, height) { child.place(left, top) }
    }
}

@Composable
internal fun SelectionGridBox(direction: BidiResolvedDirection, sink: SelectionGeometrySink,
    widthFor: (Int) -> Int, content: @Composable (Int, SelectionGeometrySink) -> Unit) {
    SubcomposeLayout(Modifier.fillMaxWidth()) { constraints ->
        if (!constraints.hasBoundedWidth) throw UnsupportedFloatLayout("Caption table needs bounded width")
        val width = constraints.maxWidth
        val gridWidth = widthFor(width)
        if (gridWidth !in 0..width) throw UnsupportedFloatLayout("Caption table exceeds its figure width")
        var geometry: FloatTextGeometry? = null
        val child = subcompose("grid") { content(width) { geometry = it } }.single()
            .measure(Constraints.fixedWidth(gridWidth))
        val exact = geometry ?: throw UnsupportedFloatLayout("Caption table selection geometry is unavailable")
        if (exact.width != child.width || exact.height != child.height)
            throw UnsupportedFloatLayout("Caption table measured geometry mismatch")
        if (child.height > constraints.maxHeight) throw UnsupportedFloatLayout("Caption table exceeds available height")
        val left = if (direction == BidiResolvedDirection.Ltr) 0 else width - gridWidth
        sink(NativeSemanticGroup(width, child.height,
            listOf(PositionedSemanticChild(NoPaintGeometry(exact), left.toFloat(), 0f, direction))))
        layout(width, child.height) { child.place(left, 0) }
    }
}
