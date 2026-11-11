package app.smallthingz.dict

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.Composable
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.node.LayoutModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.invalidateMeasurement
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.unit.Constraints

/** A parent-owned layout input. Updating it invalidates its one actual child before measure. */
internal class NativeLayoutInput<T>(initial: T) {
    var value: T = initial
        private set
    internal var node: NativeLayoutInputNode<T>? = null
    val modifier: Modifier = NativeLayoutInputElement(this)

    fun update(next: T) {
        if (next == value) return
        value = next
        node?.takeIf { it.isAttached }?.invalidateMeasurement()
    }
}

internal class NativeLayoutInputNode<T>(private var input: NativeLayoutInput<T>) : Modifier.Node(), LayoutModifierNode {
    override fun onAttach() {
        check(input.node == null || input.node === this) { "A native measure input has more than one child" }
        input.node = this
    }
    override fun onDetach() { if (input.node === this) input.node = null }
    fun update(next: NativeLayoutInput<T>) {
        if (next === input) return
        if (isAttached) onDetach()
        input = next
        if (isAttached) onAttach()
    }
    override fun MeasureScope.measure(measurable: Measurable, constraints: Constraints): MeasureResult {
        val child = measurable.measure(constraints)
        return layout(child.width, child.height) { child.place(0, 0) }
    }
}

private data class NativeLayoutInputElement<T>(val input: NativeLayoutInput<T>) : ModifierNodeElement<NativeLayoutInputNode<T>>() {
    override fun create() = NativeLayoutInputNode(input)
    override fun update(node: NativeLayoutInputNode<T>) = node.update(input)
    override fun InspectorInfo.inspectableProperties() { name = "nativeLayoutInput" }
}

internal class NativeFlowMeasureInput {
    val exclusions = NativeLayoutInput<List<NativeFloatExclusion>>(emptyList())
    var geometry: NativeAnonymousFlowGeometry? = null
    val carried: List<NativeFloatExclusion> = object : AbstractList<NativeFloatExclusion>() {
        override val size: Int get() = exclusions.value.size
        override fun get(index: Int) = exclusions.value[index]
    }
}

internal val LocalNativeFlowMeasureInput = staticCompositionLocalOf<NativeFlowMeasureInput?> { null }

@Composable
internal fun NativeLayoutMessage(input: NativeLayoutInput<String?>) {
    SubcomposeLayout(input.modifier) { constraints ->
        val reason = input.value
        if (reason == null) layout(0, 0) { }
        else {
            val message = subcompose("message") { Text(reason) }.single().measure(constraints)
            layout(message.width, message.height) { message.place(0, 0) }
        }
    }
}
