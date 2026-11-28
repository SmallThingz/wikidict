package app.smallthingz.dict

import android.view.View
import android.view.ViewGroup
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReaderSpacingAndDisclosureDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()

    @Test fun paddingOnlyCaptionKeepsTheReaderGapForTextAndFlow() {
        val labels = listOf("Text plain", "Text padded", "Text explicit", "Flow plain", "Flow padded", "Flow explicit")
        val padding = StyleEdges(px(0), px(9), px(0), px(7))
        val styles = listOf(null, BlockStyle(padding = padding), BlockStyle(margins = edges(), padding = padding))
        val entries = labels.mapIndexed { index, label ->
            val block = captionTable(label, flow = index >= 3, style = styles[index % 3])
            Entry("Caption spacing", emptyList(), "language", "English", "en",
                listOf(Section(1, "", listOf(block))), emptyList())
        }
        val selected = mutableIntStateOf(0)
        val refusals = mutableListOf<String>()
        setReaderContent {
            CompositionLocalProvider(LocalNativeFloatContextFailureObserver provides { refusals += it }) {
                EntryView(entries[selected.intValue], false, {}, settings = AppSettings(
                    allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false))
            }
        }

        val ruleTops = labels.mapIndexed { index, label ->
            compose.runOnIdle { selected.intValue = index }
            compose.waitForIdle()
            var top: Float? = null
            compose.activityRule.scenario.onActivity { activity ->
                val geometry = descendants(activity.window.decorView).filterIsInstance<NativeFloatTextView>()
                    .mapNotNull { it.currentMeasuredGeometry }.single { label in it.text }
                val bounds = geometry.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single()
                assertEquals("Authored rule height for $label", 2f, bounds.height(), 0.01f)
                top = bounds.top
            }
            checkNotNull(top)
        }
        compose.runOnIdle { assertTrue("Layout refusals: $refusals", refusals.isEmpty()) }
        ruleTops.chunked(3).forEachIndexed { index, (plain, padded, explicit) ->
            val route = if (index == 0) "Text" else "Flow"
            assertEquals("$route horizontal padding keeps the reader gap", plain, padded, 0.01f)
            assertEquals("$route explicit zero margins replace the reader gap", 6f, padded - explicit, 0.01f)
        }
    }

    @Test fun disclosureReplacementKeepsTheSameExactWidthLayoutNode() {
        val revision = mutableIntStateOf(0)
        val identities = List(2) { Any() }
        val width = NativeLayoutInput(160f)
        val activations = mutableListOf<Int>()
        setReaderContent {
            Box(Modifier.fillMaxSize()) {
                val index = revision.intValue
                val disclosure = ContainerDisclosure(0, true, "Expand $index", "Collapse $index")
                val format = NativeContainerTextFormat(
                    MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    NativeLineHeightPolicy.Normal)
                prepareNativeContainerDisclosureToggle(disclosure, false, { activations += index },
                    format, BidiResolvedDirection.Ltr, identities[index]).Content(width)
            }
        }

        lateinit var original: NativeContainerDisclosureView
        lateinit var widthNode: NativeLayoutInputNode<Float>
        compose.waitForIdle()
        compose.activityRule.scenario.onActivity { activity ->
            original = disclosureView(activity.window.decorView)
            assertEquals("Expand 0", original.logicalLabel)
            widthNode = checkNotNull(width.node)
            revision.intValue = 1
        }
        compose.waitForIdle()
        compose.activityRule.scenario.onActivity { activity ->
            val replacement = disclosureView(activity.window.decorView)
            assertEquals("Expand 1", replacement.logicalLabel)
            assertNotSame(original, replacement)
            assertFalse(original.isAttachedToWindow)
            assertSame(widthNode, width.node)
            assertTrue(replacement.performClick())
            assertEquals(listOf(1), activations)
        }
    }

    private fun captionTable(label: String, flow: Boolean, style: BlockStyle?): Block {
        val spans = listOf(Span("text", label))
        val paragraph = Block("paragraph", 0, if (flow) emptyList() else spans,
            style = style, flow = if (flow) listOf(FlowPart.Inline(spans)) else null)
        val rule = Block("rule", 0, emptyList(), ruleStyle = RuleStyle(px(2), ContainerColor.Rgb("#303030"), edges()))
        val cell = Cell(listOf(Span("text", "Grid")), false, 1, 1)
        return Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(cell)),
            captionBlocks = listOf(paragraph, rule)))
    }

    private fun disclosureView(root: View): NativeContainerDisclosureView = descendants(root)
        .filterIsInstance<NativeContainerDisclosureView>().single { it.isAttachedToWindow && it.currentMeasuredGeometry != null }

    private fun setReaderContent(content: @Composable () -> Unit) {
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f), content = content)
                }
            }
        }
    }

    private fun descendants(root: View): Sequence<View> = sequence {
        yield(root)
        if (root is ViewGroup) for (index in 0 until root.childCount) yieldAll(descendants(root.getChildAt(index)))
    }

    private fun edges() = StyleEdges(px(0), px(0), px(0), px(0))
    private fun px(value: Int) = StyleLength(StyleLengthUnit.Px, value.toFloat())
}
