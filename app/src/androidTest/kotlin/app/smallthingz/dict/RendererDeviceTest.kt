package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.mutableStateOf
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
    // Only the named owned test viewport is captured, before finally clears it.
    // A failed/oversize capture supplements, and never replaces, the overflow assertion.
    val capture = runCatching {
        val bitmap = viewport.captureToImage().asAndroidBitmap()
        try {
            val bytes = java.io.ByteArrayOutputStream()
            val limit = 64 * 1024
            val bounded = object : java.io.OutputStream() {
                override fun write(value: Int) {
                    if (bytes.size() >= limit) throw java.io.IOException("Owned PNG exceeds 65536 bytes")
                    bytes.write(value)
                }
                override fun write(data: ByteArray, offset: Int, length: Int) {
                    if (length > limit - bytes.size()) throw java.io.IOException("Owned PNG exceeds 65536 bytes")
                    bytes.write(data, offset, length)
                }
            }
            check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bounded))
            val png = bytes.toByteArray()
            val sha = java.security.MessageDigest.getInstance("SHA-256").digest(png)
                .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
            "\nOWNED_PNG_BEGIN " + imageName + " bytes=" + png.size + " sha256=" + sha +
                " width=" + bitmap.width + " height=" + bitmap.height + "\n" +
                android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP) +
                "\nOWNED_PNG_END " + imageName
        } finally { bitmap.recycle() }
    }.getOrElse { "\nOWNED_PNG_UNAVAILABLE " + imageName + " " + it.javaClass.name + ": " + it.message }
    return details + viewportDetails + capture
}

/** Read only the admitted test Activity's own view/configuration, on its UI thread. */
internal fun ownedLayoutState(view: android.view.View): String {
    val config = view.resources.configuration
    val visible = android.graphics.Rect().also(view::getWindowVisibleDisplayFrame)
    val insets = view.rootWindowInsets
    val ime = if (android.os.Build.VERSION.SDK_INT >= 30)
        "visible=${insets?.isVisible(android.view.WindowInsets.Type.ime())},insets=${insets?.getInsets(android.view.WindowInsets.Type.ime())}"
    else "unavailable-before-api30;visibleFrame-is-not-an-IME-inference"
    val focused = view.findFocus()
    return "ownedRoot=${view.width}x${view.height}; windowFocus=${view.hasWindowFocus()}; " +
        "focusedView=${focused?.javaClass?.name},id=${focused?.id}; visibleFrame=$visible; ime=$ime; " +
        "configFontScale=${config.fontScale}; densityDpi=${config.densityDpi}; " +
        "screenDp=${config.screenWidthDp}x${config.screenHeightDp}; orientation=${config.orientation}; " +
        "layoutDirection=${config.layoutDirection}; fontWeightAdjustment=" +
        if (android.os.Build.VERSION.SDK_INT >= 31) config.fontWeightAdjustment else "unavailable-before-api31"
}

/** The original assertion remains primary even when diagnostic reads/capture fail. */
internal fun <T> withRenderedLayoutFailureEvidence(
    label: String,
    node: androidx.compose.ui.test.SemanticsNodeInteraction,
    viewport: androidx.compose.ui.test.SemanticsNodeInteraction,
    imageName: String?,
    ownedState: () -> String,
    assertion: () -> T,
): T = try { assertion() } catch (failure: AssertionError) {
    val evidence = runCatching {
        val semantic = runCatching { node.fetchSemanticsNode() }.getOrNull()
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        runCatching { node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) } }
        val state = runCatching(ownedState).getOrElse { "OWNED_STATE_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
        renderedLayoutFailureEvidence(label, layouts.singleOrNull(), semantic, viewport, imageName) + "\n" + state
    }.getOrElse { "LAYOUT_EVIDENCE_UNAVAILABLE ${it.javaClass.name}: ${it.message}" }
    throw AssertionError(failure.message + "\n" + evidence, failure)
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
                    CompiledTableView(table, feature.value) { followed = it }
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
            listOf(Cell(listOf(Span("text", "\u00a0")), false, 1, 2, "#ff0000"),
                Cell(listOf(Span("text", "\u00a0")), true, 1, 1, "#00ff00")),
            listOf(Cell(listOf(Span("link", "Follow", target = "B")), false, 1, 1, "#0000ff"))))
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        var followed: String? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides direction.value) {
                    androidx.compose.material3.MaterialTheme { CompiledTableView(table, null) { followed = it } }
                }
            } }
            for (value in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                compose.runOnIdle { direction.value = value; followed = null }
                compose.waitForIdle()
                val image = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true).captureToImage().asAndroidBitmap()
                try {
                    val redX = if (value == androidx.compose.ui.unit.LayoutDirection.Ltr) image.width / 4 else image.width * 3 / 4
                    val otherX = image.width - redX - 1
                    assertEquals(android.graphics.Color.RED, image.getPixel(redX, image.height / 4))
                    assertEquals(android.graphics.Color.RED, image.getPixel(redX, image.height * 3 / 4))
                    assertEquals(android.graphics.Color.GREEN, image.getPixel(otherX, 2))
                    assertEquals(android.graphics.Color.BLUE, image.getPixel(otherX, image.height - 3))
                } finally { image.recycle() }
                compose.onNodeWithText("Follow").assertIsDisplayed().performClick()
                compose.runOnIdle { assertEquals("B", followed) }
                compose.onNodeWithText("Color sample #ff0000").assertDoesNotExist()
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun authoredForegroundSurvivesLinksAndNativeEgyptianPaintInBothDirections() {
        val direction = mutableStateOf(androidx.compose.ui.unit.LayoutDirection.Ltr)
        val signs = "\uD80C\uDC00"
        val spans = listOf(
            Span("link", "Green", target = "green-target", foreground = "#008000"),
            Span("text", " / "), Span("text", "Blue", foreground = "#0000ff"), Span("text", " / "),
            Span("link", signs, target = "sign-target", classes = "Egyp", direction = "ltr", foreground = "#40e0d0"))
        val expectedText = "Green / Blue / \u2066" + signs + "\u2069"
        val clicked = java.util.concurrent.CopyOnWriteArrayList<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides direction.value) {
                    androidx.compose.material3.MaterialTheme {
                        StyledText(spans, Modifier.width(300.dp).testTag("authored-foreground"), onLink = { clicked.add(it) })
                    }
                }
            } }
            for (value in listOf(androidx.compose.ui.unit.LayoutDirection.Ltr, androidx.compose.ui.unit.LayoutDirection.Rtl)) {
                compose.runOnIdle { direction.value = value; clicked.clear() }
                if (android.os.Build.VERSION.SDK_INT >= 31) compose.waitUntil(10000) {
                    compose.onAllNodes(SemanticsMatcher.expectValue(EgyptianShapedRunCount, 1), useUnmergedTree = true)
                        .fetchSemanticsNodes().isNotEmpty()
                }
                compose.waitForIdle()
                val node = compose.onNodeWithText(expectedText, useUnmergedTree = true)
                val image = compose.onNodeWithTag("authored-foreground", useUnmergedTree = true).captureToImage().asAndroidBitmap()
                try {
                    val expected = setOf(0xff008000.toInt(), 0xff0000ff.toInt(), 0xff40e0d0.toInt())
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
                for (target in listOf("green-target", "sign-target")) {
                    val range = annotated.getLinkAnnotations(0, annotated.length).single {
                        (it.item as? androidx.compose.ui.text.LinkAnnotation.Clickable)?.tag == target
                    }
                    val offset = range.start + if (target == "sign-target") 1 else 0
                    val bounds = layout.getBoundingBox(offset)
                    node.performTouchInput { click(bounds.center) }
                }
                compose.runOnIdle { assertEquals(listOf("green-target", "sign-target"), clicked.toList()) }
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

    @androidx.test.filters.SdkSuppress(minSdkVersion = 31)
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
            for (mode in listOf("ordinary", "rich-companion", "plain-companion")) {
                val companion = mode != "ordinary"
                val plain = mode == "plain-companion"
                val initialDepth = if (plain) 1 else 0
                val depth = mutableStateOf(initialDepth)
                var followed: String? = null
                var density = 0f
                var expectedWeight: androidx.compose.ui.text.font.FontWeight? = null
                fun value(): Entry {
                    val heading = Block("heading", depth.value, if (plain) listOf(Span("text", label)) else spans, listPath = ":".repeat(depth.value), level = 4)
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
                                    EntryView(value(), false, {}, onLink = { followed = it }, settings = AppSettings(collapseDetails = false, collapseOtherSections = false))
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
                    if (plain) {
                        assertTrue(text.getLinkAnnotations(0, text.length).isEmpty())
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
                    // Six bounded values stay below the Binder transaction budget; never
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
                        EntryView(entry, false, {}, onLink = { followed = it }, settings = AppSettings(collapseDetails = false))
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
        var imports = 0
        assertEquals("Isolated debug catalogue must use bundled rows", listOf(Catalog.DEFAULT), previousSources)
        try {
            compose.runOnIdle {
                runBlocking {
                    assertFalse(failures.initialize(open = { throw java.io.IOException("Owned startup failure fixture") }))
                }
                assertEquals(startupError, library.initializationError)
                library.sources.toList().forEach(library::removeSource)
            }
            library.refreshCatalogs().join()
            assertTrue(library.catalog.isEmpty())
            assertNull(library.error)
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
            compose.waitUntil(15000) { library.busy == null }
            compose.onNodeWithText(explanation).assertIsDisplayed()
            compose.onNodeWithText(startupError).assertIsDisplayed()
            compose.onNodeWithContentDescription("Import wikblb").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(1, imports) }
            compose.waitUntil(15000) { library.busy == null && library.error == importError }
            compose.onNodeWithText(importError).assertIsDisplayed()
            compose.onNodeWithContentDescription("Refresh catalogues").assertIsEnabled()
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
        } finally {
            compose.runOnIdle {
                initializationState.value = previousInitializationError
                library.sources.toList().forEach(library::removeSource)
                previousSources.forEach(library::addSource)
            }
            library.refreshCatalogs().join()
            compose.waitUntil(15000) { library.busy == null }
            assertEquals(previousSources, library.sources)
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
                    library.link(target, sourceEntry)?.takeIf { it.key != sourceHit.key }?.let { hits[target] = it }
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
            assertNull(runBlocking { library.link("absent", missingEntry) })
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
        fun assertField(value: String) {
            compose.onAllNodes(namedField).assertCountEquals(1)
            compose.onNode(namedField).assertIsDisplayed().assertIsFocused()
                .assert(SemanticsMatcher.expectValue(
                    androidx.compose.ui.semantics.SemanticsProperties.EditableText,
                    androidx.compose.ui.text.AnnotatedString(value),
                ))
        }
        try {
            compose.onNodeWithContentDescription("Dictionary").performClick()
            assertField("")
            compose.onNode(namedField).performTextInput("ca")
            assertField("ca")
            compose.onNodeWithContentDescription("Clear search").performClick()
            assertField("")
            compose.onNodeWithContentDescription("Close search").performClick()
            compose.onNodeWithTag("entry-scroll").assertExists()
            compose.onAllNodes(namedField).assertCountEquals(0)
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
            compose.onNodeWithContentDescription("Clear search").performTouchInput { click(center) }
            assertField("")
            compose.onNodeWithContentDescription("Close search").performTouchInput { click(center) }
            compose.onAllNodes(field).assertCountEquals(0)
            compose.onNodeWithTag("entry-scroll").assertExists()
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    private val retentionFocus = java.util.concurrent.atomic.AtomicReference<androidx.compose.ui.focus.FocusManager?>()

    private fun mountLearnRetentionPanel(
        words: List<SavedWord>,
        answers: MutableList<Pair<String, Boolean>>,
        opened: MutableList<SavedWord> = mutableListOf(),
    ) {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent {
                val density = LocalDensity.current
                val focus = androidx.compose.ui.platform.LocalFocusManager.current
                SideEffect { retentionFocus.set(focus) }
                CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 1f)) {
                    DictTheme(mode) {
                        Box(Modifier.width(320.dp).height(120.dp).clipToBounds().testTag("learn-retention-viewport")) {
                            // Real status/segments precede the game and can completely fill this short viewport.
                            LearnPanel(words, 3, { key, right -> answers += key to right }, { opened += it }, {},
                                sampleFailed = true)
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
        compose.runOnIdle { checkNotNull(retentionFocus.get()).clearFocus(force = true) }
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

}
