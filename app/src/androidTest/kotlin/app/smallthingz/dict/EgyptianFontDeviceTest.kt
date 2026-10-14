package app.smallthingz.dict

import android.os.Build
import android.accessibilityservice.AccessibilityServiceInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.atomic.AtomicReference
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import android.graphics.Paint
import android.graphics.RectF
import kotlinx.coroutines.runBlocking
import java.nio.ByteBuffer
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import kotlin.math.ceil
import kotlin.math.floor
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import java.security.MessageDigest
import java.util.Locale
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Synthetic renderer contract using the source-backed seven-scalar Egyptian witness. */
@OptIn(ExperimentalTextApi::class)
class EgyptianFontDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val witness = "𓂜𓐰𓏏𓐱𓏭𓅪𓆑"
    private val expectedFontSha = "360528e3c216b9d75d73b531e5423370c5c28bf1c847eeb79f54ed0bb015dbf7"

    @Test fun onlyExactEgypClassUsesBundledFontAndKeepsTextLinksAndCodeStyle() {
        val before = "Before "
        val after = " after."
        val isolated = "\u2066$witness\u2069"
        val entry = Entry("Egyptian font fixture", emptyList(), "language", "Egyptian", "egy",
            listOf(Section(3, "Noun", listOf(
                Block("definition", 1, listOf(
                    Span("text", before),
                    Span("link", witness, target = "jwtj-n.f", language = "egy", classes = "headword\tEgyp\n", direction = "ltr"),
                    Span("text", after))),
                Block("paragraph", 0, listOf(
                    Span("text", "Near-match", classes = "NotEgyp EgypExtra egyp"),
                    Span("text", " / code", classes = "Egyp", code = true)))
            ))), emptyList())
        val clicked = AtomicReference<String?>()
        val clipboard = AtomicReference<RecordingClipboard?>()
        compose.runOnUiThread {
            compose.activity.setContent {
                val platform = LocalClipboard.current
                val recording = remember(platform) { RecordingClipboard(platform) }
                SideEffect { clipboard.set(recording) }
                CompositionLocalProvider(LocalClipboard provides recording) {
                    MaterialTheme { EntryView(entry, false, {}, onLink = { clicked.set(it) }, settings = AppSettings(collapseDetails = false)) }
                }
            }
        }
        val expected = before + isolated + after
        compose.waitUntil(10000) {
            compose.onAllNodesWithText(expected, useUnmergedTree = true)
                .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
        val node = compose.onNodeWithText(expected, useUnmergedTree = true)
        node.assertIsDisplayed()
        if (Build.VERSION.SDK_INT >= 31) awaitShaped(expected, 1)
        val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertEquals(expected, text.text)
        val family = FontFamily(Font(R.font.egyptian_hieroglyphs))
        val selected = text.spanStyles.single { it.item.fontFamily == family }
        assertEquals(before.length, selected.start)
        assertEquals(before.length + isolated.length, selected.end)
        assertEquals("egy", selected.item.localeList!!.single().toLanguageTag())
        assertEquals(0.sp, selected.item.letterSpacing)
        val link = text.getLinkAnnotations(selected.start, selected.end).single()
        assertEquals("jwtj-n.f", (link.item as LinkAnnotation.Clickable).tag)
        assertEquals(selected.start, link.start)
        assertEquals(selected.end, link.end)
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertEquals(text, layouts.single().layoutInput.text)
        assertFalse(layouts.single().hasVisualOverflow)
        val inherited = layouts.single().layoutInput.style
        assertEquals(16.sp, inherited.fontSize)
        assertEquals(0.5.sp, inherited.letterSpacing)
        assertEquals(0.sp, inherited.toSpanStyle().merge(selected.item).letterSpacing)
        val ordinary = compose.onNodeWithText("Near-match / code", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.Text].single()
        assertFalse(ordinary.spanStyles.any { it.item.fontFamily == family })
        val code = ordinary.spanStyles.single { it.item.fontFamily == FontFamily.Monospace }
        assertEquals("Near-match".length, code.start)
        assertEquals(ordinary.length, code.end)
        assertEquals(TextUnit.Unspecified, code.item.letterSpacing)
        assertTrue(ordinary.spanStyles.all { it.item.letterSpacing == TextUnit.Unspecified })
        val glyphRect = if (Build.VERSION.SDK_INT >= 31) layouts.single().placeholderRects.single()!!
            else layouts.single().getBoundingBox(before.length + 1)
        node.performTouchInput { click(glyphRect.center) }
        compose.waitUntil(10000) { clicked.get() == "jwtj-n.f" }
        val recording = checkNotNull(clipboard.get())
        copyThroughVisibleToolbar(node, layouts.single(), expected, recording)
        val ordinaryNode = compose.onNodeWithText("Near-match / code", useUnmergedTree = true)
        copyThroughVisibleToolbar(ordinaryNode, textLayout(ordinaryNode), "Near-match / code", recording)
    }

    @SdkSuppress(minSdkVersion = 31)
    @Test fun bundledFontShapesTheActualVerticalAndHorizontalWitnessOnAndroid() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bytes = context.resources.openRawResource(R.font.egyptian_hieroglyphs).use { it.readBytes() }
        assertEquals(expectedFontSha, sha256(bytes))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = context.resources.getFont(R.font.egyptian_hieroglyphs)
            textSize = 100f
            textLocale = Locale.forLanguageTag("egy")
        }
        val shapedRuns = mutableListOf<Pair<String, EgyptianGlyphRun>>()
        fun shape(text: String): EgyptianGlyphRun = runBlocking {
            EgyptianShaper.shape(context, text, paint.textSize)
        }.also { shapedRuns.add(text to it) }
        fun geometryDiagnostics(): String = buildString {
            appendLine("EGYPTIAN_GEOMETRY textSize=${paint.textSize} scaleX=${paint.textScaleX} skewX=${paint.textSkewX} flags=${paint.flags} letterSpacing=${paint.letterSpacing} hinting=${paint.hinting} locales=${paint.textLocales.toLanguageTags()} features=${paint.fontFeatureSettings} typeface=${paint.typeface}")
            val fontInfo = mutableMapOf<android.graphics.fonts.Font, Int>()
            for ((text, glyphs) in shapedRuns.take(4)) {
                val scalars = text.codePoints().toArray().joinToString(",") { "U+${it.toString(16)}" }
                appendLine("RUN input=$scalars count=${glyphs.glyphCount()} advance=${glyphs.advance} ascent=${glyphs.ascent} descent=${glyphs.descent}")
                var visibleIndex = 0
                for (index in 0 until minOf(glyphs.glyphCount(), 256)) {
                    val font = glyphs.getFont(index)
                    val identity = fontInfo.getOrPut(font) {
                        val buffer = font.buffer.duplicate().apply { position(0) }
                        val actual = ByteArray(buffer.remaining()).also { buffer.get(it) }
                        val number = fontInfo.size
                        appendLine("FONT index=$number sha256=${sha256(actual)} style=${font.style} ttcIndex=${font.ttcIndex} axes=${font.axes?.contentToString()}")
                        for (spacingId in intArrayOf(38068, 38082)) {
                            val spacingBounds = RectF()
                            val spacingAdvance = font.getGlyphBounds(spacingId, paint, spacingBounds)
                            appendLine("SPACING font=$number id=$spacingId nativeAdvance=$spacingAdvance local=$spacingBounds")
                        }
                        number
                    }
                    val id = glyphs.getGlyphId(index)
                    val local = RectF()
                    val nativeAdvance = font.getGlyphBounds(id, paint, local)
                    val x = glyphs.getGlyphX(index)
                    val y = glyphs.getGlyphY(index)
                    val translated = RectF(local).apply { offset(x, y) }
                    val drawing = if (local.isEmpty) "none" else (visibleIndex++).toString()
                    appendLine("GLYPH raw=$index visible=$drawing id=$id font=$identity nativeAdvance=$nativeAdvance position=($x,$y) local=$local translated=$translated empty=${local.isEmpty}")
                }
                if (glyphs.glyphCount() > 256) appendLine("TRUNCATED glyphs omitted=${glyphs.glyphCount() - 256}")
            }
            if (shapedRuns.size > 4) appendLine("TRUNCATED runs omitted=${shapedRuns.size - 4}")
        }
        fun visible(glyphs: EgyptianGlyphRun): List<RectF> {
            val fonts = (0 until glyphs.glyphCount()).map { glyphs.getFont(it) }.distinct()
            for (font in fonts) {
                val buffer = font.buffer.duplicate().apply { position(0) }
                val actual = ByteArray(buffer.remaining()).also { buffer.get(it) }
                assertEquals("Unexpected fallback font", expectedFontSha, sha256(actual))
            }
            return (0 until glyphs.glyphCount()).mapNotNull { index ->
                val id = glyphs.getGlyphId(index)
                assertNotEquals("Missing shaped glyph", 0, id)
                val bounds = RectF()
                glyphs.getFont(index).getGlyphBounds(id, paint, bounds)
                if (bounds.isEmpty) null else bounds.apply {
                    offset(glyphs.getGlyphX(index), glyphs.getGlyphY(index))
                }
            }
        }
        try {
            val joined = shape(witness)
            val signs = visible(joined)
            assertEquals("Exactly five visible signs; join controls must not become boxes", 5, signs.size)
            assertTrue("D35 above lower t/y pair", signs[0].bottom < minOf(signs[1].top, signs[2].top))
            assertTrue("t left of y", signs[1].right < signs[2].left)
            assertTrue("nDs and f follow the first quadrat", signs[0].right < signs[3].left && signs[3].right < signs[4].left)
            val plain = shape("𓂜𓏏𓏭𓅪𓆑")
            assertEquals(5, visible(plain).size)
            assertTrue("Controls must alter layout", joined.advance < plain.advance)
            val vertical = visible(shape("𓂜𓐰𓏏"))
            assertEquals(2, vertical.size)
            assertTrue("Vertical join keeps logical first sign above second", vertical[0].bottom < vertical[1].top)
            val horizontal = visible(shape("𓏏𓐱𓏭"))
            assertEquals(2, horizontal.size)
            assertTrue("Horizontal join keeps logical order", horizontal[0].right < horizontal[1].left)
        } catch (failure: AssertionError) {
            runCatching {
                // Collect the existing comparison cases only after failure;
                // these diagnostic shapes do not replace their success assertions.
                for (text in arrayOf("𓂜𓏏𓏭𓅪𓆑", "𓂜𓐰𓏏", "𓏏𓐱𓏭")) {
                    if (shapedRuns.none { it.first == text }) shape(text)
                }
                val diagnostics = geometryDiagnostics()
                val bounded = diagnostics.take(65536) + if (diagnostics.length > 65536) "\nTRUNCATED diagnostic characters omitted=${diagnostics.length - 65536}" else ""
                failure.addSuppressed(AssertionError(bounded))
            }.onFailure { failure.addSuppressed(AssertionError("EGYPTIAN_GEOMETRY diagnostic error=$it")) }
            throw failure
        }
    }

    @Test
    @SdkSuppress(minSdkVersion = 31)
    fun privateShaperRejectsInvalidBuffersUtf16AndOverflowingMetrics() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // Load through the production path first, binding the selected engine and resource font.
        val ordinary = runBlocking { EgyptianShaper.shape(context, "𓀀𓀀", 100f) }
        assertEquals("11.4.4", EgyptianNative.version())
        assertTrue(ordinary.advance.isFinite() && ordinary.advance > 0f)
        val original = ordinary.getFont(0).buffer.duplicate().apply { clear() }
        val direct = ByteBuffer.allocateDirect(original.remaining()).apply { put(original); flip() }
        assertThrows(IllegalArgumentException::class.java) {
            EgyptianNative.shape(ByteBuffer.allocate(direct.capacity()), "𓀀")
        }
        assertThrows(IllegalArgumentException::class.java) {
            EgyptianNative.shape(direct, "\uD800")
        }
        assertThrows(IllegalArgumentException::class.java) {
            EgyptianNative.shape(direct, "𓀀".repeat(16385))
        }
        val failure = runCatching {
            runBlocking { EgyptianShaper.shape(context, "𓀀𓀀", Float.MAX_VALUE) }
        }.exceptionOrNull()
        assertTrue("Oversized advance must not reach Canvas", failure is IllegalStateException)
        // Refusals must release all per-call state and leave the shared read-only font usable.
        val after = runBlocking { EgyptianShaper.shape(context, "𓀀𓀀", 100f) }
        assertEquals(ordinary.advance, after.advance, 0f)
        assertArrayEquals(ordinary.glyphIds, after.glyphIds)
        assertArrayEquals(ordinary.positions, after.positions, 0f)
    }


    @Test
    @SdkSuppress(minSdkVersion = 31)
    fun nativeInlineLayoutPreservesOriginalParagraphDirectionAndFitsNarrowRuns() {
        data class Case(val spans: List<Span>, val expected: String,
                        val directions: List<ResolvedTextDirection>, val fallback: LayoutDirection = LayoutDirection.Ltr,
                        val mustScale: Boolean = false, val mustCopy: Boolean = false)
        val short = "𓀀" + String(Character.toChars(0x13447))
        val long = witness.repeat(12)
        val cases = listOf(
            Case(listOf(Span("text", witness, classes = "Egyp"), Span("text", " العربية")),
                "\u2066$witness\u2069 العربية", listOf(ResolvedTextDirection.Ltr), LayoutDirection.Rtl),
            Case(listOf(Span("text", "العربية "), Span("text", witness, classes = "Egyp")),
                "العربية \u2066$witness\u2069", listOf(ResolvedTextDirection.Rtl)),
            Case(listOf(Span("text", witness, classes = "Egyp", direction = "auto"), Span("text", " العربية")),
                "\u2068\u2066$witness\u2069\u2069 العربية", listOf(ResolvedTextDirection.Rtl)),
            Case(listOf(Span("text", witness, classes = "Egyp", direction = "rtl"), Span("text", " Latin")),
                "\u2067\u2066$witness\u2069\u2069 Latin", listOf(ResolvedTextDirection.Ltr)),
            Case(listOf(Span("text", short, classes = "Egyp"), Span("text", " العربية")),
                "\u2066$short\u2069 العربية", listOf(ResolvedTextDirection.Ltr)),
            Case(listOf(Span("text", witness, classes = "Egyp"), Span("line_break", ""),
                        Span("text", "العربية "), Span("text", witness, classes = "Egyp")),
                "\u2066$witness\u2069\nالعربية \u2066$witness\u2069", listOf(ResolvedTextDirection.Ltr, ResolvedTextDirection.Rtl)),
            // Object-boundary wrapping is intentional; copied scalars stay intact.
            Case(listOf(Span("text", "Latin"), Span("text", witness, classes = "Egyp"), Span("text", "Latin")),
                "Latin\u2066$witness\u2069Latin", listOf(ResolvedTextDirection.Ltr), mustCopy = true),
            Case(listOf(Span("text", long, classes = "Egyp")), "\u2066$long\u2069",
                listOf(ResolvedTextDirection.Ltr), mustScale = true)
        )
        val clipboard = AtomicReference<RecordingClipboard?>()
        val requiredWidth = AtomicReference<Int?>()
        var selected by mutableStateOf(cases.first())
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme {
                    val current = selected
                    val platform = LocalClipboard.current
                    val recording = remember(platform) { RecordingClipboard(platform) }
                    val widthPixels = with(LocalDensity.current) { 96.dp.roundToPx() }
                    SideEffect { clipboard.set(recording); requiredWidth.set(widthPixels) }
                    CompositionLocalProvider(LocalLayoutDirection provides current.fallback, LocalClipboard provides recording) {
                        StyledText(current.spans, Modifier.width(96.dp), preserveWhitespace = true)
                    }
                }
            }
        }
        for (case in cases) {
            compose.runOnIdle { selected = case }
            val count = egyptianTextRuns(case.spans).size
            awaitShaped(case.expected, count)
            val node = compose.onNodeWithText(case.expected, useUnmergedTree = true)
            node.assertIsDisplayed()
            val semantic = node.fetchSemanticsNode().config
            assertEquals(case.expected, semantic[SemanticsProperties.Text].single().text)
            val layout = textLayout(node)
            assertEquals("Native Text must honor the fixed parent width", checkNotNull(requiredWidth.get()), layout.size.width)
            assertFalse("Native text must fit the actual narrow viewport", layout.hasVisualOverflow)
            assertEquals(count, layout.placeholderRects.size)
            for (rect in layout.placeholderRects) {
                assertNotNull("Every original run must have a visible placeholder", rect)
                assertTrue(rect!!.left >= -1f && rect.right <= layout.size.width + 1f)
                assertTrue(rect.top >= -1f && rect.bottom <= layout.size.height + 1f)
            }
            var start = 0
            for (direction in case.directions) {
                assertEquals("Original logical paragraph base at $start", direction, layout.getParagraphDirection(start))
                if (direction == ResolvedTextDirection.Rtl) {
                    val right = layout.getLineRight(layout.getLineForOffset(start))
                    assertTrue("RTL start alignment uses the full parent width", right >= layout.size.width - 2f && right <= layout.size.width + 1f)
                }
                val newline = case.expected.indexOf('\n', start)
                start = if (newline < 0) case.expected.length else newline + 1
            }
            val scales = semantic[EgyptianVisibleScales]
            assertEquals(count, scales.size)
            assertTrue(scales.all { it.isFinite() && it > 0f && it <= 1f })
            if (case.mustScale) assertTrue("Whole long run must be uniformly fitted", scales.single() < 1f)
            if (case.mustCopy) {
                assertTrue("Unspaced native object may wrap at its boundary in a narrow viewport", layout.lineCount > 1)
                copyThroughVisibleToolbar(node, layout, case.expected, checkNotNull(clipboard.get()), selectAllRequired = false)
            }
        }
    }


    @Test
    @SdkSuppress(minSdkVersion = 31)
    fun nativeSuperscriptAndSubscriptMoveActualRenderedInk() {
        val entry = Entry("Egyptian shifted ink", emptyList(), "language", "Egyptian", "egy",
            listOf(Section(3, "Noun", listOf(Block("definition", 1, listOf(
                Span("text", "N "), Span("link", witness, target = "normal", classes = "Egyp"),
                Span("text", " S "), Span("link", witness, target = "super", classes = "Egyp", superscript = true),
                Span("text", " B "), Span("link", witness, target = "sub", classes = "Egyp", subscript = true)
            ))))), emptyList())
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme(colorScheme = lightColorScheme(primary = Color.Red)) {
                    EntryView(entry, false, {}, settings = AppSettings(collapseDetails = false))
                }
            }
        }
        val expected = "N \u2066$witness\u2069 S \u2066$witness\u2069 B \u2066$witness\u2069"
        awaitShaped(expected, 3)
        val node = compose.onNodeWithText(expected, useUnmergedTree = true)
        node.assertIsDisplayed()
        val layout = textLayout(node)
        assertEquals("Comparison glyphs must share an actual line baseline", 1, layout.lineCount)
        assertFalse(layout.hasVisualOverflow)
        val boxes = layout.placeholderRects.map { checkNotNull(it) }
        assertEquals(3, boxes.size)
        val image = node.captureToImage().toPixelMap()
        fun redAt(x: Int, y: Int): Boolean {
            val color = image[x, y]
            return color.alpha > 0.5f && color.red > 0.65f && color.green < 0.35f && color.blue < 0.35f
        }
        val inkBottom = boxes.map { box ->
            var bottom = -1
            for (y in floor(box.top).toInt().coerceAtLeast(0) until ceil(box.bottom).toInt().coerceAtMost(image.height)) {
                for (x in floor(box.left).toInt().coerceAtLeast(0) until ceil(box.right).toInt().coerceAtMost(image.width)) {
                    if (redAt(x, y)) bottom = maxOf(bottom, y)
                }
            }
            assertTrue("Each passive native Canvas must actually draw its original signs", bottom >= 0)
            bottom
        }
        assertTrue("Superscript ink must rise above the normal glyph baseline", inkBottom[1] + 1 < inkBottom[0])
        assertTrue("Subscript ink must descend below the normal glyph baseline", inkBottom[2] > inkBottom[0] + 1)
        for (y in 0 until image.height) for (x in 0 until image.width) {
            if (redAt(x, y)) assertTrue("Native shifted ink must stay within reserved line boxes", boxes.any {
                x >= floor(it.left) && x < ceil(it.right) && y >= floor(it.top) && y < ceil(it.bottom)
            })
        }
    }

    private fun awaitShaped(text: String, count: Int) {
        compose.waitUntil(10000) {
            compose.onAllNodesWithText(text, useUnmergedTree = true)
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .singleOrNull()?.config?.getOrNull(EgyptianShapedRunCount) == count
        }
    }

    private fun textLayout(node: SemanticsNodeInteraction): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
        return results.single()
    }

    private class RecordingClipboard(private val platform: Clipboard) : Clipboard by platform {
        @Volatile var copied: ClipEntry? = null
        override suspend fun getClipEntry(): ClipEntry? = copied
        override suspend fun setClipEntry(clipEntry: ClipEntry?) { copied = clipEntry }
    }

    private fun copyThroughVisibleToolbar(node: SemanticsNodeInteraction, layout: TextLayoutResult,
                                          expected: String, recording: RecordingClipboard, selectAllRequired: Boolean = true) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val originalFlags = automation.serviceInfo.flags
        val diagnostics = CopyDiagnostics()
        try {
            // Use the instrumentation connection to inspect this app's separate
            // non-focusable popup windows; do not start another automation service.
            automation.serviceInfo = automation.serviceInfo.apply {
                flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
            recording.copied = null
            captureCopyState(diagnostics, "before-longClick", node, expected)
            node.performTouchInput { longClick(layout.getBoundingBox(1).center) }
            // Multiword fixtures must select the whole block before copying.
            // Only the observed unspaced whole-selection fixture skips this action.
            captureCopyState(diagnostics, "before-SelectAll", node, expected)
            if (selectAllRequired) {
                clickOwnedToolbarAction(android.R.string.selectAll, diagnostics = diagnostics)
                compose.waitForIdle()
                captureCopyState(diagnostics, "after-SelectAll-idle", node, expected)
            }
            captureCopyState(diagnostics, "before-Copy", node, expected)
            clickOwnedToolbarAction(android.R.string.copy, diagnostics = diagnostics)
            compose.waitUntil(10000) { recording.copied != null }
            val copied = checkNotNull(recording.copied).clipData
            captureCopyState(diagnostics, "after-recorded-Copy", node, expected)
            assertEquals(1, copied.itemCount)
            assertEquals("Original scalars and explicit direction controls must survive actual copy",
                expected, copied.getItemAt(0).text.toString())
            previousCopyDiagnostics = diagnostics.finish()
        } catch (failure: Throwable) {
            if (failure is VirtualMachineError || failure is java.util.concurrent.CancellationException) throw failure
            failure.addSuppressed(AssertionError("COPY_DIAGNOSTICS current\n" + diagnostics.finish()))
            previousCopyDiagnostics?.let { failure.addSuppressed(AssertionError("COPY_DIAGNOSTICS preceding successful call\n" + it)) }
            throw failure
        } finally {
            automation.serviceInfo = automation.serviceInfo.apply { flags = originalFlags }
        }
    }

    private fun ownedToolbarRoots(): List<AccessibilityNodeInfo> {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val active = automation.rootInActiveWindow ?: return emptyList()
        val owner = compose.activity.packageName
        if (active.packageName?.toString() != owner) return emptyList()
        val roots = listOf(active) + automation.windows
            .filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
            .mapNotNull { it.root }
        return roots.filter { it.packageName?.toString() == owner }.distinctBy { it.windowId }
    }

    private fun clickOwnedToolbarAction(vararg labelResources: Int, diagnostics: CopyDiagnostics? = null): Int {
        val labels = labelResources.map { it to compose.activity.getString(it) }
        var ready: Pair<Int, AccessibilityNodeInfo>? = null
        compose.waitUntil(10000) {
            val roots = ownedToolbarRoots()
            for ((resource, label) in labels) {
                val matches = roots.flatMap { root ->
                    root.findAccessibilityNodeInfosByText(label).filter {
                        it.isVisibleToUser && it.text?.toString() == label && it.windowId == root.windowId
                    }
                }
                if (matches.isEmpty()) continue
                if (matches.size != 1) return@waitUntil false
                var current: AccessibilityNodeInfo? = matches.single()
                val windowId = current!!.windowId
                repeat(4) {
                    val candidate = current ?: return@repeat
                    if (candidate.isClickable && candidate.isEnabled) {
                        ready = resource to candidate
                        return@waitUntil true
                    }
                    current = candidate.parent?.takeIf { it.windowId == windowId }
                }
                return@waitUntil false
            }
            false
        }
        // Readiness polling never sends an action. Revalidate this same owned
        // application window and click once, retaining a false acknowledgement.
        val (resource, target) = checkNotNull(ready)
        val root = checkNotNull(ownedToolbarRoots().singleOrNull { it.windowId == target.windowId })
        assertEquals(compose.activity.packageName, root.packageName?.toString())
        assertEquals(root.windowId, target.windowId)
        assertTrue(target.refresh())
        assertTrue(target.isVisibleToUser && target.isEnabled && target.isClickable)
        diagnostics?.append("clicked resource=$resource " + diagnosticNode(target))
        assertTrue("Owned toolbar action must acknowledge its single click", target.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        return resource
    }


    // Only a failure emits evidence: current call and one preceding successful call.
    private var previousCopyDiagnostics: String? = null
    private class CopyDiagnostics {
        private val text = StringBuilder()
        private var truncated = false
        fun append(value: String) {
            val available = 16352 - text.length
            if (available <= 0) { truncated = true; return }
            val bounded = value.take(available - 1) + "\n"
            text.append(bounded)
            if (bounded.length < value.length + 1) truncated = true
        }
        fun finish(): String = text.toString() + "truncated=$truncated"
    }
    private fun diagnosticValue(value: CharSequence?): String = value?.take(192)?.toString()
        ?.replace("\\", "\\\\")?.replace("\n", "\\n")?.replace("\r", "\\r")?.replace("\t", "\\t") ?: "null"
    private fun diagnosticNode(node: AccessibilityNodeInfo): String =
        "window=${node.windowId} package=${diagnosticValue(node.packageName)} class=${diagnosticValue(node.className)} " +
            "viewId=${diagnosticValue(node.viewIdResourceName)} visible=${node.isVisibleToUser} " +
            "enabled=${node.isEnabled} clickable=${node.isClickable} selected=${node.isSelected} focused=${node.isFocused} " +
            "bounds=${android.graphics.Rect().also { node.getBoundsInScreen(it) }.toShortString()} selection=${node.textSelectionStart}:${node.textSelectionEnd}"
    private fun captureCopyState(diagnostics: CopyDiagnostics, phase: String,
                                 node: SemanticsNodeInteraction, expected: String) {
        diagnostics.append("phase=$phase fixture=${diagnosticValue(expected)} length=${expected.length}")
        try {
            val range = node.fetchSemanticsNode().config.getOrNull(SemanticsProperties.TextSelectionRange)
            diagnostics.append("compose-selection=" + (range?.let { "${it.start}:${it.end}" } ?: "absent"))
            val roots = ownedToolbarRoots()
            diagnostics.append("owned-roots=${roots.size} truncated-roots=${roots.size > 8}")
            for (root in roots.take(8)) {
                diagnostics.append("root " + diagnosticNode(root))
                val exact = root.findAccessibilityNodeInfosByText(expected)
                    .filter { it.text?.toString() == expected && it.windowId == root.windowId }
                diagnostics.append("exact-fixture-nodes=${exact.size} truncated=${exact.size > 8}")
                for (match in exact.take(8)) diagnostics.append("fixture-node " + diagnosticNode(match))
                for (resource in listOf(android.R.string.selectAll, android.R.string.copy)) {
                    val label = compose.activity.getString(resource)
                    val matches = root.findAccessibilityNodeInfosByText(label)
                        .filter { it.text?.toString() == label && it.windowId == root.windowId }
                    diagnostics.append("menu-resource=$resource matches=${matches.size} truncated=${matches.size > 8}")
                    for (match in matches.take(8)) {
                        var current: AccessibilityNodeInfo? = match
                        repeat(4) { depth ->
                            val ancestor = current
                            if (ancestor != null) {
                                diagnostics.append("menu-depth=$depth " + diagnosticNode(ancestor))
                                current = ancestor.parent?.takeIf { it.windowId == root.windowId }
                            }
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            if (error is VirtualMachineError || error is java.util.concurrent.CancellationException) throw error
            diagnostics.append("capture-error=" + error.javaClass.name)
        }
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }
}
