package app.smallthingz.dict

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

/** One measured occurrence leases an Entry item; lazy disposal is not source removal. */
internal interface NativeDocumentOverflowPublisher {
    fun attach(owner: Any)
    fun publish(owner: Any, viewportWidth: Int, bounds: NativeFloatBounds?)
    fun remove(owner: Any)
    fun detach(owner: Any)
}

internal val LocalNativeDocumentOverflowPublisher =
    staticCompositionLocalOf<NativeDocumentOverflowPublisher?> { null }

/** Asset state and pre-decode geometry can change while the source owner stays the same. */
internal fun nativeDocumentImageRevision(states: Map<String, InlineImageAssetState>,
    pixels: List<InlineImagePixels?>): Pair<Map<String, InlineImageAssetState>, List<InlineImagePixels?>> =
    states.toMap() to pixels.toList()

/** New ordinary absolute source needs an owner before its first measured range is known. */
internal fun nativeDocumentScrollNeeded(entry: Entry): Boolean {
    var needed = false
    val visitor = PresentationSpanVisitor { _, _ -> }.apply {
        onContainer = { if (it.style.absolutePosition != null) needed = true }
    }
    entry.sections.forEach { visitor.blocks(it.blocks) }
    return needed
}

@Composable
internal fun NativeDocumentOverflowItem(registry: NativeDocumentOverflowRegistry?, key: Any,
    content: @Composable () -> Unit) {
    if (registry == null) content()
    else CompositionLocalProvider(LocalNativeDocumentOverflowPublisher provides registry.publisher(key), content = content)
}

internal fun nativeDocumentRtl(direction: BidiResolvedDirection?, outerRtl: Boolean): Boolean =
    when (direction) {
        BidiResolvedDirection.Ltr -> false
        BidiResolvedDirection.Rtl -> true
        null -> outerRtl
    }

/** The extra physical padding grows the scroll surface, never the item containing block. */
internal data class NativeDocumentAllocation(val width: Int, val leftPadding: Int, val rightPadding: Int)

internal fun nativeDocumentAllocation(viewportWidth: Int, sidePadding: Int, range: Int,
    rtl: Boolean): NativeDocumentAllocation {
    if (viewportWidth < 0 || sidePadding < 0 || range < 0 ||
        viewportWidth.toLong() + range > TablePixelLimit)
        throw UnsupportedFloatLayout("Document horizontal extent exceeds the native measurement range")
    return NativeDocumentAllocation(viewportWidth + range,
        sidePadding + if (rtl) range else 0, sidePadding + if (rtl) 0 else range)
}

/** Known measured items survive lazy disposal. Unknown items do not invent a range. */
internal class NativeDocumentOverflowRegistry(
    private val viewportWidth: Int,
    private val contentWidth: Int,
    private val viewportHeight: Int,
    private val sidePadding: Int,
    private val rtl: Boolean,
    keys: Set<Any>
) {
    private data class Item(var owner: Any?, var range: Int)
    private val items = linkedMapOf<Any, Item>()
    private val publishers = linkedMapOf<Any, NativeDocumentOverflowPublisher>()
    private var allowed = keys
    private var active = true
    private var revision by mutableIntStateOf(0)

    val range: Int get() {
        revision
        return items.values.maxOfOrNull { it.range } ?: 0
    }

    fun activate() { active = true }
    fun deactivate() {
        active = false
        items.values.forEach { it.owner = null }
    }

    fun retain(keys: Set<Any>) {
        allowed = keys
        val removed = items.keys.removeAll { it !in keys }
        publishers.keys.removeAll { it !in keys }
        if (removed) revision++
    }

    fun publisher(key: Any): NativeDocumentOverflowPublisher = publishers.getOrPut(key) {
        object : NativeDocumentOverflowPublisher {
            override fun attach(owner: Any) {
                if (!active || key !in allowed) return
                items[key] = Item(owner, items[key]?.range ?: 0)
            }

            override fun publish(owner: Any, viewportWidth: Int, bounds: NativeFloatBounds?) {
                if (!active || key !in allowed || items[key]?.owner !== owner || viewportWidth != contentWidth) return
                val next = nativeDocumentHorizontalExtent(contentWidth, bounds, rtl).range
                val allocation = nativeDocumentAllocation(this@NativeDocumentOverflowRegistry.viewportWidth,
                    sidePadding, next, rtl)
                try { Constraints.fixed(allocation.width, viewportHeight) }
                catch (_: IllegalArgumentException) {
                    throw UnsupportedFloatLayout("Document horizontal extent exceeds Compose measurement range")
                }
                val before = items[key]
                items[key] = Item(owner, next)
                if (before?.range != next) revision++
            }

            override fun remove(owner: Any) {
                if (active && items[key]?.owner === owner) {
                    val item = checkNotNull(items[key])
                    if (item.range != 0) { item.range = 0; revision++ }
                }
            }

            override fun detach(owner: Any) {
                items[key]?.takeIf { it.owner === owner }?.owner = null
            }
        }
    }
}

/** One reader visit owns this state, including already measured offscreen item extents. */
internal class NativeDocumentScrollState {
    val scroll = ScrollState(0)
    private var configuration: List<Any?>? = null
    private var registry: NativeDocumentOverflowRegistry? = null

    fun registry(configuration: List<Any?>, viewportWidth: Int, contentWidth: Int,
        viewportHeight: Int, sidePadding: Int, rtl: Boolean, keys: Set<Any>): NativeDocumentOverflowRegistry {
        if (this.configuration != configuration) {
            registry?.deactivate()
            this.configuration = configuration
            registry = NativeDocumentOverflowRegistry(viewportWidth, contentWidth, viewportHeight, sidePadding, rtl, keys)
        }
        return checkNotNull(registry).also { it.activate() }
    }
}

/** The list surface is wider, but its extra padding cancels that width for every item. */
@Composable
internal fun NativeDocumentScroll(
    state: NativeDocumentScrollState,
    enabled: Boolean,
    resourceKey: List<Any?>,
    sourceKeys: Set<Any>,
    direction: BidiResolvedDirection?,
    imageOwner: InlineImageViewOwner? = null,
    images: List<InlineImage> = emptyList(),
    modifier: Modifier = Modifier,
    content: @Composable (Modifier, PaddingValues, NativeDocumentOverflowRegistry?) -> Unit
) {
    if (!enabled) {
        content(modifier, PaddingValues(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 56.dp), null)
        return
    }
    val density = LocalDensity.current
    val imageRevision = imageOwner?.let { owner -> nativeDocumentImageRevision(owner.states,
        images.map { owner.knownPixels(it, density.density) }) }
    val outerDirection = LocalLayoutDirection.current
    val rtl = nativeDocumentRtl(direction, outerDirection == LayoutDirection.Rtl)
    val view = LocalView.current
    val parentClip = LocalNativeScrollClip.current
    val clip = remember(parentClip) { NativeScrollClip(parentClip) }
    BoxWithConstraints(modifier.clipToBounds()
        .onGloballyPositioned { clip.update(it.boundsInWindow(), view) }, propagateMinConstraints = true) {
        require(constraints.hasBoundedWidth && constraints.hasBoundedHeight)
        val viewportWidth = constraints.maxWidth
        val viewportHeight = constraints.maxHeight
        val sidePadding = with(density) { 12.dp.roundToPx() }
        val contentWidth = (viewportWidth - 2 * sidePadding).coerceAtLeast(0)
        val registry = state.registry(resourceKey + listOf(imageRevision, viewportWidth, viewportHeight, sidePadding,
            density.density, density.fontScale, outerDirection, rtl), viewportWidth, contentWidth, viewportHeight,
            sidePadding, rtl, sourceKeys)
        DisposableEffect(registry) {
            registry.activate()
            onDispose { registry.deactivate() }
        }
        registry.retain(sourceKeys)
        val allocation = nativeDocumentAllocation(viewportWidth, sidePadding, registry.range, rtl)
        val padding = with(density) { PaddingValues.Absolute(left = allocation.leftPadding.toDp(),
            top = 4.dp, right = allocation.rightPadding.toDp(), bottom = 56.dp) }
        CompositionLocalProvider(LocalNativeScrollClip provides clip) {
            Layout(modifier = Modifier.fillMaxSize().testTag("entry-document-scroll").horizontalScroll(state.scroll,
                reverseScrolling = rtl != (outerDirection == LayoutDirection.Rtl)),
                content = { content(Modifier.fillMaxSize(), padding, registry) }) { measurables, incoming ->
                val child = measurables.single().measure(incoming.copy(
                    minWidth = allocation.width, maxWidth = allocation.width))
                layout(allocation.width, child.height) { child.place(0, 0) }
            }
        }
    }
}
