package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class ImageMapGeometryTest {
    private fun action(label: String) = ImageMapAction(ImageMapActionKind.Internal, "Page", "", label)
    private fun region(shape: ImageMapShape, label: String, vararg coordinates: Double) =
        ImageMapRegion(shape, coordinates.toList(), action(label))
    private fun prepared(map: ImageMap, width: Double = 100.0, height: Double = 100.0) =
        checkNotNull(PreparedImageMap.prepare(map, 100, 100, width, height))
    private val full = ImageMapBounds(0.0, 0.0, 100.0, 100.0)

    // Authored shared contract vectors 5337bf7b; no browser/device equivalence claim.
    @Test fun coordinatesRoundBeforePaintedScalingAndOuterClip() {
        val first = region(ImageMapShape.Polygon, "first", -1.0, -1.0, 3.0, -1.0, 3.0, 3.0, -1.0, 3.0)
        val geometry = prepared(ImageMap(ImageMapDescription.None, listOf(first)), 50.0, 50.0)
        val painted = ImageMapBounds(30.0, 40.0, 100.0, 100.0)
        assertEquals(ImageMapHit.Action(first.action, 0), geometry.hit(painted, 34.0, 44.0))
        assertEquals(ImageMapHit.None, geometry.hit(painted, 35.0, 45.0))
        assertEquals(ImageMapHit.Outside, geometry.hit(painted, 29.0, 40.0))
        assertEquals(ImageMapHit.Outside, geometry.hit(painted, 130.0, 40.0))
        assertEquals(listOf(-1.0, -1.0, 3.0, -1.0, 3.0, 3.0, -1.0, 3.0), first.coordinates)
    }

    @Test fun orderedClosedEdgesAndSelfIntersectingPolygonKeepFirstAction() {
        val regions = listOf(
            region(ImageMapShape.Rect, "rectangle", 20.0, 20.0, 10.0, 10.0),
            region(ImageMapShape.Circle, "circle", 20.0, 20.0, 10.0),
            region(ImageMapShape.Polygon, "polygon", 40.0, 40.0, 60.0, 60.0, 40.0, 60.0, 60.0, 40.0),
        )
        val fallback = action("default")
        val geometry = prepared(ImageMap(ImageMapDescription.None, regions, fallback))
        assertEquals(ImageMapHit.Action(regions[0].action, 0), geometry.hit(full, 20.0, 20.0))
        assertEquals(ImageMapHit.Action(regions[1].action, 1), geometry.hit(full, 30.0, 20.0))
        assertEquals(ImageMapHit.Action(regions[2].action, 2), geometry.hit(full, 50.0, 45.0))
        assertEquals(ImageMapHit.Action(regions[2].action, 2), geometry.hit(full, 50.0, 50.0))
        assertEquals(ImageMapHit.Action(fallback, null), geometry.hit(full, 45.0, 50.0))
    }

    @Test fun emptyAndDegenerateMapsDoNotInventBackgroundActions() {
        val geometry = prepared(ImageMap(ImageMapDescription.None, listOf(
            region(ImageMapShape.Circle, "negative", 5.0, 5.0, -1.0),
            region(ImageMapShape.Circle, "zero", 5.0, 5.0, 0.0),
            region(ImageMapShape.Rect, "line", 5.0, 5.0, 5.0, 10.0),
        )))
        assertEquals(ImageMapHit.None, geometry.hit(full, 5.0, 5.0))
        assertEquals(ImageMapHit.None, prepared(ImageMap(ImageMapDescription.None, emptyList())).hit(full, 5.0, 5.0))
        val fallback = action("default")
        val defaultOnly = prepared(ImageMap(ImageMapDescription.None, emptyList(), fallback))
        assertEquals(ImageMapHit.Action(fallback, null), defaultOnly.hit(full, 5.0, 5.0))
        assertEquals(ImageMapHit.Outside, defaultOnly.hit(full, 100.0, 5.0))
    }

    @Test fun missingBasisAndArithmeticOverflowNeverSelectDefault() {
        val fallback = action("default")
        val empty = ImageMap(ImageMapDescription.None, emptyList(), fallback)
        assertNull(PreparedImageMap.prepare(empty, 0, 100, 100.0, 100.0))
        assertNull(PreparedImageMap.prepare(empty, 100, 0, 100.0, 100.0))
        assertNull(PreparedImageMap.prepare(empty, 100, 100, Double.MAX_VALUE, Double.MAX_VALUE))
        val scaledOverflow = ImageMap(ImageMapDescription.None, listOf(
            region(ImageMapShape.Circle, "overflow", Double.MAX_VALUE, 1.0, 1.0),
        ), fallback)
        assertNull(PreparedImageMap.prepare(scaledOverflow, 1, 1, 100.0, 100.0))
        val hitOverflow = prepared(ImageMap(ImageMapDescription.None, listOf(
            region(ImageMapShape.Circle, "overflow", -Double.MAX_VALUE, 1.0, Double.MAX_VALUE),
        ), fallback))
        assertEquals(ImageMapHit.GeometryUnavailable, hitOverflow.hit(full, 1.0, 1.0))
        assertEquals(ImageMapHit.GeometryUnavailable, prepared(empty).hit(full.copy(width = 0.0), 1.0, 1.0))
        assertEquals(ImageMapHit.GeometryUnavailable, prepared(empty).hit(full, Double.NaN, 1.0))
    }

    @Test fun explicitEmptyFragmentAndSignedFractionalSourceCoordinatesSurvivePreparation() {
        val local = ImageMapAction(ImageMapActionKind.Internal, "", "", "local")
        assertEquals(EntryLink("", ""), local.entryLink())
        val values = listOf(-0.0, -0.25, 1.5, 2.5)
        val map = ImageMap(ImageMapDescription.None, listOf(ImageMapRegion(ImageMapShape.Rect, values, local)))
        prepared(map)
        assertEquals(values.map { it.toBits() }, map.regions.single().coordinates.map { it.toBits() })
        assertEquals("", map.regions.single().action.targetFragment)
    }
    @Test fun inlineMapUsesOriginalOccurrenceReadyBasisAndExactTinyRegionWithoutFileFallback() {
        val self = ImageMapAction(ImageMapActionKind.Internal, "mmele", null, "mmele")
        val fallback = ImageMapAction(ImageMapActionKind.External, "https://example.test/default", null, "default")
        val region = ImageMapRegion(ImageMapShape.Rect, listOf(0.0, 0.0, 1.0, 1.0), self)
        val map = ImageMap(ImageMapDescription.BottomRight, listOf(region, region.copy()), fallback)
        val original = Span("link", "", target = "File:Human body features-nb.svg",
            image = InlineImage("Human body features-nb.svg", 310, null, "body", "body", true, map))
        val textFallback = Span("link", "mmele", target = "mmele")
        val spans = listOf(original, Span("text", "\n", "", ""), textFallback)
        val image = NativeInlineImageMap(original, "span-0", 0, 563, 685, 310.0, 377.0)
        assertSame(original, image.span)
        assertSame(map, image.map)
        assertSame(self, image.actions[0])
        assertSame(self, image.actions[1])
        assertSame(fallback, image.actions[2])
        assertEquals(0, image.start); assertEquals(1, image.end)
        assertTrue(image.hasDescription)
        assertEquals("span-0", image.path)
        assertEquals("https://tn.wiktionary.org/wiki/File%3AHuman%20body%20features-nb.svg",
            inlineImageLinkUrl(original, "tnwiktionary-20261001"))
        // Retained original asset dimensions; layout dimensions use the existing client rounding.
        val firstLayout = checkNotNull(inlineImageLayoutPixels(checkNotNull(original.image), 563, 685, "image/svg+xml"))
        assertEquals(InlineImageLayoutPixels(310.0, 377.0), firstLayout)
        val chest = original.copy(target = "File:Chest.jpg", image = original.image!!.copy(file = "Chest.jpg"))
        val secondLayout = checkNotNull(inlineImageLayoutPixels(checkNotNull(chest.image), 927, 755, "image/jpeg"))
        assertEquals(InlineImageLayoutPixels(310.0, 252.0), secondLayout)
        val smaller = NativeInlineImageMap(chest, "span-1", 1, 927, 755, secondLayout.width, secondLayout.height)
        for (density in listOf(0.7f, 1f, 1.3f, 2f, 2.5f)) {
            val pixels = checkNotNull(inlineImagePixels(checkNotNull(original.image), 563, 685, density, "image/svg+xml"))
            val d = density.toDouble()
            val outer = ImageMapBounds(31.0, 47.0, pixels.width.toDouble() + 2.0 * d, pixels.height.toDouble() + 2.0 * d)
            val content = checkNotNull(nativeInlineImageMapContentBounds(outer, d))
            val dx = content.width / firstLayout.width; val dy = content.height / firstLayout.height
            val ratio = (firstLayout.width + firstLayout.height) / (563.0 + 685.0)
            val x = content.left + 0.5 * ratio * dx; val y = content.top + 0.5 * ratio * dy
            assertTrue(image.accepts(0, content, x, y))
            assertFalse(image.accepts(1, content, x, y)) // original first region, not equal-target last
            assertFalse(image.accepts(2, content, x, y))
            // The source edge scales below1, then rounds to1 before physical scaling.
            assertTrue(image.accepts(0, content, content.left + 1.01 * ratio * dx, y))
            assertFalse(image.accepts(0, content, content.left + 1.01 * dx, y))
            assertTrue(image.accepts(2, content, content.left + 1.01 * dx, y))
            assertFalse(image.accepts(2, content, outer.left, outer.top)) // no border/File fallback
            assertFalse(image.accepts(2, content, content.left + content.width, y))
            val smallerPixels = checkNotNull(inlineImagePixels(checkNotNull(chest.image), 927, 755, density, "image/jpeg"))
            val smallerContent = ImageMapBounds(19.0, 23.0, smallerPixels.width.toDouble(), smallerPixels.height.toDouble())
            val smallerRatio = (secondLayout.width + secondLayout.height) / (927.0 + 755.0)
            val sx = smallerContent.left + 0.5 * smallerRatio * smallerContent.width / secondLayout.width
            val sy = smallerContent.top + 0.5 * smallerRatio * smallerContent.height / secondLayout.height
            // The second original source rectangle collapses to zero; no minimum-target invention.
            assertFalse(smaller.accepts(0, smallerContent, sx, sy))
            assertFalse(smaller.accepts(1, smallerContent, sx, sy))
            assertTrue(smaller.accepts(2, smallerContent, sx, sy))
        }
        val calls = mutableListOf<Any>()
        image.activate(0, { calls += it }, { calls += it })
        image.activate(1, { calls += it }, { calls += it })
        image.activate(2, { calls += it }, { calls += it })
        calls += textFallback.entryLink()
        assertEquals(listOf(EntryLink("mmele"), EntryLink("mmele"), fallback.target, EntryLink("mmele")), calls)
        assertSame(original, spans[0]); assertSame(textFallback, spans[2])
        assertEquals(EntryLink("mmele"), textFallback.entryLink())
        assertEquals(listOf(0.0, 0.0, 1.0, 1.0), region.coordinates)
    }

    @Test fun inlineMapUnavailableGeometryAndDescriptionNoneRetainIndependentActionsAndSource() {
        val self = action("same label")
        val map = ImageMap(ImageMapDescription.None, listOf(region(ImageMapShape.Rect, "same label", 0.0, 0.0, 1.0, 1.0)), self)
        val original = Span("text", "", "", "", image = InlineImage("Map.svg", 310, null, "", null, false, map))
        val missing = NativeInlineImageMap(original, "group-0/span-0", 4, null, null, 310.0, 310.0)
        assertFalse(missing.available)
        assertFalse(missing.hasDescription)
        assertNull(inlineImageLinkUrl(original, "tnwiktionary-20261001"))
        assertFalse(missing.accepts(0, full, 0.0, 0.0))
        assertFalse(missing.accepts(1, full, 50.0, 50.0))
        assertSame(self, missing.actions[1])
        assertEquals(4, missing.start); assertEquals(5, missing.end)
        val ready = NativeInlineImageMap(original, missing.path, missing.start, 310, 310, 310.0, 310.0)
        assertTrue(ready.available)
        assertTrue(ready.accepts(0, full, 0.1, 0.1))
        assertTrue(ready.accepts(1, full, 50.0, 50.0))
        val second = NativeInlineImageMap(original, "group-1/span-0", 5, 310, 310, 310.0, 310.0)
        assertSame(original, second.span); assertNotEquals(ready.path, second.path)
        assertEquals(5, second.start); assertEquals(6, second.end)
        assertNull(nativeInlineImageMapContentBounds(full, 50.0))
        assertNull(nativeInlineImageMapContentBounds(full, Double.NaN))
        assertNull(nativeInlineImageMapContentBounds(full.copy(left = Double.MAX_VALUE, width = Double.MAX_VALUE), 0.0))
        val noDefaultSpan = original.copy(image = original.image!!.copy(map = map.copy(defaultAction = null)))
        val noDefault = NativeInlineImageMap(noDefaultSpan, "span-0", 0, 927, 755, 310.0, 252.0)
        assertFalse(noDefault.accepts(0, full, 0.01, 0.01))
        assertEquals(1, noDefault.actions.size)
        assertEquals(map, original.image?.map)
    }

}
