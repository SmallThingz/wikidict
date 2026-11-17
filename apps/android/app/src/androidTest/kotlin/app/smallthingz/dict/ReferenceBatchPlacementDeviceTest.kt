package app.smallthingz.dict

import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ReferenceBatchPlacementDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun nativeViews(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun walk(view: View) {
                if (view is NativeFloatTextView) result += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) walk(view.getChildAt(index))
            }
            walk(activity.window.decorView)
        }
        return result
    }

    @Test fun explicitBatchesRenderBThenAWithOriginalNativeActionsSelectionAndLegacyRecovery() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdge.None
        fun note(number: Long, group: String) = Reference(number, 1, group, listOf(Span("text", "",
            inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero),
                InlineBoxBorderEdges(none, none, none, none), spans = listOf(Span("link", "Note $group", "Target $group"))))))
        fun paragraph(label: String) = Block("paragraph", 0, listOf(Span("text", label)))
        val references = listOf(note(10, "A"), note(20, "B"))
        val batches = listOf(ReferenceBatchPlacement(0, 1, listOf(1, 0)))
        val original = Entry("Batch placement", emptyList(), "language", "English", "en",
            listOf(Section(2, "Body", listOf(paragraph("Before batches"), paragraph("After batches")))),
            references, referenceBatches = batches)
        val explicit = mutableStateOf(true)
        val actions = mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    MaterialTheme {
                        Box(Modifier.width(340.dp)) {
                            EntryView(if (explicit.value) original else original.copy(referenceBatches = null), false, {},
                                onLink = { actions += it }, settings = AppSettings(allowImages = false, allowAudio = false,
                                    collapseOtherSections = false, collapseDetails = false))
                        }
                    }
                }
            } }
            compose.waitForIdle()
            compose.onNodeWithText("References", useUnmergedTree = true).assertDoesNotExist()
            val before = compose.onNodeWithText("Before batches", useUnmergedTree = true).fetchSemanticsNode().positionOnScreen.y
            val after = compose.onNodeWithText("After batches", useUnmergedTree = true).fetchSemanticsNode().positionOnScreen.y
            val tops = mutableMapOf<String, Float>()
            for (group in listOf("B", "A")) {
                val label = "Note $group"
                val view = nativeViews().single { v -> v.currentMeasuredGeometry?.nodes?.any { it.label?.toString() == label } == true }
                compose.runOnIdle {
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    val node = geometry.nodes.single { it.label?.toString() == label }
                    val provider = view.accessibilityNodeProvider
                    val ax = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                    assertEquals(label, ax.text?.toString())
                    assertTrue(ax.isClickable)
                    view.setSelection(node.start, node.end)
                    assertEquals(label, view.selectedTextForCopy())
                    val location = IntArray(2); view.getLocationOnScreen(location)
                    tops[group] = location[1] + view.paddingTop + node.bounds.first { !it.isEmpty }.top
                    assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                }
            }
            compose.runOnIdle {
                assertTrue(before < tops.getValue("B"))
                assertTrue(tops.getValue("B") < tops.getValue("A"))
                assertTrue(tops.getValue("A") < after)
                assertEquals(listOf(EntryLink("Target B"), EntryLink("Target A")), actions)
                assertSame(references, original.references)
                explicit.value = false
            }
            compose.waitForIdle()
            compose.onNodeWithText("References", useUnmergedTree = true).assertExists()
            compose.runOnIdle { explicit.value = true }
            compose.waitForIdle()
            compose.onNodeWithText("References", useUnmergedTree = true).assertDoesNotExist()
            assertEquals(2, nativeViews().sumOf { view -> view.currentMeasuredGeometry?.nodes?.count {
                it.label?.toString() in setOf("Note A", "Note B") } ?: 0 })
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }
}
