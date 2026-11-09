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

internal data class NativeHeadingAction(val label: String, val collapsed: Boolean, val onClick: () -> Unit)

private data class NativeStyleRange(val start: Int, val end: Int, val paint: TextPaint, val bold: Boolean, val italic: Boolean,
    val baselineShiftMultiplier: Float, val letterSpacingPixels: Float?)
private class NativePaintSpan(private val value: TextPaint) : MetricAffectingSpan() {
    override fun updateMeasureState(paint: TextPaint) { paint.set(value) }
    override fun updateDrawState(paint: TextPaint) { paint.set(value) }
}

/** Partition at every authored style/link boundary; overlapping styles are merged in their original order. */
@Composable
private fun nativeStyleRanges(text: AnnotatedString, effective: TextStyle, linkColor: Color): List<NativeStyleRange> {
    val density = LocalDensity.current
    val resolver = LocalFontFamilyResolver.current
    val contentColor = LocalContentColor.current
    val baseSize = with(density) { effective.fontSize.toPx() }
    val links = text.getLinkAnnotations(0, text.length)
    val cuts = (listOf(0, text.length) + text.spanStyles.flatMap { listOf(it.start, it.end) } +
        links.flatMap { listOf(it.start, it.end) }).distinct().sorted()
    return cuts.zipWithNext().map { (start, end) ->
        var style = text.spanStyles.filter { it.start <= start && it.end >= end }
            .fold(effective.toSpanStyle()) { merged, range -> merged.merge(range.item) }
        links.filter { it.start <= start && it.end >= end }.forEach { link ->
            style = style.merge(link.item.styles?.style ?: SpanStyle(color = linkColor))
        }
        val face by resolver.resolve(style.fontFamily ?: FontFamily.Default, style.fontWeight ?: FontWeight.Normal,
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
            if (style.letterSpacing.isSp) with(density) { style.letterSpacing.toPx() } else null)
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
    val paint: TextPaint, val pixels: InlineImagePixels, val draw: (Canvas, RectF) -> Unit,
)

private class NativeInlineImageSpan(private val image: NativeImage) : ReplacementSpan() {
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
): PreparedNativeFloatText {
    val context = LocalContext.current
    val density = LocalDensity.current
    val uri = LocalUriHandler.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val effective = LocalTextStyle.current.merge(style)
    require(effective.fontSize.isSp)
    val styles = nativeStyleRanges(annotated, effective, linkColor)
    val basePaint = nativeStyleRanges(AnnotatedString(" "), effective, linkColor).single().paint
    val prefixPaint = nativeStyleRanges(AnnotatedString(" "), prefixStyle ?: effective, linkColor).single().paint
    val prefixWidth = if (prefix.isEmpty()) 0f else 28f * density.density
    val actionSize = 48f * density.density
    val actionWidth = actionSize * headingActions.size
    val insets = if (rtl) NativeTextInsets(right = indentPixels, extraRight = prefixWidth, extraLeft = actionWidth)
        else NativeTextInsets(left = indentPixels, extraLeft = prefixWidth, extraRight = actionWidth)
    fun actionBounds(geometry: NativeFloatGeometry, index: Int): RectF {
        val band = geometry.firstLineBand()
        val left = if (rtl) band.left - actionWidth + index * actionSize else band.right + index * actionSize
        return RectF(left, band.top, left + actionSize, band.top + actionSize)
    }
    fun paintAt(offset: Int) = TextPaint().apply { set(styles.firstOrNull { offset in it.start until it.end }?.paint ?: basePaint) }
    val owner = LocalInlineImageOwner.current ?: rememberInlineImageViewOwner(spans.mapNotNull { it.image }, media, settings, edition)
    spans.mapNotNull { it.image?.file }.distinct().forEach { file -> LaunchedEffect(owner, file) { owner.ensure(file) } }
    var details by remember { mutableStateOf<NativeImage?>(null) }
    val images = mutableListOf<NativeImage>()
    var offset = 0
    spans.forEachIndexed { id, span ->
        if (span.direction in listOf("rtl", "ltr", "auto")) offset++
        span.image?.let { image ->
            check(annotated.text.getOrNull(offset) == '\ufffc') { "Compiled image offset drift" }
            val paint = paintAt(offset)
            val asset = owner.states[image.file] ?: if (settings.allowImages) InlineImageAssetState.Loading else InlineImageAssetState.Disabled
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
                        Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
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
            images += NativeImage(id, offset, span, state, paint, outerPixels, draw)
        }
        offset += if (span.image != null) 1 else if (span.kind == "line_break") 1 else span.text.length
        offset += span.trail.length
        if (span.direction in listOf("rtl", "ltr", "auto")) offset++
    }
    check(offset == annotated.length) { "Native context must retain the original logical string" }
    // Shape once per text/font request, then resize the immutable ink without reshaping it.
    val shapeKey = listOf(annotated, runs, effective, density.density, density.fontScale,
        styles.map { listOf(it.start, it.end, it.paint.typeface, it.paint.textSize, it.paint.color, it.paint.bgColor, it.paint.baselineShift) })
    val shaped by produceState<Pair<Any, Map<Int, NativeEgyptianSpanPreparation>>?>(null, shapeKey) {
        val result = linkedMapOf<Int, NativeEgyptianSpanPreparation>()
        for (run in runs) {
            val paint = paintAt(run.start)
            styles.firstOrNull { run.start in it.start until it.end }?.let {
                paint.isFakeBoldText = it.bold
                if (it.italic) paint.textSkewX = -0.25f
            }
            result[run.start] = prepareNativeEgyptianSpan(context.applicationContext, run, paint,
                if (paint.ascent() == 0f) 0f else paint.baselineShift / paint.ascent(),
                paint.isUnderlineText, paint.isStrikeThruText, paint.color, paint.bgColor.takeIf { it != 0 })
        }
        value = shapeKey to result
    }
    val prepared = shaped?.takeIf { it.first == shapeKey }?.second.orEmpty()
    val textState = when {
        runs.isNotEmpty() && prepared.size != runs.size -> "Loading Egyptian glyph layout"
        prepared.values.any { !it.available } -> "Egyptian glyph layout unavailable"
        else -> null
    }
    val direction = nativeParagraphDirection(annotated, rtl)
    val nativeSource: ((Int) -> Spanned)? =
        if (runs.isNotEmpty() && prepared.size != runs.size) null else { width ->
                val native = SpannableString(annotated.text)
                styles.forEach { native.setSpan(NativePaintSpan(it.paint), it.start, it.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                val paragraphStarts = listOf(0) + annotated.text.indices.filter { annotated.text[it] == '\n' && it + 1 < annotated.length }.map { it + 1 }
                paragraphStarts.forEachIndexed { index, start ->
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
                    val lineHeight = paragraphStyle.lineHeight
                    val height = if (lineHeight.isSp) with(density) { lineHeight.toPx() }
                        else if (lineHeight.isEm) basePaint.textSize * lineHeight.value else 0f
                    if (height.isFinite() && height > 0f) native.setSpan(NativeLineHeight(ceil(height).toInt()),
                        start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                annotated.paragraphStyles.forEach { range ->
                    range.item.textIndent?.let { indent ->
                        fun pixels(value: androidx.compose.ui.unit.TextUnit) = if (value.isEm) value.value * basePaint.textSize
                            else if (value.isSp) with(density) { value.toPx() } else 0f
                        native.setSpan(LeadingMarginSpan.Standard(pixels(indent.firstLine).toInt(), pixels(indent.restLine).toInt()),
                            range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                }
                if (headingActions.isNotEmpty() && native.isNotEmpty())
                    native.setSpan(NativeHeadingControlHeight(ceil(actionSize).toInt()), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                paragraphGaps.forEach { (end, gapDp) -> if (end > 0) native.setSpan(object : LineHeightSpan {
                    override fun chooseHeight(text: CharSequence, start: Int, finish: Int, spanstartv: Int, v: Int, fm: Paint.FontMetricsInt) {
                        if (finish >= end) { val gap = ceil(gapDp * density.density).toInt(); fm.descent += gap; fm.bottom += gap }
                    }
                }, end - 1, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                runs.forEach { run ->
                    // The replacement owns its baseline and decoration; native TextLine must not apply them again.
                    val replacementPaint = paintAt(run.start).apply { baselineShift = 0; isUnderlineText = false; isStrikeThruText = false; bgColor = 0 }
                    native.setSpan(NativePaintSpan(replacementPaint), run.start, run.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    native.setSpan(prepared.getValue(run.start).spanForWidth(width.toFloat()), run.start, run.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                images.forEach { image ->
                    val replacementPaint = paintAt(image.offset).apply { baselineShift = 0 }
                    native.setSpan(NativePaintSpan(replacementPaint), image.offset, image.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    native.setSpan(NativeInlineImageSpan(image), image.offset, image.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                native
        }
    val nativeNodes: (FloatTextGeometry) -> List<FloatInteractionNode> = { geometry -> buildList {
                        annotated.getLinkAnnotations(0, annotated.length).forEachIndexed { index, range ->
                            add(FloatInteractionNode(index, FloatInteractionKind.LINK, range.start, range.end,
                                geometry.rectsForRange(range.start, range.end), annotated.subSequence(range.start, range.end), null,
                                { when (val link = range.item) { is LinkAnnotation.Clickable -> link.linkInteractionListener?.onClick(link) ?: onLink(EntryLink(link.tag)); is LinkAnnotation.Url -> uri.openUri(link.url) } }))
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
                            0, annotated.length, geometry.rectsForRange(0, annotated.length), annotated.text, null, null))
                        headingActions.forEachIndexed { index, action ->
                            add(FloatInteractionNode(afterImages + 2 + index, FloatInteractionKind.CONTROL, 0, annotated.length,
                                listOf(actionBounds(geometry as NativeFloatGeometry, index)), action.label, null, action.onClick,
                                if (action.collapsed) "Collapsed" else "Expanded"))
                        }
    } }
    val factory: ((Int, List<NativeFloatExclusion>, Boolean) -> NativeFloatGeometry)? =
        nativeSource?.let { source -> { width, carried, requireDrained ->
                val native = source(width)
                val floats = emptyList<NativeFloatOccurrence>()
                NativeFloatGeometry.build(native, basePaint, width, floats,
                    textDirection = direction,
                    requireDrainedAtBoundary = requireDrained, carriedExclusions = carried, insets = insets,
                    decoration = { canvas, geometry ->
                        val band = geometry.firstLineBand()
                        if (prefix.isNotEmpty()) {
                            val markerPaint = TextPaint(prefixPaint).apply { textAlign = if (rtl) Paint.Align.RIGHT else Paint.Align.LEFT }
                            val x = if (rtl) band.right + prefixWidth else band.left - prefixWidth
                            canvas.drawText(prefix, x, band.top - markerPaint.ascent(), markerPaint)
                        }
                        val icon = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = linkColor.toArgb(); this.style = Paint.Style.STROKE; strokeWidth = 2f * density.density }
                        headingActions.forEachIndexed { index, action ->
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
                    nodeFactory = nativeNodes)


        } }
    val revision = remember(spans, annotated, effective, shapeKey, prepared, images.map { it.state }, density, rtl, paragraphGaps, containAtEnd, insets, prefix, prefixStyle, heading, headingActions) { Any() }
    return PreparedNativeFloatText(annotated.text, textState, revision, factory, {
        val detail = details
        DropdownMenu(expanded = detail != null, onDismissRequest = { details = null }) {
            if (detail != null) {
                detail.span.imageTooltip?.takeIf { it.isNotEmpty() }?.let { DropdownMenuItem(text = { Text(it) }, onClick = {}, enabled = false) }
                if (detail.state == InlineImageAssetState.Failed || detail.state is InlineImageAssetState.GeometryUnavailable) DropdownMenuItem(text = { Text("Retry image") }, onClick = {
                    details = null; owner.retry(detail.span.image!!.file)
                })
                if (detail.state is InlineImageAssetState.GeometryUnavailable) DropdownMenuItem(text = { Text("Image size unavailable") }, onClick = {}, enabled = false)
                val ready = when (val state = detail.state) { is InlineImageAssetState.Ready -> state; is InlineImageAssetState.GeometryUnavailable -> state.resource; else -> null }
                ready?.let { asset ->
                    asset.credit.takeIf { it.isNotEmpty() }?.let { DropdownMenuItem(text = { Text(it) }, onClick = {}, enabled = false) }
                    DropdownMenuItem(text = { Text("Source and licence") }, onClick = { details = null; uri.openUri(asset.source) })
                }
            }
        }
    }, nativeSource?.let { NativePreparedText(basePaint, it, nativeNodes, direction) })

}

/** Public native paragraph heuristic retains authored paragraph direction without inserting isolates. */
private fun nativeParagraphDirection(text: AnnotatedString, fallbackRtl: Boolean): TextDirectionHeuristic {
    val fallback = if (fallbackRtl) TextDirectionHeuristics.FIRSTSTRONG_RTL else TextDirectionHeuristics.FIRSTSTRONG_LTR
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
)

/** Styled source and actions, before paragraph shaping. Anonymous owners shape this source once. */
internal data class NativePreparedText(
    val paint: TextPaint,
    val source: (Int) -> Spanned,
    val nodes: (FloatTextGeometry) -> List<FloatInteractionNode>,
    val direction: TextDirectionHeuristic,
)
