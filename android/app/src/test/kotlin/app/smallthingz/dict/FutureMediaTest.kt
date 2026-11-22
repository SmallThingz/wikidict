package app.smallthingz.dict

import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect

import org.junit.Assert.*
import org.junit.Test

class FutureMediaTest {
    @Test fun heldMissingLinkKeyRequiresSameDocumentTargetAndMeasuredNodeAcrossCallbackReplacement() {
        val owner = Any()
        val target = checkNotNull(missingLinkTarget(Span("link", "Label", "File:Missing.png"), "en"))
        val identity = MissingLinkActionIdentity(owner, target)
        var oldCalls = 0
        var newCalls = 0
        val oldAction = { oldCalls++; Unit }
        val newAction = { newCalls++; Unit }
        fun node(id: Int = 7, action: (() -> Unit)? = newAction, key: MissingLinkActionIdentity? = identity) =
            FloatInteractionNode(id, FloatInteractionKind.LINK, 0, 5, emptyList(), "Label", null, action,
                missingLinkPaint = NativeMissingLinkPaint(MissingLinkPaint.VectorNewLinkV1, false, false, actionIdentity = key))
        val pending = NativeLinkKeyPress(7, 66, identity, oldAction)
        val rebound = node()
        assertTrue(pending.matches(rebound))
        rebound.onClick?.invoke()
        assertEquals(0, oldCalls)
        assertEquals(1, newCalls)
        assertFalse(pending.matches(node(key = identity.copy(owner = Any()))))
        assertFalse(pending.matches(node(key = identity.copy(target = target.copy(target = "File:Other.png")))))
        assertFalse(pending.matches(node(key = identity.copy(target = target.copy(fragment = "")))))
        assertFalse(pending.matches(node(id = 8)))
        assertFalse(pending.matches(node(action = null)))
        assertFalse(pending.matches(node(key = null)))
        assertFalse(emptyList<FloatInteractionNode>().any(pending::matches))
        val legacy = NativeLinkKeyPress(7, 66, null, oldAction)
        assertTrue(legacy.matches(node(action = oldAction, key = null)))
        assertFalse(legacy.matches(node(action = newAction, key = null)))
    }

    @Test fun svgNaturalWidthCoversRoundedDisplayAxesWithoutExpandingOnePixelBacking() {
        val image = InlineImage("Test map.svg", widthPx = 3, svgLanguage = "ru")
        val request = SvgRasterRequest("ru", 2f, listOf(RasterImageOccurrence(image)))
        val demand = request.requiredSize(800, 400, "image/svg+xml")
        assertEquals(SvgRasterDemand(6, 4), demand)
        assertEquals(8, demand.naturalRequestWidth(800, 400))
        assertEquals(400, SvgRasterDemand(400, 200).naturalRequestWidth(800, 400))
        val tiny = SvgRasterRequest("ru", 1f, listOf(RasterImageOccurrence(image.copy(widthPx = 1), FigureSizingPolicy.RequestedFit)))
        assertEquals(0uL, figureSourceSize(image.copy(widthPx = 1), FigureSizingPolicy.RequestedFit, 4000, 1).height)
        val backing = tiny.requiredSize(4000, 1, "image/svg+xml")
        assertEquals(SvgRasterDemand(1, 1), backing)
        assertEquals(1, backing.naturalRequestWidth(4000, 1))
        assertEquals(6, demand.naturalRequestWidth(Long.MAX_VALUE, Long.MAX_VALUE))
        assertThrows(IllegalArgumentException::class.java) { SvgRasterDemand(1, 2).naturalRequestWidth(Long.MAX_VALUE, 1) }
        assertThrows(IllegalArgumentException::class.java) { demand.naturalRequestWidth(0, 400) }
        assertThrows(IllegalArgumentException::class.java) { SvgRasterDemand(0, 1).naturalRequestWidth(800, 400) }
    }

    @Test fun svgDemandSeparatesDprLanguageSizingAndAdequateServerBucket() {
        val ru = InlineImage("Test map.svg", widthPx = 200, svgLanguage = "ru")
        fun request(image: InlineImage = ru, density: Float = 1f, policy: FigureSizingPolicy? = null) =
            SvgRasterRequest(checkNotNull(image.svgLanguage), density, listOf(RasterImageOccurrence(image, policy)))
        assertEquals(200, request().requiredWidth(800, 400, "image/svg+xml"))
        assertEquals(400, request(density = 2f).requiredWidth(800, 400, "image/svg+xml"))
        assertEquals(SvgRasterDemand(400, 200), request(density = 2f).requiredSize(800, 400, "image/svg+xml"))
        val tiny = ru.copy(widthPx = 1)
        assertEquals(0uL, figureSourceSize(tiny, FigureSizingPolicy.RequestedFit, 4000, 1).height)
        assertEquals(SvgRasterDemand(1, 1), request(tiny, policy = FigureSizingPolicy.RequestedFit).requiredSize(4000, 1, "image/svg+xml"))
        assertEquals(800, request(policy = FigureSizingPolicy.Intrinsic).requiredWidth(800, 400, "image/svg+xml"))
        assertEquals(200, request(ru.copy(widthPx = null, heightPx = 100)).requiredWidth(800, 400, "image/svg+xml"))
        assertNotEquals(request().cacheSuffix, request(density = 2f).cacheSuffix)
        assertNotEquals(request().cacheSuffix, request(ru.copy(svgLanguage = "en")).cacheSuffix)
        assertNotEquals(request().cacheSuffix, request(policy = FigureSizingPolicy.Intrinsic).cacheSuffix)
        assertNotEquals(inlineImageAssetKey(ru), inlineImageAssetKey(ru.copy(svgLanguage = "und")))
        assertNotEquals(inlineImageAssetKey(ru.copy(svgLanguage = "en")), inlineImageAssetKey(ru.copy(svgLanguage = null)))
        val root = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Test_map.svg/"
        assertEquals(250, svgRasterWidth(root + "langru-250px-Test_map.svg.png", ru.file, "ru", 200))
        assertEquals(500, svgRasterWidth(root + "langru-500px-Test_map.svg.png", ru.file, "ru", 400))
        for (url in listOf(root + "langru-250px-Test_map.svg.png", root + "langen-500px-Test_map.svg.png",
            root + "500px-Test_map.svg.png", root + "langru-500px-Other.svg.png", root + "langru-500px-Test_map.svg",
            root.replace("https:", "http:") + "langru-500px-Test_map.svg.png",
            root.replace("upload.wikimedia.org", "example.org") + "langru-500px-Test_map.svg.png")) {
            assertThrows(url, RuntimeException::class.java) { svgRasterWidth(url, ru.file, "ru", 400) }
        }
        assertThrows(RuntimeException::class.java) { request().requiredWidth(800, 400, "image/png") }
        for (invalid in listOf("", "RU", "ru_RU", "ru-", "-ru", "ru--x", "ru1", "ru?x"))
            assertThrows(invalid, RuntimeException::class.java) { ru.copy(svgLanguage = invalid) }
    }

    @Test fun missingLinkPolicyPreservesAllPalettesStatePriorityAndTargetVisitIdentity() {
        val light = listOf(0xbf3c2c, 0x9f3526, 0x612419, 0x9f5555, 0x854848, 0x512e2e)
        val dark = listOf(0xfd7865, 0xfea898, 0xffc8bd, 0xc99391, 0xdcb5b3, 0xe8cecd)
        for (night in listOf(false, true)) for (visited in listOf(false, true)) for (hover in listOf(false, true)) for (active in listOf(false, true)) {
            val actual = missingLinkAppearance(MissingLinkPaint.VectorNewLinkV1, night, visited, hover, active)
            val index = (if (visited) 3 else 0) + if (active) 2 else if (hover) 1 else 0
            assertEquals(0xff000000.toInt() or (if (night) dark else light)[index], actual.color)
            assertEquals(hover || active, actual.underline)
        }
        val history = MissingLinkVisits()
        val first = Span("external_link", "First label", "https://example.org/missing")
        val same = first.copy(text = "Different label")
        val target = missingLinkTarget(first, "en")
        assertFalse(history.contains(target))
        history.record(target)
        assertTrue(history.contains(missingLinkTarget(same, "ru")))
        assertFalse(history.contains(missingLinkTarget(first.copy(target = first.target + "2"), "en")))
        assertNotEquals(missingLinkTarget(Span("link", "One", "", targetFragment = "part"), "en", "One"),
            missingLinkTarget(Span("link", "Two", "", targetFragment = "part"), "en", "Two"))
        assertEquals(missingLinkTarget(Span("link", "One", "Title#part"), "en"),
            missingLinkTarget(Span("link", "Two", "Title", targetFragment = "part"), "en"))
        history.clear(); assertFalse(history.contains(target))
        assertTrue(NativeMissingLinkPaint(MissingLinkPaint.VectorNewLinkV1, false, false, childUnderline = true).appearance().underline)
        val length = StyleLength(StyleLengthUnit.Px, 20f)
        assertThrows(RuntimeException::class.java) { FigureContent.Missing(Span("link", "Label", "", targetFragment = "part"), length, length) }
        assertEquals(" ", FigureContent.Missing(Span("link", "Label", " "), length, length).span.target)
        assertThrows(RuntimeException::class.java) { FigureContent.Missing(Span("text", "Label"), length, length, MissingLinkPaint.VectorNewLinkV1) }
        assertThrows(RuntimeException::class.java) { FigureContent.Missing(first.copy(foreground = "#123456"), length, length, MissingLinkPaint.VectorNewLinkV1) }
    }

    // Appended to FutureMediaTest; requires kotlinx.coroutines.launch and kotlinx.coroutines.flow.collect.
    @Test fun playbackFocusReplayPreservesOriginalIdentityAndStockStatePrecedence(): Unit = kotlinx.coroutines.runBlocking {
        val source = PlaybackFocusInteractions()
        val early = mutableListOf<androidx.compose.foundation.interaction.Interaction>()
        val late = mutableListOf<androidx.compose.foundation.interaction.Interaction>()
        val afterClear = mutableListOf<androidx.compose.foundation.interaction.Interaction>()
        val expected = mutableListOf<androidx.compose.foundation.interaction.Interaction>()
        val jobs = mutableListOf<kotlinx.coroutines.Job>()
        fun observe(target: MutableList<androidx.compose.foundation.interaction.Interaction>) {
            jobs += launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                source.interactions.collect { target += it }
            }
        }
        fun assertEvents(actual: List<androidx.compose.foundation.interaction.Interaction>) {
            assertEquals(expected.size, actual.size)
            expected.zip(actual).forEach { (wanted, observed) ->
                when (wanted) {
                    is androidx.compose.foundation.interaction.FocusInteraction.Focus -> assertSame(wanted, observed)
                    is androidx.compose.foundation.interaction.FocusInteraction.Unfocus -> {
                        assertTrue(observed is androidx.compose.foundation.interaction.FocusInteraction.Unfocus)
                        assertSame(wanted.focus, (observed as androidx.compose.foundation.interaction.FocusInteraction.Unfocus).focus)
                    }
                    else -> error("Only focus transitions belong in this oracle")
                }
            }
        }
        suspend fun settle() {
            kotlinx.coroutines.yield()
            assertEvents(early)
            assertEvents(late)
        }
        try {
            observe(early)
            assertTrue(early.isEmpty())
            val first = androidx.compose.foundation.interaction.FocusInteraction.Focus()
            source.accept(first)
            expected += first
            kotlinx.coroutines.yield()
            assertEvents(early)
            // A new indication subscribes while focus is already held: replay the
            // actual Focus object, not a fabricated replacement or a second input event.
            observe(late)
            assertEvents(late)

            val press = androidx.compose.foundation.interaction.PressInteraction.Press(androidx.compose.ui.geometry.Offset(2f, 3f))
            source.accept(press)
            source.accept(androidx.compose.foundation.interaction.PressInteraction.Release(press))
            source.accept(androidx.compose.foundation.interaction.PressInteraction.Cancel(press))
            source.accept(androidx.compose.foundation.interaction.FocusInteraction.Unfocus(
                androidx.compose.foundation.interaction.FocusInteraction.Focus()))
            settle()

            val hover = androidx.compose.foundation.interaction.HoverInteraction.Enter()
            val drag = androidx.compose.foundation.interaction.DragInteraction.Start()
            source.accept(hover)
            expected += androidx.compose.foundation.interaction.FocusInteraction.Unfocus(first)
            settle()
            source.accept(drag)
            settle()
            // Ending an older hover cannot revive focus while a later drag still owns the state layer.
            source.accept(androidx.compose.foundation.interaction.HoverInteraction.Exit(hover))
            settle()
            source.accept(androidx.compose.foundation.interaction.DragInteraction.Stop(drag))
            expected += first
            settle()
            val cancelledDrag = androidx.compose.foundation.interaction.DragInteraction.Start()
            source.accept(cancelledDrag)
            expected += androidx.compose.foundation.interaction.FocusInteraction.Unfocus(first)
            settle()
            source.accept(androidx.compose.foundation.interaction.DragInteraction.Cancel(cancelledDrag))
            expected += first
            settle()

            val second = androidx.compose.foundation.interaction.FocusInteraction.Focus()
            source.accept(second)
            expected += androidx.compose.foundation.interaction.FocusInteraction.Unfocus(first)
            expected += second
            settle()
            // Removing the older Focus preserves the currently effective original Focus.
            source.accept(androidx.compose.foundation.interaction.FocusInteraction.Unfocus(first))
            settle()
            source.accept(androidx.compose.foundation.interaction.FocusInteraction.Unfocus(second))
            expected += androidx.compose.foundation.interaction.FocusInteraction.Unfocus(second)
            settle()

            val third = androidx.compose.foundation.interaction.FocusInteraction.Focus()
            source.accept(third)
            expected += third
            settle()
            // This is the same clear called by the owning collector's disposal finally.
            source.clear()
            expected += androidx.compose.foundation.interaction.FocusInteraction.Unfocus(third)
            settle()
            observe(afterClear)
            assertTrue(afterClear.isEmpty())
            source.accept(androidx.compose.foundation.interaction.FocusInteraction.Unfocus(third))
            source.accept(androidx.compose.foundation.interaction.HoverInteraction.Exit(hover))
            source.accept(androidx.compose.foundation.interaction.DragInteraction.Stop(drag))
            settle()
            assertTrue(afterClear.isEmpty())
        } finally {
            source.clear()
            jobs.forEach { it.cancel() }
            jobs.forEach { it.join() }
        }
    }

    @Test fun audioControlDimensionsUseOriginalContainingAndBodyBasesWithoutClamping() {
        val pixels = AudioControl(width = StyleWidth(StyleWidthUnit.Px, 250f),
            height = StyleLength(StyleLengthUnit.Px, 30f))
        assertEquals(500f, checkNotNull(audioControlWidthPixels(pixels, 180f, 2f, 40f)), 0f)
        assertEquals(60f, checkNotNull(audioControlHeightPixels(pixels, 2f, 40f)), 0f)
        val percent = pixels.copy(width = StyleWidth(StyleWidthUnit.Percent, 125f))
        assertEquals(225f, checkNotNull(audioControlWidthPixels(percent, 180f, 2f, 40f)), 0f)
        assertEquals(300f, checkNotNull(audioControlWidthPixels(percent, 240f, 2f, 40f)), 0f)
        assertEquals(0f, checkNotNull(audioControlWidthPixels(percent, 0f, 2f, 40f)), 0f)
        val em = AudioControl(width = StyleWidth(StyleWidthUnit.Em, 1.5f),
            height = StyleLength(StyleLengthUnit.Em, .75f))
        assertEquals(30f, checkNotNull(audioControlWidthPixels(em, 400f, 2f, 20f)), 0f)
        assertEquals(60f, checkNotNull(audioControlWidthPixels(em, 400f, 2f, 40f)), 0f)
        assertEquals(30f, checkNotNull(audioControlHeightPixels(em, 2f, 40f)), 0f)
        assertEquals(0f, checkNotNull(audioControlHeightPixels(em, 2f, 0f)), 0f)
        assertNull(audioControlWidthPixels(AudioControl(), Float.NaN, 2f, 40f))
        assertNull(audioControlHeightPixels(AudioControl(), 2f, 40f))
        assertThrows(UnsupportedFloatLayout::class.java) { audioControlWidthPixels(percent, Float.NaN, 1f, 20f) }
        assertThrows(UnsupportedFloatLayout::class.java) { audioControlWidthPixels(pixels, 180f, Float.MAX_VALUE, 20f) }
        assertThrows(UnsupportedFloatLayout::class.java) { audioControlHeightPixels(em, 1f, Float.MAX_VALUE) }
        val tooWide = pixels.copy(width = StyleWidth(StyleWidthUnit.Px, TablePixelLimit + .25f))
        assertThrows(UnsupportedFloatLayout::class.java) { audioControlWidthPixels(tooWide, 400f, 1f, 20f) }
        val boundary = pixels.copy(width = StyleWidth(StyleWidthUnit.Px, TablePixelLimit.toFloat()))
        assertEquals(TablePixelLimit.toFloat(), checkNotNull(audioControlWidthPixels(boundary, 400f, 1f, 20f)), 0f)
        assertEquals(250f, pixels.width!!.value, 0f)
        assertEquals(30f, pixels.height!!.value, 0f)
    }
}
