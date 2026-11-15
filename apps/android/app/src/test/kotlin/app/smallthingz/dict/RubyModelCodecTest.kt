package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal S data-boundary controls. No producer, layout, auto-hiding or graphical fidelity claim. */
class RubyModelCodecTest {
    private fun text(value: String) = Span("text", value)
    private fun base(vararg spans: Span, context: RubyOwner = RubyOwner(InlineFontSnapshot())) =
        RubyBase(context, emptyList(), spans.toList())
    private fun annotation(vararg spans: Span, start: Long = 0, count: Long = 1, level: Long = 0,
        context: RubyOwner = RubyOwner(InlineFontSnapshot()), before: List<Span> = emptyList(), after: List<Span> = emptyList(), explicit: Boolean = false) =
        RubyAnnotation(start, count, level, context, emptyList(), spans.toList(), before, after, explicit)
    private fun owner(bases: List<RubyBase>, annotations: List<RubyAnnotation> = emptyList()) =
        Span("text", "", ruby = Ruby(listOf(RubySegment(emptyList(), bases, annotations))))
    private fun simple() = owner(listOf(base(text("漢"))), listOf(annotation(text("かん"))))
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "Ruby", "language", "Japanese", "ja")
    private fun reject(label: String, bytes: ByteArray) = assertTrue(label, runCatching { read(bytes) }.isFailure)
    private fun invalid(label: String, make: () -> Any?) = assertTrue(label, runCatching(make).isFailure)
    private fun changed(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { it[offset] = value.toByte() }
    private fun changed32(bytes: ByteArray, offset: Int, value: Long) = bytes.copyOf().also { result ->
        repeat(4) { result[offset + it] = (value ushr (8 * it)).toByte() }
    }
    private fun replace(bytes: ByteArray, start: Int, end: Int, body: ByteArray) =
        bytes.copyOfRange(0, start) + body + bytes.copyOfRange(end, bytes.size)

    private enum class Sink { Display, Preamble, Body, Heading, Cell, NestedCell, CellBlocks,
        TableCaption, TableRichCaption, Container, Reference, ReferenceBlocks,
        FigureCaption, FigureRichCaption, FlowInline, FlowFigure, ScopeInline, ScopeFigure }

    /** Independent little-endian fixture writer, deliberately not the production encoder. */
    private class Wire(private val version: Char = 'S') {
        private val out = ByteArrayOutputStream()
        val at = linkedMapOf<String, Int>()
        var rootOverride: ((String) -> Unit)? = null
        private var selected = emptyList<Span>()
        private fun mark(name: String) { check(at.put(name, out.size()) == null) }
        private fun byte(value: Int) { out.write(value) }
        private fun u16(value: Int) { repeat(2) { byte(value ushr (8 * it)) } }
        private fun u32(value: Long) { repeat(4) { byte((value ushr (8 * it)).toInt()) } }
        private fun f32(value: Float) = u32(value.toRawBits().toLong() and 0xffff_ffffL)
        private fun string(value: String, label: String? = null) {
            val bytes = value.encodeToByteArray()
            if (label != null) mark(label)
            u32(bytes.size.toLong())
            if (label != null) mark("$label.bytes")
            out.write(bytes)
        }
        private fun length(value: Float = 0f) { byte(0); f32(value) }
        private fun spans(values: List<Span>, label: String) {
            mark("$label.count"); u32(values.size.toLong())
            values.forEachIndexed { index, value -> span(value, "$label.$index") }
        }
        private fun root(label: String) {
            val override = rootOverride
            if (override == null) spans(selected, label) else override(label)
        }
        private fun span(value: Span, label: String) {
            mark("$label.start")
            byte(listOf("text", "link", "external_link", "line_break").indexOf(value.kind).also { require(it >= 0) })
            byte(listOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference")
                .indexOf(value.role).also { require(it >= 0) })
            byte((if (value.bold) 1 else 0) or (if (value.italic) 2 else 0) or (if (value.code) 4 else 0) or
                (if (value.small) 8 else 0) or (if (value.superscript) 16 else 0) or
                (if (value.subscript) 32 else 0) or (if (value.strike) 64 else 0) or (if (value.underline) 128 else 0))
            string(value.text, "$label.text"); string(value.target); string(value.trail)
            string(value.language); string(value.classes); string(value.direction); string(value.explanation)
            byte(if (value.foreground == null) 0 else 1); value.foreground?.let { string(it) }
            byte(if (value.background == null) 0 else 1); value.background?.let { string(it) }
            require(value.linkPaint == null)
            val fields = (if (value.fontScale != null) 1 else 0) or (if (value.fontFeatures != null) 2 else 0) or
                (if (value.inlineStyle != null) 8 else 0) or (if (value.fontFamily != null) 16 else 0)
            byte(fields)
            value.fontScale?.let { f32(it); byte(value.fontScaleBasis.ordinal) }
            value.fontFeatures?.let { byte(it.ordinal) }
            value.inlineStyle?.let { inlineStyle(it, "$label.style") }
            value.fontFamily?.let { require(it == ContainerFontFamily.SansSerif); byte(0) }
            mark("$label.image")
            val image = value.image
            byte(if (image == null) 0 else if (image.verticalAlign != null) 3 else 1)
            if (image != null) {
                require(image.heightPx == null && image.alt == null && image.tooltip == null && !image.border &&
                    image.map == null && image.staticPoster == null && image.svgLanguage == null && image.darkModeFilter == null)
                string(image.file); byte(if (image.widthPx == null) 0 else 1); image.widthPx?.let(::u32)
                image.verticalAlign?.let { byte(it.ordinal) }
            }
            byte(if (value.targetFragment == null) 0 else 1); value.targetFragment?.let { string(it) }
            mark("$label.tooltip"); byte(if (value.tooltip == null) 0 else 1); value.tooltip?.let { string(it) }
            if (version == 'S') {
                mark("$label.ruby"); byte(if (value.ruby == null) 0 else 1)
                value.ruby?.let { ruby(it, label) }
            } else require(value.ruby == null)
            mark("$label.end")
        }
        private fun fontSnapshot(value: InlineFontSnapshot, label: String) {
            mark("$label.flags")
            byte((if (value.fontScale != null) 1 else 0) or (if (value.small) 2 else 0) or
                (if (value.superscript) 4 else 0) or (if (value.subscript) 8 else 0) or (if (value.fontNormalized) 16 else 0))
            value.fontScale?.let { mark("$label.scale"); f32(it); byte(value.fontScaleBasis.ordinal) }
            mark("$label.face")
            byte((if (value.bold) 1 else 0) or (if (value.italic) 2 else 0) or (if (value.code) 4 else 0) or
                (if (value.fontFeatures != null) 8 else 0) or (if (value.fontFamily != null) 16 else 0))
            string(value.language, "$label.language"); string(value.classes)
            byte(listOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference")
                .indexOf(value.role).also { require(it >= 0) })
            value.fontFeatures?.let { byte(it.ordinal) }
            value.fontFamily?.let { require(it == ContainerFontFamily.SansSerif); byte(0) }
        }
        private fun inlineStyle(value: InlineTextStyle, label: String) {
            require(value.decoration == null)
            mark("$label.flags")
            byte((if (value.lineHeight != null) 2 else 0) or (if (value.baselineShift != null) 4 else 0) or
                (if (value.fontNormalized) 8 else 0) or (if (value.cursor != null) 16 else 0) or (if (value.wrap != null) 32 else 0))
            when (val height = value.lineHeight) {
                null -> Unit
                is InlineLineHeight.Computed -> { byte(0); f32(height.value.value); byte(height.value.fontScaleBasis.ordinal) }
                is InlineLineHeight.FontRelative -> {
                    byte(1); f32(height.factor); fontSnapshot(height.font, "$label.lineHeight.font")
                }
            }
            value.baselineShift?.let { f32(it.value); byte(it.fontScaleBasis.ordinal) }
            value.cursor?.let { byte(it.ordinal) }; value.wrap?.let { byte(it.ordinal) }
        }
        private fun rubyOwner(value: RubyOwner, label: String) {
            mark("$label.start"); fontSnapshot(value.font, "$label.font")
            string(value.direction, "$label.direction")
            mark("$label.inlineStyle"); byte(if (value.inlineStyle == null) 0 else 1)
            value.inlineStyle?.let { inlineStyle(it, "$label.style") }
            mark("$label.foreground"); byte(if (value.foreground == null) 0 else 1)
            value.foreground?.let { string(it, "$label.foreground.value") }
            mark("$label.background"); byte(if (value.background == null) 0 else 1)
            value.background?.let { string(it, "$label.background.value") }
            mark("$label.end")
        }
        private fun ruby(value: Ruby, label: String) {
            mark("$label.segments"); u32(value.segments.size.toLong())
            value.segments.forEachIndexed { index, segment ->
                val s = "$label.segment$index"
                spans(segment.gapBefore, "$s.gap"); mark("$s.bases"); u32(segment.bases.size.toLong())
                segment.bases.forEachIndexed { b, base ->
                    spans(base.gapBefore, "$s.base$b.gap"); rubyOwner(base.owner, "$s.base$b.owner")
                    spans(base.spans, "$s.base$b.body")
                }
                mark("$s.annotations"); u32(segment.annotations.size.toLong())
                segment.annotations.forEachIndexed { a, annotation ->
                    val name = "$s.annotation$a"
                    mark("$name.start"); u32(annotation.baseStart)
                    mark("$name.count"); u32(annotation.baseCount)
                    mark("$name.level"); u32(annotation.level)
                    rubyOwner(annotation.owner, "$name.owner")
                    spans(annotation.gapBefore, "$name.gap"); spans(annotation.spans, "$name.body")
                    spans(annotation.fallbackBefore, "$name.before"); spans(annotation.fallbackAfter, "$name.after")
                    mark("$name.explicit"); byte(if (annotation.explicitFallback) 1 else 0)
                }
            }
        }
        fun isolatedSpan(value: Span): ByteArray { span(value, "isolated"); return out.toByteArray() }
        private fun prefix(kind: Int, body: Boolean = false, level: Int = 0) {
            byte(kind); byte(0); byte(level)
            if (body) root("root") else spans(emptyList(), "prefix-${out.size()}")
            byte(0); string(""); string("")
        }
        private fun tail(heading: Boolean = false) {
            string(if (heading) "ruby-heading" else ""); string(if (heading) "old-ruby-heading" else "")
            repeat(4) { byte(0) } // alignment, paragraph style, Figure, anonymous flow
        }
        private fun paragraph(body: Boolean = true, literal: List<Span> = emptyList()) {
            if (body) prefix(0, true) else {
                byte(0); byte(0); byte(0); spans(literal, "sibling-${out.size()}"); byte(0); string(""); string("")
            }
            byte(0); tail()
        }
        private fun table(sink: Sink) {
            byte(1); byte(0)
            if (sink == Sink.TableCaption) root("root") else spans(emptyList(), "caption-${out.size()}")
            val cell = sink in listOf(Sink.Cell, Sink.NestedCell, Sink.CellBlocks)
            u32(if (cell) 1 else 0)
            if (cell) {
                u32(1); byte(0); u16(1); u16(1); byte(0)
                if (sink == Sink.Cell) root("root") else spans(emptyList(), "cell-${out.size()}")
                if (sink == Sink.NestedCell) table(Sink.Cell) else byte(0)
                byte(if (sink == Sink.CellBlocks) 1 else 0)
                if (sink == Sink.CellBlocks) { u32(1); paragraph() }
                byte(0) // cell style
            }
            byte(0) // table style
            byte(if (sink == Sink.TableRichCaption) 1 else 0)
            if (sink == Sink.TableRichCaption) { u32(1); paragraph() }
        }
        private fun figure(sink: Sink) {
            byte(2); byte(0); byte(0); byte(0) // Missing, Thumbnail, ordinary placement, no clear
            repeat(12) { length() }; f32(1f); length(18f)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            span(Span("link", "Missing", "File:Missing.png"), "missing-${out.size()}")
            length(40f); length(18f); byte(0)
            if (sink == Sink.FigureCaption) root("root") else spans(emptyList(), "figure-caption-${out.size()}")
            val rich = sink != Sink.FigureCaption
            byte(if (rich) 1 else 0); if (rich) { u32(1); paragraph() }
            byte(0); byte(0) // caption align and frame minimum
        }
        private fun body(sink: Sink, containers: Int) {
            when (sink) {
                Sink.Body, Sink.ReferenceBlocks -> paragraph()
                Sink.Heading -> { prefix(9, true, 2); byte(0); tail(true) }
                Sink.Container -> {
                    repeat(containers) { prefix(13); byte(0); tail(); u32(0); u32(1) }
                    paragraph()
                }
                Sink.FigureCaption, Sink.FigureRichCaption -> {
                    prefix(0); byte(0); string(""); string(""); byte(0); byte(0); figure(sink); byte(0)
                }
                Sink.FlowInline, Sink.FlowFigure, Sink.ScopeInline, Sink.ScopeFigure -> {
                    prefix(0); byte(0); string(""); string(""); byte(0); byte(0); byte(0); byte(1); u32(1)
                    if (sink == Sink.ScopeInline || sink == Sink.ScopeFigure) {
                        byte(2); byte(0); byte(1); byte(0); byte(1); string("ja"); u32(1)
                    }
                    if (sink == Sink.FlowFigure || sink == Sink.ScopeFigure) { byte(1); figure(Sink.FigureRichCaption) }
                    else { byte(0); root("root") }
                }
                else -> { prefix(12); table(sink); tail() }
            }
        }
        private fun clearRule() {
            prefix(11); byte(0); tail(); byte(2); length(1f); byte(0); repeat(4) { length() }; byte(0)
        }
        private fun headingStyle(extensions: Boolean) {
            u32((1 or 2 or 16 or 2048 or 4096 or 65536 or 4194304).toLong())
            repeat(8) { length() }; byte(0); byte(0); byte(0); f32(1f); byte(0)
            byte(1); f32(1f); byte(1); byte(0); string("ja"); string(""); byte(0); byte(0)
            if (extensions) byte(0)
        }
        fun document(values: List<Span>, sink: Sink = Sink.Display, features: Int = 0,
            alignment: Boolean = false, clear: Boolean = false, containers: Int = 1,
            headingTitle: String = "漢（かん）"): ByteArray {
            selected = values
            out.write("DPR$version".encodeToByteArray())
            if (sink == Sink.Display) root("root") else spans(emptyList(), "display")
            val bodyOwner = sink !in listOf(Sink.Display, Sink.Preamble, Sink.Reference, Sink.ReferenceBlocks)
            val section = bodyOwner || alignment || clear
            u32(if (section) 1 else 0)
            if (section) {
                byte(2); string(if (sink == Sink.Heading) headingTitle else "Body")
                string(if (sink == Sink.Heading) "ruby-heading" else "")
                string(if (sink == Sink.Heading) "old-ruby-heading" else "")
                u32((if (bodyOwner) 1L else 0L) + (if (alignment) 1L else 0L) + (if (clear) 1L else 0L))
                if (bodyOwner) body(sink, containers)
                if (alignment) paragraph(false, listOf(Span("text", "", image = InlineImage("Probe.svg", 20,
                    verticalAlign = InlineImageVerticalAlign.Baseline))))
                if (clear) clearRule()
            }
            if (sink == Sink.Preamble) root("root") else spans(emptyList(), "preamble")
            u32(0); u32(0) // organization lexemes and other sections
            val reference = sink == Sink.Reference || sink == Sink.ReferenceBlocks
            u32(if (reference) 1 else 0)
            if (reference) {
                byte(1); u32(1); string("ruby-ref")
                if (sink == Sink.Reference) root("root") else spans(emptyList(), "reference")
                byte(if (sink == Sink.ReferenceBlocks) 1 else 0)
                if (sink == Sink.ReferenceBlocks) { u32(1); paragraph() }
            }
            u32(if (alignment) 1 else 0)
            if (alignment) { string("Probe.svg"); byte(0); string("Original media") }
            if (version >= 'P') {
                mark("features"); val flags = features or (if (sink == Sink.Heading) 2 else 0); byte(flags)
                if (sink == Sink.Heading) { u32(1); u32(0); headingStyle(flags and 16 != 0) }
            }
            return out.toByteArray()
        }
        /** Produces invalid depth without first asking the typed constructor to accept it. */
        fun chain(depth: Int, label: String) {
            mark("$label.count"); u32(1)
            fun nested(remaining: Int, name: String) {
                if (remaining == 0) { span(Span("text", "漢"), name); return }
                val prefix = Wire('R').isolatedSpan(Span("text", ""))
                out.write(prefix); byte(1); u32(1); u32(0); u32(1); u32(0)
                out.write(ByteArray(18)); u32(1) // Required empty declaring owner adds items, not depth.
                nested(remaining - 1, "$name.child"); u32(0)
            }
            nested(depth, "$label.0")
        }
        /** Base count fits alone; 600,000 additional required owners exceed the aggregate budget. */
        fun aggregateBudget(label: String) {
            mark("$label.count"); u32(1); out.write(Wire('R').isolatedSpan(Span("text", "")))
            byte(1); u32(1); u32(0); u32(600_000)
            val emptyBase = ByteArray(26) // gap count0, default owner18, body count0.
            repeat(600_000) { out.write(emptyBase) }
            u32(0)
        }
    }

    private fun selected(entry: Entry, sink: Sink): Span {
        fun block(value: Block): Span = value.spans.single()
        val body by lazy { entry.sections.single().blocks.first() }
        return when (sink) {
            Sink.Display -> entry.displayTitle.single()
            Sink.Preamble -> entry.preamble.single()
            Sink.Body, Sink.Heading -> block(body)
            Sink.Container -> block(body.container!!.blocks.single())
            Sink.Cell -> body.table!!.rows.single().single().spans.single()
            Sink.NestedCell -> body.table!!.rows.single().single().nestedTable!!.rows.single().single().spans.single()
            Sink.CellBlocks -> block(body.table!!.rows.single().single().blocks!!.single())
            Sink.TableCaption -> body.table!!.caption.single()
            Sink.TableRichCaption -> block(body.table!!.captionBlocks!!.single())
            Sink.Reference -> entry.references.single().spans.single()
            Sink.ReferenceBlocks -> block(entry.references.single().blocks!!.single())
            Sink.FigureCaption -> body.figure!!.caption.single()
            Sink.FigureRichCaption -> block(body.figure!!.captionBlocks!!.single())
            Sink.FlowInline -> (body.flow!!.single() as FlowPart.Inline).spans.single()
            Sink.FlowFigure -> block((body.flow!!.single() as FlowPart.ImageFigure).figure.captionBlocks!!.single())
            Sink.ScopeInline -> ((body.flow!!.single() as FlowPart.Scope).scope.parts.single() as FlowPart.Inline).spans.single()
            Sink.ScopeFigure -> block(((body.flow!!.single() as FlowPart.Scope).scope.parts.single() as FlowPart.ImageFigure)
                .figure.captionBlocks!!.single())
        }
    }

    @Test fun typedOwnersRetainEmptyReadingsNestedActionsAndOrdinaryOwnerEffectsWithoutSyntheticText() {
        val target = Span("link", "漢", "Base target", targetFragment = "base", language = "ja", bold = true)
        val reading = Span("external_link", "かん", "https://example.test/reading", italic = true, tooltip = "Reading tip")
        val rp = Span("link", "〈", "Fallback target", targetFragment = "rp")
        val nested = owner(listOf(base(target)), listOf(annotation(reading, before = listOf(rp), after = listOf(text("〉")), explicit = true)))
        val root = owner(listOf(base(nested), base()), listOf(annotation(count = 2)))
        val policy = InlineTextStyle(lineHeight = InlineLineHeight.Computed(InlineComputedLength(24f, FontScaleBasis.CssPx)),
            baselineShift = InlineComputedLength(-2f, FontScaleBasis.CssPx), cursor = InlineCursor.Help, wrap = TextWrap.BreakWord)
        val styled = root.copy(language = "ja", direction = "rtl", bold = true, inlineStyle = policy,
            fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody, fontFeatures = FontFeaturePolicy.Normal)
        assertEquals("", styled.text); assertEquals("", styled.trail); assertNull(styled.image)
        assertSame(root.ruby, styled.ruby); assertSame(policy, styled.inlineStyle)
        val ruby = checkNotNull(styled.ruby)
        assertTrue(ruby.segments.single().annotations.single().spans.isEmpty())
        assertTrue(ruby.segments.single().bases[1].spans.isEmpty())
        val inner = checkNotNull(ruby.segments.single().bases.first().spans.single().ruby)
        assertSame(target, inner.segments.single().bases.single().spans.single())
        assertSame(reading, inner.segments.single().annotations.single().spans.single())
        assertSame(rp, inner.segments.single().annotations.single().fallbackBefore.single())
        assertEquals(EntryLink("Fallback target", "rp"), rp.entryLink())
        for (change in listOf<() -> Span>({ root.copy(kind = "link", target = "X") }, { root.copy(text = "x") },
            { root.copy(target = "X") }, { root.copy(trail = "x") }, { root.copy(targetFragment = "x") },
            { root.copy(image = InlineImage("Probe.svg")) }, { root.copy(inlineStyle = InlineTextStyle(wrap = TextWrap.NoWrap)) }))
            invalid("Illegal Ruby owner", change)
        for (scale in listOf(Float.NaN, -.25f)) {
            invalid("Ruby owner scale must be finite and nonnegative") { root.copy(fontScale = scale) }
            val legacyScale = checkNotNull(Span("text", "Legacy", fontScale = scale).fontScale)
            if (scale.isNaN()) assertTrue(legacyScale.isNaN()) else assertEquals(scale, legacyScale, 0f)
        }
        for (marker in listOf("wikidict-media", "wikidict-media-file-Probe.svg")) {
            val legacy = Span("text", "Legacy", classes = "ordinary $marker retained")
            assertEquals(legacy, read(Wire('O').document(listOf(legacy))).displayTitle.single())
            invalid("Ruby root cannot own a media marker") { root.copy(classes = legacy.classes) }
            val wire = Wire(); val bytes = wire.document(listOf(root))
            val prefix = Wire('R').isolatedSpan(legacy.copy(text = ""))
            reject("Forged root media marker", replace(bytes, wire.at.getValue("root.0.start"),
                wire.at.getValue("root.0.ruby"), prefix))
        }
        val malformed = "\ud800"
        for (field in listOf("language", "classes", "direction", "explanation")) {
            val legacy = when (field) {
                "language" -> Span("text", "Legacy", language = malformed)
                "classes" -> Span("text", "Legacy", classes = malformed)
                "direction" -> Span("text", "Legacy", direction = malformed)
                else -> Span("text", "Legacy", explanation = malformed)
            }
            assertNull(legacy.ruby)
            assertEquals(malformed, when (field) {
                "language" -> legacy.language
                "classes" -> legacy.classes
                "direction" -> legacy.direction
                else -> legacy.explanation
            })
            invalid("Malformed Ruby root $field") { legacy.copy(text = "", ruby = root.ruby) }
        }
        for (foreground in listOf(true, false)) {
            val legacy = if (foreground) Span("text", "Legacy", foreground = "bad")
                else Span("text", "Legacy", background = "bad")
            assertNull(legacy.ruby)
            assertEquals("bad", if (foreground) legacy.foreground else legacy.background)
            invalid("Noncanonical Ruby root paint") { legacy.copy(text = "", ruby = root.ruby) }
            invalid("Noncanonical Ruby child paint") { owner(listOf(base(legacy))) }
        }
        // VT is not a CSS class delimiter: this remains one ordinary token, including inside Ruby.
        val ordinaryClass = "plain\u000bwikidict-media"
        val classOwner = root.copy(classes = ordinaryClass)
        val classChild = owner(listOf(base(text("base").copy(classes = ordinaryClass))))
        assertEquals(listOf(classOwner, classChild), read(Wire().document(listOf(classOwner, classChild))).displayTitle)
        val decoded = read(Wire().document(listOf(styled), features = 16)).displayTitle.single()
        assertEquals(styled, decoded)
        val empty = owner(listOf(base()))
        assertEquals(empty, read(Wire().document(listOf(empty))).displayTitle.single())

        val declaringFont = InlineFontSnapshot(fontScale = 1.5f, fontScaleBasis = FontScaleBasis.NormalBody,
            language = "ja", fontFeatures = FontFeaturePolicy.Normal, fontFamily = ContainerFontFamily.SansSerif)
        val declaringStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1.25f, declaringFont),
            baselineShift = InlineComputedLength(-2f, FontScaleBasis.CssPx), cursor = InlineCursor.Help, wrap = TextWrap.BreakWord)
        val baseContext = RubyOwner(declaringFont, "ltr", declaringStyle, "#123456", "#abcdef")
        val readingFont = InlineFontSnapshot(fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody, language = "ja")
        val readingContext = RubyOwner(readingFont, "rtl", InlineTextStyle(
            lineHeight = InlineLineHeight.Computed(InlineComputedLength(7f, FontScaleBasis.CssPx))))
        invalid("Declaring contexts do not relax an ordinary empty cursor Span") {
            Span("text", "", inlineStyle = InlineTextStyle(cursor = InlineCursor.Help))
        }
        invalid("Declaring contexts do not relax an ordinary empty wrapping Span") {
            Span("text", "", inlineStyle = InlineTextStyle(wrap = TextWrap.BreakWord))
        }
        val overridingChild = target.copy(fontScale = 8f, fontScaleBasis = FontScaleBasis.CssPx,
            bold = true, italic = true, code = true, small = true)
        val groups = owner(listOf(base(overridingChild, context = baseContext)),
            listOf(annotation(context = readingContext)))
        val groupWire = Wire(); val groupBytes = groupWire.document(listOf(groups), features = 20)
        val decodedGroups = read(groupBytes).displayTitle.single()
        assertEquals(groups, decodedGroups)
        val group = checkNotNull(decodedGroups.ruby).segments.single()
        assertEquals(baseContext, group.bases.single().owner)
        assertEquals(readingContext, group.annotations.single().owner)
        assertEquals(overridingChild, group.bases.single().spans.single())
        assertTrue(group.annotations.single().spans.isEmpty())
        assertFalse(group.bases.single().owner.font.bold); assertFalse(group.bases.single().owner.font.italic)
        assertFalse(group.bases.single().owner.font.code); assertFalse(group.bases.single().owner.font.small)
        assertEquals(FontScaleBasis.NormalBody, group.bases.single().owner.font.fontScaleBasis)
        assertEquals(.5f, checkNotNull(group.annotations.single().owner.font.fontScale), 0f)
        for (direction in listOf("", "ltr", "rtl", "auto")) {
            val value = owner(listOf(base(context = baseContext.copy(direction = direction))))
            assertEquals(value, read(Wire().document(listOf(value), features = 20)).displayTitle.single())
        }
        for (direction in listOf("LTR", "rtl ", "isolate-override")) {
            invalid("Declaring owner direction is closed") { baseContext.copy(direction = direction) }
            assertEquals(direction, Span("text", "Legacy", direction = direction).direction)
        }
        for (different in listOf(declaringFont.copy(bold = true), declaringFont.copy(italic = true),
            declaringFont.copy(code = true), declaringFont.copy(fontScale = .75f), declaringFont.copy(language = "zh"),
            declaringFont.copy(fontFamily = null))) {
            invalid("Font-relative line-height requires its declaring font even without a shift") {
                baseContext.copy(inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1.25f, different)))
            }
        }
        invalid("Style normalization cannot invent a normalized declaring font") {
            RubyOwner(declaringFont, inlineStyle = InlineTextStyle(fontNormalized = true))
        }
        val normalizedFont = declaringFont.copy(fontNormalized = true)
        val normalizedStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1f, normalizedFont),
            baselineShift = InlineComputedLength(-1f, FontScaleBasis.CssPx), fontNormalized = true)
        val normalizedContext = RubyOwner(normalizedFont, inlineStyle = normalizedStyle)
        val normalizedGroups = owner(listOf(base(context = normalizedContext)))
        assertEquals(normalizedGroups, read(Wire().document(listOf(normalizedGroups), features = 4)).displayTitle.single())
        invalid("Shifted relative line-height retains normalized agreement") {
            normalizedContext.copy(inlineStyle = normalizedStyle.copy(fontNormalized = false))
        }
        val unshifted = normalizedContext.copy(inlineStyle = normalizedStyle.copy(baselineShift = null, fontNormalized = false))
        assertEquals(normalizedFont, unshifted.font)
        val inherited = InlineFontSnapshot()
        val equivalent = RubyOwner(inherited, inlineStyle = InlineTextStyle(
            lineHeight = InlineLineHeight.FontRelative(1.2f, InlineFontSnapshot(fontScale = 1f))))
        val canonical = equivalent.copy(inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1.2f, inherited)))
        assertEquals(owner(listOf(base(context = canonical))),
            read(Wire().document(listOf(owner(listOf(base(context = equivalent)))))).displayTitle.single())
        val ownerPath = "root.0.segment0.base0.owner"
        for (field in listOf("inlineStyle", "foreground", "background")) for (bad in listOf(2, 255))
            reject("Strict owner $field presence", changed(groupBytes, groupWire.at.getValue("$ownerPath.$field"), bad))
        reject("Invalid declaring direction", changed(groupBytes, groupWire.at.getValue("$ownerPath.direction.bytes"), 'x'.code))
        reject("Invalid declaring font flags", changed(groupBytes, groupWire.at.getValue("$ownerPath.font.flags"), 0x80))
        reject("Invalid declaring font scale", changed32(groupBytes, groupWire.at.getValue("$ownerPath.font.scale"), 0x7fc0_0000L))
        reject("Invalid declaring font UTF-8", changed(groupBytes, groupWire.at.getValue("$ownerPath.font.language.bytes"), 0xff))
        reject("Invalid declaring RGB", changed(groupBytes, groupWire.at.getValue("$ownerPath.foreground.value.bytes"), 'x'.code))
        val lhFace = groupWire.at.getValue("$ownerPath.style.lineHeight.font.face")
        reject("Wire relative font differs from declaring font", changed(groupBytes, lhFace, groupBytes[lhFace].toInt() or 1))
        for (color in listOf("bad", "#ABCDEF")) {
            invalid("Declaring foreground must be canonical") { baseContext.copy(foreground = color) }
            invalid("Declaring background must be canonical") { baseContext.copy(background = color) }
        }
    }

    @Test fun literalSPresenceFollowsEveryTooltipAndPreservesZeroOldFeatureEnvelope() {
        val ordinary = Span("link", "😀", "Target", trail = "!", targetFragment = "part", tooltip = "outer tip")
        val root = simple().copy(tooltip = "ruby tip")
        val last = text("後")
        val wire = Wire(); val bytes = wire.document(listOf(ordinary, root, last))
        val frozen = bytes.copyOf(); val entry = read(bytes)
        assertEquals(listOf(ordinary, root, last), entry.displayTitle)
        assertNull(entry.bodyAdjoining); assertTrue(entry.media.isEmpty()); assertTrue(entry.sections.isEmpty())
        assertEquals(0, bytes[wire.at.getValue("features")].toInt())
        for (index in 0..2) {
            val prefix = Wire('R').isolatedSpan(listOf(ordinary, root.copy(ruby = null), last)[index])
            val start = wire.at.getValue("root.$index.start"); val presence = wire.at.getValue("root.$index.ruby")
            assertArrayEquals(prefix, bytes.copyOfRange(start, presence))
            assertEquals(if (index == 1) 1 else 0, bytes[presence].toInt())
        }
        val child = "root.1.segment0.base0.body.0"
        assertEquals(0, bytes[wire.at.getValue("$child.ruby")].toInt())
        assertEquals(wire.at.getValue("$child.tooltip") + 1, wire.at.getValue("$child.ruby"))
        for (path in listOf("root.1.segment0.base0.owner", "root.1.segment0.annotation0.owner")) {
            val start = wire.at.getValue("$path.start"); val end = wire.at.getValue("$path.end")
            assertEquals("Required empty owner has no presence wrapper", 18, end - start)
            assertArrayEquals(ByteArray(18), bytes.copyOfRange(start, end))
        }
        assertEquals(wire.at.getValue("root.1.segment0.base0.gap.count") + 4,
            wire.at.getValue("root.1.segment0.base0.owner.start"))
        assertEquals(wire.at.getValue("root.1.segment0.base0.owner.end"), wire.at.getValue("root.1.segment0.base0.body.count"))
        assertEquals(wire.at.getValue("root.1.segment0.annotation0.level") + 4,
            wire.at.getValue("root.1.segment0.annotation0.owner.start"))
        assertEquals(wire.at.getValue("root.1.segment0.annotation0.owner.end"), wire.at.getValue("root.1.segment0.annotation0.gap.count"))
        assertArrayEquals(frozen, bytes)
        reject("S without semantic Ruby", Wire().document(listOf(ordinary, last)))
        reject("S with no spans", Wire().document(emptyList()))
    }

    @Test fun everyActualSpanSinkAndAuthoredHeadingCompanionPreserveTheSameTypedOwner() {
        val root = simple()
        for (sink in Sink.entries) {
            val bytes = Wire().document(listOf(root), sink)
            val entry = read(bytes)
            assertEquals(sink.name, root, selected(entry, sink))
            if (sink == Sink.Heading) {
                val section = entry.sections.single()
                assertEquals("漢（かん）", section.title)
                assertEquals("ruby-heading", section.anchor); assertEquals("old-ruby-heading", section.anchorFallback)
                assertNotNull(section.headingStyle)
            }
        }
        reject("Heading title must match terminal projection",
            Wire().document(listOf(root), Sink.Heading, headingTitle = "漢かん"))
        val block = Block("heading", 0, listOf(root), level = 2, anchor = "ruby-heading", anchorFallback = "old-ruby-heading")
        val style = read(Wire().document(listOf(root), Sink.Heading)).sections.single().headingStyle
        assertEquals("漢（かん）", Section(2, "漢（かん）", listOf(block), "ruby-heading", "old-ruby-heading", style).title)
        invalid("Model heading mismatch") { Section(2, "Wrong", listOf(block), "ruby-heading", "old-ruby-heading", style) }
        val directed = root.copy(direction = "rtl")
        val directedEntry = read(Wire().document(listOf(directed), Sink.Heading))
        assertEquals(directed, selected(directedEntry, Sink.Heading))
        assertEquals("漢（かん）", directedEntry.sections.single().title)
        assertEquals("漢（かん）", Section(2, "漢（かん）", listOf(block.copy(spans = listOf(directed))),
            "ruby-heading", "old-ruby-heading", style).title)
        val ordinaryHeading = text("漢（かん）")
        assertEquals(ordinaryHeading, selected(read(Wire('P').document(listOf(ordinaryHeading), Sink.Heading)), Sink.Heading))
        val directedOrdinary = ordinaryHeading.copy(direction = "rtl")
        invalid("Legacy non-Ruby heading direction remains forbidden") {
            Section(2, "漢（かん）", listOf(block.copy(spans = listOf(directedOrdinary))),
                "ruby-heading", "old-ruby-heading", style)
        }
        reject("Legacy wire heading direction remains forbidden",
            Wire('P').document(listOf(directedOrdinary), Sink.Heading))

        val baseLink = Span("link", "漢", "Base target", targetFragment = "base",
            explanation = "Base explanation", tooltip = "Base advisory")
        val readingLink = Span("external_link", "かん", "https://example.test/reading",
            explanation = "Reading explanation", tooltip = "Reading advisory")
        val hidden = baseLink.copy(target = "Hidden target", explanation = "Hidden explanation", tooltip = "Hidden advisory")
        val rp = Span("link", "〈", "Fallback target", explanation = "Fallback explanation", tooltip = "Fallback advisory")
        val metadataOwner = owner(listOf(base(baseLink)), listOf(
            annotation(readingLink, before = listOf(rp), after = listOf(text("〉")), explicit = true),
            annotation(hidden, level = 1)))
        val nested = read(Wire().document(listOf(metadataOwner), Sink.Container, containers = 2))
        val retained = nested.sections.single().blocks.single().container!!.blocks.single().container!!.blocks.single().spans.single()
        assertEquals(metadataOwner, retained)
        val retainedSegment = checkNotNull(retained.ruby).segments.single()
        assertEquals(EntryLink("Base target", "base"), retainedSegment.bases.single().spans.single().entryLink())
        assertEquals(readingLink, retainedSegment.annotations.first().spans.single())
        assertEquals(hidden, retainedSegment.annotations[1].spans.single())
        assertEquals(rp, retainedSegment.annotations.first().fallbackBefore.single())
        val expectedAbbreviations = listOf("漢" to "Base explanation", "かん" to "Reading explanation")
        val expectedDetails = listOf(
            Triple(TextDetailKind.Abbreviation, "漢", "Base explanation"),
            Triple(TextDetailKind.Abbreviation, "かん", "Reading explanation"),
            Triple(TextDetailKind.Advisory, "漢", "Base advisory"),
            Triple(TextDetailKind.Advisory, "かん", "Reading advisory"))
        assertEquals(expectedAbbreviations, nested.abbreviations.map { it.label to it.explanation })
        assertEquals(expectedDetails, nested.textDetails.map { Triple(it.kind, it.label, it.description) })
        val legacy = read(Wire('O').document(listOf(baseLink, readingLink), Sink.Container, containers = 2))
        assertEquals(expectedAbbreviations, legacy.abbreviations.map { it.label to it.explanation })
        assertEquals(expectedDetails, legacy.textDetails.map { Triple(it.kind, it.label, it.description) })
        assertEquals(listOf(baseLink, readingLink), legacy.sections.single().blocks.single().container!!
            .blocks.single().container!!.blocks.single().spans)

        val nestedCaption = owner(listOf(base(metadataOwner)))
        val figureEntry = read(Wire().document(listOf(nestedCaption), Sink.FigureCaption))
        val figureBlock = figureEntry.sections.single().blocks.single()
        val image = InlineImage("Sized.svg", 120, 90)
        val imageSpan = Span("text", "", image = image)
        val content = FigureContent.Image(imageSpan, FigureSizingPolicy.RequestedFit)
        val imageFigure = checkNotNull(figureBlock.figure).copy(content = content, caption = listOf(nestedCaption))
        val raw = mutableListOf<Span>()
        val specialized = mutableListOf<FigureContent>()
        val visitor = PresentationSpanVisitor { _, _ -> }
        visitor.onSpan = { raw.add(it) }
        visitor.visitFigureContent = { specialized.add(it) }
        visitor.figure(imageFigure, tableDepth = 0, contentDepth = 0)
        assertEquals(1, specialized.size); assertSame(content, specialized.single())
        assertFalse("Custom Figure root must not enter ordinary raw ownership", raw.any { it === imageSpan })
        assertEquals(listOf(nestedCaption, metadataOwner, baseLink, readingLink, rp,
            checkNotNull(metadataOwner.ruby).segments.single().annotations.first().fallbackAfter.single(), hidden), raw)
        val imageEntry = figureEntry.copy(sections = listOf(figureEntry.sections.single().copy(
            blocks = listOf(figureBlock.copy(figure = imageFigure)))), media = listOf(Media("Sized.svg", "image", "")))
        assertEquals(listOf(RasterImageOccurrence(image, FigureSizingPolicy.RequestedFit)), imageEntry.rasterImages)
        assertSame(image, imageEntry.inlineImages.single())
        invalid("A Ruby owner cannot replace a Missing media label") {
            FigureContent.Missing(nestedCaption, StyleLength(StyleLengthUnit.Px, 40f), StyleLength(StyleLengthUnit.Px, 18f))
        }
        invalid("A Ruby owner cannot replace the Image media span") {
            imageFigure.copy(content = FigureContent.Image(nestedCaption, FigureSizingPolicy.RequestedFit))
        }
    }

    @Test fun hiddenAnnotationsAndRpStillCountOldFeaturesWhileQAndRAreIndependentOptionalUnions() {
        val rich = Span("link", "漢", "Hidden target", targetFragment = "kept", fontFamily = ContainerFontFamily.SansSerif,
            inlineStyle = InlineTextStyle(wrap = TextWrap.BreakWord))
        val hidden = owner(listOf(base(text("漢"))), listOf(annotation(rich)))
        val rp = owner(listOf(base(text("漢"))), listOf(annotation(text("かん"), before = listOf(rich), explicit = true)))
        val groupFont = InlineFontSnapshot(fontFamily = ContainerFontFamily.SansSerif)
        val groupContext = RubyOwner(groupFont, inlineStyle = InlineTextStyle(
            lineHeight = InlineLineHeight.FontRelative(1.1f, groupFont), wrap = TextWrap.BreakWord))
        val emptyBaseContext = owner(listOf(base(context = groupContext)))
        val hiddenReadingContext = owner(listOf(base(text("漢"))), listOf(annotation(text("漢"), context = groupContext)))
        val emptyReadingContext = owner(listOf(base(text("漢"))), listOf(annotation(context = groupContext)))
        for (source in listOf(hidden, rp, emptyBaseContext, hiddenReadingContext, emptyReadingContext)) {
            val wire = Wire(); val bytes = wire.document(listOf(source), features = 20)
            assertEquals(source, read(bytes).displayTitle.single())
            reject("Missing family census in hidden/rp data", changed(bytes, wire.at.getValue("features"), 16))
            reject("Missing wrap census in hidden/rp data", changed(bytes, wire.at.getValue("features"), 4))
            reject("Unused cell-font feature", changed(bytes, wire.at.getValue("features"), 148))
        }
        reject("Unused inline-family feature", Wire().document(listOf(simple()), features = 4))
        for (q in listOf(false, true)) for (r in listOf(false, true)) {
            val entry = read(Wire().document(listOf(simple()), alignment = q, clear = r))
            assertEquals(simple(), entry.displayTitle.single())
            assertEquals(q, entry.inlineImages.isNotEmpty())
            assertEquals(r, entry.sections.flatMap { it.blocks }.any { it.ruleStyle?.clear == FigureClear.None })
            if (q) assertEquals(InlineImageVerticalAlign.Baseline, entry.inlineImages.single().verticalAlign)
        }
        val ordinary = text("Legacy body")
        assertEquals(ordinary, read(Wire('Q').document(listOf(ordinary), alignment = true)).displayTitle.single())
        assertEquals(ordinary, read(Wire('R').document(listOf(ordinary), clear = true)).displayTitle.single())
    }

    @Test fun malformedPresenceCountsRangesLevelsUtf8AndEveryTruncatedTailRefuse() {
        val root = owner(listOf(base(text("漢")), base(text("字"))), listOf(
            annotation(text("かん")), annotation(text("じ"), start = 1), annotation(text("kanji"), count = 2, level = 1)))
        val wire = Wire(); val bytes = wire.document(listOf(root))
        val segment = "root.0.segment0"; val a0 = "$segment.annotation0"; val a1 = "$segment.annotation1"; val a2 = "$segment.annotation2"
        for (value in listOf(2, 255)) {
            reject("Strict owner presence$value", changed(bytes, wire.at.getValue("root.0.ruby"), value))
            reject("Strict nested presence$value", changed(bytes, wire.at.getValue("$segment.base0.body.0.ruby"), value))
            reject("Strict fallback bool$value", changed(bytes, wire.at.getValue("$a0.explicit"), value))
        }
        for ((key, value) in listOf("root.0.segments" to 0L, "$segment.bases" to 0L,
            "$a0.count" to 0L, "$a0.start" to 0xffff_ffffL, "$a0.count" to 0xffff_ffffL,
            "$a1.start" to 0L, "$a1.level" to 1L, "$a2.level" to 3L, "$a2.level" to 0xffff_ffffL,
            "root.0.segments" to 0xffff_ffffL)) reject(key, changed32(bytes, wire.at.getValue(key), value))
        reject("Malformed UTF-8 in nested base", changed(bytes, wire.at.getValue("$segment.base0.body.0.text.bytes"), 0xff))
        for (size in 0 until bytes.size) reject("Truncation at $size", bytes.copyOf(size))
        reject("Trailing byte", bytes + byteArrayOf(0))
        for (version in listOf('Q', 'R')) reject("Old header cannot carry S tails", changed(bytes, 3, version.code))
        val unknown = runCatching { read(changed(bytes, 3, 'T'.code)) }.exceptionOrNull()
        assertEquals("Unsupported presentation format", unknown!!.message)
    }

    @Test fun gapAndFallbackValidationRejectsUnsupportedChildrenWithoutErasingTheirData() {
        val first = base(text("漢")); val next = RubyBase(RubyOwner(InlineFontSnapshot()), listOf(text(" \t\n\r\u000c")), listOf(text("字")))
        val segment = RubySegment(emptyList(), listOf(first, next), listOf(annotation(text("かん"))))
        val root = Span("text", "", ruby = Ruby(listOf(segment,
            RubySegment(listOf(text(" ")), listOf(base(text("後"))), emptyList()))))
        assertEquals(root, read(Wire().document(listOf(root))).displayTitle.single())
        for (gap in listOf(listOf(text("\u00a0")), listOf(text("x")), listOf(Span("link", " ", "Gap target")))) {
            invalid("Illegal gap") { root.copy(ruby = Ruby(listOf(segment.copy(bases = listOf(first, next.copy(gapBefore = gap)))))) }
        }
        invalid("First segment gap") { Ruby(listOf(segment.copy(gapBefore = listOf(text(" "))))) }
        invalid("First base gap") { Ruby(listOf(segment.copy(bases = listOf(first.copy(gapBefore = listOf(text(" "))))))) }
        invalid("First annotation level gap") { Ruby(listOf(segment.copy(annotations = listOf(annotation(text("a")).copy(gapBefore = listOf(text(" "))))))) }
        invalid("Unmarked rp") { annotation(text("a"), before = listOf(text("("))) }
        invalid("u32 overflow") { annotation(text("a"), count = 0x1_0000_0000L) }
        invalid("Negative range") { annotation(text("a"), start = -1) }
        for (child in listOf(Span("line_break", ""), Span("text", "", image = InlineImage("Probe.svg")))) {
            invalid("Invalid base child") { owner(listOf(base(child))) }
            invalid("Invalid annotation child") { owner(listOf(first), listOf(annotation(child))) }
            invalid("Invalid rp child") { owner(listOf(first), listOf(annotation(text("a"), before = listOf(child), explicit = true))) }
            val wire = Wire(); val bytes = wire.document(listOf(simple()))
            val key = "root.0.segment0.base0.body.0"
            reject("Wire child must refuse", replace(bytes, wire.at.getValue("$key.start"), wire.at.getValue("$key.end"),
                Wire().isolatedSpan(child)))
        }
        val explicit = owner(listOf(first), listOf(annotation(text("a"), before = listOf(text("(")), after = listOf(text(")")), explicit = true)))
        val wire = Wire(); val bytes = wire.document(listOf(explicit))
        reject("False explicit flag with real rp", changed(bytes, wire.at.getValue("root.0.segment0.annotation0.explicit"), 0))

        val allArrays = Span("text", "", ruby = Ruby(listOf(
            RubySegment(emptyList(), listOf(first, next), listOf(
                annotation(text("かん"), before = listOf(text("(")), after = listOf(text(")")), explicit = true),
                annotation(text("じ"), start = 1).copy(gapBefore = listOf(text(" "))))),
            RubySegment(listOf(text(" ")), listOf(base(text("後"))), emptyList()))))
        val arrays = Wire(); val arrayBytes = arrays.document(listOf(allArrays))
        assertEquals(allArrays, read(arrayBytes).displayTitle.single())
        for (marker in listOf("wikidict-media", "wikidict-media-file-Probe.svg")) {
            val marked = text(" ").copy(classes = "ordinary $marker retained")
            invalid("Media marker in nested Ruby base") { owner(listOf(base(owner(listOf(base(marked)))))) }
            invalid("Media marker in annotation") { owner(listOf(first), listOf(annotation(marked))) }
            invalid("Media marker in rp") { owner(listOf(first), listOf(annotation(text("a"), before = listOf(marked), explicit = true))) }
            for (key in listOf("root.0.segment1.gap.0", "root.0.segment0.base1.gap.0",
                "root.0.segment0.base0.body.0", "root.0.segment0.annotation1.gap.0",
                "root.0.segment0.annotation0.body.0", "root.0.segment0.annotation0.before.0",
                "root.0.segment0.annotation0.after.0")) {
                reject("Media marker $marker in $key", replace(arrayBytes, arrays.at.getValue("$key.start"),
                    arrays.at.getValue("$key.end"), Wire().isolatedSpan(marked)))
            }
        }

        val exactGap = text(" \t\n\r\u000c")
        val exactSegments = checkNotNull(allArrays.ruby).segments
        val exactGaps = allArrays.copy(ruby = Ruby(listOf(
            exactSegments[0].copy(
                bases = listOf(first, next.copy(gapBefore = listOf(exactGap))),
                annotations = listOf(exactSegments[0].annotations[0],
                    exactSegments[0].annotations[1].copy(gapBefore = listOf(exactGap)))),
            exactSegments[1].copy(gapBefore = listOf(exactGap)))))
        val nestedGaps = owner(listOf(base(exactGaps)))
        assertEquals(nestedGaps, read(Wire().document(listOf(nestedGaps))).displayTitle.single())
        for (trail in listOf(" ", "\t\n\r\u000c")) {
            val badGap = exactGap.copy(trail = trail)
            invalid("Segment gap trail must be empty") {
                Ruby(listOf(exactSegments[0], exactSegments[1].copy(gapBefore = listOf(badGap))))
            }
            invalid("Base gap trail must be empty") {
                Ruby(listOf(exactSegments[0].copy(bases = listOf(first, next.copy(gapBefore = listOf(badGap))))))
            }
            invalid("Annotation gap trail must be empty") {
                Ruby(listOf(exactSegments[0].copy(annotations = listOf(exactSegments[0].annotations[0],
                    exactSegments[0].annotations[1].copy(gapBefore = listOf(badGap))))))
            }
            for (key in listOf("root.0.segment1.gap.0", "root.0.segment0.base1.gap.0",
                "root.0.segment0.annotation1.gap.0")) {
                reject("Forged gap trail in $key", replace(arrayBytes, arrays.at.getValue("$key.start"),
                    arrays.at.getValue("$key.end"), Wire().isolatedSpan(badGap)))
            }
        }
        for (space in listOf(' ', '\u00a0')) {
            val body = Span("text", "a${space}b", trail = "${space}c")
            val positive = owner(listOf(base(owner(listOf(base(body)), listOf(
                annotation(body, before = listOf(body), after = listOf(body), explicit = true))))))
            assertEquals(positive, read(Wire().document(listOf(positive))).displayTitle.single())
        }
        val bodyKeys = listOf("root.0.segment0.base0.body.0", "root.0.segment0.annotation0.body.0",
            "root.0.segment0.annotation0.before.0", "root.0.segment0.annotation0.after.0")
        val nestedBodies = Wire()
        val nestedBodyBytes = nestedBodies.document(listOf(owner(listOf(base(allArrays)))))
        val rejectedChildren = buildList {
            for (control in listOf('\t', '\n', '\r', '\u000c')) {
                add(Span("text", "body${control}"))
                add(Span("text", "body", trail = control.toString()))
            }
            add(Span("text", "body", "Unexpected target"))
            add(Span("link", "body", ""))
            add(Span("external_link", "body", ""))
        }
        for (child in rejectedChildren) {
            // These legacy Span shapes remain constructible and decodable outside Ruby.
            assertNull(child.ruby)
            assertEquals(child, read(Wire('O').document(listOf(child))).displayTitle.single())
            assertEquals(child, read(Wire().document(listOf(simple(), child))).displayTitle[1])
            invalid("Ruby base child domain") { owner(listOf(base(child))) }
            invalid("Ruby annotation child domain") { owner(listOf(first), listOf(annotation(child))) }
            invalid("Ruby rp-before child domain") {
                owner(listOf(first), listOf(annotation(text("a"), before = listOf(child), explicit = true)))
            }
            invalid("Ruby rp-after child domain") {
                owner(listOf(first), listOf(annotation(text("a"), after = listOf(child), explicit = true)))
            }
            val literal = Wire().isolatedSpan(child)
            for (key in bodyKeys) {
                reject("Direct Ruby body child at $key", replace(arrayBytes, arrays.at.getValue("$key.start"),
                    arrays.at.getValue("$key.end"), literal))
                val nestedKey = key.replaceFirst("root.0", "root.0.segment0.base0.body.0")
                reject("Nested Ruby body child at $nestedKey", replace(nestedBodyBytes,
                    nestedBodies.at.getValue("$nestedKey.start"), nestedBodies.at.getValue("$nestedKey.end"), literal))
            }
        }
    }

    @Test fun rubyDepthSharesOwnerLimitsAndEveryStructuralArrayConsumesTheAggregateBudget() {
        val sixteen = Wire().apply { rootOverride = { chain(16, it) } }.document(emptyList())
        var span = read(sixteen).displayTitle.single()
        repeat(16) { span = checkNotNull(span.ruby).segments.single().bases.single().spans.single() }
        assertEquals("漢", span.text); assertNull(span.ruby)
        reject("Seventeenth Ruby owner", Wire().apply { rootOverride = { chain(17, it) } }.document(emptyList()))
        val mixed = read(Wire().document(listOf(simple()), Sink.Container, containers = 15))
        var block = mixed.sections.single().blocks.single()
        repeat(15) { block = block.container!!.blocks.single() }
        assertEquals(simple(), block.spans.single())
        reject("Container depth cannot reset Ruby depth", Wire().document(listOf(simple()), Sink.Container, containers = 16))
        val budget = Wire().apply { rootOverride = { aggregateBudget(it) } }.document(emptyList())
        assertTrue("Full bytes distinguish owner budget from truncation", budget.size > 15_600_000)
        reject("Required declaring owners add items to the otherwise legal base count", budget)
        val emptyBase = base()
        invalid("Model charges declaring owners even when an immutable base is reused") {
            Ruby(listOf(RubySegment(emptyList(), List(600_000) { emptyBase }, emptyList())))
        }
    }

    @Test fun oldNullSpanBytesAndExistingFeatureTrailersRemainExactAndDoNotAcquireRuby() {
        val old = Span("link", "Old😀", "Target", trail = "s", targetFragment = "part", tooltip = "tip",
            fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody, fontFeatures = FontFeaturePolicy.Normal)
        val oldSpan = Wire('R').isolatedSpan(old)
        assertArrayEquals(oldSpan + byteArrayOf(0), Wire().isolatedSpan(old))
        for (version in listOf('M', 'N', 'O', 'P', 'Q', 'R')) {
            val features = if (version == 'P') 1 else 0
            val wire = Wire(version); val bytes = wire.document(listOf(old), features = features,
                alignment = version == 'Q', clear = version == 'R')
            val frozen = bytes.copyOf(); val entry = read(bytes)
            assertEquals(old, entry.displayTitle.single()); assertNull(entry.displayTitle.single().ruby)
            assertArrayEquals(oldSpan, bytes.copyOfRange(wire.at.getValue("root.0.start"), wire.at.getValue("root.0.end")))
            assertArrayEquals(frozen, bytes)
            assertEquals(if (version == 'P') BodyAdjoiningPolicy.Ordinary else null, entry.bodyAdjoining)
        }
    }
}
