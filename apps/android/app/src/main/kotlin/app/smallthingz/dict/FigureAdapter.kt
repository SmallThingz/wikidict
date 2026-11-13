package app.smallthingz.dict

import android.graphics.Canvas as NativeCanvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Spanned
import android.text.StaticLayout
import android.text.Layout
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.layout.Layout as ComposeLayout
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.platform.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import java.util.IdentityHashMap

/** Null is an actual unavailable publication, distinct from a cached successful measure. */
internal typealias SelectionGeometrySink = (FloatTextGeometry?) -> Unit
internal data class FigureReaderContext(val media: List<Media>, val settings: AppSettings, val edition: String,
    val onLink: (EntryLink) -> Unit, val actionOwner: Any)

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
    reader: FigureReaderContext, imageOwner: InlineImageViewOwner? = null,
    missingLinkPaint: NativeMissingLinkPaint? = null, onMissingLinkActivated: () -> Unit = {},
    nativeLineHeight: NativeLineHeightPolicy? = null, figureImageActions: Boolean = false): PreparedNativeFloatText {
    val scoped = scopeTextStyle(inheritedCellTextStyle(style), event.context)
    val spans = event.layoutSpans
    val annotated = styledTextAnnotation(spans, null, scoped, reader.onLink)
    return prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), scoped,
        MaterialTheme.colorScheme.primary, reader.media, reader.settings, reader.edition, reader.onLink,
        imageOwnerOverride = imageOwner, missingLinkPaint = missingLinkPaint, onMissingLinkActivated = onMissingLinkActivated,
        nativeLineHeight = nativeLineHeight, figureImageActions = figureImageActions)
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
    nativeLineHeight: NativeLineHeightPolicy? = null,
) {
    val context = inherited ?: AnonymousFlowContext(
        if (LocalLayoutDirection.current == LayoutDirection.Ltr) BidiResolvedDirection.Ltr else BidiResolvedDirection.Rtl,
        null, inheritedAlign)
    val viewportCss = LocalWindowInfo.current.containerSize.width.toDouble() / LocalDensity.current.density
    val content = remember(block, context, viewportCss) {
        anonymousFlowContent(block, context).let { original -> original.copy(events = original.events.map { event ->
            if (event is AnonymousFlowEvent.FigureObject) event.copy(figure = figureTableViewport(
                staticPosterScreenFigure(event.figure, viewportCss), viewportCss)) else event
        }) }
    }
    val documentOwner = LocalMissingLinkOwner.current
    val actionOwner = remember(documentOwner, block, edition, media) { Any() }
    val reader = FigureReaderContext(media, settings, edition, onLink, actionOwner)
    val positionedBoundary = LocalNativePositionedPaintUnavailable.current
    val delegated = LocalNativeDelegatedFigureScope.current?.takeIf { it.sourceBlock === block }
    val captionBreakWord = LocalCaptionBreakWord.current
    if (positionedBoundary != null && delegated == null &&
        content.events.filterIsInstance<AnonymousFlowEvent.FigureObject>().any {
            it.figure.tableCaptionLayout?.let { layout ->
                (layout.stateAtViewport(viewportCss)?.media ?: layout.media).positioning == ContainerPositioning.RelativeAuto
            } == true
        }) {
        onGeometry(null)
        UnavailableAnonymousContent(block, modifier, delegated?.table?.fallbackReason ?: positionedBoundary, style, reader)
        return
    }
    if (block.needsContainerDocumentExtent()) {
        onGeometry(null)
        UnavailableAnonymousContent(block, modifier,
            "Fixed-height caption overflow needs its document extent export", style, reader)
        return
    }
    if (block.hasColumnsOrPositionedContainer()) {
        onGeometry(null)
        UnavailableAnonymousContent(block, modifier,
            "Caption columns or positioned painting need a joined Container owner", style, reader)
        return
    }
    val prepared = IdentityHashMap<AnonymousFlowEvent.Inline, PreparedNativeFloatText>()
    content.events.filterIsInstance<AnonymousFlowEvent.Inline>().forEach { event ->
        prepared[event] = prepareAnonymousInline(event, style, reader, nativeLineHeight = nativeLineHeight)
    }
    val figures = linkedMapOf<Int, PreparedFigure>()
    content.events.filterIsInstance<AnonymousFlowEvent.FigureObject>().forEach { event ->
        figures[event.id] = prepareFigure(event, reader)
    }
    val base = prepareAnonymousInline(AnonymousFlowEvent.Inline(emptyList(), content.context), style, reader,
        nativeLineHeight = nativeLineHeight)
    if (delegated != null) {
        // Keep this existing resource preparation alive while the one content slot uses
        // its complete fallback. A loading/error/ready or font transition can then retry
        // measured eligibility without a second media or caption composition.
        val revision = listOf(content, style, settings, edition, reader.actionOwner, figures.values.map { it.sourceRevision },
            base.native?.paint?.typeface, base.native?.paint?.textSize)
        SideEffect { delegated.table.prepared(delegated.index, revision) }
        delegated.table.fallbackReason?.let { reason ->
            onGeometry(null)
            UnavailableAnonymousContent(block, modifier, reason, style, reader)
            return
        }
    }
    val marker = prepareAnonymousInline(AnonymousFlowEvent.Inline(emptyList(), content.context),
        MaterialTheme.typography.labelMedium.copy(color = authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)
            ?.let { Color(it) } ?: MaterialTheme.colorScheme.primary), reader)
    val density = LocalDensity.current.density
    val markerWidth = if (prefix.isEmpty()) 0f else 28f * density
    val rtl = content.context.direction == BidiResolvedDirection.Rtl
    val insets = if (rtl) NativeTextInsets(right = indentPixels, extraRight = markerWidth)
        else NativeTextInsets(left = indentPixels, extraLeft = markerWidth)
    val flowInput = LocalNativeFlowMeasureInput.current
    val actualDensity = LocalDensity.current
    val environment = NativeFlowEnvironment(actualDensity.density, actualDensity.fontScale,
        LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
    val outsideMarkerHeight = if (prefix.isEmpty()) 0f else marker.native?.paint?.fontSpacing ?: 0f
    // A preparation owns immutable closures for this composition's spans, fonts, media and actions.
    // Remeasure alone does not create a binding or replace any child/media composition.
    val flowBinding = NativeFlowBinding(environment, insets, outsideMarkerHeight)
    val semanticAncestor = LocalNativeSemanticMeasurement.current
    SideEffect { flowInput?.bind(flowBinding); semanticAncestor?.changed() }
    DisposableEffect(flowInput, flowBinding) { onDispose { flowInput?.unbind(flowBinding) } }
    DisposableEffect(semanticAncestor) { onDispose { semanticAncestor?.changed() } }
    val captionInput = LocalStaticCaptionInput.current
    val measuredModifier = modifier.then(flowInput?.measurement?.modifier ?: Modifier).then(captionInput?.modifier ?: Modifier)
    val actualCarried = captionInput?.let { combineCaptionExclusions(carriedExclusions, it) } ?: carriedExclusions
    val missing = prepared.values.firstOrNull { it.native == null }?.stateDescription
        ?: figures.values.firstNotNullOfOrNull { it.unavailable }
    if (missing != null || base.native == null) {
        onGeometry(null)
        UnavailableAnonymousContent(block, measuredModifier, missing ?: "Figure text layout unavailable", style, reader)
    } else if (!paragraphHasContent(block) && prefix.isEmpty()) {
        val literal = AnonymousFlowOffsets.build(content,
            { event, text -> anonymousInlineSemantic(event.layoutSpans, text) }) { event ->
                checkNotNull(prepared[event]).text.toString()
            }.logicalText
        SelectionEmptyTextBox(literal, measuredModifier, onGeometry)
    } else {
        val measured = remember(content) { linkedMapOf<Int, FloatTextGeometry>() }
        val prefixText by lazy(LazyThreadSafetyMode.NONE) {
            NativeMarkerText(prefix, checkNotNull(marker.native).paint)
        }
        val intrinsicWidths: ((AnonymousFlowEvent.FigureObject) -> Int) -> NativeWidthRange = { figureWidth ->
            anonymousWidthRange(content, base.native.paint,
                inline = { event -> checkNotNull(prepared[event]?.native).source(TablePixelLimit) },
                figureWidth = { event ->
                    val margin = figures.getValue(event.id).margins
                    figureWidth(event) + margin.left + margin.right
                }, inset = insets.left + insets.right + insets.extraLeft + insets.extraRight,
                breakWordMinimum = captionBreakWord)
        }
        CompositionLocalProvider(LocalNativeFlowMeasureInput provides null) {
        AnonymousFlowLayout(content, base.native.paint, measuredModifier, MaterialTheme.colorScheme.primary,
            inline = { event, width -> checkNotNull(prepared[event]?.native).source(width) },
            figureSpec = { event, available -> val preparedFigure = figures.getValue(event.id)
                val metrics = preparedFigure.selectWidth(available)
                AnonymousFigureMeasureSpec(metrics.width, preparedFigure.margins,
                    metrics.frameMinimumWidens || event.figure.tableCaptionLayout != null,
                    childMinimumFloor = event.figure.tableCaptionLayout != null,
                    normalContentLeft = { frameWidth -> preparedFigure.normalLeft(available, frameWidth) }) },
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
            carriedExclusions = actualCarried, onFlowGeometry = onFlowGeometry, insets = insets,
            onFlowUnavailable = { onGeometry(null) },
            measureInput = flowInput, preparedBinding = flowBinding,
            outsideMarkerHeight = outsideMarkerHeight,
            decoration = { canvas, geometry -> if (prefix.isNotEmpty()) {
                val band = geometry.firstLineBand()
                prefixText.paint(canvas, if (rtl) band.right + markerWidth else band.left - markerWidth,
                    band.top - checkNotNull(marker.native).paint.ascent(), rightAligned = rtl)
            } },
            decorationBounds = { geometry -> if (prefix.isEmpty()) null else {
                val band = geometry.firstLineBand()
                val paint = checkNotNull(marker.native).paint
                val x = if (rtl) band.right + markerWidth else band.left - markerWidth
                prefixText.bounds(x, band.top - paint.ascent(), rightAligned = rtl)
            } },
            unavailable = { reason -> UnavailableAnonymousContent(block, Modifier, reason, style, reader) },
            intrinsicWidths = intrinsicWidths,
        ) { event -> figures.getValue(event.id).content {
            if (it == null) measured.remove(event.id) else measured[event.id] = it
        } }
        }
    }
    prepared.values.forEach { it.menu() }
    figures.values.forEach { it.menu() }
}

/** A declared unavailable layout retains data and compiled actions; it is not a float/bidi projection. */
@Composable
internal fun UnavailableAnonymousContent(block: Block, modifier: Modifier, reason: String,
    style: TextStyle, reader: FigureReaderContext, reasonVisible: Boolean = false) {
    val runs = remember(block) { buildList<List<Span>> { block.visitSpanRuns { spans, _ -> add(spans) } } }
    val uri = LocalUriHandler.current
    Column(modifier) {
        if (reasonVisible) Text(reason, style = MaterialTheme.typography.bodyMedium) else ReaderLayoutUnavailable(reason)
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

@Composable
internal fun ReaderLayoutUnavailable(reason: String) {
    LaunchedEffect(reason) { android.util.Log.w("WikiDictLayout", reason) }
    Text("Unable to display this layout.", style = MaterialTheme.typography.bodyMedium)
}

/** A run's action bounds are queried in the final paragraph, never in a separately shaped shard. */
private class AnonymousInlineNodeGeometry(private val owner: NativeAnonymousFlowGeometry,
    private val source: AnonymousInlineSource) : FloatTextGeometry by owner {
    override val text: CharSequence = owner.offsets.nativeText.substring(source.start, source.end)
    override fun rectsForRange(start: Int, end: Int): List<RectF> = owner.nativeRectsForRange(source.start + start, source.start + end)
}

private data class PreparedFigure(val metrics: FigureBoxMetrics?, val unavailable: String?, val sourceRevision: Any,
    val margins: FloatMargins, val normalLeft: (Int, Int) -> Float?,
    val selectWidth: (Int) -> FigureBoxMetrics,
    val content: @Composable (SelectionGeometrySink) -> Unit,
    val menu: @Composable () -> Unit)

@Composable
private fun prepareFigure(event: AnonymousFlowEvent.FigureObject, reader: FigureReaderContext): PreparedFigure {
    val figure = event.figure
    val poster = figure.staticPoster()
    val viewportCss = LocalWindowInfo.current.containerSize.width.toDouble() / LocalDensity.current.density
    val image = (figure.content as? FigureContent.Image)?.span?.image
    val missing = figure.content as? FigureContent.Missing
    val tableLayout = figure.tableCaptionLayout
    val fixedMissingPaint = tableLayout?.missingLinkPaint
    val visits = LocalMissingLinkVisits.current ?: remember { MissingLinkVisits() }
    val documentTitle = LocalMissingLinkDocument.current
    val linkTarget = missing?.takeIf { it.linkPaint != null || fixedMissingPaint != null }
        ?.let { missingLinkTarget(it.span, reader.edition, documentTitle) }
    val missingOccurrence = remember { Any() }
    val actionIdentity = remember(reader.actionOwner, linkTarget, fixedMissingPaint, missing?.span) {
        linkTarget?.let { MissingLinkActionIdentity(reader.actionOwner, it,
            if (fixedMissingPaint == null) null else checkNotNull(missing).span.let { span ->
                NativeLinkOccurrenceIdentity(missingOccurrence, 0, 0, span.text.length, span)
            }) }
    }
    val visited = linkTarget?.let(visits::contains) ?: false
    val dark = LocalReaderDarkTheme.current
    val linkPaint = remember(missing?.linkPaint, fixedMissingPaint, missing?.span?.underline, dark, visited, actionIdentity) {
        if (fixedMissingPaint != null) NativeMissingLinkPaint(fixedMissingPaint, visited,
            checkNotNull(missing).span.underline, actionIdentity)
        else missing?.linkPaint?.let { NativeMissingLinkPaint(it, dark, visited, missing.span.underline, actionIdentity) }
    }
    val bitmapColorFilter = image?.let { rememberInlineImageColorFilter(it) }
    val density = LocalDensity.current
    val bodyStyle = inheritedCellTextStyle(MaterialTheme.typography.bodyLarge)
    val bodyPixels = with(density) { bodyStyle.fontSize.toPx() }
    val tableState = tableLayout?.stateAtViewport(viewportCss)
    val mediaLayout = tableState?.media ?: tableLayout?.media
    val mediaStyleResult = runCatching { mediaLayout?.strut?.let { strut ->
        val size = bodyStyle.fontSize.value.toDouble() * strut.fontScale
        if (!size.isFinite() || size > Int.MAX_VALUE / 4.0)
            throw UnsupportedFloatLayout("Figure media font exceeds the native range")
        bodyStyle.copy(fontSize = size.toFloat().sp,
            fontFamily = if (strut.code) FontFamily.Monospace else bodyStyle.fontFamily,
            fontWeight = if (strut.bold) FontWeight.Bold else FontWeight.Normal,
            fontStyle = if (strut.italic) FontStyle.Italic else FontStyle.Normal,
            fontFeatureSettings = strut.fontFeatures?.nativeSettings ?: bodyStyle.fontFeatureSettings)
    } }
    val mediaContext = mediaLayout?.strut?.let { event.context.copy(direction = it.direction,
        language = it.language) } ?: event.context
    val mediaStrut = mediaStyleResult.getOrNull()?.let { style ->
        prepareAnonymousInline(AnonymousFlowEvent.Inline(emptyList(), mediaContext), style, reader,
            nativeLineHeight = NativeLineHeightPolicy.Pixels(0f))
    }
    val colors = MaterialTheme.colorScheme
    val uri = LocalUriHandler.current
    val imageOwner = if (image == null) null else LocalInlineImageOwner.current ?: rememberInlineImageViewOwner(
        listOf(image), reader.media, reader.settings, reader.edition,
        rasterImages = listOf(RasterImageOccurrence(image, (figure.content as FigureContent.Image).sizing)))
    val state = if (image != null) {
        val owner = checkNotNull(imageOwner)
        LaunchedEffect(owner, image) { owner.ensure(image) }
        owner.states[inlineImageAssetKey(image)] ?: if (reader.settings.allowImages) InlineImageAssetState.Loading else InlineImageAssetState.Disabled
    } else null
    val ready = state as? InlineImageAssetState.Ready
    val missingLineHeight = missing?.let { runCatching {
        figureLengthPixels(it.lineHeight, density.density, bodyPixels)
    } }
    val contentStyle = missingLineHeight?.getOrNull()?.let { height ->
        (mediaStyleResult.getOrNull() ?: bodyStyle).copy(lineHeight = with(density) { height.toSp() })
    } ?: mediaStyleResult.getOrNull() ?: bodyStyle
    val contentContext = if (missing == null) mediaContext else mediaContext.copy(textAlign = CellTextAlign.Center)
    val mediaSpan = figure.content.span.let { span ->
        val inheritedFeatures = mediaLayout?.strut?.fontFeatures
        if (span.fontFeatures == null && inheritedFeatures != null) span.copy(fontFeatures = inheritedFeatures) else span
    }
    val imageActionText = prepareAnonymousInline(AnonymousFlowEvent.Inline(listOf(mediaSpan), contentContext), contentStyle, reader,
        imageOwner, linkPaint, { linkTarget?.let(visits::record) }, figureImageActions = true)
    val missingLabel = missing?.let { value -> runCatching {
        checkNotNull(missingLineHeight).getOrThrow()
        val width = figureCoordinate(figureLengthPixels(value.width, density.density, bodyPixels)).coerceAtLeast(1)
        val factory = imageActionText.geometry ?: throw UnsupportedFloatLayout("Missing figure text is not ready")
        factory(width, emptyList(), true)
    } }
    // Policy/loading/error states are real measured content. They have no intrinsic image axes.
    val placeholder = if (image == null || ready != null) null else runCatching {
        val text = inlineImageFallbackText(image, checkNotNull(state)) ?: when (state) {
            InlineImageAssetState.Disabled -> "Images disabled"
            InlineImageAssetState.Loading -> "Loading image"
            else -> "Image unavailable"
        }
        val paint = imageActionText.native?.paint ?: throw UnsupportedFloatLayout("Image status text is not ready")
        val width = figurePlaceholderWidth(figure, density.density, Layout.getDesiredWidth(text, paint))
        StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
            .setTextDirection(if (contentContext.direction == BidiResolvedDirection.Rtl)
                android.text.TextDirectionHeuristics.RTL else android.text.TextDirectionHeuristics.LTR)
            .setIncludePad(true).build()
    }
    val resolved = runCatching {
        val pixels = when {
            missingLabel != null -> missingLabel.getOrThrow().let { figurePlaceholderPixels(it.width, it.height) }
            ready != null -> figureImagePixels(figure, ready.originalWidth, ready.originalHeight, density.density)
            else -> requireNotNull(placeholder).getOrThrow().let { figurePlaceholderPixels(it.width, it.height) }
        }
        figureBoxMetrics(figure, pixels, density.density, bodyPixels)
    }
    val metrics = resolved.getOrNull()
    var statusLayout = placeholder?.getOrNull()
    fun statusAtWidth(width: Float): StaticLayout {
        val original = checkNotNull(placeholder).getOrThrow()
        val pixels = width.toInt().coerceAtLeast(0)
        if (original.width == pixels) return original
        statusLayout?.takeIf { it.width == pixels }?.let { return it }
        return StaticLayout.Builder.obtain(original.text, 0, original.text.length, original.paint, pixels)
            .setTextDirection(if (contentContext.direction == BidiResolvedDirection.Rtl)
                android.text.TextDirectionHeuristics.RTL else android.text.TextDirectionHeuristics.LTR)
            .setIncludePad(true).build().also { statusLayout = it }
    }
    val tableWrapper = tableLayout?.let { figureTableWrapper(figure, viewportCss) }
    val tablePrepared = runCatching { tableLayout?.let {
        mediaStyleResult.getOrThrow()
        val paint = mediaStrut?.native?.paint ?: throw UnsupportedFloatLayout("Figure media strut is not ready")
        val x = android.graphics.Rect().also { paint.getTextBounds("x", 0, 1, it) }
        val label = missingLabel?.getOrThrow()
        FigureTableCaptionMetrics(it.copy(media = checkNotNull(mediaLayout)), checkNotNull(metrics),
            density.density, bodyPixels, event.context.direction == BidiResolvedDirection.Rtl,
            FigureMediaFont(NativePrimaryFontMetrics.from(paint), x.height().toFloat()),
            label?.baselineForOffset(label.text.length),
            if (placeholder != null) { width -> statusAtWidth(width).height.toFloat() } else null)
    } }
    val beforePrepared = runCatching { tableLayout?.let {
        (if (tableState != null) tableState.captionBefore else it.captionBefore)?.let { before ->
            captionBeforeFloat(before, density.density, bodyPixels)
        }
    } }
    val selectedMetrics = remember(event.id) { NativeLayoutInput<FigureBoxMetrics?>(null) }
    val badge = remember(poster, density.density) { poster?.let { NativeStaticPosterBadge(it, density.density) } }
    fun color(value: FigureColor, fallback: Color): Int = when (value) {
        FigureColor.NativeTheme -> fallback.toArgb(); FigureColor.Transparent -> 0
        is FigureColor.Rgb -> requireNotNull(canonicalColorArgb(value.value)).toInt()
    }
    fun borderColor(border: FigureBorder): Int = when (border) {
        FigureBorder.None -> 0; is FigureBorder.Solid -> color(border.color, colors.outlineVariant)
    }
    val paints = FigurePaints(color(figure.frameBackground, colors.surfaceContainer), borderColor(figure.frameBorder),
        color(figure.imageBackground, colors.surface), borderColor(figure.imageBorder),
        color(figure.captionBackground, colors.surfaceContainer), colors.outlineVariant.toArgb())
    val captionColor = color(figure.captionForeground, colors.onSurface)
    val captionSize = bodyStyle.fontSize.value.toDouble() * figure.captionFontScale
    val captionHeight = runCatching { figureLengthPixels(figure.captionLineHeight, density.density, bodyPixels) }.getOrNull()
    val captionStyle = if (captionSize.isFinite() && captionSize <= Int.MAX_VALUE / 4 && captionHeight != null)
        scopeTextStyle(bodyStyle.copy(fontSize = captionSize.toFloat().sp,
            lineHeight = with(density) { captionHeight.toSp() }, color = Color(captionColor)), event.captionContext) else null
    val captionLinkScope = remember(tableLayout?.captionLinkPaint, visits, documentTitle, reader.actionOwner,
        density.density, bodyPixels) {
        tableLayout?.captionLinkPaint?.let {
            FigureCaptionLinkScope(it, visits, documentTitle, reader.actionOwner, density.density, bodyPixels)
        }
    }
    val map = image?.map
    var mapMenu by remember(event) { mutableStateOf(false) }
    fun activate(action: ImageMapAction) { when (action.kind) {
        ImageMapActionKind.Internal -> reader.onLink(action.entryLink()); ImageMapActionKind.External -> uri.openUri(action.target)
    } }
    val mapActions = map?.let { it.regions.map { region -> region.action } + listOfNotNull(it.defaultAction) }.orEmpty()
    val originalImageAction = imageActionText.native?.nodes(ImageActionBounds(RectF(0f, 0f, 1f, 1f)))?.singleOrNull()
    val resolvedMargins = runCatching {
        if (tableWrapper != null) figureTableMargins(tableWrapper, density.density, bodyPixels)
        else metrics?.margins?.let { FloatMargins(it.top, it.right, it.bottom, it.left) } ?: FloatMargins(0f, 0f, 0f, 0f)
    }
    val unavailable = resolved.exceptionOrNull()?.message ?: tablePrepared.exceptionOrNull()?.message ?:
        resolvedMargins.exceptionOrNull()?.message ?:
        beforePrepared.exceptionOrNull()?.message ?: staticPosterCaptionUnavailable(figure, viewportCss) ?:
        if (captionStyle == null) "Caption metrics unavailable" else null
    val margins = resolvedMargins.getOrElse { FloatMargins(0f, 0f, 0f, 0f) }
    return PreparedFigure(metrics, unavailable,
        listOf(imageOwner, state, metrics, captionStyle, bodyPixels, tableState,
            mediaStrut?.native?.paint?.typeface, imageActionText.native?.paint?.typeface), margins, normalLeft = { available, frameWidth ->
        tableWrapper?.let { figureTableNormalLeft(it, available, frameWidth, density.density, bodyPixels,
            event.context.direction == BidiResolvedDirection.Rtl) }
    }, selectWidth = { available ->
        val natural = checkNotNull(metrics)
        (if (poster == null || ready == null) natural else staticPosterFitMetrics(natural,
            (available - natural.margins.left - natural.margins.right).coerceAtLeast(0f))).also(selectedMetrics::update)
    }, content = { sink ->
        val natural = checkNotNull(metrics); val style = checkNotNull(captionStyle)
        val inheritedCellContext = LocalNativeContainerTextContext.current
        val captionCellContext = inheritedCellContext?.takeIf { it.cellText != null }?.copy(
            cellText = NativeCellTextState(with(density) { style.fontSize.toPx() },
                NativeLineHeightPolicy.Pixels(checkNotNull(captionHeight)))) ?: inheritedCellContext
        FigureChildLayout(natural, sink, metricsInput = selectedMetrics, tableMetrics = tablePrepared.getOrThrow(), caption = { captionSink ->
          CompositionLocalProvider(LocalFigureCaptionForeground provides captionColor,
              LocalNativeContainerTextContext provides captionCellContext,
              LocalCellWeight provides (if (inheritedCellContext?.cellText != null) style.fontWeight else LocalCellWeight.current),
              LocalFigureCaptionLinkScope provides captionLinkScope,
              LocalAuthoredBackground provides (figure.captionBackground as? FigureColor.Rgb)?.value) {
          val captionContent: @Composable (SelectionGeometrySink) -> Unit = { actualSink ->
            val rich = figure.captionBlocks
            if (rich != null) FigureCaptionBlocks(rich, event.captionContext, style, reader, actualSink)
            else if (figure.caption.isEmpty()) SelectionEmptyBox(Modifier, actualSink)
            else AnonymousBlockView(Block("paragraph", 0, figure.caption), Modifier, reader.onLink,
                reader.media, reader.settings, reader.edition, inherited = event.captionContext, style = style,
                onGeometry = actualSink, interactionOwner = false)
          }
          if (tableLayout != null) FigureCaptionFloatFlow(beforePrepared.getOrThrow(), event.captionContext.direction,
              captionSink, captionContent)
          else if (poster == null) captionContent(captionSink)
          else StaticPosterCaption(viewportCss > 639.0, event.captionContext.direction, captionSink, captionContent)
          }
        }, build = { exact, caption ->
            val mapGeometry = ready?.let { asset -> map?.let { value -> exact.image.sourceWidth?.let { w -> exact.image.sourceHeight?.let { h ->
                PreparedImageMap.prepare(value, asset.originalWidth, asset.originalHeight, w, h)
            } } } }
            val label = missingLabel?.getOrThrow()
            val frame = NativeFigureGeometry(exact, caption, paints, { canvas, bounds ->
                if (label != null) {
                    val saved = canvas.save(); canvas.translate(bounds.left, bounds.top)
                    label.paint(canvas); canvas.restoreToCount(saved)
                } else if (ready != null) canvas.drawBitmap(ready.decoded.bitmap, null, bounds,
                    Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply { colorFilter = bitmapColorFilter })
                else {
                    val status = if (tableLayout != null) statusAtWidth(exact.image.width)
                        else checkNotNull(placeholder).getOrThrow()
                    val saved = canvas.save(); canvas.translate(bounds.left, bounds.top)
                    if (tableLayout == null) canvas.clipRect(0f, 0f, bounds.width(), bounds.height())
                    status.draw(canvas); canvas.restoreToCount(saved)
                }
            }, overlay = { canvas ->
                if (ready != null) badge?.draw(canvas, RectF(exact.frameBorder, exact.frameBorder,
                    exact.frameBorder + exact.imageInsets.left + exact.imageBorder * 2f + exact.image.width + exact.imageInsets.right,
                    exact.captionTop))
            }) { bounds ->
                val allocated = exact.tableCaption
                val anchor = allocated?.anchor?.let { RectF(it.left, it.top, it.right, it.bottom) } ?: bounds
                val original = imageActionText.native?.nodes(ImageActionBounds(anchor)).orEmpty().map { node ->
                    if (allocated == null) node else {
                        val after = allocated.after?.let { RectF(it.left, it.top, it.right, it.bottom) }
                        val outline = allocated.prepared.layout.media.focusOutline?.let { value ->
                            val offset = value.offset.value.toDouble() * if (value.offset.unit == StyleLengthUnit.Px) density.density else bodyPixels
                            if (!offset.isFinite() || kotlin.math.abs(offset) > Float.MAX_VALUE)
                                throw UnsupportedFloatLayout("Focus outline offset exceeds the native geometry range")
                            NativeNodeFocusPaint.Outline(RectF(anchor), figureLengthPixels(value.width, density.density, bodyPixels),
                                color(value.color, colors.onSurface), figureLengthPixels(value.radius, density.density, bodyPixels), offset.toFloat())
                        } ?: NativeNodeFocusPaint.None
                        node.copy(bounds = listOfNotNull(RectF(anchor), after), focusPaint = outline)
                    }
                }
                if (allocated != null && label == null && original.size != 1)
                    throw UnsupportedFloatLayout("Figure anchor requires one existing image action owner")
                if (label != null) emptyList() else if (map == null) original else buildList {
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
            val labelOwner = if (label == null || fixedMissingPaint == null) label else {
                val font = NativePrimaryFontMetrics.from(checkNotNull(mediaStrut?.native).paint)
                FigureMissingLinkGeometry(label, figureMissingLinkFragments(label.width.toFloat(), label.height.toFloat(),
                    label.baselineForOffset(label.text.length), exact.imageBorder, exact.imageInsets.left,
                    exact.imageInsets.right, font), fixedMissingPaint, density.density, bodyPixels)
            }
            if (labelOwner == null) frame else NativeSemanticGroup(frame.width, frame.height, listOf(
                PositionedSemanticChild(NoPaintGeometry(labelOwner), exact.imageLeft, exact.imageTop, event.context.direction),
                PositionedSemanticChild(NoPaintGeometry(caption), exact.captionLeft,
                    exact.captionTop + exact.captionPadding.top, event.captionContext.direction,
                    if (caption.text.isNotEmpty()) "\n" else ""),
            ), decoration = frame::paintOrdinary)
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
internal fun FigureChildLayout(metrics: FigureBoxMetrics, sink: SelectionGeometrySink,
    caption: @Composable (SelectionGeometrySink) -> Unit, build: (FloatTextGeometry) -> FloatTextGeometry) =
    FigureChildLayout(metrics, sink, null, null, caption) { _, geometry -> build(geometry) }

@Composable
internal fun FigureChildLayout(metrics: FigureBoxMetrics, sink: SelectionGeometrySink,
    metricsInput: NativeLayoutInput<FigureBoxMetrics?>?,
    tableMetrics: FigureTableCaptionMetrics?,
    caption: @Composable (SelectionGeometrySink) -> Unit, build: (FigureBoxMetrics, FloatTextGeometry) -> FloatTextGeometry) {
    val semanticMeasurement = rememberNativeSemanticMeasurement()
    val semantic = remember { arrayOfNulls<FloatTextGeometry>(1) }
    var painted by remember { mutableStateOf<FloatTextGeometry?>(null) }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semanticMeasurement) {
    ComposeLayout(modifier = semanticMeasurement.modifier.then(metricsInput?.modifier ?: Modifier), content = {
        CompositionLocalProvider(LocalCaptionBreakWord provides (tableMetrics != null)) {
            caption { if (semantic[0] !== it) { semantic[0] = it; semanticMeasurement.changed() } }
        }
        Canvas(Modifier) { painted?.paintOrdinary(drawContext.canvas.nativeCanvas) }
    }, measurePolicy = object : MeasurePolicy {
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            tableMetrics?.intrinsic(measurables.first().minIntrinsicWidth(Constraints.Infinity))?.minimum ?: metrics.width
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            tableMetrics?.intrinsic(measurables.first().minIntrinsicWidth(Constraints.Infinity))?.maximum ?: metrics.width
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semanticMeasurement.measure { try {
        val metrics = tableMetrics?.resolve(constraints.maxWidth,
            measurables.first().minIntrinsicWidth(Constraints.Infinity), exactWidth = constraints.maxWidth)
            ?: (metricsInput?.value ?: metrics)
        val measured = measurables.first().measure(Constraints.fixedWidth(metrics.captionWidth))
        val exact = semantic[0] ?: throw UnsupportedFloatLayout("Caption selection geometry is unavailable")
        if (exact.width != measured.width || exact.height != measured.height)
            throw UnsupportedFloatLayout("Caption geometry differs from its measured child")
        val geometry = build(metrics, exact)
        if (geometry.width != constraints.maxWidth || geometry.height > constraints.maxHeight)
            throw UnsupportedFloatLayout("Figure exceeds its actual child constraints")
        painted = build(metrics, NoPaintGeometry(exact))
        val frame = measurables.last().measure(Constraints.fixed(geometry.width, geometry.height))
        sink(geometry)
        layout(geometry.width, geometry.height) {
            frame.place(0, 0)
            measured.placeWithLayer(0, 0) { translationX = metrics.captionLeft
                translationY = metrics.captionTop + metrics.captionPadding.top }
        }
        } catch (_: UnsupportedFloatLayout) {
            painted = null
            unavailableSelection(constraints, sink)
        } }
    })
    }
}

internal class NoPaintGeometry(private val value: FloatTextGeometry) : FloatTextGeometry by value {
    override fun paint(canvas: NativeCanvas) = Unit
    override fun paintOrdinary(canvas: NativeCanvas) = Unit
}

// A normal measure result keeps the same caption subtree recoverable. Throwing
// through Compose's measure observer leaves that node in its Measuring state.
internal fun MeasureScope.unavailableSelection(constraints: Constraints, sink: SelectionGeometrySink): MeasureResult {
    sink(null)
    return layout(constraints.minWidth, constraints.minHeight) { }
}

@Composable
internal fun SelectionEmptyBox(modifier: Modifier = Modifier, sink: SelectionGeometrySink) {
    SelectionEmptyTextBox("", modifier, sink)
}

@Composable
private fun SelectionEmptyTextBox(text: String, modifier: Modifier, sink: SelectionGeometrySink) {
    val semanticMeasurement = rememberNativeSemanticMeasurement()
    ComposeLayout(content = {}, modifier = modifier.then(semanticMeasurement.modifier).fillMaxWidth(), measurePolicy = object : MeasurePolicy {
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
            val width = constraints.maxWidth.takeIf { constraints.hasBoundedWidth } ?: 0
            sink(EmptyCaptionGeometry(width, text)); return layout(width, 0) { }
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = 0
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = 0
    })
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
    val semanticMeasurement = rememberNativeSemanticMeasurement()
    val captionInput = LocalStaticCaptionInput.current
    val captionChildren = remember(children.size, captionInput) { List(children.size) { StaticCaptionInput() } }
    val geometries = remember(children.size) { arrayOfNulls<FloatTextGeometry>(children.size) }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semanticMeasurement) {
    ComposeLayout(content = {
        children.forEachIndexed { index, content -> key(index) {
          CompositionLocalProvider(LocalStaticCaptionInput provides captionChildren[index].takeIf { captionInput != null }) { content {
            if (geometries[index] !== it) { geometries[index] = it; semanticMeasurement.changed() }
        } } } }
    }, modifier = semanticMeasurement.modifier.then(captionInput?.modifier ?: Modifier).fillMaxWidth(), measurePolicy = object : MeasurePolicy {
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            measurables.maxOfOrNull { it.minIntrinsicWidth(height) } ?: 0
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            measurables.maxOfOrNull { it.maxIntrinsicWidth(height) } ?: 0
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semanticMeasurement.measure { try {
        val width = constraints.maxWidth.takeIf { constraints.hasBoundedWidth }
            ?: throw UnsupportedFloatLayout("Caption needs a bounded containing width")
        val placed = mutableListOf<androidx.compose.ui.layout.Placeable>()
        val geometry = mutableListOf<PositionedSemanticChild>()
        var top = 0
        measurables.forEachIndexed { index, measurable ->
            captionInput?.let { captionChildren[index].update(it.exclusions, y = top.toFloat()) }
            val measured = measurable.measure(Constraints.fixedWidth(width))
            val exact = geometries[index] ?: throw UnsupportedFloatLayout("Caption child selection geometry is unavailable")
            if (exact.width != measured.width || exact.height != measured.height)
                throw UnsupportedFloatLayout("Caption child geometry mismatch")
            geometry += PositionedSemanticChild(NoPaintGeometry(exact), 0f, top.toFloat(), direction,
                if (index > 0 && exact.text.isNotEmpty() && geometry.any { it.geometry.text.isNotEmpty() }) "\n" else "")
            placed += measured; top = figureCoordinate(top.toDouble() + measured.height)
        }
        if (top > constraints.maxHeight) throw UnsupportedFloatLayout("Caption exceeds available height")
        sink(NativeSemanticGroup(width, top, geometry))
        layout(width, top) { var y = 0; placed.forEach { child -> child.place(0, y); y += child.height } }
        } catch (_: UnsupportedFloatLayout) { unavailableSelection(constraints, sink) } }
    })
    }
}
