package app.smallthingz.dict

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Drawable
import android.graphics.drawable.RippleDrawable
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.DeviceFontFamilyName
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.constrainHeight
import kotlin.math.ceil

/** Byte ranges belong to the complete generated label, never to projected document text. */
internal fun nativeDisclosureLabelRange(label: String, start: Long, end: Long): IntRange {
    require(start >= 0 && end > start)
    var bytes = 0L
    var at = 0
    var first = -1
    var last = -1
    while (true) {
        if (bytes == start) first = at
        if (bytes == end) last = at
        if (at == label.length) break
        val codePoint = Character.codePointAt(label, at)
        require(codePoint !in 0xd800..0xdfff)
        bytes += when {
            codePoint <= 0x7f -> 1
            codePoint <= 0x7ff -> 2
            codePoint <= 0xffff -> 3
            else -> 4
        }
        at += Character.charCount(codePoint)
    }
    require(first >= 0 && last > first && end <= bytes)
    return first until last
}

internal data class NativeDisclosureInteraction(val hovered: Boolean = false,
    val active: Boolean = false, val focused: Boolean = false)

internal fun nativeDisclosureLabelAnnotation(label: String, run: ContainerDisclosureLabelRun?,
    interaction: NativeDisclosureInteraction, base: SpanStyle): AnnotatedString {
    val builder = AnnotatedString.Builder(label)
    builder.addStyle(base, 0, label.length)
    run?.let {
        val range = nativeDisclosureLabelRange(label, it.start, it.end)
        val state = when {
            interaction.hovered && interaction.active -> it.paint.hoverActive
            interaction.active -> it.paint.active
            interaction.hovered -> it.paint.hover
            else -> it.paint.normal
        }
        val underline = state.underline || interaction.focused && it.paint.underlineOnFocus
        builder.addStyle(SpanStyle(color = Color(checkNotNull(canonicalColorArgb(state.foreground)).toInt()),
            textDecoration = if (underline) TextDecoration.Underline else TextDecoration.None),
            range.first, range.last + 1)
    }
    return builder.toAnnotatedString()
}

private fun disclosureColor(color: FigureColor): Color = when (color) {
    FigureColor.Transparent -> Color.Transparent
    is FigureColor.Rgb -> Color(checkNotNull(canonicalColorArgb(color.value)).toInt())
    else -> throw UnsupportedFloatLayout("Disclosure color is unavailable")
}

/** One real generated control, independent of the stored body and its authored action graph. */
@Composable
internal fun prepareNativeContainerDisclosureToggle(disclosure: ContainerDisclosure, expanded: Boolean,
    onToggle: () -> Unit, format: NativeContainerTextFormat, direction: BidiResolvedDirection,
    identity: Any): NativeContainerDisclosureToggle {
    val density = LocalDensity.current
    val context = LocalContext.current
    val currentToggle by rememberUpdatedState(onToggle)
    var interaction by remember(identity) { mutableStateOf(NativeDisclosureInteraction()) }
    val activate = remember(identity) { { currentToggle() } }
    val update = remember(identity) { { next: NativeDisclosureInteraction -> interaction = next } }
    val label = if (expanded) disclosure.collapseLabel else disclosure.expandLabel
    val run = if (expanded) disclosure.collapseRun else disclosure.expandRun
    val button = disclosure.button
    val probe = LocalNativeNamedFontProbe.current
    val configuration = LocalConfiguration.current
    val buttonFont = remember(button?.fontFamily, context, configuration, probe) {
        try { Result.success(button?.let {
                if (probe.load(context, it.fontFamily.name, FontWeight.Normal, FontStyle.Normal) == null)
                    throw UnsupportedFloatLayout("Disclosure named font is unavailable: " + it.fontFamily.name)
                // OptionalLocal presence is checked before the matching Compose family request.
                // Availability by name does not prove source/device face or glyph identity.
                FontFamily(Font(DeviceFontFamilyName(it.fontFamily.name), FontWeight.Normal, FontStyle.Normal))
            })
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (failure: Exception) { Result.failure<FontFamily?>(failure) }
    }
    val lineHeight = when (val value = button?.lineHeight) {
        null -> format.lineHeight
        ContainerLineHeight.Normal -> NativeLineHeightPolicy.Normal
        is ContainerLineHeight.Length -> NativeLineHeightPolicy.Pixels(value.value.value * density.density)
        is ContainerLineHeight.Multiplier -> error("Invalid button line height")
    }
    // Null preserves W's declaring font; a button owns its complete typography.
    val declaring = if (button == null) format.ownerFont?.style ?: format.style else TextStyle(
        fontFamily = buttonFont.getOrNull(), fontSize = button.fontSize.value.sp,
        fontWeight = FontWeight.Normal, fontStyle = FontStyle.Normal, textAlign = TextAlign.Center)
    val style = nativeCellLineStyle(declaring, lineHeight, density).copy(
        color = disclosure.foreground?.let(::disclosureColor)
            ?: nativeMarkedCellForeground()?.let { Color(it) } ?: format.style.color,
        background = Color.Transparent)
    val buttonState = button?.state(interaction.hovered, interaction.active)
    val insets = button?.let { nativeDisclosureButtonInsets(it, checkNotNull(buttonState), density.density) }
    val annotated = nativeDisclosureLabelAnnotation(label, run, interaction, style.toSpanStyle())
    // This internal text-only adapter supplies the formatter's real label range. It is never
    // stored, assigned a source path/action, or inserted into the document's logical text.
    val labelSource = remember(identity, label) { listOf(Span("text", label)) }
    val prepareLabel: @Composable () -> PreparedNativeFloatText = {
        prepareNativeFloatText(labelSource, annotated, emptyList(), style,
            style.color, emptyList(), AppSettings(allowImages = false, allowAudio = false), "", {},
            nativeLineHeight = lineHeight, sourceFamily = if (button == null) format.sourceFamily else null,
            ownerDirection = disclosure.direction ?: direction, ownerFont = if (button == null) format.ownerFont else null)
    }
    val prepared = if (button == null) prepareLabel() else {
        // An independent button must not retain a table cell strut or inherited TextStyle
        // after replacing only the label's font. Keep the original path for null buttons.
        var isolated: PreparedNativeFloatText? = null
        CompositionLocalProvider(LocalTextStyle provides style,
            LocalNativeContainerTextContext provides null, LocalNativePreformattedText provides false,
            LocalCellWeight provides null, LocalCellLetterSpacingPixels provides null) {
            isolated = prepareLabel()
        }
        checkNotNull(isolated)
    }
    val native = prepared.native
    val factory = prepared.geometryAtWidth
    val focusPreparation = remember(identity, context, disclosure.focus, button) {
        try { Result.success(if (button == null) nativeDisclosureFocusDrawable(context, disclosure.focus) else null) }
        catch (failure: UnsupportedFloatLayout) { Result.failure(failure) }
    }
    val widths = remember(prepared.revision, insets) {
        try {
            if (native == null || factory == null) throw UnsupportedFloatLayout(
                prepared.stateDescription ?: "Disclosure label typography is unavailable")
            val value = nativeFloatRowIntrinsicWidths(native.source(0), native.paint, native.direction,
                breakWordMinimum = native.breakWordMinimum)
            val box = insets?.horizontal ?: 0f
            Result.success(ContainerWidths(value.minimum + box, value.maximum + box))
        } catch (failure: UnsupportedFloatLayout) { Result.failure(failure) }
    }
    val failure = buttonFont.exceptionOrNull()?.let { it.message ?: "Disclosure named font probe failed" }
        ?: widths.exceptionOrNull()?.message ?: focusPreparation.exceptionOrNull()?.message
    return remember(identity, prepared.revision, expanded, disclosure.focus, focusPreparation, button, buttonState, insets, density.density) {
        NativeContainerDisclosureToggle(identity, label, expanded, disclosure.focus,
            disclosure.direction ?: direction, widths.getOrNull(), failure, focusPreparation.getOrNull(),
            run?.let { nativeDisclosureLabelRange(label, it.start, it.end) }, prepared, factory, activate, update,
            button, buttonState, insets, density.density)
    }
}

private fun nativeDisclosureFocusDrawable(context: Context, focus: ContainerDisclosureFocusPaint?): Drawable? {
    if (focus?.mode == ContainerDisclosureFocusMode.AuthoredNone || focus?.color == FigureColor.Transparent) return null
    val values = context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground))
    val themed = try { values.getDrawable(0)?.mutate() } finally { values.recycle() }
        ?: throw UnsupportedFloatLayout("Native disclosure focus indication is unavailable")
    focus?.color?.let {
        val tint = disclosureColor(it).toArgb()
        if (themed is RippleDrawable) themed.setColor(ColorStateList.valueOf(tint)) else themed.setTint(tint)
    }
    return themed
}

internal class NativeContainerDisclosureToggle internal constructor(
    val identity: Any, val label: String, val expanded: Boolean,
    internal val focus: ContainerDisclosureFocusPaint?, internal val direction: BidiResolvedDirection,
    private val widths: ContainerWidths?, val failureReason: String?, internal val focusPrototype: Drawable?,
    internal val paintRange: IntRange?,
    internal val prepared: PreparedNativeFloatText,
    private val factory: ((Float, List<NativeFloatExclusion>, Boolean) -> NativeFloatGeometry)?,
    internal val activate: () -> Unit,
    internal val interactionChanged: (NativeDisclosureInteraction) -> Unit,
    internal val button: ContainerDisclosureButton? = null,
    internal val buttonState: ContainerDisclosureButtonState? = null,
    private val buttonInsets: NativeDisclosureButtonInsets? = null,
    internal val density: Float = 1f,
) {
    val intrinsic: ContainerWidths get() {
        failureReason?.let { throw UnsupportedFloatLayout(it) }
        return checkNotNull(widths)
    }
    private var measuredWidth = Float.NaN
    private var measured: NativeFloatGeometry? = null
    fun measure(width: Float): NativeFloatGeometry {
        if (width == measuredWidth) measured?.let { return it }
        failureReason?.let { throw UnsupportedFloatLayout(it) }
        val contentWidth = width - (buttonInsets?.horizontal ?: 0f)
        if (!contentWidth.isFinite() || contentWidth < 0f)
            throw UnsupportedFloatLayout("Disclosure allocation is narrower than its button box")
        val result = checkNotNull(factory)(contentWidth, emptyList(), false)
        measuredWidth = width
        measured = result
        return result
    }

    fun measureBox(width: Float): NativeDisclosureViewMeasure {
        val actual = measure(width)
        val insets = buttonInsets
        if (insets == null) {
            val extents = actual.extents.copy(usedWidth = ceil(width).toInt())
            return NativeDisclosureViewMeasure(NativeSurfaceGeometry(actual, NativeSurfaceBox.from(extents)),
                width, actual.textBottom, extents.ink)
        }
        val overflow = nativeDisclosureButtonFocusOverflow(checkNotNull(button), density)
        val extents = nativeDisclosureButtonExtents(width, actual.textBottom, actual.extents, insets, overflow)
        val surface = NativeSurfaceGeometry(actual, NativeSurfaceBox.from(extents), insets.left, insets.top)
        return NativeDisclosureViewMeasure(surface, width, extents.usedHeight, extents.ink)
    }

    @Composable
    fun Content(exactWidth: NativeLayoutInput<Float>) {
        failureReason?.let { ReaderLayoutUnavailable(it); return }
        key(identity) {
            val physical = remember(identity) { NativeLayoutInput<NativeDisclosureViewMeasure?>(null) }
            Layout(modifier = exactWidth.modifier.nativeWidthIntrinsics {
                NativeWidthRange(ceil(intrinsic.minimum).toInt(), ceil(intrinsic.maximum).toInt())
            }, content = {
                AndroidView(factory = { NativeContainerDisclosureView(it) }, modifier = physical.modifier,
                    update = { it.bind(this, physical) }, onRelease = { it.release() })
            }) { measurables, constraints ->
                val width = exactWidth.value
                val measured = measureBox(width)
                val usedWidth = ceil(width).toInt()
                val usedHeight = ceil(measured.logicalHeight).toInt()
                val surface = measured.geometry
                physical.update(measured)
                val child = measurables.single().measure(androidx.compose.ui.unit.Constraints.fixed(surface.width, surface.height))
                if (constraints.constrainWidth(usedWidth) != usedWidth || constraints.constrainHeight(usedHeight) != usedHeight)
                    throw UnsupportedFloatLayout("Disclosure allocation does not contain its native used box")
                layout(usedWidth, usedHeight) { child.place(surface.surface.left, surface.surface.top) }
            }
        }
    }
}

/** A focus-only copy of the same themed drawable used by View's default focus highlight. */
private class NativeDisclosureFocusDrawable(private val owner: NativeContainerDisclosureView, private val child: Drawable) : Drawable(), Drawable.Callback {
    init { child.callback = this }
    override fun draw(canvas: Canvas) {
        child.bounds = owner.logicalFocusBounds()
        if (owner.isFocused && !owner.isInTouchMode) child.draw(canvas)
    }
    override fun onBoundsChange(bounds: Rect) { child.bounds = owner.logicalFocusBounds() }
    override fun onLayoutDirectionChanged(layoutDirection: Int) = child.setLayoutDirection(layoutDirection)
    override fun isStateful() = true
    override fun onStateChange(state: IntArray): Boolean {
        return child.setState(state.filter { value ->
            value != android.R.attr.state_pressed && value != android.R.attr.state_hovered &&
                value != android.R.attr.state_drag_can_accept && value != android.R.attr.state_drag_hovered &&
                (value != android.R.attr.state_focused || !owner.isInTouchMode)
        }.toIntArray())
    }
    override fun setVisible(visible: Boolean, restart: Boolean): Boolean =
        super.setVisible(visible, restart) or child.setVisible(visible, restart)
    override fun jumpToCurrentState() { child.jumpToCurrentState() }
    override fun setAlpha(alpha: Int) { child.alpha = alpha }
    override fun setColorFilter(colorFilter: ColorFilter?) { child.colorFilter = colorFilter }
    @Suppress("DEPRECATION") override fun getOpacity() = PixelFormat.TRANSLUCENT
    override fun invalidateDrawable(who: Drawable) { invalidateSelf() }
    override fun scheduleDrawable(who: Drawable, what: Runnable, `when`: Long) { scheduleSelf(what, `when`) }
    override fun unscheduleDrawable(who: Drawable, what: Runnable) { unscheduleSelf(what) }
    fun release() { child.setState(intArrayOf()); child.jumpToCurrentState(); child.callback = null }
}

internal data class NativeDisclosureViewMeasure(val geometry: NativeSurfaceGeometry,
    val logicalWidth: Float, val logicalHeight: Float, val ink: NativeFloatBounds? = null)

/** Native glyph replay and one real platform Button owner; no document virtual action. */
internal class NativeContainerDisclosureView(context: Context) : View(context) {
    private var control: NativeContainerDisclosureToggle? = null
    private var geometryInput: NativeLayoutInput<NativeDisclosureViewMeasure?>? = null
    private var allocation: NativeDisclosureViewMeasure? = null
    private var focusPolicy: ContainerDisclosureFocusPaint? = null
    private var policyBound = false
    private var focusDrawable: NativeDisclosureFocusDrawable? = null
    private var logicalPointerDown = false
    private var indicatedPointer: android.graphics.PointF? = null
    private var hoveringPointer: android.graphics.PointF? = null
    internal var currentMeasuredGeometry: NativeSurfaceGeometry? = null
        private set
    internal val controlIdentity: Any? get() = control?.identity
    internal val logicalLabel: String get() = control?.label.orEmpty()
    init {
        isClickable = true
        isFocusable = true
        isFocusableInTouchMode = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        minimumWidth = 0
        minimumHeight = 0
        setPadding(0, 0, 0, 0)
        setOnClickListener { control?.activate?.invoke() }
    }
    private val touchModeListener = android.view.ViewTreeObserver.OnTouchModeChangeListener {
        refreshDrawableState()
        invalidate()
    }
    internal fun bind(next: NativeContainerDisclosureToggle, geometry: NativeLayoutInput<NativeDisclosureViewMeasure?>) {
        val before = control
        control = next
        geometryInput = geometry
        layoutDirection = if (next.direction == BidiResolvedDirection.Rtl) LAYOUT_DIRECTION_RTL else LAYOUT_DIRECTION_LTR
        if (!policyBound || focusPolicy != next.focus || before?.button != next.button) {
            focusPolicy = next.focus
            policyBound = true
            focusDrawable?.release()
            focusDrawable = null
            foreground = null
            // The View is a signed ink surface. Its automatic indication belongs to the
            // logical control box inside that surface, not to incidental italic overflow.
            defaultFocusHighlightEnabled = false
            next.focusPrototype?.let { prototype ->
                val themed = (prototype.constantState?.newDrawable(resources, context.theme) ?: prototype).mutate()
                focusDrawable = NativeDisclosureFocusDrawable(this, themed)
                foreground = focusDrawable
            }
            refreshDrawableState()
        }
        stateDescription = if (next.expanded) "Expanded" else "Collapsed"
        if (before?.prepared?.revision !== next.prepared.revision || before?.button != next.button ||
            before?.buttonState != next.buttonState || before?.density != next.density) requestLayout()
        invalidate()
    }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val measured = checkNotNull(geometryInput?.value)
        allocation = measured
        val geometry = measured.geometry
        currentMeasuredGeometry = geometry
        setMeasuredDimension(resolveSize(geometry.width, widthMeasureSpec), resolveSize(geometry.height, heightMeasureSpec))
        publishInteraction()
    }
    override fun getBaseline(): Int = currentMeasuredGeometry?.textBaselines?.first?.let { kotlin.math.round(it).toInt() } ?: -1
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val current = control
        val measured = allocation
        val button = current?.button
        fun atLogicalBox(paint: () -> Unit) {
            val box = measured ?: return
            val saved = canvas.save()
            try { canvas.translate(-box.geometry.surface.left.toFloat(), -box.geometry.surface.top.toFloat()); paint() }
            finally { canvas.restoreToCount(saved) }
        }
        if (current != null && button != null && measured != null) atLogicalBox {
            paintNativeDisclosureButton(canvas, button, button.state(wholeBoxIndicated(hoveringPointer), isPressed),
                current.density, measured.logicalWidth, measured.logicalHeight)
        }
        currentMeasuredGeometry?.paint(canvas)
        if (current != null && button != null && measured != null) atLogicalBox {
            paintNativeDisclosureButtonFocus(canvas, button, current.density, measured.logicalWidth,
                measured.logicalHeight, hasFocus(), hasFocus() && !isInTouchMode)
        }
    }
    override fun drawableStateChanged() {
        super.drawableStateChanged()
        publishInteraction()
    }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        indicatedPointer = screenPoint(event.x, event.y)
        if (event.isFromSource(android.view.InputDevice.SOURCE_MOUSE)) hoveringPointer = indicatedPointer
        else if (event.actionMasked == MotionEvent.ACTION_DOWN) hoveringPointer = null
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            logicalPointerDown = insideLogicalBox(event.x, event.y)
            if (!logicalPointerDown) { indicatedPointer = null; publishInteraction(); return false }
        } else if (logicalPointerDown && event.actionMasked in listOf(MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP) &&
            !insideLogicalBox(event.x, event.y)) {
            logicalPointerDown = false
            indicatedPointer = null
            val cancel = MotionEvent.obtain(event)
            try { cancel.action = MotionEvent.ACTION_CANCEL; super.onTouchEvent(cancel) }
            finally { cancel.recycle() }
            publishInteraction()
            return true
        }
        if (event.actionMasked == MotionEvent.ACTION_CANCEL || event.actionMasked == MotionEvent.ACTION_UP) {
            logicalPointerDown = false
            indicatedPointer = null
        }
        val result = super.onTouchEvent(event)
        publishInteraction()
        return result
    }
    private fun insideLogicalBox(x: Float, y: Float): Boolean {
        val measured = allocation ?: return false
        val localX = x + measured.geometry.surface.left
        val localY = y + measured.geometry.surface.top
        return localX >= 0f && localY >= 0f && localX < measured.logicalWidth && localY < measured.logicalHeight
    }
    override fun onHoverEvent(event: MotionEvent): Boolean {
        hoveringPointer = if (event.actionMasked == MotionEvent.ACTION_HOVER_EXIT) null else screenPoint(event.x, event.y)
        if (event.actionMasked != MotionEvent.ACTION_HOVER_EXIT && !insideLogicalBox(event.x, event.y)) {
            if (isHovered) {
                val exit = MotionEvent.obtain(event)
                try { exit.action = MotionEvent.ACTION_HOVER_EXIT; super.onHoverEvent(exit) }
                finally { exit.recycle() }
            }
            hoveringPointer = null
            publishInteraction()
            return false
        }
        val result = super.onHoverEvent(event)
        publishInteraction()
        return result
    }
    private fun screenPoint(x: Float, y: Float): android.graphics.PointF {
        val point = floatArrayOf(x, y)
        android.graphics.Matrix().also(::transformMatrixToGlobal).mapPoints(point)
        return android.graphics.PointF(point[0], point[1])
    }
    private fun runIndicated(screen: android.graphics.PointF?): Boolean {
        if (screen == null) return false
        val range = control?.paintRange ?: return false
        val actual = currentMeasuredGeometry ?: return false
        val point = floatArrayOf(screen.x, screen.y)
        android.graphics.Matrix().also(::transformMatrixToLocal).mapPoints(point)
        return insideLogicalBox(point[0], point[1]) && actual.rectsForRange(range.first, range.last + 1)
            .any { it.contains(point[0], point[1]) }
    }
    private fun wholeBoxIndicated(screen: android.graphics.PointF?): Boolean {
        if (screen == null) return false
        val point = floatArrayOf(screen.x, screen.y)
        android.graphics.Matrix().also(::transformMatrixToLocal).mapPoints(point)
        return insideLogicalBox(point[0], point[1])
    }
    private fun publishInteraction() {
        val current = control ?: return
        current.interactionChanged.invoke(if (current.button == null)
            NativeDisclosureInteraction(runIndicated(hoveringPointer),
                logicalPointerDown && runIndicated(indicatedPointer), hasFocus())
        else NativeDisclosureInteraction(wholeBoxIndicated(hoveringPointer), isPressed, hasFocus()))
        invalidate()
    }
    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        publishInteraction()
    }
    override fun getAccessibilityClassName(): CharSequence = "android.widget.Button"
    internal fun logicalFocusBounds(): Rect {
        val measured = allocation ?: return Rect()
        val left = -measured.geometry.surface.left
        val top = -measured.geometry.surface.top
        return Rect(left, top, left + ceil(measured.logicalWidth).toInt(), top + ceil(measured.logicalHeight).toInt())
    }
    override fun getFocusedRect(rect: Rect) { rect.set(logicalFocusBounds()) }
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        viewTreeObserver.addOnTouchModeChangeListener(touchModeListener)
    }
    override fun onDetachedFromWindow() {
        viewTreeObserver.removeOnTouchModeChangeListener(touchModeListener)
        super.onDetachedFromWindow()
    }
    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.text = logicalLabel
        info.stateDescription = stateDescription
        val logical = logicalFocusBounds()
        info.setBoundsInParent(logical)
        val visibleSurface = Rect()
        info.getBoundsInScreen(visibleSurface)
        val screen = android.graphics.RectF(logical)
        android.graphics.Matrix().also(::transformMatrixToGlobal).mapRect(screen)
        val screenBounds = Rect()
        screen.roundOut(screenBounds)
        val visible = !screenBounds.isEmpty && screenBounds.intersect(visibleSurface)
        if (!visible) screenBounds.set(screen.left.toInt(), screen.top.toInt(), screen.left.toInt(), screen.top.toInt())
        info.setBoundsInScreen(screenBounds)
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            val onScreen = IntArray(2)
            val inWindow = IntArray(2)
            getLocationOnScreen(onScreen)
            getLocationInWindow(inWindow)
            info.setBoundsInWindow(Rect(screenBounds).apply {
                offset(inWindow[0] - onScreen[0], inWindow[1] - onScreen[1])
            })
        }
        info.isVisibleToUser = info.isVisibleToUser && visible
    }
    internal fun release() {
        control?.interactionChanged?.invoke(NativeDisclosureInteraction())
        control = null
        geometryInput = null
        currentMeasuredGeometry = null
        allocation = null
        logicalPointerDown = false
        indicatedPointer = null
        hoveringPointer = null
        focusDrawable?.release()
        focusDrawable = null
        foreground = null
        setOnClickListener(null)
    }
}
