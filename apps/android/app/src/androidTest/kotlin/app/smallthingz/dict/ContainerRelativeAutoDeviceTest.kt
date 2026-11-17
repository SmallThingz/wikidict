package app.smallthingz.dict

import android.graphics.Rect
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ContainerRelativeAutoDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun group(children: List<Block>, style: ContainerStyle) =
        Block("container", 0, emptyList(), container = Container(children, style))
    private fun body(positioned: Boolean, tableFirst: Boolean): List<Block> {
        val head = group(listOf(Block("paragraph", 0,
            listOf(Span("link", "HEAD", target = "head-target", foreground = "#ff0000")))),
            ContainerStyle(height = px(32f), ownerFontScale = 2f,
                background = ContainerColor.Rgb("#ffff00"),
                positioning = if (positioned) ContainerPositioning.RelativeAuto else null))
        // The ordinary outer owner has zero used height. Its real child keeps positive ink.
        val headOwner = group(listOf(head), ContainerStyle(height = px(0f)))
        val cell = group(listOf(Block("paragraph", 0,
            listOf(Span("link", "TABLE_TARGET_EXPOSED", target = "table-target", foreground = "#ffffff")))),
            ContainerStyle(ownerFontScale = 1f))
        val table = Block("table", 0, emptyList(), table = Table(emptyList(),
            listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(cell), background = "#0000ff"))),
            style = TableStyle(background = "#0000ff", width = StyleWidth(StyleWidthUnit.Px, 300f))))
        val tableOwner = group(listOf(table), ContainerStyle(height = px(0f)))
        return if (tableFirst) listOf(tableOwner, headOwner) else listOf(headOwner, tableOwner)
    }
    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: View) {
                if (view is NativeFloatTextView) result += view
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(activity.window.decorView)
        }
        return result
    }
    private fun node(owner: NativeFloatTextView, label: String): AccessibilityNodeInfo {
        var result: AccessibilityNodeInfo? = null
        compose.runOnIdle { result = checkNotNull(owner.accessibilityNodeProvider
            .findAccessibilityNodeInfosByText(label, View.NO_ID)).single() }
        return checkNotNull(result)
    }
    private fun point(owner: NativeFloatTextView, x: Float, y: Float,
        root: androidx.compose.ui.geometry.Rect): Offset {
        val screen = IntArray(2); val window = IntArray(2)
        compose.runOnIdle { owner.getLocationOnScreen(screen); owner.getLocationInWindow(window) }
        return Offset(x - screen[0] + window[0] - root.left, y - screen[1] + window[1] - root.top)
    }
    private fun evidence(tag: String, label: String): android.graphics.Bitmap {
        val root = compose.onNodeWithTag(tag)
        val image = root.captureToImage()
        val report = renderedLayoutFailureEvidence(label, null, null, root,
            "relative-auto native paint and input order", image.asAndroidBitmap())
        InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
            putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
        })
        check("OWNED_PNG_BEGIN $label " in report)
        return image.asAndroidBitmap()
    }

    @Test fun actualEntryRelativeHeaderRanksAboveRealTableWithStableTextAndChildOwners() {
        val mode = mutableStateOf(0)
        val opened = mutableListOf<String>()
        var rootWindow = androidx.compose.ui.geometry.Rect.Zero
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, if (mode.value == 2) 1.25f else 1f)) {
                    DictTheme("light") { MaterialTheme(typography = MaterialTheme.typography.copy(
                        bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 20.sp))) {
                        Box(Modifier.width(if (mode.value == 2) 420.dp else 380.dp).height(550.dp).testTag("relative-entry")
                            .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                            EntryView(Entry("Relative", emptyList(), "language", "English", "en",
                                listOf(Section(2, "", body(mode.value != 0, mode.value == 3))), emptyList()),
                                false, {}, onLink = { opened += it.target },
                                settings = AppSettings(allowImages = false, allowAudio = false,
                                    collapseOtherSections = false, collapseDetails = false))
                        }
                    } }
                }
            } }
            var firstText: NativeFloatTextView? = null
            var firstTable: NativeFloatTextView? = null
            var originalText = ""
            var originalHeadBox: Rect? = null
            for (state in 0..3) {
                compose.runOnIdle { mode.value = state }; compose.waitForIdle()
                val text = views().single { it.logicalText.contains("HEAD") }
                val table = views().single { it.logicalText.contains("TABLE_TARGET_EXPOSED") }
                assertNotSame(text, table)
                if (state == 0) { firstText = text; firstTable = table; originalText = text.logicalText.toString() }
                if (state in 1..2) { assertSame(firstText, text); assertSame(firstTable, table) }
                if (state in 1..2) assertEquals(originalText, text.logicalText.toString())
                val headNode = node(text, "HEAD")
                val tableNode = node(table, "TABLE_TARGET_EXPOSED")
                assertTrue(headNode.isClickable && tableNode.isClickable)
                assertTrue(headNode.isVisibleToUser && tableNode.isVisibleToUser)
                val headBox = Rect().also(headNode::getBoundsInScreen)
                val tableBox = Rect().also(tableNode::getBoundsInScreen)
                if (state == 0) originalHeadBox = Rect(headBox)
                if (state == 1) assertEquals(originalHeadBox, headBox)
                val overlap = Rect(headBox)
                assertTrue("The original header and real table link must overlap", overlap.intersect(tableBox))
                assertTrue("The real table retains an exposed action interval", tableBox.right > headBox.right + 8)
                val bitmap = evidence("relative-entry", "native-relative-entry-$state.png")
                val first = point(text, overlap.left.toFloat(), overlap.top.toFloat(), rootWindow)
                var red = 0
                var yellow = 0
                for (y in maxOf(0, first.y.toInt()) until minOf(bitmap.height, first.y.toInt() + overlap.height()))
                    for (x in maxOf(0, first.x.toInt()) until minOf(bitmap.width, first.x.toInt() + overlap.width())) {
                        val p = bitmap.getPixel(x, y)
                        if (android.graphics.Color.red(p) > 170 && android.graphics.Color.green(p) < 100 &&
                            android.graphics.Color.blue(p) < 100) red++
                        if (android.graphics.Color.red(p) > 220 && android.graphics.Color.green(p) > 220 &&
                            android.graphics.Color.blue(p) < 50) yellow++
                    }
                if (state == 0) { assertEquals(0, red); assertEquals(0, yellow) }
                else { assertTrue("Positioned glyph ink survives later opaque table", red > 5)
                    assertTrue("The complete positioned background survives too", yellow > 10) }
                val hit = point(text, overlap.exactCenterX(), overlap.exactCenterY(), rootWindow)
                compose.onNodeWithTag("relative-entry").performTouchInput { click(hit) }
                compose.waitForIdle()
                assertEquals(if (state == 0) "table-target" else "head-target", opened.last())
                val exposed = point(table, tableBox.right - 2f, tableBox.exactCenterY(), rootWindow)
                compose.onNodeWithTag("relative-entry").performTouchInput { click(exposed) }
                compose.waitForIdle()
                assertEquals("table-target", opened.last())
                compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                if (state == 3) assertTrue(text.logicalText.indexOf('\ufffc') < text.logicalText.indexOf("HEAD"))
            }
            assertEquals(listOf("table-target", "table-target", "head-target", "table-target",
                "head-target", "table-target", "head-target", "table-target"), opened)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun positionedGroupRetainsAncestorClipAndDoesNotTransferAGestureToTheTable() {
        val clipped = mutableStateOf(false)
        val positioned = mutableStateOf(true)
        val opened = mutableListOf<String>()
        var rootWindow = androidx.compose.ui.geometry.Rect.Zero
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    DictTheme("light") { MaterialTheme(typography = MaterialTheme.typography.copy(
                        bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 20.sp))) {
                        Box(Modifier.width(380.dp).height(120.dp).background(Color.White).testTag("relative-clip")
                            .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                            Box(Modifier.width(360.dp).height(if (clipped.value) 6.dp else 100.dp).clipToBounds()) {
                                NativeFloatBlockContext(body(positioned.value, false), { opened += it.target },
                                    "relative-control", Modifier, inCell = false, gridPath = "relative-control",
                                    gapDp = 6f, trailingGap = true, documentSurface = true, positionedPaintRoot = true)
                            }
                        }
                    } }
                }
            } }
            compose.waitForIdle()
            val text = views().single { it.logicalText.contains("HEAD") }
            val table = views().single { it.logicalText.contains("TABLE_TARGET_EXPOSED") }
            val headBox = Rect().also(node(text, "HEAD")::getBoundsInScreen)
            val tableBox = Rect().also(node(table, "TABLE_TARGET_EXPOSED")::getBoundsInScreen)
            val overlap = Rect(headBox); assertTrue(overlap.intersect(tableBox))
            val hit = point(text, overlap.exactCenterX(), overlap.exactCenterY(), rootWindow)
            val textEvents = mutableListOf<Int>()
            val tableEvents = mutableListOf<Int>()
            compose.runOnIdle {
                text.setOnTouchListener { _, event -> textEvents += event.actionMasked; false }
                table.setOnTouchListener { _, event -> tableEvents += event.actionMasked; false }
            }
            // A DOWN accepted by the positioned text cannot transfer to the table when the
            // style changes while that same gesture is held.
            compose.onNodeWithTag("relative-clip").performTouchInput { down(hit) }
            compose.runOnIdle { positioned.value = false }; compose.waitForIdle()
            compose.onNodeWithTag("relative-clip").performTouchInput { up() }
            compose.waitForIdle()
            assertTrue(textEvents.contains(MotionEvent.ACTION_DOWN) && textEvents.contains(MotionEvent.ACTION_UP))
            assertFalse(tableEvents.contains(MotionEvent.ACTION_DOWN))
            // The dispatch owner stays latched. Activation is resolved against the current
            // text geometry and may cancel; it must never transfer to the newly higher table.
            assertFalse(opened.contains("table-target"))
            assertSame(text, views().single { it.logicalText.contains("HEAD") })
            assertSame(table, views().single { it.logicalText.contains("TABLE_TARGET_EXPOSED") })
            compose.runOnIdle { opened.clear(); positioned.value = true; clipped.value = true }; compose.waitForIdle()
            val image = evidence("relative-clip", "native-relative-ancestor-clip.png")
            for (y in 8 until image.height) for (x in 0 until image.width)
                assertEquals("No deferred paint may escape the existing ancestor clip", android.graphics.Color.WHITE, image.getPixel(x, y))
            compose.onNodeWithTag("relative-clip").performTouchInput { click(Offset(30f, 30f)) }
            compose.waitForIdle()
            assertTrue("Clipped deferred text and table may not receive an outside touch", opened.isEmpty())
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun unjoinedFigureAndTableCaptionOwnersKeepOriginalBodyAndActionsVisible() {
        val mode = mutableStateOf(0)
        val opened = mutableListOf<String>()
        fun edges() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        fun tree(): Block {
            val style = if (mode.value == 1) ContainerStyle(columns = ContainerColumns(2, px(8f)))
                else ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
            val caption = group(listOf(Block("paragraph", 0,
                listOf(Span("link", "caption-body", target = "caption-target")))), style)
            if (mode.value == 2) return Block("table", 0, emptyList(), table = Table(emptyList(),
                listOf(listOf(Cell(emptyList(), false, 1, 1))), captionBlocks = listOf(caption)))
            return Block("paragraph", 0, emptyList(), figure = Figure(
                FigureContent.Missing(Span("link", "figure-body", target = "figure-target"), px(100f), px(20f)),
                FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, edges(), edges(), edges(),
                1f, px(20f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
                FigureColor.Rgb("#000000"), FigureColor.Transparent, captionBlocks = listOf(caption)))
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { DictTheme("light") {
                Box(Modifier.width(380.dp).height(500.dp).testTag("relative-refusal")) {
                    EntryView(Entry("Refusal", emptyList(), "language", "English", "en",
                        listOf(Section(2, "", listOf(tree()))), emptyList()), false, {},
                        onLink = { opened += it.target }, settings = AppSettings(allowImages = false, allowAudio = false,
                            collapseOtherSections = false, collapseDetails = false))
                }
            } } }
            for (state in 0..2) {
                compose.runOnIdle { mode.value = state }; compose.waitForIdle()
                evidence("relative-refusal", "native-relative-owner-refusal-$state.png")
                compose.onAllNodesWithText("Unable to display this layout.").onFirst().assertIsDisplayed()
                val label = compose.onNodeWithText("caption-body", useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                label.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                label.performTouchInput { click(layouts.single().getBoundingBox(2).center) }
                compose.waitForIdle()
                assertEquals("caption-target", opened.last())
                if (state != 2) compose.onNodeWithText("figure-body", useUnmergedTree = true).assertIsDisplayed()
            }
            assertEquals(List(3) { "caption-target" }, opened)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    /** Direct typed, source-shaped synthetic control: no earned FR media IR or source rendition.
     * The real source requests an auto-width right float Table and a left-floated image240.
     * This fixture supplies its own 240x144 asset and explicit test typography/zero grid edges.
     */
    @Test fun absoluteLabelsKeepNearestRelativePaddingOriginInsideARealFloatingTable() {
        val phase = mutableStateOf(0)
        val opened = mutableListOf<String>()
        val failures = mutableListOf<String>()
        val figureImage = InlineImage("Synthetic-FR-relative.png", widthPx = 240,
            alt = "Synthetic floated image")
        val imageSpan = Span("text", "", image = figureImage)
        val labels = listOf(
            Span("link", "Repère", "relative-anchor", foreground = "#008000"),
            Span("link", "CHEVAUCHE", "earlier-label", foreground = "#d00000"),
            Span("link", "CHEVAUCHE", "later-label", foreground = "#0000d0"),
            Span("external_link", "Cible externe", "https://example.test/fr-label", foreground = "#000000"),
            Span("text", "Ici", bold = true, foreground = "#000000"))
        val reference = Span("text", "Repère", foreground = "#707070")
        val referenceBreak = Span("line_break", "")
        // Real ordinary source lines cover the nearby labels in the later CB controls.
        // They are not a fake document surface or a height-only spacer.
        val referenceLines = listOf(reference) + List(6) { Span("text", "Repère", foreground = "#707070") }
        val referenceSpans = referenceLines.flatMapIndexed { index, span ->
            if (index == 0) listOf(span) else listOf(referenceBreak, span)
        }
        val font = InlineFontSnapshot(18f, FontScaleBasis.CssPx, fontNormalized = true, language = "fr")
        fun zero() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        fun paragraph(span: Span) = Block("paragraph", 0, listOf(span), style = BlockStyle(margins = zero()))
        fun label(index: Int, oversized: Boolean = false, fractional: Boolean = false, leftward: Boolean = false, direct: Boolean = false): Block {
            val left = listOf(7f, 20f, 20f, 10f, 70f)[index]
            val top = listOf(13f, 50f, 50f, 92f, 120f)[index]
            return group(listOf(paragraph(labels[index])), ContainerStyle(
                width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px,
                    if (oversized && index == 3) 520f else if (index in 0..2) (if (fractional) 160.5f else 160f) else 120f)),
                height = px(20f), textAlign = if (index in 1..2) CellTextAlign.Right else CellTextAlign.Center,
                lineHeight = ContainerLineHeight.Length(px(20f)), ownerFont = font,
                absolutePosition = ContainerAbsolutePosition(if (leftward && index == 3) SignedContainerMargin(StyleLengthUnit.Px, -400f) else px(if (direct && index == 3) 200f else left), px(if (oversized && index == 3) 900f else top))))
        }
        val originalLabels = labels.indices.map { label(it) }
        val figure = Figure(FigureContent.Image(imageSpan, FigureSizingPolicy.RequestedFit),
            FigureFormat.Thumbnail, FigurePlacement.FloatLeft, FigureClear.None, zero(), zero(), zero(),
            1f, px(20f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent,
            FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent)
        val imageBlock = Block("paragraph", 0, emptyList(), figure = figure)
        val ordered = (0..10).map { state ->
            if (state == 7) listOf(0, 2, 1, 3, 4) else labels.indices.toList()
        }
        val entries = (0..10).map { state ->
            val placed = ordered[state].map { index ->
                if (state in listOf(1, 7, 9) && index == 3) label(index, oversized = true, leftward = state == 7, direct = state == 9)
                else if (state in 6..7 && index in 0..2) label(index, fractional = true)
                else originalLabels[index]
            }
            val content = if (state !in 3..6) listOf(imageBlock) + placed else {
                val moved = state >= 4
                val referenceBlock = Block("paragraph", 0, referenceSpans,
                    style = BlockStyle(margins = zero()))
                val wrapper = group(listOf(referenceBlock) + placed, ContainerStyle(
                    width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, if (state in 6..7) 160.5f else 160f)),
                    clear = FigureClear.Both,
                    margins = StyleEdges(px(if (moved) 179f else 157f), px(0f), px(0f), px(0f)),
                    padding = StyleEdges(px(if (moved) 9f else 5f), px(4f), px(3f), px(if (moved) 13f else 3f)),
                    textAlign = CellTextAlign.Center, ownerFont = font,
                    lineHeight = ContainerLineHeight.Length(px(20f)),
                    positioning = if (state in 5..6) ContainerPositioning.RelativeAuto else null))
                listOf(imageBlock, wrapper)
            }
            val relative = group(content, ContainerStyle(positioning = ContainerPositioning.RelativeAuto,
                overflow = ContainerOverflow.Visible, textWrap = TextWrap.NoWrap,
                // Later synthetic CB controls block top-margin collapse through this parent.
                // The source-shaped first/recovery phases retain the zero-edge relative owner.
                padding = if (state in 3..6) StyleEdges(px(1f), px(0f), px(0f), px(0f)) else null))
            val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
                blocks = listOf(relative)))), geometry = TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0),
                style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Separate,
                    floatSide = TableFloatSide.Right, clear = FigureClear.Right))
            Entry("Synthetic positioned labels", emptyList(), "language", "French", "fr",
                listOf(Section(0, "", listOf(if (state == 9) relative else Block("table", 0, emptyList(), table = table)))), emptyList(),
                media = listOf(Media(figureImage.file, "image", "")), bodyAdjoining = BodyAdjoiningPolicy.Ordinary,
                bodyTypography = if (state == 7) BodyTypography(
                    InlineFontSnapshot(1f, FontScaleBasis.NormalBody, fontNormalized = true, language = "fr"),
                    direction = BidiResolvedDirection.Rtl) else null)
        }.toMutableList().apply {
            this[2] = this[0]; this[8] = this[0]; this[10] = this[0]
        }
        val directory = java.io.File(compose.activity.cacheDir, "absolute-table-${java.util.UUID.randomUUID()}")
            .apply { check(mkdirs()) }
        val bitmap = android.graphics.Bitmap.createBitmap(240, 144, android.graphics.Bitmap.Config.ARGB_8888)
        val png = try {
            bitmap.eraseColor(android.graphics.Color.rgb(220, 220, 220))
            java.io.ByteArrayOutputStream().use { output ->
                check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output)); output.toByteArray()
            }
        } finally { bitmap.recycle() }
        val url = "https://example.test/synthetic-fr-relative.png"
        val cache = MediaCache(compose.activity, directory = directory, metadata = {
            """{"query":{"pages":[{"imageinfo":[{"url":"$url","width":240,"height":144,"mime":"image/png"}]}]}}""".encodeToByteArray()
        }, openMedia = { requested -> check(requested == url); java.io.ByteArrayInputStream(png) })
        val settings = AppSettings(allowImages = true, allowAudio = false, mediaCacheMb = 1,
            collapseOtherSections = false, collapseDetails = false)
        val reading = EntryReadingState()
        val bodyIndex = entryReadingStartIndex(entries.first(), emptySet()) +
            visibleEntryReadingRows(entries.first(), emptySet()).indexOfFirst { it.block != null }
        val focus = androidx.compose.ui.focus.FocusRequester()
        var face: android.graphics.Typeface? = null
        var rootWindow = androidx.compose.ui.geometry.Rect.Zero
        val uriHandler = object : androidx.compose.ui.platform.UriHandler {
            override fun openUri(uri: String) { opened += uri }
        }
        val gridMatcher = SemanticsMatcher("actual table grid") { node ->
            node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag)
                ?.startsWith("compiled-table-grid") == true
        }
        fun grid() = compose.onAllNodes(gridMatcher, useUnmergedTree = true).onFirst()
        fun horizontalRange() = compose.onNodeWithTag("entry-document-scroll").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange]
        fun expectedText(state: Int) = buildString {
            append('\ufffc')
            if (state in 3..6) append('\n').append(referenceLines.joinToString("\n") { it.text })
            ordered[state].forEach { append('\n').append(labels[it].text) }
        }
        fun actualView(state: Int): NativeFloatTextView {
            val candidates = views()
            return compose.runOnIdle { candidates.single { view ->
                view.logicalText.toString() == expectedText(state) &&
                    view.currentMeasuredGeometry?.nodes?.count { it.kind == FloatInteractionKind.LINK } == 4
            } }
        }
        fun rectNear(a: android.graphics.RectF, b: android.graphics.RectF, tolerance: Float = .02f) {
            assertEquals(a.left, b.left, tolerance); assertEquals(a.top, b.top, tolerance)
            assertEquals(a.right, b.right, tolerance); assertEquals(a.bottom, b.bottom, tolerance)
        }
        fun scrollOverflow(state: Int, view: NativeFloatTextView, sourceRtl: Boolean, authoredLeft: Float) {
            val scroll = compose.onNodeWithTag("entry-scroll")
            val viewport = scroll.fetchSemanticsNode().boundsInWindow
            val horizontal = compose.onNodeWithTag("entry-document-scroll")
            val horizontalViewport = horizontal.fetchSemanticsNode().boundsInWindow
            val range = horizontalRange()
            assertEquals(0f, range.value(), .02f)
            var distance = 0f
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val item = geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label.toString() == labels[3].text }
                val at = IntArray(2); view.getLocationInWindow(at)
                val target = item.bounds.single()
                distance = target.centerY() + at[1] + view.paddingTop - viewport.center.y
                assertTrue(distance > 500f)
                // Zero source edges put this left-floated Figure at the relative CB origin.
                // The positive absolute border box contributes all of its declared width,
                // including blank area after its centered text, to the document range.
                val imageLeft = geometry.nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.single().left
                val boxOrigin = imageLeft + at[0] + view.paddingLeft + authoredLeft
                val minimumRange = if (sourceRtl) horizontalViewport.left - boxOrigin
                    else boxOrigin + 520f - horizontalViewport.right
                assertTrue(minimumRange > 0f)
                assertTrue(range.maxValue() >= minimumRange - 1f)
            }
            scroll.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(0f, distance)) }
            compose.waitForIdle()
            var pan = 0f
            compose.runOnIdle {
                val item = checkNotNull(view.currentMeasuredGeometry).nodes.single {
                    it.kind == FloatInteractionKind.LINK && it.label.toString() == labels[3].text
                }
                val at = IntArray(2); view.getLocationInWindow(at)
                pan = if (sourceRtl) horizontalViewport.left - (item.bounds.single().left + at[0] + view.paddingLeft) + 4f
                    else item.bounds.single().right + at[0] + view.paddingLeft - horizontalViewport.right + 4f
                assertTrue(pan > 0f)
            }
            // Foundation's semantic ScrollBy advances ScrollState for positive x in both directions;
            // BODY RTL maps that value to physical movement right, exposing its reachable negative side.
            horizontal.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(pan, 0f)) }
            compose.waitForIdle()
            assertTrue(horizontalRange().value() > 0f)
            assertSame("Scrolling keeps the original cell owner", view, actualView(state))
            lateinit var exposed: android.graphics.RectF
            compose.runOnIdle {
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val item = geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label.toString() == labels[3].text }
                val at = IntArray(2); view.getLocationInWindow(at)
                exposed = android.graphics.RectF(item.bounds.single()).apply {
                    offset(at[0] + view.paddingLeft.toFloat(), at[1] + view.paddingTop.toFloat())
                }
                assertTrue(exposed.top >= viewport.top - 1f && exposed.bottom <= viewport.bottom + 1f)
                assertTrue(exposed.left >= horizontalViewport.left - 1f && exposed.right <= horizontalViewport.right + 1f)
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(item.id))
                try { assertTrue(info.isVisibleToUser); assertTrue(info.isClickable) } finally { info.recycle() }
                assertTrue(reading.scroll.firstVisibleItemIndex == bodyIndex && reading.scroll.firstVisibleItemScrollOffset > 0)
                val before = opened.size
                assertTrue(view.accessibilityNodeProvider.performAction(item.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(before + 1, opened.size); assertEquals(labels[3].target, opened.last())
            }
            assertTrue(exposed.intersect(viewport.left, viewport.top, viewport.right, viewport.bottom))
            val outside = compose.onNodeWithTag("absolute-table-root").captureToImage().asAndroidBitmap()
            try {
                var ink = 0
                for (y in maxOf(0, kotlin.math.floor(exposed.top - rootWindow.top).toInt()) until
                    minOf(outside.height, kotlin.math.ceil(exposed.bottom - rootWindow.top).toInt()))
                    for (x in maxOf(0, kotlin.math.floor(exposed.left - rootWindow.left).toInt()) until
                        minOf(outside.width, kotlin.math.ceil(exposed.right - rootWindow.left).toInt())) {
                        val pixel = outside.getPixel(x, y)
                        if (android.graphics.Color.red(pixel) < 100 && android.graphics.Color.green(pixel) < 100 &&
                            android.graphics.Color.blue(pixel) < 100) ink++
                    }
                assertTrue("The original outside label is actually painted after real Entry scrolling", ink > 5)
            } finally { outside.recycle() }
            val currentPan = horizontalRange().value()
            horizontal.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(-currentPan, 0f)) }
            compose.waitForIdle()
            assertEquals(0f, horizontalRange().value(), .02f)
            scroll.performScrollToIndex(bodyIndex); compose.waitForIdle()
            assertSame(view, actualView(state))
        }
        data class Snapshot(val frame: androidx.compose.ui.geometry.Rect,
            val image: android.graphics.RectF, val anchor: android.graphics.RectF,
            val right: android.graphics.RectF, val reference: android.graphics.RectF?, val text: String, val documentExtent: Int)
        var initial: Snapshot? = null
        var static: Snapshot? = null
        var moved: Snapshot? = null
        var near: Snapshot? = null
        var readyFailures: List<String>? = null
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val zoom = if (phase.value in 6..7) 1.25f else 1f
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalCssPixelTextZoom provides zoom,
                    // The RTL overflow phase uses explicit BODY direction, deliberately opposite this UI.
                    androidx.compose.ui.platform.LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr,
                    LocalInlineImageCache provides cache, androidx.compose.ui.platform.LocalUriHandler provides uriHandler,
                    LocalNativeFloatContextFailureObserver provides { failures += it }) {
                    val resolved = androidx.compose.ui.platform.LocalFontFamilyResolver.current.resolve(
                        androidx.compose.ui.text.font.FontFamily.Monospace,
                        androidx.compose.ui.text.font.FontWeight.Normal,
                        androidx.compose.ui.text.font.FontStyle.Normal,
                        androidx.compose.ui.text.font.FontSynthesis.All).value as android.graphics.Typeface
                    androidx.compose.runtime.SideEffect { face = resolved }
                    DictTheme("light") { MaterialTheme(typography = MaterialTheme.typography.copy(
                        bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 24.sp,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, letterSpacing = 0.sp))) {
                        Box(Modifier.width(if (phase.value in 6..7) 460.dp else 380.dp).height(700.dp)
                            .background(Color.White).testTag("absolute-table-root")
                            .focusRequester(focus).focusable()
                            .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                            EntryView(entries[phase.value], false, {}, onLink = { opened += it.target }, settings = settings, readingState = reading)
                        }
                    } }
                }
            } }
            for (state in 0..8) {
                compose.runOnIdle { phase.value = state }; compose.waitForIdle()
                compose.waitUntil(5000) {
                    val candidates = views()
                    compose.runOnIdle { candidates.any { view -> view.logicalText.toString() == expectedText(state) &&
                        view.currentMeasuredGeometry?.nodes?.any {
                            it.kind == FloatInteractionKind.IMAGE && it.stateDescription.isNullOrEmpty()
                        } == true } }
                }
                compose.waitForIdle()
                compose.onAllNodesWithText("Unable to display this layout.", useUnmergedTree = true).assertCountEquals(0)
                val view = actualView(state)
                compose.onAllNodes(gridMatcher, useUnmergedTree = true).assertCountEquals(1)
                val frame = grid().fetchSemanticsNode().boundsInWindow
                assertEquals("Only the real Figure determines this zero-edge auto Table width", 240f, frame.width, .02f)
                lateinit var snapshot: Snapshot
                lateinit var overlap: android.graphics.RectF
                var overlapWinner = -1
                compose.runOnIdle {
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    assertEquals(expectedText(state), geometry.text.toString())
                    assertEquals(1, geometry.text.count { it == '\ufffc' })
                    val imageNode = geometry.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                    val imageBounds = android.graphics.RectF(imageNode.bounds.single())
                    assertEquals(240f, imageBounds.width(), .02f)
                    assertEquals(144f, imageBounds.height(), .02f)
                    val links = geometry.nodes.filter { it.kind == FloatInteractionKind.LINK }.sortedBy { it.start }
                    val expectedLinks = ordered[state].filter { labels[it].kind != "text" }
                    assertEquals(4, links.size)
                    links.zip(expectedLinks).forEach { (item, index) ->
                        assertEquals(labels[index].text, item.label.toString())
                        assertEquals(labels[index].text, geometry.text.subSequence(item.start, item.end).toString())
                        assertTrue(item.bounds.isNotEmpty())
                        val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(item.id))
                        try { assertEquals(labels[index].text, info.text.toString()); assertTrue(info.isClickable)
                            if (state in listOf(1, 7) && index == 3) assertFalse(info.isVisibleToUser)
                            else {
                                assertTrue(info.isVisibleToUser)
                                val expectedParent = android.graphics.RectF(item.bounds.single()).apply {
                                    offset(view.paddingLeft.toFloat() - view.scrollX, view.paddingTop.toFloat() - view.scrollY)
                                }
                                val expectedBounds = Rect().also(expectedParent::roundOut)
                                val actualBounds = Rect().also(info::getBoundsInParent)
                                assertEquals(expectedBounds, actualBounds)
                            }
                        } finally { info.recycle() }
                    }
                    val anchorNode = links.single { it.label.toString() == labels[0].text }
                    val start = geometry.caretRect(anchorNode.start)
                    val end = geometry.caretRect(anchorNode.end)
                    val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        typeface = checkNotNull(face); textSize = 18f * if (state in 6..7) 1.25f else 1f
                    }
                    assertEquals(paint.measureText(labels[0].text), end.left - start.left, .02f)
                    val at = IntArray(2); view.getLocationInWindow(at)
                    fun inGrid(rect: android.graphics.RectF) = android.graphics.RectF(rect).apply {
                        offset(at[0] + view.paddingLeft - frame.left, at[1] + view.paddingTop - frame.top)
                    }
                    val anchor = inGrid(start)
                    val ref = if (state in 3..6) inGrid(geometry.caretRect(geometry.text.indexOf(reference.text))) else null
                    if (state !in 3..6) {
                        val lineWidth = if (state == 7) 160.5f else 160f
                        val imageLeft = inGrid(imageBounds).left
                        assertEquals(imageLeft + 7f + (lineWidth - paint.measureText(labels[0].text)) / 2f, anchor.left, .02f)
                        val right = links.first { it.label.toString() == labels[1].text }
                        assertEquals(imageLeft + 20f + lineWidth - paint.measureText(labels[1].text),
                            inGrid(geometry.caretRect(right.start)).left, .02f)
                    }
                    if (state in 3..6) {
                        val firstReference = geometry.text.indexOf(reference.text)
                        for (line in 1 until referenceLines.size) {
                            val lineStart = firstReference + line * (reference.text.length + 1)
                            assertEquals("Real BRs keep generic Container LH20 physical while the CSS font zooms", 20f * line,
                                geometry.caretRect(lineStart).top - geometry.caretRect(firstReference).top, .02f)
                        }
                    }
                    val rightNode = links.first { it.label.toString() == labels[1].text }
                    snapshot = Snapshot(frame, inGrid(imageBounds), anchor,
                        inGrid(geometry.caretRect(rightNode.start)), ref, geometry.text.toString(),
                        reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == bodyIndex }.size)
                    if (state in 5..6) {
                        val declaredWidth = if (state in 6..7) 160.5f else 160f
                        // Ordinary reference text retains its existing integer line allocation;
                        // only the absolute label has the new exact Float line width.
                        val centerRemainder = (declaredWidth - kotlin.math.floor(declaredWidth)) / 2f
                        assertEquals(checkNotNull(ref).left + 7f - 13f + centerRemainder, anchor.left, .02f)
                    }
                    view.setSelection(0, view.logicalText.length)
                    assertEquals(expectedText(state), view.selectedTextForCopy())
                    assertTrue(view.accessibilityNodeProvider.performAction(View.NO_ID,
                        AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                    val coincident = links.filter { it.label.toString() == labels[1].text }
                    assertEquals(2, coincident.size)
                    overlap = android.graphics.RectF(coincident.first().bounds.single())
                    assertTrue(overlap.intersect(coincident.last().bounds.single()))
                    overlapWinner = coincident.last().id
                    assertEquals(overlapWinner, geometry.interactionNodeAt(overlap.centerX(), overlap.centerY())?.id)
                    focus.requestFocus()
                }
                compose.waitForIdle()
                when (state) {
                    0 -> { initial = snapshot; readyFailures = failures.toList() }
                    1, 7 -> {
                        val before = checkNotNull(initial)
                        assertEquals(before.frame.width, frame.width, .02f)
                        assertEquals(before.frame.height, frame.height, .02f)
                        rectNear(before.image, snapshot.image)
                        if (state == 1) rectNear(before.anchor, snapshot.anchor)
                        assertEquals(before.text, snapshot.text)
                        assertTrue("Actual document allocation must reach the outside absolute owner", snapshot.documentExtent > before.documentExtent + 700)
                    }
                    2, 8 -> {
                        val before = checkNotNull(initial)
                        assertEquals(before.frame.width, frame.width, .02f)
                        assertEquals(before.frame.height, frame.height, .02f)
                        assertEquals(before.documentExtent, snapshot.documentExtent)
                        rectNear(before.image, snapshot.image)
                        rectNear(before.anchor, snapshot.anchor)
                        assertEquals(before.text, snapshot.text)
                        assertEquals(0f, horizontalRange().maxValue(), .02f)
                        assertEquals(0f, horizontalRange().value(), .02f)
                    }
                    3 -> static = snapshot
                    4 -> {
                        val before = checkNotNull(static)
                        assertEquals(before.frame.width, frame.width, .02f)
                        rectNear(before.image, snapshot.image)
                        rectNear(before.anchor, snapshot.anchor)
                        val afterReference = checkNotNull(snapshot.reference)
                        val beforeReference = checkNotNull(before.reference)
                        assertEquals(26f, afterReference.top - beforeReference.top, .02f)
                        assertEquals(26f, frame.height - before.frame.height, .02f)
                        assertEquals(10f, afterReference.left - beforeReference.left, .02f)
                        assertEquals(before.text, snapshot.text)
                        moved = snapshot
                    }
                    5 -> {
                        val before = checkNotNull(moved)
                        assertEquals(before.frame.width, frame.width, .02f)
                        assertEquals(before.frame.height, frame.height, .02f)
                        rectNear(checkNotNull(before.reference), checkNotNull(snapshot.reference))
                        // The same absolute paragraph keeps its own metric band. Its new CB
                        // starts after the original relative parent's 1px padding and 179px
                        // ordinary margin; the known 144px float cannot supply clearance here.
                        // This compares two Float carets, not Static versus Float selection bands.
                        assertEquals(1f + 179f, snapshot.anchor.top - before.anchor.top, .02f)
                        assertEquals(before.text, snapshot.text)
                        near = snapshot
                    }
                    6 -> {
                        val before = checkNotNull(near)
                        assertEquals(before.frame.width, frame.width, .02f)
                        assertEquals(before.frame.height, frame.height, .02f)
                        rectNear(before.image, snapshot.image)
                        assertEquals(before.text, snapshot.text)
                        if (state == 6) {
                            val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                                typeface = checkNotNull(face)
                            }
                            fun advance(text: String, size: Float): Float { paint.textSize = size; return paint.measureText(text) }
                            val centerGrowth = advance(labels[0].text, 22.5f) - advance(labels[0].text, 18f)
                            val rightGrowth = advance(labels[1].text, 22.5f) - advance(labels[1].text, 18f)
                            // The extra half pixel belongs to the actual line width, not just the outer box.
                            assertEquals(.25f - centerGrowth / 2f, snapshot.anchor.left - before.anchor.left, .02f)
                            assertEquals(.5f - rightGrowth, snapshot.right.left - before.right.left, .02f)
                        }
                    }
                }
                if (state > 0) assertEquals("No new native refusal after the initial asset is Ready", readyFailures, failures)
                if (state in listOf(1, 7)) scrollOverflow(state, view, state == 7, if (state == 7) -400f else 10f)
                // These two original links deliberately paint identical glyphs at one source box.
                // Actual Table/cell rendering, not software geometry paint, determines this raster.
                val window = IntArray(2)
                compose.runOnIdle { view.getLocationInWindow(window) }
                val ox = window[0] + view.paddingLeft - rootWindow.left
                val oy = window[1] + view.paddingTop - rootWindow.top
                val captured = compose.onNodeWithTag("absolute-table-root").captureToImage().asAndroidBitmap()
                var red = 0; var blue = 0
                try {
                    for (y in maxOf(0, kotlin.math.floor(overlap.top + oy).toInt()) until
                        minOf(captured.height, kotlin.math.ceil(overlap.bottom + oy).toInt()))
                        for (x in maxOf(0, kotlin.math.floor(overlap.left + ox).toInt()) until
                            minOf(captured.width, kotlin.math.ceil(overlap.right + ox).toInt())) {
                            val p = captured.getPixel(x, y)
                            if (android.graphics.Color.red(p) > 100 && android.graphics.Color.blue(p) < 50 && android.graphics.Color.green(p) < 50) red++
                            if (android.graphics.Color.blue(p) > 100 && android.graphics.Color.red(p) < 50 && android.graphics.Color.green(p) < 50) blue++
                        }
                    if (state == 7) { assertTrue(red > 5); assertEquals(0, blue) }
                    else { assertTrue(blue > 5); assertEquals(0, red) }
                } finally { captured.recycle() }
                val beforeTouch = opened.size
                compose.onNodeWithTag("absolute-table-root").performTouchInput {
                    click(Offset(overlap.centerX() + ox, overlap.centerY() + oy))
                }
                compose.waitForIdle()
                assertEquals(beforeTouch + 1, opened.size)
                assertEquals(if (state == 7) "earlier-label" else "later-label", opened.last())
                compose.runOnIdle {
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    val links = geometry.nodes.filter { it.kind == FloatInteractionKind.LINK }.sortedBy { it.start }
                    links.zip(ordered[state].filter { labels[it].kind != "text" }).forEach { (item, index) ->
                        if (state in listOf(1, 7) && index == 3) return@forEach // Activated at its real scrolled location above.
                        val before = opened.size
                        assertTrue(view.accessibilityNodeProvider.performAction(item.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                        assertEquals(before + 1, opened.size)
                        assertEquals(labels[index].target, opened.last())
                    }
                    // Stored source owners and Figure stay intact; no ImageMap or synthesized label target.
                    assertSame(figureImage, imageSpan.image)
                    originalLabels.forEachIndexed { index, block ->
                        assertSame(labels[index], checkNotNull(block.container).blocks.single().spans.single())
                    }
                    assertNull(figureImage.map); assertEquals("text", imageSpan.kind); assertTrue(imageSpan.target.isEmpty())
                    assertEquals(4, labels.count { it.kind in listOf("link", "external_link") })
                    assertTrue(labels.last().bold)
                }
            }
            // The same new absolute owner must publish document reach without a Table bridge.
            compose.runOnIdle { phase.value = 9 }; compose.waitForIdle()
            compose.waitUntil(5000) {
                val candidates = views()
                compose.runOnIdle { candidates.any { it.logicalText.toString() == expectedText(9) &&
                    it.currentMeasuredGeometry?.nodes?.count { node -> node.kind == FloatInteractionKind.LINK } == 4 &&
                    it.currentMeasuredGeometry?.nodes?.any { node ->
                        node.kind == FloatInteractionKind.IMAGE && node.stateDescription.isNullOrEmpty()
                    } == true } }
            }
            compose.waitForIdle()
            compose.onAllNodes(gridMatcher, useUnmergedTree = true).assertCountEquals(0)
            compose.onAllNodesWithText("Unable to display this layout.", useUnmergedTree = true).assertCountEquals(0)
            val direct = actualView(9)
            compose.runOnIdle {
                val geometry = checkNotNull(direct.currentMeasuredGeometry)
                assertEquals(expectedText(9), geometry.text.toString())
                assertEquals(1, geometry.text.count { it == '\ufffc' })
                val imageBounds = geometry.nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.single()
                assertEquals(240f, imageBounds.width(), .02f); assertEquals(144f, imageBounds.height(), .02f)
                val outside = geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label.toString() == labels[3].text }
                val info = checkNotNull(direct.accessibilityNodeProvider.createAccessibilityNodeInfo(outside.id))
                try { assertFalse(info.isVisibleToUser); assertTrue(info.isClickable) } finally { info.recycle() }
                assertTrue(reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == bodyIndex }.size >
                    checkNotNull(initial).documentExtent + 700)
                direct.setSelection(0, direct.logicalText.length)
                assertEquals(expectedText(9), direct.selectedTextForCopy())
                assertTrue(direct.accessibilityNodeProvider.performAction(View.NO_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                focus.requestFocus()
            }
            compose.waitForIdle()
            scrollOverflow(9, direct, sourceRtl = false, authoredLeft = 200f)
            assertEquals(readyFailures, failures)
            compose.runOnIdle { phase.value = 10 }; compose.waitForIdle()
            compose.waitUntil(5000) {
                val candidates = views()
                compose.runOnIdle { candidates.any { it.logicalText.toString() == expectedText(10) &&
                    it.currentMeasuredGeometry?.nodes?.count { node -> node.kind == FloatInteractionKind.LINK } == 4 &&
                    it.currentMeasuredGeometry?.nodes?.any { node ->
                        node.kind == FloatInteractionKind.IMAGE && node.stateDescription.isNullOrEmpty()
                    } == true } }
            }
            compose.waitForIdle()
            compose.onAllNodes(gridMatcher, useUnmergedTree = true).assertCountEquals(1)
            val restored = grid().fetchSemanticsNode().boundsInWindow
            assertEquals(checkNotNull(initial).frame.width, restored.width, .02f)
            assertEquals(checkNotNull(initial).frame.height, restored.height, .02f)
            assertEquals(0f, horizontalRange().maxValue(), .02f); assertEquals(0f, horizontalRange().value(), .02f)
            compose.runOnIdle {
                assertEquals(checkNotNull(initial).documentExtent,
                    reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == bodyIndex }.size)
                assertEquals(readyFailures, failures)
            }
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            var cleanupFailure: Throwable? = null
            fun cleanup(action: () -> Unit) {
                try { action() } catch (failure: Throwable) {
                    val previous = cleanupFailure
                    if (previous == null) cleanupFailure = failure else if (previous !== failure) previous.addSuppressed(failure)
                }
            }
            cleanup { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            cleanup { kotlinx.coroutines.runBlocking { cache.clear() } }
            cleanup { check(directory.deleteRecursively()) }
            cleanupFailure?.let { failure ->
                val original = primary
                if (original == null) throw failure else if (original !== failure) original.addSuppressed(failure)
            }
        }
    }

    @androidx.test.filters.SdkSuppress(minSdkVersion = 31)
    @Test fun soleStaticInlineChildUsesParentHypotheticalLineWithoutAddingAFlowLine() {
        // All dimensions/fonts below are synthetic. The source-like first body is only Kept.
        val kept = Span("link", "Kept", target = "static-kept", foreground = "#0033cc",
            fontScale = 18f, fontScaleBasis = FontScaleBasis.CssPx, fontFamily = ContainerFontFamily.SansSerif)
        val words = kept.copy(text = "Kept alpha beta gamma delta epsilon theta kappa lambda sigma omega")
        val directionalWords = words.copy(text = words.text + " ")
        data class Case(val span: Span = kept, val parentPixels: Float = 24f,
            val parentHeight: Float = 60f, val childHeight: Float = 20f,
            val alignment: CellTextAlign = CellTextAlign.Center,
            val direction: ContainerStaticDirection = ContainerStaticDirection.Ltr,
            val parentRtl: Boolean = false, val explicitParentDirection: Boolean = true,
            val nowrap: Boolean = false, val width: Int = 300, val zoom: Float = 1f,
            val bodyDirection: Boolean = false, val uiRtl: Boolean = true)
        val cases = listOf(Case(), Case(alignment = CellTextAlign.Right), Case(parentHeight = 90f),
            Case(childHeight = 36f), Case(parentPixels = 36f),
            Case(directionalWords, direction = ContainerStaticDirection.Inherit, parentRtl = true, uiRtl = false),
            Case(directionalWords, direction = ContainerStaticDirection.Inherit),
            Case(directionalWords, direction = ContainerStaticDirection.Rtl),
            Case(width = 230, zoom = 1.25f), Case(),
            Case(words, parentHeight = 2000f, alignment = CellTextAlign.Left, nowrap = true, uiRtl = false),
            Case(direction = ContainerStaticDirection.Inherit, explicitParentDirection = false, bodyDirection = true, uiRtl = false),
            Case(direction = ContainerStaticDirection.Rtl, explicitParentDirection = false, bodyDirection = true, uiRtl = false), Case())
        fun entry(value: Case): Entry {
            fun font(pixels: Float, bold: Boolean = false) = InlineFontSnapshot(fontScale = pixels,
                fontScaleBasis = FontScaleBasis.CssPx, fontNormalized = true, bold = bold,
                fontFamily = ContainerFontFamily.SansSerif)
            val child = group(listOf(Block("paragraph", 0, listOf(value.span))), ContainerStyle(
                width = ContainerWidth.FitContent, ownerFont = font(18f),
                lineHeight = ContainerLineHeight.Length(px(value.childHeight)), textAlign = CellTextAlign.Left,
                textWrap = if (value.nowrap) TextWrap.NoWrap else TextWrap.Normal,
                absoluteStatic = ContainerAbsoluteStaticPosition(value.direction)))
            val parent = group(listOf(child), ContainerStyle(positioning = ContainerPositioning.RelativeAuto,
                ownerFont = font(value.parentPixels, bold = true), lineHeight = ContainerLineHeight.Length(px(value.parentHeight)),
                textAlign = value.alignment, textWrap = if (value.nowrap) TextWrap.NoWrap else TextWrap.Normal))
            return Entry("Static", emptyList(), "supplemental", null, "",
                listOf(Section(2, "", listOf(parent))), emptyList(), bodyTypography = if (!value.bodyDirection) null else
                    BodyTypography(font(20f), ContainerLineHeight.Length(px(24f)), BidiResolvedDirection.Rtl))
        }
        val entries = cases.map(::entry)
        val empty = entries.first().copy(sections = listOf(Section(2, "", emptyList())))
        val phase = mutableStateOf(0)
        val removed = mutableStateOf(false)
        val reading = EntryReadingState()
        val actions = mutableListOf<EntryLink>()
        val failures = mutableListOf<String>()
        var activity: android.app.Activity? = null
        var parentPixels = 0f
        var childPixels = 0f
        var rootWindow = androidx.compose.ui.geometry.Rect.Zero
        var primary: Throwable? = null
        data class Observed(val first: android.graphics.RectF, val normalHeight: Float, val width: Int)
        val seen = mutableMapOf<Int, Observed>()
        fun currentViews(): List<NativeFloatTextView> {
            val result = mutableListOf<NativeFloatTextView>()
            fun visit(view: View) {
                if (view is NativeFloatTextView && view.isShown) result += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(checkNotNull(activity).window.decorView)
            return result
        }
        fun owner(value: Case): NativeFloatTextView = currentViews().single { view ->
            view.logicalText.toString() == value.span.text && view.currentMeasuredGeometry?.nodes?.count {
                it.kind == FloatInteractionKind.LINK && it.label?.toString() == value.span.text } == 1
        }
        fun sourceCaret(view: NativeFloatTextView, sourceOffset: Int): android.graphics.RectF {
            val geometry = checkNotNull(view.currentMeasuredGeometry) as NativeSurfaceGeometry
            return android.graphics.RectF(checkNotNull(geometry.caretRect(sourceOffset))).apply {
                offset(geometry.surface.left.toFloat(), geometry.surface.top.toFloat())
            }
        }
        fun childPaint() = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            textSize = childPixels; typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.NORMAL)
        }
        fun halfLeadingTop(paint: android.text.TextPaint, height: Float): Float {
            val fm = paint.fontMetrics
            return fm.ascent - (height - (fm.descent - fm.ascent)) / 2f
        }
        fun horizontalRange() = compose.onNodeWithTag("entry-document-scroll").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange]
        fun assertKeptPaint() {
            lateinit var rectangle: android.graphics.RectF
            compose.runOnIdle {
                val view = owner(cases[0])
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val node = geometry.nodes.single { it.kind == FloatInteractionKind.LINK }
                rectangle = android.graphics.RectF(node.bounds.single())
                assertEquals(node.id, geometry.interactionNodeAt(rectangle.centerX(), rectangle.centerY())?.id)
                val location = IntArray(2).also(view::getLocationInWindow)
                rectangle.offset(location[0] + view.paddingLeft - rootWindow.left,
                    location[1] + view.paddingTop - rootWindow.top)
            }
            val bitmap = compose.onNodeWithTag("static-inline-scene").captureToImage().asAndroidBitmap()
            try {
                val left = kotlin.math.floor(rectangle.left).toInt().coerceIn(0, bitmap.width)
                val right = kotlin.math.ceil(rectangle.right).toInt().coerceIn(left, bitmap.width)
                val top = kotlin.math.floor(rectangle.top).toInt().coerceIn(0, bitmap.height)
                val bottom = kotlin.math.ceil(rectangle.bottom).toInt().coerceIn(top, bitmap.height)
                var ink = 0
                for (y in top until bottom) for (x in left until right)
                    if (bitmap.getPixel(x, y) == 0xff0033cc.toInt()) ink++
                assertTrue("The real absolute child paints in its published source region", ink > 2)
            } finally { bitmap.recycle() }
        }
        fun assertSource(value: Case, index: Int) {
            val view = owner(value)
            val geometry = checkNotNull(view.currentMeasuredGeometry) as NativeSurfaceGeometry
            val content = geometry.content
            assertEquals(value.span.text, geometry.text.toString())
            assertEquals(0f, content.extents.usedHeight, .001f)
            assertNull(content.textBaselines?.first); assertNull(content.textBaselines?.last)
            val node = geometry.nodes.single { it.kind == FloatInteractionKind.LINK }
            assertEquals(0, node.start); assertEquals(value.span.text.length, node.end)
            assertEquals(value.span.text, node.label?.toString())
            val parentPaint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                textSize = parentPixels; typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.BOLD)
            }
            val child = childPaint()
            val baseline = -minOf(halfLeadingTop(parentPaint, value.parentHeight), halfLeadingTop(child, value.childHeight))
            val expectedTop = baseline + child.fontMetrics.ascent
            val childBaseline = -halfLeadingTop(child, value.childHeight)
            // Keep the independent selection-band oracle in native Float font metrics.
            val shaped = android.graphics.text.TextRunShaper.shapeTextRun(value.span.text, 0, value.span.text.length,
                0, value.span.text.length, 0f, 0f, false, child)
            assertTrue(shaped.glyphCount() > 0)
            val naturalTop = minOf(child.fontMetrics.ascent, shaped.ascent,
                (0 until shaped.glyphCount()).minOf { glyph ->
                    val metrics = android.graphics.Paint.FontMetrics()
                    shaped.getFont(glyph).getMetrics(child, metrics)
                    metrics.top
                })
            val first = sourceCaret(view, 0)
            assertEquals("Static top uses the declaring ascent, without child half-leading", expectedTop,
                first.top - childBaseline - naturalTop, .02f)
            val rtl = when (value.direction) {
                ContainerStaticDirection.Inherit -> value.parentRtl
                ContainerStaticDirection.Ltr -> false
                ContainerStaticDirection.Rtl -> true
            }
            val maximum = child.measureText(value.span.text)
            val hypothetical = android.text.StaticLayout.Builder.obtain(value.span.text, 0, value.span.text.length,
                child, content.width.coerceAtLeast(1)).setIncludePad(true)
                .setTextDirection(if (rtl) android.text.TextDirectionHeuristics.RTL else android.text.TextDirectionHeuristics.LTR)
                .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE).build()
            val firstAdvance = if (value.nowrap) maximum else hypothetical.getLineMax(0)
            val visualLeft = when (value.alignment) {
                CellTextAlign.Left -> 0f
                CellTextAlign.Center -> (content.width - firstAdvance) / 2f
                CellTextAlign.Right -> content.width - firstAdvance
            }
            val anchor = if (rtl) visualLeft + firstAdvance else visualLeft
            val available = (if (rtl) anchor else content.width - anchor).coerceAtLeast(0f)
            val minimum = if (value.nowrap) maximum else value.span.text.split(' ').maxOf(child::measureText)
            val usedWidth = minOf(maximum, maxOf(minimum, available))
            val expectedLeft = if (rtl) anchor - usedWidth else anchor
            assertEquals("Actual source edge uses parent progression and Float remaining width", expectedLeft, first.left, .02f)
            val ends = if (value.nowrap) listOf(value.span.text.length) else {
                val measured = android.graphics.text.MeasuredText.Builder(value.span.text.toCharArray())
                    .appendStyleRun(child, value.span.text.length, false).build()
                val constraints = android.graphics.text.LineBreaker.ParagraphConstraints().apply { setWidth(usedWidth) }
                val breaker = android.graphics.text.LineBreaker.Builder()
                    .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE).build()
                val result = breaker.computeLineBreaks(measured, constraints, 0)
                List(result.lineCount) { result.getLineBreakOffset(it) }
            }
            var start = 0
            ends.forEach { end ->
                for (offset in start until end) assertEquals(listOf(start to end), geometry.visualLineRanges(offset))
                start = end
            }
            assertEquals(value.span.text.length, start)
            assertEquals(value.span.text.length, geometry.characterRects(0, start).count { it != null })
            if (value.span === directionalWords) {
                assertTrue("Direction contrast must wrap the Latin-only source", ends.size > 1)
                val lastStart = ends[ends.lastIndex - 1]
                val latin = checkNotNull(geometry.characterRects(lastStart, 1).single())
                val space = checkNotNull(geometry.characterRects(start - 1, 1).single())
                assertTrue(space.width() > 0f)
                if (rtl) {
                    assertEquals("RTL paragraph puts its retained final SP before the Latin run", latin.left, space.right, .02f)
                    assertTrue(space.left < latin.left)
                } else {
                    val lastLatin = checkNotNull(geometry.characterRects(start - 2, 1).single())
                    assertEquals("LTR paragraph keeps its final SP after the Latin run", lastLatin.right, space.left, .02f)
                    assertTrue(space.left > latin.left)
                }
            }
            view.setSelection(0, start); assertEquals(value.span.text, view.selectedTextForCopy())
            view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ESCAPE))
            val source = entries[index].sections.single().blocks.single().container!!.blocks.single().container!!
            assertSame(value.span, source.blocks.single().spans.single())
            assertNull(source.style.height); assertEquals(ContainerWidth.FitContent, source.style.width)
            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
            try { assertEquals(value.span.text, info.text?.toString()); assertTrue(info.isClickable) }
            finally { info.recycle() }
            seen[index] = Observed(first, content.extents.usedHeight, content.width)
        }
        try {
            compose.activityRule.scenario.onActivity { host ->
                activity = host
                host.setContent {
                    val value = cases[phase.value]
                    CompositionLocalProvider(LocalDensity provides Density(1f, value.zoom), LocalCssPixelTextZoom provides 1f,
                        androidx.compose.ui.platform.LocalLayoutDirection provides if (value.uiRtl)
                            androidx.compose.ui.unit.LayoutDirection.Rtl else androidx.compose.ui.unit.LayoutDirection.Ltr,
                        LocalNativeFloatContextFailureObserver provides { failures += it }) {
                        val density = LocalDensity.current
                        androidx.compose.runtime.SideEffect {
                            parentPixels = with(density) { value.parentPixels.sp.toPx() }
                            childPixels = with(density) { 18.sp.toPx() }
                        }
                        DictTheme("light") {
                            MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = androidx.compose.ui.text.TextStyle(
                                fontSize = 20.sp, lineHeight = 24.sp, letterSpacing = 0.sp,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.SansSerif,
                                fontWeight = androidx.compose.ui.text.font.FontWeight.Normal,
                                fontStyle = androidx.compose.ui.text.font.FontStyle.Normal,
                                textDirection = if (!value.explicitParentDirection) androidx.compose.ui.text.style.TextDirection.Content
                                    else if (value.parentRtl) androidx.compose.ui.text.style.TextDirection.Rtl
                                    else androidx.compose.ui.text.style.TextDirection.Ltr))) {
                                Box(Modifier.width(value.width.dp).height(300.dp).background(Color.White)
                                    .testTag("static-inline-scene").onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                                    EntryView(if (removed.value) empty else entries[phase.value], false, {},
                                        onLink = { actions += it }, readingState = reading, settings = AppSettings(
                                            allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false))
                                }
                            }
                        }
                    }
                }
            }
            for (index in 0..10) {
                compose.runOnIdle { phase.value = index; failures.clear() }
                compose.waitForIdle()
                compose.runOnIdle { assertTrue(failures.toString(), failures.isEmpty()); assertSource(cases[index], index) }
                if (index == 0) assertKeptPaint()
                if (index < 10) assertEquals(0f, horizontalRange().maxValue(), 1f)
            }
            compose.runOnIdle {
                assertEquals(seen[0], seen[9])
                assertEquals(15f, checkNotNull(seen[2]).first.top - checkNotNull(seen[0]).first.top, .02f)
                assertEquals(8f, checkNotNull(seen[3]).first.top - checkNotNull(seen[0]).first.top, .02f)
                assertNotEquals(checkNotNull(seen[5]).first.left, checkNotNull(seen[6]).first.left)
                val view = owner(cases[10])
                val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.LINK }
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                try { assertFalse(info.isVisibleToUser) } finally { info.recycle() }
            }
            val vertical = compose.onNodeWithTag("entry-scroll")
            val viewport = vertical.fetchSemanticsNode().boundsInWindow
            var distance = 0f
            var held: NativeFloatTextView? = null
            compose.runOnIdle {
                val view = owner(cases[10]); held = view
                val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.LINK }
                val location = IntArray(2).also(view::getLocationInWindow)
                distance = node.bounds.first().centerY() + location[1] + view.paddingTop - viewport.center.y
                assertTrue(distance > 500f)
            }
            vertical.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(0f, distance)) }
            compose.waitForIdle()
            assertTrue(horizontalRange().maxValue() > 0f)
            val pan = horizontalRange().maxValue()
            compose.onNodeWithTag("entry-document-scroll").performSemanticsAction(SemanticsActions.ScrollBy) {
                assertTrue(it(pan, 0f))
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = owner(cases[10]); assertSame(held, view)
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val node = geometry.nodes.single { it.kind == FloatInteractionKind.LINK }
                assertEquals(checkNotNull(seen[10]).width, (geometry as NativeSurfaceGeometry).content.width)
                assertEquals(0f, geometry.content.extents.usedHeight, .001f)
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                try { assertTrue(info.isVisibleToUser); assertEquals(words.text, info.text?.toString()) } finally { info.recycle() }
                val last = checkNotNull(geometry.characterRects(words.text.length - 1, 1).single())
                val location = IntArray(2).also(view::getLocationInWindow)
                assertTrue(last.centerX() + location[0] + view.paddingLeft in rootWindow.left..rootWindow.right)
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink("static-kept")), actions)
                removed.value = true
            }
            compose.waitForIdle()
            compose.onAllNodesWithTag("entry-document-scroll").assertCountEquals(0)
            compose.runOnIdle {
                assertTrue(currentViews().none { it.logicalText.toString() == words.text })
                assertFalse(reading.scroll.canScrollBackward); assertFalse(reading.scroll.canScrollForward)
                phase.value = 11; removed.value = false; failures.clear()
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue(failures.contains("Static inline parent paragraph direction is unresolved"))
                assertSame(kept, entries[11].sections.single().blocks.single().container!!.blocks.single().container!!.blocks.single().spans.single())
            }
            var nativeFallback = false
            compose.runOnIdle {
                val matches = currentViews().flatMap { view -> view.currentMeasuredGeometry?.nodes.orEmpty()
                    .filter { it.onClick != null && it.label?.toString() == kept.text }.map { view to it } }
                assertTrue("Fallback keeps one original action", matches.size <= 1)
                matches.singleOrNull()?.let { (view, node) ->
                    nativeFallback = true
                    assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                }
            }
            if (!nativeFallback) {
                val retained = compose.onNodeWithText(kept.text, useUnmergedTree = true)
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                retained.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val at = layouts.single().getBoundingBox(1).center
                retained.performTouchInput { click(at) }
            }
            compose.runOnIdle {
                assertEquals(listOf(EntryLink("static-kept"), EntryLink("static-kept")), actions)
                phase.value = 12; failures.clear()
            }
            compose.waitForIdle()
            compose.runOnIdle { assertTrue(failures.toString(), failures.isEmpty()); assertSource(cases[12], 12) }
            compose.runOnIdle { phase.value = 13; failures.clear() }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue(failures.toString(), failures.isEmpty()); assertSource(cases[13], 13)
                assertEquals(seen[0], seen[13])
                val view = owner(cases[13])
                val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.LINK }
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                try { assertTrue(info.isFocused); assertTrue(info.isVisibleToUser) } finally { info.recycle() }
                assertTrue(view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                assertEquals(List(3) { EntryLink("static-kept") }, actions)
            }
            assertEquals(0f, horizontalRange().maxValue(), 1f)
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
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

    @androidx.test.filters.SdkSuppress(minSdkVersion = 31)
    @Test fun duplicateStaticParagraphAlignmentPreservesTheChildsWrappedNativeLinesAndOriginalAction() {
        val source = Span("link", "Kept alpha beta gamma delta epsilon theta kappa lambda sigma omega K",
            target = "static-alignment", targetFragment = "original", fontScale = 18f,
            fontScaleBasis = FontScaleBasis.CssPx, fontFamily = ContainerFontFamily.SansSerif)
        data class Case(val alignment: CellTextAlign, val duplicate: Boolean)
        val cases = listOf(Case(CellTextAlign.Center, false), Case(CellTextAlign.Center, true),
            Case(CellTextAlign.Right, false), Case(CellTextAlign.Right, true))
        fun font(size: Float, bold: Boolean = false) = InlineFontSnapshot(fontScale = size,
            fontScaleBasis = FontScaleBasis.CssPx, fontNormalized = true, bold = bold,
            fontFamily = ContainerFontFamily.SansSerif)
        val paragraphs = cases.map { Block("paragraph", 0, listOf(source),
            textAlign = if (it.duplicate) it.alignment else null) }
        val entries = cases.mapIndexed { index, value ->
            val child = group(listOf(paragraphs[index]), ContainerStyle(width = ContainerWidth.FitContent,
                ownerFont = font(18f), lineHeight = ContainerLineHeight.Length(px(20f)),
                textAlign = value.alignment, textWrap = TextWrap.Normal,
                absoluteStatic = ContainerAbsoluteStaticPosition(ContainerStaticDirection.Ltr)))
            val parent = group(listOf(child), ContainerStyle(positioning = ContainerPositioning.RelativeAuto,
                ownerFont = font(24f, bold = true), lineHeight = ContainerLineHeight.Length(px(60f)),
                textAlign = CellTextAlign.Left, textWrap = TextWrap.Normal))
            Entry("Static alignment", emptyList(), "supplemental", null, "",
                listOf(Section(2, "", listOf(parent))), emptyList())
        }
        val phase = mutableStateOf(0)
        val reading = EntryReadingState()
        val followed = mutableListOf<EntryLink>()
        val failures = mutableListOf<String>()
        var activity: android.app.Activity? = null
        var primary: Throwable? = null
        data class Snapshot(val width: Int, val rows: List<Int>, val characters: List<android.graphics.RectF>,
            val carets: List<android.graphics.RectF>, val action: List<android.graphics.RectF>, val normalHeight: Float)
        val snapshots = mutableListOf<Snapshot>()
        fun owner(): NativeFloatTextView {
            val result = mutableListOf<NativeFloatTextView>()
            fun visit(view: View) {
                if (view is NativeFloatTextView && view.isShown && view.logicalText.toString() == source.text) result += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(checkNotNull(activity).window.decorView)
            return result.single()
        }
        fun point(rect: android.graphics.RectF, geometry: NativeSurfaceGeometry) = android.graphics.RectF(rect).apply {
            offset(geometry.surface.left.toFloat(), geometry.surface.top.toFloat())
        }
        try {
            compose.activityRule.scenario.onActivity { host ->
                activity = host
                host.setContent {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalCssPixelTextZoom provides 1f,
                        androidx.compose.ui.platform.LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Rtl,
                        LocalNativeFloatContextFailureObserver provides { failures += it }) {
                        DictTheme("light") {
                            MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = androidx.compose.ui.text.TextStyle(
                                fontSize = 20.sp, lineHeight = 24.sp, letterSpacing = 0.sp,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.SansSerif,
                                fontWeight = androidx.compose.ui.text.font.FontWeight.Normal,
                                fontStyle = androidx.compose.ui.text.font.FontStyle.Normal,
                                textDirection = androidx.compose.ui.text.style.TextDirection.Ltr))) {
                                Box(Modifier.width(280.dp).height(300.dp).background(Color.White)) {
                                    EntryView(entries[phase.value], false, {}, onLink = { followed += it },
                                        readingState = reading, settings = AppSettings(allowImages = false, allowAudio = false,
                                            collapseOtherSections = false, collapseDetails = false))
                                }
                            }
                        }
                    }
                }
            }
            for (index in cases.indices) {
                compose.runOnIdle { phase.value = index; failures.clear() }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertTrue(failures.toString(), failures.isEmpty())
                    val view = owner()
                    val geometry = checkNotNull(view.currentMeasuredGeometry) as NativeSurfaceGeometry
                    val content = geometry.content
                    assertEquals(source.text, geometry.text.toString())
                    assertEquals(0f, content.extents.usedHeight, .001f)
                    assertNull(content.textBaselines?.first); assertNull(content.textBaselines?.last)
                    val action = geometry.nodes.single { it.kind == FloatInteractionKind.LINK }
                    assertEquals(0, action.start); assertEquals(source.text.length, action.end)
                    assertEquals(source.text, action.label?.toString())
                    val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        textSize = 18f
                        typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.NORMAL)
                    }
                    // The actual containing interval is an input, never a synthesized source width.
                    val containing = content.width.toFloat()
                    assertTrue(containing > 0f)
                    assertTrue(paint.measureText(source.text) > containing)
                    assertTrue(source.text.split(' ').maxOf(paint::measureText) < containing)
                    val measured = android.graphics.text.MeasuredText.Builder(source.text.toCharArray())
                        .appendStyleRun(paint, source.text.length, false).build()
                    val constraints = android.graphics.text.LineBreaker.ParagraphConstraints().apply { setWidth(containing) }
                    val breaker = android.graphics.text.LineBreaker.Builder()
                        .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                        .setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE).build()
                    val selected = breaker.computeLineBreaks(measured, constraints, 0)
                    val ends = List(selected.lineCount) { selected.getLineBreakOffset(it) }
                    assertTrue("The real source must wrap and leave a short last row", ends.size > 1)
                    val characters = geometry.characterRects(0, source.text.length).map {
                        point(checkNotNull(it), geometry)
                    }
                    val carets = (0..source.text.length).map { point(checkNotNull(geometry.caretRect(it)), geometry) }
                    var start = 0
                    ends.forEachIndexed { line, end ->
                        var visibleEnd = end
                        if (line != ends.lastIndex) while (visibleEnd > start && source.text[visibleEnd - 1] == ' ') visibleEnd--
                        assertTrue(visibleEnd > start)
                        val advance = paint.measureText(source.text, start, visibleEnd)
                        val shift = when (cases[index].alignment) {
                            CellTextAlign.Center -> (containing - advance) / 2f
                            CellTextAlign.Right -> containing - advance
                            CellTextAlign.Left -> error("This control compares Center and Right against a Left parent")
                        }
                        assertEquals("Child line alignment must not replace the parent's static anchor", shift, carets[start].left, .02f)
                        assertEquals(shift, characters[start].left, .02f)
                        assertEquals(shift + advance, characters[visibleEnd - 1].right, .02f)
                        assertEquals(0f, carets[start].left - shift, .02f)
                        for (offset in start until end) assertEquals(listOf(start to end), geometry.visualLineRanges(offset))
                        if (line == ends.lastIndex) {
                            assertTrue("A short final line discriminates actual Center/Right alignment", containing - advance > 12f)
                            assertTrue(shift > 0f)
                        }
                        start = end
                    }
                    assertEquals(source.text.length, start)
                    val parent = entries[index].sections.single().blocks.single().container!!
                    val child = parent.blocks.single().container!!
                    assertEquals(CellTextAlign.Left, parent.style.textAlign)
                    assertEquals(cases[index].alignment, child.style.textAlign)
                    assertSame(paragraphs[index], child.blocks.single())
                    assertSame(source, child.blocks.single().spans.single())
                    assertEquals(if (cases[index].duplicate) cases[index].alignment else null, child.blocks.single().textAlign)
                    view.setSelection(0, source.text.length)
                    assertEquals(source.text, view.selectedTextForCopy())
                    view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ESCAPE))
                    val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(action.id))
                    try {
                        assertEquals(source.text, info.text?.toString())
                        assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
                    } finally { info.recycle() }
                    if (cases[index].duplicate) {
                        assertTrue(view.accessibilityNodeProvider.performAction(action.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                        assertTrue(view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                        view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                    } else assertTrue(view.accessibilityNodeProvider.performAction(action.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals(List(index + 1) { EntryLink("static-alignment", "original") }, followed)
                    snapshots += Snapshot(content.width, ends, characters, carets,
                        action.bounds.map { point(it, geometry) }, content.extents.usedHeight)
                }
            }
            compose.runOnIdle {
                assertEquals(snapshots[0], snapshots[1]); assertEquals(snapshots[2], snapshots[3])
                assertEquals(snapshots[0].width, snapshots[2].width)
                assertEquals(snapshots[0].rows, snapshots[2].rows)
                assertEquals(snapshots[0].carets.map { it.top }, snapshots[2].carets.map { it.top })
                val lastStart = snapshots[0].rows[snapshots[0].rows.lastIndex - 1]
                assertTrue(snapshots[2].carets[lastStart].left > snapshots[0].carets[lastStart].left)
            }
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }
}
