package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Controlled J bytes only; no producer, geometry, accessibility or device acceptance. */
class FlowScopeTest {
    private class Wire {
        val bytes = ByteArrayOutputStream()
        fun byte(value: Int) { bytes.write(value) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun string(value: String) { val raw = value.toByteArray(Charsets.UTF_8); u32(raw.size); bytes.write(raw) }
        fun text(value: String) {
            byte(0); byte(0); byte(0)
            string(value); repeat(6) { string("") }
            repeat(6) { byte(0) } // foreground, background, scale, image, fragment, H tooltip
        }
        fun leaf(value: String = "אב Latin") { u32(1); byte(0); u32(1); text(value) }
        fun scope(depth: Int, language: String?, mode: Int = 0, authored: Int = 3, resolved: Int = 1) {
            u32(1); byte(2); byte(mode); byte(authored); byte(resolved)
            byte(if (language == null) 0 else 1); if (language != null) string(language)
            if (depth == 1) leaf() else scope(depth - 1, null)
        }
        fun document(content: Wire.() -> Unit): ByteArray {
            bytes.write(byteArrayOf(68, 80, 82, 74)); u32(0); u32(1)
            byte(2); string("Section"); string(""); string(""); u32(1)
            byte(0); byte(0); byte(0); u32(0); byte(0); string(""); string(""); byte(0)
            string(""); string(""); byte(0); byte(0); byte(0); byte(1)
            content()
            repeat(5) { u32(0) } // preamble, lexemes, other sections, references, media
            return bytes.toByteArray()
        }
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "Scope", "language", "English", "en")
    private fun block(parts: List<FlowPart>, kind: String = "paragraph", depth: Int = 0, path: String = "", number: String = "") =
        Block(kind, depth, emptyList(), listPath = path, number = number, flow = parts)
    private fun scope(parts: List<FlowPart>, language: String? = null,
        direction: BidiResolvedDirection = BidiResolvedDirection.Rtl) =
        FlowPart.Scope(BidiScope(BidiMode.Isolate, BidiDirectionInput.Auto, direction, language, parts))
    private fun text(value: String) = FlowPart.Inline(listOf(Span("text", value)))
    private fun figure(captionBlocks: List<Block>? = null): Figure {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        return Figure(FigureContent.Image(Span("link", "", "Exact#title", targetFragment = "", image = InlineImage("Image.svg")), FigureSizingPolicy.Intrinsic),
            FigureFormat.Framed, FigurePlacement.FloatLeft, FigureClear.None, edges, edges, edges,
            .884f, StyleLength(StyleLengthUnit.Em, 1.2376f), FigureColor.NativeTheme, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = if (captionBlocks == null) listOf(Span("text", "Caption")) else emptyList(), captionBlocks = captionBlocks)
    }

    @Test fun literalJScopeRetainsCompiledDirectionAndLanguagePresenceWithoutAutoRescanning() {
        for (language in listOf(null, "", "he")) {
            val entry = decode(Wire().document { scope(1, language, resolved = 0) })
            val result = (entry.sections.single().blocks.single().flow!!.single() as FlowPart.Scope).scope
            assertEquals(language, result.language)
            assertEquals(BidiDirectionInput.Auto, result.authoredDirection)
            // Starts with Hebrew, but the client must use the compiled result literally.
            assertEquals(BidiResolvedDirection.Ltr, result.resolvedDirection)
            assertEquals("אב Latin", textOf((result.parts.single() as FlowPart.Inline).spans))
        }
        assertThrows(IllegalArgumentException::class.java) { decode(Wire().document { scope(1, null, mode = 1) }) }
        assertThrows(IllegalArgumentException::class.java) { decode(Wire().document { scope(1, null, authored = 1, resolved = 1) }) }
        assertThrows(IllegalStateException::class.java) { decode(Wire().document { scope(1, null, mode = 2) }) }
        assertThrows(IllegalStateException::class.java) { decode(Wire().document { u32(1); byte(3); repeat(8) { byte(0) } }) }
    }

    @Test fun scopeDepthAndTruncationFailBeforeAnUnboundedContentTreeCanBeAllocated() {
        val valid = Wire().document { scope(15, "") }
        assertEquals(1, decode(valid).sections.size)
        assertThrows(IllegalArgumentException::class.java) { decode(Wire().document { scope(16, null) }) }
        // Every prefix ends before the last mandatory count; no valid partial document.
        for (length in valid.indices) assertThrows("prefix $length", IllegalArgumentException::class.java) {
            decode(valid.copyOf(length))
        }
        assertThrows(IllegalArgumentException::class.java) { decode(Wire().document { u32(Int.MAX_VALUE) }) }
    }

    @Test fun scopedFiguresAndRichCaptionsKeepOrderedSinksAndSingleMediaOwnership() {
        val caption = listOf(block(listOf(text("caption-before"), scope(listOf(text("caption-inner")), ""), text("caption-after"))))
        val image = figure(caption)
        val content = block(listOf(text("before"), scope(listOf(FlowPart.ImageFigure(image), text("inside")), "he"), text("after")))
        val ordered = mutableListOf<String>()
        content.visitSpanRuns { spans, _ -> ordered += spans.map { if (it.image != null) "IMAGE" else it.text } }
        assertEquals(listOf("before", "IMAGE", "caption-before", "caption-inner", "caption-after", "inside", "after"), ordered)
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(content)))),
            captionBlocks = listOf(content))
        val entry = Entry("Scope", emptyList(), "language", "English", "en",
            listOf(Section(2, "Section", listOf(Block("table", 0, emptyList(), table = table)))),
            listOf(Reference(1, 1, "", emptyList(), blocks = listOf(content))), media = listOf(Media("Image.svg", "image", "Catalog")))
        assertEquals(3, entry.inlineImages.size) // caption, cell, reference; no duplicate inactive payloads
        assertEquals(EntryLink("Exact#title", ""), image.content.span.entryLink())
        assertThrows(IllegalArgumentException::class.java) { entry.copy(media = emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { image.copy(caption = listOf(Span("text", "duplicate"))) }
        assertThrows(IllegalArgumentException::class.java) { table.copy(caption = listOf(Span("text", "duplicate"))) }
    }

    @Test fun sevenListRolesRetainTheirOwnerAndNoScopeInventsAMarkerOrParagraph() {
        val roles = listOf("list_item", "definition", "example", "quotation", "term", "list_detail", "indent")
        for (role in roles) {
            val value = block(listOf(scope(listOf(text("body"), FlowPart.ImageFigure(figure())))), role, 3, "#*:我", "7")
            assertEquals(role, value.kind); assertEquals(3, value.depth); assertEquals("#*:我", value.listPath); assertEquals("7", value.number)
            assertTrue(value.spans.isEmpty()); assertEquals(1, value.flow!!.size)
            assertThrows(IllegalArgumentException::class.java) { value.copy(spans = listOf(Span("text", "duplicate"))) }
        }
        assertThrows(IllegalArgumentException::class.java) { block(listOf(text("body")), "heading") }
        assertThrows(IllegalArgumentException::class.java) { block(listOf(text("body")), depth = 1) }
        assertThrows(IllegalArgumentException::class.java) {
            BidiScope(BidiMode.IsolateOverride, null, BidiResolvedDirection.Ltr, null, emptyList())
        }
    }
    @Test fun anonymousScopeOffsetsKeepAuthoredControlsAndNeverExposeGeneratedFigureAnchors() {
        val authored = "A\u2067\u202eאב\u202c\u2069\ud83d\ude80"
        val parts = listOf(text(authored), scope(listOf(text("inside"), FlowPart.ImageFigure(figure()), text("after")), ""))
        val content = anonymousFlowContent(block(parts), AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", CellTextAlign.Right))
        val map = AnonymousFlowOffsets.build(content) { textOf(it.spans) }
        assertEquals(authored + "insideafter", map.logicalText)
        assertFalse(map.logicalText.contains('\ufffc'))
        assertEquals(1, map.figures.size)
        val anchor = map.figures.single()
        assertEquals('\ufffc', map.nativeText[anchor.nativeOffset])
        assertEquals(authored.length + 6, anchor.logicalOffset)
        assertEquals("", anchor.event.captionContext.language)
        assertEquals(CellTextAlign.Right, anchor.event.captionContext.textAlign)
        for (offset in 0..map.logicalText.length)
            assertEquals(offset, map.logicalOffset(map.nativeOffset(offset)))
        val recovered = map.nativeRanges(0, map.logicalText.length).joinToString("") {
            map.nativeText.substring(it.first, it.last + 1)
        }
        assertEquals(authored + "insideafter", recovered)
        assertEquals(authored.count { it == '\u2067' }, map.logicalText.count { it == '\u2067' })
    }

    @Test fun anonymousScopesUseCompiledAutoAndResetLanguageWithoutParagraphShards() {
        val child = BidiScope(BidiMode.IsolateOverride, BidiDirectionInput.Ltr, BidiResolvedDirection.Ltr, "",
            listOf(text("אב"), FlowPart.ImageFigure(figure())))
        val parent = BidiScope(BidiMode.Isolate, BidiDirectionInput.Auto, BidiResolvedDirection.Ltr, "he",
            listOf(text("אב"), FlowPart.Scope(child), text("tail")))
        val content = anonymousFlowContent(block(listOf(FlowPart.Scope(parent))),
            AnonymousFlowContext(BidiResolvedDirection.Rtl, "en", null))
        val map = AnonymousFlowOffsets.build(content) { textOf(it.spans) }
        assertEquals("\u2066אב\u2066\u202dאב\ufffc\u202c\u2069tail\u2069", map.nativeText)
        assertEquals("אבאבtail", map.logicalText)
        assertFalse(map.nativeText.contains('\n'))
        assertEquals(listOf("he", "", "he"), content.events.filterIsInstance<AnonymousFlowEvent.Inline>().map { it.context.language })
        assertEquals("", map.figures.single().event.captionContext.language)
        assertEquals(BidiResolvedDirection.Ltr, map.figures.single().event.captionContext.direction)
        assertEquals(1, content.events.filterIsInstance<AnonymousFlowEvent.FigureObject>().size)
    }

    // Pure counterpart of the existing styledTextAnnotation emission; the Compose control also
    // checks the actual prepared native stream, so this is not evidence of rendered bidi behavior.
    private fun inlineLayoutText(event: AnonymousFlowEvent.Inline): String = buildString {
        event.layoutSpans.forEach { span ->
            val opener = when (span.direction) { "ltr" -> '\u2066'; "rtl" -> '\u2067'; "auto" -> '\u2068'; else -> null }
            opener?.let { append(it) }
            append(if (span.image != null) "\ufffc" else if (span.kind == "line_break") "\n" else span.text)
            append(span.trail)
            if (opener != null) append('\u2069')
        }
    }

    @Test fun onlyExplicitContainingScopeSuppressesSpanOwnersAndKeepsEveryNestedScope() {
        val authored = "A\u2067\u05d0\u2069\ud83d\ude80"
        val outside = listOf(Span("text", "outside", direction = "rtl"))
        val first = Span("link", authored, "Exact#title", trail = "!", language = "he",
            direction = "rtl", bold = true, tooltip = "advice", targetFragment = "")
        val runs = listOf(first, Span("text", "two", direction = "ltr"), Span("text", "three", direction = "auto"))
        val same = BidiScope(BidiMode.Isolate, BidiDirectionInput.Rtl, BidiResolvedDirection.Rtl, "",
            listOf(FlowPart.Inline(listOf(Span("text", "same", direction = "rtl")))))
        val opposite = BidiScope(BidiMode.IsolateOverride, BidiDirectionInput.Ltr, BidiResolvedDirection.Ltr, null,
            listOf(FlowPart.Inline(listOf(Span("text", "other", direction = "ltr")))))
        val parent = BidiScope(BidiMode.Isolate, BidiDirectionInput.Auto, BidiResolvedDirection.Rtl, "he",
            runs.map { FlowPart.Inline(listOf(it)) } + listOf(FlowPart.Scope(same), FlowPart.Scope(opposite)))
        val content = anonymousFlowContent(block(listOf(FlowPart.Inline(outside), FlowPart.Scope(parent), FlowPart.Inline(outside))),
            AnonymousFlowContext(BidiResolvedDirection.Rtl, "en", null))
        val events = content.events.filterIsInstance<AnonymousFlowEvent.Inline>()
        assertEquals(listOf(null, 0, 0, 0, 1, 2, null), events.map { it.containingScopeId })
        assertSame(outside, events.first().layoutSpans)
        assertSame(outside, events.last().layoutSpans)
        assertSame(first, events[1].spans.single())
        assertEquals(first.copy(direction = ""), events[1].layoutSpans.single())
        assertEquals(listOf("rtl", "ltr", "auto"), events.subList(1, 4).map { it.spans.single().direction })
        assertTrue(events.subList(1, 6).all { it.layoutSpans.all { span -> span.direction.isEmpty() } })
        assertEquals(listOf("en", "he", "he", "he", "", "he", "en"), events.map { it.context.language })
        val offsets = AnonymousFlowOffsets.build(content,
            { event, text -> anonymousInlineSemantic(event.layoutSpans, text) }, ::inlineLayoutText)
        assertEquals("\u2067outside\u2069\u2067" + authored + "!twothree\u2067same\u2069\u2066\u202dother\u202c\u2069\u2069\u2067outside\u2069",
            offsets.nativeText)
        assertEquals("outside" + authored + "!twothreesameotheroutside", offsets.logicalText)
        for (offset in 0..offsets.logicalText.length)
            assertEquals(offset, offsets.logicalOffset(offsets.nativeOffset(offset)))
        assertThrows(IllegalStateException::class.java) {
            anonymousInlineSemantic(events[1].layoutSpans, "\u2067" + authored + "!\u2069")
        }
    }

    @Test fun scopedImageOffsetsAndCaptionLocalOwnersPreserveSemanticOrderAndActions() {
        val action = ImageMapAction(ImageMapActionKind.Internal, "Mapped-title", "", "Mapped region")
        val map = ImageMap(ImageMapDescription.None,
            listOf(ImageMapRegion(ImageMapShape.Rect, listOf(0.0, 0.0, 10.0, 10.0), action)))
        val imageSpan = Span("text", "", direction = "auto", image = InlineImage("Image.svg", alt = "inline alt", map = map))
        val captionPlain = listOf(Span("link", "caption", "Caption-target", direction = "rtl"))
        val captionBlock = block(listOf(FlowPart.Inline(captionPlain),
            scope(listOf(FlowPart.Inline(listOf(Span("text", " child", direction = "ltr")))), "",
                BidiResolvedDirection.Ltr)))
        val parent = block(listOf(scope(listOf(FlowPart.Inline(listOf(Span("text", "before ", direction = "rtl"), imageSpan)),
            FlowPart.ImageFigure(figure(listOf(captionBlock))), FlowPart.Inline(listOf(Span("text", " after", direction = "ltr")))), "")))
        val content = anonymousFlowContent(parent, AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
        val event = content.events.filterIsInstance<AnonymousFlowEvent.Inline>().first()
        assertSame(imageSpan.image, event.layoutSpans[1].image)
        assertSame(map, event.layoutSpans[1].image!!.map)
        assertEquals(action, event.layoutSpans[1].image!!.map!!.regions.single().action)
        val offsets = AnonymousFlowOffsets.build(content,
            { inline, text -> anonymousInlineSemantic(inline.layoutSpans, text) }, ::inlineLayoutText)
        assertEquals("\u2067before \ufffc\ufffc after\u2069", offsets.nativeText)
        assertEquals("before inline alt after", offsets.logicalText)
        val anchor = offsets.figures.single()
        val caption = anonymousFlowContent(captionBlock, anchor.event.captionContext)
        val captionEvents = caption.events.filterIsInstance<AnonymousFlowEvent.Inline>()
        assertNull(captionEvents.first().containingScopeId)
        assertSame(captionPlain, captionEvents.first().layoutSpans)
        assertEquals(0, captionEvents.last().containingScopeId)
        assertEquals("", caption.context.language)
        assertEquals("", captionEvents.last().context.language)
        val captionOffsets = AnonymousFlowOffsets.build(caption,
            { inline, text -> anonymousInlineSemantic(inline.layoutSpans, text) }, ::inlineLayoutText)
        assertEquals("\u2067caption\u2069\u2066 child\u2069", captionOffsets.nativeText)
        val selection = AnonymousFlowSelection.build(offsets) { captionOffsets.logicalText }
        assertEquals("before inline altcaption child after", selection.text)
        assertFalse(selection.text.contains('\ufffc'))
        assertFalse(selection.text.contains('\u2067'))
        val child = selection.segments.filterIsInstance<AnonymousSelectionSegment.Figure>().single()
        assertEquals("altcaption child a", selection.text.substring(child.start - 3, child.end + 2))
        assertEquals(child.nativeStart, selection.nativeOffset(child.start + 2))
        assertEquals(child.end, selection.semanticOffset(child.nativeEnd))
        val replacement = offsets.authored.single { it.replacement }
        assertEquals("\ufffc", offsets.nativeText.substring(replacement.nativeStart, replacement.nativeEnd))
    }

    @Test fun semanticCaptionSegmentRetainsSourceOrderAndKeepsRichNewlinesOutOfNativeParent() {
        val caption = "caption\nאב\ud83d\ude80"
        val content = anonymousFlowContent(block(listOf(text("before"), scope(listOf(
            FlowPart.ImageFigure(figure()), text("after"))), text("tail"))),
            AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
        val offsets = AnonymousFlowOffsets.build(content) { textOf(it.spans) }
        val selection = AnonymousFlowSelection.build(offsets) { caption }
        assertEquals("before" + caption + "aftertail", selection.text)
        assertFalse(offsets.nativeText.contains('\n'))
        val child = selection.segments.filterIsInstance<AnonymousSelectionSegment.Figure>().single()
        assertEquals(6, child.start); assertEquals(6 + caption.length, child.end)
        assertSame(child, selection.at(child.start + 2))
        assertEquals(child.nativeStart, selection.nativeOffset(child.start + 2))
        assertEquals(child.start, selection.semanticOffset(child.nativeStart))
        assertEquals(child.end, selection.semanticOffset(child.nativeEnd))
        assertEquals("aftertail", selection.text.substring(child.end))
        assertEquals(1, selection.text.windowed(caption.length).count { it == caption })
    }

}
