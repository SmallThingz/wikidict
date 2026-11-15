package app.smallthingz.dict

import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import java.text.Bidi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

internal data class EgyptianTextRun(val start: Int, val end: Int, val text: String, val reuseLtr: Boolean, val foreground: String? = null, val background: String? = null,
    val fontFeatures: FontFeaturePolicy? = null) {
    val id: String get() = "egyptian:$start:$end"
}

/** Contiguous sign/control runs only: ordinary text, whitespace and trails remain text. */
internal fun egyptianTextRuns(spans: List<Span>): List<EgyptianTextRun> {
    if (!spans.hasRuby()) return ordinaryEgyptianTextRuns(spans)
    return rubyGraphicalProjection(spans).ranges.flatMap { range ->
        val span = range.span.takeUnless { range.role == RubyTextRole.Owner }
        if (span == null) emptyList() else ordinaryEgyptianTextRuns(listOf(span), directionControls = false).map {
            it.copy(start = range.start + it.start, end = range.start + it.end)
        }
    }
}

private fun ordinaryEgyptianTextRuns(spans: List<Span>, directionControls: Boolean = true): List<EgyptianTextRun> {
    val runs = mutableListOf<EgyptianTextRun>()
    var offset = 0
    for (span in spans) {
        val isolated = directionControls && span.usesInlineDirectionIsolate()
        if (isolated) offset++
        if (span.image != null) offset += InlineImageReplacement.length
        val text = if (span.kind == "line_break") "\n" else span.text
        // Zero remains original annotated text, never a positive-size shaping
        // request or an error placeholder. Its Compose layout needs qualification.
        if (!span.code && span.fontScale != 0f && span.classes.split(Regex("\\s+")).any { it == "Egyp" }) {
            var at = 0
            while (at < text.length) {
                val point = text.codePointAt(at)
                if (point !in 0x13000..0x13455) { at += Character.charCount(point); continue }
                val begin = at
                while (at < text.length && text.codePointAt(at) in 0x13000..0x13455) at += Character.charCount(text.codePointAt(at))
                runs.add(EgyptianTextRun(offset + begin, offset + at, text.substring(begin, at), span.direction == "ltr", span.foreground, span.background, span.fontFeatures))
            }
        }
        offset += text.length + span.trail.length
        if (isolated) offset++
    }
    return runs
}

/** Original scalars are alternateText. Added isolates follow StyledText's existing
 * direction convention; paragraph direction is resolved before adding them.
 */
internal fun egyptianInlineText(original: AnnotatedString, runs: List<EgyptianTextRun>, rtlFallback: Boolean): AnnotatedString {
    val inserted = runs.filterNot { it.reuseLtr }
    fun mapped(offset: Int): Int = offset + inserted.sumOf {
        (if (it.start < offset) 1 else 0) + (if (it.end <= offset) 1 else 0)
    }
    return buildAnnotatedString {
        var cursor = 0
        for (run in runs) {
            require(run.start >= cursor && run.end <= original.length && original.text.substring(run.start, run.end) == run.text)
            append(original.text.substring(cursor, run.start))
            if (!run.reuseLtr) append('\u2066')
            appendInlineContent(run.id, run.text)
            if (!run.reuseLtr) append('\u2069')
            cursor = run.end
        }
        append(original.text.substring(cursor))
        original.spanStyles.forEach { addStyle(it.item, mapped(it.start), mapped(it.end)) }
        original.paragraphStyles.forEach { addStyle(it.item, mapped(it.start), mapped(it.end)) }
        original.getStringAnnotations(0, original.length).forEach { addStringAnnotation(it.tag, it.item, mapped(it.start), mapped(it.end)) }
        original.getLinkAnnotations(0, original.length).forEach { range ->
            when (val link = range.item) {
                is LinkAnnotation.Clickable -> addLink(link, mapped(range.start), mapped(range.end))
                is LinkAnnotation.Url -> addLink(link, mapped(range.start), mapped(range.end))
            }
        }
        var start = 0
        while (start < original.length) {
            val newline = original.text.indexOf('\n', start)
            val textEnd = if (newline < 0) original.length else newline
            val end = if (newline < 0) original.length else newline + 1
            val explicitDirection = original.paragraphStyles.any {
                it.start <= start && it.end >= end &&
                    (it.item.textDirection == TextDirection.Ltr || it.item.textDirection == TextDirection.Rtl)
            }
            if (!explicitDirection) {
                val bidi = Bidi(original.text.substring(start, textEnd), if (rtlFallback) Bidi.DIRECTION_DEFAULT_RIGHT_TO_LEFT else Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT)
                addStyle(ParagraphStyle(textDirection = if (bidi.baseIsLeftToRight()) TextDirection.Ltr else TextDirection.Rtl), mapped(start), mapped(end))
            }
            start = end
        }
    }
}

internal val EgyptianShapedRunCount = SemanticsPropertyKey<Int>("EgyptianShapedRunCount")
internal val EgyptianVisibleScales = SemanticsPropertyKey<List<Float>>("EgyptianVisibleScales")

@Composable
internal fun EgyptianInlineText(original: AnnotatedString, runs: List<EgyptianTextRun>, modifier: Modifier, style: TextStyle, linkColor: Color,
    extraInlineContent: Map<String, InlineTextContent> = emptyMap()) {
    if (runs.isEmpty()) {
        Text(original, modifier = modifier, style = style, inlineContent = extraInlineContent)
        return
    }
    EgyptianInlineTextApi31(original, runs, modifier, style, linkColor, extraInlineContent)
}

private data class EgyptianLine(val position: Float, val thickness: Float)

private data class EgyptianInk(val glyphs: EgyptianGlyphRun, val left: Float, val top: Float, val width: Float, val height: Float,
                               val bold: Boolean, val italic: Boolean, val ascent: Int, val descent: Int,
                               val baselineShift: Int, val decorations: List<EgyptianLine>)

private fun glyphPaint(size: Float, bold: Boolean, italic: Boolean) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    textSize = size
    isFakeBoldText = bold
    textSkewX = if (italic) -0.25f else 0f
}

private data class PreparedEgyptianText(val request: Any, val runs: Map<String, Result<EgyptianInk>>)

@Composable
private fun EgyptianInlineTextApi31(original: AnnotatedString, runs: List<EgyptianTextRun>, modifier: Modifier, style: TextStyle, linkColor: Color,
    extraInlineContent: Map<String, InlineTextContent>) {
    val context = LocalContext.current.applicationContext
    val density = LocalDensity.current
    val fallbackRtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val effectiveStyle = LocalTextStyle.current.merge(style)
    val contentColor = if (effectiveStyle.color != Color.Unspecified) effectiveStyle.color else LocalContentColor.current
    val inheritedBackground = LocalAuthoredBackground.current
    val baseSize = with(density) { (if (effectiveStyle.fontSize.isSp) effectiveStyle.fontSize else 16.sp).toPx() }
    val viewportWidth = LocalWindowInfo.current.containerSize.width.toFloat().coerceAtLeast(1f)
    val annotated = remember(original, runs, fallbackRtl) { egyptianInlineText(original, runs, fallbackRtl) }
    val request = remember(original, runs, effectiveStyle, baseSize) { Any() }
    val produced by produceState<PreparedEgyptianText?>(null, request) {
        val completed = linkedMapOf<String, Result<EgyptianInk>>()
        for (run in runs) {
            completed[run.id] = try {
                requireEgyptianFeatureSupport(run.fontFeatures)
                val spanStyle = original.spanStyles.filter { it.start <= run.start && it.end >= run.end }
                    .fold(effectiveStyle.toSpanStyle()) { merged, range -> merged.merge(range.item) }
                val size = when {
                    spanStyle.fontSize.isEm -> baseSize * spanStyle.fontSize.value
                    spanStyle.fontSize.isSp -> with(density) { spanStyle.fontSize.toPx() }
                    else -> baseSize
                }
                val bold = (spanStyle.fontWeight ?: FontWeight.Normal).weight >= FontWeight.SemiBold.weight
                val italic = spanStyle.fontStyle == FontStyle.Italic
                val tracking = when {
                    spanStyle.letterSpacing.isSp -> with(density) { spanStyle.letterSpacing.toPx() }
                    spanStyle.letterSpacing.isEm -> size * spanStyle.letterSpacing.value
                    else -> 0f
                }
                val glyphs = EgyptianShaper.shape(context, run.text, size).withTracking(run.text, tracking)
                Result.success(withContext(Dispatchers.IO) {
                    val paint = glyphPaint(size, bold, italic).apply {
                        // Match the font metrics used by Compose's resource-font span.
                        typeface = context.resources.getFont(R.font.egyptian_hieroglyphs)
                    }
                    val metrics = paint.fontMetricsInt
                    val shift = ceil(paint.ascent() * (spanStyle.baselineShift?.multiplier ?: 0f)).toInt()
                    val decoration = spanStyle.textDecoration ?: TextDecoration.None
                    val linked = original.getLinkAnnotations(run.start, run.end).isNotEmpty()
                    val lines = buildList {
                        // Native links keep a visible public underline without observing
                        // Compose's private pressed state or intercepting pointer input.
                        if (linked || TextDecoration.Underline in decoration) add(EgyptianLine(paint.underlinePosition, max(1f, paint.underlineThickness)))
                        if (TextDecoration.LineThrough in decoration) add(EgyptianLine(paint.strikeThruPosition, max(1f, paint.strikeThruThickness)))
                    }
                    var ink: RectF? = null
                    for (index in 0 until glyphs.glyphCount()) {
                        val rect = RectF()
                        glyphs.getFont(index).getGlyphBounds(glyphs.getGlyphId(index), paint, rect)
                        if (!rect.isEmpty) {
                            rect.offset(glyphs.getGlyphX(index), glyphs.getGlyphY(index))
                            if (ink == null) ink = rect else ink!!.union(rect)
                        }
                    }
                    val bounds = checkNotNull(ink) { "Egyptian run has no drawing glyphs" }
                    for (line in lines) bounds.union(0f, line.position - line.thickness / 2f,
                        glyphs.advance, line.position + line.thickness / 2f)
                    val left = min(0f, bounds.left)
                    val width = max(glyphs.advance, bounds.right) - left
                    val height = bounds.height()
                    check(width.isFinite() && height.isFinite() && width > 0f && height > 0f)
                    EgyptianInk(glyphs, left, bounds.top, width, height, bold, italic,
                        metrics.ascent, metrics.descent, shift, lines)
                })
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: LinkageError) { Result.failure(failure) }
            catch (failure: Exception) { Result.failure(failure) }
            value = PreparedEgyptianText(request, completed.toMap())
        }
    }
    // produceState retains its previous value across key changes. Never draw that
    // previous paragraph's glyphs under a new logical string while its work starts.
    val prepared = produced?.takeIf { it.request === request }?.runs.orEmpty()
    val textMeasurer = rememberTextMeasurer()
    val naturalPlaceholders = runs.associate { run ->
        val ink = prepared[run.id]?.getOrNull()
        run.id to Placeholder(with(density) { (ink?.width ?: baseSize * 3f).toSp() },
            with(density) { (ink?.height ?: baseSize).toSp() }, PlaceholderVerticalAlign.TextCenter)
    } + extraInlineContent.mapValues { it.value.placeholder }
    val placeholderRanges = annotated.getStringAnnotations(0, annotated.length).mapNotNull { range ->
        naturalPlaceholders[range.item]?.let { AnnotatedString.Range(it, range.start, range.end) }
    }
    val intrinsicModifier = modifier.nativeWidthIntrinsics {
        val paragraph = textMeasurer.measure(annotated, style = effectiveStyle, placeholders = placeholderRanges,
            softWrap = false).multiParagraph.intrinsics
        fun pixels(value: Float) = if (!value.isFinite() || value > TablePixelLimit)
            androidx.compose.ui.unit.Constraints.Infinity else ceil(value).toInt()
        NativeWidthRange(pixels(paragraph.minIntrinsicWidth), pixels(paragraph.maxIntrinsicWidth))
    }
    BoxWithConstraints(intrinsicModifier, propagateMinConstraints = true) {
        val available = if (constraints.hasBoundedWidth) constraints.maxWidth.toFloat() else viewportWidth
        val scales = runs.mapNotNull { run -> prepared[run.id]?.getOrNull()?.let { min(1f, available / it.width) } }
        val content = runs.associate { run ->
            val result = prepared[run.id]
            val ink = result?.getOrNull()
            val naturalWidth = ink?.width ?: baseSize * 3f
            val scale = min(1f, available / naturalWidth)
            val width = naturalWidth * scale
            // TextCenter uses integer resource-font metrics at the unscaled span
            // size. Reserve both sides of that center for all shifted/scaled ink.
            // Two extra pixels cover Compose's ceil-height and integer-center rounding.
            val height = if (ink != null) {
                val center = (ink.ascent + ink.descent) / 2f
                val top = (ink.top + ink.baselineShift) * scale
                val bottom = (ink.top + ink.height + ink.baselineShift) * scale
                max(1f, ceil(2f * max(center - top, bottom - center)) + 2f)
            } else baseSize
            val linked = original.getLinkAnnotations(run.start, run.end).isNotEmpty()
            val color = authoredSpanForegroundArgb(run.foreground, run.background ?: inheritedBackground)
                ?.let { Color(it) } ?: if (linked) linkColor else contentColor
            val background = canonicalColorArgb(run.background)
            run.id to InlineTextContent(Placeholder(with(density) { width.toSp() }, with(density) { height.toSp() }, PlaceholderVerticalAlign.TextCenter)) {
                Canvas(Modifier.fillMaxSize()) {
                    drawIntoCanvas { composeCanvas ->
                        val canvas = composeCanvas.nativeCanvas
                        val paint = glyphPaint(ink?.glyphs?.textSize ?: baseSize, ink?.bold ?: false, ink?.italic ?: false).apply { this.color = color.toArgb() }
                        if (ink != null && scale > 0f) {
                            if (background != null) {
                                // Paint the existing reserved range without changing its geometry.
                                paint.color = background.toInt()
                                canvas.drawRect(0f, 0f, size.width, size.height, paint)
                                paint.color = color.toArgb()
                            }
                            val saved = canvas.save()
                            try {
                                // Invert AndroidParagraph's exact integer TextCenter
                                // placement using the actual measured child height.
                                val baseline = -((ink.ascent + ink.descent - size.height.toInt()) / 2).toFloat()
                                canvas.translate(0f, baseline)
                                canvas.scale(scale, scale)
                                canvas.translate(-ink.left, ink.baselineShift.toFloat())
                                ink.glyphs.draw(canvas, paint)
                                for (line in ink.decorations) {
                                    paint.strokeWidth = line.thickness
                                    canvas.drawLine(0f, line.position, ink.glyphs.advance, line.position, paint)
                                }
                            } finally { canvas.restoreToCount(saved) }
                        } else if (result?.isFailure == true) {
                            // An explicit unavailable marker, never broken system shaping.
                            paint.textSize = max(1f, height)
                            canvas.drawText("!", 0f, height, paint)
                        }
                    }
                }
            }
        }
        val failed = prepared.values.any { it.isFailure }
        Text(annotated, style = style, inlineContent = content + extraInlineContent, modifier = Modifier.semantics {
            this[EgyptianShapedRunCount] = prepared.values.count { it.isSuccess }
            this[EgyptianVisibleScales] = scales
            if (failed) stateDescription = "Egyptian glyph layout unavailable"
        })
    }
}
