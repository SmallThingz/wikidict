package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.RectF
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.Density
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.roundToInt
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class OriginalGreenPaletteDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()

    @Test fun originalPaletteGroupsThreeSwatchesAtCellOpacity() {
        val inst = InstrumentationRegistry.getInstrumentation()
        fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val shard = File.createTempFile("original-green-", ".wikblb.xz", inst.targetContext.cacheDir)
        val payload = try {
            inst.context.assets.open("green/original-en.wikblb.xz").use { input -> shard.outputStream().use { input.copyTo(it) } }
            assertEquals("0ee4869def9a2a7305592584e32c86a6eeb0e10693ce22590a3f11295efec9ca", sha(shard.readBytes()))
            BlobSource(shard).use { source ->
                assertTrue(source.compressed)
                assertEquals(193917L, source.length)
                val header = source.read(0, 38)
                val record = source.read(38, 193879)
                assertEquals("d3d7bed9aa9496a7572f0f4afacc6201fb70c33de3008d0e5550107ec2c39aa4", sha(header + record))
                assertEquals("6bebd9a5d79fb57093a74b04b65a359338399b2abddd87a4d9846f120a702581", sha(record))
                record
            }
        } finally { check(shard.delete()) }
        val entry = BlobDecoder.decode(payload, "green", "language", "Енглески", "en")
        val section = entry.sections[22]
        assertEquals("See also", section.title)
        val block = section.blocks[21]
        val table = checkNotNull(block.table)
        assertEquals(6, table.rows.first().single().colspan)
        val cells = table.rows.drop(1).flatten()
        assertEquals(16, cells.size)
        val owners = cells.flatMap { it.spans }.filter { it.inlineBoxGroup != null }
        assertEquals(40, owners.size)
        assertTrue(owners.all { it.inlineBoxGroup!!.spans.single().text == "\u00a0".repeat(4) })
        assertEquals(22, cells.flatMap { it.spans }.count { it.kind == "link" })
        val fadedCell = cells.single { it.style?.opacity == .2f }
        assertSame(table.rows[3][2], fadedCell)
        val fadedColors = fadedCell.spans.map { Color.parseColor(checkNotNull(it.background)) }
        val opaqueColors = table.rows[3][1].spans.filter { it.inlineBoxGroup != null }.map { Color.parseColor(checkNotNull(it.background)) }
        assertEquals(3, fadedColors.size); assertEquals(3, opaqueColors.size)
        assertEquals(24, entry.sections.size)
        assertEquals(1, entry.references.size)
        assertEquals(7, entry.media.size)
        val request = EntryAnchorRequest(entry.key, "#${section.anchor}")
        val clicked = mutableListOf<EntryLink>()
        fun views(root: View): List<NativeFloatTextView> = buildList {
            if (root is NativeFloatTextView) add(root)
            if (root is ViewGroup) for (i in 0 until root.childCount) addAll(views(root.getChildAt(i)))
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    DictTheme("light") { Surface { Box(Modifier.fillMaxSize().testTag("original-palette")) {
                        EntryView(entry, false, {}, onLink = { clicked += it }, anchorRequest = request,
                            settings = AppSettings(allowImages = false, allowAudio = false))
                    } } }
                }
            } }
            compose.waitForIdle()
            val viewport = compose.onNodeWithTag("original-palette", useUnmergedTree = true)
            val origin = viewport.fetchSemanticsNode().boundsInWindow
            // The real section has 21 preceding blocks. Bring the original row into the
            // viewport through the reader's vertical scroll owner before sampling pixels.
            val reader = compose.onNodeWithTag("entry-scroll")
            val position = compose.runOnIdle {
                val view = views(compose.activity.window.decorView).single { it.logicalText.toString() == "\u00a0".repeat(12) }
                val at = IntArray(2).also(view::getLocationInWindow)
                at[1] + view.height / 2f - (origin.top + origin.bottom) / 2f
            }
            reader.performSemanticsAction(SemanticsActions.ScrollBy) { it(0f, position) }
            compose.waitForIdle()
            val bitmap = viewport.captureToImage().asAndroidBitmap()
            try {
                val file = File(inst.targetContext.cacheDir, "wikidict-original-green-palette.png")
                file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                inst.sendStatus(0, android.os.Bundle().apply { putString("stream", "GREEN_FRAME ${file.name} bytes=${file.length()}\n") })
                compose.runOnIdle {
                    val visible = views(compose.activity.window.decorView)
                    val faded = visible.single { it.logicalText.toString() == "\u00a0".repeat(12) }
                    val green = visible.single { it.logicalText.toString().endsWith("green") && it.logicalText.contains('\u00a0') }
                    fun centers(view: NativeFloatTextView): List<Int> {
                        val geometry = checkNotNull(view.currentMeasuredGeometry)
                        val at = IntArray(2).also(view::getLocationInWindow)
                        val starts = Regex("\\u00a0{4}").findAll(geometry.text).map { it.range.first }.toList()
                        assertEquals(3, starts.size)
                        return starts.map { offset ->
                            val rect = RectF(checkNotNull(geometry.characterRects(offset + 1, 1).single()))
                            val x = (rect.centerX() + at[0] + view.paddingLeft - origin.left).toInt()
                            val y = (rect.centerY() + at[1] + view.paddingTop - origin.top).toInt()
                            assertTrue("Swatch outside viewport at ($x,$y)", x in 0 until bitmap.width && y in 0 until bitmap.height)
                            bitmap.getPixel(x,y)
                        }
                    }
                    val opaquePixels = centers(green)
                    val fadedPixels = centers(faded)
                    for (shift in listOf(0,8,16)) {
                        fun channel(color: Int) = color ushr shift and 255
                        for (i in opaqueColors.indices) assertTrue(abs(channel(opaqueColors[i]) - channel(opaquePixels[i])) <= 1)
                        // Differences cancel the common backdrop and measure the single
                        // whole-cell alpha independently of the device's theme colors.
                        for (i in 1..2) {
                            val expected = (.2f * (channel(fadedColors[i]) - channel(fadedColors[0]))).roundToInt()
                            assertTrue(abs(channel(fadedPixels[i]) - channel(fadedPixels[0]) - expected) <= 1)
                        }
                    }
                    assertTrue(checkNotNull(faded.currentMeasuredGeometry).nodes.none { it.onClick != null })
                    val action = checkNotNull(green.currentMeasuredGeometry).nodes.single { it.onClick != null && it.label.toString() == "green" }
                    assertTrue(green.accessibilityNodeProvider.performAction(action.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                    assertEquals("green", clicked.single().title); assertEquals("Енглески", clicked.single().fragment)
                }
            } finally { bitmap.recycle() }
        } finally { compose.runOnIdle { compose.activity.setContent {} } }
    }
}
