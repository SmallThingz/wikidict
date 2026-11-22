package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Typeface
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real Android shaping/painting kernels. Entry widget controls are in SectionHeadingDeviceTest. */
@RunWith(AndroidJUnit4::class)
class NativeSectionHeadingKernelDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val density = Density(1.25f, 1.2f)
    private var prepared: PreparedNativeFloatText? = null
    private var selected: SectionHeadingStyle? = null
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(top: Float = 0f, right: Float = 0f, bottom: Float = 0f, left: Float = 0f) =
        StyleEdges(px(top), px(right), px(bottom), px(left))
    private fun policy(scale: Float = .9f, clear: FigureClear = FigureClear.None, padded: Boolean = false) =
        SectionHeadingStyle(ContainerStyle(margins = if (padded) edges(right = 1.25f, left = .25f) else edges(),
            padding = if (padded) edges(1f, 2f, 1f, 3f) else edges(), border = ContainerBorder.None,
            clear = clear, ownerFontScale = scale, lineHeight = ContainerLineHeight.Multiplier(1.5f),
            fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)),
            InlineFontSnapshot(fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
                italic = true, language = "th", fontFeatures = FontFeaturePolicy.SevenOn), BidiResolvedDirection.Rtl)

    @Composable private fun Prepare(value: SectionHeadingStyle, text: String, actions: MutableList<EntryLink>,
        folds: MutableList<String>) {
        val body = TextStyle(fontSize = 20.sp, lineHeight = 20.sp, fontFamily = FontFamily.Monospace)
        MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = body)) {
            CompositionLocalProvider(LocalDensity provides density) {
                val inherited = TextStyle(fontSize = 72.sp, lineHeight = 80.sp, fontWeight = FontWeight.Black,
                    fontStyle = FontStyle.Normal, fontFamily = FontFamily.Monospace)
                val format = nativeSectionHeadingTextFormat(value, body.fontSize, inherited, density).getOrThrow()
                val spans = listOf(Span("link", text, "source-title"))
                val result = prepareNativeFloatText(spans, styledTextAnnotation(spans, null, format.style) { actions += it },
                    egyptianTextRuns(spans), format.style, Color.Black, emptyList(), AppSettings(),
                    "", { actions += it }, heading = true,
                    headingActions = listOf(NativeHeadingAction("Fold", false) { folds += "fold" },
                        NativeHeadingAction("Details", false) { folds += "details" }),
                    nativeLineHeight = format.lineHeight, sourceFamily = format.sourceFamily,
                    authoredHeading = true, ownerDirection = value.direction, headingLabel = text)
                SideEffect { prepared = result; selected = value }
            }
        }
    }
    private fun control(body: () -> Unit) {
        try { body() } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }
    private fun paintHasInk(geometry: FloatTextGeometry): Boolean {
        val bitmap = Bitmap.createBitmap(maxOf(1, geometry.width + 40), maxOf(1, geometry.height + 80), Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.translate(20f, 20f)
            geometry.paint(canvas)
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width)
                if (android.graphics.Color.alpha(bitmap.getPixel(x, y)) != 0) return true
            return false
        } finally { bitmap.recycle() }
    }

    @Test fun ownerFontAndRawTitleDriveActualPaintAndZeroSizeWithoutLegacyControls() = control {
        val source = "A\u00a0  B"
        val state = mutableStateOf(policy())
        val actions = mutableListOf<EntryLink>()
        val folds = mutableListOf<String>()
        compose.activityRule.scenario.onActivity { it.setContent { Prepare(state.value, source, actions, folds) } }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            val native = checkNotNull(value.native)
            assertEquals(source, value.text.toString())
            assertEquals(source, native.source(180).toString())
            assertEquals(27f, native.paint.textSize, .001f)
            assertEquals("th", native.paint.textLocale.toLanguageTag())
            assertEquals(FontFeaturePolicy.SevenOn.nativeSettings, native.paint.fontFeatureSettings)
            assertFalse(native.paint.typeface.isBold)
            assertTrue(native.paint.typeface.isItalic)
            assertTrue(native.direction.isRtl(source, 0, source.length))
            assertEquals(0f, native.horizontalInsets, 0f)
            assertTrue(native.breakWordMinimum)
            val geometry = checkNotNull(value.geometry)(180, emptyList(), false)
            assertEquals(1, geometry.shapedLineCount)
            assertEquals(40.5f, geometry.usedLineHeight(0), .001f)
            assertTrue(paintHasInk(geometry))
            assertTrue(geometry.nodes.none { it.kind == FloatInteractionKind.CONTROL })
            val heading = geometry.nodes.single { it.kind == FloatInteractionKind.HEADING }
            val link = geometry.nodes.single { it.kind == FloatInteractionKind.LINK }
            assertEquals(source, heading.label)
            assertEquals(listOf("Fold", "Details"), heading.customActions.map { it.label })
            val target = link.bounds.first { !it.isEmpty }
            assertEquals(link.id, geometry.interactionNodeAt(target.centerX(), target.centerY())?.id)
            link.onClick!!.invoke()
            heading.customActions[0].onClick()
            assertEquals(listOf("source-title"), actions.map { it.target })
            assertEquals(listOf("fold"), folds)
        }
        compose.runOnIdle { state.value = policy(scale = 0f) }
        compose.waitForIdle()
        compose.runOnIdle {
            val geometry = checkNotNull(checkNotNull(prepared).geometry)(180, emptyList(), false)
            assertEquals(source, geometry.text.toString())
            assertEquals(0f, geometry.usedLineHeight(0), 0f)
            assertFalse(paintHasInk(geometry))
            assertTrue(geometry.nodes.none { it.kind == FloatInteractionKind.CONTROL })
        }
    }

    @Test fun exactFloatIntervalReflowsOnePreparedOwnerAndClearUsesTheSameSource() = control {
        val title = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
        val actions = mutableListOf<EntryLink>()
        compose.activityRule.scenario.onActivity { it.setContent { Prepare(policy(padded = true), title, actions, mutableListOf()) } }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            val heading = checkNotNull(selected)
            val childSpec = NativeFloatContextSpec.Text(value, 0f, "source-heading",
                ParagraphBox(ParagraphEdges(), ParagraphEdges(), 0f, 0f))
            val spec = nativeSectionHeadingSpec(17, heading, childSpec, density.density, 30f, false)
            val widths = mutableListOf<Int>()
            val textPart = NativeFloatContextPart.Text(value.text, { width, exclusions ->
                widths += width
                checkNotNull(value.geometry)(width, exclusions, false)
            }, box = childSpec.box)
            val horizontal = spec.horizontal!!(200, ContainerWidths(0f, 0f))
            val owner = NativeFloatContextPart.Container(17, spec.contentWidth(200, ContainerWidths(0f, 0f)),
                { _, _ -> error("Prepared title tree is the only shape owner") }, margins = spec.margins(200),
                padding = spec.padding(200), clear = spec.clear, isolatesFloats = true,
                preparedParts = listOf(textPart), horizontal = horizontal, headingAllocation = spec.headingAllocation)
            fun layout(part: NativeFloatContextPart.Container, exclusions: List<NativeFloatExclusion>): NativeFloatContextGeometry {
                val preparation = NativeOrdinaryPreparation(listOf(part))
                assertEquals(0, preparation.sourceIndex(textPart))
                return NativeFloatContextGeometry.build(200, listOf(part), carriedExclusions = exclusions,
                    adjoining = true, preparation = preparation)
            }
            val full = layout(owner, emptyList())
            widths.clear()
            val float = NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 80.25f, 500.25f))
            val beside = layout(owner, listOf(float))
            val expected = checkNotNull(spec.headingAllocation).horizontal(119.75f)
            val border = checkNotNull(beside.ordinaryBounds[17])
            assertEquals(80.25f + expected.borderLeft, border.left, .001f)
            assertEquals(expected.borderWidth, border.width(), .001f)
            assertEquals(0f, border.top, 0f)
            assertEquals(200f - 1.25f * density.density, border.right, .001f)
            assertTrue(widths.contains(kotlin.math.floor(horizontal.content).toInt()))
            assertTrue(widths.contains(kotlin.math.floor(expected.content).toInt()))
            assertTrue(border.height() > checkNotNull(full.ordinaryBounds[17]).height())
            val leaf = beside.inputLeaves().single()
            assertEquals(0, leaf.sourceIndex)
            assertEquals(80.25f + expected.contentLeft, leaf.x, .001f)
            assertEquals(title, beside.text.toString())
            assertTrue(paintHasInk(beside))
            val link = beside.nodes.single { it.kind == FloatInteractionKind.LINK }
            val target = link.bounds.first { !it.isEmpty }
            assertEquals(link.id, beside.interactionNodeAt(target.centerX(), target.centerY())?.id)
            assertTrue(beside.rectsForRange(0, title.length).isNotEmpty())
            link.onClick!!.invoke()
            val cleared = layout(owner.copy(clear = FigureClear.Both), listOf(float))
            val clearBorder = checkNotNull(cleared.ordinaryBounds[17])
            assertEquals(500.25f, clearBorder.top, .001f)
            assertEquals(horizontal.borderLeft, clearBorder.left, .001f)
            assertEquals(horizontal.borderWidth, clearBorder.width(), .001f)
            assertEquals(title, cleared.text.toString())
            assertEquals(0, cleared.inputLeaves().single().sourceIndex)
            assertEquals(beside.nodes.map { it.kind to it.label }, cleared.nodes.map { it.kind to it.label })
            assertEquals(listOf("source-title"), actions.map { it.target })
        }
    }

    private var genericBoldItalic: Typeface? = null
    private var monospaceBold: Typeface? = null
    @Composable private fun PrepareFamilies(spans: List<Span>, actions: MutableList<EntryLink>,
        inherited: ContainerFontFamily?, probe: NativeNamedFontProbe, computedCell: Boolean = true, preformatted: Boolean = false,
        render: @Composable (PreparedNativeFloatText) -> Unit = {}) {
        val body = TextStyle(fontSize = 20.sp, lineHeight = 20.sp, fontFamily = FontFamily.SansSerif)
        val readingStyle = if (preformatted) body.copy(fontFamily = FontFamily.Monospace) else body
        MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = body)) {
            CompositionLocalProvider(LocalDensity provides density, LocalNativeNamedFontProbe provides probe,
                LocalNativePreformattedText provides preformatted,
                LocalNativeContainerTextContext provides ContainerTextContext(fontFamily = inherited,
                    cellText = if (computedCell) NativeCellTextState(30f, NativeLineHeightPolicy.Pixels(30f)) else null)) {
                val expected = LocalFontFamilyResolver.current.resolve(FontFamily.SansSerif,
                    FontWeight.Bold, FontStyle.Italic).value as Typeface
                val mono = LocalFontFamilyResolver.current.resolve(FontFamily.Monospace,
                    FontWeight.Bold, FontStyle.Normal).value as Typeface
                val value = prepareNativeFloatText(spans, styledTextAnnotation(spans, null, readingStyle) { actions += it },
                    egyptianTextRuns(spans), readingStyle, Color.Black, emptyList(), AppSettings(), "", { actions += it },
                    nativeLineHeight = NativeLineHeightPolicy.Pixels(30f), sourceFamily = inherited)
                SideEffect { prepared = value; genericBoldItalic = expected; monospaceBold = mono }
                render(value)
            }
        }
    }
    private fun runPaint(value: NativePreparedText, offset: Int): TextPaint {
        val source = value.source(240)
        return TextPaint(value.paint).apply {
            source.getSpans(offset, offset + 1, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(this) }
        }
    }

    @Test fun typedFamilyAdmissionSurvivesEqualGenericFacesAndComputedCellDefaults() = control {
        val inherited = ContainerFontFamily.Stack(listOf("Ancestor Source Family"), GenericFontFamily.SansSerif)
        val requested = ContainerFontFamily.Stack(listOf("Explicit Source Family"), GenericFontFamily.SansSerif)
        val prefix = Span("text", " \u00a0 ")
        val explicit = Span("link", "typed", "typed-target", trail = "\u00a0 ", bold = true, italic = true,
            code = true, fontFamily = requested)
        val legacyCode = Span("link", "code", "code-target", code = true, italic = true)
        val suffix = Span("text", "  tail ")
        val values = mutableStateOf(listOf(prefix, explicit, legacyCode, suffix))
        val mode = mutableStateOf(0)
        val preformatted = mutableStateOf(false)
        val observed = mutableListOf<Triple<String, FontWeight, FontStyle>>()
        val actions = mutableListOf<EntryLink>()
        compose.activityRule.scenario.onActivity { it.setContent {
            val activeMode = mode.value
            val probe = remember(activeMode) { NativeNamedFontProbe { _, name, weight, style ->
                observed += Triple(name, weight, style)
                when {
                    activeMode == 1 && name == "Explicit Source Family" -> Typeface.SANS_SERIF
                    activeMode == 2 && name == "Explicit Source Family" -> throw IllegalStateException("probe failed")
                    activeMode == 3 && name == "Ancestor Source Family" && weight == FontWeight.Bold -> Typeface.SANS_SERIF
                    else -> null
                }
            } }
            PrepareFamilies(values.value, actions, inherited, probe, preformatted = preformatted.value)
        } }
        compose.waitForIdle()
        val original = values.value.joinToString("") { it.text + it.trail }
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertEquals(original, value.text.toString())
            assertTrue(observed.contains(Triple("Explicit Source Family", FontWeight.Bold, FontStyle.Italic)))
            // The computed-cell default and this policy both resolve to SansSerif; the
            // ordered request must still be probed, while actual legacy code stays separate.
            assertFalse(observed.contains(Triple("Ancestor Source Family", FontWeight.Normal, FontStyle.Italic)))
            val native = checkNotNull(value.native)
            assertEquals(checkNotNull(genericBoldItalic), runPaint(native, prefix.text.length).typeface)
            val geometry = checkNotNull(value.geometry)(240, emptyList(), false)
            assertTrue(paintHasInk(geometry))
            geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label == explicit.text + explicit.trail }.onClick!!.invoke()
            geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label == "code" }.onClick!!.invoke()
            assertEquals(listOf("typed-target", "code-target"), actions.map { it.target })
        }
        for ((next, reason) in listOf(1 to NativeNamedFamilyUnavailable, 2 to NativeNamedFamilyProbeUnavailable)) {
            compose.runOnIdle { mode.value = next }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(original, checkNotNull(prepared).text.toString())
                assertNull(checkNotNull(prepared).native)
                assertEquals(reason, checkNotNull(prepared).stateDescription)
            }
        }
        // Remove the explicit family but keep an independently bold source run. A derived
        // computed-cell body annotation must not bypass the inherited Stack's bold request.
        val inheritedRun = explicit.copy(code = false, italic = false, fontFamily = null)
        compose.runOnIdle { values.value = listOf(prefix, inheritedRun, legacyCode, suffix); mode.value = 3 }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(original, checkNotNull(prepared).text.toString())
            assertTrue(observed.contains(Triple("Ancestor Source Family", FontWeight.Bold, FontStyle.Normal)))
            assertEquals(NativeNamedFamilyUnavailable, checkNotNull(prepared).stateDescription)
            assertNull(checkNotNull(prepared).native)
        }
        compose.runOnIdle { preformatted.value = true }
        compose.waitForIdle()
        compose.runOnIdle {
            val native = checkNotNull(checkNotNull(prepared).native)
            assertEquals(original, native.source(240).toString())
            assertEquals(checkNotNull(monospaceBold), runPaint(native, prefix.text.length).typeface)
        }
        // The actual block-level legacy family cannot defeat a nonnull Span request.
        compose.runOnIdle { values.value = listOf(prefix, explicit, legacyCode, suffix); mode.value = 1 }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(original, checkNotNull(prepared).text.toString())
            assertEquals(NativeNamedFamilyUnavailable, checkNotNull(prepared).stateDescription)
            assertNull(checkNotNull(prepared).native)
        }
        compose.runOnIdle { mode.value = 0; preformatted.value = false }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertEquals(original, checkNotNull(value.native).source(240).toString())
            val geometry = checkNotNull(value.geometry)(240, emptyList(), false)
            assertEquals(listOf(explicit.text + explicit.trail, "code"), geometry.nodes.filter { it.kind == FloatInteractionKind.LINK }.map { it.label.toString() })
            assertTrue(geometry.rectsForRange(0, original.length).isNotEmpty())
            geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label == explicit.text + explicit.trail }.onClick!!.invoke()
            assertEquals("typed-target", actions.last().target)
        }
    }

    @Test fun declaringFamilyIsIndependentAndHardcodedReplacementRefusesThenRecovers() = control {
        val ownerFamily = ContainerFontFamily.Stack(listOf("Declaring Source Family"), GenericFontFamily.Serif)
        val childFamily = ContainerFontFamily.Stack(listOf("Child Source Family"), GenericFontFamily.SansSerif)
        val snapshot = InlineFontSnapshot(fontScale = 1.75f, fontScaleBasis = FontScaleBasis.NormalBody,
            bold = true, language = "th", fontFamily = ownerFamily)
        val child = Span("link", "independent owner", "owner-target", italic = true, language = "th",
            fontScale = .8f, fontScaleBasis = FontScaleBasis.NormalBody, fontFamily = childFamily,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1.2f, snapshot)))
        val values = mutableStateOf(listOf(child))
        val loadedOwner = mutableStateOf(false)
        val observed = mutableListOf<Triple<String, FontWeight, FontStyle>>()
        val actions = mutableListOf<EntryLink>()
        compose.activityRule.scenario.onActivity { it.setContent {
            val loaded = loadedOwner.value
            val probe = remember(loaded) { NativeNamedFontProbe { _, name, weight, style ->
                observed += Triple(name, weight, style)
                if (loaded && name == "Declaring Source Family") Typeface.SERIF else null
            } }
            PrepareFamilies(values.value, actions, null, probe, computedCell = false)
        } }
        compose.waitForIdle()
        compose.runOnIdle {
            val native = checkNotNull(checkNotNull(prepared).native)
            val source = native.source(240)
            val metric = nativeInlineRanges(source, NativeAuthoredInlineMetrics::class.java).single().value
            assertEquals(24f, metric.primary.fontSize, .001f)
            assertEquals(52.5f, checkNotNull(metric.declaringPrimary).fontSize, .001f)
            assertEquals(63f, (metric.policy as NativeLineHeightPolicy.Pixels).value, .001f)
            assertTrue(observed.contains(Triple("Declaring Source Family", FontWeight.Bold, FontStyle.Normal)))
            assertTrue(observed.contains(Triple("Child Source Family", FontWeight.Normal, FontStyle.Italic)))
            assertFalse(observed.contains(Triple("Child Source Family", FontWeight.Bold, FontStyle.Normal)))
            assertEquals(child.text, source.toString())
        }
        compose.runOnIdle { loadedOwner.value = true }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(child.text, checkNotNull(prepared).text.toString())
            assertNull(checkNotNull(prepared).native)
            assertEquals(NativeNamedFamilyUnavailable, checkNotNull(prepared).stateDescription)
        }
        val glyph = Span("link", "\ud80c\udc00", "glyph-target", classes = "Egyp",
            fontFamily = ContainerFontFamily.SansSerif)
        compose.runOnIdle { values.value = listOf(glyph); loadedOwner.value = false }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(glyph.text, checkNotNull(prepared).text.toString())
            assertEquals(NativeInlineFamilyReplacementUnavailable, checkNotNull(prepared).stateDescription)
            assertNull(checkNotNull(prepared).native)
        }
        compose.runOnIdle { values.value = listOf(child) }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertEquals(child.text, checkNotNull(value.native).source(240).toString())
            val geometry = checkNotNull(value.geometry)(240, emptyList(), false)
            assertTrue(paintHasInk(geometry))
            geometry.nodes.single { it.kind == FloatInteractionKind.LINK }.onClick!!.invoke()
            assertEquals(listOf("owner-target"), actions.map { it.target })
        }
    }

    private var measuredText: NativeFloatContextGeometry? = null
    @Composable private fun MeasuredText(value: PreparedNativeFloatText, box: ParagraphBox?, gap: Float) {
        val parent = remember { NativeLayoutInput(Unit) }
        val input = remember { NativeContextMeasureInput(invalidateParent = parent::invalidate) }
        val environment = NativeFlowEnvironment(density.density, density.fontScale,
            LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
        val preparation = Any()
        Layout(modifier = Modifier.then(parent.modifier), content = {
            CompositionLocalProvider(LocalNativeContextMeasureInput provides input) {
                NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, gap, "empty-source", box)),
                    Modifier, Color.Black) { _, _ -> error("No delegated empty-text child") }
            }
        }) { children, constraints ->
            val childConstraints = Constraints(maxWidth = 240, maxHeight = 400)
            val request = input.request(constraints, childConstraints, environment,
                NativeFlowParentPolicy(preparation, true, null, 0f), emptyList())
            val child = children.single().measure(childConstraints)
            measuredText = input.ready(request)
            layout(constraints.constrainWidth(260), constraints.constrainHeight(child.height + 20)) { child.place(10, 10) }
        }
    }

    @Test fun emptyFamilyOwnerHasNoLineButKeepsRealEdgesAndMetricOwners() = control {
        val empty = Span("text", "", fontFamily = ContainerFontFamily.SansSerif)
        val values = mutableStateOf(listOf(empty))
        val box = mutableStateOf<ParagraphBox?>(null)
        val actions = mutableListOf<EntryLink>()
        val probe = NativeNamedFontProbe { _, _, _, _ -> error("A generic-only family has no named probe") }
        val gap = 2.25f
        compose.activityRule.scenario.onActivity { it.setContent {
            PrepareFamilies(values.value, actions, null, probe, computedCell = false) { value ->
                MeasuredText(value, box.value, gap)
            }
        } }
        compose.waitForIdle()
        compose.runOnIdle {
            assertTrue(checkNotNull(prepared).emptyInlineOwner)
            val geometry = checkNotNull(measuredText)
            assertEquals("", geometry.text.toString())
            assertEquals(gap, geometry.usedHeight, 0f)
            assertTrue(geometry.nodes.isEmpty())
            assertTrue(geometry.inputLeaves().isEmpty())
            assertFalse(paintHasInk(geometry))
        }
        // Legacy null-family empty input keeps its established native line behavior.
        compose.runOnIdle { values.value = listOf(empty.copy(fontFamily = null)) }
        compose.waitForIdle()
        compose.runOnIdle {
            assertFalse(checkNotNull(prepared).emptyInlineOwner)
            assertTrue(checkNotNull(measuredText).usedHeight > gap)
            assertEquals("", checkNotNull(measuredText).text.toString())
        }
        compose.runOnIdle { values.value = listOf(empty.copy(text = "  \u00a0")) }
        compose.waitForIdle()
        compose.runOnIdle {
            assertFalse(checkNotNull(prepared).emptyInlineOwner)
            assertEquals("  \u00a0", checkNotNull(measuredText).text.toString())
            assertEquals(30f + gap, checkNotNull(measuredText).usedHeight, .001f)
        }
        val edges = ParagraphBox(ParagraphEdges(top = 2.5f, bottom = gap),
            ParagraphEdges(top = 3.25f, bottom = 1.5f), 2.5f, gap)
        compose.runOnIdle { values.value = listOf(empty); box.value = edges }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(9.5f, checkNotNull(measuredText).usedHeight, .001f)
            assertTrue(checkNotNull(measuredText).inputLeaves().isEmpty())
        }
        val metric = empty.copy(inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(
            InlineComputedLength(1.5f, FontScaleBasis.NormalBody))))
        compose.runOnIdle { values.value = listOf(metric) }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(prepared)
            assertFalse(value.emptyInlineOwner)
            val source = checkNotNull(value.native).source(0)
            assertEquals("", source.toString())
            assertTrue(hasNativeAuthoredInlineMetrics(source))
            val geometry = checkNotNull(measuredText)
            assertEquals("", geometry.text.toString())
            assertEquals(54.5f, geometry.usedHeight, .001f)
            assertEquals(1, geometry.inputLeaves().size)
            assertTrue(hasNativeAuthoredInlineMetrics(geometry.inputLeaves().single().geometry.text))
            assertTrue(geometry.nodes.isEmpty())
            assertTrue(actions.isEmpty())
        }
    }
}
