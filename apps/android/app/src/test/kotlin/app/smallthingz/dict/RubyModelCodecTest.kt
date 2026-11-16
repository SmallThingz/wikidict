package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal S/T data-boundary controls. No producer, layout, auto-hiding or graphical fidelity claim. */
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
        var paragraphOverride: (() -> Unit)? = null
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
            val fields = (if (value.fontScale != null) 1 else 0) or (if (value.fontFeatures != null) 2 else 0) or
                (if (value.linkPaint != null) 4 else 0) or (if (value.inlineStyle != null) 8 else 0) or (if (value.fontFamily != null) 16 else 0)
            byte(fields)
            value.fontScale?.let { f32(it); byte(value.fontScaleBasis.ordinal) }
            value.fontFeatures?.let { byte(it.ordinal) }
            value.linkPaint?.let { byte(1); linkPaint(it) }
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
            if (version == 'S' || version == 'T' || version == 'U' || version == 'V') {
                mark("$label.ruby"); byte(if (value.ruby == null) 0 else 1)
                value.ruby?.let { ruby(it, label) }
            } else require(value.ruby == null)
            if (version == 'U' || version == 'V') {
                mark("$label.padding"); byte(if (value.inlinePaddingGroup == null) 0 else 1)
                value.inlinePaddingGroup?.let { group ->
                    mark("$label.padding.left"); byte(group.left.unit.ordinal); f32(group.left.value)
                    mark("$label.padding.right"); byte(group.right.unit.ordinal); f32(group.right.value)
                    spans(group.spans, "$label.padding.body")
                }
            } else require(value.inlinePaddingGroup == null)
            mark("$label.padding.end")
            if (version == 'V') {
                mark("$label.action"); byte(if (value.inlineActionGroup == null) 0 else 1)
                value.inlineActionGroup?.let { spans(it.spans, "$label.action.body") }
            } else require(value.inlineActionGroup == null)
            mark("$label.end")
        }
        private fun linkPaint(value: LinkPaint) {
            require(value.focusOutline == null)
            val prefix = listOf(value.normal, value.hover, value.active, value.visited, value.visitedHover, value.visitedActive)
            prefix.forEach { string(it.foreground) }
            var mask = if (value.underlineOnFocus) 64 else 0
            prefix.forEachIndexed { index, state -> if (state.underline) mask = mask or (1 shl index) }
            byte(mask); byte(0)
            string(value.hoverActive.foreground); string(value.visitedHoverActive.foreground)
            byte((if (value.hoverActive.underline) 1 else 0) or (if (value.visitedHoverActive.underline) 2 else 0))
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
            if (body && paragraphOverride != null) { checkNotNull(paragraphOverride).invoke(); return }
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
        /** Raw table edges do not consume content depth; a rich caption does. */
        fun tableChain(depth: Int, mixed: Boolean = false, captionAt: Int = 0) {
            require(depth > 0 && (captionAt == 0 || captionAt in 1 until depth))
            fun emit(level: Int, block: Boolean) {
                if (block) prefix(12)
                byte(1); byte(0) // ordinary table, no legacy geometry
                spans(emptyList(), "deep.$level.caption")
                val caption = level == captionAt
                mark("deep.$level.rows"); u32(if (caption) 0 else 1)
                if (!caption) {
                    u32(1); byte(0); mark("deep.$level.colspan"); u16(1); u16(1); byte(0)
                    if (level == depth) root("root") else spans(emptyList(), "deep.$level.cell")
                    val ordered = mixed && level % 2 == 0 && level < depth
                    if (level < depth && !ordered) emit(level + 1, false) else byte(0)
                    byte(if (ordered) 1 else 0)
                    if (ordered) { u32(1); emit(level + 1, true) }
                    byte(0) // cell style
                }
                byte(0) // table style
                byte(if (caption) 1 else 0)
                if (caption) { u32(1); emit(level + 1, true) }
                if (block) tail()
            }
            emit(1, true)
        }

        /** Raw shared depth with one innermost V owner and text-owned U/Ruby ancestors. */
        fun actionChain(depth: Int, mixed: Boolean, label: String) {
            require(version == 'V' && depth > 0)
            mark("$label.count"); u32(1)
            fun nested(remaining: Int, name: String) {
                if (remaining == 1) {
                    out.write(Wire('R').isolatedSpan(Span("link", "", "Owner")))
                    byte(0); byte(0); byte(1); u32(1)
                    span(Span("text", "leaf"), "$name.child")
                    return
                }
                out.write(Wire('R').isolatedSpan(Span("text", "")))
                if (mixed && remaining % 2 == 0) {
                    byte(1); u32(1); u32(0); u32(1); u32(0); out.write(ByteArray(18)); u32(1)
                    nested(remaining - 1, "$name.child"); u32(0); byte(0); byte(0)
                } else {
                    byte(0); byte(1); length(1f); length(1f); u32(1)
                    nested(remaining - 1, "$name.child"); byte(0)
                }
            }
            nested(depth, "$label.0")
        }
        /** Raw group/Ruby depth, including invalid depth, without typed-constructor prevalidation. */
        fun paddingChain(depth: Int, mixed: Boolean, label: String) {
            require(version == 'U')
            mark("$label.count"); u32(1)
            fun nested(remaining: Int, name: String) {
                if (remaining == 0) { span(Span("text", "leaf"), name); return }
                out.write(Wire('R').isolatedSpan(Span("text", "")))
                if (mixed && remaining % 2 == 0) {
                    byte(1); u32(1); u32(0); u32(1); u32(0); out.write(ByteArray(18)); u32(1)
                    nested(remaining - 1, "$name.child"); u32(0); byte(0)
                } else {
                    byte(0); byte(1); length(1f); length(1f); u32(1)
                    nested(remaining - 1, "$name.child")
                }
            }
            nested(depth, "$label.0")
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
        val unknown = runCatching { read(changed(bytes, 3, 'W'.code)) }.exceptionOrNull()
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

    private fun expectedTableChain(values: List<Span>, depth: Int, mixed: Boolean = false,
        captionAt: Int = 0): Table {
        var table = Table(emptyList(), listOf(listOf(Cell(values, false, 1, 1))))
        for (level in depth - 1 downTo 1) {
            val block = Block("table", 0, emptyList(), table = table)
            table = when {
                level == captionAt -> Table(emptyList(), emptyList(), captionBlocks = listOf(block))
                mixed && level % 2 == 0 -> Table(emptyList(), listOf(listOf(
                    Cell(emptyList(), false, 1, 1, blocks = listOf(block)))))
                else -> Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = table))))
            }
        }
        return table
    }

    @Test fun literalTDepthEnvelopeKeepsFullMixedTableReferenceCaptionAndOptionalRubyData() {
        val action = Span("link", "Deep😀", "Deep target", trail = "s", targetFragment = "part",
            explanation = "Deep explanation", tooltip = "Deep advisory")
        val plain = listOf(text("before "), action, text(" after"))
        assertArrayEquals(Wire('S').isolatedSpan(action), Wire('T').isolatedSpan(action))
        for (depth in listOf(17, 20, 32)) {
            val mixed = depth != 17
            val captionAt = if (depth == 20) 8 else 0
            val reference = depth == 32
            for (withRuby in listOf(false, true)) {
                val typed = owner(listOf(base(action)), listOf(annotation(text("reading"))))
                val values = if (withRuby) listOf(plain.first(), typed, plain.last()) else plain
                val wire = Wire('T').apply { paragraphOverride = { tableChain(depth, mixed, captionAt) } }
                val bytes = wire.document(values, if (reference) Sink.ReferenceBlocks else Sink.Body)
                assertArrayEquals(byteArrayOf(68, 80, 82, 84), bytes.copyOfRange(0, 4))
                assertEquals(0, bytes[wire.at.getValue("features")].toInt())
                val frozen = bytes.copyOf()
                val entry = read(bytes)
                assertEquals("Ruby", entry.title)
                assertTrue(entry.displayTitle.isEmpty()); assertTrue(entry.preamble.isEmpty())
                assertTrue(entry.media.isEmpty()); assertNull(entry.bodyAdjoining)
                val expected = expectedTableChain(values, depth, mixed, captionAt)
                val block = if (reference) {
                    assertTrue(entry.sections.isEmpty())
                    val ref = entry.references.single()
                    assertEquals(ReferenceKind.Fragment, ref.kind)
                    assertEquals(1L, ref.number); assertNull(ref.groupNumber)
                    assertEquals("ruby-ref", ref.group); assertTrue(ref.spans.isEmpty())
                    checkNotNull(ref.blocks).single()
                } else {
                    assertTrue(entry.references.isEmpty())
                    val section = entry.sections.single()
                    assertEquals(2, section.level); assertEquals("Body", section.title)
                    assertEquals("", section.anchor); assertEquals("", section.anchorFallback)
                    section.blocks.single()
                }
                assertEquals(Block("table", 0, emptyList(), table = expected), block)
                val depths = mutableListOf<Int>(); val contentDepths = mutableListOf<Int>()
                val runs = mutableListOf<List<Span>>()
                val visitor = PresentationSpanVisitor { spans, _ -> if (spans.isNotEmpty()) runs.add(spans) }
                visitor.onTable = { _, tableDepth, contentDepth -> depths.add(tableDepth); contentDepths.add(contentDepth) }
                visitor.table(checkNotNull(block.table))
                assertEquals((1..depth).toList(), depths)
                assertEquals((1..depth).map { if (captionAt != 0 && it > captionAt) 1 else 0 }, contentDepths)
                assertEquals(values, runs.single())
                val decodedAction = if (withRuby) checkNotNull(runs.single()[1].ruby)
                    .segments.single().bases.single().spans.single() else runs.single()[1]
                assertEquals(action, decodedAction)
                assertEquals(EntryLink("Deep target", "part"), decodedAction.entryLink())
                assertEquals(if (withRuby) "before Deep😀s（reading） after" else "before Deep😀s after",
                    rubyFallbackText(runs.single()))
                assertArrayEquals(frozen, bytes)
            }
        }
        // Optional Q/R payloads remain independent of T's required deep-table census.
        val optional = Wire('T').apply { paragraphOverride = { tableChain(17) } }
            .document(plain, Sink.Body, alignment = true, clear = true)
        val entry = read(optional)
        assertEquals(expectedTableChain(plain, 17), entry.sections.single().blocks.first().table)
        assertEquals(InlineImageVerticalAlign.Baseline, entry.inlineImages.single().verticalAlign)
        assertEquals(FigureClear.None, entry.sections.single().blocks.last().ruleStyle!!.clear)
    }

    @Test fun tDepthCensusDoesNotRelaxLegacyContentRubyFeatureOrAggregateGuards() {
        val plain = listOf(Span("link", "Deep", "Target", targetFragment = "part", tooltip = "tip"))
        val typed = listOf(simple())
        fun wire(version: Char, depth: Int, mixed: Boolean = false, captionAt: Int = 0) =
            Wire(version).apply { paragraphOverride = { tableChain(depth, mixed, captionAt) } }
        for (depth in listOf(1, 16)) for (values in listOf(plain, typed))
            reject("T requires actual table depth17..32: $depth", wire('T', depth).document(values, Sink.Body))
        reject("T cannot be selected by an ordinary display", Wire('T').document(typed))
        reject("T33 raw nested tables", wire('T', 33).document(plain, Sink.Body))
        reject("T33 across ordered cells and caption", wire('T', 33, true, 8).document(typed, Sink.ReferenceBlocks))
        assertEquals(expectedTableChain(typed, 16), read(wire('S', 16).document(typed, Sink.Body))
            .sections.single().blocks.single().table)
        reject("S still caps table depth16", wire('S', 17).document(typed, Sink.Body))
        reject("S still requires Ruby", wire('S', 16).document(plain, Sink.Body))
        val deep = wire('T', 17).document(typed, Sink.Body)
        reject("Same S payload cannot be relabelled to allow deep tables", changed(deep, 3, 'S'.code))
        assertEquals(expectedTableChain(plain, 16), read(wire('R', 16).document(plain, Sink.Body, clear = true))
            .sections.single().blocks.first().table)
        reject("Literal legacy R still caps table depth16", wire('R', 17).document(plain, Sink.Body, clear = true))

        val rich = owner(listOf(base(text("base"))), listOf(annotation(text("reading"), context = RubyOwner(
            InlineFontSnapshot(fontFamily = ContainerFontFamily.SansSerif),
            inlineStyle = InlineTextStyle(wrap = TextWrap.BreakWord)))))
        val featureWire = wire('T', 20, true, 8)
        val featureBytes = featureWire.document(listOf(rich), Sink.ReferenceBlocks, features = 20)
        assertEquals(expectedTableChain(listOf(rich), 20, true, 8), read(featureBytes).references.single().blocks!!.single().table)
        for (flags in listOf(0, 4, 16, 20 or 8, 20 or 32, 20 or 64, 20 or 128))
            reject("T preserves exact owner-family/wrap feature census: $flags",
                changed(featureBytes, featureWire.at.getValue("features"), flags))
        val literal = wire('T', 17)
        val bytes = literal.document(plain, Sink.Body)
        reject("T unused family bit", changed(bytes, literal.at.getValue("features"), 4))
        reject("Strict nullable Ruby presence on ordinary T span", changed(bytes, literal.at.getValue("root.0.ruby"), 2))
        reject("Deep cell colspan still excludes zero", changed(bytes, literal.at.getValue("deep.17.colspan"), 0))
        reject("Presentation count remains bounded", changed32(bytes, literal.at.getValue("root.count"), (1L shl 20) + 1))
        reject("String byte limit remains bounded", changed32(bytes, literal.at.getValue("root.0.text"), 32L * 1024 * 1024 + 1))
        for (cut in listOf(0, 3, 4, literal.at.getValue("root.0.start"), literal.at.getValue("root.0.end"), bytes.size - 1))
            reject("Truncated T at$cut", bytes.copyOf(cut))
        reject("Trailing T byte", bytes + byteArrayOf(0))

        fun rubyDepth(depth: Int, captionAt: Int = 0): ByteArray = wire('T', 17, true, captionAt).apply {
            rootOverride = { chain(depth, it) }
        }.document(emptyList(), Sink.Body)
        for ((rubyCount, captionAt) in listOf(16 to 0, 15 to 8)) {
            val entry = read(rubyDepth(rubyCount, captionAt))
            val runs = mutableListOf<List<Span>>()
            entry.sections.single().blocks.single().table!!.visitSpanRuns { spans, _ -> if (spans.isNotEmpty()) runs.add(spans) }
            var span = runs.single().single()
            repeat(rubyCount) { span = span.ruby!!.segments.single().bases.single().spans.single() }
            assertEquals(text("漢"), span)
        }
        reject("T table depth cannot relax Ruby depth16", rubyDepth(17))
        reject("Rich-caption content depth remains cumulative with Ruby", rubyDepth(16, 8))
        val budget = wire('T', 17).apply { rootOverride = { aggregateBudget(it) } }.document(emptyList(), Sink.Body)
        assertTrue("Complete owner bytes distinguish aggregate exhaustion from truncation", budget.size > 15_600_000)
        reject("T preserves aggregate owner/item budget", budget)

        val accepted = expectedTableChain(plain, 32, true, 8)
        val seen = mutableListOf<Int>()
        PresentationSpanVisitor { _, _ -> }.apply { onTable = { _, depth, _ -> seen.add(depth) } }.table(accepted)
        assertEquals((1..32).toList(), seen)
        invalid("Direct model visitor rejects33") { PresentationSpanVisitor { _, _ -> }.table(expectedTableChain(plain, 33)) }
        val cyclicRow = mutableListOf<Cell>()
        val cycle = Table(emptyList(), listOf(cyclicRow))
        cyclicRow.add(Cell(emptyList(), false, 1, 1, nestedTable = cycle))
        val cycleFailure = runCatching { PresentationSpanVisitor { _, _ -> }.table(cycle) }.exceptionOrNull()
        assertTrue(cycleFailure is IllegalArgumentException)
        assertEquals("Table nesting is too deep", cycleFailure!!.message)
    }

    @Test fun literalUGroupTailPreservesDeclaringContextActionsAndEveryExistingSpanSink() {
        val child = Span("link", "du😀", "Reading", trail = "!", targetFragment = "part",
            language = "vi", foreground = "#123456", tooltip = "Child tip", explanation = "Child explanation")
        val group = InlinePaddingGroup(StyleLength(StyleLengthUnit.Px, 0f),
            StyleLength(StyleLengthUnit.Em, .25f), listOf(child))
        val source = Span("text", "", language = "vi", direction = "ltr", bold = false,
            fontScale = 1.35f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFamily = ContainerFontFamily.SansSerif, tooltip = "Owner tip", explanation = "Owner explanation",
            inlineStyle = InlineTextStyle(cursor = InlineCursor.Help, wrap = TextWrap.BreakWord), inlinePaddingGroup = group)
        assertSame(child, source.inlinePaddingGroup!!.spans.single())
        assertEquals("du😀!", textOf(listOf(source)))
        for (sink in Sink.entries) {
            val wire = Wire('U')
            val bytes = wire.document(listOf(source), sink, features = 20, headingTitle = "du😀!")
            val decoded = read(bytes)
            assertEquals("Entire owner at $sink", source, selected(decoded, sink))
            assertEquals("No padding characters at $sink", "du😀!", textOf(listOf(selected(decoded, sink))))
            val raw = mutableListOf<Span>()
            PresentationSpanVisitor { _, _ -> }.apply { onSpan = raw::add }.spans(listOf(selected(decoded, sink)))
            assertEquals(listOf(source, child), raw)
            assertEquals(listOf(child), raw.filter { it.kind == "link" })
            assertEquals(0, bytes[wire.at.getValue("root.0.ruby")].toInt())
            assertEquals(wire.at.getValue("root.0.ruby") + 1, wire.at.getValue("root.0.padding"))
            for (bit in listOf(4, 8, 16, 32, 64, 128)) {
                val flags = bytes[wire.at.getValue("features")].toInt() and 255
                reject("Exact recursive P census $sink/$bit", changed(bytes, wire.at.getValue("features"), flags xor bit))
            }
        }
        val inherited = Span("link", "", "Fanqie", targetFragment = "kept", tooltip = "Owned action",
            inlineStyle = InlineTextStyle(cursor = InlineCursor.Help, wrap = TextWrap.Normal),
            inlinePaddingGroup = group.copy(spans = listOf(text("反"), text("切"))))
        val inheritedEntry = read(Wire('U').document(listOf(inherited), features = 16))
        assertEquals(inherited, inheritedEntry.displayTitle.single())
        val actions = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { if (it.kind == "link") actions.add(it) } }
            .spans(inheritedEntry.displayTitle)
        assertEquals(listOf(inherited), actions)
        assertEquals("反切", textOf(inheritedEntry.displayTitle))
        val ruby = owner(listOf(base(text("字"))), listOf(annotation(source)))
        val nested = inherited.copy(kind = "text", target = "", targetFragment = null,
            inlinePaddingGroup = group.copy(spans = listOf(ruby)))
        assertEquals(nested, read(Wire('U').document(listOf(nested), features = 20)).displayTitle.single())
        assertEquals("字（du😀!）", textOf(listOf(nested)))
        for (alignment in listOf(false, true)) for (clear in listOf(false, true)) {
            val entry = read(Wire('U').document(listOf(inherited), features = 16, alignment = alignment, clear = clear))
            assertEquals(inherited, entry.displayTitle.single())
            assertEquals(alignment, entry.inlineImages.isNotEmpty())
            assertEquals(clear, entry.sections.flatMap { it.blocks }.any { it.ruleStyle?.clear == FigureClear.None })
        }
        val plain = text("unchanged")
        assertEquals(1, Wire('U').isolatedSpan(plain).size - Wire('S').isolatedSpan(plain).size)
        assertArrayEquals(Wire('S').isolatedSpan(plain), Wire('U').isolatedSpan(plain).dropLast(1).toByteArray())
        assertEquals(39, Wire('U').isolatedSpan(text("")).size)
        reject("U requires an actual group", Wire('U').document(listOf(simple())))
        reject("U without Ruby still requires a group", Wire('U').document(listOf(plain)))
        val old = Wire('S').document(listOf(simple()))
        assertEquals(simple(), read(old).displayTitle.single())
        reject("S bytes cannot be relabelled U", changed(old, 3, 'U'.code))
        val unknown = runCatching { read(changed(old, 3, 'W'.code)) }.exceptionOrNull()
        assertEquals("Unsupported presentation format", unknown!!.message)
    }

    @Test fun inlinePaddingRejectsMalformedOwnersChildrenActionsAndLiteralTailsWithoutRelaxingLegacy() {
        val px0 = StyleLength(StyleLengthUnit.Px, 0f)
        val edge = StyleLength(StyleLengthUnit.Em, .25f)
        fun padded(vararg spans: Span) = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(px0, edge, spans.toList()))
        val valid = padded(text("x"))
        invalid("Both edges zero") { InlinePaddingGroup(px0, px0, listOf(text("x"))) }
        invalid("Empty child array") { InlinePaddingGroup(px0, edge, emptyList()) }
        for (number in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) invalid("Invalid edge $number") {
            InlinePaddingGroup(px0, StyleLength(StyleLengthUnit.Px, number), listOf(text("x")))
        }
        for (empty in listOf("", " ", "\u00a0")) {
            val child = text(empty)
            assertSame(child, padded(child).inlinePaddingGroup!!.spans.single())
            assertEquals(empty, read(Wire('U').document(listOf(padded(child))))
                .displayTitle.single().inlinePaddingGroup!!.spans.single().text)
        }
        for (kind in listOf("link", "external_link")) invalid("Missing owner target") { valid.copy(kind = kind) }
        invalid("Owner text") { valid.copy(text = "x") }
        invalid("Owner trail") { valid.copy(trail = "x") }
        invalid("Owner image") { valid.copy(image = InlineImage("Probe.svg")) }
        invalid("Owner Ruby") { valid.copy(ruby = simple().ruby) }
        invalid("Text owner target") { valid.copy(target = "Target") }
        for (child in listOf(Span("line_break", ""), Span("text", "", image = InlineImage("Probe.svg")),
            Span("text", "x", "Target"), Span("link", "x"), Span("external_link", "x"),
            text("x").copy(classes = "wikidict-media"), text("x").copy(classes = "wikidict-media-file-Probe.svg"),
            text("x").copy(fontScale = Float.NaN))) {
            invalid("Invalid group child $child") { padded(child) }
            val wire = Wire('U'); val bytes = wire.document(listOf(valid)); val key = "root.0.padding.body.0"
            reject("Literal child must refuse", replace(bytes, wire.at.getValue("$key.start"), wire.at.getValue("$key.end"),
                Wire('U').isolatedSpan(child)))
        }
        for (control in listOf('\t', '\n', '\r', '\u000c')) for (trail in listOf(false, true)) {
            val bad = if (trail) text("x").copy(trail = control.toString()) else text(control.toString())
            invalid("Raw body control") { padded(bad) }
            val wire = Wire('U'); val bytes = wire.document(listOf(valid)); val key = "root.0.padding.body.0"
            reject("Literal raw body control", replace(bytes, wire.at.getValue("$key.start"), wire.at.getValue("$key.end"),
                Wire('U').isolatedSpan(bad)))
        }
        invalid("Legacy empty cursor remains invalid") { Span("text", "", inlineStyle = InlineTextStyle(cursor = InlineCursor.Help)) }
        invalid("Legacy empty link style remains invalid") { Span("link", "", "A", inlineStyle = InlineTextStyle(wrap = TextWrap.Normal)) }
        val action = Span("link", "x", "Same")
        val hidden = owner(listOf(base(text("x"))), listOf(annotation(action)))
        val rp = owner(listOf(base(text("x"))), listOf(annotation(text("y"), before = listOf(action), explicit = true)))
        for (child in listOf(action, padded(action), hidden, rp)) {
            val textOwner = padded(child)
            invalid("Inherited owner rejects every descendant action, even identical") { textOwner.copy(kind = "link", target = "Same") }
            val wire = Wire('U'); val bytes = wire.document(listOf(textOwner))
            val prefixOwner = valid.copy(kind = "link", target = "Same")
            val prefixWire = Wire('U'); val prefix = prefixWire.isolatedSpan(prefixOwner)
            val forged = prefix.copyOfRange(0, prefixWire.at.getValue("isolated.padding")) +
                bytes.copyOfRange(wire.at.getValue("root.0.padding"), bytes.size)
            reject("Literal inherited descendant action", bytes.copyOfRange(0, wire.at.getValue("root.0.start")) + forged)
        }
        val states = listOf("#123456", "#234567", "#345678", "#456789", "#56789a", "#6789ab", "#789abc", "#89abcd")
            .mapIndexed { index, color -> LinkState(color, index % 2 == 1) }
        val paint = LinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], states[6], states[7], true)
        fun painted(child: Span, foreground: String? = "#123456") = padded(child).copy(
            kind = "link", target = "Painted owner", targetFragment = "paint", foreground = foreground, linkPaint = paint)
        for (child in listOf(text("child"), text("child").copy(foreground = "#123456", underline = true),
            owner(listOf(base(text("base"), context = RubyOwner(InlineFontSnapshot(), foreground = "#123456"))),
                listOf(annotation(text("reading"), context = RubyOwner(InlineFontSnapshot(), foreground = "#123456")))))) {
            for (foreground in listOf("#123456", null)) {
                val source = painted(child, foreground)
                assertSame(child, source.inlinePaddingGroup!!.spans.single())
                assertEquals(source, read(Wire('U').document(listOf(source))).displayTitle.single())
            }
        }
        assertEquals(painted(text("child"), null), read(Wire('U').document(listOf(painted(text("child"), null)))).displayTitle.single())
        for ((child, foreground) in listOf(
            text("child").copy(foreground = "#654321") to "#123456",
            text("child").copy(foreground = "#654321") to null,
            owner(listOf(base(text("base"), context = RubyOwner(InlineFontSnapshot(), foreground = "#654321")))) to "#123456",
            owner(listOf(base(text("same"))), listOf(annotation(text("same"),
                context = RubyOwner(InlineFontSnapshot(), foreground = "#654321")))) to "#123456",
            owner(listOf(base(context = RubyOwner(InlineFontSnapshot(), foreground = "#654321")))) to "#123456"
        )) {
            invalid("Inherited LinkPaint cannot erase leaf or declaring Ruby color") { painted(child, foreground) }
            val textWire = Wire('U'); val bytes = textWire.document(listOf(padded(child)))
            val ownerWire = Wire('U'); val prefix = ownerWire.isolatedSpan(painted(text("x"), foreground))
            val forged = prefix.copyOfRange(0, ownerWire.at.getValue("isolated.padding")) +
                bytes.copyOfRange(textWire.at.getValue("root.0.padding"), bytes.size)
            reject("Literal inherited LinkPaint color conflict", bytes.copyOfRange(0, textWire.at.getValue("root.0.start")) + forged)
        }
        val gapRuby = owner(listOf(base(text("a")), RubyBase(RubyOwner(InlineFontSnapshot()), listOf(text(" ")), listOf(text("b")))))
        invalid("Group forbidden in Ruby gap") {
            gapRuby.copy(ruby = Ruby(listOf(gapRuby.ruby!!.segments.single().copy(bases = listOf(base(text("a")),
                RubyBase(RubyOwner(InlineFontSnapshot()), listOf(padded(text(" "))), listOf(text("b"))))))))
        }
        val gapWire = Wire('U'); val gapBytes = gapWire.document(listOf(padded(gapRuby)))
        val gapKey = "root.0.padding.body.0.segment0.base1.gap.0"
        reject("Literal group in Ruby gap", replace(gapBytes, gapWire.at.getValue("$gapKey.start"), gapWire.at.getValue("$gapKey.end"),
            Wire('U').isolatedSpan(padded(text(" ")))))
        val wire = Wire('U'); val bytes = wire.document(listOf(valid))
        for (bad in listOf(text("x"), text("").copy(trail = "x"), simple(),
            Span("text", "", image = InlineImage("Probe.svg")))) {
            val ownerWire = Wire('U'); val ownerBytes = ownerWire.isolatedSpan(bad)
            val forged = ownerBytes.copyOfRange(0, ownerWire.at.getValue("isolated.padding")) +
                bytes.copyOfRange(wire.at.getValue("root.0.padding"), bytes.size)
            reject("Literal owner conflicts with group", bytes.copyOfRange(0, wire.at.getValue("root.0.start")) + forged)
        }
        for (value in listOf(2, 255)) reject("Strict group presence", changed(bytes, wire.at.getValue("root.0.padding"), value))
        for (side in listOf("left", "right")) {
            reject("Unknown length unit", changed(bytes, wire.at.getValue("root.0.padding.$side"), 2))
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) reject("Nonfinite/negative literal edge", changed32(bytes,
                wire.at.getValue("root.0.padding.$side") + 1, value.toRawBits().toLong() and 0xffff_ffffL))
        }
        reject("Zero literal edges", changed32(bytes, wire.at.getValue("root.0.padding.right") + 1, 0))
        for (count in listOf(0L, 0xffff_ffffL, 1000L)) reject("Invalid/truncated group children$count",
            changed32(bytes, wire.at.getValue("root.0.padding.body.count"), count))
        for (size in 0 until bytes.size) reject("U truncation$size", bytes.copyOf(size))
        reject("U trailing byte", bytes + byteArrayOf(0))
        for (header in listOf('R', 'S', 'T')) reject("Older header cannot carry U", changed(bytes, 3, header.code))
    }

    @Test fun inlinePaddingSharesContentAndItemBudgetsWhileUAllowsShallowAndDeepTables() {
        val edge = StyleLength(StyleLengthUnit.Px, 1f)
        fun padded(span: Span) = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(edge, edge, listOf(span)))
        for (mixed in listOf(false, true)) {
            var source = text("leaf")
            repeat(16) { index -> source = if (mixed && index % 2 == 1) owner(listOf(base(source))) else padded(source) }
            assertEquals("leaf", textOf(listOf(source)))
            assertEquals(source, read(Wire('U').document(listOf(source))).displayTitle.single())
            invalid("Seventeenth shared content level") { padded(source) }
            val wire = Wire('U').apply { rootOverride = { paddingChain(17, mixed, it) } }
            reject("Literal mixed group/Ruby depth17", wire.document(emptyList()))
            val wrapped = Wire('U').apply { rootOverride = { paddingChain(16, mixed, it) } }
            reject("Container contributes to same content budget", wrapped.document(emptyList(), Sink.Container))
            val allowed = Wire('U').apply { rootOverride = { paddingChain(15, mixed, it) } }
            assertEquals("leaf", textOf(listOf(selected(read(allowed.document(emptyList(), Sink.Container)), Sink.Container))))
        }
        val action = Span("link", "深😀", "Deep target", targetFragment = "part")
        val source = padded(action)
        for (depth in listOf(1, 16, 17, 20, 32)) {
            val wire = Wire('U').apply { paragraphOverride = { tableChain(depth, mixed = true) } }
            val entry = read(wire.document(listOf(source), Sink.Body))
            val tables = mutableListOf<Int>(); val raw = mutableListOf<Span>()
            PresentationSpanVisitor { _, _ -> }.apply { onTable = { _, level, _ -> tables.add(level) }; onSpan = raw::add }
                .blocks(entry.sections.single().blocks)
            assertEquals((1..depth).toList(), tables)
            assertEquals(listOf(source, action), raw)
            assertEquals("深😀", textOf(listOf(raw.first())))
        }
        val deep = Wire('U').apply { paragraphOverride = { tableChain(33, mixed = true) } }
        reject("U still limits table depth32", deep.document(listOf(source), Sink.Body))
        val noGroup = Wire('U').apply { paragraphOverride = { tableChain(20) } }
        reject("Deep U still requires group", noGroup.document(listOf(simple()), Sink.Body))
        val missingGroup = Wire('T').apply { paragraphOverride = { tableChain(20) } }
        assertEquals(1, read(missingGroup.document(listOf(action), Sink.Body)).sections.size)
        val cyclic = mutableListOf(text("leaf"))
        val cyclicOwner = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(edge, edge, cyclic))
        cyclic[0] = cyclicOwner
        invalid("A mutable group cycle shares the finite content guard") { PresentationSpanVisitor { _, _ -> }.spans(listOf(cyclicOwner)) }
        val leaf = text("")
        val payload = InlinePaddingGroup(edge, edge, java.util.Collections.nCopies((1 shl 20) - 1, leaf))
        assertEquals(1 shl 20, payload.spans.size + 1)
        val exactly = Span("text", "", inlinePaddingGroup = payload)
        var count = 0
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { count++ } }.spans(listOf(exactly))
        assertEquals(1 shl 20, count)
        val over = InlinePaddingGroup(edge, edge, java.util.Collections.nCopies(1 shl 20, leaf))
        invalid("Containing Span owner consumes its one item") { Span("text", "", inlinePaddingGroup = over) }
    }

    @Test fun literalVRetainsOneRichActionOwnerAndDistinctEqualTargetsAcrossAllSpanSinks() {
        // Synthetic declared contexts exercise the wire contract, not a captured KU/Mai operation.
        val first = text("d").copy(italic = true, tooltip = "Child tip")
        val middle = text("😀")
        val last = text("a").copy(superscript = true, fontScale = .5f, explanation = "Child explanation")
        val source = Span("link", "", "Same target", targetFragment = "part", language = "de", direction = "ltr",
            fontScale = 1.35f, fontScaleBasis = FontScaleBasis.NormalBody, fontFamily = ContainerFontFamily.SansSerif,
            tooltip = "Owner tip", explanation = "Owner explanation",
            inlineStyle = InlineTextStyle(cursor = InlineCursor.Help, wrap = TextWrap.BreakWord),
            inlineActionGroup = InlineActionGroup(listOf(first, middle, last)))
        assertSame(first, source.inlineActionGroup!!.spans.first())
        assertSame(last, source.inlineActionGroup!!.spans.last())
        assertEquals("d😀a", textOf(listOf(source)))
        for (sink in Sink.entries) {
            val wire = Wire('V')
            val bytes = wire.document(listOf(source), sink, features = 20, headingTitle = "d😀a")
            val decoded = selected(read(bytes), sink)
            assertEquals("Complete declaring owner at $sink", source, decoded)
            assertEquals("Exact child text at $sink", "d😀a", textOf(listOf(decoded)))
            val raw = mutableListOf<Span>()
            PresentationSpanVisitor { _, _ -> }.apply { onSpan = raw::add }.spans(listOf(decoded))
            assertEquals(listOf(source, first, middle, last), raw)
            assertEquals(listOf(source), raw.filter { it.kind in setOf("link", "external_link") })
            assertEquals(wire.at.getValue("root.0.padding.end"), wire.at.getValue("root.0.action"))
            for (bit in listOf(4, 8, 16, 32, 64, 128)) {
                val flags = bytes[wire.at.getValue("features")].toInt() and 255
                reject("Exact V nested P census $sink/$bit", changed(bytes, wire.at.getValue("features"), flags xor bit))
            }
        }
        val second = source.copy()
        assertEquals(source, second)
        assertNotSame(source, second)
        val adjacent = read(Wire('V').document(listOf(source, second), features = 20)).displayTitle
        assertEquals(listOf(source, second), adjacent)
        assertNotSame(adjacent[0], adjacent[1])
        val storedActions = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { if (it.kind == "link") storedActions.add(it) } }.spans(adjacent)
        assertEquals(2, storedActions.size)
        assertNotSame(storedActions[0], storedActions[1])
        assertEquals("d😀ad😀a", textOf(adjacent))
        val url = "https://example.invalid/a%20b?q=x#part"
        for (label in listOf("label", url)) {
            val external = Span("external_link", "", url, tooltip = "Exact URL",
                inlineActionGroup = InlineActionGroup(listOf(text(label))))
            val decoded = read(Wire('V').document(listOf(external))).displayTitle.single()
            assertEquals(external, decoded)
            assertEquals(url, decoded.target)
            assertEquals(label, textOf(listOf(decoded)))
        }
        val paddedReading = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Em, .25f), listOf(text("zi"))))
        val ruby = owner(listOf(base(text("字"))), listOf(annotation(paddedReading)))
        val rich = source.copy(inlineActionGroup = InlineActionGroup(listOf(ruby)))
        assertEquals(rich, read(Wire('V').document(listOf(rich), features = 20)).displayTitle.single())
        assertEquals("字（zi）", textOf(listOf(rich)))
        val hidden = owner(listOf(base(text("d😀a"))), listOf(annotation(source)))
        val insidePadding = paddedReading.copy(inlinePaddingGroup = paddedReading.inlinePaddingGroup!!.copy(spans = listOf(hidden)))
        val nestedWire = Wire('V'); val nestedBytes = nestedWire.document(listOf(insidePadding), features = 20)
        assertEquals(insidePadding, read(nestedBytes).displayTitle.single())
        assertEquals(nestedWire.at.getValue("root.0.padding.body.0.end"), nestedWire.at.getValue("root.0.action"))
        val nestedRaw = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = nestedRaw::add }.spans(listOf(insidePadding))
        assertEquals(listOf(source), nestedRaw.filter { it.inlineActionGroup != null })
        for (missing in listOf(4, 16)) reject("Hidden action features remain counted",
            changed(nestedBytes, nestedWire.at.getValue("features"), 20 xor missing))
        for (alignment in listOf(false, true)) for (clear in listOf(false, true)) {
            val entry = read(Wire('V').document(listOf(source), features = 20, alignment = alignment, clear = clear))
            assertEquals(source, entry.displayTitle.single())
            assertEquals(alignment, entry.inlineImages.isNotEmpty())
            assertEquals(clear, entry.sections.flatMap { it.blocks }.any { it.ruleStyle?.clear == FigureClear.None })
        }
        val ordinary = text("")
        assertEquals(40, Wire('V').isolatedSpan(ordinary).size)
        assertArrayEquals(Wire('U').isolatedSpan(ordinary), Wire('V').isolatedSpan(ordinary).dropLast(1).toByteArray())
        for (body in listOf(listOf(text("ordinary")), listOf(simple()), listOf(paddedReading)))
            reject("V requires an actual action group", Wire('V').document(body))
        assertEquals(paddedReading, read(Wire('U').document(listOf(paddedReading))).displayTitle.single())
        assertEquals(simple(), read(Wire('S').document(listOf(simple()))).displayTitle.single())
    }

    @Test fun inlineActionGroupsRefuseDuplicateActionsMixedPayloadsAndMalformedVWithoutChangingU() {
        fun action(vararg children: Span) = Span("link", "", "Owner", targetFragment = "part",
            inlineActionGroup = InlineActionGroup(children.toList()))
        val valid = action(text("x"))
        invalid("Empty action child array") { InlineActionGroup(emptyList()) }
        for (value in listOf("", " ", "\u00a0")) {
            val child = text(value)
            val source = action(child)
            assertSame(child, source.inlineActionGroup!!.spans.single())
            assertEquals(source, read(Wire('V').document(listOf(source))).displayTitle.single())
        }
        invalid("Text cannot own action group") { valid.copy(kind = "text", target = "", targetFragment = null) }
        invalid("Action owner requires target") { valid.copy(target = "") }
        invalid("Owner text is not a second label") { valid.copy(text = "x") }
        invalid("Owner trail is not copied after group") { valid.copy(trail = "x") }
        invalid("Owner image is exclusive") { valid.copy(image = InlineImage("Probe.svg")) }
        invalid("Owner Ruby is exclusive") { valid.copy(ruby = simple().ruby) }
        val padding = InlinePaddingGroup(StyleLength(StyleLengthUnit.Px, 1f), StyleLength(StyleLengthUnit.Em, .25f), listOf(text("x")))
        invalid("Owner U is exclusive") { valid.copy(inlinePaddingGroup = padding) }
        invalid("External owner cannot carry internal fragment") { valid.copy(kind = "external_link") }
        invalid("Ordinary empty link cursor remains invalid") { Span("link", "", "Owner", inlineStyle = InlineTextStyle(cursor = InlineCursor.Help)) }
        val styled = valid.copy(inlineStyle = InlineTextStyle(cursor = InlineCursor.Help, wrap = TextWrap.Normal))
        assertEquals(styled, read(Wire('V').document(listOf(styled), features = 16)).displayTitle.single())
        val ordinaryAction = Span("link", "x", "Owner", targetFragment = "part")
        val hidden = owner(listOf(base(text("x"))), listOf(annotation(ordinaryAction)))
        val rp = owner(listOf(base(text("x"))), listOf(annotation(text("y"), before = listOf(ordinaryAction), explicit = true)))
        val actionPadding = Span("text", "", inlinePaddingGroup = padding.copy(spans = listOf(ordinaryAction)))
        for (child in listOf(ordinaryAction, hidden, rp, actionPadding, valid,
            Span("external_link", "x", "https://example.invalid/a"), Span("line_break", ""),
            Span("text", "", image = InlineImage("Probe.svg")), text("x").copy(classes = "wikidict-media"),
            text("x").copy(classes = "wikidict-media-file-Probe.svg"), Span("text", "x", "not text"))) {
            invalid("Invalid or duplicate descendant under action owner") { action(child) }
            val wire = Wire('V'); val bytes = wire.document(listOf(valid)); val key = "root.0.action.body.0"
            reject("Literal invalid action child", replace(bytes, wire.at.getValue("$key.start"), wire.at.getValue("$key.end"),
                Wire('V').isolatedSpan(child)))
        }
        for (control in listOf('\t', '\n', '\r', '\u000c')) for (trail in listOf(false, true)) {
            val bad = if (trail) text("x").copy(trail = control.toString()) else text(control.toString())
            invalid("Raw V body control") { action(bad) }
            val wire = Wire('V'); val bytes = wire.document(listOf(valid)); val key = "root.0.action.body.0"
            reject("Literal raw V control", replace(bytes, wire.at.getValue("$key.start"), wire.at.getValue("$key.end"), Wire('V').isolatedSpan(bad)))
        }
        val states = List(8) { index -> LinkState("#12345$index", index % 2 == 1) }
        val paint = LinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], states[6], states[7], true)
        val matching = owner(listOf(base(text("base"), context = RubyOwner(InlineFontSnapshot(), foreground = "#123450"))),
            listOf(annotation(text("reading"), context = RubyOwner(InlineFontSnapshot(), foreground = "#123450"))))
        for (foreground in listOf(null, "#123450")) {
            val painted = action(matching).copy(foreground = foreground, linkPaint = paint)
            assertSame(matching, painted.inlineActionGroup!!.spans.single())
            assertEquals(painted, read(Wire('V').document(listOf(painted))).displayTitle.single())
        }
        val badReading = annotation(text("reading"), context = RubyOwner(InlineFontSnapshot(), foreground = "#654321"))
        val badSegment = matching.ruby!!.segments.single().copy(annotations = listOf(badReading))
        val conflicting = matching.copy(ruby = Ruby(listOf(badSegment)))
        for (child in listOf(text("x").copy(foreground = "#654321"), matching.copy(foreground = "#654321"),
            Span("text", "", foreground = "#654321", inlinePaddingGroup = padding), conflicting)) {
            invalid("Existing inherited color guard applies to V") { action(child).copy(linkPaint = paint) }
            val wire = Wire('V'); val bytes = wire.document(listOf(valid.copy(linkPaint = paint))); val key = "root.0.action.body.0"
            reject("Literal inherited V color", replace(bytes, wire.at.getValue("$key.start"), wire.at.getValue("$key.end"), Wire('V').isolatedSpan(child)))
        }
        val second = RubyBase(RubyOwner(InlineFontSnapshot()), listOf(text(" ")), listOf(text("b")))
        val gapRuby = owner(listOf(base(text("a")), second))
        invalid("V group cannot be a Ruby gap") {
            val badSecond = second.copy(gapBefore = listOf(valid))
            owner(listOf(base(text("a")), badSecond))
        }
        val gapWire = Wire('V'); val gapBytes = gapWire.document(listOf(action(gapRuby)))
        val gapKey = "root.0.action.body.0.segment0.base1.gap.0"
        reject("Literal V in gap", replace(gapBytes, gapWire.at.getValue("$gapKey.start"), gapWire.at.getValue("$gapKey.end"), Wire('V').isolatedSpan(valid)))
        val wire = Wire('V'); val bytes = wire.document(listOf(valid))
        for (bad in listOf(text(""), text("x"), Span("link", "x", "Owner"), Span("link", "", "Owner", trail = "x"),
            Span("link", "", "Owner", image = InlineImage("Probe.svg")), simple(), Span("text", "", inlinePaddingGroup = padding))) {
            val ownerWire = Wire('V'); val prefix = ownerWire.isolatedSpan(bad)
            val forged = prefix.copyOfRange(0, ownerWire.at.getValue("isolated.action")) + bytes.copyOfRange(wire.at.getValue("root.0.action"), bytes.size)
            reject("Literal conflicting V owner", bytes.copyOfRange(0, wire.at.getValue("root.0.start")) + forged)
        }
        for (value in listOf(2, 255)) reject("Strict V presence", changed(bytes, wire.at.getValue("root.0.action"), value))
        for (count in listOf(0L, 1000L, 0xffff_ffffL)) reject("V child count$count", changed32(bytes, wire.at.getValue("root.0.action.body.count"), count))
        for (size in 0 until bytes.size) reject("Truncated V$size", bytes.copyOf(size))
        reject("Trailing V byte", bytes + byteArrayOf(0))
        for (old in listOf('R', 'S', 'T', 'U')) reject("Old header cannot carry V", changed(bytes, 3, old.code))
        val unknown = runCatching { read(changed(bytes, 3, 'W'.code)) }.exceptionOrNull()
        assertEquals("Unsupported presentation format", unknown!!.message)
    }

    @Test fun inlineActionGroupsShareExistingContentTableAndAggregateBudgetsWithoutSiblingReset() {
        fun action(span: Span) = Span("link", "", "Owner", inlineActionGroup = InlineActionGroup(listOf(span)))
        fun padded(span: Span) = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Px, 1f), StyleLength(StyleLengthUnit.Px, 1f), listOf(span)))
        for (mixed in listOf(false, true)) {
            var source = action(text("leaf"))
            repeat(15) { index -> source = if (mixed && index % 2 == 0) owner(listOf(base(source))) else padded(source) }
            assertEquals(source, read(Wire('V').document(listOf(source))).displayTitle.single())
            assertEquals("leaf", textOf(listOf(source)))
            invalid("V plus wrappers exceed shared content16") { padded(source) }
            val excess = Wire('V').apply { rootOverride = { actionChain(17, mixed, it) } }
            reject("Raw V content17", excess.document(emptyList()))
            val inside = Wire('V').apply { rootOverride = { actionChain(15, mixed, it) } }
            assertEquals("leaf", textOf(listOf(selected(read(inside.document(emptyList(), Sink.Container)), Sink.Container))))
            val outside = Wire('V').apply { rootOverride = { actionChain(16, mixed, it) } }
            reject("Container shares V content budget", outside.document(emptyList(), Sink.Container))
        }
        val source = action(text("深😀"))
        for (depth in listOf(1, 16, 17, 20, 32)) {
            val wire = Wire('V').apply { paragraphOverride = { tableChain(depth, mixed = true) } }
            val entry = read(wire.document(listOf(source), Sink.Body))
            val levels = mutableListOf<Int>(); val raw = mutableListOf<Span>()
            PresentationSpanVisitor { _, _ -> }.apply { onTable = { _, level, _ -> levels.add(level) }; onSpan = raw::add }
                .blocks(entry.sections.single().blocks)
            assertEquals((1..depth).toList(), levels)
            assertEquals(listOf(source, source.inlineActionGroup!!.spans.single()), raw)
        }
        val tooDeep = Wire('V').apply { paragraphOverride = { tableChain(33, mixed = true) } }
        reject("V table depth33", tooDeep.document(listOf(source), Sink.Body))
        val absent = Wire('V').apply { paragraphOverride = { tableChain(20) } }
        reject("Deep V still requires action group", absent.document(listOf(simple()), Sink.Body))
        val cyclic = mutableListOf(text("leaf"))
        val u = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Px, 1f), StyleLength(StyleLengthUnit.Px, 1f), cyclic))
        val top = action(u)
        cyclic[0] = u
        invalid("Cycle under V shares bounded traversal") { PresentationSpanVisitor { _, _ -> }.spans(listOf(top)) }
        val empty = text("")
        val payload = InlineActionGroup(java.util.Collections.nCopies((1 shl 20) - 1, empty))
        val exactly = Span("link", "", "Owner", inlineActionGroup = payload)
        var visited = 0
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { visited++ } }.spans(listOf(exactly))
        assertEquals(1 shl 20, visited)
        invalid("Sibling owner cannot reset V aggregate budget") { PresentationSpanVisitor { _, _ -> }.spans(listOf(exactly, source)) }
        val over = InlineActionGroup(java.util.Collections.nCopies(1 shl 20, empty))
        invalid("V owner is charged once, beyond full child budget") { Span("link", "", "Owner", inlineActionGroup = over) }
    }
}
