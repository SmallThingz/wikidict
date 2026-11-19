package app.smallthingz.dict

import android.text.Layout
import android.text.TextDirectionHeuristic
import android.text.TextPaint

/** All em lengths are already resolved against the actual declaring font. */
internal data class NativeInlineAtomicAutoBoxFormat(
    val maxWidth: Float,
    val margins: NativeInlineBoxEdges,
    val boxSizing: ContainerBoxSizing,
    val textAlign: InlineBoxOverlayTextAlign,
    val wrap: TextWrap,
    val intrinsicWrap: InlineBoxIntrinsicWrap,
    val lineHeight: NativeLineHeightPolicy,
)

/** Intrinsic compilation has no containing block and must not invent one. */
internal enum class NativeRubyIntrinsicWidth { Minimum, Maximum }

/** One immutable child compiler result and intrinsic measurement per original owner
 * and resolved direction. Keep only the two named intrinsic shapes and latest layout;
 * repeated resizes cannot accumulate a history of child paragraphs. */
internal class NativeInlineAtomicAutoChild(
    private val compiled: NativeRubyLayout,
    paint: TextPaint,
    private val direction: TextDirectionHeuristic,
    private val alignment: Layout.Alignment,
    intrinsicWrap: InlineBoxIntrinsicWrap,
) {
    private val paint = TextPaint(paint)
    val intrinsic = nativeFloatRowIntrinsicWidths(compiled.native, this.paint, direction,
        breakWordMinimum = false, intrinsicWrap = intrinsicWrap)
    private val intrinsicShapes = mutableMapOf<NativeRubyIntrinsicWidth, Pair<Float, NativeFloatGeometry>>()
    private var layoutShape: Pair<Float, NativeFloatGeometry>? = null

    fun geometry(contentWidth: Float, purpose: NativeRubyIntrinsicWidth?): NativeFloatGeometry {
        val cached = (if (purpose == null) layoutShape else intrinsicShapes[purpose])
            ?.takeIf { it.first == contentWidth }?.second
            ?: layoutShape?.takeIf { it.first == contentWidth }?.second
            ?: intrinsicShapes.values.firstOrNull { it.first == contentWidth }?.second
        val geometry = cached ?: NativeFloatGeometry.build(compiled.native, paint,
            kotlin.math.floor(contentWidth).toInt(), emptyList(), alignment = alignment,
            textDirection = direction, includeFontPadding = false, exactAvailableWidth = contentWidth)
            .withRubyProjection(compiled)
        if (purpose == null) layoutShape = contentWidth to geometry
        else intrinsicShapes[purpose] = contentWidth to geometry
        return geometry
    }
}
