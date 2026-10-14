package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.filters.SdkSuppress
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class WideTableDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val witness = "𓂜𓐰𓏏𓐱𓏭𓅪𓆑"
    private fun fixture(): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun u16(n: Int) = byteArrayOf(n.toByte(), (n ushr 8).toByte())
        fun string(s: String) = s.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun span(kind: Int, text: String, target: String = "", trail: String = "", classes: String = "", direction: String = "") =
            byteArrayOf(kind.toByte(), 0, 0) + listOf(text, target, trail, "", classes, direction)
                .fold(byteArrayOf()) { bytes, value -> bytes + string(value) }
        val cells = (0 until 6).fold(byteArrayOf()) { bytes, index ->
            val letter = ('A'.code + index).toChar()
            val ordinary = span(1, "Cell $letter", "target$letter", if (index == 0) " " else "")
            val spans = if (index == 0) u32(2) + ordinary + span(0, witness, classes = "Egyp", direction = "ltr")
                else u32(1) + ordinary
            bytes + byteArrayOf(0) + u16(100) + u16(1) + spans
        }
        val table = byteArrayOf(1) + u32(1) + span(0, "Wide forms") + u32(1) + u32(6) + cells
        val block = byteArrayOf(12, 0, 0) + u32(0) + byteArrayOf(0) + string("") + string("") + table
        return "DPR2".toByteArray() + u32(0) + u32(1) + byteArrayOf(3) + string("Noun") + u32(1) + block + ByteArray(20)
    }
    @Test
    @SdkSuppress(minSdkVersion = 31)
    fun sixInflatedCellsDecodeAndDisplayEveryLinkIncludingNativeEgyptianText() {
        val entry = BlobDecoder.decode(fixture(), "Wide table", "language", "English", "en")
        val table = checkNotNull(entry.sections.single().blocks.single().table)
        assertEquals(List(6) { 100 }, table.rows.single().map { it.colspan })
        assertEquals(6, tableGrid(table).columns)
        val clicked = AtomicReference<String?>()
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { EntryView(entry, false, {}, onLink = { clicked.set(it) }, settings = AppSettings(collapseOtherSections = false, collapseDetails = false)) }
            }
        }
        val first = "Cell A \u2066$witness\u2069"
        compose.waitUntil(10000) {
            compose.onAllNodesWithText(first, useUnmergedTree = true)
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .singleOrNull()?.config?.getOrNull(EgyptianShapedRunCount) == 1
        }
        compose.onNodeWithText("Wide forms", useUnmergedTree = true).assertIsDisplayed()
        for (index in 0 until 6) {
            val letter = ('A'.code + index).toChar()
            val text = if (index == 0) first else "Cell $letter"
            val node = compose.onNodeWithText(text, useUnmergedTree = true)
            node.performScrollTo().assertIsDisplayed()
            val layouts = mutableListOf<TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val layout = layouts.single()
            assertFalse("Every cell must retain all visible text", layout.hasVisualOverflow)
            if (index == 0) assertNotNull("Native cell must really render its placeholder", layout.placeholderRects.single())
            node.performTouchInput { click(layout.getBoundingBox(1).center) }
            compose.waitUntil(10000) { clicked.get() == "target$letter" }
        }
        compose.onNodeWithText("Table is too large to display.", useUnmergedTree = true).assertDoesNotExist()
    }
}
