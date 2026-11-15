package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import android.graphics.Rect as AndroidRect
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Looper
import android.os.SystemClock
import android.text.TextPaint
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontSynthesis
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Source-only donor: actual reader image owners and controlled pixels; no network asset. */
class InlineImageAlignmentDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    private val label = "Aligned object"
    private val target = EntryLink("image-target")
    private val style = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 24.sp, color = Color.Black)
    private val settings = AppSettings(allowImages = false, allowAudio = false)
    private val media = listOf(Media("Controlled alignment.png", "image", ""))
    private val alignments = listOf(null, InlineImageVerticalAlign.Middle, InlineImageVerticalAlign.Baseline)

    private fun image(alignment: InlineImageVerticalAlign?) = InlineImage("Controlled alignment.png",
        widthPx = 18, heightPx = 20, border = true, alt = label, verticalAlign = alignment)

    private fun spans(image: InlineImage) = listOf(Span("text", "M", fontScale = 2f),
        Span("text", " "), Span("link", "", target.target, image = image), Span("text", " \u05d0"))

    @Composable
    private fun ReadyImage(image: InlineImage, bitmap: Bitmap, onFont: (Typeface) -> Unit,
        content: @Composable () -> Unit) {
        val owner = rememberInlineImageViewOwner(listOf(image), media, settings, "en")
        remember(owner) {
            owner.states[inlineImageAssetKey(image)] = InlineImageAssetState.Ready(
                DecodedMediaBitmap(bitmap, 18, 20), 18, 20, "image/png", "controlled", "")
            true
        }
        val face = LocalFontFamilyResolver.current.resolve(
            FontFamily.Monospace, FontWeight.Normal, FontStyle.Normal, FontSynthesis.All).value as Typeface
        SideEffect { onFont(face) }
        CompositionLocalProvider(LocalInlineImageOwner provides owner, content = content)
    }

    @Test fun composeImageAlignmentUsesOccurrenceBaselineAndOuterBorderWithoutChangingItsAction() {
        val bitmap = redBitmap()
        val actions = CopyOnWriteArrayList<EntryLink>()
        var alignment by mutableStateOf<InlineImageVerticalAlign?>(null)
        var measured: TextLayoutResult? = null
        var font: Typeface? = null
        var primaryFailure: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides LayoutDirection.Ltr) {
                    MaterialTheme(typography = Typography(bodyLarge = style)) {
                        key(alignment) {
                            val occurrence = image(alignment)
                            ReadyImage(occurrence, bitmap, { font = it }) {
                                val source = remember(occurrence) { spans(occurrence) }
                                val annotated = styledTextAnnotation(source, null, style, actions::add)
                                val inline = compiledInlineImageContent(source, annotated, style,
                                    media, settings, "en", actions::add, Color.Gray)
                                Text(annotated, style = style, inlineContent = inline,
                                    modifier = Modifier.width(240.dp).background(Color.White).testTag("aligned-compose"),
                                    onTextLayout = { measured = it })
                            }
                        }
                    }
                }
            } }
            var original: Raster? = null
            var originalBaseline: Float? = null
            for (selected in alignments) {
                if (selected != null) compose.runOnIdle { measured = null; alignment = selected }
                compose.waitUntil(5000) { ui { measured != null && font != null } }
                val layout = ui { checkNotNull(measured) }
                val xHeight = ui { xHeight(checkNotNull(font)) }
                assertEquals("M \uFFFC \u05d0", layout.layoutInput.text.text)
                assertEquals(1, layout.lineCount)
                val placeholder = checkNotNull(layout.placeholderRects.single())
                val baseline = layout.firstBaseline
                assertTrue("The alignment oracle distinguishes these boxes", kotlin.math.abs(22f - xHeight) > 2f)
                if (originalBaseline == null) originalBaseline = baseline
                else assertEquals("Tall sibling holds the baseline", checkNotNull(originalBaseline), baseline, 0.01f)
                val raster = capture("aligned-compose")
                assertImagePixels(raster, baseline, xHeight, selected, placeholder.left)
                if (selected == null) original = raster
                if (selected == InlineImageVerticalAlign.Middle) assertSamePixels(checkNotNull(original), raster)

                val imageNode = compose.onNodeWithContentDescription(label, useUnmergedTree = true)
                    .assertIsDisplayed().assertHasClickAction().fetchSemanticsNode()
                assertEquals(Role.Image, imageNode.config.getOrNull(SemanticsProperties.Role))
                if (selected != null) {
                    val host = compose.onNodeWithTag("aligned-compose").fetchSemanticsNode()
                    val box = imageNode.boundsInRoot
                    assertEquals(20f, box.width, 0.01f)
                    assertEquals(22f, box.height, 0.01f)
                    assertEquals(placeholder.left, box.left - host.boundsInRoot.left, 0.01f)
                    assertEquals(expectedTop(baseline, xHeight, selected), box.top - host.boundsInRoot.top, 1f)
                }
                val count = actions.size
                val painted = raster.red
                ui { assertPhysicalActivity(compose.activity) }
                compose.onNodeWithTag("aligned-compose").performTouchInput {
                    click(Offset(painted.centerX(), painted.centerY()))
                }
                compose.runOnIdle {
                    assertEquals(count + 1, actions.size)
                    assertEquals(target, actions.last())
                }
            }
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            try { dispose(bitmap) } catch (cleanup: Throwable) {
                if (primaryFailure == null) throw cleanup else if (cleanup !== primaryFailure) primaryFailure.addSuppressed(cleanup)
            }
        }
    }

    @Test fun nativeImageAlignmentKeepsPaintSelectionCopyAndAccessibilityAtTheSameSourceOffset() {
        val bitmap = redBitmap()
        val actions = CopyOnWriteArrayList<EntryLink>()
        data class Mode(val rtl: Boolean, val noWrap: Boolean, val indent: Float)
        val modes = listOf(Mode(false, false, 0f), Mode(true, false, 0f), Mode(true, true, 17f))
        var mode by mutableStateOf(modes.first())
        var alignment by mutableStateOf<InlineImageVerticalAlign?>(null)
        var published: NativeFloatContextGeometry? = null
        var hostWindow = Offset.Zero
        var font: Typeface? = null
        var primaryFailure: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides if (mode.rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                    MaterialTheme(typography = Typography(bodyLarge = style)) {
                        key(mode, alignment) {
                            val occurrence = image(alignment)
                            ReadyImage(occurrence, bitmap, { font = it }) {
                                val source = remember(occurrence) { spans(occurrence) }
                                val annotated = styledTextAnnotation(source, null, style, actions::add)
                                val prepared = prepareNativeFloatText(source, annotated, emptyList(), style, Color.Blue,
                                    media, settings, "en", actions::add, indentPixels = mode.indent,
                                    ownerDirection = if (mode.rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr,
                                    ownerWrap = if (mode.noWrap) TextWrap.NoWrap else null)
                                Box(Modifier.width(240.dp).background(Color.White).testTag("aligned-native")
                                    .onGloballyPositioned { hostWindow = it.positionInWindow() }) {
                                    NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f)),
                                        Modifier.width((if (mode.noWrap) 80 else 160).dp), Color.Blue,
                                        onInputGeometry = { geometry, _ -> published = geometry },
                                        child = { _, _ -> error("This fixture has no delegated child") })
                                }
                            }
                        }
                    }
                }
            } }
            for (selectedMode in modes) {
                var original: Raster? = null
                var originalBaseline: Float? = null
                for (selected in alignments) {
                    if (selectedMode != modes.first() || selected != null) compose.runOnIdle {
                        published = null; mode = selectedMode; alignment = selected
                    }
                    compose.waitUntil(5000) { ui { published != null && font != null && imageViewOrNull() != null } }
                    val snapshot = ui {
                        val view = checkNotNull(imageViewOrNull())
                        val geometry = checkNotNull(view.currentMeasuredGeometry)
                        val node = geometry.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                        val location = IntArray(2).also(view::getLocationInWindow)
                        val dx = location[0] + view.paddingLeft - hostWindow.x
                        val dy = location[1] + view.paddingTop - hostWindow.y
                        val baselines = checkNotNull(geometry.textBaselines)
                        assertEquals("The complete native source occupies one line", checkNotNull(baselines.first),
                            checkNotNull(baselines.last), 0.01f)
                        if (selectedMode.noWrap) {
                            val body = RectF()
                            geometry.rectsForRange(0, geometry.text.length).forEach(body::union)
                            assertTrue("NoWrap retains actual advances beyond its 80px allocation", body.width() > 80f)
                        }
                        NativeSnapshot(view, node.id, node.start, node.end, dx, dy,
                            checkNotNull(baselines.first) + dy,
                            xHeight(checkNotNull(font)), geometry.text.toString())
                    }
                    assertEquals("M \uFFFC \u05d0", snapshot.text)
                    assertEquals(2, snapshot.start)
                    assertEquals(3, snapshot.end)
                    if (originalBaseline == null) originalBaseline = snapshot.baseline
                    else assertEquals("Tall sibling holds the baseline", checkNotNull(originalBaseline), snapshot.baseline, 0.01f)
                    val raster = capture("aligned-native")
                    assertImagePixels(raster, snapshot.baseline, snapshot.xHeight, selected, null)
                    if (selected == null) original = raster
                    if (selected == InlineImageVerticalAlign.Middle) assertSamePixels(checkNotNull(original), raster)
                    ui {
                        val geometry = checkNotNull(snapshot.view.currentMeasuredGeometry)
                        val node = geometry.nodes.single { it.id == snapshot.id }
                        assertEquals(label, node.label.toString())
                        assertNotNull(node.onClick)
                        if (selected != null) {
                            val rect = node.bounds.single()
                            val expectedY = expectedTop(snapshot.baseline, snapshot.xHeight, selected) - snapshot.dy
                            assertEquals(20f, rect.width(), 0.01f)
                            assertEquals(22f, rect.height(), 0.01f)
                            assertEquals(expectedY, rect.top, 0.01f)
                            assertEquals(raster.red.left - 1f, rect.left + snapshot.dx, 1f)
                            assertRectEquals(rect, geometry.rectsForRange(snapshot.start, snapshot.end).single())
                            assertRectEquals(rect, checkNotNull(geometry.characterRects(snapshot.start, 1).single()))
                            val complete = geometry.rectsForRange(0, snapshot.text.length)
                            for ((start, end) in listOf(0 to snapshot.start, snapshot.end to snapshot.text.length)) {
                                for (ordinary in geometry.rectsForRange(start, end)) {
                                    assertTrue("Whole selection retains the neighboring native text origin", complete.any {
                                        it.left <= ordinary.left + 0.01f && it.right >= ordinary.right - 0.01f &&
                                            it.top <= ordinary.top + 0.01f && it.bottom >= ordinary.bottom - 0.01f
                                    })
                                }
                            }
                            val caret = geometry.caretRect(snapshot.start)
                            assertEquals(rect.top, caret.top, 0.01f)
                            assertEquals(rect.bottom, caret.bottom, 0.01f)
                            assertTrue(node.contains(rect.centerX(), rect.centerY()))
                            assertFalse("Old line band is not an image action", node.contains(rect.centerX(), rect.top - 2f))
                            assertFalse("Old line band is not an image action", node.contains(rect.centerX(), rect.bottom + 2f))
                        }
                        snapshot.view.setSelection(snapshot.start, snapshot.end)
                        assertEquals("\uFFFC", snapshot.view.selectedTextForCopy())
                        val provider = checkNotNull(snapshot.view.accessibilityNodeProvider)
                        val info = checkNotNull(provider.createAccessibilityNodeInfo(snapshot.id))
                        try {
                            assertEquals(label, info.contentDescription.toString())
                            assertEquals("android.widget.ImageView", info.className.toString())
                            assertTrue(info.isClickable)
                            assertTrue(info.isVisibleToUser)
                            if (selected != null) {
                                val rect = node.bounds.single()
                                val expected = AndroidRect()
                                val screen = IntArray(2).also(snapshot.view::getLocationOnScreen)
                                RectF(rect).apply { offset(screen[0] + snapshot.view.paddingLeft.toFloat(),
                                    screen[1] + snapshot.view.paddingTop.toFloat()) }.roundOut(expected)
                                val actual = AndroidRect().also(info::getBoundsInScreen)
                                assertEquals(expected, actual)
                            }
                        } finally { info.recycle() }
                        val before = actions.size
                        assertTrue(provider.performAction(snapshot.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                        assertEquals(before + 1, actions.size)
                        assertEquals(target, actions.last())
                        assertTrue(provider.performAction(View.NO_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                        if (selected != null) {
                            val box = node.bounds.single()
                            val oldBand = geometry.caretRect(0)
                            val beforeOutside = actions.size
                            for (outsideY in listOf(box.top - 2f, box.bottom + 2f)) {
                                assertTrue("Negative tap remains in the old line band", outsideY > oldBand.top && outsideY < oldBand.bottom)
                                tap(snapshot.view, box.centerX() + snapshot.view.paddingLeft,
                                    outsideY + snapshot.view.paddingTop, assertHandled = false)
                                assertEquals("Outside aligned image does not activate its source action", beforeOutside, actions.size)
                                assertTrue(provider.performAction(View.NO_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                            }
                        }
                    }
                    val count = actions.size
                    ui {
                        val x = raster.red.centerX() - snapshot.dx + snapshot.view.paddingLeft
                        val y = raster.red.centerY() - snapshot.dy + snapshot.view.paddingTop
                        tap(snapshot.view, x, y)
                        assertEquals(count + 1, actions.size)
                        assertEquals(target, actions.last())
                    }
                }
            }
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            try { dispose(bitmap) } catch (cleanup: Throwable) {
                if (primaryFailure == null) throw cleanup else if (cleanup !== primaryFailure) primaryFailure.addSuppressed(cleanup)
            }
        }
    }

    private data class NativeSnapshot(val view: NativeFloatTextView, val id: Int, val start: Int, val end: Int,
        val dx: Float, val dy: Float, val baseline: Float, val xHeight: Float, val text: String)
    private data class Raster(val width: Int, val height: Int, val pixels: IntArray, val red: RectF, val border: RectF)

    private fun expectedTop(baseline: Float, xHeight: Float, alignment: InlineImageVerticalAlign?): Float =
        baseline - if (alignment == InlineImageVerticalAlign.Baseline) 22f else (22f + xHeight) / 2f

    private fun xHeight(face: Typeface): Float {
        val paint = TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { typeface = face; textSize = 24f }
        return AndroidRect().also { paint.getTextBounds("x", 0, 1, it) }.height().toFloat()
    }

    private fun redBitmap(): Bitmap = Bitmap.createBitmap(18, 20, Bitmap.Config.ARGB_8888).apply {
        eraseColor(AndroidColor.RED)
    }

    private fun capture(tag: String): Raster {
        val bitmap = compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
        try {
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            fun bounds(color: Int): RectF {
                val indices = pixels.indices.filter { pixels[it] == color }
                assertTrue("$tag contains controlled color ${color.toUInt()}", indices.isNotEmpty())
                return RectF(indices.minOf { it % bitmap.width }.toFloat(), indices.minOf { it / bitmap.width }.toFloat(),
                    (indices.maxOf { it % bitmap.width } + 1).toFloat(), (indices.maxOf { it / bitmap.width } + 1).toFloat())
            }
            return Raster(bitmap.width, bitmap.height, pixels, bounds(AndroidColor.RED), bounds(0xffeaecf0.toInt()))
        } finally { bitmap.recycle() }
    }

    private fun assertImagePixels(raster: Raster, baseline: Float, xHeight: Float,
        alignment: InlineImageVerticalAlign?, left: Float?) {
        assertEquals(18f, raster.red.width(), 1f)
        assertEquals(20f, raster.red.height(), 1f)
        assertEquals(20f, raster.border.width(), 1f)
        assertEquals(22f, raster.border.height(), 1f)
        val top = expectedTop(baseline, xHeight, alignment)
        assertEquals(top + 1f, raster.red.top, 1f)
        assertEquals(top, raster.border.top, 1f)
        if (left != null) {
            assertEquals(left + 1f, raster.red.left, 1f)
            assertEquals(left, raster.border.left, 1f)
        }
    }

    private fun assertSamePixels(expected: Raster, actual: Raster) {
        assertEquals(expected.width, actual.width)
        assertEquals(expected.height, actual.height)
        assertArrayEquals("Null and explicit Middle preserve the same paint", expected.pixels, actual.pixels)
    }

    private fun assertRectEquals(expected: RectF, actual: RectF) {
        assertEquals(expected.left, actual.left, 0.01f); assertEquals(expected.top, actual.top, 0.01f)
        assertEquals(expected.right, actual.right, 0.01f); assertEquals(expected.bottom, actual.bottom, 0.01f)
    }

    private fun imageViewOrNull(): NativeFloatTextView? {
        check(Looper.myLooper() == Looper.getMainLooper())
        fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup)
            (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
        return views(compose.activity.window.decorView).filterIsInstance<NativeFloatTextView>().singleOrNull {
            it.isShown && it.currentMeasuredGeometry?.nodes?.any { node -> node.kind == FloatInteractionKind.IMAGE && node.label.toString() == label } == true
        }
    }

    private fun tap(view: NativeFloatTextView, x: Float, y: Float, assertHandled: Boolean = true) {
        assertPhysicalActivity(compose.activity)
        check(view.hasWindowFocus())
        val now = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, now + if (action == MotionEvent.ACTION_UP) 1 else 0, action, x, y, 0)
            try {
                val handled = view.dispatchTouchEvent(event)
                if (assertHandled) assertTrue(handled)
            } finally { event.recycle() }
        }
    }

    private fun <T> ui(read: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return read()
        var result: Result<T>? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { result = runCatching(read) }
        return checkNotNull(result).getOrThrow()
    }

    private fun dispose(bitmap: Bitmap) {
        try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
        finally { bitmap.recycle() }
    }

    private class RetentionLoadGate {
        val entered = java.util.concurrent.CountDownLatch(1)
        val released = java.util.concurrent.CountDownLatch(1)
    }
    private class RetentionControl {
        var image by mutableStateOf(InlineImage("Controlled retained A.png", widthPx = 120, heightPx = 90,
            border = true, alt = "Aligned object", verticalAlign = InlineImageVerticalAlign.Baseline))
        var settings by mutableStateOf(AppSettings(allowImages = false, allowAudio = false, mediaCacheMb = 0))
        var density by mutableStateOf(1f)
        var sourceOwner by mutableStateOf<Any>(Any())
        var owner: InlineImageViewOwner? = null
        var layout: TextLayoutResult? = null
        var fallbackFace: Typeface? = null
        val rasterFocus = androidx.compose.ui.focus.FocusRequester()
        val actions = CopyOnWriteArrayList<EntryLink>()
        val onAction: (EntryLink) -> Unit = { actions += it }
    }
    private data class RetentionSnapshot(val image: RectF, val following: RectF, val baseline: Float,
        val width: Int, val height: Int, val text: String)

    @Composable private fun RetentionScene(native: Boolean, control: RetentionControl, cache: MediaCache) {
        CompositionLocalProvider(LocalDensity provides Density(control.density, 1f),
            LocalLayoutDirection provides LayoutDirection.Ltr, LocalInlineImageCache provides cache,
            LocalMissingLinkOwner provides control.sourceOwner) {
            MaterialTheme(typography = Typography(bodyLarge = style)) {
                val occurrence = control.image
                val items = remember(occurrence.file) { listOf(Media(occurrence.file, "image", "")) }
                val owner = rememberInlineImageViewOwner(listOf(occurrence), items, control.settings, "en")
                val face by LocalFontFamilyResolver.current.resolve(
                    FontFamily.Monospace, FontWeight.Normal, FontStyle.Normal, FontSynthesis.All)
                SideEffect { control.owner = owner; control.fallbackFace = face as Typeface }
                CompositionLocalProvider(LocalInlineImageOwner provides owner) {
                    val source = remember(occurrence) { spans(occurrence).mapIndexed { index, span ->
                        if (index == 2) span.copy(fontScale = 1.5f) else span
                    } }
                    val annotated = styledTextAnnotation(source, null, style, control.onAction)
                    if (native) {
                        val prepared = prepareNativeFloatText(source, annotated, emptyList(), style, Color.Blue,
                            items, control.settings, "en", control.onAction, ownerDirection = BidiResolvedDirection.Ltr)
                        Box(Modifier.width(320.dp).background(Color.White).testTag("retained-native")) {
                            NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f)),
                                Modifier.width(320.dp), Color.Blue,
                                child = { _, _ -> error("No delegated child in retained image control") })
                        }
                    } else {
                        val inline = compiledInlineImageContent(source, annotated, style,
                            items, control.settings, "en", control.onAction, Color.Gray)
                        Text(annotated, style = style, inlineContent = inline,
                            modifier = Modifier.width(320.dp).background(Color.White).testTag("retained-compose")
                                .focusRequester(control.rasterFocus).focusable(),
                            onTextLayout = { control.layout = it })
                    }
                }
            }
        }
    }

    private fun retentionSnapshot(native: Boolean, control: RetentionControl): RetentionSnapshot {
        if (native) return ui {
            val geometry = checkNotNull(checkNotNull(imageViewOrNull()).currentMeasuredGeometry)
            val image = geometry.nodes.single { it.kind == FloatInteractionKind.IMAGE }
            assertEquals(2, image.start); assertEquals(3, image.end)
            RetentionSnapshot(RectF(image.bounds.single()),
                RectF(checkNotNull(geometry.characterRects(geometry.text.length - 1, 1).single())),
                checkNotNull(geometry.textBaselines?.first), geometry.width, geometry.height, geometry.text.toString())
        }
        val layout = ui { checkNotNull(control.layout) }
        val image = compose.onNodeWithContentDescription(label, useUnmergedTree = true).fetchSemanticsNode()
        val host = compose.onNodeWithTag("retained-compose").fetchSemanticsNode()
        val at = image.positionInWindow - host.positionInWindow
        val following = layout.getBoundingBox(layout.layoutInput.text.length - 1)
        return RetentionSnapshot(RectF(at.x, at.y, at.x + image.size.width, at.y + image.size.height),
            RectF(following.left, following.top, following.right, following.bottom), layout.firstBaseline,
            layout.size.width, layout.size.height, layout.layoutInput.text.text)
    }
    private fun assertRetentionGeometry(expected: RetentionSnapshot, actual: RetentionSnapshot) {
        assertRectEquals(expected.image, actual.image); assertRectEquals(expected.following, actual.following)
        assertEquals(expected.baseline, actual.baseline, 0.01f)
        assertEquals(expected.width, actual.width); assertEquals(expected.height, actual.height)
        assertEquals("M \uFFFC \u05d0", actual.text); assertEquals(expected.text, actual.text)
    }
    private fun awaitRetention(control: RetentionControl, state: String) {
        compose.waitUntil(5000) { ui {
            val current = control.owner?.states?.get(inlineImageAssetKey(control.image))
            when (state) {
                "Ready" -> current is InlineImageAssetState.Ready
                "Disabled" -> current == InlineImageAssetState.Disabled
                "Loading" -> current == InlineImageAssetState.Loading
                "Failed" -> current == InlineImageAssetState.Failed
                else -> error("Unknown control state")
            }
        } }
        compose.waitForIdle()
    }
    private fun assertRetentionAction(native: Boolean, control: RetentionControl, state: String) {
        val status = when (state) {
            "Ready" -> ""
            "Disabled" -> "Images disabled"
            "Loading" -> "Loading image"
            "Failed" -> "Image unavailable"
            else -> error("Unknown control state")
        }
        if (native) ui {
            val view = checkNotNull(imageViewOrNull())
            val geometry = checkNotNull(view.currentMeasuredGeometry)
            val node = geometry.nodes.single { it.kind == FloatInteractionKind.IMAGE }
            val box = node.bounds.single()
            assertEquals(label, node.label.toString()); assertNotNull(node.onClick)
            assertRectEquals(box, geometry.rectsForRange(2, 3).single())
            assertRectEquals(box, checkNotNull(geometry.characterRects(2, 1).single()))
            view.setSelection(0, geometry.text.length)
            assertEquals("M \uFFFC \u05d0", view.selectedTextForCopy())
            view.setSelection(2, 3); assertEquals("\uFFFC", view.selectedTextForCopy())
            val provider = view.accessibilityNodeProvider
            val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
            try {
                assertEquals(label, info.contentDescription.toString()); assertEquals(status, info.stateDescription?.toString().orEmpty())
                assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
                val screen = IntArray(2).also(view::getLocationOnScreen)
                val expected = AndroidRect()
                RectF(box).apply { offset(screen[0] + view.paddingLeft.toFloat(), screen[1] + view.paddingTop.toFloat()) }.roundOut(expected)
                assertEquals(expected, AndroidRect().also(info::getBoundsInScreen))
            } finally { info.recycle() }
            val before = control.actions.size
            assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
            assertEquals(before + 1, control.actions.size); assertEquals(target, control.actions.last())
            assertTrue(provider.performAction(View.NO_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
            tap(view, view.paddingLeft + box.centerX(), view.paddingTop + box.centerY())
            assertEquals(before + 2, control.actions.size); assertEquals(target, control.actions.last())
        } else {
            val image = compose.onNodeWithContentDescription(label, useUnmergedTree = true)
                .assertIsDisplayed().assertHasClickAction()
            val semantics = image.fetchSemanticsNode().config
            assertEquals(Role.Image, semantics.getOrNull(SemanticsProperties.Role))
            assertEquals(status, semantics.getOrNull(SemanticsProperties.StateDescription).orEmpty())
            val before = control.actions.size
            image.performTouchInput { click() }
            compose.runOnIdle { assertEquals(before + 1, control.actions.size); assertEquals(target, control.actions.last()) }
            assertEquals("M \uFFFC \u05d0", ui { checkNotNull(control.layout).layoutInput.text.text })
        }
    }
    private fun retryRetention(native: Boolean) {
        if (native) ui {
            val view = checkNotNull(imageViewOrNull())
            val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
            assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_LONG_CLICK, null))
        } else compose.onNodeWithContentDescription(label, useUnmergedTree = true)
            .performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnLongClick) { assertTrue(it()) }
        compose.onNodeWithText("Retry image").assertIsDisplayed().performClick()
    }
    private fun prepareRetentionRasterFocus(control: RetentionControl) {
        // Baseline image pixels are intentionally unfocused; keyboard-focus painting is a separate phase.
        val image = compose.onNodeWithContentDescription(label, useUnmergedTree = true)
        if (image.fetchSemanticsNode().config.getOrNull(SemanticsProperties.Focused) == true) {
            compose.runOnIdle {
                assertTrue("The owned text host accepts raster-phase focus",
                    control.rasterFocus.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter))
            }
            compose.onNodeWithTag("retained-compose").assertIsFocused()
            image.assertIsNotFocused()
        }
    }
    private fun settleRetentionRipple() {
        check(Looper.myLooper() != Looper.getMainLooper())
        compose.waitForIdle()
        val image = compose.onNodeWithContentDescription(label, useUnmergedTree = true).fetchSemanticsNode()
        check(image.config.getOrNull(SemanticsProperties.Focused) != true) { "Unexpected focused image feedback" }
        val activity = compose.activity
        val host = ui { checkNotNull(activity.findViewById<ViewGroup>(android.R.id.content)) }
        fun ripples(): List<Pair<View, android.graphics.drawable.RippleDrawable>> {
            val found = mutableListOf<Pair<View, android.graphics.drawable.RippleDrawable>>()
            fun visit(view: View) {
                (view.background as? android.graphics.drawable.RippleDrawable)?.let { found += view to it }
                if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
            check(host.isAttachedToWindow && host.isShown && host.isHardwareAccelerated)
            visit(host)
            return found
        }
        val owned = ui { ripples().also { check(it.isNotEmpty()) { "Expected the clicked image's native ripple" } } }
        fun released(): Boolean {
            check(owned.none { (_, drawable) ->
                android.R.attr.state_focused in drawable.state || android.R.attr.state_hovered in drawable.state
            }) { "Unexpected focused or hovered native ripple feedback" }
            return owned.none { (_, drawable) -> android.R.attr.state_pressed in drawable.state }
        }
        compose.waitUntil(5000) { ui { check(ripples() == owned); released() } }
        fun committedFrame(settle: Boolean) {
            val done = java.util.concurrent.CountDownLatch(1)
            val callback = Runnable { done.countDown() }
            var observer: android.view.ViewTreeObserver? = null
            var registered = false
            var primary: Throwable? = null
            try {
                ui {
                    check(ripples() == owned && released())
                    observer = host.viewTreeObserver
                    checkNotNull(observer).registerFrameCommitCallback(callback)
                    registered = true
                    for ((_, drawable) in owned) {
                        if (settle) drawable.jumpToCurrentState()
                        drawable.invalidateSelf()
                    }
                    host.invalidate()
                }
                check(done.await(5, java.util.concurrent.TimeUnit.SECONDS)) { "Owned ripple frame did not commit" }
            } catch (failure: Throwable) {
                primary = failure
                throw failure
            } finally {
                try {
                    if (registered && done.count != 0L) {
                        val removed = ui { observer?.takeIf { it.isAlive }?.unregisterFrameCommitCallback(callback) == true }
                        if (!removed) check(done.await(1, java.util.concurrent.TimeUnit.SECONDS)) {
                            "Submitted owned ripple frame callback did not finish"
                        }
                    }
                } catch (cleanup: Throwable) {
                    if (primary == null) throw cleanup else if (cleanup !== primary) primary.addSuppressed(cleanup)
                }
            }
        }
        // A normal draw consumes deferred native ripple exit work before its animations are finished.
        committedFrame(settle = false)
        committedFrame(settle = true)
        compose.waitForIdle()
        ui { check(ripples() == owned && released()) }
    }
    private data class RetentionPaint(val width: Int, val height: Int, val pixels: IntArray, val content: RectF)
    private fun assertRetentionRaster(native: Boolean, control: RetentionControl, ready: Boolean,
        color: Int = AndroidColor.RED, reference: RetentionPaint? = null,
        cssWidth: Float = 120f, cssHeight: Float = 61f): RetentionPaint {
        if (!native) { prepareRetentionRasterFocus(control); settleRetentionRipple() }
        val host = compose.onNodeWithTag(if (native) "retained-native" else "retained-compose")
        val hostPosition = host.fetchSemanticsNode().positionInWindow
        val origin = if (native) ui {
            val view = checkNotNull(imageViewOrNull())
            val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
            val location = IntArray(2).also(view::getLocationInWindow)
            Offset(location[0] + view.paddingLeft + node.bounds.single().left - hostPosition.x,
                location[1] + view.paddingTop + node.bounds.single().top - hostPosition.y)
        } else compose.onNodeWithContentDescription(label, useUnmergedTree = true).fetchSemanticsNode()
            .positionInWindow - hostPosition
        val density = ui { control.density }
        // The source's one-CSS-pixel border surrounds independently known used content axes.
        val content = RectF(origin.x + density, origin.y + density,
            origin.x + (cssWidth + 1f) * density, origin.y + (cssHeight + 1f) * density)
        val bitmap = host.captureToImage().asAndroidBitmap()
        var failurePixels: IntArray? = null
        try {
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            failurePixels = pixels
            assertTrue("The actual source image keeps its authored border", pixels.any { it == 0xffeaecf0.toInt() })
            if (ready) assertTrue("Ready paints controlled decoded pixels", pixels.count { it == color } > 100)
            else assertFalse("Unavailable pixels are not retained as a stale bitmap", pixels.any { it == AndroidColor.RED || it == AndroidColor.GREEN })
            reference?.let { previous ->
                assertEquals(previous.width, bitmap.width); assertEquals(previous.height, bitmap.height)
                assertRectEquals(previous.content, content)
                for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                    // Exclude pixels intersecting content, including its fractional edge coverage.
                    if (x + 1 <= content.left || x >= content.right || y + 1 <= content.top || y >= content.bottom) {
                        val index = y * bitmap.width + x
                        assertEquals("Only pixels inside the retained image content may change at $x,$y",
                            previous.pixels[index], pixels[index])
                    }
                }
            }
            return RetentionPaint(bitmap.width, bitmap.height, pixels, content)
        } catch (failure: Throwable) {
            // Export this exact failed owned capture; do not recapture or settle input feedback.
            try {
                val observed = failurePixels ?: IntArray(0)
                val layout = runCatching { ui { control.layout } }.getOrNull()
                val name = if (native) "inline-image-retention-native-failure.png" else "inline-image-retention-compose-failure.png"
                val border = 0xffeaecf0.toInt()
                val closestOpaqueBorder = observed.asSequence().filter { it ushr 24 == 255 }.map { pixel ->
                    kotlin.math.abs((pixel ushr 16 and 255) - 234) +
                        kotlin.math.abs((pixel ushr 8 and 255) - 236) + kotlin.math.abs((pixel and 255) - 240)
                }.minOrNull()
                val details = "OWNED_IMAGE_RETENTION_FAILURE native=$native ready=$ready density=$density" +
                    " hostWindow=$hostPosition imageOrigin=$origin content=$content cssContent=${cssWidth}x$cssHeight" +
                    " bitmap=${bitmap.width}x${bitmap.height} config=${bitmap.config} colorSpace=${bitmap.colorSpace?.name}" +
                    " exactBorder=${observed.count { it == border }} exactRed=${observed.count { it == AndroidColor.RED }}" +
                    " exactGreen=${observed.count { it == AndroidColor.GREEN }} exactWhite=${observed.count { it == AndroidColor.WHITE }}" +
                    " opaque=${observed.count { it ushr 24 == 255 }} transparent=${observed.count { it ushr 24 == 0 }}" +
                    " closestOpaqueBorderRgbDistance=$closestOpaqueBorder placeholders=${layout?.placeholderRects?.take(4)}" +
                    " referenceContent=${reference?.content}"
                val evidence = renderedLayoutFailureEvidence("inline-image-retention-raster-failure", layout, null,
                    host, name, capturedBitmap = bitmap)
                val report = "\n$details\n$evidence\n"
                check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
                androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().sendStatus(0,
                    android.os.Bundle().apply { putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, report) })
            } catch (observation: Throwable) {
                if (observation !== failure) failure.addSuppressed(observation)
            }
            throw failure
        } finally { bitmap.recycle() }
    }

    @Test fun composeKnownImageGeometrySurvivesAvailabilityAndDensityButResetsForANewSource() =
        exerciseImageGeometryRetention(native = false)

    @Test fun nativeKnownImageGeometryKeepsSelectionAndActionsAndNeverBorrowsAnotherAssetRatio() =
        exerciseImageGeometryRetention(native = true)

    private fun exerciseImageGeometryRetention(native: Boolean) {
        val control = RetentionControl()
        val directory = java.io.File(compose.activity.cacheDir, "image-geometry-${java.util.UUID.randomUUID()}")
            .apply { check(mkdirs()) }
        fun png(width: Int, height: Int, color: Int): ByteArray {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            return try {
                bitmap.eraseColor(color)
                java.io.ByteArrayOutputStream().use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)); output.toByteArray()
                }
            } finally { bitmap.recycle() }
        }
        val original = png(310, 157, AndroidColor.RED)
        val alternate = png(90, 240, AndroidColor.GREEN)
        val corrupt = java.util.concurrent.atomic.AtomicBoolean(false)
        val currentGate = java.util.concurrent.atomic.AtomicReference<RetentionLoadGate?>(null)
        val gates = CopyOnWriteArrayList<RetentionLoadGate>()
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val cache = MediaCache(compose.activity, directory = directory, metadata = { request ->
            check(Looper.myLooper() != Looper.getMainLooper())
            requests.incrementAndGet()
            currentGate.get()?.let { gate ->
                gate.entered.countDown()
                check(gate.released.await(10, java.util.concurrent.TimeUnit.SECONDS)) { "Controlled image IO gate timed out" }
            }
            val other = java.net.URLDecoder.decode(request, "UTF-8").contains("Controlled retained B.png")
            val width = if (other) 90 else 310; val height = if (other) 240 else 157
            val name = if (other) "b" else "a"
            """{"query":{"pages":[{"imageinfo":[{"url":"https://example.test/retained-$name.png","width":$width,"height":$height,"mime":"image/png"}]}]}}""".encodeToByteArray()
        }, openMedia = { url ->
            check(url == "https://example.test/retained-a.png" || url == "https://example.test/retained-b.png")
            java.io.ByteArrayInputStream(if (corrupt.get()) byteArrayOf(1, 2, 3)
                else if (url.endsWith("-b.png")) alternate else original)
        })
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { RetentionScene(native, control, cache) } }
            awaitRetention(control, "Disabled")
            val unknown = retentionSnapshot(native, control)
            assertEquals(0, requests.get())
            assertTrue("Unknown alt geometry differs from the later known 63px outer height", kotlin.math.abs(unknown.image.height() - 63f) > 5f)
            assertRetentionAction(native, control, "Disabled")
            compose.runOnIdle { control.settings = control.settings.copy(allowImages = true) }
            awaitRetention(control, "Ready")
            val ready = retentionSnapshot(native, control)
            assertEquals(122f, ready.image.width(), 1f); assertEquals(63f, ready.image.height(), 1f)
            ui {
                val fallbackPaint = TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                    typeface = checkNotNull(control.fallbackFace); textSize = 36f
                }
                val naturalAlt = android.text.StaticLayout.Builder.obtain(label, 0, label.length,
                    fallbackPaint, 120).setIncludePad(true).build()
                assertTrue("The unchanged full alt exceeds the known content height before clipping", naturalAlt.height > 61)
            }
            val firstOwner = ui { checkNotNull(control.owner) }
            ui {
                val state = checkNotNull(control.owner).states[inlineImageAssetKey(control.image)] as InlineImageAssetState.Ready
                assertEquals(310L, state.originalWidth); assertEquals(157L, state.originalHeight); assertEquals("image/png", state.mime)
            }
            assertRetentionAction(native, control, "Ready")
            val readyPaint = assertRetentionRaster(native, control, true)

            compose.runOnIdle { control.settings = control.settings.copy(allowImages = false, mediaCacheMb = 1) }
            awaitRetention(control, "Disabled")
            assertNotSame(firstOwner, ui { control.owner })
            assertRetentionGeometry(ready, retentionSnapshot(native, control))
            assertRetentionAction(native, control, "Disabled"); assertRetentionRaster(native, control, false, reference = readyPaint)
            val disabledOwner = ui { control.owner }
            val gate = RetentionLoadGate().also { gates += it; currentGate.set(it) }
            corrupt.set(true)
            compose.runOnIdle { control.settings = control.settings.copy(allowImages = true) }
            // Drive the v2 composition scheduler until the real metadata callback enters its gate.
            compose.waitUntil(5000) { gate.entered.count == 0L }
            assertTrue(gate.entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            awaitRetention(control, "Loading")
            assertNotSame(disabledOwner, ui { control.owner })
            assertRetentionGeometry(ready, retentionSnapshot(native, control))
            assertRetentionAction(native, control, "Loading"); assertRetentionRaster(native, control, false, reference = readyPaint)
            currentGate.set(null); gate.released.countDown()
            awaitRetention(control, "Failed")
            assertRetentionGeometry(ready, retentionSnapshot(native, control))
            assertRetentionAction(native, control, "Failed"); assertRetentionRaster(native, control, false, reference = readyPaint)
            // Corrupt bytes were cached before decoding: the real Retry must bypass that entry.
            assertTrue(directory.listFiles().orEmpty().any { it.extension == "bin" && it.length() == 3L })
            corrupt.set(false); retryRetention(native)
            awaitRetention(control, "Ready")
            assertRetentionGeometry(ready, retentionSnapshot(native, control)); assertRetentionRaster(native, control, true)

            val beforeDensity = ui { control.owner }
            compose.runOnIdle {
                control.settings = control.settings.copy(allowImages = false, mediaCacheMb = 2)
                control.density = 1.25f
            }
            awaitRetention(control, "Disabled")
            val scaled = retentionSnapshot(native, control)
            assertNotSame(beforeDensity, ui { control.owner })
            assertEquals(152.5f, scaled.image.width(), 1f); assertEquals(78.75f, scaled.image.height(), 1f)
            assertRetentionAction(native, control, "Disabled")
            val scaledUnavailablePaint = assertRetentionRaster(native, control, false)
            compose.runOnIdle { control.settings = control.settings.copy(allowImages = true) }
            awaitRetention(control, "Ready")
            assertRetentionGeometry(scaled, retentionSnapshot(native, control))
            assertRetentionRaster(native, control, true, reference = scaledUnavailablePaint)

            val previousOwner = ui { control.owner }
            compose.runOnIdle {
                control.settings = control.settings.copy(allowImages = false)
                control.density = 1f
                if (native) control.image = control.image.copy(file = "Controlled retained B.png")
                else control.sourceOwner = Any()
            }
            awaitRetention(control, "Disabled")
            assertNotSame(previousOwner, ui { control.owner })
            assertRetentionGeometry(unknown, retentionSnapshot(native, control))
            assertRetentionAction(native, control, "Disabled")
            if (native) {
                // This asset has never been Ready. Valid metadata precedes its deliberately failed decode.
                corrupt.set(true)
                compose.runOnIdle { control.settings = control.settings.copy(allowImages = true) }
                awaitRetention(control, "Failed")
                val alternateFailure = retentionSnapshot(native, control)
                assertEquals(35f, alternateFailure.image.width(), 1f); assertEquals(92f, alternateFailure.image.height(), 1f)
                assertRetentionAction(native, control, "Failed")
                val alternateUnavailablePaint = assertRetentionRaster(native, control, false, cssWidth = 33f, cssHeight = 90f)
                corrupt.set(false); retryRetention(native); awaitRetention(control, "Ready")
                assertRetentionGeometry(alternateFailure, retentionSnapshot(native, control))
                assertRetentionAction(native, control, "Ready"); assertRetentionRaster(native, control, true, AndroidColor.GREEN, reference = alternateUnavailablePaint, cssWidth = 33f, cssHeight = 90f)
            } else {
                compose.runOnIdle { control.settings = control.settings.copy(allowImages = true) }
                awaitRetention(control, "Ready")
                assertRetentionGeometry(ready, retentionSnapshot(native, control))
                assertRetentionAction(native, control, "Ready"); assertRetentionRaster(native, control, true)
            }
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            gates.forEach { it.released.countDown() }
            var cleanupFailure: Throwable? = null
            fun cleanup(action: () -> Unit) {
                try { action() } catch (failure: Throwable) {
                    val previous = cleanupFailure
                    if (previous == null) cleanupFailure = failure else if (previous !== failure) previous.addSuppressed(failure)
                }
            }
            cleanup { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            // Clear only this fixture cache after releasing all controlled IO and disposing its owner.
            cleanup { kotlinx.coroutines.runBlocking { cache.clear() } }
            cleanup { check(directory.deleteRecursively()) }
            cleanupFailure?.let { failure ->
                val originalFailure = primary
                if (originalFailure == null) throw failure
                if (originalFailure !== failure) originalFailure.addSuppressed(failure)
            }
        }
    }


    // Synthetic R policy only; these controls do not establish source-issued MG anchor provenance.
    private fun imageFocusPolicy(outline: Boolean): LinkPaint {
        val colors = listOf("#123456", "#227744", "#aa5500", "#8822aa", "#6655aa", "#008888", "#993333", "#667700")
        val states = colors.mapIndexed { index, color -> FigureLinkState(color, index % 2 == 0) }
        return LinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], states[6], states[7],
            underlineOnFocus = true, focusOutline = if (outline) FigureFocusOutline(
                StyleLength(StyleLengthUnit.Px, 2f), FigureColor.Rgb("#ff00ff"),
                StyleLength(StyleLengthUnit.Px, 3f), SignedContainerMargin(StyleLengthUnit.Px, 2f)) else null)
    }
    private fun imageFocusSpans(occurrence: InlineImage, policy: LinkPaint?) = spans(occurrence).mapIndexed { index, span ->
        if (index != 2) span else span.copy(targetFragment = "image-fragment", foreground = policy?.normal?.foreground,
            underline = policy?.normal?.underline ?: false, linkPaint = policy)
    }
    private fun imageFocusView(): NativeFloatTextView {
        check(Looper.myLooper() == Looper.getMainLooper())
        val found = mutableListOf<NativeFloatTextView>()
        fun visit(view: View) {
            if (view is NativeFloatTextView && view.isShown && view.currentMeasuredGeometry?.nodes?.any {
                    it.kind == FloatInteractionKind.IMAGE && it.onClick != null } == true) found += view
            if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(compose.activity.window.decorView)
        return found.single()
    }
    private fun imageFocusNode(view: NativeFloatTextView): FloatInteractionNode {
        val geometry = checkNotNull(view.currentMeasuredGeometry)
        assertEquals("M \uFFFC \u05d0", geometry.text.toString())
        assertEquals(1, geometry.nodes.size)
        return geometry.nodes.single().also {
            assertEquals(FloatInteractionKind.IMAGE, it.kind); assertEquals(2, it.start); assertEquals(3, it.end)
            assertNull("IMAGE must retain immediate Enter rather than a text-link key owner", it.missingLinkPaint)
            assertNotNull(it.onClick); assertNotNull(it.onLongClick)
            assertEquals("Open image link: Controlled alignment.png", it.label.toString())
        }
    }
    private data class ImageFocusPixels(val width: Int, val height: Int, val pixels: IntArray) {
        fun count(color: Int) = pixels.count { it == color }
        fun at(x: Int, y: Int) = pixels[y * width + x]
    }
    private fun imageFocusPixels(tag: String,
        verify: ((ImageFocusPixels, Bitmap) -> Unit)? = null): ImageFocusPixels {
        val bitmap = compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
        return try {
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            val result = ImageFocusPixels(bitmap.width, bitmap.height, pixels)
            verify?.invoke(result, bitmap)
            result
        } finally { bitmap.recycle() }
    }
    private fun assertImageFocusBody(expected: ImageFocusPixels, actual: ImageFocusPixels) {
        assertEquals(expected.width, actual.width); assertEquals(expected.height, actual.height)
        val red = expected.pixels.indices.filter { expected.pixels[it] == AndroidColor.RED }
        assertTrue(red.size >= 18 * 18)
        val left = red.minOf { it % expected.width }; val right = red.maxOf { it % expected.width }
        val top = red.minOf { it / expected.width }; val bottom = red.maxOf { it / expected.width }
        // The legacy UA stroke may cover edge pixels at the device's native density.
        val interior = red.filter { it % expected.width in (left + 2)..(right - 2) &&
            it / expected.width in (top + 2)..(bottom - 2) }
        assertTrue(interior.size > 150)
        interior.forEach { assertEquals("Authored glyph colors/underline cannot tint bitmap pixel $it", expected.pixels[it], actual.pixels[it]) }
    }
    private fun imageFocusPointer(view: NativeFloatTextView, action: Int, x: Float, y: Float,
        downTime: Long = SystemClock.uptimeMillis()): Boolean {
        assertPhysicalActivity(compose.activity); check(view.hasWindowFocus())
        val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x + view.paddingLeft, y + view.paddingTop, 0)
        event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
        return try { view.dispatchTouchEvent(event) } finally { event.recycle() }
    }
    private fun imageFocusKey(view: NativeFloatTextView, action: Int, code: Int) =
        view.dispatchKeyEvent(android.view.KeyEvent(action, code))
    private fun imageInputFocus(view: NativeFloatTextView) {
        val node = imageFocusNode(view)
        assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
        assertTrue(view.hasFocus())
        val focused = checkNotNull(view.accessibilityNodeProvider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT))
        try { assertEquals(node.label.toString(), focused.contentDescription.toString()) } finally { focused.recycle() }
    }
    private fun checkImageFocusSelection(view: NativeFloatTextView) {
        val geometry = checkNotNull(view.currentMeasuredGeometry); val node = imageFocusNode(view)
        assertEquals(20f, node.bounds.single().width(), .01f); assertEquals(22f, node.bounds.single().height(), .01f)
        assertRectEquals(node.bounds.single(), geometry.rectsForRange(2, 3).single())
        assertRectEquals(node.bounds.single(), checkNotNull(geometry.characterRects(2, 1).single()))
        view.setSelection(2, 3); assertEquals("\uFFFC", view.selectedTextForCopy())
        view.setSelection(0, geometry.text.length); assertEquals("M \uFFFC \u05d0", view.selectedTextForCopy())
        assertTrue(view.accessibilityNodeProvider.performAction(View.NO_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
    }

    @Test fun imageSourceFocusModesPreserveBitmapImmediateActivationAndAlignedOwnerAcrossRemeasure() {
        val bitmap = redBitmap()
        val rasterFocus = androidx.compose.ui.focus.FocusRequester()
        val actions = CopyOnWriteArrayList<EntryLink>()
        val callback: (EntryLink) -> Unit = { actions += it }
        val expectedAction = EntryLink(target.target, targetFragment = "image-fragment")
        val modes = listOf<LinkPaint?>(null, imageFocusPolicy(false), imageFocusPolicy(true))
        var mode by mutableStateOf(0)
        var width by mutableStateOf(320)
        var alignment by mutableStateOf<InlineImageVerticalAlign?>(InlineImageVerticalAlign.Baseline)
        var emOutline by mutableStateOf(false)
        var normalBodySize by mutableStateOf(24)
        var font: Typeface? = null
        var releaseAfterResize: (() -> Unit)? = null
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides LayoutDirection.Ltr) {
                    MaterialTheme(typography = Typography(bodyLarge = style.copy(fontSize = normalBodySize.sp))) {
                        key(mode) {
                            val occurrence = remember(alignment) { image(alignment).copy(alt = null) }
                            ReadyImage(occurrence, bitmap, { font = it }) {
                                val selectedPolicy = remember(mode, emOutline) {
                                    if (mode == 2 && emOutline) imageFocusPolicy(true).copy(focusOutline = FigureFocusOutline(
                                        StyleLength(StyleLengthUnit.Em, .125f), FigureColor.Rgb("#ff00ff"),
                                        StyleLength(StyleLengthUnit.Em, .25f), SignedContainerMargin(StyleLengthUnit.Em, .0625f)))
                                    else modes[mode]
                                }
                                val source = remember(occurrence, selectedPolicy) { imageFocusSpans(occurrence, selectedPolicy) }
                                val annotation = styledTextAnnotation(source, null, style, callback)
                                val prepared = prepareNativeFloatText(source, annotation, emptyList(), style, Color.Blue,
                                    media, settings, "en", callback, ownerDirection = BidiResolvedDirection.Ltr)
                                Box(Modifier.width(width.dp).background(Color.White).testTag("image-focus-body")
                                    .focusRequester(rasterFocus).focusable()
                                    .onGloballyPositioned {
                                        if (width == 300) releaseAfterResize?.let { release ->
                                            releaseAfterResize = null; release()
                                        }
                                    }) {
                                    NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f)),
                                        Modifier.width(width.dp), Color.Blue,
                                        child = { _, _ -> error("No delegated focus fixture child") })
                                }
                            }
                        }
                    }
                }
            } }
            for (selected in modes.indices) {
                compose.runOnIdle { mode = selected; width = 320; alignment = InlineImageVerticalAlign.Baseline }
                compose.waitForIdle()
                compose.waitUntil(5000) { ui { runCatching { imageFocusNode(imageFocusView()); font != null }.getOrDefault(false) } }
                val view = ui { imageFocusView() }
                var rasterFocusRequested = false
                val original = ui {
                    val node = imageFocusNode(view)
                    assertEquals(selected != 0, node.sourceFocusVisible)
                    if (selected == 0) assertNull(node.focusPaint)
                    else if (selected == 1) assertSame(NativeNodeFocusPaint.None, node.focusPaint)
                    else {
                        val outline = checkNotNull(node.focusPaint).outlines().single()
                        assertRectEquals(node.bounds.single(), outline.bounds)
                        assertEquals(2f, outline.width, .01f); assertEquals(3f, outline.radius, .01f)
                        assertEquals(2f, outline.offset, .01f); assertEquals(AndroidColor.MAGENTA, outline.color)
                    }
                    checkImageFocusSelection(view)
                    view.clearFocus()
                    // clearFocus can return native host focus outside touch mode. The baseline
                    // excludes both the host ring and virtual image focus without changing input mode.
                    if (view.hasFocus()) {
                        assertTrue("The owned raster host accepts focus",
                            rasterFocus.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter))
                        rasterFocusRequested = true
                    }
                    val provider = view.accessibilityNodeProvider
                    assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                    assertFalse(view.hasFocus()); assertNull(provider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT))
                    RectF(node.bounds.single())
                }
                if (rasterFocusRequested) compose.onNodeWithTag("image-focus-body").assertIsFocused()
                val exploration = imageFocusPixels("image-focus-body")
                assertEquals(0, exploration.count(AndroidColor.MAGENTA))
                ui {
                    assertTrue(view.requestFocus())
                    assertTrue(imageFocusKey(view, android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_TAB))
                    imageFocusKey(view, android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_TAB)
                    assertRectEquals(original, imageFocusNode(view).bounds.single())
                }
                val keyboard = imageFocusPixels("image-focus-body")
                assertImageFocusBody(exploration, keyboard)
                if (selected == 1) assertArrayEquals(exploration.pixels, keyboard.pixels)
                else assertTrue("Default and authored focus must visibly paint", exploration.pixels.indices.any { exploration.pixels[it] != keyboard.pixels[it] })
                if (selected == 2) assertTrue(keyboard.count(AndroidColor.MAGENTA) > 8)
                ui {
                    val before = actions.size
                    assertTrue(imageFocusKey(view, android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER))
                    assertEquals(before + 1, actions.size); assertEquals(expectedAction, actions.last())
                    imageFocusKey(view, android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER)
                    assertEquals(before + 1, actions.size)
                    val node = imageFocusNode(view); val bounds = node.bounds.single()
                    val hover = MotionEvent.obtain(0, SystemClock.uptimeMillis(), MotionEvent.ACTION_HOVER_ENTER,
                        bounds.centerX() + view.paddingLeft, bounds.centerY() + view.paddingTop, 0)
                    hover.source = android.view.InputDevice.SOURCE_MOUSE
                    try { view.dispatchGenericMotionEvent(hover) } finally { hover.recycle() }
                }
                assertImageFocusBody(exploration, imageFocusPixels("image-focus-body"))
                ui {
                    assertTrue(imageFocusPointer(view, MotionEvent.ACTION_DOWN, original.centerX(), original.centerY()))
                    // Capture pointer modality without leaving a real long-press timer pending.
                    view.cancelPendingInputEvents()
                }
                val pointer = imageFocusPixels("image-focus-body")
                assertImageFocusBody(exploration, pointer)
                if (selected != 0) assertArrayEquals("Pointer modality must not paint an authored outline", exploration.pixels, pointer.pixels)
                if (selected == 0) ui {
                    val before = actions.size
                    assertTrue(imageFocusPointer(view, MotionEvent.ACTION_DOWN, original.centerX(), original.centerY()))
                    assertTrue(imageFocusPointer(view, MotionEvent.ACTION_UP, original.centerX(), original.centerY()))
                    assertEquals(before + 1, actions.size); assertEquals(expectedAction, actions.last())
                } else {
                    // Only authored images own the new stable callback contract. Deliver UP in
                    // the completed layout pass, before instrumentation/capture latency can long-press.
                    var released: Result<Unit>? = null
                    compose.runOnIdle {
                        val before = actions.size
                        val downTime = SystemClock.uptimeMillis()
                        releaseAfterResize = { released = runCatching {
                            assertSame(view, imageFocusView()); assertRectEquals(original, imageFocusNode(view).bounds.single())
                            assertTrue(imageFocusPointer(view, MotionEvent.ACTION_UP, original.centerX(), original.centerY(), downTime))
                            assertEquals(before + 1, actions.size); assertEquals(expectedAction, actions.last())
                            assertTrue(view.hasFocus())
                            val focused = checkNotNull(view.accessibilityNodeProvider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT))
                            try { assertEquals(imageFocusNode(view).label.toString(), focused.contentDescription.toString()) } finally { focused.recycle() }
                        } }
                        assertTrue(imageFocusPointer(view, MotionEvent.ACTION_DOWN, original.centerX(), original.centerY(), downTime))
                        width = 300
                    }
                    compose.waitUntil(5000) { ui { released != null } }
                    ui { checkNotNull(released).getOrThrow() }
                }
                compose.runOnIdle { width = 50 }
                compose.waitForIdle()
                ui {
                    assertSame(view, imageFocusView())
                    assertNotEquals(original, imageFocusNode(view).bounds.single())
                    imageInputFocus(view); checkImageFocusSelection(view)
                    assertEquals(1, checkNotNull(view.currentMeasuredGeometry).nodes.size)
                }
                if (selected == 2) {
                    compose.runOnIdle { width = 320; alignment = null }
                    compose.waitForIdle()
                    ui {
                        val current = imageFocusView(); imageInputFocus(current)
                        val geometry = checkNotNull(current.currentMeasuredGeometry)
                        val node = imageFocusNode(current); val rect = node.bounds.single()
                        val baseline = checkNotNull(geometry.textBaselines?.first)
                        assertEquals(expectedTop(baseline, xHeight(checkNotNull(font)), null), rect.top, .01f)
                        checkImageFocusSelection(current)
                        assertRectEquals(rect, checkNotNull(node.focusPaint).outlines().single().bounds)
                    }
                    assertTrue(imageFocusPixels("image-focus-body").count(AndroidColor.MAGENTA) > 8)
                }
            }
            // Only the normal-body em basis changes; the explicit24sp owner and source bitmap remain fixed.
            compose.runOnIdle { emOutline = true }
            compose.waitForIdle()
            val emView = ui { imageFocusView().also(::imageInputFocus) }
            val emBox = ui { RectF(imageFocusNode(emView).bounds.single()) }
            val beforeEm = imageFocusPixels("image-focus-body")
            ui {
                val outline = checkNotNull(imageFocusNode(emView).focusPaint).outlines().single()
                assertEquals(3f, outline.width, .01f); assertEquals(6f, outline.radius, .01f)
                assertEquals(1.5f, outline.offset, .01f)
            }
            compose.runOnIdle { normalBodySize = 32 }
            compose.waitForIdle()
            ui {
                assertSame(emView, imageFocusView()); assertTrue(emView.hasFocus())
                val node = imageFocusNode(emView); assertRectEquals(emBox, node.bounds.single())
                val outline = checkNotNull(node.focusPaint).outlines().single()
                assertEquals(4f, outline.width, .01f); assertEquals(8f, outline.radius, .01f)
                assertEquals(2f, outline.offset, .01f)
                val before = actions.size
                assertTrue(imageFocusKey(emView, android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER))
                imageFocusKey(emView, android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER)
                assertEquals(before + 1, actions.size); assertEquals(expectedAction, actions.last())
            }
            val afterEm = imageFocusPixels("image-focus-body")
            assertImageFocusBody(beforeEm, afterEm)
            assertTrue("Changed em outsets must repaint the actual outline", beforeEm.pixels.indices.any {
                beforeEm.pixels[it] != afterEm.pixels[it] &&
                    (beforeEm.pixels[it] == AndroidColor.MAGENTA || afterEm.pixels[it] == AndroidColor.MAGENTA)
            })
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            var cleanupFailure: Throwable? = null
            fun clean(action: () -> Unit) {
                try { action() } catch (failure: Throwable) {
                    val previous = cleanupFailure
                    if (previous == null) cleanupFailure = failure else if (previous !== failure) previous.addSuppressed(failure)
                }
            }
            clean { ui { releaseAfterResize = null } }
            clean { dispose(bitmap) }
            cleanupFailure?.let { cleanup ->
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }


    @Test fun authoredImageOutlineAndActionUseTheRealRoundedScrollportClipAfterPanAndResize() {
        val bitmap = redBitmap()
        val actions = CopyOnWriteArrayList<EntryLink>()
        val callback: (EntryLink) -> Unit = { actions += it }
        val expectedAction = EntryLink(target.target, targetFragment = "image-fragment")
        val occurrence = image(InlineImageVerticalAlign.Baseline).copy(alt = null)
        val policy = imageFocusPolicy(true)
        val source = imageFocusSpans(occurrence, policy)
        var rounded by mutableStateOf(false)
        var hostWidth by mutableStateOf(280)
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
        fun table(radius: Float): Table {
            val corners = TableCornerRadii(px(radius), px(radius), px(radius), px(radius))
            val outer = TableStyle(background = "#ffffff", border = StyleBorder.Solid(px(1f), "#777777"),
                padding = edges(0f), margins = edges(0f), width = StyleWidth(StyleWidthUnit.Percent, 100f),
                collapse = TableCollapse.Separate, cornerRadii = corners)
            val viewport = TableBlockViewport(639, outer.copy(collapse = null, margins = null,
                marginValues = ContainerMargins(ContainerMargin.Length(px(0f)), ContainerMargin.Auto,
                    ContainerMargin.Length(px(0f)), ContainerMargin.Auto), containingDirection = TableContainingDirection.Ltr),
                ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Px, 154.25f),
                TableStyle(collapse = TableCollapse.Collapse), TableContainingDirection.Ltr, "en")
            return Table(emptyList(), listOf(listOf(Cell(source, false, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = edges(0f), minWidth = px(300f))))),
                style = outer, blockViewport = viewport)
        }
        val square = table(0f); val curved = table(32f)
        fun content() = compose.onNodeWithTag("compiled-table-block-content", useUnmergedTree = true)
        fun border() = compose.onNodeWithTag("compiled-table-block-viewport", useUnmergedTree = true)
        fun axis() = checkNotNull(content().fetchSemanticsNode().config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange))
        fun panTo(value: Float) {
            val delta = value - axis().value()
            if (kotlin.math.abs(delta) > .01f)
                content().performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.ScrollBy) { assertTrue(it(delta, 0f)) }
            compose.waitForIdle()
        }
        data class PositionedImage(val view: NativeFloatTextView, val node: FloatInteractionNode,
            val origin: Offset, val raw: RectF, val frame: RectF, val padding: RectF)
        fun positioned(): PositionedImage {
            val hostAt = compose.onNodeWithTag("image-focus-clip").fetchSemanticsNode().positionInWindow
            val frameNode = border().fetchSemanticsNode()
            val frameAt = frameNode.positionInWindow - hostAt
            // Zero padding makes the legacy content clip meet the real padding arc; cap154.25 + border1 on both sides.
            val frame = RectF(frameAt.x, frameAt.y, frameAt.x + 156.25f, frameAt.y + frameNode.size.height)
            val padding = RectF(frame).apply { inset(1f, 1f) }
            val cellAt = compose.onNodeWithTag("compiled-table-cell-root/block-0-0", useUnmergedTree = true)
                .fetchSemanticsNode().positionInWindow - hostAt
            return ui {
                val view = imageFocusView(); val geometry = checkNotNull(view.currentMeasuredGeometry)
                val surface = (geometry as NativeSurfaceGeometry).surface
                val origin = Offset(cellAt.x + surface.left + view.paddingLeft, cellAt.y + surface.top + view.paddingTop)
                val node = imageFocusNode(view)
                val raw = RectF(node.bounds.single()).apply { offset(origin.x, origin.y) }
                assertEquals(20f, raw.width(), .01f); assertEquals(22f, raw.height(), .01f)
                PositionedImage(view, node, origin, raw, frame, padding)
            }
        }
        fun inArc(point: Offset, frame: RectF): Boolean {
            val radius = 32f * minOf(1f, frame.width() / 64f, frame.height() / 64f)
            val inner = (radius - 1f).coerceAtLeast(0f)
            val left = frame.left + radius; val right = frame.right - radius
            val top = frame.top + radius; val bottom = frame.bottom - radius
            val centerX = when { point.x < left -> left; point.x > right -> right; else -> return true }
            val centerY = when { point.y < top -> top; point.y > bottom -> bottom; else -> return true }
            val dx = point.x - centerX; val dy = point.y - centerY
            return dx * dx + dy * dy <= inner * inner
        }
        fun colored(pixels: ImageFocusPixels, color: Int, allowed: (Offset) -> Boolean): List<Offset> =
            pixels.pixels.indices.filter { pixels.pixels[it] == color }.map {
                Offset(it % pixels.width + .5f, it / pixels.width + .5f)
            }.filter(allowed)
        fun outsideArcPixel(point: Offset, frame: RectF): Boolean = listOf(-1f, 1f).all { dx ->
            listOf(-1f, 1f).all { dy -> !inArc(Offset(point.x + dx, point.y + dy), frame) }
        }
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalTableDocumentViewportCssWidth provides 639.0) {
                    MaterialTheme(typography = Typography(bodyLarge = style)) {
                        ReadyImage(occurrence, bitmap, {}) {
                            Box(Modifier.width(hostWidth.dp).background(Color.White).testTag("image-focus-clip")) {
                                NativeFloatBlockContext(listOf(Block("table", 0, emptyList(), table = if (rounded) curved else square)),
                                    callback, "image-focus-clip", Modifier, inCell = false, gridPath = "root",
                                    gapDp = 0f, trailingGap = false)
                            }
                        }
                    }
                }
            } }
            compose.waitUntil(5000) { ui { runCatching { imageFocusNode(imageFocusView()); true }.getOrDefault(false) } }
            ui { imageInputFocus(imageFocusView()) }
            compose.waitForIdle()
            val unpanned = positioned()
            assertTrue(axis().maxValue() > 80f)
            val desiredPan = unpanned.raw.left - unpanned.padding.left
            assertTrue(desiredPan > 0f && desiredPan < axis().maxValue())
            panTo(desiredPan)
            val actualPan = axis().value()
            val flat = positioned()
            assertEquals(-actualPan, flat.raw.left - unpanned.raw.left, .01f)
            val flatPixels = imageFocusPixels("image-focus-clip")
            val cutOutline = colored(flatPixels, AndroidColor.MAGENTA) { point ->
                flat.padding.contains(point.x, point.y) && outsideArcPixel(point, flat.frame)
            }
            assertTrue("A real focused source outline lies inside the rectangular clip but outside the padding arc", cutOutline.isNotEmpty())
            val cutImage = colored(flatPixels, AndroidColor.RED) { point ->
                flat.raw.contains(point.x, point.y) && flat.padding.contains(point.x, point.y) &&
                    outsideArcPixel(point, flat.frame)
            }
            assertTrue("The negative hit probe must have actual unclipped bitmap ink", cutImage.isNotEmpty())
            compose.runOnIdle { rounded = true }
            compose.waitForIdle()
            ui { imageInputFocus(imageFocusView()) }
            compose.waitForIdle(); panTo(actualPan)
            val clipped = positioned()
            assertRectEquals(flat.frame, clipped.frame); assertRectEquals(flat.raw, clipped.raw)
            val clippedPixels = imageFocusPixels("image-focus-clip") { clippedPixels, bitmap ->
                try {
                    cutOutline.forEach { assertNotEquals(AndroidColor.MAGENTA, clippedPixels.at(it.x.toInt(), it.y.toInt())) }
                    cutImage.forEach { assertNotEquals(AndroidColor.RED, clippedPixels.at(it.x.toInt(), it.y.toInt())) }
                } catch (failure: Throwable) {
                    // Borrow this exact failed owned capture before the helper recycles it.
                    try {
                        fun remaining(points: List<Offset>, color: Int) = points.filter {
                            clippedPixels.at(it.x.toInt(), it.y.toInt()) == color
                        }
                        val remainingOutline = remaining(cutOutline, AndroidColor.MAGENTA)
                        val remainingImage = remaining(cutImage, AndroidColor.RED)
                        val radius = 32f * minOf(1f, clipped.frame.width() / 64f, clipped.frame.height() / 64f)
                        val details = "OWNED_IMAGE_ROUNDED_CLIP_FAILURE pan=$actualPan hostWidth=$hostWidth" +
                            " sourceRadius=32 usedRadius=$radius innerRadius=${(radius - 1f).coerceAtLeast(0f)}" +
                            " flatFrame=${flat.frame} frame=${clipped.frame} padding=${clipped.padding}" +
                            " flatRaw=${flat.raw} raw=${clipped.raw} origin=${clipped.origin}" +
                            " nodeClip=${clipped.node.clipBounds}" +
                            " bitmap=${bitmap.width}x${bitmap.height} config=${bitmap.config} colorSpace=${bitmap.colorSpace?.name}" +
                            " cutOutline=${cutOutline.size} remainingOutline=${remainingOutline.size}" +
                            " outlinePoints=${remainingOutline.take(8)} cutImage=${cutImage.size}" +
                            " remainingImage=${remainingImage.size} imagePoints=${remainingImage.take(8)}" +
                            " exactRed=${clippedPixels.count(AndroidColor.RED)} exactMagenta=${clippedPixels.count(AndroidColor.MAGENTA)}"
                        val evidence = renderedLayoutFailureEvidence("inline-image-rounded-clip-failure", null, null,
                            compose.onNodeWithTag("image-focus-clip"), "inline-image-rounded-clip-failure.png",
                            capturedBitmap = bitmap)
                        val report = "\n$details\n$evidence\n"
                        check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
                        InstrumentationRegistry.getInstrumentation().sendStatus(0,
                            android.os.Bundle().apply { putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, report) })
                    } catch (observation: Throwable) {
                        if (observation !== failure) failure.addSuppressed(observation)
                    }
                    throw failure
                }
            }
            val retained = colored(clippedPixels, AndroidColor.RED) { clipped.raw.contains(it.x, it.y) &&
                clipped.padding.contains(it.x, it.y) && inArc(it, clipped.frame) }
            assertTrue("The same image still paints inside the real curved viewport", retained.isNotEmpty())
            assertTrue(clippedPixels.count(AndroidColor.MAGENTA) > 0)
            val outside = cutImage.first(); val inside = retained[retained.size / 2]
            val hostWindow = compose.onNodeWithTag("image-focus-clip").fetchSemanticsNode().positionInWindow
            ui {
                val node = imageFocusNode(clipped.view)
                assertTrue(node.contains(outside.x - clipped.origin.x, outside.y - clipped.origin.y))
                val before = actions.size
                assertFalse(imageFocusPointer(clipped.view, MotionEvent.ACTION_DOWN,
                    outside.x - clipped.origin.x, outside.y - clipped.origin.y))
                imageFocusPointer(clipped.view, MotionEvent.ACTION_UP, outside.x - clipped.origin.x, outside.y - clipped.origin.y)
                assertEquals(before, actions.size)
                checkImageFocusSelection(clipped.view)
                val provider = clipped.view.accessibilityNodeProvider
                val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                try {
                    assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
                    assertEquals(node.label.toString(), info.contentDescription.toString())
                    val decor = compose.activity.window.decorView
                    val screen = IntArray(2).also(decor::getLocationOnScreen)
                    val window = IntArray(2).also(decor::getLocationInWindow)
                    val dx = hostWindow.x + screen[0] - window[0]; val dy = hostWindow.y + screen[1] - window[1]
                    val actual = AndroidRect().also(info::getBoundsInScreen)
                    val rectangularLimit = RectF(clipped.raw).apply { assertTrue(intersect(clipped.padding)); offset(dx, dy) }
                    val limit = AndroidRect().also(rectangularLimit::roundOut)
                    assertTrue(limit.contains(actual)); assertFalse(actual.isEmpty)
                    assertTrue(actual.contains((inside.x + dx).toInt(), (inside.y + dy).toInt()))
                } finally { info.recycle() }
                assertTrue(imageFocusPointer(clipped.view, MotionEvent.ACTION_DOWN,
                    inside.x - clipped.origin.x, inside.y - clipped.origin.y))
                assertTrue(imageFocusPointer(clipped.view, MotionEvent.ACTION_UP,
                    inside.x - clipped.origin.x, inside.y - clipped.origin.y))
                assertEquals(before + 1, actions.size); assertEquals(expectedAction, actions.last())
                imageInputFocus(clipped.view)
            }
            // Same source, scroll offset and Ready/details capability through a real parent resize.
            panTo(actualPan)
            val beforeResize = positioned()
            compose.runOnIdle { hostWidth = 260 }
            compose.waitForIdle()
            val afterResize = positioned()
            assertSame(beforeResize.view, afterResize.view)
            assertEquals(actualPan, axis().value(), .01f)
            assertEquals(-10f, afterResize.raw.left - beforeResize.raw.left, .01f)
            assertEquals(beforeResize.raw.top, afterResize.raw.top, .01f)
            ui {
                assertTrue(afterResize.view.hasFocus())
                val focused = checkNotNull(afterResize.view.accessibilityNodeProvider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT))
                try { assertEquals(afterResize.node.label.toString(), focused.contentDescription.toString()) } finally { focused.recycle() }
                val before = actions.size
                assertTrue(imageFocusKey(afterResize.view, android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER))
                assertEquals(before + 1, actions.size); assertEquals(expectedAction, actions.last())
                imageFocusKey(afterResize.view, android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER)
                assertEquals(before + 1, actions.size)
            }
            assertTrue(imageFocusPixels("image-focus-clip").count(AndroidColor.MAGENTA) > 0)
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { dispose(bitmap) } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

}
