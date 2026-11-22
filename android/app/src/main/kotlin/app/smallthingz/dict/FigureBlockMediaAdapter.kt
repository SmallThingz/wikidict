package app.smallthingz.dict

import android.graphics.Paint
import android.graphics.Rect
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import androidx.compose.foundation.Canvas
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.sp

internal const val NativeFigureBlockMediaLanguageUnavailable = "Figure media language is unavailable for this layout."

/** A source block has one native media line and no caption subtree or anonymous table. */
@Composable
internal fun prepareBlockMediaFigure(event: AnonymousFlowEvent.FigureObject,
    reader: FigureReaderContext, policy: FigureBlockMediaLayout): PreparedFigure {
    val figure = event.figure
    val content = figure.content as FigureContent.Image
    val image = checkNotNull(content.span.image)
    val density = LocalDensity.current
    val viewport = LocalTableDocumentViewportCssWidth.current
        ?: (LocalWindowInfo.current.containerSize.width.toDouble() / density.density)
    val selectedState = runCatching { policy.stateAtViewport(viewport) }
    val wrapper = selectedState.getOrNull()?.wrapper ?: policy.wrapper
    val media = selectedState.getOrNull()?.media ?: policy.media
    val language = nativeTableOwnerLanguageTag(media.strut.language)
    // Source factors and normalized em lengths use the independent reader body font once.
    val body = MaterialTheme.typography.bodyLarge
    val bodyPixels = with(density) { body.fontSize.toPx() }
    val mediaStyle = runCatching {
        val size = body.fontSize.value.toDouble() * media.strut.fontScale
        if (!body.fontSize.isSp || !size.isFinite() || size * density.density * density.fontScale > MaxComputedFontPixels)
            throw UnsupportedFloatLayout("Figure media font exceeds the native range")
        body.copy(fontSize = size.toFloat().sp,
            fontFamily = if (media.strut.code) FontFamily.Monospace else body.fontFamily,
            fontWeight = if (media.strut.bold) FontWeight.Bold else FontWeight.Normal,
            fontStyle = if (media.strut.italic) FontStyle.Italic else FontStyle.Normal,
            fontFeatureSettings = media.strut.fontFeatures?.nativeSettings ?: body.fontFeatureSettings,
            localeList = language?.let { LocaleList(Locale(it)) },
            textDirection = if (media.strut.direction == BidiResolvedDirection.Rtl) TextDirection.Rtl else TextDirection.Ltr,
            textAlign = when (checkNotNull(wrapper.textAlign)) {
                CellTextAlign.Left -> TextAlign.Left; CellTextAlign.Center -> TextAlign.Center; CellTextAlign.Right -> TextAlign.Right
            })
    }
    val owner = LocalInlineImageOwner.current?.takeIf { it.blockMediaLayout == policy }
        ?: rememberInlineImageViewOwner(listOf(image), reader.media, reader.settings, reader.edition,
            rasterImages = listOf(RasterImageOccurrence(image, content.sizing)), blockMediaLayout = policy)
    LaunchedEffect(owner, image) { owner.ensure(image) }
    val state = owner.states[inlineImageAssetKey(image)]
        ?: if (reader.settings.allowImages) InlineImageAssetState.Loading else InlineImageAssetState.Disabled
    val request = remember(policy, density.density) { runCatching { FigureBlockMediaRequest(policy, density.density) } }
    val colorFilter = rememberInlineImageColorFilter(image)
    val bitmapPaint = remember(colorFilter) { Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
        this.colorFilter = colorFilter
    } }
    val spans = listOf(content.span)
    lateinit var actionText: PreparedNativeFloatText
    // The explicit source font/language/direction replaces inherited cell projections for this owner.
    CompositionLocalProvider(LocalCellWeight provides null, LocalCellLetterSpacingPixels provides null,
        LocalCompiledTableSourceLanguage provides null, LocalCompiledTableTextDirection provides null,
        LocalNativeContainerTextContext provides null) {
        val style = mediaStyle.getOrNull() ?: body
        actionText = prepareNativeFloatText(spans, styledTextAnnotation(spans, null, style, reader.onLink),
            egyptianTextRuns(spans), style, MaterialTheme.colorScheme.primary, reader.media, reader.settings,
            reader.edition, reader.onLink, imageOwnerOverride = owner,
            nativeLineHeight = NativeLineHeightPolicy.Normal, figureImageActions = true)
    }
    val prepared = runCatching {
        selectedState.getOrThrow()
        if (language == null) throw UnsupportedFloatLayout(NativeFigureBlockMediaLanguageUnavailable)
        mediaStyle.getOrThrow()
        val ready = state as? InlineImageAssetState.Ready
            ?: throw UnsupportedFloatLayout(when (state) {
                InlineImageAssetState.Disabled -> "Figure source image is disabled."
                InlineImageAssetState.Loading -> "Figure source image is loading."
                else -> "Figure source image is unavailable."
            })
        request.getOrThrow().assertReady(ready)
        val paint = actionText.native?.paint ?: throw UnsupportedFloatLayout("Figure media font is unavailable")
        val line = StaticLayout.Builder.obtain("", 0, 0, paint, 1)
            .setTextDirection(if (media.strut.direction == BidiResolvedDirection.Rtl)
                TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR)
            .setIncludePad(true).setUseLineSpacingFromFallbacks(true).build()
        val baseline = line.getLineBaseline(0)
        val normal = NativeUsedLineMetrics((line.getLineTop(0) - baseline).toFloat(),
            (line.getLineBottom(0) - baseline).toFloat())
        val x = Rect().also { paint.getTextBounds("x", 0, 1, it) }
        FigureBlockMediaMetrics(wrapper, media, policy.preferredWidthPx, policy.naturalWidth, policy.naturalHeight,
            density.density, bodyPixels, FigureMediaFont(NativePrimaryFontMetrics.from(paint), x.height().toFloat()),
            normal, event.context.direction).also {
            if (it.margins.top != 0f || it.margins.bottom != 0f)
                throw UnsupportedFloatLayout("Figure block vertical margins need a joined margin owner")
        }
    }
    val selected = remember(event, policy, selectedState, state, mediaStyle, bodyPixels, density.density, density.fontScale) {
        NativeLayoutInput<FigureBlockMediaAllocation?>(null)
    }
    val initial = runCatching { prepared.getOrThrow().resolve(0f) }
    fun select(width: Float): FigureBoxMetrics {
        val value = prepared.getOrElse { throw UnsupportedFloatLayout(it.message ?: "Figure block layout unavailable") }
            .resolve(width)
        selected.update(value)
        return value.metrics
    }
    return PreparedFigure(initial.getOrNull()?.metrics,
        prepared.exceptionOrNull()?.message ?: initial.exceptionOrNull()?.message,
        listOf(policy, selectedState, owner, state, mediaStyle, actionText.native?.paint?.typeface, request.getOrNull()?.identity,
            event.context.direction, bodyPixels, density.density, density.fontScale),
        FloatMargins(0f, 0f, 0f, 0f), normalLeft = { _, _ -> selected.value?.box?.marginLeft },
        selectWidth = { select(it.toFloat()) }, content = { sink ->
            FigureBlockMediaChildLayout(selected, prepared.getOrThrow().intrinsic(), sink) { allocation ->
                val ready = state as InlineImageAssetState.Ready
                request.getOrThrow().assertReady(ready)
                val exact = allocation.metrics
                val frame = NativeFigureGeometry(exact, EmptyCaptionGeometry(exact.captionWidth), FigurePaints(0, 0, 0, 0, 0),
                    drawImage = { canvas, bounds -> canvas.drawBitmap(ready.decoded.bitmap, null, bounds, bitmapPaint) },
                    imageNodes = { bounds ->
                        val nodes = checkNotNull(actionText.native).nodes(ImageActionBounds(bounds))
                        if (nodes.size != 1 || nodes.single().kind != FloatInteractionKind.IMAGE || nodes.single().onClick != null)
                            throw UnsupportedFloatLayout("Figure block image requires its sole existing nonlink owner")
                        nodes
                    })
                val imageBounds = frame.imageBounds.let { NativeFloatBounds(it.left, it.top, it.right, it.bottom) }
                object : FloatTextGeometry by frame {
                    // A ceil allocation is not painted source overflow. Preserve the exact
                    // block/line box and actual image ink when exporting to parent owners.
                    override val extents = NativeGeometryExtents(frame.width, allocation.lineHeight,
                        NativeFloatBounds(minOf(0f, imageBounds.left), minOf(0f, imageBounds.top),
                            maxOf(allocation.box.borderBox, imageBounds.right), maxOf(allocation.lineHeight, imageBounds.bottom)),
                        nativeBoundsOf(frame.nodes.flatMap { it.bounds }))
                    override val ordinaryPaintBounds = listOf(imageBounds)
                }
            }
        }, menu = { actionText.menu() }, blockWidth = ::select,
        blockUsedBox = { selected.value?.let { NativeFigureUsedBox(it.box.borderBox, it.lineHeight,
            SignedNativeContainerMargins(it.margins.top, it.box.marginRight, it.margins.bottom, it.box.marginLeft)) } },
        intrinsicHorizontalMargins = prepared.getOrNull()?.let { it.margins.left + it.margins.right },
        unavailableActions = {
            if (state == InlineImageAssetState.Failed || state is InlineImageAssetState.GeometryUnavailable) {
                TextButton(onClick = { owner.retry(image) }) { Text("Retry image") }
            }
        })
}

/** The actual media geometry is painted once; there is no caption layout or second semantics tree. */
@Composable
private fun FigureBlockMediaChildLayout(input: NativeLayoutInput<FigureBlockMediaAllocation?>,
    intrinsic: NativeWidthRange, sink: SelectionGeometrySink,
    build: (FigureBlockMediaAllocation) -> FloatTextGeometry) {
    val semantic = rememberNativeSemanticMeasurement()
    var painted by remember { mutableStateOf<FloatTextGeometry?>(null) }
    DisposableEffect(sink) { onDispose { sink(null) } }
    androidx.compose.ui.layout.Layout(modifier = semantic.modifier.then(input.modifier), content = {
        Canvas(Modifier) { painted?.paintOrdinary(drawContext.canvas.nativeCanvas) }
    }, measurePolicy = object : MeasurePolicy {
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic.minimum
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic.maximum
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semantic.measure {
            try {
                val allocation = input.value ?: throw UnsupportedFloatLayout("Figure block width is unavailable")
                val geometry = build(allocation)
                if (!constraints.hasBoundedWidth || geometry.width != constraints.maxWidth || geometry.height > constraints.maxHeight)
                    throw UnsupportedFloatLayout("Figure block exceeds its actual child constraints")
                val packed = try { Constraints.fixed(geometry.width, geometry.height) }
                    catch (_: IllegalArgumentException) { throw UnsupportedFloatLayout("Figure block exceeds Compose measurement range") }
                val frame = measurables.single().measure(packed)
                painted = geometry
                sink(geometry)
                layout(geometry.width, geometry.height) { frame.place(0, 0) }
            } catch (_: UnsupportedFloatLayout) {
                painted = null
                unavailableSelection(constraints, sink)
            }
        }
    })
}
