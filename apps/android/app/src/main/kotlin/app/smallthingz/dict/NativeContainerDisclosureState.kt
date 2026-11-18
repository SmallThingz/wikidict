package app.smallthingz.dict

import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf

/** Equal data from a replacement source starts a new disclosure visit. */
internal class NativeContainerDisclosureSourceIdentity(private val source: Any) {
    override fun equals(other: Any?): Boolean = other is NativeContainerDisclosureSourceIdentity && source === other.source
    override fun hashCode(): Int = System.identityHashCode(source)
}

private class NativeDisclosureKey(val container: Container, val path: String, val referenceIndex: Int?) {
    override fun equals(other: Any?): Boolean = other is NativeDisclosureKey &&
        container === other.container && path == other.path && referenceIndex == other.referenceIndex
    override fun hashCode(): Int = (System.identityHashCode(container) * 31 + path.hashCode()) * 31 + (referenceIndex ?: -1)
}

/** One Entry epoch, with separate original reference slots despite equal displayed note paths. */
internal class NativeContainerDisclosureState private constructor(
    private val expanded: MutableMap<NativeDisclosureKey, Boolean>,
    val referenceIndex: Int?,
    private val scopes: MutableMap<Int, NativeContainerDisclosureState>,
) {
    constructor() : this(mutableStateMapOf(), null, mutableMapOf())

    fun inReference(index: Int): NativeContainerDisclosureState {
        require(index >= 0)
        return if (referenceIndex == index) this else scopes.getOrPut(index) {
            NativeContainerDisclosureState(expanded, index, scopes)
        }
    }

    fun isExpanded(container: Container, path: String): Boolean =
        expanded[NativeDisclosureKey(container, path, referenceIndex)] ?: !checkNotNull(container.disclosure).initiallyCollapsed

    fun toggle(container: Container, path: String) {
        expanded[NativeDisclosureKey(container, path, referenceIndex)] = !isExpanded(container, path)
    }

    fun expand(container: Container, path: String): Boolean {
        if (isExpanded(container, path)) return false
        expanded[NativeDisclosureKey(container, path, referenceIndex)] = true
        return true
    }

    fun isExpanded(owner: NativeContainerDisclosureOwner): Boolean =
        expanded[NativeDisclosureKey(owner.container, owner.path, owner.referenceIndex)] ?: !checkNotNull(owner.container.disclosure).initiallyCollapsed

    fun expandOwners(owners: List<NativeContainerDisclosureOwner>): Boolean {
        var changed = false
        for (owner in owners) if (!isExpanded(owner)) {
            expanded[NativeDisclosureKey(owner.container, owner.path, owner.referenceIndex)] = true
            changed = true
        }
        return changed
    }
}

/** A reader visit may recompose the same source; a replacement, even equal data, resets it. */
internal class NativeContainerDisclosureVisit {
    private var source: Entry? = null
    private var state: NativeContainerDisclosureState? = null
    fun stateFor(entry: Entry): NativeContainerDisclosureState {
        if (source !== entry) {
            source = entry
            state = NativeContainerDisclosureState()
        }
        return checkNotNull(state)
    }
}

internal val LocalNativeContainerDisclosureState = staticCompositionLocalOf<NativeContainerDisclosureState?> { null }

@Composable
internal fun rememberNativeContainerDisclosureState(source: Any): NativeContainerDisclosureState =
    LocalNativeContainerDisclosureState.current ?: remember(NativeContainerDisclosureSourceIdentity(source)) {
        NativeContainerDisclosureState()
    }

internal data class NativeContainerDisclosureOwner(val container: Container, val path: String,
    val rowKey: String?, val referenceIndex: Int?) {
    val contentPath: String get() = "$path/container/block-${checkNotNull(container.disclosure).contentIndex}"
    val content: Block get() = container.blocks[checkNotNull(container.disclosure).contentIndex.toInt()]
}

/** Inventory uses original indices even while the selected child has no rendered projection. */
internal class NativeContainerDisclosureIndex(entry: Entry) {
    val owners: List<NativeContainerDisclosureOwner>
    init {
        val result = mutableListOf<NativeContainerDisclosureOwner>()
        lateinit var block: (Block, String, String?, Int?) -> Unit
        fun table(value: Table, path: String, rowKey: String?, referenceIndex: Int?) {
            value.captionBlocks?.forEachIndexed { index, child ->
                block(child, "$path/caption/block-$index", rowKey, referenceIndex)
            }
            var cellIndex = 0
            value.rows.forEach { row -> row.forEach { cell ->
                val cellPath = "$path/cell-${cellIndex++}"
                val blocks = cell.blocks
                if (blocks != null) blocks.forEachIndexed { index, child -> block(child, "$cellPath/block-$index", rowKey, referenceIndex) }
                else cell.nestedTable?.let { table(it, "$cellPath/nested", rowKey, referenceIndex) }
            } }
        }
        block = { value, path, rowKey, referenceIndex ->
            val container = value.container
            when {
                container != null -> {
                    if (container.disclosure != null) result += NativeContainerDisclosureOwner(container, path, rowKey, referenceIndex)
                    container.blocks.forEachIndexed { index, child -> block(child, "$path/container/block-$index", rowKey, referenceIndex) }
                }
                value.table != null -> table(value.table, "$path/table", rowKey, referenceIndex)
                // Figure caption Containers already have explicit unsupported selection geometry. Do not
                // invent a renderer path or owner for those independently refused sinks.
            }
        }
        entry.readingRows.forEach { row -> row.block?.let { block(it, row.key, row.key, null) } }
        entry.references.forEachIndexed { index, reference -> reference.blocks?.forEachIndexed { blockIndex, value ->
            block(value, "reference-${reference.number}/block-$blockIndex", null, index)
        } }
        owners = result.toList()
    }

    fun enclosingPath(path: String, referenceIndex: Int? = null): List<NativeContainerDisclosureOwner> = owners.filter {
        it.referenceIndex == referenceIndex && (path == it.contentPath || path.startsWith(it.contentPath + "/"))
    }

    fun enclosingSpan(source: Span, rowKey: String?, referenceIndex: Int?): List<NativeContainerDisclosureOwner> = owners.filter { owner ->
        if (owner.rowKey != rowKey || owner.referenceIndex != referenceIndex) false else {
            var found = false
            PresentationSpanVisitor { _, _ -> }.apply { onSpan = { if (it === source) found = true } }.block(owner.content)
            found
        }
    }
}

internal fun Block.hasContainerDisclosure(): Boolean {
    var found = false
    PresentationSpanVisitor { _, _ -> }.apply { onContainer = { if (it.disclosure != null) found = true } }.block(this)
    return found
}

internal class NativeDisclosureAnchorRequest(val target: String, val externalRequest: EntryAnchorRequest?,
    val owners: List<NativeContainerDisclosureOwner>)
