package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.content.Context
import android.graphics.Typeface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.AndroidFont
import androidx.compose.ui.text.font.DeviceFontFamilyName
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontLoadingStrategy
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import kotlinx.coroutines.CancellationException

internal const val NativeNamedFamilyUnavailable = "A loaded named font family requires a native fallback chain."
internal const val NativeNamedFamilyProbeUnavailable = "Named font availability is unavailable."
internal const val NativeSectionHeadingLanguageUnavailable = "Section heading language is unavailable for this layout."

/** OptionalLocal's nullable loader is the presence test; Resolver.resolve would hide absence. */
internal fun interface NativeNamedFontProbe {
    fun load(context: Context, name: String, weight: FontWeight, style: FontStyle): Typeface?
}

private object AndroidNamedFontProbe : NativeNamedFontProbe {
    override fun load(context: Context, name: String, weight: FontWeight, style: FontStyle): Typeface? {
        val font = Font(DeviceFontFamilyName(name), weight, style) as? AndroidFont
            ?: throw UnsupportedFloatLayout(NativeNamedFamilyProbeUnavailable)
        if (font.loadingStrategy != FontLoadingStrategy.OptionalLocal)
            throw UnsupportedFloatLayout(NativeNamedFamilyProbeUnavailable)
        return font.typefaceLoader.loadBlocking(context, font)
    }
}

internal val LocalNativeNamedFontProbe = staticCompositionLocalOf<NativeNamedFontProbe> { AndroidNamedFontProbe }

/** Only a terminal generic is executable until an ordered native named fallback chain exists. */
internal fun nativeTerminalFontFamily(family: ContainerFontFamily): FontFamily = when (family) {
    ContainerFontFamily.SansSerif -> FontFamily.SansSerif
    is ContainerFontFamily.Stack -> when (family.fallback) {
        GenericFontFamily.SansSerif -> FontFamily.SansSerif
        GenericFontFamily.Serif -> FontFamily.Serif
    }
}

internal fun nativeContainerFontAdmission(family: ContainerFontFamily?, weight: FontWeight, style: FontStyle,
    available: (String, FontWeight, FontStyle) -> Boolean): Result<FontFamily?> = try {
    if (family is ContainerFontFamily.Stack) family.names.forEach { name ->
        if (available(name, weight, style)) throw UnsupportedFloatLayout(NativeNamedFamilyUnavailable)
    }
    Result.success(family?.let(::nativeTerminalFontFamily))
} catch (error: CancellationException) {
    throw error
} catch (error: Exception) {
    Result.failure(if (error is UnsupportedFloatLayout) error else UnsupportedFloatLayout(NativeNamedFamilyProbeUnavailable))
}

@Composable
internal fun nativeContainerFontAdmission(family: ContainerFontFamily?, weight: FontWeight,
    style: FontStyle): Result<FontFamily?> {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val probe = LocalNativeNamedFontProbe.current
    return remember(family, weight, style, context, configuration, probe) {
        nativeContainerFontAdmission(family, weight, style) { name, requestedWeight, requestedStyle ->
            probe.load(context, name, requestedWeight, requestedStyle) != null
        }
    }
}

/** The exact owner tuple replaces UI heading presets. Box em lengths keep the normal-body basis. */
@Composable
internal fun nativeSectionHeadingTextFormat(heading: SectionHeadingStyle, normalBodySize: TextUnit,
    inheritedStyle: TextStyle, density: Density): Result<NativeContainerTextFormat> {
    val weight = if (heading.font.bold) FontWeight.Bold else FontWeight.Normal
    val fontStyle = if (heading.font.italic) FontStyle.Italic else FontStyle.Normal
    val family = nativeContainerFontAdmission(heading.box.fontFamily, weight, fontStyle)
    return try {
        val language = heading.font.language?.let(::nativeTableOwnerLanguageTag)
            ?: throw UnsupportedFloatLayout(NativeSectionHeadingLanguageUnavailable)
        val ownerStyle = inheritedStyle.copy(fontWeight = weight, fontStyle = fontStyle,
            fontFamily = family.getOrThrow(), localeList = LocaleList(Locale(language)),
            textDirection = if (heading.direction == BidiResolvedDirection.Rtl) TextDirection.Rtl else TextDirection.Ltr,
            baselineShift = BaselineShift.None, fontFeatureSettings = heading.font.fontFeatures?.nativeSettings)
        Result.success(nativeContainerTextFormat(heading.box.textContext(ContainerTextContext()),
            normalBodySize, ownerStyle, density))
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        Result.failure(if (error is UnsupportedFloatLayout) error else UnsupportedFloatLayout("Section heading font geometry is unavailable."))
    }
}

/** One original child and one existing border-box solver; source heading flow-root is explicit. */
internal data class NativeSectionHeadingAllocation(val minimumWidth: Float,
    val horizontal: (Float) -> NativeContainerHorizontal)

internal fun nativeSectionHeadingSpec(id: Int, heading: SectionHeadingStyle, child: NativeFloatContextSpec.Text,
    density: Float, normalBodyFont: Float, dark: Boolean,
    wrapperId: ((String) -> Int)? = null): NativeFloatContextSpec.Container {
    val frames = heading.wrappers
    if (frames == null) return nativeHeadingFlowRoot(id, heading, child, density, normalBodyFont, dark)
    val ids = checkNotNull(wrapperId)
    val right = paragraphLengthPixels(frames.titlePaddingRight, density, normalBodyFont * checkNotNull(heading.box.ownerFontScale))
    val top = paragraphLengthPixels(frames.innerPaddingTop, density, normalBodyFont)
    val titleBox = checkNotNull(child.box)
    val title = child.copy(box = titleBox.copy(padding = titleBox.padding.copy(right = right)), headingFramePaddingAbove = top)
    val flowRoot = nativeHeadingFlowRoot(id, heading, title, density, normalBodyFont, dark)
    val zero = StyleLength(StyleLengthUnit.Px, 0f)
    fun frame(name: String, box: ContainerStyle, content: NativeFloatContextSpec.Container) =
        nativeContainerSpec(ids(name), box.atViewport(0.0), listOf(content), density, normalBodyFont,
            heading.direction == BidiResolvedDirection.Rtl, dark, false)
    val inner = frame("inner", ContainerStyle(padding = StyleEdges(frames.innerPaddingTop, zero, zero, zero)), flowRoot)
    val border = ContainerBorder.Edges(ContainerBorderEdge.Solid(frames.outerTopWidth, frames.outerTopColor),
        ContainerBorderEdge.None, ContainerBorderEdge.None, ContainerBorderEdge.None)
    val outer = frame("outer", ContainerStyle(margins = SignedContainerEdges(frames.outerMarginTop, zero, zero, zero),
        border = border), inner)
    // Border-box measurement is shared with solid edges. Only its native stroke pattern differs.
    val stroke = outer.decoration ?: return outer
    return outer.copy(decoration = stroke.copy(edges = stroke.edges!!.mapIndexed { index, edge -> edge.copy(dashed = index == 0) }))
}

private fun nativeHeadingFlowRoot(id: Int, heading: SectionHeadingStyle, child: NativeFloatContextSpec.Text,
    density: Float, normalBodyFont: Float, dark: Boolean): NativeFloatContextSpec.Container {
    // The closed heading box has no responsive rules; its projection is width-independent.
    val resolved = heading.box.atViewport(0.0)
    val prepared = nativeContainerSpec(id, resolved, listOf(child), density,
        normalBodyFont, heading.direction == BidiResolvedDirection.Rtl, dark, false)
    if (prepared.unavailableReason != null) return prepared.copy(isolatesFloats = true)
    return try {
        val edges = prepared.padding(0)
        val margins = prepared.margins(0)
        val minimum = maxOf(0.0, edges.left.toDouble() + edges.right + margins.left + margins.right)
        if (!minimum.isFinite() || minimum > TablePixelLimit)
            throw UnsupportedFloatLayout("Section heading edges exceed native geometry.")
        // Round the minimum upward only when Float storage would otherwise admit a band
        // narrower than the fixed edges. The actual interval and solved origin stay Float.
        val minimumFloat = minimum.toFloat().let { if (it.toDouble() < minimum) java.lang.Math.nextUp(it) else it }
        val allocation = NativeSectionHeadingAllocation(minimumFloat) { available ->
            if (!available.isFinite() || available < 0f || available.toDouble() < minimum)
                throw UnsupportedFloatLayout("An overconstrained heading box requires its containing direction.")
            val box = containerBoxWidth(resolved, available, ContainerWidths(0f, 0f), density, normalBodyFont)
            NativeContainerHorizontal.from(box, edges.left, margins.left, margins.right)
        }
        prepared.copy(isolatesFloats = true, headingAllocation = allocation,
            contentWidth = { width, _ -> kotlin.math.floor(allocation.horizontal(width.toFloat()).content).toInt() },
            horizontal = { width, _ -> allocation.horizontal(width.toFloat()) })
    } catch (failure: UnsupportedFloatLayout) {
        prepared.copy(isolatesFloats = true, unavailableReason = failure.message)
    }
}

/** The closed frame ends at the title line box. Its inner padding extends only the top clip.
 * The horizontal envelope includes all signed paint, selection and input extents of the leaf. */
internal class NativeHeadingFrameText(private val source: NativeFloatGeometry, paddingAbove: Float) : FloatTextGeometry by source {
    private val top = -paddingAbove
    private val bottom = source.textBottom
    private val horizontal = listOfNotNull(source.extents.ink, source.extents.interaction, source.scrollableBounds)
    private val clip = RectF(minOf(0f, horizontal.minOf { it.left }), top,
        maxOf(source.width.toFloat(), horizontal.maxOf { it.right }), bottom)
    init {
        if (source.positionedGroups.isNotEmpty() || source.hasPreciseClips)
            throw UnsupportedFloatLayout("Wrapped section heading contains nested positioned or clipped inline content")
    }
    private fun visible(rect: RectF) = RectF(rect).takeIf { it.intersect(clip) }
    private fun visible(bounds: NativeFloatBounds?) = bounds?.let {
        val y1 = maxOf(top, it.top)
        val y2 = minOf(bottom, it.bottom)
        if (y1 >= y2) null else NativeFloatBounds(it.left, y1, it.right, y2)
    }
    val scrollableBounds = visible(source.scrollableBounds) ?: NativeFloatBounds(0f, 0f, 0f, 0f)
    override val extents = source.extents.copy(ink = visible(source.extents.ink), interaction = visible(source.extents.interaction))
    override val ordinaryPaintBounds = source.ordinaryPaintBounds.mapNotNull { visible(it) }
    override val nodes = source.nodes.map { node -> node.copy(bounds = node.bounds.mapNotNull { visible(it) },
        clipBounds = node.clipBounds?.let { visible(it) ?: RectF() } ?: RectF(clip)) }
    private fun clipFor(rect: RectF?) = rect?.let { visible(it) ?: RectF() } ?: RectF(clip)
    override fun clipForOffset(offset: Int) = clipFor(source.clipForOffset(offset))
    override fun clipForOffset(caret: NativeTextCaret) = clipFor(source.clipForOffset(caret))
    override fun rectsForRange(start: Int, end: Int) = source.rectsForRange(start, end).mapNotNull { visible(it) }
    override fun characterRects(start: Int, length: Int) = source.characterRects(start, length).map { it?.let(::visible) }
    override fun containsInput(x: Float, y: Float) = y >= top && y < bottom && source.containsInput(x, y)
    override fun containsInteraction(x: Float, y: Float) = y >= top && y < bottom && source.containsInteraction(x, y)
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? {
        if (y < top || y >= bottom) return null
        val selected = source.interactionNodeAt(x, y) ?: return null
        return nodes.firstOrNull { it.id == selected.id && it.contains(x, y) }
    }
    override fun cursorAt(x: Float, y: Float) = if (y < top || y >= bottom) null else source.cursorAt(x, y)
    private inline fun clipped(canvas: Canvas, draw: () -> Unit) {
        val save = canvas.save()
        try { canvas.clipRect(clip); draw() } finally { canvas.restoreToCount(save) }
    }
    override fun paint(canvas: Canvas) = clipped(canvas) { source.paint(canvas) }
    override fun paintOrdinary(canvas: Canvas) = clipped(canvas) { source.paintOrdinary(canvas) }
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) =
        clipped(canvas) { source.paintSelection(canvas, start, end, paint) }
}

/** Resource-backed custom action IDs cannot collide with Android's standard action bitmask. */
internal fun nativeHeadingCustomActionId(index: Int): Int = NativeHeadingCustomActionIds[index]
internal val NativeHeadingCustomActionIds = intArrayOf(
    R.id.section_heading_fold,
    R.id.section_heading_details,
)
