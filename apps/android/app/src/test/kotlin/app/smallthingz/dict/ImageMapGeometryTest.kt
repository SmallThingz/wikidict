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
}
