package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.os.LocaleList as AndroidLocaleList
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.AlignmentSpan
import android.text.style.LeadingMarginSpan
import android.text.style.LineHeightSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.*
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.*
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.CancellationException
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

internal const val NativeInlineFamilyReplacementUnavailable = "The authored font family is unavailable for this replacement layout."
/** Line presence comes from compiled inline content, never a font/metric-only owner.
 * Offsets include native bidi isolates; those injected controls do not establish a line. */
internal fun nativeNoWrapSourceLineStarts(spans: List<Span>): List<Int> {
    val present = linkedSetOf<Int>()
    var offset = 0
    var paragraphStart = 0
    fun text(value: String) {
        value.forEach { character ->
            present += paragraphStart
            offset++
            if (character == '\n') paragraphStart = offset
        }
    }
    spans.forEach { span ->
        if (span.usesInlineDirectionIsolate()) offset++
        text(if (span.image != null) "\ufffc" else if (span.kind == "line_break") "\n" else span.text)
        text(span.trail)
        if (span.usesInlineDirectionIsolate()) offset++
    }
    check(offset == spans.nativeLogicalLength()) { "No-wrap line presence changed source offsets" }
    return present.toList()
}

private fun nativeSourceRangeHasLine(text: CharSequence, start: Int, end: Int, starts: List<Int>): Boolean {
    val paragraphStart = text.lastIndexOf('\n', start - 1) + 1
    return paragraphStart in starts || starts.any { it > start && it < end }
}

private data class NativeSourceFamilyRange(val start: Int, val end: Int, val family: ContainerFontFamily?,
    val legacy: LegacySpanFontFamily?)

internal data class NativeHeadingAction(val label: String, val collapsed: Boolean, val onClick: () -> Unit)

private data class NativeStyleRange(val start: Int, val end: Int, val paint: TextPaint, val bold: Boolean, val italic: Boolean,
    val baselineShiftMultiplier: Float, val letterSpacingPixels: Float?, val familyFailure: String? = null)
private data class NativeInlineSourceRange(val span: Span, val start: Int, val end: Int,
    val declaringPaint: TextPaint?, val emptyPaint: TextPaint?)
private data class NativeResolvedInlineStyle(val source: NativeInlineSourceRange,
    val height: Float?, val shift: Float?, val thickness: Float?)
private class NativePaintSpan(private val value: TextPaint, private val missingLink: NativeMissingLinkPaint? = null) : MetricAffectingSpan(), NativeMayUnderline, NativeInlineSafePaintSpan {
    override val mayUnderline: Boolean get() = missingLink != null || value.isUnderlineText
    override fun updateMeasureState(paint: TextPaint) { paint.set(value) }
    override fun updateDrawState(paint: TextPaint) {
        paint.set(value)
        missingLink?.appearance()?.let { paint.color = it.color; paint.isUnderlineText = it.underline }
    }
}

/** Partition at every authored style/link boundary; overlapping styles are merged in their original order. */
@Composable
private fun nativeStyleRanges(text: AnnotatedString, effective: TextStyle, linkColor: Color,
    additionalCuts: List<Int> = emptyList(), sourceFamily: ContainerFontFamily? = null,
    familyRanges: List<NativeSourceFamilyRange> = emptyList(), legacyOwnerFamily: FontFamily? = null,
    sourceLineStarts: List<Int>? = null): List<NativeStyleRange> {
    val density = LocalDensity.current
    val resolver = LocalFontFamilyResolver.current
    val contentColor = LocalContentColor.current
    val baseSize = with(density) { effective.fontSize.toPx() }
    val links = text.getLinkAnnotations(0, text.length)
    val cuts = (listOf(0, text.length) + text.spanStyles.flatMap { listOf(it.start, it.end) } +
        links.flatMap { listOf(it.start, it.end) } + additionalCuts + familyRanges.filter { it.family != null }.flatMap { listOf(it.start, it.end) } +
        if (sourceLineStarts == null) emptyList() else text.text.indices.filter { text.text[it] == '\n' }.map { it + 1 }).distinct().sorted()
    return cuts.zipWithNext().mapNotNull { (start, end) ->
        if (sourceLineStarts != null && !nativeSourceRangeHasLine(text.text, start, end, sourceLineStarts))
            return@mapNotNull null
        var style = text.spanStyles.filter { it.start <= start && it.end >= end }
            .fold(effective.toSpanStyle()) { merged, range -> merged.merge(range.item) }
        links.filter { it.start <= start && it.end >= end }.forEach { link ->
            style = style.merge(link.item.styles?.style ?: SpanStyle(color = linkColor))
        }
        val owner = familyRanges.singleOrNull { it.start <= start && it.end >= end }
        // Original semantic provenance distinguishes an actual code/Egyptian mapping
        // from derived cell body defaults, even when their generic faces are equal.
        val request = owner?.family ?: when (sourceFamily) {
            is ContainerFontFamily.Stack -> sourceFamily.takeIf { owner?.legacy == null }
            // The original M tag-zero projection stays exact. Equality never admits a new Stack.
            ContainerFontFamily.SansSerif -> sourceFamily.takeIf { style.fontFamily == effective.fontFamily }
            null -> null
        }
        val admission = nativeContainerFontAdmission(request,
            style.fontWeight ?: FontWeight.Normal, style.fontStyle ?: FontStyle.Normal)
        val family = request?.let(::nativeTerminalFontFamily) ?:
            legacyOwnerFamily.takeIf { owner?.legacy == null } ?: style.fontFamily ?: FontFamily.Default
        val face by resolver.resolve(family, style.fontWeight ?: FontWeight.Normal,
            style.fontStyle ?: FontStyle.Normal, style.fontSynthesis ?: FontSynthesis.All)
        val size = when {
            style.fontSize.isSp -> with(density) { style.fontSize.toPx() }
            style.fontSize.isEm -> (baseSize.toDouble() * style.fontSize.value).coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat()
            else -> baseSize
        }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = face as Typeface
            textSize = size
            color = (style.color.takeIf { it != Color.Unspecified } ?: contentColor).toArgb()
            bgColor = style.background.takeIf { it != Color.Unspecified }?.toArgb() ?: 0
            baselineShift = ceil(ascent() * (style.baselineShift?.multiplier ?: 0f)).toInt()
            letterSpacing = when {
                style.letterSpacing.isEm -> style.letterSpacing.value
                style.letterSpacing.isSp && size > 0 -> with(density) { style.letterSpacing.toPx() } / size
                else -> 0f
            }
            fontFeatureSettings = style.fontFeatureSettings
            style.textGeometricTransform?.let { textScaleX = it.scaleX; textSkewX = it.skewX }
            style.localeList?.let { textLocales = AndroidLocaleList.forLanguageTags(it.joinToString(",") { locale -> locale.toLanguageTag() }) }
            isUnderlineText = TextDecoration.Underline in (style.textDecoration ?: TextDecoration.None)
            isStrikeThruText = TextDecoration.LineThrough in (style.textDecoration ?: TextDecoration.None)
        }
        NativeStyleRange(start, end, paint, (style.fontWeight ?: FontWeight.Normal).weight >= FontWeight.SemiBold.weight,
            style.fontStyle == FontStyle.Italic, style.baselineShift?.multiplier ?: 0f,
            if (style.letterSpacing.isSp) with(density) { style.letterSpacing.toPx() } else null,
            admission.exceptionOrNull()?.message)
    }
}

/** Match the ordinary inline-image alt policy without changing the occurrence's em basis or Ready image. */
internal fun nativeFloatImageFallbackLayout(image: InlineImage, state: InlineImageAssetState,
    occurrencePaint: TextPaint, parentPaint: TextPaint, baselineShiftMultiplier: Float = 0f,
    letterSpacingPixels: Float? = null): StaticLayout? {
    val alt = inlineImageFallbackText(image, state) ?: return null
    val fallbackPaint = TextPaint().apply {
        set(occurrencePaint)
        if (textSize <= 0f) {
            textSize = parentPaint.textSize
            // Resolved typeface, authored paint and decoration remain the occurrence's;
            // size-relative baseline/spacing must be recomputed at the parent fallback size.
            baselineShift = ceil(ascent() * baselineShiftMultiplier).toInt()
            if (letterSpacingPixels != null && textSize > 0f) letterSpacing = letterSpacingPixels / textSize
        }
    }
    return StaticLayout.Builder.obtain(alt, 0, alt.length, fallbackPaint, MaxComputedFontPixels.toInt())
        .setIncludePad(true).build()
}

private data class NativeImage(
    val id: Int, val offset: Int, val span: Span, val state: InlineImageAssetState,
    val paint: TextPaint, val pixels: InlineImagePixels, val ink: NativeFloatBounds,
    val draw: (Canvas, RectF) -> Unit,
)

private class NativeInlineImageSpan(private val image: NativeImage) : ReplacementSpan(), NativeAtomicInlineMetrics, NativeReplacementPaintBounds, NativeNoWrapInlineImage {
    override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds =
        image.ink.translated(0f, nativeUsedMetrics.top)
    override val nativeUsedMetrics: NativeUsedLineMetrics get() {
        val metrics = image.paint.fontMetricsInt
        val bounds = Rect(); image.paint.getTextBounds("x", 0, 1, bounds)
        val top = inlineImageInkTop(InlineImageFontMetrics(metrics.ascent, metrics.descent,
            bounds.height().toFloat(), image.paint.baselineShift), image.pixels.height)
        return NativeUsedLineMetrics(top, top + image.pixels.height)
    }
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        val metrics = image.paint.fontMetricsInt
        val bounds = Rect(); image.paint.getTextBounds("x", 0, 1, bounds)
        val top = inlineImageInkTop(InlineImageFontMetrics(metrics.ascent, metrics.descent, bounds.height().toFloat(), image.paint.baselineShift), image.pixels.height)
        fm?.let { it.ascent = min(metrics.ascent, kotlin.math.floor(top).toInt()); it.top = it.ascent
            it.descent = max(metrics.descent, ceil(top + image.pixels.height).toInt()); it.bottom = it.descent }
        return ceil(image.pixels.width).toInt()
    }
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        val metrics = image.paint.fontMetricsInt
        val bounds = Rect(); image.paint.getTextBounds("x", 0, 1, bounds)
        val inkTop = y + inlineImageInkTop(InlineImageFontMetrics(metrics.ascent, metrics.descent,
            bounds.height().toFloat(), image.paint.baselineShift), image.pixels.height)
        image.draw(canvas, RectF(x, inkTop, x + image.pixels.width, inkTop + image.pixels.height))
    }
}

private fun imageStatus(state: InlineImageAssetState): String = when (state) {
    InlineImageAssetState.Disabled -> "Images disabled"
    InlineImageAssetState.Loading -> "Loading image"
    InlineImageAssetState.Failed -> "Image unavailable"
    InlineImageAssetState.LayoutUnavailable -> "Image layout unavailable"
    is InlineImageAssetState.GeometryUnavailable -> "Image geometry unavailable"
    is InlineImageAssetState.Ready -> ""
}

/** Uses the same view-scoped media owner as ordinary inline images; never starts a second download/cache. */
@Composable
internal fun prepareNativeFloatText(
    spans: List<Span>, annotated: AnnotatedString, runs: List<EgyptianTextRun>,
    style: TextStyle, linkColor: Color, media: List<Media>, settings: AppSettings, edition: String,
    onLink: (EntryLink) -> Unit, paragraphGaps: List<Pair<Int, Float>> = emptyList(), containAtEnd: Boolean = false,
    indentPixels: Float = 0f, prefix: String = "", prefixStyle: TextStyle? = null,
    heading: Boolean = false, headingActions: List<NativeHeadingAction> = emptyList(),
    imageOwnerOverride: InlineImageViewOwner? = null,
    missingLinkPaint: NativeMissingLinkPaint? = null, onMissingLinkActivated: () -> Unit = {},
    nativeLineHeight: NativeLineHeightPolicy? = null,
    figureImageActions: Boolean = false,
    sourceFamily: ContainerFontFamily? = LocalNativeContainerTextContext.current?.fontFamily,
    authoredHeading: Boolean = false, ownerDirection: BidiResolvedDirection? = null,
    headingLabel: String? = null, ownerWrap: TextWrap? = null,
    ownerFont: NativeDeclaringFont? = null,
): PreparedNativeFloatText {
    val context = LocalContext.current
    val density = LocalDensity.current
    val uri = LocalUriHandler.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val effective = LocalTextStyle.current.merge(style)
    require(effective.fontSize.isSp)
    val captionScope = LocalFigureCaptionLinkScope.current.takeIf { !figureImageActions && missingLinkPaint == null }
    val captionOwner = remember { Any() }
    val visits = LocalMissingLinkVisits.current ?: remember { MissingLinkVisits() }
    val documentTitle = LocalMissingLinkDocument.current
    val documentOwner = LocalMissingLinkOwner.current ?: captionOwner
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val paintUnavailable = ordinaryLinkPaintUnavailable(spans)
    val paintedLinks = remember(spans, captionScope) {
        if (captionScope == null && spans.none { it.linkPaint != null }) emptyList()
        else nativeCaptionLinkRanges(spans).filter { it.span.linkPaint != null || captionScope != null }
    }
    val ordinaryPolicies = paintedLinks.associate { (it.start to it.end) to it.span.linkPaint }
    val linkPaints = paintedLinks.associate { range ->
        val ordinary = range.span.linkPaint
        val scope = captionScope.takeIf { ordinary == null }
        val target = missingLinkTarget(range.span, edition,
            if (ordinary != null) documentTitle else checkNotNull(scope).documentTitle)
        val identity = MissingLinkActionIdentity(if (ordinary != null) documentOwner else checkNotNull(scope).owner, target,
            NativeLinkOccurrenceIdentity(captionOwner, range.index, range.start, range.end, range.span))
        val visited = (if (ordinary != null) visits else checkNotNull(scope).visits).contains(target)
        // Span.underline is only the ordinary normal-state checksum. Existing Figure owners
        // retain their independent child decoration and original six-state selection.
        val authoredUnderline = ordinary == null && (range.span.underline ||
            TextDecoration.Underline in (effective.textDecoration ?: TextDecoration.None))
        val state = remember(ordinary, scope?.policy, visited, identity, authoredUnderline) {
            if (ordinary != null) NativeMissingLinkPaint(ordinary, visited, identity)
            else NativeMissingLinkPaint(checkNotNull(scope).policy, visited, authoredUnderline, identity)
        }
        (range.start to range.end) to state
    }
    val ordinaryPaintRevision = paintedLinks.filter { it.span.linkPaint != null }
        .map { linkPaints.getValue(it.start to it.end) }.takeIf { it.isNotEmpty() }
    fun linkPaintAt(start: Int, end: Int): NativeMissingLinkPaint? = missingLinkPaint ?: linkPaints.entries
        .firstOrNull { (range, _) -> range.first <= start && range.second >= end }?.value
    var familyOffset = 0
    val familyRanges = spans.map { span ->
        val start = familyOffset
        familyOffset += listOf(span).nativeLogicalLength()
        NativeSourceFamilyRange(start, familyOffset, span.fontFamily, span.legacyFontFamily())
    }
    check(familyOffset == annotated.length) { "Authored family offsets must retain the original logical string" }
    val hasInlineFamily = spans.hasAuthoredFontFamily()
    val sourceLineStarts = if (ownerWrap == TextWrap.NoWrap) nativeNoWrapSourceLineStarts(spans) else null
    val noSourceLines = sourceLineStarts?.isEmpty() == true
    val emptyInlineOwner = if (sourceLineStarts != null) sourceLineStarts.isEmpty() &&
        prefix.isEmpty() && !heading && headingActions.isEmpty() else
        (hasInlineFamily || sourceFamily is ContainerFontFamily.Stack) &&
            !spans.hasCompiledInlineContent() && prefix.isEmpty() && !heading && headingActions.isEmpty()
    val preformattedOwner = ownerFont == null && LocalNativePreformattedText.current
    val inheritedFamily = sourceFamily.takeUnless { emptyInlineOwner ||
        preformattedOwner && sourceFamily is ContainerFontFamily.Stack }
    val legacyOwnerFamily = effective.fontFamily.takeIf {
        preformattedOwner && (hasInlineFamily || sourceFamily is ContainerFontFamily.Stack)
    }
    val replacementFamilyFailure = runs.any { run -> familyRanges.any { it.family != null && it.start < run.end && it.end > run.start } }
    var familyFailure: String? = if (replacementFamilyFailure) NativeInlineFamilyReplacementUnavailable else null
    fun familyPaint(run: NativeStyleRange): TextPaint {
        if (familyFailure == null) familyFailure = run.familyFailure
        return run.paint
    }
    var inlineOffset = 0
    val inlineSources = spans.mapNotNull { span ->
        val start = inlineOffset
        inlineOffset += listOf(span).nativeLogicalLength()
        val hasSourceLine = sourceLineStarts == null ||
            nativeSourceRangeHasLine(annotated.text, start, inlineOffset, sourceLineStarts)
        span.inlineStyle?.takeIf { hasSourceLine }?.let { authored ->
            val declaring = (authored.lineHeight as? InlineLineHeight.FontRelative)?.let {
                familyPaint(nativeStyleRanges(inlineFontSnapshotAnnotation(it.font, effective), effective, linkColor,
                    sourceFamily = inheritedFamily, familyRanges = listOf(NativeSourceFamilyRange(0, 1,
                        it.font.fontFamily, inlineFontSnapshotSpan(it.font).legacyFontFamily())),
                    legacyOwnerFamily = legacyOwnerFamily).single())
            }
            val empty = if (start == inlineOffset) familyPaint(nativeStyleRanges(
                inlineMetricOwnerAnnotation(span, effective), effective, linkColor, sourceFamily = inheritedFamily,
                familyRanges = listOf(NativeSourceFamilyRange(0, 1, span.fontFamily, span.legacyFontFamily())),
                legacyOwnerFamily = legacyOwnerFamily).single()) else null
            NativeInlineSourceRange(span, start, inlineOffset, declaring, empty)
        }
    }
    check(inlineOffset == annotated.length) { "Authored inline metric offsets must retain the original logical string" }
    val inlineParagraphCuts = if (inlineSources.isEmpty()) emptyList() else annotated.text.indices
        .filter { annotated.text[it] == '\n' }.map { it + 1 }
    val styles = if (noSourceLines) emptyList() else nativeStyleRanges(annotated, effective, linkColor,
        inlineSources.flatMap { listOf(it.start, it.end) } + inlineParagraphCuts, inheritedFamily, familyRanges,
        legacyOwnerFamily, sourceLineStarts)
    styles.forEach { familyPaint(it) }
    val basePaint = if (noSourceLines) TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 0f }
        else if (ownerFont == null) familyPaint(nativeStyleRanges(AnnotatedString(" "), effective, linkColor,
        sourceFamily = inheritedFamily, legacyOwnerFamily = legacyOwnerFamily).single()) else {
        val snapshot = ownerFont.snapshot
        if (snapshot.language.isNotEmpty() && nativeTableOwnerLanguageTag(snapshot.language) == null)
            familyFailure = NativeAbsoluteOwnerFontUnavailable
        if (ownerFont.style == null) familyFailure = "An unused declaring font cannot supply a source line."
        familyPaint(nativeStyleRanges(AnnotatedString(" "), ownerFont.style ?: effective, linkColor,
            sourceFamily = sourceFamily, familyRanges = listOf(NativeSourceFamilyRange(0, 1,
                snapshot.fontFamily, inlineFontSnapshotSpan(snapshot).legacyFontFamily()))).single())
    }
    // Cell typography owns the strut and the layout's default envelope, not child paints.
    // Complete independent owners already replace cell inheritance at their existing boundary.
    val cellState = LocalNativeContainerTextContext.current?.cellText.takeIf { ownerFont == null }
    val cellOwner = cellState?.ownerFont.takeUnless { noSourceLines || emptyInlineOwner }
    val cellOwnerPaint = cellOwner?.let { declaring ->
        val state = checkNotNull(cellState)
        when {
            state.ownerFontInvalidated -> {
                familyFailure = NativeCellOwnerFontChanged
                null
            }
            declaring.style == null || nativeTableOwnerLanguageTag(declaring.snapshot.language) == null -> {
                familyFailure = NativeCellOwnerFontUnavailable
                null
            }
            else -> familyPaint(nativeStyleRanges(AnnotatedString(" "), declaring.style, linkColor,
                familyRanges = listOf(NativeSourceFamilyRange(0, 1, declaring.snapshot.fontFamily, null)))
                .single()).apply {
                // Preserve the one resolved strut size through a potentially nonlinear sp conversion.
                textSize = checkNotNull(state.fontPixels)
            }
        }
    }
    val layoutPaint = cellOwnerPaint ?: basePaint
    val cellMetricRevision = cellOwner?.let {
        listOf(cellState, cellOwnerPaint?.typeface, cellOwnerPaint?.textSize)
    }
    val normalBodySize = MaterialTheme.typography.bodyLarge.fontSize
    val cssPixelTextZoom = LocalCssPixelTextZoom.current
    var inlineFailure: String? = when {
        ownerFont != null && ownerWrap != TextWrap.NoWrap -> "Absolute declaring font requires its complete no-wrap owner."
        sourceLineStarts != null && (prefix.isNotEmpty() || heading || headingActions.isNotEmpty()) ->
            "No-wrap marker or heading line ownership is unavailable."
        ownerFont != null && nativeLineHeight !is NativeLineHeightPolicy.Pixels ->
            "Absolute declaring line height is unavailable."
        spans.any { it.isUnsupportedAuthoredWhitespaceOwner() } ->
            "Authored inline whitespace effects require a retained collapsed source owner"
        else -> null
    }
    fun inlineLength(value: InlineComputedLength): Float {
        val magnitude = cellTextMetricPixels(kotlin.math.abs(value.value), value.fontScaleBasis,
            normalBodySize, density, cssPixelTextZoom)
        if (magnitude > TablePixelLimit) throw UnsupportedFloatLayout("Authored inline length exceeds native geometry")
        return if (value.value < 0f) -magnitude else magnitude
    }
    val inlineStyles = try {
        inlineSources.map { source ->
            val authored = checkNotNull(source.span.inlineStyle)
            val height = when (val value = authored.lineHeight) {
                null -> null
                is InlineLineHeight.Computed -> inlineLength(value.value)
                is InlineLineHeight.FontRelative -> (checkNotNull(source.declaringPaint).textSize.toDouble() * value.factor)
                    .let { used ->
                        if (!used.isFinite() || used > TablePixelLimit)
                            throw UnsupportedFloatLayout("Authored inline line height exceeds native geometry")
                        used.toFloat()
                    }
            }
            val shift = authored.baselineShift?.let { -inlineLength(it) }
            val thickness = authored.decoration?.thickness?.let {
                val used = it.value.toDouble() * if (it.unit == StyleLengthUnit.Px) density.density else bodyPixels
                if (!used.isFinite() || used > TablePixelLimit)
                    throw UnsupportedFloatLayout("Authored inline decoration exceeds native geometry")
                used.toFloat()
            }
            if (shift != null) {
                // TextPaint stores integer displacement; the retained metadata owns the exact
                // remainder for paint and all geometry. Never round the authored source value.
                styles.filter { it.start >= source.start && it.end <= source.end }.forEach {
                    it.paint.baselineShift = shift.toInt()
                }
                source.emptyPaint?.baselineShift = shift.toInt()
                source.declaringPaint?.baselineShift = shift.toInt()
            }
            NativeResolvedInlineStyle(source, height, shift, thickness)
        }
    } catch (failure: UnsupportedFloatLayout) {
        inlineFailure = failure.message ?: "Authored inline geometry is unavailable"
        emptyList()
    }
    val inlineRevision = inlineStyles.map { resolved ->
        val source = resolved.source
        listOf(source.span, resolved.height, resolved.shift, resolved.thickness,
            source.declaringPaint?.typeface, source.declaringPaint?.textSize, source.declaringPaint?.baselineShift,
            source.emptyPaint?.typeface, source.emptyPaint?.textSize, source.emptyPaint?.baselineShift)
    }
    val usesRunMetrics = ownerFont != null || cellOwner != null || nativeLineHeight != null || inlineStyles.any { it.height != null || it.shift != null }
    val prefixPaint = if (noSourceLines) TextPaint(basePaint) else familyPaint(nativeStyleRanges(
        AnnotatedString(" "), prefixStyle ?: effective, linkColor,
        sourceFamily = inheritedFamily.takeIf { prefix.isNotEmpty() }).single())
    val layoutUnavailable = familyFailure ?: paintUnavailable ?: inlineFailure
    val prefixWidth = if (prefix.isEmpty()) 0f else 28f * density.density
    val actionSize = 48f * density.density
    require(!authoredHeading || headingActions.size <= NativeHeadingCustomActionIds.size)
    val paintedHeadingActions = if (authoredHeading) emptyList() else headingActions
    val actionWidth = actionSize * paintedHeadingActions.size
    val insets = if (rtl) NativeTextInsets(right = indentPixels, extraRight = prefixWidth, extraLeft = actionWidth)
        else NativeTextInsets(left = indentPixels, extraLeft = prefixWidth, extraRight = actionWidth)
    fun actionBounds(geometry: NativeFloatGeometry, index: Int): RectF {
        val band = geometry.firstLineBand()
        val left = if (rtl) band.left - actionWidth + index * actionSize else band.right + index * actionSize
        return RectF(left, band.top, left + actionSize, band.top + actionSize)
    }
    fun paintAt(offset: Int) = TextPaint().apply { set(styles.firstOrNull { offset in it.start until it.end }?.paint ?: basePaint) }
    val owner = imageOwnerOverride ?: LocalInlineImageOwner.current ?: rememberInlineImageViewOwner(spans.mapNotNull { it.image }, media, settings, edition)
    spans.mapNotNull { it.image }.filter { it.staticPoster == null || figureImageActions }
        .distinctBy(::inlineImageAssetKey).forEach { image -> LaunchedEffect(owner, image) { owner.ensure(image) } }
    var details by remember { mutableStateOf<NativeImage?>(null) }
    val images = mutableListOf<NativeImage>()
    val imageDarkTheme = LocalReaderDarkTheme.current
    var offset = 0
    spans.forEachIndexed { id, span ->
        if (span.usesInlineDirectionIsolate()) offset++
        span.image?.let { image ->
            val bitmapColorFilter = rememberInlineImageColorFilter(image)
            check(annotated.text.getOrNull(offset) == '\ufffc') { "Compiled image offset drift" }
            val paint = paintAt(offset)
            val asset = if (image.staticPoster != null && !figureImageActions) InlineImageAssetState.LayoutUnavailable else
                owner.states[inlineImageAssetKey(image)] ?: if (settings.allowImages) InlineImageAssetState.Loading else InlineImageAssetState.Disabled
            val ready = asset as? InlineImageAssetState.Ready
            val dimensions = ready?.let { inlineImagePixels(image, it.originalWidth, it.originalHeight, density.density, it.mime) }
            val state = if (ready != null && dimensions == null) InlineImageAssetState.GeometryUnavailable(ready) else asset
            val occurrenceStyle = styles.firstOrNull { offset in it.start until it.end }
            val fallbackLayout = nativeFloatImageFallbackLayout(image, state, paint, basePaint,
                occurrenceStyle?.baselineShiftMultiplier ?: 0f, occurrenceStyle?.letterSpacingPixels)
            val side = (image.widthPx ?: image.heightPx)?.let {
                (it.toDouble() * density.density).coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat()
            } ?: paint.textSize.coerceAtLeast(1f)
            val pixels = fallbackLayout?.let { layout -> InlineImagePixels(
                (0 until layout.lineCount).maxOfOrNull { layout.getLineWidth(it) }?.coerceAtLeast(1f) ?: 1f,
                layout.height.coerceAtLeast(1).toFloat()) } ?: dimensions ?: InlineImagePixels(side, side)
            val borderWidth = if (image.border) density.density else 0f
            val outerPixels = inlineImageOuterPixels(pixels, image.border, density.density)
            val draw: (Canvas, RectF) -> Unit = { canvas, outer ->
                val rect = RectF(outer.left + borderWidth, outer.top + borderWidth,
                    outer.right - borderWidth, outer.bottom - borderWidth)
                when {
                    fallbackLayout != null -> { val saved = canvas.save(); canvas.translate(rect.left, rect.top)
                        canvas.clipRect(0f, 0f, rect.width(), rect.height()); fallbackLayout.draw(canvas); canvas.restoreToCount(saved) }
                    state is InlineImageAssetState.Ready -> canvas.drawBitmap(state.decoded.bitmap, null, rect,
                        Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply { colorFilter = bitmapColorFilter })
                    else -> { val marker = Paint(paint).apply { this.style = Paint.Style.STROKE; strokeWidth = 1f }
                        canvas.drawRect(rect, marker); canvas.drawLine(rect.left, rect.top, rect.right, rect.bottom, marker) }
                }
                if (image.border) {
                    val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        color = 0xffeaecf0.toInt(); this.style = Paint.Style.STROKE; strokeWidth = borderWidth
                    }
                    val half = borderWidth / 2f
                    canvas.drawRect(outer.left + half, outer.top + half, outer.right - half, outer.bottom - half, edge)
                }
            }
            // The unresolved marker strokes the content rectangle; its actual half-stroke
            // can extend outside an unbordered image. Ready/fallback pixels stay in their box.
            val markerOverflow = if (fallbackLayout == null && state !is InlineImageAssetState.Ready)
                (0.5f - borderWidth).coerceAtLeast(0f) else 0f
            val imageInk = NativeFloatBounds(-markerOverflow, -markerOverflow,
                outerPixels.width + markerOverflow, outerPixels.height + markerOverflow)
            images += NativeImage(id, offset, span, state, paint, outerPixels, imageInk, draw)
        }
        offset += if (span.image != null) 1 else if (span.kind == "line_break") 1 else span.text.length
        offset += span.trail.length
        if (span.usesInlineDirectionIsolate()) offset++
    }
    check(offset == annotated.length) { "Native context must retain the original logical string" }
    // Shape once per text/font request, then resize the immutable ink without reshaping it.
    val shapeKey = listOf(annotated, runs, effective, density.density, density.fontScale, inlineRevision, familyFailure, sourceFamily, familyRanges, legacyOwnerFamily, ownerFont, cellMetricRevision, sourceLineStarts,
        paintedLinks.filter { it.span.linkPaint != null }.map { it.start to it.end },
        styles.map { listOf(it.start, it.end, it.paint.typeface, it.paint.textSize, it.paint.color, it.paint.bgColor, it.paint.baselineShift) })
    val shaped by produceState<Pair<Any, Map<Int, NativeEgyptianSpanPreparation>>?>(null, shapeKey) {
        val result = linkedMapOf<Int, NativeEgyptianSpanPreparation>()
        for (run in if (replacementFamilyFailure) emptyList() else runs) {
            val paint = paintAt(run.start)
            styles.firstOrNull { run.start in it.start until it.end }?.let {
                paint.isFakeBoldText = it.bold
                if (it.italic) paint.textSkewX = -0.25f
            }
            result[run.start] = prepareNativeEgyptianSpan(context.applicationContext, run, paint,
                if (paint.ascent() == 0f) 0f else paint.baselineShift / paint.ascent(),
                paint.isUnderlineText && paintedLinks.none { it.span.linkPaint != null &&
                    it.start <= run.start && it.end >= run.end },
                paint.isStrikeThruText, paint.color, paint.bgColor.takeIf { it != 0 })
        }
        value = shapeKey to result
    }
    val prepared = shaped?.takeIf { it.first == shapeKey }?.second.orEmpty()
    val textState = when {
        runs.isNotEmpty() && prepared.size != runs.size -> "Loading Egyptian glyph layout"
        prepared.values.any { !it.available } -> "Egyptian glyph layout unavailable"
        else -> null
    }
    val direction = when (ownerDirection) {
        BidiResolvedDirection.Ltr -> TextDirectionHeuristics.LTR
        BidiResolvedDirection.Rtl -> TextDirectionHeuristics.RTL
        null -> nativeParagraphDirection(annotated, rtl, LocalCompiledTableTextDirection.current)
    }
    val nativeSource: ((Int) -> Spanned)? =
        if (runs.isNotEmpty() && prepared.size != runs.size) null else { width ->
                if (familyFailure != null) throw UnsupportedFloatLayout(checkNotNull(familyFailure))
                val native = SpannableString(annotated.text)
                if (ownerWrap != null && (native.isNotEmpty() || sourceLineStarts != null)) native.setSpan(
                    NativeAuthoredTextWrap(ownerWrap, inheritedOwner = true, sourceLineStarts = sourceLineStarts), 0, native.length,
                    if (native.isEmpty()) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                styles.forEach { native.setSpan(NativePaintSpan(it.paint, linkPaintAt(it.start, it.end)), it.start, it.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                val inlineParentPolicies = mutableListOf<Triple<Int, Int, NativeLineHeightPolicy>>()
                val paragraphStarts = listOf(0) + annotated.text.indices.filter {
                    annotated.text[it] == '\n' && (it + 1 < annotated.length || inlineSources.any { owner ->
                        owner.start == annotated.length && owner.end == owner.start
                    })
                }.map { it + 1 }
                paragraphStarts.forEachIndexed { index, start ->
                    if (sourceLineStarts != null && start !in sourceLineStarts) return@forEachIndexed
                    val end = paragraphStarts.getOrNull(index + 1) ?: annotated.length
                    val paragraphStyle = annotated.paragraphStyles.filter { it.start <= start && it.end >= end }
                        .fold(effective.toParagraphStyle()) { merged, range -> merged.merge(range.item) }
                    val paragraphRtl = direction.isRtl(annotated.text, start, end - start)
                    val alignment = when (paragraphStyle.textAlign) {
                        TextAlign.Center -> Layout.Alignment.ALIGN_CENTER
                        TextAlign.Left -> if (paragraphRtl) Layout.Alignment.ALIGN_OPPOSITE else Layout.Alignment.ALIGN_NORMAL
                        TextAlign.Right -> if (paragraphRtl) Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_OPPOSITE
                        TextAlign.End -> Layout.Alignment.ALIGN_OPPOSITE
                        else -> Layout.Alignment.ALIGN_NORMAL
                    }
                    native.setSpan(AlignmentSpan.Standard(alignment), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (!usesRunMetrics) {
                        val lineHeight = paragraphStyle.lineHeight
                        val height = if (lineHeight.isSp) with(density) { lineHeight.toPx() }
                            else if (lineHeight.isEm) basePaint.textSize * lineHeight.value else 0f
                        if (height.isFinite() && height > 0f) native.setSpan(NativeLineHeight(ceil(height).toInt()),
                            start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    } else {
                        // Container inheritance is already computed. An explicit paragraph override
                        // is a length at its own parent font; it must not become an inherited number.
                        val explicit = annotated.paragraphStyles.lastOrNull {
                            it.start <= start && it.end >= end &&
                                (it.item.lineHeight.isSp || it.item.lineHeight.isEm)
                        }?.item?.lineHeight
                        val inheritedPolicy = nativeLineHeight ?: when {
                            paragraphStyle.lineHeight.isSp -> NativeLineHeightPolicy.Pixels(with(density) { paragraphStyle.lineHeight.toPx() })
                            paragraphStyle.lineHeight.isEm -> NativeLineHeightPolicy.Pixels(basePaint.textSize * paragraphStyle.lineHeight.value)
                            else -> NativeLineHeightPolicy.Normal
                        }
                        val policy = when {
                            explicit?.isSp == true -> NativeLineHeightPolicy.Pixels(with(density) { explicit.toPx() })
                            explicit?.isEm == true -> NativeLineHeightPolicy.Pixels(basePaint.textSize * explicit.value)
                            else -> inheritedPolicy
                        }
                        inlineParentPolicies += Triple(start, end, policy)
                        native.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(layoutPaint), policy,
                            strut = true, includePrimaryInNormal = cellOwnerPaint != null),
                            start, end, if (start == end && (inlineSources.isNotEmpty() || cellOwnerPaint != null))
                                Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                        styles.forEach { run ->
                            val first = max(start, run.start)
                            val last = min(end, run.end)
                            if (first < last) {
                                // Images contribute their actual replaced box. Egyptian replacements
                                // remain text and retain the original style's primary-font strut.
                                val cuts = (listOf(first, last) + images.filter { it.offset in first until last }
                                    .flatMap { listOf(it.offset, it.offset + 1) }).distinct().sorted()
                                cuts.zipWithNext().filter { (a, b) -> a < b && images.none { it.offset == a } }
                                    .filterNot { (a, b) -> inlineStyles.any { authored ->
                                        (authored.height != null || authored.shift != null) &&
                                            authored.source.start <= a && authored.source.end >= b
                                    } }.forEach { (a, b) -> native.setSpan(NativeRunLineMetrics(
                                        NativePrimaryFontMetrics.from(run.paint), policy), a, b, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                            }
                        }
                    }
                }
                annotated.paragraphStyles.forEach { range ->
                    range.item.textIndent?.let { indent ->
                        fun pixels(value: androidx.compose.ui.unit.TextUnit) = if (value.isEm) value.value * basePaint.textSize
                            else if (value.isSp) with(density) { value.toPx() } else 0f
                        native.setSpan(LeadingMarginSpan.Standard(pixels(indent.firstLine).toInt(), pixels(indent.restLine).toInt()),
                            range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                }
                if (paintedHeadingActions.isNotEmpty() && native.isNotEmpty()) {
                    native.setSpan(NativeHeadingControlHeight(ceil(actionSize).toInt()), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (usesRunMetrics) native.setSpan(NativeLineMinimum(
                        NativePrimaryFontMetrics.from(basePaint), actionSize), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                paragraphGaps.forEach { (end, gapDp) -> if (end > 0) native.setSpan(object : LineHeightSpan {
                    override fun chooseHeight(text: CharSequence, start: Int, finish: Int, spanstartv: Int, v: Int, fm: Paint.FontMetricsInt) {
                        if (finish >= end) { val gap = ceil(gapDp * density.density).toInt(); fm.descent += gap; fm.bottom += gap }
                    }
                }, end - 1, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                if (usesRunMetrics) paragraphGaps.forEach { (end, gapDp) ->
                    if (end > 0) native.setSpan(NativeLineGap(ceil(gapDp * density.density)),
                        end - 1, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                runs.forEach { run ->
                    // The replacement owns its baseline and decoration; native TextLine must not apply them again.
                    val replacementPaint = paintAt(run.start).apply { baselineShift = 0; isUnderlineText = false; isStrikeThruText = false; bgColor = 0 }
                    native.setSpan(NativePaintSpan(replacementPaint), run.start, run.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    native.setSpan(prepared.getValue(run.start).spanForWidth(width.toFloat(), linkPaintAt(run.start, run.end)), run.start, run.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                images.forEach { image ->
                    val replacementPaint = paintAt(image.offset).apply { baselineShift = 0 }
                    native.setSpan(NativePaintSpan(replacementPaint), image.offset, image.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    native.setSpan(NativeInlineImageSpan(image), image.offset, image.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                inlineStyles.forEach { resolved ->
                    val source = resolved.source
                    val authored = checkNotNull(source.span.inlineStyle)
                    authored.wrap?.let { wrap ->
                        val textStart = source.start + if (source.span.usesInlineDirectionIsolate()) 1 else 0
                        val textEnd = textStart + source.span.text.length
                        if (textStart < source.start || textEnd > source.end || textStart >= textEnd)
                            throw UnsupportedFloatLayout("Authored wrap lost its exact source text range")
                        native.setSpan(NativeAuthoredTextWrap(wrap), textStart, textEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                    val ranges = if (source.start == source.end) listOf(Triple(source.start, source.end, checkNotNull(source.emptyPaint)))
                        else styles.filter { it.start >= source.start && it.end <= source.end }.map { Triple(it.start, it.end, it.paint) }
                    ranges.forEach { (start, end, paint) ->
                        val flags = if (start == end) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
                        val shift = resolved.shift ?: paint.baselineShift.toFloat()
                        if (resolved.height != null || resolved.shift != null) {
                            val primary = NativePrimaryFontMetrics.from(paint).copy(baselineShift = shift)
                            val declaring = source.declaringPaint?.let {
                                NativePrimaryFontMetrics.from(it).let { metrics ->
                                    if (resolved.shift == null) metrics else metrics.copy(baselineShift = shift)
                                }
                            }
                            val policy = resolved.height?.let { NativeLineHeightPolicy.Pixels(it) }
                                ?: inlineParentPolicies.lastOrNull { it.first <= start && it.second >= end }?.third
                                ?: NativeLineHeightPolicy.Normal
                            native.setSpan(NativeAuthoredInlineMetrics(primary, policy, declaring), start, end, flags)
                        }
                        resolved.shift?.let { native.setSpan(NativeAuthoredBaselineShift(it), start, end, flags) }
                        authored.decoration?.let { decoration ->
                            native.setSpan(NativeAuthoredUnderline(decoration.style,
                                decoration.color?.let { canonicalColorArgb(it)!!.toInt() }, resolved.thickness), start, end, flags)
                        }
                        authored.cursor?.let { native.setSpan(NativeAuthoredCursor(it), start, end, flags) }
                    }
                }
                native
        }
    val nativeNodes: (FloatTextGeometry) -> List<FloatInteractionNode> = { geometry ->
        if (sourceLineStarts?.isEmpty() == true) emptyList() else buildList {
                         annotated.getLinkAnnotations(0, annotated.length).forEachIndexed { index, range ->
                            val state = linkPaintAt(range.start, range.end)
                            val fragments = geometry.rectsForRange(range.start, range.end)
                            val ordinary = ordinaryPolicies[range.start to range.end]
                            val focus = if (ordinary != null) ordinaryLinkFocusPaint(ordinary,
                                nativeLinkFocusFragments(geometry, range.start, range.end, fragments), density.density, bodyPixels)
                            else captionScope?.takeIf { linkPaints.containsKey(range.start to range.end) }?.let { scope ->
                                figureLinkFocusPaint(scope.policy, nativeLinkFocusFragments(geometry,
                                    range.start, range.end, fragments), scope.density, scope.bodyPixels)
                            }
                            add(FloatInteractionNode(index, FloatInteractionKind.LINK, range.start, range.end,
                                fragments, annotated.subSequence(range.start, range.end), null,
                                 { when (val link = range.item) { is LinkAnnotation.Clickable -> link.linkInteractionListener?.onClick(link) ?: onLink(EntryLink(link.tag)); is LinkAnnotation.Url -> uri.openUri(link.url) }
                                    if (missingLinkPaint != null) onMissingLinkActivated()
                                    else state?.actionIdentity?.target?.let {
                                        (if (ordinary != null) visits else captionScope?.visits)?.record(it)
                                    }
                                }, missingLinkPaint = state, focusPaint = focus))
                        }
                        val firstImage = annotated.getLinkAnnotations(0, annotated.length).size
                        images.forEach { image ->
                            val model = image.span.image!!
                            val url = inlineImageLinkUrl(image.span, edition)
                            val unresolved = image.span.kind == "link" && image.span.target.startsWith("File:") && url == null
                            val click: (() -> Unit)? = when {
                                url != null -> { { uri.openUri(url) } }
                                image.span.kind == "link" && !unresolved -> { { onLink(image.span.entryLink()) } }
                                else -> null
                            }
                            val advice = image.span.imageTooltip
                            val hasDetails = !advice.isNullOrEmpty() || image.state is InlineImageAssetState.Ready ||
                                image.state is InlineImageAssetState.GeometryUnavailable || image.state == InlineImageAssetState.Failed
                            val accessibilityLabel = inlineImageAccessibilityLabel(model, when {
                                click != null -> "Open image link"
                                hasDetails -> "Image details"
                                else -> null
                            })
                            add(FloatInteractionNode(firstImage + image.id, FloatInteractionKind.IMAGE, image.offset, image.offset + 1,
                                geometry.rectsForRange(image.offset, image.offset + 1), accessibilityLabel, advice, click,
                                imageStatus(image.state) + if (unresolved) " Image link source unavailable" else "",
                                if (hasDetails) ({ details = image }) else null))
                        }
                        val afterImages = firstImage + spans.size
                        if (prefix.isNotEmpty()) {
                            val band = (geometry as NativeFloatGeometry).firstLineBand()
                            val markerBounds = if (rtl) RectF(band.right, band.top, band.right + prefixWidth, band.bottom)
                                else RectF(band.left - prefixWidth, band.top, band.left, band.bottom)
                            add(FloatInteractionNode(afterImages, FloatInteractionKind.MARKER, 0, 0,
                                listOf(markerBounds), prefix, null, null))
                        }
                        if (heading && annotated.isNotEmpty()) add(FloatInteractionNode(afterImages + 1, FloatInteractionKind.HEADING,
                            0, annotated.length, geometry.rectsForRange(0, annotated.length),
                            if (authoredHeading) headingLabel ?: annotated.text else annotated.text, null, null,
                            stateDescription = if (authoredHeading) headingActions.firstOrNull()?.let {
                                if (it.collapsed) "Collapsed" else "Expanded"
                            } else null,
                            customActions = if (authoredHeading) headingActions else emptyList()))
                        paintedHeadingActions.forEachIndexed { index, action ->
                            add(FloatInteractionNode(afterImages + 2 + index, FloatInteractionKind.CONTROL, 0, annotated.length,
                                listOf(actionBounds(geometry as NativeFloatGeometry, index)), action.label, null, action.onClick,
                                if (action.collapsed) "Collapsed" else "Expanded"))
                        }
    }.let { nodes ->
        // The nonpainting semantic heading must not cover its source-link hit targets.
        if (!authoredHeading) nodes else nodes.filter { it.kind == FloatInteractionKind.HEADING } +
            nodes.filter { it.kind != FloatInteractionKind.HEADING }
    } }
    val factory: ((Int, List<NativeFloatExclusion>, Boolean) -> NativeFloatGeometry)? =
        nativeSource?.let { source -> { width, carried, requireDrained ->
                if (layoutUnavailable != null) throw UnsupportedFloatLayout(layoutUnavailable)
                val native = source(width)
                val floats = emptyList<NativeFloatOccurrence>()
                val marker = if (prefix.isEmpty()) null else NativeMarkerText(prefix, prefixPaint)
                NativeFloatGeometry.build(native, layoutPaint, width, floats,
                    textDirection = direction,
                    requireDrainedAtBoundary = requireDrained, carriedExclusions = carried, insets = insets,
                    decoration = { canvas, geometry ->
                        val band = geometry.firstLineBand()
                        if (marker != null) {
                            val x = if (rtl) band.right + prefixWidth else band.left - prefixWidth
                            marker.paint(canvas, x, band.top - prefixPaint.ascent(), rightAligned = rtl)
                        }
                        val icon = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = linkColor.toArgb(); this.style = Paint.Style.STROKE; strokeWidth = 2f * density.density }
                        paintedHeadingActions.forEachIndexed { index, action ->
                            val bounds = actionBounds(geometry, index); val cx = bounds.centerX(); val cy = bounds.centerY(); val d = 5f * density.density
                            if (index > 0) {
                                for (line in -1..1) canvas.drawLine(cx - d, cy + line * d, cx + d, cy + line * d, icon)
                            } else if (action.collapsed) {
                                val sign = if (rtl) -1f else 1f
                                canvas.drawLine(cx - sign * d, cy - d, cx + sign * d, cy, icon)
                                canvas.drawLine(cx + sign * d, cy, cx - sign * d, cy + d, icon)
                            } else {
                                canvas.drawLine(cx - d, cy - d, cx, cy + d, icon); canvas.drawLine(cx, cy + d, cx + d, cy - d, icon)
                            }
                        }
                    },
                    decorationBounds = { geometry ->
                        val band = geometry.firstLineBand()
                        var bounds: NativeFloatBounds? = null
                        if (marker != null) {
                            val x = if (rtl) band.right + prefixWidth else band.left - prefixWidth
                            bounds = marker.bounds(x, band.top - prefixPaint.ascent(), rightAligned = rtl)
                        }
                        // Every segment stays within d plus its real half-stroke; control
                        // hit boxes are independent and remain the full action rectangles.
                        val d = 5f * density.density
                        val halfStroke = density.density
                        paintedHeadingActions.indices.forEach { index ->
                            val box = actionBounds(geometry, index)
                            bounds = enclosingBounds(bounds, NativeFloatBounds(
                                box.centerX() - d - halfStroke, box.centerY() - d - halfStroke,
                                box.centerX() + d + halfStroke, box.centerY() + d + halfStroke))
                        }
                        bounds
                    },
                    nodeFactory = nativeNodes)


        } }
    val revision = remember(spans, annotated, effective, shapeKey, prepared, images.map { it.state }, imageDarkTheme, density, rtl, paragraphGaps, containAtEnd, insets, prefix, prefixStyle, heading, headingActions, nativeLineHeight, inlineRevision, layoutUnavailable, sourceFamily, authoredHeading, ownerDirection, headingLabel, ownerWrap, ownerFont, cellMetricRevision, sourceLineStarts) { Any() }
    return PreparedNativeFloatText(annotated.text, layoutUnavailable ?: textState, revision, factory, {
        val detail = details
        DropdownMenu(expanded = detail != null, onDismissRequest = { details = null }) {
            if (detail != null) {
                detail.span.imageTooltip?.takeIf { it.isNotEmpty() }?.let { DropdownMenuItem(text = { Text(it) }, onClick = {}, enabled = false) }
                if (detail.state == InlineImageAssetState.Failed || detail.state is InlineImageAssetState.GeometryUnavailable) DropdownMenuItem(text = { Text("Retry image") }, onClick = {
                    details = null; owner.retry(detail.span.image!!)
                })
                if (detail.state is InlineImageAssetState.GeometryUnavailable) DropdownMenuItem(text = { Text("Image size unavailable") }, onClick = {}, enabled = false)
                val ready = when (val state = detail.state) { is InlineImageAssetState.Ready -> state; is InlineImageAssetState.GeometryUnavailable -> state.resource; else -> null }
                ready?.let { asset ->
                    asset.credit.takeIf { it.isNotEmpty() }?.let { DropdownMenuItem(text = { Text(it) }, onClick = {}, enabled = false) }
                    DropdownMenuItem(text = { Text("Source and licence") }, onClick = { details = null; uri.openUri(asset.source) })
                }
            }
        }
    }, nativeSource?.takeIf { layoutUnavailable == null }?.let { NativePreparedText(layoutPaint, it, nativeNodes, direction,
        insets.left + insets.right + insets.extraLeft + insets.extraRight, breakWordMinimum = authoredHeading && ownerWrap == null) }, fallback = {
        // The normal float owner already holds this image state. Failure UI reuses it.
        CompositionLocalProvider(LocalInlineImageOwner provides owner, LocalOrdinaryLinkPaintNative provides false,
            LocalAuthoredInlineNative provides false) {
            Column(Modifier.padding(start = with(density) { indentPixels.toDp() })) {
                Row {
                    if (prefix.isNotEmpty()) Text(prefix, Modifier.width(with(density) { prefixWidth.toDp() }), style = prefixStyle ?: effective)
                    StyledText(spans, style = style, onLink = onLink, preserveWhitespace = ownerFont != null || authoredHeading || hasInlineFamily || sourceFamily is ContainerFontFamily.Stack)
                }
                if (!authoredHeading) headingActions.forEach { action -> TextButton(onClick = action.onClick) { Text(action.label) } }
            }
        }
    }, ordinaryLinkPaintRevision = ordinaryPaintRevision, emptyInlineOwner = emptyInlineOwner)

}

/** Public native paragraph heuristic retains authored paragraph direction without inserting isolates. */
private fun nativeParagraphDirection(text: AnnotatedString, fallbackRtl: Boolean,
    tableDirection: TableContainingDirection?): TextDirectionHeuristic {
    val fallback = when (tableDirection) {
        TableContainingDirection.Ltr -> TextDirectionHeuristics.LTR
        TableContainingDirection.Rtl -> TextDirectionHeuristics.RTL
        null -> if (fallbackRtl) TextDirectionHeuristics.FIRSTSTRONG_RTL else TextDirectionHeuristics.FIRSTSTRONG_LTR
    }
    val starts = listOf(0) + text.text.indices.filter { text.text[it] == '\n' && it + 1 < text.length }.map { it + 1 }
    val policies = starts.map { start ->
        when (text.paragraphStyles.lastOrNull { start >= it.start && start < it.end }?.item?.textDirection) {
            TextDirection.Ltr -> TextDirectionHeuristics.LTR
            TextDirection.Rtl -> TextDirectionHeuristics.RTL
            TextDirection.ContentOrLtr -> TextDirectionHeuristics.FIRSTSTRONG_LTR
            TextDirection.ContentOrRtl -> TextDirectionHeuristics.FIRSTSTRONG_RTL
            else -> fallback
        }
    }.distinct()
    // Public StaticLayout calls the heuristic with a paragraph-local copied buffer (offset zero).
    // Never guess a global range from that buffer. Separate semantic blocks already get independent
    // factories; mixed explicit direction policies inside one compiled block need further splitting.
    if (policies.size != 1) throw UnsupportedFloatLayout("Mixed authored paragraph direction policies in one floated block")
    return policies.single()
}

private class NativeHeadingControlHeight(private val minimum: Int) : LineHeightSpan {
    override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int, v: Int, fm: Paint.FontMetricsInt) {
        if (start != 0) return
        val extra = (minimum - (fm.descent - fm.ascent)).coerceAtLeast(0)
        fm.ascent -= (extra + 1) / 2
        fm.descent += extra / 2
        fm.top = min(fm.top, fm.ascent)
        fm.bottom = max(fm.bottom, fm.descent)
    }
}

private class NativeLineHeight(private val height: Int) : LineHeightSpan {
    override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int, v: Int, fm: Paint.FontMetricsInt) {
        val natural = fm.descent - fm.ascent
        if (natural <= 0) return
        val used = max(height, natural) // Authored line height cannot crop reserved image/Egyptian ink.
        val descent = ceil(used.toDouble() * fm.descent / natural).toInt()
        fm.descent = descent; fm.ascent = descent - used
        fm.top = fm.ascent; fm.bottom = fm.descent
    }
}

internal data class PreparedNativeFloatText(
    val text: CharSequence, val stateDescription: String?, val revision: Any,
    val geometry: ((Int, List<NativeFloatExclusion>, Boolean) -> NativeFloatGeometry)?,
    val menu: @Composable () -> Unit,
    val native: NativePreparedText? = null,
    val fallback: @Composable () -> Unit,
    /** Only source ordinary links contribute; interaction flags remain draw-only. */
    val ordinaryLinkPaintRevision: Any? = null,
    val emptyInlineOwner: Boolean = false,
)

/** Styled source and actions, before paragraph shaping. Anonymous owners shape this source once. */
internal data class NativePreparedText(
    val paint: TextPaint,
    val source: (Int) -> Spanned,
    val nodes: (FloatTextGeometry) -> List<FloatInteractionNode>,
    val direction: TextDirectionHeuristic,
    val horizontalInsets: Float = 0f,
    val breakWordMinimum: Boolean = false,
)
