package app.smallthingz.dict

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.testTag
import android.content.Context
import androidx.activity.compose.setContent
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.input.key.Key
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class OriginalTableDisclosureDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()
    private val inst get() = InstrumentationRegistry.getInstrumentation()
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test fun nestedTextIntrinsicLeavesAnAdjacentSubcompositionToNormalMeasure() {
        var requested: ContainerWidths? = null
        var measured = false
        val label = "first second third"
        val parts = listOf(Span("text", label, ""))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val text = prepareNativeFloatText(parts, AnnotatedString(label), emptyList(),
                    TextStyle(fontSize = 16.sp), Color.Blue, emptyList(), AppSettings(), "", {})
                val owner = NativeFloatContextSpec.Container(1,
                    contentWidth = { _, widths -> requested = widths; kotlin.math.ceil(widths.maximum).toInt() },
                    intrinsicWidth = { content, _ -> content },
                    preparedParts = listOf(NativeFloatContextSpec.Text(text, 0f))) {}
                val sibling = NativeFloatContextSpec.Child(2, { it }, 0f)
                NativeFloatContextLayout(listOf(owner, sibling), Modifier.width(220.dp), Color.Blue,
                    onMeasuredGeometry = { geometry, _ -> measured = geometry != null }) { id, _ ->
                    check(id == 2)
                    BoxWithConstraints {
                        Box(Modifier.width(maxWidth).height(12.dp).testTag("subcomposition-sibling"))
                    }
                }
            } }
            compose.onNodeWithTag("subcomposition-sibling").assertIsDisplayed()
            compose.runOnIdle {
                assertTrue("Native layout measured both original owners", measured)
                val widths = checkNotNull(requested)
                assertTrue("Longest word has positive width", widths.minimum > 0f)
                assertTrue("Full multiword owner exceeds its longest word", widths.maximum > widths.minimum)
            }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    private fun original(): Entry {
        val tmp = File.createTempFile("tl-society-", ".wikblb.xz", inst.targetContext.cacheDir)
        val record = try {
            inst.context.assets.open("tl-society/disclosure.wikblb.xz").use { input -> tmp.outputStream().use { input.copyTo(it) } }
            assertEquals(2832L, tmp.length())
            assertEquals("e0939f8fe55bb31f92ffa4b5ad2b25d9d593e3d8e83983dfa166bcbf52d89918", sha(tmp.readBytes()))
            BlobSource(tmp).use { source ->
                assertTrue(source.compressed); assertEquals(20587L, source.length)
                assertEquals("eeb542fe4741553c4ec2f0dfddf4b95487731a1e72c2c5377d02221de446caf8", sha(source.read(0,20587)))
                source.read(35,20552).also { assertEquals("d0a00155e571c80a74d44e52cc85c938e64e66415df5a10b603352b60304167c",sha(it)) }
            }
        } finally { check(tmp.delete()) }
        return BlobDecoder.decode(record,"समाज","language","Marati","mr").also { entry ->
            val tables = entry.sections.single { it.anchor == "Paukulan_2" }.blocks.map { checkNotNull(it.table) }
            assertEquals(listOf(12,6), tables.map { it.rows.size })
            assertEquals(listOf(4,8),tables.map { it.rows[0].single().colspan })
            assertEquals(10,tables[0].rows[3][2].rowspan)
            assertEquals(listOf(4,8),tables.map { it.rows.last().single().colspan })
            val links = tables.flatMap { t -> t.rows.flatten().flatMap { c -> c.spans.filter { it.kind == "link" } } }
            assertEquals(32,links.size)
            for (table in tables) {
                val self = table.rows[0].single().spans.single { it.text == "समाज" }
                assertEquals("text",self.kind); assertTrue(self.bold); assertTrue(self.target.isEmpty())
            }
            // Stable source-oracle serialization includes physical row/cell boundaries and every
            // original row span, column span, header, span kind, Unicode text and destination.
            val body = ByteArrayOutputStream()
            DataOutputStream(body).use { out ->
                for (table in tables) {
                    out.writeInt(table.rows.size)
                    for (row in table.rows) {
                        out.writeInt(row.size)
                        for (cell in row) {
                            out.writeInt(if (cell.header) 1 else 0); out.writeInt(cell.rowspan); out.writeInt(cell.colspan)
                            out.writeInt(cell.spans.size)
                            for (span in cell.spans) for (field in listOf(span.kind,span.text,span.target)) {
                                val bytes = field.toByteArray(Charsets.UTF_8); out.writeInt(bytes.size);out.write(bytes)
                            }
                        }
                    }
                }
            }
            assertEquals("5f8de9294098b2811f253a4489f8436d6d1a3128c2ad55bb98d2cb1c0e597aaf",sha(body.toByteArray()))
        }
    }

    private val keyboardOwner = java.util.concurrent.atomic.AtomicReference<androidx.compose.ui.input.InputModeManager>()
    private fun withReaderKeyboard(action: () -> Unit) {
        val input = checkNotNull(keyboardOwner.get())
        val initial = compose.runOnIdle { input.inputMode }
        var primary: Throwable? = null
        try {
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                assertTrue(compose.activity.hasWindowFocus())
                assertTrue(input.requestInputMode(androidx.compose.ui.input.InputMode.Keyboard))
            }
            compose.waitUntil(10_000) { input.inputMode == androidx.compose.ui.input.InputMode.Keyboard }
            action()
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                if (initial == androidx.compose.ui.input.InputMode.Touch && input.inputMode != initial) {
                    // An owned physical touch returns Android to touch mode. Cancel before it can activate content.
                    val start = android.os.SystemClock.uptimeMillis()
                    var first: android.graphics.Point? = null
                    for (eventType in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_CANCEL)) {
                        val point = compose.runOnIdle {
                            val activity = compose.activity
                            assertPhysicalActivity(activity)
                            val decor = activity.window.decorView
                            assertTrue(activity.hasWindowFocus() && decor.hasWindowFocus())
                            val content = checkNotNull(activity.findViewById<android.view.View>(android.R.id.content))
                            val origin = IntArray(2).also(content::getLocationOnScreen)
                            val frame = android.graphics.Rect().also(decor::getWindowVisibleDisplayFrame)
                            assertTrue(frame.intersect(origin[0], origin[1], origin[0] + content.width, origin[1] + content.height))
                            assertTrue(frame.width() > 2 && frame.height() > 2)
                            android.graphics.Point(frame.left + 1, frame.top + 1)
                        }
                        if (first == null) first = point else assertEquals(first, point)
                        val event = android.view.MotionEvent.obtain(start, android.os.SystemClock.uptimeMillis(), eventType,
                            point.x.toFloat(), point.y.toFloat(), 0).apply { source = android.view.InputDevice.SOURCE_TOUCHSCREEN }
                        try { InstrumentationRegistry.getInstrumentation().sendPointerSync(event) } finally { event.recycle() }
                    }
                }
                compose.waitUntil(10_000) { input.inputMode == initial }
            } catch (cleanup: Throwable) {
                if (primary != null) primary.addSuppressed(cleanup) else throw cleanup
            }
        }
    }

    private val reader get() = compose.onNodeWithTag("entry-scroll")
    private fun control(table: Int) = hasTestTag("table-disclosure/block-4-$table/table/cell-0")

    private fun showHeader(table: Int): SemanticsNodeInteraction {
        reader.performScrollToNode(control(table))
        return compose.onNode(control(table), useUnmergedTree = true).performScrollTo().assertIsDisplayed()
    }

    private fun assertState(table: Int, expanded: Boolean) {
        val header = showHeader(table)
        header.assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, androidx.compose.ui.semantics.Role.Button))
            .assertContentDescriptionEquals(if (expanded) "less ▲" else "more ▼")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, if (expanded) "Expanded" else "Collapsed"))
        // The nearest actual grid contains the original flat source identifiers; identical labels
        // or flat IDs in the adjacent table cannot satisfy this witness.
        val grid = generateSequence(header.fetchSemanticsNode().parent) { it.parent }.first {
            it.config.getOrNull(SemanticsProperties.CollectionInfo) != null }
        val present = mutableMapOf<Int, androidx.compose.ui.semantics.CollectionItemInfo>()
        fun visit(node: androidx.compose.ui.semantics.SemanticsNode) {
            val tag = node.config.getOrNull(SemanticsProperties.TestTag).orEmpty()
            if (tag.startsWith("compiled-table-cell-")) {
                val original = tag.substringAfterLast('-').toInt()
                assertNull(present.put(original, node.config[SemanticsProperties.CollectionItemInfo]))
            }
            node.children.forEach(::visit)
        }
        visit(grid)
        val expected = when {
            table == 0 && expanded -> listOf(0) + (5..30)
            table == 0 -> (0..4).toList()
            expanded -> (0..30).toList()
            else -> listOf(0)
        }
        assertEquals("Visible original source cells table=$table expanded=$expanded", expected.toSet(), present.keys)
        assertEquals(if (table == 0) 4 else 8, present.getValue(0).columnSpan)
        if (table == 0 && expanded) assertEquals(10, present.getValue(7).rowSpan)
    }

    private fun categoryAction(show: Boolean): SemanticsNodeInteraction {
        val opener = hasContentDescription("Sections")
        reader.performScrollToNode(opener)
        compose.onNode(opener).performClick()
        return compose.onNodeWithText(if (show) "Show inflection" else "Hide inflection").performScrollTo()
    }

    private fun category(show: Boolean) {
        categoryAction(show).performClick()
        compose.waitForIdle()
    }

    @OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
    private fun footerAction(table: Int, actual: String, target: String) {
        fun annotation(text: androidx.compose.ui.text.AnnotatedString) = text.getLinkAnnotations(0, text.length).singleOrNull {
            (it.item as? androidx.compose.ui.text.LinkAnnotation.Clickable)?.tag == target && text.text.substring(it.start,it.end) == actual }
        val match = SemanticsMatcher("Original source link $target") { node ->
            node.config.getOrNull(SemanticsActions.GetTextLayoutResult) != null &&
                node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { annotation(it) != null } }
        reader.performScrollToNode(match)
        val text = compose.onNode(match, useUnmergedTree = true).performScrollTo()
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        text.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { assertTrue(it(layouts)) }
        val layout = layouts.single()
        val link = checkNotNull(annotation(layout.layoutInput.text))
        val local = layout.getBoundingBox(link.start).center
        val cell = generateSequence(text.fetchSemanticsNode().parent) { it.parent }.first {
            it.config.getOrNull(SemanticsProperties.CollectionItemInfo) != null }
        assertEquals(30, cell.config[SemanticsProperties.TestTag].substringAfterLast('-').toInt())
        assertEquals(if (table == 0) 4 else 8, cell.config[SemanticsProperties.CollectionItemInfo].columnSpan)
        text.performTouchInput { click(local) }
        compose.waitForIdle()
    }

    @Test fun originalSocietyTablesPreserveSourceRowsLocalFocusAndPersistentCategory() {
        val entry = original().copy(edition = "tlwiktionary-20261001")
        val tables = entry.sections[4].blocks.map { checkNotNull(it.table) }
        val modes = tables.map { table -> checkNotNull(table.disclosure).also { spec ->
            assertTrue(spec.initiallyCollapsed); assertEquals(0,spec.headerRow); assertEquals(0,spec.headerCell)
            assertEquals("inflection",spec.category);assertEquals("more ▼",spec.expandLabel);assertEquals("less ▲",spec.collapseLabel)
        }.rowModes }
        assertEquals(listOf(TableRowMode.Always,TableRowMode.Collapsed,TableRowMode.Collapsed)+List(9){TableRowMode.Expanded},modes[0])
        assertEquals(listOf(TableRowMode.Always)+List(5){TableRowMode.Expanded},modes[1])
        val context = inst.targetContext
        val key = "tl-disclosure-test-"+java.util.UUID.randomUUID()
        val prefs = context.getSharedPreferences(key, Context.MODE_PRIVATE)
        val opened = mutableListOf<EntryLink>()
        var visit by mutableIntStateOf(0)
        fun revisit() {
            compose.runOnIdle { visit++ }
            compose.waitForIdle()
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                androidx.compose.runtime.key(visit) {
                    val manager = androidx.compose.ui.platform.LocalInputModeManager.current
                    SideEffect { keyboardOwner.set(manager) }
                    val anchor = remember { EntryAnchorRequest(entry.key,"#Paukulan_2") }
                    val state = remember { EntryReadingState() }
                    CompositionLocalProvider(LocalTableVisibilityPreferences provides prefs) {
                        DictTheme("light") { Surface { EntryView(entry,false,{},onLink = { opened += it },
                            settings = AppSettings(collapseOtherSections = false,collapseDetails = false),
                            anchorRequest = anchor,readingState = state) } }
                    }
                }
            } }
            assertState(0,false);assertState(1,false)
            val first = showHeader(0)
            withReaderKeyboard {
                first.performSemanticsAction(SemanticsActions.RequestFocus) { assertTrue(it()) }
                first.assertIsFocused().performKeyInput { pressKey(Key.Enter) }
            }
            assertState(0,true);assertState(1,false)
            assertTrue(prefs.all.isEmpty())
            showHeader(1).performClick()
            assertState(0,true);assertState(1,true)
            categoryAction(false).assertIsDisplayed()
            assertTrue(prefs.all.isEmpty())
            revisit();assertState(0,false);assertState(1,false)
            category(true);assertState(0,true);assertState(1,true)
            footerAction(0,"-त","-त#Marati");footerAction(1,"ए","ए#Marati")
            assertEquals(listOf("-त" to "Marati", "ए" to "Marati"),opened.map { it.title to it.fragment })
            showHeader(1).performClick();assertState(0,true);assertState(1,false)
            showHeader(0).performClick();assertState(0,false);assertState(1,false)
            categoryAction(true).assertIsDisplayed()
            assertEquals(listOf(true), prefs.all.values.toList())
            revisit();assertState(0,true);assertState(1,true)
            category(false);assertState(0,false);assertState(1,false)
            revisit();assertState(0,false);assertState(1,false)
        } finally {
            compose.runOnIdle { compose.activity.setContent {} };compose.waitForIdle()
            context.deleteSharedPreferences(key)
        }
    }
}
