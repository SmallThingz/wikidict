package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class ContainerMinimumMarginsTest {
    private fun px(v: Float) = StyleLength(StyleLengthUnit.Px, v)
    private fun margin(v: Float) = SignedContainerMargin(StyleLengthUnit.Px, v)
    private fun group(id: Int, before: Float, after: Float, children: List<NativeFloatContextPart> = emptyList(),
        minimum: NativeContainerMinimum = NativeContainerMinimum(0f, false), height: Float? = null,
        padding: FloatMargins = FloatMargins(0f, 0f, 0f, 0f), isolated: Boolean = false) =
        NativeFloatContextPart.Container(id, 100, { _, _ -> error("Structural query must not measure") },
            margins = SignedNativeContainerMargins(before, 0f, after, 0f), preparedParts = children,
            minimum = minimum, fixedContentHeight = height, padding = padding, isolatesFloats = isolated)
    private fun profile(value: NativeFloatContextPart) = checkNotNull(NativeFloatContextGeometry.adjoiningProfile(value))
    private class Wire {
        val output = ByteArrayOutputStream()
        fun byte(v: Int) { output.write(v) }
        fun short(v: Int) { byte(v); byte(v ushr 8) }
        fun int(v: Int) { repeat(4) { byte(v ushr (it * 8)) } }
        fun text(v: String) { val bytes = v.encodeToByteArray(); int(bytes.size); output.write(bytes) }
        fun length(v: Float, unit: Int = 0) { byte(unit); int(v.toRawBits()) }
    }
    private fun containerFrame(version: Char = 'M', flags: Int = 0, payload: Wire.() -> Unit = {}) = Wire().apply {
        byte(68); byte(80); byte(82); byte(version.code); int(0)
        int(1); byte(2); text("Controlled"); text(""); text(""); int(1)
        byte(13); byte(0); byte(0); int(0); byte(0); text(""); text(""); byte(0); text(""); text(""); repeat(4) { byte(0) }
        if (version == 'M') int(flags) else short(flags)
        payload(); int(0); int(0); int(0); int(1); int(0); int(0); int(0)
    }.output.toByteArray()
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "word", "language", "English", "en")

    @Test fun mMinimumAndEdgesAndSignedMarginsKeepOldGrammarClosed() {
        val encoded = containerFrame(flags = 0x100801) {
            length(10f); length(-3f); length(-8f); length(0f)
            byte(2); byte(3); length(1f); byte(1); text("#aaaaaa")
            byte(0); byte(2); length(2f); byte(1); text("#000000"); byte(1)
            length(1.44f, 1)
        }
        val style = read(encoded).sections.single().blocks.single().container!!.style
        assertEquals(-8f, style.margins!!.bottom.value, 0f)
        assertEquals(StyleLength(StyleLengthUnit.Em, 1.44f), style.minHeight)
        val border = style.border as ContainerBorder.Edges
        assertTrue(border.top is ContainerBorderEdge.Dotted)
        assertEquals(ContainerBorderEdge.Hidden, border.left)
        for (version in listOf('J', 'K', 'L')) assertThrows(Exception::class.java) {
            read(encoded.copyOf().also { it[3] = version.code.toByte() })
        }
        assertEquals(read(containerFrame()).sections, read(containerFrame('L')).sections)
        val positive = containerFrame('L', 1) { repeat(4) { length(1f) } }
        assertThrows(Exception::class.java) { read(positive) }
        assertEquals(1f, read(containerFrame(flags = 1) { repeat(4) { length(1f) } })
            .sections.single().blocks.single().container!!.style.margins!!.top.value, 0f)
        for (bad in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) assertThrows(Exception::class.java) {
            read(containerFrame(flags = 0x100000) { length(bad) })
        }
        for (bad in listOf(Float.NaN, Float.NEGATIVE_INFINITY)) assertThrows(Exception::class.java) {
            read(containerFrame(flags = 1) { length(bad); repeat(3) { length(0f) } })
        }
        assertThrows(Exception::class.java) { read(containerFrame(flags = 0x400000)) }
        for (size in encoded.indices) assertThrows(Exception::class.java) { read(encoded.copyOf(size)) }
    }

    @Test fun pairedStrutsRetainNegativeMembersAcrossNestedAndPendingSets() {
        val nested = profile(group(0, 20f, -4f, listOf(group(1, 10f, -8f))))
        assertEquals(NativeMarginStrut(20f, -8f), nested.beforeSet)
        assertEquals(12f, nested.before, 0f)
        val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
        val first = NativeAdjoiningMargins(0f, -8f, false)
        cursor.end(cursor.begin(first), 10f, first)
        assertEquals(2f, cursor.floatTop, 0f)
        val empty = NativeAdjoiningMargins(-4f, 20f, true)
        val anchor = cursor.begin(empty)
        assertEquals(2f, anchor.borderTop, 0f)
        cursor.end(anchor, 0f, empty)
        assertEquals(22f, cursor.floatTop, 0f)
        val next = NativeAdjoiningMargins(10f, 0f, false)
        assertEquals(22f, cursor.begin(next).borderTop, 0f)
        assertEquals(2f, anchor.borderTop, 0f) // The earlier source anchor is unchanged.
        val negative = NativeAdjoiningMargins.sequence(listOf(NativeAdjoiningMargins(-8f, -4f, true)))
        assertEquals(-8f, negative.before, 0f)
    }

    @Test fun positiveMinimumDistinguishesOwnThroughFromOrdinaryLastBottomEscape() {
        val empty = group(1, 10f, 20f)
        val min = NativeContainerMinimum(0f, true) // Positive border-box minimum absorbed by edges.
        val parent = group(2, 3f, 7f, listOf(empty), minimum = min)
        val resolved = profile(parent)
        assertFalse(resolved.through)
        assertEquals(20f, resolved.before, 0f)
        assertEquals(7f, resolved.after, 0f)
        assertEquals(NativeMarginCollapse(true, false), parent.childCollapse(profile(empty)))
        val real = group(3, 10f, 20f, height = 1f)
        val ordinary = group(4, 3f, 7f, listOf(real), minimum = NativeContainerMinimum(30f, true))
        assertEquals(20f, profile(ordinary).after, 0f)
        assertTrue(ordinary.childCollapse(profile(real)).after)
        assertEquals(30f, ordinary.contentHeight(1f), 0f)
        assertEquals(40f, ordinary.contentHeight(40f), 0f)
        assertFalse(profile(group(5, 0f, 0f, listOf(empty), isolated = true)).through)
        assertEquals(0f, profile(group(6, 0f, 0f, listOf(empty), padding = FloatMargins(1f, 0f, 0f, 0f))).before, 0f)
    }

    @Test fun minimumUsesComputedBodyEmOnceAndFixedHeightRemainsIndependent() {
        val style = ContainerStyle(ownerFontScale = .9f, minHeight = StyleLength(StyleLengthUnit.Em, 1.44f))
        assertEquals(28.8f, containerMinimumHeight(style, 6f, 2f, 20f).content, .0001f)
        assertTrue(containerMinimumHeight(style, 6f, 2f, 20f).computedPositive)
        assertEquals(NativeContainerMinimum(0f, true), containerMinimumHeight(style.copy(minHeight = px(2f),
            boxSizing = ContainerBoxSizing.BorderBox), 6f, 2f, 20f))
        assertEquals(NativeContainerMinimum(0f, false), containerMinimumHeight(style.copy(minHeight = px(0f)), 6f, 2f, 20f))
        assertEquals(NativeContainerMinimum(0f, false), containerMinimumHeight(style.copy(minHeight = StyleLength(StyleLengthUnit.Em, 1f)), 6f, 2f, 0f))
        assertEquals(28.8f, containerMinimumHeight(style.copy(ownerFontScale = 0f), 6f, 2f, 20f).content, .0001f)
        assertEquals(30f, group(0, 0f, 0f, minimum = NativeContainerMinimum(30f, true), height = 10f).contentHeight(100f), 0f)
        assertEquals(40f, group(0, 0f, 0f, minimum = NativeContainerMinimum(30f, true), height = 40f).contentHeight(1f), 0f)
        assertThrows(IllegalArgumentException::class.java) { StyleLength(StyleLengthUnit.Px, -1f) }
        assertThrows(IllegalArgumentException::class.java) { FloatMargins(-1f, 0f, 0f, 0f) }
    }

    @Test fun signedDocumentCapabilityIncludesResponsiveAndDeepOwners() {
        val signed = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Px, -10f), px(0f), px(0f), px(0f))
        val child = Block("container", depth = 0, spans = emptyList(), container = Container(emptyList(), ContainerStyle(margins = signed)))
        assertTrue(child.needsContainerDocumentExtent())
        assertTrue(Block("container", depth = 0, spans = emptyList(), container = Container(listOf(child))).needsContainerDocumentExtent())
        val reset = ContainerMargins(ContainerMargin.Length(px(0f)), ContainerMargin.Auto,
            ContainerMargin.Length(px(0f)), ContainerMargin.Auto)
        val style = ContainerStyle(margins = signed, screenMaxWidth = ContainerScreenMaxWidth(400, margins = reset))
        assertTrue(style.atViewport(401.0).needsDocumentExtent())
        assertFalse(style.atViewport(400.0).needsDocumentExtent())
        assertTrue(child.copy(container = Container(emptyList(), style)).needsContainerDocumentExtent())
        assertFalse(child.copy(container = Container(emptyList(), ContainerStyle(minHeight = px(25f)))).needsContainerDocumentExtent())
        assertEquals(NativeDocumentVerticalExtent(10, 30), nativeDocumentVerticalExtent(15, -10, 20))
    }

    @Test fun signedFollowingCursorUsesLastFlowBottomWhileEarlierInkRemainsIndependent() {
        val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
        val first = NativeAdjoiningMargins(0f, -10f, false)
        val a = cursor.begin(first, null)
        assertEquals(0f, a.borderTop, 0f)
        cursor.end(a, 20f, first)
        val second = NativeAdjoiningMargins(0f, 0f, false)
        val b = cursor.begin(second, null)
        assertEquals(10f, b.borderTop, 0f)
        cursor.end(b, 5f, second)
        val used = cursor.finish()
        assertEquals(15f, used, 0f)
        assertEquals(25f, group(0, 0f, 0f, minimum = NativeContainerMinimum(25f, true)).contentHeight(used), 0f)
        assertEquals(NativeDocumentVerticalExtent(0, 20), nativeDocumentVerticalExtent(used.toInt(), 0, 20))
    }

    @Test fun signedHorizontalOffsetsAndResponsiveResetPreserveNormalAllocation() {
        val original = ContainerStyle(margins = SignedContainerEdges(margin(-2f), margin(-7f), margin(-8f), margin(-5f)),
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 80f)),
            screenMaxWidth = ContainerScreenMaxWidth(100, margins = ContainerMargins(ContainerMargin.Length(px(0f)),
                ContainerMargin.Auto, ContainerMargin.Length(px(0f)), ContainerMargin.Auto)))
        val wide = containerBoxWidth(original.atViewport(101.0), 100f, ContainerWidths(10f, 20f), 1f, 20f)
        assertEquals(-5f, wide.marginLeft, 0f)
        assertEquals(25f, wide.marginRight, 0f)
        assertEquals(100f, wide.marginBox, 0f)
        val horizontal = NativeContainerHorizontal.from(wide, 0f, -5f, -7f)
        assertEquals(-5f, horizontal.contentLeft, 0f)
        assertEquals(75f, horizontal.collisionRight, 0f)
        val reset = containerBoxWidth(original.atViewport(100.0), 100f, ContainerWidths(10f, 20f), 1f, 20f)
        assertEquals(10f, reset.marginLeft, 0f)
        assertEquals(10f, reset.marginRight, 0f)
    }

    @Test fun hiddenBeatsWiderCellBorderAndTallrikSideOverrideRemainsAuthoritative() {
        val none = StyleBorderEdge.None
        val dotted = StyleBorderEdge.Dotted(px(1f), "#aaaaaa")
        val hidden = StyleBorder.Edges(none, StyleBorderEdge.Hidden, dotted, none)
        val wide = StyleBorder.Edges(none, none, dotted, StyleBorderEdge.Solid(px(8f), "#000000"))
        fun cell(style: CellStyle, span: Int = 1) = Cell(listOf(Span("link", "kept", target = "kept")), false, span, 1, style = style)
        val table = Table(emptyList(), listOf(listOf(cell(CellStyle(border = hidden)), cell(CellStyle(border = wide))),
            listOf(cell(CellStyle(border = StyleBorder.None), 2))), style = TableStyle(collapse = TableCollapse.Collapse))
        for (rtl in listOf(false, true)) {
            val directional = if (!rtl) table else table.copy(rows = listOf(listOf(
                cell(CellStyle(border = StyleBorder.Edges(none, none, dotted, StyleBorderEdge.Hidden))),
                cell(CellStyle(border = StyleBorder.Edges(none, StyleBorderEdge.Solid(px(8f), "#000000"), dotted, none)))),
                table.rows.last()))
            val resolved = resolveTableStyle(directional, tableGrid(directional), 1f, 20f, 0, 0, rtl = rtl)
            assertEquals(0, if (rtl) resolved.cellInsets[0].left else resolved.cellInsets[0].right)
            assertEquals(0, if (rtl) resolved.cellInsets[1].right else resolved.cellInsets[1].left)
            assertEquals(1, resolved.cellInsets[0].bottom)
        }
        val overridden = table.copy(rows = listOf(listOf(cell(CellStyle(border = hidden,
            borderEdges = CellBorderEdges(right = CellBorder.Double(px(3f), "#112233")))))))
        val resolved = resolveTableStyle(overridden, tableGrid(overridden), 1f, 20f, 0, 0)
        assertEquals(TableStroke.Double, resolved.cellEdges.single().right.stroke)
        assertEquals(3f, resolved.cellEdges.single().right.width, 0f)
        assertEquals("kept", overridden.rows.single().single().spans.single().target)
    }

    @Test fun asymmetricOuterTableEdgesReachActualPixelsAndRtlCellOrigins() {
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1))),
            style = TableStyle(border = StyleBorder.Edges(StyleBorderEdge.Dotted(px(1f), "#aaaaaa"),
                StyleBorderEdge.Solid(px(3f), "#000000"), StyleBorderEdge.Hidden, StyleBorderEdge.Solid(px(5f), "#000000"))))
        val metrics = checkNotNull(tableRenderMetrics(table, 40, 0, 10, 1f, containerFontPixels = 20f))
        assertEquals(TablePixelInsets(1, 3, 0, 5), metrics.outerBorder)
        val pixels = checkNotNull(tablePixelLayout(tableGrid(table), metrics.columnWidth, 10, intArrayOf(10),
            metrics.cellSpacing, metrics.borderWidth, metrics.width, metrics.extraColumns,
            metrics.style!!.tablePadding, metrics.columnWidths, metrics.outerBorder))
        assertEquals(48, pixels.width)
        assertEquals(11, pixels.height)
        assertEquals(5, pixels.physicalCellLeft(0, 1, false))
        assertEquals(5, pixels.physicalCellLeft(0, 1, true))
        assertEquals(TableStroke.Dotted, separateCellBorderSegments(0f, 0f, 48f, 11f, metrics.style.outerEdges).first().stroke)
    }

    @Test fun negativeSourceOriginDoesNotClampFloatPlacementOrClearance() {
        val earlier = NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, -10f, 20f, 5f))
        assertEquals(-8f, tableClearanceY(-8f, FigureClear.None, listOf(earlier)), 0f)
        assertEquals(5f, tableClearanceY(-8f, FigureClear.Left, listOf(earlier)), 0f)
        var calls = 0
        val placed = placeNativeFloatingTable(100f, -8f, emptyList(), TableFloatSide.Left,
            FloatMargins(0f, 0f, 0f, 0f), NativeBlockWidth.FixedPx(20f), pixelAligned = false) {
            calls++; NativeBlockMeasure(20f, 20f, 10f)
        }
        assertEquals(-8f, placed.outer.top, 0f)
        assertEquals(2f, placed.outer.bottom, 0f)
        assertEquals(1, calls)
    }

    @Test fun mStyleEdgesAtCellSinkPreserveFourSidesAndRejectOldHeaderAndUnknownSide() {
        fun frame(version: Char = 'M', side: Int = 3) = Wire().apply {
            byte(68); byte(80); byte(82); byte(version.code); int(0)
            int(1); byte(2); text("Controlled"); text(""); text("")
            int(1); byte(12); byte(0); byte(0); int(0); byte(0); text(""); text("")
            byte(1); byte(0); int(0); int(1); int(1)
            byte(0); short(1); short(1); byte(0); int(0); byte(0); byte(0)
            byte(1); byte(1); byte(2)
            byte(side); length(1f); text("#aaaaaa"); byte(1); byte(0); byte(2); length(5f); text("#000000")
            byte(0); byte(0); text(""); text(""); byte(0); byte(0); byte(0); byte(0)
            repeat(5) { int(0) }
        }.output.toByteArray()
        val bytes = frame()
        val border = read(bytes).sections.single().blocks.single().table!!.rows.single().single().style!!.border as StyleBorder.Edges
        assertEquals(StyleBorderEdge.Dotted(px(1f), "#aaaaaa"), border.top)
        assertEquals(StyleBorderEdge.Hidden, border.right)
        assertEquals(StyleBorderEdge.None, border.bottom)
        assertEquals(StyleBorderEdge.Solid(px(5f), "#000000"), border.left)
        for (version in listOf('J', 'K', 'L')) assertThrows(Exception::class.java) { read(frame(version)) }
        assertThrows(Exception::class.java) { read(frame(side = 4)) }
        for (size in bytes.indices) assertThrows(Exception::class.java) { read(bytes.copyOf(size)) }
    }


    @Test fun mBaseAutoMarginsFollowMinimumTailAndKeepAbsentLegacyBytes() {
        val encoded = containerFrame(flags = 0x300000) {
            length(4f)
            byte(1); length(-.25f, 1); byte(0); byte(1); length(0f); byte(0)
        }
        val style = read(encoded).sections.single().blocks.single().container!!.style
        assertEquals(px(4f), style.minHeight)
        assertNull(style.margins)
        assertEquals(ContainerMargin.Auto, style.marginValues!!.left)
        assertEquals(ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Em, -.25f)), style.marginValues!!.top)
        assertFalse(legacyContainerMarginsSupported(Container(emptyList(), style)))
        for (version in listOf('J', 'K', 'L')) assertThrows(Exception::class.java) {
            read(encoded.copyOf().also { it[3] = version.code.toByte() })
        }
        assertEquals(read(containerFrame()).sections, read(containerFrame('L')).sections)
        assertThrows(Exception::class.java) { read(containerFrame(flags = 0x200001) {
            repeat(4) { length(0f) }; repeat(4) { byte(0) }
        }) }
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) assertThrows(Exception::class.java) {
            read(containerFrame(flags = 0x200000) { byte(1); length(bad); repeat(3) { byte(0) } })
        }
        assertThrows(Exception::class.java) { read(containerFrame(flags = 0x200000) { byte(2); repeat(3) { byte(0) } }) }
        assertThrows(Exception::class.java) { read(containerFrame(flags = 0x400000)) }
        for (size in encoded.indices) assertThrows(Exception::class.java) { read(encoded.copyOf(size)) }
        assertThrows(Exception::class.java) { read(encoded + byteArrayOf(0)) }
    }

    @Test fun baseAutoMarginsSeedOrderedViewportRulesWithoutLeavingDuplicateState() {
        val zero = ContainerMargin.Length(px(0f))
        val base = ContainerMargins(zero, ContainerMargin.Auto, zero, ContainerMargin.Auto)
        val intermediate = base.copy(right = ContainerMargin.Length(px(5f)))
        val reset = ContainerMargins(zero, zero, zero, zero)
        val style = ContainerStyle(marginValues = base, screenMaxWidth = ContainerScreenMaxWidth(500,
            margins = intermediate, followingRules = listOf(ContainerScreenMaxWidth(300, margins = reset))))
        for ((viewport, margins) in listOf(501.0 to base, 500.0 to intermediate, 300.0 to reset)) {
            val resolved = style.atViewport(viewport)
            assertEquals(margins, resolved.margins)
            assertNull(resolved.box.margins); assertNull(resolved.box.marginValues); assertNull(resolved.box.screenMaxWidth)
        }
        val numeric = SignedContainerEdges(px(0f), px(0f), px(0f), px(0f))
        assertThrows(IllegalArgumentException::class.java) { ContainerStyle(margins = numeric, marginValues = base) }
        assertThrows(IllegalArgumentException::class.java) { ContainerViewportStyle(ContainerStyle(marginValues = base), null) }
    }

    @Test fun baseAutoMarginsResolveAfterWidthAndKeepFloatFlexAndDirectionRules() {
        val zero = ContainerMargin.Length(px(0f))
        val auto = ContainerMargins(zero, ContainerMargin.Auto, zero, ContainerMargin.Auto)
        val style = ContainerStyle(marginValues = auto)
        val intrinsic = ContainerWidths(20f, 80f)
        fun box(value: ContainerStyle, rtl: Boolean = false) = containerBoxWidth(value.atViewport(1000.0),
            300f, intrinsic, 1f, 20f, rtl = rtl)
        assertEquals(ContainerBoxWidth(300f, 300f, 300f, 0f, 0f), box(style))
        val constrained = style.copy(maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 100f)))
        assertEquals(ContainerBoxWidth(100f, 100f, 300f, 100f, 100f), box(constrained))
        val oversized = style.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 400f)))
        assertEquals(-100f, box(oversized).marginRight, 0f)
        assertEquals(0f, box(oversized).marginLeft, 0f)
        assertEquals(-100f, box(oversized, rtl = true).marginLeft, 0f)
        assertEquals(0f, box(oversized, rtl = true).marginRight, 0f)
        assertEquals(ContainerBoxWidth(80f, 80f, 80f, 0f, 0f), box(style.copy(floatSide = TableFloatSide.Left)))
        val flex = containerFlexMeasure(style.atViewport(1000.0), 300f, intrinsic, 1f, 20f)
        assertEquals(80f, flex.basis, 0f)
        assertEquals(listOf(110f to 110f), containerFlexMargins(300f, listOf(flex), listOf(80f)))
        val em = auto.copy(left = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Em, 1f)))
        assertEquals(20f, box(style.copy(ownerFontScale = .5f, marginValues = em)).marginLeft, 0f)
    }

    @Test fun negativeBaseMarginValuesReachDeepDocumentExtentBeforeViewportReset() {
        val zero = ContainerMargin.Length(px(0f))
        val negative = ContainerMargins(ContainerMargin.Length(margin(-10f)), ContainerMargin.Auto, zero, ContainerMargin.Auto)
        val reset = ContainerMargins(zero, zero, zero, zero)
        val style = ContainerStyle(marginValues = negative,
            screenMaxWidth = ContainerScreenMaxWidth(400, margins = reset))
        val child = Block("container", 0, emptyList(), container = Container(emptyList(), style))
        assertTrue(child.needsContainerDocumentExtent())
        assertTrue(style.atViewport(401.0).needsDocumentExtent())
        assertFalse(style.atViewport(400.0).needsDocumentExtent())
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(child)))))
        assertTrue(Block("table", 0, emptyList(), table = table).needsContainerDocumentExtent())
        assertEquals(NativeDocumentVerticalExtent(10, 30), nativeDocumentVerticalExtent(15, -10, 20))
        assertFalse(child.copy(container = Container(emptyList(), ContainerStyle(marginValues = reset))).needsContainerDocumentExtent())
    }

    @Test fun ordinaryBodyAbsorbsBothEdgesWithoutTranslatingEarlierFloats() {
        for (after in listOf(30f, -30f)) {
            val body = NativeMarginCursor(NativeMarginCollapse(true, true))
            val initialFloatTop = body.floatTop
            assertEquals(0f, initialFloatTop, 0f)
            val ordinary = NativeAdjoiningMargins(20f, after, false)
            val placed = body.begin(ordinary)
            assertEquals(0f, placed.borderTop, 0f)
            body.end(placed, 10f, ordinary)
            assertEquals(10f, body.finish(), 0f)
            assertEquals(40f, maxOf(body.finish(), initialFloatTop + 40f), 0f)
            assertEquals(0f, initialFloatTop, 0f)

            val legacy = NativeMarginCursor(NativeMarginCollapse(false, false))
            val oldPlaced = legacy.begin(ordinary)
            assertEquals(20f, oldPlaced.borderTop, 0f)
            legacy.end(oldPlaced, 10f, ordinary)
            assertEquals(30f + after, legacy.finish(), 0f)
        }
        val floatOnly = NativeMarginCursor(NativeMarginCollapse(true, true))
        assertEquals(0f, floatOnly.finish(), 0f)
        assertEquals(40f, maxOf(floatOnly.finish(), floatOnly.floatTop + 40f), 0f)
    }

    @Test fun ordinaryBodyEmptyChainsAndZeroHeightBarriersKeepStructuralMeaning() {
        val body = NativeMarginCursor(NativeMarginCollapse(true, true))
        for (margins in listOf(NativeAdjoiningMargins(20f, 30f, true),
            NativeAdjoiningMargins(-50f, -10f, true))) {
            val placement = body.begin(margins)
            assertEquals(0f, placement.borderTop, 0f)
            body.end(placement, 0f, margins)
            assertTrue(body.adjoiningTop)
            assertEquals(0f, body.floatTop, 0f)
            assertEquals(0f, body.finish(), 0f)
        }
        val barrier = NativeAdjoiningMargins(0f, 0f, false)
        body.end(body.begin(barrier), 0f, barrier)
        assertFalse(body.adjoiningTop)
        val later = NativeAdjoiningMargins(20f, 30f, false)
        val placement = body.begin(later)
        assertEquals(20f, placement.borderTop, 0f)
        body.end(placement, 10f, later)
        assertEquals(30f, body.finish(), 0f)
    }

    @Test fun ordinaryBodyBlockedTrailingClearanceRetainsPositiveAndNegativeMembers() {
        for ((after, expected) in listOf(30f to 65f, -30f to 10f)) {
            val first = NativeAdjoiningMargins(0f, 0f, false)
            val trailing = NativeAdjoiningMargins(5f, after, true)
            val body = NativeMarginCursor(NativeMarginCollapse(true, true))
            body.end(body.begin(first), 10f, first)
            val cleared = body.begin(trailing, clearBottom = 40f)
            assertEquals(40f, cleared.borderTop, 0f)
            assertEquals(25f, cleared.clearance!!, 0f)
            body.end(cleared, 0f, trailing)
            assertEquals(expected, body.finish(), 0f)

            val withoutClearance = NativeMarginCursor(NativeMarginCollapse(true, true))
            withoutClearance.end(withoutClearance.begin(first), 10f, first)
            withoutClearance.end(withoutClearance.begin(trailing), 0f, trailing)
            assertEquals(10f, withoutClearance.finish(), 0f)
        }
    }

    @Test fun ordinaryBodyLeadingResolutionSharesFloatMeasurementsAndClearanceProof() {
        var measures = 0
        var measuredRequest: NativeBlockMeasureRequest? = null
        val floating = NativeFloatContextPart.Child(81, NativeBlockWidth.FixedPx(10f), { request ->
            measures++; measuredRequest = request
            NativeBlockMeasure(10f, 10f, 40f)
        }, floatSide = TableFloatSide.Left)
        val cleared = NativeFloatContextPart.Child(82, NativeBlockWidth.FixedPx(10f),
            { error("Leading resolution must not measure an ordinary child") },
            margins = FloatMargins(20f, 0f, 30f, 0f), clear = FigureClear.Both)
        val parts = listOf(floating, cleared)
        val preparation = NativeOrdinaryPreparation(parts)
        preparation.resolveBodyLeading(parts, 100)
        assertEquals(1, measures)
        assertTrue(preparation.hasClearance(cleared))
        preparation.resolveBodyLeading(parts, 100)
        preparation.measureChild(floating, checkNotNull(measuredRequest))
        assertEquals(1, measures)
        val resolved = checkNotNull(NativeFloatContextGeometry.adjoiningProfile(cleared, preparation))
        assertFalse(resolved.beforeAdjoins)
        val body = NativeMarginCursor(NativeMarginCollapse(true, true))
        val placement = body.begin(resolved, 40f, resolvedClearance = preparation.hasClearance(cleared))
        assertEquals(40f, placement.borderTop, 0f)
        assertEquals(20f, placement.clearance!!, 0f)
        body.end(placement, 10f, resolved)
        assertEquals(50f, body.finish(), 0f)
        assertFalse(NativeOrdinaryPreparation(parts).hasClearance(cleared))
    }

    @Test fun ordinaryBodyLeadingFlowRefusesOnlyItsUnprovedZeroExtentAndRecovers() {
        fun flow(id: Int) = NativeFloatContextPart.Flow(id,
            { _, _ -> error("A structural root pass must not measure anonymous flow") })
        val first = flow(91)
        val parts = listOf(first)
        val legacy = NativeOrdinaryPreparation(parts)
        legacy.checkBodyLeadingFlow(first, 0f, exportsFloats = true)
        val preparation = NativeOrdinaryPreparation(parts)
        preparation.resolveBodyLeading(parts, 100)
        val failure = assertThrows(UnsupportedFloatLayout::class.java) {
            preparation.checkBodyLeadingFlow(first, 0f, exportsFloats = true)
        }
        assertEquals("Ordinary body leading float flow has no structural adjoining profile", failure.message)
        preparation.checkBodyLeadingFlow(first, 1f, exportsFloats = true)
        preparation.checkBodyLeadingFlow(first, 0f, exportsFloats = false)

        val nested = flow(92)
        val wrapper = group(93, 0f, 0f, listOf(nested))
        val nestedPreparation = NativeOrdinaryPreparation(listOf(wrapper))
        nestedPreparation.resolveBodyLeading(listOf(wrapper), 100)
        assertThrows(UnsupportedFloatLayout::class.java) {
            nestedPreparation.checkBodyLeadingFlow(nested, 0f, exportsFloats = true)
        }
        val barrier = NativeFloatContextPart.Child(94, NativeBlockWidth.FixedPx(10f),
            { error("A structural barrier must not be measured") })
        val afterBarrier = flow(95)
        val later = listOf(barrier, afterBarrier)
        val laterPreparation = NativeOrdinaryPreparation(later)
        laterPreparation.resolveBodyLeading(later, 100)
        laterPreparation.checkBodyLeadingFlow(afterBarrier, 0f, exportsFloats = true)
    }

    @Test fun ordinaryBodyRejectsIncompleteRootBoundaryBeforeNativeLayout() {
        fun refused(adjoining: Boolean, collapse: NativeMarginCollapse, contain: Boolean,
            incoming: List<NativeFloatExclusion> = emptyList()) {
            val failure = assertThrows(UnsupportedFloatLayout::class.java) {
                NativeFloatContextGeometry.build(100, emptyList(), containAtEnd = contain,
                    carriedExclusions = incoming, adjoining = adjoining, marginCollapse = collapse,
                    bodyAdjoining = true)
            }
            assertEquals("Ordinary body requires its complete root margin boundary", failure.message)
        }
        refused(false, NativeMarginCollapse(true, true), true)
        refused(true, NativeMarginCollapse(false, true), true)
        refused(true, NativeMarginCollapse(true, false), true)
        refused(true, NativeMarginCollapse(true, true), false)
        refused(true, NativeMarginCollapse(true, true), true,
            listOf(NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 10f, 40f))))
    }
}
