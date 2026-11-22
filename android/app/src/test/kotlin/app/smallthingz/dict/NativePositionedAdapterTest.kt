package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Constructed ownership controls, independent of EN source issuance and native rendering. */
class NativePositionedAdapterTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun scope() = PositionedScope(TextWrap.NoWrap, PositionedOverflowX.Scroll, PositionedOverflowY.Auto,
        listOf(PositionedViewportState(900, PositionedOverflowX.Hidden, PositionedOverflowY.Auto)))

    @Test fun responsiveAxisUsesExactRootViewportAndRejectsUnknownCoordinates() {
        val policy = scope()
        assertEquals(PositionedOverflowX.Scroll, positionedOverflowAt(policy, 0.0))
        assertEquals(PositionedOverflowX.Scroll, positionedOverflowAt(policy, 899.999999))
        assertEquals(PositionedOverflowX.Hidden, positionedOverflowAt(policy, 900.0))
        assertEquals(PositionedOverflowX.Hidden, positionedOverflowAt(policy, 900.000001))
        val large = policy.copy(viewportStates = listOf(
            PositionedViewportState(4294967295L, PositionedOverflowX.Hidden, PositionedOverflowY.Auto)))
        assertEquals(PositionedOverflowX.Scroll, positionedOverflowAt(large, 4294967294.999))
        assertEquals(PositionedOverflowX.Hidden, positionedOverflowAt(large, 4294967295.0))
        for (invalid in listOf(-.01, Double.NaN, Double.POSITIVE_INFINITY))
            assertTrue(runCatching { positionedOverflowAt(policy, invalid) }.isFailure)
    }

    @Test fun refusedScopeRetainsActualTextOwnersWithoutUnownedPositioningClaims() {
        val span = Span("link", "Retained label", "Exact target", targetFragment = "Exact_fragment")
        val paragraph = Block("paragraph", 0, listOf(span))
        val absoluteStyle = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
            height = px(0f), positioning = ContainerPositioning.Absolute(px(3f), px(130f),
                InlineFontSnapshot(12f, FontScaleBasis.CssPx, language = "en"),
                InlineComputedLength(12f, FontScaleBasis.CssPx), TextWrap.NoWrap))
        val absoluteSource = Container(listOf(paragraph), absoluteStyle)
        val scopeStyle = ContainerStyle(positioning = ContainerPositioning.RelativeAuto,
            positionedScope = scope(), height = px(20f))
        val source = Container(listOf(Block("container", 0, emptyList(), container = absoluteSource)), scopeStyle)
        val prepared = PreparedNativeFloatText(span.text, null, Any(), null, menu = {}, fallback = {})
        val text = NativeFloatContextSpec.Text(prepared, 0f, "source/absolute/paragraph")
        val original = nativeContainerSpec(17, absoluteStyle.atViewport(899.5), listOf(text),
            1f, 20f, false, false, false, absolute = NativeAbsoluteTextPlacement(130f, 3f))
        assertNull(original.unavailableReason)
        assertEquals(0f, checkNotNull(original.fixedContentHeight), 0f)
        val unavailable = nativeContainerSpec(9, scopeStyle.atViewport(899.5), listOf(original),
            1f, 20f, false, false, false, positioned = NativePositionedScrollportPolicy(source, PositionedOverflowX.Scroll))
        assertNotNull(unavailable.unavailableReason)
        assertNull(unavailable.scrollport)
        val retained = unavailable.preparedParts!!.single() as NativeFloatContextSpec.Container
        assertEquals(original.id, retained.id)
        assertNull(retained.absolute)
        assertNull(retained.fixedContentHeight)
        assertFalse(retained.relativeAuto)
        assertSame(text, retained.preparedParts!!.single())
        assertSame(prepared, (retained.preparedParts!!.single() as NativeFloatContextSpec.Text).prepared)
        assertEquals(listOf(0, 1, 2), nativeContextPaintSequence(listOf(NativePaintOrderNode(0,
            children = listOf(NativePaintOrderNode(1, retained.relativeAuto,
                listOf(NativePaintOrderNode(2)), absolute = retained.absolute != null))))))
        assertEquals(NativeAbsoluteTextPlacement(130f, 3f), original.absolute)
        assertEquals(0f, checkNotNull(original.fixedContentHeight), 0f)
        assertSame(span, source.blocks.single().container!!.blocks.single().spans.single())
        assertEquals("Exact target", span.target)
        assertEquals("Exact_fragment", span.targetFragment)

        val legacy = nativeContainerSpec(3, ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
            .atViewport(899.5), listOf(NativeFloatContextSpec.Child(21, { it }, 0f)),
            1f, 20f, false, false, false)
        assertNotNull(legacy.unavailableReason)
        assertEquals(21, (legacy.preparedParts!!.single() as NativeFloatContextSpec.Child).id)
    }
    @Test fun ordinaryAbsolutePositionsUseGenericCssAxesAndRetainOwnNonzeroBoxes() {
        val position = ContainerAbsolutePosition(SignedContainerMargin(StyleLengthUnit.Em, -.5f),
            SignedContainerMargin(StyleLengthUnit.Px, 3f))
        val placement = nativeOrdinaryAbsolutePosition(position, 41, 1.25f, 24f)
        assertEquals(41, placement.containingBlockId)
        assertEquals(-12f, placement.left, 0f); assertEquals(3.75f, placement.top, 0f)
        val style = ContainerStyle(
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 120.25f)), height = px(20f),
            ownerFont = InlineFontSnapshot(18f, FontScaleBasis.CssPx, fontNormalized = true),
            lineHeight = ContainerLineHeight.Length(px(20f)), textAlign = CellTextAlign.Right,
            textWrap = TextWrap.NoWrap, absolutePosition = position)
        val span = Span("link", "Original label", "Exact target", targetFragment = "Exact_fragment",
            bold = false, italic = false, fontScale = 18f, fontScaleBasis = FontScaleBasis.CssPx)
        val prepared = PreparedNativeFloatText(span.text, null, Any(), null, menu = {}, fallback = {})
        val text = NativeFloatContextSpec.Text(prepared, 0f, "source/relative/static/absolute/paragraph")
        val spec = nativeContainerSpec(42, style.atViewport(640.0), listOf(text),
            1.25f, 24f, false, false, false, absolutePosition = placement)
        assertNull(spec.unavailableReason); assertNull(spec.absolute); assertNull(spec.scrollport)
        assertSame(placement, spec.absolutePosition)
        assertFalse(spec.relativeAuto); assertNull(spec.absoluteContainingBlock)
        assertEquals(25f, checkNotNull(spec.fixedContentHeight), 0f)
        val intrinsic = ContainerWidths(999f, 999f)
        assertEquals(150, spec.contentWidth(400, intrinsic))
        // The Float allocation is retained independently of the legacy integer measurement adapter.
        assertEquals(150.3125f, checkNotNull(spec.horizontal).invoke(400, intrinsic).content, 0f)
        assertSame(text, spec.preparedParts!!.single()); assertSame(prepared, text.prepared)
        assertEquals("Exact target", span.target); assertEquals("Exact_fragment", span.targetFragment)
        assertEquals(18f, style.ownerFont!!.fontScale!!, 0f)
        assertEquals(ContainerLineHeight.Length(px(20f)), style.lineHeight)
        assertEquals(TextWrap.NoWrap, style.textWrap)
        val missingAnchor = nativeContainerSpec(42, style.atViewport(640.0), listOf(text),
            1.25f, 24f, false, false, false)
        assertEquals("Absolute positioned content requires its nearest relative Container", missingAnchor.unavailableReason)
        assertSame(text, missingAnchor.preparedParts!!.single())
        assertNull(missingAnchor.absolutePosition)
        val zero = nativeContainerSpec(42, style.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 0f)),
            height = px(0f)).atViewport(640.0), listOf(text), 1.25f, 24f, false, false, false,
            absolutePosition = placement)
        assertNull(zero.unavailableReason); assertEquals(0f, checkNotNull(zero.fixedContentHeight), 0f)
        assertEquals(0f, checkNotNull(zero.horizontal).invoke(400, intrinsic).content, 0f)
        assertSame(text, zero.preparedParts!!.single())
        val changedBody = nativeOrdinaryAbsolutePosition(position, 41, 1.25f, 48f)
        assertEquals(-24f, changedBody.left, 0f); assertEquals(placement.top, changedBody.top, 0f)
        assertEquals(0f, nativeOrdinaryAbsolutePosition(position, 41, 1.25f, 0f).left, 0f)
        val tooLarge = position.copy(left = SignedContainerMargin(StyleLengthUnit.Px, Float.MAX_VALUE))
        assertTrue(runCatching { nativeOrdinaryAbsolutePosition(tooLarge, 41, 2f, 24f) }.exceptionOrNull()
            is UnsupportedFloatLayout)
        for (density in listOf(0f, Float.NaN, Float.POSITIVE_INFINITY))
            assertTrue(runCatching { nativeOrdinaryAbsolutePosition(position, 41, density, 24f) }.isFailure)
        assertEquals(-.5f, position.left.value, 0f); assertEquals(3f, position.top.value, 0f)

        val delegated = NativeFloatContextSpec.Child(50, { it }, 0f)
        val relative = ContainerStyle(positioning = ContainerPositioning.RelativeAuto, textWrap = TextWrap.NoWrap,
            padding = StyleEdges(px(4f), px(0f), px(0f), px(6f)),
            border = ContainerBorder.Solid(px(2f), ContainerColor.Transparent))
        val anchor = NativeAbsoluteContainingBlock(7.5f, 5f)
        val admitted = nativeContainerSpec(41, relative.atViewport(640.0), listOf(delegated, spec),
            1.25f, 24f, false, false, false, absoluteContainingBlock = anchor)
        assertNull(admitted.unavailableReason); assertSame(anchor, admitted.absoluteContainingBlock)
        assertTrue(admitted.relativeAuto); assertFalse(admitted.isolatesFloats)
        assertEquals(10f, admitted.padding(400).left, 0f); assertEquals(7.5f, admitted.padding(400).top, 0f)
        assertEquals(7.5f, anchor.paddingLeft, 0f); assertEquals(5f, anchor.paddingTop, 0f)
        assertEquals(listOf(delegated, spec), admitted.preparedParts)
        val legacy = nativeContainerSpec(41, ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
            .atViewport(640.0), listOf(delegated), 1.25f, 24f, false, false, false)
        assertNotNull(legacy.unavailableReason); assertNull(legacy.absoluteContainingBlock)
        assertSame(delegated, legacy.preparedParts!!.single())
    }


    @Test fun picdicScopeRetainsMapFallbackSourcesAndSignedPaddingCompensation() {
        for (file in listOf("Chest.jpg", "Human body features-nb.svg")) {
            val label = if (file == "Chest.jpg") "sefuba" else "mmele"
            val source = nativePicdicScopeFixture(file)
            val plan = checkNotNull(NativeTablePositionedScopeSource.from(source))
            val scope = plan.scope
            val spans = scope.blocks.single().spans
            assertEquals(1, plan.scopeIndex)
            assertSame(source.rows[1][0].blocks!!.single(), plan.blocks[1].single())
            assertSame(source.rows[0][0].spans, plan.blocks[0].single().spans)
            assertSame(source.rows[2][0].spans, plan.blocks[2].single().spans)
            assertEquals(" \n", plan.blocks[2].single().spans.joinToString("") { it.text })
            assertEquals(file, spans.first().image!!.file)
            assertEquals(310L, spans.first().image!!.widthPx)
            assertEquals(listOf(0.0, 0.0, 1.0, 1.0), spans.first().image!!.map!!.regions.single().coordinates)
            assertEquals(label, spans.first().image!!.map!!.regions.single().action.target)
            assertEquals(ImageMapDescription.BottomRight, spans.first().image!!.map!!.description)
            assertEquals(label, spans.first().image!!.tooltip)
            assertEquals(label, spans[2].target)
            assertEquals(listOf("link", "line_break", "link", "text", "line_break"), spans.map { it.kind })
            assertFalse(nativeDelegatedAbsoluteTable(source))
            val margin = ContainerMargin.Length(px(0f))
            val equivalent = scope.style.copy(margins = null, marginValues = ContainerMargins(margin, margin,
                ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, -25f)), margin))
            for (style in listOf(scope.style, equivalent)) for (density in listOf(1f, 1.25f)) {
                val owner = scope.copy(style = style)
                val text = PreparedNativeFloatText("\ufffc\n$label \n", null, Any(), null, menu = {}, fallback = {})
                val leaf = NativeFloatContextSpec.Text(text, 0f, "scope/paragraph")
                val spec = nativeContainerSpec(71, style.atViewport(500.0), listOf(leaf), density, 24f,
                    false, false, false, positioned = NativePositionedScrollportPolicy(owner, PositionedOverflowX.Hidden))
                assertNull(spec.unavailableReason)
                assertTrue(spec.isolatesFloats); assertTrue(spec.relativeAuto)
                assertNull(spec.fixedContentHeight); assertNull(spec.preparedParts)
                val scrollport = checkNotNull(spec.scrollport)
                assertSame(leaf, scrollport.parts.single())
                assertSame(text, (scrollport.parts.single() as NativeFloatContextSpec.Text).prepared)
                assertEquals(PositionedOverflowX.Hidden, scrollport.positioned!!.overflowX)
                assertEquals(25f * density, scrollport.padding.bottom, 0f)
                assertEquals(0f, spec.padding(310).bottom, 0f)
                assertEquals(-25f * density, spec.margins(310).bottom, 0f)
                for (width in listOf(200, 310, 500)) {
                    val imageWidth = 310f * density
                    assertEquals(width, spec.contentWidth(width, ContainerWidths(imageWidth, imageWidth)))
                    val contentHeight = 157.125f * density // Controlled ready-image line height, not a downloaded raster claim.
                    val allocation = nativePositionedScrollportAllocation(width, contentHeight,
                        NativeFloatBounds(0f, 0f, imageWidth, contentHeight), scrollport.padding)
                    assertEquals(contentHeight + 25f * density, allocation.usedHeight, 0f)
                    assertEquals(maxOf(0f, imageWidth - width), allocation.overflow, 0f)
                    assertFalse(allocation.verticalOverflow)
                    val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
                    val profile = NativeAdjoiningMargins(0f, spec.margins(width).bottom, false)
                    val first = cursor.begin(profile); cursor.end(first, allocation.usedHeight, profile)
                    val following = cursor.begin(NativeAdjoiningMargins(0f, 0f, false))
                    assertEquals(contentHeight, following.borderTop, 0f)
                }
            }
            val changed = source.copy(rows = source.rows.toMutableList().also { rows ->
                rows[1] = listOf(source.rows[1][0].copy(blocks = listOf(source.rows[1][0].blocks!!.single().copy(
                    container = scope.copy(style = scope.style.copy(positionedScope = scope.style.positionedScope!!.copy(
                        overflowX = PositionedOverflowX.Scroll)))))))
            })
            assertNull(NativeTablePositionedScopeSource.from(changed))
        }
    }

    @Test fun positionedScopeAuthorityBindsCompleteEntryProjectionAndItsOriginalCell() {
        val fixture = nativePicdicScopeFixture("Chest.jpg")
        val listSpan = Span("link", "Mmele", "mmele", targetFragment = "Setswana")
        val entry = Entry("sefuba", emptyList(), "language", "Setswana", "tn", listOf(
            Section(2, "Setswana", listOf(Block("list_item", 1, listOf(listSpan), listPath = "*"))),
            Section(3, "Setswantsho", listOf(Block("table", 0, emptyList(), table = fixture)))
        ), emptyList(), media = listOf(Media("Chest.jpg", "image", "sefuba")))
        val rows = visibleEntryReadingRows(entry, emptySet())
        val projected = nativeScopeTestProjection(entry, rows)
        assertEquals(listOf(rows.indices), floatBodyRuns(rows, entry.bodyAdjoining, entry.language))
        val receipt = checkNotNull(NativeTableScopeEntrySource.from(entry, rows, emptyMap(), rows.indices,
            projected.first, projected.second, emptyList()))
        val actualTable = projected.first.single { it.table != null }.table!!
        val actualList = projected.first.first { it.kind == "list_item" }
        assertSame(listSpan, actualList.spans.single())
        assertTrue(receipt.contains(actualTable))
        assertTrue(entry.textDetails.isNotEmpty())
        assertNotNull(NativeTableScopeEntrySource.from(entry, rows, mapOf("abbreviations" to true), rows.indices,
            projected.first, projected.second, emptyList()))
        val detailsOpen = checkNotNull(NativeTableScopeEntrySource.from(entry, rows, mapOf("abbreviations" to false), rows.indices,
            projected.first, projected.second, emptyList()))
        assertNotEquals(receipt.revision, detailsOpen.revision)
        assertEquals(receipt.revision, checkNotNull(NativeTableScopeEntrySource.from(entry, rows, emptyMap(), rows.indices,
            projected.first, projected.second, emptyList())).revision)
        val owner = NativeDelegatedTableOwner(actualTable, receipt) { }
        val scopeSource = checkNotNull(owner.scopeSource)
        val cell = owner.cells[scopeSource.scopeIndex]
        assertNull(nativeContainerOwnerAuthorityFailure(scopeSource.scope, scopeSource.scope.style.atViewport(500.0),
            fixedHeightReachable = false, positionedPaintReachable = false, positionedCell = cell))
        assertNotNull(nativeContainerOwnerAuthorityFailure(scopeSource.scope.copy(), scopeSource.scope.style.atViewport(500.0),
            fixedHeightReachable = false, positionedPaintReachable = false, positionedCell = cell))
        assertNotNull(nativeContainerOwnerAuthorityFailure(scopeSource.scope, scopeSource.scope.style.atViewport(500.0),
            fixedHeightReachable = false, positionedPaintReachable = false))
        assertFalse(owner.permitsOriginalOwners()) // Source enrollment never grants a measured View.
        assertFalse(cell.scopePublicationCurrent())
        assertFalse(receipt.owns(projected.first.drop(1), projected.second.drop(1)))
        assertNull(NativeTableScopeEntrySource.from(entry.copy(), rows, emptyMap(), rows.indices,
            projected.first, projected.second, emptyList()))
        assertNull(NativeTableScopeEntrySource.from(entry, rows, emptyMap(), 1..rows.lastIndex,
            projected.first, projected.second, emptyList()))
        assertNull(NativeTableScopeEntrySource.from(entry, rows, emptyMap(), rows.indices,
            projected.first.reversed(), projected.second, emptyList()))
        assertNull(NativeTableScopeEntrySource.from(entry, rows, emptyMap(), rows.indices,
            projected.first, projected.second.reversed(), emptyList()))
        assertNull(NativeTableScopeEntrySource.from(entry, rows, emptyMap(), rows.indices,
            projected.first, projected.second, entry.media))
        assertNull(NativeTablePositionedScopeSource.from(fixture.copy(rows = fixture.rows.toMutableList().also {
            it[2] = listOf(fixture.rows[2][0].copy(spans = emptyList(), nestedTable = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1))))))
        })))
    }

}

/** Source-matched controlled tree; it is not a newly decoded TN response. */
internal fun nativePicdicScopeFixture(file: String): Table {
    fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    val label = if (file == "Chest.jpg") "sefuba" else "mmele"
    val mapAction = ImageMapAction(ImageMapActionKind.Internal, label, null, label)
    val image = Span("link", "", "File:$file", image = InlineImage(file, widthPx = 310,
        alt = label, tooltip = label, map = ImageMap(ImageMapDescription.BottomRight,
            listOf(ImageMapRegion(ImageMapShape.Rect, listOf(0.0, 0.0, 1.0, 1.0), mapAction)))))
    val source = listOf(image, Span("line_break", "\n"), Span("link", label, label),
        Span("text", " "), Span("line_break", "\n"))
    val scope = Container(listOf(Block("paragraph", 0, source)), ContainerStyle(
        positioning = ContainerPositioning.RelativeAuto,
        positionedScope = PositionedScope(TextWrap.NoWrap, PositionedOverflowX.Hidden, PositionedOverflowY.Auto),
        padding = StyleEdges(px(0f), px(0f), px(25f), px(0f)),
        margins = SignedContainerEdges(px(0f), px(0f), SignedContainerMargin(StyleLengthUnit.Px, -25f), px(0f))))
    return Table(emptyList(), listOf(
        listOf(Cell(listOf(Span("link", "Picture dictionary", "Wiktionary:Picture dictionary")), true, 1, 1)),
        listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(Block("container", 0, emptyList(), container = scope)))),
        listOf(Cell(listOf(Span("text", " "), Span("line_break", "\n")), false, 1, 1))))
}

internal fun nativeScopeTestProjection(entry: Entry, rows: List<ReadingRow>): Pair<List<Block>, List<String>> {
    val visible = rows.filter { it.block != null || it.heading?.let { value -> sectionHeadingVisible(value, entry.language) } == true }
    return visible.map { it.block ?: it.headingBlock ?: Block("heading", 0,
        listOf(Span("text", sectionHeadingLabel(checkNotNull(it.heading), entry.language, null))),
        level = checkNotNull(it.heading).level) } to visible.map { it.key }
}
