package app.smallthingz.dict

import android.graphics.Bitmap
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Typed shape follows the two genuine Mai TABLE/TD/paragraph.figure owners. These
 * controlled pixels/URLs are marked fixtures, not a claim that a new Writer page ran. */
@RunWith(AndroidJUnit4::class)
class NativeDelegatedTableDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private var decorView: View? = null
    private val images = listOf(
        InlineImage("Delegated-Mai-PNG.png", widthPx = 190L, heightPx = 248L, alt = ""),
        InlineImage("Delegated-Mai-JPEG.jpg", widthPx = 190L, heightPx = 296L, alt = ""),
    )
    private val axes = listOf(460 to 600, 2420 to 3775)
    private val captions = listOf("First retained caption", "Second retained caption")
    private val urls = listOf("https://example.invalid/figure/first", "https://example.invalid/figure/second")
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private val noEdges = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None,
        FigureBorderEdge.None, FigureBorderEdge.None)
    private fun captionPolicy(): FigureLinkPaint {
        val states = listOf("#3366cc", "#3056a9", "#233566", "#6a60b0", "#534fa3", "#353262")
            .mapIndexed { index, rgb -> FigureLinkState(rgb, index % 3 != 0) }
        return FigureLinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], true,
            FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"), px(2f),
                SignedContainerMargin(StyleLengthUnit.Px, -2f)))
    }

    private fun figure(index: Int, label: String): Figure {
        val media = FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr),
            InlineBoxVerticalAlign.Middle, positioning = ContainerPositioning.RelativeAuto,
            after = FigureMediaAfter(px(15f), px(11f), TableFloatSide.Right, px(6f),
                SignedContainerMargin(StyleLengthUnit.Px, -11f),
                FigureGraphicPaint(FigureMediaGraphic.MagnifyClipLtrV1)),
            focusOutline = FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"), px(2f),
                SignedContainerMargin(StyleLengthUnit.Px, 0f)))
        val before = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 15f)), height = px(11f),
            floatSide = TableFloatSide.Right, margins = StyleEdges(px(0f), px(0f), px(0f), px(3f)))
        return Figure(FigureContent.Image(Span("external_link", "", urls[index], image = images[index]),
            FigureSizingPolicy.RequestedFit), FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None,
            edges(0f), edges(3f), edges(6f), 1f, px(24f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Rgb("#ffffff"),
            caption = listOf(Span("link", label, "caption-$index")),
            tableCaptionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), noEdges, noEdges,
                media, captionBefore = before, captionLinkPaint = captionPolicy()))
    }

    private fun table(labels: List<String> = captions) = Table(emptyList(), images.indices.map { index ->
        listOf(Cell(emptyList(), false, 10, 1, blocks = listOf(
            Block("paragraph", 0, emptyList(), figure = figure(index, labels[index]))),
            style = CellStyle(padding = edges(0f))))
    }, style = TableStyle(floatSide = TableFloatSide.Right, clear = FigureClear.Right,
        margins = StyleEdges(px(0f), px(0f), px(16f), px(16f))))

    private class Holder {
        var owner: InlineImageViewOwner? = null
        var origin = Offset.Zero
        var created = 0
        var disposed = 0
        var density = 1f
        var appliedPulse = -1
    }

    @Composable
    private fun Fixture(table: Table, width: Int, bitmap: Bitmap, holder: Holder,
        actions: MutableList<String>, opened: MutableList<String>, opaqueSibling: Boolean = false,
        enabled: Boolean = true, recomposeToken: Int = 0, witness: AdmissionWitness? = null,
        ordinary: Boolean = false, secondDelegated: Boolean = false, interactionOwner: Boolean = true) {
        val settings = AppSettings(allowImages = false, allowAudio = false)
        val media = images.map { Media(it.file, "image", "") }
        MaterialTheme { CompositionLocalProvider(
            LocalNativeContextInteractionOwner provides interactionOwner,
            LocalTablePhaseObserver provides (witness?.observer ?: LocalTablePhaseObserver.current),
            LocalUriHandler provides remember { object : UriHandler {
                override fun openUri(uri: String) { opened += uri }
            } }) {
            val owner = rememberInlineImageViewOwner(images, media, settings, "enwiktionary-20261001")
            remember(owner) {
                images.forEachIndexed { index, image ->
                    owner.states[image.file] = InlineImageAssetState.Ready(DecodedMediaBitmap(bitmap, 46, 60),
                        axes[index].first.toLong(), axes[index].second.toLong(), "image/png", "controlled delegated pixels", "")
                }
                true
            }
            DisposableEffect(owner) { holder.created++; onDispose { holder.disposed++ } }
            val density = LocalDensity.current
            val widthPixels = with(density) { width.dp.roundToPx() }
            SideEffect { holder.owner = owner; holder.density = density.density; holder.appliedPulse = recomposeToken }
            CompositionLocalProvider(LocalInlineImageOwner provides owner) {
                Box(Modifier.testTag("delegated-host").background(Color.White)
                    .onGloballyPositioned {
                        holder.origin = it.positionInWindow()
                        witness?.retainOwners("host-positioned")
                    }) {
                Layout(modifier = Modifier.verticalScroll(rememberScrollState()), content = {
                    if (enabled) {
                        val blocks = (if (ordinary) listOf(Block("paragraph", 0,
                            listOf(Span("link", "Ordinary retained root", "ordinary-root"))))
                            else listOf(Block("paragraph", 0, emptyList(), table = table))) +
                            if (secondDelegated) listOf(Block("paragraph", 0, emptyList(), table = table)) else emptyList()
                        val displayed = blocks +
                            if (opaqueSibling) listOf(Block("paragraph", 0, emptyList(), table = Table(emptyList(),
                                listOf(listOf(Cell(listOf(Span("text", "Opaque sibling")), false, 1, 1)))))) else emptyList()
                        NativeFloatBlockContext(displayed, { actions += it.target }, "delegated-fixture", Modifier,
                            false, "delegated-grid", 0f, false)
                    }
                }) { children, _ ->
                    val child = children.singleOrNull()?.measure(Constraints.fixedWidth(widthPixels))
                    layout(widthPixels + 40, (child?.height ?: 0) + 40) { child?.place(20, 20) }
                }
                }
            }
        } }
    }

    private fun nativeViews(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        fun visit(view: View) {
            if (view is NativeFloatTextView) result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(checkNotNull(decorView))
        return result
    }

    private fun admittedViews(): List<NativeFloatTextView> = nativeViews().filter {
        it.delegatedCellOwner?.permits(it) == true
    }.sortedBy { it.delegatedCellOwner!!.index }

    /** Failure-only reads of the installed owner; never invokes snapshot/validation or
     * rebuilds envelopes. The existing phase observer retains owners if fallback removes
     * their Views before the assertion. It does not change layout or admission. */
    private class AdmissionWitness(private val views: () -> List<NativeFloatTextView>) {
        private val tables = linkedSetOf<NativeDelegatedTableOwner>()
        private val phases = linkedMapOf<String, Int>()
        private val identities = java.util.IdentityHashMap<Any, Int>()
        private val observationErrors = linkedSetOf<String>()
        val observer = TablePhaseObserver { phase, _, _, _ -> retainOwners(phase.name) }

        fun retainOwners(phase: String) {
            phases[phase] = (phases[phase] ?: 0) + 1
            try { views().mapNotNull { it.delegatedCellOwner?.table }.forEach(tables::add) }
            catch (failure: Exception) { observationErrors += "${failure.javaClass.simpleName}:${failure.message}" }
        }

        private fun id(value: Any?): String = if (value == null) "null" else
            "${value.javaClass.simpleName}@${identities.getOrPut(value) { identities.size + 1 }}"

        private fun field(value: Any, name: String): Any? = value.javaClass.getDeclaredField(name)
            .apply { isAccessible = true }.get(value)

        private fun state(value: Any, name: String): Any? =
            (field(value, name + "\$delegate") as androidx.compose.runtime.State<*>).value

        private fun box(root: LayoutCoordinates, child: LayoutCoordinates): NativeFloatBounds? =
            geometry("measuredBox", root, child)

        // Invoke only the installed pure coordinate helpers, with no owner callback.
        private fun geometry(name: String, root: LayoutCoordinates, child: LayoutCoordinates): NativeFloatBounds? =
            Class.forName("app.smallthingz.dict.NativeDelegatedTableOwnerKt")
                .getDeclaredMethod(name, LayoutCoordinates::class.java, LayoutCoordinates::class.java)
                .apply { isAccessible = true }.invoke(null, root, child) as NativeFloatBounds?

        private fun coordinates(value: LayoutCoordinates?, root: LayoutCoordinates?): String = when {
            value == null -> "null"
            !value.isAttached -> "${id(value)} detached"
            root?.isAttached != true -> "${id(value)} size=${value.size} root-not-attached"
            else -> "${id(value)} size=${value.size} box=${box(root, value)}"
        }

        private fun view(value: NativeFloatTextView?): String = if (value == null) "null" else
            "${id(value)} attached=${value.isAttachedToWindow} layoutRequested=${value.isLayoutRequested}" +
                " size=${value.width}x${value.height} measured=${value.measuredWidth}x${value.measuredHeight}" +
                " geometry=${id(value.currentMeasuredGeometry)} owner=${id(value.delegatedCellOwner)}"

        fun failure(): String = buildString {
            retainOwners("assertion-failed")
            appendLine("181 admission witness; original count failed before these read-only diagnostics")
            appendLine("phases=$phases observerErrors=$observationErrors")
            appendLine("nativeViews=${views().size} retainedTables=${tables.size}")
            views().forEach { appendLine("native ${view(it)}") }
            tables.forEach { table ->
                try { describe(table, this) }
                catch (failure: Exception) {
                    appendLine("diagnostic-error ${id(table)} ${failure.javaClass.name}: ${failure.message}")
                }
            }
        }

        private fun describe(table: NativeDelegatedTableOwner, out: StringBuilder) {
            val root = field(table, "rootCoordinates") as LayoutCoordinates?
            val grid = table.gridCoordinates
            val generation = checkNotNull(field(table, "generation"))
            val surroundings = field(table, "measuredSurroundings") as NativeDelegatedSurroundings?
            val accepted = state(table, "accepted")
            val fallback = field(table, "fallbackComposed")
            val acceptedGeneration = field(table, "acceptedGeneration")
            val acceptedGrid = field(table, "acceptedGrid")
            out.appendLine("table=${id(table)} reason=${table.fallbackReason} accepted=$accepted" +
                " fallbackComposed=$fallback awaiting=${field(table, "awaitingNativeComposition")}" +
                " generation=${id(generation)} acceptedGeneration=${id(acceptedGeneration)}" +
                " sameGeneration=${generation === acceptedGeneration} source=${id(field(table, "source"))}" +
                " width=${field(table, "width")}")
            out.appendLine("root=${coordinates(root, root)} grid=${coordinates(grid, root)} acceptedGrid=$acceptedGrid")
            out.appendLine("surroundings=$surroundings")
            out.appendLine("first-refusal-evidence=${table.refusalEvidence}")
            val snapshots = table.cells.map { cell -> describeCell(cell, root, generation, out) }
            val gate = when {
                table.fallbackReason != null -> "stored fallbackReason"
                accepted != true -> "accepted=false"
                fallback == true -> "fallbackComposed"
                acceptedGeneration !== generation -> "accepted generation changed"
                root?.isAttached != true -> "root absent/detached"
                grid?.isAttached != true -> "grid absent/detached"
                box(root, grid) != acceptedGrid -> "grid box changed"
                table.cells.any { !it.currentPlacement(root, generation) } -> "cell currentPlacement=false"
                else -> "cell predicates current; root state placement retained below"
            }
            out.appendLine("current-permits-first-gate=$gate")
            val pending = when {
                root?.isAttached != true -> "root absent/detached"
                grid?.isAttached != true -> "grid absent/detached"
                surroundings == null -> "no measured surroundings"
                table.cells.any { !it.placementReported() } -> "cell placement not reported"
                else -> null
            }
            if (pending != null) out.appendLine("decision pending: $pending")
            else if (snapshots.any { it == null }) out.appendLine("decision snapshot unavailable; exact cell stage above")
            else {
                val tableBounds = box(checkNotNull(root), checkNotNull(grid))
                val rootStamp = field(table, "rootStatePlacement")
                val rootState = if (rootStamp == null) null else {
                    val stateBox = field(rootStamp, "bounds") as NativeFloatBounds
                    @Suppress("UNCHECKED_CAST") val targets = field(table, "rootStateInput") as List<NativeFloatBounds>
                    NativeDelegatedRootState(checkNotNull(field(rootStamp, "view")), stateBox,
                        field(rootStamp, "clip") as NativeFloatBounds,
                        targets.map { it.translated(stateBox.left, stateBox.top) }, checkNotNull(surroundings).rootFallbackInput)
                }
                out.appendLine("rootState=$rootState")
                val decision = if (tableBounds == null) "The delegated table transform is not a translation" else
                    nativeDelegatedPaintDecision(checkNotNull(surroundings).copy(allocation = tableBounds,
                        rootOwner = root, rootState = rootState), snapshots.filterNotNull(),
                        table.cells.map { checkNotNull(it.registeredOwner()) }).toString()
                out.appendLine("read-only cached-envelope decision=$decision")
            }
        }

        @Suppress("UNCHECKED_CAST")
        private fun describeCell(cell: NativeDelegatedCellOwner, root: LayoutCoordinates?, generation: Any,
            out: StringBuilder): NativeDelegatedMeasuredCell? {
            val original = cell.registeredOwner()
            val surface = field(cell, "physical") as NativeSurfaceGeometry?
            val context = cell.contextCoordinates
            val native = cell.viewCoordinates
            val cellCoords = cell.cellCoordinates
            val width = field(cell, "logicalWidth") as Int
            val height = field(cell, "logicalHeight") as Int
            val stamp = field(cell, "placement")
            out.appendLine("cell=${cell.index} owner=${id(cell)} original=${view(original)} surface=${id(surface)}" +
                " logical=${width}x$height reported=${cell.placementReported()} envelopeBuilds=${cell.envelopeBuildCount}")
            out.appendLine("cellCoordinates=${coordinates(cellCoords, root)} context=${coordinates(context, root)}" +
                " native=${coordinates(native, root)}")
            if (stamp != null) {
                out.appendLine("placement rootSame=${field(stamp, "root") === root}" +
                    " generationSame=${field(stamp, "generation") === generation} surfaceSame=${field(stamp, "surface") === surface}" +
                    " cellSame=${field(stamp, "cell") === cellCoords} contextSame=${field(stamp, "context") === context}" +
                    " viewSame=${field(stamp, "view") === native} clip=${field(stamp, "clip")}")
                val oldBoxes = field(stamp, "boxes") as List<Pair<LayoutCoordinates, NativeFloatBounds>>
                oldBoxes.forEachIndexed { index, (coordinate, expected) ->
                    out.appendLine("placementBox[$index] expected=$expected current=${coordinates(coordinate, root)}")
                }
            } else out.appendLine("placement=null")
            fun unavailable(reason: String): NativeDelegatedMeasuredCell? {
                out.appendLine("cell[${cell.index}] snapshot-stage=$reason"); return null
            }
            if (root?.isAttached != true) return unavailable("root absent/detached")
            if (original == null) return unavailable("originalView=null")
            if (surface == null) return unavailable("physical=null")
            if (!original.isAttachedToWindow) return unavailable("original View detached")
            if (original.currentMeasuredGeometry !== surface) return unavailable("current measured geometry differs")
            if (original.width != surface.width || original.height != surface.height)
                return unavailable("View dimensions differ from physical ${surface.width}x${surface.height}")
            if (context?.isAttached != true || native?.isAttached != true || cellCoords?.isAttached != true)
                return unavailable("context/native/cell coordinates absent or detached")
            if (context.size.width != width || context.size.height != height) return unavailable("logical context dimensions differ")
            val contextBox = box(root, context) ?: return unavailable("context transform not translation")
            val x = contextBox.left + surface.surface.left
            val y = contextBox.top + surface.surface.top
            val physicalBox = NativeFloatBounds(x, y, x + surface.width, y + surface.height)
            out.appendLine("physicalBox=$physicalBox nativeBox=${box(root, native)} surface=${surface.surface}")
            if (box(root, native) != physicalBox || original.delegatedCellOwner !== cell)
                return unavailable("physical/native box or View backreference differs")
            val cellBox = box(root, cellCoords) ?: return unavailable("cell transform not translation")
            val grid = cell.table.gridCoordinates ?: return unavailable("grid coordinates absent")
            val gridBox = box(root, grid) ?: return unavailable("grid transform not translation")
            val clipped = grid.localBoundingBoxOf(native, clipBounds = true)
            val innerClip = NativeFloatBounds(clipped.left + gridBox.left, clipped.top + gridBox.top,
                clipped.right + gridBox.left, clipped.bottom + gridBox.top)
            out.appendLine("innerClip=$innerClip")
            val clip = geometry("actualInputClip", root, native) ?: return unavailable("actual input clip unavailable")
            out.appendLine("actualInputClip=$clip")
            val ancestors = mutableListOf(NativeDelegatedInputAncestor(clip, true))
            var cursor: LayoutCoordinates? = native
            var containsRoot = false
            while (cursor != null) {
                val bounds = box(root, cursor) ?: return unavailable("ancestor transform not translation")
                out.appendLine("ancestor=${id(cursor)} bounds=$bounds root=${cursor === root}")
                ancestors += NativeDelegatedInputAncestor(bounds, false)
                if (cursor === root) containsRoot = true
                cursor = cursor.parentLayoutCoordinates
            }
            if (!containsRoot) return unavailable("root not in native ancestry")
            val envelopes = field(cell, "envelopes") ?: return unavailable("envelopes not yet cached; diagnostic does not build them")
            if (field(cell, "envelopeSurface") !== surface) return unavailable("cached envelope surface differs")
            fun rectangles(name: String) = (field(envelopes, name) as List<NativeFloatBounds>).map { it.translated(x, y) }
            val ink = rectangles("ink"); val deferred = rectangles("deferred")
            val input = rectangles("input"); val ordinary = rectangles("ordinary")
            val stateInk = rectangles("state")
            if (deferred.isEmpty()) return unavailable("deferred envelope empty")
            val touchWidth = field(cell, "minimumTouchWidth") as Float
            val touchHeight = field(cell, "minimumTouchHeight") as Float
            out.appendLine("minimumTouch=${touchWidth}x$touchHeight ink=$ink deferred=$deferred input=$input ordinary=$ordinary")
            out.appendLine("cell[${cell.index}] snapshot-stage=complete currentPlacement=${cell.currentPlacement(root, generation)}")
            return NativeDelegatedMeasuredCell(original, generation, cellBox, physicalBox, ancestors,
                ink, deferred, input, touchWidth, touchHeight, stateInk, ordinary, root, innerClip)
        }
    }

    private fun point(view: NativeFloatTextView, rect: android.graphics.RectF, holder: Holder): Offset {
        val location = IntArray(2); view.getLocationInWindow(location)
        return Offset(location[0] + rect.centerX() - holder.origin.x,
            location[1] + rect.centerY() - holder.origin.y)
    }

    private fun tap(view: NativeFloatTextView, kind: FloatInteractionKind, holder: Holder, after: Boolean = false) {
        val at = compose.runOnIdle {
            val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == kind }
            point(view, if (after) node.bounds.last() else node.bounds.first(), holder)
        }
        compose.onNodeWithTag("delegated-host").performTouchInput { click(at) }
        compose.waitForIdle()
    }

    @Test fun actualTableCellsRetainOriginalPaintInputAccessibilityAndSelectionOwnersAcrossReflow() {
        val width = mutableStateOf(260)
        val source = table()
        val holder = Holder()
        val witness = AdmissionWitness(::nativeViews)
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, width.value, bitmap, holder, actions, opened, witness = witness)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also {
                assertEquals(if (it.size == 2) null else witness.failure(), 2, it.size)
            } }
            compose.runOnIdle {
                assertEquals(1, holder.created); assertEquals(0, holder.disposed)
                originals.forEachIndexed { index, view ->
                    val g = checkNotNull(view.currentMeasuredGeometry)
                    assertEquals(captions[index], g.text.toString())
                    assertEquals(2, g.nodes.size)
                    val provider = view.accessibilityNodeProvider
                    g.nodes.forEach { node ->
                        val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                        assertTrue(info.isClickable)
                    }
                    assertEquals(190f * holder.density,
                        g.nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.first().width(), .01f)
                }
                val counts = originals.map { it.delegatedCellOwner!!.envelopeBuildCount }
                val canvasBitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
                try {
                    val canvas = android.graphics.Canvas(canvasBitmap)
                    repeat(50) {
                        originals.forEach { view ->
                            assertTrue(view.delegatedCellOwner!!.permits(view))
                            view.draw(canvas)
                            checkNotNull(view.currentMeasuredGeometry).nodes.forEach { node ->
                                assertNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                            }
                        }
                    }
                    assertEquals("Repeated paint/input eligibility/AX queries cannot rebuild text envelopes",
                        counts, originals.map { it.delegatedCellOwner!!.envelopeBuildCount })
                } finally { canvasBitmap.recycle() }
            }
            tap(originals[0], FloatInteractionKind.IMAGE, holder, after = true)
            assertEquals(listOf(urls[0]), opened)
            tap(originals[0], FloatInteractionKind.LINK, holder)
            assertEquals(listOf("caption-0"), actions)
            // Actual source paint remains present; the original view still draws the media
            // group and owns focus. No root duplicate renderer is substituted.
            val imagePoint = compose.runOnIdle {
                point(originals[0], checkNotNull(originals[0].currentMeasuredGeometry).nodes
                    .single { it.kind == FloatInteractionKind.IMAGE }.bounds.first(), holder)
            }
            val pixels = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()
            assertEquals(Color.Blue, pixels[imagePoint.x.toInt(), imagePoint.y.toInt()])
            val rootOwner = compose.runOnIdle {
                nativeViews().single { it.delegatedCellOwner == null && '\uFFFC' in it.logicalText }.also {
                    it.setSelection(0, it.logicalText.length)
                    assertEquals("\uFFFC", it.selectedTextForCopy())
                }
            }
            val rootSelected = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()
            assertNotEquals("Root selection must remain above the relative media phase", Color.Blue,
                rootSelected[imagePoint.x.toInt(), imagePoint.y.toInt()])
            compose.runOnIdle { rootOwner.setSelection(0, 0) }
            compose.runOnIdle {
                val view = originals[0]
                assertTrue(view.requestFocus())
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                assertTrue(view.hasFocus())
            }
            val focused = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()
            var red = 0
            for (y in 0 until focused.height) for (x in 0 until focused.width) {
                val p = focused[x, y]; if (p.red > .9f && p.green < .1f && p.blue < .1f) red++
            }
            assertTrue("The original native keyboard owner must paint its outline", red > 0)
            compose.runOnIdle {
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf("caption-0"), actions)
                width.value = 230
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertSame(originals[0], admittedViews()[0])
                assertTrue(originals[0].hasFocus())
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf("caption-0", "caption-0"), actions)
                assertEquals(listOf(urls[0]), opened)
            }
            compose.runOnIdle {
                val view = originals[0]
                val selection = Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, view.logicalText.length)
                }
                assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
                assertEquals(captions[0], view.selectedTextForCopy())
                assertTrue(view.revealLogicalOffset(0))
                width.value = 260
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val resized = admittedViews(); assertEquals(2, resized.size)
                resized.indices.forEach { assertSame(originals[it], resized[it]) }
                assertEquals(captions[0], resized[0].selectedTextForCopy())
                assertEquals(1, holder.created); assertEquals(0, holder.disposed)
                assertTrue(resized[1].revealLogicalOffset(0))
            }
            compose.waitForIdle()
            tap(originals[1], FloatInteractionKind.LINK, holder)
            assertEquals(listOf("caption-0", "caption-0", "caption-1"), actions)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun realHorizontalAncestorClipsAndScrollsWithoutReassigningTheNativeOwner() {
        val width = mutableStateOf(260)
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, width.value, bitmap, holder, actions, opened)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            compose.runOnIdle { width.value = 150 }
            compose.waitForIdle()
            val before = compose.runOnIdle {
                assertEquals(originals, admittedViews())
                IntArray(2).also(originals[0]::getLocationInWindow)
            }
            // Swipe through the visible first image, on the actual Compose scroll chain.
            compose.onNodeWithTag("delegated-host").performTouchInput {
                swipe(Offset(20f + 145f * holder.density, 20f + 100f * holder.density),
                    Offset(20f + 35f * holder.density, 20f + 100f * holder.density))
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val after = IntArray(2).also(originals[0]::getLocationInWindow)
                assertTrue("The real table scroll ancestor must consume the horizontal drag", after[0] < before[0])
                assertEquals(originals, admittedViews())
                assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
                assertTrue(originals[0].revealLogicalOffset(0))
            }
            compose.waitForIdle()
            compose.runOnIdle { width.value = 260 }
            compose.waitForIdle()
            tap(originals[0], FloatInteractionKind.IMAGE, holder, after = true)
            assertEquals(listOf(urls[0]), opened)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun opaqueSiblingAndDetachedGenerationKeepFallbackBodyAndNeverReviveOldVirtualActions() {
        val opaque = mutableStateOf(false); val enabled = mutableStateOf(true)
        val pulse = mutableStateOf(0)
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, 260, bitmap, holder, actions, opened, opaque.value, enabled.value, pulse.value)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            val oldNodes = compose.runOnIdle { originals.map { checkNotNull(it.currentMeasuredGeometry).nodes.toList() } }
            compose.runOnIdle {
                originals[0].requestFocus()
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
                opaque.value = true
            }
            compose.waitForIdle()
            assertTrue(compose.onAllNodesWithText("Unable to display this layout.", substring = true)
                .fetchSemanticsNodes().isNotEmpty())
            captions.forEach { compose.onNodeWithText(it).assertExists() }
            // Ordinary recomposition must not retry a permanently refused geometry.
            repeat(5) { next ->
                compose.runOnIdle { pulse.value = next + 1 }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertEquals(next + 1, holder.appliedPulse)
                    assertTrue(admittedViews().isEmpty())
                    assertEquals(1, holder.created); assertEquals(0, holder.disposed)
                }
                captions.forEach { compose.onNodeWithText(it).assertExists() }
            }
            compose.runOnIdle {
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                assertTrue(admittedViews().isEmpty())
                originals.forEachIndexed { index, view -> oldNodes[index].forEach { node ->
                    assertNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                    assertFalse(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                } }
                assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
                opaque.value = false
            }
            compose.waitForIdle()
            val restored = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            tap(restored[0], FloatInteractionKind.LINK, holder)
            assertEquals(listOf("caption-0"), actions)
            compose.runOnIdle { enabled.value = false }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue(admittedViews().isEmpty())
                restored.forEach { view ->
                    assertFalse(view.isAttachedToWindow)
                    assertFalse(view.revealLogicalOffset(0))
                }
                assertEquals(1, holder.created); assertEquals(0, holder.disposed)
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun readyLoadingReadyKeepsOneResourceOwnerAndCancelsTheHeldNativeSequence() {
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, 260, bitmap, holder, actions, opened)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            val resource = checkNotNull(holder.owner)
            val ready = compose.runOnIdle { checkNotNull(resource.states[images[0].file]) }
            val downAt = compose.runOnIdle {
                point(originals[0], checkNotNull(originals[0].currentMeasuredGeometry).nodes
                    .single { it.kind == FloatInteractionKind.IMAGE }.bounds.first(), holder)
            }
            compose.onNodeWithTag("delegated-host").performTouchInput { down(downAt) }
            compose.runOnIdle { resource.states[images[0].file] = InlineImageAssetState.Loading }
            compose.waitForIdle()
            // GestureDetector uses the real Android clock, independently of Compose's clock.
            Thread.sleep(android.view.ViewConfiguration.getLongPressTimeout().toLong() + 120L)
            compose.runOnIdle {
                assertSame(resource, holder.owner)
                assertEquals(1, holder.created); assertEquals(0, holder.disposed)
                assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
                resource.states[images[0].file] = ready
            }
            compose.waitForIdle()
            compose.onNodeWithTag("delegated-host").performTouchInput { up() }
            compose.waitForIdle()
            val current = compose.runOnIdle {
                assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
                assertSame(resource, holder.owner)
                admittedViews().also { views ->
                    assertEquals(2, views.size)
                    views.forEachIndexed { index, view -> assertEquals(captions[index], view.logicalText.toString()) }
                }
            }
            tap(current[0], FloatInteractionKind.IMAGE, holder, after = true)
            assertEquals(listOf(urls[0]), opened)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun sameRootViewRestoresOrdinaryStatePaintAcrossDelegatedRemovalAndReturn() {
        val ordinary = mutableStateOf(false)
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, 260, bitmap, holder, actions, opened, ordinary = ordinary.value)
            } }
            compose.waitForIdle()
            val root = compose.runOnIdle {
                assertEquals(2, admittedViews().size)
                nativeViews().single { it.delegatedStateOwner != null }
            }
            val former = compose.runOnIdle { checkNotNull(root.delegatedStateOwner).also { ordinary.value = true } }
            compose.waitForIdle()
            compose.runOnIdle {
                val current = nativeViews().single { it.logicalText.toString() == "Ordinary retained root" }
                assertSame("The native-context slot must exercise the actual retained View transition", root, current)
                assertNull(current.delegatedStateOwner)
                assertFalse(former.permitsOriginalOwners())
                val local = Bitmap.createBitmap(current.width, current.height, Bitmap.Config.ARGB_8888)
                try {
                    current.setSelection(0, 0)
                    current.draw(android.graphics.Canvas(local))
                    val before = IntArray(local.width * local.height)
                    local.getPixels(before, 0, local.width, 0, 0, local.width, local.height)
                    current.setSelection(0, current.logicalText.length)
                    assertEquals("Ordinary retained root", current.selectedTextForCopy())
                    local.eraseColor(android.graphics.Color.TRANSPARENT)
                    current.draw(android.graphics.Canvas(local))
                    val values = IntArray(local.width * local.height)
                    local.getPixels(values, 0, local.width, 0, 0, local.width, local.height)
                    assertTrue("Ordinary local selection painting must resume after owner removal",
                        values.indices.any { values[it] != before[it] })
                } finally { local.recycle() }
                val node = checkNotNull(current.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.LINK }
                assertTrue(checkNotNull(current.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id)).isClickable)
                assertTrue(current.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf("ordinary-root"), actions)
                ordinary.value = false
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(2, admittedViews().size)
                assertSame(root, nativeViews().single { it.delegatedStateOwner != null })
                assertNotSame(former, root.delegatedStateOwner)
                assertTrue(checkNotNull(root.delegatedStateOwner).permitsOriginalOwners())
                former.clearRootState(root)
                assertNotNull("Late disposal of an old owner must not clear the new owner", root.delegatedStateOwner)
                val owner = checkNotNull(root.delegatedStateOwner)
                assertTrue(owner.permitsOriginalOwners())
                val coordinatesField = NativeDelegatedTableOwner::class.java.getDeclaredField("rootStateCoordinates")
                    .apply { isAccessible = true }
                val placementField = NativeDelegatedTableOwner::class.java.getDeclaredField("rootStatePlacement")
                    .apply { isAccessible = true }
                val coordinates = coordinatesField.get(owner) as LayoutCoordinates
                val surface = root.currentMeasuredGeometry as NativeSurfaceGeometry
                val replacement = NativeFloatTextView(root.context)
                try {
                    owner.measuredRootState(replacement, surface)
                    assertNull(root.delegatedStateOwner)
                    assertSame(owner, replacement.delegatedStateOwner)
                    assertNull("A new View cannot inherit the previous View's coordinates", coordinatesField.get(owner))
                    assertNull(placementField.get(owner))
                    assertFalse(owner.permitsOriginalOwners())
                } finally {
                    owner.measuredRootState(root, surface)
                    owner.positionedRootState(root, coordinates)
                }
                assertNull(replacement.delegatedStateOwner)
                assertTrue(owner.permitsOriginalOwners())
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun finalizedUnsupportedRootScopesConvergeToVisibleBodyInsteadOfPendingOwners() {
        val second = mutableStateOf(true); val interaction = mutableStateOf(true); val pulse = mutableStateOf(0)
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, 260, bitmap, holder, actions, opened, recomposeToken = pulse.value,
                    secondDelegated = second.value, interactionOwner = interaction.value)
            } }
            compose.waitForIdle()
            repeat(3) { iteration ->
                compose.runOnIdle {
                    assertTrue(admittedViews().isEmpty())
                    pulse.value = iteration + 1
                }
                compose.waitForIdle()
                assertTrue(compose.onAllNodesWithText("one complete original Entry owner", substring = true)
                    .fetchSemanticsNodes().isNotEmpty())
                captions.forEach { label -> assertTrue("Both table bodies must remain available",
                    compose.onAllNodesWithText(label, substring = true).fetchSemanticsNodes().size >= 2) }
            }
            compose.runOnIdle { second.value = false; interaction.value = false }
            compose.waitForIdle()
            compose.runOnIdle { assertTrue(admittedViews().isEmpty()) }
            assertTrue(compose.onAllNodesWithText("one complete original Entry owner", substring = true)
                .fetchSemanticsNodes().isNotEmpty())
            captions.forEach { label -> assertTrue(compose.onAllNodesWithText(label, substring = true)
                .fetchSemanticsNodes().isNotEmpty()) }
            compose.runOnIdle { interaction.value = true }
            compose.waitForIdle()
            compose.runOnIdle { assertEquals("A real return of the original root owner may retry", 2, admittedViews().size) }
            assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun originalHandleTargetsRespectTheOuterClipAndKeepParentHandlePriority() {
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        fun dragged(view: NativeFloatTextView) = NativeFloatTextView::class.java.getDeclaredField("draggedHandle")
            .apply { isAccessible = true }.getInt(view)
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, 260, bitmap, holder, actions, opened)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            val root = compose.runOnIdle {
                nativeViews().single { it.delegatedCellOwner == null && '\uFFFC' in it.logicalText }
            }
            fun childHandlePoint(outside: Boolean) = compose.runOnIdle {
                val view = originals[0]
                view.setSelection(0, view.logicalText.length)
                val g = checkNotNull(view.currentMeasuredGeometry)
                val xy = IntArray(2).also(view::getLocationInWindow)
                val center = nativeSelectionHandleCenter(g, 0, holder.density)
                val cellLeft = checkNotNull(view.delegatedCellOwner!!.cellCoordinates).positionInWindow().x
                val windowX = cellLeft + if (outside) -1f else 1f
                val x = windowX - xy[0]
                assertTrue("The original physical owner must really extend outside its logical cell", x >= 0f)
                assertTrue(kotlin.math.abs(x - center.first) < 24f * holder.density)
                val native = checkNotNull(view.delegatedCellOwner!!.viewCoordinates)
                var outer = native
                while (outer.parentLayoutCoordinates != null) outer = checkNotNull(outer.parentLayoutCoordinates)
                val clip = outer.localBoundingBoxOf(native, clipBounds = true)
                val origin = outer.positionInWindow()
                if (outside) assertTrue(windowX < origin.x + clip.left)
                else assertTrue(windowX >= origin.x + clip.left && windowX < origin.x + clip.right)
                Offset(windowX - holder.origin.x, xy[1] + center.second - holder.origin.y)
            }
            val outside = childHandlePoint(true)
            compose.onNodeWithTag("delegated-host").performTouchInput { down(outside) }
            compose.runOnIdle { assertEquals("The outer viewport must exclude the off-clip handle target", 0, dragged(originals[0])) }
            compose.onNodeWithTag("delegated-host").performTouchInput { up() }
            compose.waitForIdle()
            val childPoint = childHandlePoint(false)
            compose.onNodeWithTag("delegated-host").performTouchInput { down(childPoint) }
            compose.runOnIdle {
                assertEquals("The real cell View receives the visible handle DOWN through shared interop", 1, dragged(originals[0]))
                assertEquals(0, dragged(root))
            }
            compose.onNodeWithTag("delegated-host").performTouchInput {
                moveTo(childPoint + Offset(35f * holder.density, 0f)); up()
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue(originals[0].selectionStart > 0)
                assertTrue(checkNotNull(originals[0].selectedTextForCopy()).length < captions[0].length)
                root.setSelection(0, root.logicalText.length)
                assertTrue(root.revealLogicalOffset(root.logicalText.length))
            }
            compose.waitForIdle()
            val parentPoint = compose.runOnIdle {
                val last = originals[1]
                val xy = IntArray(2).also(last::getLocationInWindow)
                val g = checkNotNull(last.currentMeasuredGeometry)
                val cell = checkNotNull(last.delegatedCellOwner!!.cellCoordinates)
                val cellAt = cell.positionInWindow()
                val window = Offset(cellAt.x + 1f, cellAt.y + cell.size.height - 1f)
                val rootAt = IntArray(2).also(root::getLocationInWindow)
                val center = nativeSelectionHandleCenter(checkNotNull(root.currentMeasuredGeometry), 0, holder.density)
                val dx = window.x - rootAt[0] - center.first
                val dy = window.y - rootAt[1] - center.second
                assertTrue("The target must be in the actual parent 24-radius handle", dx * dx + dy * dy <
                    24f * holder.density * 24f * holder.density)
                val localX = window.x - xy[0]; val localY = window.y - xy[1]
                assertTrue(localX >= 0f && localY >= 0f && localX < last.width && localY < last.height)
                assertTrue(g.containsInput(localX, localY))
                assertEquals(captions[1], g.text.toString())
                window - holder.origin
            }
            compose.onNodeWithTag("delegated-host").performTouchInput { down(parentPoint) }
            compose.runOnIdle {
                assertEquals("The already upper parent View keeps its visible handle priority", 1, dragged(root))
                assertEquals(0, dragged(originals[1]))
            }
            compose.onNodeWithTag("delegated-host").performTouchInput { up() }
            assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun originalStatePaintsOnceAfterAllMediaAndInvalidatesWithoutRecomposition() {
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, 260, bitmap, holder, actions, opened)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            val root = compose.runOnIdle {
                nativeViews().single { it.delegatedCellOwner == null && '\uFFFC' in it.logicalText }
            }
            val before = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()
            val rects = compose.runOnIdle {
                val view = originals[0]
                val xy = IntArray(2).also(view::getLocationInWindow)
                checkNotNull(view.currentMeasuredGeometry).rectsForRange(0, view.logicalText.length).map {
                    android.graphics.RectF(it).apply { offset(xy[0] - holder.origin.x, xy[1] - holder.origin.y) }
                }
            }
            val probe = (0 until before.height).asSequence().flatMap { y -> (0 until before.width).asSequence().map { x -> x to y } }
                .first { (x, y) -> before[x, y] == Color.White && rects.any {
                    x > it.left + 3 && x < it.right - 3 && y > it.top + 3 && y < it.bottom - 3
                } }
            val highlight = compose.runOnIdle {
                originals[0].setSelection(0, originals[0].logicalText.length)
                (NativeFloatTextView::class.java.getDeclaredField("highlight").apply { isAccessible = true }
                    .get(originals[0]) as android.graphics.Paint).color
            }
            val selected = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()[probe.first, probe.second]
            val alpha = android.graphics.Color.alpha(highlight) / 255f
            fun blended(channel: Int) = 1f - alpha + alpha * channel / 255f
            assertEquals(blended(android.graphics.Color.red(highlight)), selected.red, .012f)
            assertEquals(blended(android.graphics.Color.green(highlight)), selected.green, .012f)
            assertEquals(blended(android.graphics.Color.blue(highlight)), selected.blue, .012f)
            compose.runOnIdle { originals[0].setSelection(0, 0) }
            val cleared = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()[probe.first, probe.second]
            assertEquals("Clearing only original View state must invalidate the parent phase", Color.White, cleared)
            compose.runOnIdle {
                originals[0].setSelection(0, originals[0].logicalText.length)
                assertTrue(originals[1].requestFocus())
                originals[1].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                originals[1].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                assertFalse(originals[0].hasFocus())
                assertEquals(captions[0], originals[0].selectedTextForCopy())
                // Every original View remains registered; its local draw must not duplicate
                // the state which the containing root now paints once after all media.
                (originals + root).forEach { view ->
                    val local = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
                    try {
                        view.draw(android.graphics.Canvas(local))
                        val values = IntArray(local.width * local.height)
                        local.getPixels(values, 0, local.width, 0, 0, local.width, local.height)
                        assertTrue("Original interaction surface must not paint a second state copy", values.all { it == 0 })
                    } finally { local.recycle() }
                }
            }
            compose.waitForIdle()
            val focus = compose.runOnIdle {
                val view = originals[1]
                val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                val ink = checkNotNull(nativeFocusInk(listOf(node)))
                val xy = IntArray(2).also(view::getLocationInWindow)
                val cellTop = checkNotNull(view.delegatedCellOwner!!.cellCoordinates).positionInWindow().y - holder.origin.y
                Triple(ink.translated(xy[0] - holder.origin.x, xy[1] - holder.origin.y), cellTop, view)
            }
            val focused = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()
            assertTrue("The authored outline extends above the un-clipped real cell", focus.first.top < focus.second)
            val top = kotlin.math.floor(focus.first.top).toInt().coerceAtLeast(0)
            val bottom = kotlin.math.ceil(focus.second).toInt().coerceAtMost(focused.height)
            assertTrue("The cross-cell boundary must actually be visible", top < bottom)
            var red = 0
            for (y in top until bottom) for (x in kotlin.math.floor(focus.first.left).toInt().coerceAtLeast(0)
                until kotlin.math.ceil(focus.first.right).toInt().coerceAtMost(focused.width)) {
                val pixel = focused[x, y]
                if (pixel.red > .9f && pixel.green < .1f && pixel.blue < .1f) red++
            }
            assertTrue("A different cell's retained selection cannot cover the final focus phase", red > 0)
            assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }
}
