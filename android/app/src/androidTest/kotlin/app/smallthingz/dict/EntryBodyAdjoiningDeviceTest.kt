package app.smallthingz.dict

import android.graphics.RectF
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic compiled entries exercise the real lazy body cut; these are not source certificates. */
@RunWith(AndroidJUnit4::class)
class EntryBodyAdjoiningDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun margins(top: Float = 0f, bottom: Float = 0f) = StyleEdges(px(top), px(0f), px(bottom), px(0f))
    private fun paragraph(label: String, top: Float = 0f, bottom: Float = 0f) =
        Block("paragraph", 0, listOf(Span("link", label, label)), style = BlockStyle(margins = margins(top, bottom)))
    private fun floating(label: String = "float") = Block("container", 0, emptyList(), container = Container(
        listOf(paragraph(label)), ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 64f)),
            height = px(40f), margins = margins(), floatSide = TableFloatSide.Left,
            background = ContainerColor.Rgb("#cc0000"))))
    private fun ordinary() = Block("container", 0, emptyList(), container = Container(
        listOf(paragraph("body")), ContainerStyle(height = px(10f), margins = margins(20f, 30f),
            background = ContainerColor.Rgb("#00aa00"))))
    private fun entry(blocks: List<Block>, policy: BodyAdjoiningPolicy? = BodyAdjoiningPolicy.Ordinary,
        heading: String = "", metadata: Boolean = false) = Entry("Body cut control", emptyList(), "language", "English", "en",
        listOf(Section(3, heading, blocks, anchor = if (heading.isEmpty()) "" else "usage")),
        if (metadata) listOf(Reference(1, 1, "", listOf(Span("link", "reference", "reference")))) else emptyList(),
        preamble = if (metadata) listOf(Span("link", "preamble", "preamble")) else emptyList(), bodyAdjoining = policy)

    @Composable private fun Theme(content: @Composable () -> Unit) {
        MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge =
            MaterialTheme.typography.bodyLarge.copy(fontSize = 12.sp, lineHeight = 20.sp,
                fontFamily = FontFamily.Monospace, letterSpacing = 0.sp))) {
            CompositionLocalProvider(LocalDensity provides Density(1f, 1f), content = content)
        }
    }
    private val settings = AppSettings(allowImages = false, allowAudio = false,
        collapseOtherSections = false, collapseDetails = false)

    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun collect(view: View) {
                if (view is NativeFloatTextView) result += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) collect(view.getChildAt(index))
            }
            collect(activity.window.decorView)
        }
        return result
    }
    private fun owner(vararg labels: String): NativeFloatTextView = views().single { view ->
        val geometry = view.currentMeasuredGeometry
        geometry != null && labels.all { label -> geometry.nodes.any { it.kind == FloatInteractionKind.LINK && it.label == label } }
    }
    private fun sourceGeometry(view: NativeFloatTextView): FloatTextGeometry =
        (checkNotNull(view.currentMeasuredGeometry) as NativeSurfaceGeometry).content
    private fun sourceBounds(view: NativeFloatTextView, label: String): RectF = RectF(
        sourceGeometry(view).nodes.single { it.kind == FloatInteractionKind.LINK && it.label == label }.bounds.single())
    private fun tap(view: NativeFloatTextView, label: String) {
        compose.runOnIdle {
            val geometry = checkNotNull(view.currentMeasuredGeometry)
            val node = geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label == label }
            val rect = node.bounds.single()
            assertEquals(node.id, geometry.interactionNodeAt(rect.centerX(), rect.centerY())?.id)
            val now = SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, rect.centerX(), rect.centerY(), 0)
            val up = MotionEvent.obtain(now, now + 1, MotionEvent.ACTION_UP, rect.centerX(), rect.centerY(), 0)
            try { view.dispatchTouchEvent(down); view.dispatchTouchEvent(up) }
            finally { down.recycle(); up.recycle() }
        }
        compose.waitForIdle()
    }
    private fun tapRetained(label: String) {
        val candidates = views().filter { view -> view.currentMeasuredGeometry?.nodes?.any {
            it.kind == FloatInteractionKind.LINK && it.label == label
        } == true }
        if (candidates.isNotEmpty()) tap(candidates.single(), label)
        else {
            val node = compose.onNodeWithText(label, useUnmergedTree = true).assertIsDisplayed()
            val layouts = mutableListOf<TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            node.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
            compose.waitForIdle()
        }
    }
    private fun control(name: String, body: () -> Unit) {
        try { body() }
        catch (failure: Throwable) {
            runCatching {
                val node = compose.onNodeWithTag("body-cut-root")
                val bitmap = node.captureToImage().asAndroidBitmap()
                val report = renderedLayoutFailureEvidence(name, null, null, node, name, bitmap)
                InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
            }
            throw failure
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun actualEntryAbsorbsFirstInFlowMarginWithoutTranslatingInitialFloatAndRestoresNull() =
        control("entry-body-initial-float.png") {
            val ordinaryMode = mutableStateOf(false)
            val actions = mutableListOf<EntryLink>()
            val reading = EntryReadingState()
            val source = listOf(floating(), ordinary())
            var rootWindow = androidx.compose.ui.geometry.Rect.Zero
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                Box(Modifier.size(320.dp, 480.dp).background(Color.White).testTag("body-cut-root")
                    .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                    EntryView(entry(source, if (ordinaryMode.value) BodyAdjoiningPolicy.Ordinary else null), false, {},
                        onLink = { actions += it }, settings = settings, readingState = reading)
                }
            } } }
            compose.waitForIdle()
            fun assertPaint(view: NativeFloatTextView, ordinaryTop: Float) {
                var sourceX = 0f
                var sourceY = 0f
                compose.runOnIdle {
                    val surface = checkNotNull(view.currentMeasuredGeometry) as NativeSurfaceGeometry
                    val window = IntArray(2).also(view::getLocationInWindow)
                    sourceX = window[0] - rootWindow.left - surface.surface.left
                    sourceY = window[1] - rootWindow.top - surface.surface.top
                }
                val pixels = compose.onNodeWithTag("body-cut-root").captureToImage().toPixelMap()
                fun pixel(x: Float, y: Float) = pixels[(sourceX + x).toInt(), (sourceY + y).toInt()]
                val floatingPaint = pixel(16f, 32f)
                assertTrue(floatingPaint.red > .7f && floatingPaint.green < .1f && floatingPaint.blue < .1f)
                val ordinaryPaint = pixel(180f, ordinaryTop + 5f)
                assertTrue(ordinaryPaint.green > .6f && ordinaryPaint.red < .1f && ordinaryPaint.blue < .1f)
                val outside = pixel(180f, if (ordinaryTop == 0f) 25f else 5f)
                assertFalse(outside.green > .6f && outside.red < .1f && outside.blue < .1f)
            }
            val old = owner("float", "body")
            val oldFloat = sourceBounds(old, "float")
            val oldBody = sourceBounds(old, "body")
            val oldText = old.logicalText.toString()
            val sourceEntry = entry(source)
            val bodyIndex = entryReadingStartIndex(sourceEntry, emptySet()) +
                visibleEntryReadingRows(sourceEntry, emptySet()).indexOfFirst { it.block != null }
            var oldHeight = 0
            compose.runOnIdle { oldHeight = reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == bodyIndex }.size }
            assertPaint(old, 20f)
            compose.runOnIdle { ordinaryMode.value = true }
            compose.waitForIdle()
            val owned = owner("float", "body")
            compose.runOnIdle {
                assertEquals(oldFloat, sourceBounds(owned, "float"))
                assertEquals(oldBody.top - 20f, sourceBounds(owned, "body").top, .01f)
                assertEquals(oldBody.bottom - 20f, sourceBounds(owned, "body").bottom, .01f)
                assertEquals(oldText, owned.logicalText.toString())
                assertEquals("float\nbody", owned.logicalText.toString())
                // Used flow contains the fixed 40px float; independently measured glyph overflow
                // may enlarge the reachable document surface and is not a box-height oracle.
                assertEquals(40f, sourceGeometry(owned).extents.usedHeight, 0f)
                assertTrue(reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == bodyIndex }.size >= 40)
                owned.setSelection(0, owned.logicalText.length)
                assertEquals("float\nbody", owned.selectedTextForCopy())
                val host = owned.createAccessibilityNodeInfo()
                assertEquals("float\nbody", host.text.toString())
                assertEquals(2, checkNotNull(owned.currentMeasuredGeometry).nodes.count { it.kind == FloatInteractionKind.LINK })
            }
            assertPaint(owned, 0f)
            tap(owned, "float"); tap(owned, "body")
            assertEquals(listOf("float", "body"), actions.map { it.target })
            compose.runOnIdle { ordinaryMode.value = false }
            compose.waitForIdle()
            val restored = owner("float", "body")
            compose.runOnIdle {
                assertEquals(oldText, restored.logicalText.toString())
                assertEquals(oldFloat, sourceBounds(restored, "float"))
                assertEquals(oldBody, sourceBounds(restored, "body"))
                assertEquals(oldHeight, reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == bodyIndex }.size)
            }
            assertPaint(restored, 20f)
        }

    @Test fun wholeBodyIncludesPrefixAndEndsBeforeMetadataWhileEmptyThroughAndFloatOnlyAddNoText() =
        control("entry-body-cut-and-empty.png") {
            val mode = mutableStateOf(0)
            val actions = mutableListOf<EntryLink>()
            val reading = EntryReadingState()
            val prefix = paragraph("prefix")
            val suffix = paragraph("suffix")
            val through = Block("paragraph", 0, emptyList(), style = BlockStyle(margins = margins(20f, 30f)))
            fun selected() = entry(when (mode.value) {
                0, 1 -> listOf(prefix, floating(), suffix)
                2 -> listOf(through)
                3 -> listOf(floating())
                else -> emptyList()
            }, if (mode.value == 0) null else BodyAdjoiningPolicy.Ordinary, metadata = true)
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                Box(Modifier.size(320.dp, 560.dp).testTag("body-cut-root")) {
                    EntryView(selected(), false, {}, onLink = { actions += it }, settings = settings, readingState = reading)
                }
            } } }
            compose.waitForIdle()
            assertFalse(owner("float", "suffix").logicalText.toString().contains("prefix"))
            tapRetained("prefix")
            compose.runOnIdle { mode.value = 1 }
            compose.waitForIdle()
            val owned = owner("prefix", "float", "suffix")
            compose.runOnIdle {
                assertEquals("prefix\nfloat\nsuffix", owned.logicalText.toString())
                assertFalse(owned.logicalText.toString().contains("preamble"))
                assertFalse(owned.logicalText.toString().contains("reference"))
                assertEquals(3, checkNotNull(owned.currentMeasuredGeometry).nodes.count { it.kind == FloatInteractionKind.LINK })
                owned.setSelection(0, owned.logicalText.length)
                assertEquals("prefix\nfloat\nsuffix", owned.selectedTextForCopy())
                val labels = checkNotNull(owned.currentMeasuredGeometry).nodes.map { it.label?.toString() }
                assertFalse(labels.contains("About this entry")); assertFalse(labels.contains("References"))
            }
            tap(owned, "prefix"); tap(owned, "suffix")
            compose.onNodeWithText("preamble", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithText("reference", useUnmergedTree = true).assertIsDisplayed()
            for (state in listOf(2, 3, 4)) {
                compose.runOnIdle { mode.value = state }
                compose.waitForIdle()
                val current = selected()
                val rows = visibleEntryReadingRows(current, emptySet())
                val index = entryReadingStartIndex(current, emptySet()) + rows.indexOfFirst { it.block != null }.coerceAtLeast(0)
                compose.runOnIdle {
                    val allocated = reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == index }.size
                    if (state == 3) assertTrue(allocated >= 40) else assertEquals(0, allocated)
                    assertEquals(entryReadingStartIndex(current, emptySet()) + rows.size,
                        metadataReferencesStartIndex(current, emptySet()))
                }
                if (state == 3) {
                    val only = owner("float")
                    assertEquals("float", only.logicalText.toString())
                    assertEquals(40f, sourceGeometry(only).extents.usedHeight, 0f)
                    tap(only, "float")
                } else compose.runOnIdle {
                    assertTrue(views().all { it.currentMeasuredGeometry?.nodes.orEmpty().none { node ->
                        node.label == "prefix" || node.label == "suffix" || node.label == "float"
                    } })
                }
                compose.onNodeWithText("reference", useUnmergedTree = true).assertIsDisplayed()
            }
            assertEquals(listOf("prefix", "prefix", "suffix", "float"), actions.map { it.target })
        }

    @Test fun firstHeadingKeepsFoldAnchorAndListActionsWithReaderSpacing() =
        control("entry-body-heading-recovery.png") {
            val supported = mutableStateOf(false)
            val request = mutableStateOf<EntryAnchorRequest?>(null)
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val list = paragraph("list-action").copy(kind = "list_item", depth = 1, listPath = "*")
            fun selected() = entry(listOf(list), heading = if (supported.value) "" else "Usage")
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                CompositionLocalProvider(LocalNativeFloatContextFailureObserver provides { failures += it }) {
                    Box(Modifier.size(320.dp, 560.dp).testTag("body-cut-root")) {
                        EntryView(selected(), false, {}, onLink = { actions += it }, settings = settings,
                            anchorRequest = request.value,
                            onAnchorConsumed = { if (request.value === it) request.value = null })
                    }
                }
            } } }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            assertTrue(failures.isEmpty())
            tap(owner("list-action"), "list-action")
            compose.onNodeWithText("Collapse Usage").performClick()
            compose.waitForIdle()
            compose.onNodeWithText("Expand Usage").assertIsDisplayed()
            assertTrue(views().all { it.logicalText.toString().contains("list-action").not() })
            compose.onAllNodesWithText("list-action", useUnmergedTree = true).assertCountEquals(0)
            compose.onNodeWithContentDescription("Sections").performClick()
            compose.onNode(hasText("Usage") and hasAnyAncestor(isPopup())).performClick()
            compose.waitForIdle()
            compose.onNodeWithText("Collapse Usage").assertIsDisplayed()
            tap(owner("list-action"), "list-action")
            compose.onNodeWithText("Collapse Usage").performClick()
            compose.waitForIdle()
            compose.runOnIdle { request.value = EntryAnchorRequest(selected().key, "#usage") }
            compose.waitForIdle()
            assertNull(request.value)
            compose.onNodeWithText("Collapse Usage").assertIsDisplayed()
            tap(owner("list-action"), "list-action")
            compose.runOnIdle { supported.value = true }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            val recovered = owner("list-action")
            compose.runOnIdle {
                assertEquals("list-action", recovered.logicalText.toString())
                val nodes = checkNotNull(recovered.currentMeasuredGeometry).nodes
                assertEquals(1, nodes.count { it.kind == FloatInteractionKind.LINK })
                assertEquals(1, nodes.count { it.kind == FloatInteractionKind.MARKER })
                assertEquals(0, nodes.count { it.kind == FloatInteractionKind.HEADING || it.kind == FloatInteractionKind.CONTROL })
                val link = nodes.single { it.kind == FloatInteractionKind.LINK }
                val info = checkNotNull(recovered.accessibilityNodeProvider.createAccessibilityNodeInfo(link.id))
                assertEquals("list-action", info.text.toString())
                assertTrue(info.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK })
            }
            tap(recovered, "list-action")
            assertEquals(List(4) { "list-action" }, actions.map { it.target })
        }
}
