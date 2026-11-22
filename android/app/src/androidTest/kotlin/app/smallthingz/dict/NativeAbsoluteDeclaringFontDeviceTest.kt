package app.smallthingz.dict

import android.graphics.Typeface
import android.text.Spanned
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Constructed native controls; these are not an issued EN page or a captured font equivalence. */
@RunWith(AndroidJUnit4::class)
class NativeAbsoluteDeclaringFontDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val density = Density(1.25f, 2f)
    private val zoom = 1.5f
    private var prepared: PreparedNativeFloatText? = null
    private var format: NativeContainerTextFormat? = null
    private fun policy(size: Float = 12f, height: Float = 12f,
        family: ContainerFontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)) =
        ContainerPositioning.Absolute(StyleLength(StyleLengthUnit.Px, 3f), StyleLength(StyleLengthUnit.Px, 130f),
            InlineFontSnapshot(fontScale = size, fontScaleBasis = FontScaleBasis.CssPx, language = "en",
                fontFeatures = FontFeaturePolicy.SevenOn, fontFamily = family),
            InlineComputedLength(height, FontScaleBasis.CssPx), TextWrap.NoWrap)

    @Composable private fun Prepare(value: ContainerPositioning.Absolute, spans: List<Span>,
        activated: MutableList<EntryLink>, probe: NativeNamedFontProbe = NativeNamedFontProbe { _, _, _, _ -> null },
        inheritedFamily: ContainerFontFamily? = null) {
        val body = TextStyle(fontSize = 23.sp, lineHeight = 31.sp)
        MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = body)) {
            CompositionLocalProvider(LocalDensity provides density, LocalCssPixelTextZoom provides zoom,
                LocalNativeNamedFontProbe provides probe, LocalCellWeight provides FontWeight.Black) {
                val inherited = TextStyle(fontSize = 72.sp, lineHeight = 90.sp, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Black, fontStyle = FontStyle.Italic,
                    localeList = LocaleList(Locale("tr")), baselineShift = BaselineShift.Superscript)
                val selected = nativeAbsoluteContainerTextFormat(value, inherited, density, inheritedFamily,
                    hasLine = nativeNoWrapSourceLineStarts(spans).isNotEmpty()).getOrThrow()
                // Child annotation uses the actual declaring context; the root still has its
                // independently retained snapshot when the first descendant changes its font.
                CompositionLocalProvider(LocalCellWeight provides null,
                    LocalNativeContainerTextContext provides ContainerTextContext(fontFamily = selected.sourceFamily)) {
                    val result = prepareNativeFloatText(spans, styledTextAnnotation(spans, null, selected.style) { activated += it },
                        egyptianTextRuns(spans), selected.style, Color.Black, emptyList(), AppSettings(), "",
                        { activated += it }, nativeLineHeight = selected.lineHeight, sourceFamily = selected.sourceFamily,
                        ownerWrap = value.textWrap, ownerFont = selected.ownerFont)
                    SideEffect { prepared = result; format = selected }
                }
            }
        }
    }
    private fun control(body: () -> Unit) {
        var primary: Throwable? = null
        try { body() } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (failure: Throwable) {
                val original = primary
                if (original == null) throw failure
                if (original !== failure) original.addSuppressed(failure)
            }
        }
    }
    private fun source(): Spanned = checkNotNull(checkNotNull(prepared).native).source(90)
    private fun paintAt(source: Spanned, at: Int): TextPaint = TextPaint(checkNotNull(checkNotNull(prepared).native).paint).apply {
        source.getSpans(at, at + 1, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(this) }
    }

    @Test fun independentOwnerFontAndTextLengthSurviveFirstRunOverridesAndTextZoom() = control {
        val activated = mutableListOf<EntryLink>()
        val spans = listOf(Span("text", "tiny ", fontScale = 6f, fontScaleBasis = FontScaleBasis.CssPx),
            Span("link", "owner action", "source-target", fontScale = 30f, fontScaleBasis = FontScaleBasis.CssPx,
                bold = true, italic = true))
        compose.activityRule.scenario.onActivity { it.setContent { Prepare(policy(), spans, activated) } }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            val native = checkNotNull(value.native)
            val expected = with(density) { (12f * zoom).sp.toPx() }
            assertEquals(expected, native.paint.textSize, .001f)
            assertEquals(expected, (checkNotNull(format).lineHeight as NativeLineHeightPolicy.Pixels).value, .001f)
            assertNotEquals(12f * density.density, native.paint.textSize, .001f)
            assertFalse(native.paint.typeface.isBold)
            assertFalse(native.paint.typeface.isItalic)
            assertEquals(0, native.paint.baselineShift)
            assertEquals("en", native.paint.textLocale.toLanguageTag())
            assertEquals(FontFeaturePolicy.SevenOn.nativeSettings, native.paint.fontFeatureSettings)
            val source = source()
            assertEquals("tiny owner action", source.toString())
            assertEquals(with(density) { (6f * zoom).sp.toPx() }, paintAt(source, 0).textSize, .001f)
            assertFalse(paintAt(source, 0).typeface.isBold)
            assertTrue(paintAt(source, 6).typeface.isBold)
            assertEquals(with(density) { (30f * zoom).sp.toPx() }, paintAt(source, 6).textSize, .001f)
            assertNotEquals(30f * zoom * density.density * density.fontScale, paintAt(source, 6).textSize, .001f)
            val root = source.getSpans(0, source.length, NativeRunLineMetrics::class.java).single { it.strut }
            assertEquals(expected, root.primary.fontSize, .001f)
            val geometry = checkNotNull(value.geometry)(90, emptyList(), false)
            assertEquals(1, geometry.shapedLineCount)
            assertEquals(source.toString(), geometry.text.toString())
            val action = geometry.nodes.single { it.kind == FloatInteractionKind.LINK }
            action.onClick!!.invoke()
            assertEquals(listOf("source-target"), activated.map { it.target })
        }
    }

    @Test fun sourceBreaksEstablishLinesWhileEmptyFontsAndMetricPointsDoNot() = control {
        val activated = mutableListOf<EntryLink>()
        val br = Span("line_break", "")
        val metric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(80f, FontScaleBasis.CssPx))))
        val text = mutableStateOf(listOf(Span("text", "X", fontScale = 40f,
            fontScaleBasis = FontScaleBasis.CssPx, superscript = true), br))
        val owner = mutableStateOf(policy())
        compose.activityRule.scenario.onActivity { it.setContent { Prepare(owner.value, text.value, activated) } }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertNull(value.stateDescription)
            val source = source()
            assertEquals("X\n", source.toString())
            val geometry = checkNotNull(value.geometry)(90, emptyList(), false)
            val expected = with(density) { (12f * zoom).sp.toPx() }
            assertTrue(geometry.usedLineHeight(0) > expected)
            assertEquals(geometry.usedLineHeight(0), geometry.textBottom, .001f)
            assertEquals(0f, geometry.usedLineHeight(1), 0f) // native EOF slot has no source line
            assertTrue(geometry.caretRect(source.length).isEmpty)
            assertEquals(geometry.textBaselines?.first, geometry.textBaselines?.last)
            assertTrue(source.getSpans(source.length, source.length, NativeRunLineMetrics::class.java).none {
                source.getSpanStart(it) == source.length && source.getSpanEnd(it) == source.length
            })
        }
        val expected = with(density) { (12f * zoom).sp.toPx() }
        val metricHeight = with(density) { (80f * zoom).sp.toPx() }
        val cases = listOf(
            emptyList<Span>() to 0f,
            listOf(metric) to 0f,
            listOf(br) to expected,
            listOf(br, br) to (2f * expected),
            listOf(br, metric) to expected,
            listOf(metric, br) to metricHeight)
        for ((spans, height) in cases) {
            compose.runOnIdle { text.value = spans; owner.value = policy(size = 0f) }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                val native = checkNotNull(value.native)
                val source = native.source(90)
                assertEquals(spans.count { it.kind == "line_break" }, source.length)
                assertEquals(source.toString(), value.text.toString())
                assertEquals(0f, native.paint.textSize, 0f)
                val geometry = checkNotNull(value.geometry)(90, emptyList(), false)
                assertEquals(height, geometry.textBottom, .001f)
                assertTrue(geometry.nodes.isEmpty())
                assertTrue(geometry.caretRect(source.length).isEmpty)
                if (height == 0f) {
                    assertTrue(value.emptyInlineOwner)
                    assertNull(checkNotNull(format).ownerFont!!.style)
                    assertEquals(NativeFloatBounds(0f, 0f, 0f, 0f), geometry.scrollableBounds)
                    assertNull(geometry.extents.ink)
                    assertNull(geometry.extents.interaction)
                    assertNull(geometry.textBaselines?.first)
                    assertNull(geometry.textBaselines?.last)
                    assertTrue(geometry.rectsForRange(0, source.length).isEmpty())
                    assertTrue(source.getSpans(0, source.length, NativeRunLineMetrics::class.java).isEmpty())
                } else {
                    assertFalse(value.emptyInlineOwner)
                    assertNotNull(checkNotNull(format).ownerFont!!.style)
                }
                assertTrue(activated.isEmpty())
            }
        }
    }

    @Test fun unusedNamedOwnerNeedsNoFontButRealSourceLinesRefuseAndRecoverWithoutActionChanges() = control {
        val activated = mutableListOf<EntryLink>()
        val named = ContainerFontFamily.Stack(listOf("Controlled Face"), GenericFontFamily.Serif)
        val owner = mutableStateOf(policy(family = named))
        val spans = mutableStateOf(emptyList<Span>())
        val probe = NativeNamedFontProbe { _, name, _, _ -> if (name == "Controlled Face") Typeface.DEFAULT else null }
        compose.activityRule.scenario.onActivity { it.setContent { Prepare(owner.value, spans.value, activated, probe, named) } }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertEquals("", value.text.toString())
            assertNull(value.stateDescription)
            assertTrue(value.emptyInlineOwner)
            assertNull(checkNotNull(format).ownerFont!!.style)
            assertEquals(named, checkNotNull(format).ownerFont!!.snapshot.fontFamily)
            val geometry = checkNotNull(value.geometry)(90, emptyList(), false)
            assertEquals(0f, geometry.textBottom, 0f)
            assertNull(geometry.extents.ink)
            assertNull(geometry.extents.interaction)
            assertTrue(activated.isEmpty())
            spans.value = listOf(Span("link", "kept action", "source-target"))
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals("kept action", checkNotNull(prepared).text.toString())
            assertEquals(NativeNamedFamilyUnavailable, checkNotNull(prepared).stateDescription)
            // A real owner code mapping displaces the inherited Stack for every child;
            // its provenance must not accidentally reselect that loaded named request.
            owner.value = policy().let { it.copy(ownerFont = it.ownerFont.copy(code = true, fontFamily = null)) }
        }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertNull(value.stateDescription)
            assertNull(checkNotNull(format).sourceFamily)
            assertEquals(FontFamily.Monospace, checkNotNull(format).style.fontFamily)
            val geometry = checkNotNull(value.geometry)(90, emptyList(), false)
            assertEquals("kept action", geometry.text.toString())
            geometry.nodes.single { it.kind == FloatInteractionKind.LINK }.onClick!!.invoke()
            assertEquals(listOf("source-target"), activated.map { it.target })
            spans.value = listOf(Span("link", "kept action", "source-target", fontFamily = named))
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals("kept action", checkNotNull(prepared).text.toString())
            assertEquals(NativeNamedFamilyUnavailable, checkNotNull(prepared).stateDescription)
            assertEquals(1, activated.size)
            spans.value = listOf(Span("link", "kept action", "source-target"))
        }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertNull(value.stateDescription)
            checkNotNull(value.geometry)(90, emptyList(), false).nodes.single { it.kind == FloatInteractionKind.LINK }.onClick!!.invoke()
            assertEquals(listOf("source-target", "source-target"), activated.map { it.target })
        }
        val unusedPoint = Span("text", "", inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1f,
            InlineFontSnapshot(fontScale = 12f, fontScaleBasis = FontScaleBasis.CssPx, language = "en", fontFamily = named))))
        val br = Span("line_break", "")
        compose.runOnIdle { spans.value = listOf(br, unusedPoint) }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertNull(value.stateDescription)
            assertEquals("\n", value.text.toString())
            assertEquals(with(density) { (12f * zoom).sp.toPx() },
                checkNotNull(value.geometry)(90, emptyList(), false).textBottom, .001f)
            spans.value = listOf(unusedPoint, br)
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(NativeNamedFamilyUnavailable, checkNotNull(prepared).stateDescription)
            assertEquals("\n", checkNotNull(prepared).text.toString())
            // An empty source-family span's injected isolate pair also cannot request
            // a font for the absent EOF line. Its native offsets stay in the source.
            spans.value = listOf(br, Span("text", "", direction = "rtl", fontFamily = named))
        }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertNull(value.stateDescription)
            assertEquals("\n\u2067\u2069", value.text.toString())
            val geometry = checkNotNull(value.geometry)(90, emptyList(), false)
            assertEquals(with(density) { (12f * zoom).sp.toPx() }, geometry.textBottom, .001f)
            assertTrue(geometry.nodes.isEmpty())
            assertTrue(geometry.caretRect(value.text.length).isEmpty)
            assertEquals(2, activated.size)
        }
    }
}
