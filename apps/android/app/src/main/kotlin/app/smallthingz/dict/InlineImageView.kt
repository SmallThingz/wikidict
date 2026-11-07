package app.smallthingz.dict

import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontSynthesis
import androidx.compose.ui.text.font.FontWeight
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.floor

internal const val InlineImageReplacement = "\ufffc"
internal data class InlineImagePixels(val width: Float, val height: Float)
internal data class InlineImageFontMetrics(val ascent: Int, val descent: Int, val xHeight: Float, val baselineShift: Int)

/** The authored image size excludes its one-logical-pixel outside border. */
internal fun inlineImageOuterPixels(content: InlineImagePixels, bordered: Boolean, density: Float): InlineImagePixels {
    require(density.isFinite() && density > 0f && content.width.isFinite() && content.width > 0f &&
        content.height.isFinite() && content.height > 0f)
    if (!bordered) return content
    return InlineImagePixels(content.width + 2f * density, content.height + 2f * density).also {
        require(it.width.isFinite() && it.height.isFinite())
    }
}

/** MediaWiki's client dimensions use positive half-away rounding. The physical
 * 960px cache thumbnail is not the original SVG's natural size. */
internal fun inlineImagePixels(image: InlineImage, intrinsicWidth: Long, intrinsicHeight: Long, density: Float,
    originalMime: String? = null): InlineImagePixels? {
    require(intrinsicWidth > 0 && intrinsicHeight > 0 && density.isFinite() && density > 0f)
    val mime = originalMime?.substringBefore(';')?.trim()?.lowercase()
    val heightOnly = image.widthPx == null && image.heightPx != null
    if (heightOnly && mime?.startsWith("image/") != true) return null
    val vectorHeightOnly = heightOnly && mime == "image/svg+xml"
    fun rounded(value: Double) = floor(value + 0.5)
    val requestedWidth = image.widthPx?.toDouble() ?: intrinsicWidth.toDouble()
    val requestedHeight = image.heightPx?.toDouble()
    val cssWidth: Double
    val cssHeight: Double
    // Height-only SVGs are not limited by their natural width. Use original
    // dimensions, never the dimensions of the cached raster thumbnail.
    if (requestedHeight != null && (vectorHeightOnly || requestedWidth * intrinsicHeight > requestedHeight * intrinsicWidth)) {
        val ideal = intrinsicWidth.toDouble() * requestedHeight / intrinsicHeight
        val up = ceil(ideal)
        cssWidth = (if (rounded(up * intrinsicHeight / intrinsicWidth) > requestedHeight) floor(ideal) else up).coerceAtLeast(1.0)
        cssHeight = requestedHeight
    } else {
        cssWidth = requestedWidth
        cssHeight = rounded(intrinsicHeight.toDouble() * cssWidth / intrinsicWidth).coerceAtLeast(1.0)
    }
    val w = cssWidth * density
    val h = cssHeight * density
    val projection = min(1.0, MaxComputedFontPixels / max(w, h))
    return InlineImagePixels((w * projection).toFloat(), (h * projection).toFloat())
}
internal fun inlineImageInkTop(metrics: InlineImageFontMetrics, height: Float): Float =
    metrics.baselineShift - (metrics.xHeight + height) / 2f
internal fun inlineImageReservedHeight(metrics: InlineImageFontMetrics, height: Float): Float {
    val center = (metrics.ascent.toDouble() + metrics.descent) / 2.0
    val top = inlineImageInkTop(metrics, height).toDouble()
    return (ceil(2.0 * max(center - top, top + height - center)) + 2.0).toFloat().coerceAtLeast(1f)
}
internal fun inlineImageDrawTop(metrics: InlineImageFontMetrics, inkHeight: Float, actualBoxHeight: Int): Float {
    // Same integer TextCenter inverse used by the existing Egyptian renderer.
    val baseline = -((metrics.ascent.toLong() + metrics.descent - actualBoxHeight) / 2L).toFloat()
    return baseline + inlineImageInkTop(metrics, inkHeight)
}

internal sealed interface InlineImageAssetState {
    data object Disabled : InlineImageAssetState
    data object Loading : InlineImageAssetState
    data object Failed : InlineImageAssetState
    data class Ready(val decoded: DecodedMediaBitmap, val originalWidth: Long, val originalHeight: Long,
        val mime: String?, val source: String, val credit: String) : InlineImageAssetState
    data class GeometryUnavailable(val resource: Ready) : InlineImageAssetState
}
internal fun inlineImageFallbackText(image: InlineImage, state: InlineImageAssetState): String? =
    image.alt?.takeIf { it.isNotEmpty() && state !is InlineImageAssetState.Ready }
// Reuse the one existing cache, including its ephemeral-file cleanup. Tests can
// supply that same controlled cache rather than a second asset implementation.
internal val LocalInlineImageCache = staticCompositionLocalOf<MediaCache?> { null }
internal val LocalInlineImageOwner = staticCompositionLocalOf<InlineImageViewOwner?> { null }

internal class InlineImageViewOwner(
    private val media: Map<String, Media>, private val settings: AppSettings, private val edition: String,
    private val cache: MediaCache, private val scope: CoroutineScope, private val occurrences: Map<String, List<InlineImage>>,
    private val density: Float, private val catalogueFiles: Set<String>,
) {
    val states = mutableStateMapOf<String, InlineImageAssetState>()
    private val jobs = mutableMapOf<String, Job>()
    private val requests = mutableMapOf<String, Any>()
    fun owns(file: String): Boolean = occurrences.containsKey(file)
    fun ensure(file: String) {
        if (states.containsKey(file)) return
        start(file, false)
    }
    fun retry(file: String) {
        jobs.remove(file)?.cancel()
        start(file, true)
    }
    private fun start(file: String, forceRefresh: Boolean) {
        if (!settings.allowImages) { states[file] = InlineImageAssetState.Disabled; return }
        val request = Any(); requests[file] = request
        states[file] = InlineImageAssetState.Loading
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                cache.withFile(media.getValue(file), settings.mediaCacheMb, edition, forceRefresh = forceRefresh, canonicalFile = true) { resource ->
                    val width = requireNotNull(resource.originalWidth) { "Image intrinsic width is unavailable" }
                    val height = requireNotNull(resource.originalHeight) { "Image intrinsic height is unavailable" }
                    val target = if (file in catalogueFiles) 1600 else occurrences.getValue(file).mapNotNull { image ->
                        inlineImagePixels(image, width, height, density, resource.originalMime)
                    }.maxOfOrNull { max(it.width, it.height) }?.let { ceil(it).coerceIn(1f, 1600f).toInt() } ?: 1600
                    val decoded = decodeMediaBitmap(resource.file, target)
                    if (requests[file] === request) states[file] = InlineImageAssetState.Ready(decoded, width, height, resource.originalMime, resource.source, resource.credit)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (requests[file] === request) states[file] = InlineImageAssetState.Failed }
            finally { if (jobs[file] === coroutineContext[Job]) jobs.remove(file) }
        }
        jobs[file] = job
        job.start()
    }
    fun close() {
        requests.clear()
        jobs.values.toList().forEach { it.cancel() }
        jobs.clear(); states.clear()
    }
}

@Composable
internal fun rememberInlineImageViewOwner(images: List<InlineImage>, media: List<Media>, settings: AppSettings,
    edition: String, catalogueFiles: Set<String> = emptySet()): InlineImageViewOwner {
    val density = LocalDensity.current.density
    val cache = LocalInlineImageCache.current ?: MediaCache.get(LocalContext.current)
    val scope = rememberCoroutineScope()
    val owner = remember(images, media, settings.allowImages, settings.mediaCacheMb, edition, density, cache, scope, catalogueFiles) {
        InlineImageViewOwner(media.associateBy { it.file }, settings, edition, cache, scope, images.groupBy { it.file }, density, catalogueFiles)
    }
    DisposableEffect(owner) { onDispose { owner.close() } }
    return owner
}

@Composable
internal fun compiledInlineImageContent(spans: List<Span>, annotated: AnnotatedString, style: TextStyle,
    media: List<Media>, settings: AppSettings, edition: String, onLink: (EntryLink) -> Unit,
    placeholderColor: Color): Map<String, InlineTextContent> {
    val density = LocalDensity.current
    val resolver = LocalFontFamilyResolver.current
    val textMeasurer = rememberTextMeasurer()
    val fallbackWidth = LocalWindowInfo.current.containerSize.width.coerceIn(1, MaxComputedFontPixels.toInt())
    val effective = LocalTextStyle.current.merge(style)
    require(effective.fontSize.isSp)
    val baseSize = with(density) { effective.fontSize.toPx() }
    val owner = LocalInlineImageOwner.current ?: rememberInlineImageViewOwner(spans.mapNotNull { it.image }, media, settings, edition)
    val files = spans.mapNotNull { it.image?.file }.distinct()
    files.forEach { file -> LaunchedEffect(owner, file) { owner.ensure(file) } }
    val result = linkedMapOf<String, InlineTextContent>()
    var offset = 0
    spans.forEachIndexed { index, span ->
        if (span.direction in listOf("rtl", "ltr", "auto")) offset++
        val image = span.image
        if (image != null) key(index, image) {
            val start = offset
            val spanStyle = annotated.spanStyles.filter { it.start <= start && it.end >= start + 1 }
                .fold(effective.toSpanStyle()) { merged, range -> merged.merge(range.item) }
            val face by resolver.resolve(spanStyle.fontFamily ?: FontFamily.Default,
                spanStyle.fontWeight ?: FontWeight.Normal, spanStyle.fontStyle ?: FontStyle.Normal,
                spanStyle.fontSynthesis ?: FontSynthesis.All)
            val textSize = when {
                spanStyle.fontSize.isSp -> with(density) { spanStyle.fontSize.toPx() }
                spanStyle.fontSize.isEm -> (baseSize.toDouble() * spanStyle.fontSize.value).coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat()
                else -> baseSize
            }
            val metrics = remember(face, textSize, spanStyle.baselineShift) {
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = face as Typeface; this.textSize = textSize }
                val font = paint.fontMetricsInt
                val bounds = Rect(); paint.getTextBounds("x", 0, 1, bounds)
                InlineImageFontMetrics(font.ascent, font.descent, bounds.height().toFloat(),
                    ceil(paint.ascent() * (spanStyle.baselineShift?.multiplier ?: 0f)).toInt())
            }
            val state = owner.states[image.file] ?: if (settings.allowImages) InlineImageAssetState.Loading else InlineImageAssetState.Disabled
            val ready = state as? InlineImageAssetState.Ready
            val geometry = ready?.let { inlineImagePixels(image, it.originalWidth, it.originalHeight, density.density, it.mime) }
            val occurrenceState = if (ready != null && geometry == null) InlineImageAssetState.GeometryUnavailable(ready) else state
            val fallback = inlineImageFallbackText(image, occurrenceState)
            val fallbackStyle = effective.copy(color = spanStyle.color,
                fontSize = if (textSize > 0f) with(density) { textSize.toSp() } else effective.fontSize,
                fontFamily = spanStyle.fontFamily, fontWeight = spanStyle.fontWeight, fontStyle = spanStyle.fontStyle,
                fontSynthesis = spanStyle.fontSynthesis, fontFeatureSettings = spanStyle.fontFeatureSettings,
                letterSpacing = spanStyle.letterSpacing, baselineShift = spanStyle.baselineShift,
                textGeometricTransform = spanStyle.textGeometricTransform, localeList = spanStyle.localeList,
                background = spanStyle.background, textDecoration = spanStyle.textDecoration,
                shadow = spanStyle.shadow, drawStyle = spanStyle.drawStyle).let { merged ->
                    spanStyle.brush?.let { brush -> merged.copy(brush = brush, alpha = spanStyle.alpha) } ?: merged
                }
            val fallbackLayout = fallback?.let { textMeasurer.measure(AnnotatedString(it), style = fallbackStyle,
                overflow = TextOverflow.Ellipsis, constraints = Constraints(maxWidth = fallbackWidth,
                    maxHeight = MaxComputedFontPixels.toInt())) }
            val pixels = fallbackLayout?.let { InlineImagePixels(it.size.width.coerceAtLeast(1).toFloat(),
                it.size.height.coerceAtLeast(1).toFloat()) } ?: geometry ?: run {
                    // A status marker has no claimed intrinsic image aspect ratio.
                    // The actual asset is not painted until its passive size is known.
                    val axis = image.widthPx ?: image.heightPx
                    val side = axis?.let { (it.toDouble() * density.density).coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat() }
                        ?: baseSize.coerceAtLeast(1f)
                    InlineImagePixels(side, side)
                }
            val outer = inlineImageOuterPixels(pixels, image.border, density.density)
            val reserved = inlineImageReservedHeight(metrics, outer.height)
            result["compiled-image-$index"] = InlineTextContent(Placeholder(with(density) { outer.width.toSp() },
                with(density) { reserved.toSp() }, PlaceholderVerticalAlign.TextCenter)) {
                InlineImageOccurrence(span, pixels, metrics, occurrenceState, fallback, fallbackStyle, edition, onLink, placeholderColor) {
                    owner.retry(image.file)
                }
            }
        }
        if (image != null) offset += InlineImageReplacement.length
        offset += (if (span.kind == "line_break") 1 else span.text.length) + span.trail.length
        if (span.direction in listOf("rtl", "ltr", "auto")) offset++
    }
    return result
}

@Composable
private fun InlineImageOccurrence(span: Span, pixels: InlineImagePixels, metrics: InlineImageFontMetrics,
    state: InlineImageAssetState, fallback: String?, fallbackStyle: TextStyle,
    edition: String, onLink: (EntryLink) -> Unit, placeholderColor: Color, retry: () -> Unit) {
    val image = checkNotNull(span.image)
    val density = LocalDensity.current.density
    val borderWidth = if (image.border) density else 0f
    val outer = inlineImageOuterPixels(pixels, image.border, density)
    val ready = when (state) { is InlineImageAssetState.Ready -> state; is InlineImageAssetState.GeometryUnavailable -> state.resource; else -> null }
    val uri = LocalUriHandler.current
    var menu by remember { mutableStateOf(false) }
    val actionUrl = remember(span.kind, span.target, span.targetFragment, edition) { inlineImageLinkUrl(span, edition) }
    val unresolvedSource = span.kind == "link" && span.target.startsWith("File:") && actionUrl == null
    val click: (() -> Unit)? = when {
        actionUrl != null -> { { uri.openUri(actionUrl) } }
        span.kind == "link" && !unresolvedSource -> { { onLink(span.entryLink()) } }
        else -> null
    }
    val hasMenu = !image.tooltip.isNullOrEmpty() || ready != null || state == InlineImageAssetState.Failed
    val input = if (click != null) Modifier.combinedClickable(role = Role.Image, onClickLabel = "Open image link",
        onClick = click, onLongClick = if (hasMenu) ({ menu = true }) else null)
        else if (hasMenu) Modifier.combinedClickable(role = Role.Image, onClickLabel = "Image details",
            onClick = { menu = true }, onLongClick = { menu = true }) else Modifier
    Box(Modifier.fillMaxSize().then(input).semantics {
        role = Role.Image
        image.alt?.let { contentDescription = it }
        if (hasMenu) onLongClick(label = "Image details") { menu = true; true }
        stateDescription = (when (state) {
            InlineImageAssetState.Disabled -> "Images disabled"
            InlineImageAssetState.Loading -> "Loading image"
            InlineImageAssetState.Failed -> "Image unavailable"
            is InlineImageAssetState.GeometryUnavailable -> "Image geometry unavailable"
            is InlineImageAssetState.Ready -> ""
        }) + if (unresolvedSource) " Image link source unavailable" else ""
    }, contentAlignment = Alignment.Center) {
        if (fallback == null || image.border) Canvas(Modifier.fillMaxSize()) {
            drawIntoCanvas { target ->
                val canvas = target.nativeCanvas
                val top = if (fallback != null) (size.height - outer.height) / 2f
                    else inlineImageDrawTop(metrics, outer.height, size.height.toInt())
                val bounds = RectF(borderWidth, top + borderWidth, borderWidth + pixels.width,
                    top + borderWidth + pixels.height)
                val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
                if (fallback == null && state is InlineImageAssetState.Ready) canvas.drawBitmap(state.decoded.bitmap, null, bounds, paint)
                else if (fallback == null) {
                    paint.color = placeholderColor.toArgb(); paint.style = Paint.Style.STROKE; paint.strokeWidth = 1f
                    canvas.drawRect(bounds, paint)
                    canvas.drawLine(bounds.left, bounds.top, bounds.right, bounds.bottom, paint)
                }
                if (image.border) {
                    paint.color = 0xffeaecf0.toInt(); paint.style = Paint.Style.STROKE; paint.strokeWidth = borderWidth
                    val half = borderWidth / 2f
                    canvas.drawRect(RectF(half, top + half, outer.width - half, top + outer.height - half), paint)
                }
            }
        }
        if (fallback != null) Text(fallback, style = fallbackStyle, overflow = TextOverflow.Ellipsis,
            modifier = if (image.border) with(LocalDensity.current) {
                Modifier.requiredSize(pixels.width.toDp(), pixels.height.toDp())
            } else Modifier)
        DropdownMenu(menu, { menu = false }) {
            if (state is InlineImageAssetState.GeometryUnavailable) DropdownMenuItem(text = { Text("Image size unavailable") }, enabled = false, onClick = {})
            image.tooltip?.takeIf { it.isNotEmpty() }?.let { tooltip ->
                DropdownMenuItem(text = { Text(tooltip) }, enabled = false, onClick = {})
            }
            if (state == InlineImageAssetState.Failed || state is InlineImageAssetState.GeometryUnavailable)
                DropdownMenuItem(text = { Text("Retry image") }, onClick = { menu = false; retry() })
            ready?.let { loaded ->
                loaded.credit.takeIf { it.isNotEmpty() }?.let { credit -> DropdownMenuItem(text = { Text(credit) }, enabled = false, onClick = {}) }
                DropdownMenuItem(text = { Text("Source and licence") }, onClick = { menu = false; uri.openUri(loaded.source) })
            }
        }
    }
}
