package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Source-only controls: this file has not been compiled or executed. */
class TableAutoMarginsTest {
    private val zero = ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 0f))
    private val auto = ContainerMargin.Auto
    private fun margins(left: ContainerMargin = auto, right: ContainerMargin = auto) =
        ContainerMargins(zero, right, zero, left)
    private fun style(margins: ContainerMargins) = TableStyle(marginValues = margins,
        containingDirection = TableContainingDirection.Ltr)
    private fun resolved(left: Float = 0f, right: Float = 0f, leftAuto: Boolean = true,
        rightAuto: Boolean = true, top: Float = 0f, bottom: Float = 0f) =
        NativeTableAutoMargins(FloatMargins(top, right, bottom, left), leftAuto, rightAuto)

    @Test fun tableDomainRejectsGenericContainerExtensionsAndConflictingOldField() {
        assertEquals(margins(), style(margins()).marginValues)
        assertThrows(IllegalArgumentException::class.java) { style(margins(zero, zero)) }
        assertThrows(IllegalArgumentException::class.java) { style(margins().copy(top = auto)) }
        assertThrows(IllegalArgumentException::class.java) { style(margins().copy(bottom = auto)) }
        assertThrows(IllegalArgumentException::class.java) {
            style(margins(right = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, -1f))))
        }
        val edges = StyleEdges(StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, 0f),
            StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, 0f))
        assertThrows(IllegalArgumentException::class.java) { TableStyle(margins = edges, marginValues = margins(),
            containingDirection = TableContainingDirection.Ltr) }
        assertThrows(IllegalArgumentException::class.java) { TableStyle(marginValues = margins()) }
        assertThrows(IllegalArgumentException::class.java) { TableStyle(margins = edges,
            containingDirection = TableContainingDirection.Ltr) }
        assertNull(TableStyle(margins = edges).marginValues)
        assertThrows(IllegalArgumentException::class.java) { resolved(left = 1f) }
        assertThrows(IllegalArgumentException::class.java) { resolved(right = 1f) }
    }

    @Test fun ownerNormalizedEmAndPxResolveIndependentlyWithoutDecorationProjection() {
        val value = margins(right = ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 3f))).copy(
            top = ContainerMargin.Length(StyleLength(StyleLengthUnit.Em, .2f)))
        val pixels = resolveTableAutoMargins(value, density = 2f, normalBodyPixels = 20f)
        assertEquals(FloatMargins(4f, 6f, 0f, 0f), pixels.fixed)
        assertTrue(pixels.leftAuto); assertFalse(pixels.rightAuto)
    }

    @Test fun fractionalFixedLengthsRemainExactInAllocationAndExclusionPlacement() {
        val authored = margins(right = ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, .25f))).copy(
            top = ContainerMargin.Length(StyleLength(StyleLengthUnit.Em, .125f)))
        val fixed = resolveTableAutoMargins(authored, 1f, 2f)
        val value = placeNativeAutoMarginTable(100f, 0f, emptyList(), fixed, TableContainingDirection.Ltr) {
            NativeBlockMeasure(60f, 60f, 10f)
        }
        assertEquals(.25f, value.margins.top, 0f); assertEquals(.25f, value.margins.right, 0f)
        assertEquals(NativeFloatBounds(39.75f, .25f, 99.75f, 10.25f), value.content)
        assertEquals(10.25f, value.nextY, 0f)
    }

    @Test fun positiveSpaceAndSingleAutoPreservePhysicalFixedSide() {
        val both = solveTableAutoMargins(101f, 70f, resolved(), NativeTableMarginFlow.Block, TableContainingDirection.Rtl)
        assertEquals(15.5f, both.left, 0f); assertEquals(15.5f, both.right, 0f)
        val left = solveTableAutoMargins(100f, 60f, resolved(right = 10f, rightAuto = false),
            NativeTableMarginFlow.Block, TableContainingDirection.Ltr)
        assertEquals(30f, left.left, 0f); assertEquals(10f, left.right, 0f)
        val right = solveTableAutoMargins(100f, 60f, resolved(left = 10f, leftAuto = false),
            NativeTableMarginFlow.Block, TableContainingDirection.Rtl)
        assertEquals(10f, right.left, 0f); assertEquals(30f, right.right, 0f)
        val zero = solveTableAutoMargins(100f, 90f, resolved(right = 10f, rightAuto = false),
            NativeTableMarginFlow.Block, TableContainingDirection.Rtl)
        assertEquals(0f, zero.left, 0f); assertEquals(10f, zero.right, 0f)
    }

    @Test fun singleAutoOverconstraintAdjustsTheContainingEndEvenWhenItWasFixed() {
        val fixedRight = resolved(right = 10f, rightAuto = false)
        val fixedLeft = resolved(left = 10f, leftAuto = false)
        assertEquals(NativeTableUsedMargins(0f, -40f, 0f, 0f),
            solveTableAutoMargins(100f, 140f, fixedRight, NativeTableMarginFlow.Block, TableContainingDirection.Ltr))
        assertEquals(NativeTableUsedMargins(0f, 10f, 0f, -50f),
            solveTableAutoMargins(100f, 140f, fixedRight, NativeTableMarginFlow.Block, TableContainingDirection.Rtl))
        assertEquals(NativeTableUsedMargins(0f, -50f, 0f, 10f),
            solveTableAutoMargins(100f, 140f, fixedLeft, NativeTableMarginFlow.Block, TableContainingDirection.Ltr))
        assertEquals(NativeTableUsedMargins(0f, 0f, 0f, -40f),
            solveTableAutoMargins(100f, 140f, fixedLeft, NativeTableMarginFlow.Block, TableContainingDirection.Rtl))
    }

    @Test fun overconstraintUsesContainingDirectionIndependentOfGridDirection() {
        val cell = Cell(emptyList(), false, 1, 1)
        val grid = TableGrid(listOf(PlacedCell(cell, 0, 0, 1), PlacedCell(cell, 0, 1, 1)), 1, 2)
        val pixels = checkNotNull(tablePixelLayout(grid, 70, 10, intArrayOf(10, 10)))
        for (gridRtl in listOf(false, true)) {
            val ltr = solveTableAutoMargins(100f, pixels.width.toFloat(), resolved(),
                NativeTableMarginFlow.Block, TableContainingDirection.Ltr)
            val rtl = solveTableAutoMargins(100f, pixels.width.toFloat(), resolved(),
                NativeTableMarginFlow.Block, TableContainingDirection.Rtl)
            assertEquals(0f, ltr.left, 0f); assertEquals(-40f, ltr.right, 0f)
            assertEquals(-40f, rtl.left, 0f); assertEquals(0f, rtl.right, 0f)
            val firstCell = pixels.physicalCellLeft(0, 1, gridRtl)
            assertEquals((if (gridRtl) 70 else 0).toFloat(), ltr.left + firstCell, 0f)
            assertEquals((if (gridRtl) 30 else -40).toFloat(), rtl.left + firstCell, 0f)
        }
    }

    @Test fun inlineAndFloatAutosAreZeroAndFixedVerticalMarginsOccurOnce() {
        for (flow in listOf(NativeTableMarginFlow.Floating, NativeTableMarginFlow.Inline)) {
            val value = solveTableAutoMargins(100f, 140f, resolved(right = 10f, rightAuto = false, top = 3f, bottom = 5f),
                flow, TableContainingDirection.Rtl)
            assertEquals(NativeTableUsedMargins(3f, 10f, 5f, 0f), value)
        }
        val value = placeNativeAutoMarginTable(100f, 10f, emptyList(), resolved(top = 3f, bottom = 5f),
            TableContainingDirection.Ltr) { NativeBlockMeasure(60f, 60f, 20f) }
        assertEquals(NativeFloatBounds(20f, 13f, 80f, 33f), value.content)
        assertEquals(38f, value.nextY, 0f)
    }

    @Test fun captionFloorExpandsRealGridWithoutChangingPercentageRequestOrSpans() {
        val span = Cell(emptyList(), false, 2, 1)
        val cell = Cell(emptyList(), false, 1, 1)
        val grid = TableGrid(listOf(PlacedCell(span, 0, 0, 2), PlacedCell(cell, 1, 0, 1),
            PlacedCell(cell, 1, 1, 1)), 2, 2)
        val minimum = intArrayOf(40, 20, 20); val maximum = intArrayOf(80, 40, 40)
        val ordinary = inlineTableColumnWidths(grid, minimum, maximum, 0, 0, 100, authoredWidth = 70)
        val caption = inlineTableColumnWidths(grid, minimum, maximum, 0, 0, 100,
            authoredWidth = 70, captionMinimumWidth = 140)
        assertEquals(listOf(35, 35), ordinary); assertEquals(listOf(70, 70), caption)
        assertNull(inlineTableColumnWidths(grid, minimum, maximum, 0, 0, 100,
            authoredWidth = 70, captionMinimumWidth = TablePixelLimit + 1))
        val position = placeNativeAutoMarginTable(100f, 0f, emptyList(), resolved(), TableContainingDirection.Rtl,
            NativeBlockWidth.Percent(70f)) { request ->
            assertEquals(100f, request.containingWidth, 0f); assertEquals(70f, request.requestedWidth!!, 0f)
            NativeBlockMeasure(caption!!.sum().toFloat(), 140f, 20f)
        }
        assertEquals(NativeFloatBounds(-40f, 0f, 100f, 20f), position.content)
        assertEquals(-40f, position.documentLeft, 0f); assertEquals(100f, position.documentRight, 0f)
        assertEquals(1, position.measurementCount)
    }

    @Test fun finalFloatIntervalAndOriginalContainingWidthRemainSeparate() {
        val previous = NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 100f, 40f))
        val requests = mutableListOf<NativeBlockMeasureRequest>()
        val value = placeNativeAutoMarginTable(300f, 0f, listOf(previous), resolved(), TableContainingDirection.Ltr) {
            requests += it; NativeBlockMeasure(80f, 80f, 20f)
        }
        assertEquals(listOf(300f, 200f), requests.map { it.availableWidth })
        assertTrue(requests.all { it.containingWidth == 300f && it.requestedWidth == null })
        assertEquals(NativeFloatBounds(160f, 0f, 240f, 20f), value.content)
        assertEquals(100f, value.availableLeft, 0f); assertEquals(300f, value.availableRight, 0f)
        assertEquals(2, value.measurementCount)
    }

    @Test fun fractionalMarginRetainsOneSharedPaintAndHitOrigin() {
        val value = placeNativeAutoMarginTable(101f, 0f, emptyList(), resolved(),
            TableContainingDirection.Ltr) { NativeBlockMeasure(70f, 70f, 10f) }
        assertEquals(15.5f, value.content.left, 0f)
        assertEquals(85.5f, value.content.right, 0f)
    }

    @Test fun bottomMarginParticipatesInExistingExclusionProbeWithoutDoubleAdvance() {
        val previous = NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 21f, 80f, 40f))
        val value = placeNativeAutoMarginTable(100f, 0f, listOf(previous), resolved(bottom = 5f),
            TableContainingDirection.Ltr) { NativeBlockMeasure(60f, 60f, 20f) }
        assertEquals(NativeFloatBounds(20f, 40f, 80f, 60f), value.content)
        assertEquals(65f, value.nextY, 0f)
    }
    @Test fun fixedResponsiveMarginsKeepFractionalBodyEmAndDensityIndependent() {
        val edges = StyleEdges(StyleLength(StyleLengthUnit.Em, .4f), StyleLength(StyleLengthUnit.Px, .25f),
            StyleLength(StyleLengthUnit.Em, .5f), StyleLength(StyleLengthUnit.Px, 1.5f))
        val small = resolveTableFixedMargins(edges, 2.5f, 17f)
        val large = resolveTableFixedMargins(edges, 2.5f, 34f)
        assertEquals(6.8f, small.top, .00001f)
        assertEquals(8.5f, small.bottom, 0f)
        assertEquals(13.6f, large.top, .00001f)
        assertEquals(17f, large.bottom, 0f)
        assertEquals(.625f, small.right, 0f)
        assertEquals(3.75f, small.left, 0f)
        assertEquals(small.right, large.right, 0f)
        assertEquals(small.left, large.left, 0f)
        assertEquals(.4f, edges.top.value, 0f)
    }

    @Test fun parentOwnedFixedMarginsLeaveGridDecorationAndBodyUnchanged() {
        val edges = StyleEdges(StyleLength(StyleLengthUnit.Px, 2f), StyleLength(StyleLengthUnit.Px, 7f),
            StyleLength(StyleLengthUnit.Px, 3f), StyleLength(StyleLengthUnit.Px, 11f))
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "same cell")), false, 1, 1,
            style = CellStyle(minWidth = StyleLength(StyleLengthUnit.Px, 0f))))),
            style = TableStyle(border = StyleBorder.Solid(StyleLength(StyleLengthUnit.Px, 2f), "#123456"),
                margins = edges, floatSide = TableFloatSide.Right))
        val legacy = requireNotNull(tableRenderMetrics(table, 1, 5, 10, 1f, containerFontPixels = 16f))
        val owned = requireNotNull(tableRenderMetrics(table, 1, 5, 10, 1f, containerFontPixels = 16f,
            marginsConsumed = true))
        val legacyStyle = checkNotNull(legacy.style)
        assertEquals(TablePixelInsets(2, 7, 3, 11), legacyStyle.margins)
        assertEquals(legacyStyle.copy(margins = TablePixelInsets(0, 0, 0, 0)), owned.style)
        assertEquals(legacy.width, owned.width)
        assertEquals(table.rows.single().single().spans.single().text, "same cell")
        assertEquals(edges, table.style!!.margins)
    }

    @Test fun excessiveFixedResponsiveMarginRefusesInsteadOfClampingToFontLimit() {
        val large = StyleLength(StyleLengthUnit.Em, Float.MAX_VALUE)
        val zeroLength = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(large, zeroLength, zeroLength, zeroLength)
        assertThrows(UnsupportedFloatLayout::class.java) { resolveTableFixedMargins(edges, 1f, 16f) }
        assertEquals(Float.MAX_VALUE, edges.top.value, 0f)
    }


    @Test fun ordinaryRootTableMarginsReplaceOnlyItsLegacyGapAndAdjoinOnce() {
        val authored = margins().copy(
            top = ContainerMargin.Length(StyleLength(StyleLengthUnit.Em, .25f)),
            bottom = ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 3.5f)))
        val action = Span("link", "body", "target", targetFragment = "section", trail = "s")
        val cell = Cell(listOf(action), false, 1, 1)
        val table = Table(listOf(Span("text", "caption")), listOf(listOf(cell)), style = style(authored))
        val block = Block("table", 0, emptyList(), table = table)
        val pixels = resolveTableAutoMargins(authored, 2f, 20f)
        val original = NativeFloatContextSpec.Child(71, { 60 }, 6f,
            margins = { pixels.fixed }, widthFromContent = true,
            preferredWidth = { 60 }, autoMarginTable = table, autoMargins = pixels)
        val selected = nativeTableBodyAdjoiningSpec(block, BodyAdjoiningPolicy.Ordinary, true, original)
        assertEquals(original.copy(gapAfter = 0f), selected)
        assertSame(original.width, selected.width); assertSame(original.margins, selected.margins)
        assertSame(original.preferredWidth, selected.preferredWidth)
        assertSame(table, selected.autoMarginTable); assertSame(cell, selected.autoMarginTable!!.rows.single().single())
        assertSame(action, selected.autoMarginTable!!.rows.single().single().spans.single())
        assertEquals("section", action.targetFragment); assertEquals("s", action.trail)
        assertEquals(FloatMargins(5f, 0f, 7f, 0f), selected.margins(100))
        fun part(spec: NativeFloatContextSpec.Child) = NativeFloatContextPart.Child(spec.id,
            NativeBlockWidth.FixedPx(spec.width(100).toFloat()),
            { error("A structural query must not measure the table") }, gapAfter = spec.gapAfter,
            margins = spec.margins(100), gapBefore = spec.gapBefore, clear = spec.clear)
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeFloatContextGeometry.adjoiningProfile(part(original))
        }
        val own = checkNotNull(NativeFloatContextGeometry.adjoiningProfile(part(selected)))
        assertEquals(NativeAdjoiningMargins(5f, 7f, false), own)
        for (height in listOf(0f, 20f)) {
            val body = NativeMarginCursor(NativeMarginCollapse(true, true))
            val first = body.begin(own)
            assertEquals(0f, first.borderTop, 0f)
            body.end(first, height, own)
            assertFalse(body.adjoiningTop) // Even a zero-height table is an atomic barrier.
            val following = NativeAdjoiningMargins(11f, 0f, false)
            assertEquals(height + 11f, body.begin(following).borderTop, 0f)
        }
        for (direction in TableContainingDirection.entries) {
            val body = NativeMarginCursor(NativeMarginCollapse(true, true))
            val previous = NativeAdjoiningMargins(0f, 9f, false)
            body.end(body.begin(previous), 10f, previous)
            val at = body.begin(own)
            assertEquals(19f, at.borderTop, 0f) // max(9, 5), not an added gap or a second margin.
            val placed = placeNativeAutoMarginTable(100f, at.borderTop, emptyList(),
                pixels.copy(fixed = pixels.fixed.copy(top = 0f, bottom = 0f)), direction) {
                NativeBlockMeasure(60f, 60f, 20f)
            }
            assertEquals(NativeFloatBounds(20f, 19f, 80f, 39f), placed.content)
            assertEquals(39f, placed.nextY, 0f)
            body.end(at, placed.nextY - at.borderTop, own)
            val following = NativeAdjoiningMargins(3f, 0f, false)
            val next = body.begin(following)
            assertEquals(46f, next.borderTop, 0f) // max(7, 3), counted once.
            body.end(next, 4f, following)
            assertEquals(50f, body.finish(), 0f)
        }
    }

    @Test fun ordinaryRootTableGapRequiresItsPreparedOwnerAndPreservesUnknownRoots() {
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1))), style = style(margins()))
        val block = Block("table", 0, emptyList(), table = table)
        val original = NativeFloatContextSpec.Child(72, { it }, 6f,
            margins = { FloatMargins(0f, 0f, 0f, 0f) }, autoMarginTable = table,
            autoMargins = resolveTableAutoMargins(table.style!!.marginValues!!, 1f, 20f), clear = FigureClear.Both)
        fun select(source: Block = block, policy: BodyAdjoiningPolicy? = BodyAdjoiningPolicy.Ordinary,
            root: Boolean = true, spec: NativeFloatContextSpec.Child = original) =
            nativeTableBodyAdjoiningSpec(source, policy, root, spec)
        assertSame(original, select(policy = null)); assertSame(original, select(root = false))
        for (source in listOf(block.copy(kind = "list_item", depth = 1, listPath = "*"),
            block.copy(depth = 1), block.copy(listPath = ":"), block.copy(number = "1"),
            block.copy(spans = listOf(Span("text", "unowned prefix"))),
            block.copy(feature = Feature("unknown", "xx", "", "", "")),
            Block("paragraph", 0, listOf(Span("text", "ordinary"))))) {
            assertSame(original, select(source = source))
        }
        val fixed = table.copy(style = TableStyle(margins = StyleEdges(
            StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, 0f),
            StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, 0f))))
        val unsupported = listOf(original.copy(autoMarginTable = null), original.copy(autoMargins = null),
            original.copy(autoMarginTable = table.copy()), // Equal model is not the selected source owner.
            original.copy(autoMarginTable = fixed, autoMargins = null),
            original.copy(atomicInline = true), original.copy(floatSide = TableFloatSide.Left, gapAfter = 0f),
            original.copy(gapBefore = 2f))
        for (spec in unsupported) assertSame(spec, select(spec = spec))
        val selected = select()
        assertEquals(original.copy(gapAfter = 0f), selected)
        assertEquals(FigureClear.Both, selected.clear)
        assertEquals(0f, selected.margins(100).top, 0f)
        assertEquals(0f, selected.margins(100).bottom, 0f) // Explicit zero differs from missing owner.
        val missingOwner = original.copy(autoMarginTable = null, autoMargins = null)
        val retained = select(spec = missingOwner)
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeFloatContextGeometry.adjoiningProfile(NativeFloatContextPart.Child(retained.id,
                NativeBlockWidth.Auto, { error("No measurement before authority") }, gapAfter = retained.gapAfter))
        }
        val unresolvedFlow = NativeFloatContextPart.Flow(73,
            { _, _ -> error("No Figure measurement during a structural query") }, gapAfter = 6f)
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeFloatContextGeometry.adjoiningProfile(unresolvedFlow)
        }
    }
}
