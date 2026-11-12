package app.smallthingz.dict

import android.graphics.Paint
import android.text.SpannableString
import android.text.TextPaint
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual first intrinsic queries, one caption graph, and translated native selection/action geometry. */
@RunWith(AndroidJUnit4::class)
class FigureTableCaptionDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero = FigurePixelEdges(0f,0f,0f,0f)
    private val edges = FigureBorderEdges(FigureBorderEdge.None,FigureBorderEdge.None,FigureBorderEdge.None,FigureBorderEdge.None)
    private val context = AnonymousFlowContext(BidiResolvedDirection.Ltr,null,null)
    private val style = TextStyle(fontSize=16.sp,lineHeight=24.sp,fontFamily=FontFamily.Monospace)
    private val zeroFont = FigureMediaFont(NativePrimaryFontMetrics(0f,0f,0f,0f),0f)
    private val missingMedia = FigureMediaLayout(FigureMediaStrut(0f,direction=BidiResolvedDirection.Ltr),
        InlineBoxVerticalAlign.Baseline)
    private fun figure(caption: List<Span>): Figure {
        val lengths=StyleEdges(px(0f),px(0f),px(0f),px(0f))
        return Figure(FigureContent.Missing(Span("text","media"),px(80f),px(20f)),
            FigureFormat.Framed,FigurePlacement.None,FigureClear.None,lengths,lengths,lengths,
            1f,px(24f),FigureColor.Transparent,FigureBorder.None,FigureColor.Transparent,FigureBorder.None,
            FigureColor.NativeTheme,FigureColor.Transparent,caption=caption,
            tableCaptionLayout=TableCaptionLayout(TableCollapse.Collapse,ContainerStyle(),edges,edges,missingMedia))
    }

    @Test fun firstIntrinsicQueryMeasuresRealCaptionAndResizeKeepsOneOwnerAndAction() {
        val width=mutableStateOf(900)
        val paint = TextPaint().apply { textSize = 16f; typeface = android.graphics.Typeface.MONOSPACE }
        val word = SpannableString("SUPERCALIFRAGILISTIC")
        val ordinary = nativeTextWidthRange(word, paint)
        val emergency = nativeTextWidthRange(word, paint, breakWordMinimum = true)
        assertEquals(ordinary.maximum, ordinary.minimum)
        assertEquals(ordinary.maximum, emergency.maximum)
        assertTrue(emergency.minimum < 80 && emergency.minimum < ordinary.minimum)
        for (cluster in listOf("a\u0301", "\ud83d\udc69\u200d\ud83d\udc69\u200d\ud83d\udc67\u200d\ud83d\udc66")) {
            val actual = nativeTextWidthRange(SpannableString(cluster), paint, breakWordMinimum = true)
            assertTrue(kotlin.math.abs(actual.maximum - actual.minimum) <= 1)
        }
        val atomic = SpannableString("atomic label").apply { setSpan(object : android.text.style.ReplacementSpan() {
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?) = 96
            override fun draw(canvas: android.graphics.Canvas, text: CharSequence, start: Int, end: Int,
                x: Float, top: Int, y: Int, bottom: Int, paint: Paint) = Unit
        }, 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
        assertEquals(96, nativeTextWidthRange(atomic, paint, breakWordMinimum = true).minimum)
        val caption=listOf(Span("link","WW","caption-target"))
        val largeCaptionStyle = style.copy(fontSize = 160.sp, lineHeight = 192.sp)
        val value=figure(caption)
        val flow=anonymousFlowContent(Block("paragraph",0,emptyList(),figure=value),context)
        val natural=FigureBoxMetrics(FigurePixels(80f,40f),zero,zero,zero,0f,0f)
        val prepared=FigureTableCaptionMetrics(value.tableCaptionLayout!!,natural,1f,16f,false,zeroFont,0f)
        var frame:FloatTextGeometry?=null
        var published:FloatTextGeometry?=null
        var exact:FigureBoxMetrics?=null
        var firstMinimum=-1
        var created=0
        var disposed=0
        var owner:Any?=null
        val clicks=mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f,1f)) {
                    val currentWidth=width.value
                    Layout(content={
                        AnonymousFlowLayout(flow,remember { TextPaint().apply { textSize=16f } },
                            Modifier.testTag("figure-table-flow"),Color.Blue,
                            inline={ _,_ -> SpannableString("") },
                            figureSpec={ _,_ -> AnonymousFigureMeasureSpec(80,FloatMargins(0f,0f,0f,0f),
                                frameMinimumWidens=true,childMinimumFloor=true) },
                            inlineNodes={ emptyList() },semanticGeometry={ _,_,_ -> frame },
                            onGeometry={ published=it }) { _ ->
                            val identity=remember { Any() }
                            DisposableEffect(identity) { created++;onDispose { disposed++ } }
                            SideEffect { owner=identity }
                            FigureChildLayout(natural,{frame=it},null,prepared,caption={ sink ->
                                AnonymousBlockView(Block("paragraph",0,caption),Modifier,{clicks+=it},emptyList(),
                                    AppSettings(allowImages=false,allowAudio=false),"",style=largeCaptionStyle,
                                    onGeometry=sink,interactionOwner=false)
                            }) { metrics, child ->
                                exact=metrics
                                NativeFigureGeometry(metrics,child,FigurePaints(0,0,0,0,0),
                                    { canvas,bounds -> canvas.drawRect(bounds,Paint().apply { color=android.graphics.Color.BLUE }) },
                                    { emptyList() })
                            }
                        }
                    }) { children,_ ->
                        val minimum=children.single().minIntrinsicWidth(Constraints.Infinity)
                        if(firstMinimum<0) firstMinimum=minimum
                        val child=children.single().measure(Constraints.fixedWidth(currentWidth))
                        layout(currentWidth,child.height) { child.place(0,0) }
                    }
                } }
            } }
            compose.waitForIdle()
            var stableOwner:Any?=null
            var stableText=""
            var firstFrameWidth=0
            compose.runOnIdle {
                val box=checkNotNull(exact);val geometry=checkNotNull(published)
                assertTrue(firstMinimum>80)
                assertEquals(firstMinimum,box.width)
                assertEquals((box.width-80f)/2f,box.imageLeft,0f)
                assertEquals("WW",geometry.text.toString())
                assertEquals(1,created);assertEquals(0,disposed)
                stableOwner=owner;stableText=geometry.text.toString();firstFrameWidth=box.width
                val caret=geometry.caretRect(1)
                assertTrue(caret.top>=40f)
                assertTrue(geometry.characterRects(0,geometry.text.length).all { it!=null })
            }
            val wide=compose.onNodeWithTag("figure-table-flow").captureToImage()
            compose.runOnIdle { width.value=64 };compose.waitForIdle()
            compose.runOnIdle {
                assertSame(stableOwner,owner);assertEquals(1,created);assertEquals(0,disposed)
                assertEquals(firstFrameWidth,checkNotNull(exact).width)
                assertEquals(stableText,checkNotNull(published).text.toString())
                assertTrue(checkNotNull(published).extents.ink!!.right>64f)
            }
            compose.runOnIdle { width.value=900 };compose.waitForIdle()
            val returned=compose.onNodeWithTag("figure-table-flow").captureToImage()
            assertEquals(wide.width,returned.width);assertEquals(wide.height,returned.height)
            val originalPixels=wide.toPixelMap();val returnedPixels=returned.toPixelMap()
            assertEquals(Color.Blue,originalPixels[firstFrameWidth/2,20])
            for(y in 0 until wide.height) for(x in 0 until wide.width)
                assertEquals("pixel $x,$y",originalPixels[x,y],returnedPixels[x,y])
            var clickAt: Offset? = null
            compose.runOnIdle {
                val node=checkNotNull(published).nodes.single { it.onClick!=null }
                val bounds=node.bounds.first();clickAt=Offset(bounds.centerX(),bounds.centerY())
            }
            compose.onNodeWithTag("figure-table-flow").performTouchInput { click(checkNotNull(clickAt)) }
            compose.runOnIdle { assertEquals(listOf(EntryLink("caption-target")),clicks);assertSame(stableOwner,owner) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun firstCaptionMinimumTraversesRealNestedTablesWithoutHeightIntrinsicsOrDuplicateOwners() {
        val width = mutableStateOf(900)
        val target = "nested-caption-target"
        val word = "CAPTION_NESTED_UNBREAKABLE_0123456789"
        val nested = Table(listOf(Span("text", "Nested caption")), listOf(
            listOf(Cell(listOf(Span("link", word, target)), false, 1, 1,
                style = CellStyle(minWidth = px(300f)))),
            listOf(Cell(listOf(Span("text", "second cell")), false, 1, 1))))
        val outer = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
            blocks = listOf(Block("paragraph", 0, listOf(Span("text", "before grid"))),
                Block("table", 0, emptyList(), table = nested),
                Block("paragraph", 0, listOf(Span("text", "after grid"))))))))
        val blocks = listOf(Block("paragraph", 0, listOf(Span("text", "caption lead"))),
            Block("table", 0, emptyList(), table = outer),
            Block("paragraph", 0, listOf(Span("text", "caption tail"))))
        val value = figure(emptyList()).copy(captionBlocks = blocks)
        val flow = anonymousFlowContent(Block("paragraph", 0, emptyList(), figure = value), context)
        val natural = FigureBoxMetrics(FigurePixels(80f, 40f), zero, zero, zero, 0f, 0f)
        val prepared = FigureTableCaptionMetrics(value.tableCaptionLayout!!, natural, 1f, 16f, false, zeroFont, 0f)
        var frame: FloatTextGeometry? = null
        var published: FloatTextGeometry? = null
        var firstMinimum = -1
        var minimumAfterResize = -1
        var created = 0
        var disposed = 0
        var owner: Any? = null
        val clicks = mutableListOf<EntryLink>()
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false),
            "", { clicks += it }, Any())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    val currentWidth = width.value
                    Layout(content = {
                        AnonymousFlowLayout(flow, remember { TextPaint().apply { textSize = 16f } },
                            Modifier.testTag("nested-caption-flow"), Color.Blue,
                            inline = { _, _ -> SpannableString("") },
                            figureSpec = { _, _ -> AnonymousFigureMeasureSpec(80, FloatMargins(0f, 0f, 0f, 0f),
                                frameMinimumWidens = true, childMinimumFloor = true) },
                            inlineNodes = { emptyList() }, semanticGeometry = { _, _, _ -> frame },
                            onGeometry = { published = it }) { _ ->
                            val identity = remember { Any() }
                            DisposableEffect(identity) { created++; onDispose { disposed++ } }
                            SideEffect { owner = identity }
                            FigureChildLayout(natural, { frame = it }, null, prepared, caption = { sink ->
                                FigureCaptionBlocks(blocks, context, style, reader, sink)
                            }) { metrics, caption ->
                                NativeFigureGeometry(metrics, caption, FigurePaints(0, 0, 0, 0, 0),
                                    { canvas, bounds -> canvas.drawRect(bounds, Paint().apply { color = android.graphics.Color.BLUE }) },
                                    { emptyList() })
                            }
                        }
                    }) { children, _ ->
                        val minimum = children.single().minIntrinsicWidth(Constraints.Infinity)
                        if (firstMinimum < 0) firstMinimum = minimum
                        minimumAfterResize = minimum
                        val child = children.single().measure(Constraints.fixedWidth(currentWidth))
                        layout(currentWidth, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle()
            var identity: Any? = null
            var originalText = ""
            var originalHeight = 0
            compose.runOnIdle {
                val geometry = checkNotNull(published)
                assertTrue(firstMinimum > 240)
                assertEquals(firstMinimum, checkNotNull(frame).width)
                originalText = geometry.text.toString(); originalHeight = geometry.height; identity = owner
                for (literal in listOf("caption lead", "before grid", "Nested caption", word,
                    "second cell", "after grid", "caption tail")) {
                    assertEquals(literal, 2, originalText.split(literal).size)
                }
                assertEquals(1, geometry.nodes.count { it.onClick != null })
                assertEquals(1, created); assertEquals(0, disposed)
                width.value = 240
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertSame(identity, owner); assertEquals(1, created); assertEquals(0, disposed)
                assertEquals(firstMinimum, minimumAfterResize)
                assertEquals(originalText, checkNotNull(published).text.toString())
                assertTrue(checkNotNull(published).extents.ink!!.right > 240f)
                width.value = 900
            }
            compose.waitForIdle()
            var clickAt: Offset? = null
            compose.runOnIdle {
                val geometry = checkNotNull(published)
                assertEquals(originalHeight, geometry.height)
                assertEquals(originalText, geometry.text.toString())
                val link = geometry.nodes.single { it.onClick != null }
                val bounds = link.bounds.first(); clickAt = Offset(bounds.centerX(), bounds.centerY())
                val start = originalText.indexOf(word)
                assertTrue(geometry.rectsForRange(start, start + word.length).isNotEmpty())
                assertTrue(geometry.caretRect(start).top >= 40f)
            }
            compose.onNodeWithTag("nested-caption-flow").performTouchInput { click(checkNotNull(clickAt)) }
            compose.runOnIdle {
                assertEquals(listOf(EntryLink(target)), clicks)
                assertSame(identity, owner); assertEquals(1, created); assertEquals(0, disposed)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun captionFloatExcludesOnlyItsHeightAndEmptyCaptionRetainsTheActualBox() {
        val enabled=mutableStateOf(true)
        val empty=mutableStateOf(false)
        var text:NativeAnonymousFlowGeometry?=null
        var caption:FloatTextGeometry?=null
        var owners=0
        val before=FigureCaptionFloat(TableFloatSide.Right,15f,11f,FloatMargins(0f,0f,0f,3f))
        val spans=listOf(Span("text","first"),Span("line_break",""),Span("text","abcdefghij"))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f,1f)) {
                    Layout(content={
                        FigureCaptionFloatFlow(if(enabled.value) before else null,context.direction,{caption=it}) { sink ->
                            val identity=remember { Any() }
                            DisposableEffect(identity) { owners++;onDispose { owners-- } }
                            if(empty.value) SelectionEmptyBox(Modifier,sink)
                            else AnonymousBlockView(Block("paragraph",0,spans),Modifier,{},emptyList(),
                                AppSettings(allowImages=false,allowAudio=false),"",style=style,onGeometry=sink,
                                interactionOwner=false,onFlowGeometry={text=it})
                        }
                    }) { children,_ ->
                        val child=children.single().measure(Constraints.fixedWidth(100))
                        layout(100,child.height) { child.place(0,0) }
                    }
                } }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val geometry=checkNotNull(text)
                assertEquals(82f,geometry.firstLineBand().right,0f)
                assertTrue(geometry.rectsForRange(6,16).maxOf { it.right }>82f)
                assertEquals("first\nabcdefghij",checkNotNull(caption).text.toString())
                assertEquals(1,owners)
                enabled.value=false
            }
            compose.waitForIdle()
            compose.runOnIdle { assertEquals(100f,checkNotNull(text).firstLineBand().right,0f);assertEquals(1,owners);empty.value=true;enabled.value=true }
            compose.waitForIdle()
            compose.runOnIdle { assertEquals(11,checkNotNull(caption).height);assertEquals("",checkNotNull(caption).text.toString());assertTrue(checkNotNull(caption).nodes.isEmpty());enabled.value=false }
            compose.waitForIdle()
            compose.runOnIdle { assertEquals(0,checkNotNull(caption).height);assertEquals(1,owners) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun requiredBaseWrapperPlacesTheSameOwnerAcrossOverflowDirectionAndResize() {
        val zeroMargin = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, 0f))
        val auto = ContainerStyle(marginValues = ContainerMargins(zeroMargin, ContainerMargin.Auto,
            zeroMargin, ContainerMargin.Auto))
        val fixed = ContainerStyle(margins = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Px, 0f),
            SignedContainerMargin(StyleLengthUnit.Px, 7f), SignedContainerMargin(StyleLengthUnit.Px, 0f),
            SignedContainerMargin(StyleLengthUnit.Px, 11f)))
        data class Scene(val width: Int, val rtl: Boolean, val wrapper: ContainerStyle, val expectedLeft: Float)
        val scenes = listOf(Scene(100, false, auto, 0f), Scene(100, true, auto, -40f),
            Scene(200, false, auto, 30f), Scene(200, false, fixed, 11f),
            Scene(200, true, fixed, 53f), Scene(200, false, fixed.copy(floatSide = TableFloatSide.Right), 53f),
            Scene(100, false, auto, 0f))
        val scene = mutableStateOf(scenes.first())
        val caption = listOf(Span("link", "owner", "wrapper-target"))
        val source = figure(caption).copy(content = FigureContent.Missing(Span("text", "media"), px(140f), px(20f)),
            placement = FigurePlacement.FloatLeft, clear = FigureClear.Both, frameBackground = FigureColor.Rgb("#0000ff"))
        var geometry: NativeAnonymousFlowGeometry? = null
        var owners = 0
        val actions = mutableListOf<String>()
        fun actualView(): NativeFloatTextView {
            val views = mutableListOf<NativeFloatTextView>()
            compose.activityRule.scenario.onActivity { activity ->
                fun collect(view: android.view.View) {
                    if (view is NativeFloatTextView) views += view
                    if (view is android.view.ViewGroup) for (i in 0 until view.childCount) collect(view.getChildAt(i))
                }
                collect(activity.window.decorView)
            }
            return views.single()
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val current = scene.value
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides if (current.rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                    val value = source.copy(tableCaptionLayout = source.tableCaptionLayout!!.copy(wrapper = current.wrapper))
                    Layout(content = {
                        val identity = remember { Any() }
                        DisposableEffect(identity) { owners++; onDispose { owners-- } }
                        AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = value),
                            Modifier.testTag("base-wrapper-owner"), { actions += it.target }, emptyList(),
                            AppSettings(allowImages = false, allowAudio = false), "", style = style,
                            onFlowGeometry = { geometry = it })
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(current.width))
                        layout(current.width, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle()
            val originalOwner = actualView()
            scenes.forEachIndexed { index, current ->
                compose.runOnIdle { scene.value = current }
                compose.waitForIdle()
                assertSame(originalOwner, actualView())
                var target: Offset? = null
                compose.runOnIdle {
                    val actual = checkNotNull(geometry)
                    val placed = actual.figures.single()
                    assertEquals(140, placed.measured.geometry.width)
                    assertEquals(current.expectedLeft, placed.bounds.left, .01f)
                    assertEquals(140f, placed.bounds.width(), .01f)
                    assertSame(caption, placed.anchor.event.figure.caption)
                    assertEquals(1, owners)
                    val link = actual.nodes.single { it.onClick != null }
                    assertEquals("owner", actual.text.subSequence(link.start, link.end).toString())
                    val bounds = link.bounds.first()
                    val x = bounds.centerX().coerceIn(1f, current.width - 1f)
                    assertTrue(bounds.contains(x, bounds.centerY()))
                    target = Offset(x, bounds.centerY())
                    val visibleNodes = checkNotNull(originalOwner.accessibilityNodeProvider.findAccessibilityNodeInfosByText("owner", -1))
                    assertEquals(1, visibleNodes.size)
                    assertTrue(visibleNodes.single().isClickable)
                    val selection = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, link.start)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, link.end)
                    }
                    assertTrue(originalOwner.performAccessibilityAction(
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
                    assertEquals(link.start, originalOwner.selectionStart)
                    assertEquals(link.end, originalOwner.selectionEnd)
                    selection.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, -1)
                    selection.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, -1)
                    assertTrue(originalOwner.performAccessibilityAction(
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
                }
                val owner = compose.onNodeWithTag("base-wrapper-owner")
                val pixels = owner.captureToImage().toPixelMap()
                val frameX = (current.expectedLeft + 70f).toInt()
                assertEquals(Color.Blue, pixels[frameX, 1])
                owner.performTouchInput { click(checkNotNull(target)) }
                compose.runOnIdle { assertEquals(List(index + 1) { "wrapper-target" }, actions) }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
            compose.runOnIdle { assertEquals(0, owners) }
        }
    }
}
