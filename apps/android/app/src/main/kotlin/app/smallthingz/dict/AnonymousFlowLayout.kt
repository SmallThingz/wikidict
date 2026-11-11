package app.smallthingz.dict

import android.graphics.Canvas as NativeCanvas
import android.text.Spanned
import android.text.TextPaint
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
    decoration: (NativeCanvas, NativeFloatGeometry) -> Unit = { _, _ -> },
    outsideMarkerHeight: Float = 0f,
    unavailable: @Composable (String) -> Unit = { ReaderLayoutUnavailable(it) },
    child: @Composable (AnonymousFlowEvent.FigureObject, Int) -> Unit,
) {
    SubcomposeLayout(modifier.fillMaxWidth()) { constraints ->
        val measured = linkedMapOf<Int, androidx.compose.ui.layout.Placeable>()
        val result = try {
            if (!constraints.hasBoundedWidth || constraints.maxWidth <= 0)
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
                carriedExclusions = carriedExclusions, decoration = decoration, outsideMarkerHeight = outsideMarkerHeight)
            if (geometry.height > constraints.maxHeight)
                throw UnsupportedFloatLayout("Anonymous flow exceeds its available height")
            try { Constraints.fixed(width, geometry.height) }
            catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Anonymous flow exceeds Compose measurement range") }
            Result.success(geometry)
        } catch (failure: UnsupportedFloatLayout) { Result.failure(failure) }
        val geometry = result.getOrNull()
        if (geometry == null) {
            onFlowUnavailable()
            val message = subcompose("unsupported-flow") {
                unavailable(result.exceptionOrNull()?.message ?: "Geometry unavailable")
            }.single().measure(constraints)
            layout(message.width, message.height) { message.place(0, 0) }
        } else {
            onGeometry(geometry)
            onFlowGeometry(geometry)
            val surface = subcompose("native-anonymous-flow") {
                if (!interactionOwner) Canvas(Modifier) { geometry.paint(drawContext.canvas.nativeCanvas) }
                else AndroidView(factory = { NativeFloatTextView(it) }, update = { view ->
                    view.bind({ actualWidth -> check(actualWidth == geometry.width); geometry },
                        linkColor.copy(alpha = .25f).toArgb(), linkColor.toArgb())
                })
            }.single().measure(Constraints.fixed(geometry.width, geometry.height))
            layout(geometry.width, maxOf(constraints.minHeight, geometry.height)) {
                geometry.figures.forEach { placed ->
                    measured.getValue(placed.anchor.event.id).placeWithLayer(0, 0) {
                        translationX = placed.bounds.left
                        translationY = placed.bounds.top
                    }
                }
                // Last placement owns pointer/selection input over children; painting is transparent.
                surface.place(0, 0)
            }
        }
    }
}

/** Child pixels are already painted below the surface; geometry/actions remain on the one owner. */
private class AnonymousChildProjection(private val delegate: FloatTextGeometry) : FloatTextGeometry by delegate {
    override fun paint(canvas: NativeCanvas) = Unit
}
