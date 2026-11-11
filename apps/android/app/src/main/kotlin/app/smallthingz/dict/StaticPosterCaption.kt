package app.smallthingz.dict

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Constraints

/** One real caption child owns each translated exclusion input. No text or action is generated. */
internal class StaticCaptionInput {
    private val input = NativeLayoutInput<List<NativeFloatExclusion>>(emptyList())
    val modifier: Modifier get() = input.modifier
    val exclusions: List<NativeFloatExclusion> = object : AbstractList<NativeFloatExclusion>() {
        override val size: Int get() = input.value.size
        override fun get(index: Int) = input.value[index]
    }
    fun update(value: List<NativeFloatExclusion>, x: Float = 0f, y: Float = 0f) = input.update(value.map {
        it.copy(outer = NativeFloatBounds(it.outer.left - x, it.outer.top - y, it.outer.right - x, it.outer.bottom - y))
    })
}
internal val LocalStaticCaptionInput = staticCompositionLocalOf<StaticCaptionInput?> { null }
internal fun combineCaptionExclusions(existing: List<NativeFloatExclusion>, caption: StaticCaptionInput): List<NativeFloatExclusion> =
    object : AbstractList<NativeFloatExclusion>() {
        override val size: Int get() = existing.size + caption.exclusions.size
        override fun get(index: Int) = if (index < existing.size) existing[index] else caption.exclusions[index - existing.size]
    }

/** Source figcaption is table-caption: it encloses its generated float even with no text line. */
@Composable
internal fun StaticPosterCaption(enabled: Boolean, direction: BidiResolvedDirection, sink: SelectionGeometrySink,
    content: @Composable (SelectionGeometrySink) -> Unit) {
    val density = LocalDensity.current.density
    val input = remember { StaticCaptionInput() }
    val semantic = rememberNativeSemanticMeasurement()
    val published = remember { arrayOfNulls<FloatTextGeometry>(1) }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semantic, LocalStaticCaptionInput provides input) {
        Layout(content = { content { if (published[0] !== it) { published[0] = it; semantic.changed() } } },
            modifier = semantic.modifier, measurePolicy = object : MeasurePolicy {
                override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                    maxOf(if (enabled) figureCoordinate(18f * density) else 0, measurables.single().minIntrinsicWidth(height))
                override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                    figureCoordinate((if (enabled) 18f * density else 0f) + measurables.single().maxIntrinsicWidth(height))
                override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semantic.measure {
                    try {
                        if (!constraints.hasBoundedWidth) throw UnsupportedFloatLayout("Poster caption requires a bounded width")
                        input.update(if (enabled) listOf(staticPosterCaptionExclusion(constraints.maxWidth, density)) else emptyList())
                        val child = measurables.single().measure(constraints)
                        val geometry = published[0] ?: throw UnsupportedFloatLayout("Poster caption geometry is not ready")
                        if (geometry.width != child.width || geometry.height != child.height) throw UnsupportedFloatLayout("Poster caption geometry mismatch")
                        val height = maxOf(child.height, if (enabled) figureCoordinate(11f * density) else 0)
                        if (height > constraints.maxHeight) throw UnsupportedFloatLayout("Poster caption exceeds available height")
                        sink(NativeSemanticGroup(child.width, height,
                            listOf(PositionedSemanticChild(NoPaintGeometry(geometry), 0f, 0f, direction))))
                        layout(child.width, height) { child.place(0, 0) }
                    } catch (_: UnsupportedFloatLayout) { unavailableSelection(constraints, sink) }
                }
            })
    }
}
