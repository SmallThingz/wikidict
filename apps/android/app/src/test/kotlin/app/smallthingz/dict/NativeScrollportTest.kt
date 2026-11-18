package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class NativeScrollportTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero = FloatMargins(0f, 0f, 0f, 0f)
    private class Wire {
        val output = ByteArrayOutputStream()
        fun byte(value: Int) { output.write(value) }
        fun short(value: Int) { byte(value); byte(value ushr 8) }
        fun int(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun text(value: String) { val bytes = value.encodeToByteArray(); int(bytes.size); output.write(bytes) }
    }
    private fun frame(version: Char, overflow: Int?) = Wire().apply {
        byte(68); byte(80); byte(82); byte(version.code); int(0)
        int(1); byte(2); text("Scrollport"); text(""); text(""); int(1)
        byte(13); byte(0); byte(0); int(0); byte(0); text(""); text(""); byte(0); text(""); text(""); repeat(4) { byte(0) }
        val flags = if (overflow == null) 0 else 0x8000
        if (version == 'M') int(flags) else short(flags)
        overflow?.let(::byte)
        int(0); int(0); int(0); int(1); int(0); int(0); int(0)
    }.output.toByteArray()
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "word", "language", "English", "en")

    @Test fun existingLAndMAutoBytesRemainSemanticAndUnknownValuesRefuse() {
        for (overflow in listOf(null, 0, 1)) {
            val legacy = frame('L', overflow)
            val current = frame('M', overflow)
            assertEquals(read(legacy).sections, read(current).sections)
            val style = read(current).sections.single().blocks.single().container!!.style
            assertEquals(when (overflow) { 0 -> ContainerOverflow.Visible; 1 -> ContainerOverflow.Auto; else -> null }, style.overflow)
            // The M style word only inserts two zero high bytes; no new scroll state is serialized.
            assertEquals(legacy.size + 2, current.size)
        }
        val hidden = read(frame('M', 2)).sections.single().blocks.single().container!!
        assertEquals(ContainerOverflow.Hidden, hidden.style.overflow)
        assertTrue(hidden.blocks.isEmpty())
        for (version in listOf('L', 'M')) {
            assertThrows(Exception::class.java) { read(frame(version, if (version == 'L') 2 else 3)) }
            val bytes = frame(version, 1)
            for (length in bytes.indices) assertThrows(Exception::class.java) { read(bytes.copyOf(length)) }
            assertThrows(Exception::class.java) { read(bytes + byteArrayOf(0)) }
        }
        for (version in listOf('J', 'K')) assertThrows(Exception::class.java) { read(frame(version, 1)) }
    }

    @Test fun autoHeightDomainAcceptsRealMax500ButRefusesUnprovedAxesAndContexts() {
        val auto = ContainerStyle(overflow = ContainerOverflow.Auto)
        assertNull(nativeScrollportUnavailable(auto))
        assertNull(nativeScrollportUnavailable(auto.copy(width = ContainerWidth.Auto,
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 500f)),
            padding = StyleEdges(px(1f), px(5f), px(1f), px(5f)), clear = FigureClear.Both)))
        val scalar = ContainerMargin.Length(px(0f))
        val unsupported = listOf(auto.copy(height = px(0f)), auto.copy(minHeight = px(0f)),
            auto.copy(layout = ContainerLayout.FlexRow), auto.copy(flexItem = ContainerFlexItem.None),
            auto.copy(columns = ContainerColumns(2, px(10f))), auto.copy(positioning = ContainerPositioning.RelativeAuto),
            auto.copy(floatSide = TableFloatSide.Left), auto.copy(screenMaxWidth = ContainerScreenMaxWidth(500, width = ContainerWidth.Auto)),
            auto.copy(width = ContainerWidth.FitContent), auto.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 100f))),
            auto.copy(maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 50f))),
            auto.copy(marginValues = ContainerMargins(scalar, scalar, scalar, scalar)),
            auto.copy(margins = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Px, -1f), px(0f), px(0f), px(0f))))
        unsupported.forEach { assertNotNull(it.toString(), nativeScrollportUnavailable(it)) }
        assertNotNull(nativeScrollportUnavailable(auto, flexItem = true))
        assertNull(nativeScrollportUnavailable(auto.copy(overflow = ContainerOverflow.Visible, height = px(10f))))
    }

    @Test fun scrollRangeUsesLayoutAndPaddingAndDetectsVerticalOverflowWithoutLosingBody() {
        val padding = FloatMargins(1.25f, 3.5f, 2.25f, 4.5f)
        val allocation = nativeScrollportAllocation(100, 30f, NativeFloatBounds(0f, 0f, 240f, 30f), padding)
        assertEquals(248, allocation.content); assertEquals(148, allocation.range)
        assertEquals(34, allocation.height); assertEquals(4.5f, allocation.originX, 0f)
        assertEquals(1.25f, allocation.originY, 0f); assertFalse(allocation.verticalOverflow); assertFalse(allocation.leadingOverflow)
        val fits = nativeScrollportAllocation(100, 30f, NativeFloatBounds(0f, 0f, 40f, 30f), padding)
        assertEquals(0, fits.range)
        val signed = nativeScrollportAllocation(100, 10f, NativeFloatBounds(-20f, -4f, 120f, 30f), zero)
        assertEquals(140, signed.content); assertEquals(20f, signed.originX, 0f)
        assertEquals(34, signed.height); assertEquals(4f, signed.originY, 0f)
        assertTrue(signed.verticalOverflow); assertTrue(signed.leadingOverflow)
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeScrollportAllocation(100, 10f, NativeFloatBounds(0f, 0f, TablePixelLimit.toFloat() + 1f, 10f), zero)
        }
    }

    @Test fun realAdapterKeepsOneChildGraphAndCountsPaddingAndBordersOnce() {
        val children = listOf(NativeFloatContextSpec.Child(10, { 700 }, 0f, widthFromContent = true),
            NativeFloatContextSpec.Child(11, { 800 }, 0f, widthFromContent = true))
        val style = ContainerStyle(overflow = ContainerOverflow.Auto,
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 500f)),
            padding = StyleEdges(px(3f), px(10f), px(7f), px(10f)),
            border = ContainerBorder.Solid(px(2f), ContainerColor.Transparent))
        val owner = nativeContainerSpec(7, style.atViewport(1000.0), children, 1f, 20f, false, false, false)
        assertNull(owner.unavailableReason); assertTrue(owner.isolatesFloats)
        val viewport = owner.preparedParts!!.single() as NativeFloatContextSpec.Child
        assertEquals(-8, viewport.id); assertSame(children, viewport.scrollport!!.parts)
        assertEquals(FloatMargins(3f, 10f, 7f, 10f), viewport.scrollport.padding)
        assertEquals(FloatMargins(2f, 2f, 2f, 2f), owner.padding(1000))
        assertEquals(520, owner.contentWidth(1000, ContainerWidths(820f, 820f)))
        assertEquals(296, owner.contentWidth(300, ContainerWidths(820f, 820f)))
        assertEquals(2f, owner.horizontal!!(1000, ContainerWidths(820f, 820f)).contentLeft, 0f)
        val ordinary = nativeContainerSpec(7, style.copy(overflow = ContainerOverflow.Visible).atViewport(1000.0),
            children, 1f, 20f, false, false, false)
        assertSame(children, ordinary.preparedParts)
        val refused = nativeContainerSpec(7, style.copy(height = px(10f)).atViewport(1000.0),
            children, 1f, 20f, false, false, false)
        assertNotNull(refused.unavailableReason); assertSame(children, refused.preparedParts)
    }

    @Test fun maxWidthKeepsBodyEmBasisAndBorderBoxContentResolution() {
        val style = ContainerStyle(overflow = ContainerOverflow.Auto, ownerFontScale = .5f,
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Em, 25f)),
            padding = StyleEdges(px(0f), px(5f), px(0f), px(5f)))
        val widths = ContainerWidths(800f, 800f)
        val content = containerBoxWidth(style.atViewport(1000.0), 1000f, widths, 2f, 20f)
        assertEquals(500f, content.content, 0f); assertEquals(520f, content.borderBox, 0f)
        val border = containerBoxWidth(style.copy(boxSizing = ContainerBoxSizing.BorderBox).atViewport(1000.0),
            1000f, widths, 2f, 20f)
        assertEquals(480f, border.content, 0f); assertEquals(500f, border.borderBox, 0f)
    }

    @Test fun scrollportBfcBlocksChildEscapeWithoutSummingExternalSiblingMargins() {
        val child = NativeFloatContextPart.Container(1, 100, { _, _ -> error("Structural only") },
            margins = SignedNativeContainerMargins(30f, 0f, 40f, 0f), preparedParts = emptyList())
        val owner = NativeFloatContextPart.Container(0, 100, { _, _ -> error("Structural only") },
            margins = SignedNativeContainerMargins(10f, 0f, 20f, 0f), preparedParts = listOf(child), isolatesFloats = true)
        val profile = checkNotNull(NativeFloatContextGeometry.adjoiningProfile(owner))
        assertEquals(10f, profile.before, 0f); assertEquals(20f, profile.after, 0f); assertFalse(profile.through)
        assertEquals(NativeMarginCollapse(false, false), owner.childCollapse(checkNotNull(NativeFloatContextGeometry.adjoiningProfile(child))))
        val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
        cursor.end(cursor.begin(profile), 50f, profile)
        assertEquals(90f, cursor.begin(NativeAdjoiningMargins(30f, 0f, false)).borderTop, 0f)
    }

    @Test fun failedMeasuredBodyExtentCannotLeakAcrossWidthOrSemanticRevision() {
        val input = NativeContextMeasureInput()
        val environment = NativeFlowEnvironment(1f, 1f, androidx.compose.ui.unit.LayoutDirection.Ltr,
            androidx.compose.ui.unit.IntSize(320, 640))
        val binding = NativeFlowBinding(environment, NativeTextInsets(), 0f)
        input.bind(binding)
        val constraints = androidx.compose.ui.unit.Constraints.fixedWidth(320)
        val policy = NativeFlowParentPolicy(Any(), true, null, 0f)
        val request = input.request(constraints, constraints, environment, policy, emptyList())
        val ticket = input.begin(binding, constraints)!!
        val failure = Result.failure<NativeFloatContextGeometry>(UnsupportedFloatLayout("Complete fallback body"))
        val bounds = NativeFloatBounds(0f, 0f, 900f, 100f)
        assertTrue(input.publish(ticket, failure, bounds))
        assertNull(input.ready(request))
        assertTrue(input.measured(request)!!.result.isFailure)
        assertEquals(bounds, input.measured(request)!!.fallbackBounds)
        val smaller = androidx.compose.ui.unit.Constraints.fixedWidth(200)
        val next = input.request(smaller, smaller, environment, policy, emptyList())
        assertNull(input.measured(request)); assertNull(input.measured(next))
        assertFalse(input.publish(ticket, failure, bounds))
        val current = input.begin(binding, smaller)!!
        assertTrue(input.publish(current, failure, bounds.copy(right = 700f)))
        input.semantic.changed()
        assertNull(input.measured(next)); assertFalse(input.publish(current, failure, bounds))
    }

    @Test fun documentExtentKeepsMeasuredLazyItemsButReplacesStaleLeasesAndResources() {
        val state = NativeDocumentScrollState()
        val firstKey = listOf("section", "table")
        val secondKey = listOf("next")
        val keys = setOf<Any>(firstKey, secondKey)
        val registry = state.registry(listOf("source", "font20"), 124, 100, 200, 12, false, keys)
        val first = registry.publisher(firstKey)
        val oldOwner = Any()
        first.attach(oldOwner)
        first.publish(oldOwner, 100, NativeFloatBounds(0f, 0f, 160.5f, 20f))
        assertEquals(61, registry.range)
        first.detach(oldOwner)
        assertEquals("Lazy disposal retains an actually measured range", 61, registry.range)
        val replacement = Any()
        first.attach(replacement)
        first.remove(replacement)
        assertEquals("A remounted first measurement failure clears its retained old extent", 0, registry.range)
        first.publish(replacement, 100, NativeFloatBounds(0f, 0f, 120f, 20f))
        first.detach(oldOwner)
        first.remove(oldOwner)
        first.publish(oldOwner, 100, NativeFloatBounds(0f, 0f, 900f, 20f))
        assertEquals("The new occurrence replaces, rather than unions with, its old extent", 20, registry.range)
        first.publish(replacement, 100, NativeFloatBounds(0f, 0f, 105f, 20f))
        assertEquals("A fresh smaller publication shrinks the same source item", 5, registry.range)
        first.publish(replacement, 99, NativeFloatBounds(0f, 0f, 900f, 20f))
        assertEquals("A stale width cannot change this viewport generation", 5, registry.range)
        val second = registry.publisher(secondKey)
        val secondOwner = Any()
        second.attach(secondOwner)
        second.publish(secondOwner, 100, NativeFloatBounds(0f, 0f, 140f, 20f))
        second.detach(secondOwner)
        first.remove(replacement)
        assertEquals(40, registry.range)
        registry.retain(setOf(firstKey))
        assertEquals("Real source removal prunes the detached known item", 0, registry.range)
        second.publish(secondOwner, 100, NativeFloatBounds(0f, 0f, 900f, 20f))
        assertEquals(0, registry.range)
        first.publish(replacement, 100, NativeFloatBounds(0f, 0f, 130f, 20f))
        registry.deactivate()
        registry.activate()
        assertEquals("Returning to the same visit retains measured extents", 30, registry.range)
        val changed = state.registry(listOf("source", "font40"), 124, 100, 200, 12, false, keys)
        assertNotSame(registry, changed)
        assertEquals(0, changed.range)
        first.publish(replacement, 100, NativeFloatBounds(0f, 0f, 900f, 20f))
        assertEquals("An old resource generation cannot publish to its replacement", 0, changed.range)
        val assetStates = mutableMapOf<String, InlineImageAssetState>("file" to InlineImageAssetState.Loading)
        val knownPixels = mutableListOf<InlineImagePixels?>(null)
        val loading = nativeDocumentImageRevision(assetStates, knownPixels)
        val imageOwner = Any()
        fun forAssets(revision: Pair<Map<String, InlineImageAssetState>, List<InlineImagePixels?>>) =
            state.registry(listOf("source", imageOwner, revision), 124, 100, 200, 12, false, keys)
        val loadingRegistry = forAssets(loading)
        val loadingPublisher = loadingRegistry.publisher(firstKey)
        loadingPublisher.attach(replacement)
        loadingPublisher.publish(replacement, 100, NativeFloatBounds(0f, 0f, 160f, 20f))
        loadingPublisher.detach(replacement)
        assertSame(loadingRegistry, forAssets(nativeDocumentImageRevision(assetStates, knownPixels)))
        knownPixels[0] = InlineImagePixels(80f, 40f)
        val metadata = nativeDocumentImageRevision(assetStates, knownPixels)
        assertNull("The retained revision is immutable", loading.second.single())
        assertEquals(InlineImageAssetState.Loading, metadata.first.getValue("file"))
        val metadataRegistry = forAssets(metadata)
        assertNotSame("Known axes invalidate even while Loading is unchanged", loadingRegistry, metadataRegistry)
        assertEquals(0, metadataRegistry.range)
        val metadataPublisher = metadataRegistry.publisher(firstKey)
        metadataPublisher.attach(replacement)
        metadataPublisher.publish(replacement, 100, NativeFloatBounds(0f, 0f, 120f, 20f))
        metadataPublisher.detach(replacement)
        assetStates["file"] = InlineImageAssetState.Failed
        val failed = nativeDocumentImageRevision(assetStates, knownPixels)
        assertEquals(InlineImageAssetState.Loading, metadata.first.getValue("file"))
        val failedRegistry = forAssets(failed)
        assertNotSame(metadataRegistry, failedRegistry)
        assertEquals("Same-owner loading/error changes cannot reuse detached extents", 0, failedRegistry.range)
        metadataPublisher.publish(replacement, 100, NativeFloatBounds(0f, 0f, 900f, 20f))
        assertEquals(0, failedRegistry.range)
    }

    @Test fun documentHorizontalAllocationKeepsNormalWidthAndUsesRepresentedOriginDirection() {
        val body = Block("paragraph", 0, listOf(Span("text", "label")))
        fun entry(block: Block) = Entry("synthetic document owner", emptyList(), "language", "French", "fr",
            listOf(Section(2, "Body", listOf(block))), emptyList())
        fun relative(children: List<Block>) = Block("container", 0, emptyList(),
            container = Container(children, ContainerStyle(positioning = ContainerPositioning.RelativeAuto)))
        val legacy = entry(relative(listOf(body)))
        assertFalse("Existing relative or plain source must keep the old list composition", nativeDocumentScrollNeeded(legacy))
        val absolute = Block("container", 0, emptyList(), container = Container(listOf(body),
            ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 24f)), height = px(20f),
                absolutePosition = ContainerAbsolutePosition(px(0f), px(0f)))))
        val direct = relative(listOf(absolute))
        assertTrue("The owner exists before any positive overflow is measured", nativeDocumentScrollNeeded(entry(direct)))
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), header = false, colspan = 1, rowspan = 1, blocks = listOf(direct)))))
        assertTrue("A real table cell keeps the same document export", nativeDocumentScrollNeeded(
            entry(Block("table", 0, emptyList(), table = table))))
        assertSame(body, absolute.container!!.blocks.single())
        val viewport = 124
        val padding = 12
        for (outerRtl in listOf(false, true)) for (direction in listOf(null, BidiResolvedDirection.Ltr, BidiResolvedDirection.Rtl)) {
            val expectedRtl = direction == BidiResolvedDirection.Rtl || direction == null && outerRtl
            val rtl = nativeDocumentRtl(direction, outerRtl)
            assertEquals(expectedRtl, rtl)
            for (range in listOf(0, 26, 61)) {
                val allocation = nativeDocumentAllocation(viewport, padding, range, rtl)
                assertEquals(viewport + range, allocation.width)
                assertEquals(100, allocation.width - allocation.leftPadding - allocation.rightPadding)
                val reverseScrolling = rtl != outerRtl
                for (scroll in setOf(0, range)) {
                    // Selected ScrollNode uses this logical offset, then placeRelative mirrors it.
                    val logical = if (reverseScrolling) scroll - range else -scroll
                    val physical = if (outerRtl) viewport - allocation.width - logical else logical
                    assertEquals(padding + if (rtl) scroll else -scroll, physical + allocation.leftPadding)
                }
            }
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeDocumentAllocation(TablePixelLimit, 12, 1, false)
        }
    }

    @Test fun audioSourceDocumentEnrollmentAndOverflowLeaseKeepContainingWidth() {
        val audio = Span("link", "Original audio label", "File:a.ogg",
            classes = "wikidict-media wikidict-media-file-612e6f6767", audioControl = AudioControl())
        fun entry(span: Span): Entry {
            var block = Block("paragraph", 0, listOf(span))
            repeat(3) { block = Block("container", 0, emptyList(),
                container = Container(listOf(block), ContainerStyle())) }
            return Entry("audio extent", emptyList(), "language", "Thai", "th",
                listOf(Section(2, "Body", listOf(block))), emptyList(), media = listOf(Media("a.ogg", "audio", "")))
        }
        val source = entry(audio)
        assertTrue(nativeDocumentScrollNeeded(source))
        assertFalse(nativeDocumentScrollNeeded(entry(audio.copy(audioControl = null))))
        assertTrue(nativeAudioDocumentScrollNeeded(source.sections.single().blocks))
        assertTrue(nativeAudioDocumentScrollNeeded(listOf(Block("paragraph", 0, listOf(audio)))))
        assertFalse(nativeAudioDocumentScrollNeeded(entry(audio.copy(audioControl = null)).sections.single().blocks))
        assertFalse(nativeAudioDocumentScrollNeeded(listOf(Block("paragraph", 0, listOf(Span("text", "Other chunk"))))))
        assertFalse(nativeAudioDocumentScrollNeeded(emptyList()))
        assertSame(audio, source.sections.single().blocks.single().container!!.blocks.single()
            .container!!.blocks.single().container!!.blocks.single().spans.single())
        for (direction in TableContainingDirection.entries) {
            val rtl = direction == TableContainingDirection.Rtl
            val registry = NativeDocumentOverflowRegistry(204, 180, 200, 12, rtl, setOf("source item"))
            val publisher = registry.publisher("source item")
            val owner = Any()
            publisher.attach(owner)
            for ((rule, expected) in listOf(NativeBlockWidth.FixedPx(250f) to 250f,
                NativeBlockWidth.Percent(150f) to 270f)) {
                var calls = 0
                val placed = placeNativeFixedMarginTable(180f, 0f, emptyList(), zero, direction, rule) { request ->
                    calls++
                    assertEquals(180f, request.containingWidth, 0f)
                    val requested = checkNotNull(request.requestedWidth)
                    assertEquals(expected, requested, 0f)
                    NativeBlockMeasure(requested, requested, 30f)
                }
                assertEquals(1, calls)
                assertEquals(if (rtl) 180f - expected else 0f, placed.content.left, 0f)
                assertEquals(if (rtl) 180f else expected, placed.content.right, 0f)
                publisher.publish(owner, 180, placed.content)
                assertEquals((expected - 180f).toInt(), registry.range)
                val allocation = nativeDocumentAllocation(204, 12, registry.range, rtl)
                assertEquals("The document surface never becomes the next percentage basis", 180,
                    allocation.width - allocation.leftPadding - allocation.rightPadding)
                publisher.publish(owner, 181, NativeFloatBounds(0f, 0f, 900f, 30f))
                assertEquals((expected - 180f).toInt(), registry.range)
            }
            publisher.remove(owner)
            assertEquals(0, registry.range)
            publisher.publish(owner, 180, NativeFloatBounds(if (rtl) -70f else 0f, 0f,
                if (rtl) 180f else 250f, 30f))
            assertEquals(70, registry.range)
            publisher.publish(owner, 180, NativeFloatBounds(0f, 0f, 180f, 30f))
            assertEquals(0, registry.range)
            publisher.detach(owner)
        }
        assertEquals("Original audio label", audio.text)
        assertEquals("File:a.ogg", audio.target)
    }
    @Test fun ordinaryHiddenPaddingKeepsExactAllocationAndNormalHeightWithoutAnInventedLine() {
        val tiny = 1f / 33554432f
        val fractional = FloatMargins(0f, tiny, 0f, 1f)
        assertEquals(2, nativeOrdinaryHiddenIntrinsicWidth(0, fractional))
        assertEquals(0, nativeOrdinaryHiddenContentWidth(2, fractional))
        assertEquals(1, nativeOrdinaryHiddenContentWidth(3, fractional))
        assertEquals(androidx.compose.ui.unit.Constraints.Infinity,
            nativeOrdinaryHiddenIntrinsicWidth(androidx.compose.ui.unit.Constraints.Infinity, fractional))
        val padding = FloatMargins(1.25f, 3.5f, 2.25f, 4.5f)
        val actual = nativeOrdinaryHiddenScrollportAllocation(200, 30f,
            NativeFloatBounds(0f, 0f, 320.5f, 30f), padding)
        assertEquals(33.5f, actual.usedHeight, 0f); assertEquals(34, actual.height)
        assertEquals(128.5f, actual.overflow, 0f)
        assertEquals(4.5f, actual.originX, 0f); assertEquals(1.25f, actual.originY, 0f)
        assertFalse(actual.leadingOverflow); assertFalse(actual.verticalOverflow)
        val unsupported = nativeOrdinaryHiddenScrollportAllocation(200, 30f,
            NativeFloatBounds(-20f, -4f, 320.5f, 90f), padding)
        assertTrue(unsupported.leadingOverflow); assertTrue(unsupported.verticalOverflow)
        assertEquals(33.5f, unsupported.usedHeight, 0f)
        assertEquals(128.5f, unsupported.overflow, 0f)
        val empty = nativeOrdinaryHiddenScrollportAllocation(200, 0f,
            NativeFloatBounds(0f, 0f, 0f, 0f), zero)
        assertEquals(0f, empty.usedHeight, 0f); assertEquals(0, empty.height); assertEquals(0f, empty.overflow, 0f)
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeOrdinaryHiddenScrollportAllocation(200, TablePixelLimit.toFloat(),
                NativeFloatBounds(0f, 0f, 200f, TablePixelLimit.toFloat()), padding)
        }
    }

    @Test fun ordinaryHiddenAdapterRetainsOriginalTableAndUsesActualContainingWidthBeforeViewportBand() {
        val link = Span("link", "Original", "original-target")
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(link), false, 1, 1))))
        val block = Block("table", 0, emptyList(), table = table)
        val style = ContainerStyle(overflow = ContainerOverflow.Hidden, positioning = ContainerPositioning.RelativeAuto,
            width = ContainerWidth.FitContent, maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
            boxSizing = ContainerBoxSizing.BorderBox,
            padding = StyleEdges(px(3f), px(8f), px(7f), px(12f)),
            border = ContainerBorder.Solid(px(2f), ContainerColor.Transparent),
            screenMaxWidth = ContainerScreenMaxWidth(639L, width = ContainerWidth.Auto))
        val source = Container(listOf(block), style)
        val children = listOf(NativeFloatContextSpec.Child(10, { 400 }, 0f, widthFromContent = true))
        val policy = NativeOrdinaryHiddenScrollportPolicy(source)
        assertNull(nativeScrollportUnavailable(style))
        assertNotNull(nativeScrollportUnavailable(style.copy(overflow = ContainerOverflow.Auto)))
        val cases = listOf(640.0 to 240, 639.0 to 240, 640.0 to 160, 639.0 to 160, 640.0 to 240)
        for ((rootCssWidth, containingWidth) in cases) {
            val resolved = style.atViewport(rootCssWidth)
            assertEquals(if (rootCssWidth <= 639.0) ContainerWidth.Auto else ContainerWidth.FitContent, resolved.box.width)
            val owner = nativeContainerSpec(7, resolved, children, 1f, 20f, false, false, false,
                ordinaryHidden = policy)
            assertNull(owner.unavailableReason); assertTrue(owner.isolatesFloats); assertTrue(owner.relativeAuto)
            val viewport = owner.preparedParts!!.single() as NativeFloatContextSpec.Child
            assertEquals(-8, viewport.id)
            val scrollport = checkNotNull(viewport.scrollport)
            assertSame(children, scrollport.parts); assertSame(source, scrollport.ordinaryHidden!!.source)
            assertNull(scrollport.positioned)
            assertEquals(FloatMargins(3f, 8f, 7f, 12f), scrollport.padding)
            assertEquals(FloatMargins(2f, 2f, 2f, 2f), owner.padding(containingWidth))
            val paddingWidth = owner.contentWidth(containingWidth, ContainerWidths(420f, 420f))
            assertEquals(containingWidth - 4, paddingWidth)
            assertEquals(containingWidth - 24, nativeOrdinaryHiddenContentWidth(paddingWidth, scrollport.padding))
            val measured = nativeOrdinaryHiddenScrollportAllocation(paddingWidth, 30f,
                NativeFloatBounds(0f, 0f, 400f, 30f), scrollport.padding)
            assertEquals(40f, measured.usedHeight, 0f)
            assertEquals((424 - containingWidth).toFloat(), measured.overflow, 0f)
            assertSame(table, source.blocks.single().table)
            assertSame(link, table.rows.single().single().spans.single())
        }
    }

}
