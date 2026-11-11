package app.smallthingz.dict

import android.text.SpannableString
import android.text.TextPaint
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Typed container geometry controls; actual compiled cubeb rendering remains separate. */
@RunWith(AndroidJUnit4::class)
class ContainerGeometryDeviceTest {
    private val paint = TextPaint().apply { textSize = 18f }
    private fun text(value: String, action: (() -> Unit)? = null) = NativeFloatContextPart.Text(value, { width, carried ->
        NativeFloatGeometry.build(SpannableString(value), paint, width, emptyList(), carriedExclusions = carried,
            nodeFactory = { geometry -> if (action == null) emptyList() else listOf(
                FloatInteractionNode(0, FloatInteractionKind.LINK, 0, value.length,
                    geometry.rectsForRange(0, value.length), value, null, action)) })
    })
    private fun float(id: Int, side: TableFloatSide, width: Float, height: Float) =
        NativeFloatContextPart.Child(id, NativeBlockWidth.FixedPx(width),
            { NativeBlockMeasure(width, width, height) }, floatSide = side)

    @Test fun ordinaryContainerTranslatesIncomingFloatsAndExportsProtrudingDescendants() {
        var delivered = 0
        var incoming = emptyList<NativeFloatExclusion>()
        lateinit var nested: NativeFloatContextGeometry
        val container = NativeFloatContextPart.Container(10, 210, { width, carried ->
            incoming = carried
            NativeFloatContextGeometry.build(width, listOf(
                float(11, TableFloatSide.Right, 40f, 160f), text("Inside", { delivered++ })),
                containAtEnd = false, carriedExclusions = carried, allowProtrudingFloats = true).also { nested = it }
        }, margins = FloatMargins(0f, 10f, 0f, 60f), padding = FloatMargins(0f, 10f, 0f, 10f))
        val geometry = NativeFloatContextGeometry.build(300, listOf(
            float(1, TableFloatSide.Left, 80f, 120f), container, text("After")))
        assertEquals(1, incoming.size)
        assertEquals(-70f, incoming.single().outer.left, .01f)
        assertEquals(10f, incoming.single().outer.right, .01f)
        assertEquals(1, nested.ownExclusions.size)
        assertEquals(kotlin.math.ceil(nested.textBottom).toInt(), nested.height)
        assertTrue(nested.extents.ink!!.bottom > nested.height)
        assertEquals(2, geometry.ownExclusions.size)
        val exported = geometry.ownExclusions.single { it.side == TableFloatSide.Right }
        assertEquals(240f, exported.outer.left, .01f)
        assertEquals(280f, exported.outer.right, .01f)
        val after = geometry.caretRect(geometry.text.indexOf("After"))
        assertTrue("Normal DIV does not enclose its float", after.top < exported.outer.bottom)
        assertTrue("Following text avoids the preceding parent float", after.left >= 80f)
        assertTrue("Following text avoids the exported descendant float", after.left < exported.outer.left)
        val node = geometry.nodes.single { it.label == "Inside" }
        assertTrue(node.bounds.first().left >= 80f)
        node.onClick!!()
        assertEquals(1, delivered)
    }

    @Test fun floatedContainerOwnsItsBfcAndExportsOnlyItsMarginBox() {
        var measured = 0
        var incoming: List<NativeFloatExclusion>? = null
        val container = NativeFloatContextPart.Container(10, 150, { width, carried ->
            measured++
            incoming = carried
            NativeFloatContextGeometry.build(width, listOf(float(11, TableFloatSide.Right, 100f, 180f), text("Inside")))
        }, margins = FloatMargins(5f, 10f, 7f, 60f), padding = FloatMargins(10f, 10f, 10f, 10f),
            floatSide = TableFloatSide.Left)
        val geometry = NativeFloatContextGeometry.build(400, listOf(
            float(1, TableFloatSide.Right, 80f, 100f), container, text("After")))
        assertEquals(1, measured)
        assertTrue(checkNotNull(incoming).isEmpty())
        assertEquals(2, geometry.ownExclusions.size)
        val outer = geometry.ownExclusions.single { it.side == TableFloatSide.Left }.outer
        assertEquals(240f, outer.right - outer.left, .01f)
        assertEquals(212f, outer.bottom - outer.top, .01f)
        val child = geometry.flowChildren.single { it.id == 10 }.bounds
        assertEquals(70f, child.left, .01f)
        assertEquals(15f, child.top, .01f)
        assertTrue(geometry.caretRect(geometry.text.indexOf("After")).left >= outer.right)
    }

    @Test fun normalContainerClearUsesParentExclusionsAndUnimplementedAdjoiningMarginsRefuse() {
        val clear = NativeFloatContextPart.Container(10, 200, { width, carried ->
            assertTrue(carried.isEmpty())
            NativeFloatContextGeometry.build(width, listOf(text("Cleared")), containAtEnd = false,
                carriedExclusions = carried, allowProtrudingFloats = true)
        }, clear = FigureClear.Both)
        val geometry = NativeFloatContextGeometry.build(300, listOf(float(1, TableFloatSide.Left, 80f, 120f), clear))
        assertTrue(geometry.caretRect(geometry.text.indexOf("Cleared")).top >= 120f)
        try {
            NativeFloatContextGeometry.build(300, listOf(clear.copy(margins = FloatMargins(1f, 0f, 0f, 0f))))
            fail("Ordinary adjoining margins must not silently become additive")
        } catch (_: UnsupportedFloatLayout) { }
    }

    @Test fun flexFormattingContextIsolatesIncomingFloatsAndContainsItsOwnWithoutExportingThem() {
        var measured = 0
        var activated = 0
        val container = NativeFloatContextPart.Container(10, 150, { width, carried ->
            measured++
            assertTrue(carried.isEmpty())
            NativeFloatContextGeometry.build(width, listOf(
                float(11, TableFloatSide.Right, 60f, 180f), text("Inside", { activated++ })))
        }, margins = FloatMargins(0f, 10f, 0f, 10f), padding = FloatMargins(10f, 10f, 10f, 10f),
            isolatesFloats = true)
        val geometry = NativeFloatContextGeometry.build(300, listOf(
            float(1, TableFloatSide.Left, 80f, 120f), container, text("After")))
        assertEquals(1, measured)
        assertEquals(1, geometry.ownExclusions.size)
        val content = geometry.flowChildren.single { it.id == 10 }.bounds
        assertEquals(100f, content.left, .01f)
        assertEquals(10f, content.top, .01f)
        assertTrue(geometry.caretRect(geometry.text.indexOf("After")).top >= 200f)
        geometry.nodes.single { it.label == "Inside" }.onClick!!()
        assertEquals(1, activated)
    }

    @Test fun ordinaryZeroHeightKeepsProtrudingFloatInkWhileTheSameBfcContainsIt() {
        val child = float(1, TableFloatSide.Left, 40f, 50f)
        val ordinary = NativeFloatContextGeometry.build(100, listOf(child), containAtEnd = false,
            allowProtrudingFloats = true)
        assertEquals(0, ordinary.height)
        assertEquals(0f, ordinary.textBottom, 0f)
        assertEquals(50f, ordinary.extents.ink!!.bottom, 0f)
        assertEquals(50f, ordinary.extents.interaction!!.bottom, 0f)
        assertTrue(ordinary.containsInteraction(20f, 25f))
        assertEquals(0, ordinary.offsetForPosition(20f, 25f))
        assertEquals(50f, ordinary.ownExclusions.single().outer.bottom, 0f)
        val isolated = NativeFloatContextGeometry.build(100, listOf(child))
        assertEquals(50, isolated.height)
        assertEquals(ordinary.children, isolated.children)
        assertEquals(ordinary.text, isolated.text)
    }

    private fun block(id: Int, height: Float, top: Float = 0f, bottom: Float = 0f,
        clear: FigureClear? = null, measured: () -> Unit = {}) = NativeFloatContextPart.Child(
        id, NativeBlockWidth.FixedPx(10f), { measured(); NativeBlockMeasure(10f, 10f, height) },
        margins = FloatMargins(top, 0f, bottom, 0f), clear = clear)

    private fun adjoiningContainer(id: Int, children: List<NativeFloatContextPart>,
        top: Float = 0f, bottom: Float = 0f, paddingTop: Float = 0f, paddingBottom: Float = 0f,
        isolated: Boolean = false, floating: TableFloatSide? = null, measured: () -> Unit = {}) =
        NativeFloatContextPart.Container(id, 100, { _, _ -> error("Adjoining control used the legacy child path") },
            margins = FloatMargins(top, 0f, bottom, 0f), padding = FloatMargins(paddingTop, 0f, paddingBottom, 0f),
            floatSide = floating, empty = children.isEmpty(), isolatesFloats = isolated,
            innerMargins = NativeFloatContextGeometry.adjoiningMarginsFor(children),
            buildAdjoining = { width, carried, collapse ->
                measured()
                NativeFloatContextGeometry.build(width, children, containAtEnd = isolated || floating != null,
                    carriedExclusions = carried, allowProtrudingFloats = !isolated && floating == null,
                    adjoining = true, marginCollapse = collapse)
            })

    @Test fun adjoiningSiblingsParentsAndPerSideBarriersKeepMarginsOutsideRealBoxes() {
        fun layout(parts: List<NativeFloatContextPart>) = NativeFloatContextGeometry.build(300, parts, adjoining = true)
        val siblings = layout(listOf(block(1, 10f, bottom = 12f), block(2, 10f, top = 20f)))
        assertEquals(30f, siblings.children.single { it.id == 2 }.bounds.top, 0f)
        for (ownTop in listOf(0f, 10f)) {
            var measured = 0
            val parent = layout(listOf(adjoiningContainer(10, listOf(block(11, 10f, top = 20f)), top = ownTop) { measured++ }))
            assertEquals(1, measured)
            assertEquals(20f, parent.marginPlacements.getValue(0).borderTop, 0f)
            assertEquals(20f, parent.flowChildren.single().bounds.top, 0f)
            assertEquals(10f, parent.flowChildren.single().bounds.height(), 0f)
        }
        val topBarrier = layout(listOf(adjoiningContainer(10, listOf(block(11, 10f, top = 20f)),
            top = 10f, paddingTop = 1f)))
        assertEquals(10f, topBarrier.marginPlacements.getValue(0).borderTop, 0f)
        assertEquals(11f, topBarrier.flowChildren.single().bounds.top, 0f)
        assertEquals(31, topBarrier.height - 10)
        assertEquals(31f, topBarrier.rectsForRange(0, 1).single().top, 0f)
        val uniformBorder = layout(listOf(adjoiningContainer(10, listOf(block(11, 10f, top = 20f)),
            top = 10f, paddingTop = 1f, paddingBottom = 1f)))
        assertEquals(32, uniformBorder.height - 10)
        val bottom = layout(listOf(adjoiningContainer(10, listOf(block(11, 10f, bottom = 20f)), bottom = 10f), block(20, 10f)))
        assertEquals(10f, bottom.flowChildren.single().bounds.height(), 0f)
        assertEquals(30f, bottom.children.single().bounds.top, 0f)
        val bottomBarrier = layout(listOf(adjoiningContainer(10, listOf(block(11, 10f, bottom = 20f)),
            bottom = 10f, paddingBottom = 1f), block(20, 10f)))
        assertEquals(41f, bottomBarrier.children.single().bounds.top, 0f)
    }

    @Test fun throughEmptyOwnerKeepsItsFloatAnchorBeforeALaterLargerMargin() {
        var measured = 0
        val emptyWithFloat = adjoiningContainer(2, listOf(float(21, TableFloatSide.Left, 40f, 50f)),
            top = 5f, bottom = 7f) { measured++ }
        val geometry = NativeFloatContextGeometry.build(300, listOf(block(1, 10f, bottom = 12f),
            emptyWithFloat, block(3, 10f, top = 20f)), containAtEnd = false,
            allowProtrudingFloats = true, adjoining = true)
        assertEquals(1, measured)
        assertEquals(22f, geometry.marginPlacements.getValue(1).borderTop, 0f)
        assertEquals(0f, geometry.flowChildren.single().bounds.height(), 0f)
        assertEquals(22f, geometry.ownExclusions.single().outer.top, 0f)
        assertEquals(72f, geometry.ownExclusions.single().outer.bottom, 0f)
        assertEquals(30f, geometry.children.single { it.id == 3 }.bounds.top, 0f)
        assertEquals(40, geometry.height)
        assertTrue(geometry.extents.interaction!!.bottom >= 72f)
    }

    @Test fun clearanceKeepsNegativeAndZeroProvenanceWhileEveryRealChildIsMeasuredOnce() {
        for ((height, expectedTop, expectedClearance) in listOf(Triple(20f, 60f, -10f), Triple(30f, 70f, 0f))) {
            var count = 0
            val geometry = NativeFloatContextGeometry.build(300, listOf(block(1, 0f, bottom = 40f),
                float(2, TableFloatSide.Left, 40f, height),
                block(3, 10f, top = 30f, clear = FigureClear.Both) { count++ }), adjoining = true)
            assertEquals(1, count)
            assertEquals(40f, geometry.ownExclusions.single().outer.top, 0f)
            assertEquals(expectedTop, geometry.children.single { it.id == 3 }.bounds.top, 0f)
            val placement = geometry.marginPlacements.getValue(2)
            assertNotNull(placement.clearance)
            assertEquals(expectedClearance, placement.clearance!!, 0f)
        }
    }

    @Test fun bfcConsumesChildMarginsWithoutMovingEarlierFloatsAndKeepsOuterMarginsSeparate() {
        var measured = 0
        val childParts = listOf(block(11, 10f, top = 30f, bottom = 40f))
        val floating = NativeFloatContextGeometry.build(300, listOf(adjoiningContainer(10, childParts,
            top = 10f, bottom = 20f, floating = TableFloatSide.Left) { measured++ }), adjoining = true)
        assertEquals(1, measured)
        assertEquals(0f, floating.textBottom, 0f)
        assertEquals(0f, floating.ownExclusions.single().outer.top, 0f)
        assertEquals(110f, floating.ownExclusions.single().outer.bottom, 0f)
        assertEquals(10f, floating.flowChildren.single().bounds.top, 0f)
        assertEquals(80f, floating.flowChildren.single().bounds.height(), 0f)
        val scroll = NativeFloatContextGeometry.build(300, listOf(adjoiningContainer(10,
            listOf(float(11, TableFloatSide.Left, 40f, 50f)), isolated = true), block(20, 10f)), adjoining = true)
        assertTrue(scroll.ownExclusions.isEmpty())
        assertEquals(50f, scroll.children.single().bounds.top, 0f)
        val padded = NativeFloatContextGeometry.build(300, listOf(adjoiningContainer(10,
            listOf(float(11, TableFloatSide.Left, 40f, 50f), block(12, 10f, top = 20f)),
            top = 10f, paddingTop = 1f)), adjoining = true)
        assertEquals(11f, padded.ownExclusions.single().outer.top, 0f)
        assertEquals(31f, padded.rectsForRange(2, 3).single().top, 0f)
    }

    @Test fun oneSidedEmptySetsEscapeOnceWithoutMovingTheirOwnFloatAnchors() {
        for (paddingTop in listOf(true, false)) {
            var measured = 0
            val empty = adjoiningContainer(11, listOf(float(12, TableFloatSide.Left, 40f, 3f)),
                top = 5f, bottom = 7f) { measured++ }
            val parent = adjoiningContainer(10, listOf(empty), paddingTop = if (paddingTop) 1f else 0f,
                paddingBottom = if (paddingTop) 0f else 1f)
            val geometry = NativeFloatContextGeometry.build(300, listOf(parent, block(20, 10f)), adjoining = true)
            assertEquals(1, measured)
            assertEquals(if (paddingTop) 0f else 7f, geometry.marginPlacements.getValue(0).borderTop, 0f)
            assertEquals(0f, geometry.flowChildren.single().bounds.height(), 0f)
            assertEquals(if (paddingTop) 6f else 7f, geometry.ownExclusions.single().outer.top, 0f)
            assertEquals(8f, geometry.children.single().bounds.top, 0f)
        }
    }

    @Test fun emptyAndZeroFloatBfcKeepTheirOwnMarginsSeparateAtRealZeroHeight() {
        for (children in listOf(emptyList(), listOf(float(21, TableFloatSide.Left, 40f, 0f)))) {
            var measured = 0
            val isolated = adjoiningContainer(2, children, top = 5f, bottom = 7f,
                isolated = true) { measured++ }
            val geometry = NativeFloatContextGeometry.build(300, listOf(block(1, 10f, bottom = 12f),
                isolated, block(3, 10f, top = 20f)), adjoining = true)
            assertEquals(1, measured)
            assertEquals(22f, geometry.marginPlacements.getValue(1).borderTop, 0f)
            assertEquals(0f, geometry.flowChildren.single().bounds.height(), 0f)
            assertEquals(42f, geometry.children.single { it.id == 3 }.bounds.top, 0f)
            assertTrue(geometry.ownExclusions.isEmpty())
        }
    }

    @Test fun adjoiningComponentWrappersAndZeroWidthBfcPreserveExactPhysicalCoordinates() {
        var measured = 0
        val component = block(1, 10.25f, top = .5f).copy(margins = FloatMargins(.5f, .625f, .75f, .375f),
            measure = { request -> measured++; assertEquals(10f, request.requestedWidth!!, 0f); NativeBlockMeasure(10f, 10f, 10.25f) })
        val geometry = NativeFloatContextGeometry.build(300, listOf(component, block(2, 10f, top = .25f)), adjoining = true)
        assertEquals(1, measured)
        assertEquals(.375f, geometry.children.first().bounds.left, 0f)
        assertEquals(.5f, geometry.children.first().bounds.top, 0f)
        assertEquals(11.5f, geometry.children.last().bounds.top, 0f)
        val zeroBfc = adjoiningContainer(10, emptyList(), isolated = true).copy(contentWidth = 0)
        val zero = NativeFloatContextGeometry.build(0, listOf(zeroBfc), adjoining = true)
        assertEquals(0, zero.width)
        assertEquals(0, zero.height)
        assertEquals(0f, zero.flowChildren.single().bounds.width(), 0f)
        assertEquals(0f, zero.flowChildren.single().bounds.height(), 0f)
    }

    @Test fun unresolvedLeadingClearanceRefusesBeforeMeasuringTheClearedChild() {
        var measured = 0
        val children = listOf(float(11, TableFloatSide.Left, 40f, 50f),
            block(12, 10f, top = 30f, clear = FigureClear.Both) { measured++ })
        try {
            NativeFloatContextGeometry.build(300, listOf(adjoiningContainer(10, children, top = 10f)), adjoining = true)
            fail("Parent-top clearance has no prepared adjoining origin yet")
        } catch (failure: UnsupportedFloatLayout) {
            assertTrue(failure.message!!.contains("Leading clearance"))
        }
        assertEquals(0, measured)
    }
    private fun preparedGroup(id: Int, children: List<NativeFloatContextPart>, top: Float = 0f,
        clear: FigureClear? = null, width: Int = 200) = NativeFloatContextPart.Container(id, width,
        { _, _ -> error("Ordinary group must not create an opaque measured subtree") },
        margins = FloatMargins(top, 0f, 0f, 0f), clear = clear, empty = children.isEmpty(),
        preparedParts = children)

    @Test fun leadingClearanceResolvesParentAndFloatBeforeTheOnlyChildMeasure() {
        for (clear in listOf(false, true)) {
            var floatCalls = 0
            var blockCalls = 0
            val floating = NativeFloatContextPart.Child(11, NativeBlockWidth.FixedPx(20f), {
                floatCalls++; NativeBlockMeasure(20f, 20f, 50f)
            }, floatSide = TableFloatSide.Left)
            val body = block(12, 10f, top = 20f, clear = if (clear) FigureClear.Left else FigureClear.None) { blockCalls++ }
            val geometry = NativeFloatContextGeometry.build(200,
                listOf(preparedGroup(10, listOf(floating, body), top = 10f)), adjoining = true)
            assertEquals(1, floatCalls)
            assertEquals(1, blockCalls)
            val parent = geometry.ordinaryBounds.getValue(10)
            assertEquals(if (clear) 10f else 20f, parent.top, 0f)
            assertEquals(if (clear) 60f else 10f, parent.height(), 0f)
            val float = geometry.ownExclusions.single().outer
            assertEquals(if (clear) 10f else 20f, float.top, 0f)
            assertEquals(if (clear) 60f else 70f, float.bottom, 0f)
            assertEquals(if (clear) 60f else 20f, geometry.children.single { it.id == 12 }.bounds.top, 0f)
            if (clear) assertEquals(30f, geometry.clearanceById.getValue(12), 0f)
            else assertFalse(geometry.clearanceById.containsKey(12))
            assertEquals(70, geometry.height)
            assertEquals("\ufffc\n\ufffc", geometry.text)
            assertEquals(2, geometry.rectsForRange(0, geometry.text.length).size)
        }
    }

    @Test fun nestedLeadingClearanceUsesFinalExternalExclusionsAndOriginalFloatOwners() {
        var floatCalls = 0
        var textCalls = 0
        var received = emptyList<NativeFloatExclusion>()
        val floating = NativeFloatContextPart.Child(11, NativeBlockWidth.FixedPx(20f), {
            floatCalls++; NativeBlockMeasure(20f, 20f, 50f)
        }, floatSide = TableFloatSide.Left)
        val paragraph = text("Final body").copy(build = { width, carried ->
            textCalls++; received = carried
            assertEquals(200, width)
            NativeFloatGeometry.build(SpannableString("Final body"), paint, width, emptyList(), carriedExclusions = carried)
        })
        val clear = preparedGroup(12, listOf(paragraph), top = 20f, clear = FigureClear.Both)
        val nested = preparedGroup(20, listOf(floating, clear))
        val parent = preparedGroup(10, listOf(nested), top = 10f)
        val external = NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(170f, 0f, 200f, 90f))
        val geometry = NativeFloatContextGeometry.build(200, listOf(parent), adjoining = true,
            carriedExclusions = listOf(external))
        assertEquals(1, floatCalls)
        assertEquals(1, textCalls)
        assertTrue("The body is first shaped at its final cleared origin", received.isEmpty())
        assertEquals(10f, geometry.ordinaryBounds.getValue(10).top, 0f)
        assertEquals(10f, geometry.ordinaryBounds.getValue(20).top, 0f)
        assertEquals(90f, geometry.ordinaryBounds.getValue(12).top, 0f)
        assertEquals(60f, geometry.clearanceById.getValue(12), 0f)
        assertEquals(10f, geometry.ownExclusions.single().outer.top, 0f)
        assertEquals(60f, geometry.ownExclusions.single().outer.bottom, 0f)
        assertEquals(90f, geometry.textPaintPart(1)!!.y, 0f)
        assertEquals(listOf(0, 2), geometry.partOffsets)
    }

    @Test fun preparedThroughGroupsKeepEarlierFloatOriginsWhenLaterMarginsGrow() {
        var count = 0
        val empty = preparedGroup(2, listOf(NativeFloatContextPart.Child(21, NativeBlockWidth.FixedPx(20f), {
            count++; NativeBlockMeasure(20f, 20f, 50f)
        }, floatSide = TableFloatSide.Left)), top = 5f).copy(margins = FloatMargins(5f, 0f, 7f, 0f))
        val geometry = NativeFloatContextGeometry.build(200, listOf(block(1, 10f, bottom = 12f),
            empty, block(3, 10f, top = 20f)), adjoining = true)
        assertEquals(1, count)
        assertEquals(22f, geometry.ordinaryBounds.getValue(2).top, 0f)
        assertEquals(0f, geometry.ordinaryBounds.getValue(2).height(), 0f)
        assertEquals(22f, geometry.ownExclusions.single().outer.top, 0f)
        assertEquals(30f, geometry.children.single { it.id == 3 }.bounds.top, 0f)
    }

    @Test fun signedNormalContainerOriginRetainsRealInkSelectionAndSourceActions() {
        var clicked = 0
        val box = containerBoxWidth(ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 200f))),
            100f, ContainerWidths(0f, 200f), 1f, 18f, rtl = true)
        assertEquals(100f, box.marginBox, 0f)
        assertEquals(-100f, box.marginLeft, 0f)
        val horizontal = NativeContainerHorizontal.from(box, 0f, 0f, 0f)
        val group = preparedGroup(10, listOf(text("Signed", { clicked++ })), width = 200).copy(horizontal = horizontal)
        val geometry = NativeFloatContextGeometry.build(100, listOf(group), adjoining = true)
        assertEquals(100, geometry.width)
        assertEquals(-100f, geometry.ordinaryBounds.getValue(10).left, 0f)
        assertEquals(100f, geometry.ordinaryBounds.getValue(10).right, 0f)
        assertEquals(-100f, geometry.textPaintPart(0)!!.x, 0f)
        assertTrue(geometry.extents.ink!!.left < 0f)
        val action = geometry.nodes.single()
        assertTrue(action.bounds.first().left < 0f)
        assertTrue(geometry.containsInteraction(action.bounds.first().centerX(), action.bounds.first().centerY()))
        action.onClick!!()
        assertEquals(1, clicked)
    }

    @Test fun overwideBfcUsesItsPhysicalCollisionWidthAndKeepsTheSolvedSignedOrigin() {
        val box = containerBoxWidth(ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 200f))),
            100f, ContainerWidths(0f, 200f), 1f, 18f, rtl = true)
        val horizontal = NativeContainerHorizontal.from(box, 0f, 0f, 0f)
        for (preceding in listOf(false, true)) {
            var measured = 0
            val bfc = adjoiningContainer(10, listOf(block(11, 10f)), isolated = true) { measured++ }
                .copy(contentWidth = 200, horizontal = horizontal)
            val parts = if (preceding) listOf(float(1, TableFloatSide.Right, 20f, 30f), bfc) else listOf(bfc)
            val geometry = NativeFloatContextGeometry.build(100, parts, adjoining = true)
            assertEquals(1, measured)
            val content = geometry.flowChildren.single().bounds
            assertEquals(-100f, content.left, 0f)
            assertEquals(100f, content.right, 0f)
            assertEquals(if (preceding) 30f else 0f, content.top, 0f)
            assertEquals(if (preceding) 40f else 10f, geometry.textBottom, 0f)
            assertEquals(if (preceding) 1 else 0, geometry.ownExclusions.size)
        }
    }

    @Test fun clearedThroughSetKeepsItsBorderAnchorAndCannotEscapeTheParentBottom() {
        for (following in listOf(false, true)) for (ownFloat in listOf(false, true)) {
            var ownMeasurements = 0
            val emptyChildren = if (ownFloat) listOf(NativeFloatContextPart.Child(31,
                NativeBlockWidth.FixedPx(10f), { ownMeasurements++; NativeBlockMeasure(10f, 10f, 5f) },
                floatSide = TableFloatSide.Left)) else emptyList()
            val empty = preparedGroup(30, emptyChildren, top = 10f, clear = FigureClear.Both)
                .copy(margins = FloatMargins(10f, 0f, 20f, 0f))
            val children = listOf(block(11, 1f), float(20, TableFloatSide.Left, 20f, 49f), empty) +
                if (following) listOf(block(40, 10f, top = 30f)) else emptyList()
            val geometry = NativeFloatContextGeometry.build(200, listOf(preparedGroup(10, children)), adjoining = true)
            assertEquals(if (ownFloat) 1 else 0, ownMeasurements)
            assertEquals(50f, geometry.ordinaryBounds.getValue(30).top, 0f)
            assertEquals(0f, geometry.ordinaryBounds.getValue(30).height(), 0f)
            assertEquals(39f, geometry.clearanceById.getValue(30), 0f)
            assertEquals(if (following) 80f else 60f, geometry.ordinaryBounds.getValue(10).height(), 0f)
            val source = geometry.ownExclusions.first()
            assertEquals(1f, source.outer.top, 0f)
            assertEquals(50f, source.outer.bottom, 0f)
            if (ownFloat) {
                val nested = geometry.ownExclusions.last()
                assertEquals(50f, nested.outer.top, 0f)
                assertEquals(55f, nested.outer.bottom, 0f)
            }
            if (following) assertEquals(70f, geometry.children.single { it.id == 40 }.bounds.top, 0f)
        }
    }

    @Test fun clearedThroughBarrierEndsAtTheFollowingIndependentBottomEdge() {
        val empty = preparedGroup(30, emptyList(), top = 10f, clear = FigureClear.Both)
            .copy(margins = FloatMargins(10f, 0f, 20f, 0f))
        val children = listOf(block(11, 1f), float(20, TableFloatSide.Left, 20f, 49f), empty,
            block(40, 10f, top = 30f, bottom = 40f))
        for (isolated in listOf(false, true)) {
            val parent = if (isolated) adjoiningContainer(10, children, isolated = true)
                .copy(contentWidth = 200) else preparedGroup(10, children)
            val geometry = NativeFloatContextGeometry.build(200, listOf(parent), adjoining = true)
            assertEquals(120f, geometry.textBottom, 0f)
            if (!isolated) {
                assertEquals(80f, geometry.ordinaryBounds.getValue(10).height(), 0f)
                assertEquals(40f, geometry.adjoiningMargins!!.after, 0f)
            } else {
                assertEquals(120f, geometry.flowChildren.single().bounds.height(), 0f)
                assertEquals(0f, geometry.adjoiningMargins!!.after, 0f)
            }
        }
    }

    @Test fun preparedFormattingStatesKeepGlobalLeavesAndIsolateOnlyTheirOwnFloatSet() {
        for (mode in 0..2) {
            var measured = 0
            val internal = NativeFloatContextPart.Child(11, NativeBlockWidth.FixedPx(20f), {
                measured++; NativeBlockMeasure(20f, 20f, 80f)
            }, floatSide = TableFloatSide.Left)
            val group = preparedGroup(10, listOf(internal, block(12, 10f)), width = 100)
                .copy(floatSide = if (mode == 1) TableFloatSide.Left else null, isolatesFloats = mode == 2)
            val geometry = NativeFloatContextGeometry.build(200,
                listOf(float(1, TableFloatSide.Right, 20f, 120f), group, block(20, 10f)), adjoining = true)
            assertEquals(1, measured)
            assertEquals(listOf(1, 11, 12, 20), geometry.children.map { it.id })
            assertTrue("Prepared owners never create an opaque composition slot", geometry.flowChildren.isEmpty())
            assertEquals(4, geometry.partOffsets.size)
            assertEquals("\ufffc\n\ufffc\n\ufffc\n\ufffc", geometry.text)
            val bounds = geometry.ordinaryBounds.getValue(10)
            assertEquals(0f, bounds.left, 0f)
            assertEquals(100f, bounds.width(), 0f)
            assertEquals(if (mode == 0) 10f else 80f, bounds.height(), 0f)
            assertEquals(if (mode == 2) 1 else 2, geometry.ownExclusions.size)
            if (mode != 2) {
                val left = geometry.ownExclusions.single { it.side == TableFloatSide.Left }.outer
                assertEquals(if (mode == 0) 20f else 100f, left.width, 0f)
                assertEquals(80f, left.bottom, 0f)
            }
            assertEquals(if (mode == 2) 80f else if (mode == 0) 10f else 0f,
                geometry.children.single { it.id == 20 }.bounds.top, 0f)
            assertEquals(120, geometry.height)
        }
    }

    @Test fun aPreparedFloatIsMeasuredOnceWhileLeadingClearanceReanchorsItsParent() {
        var measured = 0
        val internal = block(21, 50f) { measured++ }
        val floating = preparedGroup(20, listOf(internal), width = 20).copy(floatSide = TableFloatSide.Left)
        val cleared = block(30, 10f, top = 20f, clear = FigureClear.Left)
        val parent = preparedGroup(10, listOf(floating, cleared), top = 10f)
        val geometry = NativeFloatContextGeometry.build(200, listOf(parent), adjoining = true)
        assertEquals(1, measured)
        assertEquals(10f, geometry.ordinaryBounds.getValue(10).top, 0f)
        assertEquals(10f, geometry.ordinaryBounds.getValue(20).top, 0f)
        assertEquals(60f, geometry.ordinaryBounds.getValue(20).bottom, 0f)
        assertEquals(10f, geometry.children.single { it.id == 21 }.bounds.top, 0f)
        assertEquals(60f, geometry.children.single { it.id == 30 }.bounds.top, 0f)
        assertEquals(30f, geometry.clearanceById.getValue(30), 0f)
        assertEquals(60f, geometry.ordinaryBounds.getValue(10).height(), 0f)
        assertEquals(listOf(0, 2), geometry.partOffsets)
    }

    @Test fun preparedRowsContainItemFloatsAndAlignActualSingleMeasureBoxes() {
        for (alignment in ContainerAlignItems.entries) for (automatic in listOf(false, true)) {
            var firstCalls = 0
            var secondCalls = 0
            fun item(id: Int, content: List<NativeFloatContextPart>, width: Int,
                margins: FloatMargins, automaticTop: Boolean = false) =
                preparedGroup(id, content, width = width).copy(margins = margins, isolatesFloats = true,
                    horizontal = NativeContainerHorizontal(width + margins.left + margins.right, width.toFloat(),
                        width.toFloat(), margins.left, margins.left, 0f, width + margins.left + margins.right),
                    flexCrossMargins = NativeFlexCrossMargins(autoTop = automaticTop))
            val first = item(10, listOf(NativeFloatContextPart.Child(11, NativeBlockWidth.FixedPx(20f), {
                firstCalls++; NativeBlockMeasure(20f, 20f, 60f)
            }, floatSide = TableFloatSide.Left)), 40, FloatMargins(3f, 4f, 2f, 2f))
            val second = item(20, listOf(block(21, 20f) { secondCalls++ }), 30,
                FloatMargins(if (automatic) 0f else 5f, 0f, 7f, 11f), automatic)
            val items = listOf(first, second)
            val geometry = NativeFloatContextGeometry.buildPreparedRow(100, 100f, items,
                NativeFlexRowPolicy(alignment), NativeOrdinaryPreparation(items))
            assertEquals(1, firstCalls); assertEquals(1, secondCalls)
            assertEquals(65, geometry.height)
            assertTrue(geometry.ownExclusions.isEmpty())
            assertEquals(2f, geometry.ordinaryBounds.getValue(10).left, 0f)
            assertEquals(57f, geometry.ordinaryBounds.getValue(20).left, 0f)
            val expectedTop = if (automatic) 38f else when (alignment) {
                ContainerAlignItems.Start, ContainerAlignItems.Stretch -> 5f
                ContainerAlignItems.Center -> 21.5f
                ContainerAlignItems.End -> 38f
            }
            assertEquals(expectedTop, geometry.ordinaryBounds.getValue(20).top, 0f)
            assertEquals(if (!automatic && alignment == ContainerAlignItems.Stretch) 53f else 20f,
                geometry.ordinaryBounds.getValue(20).height(), 0f)
            assertEquals(expectedTop, geometry.children.single { it.id == 21 }.bounds.top, 0f)
            assertEquals(3f, geometry.children.single { it.id == 11 }.bounds.top, 0f)
            assertEquals("\ufffc\n\ufffc", geometry.text)
            assertEquals(listOf(0, 2), geometry.partOffsets)
        }
    }

    @Test fun preparedRowCrossAlignmentUsesFractionalNativeHeightAndContainedFloats() {
        for (alignment in ContainerAlignItems.entries) {
            val calls = IntArray(3)
            fun paragraph(index: Int, height: Float): NativeFloatContextPart {
                val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { textSize = 28f }
                val source = SpannableString("W").apply {
                    setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint),
                        NativeLineHeightPolicy.Pixels(height), strut = true),
                        0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                return NativeFloatContextPart.Text(source, { width, carried ->
                    calls[index]++
                    NativeFloatGeometry.build(source, paint, width, emptyList(), carriedExclusions = carried).also {
                        assertEquals(height, it.textBottom, 0f)
                    }
                })
            }
            fun item(id: Int, child: NativeFloatContextPart) = preparedGroup(id, listOf(child), width = 40)
                .copy(isolatesFloats = true,
                    horizontal = NativeContainerHorizontal(40f, 40f, 40f, 0f, 0f, 0f, 40f))
            val items = listOf(item(10, paragraph(0, .5f)), item(20, paragraph(1, 1.5f)),
                item(30, NativeFloatContextPart.Child(31, NativeBlockWidth.FixedPx(10f), {
                    calls[2]++; NativeBlockMeasure(10f, 10f, 1.25f)
                }, floatSide = TableFloatSide.Left)))
            val geometry = NativeFloatContextGeometry.buildPreparedRow(120, 120f, items,
                NativeFlexRowPolicy(alignment), NativeOrdinaryPreparation(items))
            assertEquals(listOf(1, 1, 1), calls.toList())
            assertEquals(2, geometry.height)
            assertEquals(1.5f, geometry.usedHeight, 0f)
            assertEquals(1.5f, geometry.textBottom, 0f)
            val firstTop = when (alignment) {
                ContainerAlignItems.Start, ContainerAlignItems.Stretch -> 0f
                ContainerAlignItems.Center -> .5f
                ContainerAlignItems.End -> 1f
            }
            val floatTop = when (alignment) {
                ContainerAlignItems.Start, ContainerAlignItems.Stretch -> 0f
                ContainerAlignItems.Center -> .125f
                ContainerAlignItems.End -> .25f
            }
            assertEquals(firstTop, geometry.ordinaryBounds.getValue(10).top, 0f)
            assertEquals(if (alignment == ContainerAlignItems.Stretch) 1.5f else .5f,
                geometry.ordinaryBounds.getValue(10).height(), 0f)
            assertEquals(floatTop, geometry.ordinaryBounds.getValue(30).top, 0f)
            assertEquals(if (alignment == ContainerAlignItems.Stretch) 1.5f else 1.25f,
                geometry.ordinaryBounds.getValue(30).height(), 0f)
            assertEquals(floatTop, geometry.children.single().bounds.top, 0f)
            assertEquals(floatTop + 1.25f, geometry.children.single().bounds.bottom, 0f)
            assertTrue(geometry.extents.ink!!.top < firstTop)
        }
    }

    @Test fun preparedFractionalFloatKeepsTheSameExactPreflightAndFinalClearance() {
        var calls = 0
        val floating = preparedGroup(10, listOf(block(11, .5f) { calls++ }), width = 20)
            .copy(floatSide = TableFloatSide.Left)
        val following = block(20, .25f, clear = FigureClear.Left)
        val parent = preparedGroup(1, listOf(floating, following), width = 100)
        val geometry = NativeFloatContextGeometry.build(100, listOf(parent), adjoining = true)
        assertEquals(1, calls)
        assertEquals(.5f, geometry.ordinaryBounds.getValue(10).height(), 0f)
        assertEquals(.5f, geometry.children.single { it.id == 20 }.bounds.top, 0f)
        assertEquals(.75f, geometry.usedHeight, 0f)
        assertEquals(1, geometry.height)
    }

    @Test fun zeroWidthRtlPreparedRowRetainsSignedNativeInkSelectionAndBothActions() {
        val activated = mutableListOf<String>()
        fun item(id: Int, label: String, width: Int, color: Int): NativeFloatContextPart.Container {
            val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { textSize = 28f; this.color = color }
            fun source() = SpannableString(label).apply {
                setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), NativeLineHeightPolicy.Pixels(0f), strut = true),
                    0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val paragraph = NativeFloatContextPart.Text(label, { actual, carried ->
                assertTrue(carried.isEmpty())
                NativeFloatGeometry.build(source(), paint, actual, emptyList(), nodeFactory = { geometry -> listOf(
                    FloatInteractionNode(0, FloatInteractionKind.LINK, 0, label.length, geometry.rectsForRange(0, label.length),
                        label, null, { activated += label })) })
            })
            return preparedGroup(id, listOf(paragraph), width = width).copy(isolatesFloats = true,
                horizontal = NativeContainerHorizontal(width.toFloat(), width.toFloat(), width.toFloat(), 0f, 0f, 0f, width.toFloat()))
        }
        val items = listOf(item(10, "W", 40, android.graphics.Color.RED), item(20, "I", 30, android.graphics.Color.BLUE))
        val geometry = NativeFloatContextGeometry.buildPreparedRow(0, 0f, items,
            NativeFlexRowPolicy(ContainerAlignItems.Start, rtl = true), NativeOrdinaryPreparation(items))
        assertEquals(0, geometry.width); assertEquals(0, geometry.height)
        assertEquals(-40f, geometry.ordinaryBounds.getValue(10).left, 0f)
        assertEquals(-70f, geometry.ordinaryBounds.getValue(20).left, 0f)
        assertEquals("W\nI", geometry.text)
        assertTrue(geometry.extents.ink!!.left < 0f)
        assertTrue(geometry.extents.ink!!.top < 0f)
        for (node in geometry.nodes) {
            val rect = node.bounds.first()
            assertTrue(geometry.containsInteraction(rect.centerX(), rect.centerY()))
            assertEquals(node.start, geometry.offsetForPosition(rect.left + .1f, rect.centerY()))
            node.onClick!!()
        }
        assertEquals(listOf("W", "I"), activated)
        val bitmap = android.graphics.Bitmap.createBitmap(160, 120, android.graphics.Bitmap.Config.ARGB_8888)
        try {
            val canvas = android.graphics.Canvas(bitmap)
            canvas.translate(100f, 60f)
            geometry.paint(canvas)
            var red = 0; var blue = 0
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (pixel == android.graphics.Color.RED) red++
                if (pixel == android.graphics.Color.BLUE) blue++
            }
            assertTrue(red > 10); assertTrue(blue > 10)
        } finally { bitmap.recycle() }
    }
}
