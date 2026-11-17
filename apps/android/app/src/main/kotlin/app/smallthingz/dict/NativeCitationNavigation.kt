package app.smallthingz.dict

import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

internal enum class CitationSourceSlot { Title, Preamble, Section, Reference }

/** Source ownership locates the lazy item; only its measured native range supplies pixels. */
internal data class CitationDestination(val marker: CitationMarker, val span: Span,
    val slot: CitationSourceSlot, val rowKey: String? = null, val referenceIndex: Int? = null,
    val graphical: Boolean = false)

internal fun citationDestinations(entry: Entry): Map<String, CitationDestination> {
    val result = linkedMapOf<String, CitationDestination>()
    var slot = CitationSourceSlot.Title
    var rowKey: String? = null
    var referenceIndex: Int? = null
    val visitor = PresentationSpanVisitor { spans, _ ->
        for (range in rubyGraphicalProjection(spans).ranges) {
            val source = range.span ?: continue
            val marker = source.citationMarker ?: continue
            val found = result[marker.anchor] ?: continue
            if (found.span === source && range.start < range.end)
                result[marker.anchor] = found.copy(graphical = true)
        }
    }
    visitor.onSpan = { source -> source.citationMarker?.let { marker ->
        require(marker.anchor !in result) { "Duplicate citation range anchor" }
        result[marker.anchor] = CitationDestination(marker, source, slot, rowKey, referenceIndex)
    } }
    visitor.spans(entry.displayTitle)
    slot = CitationSourceSlot.Preamble
    visitor.spans(entry.preamble)
    slot = CitationSourceSlot.Section
    for (row in entry.readingRows) {
        rowKey = row.key
        row.headingBlock?.let { visitor.block(it) }
        row.block?.let { visitor.block(it) }
    }
    slot = CitationSourceSlot.Reference
    rowKey = null
    entry.references.forEachIndexed { index, reference ->
        referenceIndex = index
        val blocks = reference.blocks
        if (blocks == null) visitor.spans(reference.spans) else visitor.blocks(blocks)
    }
    return result
}

internal fun citationFoldKeys(entry: Entry, destination: CitationDestination): Set<String> = when (destination.slot) {
    CitationSourceSlot.Title -> emptySet()
    CitationSourceSlot.Preamble -> setOf("preamble")
    CitationSourceSlot.Reference -> destination.referenceIndex?.let { referenceFoldKeys(entry, it) }.orEmpty()
    CitationSourceSlot.Section -> {
        val row = entry.readingRows.singleOrNull { it.key == destination.rowKey }
            ?: throw IllegalArgumentException("Citation source row is absent")
        val key = if (row.heading != null) row.key else row.sectionKey
        buildSet { add(key); if (row.heading == null && row.meaningSection) add(key + "-details") }
    }
}

internal fun citationScrollIndex(entry: Entry, destination: CitationDestination, folded: Set<String>): Int? =
    when (destination.slot) {
        CitationSourceSlot.Title -> 0
        CitationSourceSlot.Preamble -> 1 + if ("abbreviations" in folded) 0 else entry.textDetails.size
        CitationSourceSlot.Reference -> destination.referenceIndex?.let {
            referenceItemScrollIndex(entry, it, folded)
        }
        CitationSourceSlot.Section -> {
            val rows = visibleEntryReadingRows(entry, folded)
            val index = rows.indexOfFirst { it.key == destination.rowKey }
            if (index < 0) null else {
                val run = floatBodyRuns(rows, entry.bodyAdjoining, entry.language).firstOrNull { index in it }
                entryReadingStartIndex(entry, folded) + (run?.first ?: index)
            }
        }
    }

internal class NativeCitationRequest(val marker: CitationMarker, val externalRequest: EntryAnchorRequest?) {
    var revealOwner: NativeFloatTextView? = null
    var revealStarted = false
}
internal data class NativeCitationOwner(val view: NativeFloatTextView, val geometry: FloatTextGeometry)

/** One Entry visit owns these leases. Detach/rebind removes a stale measured source immediately. */
internal class NativeCitationNavigation {
    private val owners = java.util.IdentityHashMap<NativeFloatTextView, FloatTextGeometry>()
    private val preparations = java.util.IdentityHashMap<NativeCitationPreparationStatus, String?>()
    private val handler by lazy { android.os.Handler(android.os.Looper.getMainLooper()) }
    internal fun postStatus(block: () -> Unit) { handler.post { block() } }
    internal fun preparation(status: NativeCitationPreparationStatus, failure: String?, active: Boolean = true) {
        val existed = preparations.containsKey(status)
        val previous = if (active) preparations.put(status, failure) else preparations.remove(status)
        if (existed != active || previous != failure) revision++
    }
    fun failure(anchor: String): String? {
        val candidates = preparations.entries.filter { anchor in it.key.anchors }
        // A separately prepared fallback may still be measuring its real source.
        return candidates.takeIf { it.isNotEmpty() && it.all { row -> row.value != null } }?.first()?.value
    }
    var revision by mutableIntStateOf(0)
        private set
    var targetAnchor by mutableStateOf<String?>(null)
        private set
    var request by mutableStateOf<NativeCitationRequest?>(null)
        private set

    fun start(marker: CitationMarker, externalRequest: EntryAnchorRequest?) {
        targetAnchor = marker.anchor
        request = NativeCitationRequest(marker, externalRequest)
    }
    fun clear(): NativeCitationRequest? {
        val previous = request
        previous?.revealOwner?.cancelCitationReveal(previous)
        request = null
        targetAnchor = null
        return previous
    }
    fun complete(expected: NativeCitationRequest): Boolean {
        if (request !== expected) return false
        expected.revealOwner?.cancelCitationReveal(expected)
        request = null
        return true
    }
    fun publish(view: NativeFloatTextView, geometry: FloatTextGeometry) {
        if (geometry.citationMarkerRanges.isEmpty()) { remove(view); return }
        if (owners[view] === geometry) return
        owners[view] = geometry
        revision++
    }
    fun remove(view: NativeFloatTextView) {
        if (owners.remove(view) != null) revision++
    }
    fun owner(marker: CitationMarker): NativeCitationOwner? = owners.entries.mapNotNull { (view, geometry) ->
        val range = geometry.citationMarkerRanges.singleOrNull { it.marker.anchor == marker.anchor }
        if (range?.marker == marker && view.currentMeasuredGeometry === geometry)
            NativeCitationOwner(view, geometry) else null
    }.singleOrNull()
}

internal val LocalNativeCitationNavigation = staticCompositionLocalOf<NativeCitationNavigation?> { null }
internal val LocalNativeCitationTargetAnchor = staticCompositionLocalOf<String?> { null }
internal const val CitationRevealUnavailable = "Unable to position this citation."

/** A measured source can fail before it creates a View. Its own lease reports that refusal. */
internal class NativeCitationPreparationStatus internal constructor(
    private val registry: NativeCitationNavigation, internal val anchors: List<String>,
    private val preparationFailure: String?) {
    private var active = false
    private val geometryFailures = java.util.IdentityHashMap<Any, String>()
    internal fun activate() { active = true; publish() }
    internal fun dispose() { active = false; registry.preparation(this, null, active = false) }
    private fun publish() = registry.preparation(this, preparationFailure ?: geometryFailures.values.firstOrNull())
    fun reportGeometryFailure(reason: String, owner: Any = this) = report(reason, owner)
    fun reportGeometrySuccess(owner: Any = this) = report(null, owner)
    private fun report(reason: String?, owner: Any) {
        registry.postStatus { if (active) {
            if (reason == null) geometryFailures.remove(owner) else geometryFailures[owner] = reason
            publish()
        } }
    }
}

private class CitationPreparationIdentity(private val source: Any) {
    override fun equals(other: Any?): Boolean = other is CitationPreparationIdentity && source === other.source
    override fun hashCode(): Int = System.identityHashCode(source)
}

@Composable
internal fun rememberNativeCitationPreparation(source: Any, anchors: List<String>,
    failure: String?): NativeCitationPreparationStatus? {
    val registry = LocalNativeCitationNavigation.current ?: return null
    if (anchors.isEmpty()) return null
    val lease = remember(registry, CitationPreparationIdentity(source), anchors, failure) {
        NativeCitationPreparationStatus(registry, anchors.toList(), failure)
    }
    val owners = LocalNativeCitationGeometryOwners.current
    DisposableEffect(lease, owners) {
        lease.activate()
        owners.forEach { it.attach(lease) }
        onDispose { owners.forEach { it.detach(lease) }; lease.dispose() }
    }
    return lease
}

/** Failure belongs to the aggregate that measured these sources, not an intrinsic child probe. */
internal class NativeCitationGeometryOwner {
    private val sources = java.util.IdentityHashMap<NativeCitationPreparationStatus, Int>()
    internal fun attach(source: NativeCitationPreparationStatus) {
        val count = sources[source]
        // Membership changes in composition precede measurement. The previous result
        // did not measure this new source/font preparation; wait for its own pass.
        if (count == null) reportSuccess()
        sources[source] = (count ?: 0) + 1
    }
    internal fun detach(source: NativeCitationPreparationStatus) {
        val count = sources[source] ?: return
        if (count > 1) sources[source] = count - 1 else {
            sources.remove(source)
            source.reportGeometrySuccess(this)
            reportSuccess()
        }
    }
    fun reportFailure(reason: String) {
        sources.keys.toList().forEach { it.reportGeometryFailure(reason, this) }
    }
    fun reportSuccess() {
        sources.keys.toList().forEach { it.reportGeometrySuccess(this) }
    }
}
internal val LocalNativeCitationGeometryOwners = staticCompositionLocalOf<List<NativeCitationGeometryOwner>> { emptyList() }

@Composable
internal fun rememberNativeCitationGeometryOwner(
    sources: List<NativeCitationPreparationStatus>): NativeCitationGeometryOwner? {
    if (LocalNativeCitationNavigation.current == null) return null
    val owner = remember { NativeCitationGeometryOwner() }
    DisposableEffect(owner, sources) {
        sources.forEach(owner::attach)
        onDispose { sources.forEach(owner::detach) }
    }
    return owner
}

/** A suspended Compose relocation supplies the completion that View's Boolean API cannot. */
internal class NativeCitationParentReveal(private val requester: BringIntoViewRequester,
    private val scope: CoroutineScope) {
    private var coordinates: LayoutCoordinates? = null
    val modifier: Modifier = Modifier.bringIntoViewRequester(requester).onGloballyPositioned { coordinates = it }
    fun reveal(local: android.graphics.RectF, screen: android.graphics.RectF?,
        completed: (Boolean) -> Unit): () -> Unit = revealBounds(local, screen, completed, allowEmpty = false)

    /** Clipped source boxes can have a real zero extent; keep that point without a hit-area shim. */
    fun revealIncludingEmpty(local: android.graphics.RectF, screen: android.graphics.RectF?,
        completed: (Boolean) -> Unit): () -> Unit = revealBounds(local, screen, completed, allowEmpty = true)

    private fun revealBounds(local: android.graphics.RectF, screen: android.graphics.RectF?,
        completed: (Boolean) -> Unit, allowEmpty: Boolean): () -> Unit {
        val expected = coordinates
        val job = scope.launch {
            try {
                if (expected == null || !expected.isAttached) { completed(false); return@launch }
                val bounds = if (screen == null) Rect(local.left, local.top, local.right, local.bottom) else {
                    val corners = listOf(Offset(screen.left, screen.top), Offset(screen.right, screen.top),
                        Offset(screen.right, screen.bottom), Offset(screen.left, screen.bottom)).map(expected::screenToLocal)
                    if (corners.any { !it.x.isFinite() || !it.y.isFinite() }) { completed(false); return@launch }
                    Rect(corners.minOf { it.x }, corners.minOf { it.y }, corners.maxOf { it.x }, corners.maxOf { it.y })
                }
                if (listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).any { !it.isFinite() } ||
                    bounds.width < 0f || bounds.height < 0f || !allowEmpty && bounds.isEmpty) {
                    completed(false); return@launch
                }
                requester.bringIntoView(bounds)
                completed(coordinates === expected && expected.isAttached)
            } catch (cancelled: CancellationException) {
                completed(false)
                throw cancelled
            }
        }
        return { job.cancel() }
    }
}

@Composable
internal fun rememberNativeCitationParentReveal(): NativeCitationParentReveal? {
    if (LocalNativeCitationNavigation.current == null) return null
    val requester = remember { BringIntoViewRequester() }
    val scope = rememberCoroutineScope()
    return remember(requester, scope) { NativeCitationParentReveal(requester, scope) }
}
