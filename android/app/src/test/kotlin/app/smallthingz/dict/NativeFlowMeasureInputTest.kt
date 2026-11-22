package app.smallthingz.dict

import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import org.junit.Assert.*
import org.junit.Test

class NativeFlowMeasureInputTest {
    private val environment = NativeFlowEnvironment(2f, 1.25f, LayoutDirection.Rtl, IntSize(320, 640))
    private fun binding() = NativeFlowBinding(environment, NativeTextInsets(left = 4f), 14f)
    private val policy = NativeFlowParentPolicy(Any(), false, null, 2f)
    private val outer = Constraints(minWidth = 0, maxWidth = 300, minHeight = 0, maxHeight = 200)
    private val child = Constraints(minWidth = 0, maxWidth = 0, minHeight = 0, maxHeight = 0)

    @Test fun completeRequestCopiesLiveExclusionsAndKeepsZeroConstraintsAndSignedCoordinates() {
        val input = NativeFlowMeasureInput()
        val prepared = binding()
        input.bind(prepared)
        val exclusion = NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(-8f, -4f, 20f, 12f))
        val mutable = mutableListOf(exclusion)
        val request = input.request(outer, child, environment, policy, mutable)
        mutable.clear()
        assertEquals(listOf(exclusion), request.exclusions)
        val next = input.request(outer, child, environment, policy, input.carried)
        assertEquals(request, next)
        input.request(outer, child, environment, policy, emptyList())
        assertEquals(listOf(exclusion), next.exclusions)
        assertTrue(input.carried.isEmpty())
        val actual = Constraints.fixed(0, 0)
        val ticket = input.begin(prepared, actual)!!
        assertEquals(actual, ticket.key.actualConstraints)
        assertEquals(0, ticket.key.request.childConstraints.maxHeight)
        assertEquals(0, ticket.key.request.childConstraints.maxWidth)
        assertNull(input.ready(request))
    }

    @Test fun changedEnvironmentParentBoundsPolicyAndBindingCannotShareACompletion() {
        var parentInvalidations = 0
        val input = NativeFlowMeasureInput { parentInvalidations++ }
        val prepared = binding()
        input.bind(prepared)
        val base = input.request(outer, child, environment, policy, emptyList())
        val variants = listOf(
            base.copy(parentConstraints = outer.copy(minHeight = 1)),
            base.copy(parentConstraints = outer.copy(maxHeight = 201)),
            base.copy(childConstraints = child.copy(maxHeight = 1)),
            base.copy(environment = environment.copy(density = 3f)),
            base.copy(environment = environment.copy(fontScale = 2f)),
            base.copy(environment = environment.copy(direction = LayoutDirection.Ltr)),
            base.copy(environment = environment.copy(viewport = IntSize(321, 640))),
            base.copy(environment = environment.copy(viewport = IntSize(320, 641))),
            base.copy(policy = policy.copy(containAtEnd = true)),
            base.copy(policy = policy.copy(composition = Any())),
            base.copy(policy = policy.copy(box = ParagraphBox(ParagraphEdges(left = 2f), ParagraphEdges(), 0f, 0f))),
        )
        val failure = Result.failure<NativeAnonymousFlowGeometry>(UnsupportedFloatLayout("controlled actual failure"))
        variants.forEach { variant ->
            input.request(outer, child, environment, policy, emptyList())
            val stale = input.begin(prepared, child)!!
            val next = input.request(variant.parentConstraints, variant.childConstraints,
                variant.environment, variant.policy, variant.exclusions)
            assertNotEquals(base, next)
            assertFalse(input.publish(stale, failure))
            assertNull(input.ready(base))
        }
        input.request(outer, child, environment, policy, emptyList())
        val beforeRebind = input.begin(prepared, child)!!
        val replacement = binding()
        input.bind(replacement)
        assertEquals(2, parentInvalidations)
        assertFalse(input.publish(beforeRebind, failure))
        assertNull(input.begin(prepared, child))
        val current = input.request(outer, child, environment, policy, emptyList())
        assertSame(replacement, current.binding)
        val beforeDetach = input.begin(replacement, child)!!
        input.measurement.detached()
        assertEquals(3, parentInvalidations)
        assertFalse(input.publish(beforeDetach, failure))
        assertNull(input.ready(current))
        input.unbind(prepared) // A disposed old composition cannot detach the replacement.
        assertSame(replacement, input.request(outer, child, environment, policy, emptyList()).binding)
        val failed = input.begin(replacement, child)!!
        assertTrue(input.publish(failed, failure))
        assertNull(input.geometry)
    }

    @Test fun descendantChangesDuringBuildSealThatBuildButLaterChangesInvalidateIt() {
        var invalidations = 0
        val input = NativeFlowMeasureInput { invalidations++ }
        val prepared = binding()
        input.bind(prepared)
        val request = input.request(outer, child, environment, policy, emptyList())
        val childOwner = NativeSemanticMeasurement(input.semantic)
        val started = input.begin(prepared, child)!!
        input.semantic.measure {
            childOwner.changed() // Initial real caption preparation within the parent's child phase.
            childOwner.measure { childOwner.changed() }
        }
        assertEquals(1, invalidations) // Only the original bind; no endless invalidate-on-measure loop.
        val sealed = input.seal(started)!!
        assertNotSame(started, sealed)
        assertSame(input.semantic.revision, sealed.key.descendantRevision)
        assertEquals(request, sealed.key.request)
        val failure = Result.failure<NativeAnonymousFlowGeometry>(UnsupportedFloatLayout("child unavailable"))
        assertFalse(input.publish(started, failure))
        assertTrue(input.publish(sealed, failure))
        input.request(outer, child, environment, policy, emptyList())
        val prior = input.begin(prepared, child)!!
        childOwner.changed() // Same-size descendant update after the outer build has finished.
        assertEquals(2, invalidations)
        assertNull(input.seal(prior))
        assertFalse(input.publish(prior, failure))
        assertNull(input.geometry)
    }
}
