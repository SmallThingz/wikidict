package app.smallthingz.dict

import android.graphics.Canvas as NativeCanvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Spanned
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.platform.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import java.util.IdentityHashMap

internal typealias SelectionGeometrySink = (FloatTextGeometry) -> Unit
internal data class FigureReaderContext(val media: List<Media>, val settings: AppSettings, val edition: String,
    val onLink: (EntryLink) -> Unit)

@Composable
private fun scopeTextStyle(style: TextStyle, context: AnonymousFlowContext): TextStyle = style.copy(
    textDirection = if (context.direction == BidiResolvedDirection.Ltr) TextDirection.Ltr else TextDirection.Rtl,
    textAlign = when (context.textAlign) { CellTextAlign.Left -> TextAlign.Left; CellTextAlign.Center -> TextAlign.Center
        CellTextAlign.Right -> TextAlign.Right; null -> style.textAlign },
    localeList = when (val language = context.language) { null -> style.localeList; "" -> LocaleList.current
        else -> LocaleList(Locale(language)) },
)

@Composable
private fun prepareAnonymousInline(event: AnonymousFlowEvent.Inline, style: TextStyle,
    reader: FigureReaderContext): PreparedNativeFloatText {
    val scoped = scopeTextStyle(style, event.context)
    val spans = event.layoutSpans
    val annotated = styledTextAnnotation(spans, null, scoped, reader.onLink)
    return prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), scoped,
        MaterialTheme.colorScheme.primary, reader.media, reader.settings, reader.edition, reader.onLink)
}

/** Existing media owner, typed actions and native text preparation feed the one anonymous owner. */
@Composable
internal fun AnonymousBlockView(block: Block, modifier: Modifier, onLink: (EntryLink) -> Unit,
    media: List<Media>, settings: AppSettings, edition: String, inheritedAlign: CellTextAlign? = null,
    inherited: AnonymousFlowContext? = null, style: TextStyle = MaterialTheme.typography.bodyLarge,
    onGeometry: SelectionGeometrySink = {},
    interactionOwner: Boolean = true,
    carriedExclusions: List<NativeFloatExclusion> = emptyList(),
    onFlowGeometry: (NativeAnonymousFlowGeometry) -> Unit = {},
    prefix: String = "", indentPixels: Float = 0f,
) {
    val context = inherited ?: AnonymousFlowContext(
        if (LocalLayoutDirection.current == LayoutDirection.Ltr) BidiResolvedDirection.Ltr else BidiResolvedDirection.Rtl,
        null, inheritedAlign)
    val content = remember(block, context) { anonymousFlowContent(block, context) }
    val reader = FigureReaderContext(media, settings, edition, onLink)
    val prepared = IdentityHashMap<AnonymousFlowEvent.Inline, PreparedNativeFloatText>()
    content.events.filterIsInstance<AnonymousFlowEvent.Inline>().forEach { event ->
        prepared[event] = prepareAnonymousInline(event, style, reader)
    }
    val figures = linkedMapOf<Int, PreparedFigure>()
    content.events.filterIsInstance<AnonymousFlowEvent.FigureObject>().forEach { event ->
        figures[event.id] = prepareFigure(event, reader)
    }
    val base = prepareAnonymousInline(AnonymousFlowEvent.Inline(emptyList(), content.context), style, reader)
    val marker = prepareAnonymousInline(AnonymousFlowEvent.Inline(emptyList(), content.context),
        MaterialTheme.typography.labelMedium.copy(color = authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)
            ?.let { Color(it) } ?: MaterialTheme.colorScheme.primary), reader)
    val density = LocalDensity.current.density
    val markerWidth = if (prefix.isEmpty()) 0f else 28f * density
    val rtl = content.context.direction == BidiResolvedDirection.Rtl
    val insets = if (rtl) NativeTextInsets(right = indentPixels, extraRight = markerWidth)
        else NativeTextInsets(left = indentPixels, extraLeft = markerWidth)
    val missing = prepared.values.firstOrNull { it.native == null }?.stateDescription
        ?: figures.values.firstNotNullOfOrNull { it.unavailable }
    if (missing != null || base.native == null) {
        UnavailableAnonymousContent(block, modifier, missing ?: "Figure text layout unavailable", style, reader)
    } else if (!paragraphHasContent(block) && prefix.isEmpty()) {
        val literal = AnonymousFlowOffsets.build(content,
            { event, text -> anonymousInlineSemantic(event.layoutSpans, text) }) { event ->
                checkNotNull(prepared[event]).text.toString()
            }.logicalText
        SelectionEmptyTextBox(literal, modifier, onGeometry)
    } else {
        val measured = linkedMapOf<Int, FloatTextGeometry>()
        AnonymousFlowLayout(content, base.native.paint, modifier, MaterialTheme.colorScheme.primary,
            inline = { event, width -> checkNotNull(prepared[event]?.native).source(width) },
            figureSpec = { event, _ -> val metrics = checkNotNull(figures.getValue(event.id).metrics)
                AnonymousFigureMeasureSpec(metrics.width, FloatMargins(metrics.margins.top, metrics.margins.right,
                    metrics.margins.bottom, metrics.margins.left), metrics.frameMinimumWidens) },
            inlineNodes = { geometry -> buildList {
                if (prefix.isNotEmpty()) {
                    val band = geometry.firstLineBand()
                    val bounds = if (rtl) RectF(band.right, band.top, band.right + markerWidth, band.bottom)
                        else RectF(band.left - markerWidth, band.top, band.left, band.bottom)
                    add(FloatInteractionNode(0, FloatInteractionKind.MARKER, 0, 0, listOf(bounds), prefix, null, null))
                }
                addAll(content.events.filterIsInstance<AnonymousFlowEvent.Inline>().flatMap { event ->
                val source = geometry.offsets.inlineSources.single { it.event === event }
                val local = AnonymousInlineNodeGeometry(geometry, source)
                checkNotNull(prepared[event]?.native).nodes(local).map { node -> node.copy(
                    start = geometry.selection.semanticOffset(source.start + node.start),
                    end = geometry.selection.semanticOffset(source.start + node.end),
                    label = node.label?.let { label -> if (label.toString() == local.text.subSequence(node.start, node.end).toString())
                        geometry.text.subSequence(geometry.selection.semanticOffset(source.start + node.start),
                            geometry.selection.semanticOffset(source.start + node.end)) else label },
                ) }
                })
            } },
            semanticGeometry = { event, _, _ -> measured[event.id] },
            inlineSemantic = { event, text -> anonymousInlineSemantic(event.layoutSpans, text) },
            onGeometry = onGeometry,
            interactionOwner = interactionOwner,
            carriedExclusions = carriedExclusions, onFlowGeometry = onFlowGeometry, insets = insets,
            outsideMarkerHeight = if (prefix.isEmpty()) 0f else checkNotNull(marker.native).paint.fontSpacing,
            decoration = { canvas, geometry -> if (prefix.isNotEmpty()) {
                val band = geometry.firstLineBand()
                val paint = android.text.TextPaint(checkNotNull(marker.native).paint).apply {
                    textAlign = if (rtl) Paint.Align.RIGHT else Paint.Align.LEFT
                }
                canvas.drawText(prefix, if (rtl) band.right + markerWidth else band.left - markerWidth,
                    band.top - paint.ascent(), paint)
            } },
            unavailable = { reason -> UnavailableAnonymousContent(block, Modifier, reason, style, reader) },
        ) { event, _ -> figures.getValue(event.id).content { measured[event.id] = it } }
    }
    prepared.values.forEach { it.menu() }
    figures.values.forEach { it.menu() }
}

/** A declared unavailable layout retains data and compiled actions; it is not a float/bidi projection. */
@Composable
private fun UnavailableAnonymousContent(block: Block, modifier: Modifier, reason: String,
    style: TextStyle, reader: FigureReaderContext) {
    val runs = remember(block) { buildList<List<Span>> { block.visitSpanRuns { spans, _ -> add(spans) } } }
    val uri = LocalUriHandler.current
    Column(modifier) {
        Text("Figure layout unavailable: $reason")
        runs.forEach { spans ->
            // A mapped image has no implicit File click. Its authored actions stay separately usable.
            val visible = spans.map { span -> if (span.image?.map == null) span else span.copy(
                kind = "text", target = "", targetFragment = null, text = span.image.alt.orEmpty(), image = null) }
            StyledText(visible, style = style, onLink = reader.onLink)
            spans.forEach { span -> span.image?.map?.let { map ->
                (map.regions.map { it.action } + listOfNotNull(map.defaultAction)).forEach { action ->
                    TextButton(onClick = { when (action.kind) {
                        ImageMapActionKind.Internal -> reader.onLink(action.entryLink())
                        ImageMapActionKind.External -> uri.openUri(action.target)
                    } }) { Text(action.label) }
                }
            } }
        }
    }
}

/** A run's action bounds are queried in the final paragraph, never in a separately shaped shard. */
private class AnonymousInlineNodeGeometry(private val owner: NativeAnonymousFlowGeometry,
    private val source: AnonymousInlineSource) : FloatTextGeometry by owner {
    override val text: CharSequence = owner.offsets.nativeText.substring(source.start, source.end)
    override fun rectsForRange(start: Int, end: Int): List<RectF> = owner.nativeRectsForRange(source.start + start, source.start + end)
}

private data class PreparedFigure(val metrics: FigureBoxMetrics?, val unavailable: String?,
    val content: @Composable (SelectionGeometrySink) -> Unit,
    val menu: @Composable () -> Unit)

@Composable
private fun prepareFigure(event: AnonymousFlowEvent.FigureObject, reader: FigureReaderContext): PreparedFigure {
    val figure = event.figure
    val image = requireNotNull(figure.imageSpan.image)
    val density = LocalDensity.current
    val bodyStyle = MaterialTheme.typography.bodyLarge
    val bodyPixels = with(density) { bodyStyle.fontSize.toPx() }
    val colors = MaterialTheme.colorScheme
    val uri = LocalUriHandler.current
    val owner = LocalInlineImageOwner.current ?: rememberInlineImageViewOwner(listOf(image), reader.media,
        reader.settings, reader.edition)
    LaunchedEffect(owner, image.file) { owner.ensure(image.file) }
    val state = owner.states[image.file] ?: if (reader.settings.allowImages) InlineImageAssetState.Loading else InlineImageAssetState.Disabled
    val ready = state as? InlineImageAssetState.Ready
    val resolved = if (ready == null) Result.failure(UnsupportedFloatLayout(when (state) {
        InlineImageAssetState.Disabled -> "Images disabled"; InlineImageAssetState.Loading -> "Loading image"
        else -> "Image geometry unavailable"
    })) else runCatching { figureBoxMetrics(figure,
        figureImagePixels(figure, ready.originalWidth, ready.originalHeight, density.density),
        density.density, bodyPixels) }
    val metrics = resolved.getOrNull()
    fun color(value: FigureColor, fallback: Color): Int = when (value) {
        FigureColor.NativeTheme -> fallback.toArgb(); FigureColor.Transparent -> 0
        is FigureColor.Rgb -> requireNotNull(canonicalColorArgb(value.value)).toInt()
    }
    fun borderColor(border: FigureBorder): Int = when (border) {
        FigureBorder.None -> 0; is FigureBorder.Solid -> color(border.color, colors.outlineVariant)
    }
    val paints = FigurePaints(color(figure.frameBackground, colors.surfaceContainer), borderColor(figure.frameBorder),
        color(figure.imageBackground, colors.surface), borderColor(figure.imageBorder),
        color(figure.captionBackground, colors.surfaceContainer))
    val captionColor = color(figure.captionForeground, colors.onSurface)
    val captionSize = bodyStyle.fontSize.value.toDouble() * figure.captionFontScale
    val captionHeight = runCatching { figureLengthPixels(figure.captionLineHeight, density.density, bodyPixels) }.getOrNull()
    val captionStyle = if (captionSize.isFinite() && captionSize <= Int.MAX_VALUE / 4 && captionHeight != null)
        scopeTextStyle(bodyStyle.copy(fontSize = captionSize.toFloat().sp,
            lineHeight = with(density) { captionHeight.toSp() }, color = Color(captionColor)), event.captionContext) else null
    val imageActionText = prepareAnonymousInline(AnonymousFlowEvent.Inline(listOf(figure.imageSpan), event.context), bodyStyle, reader)
    val map = image.map
    var mapMenu by remember(event) { mutableStateOf(false) }
    fun activate(action: ImageMapAction) { when (action.kind) {
        ImageMapActionKind.Internal -> reader.onLink(action.entryLink()); ImageMapActionKind.External -> uri.openUri(action.target)
    } }
    val mapActions = map?.let { it.regions.map { region -> region.action } + listOfNotNull(it.defaultAction) }.orEmpty()
    val originalImageAction = imageActionText.native?.nodes(ImageActionBounds(RectF(0f, 0f, 1f, 1f)))?.singleOrNull()
    val unavailable = resolved.exceptionOrNull()?.message ?: if (captionStyle == null) "Caption metrics unavailable" else null
    return PreparedFigure(metrics, unavailable, content = { sink ->
        val exact = checkNotNull(metrics); val asset = checkNotNull(ready); val style = checkNotNull(captionStyle)
        FigureChildLayout(exact, sink, caption = { captionSink ->
          CompositionLocalProvider(LocalFigureCaptionForeground provides captionColor,
              LocalAuthoredBackground provides (figure.captionBackground as? FigureColor.Rgb)?.value) {
            val rich = figure.captionBlocks
            if (rich != null) FigureCaptionBlocks(rich, event.captionContext, style, reader, captionSink)
            else if (figure.caption.isEmpty()) SelectionEmptyBox(Modifier, captionSink)
            else AnonymousBlockView(Block("paragraph", 0, figure.caption), Modifier, reader.onLink,
                reader.media, reader.settings, reader.edition, inherited = event.captionContext, style = style,
                onGeometry = captionSink, interactionOwner = false)
          }
        }, build = { caption ->
            val mapGeometry = map?.let { value -> exact.image.sourceWidth?.let { w -> exact.image.sourceHeight?.let { h ->
                PreparedImageMap.prepare(value, asset.originalWidth, asset.originalHeight, w, h)
            } } }
            NativeFigureGeometry(exact, caption, paints, { canvas, bounds ->
                canvas.drawBitmap(asset.decoded.bitmap, null, bounds, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
            }) { bounds ->
                val original = imageActionText.native?.nodes(ImageActionBounds(bounds)).orEmpty()
                if (map == null) original else buildList {
                    addAll(original.map { it.copy(onClick = null, onLongClick = { mapMenu = true }) })
                    mapActions.forEachIndexed { index, action ->
                        add(FloatInteractionNode(index + 1, FloatInteractionKind.LINK, 0, 0, listOf(RectF(bounds)),
                            action.label, action.label, { activate(action) },
                            if (mapGeometry == null) "Image map geometry unavailable" else null,
                            hitTest = { x, y -> val hit = mapGeometry?.hit(ImageMapBounds(bounds.left.toDouble(), bounds.top.toDouble(),
                                bounds.width().toDouble(), bounds.height().toDouble()), x.toDouble(), y.toDouble())
                                hit is ImageMapHit.Action && hit.regionIndex == index.takeIf { it < map.regions.size } }) )
                    }
                }
            }
        })
    }, menu = {
        imageActionText.menu()
        DropdownMenu(mapMenu, { mapMenu = false }) {
            mapActions.forEach { action -> DropdownMenuItem(text = { Text(action.label) }, onClick = { mapMenu = false; activate(action) }) }
            originalImageAction?.onLongClick?.let { details -> DropdownMenuItem(text = { Text("Image details") },
                onClick = { mapMenu = false; details() }) }
        }
    })
}

private class ImageActionBounds(private val bounds: RectF) : FloatTextGeometry by EmptyCaptionGeometry(1) {
    override val text = "\ufffc"
    override fun rectsForRange(start: Int, end: Int): List<RectF> = if (start < end) listOf(RectF(bounds)) else emptyList()
}

@Composable
private fun FigureChildLayout(metrics: FigureBoxMetrics, sink: SelectionGeometrySink,
    caption: @Composable (SelectionGeometrySink) -> Unit, build: (FloatTextGeometry) -> NativeFigureGeometry) {
    SubcomposeLayout { constraints ->
        var semantic: FloatTextGeometry? = null
        val measured = subcompose("caption") { caption { semantic = it } }.single()
            .measure(Constraints.fixedWidth(metrics.captionWidth))
        val exact = semantic ?: throw UnsupportedFloatLayout("Caption selection geometry is unavailable")
        if (exact.width != measured.width || exact.height != measured.height)
            throw UnsupportedFloatLayout("Caption geometry differs from its measured child")
        val geometry = build(exact)
        if (geometry.width != constraints.maxWidth || geometry.height > constraints.maxHeight)
            throw UnsupportedFloatLayout("Figure exceeds its actual child constraints")
        val frame = subcompose("figure-paint") {
            Canvas(Modifier) { build(NoPaintGeometry(exact)).paint(drawContext.canvas.nativeCanvas) }
        }.single().measure(Constraints.fixed(geometry.width, geometry.height))
        sink(geometry)
        layout(geometry.width, geometry.height) {
            frame.place(0, 0)
            measured.placeWithLayer(0, 0) { translationX = metrics.captionLeft
                translationY = metrics.captionTop + metrics.captionPadding.top }
        }
    }
}

internal class NoPaintGeometry(private val value: FloatTextGeometry) : FloatTextGeometry by value {
    override fun paint(canvas: NativeCanvas) = Unit
}

@Composable
internal fun SelectionEmptyBox(modifier: Modifier = Modifier, sink: SelectionGeometrySink) {
    SelectionEmptyTextBox("", modifier, sink)
}

@Composable
private fun SelectionEmptyTextBox(text: String, modifier: Modifier, sink: SelectionGeometrySink) {
    SubcomposeLayout(modifier.fillMaxWidth()) { constraints ->
        val width = constraints.maxWidth.takeIf { constraints.hasBoundedWidth } ?: 0
        sink(EmptyCaptionGeometry(width, text)); layout(width, 0) { }
    }
}

@Composable
internal fun FigureCaptionBlocks(blocks: List<Block>, context: AnonymousFlowContext, style: TextStyle,
    reader: FigureReaderContext, sink: SelectionGeometrySink, gapDp: Float = 6f) {
    if (blocks.isEmpty()) { SelectionEmptyBox(sink = sink); return }
    SelectionColumn(blocks.indices.map { index -> { childSink: SelectionGeometrySink ->
        FigureCaptionBlock(blocks[index], blocks.getOrNull(index - 1), index != blocks.lastIndex,
            context, style, reader, childSink, gapDp)
    } }, context.direction, sink)
}

@Composable
internal fun SelectionColumn(children: List<@Composable (SelectionGeometrySink) -> Unit>,
    direction: BidiResolvedDirection, sink: SelectionGeometrySink) {
    SubcomposeLayout(Modifier.fillMaxWidth()) { constraints ->
        val width = constraints.maxWidth.takeIf { constraints.hasBoundedWidth }
            ?: throw UnsupportedFloatLayout("Caption needs a bounded containing width")
        val placed = mutableListOf<androidx.compose.ui.layout.Placeable>()
        val geometry = mutableListOf<PositionedSemanticChild>()
        var top = 0
        children.forEachIndexed { index, content ->
            var child: FloatTextGeometry? = null
            val measured = subcompose(index) { content { child = it } }.single().measure(Constraints.fixedWidth(width))
            val exact = child ?: throw UnsupportedFloatLayout("Caption child selection geometry is unavailable")
            if (exact.width != measured.width || exact.height != measured.height)
                throw UnsupportedFloatLayout("Caption child geometry mismatch")
            geometry += PositionedSemanticChild(NoPaintGeometry(exact), 0f, top.toFloat(), direction,
                if (index > 0 && exact.text.isNotEmpty() && geometry.any { it.geometry.text.isNotEmpty() }) "\n" else "")
            placed += measured; top = figureCoordinate(top.toDouble() + measured.height)
        }
        if (top > constraints.maxHeight) throw UnsupportedFloatLayout("Caption exceeds available height")
        sink(NativeSemanticGroup(width, top, geometry))
        layout(width, top) { var y = 0; placed.forEach { child -> child.place(0, y); y += child.height } }
    }
}
