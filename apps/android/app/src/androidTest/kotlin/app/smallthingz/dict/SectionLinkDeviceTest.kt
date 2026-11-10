package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.findViewTreeViewModelStoreOwner
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Supported typed section/reference links; no wikitext parsing or network fixture. */
class SectionLinkDeviceTest {
    @get:Rule val compose = createLegacyPhysicalComposeRule()
    private val forwarded = mutableListOf<String>()

    @Test fun virtualFocusRevealsTallNativeLinksWithoutActivatingOrChangingCopy() {
        val clicks = mutableListOf<String>()
        val text = "First link\n" + "Body line\n".repeat(60) + "Last link"
        val last = text.indexOf("Last link")
        var owner: NativeFloatTextView? = null
        var scroller: android.widget.ScrollView? = null
        fun nodeBounds(id: Int): android.graphics.Rect {
            val node = checkNotNull(owner).accessibilityNodeProvider.createAccessibilityNodeInfo(id)
            checkNotNull(node)
            return try { android.graphics.Rect().also(node::getBoundsInScreen) } finally { node.recycle() }
        }
        fun visible(id: Int): Boolean {
            val viewport = android.graphics.Rect()
            val scroll = checkNotNull(scroller)
            return scroll.getGlobalVisibleRect(viewport) && viewport.contains(nodeBounds(id))
        }
        fun tab(shift: Boolean = false) {
            val view = checkNotNull(owner)
            val meta = if (shift) android.view.KeyEvent.META_SHIFT_ON else 0
            assertTrue(view.dispatchKeyEvent(android.view.KeyEvent(0, 0, android.view.KeyEvent.ACTION_DOWN,
                android.view.KeyEvent.KEYCODE_TAB, 0, meta)))
            view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_TAB))
        }
        fun waitVisible(id: Int) {
            compose.waitUntil(5000) {
                var shown = false
                InstrumentationRegistry.getInstrumentation().runOnMainSync { shown = visible(id) }
                shown
            }
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                androidx.compose.ui.viewinterop.AndroidView(modifier = androidx.compose.ui.Modifier.width(240.dp)
                    .height(120.dp), factory = { context ->
                    android.widget.ScrollView(context).also { scroll ->
                        scroll.isSmoothScrollingEnabled = false
                        val view = NativeFloatTextView(context)
                        owner = view; scroller = scroll
                        view.setPadding(7, 11, 9, 13)
                        view.bind({ width ->
                            NativeFloatGeometry.build(android.text.SpannableString(text), android.text.TextPaint().apply { textSize = 20f },
                                width, emptyList(), nodeFactory = { geometry -> listOf(
                                    FloatInteractionNode(0, FloatInteractionKind.LINK, 0, 10, geometry.rectsForRange(0, 10),
                                        "First link", null, { clicks += "first" }),
                                    FloatInteractionNode(1, FloatInteractionKind.LINK, last, text.length, geometry.rectsForRange(last, text.length),
                                        "Last link", null, { clicks += "last" })) })
                        }, 0x6633b5e5, 0xff1686c7.toInt())
                        scroll.addView(view, android.widget.FrameLayout.LayoutParams(android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                            android.view.ViewGroup.LayoutParams.WRAP_CONTENT))
                    }
                })
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue(checkNotNull(owner).requestFocus())
                assertTrue(visible(0)); assertFalse(visible(1))
                tab(); tab()
                assertTrue(clicks.isEmpty())
            }
            waitVisible(1)
            compose.runOnIdle {
                val view = checkNotNull(owner)
                val focused = checkNotNull(view.accessibilityNodeProvider.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT))
                try { assertEquals("Last link", focused.text.toString()) } finally { focused.recycle() }
                assertTrue(checkNotNull(scroller).scrollY > 0)
                assertTrue(view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf("last"), clicks)
                tab(shift = true)
            }
            waitVisible(0)
            compose.runOnIdle {
                assertTrue(checkNotNull(owner).accessibilityNodeProvider.performAction(1,
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertEquals(listOf("last"), clicks)
            }
            waitVisible(1)
            compose.runOnIdle {
                assertTrue(checkNotNull(owner).accessibilityNodeProvider.performAction(0,
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
            }
            waitVisible(0)
            compose.runOnIdle {
                val view = checkNotNull(owner)
                assertEquals(text, view.logicalText.toString())
                assertEquals(0, view.selectionStart); assertEquals(0, view.selectionEnd)
                assertEquals(listOf("last"), clicks)
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent { } }
            compose.waitForIdle()
        }
    }

    @Test fun separateComponentsSurviveTextImageAndNativeKeyboardAccessibilityActions() {
        val textAction = EntryLink("Literal#title%23?&語", "")
        val imageAction = EntryLink("Literal#image", "Caption#part")
        val clicks = mutableListOf<EntryLink>()
        val text = Span("link", "Literal component link", textAction.target, targetFragment = textAction.targetFragment)
        val image = Span("link", "", imageAction.target, targetFragment = imageAction.targetFragment,
            image = InlineImage("Controlled.svg", 20, alt = "Component image"))
        val paragraph = Block("paragraph", 0, listOf(text, Span("text", " "), image))
        val float = Block("table", 0, emptyList(), table = Table(emptyList(),
            listOf(listOf(Cell(listOf(Span("text", "Float")), false, 1, 1))),
            style = TableStyle(floatSide = TableFloatSide.Left)))
        fun show(native: Boolean) {
            val entry = Entry("Component actions", emptyList(), "supplemental", null, "",
                listOf(Section(2, "Actions", if (native) listOf(float, paragraph) else listOf(paragraph))), emptyList(),
                media = listOf(Media("Controlled.svg", "image", "")))
            compose.runOnUiThread { compose.activity.setContent {
                DictTheme("light") { androidx.compose.material3.Surface {
                    EntryView(entry, false, {}, onLink = { clicks += it },
                        settings = AppSettings(collapseOtherSections = false, collapseDetails = false, allowImages = false, allowAudio = false))
                } }
            } }
            compose.waitForIdle()
        }
        try {
            show(false)
            touchLink(text.text)
            compose.onNodeWithContentDescription("Component image", useUnmergedTree = true).performClick()
            compose.runOnIdle { assertEquals(listOf(textAction, imageAction), clicks); clicks.clear() }
            show(true)
            compose.runOnIdle {
                fun owner(view: android.view.View): NativeFloatTextView? {
                    if (view is NativeFloatTextView && view.logicalText.contains(text.text)) return view
                    if (view is android.view.ViewGroup) for (index in 0 until view.childCount) owner(view.getChildAt(index))?.let { return it }
                    return null
                }
                val view = checkNotNull(owner(compose.activity.window.decorView))
                val provider = checkNotNull(view.accessibilityNodeProvider)
                val link = checkNotNull(provider.createAccessibilityNodeInfo(0))
                try { assertEquals(text.text, link.text.toString()); assertTrue(link.isClickable) } finally { link.recycle() }
                assertTrue(provider.performAction(0, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                assertTrue(provider.performAction(0, android.view.accessibility.AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER)))
                view.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER))
                val imageNode = checkNotNull(provider.createAccessibilityNodeInfo(1))
                try { assertTrue(imageNode.isClickable) } finally { imageNode.recycle() }
                assertTrue(provider.performAction(1, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(textAction, textAction, imageAction), clicks)
            }
            // A component-only update must also invalidate the inline image's cached source URL.
            val fragment = androidx.compose.runtime.mutableStateOf("")
            val urls = mutableListOf<String>()
            compose.runOnUiThread { compose.activity.setContent {
                val sourceImage = Span("link", "", "File:Controlled.svg#literal", targetFragment = fragment.value,
                    image = InlineImage("Controlled.svg", 20, alt = "Changing component"))
                val entry = Entry("Image source component", emptyList(), "supplemental", null, "",
                    listOf(Section(2, "Image", listOf(Block("paragraph", 0, listOf(sourceImage))))), emptyList(),
                    media = listOf(Media("Controlled.svg", "image", "")), edition = "euwiktionary-20261001")
                androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalUriHandler provides
                    object : androidx.compose.ui.platform.UriHandler { override fun openUri(uri: String) { urls += uri } }) {
                    DictTheme("light") { androidx.compose.material3.Surface {
                        EntryView(entry, false, {}, settings = AppSettings(collapseOtherSections = false, allowImages = false))
                    } }
                }
            } }
            compose.onNodeWithContentDescription("Changing component", useUnmergedTree = true).performClick()
            compose.runOnIdle { fragment.value = "Caption#two" }
            compose.onNodeWithContentDescription("Changing component", useUnmergedTree = true).performClick()
            compose.runOnIdle { assertEquals(listOf(
                "https://eu.wiktionary.org/wiki/File%3AControlled.svg%23literal",
                "https://eu.wiktionary.org/wiki/File%3AControlled.svg%23literal#Caption%23two"), urls) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    private fun show(target: String, label: String, sectionTitle: String, references: List<Reference> = emptyList()) {
        val entry = Entry("Section link fixture", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", listOf(
                Block("definition", 1, listOf(Span("link", label, target = target)))
            ) + List(35) { Block("definition", 1, listOf(Span("text", "Earlier meaning $it"))) }),
            Section(3, sectionTitle, listOf(Block("paragraph", 0, listOf(Span("text", "SECTION DESTINATION BODY")))))
        ), references, preamble = listOf(Span("text", "Preamble keeps its own list row")))
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { EntryView(entry, false, {}, onLink = { forwarded.add(it.target) }, settings = AppSettings()) }
            }
        }
    }

    private fun touchLink(label: String) {
        val node = compose.onNodeWithText(label, useUnmergedTree = true)
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val glyph = layouts.single().getBoundingBox(1).center
        node.performTouchInput { click(glyph) }
        compose.waitForIdle()
    }


    private fun blankHeadingFixture(): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun u16(n: Int) = byteArrayOf(n.toByte(), (n ushr 8).toByte())
        fun string(value: String) = value.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun spans(text: String, target: String = ""): ByteArray =
            u32(1) + byteArrayOf(if (target.isEmpty()) 0 else 1, 0, 0) +
                listOf(text, target, "", "", "", "").fold(byteArrayOf()) { bytes, value -> bytes + string(value) }
        fun block(kind: Int, text: String, target: String = "", path: String = "",
                  table: ByteArray = byteArrayOf(0)): ByteArray =
            byteArrayOf(kind.toByte(), if (kind == 2 || kind == 5) 1 else 0, 0) +
                (if (kind == 12) u32(0) else spans(text, target)) +
                byteArrayOf(0) + string(path) + string("") + table
        fun table(text: String, target: String): ByteArray = block(12, "", table =
            byteArrayOf(1) + u32(0) + u32(1) + u32(1) +
                byteArrayOf(0) + u16(1) + u16(1) + spans(text, target))
        fun section(title: String, blocks: List<ByteArray>): ByteArray =
            byteArrayOf(3) + string(title) + u32(blocks.size) +
                blocks.fold(byteArrayOf()) { bytes, value -> bytes + value }
        val sections = listOf(
            section("", listOf(
                block(0, "Read blank prose", "prose"),
                block(5, "Read blank list", "list", "*"),
                table("Read blank cell", "cell"))),
            section(" \t", listOf(
                block(2, "Blank meaning"),
                block(0, "Read blank detail", "detail"),
                block(5, "Blank detail list", path = "*"),
                table("Blank detail cell", "detail-cell"))),
            section("Notes", listOf(block(0, "Named notes remain folded")))
        )
        return "DPR2".toByteArray() + u32(0) + u32(sections.size) +
            sections.fold(byteArrayOf()) { bytes, value -> bytes + value } +
            u32(0) + u32(0) + u32(0) + u32(0) + u32(0)
    }

    @Test fun decodedBlankHeadingsKeepContentAndLinksReachableWithRetainedFolds() {
        val entry = BlobDecoder.decode(blankHeadingFixture(), "Blank heading fixture", "language", "English", "en")
        assertEquals(listOf("", " \t", "Notes"), entry.sections.map { it.title })
        assertEquals(listOf("paragraph", "list_item", "table"), entry.sections[0].blocks.map { it.kind })
        assertEquals("cell", entry.sections[0].blocks[2].table!!.rows.single().single().spans.single().target)
        assertEquals(listOf("definition", "paragraph", "list_item", "table"), entry.sections[1].blocks.map { it.kind })
        val displayed = androidx.compose.runtime.mutableStateOf(entry)
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { EntryView(displayed.value, false, {}, onLink = { forwarded.add(it.target) }, settings = AppSettings()) }
            }
        }
        fun assertBlankContent() {
            for (label in listOf("Read blank prose", "Read blank list", "Read blank cell", "Blank meaning",
                    "Read blank detail", "Blank detail list", "Blank detail cell")) {
                compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
                compose.onNodeWithText(label, useUnmergedTree = true).assertIsDisplayed()
            }
            compose.onNodeWithText("Named notes remain folded").assertDoesNotExist()
        }
        assertBlankContent()
        for (label in listOf("Read blank prose", "Read blank list", "Read blank cell", "Read blank detail")) {
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
            touchLink(label)
        }
        compose.runOnIdle { assertEquals(listOf("prose", "list", "cell", "detail"), forwarded) }
        // Keep the same entry key and settings so EntryView retains its actual fold map.
        compose.runOnIdle {
            displayed.value = entry.copy(sections = entry.sections.mapIndexed { index, section ->
                if (index < 2) section.copy(title = "Foldable $index") else section
            })
        }
        for (index in 0..1) {
            val label = "Collapse Foldable $index"
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription(label))
            compose.onNodeWithContentDescription(label).performClick()
            compose.onNodeWithContentDescription("Expand Foldable $index").assertIsDisplayed()
        }
        compose.onNodeWithText("Read blank prose").assertDoesNotExist()
        compose.onNodeWithText("Blank meaning").assertDoesNotExist()
        compose.runOnIdle { displayed.value = entry }
        assertBlankContent()
        // A real named section remains folded and still exposes its ordinary toggle.
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand Notes"))
        compose.onNodeWithContentDescription("Expand Notes").performClick()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Named notes remain folded"))
        compose.onNodeWithText("Named notes remain folded").assertIsDisplayed()
    }


    private fun richHeadingFixture(): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun string(value: String) = value.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun span(text: String, target: String = "", kind: Int = if (target.isEmpty()) 0 else 1,
                 trail: String = ""): ByteArray =
            byteArrayOf(kind.toByte(), 0, 1) +
                listOf(text, target, trail, "", "", "").fold(byteArrayOf()) { bytes, value -> bytes + string(value) }
        fun block(kind: Int, depth: Int, text: String, target: String = "", spanKind: Int = if (target.isEmpty()) 0 else 1,
                  trail: String = "", level: Int = 0): ByteArray =
            byteArrayOf(kind.toByte(), depth.toByte(), level.toByte()) + u32(1) + span(text, target, spanKind, trail) +
                byteArrayOf(0) + string("") + string("") + byteArrayOf(0)
        fun section(level: Int, title: String, blocks: List<ByteArray>): ByteArray =
            byteArrayOf(level.toByte()) + string(title) + u32(blocks.size) +
                blocks.fold(byteArrayOf()) { bytes, value -> bytes + value }
        val sections = listOf(
            section(2, "English", listOf(
                block(9, 0, "English", "owner-target", level = 2),
                block(2, 1, "Owner meaning"),
                block(2, 1, "Jump to usage", "#Usage_notes"))),
            section(3, "Etymology 1", listOf(
                block(9, 0, "Etymology 1", "origin-target", level = 3),
                block(0, 0, "Historical body"))),
            section(3, "Usage notes", listOf(
                block(9, 0, "Usage", "https://example.org/heading", 2, " notes", level = 3),
                block(0, 0, "Usage destination body"))),
            section(4, "Noun", listOf(block(2, 1, "Following child meaning")))
        )
        return "DPR2".toByteArray() + u32(0) + u32(sections.size) +
            sections.fold(byteArrayOf()) { bytes, value -> bytes + value } +
            u32(0) + u32(0) + u32(0) + u32(0) + u32(0)
    }

    @Test fun decodedRichHeadingsKeepLinksFoldsContentsAndFragmentsIndependent() {
        val entry = BlobDecoder.decode(richHeadingFixture(), "Rich heading fixture", "language", "English", "en")
        assertEquals(listOf("English", "Etymology 1", "Usage notes", "Noun"), entry.sections.map { it.title })
        assertEquals(listOf(2, 3, 3, 4), entry.sections.map { it.level })
        assertEquals(listOf(0, 0, 0), entry.sections.take(3).map { it.blocks.first().depth })
        assertEquals(listOf(2, 3, 3), entry.sections.take(3).map { it.blocks.first().level })
        assertEquals(" notes", entry.sections[2].blocks.first().spans.single().trail)
        val displayed = androidx.compose.runtime.mutableStateOf(entry)
        val external = mutableListOf<String>()
        val uri = object : androidx.compose.ui.platform.UriHandler {
            override fun openUri(uri: String) { external.add(uri) }
        }
        compose.runOnUiThread {
            compose.activity.setContent {
                androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalUriHandler provides uri) {
                    MaterialTheme { EntryView(displayed.value, false, {}, onLink = { forwarded.add(it.target) }, settings = AppSettings()) }
                }
            }
        }
        fun reveal(text: String) {
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(text))
            compose.onNodeWithText(text, useUnmergedTree = true).assertIsDisplayed()
        }
        reveal("English")
        compose.onAllNodesWithText("English", useUnmergedTree = true).assertCountEquals(1)
        compose.onNodeWithText("Overview").assertDoesNotExist()
        compose.onNodeWithContentDescription("Hide examples and notes for English").assertDoesNotExist()
        touchLink("English")
        compose.runOnIdle { assertEquals(listOf("owner-target"), forwarded) }
        compose.onNodeWithContentDescription("Collapse English").assertIsDisplayed()
        reveal("Owner meaning")

        reveal("Etymology 1")
        compose.onAllNodesWithText("Etymology 1", useUnmergedTree = true).assertCountEquals(1)
        touchLink("Etymology 1")
        compose.runOnIdle { assertEquals(listOf("owner-target", "origin-target"), forwarded) }
        compose.onNodeWithContentDescription("Expand Etymology 1").assertIsDisplayed()
        compose.onNodeWithText("Historical body").assertDoesNotExist()
        reveal("Following child meaning") // A folded preceding heading never owns this section.
        reveal("Etymology 1")
        compose.onNodeWithContentDescription("Expand Etymology 1").performClick()
        reveal("Historical body")
        reveal("Etymology 1")
        compose.onNodeWithContentDescription("Collapse Etymology 1").performClick()
        compose.runOnIdle { displayed.value = entry.copy(displayTitle = listOf(Span("text", "Refreshed rich fixture"))) }
        compose.onNodeWithText("Historical body").assertDoesNotExist()
        reveal("Etymology 1")
        compose.onNodeWithContentDescription("Expand Etymology 1").assertIsDisplayed()

        reveal("Usage notes")
        touchLink("Usage notes")
        compose.runOnIdle { assertEquals(listOf("https://example.org/heading"), external) }
        compose.onNodeWithContentDescription("Expand Usage notes").assertIsDisplayed()
        compose.onNodeWithText("Usage destination body").assertDoesNotExist()
        reveal("Jump to usage")
        touchLink("Jump to usage")
        compose.onNodeWithText("Usage destination body").assertIsDisplayed()
        compose.onNodeWithContentDescription("Collapse Usage notes").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf("owner-target", "origin-target"), forwarded) }
        compose.onNodeWithContentDescription("Collapse Usage notes").performClick()
        compose.onNodeWithTag("entry-scroll").performScrollToIndex(0)
        compose.onNodeWithContentDescription("Sections").performClick()
        compose.onNode(hasText("Usage notes") and hasAnyAncestor(isPopup())).performClick()
        compose.onNodeWithText("Usage destination body").assertIsDisplayed()
        compose.onAllNodesWithText("Usage notes", useUnmergedTree = true).assertCountEquals(1)
    }

    @Test fun referenceFragmentsKeepBodyAndMediaWithoutLabelsOrGeneratedCitationTargets() {
        val entry = Entry("Reference fragment display", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", listOf(
                Block("definition", 1, listOf(Span("link", "Try fragment identity", target = "#reference-2"))),
                Block("definition", 1, listOf(Span("link", "Read numbered note", target = "#reference-1")))))
        ), listOf(
            Reference(2, null, "notes", listOf(Span("link", "FRAGMENT BODY", target = "fragment-word"),
                Span("text", " Fragment audio", target = "File:Tone.ogg", classes = "wikidict-media")), ReferenceKind.Fragment),
            Reference(1, 1, "notes", listOf(Span("text", "NUMBERED NOTE BODY"))),
            Reference(3, 2, "notes", listOf(Span("text", "LATER NOTE BODY")))),
            media = listOf(Media("Tone.ogg", "audio", "Fragment audio")))
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { EntryView(entry, false, {}, onLink = { forwarded.add(it.target) },
                    settings = AppSettings(allowImages = false, allowAudio = false)) }
            }
        }
        touchLink("Try fragment identity")
        compose.onNodeWithText("NUMBERED NOTE BODY").assertDoesNotExist()
        touchLink("Read numbered note")
        compose.onNodeWithText("NUMBERED NOTE BODY").assertIsDisplayed()
        compose.onNodeWithText("[notes 1]").assertIsDisplayed()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("FRAGMENT BODY Fragment audio"))
        compose.onNodeWithText("FRAGMENT BODY Fragment audio", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("[notes null]").assertDoesNotExist()
        compose.onNodeWithText("[null]").assertDoesNotExist()
        compose.onAllNodesWithContentDescription("Play pronunciation").assertCountEquals(1)
        compose.onNodeWithContentDescription("Play pronunciation").assertIsNotEnabled()
        touchLink("FRAGMENT BODY Fragment audio")
        compose.runOnIdle { assertEquals(listOf("fragment-word"), forwarded) }
    }

    @Test fun emptyReferencesLeafMenuAndLinksReachTheActualCitationFooter() {
        val entry = Entry("qichwa reference navigation", emptyList(), "language", "Quechua", "qu", listOf(
            Section(3, "Noun", listOf(
                Block("definition", 1, listOf(Span("link", "Read references", target = "#References"))),
                Block("definition", 1, listOf(Span("link", "Read second citation", target = "#reference-2"))))),
            Section(3, "References", emptyList(), anchor = "References"),
            Section(3, "Further reading", List(30) {
                Block("paragraph", 0, listOf(Span("text", "Further reading item $it"))) })
        ), listOf(Reference(1, 1, "", listOf(Span("text", "FIRST ACTUAL CITATION"))),
            Reference(2, 2, "", listOf(Span("text", "SECOND ACTUAL CITATION")))),
            preamble = listOf(Span("text", "Preamble keeps a separate row")))
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { EntryView(entry, false, {}, onLink = { forwarded.add(it.target) },
                    settings = AppSettings(collapseOtherSections = false, collapseDetails = false)) }
            }
        }
        compose.onNodeWithContentDescription("Sections").performClick()
        compose.onNode(hasText("References") and hasAnyAncestor(isPopup())).performClick()
        compose.onNodeWithText("FIRST ACTUAL CITATION").assertIsDisplayed()
        compose.onAllNodesWithText("References", useUnmergedTree = true).assertCountEquals(1)
        for (label in listOf("Read references", "Read second citation")) {
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Collapse References"))
            compose.onNodeWithContentDescription("Collapse References").performClick()
            compose.onNodeWithText("FIRST ACTUAL CITATION").assertDoesNotExist()
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
            touchLink(label)
            compose.onNodeWithText(if (label == "Read references") "FIRST ACTUAL CITATION" else "SECOND ACTUAL CITATION")
                .assertIsDisplayed()
        }
        compose.runOnIdle { assertTrue(forwarded.isEmpty()) }
    }

    @Test fun sameEntrySectionLinkOpensFoldedHeadingAndShowsItsBody() {
        show("#Usage_notes", "Read usage notes", "Usage notes")
        compose.onNodeWithText("SECTION DESTINATION BODY").assertDoesNotExist()
        touchLink("Read usage notes")
        compose.onNodeWithText("SECTION DESTINATION BODY").assertIsDisplayed()
        compose.onNodeWithContentDescription("Collapse Usage notes").assertIsDisplayed()
        compose.runOnIdle { assertTrue(forwarded.isEmpty()) }
    }

    @Test fun actualReferenceIdentityKeepsPriorityOverAMatchingSectionTitle() {
        show("#reference-2", "Read the reference", "reference-2", listOf(
            Reference(1, 1, "notes", listOf(Span("text", "Other reference"))),
            Reference(2, 1, "", listOf(Span("text", "REFERENCE DESTINATION BODY")))
        ))
        compose.onNodeWithText("REFERENCE DESTINATION BODY").assertDoesNotExist()
        touchLink("Read the reference")
        compose.onNodeWithText("REFERENCE DESTINATION BODY").assertIsDisplayed()
        compose.onNodeWithText("SECTION DESTINATION BODY").assertDoesNotExist()
        compose.runOnIdle { assertTrue(forwarded.isEmpty()) }
    }
    @Test fun crossEntryFragmentNavigatesOnceThroughTheActualLibraryAndApp(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue("Use the isolated validation app", context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        val learning = LearningStore.get(context)
        val before = library.dictionaries.map { it.id }.toSet()
        val previousSettings = learning.data.settings
        val prefs = context.getSharedPreferences("library", 0)
        val lastKeys = listOf("lastTitle", "lastLanguage", "lastDictionary", "lastRecordKey", "lastContextDictionary", "lastEdition")
        val previousWord = lastKeys.associateWith { prefs.getString(it, null) }
        val fixtureKeys = mutableListOf<String>()
        try {
            val edition = "anchorwiktionary-20261001"
            val english = "ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06"
            library.importFile(name = { "$edition-$english.wikblb" }) {
                instrumentation.context.assets.open("semantic-anchor-navigation.wikblb")
            }.join()
            assertNull(library.error)
            val dictionary = library.dictionaries.single { it.id !in before }
            assertEquals(2, dictionary.count)
            val source = library.search("Anchor source").single { it.dictionary == dictionary.id && it.title == "Anchor source" }
            val destination = library.search("Anchor destination").single { it.dictionary == dictionary.id && it.title == "Anchor destination" }
            fixtureKeys += library.read(source).key
            fixtureKeys += library.read(destination).key
            assertEquals(edition, dictionary.edition)
            library.importFile(name = { "$edition-aliases.wikblb" }) {
                instrumentation.context.assets.open("semantic-anchor-navigation-aliases.wikblb")
            }.join()
            assertNull(library.error)
            val aliasDictionary = library.dictionaries.single { it.id !in before && it.id != dictionary.id }
            val alias = library.search("Anchor alias").single {
                it.dictionary == aliasDictionary.id && it.contextDictionary == dictionary.id && it.title == "Anchor alias"
            }
            val followed = library.read(alias)
            assertEquals("Anchor destination", followed.title)
            assertEquals(edition, followed.edition)
            assertTrue(requireNotNull(followed.redirect).followed)
            assertEquals("Noun_2", requireNotNull(followed.redirect).fragment)
            fixtureKeys += alias.key
            fixtureKeys += followed.key
            compose.runOnUiThread {
                learning.updateSettings { it.copy(collapseEtymology = true, collapseOtherSections = true, allowImages = false, allowAudio = false) }
                compose.activity.setContent { MaterialTheme { DictApp(library, learning, onImport = {}) } }
            }
            fun paragraphStarting(marker: String) = SemanticsMatcher("paragraph starts with $marker") { node ->
                node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Text)?.any {
                    it.text == marker || it.text.startsWith("$marker ")
                } == true
            }
            fun journeyLink(label: String) = SemanticsMatcher("compiled link labeled $label") { node ->
                node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Text)?.any { text ->
                    text.getLinkAnnotations(0, text.length).any {
                        it.item is androidx.compose.ui.text.LinkAnnotation.Clickable &&
                            text.text.substring(it.start, it.end) == label
                    }
                } == true
            }
            fun touchJourneyLink(label: String, repeatedTarget: String? = null) {
                val node = if (repeatedTarget == null) {
                    compose.onNode(journeyLink(label), useUnmergedTree = true)
                } else {
                    val candidates = compose.onAllNodes(journeyLink(label), useUnmergedTree = true)
                    val count = candidates.fetchSemanticsNodes().size
                    val displayed = (0 until count).map { candidates[it] }.firstOrNull { it.isDisplayed() }
                    checkNotNull(displayed) { "No displayed compiled link labeled $label" }
                }.assertIsDisplayed()
                val layouts = mutableListOf<TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                val text = layout.layoutInput.text
                val links = text.getLinkAnnotations(0, text.length).filter {
                    it.item is androidx.compose.ui.text.LinkAnnotation.Clickable &&
                        text.text.substring(it.start, it.end) == label
                }
                assertEquals(1, links.size)
                val link = links.single()
                if (repeatedTarget != null) {
                    assertEquals(repeatedTarget, (link.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
                }
                val offset = link.start + minOf(1, link.end - link.start - 1)
                node.performTouchInput { click(layout.getBoundingBox(offset).center) }
                compose.waitForIdle()
            }
            fun waitForTitle(title: String) {
                compose.waitUntil(10000) { compose.onAllNodes(hasTestTag("entry-title") and hasText(title)).fetchSemanticsNodes().isNotEmpty() }
            }
            fun assertDestinationOpen() {
                // The destination title is intentionally offscreen after the anchor jump.
                compose.waitUntil(10000) { compose.onAllNodes(paragraphStarting("DESTINATION USAGE BODY"), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
                compose.onNode(paragraphStarting("DESTINATION USAGE BODY"), useUnmergedTree = true).assertIsDisplayed()
                compose.onNodeWithContentDescription("Collapse Usage notes").assertIsDisplayed()
                compose.onNode(paragraphStarting("PARENT SECTION REMAINS FOLDED"), useUnmergedTree = true).assertDoesNotExist()
            }
            fun backToSource() {
                compose.onNodeWithTag("entry-scroll").performScrollToNode(journeyLink("Back to source"))
                touchJourneyLink("Back to source", repeatedTarget = "Anchor source")
                waitForTitle("Anchor source")
            }
            fun leaveAndReturn() {
                compose.onNodeWithContentDescription("Settings").performClick()
                compose.onNodeWithContentDescription("Dictionary").performClick()
                compose.onNodeWithContentDescription("Close search").performClick()
                // Returning retains the anchor scroll; the lazy title may be offscreen.
                compose.onNodeWithTag("entry-scroll").performScrollToNode(
                    hasTestTag("entry-title") and hasText("Anchor destination")
                )
                waitForTitle("Anchor destination")
            }
            // A retained reader session is not reset by setContent; select this installed fixture normally.
            compose.onNodeWithContentDescription("Dictionary").performClick()
            compose.onNode(hasSetTextAction()).performTextReplacement("Anchor source")
            val sourceChoice = hasText("Anchor source") and hasText(source.language) and
                hasText(sourceLabel(source.edition)) and hasClickAction() and !hasSetTextAction()
            compose.waitUntil(10000) {
                compose.onAllNodes(sourceChoice).fetchSemanticsNodes(atLeastOneRootRequired = false).size == 1
            }
            compose.onAllNodes(sourceChoice).assertCountEquals(1).onFirst().performClick()
            waitForTitle("Anchor source")
            assertEquals(source.key, runBlocking { library.lastWord() }?.key)
            touchJourneyLink("Read destination notes")
            assertDestinationOpen()
            compose.onNodeWithContentDescription("Collapse Usage notes").performClick()
            leaveAndReturn()
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand Usage notes"))
            compose.onNodeWithContentDescription("Expand Usage notes").assertIsDisplayed()
            compose.onNode(paragraphStarting("DESTINATION USAGE BODY"), useUnmergedTree = true).assertDoesNotExist()
            // A fresh request to the same word and anchor must still be applied.
            compose.onNodeWithTag("entry-scroll").performScrollToNode(journeyLink("Read destination notes again"))
            touchJourneyLink("Read destination notes again")
            assertDestinationOpen()
            backToSource()
            touchJourneyLink("Read destination normally")
            waitForTitle("Anchor destination")
            compose.onNode(paragraphStarting("DESTINATION USAGE BODY"), useUnmergedTree = true).assertDoesNotExist()
            compose.onNodeWithText("Earlier destination meaning 0").assertIsDisplayed()
            backToSource()
            touchJourneyLink("Read missing anchor")
            waitForTitle("Anchor destination")
            compose.onNodeWithText("Earlier destination meaning 0").assertIsDisplayed()
            compose.onNode(paragraphStarting("DESTINATION USAGE BODY"), useUnmergedTree = true).assertDoesNotExist()
            compose.onNodeWithText("This word is not in your installed dictionaries.").assertDoesNotExist()
            leaveAndReturn()
            compose.onNode(paragraphStarting("DESTINATION USAGE BODY"), useUnmergedTree = true).assertDoesNotExist()
            compose.onNodeWithText("This word is not in your installed dictionaries.").assertDoesNotExist()

            // These assets come from the genuine Writer fixture, not hand-built EntryUi.
            // Each request crosses the actual import/search/read/DictApp route.
            fun touchSourceLink(label: String) {
                compose.onNodeWithTag("entry-scroll").performScrollToNode(journeyLink(label))
                touchJourneyLink(label)
            }
            fun assertAnchorBody(body: String) {
                compose.waitUntil(10000) { compose.onAllNodes(paragraphStarting(body), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
                // Do not scroll to the expected body: the fragment must perform the jump.
                compose.onNode(paragraphStarting(body), useUnmergedTree = true).assertIsDisplayed()
            }
            fun captureOwnedAnchorJourney(name: String, body: String) {
                require(name in setOf("anchor-journey-samepage.png", "anchor-journey-crossentry.png",
                    "anchor-journey-alias.png", "anchor-journey-unicode.png"))
                // Only the owned app root displaying this imported public Writer fixture.
                // No system screenshot, clipboard surface or unrelated application tree.
                compose.onNode(paragraphStarting(body), useUnmergedTree = true).assertIsDisplayed()
                val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
                try {
                    val files = instrumentation.targetContext.filesDir
                    val directory = java.io.File(files, "qa-copy-evidence")
                    check(directory.mkdirs() || directory.isDirectory)
                    check(directory.canonicalFile.parentFile == files.canonicalFile)
                    val target = java.io.File(directory, name)
                    check(target.canonicalFile.parentFile == directory.canonicalFile && !target.exists())
                    target.outputStream().use {
                        check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
                    }
                } finally { bitmap.recycle() }
            }
            backToSource()
            compose.onNode(paragraphStarting("SOURCE SECOND NOUN BODY"), useUnmergedTree = true).assertIsNotDisplayed()
            touchSourceLink("Read second local noun")
            assertAnchorBody("SOURCE SECOND NOUN BODY")
            assertEquals(source.key, library.lastWord()?.key)
            captureOwnedAnchorJourney("anchor-journey-samepage.png", "SOURCE SECOND NOUN BODY")
            touchSourceLink("Read destination second noun")
            assertAnchorBody("DESTINATION SECOND NOUN BODY")
            assertEquals(destination.key, library.lastWord()?.key)
            captureOwnedAnchorJourney("anchor-journey-crossentry.png", "DESTINATION SECOND NOUN BODY")
            backToSource()
            touchSourceLink("Read alias second noun")
            assertAnchorBody("DESTINATION SECOND NOUN BODY")
            assertEquals(alias.key, library.lastWord()?.key)
            captureOwnedAnchorJourney("anchor-journey-alias.png", "DESTINATION SECOND NOUN BODY")
            backToSource()
            touchSourceLink("Read legacy Unicode heading")
            assertAnchorBody("UNICODE HEADING BODY")
            compose.onNode(paragraphStarting("LITERAL DOT HEADING BODY"), useUnmergedTree = true).assertDoesNotExist()
            assertEquals(source.key, library.lastWord()?.key)
            captureOwnedAnchorJourney("anchor-journey-unicode.png", "UNICODE HEADING BODY")
        } finally {
            compose.runOnUiThread {
                learning.updateSettings { previousSettings }
                fixtureKeys.forEach(learning::removeHistory)
            }
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
            prefs.edit().apply { previousWord.forEach { (key, value) -> putString(key, value) } }.commit()
        }
    }

    @Test fun selfHeadingCompanionsRenderOnceWithoutActionsAndKeepFoldsAndFragments() {
        val markers = "mw-selflink selflink"
        val owner = Span("text", "English", classes = markers, bold = true, italic = true)
        val normal = Span("text", "Usage notes", classes = markers)
        val entry = Entry("Self heading fixture", emptyList(), "language", "English", "en", listOf(
            Section(2, "English", listOf(
                Block("heading", 0, listOf(owner), level = 2),
                Block("definition", 1, listOf(Span("link", "Independent entry link", target = "other-entry"))),
                Block("definition", 1, listOf(Span("link", "Jump to usage", target = "#Usage_notes"))))),
            Section(3, "Usage notes", listOf(
                Block("heading", 0, listOf(normal), level = 3),
                Block("paragraph", 0, listOf(Span("text", "SELF HEADING DESTINATION")))))
        ), emptyList()).copy(displayTitle = listOf(Span("text", "Self heading fixture", bold = true)))
        compose.runOnUiThread {
            compose.activity.setContent {
                DictTheme("system") { androidx.compose.material3.Surface(
                    modifier = androidx.compose.ui.Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) { EntryView(entry, false, {}, onLink = { forwarded.add(it.target) }, settings = AppSettings()) } }
            }
        }
        fun layout(label: String): TextLayoutResult {
            val node = compose.onNodeWithText(label, useUnmergedTree = true)
            val results = mutableListOf<TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
            return results.single()
        }
        fun selfLabel(label: String, bold: Boolean, italic: Boolean) {
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
            compose.onAllNodesWithText(label, useUnmergedTree = true).assertCountEquals(1)
            compose.onNodeWithText(label, useUnmergedTree = true).assertHasNoClickAction()
            val text = layout(label).layoutInput.text
            assertTrue(text.getLinkAnnotations(0, text.length).isEmpty())
            assertEquals(bold, text.spanStyles.any { it.item.fontWeight == androidx.compose.ui.text.font.FontWeight.Bold })
            assertEquals(italic, text.spanStyles.any { it.item.fontStyle == androidx.compose.ui.text.font.FontStyle.Italic })
            touchLink(label) // Physical glyph click must neither navigate nor toggle the separate fold button.
            compose.runOnIdle { assertTrue(forwarded.isEmpty()) }
        }
        // The caller tag belongs to the selectable container; text layout remains on its leaf.
        compose.onNodeWithTag("entry-title", useUnmergedTree = true).assertIsDisplayed()
        val titleNode = compose.onNode(
            hasText("Self heading fixture") and hasAnyAncestor(hasTestTag("entry-title")) and
                SemanticsMatcher.keyIsDefined(SemanticsActions.GetTextLayoutResult), useUnmergedTree = true)
        titleNode.assertIsDisplayed().assertHasNoClickAction()
        val titleLayouts = mutableListOf<TextLayoutResult>()
        titleNode.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(titleLayouts) }
        assertEquals("Self heading fixture", titleLayouts.single().layoutInput.text.text)
        assertTrue(titleLayouts.single().layoutInput.text.spanStyles.any { it.item.fontWeight == androidx.compose.ui.text.font.FontWeight.Bold })
        selfLabel("English", bold = true, italic = true)
        compose.onNodeWithContentDescription("Collapse English").assertIsDisplayed()
        compose.onNodeWithText("Independent entry link").assertIsDisplayed()
        captureOwnedSelfHeading("self-heading-default.png")
        touchLink("Independent entry link")
        compose.runOnIdle { assertEquals(listOf("other-entry"), forwarded); forwarded.clear() }
        selfLabel("Usage notes", bold = false, italic = false)
        compose.onNodeWithContentDescription("Expand Usage notes").assertIsDisplayed()
        compose.onNodeWithText("SELF HEADING DESTINATION").assertDoesNotExist()
        compose.onNodeWithContentDescription("Expand Usage notes").performClick()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("SELF HEADING DESTINATION"))
        compose.onNodeWithText("SELF HEADING DESTINATION").assertIsDisplayed()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Collapse Usage notes"))
        compose.onNodeWithContentDescription("Collapse Usage notes").performClick()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Jump to usage"))
        touchLink("Jump to usage")
        compose.onNodeWithText("SELF HEADING DESTINATION").assertIsDisplayed()
        compose.onNodeWithContentDescription("Collapse Usage notes").assertIsDisplayed()
        compose.onAllNodesWithText("Usage notes", useUnmergedTree = true).assertCountEquals(1)
        compose.runOnIdle { assertTrue(forwarded.isEmpty()); assertEquals(owner, entry.sections[0].blocks[0].spans.single()); assertEquals(normal, entry.sections[1].blocks[0].spans.single()) }

        // Explicit client-only narrow RTL/2x fixture. No global font, locale or device setting changes.
        val rtlSelf = "عنوان ذاتي طويل يحافظ على التفاف النص واتجاه القراءة"
        val rtlNeighbor = "رابط مستقل"
        val rtlLabel = "$rtlSelf / $rtlNeighbor"
        val rtlSpans = listOf(
            Span("text", rtlSelf, classes = markers, direction = "rtl", bold = true, italic = true),
            Span("text", " / "),
            Span("link", rtlNeighbor, target = "rtl-other-entry", direction = "rtl"))
        val rtlEntry = Entry("RTL", emptyList(), "language", "Arabic", "ar", listOf(
            Section(3, rtlLabel, listOf(
                Block("heading", 0, rtlSpans, level = 3),
                Block("paragraph", 0, listOf(Span("text", "RTL FOLD BODY")))))
        ), emptyList(), preamble = listOf(Span("text", "RTL GENERIC FOLD BODY")))
        compose.runOnIdle { forwarded.clear() }
        compose.runOnUiThread {
            compose.activity.setContent {
                val baseDensity = androidx.compose.ui.platform.LocalDensity.current
                androidx.compose.runtime.CompositionLocalProvider(
                    androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(baseDensity.density, 2f),
                    androidx.compose.ui.platform.LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Rtl
                ) {
                    DictTheme("system") { androidx.compose.material3.Surface(
                        modifier = androidx.compose.ui.Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background
                    ) {
                        // Consume Surface's full minimum constraints before narrowing the inner owned viewport.
                        androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.fillMaxSize()) {
                            androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.width(280.dp).fillMaxSize().testTag("self-heading-rtl-viewport")) {
                                EntryView(rtlEntry, false, {}, onLink = { forwarded.add(it.target) }, settings = AppSettings(collapseOtherSections = true))
                            }
                        }
                    } }
                }
            }
        }
        // Exercise the other production disclosure site in the same owned
        // RTL fixture and existing frame, without a separate screenshot.
        // collapseOtherSections=true also initializes the preamble collapsed.
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand About this entry"))
        compose.onNodeWithText("RTL GENERIC FOLD BODY").assertDoesNotExist()
        compose.onNodeWithContentDescription("Expand About this entry").assertIsDisplayed().assertHasClickAction()
        val mixedMatcher = hasText(rtlSelf, substring = true) and
            SemanticsMatcher.keyIsDefined(SemanticsActions.GetTextLayoutResult)
        compose.onNodeWithTag("entry-scroll").performScrollToNode(mixedMatcher)
        compose.onAllNodes(mixedMatcher, useUnmergedTree = true).assertCountEquals(1)
        val mixedNode = compose.onNode(mixedMatcher, useUnmergedTree = true)
        val mixedLayouts = mutableListOf<TextLayoutResult>()
        mixedNode.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(mixedLayouts) }
        val mixedLayout = mixedLayouts.single()
        val mixedText = mixedLayout.layoutInput.text
        val selfOffset = mixedText.text.indexOf(rtlSelf)
        val neighborOffset = mixedText.text.indexOf(rtlNeighbor)
        assertTrue(selfOffset >= 0 && neighborOffset > selfOffset)
        assertEquals(2f, mixedLayout.layoutInput.density.fontScale, 0f)
        assertEquals(androidx.compose.ui.text.style.ResolvedTextDirection.Rtl, mixedLayout.getParagraphDirection(selfOffset))
        assertTrue("Long self text must actually wrap", mixedLayout.getLineForOffset(selfOffset + rtlSelf.length - 1) > mixedLayout.getLineForOffset(selfOffset))
        assertFalse("Wrapped heading must not truncate", mixedLayout.hasVisualOverflow)
        val action = mixedText.getLinkAnnotations(0, mixedText.length).single()
        assertEquals("rtl-other-entry", (action.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
        assertTrue(neighborOffset in action.start until action.end)
        assertTrue("Self text must not borrow neighbor action", action.end <= selfOffset || action.start >= selfOffset + rtlSelf.length)

        val fold = compose.onNodeWithContentDescription("Expand $rtlLabel")
        fold.assertIsDisplayed().assertHasClickAction()
            .assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role, androidx.compose.ui.semantics.Role.Button))
        val foldNode = fold.fetchSemanticsNode()
        // Semantics/layout bounds and expanded interactive touch bounds are distinct public APIs.
        // Both direct SemanticsNode properties below are pixel Rects in root coordinates.
        val foldBoundsPx: androidx.compose.ui.geometry.Rect = foldNode.boundsInRoot
        val foldTouchBoundsPx: androidx.compose.ui.geometry.Rect = foldNode.touchBoundsInRoot
        val textBoundsPx = mixedNode.fetchSemanticsNode().boundsInRoot
        val density = mixedLayout.layoutInput.density
        val minimumTouchPx = with(density) { 48.dp.toPx() }
        val viewportBoundsPx = compose.onNodeWithTag("self-heading-rtl-viewport").fetchSemanticsNode().boundsInRoot
        val geometry = "visualPx=$foldBoundsPx touchPx=$foldTouchBoundsPx textPx=$textBoundsPx " +
            "viewportPx=$viewportBoundsPx densityPxPerDp=${density.density} fontScale=${density.fontScale} minimumTouchPx=$minimumTouchPx"
        assertEquals("Owned viewport width in px: $geometry", with(density) { 280.dp.toPx() }, viewportBoundsPx.width, 1f)
        assertTrue("Separate fold touch target remains at least 48dp: $geometry", foldTouchBoundsPx.width >= minimumTouchPx - 1f && foldTouchBoundsPx.height >= minimumTouchPx - 1f)
        assertTrue("RTL visual fold stays beside text without overlap: $geometry", foldBoundsPx.right <= textBoundsPx.left + 1f)
        assertTrue("RTL touch target stays beside text without overlap: $geometry", foldTouchBoundsPx.right <= textBoundsPx.left + 1f)
        assertTrue("Visual fold fully inside owned viewport: $geometry", foldBoundsPx.left >= viewportBoundsPx.left - 1f && foldBoundsPx.right <= viewportBoundsPx.right + 1f && foldBoundsPx.top >= viewportBoundsPx.top - 1f && foldBoundsPx.bottom <= viewportBoundsPx.bottom + 1f)
        assertTrue("Touch target fully inside owned viewport: $geometry", foldTouchBoundsPx.left >= viewportBoundsPx.left - 1f && foldTouchBoundsPx.right <= viewportBoundsPx.right + 1f && foldTouchBoundsPx.top >= viewportBoundsPx.top - 1f && foldTouchBoundsPx.bottom <= viewportBoundsPx.bottom + 1f)
        assertTrue("Entire measured heading remains visible: $geometry", textBoundsPx.height + 1f >= mixedLayout.size.height && textBoundsPx.width + 1f >= mixedLayout.size.width)
        assertTrue("Heading fully inside owned viewport: $geometry", textBoundsPx.left >= viewportBoundsPx.left - 1f && textBoundsPx.right <= viewportBoundsPx.right + 1f && textBoundsPx.top >= viewportBoundsPx.top - 1f && textBoundsPx.bottom <= viewportBoundsPx.bottom + 1f)
        compose.onNodeWithText("RTL FOLD BODY").assertDoesNotExist()
        compose.onNodeWithContentDescription("Expand About this entry", useUnmergedTree = true).assertIsDisplayed()
        val genericIcon = compose.onNodeWithContentDescription("Expand About this entry", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val rowIcon = compose.onNodeWithContentDescription("Expand $rtlLabel", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        captureOwnedSelfHeading("self-heading-rtl-2x.png", listOf("generic FoldHeading" to genericIcon, "row heading" to rowIcon))
        mixedNode.performTouchInput { click(mixedLayout.getBoundingBox(selfOffset + 1).center) }
        compose.runOnIdle { assertTrue(forwarded.isEmpty()) }
        compose.onNodeWithContentDescription("Expand $rtlLabel").assertIsDisplayed()
        mixedNode.performTouchInput { click(mixedLayout.getBoundingBox(neighborOffset + 1).center) }
        compose.runOnIdle { assertEquals(listOf("rtl-other-entry"), forwarded); forwarded.clear() }
        compose.onNodeWithContentDescription("Expand $rtlLabel").assertIsDisplayed()
        compose.onNodeWithText("RTL FOLD BODY").assertDoesNotExist()
        fold.performTouchInput { click() }
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("RTL FOLD BODY"))
        compose.onNodeWithText("RTL FOLD BODY").assertIsDisplayed()
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Collapse $rtlLabel"))
        compose.onNodeWithContentDescription("Collapse $rtlLabel").performTouchInput { click() }
        compose.onNodeWithText("RTL FOLD BODY").assertDoesNotExist()
        compose.onAllNodes(mixedMatcher, useUnmergedTree = true).assertCountEquals(1)
        compose.runOnIdle { assertTrue(forwarded.isEmpty()); assertEquals(rtlSpans, rtlEntry.sections.single().blocks.first().spans) }
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasContentDescription("Expand About this entry"))
        compose.onNodeWithContentDescription("Expand About this entry").performClick()
        compose.onNodeWithText("RTL GENERIC FOLD BODY").assertIsDisplayed()
        compose.onNodeWithContentDescription("Collapse About this entry").performClick()
        compose.onNodeWithText("RTL GENERIC FOLD BODY").assertDoesNotExist()
        compose.onNodeWithContentDescription("Expand About this entry").assertIsDisplayed()
    }

    // Read the existing owned frame's painted chevron, not its rotation state.
    // For a physical left-pointing chevron the middle ink is left of both arms.
    private fun paintedLeftChevron(bitmap: android.graphics.Bitmap, icon: androidx.compose.ui.geometry.Rect,
                                   root: androidx.compose.ui.geometry.Rect): Pair<Boolean, String> {
        val left = kotlin.math.floor(icon.left - root.left).toInt()
        val top = kotlin.math.floor(icon.top - root.top).toInt()
        val right = kotlin.math.ceil(icon.right - root.left).toInt()
        val bottom = kotlin.math.ceil(icon.bottom - root.top).toInt()
        check(left >= 0 && top >= 0 && right <= bitmap.width && bottom <= bitmap.height)
        check(right > left && bottom > top && right - left <= 256 && bottom - top <= 256)
        val background = bitmap.getPixel(left, top)
        val ink = ArrayList<Triple<Int, Int, Int>>()
        for (y in top until bottom) for (x in left until right) {
            val color = bitmap.getPixel(x, y)
            val contrast = maxOf(kotlin.math.abs(android.graphics.Color.red(color) - android.graphics.Color.red(background)),
                kotlin.math.abs(android.graphics.Color.green(color) - android.graphics.Color.green(background)),
                kotlin.math.abs(android.graphics.Color.blue(color) - android.graphics.Color.blue(background)))
            if (contrast >= 32) ink.add(Triple(x, y, contrast))
        }
        if (ink.isEmpty()) return false to "no contrasting painted ink in icon=$icon"
        val minY = ink.minOf { it.second }; val maxY = ink.maxOf { it.second }
        val minX = ink.minOf { it.first }; val maxX = ink.maxOf { it.first }
        val height = (maxY - minY + 1).toDouble()
        var middleWeight = 0.0; var middleX = 0.0
        var armWeight = 0.0; var armX = 0.0
        for ((x, y, weight) in ink) {
            val fraction = (y - minY + 0.5) / height
            if (fraction in 0.35..0.65) { middleWeight += weight; middleX += x * weight.toDouble() }
            if (fraction <= 0.25 || fraction >= 0.75) { armWeight += weight; armX += x * weight.toDouble() }
        }
        if (middleWeight == 0.0 || armWeight == 0.0) return false to "insufficient chevron bands icon=$icon ink=${ink.size}"
        val middle = middleX / middleWeight; val arms = armX / armWeight
        val requiredSeparation = (maxX - minX + 1) * 0.1
        return (middle + requiredSeparation < arms) to "icon=$icon ink=${ink.size} middleX=$middle armsX=$arms requiredPx=$requiredSeparation"
    }

    private fun captureOwnedSelfHeading(name: String,
        requiredLeftChevrons: List<Pair<String, androidx.compose.ui.geometry.Rect>> = emptyList()) {
        require(name in setOf("self-heading-default.png", "self-heading-rtl-2x.png"))
        // Only this owned Compose root and asserted public self-heading fixture text; never the
        // system clipboard overlay or the retained original ClipData.
        val paintChecks = mutableListOf<Pair<String, Pair<Boolean, String>>>()
        var requiredCaptureFailure: Throwable? = null
        try {
            val ownedRoot = compose.onRoot()
            val rootBounds = ownedRoot.fetchSemanticsNode().boundsInRoot
            val bitmap = ownedRoot.captureToImage().asAndroidBitmap()
            try {
                requiredLeftChevrons.forEach { (label, icon) -> paintChecks.add(label to paintedLeftChevron(bitmap, icon, rootBounds)) }
                val files = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
                val directory = java.io.File(files, "qa-copy-evidence")
                check(directory.mkdirs() || directory.isDirectory)
                check(directory.canonicalFile.parentFile == files.canonicalFile)
                val target = java.io.File(directory, name)
                check(target.canonicalFile.parentFile == directory.canonicalFile && !target.exists())
                target.outputStream().use { check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
            } finally { bitmap.recycle() }
        } catch (failure: AssertionError) {
            if (paintChecks.size != requiredLeftChevrons.size) requiredCaptureFailure = failure
            android.util.Log.i("OwnedSelfHeadingEvidence", "$name unavailable: ${failure.javaClass.simpleName}")
        } catch (failure: Exception) {
            if (paintChecks.size != requiredLeftChevrons.size) requiredCaptureFailure = failure
            // Evidence availability never replaces functional assertions, and
            // diagnostics do not print a view tree or any clipboard contents.
            android.util.Log.i("OwnedSelfHeadingEvidence", "$name unavailable: ${failure.javaClass.simpleName}")
        }
        // The original optional PNG export failure may remain diagnostic, but
        // required painted direction never passes on a missing bitmap or crop.
        requiredCaptureFailure?.let { throw it }
        assertEquals("Required owned painted chevrons", requiredLeftChevrons.size, paintChecks.size)
        paintChecks.forEach { (label, result) -> assertTrue("$label must visibly point left in collapsed RTL: ${result.second}", result.first) }
    }


}

/** Observes the production Activity after the host carrier imports and selects the owned SR blob. */
@Suppress("DEPRECATION")
class OrdinaryReaderAccessibilityTest {
    @get:Rule val activityRule = PhysicalActivityRule()

    @Test fun importedSerbianEntryExposesVisibleNativeTextThroughPublicAncestry() = observeImportedSerbianEntry(false)

    @Test fun importedSerbianIpaTouchAfterSectionsRevealUsesThePaintedNativeOwner() = observeImportedSerbianEntry(true)

    @Suppress("ClickableViewAccessibility")
    private fun observeImportedSerbianEntry(rootTouchDiagnostic: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = activityRule.activity()
        val automation = instrumentation.uiAutomation
        val captions = listOf("Застава Србије", "Положај Србије у Европи (црвено)")
        val definition = "Матична држава Срба"
        val dictionary = "7f3324c7a04746a248d62edc188a8efd8dad7fc7f1aa59de4090013857dfc00e"
        var phase = "authenticate imported selection"
        var observed = "No public tree read"
        var environment = "No owned environment read"
        var mainWindowFocused = false
        var sectionsWindow = -1
        var primaryTouchFailure: Throwable? = null
        fun ownedWindow(requireFocus: Boolean): Int {
            var id = -1
            instrumentation.runOnMainSync {
                assertPhysicalActivity(activity)
                check(activity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED))
                check(activity.window.decorView.isShown)
                mainWindowFocused = activity.hasWindowFocus()
                if (requireFocus) check(mainWindowFocused) { "Main window is not focused in $phase" }
                val info = activity.window.decorView.createAccessibilityNodeInfo()
                try { id = info.windowId } finally { info.recycle() }
                val manager = activity.getSystemService(android.view.accessibility.AccessibilityManager::class.java)
                environment = ownedLayoutState(activity.window.decorView) +
                    "; accessibilityEnabled=${manager.isEnabled}; touchExploration=${manager.isTouchExplorationEnabled}; " +
                    "uiAutomationServiceFlags=${automation.serviceInfo?.flags}; uiAutomationConnectionFlags=default_request_0_not_readback; " +
                    "composeTestRule=false; composeForceState=not_modified"
            }
            return id
        }
        val touchTrace = java.util.concurrent.CopyOnWriteArrayList<String>()
        val receivedTouch = java.util.concurrent.CopyOnWriteArrayList<Pair<Int, Int>>()
        val receivedTouchIpa = java.util.concurrent.CopyOnWriteArrayList<Boolean>()
        val touchRecorderErrors = java.util.concurrent.CopyOnWriteArrayList<String>()
        val attachedTouchOwners = mutableListOf<NativeFloatTextView>()
        var touchOwner: NativeFloatTextView? = null
        var touchPoint: FloatArray? = null
        var touchText = ""
        var touchExpectedState = ""
        var touchWindow = -1
        var touchSent = false
        val touchPaintCount = java.util.concurrent.atomic.AtomicInteger()
        val touchPaintStates = java.util.concurrent.CopyOnWriteArrayList<List<Int>>()
        var touchViewport = emptyList<Int>()
        var touchHadInputFocus = false
        var recordedFirstPaintChange = false
        var touchPaintObserver: android.view.ViewTreeObserver? = null
        var touchPaintListener: android.view.ViewTreeObserver.OnPreDrawListener? = null
        var touchIpaId = -1
        var beforeTouchHit: WordHit? = null
        var beforeTouchLearning: LearningData? = null
        val geometryField by lazy { NativeFloatTextView::class.java.getDeclaredField("geometry").apply { isAccessible = true } }
        val hitMethod by lazy { NativeFloatTextView::class.java.getDeclaredMethod("hitNode",
            java.lang.Float.TYPE, java.lang.Float.TYPE).apply { isAccessible = true } }
        fun traceDigest(value: String) = java.security.MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
            .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
        fun addTouchTrace(value: String) {
            check(touchTrace.size < 96) { "Production touch trace exceeds 96 observations" }
            check(touchTrace.sumOf { it.toByteArray().size } + value.toByteArray().size <= 64 * 1024) { "Production touch trace exceeds 64 KiB" }
            touchTrace += value.take(8192)
        }
        fun touchGeometry(view: NativeFloatTextView) = geometryField.get(view) as? FloatTextGeometry
        fun touchNode(node: FloatInteractionNode?) = node?.let {
            "id=${it.id},kind=${it.kind},range=${it.start}..${it.end},label=${it.label},bounds=${it.bounds},click=${it.onClick != null}"
        } ?: "none"
        fun describeTouch(view: NativeFloatTextView, event: android.view.MotionEvent? = null): String {
            val origin = IntArray(2).also { view.getLocationOnScreen(it) }
            val current = touchGeometry(view)
            val local = event?.let { floatArrayOf(it.x - view.paddingLeft, it.y - view.paddingTop) }
            val hit = local?.let { hitMethod.invoke(view, it[0], it[1]) as? FloatInteractionNode }
            return "view=${System.identityHashCode(view)},origin=${origin.toList()},size=${view.width}x${view.height}," +
                "padding=${listOf(view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom)}," +
                "scroll=${view.scrollX},${view.scrollY},matrix=${view.matrix.toShortString()}," +
                "focused=${view.hasFocus()},selection=${view.selectionStart}..${view.selectionEnd}," +
                "geometry=${current?.javaClass?.simpleName}:${current?.width}x${current?.height}," +
                "textSha=${current?.text?.toString()?.let(::traceDigest)}," +
                "IPA=${current?.nodes?.filter { it.label?.toString() == "IPA" }?.map(::touchNode)}," +
                "event=${event?.actionMasked},eventTime=${event?.eventTime},downTime=${event?.downTime}," +
                "raw=${event?.rawX},${event?.rawY},local=${event?.x},${event?.y}," +
                "geometryPoint=${local?.toList()},preDispatchHit=${touchNode(hit)}"
        }
        fun nativeTouchOwners(): List<NativeFloatTextView> {
            val queue = java.util.ArrayDeque<android.view.View>()
            val result = mutableListOf<NativeFloatTextView>()
            queue.add(activity.window.decorView)
            var count = 0
            while (!queue.isEmpty()) {
                check(++count <= 1024) { "Production view hierarchy exceeds 1024 views" }
                val view = queue.removeFirst()
                if (view is NativeFloatTextView && view.isShown) result += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) queue.add(view.getChildAt(index))
            }
            return result
        }
        fun recordTouchAncestry(view: NativeFloatTextView) {
            var current: android.view.View? = view
            var depth = 0
            while (current != null) {
                check(depth++ < 32) { "Production view ancestry exceeds 32 levels" }
                val item = current
                val origin = IntArray(2).also { item.getLocationOnScreen(it) }
                addTouchTrace("ancestor[$depth]=${item.javaClass.name}@${System.identityHashCode(item)}," +
                    "origin=${origin.toList()},bounds=${item.left},${item.top},${item.right},${item.bottom}," +
                    "translation=${item.translationX},${item.translationY},scroll=${item.scrollX},${item.scrollY}," +
                    "matrix=${item.matrix.toShortString()},shown=${item.isShown},focused=${item.hasFocus()}")
                current = item.parent as? android.view.View
            }
        }
        // Read the already-owned production state; never create a ViewModel or move the list.
        val readerStateSamples = mutableListOf<Map<String, Any?>>()
        val geometryFactoryField by lazy { NativeFloatTextView::class.java.getDeclaredField("geometryFactory").apply { isAccessible = true } }
        val needsGeometryField by lazy { NativeFloatTextView::class.java.getDeclaredField("needsGeometry").apply { isAccessible = true } }
        val measuredWidthField by lazy { NativeFloatTextView::class.java.getDeclaredField("lastMeasuredWidth").apply { isAccessible = true } }
        fun recordReaderState(label: String) {
            check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
            check(readerStateSamples.size < 6) { "More than six production reader-state samples" }
            val started = android.os.SystemClock.uptimeMillis()
            val candidates = nativeTouchOwners().filter { view -> captions.all { view.logicalText.contains(it) } }
            val owner = touchOwner ?: candidates.singleOrNull()
            val storeOwner = checkNotNull((owner ?: activity.window.decorView).findViewTreeViewModelStoreOwner())
            check(storeOwner === activity.window.decorView.findViewTreeViewModelStoreOwner())
            val store = storeOwner.viewModelStore
            val sessions = store.keys().mapNotNull { key -> (store[key] as? ReaderSession)?.let { key to it } }
            val (sessionKey, session) = sessions.single()
            val selected = checkNotNull(session.selected)
            check(selected.contentDictionary == dictionary && selected.title == "Србија")
            val visits = session.visits
            val reading = checkNotNull(visits.currentId?.let(session.readingStates::get))
            val scroll = reading.scroll
            val layout = scroll.layoutInfo
            val items = layout.visibleItemsInfo
            val folds = checkNotNull(reading.folds).toMap()
            check(items.size <= 32 && folds.size <= 64 && session.readingStates.size <= 32 && visits.retainedIds.size <= 32)
            fun short(value: Any?): String? = value?.toString()?.also { check(it.length <= 512) }
            val current = session.navigationState.current
            val origin = owner?.let { IntArray(2).also(it::getLocationOnScreen).toList() }
            readerStateSamples += linkedMapOf(
                "label" to label, "startedUptime" to started, "preDrawSequence" to touchPaintCount.get(),
                "storeOwnerIdentity" to System.identityHashCode(storeOwner), "sessionKey" to sessionKey,
                "sessionIdentity" to System.identityHashCode(session), "selectedIdentity" to System.identityHashCode(selected),
                "selectedKey" to short(selected.key), "visitId" to visits.currentId, "visitEntryKey" to short(visits.entryKey),
                "retainedIds" to visits.retainedIds.sorted(), "canGoBack" to visits.canGoBack,
                "navigationStateIdentity" to System.identityHashCode(session.navigationState),
                "navigationCurrentId" to current?.id, "navigationCurrentEntryKey" to short(current?.entryKey),
                "controllerIdentity" to System.identityHashCode(session.controllerToken),
                "anchorIdentity" to System.identityHashCode(session.anchorRequest),
                "anchorEntryKey" to short(session.anchorRequest?.entryKey), "anchorTarget" to short(session.anchorRequest?.target),
                "readingStates" to session.readingStates.toSortedMap().map { listOf(it.key, System.identityHashCode(it.value)) },
                "readingIdentity" to System.identityHashCode(reading), "scrollIdentity" to System.identityHashCode(scroll),
                "foldMapIdentity" to System.identityHashCode(reading.folds), "foldKey" to reading.foldKey?.map(::short),
                "folds" to folds.toSortedMap(), "firstVisibleIndex" to scroll.firstVisibleItemIndex,
                "firstVisibleScrollOffset" to scroll.firstVisibleItemScrollOffset, "isScrollInProgress" to scroll.isScrollInProgress,
                "canScrollBackward" to scroll.canScrollBackward, "canScrollForward" to scroll.canScrollForward,
                "layoutIdentity" to System.identityHashCode(layout), "totalItems" to layout.totalItemsCount,
                "viewportStartOffset" to layout.viewportStartOffset, "viewportEndOffset" to layout.viewportEndOffset,
                "viewportSize" to listOf(layout.viewportSize.width, layout.viewportSize.height),
                "visibleItems" to items.map { item -> linkedMapOf("index" to item.index, "key" to short(item.key),
                    "offset" to item.offset, "size" to item.size, "contentType" to short(item.contentType)) },
                "nativeMatches" to candidates.size, "nativeIdentity" to owner?.let(System::identityHashCode), "nativeOrigin" to origin,
                "nativeMeasuredSize" to owner?.let { listOf(it.measuredWidth, it.measuredHeight) },
                "nativeSize" to owner?.let { listOf(it.width, it.height) }, "nativeLayoutRequested" to owner?.isLayoutRequested,
                "nativeGeometryIdentity" to owner?.let { System.identityHashCode(touchGeometry(it)) },
                "nativeFactoryIdentity" to owner?.let { System.identityHashCode(geometryFactoryField.get(it)) },
                "nativeNeedsGeometry" to owner?.let { needsGeometryField.getBoolean(it) },
                "nativeLastMeasuredWidth" to owner?.let { measuredWidthField.getInt(it) },
                "loadingComposeLocal" to "UNOBSERVED: local state; use retained public tree and submitted Window pixels",
                "completedUptime" to android.os.SystemClock.uptimeMillis(),
            )
        }
        fun readerStateDescription(): String {
            val value = "readerStateDiagnostic=true; stateReadOnly=true; noViewModelCreation=true; " +
                "loadingStateDirectlyObserved=false; exactSubmittedFrameIdentity=UNKNOWN\n" +
                org.json.JSONArray(readerStateSamples.map { org.json.JSONObject(it) }).toString()
            check(value.toByteArray().size <= 64 * 1024) { "Reader-state evidence exceeds 64 KiB" }
            return value
        }
        // Holder coordinates at pre-draw are telemetry, not the Compose canvas transform.
        // PixelCopy observes submitted Window buffers; it does not identify every displayed frame.
        class SubmittedFrame(val label: String, val registeredSequence: Int, val registeredAt: Long,
            val holderState: List<Int>) {
            var committedAt = -1L
            var commitSequence = -1
            var requestedAt = -1L
            var requestSequence = -1
            var completedAt = -1L
            var completionSequence = -1
            var result = -1
            var error: String? = null
            var bitmap: android.graphics.Bitmap? = null
            var origin = emptyList<Int>()
            var releaseWhenComplete = false
            val done = java.util.concurrent.CountDownLatch(1)
        }
        val submittedFrames = java.util.concurrent.CopyOnWriteArrayList<SubmittedFrame>()
        val submittedErrors = java.util.concurrent.CopyOnWriteArrayList<String>()
        val submittedHandler = android.os.Handler(android.os.Looper.getMainLooper())
        var submittedClosed = false
        var submittedCommit: Runnable? = null
        var submittedCommitObserver: android.view.ViewTreeObserver? = null
        var submittedCommitDone: java.util.concurrent.CountDownLatch? = null
        var submittedCommitRemoved: Boolean? = null
        var submittedWindowOrigin = emptyList<Int>()
        var submittedWindowSize = emptyList<Int>()
        var submittedWindowToken: android.os.IBinder? = null
        val submittedCrops = linkedMapOf<String, android.graphics.Rect>()
        fun submittedError(failure: Throwable) {
            if (submittedErrors.size < 12) submittedErrors += failure.toString().take(1024)
        }
        fun assertSubmittedWindow() {
            check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
            assertPhysicalActivity(activity)
            check(activity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED))
            val decor = activity.window.decorView
            check(decor.isAttachedToWindow && decor.isShown && decor.isHardwareAccelerated && activity.hasWindowFocus())
            val info = decor.createAccessibilityNodeInfo()
            try { check(info.windowId == touchWindow) } finally { info.recycle() }
            val owner = checkNotNull(touchOwner)
            check(owner.isAttachedToWindow && owner.logicalText.toString() == touchText)
            val origin = IntArray(2).also { decor.getLocationOnScreen(it) }.toList()
            val size = listOf(decor.width, decor.height)
            check(size.all { it in 1..4096 } && size[0].toLong() * size[1] <= 4_608_000L)
            if (submittedWindowSize.isEmpty()) {
                submittedWindowSize = size; submittedWindowOrigin = origin; submittedWindowToken = decor.windowToken
            } else check(size == submittedWindowSize && origin == submittedWindowOrigin && decor.windowToken === submittedWindowToken)
        }
        fun requestSubmittedCopy(frame: SubmittedFrame) {
            try {
                check(!submittedClosed && submittedFrames.size <= 3)
                assertSubmittedWindow()
                check(submittedFrames.none { it !== frame && it.requestedAt >= 0 && it.done.count != 0L })
                frame.origin = submittedWindowOrigin
                val bitmap = android.graphics.Bitmap.createBitmap(submittedWindowSize[0], submittedWindowSize[1],
                    android.graphics.Bitmap.Config.ARGB_8888)
                frame.bitmap = bitmap
                frame.requestedAt = android.os.SystemClock.uptimeMillis()
                frame.requestSequence = touchPaintCount.get()
                // Use a new Rect: the Window overload may adjust it for surface insets.
                android.view.PixelCopy.request(activity.window,
                    android.graphics.Rect(0, 0, bitmap.width, bitmap.height), bitmap, { result ->
                        frame.result = result
                        frame.completedAt = android.os.SystemClock.uptimeMillis()
                        frame.completionSequence = touchPaintCount.get()
                        try {
                            assertSubmittedWindow()
                            check(result == android.view.PixelCopy.SUCCESS) { "PixelCopy ${frame.label} result=$result" }
                        } catch (failure: Throwable) { frame.error = failure.toString(); submittedError(failure) }
                        finally {
                            if (frame.releaseWhenComplete) { frame.bitmap?.recycle(); frame.bitmap = null }
                            frame.done.countDown()
                        }
                    }, submittedHandler)
            } catch (failure: Throwable) {
                frame.error = failure.toString(); submittedError(failure)
                frame.done.countDown()
            }
        }
        fun captureSubmitted(label: String): SubmittedFrame {
            val frame = SubmittedFrame(label, touchPaintCount.get(), android.os.SystemClock.uptimeMillis(), touchViewport)
            instrumentation.runOnMainSync {
                recordReaderState("before-copy:$label")
                check(submittedFrames.size < 3)
                submittedFrames += frame
                requestSubmittedCopy(frame)
            }
            check(frame.done.await(3, java.util.concurrent.TimeUnit.SECONDS)) { "PixelCopy $label completion not joined" }
            check(frame.error == null && frame.result == android.view.PixelCopy.SUCCESS) { "PixelCopy $label: ${frame.error}" }
            return frame
        }
        fun registerFirstShiftCopy(state: List<Int>) {
            check(android.os.Build.VERSION.SDK_INT >= 29)
            check(submittedCommit == null && submittedFrames.size < 3)
            val frame = SubmittedFrame("sr-main-ipa-submitted-first-shift", touchPaintCount.get(),
                android.os.SystemClock.uptimeMillis(), state.toList())
            submittedFrames += frame
            val observer = checkNotNull(touchOwner).viewTreeObserver
            val done = java.util.concurrent.CountDownLatch(1)
            val callback = Runnable {
                try {
                    frame.committedAt = android.os.SystemClock.uptimeMillis()
                    frame.commitSequence = touchPaintCount.get()
                    if (submittedClosed) {
                        frame.error = "Commit arrived after diagnostic cleanup; no copy requested"
                        frame.done.countDown()
                    } else requestSubmittedCopy(frame)
                } catch (failure: Throwable) {
                    frame.error = failure.toString(); submittedError(failure); frame.done.countDown()
                } finally { done.countDown() }
            }
            submittedCommit = callback; submittedCommitObserver = observer; submittedCommitDone = done
            observer.registerFrameCommitCallback(callback)
        }
        fun submittedDescription(frame: SubmittedFrame): String =
            "label=${frame.label}; registered=${frame.registeredAt}/${frame.registeredSequence}; " +
                "commit=${frame.committedAt}/${frame.commitSequence}; request=${frame.requestedAt}/${frame.requestSequence}; " +
                "complete=${frame.completedAt}/${frame.completionSequence}; holder=${frame.holderState}; " +
                "result=${frame.result}; joined=${frame.done.count == 0L}; error=${frame.error}; " +
                "exactSubmittedFrameIdentity=UNKNOWN; noLaterPreDrawObserved=" +
                (frame.committedAt >= 0 && frame.registeredSequence == frame.commitSequence &&
                    frame.commitSequence == frame.requestSequence && frame.requestSequence == frame.completionSequence)
        fun submittedCropDifference(baseline: android.graphics.Bitmap, bitmap: android.graphics.Bitmap,
            crop: android.graphics.Rect): String {
            check(baseline.width == bitmap.width && baseline.height == bitmap.height && !crop.isEmpty)
            val before = IntArray(crop.width()); val after = IntArray(crop.width())
            var different = 0
            val changed = android.graphics.Rect()
            for (y in crop.top until crop.bottom) {
                baseline.getPixels(before, 0, before.size, crop.left, y, before.size, 1)
                bitmap.getPixels(after, 0, after.size, crop.left, y, after.size, 1)
                for (x in before.indices) if (before[x] != after[x]) {
                    different++; changed.union(crop.left + x, y, crop.left + x + 1, y + 1)
                }
            }
            return "rect=$crop; differentPixels=$different; changedBounds=$changed"
        }
        fun finishSubmittedEvidence() {
            // Unregister only work not yet committed; already-submitted copies retain their callbacks.
            instrumentation.runOnMainSync {
                submittedClosed = true
                val observer = submittedCommitObserver; val callback = submittedCommit
                if (observer?.isAlive == true && callback != null && submittedCommitDone?.count != 0L) {
                    submittedCommitRemoved = observer.unregisterFrameCommitCallback(callback)
                    if (submittedCommitRemoved == true) {
                        submittedFrames.firstOrNull { it.label == "sr-main-ipa-submitted-first-shift" }?.let {
                            it.error = "Commit unsubmitted at cleanup; no transient frame captured"; it.done.countDown()
                        }
                        submittedCommitDone?.countDown()
                    }
                }
            }
            try {
                val deadline = android.os.SystemClock.uptimeMillis() + 3000
                fun join(latch: java.util.concurrent.CountDownLatch, label: String) {
                    val remaining = (deadline - android.os.SystemClock.uptimeMillis()).coerceAtLeast(0)
                    if (!latch.await(remaining, java.util.concurrent.TimeUnit.MILLISECONDS))
                        submittedError(AssertionError("$label not joined before cleanup deadline"))
                }
                submittedCommitDone?.let { join(it, "Frame commit callback") }
                submittedFrames.forEach { join(it.done, "PixelCopy ${it.label}") }
                val baseline = submittedFrames.firstOrNull { it.label == "sr-main-ipa-submitted-baseline" &&
                    it.error == null && it.result == android.view.PixelCopy.SUCCESS }?.bitmap
                val summary = "submittedWindowDiagnostic=true; coordinateSpace=owned-window-pixels; " +
                    "windowOrigin=$submittedWindowOrigin; windowSize=$submittedWindowSize; " +
                    "physicalPoint=${touchPoint?.toList()}; oldHolderOracleRetained=true; " +
                    "allFramePixelStability=false; exactSubmittedFrameIdentity=UNKNOWN; " +
                    "postTouchPreDraws=${touchPaintCount.get()}; firstShiftRegistered=${submittedCommit != null}; " +
                    "otherPreDrawsNotSampled=${(touchPaintCount.get() - if (submittedCommit != null) 1 else 0).coerceAtLeast(0)}; " +
                    "commitRemoved=$submittedCommitRemoved; errors=$submittedErrors\n" +
                    submittedFrames.joinToString("\n", transform = ::submittedDescription)
                instrumentation.sendStatus(0, android.os.Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$summary\n${readerStateDescription()}\n")
                })
                for (frame in submittedFrames) {
                    val bitmap = frame.bitmap ?: continue
                    if (frame.done.count != 0L || frame.error != null || frame.result != android.view.PixelCopy.SUCCESS) continue
                    val comparisons = if (baseline == null) "baseline unavailable" else submittedCrops.entries.joinToString("\n") {
                        "${it.key}: ${submittedCropDifference(baseline, bitmap, it.value)}"
                    }
                    val bytes = java.io.ByteArrayOutputStream()
                    val bounded = object : java.io.OutputStream() {
                        override fun write(value: Int) { write(byteArrayOf(value.toByte()), 0, 1) }
                        override fun write(data: ByteArray, offset: Int, length: Int) {
                            check(length <= 256 * 1024 - bytes.size()) { "Submitted PNG exceeds 256 KiB" }
                            bytes.write(data, offset, length)
                        }
                    }
                    check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bounded))
                    val png = bytes.toByteArray()
                    val sha = java.security.MessageDigest.getInstance("SHA-256").digest(png)
                        .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
                    val stream = "\n$summary\n$comparisons\nOWNED_PNG_BEGIN ${frame.label} bytes=${png.size} sha256=$sha " +
                        "width=${bitmap.width} height=${bitmap.height}\n" +
                        android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP) + "\nOWNED_PNG_END ${frame.label}\n"
                    check(stream.toByteArray().size <= 512 * 1024)
                    instrumentation.sendStatus(0, android.os.Bundle().apply {
                        putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, stream)
                    })
                }
                check(submittedErrors.isEmpty()) { "Submitted-frame evidence failed: $submittedErrors" }
            } finally {
                instrumentation.runOnMainSync {
                    submittedFrames.forEach { frame ->
                        frame.releaseWhenComplete = true
                        if (frame.done.count == 0L) { frame.bitmap?.recycle(); frame.bitmap = null }
                    }
                }
            }
        }
        fun prepareProductionTouch(publicBounds: android.graphics.Rect) {
            touchWindow = ownedWindow(true)
            instrumentation.runOnMainSync {
                val owners = nativeTouchOwners()
                check(owners.size in 1..32)
                val owner = owners.single { view -> captions.all { view.logicalText.contains(it) } }
                val geometry = checkNotNull(touchGeometry(owner))
                val ipa = geometry.nodes.single { it.label?.toString() == "IPA" && it.onClick != null }
                val origin = IntArray(2).also { owner.getLocationOnScreen(it) }
                check(!publicBounds.isEmpty)
                val point = floatArrayOf(publicBounds.exactCenterX(), publicBounds.exactCenterY())
                val localX = point[0] - origin[0] - owner.paddingLeft
                val localY = point[1] - origin[1] - owner.paddingTop
                check(ipa.bounds.any { it.contains(localX, localY) }) { "Public IPA point differs from native geometry" }
                check((hitMethod.invoke(owner, localX, localY) as? FloatInteractionNode)?.id == ipa.id)
                val visible = android.graphics.Rect()
                check(owner.getGlobalVisibleRect(visible) && visible.contains(point[0].toInt(), point[1].toInt()))
                assertEquals("No selected text before action", owner.selectionStart, owner.selectionEnd)
                assertFalse("Regression must begin before touch focus", owner.hasFocus())
                touchOwner = owner; touchPoint = point; touchText = owner.logicalText.toString()
                touchIpaId = ipa.id
                touchExpectedState = describeTouch(owner)
                addTouchTrace("chosenPublicBounds=$publicBounds; point=${point.toList()}; ${describeTouch(owner)}")
                recordTouchAncestry(owner)
                touchViewport = origin.toList() + listOf(owner.width, owner.height, owner.scrollX, owner.scrollY)
                touchHadInputFocus = owner.hasFocus()
                check(android.os.Build.VERSION.SDK_INT >= 29) { "Submitted-frame diagnostic requires API29" }
                assertSubmittedWindow()
                val windowRect = android.graphics.Rect(0, 0, submittedWindowSize[0], submittedWindowSize[1])
                fun crop(name: String, screenRect: android.graphics.Rect) {
                    val rect = android.graphics.Rect(screenRect)
                    rect.offset(-submittedWindowOrigin[0], -submittedWindowOrigin[1])
                    check(rect.intersect(windowRect) && !rect.isEmpty)
                    submittedCrops[name] = rect
                }
                crop("painted-IPA-location", publicBounds)
                captions.forEachIndexed { index, caption ->
                    val start = owner.logicalText.toString().indexOf(caption)
                    check(start >= 0)
                    val bounds = android.graphics.RectF()
                    geometry.rectsForRange(start, start + caption.length).forEach(bounds::union)
                    check(!bounds.isEmpty)
                    bounds.offset(origin[0] + owner.paddingLeft.toFloat(), origin[1] + owner.paddingTop.toFloat())
                    crop("caption-$index", android.graphics.Rect().also(bounds::roundOut))
                }
                val observer = owner.viewTreeObserver
                val listener = android.view.ViewTreeObserver.OnPreDrawListener {
                    if (touchSent) try {
                        touchPaintCount.incrementAndGet()
                        val location = IntArray(2).also { owner.getLocationOnScreen(it) }
                        val state = location.toList() + listOf(owner.width, owner.height, owner.scrollX, owner.scrollY)
                        if (touchPaintStates.lastOrNull() != state) {
                            check(touchPaintStates.size < 16) { "More than16 painted viewport changes" }
                            touchPaintStates += state
                            addTouchTrace("paintedViewport=$state; frame=${touchPaintCount.get()}")
                            if (state != touchViewport && !recordedFirstPaintChange) {
                                recordedFirstPaintChange = true
                                registerFirstShiftCopy(state)
                                recordReaderState("first-shift-pre-draw")
                                val focused = android.graphics.Rect().also(owner::getFocusedRect)
                                addTouchTrace("firstChangedPaintFocusedRect=$focused; inputFocus=${owner.hasFocus()}")
                                recordTouchAncestry(owner)
                            }
                        }
                    } catch (failure: Throwable) {
                        if (touchRecorderErrors.size < 16) touchRecorderErrors += failure.toString()
                    }
                    true // Preserve holder telemetry; actual submitted pixels are measured separately.
                }
                touchPaintObserver = observer; touchPaintListener = listener
                observer.addOnPreDrawListener(listener)
                owners.forEach { view ->
                    attachedTouchOwners += view
                    view.setOnTouchListener { _, event ->
                        if (event.actionMasked in setOf(android.view.MotionEvent.ACTION_DOWN,
                                android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL)) {
                            receivedTouch += System.identityHashCode(view) to event.actionMasked
                            try {
                                val hit = hitMethod.invoke(view, event.x - view.paddingLeft,
                                    event.y - view.paddingTop) as? FloatInteractionNode
                                receivedTouchIpa += view === touchOwner && hit?.id == touchIpaId &&
                                    hit?.label?.toString() == "IPA" && hit?.onClick != null
                                addTouchTrace("received=${describeTouch(view, event)}")
                            }
                            catch (failure: Throwable) { touchRecorderErrors += failure.toString() }
                        }
                        false // Observation only; the production hierarchy and native handler retain dispatch.
                    }
                }
            }
            runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                beforeTouchHit = checkNotNull(LibraryStore.get(activity).lastWord())
                beforeTouchLearning = LearningStore.get(activity).data
            }
        }
        fun dispatchProductionTouch() {
            check(!touchSent && ownedWindow(true) == touchWindow)
            val root = checkNotNull(automation.rootInActiveWindow)
            try { check(root.packageName?.toString() == activity.packageName && root.windowId == touchWindow) }
            finally { root.recycle() }
            instrumentation.runOnMainSync {
                val owner = checkNotNull(touchOwner); val point = checkNotNull(touchPoint)
                check(owner in nativeTouchOwners() && owner.logicalText.toString() == touchText)
                check(describeTouch(owner) == touchExpectedState) { "Native owner state changed after the before frame" }
                assertEquals(owner.selectionStart, owner.selectionEnd)
                val origin = IntArray(2).also { owner.getLocationOnScreen(it) }
                val hit = hitMethod.invoke(owner, point[0] - origin[0] - owner.paddingLeft,
                    point[1] - origin[1] - owner.paddingTop) as? FloatInteractionNode
                check(hit?.label?.toString() == "IPA" && hit.onClick != null) { "IPA point changed before root dispatch" }
                addTouchTrace("before root dispatch: ${describeTouch(owner)}")
                recordReaderState("before-root-dispatch")
            }
            val point = checkNotNull(touchPoint)
            val down = android.os.SystemClock.uptimeMillis()
            touchSent = true
            for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
                val event = android.view.MotionEvent.obtain(down, down, action, point[0], point[1], 0)
                event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
                try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
            }
            instrumentation.runOnMainSync { recordReaderState("after-root-event-pair") }
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                attachedTouchOwners.forEach { addTouchTrace("after=${describeTouch(it)}") }
                touchOwner?.let(::recordTouchAncestry)
            }
        }
        data class Tree(val nodes: List<android.view.accessibility.AccessibilityNodeInfo>, val parents: List<Int>) : java.io.Closeable {
            override fun close() { nodes.forEach { it.recycle() } }
            fun actionFor(index: Int): android.view.accessibility.AccessibilityNodeInfo {
                val label = nodes[index]
                val action = if (label.isClickable) label else nodes[parents[index].also { check(it >= 0) }]
                check(action.isClickable && action.isVisibleToUser)
                val labelBounds = android.graphics.Rect().also(label::getBoundsInScreen)
                val actionBounds = android.graphics.Rect().also(action::getBoundsInScreen)
                check(actionBounds.contains(labelBounds))
                return action
            }
        }
        fun tree(menu: Boolean = false): Tree? {
            val window = ownedWindow(false)
            val root = automation.rootInActiveWindow ?: return null
            observed = "phase=$phase; mainWindow=$window; mainFocused=$mainWindowFocused; " +
                "activeWindow=${root.windowId}; activePackage=${root.packageName}; menu=$menu"
            val nodes = mutableListOf(root)
            val parents = mutableListOf(-1)
            try {
                check(root.packageName?.toString() == activity.packageName) { "Foreign active root: $observed" }
                val activeWindow = root.windowId
                // A section heading in the underlying entry is not a popup menu item.
                if (menu && activeWindow == window) { root.recycle(); return null }
                if (!menu && activeWindow != window) {
                    check(activeWindow == sectionsWindow) { "Unexpected owned window: $observed" }
                    root.recycle(); return null
                }
                if (!menu && !mainWindowFocused) { root.recycle(); return null }
                check(root.isVisibleToUser) { "Active owned root is not visible: $observed" }
                var next = 0
                while (next < nodes.size) {
                    check(nodes.size <= 1024) { "Owned reader tree exceeds 1024 nodes" }
                    val index = next++
                    val node = nodes[index]
                    check(node.packageName?.toString() == activity.packageName && node.windowId == activeWindow)
                    // Structural holders can be invisible while their native descendants are visible.
                    // Visibility is required on the actual text/action, not used to prune traversal.
                    for (child in 0 until node.childCount) node.getChild(child)?.let {
                        nodes += it; parents += index
                    }
                }
                observed = "phase=$phase; mainWindow=$window; mainFocused=$mainWindowFocused; " +
                    "activeWindow=$activeWindow; menu=$menu; nodeCount=${nodes.size}; " +
                    "captions=${captions.map { caption -> nodes.any { it.isVisibleToUser && it.text?.contains(caption) == true } }}\n" +
                    nodes.mapIndexed { index, node ->
                        val bounds = android.graphics.Rect().also(node::getBoundsInScreen)
                        "[$index parent=${parents[index]}] ${node.className} visible=${node.isVisibleToUser} " +
                            "bounds=$bounds; ${node.text?.take(180)} / ${node.contentDescription?.take(180)}"
                    }.joinToString("\n").take(24000)
                return Tree(nodes, parents)
            } catch (failure: Throwable) { nodes.forEach { it.recycle() }; throw failure }
        }
        fun isSectionsMenu(current: Tree): Boolean =
            listOf("Именица", "Преводи").all { title ->
                current.nodes.count { it.isVisibleToUser && it.text?.toString() == title } == 1
            } && current.nodes.none {
                it.contentDescription?.toString() in setOf("Sections", "Dictionary", "Expand Именица")
            }
        fun await(label: String, menu: Boolean = false, ready: (Tree) -> Boolean): Tree {
            phase = label
            val deadline = android.os.SystemClock.uptimeMillis() + 15000
            do {
                val current = tree(menu)
                if (current != null) {
                    try {
                        if (ready(current)) {
                            if (menu) {
                                check(isSectionsMenu(current)) { "Owned popup is not the Sections menu: $observed" }
                                sectionsWindow = current.nodes.first().windowId
                            }
                            return current
                        }
                    } catch (failure: Throwable) { current.close(); throw failure }
                    current.close()
                }
                if (android.os.SystemClock.uptimeMillis() < deadline) android.os.SystemClock.sleep(50)
            } while (android.os.SystemClock.uptimeMillis() < deadline)
            throw AssertionError("Timed out awaiting $label\n$observed")
        }
        fun click(node: android.view.accessibility.AccessibilityNodeInfo) {
            val main = ownedWindow(false)
            val expectedWindow = node.windowId
            check(expectedWindow == main || expectedWindow == sectionsWindow) {
                "Action window ${node.windowId} is neither Main $main nor Sections $sectionsWindow"
            }
            if (expectedWindow == main) ownedWindow(true)
            val root = checkNotNull(automation.rootInActiveWindow) { "No active root before action in $phase" }
            try {
                check(root.packageName?.toString() == activity.packageName && root.windowId == expectedWindow) {
                    "Action root changed in $phase: expected window=${node.windowId} package=${activity.packageName}; " +
                        "actual window=${root.windowId} package=${root.packageName}; main=$main sections=$sectionsWindow"
                }
            } finally { root.recycle() }
            check(node.refresh() && node.windowId == expectedWindow &&
                node.packageName?.toString() == activity.packageName &&
                node.isVisibleToUser && node.isEnabled && node.isClickable)
            check(node.actionList.any { it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK })
            assertTrue(node.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
        }
        fun report(imageName: String) {
            val main = ownedWindow(false)
            val active = checkNotNull(automation.rootInActiveWindow) { "No active root before capture" }
            val before = try {
                check(active.packageName?.toString() == activity.packageName) { "Foreign root before capture" }
                active.windowId
            } finally { active.recycle() }
            val menu = before != main
            if (menu) check(before == sectionsWindow) { "Unrecognized popup $before before capture; Sections=$sectionsWindow" }
            fun verifyCaptureWindow() {
                tree(menu)?.use {
                    check(it.nodes.first().windowId == before) { "Owned capture window changed" }
                    if (menu) check(isSectionsMenu(it)) { "Sections content changed before capture" }
                } ?: error("Owned public root unavailable during capture: $observed")
            }
            verifyCaptureWindow()
            val bitmap = checkNotNull(automation.takeScreenshot()) { "Owned physical screenshot unavailable" }
            try {
                verifyCaptureWindow()
                check(bitmap.width in 1..4096 && bitmap.height in 1..4096)
                val bytes = java.io.ByteArrayOutputStream()
                var encoded = 0
                var encodingFailure: java.io.IOException? = null
                val bounded = object : java.io.OutputStream() {
                    override fun write(value: Int) { write(byteArrayOf(value.toByte()), 0, 1) }
                    override fun write(data: ByteArray, offset: Int, length: Int) {
                        if (length > 256 * 1024 - encoded) {
                            val failure = java.io.IOException("Owned ordinary-reader PNG exceeds 256 KiB")
                            encodingFailure = failure
                            throw failure
                        }
                        bytes.write(data, offset, length); encoded += length
                    }
                }
                val compressed = bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bounded)
                encodingFailure?.let { throw it }
                check(compressed && encoded > 0)
                val png = bytes.toByteArray()
                val sha = java.security.MessageDigest.getInstance("SHA-256").digest(png)
                    .joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
                val diagnostic = if (rootTouchDiagnostic) "productionMainTouchDiagnostic=true; ordinary111Acceptance=false; " +
                    "coordinateSpace=physical-display0-screen; pointChosenFromPublicIpaBounds=true; " +
                    "point=${touchPoint?.toList()}; sent=$touchSent; recorderErrors=$touchRecorderErrors; paintedFrames=${touchPaintCount.get()}; paintedViewports=$touchPaintStates\n" +
                    touchTrace.joinToString("\n") else ""
                val stream = "\n$environment\n$observed\n$diagnostic\nOWNED_PNG_BEGIN $imageName bytes=${png.size} sha256=$sha " +
                    "width=${bitmap.width} height=${bitmap.height}\n" +
                    android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP) + "\nOWNED_PNG_END $imageName\n"
                check(stream.toByteArray(Charsets.UTF_8).size <= (if (rootTouchDiagnostic) 512 else 384) * 1024)
                instrumentation.sendStatus(0, android.os.Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, stream)
                })
            } finally { bitmap.recycle() }
        }
        try {
            // No catalogue refresh, fixture installation, settings change or alternate composition.
            val file = java.io.File(activity.filesDir, "dictionaries/$dictionary.wikblb")
            assertEquals(118615L, file.length())
            val digest = file.inputStream().use { input ->
                val hash = java.security.MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(8192)
                while (true) { val count = input.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
                hash.digest().joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
            }
            assertEquals(dictionary, digest)
            runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                val library = LibraryStore.get(activity)
                val hit = checkNotNull(library.lastWord())
                assertEquals(dictionary, hit.dictionary)
                assertEquals("Србија", hit.title); assertEquals("Српски", hit.language)
                val entry = library.read(hit)
                assertEquals("sr", entry.languageCode)
                assertEquals(dictionary, entry.contentDictionary)
                if (rootTouchDiagnostic) {
                    val ipaSource = entry.sections[2].blocks[3].spans.first()
                    assertEquals("IPA", ipaSource.text); assertEquals("Помоћ:МФА", ipaSource.target)
                }
                val settings = LearningStore.get(activity).data.settings
                assertFalse(settings.allowImages); assertFalse(settings.allowAudio)
                if (rootTouchDiagnostic) {
                    assertTrue("Retained111 folding precondition", settings.collapsePronunciation && settings.collapseEtymology &&
                        settings.collapseOtherSections && settings.collapseDetails)
                    addTouchTrace("persistedSettings=$settings; sourceIPA=Помоћ:МФА; " +
                        "productionMain=true; setContent=false; foldOverride=false")
                }
            }
            await("normal Main SR entry") { current ->
                current.nodes.count { it.isVisibleToUser && it.contentDescription?.toString() == "Sections" } == 1 &&
                    current.nodes.any { it.isVisibleToUser && it.text?.toString() == "Србија" }
            }.use { current -> click(current.actionFor(current.nodes.indexOfFirst {
                it.isVisibleToUser && it.contentDescription?.toString() == "Sections"
            })) }
            await("owned Sections menu", menu = true, ready = ::isSectionsMenu).use { current ->
                val index = current.nodes.indexOfFirst { it.isVisibleToUser && it.text?.toString() == "Именица" }
                click(current.actionFor(index))
            }
            if (rootTouchDiagnostic) instrumentation.runOnMainSync { recordReaderState("after-sections-click") }
            await("visible ordinary SR captions and native body") { current ->
                current.nodes.none { it.text?.contains("Unable to display this layout.") == true } &&
                    current.nodes.any { it.isVisibleToUser && it.contentDescription?.toString() == "Collapse Именица" } &&
                    captions.all { caption -> current.nodes.any { it.isVisibleToUser && it.text?.contains(caption) == true } } &&
                    current.nodes.any { it.isVisibleToUser && it.text?.toString() == "IPA" && it.isClickable } &&
                    current.nodes.any { it.isVisibleToUser && it.text?.contains(definition) == true } &&
                    current.nodes.any { it.isVisibleToUser && it.contentDescription?.toString() == "Play pronunciation" }
            }.use { current ->
                val owner = current.nodes.single { node -> captions.all { node.text?.contains(it) == true } }
                val text = owner.text.toString()
                captions.forEach { assertEquals(1, Regex(Regex.escape(it)).findAll(text).count()) }
                assertTrue(text.indexOf(captions[0]) < text.indexOf(captions[1]))
                assertTrue(text.indexOf(captions[1]) < text.indexOf("IPA:"))
                assertTrue(text.indexOf("IPA:") < text.indexOf(definition))
                assertFalse(text.contains("Images disabled"))
                assertTrue(owner.availableExtraData.contains(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY))
                val viewport = android.graphics.Rect().also(current.nodes.first()::getBoundsInScreen)
                for (caption in captions) {
                    val args = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX, text.indexOf(caption))
                        putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH, 3)
                    }
                    assertTrue(owner.refreshWithExtraData(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY, args))
                    val rectangles = owner.extras.getParcelableArray(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY)
                    assertEquals(3, rectangles?.size)
                    assertTrue(rectangles!!.all { it is android.graphics.RectF && !it.isEmpty &&
                        android.graphics.RectF.intersects(it, android.graphics.RectF(viewport)) })
                }
                val ipa = current.nodes.single { it.isVisibleToUser && it.text?.toString() == "IPA" && it.isClickable }
                assertTrue(ipa.actionList.any { it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK })
                val playerIndex = current.nodes.indices.single {
                    current.nodes[it].isVisibleToUser && current.nodes[it].contentDescription?.toString() == "Play pronunciation"
                }
                val player = current.actionFor(playerIndex)
                assertFalse(player.isEnabled)
                assertTrue(owner.actionList.any { it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION })
                if (rootTouchDiagnostic) {
                    val ipaBounds = android.graphics.Rect().also(ipa::getBoundsInScreen)
                    prepareProductionTouch(ipaBounds)
                    captureSubmitted("sr-main-ipa-submitted-baseline")
                    report("sr-main-ipa-before")
                } else report("sr-ordinary-public-entry")
            }
            if (rootTouchDiagnostic) {
                phase = "one production Main IPA root tap after Sections reveal"
                dispatchProductionTouch()
                // Capture the immediate result and receiver state even if lookup feedback never arrives.
                report("sr-main-ipa-immediate")
                await("actual local missing-target feedback") { current ->
                    current.nodes.any { it.isVisibleToUser && it.text?.toString() == "This word is not in your installed dictionaries." }
                }.use { report("sr-main-ipa-result") }
                try { captureSubmitted("sr-main-ipa-submitted-settled") }
                catch (failure: Throwable) { submittedError(failure) }
                assertTrue("Touch recorder must complete", touchRecorderErrors.isEmpty())
                val ownerId = System.identityHashCode(checkNotNull(touchOwner))
                assertEquals(listOf(ownerId to android.view.MotionEvent.ACTION_DOWN,
                    ownerId to android.view.MotionEvent.ACTION_UP), receivedTouch.toList())
                assertEquals("Both received events retain the source-bound IPA hit", listOf(true, true), receivedTouchIpa.toList())
                instrumentation.runOnMainSync {
                    val owner = checkNotNull(touchOwner)
                    assertEquals(touchText, owner.logicalText.toString())
                    assertEquals("Link activation preserves input focus", touchHadInputFocus, owner.hasFocus())
                    assertEquals("No selection after internal-link action", owner.selectionStart, owner.selectionEnd)
                    val location = IntArray(2).also { owner.getLocationOnScreen(it) }
                    assertEquals("Post-action viewport remains at the revealed content", touchViewport,
                        location.toList() + listOf(owner.width, owner.height, owner.scrollX, owner.scrollY))
                    assertTrue("At least one real post-touch frame was observed", touchPaintCount.get() > 0)
                    assertTrue("No painted focus jump", touchPaintStates.isNotEmpty() && touchPaintStates.all { it == touchViewport })
                    assertNull(MediaPlayback.playing)
                }
                runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                    assertEquals(beforeTouchHit, LibraryStore.get(activity).lastWord())
                    assertEquals(beforeTouchLearning, LearningStore.get(activity).data)
                }
            }
        } catch (failure: Throwable) {
            primaryTouchFailure = failure
            try { report(if (rootTouchDiagnostic) "sr-main-ipa-failure" else "sr-ordinary-public-entry-failure") }
            catch (evidenceFailure: Throwable) {
                failure.addSuppressed(evidenceFailure)
                try {
                    instrumentation.sendStatus(0, android.os.Bundle().apply {
                        putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT,
                            run {
                                val fallback = "\n$environment\n$observed\n" +
                                    (if (rootTouchDiagnostic) "point=${touchPoint?.toList()}; sent=$touchSent; recorderErrors=$touchRecorderErrors\n${touchTrace.joinToString("\n")}\n" else "") +
                                    "OWNED_PNG_UNAVAILABLE phase=$phase ${evidenceFailure.javaClass.name}: ${evidenceFailure.message}\n"
                                check(fallback.toByteArray().size <= 128 * 1024)
                                fallback
                            })
                    })
                } catch (statusFailure: Throwable) { failure.addSuppressed(statusFailure) }
            }
            throw failure
        } finally {
            if (rootTouchDiagnostic) try {
                instrumentation.runOnMainSync {
                    attachedTouchOwners.forEach { it.setOnTouchListener(null) }
                    val observer = touchPaintObserver; val listener = touchPaintListener
                    if (observer?.isAlive == true && listener != null) observer.removeOnPreDrawListener(listener)
                }
            } catch (cleanup: Throwable) {
                if (primaryTouchFailure != null) primaryTouchFailure.addSuppressed(cleanup) else primaryTouchFailure = cleanup
            }
            if (rootTouchDiagnostic) try { finishSubmittedEvidence() }
            catch (cleanup: Throwable) {
                if (primaryTouchFailure != null) primaryTouchFailure.addSuppressed(cleanup) else throw cleanup
            }
            // If observer removal itself failed on an otherwise successful test, retain that failure.
            primaryTouchFailure?.let { throw it }
        }
    }
}
