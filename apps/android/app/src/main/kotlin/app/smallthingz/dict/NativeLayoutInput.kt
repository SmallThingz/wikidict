package app.smallthingz.dict

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
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
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection

/** A parent-owned layout input. Updating it invalidates its one actual child before measure. */
internal class NativeLayoutInput<T>(initial: T, private val onDetached: () -> Unit = {}) {
    var value: T = initial
        private set
    internal var node: NativeLayoutInputNode<T>? = null
    val modifier: Modifier = NativeLayoutInputElement(this)

    fun update(next: T) {
        if (next == value) return
        value = next
        invalidate()
    }

    fun invalidate() {
        node?.takeIf { it.isAttached }?.invalidateMeasurement()
    }

    internal fun detached() = onDetached()
}

internal class NativeLayoutInputNode<T>(private var input: NativeLayoutInput<T>) : Modifier.Node(), LayoutModifierNode {
    override fun onAttach() {
        check(input.node == null || input.node === this) { "A native measure input has more than one child" }
        input.node = this
    }
    override fun onDetach() {
        if (input.node === this) { input.node = null; input.detached() }
    }
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

internal data class NativeFlowEnvironment(val density: Float, val fontScale: Float,
    val direction: LayoutDirection, val viewport: IntSize)

/** Identity belongs to one committed preparation, including its actual font/media/action closures. */
internal class NativeFlowBinding(val environment: NativeFlowEnvironment, val insets: NativeTextInsets,
    val outsideMarkerHeight: Float)

/** Source ownership survives responsive formatting changes; the request still records each
 * actual containing/isolating boundary even though its leaves share one composition parent. */
internal data class NativeFlowOwnerBoundary(val id: Int, val contentWidth: Int,
    val floatSide: TableFloatSide?, val isolatesFloats: Boolean, val row: NativeFlexRowPolicy? = null,
    val fixedContentHeight: Float? = null, val columns: NativeColumnPolicy? = null,
    val minimum: NativeContainerMinimum = NativeContainerMinimum(0f, false),
    val margins: NativeContainerMargins? = null, val padding: FloatMargins? = null)

internal data class NativeFlowParentPolicy(val composition: Any, val containAtEnd: Boolean,
    val box: ParagraphBox?, val gapAfter: Float, val marginCollapse: NativeMarginCollapse? = null,
    val owners: List<NativeFlowOwnerBoundary> = emptyList())

internal data class NativeFlowMeasureRequest(val binding: NativeFlowBinding,
    val parentConstraints: Constraints, val childConstraints: Constraints,
    val environment: NativeFlowEnvironment, val policy: NativeFlowParentPolicy,
    val exclusions: List<NativeFloatExclusion>)

/** The producer records constraints after all real child modifiers have transformed them. */
internal data class NativeFlowMeasureKey(val request: NativeFlowMeasureRequest, val actualConstraints: Constraints,
    val descendantRevision: Any)

/**
 * Semantic children can change at the same size. Outside an active ancestor build they invalidate
 * that ancestor explicitly; during its child-measure phase the new revision is consumed in that
 * same build. This handle crosses captions even where a Flow measure input must not be inherited.
 */
internal class NativeSemanticMeasurement(private val parent: NativeSemanticMeasurement? = null,
    private val onInvalidated: () -> Unit = {}) {
    var revision: Any = Any()
        private set
    private var measuring = 0
    private val input = NativeLayoutInput(Unit) { changed() }
    val modifier: Modifier get() = input.modifier

    fun changed() {
        revision = Any()
        if (measuring == 0) { input.invalidate(); onInvalidated() }
        parent?.changed()
    }

    fun <T> measure(block: () -> T): T {
        measuring++
        return try { block() } finally { measuring-- }
    }
}

internal val LocalNativeSemanticMeasurement = staticCompositionLocalOf<NativeSemanticMeasurement?> { null }

@Composable
internal fun rememberNativeSemanticMeasurement(): NativeSemanticMeasurement {
    val parent = LocalNativeSemanticMeasurement.current
    val measurement = remember(parent) { NativeSemanticMeasurement(parent) }
    SideEffect { measurement.changed() }
    DisposableEffect(measurement) { onDispose { measurement.changed() } }
    return measurement
}

internal data class NativeMeasuredGeometry<G : FloatTextGeometry>(val result: Result<G>,
    val fallbackBounds: NativeFloatBounds? = null)

internal class NativeGeometryMeasureInput<G : FloatTextGeometry>(ancestor: NativeSemanticMeasurement? = null,
    private val invalidateParent: () -> Unit = {}) {
    private var binding: NativeFlowBinding? = null
    private var actualKey: NativeFlowMeasureKey? = null
    private val publication = NativeGeometryPublication<NativeFlowMeasureKey, NativeMeasuredGeometry<G>>()
    val measurement = NativeLayoutInput<NativeFlowMeasureRequest?>(null) { detached() }
    val semantic = NativeSemanticMeasurement(ancestor) { clear(); measurement.invalidate(); invalidateParent() }

    fun bind(next: NativeFlowBinding) {
        if (binding === next) return
        binding = next
        clear()
        invalidateParent()
    }

    fun unbind(previous: NativeFlowBinding) {
        if (binding !== previous) return
        binding = null
        clear()
        invalidateParent()
    }

    private fun clear() {
        actualKey = null
        publication.ownerDetached()
        measurement.update(null)
    }

    private fun detached() {
        clear()
        invalidateParent()
    }

    fun request(parentConstraints: Constraints, childConstraints: Constraints, environment: NativeFlowEnvironment,
        policy: NativeFlowParentPolicy, exclusions: List<NativeFloatExclusion>): NativeFlowMeasureRequest {
        val prepared = binding ?: throw UnsupportedFloatLayout("Anonymous child preparation is not ready")
        // 'carried' is a live view. Never place that view, or its caller's mutable list, in the key.
        val snapshot = java.util.Collections.unmodifiableList(ArrayList(exclusions))
        val ownerSnapshot = java.util.Collections.unmodifiableList(ArrayList(policy.owners))
        val next = NativeFlowMeasureRequest(prepared, parentConstraints, childConstraints, environment,
            policy.copy(owners = ownerSnapshot), snapshot)
        if (measurement.value != next) {
            actualKey = null
            publication.ownerDetached()
            measurement.update(next)
        }
        return next
    }

    fun begin(prepared: NativeFlowBinding, constraints: Constraints): NativeGeometryPublication.Attempt<NativeFlowMeasureKey>? {
        val request = measurement.value ?: return null
        if (binding !== prepared || request.binding !== prepared) return null
        val key = NativeFlowMeasureKey(request, constraints, semantic.revision)
        actualKey = key
        publication.select(key)
        return publication.begin(key)
    }

    /** Descendants first composed/measured inside this build are part of its final immutable key. */
    fun seal(ticket: NativeGeometryPublication.Attempt<NativeFlowMeasureKey>): NativeGeometryPublication.Attempt<NativeFlowMeasureKey>? {
        if (!publication.isCurrent(ticket) || binding !== ticket.key.request.binding || measurement.value != ticket.key.request) return null
        if (ticket.key.descendantRevision === semantic.revision) return ticket
        val key = ticket.key.copy(descendantRevision = semantic.revision)
        actualKey = key
        publication.select(key)
        return publication.begin(key)
    }

    fun publish(ticket: NativeGeometryPublication.Attempt<NativeFlowMeasureKey>, result: Result<G>,
        fallbackBounds: NativeFloatBounds? = null): Boolean {
        if (binding !== ticket.key.request.binding || measurement.value != ticket.key.request ||
            ticket.key.descendantRevision !== semantic.revision) return false
        return publication.publish(ticket, NativeMeasuredGeometry(result, fallbackBounds))
    }

    fun measured(request: NativeFlowMeasureRequest): NativeMeasuredGeometry<G>? {
        if (measurement.value != request || binding !== request.binding) return null
        val key = actualKey?.takeIf { it.request == request && it.descendantRevision === semantic.revision } ?: return null
        return publication.forInput(key)
    }

    fun ready(request: NativeFlowMeasureRequest): G? = measured(request)?.result?.getOrNull()

    val geometry: G? get() = measurement.value?.let(::ready)
    val carried: List<NativeFloatExclusion> = object : AbstractList<NativeFloatExclusion>() {
        override val size: Int get() = measurement.value?.exclusions?.size ?: 0
        override fun get(index: Int) = checkNotNull(measurement.value).exclusions[index]
    }
}

internal typealias NativeFlowMeasureInput = NativeGeometryMeasureInput<NativeAnonymousFlowGeometry>
internal typealias NativeContextMeasureInput = NativeGeometryMeasureInput<NativeFloatContextGeometry>
internal val LocalNativeFlowMeasureInput = staticCompositionLocalOf<NativeFlowMeasureInput?> { null }
internal val LocalNativeContextMeasureInput = staticCompositionLocalOf<NativeContextMeasureInput?> { null }

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
