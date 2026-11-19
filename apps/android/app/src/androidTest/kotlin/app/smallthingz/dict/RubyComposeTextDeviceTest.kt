package app.smallthingz.dict

import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.performScrollToNode
import kotlin.math.roundToInt
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.click
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.activity.compose.setContent
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.referentialEqualityPolicy
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** These controls exercise the actual Compose lowering, not native Ruby visual qualification. */
@RunWith(AndroidJUnit4::class)
class RubyComposeTextDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    private fun owner(scale: Float = 1f, bold: Boolean = false, italic: Boolean = false,
        code: Boolean = false, family: ContainerFontFamily? = null) = RubyOwner(InlineFontSnapshot(
        fontScale = scale, bold = bold, italic = italic, code = code, fontFamily = family), direction = "ltr")
    private fun ruby(base: List<Span>, reading: List<Span>, baseOwner: RubyOwner = owner(),
        readingOwner: RubyOwner = owner(.5f)): Span = Span("text", "", ruby = Ruby(listOf(RubySegment(emptyList(),
        listOf(RubyBase(baseOwner, emptyList(), base)), listOf(RubyAnnotation(0, 1, 0, readingOwner,
            emptyList(), reading, emptyList(), emptyList(), false))))))

    private inline fun control(body: () -> Unit) {
        var primary: Throwable? = null
        try { body() } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

    private fun styleAt(text: AnnotatedString, offset: Int): SpanStyle = text.spanStyles
        .filter { it.start <= offset && it.end > offset }
        .fold(SpanStyle()) { value, range -> value.merge(range.item) }

    @Test fun completeChildTraitsAndNestedContextScalesUseOriginalBasisOnce() = control {
        val plain = Span("link", "same", "normal-child", fontScale = .5f)
        val inherited = Span("link", "same", "bold-child", fontScale = .5f, bold = true, italic = true)
        val nestedLeaf = Span("text", "nested", fontScale = .5f)
        val nested = ruby(listOf(nestedLeaf), emptyList(), baseOwner = owner(.5f))
        val source = listOf(ruby(listOf(plain, inherited, nested), listOf(Span("text", "reading", fontScale = .5f)),
            baseOwner = owner(.5f, bold = true, italic = true), readingOwner = owner(.5f))
            .copy(superscript = true, underline = true, background = "#ff0000"))
        var contexts: RubyStyledTextContexts? = null
        var annotated = AnnotatedString("")
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 30.sp))) {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    val style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.Bold, fontStyle = FontStyle.Italic,
                        fontFeatureSettings = "\"liga\" 0")
                    val resolved = rubyStyledTextContexts(source, null, style)
                    val text = styledTextAnnotation(source, null, style) { }
                    SideEffect { contexts = resolved; annotated = text }
                }
            }
        } }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(contexts)
            assertEquals("samesamenestedreading", annotated.text)
            val base = value.groups.values.first { it.range.role == RubyTextRole.Base }
            val outer = value.groups.values.first { it.range.role == RubyTextRole.Owner }
            assertEquals(BaselineShift.Superscript, outer.style.baselineShift)
            assertEquals(TextDecoration.Underline, outer.style.textDecoration)
            assertEquals(Color.Red, outer.style.background)
            assertEquals(10.sp, base.style.fontSize)
            assertEquals(FontWeight.Bold, base.style.fontWeight)
            assertEquals(FontStyle.Italic, base.style.fontStyle)
            assertEquals("\"liga\" 0", base.style.fontFeatureSettings)
            val inner = value.groups.values.single { it.range.base?.spans?.singleOrNull() === nestedLeaf }
            assertEquals(10.sp, inner.style.fontSize)
            assertEquals(20.sp, inner.fontBasisStyle.fontSize)
            assertEquals("\"liga\" 0", inner.style.fontFeatureSettings)
            val first = value.leaves.single { it.range.span === plain }
            val second = value.leaves.single { it.range.span === inherited }
            val reset = styleAt(annotated, first.range.start)
            val retained = styleAt(annotated, second.range.start)
            assertEquals(FontWeight.Normal, reset.fontWeight)
            assertEquals(FontStyle.Normal, reset.fontStyle)
            assertEquals("\"liga\" 0", reset.fontFeatureSettings)
            assertEquals(FontWeight.Bold, retained.fontWeight)
            assertEquals(FontStyle.Italic, retained.fontStyle)
            assertTrue(reset.fontSize.isEm)
            assertEquals(.5f, reset.fontSize.value, 0f)
            assertEquals(20.sp, first.fontBasisStyle.fontSize)
            assertEquals(BaselineShift.None, first.enclosingStyle.baselineShift)
            assertEquals(TextDecoration.None, first.enclosingStyle.textDecoration)
            assertEquals(Color.Unspecified, first.enclosingStyle.background)
            val links = annotated.getLinkAnnotations(0, annotated.length)
            assertEquals(listOf("normal-child", "bold-child"), links.map { (it.item as LinkAnnotation.Clickable).tag })
            assertEquals(listOf(first.range.start, second.range.start), links.map { it.start })
        }
    }

    @Test fun sourceFamilyAndIndependentTextBasesSurviveOwnerCodeAndContextChanges() = control {
        val inheritedFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)
        val explicitFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.SansSerif)
        val plain = Span("text", "plain", fontScale = .5f)
        val explicit = Span("text", "explicit", fontScale = .5f, fontFamily = explicitFamily)
        val normalBody = Span("text", "body", fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody)
        val css = Span("text", "css", fontScale = 8f, fontScaleBasis = FontScaleBasis.CssPx)
        val egyptianChild = Span("text", "inherited-family")
        val egyptianOverride = Span("text", "explicit-family", fontFamily = explicitFamily)
        val egyptianOwner = RubyOwner(InlineFontSnapshot(fontScale = .5f, classes = "Egyp"))
        val source = listOf(ruby(listOf(plain, explicit, normalBody, css), emptyList(), baseOwner = owner(.5f, code = true)),
            ruby(listOf(egyptianChild, egyptianOverride), emptyList(), baseOwner = egyptianOwner))
        val zoom = mutableStateOf(1f)
        var contexts: RubyStyledTextContexts? = null
        var annotated = AnnotatedString("")
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 32.sp))) {
                CompositionLocalProvider(LocalDensity provides Density(1f), LocalCssPixelTextZoom provides zoom.value,
                    LocalNativeContainerTextContext provides ContainerTextContext(fontFamily = inheritedFamily)) {
                    val style = TextStyle(fontSize = 20.sp, fontFamily = FontFamily.Serif)
                    val value = rubyStyledTextContexts(source, null, style)
                    val text = styledTextAnnotation(source, null, style) { }
                    SideEffect { contexts = value; annotated = text }
                }
            }
        } }
        for (factor in listOf(1f, 1.5f)) {
            compose.runOnIdle { zoom.value = factor }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(contexts)
                val base = value.groups.values.single { it.range.base?.owner?.font?.code == true }
                assertEquals(LegacySpanFontFamily.Code, base.legacyFamily)
                assertNull(base.sourceFamily)
                val leaf = value.leaves.single { it.range.span === plain }
                assertSame(inheritedFamily, leaf.sourceFamily)
                assertNull(leaf.legacyFamily)
                assertEquals(FontFamily.Serif, styleAt(annotated, leaf.range.start).fontFamily)
                val own = value.leaves.single { it.range.span === explicit }
                assertSame(explicitFamily, own.range.span!!.fontFamily)
                assertEquals(FontFamily.SansSerif, styleAt(annotated, own.range.start).fontFamily)
                val body = value.leaves.single { it.range.span === normalBody }
                assertEquals(16.sp, styleAt(annotated, body.range.start).fontSize)
                val px = value.leaves.single { it.range.span === css }
                assertEquals((8f * factor).sp, styleAt(annotated, px.range.start).fontSize)
                assertEquals(.5f, styleAt(annotated, leaf.range.start).fontSize.value, 0f)
                assertSame(source.first().ruby!!.segments.single().bases.single(), base.range.base)
                val egyptian = value.groups.values.single { it.range.base?.owner === egyptianOwner }
                val inheritedEgyptian = value.leaves.single { it.range.span === egyptianChild }
                assertEquals(LegacySpanFontFamily.Egyptian, inheritedEgyptian.legacyFamily)
                assertNull(inheritedEgyptian.sourceFamily)
                assertEquals(egyptian.style.fontFamily, styleAt(annotated, inheritedEgyptian.range.start).fontFamily)
                val overriddenLeaf = value.leaves.single { it.range.span === egyptianOverride }
                assertEquals(FontFamily.SansSerif, styleAt(annotated, overriddenLeaf.range.start).fontFamily)
            }
        }
    }

    @Test fun exactGraphicalOffsetsAndExplicitFallbackKeepOrdinaryNullPathSeparate() = control {
        val child = Span("link", "X\ud83d\ude80", "base", trail = "\u0301", direction = "rtl")
        val reading = Span("link", "Y", "reading", direction = "ltr")
        val source = listOf(ruby(listOf(child), listOf(reading)))
        val currentSource = mutableStateOf(source, referentialEqualityPolicy())
        val ordinary = listOf(Span("text", "old", direction = "rtl"))
        val fallback = mutableStateOf(false)
        var contexts: RubyStyledTextContexts? = null
        var typed = AnnotatedString("")
        var legacy = AnnotatedString("")
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme {
                val style = TextStyle(fontSize = 20.sp)
                val value = rubyStyledTextContexts(currentSource.value, null, style)
                val current = styledTextAnnotation(currentSource.value, null, style) { }
                val old = styledTextAnnotation(ordinary, null, style) { }
                SideEffect { contexts = value; typed = current; legacy = old }
                if (fallback.value) CompositionLocalProvider(LocalRubyNative provides false,
                    LocalNativeContainerTextContext provides ContainerTextContext(fontFamily = ContainerFontFamily.SansSerif)) {
                    StyledText(currentSource.value, style = style, preserveWhitespace = true)
                }
            }
        } }
        compose.waitForIdle()
        compose.runOnIdle {
            val value = checkNotNull(contexts)
            assertEquals("X\ud83d\ude80\u0301Y", typed.text)
            assertEquals(value.projection.text, typed.text)
            assertEquals("\u2067old\u2069", legacy.text)
            assertSame(child, value.leaves.first().range.span)
            assertSame(reading, value.leaves.last().range.span)
            assertEquals(listOf(0, 4), typed.getLinkAnnotations(0, typed.length).map { it.start })
            assertEquals(listOf(4, 5), typed.getLinkAnnotations(0, typed.length).map { it.end })
        }
        val replacement = child.copy()
        compose.runOnIdle { currentSource.value = listOf(ruby(listOf(replacement), listOf(reading))) }
        compose.waitForIdle()
        compose.runOnIdle {
            assertSame(replacement, checkNotNull(contexts).leaves.first().range.span)
            assertNotSame(child, checkNotNull(contexts).leaves.first().range.span)
            fallback.value = true
        }
        compose.waitForIdle()
        compose.onNodeWithText("\u2067X\ud83d\ude80\u0301\u2069\uff08\u2066Y\u2069\uff09").assertIsDisplayed()
    }

    @Test fun preparedNativeSourceKeepsDeclaringPaintEmptyReadingAndFailureRecovery() = control {
        val baseLink = Span("link", "base", "base-action", fontScale = .5f)
        val readingLink = Span("link", "read", "reading-action", fontScale = .5f)
        fun source(language: String): List<Span> {
            val font = InlineFontSnapshot(fontScale = .75f, bold = true, italic = true, language = language)
            val baseOwner = RubyOwner(font, direction = "rtl", inlineStyle = InlineTextStyle(
                lineHeight = InlineLineHeight.FontRelative(1.2f, font),
                baselineShift = InlineComputedLength(.25f, FontScaleBasis.CssPx)))
            return listOf(Span("text", "", ruby = Ruby(listOf(RubySegment(emptyList(),
                listOf(RubyBase(baseOwner, emptyList(), listOf(baseLink))), listOf(
                    RubyAnnotation(0, 1, 0, owner(.5f), emptyList(), emptyList(), emptyList(), emptyList(), false),
                    RubyAnnotation(0, 1, 1, owner(.5f), emptyList(), listOf(readingLink), emptyList(), emptyList(), false)))))))
        }
        val current = mutableStateOf(source("ja"))
        var prepared: PreparedNativeFloatText? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 32.sp))) {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    val spans = current.value
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp)
                    val annotated = styledTextAnnotation(spans, null, style) { }
                    val value = prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", {},
                        nativeLineHeight = NativeLineHeightPolicy.Pixels(24f))
                    SideEffect { prepared = value }
                }
            }
        } }
        for (language in listOf("ja", "en--US", "ja")) {
            compose.runOnIdle { current.value = source(language) }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertEquals("baseread", value.text.toString())
                if (language == "en--US") {
                    assertNull(value.native)
                    assertTrue(value.stateDescription.orEmpty().contains("language"))
                } else {
                    assertNull(value.stateDescription)
                    val native = checkNotNull(value.native)
                    val spanned = native.source(400)
                    assertEquals("baseread", spanned.toString())
                    val source = spanned.getSpans(0, spanned.length, NativeRubyPreparedSource::class.java).single()
                    assertEquals("baseread", source.source.toString())
                    val root = source.projection.ranges.single { it.role == RubyTextRole.Owner }
                    val base = source.projection.ranges.single { it.role == RubyTextRole.Base }
                    val empty = source.projection.ranges.single { it.annotation?.spans?.isEmpty() == true }
                    assertEquals(20f, source.groups.getValue(root.path).paint.textSize, .001f)
                    val format = source.groups.getValue(base.path)
                    assertEquals(15f, format.paint.textSize, .001f)
                    assertTrue(format.paint.typeface.isBold)
                    assertTrue(format.paint.typeface.isItalic)
                    assertEquals(0, format.paint.baselineShift)
                    assertEquals(0f, format.baselineShift, 0f)
                    assertEquals(-.25f, checkNotNull(format.localBaselineShift), .001f)
                    assertNull(source.groups.getValue(root.path).localBaselineShift)
                    assertNull(source.groups.getValue(empty.path).localBaselineShift)
                    assertEquals(NativeLineHeightPolicy.Pixels(18f), format.lineHeight)
                    assertEquals("rtl", format.sourceDirection)
                    assertEquals(empty.start, empty.end)
                    assertEquals(10f, source.groups.getValue(empty.path).paint.textSize, .001f)
                    val leaf = source.projection.ranges.single { it.span === baseLink }
                    val childPaint = TextPaint(native.paint)
                    spanned.getSpans(leaf.start, leaf.end, MetricAffectingSpan::class.java)
                        .filter { spanned.getSpanStart(it) <= leaf.start && spanned.getSpanEnd(it) >= leaf.end }
                        .forEach { it.updateMeasureState(childPaint) }
                    assertEquals(10f, childPaint.textSize, .001f)
                    assertFalse(childPaint.typeface.isBold)
                    assertFalse(childPaint.typeface.isItalic)
                    assertEquals(0, childPaint.baselineShift)
                    val actions = source.projection.ranges.filter { it.span?.kind == "link" }
                    assertEquals(listOf("base-action", "reading-action"), actions.map { it.span!!.target })
                    assertEquals(listOf(0 to 4, 4 to 8), actions.map { it.start to it.end })
                    assertSame(baseLink, actions.first().span)
                    assertSame(readingLink, actions.last().span)
                }
            }
        }
    }

    @Test fun noWrapSourceStartsKeepRubyGapControlsOutOfHardParagraphs() = control {
        val gap = Span("text", "\r\n\t")
        val typed = listOf(Span("text", "p"), Span("line_break", ""), Span("text", "", ruby = Ruby(listOf(
            RubySegment(emptyList(), listOf(
                RubyBase(owner(), emptyList(), listOf(Span("text", "A"))),
                RubyBase(owner(), listOf(gap), listOf(Span("text", "B"))),
            ), emptyList()),
        ))))
        val ordinary = listOf(Span("text", "p"), Span("line_break", ""), Span("text", "B"))
        val source = mutableStateOf(typed)
        var prepared: PreparedNativeFloatText? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    val spans = source.value
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp)
                    val annotation = styledTextAnnotation(spans, null, style) { }
                    val value = prepareNativeFloatText(spans, annotation, egyptianTextRuns(spans), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", {},
                        nativeLineHeight = NativeLineHeightPolicy.Pixels(24f), ownerWrap = TextWrap.NoWrap)
                    SideEffect { prepared = value }
                }
            }
        } }
        for (hasRuby in listOf(true, false, true)) {
            compose.runOnIdle { source.value = if (hasRuby) typed else ordinary }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                val expected = if (hasRuby) "p\nA\r\n\tB" else "p\nB"
                assertNull(value.stateDescription)
                assertEquals(expected, value.text.toString())
                val native = checkNotNull(value.native).source(400)
                assertEquals(expected, native.toString())
                val wrap = native.getSpans(0, native.length, NativeAuthoredTextWrap::class.java).single()
                assertEquals(TextWrap.NoWrap, wrap.wrap)
                assertTrue(wrap.inheritedOwner)
                assertEquals(listOf(0, 2), wrap.sourceLineStarts)
                val markers = native.getSpans(0, native.length, NativeRubyPreparedSource::class.java)
                if (hasRuby) {
                    val marker = markers.single()
                    assertEquals(expected, marker.projection.text)
                    assertEquals(expected, marker.source.toString())
                    val originalGap = marker.projection.ranges.single { it.span === gap }
                    assertEquals(RubyTextRole.BaseGap, originalGap.role)
                    assertEquals(3 to 6, originalGap.start to originalGap.end)
                    assertEquals("\r\n\t", expected.substring(originalGap.start, originalGap.end))
                    assertFalse(checkNotNull(wrap.sourceLineStarts).contains(5))
                } else assertTrue(markers.isEmpty())
            }
        }
    }


    @Test fun composedRubyKeepsOriginalActionsSelectionAndNativeInkAcrossRemeasure() = control {
        // Synthetic typed source, not a producer fixture. Raster evidence below is the actual
        // owned View drawn onto our Canvas; it is not a compositor/window capture.
        val before = Span("link", "\u524d\ud83d\ude80", "ordinary-before", targetFragment = "start", foreground = "#008000")
        val day = Span("link", "\u65e5", "base-day", targetFragment = "one", foreground = "#0000ff")
        val origin = Span("link", "\u672c", "base-origin", foreground = "#0000ff")
        val dayReading = Span("link", "\u306b", "reading-day", fontScale = .5f, foreground = "#ff0000")
        val originReading = Span("link", "\u307b\u3093", "reading-origin", targetFragment = "two", fontScale = .5f, foreground = "#ff0000")
        val after = Span("link", "\u5f8c", "ordinary-after", foreground = "#008000")
        val typed = Span("text", "", direction = "ltr", ruby = Ruby(listOf(RubySegment(emptyList(),
            listOf(RubyBase(owner(), emptyList(), listOf(day)), RubyBase(owner(), emptyList(), listOf(origin))),
            listOf(RubyAnnotation(0, 1, 0, owner(.5f), emptyList(), listOf(dayReading), emptyList(), emptyList(), false),
                RubyAnnotation(1, 1, 0, owner(.5f), emptyList(), listOf(originReading), emptyList(), emptyList(), false))))))
        val spans = listOf(before, Span("text", " "), typed, Span("text", " "), after)
        val expected = "\u524d\ud83d\ude80 \u65e5\u672c\u306b\u307b\u3093 \u5f8c"
        data class Action(val span: Span, val start: Int, val end: Int, val target: EntryLink, val color: Int)
        // These offsets are literal UTF-16 source positions: the supplementary rocket occupies 1..3.
        val actions = listOf(
            Action(before, 0, 3, EntryLink("ordinary-before", "start"), 2),
            Action(day, 4, 5, EntryLink("base-day", "one"), 0),
            Action(origin, 5, 6, EntryLink("base-origin"), 0),
            Action(dayReading, 6, 7, EntryLink("reading-day"), 1),
            Action(originReading, 7, 9, EntryLink("reading-origin", "two"), 1),
            Action(after, 10, 11, EntryLink("ordinary-after"), 2),
        )
        data class Phase(val width: Int, val rtl: Boolean)
        val phases = listOf(Phase(240, false), Phase(72, false), Phase(72, true), Phase(240, true), Phase(240, false))
        val phase = mutableStateOf(phases.first())
        val rasterFocus = androidx.compose.ui.focus.FocusRequester()
        val callbacks = mutableListOf<EntryLink>()
        val onLink: (EntryLink) -> Unit = { callbacks += it }
        var prepared: PreparedNativeFloatText? = null
        var committed: Phase? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme {
                val current = phase.value
                CompositionLocalProvider(LocalDensity provides Density(1f), LocalLayoutDirection provides
                    if (current.rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                        textDirection = if (current.rtl) TextDirection.Rtl else TextDirection.Ltr)
                    val annotated = styledTextAnnotation(spans, null, style, onLink)
                    val value = prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", onLink,
                        nativeLineHeight = NativeLineHeightPolicy.Pixels(24f))
                    SideEffect { prepared = value; committed = current }
                    Box(Modifier.fillMaxSize().background(Color.White).safeDrawingPadding().padding(16.dp)
                        .testTag("ruby-native-raster").focusRequester(rasterFocus).focusable()) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                            Modifier.width(current.width.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            error("The Ruby text fixture has no delegated child")
                        }
                    }
                }
            }
        } }
        fun collect(view: android.view.View): List<NativeFloatTextView> = buildList {
            if (view is NativeFloatTextView) add(view)
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) addAll(collect(view.getChildAt(index)))
        }
        data class Raster(val width: Int, val height: Int, val pixels: IntArray)
        fun draw(view: NativeFloatTextView): Raster {
            val bitmap = android.graphics.Bitmap.createBitmap(view.width, view.height, android.graphics.Bitmap.Config.ARGB_8888)
            var primary: Throwable? = null
            try {
                bitmap.eraseColor(android.graphics.Color.WHITE)
                view.draw(android.graphics.Canvas(bitmap))
                return Raster(bitmap.width, bitmap.height, IntArray(bitmap.width * bitmap.height).also {
                    bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                })
            } catch (failure: Throwable) { primary = failure; throw failure }
            finally {
                try { bitmap.recycle() } catch (cleanup: Throwable) {
                    val failure = primary
                    if (failure == null) throw cleanup
                    if (failure !== cleanup) failure.addSuppressed(cleanup)
                }
            }
        }
        var retainedView: NativeFloatTextView? = null
        var originalIds: List<Int>? = null
        var initialRaster: Raster? = null
        var initialRects: List<List<android.graphics.RectF>>? = null
        var wideHeight = 0
        for ((phaseIndex, current) in phases.withIndex()) try {
            compose.runOnIdle { phase.value = current }
            // The post-write barrier must complete the actual Compose/AndroidView remeasure.
            compose.waitForIdle()
            var rasterFocusRequested = false
            compose.runOnIdle {
                val view = collect(compose.activityRule.activity().window.decorView).single()
                // End only this fixture's native host ring via its owned nonpainting destination.
                // No clearFocus/global touch-mode change or virtual-node focus action is used.
                if (view.hasFocus()) {
                    assertTrue(rasterFocus.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter))
                    rasterFocusRequested = true
                }
                assertFalse(view.hasFocus())
            }
            if (rasterFocusRequested) compose.onNodeWithTag("ruby-native-raster").assertIsFocused()
            compose.runOnIdle {
                assertEquals(current, committed)
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                assertEquals(expected, value.text.toString())
                val original = checkNotNull(value.native).source(current.width)
                val marker = original.getSpans(0, original.length, NativeRubyPreparedSource::class.java).single()
                assertEquals(expected, marker.projection.text)
                assertSame(typed, marker.projection.ranges.single { it.role == RubyTextRole.Owner }.span)
                for (action in actions) {
                    val source = marker.projection.ranges.single { it.span === action.span }
                    assertEquals(action.start to action.end, source.start to source.end)
                }
                val view = collect(compose.activityRule.activity().window.decorView).single()
                if (retainedView == null) retainedView = view else assertSame(retainedView, view)
                assertTrue(view.isAttachedToWindow && view.isShown)
                assertTrue(view.width > 0 && view.height > 0)
                assertFalse(view.defaultFocusHighlightEnabled)
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                assertEquals(expected, view.logicalText.toString())
                assertEquals(expected, geometry.text.toString())
                assertEquals(actions.map { it.start to it.end }, geometry.nodes.map { it.start to it.end })
                assertTrue(geometry.nodes.all { it.kind == FloatInteractionKind.LINK })
                val ids = geometry.nodes.map { it.id }
                if (originalIds == null) originalIds = ids else assertEquals(originalIds, ids)
                if (phaseIndex > 0) {
                    assertEquals(0, view.selectionStart)
                    assertEquals(expected.length, view.selectionEnd)
                    assertEquals(expected, view.selectedTextForCopy())
                }
                val provider = view.accessibilityNodeProvider
                val hostId = android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID
                val setSelection = android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION
                assertTrue(provider.performAction(hostId, setSelection, null))
                assertNull(view.selectedTextForCopy())
                val host = checkNotNull(provider.createAccessibilityNodeInfo(hostId))
                try { assertEquals(expected, host.text.toString()); assertEquals(actions.size, host.childCount) }
                finally { host.recycle() }
                val screenOrigin = IntArray(2).also(view::getLocationOnScreen)
                // This fixture supplies no scrollport, transforms, or View padding. Still include
                // the observed padding and screen origin in the independent AX projection.
                var ancestor: android.view.View? = view
                while (ancestor != null) {
                    assertTrue(ancestor.matrix.isIdentity)
                    assertEquals(0, ancestor.scrollX); assertEquals(0, ancestor.scrollY)
                    ancestor = ancestor.parent as? android.view.View
                }
                val callbackStart = callbacks.size
                for ((index, action) in actions.withIndex()) {
                    val node = geometry.nodes[index]
                    assertEquals(expected.substring(action.start, action.end), node.label.toString())
                    assertTrue(node.bounds.isNotEmpty() && node.bounds.all { !it.isEmpty })
                    assertEquals(geometry.rectsForRange(action.start, action.end), node.bounds)
                    assertNull(node.clipBounds); assertNull(node.preciseClip)
                    val bounds = android.graphics.RectF().also { union -> node.bounds.forEach(union::union) }
                    val parentBounds = android.graphics.Rect().also(bounds::roundOut).apply {
                        offset(view.paddingLeft, view.paddingTop)
                    }
                    val screenBounds = android.graphics.RectF(bounds).apply {
                        offset((screenOrigin[0] + view.paddingLeft).toFloat(), (screenOrigin[1] + view.paddingTop).toFloat())
                    }.let { rect -> android.graphics.Rect().also(rect::roundOut) }
                    val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                    try {
                        assertEquals(expected.substring(action.start, action.end), info.text.toString())
                        assertTrue(info.isClickable && info.isVisibleToUser)
                        assertFalse(info.isFocused); assertFalse(info.isAccessibilityFocused)
                        assertEquals(parentBounds, android.graphics.Rect().also(info::getBoundsInParent))
                        assertEquals(screenBounds, android.graphics.Rect().also(info::getBoundsInScreen))
                    } finally { info.recycle() }
                    assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals(action.target, callbacks.last())
                    assertEquals(callbackStart + index + 1, callbacks.size)
                    val characters = geometry.characterRects(action.start, action.end - action.start)
                    assertEquals(action.end - action.start, characters.size)
                    assertTrue(characters.any { it != null && !it.isEmpty })
                }
                assertEquals(actions.map { it.target }, callbacks.drop(callbackStart))
                for ((baseOffset, readingOffset) in listOf(4 to 6, 5 to 7)) {
                    val baseLine = geometry.visualLineRanges(baseOffset)
                    val readingLine = geometry.visualLineRanges(readingOffset)
                    assertTrue(baseLine.any { baseOffset >= it.first && baseOffset < it.second })
                    assertTrue(readingLine.any { readingOffset >= it.first && readingOffset < it.second })
                    // One indivisible base grapheme and its reading share real visual fragments.
                    assertEquals(baseLine, readingLine)
                }
                for (offset in listOf(0, 1, 3, 4, 5, 6, 7, 9, 10, 11)) {
                    val caret = geometry.caretRect(offset)
                    assertTrue(listOf(caret.left, caret.top, caret.right, caret.bottom).all { it.isFinite() })
                    assertTrue(caret.height() > 0f)
                }
                assertFalse("Native host focus must not paint a ring in the source-ink witness", view.hasFocus())
                val raster = draw(view)
                fun ink(index: Int): List<Pair<Int, Int>> {
                    val node = geometry.nodes[index]
                    val color = actions[index].color
                    val points = mutableListOf<Pair<Int, Int>>()
                    for (y in 0 until raster.height) for (x in 0 until raster.width) {
                        if (node.bounds.none { it.contains(x + .5f - view.paddingLeft, y + .5f - view.paddingTop) }) continue
                        val pixel = raster.pixels[y * raster.width + x]
                        val r = android.graphics.Color.red(pixel); val g = android.graphics.Color.green(pixel)
                        val b = android.graphics.Color.blue(pixel)
                        // Exact channel relation for any positive source-color contribution on white.
                        val matches = android.graphics.Color.alpha(pixel) == 255 && when (color) {
                            0 -> b > r && r == g
                            1 -> r > g && g == b
                            else -> g > r && r == b
                        }
                        if (matches) points += x to y
                    }
                    assertTrue("Missing actual source-colored glyph ink for ${actions[index].target}", points.isNotEmpty())
                    val point = points[points.size / 2]
                    assertEquals(node.id, checkNotNull(geometry.interactionNodeAt(
                        point.first + .5f - view.paddingLeft, point.second + .5f - view.paddingTop)).id)
                    return points
                }
                val painted = actions.indices.map(::ink)
                // Source reading paint must be above its associated base, independent of font pixels/counts.
                assertTrue(painted[3].map { it.second }.average() < painted[1].map { it.second }.average())
                assertTrue(painted[4].map { it.second }.average() < painted[2].map { it.second }.average())
                if (phaseIndex == 0) {
                    initialRaster = raster
                    initialRects = geometry.nodes.map { node -> node.bounds.map { android.graphics.RectF(it) } }
                    val sourceBounds = android.graphics.RectF().also { union ->
                        geometry.nodes.flatMap { it.bounds }.forEach(union::union)
                    }
                    assertTrue("The actual wide source must exceed the chosen narrow width", sourceBounds.width() > 72f)
                    wideHeight = view.height
                } else if (current.width == 72) {
                    assertTrue(view.width < checkNotNull(initialRaster).width)
                    assertTrue(view.height > wideHeight)
                } else if (phaseIndex == phases.lastIndex) {
                    val first = checkNotNull(initialRaster)
                    assertEquals(first.width, raster.width); assertEquals(first.height, raster.height)
                    assertArrayEquals(first.pixels, raster.pixels)
                    assertEquals(initialRects, geometry.nodes.map { it.bounds })
                }
                fun select(start: Int, end: Int, text: String) {
                    val arguments = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
                    }
                    assertTrue(provider.performAction(hostId, setSelection, arguments))
                    assertEquals(start, view.selectionStart); assertEquals(end, view.selectionEnd)
                    assertEquals(text, view.selectedTextForCopy())
                }
                select(1, 3, "\ud83d\ude80")
                select(4, 9, "\u65e5\u672c\u306b\u307b\u3093")
                select(0, 11, expected)
            }
        } catch (failure: Throwable) {
            val phaseContext = AssertionError("Ruby Compose/native phase=$phaseIndex width=${current.width} rtl=${current.rtl}")
            if (failure !== phaseContext) failure.addSuppressed(phaseContext)
            throw failure
        }
    }

    @Test fun typedWrapOnlyGapRetainsRawSourceAndRejectsOtherWhitespaceOwners() = control {
        // Synthetic producer-shaped gap: raw CSS whitespace under one unchanged wrap policy.
        // The geometry factory is the actual native consumer, not a mock of its admission rule.
        val first = Span("text", "A")
        val last = Span("text", "B")
        val normalGaps = listOf(Span("text", "\r\n", inlineStyle = InlineTextStyle(wrap = TextWrap.Normal)),
            Span("text", "\t", inlineStyle = InlineTextStyle(wrap = TextWrap.Normal)))
        val breakWordGaps = normalGaps.map { it.copy(inlineStyle = InlineTextStyle(wrap = TextWrap.BreakWord)) }
        val distinctGaps = listOf(normalGaps.first(), normalGaps.last().copy(inlineStyle = InlineTextStyle(
            wrap = TextWrap.Normal, lineHeight = InlineLineHeight.Computed(InlineComputedLength(30f, FontScaleBasis.CssPx)))))
        val sharedSpace = Span("text", " ", inlineStyle = InlineTextStyle(wrap = TextWrap.Normal))
        fun typed(gaps: List<Span>, tail: List<Span> = listOf(last)): List<Span> = listOf(
            Span("text", "", ruby = Ruby(listOf(RubySegment(emptyList(), listOf(
                RubyBase(owner(), emptyList(), listOf(first)), RubyBase(owner(), gaps, tail),
            ), emptyList())))))
        val original = typed(normalGaps)
        data class Phase(val name: String, val spans: List<Span>, val expected: String,
            val gaps: List<Span>? = null, val refusedByBridge: Boolean = false, val refusedByNative: Boolean = false)
        val phases = listOf(
            Phase("uniform-normal", original, "A\r\n\tB", normalGaps),
            Phase("uniform-break-word", typed(breakWordGaps), "A\r\n\tB", breakWordGaps),
            Phase("legacy", listOf(first) + normalGaps + last, "A\r\n\tB", refusedByBridge = true),
            Phase("same-object-gap-and-body", typed(listOf(sharedSpace), listOf(sharedSpace, last)), "A  B",
                refusedByBridge = true),
            Phase("later-gap-metric", typed(distinctGaps), "A\r\n\tB", distinctGaps, refusedByNative = true),
            Phase("uniform-recovery", original, "A\r\n\tB", normalGaps),
        )
        val current = mutableStateOf(original, referentialEqualityPolicy())
        var prepared: PreparedNativeFloatText? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    val spans = current.value
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp)
                    val annotation = styledTextAnnotation(spans, null, style) { }
                    val value = prepareNativeFloatText(spans, annotation, egyptianTextRuns(spans), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", {},
                        nativeLineHeight = NativeLineHeightPolicy.Pixels(24f))
                    SideEffect { prepared = value }
                }
            }
        } }
        for (phase in phases) {
            compose.runOnIdle { current.value = phase.spans }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertEquals(phase.name, phase.expected, value.text.toString())
                if (phase.refusedByBridge) {
                    assertNull(phase.name, value.native)
                    assertEquals(phase.name, "Authored inline whitespace effects require a retained collapsed source owner",
                        value.stateDescription)
                    if (phase.name == "same-object-gap-and-body") {
                        val occurrences = rubyGraphicalProjection(phase.spans).ranges.filter { it.span === sharedSpace }
                        assertEquals(listOf(RubyTextRole.BaseGap, RubyTextRole.BaseText), occurrences.map { it.role })
                        assertEquals(listOf(1 to 2, 2 to 3), occurrences.map { it.start to it.end })
                    }
                } else {
                    assertNull(phase.name, value.stateDescription)
                    val source = checkNotNull(value.native).source(400)
                    assertEquals(phase.name, phase.expected, source.toString())
                    val marker = source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).single()
                    assertEquals(phase.expected, marker.source.toString())
                    assertEquals(phase.expected, marker.projection.text)
                    val ranges = marker.projection.ranges.filter { it.role == RubyTextRole.BaseGap }
                    assertEquals(listOf(1 to 3, 3 to 4), ranges.map { it.start to it.end })
                    val gaps = checkNotNull(phase.gaps)
                    ranges.forEachIndexed { index, range ->
                        assertSame(gaps[index], range.span)
                        assertEquals(gaps[index].text, source.subSequence(range.start, range.end).toString())
                        val wrap = source.getSpans(range.start, range.end, NativeAuthoredTextWrap::class.java).single()
                        assertEquals(gaps[index].inlineStyle!!.wrap, wrap.wrap)
                        assertEquals(range.start, source.getSpanStart(wrap))
                        assertEquals(range.end, source.getSpanEnd(wrap))
                    }
                    val factory = checkNotNull(value.geometry)
                    if (phase.refusedByNative) {
                        val failure = assertThrows(UnsupportedFloatLayout::class.java) { factory(400, emptyList(), false) }
                        assertEquals("Collapsed ruby gap has distinct source inline owners", failure.message)
                        assertEquals(phase.expected, source.toString())
                        assertSame(distinctGaps.last(), ranges.last().span)
                    } else {
                        val geometry = factory(400, emptyList(), false)
                        assertEquals(phase.expected, geometry.text.toString())
                        // The retained LF is part of the collapsed gap, not a source hard line.
                        assertEquals('\n', geometry.text[2])
                        assertFalse(geometry.isHardLineBreak(2))
                        val line = geometry.visualLineRanges(0)
                        assertEquals(phase.name, line, geometry.visualLineRanges(4))
                        assertTrue(line.any { 0 >= it.first && 0 < it.second })
                        assertTrue(line.any { 4 >= it.first && 4 < it.second })
                        assertTrue(geometry.rectsForRange(1, 4).any { it.width() > 0f && it.height() > 0f })
                    }
                }
            }
        }
    }

    @Test fun scriptAndSmallSizingUseOriginalBasisOnceForDeclaringOwnerAndChild() = control {
        // Synthetic source policy: numeric scale stays .5; unnormalized legacy traits
        // supply one .8 factor, even when small and superscript are both true.
        data class Reading(val annotation: RubyAnnotation, val leaf: Span, val usesBody: Boolean,
            val normalized: Boolean)
        fun reading(text: String, basis: FontScaleBasis = FontScaleBasis.Context, small: Boolean = false,
            superscript: Boolean = false, subscript: Boolean = false, normalized: Boolean = false): Reading {
            val font = InlineFontSnapshot(fontScale = .5f, fontScaleBasis = basis, fontNormalized = normalized,
                small = small, superscript = superscript, subscript = subscript)
            val leaf = Span("text", text, fontScale = .5f, fontScaleBasis = basis,
                small = small, superscript = superscript, subscript = subscript,
                inlineStyle = if (normalized) InlineTextStyle(fontNormalized = true) else null)
            val annotation = RubyAnnotation(0, 1, 0, RubyOwner(font, direction = "ltr"), emptyList(),
                listOf(leaf), emptyList(), emptyList(), false)
            return Reading(annotation, leaf, basis == FontScaleBasis.NormalBody, normalized)
        }
        val readings = listOf(
            reading("sup", superscript = true),
            reading("sub", subscript = true),
            reading("small-sup", small = true, superscript = true),
            reading("body", basis = FontScaleBasis.NormalBody, superscript = true),
            reading("normalized", basis = FontScaleBasis.NormalBody, superscript = true, normalized = true),
        )
        val source = readings.map { item ->
            val base = RubyBase(owner(), emptyList(), listOf(Span("text", "B")))
            val segment = RubySegment(emptyList(), listOf(base), listOf(item.annotation))
            Span("text", "", ruby = Ruby(listOf(segment)))
        }
        val normalBody = mutableStateOf(20)
        var contexts: RubyStyledTextContexts? = null
        var prepared: PreparedNativeFloatText? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = normalBody.value.sp))) {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp)
                    val resolved = rubyStyledTextContexts(source, null, style)
                    val annotation = styledTextAnnotation(source, null, style) { }
                    val value = prepareNativeFloatText(source, annotation, egyptianTextRuns(source), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", {},
                        nativeLineHeight = NativeLineHeightPolicy.Pixels(24f))
                    SideEffect { contexts = resolved; prepared = value }
                }
            }
        } }
        for (bodyPixels in listOf(20, 40, 20)) {
            compose.runOnIdle { normalBody.value = bodyPixels }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                assertEquals("BsupBsubBsmall-supBbodyBnormalized", value.text.toString())
                val native = checkNotNull(value.native)
                val spanned = native.source(400)
                assertEquals(value.text.toString(), spanned.toString())
                val marker = spanned.getSpans(0, spanned.length, NativeRubyPreparedSource::class.java).single()
                val resolved = checkNotNull(contexts)
                readings.forEach { item ->
                    val ownerRange = marker.projection.ranges.single { it.annotation === item.annotation }
                    val leafRange = marker.projection.ranges.single { it.span === item.leaf }
                    assertSame(item.annotation, ownerRange.annotation)
                    assertSame(item.annotation.owner, checkNotNull(ownerRange.annotation).owner)
                    assertSame(item.leaf, leafRange.span)
                    assertEquals(item.leaf.text, spanned.subSequence(leafRange.start, leafRange.end).toString())
                    val group = resolved.groups.getValue(ownerRange.path)
                    val leaf = resolved.leaves.single { it.range.span === item.leaf }
                    assertEquals(20.sp, group.fontBasisStyle.fontSize)
                    assertEquals(20.sp, leaf.fontBasisStyle.fontSize)
                    assertEquals(.5f, checkNotNull(item.annotation.owner.font.fontScale), 0f)
                    assertEquals(.5f, checkNotNull(item.leaf.fontScale), 0f)
                    val expected = when {
                        item.normalized -> if (bodyPixels == 20) 10f else 20f
                        item.usesBody -> if (bodyPixels == 20) 8f else 16f
                        else -> 8f
                    }
                    val label = "${item.leaf.text}: body=$bodyPixels"
                    assertEquals(label, expected, group.style.fontSize.value, .001f)
                    assertTrue(label, group.style.fontSize.isSp)
                    assertEquals(label, expected, marker.groups.getValue(ownerRange.path).paint.textSize, .001f)
                    val childPaint = TextPaint(native.paint)
                    val covering = spanned.getSpans(leafRange.start, leafRange.end, MetricAffectingSpan::class.java)
                        .filter { spanned.getSpanStart(it) <= leafRange.start && spanned.getSpanEnd(it) >= leafRange.end }
                    assertTrue(label, covering.isNotEmpty())
                    covering.forEach { it.updateMeasureState(childPaint) }
                    assertEquals(label, expected, childPaint.textSize, .001f)
                }
                marker.projection.ranges.filter { it.role == RubyTextRole.Base }.forEach { base ->
                    assertEquals(20f, marker.groups.getValue(base.path).paint.textSize, .001f)
                }
            }
        }
    }

    @Test fun emptyRubyKeepsTheActualCellPointStrutAboveItsIndependentBaseHeight() = control {
        // Synthetic cell policy through the real Compose lowerer. There are no source
        // characters, annotations, padding or glyphs that could manufacture this height.
        val font = InlineFontSnapshot(fontScale = 20f, fontScaleBasis = FontScaleBasis.CssPx,
            language = "ja", fontFeatures = FontFeaturePolicy.SevenOn,
            fontFamily = ContainerFontFamily.SansSerif)
        val baseOwner = RubyOwner(font, direction = "ltr", inlineStyle = InlineTextStyle(
            lineHeight = InlineLineHeight.Computed(InlineComputedLength(48f, FontScaleBasis.CssPx))))
        val base = RubyBase(baseOwner, emptyList(), emptyList())
        val typed = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx))),
            ruby = Ruby(listOf(RubySegment(emptyList(), listOf(base), emptyList()))))
        val source = listOf(typed)
        val cellHeight = mutableStateOf(80f)
        var prepared: PreparedNativeFloatText? = null
        var resolvedCell: ContainerTextContext? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            val style = TextStyle(fontSize = 20.sp, fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp)
            MaterialTheme(typography = Typography(bodyLarge = style)) {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    val cell = Cell(source, false, 1, 1, style = CellStyle(lineHeight = CellLineHeight(
                        CellLineHeightValue.Length(CellFixedLineHeight(cellHeight.value, FontScaleBasis.CssPx)),
                        CellTextStrut(20f, FontScaleBasis.CssPx, font))))
                    val context = checkNotNull(nativeCellTextContext(cell, null, style, style.fontSize,
                        LocalDensity.current, 1f, null))
                    CompositionLocalProvider(LocalNativeContainerTextContext provides context) {
                        val annotation = styledTextAnnotation(source, null, style) { }
                        val value = prepareNativeFloatText(source, annotation, egyptianTextRuns(source), style,
                            MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", {},
                            nativeLineHeight = checkNotNull(context.cellText).lineHeight)
                        SideEffect { prepared = value; resolvedCell = context }
                    }
                }
            }
        } }
        for (height in listOf(80f, 32f, 80f)) {
            compose.runOnIdle { cellHeight.value = height }
            compose.waitForIdle()
            try {
                compose.runOnIdle {
                    val state = checkNotNull(checkNotNull(resolvedCell).cellText)
                    assertEquals(NativeLineHeightPolicy.Pixels(height), state.lineHeight)
                    assertSame(font, checkNotNull(state.ownerFont).snapshot)
                    val value = checkNotNull(prepared)
                    assertNull(value.stateDescription)
                    assertFalse(value.emptyInlineOwner)
                    assertEquals("", value.text.toString())
                    val native = checkNotNull(value.native)
                    val spanned = native.source(240)
                    assertEquals(0, spanned.length)
                    val strut = spanned.getSpans(0, 0, NativeRunLineMetrics::class.java).single { it.strut }
                    assertEquals(0, spanned.getSpanStart(strut))
                    assertEquals(0, spanned.getSpanEnd(strut))
                    assertEquals(android.text.Spanned.SPAN_MARK_MARK, spanned.getSpanFlags(strut))
                    assertTrue(strut.includePrimaryInNormal)
                    assertEquals(NativeLineHeightPolicy.Pixels(height), strut.policy)
                    val marker = spanned.getSpans(0, 0, NativeRubyPreparedSource::class.java).single()
                    assertEquals("", marker.source.toString())
                    assertEquals("", marker.projection.text)
                    assertSame(typed, marker.projection.ranges.single { it.role == RubyTextRole.Owner }.span)
                    // The Ruby owner must not inherit cell height: otherwise its own
                    // column could conceal loss of the independent paragraph point strut.
                    val outer = marker.projection.ranges.single { it.role == RubyTextRole.Owner }
                    assertEquals(NativeLineHeightPolicy.Pixels(0f), marker.groups.getValue(outer.path).lineHeight)
                    val range = marker.projection.ranges.single { it.role == RubyTextRole.Base }
                    assertSame(base, range.base)
                    assertSame(baseOwner, checkNotNull(range.base).owner)
                    assertEquals(0 to 0, range.start to range.end)
                    val format = marker.groups.getValue(range.path)
                    assertEquals(NativeLineHeightPolicy.Pixels(48f), format.lineHeight)
                    assertEquals(20f, format.paint.textSize, 0f)
                    // Equal real primary metrics make the independent 80/48 envelopes
                    // concentric; this assertion does not infer the owner from a child.
                    assertEquals(strut.primary, NativePrimaryFontMetrics.from(format.paint))
                    val geometry = checkNotNull(value.geometry)(240, emptyList(), false)
                    val expected = if (height == 80f) 80f else 48f
                    assertEquals("", geometry.text.toString())
                    assertEquals(expected, geometry.textBottom, .001f)
                    assertEquals(expected, geometry.extents.usedHeight, .001f)
                    assertNotNull(geometry.textBaselines?.first)
                    assertTrue(geometry.rectsForRange(0, 0).isEmpty())
                    assertTrue(geometry.nodes.isEmpty())
                    assertEquals("", source.single().text)
                    assertEquals(0, source.nativeLogicalLength())
                }
            } catch (failure: Throwable) {
                val phase = AssertionError("Empty Ruby cell point-strut: root=$height base=48 width=240")
                if (failure !== phase) failure.addSuppressed(phase)
                throw failure
            }
        }
    }

    @Test fun inlinePaddingKeepsSourceActionOwnersAndExactFontEdgesAcrossSplitAndZoom() = control {
        // Source-shaped synthetic U data, not producer/Reader interoperability evidence.
        // SR207 expanded150723/c042ac05 has 人/nhân and 質/chất child links to
        // #Вијетнамски, followed by the outer [[fanqie|...切...thiết...]] occurrence.
        // Its three Ruby slices are dfda29a4/2b9034b4/31a58283 (diagnosis01.json).
        // Actual first-two source scopes contain TWO 135% declarations. These chosen
        // complete 1.35/1.0 scales test the native owner basis; they assert no emitted
        // source scalar or whole-anchor census across the base and reading.
        data class Model(val spans: List<Span>, val groups: List<Span>, val children: List<List<Span>>,
            val baseLinks: List<Span>)
        fun model(split: Boolean = false, asymmetric: Boolean = false): Model {
            val words = listOf("nhân", "chất", "thiết")
            val bases = listOf("人", "質", "切")
            val groups = mutableListOf<Span>()
            val children = mutableListOf<List<Span>>()
            val baseLinks = mutableListOf<Span>()
            val source = words.mapIndexed { index, word ->
                val scale = if (index < 2) 1.35f else 1f
                val parts = if (split && index == 2) listOf("thi", "ết") else listOf(word)
                val content = parts.map { text -> Span(if (index < 2) "link" else "text", text,
                    if (index < 2) word else "", fontScale = scale, language = "vi",
                    targetFragment = "Вијетнамски".takeIf { index < 2 }, foreground = "#0000ff") }
                val group = Span(if (index < 2) "text" else "link", "", if (index == 2) "fanqie" else "",
                    fontScale = scale, language = "vi", direction = "ltr", foreground = "#0000ff",
                    inlinePaddingGroup = InlinePaddingGroup(
                        StyleLength(StyleLengthUnit.Em, if (asymmetric && index == 2) .125f else .25f),
                        StyleLength(StyleLengthUnit.Em, if (asymmetric && index == 2) .375f else .25f), content))
                groups += group; children += content
                val base = Span("link", bases[index], if (index == 2) "fanqie" else bases[index],
                    targetFragment = "Вијетнамски".takeIf { index < 2 }, foreground = "#000000")
                baseLinks += base
                ruby(listOf(base), listOf(group))
            }
            return Model(source, groups, children, baseLinks)
        }
        val original = model()
        val outsideAnnotation = original.copy(spans = original.groups.indices.flatMap { index ->
            listOf(original.baseLinks[index], original.groups[index])
        })
        data class Phase(val name: String, val model: Model, val fontScale: Float = 1f, val width: Int = 300)
        val phases = listOf(Phase("original", original), Phase("two-children", model(split = true)),
            Phase("font-zoom", original, 1.25f), Phase("asymmetric", model(asymmetric = true)),
            Phase("whole-group-wrap", original, width = 160),
            Phase("outside-annotation", outsideAnnotation),
            Phase("recovery", original))
        val current = mutableStateOf(phases.first())
        val callbacks = mutableListOf<EntryLink>()
        val onLink: (EntryLink) -> Unit = { callbacks += it }
        val focusDestination = androidx.compose.ui.focus.FocusRequester()
        var prepared: PreparedNativeFloatText? = null
        var committed: Phase? = null
        var failureReason: String? = null
        val failureObserver: (String) -> Unit = { failureReason = it }
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme {
                val phase = current.value
                val density = Density(1f, phase.fontScale)
                CompositionLocalProvider(LocalDensity provides density, LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalNativeFloatContextFailureObserver provides failureObserver) {
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                        fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal,
                        fontStyle = FontStyle.Normal, letterSpacing = 0.sp, textDirection = TextDirection.Ltr)
                    val annotated = styledTextAnnotation(phase.model.spans, null, style, onLink)
                    val value = prepareNativeFloatText(phase.model.spans, annotated, egyptianTextRuns(phase.model.spans),
                        style, MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", onLink,
                        nativeLineHeight = NativeLineHeightPolicy.Pixels(with(density) { 24.sp.toPx() }))
                    SideEffect { prepared = value; committed = phase }
                    Box(Modifier.fillMaxSize().background(Color.White).safeDrawingPadding().padding(16.dp)
                        .testTag("inline-padding-focus-destination").focusRequester(focusDestination).focusable()) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                            Modifier.width(phase.width.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            error("The inline padding fixture has no delegated child")
                        }
                    }
                }
            }
        } }
        fun views(view: android.view.View): List<NativeFloatTextView> = buildList {
            if (view is NativeFloatTextView) add(view)
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) addAll(views(view.getChildAt(index)))
        }
        fun union(rectangles: List<android.graphics.RectF>) = android.graphics.RectF().also { result ->
            assertTrue(rectangles.isNotEmpty()); rectangles.forEach(result::union)
        }
        fun sameRect(a: android.graphics.RectF, b: android.graphics.RectF) {
            assertEquals(a.left, b.left, .01f); assertEquals(a.top, b.top, .01f)
            assertEquals(a.right, b.right, .01f); assertEquals(a.bottom, b.bottom, .01f)
        }
        val expected = "人nhân質chất切thiết"
        val ranges = listOf(0 to 1, 1 to 5, 5 to 6, 6 to 10, 10 to 11, 11 to 16)
        val targets = listOf(EntryLink("人", "Вијетнамски"), EntryLink("nhân", "Вијетнамски"),
            EntryLink("質", "Вијетнамски"), EntryLink("chất", "Вијетнамски"), EntryLink("fanqie"), EntryLink("fanqie"))
        var originalGroupWidths: List<Float>? = null
        var originalPaddingWidths: List<Float>? = null
        var originalTextInsets: List<Float>? = null
        var originalIds: List<Int>? = null
        for (phase in phases) try {
            compose.runOnIdle { failureReason = null; current.value = phase }
            compose.waitForIdle()
            if (phase.name == "outside-annotation") {
                compose.runOnIdle {
                    assertEquals(phase, committed)
                    assertEquals("Inline padding group requires a complete ruby annotation", failureReason)
                    assertEquals(expected, checkNotNull(prepared).text.toString())
                    phase.model.groups.indices.forEach { index ->
                        assertSame(original.groups[index], phase.model.spans[index * 2 + 1])
                        assertSame(original.baseLinks[index], phase.model.spans[index * 2])
                    }
                }
                val retained = compose.onNodeWithText(expected).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                retained.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val fallbackText = layouts.single().layoutInput.text
                assertEquals(expected, fallbackText.text)
                assertEquals(ranges, fallbackText.getLinkAnnotations(0, expected.length).map { it.start to it.end })
                val before = callbacks.size
                ranges.forEachIndexed { index, range ->
                    retained.performTouchInput { click(layouts.single().getBoundingBox(range.first).center) }
                    compose.runOnIdle { assertEquals(targets[index], callbacks.last()) }
                }
                compose.runOnIdle { assertEquals(targets, callbacks.drop(before)) }
                continue
            }
            var movedFocus = false
            compose.runOnIdle {
                val view = views(compose.activityRule.activity().window.decorView).single()
                if (view.hasFocus()) {
                    assertTrue(focusDestination.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter))
                    movedFocus = true
                }
            }
            if (movedFocus) compose.onNodeWithTag("inline-padding-focus-destination").assertIsFocused()
            compose.runOnIdle {
                assertEquals(phase, committed)
                assertNull(failureReason)
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                val view = views(compose.activityRule.activity().window.decorView).single()
                val actual = checkNotNull(view.currentMeasuredGeometry)
                assertEquals(expected, view.logicalText.toString()); assertEquals(expected, actual.text.toString())
                assertEquals(ranges, actual.nodes.map { it.start to it.end })
                assertEquals(6, actual.nodes.size)
                assertTrue(actual.nodes.all { it.kind == FloatInteractionKind.LINK })
                if (originalIds == null) originalIds = actual.nodes.map { it.id }
                else assertEquals(originalIds, actual.nodes.map { it.id })
                val raw = checkNotNull(value.geometry)(phase.width, emptyList(), false)
                assertEquals(expected, raw.text.toString())
                val rawCharacters = raw.characterRects(0, expected.length)
                val actualCharacters = actual.characterRects(0, expected.length)
                assertEquals(expected.length, rawCharacters.size)
                assertEquals(expected.length, actualCharacters.size)
                val firstRaw = checkNotNull(rawCharacters.first())
                val firstActual = checkNotNull(actualCharacters.first())
                val dx = firstActual.left - firstRaw.left; val dy = firstActual.top - firstRaw.top
                // The real root may translate the paragraph to contain its Ruby overflow.
                // Authenticate that single translation for every original character first.
                rawCharacters.zip(actualCharacters).forEach { (a, b) ->
                    sameRect(android.graphics.RectF(checkNotNull(a)).apply { offset(dx, dy) }, checkNotNull(b))
                }
                val source = checkNotNull(value.native).source(phase.width)
                val marker = source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).single()
                assertEquals(expected, marker.projection.text)
                val groupWidths = mutableListOf<Float>()
                val paddingWidths = mutableListOf<Float>()
                val textInsets = mutableListOf<Float>()
                val rightPaddingPoints = mutableListOf<Pair<Float, Float>>()
                for (index in phase.model.groups.indices) {
                    val group = phase.model.groups[index]
                    val range = marker.projection.ranges.single { it.role == RubyTextRole.PaddingGroup && it.span === group }
                    assertEquals(ranges[index * 2 + 1], range.start to range.end)
                    val children = phase.model.children[index]
                    children.forEach { child -> assertSame(child, marker.projection.ranges.single { it.span === child }.span) }
                    if (index < 2) { assertFalse(group.hasInternalAction()); assertTrue(children.single().hasInternalAction()) }
                    else { assertTrue(group.hasInternalAction()); assertTrue(children.none { it.hasInternalAction() }) }
                    val pixels = with(Density(1f, phase.fontScale)) { (20f * (if (index < 2) 1.35f else 1f)).sp.toPx() }
                    assertEquals(pixels, marker.groups.getValue(range.path).paint.textSize, .01f)
                    val probe = TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        typeface = android.graphics.Typeface.MONOSPACE; textSize = pixels
                        textLocale = java.util.Locale.forLanguageTag("vi")
                    }
                    val content = expected.substring(range.start, range.end)
                    val edges = checkNotNull(group.inlinePaddingGroup)
                    assertEquals(StyleLengthUnit.Em, edges.left.unit)
                    assertEquals(StyleLengthUnit.Em, edges.right.unit)
                    val left = edges.left.value * pixels
                    val right = edges.right.value * pixels
                    paddingWidths += left + right
                    val rawGroup = union(checkNotNull(raw.inlinePaddingGroupRects(group, range.start, range.end)))
                    assertEquals(probe.measureText(content) + left + right, rawGroup.width(), .02f)
                    val bounds = android.graphics.RectF(rawGroup).apply { offset(dx, dy) }
                    groupWidths += bounds.width()
                    textInsets += checkNotNull(actualCharacters[range.start]).left - bounds.left
                    val point = (bounds.right - right / 2f) to bounds.centerY()
                    assertTrue(right > 2f)
                    assertTrue(actual.rectsForRange(range.start, range.end).none { it.contains(point.first, point.second) })
                    val node = actual.nodes[index * 2 + 1]
                    if (index < 2) {
                        // Selection Regions may round outward; only the child's action area
                        // is restricted to the exact content interval inside the authored edges.
                        val contentLeft = bounds.left + left
                        val contentRight = bounds.right - right
                        val expectedChild = actual.rectsForRange(range.start, range.end).mapNotNull { rectangle ->
                            val clipped = android.graphics.RectF(rectangle).apply {
                                this.left = kotlin.math.max(this.left, contentLeft)
                                this.right = kotlin.math.min(this.right, contentRight)
                            }
                            clipped.takeIf { it.left < it.right && it.top < it.bottom }
                        }
                        assertEquals(expectedChild.size, node.bounds.size)
                        expectedChild.zip(node.bounds).forEach { (expectedBound, actualBound) ->
                            sameRect(expectedBound, actualBound)
                        }
                        assertNull(actual.interactionNodeAt(point.first, point.second))
                    } else {
                        sameRect(bounds, union(node.bounds))
                        assertEquals(node.id, checkNotNull(actual.interactionNodeAt(point.first, point.second)).id)
                    }
                    rightPaddingPoints += point
                }
                if (phase.name == "original") {
                    originalGroupWidths = groupWidths
                    originalPaddingWidths = paddingWidths
                    originalTextInsets = textInsets
                }
                if (phase.name in listOf("two-children", "asymmetric", "whole-group-wrap", "recovery"))
                    checkNotNull(originalGroupWidths).zip(groupWidths).forEach { (a, b) -> assertEquals(a, b, .02f) }
                if (phase.name == "font-zoom") checkNotNull(originalPaddingWidths).zip(paddingWidths)
                    .forEach { (a, b) -> assertEquals(a * phase.fontScale, b, .04f) }
                if (phase.name in listOf("two-children", "whole-group-wrap", "recovery"))
                    checkNotNull(originalTextInsets).zip(textInsets).forEach { (a, b) -> assertEquals(a, b, .02f) }
                if (phase.name == "asymmetric") {
                    // The sum stays fixed, while the actual child moves by the changed left edge once.
                    assertEquals(checkNotNull(originalTextInsets).last() + (.125f - .25f) * 20f,
                        textInsets.last(), .02f)
                }
                if (phase.name == "whole-group-wrap")
                    assertNotEquals(actual.visualLineRanges(0), actual.visualLineRanges(10))
                val provider = view.accessibilityNodeProvider
                val hostId = android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID
                val host = checkNotNull(provider.createAccessibilityNodeInfo(hostId))
                try { assertEquals(expected, host.text.toString()); assertEquals(6, host.childCount) }
                finally { host.recycle() }
                val beforeActions = callbacks.size
                actual.nodes.forEachIndexed { index, node ->
                    val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                    try {
                        assertEquals(expected.substring(node.start, node.end), info.text.toString())
                        assertTrue(info.isClickable && info.isVisibleToUser)
                        val bounds = android.graphics.Rect().also(union(node.bounds)::roundOut).apply {
                            offset(view.paddingLeft, view.paddingTop)
                        }
                        assertEquals(bounds, android.graphics.Rect().also(info::getBoundsInParent))
                    } finally { info.recycle() }
                    assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals(targets[index], callbacks.last())
                }
                assertEquals(targets, callbacks.drop(beforeActions))
                val arguments = android.os.Bundle().apply {
                    putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                    putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, expected.length)
                }
                assertTrue(provider.performAction(hostId, android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, arguments))
                assertEquals(expected, view.selectedTextForCopy())
                assertTrue(provider.performAction(hostId, android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                assertNull(view.selectedTextForCopy())
                // Use the actual View input path for the inherited action's padding.
                // Cancel only this fixture's previous pointer sequence; no touch-mode change.
                val point = rightPaddingPoints.last()
                val now = android.os.SystemClock.uptimeMillis()
                val beforeTap = callbacks.size
                for (action in listOf(android.view.MotionEvent.ACTION_CANCEL, android.view.MotionEvent.ACTION_DOWN,
                    android.view.MotionEvent.ACTION_UP)) {
                    val event = android.view.MotionEvent.obtain(now, now + if (action == android.view.MotionEvent.ACTION_UP) 1 else 0,
                        action, point.first + view.paddingLeft, point.second + view.paddingTop, 0)
                    try {
                        val consumed = view.onTouchEvent(event)
                        if (action != android.view.MotionEvent.ACTION_CANCEL) assertTrue(consumed)
                    } finally { event.recycle() }
                }
                assertEquals(beforeTap + 1, callbacks.size); assertEquals(EntryLink("fanqie"), callbacks.last())
            }
        } catch (failure: Throwable) {
            val detail = AssertionError("Inline padding Compose phase=${phase.name} fontScale=${phase.fontScale}")
            if (failure !== detail) failure.addSuppressed(detail)
            throw failure
        }
    }


    @Test fun inlineActionGroupsKeepOneRichOwnerAcrossWrapBidiAndEmptyMetadata() = control {
        // Synthetic DPRV ownership controls, not a compiled Mai/KU source or font-scalar acceptance.
        // The same complete eight-state fixture used by OrdinaryLinkPaintDeviceTest.
        val paintColors = listOf("#3366cc", "#228844", "#cc5500", "#aa22cc", "#6a60b0", "#008080", "#993333", "#667700")
        val paintUnderlines = listOf(true, false, false, true, false, true, true, false)
        val paintStates = paintColors.mapIndexed { index, color -> FigureLinkState(color, paintUnderlines[index]) }
        val richPolicy = LinkPaint(normal = paintStates[0], hover = paintStates[1], active = paintStates[2],
            hoverActive = paintStates[3], visited = paintStates[4], visitedHover = paintStates[5],
            visitedActive = paintStates[6], visitedHoverActive = paintStates[7], underlineOnFocus = true,
            focusOutline = FigureFocusOutline(StyleLength(StyleLengthUnit.Em, .125f), FigureColor.Rgb("#ff0000"),
                StyleLength(StyleLengthUnit.Em, .125f), SignedContainerMargin(StyleLengthUnit.Em, -.125f)))
        val visits = MissingLinkVisits()
        val supSnapshot = InlineFontSnapshot(superscript = true)
        val supLineHeight = InlineLineHeight.FontRelative(1f, supSnapshot)
        val supLeaf = Span("text", "2", superscript = true, inlineStyle = InlineTextStyle(lineHeight = supLineHeight))
        val richLeaves = listOf(Span("text", "M"), supLeaf,
            Span("text", "I", italic = true), Span("text", "\u00a0\u2192\u00a0"),
            Span("text", "\u05d0\u05d1\u05d2\u05d3", direction = "rtl"),
            Span("text", " plain alpha beta gamma delta"))
        fun action(target: String, children: List<Span>, fragment: String? = null) =
            Span("link", "", target, targetFragment = fragment, inlineActionGroup = InlineActionGroup(children))
        val rich = action("mai-rich-owner", richLeaves, "source-section").copy(
            foreground = richPolicy.normal.foreground, underline = richPolicy.normal.underline, linkPaint = richPolicy)
        val firstSame = action("same-target", listOf(Span("text", "d")))
        val secondSame = action("same-target", listOf(Span("text", "a")))
        val readingLeaf = Span("text", "nhân", fontScale = .75f, language = "vi")
        val padding = Span("text", "", fontScale = .75f, language = "vi", direction = "ltr",
            inlinePaddingGroup = InlinePaddingGroup(StyleLength(StyleLengthUnit.Em, .25f),
                StyleLength(StyleLengthUnit.Em, .25f), listOf(readingLeaf)))
        val baseLeaf = Span("text", "字")
        val nestedRuby = ruby(listOf(baseLeaf), listOf(padding))
        val rubyAction = action("ruby-owner", listOf(nestedRuby))
        val emptyLeaf = Span("text", "")
        val emptyAction = action("empty-owner", listOf(emptyLeaf)).copy(fontScale = .75f,
            tooltip = "Synthetic empty action owner")
        val owners = listOf(rich, firstSame, secondSame, rubyAction, emptyAction, emptyAction)
        val source = listOf(rich, Span("text", " "), firstSame, secondSame, Span("text", " "), rubyAction,
            emptyAction, emptyAction)
        val richText = "M2I\u00a0\u2192\u00a0\u05d0\u05d1\u05d2\u05d3 plain alpha beta gamma delta"
        val expected = richText + " da 字nhân"
        val firstSameStart = richText.length + 1
        val rubyStart = firstSameStart + 3
        val ranges = listOf(0 to richText.length, firstSameStart to firstSameStart + 1,
            firstSameStart + 1 to firstSameStart + 2, rubyStart to expected.length,
            expected.length to expected.length, expected.length to expected.length)
        val targets = listOf(EntryLink("mai-rich-owner", "source-section"), EntryLink("same-target"),
            EntryLink("same-target"), EntryLink("ruby-owner"), EntryLink("empty-owner"), EntryLink("empty-owner"))
        data class Phase(val name: String, val width: Int, val rtl: Boolean = false, val fontScale: Float = 1f)
        val phases = listOf(Phase("wide", 320), Phase("wrapped", 180), Phase("wrapped-rtl", 180, true),
            Phase("zoom", 180, true, 1.25f), Phase("recovery", 320))
        val current = mutableStateOf(phases.first())
        val callbacks = mutableListOf<EntryLink>()
        val onLink: (EntryLink) -> Unit = { callbacks += it }
        val focusDestination = androidx.compose.ui.focus.FocusRequester()
        var prepared: PreparedNativeFloatText? = null
        var annotation = AnnotatedString("")
        var committed: Phase? = null
        var failureReason: String? = null
        val onFailure: (String) -> Unit = { failureReason = it }
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme {
                val phase = current.value
                val density = Density(1f, phase.fontScale)
                CompositionLocalProvider(LocalDensity provides density,
                    LocalLayoutDirection provides if (phase.rtl) LayoutDirection.Rtl else LayoutDirection.Ltr,
                    LocalNativeFloatContextFailureObserver provides onFailure,
                    LocalMissingLinkVisits provides visits) {
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp, letterSpacing = 0.sp,
                        fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal, fontStyle = FontStyle.Normal,
                        textDirection = if (phase.rtl) TextDirection.Rtl else TextDirection.Ltr)
                    val annotated = styledTextAnnotation(source, null, style, onLink)
                    val value = prepareNativeFloatText(source, annotated, egyptianTextRuns(source), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", onLink,
                        nativeLineHeight = NativeLineHeightPolicy.Pixels(with(density) { 24.sp.toPx() }))
                    SideEffect { prepared = value; annotation = annotated; committed = phase }
                    Box(Modifier.fillMaxSize().background(Color.White).safeDrawingPadding().padding(16.dp)
                        .testTag("inline-action-focus-destination").focusRequester(focusDestination).focusable()) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                            Modifier.width(phase.width.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            error("The inline action fixture has no delegated child")
                        }
                    }
                }
            }
        } }
        fun views(view: android.view.View): List<NativeFloatTextView> = buildList {
            if (view is NativeFloatTextView) add(view)
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) addAll(views(view.getChildAt(index)))
        }
        fun sameRect(a: android.graphics.RectF, b: android.graphics.RectF) {
            assertEquals(a.left, b.left, .01f); assertEquals(a.top, b.top, .01f)
            assertEquals(a.right, b.right, .01f); assertEquals(a.bottom, b.bottom, .01f)
        }
        fun sameRects(a: List<android.graphics.RectF>, b: List<android.graphics.RectF>) {
            assertEquals(a.size, b.size); a.zip(b).forEach { (first, second) -> sameRect(first, second) }
        }
        fun union(rectangles: List<android.graphics.RectF>): android.graphics.RectF {
            assertTrue(rectangles.isNotEmpty())
            return android.graphics.RectF(rectangles.first()).also { result -> rectangles.drop(1).forEach(result::union) }
        }
        var originalView: NativeFloatTextView? = null
        var originalIds: List<Int>? = null
        var originalNullCallbacks: List<Any?>? = null
        var originalBounds: List<List<android.graphics.RectF>>? = null
        var wideRows = 0
        for ((phaseIndex, phase) in phases.withIndex()) try {
            compose.runOnIdle { failureReason = null; current.value = phase }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(phase, committed); assertNull(failureReason)
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                assertEquals(expected, value.text.toString()); assertEquals(expected, annotation.text)
                // Empty owner identity is native metadata, never a fake nonempty LinkAnnotation.
                assertEquals(ranges.dropLast(2), annotation.getLinkAnnotations(0, expected.length).map { it.start to it.end })
                val view = views(compose.activityRule.activity().window.decorView).single()
                val actual = checkNotNull(view.currentMeasuredGeometry)
                assertEquals(expected, view.logicalText.toString()); assertEquals(expected, actual.text.toString())
                assertEquals(ranges, actual.nodes.map { it.start to it.end })
                assertEquals(owners.size, actual.nodes.size)
                assertTrue(actual.nodes.all { it.kind == FloatInteractionKind.LINK })
                assertEquals(owners.size, actual.nodes.map { it.id }.distinct().size)
                val provider = view.accessibilityNodeProvider
                val hostId = android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID
                if (phaseIndex == 0) {
                    originalView = view; originalIds = actual.nodes.map { it.id }
                    originalNullCallbacks = actual.nodes.drop(1).map { it.onClick }
                } else {
                    assertSame(originalView, view)
                    assertEquals(originalIds, actual.nodes.map { it.id })
                    checkNotNull(originalNullCallbacks).zip(actual.nodes.drop(1)).forEach { (before, node) ->
                        assertSame(before, node.onClick)
                    }
                    assertTrue(view.hasFocus())
                    assertEquals(1, view.selectionStart); assertEquals(richText.length, view.selectionEnd)
                    assertEquals(expected.substring(1, richText.length), view.selectedTextForCopy())
                    actual.nodes.forEachIndexed { index, node ->
                        val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                        try { assertEquals(index == 0, info.isFocused) } finally { info.recycle() }
                    }
                }
                val raw = checkNotNull(value.geometry)(phase.width, emptyList(), false)
                val actualCharacters = actual.characterRects(0, expected.length)
                val rawCharacters = raw.characterRects(0, expected.length)
                assertEquals(expected.length, actualCharacters.size); assertEquals(expected.length, rawCharacters.size)
                val dx = checkNotNull(actualCharacters[0]).left - checkNotNull(rawCharacters[0]).left
                val dy = checkNotNull(actualCharacters[0]).top - checkNotNull(rawCharacters[0]).top
                rawCharacters.zip(actualCharacters).forEach { (a, b) ->
                    if (a == null) assertNull(b)
                    else sameRect(android.graphics.RectF(a).apply { offset(dx, dy) }, checkNotNull(b))
                }
                val native = checkNotNull(value.native)
                val nativeSource = native.source(phase.width)
                val marker = nativeSource.getSpans(0, nativeSource.length, NativeRubyPreparedSource::class.java).single()
                assertEquals(expected, marker.source.toString()); assertEquals(expected, marker.projection.text)
                val ownerRanges = marker.projection.ranges.filter { it.role == RubyTextRole.ActionGroup }
                assertEquals(owners.size, ownerRanges.size)
                owners.zip(ownerRanges).forEach { (owner, range) -> assertSame(owner, range.span) }
                assertEquals(ranges, ownerRanges.map { it.start to it.end })
                assertEquals(owners.size, ownerRanges.map { it.path }.distinct().size)
                val actionOwners = ownerRanges.map { checkNotNull(marker.groups.getValue(it.path).actionOwner) }
                assertNotSame(actionOwners[4], actionOwners[5])
                val richPaint = checkNotNull(actual.nodes.first().missingLinkPaint)
                assertSame(richPolicy, richPaint.ordinaryPolicy)
                assertSame(richPaint, marker.groups.getValue(ownerRanges.first().path).actionPaint)
                assertEquals(phaseIndex > 0, richPaint.visited)
                assertTrue(actual.nodes.drop(1).all { it.missingLinkPaint == null })
                ownerRanges.drop(1).forEach { assertNull(marker.groups.getValue(it.path).actionPaint) }
                (richLeaves + listOf(baseLeaf, readingLeaf)).forEach { leaf ->
                    assertSame(leaf, marker.projection.ranges.single { it.span === leaf }.span)
                    assertFalse(leaf.hasInternalAction())
                }
                val emptyLeaves = marker.projection.ranges.filter { it.span === emptyLeaf }
                assertEquals(2, emptyLeaves.size)
                assertTrue(emptyLeaves.all { it.start == expected.length && it.end == expected.length })
                assertFalse(emptyLeaf.hasInternalAction())
                val bodyPixels = with(Density(1f, phase.fontScale)) { 20.sp.toPx() }
                fun leafPaint(leaf: Span): TextPaint {
                    val range = marker.projection.ranges.single { it.span === leaf }
                    return TextPaint(marker.paint).also { paint ->
                        nativeSource.getSpans(range.start, range.end, MetricAffectingSpan::class.java)
                            .filter { nativeSource.getSpanStart(it) <= range.start && nativeSource.getSpanEnd(it) >= range.end }
                            .forEach { it.updateMeasureState(paint) }
                    }
                }
                assertEquals(bodyPixels, leafPaint(richLeaves[0]).textSize, .01f)
                assertEquals(bodyPixels * .8f, leafPaint(richLeaves[1]).textSize, .01f)
                val supRange = marker.projection.ranges.single { it.span === supLeaf }
                assertEquals(1 to 2, supRange.start to supRange.end)
                assertSame(supLineHeight, supLeaf.inlineStyle!!.lineHeight)
                assertSame(supSnapshot, supLineHeight.font)
                assertNull(supLeaf.inlineStyle!!.baselineShift)
                val supPaint = leafPaint(supLeaf)
                val supMetrics = nativeSource.getSpans(supRange.start, supRange.end, NativeAuthoredInlineMetrics::class.java)
                    .filter { nativeSource.getSpanStart(it) == supRange.start && nativeSource.getSpanEnd(it) == supRange.end }
                    .single()
                val declaring = checkNotNull(supMetrics.declaringPrimary)
                assertEquals(supPaint.textSize, supMetrics.primary.fontSize, .01f)
                assertEquals(supPaint.textSize, declaring.fontSize, .01f)
                assertEquals(supPaint.fontMetrics.ascent, declaring.ascent, .01f)
                assertEquals(supPaint.fontMetrics.descent, declaring.descent, .01f)
                assertEquals(supPaint.textSize * supLineHeight.factor,
                    (supMetrics.policy as NativeLineHeightPolicy.Pixels).value, .01f)
                assertTrue(supPaint.baselineShift < 0)
                assertEquals(supPaint.baselineShift.toFloat(), supMetrics.primary.baselineShift, 0f)
                assertEquals(supPaint.baselineShift.toFloat(), declaring.baselineShift, 0f)
                assertTrue(nativeSource.getSpans(supRange.start, supRange.end, NativeAuthoredBaselineShift::class.java).isEmpty())
                assertTrue(leafPaint(richLeaves[2]).typeface.isItalic)
                assertEquals(bodyPixels * .75f, marker.groups.getValue(ownerRanges.last().path).paint.textSize, .01f)
                assertTrue(checkNotNull(actualCharacters[1]).centerY() < checkNotNull(actualCharacters[0]).centerY())
                val hebrewStart = richText.indexOf('\u05d0')
                assertTrue(checkNotNull(actualCharacters[hebrewStart]).centerX() >
                    checkNotNull(actualCharacters[hebrewStart + 3]).centerX())
                val richRows = (0 until richText.length).map(actual::visualLineRanges).distinct().size
                if (phaseIndex == 0) wideRows = richRows
                if (phase.name == "wrapped" || phase.name == "wrapped-rtl") assertTrue(richRows > wideRows)
                assertNotEquals(actual.visualLineRanges(0), actual.visualLineRanges(richText.lastIndex))
                owners.indices.forEach { index ->
                    val range = ranges[index]
                    val rawQueried = checkNotNull(raw.inlineActionGroupRects(actionOwners[index], range.first, range.second))
                    if (index < 3) sameRects(raw.rectsForRange(range.first, range.second), rawQueried)
                    val queried = rawQueried
                        .map { android.graphics.RectF(it).apply { offset(dx, dy) } }
                    sameRects(queried, actual.nodes[index].bounds)
                    if (index < 4) {
                        assertTrue(queried.isNotEmpty() && queried.all { it.width() > 0f && it.height() > 0f })
                        queried.forEach { rectangle -> assertEquals(actual.nodes[index].id,
                            checkNotNull(actual.interactionNodeAt(rectangle.centerX(), rectangle.centerY())).id) }
                    } else {
                        assertEquals(1, queried.size)
                        assertEquals(0f, queried.single().width(), 0f)
                        assertTrue(queried.single().height() > 0f)
                        assertNotEquals(actual.nodes[index].id,
                            actual.interactionNodeAt(queried.single().centerX(), queried.single().centerY())?.id)
                    }
                }
                for ((ownerIndex, offset) in listOf(0 to 0, 0 to 1, 0 to 2, 0 to hebrewStart,
                    1 to firstSameStart, 2 to firstSameStart + 1, 3 to rubyStart, 3 to rubyStart + 1)) {
                    val rectangle = checkNotNull(actualCharacters[offset])
                    assertEquals(actual.nodes[ownerIndex].id,
                        checkNotNull(actual.interactionNodeAt(rectangle.centerX(), rectangle.centerY())).id)
                }
                val paddingRange = marker.projection.ranges.single { it.role == RubyTextRole.PaddingGroup && it.span === padding }
                val paddingBounds = union(checkNotNull(raw.inlinePaddingGroupRects(padding, paddingRange.start, paddingRange.end)))
                    .apply { offset(dx, dy) }
                val right = .25f * bodyPixels * .75f
                val paddingPoint = (paddingBounds.right - right / 2f) to paddingBounds.centerY()
                assertTrue(actual.rectsForRange(paddingRange.start, paddingRange.end)
                    .none { it.contains(paddingPoint.first, paddingPoint.second) })
                assertEquals(actual.nodes[3].id,
                    checkNotNull(actual.interactionNodeAt(paddingPoint.first, paddingPoint.second)).id)
                val host = checkNotNull(provider.createAccessibilityNodeInfo(hostId))
                try { assertEquals(expected, host.text.toString()); assertEquals(owners.size, host.childCount) }
                finally { host.recycle() }
                val beforeActions = callbacks.size
                actual.nodes.forEachIndexed { index, node ->
                    val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                    try {
                        assertEquals(expected.substring(node.start, node.end), info.text.toString())
                        assertTrue(info.isClickable)
                        if (index < 4) assertTrue(info.isVisibleToUser)
                        val expectedBounds = android.graphics.Rect().also(union(node.bounds)::roundOut).apply {
                            offset(view.paddingLeft, view.paddingTop)
                        }
                        assertEquals(expectedBounds, android.graphics.Rect().also(info::getBoundsInParent))
                    } finally { info.recycle() }
                    assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals(targets[index], callbacks.last())
                }
                assertEquals(targets, callbacks.drop(beforeActions))
                // One virtual focus stop per source owner, including equal-target neighbors and the empty owner.
                assertTrue(provider.performAction(actual.nodes.first().id,
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(view.hasFocus())
                fun assertRichPaint(active: Boolean) {
                    assertTrue(richPaint.focused); assertFalse(richPaint.hovered); assertEquals(active, richPaint.active)
                    val state = paintStates[(if (richPaint.visited) 4 else 0) + (if (active) 2 else 0)]
                    assertEquals(0xff000000.toInt() or state.foreground.substring(1).toInt(16), richPaint.appearance().color)
                    assertEquals(state.underline || richPolicy.underlineOnFocus, richPaint.appearance().underline)
                }
                assertRichPaint(false)
                val beforeRichKey = callbacks.size
                assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                assertRichPaint(true)
                assertEquals(beforeRichKey, callbacks.size)
                assertTrue(view.onKeyUp(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER)))
                assertRichPaint(false)
                assertEquals(beforeRichKey + 1, callbacks.size); assertEquals(targets.first(), callbacks.last())
                for (index in 1 until owners.size) {
                    assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_TAB,
                        android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_TAB)))
                    actual.nodes.forEachIndexed { candidate, node ->
                        val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                        try { assertEquals(candidate == index, info.isFocused) } finally { info.recycle() }
                    }
                    val beforeKey = callbacks.size
                    assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ENTER,
                        android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                    view.onKeyUp(android.view.KeyEvent.KEYCODE_ENTER,
                        android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                    assertEquals(beforeKey + 1, callbacks.size); assertEquals(targets[index], callbacks.last())
                }
                val beforeTap = callbacks.size
                val now = android.os.SystemClock.uptimeMillis()
                for (actionCode in listOf(android.view.MotionEvent.ACTION_CANCEL, android.view.MotionEvent.ACTION_DOWN,
                    android.view.MotionEvent.ACTION_UP)) {
                    val event = android.view.MotionEvent.obtain(now,
                        now + if (actionCode == android.view.MotionEvent.ACTION_UP) 1 else 0, actionCode,
                        paddingPoint.first + view.paddingLeft, paddingPoint.second + view.paddingTop, 0)
                    try { val consumed = view.onTouchEvent(event)
                        if (actionCode != android.view.MotionEvent.ACTION_CANCEL) assertTrue(consumed)
                    } finally { event.recycle() }
                }
                assertEquals(beforeTap + 1, callbacks.size); assertEquals(targets[3], callbacks.last())
                fun select(first: Int, last: Int) {
                    val arguments = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, first)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, last)
                    }
                    assertTrue(provider.performAction(hostId, android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, arguments))
                    assertEquals(expected.substring(first, last), view.selectedTextForCopy())
                }
                select(0, expected.length)
                select(1, richText.length)
                assertTrue(provider.performAction(actual.nodes.first().id,
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                if (phaseIndex == 0) originalBounds = actual.nodes.map { node -> node.bounds.map { android.graphics.RectF(it) } }
                if (phase.name == "recovery") checkNotNull(originalBounds).zip(actual.nodes).forEach { (before, node) ->
                    sameRects(before, node.bounds)
                }
            }
        } catch (failure: Throwable) {
            val detail = AssertionError("Inline action Compose phase=${phase.name}, width=${phase.width}, rtl=${phase.rtl}, fontScale=${phase.fontScale}")
            if (failure !== detail) failure.addSuppressed(detail)
            throw failure
        }
        compose.runOnIdle { assertTrue(focusDestination.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter)) }
        compose.onNodeWithTag("inline-action-focus-destination").assertIsFocused()

        // A real zero-width host retains empty-owner metadata; it does not acquire input focus or hit width.
        val zeroPointAction = emptyAction.copy(inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx))))
        val zeroCurrent = mutableStateOf(emptyAction, referentialEqualityPolicy())
        var zeroPrepared: PreparedNativeFloatText? = null
        var zeroFailure: String? = null
        val zeroObserver: (String) -> Unit = { zeroFailure = it }
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme {
                CompositionLocalProvider(LocalDensity provides Density(1f), LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalNativeFloatContextFailureObserver provides zeroObserver) {
                    val zeroSource = listOf(zeroCurrent.value)
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp, letterSpacing = 0.sp,
                        fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal, fontStyle = FontStyle.Normal,
                        textDirection = TextDirection.Ltr)
                    val annotated = styledTextAnnotation(zeroSource, null, style, onLink)
                    val value = prepareNativeFloatText(zeroSource, annotated, egyptianTextRuns(zeroSource), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(), "", onLink,
                        nativeLineHeight = NativeLineHeightPolicy.Pixels(24f))
                    SideEffect { zeroPrepared = value }
                    Box(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                            Modifier.width(0.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            error("The empty inline action fixture has no delegated child")
                        }
                    }
                }
            }
        } }
        for (zeroOwner in listOf(emptyAction, zeroPointAction)) {
            compose.runOnIdle { zeroFailure = null; zeroCurrent.value = zeroOwner }
            compose.waitForIdle()
            compose.runOnIdle {
                assertNull(zeroFailure)
                val value = checkNotNull(zeroPrepared)
                assertNull(value.stateDescription); assertEquals("", value.text.toString())
                val view = views(compose.activityRule.activity().window.decorView).single()
                assertEquals(0, view.width)
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                assertEquals(0, geometry.width); assertEquals("", geometry.text.toString())
                assertTrue(geometry.characterRects(0, 0).isEmpty())
                assertTrue(geometry.rectsForRange(0, 0).isEmpty())
                val node = geometry.nodes.single()
                assertEquals(0 to 0, node.start to node.end)
                val band = node.bounds.single()
                assertEquals(0f, band.width(), 0f)
                if (zeroOwner === emptyAction) assertTrue(band.height() > 0f)
                else assertEquals(0f, band.height(), 0f)
                assertNull(geometry.interactionNodeAt(band.centerX(), band.centerY()))
                val nativeSource = checkNotNull(value.native).source(0)
                val marker = nativeSource.getSpans(0, 0, NativeRubyPreparedSource::class.java).single()
                val range = marker.projection.ranges.single { it.role == RubyTextRole.ActionGroup }
                assertSame(zeroOwner, range.span)
                assertNotNull(marker.groups.getValue(range.path).actionOwner)
                assertEquals(15f, marker.groups.getValue(range.path).paint.textSize, .01f)
                val provider = view.accessibilityNodeProvider
                val host = checkNotNull(provider.createAccessibilityNodeInfo(android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID))
                try { assertEquals("", host.text.toString()); assertEquals(1, host.childCount) } finally { host.recycle() }
                val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                try {
                    assertEquals("", info.text.toString()); assertTrue(info.isClickable)
                    val parentBand = android.graphics.Rect().also(band::roundOut).apply { offset(view.paddingLeft, view.paddingTop) }
                    assertEquals(parentBand, android.graphics.Rect().also(info::getBoundsInParent))
                    if (zeroOwner === zeroPointAction) assertFalse(info.isVisibleToUser)
                    // Visibility may be false for a zero-area host; the node is still real metadata.
                } finally { info.recycle() }
            }
        }
    }


    @Test fun inlineBoxLoweringKeepsOriginalFontBasisAndDeclaringCurrentColorState() = control {
        // Direct typed consumer controls. The first issuer currently refuses an action
        // ancestor around a box; this synthetic V contrast does not claim source acceptance.
        fun policy(normal: String, active: String) = LinkPaint(
            normal = LinkState(normal, false), hover = LinkState(normal, false),
            active = LinkState(active, false), hoverActive = LinkState(active, false),
            visited = LinkState(normal, false), visitedHover = LinkState(normal, false),
            visitedActive = LinkState(active, false), visitedHoverActive = LinkState(active, false),
            underlineOnFocus = false, focusOutline = null)
        val ancestorPolicy = policy("#2255aa", "#ee3300")
        val childPolicy = policy("#008833", "#aa00dd")
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val line = InlineBoxBorderEdge.Solid(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.CurrentColor)
        val overlays = listOf(InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Em, -.5f), bottom = InlineBoxInset(StyleWidthUnit.Percent, 67f)),
            none.copy(right = line)))
        val small = Span("text", "i", fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody,
            foreground = ancestorPolicy.normal.foreground)
        val cumulative = Span("text", "M", fontScale = 1.35f, foreground = ancestorPolicy.normal.foreground)
        val inheritedBox = Span("text", "", fontScale = 1.35f, bold = true,
            inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, StyleLength(StyleLengthUnit.Em, .25f), zero,
                StyleLength(StyleLengthUnit.Em, .25f)), none.copy(right = line), overlays,
                spans = listOf(small, cumulative)))
        val ancestor = Span("link", "", "typed-box-ancestor", foreground = ancestorPolicy.normal.foreground,
            linkPaint = ancestorPolicy, inlineActionGroup = InlineActionGroup(listOf(inheritedBox)))
        val child = Span("link", "J", "typed-box-child", fontScale = 1.35f,
            foreground = childPolicy.normal.foreground, linkPaint = childPolicy)
        val independentBox = Span("text", "", fontScale = .9f, foreground = "#884400",
            inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, StyleLength(StyleLengthUnit.Em, .25f), zero,
                StyleLength(StyleLengthUnit.Em, .25f)), none.copy(right = line), overlays,
                spans = listOf(child)))
        val source = listOf(ancestor, Span("text", " "), independentBox)
        val expected = "iM J"
        val zoom = mutableStateOf(1f)
        val callbacks = mutableListOf<EntryLink>()
        val onLink: (EntryLink) -> Unit = { callbacks += it }
        val visits = MissingLinkVisits()
        val focusDestination = androidx.compose.ui.focus.FocusRequester()
        var prepared: PreparedNativeFloatText? = null
        var committedZoom = 0f
        var failure: String? = null
        val observer: (String) -> Unit = { failure = it }
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge =
                TextStyle(fontSize = 20.sp, fontFamily = FontFamily.Monospace, letterSpacing = 0.sp))) {
                val currentZoom = zoom.value
                val density = Density(1f, currentZoom)
                CompositionLocalProvider(LocalDensity provides density, LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalNativeFloatContextFailureObserver provides observer, LocalMissingLinkVisits provides visits) {
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 40.sp, fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Normal, fontStyle = FontStyle.Normal, letterSpacing = 0.sp,
                        textDirection = TextDirection.Ltr)
                    val annotated = styledTextAnnotation(source, null, style, onLink)
                    val value = prepareNativeFloatText(source, annotated, egyptianTextRuns(source), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(allowImages = false, allowAudio = false),
                        "", onLink, nativeLineHeight = NativeLineHeightPolicy.Pixels(with(density) { 40.sp.toPx() }))
                    SideEffect { prepared = value; committedZoom = currentZoom }
                    Box(Modifier.fillMaxSize().background(Color.White).safeDrawingPadding().padding(16.dp)
                        .testTag("inline-box-focus-destination").focusRequester(focusDestination).focusable()) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                            Modifier.width(260.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            error("The inline box fixture has no delegated child")
                        }
                    }
                }
            }
        } }
        fun views(view: android.view.View): List<NativeFloatTextView> = buildList {
            if (view is NativeFloatTextView) add(view)
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) addAll(views(view.getChildAt(index)))
        }
        fun sameRect(a: android.graphics.RectF, b: android.graphics.RectF) {
            assertEquals(a.left, b.left, .01f); assertEquals(a.top, b.top, .01f)
            assertEquals(a.right, b.right, .01f); assertEquals(a.bottom, b.bottom, .01f)
        }
        var stableView: NativeFloatTextView? = null
        var originalIds: List<Int>? = null
        var originalBoxWidth = 0f
        for (currentZoom in listOf(1f, 1.25f, 1f)) {
            compose.runOnIdle { failure = null; zoom.value = currentZoom }
            compose.waitForIdle()
            var movedFocus = false
            compose.runOnIdle {
                val view = views(compose.activityRule.activity().window.decorView).single()
                if (view.hasFocus()) {
                    assertTrue(focusDestination.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter))
                    movedFocus = true
                }
            }
            if (movedFocus) compose.onNodeWithTag("inline-box-focus-destination").assertIsFocused()
            compose.runOnIdle {
                assertEquals(currentZoom, committedZoom, 0f); assertNull(failure)
                val value = checkNotNull(prepared); assertNull(value.stateDescription)
                val view = views(compose.activityRule.activity().window.decorView).single()
                if (stableView == null) stableView = view else assertSame(stableView, view)
                val actual = checkNotNull(view.currentMeasuredGeometry)
                val raw = checkNotNull(value.geometry).invoke(260, emptyList(), false)
                assertEquals(expected, value.text.toString()); assertEquals(expected, raw.text.toString())
                assertEquals(expected, view.logicalText.toString()); assertEquals(expected, actual.text.toString())
                assertEquals(listOf(0 to 2, 3 to 4), actual.nodes.map { it.start to it.end })
                assertTrue(actual.nodes.all { it.kind == FloatInteractionKind.LINK })
                if (originalIds == null) originalIds = actual.nodes.map { it.id }
                else assertEquals(originalIds, actual.nodes.map { it.id })
                val native = checkNotNull(value.native)
                val nativeSource = native.source(260)
                val marker = nativeSource.getSpans(0, nativeSource.length, NativeRubyPreparedSource::class.java).single()
                assertEquals(expected, marker.projection.text)
                val ancestorRange = marker.projection.ranges.single { it.role == RubyTextRole.ActionGroup }
                val firstRange = marker.projection.ranges.single { it.role == RubyTextRole.BoxGroup && it.span === inheritedBox }
                val secondRange = marker.projection.ranges.single { it.role == RubyTextRole.BoxGroup && it.span === independentBox }
                assertSame(ancestor, ancestorRange.span)
                assertTrue(firstRange.path.startsWith(ancestorRange.path + "/inlineActionGroup/spans/"))
                assertEquals(0 to 2, firstRange.start to firstRange.end)
                assertEquals(3 to 4, secondRange.start to secondRange.end)
                for (leaf in listOf(small, cumulative, child)) {
                    assertSame(leaf, marker.projection.ranges.single { it.span === leaf }.span)
                }
                assertEquals(2, marker.projection.ranges.count { it.span?.hasInternalAction() == true })
                val parentFormat = marker.groups.getValue(ancestorRange.path)
                val firstFormat = marker.groups.getValue(firstRange.path)
                val secondFormat = marker.groups.getValue(secondRange.path)
                val firstBox = checkNotNull(firstFormat.box); val secondBox = checkNotNull(secondFormat.box)
                val ancestorPaint = checkNotNull(parentFormat.actionPaint)
                val childPaintState = checkNotNull(actual.nodes[1].missingLinkPaint)
                assertSame(ancestorPaint, actual.nodes[0].missingLinkPaint)
                assertSame(ancestorPaint, firstBox.currentColorPaint)
                assertSame(ancestorPolicy, ancestorPaint.ordinaryPolicy)
                assertSame(childPolicy, childPaintState.ordinaryPolicy)
                assertNull(firstFormat.actionOwner); assertNull(secondFormat.actionOwner)
                assertNull(secondBox.currentColorPaint)
                assertEquals(0xff884400.toInt(), secondFormat.paint.color)
                val bodyPixels = with(Density(1f, currentZoom)) { 20.sp.toPx() }
                assertEquals(bodyPixels * 1.35f, firstFormat.paint.textSize, .01f)
                assertEquals(bodyPixels * .9f, secondFormat.paint.textSize, .01f)
                assertTrue(firstFormat.paint.typeface.isBold)
                fun paintAt(offset: Int) = TextPaint(native.paint).also { paint ->
                    nativeSource.getSpans(offset, offset + 1, MetricAffectingSpan::class.java)
                        .filter { nativeSource.getSpanStart(it) <= offset && nativeSource.getSpanEnd(it) > offset }
                        .forEach { it.updateMeasureState(paint) }
                }
                val smallPaint = paintAt(0); val cumulativePaint = paintAt(1); val independentPaint = paintAt(3)
                assertEquals(bodyPixels * .5f, smallPaint.textSize, .01f)
                assertEquals(bodyPixels * 1.35f, cumulativePaint.textSize, .01f)
                assertEquals(bodyPixels * 1.35f, independentPaint.textSize, .01f)
                assertFalse(smallPaint.typeface.isBold); assertFalse(cumulativePaint.typeface.isBold)
                val firstEdge = bodyPixels * 1.35f * .25f
                assertEquals(firstEdge, firstBox.padding.left, .01f)
                assertEquals(firstEdge, firstBox.padding.right, .01f)
                assertEquals(bodyPixels * .9f * .25f, secondBox.padding.left, .01f)
                val firstBorder = checkNotNull(raw.inlineBoxGroupRects(firstBox.owner, firstRange.start, firstRange.end)).single()
                val secondBorder = checkNotNull(raw.inlineBoxGroupRects(secondBox.owner, secondRange.start, secondRange.end)).single()
                // Mixed child fonts shape separately. Neither edge uses the first leaf's font.
                assertEquals(smallPaint.measureText("i") + cumulativePaint.measureText("M") + 2f * firstEdge + 1f,
                    firstBorder.width(), .05f)
                if (originalBoxWidth == 0f) originalBoxWidth = firstBorder.width()
                else if (currentZoom == 1f) assertEquals(originalBoxWidth, firstBorder.width(), .01f)
                val rawCharacters = raw.characterRects(0, expected.length)
                val actualCharacters = actual.characterRects(0, expected.length)
                assertEquals(expected.length, rawCharacters.size); assertEquals(expected.length, actualCharacters.size)
                val firstRaw = checkNotNull(rawCharacters[0]); val firstActual = checkNotNull(actualCharacters[0])
                val dx = firstActual.left - firstRaw.left; val dy = firstActual.top - firstRaw.top
                rawCharacters.zip(actualCharacters).forEach { (a, b) ->
                    sameRect(android.graphics.RectF(checkNotNull(a)).apply { offset(dx, dy) }, checkNotNull(b))
                }
                val firstBoxActual = android.graphics.RectF(firstBorder).apply { offset(dx, dy) }
                val secondBoxActual = android.graphics.RectF(secondBorder).apply { offset(dx, dy) }
                val ancestorEdgePoint = (firstBoxActual.left + firstEdge / 2f) to firstBoxActual.centerY()
                assertEquals(actual.nodes[0].id,
                    checkNotNull(actual.interactionNodeAt(ancestorEdgePoint.first, ancestorEdgePoint.second)).id)
                val childEdgePoint = (secondBoxActual.left + secondBox.padding.left / 2f) to secondBoxActual.centerY()
                assertTrue(actual.nodes[1].bounds.none { it.contains(childEdgePoint.first, childEdgePoint.second) })
                assertNull(actual.interactionNodeAt(childEdgePoint.first, childEdgePoint.second))
                val provider = checkNotNull(view.accessibilityNodeProvider)
                val hostId = android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID
                val host = checkNotNull(provider.createAccessibilityNodeInfo(hostId))
                try { assertEquals(expected, host.text.toString()); assertEquals(2, host.childCount) }
                finally { host.recycle() }
                actual.nodes.forEach { node ->
                    val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                    try { assertEquals(expected.substring(node.start, node.end), info.text.toString()); assertTrue(info.isClickable) }
                    finally { info.recycle() }
                }
                assertTrue(provider.performAction(actual.nodes[0].id,
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(view.hasFocus()); assertTrue(ancestorPaint.focused)
                assertEquals(0xff2255aa.toInt(), checkNotNull(firstBox.currentColorPaint).appearance().color)
                val beforeAncestor = callbacks.size
                assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                assertTrue(ancestorPaint.active)
                assertEquals(0xffee3300.toInt(), checkNotNull(firstBox.currentColorPaint).appearance().color)
                assertEquals(beforeAncestor, callbacks.size)
                assertSame(actual, view.currentMeasuredGeometry)
                assertTrue(view.onKeyUp(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER)))
                assertFalse(ancestorPaint.active)
                assertEquals(beforeAncestor + 1, callbacks.size); assertEquals("typed-box-ancestor", callbacks.last().target)
                assertTrue(provider.performAction(actual.nodes[1].id,
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                val beforeChild = callbacks.size
                assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                assertTrue(childPaintState.active); assertEquals(0xffaa00dd.toInt(), childPaintState.appearance().color)
                assertNull(secondBox.currentColorPaint); assertEquals(0xff884400.toInt(), secondFormat.paint.color)
                assertEquals(beforeChild, callbacks.size)
                assertTrue(view.onKeyUp(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER)))
                assertEquals(beforeChild + 1, callbacks.size); assertEquals("typed-box-child", callbacks.last().target)
                val selection = android.os.Bundle().apply {
                    putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                    putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, expected.length)
                }
                assertTrue(provider.performAction(hostId, android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
                assertEquals(expected, view.selectedTextForCopy())
                assertSame(inheritedBox, ancestor.inlineActionGroup!!.spans.single())
                assertSame(small, inheritedBox.inlineBoxGroup!!.spans[0]); assertSame(cumulative, inheritedBox.inlineBoxGroup!!.spans[1])
                assertSame(overlays, inheritedBox.inlineBoxGroup!!.overlays)
                assertSame(child, independentBox.inlineBoxGroup!!.spans.single())
                assertEquals(1.35f, inheritedBox.fontScale!!, 0f); assertEquals(1.35f, cumulative.fontScale!!, 0f)
                assertEquals("text", inheritedBox.kind); assertEquals("text", independentBox.kind)
            }
        }
        compose.runOnIdle { assertTrue(focusDestination.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter)) }
        compose.onNodeWithTag("inline-box-focus-destination").assertIsFocused()
        assertEquals(List(3) { listOf("typed-box-ancestor", "typed-box-child") }.flatten(), callbacks.map { it.target })
    }
    @Test fun roundedWholeLinkUsesOriginalSourceAndIndependentFocusAcrossZoomAndReflow() = control {
        // Direct typed consumer fixture with synthetic font/focus values. The retained
        // AF label/target/box shape is not an article or physical-device acceptance claim.
        val normal = LinkState("#3366cc", false)
        val active = LinkState("#cc2200", false)
        val policy = LinkPaint(normal, normal, active, active, normal, normal, active, active,
            underlineOnFocus = true, focusOutline = FigureFocusOutline(
                StyleLength(StyleLengthUnit.Px, 3f), FigureColor.Rgb("#ff0000"),
                StyleLength(StyleLengthUnit.Px, 7f), SignedContainerMargin(StyleLengthUnit.Px, -1f)))
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val border = InlineBoxBorderEdge.Solid(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.Rgb("#c8ccd1"))
        val child = Span("text", "Oorganklik", italic = true, foreground = normal.foreground)
        val group = InlineBoxGroup(StyleEdges(zero, StyleLength(StyleLengthUnit.Em, .2f), zero,
            StyleLength(StyleLengthUnit.Em, .1f)), InlineBoxBorderEdges(border, border, border, border),
            spans = listOf(child), radius = StyleWidth(StyleWidthUnit.Px, 2f))
        val link = Span("link", "", "Wiktionary:Oorganklik en onoorganklik", italic = true,
            foreground = normal.foreground, background = "#f8f9fa", linkPaint = policy, inlineBoxGroup = group)
        val period = Span("text", ".")
        val source = listOf(link, period)
        // AF's source-shaped baseline has no authored cursor. This separate typed
        // phase makes owner-cursor rounding observable without claiming AF provenance.
        val helpLink = link.copy(inlineStyle = InlineTextStyle(cursor = InlineCursor.Help))
        val helpSource = listOf(helpLink, period)
        val expected = "Oorganklik."
        data class Phase(val density: Float, val zoom: Float, val widthDp: Int, val help: Boolean = false)
        val phases = listOf(Phase(1f, 1f, 220), Phase(1.5f, 1f, 220),
            Phase(1.5f, 1.4f, 220), Phase(1.5f, 1.4f, 82), Phase(1f, 1f, 220, help = true),
            Phase(1f, 1f, 220))
        val phase = mutableStateOf(0)
        val calls = mutableListOf<EntryLink>()
        val onLink: (EntryLink) -> Unit = { calls += it }
        val visits = MissingLinkVisits()
        val focusDestination = androidx.compose.ui.focus.FocusRequester()
        var prepared: PreparedNativeFloatText? = null
        var committed = -1
        var failure: String? = null
        val observe: (String) -> Unit = { failure = it }
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            val selected = phases[phase.value]
            val selectedSource = if (selected.help) helpSource else source
            val density = Density(selected.density, selected.zoom)
            MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = TextStyle(
                fontSize = 20.sp, fontFamily = FontFamily.Monospace, letterSpacing = 0.sp))) {
                CompositionLocalProvider(LocalDensity provides density, LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalMissingLinkVisits provides visits, LocalNativeFloatContextFailureObserver provides observe) {
                    val style = TextStyle(fontSize = 20.sp, lineHeight = 36.sp,
                        fontFamily = FontFamily.Monospace, letterSpacing = 0.sp, textDirection = TextDirection.Ltr)
                    val annotated = styledTextAnnotation(selectedSource, null, style, onLink)
                    val value = prepareNativeFloatText(selectedSource, annotated, egyptianTextRuns(selectedSource), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(allowImages = false, allowAudio = false),
                        "", onLink, nativeLineHeight = NativeLineHeightPolicy.Pixels(with(density) { 36.sp.toPx() }))
                    SideEffect { prepared = value; committed = phase.value }
                    Box(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)
                        .background(Color.White).testTag("rounded-link-focus-destination")
                        .focusRequester(focusDestination).focusable()) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                            Modifier.width(selected.widthDp.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            error("Rounded link control has no delegated child")
                        }
                    }
                }
            }
        } }
        fun views(root: android.view.View): List<NativeFloatTextView> = buildList {
            if (root is NativeFloatTextView) add(root)
            if (root is android.view.ViewGroup) for (index in 0 until root.childCount) addAll(views(root.getChildAt(index)))
        }
        fun sameRect(a: android.graphics.RectF, b: android.graphics.RectF) {
            assertEquals(a.left, b.left, .01f); assertEquals(a.top, b.top, .01f)
            assertEquals(a.right, b.right, .01f); assertEquals(a.bottom, b.bottom, .01f)
        }
        var firstWidth = 0f
        var firstHeight = 0
        var firstId = 0
        var firstView: NativeFloatTextView? = null
        var firstActionIdentity: MissingLinkActionIdentity? = null
        for (index in phases.indices) {
            compose.runOnIdle { failure = null; phase.value = index }
            compose.waitForIdle()
            var movedFocus = false
            compose.runOnIdle {
                val view = views(compose.activity.window.decorView).single()
                if (view.hasFocus()) {
                    assertTrue(focusDestination.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter))
                    movedFocus = true
                }
            }
            if (movedFocus) compose.onNodeWithTag("rounded-link-focus-destination").assertIsFocused()
            compose.runOnIdle {
                assertEquals(index, committed); assertNull(failure)
                val selected = phases[index]
                val selectedLink = if (selected.help) helpLink else link
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                val view = views(compose.activity.window.decorView).single()
                if (firstView == null) firstView = view else assertSame(firstView, view)
                if (view.selectionActive) {
                    assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ESCAPE,
                        android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ESCAPE)))
                    view.onKeyUp(android.view.KeyEvent.KEYCODE_ESCAPE,
                        android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ESCAPE))
                }
                assertFalse(view.selectionActive)
                val sourceWidth = with(Density(selected.density, selected.zoom)) { selected.widthDp.dp.roundToPx() }
                val actual = checkNotNull(view.currentMeasuredGeometry)
                val surface = actual as NativeSurfaceGeometry
                assertEquals(sourceWidth, surface.content.width)
                assertEquals(surface.width, view.width)
                val raw = checkNotNull(value.geometry).invoke(sourceWidth, emptyList(), false)
                assertEquals(expected, value.text.toString()); assertEquals(expected, view.logicalText.toString())
                assertEquals(expected, actual.text.toString()); assertEquals(expected, raw.text.toString())
                val native = checkNotNull(value.native)
                val nativeSource = native.source(sourceWidth)
                val marker = nativeSource.getSpans(0, nativeSource.length, NativeRubyPreparedSource::class.java).single()
                val range = marker.projection.ranges.single { it.role == RubyTextRole.BoxGroup }
                assertSame(selectedLink, range.span); assertEquals(0 to child.text.length, range.start to range.end)
                assertSame(child, marker.projection.ranges.single { it.span === child }.span)
                assertSame(period, marker.projection.ranges.single { it.span === period }.span)
                assertEquals(1, marker.projection.ranges.count { it.span?.hasInternalAction() == true })
                val format = marker.groups.getValue(range.path)
                val box = checkNotNull(format.box)
                assertSame(selectedLink, box.owner.span)
                assertEquals(range.path, box.owner.path)
                val node = actual.nodes.single()
                assertEquals(FloatInteractionKind.LINK, node.kind)
                assertEquals(0 to child.text.length, node.start to node.end)
                assertEquals(child.text, node.label.toString())
                assertNull(node.preciseClip) // Rounded decoration/hits must not become a glyph clip.
                val state = checkNotNull(node.missingLinkPaint)
                assertSame(policy, state.ordinaryPolicy)
                assertSame(format.actionPaint, state)
                assertSame(state, box.currentColorPaint)
                val identity = checkNotNull(state.actionIdentity)
                assertSame(checkNotNull(format.actionOwner), identity.occurrence)
                if (index == 0) { firstId = node.id; firstActionIdentity = identity }
                else {
                    assertEquals(firstId, node.id)
                    if (index < 4) assertEquals(firstActionIdentity, identity)
                }
                val bodyPixels = 20f * selected.density * selected.zoom
                assertEquals(bodyPixels, format.paint.textSize, .01f)
                assertTrue(format.paint.typeface.isItalic)
                assertEquals(0xfff8f9fa.toInt(), format.paint.bgColor)
                assertEquals(2f * selected.density, checkNotNull(box.radius), .001f)
                assertEquals(bodyPixels * .1f, box.padding.left, .01f)
                assertEquals(bodyPixels * .2f, box.padding.right, .01f)
                assertEquals(0f, box.padding.top, 0f); assertEquals(0f, box.padding.bottom, 0f)
                for (edge in listOf(box.border.top, box.border.right, box.border.bottom, box.border.left)) {
                    assertEquals(selected.density, edge.width, .001f)
                    assertEquals(0xffc8ccd1.toInt(), edge.color)
                }
                val leafPaint = TextPaint(native.paint).also { p ->
                    nativeSource.getSpans(0, 1, MetricAffectingSpan::class.java)
                        .filter { nativeSource.getSpanStart(it) <= 0 && nativeSource.getSpanEnd(it) > 0 }
                        .forEach { it.updateMeasureState(p) }
                }
                assertEquals(bodyPixels, leafPaint.textSize, .01f); assertTrue(leafPaint.typeface.isItalic)
                val borders = checkNotNull(raw.inlineBoxGroupRects(box.owner, range.start, range.end))
                assertTrue(borders.isNotEmpty())
                val nativeHit = checkNotNull(raw.inlineBoxGroupHitTest(box.owner, range.start, range.end))
                val rawChars = raw.characterRects(0, expected.length)
                val actualChars = actual.characterRects(0, expected.length)
                assertEquals(expected.length, actualChars.size)
                val rawFirst = checkNotNull(rawChars.first()); val actualFirst = checkNotNull(actualChars.first())
                val dx = actualFirst.left - rawFirst.left; val dy = actualFirst.top - rawFirst.top
                rawChars.zip(actualChars).forEach { (a, b) ->
                    sameRect(android.graphics.RectF(checkNotNull(a)).apply { offset(dx, dy) }, checkNotNull(b))
                }
                assertEquals(borders.size, node.bounds.size)
                borders.zip(node.bounds).forEach { (a, b) -> sameRect(android.graphics.RectF(a).apply { offset(dx, dy) }, b) }
                if (index != 3) {
                    assertEquals(1, borders.size)
                    val independent = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        textSize = bodyPixels
                        typeface = android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.ITALIC)
                    }
                    assertEquals(independent.measureText(child.text) + bodyPixels * .3f + 2f * selected.density,
                        borders.single().width(), .08f)
                } else assertTrue("the narrow allocation must cause real source reflow", borders.size > 1)
                if (index == 0) { firstWidth = borders.single().width(); firstHeight = actual.height }
                if (index == phases.lastIndex) {
                    assertEquals(firstWidth, borders.single().width(), .01f)
                    assertEquals(firstHeight, actual.height)
                }
                val first = borders.first()
                val radius = 2f * selected.density
                val corner = (first.left + radius * .1f) to (first.top + radius * .1f)
                assertTrue(first.contains(corner.first, corner.second))
                assertFalse(nativeHit(corner.first, corner.second))
                val cornerActual = (corner.first + dx) to (corner.second + dy)
                assertFalse(node.contains(cornerActual.first, cornerActual.second))
                assertNull(actual.interactionNodeAt(cornerActual.first, cornerActual.second))
                val inside = (first.left + selected.density + bodyPixels * .05f) to first.centerY()
                assertTrue(nativeHit(inside.first, inside.second))
                val insideActual = (inside.first + dx) to (inside.second + dy)
                assertTrue(node.contains(insideActual.first, insideActual.second))
                assertEquals(node.id, checkNotNull(actual.interactionNodeAt(insideActual.first, insideActual.second)).id)
                val punctuation = checkNotNull(actualChars.last())
                assertFalse(node.contains(punctuation.centerX(), punctuation.centerY()))
                if (selected.help) {
                    assertNull(actual.cursorAt(cornerActual.first, cornerActual.second))
                    assertEquals(InlineCursor.Help, actual.cursorAt(insideActual.first, insideActual.second))
                    assertNull(actual.cursorAt(punctuation.centerX(), punctuation.centerY()))
                    fun icon(point: Pair<Float, Float>): android.view.PointerIcon? {
                        val now = android.os.SystemClock.uptimeMillis()
                        val event = android.view.MotionEvent.obtain(now, now, android.view.MotionEvent.ACTION_HOVER_MOVE,
                            point.first + view.paddingLeft, point.second + view.paddingTop, 0)
                        event.source = android.view.InputDevice.SOURCE_MOUSE
                        return try { view.onResolvePointerIcon(event, 0) } finally { event.recycle() }
                    }
                    val help = android.view.PointerIcon.getSystemIcon(view.context, android.view.PointerIcon.TYPE_HELP)
                    assertEquals(help, icon(insideActual))
                    assertNotEquals(help, icon(cornerActual))
                }
                fun tap(point: Pair<Float, Float>) {
                    val down = android.os.SystemClock.uptimeMillis()
                    // Finish each owned synthetic gesture before the next sample; no
                    // timing/sleep assumption or accidental double-tap recognition.
                    for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP,
                        android.view.MotionEvent.ACTION_CANCEL)) {
                        val event = android.view.MotionEvent.obtain(down, android.os.SystemClock.uptimeMillis(), action,
                            point.first + view.paddingLeft - view.scrollX, point.second + view.paddingTop - view.scrollY, 0)
                        try { view.dispatchTouchEvent(event) } finally { event.recycle() }
                    }
                }
                val beforePointer = calls.size
                tap(cornerActual); assertEquals(beforePointer, calls.size)
                tap(insideActual); assertEquals(beforePointer + 1, calls.size)
                assertEquals(link.target, calls.last().target)
                val outlines = checkNotNull(node.focusPaint).outlines()
                assertTrue(outlines.isNotEmpty())
                for (outline in outlines) {
                    assertEquals(3f * selected.density, outline.width, .001f)
                    assertEquals(7f * selected.density, outline.radius, .001f)
                    assertEquals(-selected.density, outline.offset, .001f)
                    assertEquals(0xffff0000.toInt(), outline.color)
                }
                val provider = checkNotNull(view.accessibilityNodeProvider)
                val hostId = android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID
                val host = checkNotNull(provider.createAccessibilityNodeInfo(hostId))
                try { assertEquals(expected, host.text.toString()); assertEquals(1, host.childCount) } finally { host.recycle() }
                val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                try { assertEquals(child.text, info.text.toString()); assertTrue(info.isClickable); assertTrue(info.isVisibleToUser) }
                finally { info.recycle() }
                assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(state.focused)
                val beforeEnter = calls.size
                assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                assertTrue(state.active); assertEquals(0xffcc2200.toInt(), state.appearance().color)
                assertEquals(beforeEnter, calls.size)
                assertTrue(view.onKeyUp(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER)))
                assertFalse(state.active); assertEquals(beforeEnter + 1, calls.size)
                assertEquals(link.target, calls.last().target)
                view.setSelection(0, expected.length)
                assertEquals(expected, view.selectedTextForCopy())
                assertSame(child, link.inlineBoxGroup!!.spans.single()); assertSame(group, link.inlineBoxGroup)
                assertSame(period, source.last()); assertEquals("", link.text); assertEquals("text", child.kind)
                assertEquals("#f8f9fa", link.background); assertTrue(link.italic)
            }
        }
        compose.runOnIdle { assertTrue(focusDestination.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter)) }
        compose.onNodeWithTag("rounded-link-focus-destination").assertIsFocused()
        assertEquals(phases.size * 2, calls.size)
        assertTrue(calls.all { it.target == link.target })
    }

    @Test fun atomicInlineLoweringKeepsDeclaringFontInnerBaselineAndCaretCustodyAcrossReflow() = control {
        // Controlled typed source: .9 parent and .81 declaring font are explicit fixture
        // values, not inferred HU article fonts. The source-shaped swatch contains real NBSP.
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val one = StyleLength(StyleLengthUnit.Px, 1f)
        val border = InlineBoxBorderEdge.Solid(one, InlineBoxColor.Rgb("#000000"))
        val emptyEdges = StyleEdges(zero, zero, zero, zero)
        val normalized = InlineTextStyle(fontNormalized = true)
        val following = Span("link", "\u00a0V tail", "atomic-original-neighbor", fontScale = .9f,
            fontScaleBasis = FontScaleBasis.NormalBody, inlineStyle = normalized, foreground = "#3366cc")
        data class Source(val spans: List<Span>, val owner: Span?, val child: Span?,
            val scale: Float, val wrap: TextWrap, val lineFactor: Float?)
        fun source(body: String, scale: Float = .81f, wrap: TextWrap = TextWrap.BreakWord,
            lineFactor: Float? = null, background: String = "#ff0000"): Source {
            val snapshot = InlineFontSnapshot(fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
                fontNormalized = true, language = "hu")
            val lh = lineFactor?.let { InlineLineHeight.FontRelative(it, snapshot) }
            val child = Span("text", body, fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
                language = "hu", direction = "ltr", inlineStyle = normalized)
            val atomic = InlineBoxAtomicLayout(StyleLength(StyleLengthUnit.Em, 1.5f),
                StyleLength(StyleLengthUnit.Em, 1.5f), StyleEdges(one, zero, one, zero),
                ContainerBoxSizing.ContentBox, InlineBoxOverlayTextAlign.Center, wrap, lh)
            val owner = Span("text", "", fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
                language = "hu", direction = "ltr", inlineStyle = normalized, background = background,
                inlineBoxGroup = InlineBoxGroup(emptyEdges, InlineBoxBorderEdges(border, border, border, border),
                    spans = listOf(child), atomicLayout = atomic))
            return Source(listOf(owner, following), owner, child, scale, wrap, lineFactor)
        }
        val swatch = source("\u00a0")
        val largerFont = source("\u00a0", .9f, background = "#ffffff")
        val unbroken = source("ABCDEFGHIJKLMNO", wrap = TextWrap.Normal)
        val emergency = source("ABCDEFGHIJKLMNO")
        val numeric = source("ABCDEFGHIJKLMNO", lineFactor = 1.8f)
        val removed = Source(listOf(following), null, null, .81f, TextWrap.BreakWord, null)
        data class Phase(val source: Source, val density: Float = 1f, val zoom: Float = 1f,
            val widthDp: Int = 220, val outerNumeric: Boolean = true)
        val phases = listOf(Phase(swatch), Phase(swatch, 1.5f), Phase(swatch, 1.5f, 1.3f),
            Phase(largerFont), Phase(unbroken), Phase(emergency), Phase(numeric),
            Phase(numeric, outerNumeric = false), Phase(numeric, widthDp = 58), Phase(removed), Phase(swatch))
        val selected = mutableStateOf(0)
        val calls = mutableListOf<EntryLink>()
        val onLink: (EntryLink) -> Unit = { calls += it }
        val focusDestination = androidx.compose.ui.focus.FocusRequester()
        var prepared: PreparedNativeFloatText? = null
        var committed = -1
        var failure: String? = null
        val observe: (String) -> Unit = { failure = it }
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            val index = selected.value
            val phase = phases[index]
            val density = Density(phase.density, phase.zoom)
            MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = TextStyle(
                fontSize = 20.sp, fontFamily = FontFamily.Monospace, letterSpacing = 0.sp))) {
                CompositionLocalProvider(LocalDensity provides density, LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalNativeFloatContextFailureObserver provides observe) {
                    val style = TextStyle(fontSize = 18.sp, fontFamily = FontFamily.Monospace, letterSpacing = 0.sp,
                        textDirection = TextDirection.Ltr, lineHeight = if (phase.outerNumeric) 40.sp
                            else androidx.compose.ui.unit.TextUnit.Unspecified)
                    val annotated = styledTextAnnotation(phase.source.spans, null, style, onLink)
                    val value = prepareNativeFloatText(phase.source.spans, annotated, egyptianTextRuns(phase.source.spans), style,
                        MaterialTheme.colorScheme.primary, emptyList(), AppSettings(allowImages = false, allowAudio = false),
                        "", onLink, nativeLineHeight = if (phase.outerNumeric)
                            NativeLineHeightPolicy.Pixels(with(density) { 40.sp.toPx() }) else NativeLineHeightPolicy.Normal)
                    SideEffect { prepared = value; committed = index }
                    Box(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp).background(Color.White)
                        .testTag("atomic-focus-destination").focusRequester(focusDestination).focusable()) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                            Modifier.width(phase.widthDp.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            error("Atomic inline control has no delegated child")
                        }
                    }
                }
            }
        } }
        fun views(root: android.view.View): List<NativeFloatTextView> = buildList {
            if (root is NativeFloatTextView) add(root)
            if (root is android.view.ViewGroup) for (index in 0 until root.childCount) addAll(views(root.getChildAt(index)))
        }
        fun sameRect(a: android.graphics.RectF, b: android.graphics.RectF) {
            assertEquals(a.left, b.left, .02f); assertEquals(a.top, b.top, .02f)
            assertEquals(a.right, b.right, .02f); assertEquals(a.bottom, b.bottom, .02f)
        }
        var initialBorder: android.graphics.RectF? = null
        var initialHeight = 0
        var initialView: NativeFloatTextView? = null
        var normalInnerHeight = 0f
        var numericInnerHeight = 0f
        for (index in phases.indices) {
            compose.runOnIdle { failure = null; selected.value = index }
            compose.waitForIdle()
            var movedFocus = false
            compose.runOnIdle {
                val view = views(compose.activity.window.decorView).single()
                if (view.hasFocus()) {
                    assertTrue(focusDestination.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter))
                    movedFocus = true
                }
            }
            if (movedFocus) compose.onNodeWithTag("atomic-focus-destination").assertIsFocused()
            compose.runOnIdle {
                assertEquals(index, committed); assertNull(failure)
                val phase = phases[index]
                val fixture = phase.source
                val child = fixture.child
                val expected = child?.text.orEmpty() + following.text
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                val view = views(compose.activity.window.decorView).single()
                if (initialView == null) initialView = view else assertSame(initialView, view)
                val actual = checkNotNull(view.currentMeasuredGeometry)
                val surface = actual as NativeSurfaceGeometry
                val width = with(Density(phase.density, phase.zoom)) { phase.widthDp.dp.roundToPx() }
                assertEquals(width, surface.content.width)
                val raw = checkNotNull(value.geometry).invoke(width, emptyList(), false)
                assertEquals(expected, value.text.toString()); assertEquals(expected, raw.text.toString())
                assertEquals(expected, view.logicalText.toString()); assertEquals(expected, actual.text.toString())
                assertFalse(expected.contains('\ufffc'))
                val native = checkNotNull(value.native)
                val nativeSource = native.source(width)
                val marker = nativeSource.getSpans(0, nativeSource.length, NativeRubyPreparedSource::class.java).singleOrNull()
                val node = actual.nodes.single()
                assertEquals(FloatInteractionKind.LINK, node.kind)
                assertEquals(child?.text?.length ?: 0, node.start); assertEquals(expected.length, node.end)
                assertEquals(following.text, node.label.toString())
                if (child != null) {
                    val projection = checkNotNull(marker).projection
                    assertEquals(expected, projection.text)
                    val range = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
                    assertSame(fixture.owner, range.span)
                    assertSame(child, projection.ranges.single { it.span === child }.span)
                    assertSame(following, projection.ranges.single { it.span === following }.span)
                    val format = marker.groups.getValue(range.path)
                    val box = checkNotNull(format.box)
                    assertSame(fixture.owner, box.owner.span)
                    val fontPixels = 20f * phase.density * phase.zoom * fixture.scale
                    assertEquals(fontPixels, format.paint.textSize, .01f)
                    assertEquals(android.graphics.Color.parseColor(checkNotNull(fixture.owner).background), format.paint.bgColor)
                    val contentSize = 1.5f * fontPixels
                    val borderRect = checkNotNull(raw.inlineBoxGroupRects(box.owner, range.start, range.end)).single()
                    assertEquals(contentSize + 2f * phase.density, borderRect.width(), .01f)
                    assertEquals(contentSize + 2f * phase.density, borderRect.height(), .01f)
                    val atom = raw.nativeRubyShapingSource.getSpans(0, raw.nativeRubyShapingSource.length,
                        NativeInlineAtomicBox::class.java).single()
                    val inner = atom.child.geometry as NativeFloatGeometry
                    assertEquals(child.text, inner.text.toString())
                    assertEquals(contentSize + 2f * phase.density, atom.advance, .01f)
                    assertEquals(contentSize + 4f * phase.density, atom.metrics.bottom - atom.metrics.top, .01f)
                    val independent = TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG or android.graphics.Paint.SUBPIXEL_TEXT_FLAG).apply {
                        textSize = fontPixels; typeface = android.graphics.Typeface.MONOSPACE
                        textLocale = java.util.Locale.forLanguageTag("hu")
                    }
                    val measured = android.graphics.text.MeasuredText.Builder(child.text.toCharArray()).setComputeLayout(true)
                        .appendStyleRun(independent, child.text.length, false).build()
                    val breaker = android.graphics.text.LineBreaker.Builder()
                        .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                        .setHyphenationFrequency(android.graphics.text.LineBreaker.HYPHENATION_FREQUENCY_NONE).build()
                    val fitted = breaker.computeLineBreaks(measured,
                        android.graphics.text.LineBreaker.ParagraphConstraints().apply { setWidth(contentSize) }, 0)
                    val ends = if (fixture.wrap == TextWrap.Normal) listOf(child.text.length)
                        else List(fitted.lineCount) { fitted.getLineBreakOffset(it) }
                    assertEquals(ends.size, inner.shapedLineCount)
                    if (fixture === unbroken) {
                        assertTrue(independent.measureText(child.text) > contentSize)
                        assertEquals(1, inner.shapedLineCount)
                    }
                    if (fixture === emergency || fixture === numeric) assertTrue(ends.size > 1)
                    val fm = independent.fontMetrics
                    val rowHeight = fixture.lineFactor?.let { it * fontPixels } ?: (fm.descent - fm.ascent)
                    val halfLeading = (rowHeight - (fm.descent - fm.ascent)) / 2f
                    val firstBaseline = -fm.ascent + halfLeading
                    val lastBaseline = firstBaseline + (ends.size - 1) * rowHeight
                    assertEquals(firstBaseline, checkNotNull(inner.textBaselines?.first), .02f)
                    assertEquals(lastBaseline, checkNotNull(inner.textBaselines?.last), .02f)
                    var start = 0
                    ends.forEachIndexed { line, end ->
                        assertEquals(start to end, inner.nativeRangeOfLine(line))
                        assertEquals(firstBaseline + line * rowHeight, inner.baselineForOffset(start), .02f)
                        start = end
                    }
                    val outerBaseline = raw.baselineForOffset(range.end - 1)
                    assertEquals(outerBaseline - phase.density - lastBaseline, borderRect.top, .02f)
                    // The actual external NBSP and short label stay outside the atom. Its
                    // fixed advance is independent of the long inner word's visible overflow.
                    assertEquals(outerBaseline, raw.baselineForOffset(range.end + 1), .02f)
                    if (phase.widthDp == 58) {
                        val outsidePaint = TextPaint(independent).apply { textSize = 18f * phase.density * phase.zoom }
                        val gluedWidth = contentSize + 2f * phase.density + outsidePaint.measureText("\u00a0V")
                        assertTrue(gluedWidth < width)
                        assertTrue(gluedWidth + outsidePaint.measureText(" tail") > width)
                        assertTrue(raw.nativeRubyRaw.shapedLineCount > 1)
                        assertTrue(raw.baselineForOffset(expected.lastIndex) > outerBaseline)
                    } else assertEquals(1, raw.nativeRubyRaw.shapedLineCount)
                    if (fixture === emergency) normalInnerHeight = inner.textBottom
                    if (fixture === numeric && index == 6) {
                        numericInnerHeight = inner.textBottom
                        assertTrue(numericInnerHeight > normalInnerHeight)
                    }
                    if (fixture === numeric && index >= 7) assertEquals(numericInnerHeight, inner.textBottom, .02f)
                    if (ends.size > 1) {
                        assertTrue(inner.textBottom > contentSize)
                        assertTrue(checkNotNull(raw.extents.ink).bottom > borderRect.bottom)
                    }
                    val rawChars = raw.characterRects(0, expected.length)
                    val actualChars = actual.characterRects(0, expected.length)
                    assertTrue(rawChars.all { it != null }); assertTrue(actualChars.all { it != null })
                    val dx = actualChars.first()!!.left - rawChars.first()!!.left
                    val dy = actualChars.first()!!.top - rawChars.first()!!.top
                    rawChars.zip(actualChars).forEach { (a, b) ->
                        sameRect(android.graphics.RectF(checkNotNull(a)).apply { offset(dx, dy) }, checkNotNull(b))
                    }
                    val up = NativeTextCaret(range.end, NativeTextAffinity.Upstream)
                    val down = NativeTextCaret(range.end, NativeTextAffinity.Downstream)
                    val upRect = actual.caretRect(up); val downRect = actual.caretRect(down)
                    assertTrue(kotlin.math.abs(upRect.left - downRect.left) > .1f)
                    assertTrue(view.requestFocus())
                    view.setSelection(up, up)
                    assertEquals(up, view.selectionExtentCaret)
                    assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_DPAD_RIGHT,
                        android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_DPAD_RIGHT)))
                    assertEquals(down, view.selectionExtentCaret)
                    if (index == 0) {
                        initialBorder = android.graphics.RectF(borderRect); initialHeight = actual.height
                        // Real viewport callback sees the selected atom endpoint, not the
                        // following source caret at the identical UTF-16 boundary.
                        val revealed = mutableListOf<android.graphics.RectF>()
                        val clip = android.graphics.RectF(0f, 0f, 12f, raw.height.toFloat())
                        val placement = NativeTableBlockPlacement(android.graphics.RectF(clip), clip, 0f, 0f, 0f,
                            raw.width, raw.height, 0, 0, 0f, 0f, 12, raw.height, null,
                            revealContentRect = { rect, complete -> revealed += android.graphics.RectF(rect); complete() })
                        val viewport = NativeTableViewportGeometry(raw, placement)
                        viewport.revealOffset(up) {}; viewport.revealOffset(down) {}
                        assertEquals(2, revealed.size)
                        sameRect(raw.caretRect(up), revealed[0]); sameRect(raw.caretRect(down), revealed[1])
                        assertTrue(kotlin.math.abs(revealed[0].left - revealed[1].left) > .1f)
                        // Explicit synthetic ordered owners, not an assertion that ordinary
                        // grid cells have no separators. Both children use real native text.
                        val suffix = NativeFloatGeometry.build(android.text.SpannableString("Z"), native.paint, 80,
                            emptyList(), textDirection = android.text.TextDirectionHeuristics.LTR)
                        val joined = NativeSemanticGroup(raw.width + 80, raw.height, listOf(
                            PositionedSemanticChild(viewport, 0f, 0f, BidiResolvedDirection.Ltr),
                            PositionedSemanticChild(suffix, 40f, 0f, BidiResolvedDirection.Ltr)))
                        val endUp = NativeTextCaret(raw.text.length, NativeTextAffinity.Upstream)
                        val endDown = NativeTextCaret(raw.text.length)
                        sameRect(clip, checkNotNull(joined.clipForOffset(endUp)))
                        assertNull(joined.clipForOffset(endDown))
                        val beforeReveal = revealed.size
                        joined.revealOffset(endUp) {}; joined.revealOffset(endDown) {}
                        assertEquals(beforeReveal + 1, revealed.size)
                        sameRect(raw.caretRect(NativeTextCaret(raw.text.length, NativeTextAffinity.Upstream)), revealed.last())
                        assertEquals(endDown, joined.visualCaret(endUp, 1))
                        assertEquals(endUp, joined.visualCaret(endDown, -1))
                    }
                    if (index == phases.lastIndex) {
                        sameRect(checkNotNull(initialBorder), borderRect)
                        assertEquals(initialHeight, actual.height)
                    }
                } else {
                    assertTrue(raw.nativeRubyShapingSource.getSpans(0, raw.nativeRubyShapingSource.length,
                        NativeInlineAtomicBox::class.java).isEmpty())
                }
                val provider = checkNotNull(view.accessibilityNodeProvider)
                val hostId = android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID
                val host = checkNotNull(provider.createAccessibilityNodeInfo(hostId))
                try { assertEquals(expected, host.text.toString()); assertEquals(1, host.childCount) }
                finally { host.recycle() }
                val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                try { assertEquals(following.text, info.text.toString()); assertTrue(info.isClickable) }
                finally { info.recycle() }
                view.setSelection(0, expected.length)
                assertEquals(expected, view.selectedTextForCopy())
                assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ESCAPE,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ESCAPE)))
                assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                val before = calls.size
                assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                assertEquals(before + 1, calls.size)
                view.onKeyUp(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                assertEquals(before + 1, calls.size); assertEquals(following.target, calls.last().target)
            }
        }
        assertEquals(phases.size, calls.size)
    }

    @Test fun plainCircleAdvisoriesKeepRealTableSmallTextAndToolkitHoverWithoutActions() = control {
        val title = "Vowel sign appearing in front of the initial consonant."
        val replacementTitle = "Controlled replacement advisory"
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val dotted = InlineBoxBorderEdge.Dotted(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.Rgb("#808080"))
        val border = InlineBoxBorderEdges(dotted, dotted, dotted, dotted)
        fun small(text: String, tooltip: String? = null) = Span("text", text, tooltip = tooltip,
            fontScale = .8f, fontScaleBasis = FontScaleBasis.NormalBody)
        fun badge(tooltip: String? = title, childTitle: String? = null, rounded: Boolean = true) =
            small("", tooltip).copy(inlineStyle = InlineTextStyle(cursor = InlineCursor.Help),
                inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), border,
                    spans = listOf(small("e", childTitle)),
                    radius = if (rounded) StyleWidth(StyleWidthUnit.Percent, 50f) else null))
        val firstThai = "เงินปันผล"
        val secondThai = "เงิ็น-ปัน-ผน"
        val firstTail = "\u2009ŋ\u2009i\u2009n\u2009p\u2009ạ\u2009n\u2009pʰ\u2009l"
        val secondTail = "\u2009ŋ\u2009i\u2009˘\u2009n\u2009–\u2009p\u2009ạ\u2009n\u2009–\u2009pʰ\u2009n"
        val reference = Span("link", "Reference", "advisory-reference", targetFragment = "Original")
        val callbacks = mutableListOf<EntryLink>()
        data class Fixture(val entry: Entry, val first: Span, val second: Span, val width: Int = 300,
            val density: Float = 1f, val zoom: Float = 1f)
        fun fixture(first: Span = badge(), second: Span = badge(), width: Int = 300,
            density: Float = 1f, zoom: Float = 1f): Fixture {
            fun line(thai: String, owner: Span, tail: String) = listOf(Span("text", thai, language = "th"),
                Span("line_break", ""), owner, small(tail))
            val cellStyle = CellStyle(textAlign = CellTextAlign.Center)
            // Source-derived controlled subset: both complete advisory TD bodies, with
            // the second real DIV retained. The 20sp/.8 font is fixture data, not MG proof.
            val table = Table(emptyList(), listOf(
                listOf(Cell(line(firstThai, first, firstTail), false, 1, 1, style = cellStyle)),
                listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(Block("container", 0, emptyList(),
                    container = Container(listOf(Block("paragraph", 0, line(secondThai, second, secondTail)))))), style = cellStyle))),
                geometry = TableGeometry(cellPadding = 10, cellSpacing = 2),
                style = TableStyle(border = StyleBorder.Solid(StyleLength(StyleLengthUnit.Px, 1f), "#a9a9a9")))
            val entry = Entry("Advisory control", emptyList(), "language", "Thai", "th",
                listOf(Section(3, "Pronunciation", listOf(Block("table", 0, emptyList(), table = table),
                    Block("paragraph", 0, listOf(reference))))), emptyList())
            return Fixture(entry, first, second, width, density, zoom)
        }
        val original = fixture()
        val selected = mutableStateOf(original, referentialEqualityPolicy())
        var failure: String? = null
        val observer: (String) -> Unit = { failure = it }
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            val state = selected.value
            CompositionLocalProvider(LocalDensity provides Density(state.density, state.zoom),
                LocalLayoutDirection provides LayoutDirection.Ltr, LocalNativeFloatContextFailureObserver provides observer) {
                MaterialTheme(colorScheme = androidx.compose.material3.lightColorScheme(background = Color.White,
                    surface = Color.White, onSurface = Color.Black), typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp,
                    fontFamily = FontFamily.Monospace, color = Color.Black, letterSpacing = 0.sp))) {
                    Box(Modifier.fillMaxSize().background(Color.White).safeDrawingPadding().padding(12.dp)) {
                        Box(Modifier.width(state.width.dp)) {
                            EntryView(state.entry, false, {}, { callbacks += it },
                                settings = AppSettings(allowImages = false, allowAudio = false))
                        }
                    }
                }
            }
        } }
        fun nativeViews(root: android.view.View): List<NativeFloatTextView> = buildList {
            if (root is NativeFloatTextView) add(root)
            if (root is android.view.ViewGroup) for (i in 0 until root.childCount) addAll(nativeViews(root.getChildAt(i)))
        }
        fun expectedCellText(thai: String) = thai + "\ne" + if (thai == firstThai) firstTail else secondTail
        fun view(thai: String): NativeFloatTextView = nativeViews(compose.activityRule.activity().window.decorView)
            .single { it.currentMeasuredGeometry?.text?.toString() == expectedCellText(thai) }
        fun popup(value: String): android.widget.TextView? {
            fun find(root: android.view.View): android.widget.TextView? {
                val visible = android.graphics.Rect()
                if (root is android.widget.TextView && root.text.toString() == value && root.isShown &&
                    root.getGlobalVisibleRect(visible) && !visible.isEmpty) return root
                if (root is android.view.ViewGroup) for (i in 0 until root.childCount) find(root.getChildAt(i))?.let { return it }
                return null
            }
            val decor = compose.activityRule.activity().window.decorView
            return android.view.inspector.WindowInspector.getGlobalWindowViews().asSequence()
                .filter { it !== decor }.mapNotNull(::find).firstOrNull()
        }
        fun awaitPopup(value: String, shown: Boolean) = compose.waitUntil(5000) {
            var present = false
            compose.runOnIdle { present = popup(value) != null }
            present == shown
        }
        fun awaitFixture() {
            compose.waitUntil(5000) {
                var ready = false
                compose.runOnIdle { ready = nativeViews(compose.activityRule.activity().window.decorView)
                    .count { it.currentMeasuredGeometry?.text?.toString() in listOf(expectedCellText(firstThai), expectedCellText(secondThai)) } == 2 }
                ready
            }
            compose.waitForIdle()
            compose.runOnIdle { assertNull(failure) }
        }
        fun change(value: Fixture) {
            compose.runOnIdle { failure = null; selected.value = value }
            awaitFixture()
        }
        var lastScreen: Pair<Float, Float>? = null
        var lastTool = android.view.MotionEvent.TOOL_TYPE_MOUSE
        fun inject(action: Int, point: Pair<Float, Float>, tool: Int = android.view.MotionEvent.TOOL_TYPE_MOUSE,
            checkFixture: Boolean = true) {
            if (checkFixture) compose.runOnIdle {
                val activity = compose.activityRule.activity()
                assertPhysicalActivity(activity)
                assertTrue(activity.hasWindowFocus())
                val manager = activity.getSystemService(android.view.accessibility.AccessibilityManager::class.java)
                assertFalse("Hover popup fixture requires touch exploration to be inactive", manager.isTouchExplorationEnabled)
            }
            val properties = android.view.MotionEvent.PointerProperties().apply { id = 0; toolType = tool }
            val coordinates = android.view.MotionEvent.PointerCoords().apply { x = point.first; y = point.second }
            val source = if (tool == android.view.MotionEvent.TOOL_TYPE_STYLUS) android.view.InputDevice.SOURCE_STYLUS
                else android.view.InputDevice.SOURCE_MOUSE
            val now = android.os.SystemClock.uptimeMillis()
            val event = android.view.MotionEvent.obtain(now, now, action, 1, arrayOf(properties), arrayOf(coordinates),
                0, 0, 1f, 1f, 0, 0, source, 0)
            try { androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().sendPointerSync(event) }
            finally { event.recycle() }
            lastScreen = point; lastTool = tool
            compose.waitForIdle()
        }
        fun screen(view: NativeFloatTextView, x: Float, y: Float): Pair<Float, Float> {
            val matrix = android.graphics.Matrix(); view.transformMatrixToGlobal(matrix)
            val point = floatArrayOf(x + view.paddingLeft, y + view.paddingTop); matrix.mapPoints(point)
            return point[0] to point[1]
        }
        fun hover(thai: String, owner: Span, tool: Int = android.view.MotionEvent.TOOL_TYPE_MOUSE,
            corner: Boolean = false): Pair<Float, Float> {
            lateinit var point: Pair<Float, Float>
            compose.runOnIdle {
                val actual = view(thai); val geometry = checkNotNull(actual.currentMeasuredGeometry)
                val node = geometry.nodes.single { it.advisoryIdentity?.span === owner }
                val box = node.bounds.single()
                val x = if (corner) box.left + .05f else box.centerX()
                val y = if (corner) box.top + .05f else box.centerY()
                assertEquals(!corner, node.contains(x, y))
                point = screen(actual, x, y)
            }
            inject(android.view.MotionEvent.ACTION_HOVER_ENTER, point, tool)
            inject(android.view.MotionEvent.ACTION_HOVER_MOVE, point, tool)
            return point
        }
        data class CellRaster(val bitmap: android.graphics.Bitmap, val left: Int, val top: Int)
        fun captureCell(): CellRaster {
            val interaction = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true)
            val node = interaction.fetchSemanticsNode()
            val bounds = node.boundsInRoot
            val root = (checkNotNull(node.root) as androidx.compose.ui.platform.ViewRootForTest).view
            val bitmap = interaction.captureToImage().asAndroidBitmap()
            try {
                val location = IntArray(2)
                compose.runOnIdle { root.getLocationOnScreen(location) }
                assertEquals(bounds.right.roundToInt() - bounds.left.roundToInt(), bitmap.width)
                assertEquals(bounds.bottom.roundToInt() - bounds.top.roundToInt(), bitmap.height)
                return CellRaster(bitmap, location[0] + bounds.left.roundToInt(), location[1] + bounds.top.roundToInt())
            } catch (failure: Throwable) { bitmap.recycle(); throw failure }
        }
        fun glyphMask(bitmap: android.graphics.Bitmap): Set<Int> = buildSet {
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (android.graphics.Color.alpha(pixel) > 0 && android.graphics.Color.red(pixel) < 40 &&
                    android.graphics.Color.green(pixel) < 40 && android.graphics.Color.blue(pixel) < 40)
                    add(y * bitmap.width + x)
            }
        }
        var primary: Throwable? = null
        try {
            awaitFixture()
            lateinit var originalGlyphs: Set<Int>
            lateinit var originalCharacters: List<android.graphics.RectF?>
            compose.runOnIdle {
                for ((thai, tail, owner) in listOf(Triple(firstThai, firstTail, original.first), Triple(secondThai, secondTail, original.second))) {
                    val actual = view(thai); val geometry = checkNotNull(actual.currentMeasuredGeometry)
                    assertEquals(thai + "\ne" + tail, geometry.text.toString())
                    val node = geometry.nodes.single { it.kind == FloatInteractionKind.ADVISORY }
                    assertSame(owner, checkNotNull(node.advisoryIdentity).span)
                    assertEquals("e", geometry.text.subSequence(node.start, node.end).toString())
                    assertEquals(title, node.tooltip); assertNull(node.onClick); assertNull(node.onLongClick); assertNull(node.preciseClip)
                    assertTrue(geometry.characterRects(node.start, 1).single()?.isEmpty == false)
                    val info = checkNotNull(actual.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                    try {
                        assertEquals("e", info.text.toString()); assertEquals(title, info.tooltipText.toString())
                        assertFalse(info.isClickable); assertFalse(info.isLongClickable); assertFalse(info.isFocusable)
                        assertFalse(actual.accessibilityNodeProvider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                        assertFalse(actual.accessibilityNodeProvider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    } finally { info.recycle() }
                    val expected = TextPaint().apply { textSize = 16f; typeface = android.graphics.Typeface.MONOSPACE }.measureText("e") + 2f
                    assertEquals(expected, node.bounds.single().width(), .05f)
                    assertNull(owner.background); assertNull(owner.inlineBoxGroup!!.spans.single().background)
                }
                val actual = view(firstThai)
                originalCharacters = checkNotNull(actual.currentMeasuredGeometry).characterRects(0, actual.logicalText.length)
                    .map { rectangle -> rectangle?.let { android.graphics.RectF(it) } }
                assertTrue(original.entry.textDetails.any { it.kind == TextDetailKind.Advisory && it.label == "e" && it.description == title })
            }
            val firstCapture = captureCell()
            val originalRasterSize = firstCapture.bitmap.width to firstCapture.bitmap.height
            try { originalGlyphs = glyphMask(firstCapture.bitmap); assertTrue(originalGlyphs.isNotEmpty()) }
            finally { firstCapture.bitmap.recycle() }
            // The actual Compose cell paints the label; its AndroidView owns interaction only.
            // A white gap between dots still lies inside the real outer curved hit.
            lateinit var gapPoint: Pair<Float, Float>
            val gapCapture = captureCell()
            try { compose.runOnIdle {
                val actual = view(firstThai); val geometry = checkNotNull(actual.currentMeasuredGeometry)
                val node = geometry.nodes.single { it.advisoryIdentity?.span === original.first }
                val box = node.bounds.single()
                val bitmap = gapCapture.bitmap
                val matrix = android.graphics.Matrix(); actual.transformMatrixToGlobal(matrix)
                val inverse = android.graphics.Matrix(); assertTrue(matrix.invert(inverse))
                val rx = box.width() / 2f; val ry = box.height() / 2f
                assertTrue(rx > 1f && ry > 1f)
                var found: Pair<Float, Float>? = null
                for (py in 0 until bitmap.height) for (px in 0 until bitmap.width) {
                    val screenX = gapCapture.left + px + .5f; val screenY = gapCapture.top + py + .5f
                    val point = floatArrayOf(screenX, screenY); inverse.mapPoints(point)
                    val x = point[0] - actual.paddingLeft; val y = point[1] - actual.paddingTop
                    val dx = x - box.centerX(); val dy = y - box.centerY()
                    val inner = dx * dx / ((rx - 1f) * (rx - 1f)) + dy * dy / ((ry - 1f) * (ry - 1f))
                    if (found == null && inner > 1f && node.contains(x, y) && bitmap.getPixel(px, py) == android.graphics.Color.WHITE)
                        found = screenX to screenY
                }
                gapPoint = checkNotNull(found) { "The dotted border must retain a background-colored gap inside its curved hit" }
            } } finally { gapCapture.bitmap.recycle() }
            inject(android.view.MotionEvent.ACTION_HOVER_ENTER, gapPoint)
            inject(android.view.MotionEvent.ACTION_HOVER_MOVE, gapPoint)
            awaitPopup(title, true)
            inject(android.view.MotionEvent.ACTION_HOVER_EXIT, gapPoint)
            awaitPopup(title, false)
            val mousePoint = hover(firstThai, original.first)
            compose.runOnIdle { assertEquals(title, view(firstThai).tooltipText.toString()) }
            awaitPopup(title, true) // A real separate toolkit window, not merely a View property.
            var samePopup: android.widget.TextView? = null
            compose.runOnIdle { samePopup = popup(title) }
            inject(android.view.MotionEvent.ACTION_HOVER_MOVE, mousePoint)
            compose.runOnIdle { assertSame(samePopup, popup(title)) }
            hover(firstThai, original.first, corner = true)
            compose.runOnIdle { assertNull(view(firstThai).tooltipText) }
            awaitPopup(title, false)
            hover(secondThai, original.second, android.view.MotionEvent.TOOL_TYPE_STYLUS)
            awaitPopup(title, true)
            inject(android.view.MotionEvent.ACTION_HOVER_EXIT, checkNotNull(lastScreen), lastTool)
            awaitPopup(title, false)

            val square = fixture(badge(rounded = false), badge(rounded = false))
            change(square)
            compose.runOnIdle {
                val actual = view(firstThai)
                assertEquals(originalCharacters, checkNotNull(actual.currentMeasuredGeometry).characterRects(0, actual.logicalText.length))
            }
            val squareCapture = captureCell()
            try {
                assertEquals(originalRasterSize, squareCapture.bitmap.width to squareCapture.bitmap.height)
                assertEquals(originalGlyphs, glyphMask(squareCapture.bitmap)) // The actual glyph paint is not radius-clipped.
            } finally { squareCapture.bitmap.recycle() }
            change(original)
            hover(firstThai, original.first)
            awaitPopup(title, true)
            val replaced = fixture(badge(replacementTitle), original.second)
            change(replaced)
            awaitPopup(title, false)
            hover(firstThai, replaced.first)
            awaitPopup(replacementTitle, true)
            compose.runOnIdle { view(firstThai).isEnabled = false }
            awaitPopup(replacementTitle, false)
            compose.runOnIdle { assertNull(view(firstThai).tooltipText); view(firstThai).isEnabled = true }
            val empty = fixture(badge(""), original.second)
            change(empty)
            compose.runOnIdle {
                val actual = view(firstThai)
                assertTrue(checkNotNull(actual.currentMeasuredGeometry).nodes.none { it.kind == FloatInteractionKind.ADVISORY })
                assertNull(actual.tooltipText)
            }
            val absent = fixture(badge(null), original.second)
            change(absent)
            compose.runOnIdle { assertTrue(checkNotNull(view(firstThai).currentMeasuredGeometry).nodes.none { it.kind == FloatInteractionKind.ADVISORY }) }
            val childEmpty = fixture(badge(childTitle = ""), original.second)
            change(childEmpty)
            compose.runOnIdle {
                val actual = view(firstThai); val geometry = checkNotNull(actual.currentMeasuredGeometry)
                val node = geometry.nodes.single { it.advisoryIdentity?.span === childEmpty.first }
                val glyph = checkNotNull(geometry.characterRects(node.start, 1).single())
                assertFalse(node.contains(glyph.centerX(), glyph.centerY()))
                assertEquals(title, node.tooltip) // Parent border retains its own title.
            }
            val narrow = fixture(original.first, original.second, width = 190, density = 1.25f, zoom = 1.25f)
            change(narrow)
            compose.runOnIdle {
                val geometry = checkNotNull(view(firstThai).currentMeasuredGeometry)
                val node = geometry.nodes.single { it.advisoryIdentity?.span === original.first }
                val expected = TextPaint().apply { textSize = 16f * 1.25f * 1.25f; typeface = android.graphics.Typeface.MONOSPACE }.measureText("e") + 2f * 1.25f
                assertEquals(expected, node.bounds.single().width(), .05f)
                assertEquals(firstThai + "\ne" + firstTail, geometry.text.toString())
            }
            change(original)
            compose.onNodeWithTag("entry-abbreviations").performTouchInput { click() }
            val details = original.entry.textDetails.filter { it.kind == TextDetailKind.Advisory && it.description == title }
            assertEquals(2, details.size); assertEquals(2, details.map { it.context }.distinct().size)
            val entryScroll = compose.onNodeWithTag("entry-scroll")
            details.forEach { detail ->
                entryScroll.performScrollToNode(androidx.compose.ui.test.hasText(detail.context))
                compose.onNodeWithText(detail.context).assertIsDisplayed()
                compose.onNode(androidx.compose.ui.test.hasText(title) and
                    androidx.compose.ui.test.hasAnySibling(androidx.compose.ui.test.hasText(detail.context))).assertIsDisplayed()
            }
            entryScroll.performScrollToNode(androidx.compose.ui.test.hasTestTag("entry-abbreviations"))
            compose.onNodeWithTag("entry-abbreviations").performTouchInput { click() }
            awaitFixture()
            compose.runOnIdle {
                assertTrue(callbacks.isEmpty())
                val actual = view(firstThai); val text = actual.logicalText.toString()
                actual.setSelection(0, text.length)
                assertTrue(actual.performAccessibilityAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_COPY, null))
                val clipboard = actual.context.getSystemService(android.content.ClipboardManager::class.java)
                assertEquals(text, clipboard.primaryClip!!.getItemAt(0).text.toString())
                assertSame(reference, original.entry.sections.single().blocks.last().spans.single())
            }
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try {
                var owned = false
                compose.runOnIdle { owned = compose.activityRule.activity().hasWindowFocus() }
                if (owned) lastScreen?.let { inject(android.view.MotionEvent.ACTION_HOVER_EXIT, it, lastTool, checkFixture = false) }
            } catch (cleanup: Throwable) {
                val earlier = primary
                if (earlier == null) throw cleanup else if (earlier !== cleanup) earlier.addSuppressed(cleanup)
            }
        }
    }

    @Test fun autoInlineBoxUsesFullContainingWidthAndRealInnerLinesWithoutLosingSourceCustody() = control {
        // Controlled complete font snapshots: 12sp is the original body basis,
        // .9 is the surrounding text, and .81/1.13 are already-normalized owners.
        // The 22em maximum, .1em vertical padding and 1.2 line factor are source-shaped;
        // no article's full font chain or rendered page is claimed by this fixture.
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val padding = StyleEdges(StyleLength(StyleLengthUnit.Em, .1f), zero,
            StyleLength(StyleLengthUnit.Em, .1f), zero)
        val noBorder = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val normalized = InlineTextStyle(fontNormalized = true)
        data class Source(val spans: List<Span>, val owner: Span?, val child: Span?, val prefix: Span?,
            val following: Span, val scale: Float, val intrinsic: InlineBoxIntrinsicWrap,
            val factor: Float?, val rtl: Boolean)
        fun source(intrinsic: InlineBoxIntrinsicWrap = InlineBoxIntrinsicWrap.Anywhere,
            scale: Float = .81f, factor: Float? = 1.2f, rtl: Boolean = false,
            clustersOnly: Boolean = false): Source {
            val language = if (rtl) "he" else "hu"
            val direction = if (rtl) "rtl" else "ltr"
            val font = InlineFontSnapshot(fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
                fontNormalized = true, language = language)
            val body = when {
                clustersOnly -> "A\u0301A\u0301"
                rtl -> "\u05d0\u05b7\u05d1\u05d2\u05d3\u05d4\u05d5\u05d6\u05d7\u05d8\u05d9\u05db\u05dc\u05de\u05e0\u05e1\u05e2\u05e4\u05e6\u05e7\u05e8\u05e9\u05ea \u05d0\u05d1\u05d2 \u05d3\u05d4\u05d5 \u05d6\u05d7\u05d8 \u05d9\u05db\u05dc \u05de\u05e0\u05e1"
                else -> "A\u0301BCDEFGHIJKLMNOPQRSTUVWXYZ words follow after this tail"
            }
            val child = Span("text", body, fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody,
                language = language, direction = direction, inlineStyle = normalized)
            val layout = InlineBoxAtomicAutoLayout(StyleLength(StyleLengthUnit.Em, 22f), edges,
                ContainerBoxSizing.ContentBox, InlineBoxOverlayTextAlign.Start, TextWrap.BreakWord,
                intrinsic, factor?.let { InlineLineHeight.FontRelative(it, font) })
            val owner = child.copy(text = "", background = "#d0d0d0", inlineBoxGroup = InlineBoxGroup(
                padding, noBorder, spans = listOf(child), atomicAutoLayout = layout))
            val prefix = if (clustersOnly) null else Span("text", if (rtl) "\u05d0\u05d1\u05d2\u05d3\u05d4\u05d5\u05d6\u05d7\u05d8\u05d9 " else "MMMMMMMMMM ",
                fontScale = .9f, fontScaleBasis = FontScaleBasis.NormalBody, language = language,
                direction = direction, inlineStyle = normalized)
            val following = Span("link", if (rtl) " \u05d6" else " Z", target = "original-auto-neighbor",
                targetFragment = "kept-fragment", fontScale = .9f, fontScaleBasis = FontScaleBasis.NormalBody,
                language = language, direction = direction, inlineStyle = normalized, foreground = "#3366cc")
            return Source(listOfNotNull(prefix, owner, following), owner, child, prefix, following,
                scale, intrinsic, factor, rtl)
        }
        val anywhere = source()
        val normalMinimum = source(InlineBoxIntrinsicWrap.Normal)
        val normalHeight = source(factor = null)
        val largerOwner = source(scale = 1.13f)
        val rtl = source(rtl = true)
        val clusters = source(clustersOnly = true)
        val removed = anywhere.copy(spans = listOfNotNull(anywhere.prefix, anywhere.following), owner = null, child = null)
        data class Phase(val source: Source, val widthDp: Int, val density: Float = 1f,
            val zoom: Float = 1f, val gutter: Float = 0f)
        val phases = listOf(Phase(anywhere, 260), Phase(anywhere, 80), Phase(normalMinimum, 80),
            Phase(anywhere, 180, gutter = 12.25f), // Existing native indent: fitting lane != containing C.
            Phase(anywhere, 220, density = 1.25f), Phase(anywhere, 280, zoom = 1.2f),
            Phase(largerOwner, 300), Phase(normalHeight, 80), Phase(rtl, 260), Phase(rtl, 80),
            Phase(clusters, 6), Phase(removed, 260), Phase(anywhere, 260))
        val selected = mutableStateOf(0)
        val calls = mutableListOf<EntryLink>()
        val onLink: (EntryLink) -> Unit = { calls += it }
        val focusDestination = androidx.compose.ui.focus.FocusRequester()
        var prepared: PreparedNativeFloatText? = null
        var committed = -1
        var failure: String? = null
        val observe: (String) -> Unit = { failure = it }
        compose.activityRule.scenario.onActivity { activity -> activity.setContent {
            val index = selected.value
            val phase = phases[index]
            val density = Density(phase.density, phase.zoom)
            MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = TextStyle(
                fontSize = 12.sp, fontFamily = FontFamily.Monospace, letterSpacing = 0.sp))) {
                CompositionLocalProvider(LocalDensity provides density,
                    LocalLayoutDirection provides if (phase.source.rtl) LayoutDirection.Rtl else LayoutDirection.Ltr,
                    LocalNativeFloatContextFailureObserver provides observe) {
                    val style = TextStyle(fontSize = 10.8.sp, fontFamily = FontFamily.Monospace,
                        letterSpacing = 0.sp, textDirection = if (phase.source.rtl) TextDirection.Rtl else TextDirection.Ltr)
                    val annotated = styledTextAnnotation(phase.source.spans, null, style, onLink)
                    val value = prepareNativeFloatText(phase.source.spans, annotated,
                        egyptianTextRuns(phase.source.spans), style, MaterialTheme.colorScheme.primary,
                        emptyList(), AppSettings(allowImages = false, allowAudio = false), "", onLink,
                        indentPixels = phase.gutter, nativeLineHeight = NativeLineHeightPolicy.Normal)
                    SideEffect { prepared = value; committed = index }
                    Box(Modifier.fillMaxSize().safeDrawingPadding().padding(8.dp).background(Color.White)
                        .testTag("auto-inline-control-root").focusRequester(focusDestination).focusable()) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                            Modifier.width(phase.widthDp.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            error("Auto inline box control has no delegated child")
                        }
                    }
                }
            }
        } }
        fun views(root: android.view.View): List<NativeFloatTextView> = buildList {
            if (root is NativeFloatTextView) add(root)
            if (root is android.view.ViewGroup) repeat(root.childCount) { addAll(views(root.getChildAt(it))) }
        }
        fun sameRect(a: android.graphics.RectF, b: android.graphics.RectF) {
            assertEquals(a.left, b.left, .02f); assertEquals(a.top, b.top, .02f)
            assertEquals(a.right, b.right, .02f); assertEquals(a.bottom, b.bottom, .02f)
        }
        var initialBorder: android.graphics.RectF? = null
        var initialHeight = 0
        var initialView: NativeFloatTextView? = null
        var narrowAnywhereWidth = 0f
        for (index in phases.indices) {
            compose.runOnIdle { failure = null; selected.value = index }
            compose.waitForIdle()
            var movedFocus = false
            compose.runOnIdle {
                val view = views(compose.activity.window.decorView).single()
                if (view.hasFocus()) {
                    assertTrue(focusDestination.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter))
                    movedFocus = true
                }
            }
            if (movedFocus) compose.onNodeWithTag("auto-inline-control-root").assertIsFocused()
            var overflowInScreen: android.graphics.RectF? = null
            compose.runOnIdle {
                assertEquals(index, committed); assertNull(failure)
                val phase = phases[index]
                val fixture = phase.source
                val expected = fixture.prefix?.text.orEmpty() + fixture.child?.text.orEmpty() + fixture.following.text
                val value = checkNotNull(prepared)
                assertNull(value.stateDescription)
                val view = views(compose.activity.window.decorView).single()
                if (initialView == null) initialView = view else assertSame(initialView, view)
                val actual = checkNotNull(view.currentMeasuredGeometry)
                val surface = actual as NativeSurfaceGeometry
                val containing = with(Density(phase.density, phase.zoom)) { phase.widthDp.dp.roundToPx() }
                assertEquals(containing, surface.content.width)
                val raw = checkNotNull(value.geometryAtWidth).invoke(containing.toFloat(), emptyList(), false)
                assertEquals(expected, value.text.toString()); assertEquals(expected, raw.text.toString())
                assertEquals(expected, view.logicalText.toString()); assertFalse(expected.contains('\ufffc'))
                val action = actual.nodes.single()
                assertEquals(FloatInteractionKind.LINK, action.kind)
                assertEquals(expected.length - fixture.following.text.length, action.start)
                assertEquals(expected.length, action.end)
                assertEquals(fixture.following.text, action.label.toString())
                val native = checkNotNull(value.native)
                val child = fixture.child
                if (child != null) {
                    val source = native.source(containing)
                    val marker = source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).single()
                    val range = marker.projection.ranges.single { it.role == RubyTextRole.BoxGroup }
                    assertSame(fixture.owner, range.span)
                    assertSame(child, marker.projection.ranges.single { it.span === child }.span)
                    assertSame(fixture.following, marker.projection.ranges.single { it.span === fixture.following }.span)
                    val format = marker.groups.getValue(range.path)
                    val box = checkNotNull(format.box)
                    assertNotNull(box.atomicAutoLayout); assertNull(box.atomicLayout)
                    val fontPixels = 12f * phase.density * phase.zoom * fixture.scale
                    assertEquals(fontPixels, format.paint.textSize, .01f) // Complete owner, not parent .9 times owner.
                    val independent = TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        textSize = fontPixels; typeface = android.graphics.Typeface.MONOSPACE
                        textLocale = java.util.Locale.forLanguageTag(child.language)
                    }
                    val measured = android.graphics.text.MeasuredText.Builder(child.text.toCharArray()).setComputeLayout(true)
                        .appendStyleRun(independent, child.text.length, fixture.rtl).build()
                    val characters = android.icu.text.BreakIterator.getCharacterInstance(independent.textLocale).apply { setText(child.text) }
                    val boundaries = buildList {
                        var next = characters.first()
                        while (next != android.icu.text.BreakIterator.DONE) { add(next); next = characters.next() }
                    }
                    assertFalse(1 in boundaries) // Initial letter + combining mark is one real typographic unit.
                    val preferred = measured.getWidth(0, child.text.length)
                    val minimum = if (fixture.intrinsic == InlineBoxIntrinsicWrap.Anywhere)
                        boundaries.zipWithNext().maxOf { (start, end) -> measured.getWidth(start, end) }
                    else Regex("[^ ]+").findAll(child.text).maxOf { measured.getWidth(it.range.first, it.range.last + 1) }
                    val expectedContent = minOf(22f * fontPixels, minOf(maxOf(minimum, containing.toFloat()), preferred))
                    val atom = raw.nativeRubyShapingSource.getSpans(0, raw.nativeRubyShapingSource.length,
                        NativeInlineAtomicBox::class.java).single()
                    val inner = atom.child.geometry as NativeFloatGeometry
                    val allocation = atom.allocation
                    assertEquals(child.text, inner.text.toString())
                    assertEquals(expectedContent, allocation.contentWidth, .02f)
                    assertEquals(expectedContent, atom.advance, .02f)
                    val rect = checkNotNull(raw.inlineBoxGroupRects(box.owner, range.start, range.end)).single()
                    assertEquals(expectedContent, rect.width(), .02f)
                    val breaker = android.graphics.text.LineBreaker.Builder()
                        .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                        .setHyphenationFrequency(android.graphics.text.LineBreaker.HYPHENATION_FREQUENCY_NONE).build()
                    val fitted = breaker.computeLineBreaks(measured,
                        android.graphics.text.LineBreaker.ParagraphConstraints().apply { setWidth(expectedContent) }, 0)
                    val ends = List(fitted.lineCount) { fitted.getLineBreakOffset(it) }
                    assertEquals(ends.size, inner.shapedLineCount)
                    assertTrue(ends.all { it in boundaries })
                    val fm = independent.fontMetrics
                    var innerHeight = 0f
                    var lineStart = 0
                    val baselines = ends.mapIndexed { line, end ->
                        val factor = fixture.factor
                        val top: Float
                        val bottom: Float
                        if (factor != null) {
                            val halfLeading = (factor * fontPixels - (fm.descent - fm.ascent)) / 2f
                            top = fm.ascent - halfLeading; bottom = fm.descent + halfLeading
                        } else {
                            // Normal retains the public shaper's actual fallback envelope.
                            // Primary-font half-leading is an authored-height oracle only.
                            val shaped = android.graphics.text.TextRunShaper.shapeTextRun(child.text,
                                lineStart, end - lineStart, 0, child.text.length, 0f, 0f, fixture.rtl, independent)
                            top = minOf(fitted.getLineAscent(line), shaped.ascent)
                            bottom = maxOf(fitted.getLineDescent(line), shaped.descent)
                        }
                        val baseline = innerHeight - top
                        innerHeight += bottom - top
                        lineStart = end
                        baseline
                    }
                    val firstBaseline = baselines.first()
                    val lastBaseline = baselines.last()
                    assertEquals(firstBaseline, checkNotNull(inner.textBaselines?.first), .02f)
                    assertEquals(lastBaseline, checkNotNull(inner.textBaselines?.last), .02f)
                    assertEquals(innerHeight, inner.textBottom, .02f)
                    assertEquals(innerHeight, allocation.contentHeight, .02f)
                    assertEquals(innerHeight + .2f * fontPixels, rect.height(), .02f)
                    assertEquals(rect.height(), atom.metrics.bottom - atom.metrics.top, .02f)
                    var start = 0
                    ends.forEachIndexed { line, end ->
                        assertEquals(start to end, inner.nativeRangeOfLine(line))
                        assertEquals(baselines[line], inner.baselineForOffset(start), .02f)
                        start = end
                    }
                    val outerBaseline = raw.baselineForOffset(range.end - 1)
                    assertEquals(outerBaseline - .1f * fontPixels - lastBaseline, rect.top, .02f)
                    if (index == 0 || index == phases.lastIndex) {
                        val prefixPaint = TextPaint(independent).apply { textSize = 12f * phase.density * phase.zoom * .9f }
                        val prefixWidth = prefixPaint.measureText(checkNotNull(fixture.prefix).text)
                        assertTrue(expectedContent + prefixWidth > containing)
                        assertTrue(expectedContent <= containing)
                        assertTrue("Atom must move intact instead of shrinking to the remaining first line",
                            raw.baselineForOffset(range.start - 2) < outerBaseline)
                        assertEquals(outerBaseline, raw.baselineForOffset(range.end + 1), .02f)
                        assertTrue(kotlin.math.abs(expectedContent - kotlin.math.round(expectedContent)) > .05f)
                    }
                    if (index == 1) narrowAnywhereWidth = expectedContent
                    if (fixture === normalMinimum) {
                        assertTrue(expectedContent > narrowAnywhereWidth)
                        assertTrue(rect.width() > containing)
                        assertTrue(actual.width > surface.content.width)
                    }
                    if (phase.gutter > 0f) {
                        assertEquals(containing.toFloat(), expectedContent, .02f)
                        assertTrue(expectedContent > containing - phase.gutter)
                        assertTrue(rect.right > containing)
                    }
                    if (fixture === clusters) {
                        assertEquals(listOf(2, 4), ends)
                        assertEquals(2, inner.shapedLineCount)
                    }
                    val rawChars = raw.characterRects(0, expected.length)
                    val actualChars = actual.characterRects(0, expected.length)
                    assertTrue(rawChars.all { it != null }); assertTrue(actualChars.all { it != null })
                    val dx = actualChars.first()!!.left - rawChars.first()!!.left
                    val dy = actualChars.first()!!.top - rawChars.first()!!.top
                    rawChars.zip(actualChars).forEach { (a, b) ->
                        sameRect(android.graphics.RectF(checkNotNull(a)).apply { offset(dx, dy) }, checkNotNull(b))
                    }
                    if (phase.gutter > 0f) {
                        val location = IntArray(2); view.getLocationOnScreen(location)
                        overflowInScreen = android.graphics.RectF(maxOf(rect.left, containing.toFloat() + .5f),
                            rect.top, rect.right, rect.bottom).apply {
                            offset(dx + location[0] + view.paddingLeft, dy + location[1] + view.paddingTop)
                        }
                    }
                    val up = NativeTextCaret(range.end, NativeTextAffinity.Upstream)
                    val down = NativeTextCaret(range.end, NativeTextAffinity.Downstream)
                    assertTrue(view.requestFocus())
                    view.setSelection(up, up); assertEquals(up, view.selectionExtentCaret)
                    if (index == 0) {
                        val upRect = actual.caretRect(up); val downRect = actual.caretRect(down)
                        assertTrue(kotlin.math.abs(upRect.left - downRect.left) > .1f || kotlin.math.abs(upRect.top - downRect.top) > .1f)
                        assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_DPAD_RIGHT,
                            android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_DPAD_RIGHT)))
                        assertEquals(down, view.selectionExtentCaret)
                        initialBorder = android.graphics.RectF(rect); initialHeight = actual.height
                    }
                    if (index == phases.lastIndex) {
                        sameRect(checkNotNull(initialBorder), rect); assertEquals(initialHeight, actual.height)
                    }
                } else assertTrue(raw.nativeRubyShapingSource.getSpans(0, raw.nativeRubyShapingSource.length,
                    NativeInlineAtomicBox::class.java).isEmpty())
                val provider = checkNotNull(view.accessibilityNodeProvider)
                val host = checkNotNull(provider.createAccessibilityNodeInfo(android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID))
                try { assertEquals(expected, host.text.toString()); assertEquals(1, host.childCount) }
                finally { host.recycle() }
                val info = checkNotNull(provider.createAccessibilityNodeInfo(action.id))
                try { assertEquals(fixture.following.text, info.text.toString()); assertTrue(info.isClickable) }
                finally { info.recycle() }
                view.setSelection(0, expected.length); assertEquals(expected, view.selectedTextForCopy())
                assertTrue(view.performAccessibilityAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                assertNull(view.selectedTextForCopy())
                assertTrue(view.requestFocus())
                assertTrue(provider.performAction(action.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                val before = calls.size
                assertTrue(view.onKeyDown(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                assertEquals(before + 1, calls.size)
                view.onKeyUp(android.view.KeyEvent.KEYCODE_ENTER,
                    android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                assertEquals(before + 1, calls.size); assertEquals(fixture.following.entryLink(), calls.last())
            }
            overflowInScreen?.let { screen ->
                // Native context owns painting; its interaction View is not the paint surface.
                val root = compose.onNodeWithTag("auto-inline-control-root")
                val node = root.fetchSemanticsNode()
                val rootView = (checkNotNull(node.root) as androidx.compose.ui.platform.ViewRootForTest).view
                val bitmap = root.captureToImage().asAndroidBitmap()
                try {
                    val location = IntArray(2); compose.runOnIdle { rootView.getLocationOnScreen(location) }
                    val bounds = node.boundsInRoot
                    screen.offset(-(location[0] + bounds.left.roundToInt()).toFloat(),
                        -(location[1] + bounds.top.roundToInt()).toFloat())
                    val left = kotlin.math.ceil(screen.left.toDouble()).toInt()
                    val top = kotlin.math.ceil(screen.top.toDouble()).toInt()
                    val right = kotlin.math.floor(screen.right.toDouble()).toInt()
                    val bottom = kotlin.math.floor(screen.bottom.toDouble()).toInt()
                    assertTrue(left >= 0 && top >= 0 && right <= bitmap.width && bottom <= bitmap.height)
                    var visibleBackground = 0
                    for (y in top until bottom) for (x in left until right)
                        if (bitmap.getPixel(x, y) == android.graphics.Color.rgb(208, 208, 208)) visibleBackground++
                    assertTrue("The actual overflow-visible atom must paint beyond its original containing allocation", visibleBackground >= 4)
                } finally { bitmap.recycle() }
            }
        }
        assertEquals(phases.size, calls.size)
    }

}
