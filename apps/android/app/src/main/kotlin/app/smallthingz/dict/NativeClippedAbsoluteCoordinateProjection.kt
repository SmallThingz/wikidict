package app.smallthingz.dict

import android.graphics.Matrix
import android.graphics.RectF
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.LayoutCoordinates

/** A source epoch owns coordinate leases, never another text or accessibility tree. */
internal class NativeClippedAbsoluteCoordinateOwner {
    val rootScope = NativeClippedAbsoluteCoordinateScope(this)
    private var rootLease: Lease? = null
    internal class Lease(val binding: Any, var coordinates: LayoutCoordinates, var localOrigin: Offset,
        var scrollClip: NativeScrollClip?, var outerClip: NativeTextClip?, var current: () -> Boolean,
        var reveal: (RectF, (Boolean) -> Unit) -> (() -> Unit)) {
        val publication = NativeClippedPublication(binding) { this.coordinates.isAttached && this.current() }
    }

    /** outerClip and reveal rectangles are SCREEN coordinates. The publisher supplies the
     * actual source/measurement identity guard and clears its own binding on failure/disposal. */
    fun publish(scope: NativeClippedAbsoluteCoordinateScope, binding: Any, coordinates: LayoutCoordinates,
        localOrigin: Offset, scrollClip: NativeScrollClip?, outerClip: NativeTextClip?,
        current: () -> Boolean, reveal: (RectF, (Boolean) -> Unit) -> (() -> Unit)) {
        require(scope === rootScope)
        require(outerClip != null) { "The root requires its actual viewport clip" }
        if (!localOrigin.x.isFinite() || !localOrigin.y.isFinite())
            throw UnsupportedFloatLayout("Clipped absolute containing-block origin is unavailable")
        val previous = rootLease
        if (previous?.binding === binding) {
            previous.coordinates = coordinates; previous.localOrigin = localOrigin
            previous.scrollClip = scrollClip; previous.outerClip = outerClip
            previous.current = current; previous.reveal = reveal
            previous.publication.update { previous.coordinates.isAttached && previous.current() }
        } else {
            previous?.publication?.retire()
            rootLease = Lease(binding, coordinates, localOrigin, scrollClip, outerClip, current, reveal)
        }
    }

    fun clear(binding: Any) {
        if (rootLease?.binding === binding) { rootLease?.publication?.retire(); rootLease = null }
    }
    fun clear(scope: NativeClippedAbsoluteCoordinateScope, binding: Any) {
        if (scope === rootScope) clear(binding)
    }

    fun rootOuterClip(): NativeTextClip? {
        val root = lease(rootScope) ?: return null
        var clip = root.outerClip ?: return null
        root.scrollClip?.inScreen()?.let { clip = clip.intersected(it) }
        root.scrollClip?.preciseInScreen()?.let { clip = clip.intersected(it) }
        return clip
    }

    internal fun lease(scope: NativeClippedAbsoluteCoordinateScope): Lease? = rootLease?.takeIf {
        scope === rootScope && it.publication.isCurrent
    }

    internal fun current(scope: NativeClippedAbsoluteCoordinateScope, lease: Lease): Boolean =
        scope === rootScope && rootLease === lease && lease.publication.isCurrent
}

internal class NativeClippedAbsoluteCoordinateScope internal constructor(
    val owner: NativeClippedAbsoluteCoordinateOwner,
) {
    val revisionKey: Any get() = this
}

internal val LocalNativeClippedAbsoluteCoordinateScope =
    staticCompositionLocalOf<NativeClippedAbsoluteCoordinateScope?> { null }

/** A viewport represented inside aggregate geometry, rather than in the source View's
 * ancestor chain. Native wrappers translate only, so pan is in the final geometry's
 * axes; the View matrix applies the actual outer transform once. */
internal data class NativeClippedAbsoluteViewportStep(val clip: NativeScrollClip, val panX: Float, val panY: Float)

internal class NativeClippedAbsoluteCoordinateProjection internal constructor(
    val toScreen: Matrix,
    val clip: NativeTextClip,
    private val scope: NativeClippedAbsoluteCoordinateScope,
    private val lease: NativeClippedAbsoluteCoordinateOwner.Lease,
    private val snapshot: NativeClippedPublicationSnapshot,
) {
    private fun ownerIsCurrent() = scope.owner.current(scope, lease)
    fun isCurrent() = ownerIsCurrent() && snapshot.isCurrent
    fun reveal(screen: RectF, complete: (Boolean) -> Unit): () -> Unit {
        if (!isCurrent()) { complete(false); return {} }
        return lease.reveal(RectF(screen)) { complete(it && ownerIsCurrent() && snapshot.ownerIsCurrent) }
    }
}

private fun nativeClippedOwnerToScreen(coordinates: LayoutCoordinates, origin: Offset): Matrix {
    val source = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f)
    val target = FloatArray(6)
    repeat(3) { i ->
        val point = coordinates.localToScreen(origin + Offset(source[i * 2], source[i * 2 + 1]))
        target[i * 2] = point.x; target[i * 2 + 1] = point.y
    }
    val matrix = Matrix()
    val fourth = coordinates.localToScreen(origin + Offset(1f, 1f))
    if (!target.all(Float::isFinite) || !matrix.setPolyToPoly(source, 0, target, 0, 3) || !matrix.invert(Matrix()))
        throw UnsupportedFloatLayout("Clipped absolute containing-block transform is unavailable")
    val check = floatArrayOf(1f, 1f).also(matrix::mapPoints)
    if (!fourth.x.isFinite() || !fourth.y.isFinite() ||
        kotlin.math.abs(check[0] - fourth.x) > .01f || kotlin.math.abs(check[1] - fourth.y) > .01f)
        throw UnsupportedFloatLayout("Clipped absolute containing-block perspective is unavailable")
    return matrix
}

/** Resolve the original source box through its authenticated containing block. Only
 * intervening scrolling is undone; the containing block and its ancestors still move. */
internal fun NativeClippedAbsoluteCoordinateScope.project(
    sourceToScreen: Matrix,
    sourceClip: NativeScrollClip?,
    steps: List<NativeClippedAbsoluteViewportStep>,
): NativeClippedAbsoluteCoordinateProjection? {
    val lease = owner.lease(this) ?: return null
    val snapshot = NativeClippedPublicationSnapshot(lease.publication)
    val rootClip = owner.rootOuterClip() ?: return null
    val ownerToScreen = nativeClippedOwnerToScreen(lease.coordinates, lease.localOrigin)
    val screenToOwner = Matrix()
    if (!ownerToScreen.invert(screenToOwner)) return null
    val sourceToOwner = Matrix().apply { setConcat(screenToOwner, sourceToScreen) }
    val screenPan = FloatArray(2)
    fun add(x: Float, y: Float) {
        if (!x.isFinite() || !y.isFinite()) throw UnsupportedFloatLayout("Clipped absolute scroll transform is unavailable")
        screenPan[0] += x; screenPan[1] += y
        if (!screenPan.all(Float::isFinite)) throw UnsupportedFloatLayout("Clipped absolute scroll displacement exceeds native geometry")
    }
    val escapes = try {
        nativeClippedScrollEscapes(sourceClip, lease.scrollClip, steps.map { it.clip }) { it.semanticParent }
    } catch (invalid: IllegalArgumentException) {
        throw UnsupportedFloatLayout(invalid.message ?: "Clipped absolute viewport ancestry is unavailable")
    }
    for (escape in escapes) {
        val step = escape.virtualIndex?.let(steps::get)
        if (step == null) {
            val delta = escape.owner.semanticScrollTranslationInScreen() ?: return null
            add(delta.x, delta.y)
        } else {
            val vector = floatArrayOf(0f, 0f, step.panX, step.panY).also(sourceToScreen::mapPoints)
            add(vector[2] - vector[0], vector[3] - vector[1])
        }
    }
    val ownerPan = floatArrayOf(0f, 0f, screenPan[0], screenPan[1]).also(screenToOwner::mapPoints)
    if (!ownerPan.all(Float::isFinite)) throw UnsupportedFloatLayout("Clipped absolute owner displacement is unavailable")
    sourceToOwner.postTranslate(-(ownerPan[2] - ownerPan[0]), -(ownerPan[3] - ownerPan[1]))
    val result = Matrix().apply { setConcat(ownerToScreen, sourceToOwner) }
    val values = FloatArray(9).also(result::getValues)
    if (!values.all(Float::isFinite) || values[6] != 0f || values[7] != 0f || values[8] != 1f || !result.invert(Matrix()))
        throw UnsupportedFloatLayout("Clipped absolute projected transform is unavailable")
    var clip = lease.outerClip?.intersected(rootClip) ?: rootClip
    lease.scrollClip?.inScreen()?.let { clip = clip.intersected(it) }
    lease.scrollClip?.preciseInScreen()?.let { clip = clip.intersected(it) }
    return NativeClippedAbsoluteCoordinateProjection(result, clip, this, lease, snapshot).takeIf { it.isCurrent() }
}
