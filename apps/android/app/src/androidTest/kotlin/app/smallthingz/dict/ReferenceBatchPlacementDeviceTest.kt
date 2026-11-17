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
    @Test fun compiledReferenceLayoutUsesOneRealNativeGroupOriginalActionsFontsAndOutsideMarkersInBothDirections() {
        val direction = mutableStateOf(BidiResolvedDirection.Ltr)
        val actions = mutableListOf<EntryLink>()
        val font = InlineFontSnapshot(.9f, FontScaleBasis.NormalBody, fontNormalized = true,
            fontFamily = ContainerFontFamily.SansSerif)
        fun box(top: Float, bottom: Float, left: Float) = ContainerStyle(
            margins = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Px, top),
                SignedContainerMargin(StyleLengthUnit.Px, 0f), SignedContainerMargin(StyleLengthUnit.Px, bottom),
                SignedContainerMargin(StyleLengthUnit.Px, left)),
            padding = StyleEdges(StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, 0f),
                StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, 0f)),
            border = ContainerBorder.None, background = ContainerColor.Transparent,
            ownerFont = font, lineHeight = ContainerLineHeight.Normal,
            layout = ContainerLayout.Flow, clear = FigureClear.None, overflow = ContainerOverflow.Visible)
        val markerA = Span("link", "[A]", targetFragment = "reference-10", role = "reference",
            citationMarker = CitationMarker(10, 7, "return-A"))
        val markerB = Span("link", "[B]", targetFragment = "reference-20", role = "reference",
            citationMarker = CitationMarker(20, 8, "return-B"))
        val item = ReferenceItemLayout(box(3f, 5f, 0f), ReferenceListMarker.DecimalOutside,
            FigureColor.Rgb("#123456"), ReferenceBacklinkPrefix.SingleSpace)
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    MaterialTheme {
                        val refs = listOf(10L, 20L).mapIndexed { index, number ->
                            val suffix = if (index == 0) "A" else "B"
                            Reference(number, (index + 3).toLong(), "", listOf(Span("link", "Body $suffix", "Target $suffix")),
                                bodyTypography = BodyTypography(font, ContainerLineHeight.Normal, direction.value),
                                backlinks = listOf(ReferenceBacklink.withPolicies(if (index == 0) 7L else 8L,
                                    Span("link", "return $suffix", targetFragment = "return-$suffix",
                                        fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody))))
                        }
                        val entry = Entry("Real compiled batch", emptyList(), "language", "English", "en",
                            listOf(Section(2, "Body", listOf(Block("paragraph", depth = 0, spans = listOf(markerA, markerB,
                                Span("text", " body remains")))))), refs,
                            referenceBatches = listOf(ReferenceBatchPlacement(0, 1, listOf(1, 0),
                                ReferenceBatchLayout(box(4f, 6f, 0f), box(9f, 11f, 28f), listOf(item, item)))))
                        Box(Modifier.width(340.dp)) {
                            EntryView(entry, false, {}, onLink = { actions += it },
                                settings = AppSettings(allowImages = false, allowAudio = false,
                                    collapseOtherSections = false, collapseDetails = false))
                        }
                    }
                }
            } }
            for (next in listOf(BidiResolvedDirection.Ltr, BidiResolvedDirection.Rtl)) {
                compose.runOnIdle { direction.value = next }
                compose.waitForIdle()
                compose.onNodeWithText("References", useUnmergedTree = true).assertDoesNotExist()
                val view = nativeViews().single { it.currentMeasuredGeometry?.text?.toString()?.let { text ->
                    "Body B" in text && "Body A" in text } == true }
                compose.runOnIdle {
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    assertTrue(geometry.height > 0)
                    val text = geometry.text.toString()
                    assertTrue(text.indexOf("return B Body B") < text.indexOf("return A Body A"))
                    assertEquals(1, Regex("return B Body B").findAll(text).count())
                    assertEquals(1, Regex("return A Body A").findAll(text).count())
                    val markers = geometry.nodes.filter { it.kind == FloatInteractionKind.MARKER }
                    assertEquals(listOf("4. ", "3. "), markers.map { it.label.toString() })
                    val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        typeface = android.graphics.Typeface.SANS_SERIF; textSize = 16f * .9f
                    }
                    val context = geometry as NativeFloatContextGeometry
                    val bitmap = android.graphics.Bitmap.createBitmap(view.width, view.height, android.graphics.Bitmap.Config.ARGB_8888)
                    view.draw(android.graphics.Canvas(bitmap))
                    val expected = android.graphics.Bitmap.createBitmap(view.width, view.height, android.graphics.Bitmap.Config.ARGB_8888)
                    val expectedCanvas = android.graphics.Canvas(expected).apply {
                        translate(view.paddingLeft.toFloat(), view.paddingTop.toFloat())
                    }
                    val markerPaint = android.text.TextPaint(paint).apply { color = android.graphics.Color.rgb(0x12, 0x34, 0x56) }
                    try {
                        markers.forEachIndexed { index, marker ->
                            val suffix = if (index == 0) "B" else "A"
                            val leaf = context.inputLeaves().single { "return $suffix Body $suffix" in it.geometry.text.toString() }
                            val paragraph = leaf.geometry as NativeFloatGeometry
                            val band = paragraph.firstLineBand()
                            val bounds = marker.bounds.single()
                            val baseline = leaf.y + checkNotNull(paragraph.textBaselines?.first)
                            assertEquals(paint.measureText(marker.label.toString()), bounds.width(), .7f)
                            if (next == BidiResolvedDirection.Rtl)
                                assertEquals(leaf.x + band.right, bounds.left, .01f)
                            else assertEquals(leaf.x + band.left, bounds.right, .01f)
                            assertEquals(leaf.y + band.top, bounds.top, .01f)
                            val markerText = NativeMarkerText(marker.label.toString(), markerPaint, markerDirection = next)
                            markerText.paint(expectedCanvas,
                                if (next == BidiResolvedDirection.Rtl) leaf.x + band.right else leaf.x + band.left,
                                baseline, rightAligned = next != BidiResolvedDirection.Rtl)
                        }
                        var opaqueMarkerPixels = 0
                        for (y in 0 until expected.height) for (x in 0 until expected.width) {
                            if (expected.getPixel(x, y) == markerPaint.color) {
                                opaqueMarkerPixels++
                                assertEquals("Marker side/baseline pixel at $x,$y in $next", markerPaint.color, bitmap.getPixel(x, y))
                            }
                        }
                        assertTrue("Actual marker ink must exercise the LI baseline", opaqueMarkerPixels > 0)
                    } finally { bitmap.recycle(); expected.recycle() }
                    for (suffix in listOf("B", "A")) {
                        val node = geometry.nodes.single { it.label?.toString() == "Body $suffix" }
                        view.setSelection(node.start, node.end)
                        assertEquals("Body $suffix", view.selectedTextForCopy())
                        val provider = view.accessibilityNodeProvider
                        val ax = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                        assertTrue(ax.isClickable)
                        assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                    }
                }
            }
            assertEquals(listOf(EntryLink("Target B"), EntryLink("Target A"),
                EntryLink("Target B"), EntryLink("Target A")), actions)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }
}
