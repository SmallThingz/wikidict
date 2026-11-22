package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Source-domain controls only; synthetic rendition identities do not authenticate real media. */
class FigureBlockMediaTest {
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val edges = StyleEdges(zero, zero, zero, zero)
    private fun wrapper(scale: Float = 1f) = ContainerStyle(margins = edges, width = ContainerWidth.Auto,
        lineHeight = ContainerLineHeight.Multiplier(1.5f), textAlign = CellTextAlign.Left, ownerFontScale = scale)
    private fun media(scale: Float = 1f) = FigureMediaLayout(
        FigureMediaStrut(scale, language = "vi", direction = BidiResolvedDirection.Ltr),
        InlineBoxVerticalAlign.Middle, AvailableWidthLimit(100f, zero))
    private fun rendition(density: Int) = FigureBlockMediaRendition(
        "https://example.test/controlled-${density}x.png", density.toString().repeat(64))
    private fun layout() = FigureBlockMediaLayout(wrapper(), media(), 44, 120, 110,
        rendition(1), rendition(2))
    private fun figure(policy: FigureBlockMediaLayout? = layout()) = Figure(
        content = FigureContent.Image(Span("text", "", language = "vi", tooltip = "original span",
            image = InlineImage("Controlled.svg", 44, 40, "original alt", "original image", true,
                darkModeFilter = ImageDarkModeFilter.InvertHueRotate180, svgLanguage = "vi")),
            FigureSizingPolicy.RequestedFit),
        format = FigureFormat.Thumbnail, placement = FigurePlacement.None, clear = FigureClear.None,
        margins = edges, imageInsets = edges, captionPadding = edges, captionFontScale = .875f,
        captionLineHeight = StyleLength(StyleLengthUnit.Em, 1.25f), frameBackground = FigureColor.Transparent,
        frameBorder = FigureBorder.None, imageBackground = FigureColor.Transparent, imageBorder = FigureBorder.None,
        captionForeground = FigureColor.Rgb("#123456"), captionBackground = FigureColor.Transparent,
        blockMediaLayout = policy)
    private fun rejects(label: String, action: () -> Any?) {
        assertTrue(label, runCatching(action).isFailure)
    }

    @Test fun completeStatesUseRootFractionalThresholdsAndPreserveOriginalImageMetadata() {
        val first = FigureBlockMediaState(639, wrapper(1.25f).copy(
            lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 24f)),
            textAlign = CellTextAlign.Center), media(1.25f))
        val last = FigureBlockMediaState(399, wrapper(.75f).copy(textAlign = CellTextAlign.Right),
            media(.75f).copy(maxWidth = null))
        val policy = layout().copy(viewportStates = listOf(first, last))
        assertNull(policy.stateAtViewport(639.25))
        assertSame(first, policy.stateAtViewport(639.0))
        assertSame(first, policy.stateAtViewport(638.75))
        assertSame(first, policy.stateAtViewport(399.25))
        assertSame(last, policy.stateAtViewport(399.0))
        assertSame(last, policy.stateAtViewport(0.0))
        for (width in listOf(-.25, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            rejects("viewport $width") { policy.stateAtViewport(width) }
        }
        val value = figure(policy)
        assertEquals(value.copy(blockMediaLayout = null), figure(null))
        assertNull(value.tableCaptionLayout)
        assertEquals(emptyList<Block>(), value.copy(captionBlocks = emptyList()).captionBlocks)
        assertEquals(44L, value.content.span.image!!.widthPx)
        assertEquals(40L, value.content.span.image!!.heightPx)
        assertEquals(120L, policy.naturalWidth); assertEquals(110L, policy.naturalHeight)
        assertEquals("original alt", value.content.span.image!!.alt)
        assertEquals("original span", value.content.span.tooltip)
        assertEquals(ImageDarkModeFilter.InvertHueRotate180, value.content.span.image!!.darkModeFilter)
        val zeroEm = StyleLength(StyleLengthUnit.Em, 0f)
        assertNotNull(value.copy(margins = StyleEdges(zeroEm, zeroEm, zeroEm, zeroEm)))
    }

    @Test fun stateDomainRequiresCompleteMatchingSourceOwnersWithoutInventingDefaults() {
        val good = layout()
        val missing = listOf(wrapper().copy(width = null), wrapper().copy(lineHeight = null),
            wrapper().copy(textAlign = null), wrapper().copy(ownerFontScale = null), wrapper().copy(margins = null),
            wrapper().copy(ownerFontScale = 1.5f), wrapper().copy(width = ContainerWidth.FitContent))
        missing.forEachIndexed { index, value -> rejects("required wrapper $index") { good.copy(wrapper = value) } }
        val extras = listOf(wrapper().copy(padding = edges), wrapper().copy(floatSide = TableFloatSide.Left),
            wrapper().copy(clear = FigureClear.None), wrapper().copy(maxWidth = ContainerMaxWidth.None),
            wrapper().copy(boxSizing = ContainerBoxSizing.ContentBox), wrapper().copy(layout = ContainerLayout.Flow),
            wrapper().copy(layout = ContainerLayout.FlexRow, alignItems = ContainerAlignItems.Center),
            wrapper().copy(flexItem = ContainerFlexItem.None), wrapper().copy(background = ContainerColor.Transparent),
            wrapper().copy(border = ContainerBorder.None), wrapper().copy(screenMaxWidth = ContainerScreenMaxWidth(639,
                width = ContainerWidth.Auto)), wrapper().copy(overflow = ContainerOverflow.Visible),
            wrapper().copy(height = zero), wrapper().copy(columns = ContainerColumns(1, zero)),
            wrapper().copy(positioning = ContainerPositioning.RelativeAuto), wrapper().copy(minHeight = zero))
        extras.forEachIndexed { index, value -> rejects("extra wrapper $index") { good.copy(wrapper = value) } }
        rejects("baseline") { good.copy(media = media().copy(verticalAlign = InlineBoxVerticalAlign.Baseline)) }
        rejects("subtracted cap") { good.copy(media = media().copy(maxWidth = AvailableWidthLimit(100f,
            StyleLength(StyleLengthUnit.Px, 1f)))) }
        rejects("position") { good.copy(media = media().copy(positioning = ContainerPositioning.RelativeAuto)) }
        val outline = FigureFocusOutline(zero, FigureColor.Rgb("#123456"), zero, zero)
        rejects("focus") { good.copy(media = media().copy(focusOutline = outline)) }
        val after = FigureMediaAfter(StyleLength(StyleLengthUnit.Px, 15f), StyleLength(StyleLengthUnit.Px, 11f),
            TableFloatSide.Right, StyleLength(StyleLengthUnit.Px, 6f), SignedContainerMargin(StyleLengthUnit.Px, -11f))
        rejects("after") { good.copy(media = media().copy(positioning = ContainerPositioning.RelativeAuto, after = after)) }
        val signed = SignedContainerMargin(StyleLengthUnit.Em, -.25f)
        assertNotNull(good.copy(wrapper = wrapper().copy(margins = SignedContainerEdges(signed, zero, zero, zero))))
        val auto = ContainerMargins(ContainerMargin.Auto, ContainerMargin.Auto,
            ContainerMargin.Length(zero), ContainerMargin.Length(signed))
        assertNotNull(good.copy(wrapper = wrapper().copy(margins = null, marginValues = auto)))
        assertNotNull(good.copy(media = media().copy(maxWidth = AvailableWidthLimit(100f,
            StyleLength(StyleLengthUnit.Em, 0f)))))
        assertNotNull(good.copy(wrapper = wrapper(0f).copy(lineHeight = ContainerLineHeight.Multiplier(0f)), media = media(0f)))
    }

    @Test fun layoutBoundsRetainUnsignedThresholdsAndRefuseAmbiguousDensityIdentities() {
        val good = layout()
        assertEquals(0xffff_ffffL, good.copy(preferredWidthPx = 0xffff_ffffL).preferredWidthPx)
        assertEquals(0x7fff_ffffL, good.copy(naturalWidth = 0x7fff_ffffL).naturalWidth)
        for (axis in listOf(0L, -1L, 0x1_0000_0000L)) rejects("preferred $axis") { good.copy(preferredWidthPx = axis) }
        for (axis in listOf(0L, -1L, 0x8000_0000L)) {
            rejects("width $axis") { good.copy(naturalWidth = axis) }
            rejects("height $axis") { good.copy(naturalHeight = axis) }
        }
        val max = FigureBlockMediaState(0xffff_ffffL, wrapper(), media())
        val zero = FigureBlockMediaState(0, wrapper(), media())
        val bound = good.copy(viewportStates = listOf(max, zero))
        assertSame(max, bound.stateAtViewport(0xffff_ffffL.toDouble()))
        assertSame(zero, bound.stateAtViewport(0.0))
        rejects("negative threshold") { max.copy(maxWidthPx = -1) }
        rejects("overflow threshold") { max.copy(maxWidthPx = 0x1_0000_0000L) }
        val sixteen = (16L downTo 1L).map { FigureBlockMediaState(it, wrapper(), media()) }
        assertEquals(16, good.copy(viewportStates = sixteen).viewportStates.size)
        rejects("seventeen states") { good.copy(viewportStates = sixteen + zero) }
        rejects("duplicate") { good.copy(viewportStates = listOf(max, max)) }
        rejects("ascending") { good.copy(viewportStates = listOf(zero, max)) }
        rejects("same URL") { good.copy(rendition2x = rendition(2).copy(url = rendition(1).url)) }
        rejects("same SHA256") { good.copy(rendition2x = rendition(2).copy(sha256 = rendition(1).sha256)) }
    }

    @Test fun rasterIdentityUsesExactSharedAsciiDomainWithoutNormalization() {
        val good = rendition(1)
        val preserved = "https://EXAMPLE..test/%2fimage?size=1"
        assertEquals(preserved, good.copy(url = preserved).url)
        val prefix = "https://example.test/"
        assertEquals(8192, good.copy(url = prefix + "x".repeat(8192 - prefix.length)).url.length)
        for (url in listOf("", "HTTPS://example.test/a", "http://example.test/a", "https://example.test",
            "https://example.test/", "https:///a", "https://localhost/a", "https://.example.test/a",
            "https://example.test./a", "https://user@example.test/a", "https://example.test:443/a",
            "https://example.test/a#fragment", "https://example.test/a\\b", "https://example.test/a b",
            "https://example.test/a\n", "https://example.test/\u00e9", prefix + "x".repeat(8193 - prefix.length))) {
            rejects("URL $url") { good.copy(url = url) }
        }
        for (hash in listOf("", "1".repeat(63), "1".repeat(65), "A".repeat(64), "g".repeat(64))) {
            rejects("SHA256 $hash") { good.copy(sha256 = hash) }
        }
    }

    @Test fun figureVisitorIdentifiesEachOwnerWhenTheSameSpanIsReusedAndHonorsItsBoundary() {
        val block = figure()
        val legacy = block.copy(blockMediaLayout = null)
        val reused = block.content.span
        val parts = listOf(FlowPart.ImageFigure(block), FlowPart.Inline(listOf(reused)), FlowPart.ImageFigure(legacy))
        var owner: Figure? = null
        val events = mutableListOf<String>()
        val visitor = PresentationSpanVisitor { spans, _ -> if (spans.isNotEmpty()) events += "inline:${spans.single().image!!.file}" }
        visitor.onFigure = { value -> owner = value; events += if (value.blockMediaLayout != null) "block" else "legacy" }
        visitor.visitFigureContent = { content ->
            assertSame(reused, content.span)
            events += if (owner!!.blockMediaLayout != null) "block-content" else "legacy-content"
        }
        visitor.parts(parts, 0, 0)
        assertEquals(listOf("block", "block-content", "inline:Controlled.svg", "legacy", "legacy-content"), events)
        events.clear(); visitor.visitFigures = false; visitor.parts(parts, 0, 0)
        assertEquals(listOf("inline:Controlled.svg"), events)
    }

    @Test fun blockPolicyRejectsCompetingOwnersWhileNullPolicyRetainsLegacyFigureBehavior() {
        val good = figure()
        val nonzero = StyleLength(StyleLengthUnit.Px, 1f)
        val mutations: List<Pair<String, () -> Figure>> = listOf(
            "placement" to { good.copy(placement = FigurePlacement.Center) },
            "clear" to { good.copy(clear = FigureClear.Both) },
            "frame minimum" to { good.copy(frameMinWidth = zero) },
            "frame border" to { good.copy(frameBorder = FigureBorder.Solid(zero, FigureColor.Transparent)) },
            "image border" to { good.copy(imageBorder = FigureBorder.Solid(zero, FigureColor.Transparent)) },
            "frame color" to { good.copy(frameBackground = FigureColor.NativeTheme) },
            "image color" to { good.copy(imageBackground = FigureColor.NativeTheme) },
            "caption color" to { good.copy(captionBackground = FigureColor.NativeTheme) },
            "flat caption" to { good.copy(caption = listOf(Span("text", ""))) },
            "rich caption" to { good.copy(captionBlocks = listOf(Block("paragraph", 0, emptyList()))) },
            "caption alignment" to { good.copy(captionTextAlign = CellTextAlign.Left) },
            "margin" to { good.copy(margins = edges.copy(left = nonzero)) },
            "inset" to { good.copy(imageInsets = edges.copy(right = nonzero)) },
            "padding" to { good.copy(captionPadding = edges.copy(top = nonzero)) },
            "Missing" to { good.copy(content = FigureContent.Missing(Span("text", "missing"), nonzero, nonzero)) },
            "link" to { good.copy(content = (good.content as FigureContent.Image).copy(
                span = good.content.span.copy(kind = "link", target = "File:Controlled.svg"))) }
        )
        mutations.forEach { (label, mutate) -> rejects(label, mutate) }
        val table = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(),
            FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None),
            FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None), media())
        rejects("table policy") { good.copy(tableCaptionLayout = table) }
        val image = good.content.span.image!!
        val map = ImageMap(ImageMapDescription.None, emptyList())
        rejects("map") { good.copy(content = (good.content as FigureContent.Image).copy(span = good.content.span.copy(
            image = image.copy(map = map)))) }
        val poster = InlineImage("Controlled.stl", 44, 33, staticPoster = StaticPoster(StaticPosterPolicy.ThreeDStlV1,
            "poster", "a".repeat(40), "2026-01-01T00:00:00Z"))
        rejects("poster") { good.copy(content = (good.content as FigureContent.Image).copy(span = good.content.span.copy(image = poster))) }
        assertEquals(FigurePlacement.Center, figure(null).copy(placement = FigurePlacement.Center).placement)
        assertNotNull(figure(null).copy(caption = listOf(Span("text", "legacy caption"))))
    }
}
