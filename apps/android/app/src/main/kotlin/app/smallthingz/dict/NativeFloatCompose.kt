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

/** Source identity survives remeasure, but equal-data replacement is a new action occurrence. */
private class NativeActionGroupIdentity(private val range: RubyTextRange) {
    override fun equals(other: Any?): Boolean = other is NativeActionGroupIdentity &&
        range.span === other.range.span && range.path == other.range.path &&
        range.start == other.range.start && range.end == other.range.end
    override fun hashCode(): Int = 31 * (31 * (31 * System.identityHashCode(range.span) +
        range.path.hashCode()) + range.start) + range.end
}
private class NativeCitationOccurrenceIdentity(private val span: Span, private val start: Int, private val end: Int) {
    override fun equals(other: Any?): Boolean = other is NativeCitationOccurrenceIdentity &&
        span === other.span && start == other.start && end == other.end
    override fun hashCode(): Int = 31 * (31 * System.identityHashCode(span) + start) + end
}
private data class NativeTextActionRange(val start: Int, val end: Int, val item: LinkAnnotation?,
    val group: RubyTextRange? = null)

internal data class NativeHeadingAction(val label: String, val collapsed: Boolean, val onClick: () -> Unit)

private data class NativeStyleRange(val start: Int, val end: Int, val paint: TextPaint, val bold: Boolean, val italic: Boolean,
    val baselineShiftMultiplier: Float, val letterSpacingPixels: Float?, val familyFailure: String? = null)
private data class NativeInlineSourceRange(val span: Span, val start: Int, val end: Int,
    val declaringPaint: TextPaint?, val emptyPaint: TextPaint?, val rubyParentPath: String? = null, val clippedChild: Boolean = false)
private data class NativeResolvedInlineStyle(val source: NativeInlineSourceRange,
    val height: Float?, val shift: Float?, val thickness: Float?)
private class NativePaintSpan(private val value: TextPaint, private val missingLink: NativeMissingLinkPaint? = null,
    private val groupAction: Boolean = false) : MetricAffectingSpan(), NativeMayUnderline, NativeInlineSafePaintSpan {
    override val mayUnderline: Boolean get() = (!groupAction && missingLink != null) || value.isUnderlineText
    override fun updateMeasureState(paint: TextPaint) { paint.set(value) }
    override fun updateDrawState(paint: TextPaint) {
        paint.set(value)
        missingLink?.appearance()?.let {
            paint.color = it.color
            // The declaring group paints its own underline across both edges once.
            paint.isUnderlineText = if (groupAction) value.isUnderlineText else it.underline
        }
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
    letterSpacingPixels: Float? = null, knownWidth: Float? = null): StaticLayout? {
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
    return StaticLayout.Builder.obtain(alt, 0, alt.length, fallbackPaint,
        knownWidth?.let { ceil(it).toInt().coerceAtLeast(1) } ?: MaxComputedFontPixels.toInt())
        .setIncludePad(true).build()
}

private data class NativeImage(
    val id: Int, val offset: Int, val span: Span, val state: InlineImageAssetState,
    val paint: TextPaint, val pixels: InlineImagePixels, val ink: NativeFloatBounds, val fallbackWidth: Float?,
    val normalBodyPixels: Float, val imagePixelDensity: Float,
    val draw: (Canvas, RectF) -> Unit,
)

private data class NativeImageActions(val onClick: (() -> Unit)?, val onDetails: () -> Unit)

private class NativeInlineImageSpan(private val image: NativeImage) : ReplacementSpan(), NativeFloatInlineImage, NativeNoWrapInlineImage, NativeAlignedImageSelection {
    override val nativeImageId: Int get() = image.id
    override val nativeImageSourceOffset: Int get() = image.offset
    override val nativeImageWidth: Float get() = image.pixels.width
    override val nativeImageHeight: Float get() = image.pixels.height
    override val nativeImageInkBounds: NativeFloatBounds get() = image.ink
    override val nativeImageOccurrence: NativeImageOccurrencePlacement? get() =
        nativeImageOccurrencePlacement(image.span.image?.occurrenceLayout, image.normalBodyPixels, image.imagePixelDensity)
    override fun drawNativeImage(canvas: Canvas, outer: RectF) = image.draw(canvas, outer)
    override val nativeImageSelectionBounds: NativeFloatBounds? get() =
        if (image.span.image?.verticalAlign == null && image.span.linkPaint == null) null else nativeUsedMetrics.let {
            NativeFloatBounds(0f, it.top, image.pixels.width, it.bottom)
        }
    override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds =
        image.ink.translated(0f, nativeUsedMetrics.top)
    override val nativeUsedMetrics: NativeUsedLineMetrics get() {
        val metrics = image.paint.fontMetricsInt
        val bounds = Rect(); image.paint.getTextBounds("x", 0, 1, bounds)
        val top = inlineImageInkTop(InlineImageFontMetrics(metrics.ascent, metrics.descent,
            bounds.height().toFloat(), image.paint.baselineShift), image.pixels.height, image.span.image?.verticalAlign)
        return NativeUsedLineMetrics(top, top + image.pixels.height)
    }
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        if (image.span.image?.occurrenceLayout != null)
            throw UnsupportedFloatLayout("Positioned image requires native Float row measurement")
        val metrics = image.paint.fontMetricsInt
        val bounds = Rect(); image.paint.getTextBounds("x", 0, 1, bounds)
        val top = inlineImageInkTop(InlineImageFontMetrics(metrics.ascent, metrics.descent, bounds.height().toFloat(), image.paint.baselineShift), image.pixels.height, image.span.image?.verticalAlign)
        fm?.let { it.ascent = min(metrics.ascent, kotlin.math.floor(top).toInt()); it.top = it.ascent
            it.descent = max(metrics.descent, ceil(top + image.pixels.height).toInt()); it.bottom = it.descent }
        return ceil(image.pixels.width).toInt()
    }
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        if (image.span.image?.occurrenceLayout != null)
            throw UnsupportedFloatLayout("Positioned image requires native Float row paint")
        val metrics = image.paint.fontMetricsInt
        val bounds = Rect(); image.paint.getTextBounds("x", 0, 1, bounds)
        val inkTop = y + inlineImageInkTop(InlineImageFontMetrics(metrics.ascent, metrics.descent,
            bounds.height().toFloat(), image.paint.baselineShift), image.pixels.height, image.span.image?.verticalAlign)
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
    rubyWeight: FontWeight? = null,
    referenceBacklink: ReferenceBacklink? = null,
    referenceLayoutBacklink: ReferenceBacklink? = null, outsideReferenceMarker: Boolean = false,
    staticInlineParent: NativeStaticInlineParent? = null,
    terminalFallback: Boolean = false,
    clippedAbsoluteScope: NativeClippedAbsoluteCoordinateScope? = LocalNativeClippedAbsoluteCoordinateScope.current,
): PreparedNativeFloatText {
    require(referenceLayoutBacklink == null || referenceBacklink == null && outsideReferenceMarker &&
        spans.firstOrNull() === referenceLayoutBacklink.span &&
        spans.count { it.isQualifiedCitationBacklink } == 1) { "Invalid compiled reference paragraph prefix" }
    require(!outsideReferenceMarker || referenceLayoutBacklink != null && prefix.isNotEmpty()) {
        "Outside reference marker requires its compiled paragraph owner"
    }
    val scopedBacklink = referenceBacklink ?: referenceLayoutBacklink
    val context = LocalContext.current
    val density = LocalDensity.current
    val uri = LocalUriHandler.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val effective = LocalTextStyle.current.merge(style)
    val ruby = rubyStyledTextContexts(spans, rubyWeight, effective)
    val visibleSpans = ruby?.leaves?.map { checkNotNull(it.range.span) } ?: spans
    val clippedRanges = ruby?.projection?.ranges.orEmpty().filter { it.role == RubyTextRole.ClippedAbsolute }
    val nativeAnnotation = if (clippedRanges.isEmpty()) annotated else
        rubyStyledTextAnnotation(checkNotNull(ruby), rubyWeight, onLink, measureClippedChildren = true)
    check(nativeAnnotation.text == annotated.text) { "Clipped measurement must preserve the original UTF-16 source" }
    fun clippedLeaf(index: Int): Boolean = ruby?.leaves?.get(index)?.range?.role == RubyTextRole.ClippedText
    val paintedSpans = visibleSpans.filterIndexed { index, _ -> !clippedLeaf(index) }
    val clippedOwners = clippedRanges.associate { range ->
        range.path to remember(NativeActionGroupIdentity(range)) { NativeClippedAbsoluteOwner(checkNotNull(range.span), range.path) }
    }
    val clippedRunOverlap = runs.any { run -> clippedRanges.any { run.start < it.end && run.end > it.start } &&
        clippedRanges.none { run.start >= it.start && run.end <= it.end } }
    val nativeRuns = runs.filter { run -> clippedRanges.none { run.start < it.end && run.end > it.start } }
    check(ruby == null || ruby.projection.text == annotated.text) { "Ruby annotations must retain original UTF-16 offsets" }
    fun sourceLength(span: Span): Int = if (ruby == null) listOf(span).nativeLogicalLength() else
        (if (span.image != null || span.kind == "line_break") 1 else span.text.length) + span.trail.length
    fun hasDirectionControls(span: Span): Boolean = ruby == null && span.usesInlineDirectionIsolate()
    val rubyGaps = ruby?.projection?.ranges.orEmpty().filter {
        it.role == RubyTextRole.SegmentGap || it.role == RubyTextRole.BaseGap || it.role == RubyTextRole.AnnotationGap
    }
    val rubyOwnerRanges = ruby?.projection?.ranges.orEmpty().filter { it.role == RubyTextRole.Owner }
    val paddingRanges = ruby?.projection?.ranges.orEmpty().filter { it.role == RubyTextRole.PaddingGroup }
    val paddingActions = paddingRanges.filter { range -> checkNotNull(range.span).let {
        it.hasInternalAction() || externalLinkUrl(it) != null
    } }
    val boxRanges = ruby?.projection?.ranges.orEmpty().filter { it.role == RubyTextRole.BoxGroup }
    val boxOwners = boxRanges.associate { range ->
        range.path to remember(NativeActionGroupIdentity(range)) { NativeInlineBoxOwner(checkNotNull(range.span), range.path) }
    }
    val actionGroupRanges = ruby?.projection?.ranges.orEmpty().filter { range ->
        range.role == RubyTextRole.ActionGroup || range.role in setOf(RubyTextRole.BoxGroup, RubyTextRole.ClippedAbsolute) && checkNotNull(range.span).let {
            // Keep declared ownership even when the existing native target check must refuse it.
            it.kind == "link" || it.kind == "external_link"
        }
    }
    val actionGroupOwners = actionGroupRanges.associate { range ->
        range.path to remember(NativeActionGroupIdentity(range)) { NativeInlineActionOwner(checkNotNull(range.span), range.path) }
    }
    val groupActions = paddingActions + actionGroupRanges
    val linkAnnotations = annotated.getLinkAnnotations(0, annotated.length).let { links ->
        if (paddingRanges.isEmpty() && actionGroupRanges.isEmpty()) links else links.sortedWith(compareBy({ it.start }, { it.end }))
    }
    val nativeLinks = buildList {
        linkAnnotations.forEach { link -> add(NativeTextActionRange(link.start, link.end, link.item,
            actionGroupRanges.singleOrNull { it.start == link.start && it.end == link.end })) }
        // Empty source actions retain their occurrence and declaring geometry without a LinkAnnotation or character.
        actionGroupRanges.filter { it.start == it.end }.forEach { add(NativeTextActionRange(it.start, it.end, null, it)) }
    }.let { links -> if (actionGroupRanges.isEmpty()) links else links.sortedWith(compareBy(
        { it.start }, { it.end }, { it.group?.let { group -> actionGroupRanges.indexOf(group) } ?: -1 })) }
    val paintedSourceRanges = ruby?.let { contexts ->
        if (groupActions.isEmpty()) contexts.leaves.map { it.range }
        else (contexts.leaves.map { it.range } + groupActions).sortedWith(compareBy({ it.start }, { it.path }))
    }.orEmpty()
    val citationSourceRanges = ruby?.leaves?.mapIndexedNotNull { index, leaf ->
        leaf.range.span?.takeIf { it.citationMarker != null || referenceLayoutBacklink?.span === it }?.let {
            NativeCaptionLinkRange(index, it, leaf.range.start, leaf.range.end)
        }
    } ?: nativeCaptionLinkRanges(visibleSpans).filter { scopedBacklink?.span === it.span }
    val citationOwners = citationSourceRanges.associate { range ->
        (range.start to range.end) to remember(NativeCitationOccurrenceIdentity(range.span, range.start, range.end)) { Any() }
    }
    val paragraphBreaks = annotated.text.indices.filter { offset ->
        annotated.text[offset] == '\n' && rubyGaps.none { offset in it.start until it.end }
    }
    require(effective.fontSize.isSp)
    val captionScope = LocalFigureCaptionLinkScope.current.takeIf { !figureImageActions && missingLinkPaint == null }
    val captionOwner = remember { Any() }
    val visits = LocalMissingLinkVisits.current ?: remember { MissingLinkVisits() }
    val documentTitle = LocalMissingLinkDocument.current
    val documentOwner = LocalMissingLinkOwner.current ?: captionOwner
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val citationTargetAnchor = LocalNativeCitationTargetAnchor.current?.takeIf { anchor ->
        citationSourceRanges.any { it.span.citationMarker?.anchor == anchor }
    }
    fun citationTarget(span: Span): CitationTargetStyle? = span.citationMarker?.takeIf {
        it.anchor == citationTargetAnchor
    }?.targetStyle
    fun selectedLinkPolicy(span: Span): LinkPaint? = citationTarget(span)?.paint ?: span.linkPaint
    val citationPaintUnavailable = NativeOrdinaryLinkPaintUnavailable.takeIf { paintedSpans.any { span ->
        span.citationMarker != null && !validCitationMarkerSpan(span) ||
            span.linkPaint != null && span.entryLink().local &&
                !(span.citationMarker != null && validCitationMarkerSpan(span) ||
                    scopedBacklink?.span === span && validCitationSpanLinkPaint(span))
    } }
    val paintUnavailable = citationPaintUnavailable ?: ordinaryLinkPaintUnavailable(paintedSpans, edition)
        ?: NativeOrdinaryLinkPaintUnavailable.takeIf { paddingRanges.any {
            it.span?.linkPaint != null && (it.start == it.end || it !in paddingActions)
        } } ?: "Inline action group source action is unavailable".takeIf { actionGroupRanges.any {
            val span = checkNotNull(it.span)
            !span.hasInternalAction() && externalLinkUrl(span) == null
        } }
    val paintedLinks = remember(visibleSpans, captionScope, ruby?.projection, actionGroupOwners, citationOwners) {
        if (captionScope == null && visibleSpans.none { it.linkPaint != null } &&
            groupActions.none { it.span?.linkPaint != null }) emptyList()
        else (ruby?.let {
            paintedSourceRanges.mapIndexedNotNull { index, range ->
                val span = checkNotNull(range.span)
                if ((range.start < range.end || range.path in actionGroupOwners) && span.image == null &&
                    (span.hasInternalAction() || externalLinkUrl(span) != null))
                    NativeCaptionLinkRange(index, span, range.start, range.end) else null
            }
        } ?: nativeCaptionLinkRanges(visibleSpans)).filter { it.span.linkPaint != null || captionScope != null }
    }
    val ordinaryPolicies = paintedLinks.associate { (it.start to it.end) to selectedLinkPolicy(it.span) }
    val paintedStates = paintedLinks.map { range ->
        val ordinary = selectedLinkPolicy(range.span)
        val scope = captionScope.takeIf { ordinary == null }
        val target = missingLinkTarget(range.span, edition,
            if (ordinary != null) documentTitle else checkNotNull(scope).documentTitle)
        val identity = MissingLinkActionIdentity(if (ordinary != null) documentOwner else checkNotNull(scope).owner, target,
            citationOwners[range.start to range.end]
                ?: paintedSourceRanges.getOrNull(range.index)?.let { actionGroupOwners[it.path] }
                ?: NativeLinkOccurrenceIdentity(captionOwner, range.index, range.start, range.end, range.span))
        val visited = (if (ordinary != null) visits else checkNotNull(scope).visits).contains(target)
        // Span.underline is only the ordinary normal-state checksum. Existing Figure owners
        // retain their independent child decoration and original six-state selection.
        val authoredUnderline = ordinary == null && (range.span.underline ||
            TextDecoration.Underline in (effective.textDecoration ?: TextDecoration.None))
        val state = remember(ordinary, scope?.policy, visited, identity, authoredUnderline) {
            if (ordinary != null) NativeMissingLinkPaint(ordinary, visited, identity)
            else NativeMissingLinkPaint(checkNotNull(scope).policy, visited, authoredUnderline, identity)
        }
        range to state
    }
    val linkPaints = paintedStates.associate { (range, state) -> (range.start to range.end) to state }
    val actionGroupPaints = paintedStates.mapNotNull { (range, state) ->
        paintedSourceRanges.getOrNull(range.index)?.takeIf { it.path in actionGroupOwners }?.let { it.path to state }
    }.toMap()
    val ordinaryPaintRevision = paintedStates.filter { it.first.span.linkPaint != null }
        .map { it.second }.takeIf { it.isNotEmpty() }
    fun linkPaintAt(start: Int, end: Int): NativeMissingLinkPaint? = missingLinkPaint ?: linkPaints.entries
        .firstOrNull { (range, _) -> range.first <= start && range.second >= end }?.value
    fun groupPaintAt(range: RubyTextRange): NativeMissingLinkPaint? = if (range.path in actionGroupOwners)
        missingLinkPaint ?: actionGroupPaints[range.path] else linkPaintAt(range.start, range.end)
    val citationCallbacks = linkedMapOf<Pair<Int, Int>, () -> Unit>()
    for (range in citationSourceRanges) {
        val state = linkPaintAt(range.start, range.end)
        val activate = rememberUpdatedState<() -> Unit> {
            onLink(range.span.entryLink())
            if (missingLinkPaint != null) onMissingLinkActivated()
            else state?.actionIdentity?.target?.let { visits.record(it) }
        }
        citationCallbacks[range.start to range.end] = remember(citationOwners.getValue(range.start to range.end)) {
            { activate.value() }
        }
    }
    val actionGroupCallbacks = linkedMapOf<String, () -> Unit>()
    for (range in actionGroupRanges) {
        val span = checkNotNull(range.span)
        val state = groupPaintAt(range)
        val activate = rememberUpdatedState<() -> Unit> {
            if (span.hasInternalAction()) onLink(span.entryLink()) else externalLinkUrl(span)?.let(uri::openUri)
            if (missingLinkPaint != null) onMissingLinkActivated()
            else state?.actionIdentity?.target?.let {
                (if (span.linkPaint != null) visits else captionScope?.visits)?.record(it)
            }
        }
        actionGroupCallbacks[range.path] = remember(actionGroupOwners.getValue(range.path)) { { activate.value() } }
    }
    var familyOffset = 0
    val familyRanges = visibleSpans.mapIndexed { index, span ->
        val start = familyOffset
        familyOffset += sourceLength(span)
        val inherited = ruby?.leaves?.get(index)
        NativeSourceFamilyRange(start, familyOffset, span.fontFamily ?: inherited?.sourceFamily,
            span.legacyFontFamily() ?: inherited?.legacyFamily.takeIf { span.fontFamily == null })
    }
    check(familyOffset == annotated.length) { "Authored family offsets must retain the original logical string" }
    val hasInlineFamily = paintedSpans.hasAuthoredFontFamily()
    val sourceLineStarts = if (ownerWrap != TextWrap.NoWrap) null
        else if (ruby == null) nativeNoWrapSourceLineStarts(visibleSpans) else buildSet {
            // V supplies an actual declaring metric point, not a synthetic hard break or glyph.
            if (annotated.isEmpty() && actionGroupRanges.isNotEmpty()) add(0)
            var paragraphStart = 0
            annotated.text.indices.forEach { offset ->
                add(paragraphStart)
                if (offset in paragraphBreaks) paragraphStart = offset + 1
            }
        }.toList()
    fun sourceRangeHasLine(start: Int, end: Int): Boolean {
        val starts = sourceLineStarts ?: return true
        if (ruby == null) return nativeSourceRangeHasLine(annotated.text, start, end, starts)
        val paragraphStart = paragraphBreaks.lastOrNull { it < start }?.let { it + 1 } ?: 0
        return paragraphStart in starts || starts.any { it > start && it < end }
    }
    val noSourceLines = sourceLineStarts?.isEmpty() == true
    val emptyInlineOwner = actionGroupRanges.isEmpty() && (if (sourceLineStarts != null) sourceLineStarts.isEmpty() &&
        prefix.isEmpty() && !heading && headingActions.isEmpty() else
        (hasInlineFamily || sourceFamily is ContainerFontFamily.Stack) &&
            !visibleSpans.hasCompiledInlineContent() && prefix.isEmpty() && !heading && headingActions.isEmpty())
    val containerOwner = ownerFont?.takeIf { it.kind == NativeDeclaringFontKind.Container }
    val absoluteOwner = ownerFont?.takeIf { it.kind == NativeDeclaringFontKind.Absolute }
    val backlinkOwner = ownerFont?.takeIf { it.kind == NativeDeclaringFontKind.ReferenceBacklink }
    val preformattedOwner = absoluteOwner == null && LocalNativePreformattedText.current
    val inheritedFamily = sourceFamily.takeUnless { emptyInlineOwner ||
        preformattedOwner && sourceFamily is ContainerFontFamily.Stack }
    val legacyOwnerFamily = effective.fontFamily.takeIf {
        preformattedOwner && (hasInlineFamily || sourceFamily is ContainerFontFamily.Stack)
    }
    val replacementFamilyFailure = nativeRuns.any { run -> familyRanges.any { it.family != null && it.start < run.end && it.end > run.start } }
    var familyFailure: String? = if (replacementFamilyFailure) NativeInlineFamilyReplacementUnavailable else null
    fun familyPaint(run: NativeStyleRange): TextPaint {
        if (familyFailure == null) familyFailure = run.familyFailure
        return run.paint
    }
    var inlineOffset = 0
    val inlineSources = visibleSpans.mapIndexedNotNull { index, span ->
        val start = inlineOffset
        inlineOffset += sourceLength(span)
        val rubyLeaf = ruby?.leaves?.get(index)
        val hasSourceLine = sourceRangeHasLine(start, inlineOffset)
        span.inlineStyle?.takeIf { hasSourceLine }?.let { authored ->
            val declaring = (authored.lineHeight as? InlineLineHeight.FontRelative)?.let {
                if (rubyLeaf != null && it.font.language.isNotEmpty() && nativeTableOwnerLanguageTag(it.font.language) == null)
                    familyFailure = "Ruby line-height language is unavailable for this layout."
                if (rubyLeaf == null) familyPaint(nativeStyleRanges(inlineFontSnapshotAnnotation(it.font, effective), effective, linkColor,
                    sourceFamily = inheritedFamily, familyRanges = listOf(NativeSourceFamilyRange(0, 1,
                        it.font.fontFamily, inlineFontSnapshotSpan(it.font).legacyFontFamily())),
                    legacyOwnerFamily = legacyOwnerFamily).single())
                else familyPaint(nativeStyleRanges(AnnotatedString(" "),
                    rubyFontSnapshotStyle(it.font, rubyLeaf.enclosingStyle, rubyLeaf.fontBasisStyle), linkColor,
                    sourceFamily = rubyLeaf.sourceFamily,
                    familyRanges = listOf(NativeSourceFamilyRange(0, 1, it.font.fontFamily,
                        inlineFontSnapshotSpan(it.font).legacyFontFamily()))).single())
            }
            val empty = if (start == inlineOffset) familyPaint(nativeStyleRanges(
                inlineMetricOwnerAnnotation(span, rubyLeaf?.enclosingStyle ?: effective), rubyLeaf?.enclosingStyle ?: effective,
                linkColor, sourceFamily = rubyLeaf?.sourceFamily ?: inheritedFamily,
                familyRanges = listOf(NativeSourceFamilyRange(0, 1, span.fontFamily,
                    span.legacyFontFamily() ?: rubyLeaf?.legacyFamily)),
                legacyOwnerFamily = legacyOwnerFamily).single()) else null
            NativeInlineSourceRange(span, start, inlineOffset, declaring, empty, rubyLeaf?.parentGroupPath, clippedLeaf(index))
        }
    }
    check(inlineOffset == annotated.length) { "Authored inline metric offsets must retain the original logical string" }
    val inlineParagraphCuts = if (inlineSources.isEmpty()) emptyList() else paragraphBreaks.map { it + 1 }
    val styles = (if (noSourceLines) emptyList() else nativeStyleRanges(nativeAnnotation, effective, linkColor,
        inlineSources.flatMap { listOf(it.start, it.end) } + inlineParagraphCuts, inheritedFamily, familyRanges,
        legacyOwnerFamily, sourceLineStarts.takeIf { ruby == null })).map { range ->
        val target = paintedLinks.singleOrNull { it.start <= range.start && it.end >= range.end }
            ?.span?.let(::citationTarget)
        if (target == null) range else range.copy(paint = TextPaint(range.paint).apply {
            // Target background null is an explicit transparent reset of the source normal background.
            bgColor = when (val background = target.background) {
                null, FigureColor.Transparent -> 0
                is FigureColor.Rgb -> checkNotNull(canonicalColorArgb(background.value)).toInt()
                FigureColor.NativeTheme -> throw UnsupportedFloatLayout("Citation target background is unavailable")
            }
        })
    }
    styles.forEach { familyPaint(it) }
    val basePaint = if (noSourceLines) TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 0f }
        else if (absoluteOwner == null) familyPaint(nativeStyleRanges(AnnotatedString(" "), effective, linkColor,
        sourceFamily = inheritedFamily, legacyOwnerFamily = legacyOwnerFamily).single()) else {
        val snapshot = absoluteOwner.snapshot
        if (snapshot.language.isNotEmpty() && nativeTableOwnerLanguageTag(snapshot.language) == null)
            familyFailure = NativeAbsoluteOwnerFontUnavailable
        if (absoluteOwner.style == null) familyFailure = "An unused declaring font cannot supply a source line."
        familyPaint(nativeStyleRanges(AnnotatedString(" "), absoluteOwner.style ?: effective, linkColor,
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
    val containerOwnerPaint = containerOwner?.takeUnless { noSourceLines || emptyInlineOwner }?.let { declaring ->
        if (declaring.style == null || declaring.snapshot.language.isNotEmpty() &&
            nativeTableOwnerLanguageTag(declaring.snapshot.language) == null) {
            familyFailure = NativeContainerOwnerFontUnavailable
            null
        } else familyPaint(nativeStyleRanges(AnnotatedString(" "), declaring.style, linkColor,
            sourceFamily = sourceFamily, familyRanges = listOf(NativeSourceFamilyRange(0, 1,
                declaring.snapshot.fontFamily, inlineFontSnapshotSpan(declaring.snapshot).legacyFontFamily()))).single())
            .apply { textSize = checkNotNull(declaring.fontPixels); baselineShift = 0 }
    }
    if ((referenceBacklink != null) != (backlinkOwner != null))
        familyFailure = "Reference backlink declaring font is unavailable."
    val backlinkOwnerPaint = backlinkOwner?.let { declaring ->
        val qualified = referenceBacklink
        if (qualified == null || spans.size != 1 || spans.single() !== qualified.span || ruby != null ||
            declaring.snapshot != nativeReferenceBacklinkFont(qualified) ||
            declaring.snapshot.language.isNotEmpty() && nativeTableOwnerLanguageTag(declaring.snapshot.language) == null) {
            familyFailure = "Reference backlink declaring font is unavailable."
            null
        } else familyPaint(nativeStyleRanges(inlineFontSnapshotAnnotation(declaring.snapshot, effective),
            effective, linkColor, familyRanges = listOf(NativeSourceFamilyRange(0, 1,
                declaring.snapshot.fontFamily, inlineFontSnapshotSpan(declaring.snapshot).legacyFontFamily()))).single())
    }
    val layoutPaint = backlinkOwnerPaint ?: containerOwnerPaint ?: cellOwnerPaint ?: basePaint
    val staticParentPaint = staticInlineParent?.let { parent ->
        val format = parent.format
        val declaring = format.ownerFont
        if (declaring != null && (declaring.style == null || declaring.fontPixels == null ||
                declaring.snapshot.language.isNotEmpty() && nativeTableOwnerLanguageTag(declaring.snapshot.language) == null)) {
            familyFailure = "Static inline parent declaring font is unavailable."
            null
        } else familyPaint(nativeStyleRanges(AnnotatedString(" "), declaring?.style ?: format.style, linkColor,
            sourceFamily = format.sourceFamily,
            familyRanges = declaring?.let { listOf(NativeSourceFamilyRange(0, 1,
                it.snapshot.fontFamily, inlineFontSnapshotSpan(it.snapshot).legacyFontFamily())) }.orEmpty()).single()).apply {
                if (declaring != null) {
                    textSize = checkNotNull(declaring.fontPixels)
                    baselineShift = 0
                }
            }
    }
    val staticInline = staticInlineParent?.let { parent -> staticParentPaint?.let { paint ->
        NativeStaticInlineText(paint, parent.format.lineHeight, parent.direction, parent.alignment)
    } }
    val cellMetricRevision = cellOwner?.let {
        listOf(cellState, cellOwnerPaint?.typeface, cellOwnerPaint?.textSize)
    }
    val normalBodySize = MaterialTheme.typography.bodyLarge.fontSize
    val cssPixelTextZoom = LocalCssPixelTextZoom.current
    var inlineFailure: String? = when {
        clippedRanges.isNotEmpty() && (prefix.isNotEmpty() || heading || headingActions.isNotEmpty()) ->
            "Clipped absolute marker or heading layout is unavailable"
        clippedRunOverlap -> "Clipped absolute intersects a compound Egyptian run"
        ruby?.leaves?.any { it.range.role == RubyTextRole.ClippedText && it.range.start == it.range.end &&
            it.range.span?.kind in setOf("link", "external_link") } == true ->
            "Clipped absolute empty descendant action is unavailable"
        absoluteOwner != null && ownerWrap != TextWrap.NoWrap -> "Absolute declaring font requires its complete no-wrap owner."
        sourceLineStarts != null && (prefix.isNotEmpty() || heading || headingActions.isNotEmpty()) ->
            "No-wrap marker or heading line ownership is unavailable."
        absoluteOwner != null && nativeLineHeight !is NativeLineHeightPolicy.Pixels ->
            "Absolute declaring line height is unavailable."
        visibleSpans.withIndex().any { (index, span) ->
            val role = ruby?.leaves?.get(index)?.range?.role
            val gap = role == RubyTextRole.SegmentGap || role == RubyTextRole.BaseGap ||
                role == RubyTextRole.AnnotationGap
            val wrapOnly = span.inlineStyle?.wrap?.let { span.inlineStyle == InlineTextStyle(wrap = it) } == true
            // The native gap owner verifies a uniform source context before collapsing.
            // Ordinary/body whitespace retains the existing explicit refusal.
            !clippedLeaf(index) && span.isUnsupportedAuthoredWhitespaceOwner() && !(gap && wrapOnly)
        } ->
            "Authored inline whitespace effects require a retained collapsed source owner"
        else -> null
    }
    fun inlineLength(value: InlineComputedLength): Float {
        val magnitude = cellTextMetricPixels(kotlin.math.abs(value.value), value.fontScaleBasis,
            normalBodySize, density, cssPixelTextZoom)
        if (magnitude > TablePixelLimit) throw UnsupportedFloatLayout("Authored inline length exceeds native geometry")
        return if (value.value < 0f) -magnitude else magnitude
    }
    val rubyTableTextDirection = LocalCompiledTableTextDirection.current
    val bodyTextDirection = LocalNativeContainerTextContext.current?.bodyDirection
    val columnTextDirection = LocalNativeColumnTextDirection.current
    val boxDarkTheme = LocalReaderDarkTheme.current
    val rubyFormats = linkedMapOf<String, NativeRubyGroupFormat>()
    ruby?.groups?.forEach { (path, group) ->
        val range = group.range
        val owner = range.base?.owner ?: range.annotation?.owner
        val authored = owner?.inlineStyle ?: range.span?.inlineStyle
        val language = owner?.font?.language ?: range.span?.language.orEmpty()
        if (language.isNotEmpty() && nativeTableOwnerLanguageTag(language) == null)
            familyFailure = "Ruby declaring language is unavailable for this layout."
        val relativeLanguage = (authored?.lineHeight as? InlineLineHeight.FontRelative)?.font?.language.orEmpty()
        if (relativeLanguage.isNotEmpty() && nativeTableOwnerLanguageTag(relativeLanguage) == null)
            familyFailure = "Ruby line-height language is unavailable for this layout."
        val paint = familyPaint(nativeStyleRanges(AnnotatedString(" "), group.style, linkColor,
            sourceFamily = group.sourceFamily,
            familyRanges = listOf(NativeSourceFamilyRange(0, 1, group.sourceFamily, group.legacyFamily))).single())
        val parentPolicy = group.parentGroupPath?.let { rubyFormats[it]?.lineHeight }
            ?: nativeLineHeight ?: when {
                effective.lineHeight.isSp -> NativeLineHeightPolicy.Pixels(with(density) { effective.lineHeight.toPx() })
                effective.lineHeight.isEm -> NativeLineHeightPolicy.Pixels(layoutPaint.textSize * effective.lineHeight.value)
                else -> NativeLineHeightPolicy.Normal
            }
        val relativeFont = (authored?.lineHeight as? InlineLineHeight.FontRelative)?.let { value ->
            familyPaint(nativeStyleRanges(AnnotatedString(" "),
                rubyFontSnapshotStyle(value.font, group.enclosingStyle, group.fontBasisStyle), linkColor,
                sourceFamily = group.sourceFamily,
                familyRanges = listOf(NativeSourceFamilyRange(0, 1, value.font.fontFamily,
                    inlineFontSnapshotSpan(value.font).legacyFontFamily()))).single())
        }
        try {
            val height = when (val value = authored?.lineHeight) {
                null -> parentPolicy
                is InlineLineHeight.Computed -> NativeLineHeightPolicy.Pixels(inlineLength(value.value))
                is InlineLineHeight.FontRelative -> {
                    val pixels = checkNotNull(relativeFont).textSize.toDouble() * value.factor
                    if (!pixels.isFinite() || pixels < 0.0 || pixels > TablePixelLimit)
                        throw UnsupportedFloatLayout("Ruby declaring line height exceeds native geometry")
                    NativeLineHeightPolicy.Pixels(pixels.toFloat())
                }
            }
            val shift = paint.baselineShift.toFloat()
            val localShift = authored?.baselineShift?.let { -inlineLength(it) }
            paint.baselineShift = 0
            val underline = authored?.decoration?.let { decoration ->
                paint.isUnderlineText = false
                val thickness = decoration.thickness?.let { value ->
                    val pixels = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density.density else bodyPixels
                    if (!pixels.isFinite() || pixels < 0.0 || pixels > TablePixelLimit)
                        throw UnsupportedFloatLayout("Ruby decoration exceeds native geometry")
                    pixels.toFloat()
                }
                NativeAuthoredUnderline(decoration.style, decoration.color?.let { canonicalColorArgb(it)!!.toInt() }, thickness)
            }
            val sourceDirection = owner?.direction ?: range.span?.direction.orEmpty()
            val groupDirection = when (range.span?.clippedAbsolute?.staticParentDirection) {
                BidiResolvedDirection.Ltr -> TextDirectionHeuristics.LTR
                BidiResolvedDirection.Rtl -> TextDirectionHeuristics.RTL
                null -> when (sourceDirection) {
                "ltr" -> TextDirectionHeuristics.LTR
                "rtl" -> TextDirectionHeuristics.RTL
                else -> group.parentGroupPath?.let { rubyFormats[it]?.direction }
                    ?: when (staticInlineParent?.direction ?: ownerDirection) {
                        BidiResolvedDirection.Ltr -> TextDirectionHeuristics.LTR
                        BidiResolvedDirection.Rtl -> TextDirectionHeuristics.RTL
                        null -> nativeParagraphDirection(annotated, rtl, rubyTableTextDirection, bodyTextDirection, columnTextDirection)
                    }
                }
            }
            val padding = range.span?.inlinePaddingGroup?.let { model ->
                fun edge(value: StyleLength): Float {
                    val pixels = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density.density else paint.textSize
                    if (!pixels.isFinite() || pixels < 0.0 || pixels > TablePixelLimit)
                        throw UnsupportedFloatLayout("Inline padding exceeds native geometry")
                    return pixels.toFloat()
                }
                val left = edge(model.left); val right = edge(model.right)
                if (left.toDouble() + right > TablePixelLimit)
                    throw UnsupportedFloatLayout("Inline padding exceeds native geometry")
                NativeInlinePaddingEdges(left, right)
            }
            val box = range.span?.inlineBoxGroup?.let { model ->
                fun length(value: StyleLength): Float = nativeInlineBoxCoordinate(value.value.toDouble() *
                    if (value.unit == StyleLengthUnit.Px) density.density else paint.textSize)
                fun color(value: InlineBoxColor): Int? = when (value) {
                    InlineBoxColor.CurrentColor -> null
                    InlineBoxColor.Transparent -> 0
                    is InlineBoxColor.Rgb -> checkNotNull(canonicalColorArgb(value.value)).toInt()
                    is InlineBoxColor.LightDark -> checkNotNull(canonicalColorArgb(
                        if (boxDarkTheme) value.dark else value.light)).toInt()
                }
                fun border(value: InlineBoxBorderEdge): NativeInlineBoxBorder = when (value) {
                    InlineBoxBorderEdge.None, InlineBoxBorderEdge.Hidden -> NativeInlineBoxBorder(0f, 0)
                    is InlineBoxBorderEdge.Solid -> NativeInlineBoxBorder(length(value.width), color(value.color))
                    is InlineBoxBorderEdge.Dotted -> NativeInlineBoxBorder(length(value.width), color(value.color), dotted = true)
                }
                fun borders(value: InlineBoxBorderEdges) = NativeInlineBoxBorders(
                    border(value.top), border(value.right), border(value.bottom), border(value.left))
                fun inset(value: InlineBoxInset?): NativeInlineBoxInset? = value?.let {
                    if (it.unit == StyleWidthUnit.Percent) NativeInlineBoxInset(it.value, percentage = true)
                    else NativeInlineBoxInset(nativeInlineBoxCoordinate(it.value.toDouble() *
                        if (it.unit == StyleWidthUnit.Px) density.density else paint.textSize), percentage = false)
                }
                // CurrentColor belongs to this owner or its actual stored action ancestor,
                // never to a child link which merely occupies the same logical interval.
                val action = actionGroupRanges.lastOrNull { it.path == path || path.startsWith(it.path + "/") }
                if (model.radius != null && action != null && action.path != path)
                    throw UnsupportedFloatLayout("Rounded inline box inside a separate action group is unavailable")
                val resolvedPadding = NativeInlineBoxEdges(length(model.padding.top), length(model.padding.right),
                    length(model.padding.bottom), length(model.padding.left))
                val resolvedBorders = borders(model.border)
                val atomic = model.atomicLayout?.let { atomic ->
                    val policy = when (val value = atomic.lineHeight) {
                        null -> NativeLineHeightPolicy.Normal
                        is InlineLineHeight.Computed -> NativeLineHeightPolicy.Pixels(inlineLength(value.value))
                        // Shared admission binds this snapshot to the complete declaring font.
                        is InlineLineHeight.FontRelative -> NativeLineHeightPolicy.Pixels(
                            nativeInlineBoxCoordinate(paint.textSize.toDouble() * value.factor))
                    }
                    NativeInlineAtomicBoxFormat(nativeInlineAtomicBoxAllocation(length(atomic.width), length(atomic.height),
                        resolvedPadding, NativeInlineBoxEdges(resolvedBorders.top.width, resolvedBorders.right.width,
                            resolvedBorders.bottom.width, resolvedBorders.left.width),
                        NativeInlineBoxEdges(length(atomic.margins.top), length(atomic.margins.right),
                            length(atomic.margins.bottom), length(atomic.margins.left)), atomic.boxSizing),
                        atomic.textAlign, atomic.wrap, policy)
                }
                NativeInlineBoxFormat(boxOwners.getValue(path), resolvedPadding, resolvedBorders,
                    model.overlays.map { overlay -> NativeInlineBoxOverlay(NativeInlineBoxInsets(
                        inset(overlay.insets.top), inset(overlay.insets.right),
                        inset(overlay.insets.bottom), inset(overlay.insets.left)), borders(overlay.border)) },
                    currentColorPaint = action?.let(::groupPaintAt), radius = model.radius?.let {
                        when (it.unit) {
                            StyleWidthUnit.Px -> nativeInlineBoxCoordinate(it.value.toDouble() * density.density)
                            StyleWidthUnit.Percent -> it.value
                            StyleWidthUnit.Em -> throw UnsupportedFloatLayout("Rounded inline radius cannot use em")
                        }
                    }, atomicLayout = atomic, radiusPercentage = model.radius?.unit == StyleWidthUnit.Percent)
            }
            val clipped = range.span?.clippedAbsolute?.let { model ->
                val scope = clippedAbsoluteScope ?: throw UnsupportedFloatLayout(
                    "Clipped absolute containing-block coordinate owner is unavailable")
                fun pixels(value: Float, unit: StyleLengthUnit): Float {
                    val used = value.toDouble() * if (unit == StyleLengthUnit.Px) density.density else bodyPixels
                    if (!used.isFinite() || kotlin.math.abs(used) > TablePixelLimit)
                        throw UnsupportedFloatLayout("Clipped absolute length exceeds native geometry")
                    return used.toFloat()
                }
                fun length(value: StyleLength): Float = pixels(value.value, value.unit)
                fun margin(value: ContainerMargin): Float {
                    val signed = (value as? ContainerMargin.Length)?.value
                        ?: throw UnsupportedFloatLayout("Clipped absolute margin is not definite")
                    return pixels(signed.value, signed.unit)
                }
                NativeClippedAbsoluteFormat(clippedOwners.getValue(path), length(model.width), length(model.height),
                    NativeClippedAbsoluteMargins(margin(model.margin.top), margin(model.margin.right),
                        margin(model.margin.bottom), margin(model.margin.left)), scope)
            }
            rubyFormats[path] = NativeRubyGroupFormat(paint, groupDirection, height, shift,
                authored?.wrap, underline, authored?.cursor, sourceDirection, localBaselineShift = localShift,
                padding = padding, actionPaint = if (range in groupActions) groupPaintAt(range) else null,
                actionOwner = actionGroupOwners[path], box = box, clippedAbsolute = clipped)
        } catch (failure: UnsupportedFloatLayout) {
            inlineFailure = failure.message ?: "Ruby declaring geometry is unavailable"
        }
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
    val backlinkInlineStyle = referenceBacklink?.let { backlink -> inlineStyles.singleOrNull {
        it.source.span === backlink.span && it.source.start == 0 && it.source.end == annotated.length
    } }
    val backlinkPolicy = if (backlinkOwner == null || referenceBacklink == null) null else try {
        nativeReferenceBacklinkLineHeight(referenceBacklink, backlinkInlineStyle?.height)
    } catch (failure: UnsupportedFloatLayout) {
        inlineFailure = failure.message
        null
    }
    val inlineRevision = inlineStyles.map { resolved ->
        val source = resolved.source
        listOf(source.span, resolved.height, resolved.shift, resolved.thickness,
            source.declaringPaint?.typeface, source.declaringPaint?.textSize, source.declaringPaint?.baselineShift,
            source.emptyPaint?.typeface, source.emptyPaint?.textSize, source.emptyPaint?.baselineShift)
    }
    val usesRunMetrics = ruby != null || ownerFont != null || cellOwner != null || nativeLineHeight != null ||
        visibleSpans.any { it.image?.occurrenceLayout != null } || inlineStyles.any { it.height != null || it.shift != null }
    val prefixPaint = if (noSourceLines) TextPaint(basePaint) else familyPaint(nativeStyleRanges(
        AnnotatedString(" "), prefixStyle ?: effective, linkColor,
        sourceFamily = inheritedFamily.takeIf { prefix.isNotEmpty() }).single())
    var referenceMarkerFailure: String? = null
    val referenceMarker = if (outsideReferenceMarker) try { NativeMarkerText(prefix, prefixPaint,
        markerDirection = if (rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr)
    } catch (failure: UnsupportedFloatLayout) {
        referenceMarkerFailure = failure.message ?: "Reference marker geometry is unavailable"; null
    } else null
    val layoutUnavailable = familyFailure ?: paintUnavailable ?: inlineFailure ?:
        "Reference LI declaring font is unavailable".takeIf { referenceLayoutBacklink != null && ownerFont?.kind != NativeDeclaringFontKind.Container } ?:
        referenceMarkerFailure
    val prefixWidth = if (outsideReferenceMarker) referenceMarker?.advance ?: 0f
        else if (prefix.isEmpty()) 0f else 28f * density.density
    val prefixInset = if (outsideReferenceMarker) 0f else prefixWidth
    val actionSize = 48f * density.density
    require(!authoredHeading || headingActions.size <= NativeHeadingCustomActionIds.size)
    val paintedHeadingActions = if (authoredHeading) emptyList() else headingActions
    val actionWidth = actionSize * paintedHeadingActions.size
    val insets = if (rtl) NativeTextInsets(right = indentPixels, extraRight = prefixInset, extraLeft = actionWidth)
        else NativeTextInsets(left = indentPixels, extraLeft = prefixInset, extraRight = actionWidth)
    fun actionBounds(geometry: NativeFloatGeometry, index: Int): RectF {
        val band = geometry.firstLineBand()
        val left = if (rtl) band.left - actionWidth + index * actionSize else band.right + index * actionSize
        return RectF(left, band.top, left + actionSize, band.top + actionSize)
    }
    fun paintAt(offset: Int) = TextPaint().apply { set(styles.firstOrNull { offset in it.start until it.end }?.paint ?: basePaint) }
    val owner = imageOwnerOverride ?: LocalInlineImageOwner.current ?: rememberInlineImageViewOwner(visibleSpans.mapNotNull { it.image }, media, settings, edition)
    visibleSpans.mapNotNull { it.image }.filter { it.staticPoster == null || figureImageActions }
        .distinctBy(::inlineImageAssetKey).forEach { image -> LaunchedEffect(owner, image) { owner.ensure(image) } }
    var details by remember { mutableStateOf<NativeImage?>(null) }
    val images = mutableListOf<NativeImage>()
    val imageActions = mutableMapOf<Int, NativeImageActions>()
    val imageDarkTheme = LocalReaderDarkTheme.current
    var offset = 0
    visibleSpans.forEachIndexed { id, span ->
        if (hasDirectionControls(span)) offset++
        span.image?.let { image ->
            val bitmapColorFilter = rememberInlineImageColorFilter(image)
            check(annotated.text.getOrNull(offset) == '\ufffc') { "Compiled image offset drift" }
            val paint = paintAt(offset)
            val asset = if (image.staticPoster != null && !figureImageActions) InlineImageAssetState.LayoutUnavailable else
                owner.states[inlineImageAssetKey(image)] ?: if (settings.allowImages) InlineImageAssetState.Loading else InlineImageAssetState.Disabled
            val ready = asset as? InlineImageAssetState.Ready
            val dimensions = if (ready != null) inlineImagePixels(image, ready.originalWidth, ready.originalHeight, density.density, ready.mime)
                else if (asset == InlineImageAssetState.LayoutUnavailable) null else owner.knownPixels(image, density.density)
            val state = if (ready != null && dimensions == null) InlineImageAssetState.GeometryUnavailable(ready) else asset
            val occurrenceStyle = styles.firstOrNull { offset in it.start until it.end }
            val fallbackLayout = nativeFloatImageFallbackLayout(image, state, paint, basePaint,
                occurrenceStyle?.baselineShiftMultiplier ?: 0f, occurrenceStyle?.letterSpacingPixels, dimensions?.width)
            val side = (image.widthPx ?: image.heightPx)?.let {
                (it.toDouble() * density.density).coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat()
            } ?: paint.textSize.coerceAtLeast(1f)
            val pixels = dimensions ?: fallbackLayout?.let { layout -> InlineImagePixels(
                (0 until layout.lineCount).maxOfOrNull { layout.getLineWidth(it) }?.coerceAtLeast(1f) ?: 1f,
                layout.height.coerceAtLeast(1).toFloat()) } ?: InlineImagePixels(side, side)
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
            val nativeImage = NativeImage(id, offset, span, state, paint, outerPixels, imageInk, dimensions?.width,
                with(density) { normalBodySize.toPx() }, density.density, draw)
            images += nativeImage
            if (span.linkPaint != null) {
                // Keep one action for this source occurrence across size/asset-state remeasure.
                // A changed caller or source gets new callbacks; details read the current asset.
                key(documentOwner, captionOwner, id, offset, span, edition, uri, onLink) {
                    val currentImage by rememberUpdatedState(nativeImage)
                    imageActions[id] = remember {
                        val url = inlineImageLinkUrl(span, edition)
                        val unresolved = span.kind == "link" && span.target.startsWith("File:") && url == null
                        val click: (() -> Unit)? = when {
                            url != null -> { { uri.openUri(url) } }
                            span.kind == "link" && !unresolved -> { { onLink(span.entryLink()) } }
                            else -> null
                        }
                        NativeImageActions(click, { details = currentImage })
                    }
                }
            }
        }
        offset += if (span.image != null) 1 else if (span.kind == "line_break") 1 else span.text.length
        offset += span.trail.length
        if (hasDirectionControls(span)) offset++
    }
    check(offset == annotated.length) { "Native context must retain the original logical string" }
    // Shape once per text/font request, then resize the immutable ink without reshaping it.
    val rubyMetricRevision = rubyFormats.map { (path, group) ->
        val paint = group.paint
        listOf(path, paint.typeface, paint.textSize, paint.textLocales, paint.fontFeatureSettings,
            paint.letterSpacing, paint.textScaleX, paint.textSkewX, paint.color, paint.bgColor,
            paint.isUnderlineText, paint.isStrikeThruText, group.direction, group.lineHeight,
            group.baselineShift, group.localBaselineShift, group.wrap, group.underline, group.cursor, group.sourceDirection,
            group.padding, group.actionPaint, group.actionOwner, group.clippedAbsolute?.let { listOf(it.width, it.height, it.margins) },
            group.box?.let { listOf(it.owner, it.padding, it.border, it.overlays, it.currentColorPaint, it.atomicLayout) })
    }
    val shapeKey = listOf(annotated, nativeAnnotation, clippedAbsoluteScope?.revisionKey, nativeRuns, effective, ruby, actionGroupOwners, boxOwners, clippedOwners, citationOwners, rubyMetricRevision, density.density, density.fontScale, inlineRevision, familyFailure, sourceFamily, familyRanges, legacyOwnerFamily, ownerFont, cellMetricRevision, sourceLineStarts,
        paintedLinks.filter { it.span.linkPaint != null }.map { it.start to it.end },
        styles.map { listOf(it.start, it.end, it.paint.typeface, it.paint.textSize, it.paint.color, it.paint.bgColor, it.paint.baselineShift) })
    val shaped by produceState<Pair<Any, Map<Int, NativeEgyptianSpanPreparation>>?>(null, shapeKey) {
        val result = linkedMapOf<Int, NativeEgyptianSpanPreparation>()
        for (run in if (replacementFamilyFailure) emptyList() else nativeRuns) {
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
        nativeRuns.isNotEmpty() && prepared.size != nativeRuns.size -> "Loading Egyptian glyph layout"
        prepared.values.any { !it.available } -> "Egyptian glyph layout unavailable"
        else -> null
    }
    val direction = when (staticInlineParent?.direction ?: ownerDirection) {
        BidiResolvedDirection.Ltr -> TextDirectionHeuristics.LTR
        BidiResolvedDirection.Rtl -> TextDirectionHeuristics.RTL
        null -> nativeParagraphDirection(annotated, rtl, rubyTableTextDirection, bodyTextDirection, columnTextDirection)
    }
    val nativeSource: ((Int) -> Spanned)? =
        if (nativeRuns.isNotEmpty() && prepared.size != nativeRuns.size) null else { width ->
                if (familyFailure != null) throw UnsupportedFloatLayout(checkNotNull(familyFailure))
                val native = SpannableString(annotated.text)
                if (ownerWrap != null && (native.isNotEmpty() || sourceLineStarts != null)) native.setSpan(
                    NativeAuthoredTextWrap(ownerWrap, inheritedOwner = true, sourceLineStarts = sourceLineStarts), 0, native.length,
                    if (native.isEmpty()) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                styles.forEach { range -> native.setSpan(NativePaintSpan(range.paint, linkPaintAt(range.start, range.end),
                    groupAction = groupActions.any { it.start <= range.start && it.end >= range.end }),
                    range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                val inlineParentPolicies = mutableListOf<Triple<Int, Int, NativeLineHeightPolicy>>()
                val paragraphStarts = listOf(0) + paragraphBreaks.filter {
                    it + 1 < annotated.length || inlineSources.any { owner ->
                        owner.start == annotated.length && owner.end == owner.start
                    }
                }.map { it + 1 }
                paragraphStarts.forEachIndexed { index, start ->
                    if (sourceLineStarts != null && start !in sourceLineStarts) return@forEachIndexed
                    val end = paragraphStarts.getOrNull(index + 1) ?: annotated.length
                    val paragraphStyle = annotated.paragraphStyles.filter { it.start <= start && it.end >= end }
                        .fold(effective.toParagraphStyle()) { merged, range -> merged.merge(range.item) }
                    val paragraphText = if (clippedRanges.isEmpty()) annotated.text.substring(start, end) else buildString {
                        var at = start
                        clippedRanges.filter { it.start < end && it.end > start }.sortedBy { it.start }.forEach { range ->
                            append(annotated.text, at, maxOf(at, range.start))
                            at = minOf(end, range.end)
                        }
                        append(annotated.text, at, end)
                    }
                    val staticParents = clippedRanges.filter { it.start < end && it.end > start }
                        .map { checkNotNull(checkNotNull(it.span).clippedAbsolute).staticParentDirection }.distinct()
                    if (staticParents.size > 1) throw UnsupportedFloatLayout("Clipped static-parent directions conflict in one paragraph")
                    val staticParent = staticParents.singleOrNull()
                    val explicitParent = when (direction) {
                        TextDirectionHeuristics.LTR -> BidiResolvedDirection.Ltr
                        TextDirectionHeuristics.RTL -> BidiResolvedDirection.Rtl
                        else -> null
                    }
                    if (staticParent != null && explicitParent != null && staticParent != explicitParent)
                        throw UnsupportedFloatLayout("Clipped source static-parent direction conflicts with explicit represented parent")
                    val paragraphRtl = staticParent?.let { it == BidiResolvedDirection.Rtl }
                        ?: direction.isRtl(paragraphText, 0, paragraphText.length)
                    if (staticParent != null) native.setSpan(NativeClippedParagraphDirection(staticParent), start, end,
                        if (start == end) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
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
                            backlinkPolicy != null -> backlinkPolicy
                            explicit?.isSp == true -> NativeLineHeightPolicy.Pixels(with(density) { explicit.toPx() })
                            explicit?.isEm == true -> NativeLineHeightPolicy.Pixels(basePaint.textSize * explicit.value)
                            else -> inheritedPolicy
                        }
                        inlineParentPolicies += Triple(start, end, policy)
                        val primary = NativePrimaryFontMetrics.from(layoutPaint).let { metrics ->
                            backlinkInlineStyle?.shift?.let { metrics.copy(baselineShift = it) } ?: metrics
                        }
                        native.setSpan(NativeRunLineMetrics(primary, policy,
                            strut = true, includePrimaryInNormal = cellOwnerPaint != null || containerOwnerPaint != null || backlinkOwnerPaint != null),
                            start, end, if (start == end && (inlineSources.isNotEmpty() || cellOwnerPaint != null || containerOwnerPaint != null))
                                Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                        styles.forEach { run ->
                            val first = max(start, run.start)
                            val last = min(end, run.end)
                            if (first < last) {
                                // Images contribute their actual replaced box. Egyptian replacements
                                // remain text and retain the original style's primary-font strut.
                                val cuts = (listOf(first, last) + images.filter { it.offset in first until last }
                                    .flatMap { listOf(it.offset, it.offset + 1) } + rubyOwnerRanges.flatMap {
                                        listOf(it.start, it.end).filter { cut -> cut > first && cut < last }
                                    }).distinct().sorted()
                                cuts.zipWithNext().filter { (a, b) -> a < b && images.none { it.offset == a } }
                                    .filterNot { (a, b) -> rubyOwnerRanges.any { it.start <= a && it.end >= b } }
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
                paragraphGaps.forEach { (end, gapDp) -> if (end > 0) native.setSpan(object : LineHeightSpan, NativeFloatRowMetricEffect {
                    override fun chooseHeight(text: CharSequence, start: Int, finish: Int, spanstartv: Int, v: Int, fm: Paint.FontMetricsInt) {
                        if (finish >= end) { val gap = ceil(gapDp * density.density).toInt(); fm.descent += gap; fm.bottom += gap }
                    }
                }, end - 1, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                if (usesRunMetrics) paragraphGaps.forEach { (end, gapDp) ->
                    if (end > 0) native.setSpan(NativeLineGap(ceil(gapDp * density.density)),
                        end - 1, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                nativeRuns.forEach { run ->
                    // The replacement owns its baseline and decoration; native TextLine must not apply them again.
                    val replacementPaint = paintAt(run.start).apply { baselineShift = 0; isUnderlineText = false; isStrikeThruText = false; bgColor = 0 }
                    native.setSpan(NativePaintSpan(replacementPaint), run.start, run.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    native.setSpan(prepared.getValue(run.start).spanForWidth(width.toFloat(), linkPaintAt(run.start, run.end)), run.start, run.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                images.forEach { image ->
                    val replacementPaint = paintAt(image.offset).apply {
                        baselineShift = 0
                        // The policy's normal underline is a checksum, not bitmap decoration.
                        if (image.span.linkPaint != null) isUnderlineText = false
                    }
                    native.setSpan(NativePaintSpan(replacementPaint), image.offset, image.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    native.setSpan(NativeInlineImageSpan(image), image.offset, image.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                inlineStyles.forEach { resolved ->
                    val source = resolved.source
                    val authored = checkNotNull(source.span.inlineStyle)
                    authored.wrap?.let { wrap ->
                        val textStart = source.start + if (hasDirectionControls(source.span)) 1 else 0
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
                        val clippedPoint = if (clippedRanges.isNotEmpty() && start == end &&
                            !source.clippedChild &&
                            (resolved.height != null || resolved.shift != null)) NativeClippedVisibleMetricPoint() else null
                        if (resolved.height != null || resolved.shift != null) {
                            val primary = NativePrimaryFontMetrics.from(paint).copy(baselineShift = shift)
                            val declaring = source.declaringPaint?.let {
                                NativePrimaryFontMetrics.from(it).let { metrics ->
                                    if (resolved.shift == null) metrics else metrics.copy(baselineShift = shift)
                                }
                            }
                            val policy = resolved.height?.let { NativeLineHeightPolicy.Pixels(it) }
                                ?: source.rubyParentPath?.let { rubyFormats[it]?.lineHeight }
                                ?: inlineParentPolicies.lastOrNull { it.first <= start && it.second >= end }?.third
                                ?: NativeLineHeightPolicy.Normal
                            native.setSpan(NativeAuthoredInlineMetrics(primary, policy, declaring, clippedPoint), start, end, flags)
                            if (clippedPoint != null) native.setSpan(NativeClippedVisibleMetricMarker(clippedPoint), start, end, flags)
                        }
                        resolved.shift?.let { native.setSpan(NativeAuthoredBaselineShift(it, clippedPoint), start, end, flags) }
                        authored.decoration?.let { decoration ->
                            native.setSpan(NativeAuthoredUnderline(decoration.style,
                                decoration.color?.let { canonicalColorArgb(it)!!.toInt() }, resolved.thickness), start, end, flags)
                        }
                        authored.cursor?.let { native.setSpan(NativeAuthoredCursor(it), start, end, flags) }
                    }
                }
                ruby?.let { context ->
                    if (inlineFailure != null) throw UnsupportedFloatLayout(checkNotNull(inlineFailure))
                    native.setSpan(NativeRubyPreparedSource(context.projection, native, layoutPaint, direction, rubyFormats),
                        0, native.length, if (native.isEmpty()) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                native
        }
    // Only the existing original grouped-source projection grants these owner paths.
    // Ordinary nongrouped nodes keep their already-proven native offsets and metadata.
    val advisoryProjection = ruby?.projection
    val advisoryIndex = advisoryProjection?.let(::NativeTextAdvisoryIndex)
    fun withAdvisories(geometry: FloatTextGeometry, nodes: List<FloatInteractionNode>,
        sources: Map<Int, RubyTextRange>): List<FloatInteractionNode> {
        val index = advisoryIndex ?: return nodes
        val projection = checkNotNull(advisoryProjection)
        val advisoryDeclarations = index.declarations
        if (advisoryDeclarations.isEmpty()) return nodes
        data class AdvisoryShape(val bounds: List<RectF>, val contains: (Float, Float) -> Boolean)
        val shapes = mutableMapOf<String, AdvisoryShape>()
        fun shape(range: RubyTextRange): AdvisoryShape = shapes.getOrPut(range.path) {
            val span = checkNotNull(range.span)
            val bounds = when (range.role) {
                RubyTextRole.BoxGroup -> geometry.inlineBoxGroupRects(boxOwners.getValue(range.path), range.start, range.end)
                    ?: throw UnsupportedFloatLayout("Inline advisory lost its original box geometry")
                RubyTextRole.PaddingGroup -> geometry.inlinePaddingGroupRects(span, range.start, range.end)
                    ?: throw UnsupportedFloatLayout("Inline advisory lost its original padding geometry")
                RubyTextRole.ClippedAbsolute, RubyTextRole.ClippedText -> emptyList()
                else -> geometry.rectsForRange(range.start, range.end)
            }
            val curves = (index.ancestors(range) + range).filter { box ->
                box.role == RubyTextRole.BoxGroup && box.span?.inlineBoxGroup?.radius != null }.map { box ->
                geometry.inlineBoxGroupHitTest(boxOwners.getValue(box.path), box.start, box.end)
                    ?: throw UnsupportedFloatLayout("Rounded advisory lost its original box geometry")
            }
            AdvisoryShape(bounds) { x, y -> bounds.any { it.contains(x, y) } && curves.all { it(x, y) } }
        }
        fun titleAt(range: RubyTextRange, fallback: CharSequence?): (Float, Float) -> CharSequence? {
            val descendants = index.descendants(range)
            val inherited = index.title(range) ?: fallback
            return { x, y -> descendants.lastOrNull { shape(it).contains(x, y) }?.span?.tooltip ?: inherited }
        }
        val actions = nodes.map { node ->
            val range = sources[node.id]
            if (range == null) node else {
                val image = node.kind == FloatInteractionKind.IMAGE
                val title = if (image) index.imageTitle(range, node.tooltip) else index.title(range) ?: node.tooltip
                node.copy(tooltip = title,
                    advisoryIdentity = NativeTextAdvisoryIdentity(checkNotNull(range.span), range.path),
                    tooltipForPosition = if (image) { _, _ -> title } else titleAt(range, node.tooltip))
            }
        }
        val firstId = (nodes.maxOfOrNull { it.id } ?: -1) + 1
        val advisories = advisoryDeclarations.mapIndexedNotNull { ordinal, range ->
            val span = checkNotNull(range.span)
            // Existing source actions/images retain their one node and original activation.
            if (span.tooltip.isNullOrEmpty() || span.kind == "link" || span.kind == "external_link" || span.image != null ||
                range.role == RubyTextRole.ClippedAbsolute || range.role == RubyTextRole.ClippedText) null else {
                val own = shape(range)
                val overrides = index.descendants(range)
                FloatInteractionNode(firstId + ordinal, FloatInteractionKind.ADVISORY, range.start, range.end,
                    own.bounds, projection.text.subSequence(range.start, range.end), span.tooltip, null,
                    hitTest = { x, y -> own.contains(x, y) && overrides.none { shape(it).contains(x, y) } },
                    advisoryIdentity = NativeTextAdvisoryIdentity(span, range.path),
                    tooltipForPosition = titleAt(range, span.tooltip))
            }
        }
        // Passive advice must never take the pointer action from a real link/image/control.
        return advisories + actions
    }
    val nativeNodes: (FloatTextGeometry) -> List<FloatInteractionNode> = { geometry ->
        val advisorySources = mutableMapOf<Int, RubyTextRange>()
        if (sourceLineStarts?.isEmpty() == true) emptyList() else buildList {
                         nativeLinks.forEachIndexed { index, range ->
                            val actionGroup = range.group
                            val citationSource = citationSourceRanges.singleOrNull {
                                it.start == range.start && it.end == range.end
                            }?.span
                            val citationMarker = citationSource?.citationMarker
                            val state = if (actionGroup == null) linkPaintAt(range.start, range.end) else groupPaintAt(actionGroup)
                            val paddingAction = paddingActions.singleOrNull { it.start == range.start && it.end == range.end }
                            val paddingOwner = paddingAction?.span
                            val childRange = if (boxRanges.isEmpty() && (paddingOwner != null || paddingRanges.isEmpty())) null else actionGroup ?: paddingAction ?:
                                ruby?.leaves?.singleOrNull { leaf ->
                                    val span = checkNotNull(leaf.range.span)
                                    leaf.range.start == range.start && leaf.range.end == range.end && when (val link = range.item) {
                                        is LinkAnnotation.Clickable -> span.hasInternalAction() && span.target == link.tag
                                        is LinkAnnotation.Url -> externalLinkUrl(span) == link.url
                                        else -> false
                                    }
                                }?.range ?: throw UnsupportedFloatLayout(if (boxRanges.isEmpty())
                                    "Inline padding child action lost its source owner" else "Inline group child action lost its source owner")
                            val ancestor = childRange?.let { child ->
                                paddingRanges.lastOrNull { child.path.startsWith(it.path + "/") }
                            }
                            val clippedLocation = geometry.clippedAbsoluteSemanticLocation(range.start, range.end)
                            if (clippedRanges.any { range.start >= it.start && range.end <= it.end } && clippedLocation == null)
                                throw UnsupportedFloatLayout("Clipped absolute action location is unavailable")
                            val clippedActionSpan = if (clippedLocation == null) null else (actionGroup?.span ?:
                                ruby?.leaves?.singleOrNull { leaf ->
                                    val source = checkNotNull(leaf.range.span)
                                    leaf.range.role == RubyTextRole.ClippedText && range.start >= leaf.range.start && range.end <= leaf.range.end &&
                                        when (val link = range.item) {
                                            is LinkAnnotation.Clickable -> source.hasInternalAction() && source.target == link.tag
                                            is LinkAnnotation.Url -> externalLinkUrl(source) == link.url
                                            else -> false
                                        }
                                }?.range?.span ?: throw UnsupportedFloatLayout("Clipped absolute action lost its source metadata"))
                            val rawFragments = when {
                                clippedLocation != null -> emptyList()
                                actionGroup != null -> geometry.inlineActionGroupRects(actionGroupOwners.getValue(actionGroup.path), range.start, range.end)
                                    ?: throw UnsupportedFloatLayout("Inline action group geometry is unavailable")
                                paddingOwner != null -> geometry.inlinePaddingGroupRects(paddingOwner, range.start, range.end)
                                    ?: throw UnsupportedFloatLayout("Inline padding action geometry is unavailable")
                                else -> geometry.rectsForRange(range.start, range.end)
                            }
                            val paddingFragments = if (ancestor == null) rawFragments else {
                                val edges = rubyFormats[ancestor.path]?.padding
                                    ?: throw UnsupportedFloatLayout("Inline padding action geometry is unavailable")
                                // Query the original group's full interval; clip only this child's action fragments.
                                nativeInlinePaddingChildActionRects(geometry, checkNotNull(ancestor.span),
                                    ancestor.start, ancestor.end, edges, rawFragments)
                            }
                            val fragments = boxRanges.filter { box ->
                                childRange?.path?.startsWith(box.path + "/") == true
                            }.fold(paddingFragments) { childFragments, box ->
                                // Full source owner interval and original action fragments retain
                                // occurrence identity; only action/focus/AX bounds are clipped.
                                geometry.inlineBoxChildActionRects(boxOwners.getValue(box.path), box.start, box.end,
                                    range.start, range.end, childFragments)
                                    ?: throw UnsupportedFloatLayout("Inline box child action geometry is unavailable")
                            }
                            val roundedOwners = boxRanges.filter { box ->
                                box.span?.inlineBoxGroup?.radius != null &&
                                    (box.path == actionGroup?.path || childRange?.path?.startsWith(box.path + "/") == true)
                            }
                            val roundedHitTests = roundedOwners.map { box ->
                                geometry.inlineBoxGroupHitTest(boxOwners.getValue(box.path), box.start, box.end)
                                    ?: throw UnsupportedFloatLayout("Rounded inline action lost its original box geometry")
                            }
                            val ordinary = if (actionGroup == null) ordinaryPolicies[range.start to range.end] else actionGroup.span?.linkPaint
                            val focus = if (clippedLocation != null) null else if (ordinary != null) ordinaryLinkFocusPaint(ordinary,
                                nativeLinkFocusFragments(geometry, range.start, range.end, fragments), density.density, bodyPixels)
                            else captionScope?.takeIf { linkPaints.containsKey(range.start to range.end) }?.let { scope ->
                                figureLinkFocusPaint(scope.policy, nativeLinkFocusFragments(geometry,
                                    range.start, range.end, fragments), scope.density, scope.bodyPixels)
                            }
                            (actionGroup ?: paddingAction ?: childRange)?.let { advisorySources[index] = it }
                            add(FloatInteractionNode(index, FloatInteractionKind.LINK, range.start, range.end,
                                fragments, annotated.subSequence(range.start, range.end), (clippedActionSpan ?: actionGroup?.span ?: paddingOwner ?: citationSource)?.tooltip,
                                 citationCallbacks[range.start to range.end] ?: actionGroup?.let { actionGroupCallbacks.getValue(it.path) } ?: { when (val link = range.item) { is LinkAnnotation.Clickable -> link.linkInteractionListener?.onClick(link) ?: onLink(EntryLink(link.tag)); is LinkAnnotation.Url -> uri.openUri(link.url) }
                                    if (missingLinkPaint != null) onMissingLinkActivated()
                                    else state?.actionIdentity?.target?.let {
                                        (if (ordinary != null) visits else captionScope?.visits)?.record(it)
                                    }
                                    Unit
                                }, stateDescription = clippedActionSpan?.explanation?.takeIf { it.isNotEmpty() },
                                hitTest = if (roundedHitTests.isEmpty()) null else { x, y -> roundedHitTests.all { it(x, y) } },
                                missingLinkPaint = state, focusPaint = focus, citationMarker = citationMarker, clippedAbsoluteLocation = clippedLocation))
                        }
                        val firstImage = nativeLinks.size
                        images.forEach { image ->
                            val model = image.span.image!!
                            val url = inlineImageLinkUrl(image.span, edition)
                            val unresolved = image.span.kind == "link" && image.span.target.startsWith("File:") && url == null
                            val authoredActions = imageActions[image.id]
                            val click: (() -> Unit)? = if (authoredActions != null) authoredActions.onClick else when {
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
                            val fragments = geometry.rectsForRange(image.offset, image.offset + 1)
                            val focus = image.span.linkPaint?.let {
                                ordinaryLinkFocusPaint(it, fragments, density.density, bodyPixels)
                            }
                            ruby?.leaves?.getOrNull(image.id)?.range?.takeIf { it.span === image.span }?.let {
                                advisorySources[firstImage + image.id] = it
                            }
                            add(FloatInteractionNode(firstImage + image.id, FloatInteractionKind.IMAGE, image.offset, image.offset + 1,
                                fragments, accessibilityLabel, advice, click,
                                imageStatus(image.state) + if (unresolved) " Image link source unavailable" else "",
                                if (hasDetails) authoredActions?.onDetails ?: ({ details = image }) else null,
                                focusPaint = focus, sourceFocusVisible = image.span.linkPaint != null))
                        }
                        val afterImages = firstImage + visibleSpans.size
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
    }.let { withAdvisories(geometry, it, advisorySources) }.let { nodes ->
        // The nonpainting semantic heading must not cover its source-link hit targets.
        if (!authoredHeading) nodes else nodes.filter { it.kind == FloatInteractionKind.HEADING } +
            nodes.filter { it.kind != FloatInteractionKind.HEADING }
    } }
    val revision = remember(visibleSpans, annotated, effective, shapeKey, prepared, images.map { listOf(it.state, it.pixels, it.fallbackWidth, it.normalBodyPixels.takeIf { _ -> it.span.image?.occurrenceLayout != null }) }, imageActions.toMap(), bodyPixels.takeIf { imageActions.isNotEmpty() }, imageDarkTheme, density, rtl, paragraphGaps, containAtEnd, insets, prefix, prefixStyle, heading, headingActions, nativeLineHeight, inlineRevision, layoutUnavailable, sourceFamily, authoredHeading, ownerDirection, headingLabel, ownerWrap, ownerFont, cellMetricRevision, sourceLineStarts, referenceBacklink, referenceLayoutBacklink, outsideReferenceMarker, citationTargetAnchor, staticInlineParent, staticParentPaint?.typeface, staticParentPaint?.textSize, columnTextDirection, terminalFallback) { Any() }
    val citationPreparation = rememberNativeCitationPreparation(revision,
        citationSourceRanges.mapNotNull { it.span.citationMarker?.anchor },
        layoutUnavailable ?: textState.takeIf { prepared.values.any { value -> !value.available } })
    val widthFactory: ((Int, List<NativeFloatExclusion>, Boolean, Float?, Boolean) -> NativeFloatGeometry)? =
        nativeSource?.let { source -> { width, carried, requireDrained, exactWidth, exactParagraphInsets ->
                if (layoutUnavailable != null) throw UnsupportedFloatLayout(layoutUnavailable)
                val native = source(width)
                val floats = emptyList<NativeFloatOccurrence>()
                val marker = if (prefix.isEmpty()) null else if (outsideReferenceMarker) referenceMarker else NativeMarkerText(prefix, prefixPaint)
                NativeFloatGeometry.build(native, layoutPaint, width, floats,
                    textDirection = direction,
                    requireDrainedAtBoundary = requireDrained, carriedExclusions = carried, insets = insets,
                    decoration = { canvas, geometry ->
                        val band = geometry.firstLineBand()
                        if (marker != null) {
                            if (outsideReferenceMarker) {
                                val anchor = referenceMarkerAnchor(band.left, band.right, prefixWidth,
                                    checkNotNull(geometry.textBaselines?.first), rtl)
                                marker.paint(canvas, anchor.x, anchor.baseline, anchor.rightAligned)
                            } else {
                                val x = if (rtl) band.right + prefixWidth else band.left - prefixWidth
                                marker.paint(canvas, x, band.top - prefixPaint.ascent(), rightAligned = rtl)
                            }
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
                            if (outsideReferenceMarker) {
                                val anchor = referenceMarkerAnchor(band.left, band.right, prefixWidth,
                                    checkNotNull(geometry.textBaselines?.first), rtl)
                                bounds = marker.bounds(anchor.x, anchor.baseline, anchor.rightAligned)
                            } else {
                                val x = if (rtl) band.right + prefixWidth else band.left - prefixWidth
                                bounds = marker.bounds(x, band.top - prefixPaint.ascent(), rightAligned = rtl)
                            }
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
                    nodeFactory = nativeNodes, exactAvailableWidth = exactWidth,
                    exactParagraphInsets = exactParagraphInsets)


        } }
    val factory: ((Int, List<NativeFloatExclusion>, Boolean) -> NativeFloatGeometry)? = widthFactory?.let { create ->
        { width, carried, requireDrained -> create(width, carried, requireDrained, null, false) }
    }
    val geometryAtWidth: ((Float, List<NativeFloatExclusion>, Boolean) -> NativeFloatGeometry)? = widthFactory?.let { create ->
        { width, carried, requireDrained ->
            if (!width.isFinite() || width < 0f || width > TablePixelLimit)
                throw UnsupportedFloatLayout("Absolute text width exceeds native geometry")
            create(kotlin.math.floor(width).toInt(), carried, requireDrained, width, false)
        }
    }
    val geometryForColumns: ((Float) -> NativeFloatGeometry)? = widthFactory?.let { create ->
        { width ->
            if (!width.isFinite() || width < 0f || width > TablePixelLimit)
                throw UnsupportedFloatLayout("Column text width exceeds native geometry")
            create(kotlin.math.floor(width).toInt(), emptyList(), false, width, true)
        }
    }
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
        insets.left + insets.right + insets.extraLeft + insets.extraRight, breakWordMinimum = authoredHeading && ownerWrap == null,
        citationPreparation = citationPreparation, staticInline = staticInline) }, fallback = {
        if (!terminalFallback) {
        // The normal float owner already holds this image state. Failure UI reuses it.
        CompositionLocalProvider(LocalInlineImageOwner provides owner,
            LocalInlineImageOccurrenceFallback provides images.any { it.span.image?.occurrenceLayout != null },
            LocalOrdinaryLinkPaintNative provides false,
            LocalAuthoredInlineNative provides false, LocalRubyNative provides (ruby == null && containerOwner == null)) {
            Column(Modifier.padding(start = with(density) { indentPixels.toDp() })) {
                Row {
                    if (prefix.isNotEmpty()) Text(prefix, Modifier.width(with(density) { prefixWidth.toDp() }), style = prefixStyle ?: effective)
                    StyledText(spans, weight = rubyWeight.takeIf { ruby != null }, style = style, onLink = onLink, preserveWhitespace = ruby != null || ownerFont != null || authoredHeading || hasInlineFamily || sourceFamily is ContainerFontFamily.Stack)
                }
                if (!authoredHeading) headingActions.forEach { action -> TextButton(onClick = action.onClick) { Text(action.label) } }
            }
        }
        }
    }, ordinaryLinkPaintRevision = ordinaryPaintRevision, emptyInlineOwner = emptyInlineOwner, geometryAtWidth = geometryAtWidth,
        geometryForColumns = geometryForColumns,
        citationPreparation = citationPreparation)

}

/** Public native paragraph heuristic retains authored paragraph direction without inserting isolates. */
private fun nativeParagraphDirection(text: AnnotatedString, fallbackRtl: Boolean,
    tableDirection: TableContainingDirection?, bodyDirection: BidiResolvedDirection? = null,
    columnDirection: BidiResolvedDirection? = null): TextDirectionHeuristic {
    val fallback = when (compiledBodyParagraphDirection(tableDirection, bodyDirection, columnDirection)) {
        TextDirection.Ltr -> TextDirectionHeuristics.LTR
        TextDirection.Rtl -> TextDirectionHeuristics.RTL
        else -> if (fallbackRtl) TextDirectionHeuristics.FIRSTSTRONG_RTL else TextDirectionHeuristics.FIRSTSTRONG_LTR
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

private class NativeHeadingControlHeight(private val minimum: Int) : LineHeightSpan, NativeFloatRowMetricEffect {
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
    val geometryAtWidth: ((Float, List<NativeFloatExclusion>, Boolean) -> NativeFloatGeometry)? = null,
    val citationPreparation: NativeCitationPreparationStatus? = null,
    val geometryForColumns: ((Float) -> NativeFloatGeometry)? = null,
)

/** Styled source and actions, before paragraph shaping. Anonymous owners shape this source once. */
internal data class NativePreparedText(
    val paint: TextPaint,
    val source: (Int) -> Spanned,
    val nodes: (FloatTextGeometry) -> List<FloatInteractionNode>,
    val direction: TextDirectionHeuristic,
    val horizontalInsets: Float = 0f,
    val breakWordMinimum: Boolean = false,
    val citationPreparation: NativeCitationPreparationStatus? = null,
    val staticInline: NativeStaticInlineText? = null,
)
