package app.smallthingz.dict

import android.graphics.Paint
import android.os.Bundle
import android.text.SpannableString
import android.text.TextPaint
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.round

/** API02 integration controls. Private source only; not compiled, installed, or executed. */
class TableFloatViewportDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun zeroEdges() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private fun margins(top: Float = 0f, right: Float = 6f, bottom: Float = 0f, left: Float = 4f) =
        StyleEdges(px(top), px(right), px(bottom), px(left))
    private fun policy(containing: TableContainingDirection = TableContainingDirection.Ltr,
        grid: TableContainingDirection = TableContainingDirection.Rtl, language: String = "ru") =
        TableFloatViewport(639, containing, grid, language)
    private fun cell(label: String, minimum: Float = 30f, spans: List<Span> = listOf(Span("link", label, "Mai-$label"))) =
        Cell(spans, false, 1, 1, background = "#e40000", style = CellStyle(border = StyleBorder.None,
            padding = zeroEdges(), minWidth = px(minimum), verticalAlign = CellVerticalAlign.Top))
    private fun table(value: TableFloatViewport = policy(), minimum: Float = 30f,
        edges: StyleEdges = margins(), rows: List<List<Cell>> = listOf(listOf(cell("A", minimum), cell("B", minimum)))) =
        Table(emptyList(), rows, style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Collapse,
            margins = edges, floatSide = TableFloatSide.Right), floatViewport = value)
    private fun block(value: Table) = Block("table", 0, emptyList(), table = value)

    @Composable
    private fun Scene(blocks: List<Block>, viewport: Double, width: Int = 100, fontScale: Float = 1f,
        onLink: (EntryLink) -> Unit = {}) {
        CompositionLocalProvider(LocalDensity provides Density(1f, fontScale),
            LocalLayoutDirection provides LayoutDirection.Ltr, LocalTableDocumentViewportCssWidth provides viewport) {
            DictTheme("light") {
                MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp,
                    fontFamily = FontFamily.Serif, letterSpacing = 0.sp, localeList = LocaleList("tr")))) {
                    // The surrounding surface leaves room to observe signed overflow on either side.
                    Box(Modifier.width(320.dp)) {
                        Box(Modifier.padding(start = 60.dp)) {
                            Box(Modifier.width(width.dp).testTag("mai-containing-block")) {
                                NativeFloatBlockContext(blocks, onLink, "mai-device", Modifier,
                                    inCell = false, gridPath = "root", gapDp = 0f, trailingGap = false)
                            }
                        }
                    }
                }
            }
        }
    }

    private var diagnosticSequence = 0
    private fun diagnostic(method: String, kind: String, phase: String, geometry: JSONObject? = null) {
        try {
            if (diagnosticSequence >= 32) return
            val record = JSONObject().put("version", 1).put("method", "app.smallthingz.dict.TableFloatViewportDeviceTest#$method")
                .put("sequence", ++diagnosticSequence).put("kind", kind).put("phase", phase)
            geometry?.let { record.put("geometry", it) }
            val stream = "OWNED_METHOD_DIAGNOSTIC " + record.toString() + "\n"
            if (stream.toByteArray(Charsets.UTF_8).size <= 32768) {
                InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("stream", stream) })
            }
        } catch (_: Throwable) { /* Observation transport must preserve the original test outcome. */ }
    }

    private fun emitIdleDiagnostic(record: JSONObject): Boolean = try {
        val stream = "OWNED_IDLE_STACK_DIAGNOSTIC " + record.toString() + "\n"
        if (stream.toByteArray(Charsets.UTF_8).size > 32768) false else {
            InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("stream", stream) })
            true
        }
    } catch (_: Throwable) { false }

    /** Passive counters belong only to the existing activity root; they schedule no work. */
    private class InitialIdleTraversalObservation {
        private val layouts = java.util.concurrent.atomic.AtomicLong(0)
        private val draws = java.util.concurrent.atomic.AtomicLong(0)
        private val attached = java.util.concurrent.atomic.AtomicBoolean(false)
        private val registered = java.util.concurrent.atomic.AtomicBoolean(false)
        private val errors = java.util.concurrent.atomic.AtomicInteger(0)
        @Volatile private var rootIdentity: Int? = null
        private var root: android.view.View? = null
        private var observer: android.view.ViewTreeObserver? = null
        private var removed = false
        private val layoutListener = android.view.ViewTreeObserver.OnGlobalLayoutListener { layouts.incrementAndGet() }
        private val drawListener = android.view.ViewTreeObserver.OnDrawListener { draws.incrementAndGet() }
        private val attachmentListener = object : android.view.View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: android.view.View) { attached.set(true) }
            override fun onViewDetachedFromWindow(view: android.view.View) { attached.set(false) }
        }
        fun attach(activity: android.app.Activity) {
            try {
                val owned = activity.window.decorView
                root = owned
                rootIdentity = System.identityHashCode(owned)
                val current = owned.viewTreeObserver
                observer = current
                attached.set(owned.isAttachedToWindow)
                if (!attached.get() || !current.isAlive) { errors.incrementAndGet(); return }
                owned.addOnAttachStateChangeListener(attachmentListener)
                current.addOnGlobalLayoutListener(layoutListener)
                current.addOnDrawListener(drawListener)
                registered.set(true)
            } catch (_: Throwable) { errors.incrementAndGet() }
        }
        fun snapshot() = JSONObject().put("root_identity", rootIdentity ?: JSONObject.NULL)
            .put("attached", attached.get()).put("listeners_registered", registered.get())
            .put("global_layout_count", layouts.get()).put("draw_count", draws.get())
            .put("observation_errors", errors.get())
        fun remove() {
            var complete = root != null && observer != null
            try {
                val owned = root
                // A detached tree can merge listeners into its replacement observer. Remove
                // from both captured and current trees when alive, including partial setup.
                val trees = listOfNotNull(observer, owned?.viewTreeObserver).distinct()
                trees.forEach { tree ->
                    if (tree.isAlive) {
                        try { tree.removeOnGlobalLayoutListener(layoutListener) }
                        catch (_: Throwable) { complete = false; errors.incrementAndGet() }
                        try { tree.removeOnDrawListener(drawListener) }
                        catch (_: Throwable) { complete = false; errors.incrementAndGet() }
                    }
                }
                try { owned?.removeOnAttachStateChangeListener(attachmentListener) }
                catch (_: Throwable) { complete = false; errors.incrementAndGet() }
            } catch (_: Throwable) { complete = false; errors.incrementAndGet() }
            finally {
                removed = complete
                root = null
                observer = null
            }
        }
        fun cleanupRecord(method: String) = JSONObject().put("version", 1)
            .put("method", "app.smallthingz.dict.TableFloatViewportDeviceTest#$method")
            .put("kind", "traversal_cleanup").put("traversal", snapshot())
            .put("listeners_removed", removed)
    }

    /** Samples only this test and its main thread; observation cannot replace the original wait outcome. */
    private fun withInitialIdleWatchdog(method: String?, traversal: InitialIdleTraversalObservation?, wait: () -> Unit) {
        if (method == null) { wait(); return }
        val testThread = Thread.currentThread()
        val mainThread = android.os.Looper.getMainLooper().thread
        val cancelled = java.util.concurrent.CountDownLatch(1)
        val emitted = java.util.concurrent.atomic.AtomicInteger(0)
        val observationErrors = java.util.concurrent.atomic.AtomicInteger(0)
        val startedAt = System.nanoTime()
        fun elapsedMillis(): Long = java.util.concurrent.TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)
        fun emit(record: JSONObject): Boolean = emitIdleDiagnostic(record)
        fun envelope(kind: String) = JSONObject().put("version", 1)
            .put("method", "app.smallthingz.dict.TableFloatViewportDeviceTest#$method").put("kind", kind)
        fun snapshot(role: String, thread: Thread): JSONObject {
            val state = thread.state.name
            val stack = thread.stackTrace
            val frames = JSONArray()
            val indices = if (stack.size <= 24) stack.indices.toList()
                else (0 until 16).toList() + (stack.size - 8 until stack.size).toList()
            indices.forEach { index ->
                val text = stack[index].toString()
                frames.put(JSONObject().put("index", index).put("text", text.take(256))
                    .put("text_truncated", text.length > 256))
            }
            return JSONObject().put("role", role).put("thread_id", thread.id).put("state", state)
                .put("stack_depth", stack.size).put("frames_omitted", stack.size - indices.size)
                .put("frames", frames)
        }
        val watchdog = Thread({
            try {
                var previousAttemptCompletedAt = -5000L
                for ((index, scheduledMillis) in listOf(5000L, 15000L).withIndex()) {
                    val remaining = (maxOf(scheduledMillis, previousAttemptCompletedAt + 5000L) - elapsedMillis()).coerceAtLeast(0L)
                    if (cancelled.await(remaining, java.util.concurrent.TimeUnit.MILLISECONDS)) break
                    val sampleStartedAt = elapsedMillis()
                    try {
                        val record = envelope("sample").put("sample", index + 1)
                            .put("scheduled_ms", scheduledMillis).put("elapsed_ms", sampleStartedAt)
                            .put("traversal", checkNotNull(traversal).snapshot())
                            .put("threads", JSONArray().put(snapshot("main", mainThread)).put(snapshot("test", testThread)))
                        if (cancelled.count == 0L) break
                        if (emit(record)) emitted.incrementAndGet() else observationErrors.incrementAndGet()
                    } catch (_: Throwable) { observationErrors.incrementAndGet() }
                    finally { previousAttemptCompletedAt = elapsedMillis() }
                }
            } catch (_: InterruptedException) { /* The owning wait completed or failed. */ }
        }, "owned-initial-idle").apply { isDaemon = true }
        var started = false
        try { watchdog.start(); started = true } catch (_: Throwable) { observationErrors.incrementAndGet() }
        try {
            wait()
        } finally {
            cancelled.countDown()
            var restoreInterrupt = false
            if (started) {
                try { watchdog.interrupt() } catch (_: Throwable) { observationErrors.incrementAndGet() }
                val joinDeadline = System.nanoTime() + 1_000_000_000L
                while (watchdog.isAlive) {
                    val remaining = joinDeadline - System.nanoTime()
                    if (remaining <= 0L) break
                    try { java.util.concurrent.TimeUnit.NANOSECONDS.timedJoin(watchdog, remaining) }
                    catch (_: InterruptedException) { restoreInterrupt = true }
                }
            }
            // A finite join is an observation, not proof of termination when a public API is blocked.
            try {
                emit(envelope("completion").put("started", started).put("joined", started && !watchdog.isAlive)
                    .put("cancel_requested", true).put("samples_emitted", emitted.get())
                    .put("observation_errors", observationErrors.get()).put("elapsed_ms", elapsedMillis()))
            } catch (_: Throwable) { /* Observation must retain the wait's original outcome. */ }
            finally { if (restoreInterrupt) testThread.interrupt() }
        }
    }

    private fun withScene(content: @Composable () -> Unit, phase: (String) -> Unit = {},
        initialIdleMethod: String? = null, assertions: () -> Unit) {
        val traversal = initialIdleMethod?.let { InitialIdleTraversalObservation() }
        try {
            phase("before_composition")
            compose.activityRule.scenario.onActivity {
                traversal?.attach(it)
                it.setContent(content = content)
            }
            phase("after_composition")
            phase("before_initial_idle")
            withInitialIdleWatchdog(initialIdleMethod, traversal) { compose.waitForIdle() }
            phase("after_initial_idle")
            phase("before_assertions")
            assertions()
        } finally {
            phase("cleanup_start")
            try {
                compose.activityRule.scenario.onActivity {
                    traversal?.remove()
                    it.setContent {}
                }
            } finally {
                // Failed/blocked main cleanup cannot masquerade as removed listeners.
                try { if (traversal != null && initialIdleMethod != null)
                    emitIdleDiagnostic(traversal.cleanupRecord(initialIdleMethod)) }
                catch (_: Throwable) { /* Preserve the original cleanup/test outcome. */ }
            }
            phase("cleanup_complete")
        }
    }
    private fun bounds(node: SemanticsNodeInteraction): Rect = node.getUnclippedBoundsInRoot().let {
        Rect(it.left.value, it.top.value, it.right.value, it.bottom.value)
    }
    private fun parent() = compose.onNodeWithTag("mai-containing-block", useUnmergedTree = true)
    private fun grid(path: String = "root/block-0") =
        compose.onNodeWithTag("compiled-table-grid-$path", useUnmergedTree = true)
    private fun gridCell(index: Int, path: String = "root/block-0") =
        compose.onNodeWithTag("compiled-table-cell-$path-$index", useUnmergedTree = true)
    private val horizontalScroll = SemanticsMatcher("an actual horizontal scroll owner") {
        it.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) != null
    }
    private fun assertReady() {
        compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
        compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
        compose.onAllNodes(horizontalScroll, useUnmergedTree = true).assertCountEquals(0)
    }
    private fun tapGlyph(label: String) {
        val node = compose.onNodeWithText(label, useUnmergedTree = true).assertIsDisplayed()
        val results = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
        compose.runOnIdle { assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus()) }
        node.performTouchInput { click(results.single().getBoundingBox(0).center) }
    }
    private data class Inspection(val owner: NativeFloatTextView, val context: NativeFloatContextGeometry,
        val leaf: NativeContextInputLeaf, val native: NativeFloatGeometry, val layout: android.text.StaticLayout,
        val surfaceOrigin: Offset)
    private fun inspect(text: String): Inspection {
        val matches = mutableListOf<Inspection>()
        fun visit(view: android.view.View) {
            if (view is NativeFloatTextView && view.isShown) {
                var geometry = view.currentMeasuredGeometry
                var surfaceOrigin = Offset.Zero
                while (true) {
                    val current = geometry
                    if (current is NativeSurfaceGeometry) {
                        surfaceOrigin += Offset(current.surface.left.toFloat(), current.surface.top.toFloat())
                        geometry = current.content
                    } else if (current?.javaClass?.simpleName == "NoPaintGeometry") {
                        geometry = current.javaClass.getDeclaredField("value").apply { isAccessible = true }
                            .get(current) as FloatTextGeometry
                    } else break
                }
                val context = geometry as? NativeFloatContextGeometry
                context?.inputLeaves()?.filter { it.geometry.text.toString() == text }?.forEach { leaf ->
                    val native = leaf.geometry as NativeFloatGeometry
                    val layout = NativeFloatGeometry::class.java.getDeclaredField("layout").apply { isAccessible = true }
                        .get(native) as android.text.StaticLayout
                    matches += Inspection(view, context, leaf, native, layout, surfaceOrigin)
                }
            }
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(compose.activity.window.decorView)
        return matches.single()
    }
    private fun nativeActionPoint(actual: Inspection, label: String, screenOrigin: Offset? = null,
        diagnosticMethod: String? = null): Offset {
        assertPhysicalActivity(compose.activity)
        check(compose.activity.hasWindowFocus())
        val geometry = checkNotNull(actual.owner.currentMeasuredGeometry)
        val action = geometry.nodes.single { it.label?.toString() == label }
        actual.owner.setSelection(action.start, action.end)
        assertEquals(label, actual.owner.selectedTextForCopy())
        val selection = actual.context.rectsForRange(action.start, action.end)
        val nativeSelection = actual.native.rectsForRange(action.start - actual.leaf.offset, action.end - actual.leaf.offset)
        assertEquals(nativeSelection.size, selection.size)
        nativeSelection.zip(selection).forEach { (local, owned) ->
            assertEquals(local.left + actual.leaf.x, owned.left, .01f)
            assertEquals(local.top + actual.leaf.y, owned.top, .01f)
            assertEquals(local.right + actual.leaf.x, owned.right, .01f)
            assertEquals(local.bottom + actual.leaf.y, owned.bottom, .01f)
        }
        val surfaceSelection = geometry.rectsForRange(action.start, action.end)
        assertEquals(selection.size, surfaceSelection.size)
        selection.zip(surfaceSelection).forEach { (context, surface) ->
            assertEquals(context.left - actual.surfaceOrigin.x, surface.left, .01f)
            assertEquals(context.top - actual.surfaceOrigin.y, surface.top, .01f)
            assertEquals(context.right - actual.surfaceOrigin.x, surface.right, .01f)
            assertEquals(context.bottom - actual.surfaceOrigin.y, surface.bottom, .01f)
        }
        actual.owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ESCAPE))
        val info = checkNotNull(actual.owner.accessibilityNodeProvider.createAccessibilityNodeInfo(action.id))
        return try {
            assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
            assertEquals(label, info.text?.toString())
            val rect = android.graphics.Rect().also(info::getBoundsInScreen)
            assertFalse(rect.isEmpty)
            if (screenOrigin == null) Offset(rect.exactCenterX(), rect.exactCenterY()) else {
                val expected = android.graphics.RectF()
                actual.context.nodes.single { it.label?.toString() == label }.bounds.forEach(expected::union)
                expected.offset(screenOrigin.x, screenOrigin.y)
                assertEquals("AX must round the transformed bounds, preserving the fractional owner origin",
                    android.graphics.Rect().also(expected::roundOut), rect)
                val provider = actual.owner.accessibilityNodeProvider
                val host = checkNotNull(provider.createAccessibilityNodeInfo(android.view.View.NO_ID))
                try {
                    val key = android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY
                    val arguments = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX, action.start)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH, action.end - action.start)
                    }
                    provider.addExtraDataToAccessibilityNodeInfo(android.view.View.NO_ID, host, key, arguments)
                    @Suppress("DEPRECATION")
                    val observed = checkNotNull(host.extras.getParcelableArray(key))
                    val characters = actual.context.characterRects(action.start, action.end - action.start)
                    if (diagnosticMethod != null && (characters.size != observed.size || characters.indices.any { index ->
                            val local = characters[index]
                            val remote = observed.getOrNull(index) as? android.graphics.RectF
                            local == null || remote == null ||
                                kotlin.math.abs(local.left + screenOrigin.x - remote.left) > .001f ||
                                kotlin.math.abs(local.top + screenOrigin.y - remote.top) > .001f ||
                                kotlin.math.abs(local.right + screenOrigin.x - remote.right) > .001f ||
                                kotlin.math.abs(local.bottom + screenOrigin.y - remote.bottom) > .001f
                        })) {
                        characterFailure(diagnosticMethod, actual, label, action.start, action.end,
                            screenOrigin, characters, observed.toList())
                    }
                    assertEquals(characters.size, observed.size)
                    characters.forEachIndexed { index, local ->
                        val transformed = android.graphics.RectF(checkNotNull(local)).apply { offset(screenOrigin.x, screenOrigin.y) }
                        val character = observed[index] as android.graphics.RectF
                        assertEquals("Character $index left must retain its fractional owner transform", transformed.left, character.left, .001f)
                        assertEquals("Character $index top must retain its fractional owner transform", transformed.top, character.top, .001f)
                        assertEquals("Character $index right must retain its fractional owner transform", transformed.right, character.right, .001f)
                        assertEquals("Character $index bottom must retain its fractional owner transform", transformed.bottom, character.bottom, .001f)
                    }
                } finally { host.recycle() }
                val glyph = checkNotNull(actual.context.characterRects(action.start, 1).single())
                Offset(glyph.centerX() + screenOrigin.x, glyph.centerY() + screenOrigin.y)
            }
        } finally { info.recycle() }
    }
    private fun characterFailure(method: String, actual: Inspection, label: String, start: Int, end: Int,
        screenOrigin: Offset, local: List<android.graphics.RectF?>, provider: List<Any?>) {
        try {
            var nonfinite = false
            fun rect(value: android.graphics.RectF?): Any {
                if (value == null) return JSONObject.NULL
                val coordinates = listOf(value.left, value.top, value.right, value.bottom)
                if (coordinates.any { !it.isFinite() }) { nonfinite = true; return JSONObject.NULL }
                return JSONArray(coordinates)
            }
            val characters = JSONArray()
            for (index in 0 until minOf(end - start, 32)) {
                val offset = start + index
                val nativeOffset = offset - actual.leaf.offset
                val native = if (nativeOffset in 0 until actual.native.text.length)
                    actual.native.characterRects(nativeOffset, 1).single() else null
                val remote = provider.getOrNull(index)
                characters.put(JSONObject().put("offset", offset).put("native_offset", nativeOffset)
                    .put("local", rect(local.getOrNull(index))).put("native", rect(native))
                    .put("provider", rect(remote as? android.graphics.RectF))
                    .put("provider_type", (remote?.javaClass?.simpleName ?: "null").take(64)))
            }
            val contextText = actual.context.text.toString()
            val nativeText = actual.native.text.toString()
            val geometry = JSONObject().put("action_text", label.take(128)).put("context_text", contextText.take(128))
                .put("native_text", nativeText.take(128)).put("action_start", start).put("action_end", end)
                .put("leaf_offset", actual.leaf.offset).put("owner_id", System.identityHashCode(actual.owner))
                .put("owner_class", "NativeFloatTextView")
                .put("screen_origin", JSONArray(listOf(screenOrigin.x, screenOrigin.y)))
                .put("surface_origin", JSONArray(listOf(actual.surfaceOrigin.x, actual.surfaceOrigin.y)))
                .put("characters", characters).put("nonfinite_rectangles", nonfinite)
                .put("truncated", end - start > 32 || label.length > 128 || contextText.length > 128 || nativeText.length > 128)
            diagnostic(method, "geometry_failure", "before_character_assertion", geometry)
        } catch (_: Throwable) { /* Keep the original geometry assertion authoritative. */ }
    }

    private fun tapScreen(point: Offset) {
        val rootOrigin = compose.onRoot().fetchSemanticsNode().positionOnScreen
        compose.onRoot().performTouchInput { click(point - rootOrigin) }
    }

    @Test fun fractionalRootThresholdRepositionsTheSameCellsAndActionsWithoutAddingAScrollOwner() {
        val viewport = mutableStateOf(639.0)
        val opened = mutableListOf<String>()
        val value = table()
        withScene({ Scene(listOf(block(value)), viewport.value, onLink = { opened += it.target }) }) {
            for (cssWidth in listOf(639.0, 639.5, 639.0, 640.0)) {
                compose.runOnIdle { viewport.value = cssWidth }
                compose.waitForIdle()
                assertReady()
                compose.onAllNodesWithText("A", useUnmergedTree = true).assertCountEquals(1)
                compose.onAllNodesWithText("B", useUnmergedTree = true).assertCountEquals(1)
                val actual = bounds(grid())
                assertEquals(60f, actual.width, .01f)
                assertEquals(if (cssWidth <= 639.0) 4f else 34f, actual.left - bounds(parent()).left, .01f)
                assertEquals(30f, bounds(gridCell(0)).left - actual.left, .01f)
                assertEquals(0f, bounds(gridCell(1)).left - actual.left, .01f)
                assertEquals(TableFloatSide.Right, value.style!!.floatSide)
                tapGlyph("A")
            }
            compose.runOnIdle { assertEquals(List(4) { "Mai-A" }, opened) }
        }

        // Constructor-domain projection of retained Mai Table1343, bytes48877..49892 in
        // page.expanded.wikitext (01d3e7a4). All real cells and colspan7 remain distinct.
        // The normal Cell08 route below is an explicit synthetic constructor premise:
        // actual source font/line-height metrics and compiled Mai issuance remain unearned.
        data class SourceAction(val start: Int, val end: Int, val target: EntryLink)
        data class SourceCell(val value: Cell, val text: String, val actions: List<SourceAction>)
        fun sourceCell(spans: List<Span>, text: String, actions: List<SourceAction> = emptyList(),
            header: Boolean = false, colspan: Int = 1): SourceCell = SourceCell(
            Cell(spans, header, colspan, 1, style = CellStyle(border = StyleBorder.None,
                padding = zeroEdges(), lineHeight = CellLineHeight(CellLineHeightValue.Normal))), text, actions)
        fun linkCell(label: String, target: String) = sourceCell(listOf(Span("link", label, target)),
            label, listOf(SourceAction(0, label.length, EntryLink(target))), header = true)
        fun smallBody(prefix: String) = sourceCell(listOf(Span("text", prefix), Span("line_break", ""),
            Span("text", "(Mai)", small = true)), "$prefix\n(Mai)")
        fun plural(prefix: String) = sourceCell(listOf(Span("text", prefix), Span("link", "Mais", "Mais")),
            prefix + "Mais", listOf(SourceAction(prefix.length, prefix.length + 4, EntryLink("Mais"))))
        val grammar = EntryLink("Hilfe:Vor-_und_Nachnamen/Grammatik_der_deutschen_Namen", "Familiennamen")
        val sourceRows = listOf(
            listOf(sourceCell(emptyList(), "", header = true),
                sourceCell(listOf(Span("link", "Singular ", "Hilfe:Singular"),
                    Span("link", "m", "Hilfe:Singular", italic = true)), "Singular m",
                    listOf(SourceAction(0, 9, EntryLink("Hilfe:Singular")), SourceAction(9, 10, EntryLink("Hilfe:Singular"))), true),
                sourceCell(listOf(Span("link", "Singular ", "Hilfe:Singular"),
                    Span("link", "f", "Hilfe:Singular", italic = true)), "Singular f",
                    listOf(SourceAction(0, 9, EntryLink("Hilfe:Singular")), SourceAction(9, 10, EntryLink("Hilfe:Singular"))), true),
                linkCell("Plural", "Hilfe:Plural")),
            listOf(linkCell("Nominativ", "Hilfe:Nominativ"), smallBody("der Mai"), smallBody("die Mai"), plural("die ")),
            listOf(linkCell("Genitiv", "Hilfe:Genitiv"),
                sourceCell(listOf(Span("text", "des Mai"), Span("line_break", ""), Span("text", "des "),
                    Span("link", "Mais", "Mais"), Span("line_break", ""), Span("link", "Mais", "Mais")),
                    "des Mai\ndes Mais\nMais", listOf(SourceAction(12, 16, EntryLink("Mais")), SourceAction(17, 21, EntryLink("Mais")))),
                smallBody("der Mai"), plural("der ")),
            listOf(linkCell("Dativ", "Hilfe:Dativ"), smallBody("dem Mai"), smallBody("der Mai"), plural("den ")),
            listOf(linkCell("Akkusativ", "Hilfe:Akkusativ"), smallBody("den Mai"), smallBody("die Mai"), plural("die ")),
            listOf(sourceCell(listOf(Span("text", "siehe auch:", italic = true, fontScale = .88f),
                Span("text", " ", fontScale = .88f), Span("link", "Grammatik der deutschen Namen", grammar.target,
                    fontScale = .88f, targetFragment = grammar.targetFragment)), "siehe auch: Grammatik der deutschen Namen",
                listOf(SourceAction(12, "siehe auch: Grammatik der deutschen Namen".length, grammar)), true, 7)))
        val realCells = sourceRows.flatten()
        assertEquals(21, realCells.size)
        assertEquals(16, realCells.sumOf { it.actions.size }) // Styled m/f split their source A into two ranges.
        val sourceTable = table(policy(TableContainingDirection.Ltr, TableContainingDirection.Ltr, "de"),
            rows = sourceRows.map { row -> row.map { it.value } })
        val sourceViewport = mutableStateOf(639.5)
        val containingWidth = mutableStateOf(640)
        val sourceOpened = mutableListOf<EntryLink>()
        withScene({
            CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                LocalLayoutDirection provides LayoutDirection.Ltr,
                LocalTableDocumentViewportCssWidth provides sourceViewport.value) {
                DictTheme("light") {
                    MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp,
                        fontFamily = FontFamily.Serif, letterSpacing = 0.sp))) {
                        // Explicit containing constraints exercise both natural fit and signed overflow;
                        // the source viewport threshold is independent of this test allocation.
                        Layout(content = {
                            NativeFloatBlockContext(listOf(block(sourceTable)), { sourceOpened += it }, "mai-focus-domain",
                                Modifier, inCell = false, gridPath = "root", gapDp = 0f, trailingGap = false)
                        }) { children, constraints ->
                            val child = children.single().measure(Constraints(maxWidth = containingWidth.value))
                            layout(constraints.maxWidth, child.height) { child.place(0, 0) }
                        }
                    }
                }
            }
        }) {
            for (cssWidth in listOf(639.5, 639.0)) for (available in listOf(640, 100)) {
                compose.runOnIdle { sourceViewport.value = cssWidth; containingWidth.value = available }
                compose.waitForIdle()
                assertReady()
                val actualWidth = bounds(grid()).width
                if (available == 640) assertTrue(actualWidth <= available)
                else assertTrue("The real grid must overflow the narrow allocation without a scroll owner", actualWidth > available)
                (listOf(grid()) + realCells.indices.map { gridCell(it) }).forEach { owner ->
                    val semantics = owner.fetchSemanticsNode().config
                    assertFalse("Collection metadata is not a source input-focus owner", semantics.contains(SemanticsActions.RequestFocus))
                    assertFalse("No source table/row/cell action is synthesized", semantics.contains(SemanticsActions.OnClick))
                }
                compose.runOnIdle {
                    val nativeViews = mutableListOf<NativeFloatTextView>()
                    fun visit(view: android.view.View) {
                        if (view is NativeFloatTextView) nativeViews += view
                        if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
                    }
                    visit(compose.activity.window.decorView)
                    val expectedCells = realCells.filter { it.text.isNotEmpty() }
                    val actualCells = nativeViews.mapNotNull { view ->
                        view.currentMeasuredGeometry?.let { geometry ->
                            if (expectedCells.any { it.text == geometry.text.toString() }) view to geometry
                            else { assertTrue("Reader host adds no source node", geometry.nodes.isEmpty()); null }
                        }
                    }
                    assertEquals(expectedCells.groupingBy { it.text }.eachCount(),
                        actualCells.groupingBy { it.second.text.toString() }.eachCount())
                    sourceOpened.clear()
                    actualCells.forEach { (view, geometry) ->
                        val expected = expectedCells.first { it.text == geometry.text.toString() }
                        assertEquals(expected.actions.size, geometry.nodes.size)
                        geometry.nodes.zip(expected.actions).forEach { (node, action) ->
                            assertEquals(FloatInteractionKind.LINK, node.kind)
                            assertEquals(action.start, node.start); assertEquals(action.end, node.end)
                            assertEquals(expected.text.substring(action.start, action.end), node.label.toString())
                            assertNotNull(node.onClick); assertNull(node.onLongClick)
                            val provider = checkNotNull(view.accessibilityNodeProvider)
                            val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                            try { assertTrue(info.isClickable) } finally { info.recycle() }
                            assertTrue(provider.performAction(node.id,
                                android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                            assertEquals(action.target, sourceOpened.last())
                        }
                    }
                    assertEquals(16, sourceOpened.size)
                }
            }
        }
    }

    @Test fun signedFixedPlacementUsesContainingDirectionAndDoesNotClipTheOverflowingGrid() {
        val containing = mutableStateOf(TableContainingDirection.Ltr)
        val minimum = mutableStateOf(30f)
        val viewport = mutableStateOf(639.0)
        withScene({
            Scene(listOf(block(table(policy(containing.value,
                if (containing.value == TableContainingDirection.Ltr) TableContainingDirection.Rtl else TableContainingDirection.Ltr),
                minimum.value))), viewport.value)
        }) {
            for (source in TableContainingDirection.entries) for (cellWidth in listOf(30f, 70f))
                for (cssWidth in listOf(639.0, 639.5)) {
                    compose.runOnIdle { containing.value = source; minimum.value = cellWidth; viewport.value = cssWidth }
                    compose.waitForIdle()
                    assertReady()
                    val actual = bounds(grid()); val container = bounds(parent())
                    val expectedWidth = cellWidth * 2f
                    val expectedLeft = if (cssWidth <= 639.0 && source == TableContainingDirection.Ltr) 4f
                        else 100f - 6f - expectedWidth
                    assertEquals(expectedWidth, actual.width, .01f)
                    assertEquals(expectedLeft, actual.left - container.left, .01f)
                    assertEquals(if (source == TableContainingDirection.Ltr) cellWidth else 0f,
                        bounds(gridCell(0)).left - actual.left, .01f)
                    if (cellWidth == 70f) {
                        val outsideX = if (expectedLeft < 0f) container.left - 10f else container.right + 10f
                        val root = compose.onRoot(); val rootBounds = bounds(root)
                        val image = root.captureToImage().asAndroidBitmap()
                        try {
                            val x = floor(outsideX - rootBounds.left).toInt()
                            val y = floor(actual.bottom - 3f - rootBounds.top).toInt()
                            assertEquals("Existing containing width must not become a new table clip", 0xffe40000.toInt(), image.getPixel(x, y))
                        } finally { image.recycle() }
                    }
                }
        }
    }

    @Test fun aTableInsideActualCellBlocksStillUsesTheRootViewportAndItsOwnContainingWidth() {
        val viewport = mutableStateOf(639.5)
        val opened = mutableListOf<String>()
        val nested = table(policy(grid = TableContainingDirection.Ltr))
        val containingCell = Cell(emptyList(), false, 1, 1,
            blocks = listOf(block(nested)), style = CellStyle(border = StyleBorder.None, padding = zeroEdges(), minWidth = px(180f)))
        val outer = Table(emptyList(), listOf(listOf(containingCell)),
            style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 180f), border = StyleBorder.None,
                collapse = TableCollapse.Collapse, margins = zeroEdges()))
        withScene({ Scene(listOf(block(outer)), viewport.value, width = 200, onLink = { opened += it.target }) }) {
            for (cssWidth in listOf(639.5, 639.0, 640.0)) {
                compose.runOnIdle { viewport.value = cssWidth }
                compose.waitForIdle()
                // The ordinary outer table may keep its existing scroll owner; the nested policy must add none.
                compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
                val actual = bounds(grid("root/block-0/0/block-0"))
                val cellBounds = bounds(gridCell(0))
                assertEquals(60f, actual.width, .01f)
                assertEquals(180f, cellBounds.width, .01f)
                assertEquals(if (cssWidth <= 639.0) 4f else cellBounds.width - 6f - actual.width,
                    actual.left - cellBounds.left, .01f)
                compose.onAllNodes(horizontalScroll and hasAnyAncestor(hasTestTag("compiled-table-cell-root/block-0-0")),
                    useUnmergedTree = true).assertCountEquals(0)
                tapGlyph("B")
            }
            compose.runOnIdle { assertEquals(List(3) { "Mai-B" }, opened) }
        }
    }

    @Test fun fractionalNormalBodyMarginsStayIndependentOfTheCellsEnlargedFont() {
        val viewport = mutableStateOf(639.0)
        val scale = mutableStateOf(1f)
        val opened = mutableListOf<String>()
        val sourceMargins = StyleEdges(em(.13f), em(.25f), em(.09f), em(.15f))
        val bodyPixels = with(Density(1f, 1.25f)) { 20.sp.toPx() }
        withScene({
            val value = table(policy(grid = TableContainingDirection.Ltr), edges = sourceMargins,
                rows = listOf(listOf(cell("M", 160f, listOf(Span("link", "M", "Mai-M",
                    fontScale = scale.value, fontScaleBasis = FontScaleBasis.NormalBody))))))
            Scene(listOf(block(value)), viewport.value, width = 220, fontScale = 1.25f, onLink = { opened += it.target })
        }) {
            for (cellScale in listOf(1f, 3f)) for (cssWidth in listOf(639.0, 639.5)) {
                compose.runOnIdle { scale.value = cellScale; viewport.value = cssWidth }
                compose.waitForIdle()
                assertReady()
                val actual = bounds(grid()); val container = bounds(parent())
                assertEquals(160f, actual.width, .01f)
                assertEquals(if (cssWidth <= 639.0) .15f * bodyPixels else 220f - 160f - .25f * bodyPixels,
                    actual.left - container.left, .01f)
                assertEquals(.13f * bodyPixels, actual.top - container.top, .01f)
                assertEquals(actual.left, bounds(gridCell(0)).left, .01f)
                assertEquals(actual.top, bounds(gridCell(0)).top, .01f)
                tapGlyph("M")
            }
            compose.runOnIdle { assertEquals(List(4) { "Mai-M" }, opened) }
        }
    }

    @Test fun wideFloatWrapsFollowingTextAndClearWhileNarrowStateOwnsOrdinaryFlowHeight() {
        diagnosticSequence = 0
        fun phase(value: String) = diagnostic("wideFloatWrapsFollowingTextAndClearWhileNarrowStateOwnsOrdinaryFlowHeight", "phase", value)
        val viewport = mutableStateOf(639.5)
        val label = "Following text remains beside the actual table until its margin box ends."
        val cleared = "Clear"
        val value = table(policy(grid = TableContainingDirection.Ltr), edges = margins(2f, 6f, 5f, 4f),
            rows = (0..3).map { listOf(cell("R$it", 60f)) })
        val paragraph = Block("paragraph", 0, listOf(Span("text", label)))
        val afterClear = Block("container", 0, emptyList(), container = Container(
            listOf(Block("paragraph", 0, listOf(Span("link", cleared, "Mai-Clear")))),
            ContainerStyle(clear = FigureClear.Right)))
        withScene({ Scene(listOf(block(value), paragraph, afterClear), viewport.value, width = 200) }, phase = ::phase,
            initialIdleMethod = "wideFloatWrapsFollowingTextAndClearWhileNarrowStateOwnsOrdinaryFlowHeight") {
            for (cssWidth in listOf(639.5, 639.0, 640.0)) {
                phase("before_viewport_update")
                compose.runOnIdle { viewport.value = cssWidth }
                phase("before_idle")
                compose.waitForIdle()
                phase("after_idle")
                phase("before_ready")
                assertReady()
                phase("before_geometry")
                val actual = bounds(grid()); val container = bounds(parent())
                phase("before_native_inspection")
                compose.runOnIdle {
                    val following = inspect(label)
                    val clearing = inspect(cleared)
                    val band = following.native.firstLineBand()
                    if (cssWidth > 639.0) {
                        val exclusion = following.context.ownExclusions.single()
                        assertEquals(TableFloatSide.Right, exclusion.side)
                        assertEquals(70f, exclusion.outer.right - exclusion.outer.left, .01f)
                        assertEquals(actual.bottom - container.top + 5f, exclusion.outer.bottom, .01f)
                        assertTrue(following.leaf.y < actual.bottom - container.top)
                        assertEquals(130f, band.width(), .01f)
                        assertTrue(clearing.leaf.y >= exclusion.outer.bottom)
                    } else {
                        assertTrue(following.context.ownExclusions.isEmpty())
                        assertTrue(following.leaf.y >= actual.bottom - container.top + 5f)
                        assertEquals(200f, band.width(), .01f)
                        assertTrue(clearing.leaf.y >= following.leaf.y + following.native.textBottom)
                    }
                }
                phase("after_native_inspection")
            }
            phase("method_complete")
        }
    }

    @Test fun sourceLanguageAndGridDirectionReachNativeStrutSelectionAndActionsInBothStates() {
        val viewport = mutableStateOf(639.0)
        val opened = mutableListOf<String>()
        val spans = listOf(Span("link", "M", "Mai-first", language = "ja", foreground = "#d00000", fontScale = 2f,
            fontScaleBasis = FontScaleBasis.NormalBody), Span("text", " "), Span("link", "reset", "Mai-reset", foreground = "#d00000"))
        val nativeCell = cell("unused", 140f, spans).copy(background = "#ffffff", style = CellStyle(border = StyleBorder.None,
            padding = zeroEdges(), minWidth = px(140f), verticalAlign = CellVerticalAlign.Top,
            lineHeight = CellLineHeight(CellLineHeightValue.Length(CellFixedLineHeight(.7f, FontScaleBasis.NormalBody)),
                CellTextStrut(.7f, FontScaleBasis.NormalBody))))
        val value = table(edges = margins(.5f, 6.75f, 5.25f, 4.25f), rows = listOf(listOf(nativeCell)))
        val entry = Entry("Native source owner", emptyList(), "language", "Japanese", "ja",
            listOf(Section(2, "", listOf(block(value)))), emptyList(), edition = "ja")
        withScene({
            CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides LayoutDirection.Ltr,
                LocalTableDocumentViewportCssWidth provides viewport.value) {
                DictTheme("light") {
                    MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp,
                        fontFamily = FontFamily.Serif, letterSpacing = 0.sp, localeList = LocaleList("tr")))) {
                        Box(Modifier.width(224.dp)) {
                            EntryView(entry, false, {}, onLink = { opened += it.target }, settings = AppSettings(
                                allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false))
                        }
                    }
                }
            }
        }) {
            for ((iteration, cssWidth) in listOf(639.0, 639.5, 639.0).withIndex()) {
                compose.runOnIdle { viewport.value = cssWidth }
                compose.waitForIdle()
                assertReady()
                val nativeCellMatcher = SemanticsMatcher("the actual native source-language cell") {
                    it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith("compiled-table-cell-") == true
                }
                val actualCell = bounds(compose.onNode(nativeCellMatcher, useUnmergedTree = true))
                val root = compose.onRoot().fetchSemanticsNode()
                val windowOrigin = root.positionOnScreen - root.boundsInRoot.topLeft
                assertEquals(.25f, actualCell.left - floor(actualCell.left), .01f)
                assertEquals(.5f, actualCell.top - floor(actualCell.top), .01f)
                val actual = compose.runOnIdle {
                    val actual = inspect("M reset")
                    assertEquals("ja", entry.languageCode)
                    assertEquals("ja", entry.edition)
                    assertEquals("ru", value.floatViewport!!.language)
                    assertEquals("ru", actual.layout.paint.textLocales.toLanguageTags())
                    assertEquals(14f, actual.layout.paint.textSize, .01f)
                    assertEquals(-1, actual.layout.getParagraphDirection(actual.layout.getLineForOffset(0)))
                    val text = actual.native.text as android.text.Spanned
                    val strut = text.getSpans(0, text.length, NativeRunLineMetrics::class.java).single { it.strut }
                    assertEquals(14f, strut.primary.fontSize, .01f)
                    assertEquals(NativeLineHeightPolicy.Pixels(14f), strut.policy)
                    fun runPaint(offset: Int) = android.text.TextPaint(actual.layout.paint).also { paint ->
                        text.getSpans(offset, offset + 1, android.text.style.MetricAffectingSpan::class.java)
                            .filter { text.getSpanStart(it) <= offset && text.getSpanEnd(it) > offset }
                            .forEach { it.updateMeasureState(paint) }
                    }
                    assertEquals("ja", runPaint(0).textLocales.toLanguageTags())
                    assertEquals(40f, runPaint(0).textSize, .01f)
                    assertEquals("ru", runPaint(2).textLocales.toLanguageTags())
                    assertEquals(14f, runPaint(2).textSize, .01f)
                    actual
                }
                val ink = compose.runOnIdle {
                    val action = actual.context.nodes.single { it.label?.toString() == "reset" }
                    android.graphics.RectF().also { rectangle ->
                        actual.context.characterRects(action.start, action.end - action.start).filterNotNull().forEach(rectangle::union)
                        rectangle.offset(actualCell.left, actualCell.top)
                    }
                }
                // Observe actual glyph paint before selection changes its appearance.
                val image = compose.onRoot().captureToImage().asAndroidBitmap()
                try {
                    var redPixels = 0
                    val rootBounds = root.boundsInRoot
                    val left = floor(ink.left - rootBounds.left).toInt().coerceAtLeast(0)
                    val top = floor(ink.top - rootBounds.top).toInt().coerceAtLeast(0)
                    val right = ceil(ink.right - rootBounds.left).toInt().coerceAtMost(image.width)
                    val bottom = ceil(ink.bottom - rootBounds.top).toInt().coerceAtMost(image.height)
                    assertTrue(right > left && bottom > top)
                    for (y in top until bottom) for (x in left until right) {
                        val color = image.getPixel(x, y)
                        val red = color ushr 16 and 255; val green = color ushr 8 and 255; val blue = color and 255
                        if (red > green + 40 && red > blue + 40) redPixels++
                    }
                    assertTrue("Actual reset glyph ink must occupy its independently positioned native bounds", redPixels > 0)
                } finally { image.recycle() }
                val point = compose.runOnIdle { nativeActionPoint(actual, "reset", windowOrigin + actualCell.topLeft,
                    diagnosticMethod = "sourceLanguageAndGridDirectionReachNativeStrutSelectionAndActionsInBothStates") }
                tapScreen(point)
                compose.runOnIdle { assertEquals(List(iteration + 1) { "Mai-reset" }, opened) }
            }
        }
    }

    @Test fun unsupportedNativeLanguageRetainsTheSameBodyAndActionAcrossBothStatesAndRecovery() {
        val viewport = mutableStateOf(639.0)
        val unavailable = mutableStateOf(false)
        val opened = mutableListOf<String>()
        val supported = table(rows = listOf(listOf(cell("Keep", 100f))))
        // Valid source UTF-8; the native locale canonicalizer drops this extlang identity.
        val unsupported = supported.copy(floatViewport = supported.floatViewport!!.copy(language = "zh-cmn"))
        val warning = "Table language is unavailable for this layout."
        val fallback = compose.onNodeWithTag("compiled-table-language-unavailable", useUnmergedTree = true)
        withScene({ Scene(listOf(block(if (unavailable.value) unsupported else supported)), viewport.value,
            width = 200, onLink = { opened += it.target }) }) {
            for (cssWidth in listOf(639.0, 639.5)) {
                for (refused in listOf(false, true, false)) {
                    compose.runOnIdle { viewport.value = cssWidth; unavailable.value = refused }
                    compose.waitForIdle()
                    compose.onAllNodesWithText("Keep", useUnmergedTree = true).assertCountEquals(1)
                    assertSame(supported.rows, unsupported.rows)
                    assertEquals("zh-cmn", unsupported.floatViewport!!.language)
                    if (refused) {
                        fallback.assertIsDisplayed()
                        compose.onNode(hasText(warning) and hasAnyAncestor(hasTestTag("compiled-table-language-unavailable")),
                            useUnmergedTree = true).assertIsDisplayed()
                        grid().assertDoesNotExist()
                    } else { fallback.assertDoesNotExist(); assertReady() }
                    compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                    tapGlyph("Keep")
                }
            }
            compose.runOnIdle { assertEquals(List(6) { "Mai-Keep" }, opened) }
        }
    }

    @Test fun responsiveTableInFigureCaptionRefusesPlacementButRetainsSourceOwnersSelectionAndAction() {
        val viewport = mutableStateOf(639.0)
        val value = table(edges = zeroEdges(), rows = listOf(listOf(cell("First", 80f), cell("Last", 80f))))
        val borders = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None)
        val media = FigureMediaLayout(FigureMediaStrut(0f, direction = BidiResolvedDirection.Ltr), InlineBoxVerticalAlign.Baseline)
        val zero = zeroEdges()
        val figure = Figure(FigureContent.Missing(Span("text", "media"), px(80f), px(20f)),
            FigureFormat.Framed, FigurePlacement.None, FigureClear.None, zero, zero, zero,
            1f, px(24f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
            FigureColor.NativeTheme, FigureColor.Transparent, captionBlocks = listOf(block(value)),
            tableCaptionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), borders, borders, media))
        val context = AnonymousFlowContext(BidiResolvedDirection.Ltr, "ja", null)
        val style = TextStyle(fontSize = 16.sp, lineHeight = 24.sp, fontFamily = FontFamily.Monospace,
            localeList = LocaleList("tr"))
        val flow = anonymousFlowContent(Block("paragraph", 0, emptyList(), figure = figure), context)
        val pixels = FigurePixelEdges(0f, 0f, 0f, 0f)
        val natural = FigureBoxMetrics(FigurePixels(80f, 40f), pixels, pixels, pixels, 0f, 0f)
        val prepared = FigureTableCaptionMetrics(figure.tableCaptionLayout!!, natural, 1f, 16f, false,
            FigureMediaFont(NativePrimaryFontMetrics(0f, 0f, 0f, 0f), 0f), 0f)
        val opened = mutableListOf<String>()
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false), "ja",
            { opened += it.target }, Any())
        var frame: FloatTextGeometry? = null
        var published: FloatTextGeometry? = null
        var captionGeometry: FloatTextGeometry? = null
        val warning = "Responsive floated caption table needs a shared exclusion owner"
        fun cellLayout(): android.text.StaticLayout {
            val matches = mutableListOf<NativeFloatGeometry>()
            fun visit(geometry: FloatTextGeometry) {
                if (geometry.javaClass.simpleName == "NoPaintGeometry") {
                    visit(geometry.javaClass.getDeclaredField("value").apply { isAccessible = true }
                        .get(geometry) as FloatTextGeometry)
                    return
                }
                when (geometry) {
                    is NativeSurfaceGeometry -> visit(geometry.content)
                    is NativeSemanticGroup -> {
                        @Suppress("UNCHECKED_CAST")
                        val children = NativeSemanticGroup::class.java.getDeclaredField("children").apply { isAccessible = true }
                            .get(geometry) as List<PositionedSemanticChild>
                        children.forEach { visit(it.geometry) }
                    }
                    is NativeAnonymousFlowGeometry -> if (geometry.text.toString() == "First") {
                        matches += NativeAnonymousFlowGeometry::class.java.getDeclaredField("native").apply { isAccessible = true }
                            .get(geometry) as NativeFloatGeometry
                    }
                }
            }
            visit(checkNotNull(captionGeometry))
            return NativeFloatGeometry::class.java.getDeclaredField("layout").apply { isAccessible = true }
                .get(matches.single()) as android.text.StaticLayout
        }
        withScene({
            MaterialTheme {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides LayoutDirection.Ltr, LocalTableDocumentViewportCssWidth provides viewport.value) {
                    Layout(content = {
                        AnonymousFlowLayout(flow, remember { TextPaint().apply { textSize = 16f } },
                            Modifier.testTag("mai-figure-flow"), Color.Blue,
                            inline = { _, _ -> SpannableString("") },
                            figureSpec = { _, _ -> AnonymousFigureMeasureSpec(80, FloatMargins(0f, 0f, 0f, 0f),
                                frameMinimumWidens = true, childMinimumFloor = true) },
                            inlineNodes = { emptyList() }, semanticGeometry = { _, _, _ -> frame },
                            onGeometry = { published = it }) { _ ->
                            FigureChildLayout(natural, { frame = it }, null, prepared, caption = { sink ->
                                FigureCaptionBlocks(figure.captionBlocks!!, context, style, reader, sink)
                            }) { metrics, caption ->
                                captionGeometry = caption
                                NativeFigureGeometry(metrics, caption, FigurePaints(0, 0, 0, 0, 0),
                                    { canvas, rect -> canvas.drawRect(rect, Paint().apply { color = android.graphics.Color.BLUE }) },
                                    { emptyList() })
                            }
                        }
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(320))
                        layout(320, child.height) { child.place(0, 0) }
                    }
                }
            }
        }) {
            for ((index, cssWidth) in listOf(639.0, 639.5).withIndex()) {
                compose.runOnIdle { viewport.value = cssWidth }
                compose.waitForIdle()
                compose.onAllNodesWithText(warning, useUnmergedTree = true).assertCountEquals(1)
                compose.onNodeWithText(warning, useUnmergedTree = true).assertIsDisplayed()
                grid("figure-caption").assertIsDisplayed()
                assertTrue(bounds(gridCell(0, "figure-caption")).left > bounds(gridCell(1, "figure-caption")).left)
                compose.onAllNodes(horizontalScroll, useUnmergedTree = true).assertCountEquals(0)
                val point = compose.runOnIdle {
                    assertSame(value, figure.captionBlocks!!.single().table)
                    assertEquals("ru", value.floatViewport!!.language)
                    val native = cellLayout()
                    assertEquals("ru", native.paint.textLocales.toLanguageTags())
                    assertEquals(-1, native.getParagraphDirection(0))
                    val geometry = checkNotNull(published)
                    val text = geometry.text.toString()
                    assertEquals(2, text.split("First").size)
                    assertEquals(2, text.split("Last").size)
                    val start = text.indexOf("First")
                    val node = geometry.nodes.single { it.start == start && it.onClick != null }
                    val rect = node.bounds.first()
                    assertEquals(node.id, geometry.interactionNodeAt(rect.centerX(), rect.centerY())?.id)
                    assertTrue(geometry.rectsForRange(start, start + "First".length).isNotEmpty())
                    assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
                    Offset(rect.centerX(), rect.centerY())
                }
                compose.onNodeWithTag("mai-figure-flow").performTouchInput { click(point) }
                compose.runOnIdle { assertEquals(List(index + 1) { "Mai-First" }, opened) }
            }
        }
    }

    @Test fun prefixPreferredWidthUsesNormalBodyWhileNarrowClearRetainsTheActualGridAndActions() {
        // Synthetic typed API06 premise; this is not an issued TH page fixture.
        val viewport = mutableStateOf(639.5)
        val zoom = mutableStateOf(1f)
        val fixtureDensity = Density(1f, 1.25f)
        val bodyPixels = with(fixtureDensity) { 20.sp.toPx() }
        val preferredWidth = round(4.0 * bodyPixels).toFloat()
        val inheritedPixels = with(fixtureDensity) { 10.sp.toPx() }
        val opened = mutableListOf<EntryLink>()
        val action = Span("link", "P", "PrefixTarget", targetFragment = "part", foreground = "#000080",
            fontScale = 10f, fontScaleBasis = FontScaleBasis.CssPx)
        val sourceCell = cell("unused", 1f, listOf(action)).copy(style = CellStyle(border = StyleBorder.None,
            padding = zeroEdges(), minWidth = px(1f), verticalAlign = CellVerticalAlign.Top,
            lineHeight = CellLineHeight(CellLineHeightValue.Length(CellFixedLineHeight(1f, FontScaleBasis.NormalBody)),
                CellTextStrut(1f, FontScaleBasis.NormalBody))))
        val main = table(policy(grid = TableContainingDirection.Ltr).copy(narrowClear = FigureClear.Both),
            rows = listOf(listOf(sourceCell))).let {
            it.copy(style = it.style!!.copy(width = StyleWidth(StyleWidthUnit.Em, 4f), clear = FigureClear.Right))
        }
        val noOverride = main.copy(floatViewport = main.floatViewport!!.copy(narrowClear = null))
        val overLtr = main.copy(style = main.style!!.copy(width = StyleWidth(StyleWidthUnit.Px, 230f)))
        val overRtl = overLtr.copy(floatViewport = overLtr.floatViewport!!.copy(containingDirection = TableContainingDirection.Rtl))
        val selected = mutableStateOf(main)
        val blockerCell = cell("F", 50f, listOf(Span("text", "F"))).copy(background = "#00a040",
            style = CellStyle(border = StyleBorder.None, padding = zeroEdges(), minWidth = px(50f),
                lineHeight = CellLineHeight(CellLineHeightValue.Length(CellFixedLineHeight(2f, FontScaleBasis.NormalBody)),
                    CellTextStrut(1f, FontScaleBasis.NormalBody))))
        val blocker = Table(emptyList(), List(2) { listOf(blockerCell) }, style = TableStyle(
            width = StyleWidth(StyleWidthUnit.Px, 50f), border = StyleBorder.None,
            collapse = TableCollapse.Collapse, margins = zeroEdges(), floatSide = TableFloatSide.Left))
        val inherited = ContainerStyle(ownerFontScale = .5f)
        val targetPath = "root/block-0/container/block-1"
        val blockerPath = "root/block-0/container/block-0"
        data class Phase(val value: Table, val rootWidth: Double, val textZoom: Float,
            val expectedWidth: Float, val belowBlocker: Boolean, val expectedLeft: Float)
        val phases = listOf(
            Phase(main, 639.5, 1f, preferredWidth, false, 180f - 6f - preferredWidth),
            Phase(main, 639.0, 2f, preferredWidth, true, 4f),
            Phase(noOverride, 639.0, 2f, preferredWidth, false, 54f),
            Phase(overLtr, 639.0, 2f, 230f, true, 4f),
            Phase(overRtl, 639.0, 2f, 230f, true, -56f),
            Phase(overRtl, 639.5, 2f, 230f, true, -56f),
        )
        withScene({
            CompositionLocalProvider(LocalCssPixelTextZoom provides zoom.value) {
                val body = Block("container", 0, emptyList(), container = Container(listOf(block(blocker),
                    block(selected.value), Block("paragraph", 0, listOf(Span("text", "Basis")))), inherited))
                Scene(listOf(body), viewport.value, width = 180, fontScale = 1.25f, onLink = { opened += it })
            }
        }) {
            for ((index, phase) in phases.withIndex()) {
                compose.runOnIdle { selected.value = phase.value; viewport.value = phase.rootWidth; zoom.value = phase.textZoom }
                compose.waitForIdle(); assertReady()
                val container = bounds(parent()); val actual = bounds(grid(targetPath))
                val priorFloat = bounds(grid(blockerPath)); val actualCell = bounds(gridCell(0, targetPath))
                assertEquals(50f, priorFloat.width, .01f)
                assertTrue("The real earlier float must remain tall enough to distinguish clearance", priorFloat.height >= 50f)
                assertEquals(phase.expectedWidth, actual.width, .01f)
                assertEquals(phase.expectedLeft, actual.left - container.left, .01f)
                assertEquals(if (phase.belowBlocker) priorFloat.bottom else container.top, actual.top, .01f)
                assertEquals(actual.left, actualCell.left, .01f); assertEquals(actual.width, actualCell.width, .01f)
                val root = compose.onRoot().fetchSemanticsNode()
                val windowOrigin = root.positionOnScreen - root.boundsInRoot.topLeft
                val inspected = compose.runOnIdle {
                    assertEquals(.5f, inherited.ownerFontScale!!, 0f)
                    assertEquals("Inherited text uses its half-size nominal 10sp source font", inheritedPixels, inspect("Basis").layout.paint.textSize, .01f)
                    val owned = inspect("P")
                    val source = owned.native.text as android.text.Spanned
                    val paint = TextPaint(owned.layout.paint).also { value ->
                        source.getSpans(0, 1, android.text.style.MetricAffectingSpan::class.java)
                            .filter { source.getSpanStart(it) <= 0 && source.getSpanEnd(it) > 0 }
                            .forEach { it.updateMeasureState(value) }
                    }
                    assertEquals("CSS text zoom changes the explicit glyph, not the table em width",
                        with(fixtureDensity) { (10f * phase.textZoom).sp.toPx() }, paint.textSize, .01f)
                    assertSame(main.rows, phase.value.rows); assertSame(action, phase.value.rows.single().single().spans.single())
                    assertEquals(TableFloatSide.Right, phase.value.style!!.floatSide)
                    assertEquals(FigureClear.Right, phase.value.style!!.clear)
                    owned
                }
                if (phase.expectedWidth > container.width) {
                    val outside = if (phase.expectedLeft < 0f) container.left - 8f else container.right + 8f
                    val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
                    try {
                        val x = floor(outside - root.boundsInRoot.left).toInt()
                        val y = floor(actual.bottom - 2f - root.boundsInRoot.top).toInt()
                        assertTrue(x in 0 until bitmap.width && y in 0 until bitmap.height)
                        assertEquals("Signed preferred-width overflow keeps actual cell paint", 0xffe40000.toInt(), bitmap.getPixel(x, y))
                    } finally { bitmap.recycle() }
                }
                val point = compose.runOnIdle { nativeActionPoint(inspected, "P", windowOrigin + actualCell.topLeft,
                    diagnosticMethod = "prefixPreferredWidthUsesNormalBodyWhileNarrowClearRetainsTheActualGridAndActions") }
                tapScreen(point)
                compose.runOnIdle { assertEquals(List(index + 1) { EntryLink("PrefixTarget", "part") }, opened) }
            }
        }
    }
}
