package app.smallthingz.dict

import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect as ComposeRect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Source-only donor for retained AndroidView clip replacement; no device result is implied. */
@RunWith(AndroidJUnit4::class)
class NativeScrollClipUpdateDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun retainedTextOwnerUsesEachCurrentClipForAccessibilityAndPointerInput() {
        val span = Span("link", "MMMM", "clip-target", targetFragment = "retained")
        val target = span.entryLink()
        val owner = Any()
        val identity = MissingLinkActionIdentity(owner,
            MissingLinkTarget("en", span.kind, target.title, target.fragment),
            NativeLinkOccurrenceIdentity(owner, 0, 0, span.text.length, span))
        val state = NativeMissingLinkPaint(MissingLinkPaint.VectorNewLinkV1,
            dark = false, visited = false, actionIdentity = identity)
        val calls = mutableListOf<EntryLink>()
        val action: () -> Unit = { calls.add(target); Unit }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 32f
            typeface = Typeface.MONOSPACE
            color = Color.BLUE
        }
        val original = SpannableString(span.text).apply {
            setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint),
                NativeLineHeightPolicy.Pixels(56f), strut = true),
                0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        var geometryBuilds = 0
        val factory: (Int) -> FloatTextGeometry = { width ->
            geometryBuilds++
            NativeFloatGeometry.build(original, paint, width, emptyList(),
                textDirection = TextDirectionHeuristics.LTR, nodeFactory = { geometry ->
                    listOf(FloatInteractionNode(7, FloatInteractionKind.LINK, 0, original.length,
                        geometry.rectsForRange(0, original.length), span.text, null, action,
                        missingLinkPaint = state))
                })
        }
        val selectedClip = mutableStateOf<NativeScrollClip?>(null)
        var view: NativeFloatTextView? = null
        var viewCreations = 0
        var updates = 0
        var appliedClip: NativeScrollClip? = null
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                        LocalLayoutDirection provides LayoutDirection.Ltr) {
                        Box(Modifier.safeDrawingPadding().padding(24.dp)) {
                            AndroidView(modifier = Modifier.size(180.dp, 96.dp), factory = { context ->
                                NativeFloatTextView(context).also {
                                    it.setPadding(8, 8, 8, 8)
                                    view = it
                                    viewCreations++
                                }
                            }, update = { current ->
                                current.updateScrollClip(selectedClip.value)
                                appliedClip = selectedClip.value
                                updates++
                                current.bind(factory, Color.CYAN, Color.MAGENTA)
                            })
                        }
                    }
                }
            }
            compose.waitForIdle()
            lateinit var retainedView: NativeFloatTextView
            lateinit var retainedGeometry: FloatTextGeometry
            lateinit var rawNode: FloatInteractionNode
            lateinit var rawCharacters: List<RectF>
            lateinit var rawBounds: RectF
            var retainedBuilds = 0
            compose.runOnIdle {
                retainedView = checkNotNull(view)
                assertPhysicalActivity(compose.activity)
                assertTrue(retainedView.hasWindowFocus())
                retainedGeometry = checkNotNull(retainedView.currentMeasuredGeometry)
                rawNode = retainedGeometry.nodes.single()
                val measuredCharacters = retainedGeometry.characterRects(0, original.length)
                try {
                    rawCharacters = measuredCharacters.map { RectF(checkNotNull(it)) }
                    rawBounds = RectF().also { bounds -> rawNode.bounds.forEach(bounds::union) }
                    retainedBuilds = geometryBuilds
                    assertEquals(1, viewCreations)
                    assertEquals(original.toString(), retainedView.logicalText.toString())
                    assertEquals(original.length, rawCharacters.size)
                    // Selection ink retains native font metrics; the authored height owns the line band.
                    val native = retainedGeometry as NativeFloatGeometry
                    assertEquals(1, native.shapedLineCount)
                    assertEquals(56f, native.usedLineHeight(0), .001f)
                    rawCharacters.forEach { assertTrue(it.width() > 0f); assertTrue(it.height() > 20f) }
                    val visible = Rect()
                    assertTrue(retainedView.getLocalVisibleRect(visible))
                    val local = RectF(rawBounds).apply { offset(8f, 8f) }
                    assertTrue(RectF(visible).contains(local))
                } catch (failure: Throwable) {
                    val details = StringBuilder("Initial retained scroll-clip geometry: ")
                    try {
                        details.append("characters(count=").append(measuredCharacters.size).append(")=")
                            .append(measuredCharacters.take(8).mapIndexed { index, rect -> "$index=$rect" })
                        details.append("; nodeBounds(count=").append(rawNode.bounds.size).append(")=")
                            .append(rawNode.bounds.take(8))
                        details.append("; geometry=").append(retainedGeometry.width).append('x').append(retainedGeometry.height)
                        details.append("; view=").append(retainedView.width).append('x').append(retainedView.height)
                            .append(" measured=").append(retainedView.measuredWidth).append('x').append(retainedView.measuredHeight)
                            .append(" padding=").append(listOf(retainedView.paddingLeft, retainedView.paddingTop,
                                retainedView.paddingRight, retainedView.paddingBottom))
                        details.append("; textSize=").append(paint.textSize)
                        val font = paint.fontMetrics
                        details.append("; font(top,ascent,descent,bottom,leading)=")
                            .append(listOf(font.top, font.ascent, font.descent, font.bottom, font.leading))
                        (retainedGeometry as? NativeFloatGeometry)?.let { native ->
                            details.append("; lines=").append(native.shapedLineCount)
                                .append(" firstBand=").append(native.firstLineBand())
                                .append(" textBottom=").append(native.textBottom)
                            if (native.shapedLineCount > 0) details.append(" usedHeight0=").append(native.usedLineHeight(0))
                        }
                        details.append("; carets=").append((0..original.length).take(8).map { offset ->
                            "$offset=${retainedGeometry.caretRect(offset)}"
                        })
                    } catch (diagnostic: Throwable) {
                        if (diagnostic !== failure) failure.addSuppressed(diagnostic)
                    }
                    val diagnostic = AssertionError(details.toString())
                    if (diagnostic !== failure) failure.addSuppressed(diagnostic)
                    throw failure
                }
            }

            val first = RectF(rawBounds.left + 2f, rawBounds.top + 5f,
                rawCharacters[2].centerX(), rawBounds.bottom - 7f)
            val second = RectF(rawCharacters[1].centerX(), rawBounds.top + 9f,
                rawBounds.right - 2f, rawBounds.bottom - 3f)
            val third = RectF(rawCharacters[1].centerX(), rawBounds.top + 3f,
                rawCharacters[2].centerX(), rawBounds.bottom - 11f)
            val shared = RectF(first).apply { assertTrue(intersect(second)) }
            val clipA = NativeScrollClip(null)
            val clipB = NativeScrollClip(null)

            fun updateBounds(clip: NativeScrollClip, local: RectF) {
                val at = IntArray(2).also(retainedView::getLocationInWindow)
                clip.update(ComposeRect(local.left + at[0] + retainedView.paddingLeft,
                    local.top + at[1] + retainedView.paddingTop,
                    local.right + at[0] + retainedView.paddingLeft,
                    local.bottom + at[1] + retainedView.paddingTop), retainedView)
            }
            fun expectedScreen(raw: RectF, clip: RectF?): Rect? {
                val clipped = RectF(raw)
                if (clip != null && !clipped.intersect(clip)) return null
                val at = IntArray(2).also(retainedView::getLocationOnScreen)
                clipped.offset(at[0] + retainedView.paddingLeft.toFloat(),
                    at[1] + retainedView.paddingTop.toFloat())
                return Rect().also(clipped::roundOut)
            }
            fun assertPhase(label: String, clip: RectF?, focused: Boolean) {
                assertSame(label, retainedView, view)
                assertSame(label, retainedGeometry, retainedView.currentMeasuredGeometry)
                assertEquals(label, retainedBuilds, geometryBuilds)
                assertEquals(label, 1, viewCreations)
                assertSame(label, rawNode, retainedGeometry.nodes.single())
                assertSame(label, action, rawNode.onClick)
                assertSame(label, state, rawNode.missingLinkPaint)
                assertSame(label, identity, rawNode.missingLinkPaint?.actionIdentity)
                assertEquals(label, original.toString(), retainedView.logicalText.toString())
                assertEquals(label, 0, rawNode.start)
                assertEquals(label, original.length, rawNode.end)
                assertFalse(label, retainedView.selectionActive)
                val provider = retainedView.accessibilityNodeProvider
                val info = checkNotNull(provider.createAccessibilityNodeInfo(rawNode.id))
                try {
                    assertEquals(label, span.text, info.text.toString())
                    assertTrue(label, info.isClickable)
                    assertTrue(label, info.isVisibleToUser)
                    assertEquals(label, focused, info.isFocused)
                    assertEquals(label, focused, info.isAccessibilityFocused)
                    assertEquals(label, expectedScreen(rawBounds, clip), Rect().also(info::getBoundsInScreen))
                } finally { info.recycle() }
                if (focused) {
                    for (kind in listOf(AccessibilityNodeInfo.FOCUS_INPUT, AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)) {
                        val focus = checkNotNull(provider.findFocus(kind))
                        try {
                            assertEquals(label, span.text, focus.text.toString())
                            assertTrue(label, if (kind == AccessibilityNodeInfo.FOCUS_INPUT)
                                focus.isFocused else focus.isAccessibilityFocused)
                        } finally { focus.recycle() }
                    }
                }
                val host = checkNotNull(provider.createAccessibilityNodeInfo(View.NO_ID))
                try {
                    val key = AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY
                    provider.addExtraDataToAccessibilityNodeInfo(View.NO_ID, host, key, Bundle().apply {
                        putInt(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX, 0)
                        putInt(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH, original.length)
                    })
                    val characters = checkNotNull(host.extras.getParcelableArray(key))
                    assertEquals(label, original.length, characters.size)
                    rawCharacters.forEachIndexed { index, raw ->
                        val expected = expectedScreen(raw, clip)?.let(::RectF)
                        assertEquals("$label character $index", expected, characters[index] as RectF?)
                    }
                } finally { host.recycle() }
            }
            fun send(actionCode: Int, x: Float, y: Float, downTime: Long): Boolean {
                assertPhysicalActivity(compose.activity)
                assertTrue(retainedView.hasWindowFocus())
                val event = MotionEvent.obtain(downTime, maxOf(downTime, SystemClock.uptimeMillis()),
                    actionCode, x + retainedView.paddingLeft, y + retainedView.paddingTop, 0)
                return try { retainedView.dispatchTouchEvent(event) } finally { event.recycle() }
            }
            fun tap(x: Float, y: Float) {
                val now = SystemClock.uptimeMillis()
                send(MotionEvent.ACTION_DOWN, x, y, now)
                send(MotionEvent.ACTION_UP, x, y, now)
            }
            fun assertTaps(label: String, clip: RectF?, visibleCharacter: Int, hiddenCharacter: Int?) {
                val shown = RectF(rawCharacters[visibleCharacter])
                if (clip != null) assertTrue(shown.intersect(clip))
                if (hiddenCharacter != null) {
                    val hidden = rawCharacters[hiddenCharacter]
                    assertFalse(checkNotNull(clip).contains(hidden.centerX(), hidden.centerY()))
                    val before = calls.size
                    tap(hidden.centerX(), hidden.centerY())
                    // Selection is allowed to consume an event; the clipped action must not fire.
                    assertEquals("$label clipped point", before, calls.size)
                }
                val before = calls.size
                tap(shown.centerX(), shown.centerY())
                assertEquals("$label visible point", before + 1, calls.size)
                assertEquals(label, target, calls.last())
            }
            fun replaceClip(next: NativeScrollClip?, bounds: RectF?, beforeReplacement: (() -> Unit)? = null) {
                var previousUpdates = 0
                compose.runOnIdle {
                    previousUpdates = updates
                    if (next != null) updateBounds(next, checkNotNull(bounds))
                    beforeReplacement?.invoke()
                    selectedClip.value = next
                }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertTrue(updates > previousUpdates)
                    assertSame(next, appliedClip)
                }
            }

            compose.runOnIdle {
                assertPhase("initial null", null, false)
                assertTaps("initial null", null, 0, null)
                val provider = retainedView.accessibilityNodeProvider
                assertTrue(provider.performAction(rawNode.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(provider.performAction(rawNode.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                assertPhase("focused null", null, true)
            }
            replaceClip(clipA, first)
            compose.runOnIdle {
                assertPhase("first clip", first, true)
                assertTaps("first clip", first, 0, 3)
            }

            // Both endpoints remain inside both clips: only identity-change cancellation
            // may reject this retained DOWN/UP sequence, not a point outside the new clip.
            var heldAt = 0L
            var callsBeforeHeld = 0
            replaceClip(clipB, second) {
                callsBeforeHeld = calls.size
                heldAt = SystemClock.uptimeMillis()
                assertTrue(send(MotionEvent.ACTION_DOWN, shared.centerX(), shared.centerY(), heldAt))
            }
            compose.runOnIdle {
                send(MotionEvent.ACTION_UP, shared.centerX(), shared.centerY(), heldAt)
                assertEquals("held input cancelled by clip identity", callsBeforeHeld, calls.size)
                assertPhase("second clip", second, true)
                assertTaps("second clip", second, 3, 0)
            }

            // This is a live read/query check, not a claim that mutable bounds alone
            // schedule paint. Do not replace the state or manually invalidate the View.
            compose.runOnIdle {
                val previousUpdates = updates
                updateBounds(clipB, third)
                assertSame(clipB, selectedClip.value)
                assertEquals(previousUpdates, updates)
                assertPhase("same clip moved", third, true)
                assertTaps("same clip moved", third, 1, 3)
            }
            replaceClip(null, null)
            compose.runOnIdle {
                assertPhase("restored null", null, true)
                assertTaps("restored null", null, 0, null)
                assertTaps("restored right edge", null, 3, null)
                assertEquals(6, calls.size)
                assertTrue(calls.all { it == target })
            }
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (cleanup !== failure) failure.addSuppressed(cleanup)
            }
        }
    }
}
