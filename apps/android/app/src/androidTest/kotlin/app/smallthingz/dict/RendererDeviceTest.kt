package app.smallthingz.dict

import androidx.compose.material.icons.outlined.PlayArrow

import androidx.activity.compose.setContent
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.*
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

internal fun renderedLayoutFailureEvidence(
    label: String,
    layout: androidx.compose.ui.text.TextLayoutResult?,
    semantic: androidx.compose.ui.semantics.SemanticsNode?,
    viewport: androidx.compose.ui.test.SemanticsNodeInteraction,
    imageName: String?,
    capturedBitmap: android.graphics.Bitmap? = null,
): String {
    val lines = layout?.let { measured ->
        (0 until minOf(measured.lineCount, 8)).joinToString("; ") { index ->
            "line[" + index + "]=" + listOf(measured.getLineLeft(index), measured.getLineRight(index),
                measured.getLineTop(index), measured.getLineBottom(index), measured.getLineBaseline(index)) +
                ",end=" + measured.getLineEnd(index) + ",ellipsis=" + measured.isLineEllipsized(index)
        }
    }.orEmpty()
    val details = "label=" + label.take(160) + "; layoutSize=" + layout?.size +
        "; constraints=" + layout?.layoutInput?.constraints + "; density=" + layout?.layoutInput?.density +
        "; fontSize=" + layout?.layoutInput?.style?.fontSize + "; lineHeight=" + layout?.layoutInput?.style?.lineHeight +
        "; overflowWidth=" + layout?.didOverflowWidth + "; overflowHeight=" + layout?.didOverflowHeight +
        "; paragraphHeight=" + layout?.multiParagraph?.height + "; lineCount=" + layout?.lineCount +
        "; rawPosition=" + semantic?.positionInRoot + "; rawSize=" + semantic?.size + "; " + lines
    val viewportDetails = runCatching {
        val v = viewport.fetchSemanticsNode()
        "; viewportPosition=${v.positionInRoot}; viewportSize=${v.size}; focused=" +
            semantic?.config?.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Focused)
    }.getOrElse { "; VIEWPORT_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
    if (imageName == null) return details + viewportDetails
    // Borrow an existing failed capture when supplied; its caller retains bitmap ownership.
    // Otherwise capture only the named owned viewport before finally clears it.
    var captureStage = if (capturedBitmap == null) "captureToImage" else "existing-capture"
    var captureWidth: Int? = null
    var captureHeight: Int? = null
    var encodedBytes = 0
    var byteLimit = 64 * 1024
    var limitExceeded = false
    var writerFailure: java.io.IOException? = null
    var partialFileRemoved: Boolean? = null
    val headingNames = setOf("heading-ltr-ordinary.png", "heading-ltr-plain-companion.png",
        "heading-ltr-rich-companion.png", "heading-ltr-styled-companion.png",
        "heading-rtl-ordinary.png", "heading-rtl-plain-companion.png",
        "heading-rtl-rich-companion.png", "heading-rtl-styled-companion.png")
    val largeTextNames = setOf("search-large-text.png", "search-large-text-recovered.png")
    val capture = runCatching {
        val bitmap = capturedBitmap ?: viewport.captureToImage().asAndroidBitmap()
        try {
            captureWidth = bitmap.width
            captureHeight = bitmap.height
            fun compressInto(output: java.io.OutputStream) {
                val bounded = object : java.io.OutputStream() {
                    private fun reserve(length: Int) {
                        if (length > byteLimit - encodedBytes) {
                            limitExceeded = true
                            val failure = java.io.IOException("Owned PNG exceeds $byteLimit bytes")
                            writerFailure = failure
                            throw failure
                        }
                    }
                    override fun write(value: Int) {
                        reserve(1)
                        try { output.write(value); encodedBytes++ }
                        catch (failure: java.io.IOException) { writerFailure = failure; throw failure }
                    }
                    override fun write(data: ByteArray, offset: Int, length: Int) {
                        reserve(length)
                        try { output.write(data, offset, length); encodedBytes += length }
                        catch (failure: java.io.IOException) { writerFailure = failure; throw failure }
                    }
                }
                captureStage = "PNG-compress"
                val compressed = bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bounded)
                // The native encoder may report false after an OutputStream exception.
                writerFailure?.let { throw it }
                check(compressed) { "Owned PNG encoder returned false" }
            }
            if (imageName in headingNames || imageName in largeTextNames) {
                byteLimit = if (imageName in largeTextNames) 12 * 1024 * 1024 else 16 * 1024 * 1024
                if (imageName in largeTextNames) check(bitmap.width in 1..4096 && bitmap.height in 1..4096)
                captureStage = "owned-file-path"
                val files = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
                val directory = java.io.File(files, "qa-copy-evidence")
                check(directory.mkdirs() || directory.isDirectory)
                check(directory.canonicalFile.parentFile == files.canonicalFile)
                val target = java.io.File(directory, imageName)
                check(target.canonicalFile.parentFile == directory.canonicalFile && !target.exists())
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                var complete = false
                try {
                    target.outputStream().use { output ->
                        compressInto(java.security.DigestOutputStream(output, digest))
                    }
                    captureStage = "owned-file-verify"
                    check(encodedBytes in 45..byteLimit && target.length() == encodedBytes.toLong())
                    val sha = digest.digest().joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
                    complete = true
                    "\nOWNED_PNG_FILE " + imageName + " bytes=" + encodedBytes + " sha256=" + sha +
                        " width=" + bitmap.width + " height=" + bitmap.height
                } finally {
                    if (!complete) partialFileRemoved = runCatching { !target.exists() || target.delete() }.getOrDefault(false)
                }
            } else {
                val bytes = java.io.ByteArrayOutputStream()
                compressInto(bytes)
                val png = bytes.toByteArray()
                val sha = java.security.MessageDigest.getInstance("SHA-256").digest(png)
                    .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
                "\nOWNED_PNG_BEGIN " + imageName + " bytes=" + png.size + " sha256=" + sha +
                    " width=" + bitmap.width + " height=" + bitmap.height + "\n" +
                    android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP) +
                    "\nOWNED_PNG_END " + imageName
            }
        } finally { if (capturedBitmap == null) bitmap.recycle() }
    }.getOrElse {
        "\nOWNED_PNG_UNAVAILABLE " + imageName + " " + it.javaClass.name + ": " + it.message +
            " stage=" + captureStage + " width=" + captureWidth + " height=" + captureHeight +
            " encodedBytes=" + encodedBytes + " byteLimit=" + byteLimit + " limitExceeded=" + limitExceeded +
            " partialFileRemoved=" + partialFileRemoved
    }
    return details + viewportDetails + capture
}

/** Read only the admitted test Activity's own view/configuration, on its UI thread. */
internal fun ownedLayoutState(view: android.view.View): String {
    val config = view.resources.configuration
    val visible = android.graphics.Rect().also(view::getWindowVisibleDisplayFrame)
    val insets = view.rootWindowInsets
    val ime = "visible=${insets?.isVisible(android.view.WindowInsets.Type.ime())},insets=${insets?.getInsets(android.view.WindowInsets.Type.ime())}"
    val focused = view.findFocus()
    return "ownedRoot=${view.width}x${view.height}; windowFocus=${view.hasWindowFocus()}; " +
        "focusedView=${focused?.javaClass?.name},id=${focused?.id}; visibleFrame=$visible; ime=$ime; " +
        "configFontScale=${config.fontScale}; densityDpi=${config.densityDpi}; " +
        "screenDp=${config.screenWidthDp}x${config.screenHeightDp}; orientation=${config.orientation}; " +
        "layoutDirection=${config.layoutDirection}; fontWeightAdjustment=" +
        config.fontWeightAdjustment
}

/** The original assertion remains primary even when diagnostic reads/capture fail. */
internal fun <T> withRenderedLayoutFailureEvidence(
    label: String,
    node: androidx.compose.ui.test.SemanticsNodeInteraction,
    viewport: androidx.compose.ui.test.SemanticsNodeInteraction,
    imageName: String?,
    ownedState: () -> String,
    assertion: () -> T,
): T = try { assertion() } catch (failure: Throwable) {
    // ComposeTimeoutException extends Throwable directly, outside AssertionError and Exception.
    if (failure !is AssertionError && failure !is androidx.compose.ui.test.ComposeTimeoutException) throw failure
    val evidence = runCatching {
        val semantic = runCatching { node.fetchSemanticsNode() }.getOrNull()
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        runCatching { node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) } }
        val state = runCatching(ownedState).getOrElse { "OWNED_STATE_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
        renderedLayoutFailureEvidence(label, layouts.singleOrNull(), semantic, viewport, imageName) + "\n" + state
    }.getOrElse { "LAYOUT_EVIDENCE_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
    try {
        val report = "\n$evidence\n"
        check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024) { "Owned failure status exceeds 128 KiB" }
        InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
            putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, report)
        })
    } catch (evidenceFailure: Throwable) {
        failure.addSuppressed(evidenceFailure)
    }
    throw failure
}

internal fun assertCompletePlainTextLayout(layout: androidx.compose.ui.text.TextLayoutResult, label: String) {
    // Compose 1.11.2 virtual plain-Text semantics can rebuild at maxWidth while
    // retaining the smaller measured size. Verify actual ink and all text instead.
    assertEquals(label, layout.layoutInput.text.text)
    assertFalse("Rendered text must not overflow vertically: " + label, layout.didOverflowHeight)
    assertTrue("Plain text must contain measured lines", layout.lineCount > 0)
    for (line in 0 until layout.lineCount) {
        assertFalse("Plain text must not ellipsize", layout.isLineEllipsized(line))
        assertTrue("Plain text ink must remain inside measured width",
            layout.getLineLeft(line) >= -1f && layout.getLineRight(line) <= layout.size.width + 1f)
        assertTrue("Plain text ink must remain inside measured height",
            layout.getLineTop(line) >= -1f && layout.getLineBottom(line) <= layout.size.height + 1f)
    }
    assertEquals(label.length, layout.getLineEnd(layout.lineCount - 1))
    assertTrue(layout.multiParagraph.height <= layout.size.height + 1f)
}

class RendererDeviceTest {
    @Test fun svgLanguagesKeepDistinctPixelsAndOriginalAxesInInlineNativeAndFigurePaths() {
        val red = android.graphics.Bitmap.createBitmap(250, 125, android.graphics.Bitmap.Config.ARGB_8888)
        var blue: android.graphics.Bitmap? = null
        try {
            red.eraseColor(android.graphics.Color.RED)
            blue = android.graphics.Bitmap.createBitmap(500, 250, android.graphics.Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
            val bluePixels = checkNotNull(blue)
            val file = "Controlled language.svg"
            val ru = InlineImage(file, widthPx = 32, svgLanguage = "ru", alt = "Russian")
            val ko = ru.copy(svgLanguage = "ko", alt = "Korean")
            val spans = listOf(Span("link", "", "Russian-target", image = ru), Span("text", " "), Span("link", "", "Korean-target", image = ko))
            val zero = StyleLength(StyleLengthUnit.Px, 0f)
            val edges = StyleEdges(zero, zero, zero, zero)
            fun figure(span: Span) = Figure(FigureContent.Image(span, FigureSizingPolicy.RequestedFit), FigureFormat.Thumbnail,
                FigurePlacement.None, FigureClear.None, edges, edges, edges, 1f, StyleLength(StyleLengthUnit.Em, 1.5f),
                FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
                FigureColor.NativeTheme, FigureColor.Transparent, emptyList())
            val native = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Inline(spans)))
            val figures = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.ImageFigure(figure(spans[0])),
                FlowPart.Inline(listOf(Span("text", " "))), FlowPart.ImageFigure(figure(spans[2]))))
            val media = listOf(Media(file, "image", ""))
            val settings = AppSettings(allowImages = false, allowAudio = false)
            var density by mutableFloatStateOf(1f)
            var nativeGeometry: FloatTextGeometry? = null
            var figureGeometry: FloatTextGeometry? = null
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(density, 1f)) {
                    MaterialTheme {
                        val owner = rememberInlineImageViewOwner(listOf(ru, ko), media, settings, "en", rasterImages = listOf(
                            RasterImageOccurrence(ru), RasterImageOccurrence(ko), RasterImageOccurrence(ru, FigureSizingPolicy.RequestedFit),
                            RasterImageOccurrence(ko, FigureSizingPolicy.RequestedFit)))
                        remember(owner) {
                            owner.states[inlineImageAssetKey(ru)] = InlineImageAssetState.Ready(DecodedMediaBitmap(red, 250, 125), 800, 400, "image/svg+xml", "controlled", "")
                            owner.states[inlineImageAssetKey(ko)] = InlineImageAssetState.Ready(DecodedMediaBitmap(bluePixels, 500, 250), 800, 400, "image/svg+xml", "controlled", "")
                            true
                        }
                        CompositionLocalProvider(LocalInlineImageOwner provides owner) {
                            Column(Modifier.width(260.dp)) {
                                Box(Modifier.testTag("svg-inline")) { StyledText(spans, style = MaterialTheme.typography.bodyLarge) }
                                Box(Modifier.testTag("svg-native")) { AnonymousBlockView(native, Modifier, {}, media, settings, "en", onGeometry = { nativeGeometry = it }) }
                                Box(Modifier.testTag("svg-figure")) { AnonymousBlockView(figures, Modifier, {}, media, settings, "en", onGeometry = { figureGeometry = it }) }
                            }
                        }
                    }
                }
            } }
            for (scale in listOf(1f, 2f)) {
                compose.runOnIdle { if (density != scale) { nativeGeometry = null; figureGeometry = null; density = scale } }
                compose.waitUntil(5000) { nativeGeometry != null && figureGeometry != null }
                for (tag in listOf("svg-inline", "svg-native", "svg-figure")) {
                    val bitmap = compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
                    try {
                        val pixels = IntArray(bitmap.width * bitmap.height)
                        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                        assertTrue("$tag preserves Russian pixels", pixels.count { it == android.graphics.Color.RED } > 100)
                        assertTrue("$tag preserves Korean pixels", pixels.count { it == android.graphics.Color.BLUE } > 100)
                        for (color in listOf(android.graphics.Color.RED, android.graphics.Color.BLUE)) {
                            val points = pixels.indices.filter { pixels[it] == color }
                            val width = points.maxOf { it % bitmap.width } - points.minOf { it % bitmap.width } + 1
                            val height = points.maxOf { it / bitmap.width } - points.minOf { it / bitmap.width } + 1
                            assertEquals("$tag uses compiled client width", 32f * scale, width.toFloat(), 1f)
                            assertEquals("$tag keeps original axes separate from raster buckets", 16f * scale, height.toFloat(), 1f)
                        }
                    } finally { bitmap.recycle() }
                }
                compose.runOnIdle {
                    for (geometry in listOf(checkNotNull(nativeGeometry), checkNotNull(figureGeometry))) {
                        val images = geometry.nodes.filter { it.kind == FloatInteractionKind.IMAGE || it.onClick != null }
                        assertEquals(2, images.size)
                        assertTrue(images.all { it.onClick != null && it.bounds.isNotEmpty() })
                    }
                }
            }
        } finally {
            try { compose.activityRule.scenario.onActivity { it.setContent { } }; compose.waitForIdle() }
            finally { red.recycle(); blue?.recycle() }
        }
    }

    @Test fun missingFigurePaintUsesNativeHoverPressFocusAndSharedVisitedTargetWithoutChangingMetrics() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        fun figure(label: String, target: String = "File:Missing controlled.png") = Figure(FigureContent.Missing(Span("link", label, target),
            StyleLength(StyleLengthUnit.Px, 180f), StyleLength(StyleLengthUnit.Em, 1.5f), MissingLinkPaint.VectorNewLinkV1),
            FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, edges, edges, edges,
            1f, StyleLength(StyleLengthUnit.Em, 1.5f), FigureColor.Rgb("#ffffff"), FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent, emptyList())
        val firstLabel = "First missing image filename"
        val secondLabel = "Second label, same destination"
        val block = Block("paragraph", 0, emptyList(), flow = listOf(
            FlowPart.ImageFigure(figure(firstLabel)), FlowPart.Inline(listOf(Span("text", " Between "))),
            FlowPart.ImageFigure(figure(secondLabel))))
        val visits = MissingLinkVisits()
        val actions = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        var dark by mutableStateOf(false)
        var rebound by mutableStateOf(false)
        var documentOwner by mutableStateOf(Any())
        var width by mutableIntStateOf(420)
        var measured: FloatTextGeometry? = null
        var focusCueColor = 0
        val touchHandler = android.os.Handler(android.os.Looper.getMainLooper())
        class ShortPress(val owner: NativeFloatTextView, val down: Long, val timeout: Int) {
            val deadline = down + timeout - 1L
            var cancelledAt: Long? = null
            var cancellation = "pending"
            lateinit var deadlineCancel: Runnable
        }
        var shortPress: ShortPress? = null
        var longPressOwner: NativeFloatTextView? = null
        var longPressDown = 0L
        fun cancelShortPress(press: ShortPress, reason: String) {
            check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
            touchHandler.removeCallbacks(press.deadlineCancel)
            if (press.cancelledAt != null) return
            val now = android.os.SystemClock.uptimeMillis()
            press.cancelledAt = now
            press.cancellation = reason
            val cancel = android.view.MotionEvent.obtain(press.down, now, android.view.MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
            try { press.owner.dispatchTouchEvent(cancel) } finally { cancel.recycle() }
        }
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalMissingLinkVisits provides visits,
                    LocalReaderDarkTheme provides dark, LocalMissingLinkOwner provides documentOwner) {
                    MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp))) {
                        focusCueColor = MaterialTheme.colorScheme.primary.toArgb()
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                            val shown = if (rebound) block.copy(flow = listOf(FlowPart.ImageFigure(figure(firstLabel, "Replacement-target")),
                                FlowPart.Inline(listOf(Span("text", " Between "))), FlowPart.ImageFigure(figure(secondLabel)))) else block
                            AnonymousBlockView(shown, Modifier.width(width.dp).testTag("missing-paint-fixture"), { actions += it }, emptyList(),
                                AppSettings(allowImages = false, allowAudio = false), "en", onGeometry = { measured = it })
                        }
                    }
                }
            } }
            compose.waitUntil(5000) { measured != null }
            var original: List<android.graphics.RectF> = emptyList()
            fun first() = checkNotNull(measured).nodes.single { it.label?.toString() == firstLabel }
            val viewport = compose.onNodeWithTag("missing-paint-fixture", useUnmergedTree = true)
            var captureIndex = 0
            fun capture(color: Int, underline: Boolean, focus: Boolean = false,
                cueColor: Int = 0xff3366cc.toInt(), extraIndex: Int? = null) {
                compose.waitForIdle()
                var captureGeometry: FloatTextGeometry? = null
                var captureOwner: NativeFloatTextView? = null
                var selectionBeforeCapture = false
                val snapshot = compose.runOnIdle {
                    val owner = shownNativeFloatOwners().single()
                    val node = first()
                    captureGeometry = measured
                    captureOwner = owner
                    selectionBeforeCapture = owner.selectionActive
                    Triple(checkNotNull(node.missingLinkPaint).appearance(), node.bounds.map { android.graphics.RectF(it) },
                        "owner=${owner.width}x${owner.height}; padding=${owner.paddingLeft},${owner.paddingTop}; " +
                            "geometry=${measured?.width}x${measured?.height}; bounds=${node.bounds}; " + owner.linkKeyState() + "; " + ownedLayoutState(owner))
                }
                // Figure children paint below the transparent input/selection surface.
                val press = shortPress
                val captureRequestedAt = android.os.SystemClock.uptimeMillis()
                val bitmap = try { viewport.captureToImage().asAndroidBitmap() } catch (failure: Throwable) {
                    compose.runOnUiThread { press?.let { cancelShortPress(it, "capture-failed") }; shortPress = null }
                    throw failure
                }
                try {
                    var afterCapture = ""
                    var touchEvidence = "no-short-touch"
                    var capturedShortPress = press == null
                    // No idle wait, pixel scan, PNG encoding or status IPC may extend this touch.
                    compose.runOnUiThread {
                        try {
                            val owner = shownNativeFloatOwners().single()
                            val completedAt = android.os.SystemClock.uptimeMillis()
                            afterCapture = owner.linkKeyState()
                            if (press != null) {
                                val appearance = checkNotNull(first().missingLinkPaint).appearance()
                                capturedShortPress = owner === press.owner && owner === captureOwner && press.cancelledAt == null &&
                                    captureRequestedAt >= press.down && completedAt < press.deadline &&
                                    measured === captureGeometry && first().bounds == snapshot.second &&
                                    !selectionBeforeCapture && !owner.selectionActive &&
                                    appearance.color == color && appearance.underline == underline
                                touchEvidence = "down=${press.down}; requested=$captureRequestedAt; completed=$completedAt; " +
                                    "deadline=${press.deadline}; longPressTimeout=${press.timeout}; capturedHeld=$capturedShortPress"
                            }
                        } finally {
                            press?.let {
                                cancelShortPress(it, "bitmap-complete")
                                touchEvidence += "; cancelled=${it.cancelledAt}; cancellation=${it.cancellation}; " +
                                    "afterCancel=${it.owner.linkKeyState()}; actions=${actions.size}"
                            }
                            shortPress = null
                        }
                    }
                    var ink = 0
                    var outline = 0
                    for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                        if (bitmap.getPixel(x, y) == color) ink++
                        if (bitmap.getPixel(x, y) == cueColor) outline++
                    }
                    val imageName = "missing-appearance-${extraIndex ?: captureIndex++}"
                    val evidence = renderedLayoutFailureEvidence("Missing paint state", null, null, viewport, imageName,
                        capturedBitmap = bitmap) + "\n${snapshot.third}; expectedColor=$color; actualState=${snapshot.first}; " +
                        "ink=$ink; outline=$outline; expectedUnderline=$underline; expectedFocus=$focus; cueColor=$cueColor; " +
                        "afterCapture=$afterCapture; touch=$touchEvidence"
                    check(evidence.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
                    InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
                        putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$evidence\n")
                    })
                    assertTrue("The pre-assertion bitmap must be retained", evidence.contains("OWNED_PNG_BEGIN $imageName"))
                    assertTrue("Pressed capture must finish before the real short-touch deadline: $touchEvidence", capturedShortPress)
                    assertEquals(color, snapshot.first.color); assertEquals(underline, snapshot.first.underline)
                    assertTrue("Expected policy ink must actually be drawn", ink > 10)
                    if (focus) assertTrue("The focused node, host or caret has a visible cue", outline > 10)
                    if (original.isNotEmpty()) assertEquals(original, snapshot.second)
                } finally { bitmap.recycle() }
            }
            fun event(action: Int, down: Long? = null): Long = compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                val rect = first().bounds.first()
                val now = android.os.SystemClock.uptimeMillis()
                val downTime = down ?: now
                val motion = android.view.MotionEvent.obtain(downTime, now, action,
                    rect.centerX() + owner.paddingLeft, rect.centerY() + owner.paddingTop, 0)
                try {
                    if (action in listOf(android.view.MotionEvent.ACTION_HOVER_ENTER, android.view.MotionEvent.ACTION_HOVER_MOVE, android.view.MotionEvent.ACTION_HOVER_EXIT)) {
                        motion.source = android.view.InputDevice.SOURCE_MOUSE
                        owner.dispatchGenericMotionEvent(motion)
                    } else owner.dispatchTouchEvent(motion)
                } finally { motion.recycle() }
                downTime
            }
            fun beginShortPress() = compose.runOnIdle {
                check(shortPress == null)
                val owner = shownNativeFloatOwners().single()
                assertFalse(owner.selectionActive)
                val now = android.os.SystemClock.uptimeMillis()
                val timeout = android.view.ViewConfiguration.getLongPressTimeout()
                check(timeout > 1)
                val press = ShortPress(owner, now, timeout)
                press.deadlineCancel = Runnable { cancelShortPress(press, "short-touch-deadline") }
                shortPress = press
                check(touchHandler.postAtTime(press.deadlineCancel, press.deadline))
                val rect = first().bounds.first()
                val down = android.view.MotionEvent.obtain(now, now, android.view.MotionEvent.ACTION_DOWN,
                    rect.centerX() + owner.paddingLeft, rect.centerY() + owner.paddingTop, 0)
                try { assertTrue(owner.dispatchTouchEvent(down)) } finally { down.recycle() }
            }
            compose.runOnIdle { original = first().bounds.map { android.graphics.RectF(it) } }
            capture(0xffbf3c2c.toInt(), false)
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                assertFalse(owner.selectionActive)
                assertTrue(owner.requestFocus())
                assertTrue(owner.linkKeyState().contains("focus=true/-1"))
                assertFalse(owner.defaultFocusHighlightEnabled)
            }
            capture(0xffbf3c2c.toInt(), false, focus = true, cueColor = focusCueColor, extraIndex = 14)
            compose.runOnIdle { shownNativeFloatOwners().single().clearFocus(); assertTrue(actions.isEmpty()) }
            event(android.view.MotionEvent.ACTION_HOVER_ENTER)
            capture(0xff9f3526.toInt(), true)
            beginShortPress()
            capture(0xff612419.toInt(), true)
            compose.runOnIdle { assertTrue(actions.isEmpty()); assertFalse(shownNativeFloatOwners().single().selectionActive) }
            event(android.view.MotionEvent.ACTION_HOVER_EXIT)
            capture(0xffbf3c2c.toInt(), false)
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                assertTrue(owner.accessibilityNodeProvider.performAction(first().id, android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
            }
            capture(0xffbf3c2c.toInt(), false, focus = true)
            var heldOwner: NativeFloatTextView? = null
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                heldOwner = owner
                assertTrue(owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
            }
            // Reflow replaces measured geometry and callbacks while the document and action stay the same.
            compose.runOnIdle { width = 421 }
            compose.waitForIdle()
            compose.runOnIdle { width = 420 }
            compose.waitForIdle()
            compose.runOnIdle {
                assertSame(heldOwner, shownNativeFloatOwners().single())
                assertTrue(actions.isEmpty())
            }
            capture(0xff612419.toInt(), true, focus = true)
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_DPAD_CENTER))
                assertTrue(actions.isEmpty())
            }
            capture(0xff612419.toInt(), true, focus = true)
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                val cancelledUp = android.view.KeyEvent.changeFlags(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP,
                    android.view.KeyEvent.KEYCODE_ENTER), android.view.KeyEvent.FLAG_CANCELED)
                assertTrue(owner.dispatchKeyEvent(cancelledUp))
                assertTrue(actions.isEmpty())
            }
            capture(0xffbf3c2c.toInt(), false, focus = true)
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                assertTrue(owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                rebound = true
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                assertTrue("A held key cannot activate the same-label replacement target", actions.isEmpty())
            }
            capture(0xffbf3c2c.toInt(), false, focus = true)
            compose.runOnIdle { rebound = false }
            compose.waitForIdle()
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                assertTrue(owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                documentOwner = Any()
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                assertTrue("The same target in a new document cannot inherit a held key", actions.isEmpty())
            }
            capture(0xffbf3c2c.toInt(), false, focus = true)
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                assertTrue(owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                assertTrue(owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER)))
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(listOf(EntryLink("File:Missing controlled.png")), actions.toList())
                assertTrue(checkNotNull(checkNotNull(measured).nodes.single { it.label?.toString() == secondLabel }.missingLinkPaint).visited)
            }
            capture(0xff9f5555.toInt(), false, focus = true)
            compose.runOnIdle { dark = true }
            capture(0xffc99391.toInt(), false, focus = true)
            event(android.view.MotionEvent.ACTION_HOVER_ENTER)
            capture(0xffdcb5b3.toInt(), true, focus = true)
            beginShortPress()
            capture(0xffe8cecd.toInt(), true, focus = true)
            event(android.view.MotionEvent.ACTION_HOVER_EXIT)
            compose.runOnIdle {
                assertEquals(1, actions.size)
                val owner = shownNativeFloatOwners().single()
                val second = checkNotNull(measured).nodes.single { it.label?.toString() == secondLabel }
                assertTrue(owner.accessibilityNodeProvider.performAction(second.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(2, actions.size)
                owner.setSelection(0, checkNotNull(measured).text.length)
                assertEquals(0, owner.selectionStart)
                assertEquals(checkNotNull(measured).text.length, owner.selectionEnd)
            }
            // A genuine held gesture still selects text. It is independent of short-press captures.
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                assertTrue(owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ESCAPE)))
                owner.clearFocus()
                assertFalse(owner.selectionActive)
            }
            compose.runOnIdle { longPressOwner = shownNativeFloatOwners().single() }
            longPressDown = event(android.view.MotionEvent.ACTION_DOWN)
            compose.waitUntil(android.view.ViewConfiguration.getLongPressTimeout().toLong() + 3000L) {
                compose.runOnUiThread { shownNativeFloatOwners().single().selectedTextForCopy() == "missing" }
            }
            capture(0xffc99391.toInt(), false, extraIndex = 15)
            event(android.view.MotionEvent.ACTION_CANCEL, longPressDown)
            longPressOwner = null
            compose.runOnIdle {
                val owner = shownNativeFloatOwners().single()
                assertEquals("missing", owner.selectedTextForCopy())
                assertEquals(2, actions.size)
                val at = owner.logicalText.indexOf("Between")
                assertTrue(at >= 0)
                assertTrue(owner.performAccessibilityAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION,
                    android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, at)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, at)
                    }))
                assertEquals(at, owner.selectionStart); assertEquals(at, owner.selectionEnd)
            }
            capture(0xffc99391.toInt(), false, focus = true, cueColor = focusCueColor, extraIndex = 16)
        } finally {
            try {
                compose.runOnUiThread {
                    shortPress?.let { cancelShortPress(it, "test-finally") }; shortPress = null
                    longPressOwner?.let { owner ->
                        val cancel = android.view.MotionEvent.obtain(longPressDown, android.os.SystemClock.uptimeMillis(),
                            android.view.MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
                        try { owner.dispatchTouchEvent(cancel) } finally { cancel.recycle(); longPressOwner = null }
                    }
                }
            } finally {
                compose.activityRule.scenario.onActivity { it.setContent { } }
                compose.waitForIdle()
            }
        }
    }

    private fun shownNativeFloatOwners(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        val pending = java.util.ArrayDeque<android.view.View>()
        pending.add(compose.activity.window.decorView)
        var count = 0
        while (pending.isNotEmpty()) {
            check(++count <= 512)
            val view = pending.removeFirst()
            if (view is NativeFloatTextView && view.isShown) result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { pending.add(view.getChildAt(it)) }
        }
        return result
    }

    @Test fun capturedSerbianFiguresKeepMeasuredFloatGeometryAcrossMediaStates() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bytes = instrumentation.context.assets.open("captured-sr-current212.dprj").use { it.readBytes() }
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
        assertEquals("f5824c51a366cbc8fa9cca2b078743b4075b2ef99c5eee25933434195d34c534", digest)
        val entry = BlobDecoder.decode(bytes, "Србија", "language", "Српски", "sr")
        val block = entry.sections[2].blocks[1]
        val figures = requireNotNull(block.flow).filterIsInstance<FlowPart.ImageFigure>().map { it.figure }
        assertEquals(listOf("Flag of Serbia.svg", "Serbia in Europe.svg"), figures.map { it.content.span.image!!.file })
        assertTrue(figures.all { (it.content as FigureContent.Image).sizing == FigureSizingPolicy.RequestedFit && it.content.span.image!!.widthPx == 250L &&
            it.content.span.image!!.heightPx == null && it.content.span.image!!.alt == "" &&
            it.placement == FigurePlacement.FloatRight && it.clear == FigureClear.Right && it.frameMinWidth?.value == 100f })
        val expected = "Застава Србије Положај Србије у Европи (црвено)"
        val bitmap = android.graphics.Bitmap.createBitmap(8, 8, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.BLUE)
        val settings = AppSettings(allowImages = false, allowAudio = false)
        var owner: InlineImageViewOwner? = null
        var publishedFontScale: Float? = null
        var measured: NativeAnonymousFlowGeometry? = null
        val viewport = compose.onNodeWithTag("captured-sr-media-state")
        try {
            for (fontScale in listOf(1f, 2f)) {
                owner = null; publishedFontScale = null; measured = null
                compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                    MaterialTheme {
                        androidx.compose.runtime.key(fontScale) {
                            CompositionLocalProvider(LocalDensity provides Density(1f, fontScale)) {
                                val mediaOwner = rememberInlineImageViewOwner(figures.map { it.content.span.image!! }, entry.media, settings, entry.edition)
                                remember(mediaOwner) {
                                    figures.forEach { mediaOwner.states[it.content.span.image!!.file] = InlineImageAssetState.Disabled }
                                    true
                                }
                                SideEffect { owner = mediaOwner; publishedFontScale = fontScale }
                                CompositionLocalProvider(LocalInlineImageOwner provides mediaOwner) {
                                    Box(Modifier.width(320.dp).testTag("captured-sr-media-state")) {
                                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Flow(0, 0f, null, null, false) { carried, sink ->
                                            AnonymousBlockView(block, Modifier, {}, entry.media, settings, entry.edition,
                                                interactionOwner = false, carriedExclusions = carried,
                                                onFlowGeometry = { measured = it; sink(it) })
                                        }), Modifier, MaterialTheme.colorScheme.primary) { _, _ ->
                                            Text("Unexpected linear fallback")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } }
                for (phase in listOf("disabled", "loading", "failed", "ready", "disabled-again")) {
                    withRenderedLayoutFailureEvidence("captured SR $phase fontScale=$fontScale", viewport, viewport,
                        "sr-figure-media-state-failure", { "phase=$phase; fontScale=$fontScale; publishedFontScale=$publishedFontScale; ownerPublished=${owner != null}; geometryPublished=${measured != null}" }) {
                        try {
                            compose.waitUntil(timeoutMillis = 5000) {
                                var published = false
                                instrumentation.runOnMainSync { published = owner != null && publishedFontScale == fontScale }
                                published
                            }
                        } catch (failure: Exception) { throw AssertionError("Captured SR owner was not published: phase=$phase fontScale=$fontScale", failure) }
                        compose.runOnIdle {
                            val activeOwner = owner ?: throw AssertionError("Captured SR owner disappeared: phase=$phase fontScale=$fontScale")
                            assertTrue("Owner must belong to this font-scale composition", publishedFontScale == fontScale)
                            if (phase != "disabled") measured = null
                            figures.forEachIndexed { index, figure ->
                                activeOwner.states[figure.content.span.image!!.file] = when (phase) {
                                    "loading" -> InlineImageAssetState.Loading
                                    "failed" -> InlineImageAssetState.Failed
                                    "ready" -> InlineImageAssetState.Ready(DecodedMediaBitmap(bitmap, 8, 8), 500, if (index == 0) 300 else 400,
                                        "image/png", "controlled transition pixels, not an SVG claim", "")
                                    else -> InlineImageAssetState.Disabled
                                }
                            }
                        }
                        try {
                            compose.waitUntil(timeoutMillis = 5000) {
                                var ready = false
                                instrumentation.runOnMainSync { ready = measured != null && shownNativeFloatOwners().count { it.logicalText.toString() == expected } == 1 }
                                ready
                            }
                        } catch (failure: Exception) { throw AssertionError("Captured SR media geometry did not become ready: $phase", failure) }
                        compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                        compose.onNodeWithText("Unexpected linear fallback").assertDoesNotExist()
                        val captured = viewport.captureToImage().asAndroidBitmap()
                        try {
                            val pixels = IntArray(captured.width * captured.height)
                            captured.getPixels(pixels, 0, captured.width, 0, 0, captured.width, captured.height)
                            assertEquals("Only Ready may paint controlled image pixels: $phase", phase == "ready",
                                pixels.any { it == android.graphics.Color.BLUE })
                        } finally { captured.recycle() }
                        compose.runOnIdle {
                            val geometry = checkNotNull(measured)
                            assertEquals(expected, geometry.text.toString())
                            assertEquals(2, geometry.figures.size)
                            val imageNodes = geometry.nodes.filter { it.kind == FloatInteractionKind.IMAGE }
                            assertEquals(2, imageNodes.size)
                            imageNodes.forEachIndexed { index, node ->
                                val bounds = node.bounds.single()
                                assertEquals(250f, bounds.width(), .01f)
                                if (phase == "ready") assertEquals(if (index == 0) 150f else 200f, bounds.height(), .01f)
                                else {
                                    assertTrue("Status must be measured, not a square image-aspect guess", bounds.height() > 0 && bounds.height() < 150f)
                                    assertTrue(node.stateDescription?.toString().orEmpty().contains(when (phase) {
                                        "loading" -> "Loading image"; "failed" -> "Image unavailable"; else -> "Images disabled"
                                    }))
                                }
                                assertEquals(260f, geometry.figures[index].bounds.width(), .01f)
                                assertTrue(geometry.figures[index].bounds.left >= 0f)
                            }
                            assertTrue(geometry.figures[1].bounds.top >= geometry.figures[0].bounds.bottom)
                            val view = shownNativeFloatOwners().single { it.logicalText.toString() == expected }
                            val provider = view.accessibilityNodeProvider
                            val args = android.os.Bundle().apply {
                                putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                                putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, expected.length)
                            }
                            assertTrue(provider.performAction(android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID,
                                android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, args))
                            assertEquals(expected, view.selectedTextForCopy())
                            assertFalse(view.logicalText.contains("Images disabled"))
                            assertFalse(view.logicalText.contains("Loading image"))
                        }
                        if (fontScale == 1f && phase in listOf("disabled", "ready")) {
                            val evidence = renderedLayoutFailureEvidence("captured SR $phase", null, null, viewport, "sr-figure-media-$phase")
                            assertTrue("Success frame must be retained", evidence.contains("OWNED_PNG_BEGIN sr-figure-media-$phase"))
                            assertTrue("Success status payload must stay bounded", evidence.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
                            instrumentation.sendStatus(0, android.os.Bundle().apply {
                                putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$evidence\n")
                            })
                        }
                    }
                }
                compose.activityRule.scenario.onActivity { it.setContent { } }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent { } }
            compose.waitForIdle()
            bitmap.recycle()
        }
    }

    @Suppress("DEPRECATION", "ClickableViewAccessibility")
    @Test fun capturedSerbianIpaTouchUsesThePaintedNativeOwnerThroughRootDispatch() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bytes = instrumentation.context.assets.open("captured-sr-current212.dprj").use { it.readBytes() }
        fun digest(value: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(value)
            .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
        assertEquals("f5824c51a366cbc8fa9cca2b078743b4075b2ef99c5eee25933434195d34c534", digest(bytes))
        val entry = BlobDecoder.decode(bytes, "Србија", "language", "Српски", "sr")
        val ipaSource = entry.sections[2].blocks[3].spans.first()
        assertEquals("IPA", ipaSource.text)
        assertEquals("Помоћ:МФА", ipaSource.target)
        val captions = listOf("Застава Србије", "Положај Србије у Европи (црвено)")
        val followed = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        val trace = java.util.concurrent.CopyOnWriteArrayList<String>()
        val failures = java.util.concurrent.CopyOnWriteArrayList<String>()
        val received = java.util.concurrent.CopyOnWriteArrayList<Pair<Int, Int>>()
        val attached = mutableListOf<NativeFloatTextView>()
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val directory = java.io.File(compose.activity.cacheDir, "sr-entry-media-${System.nanoTime()}")
        var directoryCreated = false
        val cache = MediaCache(compose.activity, metadata = {
            requests.incrementAndGet(); error("Media-disabled root-touch fixture must not request metadata")
        }, openMedia = { error("No media request belongs to this root-touch fixture") }, directory = directory)
        val geometryField = NativeFloatTextView::class.java.getDeclaredField("geometry").apply { isAccessible = true }
        val hitMethod = NativeFloatTextView::class.java.getDeclaredMethod("hitNode",
            java.lang.Float.TYPE, java.lang.Float.TYPE).apply { isAccessible = true }
        var phase = "fixture setup"
        var chosen: NativeFloatTextView? = null
        var point: FloatArray? = null
        var originalText = ""
        fun add(value: String) { check(trace.size < 64) { "Root-touch trace exceeds 64 observations" }; trace += value.take(4096) }
        fun geometry(view: NativeFloatTextView) = geometryField.get(view) as? FloatTextGeometry
        fun nodeDescription(node: FloatInteractionNode?) = node?.let {
            "id=${it.id},kind=${it.kind},range=${it.start}..${it.end},label=${it.label},bounds=${it.bounds},click=${it.onClick != null}"
        } ?: "none"
        fun describe(view: NativeFloatTextView, event: android.view.MotionEvent? = null): String {
            val origin = IntArray(2).also { view.getLocationOnScreen(it) }
            val current = geometry(view)
            val local = event?.let { floatArrayOf(it.x - view.paddingLeft, it.y - view.paddingTop) }
            val hit = local?.let { hitMethod.invoke(view, it[0], it[1]) as? FloatInteractionNode }
            return "view=${System.identityHashCode(view)},origin=${origin.toList()},size=${view.width}x${view.height}," +
                "padding=${listOf(view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom)}," +
                "scroll=${view.scrollX},${view.scrollY},matrix=${view.matrix.toShortString()}," +
                "selection=${view.selectionStart}..${view.selectionEnd}," +
                "geometry=${current?.javaClass?.simpleName}:${current?.width}x${current?.height}," +
                "textSha=${current?.text?.toString()?.toByteArray()?.let(::digest)}," +
                "IPA=${current?.nodes?.filter { it.label?.toString() == "IPA" }?.map(::nodeDescription)}," +
                "event=${event?.actionMasked},raw=${event?.rawX},${event?.rawY},local=${event?.x},${event?.y}," +
                "geometryPoint=${local?.toList()},preDispatchHit=${nodeDescription(hit)}"
        }
        fun ownedWindow(): Int = compose.runOnIdle {
            assertPhysicalActivity(compose.activity)
            val decor = compose.activity.window.decorView
            check(compose.activity.hasWindowFocus() && decor.hasWindowFocus())
            val info = decor.createAccessibilityNodeInfo()
            try { info.windowId } finally { info.recycle() }
        }
        fun emit(label: String) {
            val window = ownedWindow()
            val root = checkNotNull(instrumentation.uiAutomation.rootInActiveWindow)
            try { check(root.packageName?.toString() == compose.activity.packageName && root.windowId == window) }
            finally { root.recycle() }
            val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot()) { "Owned physical screenshot unavailable" }
            try {
                check(bitmap.width in 1..4096 && bitmap.height in 1..4096)
                val output = java.io.ByteArrayOutputStream()
                var count = 0
                var encodeFailure: java.io.IOException? = null
                val bounded = object : java.io.OutputStream() {
                    override fun write(value: Int) { write(byteArrayOf(value.toByte()), 0, 1) }
                    override fun write(value: ByteArray, offset: Int, length: Int) {
                        if (length > 256 * 1024 - count) {
                            val problem = java.io.IOException("Root-touch PNG exceeds 256 KiB")
                            encodeFailure = problem; throw problem
                        }
                        output.write(value, offset, length); count += length
                    }
                }
                val compressed = bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bounded)
                encodeFailure?.let { throw it }; check(compressed)
                check(ownedWindow() == window)
                val png = output.toByteArray()
                val state = compose.runOnIdle { ownedLayoutState(compose.activity.window.decorView) }
                val report = "\nfixtureDiagnostic=true; ordinary111Acceptance=false; pointChosenFromGeometry=true; " +
                    "coordinateSpace=physical-display0-screen; phase=$phase; point=${point?.toList()}; followed=${followed.map { it.target }}; " +
                    "layoutFailures=$failures; $state\n${trace.joinToString("\n")}\n" +
                    "OWNED_PNG_BEGIN $label bytes=${png.size} sha256=${digest(png)} width=${bitmap.width} height=${bitmap.height}\n" +
                    android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP) + "\nOWNED_PNG_END $label\n"
                check(report.toByteArray().size <= 512 * 1024)
                instrumentation.sendStatus(0, android.os.Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, report)
                })
            } finally { bitmap.recycle() }
        }
        var primary: Throwable? = null
        try {
            assertTrue(directory.mkdir()); directoryCreated = true
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("dark") {
                    CompositionLocalProvider(LocalInlineImageCache provides cache,
                        LocalNativeFloatContextFailureObserver provides { if (failures.size < 16) failures += it }) {
                        // Keep the physical Activity density and normal Scaffold insets; no test density/size override.
                        androidx.compose.material3.Scaffold { padding ->
                            androidx.compose.material3.Surface(Modifier.fillMaxSize().padding(padding).testTag("captured-sr-root-touch")) {
                                EntryView(entry, false, {}, onLink = { followed += it },
                                    settings = AppSettings(allowImages = false, allowAudio = false,
                                        collapsePronunciation = false, collapseEtymology = false,
                                        collapseOtherSections = false, collapseDetails = false),
                                    anchorRequest = EntryAnchorRequest(entry.key, "#Именица"))
                            }
                        }
                    }
                }
            } }
            phase = "await native IPA geometry"
            compose.waitUntil(15000) {
                var ready = false
                instrumentation.runOnMainSync {
                    ready = shownNativeFloatOwners().count { view -> captions.all { view.logicalText.contains(it) } &&
                        geometry(view)?.nodes?.count { it.label?.toString() == "IPA" && it.onClick != null } == 1 } == 1
                }
                ready
            }
            compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
            compose.runOnIdle {
                val owners = shownNativeFloatOwners()
                check(owners.size in 1..32)
                val view = owners.single { candidate -> captions.all { candidate.logicalText.contains(it) } }
                chosen = view; originalText = view.logicalText.toString()
                captions.forEach { assertEquals(1, Regex(Regex.escape(it)).findAll(originalText).count()) }
                assertTrue(originalText.contains("IPA:")); assertTrue(originalText.contains("Sr-srbija.ogg"))
                assertEquals(0, view.selectionStart); assertEquals(0, view.selectionEnd)
                val ipa = checkNotNull(geometry(view)).nodes.single { it.label?.toString() == "IPA" && it.onClick != null }
                val rect = ipa.bounds.first { !it.isEmpty }
                val origin = IntArray(2).also { view.getLocationOnScreen(it) }
                point = floatArrayOf(origin[0] + view.paddingLeft + rect.centerX(), origin[1] + view.paddingTop + rect.centerY())
                val visible = android.graphics.Rect(); check(view.getGlobalVisibleRect(visible))
                check(visible.contains(point!![0].toInt(), point!![1].toInt()))
                add("chosen=" + describe(view) + "; node=" + nodeDescription(ipa))
                owners.forEach { owner ->
                    attached += owner
                    owner.setOnTouchListener { _, event ->
                        // Observe the actual recipient without consuming or rerouting its event.
                        try {
                            if (event.actionMasked in listOf(android.view.MotionEvent.ACTION_DOWN,
                                    android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL)) {
                                received += System.identityHashCode(owner) to event.actionMasked
                                add("received=" + describe(owner, event))
                            }
                        } catch (problem: Throwable) { failures += "Touch observation failed: ${problem.javaClass.name}: ${problem.message}" }
                        false
                    }
                }
            }
            phase = "before one root-dispatched tap"
            emit("sr-root-ipa-before")
            ownedWindow()
            compose.runOnIdle {
                val view = checkNotNull(chosen)
                check(view.isShown && view.logicalText.toString() == originalText)
                check(view.selectionStart == view.selectionEnd)
                val origin = IntArray(2).also { view.getLocationOnScreen(it) }
                val position = checkNotNull(point)
                val hit = hitMethod.invoke(view, position[0] - origin[0] - view.paddingLeft,
                    position[1] - origin[1] - view.paddingTop) as? FloatInteractionNode
                check(hit?.label?.toString() == "IPA" && hit?.onClick != null)
                add("before root dispatch: " + describe(view))
            }
            // Match one short tap: no idle wait, capture or extra read between DOWN and UP.
            val downTime = android.os.SystemClock.uptimeMillis()
            for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
                phase = "root event $action intent"
                val position = checkNotNull(point)
                val event = android.view.MotionEvent.obtain(downTime, downTime, action,
                    position[0], position[1], 0).apply { source = android.view.InputDevice.SOURCE_TOUCHSCREEN }
                try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
                phase = "root event $action returned"
            }
            compose.waitForIdle()
            compose.runOnIdle {
                attached.forEach { add("after=" + describe(it)) }
                assertEquals(originalText, checkNotNull(chosen).logicalText.toString())
            }
            emit("sr-root-ipa-after")
            assertTrue("No layout or observation failure: $failures", failures.isEmpty())
            assertEquals("Actual root-dispatched link callback", listOf("Помоћ:МФА"), followed.map { it.target })
            val ownerId = System.identityHashCode(checkNotNull(chosen))
            assertEquals(listOf(ownerId to android.view.MotionEvent.ACTION_DOWN, ownerId to android.view.MotionEvent.ACTION_UP), received.toList())
            compose.runOnIdle { assertEquals(0, chosen!!.selectionStart); assertEquals(0, chosen!!.selectionEnd); assertNull(MediaPlayback.playing) }
            assertEquals(0, requests.get())
        } catch (problem: Throwable) {
            primary = problem
            try { emit("sr-root-ipa-failure") }
            catch (evidenceFailure: Throwable) {
                problem.addSuppressed(evidenceFailure)
                try {
                    val report = "\nphase=$phase; followed=${followed.map { it.target }}; failures=$failures\n${trace.joinToString("\n")}\n" +
                        "OWNED_PNG_UNAVAILABLE ${evidenceFailure.javaClass.name}: ${evidenceFailure.message}\n"
                    check(report.toByteArray().size <= 128 * 1024)
                    instrumentation.sendStatus(0, android.os.Bundle().apply { putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, report) })
                } catch (publicationFailure: Throwable) { problem.addSuppressed(publicationFailure) }
            }
            throw problem
        } finally {
            try {
                compose.runOnIdle { attached.forEach { it.setOnTouchListener(null) } }
                compose.activityRule.scenario.onActivity { it.setContent { } }
                compose.waitForIdle()
                if (directoryCreated) {
                    assertTrue(directory.listFiles().orEmpty().isEmpty()); assertTrue(directory.delete())
                }
            } catch (cleanup: Throwable) { if (primary != null) primary.addSuppressed(cleanup) else throw cleanup }
        }
    }

    @Suppress("DEPRECATION")
    @Test fun capturedSerbianEntryKeepsPublicCaptionTextAndPronunciationControlsBesideFigures() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bytes = instrumentation.context.assets.open("captured-sr-current212.dprj").use { it.readBytes() }
        assertEquals("f5824c51a366cbc8fa9cca2b078743b4075b2ef99c5eee25933434195d34c534",
            java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') })
        val entry = BlobDecoder.decode(bytes, "Србија", "language", "Српски", "sr")
        val captions = listOf("Застава Србије", "Положај Србије у Европи (црвено)")
        assertEquals("Sr-srbija.ogg", entry.media.single { it.kind == "audio" }.file)
        val settings = mutableStateOf(AppSettings(allowImages = false, allowAudio = false,
            collapsePronunciation = false, collapseEtymology = false, collapseOtherSections = false, collapseDetails = false))
        val anchor = EntryAnchorRequest(entry.key, "#Именица")
        val followed = mutableListOf<EntryLink>()
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val directory = java.io.File(compose.activity.cacheDir, "sr-entry-media-${System.nanoTime()}")
        assertTrue(directory.mkdir())
        val cache = MediaCache(compose.activity, metadata = {
            assertTrue(it.contains("Sr-srbija.ogg"))
            requests.incrementAndGet()
            throw java.io.IOException("Controlled pronunciation metadata failure")
        }, openMedia = { error("No media bytes are needed for the control-action proof") }, directory = directory)
        val viewport = compose.onNodeWithTag("captured-sr-full-entry")
        var observed = "No public accessibility observation yet"
        val layoutFailures = java.util.concurrent.CopyOnWriteArrayList<String>()
        val recordLayoutFailure: (String) -> Unit = { if (layoutFailures.size < 16) layoutFailures += it }
        fun publicNodes(): List<android.view.accessibility.AccessibilityNodeInfo> {
            val window = compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                check(compose.activity.hasWindowFocus())
                val info = compose.activity.window.decorView.createAccessibilityNodeInfo()
                try { info.windowId } finally { info.recycle() }
            }
            val root = instrumentation.uiAutomation.rootInActiveWindow ?: run {
                observed = "Public accessibility root unavailable"
                return emptyList()
            }
            val nodes = mutableListOf(root)
            try {
                var next = 0
                while (next < nodes.size) {
                    check(nodes.size <= 1024) { "Public accessibility tree exceeded the bounded fixture" }
                    val node = nodes[next++]
                    check(node.packageName?.toString() == compose.activity.packageName && node.windowId == window)
                    for (index in 0 until node.childCount) node.getChild(index)?.let { nodes += it }
                }
                val captionVisibility = captions.map { caption -> caption to nodes.any { it.isVisibleToUser && it.text?.contains(caption) == true } }
                val playerVisible = nodes.any { it.isVisibleToUser && it.contentDescription?.toString() == "Play pronunciation" }
                observed = "captionVisibility=$captionVisibility; playerVisible=$playerVisible; nodeCount=${nodes.size}\n" +
                    nodes.joinToString("\n") { node ->
                        val bounds = android.graphics.Rect().also(node::getBoundsInScreen)
                        "${node.className}: visible=${node.isVisibleToUser}, bounds=$bounds; ${node.text} / ${node.contentDescription}"
                    }.take(8192)
                return nodes
            } catch (failure: Throwable) { nodes.forEach { it.recycle() }; throw failure }
        }
        var failure: Throwable? = null
        try {
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("dark") {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalInlineImageCache provides cache,
                        LocalNativeFloatContextFailureObserver provides recordLayoutFailure) {
                        androidx.compose.material3.Surface(Modifier.width(384.dp).height(720.dp).testTag("captured-sr-full-entry")) {
                            EntryView(entry, false, {}, onLink = { followed += it }, settings = settings.value,
                                anchorRequest = anchor)
                        }
                    }
                }
            } }
            withRenderedLayoutFailureEvidence("captured SR full EntryView", viewport, viewport,
                "sr-full-entry-failure", { "Native layout failures: ${layoutFailures.joinToString()}\n$observed" }) {
                compose.waitUntil(15000) {
                    val nodes = publicNodes()
                    try { captions.all { caption -> nodes.any { it.isVisibleToUser && it.text?.contains(caption) == true } }
                    } finally { nodes.forEach { it.recycle() } }
                }
                compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                assertEquals(0, requests.get())
                compose.runOnIdle {
                    val view = shownNativeFloatOwners().single { candidate -> captions.all { candidate.logicalText.contains(it) } }
                    val text = view.logicalText.toString()
                    captions.forEach { assertEquals(1, Regex(Regex.escape(it)).findAll(text).count()) }
                    assertTrue(text.contains("IPA:"))
                    assertTrue(text.contains("Sr-srbija.ogg"))
                    assertTrue(text.contains("(датотека)\nСлогови:"))
                    assertFalse(text.contains("Images disabled"))
                    val args = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, text.length)
                    }
                    assertTrue(view.accessibilityNodeProvider.performAction(android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID,
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, args))
                    assertEquals(text, view.selectedTextForCopy())
                }
                val nodes = publicNodes()
                try {
                    val owner = nodes.single { candidate -> captions.all { candidate.text?.contains(it) == true } }
                    assertTrue(owner.availableExtraData.contains(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY))
                    val locationArgs = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX,
                            owner.text.toString().indexOf(captions[0]))
                        putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH, 3)
                    }
                    assertTrue(owner.refreshWithExtraData(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY, locationArgs))
                    val locations = owner.extras.getParcelableArray(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY)
                    assertEquals(3, locations?.size)
                    assertTrue(locations!!.all { it is android.graphics.RectF && !it.isEmpty })
                    val ipa = nodes.single { it.isVisibleToUser && it.text?.toString() == "IPA" && it.isClickable }
                    assertTrue(ipa.refresh())
                    assertTrue(ipa.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
                } finally { nodes.forEach { it.recycle() } }
                compose.runOnIdle { assertEquals(listOf("Помоћ:МФА"), followed.map { it.target }) }
                // The authored text can place its separate player below this bounded viewport.
                compose.onNodeWithContentDescription("Play pronunciation").performScrollTo().assertIsDisplayed()
                compose.waitUntil(15000) {
                    val visibleNodes = publicNodes()
                    try { visibleNodes.any { it.isVisibleToUser && it.contentDescription?.toString() == "Play pronunciation" }
                    } finally { visibleNodes.forEach { it.recycle() } }
                }
                compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
                compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
                val evidence = renderedLayoutFailureEvidence("captured SR full EntryView disabled", null, null, viewport, "sr-full-entry-disabled")
                assertTrue(evidence.contains("OWNED_PNG_BEGIN sr-full-entry-disabled"))
                assertTrue(evidence.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
                instrumentation.sendStatus(0, android.os.Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$evidence\n")
                })
                // The existing player action must remain usable; its controlled metadata failure makes no network/audio request.
                compose.runOnIdle { settings.value = settings.value.copy(allowAudio = true) }
                compose.onNodeWithContentDescription("Play pronunciation").assertIsEnabled().performClick()
                compose.waitUntil(5000) { requests.get() == 1 && compose.onAllNodesWithText("Pronunciation could not be played.")
                    .fetchSemanticsNodes().size == 1 }
                compose.onNodeWithText("Pronunciation could not be played.").assertExists()
                compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
                compose.onNodeWithContentDescription("Play pronunciation").assertIsEnabled()
                assertEquals(1, requests.get())
                compose.runOnIdle { assertNull(MediaPlayback.playing) }
            }
        } catch (caught: Throwable) { failure = caught; throw caught }
        finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent { } }
                compose.waitForIdle()
                assertTrue(directory.listFiles().orEmpty().isEmpty())
                assertTrue(directory.delete())
            } catch (cleanup: Throwable) { if (failure != null) failure.addSuppressed(cleanup) else throw cleanup }
        }
    }

    @Suppress("DEPRECATION")
    @Test fun imageActionsWithoutAuthoredAltHavePlatformNamesInOrdinaryAndNativeTrees() {
        val floating = mutableStateOf(false)
        val alternative = mutableStateOf<String?>(null)
        val opened = mutableListOf<String>()
        val file = "Vraagteken-2.svg"
        val expectedUrl = "https://he.wiktionary.org/wiki/File%3AVraagteken-2.svg"
        val caseMarker = mutableStateOf("Image case: ordinary / absent")
        fun entry(): Entry {
            val image = Span("link", "", "File:$file", image = InlineImage(file, 15, alt = alternative.value))
            val body = Block("paragraph", 0, listOf(Span("text", "Image context "), image))
            val table = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(
                Cell(listOf(Span("text", "Float")), false, 1, 1))), style = TableStyle(floatSide = TableFloatSide.Left)))
            return Entry("Image action names", emptyList(), "language", "English", "en",
                listOf(Section(2, "", if (floating.value) listOf(table, body) else listOf(body))), emptyList(),
                media = listOf(Media(file, "image", "")), edition = "hewiktionary-20261001")
        }
        val activity = compose.activity
        fun ownedWindow(): Int = compose.runOnIdle {
            assertPhysicalActivity(activity)
            check(activity.hasWindowFocus() && activity.window.decorView.hasWindowFocus())
            val info = activity.window.decorView.createAccessibilityNodeInfo()
            try { info.windowId } finally { info.recycle() }
        }
        fun publicImageForm(node: android.view.accessibility.AccessibilityNodeInfo, label: String,
            native: Boolean, alt: String?, window: Int): Boolean {
            if (node.packageName?.toString() != activity.packageName || node.windowId != window ||
                !node.isEnabled || !node.isClickable || node.actionList.none {
                    it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK
                }) return false
            if (native || alt.isNullOrEmpty()) return node.className?.toString() == "android.widget.ImageView" &&
                node.contentDescription?.toString() == label && (native || node.childCount == 0)
            // Compose 1.11.2 splits a merging image's role and name into children
            // when its authored fallback Text is present. The action stays here.
            if (node.className?.toString() != "android.view.View" || !node.contentDescription.isNullOrEmpty() ||
                node.childCount !in 1..512) return false
            var names = 0
            var fallbacks = 0
            for (index in 0 until node.childCount) {
                val child = node.getChild(index) ?: return false
                try {
                    if (child.packageName?.toString() != activity.packageName || child.windowId != window) return false
                    val passive = !child.isClickable && child.actionList.none {
                        it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK
                    }
                    if (passive && child.contentDescription?.toString() == label) names++
                    if (passive && child.className?.toString() == "android.widget.TextView" && child.text?.toString() == alt) fallbacks++
                } finally { child.recycle() }
            }
            return names == 1 && fallbacks == 1
        }
        fun namedImage(label: String, marker: String, native: Boolean, alt: String?): android.view.accessibility.AccessibilityNodeInfo? {
            val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
            val window = ownedWindow()
            val root = automation.rootInActiveWindow ?: return null
            val pending = java.util.ArrayDeque<android.view.accessibility.AccessibilityNodeInfo>()
            pending.add(root)
            var found: android.view.accessibility.AccessibilityNodeInfo? = null
            var visited = 0
            var contextTextSeen = false
            val observedCases = mutableListOf<String>()
            try {
                check(root.packageName?.toString() == activity.packageName && root.windowId == window)
                while (pending.isNotEmpty()) {
                    val node = pending.removeFirst()
                    try {
                        check(++visited <= 512)
                        val bodyText = node.text?.toString().orEmpty()
                        contextTextSeen = contextTextSeen || bodyText.contains("Image context \uFFFC")
                        if (bodyText.startsWith("Image case: ")) observedCases += bodyText
                        assertFalse(bodyText.contains("Open image link: $file"))
                        if (publicImageForm(node, label, native, alt, window)) {
                            check(found == null) { "Ambiguous named image action" }
                            found = android.view.accessibility.AccessibilityNodeInfo.obtain(node)
                        }
                        for (index in 0 until node.childCount) node.getChild(index)?.let { pending.add(it) }
                    } finally { node.recycle() }
                }
                check(ownedWindow() == window)
                if (!contextTextSeen || observedCases != listOf(marker)) { found?.recycle(); return null }
                return found
            } catch (failure: Throwable) { found?.recycle(); throw failure }
            finally { while (pending.isNotEmpty()) pending.removeFirst().recycle() }
        }
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                    CompositionLocalProvider(androidx.compose.ui.platform.LocalUriHandler provides object : androidx.compose.ui.platform.UriHandler {
                        override fun openUri(uri: String) { opened += uri }
                    }) {
                        Column(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
                            androidx.compose.material3.Text(caseMarker.value)
                            Box(Modifier.weight(1f)) {
                                EntryView(entry(), false, {}, onLink = { error("The compiled File action must keep its URI route") },
                                    settings = AppSettings(allowImages = false, allowAudio = false,
                                        collapseDetails = false, collapseOtherSections = false))
                            }
                        }
                    }
                } }
            } }
            var count = 0
            for (native in listOf(false, true)) for (alt in listOf(null, "", " \t", "Authored alternative")) {
                val altCase = when (alt) { null -> "absent"; "" -> "empty"; " \t" -> "whitespace"; else -> "authored" }
                val marker = "Image case: ${if (native) "native" else "ordinary"} / $altCase"
                compose.runOnIdle { floating.value = native; alternative.value = alt; caseMarker.value = marker }
                val label = if (alt == "Authored alternative") "Authored alternative" else "Open image link: $file"
                var selected: android.view.accessibility.AccessibilityNodeInfo? = null
                try {
                    compose.waitUntil(15000) {
                        selected = namedImage(label, marker, native, alt)
                        selected != null
                    }
                    val node = checkNotNull(selected)
                    val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
                    val window = ownedWindow()
                    val root = checkNotNull(automation.rootInActiveWindow)
                    try {
                        check(root.packageName?.toString() == activity.packageName && root.windowId == window)
                    } finally { root.recycle() }
                    check(node.refresh()) { "Selected image disappeared before activation: native=$native, alt=$alt" }
                    if (!native) {
                        val imageRole = SemanticsMatcher("Current named merging image") { semantic ->
                            semantic.config.isMergingSemanticsOfDescendants &&
                                semantic.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Role) == androidx.compose.ui.semantics.Role.Image &&
                                semantic.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription) == listOf(label) &&
                                semantic.config.contains(androidx.compose.ui.semantics.SemanticsActions.OnClick)
                        }
                        val semantic = compose.onAllNodes(imageRole, useUnmergedTree = true).fetchSemanticsNodes().single()
                        val idKey = "androidx.compose.ui.semantics.id"
                        assertTrue(node.availableExtraData.contains(idKey))
                        assertTrue(node.refreshWithExtraData(idKey, android.os.Bundle()))
                        assertTrue(node.extras.containsKey(idKey))
                        assertEquals(semantic.id, node.extras.getInt(idKey))
                    }
                    assertTrue("Expected current image action form: $marker; node=$node",
                        publicImageForm(node, label, native, alt, window))
                    if (alt == null || alt.isEmpty()) assertEquals(0, node.childCount)
                    assertEquals(window, node.windowId)
                    assertTrue(node.actionList.any {
                        it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK
                    })
                    assertEquals(window, ownedWindow())
                    assertTrue(node.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
                } catch (failure: Throwable) {
                    throw AssertionError("$marker; completed activations=$count; selected=$selected", failure)
                } finally { selected?.recycle() }
                count++
                compose.runOnIdle { assertEquals(List(count) { expectedUrl }, opened) }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent { } } }
    }

    @Test fun anonymousFigureAdapterPaintsOneChildAndOwnsCrossCaptionSelectionAndActions() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = android.graphics.Bitmap.createBitmap(40, 30, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.BLUE)
        val settings = AppSettings(allowImages = false, allowAudio = false)
        val media = listOf(Media("Controlled.png", "image", ""))
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val clicked = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        fun nativeOwners(): List<NativeFloatTextView> {
            val result = mutableListOf<NativeFloatTextView>()
            val pending = java.util.ArrayDeque<android.view.View>()
            pending.add(compose.activity.window.decorView)
            var count = 0
            while (pending.isNotEmpty()) {
                check(++count <= 512)
                val view = pending.removeFirst()
                if (view is NativeFloatTextView && view.isShown) result += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { pending.add(view.getChildAt(it)) }
            }
            return result
        }
        try {
            for (outer in listOf(false, true)) for (side in listOf(FigurePlacement.FloatLeft, FigurePlacement.FloatRight)) {
                val before = "${if (outer) "outer" else "direct"}/${side.name} before "
                val caption = "caption אב"
                val after = " after"
                val image = InlineImage("Controlled.png", widthPx = 80, alt = "controlled figure")
                val figure = Figure(FigureContent.Image(Span("link", "", "Image-target", image = image), FigureSizingPolicy.RequestedFit), FigureFormat.Thumbnail,
                    side, FigureClear.None, edges, edges, StyleEdges(zero, zero, StyleLength(StyleLengthUnit.Px, 3f), zero),
                    .884f, StyleLength(StyleLengthUnit.Em, 1.2376f), FigureColor.Transparent, FigureBorder.None,
                    FigureColor.Transparent, FigureBorder.Solid(zero, FigureColor.Rgb("#ff0000")),
                    FigureColor.NativeTheme, FigureColor.Transparent,
                    caption = listOf(Span("link", caption, "Caption-target", direction = "rtl")))
                val flow = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Scope(BidiScope(
                    BidiMode.Isolate, BidiDirectionInput.Auto, BidiResolvedDirection.Rtl, "he",
                    listOf(FlowPart.Inline(listOf(Span("text", before, direction = "rtl"))), FlowPart.ImageFigure(figure),
                        FlowPart.Scope(BidiScope(BidiMode.Isolate, BidiDirectionInput.Rtl, BidiResolvedDirection.Rtl, "",
                            listOf(FlowPart.Inline(listOf(Span("text", after, direction = "rtl")))))))))))
                val expected = before + caption + after
                var flowPosition: androidx.compose.ui.geometry.Offset? = null
                var measuredFlow: NativeAnonymousFlowGeometry? = null
                compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                    androidx.compose.material3.MaterialTheme {
                        CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                            val owner = rememberInlineImageViewOwner(listOf(image), media, settings, "en")
                            remember(owner) {
                                owner.states[image.file] = InlineImageAssetState.Ready(
                                    DecodedMediaBitmap(bitmap, 40, 30), 160, 120, "image/png", "controlled", "")
                                true
                            }
                            CompositionLocalProvider(LocalInlineImageOwner provides owner) {
                                Box(Modifier.width(260.dp).testTag("anonymous-adapter")) {
                                    if (!outer) AnonymousBlockView(flow, Modifier, { clicked += it }, media, settings, "en",
                                        onFlowGeometry = { measuredFlow = it })
                                    else NativeFloatContextLayout(listOf(NativeFloatContextSpec.Flow(0, 0f, null,
                                        ParagraphBox(ParagraphEdges(), ParagraphEdges(top = .25f, left = .25f), .5f, 0f), false) { carried, sink ->
                                        AnonymousBlockView(flow, Modifier.onGloballyPositioned { flowPosition = it.positionInWindow() },
                                            { clicked += it }, media, settings, "en",
                                            interactionOwner = false, carriedExclusions = carried,
                                            onFlowGeometry = { measuredFlow = it; sink(it) })
                                    }), Modifier, androidx.compose.material3.MaterialTheme.colorScheme.primary) { _, _ ->
                                        androidx.compose.material3.Text("Geometry pending")
                                    }
                                }
                            }
                        }
                    }
                } }
                compose.waitUntil(timeoutMillis = 5000) {
                    var ready = false
                    instrumentation.runOnMainSync { ready = nativeOwners().count { it.logicalText.toString() == expected } == 1 }
                    ready
                }
                val captured = compose.onNodeWithTag("anonymous-adapter").captureToImage().asAndroidBitmap()
                try {
                    val pixels = IntArray(captured.width * captured.height)
                    captured.getPixels(pixels, 0, captured.width, 0, 0, captured.width, captured.height)
                    assertTrue("Actual measured child must paint", pixels.any { it == android.graphics.Color.BLUE })
                    assertFalse("Zero image border must not paint a hairline", pixels.any { it == android.graphics.Color.RED })
                } finally { captured.recycle() }
                compose.runOnIdle {
                    val view = nativeOwners().single { it.logicalText.toString() == expected }
                    val nativeFlow = checkNotNull(measuredFlow)
                    assertEquals("\u2067" + before + "\ufffc\u2067" + after + "\u2069\u2069", nativeFlow.offsets.nativeText)
                    assertEquals(before + after, nativeFlow.offsets.logicalText)
                    assertEquals(expected, nativeFlow.text.toString())
                    assertSame(compose.activity.window.decorView, view.rootView)
                    assertTrue(view.hasWindowFocus()); assertTrue(view.isAttachedToWindow)
                    if (outer) {
                        val location = IntArray(2); view.getLocationInWindow(location)
                        val placed = checkNotNull(flowPosition)
                        assertEquals(location[0] + .25f, placed.x, .01f)
                        assertEquals(location[1] + .75f, placed.y, .01f)
                    }
                    val provider = view.accessibilityNodeProvider
                    val host = checkNotNull(provider.createAccessibilityNodeInfo(android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID))
                    try {
                        assertEquals(expected, host.text.toString())
                        assertFalse(host.text?.contains('\ufffc') == true)
                        assertEquals(2, host.childCount)
                    } finally { host.recycle() }
                    val args = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, before.length - 2)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, before.length + caption.length + 2)
                    }
                    assertTrue(provider.performAction(android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID,
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, args))
                    assertEquals(expected.substring(before.length - 2, before.length + caption.length + 2), view.selectedTextForCopy())
                    var captionId: Int? = null
                    for (id in 0 until 2) {
                        val node = checkNotNull(provider.createAccessibilityNodeInfo(id))
                        try { if (node.text?.toString() == caption || node.contentDescription?.toString() == caption) {
                            assertTrue(node.isClickable); assertTrue(node.isEnabled); captionId = id
                        } } finally { node.recycle() }
                    }
                    val old = clicked.size
                    assertTrue(provider.performAction(checkNotNull(captionId), android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals(old + 1, clicked.size); assertEquals(EntryLink("Caption-target"), clicked.last())
                }
                compose.activityRule.scenario.onActivity { it.setContent { } }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent { } }
            compose.waitForIdle()
            bitmap.recycle()
        }
    }

    @Test fun missingFigureWrapsLongLabelAtAuthoredWidthWithFontScalingAndKeepsSelectionActions() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val forbiddenCache = java.io.File(context.cacheDir, "missing-label-uncreated-" + java.util.UUID.randomUUID())
        val cache = MediaCache(context, metadata = { requests.incrementAndGet(); error("Missing label requested metadata") },
            openMedia = { requests.incrementAndGet(); error("Missing label requested pixels") }, directory = forbiddenCache)
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val cluster = "e\u0301"
        val longToken = "Long" + cluster.repeat(45) + "Filename.png"
        val label = "Missing file " + longToken + "\nEnd"
        val target = EntryLink("File:Missing PNG", "")
        val figure = Figure(FigureContent.Missing(
            Span("link", label, target.target, targetFragment = target.targetFragment,
                foreground = "#224466", fontScale = .94f, fontScaleBasis = FontScaleBasis.NormalBody),
            StyleLength(StyleLengthUnit.Px, 180f), StyleLength(StyleLengthUnit.Em, 1.504f)),
            FigureFormat.Thumbnail, FigurePlacement.FloatRight, FigureClear.None,
            edges, StyleEdges(zero, StyleLength(StyleLengthUnit.Px, 3f), zero, StyleLength(StyleLengthUnit.Px, 3f)), edges,
            1f, StyleLength(StyleLengthUnit.Em, 1.5f), FigureColor.Rgb("#ffffff"),
            FigureBorder.Solid(StyleLength(StyleLengthUnit.Px, 1f), FigureColor.Rgb("#000000")),
            FigureColor.Transparent, FigureBorder.None, FigureColor.Rgb("#202122"), FigureColor.Transparent,
            caption = listOf(Span("link", "Retained caption", "Caption-target")), captionTextAlign = CellTextAlign.Left)
        val block = Block("paragraph", 0, emptyList(), flow = listOf(
            FlowPart.Inline(listOf(Span("text", "Before "))), FlowPart.ImageFigure(figure),
            FlowPart.Inline(listOf(Span("text", " After")))), textAlign = CellTextAlign.Right)
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        var fontScale by mutableFloatStateOf(1f)
        var measured: Pair<Float, FloatTextGeometry>? = null
        val heights = mutableListOf<Float>()
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, fontScale), LocalInlineImageCache provides cache) {
                    MaterialTheme(typography = MaterialTheme.typography.copy(
                        bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp))) {
                        androidx.compose.foundation.layout.Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                            AnonymousBlockView(block, Modifier.width(420.dp), { links += it }, emptyList(),
                                AppSettings(allowImages = true, allowAudio = false), "en",
                                onGeometry = { measured = it?.let { value -> fontScale to value } })
                        }
                    }
                }
            } }
            for (scale in listOf(1f, 1.8f)) {
                compose.runOnIdle { if (fontScale != scale) { measured = null; fontScale = scale } }
                compose.waitUntil(timeoutMillis = 5000) { measured?.first == scale }
                compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                compose.runOnIdle {
                    val geometry = checkNotNull(measured).second
                    val text = geometry.text.toString()
                    assertEquals("Before " + label + "\nRetained caption After", text)
                    val start = text.indexOf(label)
                    val rects = geometry.rectsForRange(start, start + label.length)
                    assertTrue("Long token must wrap", rects.size > 2)
                    assertTrue(rects.all { it.width() <= 180.5f })
                    val placed = (geometry as NativeAnonymousFlowGeometry).figures.single()
                    val lastLine = geometry.rectsForRange(start + label.lastIndexOf('\n') + 1, start + label.length).single()
                    assertTrue("Short final line leaves room to distinguish alignment", lastLine.width() < 150f)
                    assertEquals("Missing label centers inside its content box despite the right-aligned parent",
                        placed.bounds.centerX(), lastLine.centerX(), 1.1f)
                    val captionStart = text.indexOf("Retained caption")
                    assertEquals("Caption keeps its independently authored left alignment",
                        placed.bounds.left + 1f, geometry.caretRect(captionStart).left, 1.1f)
                    val tops = rects.map { it.top }.distinct().sorted()
                    assertTrue(tops.size > 2)
                    val expectedHeight = kotlin.math.ceil(1.504f * 20f * scale)
                    assertEquals("Line height uses normal body size once", expectedHeight, tops[1] - tops[0], 1.1f)
                    for (at in label.indices.filter { label[it] == '\u0301' }) {
                        val baseLine = geometry.lineRange(start + at - 1)
                        val combiningLine = geometry.lineRange(start + at)
                        assertEquals("Emergency wrap must preserve a grapheme", baseLine, combiningLine)
                    }
                    val labelNode = geometry.nodes.single { it.label?.toString() == label }
                    assertEquals(start, labelNode.start)
                    assertEquals(start + label.length, labelNode.end)
                    checkNotNull(labelNode.onClick).invoke()
                    assertEquals(target, links.last())
                    assertEquals(1, geometry.nodes.count { it.label?.toString() == "Retained caption" })
                    val pixels = android.graphics.Bitmap.createBitmap(geometry.width, geometry.height,
                        android.graphics.Bitmap.Config.ARGB_8888)
                    try {
                        geometry.paint(android.graphics.Canvas(pixels))
                        var authoredInk = false
                        for (rect in rects) {
                            for (y in rect.top.toInt().coerceAtLeast(0) until kotlin.math.ceil(rect.bottom).toInt().coerceAtMost(pixels.height)) {
                                for (x in rect.left.toInt().coerceAtLeast(0) until kotlin.math.ceil(rect.right).toInt().coerceAtMost(pixels.width)) {
                                    if (pixels.getPixel(x, y) == android.graphics.Color.rgb(0x22, 0x44, 0x66)) authoredInk = true
                                }
                            }
                        }
                        assertTrue("Compiled label ink survives the light frame", authoredInk)
                    } finally { pixels.recycle() }
                    heights += rects.maxOf { it.bottom } - rects.minOf { it.top }
                }
            }
            assertTrue("Enlarged text must reflow at the same content width", heights[1] > heights[0])
            assertEquals(0, requests.get())
            assertFalse(forbiddenCache.exists())
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent { } }
            compose.waitForIdle()
        }
    }

    @Test fun unavailableFigureGeometryKeepsEntryBodyCaptionAndCompiledMapFallbackActions() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val action = ImageMapAction(ImageMapActionKind.Internal, "Mapped-title", "", "Mapped region")
        val map = ImageMap(ImageMapDescription.None,
            listOf(ImageMapRegion(ImageMapShape.Rect, listOf(0.0, 0.0, 10.0, 10.0), action)))
        val figure = Figure(FigureContent.Image(Span("link", "", "File:Must-not-be-background", image = InlineImage("Disabled.png", widthPx = 80,
            alt = "Authored image alt", map = map)), FigureSizingPolicy.RequestedFit), FigureFormat.Thumbnail, FigurePlacement.FloatLeft,
            FigureClear.None, edges, edges, edges, .884f, StyleLength(StyleLengthUnit.Em, 1.2376f),
            FigureColor.NativeTheme, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
            FigureColor.NativeTheme, FigureColor.Transparent, caption = listOf(Span("text", "Retained caption")))
        val block = Block("paragraph", 0, emptyList(), flow = listOf(
            FlowPart.Inline(listOf(Span("text", "Retained before"))), FlowPart.ImageFigure(figure),
            FlowPart.Inline(listOf(Span("text", "Retained after")))))
        val entry = Entry("Unavailable figure", emptyList(), "language", "English", "en",
            listOf(Section(2, "Body", listOf(block))), emptyList(), media = listOf(Media("Disabled.png", "image", "")))
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                androidx.compose.material3.MaterialTheme {
                    EntryView(entry, false, {}, { link -> links += link }, AppSettings(allowImages = false, allowAudio = false,
                        collapseOtherSections = false, collapseDetails = false))
                }
            } }
            val expected = "Retained beforeRetained captionRetained after"
            compose.waitUntil(timeoutMillis = 5000) {
                var ready = false
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    ready = shownNativeFloatOwners().count { it.logicalText.contains(expected) } == 1
                }
                ready
            }
            compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
            compose.runOnIdle {
                val view = shownNativeFloatOwners().single { it.logicalText.contains(expected) }
                val provider = view.accessibilityNodeProvider
                val host = checkNotNull(provider.createAccessibilityNodeInfo(android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID))
                try {
                    assertEquals(view.logicalText.toString(), host.text.toString())
                    assertEquals(1, Regex("Retained caption").findAll(host.text.toString()).count())
                    var mapped: Int? = null
                    var imageFound = false
                    for (id in 0 until host.childCount) {
                        val node = checkNotNull(provider.createAccessibilityNodeInfo(id))
                        try {
                            val label = node.contentDescription?.toString() ?: node.text?.toString().orEmpty()
                            if (label == "Mapped region") { assertTrue(node.isClickable); mapped = id }
                            if (label.contains("Authored image alt")) {
                                imageFound = true
                                assertFalse("An unknown map must not turn its whole image into a region click", node.isClickable)
                                assertTrue(node.stateDescription?.contains("Images disabled") == true)
                            }
                        } finally { node.recycle() }
                    }
                    assertTrue(imageFound)
                    assertTrue(provider.performAction(checkNotNull(mapped), android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals(listOf(EntryLink("Mapped-title", "")), links.toList())
                } finally { host.recycle() }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent { } } }
    }

    @Test fun authoredParagraphBoxesKeepPhysicalEdgesEmptyHeightAndLinkActionsInBothDirections() {
        fun edges(top: Float = 0f, right: Float = 0f, bottom: Float = 0f, left: Float = 0f) = StyleEdges(
            StyleLength(StyleLengthUnit.Px, top), StyleLength(StyleLengthUnit.Px, right),
            StyleLength(StyleLengthUnit.Px, bottom), StyleLength(StyleLengthUnit.Px, left))
        val styled = mutableStateOf<BlockStyle?>(null)
        val empty = mutableStateOf(false)
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        val followed = mutableListOf<EntryLink>()
        val link = Span("link", "Target", "literal#title", targetFragment = "")
        var density = 0f
        fun entry() = Entry("Geometry", emptyList(), "language", "English", "en",
            listOf(Section(2, "", listOf(Block("paragraph", 0, listOf(Span("text", "Before"))),
                Block("paragraph", 0, if (empty.value) emptyList() else listOf(link), style = styled.value),
                Block("paragraph", 0, listOf(Span("text", "After")))))), emptyList())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides direction.value) {
                    DictTheme("light") { androidx.compose.material3.Surface {
                        density = LocalDensity.current.density
                        Box(Modifier.width(320.dp).height(480.dp).testTag("paragraph-geometry")) {
                            EntryView(entry(), false, {}, onLink = { followed += it }, settings = AppSettings(collapseOtherSections = false))
                        }
                    } }
                }
            } }
            fun node(label: String) = compose.onNode(hasText(label) and SemanticsMatcher("Actual paragraph layout") {
                it.config.getOrNull(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) != null
            }, useUnmergedTree = true)
            for (dir in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                compose.runOnIdle { direction.value = dir; styled.value = null; empty.value = false }
                val base = node("Target").fetchSemanticsNode().boundsInRoot
                val baseAfter = node("After").fetchSemanticsNode().boundsInRoot
                compose.runOnIdle { styled.value = BlockStyle(margins = edges(10f, 4f, 7f, 8f), padding = edges(3f, 6f, 5f, 12f)) }
                val target = node("Target")
                val actual = target.fetchSemanticsNode().boundsInRoot
                assertEquals(base.left + 20f * density, actual.left, 2f)
                assertEquals(base.top + 13f * density, actual.top, 2f)
                assertEquals(baseAfter.top + 19f * density, node("After").fetchSemanticsNode().boundsInRoot.top, 3f)
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                target.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                assertEquals("Target", layout.layoutInput.text.text)
                assertFalse(layout.didOverflowHeight)
                compose.runOnIdle {
                    assertPhysicalActivity(compose.activity)
                    check(compose.activity.hasWindowFocus() && compose.activity.window.decorView.hasWindowFocus())
                }
                target.performTouchInput { click(layout.getBoundingBox(0).center) }
                compose.runOnIdle { assertEquals(link.entryLink(), followed.last()) }
                compose.runOnIdle { styled.value = BlockStyle(margins = edges()) }
                assertEquals(base.top, node("Target").fetchSemanticsNode().boundsInRoot.top, 2f)
                assertEquals(baseAfter.top - 6f * density, node("After").fetchSemanticsNode().boundsInRoot.top, 2f)
                compose.runOnIdle { empty.value = true; styled.value = null }
                val emptyBaseAfter = node("After").fetchSemanticsNode().boundsInRoot.top
                compose.runOnIdle { styled.value = BlockStyle(padding = edges()) }
                node("Target").assertDoesNotExist()
                assertEquals(emptyBaseAfter, node("After").fetchSemanticsNode().boundsInRoot.top, 2f)
                compose.runOnIdle { styled.value = BlockStyle(margins = edges(7f, 0f, 11f), padding = edges(3f, 0f, 5f)) }
                assertEquals(emptyBaseAfter + 26f * density, node("After").fetchSemanticsNode().boundsInRoot.top, 3f)
            }
            compose.runOnIdle { assertEquals(listOf(link.entryLink(), link.entryLink()), followed) }
            compose.runOnIdle { empty.value = false; styled.value = BlockStyle(padding = edges(left = 400f)) }
            compose.onNodeWithText("Paragraph layout unavailable at this size").assertIsDisplayed()
            node("Target").assertDoesNotExist()
            compose.runOnIdle { assertEquals(400f, styled.value!!.padding!!.left.value, 0f) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent { } } }
    }

    @Test fun nativeParagraphMarginsDoNotCollapseAcrossInvisibleSectionBoundaries() {
        val separate = mutableStateOf(false)
        val px = { value: Float -> StyleLength(StyleLengthUnit.Px, value) }
        val first = Block("paragraph", 0, listOf(Span("text", "Alpha")), style = BlockStyle(
            margins = StyleEdges(px(0f), px(0f), px(10f), px(0f))))
        val second = Block("paragraph", 0, listOf(Span("text", "Beta")), style = BlockStyle(
            margins = StyleEdges(px(7f), px(0f), px(0f), px(0f))))
        val floated = Block("table", 0, emptyList(), table = Table(emptyList(),
            listOf(listOf(Cell(listOf(Span("text", "Float")), false, 1, 1))), style = TableStyle(floatSide = TableFloatSide.Left)))
        var density = 0f
        fun entry() = Entry("Section geometry", emptyList(), "language", "English", "en",
            if (separate.value) listOf(Section(2, "", listOf(floated, first)), Section(2, "", listOf(second)))
            else listOf(Section(2, "", listOf(floated, first, second))), emptyList())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") { androidx.compose.material3.Surface {
                    density = LocalDensity.current.density
                    Box(Modifier.width(360.dp).height(500.dp)) {
                        EntryView(entry(), false, {}, onLink = {}, settings = AppSettings(collapseOtherSections = false))
                    }
                } }
            } }
            @Suppress("DEPRECATION")
            fun gap(): Float = compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                check(compose.activity.hasWindowFocus() && compose.activity.window.decorView.hasWindowFocus())
                fun descendants(view: android.view.View): List<NativeFloatTextView> = buildList {
                    if (view is NativeFloatTextView) add(view)
                    if (view is android.view.ViewGroup) for (index in 0 until view.childCount) addAll(descendants(view.getChildAt(index)))
                }
                val view = descendants(compose.activity.window.decorView).single { it.logicalText.toString().contains("Alpha") }
                assertEquals("\ufffc\nAlpha\nBeta", view.logicalText.toString())
                val provider = view.accessibilityNodeProvider
                val hostId = android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID
                val info = provider.createAccessibilityNodeInfo(hostId)!!
                fun character(label: String): android.graphics.RectF {
                    val start = info.text.toString().indexOf(label)
                    assertTrue(start >= 0)
                    val args = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX, start)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH, 1)
                    }
                    val key = android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY
                    provider.addExtraDataToAccessibilityNodeInfo(hostId, info, key, args)
                    return (info.extras.getParcelableArray(key)!!.single() as android.graphics.RectF)
                }
                val alpha = character("Alpha"); val beta = character("Beta")
                beta.top - alpha.bottom
            }
            val together = gap()
            compose.runOnIdle { separate.value = true }
            assertEquals(together + 7f * density, gap(), 2f)
        } finally { compose.activityRule.scenario.onActivity { it.setContent { } } }
    }

    @Test fun paragraphEdgesStayInsideOrderedCellAndReferenceContainers() {
        val styled = mutableStateOf(false)
        val px = { value: Float -> StyleLength(StyleLengthUnit.Px, value) }
        val zeroBox = BlockStyle(padding = StyleEdges(px(0f), px(0f), px(0f), px(0f)))
        val box = BlockStyle(margins = StyleEdges(px(7f), px(0f), px(11f), px(5f)),
            padding = StyleEdges(px(3f), px(0f), px(5f), px(9f)))
        var density = 0f
        fun blocks(label: String) = listOf(Block("paragraph", 0, listOf(Span("text", "$label before"))),
            Block("paragraph", 0, emptyList(), style = if (styled.value) box else zeroBox),
            Block("paragraph", 0, listOf(Span("text", "$label after"))))
        fun entry(): Entry {
            val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = blocks("Cell")))))
            return Entry("Nested geometry", emptyList(), "language", "English", "en",
                listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = table)))),
                listOf(Reference(1, 1, "", emptyList(), blocks = blocks("Reference"))))
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") { androidx.compose.material3.Surface {
                    density = LocalDensity.current.density
                    Box(Modifier.width(340.dp).height(600.dp)) {
                        EntryView(entry(), false, {}, onLink = {}, settings = AppSettings(collapseOtherSections = false))
                    }
                } }
            } }
            val cellBefore = compose.onNodeWithText("Cell before").fetchSemanticsNode().boundsInRoot
            val cellAfter = compose.onNodeWithText("Cell after").fetchSemanticsNode().boundsInRoot
            val refBefore = compose.onNodeWithText("Reference before").fetchSemanticsNode().boundsInRoot
            val refAfter = compose.onNodeWithText("Reference after").fetchSemanticsNode().boundsInRoot
            compose.runOnIdle { styled.value = true }
            val newCellBefore = compose.onNodeWithText("Cell before").fetchSemanticsNode().boundsInRoot
            val newCellAfter = compose.onNodeWithText("Cell after").fetchSemanticsNode().boundsInRoot
            val newRefBefore = compose.onNodeWithText("Reference before").fetchSemanticsNode().boundsInRoot
            val newRefAfter = compose.onNodeWithText("Reference after").fetchSemanticsNode().boundsInRoot
            // Each independent container keeps its own old spacing; only the empty source box grows.
            assertEquals(cellBefore.left, newCellBefore.left, 1f)
            assertEquals(cellAfter.left, newCellAfter.left, 1f)
            assertEquals(refBefore.left, newRefBefore.left, 1f)
            assertEquals(refAfter.left, newRefAfter.left, 1f)
            assertEquals(cellAfter.top - cellBefore.bottom + 26f * density,
                newCellAfter.top - newCellBefore.bottom, 3f)
            assertEquals(refAfter.top - refBefore.bottom + 26f * density,
                newRefAfter.top - newRefBefore.bottom, 3f)
        } finally { compose.activityRule.scenario.onActivity { it.setContent { } } }
    }

    @Test fun authoredAdviceUsesTextDetailsWithoutReplacingTextOrInternalLinkActions() {
        val sg = Span("link", "\\bə.lɑs.tɪŋ\\", "Aide:Sêndagô/Holandëe", classes = "API", tooltip = "Sêndagô API")
        val uz = Span("link", "koʻchma", "Vikilugʻat:Shartli qisqartmalar", italic = true,
            background = "#ccffff", tooltip = "koʻchma soʻz", targetFragment = "")
        val suppressed = Span("link", "Suppressed", "page", explanation = "Expansion B", tooltip = "")
        val spans = listOf(sg, uz, suppressed)
        val entry = Entry("Authored advice", emptyList(), "language", "Language", "und",
            listOf(Section(3, "Notes", spans.map { Block("paragraph", 0, listOf(it)) } +
                Block("paragraph", 0, listOf(Span("text", "", tooltip = "Description-only advice"))))), emptyList())
        val followed = mutableListOf<EntryLink>()
        val inputModeManager = java.util.concurrent.atomic.AtomicReference<androidx.compose.ui.input.InputModeManager>()
        val originalInputMode = java.util.concurrent.atomic.AtomicReference<androidx.compose.ui.input.InputMode?>()
        var primaryFailure: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val manager = androidx.compose.ui.platform.LocalInputModeManager.current
                SideEffect { inputModeManager.set(manager); originalInputMode.compareAndSet(null, manager.inputMode) }
                DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                    Box(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
                        EntryView(entry, false, {}, onLink = { followed += it }, settings = AppSettings(
                            collapseDetails = true, collapseOtherSections = false))
                    }
                } }
            } }
            for (span in spans) {
                val textNode = compose.onNode(hasText(span.text) and SemanticsMatcher("Own text layout") {
                    it.config.getOrNull(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) != null
                }, useUnmergedTree = true)
                textNode.performScrollTo().assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                textNode.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                assertEquals(span.text, layout.layoutInput.text.text)
                assertNull(textNode.fetchSemanticsNode().config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription))
                val point = layout.getBoundingBox(0).center
                textNode.performTouchInput { click(point) }
            }
            compose.runOnIdle {
                assertEquals(spans.map { it.entryLink() }, followed)
                assertEquals(listOf("Expansion B"), entry.abbreviations.map { it.explanation })
                assertEquals(listOf("Sêndagô API", "koʻchma soʻz", "Description-only advice"),
                    entry.textDetails.filter { it.kind == TextDetailKind.Advisory }.map { it.description })
            }
            val details = compose.onNodeWithTag("entry-abbreviations")
            details.performScrollTo().assertIsDisplayed().performClick()
            for (description in listOf("Expansion B", "Sêndagô API", "koʻchma soʻz", "Description-only advice")) {
                val index = entry.textDetails.indexOfFirst { it.description == description }
                assertTrue(index >= 0)
                val prefix = if (entry.textDetails[index].kind == TextDetailKind.Abbreviation) "abbreviation-" else "advisory-"
                compose.onNodeWithTag("entry-scroll").performScrollToKey(prefix + index)
                compose.onNodeWithText(description).assertIsDisplayed()
            }
            val manager = checkNotNull(inputModeManager.get())
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                assertTrue(compose.activity.hasWindowFocus() && compose.activity.window.decorView.hasWindowFocus())
                assertTrue(manager.requestInputMode(androidx.compose.ui.input.InputMode.Keyboard))
            }
            compose.waitUntil(10000) { manager.inputMode == androidx.compose.ui.input.InputMode.Keyboard }
            details.performScrollTo().performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus) { assertTrue(it()) }
            details.assertIsFocused().performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            compose.onNodeWithText("Sêndagô API").assertDoesNotExist()
            compose.onNodeWithText("koʻchma soʻz").assertDoesNotExist()
            compose.onNodeWithText("Description-only advice").assertDoesNotExist()
            details.performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            val descriptionIndex = entry.textDetails.indexOfFirst { it.description == "Description-only advice" }
            compose.onNodeWithTag("entry-scroll").performScrollToKey("advisory-" + descriptionIndex)
            compose.onNodeWithText("Description-only advice").assertIsDisplayed()
            compose.runOnIdle { assertEquals(spans.map { it.entryLink() }, followed) }
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            try {
                val manager = inputModeManager.get()
                val previous = originalInputMode.get()
                if (manager != null && previous != null) {
                    compose.runOnIdle {
                        assertPhysicalActivity(compose.activity)
                        assertTrue(compose.activity.hasWindowFocus() && compose.activity.window.decorView.hasWindowFocus())
                        manager.requestInputMode(previous)
                    }
                    if (previous == androidx.compose.ui.input.InputMode.Touch && manager.inputMode != previous) {
                        val point = java.util.concurrent.atomic.AtomicReference<IntArray>()
                        val downTime = android.os.SystemClock.uptimeMillis()
                        for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
                            compose.runOnIdle {
                                assertPhysicalActivity(compose.activity)
                                val decor = compose.activity.window.decorView
                                assertTrue(compose.activity.hasWindowFocus() && decor.hasWindowFocus())
                                val content = checkNotNull(compose.activity.findViewById<android.view.View>(android.R.id.content))
                                assertTrue(content.isShown && content.width > 2 && content.height > 2)
                                val origin = IntArray(2).also { content.getLocationOnScreen(it) }
                                val visible = android.graphics.Rect().also { decor.getWindowVisibleDisplayFrame(it) }
                                assertTrue(visible.intersect(android.graphics.Rect(origin[0], origin[1], origin[0] + content.width, origin[1] + content.height)))
                                assertTrue(visible.width() > 2 && visible.height() > 2)
                                val current = intArrayOf(visible.left + 1, visible.top + 1)
                                if (point.get() == null) point.set(current) else assertTrue(point.get().contentEquals(current))
                            }
                            val location = checkNotNull(point.get())
                            val event = android.view.MotionEvent.obtain(downTime, android.os.SystemClock.uptimeMillis(), action,
                                location[0].toFloat(), location[1].toFloat(), 0).apply { source = android.view.InputDevice.SOURCE_TOUCHSCREEN }
                            try { InstrumentationRegistry.getInstrumentation().sendPointerSync(event) } finally { event.recycle() }
                        }
                    }
                    compose.waitUntil(10000) { manager.inputMode == previous }
                    compose.runOnIdle { assertEquals(previous, manager.inputMode) }
                }
            } catch (cleanup: Throwable) {
                if (primaryFailure != null) primaryFailure.addSuppressed(cleanup) else throw cleanup
            } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        }
    }

    @Test fun inlineAudioTableUsesMeasuredColumnsBesideFloatsAndKeepsActionsAfterNarrowing() {
        val width = mutableStateOf(600)
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        val failures = java.util.concurrent.CopyOnWriteArrayList<String>()
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val audio = Span("link", "Audio", "File:Controlled.ogg", classes = "wikidict-media")
        val details = Span("link", "Details", "Details-target", fontScale = .8f,
            fontScaleBasis = FontScaleBasis.NormalBody)
        val floated = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text",
            "Float\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7")), false, 1, 1))),
            style = TableStyle(floatSide = TableFloatSide.Left, width = StyleWidth(StyleWidthUnit.Px, 120f), margins = edges))
        val inline = Table(emptyList(), listOf(listOf(
            Cell(listOf(Span("text", "เสียง:")), false, 1, 1),
            Cell(listOf(audio), false, 1, 1), Cell(listOf(details), false, 1, 1))),
            style = TableStyle(display = TableDisplay.InlineBlock, verticalAlign = InlineBoxVerticalAlign.Middle,
                lineHeight = ComputedLineHeight(1f), collapse = TableCollapse.Collapse, margins = edges))
        val entry = Entry("Inline table", emptyList(), "language", "English", "en",
            listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = floated),
                Block("list_item", 1, emptyList(), listPath = "*", table = inline)))), emptyList(),
            media = listOf(Media("Controlled.ogg", "audio", "Audio")))
        var bodyLineHeight = 0f
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    androidx.compose.ui.platform.LocalLayoutDirection provides direction.value,
                    LocalNativeFloatContextFailureObserver provides { failures += it }) {
                    DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        bodyLineHeight = androidx.compose.material3.MaterialTheme.typography.bodyLarge.fontSize.value
                        Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.TopStart) {
                            Box(Modifier.width(width.value.dp).height(700.dp)) {
                                EntryView(entry, false, {}, onLink = { links += it }, settings = AppSettings(
                                    allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false))
                            }
                        }
                    } }
                }
            } }
            fun grid(columns: Int) = compose.onNode(SemanticsMatcher("Compiled grid with $columns columns") {
                it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag)
                    ?.startsWith("compiled-table-grid") == true &&
                    it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.CollectionInfo)?.columnCount == columns
            }, useUnmergedTree = true)
            for (dir in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                for (viewport in listOf(600, 320)) {
                    compose.runOnIdle { direction.value = dir; width.value = viewport }
                    compose.waitForIdle()
                    compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                    compose.runOnIdle { assertTrue(failures.toString(), failures.isEmpty()) }
                    // One logical inline table must expose one set of public controls.
                    compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
                    compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
                    val floatBox = grid(1).fetchSemanticsNode().boundsInRoot
                    val tableBox = grid(3).fetchSemanticsNode().boundsInRoot
                    if (viewport == 600) {
                        assertTrue("Inline grid must fit in the measured free interval", tableBox.left >= floatBox.right - 1f)
                        assertTrue("It must remain beside the float", tableBox.top < floatBox.bottom)
                        assertTrue("Natural table must not stretch to the entire entry", tableBox.width < viewport - 120f)
                    } else {
                        assertTrue("A too-narrow interval must move the intact table below the float", tableBox.top >= floatBox.bottom - 1f)
                    }
                    val label = compose.onNodeWithText("เสียง:", useUnmergedTree = true).assertIsDisplayed()
                    val detail = compose.onNodeWithText("Details", useUnmergedTree = true).assertIsDisplayed()
                    val labelBounds = label.fetchSemanticsNode().boundsInRoot
                    val detailBounds = detail.fetchSemanticsNode().boundsInRoot
                    if (dir == androidx.compose.ui.unit.LayoutDirection.Ltr) assertTrue(labelBounds.left < detailBounds.left)
                    else assertTrue(labelBounds.left > detailBounds.left)
                    val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                    detail.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                    assertEquals("Details", layouts.single().layoutInput.text.text)
                    assertEquals("Table-origin 1em is not multiplied by the cell's 80% span", bodyLineHeight,
                        layouts.single().layoutInput.style.lineHeight.value, .01f)
                    compose.runOnIdle {
                        assertPhysicalActivity(compose.activity)
                        check(compose.activity.hasWindowFocus() && compose.activity.window.decorView.hasWindowFocus())
                    }
                    detail.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                    compose.runOnIdle { assertEquals(EntryLink("Details-target"), links.last()) }
                }
            }
            compose.runOnIdle { assertEquals(4, links.size) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun atomicInlineTableKeepsOneLiveAudioOwnerAcrossResizeAndErrorRemeasure(): Unit = runBlocking {
        val key = mediaKey(Media("Atomic.wav", "audio", "Audio"), "")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            java.io.File(context.cacheDir, "inline-table-" + java.util.UUID.randomUUID()).apply { check(mkdirs()) }
        }
        fun empty() = runBlocking(kotlinx.coroutines.Dispatchers.IO) { directory.listFiles().orEmpty().isEmpty() }
        var primaryFailure: Throwable? = null
        try {
            val samples = ByteArray(60 * 8000) { 128.toByte() }
            val wav = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                .put("RIFF".toByteArray()).putInt(36 + samples.size).put("WAVEfmt ".toByteArray())
                .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(8000).putShort(1).putShort(8)
                .put("data".toByteArray()).putInt(samples.size).array() + samples
            val calls = java.util.concurrent.atomic.AtomicInteger()
            val cache = MediaCache(context, directory = directory, metadata = {
                if (calls.incrementAndGet() > 1) throw java.io.IOException("Controlled metadata failure")
                """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/silence.wav","descriptionurl":"https://fixture.invalid/source"}]}]}}""".toByteArray()
            }, openMedia = { java.io.ByteArrayInputStream(wav) })
            val media = Media("Atomic.wav", "audio", "Audio")
            val width = mutableStateOf(600)
            val pulse = mutableStateOf(0)
            val geometryFailure = mutableStateOf(false)
            val failures = java.util.concurrent.CopyOnWriteArrayList<String>()
            val floatTable = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "Float\n2\n3\n4\n5\n6\n7")), false, 1, 1))),
                style = TableStyle(floatSide = TableFloatSide.Left, width = StyleWidth(StyleWidthUnit.Px, 120f)))
            val table = Table(emptyList(), listOf(listOf(
                Cell(listOf(Span("text", "Audio:")), false, 1, 1),
                Cell(listOf(Span("link", "Listen", "File:Atomic.wav", classes = "wikidict-media")), false, 1, 1))),
                style = TableStyle(display = TableDisplay.InlineBlock, verticalAlign = InlineBoxVerticalAlign.Middle,
                    lineHeight = ComputedLineHeight(1f)))
            val richCell = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
                blocks = listOf(Block("table", 0, emptyList(), table = floatTable),
                    Block("list_item", 1, emptyList(), listPath = "*", table = table)),
                style = CellStyle(letterSpacing = StyleLength(StyleLengthUnit.Px, 0f),
                    width = StyleWidth(StyleWidthUnit.Percent, 100f))))),
                style = TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 100f)))
            val entry = Entry("Atomic media", emptyList(), "language", "English", "en",
                listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = richCell)))),
                emptyList(), media = listOf(media))
            val playerState = MediaPlayback::class.java.getDeclaredField("player\$delegate").apply { isAccessible = true }
            fun player() = (playerState.get(MediaPlayback) as androidx.compose.runtime.State<*>).value as? android.media.MediaPlayer
            var ownedPlayer: android.media.MediaPlayer? = null
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalInlineImageCache provides cache,
                    LocalNativeFloatContextFailureObserver provides { failures += it }) {
                    val revision = pulse.value
                    DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.TopStart) {
                            Box(Modifier.width(width.value.dp).height(700.dp)) {
                                NativeFloatContextLayout(listOf(
                                    NativeFloatContextSpec.Child(0, { it }, 0f, atomicInline = true),
                                    NativeFloatContextSpec.Child(1, {
                                        if (geometryFailure.value) throw UnsupportedFloatLayout("Controlled later child failure")
                                        1
                                    }, 0f)), Modifier, androidx.compose.material3.MaterialTheme.colorScheme.primary) { id, _ ->
                                    if (id == 0) Box(Modifier.height(650.dp)) {
                                        EntryView(entry, false, {}, onLink = { check(revision >= 0) }, settings = AppSettings(
                                            allowImages = false, allowAudio = true, mediaCacheMb = 0,
                                            collapseOtherSections = false, collapseDetails = false))
                                    } else Text("Tail")
                                }
                            }
                        }
                    } }
                }
            } }
            compose.onNodeWithContentDescription("Play pronunciation").assertIsDisplayed().performClick()
            compose.waitUntil(15000) {
                var ready = false
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    ready = MediaPlayback.playing == key && player()?.isPlaying == true
                }
                ready
            }
            compose.runOnIdle { ownedPlayer = checkNotNull(player()) }
            compose.onNodeWithContentDescription("Source and licence").assertIsDisplayed()
            for (nextWidth in listOf(600, 320, 600)) {
                compose.runOnIdle { width.value = nextWidth; pulse.value++ }
                compose.waitForIdle()
                compose.onAllNodesWithContentDescription("Stop pronunciation").assertCountEquals(1)
                compose.onAllNodesWithContentDescription("Source and licence").assertCountEquals(1)
                compose.runOnIdle {
                    assertSame(ownedPlayer, player())
                    assertEquals(key, MediaPlayback.playing)
                    assertTrue(checkNotNull(ownedPlayer).isPlaying)
                    assertEquals(1, calls.get())
                    assertTrue(failures.toString(), failures.isEmpty())
                }
            }
            for (fail in listOf(true, false)) {
                compose.runOnIdle { geometryFailure.value = fail }
                compose.waitForIdle()
                compose.onAllNodesWithContentDescription("Stop pronunciation").assertCountEquals(1)
                compose.onNodeWithContentDescription("Stop pronunciation").assertIsDisplayed()
                compose.onAllNodesWithContentDescription("Source and licence").assertCountEquals(1)
                if (fail) compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
                else compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                compose.runOnIdle { assertSame(ownedPlayer, player()); assertTrue(checkNotNull(ownedPlayer).isPlaying); assertEquals(1, calls.get()) }
            }
            compose.runOnIdle {
                assertEquals(listOf("Controlled later child failure"), failures.toList())
                failures.clear()
            }
            compose.onNodeWithContentDescription("Stop pronunciation").performClick()
            compose.waitUntil(10000) { empty() }
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            compose.onNodeWithContentDescription("Play pronunciation").performClick()
            compose.waitUntil(15000) {
                compose.onAllNodesWithText("Pronunciation could not be played.").fetchSemanticsNodes(atLeastOneRootRequired = false).size == 1
            }
            for (nextWidth in listOf(320, 600)) {
                compose.runOnIdle { width.value = nextWidth; pulse.value++ }
                compose.waitForIdle()
                compose.onAllNodesWithText("Pronunciation could not be played.").assertCountEquals(1)
                compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
                compose.runOnIdle { assertEquals(2, calls.get()); assertNull(MediaPlayback.playing); assertTrue(failures.toString(), failures.isEmpty()) }
            }
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            var cleanupFailure: Throwable? = null
            fun recordCleanup(failure: Throwable) {
                val prior = cleanupFailure
                if (prior == null) cleanupFailure = failure else prior.addSuppressed(failure)
            }
            try { compose.activityRule.scenario.onActivity { it.setContent {} } }
            catch (cleanup: Throwable) { recordCleanup(cleanup) }
            try { compose.runOnIdle { if (MediaPlayback.playing == key) MediaPlayback.stop() } }
            catch (cleanup: Throwable) { recordCleanup(cleanup) }
            try {
                compose.waitUntil(10000) { empty() }
                kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.IO) {
                    check(directory.listFiles().orEmpty().isEmpty())
                    check(directory.delete())
                }
            } catch (cleanup: Throwable) { recordCleanup(cleanup) }
            cleanupFailure?.let { cleanup ->
                val primary = primaryFailure
                if (primary != null) primary.addSuppressed(cleanup) else throw cleanup
            }
        }
    }

    @Test fun inlineImageTopTableRemeasuresLoadedIntrinsicAndKeepsOneAudioOwner(): Unit = runBlocking {
        // Controlled resources exercise the existing reader path, not a live Commons availability claim.
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            java.io.File(context.cacheDir, "inline-image-top-" + java.util.UUID.randomUUID()).apply { check(mkdirs()) }
        }
        val imageRelease = java.util.concurrent.CountDownLatch(1)
        val imageCalls = java.util.concurrent.atomic.AtomicInteger()
        val audioCalls = java.util.concurrent.atomic.AtomicInteger()
        val imageDownloads = java.util.concurrent.atomic.AtomicInteger()
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        val failures = java.util.concurrent.CopyOnWriteArrayList<String>()
        val audio = Media("Inline top.wav", "audio", "Audio")
        val key = mediaKey(audio, "")
        var primaryFailure: Throwable? = null
        try {
            val png = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                val bitmap = android.graphics.Bitmap.createBitmap(80, 20, android.graphics.Bitmap.Config.ARGB_8888)
                try {
                    bitmap.eraseColor(android.graphics.Color.RED)
                    java.io.ByteArrayOutputStream().also { check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }.toByteArray()
                } finally { bitmap.recycle() }
            }
            val samples = ByteArray(60 * 8000) { 128.toByte() }
            val wav = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                .put("RIFF".toByteArray()).putInt(36 + samples.size).put("WAVEfmt ".toByteArray())
                .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(8000).putShort(1).putShort(8)
                .put("data".toByteArray()).putInt(samples.size).array() + samples
            val cache = MediaCache(context, directory = directory, metadata = { query ->
                val title = java.net.URLDecoder.decode(query.substringAfter("titles="), "UTF-8")
                if (title == "File:Inline top.wav") {
                    audioCalls.incrementAndGet()
                    """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/top.wav","descriptionurl":"https://fixture.invalid/audio-source"}]}]}}""".toByteArray()
                } else {
                    check(title == "File:Controlled.png")
                    if (imageCalls.incrementAndGet() == 1) {
                        check(imageRelease.await(15, java.util.concurrent.TimeUnit.SECONDS))
                        throw java.io.IOException("Controlled image request failure")
                    }
                    """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/top.png","descriptionurl":"https://fixture.invalid/image-source","width":80,"height":20,"mime":"image/png"}]}]}}""".toByteArray()
                }
            }, openMedia = { url ->
                if (url.endsWith(".wav")) java.io.ByteArrayInputStream(wav)
                else { imageDownloads.incrementAndGet(); java.io.ByteArrayInputStream(png) }
            })
            val width = mutableStateOf(600)
            val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
            val settings = mutableStateOf(AppSettings(allowImages = false, allowAudio = true, mediaCacheMb = 0,
                collapseOtherSections = false, collapseDetails = false))
            val image = Span("link", "", "Image-target", fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody,
                classes = "wikidict-media wikidict-media-file-436f6e74726f6c6c65642e706e67",
                image = InlineImage("Controlled.png", alt = "", tooltip = "Controlled icon", border = true))
            val zero = StyleLength(StyleLengthUnit.Px, 0f)
            val table = Table(emptyList(), listOf(listOf(
                Cell(listOf(image, Span("text", " Hoa Ky")), false, 1, 1),
                Cell(listOf(Span("link", "Listen", "File:Inline top.wav", classes = "wikidict-media")), false, 1, 1))),
                geometry = TableGeometry(cellSpacing = 0, cellPadding = 0), style = TableStyle(
                    display = TableDisplay.InlineBlock, verticalAlign = InlineBoxVerticalAlign.Top,
                    margins = StyleEdges(zero, zero, zero, zero), border = StyleBorder.None))
            val block = Block("list_item", 1, emptyList(), listPath = "*", table = table)
            val entry = Entry("Image and audio", emptyList(), "language", "English", "en",
                listOf(Section(2, "", listOf(block))), emptyList(), media = listOf(Media("Controlled.png", "image", "Icon"), audio))
            val imageMatcher = SemanticsMatcher("One compiled inline image") {
                it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Role) == androidx.compose.ui.semantics.Role.Image &&
                    it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.StateDescription) != null
            }
            fun imageNode() = compose.onNode(imageMatcher, useUnmergedTree = true)
            fun gridNode() = compose.onNode(SemanticsMatcher("Two-column compiled grid") {
                it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag)?.startsWith("compiled-table-grid") == true &&
                    it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.CollectionInfo)?.columnCount == 2
            }, useUnmergedTree = true)
            fun waitImage(state: String) = compose.waitUntil(15000) {
                val nodes = compose.onAllNodes(imageMatcher, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false)
                nodes.size == 1 && nodes.single().config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.StateDescription) == state
            }
            val playerState = MediaPlayback::class.java.getDeclaredField("player\$delegate").apply { isAccessible = true }
            fun player() = (playerState.get(MediaPlayback) as androidx.compose.runtime.State<*>).value as? android.media.MediaPlayer
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalInlineImageCache provides cache,
                    androidx.compose.ui.platform.LocalLayoutDirection provides direction.value,
                    LocalNativeFloatContextFailureObserver provides { failures += it }) {
                    DictTheme("light") { Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.TopStart) {
                        Box(Modifier.width(width.value.dp).height(700.dp)) {
                            EntryView(entry, false, {}, onLink = { links += it }, settings = settings.value)
                        }
                    } }
                }
            } }
            waitImage("Images disabled")
            val disabledWidth = gridNode().fetchSemanticsNode().boundsInRoot.width
            assertEquals(0, imageCalls.get())
            compose.runOnIdle { settings.value = settings.value.copy(allowImages = true) }
            waitImage("Loading image")
            assertEquals(disabledWidth, gridNode().fetchSemanticsNode().boundsInRoot.width, 1f)
            imageRelease.countDown()
            waitImage("Image unavailable")
            imageNode().performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnLongClick) { assertTrue(it()) }
            compose.onNodeWithText("Retry image").assertIsDisplayed().performClick()
            waitImage("")
            assertEquals(2, imageCalls.get()); assertEquals(1, imageDownloads.get())
            assertEquals(82f, imageNode().fetchSemanticsNode().boundsInRoot.width, 1f)
            assertTrue("Loaded intrinsic plus border must replace the status marker in real table measurement",
                gridNode().fetchSemanticsNode().boundsInRoot.width > disabledWidth + 40f)
            val captured = imageNode().captureToImage().asAndroidBitmap()
            try {
                var red = 0
                for (y in 0 until captured.height) for (x in 0 until captured.width) {
                    val color = captured.getPixel(x, y)
                    if (android.graphics.Color.red(color) > 240 && android.graphics.Color.green(color) < 15 && android.graphics.Color.blue(color) < 15) red++
                }
                assertTrue("The loaded placeholder must paint the actual bitmap", red >= 78 * 18)
            } finally { captured.recycle() }
            compose.onNodeWithContentDescription("Play pronunciation").assertIsDisplayed().performClick()
            compose.waitUntil(15000) {
                var playing = false
                InstrumentationRegistry.getInstrumentation().runOnMainSync { playing = MediaPlayback.playing == key && player()?.isPlaying == true }
                playing
            }
            val ownedPlayer = compose.runOnIdle { checkNotNull(player()) }
            for (dir in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                for (viewport in listOf(600, 320)) {
                    compose.runOnIdle { direction.value = dir; width.value = viewport }
                    compose.waitForIdle()
                    compose.onAllNodes(imageMatcher, useUnmergedTree = true).assertCountEquals(1)
                    compose.onAllNodesWithText(blockPrefix(block), useUnmergedTree = true).assertCountEquals(1)
                    compose.onAllNodesWithContentDescription("Stop pronunciation").assertCountEquals(1)
                    compose.onAllNodesWithContentDescription("Source and licence").assertCountEquals(1)
                    val grid = gridNode().fetchSemanticsNode().boundsInRoot
                    val marker = compose.onNodeWithText(blockPrefix(block), useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                    assertTrue("Top aligns the intact table with the parent line, not its last baseline", marker.top - grid.top in -1f..20f)
                    assertTrue(grid.height > marker.height + 8f)
                    assertTrue(grid.width < viewport)
                    compose.runOnIdle {
                        assertSame(ownedPlayer, player()); assertEquals(key, MediaPlayback.playing)
                        assertTrue(failures.toString(), failures.isEmpty())
                        assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
                    }
                    imageNode().performTouchInput { click(center) }
                    compose.runOnIdle { assertEquals(EntryLink("Image-target"), links.last()) }
                }
            }
            assertEquals(4, links.size); assertEquals(1, audioCalls.get()); assertEquals(2, imageCalls.get())
            compose.onNodeWithContentDescription("Stop pronunciation").performClick()
            compose.waitUntil(10000) { MediaPlayback.playing == null }
        } catch (failure: Throwable) { primaryFailure = failure; throw failure }
        finally {
            imageRelease.countDown()
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.runOnIdle { if (MediaPlayback.playing == key) MediaPlayback.stop() }
                compose.waitUntil(10000) { runBlocking(kotlinx.coroutines.Dispatchers.IO) { directory.listFiles().orEmpty().isEmpty() } }
                kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.IO) { check(directory.delete()) }
            } catch (cleanup: Throwable) { if (primaryFailure != null) primaryFailure.addSuppressed(cleanup) else throw cleanup }
        }
    }

    @Test fun explicitCellTopUsesPaddedTopBesideTallerCellAndRetainsSourceActions() {
        val explicitTop = mutableStateOf(true)
        val width = mutableStateOf(600)
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        var normalBodyPixels = 0f
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val padding = StyleEdges(StyleLength(StyleLengthUnit.Em, 1.14f), zero, zero, StyleLength(StyleLengthUnit.Px, 3f))
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    androidx.compose.ui.platform.LocalLayoutDirection provides direction.value) {
                    DictTheme("light") {
                        normalBodyPixels = androidx.compose.material3.MaterialTheme.typography.bodyLarge.fontSize.value
                        val style = CellStyle(padding = padding, verticalAlign = if (explicitTop.value) CellVerticalAlign.Top else null)
                        val table = Table(emptyList(), listOf(listOf(
                            Cell(listOf(Span("link", "Top target", "Top-target", fontScale = .95f,
                                fontScaleBasis = FontScaleBasis.NormalBody)), false, 1, 1, style = style),
                            Cell(listOf(Span("text", "Tall cell\nsecond\nthird\nfourth")), false, 1, 1,
                                style = CellStyle(padding = StyleEdges(zero, zero, zero, zero))))),
                            geometry = TableGeometry(cellSpacing = 0, cellPadding = 0),
                            style = TableStyle(border = StyleBorder.None, margins = StyleEdges(zero, zero, zero, zero)))
                        val entry = Entry("Cell top", emptyList(), "language", "English", "en",
                            listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = table)))), emptyList())
                        Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.TopStart) {
                            Box(Modifier.width(width.value.dp).height(700.dp)) {
                                EntryView(entry, false, {}, onLink = { links += it }, settings = AppSettings(
                                    collapseOtherSections = false, collapseDetails = false))
                            }
                        }
                    }
                }
            } }
            fun cell(column: Int) = compose.onNode(SemanticsMatcher("Cell $column") {
                it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.CollectionItemInfo)?.let { info ->
                    info.rowIndex == 0 && info.columnIndex == column
                } == true
            }, useUnmergedTree = true)
            for (dir in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                for (viewport in listOf(600, 320)) {
                    var topPosition: androidx.compose.ui.geometry.Rect? = null
                    for (top in listOf(true, false)) {
                        compose.runOnIdle { explicitTop.value = top; direction.value = dir; width.value = viewport }
                        compose.waitForIdle()
                        val target = compose.onNodeWithText("Top target", useUnmergedTree = true).assertIsDisplayed()
                        val bounds = target.fetchSemanticsNode().boundsInRoot
                        val left = cell(0).fetchSemanticsNode().boundsInRoot
                        val right = cell(1).fetchSemanticsNode().boundsInRoot
                        assertEquals(left.top, right.top, 1f)
                        assertEquals(kotlin.math.round(normalBodyPixels * 1.14f), bounds.top - left.top, 1f)
                        assertTrue("Taller sibling must leave free space below the short top-aligned content", right.bottom - bounds.bottom > 20f)
                        if (top) topPosition = bounds else assertEquals("Absent policy keeps the prior top placement", topPosition, bounds)
                        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                        target.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                        assertEquals("Top target", layouts.single().layoutInput.text.text)
                        compose.runOnIdle { assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus()) }
                        target.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                        compose.runOnIdle { assertEquals(EntryLink("Top-target"), links.last()) }
                    }
                }
            }
            assertEquals(8, links.size)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun retainedAnonymousFlowKeepsItsActionOwnerAndClearsFailedGeometry() {
        val laterFailure = mutableStateOf(false)
        val localFailure = mutableStateOf(false)
        val pulse = mutableStateOf(0)
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        val block = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Inline(
            listOf(Span("link", "Retained flow action", "Flow-target")))))
        var input: NativeFlowMeasureInput? = null
        var published: FloatTextGeometry? = null
        val field = NativeFloatTextView::class.java.getDeclaredField("geometry").apply { isAccessible = true }
        fun activate() {
            val owner = shownNativeFloatOwners().single { it.logicalText.contains("Retained flow action") }
            val geometry = field.get(owner) as FloatTextGeometry
            val node = geometry.nodes.single { it.label?.toString() == "Retained flow action" && it.onClick != null }
            val provider = owner.accessibilityNodeProvider
            val publicNode = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
            try {
                assertTrue(publicNode.isVisibleToUser)
                assertTrue(publicNode.isClickable)
                assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
            } finally { publicNode.recycle() }
        }
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                        val revision = pulse.value
                        NativeFloatContextLayout(listOf(
                            NativeFloatContextSpec.Flow(0, 0f, null, null, false) { carried, sink ->
                                input = LocalNativeFlowMeasureInput.current
                                AnonymousBlockView(block, if (localFailure.value) Modifier.height(1.dp) else Modifier,
                                    { links += it }, emptyList(), AppSettings(allowImages = false, allowAudio = false), "",
                                    interactionOwner = false, carriedExclusions = carried, onFlowGeometry = sink,
                                    onGeometry = { published = it })
                            },
                            NativeFloatContextSpec.Child(1, {
                                check(revision >= 0)
                                if (laterFailure.value) throw UnsupportedFloatLayout("Controlled later flow sibling")
                                1
                            }, 0f)), Modifier.width(300.dp), MaterialTheme.colorScheme.primary) { _, _ -> Text("Tail") }
                    }
                } }
            } }
            compose.waitForIdle()
            compose.runOnIdle { assertNotNull(published); assertNotNull(input?.geometry); activate() }
            compose.runOnIdle { laterFailure.value = true }
            compose.waitForIdle()
            compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
            compose.runOnIdle { assertNotNull(published); assertNotNull(input?.geometry); activate(); pulse.value++ }
            compose.waitForIdle()
            compose.runOnIdle { assertNotNull(input?.geometry); activate(); localFailure.value = true }
            compose.waitForIdle()
            compose.runOnIdle {
                assertNull("Actual child failure invalidates the previous publication", published)
                assertNull(input?.geometry)
                assertTrue("No stale native action owner", shownNativeFloatOwners().none { it.logicalText.contains("Retained flow action") })
                localFailure.value = false
                laterFailure.value = false
            }
            compose.waitForIdle()
            compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
            compose.runOnIdle { assertNotNull(published); assertNotNull(input?.geometry); activate() }
            assertEquals(List(4) { EntryLink("Flow-target") }, links.toList())
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun realFigureCaptionRecoversAfterItsTableOutgrowsTheContentBox() {
        val wide = mutableStateOf(false)
        val pulse = mutableStateOf(0)
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        var published: FloatTextGeometry? = null
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val field = NativeFloatTextView::class.java.getDeclaredField("geometry").apply { isAccessible = true }
        fun activateCaption() {
            val owner = shownNativeFloatOwners().single { it.logicalText.contains("Caption action") }
            val geometry = field.get(owner) as FloatTextGeometry
            val node = geometry.nodes.single { it.label?.toString() == "Caption action" && it.onClick != null }
            val provider = owner.accessibilityNodeProvider
            val publicNode = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
            try {
                assertTrue(publicNode.isVisibleToUser)
                assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
            } finally { publicNode.recycle() }
        }
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                            val revision = pulse.value
                            val table = Table(emptyList(), listOf(listOf(Cell(
                                listOf(Span("link", "Caption action", "Caption-target")), false, 1, 1,
                                style = CellStyle(width = StyleWidth(StyleWidthUnit.Px, 60f))))),
                                style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, if (wide.value) 360f else 180f)))
                            val figure = Figure(FigureContent.Missing(Span("text", "Missing image"),
                                StyleLength(StyleLengthUnit.Px, 240f), StyleLength(StyleLengthUnit.Em, 1.5f)),
                                FigureFormat.Thumbnail, FigurePlacement.FloatRight, FigureClear.None,
                                edges, edges, edges, 1f, StyleLength(StyleLengthUnit.Em, 1.5f),
                                FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
                                FigureColor.NativeTheme, FigureColor.Transparent, caption = emptyList(),
                                captionBlocks = listOf(Block("table", 0, emptyList(), table = table)))
                            val block = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.ImageFigure(figure)))
                            AnonymousBlockView(block, Modifier.width(420.dp), { links += it }, emptyList(),
                                AppSettings(allowImages = false, allowAudio = false), "",
                                onGeometry = { check(revision >= 0); published = it })
                        }
                    } }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle { assertNotNull(published); activateCaption(); wide.value = true }
            compose.waitForIdle()
            compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
            compose.runOnIdle {
                assertNull("The real caption failure clears its previous geometry", published)
                assertTrue(shownNativeFloatOwners().none { it.logicalText.contains("Caption action") })
                pulse.value++
            }
            compose.waitForIdle()
            compose.runOnIdle { assertNull(published); wide.value = false }
            compose.waitForIdle()
            compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
            compose.runOnIdle { assertNotNull(published); activateCaption() }
            assertEquals(List(2) { EntryLink("Caption-target") }, links.toList())
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun failedAtomicMeasureIsNotRetriedByTheSamePassFallback() {
        val fail = mutableStateOf(true)
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        val failedNodeDisposals = java.util.concurrent.atomic.AtomicInteger()
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.TopStart) {
                        Box(Modifier.width(300.dp)) {
                            NativeFloatContextLayout(listOf(NativeFloatContextSpec.Child(0, { it }, 0f,
                                atomicInline = true)), Modifier, androidx.compose.material3.MaterialTheme.colorScheme.primary) { _, _ ->
                                val failThisNode = fail.value
                                // A thrown Compose measure leaves that node in Measuring. Recovery
                                // replaces this deliberately broken test node, not a live media owner.
                                androidx.compose.runtime.key(failThisNode) {
                                    androidx.compose.runtime.DisposableEffect(failThisNode) {
                                        onDispose { if (failThisNode) failedNodeDisposals.incrementAndGet() }
                                    }
                                    androidx.compose.ui.layout.Layout(content = {}, modifier = Modifier.testTag("atomic-owned")) { _, _ ->
                                        attempts.incrementAndGet()
                                        if (failThisNode) throw UnsupportedFloatLayout("Controlled atomic measure failure")
                                        layout(80, 30) { }
                                    }
                                }
                            }
                        }
                    }
                } }
            } }
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Unable to display this layout.").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.runOnIdle { assertEquals("The failed child must not be measured again by fallback", 1, attempts.get()); fail.value = false }
            compose.waitForIdle()
            compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
            compose.onNodeWithTag("atomic-owned").assertIsDisplayed()
            compose.runOnIdle {
                assertEquals("The deliberately failed node must be disposed", 1, failedNodeDisposals.get())
                assertTrue("Replacement node must actually be measured", attempts.get() > 1)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun plainFigureTableCaptionInheritsComputedTableLineHeight() {
        val observed = java.util.concurrent.atomic.AtomicReference<FloatTextGeometry>()
        val table = Table(listOf(Span("text", "Top"), Span("line_break", ""), Span("text", "Bottom")),
            listOf(listOf(Cell(listOf(Span("text", "Cell", fontScale = .8f)), false, 1, 1))),
            style = TableStyle(lineHeight = ComputedLineHeight(2f)))
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.TopStart) {
                            Box(Modifier.width(300.dp)) {
                                FigureCaptionTable(table, AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null),
                                    androidx.compose.material3.MaterialTheme.typography.bodyLarge.copy(fontSize = 18.sp, lineHeight = 20.sp),
                                    FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false), "", {}, remember { Any() })) {
                                        observed.set(it)
                                    }
                            }
                        }
                    } }
                }
            } }
            compose.waitUntil(10000) { observed.get()?.text?.contains("Bottom") == true }
            compose.runOnIdle {
                val geometry = checkNotNull(observed.get())
                val text = geometry.text.toString()
                val top = text.indexOf("Top"); val bottom = text.indexOf("Bottom")
                assertTrue(top >= 0 && bottom > top)
                val first = geometry.rectsForRange(top, top + 1).single()
                val second = geometry.rectsForRange(bottom, bottom + 1).single()
                assertEquals(36f, second.top - first.top, 2f)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun leadingListTableShowsOneMarkerAndContinuationKeepsBodyAndActions() {
        val floating = mutableStateOf(false)
        val followed = mutableListOf<EntryLink>()
        fun table(label: String) = Table(emptyList(), listOf(listOf(
            Cell(listOf(Span("link", label, target = label)), false, 1, 1))),
            style = if (floating.value) TableStyle(floatSide = TableFloatSide.Left) else null)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val leading = Block("list_item", 1, emptyList(), listPath = "*", table = table("Leading cell"))
                val continuation = Block("table", 1, emptyList(), listPath = "*", table = table("Continuation cell"))
                val entry = Entry("Bullet tables", emptyList(), "language", "English", "en",
                    listOf(Section(3, "Noun", listOf(leading, continuation))), emptyList())
                DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                    EntryView(entry, false, {}, onLink = { followed += it },
                        settings = AppSettings(collapseDetails = false, collapseOtherSections = false))
                } }
            } }
            for (float in listOf(false, true)) {
                compose.runOnIdle { floating.value = float }
                compose.onAllNodesWithText("• ", useUnmergedTree = true).assertCountEquals(1)
                val markerBounds = compose.onNodeWithText("• ", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val firstRowBounds = compose.onNodeWithText("Leading cell").fetchSemanticsNode().boundsInRoot
                assertTrue(markerBounds.right <= firstRowBounds.left + 1f)
                assertTrue(markerBounds.top < firstRowBounds.bottom && markerBounds.bottom > firstRowBounds.top)
                compose.onNodeWithText("Leading cell").assertIsDisplayed().performClick()
                compose.onNodeWithText("Continuation cell").assertIsDisplayed().performClick()
                compose.runOnIdle {
                    assertEquals(listOf("Leading cell", "Continuation cell"), followed.takeLast(2).map { it.target })
                }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun textDetailsExposeAuthoredAudioCaptionAndAbbreviationWithoutChangingBodyActions() {
        val file = "En-us-girl.ogg"
        val audio = Span("link", file, "File:$file",
            classes = "wikidict-media wikidict-media-file-456e2d75732d6769726c2e6f6767", explanation = "Audio (US)")
        val entry = Entry("girl", emptyList(), "language", "English", "en", listOf(
            Section(3, "Pronunciation", listOf(Block("paragraph", 0, listOf(audio)))),
            Section(3, "Noun", listOf(Block("paragraph", 0, listOf(Span("text", "f", explanation = "feminine")))))),
            emptyList(), media = listOf(Media(file, "audio", file)), edition = "enwiktionary-20260901")
        val links = mutableListOf<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") {
                    EntryView(entry, false, {}, onLink = { links += it.target }, settings = AppSettings(
                        allowImages = false, allowAudio = false, collapsePronunciation = false,
                        collapseOtherSections = false, collapseDetails = true))
                }
            } }
            val details = compose.onNodeWithTag("entry-abbreviations")
            details.assertTextEquals("Text details").assertHasClickAction()
            details.assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription, "Collapsed"))
            compose.onNodeWithText("Abbreviations").assertDoesNotExist()
            compose.onNodeWithText("Audio (US)").assertDoesNotExist()
            compose.onNodeWithText("feminine").assertDoesNotExist()
            compose.onNodeWithText(file).assertIsDisplayed()
            details.performClick()
            details.assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription, "Expanded"))
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Audio (US)"))
            compose.onNodeWithText("Audio (US)").assertIsDisplayed()
            compose.onNodeWithText("Pronunciation: $file").assertIsDisplayed()
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("feminine"))
            compose.onNodeWithText("feminine").assertIsDisplayed()
            compose.onNodeWithText("Noun: f").assertIsDisplayed()
            compose.onNodeWithTag("entry-scroll").performScrollToIndex(0)
            details.performClick()
            compose.onNodeWithText("Audio (US)").assertDoesNotExist()
            compose.onNodeWithText("feminine").assertDoesNotExist()
            val body = compose.onNodeWithText(file)
            body.assertIsDisplayed()
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            body.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val text = layouts.single().layoutInput.text
            assertEquals(file, text.text)
            val link = text.getLinkAnnotations(0, text.length).single().item as androidx.compose.ui.text.LinkAnnotation.Clickable
            assertEquals("File:$file", link.tag)
            compose.runOnIdle { assertTrue(links.isEmpty()) }
            body.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
            compose.runOnIdle { assertEquals(listOf("File:$file"), links) }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
        }
    }

    @Test fun activeQuizClueFollowsQuestionAndDropsLateResultsWithoutChangingSavedPreview() {
        val first = SavedWord("first", "First", "English", "language", "First stored preview",
            dictionary = "first-dictionary", recordKey = "1\tFirst", edition = "test-edition")
        val second = first.copy(key = "second", title = "Second", clue = "Second stored preview",
            dictionary = "second-dictionary", recordKey = "1\tSecond")
        val words = listOf(first, second)
        val revision = mutableStateOf(1)
        val requests = java.util.Collections.synchronizedList(mutableListOf<Pair<SavedWord, kotlinx.coroutines.CompletableDeferred<String?>>>())
        val answers = mutableListOf<Pair<String, Boolean>>()
        var closing = false
        var primaryFailure: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") {
                    androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                          Box(Modifier.height(420.dp)) {
                            LearnPanel(words, 3, { key, right -> answers += key to right }, {}, {},
                                libraryRevision = revision.value, loadStudyClue = { word ->
                                    val result = kotlinx.coroutines.CompletableDeferred<String?>()
                                    synchronized(requests) {
                                        requests += word to result
                                        if (closing) result.complete(null)
                                    }
                                    // A late non-cooperative loader must not publish into another question.
                                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { result.await() }
                                })
                          }
                        }
                    }
                }
            } }
            compose.waitUntil(10000) { requests.size == 1 }
            val question = requests[0].first
            val other = words.single { it.key != question.key }
            compose.onNodeWithText(question.clue).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("0 correct · 0 of 3").assertExists()
            compose.runOnIdle { assertTrue(answers.isEmpty()); revision.value++ }
            compose.waitUntil(10000) { requests.size == 2 }
            val firstMeaning = "Parent context · A specific current meaning."
            compose.runOnIdle { requests[1].second.complete(firstMeaning) }
            compose.waitUntil(10000) { compose.onAllNodesWithText(firstMeaning).fetchSemanticsNodes().size == 1 }
            compose.runOnIdle { requests[0].second.complete("Stale library revision") }
            compose.waitForIdle()
            compose.onNodeWithText("Stale library revision").assertDoesNotExist()
            compose.onNodeWithText(firstMeaning).assertExists()
            compose.runOnIdle { revision.value++ }
            compose.waitUntil(10000) { requests.size == 3 }
            compose.onNodeWithText(question.clue).assertExists()
            compose.onNodeWithText(other.title).performScrollTo().performClick()
            compose.onNodeWithText("Answer: ${question.title}").assertExists()
            compose.onNodeWithText("0 correct · 1 of 3").assertExists()
            compose.runOnIdle { assertEquals(listOf(question.key to false), answers) }
            compose.onNodeWithText("Next").performScrollTo().performClick()
            compose.waitUntil(10000) { requests.size == 4 }
            compose.runOnIdle { assertEquals(other, requests[3].first) }
            compose.onNodeWithText(other.clue).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText(question.clue).assertDoesNotExist()
            compose.onNodeWithText(firstMeaning).assertDoesNotExist()
            compose.runOnIdle { requests[2].second.complete("Stale previous question") }
            compose.waitForIdle()
            compose.onNodeWithText("Stale previous question").assertDoesNotExist()
            compose.onNodeWithText(other.clue).assertExists()
            compose.runOnIdle { requests[3].second.complete(null) }
            compose.waitForIdle()
            compose.onNodeWithText(other.clue).assertExists()
            compose.runOnIdle { revision.value++ }
            compose.waitUntil(10000) { requests.size == 5 }
            compose.runOnIdle { requests[4].second.completeExceptionally(java.io.IOException("Controlled missing record")) }
            compose.waitForIdle()
            compose.onNodeWithText(other.clue).assertExists()
            compose.runOnIdle { revision.value++ }
            compose.waitUntil(10000) { requests.size == 6 }
            val currentMeaning = "Other parent context · A useful distinguishing meaning."
            compose.runOnIdle { requests[5].second.complete(currentMeaning) }
            compose.waitUntil(10000) { compose.onAllNodesWithText(currentMeaning).fetchSemanticsNodes().size == 1 }
            val clue = compose.onNodeWithText(currentMeaning)
            withRenderedLayoutFailureEvidence("Active Quiz question clue", clue, compose.onRoot(), null,
                ownedState = { "question=${other.key}; requests=${requests.map { it.first.key }}; answers=$answers" }) {
                clue.performScrollTo().assertIsDisplayed()
                compose.onNodeWithText("0 correct · 1 of 3").assertExists()
                compose.onNodeWithText("Answer: ${question.title}").assertDoesNotExist()
                compose.onNodeWithText("Next").assertDoesNotExist()
                compose.onNodeWithText(first.title).performScrollTo().assertIsDisplayed().assertIsEnabled()
                compose.onNodeWithText(second.title).performScrollTo().assertIsDisplayed().assertIsEnabled()
            }
            compose.runOnIdle {
                assertEquals(listOf(question, question, question, other, other, other), requests.map { it.first })
                assertEquals(listOf(question.key to false), answers)
                assertEquals("First stored preview", first.clue)
                assertEquals("Second stored preview", second.clue)
            }
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            try {
                synchronized(requests) {
                    closing = true
                    requests.forEach { it.second.complete(null) }
                }
                compose.activityRule.scenario.onActivity { it.setContent {} }
            } catch (cleanup: Throwable) {
                if (primaryFailure != null) primaryFailure.addSuppressed(cleanup) else throw cleanup
            }
        }
    }

    @Test fun activeCardClueKeepsFallbackAcrossRevisionCancellationAndScrollableLongAnswer() {
        val first = SavedWord("first", "First", "English", "language", "First stored preview",
            dictionary = "first-dictionary", recordKey = "1\tFirst", edition = "test-edition")
        val second = first.copy(key = "second", title = "Second", clue = "Second stored preview",
            dictionary = "second-dictionary", recordKey = "1\tSecond")
        val pool = mutableStateOf(listOf(first))
        val revision = mutableStateOf(1)
        val requests = java.util.Collections.synchronizedList(mutableListOf<Pair<SavedWord, kotlinx.coroutines.CompletableDeferred<String?>>>())
        val opened = mutableListOf<SavedWord>()
        val longAnswer = "Parent context · " + "A useful descendant meaning with retained context. ".repeat(8)
        var primaryFailure: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") {
                    androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                          Box(Modifier.height(260.dp)) {
                            LearnPanel(pool.value, 3, { _, _ -> error("No rating selected") }, { opened += it }, {},
                                libraryRevision = revision.value, loadStudyClue = { word ->
                                    val result = kotlinx.coroutines.CompletableDeferred<String?>()
                                    requests += word to result
                                    // Deliberately ignore cancellation until released to exercise stale-result protection.
                                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { result.await() }
                                })
                          }
                        }
                    }
                }
            } }
            compose.runOnIdle { assertTrue(requests.isEmpty()) }
            compose.onNodeWithText("Cards").performScrollTo().performClick()
            compose.waitUntil(10000) { requests.size == 1 }
            val recall = "Recall the meaning, then tap to reveal."
            compose.onNodeWithText(recall).performScrollTo().performClick()
            compose.onNodeWithText(first.clue).assertExists()
            compose.runOnIdle { revision.value++ }
            compose.waitUntil(10000) { requests.size == 2 }
            compose.runOnIdle { requests[1].second.complete("Parent context · Current meaning") }
            compose.waitUntil(10000) { compose.onAllNodesWithText("Parent context · Current meaning").fetchSemanticsNodes().size == 1 }
            compose.runOnIdle { requests[0].second.complete("Stale answer") }
            compose.waitForIdle()
            compose.onNodeWithText("Stale answer").assertDoesNotExist()
            compose.onNodeWithText("Parent context · Current meaning").assertExists()
            compose.runOnIdle { pool.value = listOf(second) }
            compose.waitUntil(10000) { requests.size == 3 }
            compose.onNodeWithText(recall).performScrollTo().performClick()
            compose.onNodeWithText(second.clue).assertExists()
            compose.runOnIdle { requests[2].second.complete(null) }
            compose.waitForIdle()
            compose.onNodeWithText(second.clue).assertExists()
            compose.runOnIdle { revision.value++ }
            compose.waitUntil(10000) { requests.size == 4 }
            compose.runOnIdle { requests[3].second.completeExceptionally(java.io.IOException("Controlled missing record")) }
            compose.waitForIdle()
            compose.onNodeWithText(second.clue).assertExists()
            compose.runOnIdle { revision.value++ }
            compose.waitUntil(10000) { requests.size == 5 }
            compose.runOnIdle { requests[4].second.complete(longAnswer) }
            compose.waitUntil(10000) { compose.onAllNodesWithText(longAnswer).fetchSemanticsNodes().size == 1 }
            // The card merges title and answer semantics; its layout action can belong to the title.
            val answer = compose.onNodeWithText(longAnswer, useUnmergedTree = true)
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            withRenderedLayoutFailureEvidence("Active card long answer", answer, compose.onRoot(), null,
                ownedState = { "expectedText=$longAnswer; observedLayoutTexts=" + layouts.map { it.layoutInput.text.text } }) {
                answer.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                assertEquals(1, layouts.size)
                val layout = layouts.single()
                assertEquals(longAnswer, layout.layoutInput.text.text)
                assertTrue(layout.lineCount > 1)
                assertFalse(layout.hasVisualOverflow)
                for (line in 0 until layout.lineCount) assertFalse(layout.isLineEllipsized(line))
            }
            compose.onNodeWithText("Read").performScrollTo().assertIsDisplayed().performClick()
            compose.runOnIdle {
                assertEquals(listOf(second), opened)
                assertEquals(listOf(first, first, second, second, second), requests.map { it.first })
                assertEquals("First stored preview", first.clue)
                assertEquals("Second stored preview", second.clue)
            }
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            try {
                synchronized(requests) { requests.forEach { it.second.complete(null) } }
                compose.activityRule.scenario.onActivity { it.setContent {} }
            } catch (cleanup: Throwable) {
                if (primaryFailure != null) primaryFailure.addSuppressed(cleanup) else throw cleanup
            }
        }
    }

    @Test fun typedInlineImagesUseOneCanonicalAssetAndKeepZeroFontInkAndCompiledActionsWithControlledPng(): Unit = runBlocking {
        // Controlled PNG/UI/resource test only, not actual HE SVG availability.
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            java.io.File(context.cacheDir, "typed-inline-" + java.util.UUID.randomUUID()).apply { mkdirs() }
        }
        val png = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val bitmap = android.graphics.Bitmap.createBitmap(100, 300, android.graphics.Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(android.graphics.Color.RED)
                java.io.ByteArrayOutputStream().also { assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }.toByteArray()
            } finally { bitmap.recycle() }
        }
        val metadataCalls = java.util.concurrent.atomic.AtomicInteger()
        val downloads = java.util.concurrent.atomic.AtomicInteger()
        val queries = java.util.Collections.synchronizedList(mutableListOf<String>())
        val opened = mutableListOf<String>()
        val links = mutableListOf<String>()
        val forceFailure = java.util.concurrent.atomic.AtomicBoolean()
        val metadata = """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/controlled.png","descriptionurl":"https://commons.wikimedia.org/wiki/File:Different_asset_description","width":100,"height":300,"mime":"image/png"}]}]}}""".toByteArray()
        val cache = MediaCache(context, metadata = { query ->
            val attempt = metadataCalls.incrementAndGet(); queries += query
            if (attempt == 1 || forceFailure.get()) throw java.io.IOException("Controlled image request failure")
            metadata
        },
            openMedia = { downloads.incrementAndGet(); java.io.ByteArrayInputStream(png) }, directory = directory)
        val file = "File:Controlled.png"
        val first = Span("link", "", "File:File:Controlled.png", fontScale = 0f, small = true, image = InlineImage(file, 15, border = true))
        val second = Span("link", "", "Target", fontScale = 0f, image = InlineImage(file, 30, alt = "Body alternative", tooltip = "Body tooltip"))
        val unlinked = Span("text", "", image = InlineImage(file, 20, alt = "Unlinked alternative", tooltip = "Unlinked details", border = true))
        val heading = Block("heading", 0, listOf(Span("text", "Heading "), first), level = 3, anchor = "Heading")
        val legacyCatalogue = Span("link", "Legacy caption", first.target, classes = "wikidict-media")
        val entry = Entry("Inline image control", emptyList(), "language", "English", "en", listOf(Section(3, "Heading",
            listOf(heading, Block("paragraph", 0, listOf(Span("text", "Before "), second, Span("text", " After"))),
                Block("paragraph", 0, listOf(unlinked)), Block("paragraph", 0, listOf(legacyCatalogue))))), emptyList(),
            media = listOf(Media(file, "image", "Distinct catalogue caption")), edition = "hewiktionary-20261001")
        val settings = mutableStateOf(AppSettings(allowImages = false, mediaCacheMb = 0,
            collapseOtherSections = false, collapseDetails = false))
        var displayDensity = 1f
        val inputModeManager = java.util.concurrent.atomic.AtomicReference<androidx.compose.ui.input.InputModeManager>()
        val originalInputMode = java.util.concurrent.atomic.AtomicReference<androidx.compose.ui.input.InputMode>()
        var primaryFailure: Throwable? = null
        val images = SemanticsMatcher("Typed inline image state") { node ->
            node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Role) == androidx.compose.ui.semantics.Role.Image &&
                node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.StateDescription) != null
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") {
                    val density = LocalDensity.current
                    val manager = androidx.compose.ui.platform.LocalInputModeManager.current
                    SideEffect {
                        displayDensity = density.density
                        inputModeManager.set(manager)
                        originalInputMode.compareAndSet(null, manager.inputMode)
                    }
                    CompositionLocalProvider(LocalInlineImageCache provides cache,
                        androidx.compose.ui.platform.LocalUriHandler provides object : androidx.compose.ui.platform.UriHandler {
                            override fun openUri(uri: String) { opened += uri }
                        }) { EntryView(entry, false, {}, onLink = { links += it.target }, settings = settings.value) }
                }
            } }
            compose.waitUntil(15000) { compose.onAllNodes(images, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).size == 3 }
            assertEquals(0, metadataCalls.get()); assertEquals(0, downloads.get())
            compose.onNodeWithText("Body alternative").assertIsDisplayed()
            assertTrue(compose.onNodeWithText("Body alternative").fetchSemanticsNode().boundsInRoot.width > 30f * displayDensity)
            // Keep static failed-state pixels independent of a preceding press indication.
            // The ready-image check below separately exercises the real click path.
            compose.onAllNodes(images, useUnmergedTree = true)[0].performSemanticsAction(
                androidx.compose.ui.semantics.SemanticsActions.OnClick) { assertTrue(it()) }
            compose.runOnIdle { assertEquals("https://he.wiktionary.org/wiki/File%3AFile%3AControlled.png", opened.single()); settings.value = settings.value.copy(allowImages = true) }
            compose.waitUntil(15000) {
                val nodes = compose.onAllNodes(images, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false)
                nodes.size == 3 && nodes.all { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.StateDescription) == "Image unavailable" }
            }
            val failedNode = compose.onAllNodes(images, useUnmergedTree = true)[0]
            val failedSemantic = failedNode.fetchSemanticsNode()
            val failedImage = failedNode.captureToImage().asAndroidBitmap()
            val rgbaMin = IntArray(4) { 255 }
            val rgbaMax = IntArray(4)
            var closestRgbDistance = Int.MAX_VALUE
            var closestColor = 0
            try {
                var left = failedImage.width; var top = failedImage.height; var right = -1; var bottom = -1
                for (y in 0 until failedImage.height) for (x in 0 until failedImage.width) {
                    val pixel = failedImage.getPixel(x, y)
                    val rgba = intArrayOf(android.graphics.Color.red(pixel), android.graphics.Color.green(pixel),
                        android.graphics.Color.blue(pixel), android.graphics.Color.alpha(pixel))
                    for (channel in rgba.indices) {
                        rgbaMin[channel] = minOf(rgbaMin[channel], rgba[channel])
                        rgbaMax[channel] = maxOf(rgbaMax[channel], rgba[channel])
                    }
                    val distance = maxOf(kotlin.math.abs(rgba[0] - 234), kotlin.math.abs(rgba[1] - 236),
                        kotlin.math.abs(rgba[2] - 240))
                    if (distance < closestRgbDistance) { closestRgbDistance = distance; closestColor = pixel }
                    if (kotlin.math.abs(android.graphics.Color.red(pixel) - 234) <= 2 &&
                        kotlin.math.abs(android.graphics.Color.green(pixel) - 236) <= 2 &&
                        kotlin.math.abs(android.graphics.Color.blue(pixel) - 240) <= 2) {
                        left = minOf(left, x); top = minOf(top, y); right = maxOf(right, x); bottom = maxOf(bottom, y)
                    }
                }
                assertTrue("The failed-state marker must preserve the compiled outside border", right >= left && bottom >= top)
                assertEquals(17f * displayDensity, (right - left + 1).toFloat(), 2f)
                assertEquals(17f * displayDensity, (bottom - top + 1).toFloat(), 2f)
            } catch (failure: AssertionError) {
                val pixels = runCatching {
                    "density=$displayDensity; capture=${failedImage.width}x${failedImage.height}; " +
                        "nodeBounds=${failedSemantic.boundsInRoot}; nodeState=" +
                        failedSemantic.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.StateDescription) +
                        "; nodeName=" + failedSemantic.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription) +
                        "; rgbaMin=${rgbaMin.contentToString()}; rgbaMax=${rgbaMax.contentToString()}; " +
                        "closestRgbDistance=$closestRgbDistance; closestArgb=${Integer.toHexString(closestColor)}"
                }.getOrElse { "PIXEL_METADATA_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
                val evidence = runCatching {
                    renderedLayoutFailureEvidence("Failed inline image outside border", null, failedSemantic,
                        failedNode, "inline-image-failed-border.png", capturedBitmap = failedImage)
                }.getOrElse { "IMAGE_EVIDENCE_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
                throw AssertionError(failure.message + "\n" + pixels + "\n" + evidence, failure)
            } finally { failedImage.recycle() }
            // Retry/details on an unlinked image must be reachable without inventing a link.
            val manager = checkNotNull(inputModeManager.get())
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                assertTrue(compose.activity.hasWindowFocus() && compose.activity.window.decorView.hasWindowFocus())
                assertTrue("The platform must accept keyboard input mode", manager.requestInputMode(androidx.compose.ui.input.InputMode.Keyboard))
            }
            compose.waitUntil(10000) { manager.inputMode == androidx.compose.ui.input.InputMode.Keyboard }
            compose.onAllNodes(images, useUnmergedTree = true)[2].performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus) { assertTrue(it()) }
            compose.onAllNodes(images, useUnmergedTree = true)[2].assertIsFocused()
            compose.onAllNodes(images, useUnmergedTree = true)[2].performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            val retryAction = compose.onNode(hasText("Retry image") and hasAnyAncestor(isPopup()))
            retryAction.assertIsDisplayed().assertIsEnabled().assertHasClickAction()
            retryAction.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus) { assertTrue(it()) }
            retryAction.assertIsFocused()
            compose.runOnIdle {
                assertEquals(androidx.compose.ui.input.InputMode.Keyboard, manager.inputMode)
                assertEquals(1, metadataCalls.get()); assertEquals(0, downloads.get())
                assertEquals(1, opened.size); assertTrue(links.isEmpty())
            }
            retryAction.performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            compose.onNode(isPopup()).assertDoesNotExist()
            compose.runOnIdle { assertEquals(1, opened.size); assertTrue(links.isEmpty()) }
            compose.waitUntil(15000) {
                val nodes = compose.onAllNodes(images, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false)
                nodes.size == 3 && nodes.all { it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.StateDescription) == "" }
            }
            compose.waitUntil(15000) { kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) { directory.listFiles().orEmpty().isEmpty() } }
            assertEquals(2, metadataCalls.get()); assertEquals(1, downloads.get())
            assertEquals(2, queries.size)
            assertTrue(queries.all { it.contains("titles=File%3AFile%3AControlled.png") })
            compose.onAllNodesWithText("Body alternative").assertCountEquals(0)
            val firstNode = compose.onAllNodes(images, useUnmergedTree = true)[0]
            assertEquals(listOf("Open image link: File:Controlled.png"),
                firstNode.fetchSemanticsNode().config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription))
            assertEquals(17f * displayDensity, firstNode.fetchSemanticsNode().boundsInRoot.width, 1f)
            val captured = firstNode.captureToImage().asAndroidBitmap()
            try {
                var left = captured.width; var top = captured.height; var right = -1; var bottom = -1
                var borderLeft = captured.width; var borderTop = captured.height; var borderRight = -1; var borderBottom = -1
                for (y in 0 until captured.height) for (x in 0 until captured.width) {
                    val pixel = captured.getPixel(x, y)
                    if (android.graphics.Color.red(pixel) > 240 && android.graphics.Color.green(pixel) < 15 && android.graphics.Color.blue(pixel) < 15) {
                        left = minOf(left, x); top = minOf(top, y); right = maxOf(right, x); bottom = maxOf(bottom, y)
                    }
                    if (kotlin.math.abs(android.graphics.Color.red(pixel) - 234) <= 2 &&
                        kotlin.math.abs(android.graphics.Color.green(pixel) - 236) <= 2 &&
                        kotlin.math.abs(android.graphics.Color.blue(pixel) - 240) <= 2) {
                        borderLeft = minOf(borderLeft, x); borderTop = minOf(borderTop, y)
                        borderRight = maxOf(borderRight, x); borderBottom = maxOf(borderBottom, y)
                    }
                }
                assertTrue("Zero-font image must contain actual visible bitmap ink", right >= left && bottom >= top)
                assertEquals(15f * displayDensity, (right - left + 1).toFloat(), 2f)
                assertEquals(45f * displayDensity, (bottom - top + 1).toFloat(), 2f)
                assertTrue("The compiled border must paint outside the unchanged bitmap", borderLeft < left && borderTop < top && borderRight > right && borderBottom > bottom)
                assertEquals(17f * displayDensity, (borderRight - borderLeft + 1).toFloat(), 2f)
                assertEquals(47f * displayDensity, (borderBottom - borderTop + 1).toFloat(), 2f)
                assertEquals(displayDensity, (left - borderLeft).toFloat(), 1f)
                assertEquals(displayDensity, (top - borderTop).toFloat(), 1f)
                assertEquals(displayDensity, (borderRight - right).toFloat(), 1f)
                assertEquals(displayDensity, (borderBottom - bottom).toFloat(), 1f)
            } finally { captured.recycle() }
            firstNode.performClick()
            compose.runOnIdle { assertEquals(opened[0], opened[1]); assertTrue(links.isEmpty()) }
            compose.onAllNodes(images, useUnmergedTree = true)[1].performClick()
            compose.runOnIdle { assertEquals(listOf("Target"), links) }
            compose.runOnIdle { assertEquals(androidx.compose.ui.input.InputMode.Keyboard, manager.inputMode) }
            compose.onAllNodes(images, useUnmergedTree = true)[1].performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus) { assertTrue(it()) }
            compose.onAllNodes(images, useUnmergedTree = true)[1].assertIsFocused()
            compose.onAllNodes(images, useUnmergedTree = true)[1].performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            compose.runOnIdle { assertEquals(listOf("Target", "Target"), links); assertEquals(1, downloads.get()) }
            compose.onAllNodes(images, useUnmergedTree = true)[2].performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus) { assertTrue(it()) }
            compose.onAllNodes(images, useUnmergedTree = true)[2].assertIsFocused()
            compose.onAllNodes(images, useUnmergedTree = true)[2].performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            compose.onNodeWithText("Unlinked details").assertIsDisplayed()
            compose.onNodeWithText("Source and licence").assertIsDisplayed().performClick()
            compose.runOnIdle {
                assertEquals(listOf("Target", "Target"), links)
                assertEquals(3, opened.size)
                assertEquals("https://commons.wikimedia.org/wiki/File:Different_asset_description", opened.last())
                assertEquals(1, downloads.get())
            }
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Distinct catalogue caption"))
            compose.onNodeWithText("Distinct catalogue caption").assertIsDisplayed()
            compose.onNodeWithTag("entry-scroll").performScrollToIndex(0)
            compose.waitForIdle()
            assertEquals(2, metadataCalls.get()); assertEquals(1, downloads.get())

            // The outside border must not give long fallback text extra wrapping width.
            // A controlled narrow WindowInfo exercises the normal measurement path
            // within the real window; no foreign display or app state is changed.
            val longAlt = "Long alternative near a wrapping boundary. ".repeat(8)
            val longImage = InlineImage(file, 15, alt = longAlt, tooltip = "Fallback details", border = true)
            val fallbackSettings = mutableStateOf(settings.value.copy(allowImages = false))
            val fallbackEntry = Entry("Fallback image control", emptyList(), "language", "English", "en",
                listOf(Section(2, "English", listOf(Block("paragraph", 0,
                    listOf(Span("text", "", image = longImage)))))), emptyList(),
                media = listOf(Media(file, "image", "")), edition = "hewiktionary-20261001")
            val expectedLayout = java.util.concurrent.atomic.AtomicReference<androidx.compose.ui.text.TextLayoutResult>()
            forceFailure.set(true)
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") {
                    val density = LocalDensity.current
                    val actualWindow = androidx.compose.ui.platform.LocalWindowInfo.current
                    val narrowWindow = remember(actualWindow, density.density) {
                        object : androidx.compose.ui.platform.WindowInfo by actualWindow {
                            override val containerSize = androidx.compose.ui.unit.IntSize(
                                (180f * density.density).toInt(), actualWindow.containerSize.height)
                        }
                    }
                    val style = androidx.compose.material3.MaterialTheme.typography.bodyLarge
                    val measured = androidx.compose.ui.text.rememberTextMeasurer().measure(
                        androidx.compose.ui.text.AnnotatedString(longAlt),
                        style = androidx.compose.material3.LocalTextStyle.current.merge(style),
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                        constraints = androidx.compose.ui.unit.Constraints(maxWidth = narrowWindow.containerSize.width,
                            maxHeight = MaxComputedFontPixels.toInt()))
                    SideEffect { expectedLayout.set(measured) }
                    CompositionLocalProvider(LocalInlineImageCache provides cache,
                        androidx.compose.ui.platform.LocalWindowInfo provides narrowWindow) {
                        // The ordinary reader supplies private media/settings/edition locals
                        // and retains its inert 12.dp side gutter for input-mode restoration.
                        EntryView(fallbackEntry, false, {}, settings = fallbackSettings.value)
                    }
                }
            } }
            fun assertFallbackLayout(state: String) {
                compose.waitUntil(15000) {
                    val nodes = compose.onAllNodes(images, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false)
                    nodes.size == 1 && nodes.single().config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.StateDescription) == state
                }
                val expected = checkNotNull(expectedLayout.get())
                assertTrue("The alternative must actually wrap", expected.lineCount > 1)
                val text = compose.onNodeWithText(longAlt, useUnmergedTree = true)
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                text.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val actual = layouts.single()
                assertEquals(expected.size, actual.size)
                assertEquals(expected.size.width, actual.layoutInput.constraints.maxWidth)
                assertEquals(expected.size.height, actual.layoutInput.constraints.maxHeight)
                assertEquals(expected.lineCount, actual.lineCount)
                for (line in 0 until expected.lineCount) {
                    assertEquals(expected.getLineEnd(line), actual.getLineEnd(line))
                    assertEquals(expected.isLineEllipsized(line), actual.isLineEllipsized(line))
                }
                val outer = compose.onAllNodes(images, useUnmergedTree = true)[0].fetchSemanticsNode().boundsInRoot
                val inner = text.fetchSemanticsNode().boundsInRoot
                assertEquals(expected.size.width + 2f * displayDensity, outer.width, 1f)
                assertEquals(displayDensity, inner.left - outer.left, 1f)
                assertEquals(displayDensity, outer.right - inner.right, 1f)
            }
            assertFallbackLayout("Images disabled")
            assertEquals(2, metadataCalls.get()); assertEquals(1, downloads.get())
            compose.runOnIdle { fallbackSettings.value = fallbackSettings.value.copy(allowImages = true) }
            assertFallbackLayout("Image unavailable")
            assertEquals(3, metadataCalls.get()); assertEquals(1, downloads.get())
        } catch (problem: Throwable) {
            primaryFailure = problem
            throw problem
        } finally {
            try {
                val manager = inputModeManager.get()
                val previous = originalInputMode.get()
                if (manager != null && previous != null) {
                    compose.runOnIdle {
                        assertPhysicalActivity(compose.activity)
                        assertTrue(compose.activity.hasWindowFocus() && compose.activity.window.decorView.hasWindowFocus())
                        manager.requestInputMode(previous)
                    }
                    // Touch is a platform state, not a writable Compose setting. If needed,
                    // restore it with a real touchscreen event in the reader's 12.dp side padding.
                    if (previous == androidx.compose.ui.input.InputMode.Touch && manager.inputMode != previous) {
                        val point = java.util.concurrent.atomic.AtomicReference<IntArray>()
                        val downTime = android.os.SystemClock.uptimeMillis()
                        for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
                            compose.runOnIdle {
                                assertPhysicalActivity(compose.activity)
                                val decor = compose.activity.window.decorView
                                assertTrue(compose.activity.hasWindowFocus() && decor.hasWindowFocus())
                                val content = checkNotNull(compose.activity.findViewById<android.view.View>(android.R.id.content))
                                assertTrue(content.isShown && content.width > 2 && content.height > 2)
                                val origin = IntArray(2).also { content.getLocationOnScreen(it) }
                                val visible = android.graphics.Rect().also { decor.getWindowVisibleDisplayFrame(it) }
                                assertTrue(visible.intersect(android.graphics.Rect(origin[0], origin[1], origin[0] + content.width, origin[1] + content.height)))
                                assertTrue(visible.width() > 2 && visible.height() > 2)
                                val current = intArrayOf(visible.left + 1, visible.top + 1)
                                if (point.get() == null) point.set(current) else assertTrue(point.get().contentEquals(current))
                            }
                            val location = checkNotNull(point.get())
                            val event = android.view.MotionEvent.obtain(downTime, android.os.SystemClock.uptimeMillis(), action,
                                location[0].toFloat(), location[1].toFloat(), 0).apply { source = android.view.InputDevice.SOURCE_TOUCHSCREEN }
                            try { InstrumentationRegistry.getInstrumentation().sendPointerSync(event) } finally { event.recycle() }
                        }
                    }
                    compose.waitUntil(10000) { manager.inputMode == previous }
                    compose.runOnIdle { assertEquals("Restore the owned view's original input mode", previous, manager.inputMode) }
                }
            } catch (cleanup: Throwable) {
                if (primaryFailure != null) primaryFailure.addSuppressed(cleanup) else throw cleanup
            } finally {
                try { compose.activityRule.scenario.onActivity { it.setContent {} } }
                finally {
                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.IO) { directory.deleteRecursively() }
                }
            }
        }
    }

    @Test fun mediaStopReplayPermissionAndDisposalPreserveCurrentRequestAndOwnedFiles(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            java.io.File(context.cacheDir, "media-lifecycle-" + java.util.UUID.randomUUID()).apply { mkdirs() }
        }
        // Test-owned silence; real MediaPlayer setup, no network or user media.
        val samples = ByteArray(30 * 8000) { 128.toByte() }
        val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .put("RIFF".toByteArray()).putInt(36 + samples.size).put("WAVEfmt ".toByteArray())
            .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(8000).putShort(1).putShort(8)
            .put("data".toByteArray()).putInt(samples.size).array()
        val wav = header + samples
        val metadata = """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/silence"}]}]}}""".toByteArray()
        val cleanupEntered = java.util.concurrent.CountDownLatch(1)
        val releaseCleanup = java.util.concurrent.CountDownLatch(1)
        val secondOpen = java.util.concurrent.CountDownLatch(1)
        val releaseSecond = java.util.concurrent.CountDownLatch(1)
        val opens = java.util.concurrent.atomic.AtomicInteger()
        val deletes = java.util.Collections.synchronizedList(mutableListOf<java.io.File>())
        val cache = MediaCache(context, metadata = { metadata }, directory = directory,
            openMedia = {
                if (opens.incrementAndGet() == 2) {
                    secondOpen.countDown()
                    check(releaseSecond.await(15, java.util.concurrent.TimeUnit.SECONDS))
                }
                java.io.ByteArrayInputStream(wav)
            }, deleteTemporary = { file ->
                assertNotSame(android.os.Looper.getMainLooper().thread, Thread.currentThread())
                deletes += file
                if (cleanupEntered.count > 0) {
                    cleanupEntered.countDown()
                    check(releaseCleanup.await(15, java.util.concurrent.TimeUnit.SECONDS))
                }
                file.delete()
            })
        val media = Media("Lifecycle.wav", "audio", "Synthetic pronunciation")
        val settings = androidx.compose.runtime.mutableStateOf(AppSettings(allowAudio = true, mediaCacheMb = 0))
        fun show(selected: MediaCache = cache, selectedMedia: Media = media) {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { DictTheme("light") { MediaView(selectedMedia, settings.value, cache = selected) } }
            }
        }
        fun waitPlaying() {
            compose.waitUntil(15000) { compose.onAllNodesWithContentDescription("Stop pronunciation").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
            compose.onNodeWithContentDescription("Stop pronunciation").assertIsDisplayed().assertIsEnabled()
        }
        fun waitEmpty() {
            compose.waitUntil(15000) {
                runBlocking(kotlinx.coroutines.Dispatchers.IO) { directory.listFiles().orEmpty().isEmpty() }
            }
        }
        try {
            show()
            compose.onNodeWithContentDescription("Play pronunciation").performClick()
            waitPlaying()
            compose.onNodeWithContentDescription("Stop pronunciation").performClick()
            assertTrue(cleanupEntered.await(15, java.util.concurrent.TimeUnit.SECONDS))
            compose.onNodeWithContentDescription("Play pronunciation").performClick()
            assertTrue(secondOpen.await(15, java.util.concurrent.TimeUnit.SECONDS))
            compose.onNodeWithContentDescription("Loading pronunciation").assertIsNotEnabled()
            releaseCleanup.countDown()
            compose.waitForIdle()
            // The old finally must not clear the replacement's busy state.
            compose.onNodeWithContentDescription("Loading pronunciation").assertIsNotEnabled()
            compose.runOnIdle { settings.value = settings.value.copy(allowAudio = false) }
            // Observe the cancellation effect before unblocking the pending download.
            compose.waitForIdle()
            compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
            releaseSecond.countDown()
            waitEmpty()
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            // Cancellation before loading hands back must not start later.
            compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
            compose.runOnIdle { settings.value = settings.value.copy(allowAudio = true) }
            compose.onNodeWithContentDescription("Play pronunciation").performClick()
            waitPlaying()
            compose.runOnIdle { settings.value = settings.value.copy(allowAudio = false) }
            waitEmpty()
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            compose.runOnIdle { settings.value = settings.value.copy(allowAudio = true) }
            compose.onNodeWithContentDescription("Play pronunciation").performClick()
            waitPlaying()
            compose.activityRule.scenario.onActivity { it.setContent {} }
            waitEmpty()
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            assertEquals(4, opens.get())
            assertEquals(3, deletes.distinct().size)

            val broken = MediaCache(context, metadata = { metadata }, directory = directory,
                openMedia = { java.io.ByteArrayInputStream(byteArrayOf(1)) })
            show(broken)
            compose.onNodeWithContentDescription("Play pronunciation").performClick()
            compose.waitUntil(15000) {
                compose.onAllNodesWithText("Pronunciation could not be played.").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            waitEmpty()
            compose.onNodeWithContentDescription("Play pronunciation").assertIsEnabled()
            compose.runOnIdle { assertNull(MediaPlayback.playing) }

            // Skia may return a partial bitmap for truncated PNG data. Use an
            // unrecognized image format to exercise the visible failure and retry contract.
            val unsupported = "Synthetic non-image media fixture".toByteArray(Charsets.US_ASCII)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeByteArray(unsupported, 0, unsupported.size, bounds)
                assertTrue("Fixture must have no decodable image dimensions", bounds.outWidth <= 0 && bounds.outHeight <= 0)
                val decoded = android.graphics.BitmapFactory.decodeByteArray(unsupported, 0, unsupported.size)
                try { assertNull("Fixture must not decode as an image", decoded) }
                finally { decoded?.recycle() }
            }
            val imageAttempts = java.util.concurrent.atomic.AtomicInteger()
            val imageCache = MediaCache(context, metadata = { metadata }, directory = directory,
                openMedia = { imageAttempts.incrementAndGet(); java.io.ByteArrayInputStream(unsupported) })
            compose.runOnIdle { settings.value = settings.value.copy(allowImages = true) }
            show(imageCache, Media("Unsupported.png", "image", "Synthetic unsupported image"))
            compose.waitUntil(15000) {
                compose.onAllNodesWithText("Unsupported image").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            waitEmpty()
            compose.onNodeWithContentDescription("Retry image").assertIsEnabled().performClick()
            compose.waitUntil(15000) {
                imageAttempts.get() == 2 && compose.onAllNodesWithText("Unsupported image").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            waitEmpty()
            compose.onNodeWithContentDescription("Retry image").assertIsEnabled()
        } finally {
            releaseCleanup.countDown(); releaseSecond.countDown()
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.runOnIdle { MediaPlayback.stop() }
            waitEmpty()
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.IO) { directory.deleteRecursively() }
        }
    }


    @get:Rule val compose = createPhysicalComposeRule()
    private val library get() = LibraryStore.get(InstrumentationRegistry.getInstrumentation().targetContext)
    @Test fun compiledColorSampleRendersExactColorReadableLabelAndTableFallback() {
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(Span("link", "Fallback target", target = "B")), false, 1, 1))))
        val feature = mutableStateOf<Feature?>(Feature("color_swatch", "", "#ffff00", "none", ""))
        var followed: String? = null
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { androidx.compose.material3.MaterialTheme {
                    CompiledTableView(table, feature.value) { followed = it.target }
                } }
            }
            compose.onNodeWithText("Color sample #ffff00").assertIsDisplayed().assertHasNoClickAction()
            compose.onNodeWithText("Fallback target").assertDoesNotExist()
            val bitmap = compose.onNodeWithTag("compiled-color-swatch", useUnmergedTree = true).captureToImage().asAndroidBitmap()
            try { assertEquals(android.graphics.Color.YELLOW, bitmap.getPixel(bitmap.width / 2, bitmap.height / 2)) }
            finally { bitmap.recycle() }
            compose.runOnIdle { feature.value = Feature("color_swatch", "", "#FFFF00", "none", "") }
            compose.onNodeWithText("Color sample #ffff00").assertDoesNotExist()
            compose.onNodeWithText("Fallback target").assertIsDisplayed().performClick()
            compose.runOnIdle { assertEquals("B", followed); feature.value = Feature("future_feature", "", "#ffff00", "none", "") }
            compose.onNodeWithText("Fallback target").assertIsDisplayed()
            compose.runOnIdle { feature.value = Feature("color_swatch", "af", "#ffff00", "none", "") }
            compose.onNodeWithText("Fallback target").assertIsDisplayed()
            compose.onNodeWithTag("compiled-color-swatch", useUnmergedTree = true).assertDoesNotExist()
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun authoredCellBackgroundFillsRowspansInBothDirectionsAndKeepsLinks() {
        val table = Table(emptyList(), listOf(
            listOf(Cell(listOf(Span("text", "Cell")), false, 1, 2, "#ff0000"),
                Cell(listOf(Span("text", "Header", foreground = "#000080")), true, 1, 1, "#00ff00")),
            listOf(Cell(listOf(Span("link", "Follow", target = "B", background = "#ffffe0"),
                Span("link", " Base", target = "C")), false, 1, 1, "#0000ff"))))
        val phaseCalls = LongArray(TablePhase.entries.size)
        val phaseNanos = LongArray(TablePhase.entries.size)
        val phaseItems = LongArray(TablePhase.entries.size)
        var abortedPhases = 0
        val phaseObserver = TablePhaseObserver { phase, nanos, items, completed ->
            check(nanos >= 0 && items >= 0)
            phaseCalls[phase.ordinal]++
            phaseNanos[phase.ordinal] += nanos
            phaseItems[phase.ordinal] += items
            if (!completed) abortedPhases++
        }
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        val mode = mutableStateOf("light")
        var followed: String? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides direction.value, LocalTablePhaseObserver provides phaseObserver) {
                    DictTheme(mode.value) { androidx.compose.material3.Surface {
                        CompiledTableView(table, null) { followed = it.target }
                    } }
                }
            } }
            for (theme in listOf("light", "dark")) for (value in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                compose.runOnIdle { mode.value = theme; direction.value = value; followed = null }
                compose.waitForIdle()
                val image = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true).captureToImage().asAndroidBitmap()
                try {
                    val redX = if (value == androidx.compose.ui.unit.LayoutDirection.Ltr) image.width / 4 else image.width * 3 / 4
                    val otherX = image.width - redX - 1
                    assertEquals(android.graphics.Color.RED, image.getPixel(redX, image.height / 4))
                    assertEquals(android.graphics.Color.RED, image.getPixel(redX, image.height * 3 / 4))
                    assertEquals(android.graphics.Color.GREEN, image.getPixel(otherX, 2))
                    assertEquals(android.graphics.Color.BLUE, image.getPixel(otherX, image.height - 3))
                    assertTrue((0 until image.height).any { y ->
                        (0 until image.width).any { x -> image.getPixel(x, y) == 0xffffffe0.toInt() }
                    })
                } finally { image.recycle() }
                for ((label, expected) in listOf("Cell" to 0xff000000L, "Header" to 0xff000080L)) {
                    val text = compose.onNodeWithText(label, useUnmergedTree = true).fetchSemanticsNode()
                        .config[androidx.compose.ui.semantics.SemanticsProperties.Text].single()
                    assertTrue(text.spanStyles.any { it.start == 0 && it.end == label.length && it.item.color == androidx.compose.ui.graphics.Color(expected) })
                }
                val actions = compose.onNodeWithText("Follow Base", useUnmergedTree = true).assertIsDisplayed()
                val text = actions.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.Text].single()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                actions.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                for ((target, expected) in listOf("B" to 0xff000000L, "C" to 0xffffffffL)) {
                    val range = text.getLinkAnnotations(0, text.length).single {
                        (it.item as? androidx.compose.ui.text.LinkAnnotation.Clickable)?.tag == target
                    }
                    assertTrue(text.spanStyles.any { it.start == range.start && it.end == range.end && it.item.color == androidx.compose.ui.graphics.Color(expected) })
                    val link = range.item as androidx.compose.ui.text.LinkAnnotation.Clickable
                    assertEquals(androidx.compose.ui.text.style.TextDecoration.Underline, link.styles?.style?.textDecoration)
                    actions.performTouchInput { click(layouts.single().getBoundingBox(range.start + if (target == "C") 1 else 0).center) }
                    compose.runOnIdle { assertEquals(target, followed) }
                }
                compose.onNodeWithText("Color sample #ff0000").assertDoesNotExist()
            }
            compose.runOnIdle {
                assertEquals(0, abortedPhases)
                assertTrue(phaseCalls.all { it > 0L })
                assertTrue(phaseItems[TablePhase.Measurement.ordinal] >= 3L)
                assertTrue(phaseItems[TablePhase.Composition.ordinal] >= 3L)
                val report = TablePhase.entries.joinToString(";") { phase ->
                    "${phase.name}:${phaseCalls[phase.ordinal]}:${phaseNanos[phase.ordinal]}:${phaseItems[phase.ordinal]}"
                }
                check(report.length <= 1024)
                InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
                    putString("table_phase_totals", report)
                })
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun authoredForegroundSurvivesLinksAndNativeEgyptianPaintInBothDirections() {
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        val mode = mutableStateOf("light")
        val signs = "\uD80C\uDC00"
        val spans = listOf(
            Span("link", "Green", target = "green-target", trail = "s", foreground = "#008000", background = "#ffffe0"),
            Span("text", " / "), Span("text", "Blue", foreground = "#0000ff", background = "#ffd0e0"), Span("text", " / "),
            Span("link", signs, target = "sign-target", classes = "Egyp", direction = "ltr", foreground = "#40e0d0", background = "#ff8000"),
            Span("text", " / "), Span("text", "Dark", background = "#000000"), Span("text", " / "),
            Span("link", "Light", target = "fallback-target", trail = "s", background = "#ffffe0"), Span("text", " / "),
            Span("link", signs, target = "native-fallback-target", classes = "Egyp", direction = "ltr", background = "#000000"))
        val expectedText = "Greens / Blue / \u2066" + signs + "\u2069 / Dark / Lights / \u2066" + signs + "\u2069"
        val clicked = java.util.concurrent.CopyOnWriteArrayList<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides direction.value) {
                    DictTheme(mode.value) { androidx.compose.material3.Surface {
                        StyledText(spans, Modifier.width(300.dp).testTag("authored-foreground"), onLink = { clicked.add(it.target) })
                    } }
                }
            } }
            for (theme in listOf("light", "dark")) for (value in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                compose.runOnIdle { mode.value = theme; direction.value = value; clicked.clear() }
                compose.waitUntil(10000) {
                    compose.onAllNodes(SemanticsMatcher.expectValue(EgyptianShapedRunCount, 2), useUnmergedTree = true)
                        .fetchSemanticsNodes().isNotEmpty()
                }
                compose.waitForIdle()
                val node = compose.onNodeWithText(expectedText, useUnmergedTree = true)
                val image = compose.onNodeWithTag("authored-foreground", useUnmergedTree = true).captureToImage().asAndroidBitmap()
                try {
                    val expected = setOf(0xff008000.toInt(), 0xff0000ff.toInt(), 0xff40e0d0.toInt(),
                        0xffffffe0.toInt(), 0xffffd0e0.toInt(), 0xffff8000.toInt(), 0xff000000.toInt(), 0xffffffff.toInt())
                    val found = mutableSetOf<Int>()
                    for (y in 0 until image.height) for (x in 0 until image.width) {
                        val pixel = image.getPixel(x, y)
                        if (pixel in expected) found.add(pixel)
                    }
                    assertEquals(expected, found)
                } finally { image.recycle() }
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                val annotated = layout.layoutInput.text
                assertEquals(expectedText, annotated.text)
                val greenPaint = annotated.spanStyles.single { it.start == 0 && it.item.background == androidx.compose.ui.graphics.Color(0xffffffe0.toInt()) }
                assertEquals(0, greenPaint.start)
                assertEquals(6, greenPaint.end)
                assertFalse(annotated.spanStyles.any { it.item.background != androidx.compose.ui.graphics.Color.Unspecified && it.start <= 6 && it.end > 6 })
                val darkStart = annotated.text.indexOf("Dark")
                assertTrue(annotated.spanStyles.any { it.start == darkStart && it.end == darkStart + 4 && it.item.color == androidx.compose.ui.graphics.Color.White })
                val targets = listOf("green-target", "sign-target", "fallback-target", "native-fallback-target")
                for (target in targets) {
                    val range = annotated.getLinkAnnotations(0, annotated.length).single {
                        (it.item as? androidx.compose.ui.text.LinkAnnotation.Clickable)?.tag == target
                    }
                    val link = range.item as androidx.compose.ui.text.LinkAnnotation.Clickable
                    val expected = when (target) {
                        "green-target" -> 0xff008000L
                        "sign-target" -> 0xff40e0d0L
                        "fallback-target" -> 0xff000000L
                        else -> 0xffffffffL
                    }
                    assertTrue(annotated.spanStyles.any { it.start == range.start && it.end == range.end && it.item.color == androidx.compose.ui.graphics.Color(expected) })
                    if (target.endsWith("fallback-target"))
                        assertEquals(androidx.compose.ui.text.style.TextDecoration.Underline, link.styles?.style?.textDecoration)
                    val offset = range.start + if (target == "sign-target" || target == "native-fallback-target") 1 else 0
                    val bounds = layout.getBoundingBox(offset)
                    node.performTouchInput { click(bounds.center) }
                }
                compose.runOnIdle { assertEquals(targets, clicked.toList()) }
                node.assertTextEquals(expectedText)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Before fun installRealBinaryDictionary() {
        runBlocking {
            library.refreshCatalogs().join()
            assertNull(library.error)
            library.download(library.catalog.first()).join()
            assertNull(library.error)
        }
        compose.waitUntil(15000) { compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
    }
    @Test fun selectedDictionaryExportsStandardSearchClickAndRetainsOtherTabs() {
        compose.onNodeWithTag("entry-scroll").assertExists()
        // Query our admitted Activity's provider, not a global accessibility service.
        lateinit var provider: android.view.accessibility.AccessibilityNodeProvider
        compose.runOnIdle {
            fun owner(view: android.view.View): android.view.View? {
                if (view.javaClass.name == "androidx.compose.ui.platform.AndroidComposeView") return view
                if (view is android.view.ViewGroup) {
                    for (index in 0 until view.childCount) owner(view.getChildAt(index))?.let { return it }
                }
                return null
            }
            provider = checkNotNull(checkNotNull(owner(compose.activity.window.decorView)).accessibilityNodeProvider)
        }
        fun exported(label: String): Pair<Int, android.view.accessibility.AccessibilityNodeInfo> {
            // Compose 1.11.2 uses the semantics id for every non-root virtual node.
            val id = compose.onNodeWithContentDescription(label).fetchSemanticsNode().id
            lateinit var info: android.view.accessibility.AccessibilityNodeInfo
            compose.runOnIdle { info = checkNotNull(provider.createAccessibilityNodeInfo(id)) }
            return id to info
        }
        fun activate(id: Int) {
            compose.runOnIdle {
                assertTrue(provider.performAction(id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
            }
            compose.waitForIdle()
        }
        val (searchId, search) = exported("Dictionary")
        try {
            assertEquals("android.widget.Button", search.className.toString())
            assertTrue(search.isEnabled)
            assertTrue(search.isFocusable)
            assertTrue("The selected reader must advertise its search click", search.isClickable)
            assertFalse("Search is an action, not a checked tab or toggle", search.isCheckable)
            assertFalse(search.isSelected)
            val click = search.actionList.single { it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK }
            assertEquals("Search", click.label.toString())
        } finally { search.recycle() }
        for (label in listOf("Saved", "History", "Learn", "Settings")) {
            assertEquals(androidx.compose.ui.semantics.Role.Tab,
                compose.onNodeWithContentDescription(label).fetchSemanticsNode().config.getOrNull(
                    androidx.compose.ui.semantics.SemanticsProperties.Role))
            val (_, tab) = exported(label)
            try {
                assertTrue(tab.isClickable)
                assertFalse(tab.isSelected)
                assertTrue(tab.actionList.any { it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK })
            } finally { tab.recycle() }
        }
        // hasClickAction/performClick alone would pass the old selected Tab;
        // activation follows only after checking the platform-advertised action above.
        activate(searchId)
        compose.onNode(hasSetTextAction()).assertIsFocused().performTextInput("cat")
        compose.onNode(hasSetTextAction()).assertTextEquals("cat")
        compose.waitUntil(10000) {
            compose.onAllNodes(hasText("cat") and !hasSetTextAction()).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.onNodeWithTag("entry-scroll").assertExists()
        compose.onNodeWithContentDescription("Settings").performClick()
        val (dictionaryId, dictionary) = exported("Dictionary")
        try {
            assertEquals(androidx.compose.ui.semantics.Role.Tab,
                compose.onNodeWithContentDescription("Dictionary").fetchSemanticsNode().config.getOrNull(
                    androidx.compose.ui.semantics.SemanticsProperties.Role))
            assertFalse(dictionary.isSelected)
            assertTrue(dictionary.isClickable)
            assertTrue(dictionary.actionList.any { it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK })
        } finally { dictionary.recycle() }
        activate(dictionaryId)
        compose.onNode(hasSetTextAction()).assertIsFocused()
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.onNodeWithTag("entry-scroll").assertExists()
    }

    @Test fun realSystemClipboardCopiesReaderTextAndPastesIntoSearchWithoutClobberingNewerClip() {
        // No LocalClipboard override: both toolbar actions use Android's actual clipboard.
        search("cat")
        val entry = runBlocking { library.read(checkNotNull(library.exact("cat"))) }
        val expected = entry.readingRows.mapNotNull { it.block }.filter { it.kind == "definition" }
            .map { compactSpans(it.spans) }.first { spans ->
                spans.isNotEmpty() && spans.all { it.kind in setOf("text", "link", "external_link") &&
                    it.direction.isEmpty() && !it.hasClassToken("wikidict-media") } &&
                    spans.sumOf { it.text.length + it.trail.length } in 8..240
            }.joinToString("") { it.text + it.trail }
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(expected))
        val paragraph = compose.onNodeWithText(expected, useUnmergedTree = true).assertIsDisplayed()
        val manager = compose.activity.getSystemService(android.content.ClipboardManager::class.java)
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val originalFlags = automation.serviceInfo.flags
        // Local construction checks never publish or read clipboard contents.
        val plain = android.content.ClipData.newPlainText("test", "public fixture")
        check(restorablePlainClipboard(plain))
        check(!restorablePlainClipboard(android.content.ClipData.newHtmlText("test", "public fixture", "<b>public fixture</b>")))
        check(!restorablePlainClipboard(android.content.ClipData.newIntent("test", android.content.Intent("test.only"))))
        check(!restorablePlainClipboard(android.content.ClipData.newRawUri("test", android.net.Uri.parse("content://test.only/item"))))
        val multi = android.content.ClipData(plain).apply { addItem(android.content.ClipData.Item("second")) }
        check(!restorablePlainClipboard(multi))
        val styled = android.content.ClipData.newPlainText("test", android.text.SpannableString("public fixture"))
        check(!restorablePlainClipboard(styled))
        val extra = android.content.ClipData.newPlainText("test", "public fixture").apply {
            description.extras = android.os.PersistableBundle().apply { putBoolean("test.only", true) }
        }
        check(!restorablePlainClipboard(extra))
        check(!sameClipboardMutation(plain, android.content.ClipData.newPlainText("test", "different fixture")))
        val token = compose.activity.window.decorView.windowToken
        fun focusedOwner(): Boolean = compose.activity.window.decorView.let {
            !compose.activity.isFinishing && !compose.activity.isDestroyed &&
                it.display?.displayId == android.view.Display.DEFAULT_DISPLAY &&
                it.windowToken == token && it.hasWindowFocus()
        }
        var generation = 0L
        var originalGeneration = 0L
        var ownedGeneration = -1L
        var original: android.content.ClipData? = null
        var owned: android.content.ClipData? = null
        val listener = android.content.ClipboardManager.OnPrimaryClipChangedListener { generation++ }
        var listening = false
        try {
            // Capture only while our admitted physical Activity is foreground. Keep the
            // original in process memory; never log, hash, parcel, or persist its contents.
            compose.runOnIdle {
                check(focusedOwner()) { "Clipboard preflight requires the owned focused physical Activity" }
                manager.addPrimaryClipChangedListener(listener); listening = true
                val present = manager.hasPrimaryClip()
                val current = manager.primaryClip
                check(present == (current != null)) {
                    "Clipboard availability is unknown; no copy attempted; " +
                        "present=$present,currentPresent=${current != null}"
                }
                // Fixed eligibility booleans only; no clipboard payload or metadata values.
                val originalDescription = current?.description
                val originalItem = current?.takeIf { it.itemCount == 1 }?.getItemAt(0)
                val originalPreflightChecks = linkedMapOf(
                    "currentPresent" to (current != null),
                    "singleItem" to (current?.itemCount == 1),
                    "singleMime" to (originalDescription?.mimeTypeCount == 1),
                    "plainMime" to (originalDescription != null && originalDescription.mimeTypeCount > 0 && originalDescription.getMimeType(0) == "text/plain"),
                    "noExtras" to (originalDescription != null && originalDescription.extras == null),
                    "plainLabel" to (originalDescription != null && (originalDescription.label == null || originalDescription.label is String)),
                    "noUri" to (originalItem != null && originalItem.uri == null),
                    "noIntent" to (originalItem != null && originalItem.intent == null),
                    "noHtml" to (originalItem != null && originalItem.htmlText == null),
                    "textPresent" to (originalItem?.text != null),
                    "immutableStringText" to (originalItem?.text is String),
                )
                check(current == null || restorablePlainClipboard(current)) {
                    "Original clipboard cannot be safely restored; no copy attempted; " +
                        "preflight predicate booleans: $originalPreflightChecks"
                }
                original = current?.let { android.content.ClipData(it) }
                originalGeneration = generation
            }
            automation.serviceInfo = automation.serviceInfo.apply {
                flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
            val copyLayouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            paragraph.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(copyLayouts) }
            val copyLayout = copyLayouts.single()
            val copyAnchorIndex = copyLayout.layoutInput.text.text.indexOfFirst { !it.isWhitespace() }
            check(copyAnchorIndex >= 0) { "Owned copy paragraph has no glyph anchor" }
            val copyAnchor = copyLayout.getBoundingBox(copyAnchorIndex).center
            paragraph.performTouchInput { longClick(copyAnchor) }
            clickRealClipboardToolbar(android.R.string.selectAll)
            compose.runOnIdle {
                check(focusedOwner() && generation == originalGeneration && sameClipboardMutation(manager.primaryClip, original)) {
                    "Clipboard changed before Copy; original preserved"
                }
            }
            clickRealClipboardToolbar(android.R.string.copy)
            var postCopyChecks: Map<String, Boolean> = emptyMap()
            try {
                compose.waitUntil(10000) {
                    var ready = false
                    compose.runOnIdle {
                        check(focusedOwner()) { "Owned Activity lost focus after Copy" }
                        val current = manager.primaryClip
                        val description = current?.description
                        val item = current?.takeIf { it.itemCount == 1 }?.getItemAt(0)
                        postCopyChecks = linkedMapOf(
                            "ownedWindowFocused" to true, // The unchanged check immediately above passed.
                            "generationUnchanged" to (generation == originalGeneration),
                            "generationExactlyOne" to (generation == originalGeneration + 1),
                            "generationMoreThanOne" to (generation > originalGeneration + 1),
                            "currentPresent" to (current != null),
                            "plainShape" to (current != null && plainClipboardShape(current, allowStyledText = true)),
                            "singleItem" to (current?.itemCount == 1),
                            "singleMime" to (description?.mimeTypeCount == 1),
                            "plainMime" to (description != null && description.mimeTypeCount > 0 && description.getMimeType(0) == "text/plain"),
                            "noExtras" to (description != null && description.extras == null),
                            "plainLabel" to (description != null && (description.label == null || description.label is String)),
                            "noUri" to (item != null && item.uri == null),
                            "noIntent" to (item != null && item.intent == null),
                            "noHtml" to (item != null && item.htmlText == null),
                            "textPresent" to (item?.text != null),
                            "expectedText" to (item?.text?.toString() == expected),
                            "timestampPositive" to (description != null && description.timestamp > 0),
                            "timestampChanged" to (description != null && (original == null || description.timestamp != original!!.description.timestamp)),
                        )
                        ready = generation == originalGeneration + 1 && current != null &&
                            plainClipboardShape(current, allowStyledText = true) &&
                            current.getItemAt(0).text.toString() == expected &&
                            current.description.timestamp > 0 &&
                            (original == null || current.description.timestamp != original!!.description.timestamp)
                        if (ready) { owned = android.content.ClipData(current!!); ownedGeneration = generation }
                    }
                    ready
                }
            } catch (timeout: androidx.compose.ui.test.ComposeTimeoutException) {
                // Fixed booleans only: never payload, labels, MIME strings, extras,
                // URI/Intent values, timestamps, original contents, or a view capture.
                throw AssertionError("Post-Copy predicate booleans: $postCopyChecks", timeout)
            }
            compose.onNodeWithContentDescription("Dictionary").performClick()
            val field = compose.onNode(hasSetTextAction()).assertIsFocused().assertTextEquals("")
            compose.runOnIdle {
                check(focusedOwner() && generation == ownedGeneration && sameClipboardMutation(manager.primaryClip, owned)) {
                    "Clipboard changed before Paste; no paste attempted"
                }
            }
            field.performTouchInput { longClick() }
            // A visible contextual Paste action, not test text injection or a hidden key.
            clickRealClipboardToolbar(android.R.string.paste)
            // Do not let assertion diagnostics dump a possibly newer external clip
            // pasted during the unavoidable clipboard check-to-menu IPC interval.
            val pastedExpected = try {
                field.fetchSemanticsNode().config.getOrNull(
                    androidx.compose.ui.semantics.SemanticsProperties.EditableText)?.text == expected
            } catch (_: AssertionError) { false }
            assertTrue("Visible Paste did not return the owned test payload", pastedExpected)
            captureOwnedMaintenance("real-system-paste.png")
        } finally {
            try {
                compose.runOnIdle {
                    if (owned != null && focusedOwner() && generation == ownedGeneration &&
                        sameClipboardMutation(manager.primaryClip, owned)) {
                        // ClipboardManager exposes no atomic compare-and-set. This is a
                        // final foreground/mutation check immediately before normal IPC;
                        // a newer observed write is always preserved, never overwritten.
                        if (original == null) manager.clearPrimaryClip() else manager.setPrimaryClip(original!!)
                        android.util.Log.i("RealClipboardEvidence", "owned-test-clip restoration submitted")
                    } else if (owned != null) {
                        android.util.Log.i("RealClipboardEvidence", "restoration skipped: focus or mutation changed")
                    }
                }
            } finally {
                if (listening) manager.removePrimaryClipChangedListener(listener)
                automation.serviceInfo = automation.serviceInfo.apply { flags = originalFlags }
                original = null; owned = null
            }
        }
    }

    private fun plainClipboardShape(clip: android.content.ClipData, allowStyledText: Boolean): Boolean {
        val description = clip.description
        if (clip.itemCount != 1 || description.mimeTypeCount != 1 ||
            description.getMimeType(0) != "text/plain" || description.extras != null ||
            (description.label != null && description.label !is String)) return false
        val item = clip.getItemAt(0)
        return item.uri == null && item.intent == null && item.htmlText == null &&
            item.text != null && (allowStyledText || item.text is String)
    }

    private fun restorablePlainClipboard(clip: android.content.ClipData): Boolean =
        plainClipboardShape(clip, allowStyledText = false)

    private fun sameClipboardMutation(a: android.content.ClipData?, b: android.content.ClipData?): Boolean {
        if (a == null || b == null) return a == null && b == null
        return plainClipboardShape(a, allowStyledText = true) && plainClipboardShape(b, allowStyledText = true) &&
            a.description.timestamp == b.description.timestamp && a.description.label == b.description.label &&
            a.getItemAt(0).text.toString() == b.getItemAt(0).text.toString()
    }

    private fun clickRealClipboardToolbar(labelResource: Int) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val label = compose.activity.getString(labelResource)
        fun roots() = automation.windowsOnAllDisplays.get(android.view.Display.DEFAULT_DISPLAY).orEmpty()
            .filter { it.displayId == android.view.Display.DEFAULT_DISPLAY &&
                it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_APPLICATION }
            .mapNotNull { it.root }.filter { it.packageName?.toString() == compose.activity.packageName }
            .distinctBy { it.windowId }
        var ready: android.view.accessibility.AccessibilityNodeInfo? = null
        compose.waitUntil(10000) {
            val matches = roots().flatMap { root -> root.findAccessibilityNodeInfosByText(label).filter {
                it.isVisibleToUser && it.text?.toString() == label && it.windowId == root.windowId
            } }
            if (matches.size != 1) return@waitUntil false
            var node: android.view.accessibility.AccessibilityNodeInfo? = matches.single()
            repeat(4) {
                val candidate = node ?: return@repeat
                if (candidate.isClickable && candidate.isEnabled) { ready = candidate; return@waitUntil true }
                node = candidate.parent?.takeIf { it.windowId == candidate.windowId }
            }
            false
        }
        val target = checkNotNull(ready)
        check(roots().count { it.windowId == target.windowId } == 1) { "Owned toolbar window changed" }
        check(target.refresh() && target.isVisibleToUser && target.isEnabled && target.isClickable) {
            "Owned toolbar action is no longer ready"
        }
        check(compose.activity.window.decorView.let {
            it.display?.displayId == android.view.Display.DEFAULT_DISPLAY && it.hasWindowFocus()
        }) { "Owned physical Activity lost focus before toolbar activation" }
        check(target.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK)) {
            "Owned toolbar action did not acknowledge its single click"
        }
        compose.waitForIdle()
    }

    @Test fun ordinaryAndCompanionHeadingsKeepRolesLinksAndLogicalDepthInBothDirections() {
        val spans = listOf(Span("text", "Se beiga ", italic = true),
            Span("link", "la conchugazión benasquesa", target = "templlar/conj.BEN", bold = true, italic = true),
            Span("text", " d'este berbo.", italic = true))
        val label = spans.joinToString("") { it.text }
        for (direction in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
            for (mode in listOf("ordinary", "rich-companion", "plain-companion", "styled-companion")) {
                val companion = mode != "ordinary"
                val plain = mode == "plain-companion"
                val styled = mode == "styled-companion"
                val initialDepth = if (plain) 1 else 0
                val depth = mutableStateOf(initialDepth)
                var followed: String? = null
                var density = 0f
                var expectedWeight: androidx.compose.ui.text.font.FontWeight? = null
                fun value(): Entry {
                    val heading = Block("heading", depth.value,
                        if (plain || styled) listOf(Span("text", label, italic = styled, background = if (styled) "#ffffe0" else null)) else spans,
                        listPath = ":".repeat(depth.value), level = 4)
                    return Entry("templlar", emptyList(), "language", "Aragonese", "an",
                        listOf(Section(4, if (companion) label else "Conchugazión", listOf(heading,
                            Block("paragraph", 0, listOf(Span("text", "Following body")))))), emptyList())
                }
                val caseId = "heading-${direction.toString().lowercase()}-$mode"
                var initialEvidence = "Initial owned fixture evidence not yet available"
                var stage = "install-fixture"
                var primaryFailure: Throwable? = null
                val lifecycleTrace = mutableListOf<String>()
                fun observeOwnedFixture(at: String) {
                    stage = at
                    val roots = runCatching {
                        compose.onAllNodesWithTag("heading-fixture", useUnmergedTree = true)
                            .fetchSemanticsNodes(atLeastOneRootRequired = false).size.toString()
                    }.getOrElse { "unavailable:${it.javaClass.simpleName}" }
                    val activity = runCatching {
                        var state = "scenario=${compose.activityRule.scenario.state}"
                        compose.activityRule.scenario.onActivity { owned ->
                            val view = owned.window.decorView
                            state += "; lifecycle=${owned.lifecycle.currentState}; finishing=${owned.isFinishing}; destroyed=${owned.isDestroyed}; attached=${view.isAttachedToWindow}; " + ownedLayoutState(view)
                        }
                        state
                    }.getOrElse { "activity-unavailable:${it.javaClass.simpleName}:${it.message}" }
                    lifecycleTrace += "timeMs=${System.currentTimeMillis()}; case=$caseId; stage=$at; roots=$roots; $activity".take(1600)
                }
                println("HEADING_FIXTURE_BEGIN $caseId initialDepth=$initialDepth")
                try {
                    compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                        CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides direction) {
                            DictTheme("system") {
                                density = LocalDensity.current.density
                                expectedWeight = androidx.compose.material3.MaterialTheme.typography.titleMedium.fontWeight
                                androidx.compose.material3.Surface(Modifier.fillMaxSize().testTag("heading-fixture")) {
                                    EntryView(value(), false, {}, onLink = { followed = it.target }, settings = AppSettings(collapseDetails = false, collapseOtherSections = false))
                                }
                            }
                        }
                    } }
                    val node = compose.onNodeWithText(label, useUnmergedTree = true)
                    // Capture only this synthetic fixture before the first display assertion.
                    // Diagnostics cannot turn an assertion failure into a pass.
                    initialEvidence = runCatching {
                        val viewport = compose.onNodeWithTag("heading-fixture", useUnmergedTree = true)
                        val semantic = runCatching { node.fetchSemanticsNode() }.getOrNull()
                        val initialLayouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                        runCatching { node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(initialLayouts) } }
                        val tree = runCatching { viewport.printToString(maxDepth = 8).take(12000) }
                            .getOrElse { "OWNED_TREE_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
                        renderedLayoutFailureEvidence(caseId, initialLayouts.singleOrNull(), semantic,
                            viewport, "$caseId.png") + "\nOWNED_FIXTURE_TREE\n" + tree
                    }.getOrElse { "OWNED_FIXTURE_EVIDENCE_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
                    observeOwnedFixture("initial-display")
                    node.assertIsDisplayed()
                    compose.onAllNodesWithText(label, useUnmergedTree = true).assertCountEquals(1)
                    // StyledText puts the heading modifier on its SelectionContainer;
                    // the unmerged Text descendant still supplies link/layout evidence.
                    assertTrue(generateSequence(node.fetchSemanticsNode()) { it.parent }.any {
                        it.config.contains(androidx.compose.ui.semantics.SemanticsProperties.Heading)
                    })
                    val before = node.fetchSemanticsNode().boundsInRoot
                    val bodyBefore = compose.onNodeWithText("Following body", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                    compose.runOnIdle { depth.value = initialDepth + 1 }
                    val after = node.fetchSemanticsNode().boundsInRoot
                    val bodyAfter = compose.onNodeWithText("Following body", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                    val logicalShift = if (direction == androidx.compose.ui.unit.LayoutDirection.Ltr) after.left - before.left else before.right - after.right
                    assertEquals(7f * density, logicalShift, 1.1f)
                    assertEquals(bodyBefore.left, bodyAfter.left, 1.1f)
                    assertEquals(bodyBefore.right, bodyAfter.right, 1.1f)
                    val text = node.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.Text].single()
                    val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                    node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                    assertEquals(expectedWeight, layouts.single().layoutInput.style.fontWeight)
                    if (plain || styled) {
                        assertTrue(text.getLinkAnnotations(0, text.length).isEmpty())
                        if (styled) {
                            assertTrue(text.spanStyles.any { it.start == 0 && it.end == text.length && it.item.fontStyle == androidx.compose.ui.text.font.FontStyle.Italic })
                            assertTrue(text.spanStyles.any { it.start == 0 && it.end == text.length && it.item.background == androidx.compose.ui.graphics.Color(0xffffffe0.toInt()) })
                            node.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                            compose.runOnIdle { assertEquals(null, followed) }
                        }
                    } else {
                    val link = text.getLinkAnnotations(0, text.length).single()
                    assertEquals("templlar/conj.BEN", (link.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
                    assertTrue(text.spanStyles.any { it.start == 0 && it.item.fontStyle == androidx.compose.ui.text.font.FontStyle.Italic })
                    assertTrue(text.spanStyles.any { it.start == link.start && it.end == link.end && it.item.fontWeight == androidx.compose.ui.text.font.FontWeight.Bold })
                    node.performTouchInput { click(layouts.single().getBoundingBox(link.start).center) }
                    compose.runOnIdle { assertEquals("templlar/conj.BEN", followed) }
                    }
                    if (companion) {
                        observeOwnedFixture("before-collapse")
                        compose.onNodeWithContentDescription("Collapse $label").performClick()
                        observeOwnedFixture("after-collapse")
                        compose.onNodeWithText("Following body", useUnmergedTree = true).assertDoesNotExist()
                        observeOwnedFixture("before-expand")
                        compose.onNodeWithContentDescription("Expand $label").performClick()
                        observeOwnedFixture("after-expand")
                        compose.onNodeWithText("Following body", useUnmergedTree = true).assertIsDisplayed()
                    }
                    // addResults is emitted in the final raw instrumentation result bundle.
                    // Eight bounded values stay below the Binder transaction budget; never
                    // truncate a PNG payload into something that looks decodable.
                    val successEvidence = if (initialEvidence.length <= 56 * 1024) initialEvidence else
                        initialEvidence.substringBefore("\nOWNED_PNG_BEGIN").take(14000) +
                            "\nOWNED_PNG_UNAVAILABLE $caseId success result exceeds 57344 characters" +
                            "\nOWNED_FIXTURE_TREE\n" + initialEvidence.substringAfter("\nOWNED_FIXTURE_TREE\n", "").take(12000)
                    InstrumentationRegistry.getInstrumentation().addResults(android.os.Bundle().apply {
                        putString("heading_fixture_$caseId", successEvidence)
                        putString("heading_lifecycle_$caseId", lifecycleTrace.joinToString("\n").take(10000))
                    })
                    println("HEADING_FIXTURE_PASS $caseId")
                } catch (failure: Throwable) {
                    primaryFailure = failure
                    val failedStage = stage
                    observeOwnedFixture("failure-after-$failedStage")
                    val currentTree = runCatching {
                        compose.onNodeWithTag("heading-fixture", useUnmergedTree = true)
                            .printToString(maxDepth = 8).take(12000)
                    }.getOrElse { "OWNED_TREE_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
                    // Preserve the original exception and assertions; diagnostics cannot
                    // replace it or capture another Activity when this fixture is absent.
                    val diagnostic = ("case=$caseId depth=${depth.value} stage=$failedStage\n" +
                        lifecycleTrace.joinToString("\n") + "\nINITIAL_OWNED_EVIDENCE\n" +
                        initialEvidence.substringBefore("\nOWNED_PNG_BEGIN").take(14000) +
                        "\nCURRENT_OWNED_FIXTURE_TREE\n" + currentTree).take(56000)
                    runCatching {
                        InstrumentationRegistry.getInstrumentation().addResults(android.os.Bundle().apply {
                            putString("heading_failure_$caseId", diagnostic)
                        })
                    }.onFailure { failure.addSuppressed(it) }
                    failure.addSuppressed(AssertionError(diagnostic))
                    throw failure
                } finally {
                    try { compose.activityRule.scenario.onActivity { it.setContent {} } }
                    catch (cleanup: Throwable) {
                        val original = primaryFailure
                        if (original != null) original.addSuppressed(cleanup) else throw cleanup
                    }
                }
            }
        }
    }

    @Test fun ordinaryInlineSpacingRendersCollapsedRangesAndKeepsLiteralControls() {
        val original = listOf(Span("text", "left  ", italic = true, trail = "\t"),
            Span("link", "\t target", target = "B#English", bold = true), Span("text", " \t right"))
        val blocks = listOf(Block("definition", 1, original),
            Block("preformatted", 0, listOf(Span("text", "pre  \t kept"))),
            Block("paragraph", 0, emptyList(), table = Table(emptyList(), listOf(listOf(
                Cell(listOf(Span("text", "cell  \t kept")), false, 1, 1))))),
            Block("paragraph", 0, listOf(Span("text", "poem  \t kept", classes = "wikidict-poem"))),
            Block("paragraph", 0, listOf(Span("text", "code  \t kept", code = true))))
        val entry = Entry("Whitespace fixture", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", blocks)), emptyList())
        var followed: String? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("system") {
                    androidx.compose.material3.Surface(
                        modifier = Modifier.fillMaxSize(),
                        color = androidx.compose.material3.MaterialTheme.colorScheme.background,
                    ) {
                        EntryView(entry, false, {}, onLink = { followed = it.target }, settings = AppSettings(collapseDetails = false))
                    }
                }
            } }
            val node = compose.onNodeWithText("left target right", useUnmergedTree = true).assertIsDisplayed()
            val text = node.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.Text].single()
            val link = text.getLinkAnnotations(0, text.length).single()
            assertEquals("B#English", (link.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
            assertEquals(5, link.start); assertEquals(11, link.end)
            assertTrue(text.spanStyles.any { it.start == 0 && it.end == 5 && it.item.fontStyle == androidx.compose.ui.text.font.FontStyle.Italic })
            assertTrue(text.spanStyles.any { it.start == 5 && it.end == 11 && it.item.fontWeight == androidx.compose.ui.text.font.FontWeight.Bold })
            captureOwnedMaintenance("ordinary-inline-spacing.png")
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
            node.performTouchInput { click(layouts.single().getBoundingBox(link.start).center) }
            compose.runOnIdle { assertEquals("B#English", followed) }
            for (literal in listOf("pre  \t kept", "cell  \t kept", "poem  \t kept", "code  \t kept")) {
                compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(literal))
                compose.onNodeWithText(literal, useUnmergedTree = true).assertIsDisplayed()
            }
            assertEquals("left  ", original[0].text); assertEquals("\t", original[0].trail)
            assertEquals("\t target", original[1].text)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    private fun captureOwnedMaintenance(name: String) {
        require(name in setOf("ordinary-inline-spacing.png", "real-system-paste.png"))
        // Only this owned Compose root and known public fixture text; never the
        // system clipboard overlay or the retained original ClipData.
        try {
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            try {
                val files = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
                val directory = java.io.File(files, "qa-copy-evidence")
                check(directory.mkdirs() || directory.isDirectory)
                check(directory.canonicalFile.parentFile == files.canonicalFile)
                val target = java.io.File(directory, name)
                check(target.canonicalFile.parentFile == directory.canonicalFile && !target.exists())
                target.outputStream().use { check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
            } finally { bitmap.recycle() }
        } catch (failure: AssertionError) {
            android.util.Log.i("OwnedMaintenanceEvidence", "$name unavailable: ${failure.javaClass.simpleName}")
        } catch (failure: Exception) {
            // Evidence availability never replaces functional assertions, and
            // diagnostics do not print a view tree or any clipboard contents.
            android.util.Log.i("OwnedMaintenanceEvidence", "$name unavailable: ${failure.javaClass.simpleName}")
        }
    }

    private fun search(word:String) {
        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.onNode(hasSetTextAction()).performTextInput(word)
        compose.waitUntil(10000){compose.onAllNodesWithText(word).fetchSemanticsNodes().isNotEmpty()}
        compose.onAllNodesWithText(word).onFirst().performClick()
        compose.waitUntil(10000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
    }
    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = java.io.File(instrumentation.targetContext.filesDir,"qa-screenshots").apply { mkdirs() }
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { java.io.File(directory,name).outputStream().use { assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)) } }
        finally { bitmap.recycle() }
    }
    @Test fun corpusArabicAndCompiledAliasRemainReadableInPortrait(): Unit = runBlocking {
        val before = library.dictionaries.map { it.id }.toSet()
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        try {
            for ((name,asset) in listOf(
                "arwiktionary-20261001-d274159863057eb5c633116c3b54e4f8659167f0b73fabbee256e881fa1ac8c8.wikblb" to "arabic-visual.wikblb",
                "bgwiktionary-20261001-aliases.wikblb" to "compiled-aliases.wikblb",
                "bgwiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb" to "compiled-alias-targets.wikblb")) {
                library.importFile(name={name}) { assets.open(asset) }.join()
                assertNull(library.error)
            }
            assertEquals("ar",library.read(library.exact("-هُم","العربية","arwiktionary-20261001")!!).languageCode)
            search("ChainA")
            compose.onNodeWithContentDescription("Pronounce word offline").performClick()
            compose.onNodeWithText("This entry has no identified language for speech.").assertExists()
            search("-هُم")
            compose.onAllNodesWithText("This entry has no identified language for speech.").assertCountEquals(0)
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            compose.onNode(
                (hasTestTag("entry-title") or hasAnyAncestor(hasTestTag("entry-title"))) and
                    SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult),
                useUnmergedTree = true
            ).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertEquals(1,layouts.single().lineCount)
            capture("actual-arabic-excerpt.png")
            search("ChainA")
            compose.onNodeWithText("ChainA -> ChainB#Incoming").assertExists()
            compose.onNodeWithText("gainst",substring=true).assertExists()
            capture("synthetic-alias-chain.png")
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithTag("settings-scroll").performScrollToNode(hasText("Images & sound"))
            capture("portrait-media-settings.png")
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }
    @Test fun emptyAvailableCatalogExplainsRecoveryAndPreservesValidationErrors(): Unit = runBlocking {
        val previousSources = library.sources.toList()
        val previousDictionaries = library.dictionaries.map { it.id }
        val explanation = "No downloads listed. Add a catalogue or import a file."
        val importError = "Selected file unavailable"
        // Own isolated test process state only: never fail or modify its real database.
        val failuresField = LibraryStore::class.java.getDeclaredField("failures").apply { isAccessible = true }
        val failures = failuresField.get(library) as LibraryFailureState
        val initializationField = LibraryFailureState::class.java
            .getDeclaredField("initializationError" + "$" + "delegate").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val initializationState = initializationField.get(failures) as androidx.compose.runtime.MutableState<String?>
        val previousInitializationError = initializationState.value
        val startupError = "Unable to open your library. Restart the app to try again."
        val scopeField = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }
        val scopeJob = (scopeField.get(library) as kotlinx.coroutines.CoroutineScope).coroutineContext[kotlinx.coroutines.Job]!!
        val mutexField = LibraryStore::class.java.getDeclaredField("mutex").apply { isAccessible = true }
        val operationMutex = mutexField.get(library) as kotlinx.coroutines.sync.Mutex
        suspend fun drainLibrary() = kotlinx.coroutines.withTimeout(15000) {
            scopeJob.children.toList().forEach { it.join() }
        }
        var imports = 0
        assertTrue("Isolated debug catalogue must use bundled rows",
            previousSources == listOf(Catalog.DEBUG_FIXTURE) || previousSources == listOf(Catalog.DEFAULT))
        try {
            drainLibrary()
            // A queued empty refresh cannot finish under this mutex. This detects
            // the transient operation even if its busy label would be missed by a frame.
            operationMutex.lock()
            try {
                compose.runOnIdle {
                    runBlocking {
                        assertFalse(failures.initialize(open = { throw java.io.IOException("Owned startup failure fixture") }))
                    }
                    assertEquals(startupError, library.initializationError)
                    library.sources.toList().forEach(library::removeSource)
                    assertTrue(library.catalog.isEmpty())
                    assertNull(library.error)
                    assertTrue(library.refreshCatalogs().isCompleted)
                }
                compose.activityRule.scenario.onActivity { activity ->
                    activity.setContent {
                        androidx.compose.material3.MaterialTheme {
                            LibraryScreen(library) {
                                imports++
                                library.importFile(input = { throw java.io.IOException(importError) })
                            }
                        }
                    }
                }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertNull(library.busy)
                    assertFalse("No empty-source refresh may queue behind an import", scopeJob.children.any())
                }
                compose.onNodeWithText("Reading catalogues").assertDoesNotExist()
                compose.onNodeWithContentDescription("Import wikblb").assertIsEnabled()
                compose.onNodeWithContentDescription("Refresh catalogues").assertIsNotEnabled()
            } finally { operationMutex.unlock() }
            compose.onNodeWithText(explanation).assertIsDisplayed()
            compose.onNodeWithText(startupError).assertIsDisplayed()
            compose.onNodeWithContentDescription("Import wikblb").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(1, imports) }
            compose.waitUntil(15000) { library.busy == null && library.error == importError }
            compose.onNodeWithText(importError).assertIsDisplayed()
            compose.onNodeWithContentDescription("Refresh catalogues").assertIsNotEnabled()
            compose.runOnIdle {
                assertTrue(library.refreshCatalogs().isCompleted)
                assertEquals(importError, library.error)
            }
            compose.onNodeWithContentDescription("Add catalogue").performClick()
            compose.onNode(hasSetTextAction()).performTextInput("http://example.invalid/catalogue.list")
            compose.onNodeWithText("Add source").performClick()
            compose.onNodeWithText("Use an HTTPS catalogue URL").assertIsDisplayed()
            compose.onNodeWithText(importError).assertIsDisplayed()
            compose.onNodeWithText(explanation).assertIsDisplayed()
            compose.onNodeWithText("Add source").assertIsEnabled()
            compose.onNode(hasSetTextAction()).performTextReplacement(Catalog.DEFAULT)
            compose.onNodeWithText("Use an HTTPS catalogue URL").assertDoesNotExist()
            compose.onNodeWithText(importError).assertIsDisplayed()
            compose.onNodeWithText("Add source").performClick()
            compose.waitUntil(15000) { library.busy == null && library.catalog.isNotEmpty() }
            compose.onNodeWithText(explanation).assertDoesNotExist()
            compose.onNodeWithText(library.catalog.first().label).assertIsDisplayed()
            compose.onNodeWithText(importError).assertDoesNotExist()
            compose.onNodeWithText("Use an HTTPS catalogue URL").assertDoesNotExist()
            assertNull(library.error)
            compose.onNodeWithText(startupError).assertIsDisplayed()
            compose.runOnIdle { assertEquals(startupError, library.initializationError) }
            assertEquals(previousDictionaries, library.dictionaries.map { it.id })
            drainLibrary()
            compose.runOnIdle { failures.publishCatalogueError("Owned removed catalogue failure") }
            operationMutex.lock()
            lateinit var supersededRefresh: kotlinx.coroutines.Job
            try {
                compose.runOnIdle { supersededRefresh = library.refreshCatalogs() }
                compose.onNodeWithContentDescription("Remove source ${Catalog.DEFAULT}").performScrollTo().performClick()
                compose.runOnIdle {
                    assertTrue(library.sources.isEmpty())
                    assertTrue(library.catalog.isEmpty())
                    assertNull(library.error)
                    assertNull(library.busy)
                    assertEquals(listOf(supersededRefresh), scopeJob.children.toList())
                    assertEquals(startupError, library.initializationError)
                    failures.operationError = importError
                }
                compose.onNodeWithContentDescription("Import wikblb").performScrollTo().assertIsEnabled()
                compose.onNodeWithContentDescription("Refresh catalogues").assertIsNotEnabled()
                compose.onNodeWithText("Reading catalogues").assertDoesNotExist()
            } finally { operationMutex.unlock() }
            supersededRefresh.join()
            compose.runOnIdle {
                assertTrue(supersededRefresh.isCancelled)
                assertTrue(library.catalog.isEmpty())
                assertEquals(importError, library.error)
                assertNull(library.busy)
            }
        } finally {
            compose.runOnIdle {
                initializationState.value = previousInitializationError
                library.sources.toList().forEach(library::removeSource)
                previousSources.forEach(library::addSource)
            }
            library.refreshCatalogs().join()
            compose.waitUntil(15000) { library.busy == null }
            assertEquals(previousSources, library.sources)
            assertTrue(library.catalog.isNotEmpty())
        }
    }

    @Test fun pronunciationButtonNamesMatchPlayAndStopActions() {
        val playing = mutableStateOf(false)
        val actions = mutableListOf<Boolean>()
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent {
                androidx.compose.material3.MaterialTheme {
                    EntryPronunciationButton(playing.value) {
                        actions.add(playing.value)
                        playing.value = !playing.value
                    }
                }
            }
        }
        try {
            compose.onNodeWithContentDescription("Pronounce word offline")
                .assertIsDisplayed().assertIsEnabled().assertHasClickAction()
                .assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role, androidx.compose.ui.semantics.Role.Button))
                .performClick()
            compose.onAllNodesWithContentDescription("Pronounce word offline").assertCountEquals(0)
            compose.runOnIdle { assertTrue(playing.value); assertEquals(listOf(false), actions) }
            compose.onNodeWithContentDescription("Stop pronunciation")
                .assertIsDisplayed().assertIsEnabled().assertHasClickAction()
                .assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role, androidx.compose.ui.semantics.Role.Button))
                .performClick()
            compose.onAllNodesWithContentDescription("Stop pronunciation").assertCountEquals(0)
            compose.onNodeWithContentDescription("Pronounce word offline").assertIsDisplayed().assertIsEnabled()
            compose.runOnIdle { assertFalse(playing.value); assertEquals(listOf(false, true), actions) }
        } finally {
            compose.runOnIdle { playing.value = false }
        }
    }
    @Test fun binaryLibrarySearchDecodeAndRandomCoverMultipleWords() = runBlocking {
        assertTrue(library.dictionaries.sumOf{it.count}>20)
        val words=library.search("")
        assertTrue(words.size>20)
        for(hit in words) {
            val entry = library.read(hit)
            assertEquals(hit.title, entry.title)
            val texts = buildList {
                add(textOf(entry.displayTitle)); add(textOf(entry.preamble))
                entry.sections.forEach { section ->
                    add(section.title)
                    section.blocks.forEach { block ->
                        add(textOf(block.spans))
                        block.table?.let { table -> add(textOf(table.caption)); table.rows.flatten().forEach { add(textOf(it.spans)) } }
                    }
                }
                entry.references.forEach { add(textOf(it.spans)) }
                entry.media.forEach { add(it.caption) }
            }
            for (text in texts) assertFalse("Unrendered syntax in ${entry.title}: $text", Regex("\\[\\[|\\]\\]|\\{\\{|\\}\\}|</?[A-Za-z][^>]*>|\\{\\||\\|\\}").containsMatchIn(text))
        }
        assertNotNull(library.exact("cat"));assertTrue(library.search("not-in-this-corpus").isEmpty())
        assertTrue((1..20).map{library.random()!!.title}.distinct().size>1)
    }
    @Test fun foldedSectionsSearchAndRecreationRemainUsable() {
        search("cat")
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand Etymology 1"))
        compose.onNodeWithContentDescription("Expand Etymology 1").performClick()
        compose.onNodeWithContentDescription("Collapse Etymology 1").assertExists()
        val retainedScroll = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
        compose.onNodeWithContentDescription("Saved").performClick()
        // Enter the visible child screen before dispatching Back outside Compose.
        compose.onNodeWithText("Saved").assertIsDisplayed()
        compose.waitForIdle()
        compose.runOnIdle {
            assertFalse(compose.activity.isFinishing)
            assertFalse(compose.activity.isDestroyed)
            android.util.Log.i("ReaderBackEvidence", "Saved screen ready; activity finishing=false destroyed=false")
        }
        compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithContentDescription("Collapse Etymology 1").assertExists()
        val restoredScroll = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
        assertEquals(retainedScroll, restoredScroll, 0.01f)
        // Use this installed fixture's real links and the actual reader handler, not
        // a controller-only callback or a second root search pretending to be Back.
        val sourceHit = runBlocking { requireNotNull(library.lastWord()) }
        val sourceEntry = runBlocking { library.read(sourceHit) }
        val destinations = runBlocking {
            val hits = linkedMapOf<String, WordHit>()
            sourceEntry.sections.flatMap { it.blocks }.flatMap { it.spans }
                .filter { it.kind == "link" && it.target.isNotBlank() }
                .map { it.target }.distinct().forEach { target ->
                    library.link(EntryLink(target), sourceEntry)?.takeIf { it.key != sourceHit.key }?.let { hits[target] = it }
                }
            hits
        }
        assertTrue("Installed cat fixture must contain a link to another installed entry", destinations.isNotEmpty())
        val readerLink = SemanticsMatcher("real installed reader link") { node ->
            node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Text).orEmpty().any { text ->
                text.getLinkAnnotations(0, text.length).any {
                    (it.item as? androidx.compose.ui.text.LinkAnnotation.Clickable)?.tag in destinations
                }
            }
        }
        compose.onNodeWithTag("entry-scroll").performScrollToNode(readerLink)
        val paragraph = compose.onAllNodes(readerLink, useUnmergedTree = true).onFirst()
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        paragraph.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val layout = layouts.single()
        val link = layout.layoutInput.text.getLinkAnnotations(0, layout.layoutInput.text.length).first {
            (it.item as? androidx.compose.ui.text.LinkAnnotation.Clickable)?.tag in destinations
        }
        val target = (link.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag
        val destination = requireNotNull(destinations[target])
        val destinationEntry = runBlocking { library.read(destination) }
        val destinationTitle = destinationEntry.displayTitle.takeIf { it.isNotEmpty() }
            ?.joinToString("") { it.text + it.trail } ?: destinationEntry.title
        val linkScroll = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
        paragraph.performTouchInput { click(layout.getBoundingBox(link.start).center) }
        compose.waitUntil(15000) { runBlocking { library.lastWord()?.key == destination.key } }
        // A link fragment may open below the header; verify the rendered destination too.
        compose.onNodeWithTag("entry-scroll").performScrollToIndex(0)
        compose.onNodeWithTag("entry-title").assertTextEquals(destinationTitle)
        compose.onAllNodesWithText((destinationEntry.language ?: destinationEntry.kind.replace('_', ' ')).uppercase())
            .onFirst().assertIsDisplayed()
        assertEquals(destination.key, runBlocking { library.lastWord() }?.key)
        // Retain B's nondefault fold/scroll and the A->B path across configuration recreation.
        val destinationSection = destinationEntry.readingRows.mapNotNull { row ->
            row.heading?.title?.takeIf { it.isNotBlank() && it != destinationEntry.language }
        }.groupingBy { it }.eachCount().entries.first { it.value == 1 }.key
        val destinationToggle = hasContentDescription("Expand $destinationSection") or
            hasContentDescription("Collapse $destinationSection")
        compose.onNodeWithTag("entry-scroll").performScrollToNode(destinationToggle)
        val destinationWasExpanded = compose.onAllNodesWithContentDescription("Collapse $destinationSection")
            .fetchSemanticsNodes().isNotEmpty()
        val beforeToggle = if (destinationWasExpanded) "Collapse $destinationSection" else "Expand $destinationSection"
        val afterToggle = if (destinationWasExpanded) "Expand $destinationSection" else "Collapse $destinationSection"
        compose.onNodeWithContentDescription(beforeToggle).performClick()
        compose.onNodeWithContentDescription(afterToggle).assertExists()
        val destinationScroll = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
        compose.activityRule.scenario.recreate()
        compose.waitUntil(15000) {
            compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
        assertEquals(destination.key, runBlocking { library.lastWord() }?.key)
        val recreatedDestinationScroll = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
        assertEquals(destinationScroll, recreatedDestinationScroll, 0.01f)
        // Observe the retained rendered B, not only the persisted last-word preference.
        compose.onNodeWithTag("entry-scroll").performScrollToIndex(0)
        compose.onNodeWithTag("entry-title").assertTextEquals(destinationTitle)
        compose.onAllNodesWithText((destinationEntry.language ?: destinationEntry.kind.replace('_', ' ')).uppercase())
            .onFirst().assertIsDisplayed()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription(afterToggle))
        compose.onNodeWithContentDescription(afterToggle).assertExists()
        compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
        compose.waitUntil(15000) { runBlocking { library.lastWord()?.key == sourceHit.key } }
        assertEquals(sourceHit.key, runBlocking { library.lastWord() }?.key)
        val backScroll = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
        assertEquals(linkScroll, backScroll, 0.01f)
        compose.onNodeWithTag("entry-scroll").performScrollToIndex(0)
        compose.onNodeWithTag("entry-title").assertTextEquals("cat")
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Collapse Etymology 1"))
        compose.onNodeWithContentDescription("Collapse Etymology 1").performClick()
        val screen=compose.onRoot().fetchSemanticsNode().boundsInRoot
        val reading=compose.onNodeWithTag("entry-scroll").fetchSemanticsNode().boundsInRoot
        assertTrue(reading.height/screen.height>0.85f)
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNodeWithText("Dark").performClick()
        compose.onNodeWithText("Light").performClick()
        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("ca")
        compose.activityRule.scenario.recreate()
        compose.waitUntil(15000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        compose.onNode(hasSetTextAction()).assertTextEquals("ca")
        compose.onAllNodesWithTag("entry-scroll").assertCountEquals(0)
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.waitUntil(15000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("entry-title").assertTextEquals("cat")

        compose.onNodeWithContentDescription("Dictionary").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("ca")
        compose.activityRule.scenario.recreate()
        compose.waitUntil(15000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        compose.onNode(hasSetTextAction()).assertTextEquals("ca")
        compose.onAllNodesWithTag("entry-scroll").assertCountEquals(0)
        compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
        compose.waitUntil(15000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("entry-title").assertTextEquals("cat")

        compose.activityRule.scenario.recreate()
        compose.waitUntil(15000){compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("entry-title").assertTextEquals("cat")
    }
    @Test fun checksumFailureDoesNotInstallOrDamageLibrary() = runBlocking {
        val before=library.dictionaries.map{it.id}
        library.download(library.catalog.first().copy(sha256="0".repeat(64))).join()
        assertTrue(library.error!!.contains("checksum"))
        assertEquals(before,library.dictionaries.map{it.id})
        assertEquals("cat",library.read(library.exact("cat")!!).title)
    }
    @Suppress("DEPRECATION")
    @Test fun failedSystemDownloadVerificationAllowsCompletedRowRecovery() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = context.getSystemService(android.content.Context.DOWNLOAD_SERVICE) as android.app.DownloadManager
        val prefs = context.getSharedPreferences("library", android.content.Context.MODE_PRIVATE)
        val keys = listOf("downloadId", "downloadUrl", "downloadLabel", "downloadBytes", "downloadHash")
        val saved = prefs.all.filterKeys { it in keys }
        assertEquals("A genuine retained download must not be replaced", -1L, prefs.getLong("downloadId", -1))
        assertTrue(saved.values.all { it is String || it is Long })
        val fixture = library.catalog.first()
        assertTrue(fixture.url.startsWith("asset://"))
        val bytes = requireNotNull(fixture.bytes)
        val hash = requireNotNull(fixture.sha256)
        val item = CatalogItem("https://example.invalid/recovery/English.wikblb", "Local completed download", bytes, hash)
        val before = library.dictionaries.map { it.id }.toSet()
        val ids = mutableListOf<Long>()
        val files = mutableListOf<java.io.File>()
        val directory = requireNotNull(context.getExternalFilesDir("downloads"))
        val parts = java.io.File(context.filesDir, "dictionaries")
        val oldParts = parts.listFiles().orEmpty().filter { it.extension == "part" }.map { it.name }.toSet()
        fun completed(value: CatalogItem): Long {
            val file = java.io.File(directory, "recovery-${java.util.UUID.randomUUID()}.wikblb")
            files.add(file)
            context.assets.open(fixture.url.removePrefix("asset://")).use { input -> file.outputStream().use { input.copyTo(it) } }
            assertEquals(bytes, file.length())
            val id = manager.addCompletedDownload("Wikidict recovery fixture", value.label, false, "application/octet-stream", file.absolutePath, file.length(), true)
            assertTrue(id >= 0)
            ids.add(id)
            manager.query(android.app.DownloadManager.Query().setFilterById(id)).use { c ->
                assertTrue(c.moveToFirst())
                assertEquals(android.app.DownloadManager.STATUS_SUCCESSFUL, c.getInt(c.getColumnIndexOrThrow(android.app.DownloadManager.COLUMN_STATUS)))
            }
            assertTrue(prefs.edit().putLong("downloadId", id).putString("downloadUrl", value.url).putString("downloadLabel", value.label)
                .putLong("downloadBytes", value.bytes ?: -1).putString("downloadHash", value.sha256).commit())
            return id
        }
        fun cleared(id: Long) {
            manager.query(android.app.DownloadManager.Query().setFilterById(id)).use { assertFalse(it.moveToFirst()) }
            keys.forEach { assertFalse("Stale download field: $it", prefs.contains(it)) }
            assertNull(library.busy)
            assertEquals(oldParts, parts.listFiles().orEmpty().filter { it.extension == "part" }.map { it.name }.toSet())
        }
        try {
            for ((bad, message) in listOf(item.copy(sha256 = "0".repeat(64)) to "checksum", item.copy(bytes = bytes + 1) to "Incomplete download")) {
                val id = completed(bad)
                library.download(bad).join()
                assertTrue("Expected $message verification failure; observed library.error=${library.error}",
                    library.error.orEmpty().contains(message, ignoreCase = true))
                cleared(id)
                assertEquals(before, library.dictionaries.map { it.id }.toSet())
                assertEquals("cat", library.read(library.exact("cat")!!).title)
            }
            // Re-enter the real completed-row verifier with the same URL, then another URL.
            // Every row is local and pre-completed; this is not a network/enqueue assertion.
            for (valid in listOf(item, item.copy(url = "https://example.invalid/another/English.wikblb"))) {
                val id = completed(valid)
                library.download(valid).join()
                assertNull(library.error)
                cleared(id)
                assertEquals(before, library.dictionaries.map { it.id }.toSet())
                assertEquals("cat", library.read(library.exact("cat")!!).title)
            }
        } finally {
            ids.forEach { runCatching { manager.remove(it) } }
            files.forEach { it.delete() }
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
            val editor = prefs.edit()
            keys.forEach { editor.remove(it) }
            saved.forEach { (key, value) -> when (value) { is String -> editor.putString(key, value); is Long -> editor.putLong(key, value) } }
            assertTrue(editor.commit())
        }
    }
    @Test fun liveMediaDownloadsAndCacheHonorsLimits() = runBlocking {
        org.junit.Assume.assumeTrue("Opt in with -Pandroid.testInstrumentationRunnerArguments.liveMedia=true", InstrumentationRegistry.getArguments().getString("liveMedia") == "true")
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val cache=MediaCache.get(context)
        cache.clear()
        val entry=library.read(library.exact("cat")!!)
        val image=cache.get(entry.media.first{it.kind=="image"},25)
        assertTrue(image.file.length()>0)
        assertNotNull(android.graphics.BitmapFactory.decodeFile(image.file.absolutePath))
        assertTrue(image.source.startsWith("https://"))
        val audio=cache.get(entry.media.first{it.kind=="audio"},25)
        assertTrue(audio.file.length()>0)
        val retriever=android.media.MediaMetadataRetriever()
        try { retriever.setDataSource(audio.file.absolutePath); assertTrue(retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()>0) } finally { retriever.release() }
        assertEquals(image.file,cache.get(entry.media.first{it.kind=="image"},25).file)
        cache.trim(0)
        assertFalse(image.file.exists());assertFalse(audio.file.exists())
    }


    @Test fun supportingSectionsAndSenseNotesStartFolded() {
        search("A")
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand Alternative forms"))
        compose.onAllNodesWithText("Centennial", substring = true).assertCountEquals(0)
        compose.onNodeWithContentDescription("Expand Alternative forms").performClick()
        compose.onNodeWithContentDescription("Collapse Alternative forms").assertExists()
        compose.onAllNodesWithText("Centennial", substring = true).onFirst().assertExists()
        compose.onNodeWithContentDescription("Collapse Alternative forms").performClick()
        compose.onAllNodesWithText("Centennial", substring = true).assertCountEquals(0)
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Show examples and notes for Letter"))
        compose.onNodeWithContentDescription("Show examples and notes for Letter").performClick()
        compose.onNodeWithContentDescription("Hide examples and notes for Letter").assertExists()
        compose.onNodeWithContentDescription("Hide examples and notes for Letter").performClick()
        compose.onNodeWithContentDescription("Show examples and notes for Letter").assertExists()
    }

    @Test fun bottomSettingsConfirmationRevealsWithoutMovingAccessibilityFocus() {
        val learning = LearningStore.get(compose.activity)
        val before = learning.data
        var host: android.view.View? = null
        var provider: android.view.accessibility.AccessibilityNodeProvider? = null
        var previousForce: Boolean? = null
        var focusedId: Int? = null
        var primaryFailure: Throwable? = null
        fun rawBounds(node: SemanticsNodeInteraction): androidx.compose.ui.geometry.Rect {
            val semantic = node.fetchSemanticsNode()
            return androidx.compose.ui.geometry.Rect(semantic.positionInRoot,
                androidx.compose.ui.geometry.Size(semantic.size.width.toFloat(), semantic.size.height.toFloat()))
        }
        fun composeHost(view: android.view.View): android.view.View? {
            if (view.javaClass.name == "androidx.compose.ui.platform.AndroidComposeView") return view
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) {
                composeHost(view.getChildAt(index))?.let { return it }
            }
            return null
        }
        fun assertFocusedTrigger() {
            compose.runOnIdle {
                val info = checkNotNull(checkNotNull(provider).createAccessibilityNodeInfo(checkNotNull(focusedId)))
                try {
                    assertTrue("Automatic reveal must preserve accessibility focus", info.isAccessibilityFocused)
                    assertTrue(info.isVisibleToUser)
                    assertTrue(info.isEnabled)
                } finally { info.recycle() }
            }
        }
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent {
                    val density = LocalDensity.current
                    CompositionLocalProvider(LocalDensity provides Density(density.density, 1f)) {
                        DictTheme(before.settings.darkMode) {
                            Box(Modifier.size(width = 360.dp, height = 480.dp).clipToBounds()
                                .testTag("settings-confirmation-viewport")) { SettingsScreen(learning) }
                        }
                    }
                }
            }
            val viewport = compose.onNodeWithTag("settings-confirmation-viewport")
            val scroll = compose.onNodeWithTag("settings-scroll")
            val show = compose.onNode(hasText("Clear history") and hasClickAction())
            scroll.performScrollToNode(hasText("Clear history"))
            show.assertIsDisplayed().assertIsEnabled()
            val bounds = rawBounds(viewport)
            val trigger = rawBounds(show)
            assertTrue("Regression begins with the last button row at the viewport bottom",
                trigger.top >= bounds.top && trigger.bottom <= bounds.bottom + 1f &&
                    bounds.bottom - trigger.bottom < trigger.height / 2f)
            compose.onNodeWithText("Clear history?").assertDoesNotExist()
            focusedId = show.fetchSemanticsNode().id
            compose.runOnIdle {
                val owner = checkNotNull(composeHost(compose.activity.window.decorView))
                host = owner
                provider = checkNotNull(owner.accessibilityNodeProvider)
                val delegateField = owner.javaClass.getDeclaredField("composeAccessibilityDelegate").apply { isAccessible = true }
                val delegate = checkNotNull(delegateField.get(owner))
                val forceField = delegate.javaClass.getDeclaredField("accessibilityForceEnabledForTesting").apply { isAccessible = true }
                previousForce = forceField.getBoolean(delegate)
                // Only this owned Compose view's test hook; no global service or touch-exploration setting.
                owner.javaClass.getMethod("forceAccessibilityForTesting", java.lang.Boolean.TYPE).invoke(owner, true)
                assertTrue(checkNotNull(provider).performAction(checkNotNull(focusedId),
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
            }
            assertFocusedTrigger()
            withRenderedLayoutFailureEvidence("bottom Settings confirmation", show, viewport,
                "settings-confirmation", { "controlled per-view accessibility test; no global AT changes" }) {
                compose.runOnIdle {
                    assertTrue(checkNotNull(provider).performAction(checkNotNull(focusedId),
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                }
                // No test scroll or focus request follows the action: the production reveal must do it.
                compose.waitForIdle()
                for (label in listOf("Clear history?", "Keep", "Clear")) {
                    val node = compose.onNodeWithText(label)
                    node.assertIsDisplayed().assertIsEnabled()
                    val actual = rawBounds(node)
                    assertTrue("Full confirmation content must be visible: $label, $actual in $bounds",
                        actual.width > 0f && actual.height > 0f && actual.left >= bounds.left - 1f &&
                            actual.right <= bounds.right + 1f && actual.top >= bounds.top - 1f &&
                            actual.bottom <= bounds.bottom + 1f)
                    if (label != "Clear history?") {
                        node.assertHasClickAction()
                        val id = node.fetchSemanticsNode().id
                        compose.runOnIdle {
                            val info = checkNotNull(checkNotNull(provider).createAccessibilityNodeInfo(id))
                            try {
                                assertTrue(info.isVisibleToUser && info.isEnabled)
                                assertTrue(info.actionList.any { it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK })
                                assertFalse("Reveal must not move focus onto either decision", info.isAccessibilityFocused)
                            } finally { info.recycle() }
                        }
                    }
                }
                assertFocusedTrigger()
                compose.runOnIdle { assertEquals(before, learning.data) }
                compose.onNodeWithText("Keep").performClick()
                compose.waitForIdle()
                compose.onNodeWithText("Clear history?").assertDoesNotExist()
                compose.onNodeWithText("Keep").assertDoesNotExist()
                assertFocusedTrigger()
                compose.runOnIdle { assertEquals(before, learning.data) }
            }
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            try {
                compose.runOnUiThread {
                    val owner = host
                    val previous = previousForce
                    try {
                        focusedId?.let { provider?.performAction(it,
                            android.view.accessibility.AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS, null) }
                    } finally {
                        try {
                            if (owner != null && previous != null) owner.javaClass
                                .getMethod("forceAccessibilityForTesting", java.lang.Boolean.TYPE).invoke(owner, previous)
                        } finally { compose.activity.setContent {} }
                    }
                }
            } catch (cleanup: Throwable) {
                primaryFailure?.addSuppressed(cleanup) ?: throw cleanup
            }
        }
    }

    @Test fun preferenceSlidersCommitAccessibleValues() {
        val learning = LearningStore.get(compose.activity)
        compose.onNodeWithContentDescription("Settings").performClick()
        fun slide(label: String, position: Float) {
            compose.onNodeWithTag("settings-scroll").performScrollToNode(hasContentDescription(label))
            compose.onNodeWithContentDescription(label).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { it(position) }
            compose.waitForIdle()
        }
        slide("Media cache", 0f)
        assertEquals(0, learning.data.settings.mediaCacheMb)
        slide("Media cache", 1f)
        assertEquals(4096, learning.data.settings.mediaCacheMb)
        slide("Remember words", 1f)
        assertEquals(100_000, learning.data.settings.historyLimit)
        slide("Remember words", 0f)
        assertFalse(learning.data.settings.historyEnabled)
        slide("Questions per round", .5f)
        assertEquals(27, learning.data.settings.quizLength)
        compose.runOnIdle { learning.updateSettings { it.copy(mediaCacheMb=100, historyEnabled=true, historyLimit=100, quizLength=10) } }
    }
    @Test fun systemDownloadManagerFetchesAndVerifiesDictionary() = runBlocking {
        val item = CatalogItem(
            InstrumentationRegistry.getArguments().getString("dictionaryUrl") ?: "https://github.com/SmallThingz/wikidict/releases/download/dictionary-qa-1388760245fd/wikidict-app-qa-English-30words.wikblb",
            "English device transfer", 3365898,
            "1388760245fdfc7aaadebe1770415f44cf26e391811abae8d62b4044528b4ee3",
        )
        val before = library.dictionaries.map { it.id }.toSet()
        try {
            withTimeout(120_000) { library.download(item).join() }
            assertNull(library.error)
            val edition = dictionaryEdition(java.net.URI(item.url).path.substringAfterLast('/'))
            val id = if (edition.isEmpty()) item.sha256 else "${item.sha256}-$edition"
            assertTrue(library.dictionaries.any { it.id == id && it.edition == edition })
            assertEquals("cat",library.read(library.search("cat").single { it.dictionary == id && it.title == "cat" }).title)
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }
    @Test fun searchChoicesDistinguishTheSameWordInDifferentSourceEditions(): Unit = runBlocking {
        val before = library.dictionaries.map { it.id }.toSet()
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("compiled-alias-targets.wikblb").use { it.readBytes() }
        try {
            for (edition in listOf("ar","bg")) {
                library.importFile(name={"${edition}wiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"}) { java.io.ByteArrayInputStream(bytes) }.join()
                assertNull(library.error)
            }
            compose.onNodeWithContentDescription("Dictionary").performClick()
            compose.onNode(hasSetTextAction()).performTextInput("animus")
            compose.waitUntil(10000){compose.onAllNodesWithText("ar.wiktionary.org · 2026-10-01").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("ar.wiktionary.org · 2026-10-01").assertExists()
            compose.onNodeWithText("bg.wiktionary.org · 2026-10-01").assertExists()
            capture("source-edition-choices.png")
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }
    @Test fun missingEntryLinkShowsSnackbarAndRecoversThroughActualReader() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue("Use the isolated validation app", context.packageName.endsWith(".validation"))
        val learning = LearningStore.get(context)
        val previousLearning = learning.data
        val installed = library.dictionaries.toList()
        val previousIds = installed.map { it.id }.toSet()
        val prefs = context.getSharedPreferences("library", 0)
        val lastKeys = listOf("lastTitle", "lastLanguage", "lastDictionary", "lastRecordKey", "lastContextDictionary", "lastEdition")
        val previousWord = lastKeys.associateWith { prefs.getString(it, null) }
        val edition = "readererror" + java.util.UUID.randomUUID().toString().replace("-", "").take(8) + "wiktionary-20261001"
        val owned = mutableSetOf<String>()
        val fixtureKeys = mutableSetOf<String>()
        val errorMessage = "This word is not in your installed dictionaries."
        val progress = SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo)
        fun install(asset: String, filename: String): DictionaryInfo = runBlocking {
            val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open(asset).use { it.readBytes() }
            val id = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) } + "-" + edition
            assertFalse(previousIds.contains(id))
            owned += id
            library.importFile(name = { filename }) { java.io.ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
            library.dictionaries.single { it.id == id }
        }
        fun waitForTitle(title: String) {
            compose.waitUntil(10000) {
                compose.onAllNodes(hasTestTag("entry-title") and hasText(title))
                    .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
        }
        try {
            val english = "ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06"
            val target = install("compiled-alias-targets.wikblb", edition + "-" + english + ".wikblb")
            val aliases = install("alias-edges.wikblb", edition + "-aliases.wikblb")
            val missing = runBlocking { library.search("Missing").single {
                it.dictionary == aliases.id && it.contextDictionary == target.id && it.title == "Missing"
            } }
            val recovery = runBlocking { library.search("animus").single {
                it.dictionary == target.id && it.title == "animus"
            } }
            val missingEntry = runBlocking { library.read(missing) }
            val recoveredEntry = runBlocking { library.read(recovery) }
            fixtureKeys += missingEntry.key
            fixtureKeys += recoveredEntry.key
            assertEquals("Missing", missingEntry.title)
            assertFalse(requireNotNull(missingEntry.redirect).followed)
            assertEquals(edition, missingEntry.edition)
            assertEquals("English", missingEntry.navigationLanguage)
            assertNull(runBlocking { library.link(EntryLink("absent"), missingEntry) })
            assertTrue(previousLearning.history.size <= 99_998)
            compose.runOnIdle {
                // Preserve prior history while allowing the two real navigation commits.
                learning.updateSettings { it.copy(historyEnabled = true,
                    historyLimit = maxOf(it.historyLimit, previousLearning.history.size + 2),
                    allowImages = false, allowAudio = false) }
                compose.activity.setContent { DictTheme(learning.data.settings.darkMode) {
                    DictApp(library, learning) {}
                } }
            }
            // Open the fixture through the real UI; replacing content retains this Activity's reader session.
            compose.onNodeWithContentDescription("Dictionary").performClick()
            compose.onNode(hasSetTextAction()).performTextReplacement("Missing")
            val initialChoice = hasText("Missing") and hasText(sourceLabel(edition)) and
                hasClickAction() and !hasSetTextAction()
            compose.waitUntil(10000) {
                compose.onAllNodes(initialChoice).fetchSemanticsNodes(atLeastOneRootRequired = false).size == 1
            }
            compose.onAllNodes(initialChoice).assertCountEquals(1).onFirst().performClick()
            waitForTitle("Missing")
            assertEquals(missing.key, runBlocking { library.lastWord() }?.key)
            val beforeError = learning.data
            val wordBeforeError = lastKeys.associateWith { prefs.getString(it, null) }
            assertEquals(missingEntry.key, beforeError.history.first().key)
            val link = compose.onNodeWithText("absent", useUnmergedTree = true)
                .performScrollTo().assertIsDisplayed()
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            link.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertEquals(1, layouts.size)
            link.performTouchInput { click(layouts.single().getBoundingBox(1).center) }
            compose.waitUntil(10000) {
                compose.onAllNodesWithText(errorMessage).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onNodeWithText(errorMessage).assertIsDisplayed()
            compose.onNodeWithTag("entry-title").assertTextEquals("Missing")
            compose.onAllNodes(progress).assertCountEquals(0)
            compose.runOnIdle {
                assertEquals(beforeError, learning.data)
                assertEquals(wordBeforeError, lastKeys.associateWith { prefs.getString(it, null) })
            }

            // Recover through the real dock/search/reader while the failed intent owns a snackbar.
            compose.onNodeWithContentDescription("Dictionary").performClick()
            compose.onNodeWithText(errorMessage).assertDoesNotExist()
            compose.onNode(hasSetTextAction()).performTextInput("animus")
            val choice = hasText("animus") and hasText(sourceLabel(edition)) and hasClickAction() and !hasSetTextAction()
            compose.waitUntil(10000) {
                compose.onAllNodes(choice).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onAllNodes(choice).assertCountEquals(1)
            compose.onNode(choice).performScrollTo().assertIsDisplayed().performClick()
            waitForTitle("animus")
            compose.onNodeWithText("Target definition.").assertIsDisplayed()
            compose.onNodeWithText(errorMessage).assertDoesNotExist()
            compose.onAllNodes(progress).assertCountEquals(0)
            compose.runOnIdle {
                assertEquals(recovery.dictionary, prefs.getString("lastDictionary", null))
                assertEquals(recovery.recordKey, prefs.getString("lastRecordKey", null))
                assertEquals(recovery.edition, prefs.getString("lastEdition", null))
                assertEquals(recoveredEntry.key, learning.data.history.first().key)
                assertEquals(1, learning.data.history.count { it.key == recoveredEntry.key })
            }
        } finally {
            try {
                compose.runOnIdle { compose.activity.setContent {} }
                compose.waitForIdle()
            } finally {
                try {
                    runBlocking {
                        owned.filter { id -> library.dictionaries.any { it.id == id } }.forEach { id ->
                            library.remove(id).join()
                            assertNull(library.error)
                        }
                    }
                    assertEquals(installed.sortedBy { it.id }, library.dictionaries.sortedBy { it.id })
                } finally {
                    assertTrue(prefs.edit().apply {
                        previousWord.forEach { (key, value) -> putString(key, value) }
                    }.commit())
                    compose.runOnIdle {
                        fixtureKeys.forEach(learning::removeHistory)
                        learning.updateSettings { previousLearning.settings }
                        assertEquals(previousLearning, learning.data)
                    }
                }
            }
        }
    }

    @Test fun coldLearningPersistenceKeepsAllBookmarksAndExplicitHistoryLimit() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "qa-learning-roundtrip-" + java.util.UUID.randomUUID()
        val prefs = context.getSharedPreferences(name, 0)
        val bookmarks = (0 until 1025).map { index ->
            val edition = if (index % 2 == 0) "enwiktionary-20261001" else "frwiktionary-20261001"
            val origin = WordHit("aliases-" + edition, "слово", "English", "language", 0, 4,
                recordKey = "1\tword-" + index, contextDictionary = "english-" + edition, edition = edition)
            SavedWord(origin.key, origin.title, origin.language, origin.kind, "معنى " + index,
                savedAt = index.toLong() + 10, lastViewed = index.toLong() + 20, views = index + 1,
                dictionary = origin.dictionary, recordKey = origin.recordKey,
                contextDictionary = origin.contextDictionary, edition = edition)
        }
        val before = LearningData(
            history = bookmarks.take(3), bookmarks = bookmarks,
            study = mapOf(bookmarks.last().key to StudyStat(right = 2, wrong = 1, last = 42)),
            settings = AppSettings(historyLimit = 3),
        )
        try {
            LearningPersistence.persist(prefs, before)
            // Decode persisted JSON afresh; Activity recreation retains the singleton.
            val restored = LearningPersistence.load(prefs)
            assertEquals(1025, restored.bookmarks.map { it.key }.toSet().size)
            assertEquals(before, restored) // Includes order, all owner fields and saved metadata.
            assertEquals(bookmarks.last(), restored.bookmarks.last())

            val hit = WordHit("english-enwiktionary-20261001", "recent", "English", "language", 0, 4,
                edition = "enwiktionary-20261001")
            val entry = Entry("recent", emptyList(), "language", "English", "en",
                emptyList(), emptyList(), edition = hit.edition, origin = hit, contentDictionary = hit.dictionary)
            val updated = restored.recordEntry(entry, 5000).copy(settings = restored.settings.copy(darkMode = "dark"))
            assertEquals(listOf(hit.key) + before.history.take(2).map { it.key }, updated.history.map { it.key })
            assertEquals(3, updated.settings.historyLimit)
            assertEquals(bookmarks, updated.bookmarks)
            LearningPersistence.persist(prefs, updated)
            val reloaded = LearningPersistence.load(prefs)
            assertEquals(updated, reloaded)
            assertEquals(bookmarks.last(), reloaded.bookmarks.last())
        } finally {
            assertTrue(prefs.edit().clear().commit())
            assertTrue(context.deleteSharedPreferences(name))
        }
    }

    @Test fun compressedDictionaryIndexesAndReadsWithoutExpandingOnDisk() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val rawHit = library.exact("elephant", "English")!!
        val expected = library.read(rawHit)
        val before = library.dictionaries.map { it.id }.toSet()
        val compressed = java.io.File(context.cacheDir, "test.wikblb.xz")
        val learning = LearningStore.get(context)
        val prefs = context.getSharedPreferences("library", 0)
        val lastKeys = listOf("lastTitle", "lastLanguage", "lastDictionary", "lastRecordKey", "lastContextDictionary", "lastEdition")
        val oldPrefs = lastKeys.associateWith { prefs.getString(it, null) }
        var learningBefore: LearningData? = null
        var createdKeys = emptySet<String>()
        try {
            InstrumentationRegistry.getInstrumentation().context.assets.open("English-extreme.wikblb.xz").use { input ->
                compressed.outputStream().use { output -> input.copyTo(output) }
            }
            library.importFile { compressed.inputStream() }.join()
            assertNull(library.error)
            val info = library.dictionaries.single { it.id !in before }
            val hit = library.search("elephant").first { it.dictionary == info.id && it.title == "elephant" }
            val actual = library.read(hit)
            assertEquals(rawHit.dictionary, expected.contentDictionary)
            assertEquals(hit.dictionary, actual.contentDictionary)
            assertEquals(expected.copy(origin=null, contentDictionary=null), actual.copy(origin=null, contentDictionary=null))
            assertNotEquals(expected.origin?.dictionary, actual.origin?.dictionary)
            assertEquals(compressed.length(), java.io.File(context.filesDir, "dictionaries/${info.id}.wikblb").length())
            assertEquals("", expected.edition)
            assertEquals("", actual.edition)
            assertEquals(rawHit.key, expected.key)
            assertEquals(hit.key, actual.key)
            assertNotEquals(expected.key, actual.key)
            val keys = setOf(expected.key, actual.key)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                val saved = learning.data
                assertTrue(saved.settings.historyEnabled)
                assertTrue(saved.history.size + 2 <= saved.settings.historyLimit)
                assertTrue((saved.history + saved.bookmarks).none {
                    it.key in keys || it.key == expected.copy(origin = null).key
                })
                learningBefore = saved
                createdKeys = keys
            }
            val choices = library.search("elephant").filter { it.title == "elephant" }
            assertEquals(setOf(rawHit.key, hit.key), choices.map { it.key }.toSet())
            assertEquals(2, choices.size)
            val titleRow = hasText("elephant") and !hasSetTextAction()
            // Return to the raw entry last so removing the compressed fixture cannot open a fallback.
            for (choice in listOf(hit, rawHit)) {
                compose.onNodeWithContentDescription("Dictionary").performClick()
                compose.onNode(hasSetTextAction()).performTextReplacement("elephant")
                compose.waitUntil(10000) {
                    compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isEmpty() &&
                        compose.onAllNodes(titleRow).fetchSemanticsNodes().size == choices.size
                }
                compose.onAllNodes(titleRow)[choices.indexOfFirst { it.key == choice.key }].performClick()
                compose.waitUntil(10000) { compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithTag("entry-title").assertExists()
                assertEquals(choice.key, library.lastWord()!!.key)
                compose.onNodeWithContentDescription("Bookmark").performClick()
                compose.onNodeWithContentDescription("Remove bookmark").assertExists()
            }
            compose.onNodeWithContentDescription("Saved").performClick()
            compose.waitUntil(10000) { compose.onAllNodes(titleRow).fetchSemanticsNodes().size == 2 }
            compose.onAllNodes(titleRow).assertCountEquals(2)
            val bookmarks = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                learning.data.bookmarks.filter { it.key in keys }
            }
            assertEquals(keys, bookmarks.map { it.key }.toSet())
            assertEquals(setOf(rawHit.dictionary, hit.dictionary), bookmarks.map { it.dictionary }.toSet())
            for (word in bookmarks) assertEquals(word.key, library.read(library.savedWord(word)!!).key)
            compose.waitUntil(10000) {
                val state = context.getSharedPreferences("dict.learning.v1", 0).getString("state", null)
                val saved = state?.let { org.json.JSONObject(it).optJSONArray("bookmarks") }
                val persistedKeys = if (saved == null) emptySet() else
                    (0 until saved.length()).map { saved.getJSONObject(it).getString("key") }.toSet()
                persistedKeys.containsAll(keys)
            }
            compose.activityRule.scenario.recreate()
            compose.waitUntil(15000) {
                compose.onAllNodes(titleRow).fetchSemanticsNodes(atLeastOneRootRequired = false).size == 2
            }
            compose.onAllNodes(titleRow).assertCountEquals(2)
            for (choice in listOf(hit, rawHit)) {
                compose.onAllNodes(titleRow)[bookmarks.indexOfFirst { it.key == choice.key }].performClick()
                compose.waitUntil(10000) { compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isNotEmpty() }
                assertEquals(choice.key, library.lastWord()!!.key)
                compose.onNodeWithContentDescription("Remove bookmark").assertExists()
                compose.onNodeWithContentDescription("Saved").performClick()
                compose.onAllNodes(titleRow).assertCountEquals(2)
            }
            library.remove(info.id).join()
        } finally {
            try {
                try {
                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                        createdKeys.forEach { learning.removeBookmark(it); learning.removeHistory(it) }
                    }
                } finally {
                    library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
                }
            } finally {
                try {
                    assertTrue(prefs.edit().apply {
                        oldPrefs.forEach { (key, value) -> putString(key, value) }
                    }.commit())
                } finally {
                    compressed.delete()
                }
            }
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                learningBefore?.let { assertEquals(it, learning.data) }
            }
            assertEquals(oldPrefs, lastKeys.associateWith { prefs.getString(it, null) })
        }
    }

    @Test fun quizPoolReplacementClearsOldAnswerAndKeepsRoundProgress() {
        val oldWords = listOf(
            SavedWord("old-cat", "cat", "English", "language", "Old cat clue"),
            SavedWord("old-dog", "dog", "English", "language", "Old dog clue"),
        )
        val newWords = listOf(
            SavedWord("new-bird", "bird", "English", "language", "New bird clue"),
            SavedWord("new-fish", "fish", "English", "language", "New fish clue"),
        )
        val pool = mutableStateOf(oldWords)
        val answers = mutableListOf<Pair<String, Boolean>>()
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent { androidx.compose.material3.MaterialTheme {
                QuizGame(pool.value, 3, onAnswer = { key, right -> answers += key to right })
            } }
        }
        fun currentQuestion(words: List<SavedWord>): SavedWord = words.single {
            compose.onAllNodesWithText(it.clue).fetchSemanticsNodes().isNotEmpty()
        }
        val oldQuestion = currentQuestion(oldWords)
        compose.onNodeWithText(oldQuestion.title).assertIsEnabled().performClick()
        compose.onNodeWithText("Correct.").assertIsDisplayed()
        oldWords.forEach { compose.onNodeWithText(it.title).assertIsNotEnabled() }
        compose.runOnIdle {
            assertEquals(listOf(oldQuestion.key to true), answers)
            pool.value = newWords
        }
        newWords.forEach { compose.onNodeWithText(it.title).assertIsEnabled() }
        compose.onNodeWithText("Correct.").assertDoesNotExist()
        compose.onNodeWithText("Next").assertDoesNotExist()
        compose.onNodeWithText("1 correct · 1 of 3").assertIsDisplayed()
        val newQuestion = currentQuestion(newWords)
        compose.onNodeWithText(newQuestion.title).performClick()
        compose.onNodeWithText("2 correct · 2 of 3").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf(oldQuestion.key to true, newQuestion.key to true), answers) }
    }

    @Test fun learnCardsRetainModeAndRevealedOwnerAcrossDisposedScreen() {
        val first = SavedWord("return-card-a", "alpha", "English", "language", "First meaning", dictionary = "owner-a")
        val second = SavedWord("return-card-b", "bravo", "English", "language", "Second meaning", dictionary = "owner-b")
        val replacement = SavedWord("return-card-c", "charlie", "English", "language", "Replacement meaning", dictionary = "owner-c")
        val pool = mutableStateOf(listOf(first, second))
        val showLearn = mutableStateOf(true)
        val opened = mutableListOf<SavedWord>()
        val disposals = java.util.concurrent.atomic.AtomicInteger()
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val state = androidx.compose.runtime.saveable.rememberSaveableStateHolder()
                DictTheme("light") { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                    androidx.compose.animation.Crossfade(showLearn.value, label = "learn-return-control") { learning ->
                        if (learning) state.SaveableStateProvider(AppScreen.Learn) {
                            androidx.compose.runtime.DisposableEffect(Unit) { onDispose { disposals.incrementAndGet() } }
                            LearnPanel(pool.value, 3, { _, _ -> error("No rating selected") },
                                { opened += it; showLearn.value = false }, {})
                        } else androidx.compose.material3.Button(onClick = { showLearn.value = true }) {
                            androidx.compose.material3.Text("Return to Learn")
                        }
                    }
                } }
            } }
            compose.onNodeWithText("Cards").performClick()
            val selected = pool.value.single { word ->
                compose.onAllNodesWithText(word.title).fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithText(selected.title).performClick()
            compose.onNodeWithText(selected.clue).assertIsDisplayed()
            compose.onNodeWithText("Read").performClick()
            compose.waitUntil(10000) { disposals.get() == 1 }
            compose.onNodeWithText("Cards").assertDoesNotExist()
            compose.onNodeWithText(selected.clue).assertDoesNotExist()
            // Read may update history metadata; the current pool row remains authoritative.
            val updated = selected.copy(clue = "Current meaning for ${selected.title}", views = selected.views + 1)
            compose.runOnIdle { pool.value = pool.value.map { if (it.key == selected.key) updated else it } }
            compose.onNodeWithText("Return to Learn").performClick()
            compose.onNodeWithText("Cards").assertIsSelected()
            compose.onNodeWithText(updated.title).assertIsDisplayed()
            compose.onNodeWithText(updated.clue).assertIsDisplayed()
            compose.onNodeWithText("Recall the meaning, then tap to reveal.").assertDoesNotExist()
            compose.onNodeWithText("Read").performClick()
            compose.waitUntil(10000) { disposals.get() == 2 }
            compose.runOnIdle {
                assertEquals(listOf(selected, updated), opened)
                pool.value = listOf(replacement)
            }
            compose.onNodeWithText("Return to Learn").performClick()
            compose.onNodeWithText("Cards").assertIsSelected()
            compose.onNodeWithText(replacement.title).assertIsDisplayed()
            compose.onNodeWithText("Recall the meaning, then tap to reveal.").assertIsDisplayed()
            compose.onNodeWithText("Open or bookmark at least two different words first.").assertDoesNotExist()
            compose.onNodeWithText("Read").assertDoesNotExist()
            compose.onNodeWithText(replacement.clue).assertDoesNotExist()
            // Even returning to an earlier owner cannot resurrect its obsolete reveal state.
            compose.runOnIdle { pool.value = listOf(updated) }
            compose.onNodeWithText(updated.title).assertIsDisplayed()
            compose.onNodeWithText("Recall the meaning, then tap to reveal.").assertIsDisplayed()
            compose.onNodeWithText(updated.clue).assertDoesNotExist()
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                primary?.addSuppressed(cleanup) ?: throw cleanup
            }
        }
    }

    @Test fun flashcardPoolReplacementStartsUnrevealedAndUsesCurrentOwner() {
        val oldWord = SavedWord("old-card", "alpha", "English", "language", "Old card meaning")
        val newWord = SavedWord("new-card", "bravo", "English", "language", "New card meaning")
        val pool = mutableStateOf(listOf(oldWord))
        val answers = mutableListOf<Pair<String, Boolean>>()
        val opened = mutableListOf<SavedWord>()
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent { androidx.compose.material3.MaterialTheme {
                Flashcards(pool.value, onOpen = { opened += it }, onAnswer = { key, right -> answers += key to right })
            } }
        }
        compose.onNodeWithText(oldWord.title).performClick()
        compose.onNodeWithText(oldWord.clue).assertIsDisplayed()
        compose.onNodeWithText("Read").assertIsEnabled()
        compose.runOnIdle { pool.value = listOf(newWord) }
        compose.onNodeWithText(newWord.title).assertIsDisplayed()
        compose.onNodeWithText("Recall the meaning, then tap to reveal.").assertIsDisplayed()
        compose.onNodeWithText(oldWord.clue).assertDoesNotExist()
        compose.onNodeWithText(newWord.clue).assertDoesNotExist()
        for (label in listOf("Read", "Again", "Got it")) compose.onNodeWithText(label).assertDoesNotExist()
        compose.onNodeWithText(newWord.title).performClick()
        compose.onNodeWithText(newWord.clue).assertIsDisplayed()
        compose.onNodeWithText("Read").performClick()
        compose.onNodeWithText("Got it").performClick()
        compose.onNodeWithText("Recall the meaning, then tap to reveal.").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(listOf(newWord), opened)
            assertEquals(listOf(newWord.key to true), answers)
        }
    }

    @Test fun scramblePoolReplacementClearsOldGuessAndFeedback() {
        val oldWord = SavedWord("old-scramble", "alpha", "English", "language", "Old scramble clue")
        val newWord = SavedWord("new-scramble", "bravo", "English", "language", "New scramble clue")
        val pool = mutableStateOf(listOf(oldWord))
        val answers = mutableListOf<Pair<String, Boolean>>()
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent { androidx.compose.material3.MaterialTheme {
                ScrambleGame(pool.value, onAnswer = { key, right -> answers += key to right })
            } }
        }
        compose.onNode(hasSetTextAction()).performTextInput("wrong")
        compose.onNodeWithText("Check").performClick()
        compose.onNodeWithText("Answer: alpha").assertIsDisplayed()
        compose.onNodeWithText("Check").assertIsNotEnabled()
        compose.runOnIdle {
            assertEquals(listOf(oldWord.key to false), answers)
            pool.value = listOf(newWord)
        }
        compose.onNodeWithText(newWord.clue).assertIsDisplayed()
        compose.onNode(hasSetTextAction()).assert(androidx.compose.ui.test.SemanticsMatcher.expectValue(
            androidx.compose.ui.semantics.SemanticsProperties.EditableText, androidx.compose.ui.text.AnnotatedString("")))
        compose.onNodeWithText("Answer: alpha").assertDoesNotExist()
        compose.onNodeWithText("Correct.").assertDoesNotExist()
        compose.onNodeWithText("Next").assertDoesNotExist()
        compose.onNodeWithText("Check").assertIsNotEnabled()
        compose.onNode(hasSetTextAction()).performTextInput(newWord.title)
        compose.onNodeWithText("Check").assertIsEnabled().performClick()
        compose.onNodeWithText("Correct.").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf(oldWord.key to false, newWord.key to true), answers) }
    }

    @Test fun scrambleAcceptsCanonicalSpellingsAndReportsMissingAccentsAgainstTheOriginalKey() {
        val words = listOf(
            SavedWord("nfc-composed", "caf\u00e9", "French", "language", "Composed accent clue"),
            SavedWord("nfc-decomposed", "cafe\u0301", "French", "language", "Decomposed accent clue"),
        )
        val pool = mutableStateOf(listOf(words.first()))
        val answers = mutableListOf<Pair<String, Boolean>>()
        val expected = mutableListOf<Pair<String, Boolean>>()
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent { androidx.compose.material3.MaterialTheme {
                ScrambleGame(pool.value, onAnswer = { key, right -> answers += key to right })
            } }
        }
        for ((index, word) in words.withIndex()) {
            compose.runOnIdle { pool.value = listOf(word) }
            compose.onNodeWithText(word.clue).assertIsDisplayed()
            val equivalent = if (index == 0) "  CAFE\u0301  " else "CAF\u00c9"
            for ((guess, correct) in listOf(equivalent to true, "cafe" to false)) {
                compose.onNode(hasSetTextAction()).performTextInput(guess)
                compose.onNodeWithText("Check").performClick()
                compose.onNodeWithText(if (correct) "Correct." else "Answer: ${word.title}").assertIsDisplayed()
                expected += word.key to correct
                compose.runOnIdle {
                    assertEquals(expected, answers)
                    assertEquals(word, pool.value.single())
                }
                compose.onNodeWithText("Next").performClick()
            }
        }
    }

    @Test fun quizNeedsDistinctVisibleWordsAndRecoversWhenPoolChanges() {
        val sameTitle = listOf(
            SavedWord("cat-en", "cat", "English", "language", "English cat clue", dictionary = "en-dictionary", edition = "enwiktionary"),
            SavedWord("cat-fr", "cat", "French", "language", "French cat clue", dictionary = "fr-dictionary", edition = "frwiktionary"),
        )
        val differentWord = SavedWord("dog-en", "dog", "English", "language", "English dog clue", dictionary = "en-dictionary", edition = "enwiktionary")
        val pool = mutableStateOf(sameTitle)
        val answers = mutableListOf<Pair<String, Boolean>>()
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent { androidx.compose.material3.MaterialTheme {
                QuizGame(pool.value, 3, onAnswer = { key, right -> answers += key to right })
            } }
        }
        compose.onNodeWithText("Open or bookmark at least two different words first.").assertIsDisplayed()
        compose.onAllNodes(hasClickAction()).assertCountEquals(0)
        compose.onAllNodesWithText("cat").assertCountEquals(0)
        sameTitle.forEach { compose.onNodeWithText(it.clue).assertDoesNotExist() }
        compose.runOnIdle {
            assertTrue(answers.isEmpty())
            pool.value = sameTitle + differentWord
        }
        compose.onNodeWithText("Open or bookmark at least two different words first.").assertDoesNotExist()
        compose.onAllNodesWithText("cat").assertCountEquals(1)
        compose.onAllNodesWithText("dog").assertCountEquals(1)
        compose.onNodeWithText("cat").assertIsEnabled()
        compose.onNodeWithText("dog").assertIsEnabled()
        val question = (sameTitle + differentWord).single {
            compose.onAllNodesWithText(it.clue).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(question.title).performClick()
        compose.onNodeWithText("Correct.").assertIsDisplayed()
        compose.onNodeWithText("1 correct · 1 of 3").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf(question.key to true), answers) }
    }

    @Test fun quizUniqueTitlesScoreTheDisplayedOwnerAcrossWrongAndRightAnswers() {
        val words = listOf("cat", "dog", "bird").flatMap { title ->
            listOf(
                SavedWord("$title-en", title, "English", "language", "English $title clue", dictionary = "en-dictionary", edition = "enwiktionary"),
                SavedWord("$title-fr", title, "French", "language", "French $title clue", dictionary = "fr-dictionary", edition = "frwiktionary"),
            )
        }
        val answers = mutableListOf<Pair<String, Boolean>>()
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent { androidx.compose.material3.MaterialTheme {
                QuizGame(words, 3, onAnswer = { key, right -> answers += key to right })
            } }
        }
        fun currentQuestion(): SavedWord = words.single {
            compose.onAllNodesWithText(it.clue).fetchSemanticsNodes().isNotEmpty()
        }
        fun assertUniqueEnabledChoices() {
            compose.onAllNodes(hasClickAction()).assertCountEquals(3)
            listOf("cat", "dog", "bird").forEach {
                compose.onAllNodesWithText(it).assertCountEquals(1)
                compose.onNodeWithText(it).assertIsEnabled()
            }
        }
        assertUniqueEnabledChoices()
        val first = currentQuestion()
        val wrongTitle = listOf("cat", "dog", "bird").first { it != first.title }
        compose.onNodeWithText(wrongTitle).performClick()
        compose.onNodeWithText("Answer: " + first.title).assertIsDisplayed()
        compose.onNodeWithText("0 correct · 1 of 3").assertIsDisplayed()
        listOf("cat", "dog", "bird").forEach { compose.onNodeWithText(it).assertIsNotEnabled() }
        compose.runOnIdle { assertEquals(listOf(first.key to false), answers) }
        compose.onNodeWithText("Next").performClick()
        assertUniqueEnabledChoices()
        val second = currentQuestion()
        assertNotEquals(first.key, second.key)
        compose.onNodeWithText(second.title).performClick()
        compose.onNodeWithText("Correct.").assertIsDisplayed()
        compose.onNodeWithText("1 correct · 2 of 3").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf(first.key to false, second.key to true), answers) }
    }


    @Test fun emptyLibraryRootBackFallsThroughAndEnteredLibraryKeepsParent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val learning = LearningStore.get(context)
        val learningBefore = learning.data
        val installed = library.dictionaries.toList()
        assertTrue(installed.isNotEmpty())
        val prefs = context.getSharedPreferences("library", 0)
        val lastKeys = listOf("lastTitle", "lastLanguage", "lastDictionary", "lastRecordKey", "lastContextDictionary", "lastEdition")
        val lastBefore = lastKeys.associateWith { prefs.getString(it, null) }
        val directory = java.nio.file.Files.createTempDirectory(context.cacheDir.toPath(), "qa-empty-back-").toFile()
        data class Backup(val info: DictionaryInfo, val file: java.io.File, val name: String)
        val backups = mutableListOf<Backup>()
        val parentBacks = java.util.concurrent.atomic.AtomicInteger()
        val parent = object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { parentBacks.incrementAndGet() }
        }
        var restored = false
        fun back() {
            compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            compose.waitForIdle()
        }
        try {
            runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                installed.forEach { info ->
                    val owner = when (info.kind) {
                        "language" -> java.security.MessageDigest.getInstance("SHA-256")
                            .digest(info.language.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
                        "alias" -> "aliases"
                        "sign_gloss" -> "sign-gloss"
                        else -> info.kind
                    }
                    val name = if (info.edition.isEmpty()) "" else info.edition + "-" + owner + ".wikblb"
                    assertEquals(info.edition, dictionaryEdition(name))
                    validateDictionaryFilename(name, info.kind, info.language)
                    val copy = java.io.File(directory, info.id + ".wikblb")
                    java.io.File(context.filesDir, "dictionaries/" + info.id + ".wikblb").copyTo(copy)
                    backups += Backup(info, copy, name)
                }
            }

            // With a dictionary, the explicit Library child still returns to Settings,
            // and Back from Settings or search returns to the existing reader.
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithText("Dictionaries").performClick()
            compose.onNodeWithText("On this device").assertIsDisplayed()
            back()
            compose.onNodeWithText("Settings").assertIsDisplayed()
            back()
            compose.onNodeWithTag("entry-scroll").assertExists()
            compose.onNodeWithContentDescription("Dictionary").performClick()
            compose.onNode(hasSetTextAction()).performTextInput("ca")
            back()
            compose.onNodeWithTag("entry-scroll").assertExists()

            // Avoid automatic reader opens while removing a multi-fixture library.
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithText("Dictionaries").performClick()
            runBlocking {
                installed.forEach { info ->
                    library.remove(info.id).join()
                    assertNull(library.error)
                }
            }
            compose.waitUntil(15000) {
                library.dictionaries.isEmpty() &&
                    compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes().isEmpty()
            }
            compose.onNodeWithText("Dictionaries").assertIsDisplayed()
            compose.onNodeWithContentDescription("Import wikblb").assertIsEnabled()

            // Install an owned Activity-level parent before the new real DictApp
            // callback. It records root fallthrough without finishing the test Activity.
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
            compose.runOnIdle {
                compose.activity.onBackPressedDispatcher.addCallback(parent)
                compose.activity.setContent { DictTheme(learning.data.settings.darkMode) {
                    DictApp(library, learning) {}
                } }
            }
            compose.waitForIdle()
            compose.onNodeWithText("Dictionaries").assertIsDisplayed()
            back()
            assertEquals(1, parentBacks.get())
            compose.onNodeWithContentDescription("Dictionary").assertIsSelected()
            compose.onNodeWithText("Dictionaries").assertIsDisplayed()

            // Explicitly entered Library remains a child even when empty.
            // These checks also prove the parent callback does not steal child Back.
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithText("Dictionaries").performClick()
            back()
            compose.onNodeWithText("Settings").assertIsDisplayed()
            assertEquals(1, parentBacks.get())
            back()
            compose.onNodeWithText("Dictionaries").assertIsDisplayed()
            assertEquals(1, parentBacks.get())
            back()
            assertEquals(2, parentBacks.get())
        } finally {
            try {
                compose.runOnIdle {
                    parent.remove()
                    compose.activity.setContent {}
                }
                compose.waitForIdle()
            } finally {
                try {
                    runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                        backups.forEach { backup ->
                            if (library.dictionaries.none { it.id == backup.info.id }) {
                                library.importFile(name = { backup.name }) { backup.file.inputStream() }.join()
                                assertNull(library.error)
                            }
                        }
                        assertEquals(installed.sortedBy { it.id }, library.dictionaries.sortedBy { it.id })
                        restored = true
                    }
                } finally {
                    try {
                        assertTrue(prefs.edit().apply {
                            lastBefore.forEach { (key, value) -> putString(key, value) }
                        }.commit())
                        assertEquals(lastBefore, lastKeys.associateWith { prefs.getString(it, null) })
                        compose.runOnIdle { assertEquals(learningBefore, learning.data) }
                    } finally {
                        // Keep owned recovery copies if fixture restoration itself failed.
                        if (restored) assertTrue(directory.deleteRecursively())
                    }
                }
            }
        }
    }

    @Test fun searchPendingQueriesHideOldRowsAndRejectLateOwners() {
        val first = WordHit("owner-a", "alpha", "English", "language", 0, 4, "record-a")
        val stale = WordHit("owner-b", "beta", "English", "language", 0, 4, "record-b")
        val current = WordHit("owner-c", "gamma", "English", "language", 0, 4, "record-c")
        val query = mutableStateOf("alpha")
        val firstResult = kotlinx.coroutines.CompletableDeferred<List<WordHit>>()
        val staleResult = kotlinx.coroutines.CompletableDeferred<List<WordHit>>()
        val currentResult = kotlinx.coroutines.CompletableDeferred<List<WordHit>>()
        val staleStarted = kotlinx.coroutines.CompletableDeferred<Unit>()
        val staleCancelled = kotlinx.coroutines.CompletableDeferred<Unit>()
        val staleReturned = kotlinx.coroutines.CompletableDeferred<Unit>()
        val opened = mutableListOf<WordHit>()
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { androidx.compose.material3.MaterialTheme {
                    SearchResults(query.value, 1, { text ->
                        when (text) {
                            "alpha" -> firstResult.await()
                            "beta" -> {
                                staleStarted.complete(Unit)
                                val hits = try { staleResult.await() }
                                catch (_: kotlinx.coroutines.CancellationException) {
                                    staleCancelled.complete(Unit)
                                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { staleResult.await() }
                                }
                                staleReturned.complete(Unit)
                                hits
                            }
                            "gamma" -> currentResult.await()
                            else -> error("Unexpected search")
                        }
                    }, { opened += it })
                } }
            }
            compose.onNodeWithText("Searching…").assertIsDisplayed()
            compose.onNodeWithText("No matching words").assertDoesNotExist()
            firstResult.complete(listOf(first))
            compose.waitUntil(10000) { compose.onAllNodesWithText("alpha").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("alpha").performClick()
            compose.runOnIdle { assertEquals(listOf(first), opened); query.value = "beta" }
            compose.waitUntil(10000) { staleStarted.isCompleted }
            compose.onNodeWithText("Searching…").assertIsDisplayed()
            compose.onNodeWithText("alpha").assertDoesNotExist()
            compose.onNodeWithText("No matching words").assertDoesNotExist()
            compose.runOnIdle { query.value = "gamma" }
            compose.waitUntil(10000) { staleCancelled.isCompleted }
            currentResult.complete(listOf(current))
            compose.waitUntil(10000) { compose.onAllNodesWithText("gamma").fetchSemanticsNodes().isNotEmpty() }
            staleResult.complete(listOf(stale))
            compose.waitUntil(10000) { staleReturned.isCompleted }
            compose.waitForIdle()
            compose.onNodeWithText("beta").assertDoesNotExist()
            compose.onNodeWithText("alpha").assertDoesNotExist()
            compose.onNodeWithText("Unable to search dictionaries. Try again.").assertDoesNotExist()
            compose.onNodeWithText("gamma").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(listOf(first, current), opened) }
        } finally {
            firstResult.complete(emptyList())
            staleResult.complete(emptyList())
            currentResult.complete(emptyList())
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun searchFailureRetryRevisionAndCancellationHaveDistinctRenderedStates() {
        val query = mutableStateOf("same")
        val revision = mutableStateOf(1)
        val calls = java.util.concurrent.atomic.AtomicInteger()
        val failure = kotlinx.coroutines.CompletableDeferred<List<WordHit>>()
        val retry = kotlinx.coroutines.CompletableDeferred<List<WordHit>>()
        val revised = kotlinx.coroutines.CompletableDeferred<List<WordHit>>()
        val cancelled = kotlinx.coroutines.CompletableDeferred<List<WordHit>>()
        val cancelledStarted = kotlinx.coroutines.CompletableDeferred<Unit>()
        val cancellationObserved = kotlinx.coroutines.CompletableDeferred<Unit>()
        val finalResult = kotlinx.coroutines.CompletableDeferred<List<WordHit>>()
        val revisedHit = WordHit("revision-owner", "same", "English", "language", 0, 4, "revision-record")
        val finalHit = WordHit("final-owner", "final", "English", "language", 0, 4, "final-record")
        val opened = mutableListOf<WordHit>()
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { androidx.compose.material3.MaterialTheme {
                    SearchResults(query.value, revision.value, { text ->
                        when (text) {
                            "same" -> when (calls.incrementAndGet()) {
                                1 -> failure.await()
                                2 -> retry.await()
                                3 -> revised.await()
                                else -> error("Unexpected retry")
                            }
                            "cancelled" -> {
                                cancelledStarted.complete(Unit)
                                try { cancelled.await() }
                                catch (error: kotlinx.coroutines.CancellationException) {
                                    cancellationObserved.complete(Unit)
                                    throw error
                                }
                            }
                            "final" -> finalResult.await()
                            else -> error("Unexpected search")
                        }
                    }, { opened += it })
                } }
            }
            compose.onNodeWithText("Searching…").assertIsDisplayed()
            compose.onNodeWithText("No matching words").assertDoesNotExist()
            failure.completeExceptionally(java.io.IOException("Controlled unavailable index"))
            compose.waitUntil(10000) { compose.onAllNodesWithText("Retry search").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Unable to search dictionaries. Try again.").assertIsDisplayed()
            compose.onNodeWithText("No matching words").assertDoesNotExist()
            compose.onNodeWithText("Retry search").assertIsEnabled().performClick()
            compose.onNodeWithText("Searching…").assertIsDisplayed()
            compose.onNodeWithText("Unable to search dictionaries. Try again.").assertDoesNotExist()
            retry.complete(emptyList())
            compose.waitUntil(10000) { compose.onAllNodesWithText("No matching words").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Searching…").assertDoesNotExist()
            compose.runOnIdle { revision.value++ }
            compose.onNodeWithText("Searching…").assertIsDisplayed()
            compose.onNodeWithText("No matching words").assertDoesNotExist()
            revised.complete(listOf(revisedHit))
            compose.waitUntil(10000) { compose.onAllNodesWithText("same").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("same").performClick()
            compose.runOnIdle { assertEquals(3, calls.get()); query.value = "cancelled" }
            compose.waitUntil(10000) { cancelledStarted.isCompleted }
            compose.onNodeWithText("same").assertDoesNotExist()
            compose.runOnIdle { query.value = "final" }
            compose.waitUntil(10000) { cancellationObserved.isCompleted }
            compose.onNodeWithText("Searching…").assertIsDisplayed()
            compose.onNodeWithText("Unable to search dictionaries. Try again.").assertDoesNotExist()
            finalResult.complete(listOf(finalHit))
            compose.waitUntil(10000) { compose.onAllNodesWithText("final").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("final").performClick()
            compose.runOnIdle { assertEquals(listOf(revisedHit, finalHit), opened) }
        } finally {
            listOf(failure, retry, revised, cancelled, finalResult).forEach { it.complete(emptyList()) }
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun learnSamplingFailureRetryAndEmptyHaveDistinctRenderedStates() {
        val failure = kotlinx.coroutines.CompletableDeferred<List<Entry>>()
        val retry = kotlinx.coroutines.CompletableDeferred<List<Entry>>()
        val calls = java.util.concurrent.atomic.AtomicInteger()
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { androidx.compose.material3.MaterialTheme {
                    LearnResults(1, "all", {
                        when (calls.incrementAndGet()) {
                            1 -> failure.await()
                            2 -> retry.await()
                            else -> error("Unexpected sample")
                        }
                    }) { entries, pending, failed, again ->
                        assertTrue(entries.isEmpty())
                        LearnPanel(emptyList(), 3, { _, _ -> error("No sampled answer") },
                            { error("No sampled word") }, {}, pending, failed, again)
                    }
                } }
            }
            compose.onNodeWithText("Loading dictionary words…").assertIsDisplayed()
            compose.onNodeWithText("0 words to explore").assertDoesNotExist()
            compose.onNodeWithText("Open or bookmark at least two different words first.").assertDoesNotExist()
            failure.completeExceptionally(java.io.IOException("Controlled sample unavailable"))
            compose.waitUntil(10000) { compose.onAllNodesWithText("Retry words").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Unable to load dictionary words. Try again.").assertIsDisplayed()
            compose.onNodeWithText("Open or bookmark at least two different words first.").assertDoesNotExist()
            compose.onNodeWithText("Retry words").assertIsEnabled().performClick()
            compose.onNodeWithText("Loading dictionary words…").assertIsDisplayed()
            compose.onNodeWithText("Unable to load dictionary words. Try again.").assertDoesNotExist()
            retry.complete(emptyList())
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Open or bookmark at least two different words first.").fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithText("0 words to explore").assertIsDisplayed()
            compose.onNodeWithText("Loading dictionary words…").assertDoesNotExist()
            compose.onNodeWithText("Cards").performClick()
            compose.onNodeWithText("Open or bookmark some words first.").assertIsDisplayed()
            compose.onNodeWithText("Scramble").performClick()
            compose.onNodeWithText("Add a few longer words first.").assertIsDisplayed()
            compose.runOnIdle { assertEquals(2, calls.get()) }
        } finally {
            failure.complete(emptyList()); retry.complete(emptyList())
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun learnSamplingRevisionRejectsLateOwnersAndPreservesRoundProgress() {
        fun entry(title: String, owner: String) = Entry(title, emptyList(), "language", "English", "en",
            listOf(Section(2, "Noun", listOf(Block("definition", 1, listOf(Span("text", "$owner meaning")))))),
            emptyList(), origin = WordHit(owner, title, "English", "language", 0, 4, "$owner-record"))
        fun word(entry: Entry) = SavedWord(entry.key, entry.title, entry.language, entry.kind, entry.clue(),
            dictionary = entry.origin!!.dictionary, recordKey = entry.origin.recordKey)
        val old = listOf(entry("alpha", "old-a"), entry("bravo", "old-b"))
        val stale = listOf(entry("stale", "stale-a"), entry("ghost", "stale-b"))
        val current = listOf(entry("charlie", "current-a"), entry("delta", "current-b"))
        val revision = mutableStateOf(1)
        val first = kotlinx.coroutines.CompletableDeferred<List<Entry>>()
        val late = kotlinx.coroutines.CompletableDeferred<List<Entry>>()
        val latest = kotlinx.coroutines.CompletableDeferred<List<Entry>>()
        val lateStarted = kotlinx.coroutines.CompletableDeferred<Unit>()
        val lateCancelled = kotlinx.coroutines.CompletableDeferred<Unit>()
        val lateReturned = kotlinx.coroutines.CompletableDeferred<Unit>()
        val answers = mutableListOf<Pair<String, Boolean>>()
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { androidx.compose.material3.MaterialTheme {
                    val version = revision.value
                    LearnResults(version, "all", {
                        when (version) {
                            1 -> first.await()
                            2 -> {
                                lateStarted.complete(Unit)
                                val entries = try { late.await() }
                                catch (_: kotlinx.coroutines.CancellationException) {
                                    lateCancelled.complete(Unit)
                                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { late.await() }
                                }
                                lateReturned.complete(Unit)
                                entries
                            }
                            3 -> latest.await()
                            else -> error("Unexpected revision")
                        }
                    }) { entries, pending, failed, again ->
                        LearnPanel(entries.map(::word), 3, { key, right -> answers += key to right },
                            {}, {}, pending, failed, again)
                    }
                } }
            }
            first.complete(old)
            compose.waitUntil(10000) { compose.onAllNodesWithText("alpha").fetchSemanticsNodes().isNotEmpty() }
            val oldQuestion = old.single { compose.onAllNodesWithText(it.clue()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(oldQuestion.title).performClick()
            compose.onNodeWithText("1 correct · 1 of 3").assertIsDisplayed()
            compose.runOnIdle { revision.value = 2 }
            compose.waitUntil(10000) { lateStarted.isCompleted }
            compose.onNodeWithText("Loading dictionary words…").assertIsDisplayed()
            old.forEach { compose.onNodeWithText(it.title).assertDoesNotExist() }
            compose.onNodeWithText("Open or bookmark at least two different words first.").assertDoesNotExist()
            compose.runOnIdle { revision.value = 3 }
            compose.waitUntil(10000) { lateCancelled.isCompleted }
            latest.complete(current)
            compose.waitUntil(10000) { compose.onAllNodesWithText("charlie").fetchSemanticsNodes().isNotEmpty() }
            late.complete(stale)
            compose.waitUntil(10000) { lateReturned.isCompleted }
            compose.waitForIdle()
            stale.forEach { compose.onNodeWithText(it.title).assertDoesNotExist() }
            compose.onNodeWithText("1 correct · 1 of 3").assertIsDisplayed()
            compose.onNodeWithText("Correct.").assertDoesNotExist()
            compose.onNodeWithText("Next").assertDoesNotExist()
            current.forEach { compose.onNodeWithText(it.title).assertIsEnabled() }
            val question = current.single { compose.onAllNodesWithText(it.clue()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(question.title).performClick()
            compose.onNodeWithText("2 correct · 2 of 3").assertIsDisplayed()
            compose.runOnIdle {
                assertEquals(listOf(oldQuestion.key to true, question.key to true), answers)
            }
        } finally {
            listOf(first, late, latest).forEach { it.complete(emptyList()) }
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun learnLocalPoolsRemainPlayableAndCancelOptionalSampling() {
        val bookmarked = listOf(
            SavedWord("saved-a", "alpha", "English", "language", "Saved alpha meaning", dictionary = "saved-owner-a"),
            SavedWord("saved-b", "bravo", "English", "language", "Saved bravo meaning", dictionary = "saved-owner-b"),
        )
        val history = SavedWord("history-c", "charlie", "English", "language", "History charlie meaning", dictionary = "history-owner")
        val source = mutableStateOf("all")
        val local = mutableStateOf(bookmarked)
        val pending = kotlinx.coroutines.CompletableDeferred<List<Entry>>()
        val retried = kotlinx.coroutines.CompletableDeferred<List<Entry>>()
        val cancelled = kotlinx.coroutines.CompletableDeferred<Unit>()
        val calls = java.util.concurrent.atomic.AtomicInteger()
        val answers = mutableListOf<Pair<String, Boolean>>()
        val opened = mutableListOf<SavedWord>()
        var randoms = 0
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { androidx.compose.material3.MaterialTheme {
                    LearnResults(1, source.value, {
                        when (calls.incrementAndGet()) {
                            1 -> pending.await()
                            2 -> try { retried.await() }
                                catch (error: kotlinx.coroutines.CancellationException) {
                                    cancelled.complete(Unit); throw error
                                }
                            else -> error("Saved/history pools must not sample")
                        }
                    }) { entries, loading, failed, retry ->
                        assertTrue(entries.isEmpty())
                        LearnPanel(local.value, 3, { key, right -> answers += key to right },
                            { opened += it }, { randoms++ }, loading, failed, retry)
                    }
                } }
            }
            compose.onNodeWithText("Loading dictionary words…").assertIsDisplayed()
            val question = bookmarked.single { compose.onAllNodesWithText(it.clue).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(question.title).assertIsEnabled().performClick()
            compose.onNodeWithText("1 correct · 1 of 3").assertIsDisplayed()
            pending.completeExceptionally(java.io.IOException("Optional random source unavailable"))
            compose.waitUntil(10000) { compose.onAllNodesWithText("Retry words").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Correct.").assertIsDisplayed()
            compose.onNodeWithText("1 correct · 1 of 3").assertIsDisplayed()
            compose.onNodeWithText("Retry words").performClick()
            compose.waitUntil(10000) { calls.get() == 2 }
            compose.runOnIdle { source.value = "bookmarks" }
            compose.waitUntil(10000) { cancelled.isCompleted }
            compose.onNodeWithText("Loading dictionary words…").assertDoesNotExist()
            compose.onNodeWithText("Retry words").assertDoesNotExist()
            compose.onNodeWithText("1 correct · 1 of 3").assertIsDisplayed()
            compose.onNodeWithText("Cards").performClick()
            val card = bookmarked.single { compose.onAllNodesWithText(it.title).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(card.title).performClick()
            compose.onNodeWithText("Read").performClick()
            compose.runOnIdle { source.value = "history"; local.value = listOf(history) }
            compose.onNodeWithText(history.title).assertIsDisplayed().performClick()
            compose.onNodeWithText(history.clue).assertIsDisplayed()
            compose.onNodeWithText("Read").performClick()
            compose.onNodeWithContentDescription("Random word").performClick()
            compose.runOnIdle {
                assertEquals(2, calls.get())
                assertEquals(listOf(question.key to true), answers)
                assertEquals(listOf(card, history), opened)
                assertEquals(1, randoms)
                local.value = emptyList()
            }
            compose.onNodeWithText("Open or bookmark some words first.").assertIsDisplayed()
            compose.onNodeWithText("0 words to explore").assertIsDisplayed()
            compose.onNodeWithText("Loading dictionary words…").assertDoesNotExist()
            compose.onNodeWithText("Retry words").assertDoesNotExist()
        } finally {
            pending.complete(emptyList()); retried.complete(emptyList())
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }


    @Test fun searchFieldKeepsAccessibleNameForEmptyAndPopulatedQuery() {
        val namedField = hasContentDescription("Find a word") and hasSetTextAction()
        val learning = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext)
        val inputModeManager = java.util.concurrent.atomic.AtomicReference<androidx.compose.ui.input.InputModeManager?>()
        var beforeTab = "not reached"
        fun ownedFocusEvidence(): String {
            val targets = listOf("field" to namedField,
                "clear" to hasContentDescription("Clear search"),
                "close" to hasContentDescription("Close search"))
                .joinToString { (label, matcher) ->
                    val ids = compose.onAllNodes(matcher, useUnmergedTree = true)
                        .fetchSemanticsNodes(atLeastOneRootRequired = false).take(8).map { it.id }
                    "$label=$ids"
                }
            val focused = compose.onAllNodes(isFocused(), useUnmergedTree = true)
                .fetchSemanticsNodes(atLeastOneRootRequired = false).take(16).joinToString { node ->
                    "id=${node.id},role=${node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Role)}," +
                        "editable=${node.config.getOrNull(androidx.compose.ui.semantics.SemanticsActions.SetText) != null}," +
                        "bounds=${node.boundsInRoot}"
                }
            var ownedWindow = "unavailable"
            compose.runOnIdle {
                val activity = compose.activity
                val decor = activity.window.decorView
                ownedWindow = "inputMode=${inputModeManager.get()?.inputMode},touchMode=${decor.isInTouchMode}," +
                    "activityFocus=${activity.hasWindowFocus()},decorFocus=${decor.hasWindowFocus()}"
            }
            return "targets={$targets};focused=[$focused];$ownedWindow"
        }
        fun assertField(value: String) {
            compose.onAllNodes(namedField).assertCountEquals(1)
            compose.onNode(namedField).assertIsDisplayed().assertIsFocused()
                .assert(SemanticsMatcher.expectValue(
                    androidx.compose.ui.semantics.SemanticsProperties.EditableText,
                    androidx.compose.ui.text.AnnotatedString(value),
                ))
        }
        try {
            // Capture the public manager around the same production app and store owners.
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val manager = androidx.compose.ui.platform.LocalInputModeManager.current
                SideEffect { inputModeManager.set(manager) }
                DictTheme(learning.data.settings.darkMode) { DictApp(library, learning) {} }
            } }
            compose.waitUntil(15000) {
                compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onNodeWithContentDescription("Dictionary").performClick()
            assertField("")
            compose.onNode(namedField).performTextInput("ca")
            assertField("ca")
            // System-defined focusability requires the platform keyboard mode first.
            val manager = checkNotNull(inputModeManager.get())
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                assertTrue(compose.activity.hasWindowFocus() && compose.activity.window.decorView.hasWindowFocus())
                val before = manager.inputMode
                val accepted = manager.requestInputMode(androidx.compose.ui.input.InputMode.Keyboard)
                android.util.Log.i("TestRunner", "OWNED_SEARCH_INPUT_MODE before=$before accepted=$accepted after=${manager.inputMode}")
                assertTrue("The platform must accept keyboard input mode", accepted)
            }
            compose.waitUntil(10000) { manager.inputMode == androidx.compose.ui.input.InputMode.Keyboard }
            compose.runOnIdle { assertEquals(androidx.compose.ui.input.InputMode.Keyboard, manager.inputMode) }
            beforeTab = ownedFocusEvidence()
            // Keyboard activation gives Clear its own focus before it removes itself.
            compose.onNode(namedField).performKeyInput {
                keyDown(androidx.compose.ui.input.key.Key.Tab); keyUp(androidx.compose.ui.input.key.Key.Tab)
            }
            compose.onNodeWithContentDescription("Clear search").assertIsFocused().performKeyInput {
                keyDown(androidx.compose.ui.input.key.Key.Enter); keyUp(androidx.compose.ui.input.key.Key.Enter)
            }
            assertField("")
            compose.onNode(namedField).performTextInput("ca")
            assertField("ca")
            compose.onNodeWithContentDescription("Clear search").performClick()
            assertField("")
            compose.onNodeWithContentDescription("Close search").performClick()
            compose.onNodeWithTag("entry-scroll").assertExists()
            compose.onAllNodes(namedField).assertCountEquals(0)
        } catch (failure: AssertionError) {
            val afterFailure = runCatching { ownedFocusEvidence() }
                .getOrElse { "unavailable:${it.javaClass.simpleName}" }
            // IDs, roles and geometry only: no query text, dictionary text or foreign windows.
            failure.addSuppressed(AssertionError("OWNED_SEARCH_FOCUS beforeTab={$beforeTab};afterFailure={$afterFailure}"))
            throw failure
        } finally {
            if (compose.onAllNodesWithContentDescription("Close search")
                    .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()) {
                compose.onNodeWithContentDescription("Close search").performClick()
            }
        }
    }

    private val largeTextDensity = java.util.concurrent.atomic.AtomicReference<Density?>()

    @Composable
    private fun LargeTextViewport(mode: String, content: @Composable () -> Unit) {
        val base = LocalDensity.current
        val local = Density(base.density, fontScale = 2f)
        SideEffect { largeTextDensity.set(local) }
        CompositionLocalProvider(LocalDensity provides local) {
            DictTheme(mode) {
                Box(Modifier.width(320.dp).height(480.dp).clipToBounds().testTag("large-text-viewport")) {
                    content()
                }
            }
        }
    }

    private fun assertLargeTextViewport(): androidx.compose.ui.geometry.Rect {
        val node = compose.onNodeWithTag("large-text-viewport").assertIsDisplayed().fetchSemanticsNode()
        val density = checkNotNull(largeTextDensity.get())
        assertEquals(2f, density.fontScale, 0f)
        val bounds = androidx.compose.ui.geometry.Rect(
            node.positionInRoot,
            androidx.compose.ui.geometry.Size(node.size.width.toFloat(), node.size.height.toFloat()),
        )
        // The real activity may constrain height further while the IME is visible.
        assertTrue(bounds.width > 0f && bounds.width <= with(density) { 320.dp.toPx() } + 1f)
        assertTrue(bounds.height > 0f && bounds.height <= with(density) { 480.dp.toPx() } + 1f)
        return bounds
    }

    private fun assertLargeTextLayout(node: SemanticsNodeInteraction, scroll: Boolean = false, imageName: String? = null, plainText: String? = null) {
        val viewportNode = compose.onNodeWithTag("large-text-viewport")
        withRenderedLayoutFailureEvidence("large-text", node, viewportNode, imageName, {
            var state = ""
            compose.runOnIdle { state = ownedLayoutState(compose.activity.window.decorView) }
            state
        }) {
        if (scroll) node.performScrollTo()
        node.assertIsDisplayed()
        val semantic = node.fetchSemanticsNode()
        val viewport = assertLargeTextViewport()
        val raw = androidx.compose.ui.geometry.Rect(
            semantic.positionInRoot,
            androidx.compose.ui.geometry.Size(semantic.size.width.toFloat(), semantic.size.height.toFloat()),
        )
        assertTrue("Text must have positive visible area: $raw", raw.width > 0f && raw.height > 0f)
        assertTrue("Text must fit the viewport horizontally: $raw in $viewport",
            raw.left >= viewport.left - 1f && raw.right <= viewport.right + 1f)
        assertTrue("Scroll must expose the full text vertically: $raw in $viewport",
            raw.top >= viewport.top - 1f && raw.bottom <= viewport.bottom + 1f)
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertEquals("Inspect the actual rendered text, not just clipped semantics bounds", 1, layouts.size)
        val layout = layouts.single()
        assertEquals(2f, layout.layoutInput.density.fontScale, 0f)
        if (plainText == null) {
            assertFalse("Large text must not be truncated or overflow its measured layout", layout.hasVisualOverflow)
        } else {
            assertCompletePlainTextLayout(layout, plainText)
        }
        assertTrue(layout.size.width <= semantic.size.width + 1 && layout.size.height <= semantic.size.height + 1)
        }
    }


    private fun clickLargeTextAction(label: String) {
        val action = compose.onNode(hasText(label) and hasClickAction())
        action.performScrollTo().assertIsDisplayed().assertIsEnabled()
        assertLargeTextLayout(compose.onNodeWithText(label, useUnmergedTree = true), plainText = label)
        // Exercise hit testing after verifying the visible action, not a hidden semantics callback.
        action.performTouchInput { click(center) }
    }

    @Test fun largeTextLearnFeedbackKeepsNextReachableForLongAnswers() {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        val words = listOf(
            SavedWord("large-en", "a very long English answer العربية", "English", "language", "First owner clue"),
            SavedWord("large-ja", "another long entry 日本語 with detail", "Japanese", "language", "Second owner clue"),
        )
        val answers = mutableListOf<Pair<String, Boolean>>()
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { LargeTextViewport(mode) {
                    LearnPanel(words, 3, { key, right -> answers += key to right }, {}, {})
                } }
            }
            assertLargeTextViewport()
            val question = words.single {
                compose.onAllNodesWithText(it.clue).fetchSemanticsNodes().isNotEmpty()
            }
            val wrong = words.single { it.key != question.key }
            compose.onNodeWithText(wrong.title).performScrollTo().assertIsDisplayed().performClick()
            compose.runOnIdle { assertEquals(listOf(question.key to false), answers) }
            assertLargeTextLayout(compose.onNodeWithText("Answer: " + question.title, useUnmergedTree = true), scroll = true)
            clickLargeTextAction("Next")
            compose.onNodeWithText("Answer: " + question.title).assertDoesNotExist()
            compose.onNodeWithText(wrong.clue).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("0 correct · 1 of 3").performScrollTo().assertIsDisplayed()

            compose.onNodeWithText("Scramble").performScrollTo().assertIsDisplayed().performClick()
            val scrambled = words.single {
                compose.onAllNodesWithText(it.clue).fetchSemanticsNodes().isNotEmpty()
            }
            val input = compose.onNode(hasSetTextAction())
            input.performScrollTo().assertIsDisplayed().performTextInput("wrong")
            input.assertIsFocused()
            clickLargeTextAction("Check")
            compose.runOnIdle {
                assertEquals(listOf(question.key to false, scrambled.key to false), answers)
            }
            assertLargeTextLayout(compose.onNodeWithText("Answer: " + scrambled.title, useUnmergedTree = true), scroll = true)
            clickLargeTextAction("Next")
            compose.onNodeWithText("Answer: " + scrambled.title).assertDoesNotExist()
            compose.onNodeWithText(words.single { it.key != scrambled.key }.clue).performScrollTo().assertIsDisplayed()
            compose.onNode(hasSetTextAction()).assert(SemanticsMatcher.expectValue(
                androidx.compose.ui.semantics.SemanticsProperties.EditableText,
                androidx.compose.ui.text.AnnotatedString(""),
            ))
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun largeTextSearchKeepsNamedFieldFocusedAndControlsVisible() {
        val learning = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext)
        val field = hasContentDescription("Find a word") and hasSetTextAction()
        fun captureState(name: String) {
            compose.waitForIdle()
            assertLargeTextViewport()
            val viewport = compose.onNodeWithTag("large-text-viewport").assertIsDisplayed()
            val evidence = renderedLayoutFailureEvidence(
                "large-text success; density=${largeTextDensity.get()}", null,
                viewport.fetchSemanticsNode(), viewport, name,
            )
            assertTrue(evidence, evidence.contains("\nOWNED_PNG_FILE $name "))
            android.util.Log.i("OwnedLargeTextEvidence", evidence)
        }
        fun assertField(value: String) {
            val input = compose.onNode(field)
            withRenderedLayoutFailureEvidence("search focus/value", input, compose.onNodeWithTag("large-text-viewport"), "search-large-text", {
                var state = ""
                compose.runOnIdle { state = ownedLayoutState(compose.activity.window.decorView) }
                state
            }) {
                compose.onAllNodes(field).assertCountEquals(1)
                input.assertIsDisplayed().assertIsFocused().assert(SemanticsMatcher.expectValue(
                    androidx.compose.ui.semantics.SemanticsProperties.EditableText,
                    androidx.compose.ui.text.AnnotatedString(value),
                ))
            }
            assertLargeTextLayout(input, imageName = "search-large-text")
            val viewport = assertLargeTextViewport()
            for (description in if (value.isEmpty()) listOf("Close search") else listOf("Close search", "Clear search")) {
                val action = compose.onNodeWithContentDescription(description).assertIsDisplayed().assertIsEnabled()
                val node = action.fetchSemanticsNode()
                val raw = androidx.compose.ui.geometry.Rect(node.positionInRoot,
                    androidx.compose.ui.geometry.Size(node.size.width.toFloat(), node.size.height.toFloat()))
                assertTrue("Search action must be visibly reachable: $description $raw in $viewport",
                    raw.width > 0f && raw.height > 0f &&
                    raw.left >= viewport.left - 1f && raw.right <= viewport.right + 1f &&
                    raw.top >= viewport.top - 1f && raw.bottom <= viewport.bottom + 1f)
            }
        }
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent { LargeTextViewport(learning.data.settings.darkMode) {
                    DictApp(library, learning) {}
                } }
            }
            compose.waitUntil(15000) {
                compose.onAllNodesWithTag("entry-scroll").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onNodeWithContentDescription("Dictionary").assertIsDisplayed().performClick()
            assertField("")
            assertLargeTextLayout(compose.onNodeWithText("Find a word…", useUnmergedTree = true), imageName = "search-large-text", plainText = "Find a word…")
            compose.onNode(field).performTextInput("cat")
            assertField("cat")
            captureState("search-large-text.png")
            compose.onNodeWithContentDescription("Clear search").performTouchInput { click(center) }
            assertField("")
            compose.onNodeWithContentDescription("Close search").performTouchInput { click(center) }
            compose.onAllNodes(field).assertCountEquals(0)
            compose.onNodeWithTag("entry-scroll").assertExists()
            captureState("search-large-text-recovered.png")
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    private val retentionFocus = java.util.concurrent.atomic.AtomicReference<FocusRequester?>()

    private fun mountLearnRetentionPanel(
        words: List<SavedWord>,
        answers: MutableList<Pair<String, Boolean>>,
        opened: MutableList<SavedWord> = mutableListOf(),
    ) {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent {
                val density = LocalDensity.current
                val focus = remember { FocusRequester() }
                SideEffect { retentionFocus.set(focus) }
                CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 1f)) {
                    DictTheme(mode) {
                        Column {
                            // Park focus outside the game in either platform input mode.
                            Box(Modifier.size(1.dp).testTag("learn-retention-focus-target")
                                .focusRequester(focus).focusable())
                            Box(Modifier.width(320.dp).height(120.dp).clipToBounds().testTag("learn-retention-viewport")) {
                                // Real status/segments precede the game and can completely fill this short viewport.
                                LearnPanel(words, 3, { key, right -> answers += key to right }, { opened += it }, {},
                                    sampleFailed = true)
                            }
                        }
                    }
                }
            }
        }
        compose.waitForIdle()
    }

    private fun scrollLearnRetentionToEdge(top: Boolean) {
        val scroll = compose.onNode(SemanticsMatcher.keyIsDefined(
            androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange))
        // Real drags and observed scroll progress, not sleeps or a substituted game composition.
        repeat(24) {
            val before = scroll.fetchSemanticsNode().config[
                androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
            scroll.performTouchInput { if (top) swipeDown(durationMillis = 200) else swipeUp(durationMillis = 200) }
            compose.waitForIdle()
            val after = scroll.fetchSemanticsNode().config[
                androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
            if (after == before) return
        }
        fail("Learn scroll did not reach its edge")
    }


    private fun selectLearnRetentionGame(label: String) {
        scrollLearnRetentionToEdge(top = true)
        val scroll = compose.onNode(SemanticsMatcher.keyIsDefined(
            androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange))
        repeat(24) {
            if (compose.onAllNodesWithText(label).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()) {
                compose.onNodeWithText(label).performScrollTo().assertIsDisplayed().performClick()
                return
            }
            scroll.performTouchInput { swipeUp(durationMillis = 200) }
            compose.waitForIdle()
        }
        fail("Learn game tab was not reachable: " + label)
    }

    private fun hideUnfocusedLearnGame(text: String) {
        compose.runOnIdle { assertTrue(checkNotNull(retentionFocus.get()).requestFocus()) }
        compose.onNodeWithTag("learn-retention-focus-target").assertIsFocused()
        compose.onAllNodes(isFocused() and hasAnyAncestor(hasTestTag("learn-retention-viewport"))).assertCountEquals(0)
        val scroll = compose.onNode(SemanticsMatcher.keyIsDefined(
            androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange))
        val before = scroll.fetchSemanticsNode().config[
            androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
        scrollLearnRetentionToEdge(top = true)
        compose.onNodeWithText("Learn", useUnmergedTree = true).assertIsDisplayed()
        val after = scroll.fetchSemanticsNode().config[
            androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value()
        assertTrue("The answered/revealed/edited game must actually scroll away", after < before)
        val viewport = compose.onNodeWithTag("learn-retention-viewport").fetchSemanticsNode()
        val top = viewport.positionInRoot.y
        val bottom = top + viewport.size.height
        // The tab row precedes the entire game. Its actual position must also be
        // below the viewport, so hiding only the game's final feedback cannot pass.
        compose.onAllNodesWithText("Quiz", useUnmergedTree = true)
            .fetchSemanticsNodes(atLeastOneRootRequired = false).forEach { node ->
                assertTrue("The whole game must be below its offscreen tab row",
                    node.positionInRoot.y >= bottom)
            }
        compose.onAllNodesWithText(text, useUnmergedTree = true)
            .fetchSemanticsNodes(atLeastOneRootRequired = false).forEach { node ->
                val nodeTop = node.positionInRoot.y
                assertTrue("Game content must be fully outside the viewport",
                    nodeTop >= bottom || nodeTop + node.size.height <= top)
            }
        // A lazy predecessor may have disposed the node; the expected state must still return below.
        scrollLearnRetentionToEdge(top = false)
    }

    @Test fun quizRoundAndAnsweredOwnerSurviveUnfocusedOffscreenScroll() {
        val words = listOf(
            SavedWord("quiz-scroll-a", "quartz", "English", "language", "Quartz owner clue"),
            SavedWord("quiz-scroll-b", "zephyr", "English", "language", "Zephyr owner clue"),
        )
        val answers = mutableListOf<Pair<String, Boolean>>()
        try {
            mountLearnRetentionPanel(words, answers)
            scrollLearnRetentionToEdge(top = false)
            val question = words.single { compose.onAllNodesWithText(it.clue).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(question.title).performScrollTo().assertIsDisplayed().performClick()
            compose.onNodeWithText("Correct.").performScrollTo().assertIsDisplayed()
            compose.runOnIdle { assertEquals(listOf(question.key to true), answers) }
            hideUnfocusedLearnGame("Correct.")
            compose.onNodeWithText(question.clue).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("1 correct · 1 of 3").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Correct.").performScrollTo().assertIsDisplayed()
            words.forEach { compose.onNodeWithText(it.title).assertIsNotEnabled() }
            compose.onNodeWithText("Next").performScrollTo().assertIsDisplayed().performClick()
            compose.onNodeWithText(words.single { it.key != question.key }.clue).performScrollTo().assertIsDisplayed()
            compose.runOnIdle { assertEquals(listOf(question.key to true), answers) }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
            retentionFocus.set(null)
        }
    }

    @Test fun revealedCardAndOwnerSurviveUnfocusedOffscreenScroll() {
        val words = listOf(
            SavedWord("card-scroll-a", "amber", "English", "language", "Amber owner meaning"),
            SavedWord("card-scroll-b", "birch", "English", "language", "Birch owner meaning"),
        )
        val answers = mutableListOf<Pair<String, Boolean>>()
        val opened = mutableListOf<SavedWord>()
        try {
            mountLearnRetentionPanel(words, answers, opened)
            scrollLearnRetentionToEdge(top = false)
            selectLearnRetentionGame("Cards")
            scrollLearnRetentionToEdge(top = false)
            val card = words.single { compose.onAllNodesWithText(it.title).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(card.title).performScrollTo().assertIsDisplayed().performClick()
            compose.onNodeWithText(card.clue).performScrollTo().assertIsDisplayed()
            hideUnfocusedLearnGame(card.clue)
            compose.onNodeWithText(card.clue).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Recall the meaning, then tap to reveal.").assertDoesNotExist()
            compose.onNodeWithText("Read").performScrollTo().assertIsDisplayed().performClick()
            compose.runOnIdle { assertEquals(listOf(card), opened); assertTrue(answers.isEmpty()) }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
            retentionFocus.set(null)
        }
    }

    @Test fun scrambleGuessAndFeedbackSurviveUnfocusedOffscreenScroll() {
        val words = listOf(
            SavedWord("scramble-scroll-a", "cedar", "English", "language", "Cedar owner clue"),
            SavedWord("scramble-scroll-b", "maple", "English", "language", "Maple owner clue"),
        )
        val answers = mutableListOf<Pair<String, Boolean>>()
        try {
            mountLearnRetentionPanel(words, answers)
            scrollLearnRetentionToEdge(top = false)
            selectLearnRetentionGame("Scramble")
            scrollLearnRetentionToEdge(top = false)
            val word = words.single { compose.onAllNodesWithText(it.clue).fetchSemanticsNodes().isNotEmpty() }
            compose.onNode(hasSetTextAction()).performScrollTo().assertIsDisplayed().performTextInput("not the answer")
            hideUnfocusedLearnGame(word.clue)
            compose.onNodeWithText(word.clue).performScrollTo().assertIsDisplayed()
            compose.onNode(hasSetTextAction()).performScrollTo().assertIsDisplayed().assertIsNotFocused()
                .assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.EditableText,
                    androidx.compose.ui.text.AnnotatedString("not the answer")))
            compose.onNodeWithText("Check").performScrollTo().assertIsDisplayed().performClick()
            compose.onNodeWithText("Answer: " + word.title).performScrollTo().assertIsDisplayed()
            hideUnfocusedLearnGame("Answer: " + word.title)
            compose.onNodeWithText("Answer: " + word.title).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Check").assertIsNotEnabled()
            compose.onNodeWithText("Next").performScrollTo().assertIsDisplayed().performClick()
            compose.onNodeWithText(words.single { it.key != word.key }.clue).performScrollTo().assertIsDisplayed()
            compose.onNode(hasSetTextAction()).assert(SemanticsMatcher.expectValue(
                androidx.compose.ui.semantics.SemanticsProperties.EditableText,
                androidx.compose.ui.text.AnnotatedString("")))
            compose.runOnIdle { assertEquals(listOf(word.key to false), answers) }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
            retentionFocus.set(null)
        }
    }


    @Test fun attributionActionsWrapWithinNarrowLargeTextAndKeepIndependentDestinations() {
        fun captureAttribution(name: String) {
            require(name in setOf("attribution-narrow-ltr.png", "attribution-narrow-rtl.png",
                "attribution-normal-ltr.png", "attribution-normal-rtl.png"))
            // The same owned Compose-root/file route used by the retained SectionLink frames.
            // Only this public fixture is captured, never a system overlay or another app.
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            try {
                val files = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
                val directory = java.io.File(files, "qa-copy-evidence")
                check(directory.mkdirs() || directory.isDirectory)
                check(directory.canonicalFile.parentFile == files.canonicalFile)
                val target = java.io.File(directory, name)
                check(target.canonicalFile.parentFile == directory.canonicalFile && !target.exists())
                target.outputStream().use { output ->
                    var count = 0
                    val bounded = object : java.io.OutputStream() {
                        override fun write(value: Int) {
                            check(count < 16 * 1024 * 1024)
                            output.write(value); count++
                        }
                        override fun write(bytes: ByteArray, offset: Int, length: Int) {
                            check(length <= 16 * 1024 * 1024 - count)
                            output.write(bytes, offset, length); count += length
                        }
                    }
                    check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bounded))
                }
            } finally { bitmap.recycle() }
        }
        val entry = Entry("Attribution fixture", emptyList(), "language", "English", "en",
            listOf(Section(2, "English", listOf(Block("definition", 1,
                listOf(Span("text", "Owned attribution fixture body")))))), emptyList())
            .copy(edition = "enwiktionary-20261001")
        val licenseUrl = "https://creativecommons.org/licenses/by-sa/4.0/"
        val opened = mutableListOf<String>()
        for (direction in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
            for (large in listOf(false, true)) {
                val width = if (large) 280.dp else 360.dp
                val scale = if (large) 2f else 1f
                val caseId = "attribution-${direction.name.lowercase()}-${if (large) "large" else "normal"}"
                compose.runOnUiThread {
                    compose.activity.setContent {
                        val density = LocalDensity.current
                        CompositionLocalProvider(
                            LocalDensity provides Density(density.density, scale),
                            androidx.compose.ui.platform.LocalLayoutDirection provides direction,
                            androidx.compose.ui.platform.LocalUriHandler provides object : androidx.compose.ui.platform.UriHandler {
                                override fun openUri(uri: String) { opened.add(uri) }
                            }
                        ) {
                            DictTheme("system") {
                                androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                                    Box(Modifier.fillMaxSize()) {
                                        Box(Modifier.width(width).fillMaxSize().testTag("attribution-viewport")) {
                                            EntryView(entry, false, {}, settings = AppSettings(collapseOtherSections = false))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("CC BY-SA 4.0"))
                val viewport = compose.onNodeWithTag("attribution-viewport")
                val viewportBounds = viewport.fetchSemanticsNode().boundsInRoot
                // Retain this owned scene even if a later text/geometry/action assertion fails.
                captureAttribution("attribution-${if (large) "narrow" else "normal"}-${direction.name.lowercase()}.png")
                val bounds = mutableListOf<androidx.compose.ui.geometry.Rect>()
                for (label in listOf("Wiktionary contributors", "CC BY-SA 4.0")) {
                    val button = compose.onNodeWithText(label)
                    val text = compose.onNodeWithText(label, useUnmergedTree = true)
                    val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                    text.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                    val layout = layouts.single()
                    val node = button.fetchSemanticsNode()
                    val evidence = "$caseId: " + renderedLayoutFailureEvidence(label, layout, node, viewport, null)
                    button.assertIsDisplayed().assertHasClickAction().assert(
                        SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role,
                            androidx.compose.ui.semantics.Role.Button))
                    assertEquals(evidence, scale, layout.layoutInput.density.fontScale, 0f)
                    assertEquals(evidence, with(layout.layoutInput.density) { width.toPx() }, viewportBounds.width, 1f)
                    try { assertCompletePlainTextLayout(layout, label) }
                    catch (failure: AssertionError) { throw AssertionError(evidence, failure) }
                    val visual = node.boundsInRoot
                    val touch = node.touchBoundsInRoot
                    for (rect in listOf(visual, touch)) {
                        assertTrue(evidence, rect.width > 0f && rect.height > 0f &&
                            rect.left >= viewportBounds.left - 1f && rect.right <= viewportBounds.right + 1f &&
                            rect.top >= viewportBounds.top - 1f && rect.bottom <= viewportBounds.bottom + 1f)
                    }
                    bounds.add(visual)
                    button.performClick()
                }
                assertFalse("$caseId buttons must not overlap: $bounds", bounds[0].overlaps(bounds[1]))
                if (!large) assertEquals("$caseId retains the ordinary single row", bounds[0].top, bounds[1].top, 1f)
                compose.runOnIdle {
                    assertEquals("$caseId independent destinations", listOf(attributionUrl(entry), licenseUrl), opened)
                    opened.clear()
                }
            }
        }
    }


    @Test fun preferredCellWidthsResizeTheRealGridAndKeepRtlActionOwners() {
        val single = mutableStateOf(false)
        val viewport = mutableStateOf(600)
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    androidx.compose.ui.platform.LocalLayoutDirection provides direction.value) {
                    DictTheme("light") {
                        fun cell(label: String, percent: Float) = Cell(listOf(Span("link", label, "Width-$label")),
                            false, 1, 1, style = CellStyle(padding = edges, width = StyleWidth(StyleWidthUnit.Percent, percent)))
                        val cells = if (single.value) listOf(cell("A", 48f)) else listOf(cell("A", 20f), cell("B", 80f))
                        val table = Table(emptyList(), listOf(cells), geometry = TableGeometry(cellSpacing = 0, cellPadding = 0),
                            style = TableStyle(border = StyleBorder.None, margins = edges,
                                width = StyleWidth(StyleWidthUnit.Px, if (viewport.value == 600) 400f else 200f)))
                        val entry = Entry("Preferred widths", emptyList(), "language", "English", "en",
                            listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = table)))), emptyList())
                        Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.TopStart) {
                            Box(Modifier.width(viewport.value.dp).height(700.dp)) {
                                EntryView(entry, false, {}, onLink = { links += it }, settings = AppSettings(
                                    collapseOtherSections = false, collapseDetails = false))
                            }
                        }
                    }
                }
            } }
            fun cell(column: Int) = compose.onNode(SemanticsMatcher("Preferred cell $column") {
                it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.CollectionItemInfo)?.let { item ->
                    item.rowIndex == 0 && item.columnIndex == column
                } == true
            }, useUnmergedTree = true)
            for (dir in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                for (width in listOf(600, 320)) for (one in listOf(false, true)) {
                    compose.runOnIdle { direction.value = dir; viewport.value = width; single.value = one }
                    compose.waitForIdle()
                    val assigned = if (width == 600) 400f else 200f
                    val first = cell(0).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
                    assertEquals(if (one) assigned else assigned * .2f, first.width, 1f)
                    if (!one) {
                        val second = cell(1).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
                        assertEquals(assigned * .8f, second.width, 1f)
                        if (dir == androidx.compose.ui.unit.LayoutDirection.Ltr) assertEquals(first.right, second.left, 1f)
                        else assertEquals(second.right, first.left, 1f)
                    }
                    val action = compose.onNodeWithText("A", useUnmergedTree = true).assertIsDisplayed()
                    val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                    action.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                    assertEquals("A", layouts.single().layoutInput.text.text)
                    compose.runOnIdle { assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus()) }
                    action.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                    compose.runOnIdle { assertEquals(EntryLink("Width-A"), links.last()) }
                }
            }
            assertEquals(8, links.size)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun containerScrollportOwnsTwoRealTablesAndClipsNativeSelectionAcrossResizeAndRtl() {
        val width = mutableStateOf(620)
        val wide = mutableStateOf(true)
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        fun nativeOwners(): List<NativeFloatTextView> {
            val result = mutableListOf<NativeFloatTextView>()
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView && view.isShown && view.logicalText.startsWith("Viewport link")) result += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(compose.activity.window.decorView)
            return result
        }
        val horizontal = SemanticsMatcher("one Container horizontal owner") {
            it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange) != null
        }
        fun scroller() = compose.onNode(horizontal, useUnmergedTree = true)
        fun axis() = scroller().fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange]
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    androidx.compose.ui.platform.LocalLayoutDirection provides direction.value) {
                    DictTheme("light") {
                        fun table(name: String, pixels: Float): Block {
                            fun cell(label: String) = Cell(listOf(Span("link", label, "Scroll-$label")), false, 1, 1,
                                style = CellStyle(padding = edges, minWidth = StyleLength(StyleLengthUnit.Px, if (wide.value) 350f else 40f)))
                            return Block("table", 0, emptyList(), table = Table(emptyList(),
                                listOf(listOf(cell("$name start"), cell("$name end"))),
                                geometry = TableGeometry(cellSpacing = 0, cellPadding = 0),
                                style = TableStyle(border = StyleBorder.None, margins = edges,
                                    width = StyleWidth(StyleWidthUnit.Px, if (wide.value) pixels else 160f))))
                        }
                        val parts = listOf(Block("paragraph", 0, listOf(Span("link", "Viewport link", "Scroll-text"))),
                            table("One", 900f), table("Two", 850f))
                        val block = Block("container", 0, emptyList(), container = Container(parts,
                            ContainerStyle(overflow = ContainerOverflow.Auto,
                                maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 500f)),
                                padding = StyleEdges(StyleLength(StyleLengthUnit.Px, 4f), StyleLength(StyleLengthUnit.Px, 6f),
                                    StyleLength(StyleLengthUnit.Px, 4f), StyleLength(StyleLengthUnit.Px, 6f)),
                                border = ContainerBorder.Solid(StyleLength(StyleLengthUnit.Px, 2f), ContainerColor.Rgb("#000000")))))
                        Column(Modifier.width(width.value.dp).testTag("scrollport-scene")) {
                            NativeFloatBlockContext(listOf(block), { links += it }, "scrollport-control", Modifier,
                                inCell = false, gridPath = "scrollport-control", gapDp = 0f, trailingGap = false)
                            Text("Following owner", Modifier.testTag("after-scrollport"))
                        }
                    }
                }
            } }
            for (rtl in listOf(false, true)) {
                compose.runOnIdle {
                    direction.value = if (rtl) androidx.compose.ui.unit.LayoutDirection.Rtl else androidx.compose.ui.unit.LayoutDirection.Ltr
                    width.value = 620; wide.value = true
                }
                compose.waitForIdle()
                compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(1)
                scroller().performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.ScrollBy) { it(-10000f, 0f) }
                compose.waitForIdle()
                assertEquals(0f, axis().value(), 1f)
                assertTrue(axis().maxValue() > 300f)
                val initialTop = compose.onNodeWithTag("after-scrollport").fetchSemanticsNode().boundsInRoot.top
                val viewport = scroller().fetchSemanticsNode().boundsInRoot
                assertEquals(512f, viewport.width, 1f) // content max500 plus two six-pixel paddings; border stays outside.
                val owner = compose.runOnIdle { nativeOwners().single().also { it.setSelection(0, 8) } }
                val source = compose.runOnIdle { owner.logicalText.toString() }
                scroller().performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.ScrollBy) { it(10000f, 0f) }
                compose.waitForIdle()
                assertEquals(axis().maxValue(), axis().value(), 1f)
                assertEquals(initialTop, compose.onNodeWithTag("after-scrollport").fetchSemanticsNode().boundsInRoot.top, 1f)
                compose.runOnIdle {
                    assertSame(owner, nativeOwners().single())
                    assertEquals(source, owner.logicalText.toString()); assertEquals(0, owner.selectionStart); assertEquals(8, owner.selectionEnd)
                    val down = android.view.MotionEvent.obtain(0L, 0L, android.view.MotionEvent.ACTION_DOWN, -1f, -1f, 0)
                    try { assertFalse(owner.onTouchEvent(down)) } finally { down.recycle() }
                    val infos = checkNotNull(owner.accessibilityNodeProvider!!.findAccessibilityNodeInfosByText("Viewport link", android.view.View.NO_ID))
                    assertTrue(infos.isNotEmpty())
                    infos.forEach { info ->
                        val bounds = android.graphics.Rect(); info.getBoundsInScreen(bounds)
                        if (!bounds.isEmpty) {
                            val clipField = NativeFloatTextView::class.java.getDeclaredField("scrollClip").apply { isAccessible = true }
                            val clip = (clipField.get(owner) as NativeScrollClip).inScreen()
                            assertTrue(clip.contains(android.graphics.RectF(bounds)))
                        }
                        info.recycle()
                    }
                    owner.setSelection(0, 0)
                }
                // Both real grids move with the one owner; the trailing cell is reachable and keeps its action.
                val visibleLabel = "Two end"
                val action = compose.onNodeWithText(visibleLabel, useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                action.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                compose.runOnIdle { assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus()) }
                action.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                compose.runOnIdle { assertEquals(EntryLink("Scroll-$visibleLabel"), links.last()) }
                if (!rtl) {
                    compose.runOnIdle {
                        val geometry = NativeFloatTextView::class.java.getDeclaredField("geometry").apply { isAccessible = true }.get(owner) as FloatTextGeometry
                        val target = geometry.nodes.single { it.onClick != null }
                        assertTrue(owner.accessibilityNodeProvider!!.performAction(target.id,
                            android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                    }
                    compose.waitForIdle()
                    assertTrue("Native focus must reveal through the same local viewport", axis().value() < axis().maxValue())
                }
                compose.runOnIdle { width.value = 320 }
                compose.waitForIdle()
                assertEquals(316f, scroller().fetchSemanticsNode().boundsInRoot.width, 1f)
                assertTrue(axis().value() <= axis().maxValue())
                compose.runOnIdle { assertSame(owner, nativeOwners().single()); assertEquals(source, owner.logicalText.toString()); wide.value = false }
                compose.waitForIdle()
                assertEquals(0f, axis().maxValue(), 1f); assertEquals(0f, axis().value(), 1f)
                compose.runOnIdle { assertSame(owner, nativeOwners().single()); assertEquals(source, owner.logicalText.toString()) }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun containerScrollportContainsInternalFloatAndShowsCompleteVerticalRefusal() {
        val overflow = mutableStateOf(false)
        val links = java.util.concurrent.CopyOnWriteArrayList<EntryLink>()
        val px: (Float) -> StyleLength = { StyleLength(StyleLengthUnit.Px, it) }
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    DictTheme("light") {
                        val body = Block("paragraph", 0, listOf(Span("link", "Kept overflow action", "Kept-overflow")))
                        val inner = Block("container", 0, emptyList(), container = Container(
                            if (overflow.value) listOf(body) else emptyList(), ContainerStyle(
                                height = px(if (overflow.value) 0f else 90f),
                                width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 80f)),
                                floatSide = if (overflow.value) null else TableFloatSide.Left,
                                background = ContainerColor.Rgb("#cccccc"))))
                        val outer = Block("container", 0, emptyList(), container = Container(
                            if (overflow.value) listOf(inner) else listOf(inner, body),
                            ContainerStyle(overflow = ContainerOverflow.Auto)))
                        Column(Modifier.width(320.dp)) {
                            NativeFloatBlockContext(listOf(outer), { links += it }, "scrollport-overflow", Modifier,
                                inCell = false, gridPath = "scrollport-overflow", gapDp = 0f, trailingGap = false,
                                fixedHeightReachable = true)
                            Text("After contained float", Modifier.testTag("after-contained-float"))
                        }
                    }
                }
            } }
            compose.waitForIdle()
            assertTrue(compose.onNodeWithTag("after-contained-float").fetchSemanticsNode().boundsInRoot.top >= 90f)
            compose.onNodeWithText("Local vertical overflow is unavailable").assertDoesNotExist()
            compose.runOnIdle { overflow.value = true }
            compose.waitForIdle()
            compose.onNodeWithText("Local vertical overflow is unavailable").assertIsDisplayed()
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
                val pending = java.util.ArrayDeque<android.view.View>(); pending.add(compose.activity.window.decorView)
                var found = 0
                while (pending.isNotEmpty()) {
                    val view = pending.removeFirst()
                    if (view is NativeFloatTextView && view.isShown) {
                        val nodes = view.accessibilityNodeProvider?.findAccessibilityNodeInfosByText("Kept overflow action", android.view.View.NO_ID).orEmpty()
                        nodes.forEach { node ->
                            if (node.isClickable && node.isVisibleToUser) {
                                assertTrue(view.accessibilityNodeProvider!!.performAction(
                                    // The provider's stable node ID is retained in its real geometry, not inferred from bounds.
                                    (view.javaClass.getDeclaredField("geometry").apply { isAccessible = true }.get(view) as FloatTextGeometry)
                                        .nodes.single { it.label == "Kept overflow action" || it.onClick != null }.id,
                                    android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                                found++
                            }
                            node.recycle()
                        }
                    }
                    if (view is android.view.ViewGroup) repeat(view.childCount) { pending.add(view.getChildAt(it)) }
                }
                assertEquals(1, found); assertEquals(listOf(EntryLink("Kept-overflow")), links)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun scrollportUsesFractionalAndZeroNativeLineBoxesAcrossPlainAndAnonymousOwners() {
        val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { textSize = 20f }
        val primary = NativePrimaryFontMetrics.from(paint)
        for (height in listOf(0f, .5f, 1.25f)) {
            val source = android.text.SpannableString("fractional")
            source.setSpan(NativeRunLineMetrics(primary, NativeLineHeightPolicy.Pixels(height), strut = true),
                0, source.length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val native = NativeFloatGeometry.build(source, paint, 300, emptyList())
            assertEquals(height, native.textBottom, .0001f)
            assertEquals(kotlin.math.ceil(height).toInt(), native.height)
            assertEquals(height, native.scrollableBounds.bottom, .0001f)
            assertTrue("Glyph ink must remain independent of the short used line", native.extents.ink!!.bottom > native.scrollableBounds.bottom)
            val content = anonymousFlowContent(Block("paragraph", 0, listOf(Span("text", "fractional"))),
                AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
            val anonymous = NativeAnonymousFlowGeometry.build(content, paint, 300, inline = { source },
                figure = { _, _ -> error("This source has no Figure") })
            assertEquals(height, anonymous.textBottom, .0001f)
            assertEquals(height, anonymous.scrollableBounds.bottom, .0001f)
            var calls = 0
            for (flow in listOf(false, true)) {
                val part = if (flow) NativeFloatContextPart.Flow(1, { _, _ -> calls++; anonymous })
                    else NativeFloatContextPart.Text("fractional", { _, _ -> calls++; native })
                val context = NativeFloatContextGeometry.build(300, listOf(part), containAtEnd = true)
                assertEquals(height, context.usedHeight, .0001f)
                assertEquals(height, context.scrollableBounds.bottom, .0001f)
                val allocation = nativeScrollportAllocation(300, context.usedHeight, context.scrollableBounds,
                    FloatMargins(0f, 0f, 0f, 0f))
                assertFalse(allocation.verticalOverflow); assertFalse(allocation.leadingOverflow)
                assertEquals(0, allocation.range)
                assertEquals("fractional", context.text.toString())
            }
            assertEquals(2, calls)
        }
    }

    @OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.ui.test.ExperimentalTestApi::class)
    @Test fun authoredAudioControlsKeepFocusSeekAndSameFileOccurrencesIndependent(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            java.io.File(context.cacheDir, "audio-control-" + java.util.UUID.randomUUID()).apply { mkdirs() }
        }
        // Synthetic owned silence, not a retained pronunciation or source-media receipt.
        val samples = ByteArray(120 * 8000) { 128.toByte() }
        val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .put("RIFF".toByteArray()).putInt(36 + samples.size).put("WAVEfmt ".toByteArray())
            .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(8000).putShort(1).putShort(8)
            .put("data".toByteArray()).putInt(samples.size).array()
        val sourceUrl = "https://fixture.invalid/audio-source"
        val metadata = """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/audio","descriptionurl":"$sourceUrl"}]}]}}""".toByteArray()
        val opens = java.util.concurrent.atomic.AtomicInteger()
        val cache = MediaCache(context, metadata = { metadata }, directory = directory,
            openMedia = { opens.incrementAndGet(); java.io.ByteArrayInputStream(header + samples) })
        var thumbColor = 0
        var focusAlpha = 0f
        var automaticFocusColor = 0
        val media = Media("Owned-audio.wav", "audio", "Owned audio fixture")
        val red = AudioControlFocusPaint(AudioControlFocusMode.UaAuto, FigureColor.Rgb("#ff0000"))
        val green = AudioControlFocusPaint(AudioControlFocusMode.UaAuto, FigureColor.Rgb("#00ff00"))
        val none = AudioControlFocusPaint(AudioControlFocusMode.AuthoredNone)
        val control = mutableStateOf(AudioControl(StyleWidth(StyleWidthUnit.Px, 250f),
            StyleLength(StyleLengthUnit.Px, 30f), red))
        val other = control.value.copy(focus = none)
        val reference = mutableStateOf(true)
        val referenceColor = mutableStateOf(androidx.compose.ui.graphics.Color.Red)
        val hostWidth = mutableStateOf(320f)
        val originalWidth = NativeLayoutInput(320f)
        val direction = mutableStateOf("ltr")
        val overflowOwned = mutableStateOf(true)
        val showFirst = mutableStateOf(true)
        val settings = mutableStateOf(AppSettings(allowAudio = true, mediaCacheMb = 1))
        val selectedMedia = mutableStateOf(media)
        val selectedCache = mutableStateOf(cache)
        val brokenCache = MediaCache(context, metadata = { metadata }, directory = directory,
            openMedia = { java.io.ByteArrayInputStream(byteArrayOf(1)) })
        val opened = mutableListOf<String>()
        val neutral = FocusRequester()
        val keyboard = object : androidx.compose.ui.input.InputModeManager {
            override val inputMode = androidx.compose.ui.input.InputMode.Keyboard
            override fun requestInputMode(inputMode: androidx.compose.ui.input.InputMode) = inputMode == this.inputMode
        }
        val playerState = MediaPlayback::class.java.getDeclaredField("player\$delegate").apply { isAccessible = true }
        fun player() = (playerState.get(MediaPlayback) as androidx.compose.runtime.State<*>).value as? android.media.MediaPlayer
        fun node(owner: String, label: String) = compose.onNode(hasContentDescription(label) and hasAnyAncestor(hasTestTag(owner)))
        fun play(owner: String) = node(owner, "Play pronunciation")
        fun stop(owner: String) = node(owner, "Stop pronunciation")
        fun seek(owner: String) = node(owner, "Pronunciation position")
        fun source(owner: String) = node(owner, "Source and licence")
        fun focus(node: SemanticsNodeInteraction) {
            node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus) { assertTrue(it()) }
            node.assertIsFocused()
            compose.mainClock.advanceTimeBy(100)
            compose.waitForIdle()
        }
        fun shot(node: SemanticsNodeInteraction): IntArray {
            val bitmap = node.captureToImage().asAndroidBitmap()
            return try { IntArray(bitmap.width * bitmap.height).also { bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height) } }
            finally { bitmap.recycle() }
        }
        fun tintedThumb(color: Int): Int {
            fun channel(shift: Int) = kotlin.math.round(((color ushr shift) and 255) * focusAlpha +
                ((thumbColor ushr shift) and 255) * (1f - focusAlpha)).toInt().coerceIn(0, 255)
            return android.graphics.Color.rgb(channel(16), channel(8), channel(0))
        }
        fun pixelsNear(pixels: IntArray, color: Int) = pixels.count { pixel ->
            listOf(0, 8, 16).all { shift -> kotlin.math.abs(((pixel ushr shift) and 255) - ((color ushr shift) and 255)) <= 2 }
        }
        fun layoutBox(node: SemanticsNodeInteraction): android.graphics.RectF {
            val n = node.fetchSemanticsNode()
            return android.graphics.RectF(n.positionInRoot.x, n.positionInRoot.y,
                n.positionInRoot.x + n.size.width, n.positionInRoot.y + n.size.height)
        }
        fun assertSize(width: Float, rtl: Boolean = false) {
            val button = layoutBox(play("audio-a"))
            val slider = layoutBox(seek("audio-a"))
            assertEquals(30f, button.height(), .01f)
            assertEquals(30f, slider.height(), .01f)
            assertEquals(width, maxOf(button.right, slider.right) - minOf(button.left, slider.left), .01f)
            if (rtl) assertTrue(button.left >= slider.right) else assertTrue(slider.left >= button.right)
        }
        fun waitPlaying(owner: String) {
            compose.waitUntil(15000) {
                val nodes = compose.onAllNodes(hasContentDescription("Stop pronunciation") and hasAnyAncestor(hasTestTag(owner)))
                    .fetchSemanticsNodes(atLeastOneRootRequired = false)
                var ready = false
                InstrumentationRegistry.getInstrumentation().runOnMainSync { ready = player()?.isPlaying == true }
                nodes.size == 1 && ready
            }
            compose.waitUntil(5000) { seek(owner).fetchSemanticsNode().config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Disabled) == null }
        }
        fun range(owner: String) = seek(owner).fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo]
        fun waitPosition(target: Int) {
            compose.waitUntil(5000) {
                var position = -1
                InstrumentationRegistry.getInstrumentation().runOnMainSync { position = player()?.currentPosition ?: -1 }
                position in target - 200..target + 200
            }
        }
        fun settlePausedRange(owner: String) {
            compose.waitUntil(5000) {
                var actual = -1
                InstrumentationRegistry.getInstrumentation().runOnMainSync { actual = player()?.currentPosition ?: -1 }
                actual >= 0 && kotlin.math.abs(range(owner).current - actual) <= 1f
            }
        }
        var primaryFailure: Throwable? = null
        try {
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                // Only the owned fixture chooses the existing keyboard branch; no platform input-mode mutation.
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    androidx.compose.ui.platform.LocalInputModeManager provides keyboard,
                    androidx.compose.ui.platform.LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr,
                    androidx.compose.ui.platform.LocalUriHandler provides object : androidx.compose.ui.platform.UriHandler {
                        override fun openUri(uri: String) { opened += uri }
                    }) {
                    DictTheme("light") {
                        val color = androidx.compose.material3.SliderDefaults.colors().thumbColor.toArgb()
                        val alpha = androidx.compose.material3.RippleDefaults.RippleAlpha.focusedAlpha
                        SideEffect { thumbColor = color; focusAlpha = alpha }
                        androidx.compose.material3.Surface(color = androidx.compose.ui.graphics.Color.White) {
                            val automatic = androidx.compose.material3.LocalContentColor.current.toArgb()
                            SideEffect { automaticFocusColor = automatic }
                            Column(Modifier.width(hostWidth.value.dp)) {
                                Box(Modifier.size(1.dp).focusRequester(neutral).focusable())
                                if (reference.value) {
                                    CompositionLocalProvider(androidx.compose.material3.LocalMinimumInteractiveComponentSize provides 0.dp,
                                        androidx.compose.material3.LocalRippleConfiguration provides androidx.compose.material3.RippleConfiguration(referenceColor.value)) {
                                        androidx.compose.foundation.layout.Row(Modifier.width(250.dp).height(30.dp)) {
                                            androidx.compose.material3.IconButton(onClick = {}, modifier = Modifier.testTag("audio-stock")) {
                                                androidx.compose.material3.Icon(androidx.compose.material.icons.Icons.Outlined.PlayArrow, "Stock playback reference")
                                            }
                                        }
                                    }
                                } else {
                                    if (showFirst.value) androidx.compose.runtime.key("first") {
                                        Box(Modifier.testTag("audio-a")) {
                                            MediaView(selectedMedia.value, settings.value, cache = selectedCache.value, audioControl = control.value,
                                                audioDirection = direction.value, audioContainingWidthPixels = { originalWidth.value }, audioContainingWidthModifier = originalWidth.modifier, audioOverflowOwned = overflowOwned.value)
                                        }
                                    }
                                    androidx.compose.runtime.key("second") {
                                        Box(Modifier.testTag("audio-b")) { MediaView(selectedMedia.value, settings.value, cache = selectedCache.value, audioControl = other, audioDirection = "ltr", audioOverflowOwned = true) }
                                    }
                                }
                            }
                        }
                    }
                }
            } }
            compose.runOnIdle { neutral.requestFocus() }
            val stock = compose.onNodeWithTag("audio-stock")
            val idle = shot(stock)
            focus(stock); val redStock = shot(stock)
            compose.runOnIdle { referenceColor.value = androidx.compose.ui.graphics.Color.Green }
            compose.waitForIdle(); val greenStock = shot(stock)
            compose.runOnIdle { referenceColor.value = androidx.compose.ui.graphics.Color.Unspecified }
            compose.waitForIdle(); val defaultStock = shot(stock)
            stock.performMouseInput { enter(center) }
            compose.mainClock.advanceTimeBy(100); compose.waitForIdle()
            val hoverStock = shot(stock)
            stock.performMouseInput { exit() }
            compose.runOnIdle { reference.value = false }
            compose.waitForIdle()
            assertSize(250f)
            seek("audio-a").assertIsNotEnabled(); seek("audio-b").assertIsNotEnabled()
            focus(play("audio-a")); assertArrayEquals(redStock, shot(play("audio-a")))
            compose.runOnIdle { control.value = control.value.copy(focus = green) }
            play("audio-a").assertIsFocused(); compose.waitForIdle()
            assertArrayEquals(greenStock, shot(play("audio-a")))
            compose.runOnIdle { control.value = control.value.copy(focus = none) }
            play("audio-a").assertIsFocused(); compose.waitForIdle()
            assertArrayEquals(idle, shot(play("audio-a")))
            compose.runOnIdle { control.value = control.value.copy(focus = null) }
            play("audio-a").assertIsFocused(); compose.waitForIdle()
            assertArrayEquals(defaultStock, shot(play("audio-a")))
            compose.runOnIdle { control.value = control.value.copy(focus = red.copy(color = FigureColor.Transparent)) }
            play("audio-a").assertIsFocused(); compose.waitForIdle()
            assertArrayEquals(idle, shot(play("audio-a")))
            compose.runOnIdle { control.value = control.value.copy(focus = red) }
            play("audio-a").performMouseInput { enter(center) }
            compose.mainClock.advanceTimeBy(100); compose.waitForIdle()
            assertArrayEquals(hoverStock, shot(play("audio-a")))
            compose.runOnIdle { control.value = control.value.copy(focus = green) }
            play("audio-a").assertIsFocused(); compose.waitForIdle()
            assertArrayEquals(hoverStock, shot(play("audio-a")))
            play("audio-a").performMouseInput { exit() }
            compose.mainClock.advanceTimeBy(100); compose.waitForIdle()
            assertArrayEquals(greenStock, shot(play("audio-a")))
            // Fixed and percentage geometry uses original C even when the outer allocation does not change.
            compose.runOnIdle { control.value = control.value.copy(width = StyleWidth(StyleWidthUnit.Px, TablePixelLimit + 1f)) }
            compose.onNodeWithText("Unable to display this layout.").assertExists()
            play("audio-a").assertIsEnabled(); seek("audio-a").assertIsNotEnabled()
            compose.runOnIdle { control.value = control.value.copy(width = StyleWidth(StyleWidthUnit.Percent, 50f)); originalWidth.update(180f) }
            compose.waitForIdle(); assertSize(90f)
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            compose.runOnIdle { originalWidth.update(200f) }
            compose.waitForIdle(); assertSize(100f)
            compose.runOnIdle { control.value = control.value.copy(width = StyleWidth(StyleWidthUnit.Px, 250f)); hostWidth.value = 180f; direction.value = "rtl" }
            compose.waitForIdle(); assertSize(250f, rtl = true)
            // This direct fixture owns only child allocation, not a document-scroll receipt.
            // Removing that explicit grant must show retained-layout refusal, not silent clipping.
            compose.runOnIdle { overflowOwned.value = false }
            compose.onNodeWithText("Unable to display this layout.").assertExists()
            play("audio-a").assertIsEnabled()
            compose.runOnIdle { overflowOwned.value = true }
            compose.waitForIdle(); assertSize(250f, rtl = true)
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            compose.runOnIdle { hostWidth.value = 320f; originalWidth.update(320f); direction.value = "ltr"; control.value = control.value.copy(focus = none) }
            compose.waitForIdle(); focus(play("audio-a"))
            play("audio-a").performKeyInput { keyDown(androidx.compose.ui.input.key.Key.Enter) }
            compose.runOnIdle { assertNull(MediaPlayback.playing) }
            compose.waitUntil(3000) { !shot(play("audio-a")).contentEquals(idle) }
            play("audio-a").performKeyInput { keyUp(androidx.compose.ui.input.key.Key.Enter) }
            waitPlaying("audio-a")
            play("audio-b").assertExists(); seek("audio-b").assertIsNotEnabled()
            var firstPlayer: android.media.MediaPlayer? = null
            compose.runOnIdle { firstPlayer = player(); assertNotNull(firstPlayer) }
            assertEquals(120000f, range("audio-a").range.endInclusive, 1f)
            compose.waitUntil(5000) { range("audio-a").current > 0f }
            // Stabilize the independent seek/key oracle using the actual owned player,
            // not a frozen Compose clock (which cannot stop native playback time).
            var pausedPosition = 0
            compose.runOnIdle { checkNotNull(player()).pause(); pausedPosition = checkNotNull(player()).currentPosition }
            compose.waitUntil(5000) { kotlin.math.abs(range("audio-a").current - pausedPosition) <= 1f }
            seek("audio-a").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { assertTrue(it(30000f)) }
            waitPosition(30000)
            compose.runOnIdle { control.value = control.value.copy(focus = red) }
            focus(seek("audio-a"))
            assertTrue("Actual stock thumb focus must use authored red", pixelsNear(shot(seek("audio-a")), tintedThumb(android.graphics.Color.RED)) > 0)
            compose.runOnIdle { control.value = control.value.copy(focus = green) }
            seek("audio-a").assertIsFocused(); compose.waitForIdle()
            assertTrue("Policy replacement keeps the real slider focused and colors its thumb", pixelsNear(shot(seek("audio-a")), tintedThumb(android.graphics.Color.GREEN)) > 0)
            compose.runOnIdle { control.value = control.value.copy(focus = none) }
            seek("audio-a").assertIsFocused(); compose.waitForIdle()
            assertEquals(0, pixelsNear(shot(seek("audio-a")), tintedThumb(android.graphics.Color.GREEN)))
            compose.runOnIdle { control.value = control.value.copy(focus = null) }
            seek("audio-a").assertIsFocused(); compose.waitForIdle()
            assertTrue("An explicit control with null focus keeps selected native-auto indication",
                pixelsNear(shot(seek("audio-a")), tintedThumb(automaticFocusColor)) > 0)
            settlePausedRange("audio-a")
            val before = range("audio-a").current
            seek("audio-a").performKeyInput { keyDown(androidx.compose.ui.input.key.Key.DirectionRight) }
            assertEquals(before + 1200f, range("audio-a").current, 2f)
            seek("audio-a").performKeyInput { keyUp(androidx.compose.ui.input.key.Key.DirectionRight) }
            waitPosition((before + 1200f).toInt())
            focus(source("audio-a")); val sourcePaint = shot(source("audio-a"))
            compose.runOnIdle { control.value = control.value.copy(focus = red); direction.value = "rtl" }
            source("audio-a").assertIsFocused(); compose.waitForIdle()
            assertArrayEquals(sourcePaint, shot(source("audio-a")))
            source("audio-a").performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            assertEquals(listOf(sourceUrl), opened)
            seek("audio-a").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { assertTrue(it(60000f)) }
            waitPosition(60000); focus(seek("audio-a"))
            settlePausedRange("audio-a")
            val rtlBefore = range("audio-a").current
            seek("audio-a").performKeyInput { keyDown(androidx.compose.ui.input.key.Key.DirectionRight) }
            assertEquals(rtlBefore - 1200f, range("audio-a").current, 2f)
            seek("audio-a").performKeyInput { keyUp(androidx.compose.ui.input.key.Key.DirectionRight) }
            waitPosition((rtlBefore - 1200f).toInt())
            compose.runOnIdle { assertSame(firstPlayer, player()); checkNotNull(player()).start() }
            focus(play("audio-b")); play("audio-b").performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            waitPlaying("audio-b")
            play("audio-a").assertExists(); seek("audio-a").assertIsNotEnabled()
            var secondPlayer: android.media.MediaPlayer? = null
            compose.runOnIdle { secondPlayer = player(); assertNotSame(firstPlayer, secondPlayer); showFirst.value = false }
            compose.waitForIdle(); stop("audio-b").assertExists()
            compose.runOnIdle { assertSame(secondPlayer, player()); assertEquals(1, opens.get()) }
            compose.runOnIdle { settings.value = settings.value.copy(allowAudio = false) }
            compose.waitUntil(5000) { MediaPlayback.playing == null }
            play("audio-b").assertIsNotEnabled(); seek("audio-b").assertIsNotEnabled()
            source("audio-b").assertIsEnabled(); focus(source("audio-b"))
            source("audio-b").performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            assertEquals(listOf(sourceUrl, sourceUrl), opened)
            compose.runOnIdle { settings.value = settings.value.copy(allowAudio = true) }
            focus(play("audio-b")); play("audio-b").performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
            waitPlaying("audio-b")
            compose.runOnIdle { selectedCache.value = brokenCache; selectedMedia.value = media.copy(file = "Broken-audio.wav") }
            compose.waitForIdle(); play("audio-b").performClick()
            compose.waitUntil(15000) { compose.onAllNodesWithText("Pronunciation could not be played.")
                .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
            seek("audio-b").assertIsNotEnabled()
            compose.runOnIdle { assertNull(MediaPlayback.playing); selectedCache.value = cache; selectedMedia.value = media }
            compose.waitForIdle(); play("audio-b").performClick(); waitPlaying("audio-b")
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitUntil(5000) { MediaPlayback.playing == null }
            assertEquals("Owned-audio.wav", media.file)
            assertEquals(other, AudioControl(StyleWidth(StyleWidthUnit.Px, 250f), StyleLength(StyleLengthUnit.Px, 30f), none))
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            val alreadyFailed = primaryFailure != null
            fun retainCleanup(failure: Throwable) {
                val original = primaryFailure
                if (original == null) primaryFailure = failure
                else if (original !== failure) original.addSuppressed(failure)
            }
            try { compose.activityRule.scenario.onActivity { it.setContent {} } } catch (failure: Throwable) { retainCleanup(failure) }
            try { compose.runOnIdle { MediaPlayback.stop() } } catch (failure: Throwable) { retainCleanup(failure) }
            try {
                kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.IO) {
                    check(directory.deleteRecursively() || !directory.exists()) { "Owned audio fixture cleanup failed" }
                }
            } catch (failure: Throwable) { retainCleanup(failure) }
            if (!alreadyFailed) primaryFailure?.let { throw it }
        }
    }
    @OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)
    @Test fun ambiguousLinkDialogKeepsOriginalIntentAndCancelsOnlyItsCurrentChoice() {
        val original = EntryLink("Literal#title", "Noun#part")
        // Generic multi-edition display fixture; resolver admission is tested separately.
        val hits = listOf(
            WordHit("choice-fr-1", original.title, "French", "language", 0, 4, edition = "frwiktionary-20261001"),
            WordHit("choice-en-1", original.title, "English", "language", 0, 4, edition = "enwiktionary-20261001"),
            WordHit("choice-nl-1", original.title, "Dutch", "language", 0, 4, edition = "nlwiktionary-20261001"),
            WordHit("choice-fr-2", original.title, "French", "language", 0, 4, edition = "frwiktionary-20261101"),
            WordHit("choice-en-2", original.title, "English", "language", 0, 4, edition = "enwiktionary-20261101"),
            WordHit("choice-nl-2", original.title, "Dutch", "language", 0, 4, edition = "nlwiktionary-20261101"))
        val chooser = EntryLinkChoiceState()
        val revision = mutableIntStateOf(1)
        var controller: Any = Any()
        val visible = mutableStateOf(true)
        class Command(val target: EntryLink, val candidates: List<WordHit>, val revision: Int, val token: Any) {
            val started = kotlinx.coroutines.CompletableDeferred<Unit>()
            val finished = kotlinx.coroutines.CompletableDeferred<Unit>()
            var cancelled = false
            var result: WordHit? = null
        }
        val command = mutableStateOf<Command?>(null)
        val returned = mutableListOf<Pair<EntryLink, WordHit?>>()
        fun row(hit: WordHit) = hasClickAction() and hasText(hit.title) and hasText(hit.language) and hasText(sourceLabel(hit.edition))
        val dialog = isDialog()
        fun list() = compose.onNode(SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsActions.ScrollToIndex)
            and hasAnyAncestor(dialog))
        fun start(): Command {
            lateinit var next: Command
            var previous: EntryLinkChoiceState.Request? = null
            compose.runOnIdle {
                previous = chooser.pending
                next = Command(original, hits, revision.intValue, controller)
                command.value = next
            }
            compose.waitUntil(5000) { next.started.isCompleted && chooser.pending != null && chooser.pending !== previous }
            compose.waitForIdle()
            compose.runOnIdle {
                val request = checkNotNull(chooser.pending)
                assertSame(original, request.target)
                assertEquals(hits.map { it.key }, request.hits.map { it.key })
                request.hits.zip(hits).forEach { (actual, source) -> assertSame(source, actual) }
            }
            return next
        }
        fun completed(value: Command, hit: WordHit?) {
            compose.waitUntil(5000) { value.finished.isCompleted }
            compose.waitForIdle()
            compose.runOnIdle {
                assertFalse(value.cancelled); assertSame(hit, value.result)
                assertNull(chooser.pending)
                assertSame(original, returned.last().first)
            }
            compose.onNode(dialog).assertDoesNotExist()
        }
        fun chooseWithKey(hit: WordHit, key: androidx.compose.ui.input.key.Key) {
            list().performScrollToNode(row(hit))
            // Dialog has its own Compose owner. Use that real View's keyboard-focus
            // transition, the same public operation used by its InputModeManager.
            val dialogView = (checkNotNull(compose.onNode(dialog).fetchSemanticsNode().root)
                as androidx.compose.ui.platform.ViewRootForTest).view
            compose.runOnIdle { assertTrue(dialogView.requestFocusFromTouch()) }
            compose.waitForIdle()
            compose.runOnIdle { assertFalse(dialogView.isInTouchMode) }
            compose.onNode(row(hit)).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus) {
                assertTrue(it())
            }
            compose.onNode(row(hit)).assertIsFocused().performKeyInput { pressKey(key) }
        }
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f)) {
                        Text("Original reader remains mounted", Modifier.testTag("choice-underlying-reader"))
                        if (visible.value) {
                            androidx.compose.runtime.DisposableEffect(chooser) {
                                onDispose { chooser.cancel() }
                            }
                            androidx.compose.runtime.LaunchedEffect(revision.intValue) { chooser.cancelIfStale() }
                            val current = command.value
                            androidx.compose.runtime.LaunchedEffect(current) {
                                if (current != null) {
                                    current.started.complete(Unit)
                                    try {
                                        current.result = chooser.choose(current.target, current.candidates) {
                                            controller === current.token && revision.intValue == current.revision
                                        }
                                        returned += current.target to current.result
                                    } catch (_: kotlinx.coroutines.CancellationException) {
                                        current.cancelled = true
                                    } finally { current.finished.complete(Unit) }
                                }
                            }
                            EntryLinkChoiceDialog(chooser)
                        }
                    }
                }
            } }
            val pointer = start()
            compose.onNodeWithText("Choose an entry for ${original.title}").assertIsDisplayed()
            compose.onNodeWithTag("choice-underlying-reader").assertExists()
            // All original same-title owners remain reachable in the bounded list, including
            // the later source editions below its viewport. No title-only deduplication.
            hits.forEach { hit ->
                list().performScrollToNode(row(hit))
                compose.onNode(row(hit)).assertIsDisplayed().assertIsEnabled()
            }
            val range = list().fetchSemanticsNode().config[
                androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange]
            assertTrue(range.maxValue() > 0f)
            compose.onNode(row(hits.last())).performTouchInput { click() }
            completed(pointer, hits.last())
            val enter = start()
            chooseWithKey(hits[1], androidx.compose.ui.input.key.Key.Enter)
            completed(enter, hits[1])
            val space = start()
            chooseWithKey(hits[2], androidx.compose.ui.input.key.Key.Spacebar)
            completed(space, hits[2])
            val accessibility = start()
            list().performScrollToNode(row(hits[0]))
            compose.onNode(row(hits[0])).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick) {
                assertTrue(it())
            }
            completed(accessibility, hits[0])
            val dismissed = start()
            compose.onNodeWithText("Cancel").performClick()
            completed(dismissed, null)
            compose.runOnIdle { assertEquals(5, returned.size) }

            val staleRevision = start()
            compose.runOnIdle {
                val old = checkNotNull(chooser.pending)
                revision.intValue++
                // Deliberately precede the revision LaunchedEffect: the click's own
                // synchronous guard must reject the stale candidate.
                chooser.complete(old, hits[0])
                assertNull(chooser.pending)
            }
            compose.waitUntil(5000) { staleRevision.finished.isCompleted }
            compose.runOnIdle { assertTrue(staleRevision.cancelled); assertEquals(5, returned.size) }
            val newRevision = start()
            compose.runOnIdle {
                val current = checkNotNull(chooser.pending)
                chooser.cancelIfStale()
                assertSame(current, chooser.pending)
            }
            chooseWithKey(hits[3], androidx.compose.ui.input.key.Key.Enter)
            completed(newRevision, hits[3])

            val superseded = start()
            lateinit var oldRequest: EntryLinkChoiceState.Request
            compose.runOnIdle { oldRequest = checkNotNull(chooser.pending) }
            val successor = start()
            compose.waitUntil(5000) { superseded.finished.isCompleted }
            compose.runOnIdle {
                val current = checkNotNull(chooser.pending)
                assertTrue(superseded.cancelled)
                chooser.complete(oldRequest, hits[4])
                assertSame(current, chooser.pending)
                assertEquals(6, returned.size)
            }
            list().performScrollToNode(row(hits[4]))
            compose.onNode(row(hits[4])).performClick()
            completed(successor, hits[4])

            val detachedController = start()
            compose.runOnIdle {
                val old = checkNotNull(chooser.pending)
                controller = Any()
                chooser.complete(old, hits[0])
            }
            compose.waitUntil(5000) { detachedController.finished.isCompleted }
            compose.runOnIdle { assertTrue(detachedController.cancelled); assertEquals(7, returned.size) }
            val disposal = start()
            compose.runOnIdle { visible.value = false }
            compose.waitUntil(5000) { disposal.finished.isCompleted }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue(disposal.cancelled); assertNull(chooser.pending)
                assertEquals(7, returned.size)
                returned.forEach { assertSame(original, it.first) }
            }
            compose.onNode(dialog).assertDoesNotExist()
            compose.onNodeWithTag("choice-underlying-reader").assertExists()
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            val bodyFailure = primary
            fun cleanup(block: () -> Unit) {
                try { block() } catch (failure: Throwable) {
                    val originalFailure = primary
                    if (originalFailure == null) primary = failure else if (originalFailure !== failure) originalFailure.addSuppressed(failure)
                }
            }
            cleanup { compose.runOnIdle { chooser.cancel(); compose.activity.setContent {} } }
            cleanup { compose.waitForIdle() }
            if (bodyFailure == null) primary?.let { throw it }
        }
    }


    @Test fun emptyPublishedEntryNoticeIsAccessibleAndClearsWhenSameEntryGainsContent() {
        val empty = Entry("czytać", emptyList(), "language", "polski", "pl", emptyList(), emptyList(),
            organization = PresentationOrganization(emptyList(), emptyList()))
        val current = mutableStateOf(empty)
        val message = "No entry content is available in this dictionary."
        try {
            compose.runOnUiThread {
                compose.activity.setContent {
                    val density = LocalDensity.current
                    CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                        DictTheme("system") {
                            androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                                Box(Modifier.fillMaxSize()) {
                                    Box(Modifier.width(280.dp).fillMaxSize().testTag("empty-entry-viewport")) {
                                        EntryView(current.value, false, {}, settings = AppSettings(collapseOtherSections = false))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            val notice = compose.onNodeWithTag("entry-empty-message")
            notice.assertIsDisplayed().assertTextEquals(message).assertHasNoClickAction()
            compose.onAllNodesWithText(message).assertCountEquals(1)
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            notice.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val layout = layouts.single()
            assertFalse(layout.didOverflowWidth); assertFalse(layout.didOverflowHeight)
            assertTrue(layout.lineCount > 0)
            assertEquals(2f, layout.layoutInput.density.fontScale, 0f)
            val bounds = notice.fetchSemanticsNode().boundsInRoot
            val viewport = compose.onNodeWithTag("empty-entry-viewport").fetchSemanticsNode().boundsInRoot
            assertEquals(with(layout.layoutInput.density) { 280.dp.toPx() }, viewport.width, 1f)
            assertTrue(bounds.left >= viewport.left && bounds.right <= viewport.right)
            compose.onNodeWithTag("entry-title").assertTextEquals("czytać")
            val populated = empty.copy(organization = null, sections = listOf(Section(3, "Meaning",
                listOf(Block("definition", 0, listOf(Span("text", "Retained definition")))))))
            for (entry in listOf(populated,
                empty.copy(preamble = listOf(Span("text", "Retained preamble"))),
                empty.copy(kind = "alias"),
                empty.copy(media = listOf(Media("Retained.ogg", "audio", "Retained audio"))),
                empty.copy(references = listOf(Reference(1, 1L, "", listOf(Span("text", "Retained reference"))))))) {
                compose.runOnIdle { current.value = entry }
                notice.assertDoesNotExist()
                compose.onNodeWithTag("entry-title").assertTextEquals("czytać")
            }
            compose.runOnIdle { current.value = empty }
            notice.assertIsDisplayed().assertTextEquals(message)
        } finally {
            compose.runOnUiThread { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }
}
