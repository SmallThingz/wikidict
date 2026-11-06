package app.smallthingz.dict

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.viewinterop.AndroidView
import kotlin.math.ceil
import kotlin.math.roundToInt

internal sealed interface NativeFloatContextSpec {
    data class Text(val prepared: PreparedNativeFloatText, val gapAfter: Float, val path: String? = null) : NativeFloatContextSpec
    /** width is the existing renderer's actual viewport allocation at the ORIGINAL parent width. */
    data class Child(val id: Int, val width: (Int) -> Int, val gapAfter: Float,
        val floatSide: TableFloatSide? = null, val margins: (Int) -> FloatMargins = { FloatMargins(0f, 0f, 0f, 0f) },
        val requiresUnobstructedText: Boolean = false) : NativeFloatContextSpec
}

/** Existing child composables keep their own cell selection, accessibility tree and image owner. */
@Composable
internal fun NativeFloatContextLayout(
    parts: List<NativeFloatContextSpec>, modifier: Modifier, linkColor: Color, containAtEnd: Boolean = true,
    revealIndex: Int? = null, revealToken: Any? = null, onRevealed: () -> Unit = {},
    child: @Composable (id: Int, originalContainingWidth: Int) -> Unit,
) {
    val loading = parts.filterIsInstance<NativeFloatContextSpec.Text>().firstOrNull { it.prepared.geometry == null }
    Box(modifier.fillMaxWidth()) {
        if (loading != null) Text(loading.prepared.stateDescription ?: "Loading text layout")
        else SubcomposeLayout(Modifier.fillMaxWidth()) { constraints ->
            if (!constraints.hasBoundedWidth || constraints.maxWidth <= 0) {
                val message = subcompose("unsupported-width") { Text("Floated table layout needs a bounded width") }
                    .single().measure(constraints)
                layout(message.width, message.height) { message.place(0, 0) }
            } else {
                val width = constraints.maxWidth
                val measured = mutableMapOf<Pair<Int, Int>, androidx.compose.ui.layout.Placeable>()
                val selected = mutableMapOf<Int, androidx.compose.ui.layout.Placeable>()
                val specifications = parts.map { part -> when (part) {
                    is NativeFloatContextSpec.Text -> NativeFloatContextPart.Text(part.prepared.text,
                        { available, carried -> part.prepared.geometry!!(available, carried, false) }, part.gapAfter)
                    is NativeFloatContextSpec.Child -> {
                        val allocated = part.width(width).coerceAtLeast(1)
                        NativeFloatContextPart.Child(part.id, NativeBlockWidth.FixedPx(allocated.toFloat()), { request ->
                            // Fixed here means the normal native viewport, not a rewritten authored table width.
                            // The child resolves percent/fixed grid widths against the original containing width.
                            val childWidth = ceil(request.requestedWidth ?: allocated.toFloat()).toInt()
                            val placeable = measured.getOrPut(part.id to childWidth) {
                                subcompose(part.id to childWidth) { child(part.id, width) }.single()
                                    .measure(Constraints(minWidth = childWidth, maxWidth = childWidth))
                            }
                            selected[part.id] = placeable
                            NativeBlockMeasure(placeable.width.toFloat(), placeable.width.toFloat(), placeable.height.toFloat())
                        }, part.gapAfter, part.floatSide, part.margins(width), part.requiresUnobstructedText)
                    }
                } }
                val result = try {
                    val candidate = NativeFloatContextGeometry.build(width, specifications, containAtEnd)
                    try { Constraints.fixed(width, candidate.height) }
                    catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Context exceeds the native Compose measurement range") }
                    Result.success(candidate)
                }
                    catch (failure: UnsupportedFloatLayout) { Result.failure(failure) }
                val geometry = result.getOrNull()
                if (geometry == null) {
                    val message = subcompose("unsupported-flow") { Text("Floated table layout unavailable: ${result.exceptionOrNull()?.message}") }
                        .single().measure(constraints)
                    layout(message.width, message.height) { message.place(0, 0) }
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
                    }.single().measure(Constraints.fixed(width, geometry.height))
                    layout(width, geometry.height) {
                        text.place(0, 0)
                        // Child table/frame remains above the drawing surface for its own native pointer/a11y handling.
                        geometry.children.forEach { placed -> selected.getValue(placed.id)
                            .place(placed.bounds.left.roundToInt(), placed.bounds.top.roundToInt()) }
                    }
                }
            }
        }
        parts.filterIsInstance<NativeFloatContextSpec.Text>().forEach { it.prepared.menu() }
    }
}
