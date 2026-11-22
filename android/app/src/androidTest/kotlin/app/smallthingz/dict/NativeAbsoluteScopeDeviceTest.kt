package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Rect
import android.graphics.RectF
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.referentialEqualityPolicy
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** SYNTHETIC constructor-policy controls. The local 310x157 PNG is not a captured EN rendition. */
class NativeAbsoluteScopeDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val names = listOf("sh\u00eengng\u00e2", "\u014dts\u012bp\u00edk", "sh\u00eengm\u00f9i", "\u014dts\u012bn\u00e1p")
    private val tops = listOf(3f, 60f, 150f, 70f)
    private val lefts = listOf(130f, 250f, 125f, 20f)
    private val image = InlineImage("Synthetic-absolute-control.png", widthPx = 310, alt = "Synthetic normal image")
    private val settings = AppSettings(allowImages = true, allowAudio = false, mediaCacheMb = 1,
        collapseOtherSections = false, collapseDetails = false)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun zero() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private fun box(value: Container) = Block("container", 0, emptyList(), container = value)
    private fun paragraph(spans: List<Span>) = Block("paragraph", 0, spans,
        style = BlockStyle(margins = zero()))
    private fun label(index: Int, top: Float = tops[index], left: Float = lefts[index],
        text: String = names[index], color: String = "#000000") = box(Container(listOf(paragraph(listOf(
            Span("link", text, names[index], language = "kix", targetFragment = "Khiamniungan_Naga", foreground = color,
                fontScale = 12f, fontScaleBasis = FontScaleBasis.CssPx)))),
        ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)), height = px(0f),
            textAlign = CellTextAlign.Left, positioning = ContainerPositioning.Absolute(px(top), px(left),
                InlineFontSnapshot(12f, FontScaleBasis.CssPx, language = "en"),
                InlineComputedLength(12f, FontScaleBasis.CssPx), TextWrap.NoWrap))))
    private fun scope(labels: List<Block> = names.indices.map { label(it) }, width: Float? = null): Container = Container(
        listOf(paragraph(listOf(Span("text", "", image = image)))) + labels,
        ContainerStyle(width = width?.let { ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, it)) },
            margins = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Em, .3f), px(0f),
                SignedContainerMargin(StyleLengthUnit.Px, -25f), px(0f)),
            padding = StyleEdges(px(0f), px(0f), px(25f), px(0f)), textAlign = CellTextAlign.Left,
            positioning = ContainerPositioning.RelativeAuto,
            positionedScope = PositionedScope(TextWrap.NoWrap, PositionedOverflowX.Scroll, PositionedOverflowY.Auto,
                listOf(PositionedViewportState(900, PositionedOverflowX.Hidden, PositionedOverflowY.Auto)))))
    private fun entry(source: Container, ancestors: Boolean = false): Entry {
        val body = if (!ancestors) box(source) else {
            val inner = Container(listOf(box(source)), ContainerStyle(overflow = ContainerOverflow.Auto,
                maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 240f))))
            val carrier = Container(listOf(box(inner)), ContainerStyle(
                width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 400f))))
            box(Container(listOf(box(carrier)), ContainerStyle(overflow = ContainerOverflow.Auto,
                maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 160f)))))
        }
        return Entry("Absolute constructor control", emptyList(), "language", "English", "en",
            listOf(Section(0, "", listOf(body, paragraph(listOf(Span("link", "tail", "after-scope")))))),
            emptyList(), media = listOf(Media(image.file, "image", "")), bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
    }
    private class Seen {
        val actions = mutableListOf<EntryLink>()
        val failures = mutableListOf<String>()
    }
    @Composable private fun Scene(value: Entry, cache: MediaCache, seen: Seen, viewport: Double, width: Int,
        direction: LayoutDirection = LayoutDirection.Ltr) {
        val reading = remember { EntryReadingState() }
        CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides direction,
            LocalTableDocumentViewportCssWidth provides viewport, LocalInlineImageCache provides cache,
            LocalNativeFloatContextFailureObserver provides { seen.failures += it }) {
            DictTheme("light") {
                MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                    fontFamily = FontFamily.Monospace, letterSpacing = 0.sp))) {
                    Box(Modifier.size(width.dp, 560.dp).background(Color.White).testTag("absolute-root")) {
                        EntryView(value, false, {}, onLink = { seen.actions += it }, settings = settings,
                            readingState = reading)
                    }
                }
            }
        }
    }
    private fun withScene(name: String, content: @Composable (MediaCache) -> Unit, assertions: () -> Unit) {
        val directory = File(compose.activity.cacheDir, "absolute-control-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val bitmap = Bitmap.createBitmap(310, 157, Bitmap.Config.ARGB_8888)
        val png = try {
            bitmap.eraseColor(android.graphics.Color.BLUE)
            ByteArrayOutputStream().use { output -> check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)); output.toByteArray() }
        } finally { bitmap.recycle() }
        val url = "https://example.test/synthetic-absolute-control.png"
        val cache = MediaCache(compose.activity, directory = directory, metadata = {
            """{"query":{"pages":[{"imageinfo":[{"url":"$url","width":310,"height":157,"mime":"image/png"}]}]}}""".encodeToByteArray()
        }, openMedia = { requested -> check(requested == url); ByteArrayInputStream(png) })
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { it.setContent { content(cache) } }
            compose.waitForIdle(); assertions()
        } catch (failure: Throwable) {
            primary = failure
            runCatching {
                val root = compose.onNodeWithTag("absolute-root")
                val report = renderedLayoutFailureEvidence(name, null, null, root, name, root.captureToImage().asAndroidBitmap())
                InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
            }
            throw failure
        } finally {
            var cleanupFailure: Throwable? = null
            fun cleanup(action: () -> Unit) {
                try { action() } catch (failure: Throwable) {
                    val previous = cleanupFailure
                    if (previous == null) cleanupFailure = failure
                    else if (previous !== failure) previous.addSuppressed(failure)
                }
            }
            cleanup {
                compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            }
            cleanup { check(directory.deleteRecursively()) }
            cleanupFailure?.let { failure ->
                val original = primary
                if (original == null) throw failure
                if (original !== failure) original.addSuppressed(failure)
            }
        }
    }
    private fun <T> ui(read: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return read()
        var result: Result<T>? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { result = runCatching(read) }
        return checkNotNull(result).getOrThrow()
    }
    private fun allViews(): List<View> = ui {
        val result = mutableListOf<View>()
        fun collect(view: View) {
            result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { collect(view.getChildAt(it)) }
        }
        collect(compose.activity.window.decorView)
        result
    }
    private fun views(): List<NativeFloatTextView> = allViews().filterIsInstance<NativeFloatTextView>()
    private fun rootView() = ui { views().single { it.logicalText.toString().contains("tail") && '\ufffc' in it.logicalText } }
    private fun geometry(view: NativeFloatTextView): FloatTextGeometry {
        check(Looper.myLooper() == Looper.getMainLooper())
        return checkNotNull(view.currentMeasuredGeometry)
    }
    private fun nodes(view: NativeFloatTextView) = ui { geometry(view).nodes.toList() }
    private fun node(view: NativeFloatTextView, label: String) = ui { geometry(view).nodes.single {
        it.kind == FloatInteractionKind.LINK && it.label == label
    } }
    private fun viewport() = compose.onNodeWithTag("compiled-positioned-scrollport", useUnmergedTree = true)
    private fun windowBox(owner: SemanticsNodeInteraction): RectF {
        val semantic = owner.fetchSemanticsNode(); val at = semantic.positionInWindow
        return RectF(at.x, at.y, at.x + semantic.size.width, at.y + semantic.size.height)
    }
    private fun nativeWindow(view: NativeFloatTextView): Pair<Float, Float> = ui {
        val at = IntArray(2); view.getLocationInWindow(at)
        at[0] + view.paddingLeft.toFloat() to at[1] + view.paddingTop.toFloat()
    }
    private fun caretWindow(view: NativeFloatTextView, index: Int): RectF = ui {
        val (x, y) = nativeWindow(view)
        RectF(geometry(view).caretRect(index)).apply { offset(x, y) }
    }
    private fun imageCaret(view: NativeFloatTextView) = ui { caretWindow(view, view.logicalText.indexOf('\ufffc')) }
    private fun ready(seen: Seen, labelCount: Int) {
        compose.waitUntil(5000) {
            ui { views().any { view -> val g = view.currentMeasuredGeometry
                g != null && g.nodes.any { it.kind == FloatInteractionKind.IMAGE && it.stateDescription.isNullOrEmpty() } &&
                    g.nodes.count { it.kind == FloatInteractionKind.LINK && it.label != "tail" } == labelCount } }
        }
        compose.waitForIdle()
        // The real Entry loader may publish its retained Loading fallback before Ready.
        // Qualify the current Ready body without erasing that observation history.
        compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true,
            useUnmergedTree = true).assertCountEquals(0)
        compose.onAllNodesWithText("Unable to display this layout.", useUnmergedTree = true).assertCountEquals(0)
    }
    private fun clearSelection(view: NativeFloatTextView) {
        assertTrue(view.accessibilityNodeProvider.performAction(View.NO_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
    }
    private fun inventory(view: NativeFloatTextView, expected: List<String> = names, tail: Boolean = true) {
        val expectedText = "\ufffc" + expected.joinToString("", prefix = "") { "\n$it" } + if (tail) "\ntail" else ""
        assertEquals(expectedText, view.logicalText.toString())
        expected.forEachIndexed { index, label ->
            val item = geometry(view).nodes.filter { it.kind == FloatInteractionKind.LINK && it.label != "tail" }[index]
            assertEquals(label, item.label)
            assertEquals(label, view.logicalText.subSequence(item.start, item.end).toString())
            view.setSelection(item.start, item.end); assertEquals(label, view.selectedTextForCopy())
            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(item.id))
            try { assertEquals(label, info.text.toString()); assertTrue(info.isClickable) } finally { info.recycle() }
        }
        view.setSelection(0, view.logicalText.length); assertEquals(expectedText, view.selectedTextForCopy()); clearSelection(view)
    }
    private fun inputGuard() { assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus()) }
    private fun drag(view: NativeFloatTextView, window: RectF, distance: Float) {
        compose.runOnIdle {
            inputGuard(); val (ox, oy) = nativeWindow(view)
            val x = window.centerX() - ox + view.paddingLeft; val y = window.centerY() - oy + view.paddingTop
            val now = SystemClock.uptimeMillis()
            for ((time, action, dx) in listOf(Triple(0L, MotionEvent.ACTION_DOWN, 0f),
                Triple(20L, MotionEvent.ACTION_MOVE, -distance), Triple(21L, MotionEvent.ACTION_CANCEL, -distance))) {
                val event = MotionEvent.obtain(now, now + time, action, x + dx, y, 0)
                try { view.dispatchTouchEvent(event) } finally { event.recycle() }
            }
        }
        compose.waitForIdle()
    }
    private fun focus(view: NativeFloatTextView, label: String) {
        compose.runOnIdle {
            inputGuard()
            assertTrue(view.accessibilityNodeProvider.performAction(node(view, label).id, AccessibilityNodeInfo.ACTION_FOCUS, null))
        }
        compose.waitForIdle()
        compose.waitUntil(5000) { ui { node(view, label).bounds.any { !it.isEmpty } } }
    }
    private fun click(view: NativeFloatTextView, label: String) {
        compose.runOnIdle {
            inputGuard(); val bounds = node(view, label).bounds.first { !it.isEmpty }; val now = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(now, now + if (action == MotionEvent.ACTION_UP) 1 else 0,
                    action, bounds.centerX() + view.paddingLeft, bounds.centerY() + view.paddingTop, 0)
                try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
            }
        }
        compose.waitForIdle()
    }
    private data class ScrollPosition(val value: Float, val maximum: Float)
    private fun axis(owner: SemanticsNodeInteraction = viewport()): ScrollPosition? {
        val range = owner.fetchSemanticsNode().config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange)
        return range?.let { ui { ScrollPosition(it.value(), it.maxValue()) } }
    }
    private fun target(view: NativeFloatTextView, box: RectF): NativeHorizontalScrollTarget? = ui {
        val (x, y) = nativeWindow(view)
        geometry(view).horizontalScrollTargetAt(box.centerX() - x, box.centerY() - y)
    }
    private fun sourceAx(scrolling: Boolean, action: Int? = null): Boolean {
        val id = viewport().fetchSemanticsNode().id
        val windowBounds = windowBox(viewport())
        return ui {
            val screen = IntArray(2); val window = IntArray(2)
            compose.activity.window.decorView.getLocationOnScreen(screen); compose.activity.window.decorView.getLocationInWindow(window)
            val expected = Rect()
            RectF(windowBounds).apply { offset((screen[0] - window[0]).toFloat(), (screen[1] - window[1]).toFloat()) }.roundOut(expected)
            val providers = allViews().filterNot { it is NativeFloatTextView }.mapNotNull { it.accessibilityNodeProvider }.distinct()
            val candidates = providers.mapNotNull { provider ->
                val info = provider.createAccessibilityNodeInfo(id) ?: return@mapNotNull null
                val actual = Rect(); info.getBoundsInScreen(actual)
                if (actual == expected) provider to info else { info.recycle(); null }
            }
            // Hidden's tag-only owner may be pruned; no source AX container is invented.
            if (candidates.isEmpty() && !scrolling) {
                assertTrue(providers.isNotEmpty())
                return@ui action?.let { requested -> providers.any { it.performAction(id, requested, null) } } ?: false
            }
            assertEquals("One actual source scrollport accessibility owner", 1, candidates.size)
            val (provider, info) = candidates.single()
            try {
                assertEquals(scrolling, info.isScrollable)
                val movements = setOf(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD, AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD,
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id, AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id)
                assertEquals(scrolling, info.actionList.any { it.id in movements })
                action?.let { provider.performAction(id, it, null) } ?: true
            } finally { info.recycle() }
        }
    }

    @Test fun actualEntryKeepsImageFlowAndZeroHeightLabelOriginsAcrossFractionalViewportAndRtl() {
        val baseline = scope(emptyList()); val origin = scope(listOf(label(0, 16f, 0f))); val full = scope()
        // Hold the source top margin constant while removing only the cancelling bottom pair.
        val unpadded = baseline.copy(style = baseline.style.copy(padding = zero(), margins = SignedContainerEdges(
            SignedContainerMargin(StyleLengthUnit.Em, .3f), px(0f), px(0f), px(0f))))
        val value = mutableStateOf(entry(unpadded)); val width = mutableStateOf(300)
        val rootCss = mutableStateOf(899.5); val direction = mutableStateOf(LayoutDirection.Ltr); val seen = Seen()
        withScene("absolute-origin", { Scene(value.value, it, seen, rootCss.value, width.value, direction.value) }) {
            ready(seen, 0)
            val unpaddedHeight = windowBox(viewport()).height()
            val unpaddedView = rootView(); val unpaddedImage = imageCaret(unpaddedView)
            val unpaddedTail = caretWindow(unpaddedView, node(unpaddedView, "tail").start)
            compose.runOnIdle { value.value = entry(baseline) }; ready(seen, 0)
            val baselineBox = windowBox(viewport()); val baselineView = rootView()
            val baselineImage = imageCaret(baselineView)
            assertEquals(310f, ui { kotlin.math.abs(caretWindow(baselineView, baselineView.logicalText.indexOf('\ufffc') + 1).left -
                baselineImage.left) }, .01f)
            val baselineTail = caretWindow(baselineView, node(baselineView, "tail").start)
            assertEquals(25f, baselineBox.height() - unpaddedHeight, .01f)
            assertEquals(unpaddedImage, baselineImage)
            assertEquals("Source bottom margin cancels the padding without changing image flow", unpaddedTail, baselineTail)
            val baselineHeight = ui { geometry(baselineView).height }
            compose.runOnIdle { value.value = entry(origin) }; ready(seen, 1)
            val zero = caretWindow(rootView(), node(rootView(), names[0]).start)
            compose.runOnIdle { value.value = entry(full) }; ready(seen, 4)
            val stable = rootView()
            compose.runOnIdle {
                inventory(stable)
                assertEquals(baselineHeight, geometry(stable).height)
                assertEquals(baselineImage, imageCaret(stable))
                assertEquals(baselineTail, caretWindow(stable, node(stable, "tail").start))
                names.indices.forEach { i ->
                    val item = node(stable, names[i]); val first = caretWindow(stable, item.start); val last = caretWindow(stable, item.end)
                    assertEquals(lefts[i], first.left - zero.left, .01f)
                    assertEquals(tops[i] - 16f, first.top - zero.top, .01f)
                    assertEquals(first.top, last.top, .01f)
                    assertEquals(item.start to item.end, geometry(stable).lineRange(item.start))
                }
            }
            assertEquals(baselineBox, windowBox(viewport()))
            // Keep the neutral normal-flow image within C in RTL; leading overflow is a
            // separate refused native domain, not evidence about absolute physical offsets.
            compose.runOnIdle { rootCss.value = 900.0; width.value = 420; direction.value = LayoutDirection.Rtl }; ready(seen, 4)
            assertTrue(windowBox(viewport()).width() >= 310f)
            assertSame(stable, rootView()); assertNull(axis())
            compose.runOnIdle {
                inventory(stable)
                val first = caretWindow(stable, node(stable, names[0]).start)
                names.indices.forEach { i ->
                    val next = caretWindow(stable, node(stable, names[i]).start)
                    assertEquals(lefts[i] - lefts[0], next.left - first.left, .01f)
                    assertEquals(tops[i] - tops[0], next.top - first.top, .01f)
                }
            }
            compose.runOnIdle { width.value = 64; rootCss.value = 899.0; direction.value = LayoutDirection.Ltr }; ready(seen, 4)
            val narrowWidth = windowBox(viewport()).width()
            val current = rootView()
            compose.runOnIdle {
                inventory(current)
                names.forEach { label -> val item = node(current, label)
                    assertEquals(geometry(current).caretRect(item.start).top, geometry(current).caretRect(item.end).top, .01f)
                }
                assertTrue(kotlin.math.abs(geometry(current).caretRect(node(current, names[0]).end).left -
                    geometry(current).caretRect(node(current, names[0]).start).left) > narrowWidth)
            }
        }
    }

    @Test fun realInputAndProgrammaticRevealKeepOneScopeAcrossScrollHiddenClampAndReplacement() {
        val source = scope(); val value = mutableStateOf(entry(source), referentialEqualityPolicy()); val width = mutableStateOf(240)
        val css = mutableStateOf(899.5); val seen = Seen()
        withScene("absolute-scroll", { Scene(value.value, it, seen, css.value, width.value) }) {
            ready(seen, 4); val stable = rootView(); val window = windowBox(viewport())
            val originalTarget = target(stable, window); assertNotNull(originalTarget); assertTrue(checkNotNull(axis()).maximum > 0f)
            assertTrue(sourceAx(true, AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)); compose.waitForIdle()
            assertTrue(checkNotNull(axis()).value > 0f)
            assertTrue(sourceAx(true, AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)); compose.waitForIdle()
            assertEquals(0f, checkNotNull(axis()).value, .01f)
            val initial = imageCaret(stable).left
            drag(stable, window, 35f)
            val scrolled = imageCaret(stable).left; assertTrue(scrolled < initial); val offset = checkNotNull(axis()).value
            val ids = ui { geometry(stable).nodes.map { it.id to (it.start to it.end) } }
            compose.runOnIdle { css.value = 900.0 }; ready(seen, 4)
            assertSame(stable, rootView()); assertNull(axis()); assertNull(target(stable, windowBox(viewport())))
            assertNull(viewport().fetchSemanticsNode().config.getOrNull(SemanticsActions.ScrollBy))
            assertFalse(sourceAx(false, AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)); compose.waitForIdle()
            assertEquals(scrolled, imageCaret(stable).left, .01f)
            drag(stable, windowBox(viewport()), 35f); assertEquals(scrolled, imageCaret(stable).left, .01f)
            assertTrue(seen.actions.isEmpty())
            focus(stable, names[1])
            assertTrue("Hidden must retain programmatic source action reveal", imageCaret(stable).left < scrolled)
            compose.runOnIdle { assertEquals(ids, geometry(stable).nodes.map { it.id to (it.start to it.end) }); inventory(stable) }
            click(stable, names[1]); assertEquals(listOf(EntryLink(names[1], "Khiamniungan_Naga")), seen.actions)
            compose.runOnIdle { css.value = 899.5 }; ready(seen, 4)
            assertSame(originalTarget, target(stable, windowBox(viewport()))); assertTrue(checkNotNull(axis()).value >= offset)
            // The nonempty width100% absolute line boxes retain their positive left overflow.
            // At the narrower width only the known 310px image extends farther than that envelope.
            compose.runOnIdle { width.value = 64 }; ready(seen, 4)
            val narrow = checkNotNull(axis())
            assertEquals(310f - windowBox(viewport()).width(), narrow.maximum, .01f)
            assertTrue(narrow.maximum > 250f)
            viewport().performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(10000f, 0f)) }; compose.waitForIdle()
            assertEquals(narrow.maximum, checkNotNull(axis()).value, .01f)
            compose.runOnIdle { width.value = 240 }; ready(seen, 4)
            assertEquals(250f, checkNotNull(axis()).maximum, .01f)
            assertEquals(250f, checkNotNull(axis()).value, .01f)
            assertSame(originalTarget, target(stable, windowBox(viewport())))
            compose.runOnIdle { value.value = entry(source.copy(blocks = source.blocks.toList())) }; ready(seen, 4)
            val replaced = rootView(); assertEquals(0f, checkNotNull(axis()).value, .01f)
            assertNotSame(originalTarget, target(replaced, windowBox(viewport())))
            compose.runOnIdle { inventory(replaced) }
            // Zero range is a distinct legitimate source: every nonempty line begins at left0.
            compose.runOnIdle { value.value = entry(scope(names.indices.map { label(it, left = 0f) })); width.value = 420 }
            ready(seen, 4); val zeroRange = rootView()
            assertEquals(0f, checkNotNull(axis()).maximum, .01f); assertEquals(0f, checkNotNull(axis()).value, .01f)
            assertNull(viewport().fetchSemanticsNode().config.getOrNull(SemanticsActions.ScrollBy))
            assertNull(target(zeroRange, windowBox(viewport()))); val unmoved = imageCaret(zeroRange).left
            assertFalse(sourceAx(false, AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)); compose.waitForIdle()
            drag(zeroRange, windowBox(viewport()), 35f); assertEquals(unmoved, imageCaret(zeroRange).left, .01f)
            assertEquals(1, seen.actions.size)
            compose.runOnIdle { inventory(zeroRange) }
        }
    }

    @Test fun ancestorClipsPreserveCopyAndActionsWhileLaterAbsoluteSiblingWinsPaintAndHit() {
        val overlap = listOf(label(0, 30f, 200f, "Overlap", "#ff0000"), label(1, 30f, 200f, "Overlap", "#00aa00"))
        val source = scope(names.indices.map { label(it) } + overlap, width = 360f); val seen = Seen()
        withScene("absolute-clips", { Scene(entry(source, ancestors = true), it, seen, 899.5, 300) }) {
            ready(seen, 6)
            val view = ui { views().single { candidate ->
                '\ufffc' in candidate.logicalText && candidate.currentMeasuredGeometry?.nodes?.count {
                    it.kind == FloatInteractionKind.LINK && it.label != "tail" } == 6
            } }
            compose.runOnIdle {
                val tailOwners = views().filter { candidate -> candidate.currentMeasuredGeometry?.nodes?.any {
                    it.kind == FloatInteractionKind.LINK && it.label == "tail" } == true }
                assertEquals(1, tailOwners.size); assertNotSame(view, tailOwners.single())
            }
            val horizontal = SemanticsMatcher("ordinary ancestor horizontal owner") {
                it.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) != null &&
                    it.config.getOrNull(SemanticsProperties.TestTag) != "compiled-positioned-scrollport"
            }
            fun ancestor(width: Int) = compose.onNode(horizontal and SemanticsMatcher("width $width") { it.size.width == width }, useUnmergedTree = true)
            val outer = ancestor(160); val inner = ancestor(240)
            fun clip() = windowBox(viewport()).apply { check(intersect(windowBox(outer))); check(intersect(windowBox(inner))) }
            fun assertClippedAx(item: FloatInteractionNode, visibleClip: RectF) {
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(item.id))
                try {
                    assertEquals(item.label, info.text.toString()); assertTrue(info.isClickable)
                    val bounds = RectF(); item.bounds.forEach(bounds::union)
                    val (wx, wy) = nativeWindow(view); bounds.offset(wx, wy)
                    if (!bounds.intersect(visibleClip)) bounds.setEmpty()
                    val screen = IntArray(2); val window = IntArray(2)
                    compose.activity.window.decorView.getLocationOnScreen(screen); compose.activity.window.decorView.getLocationInWindow(window)
                    if (!bounds.isEmpty) bounds.offset((screen[0] - window[0]).toFloat(), (screen[1] - window[1]).toFloat())
                    val expected = Rect(); bounds.roundOut(expected); val actual = Rect(); info.getBoundsInScreen(actual)
                    assertEquals(expected, actual)
                    assertEquals(!expected.isEmpty, info.isVisibleToUser)
                } finally { info.recycle() }
            }
            fun rejectBetween(item: FloatInteractionNode, inside: RectF, outside: RectF) {
                val g = geometry(view); val (wx, wy) = nativeWindow(view)
                val point = (item.start until item.end).mapNotNull { at ->
                    val a = g.caretRect(at); val b = g.caretRect(at + 1)
                    val x = (a.centerX() + b.centerX()) / 2f; val y = a.centerY()
                    if (inside.contains(wx + x, wy + y) && !outside.contains(wx + x, wy + y)) x to y else null
                }.firstOrNull()
                assertNotNull("An actual source glyph must cross this independent clip", point)
                val (x, y) = checkNotNull(point); inputGuard(); val now = SystemClock.uptimeMillis()
                val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x + view.paddingLeft, y + view.paddingTop, 0)
                try { assertFalse(view.dispatchTouchEvent(down)) } finally { down.recycle() }
            }
            val twins = nodes(view).filter { it.label == "Overlap" }; assertEquals(2, twins.size)
            val beforeInner = windowBox(inner); val beforeOuter = windowBox(outer); val beforeClip = clip()
            compose.runOnIdle {
                inventory(view, names + listOf("Overlap", "Overlap"), tail = false)
                rejectBetween(twins.last(), beforeInner, beforeOuter)
                assertTrue(seen.actions.isEmpty()); twins.forEach { assertClippedAx(it, beforeClip) }
            }
            outer.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(120f, 0f)) }; compose.waitForIdle()
            val visibleTwins = nodes(view).filter { it.label == "Overlap" }
            val afterInner = windowBox(inner); val afterOuter = windowBox(outer); val afterClip = clip()
            compose.runOnIdle {
                rejectBetween(visibleTwins.last(), afterOuter, afterInner); assertTrue(seen.actions.isEmpty())
                val shared = RectF(visibleTwins.first().bounds.single()); assertTrue(shared.intersect(visibleTwins.last().bounds.single()))
                assertEquals(visibleTwins.last().id, geometry(view).interactionNodeAt(shared.centerX(), shared.centerY())?.id)
                visibleTwins.forEach { assertClippedAx(it, afterClip) }
                val now = SystemClock.uptimeMillis(); inputGuard()
                for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                    val event = MotionEvent.obtain(now, now + if (action == MotionEvent.ACTION_UP) 1 else 0,
                        action, shared.centerX() + view.paddingLeft, shared.centerY() + view.paddingTop, 0)
                    try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
                }
                assertEquals(listOf(EntryLink(names[1], "Khiamniungan_Naga")), seen.actions)
            }
            val actualClip = clip(); val rootAt = compose.onNodeWithTag("absolute-root").fetchSemanticsNode().positionInWindow
            val pixels = compose.onNodeWithTag("absolute-root").captureToImage().asAndroidBitmap()
            try {
                var green = 0; var red = 0
                for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
                    val color = pixels.getPixel(x, y)
                    if (color == android.graphics.Color.RED || color == android.graphics.Color.rgb(0, 170, 0)) {
                        assertTrue(actualClip.contains(rootAt.x + x + .5f, rootAt.y + y + .5f))
                        if (color == android.graphics.Color.RED) red++ else green++
                    }
                }
                assertEquals("Later identical glyphs cover the earlier authored red fill", 0, red); assertTrue(green > 0)
            } finally { pixels.recycle() }
        }
    }

    @Test fun positiveVerticalOverflowRetainsBodyAndActionsThenRecoversWithoutInventedFlowHeight() {
        val good = scope(); val bad = scope(names.indices.map { label(it, if (it == 2) 500f else tops[it]) })
        val value = mutableStateOf(entry(good)); val seen = Seen()
        withScene("absolute-y-refusal", { Scene(value.value, it, seen, 899.5, 300) }) {
            ready(seen, 4); val height = windowBox(viewport()).height()
            val previousFailures = ui { seen.failures.size }
            compose.runOnIdle { value.value = entry(bad) }
            compose.waitUntil(5000) { ui { seen.failures.drop(previousFailures).any { "vertical" in it.lowercase() } } }; compose.waitForIdle()
            assertTrue(compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true,
                useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())
            val retainedViews = views()
            compose.runOnIdle {
                names.forEach { name -> assertTrue(retainedViews.any { name in it.logicalText.toString() }) }
                val retained = retainedViews.single { candidate -> candidate.currentMeasuredGeometry?.nodes?.any {
                    it.kind == FloatInteractionKind.LINK && it.label == names[0] } == true }
                val item = node(retained, names[0]); retained.setSelection(item.start, item.end)
                assertEquals(names[0], retained.selectedTextForCopy()); clearSelection(retained)
                assertTrue(retained.accessibilityNodeProvider.performAction(item.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink(names[0], "Khiamniungan_Naga")), seen.actions)
                value.value = entry(good)
            }
            ready(seen, 4); assertEquals(height, windowBox(viewport()).height(), .01f)
            val recovered = rootView()
            compose.runOnIdle { inventory(recovered) }
            compose.onAllNodesWithText("Unable to display this layout.", useUnmergedTree = true).assertCountEquals(0)
        }
    }

    @Test fun ordinaryHiddenTableRetainsOnlyProgrammaticRevealAcrossRootBandsAndNestedWidths() {
        // Direct typed constructor control, not a captured ZH record. The original Table
        // and Hidden owner survive every viewport phase; no positioned-scope substitute.
        fun text(value: String) = Span("text", value, fontScale = 14f,
            fontScaleBasis = FontScaleBasis.CssPx, fontFamily = ContainerFontFamily.SansSerif)
        fun link(value: String) = text(value).copy(kind = "link", target = "hidden-$value")
        val near = link("NEAR"); val far = link("FAR"); val caption = link("CAPTION")
        val heading = Block("heading", 0, listOf(far), level = 3, anchor = "hidden-far")
        val cellStyle = CellStyle(border = StyleBorder.None, padding = zero(),
            width = StyleWidth(StyleWidthUnit.Px, 200f), minWidth = px(200f))
        val rows = listOf(listOf(Cell(listOf(near), false, 1, 1, style = cellStyle),
            Cell(listOf(text("first")), false, 1, 1, style = cellStyle))) +
            List(28) { index -> listOf(Cell(listOf(text("left $index")), false, 1, 1, style = cellStyle),
                Cell(listOf(text("right $index")), false, 1, 1, style = cellStyle)) } +
            listOf(listOf(Cell(listOf(text("last")), false, 1, 1, style = cellStyle),
                Cell(emptyList(), false, 1, 1, blocks = listOf(heading),
                    style = cellStyle.copy(textAlign = CellTextAlign.Right))))
        val table = Table(listOf(caption), rows,
            geometry = TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0),
            style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 400f), border = StyleBorder.None,
                padding = zero(), margins = zero()), rowsHiddenMaxWidthPx = 639L)
        val source = Container(listOf(Block("table", 0, emptyList(), table = table)),
            ContainerStyle(width = ContainerWidth.FitContent,
                maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
                boxSizing = ContainerBoxSizing.BorderBox, overflow = ContainerOverflow.Hidden,
                positioning = ContainerPositioning.RelativeAuto, margins = zero(),
                padding = StyleEdges(px(4f), px(8f), px(4f), px(8f)),
                border = ContainerBorder.Solid(px(2f), ContainerColor.Rgb("#ff0000")),
                background = ContainerColor.Rgb("#ddffdd"),
                screenMaxWidth = ContainerScreenMaxWidth(639L, width = ContainerWidth.Auto)))
        fun sourceEntry(containing: Float) = Entry("Hidden Table constructor", emptyList(), "language", "English", "en",
            listOf(Section(0, "", listOf(box(Container(listOf(box(source)), ContainerStyle(
                width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, containing))))),
                paragraph(listOf(text("after hidden table")))))), emptyList(),
            bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        val value = mutableStateOf(sourceEntry(200f), referentialEqualityPolicy())
        val rootCss = mutableStateOf(640.0); val width = mutableStateOf(420); val zoom = mutableStateOf(1f)
        val request = mutableStateOf<EntryAnchorRequest?>(null, referentialEqualityPolicy())
        val reading = EntryReadingState(); val actions = mutableListOf<EntryLink>()
        val consumed = mutableListOf<EntryAnchorRequest>(); val failures = mutableListOf<String>()
        fun owner(label: String): NativeFloatTextView = ui { views().single { view ->
            view.currentMeasuredGeometry?.nodes?.any { it.kind == FloatInteractionKind.LINK && it.label == label } == true
        } }
        fun has(label: String) = ui { views().any { view ->
            view.currentMeasuredGeometry?.nodes?.any { it.kind == FloatInteractionKind.LINK && it.label == label } == true
        } }
        fun port() = compose.onNodeWithTag("compiled-hidden-scrollport", useUnmergedTree = true)
        fun root() = compose.onNodeWithTag("ordinary-hidden-root")
        fun visible(label: String): Boolean = ui {
            if (!has(label)) return@ui false
            val view = owner(label); val item = node(view, label)
            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(item.id))
            try { info.isVisibleToUser } finally { info.recycle() }
        }
        fun ready(shown: Boolean) {
            compose.waitUntil(5000) { has("CAPTION") && has("NEAR") == shown && has("FAR") == shown }
            compose.waitForIdle()
            compose.onAllNodesWithText("layout unavailable", substring = true, ignoreCase = true,
                useUnmergedTree = true).assertCountEquals(0)
            assertSame(rows, table.rows); assertSame(table, source.blocks.single().table)
        }
        fun assertSource(label: String) = ui {
            val view = owner(label); val item = node(view, label)
            assertEquals(label, view.logicalText.subSequence(item.start, item.end).toString())
            view.setSelection(item.start, item.end); assertEquals(label, view.selectedTextForCopy()); clearSelection(view)
            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(item.id))
            try { assertEquals(label, info.text.toString()); assertTrue(info.isClickable) } finally { info.recycle() }
        }
        fun noUserScroll() {
            val semantic = port().fetchSemanticsNode()
            assertNull(semantic.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange))
            assertNull(semantic.config.getOrNull(SemanticsActions.ScrollBy))
            val id = semantic.id
            compose.runOnIdle {
                val providers = allViews().filterNot { it is NativeFloatTextView }.mapNotNull { it.accessibilityNodeProvider }.distinct()
                assertTrue(providers.isNotEmpty())
                assertFalse(providers.any { it.performAction(id, AccessibilityNodeInfo.ACTION_SCROLL_FORWARD, null) })
                assertFalse(providers.any { it.performAction(id, AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD, null) })
            }
        }
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, zoom.value),
                    LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalTableDocumentViewportCssWidth provides rootCss.value,
                    LocalNativeFloatContextFailureObserver provides { failures += it }) {
                    DictTheme("light") {
                        MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                            fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp))) {
                            Box(Modifier.size(width.value.dp, 420.dp).background(Color.White).testTag("ordinary-hidden-root")) {
                                EntryView(value.value, false, {}, onLink = { actions += it }, settings = settings,
                                    readingState = reading, anchorRequest = request.value,
                                    onAnchorConsumed = {
                                        if (rootCss.value > 639.0) {
                                            val placed = owner("FAR"); val item = node(placed, "FAR")
                                            assertTrue(placed.isAttachedToWindow && placed.isLaidOut)
                                            assertNotNull(placed.currentMeasuredGeometry)
                                            assertEquals(far.text, placed.logicalText.subSequence(item.start, item.end).toString())
                                            assertTrue(item.bounds.any { !it.isEmpty })
                                        }
                                        consumed += it; if (request.value === it) request.value = null
                                    })
                            }
                        }
                    }
                }
            } }
            ready(true); noUserScroll()
            assertEquals(196f, windowBox(port()).width(), .01f)
            val originalHeight = windowBox(port()).height()
            assertTrue("The real final cell lies below the reader viewport", originalHeight > windowBox(root()).height())
            assertFalse(visible("FAR")); assertSource("NEAR"); assertSource("FAR"); assertSource("CAPTION")
            val nearView = owner("NEAR"); val nearStart = node(nearView, "NEAR").start
            val before = caretWindow(nearView, nearStart).left
            val nearBand = caretWindow(nearView, nearStart)
            val shell = windowBox(port())
            compose.runOnIdle {
                inputGuard(); val now = SystemClock.uptimeMillis()
                // Dispatch through the real activity/Compose hierarchy, not directly to
                // the child View (which would miss an accidentally installed draggable).
                val x = shell.left + 30f; val y = nearBand.centerY()
                for ((dt, action, dx) in listOf(Triple(0L, MotionEvent.ACTION_DOWN, 0f),
                    Triple(20L, MotionEvent.ACTION_MOVE, -50f), Triple(21L, MotionEvent.ACTION_CANCEL, -50f))) {
                    val event = MotionEvent.obtain(now, now + dt, action, x + dx, y, 0)
                    try { compose.activity.dispatchTouchEvent(event) } finally { event.recycle() }
                }
                val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE }
                val coordinates = MotionEvent.PointerCoords().apply { this.x = x; this.y = y; setAxisValue(MotionEvent.AXIS_HSCROLL, 1f) }
                val wheel = MotionEvent.obtain(now + 30, now + 30, MotionEvent.ACTION_SCROLL, 1,
                    arrayOf(properties), arrayOf(coordinates), 0, 0, 1f, 1f, 0, 0,
                    android.view.InputDevice.SOURCE_MOUSE, 0)
                try { compose.activity.dispatchGenericMotionEvent(wheel) } finally { wheel.recycle() }
            }
            compose.waitForIdle(); assertEquals(before, caretWindow(owner("NEAR"), node(owner("NEAR"), "NEAR").start).left, .01f)
            assertTrue(actions.isEmpty())
            // A genuine child native View asks its ancestors to reveal this action.
            val farView = owner("FAR"); val farId = node(farView, "FAR").id
            compose.runOnIdle {
                // The bridge launches real descendant requests; latest same-value and
                // opposite-target replacements must not cancel the final placement.
                assertTrue(farView.revealLogicalOffset(node(farView, "FAR").start))
                assertTrue(farView.revealLogicalOffset(node(farView, "FAR").start))
                assertTrue(nearView.revealLogicalOffset(nearStart))
                assertTrue(farView.accessibilityNodeProvider.performAction(farId,
                    AccessibilityNodeInfo.ACTION_FOCUS, null))
            }
            compose.waitUntil(5000) { visible("FAR") }
            compose.waitForIdle(); noUserScroll()
            assertTrue(caretWindow(owner("NEAR"), node(owner("NEAR"), "NEAR").start).left < before)
            assertEquals(originalHeight, windowBox(port()).height(), .01f)
            assertSame(farView, owner("FAR")); assertEquals(farId, node(farView, "FAR").id)
            assertSource("FAR"); click(farView, "FAR")
            assertEquals(listOf(EntryLink("hidden-FAR", null)), actions)
            // Changing root allocation alone does not change the nested containing C.
            compose.runOnIdle { width.value = 360 }; ready(true)
            assertEquals(196f, windowBox(port()).width(), .01f)
            compose.runOnIdle { value.value = sourceEntry(160f); zoom.value = 1.5f }; ready(true)
            assertEquals(156f, windowBox(port()).width(), .01f); noUserScroll(); assertSource("FAR")
            // ROOT CSS threshold is inclusive despite C=160 and a different actual UI width.
            compose.runOnIdle { rootCss.value = 639.0 }; ready(false)
            assertTrue(windowBox(port()).height() < originalHeight)
            assertSource("CAPTION"); noUserScroll()
            val hiddenScroll = ui { reading.scroll.firstVisibleItemIndex to reading.scroll.firstVisibleItemScrollOffset }
            val denied = EntryAnchorRequest(value.value.key, "hidden-far")
            compose.runOnIdle { request.value = denied }
            compose.waitUntil(5000) { ui { consumed.any { it === denied } } }
            compose.onNodeWithText(SourceHeadingRevealUnavailable, useUnmergedTree = true).assertExists()
            assertEquals(1, consumed.count { it === denied })
            assertEquals(hiddenScroll, ui { reading.scroll.firstVisibleItemIndex to reading.scroll.firstVisibleItemScrollOffset })
            assertFalse(has("FAR")); assertSame(heading, table.rows.last()[1].blocks!!.single())
            // The original allowed Table-cell heading recovers, including vertical root
            // reveal. Consumption is placement-backed; visibility is checked separately.
            compose.runOnIdle { rootCss.value = 640.0; zoom.value = 1f; value.value = sourceEntry(200f) }; ready(true)
            val recovered = EntryAnchorRequest(value.value.key, "hidden-far")
            compose.runOnIdle { request.value = recovered }
            compose.waitUntil(5000) { ui { consumed.any { it === recovered } } }
            compose.waitUntil(5000) { visible("FAR") }
            assertEquals(1, consumed.count { it === recovered }); assertSource("FAR"); noUserScroll()
            assertEquals(196f, windowBox(port()).width(), .01f)
            assertEquals(originalHeight, windowBox(port()).height(), .01f)
            assertTrue(failures.isEmpty())
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent { } }; compose.waitForIdle() }
            catch (failure: Throwable) { if (primary != null) primary.addSuppressed(failure) else throw failure }
        }
    }
}
