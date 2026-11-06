package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF

/** Semantic paragraphs stay intact. Child blocks retain their existing native/Compose renderer. */
internal sealed interface NativeFloatContextPart {
    data class Text(
        val text: CharSequence,
        val build: (Int, List<NativeFloatExclusion>) -> NativeFloatGeometry,
        val gapAfter: Float = 0f,
    ) : NativeFloatContextPart
    data class Child(
        val id: Int,
        val widthRule: NativeBlockWidth,
        val measure: (NativeBlockMeasureRequest) -> NativeBlockMeasure,
        val gapAfter: Float = 0f,
        val floatSide: TableFloatSide? = null,
        val margins: FloatMargins = FloatMargins(0f, 0f, 0f, 0f),
        val requiresUnobstructedText: Boolean = false,
    ) : NativeFloatContextPart
}

internal data class PlacedFloatContextChild(val id: Int, val offset: Int, val bounds: RectF)

/**
 * One selection/accessibility owner across native paragraphs. A delegated table is one object in
 * the parent's logical stream and keeps its original independent cell selection/semantics tree.
 * Child positions come from whole-height float exclusion, never an implicit clear at a boundary.
 */
internal class NativeFloatContextGeometry private constructor(
    override val width: Int,
    override val text: CharSequence,
    override val height: Int,
    private val paragraphs: List<Paragraph>,
    val children: List<PlacedFloatContextChild>,
    val partOffsets: List<Int>,
) : FloatTextGeometry {
    private data class Paragraph(val offset: Int, val y: Float, val geometry: NativeFloatGeometry)
    override val nodes: List<FloatInteractionNode> = paragraphs.flatMap { paragraph ->
        paragraph.geometry.nodes.map { node -> node.copy(
            // Source offsets are stable and unique across semantic parts, unlike per-part IDs.
            id = node.id,
            start = paragraph.offset + node.start, end = paragraph.offset + node.end,
            bounds = node.bounds.map { RectF(it).apply { offset(0f, paragraph.y) } },
        ) }
    }.mapIndexed { index, node -> node.copy(id = index) }
    override fun paint(canvas: Canvas) {
        paragraphs.forEach { paragraph -> val saved = canvas.save()
            canvas.translate(0f, paragraph.y); paragraph.geometry.paint(canvas); canvas.restoreToCount(saved) }
    }
    override fun offsetForPosition(x: Float, y: Float): Int {
        paragraphs.forEach { paragraph -> paragraph.geometry.floats.lastOrNull { placed ->
            placed.content.contains(x, y - paragraph.y)
        }?.let { return paragraph.offset + it.occurrence.offset } }
        children.firstOrNull { it.bounds.contains(x, y) }?.let { return it.offset }
        val paragraph = paragraphs.minByOrNull { p -> when {
            y < p.y -> p.y - y
            y > p.y + p.geometry.textBottom -> y - p.y - p.geometry.textBottom
            else -> 0f
        } } ?: return 0
        return paragraph.offset + paragraph.geometry.offsetForPosition(x, y - paragraph.y)
    }
    private fun paragraphAt(offset: Int): Paragraph? = paragraphs.lastOrNull { offset >= it.offset }
        ?.takeIf { offset <= it.offset + it.geometry.text.length }
    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        paragraphAt(offset)?.let { return it.geometry.caretRect(offset - it.offset).apply { offset(0f, it.y) } }
        children.firstOrNull { it.offset == offset }?.let { return RectF(it.bounds.left, it.bounds.top, it.bounds.left + 1, it.bounds.bottom) }
        val next = paragraphs.firstOrNull { it.offset > offset }
        return next?.geometry?.caretRect(0)?.apply { offset(0f, next.y) } ?: RectF(0f, height.toFloat(), 1f, height.toFloat())
    }
    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        return buildList {
            paragraphs.forEach { paragraph ->
                val first = maxOf(0, start - paragraph.offset)
                val last = minOf(paragraph.geometry.text.length, end - paragraph.offset)
                if (first < last) addAll(paragraph.geometry.rectsForRange(first, last).map { RectF(it).apply { offset(0f, paragraph.y) } })
            }
            children.filter { it.offset in start until end }.forEach { add(RectF(it.bounds)) }
        }
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            val paragraph = paragraphAt(offset)?.takeIf { offset < it.offset + it.geometry.text.length }
            if (paragraph != null) paragraph.geometry.characterRects(offset - paragraph.offset, 1).single()
                ?.let { RectF(it).apply { offset(0f, paragraph.y) } }
            else children.firstOrNull { it.offset == offset }?.let { RectF(it.bounds) }
        }
    }
    override fun lineRange(offset: Int): Pair<Int, Int> {
        require(offset in 0..text.length)
        paragraphAt(offset)?.let { paragraph ->
            val local = paragraph.geometry.lineRange(offset - paragraph.offset)
            val end = paragraph.offset + local.second
            // The separator belongs to the preceding native line, exactly like Layout.getLineEnd.
            val withSeparator = if (local.second == paragraph.geometry.text.length && end < text.length && text[end] == '\n') end + 1 else end
            return (paragraph.offset + local.first) to withSeparator
        }
        children.firstOrNull { offset == it.offset || (offset == it.offset + 1 && offset < text.length && text[offset] == '\n') }?.let {
            val end = it.offset + 1
            return it.offset to if (end < text.length && text[end] == '\n') end + 1 else end
        }
        return offset to minOf(text.length, offset + 1)
    }
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        paragraphAt(offset)?.let { p ->
            val moved = p.geometry.visualOffset(offset - p.offset, direction) + p.offset
            if (moved != offset) return moved
        }
        return if ((direction < 0 && offset == 0) || (direction > 0 && offset == text.length)) offset
            else Character.offsetByCodePoints(text, offset, direction)
    }

    companion object {
        fun build(width: Int, parts: List<NativeFloatContextPart>, containAtEnd: Boolean = true): NativeFloatContextGeometry {
            require(width > 0)
            val text = StringBuilder()
            val paragraphs = mutableListOf<Paragraph>()
            val children = mutableListOf<PlacedFloatContextChild>()
            val exclusions = mutableListOf<NativeFloatExclusion>()
            val partOffsets = mutableListOf<Int>()
            var y = 0f
            parts.forEachIndexed { index, part ->
                if (index > 0) text.append('\n') // A semantic block boundary, never a visual wrap.
                partOffsets += text.length
                when (part) {
                    is NativeFloatContextPart.Text -> {
                        require(part.gapAfter.isFinite() && part.gapAfter >= 0)
                        val carried = exclusions.filter { it.outer.bottom > y }.map { it.copy(outer = it.outer.translated(0f, -y)) }
                        val geometry = part.build(width, carried)
                        check(geometry.text.toString() == part.text.toString()) { "Native paragraph changed its logical source" }
                        paragraphs += Paragraph(text.length, y, geometry)
                        text.append(part.text)
                        geometry.floats.forEach { placed -> exclusions += NativeFloatExclusion(placed.occurrence.side,
                            NativeFloatBounds(placed.outer.left, placed.outer.top + y, placed.outer.right, placed.outer.bottom + y)) }
                        y += geometry.textBottom + part.gapAfter
                    }
                    is NativeFloatContextPart.Child -> {
                        require(part.gapAfter.isFinite() && part.gapAfter >= 0)
                        if (part.requiresUnobstructedText && exclusions.any { it.outer.bottom > y })
                            throw UnsupportedFloatLayout("This text block needs native exclusion-band shaping")
                        val side = part.floatSide
                        if (side == null) {
                            val placed = placeNativeFloatBlock(width.toFloat(), y, exclusions, part.widthRule,
                                pixelAligned = true, measure = part.measure)
                            children += PlacedFloatContextChild(part.id, text.length,
                                RectF(placed.bounds.left, placed.bounds.top, placed.bounds.right, placed.bounds.bottom))
                            y = placed.nextY + part.gapAfter
                        } else {
                            val placed = placeNativeFloatingTable(width.toFloat(), y, exclusions, side,
                                part.margins, part.widthRule, part.measure)
                            children += PlacedFloatContextChild(part.id, text.length,
                                RectF(placed.content.left, placed.content.top, placed.content.right, placed.content.bottom))
                            exclusions += NativeFloatExclusion(side, placed.outer)
                            // A floated table leaves the following body at its normal flow Y.
                            // Its stored margins, rather than a fabricated empty paragraph, exclude later lines.
                        }
                        text.append('\ufffc')
                    }
                }
            }
            val floatBottom = exclusions.maxOfOrNull { it.outer.bottom } ?: 0f
            if (!containAtEnd && floatBottom > y + .01f) throw UnsupportedFloatLayout("Float crosses a delegated section boundary")
            val bottom = maxOf(y, floatBottom)
            if (!bottom.isFinite() || bottom > Int.MAX_VALUE / 4) throw UnsupportedFloatLayout("Native context height exceeds geometry limit")
            return NativeFloatContextGeometry(width, text.toString(), kotlin.math.ceil(bottom).toInt(), paragraphs, children, partOffsets)
        }
    }
}
