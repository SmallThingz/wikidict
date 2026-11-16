package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Synthetic selected-row inputs, not an Android shaping, fitting or paint receipt. */
class NativeFloatRowPiecesTest {
    private fun image(width: Float, height: Float = 2f) =
        NativeFloatRowImage(width, height, -height, positioned = true)

    @Test fun repeatedFractionalAtomsAndInterveningTextKeepTheirFloatAdvance() {
        val source = "\ufffc".repeat(5)
        val atoms = source.indices.map { NativeFloatRowPiece.Image(it, false, image(.2f)) }
        val row = nativeFloatRowPieces(source, 0, source.length, atoms, 0f, 8f)
        assertEquals(1f, row.advance, .000001f)
        assertEquals(5, row.placements.size)
        row.placements.forEachIndexed { index, placed ->
            assertSame(atoms[index], placed.piece)
            assertEquals(index * .2f, placed.left, .000001f)
            assertEquals((index + 1) * .2f, placed.right, .000001f)
            assertEquals(.2f, checkNotNull(placed.imageBounds).width, .000001f)
            assertEquals(index, placed.positionedSourceOffset)
        }
        assertEquals("\ufffc".repeat(5), source)
        val mixedSource = "\ufffcab\ufffc"
        val text = NativeFloatRowPiece.Text(1, 3, false, .35f)
        val mixed = nativeFloatRowPieces(mixedSource, 0, mixedSource.length, listOf(
            NativeFloatRowPiece.Image(0, false, image(.2f)), text,
            NativeFloatRowPiece.Image(3, false, image(.2f))), 0f, 8f)
        assertEquals(.75f, mixed.advance, .000001f)
        assertSame(text, mixed.placements[1].piece)
        assertEquals(.2f, mixed.placements[1].left, .000001f)
        assertEquals(.55f, mixed.placements[1].right, .000001f)
        assertEquals("ab", mixedSource.substring(text.start, text.end))
    }

    @Test fun anAlreadySelectedFractionalCutDoesNotRequireAnIntegerBudgetWitness() {
        // Conditional arithmetic witness: if native fitting selects seven legal atoms,
        // no integer budget can distinguish its 1.4px prefix from the next 1.6px prefix.
        // This control neither chooses a line break nor claims those cuts are native-legal.
        val source = "\ufffc".repeat(8)
        val pieces = source.indices.map { NativeFloatRowPiece.Image(it, false, image(.2f)) }
        val selected = nativeFloatRowPieces(source, 0, 7, pieces.take(7), 0f, 0f)
        val withNext = nativeFloatRowPieces(source, 0, 8, pieces, 0f, 0f)
        assertEquals(1.4f, selected.advance, .000001f)
        assertEquals(1.6f, withNext.advance, .000001f)
        assertFalse((0..2).any { it.toFloat() >= selected.advance && it.toFloat() < withNext.advance })
        assertEquals(7, selected.end)
        assertEquals(8, source.length)
        assertEquals(7, selected.sourceEdges(7).single().offset)
    }

    @Test fun physicalAlignmentUsesProvidedVisibleAdvanceAndAllowsRealOverflow() {
        val left = 3.25f
        val right = 4.25f
        assertEquals(left, nativeFloatRowOrigin(left, right, .75f, NativeFloatRowPhysicalAlignment.Left), 0f)
        assertEquals(3.5f, nativeFloatRowOrigin(left, right, .75f, NativeFloatRowPhysicalAlignment.Right), 0f)
        assertEquals(3.375f, nativeFloatRowOrigin(left, right, .75f, NativeFloatRowPhysicalAlignment.Center), 0f)
        assertEquals(2.75f, nativeFloatRowOrigin(left, right, 1.5f, NativeFloatRowPhysicalAlignment.Right), 0f)
        assertEquals(3f, nativeFloatRowOrigin(left, right, 1.5f, NativeFloatRowPhysicalAlignment.Center), 0f)
        // The visible width is an independent native input; retained trailing text is not trimmed here.
        val origin = nativeFloatRowOrigin(left, right, .75f, NativeFloatRowPhysicalAlignment.Right)
        val row = nativeFloatRowPieces("a ", 0, 2,
            listOf(NativeFloatRowPiece.Text(0, 2, false, 1.25f)), origin, 0f)
        assertEquals(1.25f, row.advance, 0f)
        assertEquals(4.75f, row.placements.single().right, 0f)
        assertEquals(2, row.end)
    }

    @Test fun mixedVisualOrderPreservesPhysicalPaddingAndBothSourceEdgeAffinities() {
        val source = "a\ufffc\u05d0\u05d1"
        val occurrence = NativeFloatRowImage(1f, 3f, -2f,
            paddingLeft = .25f, paddingRight = .75f, translationX = -1.5f,
            translationY = .5f, positioned = true)
        val rtlText = NativeFloatRowPiece.Text(2, 4, true, 2.5f)
        val atom = NativeFloatRowPiece.Image(1, true, occurrence)
        val ltrText = NativeFloatRowPiece.Text(0, 1, false, 1.25f)
        val row = nativeFloatRowPieces(source, 0, 4, listOf(rtlText, atom, ltrText), 10f, 8f)
        assertEquals(listOf(rtlText, atom, ltrText), row.placements.map { it.piece })
        assertEquals(5.75f, row.advance, 0f)
        val placed = row.placements[1]
        assertEquals(12.5f, placed.left, 0f)
        assertEquals(14.5f, placed.right, 0f)
        assertEquals(NativeFloatBounds(11.25f, 6.5f, 12.25f, 9.5f), placed.imageBounds)
        assertEquals(14.5f, placed.sourceStartX, 0f)
        assertEquals(12.5f, placed.sourceEndX, 0f)
        val edges = row.sourceEdges(2)
        assertEquals(2, edges.size)
        val imageEnd = edges.single { it.piece === atom }
        val textStart = edges.single { it.piece === rtlText }
        assertFalse(imageEnd.atStart)
        assertTrue(textStart.atStart)
        assertEquals(12.5f, imageEnd.flowX, 0f)
        assertEquals(11.25f, checkNotNull(imageEnd.imageX), 0f)
        assertEquals(12.5f, textStart.flowX, 0f)
        assertNull(textStart.imageX)
        assertEquals("a\ufffc\u05d0\u05d1", source)
    }

    @Test fun signedTranslationMovesOnlyImageBoundsAndZeroPresenceRetainsPositionedIdentity() {
        val source = "x\ufffcy"
        val original = NativeFloatRowImage(6.25f, 4.5f, -3.25f,
            paddingLeft = .375f, paddingRight = .625f, positioned = true)
        fun row(value: NativeFloatRowImage) = nativeFloatRowPieces(source, 0, source.length, listOf(
            NativeFloatRowPiece.Text(0, 1, false, 2f), NativeFloatRowPiece.Image(1, false, value),
            NativeFloatRowPiece.Text(2, 3, false, 3f)), .125f, 10.5f)
        val base = row(original)
        val moved = row(original.copy(translationX = -10f, translationY = 1.25f))
        assertEquals(base.advance, moved.advance, 0f)
        assertEquals(base.baseline, moved.baseline, 0f)
        assertEquals(base.placements.map { it.left to it.right }, moved.placements.map { it.left to it.right })
        val baseBox = checkNotNull(base.placements[1].imageBounds)
        assertEquals(NativeFloatBounds(2.5f, 7.25f, 8.75f, 11.75f), baseBox)
        assertEquals(baseBox.translated(-10f, 1.25f), moved.placements[1].imageBounds)
        assertEquals(6.25f, baseBox.width, 0f) // The action box excludes both wrapper pads.
        assertEquals(7.25f, original.advance, 0f)
        val movedEdges = moved.sourceEdges(2)
        assertEquals(9.375f, movedEdges.single { it.atStart }.flowX, 0f)
        assertEquals(-1.25f, checkNotNull(movedEdges.single { !it.atStart }.imageX), 0f)
        val legacy = NativeFloatRowImage(6.25f, 4.5f, -3.25f)
        val allZeroPresent = legacy.copy(positioned = true)
        val legacyRow = row(legacy)
        val zeroRow = row(allZeroPresent)
        assertEquals(legacyRow.placements[1].imageBounds, zeroRow.placements[1].imageBounds)
        assertNull(legacyRow.placements[1].positionedSourceOffset)
        assertEquals(1, zeroRow.placements[1].positionedSourceOffset)
        // Source order is available to the existing scheduler, not implemented by this map.
        val zeroSource = "\ufffc\ufffc"
        val zeroAtoms = listOf(NativeFloatRowPiece.Image(1, true, allZeroPresent),
            NativeFloatRowPiece.Image(0, true, allZeroPresent))
        val reverse = nativeFloatRowPieces(zeroSource, 0, 2, zeroAtoms, 0f, 0f)
        assertEquals(listOf(1, 0), reverse.placements.map { it.positionedSourceOffset })
        assertEquals(listOf(0, 1), reverse.placements.mapNotNull { it.positionedSourceOffset }.sorted())
    }

    @Test fun originalUtf16CoverageIsRetainedWithoutInventingTextOrNativeClusterDecisions() {
        val source = "A\u0301\ufffc\ud83d\ude00fi"
        val before = NativeFloatRowPiece.Text(0, 2, false, 1.25f)
        val after = NativeFloatRowPiece.Text(3, 7, false, 2.75f)
        val row = nativeFloatRowPieces(source, 0, source.length,
            listOf(before, NativeFloatRowPiece.Image(2, false, image(.2f)), after), 0f, 0f)
        assertEquals(7, row.end)
        assertEquals("A\u0301", source.substring(before.start, before.end))
        assertEquals("\ud83d\ude00fi", source.substring(after.start, after.end))
        assertEquals(1, source.count { it == '\ufffc' })
        assertTrue(row.sourceEdges(1).isEmpty()) // Interior native caret/grapheme policy belongs to its shaped run.
        assertEquals(2, row.sourceEdges(2).size)
        assertEquals(2, row.sourceEdges(3).size)
        assertTrue(row.sourceEdges(4).isEmpty())
        val empty = nativeFloatRowPieces(source, 0, 0, emptyList(), 0f, 0f)
        assertEquals(0f, empty.advance, 0f)
        assertTrue(empty.placements.isEmpty())
        assertTrue(empty.sourceEdges(0).isEmpty()) // No font-only synthetic line or caret is created.
    }

    @Test fun invalidCoverageSurrogateSplitsAndNonImageAtomsAreRejected() {
        fun rejected(block: () -> Unit) {
            try { block(); fail("Expected invalid source mapping to be rejected") }
            catch (_: IllegalArgumentException) { }
        }
        rejected { nativeFloatRowPieces("ab", 0, 2,
            listOf(NativeFloatRowPiece.Text(1, 2, false, 1f)), 0f, 0f) }
        rejected { nativeFloatRowPieces("ab", 0, 2, listOf(
            NativeFloatRowPiece.Text(0, 2, false, 1f), NativeFloatRowPiece.Text(1, 2, false, 1f)), 0f, 0f) }
        rejected { nativeFloatRowPieces("a", 0, 1,
            listOf(NativeFloatRowPiece.Image(0, false, image(.2f))), 0f, 0f) }
        rejected { nativeFloatRowPieces("\ud83d\ude00", 0, 2, listOf(
            NativeFloatRowPiece.Text(0, 1, false, 1f), NativeFloatRowPiece.Text(1, 2, false, 1f)), 0f, 0f) }
        rejected { NativeFloatRowPiece.Text(0, 1, false, Float.NaN) }
        rejected { NativeFloatRowImage(1f, 1f, 0f, paddingLeft = .25f) }
        rejected { NativeFloatRowImage(1f, 1f, 0f, paddingRight = -.25f, positioned = true) }
        rejected { nativeFloatRowPieces("\ufffc", 0, 1,
            listOf(NativeFloatRowPiece.Image(0, false, image(1f))), TablePixelLimit.toFloat(), 0f) }
        rejected { nativeFloatRowOrigin(1f, 0f, 0f, NativeFloatRowPhysicalAlignment.Left) }
    }
}
