package app.smallthingz.dict

import android.graphics.Canvas as NativeCanvas
import android.text.Spanned
import android.text.TextPaint
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.viewinterop.AndroidView

internal data class AnonymousFigureMeasureSpec(val width: Int, val margins: FloatMargins,
    val frameMinimumWidens: Boolean = false)

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
    inlineNodes: (NativeAnonymousFlowGeometry) -> List<FloatInteractionNode>,
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
    child: @Composable (AnonymousFlowEvent.FigureObject, Int) -> Unit,
) {
    val semantic = measureInput?.semantic ?: rememberNativeSemanticMeasurement()
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semantic) {
    SubcomposeLayout(modifier.then(if (measureInput == null) semantic.modifier else Modifier).fillMaxWidth()) { constraints ->
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
                val childConstraints = try { Constraints(minWidth = spec.width, maxWidth = spec.width) }
                    catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Figure exceeds Compose measurement range") }
                val placeable = subcompose("figure-${event.id}") { Box(Modifier.clearAndSetSemantics { }) { child(event, parentWidth) } }
                    .single().measure(childConstraints)
                check(measured.put(event.id, placeable) == null)
                val semantic = semanticGeometry(event, placeable.width, placeable.height)
                    ?: throw UnsupportedFloatLayout("Figure selection geometry is not ready")
                if (semantic.width != placeable.width || semantic.height != placeable.height)
                    throw UnsupportedFloatLayout("Figure selection geometry does not match its measured child")
                MeasuredAnonymousFigure(AnonymousChildProjection(semantic), spec.margins, spec.frameMinimumWidens)
            }, insets = insets, inlineNodes = inlineNodes, inlineSemantic = inlineSemantic,
                carriedExclusions = exclusions, decoration = decoration, outsideMarkerHeight = outsideMarkerHeight,
                decorationBounds = decorationBounds)
            if (geometry.height > constraints.maxHeight)
                throw UnsupportedFloatLayout("Anonymous flow exceeds its available height")
            try { Constraints.fixed(width, geometry.height) }
            catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Anonymous flow exceeds Compose measurement range") }
            val surface = NativeSurfaceGeometry(geometry)
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
            val message = subcompose("unsupported-flow") {
                unavailable(failure.message ?: "Geometry unavailable")
            }.single().measure(constraints)
            return layout(message.width, message.height) { message.place(0, 0) }
        }
        val geometry = result.getOrNull()
        if (geometry == null) unavailableResult(checkNotNull(result.exceptionOrNull())) else {
            val physical = checkNotNull(preparedSurface)
            onGeometry(geometry)
            onFlowGeometry(geometry)
            val surface = subcompose("native-anonymous-flow") {
                if (!interactionOwner) Canvas(Modifier) { physical.paint(drawContext.canvas.nativeCanvas) }
                else AndroidView(factory = { NativeFloatTextView(it) }, update = { view ->
                    view.bind({ actualWidth -> check(actualWidth == physical.width); physical },
                        linkColor.copy(alpha = .25f).toArgb(), linkColor.toArgb())
                })
            }.single().measure(Constraints.fixed(physical.width, physical.height))
            if (ticket != null && measureInput?.publish(ticket, Result.success(geometry)) != true) {
                unavailableResult(UnsupportedFloatLayout("Anonymous child preparation changed during measurement"))
            } else layout(geometry.width, maxOf(constraints.minHeight, geometry.height)) {
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
}

/** Child pixels are already painted below the surface; geometry/actions remain on the one owner. */
private class AnonymousChildProjection(private val delegate: FloatTextGeometry) : FloatTextGeometry by delegate {
    override fun paint(canvas: NativeCanvas) = Unit
}
