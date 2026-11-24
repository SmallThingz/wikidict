package app.smallthingz.dict

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.PointerInputModifierNode
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.flow.first
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.viewinterop.AndroidView
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/** Preserve Compose's default intrinsic approximation through the original measure callback. */
internal fun MeasurePolicy.defaultIntrinsicPolicy(): MeasurePolicy {
    val actual = this
    return MeasurePolicy { measurables, constraints ->
        with(actual) { measure(measurables, constraints) }
    }
}

// Optional diagnostics stay outside the authored text and accessibility stream.
internal val LocalNativeFloatContextFailureObserver = staticCompositionLocalOf<((String) -> Unit)?> { null }
internal val LocalNativeContextInteractionOwner = staticCompositionLocalOf { true }
internal val LocalNativeContextContainAtEnd = staticCompositionLocalOf { true }
internal val LocalNativeFractionalTableCoordinates = staticCompositionLocalOf { false }

/** Only the responsive Table subtree supplies Compose's fractional native-surface coordinates. */
internal class NativeTableCoordinateBinding {
    private var view: NativeFloatTextView? = null
    val modifier = Modifier.onGloballyPositioned { view?.positionTableCoordinates(this, it) }
    fun bind(next: NativeFloatTextView) {
        if (view !== next) {
            view?.clearTableCoordinates(this)
            view = next
        }
        next.bindTableCoordinates(this)
    }
    fun clear() { view?.clearTableCoordinates(this); view = null }
}

@Composable
internal fun rememberNativeTableCoordinateBinding(): NativeTableCoordinateBinding? {
    if (!LocalNativeFractionalTableCoordinates.current) return null
    val binding = remember { NativeTableCoordinateBinding() }
    DisposableEffect(binding) { onDispose { binding.clear() } }
    return binding
}

/** Used box and signed glyph ink are independent for an app-owned native control. */
internal data class NativeExactChildMeasure(val block: NativeBlockMeasure, val ink: NativeFloatBounds?)

internal sealed interface NativeFloatContextSpec {
    data class Text(val prepared: PreparedNativeFloatText, val gapAfter: Float, val path: String? = null,
        val box: ParagraphBox? = null,
        val columnBreakInside: ColumnBreakInside? = null, val headingFramePaddingAbove: Float? = null, val columnAvoidGroup: Int = 0) : NativeFloatContextSpec
    data class Rule(val id: Int, val metrics: NativeRuleMetrics) : NativeFloatContextSpec
    data class Flow(val id: Int, val gapAfter: Float, val path: String?, val box: ParagraphBox?,
        val empty: Boolean,
        val content: @Composable (List<NativeFloatExclusion>, (NativeAnonymousFlowGeometry) -> Unit) -> Unit,
    ) : NativeFloatContextSpec
    /** Intrinsics and measurement query the same composed content owner. The intrinsic
     * adapter returns the complete outer contribution, including authored box edges. */
    data class Container(val id: Int,
        val contentWidth: (Int, ContainerWidths) -> Int,
        val intrinsicWidth: (Int, Boolean) -> Int,
        val margins: (Int) -> NativeContainerMargins = { FloatMargins(0f, 0f, 0f, 0f) },
        val padding: (Int) -> FloatMargins = { FloatMargins(0f, 0f, 0f, 0f) },
        val floatSide: TableFloatSide? = null, val clear: FigureClear? = null,
        val empty: Boolean = false, val isolatesFloats: Boolean = false,
        val innerMargins: NativeAdjoiningMargins? = null,
        val preparedParts: List<NativeFloatContextSpec>? = null,
        val horizontal: ((Int, ContainerWidths) -> NativeContainerHorizontal)? = null,
        val row: NativeFlexRowPolicy? = null,
        val flex: NativeFlexItemSpec? = null,
        val decoration: NativeContainerDecoration? = null,
        val unavailableReason: String? = null,
        val fixedContentHeight: Float? = null,
        val columns: NativeColumnPolicy? = null,
        val relativeAuto: Boolean = false,
        val minimum: NativeContainerMinimum = NativeContainerMinimum(0f, false),
        val headingAllocation: NativeSectionHeadingAllocation? = null,
        val absolute: NativeAbsoluteTextPlacement? = null,
        val scrollport: NativeScrollportSpec? = null,
        val absolutePosition: NativeAbsolutePosition? = null,
        val absoluteContainingBlock: NativeAbsoluteContainingBlock? = null,
        val absoluteStatic: NativeAbsoluteStaticPosition? = null,
        val columnClearEvent: Boolean = false,
        val columnContentWidths: (() -> ContainerWidths)? = null,
        val column: NativeFlexColumnPolicy? = null,
        val content: @Composable () -> Unit,
    ) : NativeFloatContextSpec
    /** width is the existing renderer's actual viewport allocation at the ORIGINAL parent width. */
    data class Child(val id: Int, val width: (Int) -> Int, val gapAfter: Float,
        val floatSide: TableFloatSide? = null, val margins: (Int) -> FloatMargins = { FloatMargins(0f, 0f, 0f, 0f) },
        val requiresUnobstructedText: Boolean = false, val gapBefore: Float = 0f,
        val clear: FigureClear? = null, val logicalObject: Boolean = true,
        val atomicInline: Boolean = false, val widthFromContent: Boolean = false,
        val preferredWidth: (Int) -> Int? = { null }, val overflowViewport: Boolean = false,
        val scrollport: NativeScrollportSpec? = null,
        val delegatedTable: Table? = null, val autoMarginTable: Table? = null,
        val positionedTableSource: NativeTableScopeEntrySource? = null,
        val autoMargins: NativeTableAutoMargins? = null,
        val blockViewport: TableBlockViewport? = null,
        val blockBox: ((Int) -> NativeTableBlockBox)? = null,
        val fixedMarginTable: NativeFixedMarginTableInput? = null,
        val pairedMarginTable: NativeFixedMarginTableInput? = null,
        val pairedBlockBox: ((Int, Float, ContainerWidths) -> NativeTableBlockBox)? = null,
        val intrinsicMarginTable: NativeFixedMarginTableInput? = null,
        val minimumWidth: (Int) -> Float? = { null },
        val documentScrollable: Boolean = false,
        val ordinaryDirection: TableContainingDirection? = null,
        val exactWidth: ((Float) -> Float)? = null,
        val exactMeasure: ((Float) -> NativeExactChildMeasure)? = null,
        val content: (@Composable (NativeLayoutInput<Float>) -> Unit)? = null) : NativeFloatContextSpec
}

/** Keep an unavailable fallback within both the parent's bounds and Compose's packed range. */
internal fun nativeFallbackHeight(constraints: Constraints, contentHeight: Long): Int {
    require(constraints.hasBoundedWidth && contentHeight >= 0L)
    val capacity = Constraints.fitPrioritizingWidth(minWidth = constraints.maxWidth, maxWidth = constraints.maxWidth,
        minHeight = 0, maxHeight = Int.MAX_VALUE - 1).maxHeight
    return contentHeight.coerceIn(constraints.minHeight.toLong(), minOf(constraints.maxHeight, capacity).toLong()).toInt()
}

/** A retained grid inside horizontal scrolling has a measured width even when its parent has no maximum. */
internal fun nativeUnavailableGridHeight(constraints: Constraints, measuredWidth: Int, contentHeight: Long): Int {
    val bounded = if (constraints.hasBoundedWidth) constraints else Constraints.fitPrioritizingWidth(
        minWidth = measuredWidth, maxWidth = measuredWidth,
        minHeight = constraints.minHeight, maxHeight = constraints.maxHeight)
    return nativeFallbackHeight(bounded, contentHeight)
}

/** Real child compositions are shared by intrinsic queries, normal placement and fallback. */
@Composable
internal fun NativeFloatContextLayout(
    parts: List<NativeFloatContextSpec>, modifier: Modifier, linkColor: Color,
    containAtEnd: Boolean = LocalNativeContextContainAtEnd.current,
    revealIndex: Int? = null, revealToken: Any? = null, onRevealed: () -> Unit = {},
    interactionOwner: Boolean = LocalNativeContextInteractionOwner.current,
    adjoining: Boolean = false,
    documentSurface: Boolean = false,
    delegatedSourceRevision: Any? = null,
    bodyAdjoining: BodyAdjoiningPolicy? = null,
    sourceReveal: (suspend (Float?) -> Unit)? = null,
    absoluteScope: Boolean = false,
    onInputGeometry: ((NativeFloatContextGeometry, FloatTextGeometry) -> Unit)? = null,
    revealUnavailable: (suspend () -> Unit)? = null,
    // Runs after all native surface/extent checks. A validator may use the existing
    // UnsupportedFloatLayout path; null clears any previous measured permission.
    onMeasuredGeometry: ((NativeFloatContextGeometry?, FloatTextGeometry?) -> Unit)? = null,
    child: @Composable (id: Int, originalContainingWidth: NativeLayoutInput<Int>) -> Unit,
) {
    val ordinaryBody = bodyAdjoining == BodyAdjoiningPolicy.Ordinary
    require(!ordinaryBody || documentSurface && containAtEnd) { "Ordinary body margins require the complete document body owner" }
    val publishCellBaselines = LocalNativeContainerTextContext.current?.cellText != null
    val pairedTableHeightIntrinsics = LocalPairedTableIntrinsicHeight.current
    fun flatten(items: List<NativeFloatContextSpec>): List<NativeFloatContextSpec> = items.flatMap { item ->
        val nested = (item as? NativeFloatContextSpec.Container)?.preparedParts
        if (nested == null) listOf(item) else flatten(nested)
    }
    val leaves = flatten(parts)
    val citationOwner = rememberNativeCitationGeometryOwner(
        leaves.filterIsInstance<NativeFloatContextSpec.Text>().mapNotNull { it.prepared.citationPreparation })
    val inheritedCitationOwners = LocalNativeCitationGeometryOwners.current
    val childCitationOwners = inheritedCitationOwners + listOfNotNull(citationOwner)
    val paintParts = mutableListOf<NativeFloatContextSpec>()
    fun paintOrder(items: List<NativeFloatContextSpec>) { items.forEach {
        paintParts += it
        (it as? NativeFloatContextSpec.Container)?.preparedParts?.let(::paintOrder)
    } }
    paintOrder(parts)
    val sourcePaintIndices = java.util.IdentityHashMap<NativeFloatContextSpec, Int>()
    paintParts.forEachIndexed { index, part -> sourcePaintIndices[part] = index }
    val containingBlockSources = paintParts.filterIsInstance<NativeFloatContextSpec.Container>()
        .filter { it.absoluteContainingBlock != null }.associate { it.id to sourcePaintIndices.getValue(it) }
    fun paintTree(items: List<NativeFloatContextSpec>): List<NativePaintOrderNode> = items.map { part ->
        val group = part as? NativeFloatContextSpec.Container
        NativePaintOrderNode(sourcePaintIndices.getValue(part), group?.relativeAuto == true ||
            group?.absolute != null || group?.absolutePosition != null || group?.absoluteStatic != null,
            paintTree(group?.preparedParts.orEmpty()), absolute = group?.absolute != null,
            absoluteContainingBlock = group?.absoluteContainingBlock != null,
            absolutePositionContainingBlock = (group?.absolutePosition?.containingBlockId ?: group?.absoluteStatic?.containingBlockId)?.let { id ->
                containingBlockSources[id]
                    ?: throw UnsupportedFloatLayout("Absolute paint owner has no represented containing block")
            })
    }
    val paintSequence = nativeContextPaintSequence(paintTree(parts), absoluteScope)
    val ordinaryPaintRanks = java.util.IdentityHashMap<NativeFloatContextSpec, Int>()
    paintSequence.forEachIndexed { rank, index -> ordinaryPaintRanks[paintParts[index]] = rank }
    val positioned = paintParts.filterIsInstance<NativeFloatContextSpec.Container>().any { it.relativeAuto || it.absolute != null || it.absolutePosition != null || it.absoluteStatic != null }
    val positionedParent = LocalNativePositionedPaintParent.current
    val captionBreakWord = LocalCaptionBreakWord.current
    val decorated = paintParts.filterIsInstance<NativeFloatContextSpec.Container>().filter { it.decoration != null }
    fun sourceIds(items: List<NativeFloatContextSpec>): List<Int> = items.flatMap { part -> when (part) {
        is NativeFloatContextSpec.Rule -> listOf(part.id)
        is NativeFloatContextSpec.Flow -> listOf(part.id)
        is NativeFloatContextSpec.Child -> listOf(part.id)
        is NativeFloatContextSpec.Container -> listOf(part.id) + sourceIds(part.preparedParts.orEmpty())
        else -> emptyList()
    } }
    val sourceKeys = sourceIds(parts)
    require(sourceKeys.distinct().size == sourceKeys.size) { "Prepared leaves require unique stable source owners" }
    val parentMeasureInput = remember { NativeLayoutInput(Unit) }
    val delegatedCell = LocalNativeDelegatedCell.current
    val delegatedTables = linkedMapOf<Int, NativeDelegatedTableOwner>()
    leaves.filterIsInstance<NativeFloatContextSpec.Child>().forEach { part ->
        part.delegatedTable?.let { table -> androidx.compose.runtime.key("delegated-table", part.id) {
            delegatedTables[part.id] = remember(NativeDelegatedTableIdentity(table), part.positionedTableSource?.revision) {
                NativeDelegatedTableOwner(table, part.positionedTableSource, parentMeasureInput::invalidate)
            }
        } }
    }
    val documentPublisher = LocalNativeDocumentOverflowPublisher.current.takeIf { documentSurface }
    val documentOwner = remember(delegatedSourceRevision, documentPublisher) { Any() }
    DisposableEffect(documentOwner, documentPublisher) {
        documentPublisher?.attach(documentOwner)
        onDispose { documentPublisher?.detach(documentOwner) }
    }
    val semanticAncestor = LocalNativeSemanticMeasurement.current
    val composition = Any()
    val currentDensity = LocalDensity.current
    val environment = NativeFlowEnvironment(currentDensity.density, currentDensity.fontScale,
        LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
    val documentRtl = LocalNativeContainerTextContext.current?.bodyDirection?.let { it == BidiResolvedDirection.Rtl }
        ?: (environment.direction == androidx.compose.ui.unit.LayoutDirection.Rtl)
    val ownInput = LocalNativeContextMeasureInput.current
    val delegatedRevision = listOf(delegatedSourceRevision, environment,
        interactionOwner, positioned, positionedParent, ownInput != null,
        leaves.filterIsInstance<NativeFloatContextSpec.Text>().map {
            listOf(it.prepared.native?.paint?.typeface, it.prepared.native?.paint?.textSize, it.prepared.stateDescription,
                it.prepared.ordinaryLinkPaintRevision)
        }) + listOfNotNull(bodyAdjoining) + absoluteScope
    val localScrollport = LocalNativeContainerScrollport.current
    require(!documentSurface || ownInput == null) { "Document scroll allocation cannot replace a nested used box" }
    val measureAncestor = ownInput?.semantic ?: semanticAncestor
    val binding = NativeFlowBinding(environment, NativeTextInsets(), 0f)
    SideEffect { ownInput?.bind(binding); semanticAncestor?.changed() }
    DisposableEffect(ownInput, binding) { onDispose { ownInput?.unbind(binding) } }
    DisposableEffect(semanticAncestor) { onDispose { semanticAncestor?.changed() } }
    val loading = leaves.filterIsInstance<NativeFloatContextSpec.Text>().firstOrNull { it.prepared.geometry == null }
    CompositionLocalProvider(LocalNativeContextMeasureInput provides null,
        LocalNativeFlowMeasureInput provides null,
        LocalNativeDelegatedCell provides null,
        LocalNativeDelegatedFigureScope provides delegatedCell,
        LocalNativeContextInteractionOwner provides true,
        LocalNativeContextContainAtEnd provides true,
        LocalNativePositionedPaintParent provides true,
        LocalNativeSemanticMeasurement provides measureAncestor) {
    Box(modifier.then(ownInput?.measurement?.modifier ?: Modifier).fillMaxWidth()
        .onGloballyPositioned { coordinates ->
            delegatedCell?.let { it.contextCoordinates = coordinates; it.table.validateAfterPlacement() }
            delegatedTables.values.forEach { it.positioned(coordinates) }
        }.drawWithContent {
            if (delegatedCell == null || delegatedCell.table.permitsCellContent()) drawContent()
            // Preserve the same original cell state owners, but paint their state once
            // after all table media. A lost-focus View can still own a visible selection.
            delegatedTables.values.forEach { it.paintOriginalState(drawContext.canvas.nativeCanvas, focus = false) }
            delegatedTables.values.forEach { it.paintOriginalState(drawContext.canvas.nativeCanvas, focus = true) }
        }) {
        if (loading != null) {
            androidx.compose.runtime.SideEffect { onMeasuredGeometry?.invoke(null, null) }
            Text(loading.prepared.stateDescription ?: "Loading text layout")
        }
        else {
            val slots = leaves.withIndex().filter { it.value !is NativeFloatContextSpec.Text && it.value !is NativeFloatContextSpec.Rule }
            val textSlots = leaves.indices.filter { leaves[it] is NativeFloatContextSpec.Text || leaves[it] is NativeFloatContextSpec.Rule }
            val widths = mutableMapOf<Int, NativeLayoutInput<Int>>()
            val exactWidths = mutableMapOf<Int, NativeLayoutInput<Float>>()
            val tableMarginInputs = mutableMapOf<Int, NativeTableMarginMeasureInput>()
            val flows = mutableMapOf<Int, NativeFlowMeasureInput>()
            val containers = mutableMapOf<Int, NativeContextMeasureInput>()
            val flowPlacements = mutableMapOf<Int, NativeFlowSurfacePlacement>()
            slots.forEach { (index, part) -> androidx.compose.runtime.key(part::class, when (part) {
                is NativeFloatContextSpec.Child -> part.id
                is NativeFloatContextSpec.Flow -> part.id
                is NativeFloatContextSpec.Container -> part.id
                else -> error("Text has no child slot")
            }) {
                when (part) {
                    is NativeFloatContextSpec.Child -> {
                        widths[index] = remember { NativeLayoutInput(0) }
                        if (part.content != null) exactWidths[index] = remember { NativeLayoutInput(0f) }
                        (part.autoMarginTable ?: part.fixedMarginTable?.table ?: part.pairedMarginTable?.table ?: part.intrinsicMarginTable?.table)?.let { table ->
                            tableMarginInputs[index] = remember(NativeDelegatedTableIdentity(table)) { NativeTableMarginMeasureInput(table) }
                        }
                    }
                    is NativeFloatContextSpec.Flow -> {
                        flows[index] = remember(measureAncestor) {
                            NativeFlowMeasureInput(measureAncestor, parentMeasureInput::invalidate)
                        }
                        flowPlacements[index] = remember { NativeFlowSurfacePlacement() }
                    }
                    is NativeFloatContextSpec.Container -> {
                        containers[index] = remember(measureAncestor) {
                            NativeContextMeasureInput(measureAncestor, parentMeasureInput::invalidate)
                        }
                        flowPlacements[index] = remember { NativeFlowSurfacePlacement() }
                    }
                    else -> Unit
                }
            } }
            val auxiliary = remember { NativeLayoutInput<NativeContextPass?>(null) }
            val textPasses = mutableMapOf<Int, NativeLayoutInput<NativeContextPass?>>()
            val decorationPasses = mutableMapOf<Int, NativeLayoutInput<NativeContextPass?>>()
            val mediaSlots = slots.filter { it.value is NativeFloatContextSpec.Flow || it.value is NativeFloatContextSpec.Container }
            val mediaPasses = mutableMapOf<Int, NativeLayoutInput<NativeContextPass?>>()
            mediaSlots.forEach { (index, _) -> androidx.compose.runtime.key("media-paint-input", index) {
                mediaPasses[index] = remember { NativeLayoutInput<NativeContextPass?>(null) }
            } }
            decorated.forEach { part -> androidx.compose.runtime.key("container-paint-input", part.id) {
                decorationPasses[part.id] = remember { NativeLayoutInput<NativeContextPass?>(null) }
            } }
            textSlots.forEach { index -> androidx.compose.runtime.key("text-paint-input", index) {
                textPasses[index] = remember { NativeLayoutInput<NativeContextPass?>(null) }
            } }
            Layout(modifier = parentMeasureInput.modifier.fillMaxWidth(), content = {
                CompositionLocalProvider(LocalNativeCitationGeometryOwners provides childCitationOwners) {
                slots.forEach { (index, part) -> androidx.compose.runtime.key(part::class, when (part) {
                    is NativeFloatContextSpec.Child -> part.id
                    is NativeFloatContextSpec.Flow -> part.id
                    is NativeFloatContextSpec.Container -> part.id
                    else -> error("Text has no child slot")
                }) {
                    when (part) {
                        is NativeFloatContextSpec.Child -> CompositionLocalProvider(
                            LocalNativeTableMarginMeasureInput provides tableMarginInputs[index],
                            LocalNativeDelegatedTable provides delegatedTables[part.id],
                            // Ordinary children retain the enclosing native paint-parent scope.
                            LocalNativePositionedPaintParent provides (delegatedTables[part.id] == null),
                            LocalNativePositionedPaintUnavailable provides
                                "Positioned Figure media needs the delegated child's Entry paint-order join") { Box {
                            val scrollport = part.scrollport
                            if (part.content != null) part.content.invoke(exactWidths.getValue(index))
                            else if (scrollport == null) child(part.id, widths.getValue(index))
                            else NativeContainerScrollport(scrollport, linkColor, parentMeasureInput, child)
                        } }
                        is NativeFloatContextSpec.Flow -> {
                            val input = flows.getValue(index)
                            androidx.compose.runtime.CompositionLocalProvider(LocalNativeFlowMeasureInput provides input) {
                                NativeFlowSurfaceSlot(input, flowPlacements.getValue(index)) {
                                    // The child publishes only after its complete measure; this callback
                                    // is an observation hook, not authority to reuse geometry.
                                    part.content(input.carried) { }
                                }
                            }
                        }
                        is NativeFloatContextSpec.Container -> {
                            val input = containers.getValue(index)
                            CompositionLocalProvider(LocalNativeContextMeasureInput provides input,
                                LocalNativeContextInteractionOwner provides false,
                                LocalNativeContextContainAtEnd provides (part.floatSide != null || part.isolatesFloats)) {
                                NativeFlowSurfaceSlot(input, flowPlacements.getValue(index)) {
                                    val scrollport = part.scrollport
                                    if (scrollport == null) part.content()
                                    else NativeContainerScrollport(scrollport, linkColor, parentMeasureInput, child)
                                }
                            }
                        }
                        else -> Unit
                    }
                } }
                }
                textSlots.forEach { index -> androidx.compose.runtime.key("text-paint", index) {
                    NativeContextTextSurface(textPasses.getValue(index), index)
                } }
                decorated.forEach { part -> androidx.compose.runtime.key("container-paint", part.id) {
                    NativeContainerPaintSurface(decorationPasses.getValue(part.id), part.id, checkNotNull(part.decoration))
                } }
                mediaSlots.forEach { (index, _) -> androidx.compose.runtime.key("media-paint", index) {
                    NativeContextPositionedSurface(mediaPasses.getValue(index), index, positionedParent)
                } }
                CompositionLocalProvider(LocalNativeCitationGeometryOwners provides inheritedCitationOwners) {
                    NativeFloatAuxiliary(auxiliary, leaves, linkColor, revealIndex, revealToken, onRevealed, interactionOwner,
                        delegatedCell, delegatedTables.values.singleOrNull(), sourceReveal, revealUnavailable)
                }
            }, measurePolicy = object : MeasurePolicy {
                private fun intrinsicWidthOf(measurables: List<IntrinsicMeasurable>, maximum: Boolean,
                    items: List<NativeFloatContextSpec> = parts, row: Boolean = false, structural: Boolean = false,
                    column: Boolean = false): Int {
                    if (column) {
                        check(!row)
                        var used = 0f
                        for (item in items) {
                            val owner = item as? NativeFloatContextSpec.Container
                                ?: throw UnsupportedFloatLayout("A flex column requires original item owners")
                            val nested = owner.preparedParts
                                ?: throw UnsupportedFloatLayout("Flex column items must retain prepared children")
                            val intrinsic = ContainerWidths(
                                intrinsicWidthOf(measurables, false, nested, owner.row != null, column = owner.column != null).toFloat(),
                                intrinsicWidthOf(measurables, true, nested, owner.row != null, column = owner.column != null).toFloat())
                            val contribution = owner.flex?.intrinsic?.invoke(intrinsic, maximum)
                                ?: throw UnsupportedFloatLayout("Flex column intrinsic contribution is not prepared")
                            if (!contribution.isFinite() || contribution < 0f)
                                throw UnsupportedFloatLayout("Invalid flex column intrinsic contribution")
                            used = maxOf(used, contribution)
                        }
                        return if (used > TablePixelLimit) Constraints.Infinity else ceil(used).toInt()
                    }
                    if (row) {
                        var sum = 0.0
                        for (item in items) {
                            val owner = item as? NativeFloatContextSpec.Container
                                ?: throw UnsupportedFloatLayout("A flex row requires complete logical item owners")
                            val nested = owner.preparedParts ?: throw UnsupportedFloatLayout("Flex items must retain their prepared children")
                            val intrinsic = ContainerWidths(intrinsicWidthOf(measurables, false, nested, owner.row != null, column = owner.column != null).toFloat(),
                                intrinsicWidthOf(measurables, true, nested, owner.row != null, column = owner.column != null).toFloat())
                            val contribution = owner.flex?.intrinsic?.invoke(intrinsic, maximum)
                                ?: throw UnsupportedFloatLayout("Flex item intrinsic contribution is not prepared")
                            if (!contribution.isFinite() || contribution < 0f) throw UnsupportedFloatLayout("Invalid flex intrinsic contribution")
                            sum += contribution
                        }
                        return if (sum > TablePixelLimit) Constraints.Infinity else ceil(sum).toInt()
                    }
                    fun childWidth(index: Int): Int? {
                        if (structural) return null
                        val position = slots.indexOfFirst { it.index == index }
                        if (position < 0) return null
                        val measurable = measurables[position]
                        return if (maximum) measurable.maxIntrinsicWidth(Constraints.Infinity)
                            else measurable.minIntrinsicWidth(Constraints.Infinity)
                    }
                    var used = 0L
                    var floatLine = 0L
                    for (part in items) {
                        if (part is NativeFloatContextSpec.Container && (part.absolute != null || part.absolutePosition != null || part.absoluteStatic != null)) continue
                        val index = leaves.indexOfFirst { it === part }
                        val content = when (part) {
                            is NativeFloatContextSpec.Text -> if (part.prepared.emptyInlineOwner) 0 else {
                                val native = part.prepared.native ?: return Constraints.Infinity
                                val range = nativeTextWidthRange(native.source(TablePixelLimit), native.paint,
                                    native.horizontalInsets, breakWordMinimum = captionBreakWord || native.breakWordMinimum,
                                    textDirection = native.direction)
                                if (maximum) range.maximum else range.minimum
                            }
                            is NativeFloatContextSpec.Rule -> part.metrics.intrinsic().let { if (maximum) it.maximum else it.minimum }
                            is NativeFloatContextSpec.Container -> part.intrinsicWidth(
                                if (part.columnContentWidths != null) 0 else
                                (part.preparedParts ?: part.scrollport?.takeIf { it.positioned != null }?.parts)?.let {
                                    intrinsicWidthOf(measurables, maximum, it, part.row != null, structural || part.scrollport != null, part.column != null)
                                } ?: childWidth(index) ?: throw UnsupportedFloatLayout("Positioned scope intrinsic child is unavailable"), maximum)
                            else -> childWidth(index) ?: throw UnsupportedFloatLayout("Positioned scope requires prepared native intrinsic content")
                        }
                        val box = when (part) {
                            is NativeFloatContextSpec.Text -> part.box
                            is NativeFloatContextSpec.Flow -> part.box
                            else -> null
                        }
                        val edges = box?.let { kotlin.math.ceil(it.contentLeft + it.contentRight).toLong() } ?: 0L
                        val fixedMargins = (part as? NativeFloatContextSpec.Child)?.takeIf {
                            it.fixedMarginTable != null || it.blockViewport == null &&
                                (it.autoMarginTable?.blockViewport?.isSeparateCornerGrid == true || it.intrinsicMarginTable != null)
                        }?.margins?.invoke(0)
                        val fixedEdges = fixedMargins?.let { ceil(it.left + it.right).toLong() } ?: 0L
                        val own = content.toLong() + edges + fixedEdges
                        val floating = when (part) {
                            is NativeFloatContextSpec.Child -> part.floatSide != null
                            is NativeFloatContextSpec.Container -> part.floatSide != null
                            else -> false
                        }
                        if (floating) {
                            val clear = when (part) {
                                is NativeFloatContextSpec.Child -> part.clear
                                is NativeFloatContextSpec.Container -> part.clear
                                else -> null
                            }
                            if (clear != null && clear != FigureClear.None) floatLine = 0L
                            val extent = if (part is NativeFloatContextSpec.Child && part.fixedMarginTable == null) {
                                val margins = part.margins(0)
                                own + kotlin.math.ceil(margins.left + margins.right).toLong()
                            } else own
                            floatLine = if (maximum) floatLine + extent else maxOf(floatLine, extent)
                            used = maxOf(used, floatLine)
                        } else {
                            used = maxOf(used, if (maximum) floatLine + own else maxOf(floatLine, own))
                            if (part is NativeFloatContextSpec.Child && part.requiresUnobstructedText) floatLine = 0L
                        }
                    }
                    return if (used > TablePixelLimit) Constraints.Infinity else used.toInt()
                }
                private val defaultIntrinsics = this.defaultIntrinsicPolicy()
                private var citationIntrinsicDepth = 0
                private fun <T> citationIntrinsic(block: () -> T): T {
                    citationIntrinsicDepth++
                    return try { block() } finally { citationIntrinsicDepth-- }
                }
                override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsicWidthOf(measurables, false)
                override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsicWidthOf(measurables, true)

                private fun pairedTextHeight(width: Int): Int {
                    val item = parts.singleOrNull() as? NativeFloatContextSpec.Text ?: return Constraints.Infinity
                    if (width !in 0..TablePixelLimit || item.box != null || item.gapAfter != 0f || ordinaryBody || adjoining ||
                            ownInput != null || documentSurface || !containAtEnd) return Constraints.Infinity
                    val build = item.prepared.geometry ?: return Constraints.Infinity
                    val source = if (item.prepared.text.isEmpty())
                        item.prepared.native?.source?.invoke(0) ?: item.prepared.text else item.prepared.text
                    return try {
                        NativeFloatContextGeometry.build(width, listOf(NativeFloatContextPart.Text(source,
                            { available, carried -> build(available, carried, false) },
                            emptyInlineOwner = item.prepared.emptyInlineOwner))).height
                    } catch (_: UnsupportedFloatLayout) { Constraints.Infinity }
                }
                override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int): Int = citationIntrinsic {
                    if (pairedTableHeightIntrinsics) pairedTextHeight(width) else with(defaultIntrinsics) { this@minIntrinsicHeight.minIntrinsicHeight(measurables, width) }
                }
                override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int): Int = citationIntrinsic {
                    if (pairedTableHeightIntrinsics) pairedTextHeight(width) else with(defaultIntrinsics) { this@maxIntrinsicHeight.maxIntrinsicHeight(measurables, width) }
                }

                override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                    return ownInput?.semantic?.measure { measureContext(measurables, constraints) }
                        ?: measureContext(measurables, constraints)
                }

                private fun MeasureScope.measureContext(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                    onMeasuredGeometry?.invoke(null, null)
                    val ticket = ownInput?.begin(binding, constraints)
                    val width = constraints.maxWidth.takeIf { constraints.hasBoundedWidth }
                    delegatedTables.values.forEach { it.begin(delegatedRevision, width ?: 0) }
                    val childMeasurables = slots.mapIndexed { slot, row -> row.index to measurables[slot] }.toMap()
                    val pairedCommits = mutableMapOf<Int, (PlacedFloatContextChild) -> Unit>()
                    val measured = mutableMapOf<Int, Placeable>()
                    val requests = mutableMapOf<Int, Constraints>()
                    val flowRequests = mutableMapOf<Int, NativeFlowMeasureRequest>()
                    val containerRequests = mutableMapOf<Int, NativeFlowMeasureRequest>()
                    val attempted = mutableSetOf<Int>()
                    val failed = mutableMapOf<Int, UnsupportedFloatLayout>()
                    fun measurePart(index: Int, childConstraints: Constraints): Placeable {
                        measured[index]?.let {
                            if (requests[index] != childConstraints) throw UnsupportedFloatLayout("A native child requires two different measurements")
                            return it
                        }
                        failed[index]?.let { throw it }
                        check(attempted.add(index)) { "A native child was measured twice in one pass" }
                        requests[index] = childConstraints
                        return try { childMeasurables.getValue(index).measure(childConstraints).also { measured[index] = it } }
                        catch (failure: UnsupportedFloatLayout) { failed[index] = failure; throw failure }
                    }
                    widths.values.forEach { it.update(width ?: 0) }
                    var preparedSurface: NativeSurfaceGeometry? = null
                    var documentExtent: NativeDocumentVerticalExtent? = null
                    var documentScrollBounds: NativeFloatBounds? = null
                    var paintRanks = ordinaryPaintRanks
                    var mediaRanks = emptyMap<Int, Int>()
                    val result = try {
                        if (width == null) throw UnsupportedFloatLayout("Floated table layout needs a bounded width")
                        fun specifications(items: List<NativeFloatContextSpec>, containingWidth: Int,
                            owners: List<NativeFlowOwnerBoundary> = emptyList(), contextContains: Boolean = containAtEnd,
                            row: NativeFlexRowPolicy? = null, available: Float = containingWidth.toFloat(),
                            column: NativeFlexColumnPolicy? = null
                        ): List<NativeFloatContextPart> {
                            check(row == null || column == null)
                            val allocations = if (column != null) items.map { item ->
                                val owner = item as? NativeFloatContextSpec.Container
                                    ?: throw UnsupportedFloatLayout("A flex column requires original item owners")
                                val nested = owner.preparedParts
                                    ?: throw UnsupportedFloatLayout("Flex column items must retain prepared children")
                                val minimum = intrinsicWidthOf(measurables, false, nested, owner.row != null, column = owner.column != null)
                                val maximum = intrinsicWidthOf(measurables, true, nested, owner.row != null, column = owner.column != null)
                                owner.flex?.columnMeasure?.invoke(available, ContainerWidths(minimum.toFloat(), maximum.toFloat()), column)
                                    ?: throw UnsupportedFloatLayout("Flex column cross sizing is not prepared")
                            } else if (row == null) null else {
                                val metrics = items.map { item ->
                                    val owner = item as? NativeFloatContextSpec.Container
                                        ?: throw UnsupportedFloatLayout("A flex row requires complete logical item owners")
                                    val nested = owner.preparedParts ?: throw UnsupportedFloatLayout("Flex items must retain prepared children")
                                    val minimum = intrinsicWidthOf(measurables, false, nested, owner.row != null, column = owner.column != null)
                                    val maximum = intrinsicWidthOf(measurables, true, nested, owner.row != null, column = owner.column != null)
                                    owner.flex?.measure?.invoke(available, ContainerWidths(minimum.toFloat(), maximum.toFloat()))
                                        ?: throw UnsupportedFloatLayout("Flex item sizing is not prepared")
                                }
                                val used = containerFlexWidths(available, metrics)
                                val margins = containerFlexMargins(available, metrics, used)
                                items.indices.map { NativeFlexItemAllocation(used[it], margins[it].first, margins[it].second) }
                            }
                            return items.mapIndexed { itemIndex, part ->
                            val index = leaves.indexOfFirst { it === part }
                            when (part) {
                            is NativeFloatContextSpec.Text -> {
                                // An actually empty string can carry real zero-offset metric owners.
                                // This constructs their original Spanned metadata only; shaping and
                                // allocation still use the eventual real width in the factory below.
                                val source = if (part.prepared.text.isEmpty())
                                    part.prepared.native?.source?.invoke(0) ?: part.prepared.text else part.prepared.text
                                NativeFloatContextPart.Text(source,
                                    { available, carried -> part.prepared.geometry!!(available, carried, false) },
                                    part.gapAfter, part.box, part.prepared.emptyInlineOwner,
                                    part.prepared.geometryAtWidth?.let { exact -> { available, carried -> exact(available, carried, false) } },
                                    part.prepared.geometryForColumns, part.columnBreakInside, part.headingFramePaddingAbove, part.columnAvoidGroup)
                            }
                            is NativeFloatContextSpec.Rule -> NativeFloatContextPart.Rule(part.id, part.metrics, available)
                            is NativeFloatContextSpec.Flow -> NativeFloatContextPart.Flow(part.id, { available, carried ->
                                val input = flows.getValue(index)
                                val childConstraints = Constraints(minWidth = available, maxWidth = available)
                                val previous = flowRequests[index]
                                if (index in attempted && (previous?.exclusions != carried || previous?.childConstraints != childConstraints))
                                    throw UnsupportedFloatLayout("An anonymous child requires two exclusion contexts")
                                val request = input.request(constraints, childConstraints, environment,
                                    NativeFlowParentPolicy(composition, contextContains, part.box, part.gapAfter, owners = owners), carried)
                                flowRequests[index] = request
                                val placeable = measurePart(index, childConstraints)
                                val geometry = input.ready(request) ?: throw UnsupportedFloatLayout("Anonymous child geometry is not ready for these inputs")
                                if (geometry.width != placeable.width || geometry.height != placeable.height)
                                    throw UnsupportedFloatLayout("Anonymous child measurement differs from its geometry")
                                geometry
                            }, part.gapAfter, part.box, part.empty)
                            is NativeFloatContextSpec.Container -> {
                                part.unavailableReason?.let { throw UnsupportedFloatLayout(it) }
                                val nested = part.preparedParts
                                val measurable = if (nested == null) childMeasurables.getValue(index) else null
                                val scopeParts = part.scrollport?.takeIf { it.positioned != null }?.parts
                                val exactColumnWidths = part.columnContentWidths?.invoke()
                                val minimum = if (exactColumnWidths != null) 0 else if (part.absoluteStatic != null) 0 else if (scopeParts != null) intrinsicWidthOf(measurables, false, scopeParts, structural = true)
                                    else if (nested == null) measurable!!.minIntrinsicWidth(Constraints.Infinity)
                                    else intrinsicWidthOf(measurables, false, nested, part.row != null, column = part.column != null)
                                val maximum = if (exactColumnWidths != null) 0 else if (part.absoluteStatic != null) 0 else if (scopeParts != null) intrinsicWidthOf(measurables, true, scopeParts, structural = true)
                                    else if (nested == null) measurable!!.maxIntrinsicWidth(Constraints.Infinity)
                                    else intrinsicWidthOf(measurables, true, nested, part.row != null, column = part.column != null)
                                if (minimum > TablePixelLimit || maximum < minimum || maximum > TablePixelLimit)
                                    throw UnsupportedFloatLayout("Container intrinsic width exceeds the native range")
                                val intrinsic = exactColumnWidths ?: ContainerWidths(minimum.toFloat(), maximum.toFloat())
                                val forced = allocations?.get(itemIndex)
                                val allocated = if (part.absoluteStatic != null) floor(available).toInt()
                                    else forced?.let { floor(it.width).toInt() } ?: part.contentWidth(containingWidth, intrinsic)
                                if (allocated !in 0..TablePixelLimit)
                                    throw UnsupportedFloatLayout("Container content width exceeds the native range")
                                fun measureContainer(available: Int, carried: List<NativeFloatExclusion>, collapse: NativeMarginCollapse?): NativeFloatContextGeometry {
                                    val input = containers.getValue(index)
                                    val childConstraints = Constraints(minWidth = available, maxWidth = available)
                                    val previous = containerRequests[index]
                                    if (index in attempted && (previous?.exclusions != carried || previous?.childConstraints != childConstraints ||
                                            previous?.policy?.marginCollapse != collapse))
                                        throw UnsupportedFloatLayout("A container requires two exclusion contexts")
                                    val request = input.request(constraints, childConstraints, environment,
                                        NativeFlowParentPolicy(composition, contextContains, null, 0f, collapse, owners), carried)
                                    containerRequests[index] = request
                                    val placeable = measurePart(index, childConstraints)
                                    val geometry = input.ready(request)
                                        ?: throw UnsupportedFloatLayout("Container geometry is not ready for these inputs")
                                    if (geometry.width != placeable.width || geometry.height != placeable.height)
                                        throw UnsupportedFloatLayout("Container measurement differs from its geometry")
                                    return geometry
                                }
                                val padding = part.padding(containingWidth)
                                val margins = part.margins(containingWidth).let { original ->
                                    if (forced == null) original else when (original) {
                                        is FloatMargins -> original.copy(left = forced.left, right = forced.right)
                                        is SignedNativeContainerMargins -> original.copy(left = forced.left, right = forced.right)
                                    }
                                }
                                val effectiveFloat = if (forced == null) part.floatSide else null
                                val isolated = part.isolatesFloats || part.row != null || part.column != null || forced != null
                                val horizontal = if (part.absoluteStatic != null)
                                    NativeContainerHorizontal(available, available, available, 0f, 0f, 0f, available)
                                else forced?.let {
                                    val border = it.width + padding.left + padding.right
                                    val outer = border + it.left + it.right
                                    if (column == null) NativeContainerHorizontal(outer, it.width, border, it.left,
                                        it.left + padding.left, 0f, outer)
                                    else {
                                        val left = it.left + it.crossOffset
                                        NativeContainerHorizontal(outer, it.width, border, left, left + padding.left,
                                            minOf(0f, left), maxOf(outer, left + border))
                                    }
                                } ?: part.horizontal?.invoke(containingWidth, intrinsic)
                                NativeFloatContextPart.Container(part.id, allocated,
                                    { available, carried -> measureContainer(available, carried, null) },
                                    margins, padding, effectiveFloat, if (forced == null) part.clear else null,
                                    part.empty, isolated, part.innerMargins,
                                    { available, carried, collapse -> measureContainer(available, carried, collapse) },
                                    nested?.let { specifications(it, allocated,
                                        owners + NativeFlowOwnerBoundary(part.id, allocated, effectiveFloat, isolated, part.row,
                                            part.fixedContentHeight, part.columns, part.minimum, margins, padding, part.column),
                                        effectiveFloat != null || isolated, part.row, horizontal?.content ?: allocated.toFloat(), part.column) },
                                    horizontal, part.row, part.flex?.crossMargins ?: NativeFlexCrossMargins(),
                                    part.fixedContentHeight, part.columns, part.minimum, part.headingAllocation,
                                    part.absolute, part.scrollport?.positioned != null, part.absolutePosition, part.absoluteContainingBlock,
                                    part.absoluteStatic, if (part.absoluteStatic == null) null else
                                        (nested?.singleOrNull() as? NativeFloatContextSpec.Text)?.prepared?.native,
                                    part.columnClearEvent, part.column)
                            }
                            is NativeFloatContextSpec.Child -> {
                                val exact = part.exactWidth
                                if ((exact != null) != (part.exactMeasure != null) || (exact != null) != (part.content != null) ||
                                    exact != null && (part.logicalObject || part.atomicInline || part.widthFromContent ||
                                        part.overflowViewport || part.scrollport != null || part.delegatedTable != null ||
                                        part.autoMarginTable != null || part.fixedMarginTable != null || part.pairedMarginTable != null ||
                                        part.intrinsicMarginTable != null || part.blockViewport != null || part.blockBox != null ||
                                        part.documentScrollable || part.ordinaryDirection != null))
                                    throw UnsupportedFloatLayout("Exact native control requires its own ordinary content slot")
                                if (part.documentScrollable && (part.ordinaryDirection == null || part.logicalObject ||
                                        part.floatSide != null || part.atomicInline || part.overflowViewport || part.scrollport != null ||
                                        part.autoMarginTable != null || part.fixedMarginTable != null || part.pairedMarginTable != null ||
                                        part.intrinsicMarginTable != null || part.blockViewport != null || part.blockBox != null))
                                    throw UnsupportedFloatLayout("Audio control allocation has no represented ordinary source box")
                                val minimumFloor = part.minimumWidth(containingWidth)?.let { value ->
                                    if (!value.isFinite() || value < 0f || value > TablePixelLimit)
                                        throw UnsupportedFloatLayout("Authored child minimum exceeds the native range")
                                    ceil(value).toInt()
                                }
                                if (minimumFloor != null && (part.blockViewport != null || part.fixedMarginTable != null ||
                                        part.pairedMarginTable != null || part.intrinsicMarginTable != null || part.blockBox != null))
                                    throw UnsupportedFloatLayout("Responsive table minima require an extended sizing policy")
                                if (minimumFloor != null && (exact != null || !part.widthFromContent && !part.atomicInline))
                                    throw UnsupportedFloatLayout("Table minimum requires its intrinsic content owner")
                                val paired = part.pairedMarginTable
                                val intrinsicOwner = part.intrinsicMarginTable
                                if (paired != null || intrinsicOwner != null) {
                                    val owner = paired ?: checkNotNull(intrinsicOwner)
                                    val family = if (intrinsicOwner != null) "Intrinsic" else "Paired"
                                    val source = owner.table
                                    val policy = source.blockViewport
                                        ?: throw UnsupportedFloatLayout("$family table block policy is unavailable")
                                    val floating = source.floatViewport
                                    val intrinsicDirection = policy.intrinsicContainingDirection
                                    val narrow = paired != null || part.blockViewport != null
                                    val resolveBox = part.pairedBlockBox
                                    if (paired != null && intrinsicOwner != null ||
                                        (intrinsicOwner != null && (floating != null || intrinsicDirection == null || owner.containingDirection != intrinsicDirection)) ||
                                        (paired != null && (floating == null || intrinsicDirection != null || owner.containingDirection != floating.containingDirection)) ||
                                        (if (narrow) part.blockViewport !== policy || resolveBox == null else part.blockViewport != null || resolveBox != null) ||
                                        part.blockBox != null || part.autoMarginTable != null || part.autoMargins != null ||
                                        part.fixedMarginTable != null || part.floatSide != null || part.atomicInline ||
                                        !part.widthFromContent || part.scrollport != null || part.overflowViewport || policy.focusPaint == null)
                                        throw UnsupportedFloatLayout("$family table measurement owner is inconsistent")
                                    if (intrinsicOwner != null && (source.caption.isNotEmpty() || source.captionBlocks?.isNotEmpty() == true))
                                        throw UnsupportedFloatLayout("Intrinsic table focus with a caption is unavailable.")
                                    widths.getValue(index).update(containingWidth)
                                    val input = tableMarginInputs[index]
                                        ?: throw UnsupportedFloatLayout("$family table measure owner is unavailable")
                                    val measurable = childMeasurables.getValue(index)
                                    val query = input.beginBlockIntrinsicQuery()
                                    measurable.minIntrinsicWidth(Constraints.Infinity)
                                    val intrinsic = input.blockIntrinsicsReady(query)
                                    val margins = part.margins(containingWidth)
                                    var candidate: NativeTableBlockBox? = null
                                    var candidateWidth = 0
                                    var predicted: NativeBlockMeasure? = null
                                    pairedCommits[index] = { placed ->
                                        val expected = predicted ?: throw UnsupportedFloatLayout("$family table used height is unavailable")
                                        if (kotlin.math.abs(placed.bounds.width() - expected.usedWidth) > .01f ||
                                                kotlin.math.abs(placed.bounds.height() - expected.height) > .01f)
                                            throw UnsupportedFloatLayout("$family table final allocation changed after intrinsic fitting")
                                        val box = candidate
                                        if (narrow) input.beginBlock(containingWidth,
                                            box ?: throw UnsupportedFloatLayout("$family table used width is unavailable"))
                                        else input.begin(containingWidth, candidateWidth, intrinsic.minimum.toInt())
                                        val placeable = measurePart(index, Constraints(minWidth = candidateWidth, maxWidth = candidateWidth))
                                        val actual = input.ready(placeable.width, placeable.height)
                                        if (actual.blockBox !== box || actual.scrolling != narrow ||
                                            kotlin.math.abs(actual.placementWidth - expected.usedWidth) > .01f ||
                                            kotlin.math.abs(actual.placementHeight - expected.height) > .01f)
                                            throw UnsupportedFloatLayout("$family table measured geometry differs from intrinsic fitting")
                                    }
                                    NativeFloatContextPart.Child(part.id, NativeBlockWidth.Auto, { request ->
                                        if (request.containingWidth != containingWidth.toFloat() || request.requestedWidth != null)
                                            throw UnsupportedFloatLayout("$family table containing interval changed")
                                        val box = if (narrow) checkNotNull(resolveBox)(containingWidth, request.assignedWidth, intrinsic) else null
                                        val minimum = if (box != null) checkNotNull(resolveBox)(containingWidth, request.assignedWidth,
                                            ContainerWidths(intrinsic.minimum, intrinsic.minimum)).borderWidth else intrinsic.minimum
                                        if (box != null && (box.policy !== policy || box.floatPolicy !== floating || box.fixedMargins != margins))
                                            throw UnsupportedFloatLayout("$family table source box changed during fitting")
                                        val allocated = if (box != null) ceil(box.borderWidth).toInt()
                                            else intrinsicTableGridWidth(request.availableWidth, intrinsic)
                                        if (box != null) input.beginBlock(containingWidth, box)
                                        else input.begin(containingWidth, allocated, intrinsic.minimum.toInt())
                                        val height = measurable.maxIntrinsicHeight(allocated)
                                        if (height !in 0..TablePixelLimit)
                                            throw UnsupportedFloatLayout("$family table height cannot be fitted at its assigned width")
                                        val edges = (box?.insets?.top ?: 0f) + (box?.insets?.bottom ?: 0f)
                                        val actualHeight = height - ceil(edges).toInt() + edges
                                        NativeBlockMeasure(box?.borderWidth ?: allocated.toFloat(), minimum, actualHeight).also {
                                            candidate = box; candidateWidth = allocated; predicted = it
                                        }
                                    }, part.gapAfter, margins = margins, gapBefore = part.gapBefore,
                                        clear = part.clear, logicalObject = part.logicalObject,
                                        pairedViewportDirection = owner.containingDirection)
                                } else {
                                if (part.pairedBlockBox != null)
                                    throw UnsupportedFloatLayout("Paired table box has no source owner")
                                val autoTable = part.autoMarginTable
                                val separateCornerGrid = autoTable?.blockViewport?.isSeparateCornerGrid == true
                                val numericBlockBox = if (separateCornerGrid) part.blockBox?.invoke(containingWidth) else null
                                val autoMargins = if (separateCornerGrid) numericBlockBox?.margins
                                    ?: NativeTableAutoMargins(part.margins(containingWidth), false, false) else part.autoMargins
                                val fixedTable = part.fixedMarginTable
                                if (fixedTable != null) {
                                    val source = fixedTable.table
                                    val policy = source.floatViewport
                                        ?: throw UnsupportedFloatLayout("Fixed table source policy is unavailable")
                                    if (autoTable != null || autoMargins != null || part.blockViewport != null || part.blockBox != null ||
                                        part.atomicInline || !part.widthFromContent || part.scrollport != null || part.overflowViewport ||
                                        (part.preferredWidth(containingWidth) != null) != (source.style?.width != null) ||
                                        source.style?.floatSide != TableFloatSide.Right ||
                                        part.floatSide != null && part.floatSide != TableFloatSide.Right ||
                                        fixedTable.containingDirection != policy.containingDirection)
                                        throw UnsupportedFloatLayout("Fixed table measurement owner is inconsistent")
                                }
                                val fixedMargins = fixedTable?.let { part.margins(containingWidth) }
                                val tableStyle = part.blockViewport?.boxStyle ?: autoTable?.style
                                val containingDirection = if (autoTable != null || autoMargins != null) {
                                    if (autoTable == null || autoMargins == null ||
                                        (!separateCornerGrid && tableStyle?.marginValues == null) ||
                                        (separateCornerGrid && (part.autoMargins != null || autoMargins.leftAuto || autoMargins.rightAuto ||
                                            part.overflowViewport || autoTable.blockViewport?.focusPaint == null ||
                                            (if (part.blockViewport == null) numericBlockBox != null else
                                                numericBlockBox == null || numericBlockBox.policy !== part.blockViewport || numericBlockBox.floatPolicy != null))) ||
                                        tableStyle == null || tableStyle.isInline || tableStyle.floatSide != null ||
                                        part.atomicInline || part.floatSide != null || !part.widthFromContent || part.scrollport != null)
                                        throw UnsupportedFloatLayout("Table automatic margin owner is inconsistent")
                                    tableStyle.containingDirection
                                        ?: throw UnsupportedFloatLayout("Table containing direction is unavailable")
                                } else null
                                if ((part.blockViewport != null) != (part.blockBox != null) ||
                                    part.blockViewport != null && (autoTable == null || autoTable.blockViewport !== part.blockViewport))
                                    throw UnsupportedFloatLayout("Table block viewport owner is inconsistent")
                                val blockBox = numericBlockBox ?: part.blockBox?.invoke(containingWidth)
                                widths.getValue(index).update(containingWidth)
                                val exactAllocation = exact?.invoke(available)?.also { value ->
                                    if (!value.isFinite() || value < 0f || value > TablePixelLimit)
                                        throw UnsupportedFloatLayout("Disclosure label allocation exceeds native geometry")
                                    exactWidths.getValue(index).update(value)
                                }
                                val atomic = if (part.atomicInline) measurePart(index, Constraints(maxWidth = containingWidth)) else null
                                if (minimumFloor != null && atomic != null && atomic.width < minimumFloor)
                                    throw UnsupportedFloatLayout("Inline table minimum exceeds its represented atomic allocation")
                                var intrinsicMinimum: Int? = null
                                val allocated = exactAllocation?.let { ceil(it).toInt() } ?:
                                    blockBox?.let { ceil(it.borderWidth).toInt() } ?: atomic?.width ?: if (part.widthFromContent) {
                                    val measurable = childMeasurables.getValue(index)
                                    val naturalMinimum = measurable.minIntrinsicWidth(Constraints.Infinity)
                                    val maximum = measurable.maxIntrinsicWidth(Constraints.Infinity)
                                    if (naturalMinimum > TablePixelLimit || maximum < naturalMinimum)
                                        throw UnsupportedFloatLayout("Rich child intrinsic width exceeds the native range")
                                    val minimum = maxOf(naturalMinimum, minimumFloor ?: 0)
                                    intrinsicMinimum = minimum
                                    val margins = fixedMargins ?: part.margins(containingWidth)
                                    val available = (containingWidth - ceil(margins.left + margins.right).toInt()).coerceAtLeast(0)
                                    val used = maxOf(minimum, part.preferredWidth(containingWidth) ?: minOf(available, maximum))
                                    // Only a top-level scrolling table has a viewport distinct from its
                                    // real overwide grid. Nested grids stay on their outer table's surface.
                                    if (part.overflowViewport) minOf(available, used) else used
                                } else part.width(containingWidth).let { if (part.documentScrollable) it else it.coerceAtLeast(0) }
                                if (part.documentScrollable && allocated !in 0..TablePixelLimit)
                                    throw UnsupportedFloatLayout("Audio control allocation exceeds native geometry")
                                if (autoTable != null || fixedTable != null) {
                                    val minimum = blockBox?.let { allocated } ?: intrinsicMinimum
                                        ?: throw UnsupportedFloatLayout("Table intrinsic minimum is unavailable")
                                    if (minimum !in 0..TablePixelLimit || allocated !in 0..TablePixelLimit)
                                        throw UnsupportedFloatLayout("Table automatic margin measurement exceeds the native range")
                                    val input = tableMarginInputs[index]
                                        ?: throw UnsupportedFloatLayout("Table automatic margin measure owner is unavailable")
                                    if (blockBox == null) input.begin(containingWidth, allocated, minimum)
                                    else input.beginBlock(containingWidth, blockBox)
                                    val placeable = measurePart(index, Constraints(minWidth = allocated, maxWidth = allocated))
                                    val box = input.ready(placeable.width, placeable.height)
                                    if (fixedTable != null && (box.scrolling || box.blockBox != null ||
                                            box.borderWidth != box.viewportWidth))
                                        throw UnsupportedFloatLayout("Fixed table border was replaced by a viewport")
                                    // The one real measurement supplies the final caption/grid border box.
                                    // Exclusion placement may move it but must not remeasure its Compose owner.
                                    NativeFloatContextPart.Child(part.id, NativeBlockWidth.FixedPx(box.placementWidth), { request ->
                                        if (request.requestedWidth != box.placementWidth)
                                            throw UnsupportedFloatLayout("Table automatic margin placement changed its measured width")
                                        NativeBlockMeasure(box.placementWidth,
                                            if (box.blockBox == null) box.minimumWidth.toFloat() else box.placementWidth,
                                            box.placementHeight)
                                    }, part.gapAfter, floatSide = if (fixedTable != null) part.floatSide else null,
                                        margins = fixedMargins ?: checkNotNull(autoMargins).fixed,
                                        requiresUnobstructedText = part.requiresUnobstructedText, gapBefore = part.gapBefore,
                                        clear = part.clear, logicalObject = part.logicalObject,
                                        autoMarginBox = box.takeIf { autoTable != null }, autoMargins = autoMargins,
                                        containingDirection = containingDirection,
                                        fixedMarginBox = box.takeIf { fixedTable != null },
                                        fixedMarginDirection = fixedTable?.containingDirection)
                                } else if (exactAllocation != null) {
                                    val measured = checkNotNull(part.exactMeasure).invoke(exactAllocation)
                                    if (measured.block.usedWidth != exactAllocation)
                                        throw UnsupportedFloatLayout("Disclosure measurement changed its original allocation")
                                    val placeable = measurePart(index, Constraints(minWidth = allocated, maxWidth = allocated))
                                    if (placeable.width != allocated || placeable.height != ceil(measured.block.height).toInt())
                                        throw UnsupportedFloatLayout("Disclosure View allocation differs from its native used box")
                                    NativeFloatContextPart.Child(part.id, NativeBlockWidth.FixedPx(exactAllocation), { request ->
                                        if (request.requestedWidth != exactAllocation)
                                            throw UnsupportedFloatLayout("Disclosure placement changed its measured width")
                                        measured.block
                                    }, part.gapAfter, part.floatSide, part.margins(containingWidth), part.requiresUnobstructedText,
                                        part.gapBefore, part.clear, false, exactContainingWidth = available, inkBounds = measured.ink)
                                } else NativeFloatContextPart.Child(part.id, NativeBlockWidth.FixedPx(allocated.toFloat()), { request ->
                                    val childWidth = ceil(request.requestedWidth ?: allocated.toFloat()).toInt()
                                    val placeable = atomic ?: measurePart(index, Constraints(minWidth = childWidth, maxWidth = childWidth))
                                    NativeBlockMeasure(placeable.width.toFloat(), placeable.width.toFloat(), placeable.height.toFloat())
                                }, part.gapAfter, part.floatSide, part.margins(containingWidth), part.requiresUnobstructedText,
                                    part.gapBefore, part.clear, part.logicalObject, ordinaryDirection = part.ordinaryDirection)
                                }
                            }
                        } } }
                        val geometry = NativeFloatContextGeometry.build(width, specifications(parts, width), containAtEnd,
                            ownInput?.carried.orEmpty(), allowProtrudingFloats = !containAtEnd,
                            adjoining = ordinaryBody || adjoining || ownInput?.measurement?.value?.policy?.marginCollapse != null,
                            marginCollapse = if (ordinaryBody) NativeMarginCollapse(true, true) else
                                ownInput?.measurement?.value?.policy?.marginCollapse ?: NativeMarginCollapse(false, false),
                            bodyAdjoining = ordinaryBody, absoluteScope = absoluteScope)
                        // The allocator and ordinary-margin preparation may probe several widths.
                        // Commit only the final real owner, once, after those pure probes finish.
                        pairedCommits.forEach { (index, commit) ->
                            val id = (leaves[index] as NativeFloatContextSpec.Child).id
                            geometry.children.singleOrNull { it.id == id }?.let(commit)
                        }
                        try { Constraints.fixed(width, geometry.height) }
                        catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Context exceeds the native Compose measurement range") }
                        val mediaIndices = mediaSlots.map { it.index }.filter { geometry.positionedGroupsAtSource(it).isNotEmpty() }
                        if (mediaIndices.isNotEmpty()) {
                            val phases = mediaIndices.associate { sourcePaintIndices.getValue(leaves[it]) to (paintParts.size + it) }
                            val sequence = try { nativeContextMediaPaintSequence(paintTree(parts), phases, absoluteScope) }
                                catch (failure: IllegalArgumentException) {
                                    throw UnsupportedFloatLayout(failure.message ?: "Nested media paint phase unavailable")
                                }
                            paintRanks = java.util.IdentityHashMap<NativeFloatContextSpec, Int>().apply {
                                sequence.forEachIndexed { rank, source -> if (source < paintParts.size) put(paintParts[source], rank) }
                            }
                            mediaRanks = mediaIndices.associateWith { sequence.indexOf(paintParts.size + it).also { rank -> check(rank >= 0) } }
                        }
                        val inputGeometry = if (!positioned && mediaRanks.isEmpty() && delegatedTables.isEmpty()) geometry else NativeContextPaintInput(geometry,
                            leaves.indices.associateWith { paintRanks.getValue(leaves[it]) },
                            leaves.filterIsInstance<NativeFloatContextSpec.Child>().associate { it.id to paintRanks.getValue(it) },
                            paintParts.filterIsInstance<NativeFloatContextSpec.Container>()
                                .filter { it.relativeAuto || it.absolute != null || it.absolutePosition != null || it.absoluteStatic != null || it.decoration != null }.map { group ->
                                    NativePaintBox(group.id, paintRanks.getValue(group),
                                        flatten(group.preparedParts.orEmpty()).map { leaf ->
                                            leaves.indexOfFirst { it === leaf }.also { check(it >= 0) }
                                        }.toSet())
                                }, mediaRanks)
                        onInputGeometry?.invoke(geometry, inputGeometry)
                        val delegatedOverflow = delegatedTables.mapNotNull { (id, owner) ->
                            geometry.children.singleOrNull { it.id == id }?.bounds?.let { bounds ->
                                owner.documentOverflow(NativeFloatBounds(bounds.left, bounds.top, bounds.right, bounds.bottom))
                            }
                        }
                        // These are measured descendant surface allocations. They enlarge the
                        // painting surface, never this context's normal box or fallback input.
                        val surfaceExtents = delegatedOverflow.fold(inputGeometry.extents) { extents, overflow ->
                            extents.copy(ink = enclosingBounds(extents.ink, overflow.physical))
                        }
                        val physical = NativeSurfaceGeometry(NoPaintGeometry(inputGeometry), NativeSurfaceBox.from(surfaceExtents))
                        try { Constraints.fixed(physical.width, physical.height) }
                        catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Context overflow exceeds the native Compose measurement range") }
                        preparedSurface = physical
                        if (documentSurface) {
                            if (paintParts.any { it is NativeFloatContextSpec.Container && (it.absolutePosition != null || it.absoluteStatic != null) ||
                                    it is NativeFloatContextSpec.Child && it.documentScrollable } ||
                                delegatedTables.values.any { it.ordinaryAbsolute }) {
                                val scrollable = delegatedOverflow.fold(geometry.scrollableBounds) { bounds, overflow ->
                                    enclosingBounds(bounds, overflow.scrollable) ?: bounds
                                }
                                if (documentPublisher == null && nativeDocumentHorizontalExtent(width, scrollable, documentRtl).overflow > 0f)
                                    throw UnsupportedFloatLayout("Document horizontal overflow has no scroll owner")
                                documentScrollBounds = scrollable
                                // A negative item-local paint origin is not extra scrollable
                                // space before the document start. Keep normal content in place.
                                documentExtent = nativeDocumentScrollableVerticalExtent(geometry.height, scrollable)
                            } else documentExtent = nativeDocumentVerticalExtent(geometry.height,
                                physical.surface.top, physical.surface.top + physical.surface.height)
                            try { Constraints.fixed(width, checkNotNull(documentExtent).height) }
                            catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Document overflow exceeds Compose measurement range") }
                        }
                        if (documentSurface) documentPublisher?.publish(documentOwner, width, documentScrollBounds)
                        if (!localScrollport) delegatedCell?.observedScopeContext(geometry)
                        onMeasuredGeometry?.invoke(geometry, inputGeometry)
                        Result.success(geometry)
                    } catch (failure: UnsupportedFloatLayout) { Result.failure(failure) }
                    if (result.isFailure) onMeasuredGeometry?.invoke(null, null)
                    if (documentSurface && (width == null || result.isFailure)) documentPublisher?.remove(documentOwner)
                    if (result.isFailure && width != null) slots.forEach { (index, part) ->
                        if (index !in attempted) {
                            val childWidth = try {
                                if (localScrollport && part is NativeFloatContextSpec.Child && part.widthFromContent)
                                    maxOf(width, childMeasurables.getValue(index).minIntrinsicWidth(Constraints.Infinity))
                                        .coerceAtMost(TablePixelLimit) else width
                            } catch (_: UnsupportedFloatLayout) { width }
                            val childConstraints = Constraints(maxWidth = childWidth)
                            try {
                                if (part is NativeFloatContextSpec.Flow) flowRequests[index] = flows.getValue(index).request(
                                    constraints, childConstraints, environment,
                                    NativeFlowParentPolicy(composition, containAtEnd, part.box, part.gapAfter), emptyList())
                                if (part is NativeFloatContextSpec.Container) containerRequests[index] = containers.getValue(index).request(
                                    constraints, childConstraints, environment,
                                    NativeFlowParentPolicy(composition, containAtEnd, null, 0f), emptyList())
                            } catch (_: UnsupportedFloatLayout) { }
                            // Native preparation may refuse while the same slot still owns real
                            // Compose fallback content. Measure it once without publishing geometry.
                            try { measurePart(index, childConstraints) }
                            catch (_: UnsupportedFloatLayout) { /* measurePart retains this failure. */ }
                        }
                    }
                    val flowGeometry: Map<Int, FloatTextGeometry> = flows.mapNotNull { (index, input) ->
                        val placeable = measured[index]
                        flowRequests[index]?.let(input::ready)
                            ?.takeIf { placeable != null && it.width == placeable.width && it.height == placeable.height }
                            ?.let { index to it }
                    }.toMap() + containers.mapNotNull { (index, input) ->
                        val placeable = measured[index]
                        containerRequests[index]?.let(input::measured)?.let { publication ->
                            publication.result.getOrNull() ?: publication.fallbackGeometry.takeIf { publication.result.isFailure }
                        }?.takeIf { placeable != null && it.width == placeable.width && it.height == placeable.height }
                            ?.let { index to it }
                    }.toMap()
                    val pass = NativeContextPass(width, result, measured.mapValues { it.value.height }, failed, flowGeometry,
                        preparedSurface, documentExtent.takeIf { result.isSuccess })
                    if (result.isFailure) {
                        delegatedTables.values.forEach { it.refuse("The containing native layout did not publish current geometry",
                            "stage=containing native preparation; cause=${result.exceptionOrNull()}") }
                        delegatedCell?.let { cell -> cell.table.refuse("The original table cell did not publish current native geometry",
                            "stage=cell native preparation; cell=${cell.index}; cause=${result.exceptionOrNull()}") }
                    } else {
                        val geometry = result.getOrThrow()
                        val originY = pass.documentExtent?.origin?.toFloat() ?: 0f
                        delegatedTables.forEach { (id, owner) ->
                            val allocation = geometry.children.singleOrNull { it.id == id }
                            if (allocation == null) owner.refuse("The original delegated table allocation is absent")
                            else {
                                // Other opaque children or another positioned phase have no complete
                                // envelope here. Preserve their existing fallback until that join exists.
                                val complete = interactionOwner && delegatedSourceRevision != null && geometry.children.size == 1 && !positioned && !positionedParent && ownInput == null && mediaRanks.isEmpty() &&
                                    geometry.inputLeaves().all { it.geometry is NativeFloatGeometry || it.geometry is NativeRuleGeometry }
                                if (!complete) owner.refuse("The delegated table needs one complete original Entry owner",
                                    "stage=known root scope; interactionOwner=$interactionOwner; children=${geometry.children.size}; " +
                                        "sourceKnown=${delegatedSourceRevision != null}; positioned=$positioned/$positionedParent; " +
                                        "nested=${ownInput != null}; mediaPhases=${mediaRanks.size}")
                                val ordinary = geometry.inputLeaves()
                                val otherInk = if (!complete) null else ordinary.flatMap { leaf ->
                                    leaf.geometry.ordinaryPaintBounds.map { it.translated(leaf.x, leaf.y + originY) }
                                } + decorated.filterNot { group -> sourceIds(group.preparedParts.orEmpty()).contains(id) }
                                    .mapNotNull { group -> geometry.ordinaryBounds[group.id]?.let {
                                        NativeFloatBounds(it.left, it.top + originY, it.right, it.bottom + originY)
                                    } }
                                val childBounds = geometry.children.map { NativeFloatBounds(it.bounds.left,
                                    it.bounds.top + originY, it.bounds.right, it.bounds.bottom + originY) }
                                val rootInputBoxes = listOf(NativeFloatBounds(0f, originY, geometry.width.toFloat(),
                                    originY + geometry.height)) + geometry.ordinaryBounds.values.map {
                                    NativeFloatBounds(it.left, it.top + originY, it.right, it.bottom + originY)
                                }
                                val rootFallbackInput = rootInputBoxes.flatMap {
                                    nativeInputOutsideChildren(it, childBounds)
                                }
                                val otherInput = if (!complete) null else ordinary.flatMap { leaf ->
                                    listOfNotNull(leaf.geometry.extents.interaction?.translated(leaf.x, leaf.y + originY))
                                }
                                owner.measured(NativeFloatBounds(allocation.bounds.left, allocation.bounds.top + originY,
                                    allocation.bounds.right, allocation.bounds.bottom + originY), otherInk, otherInput, rootFallbackInput)
                            }
                        }
                    }
                    auxiliary.update(pass)
                    textPasses.values.forEach { it.update(pass) }
                    decorationPasses.values.forEach { it.update(pass) }
                    mediaPasses.values.forEach { it.update(pass) }
                    val textPaint = textSlots.mapIndexed { slot, index -> index to
                        measurables[slots.size + slot].measure(Constraints.fixed(0, 0)) }.toMap()
                    val decorationPaint = decorated.mapIndexed { slot, part -> part.id to
                        measurables[slots.size + textSlots.size + slot].measure(Constraints.fixed(0, 0)) }.toMap()
                    val surface = measurables.last().measure(constraints)
                    // The fallback surface establishes exact child tops before these paint-only slots.
                    val mediaPaint = mediaSlots.mapIndexed { slot, row -> row.index to
                        measurables[slots.size + textSlots.size + decorated.size + slot].measure(Constraints.fixed(0, 0)) }.toMap()
                    val cellBaselines = result.getOrNull()?.textBaselines?.takeIf { publishCellBaselines }
                    val cellBaselineOrigin = pass.documentExtent?.origin ?: 0
                    val alignmentLines = cellBaselines?.let { lines -> listOfNotNull<Pair<androidx.compose.ui.layout.AlignmentLine, Int>>(
                        lines.first?.let { androidx.compose.ui.layout.FirstBaseline to (it + cellBaselineOrigin).roundToInt() },
                        lines.last?.let { androidx.compose.ui.layout.LastBaseline to (it + cellBaselineOrigin).roundToInt() }).toMap() } ?: emptyMap()
                    val measuredLayout = layout(surface.width, surface.height, alignmentLines) {
                        val geometry = result.getOrNull()
                        val documentOrigin = pass.documentExtent?.origin ?: 0
                        if (geometry == null) {
                            pass.fallbackTops.forEach { (index, top) ->
                                if ((leaves[index] is NativeFloatContextSpec.Flow || leaves[index] is NativeFloatContextSpec.Container) && top < surface.height)
                                    measured[index]?.let {
                                        flowPlacements.getValue(index).remainder = Offset.Zero
                                        it.placeRelative(0, top.toInt())
                                    }
                            }
                            surface.place(0, 0)
                            pass.fallbackTops.forEach { (index, top) ->
                                if (leaves[index] is NativeFloatContextSpec.Child && top < surface.height)
                                    measured[index]?.placeRelative(0, top.toInt())
                            }
                            mediaPaint.values.forEach { it.place(0, 0) }
                        } else {
                            decorated.forEach { part -> decorationPaint.getValue(part.id).place(0, documentOrigin,
                                zIndex = paintRanks.getValue(part).toFloat()) }
                            // Text and rich-flow painters follow the same order as their selectable
                            // intervals, even when authored zero heights make their ink overlap.
                            // Each existing rich child remains composed and measured once.
                            leaves.forEachIndexed { index, part -> when (part) {
                                is NativeFloatContextSpec.Text, is NativeFloatContextSpec.Rule ->
                                    textPaint.getValue(index).place(0, documentOrigin, zIndex = paintRanks.getValue(part).toFloat())
                                is NativeFloatContextSpec.Flow -> {
                                    geometry.flowChildren.firstOrNull { it.id == part.id }?.let { placed ->
                                        val x = floor(placed.bounds.left).toInt()
                                        val y = floor(placed.bounds.top).toInt()
                                        flowPlacements.getValue(index).remainder = Offset(placed.bounds.left - x, placed.bounds.top - y)
                                        measured.getValue(index).place(x, y + documentOrigin, zIndex = paintRanks.getValue(part).toFloat())
                                    }
                                }
                                is NativeFloatContextSpec.Container -> {
                                    geometry.flowChildren.firstOrNull { it.id == part.id }?.let { placed ->
                                        val x = floor(placed.bounds.left).toInt()
                                        val y = floor(placed.bounds.top).toInt()
                                        flowPlacements.getValue(index).remainder = Offset(placed.bounds.left - x, placed.bounds.top - y)
                                        measured.getValue(index).place(x, y + documentOrigin, zIndex = paintRanks.getValue(part).toFloat())
                                    }
                                }
                                else -> Unit
                            } }
                            val lastRank = paintParts.size + mediaRanks.size
                            surface.place(0, 0, zIndex = lastRank.toFloat())
                            geometry.children.forEach { placed ->
                                val index = leaves.indexOfFirst { it is NativeFloatContextSpec.Child && it.id == placed.id }
                                val childOwner = leaves[index] as NativeFloatContextSpec.Child
                                if (childOwner.exactWidth != null || childOwner.autoMarginTable != null || childOwner.fixedMarginTable != null || childOwner.pairedMarginTable != null || childOwner.intrinsicMarginTable != null || childOwner.ordinaryDirection != null) {
                                    val x = floor(placed.bounds.left).toInt()
                                    val y = floor(placed.bounds.top).toInt()
                                    measured.getValue(index).placeWithLayer(x, y + documentOrigin,
                                        zIndex = if (positioned || mediaRanks.isNotEmpty() || delegatedTables.containsKey(placed.id))
                                            paintRanks.getValue(leaves[index]).toFloat()
                                            else paintParts.size.toFloat() + 1f) {
                                        translationX = placed.bounds.left - x
                                        translationY = placed.bounds.top - y
                                    }
                                } else measured.getValue(index).place(placed.bounds.left.roundToInt(), placed.bounds.top.roundToInt() + documentOrigin,
                                    // Root selection/focus belongs above positioned media. The
                                    // proved table-local group keeps that same existing overlay.
                                    zIndex = if (positioned || mediaRanks.isNotEmpty() || delegatedTables.containsKey(placed.id))
                                        paintRanks.getValue(leaves[index]).toFloat()
                                        else paintParts.size.toFloat() + 1f)
                            }
                            mediaRanks.forEach { (index, rank) -> mediaPaint.getValue(index).place(0, documentOrigin,
                                zIndex = rank.toFloat()) }
                        }
                    }
                    // A failed native build still places its real measured children. Export those
                    // fallback layout boxes under the same request so an enclosing viewport can
                    // expose their full width without turning glyph ink into a scroll range.
                    val fallbackBounds = if (result.isFailure) NativeFloatBounds(0f, 0f,
                        maxOf(surface.width, measured.values.maxOfOrNull { it.width } ?: 0).toFloat(),
                        surface.height.toFloat()) else null
                    val published = ticket?.let { started -> ownInput?.seal(started)?.let {
                        ownInput.publish(it, result, fallbackBounds)
                    } } == true
                    when {
                        citationIntrinsicDepth != 0 -> Unit
                        ownInput != null && ticket == null -> Unit
                        result.isFailure -> citationOwner?.reportFailure(
                            result.exceptionOrNull()?.message ?: "Native context geometry is unavailable")
                        ownInput == null || published -> citationOwner?.reportSuccess()
                        ticket != null -> citationOwner?.reportFailure(
                            "Native context preparation changed during measurement")
                    }
                    return measuredLayout
                }
            })
        }
        leaves.filterIsInstance<NativeFloatContextSpec.Text>().forEach { it.prepared.menu() }
    }
    }
}

private class NativeFlowSurfacePlacement {
    var remainder by mutableStateOf(Offset.Zero)
}

private data class NativeFlowSurfaceRequest(val constraints: Constraints,
    val flow: NativeFlowMeasureRequest?, val revision: Any)
private data class NativeFlowSurfaceAllocation(val request: NativeFlowSurfaceRequest,
    val width: Int, val height: Int, val surface: NativeSurfaceBox)
private class NativeFlowSurfaceResult { var allocation: NativeFlowSurfaceAllocation? = null }

private abstract class NativeFlowSurfaceMeasurePolicy : MeasurePolicy {
    override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
        measurables.single().minIntrinsicWidth(height)
    override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
        measurables.single().maxIntrinsicWidth(height)
    override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
        measurables.single().minIntrinsicHeight(width)
    override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
        measurables.single().maxIntrinsicHeight(width)
}

/** The transform belongs to real painted/input bounds, while the parent still sees the used box. */
@Composable
private fun <G : FloatTextGeometry> NativeFlowSurfaceSlot(input: NativeGeometryMeasureInput<G>, placement: NativeFlowSurfacePlacement,
    content: @Composable () -> Unit) {
    val request = remember { NativeLayoutInput<NativeFlowSurfaceRequest?>(null) }
    val result = remember { NativeFlowSurfaceResult() }
    Layout(content = {
        Layout(modifier = request.modifier, content = { Box { content() } },
            measurePolicy = object : NativeFlowSurfaceMeasurePolicy() {
                override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                    val current = checkNotNull(request.value)
                    val child = measurables.single().measure(current.constraints)
                    val geometry = input.geometry?.takeIf { it.width == child.width && it.height == child.height }
                    val surface = geometry?.let { NativeSurfaceBox.from(it.extents) }
                        ?: NativeSurfaceBox(0, 0, child.width, child.height)
                    result.allocation = NativeFlowSurfaceAllocation(current, child.width, child.height, surface)
                    return layout(surface.width, surface.height) { child.place(-surface.left, -surface.top) }
                }
            })
    }, measurePolicy = object : NativeFlowSurfaceMeasurePolicy() {
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
            val current = NativeFlowSurfaceRequest(constraints, input.measurement.value, input.semantic.revision)
            request.update(current)
            // Only the physical wrapper is unconstrained; its one real child receives exactly
            // the parent's original constraints and retains its existing measurement ticket.
            val physical = measurables.single().measure(Constraints())
            val allocation = checkNotNull(result.allocation)
            check(allocation.request == current)
            return layout(allocation.width, allocation.height) {
                physical.placeWithLayer(allocation.surface.left, allocation.surface.top) {
                    translationX = placement.remainder.x
                    translationY = placement.remainder.y
                }
            }
        }
    })
}

/** A paint-only zero-used slot; logical allocation and all interactions stay on the shared owner. */
@Composable
private fun NativeContextTextSurface(input: NativeLayoutInput<NativeContextPass?>, index: Int) {
    SubcomposeLayout(input.modifier) {
        val part = input.value?.result?.getOrNull()?.textPaintPart(index)
        if (part == null) layout(0, 0) { } else {
            val physical = NativeSurfaceGeometry(part.geometry)
            val paint = subcompose("paint") {
                Canvas(Modifier) { physical.paint(drawContext.canvas.nativeCanvas) }
            }.single().measure(Constraints.fixed(physical.width, physical.height))
            layout(0, 0) {
                paint.placeWithLayer(physical.surface.left, physical.surface.top) {
                    translationX = part.x; translationY = part.y
                }
            }
        }
    }
}

@Composable
private fun NativeContextPositionedSurface(input: NativeLayoutInput<NativeContextPass?>, index: Int,
    parentOwnsSuccessfulGroups: Boolean) {
    SubcomposeLayout(input.modifier) {
        val pass = input.value
        val geometry = pass?.result?.getOrNull()
        val groups = if (geometry != null) {
            if (parentOwnsSuccessfulGroups) emptyList() else geometry.positionedGroupsAtSource(index)
        } else {
            // A failed parent cannot export an aggregate owner. Its measured children still
            // paint once at the actual fallback positions, without a second composition.
            val top = pass?.fallbackTops?.get(index)
            if (top == null) emptyList() else pass?.flowGeometry?.get(index)?.positionedGroups.orEmpty()
                .map { it.translated(0f, top.toFloat()) }
        }
        val bounds = nativeBoundsOf(groups.flatMap { it.bounds })
        if (bounds == null) layout(0, 0) { } else {
            val left = floor(bounds.left).toInt()
            val top = floor(bounds.top).toInt()
            val width = ceil(bounds.right).toInt() - left
            val height = ceil(bounds.bottom).toInt() - top
            val paint = subcompose("paint") { Canvas(Modifier.clearAndSetSemantics { }) {
                val canvas = drawContext.canvas.nativeCanvas
                val saved = canvas.save()
                try {
                    canvas.translate(-left.toFloat(), -top.toFloat())
                    groups.forEach { it.paint(canvas) }
                } finally { canvas.restoreToCount(saved) }
            } }.single().measure(Constraints.fixed(width, height))
            layout(0, 0) { paint.place(left, top) }
        }
    }
}

@Composable
private fun NativeContainerPaintSurface(input: NativeLayoutInput<NativeContextPass?>, id: Int,
    decoration: NativeContainerDecoration) {
    SubcomposeLayout(input.modifier) {
        val box = input.value?.result?.getOrNull()?.ordinaryBounds?.get(id)
        if (box == null || box.isEmpty) layout(0, 0) { } else {
            val left = floor(box.left).toInt()
            val top = floor(box.top).toInt()
            val width = ceil(box.right).toInt() - left
            val height = ceil(box.bottom).toInt() - top
            val paint = subcompose("paint") { Canvas(Modifier) {
                val canvas = drawContext.canvas.nativeCanvas
                val saved = canvas.save()
                canvas.translate(-left.toFloat(), -top.toFloat())
                decoration.paint(canvas, box)
                canvas.restoreToCount(saved)
            } }.single().measure(Constraints.fixed(width, height))
            layout(0, 0) { paint.place(left, top) }
        }
    }
}

private class NativeContextPass(val width: Int?, val result: Result<NativeFloatContextGeometry>,
    val heights: Map<Int, Int>, val failures: Map<Int, UnsupportedFloatLayout>,
    val flowGeometry: Map<Int, FloatTextGeometry>, val surface: NativeSurfaceGeometry?,
    val documentExtent: NativeDocumentVerticalExtent? = null) {
    val fallbackTops = linkedMapOf<Int, Long>()
}

/** Sharing belongs to this direct sibling wrapper; the nested AndroidView's flag
 * does not cross a Compose LayoutNode boundary. Native owners still decide input. */
private data object NativeDelegatedPointerSharing : ModifierNodeElement<NativeDelegatedPointerSharingNode>() {
    override fun create() = NativeDelegatedPointerSharingNode()
    override fun update(node: NativeDelegatedPointerSharingNode) = Unit
    override fun InspectorInfo.inspectableProperties() { name = "nativeDelegatedPointerSharing" }
}

private class NativeDelegatedPointerSharingNode : Modifier.Node(), PointerInputModifierNode {
    override fun sharePointerInputWithSiblings() = true
    override fun onPointerEvent(pointerEvent: PointerEvent, pass: PointerEventPass, bounds: IntSize) = Unit
    override fun onCancelPointerInput() = Unit
}

/** Only native surfaces and failure text are subcomposed; live child controls stay in their slots. */
@Composable
private fun NativeFloatAuxiliary(input: NativeLayoutInput<NativeContextPass?>, parts: List<NativeFloatContextSpec>,
    linkColor: Color, revealIndex: Int?, revealToken: Any?, onRevealed: () -> Unit, interactionOwner: Boolean,
    delegatedCell: NativeDelegatedCellOwner? = null, stateTable: NativeDelegatedTableOwner? = null,
    sourceReveal: (suspend (Float?) -> Unit)? = null,
    revealUnavailable: (suspend () -> Unit)? = null) {
    val scrollClip = LocalNativeScrollClip.current
    val minimumTouch = LocalViewConfiguration.current.minimumTouchTargetSize
    val minimumTouchWidth = with(LocalDensity.current) { minimumTouch.width.toPx() }
    val minimumTouchHeight = with(LocalDensity.current) { minimumTouch.height.toPx() }
    val sharing = if (stateTable != null) NativeDelegatedPointerSharing else Modifier
    SubcomposeLayout(input.modifier.fillMaxWidth().then(sharing)) { constraints ->
        val pass = checkNotNull(input.value)
        val geometry = pass.result.getOrNull()
        if (geometry == null) {
            val reason = pass.result.exceptionOrNull()?.message ?: "Float geometry unavailable"
            val message = subcompose("unsupported-flow") {
                val observer = LocalNativeFloatContextFailureObserver.current
                LaunchedEffect(reason, observer) { observer?.invoke(reason) }
                LaunchedEffect(revealToken, sourceReveal != null, revealUnavailable != null) {
                    if (sourceReveal != null) sourceReveal(null)
                    else if (revealToken != null) revealUnavailable?.invoke()
                }
                ReaderLayoutUnavailable(reason)
            }.single().measure(constraints)
            val fallback = linkedMapOf<Int, Placeable>()
            if (pass.width != null) parts.forEachIndexed { index, part ->
                if (index !in pass.heights) {
                    fallback[index] = subcompose("fallback-part-$index") {
                        val failure = pass.failures[index]
                        check(failure != null || part is NativeFloatContextSpec.Text || part is NativeFloatContextSpec.Rule) {
                            "An unmeasured native child requires a retained measurement failure"
                        }
                        // A fallback subtree may emit zero or several document-order children.
                        Column {
                            if (failure != null) ReaderLayoutUnavailable(failure.message ?: "Child measurement unavailable")
                            else if (part is NativeFloatContextSpec.Text) part.prepared.fallback()
                            else if (part is NativeFloatContextSpec.Rule) AuthoredRuleSurface(part.metrics)
                        }
                    }.single().measure(Constraints(maxWidth = pass.width))
                }
            }
            var top = message.height.toLong()
            parts.indices.forEach { index ->
                pass.fallbackTops[index] = top
                top += (pass.heights[index] ?: fallback[index]?.height ?: 0).toLong()
            }
            val height = if (constraints.hasBoundedWidth) nativeFallbackHeight(constraints, top)
                else constraints.constrainHeight(top.coerceAtMost(TablePixelLimit.toLong()).toInt())
            // A failed context cannot publish an aggregate interaction owner to its parent.
            // Its successfully measured children therefore retain local fallback owners.
            val flowOwners = pass.flowGeometry.mapValues { (index, flow) ->
                val physical = NativeSurfaceGeometry(NoPaintGeometry(flow))
                subcompose("fallback-flow-$index") {
                    val coordinates = rememberNativeTableCoordinateBinding()
                    val citationNavigation = LocalNativeCitationNavigation.current
                    val citationParentReveal = rememberNativeCitationParentReveal()
                    AndroidView(modifier = (coordinates?.modifier ?: Modifier).then(citationParentReveal?.modifier ?: Modifier),
                        factory = { NativeFloatTextView(it, scrollClip) }, update = { view ->
                        view.updateScrollClip(scrollClip)
                        view.updateCitationNavigation(citationNavigation)
                        view.updateCitationParentReveal(citationParentReveal)
                        coordinates?.bind(view)
                        view.bind({ measuredWidth -> check(measuredWidth == physical.width); physical },
                            linkColor.copy(alpha = .25f).toArgb(), linkColor.toArgb())
                    })
                }.single().measure(Constraints.fixed(physical.width, physical.height)) to physical.surface
            }
            layout(message.width, height) {
                message.place(0, 0)
                fallback.forEach { (index, item) ->
                    val y = pass.fallbackTops.getValue(index)
                    if (y < height) item.placeRelative(0, y.toInt())
                }
                flowOwners.forEach { (index, owned) ->
                    val y = pass.fallbackTops.getValue(index)
                    if (y < height) owned.first.place(owned.second.left, y.toInt() + owned.second.top)
                }
            }
        } else {
            val allocatedHeight = pass.documentExtent?.height ?: geometry.height
            if (!interactionOwner) return@SubcomposeLayout layout(geometry.width, allocatedHeight) { }
            val physical = checkNotNull(pass.surface)
            val state = parts.filterIsInstance<NativeFloatContextSpec.Text>().mapNotNull { it.prepared.stateDescription }
                .distinct().joinToString(". ").ifEmpty { null }
            val text = subcompose("native-context") {
                val coordinates = rememberNativeTableCoordinateBinding()
                    val citationNavigation = LocalNativeCitationNavigation.current
                    val citationParentReveal = rememberNativeCitationParentReveal()
                var nativeView by remember { mutableStateOf<NativeFloatTextView?>(null) }
                val sourcePass = physical.takeIf { sourceReveal != null }
                val sourcePlacement = remember(revealToken, revealIndex, geometry.text.toString(), sourcePass) {
                    mutableStateOf<Pair<Any?, Float?>?>(null)
                }
                val currentSourcePlacement = rememberUpdatedState(sourcePlacement)
                val retainedView = nativeView
                DisposableEffect(retainedView, delegatedCell, stateTable) { onDispose {
                    retainedView?.let {
                        delegatedCell?.clear(it)
                        stateTable?.clearRootState(it)
                    }
                } }
                LaunchedEffect(revealToken, revealIndex, geometry.text.toString(), sourceReveal != null) {
                    if (revealIndex != null) {
                        if (sourceReveal != null) {
                            val placed = checkNotNull(snapshotFlow { currentSourcePlacement.value.value }.first {
                                it != null && it.first === revealToken
                            })
                            sourceReveal(placed.second)
                        } else {
                            withFrameNanos { }
                            if (nativeView?.revealLogicalOffset(geometry.partOffsets[revealIndex]) == true) onRevealed()
                        }
                    }
                }
                AndroidView(modifier = (coordinates?.modifier ?: Modifier).then(citationParentReveal?.modifier ?: Modifier).onGloballyPositioned { coordinates ->
                    if (sourceReveal != null) {
                        val offset = revealIndex?.let(geometry.partOffsets::getOrNull)
                        val leaf = geometry.inputLeaves().singleOrNull { it.offset == offset &&
                            (it.geometry as? NativeFloatGeometry)?.headingOwnerContentTop() != null }
                        val contentTop = (leaf?.geometry as? NativeFloatGeometry)?.headingOwnerContentTop()
                        val target = if (coordinates.isAttached && leaf != null && contentTop != null)
                            coordinates.localToWindow(Offset(0f, leaf.y + contentTop - physical.surface.top)).y else null
                        sourcePlacement.value = revealToken to target
                    }
                    delegatedCell?.let { it.viewCoordinates = coordinates; it.table.validateAfterPlacement() }
                    nativeView?.let { view ->
                        view.delegatedStateOwner = stateTable
                        stateTable?.measuredRootState(view, physical)
                        stateTable?.positionedRootState(view, coordinates)
                    }
                }, factory = { NativeFloatTextView(it, scrollClip).also { view -> nativeView = view } }, update = { view ->
                    view.updateScrollClip(scrollClip)
                        view.updateCitationNavigation(citationNavigation)
                        view.updateCitationParentReveal(citationParentReveal)
                    coordinates?.bind(view)
                    delegatedCell?.let { cell ->
                        cell.measured(view, physical, geometry.width, allocatedHeight, minimumTouchWidth, minimumTouchHeight,
                            scrollableBounds = if (cell.table.ordinaryAbsolute) geometry.scrollableBounds else null)
                    }
                    view.delegatedStateOwner = stateTable
                    stateTable?.measuredRootState(view, physical)
                    view.bind({ measuredWidth -> check(measuredWidth == physical.width); physical },
                        linkColor.copy(alpha = .25f).toArgb(), linkColor.toArgb(), state)
                })
            }.single().measure(Constraints.fixed(physical.width, physical.height))
            layout(geometry.width, allocatedHeight) {
                text.place(physical.surface.left, physical.surface.top + (pass.documentExtent?.origin ?: 0))
            }
        }
    }
}
