package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import kotlin.math.abs

/** One original action occurrence. Equal source values never merge owner identities. */
internal class NativeInlineActionOwner(val span: Span, val path: String)

/** A selected native line's complete disjoint selection path. Only its vertical band
 * is normalized; physical bidi x positions and all contours remain native. */
internal class NativeInlineActionFragment(
    val line: Int,
    val start: Int,
    val end: Int,
    path: Path,
    val baseline: Float,
) {
    private val normalized = Path(path)
    init {
        require(line >= 0 && start >= 0 && end > start)
        val bounds = RectF().also { normalized.computeBounds(it, true) }
        nativeInlineActionCoordinates(baseline, bounds.left, bounds.top, bounds.right, bounds.bottom)
        if (bounds.width() <= 0f || bounds.height() <= 0f)
            throw UnsupportedFloatLayout("Inline action fragment lacks its native selection band")
    }
    internal fun pathForBand(top: Float, bottom: Float): Path {
        nativeInlineActionCoordinates(top, bottom)
        if (bottom < top) throw UnsupportedFloatLayout("Inline action band is reversed")
        return Path(normalized).apply {
            transform(Matrix().apply { setValues(floatArrayOf(
                1f, 0f, 0f, 0f, bottom - top, top, 0f, 0f, 1f)) })
        }
    }
    internal fun boundsForBand(top: Float, bottom: Float): NativeFloatBounds? {
        if (bottom <= top) return null
        val bounds = RectF().also { pathForBand(top, bottom).computeBounds(it, true) }
        nativeInlineActionCoordinates(bounds.left, bounds.top, bounds.right, bounds.bottom)
        return if (bounds.isEmpty) null else NativeFloatBounds(bounds.left, bounds.top, bounds.right, bounds.bottom)
    }
}

private fun nativeInlineActionCoordinates(vararg values: Float) {
    if (values.any { !it.isFinite() || abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Inline action geometry exceeds native coordinates")
}

/** Declaring-font paint is independent of child fonts and script placement. The
 * caller schedules backgrounds before native glyphs and decorations afterward. */
internal class NativeInlineActionPaint(
    private val format: NativeRubyGroupFormat,
    private val shift: Float,
    fragments: List<NativeInlineActionFragment>,
    private val currentColorPaint: NativeMissingLinkPaint? = null,
) {
    private val fragments = fragments.toList()
    private val primary = NativePrimaryFontMetrics.from(format.paint)
    private data class Decoration(val position: Float, val thickness: Float,
        val color: Int, val style: InlineUnderlineStyle)
    init {
        nativeInlineActionCoordinates(shift, primary.ascent, primary.descent)
        if (primary.descent < primary.ascent)
            throw UnsupportedFloatLayout("Inline action declaring font has reversed metrics")
    }
    private fun selected(line: Int?) = if (line == null) fragments else fragments.filter { it.line == line }
    private fun decorations(reserve: Boolean): List<Decoration> {
        val appearance = if (reserve) null else format.actionPaint?.appearance()
        val color = appearance?.color ?: (if (reserve) null else currentColorPaint?.appearance()?.color) ?: format.paint.color
        return buildList {
            fun addDecoration(position: Float, thickness: Float, color: Int, style: InlineUnderlineStyle) {
                nativeInlineActionCoordinates(position, thickness)
                if (thickness > 0f) add(Decoration(position, thickness, color, style))
            }
            if (format.paint.isStrikeThruText) addDecoration(format.paint.strikeThruPosition,
                format.paint.strikeThruThickness, color, InlineUnderlineStyle.Solid)
            val authored = format.underline
            if (authored != null) addDecoration(format.paint.underlinePosition,
                authored.thickness ?: format.paint.getUnderlineThickness(),
                authored.color ?: color, authored.style)
            else if (reserve && format.actionPaint != null || (appearance?.underline ?: format.paint.isUnderlineText))
                addDecoration(format.paint.underlinePosition, format.paint.getUnderlineThickness(), color, InlineUnderlineStyle.Solid)
        }
    }
    /** Conservative envelopes only; paint and hit geometry never use their unions. */
    fun bounds(line: Int? = null): List<NativeFloatBounds> = buildList {
        val decorations = decorations(reserve = true)
        selected(line).forEach { fragment ->
            val baseline = fragment.baseline + shift
            if (format.paint.bgColor ushr 24 != 0)
                fragment.boundsForBand(baseline + primary.ascent, baseline + primary.descent)?.let(::add)
            decorations.forEach { decoration ->
                val top = baseline + decoration.position
                fragment.boundsForBand(top, top + decoration.thickness)?.let(::add)
            }
        }
    }
    fun paintBackgrounds(canvas: Canvas, line: Int? = null) {
        val color = format.paint.bgColor
        if (color ushr 24 == 0) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        selected(line).forEach { fragment ->
            val baseline = fragment.baseline + shift
            if (primary.descent > primary.ascent)
                canvas.drawPath(fragment.pathForBand(baseline + primary.ascent, baseline + primary.descent), paint)
        }
    }
    fun paintDecorations(canvas: Canvas, line: Int? = null) {
        val decorations = decorations(reserve = false)
        selected(line).forEach { fragment ->
            val baseline = fragment.baseline + shift
            decorations.forEach decoration@{ decoration ->
                if (decoration.color ushr 24 != 0) {
                    val top = baseline + decoration.position
                    val bottom = top + decoration.thickness
                    val path = fragment.pathForBand(top, bottom)
                    if (decoration.style == InlineUnderlineStyle.Solid) {
                        canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = decoration.color })
                    } else {
                        val bounds = fragment.boundsForBand(top, bottom) ?: return@decoration
                        val saved = canvas.save()
                        try {
                            canvas.clipPath(path)
                            NativeInlineDecorationFragment(bounds, decoration.color, decoration.style).paint(canvas)
                        } finally { canvas.restoreToCount(saved) }
                    }
                }
            }
        }
    }
}
