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
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.sp

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

    @Test fun clippedAbsoluteSourceKeepsVirtualActionsAndExactSemanticAnchorsWithoutPaintOrHit() {
        // Direct typed consumer control, not a source-emitter or TalkBack acceptance receipt.
        val hiddenLink = Span("link", "Tooltip", "clipped-target", targetFragment = "source")
        val hiddenExternal = Span("external_link", " time to peak concentrations", "https://example.org/clipped")
        val before = Span("link", "A", "before")
        val after = Span("link", "B", "after")
        fun signed(value: Float) = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, value))
        fun owner(width: Float, height: Float, children: List<Span>) = Span("text", "", clippedAbsolute =
            ClippedAbsoluteInline(StyleLength(StyleLengthUnit.Px, width), StyleLength(StyleLengthUnit.Px, height),
                ContainerMargins(signed(-.5f), signed(-2f), signed(-3f), signed(-1.25f)), children, BidiResolvedDirection.Ltr))
        val clipped = owner(12.5f, 6.25f, listOf(hiddenLink, hiddenExternal))
        val point = owner(0f, 0f, listOf(hiddenLink, hiddenExternal))
        val plainChild = Span("text", "retained plain source")
        val plain = owner(0f, 0f, listOf(plainChild))
        val sources = listOf(listOf(before, clipped, after), listOf(clipped), listOf(point), listOf(plain))
        val projections = sources.map { rubyGraphicalProjection(it, "clipped-view") }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 20f; typeface = Typeface.MONOSPACE; color = Color.BLACK
        }
        val policy = NativeLineHeightPolicy.Pixels(32f)
        val calls = mutableListOf<Span>()
        val failures = mutableListOf<String>()
        val callbacks = listOf(before, hiddenLink, hiddenExternal, after).associateWith { span ->
            { calls.add(span); Unit }
        }
        val coordinateOwner = NativeClippedAbsoluteCoordinateOwner()
        val rootBinding = Any()
        val selectedClip = mutableStateOf<NativeScrollClip?>(null)
        val factoryRevision = mutableStateOf(0)
        var holdReveal = false
        var queuedReveal: ((Boolean) -> Unit)? = null
        var revealCancelled = false
        var cancelCalls = 0
        var rootCoordinates: androidx.compose.ui.layout.LayoutCoordinates? = null
        fun publishRoot() {
            val coordinates = rootCoordinates?.takeIf { it.isAttached } ?: return
            val origin = coordinates.localToScreen(androidx.compose.ui.geometry.Offset.Zero)
            val bounds = RectF(origin.x, origin.y, origin.x + coordinates.size.width, origin.y + coordinates.size.height)
            coordinateOwner.publish(coordinateOwner.rootScope, rootBinding, coordinates,
                androidx.compose.ui.geometry.Offset.Zero, selectedClip.value, NativeTextClip.rectangle(bounds),
                current = { coordinates.isAttached }, reveal = { target, complete ->
                    val visible = target.left >= bounds.left && target.right <= bounds.right &&
                        target.top >= bounds.top && target.bottom <= bounds.bottom
                    if (holdReveal) { assertTrue(visible); queuedReveal = complete } else complete(visible)
                    val cancellation: () -> Unit = {
                        cancelCalls++
                        if (queuedReveal === complete) {
                            queuedReveal = null; revealCancelled = true
                            complete(false)
                        }
                    }
                    cancellation
                })
        }
        var builds = 0
        val factories: List<(Int) -> FloatTextGeometry> = projections.mapIndexed { phase, projection ->
            val range = projection.ranges.single { it.role == RubyTextRole.ClippedAbsolute }
            val original = checkNotNull(range.span)
            val source = SpannableString(projection.text).apply {
                setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), policy, strut = true),
                    0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val format = NativeClippedAbsoluteFormat(NativeClippedAbsoluteOwner(original, range.path),
                if (phase < 2) 12.5f else 0f, if (phase < 2) 6.25f else 0f,
                NativeClippedAbsoluteMargins(-.5f, -2f, -3f, -1.25f), coordinateOwner.rootScope)
            val marker = NativeRubyPreparedSource(projection, source, paint, TextDirectionHeuristics.LTR,
                mapOf(range.path to NativeRubyGroupFormat(paint, TextDirectionHeuristics.LTR, policy,
                    clippedAbsolute = format)))
            source.setSpan(marker, 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val factory: (Int) -> FloatTextGeometry = { width ->
                builds++
                NativeFloatGeometry.build(source, paint, width, emptyList(),
                    textDirection = TextDirectionHeuristics.LTR, includeFontPadding = false, nodeFactory = { geometry ->
                        projection.ranges.filter { it.role == RubyTextRole.Text || it.role == RubyTextRole.ClippedText }
                            .filter { it.span?.kind in setOf("link", "external_link") }
                            .mapIndexed { index, leaf ->
                                val span = checkNotNull(leaf.span)
                                FloatInteractionNode(index + 1, FloatInteractionKind.LINK, leaf.start, leaf.end,
                                    geometry.rectsForRange(leaf.start, leaf.end), span.text + span.trail,
                                    span.tooltip, checkNotNull(callbacks[span]))
                            }
                    })
            }
            factory
        }
        val phase = mutableStateOf(0)
        var view: NativeFloatTextView? = null
        var creations = 0
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalNativeClippedAbsoluteCoordinateScope provides coordinateOwner.rootScope,
                    LocalNativeScrollClip provides selectedClip.value) {
                    androidx.compose.runtime.DisposableEffect(coordinateOwner) {
                        onDispose { coordinateOwner.clear(rootBinding) }
                    }
                    androidx.compose.runtime.SideEffect { publishRoot() }
                    Box(Modifier.safeDrawingPadding().padding(32.dp).size(240.dp).onGloballyPositioned {
                        rootCoordinates = it; publishRoot()
                    }) {
                      TableContentViewport(scrolling = true) {
                       val actualClip = LocalNativeScrollClip.current
                       val currentPhase = phase.value
                       val selectedFactory = androidx.compose.runtime.remember(currentPhase, factoryRevision.value) {
                           { width: Int -> factories[currentPhase](width) }
                       }
                       androidx.compose.ui.layout.Layout(content = {
                        AndroidView(modifier = Modifier.width(180.dp), factory = { context ->
                            NativeFloatTextView(context).also {
                                it.translationX = .25f; it.translationY = .375f
                                creations++; view = it
                            }
                        }, update = { current ->
                            current.updateScrollClip(actualClip)
                            current.bind(selectedFactory, Color.CYAN, Color.MAGENTA,
                                onUnsupported = { failures += it.message.orEmpty() })
                        })
                       }) { children, constraints ->
                           val child = children.single().measure(androidx.compose.ui.unit.Constraints(
                               minWidth = 180, maxWidth = 180, maxHeight = constraints.maxHeight))
                           // A real overwide table content allocation, with the original View
                           // placed at its source origin. TableContentViewport owns the pan.
                           layout(360, child.height) { child.place(12, 0) }
                       }
                      }
                    }
                }
            } }
            compose.waitForIdle()
            lateinit var originalView: NativeFloatTextView
            lateinit var mixed: FloatTextGeometry
            lateinit var hidden: List<FloatInteractionNode>
            fun expectedScreen(current: NativeFloatTextView, rectangle: RectF): Rect {
                // The fixture adds only this known fractional child translation. Derive the
                // oracle from the untransformed parent's screen origin, never the new helper.
                val parent = current.parent as View
                val at = IntArray(2).also(parent::getLocationOnScreen)
                return Rect().also { result -> RectF(rectangle).apply {
                    offset(at[0] + current.left + current.translationX - parent.scrollX - current.scrollX,
                        at[1] + current.top + current.translationY - parent.scrollY - current.scrollY)
                }.roundOut(result) }
            }
            fun assertNode(current: NativeFloatTextView, node: FloatInteractionNode, visible: Boolean) {
                val location = checkNotNull(node.clippedAbsoluteLocation)
                assertTrue(node.bounds.isEmpty())
                assertNull(node.focusPaint)
                assertFalse(node.contains(location.bounds.centerX(), location.bounds.centerY()))
                val info = checkNotNull(current.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                try {
                    assertEquals(node.label.toString(), info.text.toString())
                    assertTrue(info.isClickable)
                    assertEquals(visible, info.isVisibleToUser)
                    if (visible) {
                        assertEquals(Rect().also(location.bounds::roundOut), Rect().also(info::getBoundsInParent))
                        assertEquals(expectedScreen(current, location.bounds), Rect().also(info::getBoundsInScreen))
                    }
                } finally { info.recycle() }
            }
            compose.runOnIdle {
                originalView = checkNotNull(view)
                assertPhysicalActivity(compose.activity)
                assertTrue(originalView.hasWindowFocus())
                mixed = checkNotNull(originalView.currentMeasuredGeometry)
                assertEquals(projections[0].text, originalView.logicalText.toString())
                assertEquals("ATooltip time to peak concentrationsB", mixed.text.toString())
                hidden = mixed.nodes.filter { it.clippedAbsoluteLocation != null }
                assertEquals(2, hidden.size)
                assertSame(callbacks[hiddenLink], hidden[0].onClick)
                assertSame(callbacks[hiddenExternal], hidden[1].onClick)
                val referenceSource = SpannableString("AB").apply {
                    setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), policy, strut = true),
                        0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                val reference = NativeFloatGeometry.build(referenceSource, paint, 180, emptyList(),
                    textDirection = TextDirectionHeuristics.LTR, includeFontPadding = false)
                assertEquals(reference.height, mixed.height)
                assertEquals(reference.caretRect(0), mixed.caretRect(0))
                assertEquals(reference.caretRect(1), mixed.caretRect(hidden.last().end))
                assertEquals(reference.caretRect(2), mixed.caretRect(mixed.text.length))
                val sourceBox = checkNotNull(hidden[0].clippedAbsoluteLocation).bounds
                val hiddenText = hiddenLink.text + hiddenExternal.text
                val fullProbe = before.text + hiddenText + after.text
                val hiddenAdvance = paint.getRunAdvance(fullProbe, 1, 1 + hiddenText.length,
                    0, fullProbe.length, false, 1 + hiddenText.length)
                assertTrue(hiddenAdvance - 1.25f - 2f > 180f)
                assertTrue(paint.measureText(before.text) < 180f)
                // The first ordinary character fits; the real nowrap hidden body does
                // not. Its first fragment starts on the next hypothetical 32px row.
                val fm = paint.fontMetrics
                val primaryTop = (32f - (fm.descent - fm.ascent)) / 2f
                assertEquals(-1.25f, sourceBox.left, .001f)
                assertEquals(32f + primaryTop, sourceBox.top, .001f)
                assertEquals(12.5f, sourceBox.width(), .001f); assertEquals(6.25f, sourceBox.height(), .001f)
                hidden.forEach { node ->
                    assertTrue(mixed.characterRects(node.start, node.end - node.start).all { it == null })
                    assertTrue(mixed.rectsForRange(node.start, node.end).isEmpty())
                    assertNode(originalView, node, true)
                }
                val pointerCalls = calls.size
                val now = SystemClock.uptimeMillis()
                for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                    val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action,
                        sourceBox.centerX(), sourceBox.centerY(), 0)
                    try { originalView.dispatchTouchEvent(event) } finally { event.recycle() }
                }
                assertTrue(calls.drop(pointerCalls).none { it === hiddenLink || it === hiddenExternal })
                calls.clear()
                val extraHost = checkNotNull(originalView.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID))
                try {
                    val key = AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY
                    originalView.accessibilityNodeProvider.addExtraDataToAccessibilityNodeInfo(View.NO_ID, extraHost, key,
                        Bundle().apply {
                            putInt(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX, hidden[0].start)
                            putInt(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH,
                                hidden.last().end - hidden[0].start)
                        })
                    val characters = checkNotNull(extraHost.extras.getParcelableArray(key))
                    assertEquals(hidden.last().end - hidden[0].start, characters.size)
                    assertTrue(characters.all { it == null })
                } finally { extraHost.recycle() }
                originalView.setSelection(0, mixed.text.length)
                assertEquals(mixed.text.toString(), originalView.selectedTextForCopy())
                originalView.setSelection(hidden[0].start, hidden.last().end)
                assertEquals(hiddenLink.text + hiddenExternal.text, originalView.selectedTextForCopy())
                val provider = originalView.accessibilityNodeProvider
                for (node in hidden) {
                    assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                    assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                }
                assertEquals(listOf(hiddenLink, hiddenExternal), calls)
                assertTrue(provider.performAction(hidden[0].id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(originalView.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN,
                    android.view.KeyEvent.KEYCODE_TAB)))
                originalView.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_TAB))
                val focused = checkNotNull(provider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT))
                try { assertEquals(hiddenExternal.text, focused.text.toString()) } finally { focused.recycle() }
                val beforeEnter = calls.size
                assertTrue(originalView.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                // Existing null-policy source actions activate on DOWN, unlike stateful
                // link-paint owners. Empty hit geometry must not remove that route.
                assertEquals(beforeEnter + 1, calls.size)
                originalView.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                assertEquals(beforeEnter + 1, calls.size)
                assertSame(hiddenExternal, calls.last())
                val buildCount = builds
                originalView.scrollTo(2, 3)
                hidden.forEach { assertNode(originalView, it, true) }
                assertEquals(buildCount, builds)
                originalView.scrollTo(0, 0)
            }
            // A real ancestor scroll clip can hide the semantic box without deleting its
            // source node/callback. Replacing it restores the same View and source geometry.
            val clip = NativeScrollClip(null)
            compose.runOnIdle {
                val at = IntArray(2).also(originalView::getLocationInWindow)
                clip.update(ComposeRect(at[0] + 100f, at[1] + 40f, at[0] + 140f, at[1] + 80f), originalView)
                selectedClip.value = clip
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertSame(originalView, view); assertSame(mixed, originalView.currentMeasuredGeometry)
                hidden.forEach { assertNode(originalView, it, false) }
                selectedClip.value = null
            }
            compose.waitForIdle()
            compose.runOnIdle { hidden.forEach { assertNode(originalView, it, true) } }
            val tableViewport = compose.onNode(androidx.compose.ui.test.SemanticsMatcher.keyIsDefined(
                androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange))
            lateinit var beforePan: Rect
            var viewLeft = 0
            compose.runOnIdle {
                val info = checkNotNull(originalView.accessibilityNodeProvider.createAccessibilityNodeInfo(hidden[0].id))
                try { beforePan = Rect().also(info::getBoundsInScreen) } finally { info.recycle() }
                viewLeft = IntArray(2).also(originalView::getLocationOnScreen)[0]
            }
            tableViewport.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.ScrollBy) {
                assertTrue(it(80f, 0f))
            }
            compose.waitForIdle()
            val pannedRange = tableViewport.fetchSemanticsNode().config[
                androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange]
            compose.runOnIdle {
                assertEquals(80f, pannedRange.value(), .001f)
                assertEquals(viewLeft - 80, IntArray(2).also(originalView::getLocationOnScreen)[0])
                val info = checkNotNull(originalView.accessibilityNodeProvider.createAccessibilityNodeInfo(hidden[0].id))
                try {
                    assertTrue(info.isVisibleToUser)
                    assertEquals(beforePan, Rect().also(info::getBoundsInScreen))
                    assertEquals(hiddenLink.text, info.text.toString())
                } finally { info.recycle() }
                val count = calls.size
                assertTrue(originalView.accessibilityNodeProvider.performAction(hidden[0].id,
                    AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(count + 1, calls.size); assertSame(hiddenLink, calls.last())
                assertSame(mixed, originalView.currentMeasuredGeometry)
                originalView.setSelection(0, mixed.text.length)
                assertEquals(projections[0].text, originalView.selectedTextForCopy())
                coordinateOwner.clear(rootBinding)
                val detached = checkNotNull(originalView.accessibilityNodeProvider.createAccessibilityNodeInfo(hidden[0].id))
                try { assertFalse(detached.isVisibleToUser) } finally { detached.recycle() }
                publishRoot()
            }
            tableViewport.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.ScrollBy) {
                assertTrue(it(-80f, 0f))
            }
            compose.waitForIdle()
            compose.runOnIdle { hidden.forEach { assertNode(originalView, it, true) } }
            compose.runOnIdle {
                holdReveal = true
                val provider = originalView.accessibilityNodeProvider
                provider.performAction(hidden[0].id, AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS, null)
                assertTrue(provider.performAction(hidden[0].id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                assertNotNull(queuedReveal)
                factoryRevision.value++
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertFalse(revealCancelled)
                val complete = checkNotNull(queuedReveal)
                queuedReveal = null; holdReveal = false
                complete(true)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val focused = checkNotNull(originalView.accessibilityNodeProvider.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY))
                try { assertEquals(hiddenLink.text, focused.text.toString()); assertTrue(focused.isVisibleToUser) }
                finally { focused.recycle() }
                assertFalse(revealCancelled)
                val provider = originalView.accessibilityNodeProvider
                provider.performAction(hidden[0].id, AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS, null)
                holdReveal = true
                assertTrue(provider.performAction(hidden[0].id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                assertNotNull(queuedReveal)
                val beforeCancel = cancelCalls
                assertTrue(provider.performAction(hidden[0].id, AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS, null))
                assertEquals(beforeCancel + 1, cancelCalls)
                assertTrue(revealCancelled); assertNull(queuedReveal)
                holdReveal = false
            }
            for (next in 1..3) {
                compose.runOnIdle { phase.value = next }
                compose.waitForIdle()
                compose.runOnIdle {
                    val current = checkNotNull(view)
                    val geometry = checkNotNull(current.currentMeasuredGeometry)
                    assertSame(originalView, current); assertEquals(1, creations)
                    assertEquals(0, current.height); assertEquals(0, geometry.height)
                    assertEquals(projections[next].text, geometry.text.toString())
                    assertTrue(geometry.characterRects(0, geometry.text.length).all { it == null })
                    assertTrue(geometry.rectsForRange(0, geometry.text.length).isEmpty())
                    assertFalse(geometry.containsInput(0f, 0f))
                    assertTrue(geometry.focusBounds.isEmpty)
                    val location = geometry.clippedAbsoluteSemanticLocations.single()
                    if (next >= 2) {
                        assertEquals(0f, location.bounds.width(), 0f)
                        assertEquals(0f, location.bounds.height(), 0f)
                    }
                    val host = checkNotNull(current.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID))
                    try {
                        assertEquals(projections[next].text, host.text.toString())
                        assertTrue(host.isVisibleToUser)
                        assertEquals(expectedScreen(current, location.bounds), Rect().also(host::getBoundsInScreen))
                    } finally { host.recycle() }
                    if (next == 3) assertTrue(geometry.nodes.isEmpty()) else {
                        assertTrue(current.isLaidOut)
                        assertFalse(current.isLayoutRequested)
                        val beforeInputFocus = calls.size
                        // A laid-out zero-height View cannot acquire platform input focus.
                        // Its virtual AX owner remains actionable below; the mixed positive-
                        // flow owner above proves actual keyboard traversal/activation.
                        assertFalse(current.accessibilityNodeProvider.performAction(geometry.nodes.first().id,
                            AccessibilityNodeInfo.ACTION_FOCUS, null))
                        assertEquals(beforeInputFocus, calls.size)
                    }
                    val beforeClippedActions = calls.size
                    geometry.nodes.forEach { node ->
                        assertNode(current, node, true)
                        val provider = current.accessibilityNodeProvider
                        assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                        assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                    }
                    val addedCalls = calls.drop(beforeClippedActions)
                    if (next == 3) assertTrue(addedCalls.isEmpty()) else {
                        assertEquals(2, addedCalls.size)
                        assertSame(hiddenLink, addedCalls[0]); assertSame(hiddenExternal, addedCalls[1])
                    }
                    current.setSelection(0, geometry.text.length)
                    assertEquals(projections[next].text, current.selectedTextForCopy())
                }
            }
            compose.runOnIdle { phase.value = 0 }
            compose.waitForIdle()
            compose.runOnIdle {
                val recovered = checkNotNull(originalView.currentMeasuredGeometry)
                assertEquals(mixed.text.toString(), recovered.text.toString())
                assertEquals(mixed.height, recovered.height)
                assertEquals(mixed.caretRect(mixed.text.length), recovered.caretRect(recovered.text.length))
                recovered.nodes.filter { it.clippedAbsoluteLocation != null }.forEach { assertNode(originalView, it, true) }
                assertTrue(failures.toString(), failures.isEmpty())
                assertSame(hiddenLink, checkNotNull(clipped.clippedAbsolute).children[0])
                assertSame(hiddenExternal, checkNotNull(clipped.clippedAbsolute).children[1])
                assertEquals(1, creations)
            }
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
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

    @Test fun styledRubyRefusalTerminatesInClippedNativeSourceAndRecoversWithoutHiddenPaint() {
        // Direct typed-source fallback control. This does not claim issuer or TalkBack qualification.
        val prefix = Span("text", "Before ")
        val internal = Span("link", "Tooltip", "terminal-tooltip", targetFragment = "retained",
            tooltip = "retained internal tooltip")
        val external = Span("external_link", " time to peak concentrations", "https://example.org/terminal-tooltip",
            tooltip = "retained external tooltip")
        val negative = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, -1f))
        val clipped = Span("text", "", clippedAbsolute = ClippedAbsoluteInline(
            StyleLength(StyleLengthUnit.Px, 1f), StyleLength(StyleLengthUnit.Px, 1f),
            ContainerMargins(negative, negative, negative, negative), listOf(internal, external), BidiResolvedDirection.Ltr))
        val base = Span("text", "字", fontScale = 1f)
        val reading = Span("text", "ji", fontScale = .5f)
        val ruby = Span("text", "", ruby = Ruby(listOf(RubySegment(emptyList(),
            listOf(RubyBase(RubyOwner(InlineFontSnapshot(fontScale = 1f), direction = "ltr"), emptyList(), listOf(base))),
            listOf(RubyAnnotation(0, 1, 0, RubyOwner(InlineFontSnapshot(fontScale = .5f), direction = "ltr"),
                emptyList(), listOf(reading), emptyList(), emptyList(), false))))))
        val suffix = Span("text", " After")
        val open = Span("text", "\uff08")
        val close = Span("text", "\uff09")
        val source = listOf(prefix, clipped, ruby, suffix)
        val recovery = listOf(prefix, clipped, base, open, reading, close, suffix)
        val visible = listOf(prefix, base, open, reading, close, suffix)
        val hiddenText = internal.text + external.text
        val expected = "Before ${hiddenText}字\uff08ji\uff09 After"
        val visibleExpected = "Before 字\uff08ji\uff09 After"
        val hiddenStart = prefix.text.length
        val hiddenEnd = hiddenStart + hiddenText.length
        val current = mutableStateOf(source)
        val links = mutableListOf<EntryLink>()
        val urls = mutableListOf<String>()
        val failures = mutableListOf<String>()
        val onLink: (EntryLink) -> Unit = { links += it }
        val onFailure: (String) -> Unit = { failures += it }
        val uri = object : androidx.compose.ui.platform.UriHandler {
            override fun openUri(uri: String) { urls += uri }
        }
        val focusDestination = androidx.compose.ui.focus.FocusRequester()
        val sharedContext = ContainerTextContext(lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 24f)))
        val coordinateOwner = NativeClippedAbsoluteCoordinateOwner()
        val rootBinding = Any()
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                        LocalLayoutDirection provides LayoutDirection.Ltr,
                        androidx.compose.ui.platform.LocalUriHandler provides uri,
                        LocalNativeFloatContextFailureObserver provides onFailure,
                        LocalNativeContainerTextContext provides sharedContext,
                        LocalNativeClippedAbsoluteCoordinateScope provides coordinateOwner.rootScope) {
                        androidx.compose.runtime.DisposableEffect(coordinateOwner) {
                            onDispose { coordinateOwner.clear(rootBinding) }
                        }
                        val style = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                            fontFamily = FontFamily.Monospace, color = androidx.compose.ui.graphics.Color.Black)
                        // Both independent sources use the same native StyledText path via
                        // this shared declared line height. The reference has no clipped/Ruby owner.
                        Box(Modifier.fillMaxSize().onGloballyPositioned { coordinates ->
                                val at = coordinates.localToScreen(androidx.compose.ui.geometry.Offset.Zero)
                                val bounds = RectF(at.x, at.y, at.x + coordinates.size.width, at.y + coordinates.size.height)
                                coordinateOwner.publish(coordinateOwner.rootScope, rootBinding, coordinates,
                                    androidx.compose.ui.geometry.Offset.Zero, null, NativeTextClip.rectangle(bounds),
                                    current = { coordinates.isAttached }, reveal = { target, complete ->
                                        complete(target.left >= bounds.left && target.right <= bounds.right &&
                                            target.top >= bounds.top && target.bottom <= bounds.bottom)
                                        val cancellation: () -> Unit = {}
                                        cancellation
                                    })
                            }) {
                        Column(Modifier.safeDrawingPadding().padding(24.dp)
                            .background(androidx.compose.ui.graphics.Color.White)
                            .testTag("clipped-terminal-paint").focusRequester(focusDestination).focusable()) {
                            StyledText(current.value, Modifier.width(300.dp), style = style,
                                onLink = onLink, preserveWhitespace = true)
                            StyledText(visible, Modifier.width(300.dp), style = style,
                                onLink = onLink, preserveWhitespace = true)
                        }
                        }
                    }
                }
            } }
            fun views(root: View): List<NativeFloatTextView> = buildList {
                if (root is NativeFloatTextView) add(root)
                if (root is android.view.ViewGroup)
                    for (index in 0 until root.childCount) addAll(views(root.getChildAt(index)))
            }
            fun actual(text: String = expected): NativeFloatTextView {
                val all = views(compose.activity.window.decorView).filter {
                    it.currentMeasuredGeometry?.text?.isNotEmpty() == true
                }
                assertEquals("one actual native owner and one independent reference", 2, all.size)
                val measured = all.filter { it.currentMeasuredGeometry?.text?.toString() == text }
                assertEquals("exactly one successful native owner for $text", 1, measured.size)
                return measured.single()
            }
            fun capturedPaint(): Pair<IntArray, IntArray> {
                lateinit var rectangles: List<Rect>
                compose.runOnIdle {
                    assertPhysicalActivity(compose.activity)
                    focusDestination.requestFocus()
                    val owners = listOf(actual(), actual(visibleExpected))
                    owners.forEach { owner ->
                        if (owner.selectionActive) {
                            assertTrue(owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN,
                                android.view.KeyEvent.KEYCODE_ESCAPE)))
                            owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP,
                                android.view.KeyEvent.KEYCODE_ESCAPE))
                        }
                        assertFalse(owner.selectionActive)
                    }
                }
                compose.waitForIdle()
                compose.onNodeWithTag("clipped-terminal-paint", useUnmergedTree = true).assertIsFocused()
                compose.runOnIdle {
                    rectangles = listOf(actual(), actual(visibleExpected)).map { owner ->
                        val at = IntArray(2).also(owner::getLocationInWindow)
                        Rect(at[0], at[1], at[0] + owner.width, at[1] + owner.height)
                    }
                }
                val node = compose.onNodeWithTag("clipped-terminal-paint", useUnmergedTree = true)
                val bounds = node.fetchSemanticsNode().boundsInWindow
                val bitmap = node.captureToImage().asAndroidBitmap()
                return try {
                    val pixels = rectangles.map { rectangle ->
                        val x = rectangle.left - bounds.left
                        val y = rectangle.top - bounds.top
                        val left = kotlin.math.round(x).toInt(); val top = kotlin.math.round(y).toInt()
                        assertEquals(x, left.toFloat(), .001f); assertEquals(y, top.toFloat(), .001f)
                        assertTrue(left >= 0 && top >= 0 && rectangle.width() > 0 && rectangle.height() > 0)
                        assertTrue(left + rectangle.width() <= bitmap.width && top + rectangle.height() <= bitmap.height)
                        IntArray(rectangle.width() * rectangle.height()).also {
                            bitmap.getPixels(it, 0, rectangle.width(), left, top, rectangle.width(), rectangle.height())
                        }
                    }
                    pixels[0] to pixels[1]
                } finally { bitmap.recycle() }
            }
            fun sameRect(expected: RectF, actual: RectF) {
                assertEquals(expected.left, actual.left, .001f); assertEquals(expected.top, actual.top, .001f)
                assertEquals(expected.right, actual.right, .001f); assertEquals(expected.bottom, actual.bottom, .001f)
            }
            fun raster(width: Int, height: Int, draw: (android.graphics.Canvas) -> Unit): IntArray {
                assertTrue(width > 0 && height > 0)
                val bitmap = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888)
                return try {
                    draw(android.graphics.Canvas(bitmap))
                    IntArray(width * height).also { bitmap.getPixels(it, 0, width, 0, 0, width, height) }
                } finally { bitmap.recycle() }
            }
            var firstHeight = -1
            var firstCharacters: List<RectF?>? = null
            var firstPixels: IntArray? = null
            fun inspect(label: String, captured: Pair<IntArray, IntArray>) {
                val view = actual()
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                assertEquals(label, expected, view.logicalText.toString())
                assertEquals(label, expected, geometry.text.toString())
                assertFalse(geometry.text.contains('\n')); assertFalse(geometry.text.contains('\ufffc'))
                val surface = checkNotNull(actual(visibleExpected).currentMeasuredGeometry)
                assertEquals(visibleExpected, surface.text.toString())
                assertEquals(0 to visibleExpected.length, surface.lineRange(0))
                assertEquals(surface.caretRect(0).top, surface.caretRect(visibleExpected.length).top, .001f)
                assertEquals(label, surface.height, geometry.height)
                assertEquals(label, surface.width, geometry.width)
                val characters = geometry.characterRects(0, expected.length)
                val referenceCharacters = surface.characterRects(0, visibleExpected.length)
                assertEquals(expected.length, characters.size)
                for (index in expected.indices) {
                    if (index in hiddenStart until hiddenEnd) assertNull("$label hidden character $index", characters[index])
                    else {
                        val visibleIndex = if (index < hiddenStart) index else index - hiddenText.length
                        sameRect(checkNotNull(referenceCharacters[visibleIndex]), checkNotNull(characters[index]))
                    }
                }
                assertTrue(geometry.rectsForRange(hiddenStart, hiddenEnd).isEmpty())
                sameRect(surface.caretRect(hiddenStart), geometry.caretRect(hiddenStart))
                sameRect(surface.caretRect(hiddenStart), geometry.caretRect(hiddenEnd))
                sameRect(surface.caretRect(visibleExpected.length), geometry.caretRect(expected.length))
                // NativeFloatTextView deliberately holds NoPaintGeometry: actual glyphs
                // belong to the Compose context. Compare its real captured paint to the
                // independently rendered ordinary paragraph on that same paint path.
                val painted = captured.first
                assertTrue("$label reference capture contains visible text",
                    captured.second.any { Color.alpha(it) > 0 && it != Color.WHITE })
                assertArrayEquals("$label visible paint is exactly the independent unclipped paragraph",
                    captured.second, painted)
                val selected = raster(geometry.width, geometry.height) { canvas ->
                    geometry.paintSelection(canvas, hiddenStart, hiddenEnd, Paint().apply { color = Color.MAGENTA })
                }
                assertTrue("$label clipped selection has no paint", selected.all { it == Color.TRANSPARENT })
                view.setSelection(0, expected.length)
                assertEquals(expected, view.selectedTextForCopy())
                view.setSelection(hiddenStart, hiddenEnd)
                assertEquals(hiddenText, view.selectedTextForCopy())
                val nodes = geometry.nodes.filter { it.clippedAbsoluteLocation != null }
                assertEquals("$label two original child actions, no punctuation/owner action", 2, nodes.size)
                assertEquals("$label no synthetic punctuation action", nodes.map { it.id },
                    geometry.nodes.filter { it.onClick != null || it.onLongClick != null }.map { it.id })
                assertEquals(listOf(hiddenStart to hiddenStart + internal.text.length,
                    hiddenStart + internal.text.length to hiddenEnd), nodes.map { it.start to it.end })
                val beforeLinks = links.size
                val beforeUrls = urls.size
                nodes.forEachIndexed { index, node ->
                    val original = if (index == 0) internal else external
                    assertEquals(original.text, node.label.toString())
                    assertEquals(original.tooltip, node.tooltip)
                    assertTrue(node.bounds.isEmpty())
                    assertFalse(node.contains(checkNotNull(node.clippedAbsoluteLocation).bounds.centerX(),
                        checkNotNull(node.clippedAbsoluteLocation).bounds.centerY()))
                    val provider = view.accessibilityNodeProvider
                    val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                    try {
                        assertEquals(original.text, info.text.toString())
                        assertEquals(original.tooltip, info.tooltipText.toString())
                        assertTrue(info.isVisibleToUser)
                        assertTrue(info.isClickable)
                    } finally { info.recycle() }
                    assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                }
                assertEquals(listOf(internal.entryLink()), links.drop(beforeLinks))
                assertEquals(listOf(external.target), urls.drop(beforeUrls))
                if (firstHeight < 0) {
                    firstHeight = geometry.height
                    firstCharacters = characters.map { it?.let(::RectF) }
                    firstPixels = painted
                } else {
                    assertEquals(firstHeight, geometry.height)
                    assertEquals(firstCharacters, characters)
                    assertArrayEquals(checkNotNull(firstPixels), painted)
                }
            }
            compose.waitForIdle()
            val terminalPaint = capturedPaint()
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                assertEquals(listOf("Clipped absolute mixed structural source is unavailable"), failures)
                inspect("terminal native", terminalPaint)
                assertEquals("Before ${hiddenText}字ji After", rubyGraphicalText(source))
                assertSame(clipped, source[1]); assertSame(ruby, source[2])
                assertSame(internal, checkNotNull(clipped.clippedAbsolute).children[0])
                assertSame(external, checkNotNull(clipped.clippedAbsolute).children[1])
                current.value = recovery
            }
            compose.waitForIdle()
            val recoveredPaint = capturedPaint()
            compose.runOnIdle {
                inspect("simple clipped recovery", recoveredPaint)
                // The terminal projection produced one real native owner, not another failed
                // recursive pass. Recovery adds no new refusal and keeps the original carrier.
                assertEquals(listOf("Clipped absolute mixed structural source is unavailable"), failures)
                assertEquals(listOf(internal.entryLink(), internal.entryLink()), links)
                assertEquals(listOf(external.target, external.target), urls)
                assertSame(clipped, recovery[1])
                assertEquals("", clipped.text); assertEquals("", clipped.trail)
                assertEquals(listOf(base), checkNotNull(ruby.ruby).segments.single().bases.single().spans)
                assertEquals(listOf(reading), checkNotNull(ruby.ruby).segments.single().annotations.single().spans)
            }
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
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
