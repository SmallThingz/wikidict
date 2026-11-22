package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class SpanLinkPaintTest {
    private fun paint(underline: Boolean = false): LinkPaint = LinkPaint(
        FigureLinkState("#123456", underline), FigureLinkState("#234567", true),
        FigureLinkState("#345678", false), FigureLinkState("#789abc", true), FigureLinkState("#456789", false),
        FigureLinkState("#56789a", true), FigureLinkState("#6789ab", false), FigureLinkState("#89abcd", true), true,
        FigureFocusOutline(StyleLength(StyleLengthUnit.Px, 2f), FigureColor.Rgb("#abcdef"),
            StyleLength(StyleLengthUnit.Em, .5f), SignedContainerMargin(StyleLengthUnit.Px, -1.25f)))
    private fun figurePaint() = FigureLinkPaint(FigureLinkState("#123456", false), FigureLinkState("#234567", true),
        FigureLinkState("#345678", false), FigureLinkState("#456789", false),
        FigureLinkState("#56789a", true), FigureLinkState("#6789ab", false), true)
    private fun link(value: LinkPaint? = paint()) = Span("link", "source", "Target", trail = "s",
        language = "mai", classes = "source-link", direction = "ltr", bold = true, italic = true,
        foreground = "#123456", background = "#fedcba", targetFragment = "part", tooltip = "source advice",
        fontScale = 12.375f, fontScaleBasis = FontScaleBasis.CssPx, fontFeatures = FontFeaturePolicy.SevenOn,
        linkPaint = value)
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val edges = StyleEdges(zero, zero, zero, zero)
    private val noBorders = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None,
        FigureBorderEdge.None, FigureBorderEdge.None)
    private fun layout(missing: FigureLinkPaint? = null, caption: FigureLinkPaint? = null) = TableCaptionLayout(
        TableCollapse.Collapse, ContainerStyle(), noBorders, noBorders,
        FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr), InlineBoxVerticalAlign.Baseline),
        missingLinkPaint = missing, captionLinkPaint = caption)
    private fun figure(label: Span = Span("text", "Missing"), caption: List<Span> = emptyList(),
        blocks: List<Block>? = null, owner: TableCaptionLayout? = null) = Figure(
        FigureContent.Missing(label, StyleLength(StyleLengthUnit.Px, 20f), StyleLength(StyleLengthUnit.Em, 1f)),
        FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, edges, edges, edges, 1f,
        StyleLength(StyleLengthUnit.Em, 1.2f), FigureColor.Transparent, FigureBorder.None,
        FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
        caption = caption, captionBlocks = blocks, tableCaptionLayout = owner)

    @Test fun optionalPaintKeepsEveryIndependentFieldAndBothOrdinaryActionKinds() {
        val old = link(null)
        val painted = link()
        assertEquals(old, painted.copy(linkPaint = null))
        assertEquals(paint(), painted.linkPaint)
        assertEquals(painted, painted.copy(foreground = null).copy(foreground = "#123456"))
        val external = painted.copy(kind = "external_link", target = "https://example.invalid/source", targetFragment = null)
        assertEquals(paint(), external.linkPaint)
        assertEquals("s", external.trail); assertEquals("source advice", external.tooltip)
        for (underlined in listOf(false, true)) {
            val source = paint(underlined)
            assertEquals(source, old.copy(underline = underlined, linkPaint = source).linkPaint)
            assertThrows(IllegalArgumentException::class.java) { old.copy(underline = !underlined, linkPaint = source) }
        }
        // The contract requires a nonempty target, independently of display text or whitespace spelling.
        assertEquals(" ", painted.copy(target = " ").target)
        assertEquals("", painted.copy(text = "").text)
    }

    @Test fun wrongOwnersAndConflictingStaticNormalStatesRefuse() {
        val source = link()
        for (kind in listOf("text", "line_break")) assertThrows(IllegalArgumentException::class.java) {
            source.copy(kind = kind, targetFragment = null)
        }
        for (fragment in listOf<String?>(null, "part")) assertThrows(IllegalArgumentException::class.java) {
            source.copy(target = "", targetFragment = fragment)
        }
        val image = InlineImage("Source.svg", widthPx = 40, heightPx = 20)
        val oldImage = source.copy(linkPaint = null, text = "", trail = "", image = image)
        assertEquals(image, oldImage.image)
        assertThrows(IllegalArgumentException::class.java) {
            oldImage.copy(image = image.copy(alt = "Authored alternative"), linkPaint = paint())
        }
        assertThrows(IllegalArgumentException::class.java) { source.copy(foreground = "#654321") }
        assertThrows(IllegalArgumentException::class.java) { source.copy(underline = true) }
        assertThrows(IllegalArgumentException::class.java) { FigureLinkState("#ABCDEF", false) }
        assertThrows(IllegalArgumentException::class.java) {
            paint().copy(focusOutline = paint().focusOutline!!.copy(color = FigureColor.NativeTheme))
        }
    }

    @Test fun missingLabelRejectsOnlyAnActualCompetingPaintOwner() {
        val source = link().copy(trail = "", foreground = null)
        val ordinary = figure(label = source)
        assertSame(source, ordinary.content.span)
        assertThrows(IllegalArgumentException::class.java) {
            (ordinary.content as FigureContent.Missing).copy(linkPaint = MissingLinkPaint.VectorNewLinkV1)
        }
        assertThrows(IllegalArgumentException::class.java) { ordinary.copy(tableCaptionLayout = layout(missing = figurePaint())) }
        val old = source.copy(linkPaint = null)
        assertEquals(MissingLinkPaint.VectorNewLinkV1,
            (ordinary.content as FigureContent.Missing).copy(span = old, linkPaint = MissingLinkPaint.VectorNewLinkV1).linkPaint)
        assertEquals(old, figure(label = old, owner = layout(missing = figurePaint())).content.span)
        assertSame(source, figure(label = source, owner = layout(caption = figurePaint())).content.span)
        assertEquals(listOf(source), figure(label = old, caption = listOf(source),
            owner = layout(missing = figurePaint())).caption)
    }

    @Test fun captionOwnerTraversesContainersTablesCellsAndScopesButStopsAtNestedFigures() {
        val source = link()
        val inline = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Scope(BidiScope(
            BidiMode.Isolate, BidiDirectionInput.Ltr, BidiResolvedDirection.Ltr, "mai",
            listOf(FlowPart.Inline(listOf(source)))))))
        val cell = Cell(emptyList(), false, 1, 1, blocks = listOf(inline))
        val table = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(cell))))
        val container = Block("container", 0, emptyList(), container = Container(listOf(table), ContainerStyle()))
        assertEquals(listOf(source), figure(caption = listOf(source)).caption)
        assertEquals(listOf(container), figure(blocks = listOf(container)).captionBlocks)
        assertThrows(IllegalArgumentException::class.java) { figure(caption = listOf(source), owner = layout(caption = figurePaint())) }
        assertThrows(IllegalArgumentException::class.java) { figure(blocks = listOf(container), owner = layout(caption = figurePaint())) }
        val nested = figure(caption = listOf(source))
        val nestedBlock = Block("paragraph", 0, emptyList(), figure = nested)
        val nestedFlow = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.ImageFigure(nested)))
        for (body in listOf(nestedBlock, nestedFlow)) {
            val outer = figure(blocks = listOf(body), owner = layout(caption = figurePaint()))
            assertSame(body, outer.captionBlocks!!.single())
        }
        assertThrows(IllegalArgumentException::class.java) { nested.copy(tableCaptionLayout = layout(caption = figurePaint())) }
    }

    @Test fun everyOrdinaryBooleanStateIsExplicitWhileFigureKeepsItsOriginalFold() {
        val value = paint()
        val states = mapOf(
            Triple(false, false, false) to value.normal,
            Triple(false, true, false) to value.hover,
            Triple(false, false, true) to value.active,
            Triple(false, true, true) to value.hoverActive,
            Triple(true, false, false) to value.visited,
            Triple(true, true, false) to value.visitedHover,
            Triple(true, false, true) to value.visitedActive,
            Triple(true, true, true) to value.visitedHoverActive)
        assertEquals(8, states.values.map { it.foreground }.distinct().size)
        for ((bits, expected) in states) assertEquals(expected, value.state(bits.first, bits.second, bits.third))
        assertFalse(value.state(false, false, true).underline)
        assertTrue(value.state(false, true, true).underline)
        assertFalse(value.state(true, false, true).underline)
        assertTrue(value.state(true, true, true).underline)
        val figure = figurePaint()
        assertEquals(figure.active, figure.state(false, true, true))
        assertEquals(figure.visitedActive, figure.state(true, true, true))
    }
}
