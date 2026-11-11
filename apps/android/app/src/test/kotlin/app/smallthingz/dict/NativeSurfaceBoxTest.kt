package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeSurfaceBoxTest {
    @Test fun signedDescendantBoundsDoNotBecomeParentFlowAllocation() {
        val child = NativeGeometryExtents(0, 0f, NativeFloatBounds(-3.25f, -8.5f, 21.5f, 4.25f),
            NativeFloatBounds(-2f, -7f, 20f, 3f))
        val parent = NativeGeometryExtents(0, 0f, null, null).including(child, -7.5f, -4.25f)
        assertEquals(0, parent.usedWidth); assertEquals(0f, parent.usedHeight, 0f)
        assertEquals(NativeFloatBounds(-10.75f, -12.75f, 14f, 0f), parent.ink)
        assertEquals(NativeFloatBounds(-9.5f, -11.25f, 12.5f, -1.25f), parent.interaction)
        assertEquals(NativeSurfaceBox(-11, -13, 25, 13), NativeSurfaceBox.from(parent))
        assertEquals(NativeSurfaceBox(0, 0, 0, 0), NativeSurfaceBox.from(NativeGeometryExtents(0, 0f, null, null)))
    }

    @Test fun actualSurfaceLimitsRefuseOverflowWithoutCoercingTheUsedBox() {
        val oversized = NativeGeometryExtents(0, 0f, NativeFloatBounds(-Float.MAX_VALUE, 0f, Float.MAX_VALUE, 1f), null)
        try { NativeSurfaceBox.from(oversized); fail("Oversized physical coordinates must refuse") }
        catch (_: UnsupportedFloatLayout) { }
        try {
            NativeGeometryExtents(0, 0f, null, null).including(oversized, Float.MAX_VALUE, 0f)
            fail("Ancestor translation must refuse before a floating point infinity is constructed")
        } catch (_: UnsupportedFloatLayout) { }
        assertEquals(0, oversized.usedWidth); assertEquals(0f, oversized.usedHeight, 0f)
    }
}
