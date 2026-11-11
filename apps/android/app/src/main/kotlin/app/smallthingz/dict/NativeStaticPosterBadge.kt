package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableString
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import kotlin.math.floor

/** Native source-font label painted as one opacity group inside its existing wrapper. */
internal class NativeStaticPosterBadge(val identity: StaticPoster, private val density: Float) {
    val text = staticPosterPaintedLabel(identity.label)
    val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create("sans-serif", Typeface.BOLD)
        textSize = 14f * density
        color = 0xff1e1f21.toInt()
    }
    init { require(density.isFinite() && density > 0f); figureCoordinate(19f * density) }

    internal data class Box(val bounds: RectF, val layout: StaticLayout?, val lines: List<NativeLinePaintPlacement>)
    internal fun box(wrapper: RectF): Box {
        val left = wrapper.left + 11f * density
        val top = wrapper.top + 11f * density
        if (text.isEmpty()) return Box(RectF(left, top, left + 10f * density, top + 4f * density), null, emptyList())
        val source = SpannableString(text)
        val intrinsic = nativeTextWidthRange(source, paint)
        val available = floor(wrapper.right - left - 10f * density).toInt().coerceAtLeast(0)
        val width = minOf(intrinsic.maximum, maxOf(intrinsic.minimum, available))
        val layout = StaticLayout.Builder.obtain(source, 0, source.length, paint, width)
            .setTextDirection(TextDirectionHeuristics.LTR).setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(false).setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
        val fm = paint.fontMetrics
        val lineHeight = 19f * density
        val baseline = (lineHeight - (fm.descent - fm.ascent)) / 2f - fm.ascent
        val lines = List(layout.lineCount) { NativeLinePaintPlacement(it, baseline + it * lineHeight) }
        return Box(RectF(left, top, left + width + 10f * density, top + layout.lineCount * lineHeight + 4f * density), layout, lines)
    }

    fun draw(canvas: Canvas, wrapper: RectF) {
        if (wrapper.isEmpty) return
        val box = box(wrapper)
        val saved = canvas.save()
        try {
            canvas.clipRect(wrapper)
            // Alpha belongs to the entire badge, not separately to the glyphs and background.
            val group = canvas.saveLayerAlpha(wrapper, 204)
            try {
                canvas.drawRoundRect(box.bounds, 2f * density, 2f * density,
                    Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xfff8f9fa.toInt() })
                box.layout?.let { shaped ->
                    canvas.translate(box.bounds.left + 5f * density, box.bounds.top + 2f * density)
                    NativeLinePainter(shaped).paint(canvas, box.lines)
                }
            } finally { canvas.restoreToCount(group) }
        } finally { canvas.restoreToCount(saved) }
    }
}
