package app.smallthingz.dict

import kotlin.math.floor

/** One real anonymous media cell; the caption is external to its collapsed grid. */
internal class FigureTableCaptionMetrics(
    val layout: TableCaptionLayout,
    val natural: FigureBoxMetrics,
    private val density: Float,
    private val normalBodyPixels: Float,
    val rtl: Boolean,
    private val mediaFont: FigureMediaFont,
    private val contentBaseline: Float? = null,
    private val contentHeightAtWidth: ((Float) -> Float)? = null,
) {
    private val emptyBorder = TableStyleBorder(0f, null, TableStroke.None)
    private val emptyEdges = TableCellBorders(emptyBorder, emptyBorder, emptyBorder, emptyBorder)
    val grid = TableGrid(listOf(PlacedCell(Cell(emptyList(), false, 1, 1), 0, 0, 1)), 1, 1)
    private fun length(value: StyleLength) = figureLengthPixels(value, density, normalBodyPixels)
    private fun color(value: FigureColor): String? = when (value) {
        FigureColor.NativeTheme -> null
        FigureColor.Transparent -> ""
        is FigureColor.Rgb -> value.value
    }
    private fun edge(value: FigureBorderEdge): TableStyleBorder = when (value) {
        FigureBorderEdge.None -> emptyBorder
        FigureBorderEdge.Hidden -> TableStyleBorder(0f, null, TableStroke.Hidden)
        is FigureBorderEdge.Solid -> TableStyleBorder(length(value.width), color(value.color), TableStroke.Solid)
        is FigureBorderEdge.Dotted -> TableStyleBorder(length(value.width), color(value.color), TableStroke.Dotted)
    }
    private fun edges(value: FigureBorderEdges) = TableCellBorders(edge(value.top), edge(value.right),
        edge(value.bottom), edge(value.left))
    val tableEdges = edges(layout.tableBorder)
    val captionEdges = edges(layout.captionBorder)
    val mediaInsets = collapsedTableCellInsets(grid, listOf(emptyEdges), tableEdges,
        listOf(TablePixelInsets(0, 0, 0, 0)), rtl).single()
    val tableStyle = TableResolvedStyle(null, tableEdges.top, true, TablePixelInsets(0, 0, 0, 0),
        listOf(emptyBorder), listOf(mediaInsets), cellEdges = listOf(emptyEdges), rtl = rtl, outerEdges = tableEdges)
    private val capSubtract = layout.media.maxWidth?.let { length(it.subtract) }
    private val imageOwnWidth = natural.imageInsets.left + natural.imageInsets.right + natural.imageBorder * 2f
    private val captionOwnWidth = natural.captionPadding.left + natural.captionPadding.right +
        captionEdges.left.width + captionEdges.right.width

    /** Cyclic percentage cap contributes zero media content to MIN, preferred media to MAX. */
    fun intrinsic(captionMinimum: Int): NativeWidthRange {
        require(captionMinimum >= 0)
        val captionFloor = figureCoordinate(captionMinimum + captionOwnWidth)
        val frameFloor = figureCoordinate((natural.frameMinWidth ?: 0f) + mediaInsets.horizontal)
        val minimum = maxOf(captionFloor, frameFloor, figureCoordinate(imageOwnWidth + mediaInsets.horizontal +
            if (layout.media.maxWidth == null) natural.image.width else 0f))
        val maximum = maxOf(minimum, figureCoordinate(natural.image.width + imageOwnWidth + mediaInsets.horizontal))
        if (minimum > TablePixelLimit) throw UnsupportedFloatLayout("Figure table minimum exceeds native measurement range")
        return NativeWidthRange(minimum, maximum)
    }

    fun resolve(availableWidth: Int, captionMinimum: Int, exactWidth: Int? = null): FigureBoxMetrics {
        val intrinsic = intrinsic(captionMinimum)
        val track = inlineTableColumnWidths(grid, intArrayOf(intrinsic.minimum), intArrayOf(intrinsic.maximum),
            0, 0, availableWidth, authoredWidth = exactWidth)?.single()
            ?: throw UnsupportedFloatLayout("Figure anonymous media grid cannot be allocated")
        val cellContentWidth = (track - mediaInsets.horizontal).coerceAtLeast(0).toFloat()
        // The already chosen media policy supplies the preferred ratio. Both encoded axes survive.
        val imageWidth = layout.media.maxWidth?.let { cap ->
            minOf(natural.image.width, (cellContentWidth * cap.percent / 100f - checkNotNull(capSubtract)).coerceAtLeast(0f))
        } ?: natural.image.width
        val imageHeight = contentHeightAtWidth?.invoke(imageWidth) ?: if (natural.image.width == 0f) natural.image.height
            else natural.image.height * (imageWidth / natural.image.width)
        if (!imageHeight.isFinite() || imageHeight < 0f)
            throw UnsupportedFloatLayout("Figure content height is unavailable")
        val image = natural.image.copy(width = imageWidth, height = imageHeight)
        val outerHeight = natural.imageInsets.top + natural.imageInsets.bottom + natural.imageBorder * 2f + imageHeight
        val line = figureMediaLine(mediaFont, layout.media.verticalAlign, outerHeight,
            contentBaseline?.let { it + natural.imageInsets.top + natural.imageBorder })
        val rowHeight = figureCoordinate(mediaInsets.vertical + line.height)
        val pixels = TablePixelLayout(track, intArrayOf(0, rowHeight), track, columnWidths = listOf(track))
        val captionWidth = floor(track - captionOwnWidth).toInt()
        if (captionWidth < captionMinimum) throw UnsupportedFloatLayout("Figure caption minimum exceeds its allocated content box")
        val left = mediaInsets.left + (cellContentWidth - imageOwnWidth - imageWidth) / 2f +
            natural.imageInsets.left + natural.imageBorder
        val top = mediaInsets.top + line.contentTop + natural.imageInsets.top + natural.imageBorder
        val anchor = NativeFloatBounds(mediaInsets.left.toFloat(), mediaInsets.top.toFloat(),
            mediaInsets.left + cellContentWidth, mediaInsets.top + line.height)
        val after = layout.media.after?.let { value ->
            val width = length(value.width); val height = length(value.height); val inset = length(value.inset)
            val left = if (value.side == TableFloatSide.Left) anchor.left + inset else anchor.right - inset - width
            val bottom = when (value.bottom.unit) {
                StyleLengthUnit.Px -> value.bottom.value * density
                StyleLengthUnit.Em -> value.bottom.value * normalBodyPixels
            }
            val top = anchor.bottom - bottom - height
            NativeFloatBounds(left, top, left + width, top + height)
        }
        val box = FigureTableCaptionAllocation(this, pixels, captionWidth, left, top,
            captionEdges.left.width + natural.captionPadding.left,
            rowHeight + captionEdges.top.width, anchor, after)
        return natural.copy(image = image, tableCaption = box)
    }
}

internal data class FigureTableCaptionAllocation(
    val prepared: FigureTableCaptionMetrics,
    val pixels: TablePixelLayout,
    val captionWidth: Int,
    val imageLeft: Float,
    val imageTop: Float,
    val captionLeft: Float,
    val captionTop: Float,
    val anchor: NativeFloatBounds,
    val after: NativeFloatBounds?,
) {
    fun height(captionHeight: Int): Int = figureCoordinate(captionTop +
        prepared.natural.captionPadding.top + captionHeight + prepared.natural.captionPadding.bottom +
        prepared.captionEdges.bottom.width)
    fun borders(captionHeight: Int): List<TableBorderSegment> =
        collapsedTableBorders(prepared.grid, pixels, prepared.tableStyle) +
            separateCellBorderSegments(0f, pixels.height.toFloat(), pixels.width.toFloat(), height(captionHeight).toFloat(),
                prepared.captionEdges)
}
