package app.smallthingz.dict

import android.os.Build
import android.accessibilityservice.AccessibilityServiceInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.ConcurrentLinkedQueue
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
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
import androidx.compose.ui.graphics.asAndroidBitmap
import kotlin.math.ceil
import kotlin.math.floor
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
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
    @get:Rule val compose = createPhysicalComposeRule()
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
        for ((caseIndex, case) in cases.withIndex()) {
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
            val caretGeometry = layout.layoutInput.placeholders.take(16).map { range ->
                val start = range.start
                val end = range.end
                if (start < 0 || end <= start || end > layout.layoutInput.text.length) {
                    "invalid placeholder range $start..$end"
                } else {
                    "$start..$end:primary=${layout.getHorizontalPosition(start, true)}..${layout.getHorizontalPosition(end, true)}," +
                        "secondary=${layout.getHorizontalPosition(start, false)}..${layout.getHorizontalPosition(end, false)}," +
                        "bidi=${layout.getBidiRunDirection(start)}..${layout.getBidiRunDirection(end - 1)}," +
                        "paragraph=${layout.getParagraphDirection(start)}," +
                        "startContext=${layout.layoutInput.text.text.substring(maxOf(0, start - 2), minOf(layout.layoutInput.text.length, start + 2)).map { it.code }}," +
                        "endContext=${layout.layoutInput.text.text.substring(maxOf(0, end - 2), minOf(layout.layoutInput.text.length, end + 2)).map { it.code }}"
                }
            }
            for ((rectIndex, rect) in layout.placeholderRects.withIndex()) {
                val geometry = "case=$caseIndex, placeholder=$rectIndex, expectedLength=${case.expected.length}, " +
                    "fallback=${case.fallback}, directions=${case.directions}, size=${layout.size}, " +
                    "constraints=${layout.layoutInput.constraints}, rect=$rect, caretGeometry=$caretGeometry, " +
                    "rects=${layout.placeholderRects.take(16)}, scales=${semantic[EgyptianVisibleScales]}, " +
                    "lines=${(0 until minOf(layout.lineCount, 16)).map { line -> "${layout.getLineStart(line)}..${layout.getLineEnd(line)}:${layout.getLineLeft(line)}..${layout.getLineRight(line)}" }}"
                assertNotNull("Every original run must have a visible placeholder: $geometry", rect)
                assertTrue("Native placeholder must fit horizontal viewport: $geometry",
                    rect!!.left >= -1f && rect.right <= layout.size.width + 1f)
                assertTrue("Native placeholder must fit vertical viewport: $geometry",
                    rect.top >= -1f && rect.bottom <= layout.size.height + 1f)
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


    /** Renderer fixture uses the exact two authored AR MdC outputs, not Arabic corpus acceptance. */
    @Test
    @SdkSuppress(minSdkVersion = 31)
    fun authoredOverlayAndCartoucheControlsKeepMixedArabicInkLinksAndToolbarCopy() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cases = listOf(
            "Tut overlay" to "𓇋𓏠𓐰𓈖𓏏𓅱𓐴𓏏𓋹",
            "Akhenaten cartouche" to "𓍹𓐼𓇋𓏏𓐰𓈖𓐰𓇳𓅜𓐍𓐰𓈖𓐽𓍺"
        )
        assertEquals(expectedFontSha, sha256(context.resources.openRawResource(R.font.egyptian_hieroglyphs).use { it.readBytes() }))
        for ((label, signs) in cases) {
            val points = signs.codePoints().toArray()
            if (label == "Tut overlay") assertEquals(1, points.count { it == 0x13434 })
            else {
                assertEquals(0x13379, points.first()); assertEquals(0x1337A, points.last())
                assertEquals(1, points.count { it == 0x1343C }); assertEquals(1, points.count { it == 0x1343D })
            }
            // Exercise the actual app-owned shaper/font, not nominal glyph count alone.
            val shaped = runBlocking { EgyptianShaper.shape(context, signs, 100f) }
            assertTrue(shaped.glyphCount() > 0)
            assertTrue(shaped.advance.isFinite() && shaped.advance > 0f)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 100f }
            val ink = RectF()
            var visible = 0
            repeat(shaped.glyphCount()) { index ->
                val bounds = RectF()
                shaped.getFont(index).getGlyphBounds(shaped.getGlyphId(index), paint, bounds)
                assertTrue(shaped.clusters[index] in signs.indices)
                if (!bounds.isEmpty) {
                    bounds.offset(shaped.getGlyphX(index), shaped.getGlyphY(index))
                    assertTrue(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).all { it.isFinite() })
                    if (visible++ == 0) ink.set(bounds) else ink.union(bounds)
                }
            }
            assertTrue("Actual signs must have finite nonempty ink: $label", visible > 0 && ink.width() > 0f && ink.height() > 0f)
            val before = "قبل "
            val after = " بعد "
            val following = "التالي"
            val expected = before + "\u2066" + signs + "\u2069" + after + following
            val entry = Entry(label, emptyList(), "language", "Arabic", "ar",
                listOf(Section(3, "الأصل والاشتقاق", listOf(Block("paragraph", 0, listOf(
                    Span("text", before), Span("link", signs, target = "egyptian-origin", language = "egy", classes = "Egyp", direction = "ltr"),
                    Span("text", after), Span("link", following, target = "following-arabic")
                ))))), emptyList())
            val clicked = mutableListOf<String>()
            val clipboard = AtomicReference<RecordingClipboard?>()
            compose.runOnUiThread {
                compose.activity.setContent {
                    val density = LocalDensity.current
                    val platform = LocalClipboard.current
                    val recording = remember(platform) { RecordingClipboard(platform) }
                    SideEffect { clipboard.set(recording) }
                    CompositionLocalProvider(LocalClipboard provides recording,
                        LocalLayoutDirection provides LayoutDirection.Rtl,
                        LocalDensity provides androidx.compose.ui.unit.Density(density.density, 2f)) {
                        MaterialTheme(colorScheme = lightColorScheme(primary = Color.Red)) {
                            androidx.compose.material3.Surface {
                                androidx.compose.foundation.layout.Box(Modifier.width(180.dp)) {
                                    EntryView(entry, false, {}, onLink = { clicked += it },
                                        settings = AppSettings(collapseOtherSections = false, collapseDetails = false))
                                }
                            }
                        }
                    }
                }
            }
            try {
                awaitShaped(expected, 1)
                val node = compose.onNodeWithText(expected, useUnmergedTree = true)
                node.assertIsDisplayed()
                val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single()
                assertEquals(expected, text.text)
                val begin = before.length
                assertArrayEquals(points, text.text.substring(begin + 1, begin + 1 + signs.length).codePoints().toArray())
                val links = text.getLinkAnnotations(0, text.length)
                assertEquals(listOf("egyptian-origin", "following-arabic"), links.map { (it.item as LinkAnnotation.Clickable).tag })
                val layout = textLayout(node)
                assertEquals(text, layout.layoutInput.text)
                assertFalse("Narrow large local font must not clip the authored run: $label", layout.hasVisualOverflow)
                assertEquals(ResolvedTextDirection.Rtl, layout.getParagraphDirection(0))
                val box = checkNotNull(layout.placeholderRects.single())
                assertTrue(box.width > 0f && box.height > 0f)
                assertTrue(box.left >= -1f && box.right <= layout.size.width + 1f)
                assertTrue(box.top >= -1f && box.bottom <= layout.size.height + 1f)
                val root = compose.onRoot(useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val bounds = node.fetchSemanticsNode().boundsInRoot
                assertTrue(bounds.left >= root.left - 1f && bounds.right <= root.right + 1f)
                assertTrue(bounds.top >= root.top - 1f && bounds.bottom <= root.bottom + 1f)
                val image = node.captureToImage().toPixelMap()
                var red = 0
                for (y in floor(box.top).toInt().coerceAtLeast(0) until ceil(box.bottom).toInt().coerceAtMost(image.height)) {
                    for (x in floor(box.left).toInt().coerceAtLeast(0) until ceil(box.right).toInt().coerceAtMost(image.width)) {
                        val color = image[x, y]
                        if (color.alpha > .5f && color.red > .65f && color.green < .35f && color.blue < .35f) red++
                    }
                }
                assertTrue("The actual native Canvas must draw the control-bearing run: $label", red > 0)
                node.performTouchInput { click(box.center) }
                compose.waitUntil(10000) { clicked == listOf("egyptian-origin") }
                val followingBox = layout.getBoundingBox(expected.indexOf(following))
                node.performTouchInput { click(followingBox.center) }
                compose.waitUntil(10000) { clicked == listOf("egyptian-origin", "following-arabic") }
                copyThroughVisibleToolbar(node, layout, expected, checkNotNull(clipboard.get()))
            } finally {
                compose.runOnIdle { compose.activity.setContent {} }
                compose.waitForIdle()
            }
        }
    }


    @Test fun entryAbbreviationsUseOneKeyboardControlWithoutReplacingLinksOrCopiedText() {
        val (nativeAnnotated, nativeLegacy) = importedAbbreviationInterop()
        val spans = listOf(Span("link", "f", target = "gender-glossary", explanation = "feminine gender"),
            Span("text", " / "), Span("text", "ab", explanation = "abbreviation"),
            Span("text", "br", italic = true, explanation = "abbreviation"), Span("text", " / "),
            Span("text", "f", explanation = "forte"), Span("text", " "), Span("link", "After", target = "after"))
        val entry = Entry("Abbreviation fixture", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(Block("paragraph", 0, spans)))), emptyList())
        val expected = "f / abbr / f After"
        fun unlinkedSelectionAnchor(node: SemanticsNodeInteraction, layout: TextLayoutResult,
                                    text: androidx.compose.ui.text.AnnotatedString, token: String): Int {
            val start = text.text.indexOf(token)
            assertTrue("Selection token must exist", start >= 0 && token.isNotEmpty())
            assertEquals("Anchor layout must describe the actual annotated text", text, layout.layoutInput.text)
            val textNode = node.fetchSemanticsNode()
            assertEquals(text, textNode.config[SemanticsProperties.Text].single())
            assertEquals("Glyph-to-root coordinates require the same text layout size", layout.size, textNode.size)
            val clickables = compose.onAllNodes(hasClickAction(), useUnmergedTree = true)
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .filter { candidate -> generateSequence(candidate) { it.parent }.any { it.id == textNode.id } }
            val links = text.getLinkAnnotations(0, text.length)
            assertEquals("Every link must retain an observable clickable descendant", links.size, clickables.size)
            assertTrue("Bounded selected fixture link targets", clickables.size <= 16)
            val touchBounds = clickables.map { it.touchBoundsInRoot }
            val origin = textNode.positionInRoot
            val index = (start until start + token.length).firstOrNull { offset ->
                !text.text[offset].isWhitespace() && text.getLinkAnnotations(offset, offset + 1).isEmpty() &&
                    touchBounds.none { it.contains(layout.getBoundingBox(offset).center + origin) }
            }
            assertNotNull("Requested unlinked token needs an actual glyph outside observed clickable touch targets: " +
                "token=$token origin=$origin targets=$touchBounds", index)
            val actualIndex = checkNotNull(index)
            val point = layout.getBoundingBox(actualIndex).center + origin
            assertTrue("Selection starts on an existing nonspace glyph", !text.text[actualIndex].isWhitespace())
            assertTrue("Selection anchor must be outside every link", text.getLinkAnnotations(actualIndex, actualIndex + 1).isEmpty())
            assertTrue("Plain selection gesture must stay outside observed clickable touch targets", touchBounds.none { it.contains(point) })
            android.util.Log.i("TestRunner", "OWNED_UNLINKED_SELECTION_ANCHOR token=$token index=$actualIndex " +
                "glyphBox=${layout.getBoundingBox(actualIndex)} origin=$origin pointRoot=$point " +
                "clickableIds=${clickables.map { it.id }} observedTouchBounds=$touchBounds consumer=unattributed")
            return actualIndex
        }
        var selected by mutableStateOf(nativeAnnotated)
        val clicked = mutableListOf<String>()
        val clipboard = AtomicReference<RecordingClipboard?>()
        val inputModeManager = AtomicReference<androidx.compose.ui.input.InputModeManager?>()
        val observedTouchConfiguration = AtomicReference<FloatArray?>()
        val observingCopy = AtomicBoolean(false)
        val pointerCount = AtomicInteger(0)
        val pointerTrace = ConcurrentLinkedQueue<String>()
        var originalKeyboardMode: androidx.compose.ui.input.InputMode? = null
        var keyboardModeOwner: android.view.View? = null
        var primaryFailure: Throwable? = null
        compose.runOnUiThread {
            compose.activity.setContent {
                val platform = LocalClipboard.current
                val observedDensity = LocalDensity.current
                val observedViewConfiguration = androidx.compose.ui.platform.LocalViewConfiguration.current
                SideEffect {
                    observedTouchConfiguration.set(floatArrayOf(observedDensity.density, observedDensity.fontScale,
                        observedViewConfiguration.minimumTouchTargetSize.width.value,
                        observedViewConfiguration.minimumTouchTargetSize.height.value))
                }
                val currentInputModeManager = androidx.compose.ui.platform.LocalInputModeManager.current
                SideEffect { inputModeManager.set(currentInputModeManager) }
                val recording = remember(platform) { RecordingClipboard(platform) }
                SideEffect { clipboard.set(recording) }
                CompositionLocalProvider(LocalClipboard provides recording) {
                    MaterialTheme {
                        androidx.compose.material3.Surface(modifier = Modifier.pointerInput(Unit) {
                            // Observe the same events without consuming or replacing any gesture handler.
                            val passes = listOf(PointerEventPass.Initial, PointerEventPass.Main, PointerEventPass.Final)
                            awaitPointerEventScope {
                                while (true) {
                                    for (pass in passes) {
                                        val event = awaitPointerEvent(pass)
                                        if (observingCopy.get() && pointerCount.getAndIncrement() < 48) {
                                            pointerTrace.add("pass=$pass type=${event.type} changes=" +
                                                event.changes.take(2).joinToString { change ->
                                                    "id=${change.id.value} time=${change.uptimeMillis} " +
                                                        "pressed=${change.pressed} previous=${change.previousPressed} " +
                                                        "consumed=${change.isConsumed} position=${change.position}"
                                                })
                                        }
                                    }
                                }
                            }
                        }) {
                            EntryView(selected, false, {}, onLink = { clicked += it },
                                settings = AppSettings(collapseOtherSections = false, collapseDetails = true))
                        }
                    }
                }
            }
        }
        try {
            val nativeCompact = "der. ? lbor. f c m n"
            val nativeNode = compose.onNodeWithText(nativeCompact, useUnmergedTree = true)
            nativeNode.performScrollTo().assertIsDisplayed()
            val nativeText = nativeNode.fetchSemanticsNode().config[SemanticsProperties.Text].single()
            assertEquals(nativeCompact, nativeText.text)
            val glossaryTargets = listOf("Appendix:Glossary#derived terms", "Appendix:Glossary#learned borrowing")
            assertEquals(glossaryTargets, nativeText.getLinkAnnotations(0, nativeText.length).map { (it.item as LinkAnnotation.Clickable).tag })
            fun nativeCapture(label: String) {
                val bytes = java.io.ByteArrayOutputStream()
                assertTrue(compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bytes))
                saveOwnedCopyImage(label, bytes.toByteArray())
            }
            nativeCapture("native-compact")
            val nativeLayout = textLayout(nativeNode)
            nativeNode.performTouchInput { click(nativeLayout.getBoundingBox(0).center) }
            compose.waitUntil(10000) { clicked == glossaryTargets.take(1) }
            nativeNode.performTouchInput { click(nativeLayout.getBoundingBox(nativeCompact.indexOf("lbor.")).center) }
            compose.waitUntil(10000) { clicked == glossaryTargets }
            compose.runOnIdle { assertPhysicalActivity(compose.activity) }
            val nativeSelectionAnchor = unlinkedSelectionAnchor(nativeNode, nativeLayout, nativeText, "f")
            val combinedClickableFlag = runCatching {
                Class.forName("androidx.compose.foundation.ComposeFoundationFlags")
                    .getField("isNonSuspendingPointerInputInCombinedClickableEnabled").getBoolean(null).toString()
            }.getOrElse { "unavailable:${it.javaClass.name}" }
            val selectionBefore = nativeNode.fetchSemanticsNode().config
                .getOrNull(SemanticsProperties.TextSelectionRange)?.toString() ?: "absent"
            observingCopy.set(true)
            try {
                copyThroughVisibleToolbar(nativeNode, nativeLayout, nativeCompact, checkNotNull(clipboard.get()), selectionAnchorIndex = nativeSelectionAnchor)
            } catch (failure: Throwable) {
                val selectionAfter = runCatching {
                    nativeNode.fetchSemanticsNode().config
                        .getOrNull(SemanticsProperties.TextSelectionRange)?.toString() ?: "absent"
                }.getOrElse { "unavailable:${it.javaClass.name}" }
                failure.addSuppressed(AssertionError("OWNED_LINK_COPY_POINTER_OBSERVATION " +
                    "nonSuspendingCombinedClickable=$combinedClickableFlag " +
                    "semanticsSelectionBefore=$selectionBefore semanticsSelectionAfter=$selectionAfter " +
                    "anchor=verified-unlinked-glyph-index-$nativeSelectionAnchor " +
                    "passiveSamples=${pointerTrace.size} limit=48\n" + pointerTrace.joinToString("\n")))
                throw failure
            } finally {
                observingCopy.set(false)
            }
            compose.runOnIdle { assertEquals("Selecting and copying must not activate a link", glossaryTargets, clicked) }
            compose.onNodeWithTag("entry-abbreviations").performScrollTo().performClick()
            val meanings = listOf("derived terms", "uncertain", "learned borrowing", "feminine gender", "common gender", "masculine gender", "neuter gender")
            assertEquals(meanings, nativeAnnotated.abbreviations.map { it.explanation })
            assertEquals(listOf("der.", "?", "lbor.", "f", "c", "m", "n"), nativeAnnotated.abbreviations.map { it.label })
            for (explanation in meanings)
                compose.onNodeWithText(explanation).performScrollTo().assertIsDisplayed()
            nativeCapture("native-expanded")
            compose.runOnIdle { selected = nativeLegacy }
            compose.onNodeWithTag("entry-abbreviations").assertDoesNotExist()
            assertTrue(nativeLegacy.sections.flatMap { it.blocks }.any { textOf(it.spans).isNotBlank() })
            val legacyBody = nativeLegacy.sections.flatMap { it.blocks }.first { textOf(it.spans).isNotBlank() }
            compose.onNodeWithText(textOf(legacyBody.spans), useUnmergedTree = true).performScrollTo().assertIsDisplayed()
            compose.runOnIdle { selected = entry; clicked.clear() }
            val button = compose.onNodeWithTag("entry-abbreviations")
            button.assertIsDisplayed().assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Collapsed"))
            compose.onAllNodesWithText("Abbreviations").assertCountEquals(1)
            compose.onNodeWithText("feminine gender").assertDoesNotExist()
            // Touch-driven navigation precedes this keyboard interaction. System-defined
            // focusability requires the platform's actual keyboard input mode first.
            val keyboardInputMode = checkNotNull(inputModeManager.get())
            compose.runOnIdle {
                val before = keyboardInputMode.inputMode
                originalKeyboardMode = before
                keyboardModeOwner = compose.activity.window.decorView
                val requested = keyboardInputMode.requestInputMode(androidx.compose.ui.input.InputMode.Keyboard)
                android.util.Log.i("TestRunner", "OWNED_ABBREVIATION_INPUT_MODE before=$before requested=$requested after=${keyboardInputMode.inputMode}")
                assertTrue("The platform must accept keyboard input mode", requested)
            }
            compose.waitUntil(10000) {
                keyboardInputMode.inputMode == androidx.compose.ui.input.InputMode.Keyboard
            }
            compose.runOnIdle {
                assertEquals(androidx.compose.ui.input.InputMode.Keyboard, keyboardInputMode.inputMode)
                android.util.Log.i("TestRunner", "OWNED_ABBREVIATION_INPUT_MODE verified=${keyboardInputMode.inputMode}")
            }
            button.performSemanticsAction(SemanticsActions.RequestFocus) { assertTrue(it()) }
            button.assertIsFocused().performKeyInput {
                keyDown(androidx.compose.ui.input.key.Key.Enter); keyUp(androidx.compose.ui.input.key.Key.Enter)
            }
            button.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Expanded"))
            compose.onNodeWithText("feminine gender").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("abbreviation").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("forte").performScrollTo().assertIsDisplayed()
            // All three distinct meanings share one source context; show it once, not once per meaning.
            compose.onNodeWithText("feminine gender").assertIsDisplayed()
            compose.onNodeWithText("abbreviation").assertIsDisplayed()
            compose.onAllNodesWithText("Noun: f / abbr / f After", useUnmergedTree = true).assertCountEquals(1)
            compose.onAllNodesWithText("Abbreviations").assertCountEquals(1)
            // Return from the keyboard check through the same real collapse touch a user makes.
            // Compose's direct view injection does not establish the platform touch-mode transition.
            button.performScrollTo().assertIsDisplayed()
            val collapseCenter = button.fetchSemanticsNode().boundsInWindow.center
            val collapseScreen = AtomicReference<android.graphics.PointF?>()
            compose.runOnIdle {
                val activity = compose.activity
                assertPhysicalActivity(activity)
                val decor = activity.window.decorView
                assertTrue("Collapse touch requires our focused visible activity window", decor.isShown && activity.hasWindowFocus() && decor.hasWindowFocus())
                val screen = IntArray(2)
                val window = IntArray(2)
                decor.getLocationOnScreen(screen)
                decor.getLocationInWindow(window)
                collapseScreen.set(android.graphics.PointF(
                    collapseCenter.x + screen[0] - window[0],
                    collapseCenter.y + screen[1] - window[1]))
            }
            val collapsePoint = checkNotNull(collapseScreen.get())
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val collapseAutomation = instrumentation.uiAutomation
            val collapseOriginalFlags = collapseAutomation.serviceInfo.flags
            try {
                collapseAutomation.serviceInfo = collapseAutomation.serviceInfo.apply {
                    flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                }
                val focusedWindow = collapseAutomation.windowsOnAllDisplays
                    .get(android.view.Display.DEFAULT_DISPLAY).orEmpty()
                    .filter { it.isFocused }.single()
                val focusedBounds = android.graphics.Rect()
                focusedWindow.getBoundsInScreen(focusedBounds)
                assertEquals(android.view.Display.DEFAULT_DISPLAY, focusedWindow.displayId)
                assertTrue("Collapse touch requires the active focused application window", focusedWindow.isActive && focusedWindow.type == AccessibilityWindowInfo.TYPE_APPLICATION)
                assertEquals(instrumentation.targetContext.packageName, focusedWindow.root?.packageName?.toString())
                assertTrue("Collapse touch stays inside the observed owned window", focusedBounds.contains(collapsePoint.x.toInt(), collapsePoint.y.toInt()))
                val downTime = android.os.SystemClock.uptimeMillis()
                for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
                    val event = android.view.MotionEvent.obtain(downTime, android.os.SystemClock.uptimeMillis(), action, collapsePoint.x, collapsePoint.y, 0)
                    try {
                        event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
                        // Observe only our fixture and the already validated owned window.
                        // Keep the original native injection and its ownership checks unchanged.
                        val buttonSnapshot = runCatching {
                            button.fetchSemanticsNode().let { node ->
                                "window=${node.boundsInWindow} root=${node.boundsInRoot} touchRoot=${node.touchBoundsInRoot}"
                            }
                        }.getOrElse { "unavailable:${it.javaClass.simpleName}" }
                        val ownedSnapshot = AtomicReference("unavailable")
                        runCatching {
                            compose.runOnIdle {
                                val activity = compose.activity
                                val decor = activity.window.decorView
                                val screen = IntArray(2)
                                val window = IntArray(2)
                                decor.getLocationOnScreen(screen)
                                decor.getLocationInWindow(window)
                                val visible = android.graphics.Rect()
                                decor.getGlobalVisibleRect(visible)
                                ownedSnapshot.set("display=${decor.display?.displayId} " +
                                    "shown=${decor.isShown} attached=${decor.isAttachedToWindow} " +
                                    "activityFocus=${activity.hasWindowFocus()} decorFocus=${decor.hasWindowFocus()} " +
                                    "touchMode=${decor.isInTouchMode} inputMode=${keyboardInputMode.inputMode} " +
                                    "decorSize=${decor.width}x${decor.height} screen=${screen.toList()} " +
                                    "window=${window.toList()} visible=$visible " +
                                    "focusedView=${decor.findFocus()?.javaClass?.name}")
                            }
                        }.onFailure { ownedSnapshot.set("unavailable:${it.javaClass.simpleName}") }
                        android.util.Log.i("TestRunner", "OWNED_ABBREVIATION_NATIVE_TOUCH " +
                            "action=${android.view.MotionEvent.actionToString(event.action)} " +
                            "eventDisplay=unavailable-public-sdk source=${event.source} " +
                            "xy=${event.x},${event.y} raw=${event.rawX},${event.rawY} " +
                            "downTime=${event.downTime} eventTime=${event.eventTime} " +
                            "pid=${android.os.Process.myPid()} uid=${android.os.Process.myUid()} " +
                            "ownedWindowId=${focusedWindow.id} ownedWindowDisplay=${focusedWindow.displayId} " +
                            "ownedWindowBounds=$focusedBounds observedFocus=${focusedWindow.isFocused} " +
                            "observedActive=${focusedWindow.isActive} button=$buttonSnapshot " +
                            "ownedView=${ownedSnapshot.get()}")
                        instrumentation.sendPointerSync(event)
                    } finally { event.recycle() }
                }
            } finally {
                collapseAutomation.serviceInfo = collapseAutomation.serviceInfo.apply { flags = collapseOriginalFlags }
            }
            compose.waitUntil(10000) {
                keyboardInputMode.inputMode == androidx.compose.ui.input.InputMode.Touch
            }
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                assertEquals(androidx.compose.ui.input.InputMode.Touch, keyboardInputMode.inputMode)
                assertTrue("The owned activity must retain window focus after the collapse touch", compose.activity.hasWindowFocus())
                android.util.Log.i("TestRunner", "OWNED_ABBREVIATION_INPUT_MODE after-collapse=${keyboardInputMode.inputMode} windowFocus=${compose.activity.hasWindowFocus()}")
            }
            button.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Collapsed"))
            val node = compose.onNodeWithText(expected, useUnmergedTree = true)
            node.performScrollTo().assertIsDisplayed()
            val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single()
            assertEquals(expected, text.text)
            assertEquals(listOf("gender-glossary", "after"), text.getLinkAnnotations(0, text.length).map { (it.item as LinkAnnotation.Clickable).tag })
            val layout = textLayout(node)
            node.performTouchInput { click(layout.getBoundingBox(0).center) }
            compose.waitUntil(10000) { clicked == listOf("gender-glossary") }
            node.performTouchInput { click(layout.getBoundingBox(expected.indexOf("After")).center) }
            compose.waitUntil(10000) { clicked == listOf("gender-glossary", "after") }
            val syntheticSelectionAnchor = unlinkedSelectionAnchor(node, layout, text, "abbr")
            val syntheticObservation = StringBuilder()
            // Public layout/semantics measurements are observations, not a winning pointer-hit oracle.
            runCatching {
                compose.runOnIdle { assertPhysicalActivity(compose.activity) }
                val configuration = checkNotNull(observedTouchConfiguration.get())
                val density = configuration[0]
                val minimumWidthPx = configuration[2] * density
                val minimumHeightPx = configuration[3] * density
                val textBounds = node.fetchSemanticsNode().boundsInRoot
                val anchorLocal = layout.getBoundingBox(syntheticSelectionAnchor).center
                val anchorRoot = anchorLocal + textBounds.topLeft
                syntheticObservation.append("density=$density fontScale=${configuration[1]} " +
                    "minimumTouchTargetDp=${configuration[2]},${configuration[3]} " +
                    "minimumTouchTargetPx=$minimumWidthPx,$minimumHeightPx " +
                    "anchorIndex=$syntheticSelectionAnchor anchorLocal=$anchorLocal anchorRoot=$anchorRoot textBounds=$textBounds\n")
                text.getLinkAnnotations(0, text.length).take(16).forEach { link ->
                    val pathBounds = layout.getPathForRange(link.start, link.end).getBounds()
                    // Source-derived rounded child rectangle and minimum-target envelope only.
                    // Clipping, pointer type, sibling arbitration and actual consumer remain independent.
                    val measured = androidx.compose.ui.geometry.Rect(
                        java.lang.Math.round(pathBounds.left).toFloat(), java.lang.Math.round(pathBounds.top).toFloat(),
                        java.lang.Math.round(pathBounds.right).toFloat(), java.lang.Math.round(pathBounds.bottom).toFloat())
                    val padX = ((minimumWidthPx - measured.width) / 2f).coerceAtLeast(0f)
                    val padY = ((minimumHeightPx - measured.height) / 2f).coerceAtLeast(0f)
                    val candidate = androidx.compose.ui.geometry.Rect(measured.left - padX, measured.top - padY,
                        measured.right + padX, measured.bottom + padY)
                    syntheticObservation.append("linkRange=${link.start}..${link.end} " +
                        "tag=${(link.item as LinkAnnotation.Clickable).tag} publicPathBounds=$pathBounds " +
                        "derivedRoundedChild=$measured derivedMinimumEnvelope=$candidate " +
                        "derivedContainsAnchor=${candidate.contains(anchorLocal)} consumer=unobserved\n")
                }
                compose.onAllNodes(hasClickAction(), useUnmergedTree = true)
                    .fetchSemanticsNodes(atLeastOneRootRequired = false)
                    .filter { it.boundsInRoot.overlaps(textBounds) }.take(16).forEach { candidate ->
                        syntheticObservation.append("publicClickableSemanticsId=${candidate.id} " +
                            "layoutBoundsRoot=${candidate.boundsInRoot} touchBoundsRoot=${candidate.touchBoundsInRoot} " +
                            "touchContainsAnchor=${candidate.touchBoundsInRoot.contains(anchorRoot)} " +
                            "linkIdentity=unattributed consumer=unobserved\n")
                    }
            }.onFailure { syntheticObservation.append("geometryUnavailable=${it.javaClass.name}:${it.message}\n") }
            syntheticObservation.toString().lineSequence().take(64).forEachIndexed { index, line ->
                android.util.Log.i("TestRunner", "OWNED_SYNTHETIC_HIT_OBSERVATION[$index] $line")
            }
            pointerCount.set(0)
            pointerTrace.clear()
            observingCopy.set(true)
            try {
                copyThroughVisibleToolbar(node, layout, expected, checkNotNull(clipboard.get()),
                    selectionAnchorIndex = syntheticSelectionAnchor)
            } catch (failure: Throwable) {
                failure.addSuppressed(AssertionError("OWNED_SYNTHETIC_HIT_OBSERVATION " +
                    syntheticObservation.toString() + "passiveSamples=${pointerTrace.size} limit=48 " +
                    "consumptionDoesNotIdentifyConsumer=true\n" + pointerTrace.joinToString("\n")))
                throw failure
            } finally {
                observingCopy.set(false)
                android.util.Log.i("TestRunner", "OWNED_SYNTHETIC_POINTER_OBSERVATION " +
                    "passiveSamples=${pointerTrace.size} limit=48 consumer=unattributed")
                pointerTrace.take(48).forEachIndexed { index, line ->
                    android.util.Log.i("TestRunner", "OWNED_SYNTHETIC_POINTER_OBSERVATION[$index] $line")
                }
            }
            compose.runOnIdle { assertEquals("Selecting and copying must not activate a link", listOf("gender-glossary", "after"), clicked) }
            compose.runOnIdle { selected = entry.copy(title = "No abbreviations", sections = listOf(Section(3, "Noun", listOf(Block("paragraph", 0, listOf(Span("text", "Plain body"))))))) }
            compose.onNodeWithText("Plain body").assertIsDisplayed()
            compose.onNodeWithTag("entry-abbreviations").assertDoesNotExist()
            compose.runOnIdle { selected = entry }
            compose.onNodeWithTag("entry-abbreviations").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Collapsed"))
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            // Restore only the mode this test changed, through the same owned manager.
            // A declined restoration remains evidence; never replace the original failure.
            val modeCleanup = runCatching {
                compose.runOnIdle {
                    val original = originalKeyboardMode
                    val manager = inputModeManager.get()
                    if (original != null && manager != null && manager.inputMode != original) {
                        val activity = compose.activity
                        val decor = activity.window.decorView
                        assertPhysicalActivity(activity)
                        check(decor === keyboardModeOwner && decor.isAttachedToWindow && decor.isShown &&
                            activity.hasWindowFocus() && decor.hasWindowFocus()) {
                            "Input-mode restoration requires the same owned focused fixture window"
                        }
                        val before = manager.inputMode
                        val accepted = manager.requestInputMode(original)
                        android.util.Log.i("TestRunner", "OWNED_ABBREVIATION_INPUT_MODE_CLEANUP " +
                            "before=$before original=$original accepted=$accepted after=${manager.inputMode}")
                        check(accepted && manager.inputMode == original) { "Owned input mode was not restored" }
                    }
                }
            }.exceptionOrNull()
            if (modeCleanup != null) {
                android.util.Log.i("TestRunner", "OWNED_ABBREVIATION_INPUT_MODE_CLEANUP " +
                    "failed=${modeCleanup.javaClass.simpleName}")
                if (modeCleanup !== primaryFailure) primaryFailure?.addSuppressed(modeCleanup)
            }
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
            if (primaryFailure == null && modeCleanup != null) throw modeCleanup
        }
    }


    @Test fun expandedAbbreviationsKeepActualSectionAndReferenceLinkDestinations() {
        val explained = buildList {
            repeat(8) { index ->
                if (index > 0) add(Span("text", " / "))
                add(Span("text", "x$index", explanation = "Meaning $index"))
            }
        }
        val links = listOf(Span("link", "Section target", target = "#Destination"),
            Span("text", " / "), Span("link", "Reference target", target = "#reference-1"))
        val entry = Entry("Navigation fixture", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(Block("paragraph", 0, explained), Block("paragraph", 0, links))),
                Section(3, "Destination", listOf(Block("paragraph", 0, listOf(Span("text", "Destination body")))))),
            listOf(Reference(1, 1, "", listOf(Span("text", "Reference body")))))
        val escaped = mutableListOf<String>()
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { androidx.compose.material3.Surface {
                    EntryView(entry, false, {}, onLink = { escaped += it },
                        settings = AppSettings(collapseOtherSections = false, collapseDetails = true))
                } }
            }
        }
        try {
            compose.onNodeWithTag("entry-abbreviations").performClick()
            compose.onNodeWithTag("entry-abbreviations").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Expanded"))
            fun tap(label: String) {
                compose.onNodeWithTag("entry-scroll")
                    .performScrollToNode(hasText("Section target / Reference target"))
                val node = compose.onNodeWithText("Section target / Reference target", useUnmergedTree = true)
                node.performScrollTo().assertIsDisplayed()
                val layout = textLayout(node)
                node.performTouchInput { click(layout.getBoundingBox("Section target / Reference target".indexOf(label)).center) }
            }
            tap("Section target")
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Destination body", useUnmergedTree = true)
                    .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onNodeWithText("Destination body", useUnmergedTree = true).assertIsDisplayed()
            tap("Reference target")
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Reference body", useUnmergedTree = true)
                    .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onNodeWithText("Reference body", useUnmergedTree = true).assertIsDisplayed()
            compose.runOnIdle { assertTrue("Local anchors must not escape into dictionary lookup", escaped.isEmpty()) }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
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
                                          expected: String, recording: RecordingClipboard, selectAllRequired: Boolean = true, selectionAnchorIndex: Int = 1) {
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
            val touch = layout.getBoundingBox(selectionAnchorIndex).center
            diagnostics.append("longClick-local=$touch layout-size=${layout.size} glyph-box[$selectionAnchorIndex]=${layout.getBoundingBox(selectionAnchorIndex)}")
            node.performTouchInput { longClick(touch) }
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
            // Retain this owned Compose root before teardown; file export is separate from test acceptance.
            try {
                val image = java.io.ByteArrayOutputStream()
                check(compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, image))
                saveOwnedCopyImage("copy-failure", image.toByteArray())
                failure.addSuppressed(AssertionError("OWNED_COPY_IMAGE files/qa-copy-evidence/copy-failure.png expectedLength=${expected.length}"))
            } catch (captureFailure: Throwable) {
                if (captureFailure is VirtualMachineError || captureFailure is java.util.concurrent.CancellationException) throw captureFailure
                failure.addSuppressed(AssertionError("Owned copy image capture failed", captureFailure))
            }
            val failureDiagnostics = CopyDiagnostics()
            captureCopyState(failureDiagnostics, "failure-or-timeout", node, expected)
            failure.addSuppressed(AssertionError("COPY_DIAGNOSTICS current\n" + diagnostics.finish()))
            failure.addSuppressed(AssertionError("COPY_DIAGNOSTICS failure snapshot\n" + failureDiagnostics.finish()))
            previousCopyDiagnostics?.let { failure.addSuppressed(AssertionError("COPY_DIAGNOSTICS preceding successful call\n" + it)) }
            throw failure
        } finally {
            automation.serviceInfo = automation.serviceInfo.apply { flags = originalFlags }
        }
    }

    private fun saveOwnedCopyImage(label: String, bytes: ByteArray) {
        require(label in setOf("native-compact", "native-expanded", "copy-failure"))
        require(bytes.size in 45..16_777_216)
        val files = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
        val directory = java.io.File(files, "qa-copy-evidence")
        check(directory.mkdirs() || directory.isDirectory)
        check(directory.canonicalFile.parentFile == files.canonicalFile)
        val target = java.io.File(directory, "$label.png")
        check(target.canonicalFile.parentFile == directory.canonicalFile)
        target.outputStream().use { it.write(bytes) }
    }

    private fun ownedToolbarWindows(): List<AccessibilityWindowInfo> {
        val activity = compose.activity // The shared provider verifies our package and physical display.
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        if (android.os.Build.VERSION.SDK_INT < 30) return emptyList()
        return automation.windowsOnAllDisplays.get(android.view.Display.DEFAULT_DISPLAY).orEmpty()
            .filter { it.displayId == android.view.Display.DEFAULT_DISPLAY &&
                it.type == AccessibilityWindowInfo.TYPE_APPLICATION &&
                it.root?.packageName?.toString() == activity.packageName }
    }

    private fun ownedToolbarRoots(): List<AccessibilityNodeInfo> =
        ownedToolbarWindows().mapNotNull { it.root }
            .filter { it.packageName?.toString() == compose.activity.packageName }
            .distinctBy { it.windowId }

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
            val semanticNode = node.fetchSemanticsNode()
            val range = semanticNode.config.getOrNull(SemanticsProperties.TextSelectionRange)
            diagnostics.append("compose-selection=" + (range?.let { "${it.start}:${it.end}" } ?: "absent"))
            diagnostics.append("compose-node=${semanticNode.id} bounds-in-root=${semanticNode.boundsInRoot} bounds-in-window=${semanticNode.boundsInWindow}")
            // A Text node need not expose its enclosing selection state itself.
            // Inspect only this fixture's bounded ancestor chain; absence is not idle proof.
            var ancestor = semanticNode.parent
            repeat(6) { depth ->
                val current = ancestor
                if (current != null) {
                    val selection = current.config.getOrNull(SemanticsProperties.TextSelectionRange)
                    diagnostics.append("compose-parent-depth=$depth id=${current.id} bounds=${current.boundsInRoot} selection=" +
                        (selection?.let { "${it.start}:${it.end}" } ?: "absent"))
                    ancestor = current.parent
                }
            }
            val roots = ownedToolbarRoots()
            val owner = compose.activity.packageName
            val windows = ownedToolbarWindows()
            diagnostics.append("owned-windows=${windows.size} truncated-windows=${windows.size > 8}")
            for (window in windows.take(8)) diagnostics.append("owned-window id=${window.id} display=${if (android.os.Build.VERSION.SDK_INT >= 30) window.displayId else -1} type=${window.type} active=${window.isActive} focused=${window.isFocused}")
            diagnostics.append("owned-roots=${roots.size} truncated-roots=${roots.size > 8}")
            for (root in roots.take(8)) {
                diagnostics.append("root " + diagnosticNode(root))
                val queue = java.util.ArrayDeque<Pair<AccessibilityNodeInfo, Int>>()
                queue.add(root to 0)
                var visited = 0
                while (queue.isNotEmpty() && visited < 24) {
                    val (current, depth) = queue.removeFirst()
                    if (current.packageName?.toString() != owner || current.windowId != root.windowId) continue
                    visited++
                    diagnostics.append("owned-node depth=$depth children=${current.childCount} text=${diagnosticValue(current.text)} " + diagnosticNode(current))
                    if (depth < 4) for (index in 0 until minOf(current.childCount, 8)) {
                        current.getChild(index)?.let { queue.add(it to depth + 1) }
                    }
                }
                diagnostics.append("owned-subtree visited=$visited truncated=${queue.isNotEmpty()}")
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

    /** Required genuine Writer fixture: no hand-built wire or absent-fixture skip. */
    private fun importedAbbreviationInterop(): Pair<Entry, Entry> = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = InstrumentationRegistry.getArguments().getString("abbreviationInteropRoot")?.let {
            java.io.File(it).canonicalFile.also { directory -> require(directory.isDirectory && directory.isAbsolute) }
        }
        fun fixture(name: String): java.io.InputStream = if (root == null)
            instrumentation.context.assets.open("abbreviation-interop/$name")
        else java.io.File(root, name).inputStream()
        val headingHash = MessageDigest.getInstance("SHA-256").digest("English".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        val blobName = "languages/$headingHash.wikblb"
        fun export(name: String): Entry {
            val envelope = org.json.JSONObject(fixture(name).bufferedReader(Charsets.UTF_8).use { it.readText() })
            val entries = envelope.getJSONArray("entries")
            assertEquals(1, entries.length())
            return interopExpectedEntry(entries.getJSONObject(0))
        }
        val expectedAnnotated = export("annotated.export.json")
        val expectedLegacy = export("legacy.export.json")
        assertEquals("Acupuncture abbreviation sample", expectedAnnotated.title)
        assertEquals("Legacy format abbreviation control", expectedLegacy.title)
        assertEquals("English", expectedAnnotated.language)
        assertEquals("en", expectedAnnotated.languageCode)
        assertEquals("English", expectedLegacy.language)
        assertTrue(expectedAnnotated.abbreviations.isNotEmpty())
        assertTrue(expectedLegacy.abbreviations.isEmpty())
        val library = LibraryStore.get(instrumentation.targetContext)
        val edition = "abbrinterop${java.util.UUID.randomUUID().toString().replace("-", "")}wiktionary-20261001"
        try {
            library.importFile(name = { "$edition-$headingHash.wikblb" }) { fixture(blobName) }.join()
            assertNull(library.error)
            assertEquals(1, library.dictionaries.count { it.edition == edition })
            suspend fun read(expected: Entry): Entry {
                val hit = requireNotNull(library.exact(expected.title, "English", edition))
                val actual = library.read(hit)
                assertEquals(expected, actual.copy(edition = "", origin = null, contentDictionary = null))
                return actual
            }
            read(expectedAnnotated) to read(expectedLegacy)
        } finally {
            library.dictionaries.filter { it.edition == edition }.forEach { library.remove(it.id).join() }
            assertTrue(library.dictionaries.none { it.edition == edition })
        }
    }

    /** Native JSON is only an independent expected value; presentation still decodes from the imported blob. */
    private fun interopExpectedEntry(j: org.json.JSONObject): Entry {
        fun <T> list(a: org.json.JSONArray, read: (org.json.JSONObject) -> T): List<T> =
            List(a.length()) { read(a.getJSONObject(it)) }
        fun spans(a: org.json.JSONArray): List<Span> = list(a) { s ->
            Span(s.getString("kind"), s.getString("text"), s.getString("target"), s.getString("trail"),
                s.getString("language"), s.getString("classes"), s.getString("direction"),
                bold = s.getBoolean("bold"), italic = s.getBoolean("italic"), code = s.getBoolean("code"),
                small = s.getBoolean("small"), superscript = s.getBoolean("superscript"),
                subscript = s.getBoolean("subscript"), strike = s.getBoolean("strike"),
                underline = s.getBoolean("underline"), role = s.getString("role"),
                explanation = s.optString("explanation", ""))
        }
        fun block(v: org.json.JSONObject): Block {
            val table = if (v.isNull("table")) null else v.getJSONObject("table").let { t ->
                Table(spans(t.getJSONArray("caption")), list(t.getJSONArray("rows")) { row ->
                    list(row.getJSONArray("cells")) { c ->
                        Cell(spans(c.getJSONArray("spans")), c.getBoolean("header"), c.getInt("colspan"), c.getInt("rowspan"))
                    }
                })
            }
            val feature = if (v.isNull("feature")) null else v.getJSONObject("feature").let { f ->
                Feature(f.getString("kind"), f.getString("language"), f.getString("data"), f.getString("tail_kind"), f.getString("tail"))
            }
            return Block(v.getString("kind"), v.getInt("depth"), spans(v.getJSONArray("spans")),
                v.getString("list_path"), v.getString("number"), table, feature, v.getInt("level"))
        }
        assertTrue(j.isNull("redirect"))
        assertTrue(j.isNull("alias"))
        return Entry(j.getString("title"), spans(j.getJSONArray("display_title")), j.getString("kind"),
            if (j.isNull("language")) null else j.getString("language"), j.getString("language_code"),
            list(j.getJSONArray("sections")) { s -> Section(s.getInt("level"), s.getString("title"), list(s.getJSONArray("blocks"), ::block)) },
            list(j.getJSONArray("references")) { r -> Reference(r.getLong("number"), r.getLong("group_number"), r.getString("group"), spans(r.getJSONArray("spans"))) },
            spans(j.getJSONArray("preamble_spans")),
            list(j.getJSONArray("media")) { m -> Media(m.getString("file"), m.getString("kind"), m.getString("caption")) })
    }

}
