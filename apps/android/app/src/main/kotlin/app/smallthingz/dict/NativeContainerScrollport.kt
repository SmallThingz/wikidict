package app.smallthingz.dict

import android.graphics.RectF
import android.view.View
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.Constraints
import kotlin.math.ceil
import kotlin.math.floor

/** This is a reader capability restriction; stored Auto and its old wire bytes are unchanged. */
internal fun nativeScrollportUnavailable(style: ContainerStyle, flexItem: Boolean = false): String? {
    if (style.overflow != ContainerOverflow.Auto) return null
    val margins = style.marginValues
    val numeric = style.margins?.let { listOf(it.top, it.right, it.bottom, it.left) }.orEmpty()
    return when {
        style.height != null || style.minHeight != null -> "Automatic scrollports require automatic block height"
        flexItem || style.flexItem != null || style.layout == ContainerLayout.FlexRow -> "Automatic scrollports in flex layout are unavailable"
        style.columns != null || style.positioning != null || style.floatSide != null -> "This scrollport formatting combination is unavailable"
        style.screenMaxWidth != null -> "Responsive scrollport overrides are unavailable"
        style.width != null && style.width != ContainerWidth.Auto -> "Automatic scrollports require automatic width"
        (style.maxWidth as? ContainerMaxWidth.Length)?.value?.unit == StyleWidthUnit.Percent -> "Percentage scrollport maximum width is unavailable"
        margins != null -> "Base margin values on scrollports are unavailable"
        numeric.any { it.value < 0f } -> "Negative external scrollport margins are unavailable"
        else -> null
    }
}

internal data class NativeScrollportSpec(val parts: List<NativeFloatContextSpec>, val padding: FloatMargins)

/** Layout overflow, not glyph ink, determines the range. The first domain has no local y axis. */
internal data class NativeScrollportAllocation(val viewport: Int, val content: Int, val height: Int,
    val originX: Float, val originY: Float, val verticalOverflow: Boolean, val leadingOverflow: Boolean) {
    val range: Int get() = content - viewport
}
internal fun nativeScrollportAllocation(viewport: Int, usedHeight: Float, layout: NativeFloatBounds,
    padding: FloatMargins): NativeScrollportAllocation {
    require(viewport in 0..TablePixelLimit && usedHeight.isFinite() && usedHeight >= 0f)
    val left = minOf(0f, layout.left)
    val right = maxOf((viewport - padding.left - padding.right).coerceAtLeast(0f), layout.right)
    val top = minOf(0f, layout.top)
    val bottom = maxOf(usedHeight, layout.bottom)
    val width = ceil(right - left + padding.left + padding.right).toDouble()
    val height = ceil(bottom - top + padding.top + padding.bottom).toDouble()
    if (width > TablePixelLimit || height > TablePixelLimit)
        throw UnsupportedFloatLayout("Scrollport extent exceeds native geometry")
    return NativeScrollportAllocation(viewport, maxOf(viewport, width.toInt()), height.toInt(),
        padding.left - left, padding.top - top,
        top < -.01f || bottom > usedHeight + .01f, left < -.01f)
}

/** A viewport belongs to its real Compose owner. Native virtual descendants intersect the same
 * screen clip, including nested owners, instead of assuming the Android host window is the clip. */
internal class NativeScrollClip(private val parent: NativeScrollClip?) {
    private var screen: RectF? = null
    fun update(bounds: Rect, view: View) {
        val window = IntArray(2); val global = IntArray(2)
        view.getLocationInWindow(window); view.getLocationOnScreen(global)
        screen = RectF(bounds.left + global[0] - window[0], bounds.top + global[1] - window[1],
            bounds.right + global[0] - window[0], bounds.bottom + global[1] - window[1])
    }
    fun inScreen(): RectF {
        val result = screen?.let(::RectF) ?: return RectF()
        parent?.inScreen()?.let { if (!result.intersect(it)) result.setEmpty() }
        return result
    }
    fun inView(view: View): RectF = inScreen().apply {
        val at = IntArray(2); view.getLocationOnScreen(at); offset(-at[0].toFloat(), -at[1].toFloat())
    }
}
internal val LocalNativeScrollClip = staticCompositionLocalOf<NativeScrollClip?> { null }
internal val LocalNativeContainerScrollport = staticCompositionLocalOf { false }

/** One delegated child owns the complete original prepared graph. Its Tables yield their own
 * scrollers; the existing native selection owners keep their original text and action identities. */
@Composable
internal fun NativeContainerScrollport(spec: NativeScrollportSpec, linkColor: Color,
    parentMeasureInput: NativeLayoutInput<Unit>,
    child: @Composable (Int, NativeLayoutInput<Int>) -> Unit) {
    val scroll = rememberScrollState()
    val parentClip = LocalNativeScrollClip.current
    val clip = remember(parentClip) { NativeScrollClip(parentClip) }
    val view = LocalView.current
    val message = remember { NativeLayoutInput<String?>(null) }
    val viewportMeasureInput = remember { NativeLayoutInput(Unit) }
    val ancestor = LocalNativeSemanticMeasurement.current
    val input = remember(ancestor, parentMeasureInput) { NativeContextMeasureInput(ancestor) {
        viewportMeasureInput.invalidate()
        parentMeasureInput.invalidate()
    } }
    val density = LocalDensity.current
    val environment = NativeFlowEnvironment(density.density, density.fontScale,
        LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
    val composition = Any()
    val request = LocalCellHeadingRequest.current
    val reached = LocalCellHeadingReached.current
    fun leaves(parts: List<NativeFloatContextSpec>): List<NativeFloatContextSpec> = parts.flatMap {
        (it as? NativeFloatContextSpec.Container)?.preparedParts?.let(::leaves) ?: listOf(it)
    }
    val revealIndex = leaves(spec.parts).indexOfFirst { when (it) {
        is NativeFloatContextSpec.Text -> it.path == request?.path
        is NativeFloatContextSpec.Flow -> it.path == request?.path
        else -> false
    } }.takeIf { request != null && it >= 0 }
    CompositionLocalProvider(LocalNativeScrollClip provides clip,
        LocalNativeContainerScrollport provides true,
        LocalTableContentWidths provides true,
        LocalNativeContextMeasureInput provides input,
        LocalNativeFlowMeasureInput provides null,
        LocalNativeContextInteractionOwner provides true,
        LocalNativeContextContainAtEnd provides true) {
        Layout(modifier = viewportMeasureInput.modifier.fillMaxWidth().clipToBounds().onGloballyPositioned {
            clip.update(it.boundsInWindow(), view)
        }.horizontalScroll(scroll), content = {
            NativeFloatContextLayout(spec.parts, Modifier, linkColor, containAtEnd = true,
                revealIndex = revealIndex, revealToken = request,
                onRevealed = { if (request != null) reached(request) }, adjoining = true,
                child = child)
            NativeLayoutMessage(message)
        }, measurePolicy = object : MeasurePolicy {
            override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                (measurables.first().minIntrinsicWidth(height).toLong() + ceil(spec.padding.left + spec.padding.right).toLong())
                    .coerceAtMost(Constraints.Infinity.toLong()).toInt()
            override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                (measurables.first().maxIntrinsicWidth(height).toLong() + ceil(spec.padding.left + spec.padding.right).toLong())
                    .coerceAtMost(Constraints.Infinity.toLong()).toInt()
            override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                // horizontalScroll retains the actual filled viewport minimum. Text shaping and
                // percentage tables receive this finite width, never its unbounded scroll maximum.
                val viewport = constraints.minWidth
                val contentWidth = floor((viewport - spec.padding.left - spec.padding.right).coerceAtLeast(0f)).toInt()
                val childConstraints = Constraints(minWidth = contentWidth, maxWidth = contentWidth)
                val request = input.request(constraints, childConstraints, environment,
                    NativeFlowParentPolicy(composition, true, null, 0f), emptyList())
                val content = measurables.first().measure(childConstraints)
                val measured = input.measured(request)
                val geometry = measured?.result?.getOrNull()
                check(geometry == null || geometry.width == content.width && geometry.height == content.height)
                val bounds = geometry?.scrollableBounds ?: measured?.fallbackBounds ?:
                    NativeFloatBounds(0f, 0f, contentWidth.toFloat(), content.height.toFloat())
                val allocation = nativeScrollportAllocation(viewport, geometry?.usedHeight ?: content.height.toFloat(), bounds, spec.padding)
                // Preserve the complete real body on an unsupported y-overflow result; its visible
                // warning and expanded fallback are not a successful local-scroll layout.
                message.update(when {
                    allocation.verticalOverflow -> "Local vertical overflow is unavailable"
                    allocation.leadingOverflow -> "Leading horizontal overflow is unavailable"
                    else -> null
                })
                val warning = measurables.last().measure(Constraints(maxWidth = viewport))
                val height = allocation.height.toLong() + warning.height
                if (height > TablePixelLimit) throw UnsupportedFloatLayout("Scrollport fallback exceeds native geometry")
                return layout(allocation.content, height.toInt()) {
                    warning.place(0, 0)
                    val x = floor(allocation.originX).toInt()
                    val y = floor(allocation.originY).toInt()
                    content.placeWithLayer(x, y + warning.height) {
                        translationX = allocation.originX - x
                        translationY = allocation.originY - y
                    }
                }
            }
        })
    }
}
