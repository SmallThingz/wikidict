package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import kotlin.math.ceil
import kotlin.math.floor

internal val LocalNativeContainerTextWrap = staticCompositionLocalOf<TextWrap?> { null }

/** Paint belongs to the solved border box, not to its margin allocation or descendant ink. */
internal data class NativeContainerPaintEdge(val width: Float, val color: Int?, val dotted: Boolean = false)
internal data class NativeContainerDecoration(val background: Int?, val borderColor: Int?, val borderWidth: Float,
    val edges: List<NativeContainerPaintEdge>? = null,
    val nativeCorners: NativeCornerRadii? = null) {
    init { require(edges == null || edges.size == 4) }
    private val roundedBorder = if (nativeCorners == null) null else {
        val sides = edges ?: List(4) { NativeContainerPaintEdge(borderWidth, borderColor) }
        val first = sides.first()
        if (sides.any { !it.width.isFinite() || it.width < 0f || it.dotted ||
                it.width != first.width || it.color != first.color })
            throw UnsupportedFloatLayout("Rounded table borders require one uniform solid edge")
        first
    }
    private class RoundedPaint(val box: RectF, val outer: Path, val ring: Path?)
    private var roundedPaint: RoundedPaint? = null

    fun paint(canvas: Canvas, box: RectF, paintBackground: Boolean = true, paintBorder: Boolean = true) {
        if (nativeCorners != null) {
            paintRounded(canvas, box, paintBackground, paintBorder)
            return
        }
        if (box.isEmpty) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        background?.let { paint.color = it; canvas.drawRect(box, paint) }
        val sides = edges ?: List(4) { NativeContainerPaintEdge(borderWidth, borderColor) }
        val top = minOf(sides[0].width, box.height())
        val right = minOf(sides[1].width, box.width())
        val bottom = minOf(sides[2].width, box.height())
        val left = minOf(sides[3].width, box.width())
        val bands = listOf(RectF(box.left, box.top, box.right, box.top + top),
            RectF(box.right - right, box.top, box.right, box.bottom),
            RectF(box.left, box.bottom - bottom, box.right, box.bottom),
            RectF(box.left, box.top, box.left + left, box.bottom))
        sides.forEachIndexed { index, side ->
            val band = bands[index]
            if (side.color != null && side.width > 0f && !band.isEmpty) {
                paint.color = side.color
                if (!side.dotted) canvas.drawRect(band, paint) else {
                    val horizontal = index % 2 == 0
                    val checkpoint = canvas.save()
                    canvas.clipRect(band)
                    paintNativeTableBorder(canvas, if (horizontal)
                        TableBorderSegment(band.left, band.centerY(), band.right, band.centerY(), side.width, null, TableStroke.Dotted)
                    else TableBorderSegment(band.centerX(), band.top, band.centerX(), band.bottom, side.width, null, TableStroke.Dotted), side.color)
                    canvas.restoreToCount(checkpoint)
                }
            }
        }
    }

    /** Called by the existing owner before successful geometry publication. No draw-time solving. */
    fun prepareCorners(box: RectF) {
        val corners = nativeCorners ?: return
        if (roundedPaint?.box == box) return
        roundedPaint = null
        val border = checkNotNull(roundedBorder)
        if (listOf(box.left, box.top, box.right, box.bottom).any { !it.isFinite() } ||
            box.right < box.left || box.bottom < box.top)
            throw UnsupportedFloatLayout("Table corner owner bounds are unavailable")
        val shape = NativeTableCornerShape(NativeFloatBounds(box.left, box.top, box.right, box.bottom),
            corners, border.width)
        val outer = nativeTableCornerPath(shape)
        val ring = if (border.width <= 0f || border.color == null) null else Path(outer).apply {
            val inner = nativeTableCornerPath(shape, padding = true)
            if (!inner.isEmpty && !op(inner, Path.Op.DIFFERENCE))
                throw UnsupportedFloatLayout("Table corner border path is unavailable")
        }
        roundedPaint = RoundedPaint(RectF(box), outer, ring)
    }

    private fun paintRounded(canvas: Canvas, box: RectF, paintBackground: Boolean, paintBorder: Boolean) {
        val prepared = checkNotNull(roundedPaint?.takeIf { it.box == box }) {
            "Rounded table paint requires its measured corner preparation"
        }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        if (paintBackground) background?.let { paint.color = it; canvas.drawPath(prepared.outer, paint) }
        if (paintBorder) prepared.ring?.let {
            paint.color = checkNotNull(roundedBorder?.color); canvas.drawPath(it, paint)
        }
    }
}

/** Exact circular regions, including inner arcs that extend into an opposite border.
 * addRoundRect is deliberately absent: its implicit inner normalization changes this shape. */
internal fun nativeTableCornerPath(shape: NativeTableCornerShape, padding: Boolean = false): Path {
    val bounds = (if (padding) shape.paddingBox else shape.borderBox) ?: return Path()
    if (bounds.width <= 0f || bounds.height <= 0f) return Path()
    val path = Path().apply { addRect(bounds.left, bounds.top, bounds.right, bounds.bottom, Path.Direction.CW) }
    val radii = (if (padding) shape.innerRadii else shape.outerRadii).clockwise
    radii.forEachIndexed { index, radius ->
        if (radius > 0.0) {
            val center = shape.center(index)
            val cx = center.first.toFloat()
            val cy = center.second.toFloat()
            val usedRadius = radius.toFloat()
            if (listOf(cx, cy, usedRadius, cx - usedRadius, cx + usedRadius,
                    cy - usedRadius, cy + usedRadius).any { !it.isFinite() })
                throw UnsupportedFloatLayout("Table corner path exceeds native geometry")
            val region = Path().apply {
                addCircle(cx, cy, usedRadius, Path.Direction.CW)
                fun rectangle(left: Float, top: Float, right: Float, bottom: Float) {
                    if (right > left && bottom > top) addRect(left, top, right, bottom, Path.Direction.CW)
                }
                if (index == 0 || index == 3)
                    rectangle(maxOf(cx, bounds.left), bounds.top, bounds.right, bounds.bottom)
                else rectangle(bounds.left, bounds.top, minOf(cx, bounds.right), bounds.bottom)
                if (index < 2)
                    rectangle(bounds.left, maxOf(cy, bounds.top), bounds.right, bounds.bottom)
                else rectangle(bounds.left, bounds.top, bounds.right, minOf(cy, bounds.bottom))
            }
            if (!path.op(region, Path.Op.INTERSECT))
                throw UnsupportedFloatLayout("Table corner path is unavailable")
        }
    }
    return path
}

/** Conservative native-path envelope after the true intersection, without integer Region/raster approximation. */
internal fun nativeTableCornerIntersection(shape: NativeTableCornerShape, rectangle: RectF,
    padding: Boolean = false): RectF? {
    if (rectangle.isEmpty) return null
    val clipped = nativeTableCornerPath(shape, padding)
    val rect = Path().apply { addRect(rectangle, Path.Direction.CW) }
    if (!clipped.op(rect, Path.Op.INTERSECT))
        throw UnsupportedFloatLayout("Table corner intersection is unavailable")
    if (clipped.isEmpty) return null
    val owner = (if (padding) shape.paddingBox else shape.borderBox) ?: return null
    val bounds = RectF().also { clipped.computeBounds(it, true) }
    // Path control points may extend beyond its true intersection. The original
    // rectangular constraints remain exact even when the native envelope is conservative.
    return bounds.takeIf { it.intersect(rectangle) &&
        it.intersect(owner.left, owner.top, owner.right, owner.bottom) && !it.isEmpty }
}

/** A stamped circle path keeps dotted borders circular even at fractional density,
 * without allocating one Kotlin object for each subpixel dot. */
internal fun paintNativeTableBorder(canvas: Canvas, edge: TableBorderSegment, color: Int) {
    if (edge.width <= 0f || edge.stroke == TableStroke.None || edge.stroke == TableStroke.Hidden) return
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        style = Paint.Style.STROKE
        strokeWidth = edge.width
    }
    require(edge.stroke != TableStroke.Inset && edge.stroke != TableStroke.Outset) {
        "Shaded table borders require their physical-side paint plan"
    }
    if (edge.stroke != TableStroke.Dotted) {
        canvas.drawLine(edge.x1, edge.y1, edge.x2, edge.y2, paint)
        return
    }
    val horizontal = edge.y1 == edge.y2
    val start = minOf(if (horizontal) edge.x1 else edge.y1, if (horizontal) edge.x2 else edge.y2)
    val end = maxOf(if (horizontal) edge.x1 else edge.y1, if (horizontal) edge.x2 else edge.y2)
    val fixed = if (horizontal) edge.y1 else edge.x1
    val radius = edge.width / 2f
    val checkpoint = canvas.save()
    if (horizontal) canvas.clipRect(start, fixed - radius, end, fixed + radius)
    else canvas.clipRect(fixed - radius, start, fixed + radius, end)
    if (end - start <= edge.width) {
        paint.style = Paint.Style.FILL
        canvas.drawCircle(if (horizontal) (start + end) / 2f else fixed,
            if (horizontal) fixed else (start + end) / 2f, radius, paint)
    } else {
        val dot = android.graphics.Path().apply { addCircle(0f, 0f, radius, android.graphics.Path.Direction.CW) }
        paint.pathEffect = android.graphics.PathDashPathEffect(dot, edge.width * 2f, 0f,
            android.graphics.PathDashPathEffect.Style.TRANSLATE)
        val line = android.graphics.Path().apply {
            if (horizontal) { moveTo(start + radius, fixed); lineTo(end - radius, fixed) }
            else { moveTo(fixed, start + radius); lineTo(fixed, end - radius) }
        }
        canvas.drawPath(line, paint)
    }
    canvas.restoreToCount(checkpoint)
}

/** Intrinsics are independent of eventual column count and containing width. Native list
 * gutters and paragraph edges each enter once; an empty clear event owns no glyph or width. */
internal fun nativeColumnContentWidths(parts: List<NativeFloatContextSpec>,
    breakWordMinimum: Boolean = false): ContainerWidths {
    var minimum = 0f
    var maximum = 0f
    parts.forEach { part ->
        when (part) {
            is NativeFloatContextSpec.Text -> {
                val native = part.prepared.native
                    ?: throw UnsupportedFloatLayout(part.prepared.stateDescription ?: "Column text preparation is unavailable")
                val widths = nativeFloatRowIntrinsicWidths(native.source(TablePixelLimit), native.paint,
                    native.direction, breakWordMinimum || native.breakWordMinimum)
                val inset = native.horizontalInsets + (part.box?.contentLeft ?: 0f) + (part.box?.contentRight ?: 0f)
                minimum = maxOf(minimum, widths.minimum + inset)
                maximum = maxOf(maximum, widths.maximum + inset)
            }
            is NativeFloatContextSpec.Container -> if (!part.columnClearEvent)
                throw UnsupportedFloatLayout("Column fragmentation for this child layout is unavailable")
            else -> throw UnsupportedFloatLayout("Column fragmentation for this child layout is unavailable")
        }
    }
    if (!minimum.isFinite() || !maximum.isFinite() || maximum > TablePixelLimit)
        throw UnsupportedFloatLayout("Column content intrinsic width exceeds native geometry")
    return ContainerWidths(minimum, maximum)
}

/** This is the adapter for the existing prepared owner, not another measurement subtree. */
internal fun nativeContainerSpec(id: Int, resolved: ContainerViewportStyle,
    children: List<NativeFloatContextSpec>, density: Float, normalBodyFont: Float,
    rtl: Boolean, dark: Boolean, flexItem: Boolean,
    positioned: NativePositionedScrollportPolicy? = null, absolute: NativeAbsoluteTextPlacement? = null,
    absolutePosition: NativeAbsolutePosition? = null,
    absoluteContainingBlock: NativeAbsoluteContainingBlock? = null,
    absoluteStatic: NativeAbsoluteStaticPosition? = null,
    columnBreakWordMinimum: Boolean = false,
    ordinaryHidden: NativeOrdinaryHiddenScrollportPolicy? = null): NativeFloatContextSpec.Container = try {
    supportedNativeContainerSpec(id, resolved, children, density, normalBodyFont, rtl, dark, flexItem, positioned, absolute,
        absolutePosition, absoluteContainingBlock, absoluteStatic, columnBreakWordMinimum, ordinaryHidden)
} catch (error: UnsupportedFloatLayout) {
    // Keep the real leaves available to the existing visible fallback. Geometry
    // limits must not discard the body by throwing out of composition.
    val retained = if (resolved.box.positionedScope == null) children else children.map { child ->
        // A refused scope has no admitted positioning envelope. Keep its direct real
        // text owners in ordinary fallback flow, without a zero-height/offset claim.
        if (child is NativeFloatContextSpec.Container && child.absolute != null)
            child.copy(absolute = null, relativeAuto = false, fixedContentHeight = null)
        else child
    }
    NativeFloatContextSpec.Container(id, contentWidth = { width, _ -> width }, intrinsicWidth = { width, _ -> width },
        preparedParts = retained, unavailableReason = error.message ?: "Container geometry is unavailable", content = {})
}

private fun supportedNativeContainerSpec(id: Int, resolved: ContainerViewportStyle,
    children: List<NativeFloatContextSpec>, density: Float, normalBodyFont: Float,
    rtl: Boolean, dark: Boolean, flexItem: Boolean,
    positioned: NativePositionedScrollportPolicy?, absolute: NativeAbsoluteTextPlacement?,
    absolutePosition: NativeAbsolutePosition?, absoluteContainingBlock: NativeAbsoluteContainingBlock?,
    absoluteStatic: NativeAbsoluteStaticPosition?, columnBreakWordMinimum: Boolean,
    ordinaryHidden: NativeOrdinaryHiddenScrollportPolicy?): NativeFloatContextSpec.Container {
    val style = resolved.box
    if (style.layout == ContainerLayout.FlexColumn) {
        if (style.height != null || style.minHeight != null || style.columns != null ||
            style.overflow != null && style.overflow != ContainerOverflow.Visible)
            throw UnsupportedFloatLayout("Flex columns require an auto-height visible owner")
        fun supported(part: NativeFloatContextSpec): Boolean = when (part) {
            is NativeFloatContextSpec.Text, is NativeFloatContextSpec.Rule -> true
            is NativeFloatContextSpec.Container -> !part.relativeAuto && part.absolute == null &&
                part.absolutePosition == null && part.absoluteStatic == null && part.absoluteContainingBlock == null &&
                part.scrollport == null && part.columns == null && part.preparedParts?.all(::supported) == true
            else -> false
        }
        if (children.any { it !is NativeFloatContextSpec.Container || !supported(it) })
            throw UnsupportedFloatLayout("Flex column items require original ordinary Container owners")
    }
    if ((style.overflow == ContainerOverflow.Hidden) != (ordinaryHidden != null))
        throw UnsupportedFloatLayout("Hidden overflow requires its original ordinary Container owner")
    if ((style.positionedScope != null) != (positioned != null) ||
        (style.positioning is ContainerPositioning.Absolute) != (absolute != null))
        throw UnsupportedFloatLayout("Positioned content requires its own direct source scope")
    if ((style.absolutePosition != null) != (absolutePosition != null))
        throw UnsupportedFloatLayout("Absolute positioned content requires its nearest relative Container")
    if ((style.absoluteStatic != null) != (absoluteStatic != null))
        throw UnsupportedFloatLayout("Static inline content requires its sole immediate relative Container")
    if (absoluteContainingBlock != null && (style.positioning != ContainerPositioning.RelativeAuto || positioned != null))
        throw UnsupportedFloatLayout("Absolute containing block requires an ordinary relative Container")
    if (positioned == null) nativeScrollportUnavailable(style, flexItem)?.let { throw UnsupportedFloatLayout(it) }
    if (positioned != null && (flexItem || style.height != null || style.minHeight != null))
        throw UnsupportedFloatLayout("This positioned scrollport needs an ordinary auto-height owner")
    val scrolling = style.overflow == ContainerOverflow.Auto || ordinaryHidden != null || positioned != null
    fun length(value: StyleLength): Float {
        val result = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density else normalBodyFont
        if (!result.isFinite() || result !in 0.0..TablePixelLimit.toDouble())
            throw UnsupportedFloatLayout("Container edge exceeds native geometry")
        return result.toFloat()
    }
    fun margin(value: ContainerMargin?): Float = (value as? ContainerMargin.Length)?.let {
        val result = it.value.value.toDouble() * if (it.value.unit == StyleLengthUnit.Px) density else normalBodyFont
        if (!result.isFinite() || kotlin.math.abs(result) > TablePixelLimit)
            throw UnsupportedFloatLayout("Container margin exceeds native geometry")
        result.toFloat()
    } ?: 0f
    val margins: NativeContainerMargins = resolved.margins?.let {
        SignedNativeContainerMargins(margin(it.top), margin(it.right), margin(it.bottom), margin(it.left))
    } ?: FloatMargins(0f, 0f, 0f, 0f)
    if ((flexItem || resolved.ownsFormattingContext) && positioned == null &&
        listOf(margins.top, margins.right, margins.bottom, margins.left).any { it < 0f })
        throw UnsupportedFloatLayout("Signed external float, BFC or flex margins are not supported")
    if (positioned != null && (margins.left < 0f || margins.right < 0f))
        throw UnsupportedFloatLayout("Signed horizontal positioned-scope margins are unavailable")
    if (style.minHeight != null && (flexItem || (style.layout == ContainerLayout.FlexRow || style.layout == ContainerLayout.FlexColumn) || style.columns != null))
        throw UnsupportedFloatLayout("Minimum height in flex or multicolumn layout is not supported")
    val borderSides = style.border.physicalEdges()
    val edgeWidths = listOf(borderSides.top, borderSides.right, borderSides.bottom, borderSides.left)
        .map { it.usedWidth?.let(::length) ?: 0f }
    val authoredPadding = style.padding
    val padding = FloatMargins((authoredPadding?.top?.let(::length) ?: 0f) + edgeWidths[0],
        (authoredPadding?.right?.let(::length) ?: 0f) + edgeWidths[1],
        (authoredPadding?.bottom?.let(::length) ?: 0f) + edgeWidths[2],
        (authoredPadding?.left?.let(::length) ?: 0f) + edgeWidths[3])
    val scrollPadding = FloatMargins(padding.top - edgeWidths[0], padding.right - edgeWidths[1],
        padding.bottom - edgeWidths[2], padding.left - edgeWidths[3])
    val scrollHorizontalPadding = scrollPadding.left + scrollPadding.right
    val outerPadding = if (scrolling) FloatMargins(edgeWidths[0], edgeWidths[1], edgeWidths[2], edgeWidths[3]) else padding
    fun color(value: ContainerColor?): Int? = when (value) {
        null, ContainerColor.Transparent -> null
        is ContainerColor.Rgb -> android.graphics.Color.parseColor(value.value)
        is ContainerColor.LightDark -> android.graphics.Color.parseColor(if (dark) value.dark else value.light)
    }
    val decoration = NativeContainerDecoration(color(style.background), null, 0f,
        listOf(borderSides.top, borderSides.right, borderSides.bottom, borderSides.left).mapIndexed { index, edge ->
            val ink = when (edge) {
                ContainerBorderEdge.None, ContainerBorderEdge.Hidden -> null
                is ContainerBorderEdge.Solid -> color(edge.color)
                is ContainerBorderEdge.Dotted -> color(edge.color)
            }
            NativeContainerPaintEdge(edgeWidths[index], ink, edge is ContainerBorderEdge.Dotted)
        }).takeIf { it.background != null || it.edges!!.any { edge -> edge.color != null && edge.width > 0f } }
    val relativeAuto = style.positioning == ContainerPositioning.RelativeAuto
    if (relativeAuto && positioned == null && (flexItem || (style.layout == ContainerLayout.FlexRow || style.layout == ContainerLayout.FlexColumn) || style.floatSide != null ||
            style.columns != null || ordinaryHidden == null && absoluteContainingBlock == null && children.any { it !is NativeFloatContextSpec.Text }))
        throw UnsupportedFloatLayout("Positioned groups require one ordinary plaintext owner")
    if (positioned != null && children.any { it !is NativeFloatContextSpec.Text &&
            (it !is NativeFloatContextSpec.Container || it.absolute == null) })
        throw UnsupportedFloatLayout("This positioned scope needs direct text, image and absolute text owners")
    if (absolute != null && children.any { it !is NativeFloatContextSpec.Text })
        throw UnsupportedFloatLayout("Absolute text requires ordinary paragraph owners")
    if (absolutePosition != null && children.any { it !is NativeFloatContextSpec.Text })
        throw UnsupportedFloatLayout("Absolute positioned content requires ordinary paragraph owners")
    if (absoluteStatic != null && (children.size != 1 || children.single() !is NativeFloatContextSpec.Text))
        throw UnsupportedFloatLayout("Static inline content requires its one original ordinary paragraph")
    val columns = style.columns?.let {
        NativeColumnPolicy(it.count, length(it.gap), rtl, it.width?.let(::length), density)
    }
    if (columns != null && (style.height != null || (style.layout == ContainerLayout.FlexRow || style.layout == ContainerLayout.FlexColumn) ||
            style.overflow == ContainerOverflow.Auto))
        throw UnsupportedFloatLayout("Columns require an auto-height ordinary formatting context")
    if (columns != null && children.any { it !is NativeFloatContextSpec.Text &&
            (it !is NativeFloatContextSpec.Container || !it.columnClearEvent) })
        throw UnsupportedFloatLayout("Column fragmentation for this child layout is unavailable")
    val columnWidths = columns?.let { lazy { nativeColumnContentWidths(children, columnBreakWordMinimum) } }
    fun columnIntrinsic(intrinsic: ContainerWidths) = columns?.intrinsic(columnWidths!!.value) ?: intrinsic
    fun childIntrinsic(intrinsic: ContainerWidths) = if (!scrolling) intrinsic else ContainerWidths(
        (intrinsic.minimum - scrollHorizontalPadding).coerceAtLeast(0f),
        (intrinsic.maximum - scrollHorizontalPadding).coerceAtLeast(0f))
    fun solved(width: Float, intrinsic: ContainerWidths) =
        containerBoxWidth(resolved, width, columnIntrinsic(childIntrinsic(intrinsic)), density, normalBodyFont, flexItem, rtl)
    fun pixels(value: Float): Int {
        if (!value.isFinite() || value !in 0f..TablePixelLimit.toFloat())
            throw UnsupportedFloatLayout("Container width exceeds native geometry")
        return floor(value).toInt()
    }
    val flex = if (!flexItem) null else NativeFlexItemSpec(
        measure = { width, intrinsic -> containerFlexMeasure(resolved, width, columnIntrinsic(intrinsic), density, normalBodyFont) },
        intrinsic = { intrinsic, maximum -> containerFlexIntrinsicContribution(resolved, columnIntrinsic(intrinsic), density, normalBodyFont, maximum) },
        crossMargins = NativeFlexCrossMargins(resolved.margins?.top == ContainerMargin.Auto,
            resolved.margins?.bottom == ContainerMargin.Auto),
        columnMeasure = { width, intrinsic, policy ->
            containerFlexColumnMeasure(resolved, width, intrinsic, density, normalBodyFont, policy)
        })
    // Border/decoration stay on this ordinary owner. Its one real viewport child owns the
    // padding box and the complete original subtree, so padding and border are counted once.
    val renderedChildren = if (!scrolling || positioned != null) children else {
        require(id >= 0) { "Authored Container source IDs must be nonnegative" }
        listOf(NativeFloatContextSpec.Child(-id - 1, { it }, 0f,
            requiresUnobstructedText = true, scrollport = NativeScrollportSpec(children, scrollPadding, ordinaryHidden = ordinaryHidden)))
    }
    return NativeFloatContextSpec.Container(id,
        contentWidth = { width, intrinsic -> pixels(solved(width.toFloat(), intrinsic).content +
            if (scrolling) scrollHorizontalPadding else 0f) },
        intrinsicWidth = { content, maximum ->
            // Percentages are indefinite during an intrinsic query, exactly as in row contributions.
            val value = containerFlexIntrinsicContribution(resolved, columnIntrinsic(childIntrinsic(ContainerWidths(content.toFloat(), content.toFloat()))),
                density, normalBodyFont, maximum)
            if (value > TablePixelLimit) androidx.compose.ui.unit.Constraints.Infinity else ceil(value).toInt()
        }, margins = { margins }, padding = { outerPadding },
        floatSide = if (flexItem) null else style.floatSide, clear = if (flexItem) null else style.clear,
        empty = children.isEmpty(), isolatesFloats = resolved.ownsFormattingContext || flexItem || positioned != null,
        preparedParts = renderedChildren.takeIf { positioned == null },
        innerMargins = if (positioned != null) NativeAdjoiningMargins(0f, 0f, false) else null,
        horizontal = { width, intrinsic ->
            val value = solved(width.toFloat(), intrinsic)
            val horizontal = NativeContainerHorizontal.from(value, padding.left, margins.left, margins.right)
            if (!scrolling) horizontal else horizontal.copy(content = value.content + scrollHorizontalPadding,
                contentLeft = value.marginLeft + edgeWidths[3])
        },
        row = if (style.layout == ContainerLayout.FlexRow) NativeFlexRowPolicy(style.alignItems ?: ContainerAlignItems.Stretch, rtl) else null,
        column = if (style.layout == ContainerLayout.FlexColumn)
            NativeFlexColumnPolicy(style.alignItems ?: ContainerAlignItems.Stretch, rtl) else null,
        flex = flex, decoration = decoration, columns = columns, relativeAuto = relativeAuto,
        fixedContentHeight = containerUsedHeight(style, padding.top + padding.bottom,
            density, normalBodyFont)?.content,
        minimum = containerMinimumHeight(style, padding.top + padding.bottom, density, normalBodyFont),
        absolute = absolute, absolutePosition = absolutePosition, absoluteContainingBlock = absoluteContainingBlock,
        absoluteStatic = absoluteStatic,
        columnClearEvent = children.isEmpty() && style.clear != null && style.copy(clear = null) == ContainerStyle(),
        columnContentWidths = columnWidths?.let { measured -> { measured.value } },
        scrollport = positioned?.let { NativeScrollportSpec(children, scrollPadding, it) },
        content = {})
}

internal data class NativeContainerLeaf(val block: Block, val previous: Block?, val id: Int,
    val path: String, val gridPath: String, val gap: Float, val rootIndex: Int?,
    val format: NativeContainerTextFormat?, val context: ContainerTextContext?,
    val align: CellTextAlign?, val inContainer: Boolean, val inScrollport: Boolean = false,
    val ownerWrap: TextWrap? = null, val bodyTypographyExcluded: Boolean = false,
    val staticInlineParent: NativeStaticInlineParent? = null,
    val clippedAbsoluteScope: NativeClippedAbsoluteCoordinateScope? = null,
    val cellForeground: NativeCellForegroundContext? = null,
    val semanticBorderInk: NativeSemanticBorderInk? = null)

private data class NativePositionedParent(val paddingTop: Float)

private data class NativeStaticInlineScope(val containingBlockId: Int, val child: Container,
    val parent: NativeStaticInlineParent)

/** The hypothetical line belongs to the containing paragraph, never to the child's
 * first strong character or independently declared font. */
internal fun nativeStaticInlineParent(format: NativeContainerTextFormat,
    position: ContainerAbsoluteStaticPosition, tableDirection: TableContainingDirection?,
    bodyDirection: BidiResolvedDirection?, align: androidx.compose.ui.text.style.TextAlign?): NativeStaticInlineParent {
    val direction = when (position.direction) {
        ContainerStaticDirection.Ltr -> BidiResolvedDirection.Ltr
        ContainerStaticDirection.Rtl -> BidiResolvedDirection.Rtl
        ContainerStaticDirection.Inherit -> when (compiledBodyParagraphDirection(tableDirection, bodyDirection)
                ?: format.style.textDirection) {
            androidx.compose.ui.text.style.TextDirection.Ltr -> BidiResolvedDirection.Ltr
            androidx.compose.ui.text.style.TextDirection.Rtl -> BidiResolvedDirection.Rtl
            else -> throw UnsupportedFloatLayout("Static inline parent paragraph direction is unresolved")
        }
    }
    val rtl = direction == BidiResolvedDirection.Rtl
    val alignment = when (align ?: format.style.textAlign) {
        androidx.compose.ui.text.style.TextAlign.Center -> android.text.Layout.Alignment.ALIGN_CENTER
        androidx.compose.ui.text.style.TextAlign.Left -> if (rtl) android.text.Layout.Alignment.ALIGN_OPPOSITE else android.text.Layout.Alignment.ALIGN_NORMAL
        androidx.compose.ui.text.style.TextAlign.Right -> if (rtl) android.text.Layout.Alignment.ALIGN_NORMAL else android.text.Layout.Alignment.ALIGN_OPPOSITE
        androidx.compose.ui.text.style.TextAlign.End -> android.text.Layout.Alignment.ALIGN_OPPOSITE
        androidx.compose.ui.text.style.TextAlign.Start, androidx.compose.ui.text.style.TextAlign.Unspecified -> android.text.Layout.Alignment.ALIGN_NORMAL
        else -> throw UnsupportedFloatLayout("Static inline parent paragraph alignment is unavailable")
    }
    return NativeStaticInlineParent(format, direction, alignment)
}

/** New absolute offsets use ordinary Container CSS lengths, not the legacy absolute text zoom basis. */
internal fun nativeOrdinaryAbsolutePosition(position: ContainerAbsolutePosition, containingBlockId: Int,
    density: Float, normalBodyFont: Float): NativeAbsolutePosition {
    require(density.isFinite() && density > 0f && normalBodyFont.isFinite() && normalBodyFont >= 0f)
    fun offset(value: ContainerMarginLength): Float {
        val pixels = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density else normalBodyFont
        if (!pixels.isFinite() || kotlin.math.abs(pixels) > TablePixelLimit)
            throw UnsupportedFloatLayout("Absolute Container offset exceeds native geometry")
        return pixels.toFloat()
    }
    return NativeAbsolutePosition(containingBlockId, offset(position.left), offset(position.top))
}

/** Coordinate provenance is independent of typography and follows the original source tree. */
private fun Container.hasClippedAbsoluteDescendant(): Boolean {
    var found = false
    PresentationSpanVisitor { _, _ -> }.apply {
        onSpan = { if (it.clippedAbsolute != null) found = true }
    }.blocks(blocks)
    return found
}

/** Table/Figure descendants start independent adapter trees and never lend this anchor. */
private fun Container.hasOrdinaryAbsoluteDescendant(): Boolean = blocks.any { block ->
    block.container?.let { it.style.absolutePosition != null || it.style.absoluteStatic != null ||
        it.hasOrdinaryAbsoluteDescendant() } == true
}

internal fun positionedOverflowAt(scope: PositionedScope, viewport: Double): PositionedOverflowX {
    if (!viewport.isFinite() || viewport < 0.0) throw UnsupportedFloatLayout("Positioned scope needs the source viewport width")
    return scope.viewportStates.lastOrNull { viewport >= it.minWidthPx.toDouble() }?.overflowX ?: scope.overflowX
}

private fun nativeAbsoluteParagraphs(blocks: List<Block>): Boolean = blocks.all { block ->
    block.kind == "paragraph" && block.depth == 0 && block.container == null && block.table == null &&
        block.figure == null && block.flow == null && block.feature == null &&
        block.spans.all { it.image == null && !it.hasClassToken("wikidict-media") }
}

/** Project only real source owners. A logical UL/OL remains one flex item, and each
 * actual paragraph/figure/table leaf is prepared once at its original source address. */
@Composable
internal fun prepareNativeContainerTree(blocks: List<Block>, path: String, gridPath: String,
    rootPaths: List<String>?, rootGaps: List<Float>, inherited: ContainerTextContext,
    inheritedStyle: TextStyle, inheritedAlign: CellTextAlign?, normalBodySize: TextUnit,
    density: Density, rootViewport: Double, rtl: Boolean, dark: Boolean, fixedHeightReachable: Boolean,
    id: (String) -> Int, positionedPaintReachable: Boolean = false,
    staticInlineAlign: androidx.compose.ui.text.style.TextAlign? = null,
    leaf: @Composable (NativeContainerLeaf) -> List<NativeFloatContextSpec>
): List<NativeFloatContextSpec> {
    val disclosureState = rememberNativeContainerDisclosureState(blocks)
    val inheritedWrap = LocalNativeContainerTextWrap.current
    val inheritedClippedScope = LocalNativeClippedAbsoluteCoordinateScope.current
    val tableDirection = LocalCompiledTableTextDirection.current
    val columnBreakWordMinimum = LocalCaptionBreakWord.current
    val parentTextStyle = androidx.compose.material3.LocalTextStyle.current
    val bodyPixels = normalBodySize.value * density.density * density.fontScale
    val positionedBodyPixels = with(density) { normalBodySize.toPx() }
    fun groupIndices(item: ContainerFlowItem): List<Int> = when (item) {
        is ContainerFlowItem.Block -> listOf(item.index)
        is ContainerFlowItem.ListGroup -> item.items.flatMap { listOf(it.index) + it.children.flatMap(::groupIndices) }
    }
    fun hasTextLeaf(values: List<Block>): Boolean = values.any { block ->
        block.container?.let { it.disclosure != null || hasTextLeaf(it.blocks) } ?: true
    }
    @Composable fun visit(values: List<Block>, paths: List<String>, grids: List<String>,
        gaps: List<Float>, context: ContainerTextContext, align: CellTextAlign?, inside: Boolean,
        row: Boolean, roots: List<Int?>, inScrollport: Boolean,
        positionedParent: NativePositionedParent? = null, ownerWrap: TextWrap? = null,
        declaringFormat: NativeContainerTextFormat? = null,
        ordinaryContainingBlock: Int? = null, staticScope: NativeStaticInlineScope? = null,
        staticInlineParent: NativeStaticInlineParent? = null,
        sourceAlign: androidx.compose.ui.text.style.TextAlign? = null,
        clippedScope: NativeClippedAbsoluteCoordinateScope? = null,
        hiddenChild: Int? = null, columnItems: Boolean = false): List<NativeFloatContextSpec> {
        val result = mutableListOf<NativeFloatContextSpec>()
        val groups = nativeDisclosureFlowItems(values, row, hiddenChild)
        for (group in groups) {
            val indices = groupIndices(group)
            val first = indices.first()
            val block = values[first]
            val container = block.container.takeIf { group is ContainerFlowItem.Block }
            if (container != null) {
                val resolved = container.style.atViewport(rootViewport)
                val absolute = resolved.box.positioning as? ContainerPositioning.Absolute
                val ordinaryAbsolute = resolved.box.absolutePosition
                val ordinaryStatic = resolved.box.absoluteStatic
                val immediateStatic = staticScope?.takeIf { it.child === container && ordinaryStatic != null }
                val scope = resolved.box.positionedScope
                val nonstaticClippedAncestor = resolved.box.positioning != null || ordinaryAbsolute != null ||
                    ordinaryStatic != null || scope != null
                val clippedDomainFailure = if (nonstaticClippedAncestor && container.hasClippedAbsoluteDescendant())
                    "Clipped absolute content requires Entry-root all-static ancestry" else null
                // The typed clipped subset never borrows a closer represented positioned owner.
                val nextClippedScope = clippedScope.takeUnless { nonstaticClippedAncestor }
                val ordinaryRelative = resolved.box.positioning == ContainerPositioning.RelativeAuto && scope == null &&
                    (resolved.box.ownerFont != null || resolved.box.textWrap != null || container.hasOrdinaryAbsoluteDescendant())
                val inheritedContext = if ((context.bodyOrigin != null || context.bodyDirection != null) &&
                    (resolved.box.positioning != null || ordinaryAbsolute != null || ordinaryStatic != null || scope != null))
                    nativeWithoutBodyTextContext(context, normalBodySize, density)
                        ?: checkNotNull(context.bodyOrigin).baseline else context
                val requestedContext = resolved.box.textContext(inheritedContext)
                val absoluteFormat = absolute?.let {
                    nativeAbsoluteContainerTextFormat(it, inheritedStyle, density, inheritedContext.fontFamily,
                        hasLine = container.blocks.any { child -> nativeNoWrapSourceLineStarts(child.spans).isNotEmpty() })
                }
                // A tree containing only empty containers has no text font to resolve.
                // Its real boxes still participate; an actual empty paragraph is a leaf.
                val unusedContainerFont = requestedContext.containerText != null && container.disclosure == null &&
                    !hasTextLeaf(container.blocks)
                val containerContext = if (absoluteFormat == null && requestedContext.containerText != null && !unusedContainerFont)
                    nativeContainerOwnerTextContext(requestedContext, inheritedStyle, density) else null
                val familyAdmission = if (absoluteFormat == null && !unusedContainerFont) nativeContainerFontAdmission(requestedContext.fontFamily,
                    inheritedStyle.fontWeight ?: androidx.compose.ui.text.font.FontWeight.Normal,
                    inheritedStyle.fontStyle ?: androidx.compose.ui.text.font.FontStyle.Normal) else null
                var textFailure: String? = null
                val next = try {
                    if (absoluteFormat != null) {
                        val format = absoluteFormat.getOrThrow()
                        requestedContext.copy(fontFamily = format.sourceFamily, cellText = null, containerText = null)
                    } else if (unusedContainerFont) requestedContext else {
                        checkNotNull(familyAdmission).getOrThrow()
                        val computedContext = containerContext?.getOrThrow() ?: requestedContext
                        nativeContainerTextFormat(computedContext, normalBodySize, inheritedStyle, density)
                        computedContext
                    }
                } catch (error: UnsupportedFloatLayout) {
                    textFailure = error.message ?: "Container text geometry is unavailable"
                    inheritedContext
                }
                val nextAlign = resolved.box.textAlign ?: align
                // Source paragraph direction controls column progression and list markers.
                // Directional spans still retain their own native bidi/isolation policies.
                val columnRtl = if (resolved.box.layout == ContainerLayout.FlexColumn) {
                    LocalNativeColumnTextDirection.current?.let { it == BidiResolvedDirection.Rtl } ?: when (tableDirection) {
                        TableContainingDirection.Ltr -> false
                        TableContainingDirection.Rtl -> true
                        null -> next.bodyDirection?.let { it == BidiResolvedDirection.Rtl } ?: rtl
                    }
                } else if (resolved.box.columns == null) rtl else
                    resolved.box.columns.direction?.let { it == BidiResolvedDirection.Rtl } ?: when (tableDirection) {
                        TableContainingDirection.Ltr -> false
                        TableContainingDirection.Rtl -> true
                        null -> next.bodyDirection?.let { it == BidiResolvedDirection.Rtl } ?: rtl
                    }
                val background = when (val value = resolved.box.background) {
                    is ContainerColor.Rgb -> value.value
                    is ContainerColor.LightDark -> if (dark) value.dark else value.light
                    null, ContainerColor.Transparent -> LocalAuthoredBackground.current
                }
                val children = mutableListOf<NativeFloatContextSpec>()
                val paddingTop = resolved.box.padding?.top?.let {
                    (it.value.toDouble() * if (it.unit == StyleLengthUnit.Px) density.density else positionedBodyPixels).toFloat()
                } ?: 0f
                val childScope = scope?.let { NativePositionedParent(paddingTop) }
                val nextWrap = absolute?.textWrap ?: scope?.textWrap ?: resolved.box.textWrap ?: ownerWrap
                val nextOrdinaryContainingBlock = when {
                    ordinaryRelative -> id(paths[first])
                    ordinaryAbsolute != null || ordinaryStatic != null || absolute != null || scope != null -> null
                    else -> ordinaryContainingBlock
                }
                val nextStaticScope = if (!validSoleStaticInlineContainer(container) || textFailure != null) null else try {
                    val child = checkNotNull(container.blocks.single().container)
                    val parentFormat = nativeContainerTextFormat(next, normalBodySize, inheritedStyle, density).let {
                        it.copy(style = parentTextStyle.merge(it.style))
                    }
                    NativeStaticInlineScope(id(paths[first]), child, nativeStaticInlineParent(parentFormat,
                        checkNotNull(child.style.absoluteStatic), tableDirection, next.bodyDirection,
                        resolved.box.textAlign?.composeAlign() ?: sourceAlign))
                } catch (error: UnsupportedFloatLayout) {
                    textFailure = error.message ?: "Static inline parent typography is unavailable"
                    null
                }
                val disclosure = container.disclosure
                val expanded = disclosure?.let { disclosureState.isExpanded(container, paths[first]) } ?: true
                val hiddenChild = nativeDisclosureHiddenChild(container, expanded)
                val prepareChildren: @Composable () -> Unit = {
                    if (disclosure != null) {
                        val identity = remember(disclosureState, NativeContainerDisclosureSourceIdentity(container), paths[first]) { Any() }
                        val columnDirection = LocalNativeColumnTextDirection.current
                        var toggleFormat: NativeContainerTextFormat? = null
                        var toggleDirection: BidiResolvedDirection? = null
                        try {
                            val format = absoluteFormat?.getOrThrow() ?:
                                nativeDisclosureTextFormat(next,
                                    nativeContainerTextFormat(next, normalBodySize, parentTextStyle.merge(inheritedStyle), density))
                            val inheritedDirection = compiledBodyParagraphDirection(tableDirection, next.bodyDirection,
                                columnDirection) ?: format.style.textDirection
                            toggleFormat = format
                            toggleDirection = disclosure.direction ?: when (inheritedDirection) {
                                androidx.compose.ui.text.style.TextDirection.Ltr -> BidiResolvedDirection.Ltr
                                androidx.compose.ui.text.style.TextDirection.Rtl -> BidiResolvedDirection.Rtl
                                else -> throw UnsupportedFloatLayout("Disclosure needs its represented Container direction")
                            }
                        } catch (error: UnsupportedFloatLayout) {
                            textFailure = textFailure ?: error.message ?: "Disclosure typography is unavailable"
                        }
                        if (toggleFormat != null && toggleDirection != null) {
                            val toggle = prepareNativeContainerDisclosureToggle(disclosure, expanded,
                                { disclosureState.toggle(container, paths[first]) }, checkNotNull(toggleFormat),
                                checkNotNull(toggleDirection), identity)
                            val side = when (disclosure.placement) {
                                ContainerDisclosurePlacement.InlineFlow -> null
                                ContainerDisclosurePlacement.FloatLeft -> TableFloatSide.Left
                                ContainerDisclosurePlacement.FloatRight -> TableFloatSide.Right
                            }
                            children += NativeFloatContextSpec.Child(id(paths[first] + "/disclosure-toggle"),
                                width = { it }, gapAfter = 0f, floatSide = side, logicalObject = false,
                                exactWidth = { containing -> nativeDisclosureWidth(containing, toggle.intrinsic) },
                                exactMeasure = { width ->
                                    val geometry = toggle.measure(width)
                                    NativeExactChildMeasure(NativeBlockMeasure(width, toggle.intrinsic.minimum, geometry.textBottom),
                                        geometry.extents.ink)
                                }, content = { width -> toggle.Content(width) })
                        }
                    }
                    children += visit(container.blocks,
                        container.blocks.indices.map { "${paths[first]}/container/block-$it" },
                        container.blocks.indices.map { "${grids[first]}/container/block-$it" },
                        List(container.blocks.size) { 0f }, next, nextAlign, true,
                        resolved.box.layout == ContainerLayout.FlexRow, List(container.blocks.size) { null },
                        inScrollport || resolved.box.overflow == ContainerOverflow.Auto || resolved.box.overflow == ContainerOverflow.Hidden || scope != null,
                        childScope, nextWrap, absoluteFormat?.getOrNull(), nextOrdinaryContainingBlock,
                        nextStaticScope, immediateStatic?.parent, resolved.box.textAlign?.composeAlign() ?: sourceAlign,
                        nextClippedScope, hiddenChild, resolved.box.layout == ContainerLayout.FlexColumn)
                }
                val cellForeground = LocalNativeCellForeground.current?.let { inherited ->
                    when (resolved.box.background) {
                        is ContainerColor.Rgb, is ContainerColor.LightDark ->
                            inherited.atBackground(background, LocalFigureCaptionForeground.current)
                        null, ContainerColor.Transparent -> inherited
                    }
                }
                val semanticBorderInk = when (resolved.box.background) {
                    is ContainerColor.Rgb, is ContainerColor.LightDark ->
                        nativeBorderNormalOwnerInk(LocalNativeSemanticBorderInk.current,
                            container, NativeSemanticBorderInkOrigin.Container, cellForeground, background)
                    null, ContainerColor.Transparent -> LocalNativeSemanticBorderInk.current
                }
                CompositionLocalProvider(LocalNativeSemanticBorderInk provides semanticBorderInk,
                    LocalAuthoredBackground provides background,
                    LocalNativeCellForeground provides cellForeground) {
                    if (resolved.box.columns == null) prepareChildren() else CompositionLocalProvider(
                        androidx.compose.ui.platform.LocalLayoutDirection provides
                            if (columnRtl) androidx.compose.ui.unit.LayoutDirection.Rtl else androidx.compose.ui.unit.LayoutDirection.Ltr,
                        LocalNativeColumnTextDirection provides
                            (resolved.box.columns.direction ?: LocalNativeColumnTextDirection.current),
                        content = prepareChildren)
                }
                val placement = if (absolute == null || positionedParent == null) null else
                    NativeAbsoluteTextPlacement(absolute.left.value * density.density,
                        absolute.top.value * density.density - positionedParent.paddingTop)
                val scopePolicy = try {
                    scope?.let { NativePositionedScrollportPolicy(container, positionedOverflowAt(it, rootViewport)) }
                } catch (error: UnsupportedFloatLayout) {
                    textFailure = textFailure ?: error.message ?: "Positioned viewport geometry is unavailable"
                    null
                }
                var ordinaryPlacement: NativeAbsolutePosition? = null
                var ordinaryAnchor: NativeAbsoluteContainingBlock? = null
                try {
                    ordinaryPlacement = ordinaryAbsolute?.let { value -> ordinaryContainingBlock?.let { containingId ->
                        nativeOrdinaryAbsolutePosition(value, containingId, density.density, bodyPixels)
                    } }
                    if (ordinaryRelative) {
                        fun padding(value: StyleLength?): Float {
                            val pixels = value?.let { it.value.toDouble() *
                                if (it.unit == StyleLengthUnit.Px) density.density else bodyPixels } ?: 0.0
                            if (!pixels.isFinite() || pixels !in 0.0..TablePixelLimit.toDouble())
                                throw UnsupportedFloatLayout("Relative Container padding exceeds native geometry")
                            return pixels.toFloat()
                        }
                        // The native content origin already includes border; only authored padding is removed.
                        ordinaryAnchor = NativeAbsoluteContainingBlock(padding(resolved.box.padding?.left),
                            padding(resolved.box.padding?.top))
                    }
                } catch (error: UnsupportedFloatLayout) {
                    textFailure = textFailure ?: error.message ?: "Absolute Container geometry is unavailable"
                }
                val prepared = nativeContainerSpec(id(paths[first]), resolved, children,
                    density.density, if (absolute != null || scope != null) positionedBodyPixels else bodyPixels,
                    columnRtl, dark, row || columnItems, scopePolicy, placement, ordinaryPlacement, ordinaryAnchor,
                    immediateStatic?.let { NativeAbsoluteStaticPosition(it.containingBlockId) },
                    columnBreakWordMinimum = columnBreakWordMinimum,
                    ordinaryHidden = NativeOrdinaryHiddenScrollportPolicy(container).takeIf { resolved.box.overflow == ContainerOverflow.Hidden })
                val failure = textFailure ?: (if (scope == null && absolute == null)
                    nativeScrollportUnavailable(container.style, row || columnItems) else null)
                val domainFailure = clippedDomainFailure ?: failure ?: when {
                    resolved.box.layout == ContainerLayout.FlexColumn && !nativeFlexColumnSourceSupported(container) ->
                        "Flex column items require original ordinary nonpositioned Container owners"
                    absolute != null && (positionedParent == null || !nativeAbsoluteParagraphs(container.blocks)) ->
                        "Absolute text requires its direct scope and unreplaced ordinary paragraphs"
                    ordinaryAbsolute != null && (ordinaryContainingBlock == null || !nativeAbsoluteParagraphs(container.blocks)) ->
                        "Absolute positioned content requires its nearest relative Container and ordinary paragraphs"
                    ordinaryStatic != null && (immediateStatic == null || !validContainerAbsoluteStaticBody(container)) ->
                        "Static inline content requires its sole immediate relative Container"
                    inScrollport && positionedParent == null && scope == null && (resolved.box.positioning != null || ordinaryAbsolute != null || ordinaryStatic != null || resolved.box.columns != null ||
                        resolved.box.layout == ContainerLayout.FlexRow || resolved.box.layout == ContainerLayout.FlexColumn) ->
                        "This child layout is unavailable inside a local scrollport"
                    resolved.needsDocumentExtent() && !fixedHeightReachable && absolute == null ->
                        "Container overflow needs this owner's document extent export"
                    (resolved.box.positioning != null || ordinaryAbsolute != null || ordinaryStatic != null) && !positionedPaintReachable ->
                        "Positioned painting needs this owner's Entry stacking context"
                    else -> null
                }
                result += if (domainFailure == null) prepared else prepared.copy(unavailableReason = domainFailure)
            } else {
                val children = mutableListOf<NativeFloatContextSpec>()
                for (index in indices) {
                    val original = values[index]
                    // The generated flex item owns a direct block's edges; list groups
                    // retain every LI/detail's own block edges and marker geometry.
                    val consumed = row && group is ContainerFlowItem.Block
                    val rendered = if (consumed) original.copy(style = null) else original
                    val excludesBody = original.kind == "heading" && (context.bodyDirection != null ||
                        context.bodyOrigin?.let { it.fontInherited || it.lineHeightInherited } == true)
                    val textContext = if (excludesBody) nativeWithoutBodyTextContext(context, normalBodySize, density) else context
                    val format = if (excludesBody) textContext?.let {
                        nativeContainerTextFormat(it, normalBodySize, inheritedStyle, density)
                    } else declaringFormat ?: if (inside || context.bodyOrigin != null)
                        nativeContainerTextFormat(context, normalBodySize, inheritedStyle, density) else null
                    val child = NativeContainerLeaf(rendered, if (inside) null else values.getOrNull(index - 1),
                        id(paths[index] + "/leaf"), paths[index], grids[index], if (inside) 0f else gaps[index],
                        roots[index], format, textContext.takeIf { inside || context.bodyOrigin != null }, align,
                        inside, inScrollport, ownerWrap.takeUnless { rendered.kind == "heading" }, bodyTypographyExcluded = excludesBody,
                        staticInlineParent = staticInlineParent, clippedAbsoluteScope = clippedScope,
                        cellForeground = LocalNativeCellForeground.current, semanticBorderInk = LocalNativeSemanticBorderInk.current)
                    fun bindColumnPolicy(prepared: NativeFloatContextSpec): NativeFloatContextSpec {
                        val policy = original.columnBreakInside ?: return prepared
                        // A non-Text fallback keeps its original body. The column adapter
                        // rejects that represented child before fragmentation is attempted.
                        return (prepared as? NativeFloatContextSpec.Text)?.copy(columnBreakInside = policy) ?: prepared
                    }
                    CompositionLocalProvider(LocalNativeClippedAbsoluteCoordinateScope provides clippedScope) {
                        if (excludesBody) {
                            CompositionLocalProvider(LocalNativeContainerTextContext provides textContext) { children += leaf(child).map(::bindColumnPolicy) }
                        } else if (format?.ownerFont == null) children += leaf(child).map(::bindColumnPolicy) else {
                            CompositionLocalProvider(LocalCellWeight provides null,
                                LocalTableLineHeightPixels provides null,
                                LocalNativeContainerTextContext provides context.copy(cellText = null, fontFamily = format.sourceFamily)) {
                                children += leaf(child).map(::bindColumnPolicy)
                            }
                        }
                    }
                }
                if (!row) result += children else {
                    val own = if (group is ContainerFlowItem.Block) ContainerStyle(margins = block.style?.margins,
                        padding = block.style?.padding) else ContainerStyle()
                    val item = nativeContainerSpec(id(paths[first] + "/logical-item"), own.atViewport(rootViewport), children,
                        density.density, bodyPixels, rtl, dark, true)
                    result += if (group is ContainerFlowItem.Block && block.ruleStyle != null)
                        item.copy(unavailableReason = "Authored rule flex-item margin ownership is unavailable") else item
                }
            }
        }
        return result
    }
    var projected: List<NativeFloatContextSpec> = emptyList()
    CompositionLocalProvider(LocalNativeContainerDisclosureState provides disclosureState) {
    projected = visit(blocks, rootPaths ?: blocks.indices.map { "$path/block-$it" },
        blocks.indices.map { "$gridPath/block-$it" }, rootGaps, inherited, inheritedAlign,
        false, false, blocks.indices.map { it }, false, ownerWrap = inheritedWrap,
        sourceAlign = staticInlineAlign ?: inheritedAlign?.composeAlign(), clippedScope = inheritedClippedScope)
    }
    return projected
}
