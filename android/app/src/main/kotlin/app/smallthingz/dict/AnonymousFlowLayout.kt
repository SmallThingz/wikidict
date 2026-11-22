package app.smallthingz.dict

import android.graphics.Canvas as NativeCanvas
import android.text.Spanned
import android.text.TextPaint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlin.math.roundToInt

internal data class AnonymousFigureMeasureSpec(val width: Int, val margins: FloatMargins,
    val frameMinimumWidens: Boolean = false, val childMinimumFloor: Boolean = false,
    val normalContentLeft: ((Int) -> Float?)? = null,
    val usedBox: NativeFigureUsedBox? = null)

private data class AnonymousSurfaceRequest(val geometry: NativeSurfaceGeometry?, val failure: String? = null)

/**
 * One measured figure child supplies its actual caption geometry to the shared semantic owner.
 * Children paint below the native input/selection surface and have no second accessibility tree.
 * No per-text child is made. The child adapter must retain media ownership and expose all actions.
 */
@Composable
internal fun AnonymousFlowLayout(
    content: AnonymousFlowContent,
    paint: TextPaint,
    modifier: Modifier,
    linkColor: Color,
    inline: (AnonymousFlowEvent.Inline, Int) -> Spanned,
    figureSpec: (AnonymousFlowEvent.FigureObject, Int) -> AnonymousFigureMeasureSpec,
    inlineNodes: (NativeAnonymousFlowGeometry) -> List<FloatInteractionNode> = { emptyList() },
    semanticGeometry: (AnonymousFlowEvent.FigureObject, Int, Int) -> FloatTextGeometry?,
    insets: NativeTextInsets = NativeTextInsets(),
    inlineSemantic: (AnonymousFlowEvent.Inline, String) -> List<AnonymousInlineTextPart> = { _, text ->
        listOf(AnonymousInlineTextPart(0, text.length, text))
    },
    onGeometry: (FloatTextGeometry) -> Unit = {},
    interactionOwner: Boolean = true,
    carriedExclusions: List<NativeFloatExclusion> = emptyList(),
    onFlowGeometry: (NativeAnonymousFlowGeometry) -> Unit = {},
    onFlowUnavailable: () -> Unit = {},
    measureInput: NativeFlowMeasureInput? = null,
    preparedBinding: NativeFlowBinding? = null,
    decoration: (NativeCanvas, NativeFloatGeometry) -> Unit = { _, _ -> },
    outsideMarkerHeight: Float = 0f,
    decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds? = { null },
    unavailable: @Composable (String) -> Unit = { ReaderLayoutUnavailable(it) },
    intrinsicWidths: (((AnonymousFlowEvent.FigureObject) -> Int) -> NativeWidthRange)? = null,
    inlineNodeSources: ((NativeAnonymousFlowGeometry) -> List<NativeAnonymousInlineNode>)? = null,
    citationStatuses: List<NativeCitationPreparationStatus> = emptyList(),
    child: @Composable (AnonymousFlowEvent.FigureObject) -> Unit,
) {
    val publishCellBaselines = LocalNativeContainerTextContext.current?.cellText != null
    val semantic = measureInput?.semantic ?: rememberNativeSemanticMeasurement()
    val scrollClip = LocalNativeScrollClip.current
    val positionedParent = LocalNativePositionedPaintParent.current
    val captionBreakWord = LocalCaptionBreakWord.current
    val figures = content.events.filterIsInstance<AnonymousFlowEvent.FigureObject>()
    val citationOwner = rememberNativeCitationGeometryOwner(citationStatuses)
    val inheritedCitationOwners = LocalNativeCitationGeometryOwners.current
    val childCitationOwners = inheritedCitationOwners + listOfNotNull(citationOwner)
    val surfaceInput = remember { NativeLayoutInput<AnonymousSurfaceRequest?>(null) }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semantic,
        LocalNativePositionedPaintParent provides true) {
    Layout(modifier = modifier.then(if (measureInput == null) semantic.modifier else Modifier).fillMaxWidth(), content = {
        CompositionLocalProvider(LocalNativeCitationGeometryOwners provides childCitationOwners) {
            figures.forEach { event -> key(event.id) {
                TableContentColumn(Modifier.clearAndSetSemantics { }, 0.dp) { child(event) }
            } }
        }
        // Intrinsic queries visit real Figure children, never this paint/input surface slot.
        SubcomposeLayout(surfaceInput.modifier) { constraints ->
            val request = checkNotNull(surfaceInput.value)
            val physical = request.geometry
            val surface = if (physical == null) subcompose("unsupported-flow") {
                CompositionLocalProvider(LocalNativeCitationGeometryOwners provides inheritedCitationOwners) {
                    unavailable(request.failure ?: "Geometry unavailable")
                }
            }.single() else subcompose("native-anonymous-flow") {
                if (!interactionOwner) Canvas(Modifier) { physical.paint(drawContext.canvas.nativeCanvas) }
                else {
                    val coordinates = rememberNativeTableCoordinateBinding()
                    val citationNavigation = LocalNativeCitationNavigation.current
                    val citationParentReveal = rememberNativeCitationParentReveal()
                    AndroidView(modifier = (coordinates?.modifier ?: Modifier).then(citationParentReveal?.modifier ?: Modifier),
                        factory = { NativeFloatTextView(it, scrollClip) }, update = { view ->
                        view.updateScrollClip(scrollClip)
                        view.updateCitationNavigation(citationNavigation)
                        view.updateCitationParentReveal(citationParentReveal)
                        coordinates?.bind(view)
                        view.bind({ actualWidth -> check(actualWidth == physical.width); physical },
                            linkColor.copy(alpha = .25f).toArgb(), linkColor.toArgb())
                    })
                }
            }.single()
            val measured = surface.measure(constraints)
            layout(measured.width, measured.height) { measured.place(0, 0) }
        }
    }, measurePolicy = object : MeasurePolicy {
      private val defaultIntrinsics = this.defaultIntrinsicPolicy()
      private var citationIntrinsicDepth = 0
      private fun <T> citationIntrinsic(block: () -> T): T {
        citationIntrinsicDepth++
        return try { block() } finally { citationIntrinsicDepth-- }
      }
      private fun widths(measurables: List<IntrinsicMeasurable>, maximum: Boolean): NativeWidthRange {
        val byId = figures.mapIndexed { index, figure -> figure.id to measurables[index] }.toMap()
        val figureWidth: (AnonymousFlowEvent.FigureObject) -> Int = { event ->
            val child = byId.getValue(event.id)
            if (maximum) child.maxIntrinsicWidth(Constraints.Infinity) else child.minIntrinsicWidth(Constraints.Infinity)
        }
        return intrinsicWidths?.invoke(figureWidth) ?: anonymousWidthRange(content, paint,
            inline = { inline(it, TablePixelLimit) }, figureWidth = { figureWidth(it).toFloat() },
            inset = insets.left + insets.right + insets.extraLeft + insets.extraRight,
            breakWordMinimum = captionBreakWord)
      }
      override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = widths(measurables, false).minimum
      override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = widths(measurables, true).maximum
      override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int): Int = citationIntrinsic {
        with(defaultIntrinsics) { this@minIntrinsicHeight.minIntrinsicHeight(measurables, width) }
      }
      override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int): Int = citationIntrinsic {
        with(defaultIntrinsics) { this@maxIntrinsicHeight.maxIntrinsicHeight(measurables, width) }
      }
      override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
        val started = preparedBinding?.let { measureInput?.begin(it, constraints) }
        val exclusions = started?.key?.request?.exclusions ?: carriedExclusions.toList()
        val measured = linkedMapOf<Int, androidx.compose.ui.layout.Placeable>()
        var preparedSurface: NativeSurfaceGeometry? = null
        val built = semantic.measure { try {
            if (measureInput != null && started == null)
                throw UnsupportedFloatLayout("Anonymous child preparation changed before measurement")
            if (!constraints.hasBoundedWidth)
                throw UnsupportedFloatLayout("Anonymous flow needs a bounded containing width")
            val width = constraints.maxWidth
            val geometry = NativeAnonymousFlowGeometry.build(content, paint, width, { inline(it, width) }, { event, parentWidth ->
                val spec = figureSpec(event, parentWidth)
                if (spec.width < 0) throw UnsupportedFloatLayout("Negative figure width")
                val measurable = measurables[figures.indexOfFirst { it.id == event.id }.also { check(it >= 0) }]
                val childWidth = if (spec.childMinimumFloor) maxOf(measurable.minIntrinsicWidth(Constraints.Infinity),
                    minOf((parentWidth - spec.margins.left - spec.margins.right).toInt().coerceAtLeast(0),
                        measurable.maxIntrinsicWidth(Constraints.Infinity))) else spec.width
                val childConstraints = try { Constraints(minWidth = childWidth, maxWidth = childWidth) }
                    catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Figure exceeds Compose measurement range") }
                val placeable = measurable.measure(childConstraints)
                check(measured.put(event.id, placeable) == null)
                val semantic = semanticGeometry(event, placeable.width, placeable.height)
                    ?: throw UnsupportedFloatLayout("Figure selection geometry is not ready")
                if (semantic.width != placeable.width || semantic.height != placeable.height)
                    throw UnsupportedFloatLayout("Figure selection geometry does not match its measured child")
                MeasuredAnonymousFigure(AnonymousChildProjection(semantic), spec.margins, spec.frameMinimumWidens,
                    spec.normalContentLeft?.invoke(placeable.width), spec.usedBox)
            }, insets = insets, inlineNodes = inlineNodes, inlineSemantic = inlineSemantic,
                carriedExclusions = exclusions, decoration = decoration, outsideMarkerHeight = outsideMarkerHeight,
                decorationBounds = decorationBounds, inlineNodeSources = inlineNodeSources)
            if (geometry.height > constraints.maxHeight)
                throw UnsupportedFloatLayout("Anonymous flow exceeds its available height")
            try { Constraints.fixed(width, geometry.height) }
            catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Anonymous flow exceeds Compose measurement range") }
            val surface = NativeSurfaceGeometry(if (positionedParent) NativeOrdinaryPaint(geometry) else geometry)
            try { Constraints.fixed(surface.width, surface.height) }
            catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Anonymous overflow exceeds Compose measurement range") }
            preparedSurface = surface
            Result.success(geometry)
        } catch (failure: UnsupportedFloatLayout) { Result.failure(failure) } }
        val ticket = started?.let { measureInput?.seal(it) }
        val result = if (started != null && ticket == null) Result.failure(
            UnsupportedFloatLayout("Anonymous child preparation changed during its child build")) else built
        fun unavailableResult(failure: Throwable): androidx.compose.ui.layout.MeasureResult {
            if (ticket != null) measureInput?.publish(ticket, Result.failure(failure))
            onFlowUnavailable()
            surfaceInput.update(AnonymousSurfaceRequest(null, failure.message))
            val message = measurables.last().measure(constraints)
            if (citationIntrinsicDepth == 0)
                citationOwner?.reportFailure(failure.message ?: "Anonymous flow geometry is unavailable")
            return layout(message.width, message.height) { message.place(0, 0) }
        }
        val geometry = result.getOrNull()
        return if (geometry == null) unavailableResult(checkNotNull(result.exceptionOrNull())) else {
            val physical = checkNotNull(preparedSurface)
            // Every source child has finished; the final surface slot owns no source geometry.
            if (ticket != null && measureInput?.publish(ticket, Result.success(geometry)) != true) {
                unavailableResult(UnsupportedFloatLayout("Anonymous child preparation changed during measurement"))
            } else {
              onGeometry(geometry)
              onFlowGeometry(geometry)
              surfaceInput.update(AnonymousSurfaceRequest(physical))
              val surface = measurables.last().measure(Constraints.fixed(physical.width, physical.height))
              if (citationIntrinsicDepth == 0) citationOwner?.reportSuccess()
              val alignmentLines = geometry.textBaselines?.takeIf { publishCellBaselines }?.let { lines -> listOfNotNull<Pair<androidx.compose.ui.layout.AlignmentLine, Int>>(
                  lines.first?.let { androidx.compose.ui.layout.FirstBaseline to it.roundToInt() },
                  lines.last?.let { androidx.compose.ui.layout.LastBaseline to it.roundToInt() }).toMap() } ?: emptyMap()
              layout(geometry.width, maxOf(constraints.minHeight, geometry.height), alignmentLines) {
                geometry.figures.forEach { placed ->
                    measured.getValue(placed.anchor.event.id).placeWithLayer(0, 0) {
                        translationX = placed.bounds.left
                        translationY = placed.bounds.top
                    }
                }
                // Last placement owns pointer/selection input over children; painting is transparent.
                surface.place(physical.surface.left, physical.surface.top)
              }
            }
        }
      }
    })
    }
}

/** Child pixels are already painted below the surface; geometry/actions remain on the one owner. */
private class AnonymousChildProjection(private val delegate: FloatTextGeometry) : FloatTextGeometry by delegate {
    override fun paint(canvas: NativeCanvas) = Unit
    override fun paintOrdinary(canvas: NativeCanvas) = Unit
}
