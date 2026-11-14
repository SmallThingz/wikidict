package app.smallthingz.dict

import android.graphics.Canvas as AndroidCanvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.foundation.Canvas
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth

internal const val NativeRuleAccessibilityLabel = "Separator"

/** A real empty separator has no glyph, object character, baseline, or action. */
internal class NativeRuleGeometry(val contentWidth: Float, val metrics: NativeRuleMetrics,
    allocationWidth: Int = figureCoordinate(contentWidth)) : FloatTextGeometry by EmptyCaptionGeometry(allocationWidth) {
    init {
        if (!contentWidth.isFinite() || contentWidth < 0f || contentWidth > TablePixelLimit ||
            allocationWidth < figureCoordinate(contentWidth) || allocationWidth > TablePixelLimit)
            throw UnsupportedFloatLayout("Authored rule width exceeds native geometry")
    }
    override val width = allocationWidth
    override val height = metrics.allocatedHeight
    private val bounds = RectF(0f, 0f, contentWidth, metrics.height)
    private val fill = metrics.fill?.let { color -> Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color } }
    override val nodes = listOf(FloatInteractionNode(0, FloatInteractionKind.SEPARATOR, 0, 0,
        listOf(RectF(bounds)), null, null, null))
    override val extents = NativeGeometryExtents(width, metrics.height,
        if (fill == null || bounds.isEmpty) null else NativeFloatBounds(0f, 0f, contentWidth, metrics.height),
        nativeBoundsOf(nodes.flatMap { it.bounds }))
    override val ordinaryPaintBounds = listOfNotNull(extents.ink)
    override val focusBounds: RectF get() = RectF(bounds)
    override fun containsInteraction(x: Float, y: Float): Boolean = bounds.contains(x, y)
    override fun containsInput(x: Float, y: Float): Boolean = bounds.contains(x, y)
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? = nodes.single().takeIf { bounds.contains(x, y) }
    override fun paint(canvas: AndroidCanvas) {
        fill?.let { canvas.drawRect(bounds, it) }
    }
    override fun paintOrdinary(canvas: AndroidCanvas) = paint(canvas)
}

@Composable
internal fun AuthoredRule(style: RuleStyle, modifier: Modifier = Modifier,
    sink: SelectionGeometrySink? = null, includeVerticalMargins: Boolean = true) {
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val dark = LocalReaderDarkTheme.current
    val resolved = remember(style, density.density, bodyPixels, dark) {
        runCatching { resolveAuthoredRuleMetrics(style, density.density, bodyPixels, dark) }
    }
    val metrics = resolved.getOrNull()
    if (metrics == null) {
        val reason = resolved.exceptionOrNull()?.message ?: "Authored rule is unavailable"
        if (sink != null) UnavailableSelectionContent(reason, sink) else ReaderLayoutUnavailable(reason)
    } else AuthoredRuleSurface(metrics, modifier, sink, includeVerticalMargins)
}

/** The enclosing adjoining owner consumes vertical margins when requested; paint is never rounded. */
@Composable
internal fun AuthoredRuleSurface(metrics: NativeRuleMetrics, modifier: Modifier = Modifier,
    sink: SelectionGeometrySink? = null, includeVerticalMargins: Boolean = true) {
    val semantic = rememberNativeSemanticMeasurement()
    val message = remember { NativeLayoutInput<String?>(null) }
    val painted = remember(metrics) { arrayOfNulls<FloatTextGeometry>(1) }
    DisposableEffect(sink) { onDispose { sink?.invoke(null) } }
    val accessibility = if (sink == null) Modifier.semantics { contentDescription = NativeRuleAccessibilityLabel } else Modifier
    Layout(modifier = modifier.then(semantic.modifier).then(accessibility), content = {
        Canvas(Modifier) { painted[0]?.paintOrdinary(drawContext.canvas.nativeCanvas) }
        NativeLayoutMessage(message)
    }, measurePolicy = object : MeasurePolicy {
        private fun used(): Pair<Float, Float> {
            if (!includeVerticalMargins) return 0f to metrics.height
            val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
            val profile = metrics.adjoining
            val placement = cursor.begin(profile)
            cursor.end(placement, metrics.height, profile)
            return placement.borderTop to cursor.finish()
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = metrics.intrinsic().minimum
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = metrics.intrinsic().maximum
        override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) = figureCoordinate(used().second)
        override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) = figureCoordinate(used().second)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semantic.measure {
            try {
                if (!constraints.hasBoundedWidth || constraints.maxWidth > TablePixelLimit)
                    throw UnsupportedFloatLayout("Authored rule needs its containing width")
                val width = constraints.maxWidth
                val (top, usedHeight) = used()
                val height = figureCoordinate(usedHeight)
                if (height < constraints.minHeight || height > constraints.maxHeight)
                    throw UnsupportedFloatLayout("Authored rule exceeds its available height")
                val body = NativeRuleGeometry(metrics.contentWidth(width.toFloat()), metrics,
                    metrics.allocatedWidth(width.toFloat()))
                val group = NativeSemanticGroup(width, height, listOf(PositionedSemanticChild(body,
                    metrics.margins.left, top, BidiResolvedDirection.Ltr)))
                val exact = object : FloatTextGeometry by group {
                    override val extents = NativeGeometryExtents(width, usedHeight,
                        body.extents.ink?.translated(metrics.margins.left, top),
                        body.extents.interaction?.translated(metrics.margins.left, top))
                    override val ordinaryPaintBounds = body.ordinaryPaintBounds.map { it.translated(metrics.margins.left, top) }
                }
                val packed = try { Constraints.fixed(width, height) }
                    catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Authored rule exceeds Compose measurement range") }
                val canvas = measurables.first().measure(packed)
                message.update(null)
                val warning = measurables.last().measure(Constraints.fixed(0, 0))
                painted[0] = exact
                sink?.invoke(NoPaintGeometry(exact))
                layout(width, height) { canvas.place(0, 0); warning.place(0, 0) }
            } catch (failure: UnsupportedFloatLayout) {
                painted[0] = null
                sink?.invoke(null)
                message.update(failure.message ?: "Authored rule is unavailable")
                val warning = measurables.last().measure(constraints.copy(minWidth = 0, minHeight = 0))
                val width = constraints.constrainWidth(warning.width)
                val height = constraints.constrainHeight(warning.height)
                val canvas = measurables.first().measure(Constraints.fixed(0, 0))
                layout(width, height) { canvas.place(0, 0); warning.place(0, 0) }
            }
        }
    })
}
