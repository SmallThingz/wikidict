package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.ParagraphStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativePreparedRunMetricsDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun preparedSourceKeepsInheritedNumberAndExplicitChildLengthWithResolvedRunFonts() {
        val text = "Aa\nBb"
        val annotated = AnnotatedString(text,
            spanStyles = listOf(AnnotatedString.Range(SpanStyle(fontSize = 40.sp), 1, 2),
                AnnotatedString.Range(SpanStyle(fontSize = 30.sp), 4, 5)),
            paragraphStyles = listOf(AnnotatedString.Range(ParagraphStyle(lineHeight = 18.sp), 3, 5)))
        var prepared: PreparedNativeFloatText? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val value = prepareNativeFloatText(listOf(Span("text", text)), annotated, emptyList(),
                            TextStyle(fontSize = 20.sp, lineHeight = 99.sp, fontFamily = FontFamily.Monospace),
                            MaterialTheme.colorScheme.primary, emptyList(),
                            AppSettings(allowImages = false, allowAudio = false), "", {},
                            nativeLineHeight = NativeLineHeightPolicy.Multiplier(1.5f))
                        SideEffect { prepared = value }
                    }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                val native = checkNotNull(value.native)
                val source = native.source(300)
                val first = source.getSpans(0, 2, NativeRunLineMetrics::class.java)
                val second = source.getSpans(3, 5, NativeRunLineMetrics::class.java)
                assertTrue(first.isNotEmpty() && second.isNotEmpty())
                assertTrue(first.all { it.policy == NativeLineHeightPolicy.Multiplier(1.5f) })
                assertTrue(second.all { it.policy == NativeLineHeightPolicy.Pixels(18f) })
                assertEquals(setOf(20f, 40f), first.map { it.primary.fontSize }.toSet())
                assertEquals(setOf(20f, 30f), second.map { it.primary.fontSize }.toSet())
                assertEquals(1, first.count { it.strut }); assertEquals(1, second.count { it.strut })
                val geometry = checkNotNull(value.geometry).invoke(300, emptyList(), false)
                val firstBounds = first.map { it.primary.authored(it.policy)!! }.reduce { a, b -> a.including(b) }
                val secondBounds = second.map { it.primary.authored(it.policy)!! }.reduce { a, b -> a.including(b) }
                assertEquals(firstBounds.height + secondBounds.height, geometry.textBottom, 0.001f)
                assertEquals(-firstBounds.top, geometry.baselineForOffset(0), 0.001f)
                assertEquals(firstBounds.height - secondBounds.top, geometry.baselineForOffset(3), 0.001f)
                assertEquals(text, geometry.text.toString())
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun actualContainerOwnerStrutSurvivesEveryChildOverrideNestedResetAndZeroOwner() {
        val inherited = ContainerStyle(ownerFontScale = .9f, lineHeight = ContainerLineHeight.Multiplier(1.5f))
            .textContext(ContainerTextContext())
        val contexts = listOf(inherited, inherited, ContainerStyle(ownerFontScale = 1f).textContext(inherited),
            ContainerStyle(ownerFontScale = 0f).textContext(inherited),
            ContainerStyle(lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 1.35f)))
                .textContext(inherited))
        val childSizes = listOf(9f, 36f, 20f, 40f, 40f)
        val prepared = arrayOfNulls<PreparedNativeFloatText>(contexts.size)
        val actions = mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        contexts.forEachIndexed { index, owner ->
                            val format = nativeContainerTextFormat(owner, 20.sp,
                                TextStyle(fontSize = 99.sp, lineHeight = 99.sp, fontFamily = FontFamily.Monospace),
                                LocalDensity.current)
                            val annotated = androidx.compose.ui.text.buildAnnotatedString {
                                append("W")
                                addStyle(SpanStyle(fontSize = childSizes[index].sp), 0, 1)
                                addLink(androidx.compose.ui.text.LinkAnnotation.Clickable("owner-$index", linkInteractionListener = null), 0, 1)
                            }
                            val value = prepareNativeFloatText(listOf(Span("link", "W", "owner-$index")),
                                annotated, emptyList(), format.style, MaterialTheme.colorScheme.primary,
                                emptyList(), AppSettings(allowImages = false, allowAudio = false), "",
                                { actions += it }, nativeLineHeight = format.lineHeight)
                            SideEffect { prepared[index] = value }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                contexts.forEachIndexed { index, owner ->
                    val value = checkNotNull(prepared[index])
                    val native = checkNotNull(value.native)
                    val source = native.source(200)
                    val runs = source.getSpans(0, source.length, NativeRunLineMetrics::class.java)
                    val strut = runs.single { it.strut }
                    assertEquals(20f * owner.ownerFontScale, native.paint.textSize, .001f)
                    assertEquals(native.paint.textSize, strut.primary.fontSize, .001f)
                    assertEquals(childSizes[index], runs.single { !it.strut }.primary.fontSize, .001f)
                    val policy = if (index == 4) NativeLineHeightPolicy.Pixels(27f)
                        else NativeLineHeightPolicy.Multiplier(1.5f)
                    assertTrue(runs.all { it.policy == policy })
                    // Independent primary-font half-leading oracle for the real prepared strut and run.
                    val boxes = runs.map { run ->
                        val metrics = run.primary
                        val height = if (index == 4) 27f else metrics.fontSize * 1.5f
                        val leading = (height - (metrics.descent - metrics.ascent)) / 2f
                        (metrics.ascent - leading + metrics.baselineShift) to
                            (metrics.descent + leading + metrics.baselineShift)
                    }
                    val top = boxes.minOf { it.first }; val bottom = boxes.maxOf { it.second }
                    val geometry = checkNotNull(value.geometry).invoke(200, emptyList(), false)
                    assertEquals(bottom - top, geometry.textBottom, .001f)
                    assertEquals(-top, geometry.baselineForOffset(0), .001f)
                    if (index == 0) assertEquals(27f, geometry.textBottom, .001f)
                    if (index == 3) assertTrue("Zero owner must retain the positive child", geometry.textBottom > 0f)
                    assertEquals("W", geometry.text.toString())
                    assertTrue(geometry.rectsForRange(0, 1).any { it.width() > 0f && it.height() > 0f })
                    val bitmap = android.graphics.Bitmap.createBitmap(256, 180, android.graphics.Bitmap.Config.ARGB_8888)
                    try {
                        val canvas = android.graphics.Canvas(bitmap); canvas.translate(24f, 48f); geometry.paint(canvas)
                        val pixels = IntArray(256 * 180); bitmap.getPixels(pixels, 0, 256, 0, 0, 256, 180)
                        assertTrue("Actual owner/child glyph paint must survive", pixels.count { android.graphics.Color.alpha(it) != 0 } > 10)
                    } finally { bitmap.recycle() }
                    geometry.nodes.single { it.onClick != null }.onClick!!()
                    assertEquals("owner-$index", actions.last().target)
                }
                assertEquals(contexts.indices.map { "owner-$it" }, actions.map { it.target })
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun completeContainerFontKeepsIndependentNormalStrutAndOriginalChildFonts() {
        // Synthetic W owners; these scalars are not a claim about a producer's Mai output.
        val owner = InlineFontSnapshot(fontScale = 1.8f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, bold = true, italic = true, small = true,
            fontFamily = ContainerFontFamily.SansSerif)
        val root = ContainerStyle(ownerFont = owner, lineHeight = ContainerLineHeight.Normal)
            .textContext(ContainerTextContext())
        val scriptOwner = owner.copy(superscript = true)
        val cssOwner = owner.copy(fontScale = 18f, fontScaleBasis = FontScaleBasis.CssPx)
        val replacement = owner.copy(fontScale = .6f, bold = false, italic = false, small = false)
        val contexts = listOf(root,
            ContainerStyle(ownerFont = scriptOwner).textContext(ContainerTextContext()),
            ContainerStyle(ownerFontScale = .75f).textContext(root),
            ContainerStyle(ownerFont = cssOwner).textContext(root),
            ContainerStyle(ownerFont = owner.copy(fontScale = 0f)).textContext(root),
            ContainerStyle(ownerFontScale = 1.1f).textContext(ContainerStyle(ownerFont = cssOwner).textContext(root)),
            ContainerStyle(ownerFont = replacement).textContext(root))
        val child = Span("link", "M", target = "w-child", foreground = "#0000ff",
            fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody)
        val cssChild = Span("text", "x", foreground = "#008000", fontScale = 14f,
            fontScaleBasis = FontScaleBasis.CssPx)
        val scriptChild = Span("text", "2", foreground = "#ff0000", fontScale = 1f,
            fontScaleBasis = FontScaleBasis.NormalBody, superscript = true)
        val spans = listOf(child, cssChild, scriptChild)
        val contextualChild = Span("text", "n", foreground = "#000000")
        val actions = mutableListOf<EntryLink>()
        val prepared = arrayOfNulls<PreparedNativeFloatText>(contexts.size)
        val contextualPrepared = arrayOfNulls<PreparedNativeFloatText>(contexts.size)
        val resolved = arrayOfNulls<ContainerTextContext>(contexts.size)
        val formats = arrayOfNulls<NativeContainerTextFormat>(contexts.size)
        try {
            for ((density, cssZoom) in listOf(Density(1f, 1f) to 1f, Density(1.25f, 1.4f) to 1.6f)) {
                compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                    MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge =
                        TextStyle(fontSize = 20.sp, fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp))) {
                        CompositionLocalProvider(LocalDensity provides density, LocalCssPixelTextZoom provides cssZoom) {
                            contexts.forEachIndexed { index, raw ->
                                val inherited = TextStyle(fontSize = 99.sp, fontFamily = FontFamily.Monospace,
                                    letterSpacing = 0.sp)
                                val context = nativeContainerOwnerTextContext(raw, inherited, LocalDensity.current).getOrThrow()
                                val format = nativeContainerTextFormat(context, 20.sp, inherited, LocalDensity.current)
                                CompositionLocalProvider(LocalNativeContainerTextContext provides context) {
                                    val annotated = styledTextAnnotation(spans, null, format.style) { actions += it }
                                    val value = prepareNativeFloatText(spans, annotated, emptyList(), format.style,
                                        MaterialTheme.colorScheme.primary, emptyList(),
                                        AppSettings(allowImages = false, allowAudio = false), "", { actions += it },
                                        nativeLineHeight = format.lineHeight, sourceFamily = format.sourceFamily,
                                        ownerFont = format.ownerFont)
                                    val defaults = listOf(contextualChild)
                                    val defaultAnnotation = styledTextAnnotation(defaults, null, format.style) { actions += it }
                                    val defaultValue = prepareNativeFloatText(defaults, defaultAnnotation, emptyList(), format.style,
                                        MaterialTheme.colorScheme.primary, emptyList(),
                                        AppSettings(allowImages = false, allowAudio = false), "", { actions += it },
                                        nativeLineHeight = format.lineHeight, sourceFamily = format.sourceFamily,
                                        ownerFont = format.ownerFont)
                                    SideEffect {
                                        prepared[index] = value; contextualPrepared[index] = defaultValue
                                        resolved[index] = context; formats[index] = format
                                    }
                                }
                            }
                        }
                    }
                } }
                compose.waitForIdle()
                compose.runOnIdle {
                    val bodyPixels = with(density) { 20.sp.toPx() }
                    val expectedOwnerPixels = listOf(bodyPixels * 1.8f, bodyPixels * 1.8f,
                        bodyPixels * .75f, with(density) { (18f * cssZoom).sp.toPx() }, 0f,
                        bodyPixels * 1.1f, bodyPixels * .6f)
                    val geometries = mutableListOf<NativeFloatGeometry>()
                    contexts.forEachIndexed { index, raw ->
                        val value = checkNotNull(prepared[index])
                        val context = checkNotNull(resolved[index])
                        val format = checkNotNull(formats[index])
                        assertSame(checkNotNull(raw.containerText).snapshot, checkNotNull(context.containerText).snapshot)
                        assertSame(checkNotNull(context.containerText).resolved, format.ownerFont)
                        val native = checkNotNull(value.native)
                        val source = native.source(500)
                        assertEquals("Mx2", source.toString()); assertEquals("Mx2", value.text.toString())
                        val runs = source.getSpans(0, source.length, NativeRunLineMetrics::class.java)
                        val strut = runs.single { it.strut }
                        assertEquals(NativeLineHeightPolicy.Normal, strut.policy)
                        assertTrue(strut.includePrimaryInNormal)
                        assertEquals(expectedOwnerPixels[index], native.paint.textSize, .001f)
                        assertEquals(expectedOwnerPixels[index], strut.primary.fontSize, .001f)
                        assertEquals(0f, strut.primary.baselineShift, 0f)
                        assertEquals(0, native.paint.baselineShift)
                        val defaultNative = checkNotNull(checkNotNull(contextualPrepared[index]).native)
                        val defaultSource = defaultNative.source(500)
                        assertEquals("n", defaultSource.toString())
                        val defaultPaint = android.text.TextPaint(defaultNative.paint)
                        defaultSource.getSpans(0, 1, android.text.style.MetricAffectingSpan::class.java)
                            .forEach { it.updateDrawState(defaultPaint) }
                        assertEquals(expectedOwnerPixels[index], defaultPaint.textSize, .001f)
                        assertFalse(defaultPaint.typeface.isBold); assertFalse(defaultPaint.typeface.isItalic)
                        assertEquals(0, defaultPaint.baselineShift)
                        assertEquals(android.graphics.Typeface.create(android.graphics.Typeface.SANS_SERIF,
                            android.graphics.Typeface.NORMAL), defaultPaint.typeface)
                        assertNull(contextualChild.fontScale); assertNull(contextualChild.fontFamily)
                        assertFalse(contextualChild.bold || contextualChild.italic || contextualChild.superscript)
                        val wantedFace = android.graphics.Typeface.create(android.graphics.Typeface.SANS_SERIF,
                            if (index == 6) android.graphics.Typeface.NORMAL else android.graphics.Typeface.BOLD_ITALIC)
                        val ownerProbe = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                            typeface = wantedFace; textSize = expectedOwnerPixels[index]
                        }
                        assertEquals(ownerProbe.fontMetrics.ascent, strut.primary.ascent, .001f)
                        assertEquals(ownerProbe.fontMetrics.descent, strut.primary.descent, .001f)
                        fun childPaint(offset: Int) = android.text.TextPaint(native.paint).also { paint ->
                            source.getSpans(offset, offset + 1, android.text.style.MetricAffectingSpan::class.java)
                                .filter { source.getSpanStart(it) <= offset && source.getSpanEnd(it) > offset }
                                .forEach { it.updateDrawState(paint) }
                        }
                        val plain = childPaint(0); val css = childPaint(1); val sup = childPaint(2)
                        assertEquals(bodyPixels * .5f, plain.textSize, .001f)
                        assertEquals(with(density) { (14f * cssZoom).sp.toPx() }, css.textSize, .001f)
                        assertEquals(bodyPixels * .8f, sup.textSize, .001f)
                        assertFalse(plain.typeface.isBold); assertFalse(plain.typeface.isItalic)
                        assertEquals(0, plain.baselineShift)
                        assertEquals(android.graphics.Color.BLUE, plain.color)
                        assertEquals(kotlin.math.ceil(sup.ascent() * .5f).toInt(), sup.baselineShift)
                        assertTrue(sup.baselineShift < 0)
                        val geometry = checkNotNull(value.geometry).invoke(500, emptyList(), false)
                        geometries += geometry
                        // Android supplies the real fallback envelope; the independent owner adds
                        // its actual primary font even though every painted child overrides size.
                        val natural = android.text.StaticLayout.Builder.obtain(source, 0, source.length,
                            android.text.TextPaint(native.paint), 500).setTextDirection(native.direction)
                            .setIncludePad(true).setUseLineSpacingFromFallbacks(true).setLineSpacing(0f, 1f)
                            .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                            .setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE).build()
                        assertEquals(1, natural.lineCount); assertEquals(1, geometry.shapedLineCount)
                        val baseline = natural.getLineBaseline(0)
                        val top = minOf((natural.getLineTop(0) - baseline).toFloat(), ownerProbe.ascent())
                        val bottom = maxOf((natural.getLineBottom(0) - baseline).toFloat(), ownerProbe.descent())
                        assertEquals(-top, geometry.baselineForOffset(0), .001f)
                        assertEquals(bottom - top, geometry.usedLineHeight(0), .001f)
                        assertEquals(bottom - top, geometry.textBottom, .001f)
                        assertEquals("Mx2", geometry.text.toString())
                        assertEquals(3, geometry.characterRects(0, 3).count { it != null })
                        val node = geometry.nodes.single { it.onClick != null }
                        assertEquals(0, node.start); assertEquals(1, node.end)
                        assertTrue(node.bounds.any { it.width() > 0f && it.height() > 0f })
                        node.onClick!!(); assertEquals("w-child", actions.last().target)
                        val bitmap = android.graphics.Bitmap.createBitmap(640, 240, android.graphics.Bitmap.Config.ARGB_8888)
                        try {
                            val canvas = android.graphics.Canvas(bitmap); canvas.translate(24f, 48f); geometry.paint(canvas)
                            val pixels = IntArray(640 * 240); bitmap.getPixels(pixels, 0, 640, 0, 0, 640, 240)
                            assertTrue("Positive child paint survives the independent or zero owner",
                                pixels.count { android.graphics.Color.alpha(it) != 0 } > 10)
                        } finally { bitmap.recycle() }
                    }
                    // Normalized owner SUP changes no placement. The actual child SUP remains shifted.
                    assertEquals(geometries[0].textBottom, geometries[1].textBottom, 0f)
                    assertEquals(geometries[0].baselineForOffset(0), geometries[1].baselineForOffset(0), 0f)
                    assertEquals(geometries[0].characterRects(0, 3), geometries[1].characterRects(0, 3))
                    assertTrue(geometries[4].textBottom > 0f)
                    assertSame(child, spans[0]); assertSame(cssChild, spans[1]); assertSame(scriptChild, spans[2])
                    assertFalse(child.bold || child.italic || child.small || child.code || child.superscript || child.subscript)
                    assertNull(child.fontFamily); assertEquals(FontScaleBasis.NormalBody, child.fontScaleBasis)
                    assertSame(owner, checkNotNull(root.containerText).snapshot)
                }
            }
            assertEquals(contexts.size * 2, actions.size)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun actualContainerFontAdapterDistinguishesEmptyTreeRetainedEmptyAndBreak() {
        val snapshot = InlineFontSnapshot(fontScale = 1.8f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, bold = true, superscript = true, fontFamily = ContainerFontFamily.SansSerif)
        val owner = ContainerStyle(ownerFont = snapshot, lineHeight = ContainerLineHeight.Multiplier(1.5f))
        val emptyMetric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx))))
        val br = Span("line_break", "")
        val body = Span("link", "Body", target = "w-body", foreground = "#0000ff",
            fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody)
        fun box(children: List<Block>, style: ContainerStyle = owner) =
            Block("container", 0, emptyList(), container = Container(children, style))
        val cases = listOf(box(emptyList()), box(listOf(box(emptyList(), ContainerStyle()))),
            box(listOf(Block("paragraph", 0, listOf(emptyMetric)))),
            box(listOf(Block("paragraph", 0, listOf(br)))),
            box(listOf(Block("paragraph", 0, listOf(body)))))
        val selected = mutableStateOf(0)
        val actions = mutableListOf<EntryLink>()
        val failures = mutableListOf<String>()
        var geometry: NativeFloatContextGeometry? = null
        var measuredHeight = -1
        val declaringProbe = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            typeface = android.graphics.Typeface.create(android.graphics.Typeface.SANS_SERIF, android.graphics.Typeface.BOLD)
            textSize = 36f
        }
        fun halfLeading(paint: android.text.TextPaint, height: Float): Pair<Float, Float> {
            val fm = paint.fontMetrics
            val leading = (height - (fm.descent - fm.ascent)) / 2f
            return (fm.ascent - leading) to (fm.descent + leading)
        }
        val declaringBand = halfLeading(declaringProbe, 36f * 1.5f)
        fun expectedBand(index: Int): Pair<Float, Float> {
            val childProbe = android.text.TextPaint(declaringProbe).apply {
                typeface = android.graphics.Typeface.SANS_SERIF
                textSize = if (index == 4) 10f else 36f
            }
            val childBand = halfLeading(childProbe, if (index == 2) 0f else childProbe.textSize * 1.5f)
            return minOf(declaringBand.first, childBand.first) to maxOf(declaringBand.second, childBand.second)
        }
        // The real LF supplies Android's ordinary trailing native row. Font ownership itself supplies no row.
        val brLines = android.text.StaticLayout.Builder.obtain("\n", 0, 1, declaringProbe, 240)
            .setIncludePad(true).build().lineCount
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge =
                    TextStyle(fontSize = 20.sp, fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp))) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                        LocalNativeFloatContextFailureObserver provides { failures += it }) {
                        val parent = remember { NativeLayoutInput(Unit) }
                        val input = remember { NativeContextMeasureInput(invalidateParent = parent::invalidate) }
                        val density = LocalDensity.current
                        val environment = NativeFlowEnvironment(density.density, density.fontScale,
                            LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
                        val preparation = Any()
                        Layout(modifier = Modifier.then(parent.modifier), content = {
                            CompositionLocalProvider(LocalNativeContextMeasureInput provides input) {
                                NativeFloatBlockContext(listOf(cases[selected.value]), { actions += it }, "w-empty",
                                    Modifier, inCell = false, gridPath = "w-empty", gapDp = 0f, trailingGap = false)
                            }
                        }) { children, constraints ->
                            val childConstraints = Constraints(maxWidth = 240, maxHeight = 300)
                            val request = input.request(constraints, childConstraints, environment,
                                NativeFlowParentPolicy(preparation, true, null, 0f), emptyList())
                            val child = children.single().measure(childConstraints)
                            geometry = input.ready(request); measuredHeight = child.height
                            layout(constraints.constrainWidth(240), constraints.constrainHeight(300)) { child.place(0, 0) }
                        }
                    }
                }
            } }
            for (index in cases.indices + listOf(0, 4)) {
                compose.runOnIdle {
                    if (selected.value != index) {
                        geometry = null; measuredHeight = -1; selected.value = index
                    }
                }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertTrue(failures.toString(), failures.isEmpty())
                    val current = checkNotNull(geometry)
                    if (index >= 2) {
                        val band = expectedBand(index)
                        val count = if (index == 3) brLines else 1
                        val expectedHeight = (band.second - band.first) * count
                        assertEquals(expectedHeight, current.usedHeight, .001f)
                        assertEquals(kotlin.math.ceil(expectedHeight).toInt(), measuredHeight)
                        val baselines = checkNotNull(current.textBaselines)
                        assertEquals(-band.first, checkNotNull(baselines.first), .001f)
                        assertEquals((count - 1) * (band.second - band.first) - band.first,
                            checkNotNull(baselines.last), .001f)
                        assertTrue("The 36px owner must dominate the ordinary 20px fallback", expectedHeight >= 54f)
                    }
                    when (index) {
                        0, 1 -> {
                            assertEquals("", current.text.toString()); assertTrue(current.nodes.isEmpty())
                            assertEquals(0f, current.usedHeight, 0f); assertEquals(0, measuredHeight)
                            assertNull(current.textBaselines)
                            assertTrue(current.characterRects(0, 0).isEmpty())
                        }
                        2 -> {
                            assertEquals("", current.text.toString()); assertTrue(current.nodes.isEmpty())
                            assertTrue(current.usedHeight > 0f); assertTrue(measuredHeight > 0)
                            val lines = checkNotNull(current.textBaselines)
                            assertNotNull(lines.first); assertEquals(lines.first, lines.last)
                            assertTrue(current.characterRects(0, 0).isEmpty())
                            assertSame(emptyMetric, cases[2].container!!.blocks.single().spans.single())
                        }
                        3 -> {
                            assertEquals("\n", current.text.toString()); assertTrue(current.nodes.isEmpty())
                            assertTrue(current.usedHeight > 0f); assertTrue(measuredHeight > 0)
                            assertNotNull(current.textBaselines)
                            assertSame(br, cases[3].container!!.blocks.single().spans.single())
                        }
                        4 -> {
                            assertEquals("Body", current.text.toString())
                            assertTrue(current.usedHeight > 0f)
                            assertEquals(4, current.characterRects(0, 4).count { it != null })
                            val node = current.nodes.single { it.onClick != null }
                            assertEquals(0, node.start); assertEquals(4, node.end)
                            node.onClick!!(); assertEquals("w-body", actions.last().target)
                            assertSame(body, cases[4].container!!.blocks.single().spans.single())
                        }
                    }
                    assertSame(snapshot, cases[index].container!!.style.ownerFont)
                }
            }
            assertEquals(listOf("w-body", "w-body"), actions.map { it.target })
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun bodyTypographyKeepsRootAddressesHeadingDefaultsAndSourceOwnedStruts() {
        val owner = InlineFontSnapshot(fontScale = 1.8f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, bold = true, italic = true, fontFamily = ContainerFontFamily.SansSerif)
        val body = Span("link", "Body", target = "body-owner", foreground = "#0000ff",
            fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody)
        val heading = Span("text", "Heading")
        val tail = Span("text", "Tail", fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody)
        val blocks = listOf(Block("paragraph", 0, listOf(body)),
            Block("heading", 0, listOf(heading), level = 3), Block("paragraph", 0, listOf(tail)))
        val paths = listOf("body/root/0", "body/root/1", "body/root/2")
        val gaps = listOf(6f, 2f, 6f)
        val selected = mutableStateOf(false)
        val actions = mutableListOf<EntryLink>()
        var leaves = emptyList<NativeContainerLeaf>()
        var prepared = emptyList<PreparedNativeFloatText>()
        var emptyLeaves = -1
        var resolved: ContainerTextContext? = null
        val rootStyle = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
            fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp)
        val headingStyle = TextStyle(fontSize = 28.sp, lineHeight = 34.sp,
            fontFamily = FontFamily.Serif, letterSpacing = 0.sp)
        val declaring = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            typeface = android.graphics.Typeface.create(android.graphics.Typeface.SANS_SERIF,
                android.graphics.Typeface.BOLD_ITALIC)
            textSize = 36f
        }
        val childPaint = android.text.TextPaint(declaring).apply {
            typeface = android.graphics.Typeface.SANS_SERIF; textSize = 10f
        }
        fun independentBand(paint: android.text.TextPaint): Pair<Float, Float> {
            val metrics = paint.fontMetrics
            val leading = (paint.textSize * 1.5f - (metrics.descent - metrics.ascent)) / 2f
            return metrics.ascent - leading to metrics.descent + leading
        }
        val ownerBand = independentBand(declaring); val childBand = independentBand(childPaint)
        val bodyTop = minOf(ownerBand.first, childBand.first)
        val bodyBottom = maxOf(ownerBand.second, childBand.second)
        var headingBefore: Pair<Float, List<android.graphics.RectF?>>? = null
        var bodyBefore: Pair<Float, List<android.graphics.RectF?>>? = null
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = rootStyle,
                    titleMedium = headingStyle)) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val density = LocalDensity.current
                        val context = if (selected.value) nativeBodyTextContext(owner,
                            ContainerLineHeight.Multiplier(1.5f), null, 20.sp, rootStyle, density).getOrThrow()
                            else nativeRootTextContext(rootStyle, 20.sp, density)
                        val captured = mutableListOf<NativeContainerLeaf>()
                        val texts = mutableListOf<PreparedNativeFloatText>()
                        val ids = remember { linkedMapOf<String, Int>() }
                        prepareNativeContainerTree(blocks, "body", "body-grid", paths, gaps, context,
                            rootStyle, null, 20.sp, density, 240.0, rtl = false, dark = false,
                            fixedHeightReachable = false, id = { ids.getOrPut(it) { ids.size + 1 } }) { leaf ->
                            captured += leaf
                            val format = leaf.format
                            val style = if (leaf.block.kind == "heading") headingStyle else format?.style ?: rootStyle
                            CompositionLocalProvider(LocalNativeContainerTextContext provides leaf.context) {
                                val annotated = styledTextAnnotation(leaf.block.spans, null, style) { actions += it }
                                texts += prepareNativeFloatText(leaf.block.spans, annotated, emptyList(), style,
                                    MaterialTheme.colorScheme.primary, emptyList(),
                                    AppSettings(allowImages = false, allowAudio = false), "", { actions += it },
                                    heading = leaf.block.kind == "heading", nativeLineHeight = format?.lineHeight,
                                    sourceFamily = format?.sourceFamily, ownerFont = format?.ownerFont)
                            }
                            emptyList()
                        }
                        var emptyCount = 0
                        val emptyTree = prepareNativeContainerTree(emptyList(), "empty-body", "empty-grid",
                            emptyList(), emptyList(), context, rootStyle, null, 20.sp, density, 240.0,
                            rtl = false, dark = false, fixedHeightReachable = false,
                            id = { ids.getOrPut(it) { ids.size + 1 } }) { emptyCount++; emptyList() }
                        SideEffect {
                            leaves = captured.toList(); prepared = texts.toList(); emptyLeaves = emptyCount
                            resolved = context
                            check(emptyTree.isEmpty())
                        }
                    }
                }
            } }
            for (enabled in listOf(false, true, false)) {
                compose.runOnIdle { selected.value = enabled }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertEquals(3, leaves.size); assertEquals(3, prepared.size)
                    assertEquals(0, emptyLeaves)
                    leaves.forEachIndexed { index, leaf ->
                        assertSame(blocks[index], leaf.block)
                        assertEquals(paths[index], leaf.path); assertEquals(index, leaf.rootIndex)
                        assertEquals(gaps[index], leaf.gap, 0f); assertFalse(leaf.inContainer)
                        if (index == 0) assertNull(leaf.previous) else assertSame(blocks[index - 1], leaf.previous)
                    }
                    val headingLeaf = leaves[1]
                    assertNull(headingLeaf.format)
                    assertNull(headingLeaf.context)
                    assertEquals(enabled, headingLeaf.bodyTypographyExcluded)
                    val headGeometry = checkNotNull(prepared[1].geometry).invoke(240, emptyList(), false)
                    assertEquals("Heading", headGeometry.text.toString())
                    val headState = headGeometry.textBottom to headGeometry.characterRects(0, heading.text.length)
                    if (headingBefore == null) headingBefore = headState else assertEquals(headingBefore, headState)
                    val native = checkNotNull(prepared[0].native)
                    val source = native.source(240)
                    val runs = source.getSpans(0, source.length, NativeRunLineMetrics::class.java)
                    assertEquals(if (enabled) 36f else 20f, runs.single { it.strut }.primary.fontSize, .001f)
                    assertEquals(setOf(10f), runs.filter { !it.strut }.map { it.primary.fontSize }.toSet())
                    val geometry = checkNotNull(prepared[0].geometry).invoke(240, emptyList(), false)
                    assertEquals("Body", geometry.text.toString())
                    assertEquals(4, geometry.characterRects(0, 4).count { it != null })
                    if (enabled) {
                        assertSame(owner, checkNotNull(checkNotNull(resolved).containerText).snapshot)
                        assertEquals(bodyBottom - bodyTop, geometry.textBottom, .001f)
                        assertEquals(-bodyTop, geometry.baselineForOffset(0), .001f)
                        assertEquals(54f, geometry.textBottom, .001f)
                        assertTrue(runs.all { it.policy == NativeLineHeightPolicy.Multiplier(1.5f) })
                    } else {
                        assertNull(checkNotNull(resolved).containerText)
                        val state = geometry.textBottom to geometry.characterRects(0, 4)
                        if (bodyBefore == null) bodyBefore = state else assertEquals(bodyBefore, state)
                    }
                    val action = geometry.nodes.single { it.onClick != null }
                    assertEquals(0, action.start); assertEquals(4, action.end)
                    action.onClick!!(); assertEquals("body-owner", actions.last().target)
                    assertFalse(body.bold || body.italic || body.small || body.superscript || body.subscript)
                    assertEquals(.5f, body.fontScale); assertEquals(FontScaleBasis.NormalBody, body.fontScaleBasis)
                }
            }
            assertEquals(List(3) { "body-owner" }, actions.map { it.target })
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

    @Test fun excludedBodyKeepsNearestCellMetricsAndExplicitContainerAliases() {
        val snapshot = InlineFontSnapshot(fontScale = 1.8f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, bold = true, italic = true, fontFamily = ContainerFontFamily.SansSerif)
        val cellFont = InlineFontSnapshot(fontScale = .6f, fontScaleBasis = FontScaleBasis.NormalBody,
            language = "en", fontFamily = ContainerFontFamily.SansSerif, fontFeatures = FontFeaturePolicy.Normal)
        val child = Span("link", "M", target = "body-near-owner", foreground = "#0000ff",
            fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFamily = ContainerFontFamily.SansSerif)
        val plain = Cell(listOf(child), false, 1, 1)
        val fixed = CellLineHeightValue.Length(CellFixedLineHeight(40f, FontScaleBasis.CssPx))
        val heightOnly = plain.copy(style = CellStyle(lineHeight = CellLineHeight(fixed)))
        val fullCell = plain.copy(style = CellStyle(lineHeight = CellLineHeight(fixed,
            CellTextStrut(.6f, FontScaleBasis.NormalBody, cellFont))))
        val rootStyle = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
            fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp)
        val aliasFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)
        val contexts = arrayOfNulls<ContainerTextContext>(3)
        val prepared = arrayOfNulls<PreparedNativeFloatText>(3)
        val formats = arrayOfNulls<NativeContainerTextFormat>(3)
        val actions = mutableListOf<EntryLink>()
        var bodyContext: ContainerTextContext? = null
        var primary: Throwable? = null
        fun declaredBand(size: Float, height: Float, family: android.graphics.Typeface): Pair<Float, Float> {
            val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                textSize = size; typeface = family
            }
            val metrics = paint.fontMetrics
            val leading = (height - (metrics.descent - metrics.ascent)) / 2f
            return metrics.ascent - leading to metrics.descent + leading
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = rootStyle)) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val density = LocalDensity.current
                        val body = nativeBodyTextContext(snapshot, ContainerLineHeight.Multiplier(1.5f),
                            null, 20.sp, rootStyle, density).getOrThrow()
                        val bodyFormat = nativeContainerTextFormat(body, 20.sp, rootStyle, density)
                        val inheritedHeight = nativeCellTextContext(heightOnly, body, bodyFormat.style,
                            20.sp, density, 1f, null)
                        val nearerOwner = nativeCellTextContext(fullCell, body, bodyFormat.style,
                            20.sp, density, 1f, null)
                        val aliases = ContainerStyle(ownerFontScale = .75f,
                            fontFamily = aliasFamily).textContext(body)
                        val excluded = listOf(inheritedHeight, nearerOwner, aliases).map {
                            checkNotNull(nativeWithoutBodyTextContext(it, 20.sp, density))
                        }
                        excluded.forEachIndexed { index, context ->
                            val format = nativeContainerTextFormat(context, 20.sp, rootStyle, density)
                            CompositionLocalProvider(LocalNativeContainerTextContext provides context) {
                                val spans = listOf(child)
                                val annotated = styledTextAnnotation(spans, null, format.style) { actions += it }
                                val value = prepareNativeFloatText(spans, annotated, emptyList(), format.style,
                                    MaterialTheme.colorScheme.primary, emptyList(),
                                    AppSettings(allowImages = false, allowAudio = false), "", { actions += it },
                                    nativeLineHeight = format.lineHeight, sourceFamily = format.sourceFamily,
                                    ownerFont = format.ownerFont)
                                SideEffect { contexts[index] = context; prepared[index] = value; formats[index] = format }
                            }
                        }
                        SideEffect { bodyContext = body }
                    }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val original = checkNotNull(bodyContext)
                assertSame(snapshot, checkNotNull(original.containerText).snapshot)
                assertNotNull(original.bodyOrigin)
                val lineOnly = checkNotNull(contexts[0])
                assertNull(lineOnly.containerText); assertNull(lineOnly.cellText); assertNull(lineOnly.bodyOrigin)
                assertEquals(NativeLineHeightPolicy.Pixels(40f), checkNotNull(formats[0]).lineHeight)
                val complete = checkNotNull(contexts[1])
                assertNull(complete.containerText); assertNull(complete.bodyOrigin)
                assertSame(cellFont, checkNotNull(checkNotNull(complete.cellText).ownerFont).snapshot)
                assertEquals(NativeLineHeightPolicy.Pixels(40f), checkNotNull(formats[1]).lineHeight)
                val aliases = checkNotNull(contexts[2])
                assertNull(aliases.containerText); assertNull(aliases.cellText); assertNull(aliases.bodyOrigin)
                assertEquals(.75f, aliases.ownerFontScale, 0f)
                assertEquals(aliasFamily, aliases.fontFamily)
                assertEquals(NativeLineHeightPolicy.Pixels(24f), checkNotNull(formats[2]).lineHeight)
                val sizes = listOf(20f, 12f, 15f)
                for (index in prepared.indices) {
                    val value = checkNotNull(prepared[index])
                    val native = checkNotNull(value.native)
                    val source = native.source(240)
                    val runs = source.getSpans(0, source.length, NativeRunLineMetrics::class.java)
                    assertEquals(sizes[index], runs.single { it.strut }.primary.fontSize, .001f)
                    assertEquals(setOf(10f), runs.filter { !it.strut }.map { it.primary.fontSize }.toSet())
                    assertFalse(native.paint.typeface.isBold); assertFalse(native.paint.typeface.isItalic)
                    val height = if (index == 2) 24f else 40f
                    val family = if (index == 2) android.graphics.Typeface.SERIF else android.graphics.Typeface.SANS_SERIF
                    val ownerBand = declaredBand(sizes[index], height, family)
                    val childBand = declaredBand(10f, height, android.graphics.Typeface.SANS_SERIF)
                    val top = minOf(ownerBand.first, childBand.first)
                    val bottom = maxOf(ownerBand.second, childBand.second)
                    val geometry = checkNotNull(value.geometry).invoke(240, emptyList(), false)
                    assertEquals(bottom - top, geometry.textBottom, .001f)
                    assertEquals(-top, geometry.baselineForOffset(0), .001f)
                    assertEquals("M", geometry.text.toString())
                    assertNotNull(geometry.characterRects(0, 1).single())
                    geometry.nodes.single { it.onClick != null }.onClick!!()
                }
                val scalar = plain.copy(style = CellStyle(lineHeight = CellLineHeight(fixed,
                    CellTextStrut(.6f, FontScaleBasis.NormalBody))))
                val refusal = assertThrows(UnsupportedFloatLayout::class.java) {
                    nativeCellTextContext(scalar, original, checkNotNull(formats[0]).style,
                        20.sp, Density(1f, 1f), 1f, null)
                }
                assertEquals("A scalar Cell strut cannot replace an inherited Container declaring font.", refusal.message)
                assertSame(snapshot, checkNotNull(original.containerText).snapshot)
                assertSame(child, plain.spans.single())
                assertFalse(child.bold || child.italic || child.superscript || child.subscript)
                assertEquals(List(3) { "body-near-owner" }, actions.map { it.target })
            }
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

    @Test fun actualFigureCaptionsKeepTheirHeightsAboveBodyAndCellDefaults() {
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        val caption = listOf(Span("link", "Caption", target = "body-caption", foreground = "#0000ff"))
        val table = Table(emptyList(), listOf(listOf(Cell(caption, false, 1, 1))),
            style = TableStyle(border = StyleBorder.None, padding = zero,
                lineHeight = ComputedLineHeight(1.1f, FontScaleBasis.NormalBody)))
        val figure = Figure(FigureContent.Missing(Span("text", "media"), px(80f), px(20f)),
            FigureFormat.Framed, FigurePlacement.None, FigureClear.None, zero, zero, zero,
            1f, px(24f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme,
            FigureColor.Transparent, caption = caption)
        val figures = listOf(figure,
            figure.copy(caption = emptyList(), captionBlocks = listOf(Block("paragraph", 0, caption))),
            figure.copy(caption = emptyList(), captionBlocks = listOf(Block("table", 0, emptyList(), table = table))))
        val snapshot = InlineFontSnapshot(fontScale = 1.8f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, bold = true, italic = true, fontFamily = ContainerFontFamily.SansSerif)
        val cellFont = InlineFontSnapshot(fontScale = .6f, fontScaleBasis = FontScaleBasis.NormalBody,
            language = "en", fontFamily = ContainerFontFamily.SansSerif, fontFeatures = FontFeaturePolicy.Normal)
        val cell = Cell(emptyList(), false, 1, 1, style = CellStyle(lineHeight = CellLineHeight(
            CellLineHeightValue.Length(CellFixedLineHeight(40f, FontScaleBasis.CssPx)),
            CellTextStrut(.6f, FontScaleBasis.NormalBody, cellFont))))
        val rootStyle = TextStyle(fontSize = 20.sp, lineHeight = 26.sp,
            fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp)
        val selected = mutableStateOf(0 to false)
        val actions = mutableListOf<EntryLink>()
        var published: FloatTextGeometry? = null
        var primary: Throwable? = null
        data class Observed(val text: String, val height: Int,
            val characters: List<android.graphics.RectF?>, val bounds: List<android.graphics.RectF>,
            val start: Int, val end: Int)
        val baselines = arrayOfNulls<Observed>(figures.size)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = rootStyle)) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val density = LocalDensity.current
                        val body = if (selected.value.second) nativeBodyTextContext(snapshot,
                            ContainerLineHeight.Multiplier(1.5f), null, 20.sp, rootStyle, density).getOrThrow() else null
                        val inheritedStyle = body?.let { nativeContainerTextFormat(it, 20.sp, rootStyle, density).style }
                            ?: rootStyle
                        val context = checkNotNull(nativeCellTextContext(cell, body, inheritedStyle,
                            20.sp, density, 1f, null))
                        CompositionLocalProvider(LocalNativeContainerTextContext provides context) {
                            Layout(content = {
                                AnonymousBlockView(Block("paragraph", 0, emptyList(),
                                    figure = figures[selected.value.first]), Modifier, { actions += it }, emptyList(),
                                    AppSettings(allowImages = false, allowAudio = false), "", style = rootStyle,
                                    onGeometry = { published = it }, interactionOwner = false)
                            }) { children, constraints ->
                                val child = children.single().measure(Constraints(maxWidth = 240, maxHeight = 400))
                                layout(constraints.constrainWidth(240), constraints.constrainHeight(child.height)) {
                                    child.place(0, 0)
                                }
                            }
                        }
                    }
                }
            } }
            for (kind in figures.indices) for (withBody in listOf(false, true, false)) {
                compose.runOnIdle {
                    if (selected.value != (kind to withBody)) {
                        published = null; selected.value = kind to withBody
                    }
                }
                compose.waitForIdle()
                compose.runOnIdle {
                    val geometry = checkNotNull(published)
                    val text = geometry.text.toString()
                    val start = text.indexOf("Caption")
                    assertTrue(start >= 0)
                    val action = geometry.nodes.single { it.onClick != null }
                    assertEquals(start, action.start); assertEquals(start + 7, action.end)
                    val characters = geometry.characterRects(start, start + 7).map { rect ->
                        rect?.let { android.graphics.RectF(it) }
                    }
                    assertEquals(7, characters.count { it != null })
                    val current = Observed(text, geometry.height, characters,
                        action.bounds.map { android.graphics.RectF(it) }, action.start, action.end)
                    val prior = baselines[kind]
                    if (prior == null) {
                        assertFalse(withBody); baselines[kind] = current
                    } else {
                        assertEquals("BODY must not replace the nearer Figure or caption-table height", prior, current)
                    }
                    action.onClick!!(); assertEquals("body-caption", actions.last().target)
                    assertSame(caption.single(), figures[0].caption.single())
                    assertSame(caption.single(), figures[1].captionBlocks!!.single().spans.single())
                    assertSame(table, figures[2].captionBlocks!!.single().table)
                    assertEquals(24f, figures[kind].captionLineHeight.value, 0f)
                    assertEquals(FontScaleBasis.NormalBody, checkNotNull(table.style!!.lineHeight).fontScaleBasis)
                    assertEquals(22f, table.style!!.lineHeight!!.value * 20f, .001f)
                    assertEquals(40f, (cell.style!!.lineHeight!!.height as CellLineHeightValue.Length).value.value, 0f)
                }
            }
            assertEquals(List(figures.size * 3) { "body-caption" }, actions.map { it.target })
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

    @Test fun nativeBodyDirectionUsesStrongBasePoliciesBelowNearerOwners() {
        val font = InlineFontSnapshot(fontScale = 1.5f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, fontFamily = ContainerFontFamily.SansSerif)
        val root = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
            fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp)
        data class Sample(val text: String, val expectedRtl: Boolean, val prepared: PreparedNativeFloatText)
        var samples = emptyList<Sample>()
        var retained: ContainerTextContext? = null
        var excluded: ContainerTextContext? = null
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = root)) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                        LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr) {
                        val density = LocalDensity.current
                        val rtl = nativeBodyTextContext(font, ContainerLineHeight.Multiplier(1.5f),
                            null, 20.sp, root, density, direction = BidiResolvedDirection.Rtl).getOrThrow()
                        val ltr = rtl.copy(bodyDirection = BidiResolvedDirection.Ltr)
                        val replaced = nativeContainerOwnerTextContext(ContainerStyle(
                            ownerFont = font.copy(fontScale = .75f), lineHeight = ContainerLineHeight.Normal)
                            .textContext(rtl), root, density).getOrThrow()
                        val restored = checkNotNull(nativeWithoutBodyTextContext(replaced, 20.sp, density))
                        data class Input(val text: String, val context: ContainerTextContext?, val expectedRtl: Boolean,
                            val table: TableContainingDirection? = null, val owner: BidiResolvedDirection? = null,
                            val paragraph: androidx.compose.ui.text.style.TextDirection? = null)
                        val inputs = listOf(
                            Input("Latin", rtl, true), Input("אבג", ltr, false),
                            Input("Latin", null, false), Input("אבג", null, true),
                            Input("Latin", rtl, false, table = TableContainingDirection.Ltr),
                            Input("אבג", ltr, true, table = TableContainingDirection.Rtl),
                            Input("Latin", rtl, false, owner = BidiResolvedDirection.Ltr),
                            Input("אבג", ltr, true, owner = BidiResolvedDirection.Rtl),
                            Input("Latin", rtl, false, paragraph = androidx.compose.ui.text.style.TextDirection.Ltr),
                            Input("Latin", replaced, true), Input("Latin", restored, false))
                        val values = mutableListOf<Sample>()
                        inputs.forEach { input ->
                            CompositionLocalProvider(LocalNativeContainerTextContext provides input.context,
                                LocalCompiledTableTextDirection provides input.table) {
                                val source = listOf(Span("text", input.text, fontScale = .5f,
                                    fontScaleBasis = FontScaleBasis.NormalBody))
                                val format = input.context?.let { nativeContainerTextFormat(it, 20.sp, root, density) }
                                val style = format?.style ?: root
                                val annotated = styledTextAnnotation(source, null, style) { }
                                val projected = if (input.paragraph == null) annotated else
                                    AnnotatedString.Builder(annotated).apply {
                                        addStyle(ParagraphStyle(textDirection = input.paragraph), 0, length)
                                    }.toAnnotatedString()
                                values += Sample(input.text, input.expectedRtl,
                                    prepareNativeFloatText(source, projected, emptyList(), style,
                                        MaterialTheme.colorScheme.primary, emptyList(),
                                        AppSettings(allowImages = false, allowAudio = false), "", {},
                                        nativeLineHeight = format?.lineHeight, sourceFamily = format?.sourceFamily,
                                        ownerFont = format?.ownerFont, ownerDirection = input.owner))
                            }
                        }
                        SideEffect { samples = values.toList(); retained = replaced; excluded = restored }
                    }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(11, samples.size)
                assertEquals(BidiResolvedDirection.Rtl, checkNotNull(retained).bodyDirection)
                assertNull(checkNotNull(excluded).bodyDirection)
                assertSame(checkNotNull(retained).containerText!!.resolved, checkNotNull(excluded).containerText!!.resolved)
                assertEquals(NativeLineHeightPolicy.Normal,
                    nativeContainerTextFormat(checkNotNull(excluded), 20.sp, root, Density(1f, 1f)).lineHeight)
                samples.forEach { sample ->
                    val native = checkNotNull(sample.prepared.native)
                    assertEquals(sample.text, sample.prepared.text.toString())
                    assertEquals(sample.expectedRtl, native.direction.isRtl(sample.text, 0, sample.text.length))
                    val source = native.source(240)
                    val layout = android.text.StaticLayout.Builder.obtain(source, 0, source.length,
                        android.text.TextPaint(native.paint), 240).setTextDirection(native.direction)
                        .setIncludePad(false).build()
                    assertEquals(if (sample.expectedRtl) -1 else 1, layout.getParagraphDirection(0))
                    val geometry = checkNotNull(sample.prepared.geometry).invoke(240, emptyList(), false)
                    assertEquals(sample.text, geometry.text.toString())
                    assertEquals(sample.text.length, geometry.characterRects(0, sample.text.length).count { it != null })
                    assertTrue(geometry.nodes.none { it.onClick != null })
                }
            }
            // The Flow closure is composed after its preparation provider has returned.
            val flowSource = Span("link", "Latin", target = "deferred-body-flow", targetFragment = "part",
                fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody,
                fontFamily = ContainerFontFamily.SansSerif)
            val flowBlock = Block("paragraph", 0, emptyList(),
                flow = listOf(FlowPart.Inline(listOf(flowSource))))
            val flowRtl = mutableStateOf(false)
            val flowActions = mutableListOf<EntryLink>()
            val flowFailures = mutableListOf<String>()
            var flowActivity: android.app.Activity? = null
            var ambientBody: ContainerTextContext? = null
            val flowRects = mutableMapOf<Boolean, List<android.graphics.RectF?>>()
            compose.activityRule.scenario.onActivity { activity ->
                flowActivity = activity
                activity.setContent {
                    MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = root)) {
                        CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                            LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr,
                            LocalNativeContainerTextContext provides null,
                            LocalNativeFloatContextFailureObserver provides { flowFailures += it }) {
                            val body = nativeBodyTextContext(font, ContainerLineHeight.Multiplier(1.5f),
                                null, 20.sp, root, LocalDensity.current, direction = BidiResolvedDirection.Rtl).getOrThrow()
                            val ambient = LocalNativeContainerTextContext.current
                            SideEffect { ambientBody = ambient }
                            Layout(content = {
                                NativeFloatBlockContext(listOf(flowBlock), { flowActions += it }, "body-flow",
                                    Modifier, inCell = false, gridPath = "body-flow", gapDp = 0f,
                                    trailingGap = false, bodyTextContext = body.takeIf { flowRtl.value })
                            }) { children, constraints ->
                                val child = children.single().measure(Constraints.fixedWidth(240))
                                layout(constraints.constrainWidth(240), constraints.constrainHeight(child.height)) {
                                    child.place(0, 0)
                                }
                            }
                        }
                    }
                }
            }
            for (owned in listOf(false, true, false, true)) {
                compose.runOnIdle { flowRtl.value = owned }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertNull(ambientBody)
                    assertTrue(flowFailures.toString(), flowFailures.isEmpty())
                    val views = mutableListOf<NativeFloatTextView>()
                    fun visit(view: android.view.View) {
                        if (view is NativeFloatTextView && view.isShown &&
                            view.currentMeasuredGeometry?.nodes?.any { it.label?.toString() == "Latin" } == true) views += view
                        if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
                    }
                    visit(checkNotNull(flowActivity).window.decorView)
                    val view = views.single()
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    assertEquals("Latin", geometry.text.toString())
                    val rects = geometry.characterRects(0, 5)
                    assertEquals(5, rects.count { it != null })
                    val first = checkNotNull(rects.first())
                    assertTrue("Deferred Flow must use the explicit body paragraph direction", if (owned)
                        first.left > geometry.width / 2f else first.left < geometry.width / 2f)
                    val previous = flowRects[owned]
                    if (previous == null) flowRects[owned] = rects.map { it?.let { rect -> android.graphics.RectF(rect) } }
                    else assertEquals(previous, rects)
                    val node = geometry.nodes.single { it.label?.toString() == "Latin" }
                    val provider = checkNotNull(view.accessibilityNodeProvider)
                    assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals("deferred-body-flow", flowActions.last().target)
                    assertEquals("part", flowActions.last().targetFragment)
                    assertSame(flowSource, (checkNotNull(flowBlock.flow).single() as FlowPart.Inline).spans.single())
                }
            }
            assertEquals(4, flowActions.size)
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

    @Test fun actualReferenceBodyKeepsItsSlotLabelActionsAndEmptyBodyAcrossPolicyChanges() {
        val source = Span("link", "Alpha", target = "reference-body", targetFragment = "part",
            foreground = "#0000ff", fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFamily = ContainerFontFamily.SansSerif)
        val font = InlineFontSnapshot(fontScale = 1.5f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, fontFamily = ContainerFontFamily.SansSerif)
        val typography = BodyTypography(font, ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 32f)),
            direction = BidiResolvedDirection.Rtl)
        val plain = Reference(17, 17, "latin", listOf(source))
        val owned = plain.copy(bodyTypography = typography)
        val block = Block("paragraph", 0, listOf(source))
        val ordered = Reference(18, null, "", emptyList(), kind = ReferenceKind.Fragment,
            blocks = listOf(block), bodyTypography = typography)
        val unusedTypography = typography.copy(ownerFont = font.copy(fontFamily = ContainerFontFamily.Stack(
            listOf("Controlled Reference Family"), GenericFontFamily.SansSerif)))
        val bare = plain.copy(spans = emptyList(), blocks = listOf(Block("paragraph", 0, emptyList())))
        val emptyMetric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx))))
        val broken = plain.copy(spans = emptyList(), blocks = listOf(Block("paragraph", 0,
            listOf(emptyMetric, Span("line_break", "")))))
        val cases = listOf(plain, owned, ordered,
            ordered.copy(blocks = emptyList(), bodyTypography = unusedTypography),
            owned.copy(spans = emptyList(), bodyTypography = unusedTypography), owned, bare, bare.copy(bodyTypography = typography),
            broken, broken.copy(bodyTypography = typography), owned)
        val selected = mutableStateOf(0)
        val labelGroup = mutableStateOf("latin")
        val root = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
            fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp)
        val actions = mutableListOf<EntryLink>()
        var activity: android.app.Activity? = null
        var labelBounds: androidx.compose.ui.geometry.Rect? = null
        var bodyBounds: androidx.compose.ui.geometry.Rect? = null
        var labelLayout: androidx.compose.ui.text.TextLayoutResult? = null
        val originalLabels = mutableMapOf<String, Triple<androidx.compose.ui.geometry.Rect,
            androidx.compose.ui.text.style.ResolvedTextDirection, TextStyle>>()
        val ownedGeometry = mutableMapOf<String, Pair<Int, List<android.graphics.RectF?>>>()
        var bareHeight: Float? = null
        var breakHeight: Float? = null
        var namedProbes = 0
        var primary: Throwable? = null
        fun views(): List<NativeFloatTextView> {
            val result = mutableListOf<NativeFloatTextView>()
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView && view.isShown) result += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(checkNotNull(activity).window.decorView)
            return result
        }
        try {
            compose.activityRule.scenario.onActivity { host ->
                activity = host
                host.setContent {
                    MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = root)) {
                        CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                            LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr) {
                            val probe = remember { NativeNamedFontProbe { _, _, _, _ ->
                                namedProbes++; android.graphics.Typeface.SANS_SERIF
                            } }
                            val inherited = nativeBodyTextContext(font.copy(fontScale = 2f),
                                ContainerLineHeight.Multiplier(2f), null, 20.sp, root, LocalDensity.current,
                                direction = BidiResolvedDirection.Rtl).getOrThrow()
                            CompositionLocalProvider(LocalNativeContainerTextContext provides inherited,
                                LocalNativeNamedFontProbe provides probe) {
                                Layout(content = {
                                    androidx.compose.foundation.layout.Row(
                                        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                                        val original = cases[selected.value]
                                        val reference = if (original.kind == ReferenceKind.Fragment) original
                                            else original.copy(group = labelGroup.value)
                                        val label = referenceLabel(reference)
                                        if (label == null) SideEffect { labelBounds = null; labelLayout = null }
                                        else androidx.compose.material3.Text(label, style = MaterialTheme.typography.labelMedium,
                                            modifier = Modifier.onGloballyPositioned { labelBounds = it.boundsInRoot() },
                                            onTextLayout = { labelLayout = it })
                                        ReferenceBody(reference, Modifier.weight(1f)
                                            .onGloballyPositioned { bodyBounds = it.boundsInRoot() }) { actions += it }
                                    }
                                }) { children, constraints ->
                                    val child = children.single().measure(Constraints.fixedWidth(300))
                                    layout(constraints.constrainWidth(300), constraints.constrainHeight(child.height)) {
                                        child.place(0, 0)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            for (group in listOf("latin", "עברית", "Latin עברית")) {
              val phases = if (group == "latin") cases.indices.toList() else listOf(0, 1, 5)
              for (index in phases) {
                compose.runOnIdle { selected.value = index; labelGroup.value = group }
                compose.waitForIdle()
                compose.runOnIdle {
                    val body = checkNotNull(bodyBounds)
                    if (cases[index].kind == ReferenceKind.Fragment) {
                        assertNull(referenceLabel(cases[index])); assertNull(labelBounds); assertNull(labelLayout)
                        assertEquals(0f, body.left, .001f)
                    } else {
                        val label = checkNotNull(labelBounds)
                        val layout = checkNotNull(labelLayout)
                        val expected = checkNotNull(referenceLabel(cases[index].copy(group = group)))
                        assertEquals(expected, layout.layoutInput.text.text)
                        val labelDirection = layout.getParagraphDirection(0)
                        assertEquals(if (group == "עברית") androidx.compose.ui.text.style.ResolvedTextDirection.Rtl
                            else androidx.compose.ui.text.style.ResolvedTextDirection.Ltr, labelDirection)
                        val currentLabel = Triple(label, labelDirection, layout.layoutInput.style)
                        val previous = originalLabels.putIfAbsent(expected, currentLabel)
                        if (previous != null) assertEquals(previous, currentLabel)
                        assertEquals(label.right + 8f, body.left, .001f)
                    }
                    assertEquals(300f, body.right, .001f)
                    val owners = views().filter { view -> view.currentMeasuredGeometry?.nodes?.any {
                        it.onClick != null && it.label?.toString() == "Alpha" } == true }
                    if (index == 3 || index == 4) {
                        assertEquals(0f, body.height, .001f)
                        assertTrue(owners.isEmpty())
                        assertEquals(0, namedProbes)
                    } else if (index == 6 || index == 7) {
                        assertTrue(owners.isEmpty())
                        if (index == 6) bareHeight = body.height
                        else assertEquals(checkNotNull(bareHeight), body.height, .001f)
                    } else if (index == 8 || index == 9) {
                        assertTrue(owners.isEmpty())
                        val realLine = views().mapNotNull { it.currentMeasuredGeometry }
                            .single { it.text.toString() == "\n" }
                        assertTrue(realLine.height > 0)
                        if (index == 8) breakHeight = body.height
                        else assertTrue(body.height > checkNotNull(breakHeight))
                    } else {
                        val view = owners.single()
                        val geometry = checkNotNull(view.currentMeasuredGeometry)
                        val node = geometry.nodes.single { it.onClick != null && it.label?.toString() == "Alpha" }
                        assertEquals("Alpha", geometry.text.subSequence(node.start, node.end).toString())
                        val characters = geometry.characterRects(node.start, node.end).map { rect ->
                            rect?.let { android.graphics.RectF(it) }
                        }
                        assertEquals(5, characters.count { it != null })
                        val first = checkNotNull(characters.first())
                        if (index == 0) assertTrue(first.left < geometry.width / 2f)
                        else assertTrue(first.left > geometry.width / 2f)
                        val observed = geometry.height to characters
                        if (index == 1) ownedGeometry[group] = observed
                        if (index == 5 || index == 10) assertEquals(ownedGeometry[group], observed)
                        view.setSelection(node.start, node.end)
                        assertEquals("Alpha", view.selectedTextForCopy())
                        view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN,
                            android.view.KeyEvent.KEYCODE_ESCAPE))
                        val provider = checkNotNull(view.accessibilityNodeProvider)
                        val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                        assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
                        assertEquals("Alpha", info.text?.toString())
                        assertTrue(provider.performAction(node.id,
                            android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                        assertEquals("reference-body", actions.last().target)
                        assertEquals("part", actions.last().targetFragment)
                    }
                    assertSame(source, plain.spans.single()); assertSame(block, ordered.blocks!!.single())
                    assertSame(source, ordered.blocks!!.single().spans.single())
                    assertEquals(ReferenceKind.Fragment, ordered.kind)
                }
              }
            }
            assertEquals(11, actions.size)
            assertEquals(0, namedProbes)
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

    @Test fun citationBacklinkUsesItsActualFontNormalAndNumericBandsOutsideReferenceBody() {
        // Direct typed controls: a Normal backlink is consumer coverage, not producer admission.
        val plain = Span("link", "Return", targetFragment = "original-citation-return",
            fontScale = 1.25f, fontScaleBasis = FontScaleBasis.Context)
        val normal = ReferenceBacklink.withPolicies(7, plain)
        val relative = ReferenceBacklink.withPolicies(7, plain, inlineStyle = InlineTextStyle(
            lineHeight = InlineLineHeight.FontRelative(1.5f, InlineFontSnapshot(fontScale = 1.25f))))
        val zero = ReferenceBacklink.withPolicies(7, plain, inlineStyle = InlineTextStyle(
            lineHeight = InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx))))
        val cases = listOf(normal, normal, relative, zero, normal, normal)
        val phase = mutableStateOf(0)
        val bodySpan = Span("link", "Body", target = "independent-reference-body")
        val bodyFont = InlineFontSnapshot(fontScale = 1.6f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, bold = true, italic = true, fontFamily = ContainerFontFamily.SansSerif)
        val reference = Reference(41, 9, "", listOf(bodySpan), bodyTypography = BodyTypography(
            bodyFont, ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 52f))))
        val root = TextStyle(fontSize = 20.sp, lineHeight = 77.sp, fontFamily = FontFamily.Serif,
            fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
            fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
            fontFeatureSettings = "smcp", letterSpacing = 3.sp)
        val actions = mutableListOf<EntryLink>()
        var activity: android.app.Activity? = null
        var prepared: PreparedNativeFloatText? = null
        var basisPixels = 0f
        var prefixBounds: androidx.compose.ui.geometry.Rect? = null
        var bodyBounds: androidx.compose.ui.geometry.Rect? = null
        val originalNormal = mutableMapOf<Float, Pair<Float, Float>>()
        var primary: Throwable? = null
        fun views(): List<NativeFloatTextView> {
            val found = mutableListOf<NativeFloatTextView>()
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView && view.isShown) found += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(checkNotNull(activity).window.decorView)
            return found
        }
        try {
            compose.activityRule.scenario.onActivity { host ->
                activity = host
                host.setContent {
                    MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = root)) {
                        val zoom = if (phase.value == 4) 1.5f else 1f
                        CompositionLocalProvider(LocalDensity provides Density(1f, zoom),
                            LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr) {
                            val density = LocalDensity.current
                            val inherited = nativeBodyTextContext(bodyFont.copy(fontScale = 3f),
                                ContainerLineHeight.Multiplier(4f), null, 20.sp, root, density).getOrThrow()
                            val hostile = phase.value != 0
                            CompositionLocalProvider(
                                androidx.compose.material3.LocalTextStyle provides root,
                                LocalNativeContainerTextContext provides if (hostile) inherited else null,
                                LocalCellWeight provides if (hostile) androidx.compose.ui.text.font.FontWeight.Black else null,
                                LocalCellLetterSpacingPixels provides if (hostile) 6f else null,
                                LocalTableLineHeightPixels provides if (hostile) 91f else null,
                                LocalNativePreformattedText provides hostile) {
                                val value = prepareNativeReferenceBacklink(cases[phase.value]) { actions += it }
                                SideEffect { prepared = value; basisPixels = with(density) { 20.sp.toPx() } }
                                Layout(content = {
                                    androidx.compose.foundation.layout.Row(
                                        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(value, 0f)),
                                            Modifier.width(androidx.compose.foundation.layout.IntrinsicSize.Max)
                                                .onGloballyPositioned { prefixBounds = it.boundsInRoot() },
                                            MaterialTheme.colorScheme.primary) { _, _ ->
                                            error("Backlink has no delegated child")
                                        }
                                        CompositionLocalProvider(LocalCellWeight provides null,
                                            LocalCellLetterSpacingPixels provides null,
                                            LocalTableLineHeightPixels provides null,
                                            LocalNativePreformattedText provides false) {
                                            ReferenceBody(reference, Modifier.weight(1f)
                                                .onGloballyPositioned { bodyBounds = it.boundsInRoot() }) { actions += it }
                                        }
                                    }
                                }) { children, constraints ->
                                    val child = children.single().measure(Constraints.fixedWidth(360))
                                    layout(constraints.constrainWidth(360), constraints.constrainHeight(child.height)) {
                                        child.place(0, 0)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            for (index in cases.indices) {
                compose.runOnIdle { phase.value = index }
                compose.waitForIdle()
                compose.runOnIdle {
                    val backlink = cases[index]
                    val value = checkNotNull(prepared)
                    val native = checkNotNull(value.native)
                    val source = native.source(360)
                    val geometry = checkNotNull(value.geometry).invoke(360, emptyList(), false)
                    val expectedPixels = basisPixels * 1.25f
                    val independent = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        typeface = android.graphics.Typeface.DEFAULT
                        textSize = expectedPixels
                    }
                    val metrics = independent.fontMetrics
                    assertEquals(expectedPixels, native.paint.textSize, .001f)
                    assertEquals(android.graphics.Typeface.NORMAL, native.paint.typeface.style)
                    assertFalse(native.paint.isFakeBoldText)
                    assertEquals(0f, native.paint.textSkewX, 0f)
                    assertEquals(0f, native.paint.letterSpacing, 0f)
                    assertTrue(native.paint.fontFeatureSettings.isNullOrEmpty())
                    assertEquals(0, native.paint.baselineShift)
                    assertEquals(metrics.ascent, native.paint.fontMetrics.ascent, .001f)
                    assertEquals(metrics.descent, native.paint.fontMetrics.descent, .001f)
                    assertEquals("Return", source.toString())
                    assertEquals("Return", geometry.text.toString())
                    assertEquals(1, geometry.shapedLineCount)
                    val runs = source.getSpans(0, source.length, NativeRunLineMetrics::class.java)
                    val strut = runs.single { it.strut }
                    assertEquals(expectedPixels, strut.primary.fontSize, .001f)
                    assertEquals(metrics.ascent, strut.primary.ascent, .001f)
                    assertEquals(metrics.descent, strut.primary.descent, .001f)
                    val height: Float
                    val expectedBaseline: Float
                    if (index == 2 || index == 3) {
                        height = if (index == 2) expectedPixels * 1.5f else 0f
                        val top = metrics.ascent - (height - (metrics.descent - metrics.ascent)) / 2f
                        expectedBaseline = -top
                        assertTrue(runs.all { it.policy == NativeLineHeightPolicy.Pixels(height) })
                        val authored = source.getSpans(0, source.length, NativeAuthoredInlineMetrics::class.java)
                        assertTrue(authored.isNotEmpty())
                        assertTrue(authored.all { it.policy == NativeLineHeightPolicy.Pixels(height) })
                    } else {
                        val independentlyShaped = android.text.StaticLayout.Builder.obtain("Return", 0, 6, independent, 360)
                            .setIncludePad(true).setUseLineSpacingFromFallbacks(true).setLineSpacing(0f, 1f)
                            .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                            .setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE).build()
                        val baseline = independentlyShaped.getLineBaseline(0).toFloat()
                        val top = minOf(independentlyShaped.getLineTop(0) - baseline, metrics.ascent)
                        val bottom = maxOf(independentlyShaped.getLineBottom(0) - baseline, metrics.descent)
                        height = bottom - top
                        expectedBaseline = -top
                        assertTrue(runs.all { it.policy == NativeLineHeightPolicy.Normal })
                        assertTrue(strut.includePrimaryInNormal)
                        val measured = geometry.textBottom to geometry.baselineForOffset(0)
                        val previous = originalNormal.putIfAbsent(expectedPixels, measured)
                        if (previous != null) assertEquals(previous, measured)
                    }
                    assertEquals(height, geometry.textBottom, .001f)
                    assertEquals(expectedBaseline, geometry.baselineForOffset(0), .001f)
                    assertEquals(independent.measureText("Return"), geometry.nativeSingleLineAdvance(), .01f)
                    assertEquals(6, geometry.characterRects(0, 6).count { it != null })
                    val prefix = checkNotNull(prefixBounds)
                    val body = checkNotNull(bodyBounds)
                    assertEquals(prefix.right + 8f, body.left, .001f)
                    assertEquals(360f, body.right, .001f)
                    val prefixView = views().single { it.currentMeasuredGeometry?.text?.toString() == "Return" }
                    val actual = checkNotNull(prefixView.currentMeasuredGeometry)
                    val actualContent = (actual as NativeSurfaceGeometry).content
                    assertEquals(height, actualContent.extents.usedHeight, .001f)
                    assertEquals(expectedBaseline, checkNotNull(checkNotNull(actualContent.textBaselines).first), .001f)
                    val node = actual.nodes.single { it.onClick != null }
                    assertEquals("Return", node.label?.toString())
                    prefixView.setSelection(node.start, node.end)
                    assertEquals("Return", prefixView.selectedTextForCopy())
                    prefixView.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN,
                        android.view.KeyEvent.KEYCODE_ESCAPE))
                    val provider = checkNotNull(prefixView.accessibilityNodeProvider)
                    val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                    try {
                        assertTrue(info.isClickable)
                        assertEquals("Return", info.text?.toString())
                    } finally { info.recycle() }
                    assertTrue(provider.performAction(node.id,
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals(EntryLink("", "original-citation-return"), actions.last())
                    val bodyView = views().single { it.currentMeasuredGeometry?.text?.toString() == "Body" }
                    val bodyGeometry = checkNotNull(bodyView.currentMeasuredGeometry)
                    assertEquals(52f, (bodyGeometry as NativeSurfaceGeometry).content.extents.usedHeight, .001f)
                    val bodyNode = bodyGeometry.nodes.single { it.onClick != null }
                    assertTrue(checkNotNull(bodyView.accessibilityNodeProvider).performAction(bodyNode.id,
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals("independent-reference-body", actions.last().target)
                    assertSame(bodySpan, reference.spans.single())
                    assertEquals(plain.text, backlink.span.text)
                    assertEquals(plain.targetFragment, backlink.span.targetFragment)
                    assertFalse(backlink.span.bold); assertFalse(backlink.span.italic)
                    assertFalse(backlink.span.superscript); assertEquals("normal", backlink.span.role)
                }
            }
            assertEquals(cases.size * 2, actions.size)
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }
}
