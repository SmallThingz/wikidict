package app.smallthingz.dict

import android.graphics.RectF
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.findRootCoordinates
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.toSize
import androidx.compose.ui.viewinterop.AndroidView
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Source-only controls through the actual caption/table/figure/native View owners. */
class TableBlockViewportCaptionDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private val auto = ContainerMargins(ContainerMargin.Length(px(0f)), ContainerMargin.Auto,
        ContainerMargin.Length(px(0f)), ContainerMargin.Auto)
    private val textStyle = TextStyle(fontSize = 16.sp, lineHeight = 20.sp, fontFamily = FontFamily.Monospace)
    private val captionText = "CAPTION_MINIMUM_EXCEEDS_THREE_HUNDRED_PIXELS"
    private fun sourceStyle(parent: TableContainingDirection, decorated: Boolean = false) = TableStyle(
        background = "#0000ff", border = if (decorated) StyleBorder.Solid(px(2f), "#00ff00") else StyleBorder.None,
        width = StyleWidth(StyleWidthUnit.Percent, 70f),
        padding = if (decorated) StyleEdges(px(4f), px(4f), px(4f), px(4f)) else zero,
        marginValues = auto, containingDirection = parent)
    private fun policy(parent: TableContainingDirection, grid: TableContainingDirection,
        decorated: Boolean = false) = TableBlockViewport(639L, sourceStyle(parent, decorated),
        ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
        TableStyle(collapse = TableCollapse.Collapse), grid, language = "ru")
    private fun table(parent: TableContainingDirection = TableContainingDirection.Ltr,
        grid: TableContainingDirection = TableContainingDirection.Ltr, decorated: Boolean = false,
        minimum: Float = 100f) = Table(listOf(Span("link", captionText, "caption")), listOf(listOf(
            Cell(listOf(Span("link", "FIRST", "first")), false, 1, 1, background = "#ff0000",
                style = CellStyle(border = StyleBorder.None, padding = zero, minWidth = px(minimum))),
            Cell(listOf(Span("text", "MIDDLE")), false, 1, 1, background = "#ff0000",
                style = CellStyle(border = StyleBorder.None, padding = zero, minWidth = px(minimum))),
            Cell(listOf(Span("link", "LAST", "last")), false, 1, 1, background = "#ff0000",
                style = CellStyle(border = StyleBorder.None, padding = zero, minWidth = px(minimum))))),
        style = sourceStyle(parent, decorated).copy(collapse = TableCollapse.Collapse),
        blockViewport = policy(parent, grid, decorated))
    private fun figure(table: Table, width: Int) = Figure(
        FigureContent.Missing(Span("text", "media"), px(width.toFloat()), px(20f)),
        FigureFormat.Framed, FigurePlacement.None, FigureClear.None, zero, zero, zero,
        1f, px(20f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
        FigureColor.NativeTheme, FigureColor.Transparent,
        captionBlocks = listOf(Block("table", 0, emptyList(), table = table)))
    private fun nativeView(): NativeFloatTextView {
        val views = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: View) {
                if (view is NativeFloatTextView && view.currentMeasuredGeometry?.text?.contains(captionText) == true) views += view
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(activity.window.decorView)
        }
        return views.single()
    }
    private fun noWarning() {
        compose.onAllNodesWithText("Table block layout unavailable.", substring = true).assertCountEquals(0)
        compose.onAllNodesWithText("Table margin layout unavailable.", substring = true).assertCountEquals(0)
    }
    private fun node(geometry: FloatTextGeometry, label: String) = geometry.nodes.single {
        it.onClick != null && geometry.text.subSequence(it.start, it.end).toString() == label
    }

    @Test fun captionMinimumGrowsAnonymousGridWhileSourceViewportEdgesAnd639640SelectionStayIndependent() {
        val viewport = mutableStateOf(639)
        var observed: FloatTextGeometry? = null
        val source = table(TableContainingDirection.Rtl, TableContainingDirection.Ltr, decorated = true)
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false), "", {}, Any())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val actual = LocalWindowInfo.current
                val window = object : WindowInfo by actual { override val containerSize = IntSize(viewport.value, 1000) }
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalWindowInfo provides window) {
                    Layout(modifier = Modifier.testTag("caption-responsive-owner"), content = {
                        FigureCaptionBlocks(listOf(Block("table", 0, emptyList(), table = source)),
                            AnonymousFlowContext(BidiResolvedDirection.Rtl, null, null), textStyle, reader,
                            { observed = it }, gapDp = 0f)
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(200))
                        layout(200, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle(); noWarning()
            var original = ""
            var contentClip = RectF()
            var bodyY = 0
            compose.runOnIdle {
                val geometry = checkNotNull(observed)
                original = geometry.text.toString()
                assertEquals(200, geometry.width)
                assertEquals(1, original.split(captionText).size - 1)
                val heading = node(geometry, captionText)
                val first = node(geometry, "FIRST")
                val last = node(geometry, "LAST")
                contentClip = checkNotNull(first.clipBounds)
                assertEquals(30f, contentClip.left, .01f)
                assertEquals(140f, contentClip.width(), .01f)
                assertTrue(kotlin.math.abs(geometry.caretRect(heading.end).left - geometry.caretRect(heading.start).left) > 300f)
                assertTrue(first.bounds.isNotEmpty())
                assertTrue(last.bounds.isEmpty())
                assertTrue(geometry.characterRects(last.start, last.end - last.start).all { it == null })
                assertTrue(geometry.rectsForRange(0, geometry.text.length).all { contentClip.contains(it) })
                assertNotNull(geometry.horizontalScrollTargetAt(contentClip.centerX(), contentClip.centerY()))
                bodyY = (contentClip.bottom - 2f).toInt()
            }
            val pixels = compose.onNodeWithTag("caption-responsive-owner").captureToImage().asAndroidBitmap()
            try {
                assertEquals(0xff00ff00.toInt(), pixels.getPixel(25, bodyY))
                assertEquals(0xff0000ff.toInt(), pixels.getPixel(28, bodyY))
                assertEquals(0xffff0000.toInt(), pixels.getPixel(31, bodyY))
                assertNotEquals(0xffff0000.toInt(), pixels.getPixel(175, bodyY))
            } finally { pixels.recycle() }
            compose.runOnIdle { viewport.value = 640 }
            compose.waitForIdle(); noWarning()
            compose.runOnIdle {
                val geometry = checkNotNull(observed)
                assertEquals(original, geometry.text.toString())
                assertNull(node(geometry, "LAST").clipBounds)
                assertTrue(node(geometry, "LAST").bounds.isNotEmpty())
                assertTrue(geometry.extents.ink!!.left < 0f)
                assertNull(geometry.horizontalScrollTargetAt(100f, bodyY.toFloat()))
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun actualNativeCaptionOwnerRevealsHiddenActionsByKeyboardAccessibilityAndRoutesHorizontalDrag() {
        val clicked = mutableListOf<String>()
        val source = table(TableContainingDirection.Ltr, TableContainingDirection.Rtl)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val actual = LocalWindowInfo.current
                val window = object : WindowInfo by actual { override val containerSize = IntSize(639, 1000) }
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalWindowInfo provides window) {
                    Layout(content = {
                        AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = figure(source, 200)),
                            Modifier.testTag("caption-native-owner"), { clicked += it.target }, emptyList(),
                            AppSettings(allowImages = false, allowAudio = false), "", style = textStyle)
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(200))
                        layout(200, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle(); noWarning()
            val view = nativeView()
            var originalText = ""
            var lastId = -1
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                originalText = geometry.text.toString()
                val last = node(geometry, "LAST")
                lastId = last.id
                assertTrue(last.bounds.isEmpty())
                assertFalse(checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(lastId)).isVisibleToUser)
                assertTrue(view.requestFocus())
            }
            repeat(3) {
                compose.runOnIdle {
                    assertTrue(view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB)))
                    view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                }
                compose.waitForIdle()
            }
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                assertEquals(originalText, geometry.text.toString())
                assertEquals(lastId, node(geometry, "LAST").id)
                assertTrue(node(geometry, "LAST").bounds.isNotEmpty())
                assertTrue(checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(lastId)).isVisibleToUser)
                assertTrue(clicked.isEmpty())
            }
            // In RTL, moving the finger left returns toward the initial physical right edge.
            repeat(4) {
                var down = 0L
                var x = 0f
                var y = 0f
                compose.runOnIdle {
                    val bounds = checkNotNull(node(checkNotNull(view.currentMeasuredGeometry), "FIRST").clipBounds)
                    down = SystemClock.uptimeMillis(); x = bounds.right - 8f; y = bounds.centerY()
                    val start = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0)
                    val move = MotionEvent.obtain(down, down + 100, MotionEvent.ACTION_MOVE, bounds.left + 8f, y, 0)
                    try { assertTrue(view.dispatchTouchEvent(start)); assertTrue(view.dispatchTouchEvent(move)) }
                    finally { start.recycle(); move.recycle() }
                }
                compose.waitForIdle()
                compose.runOnIdle {
                    val cancel = MotionEvent.obtain(down, down + 200, MotionEvent.ACTION_CANCEL, x, y, 0)
                    try { view.dispatchTouchEvent(cancel) } finally { cancel.recycle() }
                }
                compose.waitForIdle()
            }
            assertSame(view, nativeView())
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                assertTrue(node(geometry, "FIRST").bounds.isNotEmpty())
                assertTrue(node(geometry, "LAST").bounds.isEmpty())
                assertTrue(clicked.isEmpty())
                assertTrue(view.accessibilityNodeProvider.performAction(lastId, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
            }
            compose.waitForIdle(); noWarning()
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val last = node(geometry, "LAST")
                assertTrue(last.bounds.isNotEmpty())
                assertTrue(checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(lastId)).isVisibleToUser)
                val b = last.bounds.first(); val now = SystemClock.uptimeMillis()
                val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, b.centerX(), b.centerY(), 0)
                val up = MotionEvent.obtain(now, now + 10, MotionEvent.ACTION_UP, b.centerX(), b.centerY(), 0)
                try { assertTrue(view.dispatchTouchEvent(down)); assertTrue(view.dispatchTouchEvent(up)) }
                finally { down.recycle(); up.recycle() }
                assertEquals(listOf("last"), clicked)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun nestedViewportRevealWaitsForBothRealPlacementsAndRetainsOneCaptionGraph() {
        val inner = table(minimum = 300f)
        val outer = Table(listOf(Span("text", "OUTER")), listOf(listOf(
            Cell(emptyList(), false, 1, 1, blocks = listOf(Block("table", 0, emptyList(), table = inner)),
                style = CellStyle(border = StyleBorder.None, padding = zero, minWidth = px(400f))))),
            style = sourceStyle(TableContainingDirection.Ltr),
            blockViewport = policy(TableContainingDirection.Ltr, TableContainingDirection.Ltr))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val actual = LocalWindowInfo.current
                val window = object : WindowInfo by actual { override val containerSize = IntSize(639, 1000) }
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalWindowInfo provides window) {
                    Layout(content = {
                        AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = figure(outer, 200)),
                            Modifier, {}, emptyList(), AppSettings(allowImages = false, allowAudio = false), "", style = textStyle)
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(200))
                        layout(200, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle(); noWarning()
            val view = nativeView()
            var before = ""
            var id = -1
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                before = geometry.text.toString()
                val target = node(geometry, "LAST")
                id = target.id
                assertTrue(target.bounds.isEmpty())
                assertTrue(view.accessibilityNodeProvider.performAction(id, AccessibilityNodeInfo.ACTION_FOCUS, null))
            }
            compose.waitForIdle(); noWarning()
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                assertEquals(before, geometry.text.toString())
                assertEquals(1, before.split(captionText).size - 1)
                val target = node(geometry, "LAST")
                assertEquals(id, target.id)
                assertTrue(target.bounds.isNotEmpty())
                assertTrue(target.bounds.all { checkNotNull(target.clipBounds).contains(it) })
                assertTrue(checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(id)).isVisibleToUser)
                assertEquals(id, geometry.interactionNodeAt(target.bounds.first().centerX(), target.bounds.first().centerY())?.id)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun captionOnlyTableRetainsItsRealCaptionWithoutInventingAnAnonymousGrid() {
        var observed: FloatTextGeometry? = null
        val source = table().copy(rows = emptyList())
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false), "", {}, Any())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val actual = LocalWindowInfo.current
                val window = object : WindowInfo by actual { override val containerSize = IntSize(639, 1000) }
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalWindowInfo provides window) {
                    Layout(content = {
                        FigureCaptionBlocks(listOf(Block("table", 0, emptyList(), table = source)),
                            AnonymousFlowContext(BidiResolvedDirection.Ltr, null, null), textStyle, reader,
                            { observed = it }, gapDp = 0f)
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(200))
                        layout(200, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle(); noWarning()
            compose.runOnIdle {
                val geometry = checkNotNull(observed)
                assertEquals(captionText, geometry.text.toString())
                val link = node(geometry, captionText)
                val clip = checkNotNull(link.clipBounds)
                assertEquals(140f, clip.width(), .01f)
                assertEquals(30f, clip.left, .01f)
                assertEquals(1, geometry.nodes.count { it.onClick != null })
                assertTrue(link.bounds.isNotEmpty())
                assertNotNull(geometry.horizontalScrollTargetAt(clip.centerX(), clip.centerY()))
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun unsupportedOwnerLanguageRetainsNativeCaptionActionsInBothStatesAndRecoversToRu() {
        val viewport = mutableStateOf(639)
        val language = mutableStateOf("not a native locale")
        val captionOnly = mutableStateOf(false)
        val clicked = mutableListOf<String>()
        var observedFlow: NativeAnonymousFlowGeometry? = null
        val original = table()
        var diagnosticPhase = "before_composition"
        var diagnosticSequence = 0
        var firstFailure: Throwable? = null
        fun recordDiagnostic(kind: String, failure: Throwable? = null) {
            // Preserve a first cause before Compose/Activity cleanup can obscure it.
            try {
                val errorClass = failure?.javaClass?.name.orEmpty()
                val message = failure?.message.orEmpty()
                val stack = failure?.stackTraceToString().orEmpty()
                val record = org.json.JSONObject()
                    .put("version", 1)
                    .put("method", "app.smallthingz.dict.TableBlockViewportCaptionDeviceTest#unsupportedOwnerLanguageRetainsNativeCaptionActionsInBothStatesAndRecoversToRu")
                    .put("sequence", ++diagnosticSequence)
                    .put("kind", kind).put("phase", diagnosticPhase)
                if (failure != null) record
                    .put("exception_class", errorClass.take(256))
                    .put("message", message.take(512)).put("stack", stack.take(4096))
                    .put("truncated", errorClass.length > 256 || message.length > 512 || stack.length > 4096)
                val line = "OWNED_METHOD_DIAGNOSTIC " + record.toString()
                check(diagnosticSequence <= 32 && line.toByteArray(Charsets.UTF_8).size <= 32768)
                androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().sendStatus(
                    0, Bundle().apply { putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$line\n") })
            } catch (observationFailure: Throwable) {
                // Diagnostic transport cannot replace the tested outcome.
                if (failure != null && observationFailure !== failure) failure.addSuppressed(observationFailure)
            }
        }
        fun phase(value: String) { diagnosticPhase = value; recordDiagnostic("phase") }
        fun assertNativeWarning(expected: Int) {
            // The child paints once below the semantics barrier; the native owner publishes AX.
            val painted = compose.onAllNodesWithText(NativeTableLanguageUnavailable,
                substring = true, useUnmergedTree = true).fetchSemanticsNodes()
            assertEquals(expected, painted.size)
            val paintedWarning = painted.singleOrNull()
            // Full measured geometry and root-clipped semantics are distinct coordinate domains.
            val paintBounds = paintedWarning?.let { Rect(it.positionInWindow, it.size.toSize()) }
            val rootBounds = paintedWarning?.layoutInfo?.coordinates?.findRootCoordinates()?.let {
                Rect(it.positionInWindow(), it.size.toSize())
            }
            val clippedPaintBounds = paintedWarning?.boundsInWindow
            val owner = nativeView()
            compose.runOnIdle {
                val geometry = checkNotNull(owner.currentMeasuredGeometry)
                assertFalse(geometry.text.contains(NativeTableLanguageUnavailable))
                val warnings = geometry.nodes.filter { it.label?.toString() == NativeTableLanguageUnavailable }
                assertEquals(expected, warnings.size)
                val infos = checkNotNull(owner.accessibilityNodeProvider.findAccessibilityNodeInfosByText(
                    NativeTableLanguageUnavailable, View.NO_ID))
                assertEquals(expected, infos.size)
                if (expected == 1) {
                    val warning = warnings.single()
                    assertEquals(warning.start, warning.end)
                    assertNull(warning.onClick)
                    assertNull(warning.onLongClick)
                    val bounds = warning.bounds.single()
                    assertFalse(bounds.isEmpty)
                    val location = IntArray(2); owner.getLocationInWindow(location)
                    val paintedBounds = checkNotNull(paintBounds)
                    assertEquals(paintedBounds.left, bounds.left + location[0] + owner.paddingLeft, .01f)
                    assertEquals(paintedBounds.top, bounds.top + location[1] + owner.paddingTop, .01f)
                    assertEquals(paintedBounds.right, bounds.right + location[0] + owner.paddingLeft, .01f)
                    assertEquals(paintedBounds.bottom, bounds.bottom + location[1] + owner.paddingTop, .01f)
                    // Match the public semantics projection; this does not infer a pixel clip.
                    val projectedBounds = Rect(bounds.left + location[0] + owner.paddingLeft,
                        bounds.top + location[1] + owner.paddingTop,
                        bounds.right + location[0] + owner.paddingLeft,
                        bounds.bottom + location[1] + owner.paddingTop).intersect(checkNotNull(rootBounds))
                    val clippedBounds = checkNotNull(clippedPaintBounds)
                    assertFalse(projectedBounds.isEmpty)
                    assertFalse(clippedBounds.isEmpty)
                    assertEquals(clippedBounds.left, projectedBounds.left, .01f)
                    assertEquals(clippedBounds.top, projectedBounds.top, .01f)
                    assertEquals(clippedBounds.right, projectedBounds.right, .01f)
                    assertEquals(clippedBounds.bottom, projectedBounds.bottom, .01f)
                    val info = infos.single()
                    assertEquals(NativeTableLanguageUnavailable, info.text.toString())
                    assertTrue(info.isVisibleToUser)
                    assertFalse(info.isClickable)
                    assertFalse(info.isLongClickable)
                    assertTrue(info.actionList.none { it.id == AccessibilityNodeInfo.ACTION_CLICK ||
                        it.id == AccessibilityNodeInfo.ACTION_LONG_CLICK })
                    val expectedBounds = android.graphics.Rect()
                    bounds.roundOut(expectedBounds); expectedBounds.offset(owner.paddingLeft, owner.paddingTop)
                    val actualBounds = android.graphics.Rect(); info.getBoundsInParent(actualBounds)
                    assertEquals(expectedBounds, actualBounds)
                }
            }
        }
        fun retainStateFrame(name: String, phase: String) {
            val viewportNode = compose.onNodeWithTag("responsive-native-language-owner")
            val semantics = viewportNode.printToString(maxDepth = 8).take(12000)
            var native = ""
            val view = nativeView()
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                native = "body=${geometry.text}; nodes=" + geometry.nodes.joinToString { target ->
                    val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(target.id))
                    "id=${target.id}, text=${info.text}, clickable=${info.isClickable}, bounds=${target.bounds}"
                }
            }
            val report = renderedLayoutFailureEvidence("responsive-native-language-$phase", null,
                viewportNode.fetchSemanticsNode(), viewportNode, name) +
                "\nphase=$phase; documentViewportCss=${viewport.value}; clicked=$clicked\n$native\n$semantics"
            check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().sendStatus(
                0, Bundle().apply { putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n") })
            check("OWNED_PNG_BEGIN $name " in report)
        }
        val none = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None,
            FigureBorderEdge.None, FigureBorderEdge.None)
        val captionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), none, none,
            FigureMediaLayout(FigureMediaStrut(0f, direction = BidiResolvedDirection.Ltr), InlineBoxVerticalAlign.Baseline))
        try {
            phase("before_composition")
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val actual = LocalWindowInfo.current
                val window = object : WindowInfo by actual { override val containerSize = IntSize(viewport.value, 1000) }
                val source = original.copy(rows = if (captionOnly.value) emptyList() else original.rows,
                    blockViewport = original.blockViewport!!.copy(language = language.value))
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalWindowInfo provides window) {
                    Layout(modifier = Modifier.testTag("responsive-native-language-owner"), content = {
                        // This existing Figure shape queries its real caption minimum before measure.
                        AnonymousBlockView(Block("paragraph", 0, emptyList(),
                            figure = figure(source, 200).copy(tableCaptionLayout = captionLayout)),
                            Modifier, { clicked += it.target }, emptyList(),
                            AppSettings(allowImages = false, allowAudio = false), "", style = textStyle,
                            onFlowGeometry = { observedFlow = it })
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(200))
                        layout(200, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            for (width in listOf(639, 640)) {
                phase("unsupported_${width}_update")
                compose.runOnIdle { viewport.value = width }
                compose.waitForIdle()
                phase("unsupported_${width}_warning")
                assertNativeWarning(1)
                compose.onAllNodesWithTag("compiled-table-block-content", useUnmergedTree = true).assertCountEquals(0)
                phase("unsupported_${width}_body_actions")
                val view = nativeView()
                compose.runOnIdle {
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    for (literal in listOf(captionText, "FIRST", "MIDDLE", "LAST"))
                        assertEquals(literal, 1, geometry.text.toString().split(literal).size - 1)
                    val first = node(geometry, "FIRST")
                    val last = node(geometry, "LAST")
                    assertEquals(3, geometry.nodes.count { it.onClick != null })
                    assertTrue(first.bounds.isNotEmpty())
                    assertTrue(last.bounds.isNotEmpty())
                    assertTrue(geometry.nodes.all { it.clipBounds == null })
                    assertNull(geometry.horizontalScrollTargetAt(first.bounds.first().centerX(), first.bounds.first().centerY()))
                    assertTrue(geometry.characterRects(first.start, first.end - first.start).any { it != null })
                    val selection = Bundle().apply {
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, first.start)
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, last.end)
                    }
                    assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
                    assertEquals(first.start, view.selectionStart)
                    assertEquals(last.end, view.selectionEnd)
                    assertTrue(geometry.rectsForRange(view.selectionStart, view.selectionEnd).isNotEmpty())
                    for (target in listOf(first, last)) {
                        val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(target.id))
                        assertTrue(info.isClickable)
                        assertEquals(geometry.text.subSequence(target.start, target.end).toString(), info.text.toString())
                    }
                    assertTrue(view.accessibilityNodeProvider.performAction(first.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                    selection.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, -1)
                    selection.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, -1)
                    assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
                }
            }
            phase("warning_frame")
            retainStateFrame("responsive-native-language-warning.png", "warning")
            phase("ru_recovery")
            compose.runOnIdle { assertEquals(listOf("first", "first"), clicked); language.value = "ru" }
            for (width in listOf(639, 640)) {
                phase("supported_${width}_update")
                compose.runOnIdle { viewport.value = width }
                compose.waitForIdle()
                phase("supported_${width}_warning")
                noWarning()
                assertNativeWarning(0)
                compose.onAllNodesWithTag("compiled-table-block-content", useUnmergedTree = true)
                    .assertCountEquals(if (width == 639) 1 else 0)
                phase("supported_${width}_body_actions")
                val view = nativeView()
                compose.runOnIdle {
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    for (literal in listOf(captionText, "FIRST", "MIDDLE", "LAST"))
                        assertEquals(literal, 1, geometry.text.toString().split(literal).size - 1)
                    val first = node(geometry, "FIRST")
                    assertEquals(width == 639, first.clipBounds != null)
                    assertTrue(view.accessibilityNodeProvider.performAction(first.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                }
            }
            phase("recovered_frame")
            retainStateFrame("responsive-native-language-recovered.png", "recovered")
            phase("caption_only_update")
            compose.runOnIdle {
                assertEquals(List(4) { "first" }, clicked)
                language.value = "not a native locale"
                captionOnly.value = true
                viewport.value = 639
            }
            compose.waitForIdle()
            phase("caption_only_warning")
            assertNativeWarning(1)
            compose.onAllNodesWithTag("compiled-table-block-content", useUnmergedTree = true).assertCountEquals(0)
            compose.onNodeWithTag("compiled-table-grid-figure-caption", useUnmergedTree = true)
                .assertWidthIsEqualTo(0.dp).assertHeightIsEqualTo(0.dp)
            phase("caption_only_body_actions")
            val retainedView = nativeView()
            compose.runOnIdle {
                val exactFigure = checkNotNull(observedFlow).figures.single().measured.geometry
                assertEquals("media\n" + captionText, exactFigure.text.toString())
                val geometry = checkNotNull(retainedView.currentMeasuredGeometry)
                val caption = node(geometry, captionText)
                assertEquals(1, geometry.nodes.count { it.onClick != null })
                assertTrue(caption.bounds.isNotEmpty())
                assertTrue(geometry.rectsForRange(caption.start, caption.end).isNotEmpty())
                assertTrue(checkNotNull(retainedView.accessibilityNodeProvider.createAccessibilityNodeInfo(caption.id)).isClickable)
                assertTrue(retainedView.accessibilityNodeProvider.performAction(caption.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(List(4) { "first" } + "caption", clicked)
            }
            phase("method_complete")
        } catch (failure: Throwable) {
            firstFailure = failure
            recordDiagnostic("failure", failure)
            throw failure
        } finally {
            phase("cleanup_start")
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                phase("cleanup_complete")
            } catch (cleanupFailure: Throwable) {
                recordDiagnostic("cleanup_failure", cleanupFailure)
                val originalFailure = firstFailure
                if (originalFailure == null) throw cleanupFailure
                if (cleanupFailure !== originalFailure) originalFailure.addSuppressed(cleanupFailure)
            }
        }
    }

    @Test fun warningReindexClearsChangedFocusButGeometryOnlyReflowKeepsTheSameOwner() {
        val warning = mutableStateOf(true)
        val shift = mutableStateOf(20f)
        val clicked = mutableListOf<String>()
        val actions = listOf<() -> Unit>({ clicked += "A" }, { clicked += "B" }, { clicked += "C" })
        var actualView: NativeFloatTextView? = null
        fun letter(index: Int): FloatTextGeometry {
            val text = ('A' + index).toString()
            return NativeSemanticGroup(30, 20, listOf(PositionedSemanticChild(
                EmptyCaptionGeometry(30, text), 0f, 0f, BidiResolvedDirection.Ltr)),
                extraNodes = listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, 0, 1,
                    listOf(RectF(0f, 0f, 30f, 20f)), text, null, actions[index])))
        }
        fun graph(showWarning: Boolean, y: Float): FloatTextGeometry {
            val first = mutableListOf(PositionedSemanticChild(letter(0), 0f, y, BidiResolvedDirection.Ltr))
            if (showWarning) first += PositionedSemanticChild(NativeSemanticGroup(30, 10, emptyList(),
                extraNodes = listOf(FloatInteractionNode(0, FloatInteractionKind.MARKER, 0, 0,
                    listOf(RectF(0f, 0f, 30f, 10f)), NativeTableLanguageUnavailable, null, null))),
                0f, 0f, BidiResolvedDirection.Ltr)
            return NativeSemanticGroup(90, 60, listOf(
                PositionedSemanticChild(NativeSemanticGroup(30, 60, first), 0f, 0f, BidiResolvedDirection.Ltr),
                PositionedSemanticChild(letter(1), 30f, y, BidiResolvedDirection.Ltr),
                PositionedSemanticChild(letter(2), 60f, y, BidiResolvedDirection.Ltr)))
        }
        fun focusB(): Int {
            var id = -1
            compose.runOnIdle {
                val view = checkNotNull(actualView)
                val current = checkNotNull(view.currentMeasuredGeometry)
                assertEquals("ABC", current.text.toString())
                id = node(current, "B").id
                assertTrue(view.accessibilityNodeProvider.performAction(id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(view.accessibilityNodeProvider.performAction(id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
            }
            return id
        }
        fun assertCleared(oldId: Int, replacement: String) = compose.runOnIdle {
            val view = checkNotNull(actualView)
            val current = checkNotNull(view.currentMeasuredGeometry)
            assertEquals("ABC", current.text.toString())
            assertEquals(replacement, current.nodes.single { it.id == oldId }.label.toString())
            assertNull(view.accessibilityNodeProvider.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY))
            assertEquals("ABC", view.accessibilityNodeProvider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.text.toString())
            for (target in current.nodes) {
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(target.id))
                assertFalse(info.isFocused)
                assertFalse(info.isAccessibilityFocused)
            }
            view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
            assertTrue(clicked.isEmpty())
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val geometry = graph(warning.value, shift.value)
                Layout(content = {
                    AndroidView(factory = { NativeFloatTextView(it).also { actualView = it } },
                        update = { it.bind({ geometry }, 0, 0) })
                }) { children, _ ->
                    val child = children.single().measure(Constraints.fixed(90, 60))
                    layout(90, 60) { child.place(0, 0) }
                }
            } }
            compose.waitForIdle()
            val originalId = focusB()
            compose.runOnIdle { shift.value = 25f }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = checkNotNull(actualView)
                assertEquals(originalId, node(checkNotNull(view.currentMeasuredGeometry), "B").id)
                assertEquals("B", view.accessibilityNodeProvider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.text.toString())
                assertEquals("B", view.accessibilityNodeProvider.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)?.text.toString())
            }
            compose.runOnIdle { warning.value = false }
            compose.waitForIdle(); assertCleared(originalId, "C")
            val shiftedId = focusB()
            compose.runOnIdle { warning.value = true }
            compose.waitForIdle(); assertCleared(shiftedId, NativeTableLanguageUnavailable)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun zeroLengthHiddenActionWaitsForFreshBodyAndUsesItsMatchedLivePlacement() {
        val publication = NativeTableViewportPublication()
        var invalidations = 0
        var complete = false
        var oldReveal = false
        var revealed: RectF? = null
        publication.invalidate = { invalidations++ }
        val action: () -> Unit = {}
        fun body(bounds: List<RectF>) = NativeSemanticGroup(400, 20, emptyList(), extraNodes = listOf(
            FloatInteractionNode(0, FloatInteractionKind.IMAGE, 0, 0, bounds, "image", null, action)))
        fun placement(reveal: (RectF, () -> Unit) -> Unit) = NativeTableBlockPlacement(
            borderBox = RectF(0f, 0f, 100f, 20f), contentClip = RectF(0f, 0f, 100f, 20f),
            contentX = 0f, contentY = 0f, physicalScrollX = 0f,
            gridWidth = 400, gridHeight = 20, captionWidth = 0, captionHeight = 0,
            captionY = 0f, gridY = 0f, ownerWidth = 100, ownerHeight = 20, scrollTarget = null,
            revealContentRect = reveal)
        val geometry = NativeTableViewportGeometry(body(emptyList()), placement { _, done -> oldReveal = true; done() },
            publication::afterPublication)
        geometry.revealNode(0) { complete = true }
        assertEquals(1, invalidations)
        assertFalse(complete)
        assertFalse(oldReveal)
        publication.publish(body(listOf(RectF(300f, 0f, 320f, 20f))), placement { rect, done -> revealed = rect; done() })
        assertEquals(RectF(300f, 0f, 320f, 20f), revealed)
        assertTrue(complete)
        assertFalse(oldReveal)
        publication.close()
        publication.afterPublication { value, current -> assertNull(value); assertNull(current) }
    }
}
