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
    private class Wire(private val version: Char = 'S', private val yFlags: Int = 0) {
        private val out = ByteArrayOutputStream()
        val at = linkedMapOf<String, Int>()
        var rootOverride: ((String) -> Unit)? = null
        var paragraphOverride: (() -> Unit)? = null
        var containerStyleOverride: ((String) -> Unit)? = null
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
            string(value.language); string(value.classes); string(value.direction, "$label.direction"); string(value.explanation)
            byte(if (value.foreground == null) 0 else 1); value.foreground?.let { string(it) }
            byte(if (value.background == null) 0 else 1); value.background?.let { string(it) }
            val fields = (if (value.fontScale != null) 1 else 0) or (if (value.fontFeatures != null) 2 else 0) or
                (if (value.linkPaint != null) 4 else 0) or (if (value.inlineStyle != null) 8 else 0) or (if (value.fontFamily != null) 16 else 0) or
                (if (value.inlineBoxGroup?.radius != null) 0x20 else 0) or (if (value.inlineBoxGroup?.atomicLayout != null) 0x40 else 0)
            mark("$label.fontFields"); byte(fields)
            value.fontScale?.let { f32(it); byte(value.fontScaleBasis.ordinal) }
            value.fontFeatures?.let { byte(it.ordinal) }
            value.linkPaint?.let { byte(1); linkPaint(it) }
            value.inlineStyle?.let { inlineStyle(it, "$label.style") }
            value.fontFamily?.let { require(it == ContainerFontFamily.SansSerif); byte(0) }
            mark("$label.image")
            val image = value.image
            byte(if (image == null) 0 else if (image.verticalAlign != null) 3 else 1)
            if (image != null) {
                require(image.map == null && image.staticPoster == null && image.svgLanguage == null && image.darkModeFilter == null)
                string(image.file)
                byte((if (image.widthPx != null) 1 else 0) or (if (image.heightPx != null) 2 else 0) or
                    (if (image.alt != null) 4 else 0) or (if (image.tooltip != null) 8 else 0) or (if (image.border) 16 else 0))
                image.widthPx?.let(::u32); image.heightPx?.let(::u32)
                image.alt?.let { string(it) }; image.tooltip?.let { string(it) }
                image.verticalAlign?.let { byte(it.ordinal) }
                if ((version == 'Y' || version == 'Z') && yFlags and 32 != 0) {
                    mark("$label.image.occurrence"); byte(if (image.occurrenceLayout == null) 0 else 1)
                    image.occurrenceLayout?.let { layout ->
                        listOf("x" to layout.x, "y" to layout.y, "left" to layout.paddingLeft, "right" to layout.paddingRight)
                            .forEach { (name, length) ->
                                mark("$label.image.occurrence.$name"); byte(length.unit.ordinal); f32(length.value)
                            }
                    }
                    mark("$label.image.occurrence.end")
                } else require(image.occurrenceLayout == null)
            }
            byte(if (value.targetFragment == null) 0 else 1); value.targetFragment?.let { string(it) }
            mark("$label.tooltip"); byte(if (value.tooltip == null) 0 else 1); value.tooltip?.let { string(it) }
            if (version == 'S' || version == 'T' || version == 'U' || version == 'V' || (version == 'Y' || version == 'Z')) {
                mark("$label.ruby"); byte(if (value.ruby == null) 0 else 1)
                value.ruby?.let { ruby(it, label) }
            } else require(value.ruby == null)
            if (version == 'U' || version == 'V' || (version == 'Y' || version == 'Z')) {
                mark("$label.padding"); byte(if (value.inlinePaddingGroup == null) 0 else 1)
                value.inlinePaddingGroup?.let { group ->
                    mark("$label.padding.left"); byte(group.left.unit.ordinal); f32(group.left.value)
                    mark("$label.padding.right"); byte(group.right.unit.ordinal); f32(group.right.value)
                    spans(group.spans, "$label.padding.body")
                }
            } else require(value.inlinePaddingGroup == null)
            mark("$label.padding.end")
            if (version == 'V' || (version == 'Y' || version == 'Z')) {
                mark("$label.action"); byte(if (value.inlineActionGroup == null) 0 else 1)
                value.inlineActionGroup?.let { spans(it.spans, "$label.action.body") }
            } else require(value.inlineActionGroup == null)
            if ((version == 'Y' || version == 'Z') && yFlags and 4 != 0) {
                mark("$label.box"); byte(if (value.inlineBoxGroup == null) 0 else 1)
                value.inlineBoxGroup?.let { inlineBox(it, "$label.box") }
            } else require(value.inlineBoxGroup == null)
            if ((version == 'Y' || version == 'Z') && yFlags and 64 != 0) {
                val name = "$label.citation"
                mark(name); byte(if (value.citationMarker == null) 0 else 1)
                value.citationMarker?.let { marker ->
                    mark("$name.reference"); u32(marker.reference)
                    mark("$name.occurrence"); u32(marker.occurrence)
                    string(marker.anchor, "$name.anchor")
                    mark("$name.policy"); byte((if (marker.nowrap) 1 else 0) or
                        (if (marker.targetStyle != null) 2 else 0) or (if (marker.isolation != null) 4 else 0))
                    marker.isolation?.let { mark("$name.isolation"); byte(it.ordinal) }
                    marker.targetStyle?.let { style ->
                        linkPaint(style.paint); mark("$name.background"); byte(if (style.background == null) 0 else 1)
                        when (val color = style.background) {
                            null -> Unit
                            FigureColor.NativeTheme -> byte(0)
                            FigureColor.Transparent -> byte(1)
                            is FigureColor.Rgb -> { byte(2); string(color.value) }
                        }
                    }
                }
            } else require(value.citationMarker == null)
            if (version == 'Z' && yFlags and 8192 != 0) audioTail(value.audioControl, "$label.audio")
            else require(value.audioControl == null)
            if ((version == 'Y' || version == 'Z') && yFlags and 128 != 0) {
                mark("$label.clipped"); byte(if (value.clippedAbsolute == null) 0 else 1)
                value.clippedAbsolute?.let { clipped ->
                    mark("$label.clipped.staticParentDirection")
                    byte(when (clipped.staticParentDirection) { BidiResolvedDirection.Ltr -> 1; BidiResolvedDirection.Rtl -> 2 })
                    mark("$label.clipped.width"); byte(clipped.width.unit.ordinal); f32(clipped.width.value)
                    mark("$label.clipped.height"); byte(clipped.height.unit.ordinal); f32(clipped.height.value)
                    listOf("top" to clipped.margin.top, "right" to clipped.margin.right,
                        "bottom" to clipped.margin.bottom, "left" to clipped.margin.left).forEach { (name, margin) ->
                        val length = (margin as ContainerMargin.Length).value
                        mark("$label.clipped.$name"); byte(length.unit.ordinal); f32(length.value)
                    }
                    mark("$label.clipped.children.count"); u32(clipped.children.size.toLong())
                    clipped.children.forEachIndexed { index, child -> span(child, "$label.clipped.child.$index") }
                }
            } else require(value.clippedAbsolute == null)
            mark("$label.end")
        }
        private fun audioTail(value: AudioControl?, label: String) {
            mark(label); byte(if (value == null) 0 else 1)
            if (value == null) return
            mark("$label.fields"); byte((if (value.width != null) 1 else 0) or
                (if (value.height != null) 2 else 0) or (if (value.focus != null) 4 else 0))
            value.width?.let { mark("$label.width.unit"); byte(it.unit.ordinal); mark("$label.width.value"); f32(it.value) }
            value.height?.let { mark("$label.height.unit"); byte(it.unit.ordinal); mark("$label.height.value"); f32(it.value) }
            value.focus?.let { focus ->
                mark("$label.focus.mode"); byte(focus.mode.ordinal)
                mark("$label.focus.presence"); byte(if (focus.color == null) 0 else 1)
                if (focus.color != null) {
                    mark("$label.focus.color")
                    when (val color = checkNotNull(focus.color)) {
                        FigureColor.NativeTheme -> byte(0)
                        FigureColor.Transparent -> byte(1)
                        is FigureColor.Rgb -> { byte(2); string(color.value, "$label.focus.rgb") }
                    }
                }
            }
        }
        fun isolatedAudioTail(value: Span): ByteArray { audioTail(value.audioControl, "isolated.audio"); return out.toByteArray() }
        private fun boxLength(value: StyleLength, label: String) {
            mark(label); byte(value.unit.ordinal); f32(value.value)
        }
        private fun boxColor(value: InlineBoxColor, label: String) {
            mark(label)
            when (value) {
                InlineBoxColor.CurrentColor -> byte(0)
                InlineBoxColor.Transparent -> byte(1)
                is InlineBoxColor.Rgb -> { byte(2); string(value.value, "$label.rgb") }
                is InlineBoxColor.LightDark -> { byte(3); string(value.light, "$label.light"); string(value.dark, "$label.dark") }
            }
        }
        private fun boxBorder(value: InlineBoxBorderEdges, label: String) {
            listOf(value.top, value.right, value.bottom, value.left).forEachIndexed { index, edge ->
                val name = "$label.$index"; mark(name)
                when (edge) {
                    InlineBoxBorderEdge.None -> byte(0)
                    InlineBoxBorderEdge.Hidden -> byte(1)
                    is InlineBoxBorderEdge.Solid -> { byte(2); boxLength(edge.width, "$name.width"); boxColor(edge.color, "$name.color") }
                    is InlineBoxBorderEdge.Dotted -> { byte(3); boxLength(edge.width, "$name.width"); boxColor(edge.color, "$name.color") }
                }
            }
        }
        private fun boxOverlayContent(value: InlineBoxOverlayContent, label: String) {
            mark("$label.start"); mark("$label.beforeChild"); u32(value.beforeChild)
            fontSnapshot(value.ownerFont, "$label.font")
            mark("$label.lineHeight")
            when (val height = value.lineHeight) {
                null -> byte(0)
                is InlineLineHeight.Computed -> { byte(1); f32(height.value.value); byte(height.value.fontScaleBasis.ordinal) }
                is InlineLineHeight.FontRelative -> { byte(2); f32(height.factor); fontSnapshot(height.font, "$label.heightFont") }
            }
            mark("$label.align"); byte(value.textAlign.ordinal)
            spans(value.spans, "$label.body")
            mark("$label.end")
        }
        private fun boxOverlay(value: InlineBoxOverlay, label: String) {
            val sides = listOf(value.insets.top, value.insets.right, value.insets.bottom, value.insets.left)
            mark("$label.flags"); byte(sides.withIndex().sumOf { (index, inset) -> if (inset == null) 0 else 1 shl index } or
                (if (value.content != null) 0x10 else 0))
            sides.forEachIndexed { index, inset -> if (inset != null) {
                mark("$label.inset$index"); byte(inset.unit.ordinal); f32(inset.value)
            } }
            boxBorder(value.border, "$label.border")
            value.content?.let { boxOverlayContent(it, "$label.content") }
        }
        private fun inlineBox(value: InlineBoxGroup, label: String) {
            listOf(value.padding.top, value.padding.right, value.padding.bottom, value.padding.left)
                .forEachIndexed { index, edge -> boxLength(edge, "$label.padding$index") }
            boxBorder(value.border, "$label.border")
            mark("$label.overlays"); u32(value.overlays.size.toLong())
            value.overlays.forEachIndexed { index, overlay -> boxOverlay(overlay, "$label.overlay$index") }
            spans(value.spans, "$label.body")
            mark("$label.childrenEnd")
            value.radius?.let { mark("$label.radius"); byte(it.unit.ordinal); f32(it.value) }
            value.atomicLayout?.let { atomic ->
                mark("$label.atomic")
                boxLength(atomic.width, "$label.atomic.width"); boxLength(atomic.height, "$label.atomic.height")
                listOf(atomic.margins.top, atomic.margins.right, atomic.margins.bottom, atomic.margins.left)
                    .forEachIndexed { index, edge -> boxLength(edge, "$label.atomic.margin$index") }
                mark("$label.atomic.sizing"); byte(atomic.boxSizing.ordinal)
                mark("$label.atomic.align"); byte(atomic.textAlign.ordinal)
                mark("$label.atomic.wrap"); byte(atomic.wrap.ordinal)
                mark("$label.atomic.lineHeight")
                when (val height = atomic.lineHeight) {
                    null -> byte(0)
                    is InlineLineHeight.Computed -> { byte(1); f32(height.value.value); byte(height.value.fontScaleBasis.ordinal) }
                    is InlineLineHeight.FontRelative -> { byte(2); f32(height.factor); fontSnapshot(height.font, "$label.atomic.heightFont") }
                }
                mark("$label.atomic.end")
            }
            mark("$label.end")
        }
        private fun referenceBlock(value: Block, label: String) {
            if (version == 'Z') { positionedBlock(value, label); return }
            val container = value.container
            when {
                value == Block("paragraph", 0, value.spans) -> {
                    byte(0); byte(0); byte(0); spans(value.spans, "$label.spans")
                    byte(0); string(""); string(""); byte(0); tail()
                }
                container != null && value == Block("container", 0, emptyList(), container = container) &&
                    container.style == ContainerStyle() -> {
                    prefix(13); byte(0); tail(); u32(0); u32(container.blocks.size.toLong())
                    container.blocks.forEachIndexed { index, child -> referenceBlock(child, "$label.block$index") }
                }
                else -> error("Reference fixture requires a fully represented ordinary block")
            }
        }
        private fun reference(value: Reference, index: Int) {
            val label = "references.$index"
            byte(if (value.kind == ReferenceKind.Note) 0 else 1); u32(value.number)
            if (value.kind == ReferenceKind.Note) { u32(checkNotNull(value.groupNumber)); string("") }
            string(value.group); spans(value.spans, "$label.spans")
            byte(if (value.blocks == null) 0 else 1)
            value.blocks?.let { blocks ->
                u32(blocks.size.toLong()); blocks.forEachIndexed { at, block -> referenceBlock(block, "$label.block$at") }
            }
        }
        private fun bodyTypography(value: BodyTypography, label: String = "body") {
            mark("$label.start"); fontSnapshot(value.ownerFont, "$label.font")
            mark("$label.lineHeight"); byte(if (value.lineHeight == null) 0 else 1)
            when (val height = value.lineHeight) {
                null -> Unit
                ContainerLineHeight.Normal -> byte(0)
                is ContainerLineHeight.Multiplier -> { byte(1); f32(height.value) }
                is ContainerLineHeight.Length -> { byte(2); boxLength(height.value, "$label.length") }
            }
            if ((version == 'Y' || version == 'Z') && yFlags and 16 != 0) {
                mark("$label.direction"); byte(when (value.direction) {
                    null -> 0
                    BidiResolvedDirection.Ltr -> 1
                    BidiResolvedDirection.Rtl -> 2
                })
            } else require(value.direction == null)
            mark("$label.end")
        }
        /** Raw Y owners exercise depth beyond constructor admission without a second codec. */
        fun boxChain(depth: Int, label: String) {
            require((version == 'Y' || version == 'Z') && yFlags and 4 != 0)
            mark("$label.count"); u32(1)
            fun nested(left: Int, name: String) {
                if (left == 0) { span(Span("text", "leaf"), name); return }
                out.write(Wire('V').isolatedSpan(Span("text", ""))); byte(1)
                repeat(4) { length() }; repeat(4) { byte(0) }; u32(0); u32(1)
                nested(left - 1, "$name.child")
            }
            nested(depth, "$label.0")
        }
        /** Reuses one literal overlay record, without a million test-only offset keys. */
        fun boxBudget(count: Int, label: String, following: Span? = null) {
            require((version == 'Y' || version == 'Z') && yFlags and 4 != 0)
            mark("$label.count"); u32(if (following == null) 1 else 2)
            out.write(Wire('V').isolatedSpan(Span("text", ""))); byte(1)
            repeat(4) { length() }; repeat(4) { byte(0) }; u32(count.toLong())
            val record = Wire('Y', yFlags).apply {
                byte(3); byte(0); f32(0f); byte(0); f32(0f); repeat(4) { byte(0) }
            }.out.toByteArray()
            repeat(count) { out.write(record) }
            spans(listOf(Span("text", "x")), "$label.0.box.body")
            if (yFlags and 64 != 0) byte(0) // No marker on the raw Box owner.
            if (version == 'Z' && yFlags and 8192 != 0) byte(0) // No AUDIO policy on the raw Box owner.
            if (yFlags and 128 != 0) byte(0) // The raw Box owner also has the nullable clipped tail.
            following?.let { span(it, "$label.1") }
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
        private fun fontFamily(value: ContainerFontFamily) = when (value) {
            ContainerFontFamily.SansSerif -> byte(0)
            is ContainerFontFamily.Stack -> {
                byte(1); u32(value.names.size.toLong()); value.names.forEach { string(it) }; byte(value.fallback.ordinal)
            }
        }
        fun containerOwnerStyle(owner: InlineFontSnapshot, scale: Float? = null,
            family: ContainerFontFamily? = null, label: String = "owned") {
            mark("$label.style")
            u32((0x1000000 or (if (scale != null) 0x10000 else 0) or (if (family != null) 0x400000 else 0)).toLong())
            scale?.let(::f32); family?.let(::fontFamily)
            fontSnapshot(owner, "$label.owner")
            if (version == 'Z' && yFlags and 256 != 0) byte(0)
        }
        fun ownedParagraph(owner: InlineFontSnapshot, empty: Boolean = false) {
            prefix(13); byte(0); tail(); containerOwnerStyle(owner)
            u32(if (empty) 0 else 1)
            if (!empty) { prefix(0, true); byte(0); tail(); columnLayoutTail() }
            columnLayoutTail()
        }
        /** Repeated records share no test offset map; the wire still contains each real owner. */
        fun ownerBudget(count: Int, owner: InlineFontSnapshot) {
            prefix(13); byte(0); tail(); u32(0)
            if (version == 'Z' && yFlags and 256 != 0) byte(0)
            u32(count.toLong())
            val record = Wire(version, yFlags).apply { ownedParagraph(owner, empty = true) }.out.toByteArray()
            repeat(count) { out.write(record) }
            columnLayoutTail()
        }
        private fun disclosureColor(value: FigureColor, label: String) {
            mark(label)
            when (value) {
                FigureColor.NativeTheme -> byte(0)
                FigureColor.Transparent -> byte(1)
                is FigureColor.Rgb -> { byte(2); string(value.value, "$label.rgb") }
            }
        }
        private fun disclosureRun(value: ContainerDisclosureLabelRun, label: String) {
            mark(label); mark("$label.start"); u32(value.start); mark("$label.end"); u32(value.end)
            val states = listOf(value.paint.normal, value.paint.hover, value.paint.active, value.paint.hoverActive)
            states.forEachIndexed { index, state -> string(state.foreground, "$label.color$index") }
            var flags = if (value.paint.underlineOnFocus) 16 else 0
            states.forEachIndexed { index, state -> if (state.underline) flags = flags or (1 shl index) }
            mark("$label.flags"); byte(flags)
        }
        private fun disclosure(value: ContainerDisclosure, label: String) {
            mark(label); mark("$label.index"); u32(value.contentIndex)
            mark("$label.collapsed"); byte(if (value.initiallyCollapsed) 1 else 0)
            string(value.expandLabel, "$label.expand"); string(value.collapseLabel, "$label.collapse")
            mark("$label.focus"); byte(if (value.focus == null) 0 else 1)
            value.focus?.let { focus ->
                mark("$label.focus.mode"); byte(focus.mode.ordinal)
                mark("$label.focus.presence"); byte(if (focus.color == null) 0 else 1)
                focus.color?.let { disclosureColor(it, "$label.focus.color") }
            }
            mark("$label.placement"); byte(value.placement.ordinal)
            mark("$label.fields"); byte((if (value.foreground != null) 1 else 0) or
                (if (value.direction != null) 2 else 0) or (if (value.expandRun != null) 4 else 0) or
                (if (value.collapseRun != null) 8 else 0))
            value.foreground?.let { disclosureColor(it, "$label.foreground") }
            value.direction?.let { mark("$label.direction"); byte(it.ordinal) }
            value.expandRun?.let { disclosureRun(it, "$label.expandRun") }
            value.collapseRun?.let { disclosureRun(it, "$label.collapseRun") }
            mark("$label.end")
        }
        fun disclosureTableChain(policy: ContainerDisclosure, depth: Int) {
            prefix(13); byte(0); tail(); positionedStyle(ContainerStyle(), "tableOwner.style", policy)
            u32(1); prefix(13); byte(0); tail(); positionedStyle(ContainerStyle(), "tableContent.style")
            u32(1); tableChain(depth, mixed = true); columnLayoutTail(); columnLayoutTail()
        }
        /** Literal Z Container subset; existing primitives retain every ordinary span field. */
        fun positionedStyle(value: ContainerStyle, label: String, disclosure: ContainerDisclosure? = null) {
            require(value == ContainerStyle(width = value.width, lineHeight = value.lineHeight,
                textAlign = value.textAlign, overflow = value.overflow, ownerFontScale = value.ownerFontScale,
                height = value.height, columns = value.columns, positioning = value.positioning, fontFamily = value.fontFamily,
                ownerFont = value.ownerFont, absolutePosition = value.absolutePosition, textWrap = value.textWrap, absoluteStatic = value.absoluteStatic))
            mark("$label.flags")
            val flags = (if (value.width != null) 4 else 0) or (if (value.lineHeight != null) 4096 else 0) or
                (if (value.textAlign != null) 8192 else 0) or (if (value.overflow != null) 32768 else 0) or
                (if (value.ownerFontScale != null) 65536 else 0) or (if (value.height != null) 131072 else 0) or
                (if (value.positioning != null) 524288 else 0) or (if (value.fontFamily != null) 4194304 else 0) or
                (if (value.ownerFont != null) 16777216 else 0) or (if (value.columns != null) 262144 else 0) or
                (if (value.columns?.width != null || value.columns?.direction != null) 0x02000000 else 0)
            u32(flags.toLong())
            value.width?.let { width ->
                mark("$label.width")
                when (width) {
                    ContainerWidth.Auto -> byte(0)
                    ContainerWidth.FitContent -> byte(2)
                    is ContainerWidth.Length -> { byte(1); mark("$label.width.unit"); byte(width.value.unit.ordinal)
                        mark("$label.width.value"); f32(width.value.value) }
                }
            }
            value.lineHeight?.let { height ->
                mark("$label.lineHeight")
                when (height) {
                    ContainerLineHeight.Normal -> byte(0)
                    is ContainerLineHeight.Multiplier -> { byte(1); f32(height.value) }
                    is ContainerLineHeight.Length -> { byte(2); positionedLength(height.value, "$label.lineHeight.length") }
                }
            }
            value.textAlign?.let { mark("$label.textAlign"); byte(it.ordinal) }
            value.overflow?.let { mark("$label.overflow"); byte(it.ordinal) }
            value.ownerFontScale?.let(::f32)
            value.height?.let { positionedLength(it, "$label.height") }
            value.columns?.let { columns ->
                mark("$label.columnCount"); u16(columns.count ?: 0)
                positionedLength(columns.gap, "$label.columnGap")
            }
            value.positioning?.let { require(it == ContainerPositioning.RelativeAuto); byte(0) }
            value.fontFamily?.let(::fontFamily)
            value.ownerFont?.let { fontSnapshot(it, "$label.owner") }
            if (version == 'Z' && yFlags and 256 != 0) {
                mark("$label.extension")
                byte((if (value.absolutePosition != null) 1 else 0) or (if (value.textWrap != null) 2 else 0) or (if (value.absoluteStatic != null) 4 else 0) or (if (disclosure != null) 8 else 0))
                value.absolutePosition?.let {
                    positionedLength(it.left, "$label.left"); positionedLength(it.top, "$label.top")
                }
                value.textWrap?.let {
                    mark("$label.wrap")
                    byte(when (it) { TextWrap.Normal -> 0; TextWrap.NoWrap -> 1; else -> error("Unsupported fixture wrap") })
                }
                value.absoluteStatic?.let { mark("$label.static"); byte(it.direction.ordinal) }
                disclosure?.let { this.disclosure(it, "$label.disclosure") }
            } else require(value.absolutePosition == null && value.textWrap == null && value.absoluteStatic == null && disclosure == null)
            value.columns?.takeIf { it.width != null || it.direction != null }?.let { columns ->
                mark("$label.columnExtension"); byte((if (columns.width != null) 1 else 0) or (if (columns.direction != null) 2 else 0))
                columns.width?.let { positionedLength(it, "$label.columnWidth") }
                columns.direction?.let { mark("$label.columnDirection"); byte(it.ordinal) }
            }
            mark("$label.end")
        }
        fun isolatedPositionedStyle(value: ContainerStyle): ByteArray {
            positionedStyle(value, "isolatedStyle")
            return out.toByteArray()
        }
        private fun positionedLength(value: ContainerMarginLength, label: String) {
            mark("$label.unit"); byte(value.unit.ordinal); mark("$label.value"); f32(value.value)
        }
        /** Full real child lists, including Table/cell boundaries, without another encoder. */
        fun positionedBlock(value: Block, label: String = "positioned") {
            val container = value.container
            val table = value.table
            when {
                container != null -> {
                    require(value == Block("container", 0, emptyList(), container = container))
                    prefix(13); byte(0); tail(); positionedStyle(container.style, "$label.style", container.disclosure)
                    mark("$label.children"); u32(container.blocks.size.toLong())
                    container.blocks.forEachIndexed { index, child -> positionedBlock(child, "$label.child$index") }
                }
                table != null -> {
                    require(value == Block("table", 0, emptyList(), table = table))
                    prefix(12); positionedTable(table, "$label.table"); tail()
                }
                else -> {
                    require(value == Block(value.kind, value.depth, value.spans, listPath = value.listPath,
                        number = value.number, textAlign = value.textAlign, columnBreakInside = value.columnBreakInside))
                    val tag = when (value.kind) { "paragraph" -> 0; "definition" -> 2; "example" -> 3; "quotation" -> 4
                        "list_item" -> 5; "list_detail" -> 6; "indent" -> 7; "term" -> 8; else -> error("Unsupported fixture block") }
                    byte(tag); byte(value.depth); byte(0); spans(value.spans, "$label.spans")
                    byte(0); string(value.listPath); string(value.number); byte(0)
                    tail(alignment = value.textAlign, alignmentLabel = "$label.alignment")
                }
            }
            columnLayoutTail(value.columnBreakInside, "$label.columnBreakInside")
        }
        private fun minimumTableStyle(value: TableStyle?, label: String) {
            mark("$label.presence"); byte(if (value == null) 0 else 1)
            if (value == null) return
            val flags = (if (value.background != null) 1 else 0) or (if (value.border != null) 2 else 0) or
                (if (value.collapse != null) 4 else 0) or (if (value.margins != null) 8 else 0) or
                (if (value.floatSide != null) 16 else 0) or (if (value.width != null) 32 else 0) or
                (if (value.padding != null) 64 else 0) or (if (value.clear != null) 128 else 0)
            val extension = (if (value.display != null) 1 else 0) or (if (value.verticalAlign != null) 2 else 0) or
                (if (value.lineHeight != null) 4 else 0) or (if (value.marginValues != null) 8 else 0) or (if (value.containingDirection != null) 16 else 0) or
                (if (value.cornerRadii != null) 32 else 0) or (if (value.minWidth != null) 64 else 0)
            require(value.minWidth == null || version == 'Z' && yFlags and 512 != 0)
            mark("$label.flags"); byte(flags); mark("$label.extension"); byte(extension)
            value.background?.let { string(it) }
            value.border?.let { border -> when (border) {
                StyleBorder.None -> byte(0)
                is StyleBorder.Solid -> { byte(1); positionedLength(border.width, "$label.border"); string(border.color) }
                else -> error("Unsupported fixture border")
            } }
            value.collapse?.let { byte(it.ordinal) }
            fun edges(edges: StyleEdges, name: String) {
                listOf(edges.top, edges.right, edges.bottom, edges.left).forEachIndexed { index, length -> positionedLength(length, "$label.$name.$index") }
            }
            value.margins?.let { edges(it, "margins") }
            value.floatSide?.let { byte(it.ordinal) }
            value.width?.let { mark("$label.width"); byte(it.unit.ordinal); f32(it.value) }
            value.padding?.let { edges(it, "padding") }
            value.clear?.let { byte(it.ordinal) }
            value.display?.let { byte(it.ordinal) }
            value.verticalAlign?.let { byte(it.ordinal) }
            value.lineHeight?.let { f32(it.value); byte(it.fontScaleBasis.ordinal) }
            value.marginValues?.let { margins ->
                listOf(margins.top, margins.right, margins.bottom, margins.left).forEachIndexed { index, margin -> when (margin) {
                    ContainerMargin.Auto -> byte(0)
                    is ContainerMargin.Length -> { byte(1); positionedLength(margin.value, "$label.marginValue.$index") }
                } }
            }
            value.containingDirection?.let { byte(it.ordinal) }
            value.cornerRadii?.let { corners ->
                listOf(corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft).forEachIndexed { index, radius ->
                    positionedLength(radius, "$label.corner.$index")
                }
            }
            mark("$label.oldEnd")
            value.minWidth?.let { mark("$label.minimum.unit"); byte(it.unit.ordinal); mark("$label.minimum.value"); f32(it.value) }
            mark("$label.end")
        }
        fun isolatedMinimumTableStyle(value: TableStyle?): ByteArray {
            minimumTableStyle(value, "isolatedTable")
            return out.toByteArray()
        }
        /** Raw responsive style slots, so malformed policy occurrences reach the real decoder. */
        fun responsiveMinimum(outer: TableStyle?, box: TableStyle, grid: TableStyle) {
            prefix(12); byte(3); byte(0); spans(emptyList(), "responsive.caption"); u32(0)
            minimumTableStyle(outer, "responsive.outer"); byte(0)
            u32(100); minimumTableStyle(box, "responsive.box"); byte(ContainerBoxSizing.ContentBox.ordinal)
            byte(StyleWidthUnit.Percent.ordinal); f32(100f)
            minimumTableStyle(grid, "responsive.grid"); byte(TableContainingDirection.Ltr.ordinal); string("ja")
            tail(); columnLayoutTail()
        }
        /** Existing CellStyle field order, with the scalar opacity suffix after line height. */
        private fun opacityCellStyle(value: CellStyle?, label: String) {
            mark("$label.presence"); byte(if (value == null) 0 else 1)
            if (value == null) return
            require(value.borderEdges == null && value.letterSpacing == null)
            val flags = (if (value.border != null) 1 else 0) or (if (value.padding != null) 2 else 0) or
                (if (value.textAlign != null) 4 else 0) or (if (value.lineHeight != null) 8 else 0) or
                (if (value.opacity != null) 16 else 0) or (if (value.width != null) 32 else 0) or
                (if (value.minWidth != null) 64 else 0) or (if (value.verticalAlign != null) 128 else 0)
            mark("$label.flags"); byte(flags)
            value.border?.let { border -> when (border) {
                StyleBorder.None -> byte(0)
                is StyleBorder.Solid -> { byte(1); positionedLength(border.width, "$label.border"); string(border.color) }
                else -> error("Unsupported fixture border")
            } }
            value.padding?.let { edges -> listOf(edges.top, edges.right, edges.bottom, edges.left)
                .forEachIndexed { index, length -> positionedLength(length, "$label.padding.$index") } }
            value.textAlign?.let { byte(it.ordinal) }
            value.width?.let { byte(it.unit.ordinal); f32(it.value) }
            value.minWidth?.let { positionedLength(it, "$label.minimum") }
            value.verticalAlign?.let { byte(it.ordinal) }
            mark("$label.lineHeight")
            value.lineHeight?.let { lineHeight ->
                val strut = lineHeight.strut
                require(strut?.ownerFont == null)
                byte(if (strut == null) 0 else 1)
                strut?.let { f32(it.fontScale); byte(it.fontScaleBasis.ordinal) }
                when (val height = lineHeight.height) {
                    CellLineHeightValue.Normal -> byte(0)
                    is CellLineHeightValue.Multiplier -> { byte(1); f32(height.value) }
                    is CellLineHeightValue.Length -> { byte(2); f32(height.value.value); byte(height.value.fontScaleBasis.ordinal) }
                }
            }
            mark("$label.oldEnd")
            value.opacity?.let { mark("$label.opacity"); f32(it) }
            mark("$label.end")
        }
        private fun positionedTable(value: Table, label: String) {
            require(value.geometry == null && value.blockViewport == null && value.floatViewport == null)
            mark("$label.flags"); byte(if (value.rowsHiddenMaxWidthPx == null) 1 else 0x21)
            byte(0); spans(value.caption, "$label.caption"); mark("$label.rows"); u32(value.rows.size.toLong())
            value.rows.forEachIndexed { rowIndex, row ->
                u32(row.size.toLong())
                row.forEachIndexed { cellIndex, cell ->
                    val name = "$label.row$rowIndex.cell$cellIndex"
                    byte(if (cell.header) 1 else 0); u16(cell.colspan); u16(cell.rowspan)
                    byte(if (cell.background == null) 0 else 1); cell.background?.let { string(it) }
                    spans(cell.spans, "$name.spans")
                    if (cell.nestedTable == null) byte(0) else positionedTable(cell.nestedTable, "$name.nested")
                    byte(if (cell.blocks == null) 0 else 1)
                    cell.blocks?.let { blocks -> u32(blocks.size.toLong())
                        blocks.forEachIndexed { index, child -> positionedBlock(child, "$name.block$index") } }
                    opacityCellStyle(cell.style, "$name.style")
                }
            }
            minimumTableStyle(value.style, "$label.style"); byte(if (value.captionBlocks == null) 0 else 1)
            value.captionBlocks?.let { blocks -> u32(blocks.size.toLong())
                blocks.forEachIndexed { index, child -> positionedBlock(child, "$label.captionBlock$index") } }
            mark("$label.oldEnd")
            value.rowsHiddenMaxWidthPx?.let { mark("$label.rowsHiddenMaxWidth"); u32(it) }
        }
        fun audioPrefixTable(value: Table) {
            prefix(12, true); positionedTable(value, "audioPrefix.table"); tail(); columnLayoutTail()
        }
        fun positionedBudget(count: Int) {
            val zero = StyleLength(StyleLengthUnit.Px, 0f)
            val absolute = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 0f)), height = zero,
                absolutePosition = ContainerAbsolutePosition(zero, zero))
            fun label(text: String) = Block("container", 0, emptyList(), container = Container(listOf(
                Block("paragraph", 0, listOf(Span("link", text, "Budget target")))), absolute))
            // Each empty row is a real counted collection node, without a separately styled Container graph.
            val rows = java.util.Collections.nCopies(count, emptyList<Cell>())
            positionedBlock(Block("container", 0, emptyList(), container = Container(listOf(label("before"),
                Block("table", 0, emptyList(), table = Table(emptyList(), rows)), label("after")),
                ContainerStyle(positioning = ContainerPositioning.RelativeAuto))), "budgetRoot")
        }
        private fun referenceLayoutStyle(value: ContainerStyle, label: String) {
            require(validReferenceLayoutStyle(value) && value.border == ContainerBorder.None &&
                value.background == ContainerColor.Transparent && value.lineHeight == ContainerLineHeight.Normal &&
                value == ContainerStyle(margins = value.margins, padding = value.padding,
                    border = value.border, background = value.background, layout = value.layout,
                    clear = value.clear, overflow = value.overflow, ownerFont = value.ownerFont,
                    lineHeight = value.lineHeight))
            mark("$label.flags")
            u32((1 or 2 or 16 or 128 or 1024 or 2048 or 4096 or 32768 or 16777216).toLong())
            val margins = checkNotNull(value.margins)
            listOf(margins.top, margins.right, margins.bottom, margins.left).forEach { byte(it.unit.ordinal); f32(it.value) }
            val padding = checkNotNull(value.padding)
            listOf(padding.top, padding.right, padding.bottom, padding.left).forEach { byte(it.unit.ordinal); f32(it.value) }
            byte(0); byte(0); byte(0); byte(0); byte(0); byte(0)
            fontSnapshot(checkNotNull(value.ownerFont), "$label.owner")
            if (version == 'Z' && yFlags and 256 != 0) byte(0)
        }
        private fun referenceLayoutColor(value: ContainerColor) {
            when (value) {
                ContainerColor.Transparent -> byte(0)
                is ContainerColor.Rgb -> { byte(1); string(value.value) }
                is ContainerColor.LightDark -> { byte(2); string(value.light); string(value.dark) }
            }
        }
        private fun referenceLayouts(batches: List<ReferenceBatchPlacement>) {
            batches.forEachIndexed { index, batch ->
                val name = "referenceLayouts.$index"
                mark("$name.presence"); byte(if (batch.layout == null) 0 else 1)
                batch.layout?.let { layout ->
                    referenceLayoutStyle(layout.wrapper, "$name.wrapper")
                    referenceLayoutStyle(layout.list, "$name.list")
                    mark("$name.count"); u32(layout.items.size.toLong())
                    layout.items.forEachIndexed { itemIndex, item ->
                        val label = "$name.$itemIndex"
                        referenceLayoutStyle(item.box, "$label.box")
                        mark("$label.marker"); byte(0)
                        mark("$label.foreground"); byte(2); string((item.markerForeground as FigureColor.Rgb).value)
                        mark("$label.prefix"); byte(0)
                        mark("$label.target"); byte(if (item.targetBackground == null) 0 else 1)
                        item.targetBackground?.let(::referenceLayoutColor)
                    }
                }
            }
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
            value.fontFamily?.let(::fontFamily)
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
        private fun tail(heading: Boolean = false, alignment: CellTextAlign? = null, alignmentLabel: String? = null) {
            string(if (heading) "ruby-heading" else ""); string(if (heading) "old-ruby-heading" else "")
            alignmentLabel?.let { mark("$it.presence") }; byte(if (alignment == null) 0 else 1)
            alignment?.let { alignmentLabel?.let { name -> mark("$name.value") }; byte(it.ordinal) }
            repeat(3) { byte(0) } // paragraph style, Figure, anonymous flow
        }
        private fun columnLayoutTail(value: ColumnBreakInside? = null, label: String? = null) {
            if (version == 'Z' && yFlags and 4096 != 0) {
                label?.let { mark(it) }
                byte(when (value) { null -> 0; ColumnBreakInside.Auto -> 1; ColumnBreakInside.Avoid -> 2 })
            } else require(value == null)
        }
        private fun paragraph(body: Boolean = true, literal: List<Span> = emptyList()) {
            if (body && paragraphOverride != null) { checkNotNull(paragraphOverride).invoke(); return }
            if (body) prefix(0, true) else {
                byte(0); byte(0); byte(0); spans(literal, "sibling-${out.size()}"); byte(0); string(""); string("")
            }
            byte(0); tail(); columnLayoutTail()
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
                Sink.Heading -> { prefix(9, true, 2); byte(0); tail(true); columnLayoutTail() }
                Sink.Container -> {
                    repeat(containers) { index ->
                        prefix(13); byte(0); tail()
                        val style = containerStyleOverride
                        if (style == null) {
                            u32(0); if (version == 'Z' && yFlags and 256 != 0) byte(0)
                        } else style("container$index")
                        u32(1)
                    }
                    paragraph()
                    repeat(containers) { columnLayoutTail() }
                }
                Sink.FigureCaption, Sink.FigureRichCaption -> {
                    prefix(0); byte(0); string(""); string(""); byte(0); byte(0); figure(sink); byte(0); columnLayoutTail()
                }
                Sink.FlowInline, Sink.FlowFigure, Sink.ScopeInline, Sink.ScopeFigure -> {
                    prefix(0); byte(0); string(""); string(""); byte(0); byte(0); byte(0); byte(1); u32(1)
                    if (sink == Sink.ScopeInline || sink == Sink.ScopeFigure) {
                        byte(2); byte(0); byte(1); byte(0); byte(1); string("ja"); u32(1)
                    }
                    if (sink == Sink.FlowFigure || sink == Sink.ScopeFigure) { byte(1); figure(Sink.FigureRichCaption) }
                    else { byte(0); root("root") }
                    columnLayoutTail()
                }
                else -> { prefix(12); table(sink); tail(); columnLayoutTail() }
            }
        }
        private fun clearRule() {
            prefix(11); byte(0); tail(); byte(2); length(1f); byte(0); repeat(4) { length() }; byte(0); columnLayoutTail()
        }
        private fun headingStyle(extensions: Boolean) {
            u32((1 or 2 or 16 or 2048 or 4096 or 65536 or 4194304).toLong())
            repeat(8) { length() }; byte(0); byte(0); byte(0); f32(1f); byte(0)
            if (version == 'Z' && yFlags and 256 != 0) { mark("heading.extension"); byte(0) }
            byte(1); f32(1f); byte(1); byte(0); string("ja"); string(""); byte(0); byte(0)
            if (extensions) byte(0)
        }
        fun document(values: List<Span>, sink: Sink = Sink.Display, features: Int = 0,
            alignment: Boolean = false, clear: Boolean = false, containers: Int = 1,
            headingTitle: String = "漢（かん）", bodyTypography: BodyTypography? = null,
            referenceValues: List<Reference>? = null, referenceTypography: BodyTypography? = null, mediaValues: List<Media>? = null,
            referenceBatches: List<ReferenceBatchPlacement>? = null): ByteArray {
            selected = values
            out.write("DPR$version".encodeToByteArray())
            if (version == 'Z') { mark("yFeatures"); u16(yFlags) }
            else if (version == 'Y') { mark("yFeatures"); byte(yFlags) }
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
            mark("references.count")
            if (referenceValues != null) {
                require(!reference && referenceTypography == null)
                u32(referenceValues.size.toLong())
                referenceValues.forEachIndexed { index, value -> this.reference(value, index) }
            } else {
                u32(if (reference) 1 else 0)
                if (reference) {
                    byte(1); u32(1); string("ruby-ref")
                    if (sink == Sink.Reference) root("root") else spans(emptyList(), "reference")
                    byte(if (sink == Sink.ReferenceBlocks) 1 else 0)
                    if (sink == Sink.ReferenceBlocks) { u32(1); paragraph() }
                }
            }
            if (mediaValues == null) {
                u32(if (alignment) 1 else 0)
                if (alignment) { string("Probe.svg"); byte(0); string("Original media") }
            } else {
                u32(mediaValues.size.toLong())
                mediaValues.forEach { require(it.kind in listOf("image", "audio")); string(it.file); byte(if (it.kind == "audio") 1 else 0); string(it.caption) }
            }
            if (version >= 'P') {
                mark("features"); val flags = features or (if (sink == Sink.Heading) 2 else 0); byte(flags)
                if (sink == Sink.Heading) { u32(1); u32(0); headingStyle(flags and 16 != 0) }
            }
            bodyTypography?.let { this.bodyTypography(it) }
            val referenceOwners = referenceValues?.map { it.bodyTypography }
                ?: if (reference) listOf(referenceTypography) else emptyList()
            if ((version == 'Y' || version == 'Z') && yFlags and 8 != 0) referenceOwners.forEachIndexed { index, typography ->
                val label = "referenceTypography.$index"
                mark("$label.presence"); byte(if (typography == null) 0 else 1)
                typography?.let { this.bodyTypography(it, label) }
            } else require(referenceOwners.all { it == null })
            val backlinkLists = referenceValues?.map { it.backlinks } ?: if (reference) listOf(emptyList()) else emptyList()
            if ((version == 'Y' || version == 'Z') && yFlags and 64 != 0) backlinkLists.forEachIndexed { index, values ->
                val label = "backlinks.$index"
                mark("$label.count"); u32(values.size.toLong())
                values.forEachIndexed { position, value ->
                    val name = "$label.$position"
                    mark("$name.occurrence"); u32(value.occurrence); span(value.span, "$name.span")
                }
            } else require(backlinkLists.all { it.isEmpty() })
            if (version == 'Z' && yFlags and 16384 != 0) {
                mark("referenceBatches.presence"); byte(if (referenceBatches == null) 0 else 1)
                referenceBatches?.let { batches ->
                    mark("referenceBatches.count"); u32(batches.size.toLong())
                    batches.forEachIndexed { index, batch ->
                        val name = "referenceBatches.$index"
                        mark("$name.section"); u32(batch.sectionIndex.toLong())
                        mark("$name.boundary"); u32(batch.beforeBlockIndex.toLong())
                        mark("$name.count"); u32(batch.referenceIndices.size.toLong())
                        batch.referenceIndices.forEachIndexed { position, value ->
                            mark("$name.index$position"); u32(value.toLong())
                        }
                    }
                }
            } else require(referenceBatches == null)
            if (version == 'Z' && yFlags and 32768 != 0) referenceLayouts(checkNotNull(referenceBatches))
            return out.toByteArray()
        }
        /** Raw table edges do not consume content depth; a rich caption does. */
        fun tableChain(depth: Int, mixed: Boolean = false, captionAt: Int = 0,
            rowsHiddenMaxWidthPx: Long? = null) {
            require(depth > 0 && (captionAt == 0 || captionAt in 1 until depth))
            fun emit(level: Int, block: Boolean) {
                if (block) prefix(12)
                byte(if (rowsHiddenMaxWidthPx == null) 1 else 0x21); byte(0) // ordinary table, no legacy geometry
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
                rowsHiddenMaxWidthPx?.let(::u32)
                if (block) { tail(); columnLayoutTail() }
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

    @Test fun containerOwnerFontsRetainIndependentSnapshotsAliasesAndOriginalChildrenAcrossYContainers() {
        val family = ContainerFontFamily.Stack(listOf("Source Serif", "Source Sans"), GenericFontFamily.Serif)
        val font = InlineFontSnapshot(.75f, FontScaleBasis.NormalBody, small = true, superscript = true,
            subscript = true, fontNormalized = true, bold = true, italic = true, code = true,
            language = "ja", classes = "source-owner", role = "headword",
            fontFeatures = FontFeaturePolicy.SevenOn, fontFamily = family)
        val child = Span("link", "child\ud83d\ude00", "Original target", trail = "!", targetFragment = "part",
            tooltip = "Original tooltip", explanation = "Original explanation", fontScale = 2f,
            fontScaleBasis = FontScaleBasis.NormalBody)
        val source = Container(listOf(Block("paragraph", 0, listOf(child))),
            ContainerStyle(ownerFontScale = .75f, fontFamily = family.copy(names = family.names.toList()), ownerFont = font))
        assertSame(font, source.style.ownerFont); assertSame(child, source.blocks.single().spans.single())
        assertFalse(child.bold); assertFalse(child.italic); assertFalse(child.code)
        assertEquals(2f, child.fontScale); assertEquals("child\ud83d\ude00!", textOf(listOf(child)))
        val wire = Wire('Y', 1).apply { containerStyleOverride = { containerOwnerStyle(font, .75f, family, it) } }
        val entry = read(wire.document(listOf(child), Sink.Container, features = 4))
        val decoded = entry.sections.single().blocks.single().container!!
        assertEquals(source, decoded)
        assertEquals(listOf(Abbreviation("child\ud83d\ude00!", "Original explanation", "Body: child\ud83d\ude00!")), entryAbbreviations(entry))
        val raw = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = raw::add }.blocks(entry.sections.single().blocks)
        assertEquals(listOf(child), raw)
        for (basis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx)) for (size in listOf(0f, 23.5f)) {
            val exact = InlineFontSnapshot(size, basis, fontNormalized = true)
            val value = Wire('Y', 1).apply { containerStyleOverride = { containerOwnerStyle(exact, label = it) } }
            val result = read(value.document(listOf(child), Sink.Container)).sections.single().blocks.single().container!!
            assertEquals(exact, result.style.ownerFont); assertNull(result.style.ownerFontScale)
            assertNull(result.style.fontFamily); assertEquals(child, result.blocks.single().spans.single())
            val empty = Wire('Y', 1).apply { paragraphOverride = { ownedParagraph(exact, empty = true) } }
            val noLine = read(empty.document(emptyList(), Sink.Body)).sections.single().blocks.single().container!!
            assertTrue(noLine.blocks.isEmpty()); assertEquals(exact, noLine.style.ownerFont)
            assertTrue(mutableListOf<Span>().also { spans ->
                PresentationSpanVisitor { runs, _ -> spans.addAll(runs) }.block(Block("container", 0, emptyList(), container = noLine))
            }.isEmpty())
        }
        for (sink in listOf(Sink.Body, Sink.CellBlocks, Sink.TableRichCaption, Sink.ReferenceBlocks,
            Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)) {
            val nested = Wire('Y', 1).apply { paragraphOverride = { ownedParagraph(font) } }
            val restored = read(nested.document(listOf(child), sink, features = 4))
            val containers = mutableListOf<Container>(); val leaves = mutableListOf<Span>()
            val visitor = PresentationSpanVisitor { _, _ -> }.apply { onContainer = containers::add; onSpan = leaves::add }
            restored.sections.forEach { visitor.blocks(it.blocks) }
            restored.references.forEach { visitor.blocks(it.blocks.orEmpty()) }
            assertEquals("$sink declaring source", listOf(font), containers.map { it.style.ownerFont })
            assertEquals("$sink original child", listOf(child), leaves.filter { it.target == child.target })
            assertEquals("$sink fallback", "child\ud83d\ude00!", textOf(containers.single().blocks.single().spans))
        }
        val ruby = simple()
        val padding = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Px, 1f), StyleLength(StyleLengthUnit.Em, .25f), listOf(text("p"))))
        val action = Span("link", "", "Grouped target", inlineActionGroup = InlineActionGroup(listOf(text("a"))))
        val combined = Wire('Y', 1).apply { containerStyleOverride = { containerOwnerStyle(font, label = it) } }
        assertEquals(listOf(ruby, padding, action), read(combined.document(listOf(ruby, padding, action),
            Sink.Container, features = 4)).sections.single().blocks.single().container!!.blocks.single().spans)
    }

    @Test fun containerOwnerFontsRejectAliasConflictsSpecialOwnersAndMalformedYWithExactLegacyCensus() {
        val font = InlineFontSnapshot(1f, FontScaleBasis.NormalBody, fontNormalized = true)
        fun bytes(owner: InlineFontSnapshot = font, scale: Float? = null, family: ContainerFontFamily? = null,
            features: Int = 0): Pair<Wire, ByteArray> {
            val wire = Wire('Y', 1).apply { containerStyleOverride = { containerOwnerStyle(owner, scale, family, it) } }
            return wire to wire.document(listOf(text("unchanged")), Sink.Container, features = features)
        }
        for (bad in listOf(InlineFontSnapshot(), font.copy(fontNormalized = false),
            InlineFontSnapshot(1f, FontScaleBasis.Context))) {
            invalid("Noncomputed Container metric font") { ContainerStyle(ownerFont = bad) }
            reject("Literal noncomputed Container metric font", bytes(bad).second)
        }
        for (scale in listOf(Float.NaN, Float.POSITIVE_INFINITY, -1f))
            invalid("Invalid owner size") { font.copy(fontScale = scale) }
        val family = ContainerFontFamily.Stack(listOf("Source Serif", "Source Sans"), GenericFontFamily.Serif)
        val complete = font.copy(fontFamily = family)
        for ((owner, alias) in listOf(complete to 2f, complete.copy(fontScaleBasis = FontScaleBasis.CssPx) to 1f)) {
            invalid("Conflicting scalar alias") { ContainerStyle(ownerFont = owner, ownerFontScale = alias) }
            reject("Literal scalar alias", bytes(owner, scale = alias, features = 4).second)
        }
        for (alias in listOf(ContainerFontFamily.SansSerif, family.copy(names = family.names.reversed()),
            family.copy(fallback = GenericFontFamily.SansSerif))) {
            invalid("Conflicting family alias") { ContainerStyle(ownerFont = complete, fontFamily = alias) }
            reject("Literal family alias", bytes(complete, family = alias, features = 4).second)
        }
        invalid("Family alias cannot fill an absent snapshot request") { ContainerStyle(ownerFont = font, fontFamily = family) }
        reject("Literal absent snapshot family", bytes(font, family = family, features = 4).second)
        assertTrue("RelativeAuto with an owner font requires Z",
            ContainerStyle(ownerFont = font, positioning = ContainerPositioning.RelativeAuto).requiresPositionedContainers())
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val absolute = ContainerPositioning.Absolute(zero, zero, font, InlineComputedLength(0f, FontScaleBasis.CssPx), TextWrap.NoWrap)
        invalid("Absolute is a distinct owner") { ContainerStyle(ownerFont = font, positioning = absolute,
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)), height = zero) }
        invalid("Positioned scope is a distinct owner") { ContainerStyle(ownerFont = font,
            positioning = ContainerPositioning.RelativeAuto,
            positionedScope = PositionedScope(TextWrap.NoWrap, PositionedOverflowX.Hidden, PositionedOverflowY.Auto)) }
        val heading = read(Wire().document(listOf(simple()), Sink.Heading)).sections.single().headingStyle!!
        invalid("Heading already has its own metric font") { heading.copy(box = heading.box.copy(ownerFont = font.copy(fontFamily = ContainerFontFamily.SansSerif))) }
        assertFalse(validFigureViewportWrapper(ContainerStyle(ownerFont = font)))
        val before = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 10f)),
            height = zero, floatSide = TableFloatSide.Left)
        assertTrue(validFigureCaptionBefore(before)); assertFalse(validFigureCaptionBefore(before.copy(ownerFont = font)))
        val edges = StyleEdges(zero, zero, zero, zero)
        val media = FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr), InlineBoxVerticalAlign.Middle)
        val wrapper = ContainerStyle(margins = edges, width = ContainerWidth.Auto, lineHeight = ContainerLineHeight.Normal,
            textAlign = CellTextAlign.Left, ownerFontScale = 1f)
        assertNotNull(FigureBlockMediaState(639, wrapper, media))
        invalid("Figure block wrapper has independent strut") { FigureBlockMediaState(639, wrapper.copy(ownerFont = font), media) }
        val (wire, good) = bytes()
        val key = "container0.owner"
        for (bad in listOf(0, 1, 0x31, 0xff)) reject("Snapshot flags$bad", changed(good, wire.at.getValue("$key.flags"), bad))
        for (bad in listOf(0, 3, 255)) reject("Snapshot basis$bad", changed(good, wire.at.getValue("$key.scale") + 4, bad))
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, -1f))
            reject("Raw owner scale$bad", changed32(good, wire.at.getValue("$key.scale"), bad.toRawBits().toLong()))
        reject("Unknown face flag", changed(good, wire.at.getValue("$key.face"), 0x20))
        val (languageWire, languageBytes) = bytes(font.copy(language = "ja"))
        reject("Malformed owner UTF8", changed(languageBytes, languageWire.at.getValue("$key.language.bytes"), 0xff))
        for (flags in listOf(0x800000L, 0x1800000L, 0x2000000L))
            reject("Reserved or unknown Y style bit", changed32(good, wire.at.getValue("container0.style"), flags))
        reject("Y with no owner", Wire('Y', 1).document(listOf(text("legacy"))))
        for (old in listOf('M', 'P', 'Q', 'R', 'S', 'T', 'U', 'V')) {
            val legacyEnvelope = changed(replace(good, 4, 5, byteArrayOf()), 3, old.code)
            assertEquals("Owner field under$old", "Unknown container style field",
                runCatching { read(legacyEnvelope) }.exceptionOrNull()?.message)
        }
        for (size in good.indices) reject("Truncated Y$size", good.copyOf(size))
        reject("Trailing Y byte", good + byteArrayOf(0))
        for (owner in listOf(font.copy(fontFamily = ContainerFontFamily.SansSerif), complete)) {
            val (familyWire, accepted) = bytes(owner, features = 4)
            assertEquals(owner, read(accepted).sections.single().blocks.single().container!!.style.ownerFont)
            reject("Owner-only family census missing", changed(accepted, familyWire.at.getValue("features"), 0))
        }
        reject("False family census", changed(good, wire.at.getValue("features"), 4))
        val legacy = Span("link", "", "Old action", inlineActionGroup = InlineActionGroup(listOf(text("legacy"))))
        assertArrayEquals("Y has no new Span tail", Wire('V').isolatedSpan(legacy), Wire('Y', 1).isolatedSpan(legacy))
        val old = Wire('V').document(listOf(legacy), Sink.Container)
        assertNull(read(old).sections.single().blocks.single().container!!.style.ownerFont)
        reject("Changing only header cannot create Y owner", changed(old, 3, 'Y'.code))
        val unsupported = runCatching { read(changed(good, 3, 'X'.code)) }.exceptionOrNull()
        assertEquals("Unsupported presentation format", unsupported!!.message)
    }

    @Test fun containerOwnerFontsChargeOneItemWithoutAddingContentDepthOrResettingExistingBudgets() {
        val font = InlineFontSnapshot(0f, FontScaleBasis.CssPx, fontNormalized = true)
        for (depth in listOf(1, 16)) {
            val wire = Wire('Y', 1).apply { containerStyleOverride = { containerOwnerStyle(font, label = it) } }
            val value = read(wire.document(listOf(text("deep")), Sink.Container, containers = depth))
            val containers = mutableListOf<Container>()
            PresentationSpanVisitor { _, _ -> }.apply { onContainer = containers::add }.blocks(value.sections.single().blocks)
            assertEquals(depth, containers.size); assertTrue(containers.all { it.style.ownerFont == font })
            assertEquals("deep", textOf(containers.last().blocks.single().spans))
        }
        val excess = Wire('Y', 1).apply { containerStyleOverride = { containerOwnerStyle(font, label = it) } }
        reject("Owner font does not waive content17", excess.document(listOf(text("deep")), Sink.Container, containers = 17))
        val nested = Wire('Y', 1).apply {
            containerStyleOverride = { containerOwnerStyle(font, label = it) }
            paragraphOverride = { tableChain(32, mixed = true) }
        }
        val deep = read(nested.document(listOf(text("table")), Sink.Container))
        val depths = mutableListOf<Int>()
        PresentationSpanVisitor { _, _ -> }.apply { onTable = { _, depth, _ -> depths.add(depth) } }.blocks(deep.sections.single().blocks)
        assertEquals((1..32).toList(), depths)
        val tooDeep = Wire('Y', 1).apply {
            containerStyleOverride = { containerOwnerStyle(font, label = it) }
            paragraphOverride = { tableChain(33, mixed = true) }
        }
        reject("Y still rejects table33", tooDeep.document(listOf(text("table")), Sink.Container))
        val empty = Block("container", 0, emptyList(), container = Container(emptyList(), ContainerStyle(ownerFont = font)))
        val exact = java.util.Collections.nCopies(1 shl 19, empty)
        var visited = 0
        PresentationSpanVisitor { _, _ -> }.apply { onContainer = { visited++ } }.blocks(exact)
        assertEquals(1 shl 19, visited)
        invalid("Every owner consumes one additional item") { PresentationSpanVisitor { _, _ -> }.blocks(exact + empty) }
        val rawExact = Wire('Y', 1).apply { paragraphOverride = { ownerBudget((1 shl 19) - 1, font) } }
        val accepted = read(rawExact.document(emptyList(), Sink.Body))
        assertEquals((1 shl 19) - 1, accepted.sections.single().blocks.single().container!!.blocks.size)
        val rawExcess = Wire('Y', 1).apply { paragraphOverride = { ownerBudget(1 shl 19, font) } }
        reject("Raw owner item budget is shared", rawExcess.document(emptyList(), Sink.Body))
    }

    @Test fun combinedYFlagsRetainBodyBoxContainerAndOriginalActionsAcrossEverySpanSink() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val one = StyleLength(StyleLengthUnit.Px, 1f)
        val none = InlineBoxBorderEdge.None
        val borders = InlineBoxBorderEdges(InlineBoxBorderEdge.Solid(one, InlineBoxColor.CurrentColor),
            InlineBoxBorderEdge.Dotted(StyleLength(StyleLengthUnit.Em, .125f), InlineBoxColor.LightDark("#112233", "#ddeeff")),
            InlineBoxBorderEdge.Hidden, InlineBoxBorderEdge.Solid(zero, InlineBoxColor.Transparent))
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Percent, 0f), bottom = InlineBoxInset(StyleWidthUnit.Percent, 67f)),
            InlineBoxBorderEdges(none, InlineBoxBorderEdge.Solid(one, InlineBoxColor.Rgb("#102030")), none, none))
        val behind = overlay.copy(insets = InlineBoxInsets(left = InlineBoxInset(StyleWidthUnit.Em, -1.25f),
            bottom = InlineBoxInset(StyleWidthUnit.Px, -2.5f)))
        val child = Span("link", "ずれ", "Original target", trail = "!", targetFragment = "part", tooltip = "Child tip",
            explanation = "Child explanation", fontScale = 1.35f, fontScaleBasis = FontScaleBasis.Context)
        val plain = Span("text", "tail", italic = true)
        val group = InlineBoxGroup(StyleEdges(one, StyleLength(StyleLengthUnit.Em, .25f), zero, one), borders,
            listOf(overlay, behind), listOf(child, plain))
        val box = Span("text", "", fontScale = 1.35f, fontScaleBasis = FontScaleBasis.Context, inlineBoxGroup = group)
        assertSame(group, box.inlineBoxGroup); assertSame(child, group.spans.first()); assertSame(overlay, group.overlays.first())
        assertEquals(1.35f, box.fontScale); assertEquals(1.35f, child.fontScale)
        assertEquals(27f, spanFontPixels(box, 20f, 40f), 0f)
        assertEquals(27f, spanFontPixels(child, 20f, 40f), 0f)
        assertEquals("ずれ!tail", rubyFallbackText(listOf(box))); assertEquals("ずれ!tail", textOf(listOf(box)))
        val font = InlineFontSnapshot(1.25f, FontScaleBasis.NormalBody, fontNormalized = true, bold = true,
            language = "ja", fontFamily = ContainerFontFamily.SansSerif)
        val body = BodyTypography(font, ContainerLineHeight.Multiplier(1.4f))
        for (flags in 1..7) {
            val source = if (flags and 4 != 0) box else text("ordinary")
            val wire = Wire('Y', flags).apply {
                if (flags and 1 != 0) containerStyleOverride = { containerOwnerStyle(font, label = it) }
            }
            val sink = if (flags and 1 != 0) Sink.Container else Sink.Display
            val typography = body.takeIf { flags and 2 != 0 }
            val result = read(wire.document(listOf(source), sink, features = if (flags and 3 != 0) 4 else 0,
                bodyTypography = typography))
            assertEquals("Y flags$flags body", typography, result.bodyTypography)
            assertEquals("Y flags$flags source", source, selected(result, sink))
            if (flags and 1 != 0) assertEquals(font, result.sections.single().blocks.single().container!!.style.ownerFont)
        }
        for (sink in Sink.entries) {
            val restored = read(Wire('Y', 6).document(listOf(box), sink, features = 4,
                headingTitle = "ずれ!tail", bodyTypography = body))
            val actual = selected(restored, sink)
            assertEquals("$sink complete owner and ordered overlays", box, actual)
            assertEquals("$sink body", body, restored.bodyTypography)
            assertEquals("$sink terminal", "ずれ!tail", rubyFallbackText(listOf(actual)))
            assertEquals("$sink action", EntryLink("Original target", "part"), actual.inlineBoxGroup!!.spans.first().entryLink())
            assertEquals("Child tip", actual.inlineBoxGroup!!.spans.first().tooltip)
            val raw = mutableListOf<Span>()
            PresentationSpanVisitor { _, _ -> }.apply { onSpan = raw::add }.spans(listOf(actual))
            assertEquals(listOf(actual, child, plain), raw)
            if (sink == Sink.Heading) {
                assertEquals("ずれ!tail", restored.sections.single().title)
                assertEquals("ruby-heading", restored.sections.single().anchor)
            }
        }
        for (basis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx))
            for (height in listOf(null, ContainerLineHeight.Normal, ContainerLineHeight.Multiplier(0f),
                ContainerLineHeight.Length(zero), ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 1.5f)))) {
                val value = BodyTypography(InlineFontSnapshot(0f, basis, fontNormalized = true), height)
                val restored = read(Wire('Y', 2).document(emptyList(), bodyTypography = value))
                assertEquals(value, restored.bodyTypography); assertTrue(restored.displayTitle.isEmpty())
                assertTrue(restored.sections.isEmpty()); assertTrue(restored.rasterImages.isEmpty())
            }
        val innerBox = box.copy(inlineBoxGroup = group.copy(spans = listOf(text("b"))))
        val padding = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(one, zero, listOf(text("u"))))
        val nestedAction = Span("link", "", "Nested V", inlineActionGroup = InlineActionGroup(listOf(text("v"))))
        val nestedChildren = listOf(simple(), padding, nestedAction, innerBox)
        val recursive = box.copy(inlineBoxGroup = group.copy(spans = nestedChildren))
        nestedChildren.forEachIndexed { index, span -> assertSame(span, recursive.inlineBoxGroup!!.spans[index]) }
        val recursiveEntry = read(Wire('Y', 6).document(listOf(recursive), features = 4, bodyTypography = body))
        assertEquals(recursive, recursiveEntry.displayTitle.single())
        assertEquals("漢（かん）uvb", rubyFallbackText(recursiveEntry.displayTitle))
        val outerOwners = listOf(owner(listOf(base(innerBox))),
            Span("text", "", inlinePaddingGroup = InlinePaddingGroup(one, zero, listOf(innerBox))),
            Span("link", "", "Outer V", inlineActionGroup = InlineActionGroup(listOf(innerBox))))
        for (source in outerOwners) {
            val restored = read(Wire('Y', 4).document(listOf(source))).displayTitle.single()
            assertEquals(source, restored); assertEquals("b", rubyFallbackText(listOf(restored)))
        }
        val action = box.copy(kind = "external_link", target = "https://example.test/original",
            inlineBoxGroup = group.copy(spans = listOf(text("ずれ"))))
        val restoredAction = read(Wire('Y', 4).document(listOf(action))).displayTitle.single()
        assertEquals(action, restoredAction)
        assertEquals(listOf("https://example.test/original"), rubyFallbackSpans(listOf(restoredAction)).map { it.target })
    }

    @Test fun inlineBoxRejectsMalformedGeometryEmptyBodiesAndDuplicateActionsWithoutNarrowingSharedWhitespace() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdge.None
        val borders = InlineBoxBorderEdges(none, none, none, none)
        fun group(children: List<Span>) = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), borders, spans = children)
        fun boxed(vararg children: Span) = Span("text", "", inlineBoxGroup = group(children.toList()))
        val ordinary = boxed(text("x"))
        for (children in listOf(emptyList(), listOf(text("")), listOf(owner(listOf(base()), listOf(annotation())))))
            invalid("No original child text or trail") { group(children) }
        assertNotNull(boxed(Span("text", "", trail = "!")))
        for (raw in listOf(" ", "\t", "\n", "\r", "\u000c")) {
            val value = boxed(text(raw))
            assertEquals(value, read(Wire('Y', 4).document(listOf(value))).displayTitle.single())
            assertEquals(raw, rubyFallbackText(listOf(value)))
            if (raw != " ") {
                invalid("Ruby body keeps its stricter raw domain") { owner(listOf(base(value))) }
                invalid("U body keeps its stricter raw domain") { Span("text", "", inlinePaddingGroup =
                    InlinePaddingGroup(StyleLength(StyleLengthUnit.Px, 1f), zero, listOf(value))) }
            }
        }
        for (child in listOf(Span("line_break", ""), Span("text", "", image = InlineImage("Probe.svg")),
            text("media").copy(classes = "wikidict-media"), text("media").copy(classes = "wikidict-media-file-Probe")))
            invalid("Explicit non-inline child") { boxed(child) }
        for (change in listOf<() -> Span>({ ordinary.copy(text = "owner") }, { ordinary.copy(trail = "!") },
            { ordinary.copy(image = InlineImage("Probe.svg")) }, { ordinary.copy(ruby = simple().ruby) },
            { ordinary.copy(inlinePaddingGroup = InlinePaddingGroup(StyleLength(StyleLengthUnit.Px, 1f), zero, listOf(text("u")))) },
            { ordinary.copy(kind = "link", target = "A", inlineActionGroup = InlineActionGroup(listOf(text("v")))) }))
            invalid("Exclusive offset-free Box owner", change)
        val linked = ordinary.copy(kind = "link", target = "A")
        invalid("Equal descendant action is still duplicate") { linked.copy(inlineBoxGroup = group(listOf(Span("link", "x", "A")))) }
        invalid("Hidden Ruby reading action remains duplicate") { linked.copy(inlineBoxGroup = group(listOf(
            owner(listOf(base(text("x"))), listOf(annotation(Span("link", "x", "A"))))))) }
        invalid("Box cannot be a Ruby gap") { owner(listOf(base(text("a")), RubyBase(RubyOwner(InlineFontSnapshot()),
            listOf(boxed(text(" "))), listOf(text("b"))))) }
        val state = LinkState("#112233", false)
        val policy = LinkPaint(normal = state, hover = state, active = state, hoverActive = state,
            visited = state, visitedHover = state, visitedActive = state, visitedHoverActive = state, underlineOnFocus = false)
        val painted = linked.copy(foreground = "#112233", linkPaint = policy)
        invalid("Action paint cannot overwrite child source color") { painted.copy(inlineBoxGroup = group(listOf(text("x").copy(foreground = "#334455")))) }
        invalid("Action paint cannot overwrite Ruby declaring color") { painted.copy(inlineBoxGroup = group(listOf(owner(listOf(
            base(text("x"), context = RubyOwner(InlineFontSnapshot(), foreground = "#334455"))))))) }
        for (insets in listOf(InlineBoxInsets(), InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f)),
            InlineBoxInsets(left = InlineBoxInset(StyleWidthUnit.Percent, 0f))))
            invalid("Each absolute axis needs a source anchor") { InlineBoxOverlay(insets, borders) }
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY)) invalid("Finite signed inset") { InlineBoxInset(StyleWidthUnit.Px, bad) }
        for (bad in listOf("red", "#ABCDEF", "#fff", "#11223344")) {
            invalid("Canonical RGB") { InlineBoxColor.Rgb(bad) }; invalid("Canonical theme pair") { InlineBoxColor.LightDark("#112233", bad) }
        }
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, -2f),
            right = InlineBoxInset(StyleWidthUnit.Percent, 0f)), borders)
        val rich = ordinary.copy(inlineBoxGroup = group(listOf(text("x"))).copy(overlays = listOf(overlay),
            border = borders.copy(top = InlineBoxBorderEdge.Solid(StyleLength(StyleLengthUnit.Em, .5f), InlineBoxColor.Rgb("#123456")))))
        val wire = Wire('Y', 4); val bytes = wire.document(listOf(rich))
        assertEquals(rich, read(bytes).displayTitle.single())
        for (bad in listOf(2, 255)) reject("Box presence", changed(bytes, wire.at.getValue("root.0.box"), bad))
        for (bad in listOf(0, 1, 2, 4, 8, 16, 255)) reject("Overlay axis mask", changed(bytes, wire.at.getValue("root.0.box.overlay0.flags"), bad))
        reject("Inset unit", changed(bytes, wire.at.getValue("root.0.box.overlay0.inset0"), 3))
        reject("Inset NaN", changed32(bytes, wire.at.getValue("root.0.box.overlay0.inset0") + 1, Float.NaN.toRawBits().toLong()))
        reject("Negative padding", changed32(bytes, wire.at.getValue("root.0.box.padding0") + 1, (-1f).toRawBits().toLong()))
        reject("Unknown border", changed(bytes, wire.at.getValue("root.0.box.border.0"), 4))
        reject("Unknown paint", changed(bytes, wire.at.getValue("root.0.box.border.0.color"), 4))
        reject("Noncanonical RGB", changed(bytes, wire.at.getValue("root.0.box.border.0.color.rgb.bytes") + 1, 'A'.code))
        reject("Huge overlay count", changed32(bytes, wire.at.getValue("root.0.box.overlays"), 0xffff_ffffL))
        reject("Empty child array", changed32(bytes, wire.at.getValue("root.0.box.body.count"), 0))
        val childStart = wire.at.getValue("root.0.box.body.0.start"); val childEnd = wire.at.getValue("root.0.box.body.0.end")
        reject("Literal metric-only body", replace(bytes, childStart, childEnd, Wire('Y', 4).isolatedSpan(text(""))))
        reject("Literal explicit BR", replace(bytes, childStart, childEnd, Wire('Y', 4).isolatedSpan(Span("line_break", ""))))
        val actionWire = Wire('Y', 4); val actionBytes = actionWire.document(listOf(linked))
        reject("Literal equal descendant action", replace(actionBytes, actionWire.at.getValue("root.0.box.body.0.start"),
            actionWire.at.getValue("root.0.box.body.0.end"), Wire('Y', 4).isolatedSpan(Span("link", "x", "A"))))
        for (size in bytes.indices) reject("Truncated Box$size", bytes.copyOf(size))
    }

    @Test fun combinedYCensusBodyTrailerAndBoxBudgetsDoNotRelaxOlderHeadersOrDepth() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdge.None
        val borders = InlineBoxBorderEdges(none, none, none, none)
        val font = InlineFontSnapshot(0f, FontScaleBasis.CssPx, fontNormalized = true)
        val body = BodyTypography(font)
        val box = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), borders, spans = listOf(text("x"))))
        val wire = Wire('Y', 6); val good = wire.document(listOf(box), bodyTypography = body)
        for (flags in listOf(0, 1, 2, 3, 4, 5, 7, 8, 255)) reject("Exact Y flags$flags", changed(good, wire.at.getValue("yFeatures"), flags))
        reject("Flag4 debt", Wire('Y', 4).document(listOf(text("ordinary"))))
        reject("Flag2 debt", Wire('Y', 2).document(emptyList()))
        reject("Unflagged BODY tail", Wire('Y', 4).document(listOf(box), bodyTypography = body))
        for (bad in listOf('W', 'X', '[')) assertEquals("Unsupported presentation format",
            runCatching { read(changed(good, 3, bad.code)) }.exceptionOrNull()!!.message)
        val noBox = Span("link", "", "Legacy", inlineActionGroup = InlineActionGroup(listOf(text("v"))))
        assertArrayEquals(Wire('V').isolatedSpan(noBox), Wire('Y', 2).isolatedSpan(noBox))
        val old = Wire('V').document(listOf(noBox))
        assertEquals(noBox, read(old).displayTitle.single()); assertNull(read(old).bodyTypography)
        reject("No header-only Y upgrade", changed(old, 3, 'Y'.code))
        val p = Wire('Y', 2); val pBytes = p.document(emptyList(), features = 4,
            bodyTypography = body.copy(ownerFont = font.copy(fontFamily = ContainerFontFamily.SansSerif)))
        assertEquals(ContainerFontFamily.SansSerif, read(pBytes).bodyTypography!!.ownerFont.fontFamily)
        reject("BODY-only P census", changed(pBytes, p.at.getValue("features"), 0))
        reject("False P census", changed(good, wire.at.getValue("features"), 4))
        for (invalidFont in listOf(InlineFontSnapshot(), font.copy(fontNormalized = false),
            InlineFontSnapshot(1f, FontScaleBasis.Context))) invalid("Computed BODY snapshot") { BodyTypography(invalidFont) }
        for (bad in listOf(0, 1, 0x31, 255)) reject("Raw BODY snapshot flags", changed(good, wire.at.getValue("body.font.flags"), bad))
        reject("Raw BODY context basis", changed(good, wire.at.getValue("body.font.scale") + 4, 0))
        reject("Raw BODY negative size", changed32(good, wire.at.getValue("body.font.scale"), (-1f).toRawBits().toLong()))
        reject("BODY line-height presence", changed(good, wire.at.getValue("body.lineHeight"), 2))
        for (size in wire.at.getValue("body.start") until good.size) reject("Truncated BODY$size", good.copyOf(size))
        reject("Y trailing byte", good + byteArrayOf(0))
        for (depth in listOf(1, 16)) {
            val deep = Wire('Y', 6).apply { rootOverride = { boxChain(depth, it) } }
            assertEquals("leaf", rubyFallbackText(read(deep.document(emptyList(), bodyTypography = body)).displayTitle))
        }
        val tooDeep = Wire('Y', 6).apply { rootOverride = { boxChain(17, it) } }
        reject("Box shares content17 refusal", tooDeep.document(emptyList(), bodyTypography = body))
        for (depth in listOf(17, 32, 33)) {
            val tables = Wire('Y', 6).apply { paragraphOverride = { tableChain(depth, mixed = true) } }
            val bytes = tables.document(listOf(box), Sink.Body, bodyTypography = body)
            if (depth == 33) reject("Y table33", bytes) else {
                val depths = mutableListOf<Int>()
                PresentationSpanVisitor { _, _ -> }.apply { onTable = { _, level, _ -> depths.add(level) } }.blocks(read(bytes).sections.single().blocks)
                assertEquals((1..depth).toList(), depths)
            }
        }
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Px, 0f)), borders)
        val maximum = (1 shl 20) - 3
        fun budgetOwner(count: Int) = box.copy(inlineBoxGroup = box.inlineBoxGroup!!.copy(overlays = java.util.Collections.nCopies(count, overlay)))
        fun budgetEntry(value: Span) = Entry("Budget", listOf(value), "language", "Japanese", "ja", emptyList(), emptyList(), bodyTypography = body)
        assertEquals(maximum, budgetEntry(budgetOwner(maximum)).displayTitle.single().inlineBoxGroup!!.overlays.size)
        val exceedsOnlyWithBody = budgetOwner(maximum + 1)
        invalid("BODY and overlays share one model item budget") { budgetEntry(exceedsOnlyWithBody) }
        for (count in listOf(maximum, maximum + 1)) {
            val raw = Wire('Y', 6).apply { rootOverride = { boxBudget(count, it) } }
            val bytes = raw.document(emptyList(), bodyTypography = body)
            if (count == maximum) assertEquals(count, read(bytes).displayTitle.single().inlineBoxGroup!!.overlays.size)
            else reject("BODY and complete overlay records share decoder budget", bytes)
        }
    }

    @Test fun referenceTypographyAndParagraphDirectionRetainIndependentOwnersAndAllReferenceBodySlots() {
        val font = InlineFontSnapshot(.5f, FontScaleBasis.NormalBody, fontNormalized = true,
            bold = true, italic = true, code = true, language = "he", fontFeatures = FontFeaturePolicy.SevenOn,
            fontFamily = ContainerFontFamily.SansSerif)
        val referenceOwner = BodyTypography(font, ContainerLineHeight.Multiplier(1.5f), BidiResolvedDirection.Rtl)
        val entryOwner = BodyTypography(InlineFontSnapshot(1.25f, FontScaleBasis.NormalBody, fontNormalized = true),
            ContainerLineHeight.Normal, BidiResolvedDirection.Ltr)
        val child = Span("link", "source\ud83d\ude00", "Original target", trail = "!", targetFragment = "part",
            tooltip = "Original tooltip", explanation = "Original explanation", fontScale = 24f, fontScaleBasis = FontScaleBasis.CssPx)
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdge.None
        val box = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero),
            InlineBoxBorderEdges(none, none, none, none), spans = listOf(Span("external_link", "external", "https://example.test/original"))))
        val rich = Block("container", 0, emptyList(), container = Container(listOf(Block("paragraph", 0, listOf(box))), ContainerStyle()))
        val zeroOwner = BodyTypography(InlineFontSnapshot(0f, FontScaleBasis.CssPx, fontNormalized = true),
            ContainerLineHeight.Length(zero), BidiResolvedDirection.Ltr)
        val references = listOf(
            Reference(1, 2, "notes", listOf(child), bodyTypography = referenceOwner),
            Reference(2, null, "fragment", listOf(simple()), ReferenceKind.Fragment),
            Reference(3, 1, "other", emptyList(), blocks = listOf(rich), bodyTypography = zeroOwner),
            Reference(4, null, "empty", emptyList(), ReferenceKind.Fragment, emptyList(), referenceOwner.copy(direction = null)))
        assertSame(referenceOwner, references[0].bodyTypography); assertSame(child, references[0].spans.single())
        assertFalse(child.bold); assertFalse(child.italic); assertFalse(child.code)
        assertEquals(24f, child.fontScale); assertEquals(FontScaleBasis.CssPx, child.fontScaleBasis)
        val wire = Wire('Y', 30)
        val bytes = wire.document(emptyList(), features = 4, bodyTypography = entryOwner, referenceValues = references)
        val restored = read(bytes)
        assertEquals(entryOwner, restored.bodyTypography); assertEquals(references, restored.references)
        assertEquals("source\ud83d\ude00!", textOf(restored.references[0].spans))
        assertEquals(EntryLink("Original target", "part"), restored.references[0].spans.single().entryLink())
        assertEquals("漢（かん）", rubyFallbackText(restored.references[1].spans))
        assertEquals(listOf(box), restored.references[2].blocks!!.single().container!!.blocks.single().spans)
        assertTrue(restored.references[3].spans.isEmpty()); assertTrue(restored.references[3].blocks!!.isEmpty())
        assertTrue(restored.sections.isEmpty()); assertTrue(restored.displayTitle.isEmpty()); assertTrue(restored.rasterImages.isEmpty())
        val runs = mutableListOf<Span>()
        restored.references.forEach { it.visitSpanRuns { spans, _ -> runs.addAll(spans) } }
        assertEquals(listOf(child, simple(), box), runs)
        assertEquals(wire.at.getValue("body.end"), wire.at.getValue("referenceTypography.0.presence"))
        assertEquals(0, bytes[wire.at.getValue("referenceTypography.1.presence")].toInt())
        assertEquals(wire.at.getValue("referenceTypography.1.presence") + 1,
            wire.at.getValue("referenceTypography.2.presence"))
        assertEquals(1, bytes[wire.at.getValue("body.direction")].toInt())
        assertEquals(2, bytes[wire.at.getValue("referenceTypography.0.direction")].toInt())
        assertEquals(0, bytes[wire.at.getValue("referenceTypography.3.direction")].toInt())
        assertEquals(bytes.size, wire.at.getValue("referenceTypography.3.end"))
        for (kind in ReferenceKind.entries) for (blocks in listOf(false, true)) {
            val source = Reference(1, if (kind == ReferenceKind.Note) 1 else null, "slot",
                if (blocks) emptyList() else listOf(child), kind,
                if (blocks) listOf(Block("paragraph", 0, listOf(child))) else null, referenceOwner)
            val decoded = read(Wire('Y', 24).document(emptyList(), features = 4, referenceValues = listOf(source)))
            assertNull(decoded.bodyTypography); assertEquals(listOf(source), decoded.references)
            assertEquals("source\ud83d\ude00!", mutableListOf<Span>().also { leaves ->
                decoded.references.single().visitSpanRuns { spans, _ -> leaves.addAll(spans) }
            }.let(::textOf))
        }
        for (height in listOf(null, ContainerLineHeight.Normal, ContainerLineHeight.Multiplier(0f),
            ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 1.75f)))) {
            val source = Reference(1, null, "height", emptyList(), ReferenceKind.Fragment,
                bodyTypography = zeroOwner.copy(lineHeight = height, direction = null))
            val decoded = read(Wire('Y', 8).document(emptyList(), referenceValues = listOf(source)))
            assertEquals(source, decoded.references.single()); assertNull(decoded.bodyTypography)
        }
    }

    @Test fun referenceTypographyDirectionTrailerIsStrictAndNullLegacyBytesRemainExact() {
        val font = InlineFontSnapshot(1f, FontScaleBasis.NormalBody, fontNormalized = true)
        val owner = BodyTypography(font)
        val directional = owner.copy(direction = BidiResolvedDirection.Rtl)
        val child = Span("link", "", "V target", inlineActionGroup = InlineActionGroup(listOf(text("v"))))
        val legacyReference = Reference(1, null, "ruby-ref", listOf(child), ReferenceKind.Fragment)
        for (version in listOf('V', 'Y')) {
            val flags = if (version == 'Y') 2 else 0
            val body = owner.takeIf { version == 'Y' }
            val old = Wire(version, flags).document(listOf(child), Sink.Reference, bodyTypography = body)
            val explicitNull = Wire(version, flags).document(emptyList(), bodyTypography = body,
                referenceValues = listOf(legacyReference.copy(bodyTypography = null)))
            assertArrayEquals("$version null reference field changes no bytes", old, explicitNull)
            assertEquals(listOf(legacyReference), read(old).references)
            assertEquals(body, read(old).bodyTypography)
        }
        val source = legacyReference.copy(bodyTypography = directional)
        val wire = Wire('Y', 26)
        val good = wire.document(emptyList(), bodyTypography = owner, referenceValues = listOf(source))
        assertEquals(owner, read(good).bodyTypography); assertEquals(source, read(good).references.single())
        assertEquals(wire.at.getValue("body.lineHeight") + 1, wire.at.getValue("body.direction"))
        assertEquals(0, good[wire.at.getValue("body.direction")].toInt())
        for (bad in listOf(2, 255)) reject("Reference owner presence$bad", changed(good, wire.at.getValue("referenceTypography.0.presence"), bad))
        for (label in listOf("body.direction", "referenceTypography.0.direction")) for (bad in listOf(3, 255)) {
            assertEquals("Unknown body paragraph direction", runCatching { read(changed(good, wire.at.getValue(label), bad)) }.exceptionOrNull()?.message)
        }
        reject("Reference-only font must remain normalized", changed(good, wire.at.getValue("referenceTypography.0.font.flags"), 1))
        reject("Reference-only font cannot become Context", changed(good, wire.at.getValue("referenceTypography.0.font.scale") + 4, 0))
        reject("Reference line-height presence", changed(good, wire.at.getValue("referenceTypography.0.lineHeight"), 2))
        for (flags in listOf(0, 2, 8, 10, 16, 18, 24, 64, 128, 255))
            reject("Reference/direction census$flags", changed(good, wire.at.getValue("yFeatures"), flags))
        reject("No actual reference owner", Wire('Y', 8).document(emptyList(), referenceValues = listOf(legacyReference)))
        reject("Empty reference array cannot earn bit8", Wire('Y', 8).document(emptyList()))
        reject("Direction cannot stand alone", Wire('Y', 16).document(emptyList()))
        reject("All-null direction debt", Wire('Y', 26).document(emptyList(), bodyTypography = owner,
            referenceValues = listOf(source.copy(bodyTypography = owner))))
        val entryOnlyDirection = Wire('Y', 26)
        val withTail = entryOnlyDirection.document(emptyList(), bodyTypography = directional,
            referenceValues = listOf(source.copy(bodyTypography = owner)))
        assertEquals("Trailing presentation data", runCatching {
            read(changed(withTail, entryOnlyDirection.at.getValue("yFeatures"), 18))
        }.exceptionOrNull()?.message)
        val familyWire = Wire('Y', 8)
        val familyReference = source.copy(bodyTypography = owner.copy(ownerFont = font.copy(fontFamily = ContainerFontFamily.SansSerif)))
        val familyBytes = familyWire.document(emptyList(), features = 4, referenceValues = listOf(familyReference))
        assertEquals(familyReference, read(familyBytes).references.single())
        reject("Reference-only family participates in pending P census", changed(familyBytes, familyWire.at.getValue("features"), 0))
        reject("False pending P census", changed(good, wire.at.getValue("features"), 4))
        reject("Reference count cannot omit a typography slot", changed32(good, wire.at.getValue("references.count"), 0))
        for (size in good.indices) reject("Truncated reference typography$size", good.copyOf(size))
        reject("Extra reference trailer count", replace(good, wire.at.getValue("referenceTypography.0.presence"),
            wire.at.getValue("referenceTypography.0.presence"), byteArrayOf(1, 0, 0, 0)))
        reject("Trailing reference byte", good + byteArrayOf(0))
    }

    @Test fun referenceTypographyAddsOneSharedItemAndNoContentOrTableDepth() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdge.None
        val borders = InlineBoxBorderEdges(none, none, none, none)
        val owner = BodyTypography(InlineFontSnapshot(0f, FontScaleBasis.CssPx, fontNormalized = true),
            direction = BidiResolvedDirection.Rtl)
        for (sink in listOf(Sink.Reference, Sink.ReferenceBlocks)) {
            val literal = Wire('Y', 24).document(listOf(text("original")), sink, referenceTypography = owner)
            val reference = read(literal).references.single()
            assertEquals(owner, reference.bodyTypography)
            val runs = mutableListOf<Span>(); reference.visitSpanRuns { spans, _ -> runs.addAll(spans) }
            assertEquals(listOf(text("original")), runs)
        }
        for (depth in listOf(16, 17)) {
            val wire = Wire('Y', 28).apply { rootOverride = { boxChain(depth, it) } }
            val bytes = wire.document(emptyList(), Sink.Reference, referenceTypography = owner)
            if (depth == 16) assertEquals("leaf", rubyFallbackText(read(bytes).references.single().spans))
            else reject("Reference typography does not waive content17", bytes)
        }
        for (depth in listOf(16, 32, 33)) {
            val wire = Wire('Y', 24).apply { paragraphOverride = { tableChain(depth, mixed = true) } }
            val bytes = wire.document(listOf(text("table")), Sink.ReferenceBlocks, referenceTypography = owner)
            if (depth == 33) reject("Reference typography does not waive table33", bytes) else {
                val decoded = read(bytes).references.single(); assertEquals(owner, decoded.bodyTypography)
                val levels = mutableListOf<Int>()
                PresentationSpanVisitor { _, _ -> }.apply { onTable = { _, level, _ -> levels.add(level) } }.blocks(decoded.blocks!!)
                assertEquals((1..depth).toList(), levels)
            }
        }
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Px, 0f)), borders)
        val emptyReference = Reference(1, null, "empty", emptyList(), ReferenceKind.Fragment, bodyTypography = owner)
        fun box(count: Int) = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), borders,
            java.util.Collections.nCopies(count, overlay), listOf(text("x"))))
        fun entry(value: Span) = Entry("Budget", listOf(value), "language", "Japanese", "ja", emptyList(), listOf(emptyReference))
        // Preserve the existing model's wrapper accounting: only the new owner adds an item.
        val modelMaximum = (1 shl 20) - 3
        assertEquals(modelMaximum, entry(box(modelMaximum)).displayTitle.single().inlineBoxGroup!!.overlays.size)
        val withOneMore = box(modelMaximum + 1)
        invalid("Reference owner adds exactly one model item") { entry(withOneMore) }
        // The wire already counts its reference slot, in addition to Box + child + typography.
        val wireMaximum = (1 shl 20) - 4
        for (count in listOf(wireMaximum, wireMaximum + 1)) {
            val wire = Wire('Y', 28).apply { rootOverride = { boxBudget(count, it) } }
            val bytes = wire.document(emptyList(), referenceValues = listOf(emptyReference))
            if (count == wireMaximum) {
                val decoded = read(bytes); assertEquals(owner, decoded.references.single().bodyTypography)
                assertEquals(count, decoded.displayTitle.single().inlineBoxGroup!!.overlays.size)
            } else reject("Reference slot and owner share decoder item budget", bytes)
        }
    }

    @Test fun imageOccurrenceLayoutsRetainExactImagesActionsAndAllExistingSpanSinks() {
        val px = StyleLengthUnit.Px
        val em = StyleLengthUnit.Em
        val layout = InlineImageOccurrenceLayout(SignedContainerMargin(px, -10f), SignedContainerMargin(em, -0.25f),
            StyleLength(em, 0.4f), StyleLength(px, 3f))
        val image = InlineImage("Probe.svg", 120, 61, "Complete image alt", "Image tooltip", border = true,
            verticalAlign = InlineImageVerticalAlign.Baseline, occurrenceLayout = layout)
        val source = Span("link", "", "Image target", image = image, targetFragment = "image-anchor",
            tooltip = "Action tooltip", explanation = "Image explanation", language = "ja", fontScale = 1.35f)
        for (sink in Sink.entries.filter { it != Sink.Heading }) {
            val wire = Wire('Y', 32)
            val entry = read(wire.document(listOf(source), sink, headingTitle = "",
                mediaValues = listOf(Media("Probe.svg", "image", "Original media"))))
            assertEquals(sink.name, source, selected(entry, sink))
            assertEquals(listOf(image), entry.inlineImages)
            assertEquals(listOf(RasterImageOccurrence(image)), entry.rasterImages)
            assertEquals(listOf(Media("Probe.svg", "image", "Original media")), entry.media)
            assertEquals(EntryLink("Image target", "image-anchor"), selected(entry, sink).entryLink())
            assertEquals(layout, selected(entry, sink).image!!.occurrenceLayout)
        }
        reject("Existing authored heading domain still excludes an image-only companion", Wire('Y', 32).document(
            listOf(source), Sink.Heading, headingTitle = "", mediaValues = listOf(Media("Probe.svg", "image", "Original media"))))
        val zero = InlineImageOccurrenceLayout(StyleLength(px, 0f), StyleLength(em, 0f),
            StyleLength(px, 0f), StyleLength(em, 0f))
        val second = Span("external_link", "", "https://example.test/image", image = image.copy(occurrenceLayout = zero))
        val owner = BodyTypography(InlineFontSnapshot(fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true), direction = BidiResolvedDirection.Rtl)
        val reference = Reference(1, 1, "image-reference", listOf(second), bodyTypography = owner)
        val union = Wire('Y', 58)
        val entry = read(union.document(listOf(source, text(" ordinary "), simple()), bodyTypography = owner,
            referenceValues = listOf(reference), mediaValues = listOf(Media("Probe.svg", "image", "Original media"))))
        assertEquals(listOf(source, text(" ordinary "), simple()), entry.displayTitle)
        assertEquals(listOf(reference), entry.references)
        assertEquals(owner, entry.bodyTypography)
        assertEquals(listOf(image, second.image), entry.inlineImages)
        assertNotNull(entry.references.single().spans.single().image!!.occurrenceLayout)
        assertEquals(zero, entry.references.single().spans.single().image!!.occurrenceLayout)
        assertSame(layout, image.occurrenceLayout)
        assertEquals(1.35f, source.fontScale)
        val edge = StyleLength(px, 0f)
        val borders = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val box = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(edge, edge, edge, edge),
            borders, emptyList(), listOf(text("box sibling"))))
        val containerFont = owner.ownerFont.copy(fontFamily = ContainerFontFamily.SansSerif)
        val complete = Wire('Y', 63).apply {
            containerStyleOverride = { containerOwnerStyle(containerFont, label = it) }
        }
        val completeBytes = complete.document(listOf(box, source), Sink.Container, features = 4,
            bodyTypography = owner, referenceValues = listOf(reference),
            mediaValues = listOf(Media("Probe.svg", "image", "Original media")))
        val completeEntry = read(completeBytes)
        val container = completeEntry.sections.single().blocks.single().container!!
        assertEquals(containerFont, container.style.ownerFont)
        assertEquals(listOf(box, source), container.blocks.single().spans)
        assertEquals(owner, completeEntry.bodyTypography)
        assertEquals(listOf(reference), completeEntry.references)
        assertEquals(listOf(image, second.image), completeEntry.inlineImages)
        reject("Image union retains the exact pending font census", changed(completeBytes, complete.at.getValue("features"), 0))

        val figureEntry = read(Wire('S').document(listOf(simple()), Sink.FigureCaption))
        val originalBlock = figureEntry.sections.single().blocks.single()
        val figureImage = image.copy(verticalAlign = null)
        val figureSource = source.copy(image = figureImage)
        val content = FigureContent.Image(figureSource, FigureSizingPolicy.RequestedFit)
        val figure = originalBlock.figure!!.copy(content = content)
        val raw = mutableListOf<Span>()
        val specialized = mutableListOf<FigureContent>()
        PresentationSpanVisitor { _, _ -> }.apply {
            onSpan = { raw.add(it) }
            visitFigureContent = { specialized.add(it) }
        }.figure(figure, 0, 0)
        assertEquals(1, specialized.size)
        assertSame(content, specialized.single())
        assertFalse(raw.any { it === figureSource })
        val withFigure = figureEntry.copy(sections = listOf(figureEntry.sections.single().copy(
            blocks = listOf(originalBlock.copy(figure = figure)))), media = listOf(Media("Probe.svg", "image", "Original media")))
        assertEquals(listOf(RasterImageOccurrence(figureImage, FigureSizingPolicy.RequestedFit)), withFigure.rasterImages)
        assertSame(figureImage, withFigure.inlineImages.single())
    }

    @Test fun imageOccurrenceTailRejectsMalformedGeometryAndCensusWithoutChangingNullBytes() {
        val px = StyleLengthUnit.Px
        val zero = StyleLength(px, 0f)
        val layout = InlineImageOccurrenceLayout(zero, zero, zero, zero)
        val image = InlineImage("Probe.svg", 120, 61, "Full alt", occurrenceLayout = layout)
        val source = Span("text", "", image = image)
        val media = listOf(Media("Probe.svg", "image", "Original media"))
        val wire = Wire('Y', 32)
        val bytes = wire.document(listOf(source), mediaValues = media)
        assertEquals(source, read(bytes).displayTitle.single())
        val presence = wire.at.getValue("root.0.image.occurrence")
        val end = wire.at.getValue("root.0.image.occurrence.end")
        assertEquals(21, end - presence)
        assertArrayEquals(byteArrayOf(1) + ByteArray(20), bytes.copyOfRange(presence, end))
        reject("Occurrence presence is strict", changed(bytes, presence, 2))
        reject("Empty Y census", changed(bytes, wire.at.getValue("yFeatures"), 0))
        reject("Clipped feature cannot replace image occurrence payload", changed(bytes, wire.at.getValue("yFeatures"), 128))
        for (name in listOf("x", "y", "left", "right")) {
            val start = wire.at.getValue("root.0.image.occurrence.$name")
            reject("Unknown $name unit", changed(bytes, start, 2))
            for (value in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
                reject("Nonfinite $name", changed32(bytes, start + 1, value.toRawBits().toLong() and 0xffff_ffffL))
            }
        }
        for (name in listOf("left", "right")) reject("Negative $name padding", changed32(bytes,
            wire.at.getValue("root.0.image.occurrence.$name") + 1, (-1f).toRawBits().toLong() and 0xffff_ffffL))
        for (size in presence until bytes.size) reject("Truncated occurrence/tail $size", bytes.copyOf(size))
        reject("Trailing occurrence data", bytes + byteArrayOf(0))
        val absent = source.copy(image = image.copy(occurrenceLayout = null))
        reject("Bit32 needs an actual layout", Wire('Y', 32).document(listOf(absent), mediaValues = media))
        val body = BodyTypography(InlineFontSnapshot(fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody, fontNormalized = true))
        val mixed = Wire('Y', 34)
        val mixedBytes = mixed.document(listOf(source), bodyTypography = body, mediaValues = media)
        reject("A layout cannot appear without its capability", changed(mixedBytes, mixed.at.getValue("yFeatures"), 2))
        val plainY = Wire('Y', 2).document(listOf(absent), bodyTypography = body, mediaValues = media)
        val withBit = Wire('Y', 34)
        val absentBytes = withBit.document(listOf(absent), bodyTypography = body, mediaValues = media)
        val removedPresence = replace(absentBytes, withBit.at.getValue("root.0.image.occurrence"),
            withBit.at.getValue("root.0.image.occurrence.end"), byteArrayOf())
        assertArrayEquals(plainY, changed(removedPresence, withBit.at.getValue("yFeatures"), 2))
        val aligned = absent.copy(image = absent.image!!.copy(verticalAlign = InlineImageVerticalAlign.Middle))
        val old = Wire('V').isolatedSpan(aligned)
        val nullable = Wire('Y', 32)
        val nullableBytes = nullable.isolatedSpan(aligned)
        assertArrayEquals(old, replace(nullableBytes, nullable.at.getValue("isolated.image.occurrence"),
            nullable.at.getValue("isolated.image.occurrence.end"), byteArrayOf()))
        assertArrayEquals(Wire('V').isolatedSpan(text("ordinary")), Wire('Y', 32).isolatedSpan(text("ordinary")))
        assertEquals(absent, read(Wire('O').document(listOf(absent), mediaValues = media)).displayTitle.single())
        invalid("Signed x remains finite") { InlineImageOccurrenceLayout(SignedContainerMargin(px, Float.NaN), zero, zero, zero) }
        invalid("Signed y remains finite") { InlineImageOccurrenceLayout(zero, SignedContainerMargin(px, Float.POSITIVE_INFINITY), zero, zero) }
        invalid("Padding remains nonnegative") { InlineImageOccurrenceLayout(zero, zero, StyleLength(px, -1f), zero) }
        val map = ImageMap(ImageMapDescription.None, emptyList())
        assertEquals(map, image.copy(occurrenceLayout = null, map = map).map)
        invalid("Map cannot share occurrence geometry") { image.copy(map = map) }
        val poster = StaticPoster(StaticPosterPolicy.ThreeDStlV1, "render", "a".repeat(40), "2026-01-01T00:00:00Z")
        val posterImage = InlineImage("Shape.stl", 120, 90, staticPoster = poster)
        assertSame(poster, posterImage.staticPoster)
        invalid("Static poster cannot share occurrence geometry") { posterImage.copy(occurrenceLayout = layout) }
    }

    @Test fun imageOccurrenceAddsOneSharedItemIncludingCustomFiguresWithoutAddingDepth() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val image = InlineImage("Probe.svg", 120, occurrenceLayout = InlineImageOccurrenceLayout(zero, zero, zero, zero))
        val source = Span("text", "", image = image)
        val plain = source.copy(image = image.copy(occurrenceLayout = null))
        val media = listOf(Media("Probe.svg", "image", "Original media"))
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Px, 0f)), none)
        fun box(count: Int) = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero),
            none, java.util.Collections.nCopies(count, overlay), listOf(text("x"))))
        fun entry(count: Int, subject: Span) = Entry("Budget", listOf(box(count), subject), "language", "Japanese", "ja",
            emptyList(), emptyList(), media = media)
        val modelMaximum = (1 shl 20) - 4 // box + its leaf + image Span + occurrence layout
        assertEquals(listOf(image), entry(modelMaximum, source).inlineImages)
        invalid("Layout consumes the last shared model item") { entry(modelMaximum + 1, source) }
        assertEquals(listOf(plain.image), entry(modelMaximum + 1, plain).inlineImages)
        val decoderMaximum = modelMaximum - 1 // existing media collection charges one slot in the Reader
        for ((count, subject, accepted) in listOf(Triple(decoderMaximum, source, true),
            Triple(decoderMaximum + 1, source, false), Triple(decoderMaximum + 1, plain, true))) {
            val flags = if (subject.image!!.occurrenceLayout == null) 4 else 36
            val wire = Wire('Y', flags).apply { rootOverride = { boxBudget(count, it, subject) } }
            val bytes = wire.document(emptyList(), mediaValues = media)
            if (accepted) assertEquals(subject, read(bytes).displayTitle.last()) else reject("Shared decoder image item", bytes)
        }
        val figureEntry = read(Wire('S').document(listOf(simple()), Sink.FigureCaption))
        val figure = figureEntry.sections.single().blocks.single().figure!!.copy(caption = emptyList(),
            content = FigureContent.Image(source, FigureSizingPolicy.RequestedFit))
        fun figureBudget(subject: Span): Int {
            var callbacks = 0
            val visitor = PresentationSpanVisitor { _, _ -> }.apply { visitFigureContent = { callbacks++ } }
            visitor.spans(java.util.Collections.nCopies((1 shl 20) - 1, text("")))
            visitor.figure(figure.copy(content = FigureContent.Image(subject, FigureSizingPolicy.RequestedFit)), 0, 0)
            return callbacks
        }
        assertEquals(1, figureBudget(plain))
        invalid("Custom Figure root shares occurrence item budget") { figureBudget(source) }
        for (depth in listOf(16, 17)) {
            val bytes = Wire('Y', 32).document(listOf(source), Sink.Container, containers = depth, mediaValues = media)
            if (depth == 17) reject("Image does not relax content depth", bytes)
            else assertEquals(listOf(image), read(bytes).inlineImages)
        }
        for (depth in listOf(32, 33)) {
            val wire = Wire('Y', 32).apply { paragraphOverride = { tableChain(depth, mixed = true) } }
            val bytes = wire.document(listOf(source), Sink.Body, mediaValues = media)
            if (depth == 33) reject("Image does not relax table depth", bytes)
            else assertEquals(listOf(image), read(bytes).inlineImages)
        }
    }

    @Test fun positionedZRetainsDefiniteLabelsOriginalChildrenAndIndependentDeclaringContextsAcrossSinks() {
        // Synthetic data-boundary fixture; no FR producer or rendered-layout claim.
        val px = StyleLengthUnit.Px
        val em = StyleLengthUnit.Em
        val font = InlineFontSnapshot(18f, FontScaleBasis.CssPx, fontNormalized = true,
            language = "fr", classes = "label-owner")
        val labels = listOf("thumb", "index", "middle", "ring", "little").mapIndexed { index, label ->
            val span = if (index == 3) Span("text", label, bold = true, fontScale = 18f,
                fontScaleBasis = FontScaleBasis.CssPx, inlineStyle = InlineTextStyle(fontNormalized = true))
            else Span("link", label, "Target$index", targetFragment = "French", tooltip = "Tip$index",
                explanation = "Meaning$index", fontScale = 18f, fontScaleBasis = FontScaleBasis.CssPx, inlineStyle = InlineTextStyle(fontNormalized = true))
            val style = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, if (index == 4) 160f else 120f)),
                height = StyleLength(px, 20f), textAlign = if (index % 2 == 0) CellTextAlign.Center else CellTextAlign.Right,
                lineHeight = ContainerLineHeight.Length(StyleLength(px, 20f)), ownerFont = font,
                absolutePosition = ContainerAbsolutePosition(if (index == 0) SignedContainerMargin(px, -2f) else StyleLength(px, index * 12f),
                    if (index == 4) StyleLength(em, .25f) else StyleLength(px, index * 20f)), textWrap = TextWrap.NoWrap)
            Block("container", 0, emptyList(), container = Container(listOf(Block("paragraph", 0, listOf(span))), style))
        }
        val image = Span("text", "", image = InlineImage("Hand.png", 240, alt = "Hand"))
        val middle = Block("container", 0, emptyList(), container = Container(labels, ContainerStyle(textWrap = TextWrap.Normal)))
        val relative = Container(listOf(Block("paragraph", 0, listOf(image)), middle), ContainerStyle(
            positioning = ContainerPositioning.RelativeAuto, overflow = ContainerOverflow.Visible,
            ownerFont = font.copy(fontScale = 20f, bold = false), textWrap = TextWrap.NoWrap))
        val root = Block("container", 0, emptyList(), container = relative)
        val media = listOf(Media("Hand.png", "image", "Source image"))
        assertSame(labels, middle.container!!.blocks)
        assertSame(font, labels.first().container!!.style.ownerFont)
        assertSame(image, relative.blocks.first().spans.single())
        val expectedSpans = listOf(image) + labels.flatMap { it.container!!.blocks.single().spans }
        for (sink in listOf(Sink.Body, Sink.CellBlocks, Sink.TableRichCaption, Sink.ReferenceBlocks,
                Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)) {
            val wire = Wire('Z', 257).apply { paragraphOverride = { positionedBlock(root, "labels") } }
            val bytes = wire.document(emptyList(), sink, mediaValues = media)
            assertArrayEquals(byteArrayOf(68, 80, 82, 90, 1, 1), bytes.copyOf(6))
            val decoded = read(bytes)
            val containers = mutableListOf<Container>()
            val visitor = PresentationSpanVisitor { _, _ -> }.apply { onContainer = containers::add }
            decoded.sections.forEach { visitor.blocks(it.blocks) }
            decoded.references.forEach { reference -> reference.blocks?.let { visitor.blocks(it) } }
            assertEquals("Complete original subtree at $sink", relative, containers.first())
            assertEquals(labels.map { it.container!!.style }, containers.drop(2).map { it.style })
            val retained = mutableListOf<Span>()
            PresentationSpanVisitor { spans, _ -> retained.addAll(spans) }.blocks(containers.first().blocks)
            assertEquals(expectedSpans, retained)
            assertEquals(listOf("Target0", "Target1", "Target2", "Target4"), retained.filter { it.kind == "link" }.map { it.target })
            assertTrue(retained.single { it.text == "ring" }.bold)
            assertEquals(media, decoded.media)
            assertNull(decoded.bodyTypography)
        }
        val comboOnly = ContainerStyle(positioning = ContainerPositioning.RelativeAuto, ownerFont = font)
        val combo = Block("container", 0, emptyList(), container = Container(emptyList(), comboOnly))
        val comboWire = Wire('Z', 257).apply { paragraphOverride = { positionedBlock(combo) } }
        val comboBytes = comboWire.document(emptyList(), Sink.Body)
        assertEquals(0, comboBytes[comboWire.at.getValue("positioned.style.extension")].toInt())
        assertEquals(comboOnly, read(comboBytes).sections.single().blocks.single().container!!.style)
        val noFont = labels.first().copy(container = labels.first().container!!.copy(
            style = labels.first().container!!.style.copy(ownerFont = null)))
        val noFontRoot = root.copy(container = Container(listOf(noFont), ContainerStyle(positioning = ContainerPositioning.RelativeAuto)))
        val noFontWire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(noFontRoot) } }
        assertEquals(noFontRoot, read(noFontWire.document(emptyList(), Sink.Body)).sections.single().blocks.single())
        val zero = StyleLength(px, 0f)
        val nested = Span("link", "", "RubyAction", inlineActionGroup = InlineActionGroup(listOf(
            Span("text", "", inlinePaddingGroup = InlinePaddingGroup(StyleLength(px, 1f), zero, listOf(simple()))))))
        val none = InlineBoxBorderEdge.None
        val boxSpan = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero),
            InlineBoxBorderEdges(none, none, none, none), spans = listOf(nested)))
        val moved = Span("text", "", image = InlineImage("Occurrence.png", 12, alt = "second",
            occurrenceLayout = InlineImageOccurrenceLayout(zero, zero, zero, zero)))
        val fullRoot = root.copy(container = relative.copy(blocks = relative.blocks + Block("paragraph", 0, listOf(boxSpan, moved))))
        val body = BodyTypography(font, direction = BidiResolvedDirection.Ltr)
        val reference = Reference(1, null, "reference", listOf(text("reference")), ReferenceKind.Fragment,
            bodyTypography = body.copy(direction = BidiResolvedDirection.Rtl))
        val allFlags = Wire('Z', 319).apply { paragraphOverride = { positionedBlock(fullRoot) } }
        val allBytes = allFlags.document(emptyList(), Sink.Body, bodyTypography = body, referenceValues = listOf(reference),
            mediaValues = media + Media("Occurrence.png", "image", ""))
        val all = read(allBytes)
        assertEquals(fullRoot, all.sections.single().blocks.single())
        assertEquals(body, all.bodyTypography); assertEquals(listOf(reference), all.references)
        assertEquals(listOf(image.image, moved.image), all.inlineImages)
        for (bit in listOf(1, 2, 4, 8, 16, 32, 256)) {
            val flags = 319 xor bit
            reject("Exact combined Z bit $bit", allBytes.copyOf().also { it[4] = flags.toByte(); it[5] = (flags ushr 8).toByte() })
        }
    }

    @Test fun positionedZValidatesNearestRelativeBoundariesLocalFieldsAndExactWireCensus() {
        val px = StyleLengthUnit.Px
        val zero = StyleLength(px, 0f)
        val font = InlineFontSnapshot(18f, FontScaleBasis.CssPx, fontNormalized = true)
        val style = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 120f)), height = StyleLength(px, 20f),
            ownerFont = font, absolutePosition = ContainerAbsolutePosition(SignedContainerMargin(px, -3f), StyleLength(StyleLengthUnit.Em, .5f)),
            textWrap = TextWrap.NoWrap, lineHeight = ContainerLineHeight.Length(StyleLength(px, 20f)))
        fun box(children: List<Block>, value: ContainerStyle = ContainerStyle()) =
            Block("container", 0, emptyList(), container = Container(children, value))
        val leaf = Block("paragraph", 0, listOf(Span("link", "kept", "Destination", targetFragment = "Part")))
        val absolute = box(listOf(leaf), style)
        fun relative(vararg children: Block) = box(children.toList(), ContainerStyle(positioning = ContainerPositioning.RelativeAuto))
        fun entry(vararg blocks: Block) = Entry("Z", emptyList(), "language", "French", "fr",
            listOf(Section(2, "Body", blocks.toList())), emptyList())
        fun table(child: Block) = Block("table", 0, emptyList(), table = Table(emptyList(),
            listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(child))))))
        fun literal(root: Block): Pair<Wire, ByteArray> {
            val wire = Wire('Z', 257).apply { paragraphOverride = { positionedBlock(root) } }
            return wire to wire.document(emptyList(), Sink.Body)
        }
        val valid = relative(box(listOf(absolute)))
        assertSame(valid, entry(valid).sections.single().blocks.single())
        assertEquals(valid, read(literal(valid).second).sections.single().blocks.single())
        val nearer = relative(box(listOf(relative(absolute))))
        assertEquals(nearer, read(literal(nearer).second).sections.single().blocks.single())
        val renewed = relative(box(listOf(relative(absolute)), style))
        assertEquals(renewed, read(literal(renewed).second).sections.single().blocks.single())
        val cellRoot = table(relative(absolute))
        assertEquals(cellRoot, read(literal(cellRoot).second).sections.single().blocks.single())
        for ((label, invalidRoot) in listOf("orphan" to absolute, "ordinary is not anchor" to box(listOf(absolute)),
                "absolute consumes anchor" to relative(box(listOf(box(listOf(absolute))), style)),
                "table resets external anchor" to relative(table(absolute)),
                "sibling relative cannot lend anchor" to box(listOf(relative(leaf), absolute)))) {
            invalid(label) { entry(invalidRoot) }; reject(label, literal(invalidRoot).second)
        }
        val validEntry = entry(valid)
        invalid("Independent section resets anchor") { validEntry.copy(sections = validEntry.sections + Section(2, "Other", listOf(absolute))) }
        val orphanReference = Reference(1, null, "ref", emptyList(), ReferenceKind.Fragment, listOf(absolute))
        invalid("Reference cannot borrow body anchor") { validEntry.copy(references = listOf(orphanReference)) }
        val referenceWire = Wire('Z', 257).apply { paragraphOverride = { positionedBlock(valid) } }
        reject("Literal reference cannot borrow body anchor", referenceWire.document(emptyList(), Sink.Body,
            referenceValues = listOf(orphanReference)))
        for (sink in listOf(Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure, Sink.TableRichCaption)) {
            val wire = Wire('Z', 257).apply { paragraphOverride = { positionedBlock(absolute) } }
            reject("Independent replaced owner at $sink", wire.document(emptyList(), sink))
        }
        val figureWire = Wire('Z', 257).apply { paragraphOverride = { positionedBlock(valid) } }
        val originalFigure = read(figureWire.document(emptyList(), Sink.FigureRichCaption))
            .sections.single().blocks.single().figure!!
        val originalFigureBlock = Block("paragraph", 0, emptyList(), figure = originalFigure)
        val recoveredFigure = relative(originalFigureBlock)
        assertSame(recoveredFigure, entry(recoveredFigure).sections.single().blocks.single())
        val unanchoredFigure = originalFigureBlock.copy(figure = originalFigure.copy(captionBlocks = listOf(absolute)))
        invalid("Figure cannot borrow actual external relative anchor") { entry(relative(unanchoredFigure)) }
        assertSame(originalFigure.content, unanchoredFigure.figure!!.content)
        val zeroMargins = ContainerMargins(ContainerMargin.Length(zero), ContainerMargin.Length(zero),
            ContainerMargin.Length(zero), ContainerMargin.Length(zero))
        assertEquals(style.absolutePosition, style.copy(padding = StyleEdges(zero, zero, zero, zero), marginValues = zeroMargins,
            border = ContainerBorder.None, background = ContainerColor.Transparent, boxSizing = ContainerBoxSizing.ContentBox).absolutePosition)
        val invalidStyles = listOf<Pair<String, () -> ContainerStyle>>(
            "relative and absolute" to { style.copy(positioning = ContainerPositioning.RelativeAuto) },
            "missing width" to { style.copy(width = null) }, "auto width" to { style.copy(width = ContainerWidth.Auto) },
            "fit width" to { style.copy(width = ContainerWidth.FitContent) },
            "percent width" to { style.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f))) },
            "missing height" to { style.copy(height = null) }, "float" to { style.copy(floatSide = TableFloatSide.Left) },
            "clear" to { style.copy(clear = FigureClear.None) }, "layout" to { style.copy(layout = ContainerLayout.Flow) },
            "max width" to { style.copy(maxWidth = ContainerMaxWidth.None) }, "min height" to { style.copy(minHeight = zero) },
            "overflow" to { style.copy(overflow = ContainerOverflow.Visible) },
            "border box" to { style.copy(boxSizing = ContainerBoxSizing.BorderBox) },
            "padding" to { style.copy(padding = StyleEdges(zero, zero, zero, StyleLength(px, 1f))) },
            "auto margin" to { style.copy(marginValues = zeroMargins.copy(left = ContainerMargin.Auto)) },
            "background" to { style.copy(background = ContainerColor.Rgb("#000000")) },
            "border" to { style.copy(border = ContainerBorder.Solid(StyleLength(px, 1f), ContainerColor.Transparent)) },
            "break word" to { style.copy(textWrap = TextWrap.BreakWord) })
        invalidStyles.forEach { (label, make) -> invalid(label, make) }
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            invalid("Nonfinite absolute $bad") { ContainerAbsolutePosition(SignedContainerMargin(px, bad), zero) }
        }
        val (wire, bytes) = literal(valid)
        val key = "positioned.child0.child0.style"
        for (flags in listOf(0, 1, 63, 256 or 64, 256 or 128, 256 or 512, 65535)) {
            val bad = bytes.copyOf().also { it[4] = flags.toByte(); it[5] = (flags ushr 8).toByte() }
            reject("Strict Z LEu16 flags $flags", bad)
        }
        reject("Z owner bit debt", bytes.copyOf().also { it[4] = 0 })
        reject("Reserved old style bit23", changed32(bytes, wire.at.getValue("$key.flags"), 0x800000))
        reject("Unknown extension mask", changed(bytes, wire.at.getValue("$key.extension"), 8))
        reject("Unknown position unit", changed(bytes, wire.at.getValue("$key.left.unit"), 2))
        reject("No ordinal alias for nowrap", changed(bytes, wire.at.getValue("$key.wrap"), 2))
        reject("Literal percentage width", changed(bytes, wire.at.getValue("$key.width.unit"), StyleWidthUnit.Percent.ordinal))
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            reject("Literal nonfinite left $bad", changed32(bytes, wire.at.getValue("$key.left.value"), bad.toRawBits().toLong()))
            reject("Literal nonfinite top $bad", changed32(bytes, wire.at.getValue("$key.top.value"), bad.toRawBits().toLong()))
        }
        reject("Literal negative height", changed32(bytes, wire.at.getValue("$key.height.value"), (-1f).toRawBits().toLong()))
        reject("Wrong inherited P census", changed(bytes, wire.at.getValue("features"), 64))
        for (end in bytes.indices) reject("Truncated Z $end", bytes.copyOf(end))
        reject("Trailing Z data", bytes + byteArrayOf(0))
        val plain = box(listOf(leaf))
        val debt = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(plain) } }
        reject("No actual positioned payload", debt.document(emptyList(), Sink.Body))
        val oldStyle = ContainerStyle(ownerFont = font)
        val old = Wire('Y', 1).apply { paragraphOverride = { positionedBlock(box(listOf(leaf), oldStyle)) } }
        val oldBytes = old.document(emptyList(), Sink.Body)
        assertEquals(box(listOf(leaf), oldStyle), read(oldBytes).sections.single().blocks.single())
        val oldCombo = Wire('Y', 1).apply { paragraphOverride = {
            positionedBlock(box(listOf(leaf), oldStyle.copy(positioning = ContainerPositioning.RelativeAuto))) } }
        reject("Y cannot borrow relative owner capability", oldCombo.document(emptyList(), Sink.Body))
        assertArrayEquals(Wire('Y', 1).isolatedSpan(leaf.spans.single()), Wire('Z', 257).isolatedSpan(leaf.spans.single()))
        for (header in listOf("DPRZ", "DPRZ\u0000")) reject("Truncated known Z header", header.encodeToByteArray())
    }

    @Test fun positionedZSharesOriginalContentTableAndItemLimitsWithoutSkippingOutOfFlowChildren() {
        val px = StyleLengthUnit.Px
        val absolute = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 0f)), height = StyleLength(px, 0f),
            absolutePosition = ContainerAbsolutePosition(StyleLength(px, 0f), StyleLength(px, 0f)))
        for (depth in listOf(2, 16, 17)) {
            val wire = Wire('Z', 256).apply { containerStyleOverride = { label ->
                val index = label.removePrefix("container").toInt()
                positionedStyle(when (index) {
                    0 -> ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
                    depth - 1 -> absolute
                    else -> ContainerStyle()
                }, label)
            } }
            val bytes = wire.document(listOf(Span("link", "deep", "Deep")), Sink.Container, containers = depth)
            if (depth == 17) reject("Absolute cannot reset content17", bytes) else {
                val decoded = read(bytes)
                val values = mutableListOf<Container>()
                PresentationSpanVisitor { _, _ -> }.apply { onContainer = values::add }.blocks(decoded.sections.single().blocks)
                assertEquals(depth, values.size)
                assertEquals(absolute, values.last().style)
                assertEquals("Deep", values.last().blocks.single().spans.single().target)
            }
        }
        for (depth in listOf(32, 33)) {
            val wire = Wire('Z', 256).apply {
                containerStyleOverride = { positionedStyle(ContainerStyle(textWrap = TextWrap.Normal), it) }
                paragraphOverride = { tableChain(depth, mixed = true) }
            }
            val bytes = wire.document(listOf(text("table")), Sink.Container)
            if (depth == 33) reject("Z retains table33 refusal", bytes) else {
                val depths = mutableListOf<Int>()
                PresentationSpanVisitor { _, _ -> }.apply { onTable = { _, level, _ -> depths.add(level) } }
                    .blocks(read(bytes).sections.single().blocks)
                assertEquals((1..32).toList(), depths)
            }
        }
        val empty = Block("container", 0, emptyList(), container = Container(emptyList(), ContainerStyle(textWrap = TextWrap.Normal)))
        var visited = 0
        PresentationSpanVisitor { _, _ -> }.apply { onContainer = { visited++ } }
            .blocks(java.util.Collections.nCopies(1 shl 20, empty))
        assertEquals(1 shl 20, visited)
        invalid("Explicit wrap does not reset item budget") {
            PresentationSpanVisitor { _, _ -> }.blocks(java.util.Collections.nCopies((1 shl 20) + 1, empty))
        }
        // Exact decoder budget: section + root + three child blocks + two paragraphs + two link Spans = 9.
        val rows = (1 shl 20) - 9
        val exact = Wire('Z', 256).apply { paragraphOverride = { positionedBudget(rows) } }
        val decoded = read(exact.document(emptyList(), Sink.Body))
        val root = decoded.sections.single().blocks.single().container!!
        assertEquals(ContainerStyle(positioning = ContainerPositioning.RelativeAuto), root.style)
        assertEquals(3, root.blocks.size)
        val filler = root.blocks[1].table!!
        assertEquals(rows, filler.rows.size)
        assertTrue(filler.rows.all { it.isEmpty() })
        assertEquals(TableGrid(emptyList(), rows, 0), tableGrid(filler))
        for ((index, label) in listOf(0 to "before", 2 to "after")) {
            val child = root.blocks[index].container!!
            assertEquals(absolute, child.style)
            assertEquals(listOf(Block("paragraph", 0, listOf(Span("link", label, "Budget target")))), child.blocks)
        }
        val excess = Wire('Z', 256).apply { paragraphOverride = { positionedBudget(rows + 1) } }
        reject("Raw Z item count is one shared budget", excess.document(emptyList(), Sink.Body))
    }

    @Test fun citation64RetainsExplicitPairsPoliciesAndEveryOrdinarySpanSink() {
        val states = List(8) { LinkState("#12345$it", it % 2 == 1) }
        val paint = LinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], states[6], states[7], true)
        val targeted = paint.copy(normal = LinkState("#abcdef", true))
        val metrics = InlineTextStyle(lineHeight = InlineLineHeight.Computed(InlineComputedLength(15f, FontScaleBasis.CssPx)))
        fun marker(reference: Long, occurrence: Long, anchor: String) = Span("link", "[same]", role = "reference",
            targetFragment = "reference-$reference", tooltip = "marker tooltip", explanation = "marker explanation",
            superscript = true, small = true, fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFeatures = FontFeaturePolicy.Normal, foreground = states[0].foreground, background = "#fefefe", linkPaint = paint, inlineStyle = metrics,
            citationMarker = CitationMarker(reference, occurrence, anchor, true, BidiResolvedDirection.Rtl,
                CitationTargetStyle(targeted, FigureColor.Rgb("#ffeedd"))))
        fun backlink(occurrence: Long, anchor: String, styled: Boolean = true): ReferenceBacklink {
            val template = Span("link", "↩same", targetFragment = anchor, tooltip = "backlink tooltip",
                explanation = "backlink explanation", bold = true, fontScale = 18f, fontScaleBasis = FontScaleBasis.CssPx,
                foreground = if (styled) states[0].foreground else null,
                fontFamily = if (styled) ContainerFontFamily.SansSerif else null)
            val result = ReferenceBacklink.withPolicies(occurrence, template, if (styled) paint else null, if (styled) metrics else null)
            assertNull(template.linkPaint); assertNull(template.inlineStyle)
            assertFalse(template.isQualifiedCitationBacklink)
            assertNotSame(template, result.span)
            assertEquals(template.copy(linkPaint = null, inlineStyle = null), result.span.copy(
                linkPaint = null, inlineStyle = null, citationBacklinkWitness = null))
            assertSame(result.span, result.copy().span)
            return result
        }
        val first = marker(41, 7, "return-first")
        val second = marker(41, 2, "return-second")
        val third = marker(9, 101, "return-third")
        val references = listOf(
            Reference(9, 2, "other", listOf(text("Reference nine")), backlinks = listOf(backlink(101, "return-third"))),
            Reference(41, 1, "notes", listOf(text("Reference forty-one")), backlinks = listOf(
                backlink(2, "return-second", false), backlink(7, "return-first"))))
        val wire = Wire('Y', 64)
        val decoded = read(wire.document(listOf(first, text(" + "), second, third), features = 4, referenceValues = references))
        assertEquals(listOf(first, text(" + "), second, third), decoded.displayTitle)
        assertEquals(references, decoded.references)
        assertEquals(listOf(2L, 7L), decoded.references[1].backlinks.map { it.occurrence })
        assertEquals(listOf("↩same", "Reference nine"), mutableListOf<String>().also { runs ->
            decoded.references.first().visitSpanRuns { values, _ -> runs += values.joinToString("") { it.text } }
        })
        assertEquals("[same] + [same][same]", rubyFallbackText(decoded.displayTitle))
        assertEquals(targeted, decoded.displayTitle.first().citationMarker!!.targetStyle!!.paint)
        assertNotEquals(decoded.displayTitle.first().linkPaint!!.normal,
            decoded.displayTitle.first().citationMarker!!.targetStyle!!.paint.normal)
        val reset = first.copy(citationMarker = first.citationMarker!!.copy(targetStyle = CitationTargetStyle(targeted)))
        val resetSource = read(Wire('Y', 64).document(listOf(reset, second, third), features = 4, referenceValues = references)).displayTitle.first()
        assertEquals("#fefefe", resetSource.background)
        assertNull(resetSource.citationMarker!!.targetStyle!!.background)
        for (sink in Sink.entries.filterNot { it == Sink.Reference || it == Sink.ReferenceBlocks }) {
            val source = marker(9, 11, "return-${sink.name}").copy(citationMarker = CitationMarker(9, 11, "return-${sink.name}"))
            val note = Reference(9, 1, "", emptyList(), backlinks = listOf(backlink(11, "return-${sink.name}", false)))
            val result = read(Wire('Y', 64).document(listOf(source), sink, headingTitle = source.text, referenceValues = listOf(note)))
            val seen = mutableListOf<Span>()
            val visitor = PresentationSpanVisitor { _, _ -> }.apply { onCitationMarker = seen::add }
            visitor.spans(result.displayTitle); visitor.spans(result.preamble)
            result.sections.forEach { visitor.blocks(it.blocks) }
            assertEquals(sink.name, listOf(source), seen)
            assertEquals(note, result.references.single())
        }
        for (ordered in listOf(false, true)) {
            val note = Reference(9, 1, "", if (ordered) emptyList() else listOf(third),
                blocks = if (ordered) listOf(Block("container", 0, emptyList(), container = Container(listOf(
                    Block("paragraph", 0, listOf(third))), ContainerStyle()))) else null,
                backlinks = listOf(backlink(101, "return-third", false)))
            assertEquals(note, read(Wire('Y', 64).document(emptyList(), referenceValues = listOf(note))).references.single())
        }
        val z = Wire('Z', 320).apply { containerStyleOverride = { positionedStyle(ContainerStyle(textWrap = TextWrap.Normal), it) } }
        val zEntry = read(z.document(listOf(first, second, third), Sink.Container, features = 4, referenceValues = references))
        assertEquals(listOf(first, second, third), zEntry.sections.single().blocks.single().container!!.blocks.single().spans)
        assertEquals(references, zEntry.references)
    }

    @Test fun citation64RejectsForgedPoliciesPairsAnchorsAndQualifiedSpanEscapes() {
        val state = LinkState("#112233", false)
        val paint = LinkPaint(state, state, state, state, state, state, state, state, false)
        val metrics = InlineTextStyle(lineHeight = InlineLineHeight.Computed(InlineComputedLength(15f, FontScaleBasis.CssPx)))
        val marker = Span("link", "[7]", targetFragment = "reference-9", role = "reference", linkPaint = paint,
            inlineStyle = metrics, citationMarker = CitationMarker(9, 7, "return-seven", true, BidiResolvedDirection.Ltr,
                CitationTargetStyle(paint, FigureColor.Transparent)))
        val back = ReferenceBacklink.withPolicies(7, Span("link", "↑", targetFragment = "return-seven"), paint, metrics)
        val note = Reference(9, 1, "", emptyList(), backlinks = listOf(back))
        fun entry(markers: List<Span> = listOf(marker), refs: List<Reference> = listOf(note), sections: List<Section> = emptyList()) =
            Entry("Citations", markers, "language", "Japanese", "ja", sections, refs)
        assertSame(marker, entry().displayTitle.single())
        val copiedBack = back.copy(span = back.span.copy(text = "original copied label"))
        assertSame(copiedBack.span, entry(refs = listOf(note.copy(backlinks = listOf(copiedBack)))).references.single().backlinks.single().span)
        invalid("Isolation cannot compete with span direction") { marker.copy(direction = "rtl") }
        invalid("Target paint requires an independent normal policy") { marker.copy(linkPaint = null) }
        invalid("Malformed anchor UTF16") { marker.citationMarker!!.copy(anchor = "\ud800") }
        for (id in listOf(0L, 0xffff_ffffL, -1L)) {
            invalid("Reference ID") { marker.citationMarker!!.copy(reference = id) }
            invalid("Occurrence ID") { marker.citationMarker!!.copy(occurrence = id) }
            invalid("Backlink ID") { back.copy(occurrence = id) }
        }
        invalid("Ordinary local paint stays refused") { Span("link", "local", targetFragment = "a", linkPaint = paint) }
        invalid("Ordinary local inline metrics stay refused") { Span("link", "local", targetFragment = "a", inlineStyle = metrics) }
        invalid("Witness copy cannot become text") { back.span.copy(kind = "text") }
        invalid("Witness copy cannot gain an external target") { back.span.copy(target = "Elsewhere") }
        invalid("Witness copy cannot gain trail") { back.span.copy(trail = "tail") }
        invalid("Wrapper copy cannot replace qualified source with an ordinary template") {
            back.copy(span = Span("link", "↑", targetFragment = "return-seven"))
        }
        invalid("Only note owns backlinks") { note.copy(kind = ReferenceKind.Fragment, groupNumber = null) }
        invalid("Duplicate reference identity") { entry(refs = listOf(note, note.copy(backlinks = emptyList()))) }
        invalid("Duplicate pair") { entry(listOf(marker, marker)) }
        invalid("Missing backlink") { entry(refs = listOf(note.copy(backlinks = emptyList()))) }
        invalid("Backlink without marker") { entry(emptyList()) }
        invalid("Duplicate backlink") { entry(refs = listOf(note.copy(backlinks = listOf(back, back)))) }
        invalid("Wrong stored return target") { entry(refs = listOf(note.copy(backlinks = listOf(back.copy(span = back.span.copy(targetFragment = "wrong")))))) }
        invalid("Marker anchor collides with canonical footer") { entry(listOf(marker.copy(citationMarker = marker.citationMarker!!.copy(anchor = "reference-9")))) }
        for (fallback in listOf(false, true)) {
            val section = Section(2, "Anchored", emptyList(), anchor = if (fallback) "" else "return-seven",
                anchorFallback = if (fallback) "return-seven" else "")
            invalid("Section return anchor collision") { entry(sections = listOf(section)) }
            invalid("Footer collision") { entry(sections = listOf(section.copy(anchor = "reference-9", anchorFallback = ""))) }
            val block = Block("paragraph", 0, listOf(text("x")), anchor = if (fallback) "" else "return-seven",
                anchorFallback = if (fallback) "return-seven" else "")
            invalid("Nested Block return anchor collision") { entry(sections = listOf(Section(2, "Body", listOf(
                Block("container", 0, emptyList(), container = Container(listOf(block), ContainerStyle())))))) }
        }
        val escaping = back.span
        invalid("Display escape") { entry(listOf(escaping)) }
        invalid("Preamble escape") { entry().copy(preamble = listOf(escaping)) }
        invalid("Section escape") { entry(sections = listOf(Section(2, "Body", listOf(Block("paragraph", 0, listOf(escaping)))))) }
        invalid("Reference body escape") { entry(refs = listOf(note.copy(spans = listOf(escaping)))) }
        invalid("Container escape") { PresentationSpanVisitor { _, _ -> }.blocks(listOf(Block("container", 0, emptyList(),
            container = Container(listOf(Block("paragraph", 0, listOf(escaping))), ContainerStyle())))) }
        invalid("Cell escape") { PresentationSpanVisitor { _, _ -> }.table(Table(emptyList(), listOf(listOf(Cell(listOf(escaping), false, 1, 1))))) }
        invalid("Ruby body escape") { owner(listOf(base(escaping))) }
        invalid("Ruby reading marker remains outside its child domain") { owner(listOf(base(text("x"))), listOf(annotation(marker))) }
        invalid("Ruby RP marker remains outside its child domain") { owner(listOf(base(text("x"))), listOf(annotation(text("y"), before = listOf(marker), explicit = true))) }
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        invalid("Padding child marker remains outside its child domain") { InlinePaddingGroup(zero, StyleLength(StyleLengthUnit.Px, 1f), listOf(marker)) }
        invalid("Action child marker remains outside its child domain") { InlineActionGroup(listOf(marker)) }
        val edges = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        invalid("Box child marker remains outside its child domain") { InlineBoxGroup(StyleEdges(zero, zero, zero, zero), edges, spans = listOf(marker)) }
        val wire = Wire('Y', 64)
        val bytes = wire.document(listOf(marker), referenceValues = listOf(note))
        val payload = "root.0.citation"
        reject("Citation presence", changed(bytes, wire.at.getValue(payload), 2))
        reject("Unknown marker policy", changed(bytes, wire.at.getValue("$payload.policy"), 8))
        reject("Unknown isolation", changed(bytes, wire.at.getValue("$payload.isolation"), 2))
        reject("Unknown target background presence", changed(bytes, wire.at.getValue("$payload.background"), 2))
        reject("Native theme target background", changed(bytes, wire.at.getValue("$payload.background") + 1, 0))
        for (name in listOf("reference", "occurrence")) for (id in listOf(0L, 0xffff_ffffL))
            reject("Invalid marker $name", changed32(bytes, wire.at.getValue("$payload.$name"), id))
        reject("Unknown reference", changed32(bytes, wire.at.getValue("$payload.reference"), 8))
        reject("Invalid backlink occurrence", changed32(bytes, wire.at.getValue("backlinks.0.0.occurrence"), 0))
        reject("Mismatched backlink occurrence", changed32(bytes, wire.at.getValue("backlinks.0.0.occurrence"), 6))
        reject("Forged backlink count", changed32(bytes, wire.at.getValue("backlinks.0.count"), 0xffff_ffffL))
        reject("Empty marker anchor", replace(bytes, wire.at.getValue("$payload.anchor"), wire.at.getValue("$payload.policy"), ByteArray(4)))
        reject("Non-reference marker role", changed(bytes, wire.at.getValue("root.0.start") + 1, 0))
        reject("Forged marker normal checksum", changed(bytes, wire.at.getValue("root.0.start") + 2, 128))
        reject("Backlink cannot contain a marker", changed(bytes, wire.at.getValue("backlinks.0.0.span.citation"), 1))
        reject("Clipped feature cannot replace citation payload", changed(bytes, wire.at.getValue("yFeatures"), 128))
        reject("Feature debt", changed(bytes, wire.at.getValue("yFeatures"), 1))
        for (end in wire.at.getValue(payload)..bytes.lastIndex) reject("Truncated citation/trailer at $end", bytes.copyOf(end))
        reject("EOF remains exact", bytes + byteArrayOf(0))
    }

    @Test fun citation64KeepsNullWireBytesAndSharesLatePrefixFeatureAndItemBudgets() {
        val plain = text("ordinary")
        val legacy = Wire('V').document(listOf(plain))
        val unused = Wire('Y', 64)
        val unusedBytes = unused.document(listOf(plain))
        reject("Bit64 needs an actual paired marker", unusedBytes)
        // Remove only the new header byte and per-Span presence: every V payload byte is unchanged.
        val presence = unused.at.getValue("root.0.citation")
        val withoutPresence = replace(unusedBytes, presence, presence + 1, byteArrayOf())
        val restored = changed(withoutPresence.copyOfRange(0, 4) + withoutPresence.copyOfRange(5, withoutPresence.size), 3, 'V'.code)
        assertArrayEquals(legacy, restored)
        val marker = Span("link", "[1]", role = "reference", targetFragment = "reference-9",
            citationMarker = CitationMarker(9, 23, "return-budget"))
        val prefix = ReferenceBacklink.withPolicies(23, Span("link", "↑", targetFragment = "return-budget",
            fontFamily = ContainerFontFamily.SansSerif))
        val note = Reference(9, 1, "", emptyList(), backlinks = listOf(prefix))
        val wire = Wire('Y', 64)
        val bytes = wire.document(listOf(marker), referenceValues = listOf(note), features = 4)
        assertEquals(note, read(bytes).references.single())
        reject("Late backlink font-family payload owes P bit4", changed(bytes, wire.at.getValue("features"), 0))
        val noFamily = note.copy(backlinks = listOf(ReferenceBacklink.withPolicies(23,
            Span("link", "↑", targetFragment = "return-budget"))))
        reject("P bit4 cannot be paid by marker identity", Wire('Y', 64).document(listOf(marker), referenceValues = listOf(noFamily), features = 4))
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f), right = InlineBoxInset(StyleWidthUnit.Px, 0f)), edges)
        fun box(count: Int) = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), edges,
            java.util.Collections.nCopies(count, overlay), listOf(text("x"))))
        fun entry(count: Int) = Entry("Budget", listOf(box(count), marker), "language", "Japanese", "ja", emptyList(), listOf(noFamily))
        // Model: Box + leaf + marker Span + marker payload + backlink wrapper + backlink Span.
        val modelMaximum = (1 shl 20) - 6
        assertEquals(modelMaximum, entry(modelMaximum).displayTitle.first().inlineBoxGroup!!.overlays.size)
        invalid("Citation payload and prefix share the model budget") { entry(modelMaximum + 1) }
        // Decoder additionally retains its historical reference-slot charge; no retroactive model charge.
        val wireMaximum = (1 shl 20) - 7
        for (count in listOf(wireMaximum, wireMaximum + 1)) {
            val raw = Wire('Y', 68).apply { rootOverride = { boxBudget(count, it, marker) } }
            val encoded = raw.document(emptyList(), referenceValues = listOf(noFamily))
            if (count == wireMaximum) {
                val decoded = read(encoded)
                assertEquals(marker, decoded.displayTitle.last())
                assertEquals(noFamily, decoded.references.single())
                assertEquals(count, decoded.displayTitle.first().inlineBoxGroup!!.overlays.size)
            } else reject("Late backlink cannot restart the wire item budget", encoded)
        }
        // No citation data means historical duplicate references still have their old model behavior.
        val old = Reference(9, 1, "", emptyList())
        assertEquals(2, Entry("Legacy", listOf(plain), "language", "Japanese", "ja", emptyList(), listOf(old, old)).references.size)
    }
    @Test fun staticInlineZRetainsSoleSourceBodyIndependentOwnersAndExactDirectionAcrossSinks() {
        // Synthetic carrier boundary, not proof of hypothetical native placement or producer acceptance.
        val px = StyleLengthUnit.Px
        val parentFont = InlineFontSnapshot(18f, FontScaleBasis.CssPx, fontNormalized = true, bold = true, language = "fr")
        val childFont = parentFont.copy(fontScale = 27f, bold = false, italic = true)
        val kept = Span("link", "Kept", "Target", trail = " ", targetFragment = "French", direction = "rtl",
            tooltip = "Tip", explanation = "Meaning", fontScale = 1.35f, fontScaleBasis = FontScaleBasis.NormalBody)
        val external = Span("external_link", "outside", "https://example.test/static", direction = "ltr")
        val source = listOf(text("("), kept, external.copy(trail = ")"))
        val paragraph = Block("paragraph", 0, source)
        fun box(blocks: List<Block>, style: ContainerStyle) = Block("container", 0, emptyList(), container = Container(blocks, style))
        val parentStyle = ContainerStyle(positioning = ContainerPositioning.RelativeAuto, width = ContainerWidth.Auto,
            ownerFont = parentFont, lineHeight = ContainerLineHeight.Length(StyleLength(px, 31f)), textAlign = CellTextAlign.Right,
            textWrap = TextWrap.NoWrap)
        for (direction in ContainerStaticDirection.entries) {
            val childStyle = ContainerStyle(width = ContainerWidth.FitContent, ownerFont = childFont,
                lineHeight = ContainerLineHeight.Length(StyleLength(px, 22f)), textAlign = CellTextAlign.Center,
                textWrap = TextWrap.Normal, absoluteStatic = ContainerAbsoluteStaticPosition(direction))
            val child = box(listOf(paragraph), childStyle)
            val root = box(listOf(child), parentStyle)
            assertTrue(validSoleStaticInlineContainer(checkNotNull(root.container)))
            assertSame(source, child.container!!.blocks.single().spans)
            assertSame(parentFont, root.container!!.style.ownerFont)
            assertSame(childFont, child.container!!.style.ownerFont)
            assertSame(kept, child.container!!.blocks.single().spans[1])
            assertEquals("rtl", kept.direction)
            for (sink in listOf(Sink.Body, Sink.CellBlocks, Sink.TableRichCaption, Sink.ReferenceBlocks,
                    Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)) {
                val wire = Wire('Z', 257).apply { paragraphOverride = { positionedBlock(root, "static") } }
                val bytes = wire.document(emptyList(), sink)
                assertArrayEquals(byteArrayOf(68, 80, 82, 90, 1, 1), bytes.copyOf(6))
                assertEquals(direction.ordinal, bytes[wire.at.getValue("static.child0.style.static")].toInt())
                val decoded = read(bytes)
                val containers = mutableListOf<Container>()
                val spans = mutableListOf<Span>()
                val visitor = PresentationSpanVisitor { _, _ -> }.apply { onContainer = containers::add }
                decoded.sections.forEach { visitor.blocks(it.blocks) }
                decoded.references.forEach { reference -> reference.blocks?.let { visitor.blocks(it) } }
                assertEquals(listOf(root.container, child.container), containers)
                PresentationSpanVisitor { _, _ -> }.apply { onSpan = spans::add }.blocks(containers.first().blocks)
                assertEquals(source, spans)
                assertEquals("(Kept outside)", textOf(spans))
                assertEquals(listOf("Target", "https://example.test/static"), spans.filter { it.kind != "text" }.map { it.target })
                assertEquals(parentStyle.lineHeight, containers[0].style.lineHeight)
                assertEquals(childStyle.lineHeight, containers[1].style.lineHeight)
                assertNull(containers[1].style.height)
                assertNull(containers[1].style.absolutePosition)
            }
        }
        val plainChild = box(listOf(Block("paragraph", 0, listOf(text(" ")))), ContainerStyle(
            width = ContainerWidth.FitContent, absoluteStatic = ContainerAbsoluteStaticPosition()))
        val plainRoot = box(listOf(plainChild), ContainerStyle(positioning = ContainerPositioning.RelativeAuto))
        val noFont = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(plainRoot) } }
        assertEquals(plainRoot, read(noFont.document(emptyList(), Sink.Body)).sections.single().blocks.single())
        assertNull(plainChild.container!!.style.ownerFont)
        assertEquals(ContainerStaticDirection.Inherit, plainChild.container!!.style.absoluteStatic!!.direction)

        // Independent byte literals: adding static support must not append a tag to old fixed or Y styles.
        val fixed = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 1f)), height = StyleLength(px, 2f),
            absolutePosition = ContainerAbsolutePosition(SignedContainerMargin(px, -3f), StyleLength(px, 4f)), textWrap = TextWrap.NoWrap)
        assertArrayEquals(byteArrayOf(4, 0, 2, 0, 1, 0, 0, 0, -128, 63, 0, 0, 0, 0, 64,
            3, 0, 0, 0, 64, -64, 0, 0, 0, -128, 64, 1), Wire('Z', 256).isolatedPositionedStyle(fixed))
        assertArrayEquals(byteArrayOf(4, 0, 0, 0, 0), Wire('Y', 1).isolatedPositionedStyle(ContainerStyle(width = ContainerWidth.Auto)))
        assertArrayEquals(byteArrayOf(4, 0, 0, 0, 2, 4, 0), Wire('Z', 256).isolatedPositionedStyle(plainChild.container!!.style))
    }

    @Test fun staticInlineZRejectsBorrowedCustodyUnsupportedBodiesAndForgedExtensionTags() {
        val px = StyleLengthUnit.Px
        val zero = StyleLength(px, 0f)
        val childStyle = ContainerStyle(width = ContainerWidth.FitContent, absoluteStatic = ContainerAbsoluteStaticPosition())
        val leaf = Block("paragraph", 0, listOf(Span("link", "source", "Kept")))
        fun box(blocks: List<Block>, style: ContainerStyle = ContainerStyle()) = Block("container", 0, emptyList(), container = Container(blocks, style))
        val child = box(listOf(leaf), childStyle)
        val parentStyle = ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
        fun relative(vararg blocks: Block) = box(blocks.toList(), parentStyle)
        fun table(block: Block) = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(
            Cell(spans = emptyList(), header = false, colspan = 1, rowspan = 1, blocks = listOf(block))))))
        fun entry(root: Block) = Entry("Static", emptyList(), "language", "French", "fr", listOf(Section(2, "Body", listOf(root))), emptyList())
        fun literal(root: Block): Pair<Wire, ByteArray> {
            val wire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(root, "static") } }
            return wire to wire.document(emptyList(), Sink.Body)
        }
        val valid = relative(child)
        assertSame(valid, entry(valid).sections.single().blocks.single())
        for ((label, root) in listOf("orphan" to child, "ordinary parent" to box(listOf(child)),
                "intermediate parent" to relative(box(listOf(child))), "leading sibling" to relative(leaf, child),
                "trailing sibling" to relative(child, leaf), "table cannot lend anchor" to relative(table(child)),
                "earlier relative sibling" to box(listOf(relative(leaf), child)))) {
            invalid(label) { entry(root) }; reject(label, literal(root).second)
        }
        val nearer = relative(box(listOf(relative(child))))
        assertEquals(nearer, read(literal(nearer).second).sections.single().blocks.single())
        val cell = table(relative(child))
        assertEquals(cell, read(literal(cell).second).sections.single().blocks.single())
        invalid("Independent section cannot borrow parent") { entry(valid).copy(sections = listOf(Section(2, "First", listOf(valid)), Section(2, "Other", listOf(child)))) }
        val reference = Reference(1, null, "ref", emptyList(), ReferenceKind.Fragment, listOf(child))
        invalid("Independent reference cannot borrow parent") { entry(valid).copy(references = listOf(reference)) }
        val referenceWire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(valid) } }
        reject("Literal independent reference", referenceWire.document(emptyList(), Sink.Body, referenceValues = listOf(reference)))
        for (sink in listOf(Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure, Sink.TableRichCaption)) {
            val wire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(child) } }
            reject("Independent replaced owner at $sink", wire.document(emptyList(), sink))
        }
        for (style in listOf(parentStyle.copy(width = ContainerWidth.FitContent), parentStyle.copy(height = zero),
                parentStyle.copy(overflow = ContainerOverflow.Visible), parentStyle.copy(clear = FigureClear.None))) {
            invalid("Unsupported immediate parent $style") { entry(box(listOf(child), style)) }
        }
        val margin = ContainerMargins(ContainerMargin.Length(zero), ContainerMargin.Length(zero), ContainerMargin.Length(zero), ContainerMargin.Length(zero))
        val neutral = childStyle.copy(padding = StyleEdges(zero, zero, zero, zero), margins = StyleEdges(zero, zero, zero, zero),
            border = ContainerBorder.None, background = ContainerColor.Transparent, boxSizing = ContainerBoxSizing.ContentBox)
        assertTrue(validContainerAbsoluteStaticBody(Container(listOf(leaf), neutral)))
        assertTrue(validContainerAbsoluteStaticBody(Container(listOf(leaf), neutral.copy(margins = null, marginValues = margin))))
        for ((label, make) in listOf<Pair<String, () -> ContainerStyle>>(
                "auto width" to { childStyle.copy(width = ContainerWidth.Auto) }, "missing width" to { childStyle.copy(width = null) },
                "explicit height" to { childStyle.copy(height = zero) }, "relative" to { childStyle.copy(positioning = ContainerPositioning.RelativeAuto) },
                "fixed" to { childStyle.copy(absolutePosition = ContainerAbsolutePosition(zero, zero)) },
                "visible overflow" to { childStyle.copy(overflow = ContainerOverflow.Visible) }, "clear none" to { childStyle.copy(clear = FigureClear.None) },
                "flow layout" to { childStyle.copy(layout = ContainerLayout.Flow) }, "max none" to { childStyle.copy(maxWidth = ContainerMaxWidth.None) },
                "padding" to { childStyle.copy(padding = StyleEdges(zero, zero, zero, StyleLength(px, 1f))) },
                "auto margin" to { childStyle.copy(marginValues = margin.copy(left = ContainerMargin.Auto)) },
                "border box" to { childStyle.copy(boxSizing = ContainerBoxSizing.BorderBox) })) invalid(label, make)
        for (spans in listOf(emptyList(), listOf(text("")), listOf(Span("line_break", "")), listOf(simple()),
                listOf(Span("text", "", image = InlineImage("Image.png", 1))),
                listOf(Span("text", "", inlinePaddingGroup = InlinePaddingGroup(zero, StyleLength(px, 1f), listOf(text("x"))))))) {
            invalid("Unsupported static body $spans") { Container(listOf(Block("paragraph", 0, spans)), childStyle) }
        }
        invalid("Extra body paragraph") { Container(listOf(leaf, leaf), childStyle) }
        invalid("Paragraph alignment is not container alignment") { Container(listOf(leaf.copy(textAlign = CellTextAlign.Center)), childStyle) }
        val (wire, bytes) = literal(valid)
        val styleKey = "static.child0.style"
        val textKey = "static.child0.child0.spans.0.text.bytes"
        for (control in (0..31) + 127) {
            invalid("Control in text $control") { Container(listOf(Block("paragraph", 0, listOf(text(control.toChar().toString())))), childStyle) }
            invalid("Control in trail $control") { Container(listOf(Block("paragraph", 0, listOf(Span("text", "x", trail = control.toChar().toString())))), childStyle) }
            reject("Literal control $control", changed(bytes, wire.at.getValue(textKey), control))
        }
        for (tag in listOf(3, 255)) reject("Unknown direction $tag", changed(bytes, wire.at.getValue("$styleKey.static"), tag))
        for (mask in listOf(8, 128, 255)) reject("Unknown static extension $mask", changed(bytes, wire.at.getValue("$styleKey.extension"), mask))
        reject("Static is not auto width", changed(bytes, wire.at.getValue("$styleKey.width"), 0))
        val fixedPayload = ByteArray(10) // Two real zero px lengths before the unchanged static selector.
        val simultaneous = replace(bytes, wire.at.getValue("$styleKey.static"), wire.at.getValue("$styleKey.static"), fixedPayload)
        reject("Literal simultaneous fixed and static", changed(simultaneous, wire.at.getValue("$styleKey.extension"), 5))
        reject("Exact P census remains", changed(bytes, wire.at.getValue("features"), 64))
        reject("Z still needs bit256", changed(bytes, 5, 0))
        reject("Clipped tail and census are required beside static positioning", changed(bytes, 4, 128))
        for (end in bytes.indices) reject("Truncated static $end", bytes.copyOf(end))
        reject("Trailing static data", bytes + byteArrayOf(0))
        val debt = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(relative(leaf)) } }
        reject("No actual static/fixed/wrap payload", debt.document(emptyList(), Sink.Body))
        assertEquals(valid, read(bytes).sections.single().blocks.single())
    }

    @Test fun staticInlineZSharesContentAndExactItemLimitsWithoutCountingHypotheticalCopies() {
        val childStyle = ContainerStyle(width = ContainerWidth.FitContent, absoluteStatic = ContainerAbsoluteStaticPosition())
        val parentStyle = ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
        for (depth in listOf(2, 16, 17)) {
            val wire = Wire('Z', 256).apply { containerStyleOverride = { label ->
                val index = label.removePrefix("container").toInt()
                positionedStyle(when (index) { depth - 1 -> childStyle; depth - 2 -> parentStyle; else -> ContainerStyle() }, label)
            } }
            val bytes = wire.document(listOf(Span("link", "source", "Kept")), Sink.Container, containers = depth)
            if (depth == 17) reject("Static cannot reset content17", bytes) else {
                val containers = mutableListOf<Container>()
                PresentationSpanVisitor { _, _ -> }.apply { onContainer = containers::add }.blocks(read(bytes).sections.single().blocks)
                assertEquals(depth, containers.size)
                assertTrue(validSoleStaticInlineContainer(containers[depth - 2]))
                assertEquals("Kept", containers.last().blocks.single().spans.single().target)
            }
        }
        val owner = InlineFontSnapshot(1f, FontScaleBasis.NormalBody, fontNormalized = true)
        val source = listOf(text("before "), Span("link", "source", "Kept"), text(" after"))
        val child = Block("container", 0, emptyList(), container = Container(listOf(Block("paragraph", 0, source)), childStyle.copy(ownerFont = owner)))
        val parent = Block("container", 0, emptyList(), container = Container(listOf(child), parentStyle.copy(ownerFont = owner)))
        // Section1 + five blocks + two declaring owners + three spans = eleven items; every empty Table row adds one.
        val rows = (1 shl 20) - 11
        fun literal(count: Int): ByteArray {
            val table = Block("table", 0, emptyList(), table = Table(emptyList(), java.util.Collections.nCopies(count, emptyList<Cell>())))
            val root = Block("container", 0, emptyList(), container = Container(listOf(table, parent), ContainerStyle()))
            val wire = Wire('Z', 257).apply { paragraphOverride = { positionedBlock(root, "budget") } }
            return wire.document(emptyList(), Sink.Body)
        }
        val decoded = read(literal(rows))
        val children = checkNotNull(decoded.sections.single().blocks.single().container).blocks
        val table = checkNotNull(children[0].table)
        assertEquals(rows, table.rows.size); assertTrue(table.rows.all { it.isEmpty() })
        assertEquals(TableGrid(emptyList(), rows, 0), tableGrid(table))
        assertEquals(parent, children[1])
        val retained = children[1].container!!.blocks.single().container!!.blocks.single().spans
        assertEquals(source, retained); assertEquals("Kept", retained[1].target)
        reject("Static shares exact aggregate item limit", literal(rows + 1))
    }

    @Test fun tableMinimum512RetainsIndependentPreferredWidthsCompleteSourcesAndEveryTableSink() {
        val px = StyleLengthUnit.Px
        val caption = Span("link", "caption", "Caption target", targetFragment = "caption")
        val kept = Span("link", "kept", "Cell target", tooltip = "tip", explanation = "meaning")
        val external = Span("external_link", "nested", "https://example.test/nested")
        val nested = Table(emptyList(), listOf(listOf(Cell(listOf(external), false, 1, 1))),
            style = TableStyle(minWidth = StyleWidth(StyleWidthUnit.Em, 1.5f)))
        val rows = listOf(listOf(Cell(listOf(kept), false, 1, 2), Cell(emptyList(), true, 1, 1, nestedTable = nested)),
            listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(Block("paragraph", 0, listOf(text("self")))))))
        val padding = StyleEdges(StyleLength(px, 1f), StyleLength(px, 2f), StyleLength(px, 3f), StyleLength(px, 4f))
        for (minimum in listOf(StyleWidth(StyleWidthUnit.Px, 0f), StyleWidth(StyleWidthUnit.Px, 12.25f),
                StyleWidth(StyleWidthUnit.Em, 2f), StyleWidth(StyleWidthUnit.Percent, 70f), StyleWidth(StyleWidthUnit.Percent, 150f))) {
            val style = TableStyle(border = StyleBorder.Solid(StyleLength(px, 1f), "#123456"), collapse = TableCollapse.Separate,
                width = StyleWidth(StyleWidthUnit.Px, 100f), padding = padding, minWidth = minimum)
            val table = Table(listOf(caption), rows, style = style)
            val block = Block("table", 0, emptyList(), table = table)
            assertSame(minimum, style.minWidth); assertSame(minimum, style.copy(floatSide = TableFloatSide.Right).minWidth)
            assertEquals(100f, style.width!!.value, 0f)
            assertNotEquals(style, style.copy(minWidth = null))
            for (sink in listOf(Sink.Body, Sink.Container, Sink.CellBlocks, Sink.TableRichCaption, Sink.ReferenceBlocks,
                    Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)) {
                val wire = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(block, "minimum") } }
                val bytes = wire.document(emptyList(), sink)
                assertArrayEquals(byteArrayOf(68, 80, 82, 90, 0, 2), bytes.copyOf(6))
                val decoded = read(bytes)
                val found = mutableListOf<Table>()
                val visitor = PresentationSpanVisitor { _, _ -> }.apply { onTable = { value, _, _ -> if (value.style?.minWidth != null) found.add(value) } }
                decoded.sections.forEach { visitor.blocks(it.blocks) }
                decoded.references.forEach { reference -> reference.blocks?.let { visitor.blocks(it) } }
                assertEquals(listOf(table, nested), found)
                assertEquals(listOf(caption), found.first().caption)
                assertEquals(2, found.first().rows[0][0].rowspan)
                assertEquals(kept, found.first().rows[0][0].spans.single())
                if (sink == Sink.Body) assertEquals(Entry("Ruby", emptyList(), "language", "Japanese", "ja",
                    listOf(Section(2, "Body", listOf(block))), emptyList(), organization = PresentationOrganization(emptyList(), emptyList())), decoded)
            }
            val auto = style.copy(width = null)
            val above = style.copy(width = StyleWidth(StyleWidthUnit.Px, 400f))
            for (sourceStyle in listOf(auto, above)) {
                val expected = table.copy(style = sourceStyle)
                val wire = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(block.copy(table = expected)) } }
                assertEquals(expected, read(wire.document(emptyList(), Sink.Body)).sections.single().blocks.single().table)
            }
        }
        val onlyMinimum = TableStyle(minWidth = StyleWidth(StyleWidthUnit.Percent, 70f))
        val empty = Table(emptyList(), emptyList(), style = onlyMinimum)
        val emptyWire = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = empty)) } }
        assertEquals(empty, read(emptyWire.document(emptyList(), Sink.Body)).sections.single().blocks.single().table)
        val inline = Table(emptyList(), listOf(listOf(Cell(listOf(kept), false, 1, 1))),
            style = onlyMinimum.copy(display = TableDisplay.InlineTable))
        val inlineWire = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = inline)) } }
        assertEquals(inline, read(inlineWire.document(emptyList(), Sink.Body)).sections.single().blocks.single().table)
        val absolute = Block("container", 0, emptyList(), container = Container(listOf(Block("paragraph", 0, listOf(kept))),
            ContainerStyle(width = ContainerWidth.FitContent, absoluteStatic = ContainerAbsoluteStaticPosition(ContainerStaticDirection.Rtl))))
        val parent = Block("container", 0, emptyList(), container = Container(listOf(absolute), ContainerStyle(positioning = ContainerPositioning.RelativeAuto)))
        val mixed = Block("container", 0, emptyList(), container = Container(listOf(parent, Block("table", 0, emptyList(), table = empty)), ContainerStyle()))
        val mixedWire = Wire('Z', 768).apply { paragraphOverride = { positionedBlock(mixed) } }
        val mixedBytes = mixedWire.document(emptyList(), Sink.Body)
        assertArrayEquals(byteArrayOf(68, 80, 82, 90, 0, 3), mixedBytes.copyOf(6))
        assertEquals(mixed, read(mixedBytes).sections.single().blocks.single())
        reject("Mixed minimum debt", changed(mixedBytes, 5, 1))
        reject("Mixed positioned debt", changed(mixedBytes, 5, 2))
    }

    @Test fun tableMinimum512RejectsResponsiveOccurrencesMalformedWidthsAndCapabilityDebtWithoutChangingNullBytes() {
        val minimum = StyleWidth(StyleWidthUnit.Percent, 70f)
        val style = TableStyle(minWidth = minimum)
        val source = Span("link", "source", "Kept")
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(source), false, 1, 1))), style = style)
        val block = Block("table", 0, emptyList(), table = table)
        val wire = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(block, "minimum") } }
        val bytes = wire.document(emptyList(), Sink.Body)
        val key = "minimum.table.style"
        assertEquals(0, bytes[wire.at.getValue("$key.flags")].toInt())
        assertEquals(64, bytes[wire.at.getValue("$key.extension")].toInt())
        for (flags in listOf(0, 1, 127, 128, 256, 512 or 128, 1024, 65535)) {
            val bad = bytes.copyOf().also { it[4] = flags.toByte(); it[5] = (flags ushr 8).toByte() }
            reject("Minimum header $flags", bad)
        }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            invalid("Direct minimum $value") { TableStyle(minWidth = StyleWidth(StyleWidthUnit.Percent, value)) }
            reject("Literal minimum $value", changed32(bytes, wire.at.getValue("$key.minimum.value"), value.toRawBits().toLong()))
        }
        for (unit in listOf(3, 255)) reject("Unknown minimum unit $unit", changed(bytes, wire.at.getValue("$key.minimum.unit"), unit))
        reject("Reserved second table bit", changed(bytes, wire.at.getValue("$key.extension"), 192))
        reject("Unannounced payload after null style", changed(bytes, wire.at.getValue("$key.presence"), 0))
        reject("Minimum does not earn P corner/flow features", changed(bytes, wire.at.getValue("features"), 32))
        for (end in bytes.indices) reject("Truncated minimum $end", bytes.copyOf(end))
        reject("Trailing minimum data", bytes + byteArrayOf(0))
        val noMinimum = table.copy(style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 100f)))
        val debt = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(block.copy(table = noMinimum)) } }
        reject("512 requires an actual minimum", debt.document(emptyList(), Sink.Body))
        val noPosition = Wire('Z', 768).apply { paragraphOverride = { positionedBlock(block) } }
        reject("256 independently requires positioned payload", noPosition.document(emptyList(), Sink.Body))
        val oldStyle = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 100f))
        val expectedOld = byteArrayOf(1, 32, 0, 0, 0, 0, -56, 66)
        for (writer in listOf(Wire('Y', 1), Wire('Z', 256), Wire('Z', 512), Wire('Z', 768)))
            assertArrayEquals(expectedOld, writer.isolatedMinimumTableStyle(oldStyle))
        assertArrayEquals(byteArrayOf(0), Wire('Z', 512).isolatedMinimumTableStyle(null))
        assertArrayEquals(byteArrayOf(1, 0, 64, 2, 0, 0, -116, 66), Wire('Z', 512).isolatedMinimumTableStyle(style))
        // New scalar follows every old field, including the Q corner payload and containing direction.
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val corners = TableCornerRadii(zero, zero, zero, zero)
        val oldCorner = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Separate, margins = edges,
            containingDirection = TableContainingDirection.Rtl, cornerRadii = corners)
        val oldBytes = Wire('Z', 256).isolatedMinimumTableStyle(oldCorner)
        val newBytes = Wire('Z', 512).isolatedMinimumTableStyle(oldCorner.copy(minWidth = minimum))
        assertArrayEquals(changed(oldBytes, 2, oldBytes[2].toInt() or 64), newBytes.copyOf(oldBytes.size))
        assertArrayEquals(byteArrayOf(2, 0, 0, -116, 66), newBytes.copyOfRange(oldBytes.size, newBytes.size))
        val auto = ContainerMargins(ContainerMargin.Length(zero), ContainerMargin.Auto, ContainerMargin.Length(zero), ContainerMargin.Auto)
        val box = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 100f), marginValues = auto, containingDirection = TableContainingDirection.Ltr)
        val grid = TableStyle(collapse = TableCollapse.Collapse)
        val viewport = TableBlockViewport(100, box, ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
            grid, TableContainingDirection.Ltr, "ja")
        invalid("Minimum on responsive ordinary style") { table.copy(blockViewport = viewport) }
        invalid("Minimum on viewport box") { viewport.copy(boxStyle = box.copy(minWidth = minimum)) }
        invalid("Minimum on anonymous grid") { viewport.copy(gridStyle = grid.copy(minWidth = minimum)) }
        val floating = TableFloatViewport(639, TableContainingDirection.Ltr, TableContainingDirection.Ltr, "ja")
        invalid("Minimum on responsive float style") { table.copy(style = style.copy(floatSide = TableFloatSide.Right, margins = edges), floatViewport = floating) }
        fun responsive(flags: Int, outer: TableStyle?, boxStyle: TableStyle, gridStyle: TableStyle): ByteArray {
            val w = Wire('Z', flags).apply {
                containerStyleOverride = { positionedStyle(ContainerStyle(textWrap = TextWrap.Normal), it) }
                paragraphOverride = { responsiveMinimum(outer, boxStyle, gridStyle) }
            }
            return w.document(emptyList(), Sink.Container)
        }
        assertEquals(viewport, read(responsive(256, null, box, grid)).sections.single().blocks.single().container!!.blocks.single().table!!.blockViewport)
        reject("Literal outer responsive minimum", responsive(768, style, box, grid))
        reject("Literal hidden box minimum", responsive(768, null, box.copy(minWidth = minimum), grid))
        reject("Literal hidden grid minimum", responsive(768, null, box, grid.copy(minWidth = minimum)))
        assertEquals(table, read(bytes).sections.single().blocks.single().table)
    }

    @Test fun tableMinimum512UsesOriginalContentTableAndExactItemBudgets() {
        val source = Span("link", "minimum", "Kept")
        val style = TableStyle(minWidth = StyleWidth(StyleWidthUnit.Px, 0f))
        val leaf = Table(listOf(source), emptyList(), style = style)
        for (depth in listOf(32, 33)) {
            var table = leaf
            repeat(depth - 1) { index ->
                val cell = if (index % 2 == 0) Cell(emptyList(), false, 1, 1, nestedTable = table)
                    else Cell(emptyList(), false, 1, 1, blocks = listOf(Block("table", 0, emptyList(), table = table)))
                table = Table(emptyList(), listOf(listOf(cell)))
            }
            val root = Block("table", 0, emptyList(), table = table)
            val wire = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(root) } }
            val bytes = wire.document(emptyList(), Sink.Body)
            if (depth == 33) reject("Minimum cannot reset table33", bytes) else {
                val depths = mutableListOf<Int>()
                PresentationSpanVisitor { _, _ -> }.apply { onTable = { _, level, _ -> depths.add(level) } }
                    .blocks(read(bytes).sections.single().blocks)
                assertEquals((1..32).toList(), depths)
            }
        }
        for (depth in listOf(16, 17)) {
            val wire = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = leaf)) } }
            val bytes = wire.document(emptyList(), Sink.Container, containers = depth)
            if (depth == 17) reject("Minimum cannot reset content17", bytes)
            else assertEquals(listOf(source), read(bytes).sections.single().blocks.let { blocks ->
                val spans = mutableListOf<Span>(); PresentationSpanVisitor { values, _ -> spans.addAll(values) }.blocks(blocks); spans
            })
        }
        // Section1 + table block1 + caption Span1; the scalar is not another item or an owner.
        val rows = (1 shl 20) - 3
        fun literal(count: Int): ByteArray {
            val table = leaf.copy(rows = java.util.Collections.nCopies(count, emptyList<Cell>()))
            val wire = Wire('Z', 512).apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = table)) } }
            return wire.document(emptyList(), Sink.Body)
        }
        val exact = checkNotNull(read(literal(rows)).sections.single().blocks.single().table)
        assertEquals(rows, exact.rows.size); assertTrue(exact.rows.all { it.isEmpty() })
        assertEquals(TableGrid(emptyList(), rows, 0), tableGrid(exact))
        assertEquals(listOf(source), exact.caption); assertEquals(style, exact.style)
        reject("Minimum shares exact item M plus one refusal", literal(rows + 1))
    }

    @Test fun staticParagraphAlignmentRepeatsOnlyItsOwnChildContainerThroughModelAndWire() {
        val source = Span("link", "Kept", "Target", targetFragment = "French", tooltip = "tip", explanation = "meaning")
        fun box(blocks: List<Block>, style: ContainerStyle) = Block("container", 0, emptyList(), container = Container(blocks, style))
        fun entry(root: Block) = Entry("Static", emptyList(), "language", "French", "fr", listOf(Section(2, "Body", listOf(root))), emptyList())
        for (alignment in listOf(CellTextAlign.Center, CellTextAlign.Right)) {
            val other = if (alignment == CellTextAlign.Center) CellTextAlign.Right else CellTextAlign.Center
            val paragraph = Block("paragraph", 0, listOf(source), textAlign = alignment)
            val childStyle = ContainerStyle(width = ContainerWidth.FitContent, textAlign = alignment,
                absoluteStatic = ContainerAbsoluteStaticPosition())
            val child = box(listOf(paragraph), childStyle)
            val parentStyle = ContainerStyle(positioning = ContainerPositioning.RelativeAuto, textAlign = other)
            val root = box(listOf(child), parentStyle)
            assertTrue(validContainerAbsoluteStaticBody(checkNotNull(child.container)))
            assertTrue(validSoleStaticInlineContainer(checkNotNull(root.container)))
            assertSame(source, child.container!!.blocks.single().spans.single())
            assertSame(root, entry(root).sections.single().blocks.single())
            val wire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(root, "aligned") } }
            val bytes = wire.document(emptyList(), Sink.Body)
            val decoded = read(bytes).sections.single().blocks.single()
            assertEquals(root, decoded)
            val actualChild = decoded.container!!.blocks.single().container!!
            assertEquals(alignment, actualChild.style.textAlign)
            assertEquals(alignment, actualChild.blocks.single().textAlign)
            assertEquals(listOf(source), actualChild.blocks.single().spans)
            invalid("Child alignment cannot disagree with paragraph") { Container(listOf(paragraph), childStyle.copy(textAlign = other)) }
            invalid("Child alignment cannot be supplied by parent") { Container(listOf(paragraph), childStyle.copy(textAlign = null)) }
            invalid("Alignment does not relax paragraph depth") { Container(listOf(paragraph.copy(depth = 1)), childStyle) }
            invalid("Matching paragraph does not relax immediate custody") { entry(child) }
            val nullParagraph = paragraph.copy(textAlign = null)
            for (ownAlignment in listOf(alignment, null)) {
                val inheritedChild = box(listOf(nullParagraph), childStyle.copy(textAlign = ownAlignment))
                val inheritedRoot = box(listOf(inheritedChild), parentStyle)
                val inheritedWire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(inheritedRoot) } }
                assertEquals(inheritedRoot, read(inheritedWire.document(emptyList(), Sink.Body)).sections.single().blocks.single())
            }
            reject("Literal paragraph mismatch", changed(bytes, wire.at.getValue("aligned.child0.child0.alignment.value"), other.ordinal))
            reject("Literal child mismatch", changed(bytes, wire.at.getValue("aligned.child0.style.textAlign"), other.ordinal))
            // Parent repeats the paragraph value, but deleting the child's own proof still must fail.
            val provedParent = root.copy(container = root.container!!.copy(style = parentStyle.copy(textAlign = alignment)))
            val parentWire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(provedParent, "parentProof") } }
            val parentBytes = parentWire.document(emptyList(), Sink.Body)
            val childKey = "parentProof.child0.style"
            val flags = 4L or 8192L // FitContent plus child text alignment; static remains in its separate extension.
            val withoutFlag = changed32(parentBytes, parentWire.at.getValue("$childKey.flags"), flags and 8192L.inv())
            val offset = parentWire.at.getValue("$childKey.textAlign")
            reject("Literal parent cannot lend child alignment", replace(withoutFlag, offset, offset + 1, byteArrayOf()))
            assertEquals(provedParent, read(parentBytes).sections.single().blocks.single())
        }
    }

    @Test fun columnExtension4096KeepsAutoCountCapZeroAndSourceGraphAcrossEveryContainerSink() {
        val gap = StyleLength(StyleLengthUnit.Em, 1.25f)
        val leaf = Span("link", "kept", "Target", targetFragment = "anchor", tooltip = "tip", explanation = "meaning",
            fontScale = 0.5f, fontScaleBasis = FontScaleBasis.NormalBody, bold = true)
        val owner = InlineFontSnapshot(fontScale = 1.5f, fontScaleBasis = FontScaleBasis.NormalBody, fontNormalized = true)
        for (count in listOf<Int?>(null, 1, 65535)) for (width in listOf(StyleLength(StyleLengthUnit.Px, 0f),
                StyleLength(StyleLengthUnit.Px, 3.25f), StyleLength(StyleLengthUnit.Em, 26f))) for (direction in listOf(null, BidiResolvedDirection.Ltr, BidiResolvedDirection.Rtl)) {
            val columns = ContainerColumns(count, gap, width, direction)
            val style = ContainerStyle(columns = columns, ownerFont = owner)
            val block = Block("container", 0, emptyList(), container = Container(listOf(Block("paragraph", 0, listOf(leaf))), style))
            assertSame(columns, style.copy(textAlign = CellTextAlign.Right).columns)
            assertSame(width, columns.width); assertSame(gap, columns.gap)
            assertEquals(count, columns.count); assertEquals(direction, columns.direction); assertEquals(1.5f, owner.fontScale)
            assertEquals(0.5f, leaf.fontScale); assertSame(leaf, block.container!!.blocks.single().spans.single())
            for (sink in listOf(Sink.Body, Sink.Container, Sink.CellBlocks, Sink.TableRichCaption, Sink.ReferenceBlocks,
                    Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)) {
                val wire = Wire('Z', 4097).apply { paragraphOverride = { positionedBlock(block, "columns") } }
                val bytes = wire.document(emptyList(), sink)
                assertArrayEquals(byteArrayOf(68, 80, 82, 90, 1, 16), bytes.copyOf(6))
                val decoded = read(bytes)
                val found = mutableListOf<Container>()
                val visitor = PresentationSpanVisitor { _, _ -> }.apply {
                    onContainer = { if (it.style.columns?.width != null) found.add(it) }
                }
                decoded.sections.forEach { visitor.blocks(it.blocks) }
                decoded.references.forEach { it.blocks?.let { blocks -> visitor.blocks(blocks) } }
                assertEquals(listOf(block.container), found)
                assertEquals(listOf(leaf), found.single().blocks.single().spans)
                if (sink == Sink.Body) assertEquals(Entry("Ruby", emptyList(), "language", "Japanese", "ja",
                    listOf(Section(2, "Body", listOf(block))), emptyList(), organization = PresentationOrganization(emptyList(), emptyList())), decoded)
            }
        }
        val columns = ContainerColumns(null, gap, StyleLength(StyleLengthUnit.Em, 26f))
        val style = ContainerStyle(columns = columns, textWrap = TextWrap.Normal)
        val block = Block("container", 0, emptyList(), container = Container(listOf(Block("paragraph", 0, listOf(leaf))), style))
        val wire = Wire('Z', 4352).apply { paragraphOverride = { positionedBlock(block, "mixed") } }
        val bytes = wire.document(emptyList(), Sink.Body)
        assertEquals(block, read(bytes).sections.single().blocks.single())
        assertEquals(wire.at.getValue("mixed.style.wrap") + 1, wire.at.getValue("mixed.style.columnExtension"))
        reject("Positioned debt remains independent", changed(bytes, 5, 16))
        reject("Width debt remains independent", changed(bytes, 5, 1))
        for (direction in BidiResolvedDirection.entries) {
            val directionOnly = block.copy(container = block.container!!.copy(style = ContainerStyle(columns = ContainerColumns(2, gap, direction = direction))))
            val directionWire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(directionOnly, "direction") } }
            val directionBytes = directionWire.document(emptyList(), Sink.Body)
            assertEquals(directionOnly, read(directionBytes).sections.single().blocks.single())
            assertEquals(2, directionBytes[directionWire.at.getValue("direction.style.columnExtension")].toInt())
            assertEquals(direction.ordinal, directionBytes[directionWire.at.getValue("direction.style.columnDirection")].toInt())
            assertNull(read(directionBytes).sections.single().blocks.single().container!!.style.columns!!.width)
            for (tag in listOf(2, 255)) reject("Invalid direction $tag", changed(directionBytes, directionWire.at.getValue("direction.style.columnDirection"), tag))
            val countAt = directionWire.at.getValue("direction.style.columnCount")
            reject("Direction alone cannot earn auto count", changed(changed(directionBytes, countAt, 0), countAt + 1, 0))
        }
        val empty = block.copy(container = Container(emptyList(), ContainerStyle(columns = columns)))
        val emptyWire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(empty) } }
        assertEquals(empty, read(emptyWire.document(emptyList(), Sink.Body)).sections.single().blocks.single())
    }

    @Test fun columnExtension4096RejectsMalformedTailAndDebtWhileFixedCountBytesStayExact() {
        val gap = StyleLength(StyleLengthUnit.Em, 1f)
        val fixed = ContainerStyle(columns = ContainerColumns(2, gap))
        val old = Wire('M').isolatedPositionedStyle(fixed)
        assertArrayEquals(byteArrayOf(0, 0, 4, 0, 2, 0, 1, 0, 0, -128, 63), old)
        assertArrayEquals(old, Wire('Z', 4096).isolatedPositionedStyle(fixed))
        val widthStyle = fixed.copy(columns = fixed.columns!!.copy(width = StyleLength(StyleLengthUnit.Px, 0f)))
        val new = Wire('Z', 4096).isolatedPositionedStyle(widthStyle)
        assertArrayEquals(byteArrayOf(0, 0, 4, 2), new.copyOf(4))
        assertArrayEquals(old.copyOfRange(4, old.size), new.copyOfRange(4, old.size))
        assertArrayEquals(byteArrayOf(1, 0, 0, 0, 0, 0), new.copyOfRange(old.size, new.size))
        invalid("Auto count requires width") { ContainerColumns(null, gap) }
        invalid("Direction does not supply an authored count or width") { ContainerColumns(null, gap, direction = BidiResolvedDirection.Rtl) }
        for (count in listOf(0, -1, 65536)) invalid("Invalid authored cap $count") { ContainerColumns(count, gap, StyleLength(StyleLengthUnit.Px, 0f)) }
        val block = Block("container", 0, emptyList(), container = Container(listOf(Block("paragraph", 0, listOf(text("kept")))), widthStyle))
        val wire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(block, "columns") } }
        val bytes = wire.document(emptyList(), Sink.Body)
        val key = "columns.style"
        for (flags in listOf(0, 127, 256, 512, 4096 or 128, 4096 or 1024, 4096 or 2048, 65535)) {
            reject("Width header $flags", bytes.copyOf().also { it[4] = flags.toByte(); it[5] = (flags ushr 8).toByte() })
        }
        reject("Width requires columns prefix", changed32(bytes, wire.at.getValue("$key.flags"), 0x02000000))
        reject("Unknown style bit", changed32(bytes, wire.at.getValue("$key.flags"), 0x06040000))
        for (mask in listOf(0, 4, 255)) reject("Invalid column extension mask $mask", changed(bytes, wire.at.getValue("$key.columnExtension"), mask))
        for (unit in listOf(2, 255)) reject("Width is not percent or unknown $unit", changed(bytes, wire.at.getValue("$key.columnWidth.unit"), unit))
        for (bad in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            invalid("Direct width $bad") { ContainerColumns(null, gap, StyleLength(StyleLengthUnit.Px, bad)) }
            reject("Literal width $bad", changed32(bytes, wire.at.getValue("$key.columnWidth.value"), bad.toRawBits().toLong()))
        }
        for (end in bytes.indices) reject("Truncated width $end", bytes.copyOf(end))
        reject("Trailing width bytes", bytes + byteArrayOf(0))
        reject("Width earns no unrelated P feature", changed(bytes, wire.at.getValue("features"), 32))
        val debt = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(block.copy(container = block.container!!.copy(style = fixed))) } }
        reject("Width flag requires actual width", debt.document(emptyList(), Sink.Body))
        val fixedZ = Wire('Z', 256).apply {
            paragraphOverride = { positionedBlock(block.copy(container = block.container!!.copy(style = fixed.copy(textWrap = TextWrap.Normal))), "fixed") }
        }
        val fixedBytes = fixedZ.document(emptyList(), Sink.Body)
        val countAt = fixedZ.at.getValue("fixed.style.columnCount")
        reject("Old count zero stays invalid", changed(changed(fixedBytes, countAt, 0), countAt + 1, 0))
        val autoBytes = changed(changed(bytes, wire.at.getValue("$key.columnCount"), 0), wire.at.getValue("$key.columnCount") + 1, 0)
        assertNull(read(autoBytes).sections.single().blocks.single().container!!.style.columns!!.count)
        for (style in listOf(ContainerStyle(height = StyleLength(StyleLengthUnit.Px, 1f)),
                ContainerStyle(minHeight = StyleLength(StyleLengthUnit.Px, 0f)), ContainerStyle(layout = ContainerLayout.FlexRow),
                ContainerStyle(overflow = ContainerOverflow.Auto), ContainerStyle(positioning = ContainerPositioning.RelativeAuto))) {
            invalid("Width keeps shared fragmentation guard $style") { style.copy(columns = widthStyle.columns) }
        }
        assertEquals(block, read(bytes).sections.single().blocks.single())
    }

    @Test fun columnExtension4096SharesOriginalDepthAndExactItemBudgetWithoutScalarOwners() {
        val source = Span("link", "budget", "Kept")
        val style = ContainerStyle(columns = ContainerColumns(null, StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Em, 26f)))
        for (depth in listOf(16, 17)) {
            val wire = Wire('Z', 4096).apply { containerStyleOverride = { positionedStyle(style, it) } }
            val bytes = wire.document(listOf(source), Sink.Container, containers = depth)
            if (depth == 17) reject("Width does not reset content depth", bytes) else {
                val found = mutableListOf<Span>()
                PresentationSpanVisitor { spans, _ -> found.addAll(spans) }.blocks(read(bytes).sections.single().blocks)
                assertEquals(listOf(source), found)
            }
        }
        for (depth in listOf(32, 33)) {
            var table = Table(listOf(source), emptyList())
            repeat(depth - 1) { table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = table)))) }
            val root = Block("container", 0, emptyList(), container = Container(listOf(Block("table", 0, emptyList(), table = table)), style))
            val wire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(root) } }
            val bytes = wire.document(emptyList(), Sink.Body)
            if (depth == 33) reject("Width does not reset table depth", bytes) else assertEquals(root, read(bytes).sections.single().blocks.single())
        }
        // Section1 + Container block1 + Table block1 + real caption Span1. Width/gap/count add no owner item.
        val rows = (1 shl 20) - 4
        fun literal(count: Int): ByteArray {
            val table = Table(listOf(source), java.util.Collections.nCopies(count, emptyList<Cell>()))
            val root = Block("container", 0, emptyList(), container = Container(listOf(Block("table", 0, emptyList(), table = table)), style))
            val wire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(root) } }
            return wire.document(emptyList(), Sink.Body)
        }
        val exact = checkNotNull(read(literal(rows)).sections.single().blocks.single().container)
        assertEquals(style, exact.style)
        val table = checkNotNull(exact.blocks.single().table)
        assertEquals(rows, table.rows.size); assertTrue(table.rows.all { it.isEmpty() })
        assertEquals(listOf(source), table.caption); assertEquals(TableGrid(emptyList(), rows, 0), tableGrid(table))
        reject("Width shares exact item M plus one refusal", literal(rows + 1))
    }

    @Test fun columnLayout4096RetainsPerBlockBreakPolicyAndRejectsBorrowedOwnersWithoutNewBudget() {
        val source = Span("link", "same original item", "Kept", targetFragment = "part", tooltip = "tip", explanation = "meaning")
        val kinds = listOf("paragraph", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term")
        for (kind in kinds) for (policy in ColumnBreakInside.entries) {
            val path = when (kind) { "list_item" -> "#"; "list_detail" -> "*:"; "indent" -> ":"; "term" -> ";"; else -> "" }
            val depth = if (kind == "paragraph") 0 else if (kind == "list_detail") 2 else 1
            val block = Block(kind, depth, listOf(source), listPath = path, number = if (kind == "list_item") "3" else "", columnBreakInside = policy)
            assertSame(source, block.spans.single()); assertEquals(policy, block.copy(textAlign = CellTextAlign.Right).columnBreakInside)
            for (sink in listOf(Sink.Body, Sink.Container, Sink.CellBlocks, Sink.TableRichCaption, Sink.ReferenceBlocks,
                    Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)) {
                val wire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(block, "policy") } }
                val bytes = wire.document(emptyList(), sink)
                assertArrayEquals(byteArrayOf(68, 80, 82, 90, 0, 16), bytes.copyOf(6))
                assertEquals(if (policy == ColumnBreakInside.Auto) 1 else 2, bytes[wire.at.getValue("policy.columnBreakInside")].toInt())
                val decoded = read(bytes)
                val found = mutableListOf<Block>()
                val visitor = PresentationSpanVisitor { _, _ -> }.apply { onBlock = { if (it.columnBreakInside != null) found.add(it) } }
                decoded.sections.forEach { visitor.blocks(it.blocks) }
                decoded.references.forEach { it.blocks?.let { blocks -> visitor.blocks(blocks) } }
                assertEquals(listOf(block), found); assertEquals(listOf(source), found.single().spans)
                if (sink == Sink.Body) {
                    assertEquals(Entry("Ruby", emptyList(), "language", "Japanese", "ja", listOf(Section(2, "Body", listOf(block))),
                        emptyList(), organization = PresentationOrganization(emptyList(), emptyList())), decoded)
                    for (tag in listOf(3, 255)) reject("Unknown break policy $tag", changed(bytes, wire.at.getValue("policy.columnBreakInside"), tag))
                    reject("4096 must have actual column layout", changed(bytes, wire.at.getValue("policy.columnBreakInside"), 0))
                    reject("Final block policy is mandatory in4096", replace(bytes, wire.at.getValue("policy.columnBreakInside"),
                        wire.at.getValue("policy.columnBreakInside") + 1, byteArrayOf()))
                }
            }
        }
        for (kind in listOf("blank", "heading", "preformatted", "rule", "table")) {
            invalid("Break policy kind $kind") { Block(kind, 0, emptyList(), columnBreakInside = ColumnBreakInside.Avoid) }
        }
        invalid("Break policy cannot lend itself to Container") {
            Block("container", 0, emptyList(), container = Container(emptyList()), columnBreakInside = ColumnBreakInside.Avoid)
        }
        invalid("Break policy cannot own a Table payload") {
            Block("paragraph", 0, emptyList(), table = Table(emptyList(), emptyList()), columnBreakInside = ColumnBreakInside.Auto)
        }
        invalid("Break policy cannot own a feature payload") {
            Block("paragraph", 0, emptyList(), feature = Feature("IPA", "ja", "x", "", ""), columnBreakInside = ColumnBreakInside.Auto)
        }
        invalid("Break policy cannot own anonymous flow") {
            Block("paragraph", 0, emptyList(), flow = emptyList(), columnBreakInside = ColumnBreakInside.Auto)
        }
        val paragraph = Block("paragraph", 0, listOf(source), columnBreakInside = ColumnBreakInside.Avoid)
        val nullBlock = paragraph.copy(columnBreakInside = null)
        val oldWire = Wire('V').apply { paragraphOverride = { positionedBlock(nullBlock, "plain") } }
        val oldBytes = oldWire.document(emptyList(), Sink.Body)
        val newWire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(paragraph, "policy") } }
        val newBytes = newWire.document(emptyList(), Sink.Body)
        val end = newWire.at.getValue("policy.columnBreakInside")
        assertArrayEquals(oldBytes, replace(newBytes.copyOfRange(0, 4).also { it[3] = 'V'.code.toByte() } +
            newBytes.copyOfRange(6, newBytes.size), end - 2, end - 1, byteArrayOf()))
        for (depth in listOf(16, 17)) {
            val wire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(paragraph) } }
            val bytes = wire.document(emptyList(), Sink.Container, containers = depth)
            if (depth == 17) reject("Break policy preserves content17 refusal", bytes) else {
                val found = mutableListOf<Block>()
                PresentationSpanVisitor { _, _ -> }.apply { onBlock = { if (it.columnBreakInside != null) found.add(it) } }
                    .blocks(read(bytes).sections.single().blocks)
                assertEquals(listOf(paragraph), found)
            }
        }
        // Section1 + Container block1 + policy paragraph1 + original Span1 + Table block1.
        val rows = (1 shl 20) - 5
        fun literal(count: Int): ByteArray {
            val table = Table(emptyList(), java.util.Collections.nCopies(count, emptyList<Cell>()))
            val root = Block("container", 0, emptyList(), container = Container(listOf(paragraph, Block("table", 0, emptyList(), table = table))))
            val wire = Wire('Z', 4096).apply { paragraphOverride = { positionedBlock(root) } }
            return wire.document(emptyList(), Sink.Body)
        }
        val exact = checkNotNull(read(literal(rows)).sections.single().blocks.single().container)
        assertEquals(paragraph, exact.blocks.first()); assertNull(exact.style.columns)
        assertEquals(rows, exact.blocks.last().table!!.rows.size)
        reject("Break policy has no extra scalar item at M plus one", literal(rows + 1))
    }


    @Test fun audioControl8192PreservesExactOccurrenceOwnersAndEveryExistingSpanSink() {
        val file = "Clip é.ogg"
        val token = "wikidict-media-file-436c697020c3a92e6f6767"
        val media = listOf(Media(file, "audio", "Original catalog caption"))
        val owner = Span("link", "Play", "File:$file", language = "eu", classes = "wikidict-media $token",
            role = "pronunciation", tooltip = "Original tip", explanation = "Original explanation",
            foreground = "#123456", fontScale = 1.25f, fontScaleBasis = FontScaleBasis.NormalBody,
            audioControl = AudioControl(StyleWidth(StyleWidthUnit.Px, 250f), StyleLength(StyleLengthUnit.Px, 30f),
                AudioControlFocusPaint(AudioControlFocusMode.UaAuto, FigureColor.Rgb("#ff0000"))))
        for (sink in Sink.entries) {
            val wire = Wire('Z', 8192)
            val entry = read(wire.document(listOf(owner), sink, headingTitle = "Play", mediaValues = media))
            assertEquals(sink.name, owner, selected(entry, sink))
            assertEquals(media, entry.media)
            assertEquals(EntryLink("File:$file"), selected(entry, sink).entryLink())
            assertEquals("Play", selected(entry, sink).text)
            assertEquals("", selected(entry, sink).trail)
            assertTrue(entry.inlineImages.isEmpty())
        }
        val prefixTable = Table(listOf(text("Visible caption")), emptyList())
        val mixedBlock = Block("table", 0, listOf(owner), table = prefixTable)
        val raw = mutableListOf<Span>(); val displayed = mutableListOf<Span>()
        PresentationSpanVisitor { spans, _ -> displayed.addAll(spans) }.apply { onSpan = { raw.add(it) } }
            .blocks(listOf(mixedBlock))
        assertSame(owner, raw.first())
        assertEquals(listOf(owner) + prefixTable.caption, raw)
        assertEquals(prefixTable.caption, displayed)
        val prefixWire = Wire('Z', 8192).apply { paragraphOverride = { audioPrefixTable(prefixTable) } }
        val decodedPrefix = read(prefixWire.document(listOf(owner), Sink.Body, mediaValues = media))
            .sections.single().blocks.single()
        assertEquals(mixedBlock, decodedPrefix)
        assertEquals(EntryLink("File:$file"), decodedPrefix.spans.single().entryLink())
        val automatic = owner.copy(text = "", audioControl = AudioControl())
        val none = owner.copy(text = "Second", audioControl = AudioControl(StyleWidth(StyleWidthUnit.Percent, 50f),
            StyleLength(StyleLengthUnit.Em, 1.5f), AudioControlFocusPaint(AudioControlFocusMode.AuthoredNone)))
        val transparent = owner.copy(audioControl = AudioControl(focus = AudioControlFocusPaint(
            AudioControlFocusMode.UaAuto, FigureColor.Transparent)))
        val defaultFocus = owner.copy(audioControl = AudioControl(width = StyleWidth(StyleWidthUnit.Em, 2f),
            focus = AudioControlFocusPaint(AudioControlFocusMode.UaAuto)))
        val values = listOf(owner, automatic, none, transparent, defaultFocus, owner)
        val wire = Wire('Z', 8192)
        val entry = read(wire.document(values, mediaValues = media))
        assertEquals(values, entry.displayTitle)
        assertEquals(6, entry.displayTitle.count { it.audioControl != null })
        assertEquals("", entry.displayTitle[1].text)
        assertEquals(AudioControl(), entry.displayTitle[1].audioControl)
        assertNotSame(entry.displayTitle.first(), entry.displayTitle.last())
        assertSame(owner.audioControl, owner.copy(tooltip = "Changed tip only").audioControl)
        assertArrayEquals(byteArrayOf(1, 0), Wire('Z', 8192).isolatedAudioTail(automatic))
        assertArrayEquals(byteArrayOf(1, 4, 0, 0), Wire('Z', 8192).isolatedAudioTail(none.copy(audioControl = AudioControl(
            focus = AudioControlFocusPaint(AudioControlFocusMode.AuthoredNone)))))
        val direct = Entry("Audio", values, "language", "Basque", "eu", emptyList(), emptyList(), media = media)
        assertSame(owner, direct.displayTitle.first()); assertSame(owner, direct.displayTitle.last())
        assertSame(media.single(), direct.media.single())
        val marker = Span("link", "[1]", targetFragment = "reference-9", role = "reference",
            citationMarker = CitationMarker(9, 7, "audio-return"))
        val backlink = ReferenceBacklink.withPolicies(7, Span("link", "return", targetFragment = "audio-return"))
        val note = Reference(9, 1, "", emptyList(), backlinks = listOf(backlink))
        val mixed = Wire('Z', 8192 or 64)
        val mixedBytes = mixed.document(listOf(marker, owner), referenceValues = listOf(note), mediaValues = media)
        val decodedMixed = read(mixedBytes)
        assertEquals(listOf(marker, owner), decodedMixed.displayTitle)
        assertEquals(listOf(note), decodedMixed.references)
        assertEquals(mixed.at.getValue("root.0.end") - 1, mixed.at.getValue("root.0.audio"))
        assertEquals(mixed.at.getValue("root.1.citation") + 1, mixed.at.getValue("root.1.audio"))
        assertEquals(0, mixedBytes[mixed.at.getValue("backlinks.0.0.span.audio")].toInt())
    }

    @Test fun audioControl8192RejectsForgedOwnershipCatalogAndNoncanonicalWireWithoutChangingLegacyBytes() {
        val file = "Tone.ogg"
        val token = "wikidict-media-file-546f6e652e6f6767"
        val catalog = listOf(Media(file, "audio", "Tone"))
        val control = AudioControl(StyleWidth(StyleWidthUnit.Px, 250f), StyleLength(StyleLengthUnit.Em, 1.5f),
            AudioControlFocusPaint(AudioControlFocusMode.UaAuto, FigureColor.Rgb("#ff0000")))
        val owner = Span("link", "Play", "File:$file", classes = "wikidict-media $token", audioControl = control)
        val vtOwner = owner.copy(classes = "wikidict-media\u000b$token")
        assertEquals(vtOwner, read(Wire('Z', 8192).document(listOf(vtOwner), mediaValues = catalog)).displayTitle.single())
        assertFalse(validRubyChild(vtOwner))
        invalid("AUDIO cannot escape the Ruby child domain through VT") { this.owner(listOf(base(vtOwner))) }
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val one = StyleLength(StyleLengthUnit.Px, 1f)
        invalid("AUDIO cannot escape the padding child domain through VT") { InlinePaddingGroup(one, zero, listOf(vtOwner)) }
        invalid("AUDIO cannot escape the action child domain through VT") { InlineActionGroup(listOf(vtOwner)) }
        invalid("AUDIO cannot escape the box child domain through VT") {
            val none = InlineBoxBorderEdge.None
            InlineBoxGroup(StyleEdges(zero, zero, zero, zero), InlineBoxBorderEdges(none, none, none, none), spans = listOf(vtOwner))
        }
        val plainGroup = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(one, zero, listOf(text("child"))))
        val nestedWire = Wire('Z', 8192)
        val nestedBytes = nestedWire.document(listOf(plainGroup), mediaValues = catalog)
        reject("Literal nested AUDIO VT owner", replace(nestedBytes, nestedWire.at.getValue("root.0.padding.body.0.start"),
            nestedWire.at.getValue("root.0.padding.body.0.end"), Wire('Z', 8192).isolatedSpan(vtOwner)))
        val legacy = owner.copy(audioControl = null)
        val old = Wire('V').isolatedSpan(legacy)
        assertArrayEquals(old, Wire('Z', 4096).isolatedSpan(legacy))
        assertArrayEquals(old + byteArrayOf(0), Wire('Z', 8192).isolatedSpan(legacy))
        assertEquals(legacy, read(Wire('O').document(listOf(legacy), mediaValues = catalog)).displayTitle.single())
        val wire = Wire('Z', 8192); val bytes = wire.document(listOf(owner), mediaValues = catalog)
        val audio = wire.at.getValue("root.0.audio")
        val payload = bytes.copyOfRange(audio, wire.at.getValue("root.0.end"))
        val wrongOwners = listOf(
            legacy.copy(kind = "text", target = ""), legacy.copy(kind = "external_link", target = "https://example.test/Tone.ogg"),
            legacy.copy(target = "File:Other.ogg"), legacy.copy(target = "File:Tone_ogg"), legacy.copy(target = "Tone.ogg"),
            legacy.copy(classes = token), legacy.copy(classes = "wikidict-media"), legacy.copy(classes = "wikidict-media $token $token"),
            legacy.copy(classes = "wikidict-media $token wikidict-media-file-00"),
            legacy.copy(classes = "wikidict-media wikidict-media-file-546F6E652E6F6767"),
            legacy.copy(trail = "suffix"), legacy.copy(targetFragment = "fragment"),
            legacy.copy(text = "", image = InlineImage("Image.png")),
            legacy.copy(fontScale = Float.NaN), legacy.copy(foreground = "bad"))
        for ((index, invalidOwner) in wrongOwners.withIndex()) {
            invalid("Audio owner $index") { invalidOwner.copy(audioControl = control) }
            // The plain legacy constructor does not confer AUDIO authority; splice only the actual policy tail.
            val plain = Wire('Z', 8192).isolatedSpan(invalidOwner)
            reject("Forged audio owner $index", replace(bytes, wire.at.getValue("root.0.start"),
                wire.at.getValue("root.0.end"), plain.dropLast(1).toByteArray() + payload))
        }
        val group = Span("link", "", "File:$file", classes = "", inlineActionGroup = InlineActionGroup(listOf(text("child"))))
        invalid("AUDIO cannot borrow an inline action owner") { group.copy(classes = owner.classes, audioControl = control) }
        invalid("AUDIO cannot borrow a Ruby owner") { simple().copy(audioControl = control) }
        invalid("AUDIO ordinary strings remain valid UTF-16") { owner.copy(language = "\ud800") }
        val state = LinkState("#0000ff", false)
        val paint = LinkPaint(state, state, state, state, state, state, state, state, false)
        invalid("AUDIO does not carry ordinary link paint") { owner.copy(linkPaint = paint) }
        invalid("Empty AUDIO does not relax ordinary inline style") { owner.copy(text = "", inlineStyle = InlineTextStyle(wrap = TextWrap.BreakWord)) }
        for (media in listOf(emptyList(), listOf(Media(file, "image", "Wrong kind")), catalog + catalog,
            catalog + Media(file, "image", "Ambiguous"), listOf(Media("tone.ogg", "audio", "Wrong case")))) {
            invalid("Unique exact audio catalog") { Entry("Audio", listOf(owner), "language", null, "eu", emptyList(), emptyList(), media = media) }
            reject("Literal unique audio catalog", Wire('Z', 8192).document(listOf(owner), mediaValues = media))
            val prefix = Block("table", 0, listOf(owner), table = Table(emptyList(), emptyList()))
            invalid("Ignored prefix still requires exact audio catalog") {
                Entry("Audio", emptyList(), "language", null, "eu", listOf(Section(2, "Body", listOf(prefix))), emptyList(), media = media)
            }
            reject("Literal ignored prefix still requires exact audio catalog", Wire('Z', 8192).apply {
                paragraphOverride = { audioPrefixTable(checkNotNull(prefix.table)) }
            }.document(listOf(owner), Sink.Body, mediaValues = media))
        }
        for (bad in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            invalid("Audio width $bad") { AudioControl(width = StyleWidth(StyleWidthUnit.Px, bad)) }
            invalid("Audio height $bad") { AudioControl(height = StyleLength(StyleLengthUnit.Px, bad)) }
            reject("Literal audio width $bad", changed32(bytes, wire.at.getValue("root.0.audio.width.value"), bad.toRawBits().toLong()))
            reject("Literal audio height $bad", changed32(bytes, wire.at.getValue("root.0.audio.height.value"), bad.toRawBits().toLong()))
        }
        for (color in listOf(FigureColor.Transparent, FigureColor.Rgb("#ff0000"), FigureColor.NativeTheme))
            invalid("Authored none has no color") { AudioControlFocusPaint(AudioControlFocusMode.AuthoredNone, color) }
        invalid("UA color cannot borrow table native-theme authority") { AudioControlFocusPaint(AudioControlFocusMode.UaAuto, FigureColor.NativeTheme) }
        for (value in listOf(2, 255)) reject("Noncanonical audio presence", changed(bytes, audio, value))
        for (value in listOf(8, 255)) reject("Unknown audio fields", changed(bytes, wire.at.getValue("root.0.audio.fields"), value))
        for (value in listOf(3, 255)) reject("Unknown audio width unit", changed(bytes, wire.at.getValue("root.0.audio.width.unit"), value))
        for (value in listOf(2, 255)) {
            reject("Unknown audio height unit", changed(bytes, wire.at.getValue("root.0.audio.height.unit"), value))
            reject("Unknown audio focus mode", changed(bytes, wire.at.getValue("root.0.audio.focus.mode"), value))
            reject("Noncanonical audio color presence", changed(bytes, wire.at.getValue("root.0.audio.focus.presence"), value))
        }
        reject("Native theme is not audio source color", changed(bytes, wire.at.getValue("root.0.audio.focus.color"), 0))
        reject("Unknown audio color", changed(bytes, wire.at.getValue("root.0.audio.focus.color"), 3))
        reject("None cannot retain RGB", changed(bytes, wire.at.getValue("root.0.audio.focus.mode"), 0))
        val rgb = wire.at.getValue("root.0.audio.focus.rgb.bytes")
        reject("Noncanonical RGB", changed(bytes, rgb + 1, 'F'.code))
        for (end in audio until wire.at.getValue("root.0.end")) reject("Truncated audio field $end", bytes.copyOf(end))
        reject("Trailing byte", bytes + byteArrayOf(0))
        reject("Missing AUDIO census", Wire('Z', 8192).document(listOf(legacy), mediaValues = catalog))
        for (flags in listOf(0, 127, 4096, 8192 or 128, 8192 or 1024, 8192 or 2048, 65535))
            reject("Unknown or unearned audio header $flags", bytes.copyOf().also { it[4] = flags.toByte(); it[5] = (flags ushr 8).toByte() })
        for (header in listOf('V', 'Y', 'W', 'X')) reject("Audio cannot use old header $header", changed(bytes, 3, header.code))
    }

    @Test fun audioControl8192ChargesEachPolicyOnceWithoutResettingSharedDepthOrItemLimits() {
        val file = "Tone.ogg"
        val owner = Span("link", "Play", "File:$file", classes = "wikidict-media wikidict-media-file-546f6e652e6f6767",
            audioControl = AudioControl())
        val catalog = listOf(Media(file, "audio", "Tone"))
        for (focus in listOf(false, true)) {
            val source = if (focus) owner.copy(audioControl = AudioControl(focus = AudioControlFocusPaint(AudioControlFocusMode.UaAuto))) else owner
            val perSpan = if (focus) 3 else 2
            val modelRows = (1 shl 20) - perSpan
            fun table(count: Int) = Table(listOf(source), java.util.Collections.nCopies(count, emptyList<Cell>()))
            var encountered: Span? = null
            PresentationSpanVisitor { _, _ -> }.apply { onSpan = { encountered = it } }.table(table(modelRows))
            assertSame(source, encountered)
            invalid("AUDIO shares model M+1") { PresentationSpanVisitor { _, _ -> }.table(table(modelRows + 1)) }
            // Decoder additionally counts Section, Table Block and one Media catalog record.
            val decoderRows = (1 shl 20) - perSpan - 3
            fun literal(rows: Int): ByteArray = Wire('Z', 8192).apply {
                paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = table(rows)), "audioBudget") }
            }.document(emptyList(), Sink.Body, mediaValues = catalog)
            val decoded = read(literal(decoderRows)).sections.single().blocks.single().table!!
            assertEquals(decoderRows, decoded.rows.size)
            assertEquals(listOf(source), decoded.caption)
            assertTrue(decoded.rows.all { it.isEmpty() })
            reject("AUDIO shares decoder M+1", literal(decoderRows + 1))
            // The legacy non-inline Table prefix has no display callback, but its serialized policy counts once.
            fun prefix(count: Int) = Block("table", 0, listOf(source), table = Table(emptyList(),
                java.util.Collections.nCopies(count, emptyList<Cell>())))
            var prefixOwner: Span? = null
            PresentationSpanVisitor { spans, _ -> assertTrue(spans.isEmpty()) }.apply { onSpan = { prefixOwner = it } }
                .blocks(listOf(prefix((1 shl 20) - perSpan - 1)))
            assertSame(source, prefixOwner)
            invalid("Ignored AUDIO prefix shares model M+1") {
                PresentationSpanVisitor { _, _ -> }.blocks(listOf(prefix((1 shl 20) - perSpan)))
            }
            fun prefixLiteral(rows: Int): ByteArray = Wire('Z', 8192).apply {
                paragraphOverride = { audioPrefixTable(checkNotNull(prefix(rows).table)) }
            }.document(listOf(source), Sink.Body, mediaValues = catalog)
            val decodedPrefix = read(prefixLiteral(decoderRows)).sections.single().blocks.single()
            assertEquals(listOf(source), decodedPrefix.spans)
            assertEquals(decoderRows, checkNotNull(decodedPrefix.table).rows.size)
            reject("Ignored AUDIO prefix shares decoder M+1", prefixLiteral(decoderRows + 1))
        }
        for (depth in listOf(16, 17)) {
            val bytes = Wire('Z', 8192).document(listOf(owner), Sink.Container, containers = depth, mediaValues = catalog)
            if (depth == 17) reject("Audio does not reset content depth", bytes)
            else assertNotNull(read(bytes).sections.single().blocks.single().container)
        }
        for (depth in listOf(32, 33)) {
            val wire = Wire('Z', 8192).apply { paragraphOverride = { tableChain(depth, mixed = true) } }
            val bytes = wire.document(listOf(owner), Sink.Body, mediaValues = catalog)
            if (depth == 33) reject("Audio does not reset table depth", bytes)
            else {
                val found = mutableListOf<Span>()
                val visitor = PresentationSpanVisitor { _, _ -> }.apply { onSpan = { if (it.audioControl != null) found.add(it) } }
                read(bytes).sections.forEach { visitor.blocks(it.blocks) }
                assertEquals(listOf(owner), found)
            }
        }
    }

    @Test fun clippedAbsoluteRetainsAuthoredGeometryOriginalTextActionsAndAnnotationsAcrossAllSinks() {
        // Synthetic typed policy: this does not qualify the Hungarian producer or native paint.
        val px = StyleLengthUnit.Px
        val minus = ContainerMargin.Length(SignedContainerMargin(px, -1f))
        val child = Span("link", "time", "Time", trail = " ", targetFragment = "peak", tooltip = "Child tip",
            explanation = "Child explanation", language = "hu", italic = true)
        val external = Span("external_link", "to peak", "https://example.test/peak", trail = " ", bold = true)
        val children = listOf(text("Tooltip "), child, external, text("concentrations"))
        val group = ClippedAbsoluteInline(StyleLength(px, 1f), StyleLength(px, 1f),
            ContainerMargins(minus, minus, minus, minus), children, staticParentDirection = BidiResolvedDirection.Rtl)
        val source = Span("text", "", language = "hu", direction = "rtl", fontScale = 1.35f, tooltip = "Owner tip",
            explanation = "Owner explanation", inlineStyle = InlineTextStyle(cursor = InlineCursor.Help, wrap = TextWrap.BreakWord),
            clippedAbsolute = group)
        val label = "Tooltip time to peak concentrations"
        val visited = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { visited.add(it) } }.spans(listOf(source))
        assertEquals(5, visited.size)
        assertSame(source, visited.first())
        children.forEachIndexed { index, span -> assertSame(span, visited[index + 1]) }
        assertSame(group, source.clippedAbsolute)
        assertSame(children, group.children)
        assertEquals(label, textOf(listOf(source)))
        assertEquals("before ${label} after", textOf(listOf(text("before "), source, text(" after"))))
        for (sink in Sink.entries) {
            val wire = Wire('Y', 128)
            val entry = read(wire.document(listOf(source), sink, features = 16, headingTitle = label))
            val decoded = selected(entry, sink)
            assertEquals(sink.name, source, decoded)
            assertEquals("rtl", decoded.direction) // Explicit clipped-owner bidi agrees with its separate parent field.
            assertEquals(BidiResolvedDirection.Rtl, decoded.clippedAbsolute!!.staticParentDirection)
            assertEquals(label, textOf(listOf(decoded)))
            assertEquals(EntryLink("Time", "peak"), decoded.clippedAbsolute!!.children[1].entryLink())
            assertEquals(external, decoded.clippedAbsolute!!.children[2])
            assertTrue(entry.abbreviations.any { it.label == label && it.explanation == "Owner explanation" })
            assertTrue(entry.abbreviations.any { it.label == "time " && it.explanation == "Child explanation" })
            assertTrue(entry.textDetails.any { it.kind == TextDetailKind.Advisory && it.label == label && it.description == "Owner tip" })
            assertTrue(entry.textDetails.any { it.kind == TextDetailKind.Advisory && it.label == "time " && it.description == "Child tip" })
        }
        val state = LinkState("#123456", false)
        val paint = LinkPaint(state, state, state, state, state, state, state, state, false)
        val leaf = Span("text", "owned", foreground = "#123456", fontScale = 0.5f)
        val action = Span("link", "", "Whole owner", targetFragment = "owned", foreground = "#123456", linkPaint = paint,
            clippedAbsolute = group.copy(children = listOf(leaf)))
        val actionEntry = read(Wire('Y', 128).document(listOf(action)))
        assertEquals(action, actionEntry.displayTitle.single())
        assertSame(leaf, action.clippedAbsolute!!.children.single())
        assertEquals(EntryLink("Whole owner", "owned"), actionEntry.displayTitle.single().entryLink())
        assertEquals("text", actionEntry.displayTitle.single().clippedAbsolute!!.children.single().kind)
        assertEquals(0.5f, actionEntry.displayTitle.single().clippedAbsolute!!.children.single().fontScale)
        val emptyMetric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx))))
        assertEquals(listOf(emptyMetric, text(" ")), group.copy(children = listOf(emptyMetric, text(" "))).children)
        assertEquals("citation", group.copy(children = listOf(Span("text", "source", role = "citation"))).children.single().role)

        val zero = StyleLength(px, 0f)
        val borders = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val box = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), borders,
            emptyList(), listOf(text("box"))))
        val image = Span("text", "", image = InlineImage("Probe.svg", 120,
            occurrenceLayout = InlineImageOccurrenceLayout(zero, zero, zero, zero)))
        val font = InlineFontSnapshot(fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontNormalized = true, fontFamily = ContainerFontFamily.SansSerif)
        val body = BodyTypography(font, direction = BidiResolvedDirection.Rtl)
        val reference = Reference(1, 1, "kept", listOf(source), bodyTypography = body)
        val complete = Wire('Y', 191).apply { containerStyleOverride = { containerOwnerStyle(font, label = it) } }
        val bytes = complete.document(listOf(box, source, image), Sink.Container, features = 20,
            bodyTypography = body, referenceValues = listOf(reference), mediaValues = listOf(Media("Probe.svg", "image", "Original media")))
        val entry = read(bytes)
        val container = entry.sections.single().blocks.single().container!!
        assertEquals(font, container.style.ownerFont)
        assertEquals(listOf(box, source, image), container.blocks.single().spans)
        assertEquals(listOf(reference), entry.references)
        assertEquals(body, entry.bodyTypography)
        assertEquals(listOf(image.image), entry.inlineImages)
        reject("Clipped union preserves pending family census", changed(bytes, complete.at.getValue("features"), 16))


        // Current Z joins keep citation and AUDIO in their existing positions, then append Clipped.
        val marker = Span("link", "[1]", targetFragment = "reference-9", role = "reference",
            citationMarker = CitationMarker(9, 7, "clip-return"))
        val backlink = ReferenceBacklink.withPolicies(7, Span("link", "return", targetFragment = "clip-return"))
        val note = Reference(9, 1, "", emptyList(), backlinks = listOf(backlink))
        val audio = Span("link", "Audio", "File:Tone.ogg",
            classes = "wikidict-media wikidict-media-file-546f6e652e6f6767", audioControl = AudioControl())
        val clipped = Span("text", "", clippedAbsolute = group)
        val paragraph = Block("paragraph", 0, listOf(marker, clipped, audio), columnBreakInside = ColumnBreakInside.Avoid)
        val minimum = Table(emptyList(), emptyList(), style = TableStyle(minWidth = StyleWidth(StyleWidthUnit.Px, 7f)))
        fun root(block: Block) = Block("container", 0, emptyList(), container = Container(listOf(block,
            Block("table", 0, emptyList(), table = minimum)), ContainerStyle(textWrap = TextWrap.Normal)))
        val flags = 128 or 64 or 256 or 512 or 4096 or 8192
        val catalog = listOf(Media("Tone.ogg", "audio", ""))
        val mixed = Wire('Z', flags).apply { paragraphOverride = { positionedBlock(root(paragraph), "clipMixed") } }
        val mixedBytes = mixed.document(emptyList(), Sink.Body, referenceValues = listOf(note), mediaValues = catalog)
        val mixedEntry = read(mixedBytes)
        assertEquals(root(paragraph), mixedEntry.sections.single().blocks.single())
        assertEquals(listOf(note), mixedEntry.references)
        assertEquals(catalog, mixedEntry.media)
        assertSame(clipped, paragraph.spans[1])
        assertSame(group, clipped.clippedAbsolute)
        val audioPath = "clipMixed.child0.spans.2"
        val citationAt = mixed.at.getValue("$audioPath.citation")
        val audioAt = mixed.at.getValue("$audioPath.audio")
        val clippedAt = mixed.at.getValue("$audioPath.clipped")
        assertEquals(citationAt + 1, audioAt)
        assertEquals(audioAt + 2, clippedAt)
        assertArrayEquals(byteArrayOf(0, 1, 0, 0), mixedBytes.copyOfRange(citationAt, clippedAt + 1))
        val backlinkPath = "backlinks.0.0.span"
        assertEquals(mixed.at.getValue("$backlinkPath.audio") + 1, mixed.at.getValue("$backlinkPath.clipped"))
        reject("Mixed clipped tail cannot be omitted", replace(mixedBytes, clippedAt, clippedAt + 1, byteArrayOf()))
        reject("Mixed clipped owner cannot lose flag128", changed(mixedBytes, mixed.at.getValue("yFeatures"), flags and 127))
        val missingOwner = paragraph.copy(spans = listOf(marker, text("ordinary"), audio))
        reject("Mixed actual clipped census is independent", Wire('Z', flags).apply {
            paragraphOverride = { positionedBlock(root(missingOwner), "missingClipped") }
        }.document(emptyList(), Sink.Body, referenceValues = listOf(note), mediaValues = catalog))

        // Independent common-core literal: all-auto AUDIO followed by absent Clipped is exactly [1,0,0].
        val audioClip = Wire('Z', 8192 or 128)
        val isolated = audioClip.isolatedSpan(audio)
        assertArrayEquals(byteArrayOf(1, 0, 0), isolated.takeLast(3).toByteArray())
        assertArrayEquals(Wire('Z', 8192).isolatedSpan(audio) + byteArrayOf(0), isolated)
        val pair = Wire('Z', 8192 or 128)
        val pairBytes = pair.document(listOf(audio, clipped), mediaValues = catalog)
        assertEquals(listOf(audio, clipped), read(pairBytes).displayTitle)
        val pairTail = pair.at.getValue("root.0.audio")
        reject("Reversed common AUDIO-Clipped framing", replace(pairBytes, pairTail, pairTail + 3, byteArrayOf(0, 1, 0)))
    }

    @Test fun clippedAbsoluteRejectsMalformedOwnersNestedPayloadsAndWireWithoutChangingLegacyBytes() {
        val px = StyleLengthUnit.Px
        val zero = StyleLength(px, 0f)
        val minus = ContainerMargin.Length(SignedContainerMargin(px, -1f))
        val margin = ContainerMargins(minus, minus, minus, minus)
        val group = ClippedAbsoluteInline(zero, zero, margin, listOf(text("x")), staticParentDirection = BidiResolvedDirection.Rtl)
        val source = Span("text", "", clippedAbsolute = group)
        val wire = Wire('Y', 128)
        val bytes = wire.document(listOf(source))
        assertEquals(source, read(bytes).displayTitle.single())
        assertNotNull(read(bytes).displayTitle.single().clippedAbsolute)
        val present = wire.at.getValue("root.0.clipped")
        val direction = wire.at.getValue("root.0.clipped.staticParentDirection")
        val start = wire.at.getValue("root.0.clipped.width")
        val count = wire.at.getValue("root.0.clipped.children.count")
        assertEquals(30, count - start)
        assertEquals(35, count + 4 - (present + 1)) // Required direction plus the existing minimum body.
        assertEquals(present + 1, direction)
        assertEquals(direction + 1, start)
        assertEquals(2, bytes[direction].toInt())
        assertEquals(1, bytes[present].toInt())
        for (tag in listOf(0, 3, 255)) reject("Required static-parent direction tag $tag", changed(bytes, direction, tag))
        reject("Unpublished old clipped payload has no direction", replace(bytes, direction, direction + 1, byteArrayOf()))
        val ltr = source.copy(clippedAbsolute = group.copy(staticParentDirection = BidiResolvedDirection.Ltr))
        val ltrWire = Wire('Y', 128)
        val ltrBytes = ltrWire.document(listOf(ltr))
        assertEquals(1, ltrBytes[ltrWire.at.getValue("root.0.clipped.staticParentDirection")].toInt())
        assertEquals(ltr, read(ltrBytes).displayTitle.single())
        assertEquals(BidiResolvedDirection.Rtl, source.clippedAbsolute!!.staticParentDirection)
        assertSame(group, source.clippedAbsolute)
        invalid("Explicit owner direction cannot contradict static parent") { source.copy(direction = "ltr") }
        invalid("Clipped owner direction cannot remain auto") { source.copy(direction = "auto") }
        val matching = source.copy(direction = "rtl")
        val matchingWire = Wire('Y', 128)
        val matchingBytes = matchingWire.document(listOf(matching))
        assertEquals(matching, read(matchingBytes).displayTitle.single())
        val directionText = matchingWire.at.getValue("root.0.direction.bytes")
        reject("Forged clipped owner direction conflict", replace(matchingBytes, directionText, directionText + 3, "ltr".encodeToByteArray()))
        val autoOwner = replace(matchingBytes, directionText, directionText + 3, "auto".encodeToByteArray())
        reject("Forged unresolved clipped owner direction", changed32(autoOwner, matchingWire.at.getValue("root.0.direction"), 4))
        val ordinaryAuto = Span("text", "ordinary", direction = "auto")
        assertEquals(listOf(ordinaryAuto, source), read(Wire('Y', 128).document(listOf(ordinaryAuto, source))).displayTitle)
        reject("Strict clipped presence", changed(bytes, present, 2))
        reject("No zero capability mask", changed(bytes, wire.at.getValue("yFeatures"), 0))
        for (flags in listOf(64, 192, 255)) reject("Forged capability tails or census $flags", changed(bytes, wire.at.getValue("yFeatures"), flags))
        for (field in listOf("width", "height", "top", "right", "bottom", "left")) {
            val at = wire.at.getValue("root.0.clipped.$field")
            reject("Unknown $field unit", changed(bytes, at, 2))
            for (invalid in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
                reject("Nonfinite $field", changed32(bytes, at + 1, invalid.toRawBits().toLong() and 0xffff_ffffL))
        }
        for (field in listOf("width", "height")) reject("Negative $field", changed32(bytes,
            wire.at.getValue("root.0.clipped.$field") + 1, (-1f).toRawBits().toLong() and 0xffff_ffffL))
        reject("Empty child array", changed32(bytes, count, 0))
        reject("Impossible child count", changed32(bytes, count, 0xffff_ffffL))
        for (size in present until bytes.size) reject("Truncated clipped payload $size", bytes.copyOf(size))
        reject("Clipped trailing byte", bytes + byteArrayOf(0))
        reject("Flag128 requires an actual owner", Wire('Y', 128).document(listOf(text("ordinary"))))
        val plain = text("ordinary")
        val nullable = Wire('Y', 128)
        val nullableSpan = nullable.isolatedSpan(plain)
        val oldSpan = Wire('V').isolatedSpan(plain)
        assertArrayEquals(oldSpan + byteArrayOf(0), nullableSpan)
        assertEquals(oldSpan.size, nullable.at.getValue("isolated.clipped"))
        val body = BodyTypography(InlineFontSnapshot(fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody, fontNormalized = true))
        val oldY = Wire('Y', 2).document(listOf(plain), bodyTypography = body)
        val flagged = Wire('Y', 130)
        val flaggedBytes = flagged.document(listOf(plain), bodyTypography = body)
        val removed = replace(flaggedBytes, flagged.at.getValue("root.0.clipped"), flagged.at.getValue("root.0.clipped") + 1, byteArrayOf())
        assertArrayEquals(oldY, changed(removed, flagged.at.getValue("yFeatures"), 2))
        val withOwner = Wire('Y', 130)
        reject("Payload cannot lose its capability", changed(withOwner.document(listOf(source), bodyTypography = body),
            withOwner.at.getValue("yFeatures"), 2))
        for (version in listOf('W', 'X', 'Z')) reject("Unsupported or wrong-width header $version", changed(bytes, 3, version.code))
        invalid("Auto margin has no definite static box") { group.copy(margin = margin.copy(left = ContainerMargin.Auto)) }
        invalid("Negative width") { group.copy(width = StyleLength(px, -1f)) }
        invalid("Nonfinite margin") { group.copy(margin = margin.copy(top = ContainerMargin.Length(SignedContainerMargin(px, Float.NaN)))) }
        invalid("Empty clipped body") { group.copy(children = emptyList()) }
        invalid("Metric-only clipped body") { group.copy(children = listOf(Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx)))))) }
        invalid("Clipped owner has no own text") { source.copy(text = "own") }
        invalid("Clipped owner has no own trail") { source.copy(trail = "own") }
        invalid("Clipped owner cannot also be Ruby") { source.copy(ruby = simple().ruby) }
        invalid("Text owner cannot hide an action target") { source.copy(target = "Target") }
        invalid("Action owner needs target") { source.copy(kind = "link") }
        val forbidden = listOf(Span("line_break", ""), Span("text", "x", classes = "wikidict-media"),
            Span("text", "", image = InlineImage("Probe.svg")), simple(), source,
            Span("text", "", inlinePaddingGroup = InlinePaddingGroup(StyleLength(px, 1f), zero, listOf(text("x")))),
            Span("link", "", "Action", inlineActionGroup = InlineActionGroup(listOf(text("x")))))
        for (child in forbidden) invalid("Unsupported child ${child.kind}/${child.classes}") { group.copy(children = listOf(child)) }
        for (control in listOf('\t', '\n', '\r', '\u000c')) {
            invalid("Raw body control") { group.copy(children = listOf(text("x${control}y"))) }
            invalid("Raw trail control") { group.copy(children = listOf(Span("link", "x", "Target", trail = control.toString()))) }
            reject("Forged raw body control", changed(bytes, wire.at.getValue("root.0.clipped.child.0.text.bytes"), control.code))
        }
        val marker = Span("link", "[1]", targetFragment = "reference-9", role = "reference",
            citationMarker = CitationMarker(9, 7, "clip-return"))
        val backlink = ReferenceBacklink.withPolicies(7, Span("link", "return", targetFragment = "clip-return"))
        val audio = Span("link", "Play", "File:Tone.ogg",
            classes = "wikidict-media wikidict-media-file-546f6e652e6f6767", audioControl = AudioControl())
        for (child in listOf(marker, backlink.span, audio)) {
            invalid("Current qualified policy cannot enter clipped children") { group.copy(children = listOf(child)) }
            invalid("Current qualified owner cannot also carry clipped payload") { child.copy(text = "", clippedAbsolute = group) }
        }
        val nested = Wire('Y', 128).isolatedSpan(source)
        reject("Nested clipped carrier", replace(bytes, wire.at.getValue("root.0.clipped.child.0.start"),
            wire.at.getValue("root.0.clipped.child.0.end"), nested))
        val duplicate = Span("link", "x", "Same")
        invalid("Even equal descendant action repeats owner") { Span("link", "", "Same", clippedAbsolute = group.copy(children = listOf(duplicate))) }
        val state = LinkState("#123456", false)
        val paint = LinkPaint(state, state, state, state, state, state, state, state, false)
        invalid("Owner paint cannot overwrite a child color") {
            Span("link", "", "Owner", linkPaint = paint, clippedAbsolute = group.copy(children = listOf(Span("text", "x", foreground = "#654321"))))
        }
        val edge = StyleLength(px, 1f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        invalid("Ruby cannot contain clipped carrier") { owner(listOf(base(source))) }
        invalid("Padding cannot contain clipped carrier") { InlinePaddingGroup(edge, zero, listOf(source)) }
        invalid("Action cannot contain clipped carrier") { InlineActionGroup(listOf(source)) }
        invalid("Box cannot contain clipped carrier") { InlineBoxGroup(StyleEdges(zero, zero, zero, zero), none, emptyList(), listOf(source)) }
        val contexts = listOf(
            simple() to "root.0.segment0.base0.body.0",
            Span("text", "", inlinePaddingGroup = InlinePaddingGroup(edge, zero, listOf(text("x")))) to "root.0.padding.body.0",
            Span("link", "", "Owner", inlineActionGroup = InlineActionGroup(listOf(text("x")))) to "root.0.action.body.0",
            Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), none, emptyList(), listOf(text("x")))) to "root.0.box.body.0")
        for ((context, path) in contexts) {
            val raw = Wire('Y', if (context.inlineBoxGroup == null) 128 else 132)
            val original = raw.document(listOf(context))
            val child = Wire('Y', if (context.inlineBoxGroup == null) 128 else 132).isolatedSpan(source)
            reject("Forged structural context $path", replace(original, raw.at.getValue("$path.start"), raw.at.getValue("$path.end"), child))
        }

        // The initial carrier has one Entry-root containing block. An ordinary holder never clears ancestry debt.
        fun paragraph(value: Span = source) = Block("paragraph", 0, listOf(value))
        fun wrapper(child: Block, style: ContainerStyle = ContainerStyle()) =
            Block("container", 0, emptyList(), container = Container(listOf(child), style))
        val relativeStyle = ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
        fun entry(blocks: List<Block>, references: List<Reference> = emptyList(), media: List<Media> = emptyList()) =
            Entry("Clip ancestry", emptyList(), "language", "Hungarian", "hu", listOf(Section(2, "Body", blocks)), references, media = media)
        val staticRoot = wrapper(wrapper(paragraph()))
        assertEquals(staticRoot, entry(listOf(staticRoot)).sections.single().blocks.single())
        val directRelative = wrapper(wrapper(paragraph()), relativeStyle)
        invalid("Relative ancestry survives an ordinary intermediate") { entry(listOf(directRelative)) }
        val nestedTable = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
            blocks = listOf(Block("list_item", 1, listOf(source), listPath = "*"))))))
        val table = Table(listOf(source), listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = nestedTable))))
        val tableBlock = Block("table", 0, emptyList(), table = table)
        val staticTable = wrapper(tableBlock)
        assertEquals(staticTable, entry(listOf(staticTable)).sections.single().blocks.single())
        val relativeTable = wrapper(wrapper(tableBlock), relativeStyle)
        invalid("Table, nested cell and list ownership cannot erase nonstatic ancestry") { entry(listOf(relativeTable)) }
        for ((block, accepted) in listOf(staticRoot to true, directRelative to false, staticTable to true, relativeTable to false)) {
            val raw = Wire('Y', 128).apply { paragraphOverride = { positionedBlock(block, "clippedAncestry") } }
            val literal = raw.document(emptyList(), Sink.Body)
            if (accepted) assertEquals(block, read(literal).sections.single().blocks.single())
            else reject("Literal nonstatic clipped ancestry", literal)
        }
        val figure = read(Wire('Y', 128).document(listOf(source), Sink.FigureCaption))
            .sections.single().blocks.single().figure!!
        val figureBlock = Block("paragraph", 0, emptyList(), figure = figure)
        assertEquals(figureBlock, entry(listOf(figureBlock)).sections.single().blocks.single())
        invalid("Figure caption retains incoming nonstatic ancestry") { entry(listOf(wrapper(figureBlock, relativeStyle))) }
        val figureBorders = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None)
        val mediaPolicy = FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr), InlineBoxVerticalAlign.Middle)
        val captionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), figureBorders, figureBorders, mediaPolicy)
        val imageFigure = figure.copy(content = FigureContent.Image(Span("text", "", image = InlineImage("Probe.svg")),
            FigureSizingPolicy.Intrinsic), format = FigureFormat.Framed, frameBorder = FigureBorder.None, tableCaptionLayout = captionLayout)
        val imageCatalog = listOf(Media("Probe.svg", "image", ""))
        fun imageBlock(value: Figure) = Block("paragraph", 0, emptyList(), figure = value)
        assertEquals(imageFigure, entry(listOf(imageBlock(imageFigure)), media = imageCatalog).sections.single().blocks.single().figure)
        val positionedMedia = mediaPolicy.copy(positioning = ContainerPositioning.RelativeAuto)
        for (layout in listOf(captionLayout.copy(media = positionedMedia),
            captionLayout.copy(viewportStates = listOf(FigureViewportState(500, ContainerStyle(), positionedMedia))))) {
            val positionedFigure = imageFigure.copy(tableCaptionLayout = layout)
            invalid("Figure media and every responsive state retain nonstatic ancestry") {
                entry(listOf(imageBlock(positionedFigure)), media = imageCatalog)
            }
        }
        // A nonstatic sibling without clipped content must not poison following roots or reference bodies.
        val ordinaryRelative = wrapper(paragraph(text("ordinary")), relativeStyle)
        val reference = Reference(1, 1, "clip", listOf(source))
        val recovered = entry(listOf(ordinaryRelative, staticTable, figureBlock), listOf(reference))
        assertEquals(listOf(ordinaryRelative, staticTable, figureBlock), recovered.sections.single().blocks)
        assertEquals(listOf(reference), recovered.references)
    }

    @Test fun clippedAbsoluteSharesOwnerChildBudgetAndExistingContentTableLimitsWithoutReset() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val margin = ContainerMargin.Length(zero)
        val clipped = Span("text", "", clippedAbsolute = ClippedAbsoluteInline(zero, zero,
            ContainerMargins(margin, margin, margin, margin), listOf(text("kept")), staticParentDirection = BidiResolvedDirection.Ltr))
        // Real empty rows keep exact M/M+1 work without allocating a million styled overlay graphs.
        val limit = 1 shl 20
        fun table(rows: Int, caption: List<Span> = listOf(clipped)) = Table(caption,
            java.util.Collections.nCopies(rows, emptyList<Cell>()))
        val maximum = limit - 2 // clipped owner and child; no separate payload item
        val visited = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { visited.add(it) } }.table(table(maximum))
        assertEquals(listOf(clipped, text("kept")), visited)
        assertSame(clipped, visited.first())
        invalid("Clipped children share the preceding model budget") {
            PresentationSpanVisitor { _, _ -> }.table(table(maximum + 1))
        }
        PresentationSpanVisitor { _, _ -> }.table(table(maximum + 1, listOf(text("ordinary"))))
        val decoderRows = limit - 4 // Section + Table Block + clipped owner + child
        fun literal(rows: Int): ByteArray = Wire('Y', 128).apply {
            paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = table(rows)), "clipBudget") }
        }.document(emptyList(), Sink.Body)
        val decoded = read(literal(decoderRows)).sections.single().blocks.single().table!!
        assertEquals(decoderRows, decoded.rows.size)
        assertEquals(listOf(clipped), decoded.caption)
        assertTrue(decoded.rows.all { it.isEmpty() })
        reject("Clipped children share preceding wire items", literal(decoderRows + 1))

        val clippedPrefix = Block("table", 0, listOf(clipped), table = table(1, emptyList()))
        val prefixOwners = mutableListOf<Span>()
        PresentationSpanVisitor { spans, _ -> assertTrue(spans.isEmpty()) }.apply { onSpan = { prefixOwners.add(it) } }
            .blocks(listOf(clippedPrefix))
        assertEquals(listOf(clipped, text("kept")), prefixOwners)
        assertSame(clipped, prefixOwners.first())
        val clippedPrefixWire = Wire('Y', 128).apply {
            paragraphOverride = { audioPrefixTable(checkNotNull(clippedPrefix.table)) }
        }
        assertEquals(clippedPrefix, read(clippedPrefixWire.document(listOf(clipped), Sink.Body))
            .sections.single().blocks.single())

        // Both new policies in an ignored legacy prefix share one raw budget and no display callback.
        val audio = Span("link", "Play", "File:Tone.ogg",
            classes = "wikidict-media wikidict-media-file-546f6e652e6f6767", audioControl = AudioControl())
        val prefix = listOf(clipped, audio)
        fun prefixBlock(rows: Int) = Block("table", 0, prefix, table = table(rows, emptyList()))
        val raw = mutableListOf<Span>()
        PresentationSpanVisitor { spans, _ -> assertTrue(spans.isEmpty()) }.apply { onSpan = { raw.add(it) } }
            .blocks(listOf(prefixBlock(limit - 5))) // Block + clipped owner/child + AUDIO owner/control
        assertEquals(listOf(clipped, text("kept"), audio), raw)
        assertSame(clipped, raw.first())
        assertSame(audio, raw.last())
        invalid("Ignored clipped/AUDIO prefix model M+1") {
            PresentationSpanVisitor { _, _ -> }.blocks(listOf(prefixBlock(limit - 4)))
        }
        val catalog = listOf(Media("Tone.ogg", "audio", ""))
        fun prefixLiteral(rows: Int): ByteArray = Wire('Z', 8192 or 128).apply {
            paragraphOverride = { audioPrefixTable(checkNotNull(prefixBlock(rows).table)) }
        }.document(prefix, Sink.Body, mediaValues = catalog)
        val prefixRows = limit - 7 // add Section and Media to the direct block walk
        val decodedPrefix = read(prefixLiteral(prefixRows)).sections.single().blocks.single()
        assertEquals(prefix, decodedPrefix.spans)
        assertEquals(prefixRows, checkNotNull(decodedPrefix.table).rows.size)
        reject("Ignored clipped/AUDIO prefix decoder M+1", prefixLiteral(prefixRows + 1))
        PresentationSpanVisitor { _, _ -> }.spans(listOf(clipped), contentDepth = 15)
        invalid("Clipped consumes one content level") { PresentationSpanVisitor { _, _ -> }.spans(listOf(clipped), contentDepth = 16) }
        for (depth in listOf(15, 16)) {
            val bytes = Wire('Y', 128).document(listOf(clipped), Sink.Container, containers = depth)
            if (depth == 16) reject("Container plus clipped content17", bytes)
            else assertEquals("kept", read(bytes).let { entry ->
                var block = entry.sections.single().blocks.single()
                repeat(depth) { block = block.container!!.blocks.single() }
                textOf(block.spans)
            })
        }
        for (depth in listOf(32, 33)) {
            val wire = Wire('Y', 128).apply { paragraphOverride = { tableChain(depth) } }
            val bytes = wire.document(listOf(clipped), Sink.Body)
            if (depth == 33) reject("Clipped keeps table32 maximum", bytes)
            else {
                val seen = mutableListOf<Span>()
                PresentationSpanVisitor { _, _ -> }.apply { onSpan = { seen.add(it) } }.blocks(read(bytes).sections.single().blocks)
                assertEquals(listOf(clipped, text("kept")), seen)
            }
        }
    }
    @Test fun referenceBatches16384KeepOriginalNotesActionsAndLegacyBytesAtDeclaredBoundaries() {
        val marker = Span("link", "[A]", targetFragment = "reference-10", role = "reference",
            citationMarker = CitationMarker(10, 7, "return-A"))
        val bodyOwner = BodyTypography(InlineFontSnapshot(1.25f, FontScaleBasis.NormalBody, fontNormalized = true))
        val noteOwner = BodyTypography(InlineFontSnapshot(.8f, FontScaleBasis.NormalBody, fontNormalized = true), ContainerLineHeight.Normal)
        val action = Span("external_link", "source", "https://example.test/kept", trail = "!", tooltip = "original tooltip")
        val refs = listOf(
            Reference(10, 1, "A", listOf(action), bodyTypography = noteOwner,
                backlinks = listOf(ReferenceBacklink.withPolicies(7, Span("link", "return", targetFragment = "return-A")))),
            Reference(20, 1, "B", emptyList(), blocks = listOf(Block("paragraph", 0, listOf(text("rich B"), action)))))
        val placements = listOf(ReferenceBatchPlacement(0, 0, listOf(1)), ReferenceBatchPlacement(0, 1, listOf(0)))
        val low = 2 or 8 or 64
        val wire = Wire('Z', low or 16384)
        val bytes = wire.document(listOf(marker, text(" body")), Sink.Body, bodyTypography = bodyOwner,
            referenceValues = refs, referenceBatches = placements)
        val decoded = read(bytes)
        assertEquals(refs, decoded.references)
        assertEquals(placements, decoded.referenceBatches)
        assertEquals(bodyOwner, decoded.bodyTypography)
        assertEquals(listOf(marker, text(" body")), decoded.sections.single().blocks.single().spans)
        assertEquals(listOf(20L, 10L), decoded.readingRows.mapNotNull { it.reference?.number })
        assertEquals(listOf(10L, 20L), decoded.references.map { it.number })
        assertEquals(EntryLink("https://example.test/kept"), decoded.references[0].spans.single().entryLink())
        assertEquals("source!", textOf(decoded.references[0].spans))
        assertEquals(listOf(7L), decoded.references[0].backlinks.map { it.occurrence })
        val legacy = Wire('Y', low).document(listOf(marker, text(" body")), Sink.Body,
            bodyTypography = bodyOwner, referenceValues = refs)
        val prefix = bytes.copyOfRange(0, wire.at.getValue("referenceBatches.presence"))
        val recovered = changed(prefix.copyOfRange(0, 5) + prefix.copyOfRange(6, prefix.size), 3, 'Y'.code)
        assertArrayEquals(legacy, recovered)
        assertEquals(read(legacy), decoded.copy(referenceBatches = null))
        assertNull(read(legacy).referenceBatches)
    }

    @Test fun referenceBatches16384RejectIncompleteCensusInvalidBoundariesAndUntruthfulFraming() {
        val refs = listOf(Reference(10, 1, "A", listOf(text("A"))), Reference(20, 1, "B", listOf(text("B"))))
        val placements = listOf(ReferenceBatchPlacement(0, 0, listOf(1)), ReferenceBatchPlacement(0, 1, listOf(0)))
        val wire = Wire('Z', 16384)
        val bytes = wire.document(listOf(text("body")), Sink.Body, referenceValues = refs, referenceBatches = placements)
        val entry = read(bytes)
        val sameBoundary = placements.map { it.copy(beforeBlockIndex = 1) }
        assertEquals(listOf(20L, 10L), entry.copy(referenceBatches = sameBoundary).readingRows.mapNotNull { it.reference?.number })
        for (bad in listOf(emptyList(), placements.take(1), placements.reversed(),
            listOf(placements[0].copy(referenceIndices = emptyList()), placements[1]),
            listOf(placements[0].copy(sectionIndex = -1), placements[1]),
            listOf(placements[0].copy(sectionIndex = 1), placements[1]),
            listOf(placements[0].copy(beforeBlockIndex = 2), placements[1]),
            listOf(placements[0].copy(referenceIndices = listOf(2)), placements[1]),
            listOf(placements[0], placements[1].copy(referenceIndices = listOf(1))))) {
            invalid("Invalid explicit placement $bad") { entry.copy(referenceBatches = bad) }
        }
        invalid("Explicit placement cannot grant Ordinary") { entry.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary) }
        invalid("Empty references cannot own placement") { entry.copy(references = emptyList()) }
        invalid("Fragments cannot enter a note batch") { entry.copy(references = listOf(refs[0], Reference(20, null, "B", listOf(text("fragment")), ReferenceKind.Fragment))) }
        val start = wire.at.getValue("referenceBatches.presence")
        for (value in listOf(0, 2, 255)) reject("Canonical presence1 only", changed(bytes, start, value))
        for (value in listOf(0L, 0xffff_ffffL)) {
            reject("Nonempty bounded batch count", changed32(bytes, wire.at.getValue("referenceBatches.count"), value))
            reject("Nonempty bounded item count", changed32(bytes, wire.at.getValue("referenceBatches.0.count"), value))
        }
        reject("Section must exist", changed32(bytes, wire.at.getValue("referenceBatches.0.section"), 1))
        reject("Boundary is before a block or terminal", changed32(bytes, wire.at.getValue("referenceBatches.0.boundary"), 2))
        reject("Unsigned boundary cannot wrap", changed32(bytes, wire.at.getValue("referenceBatches.0.boundary"), 0xffff_ffffL))
        reject("Index must exist", changed32(bytes, wire.at.getValue("referenceBatches.0.index0"), 2))
        reject("No duplicated or omitted note", changed32(bytes, wire.at.getValue("referenceBatches.1.index0"), 1))
        reject("Explicit Ordinary unsupported", changed(bytes, wire.at.getValue("features"), 1))
        for (end in start..bytes.lastIndex) reject("Truncated batch tail $end", bytes.copyOf(end))
        reject("Trailing bytes", bytes + byteArrayOf(0))
        reject("No unadvertised tail", changed(bytes, 5, 0))
        reject("Unknown high feature", changed(bytes, 5, 192))
        reject("Old header cannot consume new tail", changed(bytes, 3, 'Y'.code))
        reject("Feature needs a real owner", Wire('Z', 16384).document(listOf(text("body")), Sink.Body, referenceValues = refs))
    }

    @Test fun referenceBatches16384ChargeTheSharedItemBudgetAfterExistingBodyAndNotes() {
        val limit = 1 shl 20
        val refs = listOf(Reference(1, 1, "", emptyList()))
        val placement = listOf(ReferenceBatchPlacement(0, 1, listOf(0)))
        fun root(rows: Int) = Block("table", 0, emptyList(), table = Table(emptyList(),
            java.util.Collections.nCopies(rows, emptyList<Cell>())))
        fun model(rows: Int) = Entry("Budget", emptyList(), "language", "English", "en",
            listOf(Section(2, "Body", listOf(root(rows)))), refs, referenceBatches = placement)
        // Existing Block plus batch and index; no retroactive model charge for the legacy reference slot.
        assertEquals(limit - 3, model(limit - 3).sections.single().blocks.single().table!!.rows.size)
        invalid("Batch cannot restart model budget") { model(limit - 2) }
        // The decoder additionally counts Section and the original reference slot.
        fun literal(rows: Int) = Wire('Z', 16384).apply {
            paragraphOverride = { positionedBlock(root(rows), "referenceBudget") }
        }.document(emptyList(), Sink.Body, referenceValues = refs, referenceBatches = placement)
        assertEquals(limit - 5, read(literal(limit - 5)).sections.single().blocks.single().table!!.rows.size)
        reject("Batch cannot restart wire budget", literal(limit - 4))
    }

    // This wire fixture uses the decoder's existing canonical all-positive margin representation.
    // The independent in-memory layout fixture intentionally also accepts Signed* positive values.
    private fun referenceLayoutCodecBatch(wrapperFamily: ContainerFontFamily? = null): ReferenceBatchPlacement {
        val f = ReferenceLayoutFixture
        val margin = StyleLength(StyleLengthUnit.Em, 1f)
        val box = f.box.copy(margins = StyleEdges(margin, margin, margin, margin))
        return f.batch.copy(layout = ReferenceBatchLayout(
            box.copy(ownerFont = f.font.copy(fontFamily = wrapperFamily)), box,
            f.layout.items.map { it.copy(box = box) }))
    }

    @Test fun referenceLayout32768DecodesOriginalIndicesFontsBacklinkAndTargetWithoutChangingNoteGraph() {
        val f = ReferenceLayoutFixture
        val batch = referenceLayoutCodecBatch()
        val flags = 1 or 8 or 16 or 64 or 16384 or 32768
        val wire = Wire('Z', flags)
        val bytes = wire.document(listOf(f.markerA, f.markerB, text(" body")), Sink.Body,
            referenceValues = f.references, referenceBatches = listOf(batch))
        val decoded = read(bytes)
        assertEquals(f.references, decoded.references)
        assertEquals(listOf(batch), decoded.referenceBatches)
        assertEquals(listOf(1, 0), decoded.referenceBatches!!.single().referenceIndices)
        assertEquals(listOf(f.markerA, f.markerB, text(" body")), decoded.sections.single().blocks.single().spans)
        val projection = referenceLayoutProjection(decoded.referenceBatches!!.single(), decoded.references, "compiled")
        assertEquals(listOf("4.", "3."), projection.paragraphs.values.map { it.marker })
        assertEquals(.75f, projection.paragraphs.values.first().spans.first().fontScale)
        assertEquals(.9f, projection.paragraphs.values.first().spans[1].fontScale)
        assertEquals("https://example.test/20", projection.paragraphs.values.first().reference.spans.last().target)
        // An actual negative edge retains the signed representation in the ordinary decoder.
        val positive = StyleLength(StyleLengthUnit.Em, 1f)
        val layout = checkNotNull(batch.layout)
        val signed = layout.copy(wrapper = layout.wrapper.copy(margins = SignedContainerEdges(
            SignedContainerMargin(StyleLengthUnit.Em, -1f), positive, positive, positive)))
        val signedBatch = batch.copy(layout = signed)
        val signedBytes = Wire('Z', flags).document(listOf(f.markerA, f.markerB, text(" body")), Sink.Body,
            referenceValues = f.references, referenceBatches = listOf(signedBatch))
        assertEquals(listOf(signedBatch), read(signedBytes).referenceBatches)
    }

    @Test fun referenceLayout32768RejectsCapabilityCensusPresenceMarkerPrefixAndTruncatedOwner() {
        val f = ReferenceLayoutFixture
        val flags = 1 or 8 or 16 or 64 or 16384 or 32768
        val wire = Wire('Z', flags)
        val bytes = wire.document(listOf(f.markerA, f.markerB, text(" body")), Sink.Body,
            referenceValues = f.references, referenceBatches = listOf(f.batch))
        val start = wire.at.getValue("referenceLayouts.0.presence")
        for (end in start until bytes.size) reject("Incomplete typed layout at $end", bytes.copyOf(end))
        reject("Unused layout capability", changed(bytes, start, 0))
        reject("Noncanonical layout presence", changed(bytes, start, 2))
        for (count in listOf(0L, 1L, 3L, 0xffff_ffffL))
            reject("Exact original index census", changed32(bytes, wire.at.getValue("referenceLayouts.0.count"), count))
        reject("Only decimal outside", changed(bytes, wire.at.getValue("referenceLayouts.0.0.marker"), 1))
        reject("Only one ordinary space", changed(bytes, wire.at.getValue("referenceLayouts.0.0.prefix"), 1))
        reject("Concrete marker RGB", changed(bytes, wire.at.getValue("referenceLayouts.0.0.foreground"), 0))
        reject("Noncanonical target presence", changed(bytes, wire.at.getValue("referenceLayouts.0.0.target"), 2))
        val noPlacement = flags and 16384.inv()
        reject("Layout requires placement owner", changed(changed(bytes, 4, noPlacement and 255), 5, noPlacement ushr 8))
        val noFont = flags and 1.inv()
        reject("Layout requires owner fonts", changed(changed(bytes, 4, noFont and 255), 5, noFont ushr 8))
    }

    @Test fun nullLayoutPreservesExact16384RecordAndOriginalLegacyRows() {
        val f = ReferenceLayoutFixture
        val flags = 8 or 16 or 64 or 16384
        val placements = listOf(f.batch.copy(layout = null))
        val wire = Wire('Z', flags)
        val bytes = wire.document(listOf(f.markerA, f.markerB, text(" body")), Sink.Body,
            referenceValues = f.references, referenceBatches = placements)
        val decoded = read(bytes)
        assertEquals(placements, decoded.referenceBatches)
        assertEquals(listOf(20L, 10L), decoded.readingRows.mapNotNull { it.reference?.number })
        assertTrue(decoded.readingRows.none { it.referenceBatch != null })
        assertFalse(wire.at.containsKey("referenceLayouts.0.presence"))
        val fullWire = Wire('Z', flags or 1 or 32768)
        val full = fullWire.document(listOf(f.markerA, f.markerB, text(" body")), Sink.Body,
            referenceValues = f.references, referenceBatches = listOf(f.batch))
        val stripped = full.copyOf(fullWire.at.getValue("referenceLayouts.0.presence"))
        stripped[4] = flags.toByte(); stripped[5] = (flags ushr 8).toByte()
        assertArrayEquals(bytes, stripped)
        assertEquals(decoded, read(stripped))
    }
    @Test fun referenceLayoutTailOwnsGlobalWrapperOnlyFontFamilyCensus() {
        val f = ReferenceLayoutFixture
        val batch = referenceLayoutCodecBatch(ContainerFontFamily.SansSerif)
        val wire = Wire('Z', 1 or 8 or 16 or 64 or 16384 or 32768)
        val bytes = wire.document(listOf(f.markerA, f.markerB, text(" body")), Sink.Body,
            features = 4, referenceValues = f.references, referenceBatches = listOf(batch))
        assertEquals(listOf(batch), read(bytes).referenceBatches)
        val missing = Wire('Z', 1 or 8 or 16 or 64 or 16384 or 32768).document(
            listOf(f.markerA, f.markerB, text(" body")), Sink.Body,
            features = 0, referenceValues = f.references, referenceBatches = listOf(batch))
        reject("Wrapper-only family requires global family census", missing)
    }


    @Test fun inlineBoxRadiusPreservesNullZeroAndOriginalOwnerWhileRejectingNonuniformShapes() {
        val px = StyleLengthUnit.Px
        val em = StyleLengthUnit.Em
        val zero = StyleLength(px, 0f)
        val zeroRadius = StyleWidth(StyleWidthUnit.Px, 0f)
        val padding = StyleEdges(StyleLength(em, .2f), StyleLength(em, .5f), StyleLength(em, .2f), StyleLength(em, .5f))
        val color = InlineBoxColor.Rgb("#aabbcc")
        val edge = InlineBoxBorderEdge.Solid(StyleLength(px, 1f), color)
        val border = InlineBoxBorderEdges(edge, edge, edge, edge)
        val child = Span("text", "Afrikaans\ud83d\ude00", trail = "!", fontScale = 1.25f, fontScaleBasis = FontScaleBasis.NormalBody)
        val square = InlineBoxGroup(padding, border, spans = listOf(child))
        val explicitZero = square.copy(radius = zeroRadius)
        val rounded = square.copy(radius = StyleWidth(StyleWidthUnit.Px, 2f))
        val owner = Span("link", "", "Afrikaans", background = "#eeeeee", fontScale = 1.25f,
            fontScaleBasis = FontScaleBasis.NormalBody, inlineBoxGroup = rounded)
        assertNull(square.radius); assertEquals(zeroRadius, explicitZero.radius); assertNotEquals(square, explicitZero)
        assertEquals(StyleWidth(StyleWidthUnit.Px, 2f), rounded.radius)
        assertSame(child, rounded.spans.single()); assertSame(rounded, owner.inlineBoxGroup)
        assertEquals("Afrikaans\ud83d\ude00!", rubyGraphicalProjection(listOf(owner)).text)
        assertEquals("Afrikaans", owner.target); assertEquals("#eeeeee", owner.background)
        assertEquals(1.25f, owner.fontScale!!, 0f); assertEquals(padding, rounded.padding)
        assertNull(owner.copy(inlineBoxGroup = rounded.copy(radius = null)).inlineBoxGroup!!.radius)
        assertEquals(StyleWidth(StyleWidthUnit.Px, 2f), owner.inlineBoxGroup!!.radius)
        val zeroEdge = edge.copy(width = zero)
        assertEquals(zeroRadius, square.copy(border = InlineBoxBorderEdges(zeroEdge, zeroEdge, zeroEdge, zeroEdge), radius = zeroRadius).radius)
        val emEdge = edge.copy(width = StyleLength(em, .1f))
        assertEquals(StyleWidth(StyleWidthUnit.Px, 2f), square.copy(border = InlineBoxBorderEdges(emEdge, emEdge, emEdge, emEdge),
            radius = StyleWidth(StyleWidthUnit.Px, 2f)).radius)
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY))
            invalid("Radius must remain finite and nonnegative") { square.copy(radius = StyleWidth(StyleWidthUnit.Px, value)) }
        for (value in listOf(0f, 2f)) invalid("Radius cannot use em") { square.copy(radius = StyleWidth(StyleWidthUnit.Em, value)) }
        val badEdges = listOf<InlineBoxBorderEdge>(InlineBoxBorderEdge.None, InlineBoxBorderEdge.Hidden,
            InlineBoxBorderEdge.Dotted(edge.width, color), edge.copy(width = StyleLength(px, 2f)),
            edge.copy(width = StyleLength(em, 1f)), edge.copy(color = InlineBoxColor.Rgb("#aabbcd")),
            edge.copy(color = InlineBoxColor.CurrentColor), edge.copy(color = InlineBoxColor.Transparent),
            edge.copy(color = InlineBoxColor.LightDark("#aabbcc", "#aabbcc")))
        for (radius in listOf(zeroRadius, StyleWidth(StyleWidthUnit.Px, 2f))) for (bad in badEdges) {
            invalid("Every nonnull radius requires one uniform RGB border style") {
                square.copy(border = border.copy(left = bad), radius = radius)
            }
            assertNull(square.copy(border = border.copy(left = bad)).radius)
            if (bad !is InlineBoxBorderEdge.Dotted && (bad !is InlineBoxBorderEdge.Solid || bad.color !is InlineBoxColor.Rgb)) {
                invalid("Uniform edges still require solid or dotted canonical RGB") {
                    square.copy(border = InlineBoxBorderEdges(bad, bad, bad, bad), radius = radius)
                }
            }
        }
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            left = InlineBoxInset(StyleWidthUnit.Px, 0f)), border)
        for (radius in listOf(zeroRadius, StyleWidth(StyleWidthUnit.Px, 2f))) invalid("Rounded owner cannot carry an overlay") {
            square.copy(overlays = listOf(overlay), radius = radius)
        }
        assertEquals(listOf(overlay), square.copy(overlays = listOf(overlay)).overlays)
        val mutableOverlays = mutableListOf<InlineBoxOverlay>()
        val mutableGroup = rounded.copy(overlays = mutableOverlays)
        val retainedOwner = owner.copy(inlineBoxGroup = mutableGroup)
        val retainedEntry = Entry("Rounded", listOf(retainedOwner), "language", "Afrikaans", "af", emptyList(), emptyList())
        mutableOverlays.add(overlay)
        invalid("Existing Span revalidation must catch a later overlay") { retainedOwner.copy() }
        invalid("Complete Entry revalidation must catch a later overlay") { retainedEntry.copy() }
        mutableOverlays.clear()
        assertSame(retainedOwner, retainedEntry.copy().displayTitle.single())
        assertSame(child, rounded.spans.single())
    }

    private fun roundedWireOwner(radius: StyleWidth?): Span {
        val px = StyleLengthUnit.Px
        val pad = StyleLength(StyleLengthUnit.Em, .25f)
        val edge = InlineBoxBorderEdge.Solid(StyleLength(px, 1f), InlineBoxColor.Rgb("#c8ccd1"))
        val states = List(8) { LinkState("#123456", it % 2 != 0) }
        val paint = LinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], states[6], states[7], true)
        return Span("link", "", "Afrikaans", targetFragment = "sense", tooltip = "whole action",
            background = "#eeeeee", fontScale = 1.25f, fontScaleBasis = FontScaleBasis.NormalBody, linkPaint = paint,
            inlineBoxGroup = InlineBoxGroup(StyleEdges(pad, pad, pad, pad), InlineBoxBorderEdges(edge, edge, edge, edge),
                spans = listOf(Span("text", "Afrikaans\ud83d\ude00", trail = "!", fontScale = 1.25f,
                    fontScaleBasis = FontScaleBasis.NormalBody)), radius = radius))
    }

    @Test fun inlineBoxRadiusLocalFlagRoundtripsWholeActionAtEveryExistingSinkAndKeepsNullBytes() {
        val square = roundedWireOwner(null)
        for (radius in listOf(StyleWidth(StyleWidthUnit.Px, 0f), StyleWidth(StyleWidthUnit.Px, 2f))) {
            val source = square.copy(inlineBoxGroup = square.inlineBoxGroup!!.copy(radius = radius))
            for (sink in Sink.entries) {
                val wire = Wire('Y', 4)
                val bytes = wire.document(listOf(source), sink,
                    headingTitle = "Afrikaans\ud83d\ude00!")
                val actual = selected(read(bytes), sink)
                assertEquals("$sink complete source owner", source, actual)
                assertEquals(EntryLink("Afrikaans", "sense"), actual.entryLink())
                assertEquals("whole action", actual.tooltip); assertEquals("#eeeeee", actual.background)
                assertEquals("text", actual.inlineBoxGroup!!.spans.single().kind)
                assertEquals("", actual.inlineBoxGroup!!.spans.single().target)
                assertEquals("Afrikaans\ud83d\ude00!", rubyGraphicalProjection(listOf(actual)).text)
                val start = wire.at.getValue("root.0.box.radius")
                assertEquals(wire.at.getValue("root.0.box.childrenEnd"), start)
                assertEquals(start + 5, wire.at.getValue("root.0.box.end"))
                val expected = if (radius.value == 0f) byteArrayOf(0, 0, 0, 0, 0) else byteArrayOf(0, 0, 0, 0, 64)
                assertArrayEquals(expected, bytes.copyOfRange(start, start + 5))
                assertEquals(0x20, bytes[wire.at.getValue("root.0.fontFields")].toInt() and 0x20)
                var old = replace(bytes, start, start + 5, byteArrayOf())
                val field = wire.at.getValue("root.0.fontFields")
                old = changed(old, field, old[field].toInt() and 0xdf)
                val legacy = Wire('Y', 4).document(listOf(square), sink,
                    headingTitle = "Afrikaans\ud83d\ude00!")
                assertArrayEquals("Only same-owner local bit and5B suffix differ", legacy, old)
                assertEquals(square, selected(read(old), sink))
            }
        }
        assertNull(square.inlineBoxGroup!!.radius)
        val inner = Span("text", "", inlineBoxGroup = square.inlineBoxGroup!!.copy(radius = StyleWidth(StyleWidthUnit.Px, 2f)))
        val outer = square.copy(inlineBoxGroup = square.inlineBoxGroup!!.copy(spans = listOf(inner)))
        val wire = Wire('Y', 4)
        val bytes = wire.document(listOf(outer))
        assertEquals(outer, read(bytes).displayTitle.single())
        assertEquals(0, bytes[wire.at.getValue("root.0.fontFields")].toInt() and 0x20)
        assertEquals(0x20, bytes[wire.at.getValue("root.0.box.body.0.fontFields")].toInt() and 0x20)
        val audio = Span("link", "Tone.ogg", "File:Tone.ogg",
            classes = "wikidict-media wikidict-media-file-546f6e652e6f6767", audioControl = AudioControl())
        val catalog = listOf(Media("Tone.ogg", "audio", "original audio"))
        val rounded = roundedWireOwner(StyleWidth(StyleWidthUnit.Px, 2f))
        val mixed = read(Wire('Z', 4 or 8192).document(listOf(rounded, audio), mediaValues = catalog))
        assertEquals(listOf(rounded, audio), mixed.displayTitle); assertEquals(catalog, mixed.media)
    }

    @Test fun inlineBoxRadiusRejectsOrphanFlagsMalformedLengthsAndForgedRoundedDomains() {
        val radius = StyleWidth(StyleWidthUnit.Px, 2f)
        val source = roundedWireOwner(radius)
        val wire = Wire('Y', 4)
        val bytes = wire.document(listOf(source))
        val fields = wire.at.getValue("root.0.fontFields")
        val start = wire.at.getValue("root.0.box.radius")
        for (unknown in listOf(0x40, 0x80)) reject("Missing atomic suffix or reserved local font bit",
            changed(bytes, fields, bytes[fields].toInt() or unknown))
        reject("Radius cannot borrow an absent box", changed(bytes, wire.at.getValue("root.0.box"), 0))
        reject("Payload requires its local flag", changed(bytes, fields, bytes[fields].toInt() and 0xdf))
        for (unit in listOf(1, 3, 255)) reject("Only CSS-pixel or percentage radius", changed(bytes, start, unit))
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) reject("Finite nonnegative radius",
            changed32(bytes, start + 1, value.toRawBits().toLong() and 0xffff_ffffL))
        for (count in 0 until 5) reject("No partial radius suffix", bytes.copyOf(start + count))
        reject("No extra nullable tag", replace(bytes, start, start, byteArrayOf(1)))
        reject("Strict final EOF", bytes + byteArrayOf(0))
        val childFields = wire.at.getValue("root.0.box.body.0.fontFields")
        reject("Child cannot borrow ancestor radius box", changed(bytes, childFields, bytes[childFields].toInt() or 0x20))
        val siblingWire = Wire('Y', 4)
        val siblings = siblingWire.document(listOf(source, text("ordinary")))
        val siblingField = siblingWire.at.getValue("root.1.fontFields")
        reject("Sibling cannot borrow another owner's box", changed(siblings, siblingField, siblings[siblingField].toInt() or 0x20))
        val oldWire = Wire('O')
        val old = oldWire.document(listOf(text("ordinary")))
        assertEquals(listOf(text("ordinary")), read(old).displayTitle)
        reject("Old header still rejects radius flag", changed(old, oldWire.at.getValue("root.0.fontFields"), 0x20))
        val body = BodyTypography(InlineFontSnapshot(1f, FontScaleBasis.NormalBody, fontNormalized = true))
        val noBoxWire = Wire('Y', 2)
        val noBox = noBoxWire.document(listOf(text("ordinary")), bodyTypography = body)
        assertEquals(body, read(noBox).bodyTypography)
        reject("Existing global box capability is required", changed(noBox, noBoxWire.at.getValue("root.0.fontFields"), 0x20))
        val square = source.copy(inlineBoxGroup = source.inlineBoxGroup!!.copy(radius = null))
        val border = square.inlineBoxGroup!!.border
        val first = border.top as InlineBoxBorderEdge.Solid
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Px, 0f)), border)
        val uniformCurrent = first.copy(color = InlineBoxColor.CurrentColor)
        val badGroups = listOf(square.inlineBoxGroup!!.copy(overlays = listOf(overlay)),
            square.inlineBoxGroup!!.copy(border = border.copy(left = InlineBoxBorderEdge.Dotted(first.width, first.color))),
            square.inlineBoxGroup!!.copy(border = border.copy(left = first.copy(width = StyleLength(StyleLengthUnit.Em, 1f)))),
            square.inlineBoxGroup!!.copy(border = InlineBoxBorderEdges(uniformCurrent, uniformCurrent, uniformCurrent, uniformCurrent)))
        for (group in badGroups) {
            val raw = Wire('Y', 4)
            val legacy = raw.document(listOf(square.copy(inlineBoxGroup = group)))
            assertEquals(group, read(legacy).displayTitle.single().inlineBoxGroup)
            val at = raw.at.getValue("root.0.box.childrenEnd")
            val forged = replace(legacy, at, at, byteArrayOf(0, 0, 0, 0, 64))
            val field = raw.at.getValue("root.0.fontFields")
            reject("Forged radius cannot widen square shape domain", changed(forged, field, forged[field].toInt() or 0x20))
        }
        assertEquals(source, read(bytes).displayTitle.single())
    }

    @Test fun inlineBoxRadiusDoesNotAddItemsOrResetContentAndTableBudgets() {
        val limit = 1 shl 20
        val square = roundedWireOwner(null)
        val rounded = square.copy(inlineBoxGroup = square.inlineBoxGroup!!.copy(radius = StyleWidth(StyleWidthUnit.Px, 2f)))
        fun root(count: Int, source: Span) = Block("table", 0, emptyList(), table = Table(listOf(source),
            java.util.Collections.nCopies(count, emptyList<Cell>())))
        fun model(count: Int, source: Span) = Entry("Budget", emptyList(), "language", "Afrikaans", "af",
            listOf(Section(2, "Body", listOf(root(count, source)))), emptyList())
        // Existing root Block + original Box Span + real child Span; radius is only a scalar.
        for (source in listOf(square, rounded)) {
            assertEquals(limit - 3, model(limit - 3, source).sections.single().blocks.single().table!!.rows.size)
            invalid("Radius never bypasses shared model work") { model(limit - 2, source) }
            fun literal(count: Int) = Wire('Y', 4).apply {
                paragraphOverride = { positionedBlock(root(count, source), "radiusBudget") }
            }.document(emptyList(), Sink.Body)
            // Reader also charges the existing Section slot.
            assertEquals(limit - 4, read(literal(limit - 4)).sections.single().blocks.single().table!!.rows.size)
            reject("Radius never bypasses shared decode work", literal(limit - 3))
        }
        for (depth in listOf(15, 16)) {
            val bytes = Wire('Y', 4).document(listOf(rounded), Sink.Container, containers = depth)
            if (depth == 15) assertEquals(1, read(bytes).sections.size)
            else reject("Box child still consumes content depth after15 containers", bytes)
        }
        for (depth in listOf(32, 33)) {
            val bytes = Wire('Y', 4).apply { paragraphOverride = { tableChain(depth, mixed = true) } }
                .document(listOf(rounded), Sink.Body)
            if (depth == 32) assertEquals(1, read(bytes).sections.size)
            else reject("Rounded box cannot reset table depth", bytes)
        }
    }

    private fun disclosurePaint() = ContainerDisclosureTextPaint(LinkState("#102030", false),
        LinkState("#203040", true), LinkState("#304050", false), LinkState("#405060", true), true)
    private fun disclosurePolicy() = ContainerDisclosure(1, true, "[ก😀é]", "[hide]",
        ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.UaAuto, FigureColor.Rgb("#3366cc")),
        ContainerDisclosurePlacement.FloatRight, FigureColor.Transparent, BidiResolvedDirection.Rtl,
        ContainerDisclosureLabelRun(1, 8, disclosurePaint()), ContainerDisclosureLabelRun(1, 5, disclosurePaint()))
    private fun disclosureOwner(policy: ContainerDisclosure? = disclosurePolicy(),
        style: ContainerStyle = ContainerStyle(), hidden: List<Block> = listOf(Block("paragraph", 0,
            listOf(Span("text", "hidden 😀 ", bold = true), Span("link", "target", "Original target", targetFragment = "sense"))))) =
        Block("container", 0, emptyList(), container = Container(listOf(
            Block("paragraph", 0, listOf(Span("external_link", "outside", "https://example.test/outside"))),
            Block("container", 0, emptyList(), container = Container(hidden))), style, policy))
    private fun disclosureContainers(entry: Entry): List<Container> = buildList {
        val visitor = PresentationSpanVisitor { _, _ -> }
        visitor.onContainer = { add(it) }
        entry.sections.forEach { visitor.blocks(it.blocks) }
        entry.references.forEach { reference -> reference.blocks?.let { visitor.blocks(it) } }
    }

    @Test fun containerDisclosureRetainsOriginalChildLabelsStatesAndRejectsMutatedCustody() {
        val root = disclosureOwner()
        val owner = checkNotNull(root.container)
        val policy = checkNotNull(owner.disclosure)
        val child = checkNotNull(owner.blocks[1].container)
        val entry = Entry("Disclosure", emptyList(), "language", "Thai", "th",
            listOf(Section(2, "Body", listOf(root))), emptyList())
        assertSame(owner, disclosureContainers(entry).first())
        assertSame(child, disclosureContainers(entry)[1])
        val original = mutableListOf<Span>()
        root.visitSpanRuns { spans, _ -> original.addAll(spans) }
        assertEquals(listOf("outside", "hidden 😀 ", "target"), original.map { it.text })
        assertSame(child.blocks.single().spans.last(), original.last())
        assertEquals(EntryLink("Original target", "sense"), original.last().entryLink())
        assertEquals("[ก😀é]", policy.expandLabel)
        assertEquals(1L, policy.expandRun!!.start); assertEquals(8L, policy.expandRun!!.end)
        assertEquals(listOf("#102030", "#203040", "#304050", "#405060"), listOf(policy.expandRun!!.paint.normal,
            policy.expandRun!!.paint.hover, policy.expandRun!!.paint.active, policy.expandRun!!.paint.hoverActive).map { it.foreground })
        assertEquals(listOf(false, true, false, true), listOf(policy.expandRun!!.paint.normal,
            policy.expandRun!!.paint.hover, policy.expandRun!!.paint.active, policy.expandRun!!.paint.hoverActive).map { it.underline })
        assertTrue(policy.expandRun!!.paint.underlineOnFocus)
        assertEquals(FigureColor.Transparent, policy.foreground)
        assertSame(child, owner.copy(disclosure = policy.copy(initiallyCollapsed = false)).blocks[1].container)
        for (index in listOf(0L, 2L, 0xffff_ffffL)) invalid("Original immediate child index $index") {
            owner.copy(disclosure = policy.copy(contentIndex = index))
        }
        for (index in listOf(-1L, 0x1_0000_0000L)) invalid("u32 index $index") { policy.copy(contentIndex = index) }
        for (label in listOf("", "\u0000", "\t", "\n", "\r", "\u001f", "\u007f", "\ud800", "\udc00")) {
            invalid("Invalid complete expand label") { policy.copy(expandLabel = label, expandRun = null) }
            invalid("Invalid complete collapse label") { policy.copy(collapseLabel = label, collapseRun = null) }
        }
        assertEquals(" \u0085 ", policy.copy(expandLabel = " \u0085 ", expandRun = null).expandLabel)
        for ((start, end) in listOf(2L to 8L, 1L to 5L, 1L to 40L)) invalid("Original UTF-8 boundaries") {
            policy.copy(expandRun = ContainerDisclosureLabelRun(start, end, disclosurePaint()))
        }
        invalid("Nonempty run") { ContainerDisclosureLabelRun(1, 1, disclosurePaint()) }
        invalid("No native-theme label paint") { policy.copy(foreground = FigureColor.NativeTheme) }
        invalid("No native-theme focus paint") { ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.UaAuto, FigureColor.NativeTheme) }
        invalid("None cannot carry color") { ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.AuthoredNone, FigureColor.Transparent) }
        invalid("Run states require canonical RGB") { disclosurePaint().copy(normal = LinkState("#ABCDEF", false)) }
        assertNotNull(policy.copy(focus = ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.AuthoredNone)))
        assertNotNull(policy.copy(focus = ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.UaAuto, FigureColor.Transparent)))
        val mutable = owner.blocks.toMutableList()
        val retained = owner.copy(blocks = mutable)
        val retainedEntry = entry.copy(sections = listOf(Section(2, "Body", listOf(root.copy(container = retained)))))
        mutable[1] = mutable[0]
        invalid("Container copy rechecks original child") { retained.copy() }
        invalid("Complete hidden-tree validation rechecks original child") { retainedEntry.copy() }
        mutable[1] = owner.blocks[1]
        assertSame(child, disclosureContainers(retainedEntry.copy())[1])
    }

    @Test fun containerDisclosure256RoundtripsFullHiddenGraphAtEveryBlockSinkAndMixedColumnTail() {
        val original = disclosureOwner()
        val sinks = listOf(Sink.Body, Sink.Container, Sink.CellBlocks, Sink.TableRichCaption,
            Sink.ReferenceBlocks, Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)
        for (sink in sinks) {
            val wire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(original, "disclosure") } }
            val bytes = wire.document(emptyList(), sink)
            val decoded = read(bytes)
            val actual = disclosureContainers(decoded).single { it.disclosure != null }
            assertEquals("Full original owner at $sink", original.container, actual)
            assertEquals(listOf("hidden 😀 ", "target"), actual.blocks[1].container!!.blocks.single().spans.map { it.text })
            assertEquals(EntryLink("Original target", "sense"), actual.blocks[1].container!!.blocks.single().spans.last().entryLink())
            val label = "disclosure.style.disclosure"
            assertEquals(8, bytes[wire.at.getValue("disclosure.style.extension")].toInt() and 255)
            assertEquals(2, bytes[wire.at.getValue("$label.placement")].toInt() and 255)
            assertEquals(15, bytes[wire.at.getValue("$label.fields")].toInt() and 255)
            assertEquals(1, bytes[wire.at.getValue("$label.direction")].toInt() and 255)
            assertEquals(26, bytes[wire.at.getValue("$label.expandRun.flags")].toInt() and 255)
            assertEquals(53, wire.at.getValue("$label.expandRun.flags") + 1 - wire.at.getValue("$label.expandRun"))
            assertEquals(wire.at.getValue("$label.end"), wire.at.getValue("disclosure.children"))
        }
        val minimal = ContainerDisclosure(1, true, "e", "c")
        val plain = disclosureOwner(minimal)
        val minimalWire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(plain, "minimal") } }
        val minimalBytes = minimalWire.document(emptyList(), Sink.Body)
        assertArrayEquals(byteArrayOf(1, 0, 0, 0, 1, 1, 0, 0, 0, 101, 1, 0, 0, 0, 99, 0, 0, 0),
            minimalBytes.copyOfRange(minimalWire.at.getValue("minimal.style.disclosure"),
                minimalWire.at.getValue("minimal.style.disclosure.end")))
        for ((index, focus) in listOf(null, ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.AuthoredNone),
            ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.UaAuto),
            ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.UaAuto, FigureColor.Transparent)).withIndex()) {
            val policy = minimal.copy(initiallyCollapsed = index % 2 == 0, focus = focus,
                placement = ContainerDisclosurePlacement.entries[index % 3],
                foreground = if (index == 1) FigureColor.Rgb("#123456") else null,
                direction = if (index == 2) BidiResolvedDirection.Ltr else null)
            val originalPolicy = disclosureOwner(policy)
            val candidate = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(originalPolicy) } }
            assertEquals(originalPolicy, read(candidate.document(emptyList(), Sink.Body)).sections.single().blocks.single())
        }
        val font = InlineFontSnapshot(fontScale = 18f, fontScaleBasis = FontScaleBasis.CssPx, fontNormalized = true)
        val style = ContainerStyle(ownerFont = font, columns = ContainerColumns(2, StyleLength(StyleLengthUnit.Px, 1f),
            StyleLength(StyleLengthUnit.Em, 12f), BidiResolvedDirection.Ltr))
        val mixed = disclosureOwner(style = style)
        val wire = Wire('Z', 1 or 256 or 4096).apply { paragraphOverride = { positionedBlock(mixed, "mixed") } }
        val bytes = wire.document(emptyList(), Sink.Body)
        assertEquals(mixed, read(bytes).sections.single().blocks.single())
        assertEquals(wire.at.getValue("mixed.style.disclosure.end"), wire.at.getValue("mixed.style.columnExtension"))
        assertEquals(wire.at.getValue("mixed.style.end"), wire.at.getValue("mixed.children"))
        assertEquals(font, read(bytes).sections.single().blocks.single().container!!.style.ownerFont)
        // The same capability remains occupied by an ordinary wrap after removing disclosure.
        val wrapped = disclosureOwner(style = ContainerStyle(textWrap = TextWrap.Normal))
        val with = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(wrapped, "nullPair") } }
        val full = with.document(emptyList(), Sink.Body)
        val start = with.at.getValue("nullPair.style.disclosure")
        val end = with.at.getValue("nullPair.style.disclosure.end")
        val stripped = changed(replace(full, start, end, byteArrayOf()), with.at.getValue("nullPair.style.extension"), 2)
        val square = wrapped.copy(container = wrapped.container!!.copy(disclosure = null))
        val without = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(square, "nullPair") } }
        val legacy = without.document(emptyList(), Sink.Body)
        assertArrayEquals(legacy, stripped)
        assertEquals(square, read(legacy).sections.single().blocks.single())
        val noExtension = disclosureOwner(null)
        val old = Wire('O').apply { paragraphOverride = { positionedBlock(noExtension) } }
        assertEquals(noExtension, read(old.document(emptyList(), Sink.Body)).sections.single().blocks.single())
    }

    @Test fun containerDisclosureRefusesMalformedLocalContextLabelsStatesAndCapabilityDebt() {
        val source = disclosureOwner()
        val wire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(source, "disclosure") } }
        val bytes = wire.document(emptyList(), Sink.Body)
        val name = "disclosure.style.disclosure"
        for (extension in listOf(16, 128, 255)) reject("Unknown Container extension $extension",
            changed(bytes, wire.at.getValue("disclosure.style.extension"), extension))
        reject("Disclosure cannot borrow missing header256", changed(bytes, 5, 0))
        val noPayload = changed(replace(bytes, wire.at.getValue(name), wire.at.getValue("$name.end"), byteArrayOf()),
            wire.at.getValue("disclosure.style.extension"), 0)
        assertEquals("The complete tree has no actual256 owner", "Y/Z features do not match owner geometry payload",
            runCatching { read(noPayload) }.exceptionOrNull()?.message)
        for (index in listOf(0L, 2L, 0xffff_ffffL)) reject("Original immediate Container child", changed32(bytes, wire.at.getValue("$name.index"), index))
        for (key in listOf("collapsed", "focus", "focus.presence")) reject("Canonical bool $key", changed(bytes, wire.at.getValue("$name.$key"), 2))
        reject("Unknown focus mode", changed(bytes, wire.at.getValue("$name.focus.mode"), 2))
        reject("None cannot carry paint", changed(bytes, wire.at.getValue("$name.focus.mode"), 0))
        reject("No native-theme focus", changed(bytes, wire.at.getValue("$name.focus.color"), 0))
        reject("No native-theme foreground", changed(bytes, wire.at.getValue("$name.foreground"), 0))
        reject("Unknown placement", changed(bytes, wire.at.getValue("$name.placement"), 3))
        reject("Unknown direction", changed(bytes, wire.at.getValue("$name.direction"), 2))
        for (flag in listOf(16, 32, 64, 128)) reject("Unknown disclosure fields $flag", changed(bytes, wire.at.getValue("$name.fields"), 15 or flag))
        for (flag in listOf(32, 64, 128)) reject("Unknown run flags $flag", changed(bytes, wire.at.getValue("$name.expandRun.flags"), 26 or flag))
        for (key in listOf("expand", "collapse")) {
            val length = if (key == "expand") source.container!!.disclosure!!.expandLabel.encodeToByteArray().size else 6
            val offset = wire.at.getValue("$name.$key")
            reject("Empty complete $key", replace(bytes, offset, offset + 4 + length, byteArrayOf(0, 0, 0, 0)))
            reject("Oversize $key", changed32(bytes, offset, 32L * 1024 * 1024 + 1))
            for (bad in listOf(0, 31, 127, 255)) reject("Invalid $key bytes", changed(bytes, wire.at.getValue("$name.$key.bytes"), bad))
        }
        reject("No continuation-byte start", changed32(bytes, wire.at.getValue("$name.expandRun.start"), 2))
        reject("No continuation-byte end", changed32(bytes, wire.at.getValue("$name.expandRun.end"), 5))
        reject("Run outside label", changed32(bytes, wire.at.getValue("$name.expandRun.end"), 0xffff_ffffL))
        reject("Four canonical RGB states", changed(bytes, wire.at.getValue("$name.expandRun.color3.bytes") + 1, 'A'.code))
        for (end in wire.at.getValue(name) until wire.at.getValue("$name.end")) reject("Truncated disclosure $end", bytes.copyOf(end))
        reject("No trailing data", bytes + byteArrayOf(0))
        val heading = Wire('Z', 256)
        val generic = heading.document(listOf(text("heading")), Sink.Heading, headingTitle = "heading")
        val wrongContext = changed(generic, heading.at.getValue("heading.extension"), 8)
        assertTrue("Generic style rejects8 before payload", runCatching { read(wrongContext) }.exceptionOrNull()?.message
            ?.contains("Unknown positioned Container extension") == true)
        assertEquals(source, read(bytes).sections.single().blocks.single())
    }

    @Test fun containerDisclosureHiddenTreeUsesOneItemContentAndTableBudget() {
        val limit = 1 shl 20
        val minimal = ContainerDisclosure(0, true, "e", "c")
        val rich = disclosurePolicy().copy(contentIndex = 0)
        fun owner(rows: Int, policy: ContainerDisclosure): Block {
            val table = Block("table", 0, emptyList(), table = Table(emptyList(), java.util.Collections.nCopies(rows, emptyList<Cell>())))
            val child = Block("container", 0, emptyList(), container = Container(listOf(table)))
            return Block("container", 0, emptyList(), container = Container(listOf(child), disclosure = policy))
        }
        for ((policy, cost) in listOf(minimal to 1, rich to 4)) {
            fun entry(rows: Int) = Entry("Hidden budget", emptyList(), "language", "Thai", "th",
                listOf(Section(2, "Body", listOf(owner(rows, policy)))), emptyList())
            val exact = entry(limit - 3 - cost)
            assertEquals(limit - 3 - cost, exact.sections.single().blocks.single().container!!.blocks.single().container!!.blocks.single().table!!.rows.size)
            invalid("Hidden rows cannot restart model budget") { entry(limit - 2 - cost) }
            fun wire(rows: Int): ByteArray = Wire('Z', 256).apply {
                paragraphOverride = { positionedBlock(owner(rows, policy), "budget") }
            }.document(emptyList(), Sink.Body)
            val decoded = read(wire(limit - 4 - cost))
            assertEquals(policy, decoded.sections.single().blocks.single().container!!.disclosure)
            assertEquals(limit - 4 - cost, decoded.sections.single().blocks.single().container!!.blocks.single().container!!.blocks.single().table!!.rows.size)
            reject("Disclosure/focus/runs share decoder budget", wire(limit - 3 - cost))
        }
        val source = disclosureOwner(minimal.copy(contentIndex = 1))
        var nested = source
        repeat(14) { nested = Block("container", 0, emptyList(), container = Container(listOf(nested))) }
        assertNotNull(nested)
        invalid("Hidden content cannot exceed depth16") { Container(listOf(nested)) }
        for (count in listOf(14, 15)) {
            val wire = Wire('Z', 256).apply { paragraphOverride = { positionedBlock(source, "depth") } }
            val bytes = wire.document(emptyList(), Sink.Container, containers = count)
            if (count == 14) assertNotNull(read(bytes)) else reject("Shared hidden content depth17", bytes)
        }
        for (depth in listOf(32, 33)) {
            val wire = Wire('Z', 256).apply { paragraphOverride = { disclosureTableChain(minimal, depth) } }
            val bytes = wire.document(listOf(Span("link", "deep hidden", "Deep target")), Sink.Body)
            if (depth == 32) assertNotNull(read(bytes)) else reject("Shared hidden table depth33", bytes)
        }
    }

    @Test fun tableRowVisibilityRetainsFullGraphAcrossBlockSinksAndNullWireBytes() {
        val caption = Span("link", "caption", "Caption", targetFragment = "section", tooltip = "tip")
        val nestedAction = Span("external_link", "nested", "https://example.org/nested")
        val blockAction = Span("link", "ordered", "Ordered", explanation = "kept")
        val nested = Table(emptyList(), listOf(listOf(Cell(listOf(nestedAction), false, 1, 1))), rowsHiddenMaxWidthPx = 1)
        val rows = listOf(listOf(Cell(listOf(text("plain")), true, 1, 1),
            Cell(emptyList(), false, 1, 1, nestedTable = nested),
            Cell(emptyList(), false, 1, 1, blocks = listOf(Block("paragraph", 0, listOf(blockAction))))))
        val source = Table(listOf(caption), rows, style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 240f)),
            rowsHiddenMaxWidthPx = 720)
        val block = Block("table", 0, emptyList(), table = source)
        val seen = mutableListOf<Span>()
        val tables = mutableListOf<Table>()
        PresentationSpanVisitor { _, _ -> }.apply {
            onSpan = { seen.add(it) }; onTable = { value, _, _ -> tables.add(value) }
        }.table(source)
        assertSame(source, tables.first()); assertSame(rows, source.rows)
        assertSame(caption, seen.first()); assertSame(nestedAction, seen[2]); assertSame(blockAction, seen[3])
        assertSame(rows, source.copy(caption = emptyList()).rows)
        assertEquals(720L, source.copy(caption = emptyList()).rowsHiddenMaxWidthPx)
        for (sink in listOf(Sink.Body, Sink.Container, Sink.CellBlocks, Sink.TableRichCaption, Sink.ReferenceBlocks,
                Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)) {
            val wire = Wire('O').apply { paragraphOverride = { positionedBlock(block, "rowsPolicy") } }
            val decoded = read(wire.document(emptyList(), sink))
            val found = mutableListOf<Table>()
            val visitor = PresentationSpanVisitor { _, _ -> }.apply {
                onTable = { value, _, _ -> if (value.rowsHiddenMaxWidthPx != null) found.add(value) }
            }
            decoded.sections.forEach { visitor.blocks(it.blocks) }
            decoded.references.forEach { it.blocks?.let { blocks -> visitor.blocks(blocks) } }
            assertEquals(sink.name, listOf(source, nested), found)
            assertEquals(listOf(caption), found.first().caption)
            assertEquals(listOf(blockAction), found.first().rows.single()[2].blocks!!.single().spans)
        }
        val rich = source.copy(caption = emptyList(), captionBlocks = listOf(Block("paragraph", 0, listOf(caption))))
        val richWire = Wire('M').apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = rich)) } }
        assertEquals(rich, read(richWire.document(emptyList(), Sink.Body)).sections.single().blocks.single().table)
        // Null does not add a presence byte or a feature trailer; the new scalar follows the entire old Table.
        val square = Table(listOf(caption), listOf(emptyList()))
        for (bound in listOf(1L, 720L, 0xffff_ffffL)) {
            val flagged = square.copy(rowsHiddenMaxWidthPx = bound)
            val current = Wire('M').apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = flagged), "bounded") } }
            val bytes = current.document(emptyList(), Sink.Body)
            val plain = Wire('M').apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = square), "bounded") } }
                .document(emptyList(), Sink.Body)
            assertEquals(0x21, bytes[current.at.getValue("bounded.table.flags")].toInt() and 255)
            val tail = current.at.getValue("bounded.table.rowsHiddenMaxWidth")
            assertEquals(current.at.getValue("bounded.table.oldEnd"), tail)
            assertArrayEquals(ByteArray(4) { (bound ushr (it * 8)).toByte() }, bytes.copyOfRange(tail, tail + 4))
            val stripped = changed(replace(bytes, tail, tail + 4, byteArrayOf()), current.at.getValue("bounded.table.flags"), 1)
            assertArrayEquals(plain, stripped)
            assertEquals(square, read(plain).sections.single().blocks.single().table)
            assertEquals(flagged, read(bytes).sections.single().blocks.single().table)
        }
        val audio = Span("link", "Play", "File:Tone.ogg", classes = "wikidict-media wikidict-media-file-546f6e652e6f6767",
            audioControl = AudioControl())
        val audioTable = Table(emptyList(), listOf(listOf(Cell(listOf(audio), false, 1, 1))), rowsHiddenMaxWidthPx = 720)
        val mixed = Block("container", 0, emptyList(), container = Container(listOf(
            Block("table", 0, emptyList(), table = audioTable),
            Block("paragraph", 0, listOf(text("outside")), columnBreakInside = ColumnBreakInside.Auto)),
            ContainerStyle(overflow = ContainerOverflow.Hidden, textWrap = TextWrap.Normal)))
        fun mixedWire(catalog: List<Media>) = Wire('Z', 256 or 4096 or 8192).apply {
            paragraphOverride = { positionedBlock(mixed, "mixedRows") }
        }.document(emptyList(), Sink.Body, mediaValues = catalog)
        assertEquals(mixed, read(mixedWire(listOf(Media("Tone.ogg", "audio", "Tone")))).sections.single().blocks.single())
        reject("Hidden rows still require the complete AUDIO catalog", mixedWire(emptyList()))
    }

    @Test fun tableRowVisibilityRejectsMalformedFlagsBoundsAndIncompatiblePolicies() {
        val cell = Cell(listOf(text("stored")), false, 1, 1)
        val source = Table(emptyList(), listOf(listOf(cell)), rowsHiddenMaxWidthPx = 720)
        for (bound in listOf(0L, -1L, 0x1_0000_0000L)) invalid("Positive u32 bound $bound") {
            source.copy(rowsHiddenMaxWidthPx = bound)
        }
        invalid("No source rows") { source.copy(rows = emptyList()) }
        assertEquals(720L, source.copy(rows = listOf(emptyList())).rowsHiddenMaxWidthPx)
        for (display in listOf(TableDisplay.InlineTable, TableDisplay.InlineBlock)) invalid("Inline policy $display") {
            source.copy(style = TableStyle(display = display))
        }
        for (side in TableFloatSide.entries) invalid("Floated table policy $side") { source.copy(style = TableStyle(floatSide = side)) }
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val margins = ContainerMargins(ContainerMargin.Length(zero), ContainerMargin.Auto, ContainerMargin.Length(zero), ContainerMargin.Auto)
        val box = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 100f), marginValues = margins, containingDirection = TableContainingDirection.Ltr)
        val grid = TableStyle(collapse = TableCollapse.Collapse)
        val viewport = TableBlockViewport(100, box, ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
            grid, TableContainingDirection.Ltr, "ja")
        invalid("Block viewport and hidden rows") { source.copy(blockViewport = viewport) }
        invalid("Float viewport and hidden rows") {
            source.copy(floatViewport = TableFloatViewport(100, TableContainingDirection.Ltr, TableContainingDirection.Ltr, "ja"))
        }
        val mutableRows = mutableListOf(listOf(cell))
        val mutable = source.copy(rows = mutableRows)
        mutableRows.clear()
        invalid("Mutated row policy custody is revalidated") { PresentationSpanVisitor { _, _ -> }.table(mutable) }
        mutableRows.add(listOf(cell))
        PresentationSpanVisitor { _, _ -> }.table(mutable)
        val wire = Wire('M').apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = source), "badRows") } }
        val bytes = wire.document(emptyList(), Sink.Body)
        val flag = wire.at.getValue("badRows.table.flags")
        val tail = wire.at.getValue("badRows.table.rowsHiddenMaxWidth")
        reject("Zero serialized bound", changed32(bytes, tail, 0))
        reject("Pre-M table policy", changed(bytes, 3, 'L'.code))
        for (value in listOf(0x20, 0x22, 0x23, 0x25, 0x27, 0x2d, 0x33, 0x40, 0x41, 0x80, 0x81, 0xff))
            reject("Illegal local table flags $value", changed(bytes, flag, value))
        for (length in 0..3) reject("Truncated u32 tail $length", bytes.copyOf(tail + length))
        reject("Missing policy tail", replace(bytes, tail, tail + 4, byteArrayOf()))
        reject("Unflagged extra policy tail", changed(bytes, flag, 1))
        reject("Trailing bytes", bytes + byteArrayOf(0))
        // Forge a policy onto otherwise valid old source shapes, without constructing an invalid Table first.
        for (style in listOf(TableStyle(display = TableDisplay.InlineTable), TableStyle(floatSide = TableFloatSide.Left))) {
            val plain = source.copy(rowsHiddenMaxWidthPx = null, style = style)
            val raw = Wire('M').apply { paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = plain), "forgedRows") } }
            val data = raw.document(emptyList(), Sink.Body)
            val end = raw.at.getValue("forgedRows.table.oldEnd")
            val forged = changed(replace(data, end, end, byteArrayOf(-48, 2, 0, 0)), raw.at.getValue("forgedRows.table.flags"), 0x21)
            reject("Serialized incompatible style $style", forged)
        }
    }

    @Test fun hiddenContainerOverflowUsesExistingMStyleFieldAndPreservesOldNullVisibleAutoBytes() {
        assertEquals(2, ContainerOverflow.Hidden.ordinal)
        for (overflow in listOf(null, ContainerOverflow.Visible, ContainerOverflow.Auto, ContainerOverflow.Hidden)) {
            val style = ContainerStyle(overflow = overflow)
            val source = Block("container", 0, emptyList(), container = Container(emptyList(), style))
            val wire = Wire('M').apply { paragraphOverride = { positionedBlock(source, "overflow") } }
            val bytes = wire.document(emptyList(), Sink.Body)
            assertEquals(source, read(bytes).sections.single().blocks.single())
            val isolated = Wire('M').isolatedPositionedStyle(style)
            assertArrayEquals(if (overflow == null) byteArrayOf(0, 0, 0, 0)
                else byteArrayOf(0, -128, 0, 0, overflow.ordinal.toByte()), isolated)
            if (overflow != null) {
                val at = wire.at.getValue("overflow.style.overflow")
                assertEquals(overflow.ordinal, bytes[at].toInt() and 255)
                reject("Unknown M overflow", changed(bytes, at, 3))
                val flags = wire.at.getValue("overflow.style.flags")
                val legacy = changed(replace(bytes, flags + 2, flags + 4, byteArrayOf()), 3, 'L'.code)
                if (overflow == ContainerOverflow.Hidden) reject("Hidden retains pre-M refusal", legacy)
                else assertEquals(source, read(legacy).sections.single().blocks.single())
            }
        }
        val hidden = ContainerStyle(overflow = ContainerOverflow.Hidden)
        assertTrue(hidden.atViewport(100f).ownsFormattingContext)
        assertFalse(ContainerStyle(overflow = ContainerOverflow.Visible).atViewport(100f).ownsFormattingContext)
        for (columns in listOf(ContainerColumns(2, StyleLength(StyleLengthUnit.Px, 0f)),
                ContainerColumns(null, StyleLength(StyleLengthUnit.Em, 1f), StyleLength(StyleLengthUnit.Em, 26f))))
            invalid("Hidden cannot silently become a column scrollport") { hidden.copy(columns = columns) }
    }

    @Test fun tableRowVisibilityUsesCompleteSharedItemContentAndTableLimits() {
        val caption = Span("link", "caption", "Caption")
        val child = Span("external_link", "hidden row", "https://example.org/row")
        val first = listOf(Cell(listOf(child), false, 1, 1))
        fun source(totalRows: Int, bound: Long? = 720) = Table(listOf(caption),
            listOf(first) + java.util.Collections.nCopies(totalRows - 1, emptyList<Cell>()), rowsHiddenMaxWidthPx = bound)
        val limit = 1 shl 20
        val modelRows = limit - 4 // Policy, caption, original cell and its span; every row is counted.
        val seen = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { seen.add(it) } }.table(source(modelRows))
        assertEquals(listOf(caption, child), seen); assertSame(caption, seen[0]); assertSame(child, seen[1])
        invalid("Hidden policy shares M+1 model work") { PresentationSpanVisitor { _, _ -> }.table(source(modelRows + 1)) }
        PresentationSpanVisitor { _, _ -> }.table(source(modelRows + 1, null))
        val decoderRows = modelRows - 2 // Section + Table Block, with no extra item for the scalar's four bytes.
        fun literal(rows: Int) = Wire('M').apply {
            paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = source(rows)), "rowBudget") }
        }.document(emptyList(), Sink.Body)
        val decoded = read(literal(decoderRows)).sections.single().blocks.single().table!!
        assertEquals(decoderRows, decoded.rows.size); assertEquals(720L, decoded.rowsHiddenMaxWidthPx)
        assertEquals(listOf(caption), decoded.caption); assertEquals(listOf(child), decoded.rows.first().single().spans)
        reject("Hidden policy shares M+1 wire work", literal(decoderRows + 1))
        val leaf = Block("table", 0, emptyList(), table = source(1))
        for (depth in listOf(16, 17)) {
            val wire = Wire('O').apply { paragraphOverride = { positionedBlock(leaf, "contentBound") } }
            val bytes = wire.document(emptyList(), Sink.Container, containers = depth)
            if (depth == 16) assertEquals(1, read(bytes).sections.size)
            else reject("Hidden rows do not reset content depth", bytes)
        }
        for ((header, depths) in listOf('M' to listOf(16, 17), 'T' to listOf(32, 33))) for (depth in depths) {
            val bytes = Wire(header).apply { paragraphOverride = { tableChain(depth, mixed = true, rowsHiddenMaxWidthPx = 720) } }
                .document(listOf(child), Sink.Body)
            if (depth == depths.first()) {
                val bounds = mutableListOf<Long?>()
                PresentationSpanVisitor { _, _ -> }.apply { onTable = { value, _, _ -> bounds.add(value.rowsHiddenMaxWidthPx) } }
                    .blocks(read(bytes).sections.single().blocks)
                assertEquals(List(depth) { 720L }, bounds)
            } else reject("Hidden rows do not reset table depth $header", bytes)
        }
        val cycleBlocks = mutableListOf<Block>()
        val cyclic = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = cycleBlocks))), rowsHiddenMaxWidthPx = 720)
        cycleBlocks.add(Block("table", 0, emptyList(), table = cyclic))
        invalid("Cyclic hidden rows remain bounded") { PresentationSpanVisitor { _, _ -> }.table(cyclic) }
    }

    private fun atomicWireLayout(lineHeight: InlineLineHeight? = null, wrap: TextWrap = TextWrap.BreakWord): InlineBoxAtomicLayout {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        return InlineBoxAtomicLayout(StyleLength(StyleLengthUnit.Em, 1f), StyleLength(StyleLengthUnit.Em, 1f),
            StyleEdges(zero, zero, zero, zero), ContainerBoxSizing.BorderBox, InlineBoxOverlayTextAlign.Start, wrap, lineHeight)
    }
    private fun atomicWireOwner(layout: InlineBoxAtomicLayout = atomicWireLayout(), value: String = "\u00a0",
        direction: String = "", explicitPolicies: Boolean = false, family: ContainerFontFamily? = null): Span {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdge.None
        val style = InlineTextStyle(fontNormalized = true, lineHeight = layout.lineHeight.takeIf { explicitPolicies },
            wrap = layout.wrap.takeIf { explicitPolicies })
        val child = Span("text", value, language = "hu", classes = "atomic-swatch", direction = direction,
            fontScale = .81f, fontScaleBasis = FontScaleBasis.NormalBody, fontFeatures = FontFeaturePolicy.Normal,
            fontFamily = family, inlineStyle = style, foreground = "#123456", background = "#ffffff",
            tooltip = "original child", explanation = "original advice")
        return child.copy(text = "", foreground = "#654321", background = "#20a0ff", tooltip = "original owner",
            inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), InlineBoxBorderEdges(none, none, none, none),
                spans = listOf(child), atomicLayout = layout))
    }
    private fun atomicWireFont(value: Span) = InlineFontSnapshot(value.fontScale, value.fontScaleBasis,
        value.small, value.superscript, value.subscript, true, value.bold, value.italic, value.code,
        value.language, value.classes, value.role, value.fontFeatures, value.fontFamily)

    @Test fun atomicInlineBoxLocalFlagRetainsRealNbspAndNullBytesAcrossEveryExistingSink() {
        val source = atomicWireOwner()
        val group = checkNotNull(source.inlineBoxGroup)
        val plain = source.copy(inlineBoxGroup = group.copy(atomicLayout = null))
        for (sink in Sink.entries) {
            val wire = Wire('Y', 4)
            val bytes = wire.document(listOf(source), sink, headingTitle = "\u00a0")
            val actual = selected(read(bytes), sink)
            assertEquals("$sink complete source", source, actual)
            assertEquals("\u00a0", rubyGraphicalProjection(listOf(actual)).text)
            assertEquals(.81f, checkNotNull(actual.fontScale), 0f)
            assertEquals(.81f, checkNotNull(actual.inlineBoxGroup!!.spans.single().fontScale), 0f)
            assertFalse(actual.hasInternalAction()); assertEquals("original child", actual.inlineBoxGroup!!.spans.single().tooltip)
            val start = wire.at.getValue("root.0.box.atomic")
            assertEquals(wire.at.getValue("root.0.box.childrenEnd"), start)
            assertEquals(34, wire.at.getValue("root.0.box.atomic.end") - start)
            val oneEm = byteArrayOf(1, 0, 0, -128, 63)
            assertArrayEquals(oneEm + oneEm + ByteArray(20) + byteArrayOf(1, 0, 1, 0), bytes.copyOfRange(start, start + 34))
            val fields = wire.at.getValue("root.0.fontFields")
            assertEquals(0x40, bytes[fields].toInt() and 0x40)
            val withoutSuffix = replace(bytes, start, start + 34, byteArrayOf())
            val old = changed(withoutSuffix, fields, withoutSuffix[fields].toInt() and 0xbf)
            assertArrayEquals("Only the local flag and34B suffix differ", Wire('Y', 4).document(listOf(plain), sink,
                headingTitle = "\u00a0"), old)
            assertEquals(plain, selected(read(old), sink))
        }
        for (sizing in ContainerBoxSizing.entries) for (align in InlineBoxOverlayTextAlign.entries)
            for (wrap in listOf(TextWrap.Normal, TextWrap.BreakWord)) {
                val owner = atomicWireOwner(atomicWireLayout(wrap = wrap).copy(boxSizing = sizing, textAlign = align),
                    value = "Latin \u00a0", direction = "ltr")
                assertEquals(owner, read(Wire('Y', 4).document(listOf(owner))).displayTitle.single())
            }
        val audio = Span("link", "Tone.ogg", "File:Tone.ogg",
            classes = "wikidict-media wikidict-media-file-546f6e652e6f6767", audioControl = AudioControl())
        val catalog = listOf(Media("Tone.ogg", "audio", "original audio"))
        val mixed = read(Wire('Z', 4 or 8192).document(listOf(source, audio), mediaValues = catalog))
        assertEquals(listOf(source, audio), mixed.displayTitle); assertEquals(catalog, mixed.media)
    }

    @Test fun atomicInlineBoxKeepsExplicitLineHeightAndExistingFontFeatureCensusIndependent() {
        val plain = atomicWireOwner()
        val font = atomicWireFont(plain)
        val heights = listOf<InlineLineHeight?>(null,
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx)),
            InlineLineHeight.Computed(InlineComputedLength(18f, FontScaleBasis.NormalBody)),
            InlineLineHeight.FontRelative(1.5f, font))
        for (height in heights) for (explicit in listOf(false, true)) {
            val source = atomicWireOwner(atomicWireLayout(height), direction = "rtl", explicitPolicies = explicit)
            val features = if (explicit) 16 else 0 // Atomic wrap itself is not the ordinary inline-style feature.
            assertEquals(source, read(Wire('Y', 4).document(listOf(source), features = features)).displayTitle.single())
            reject("Exact ordinary text-flow census", Wire('Y', 4).document(listOf(source), features = features xor 16))
        }
        val familyOwner = atomicWireOwner(family = ContainerFontFamily.SansSerif)
        val familyHeight = InlineLineHeight.FontRelative(1.25f, atomicWireFont(familyOwner))
        val family = atomicWireOwner(atomicWireLayout(familyHeight), family = ContainerFontFamily.SansSerif)
        assertEquals(family, read(Wire('Y', 4).document(listOf(family), features = 4)).displayTitle.single())
        reject("Atomic snapshot family retains existing census", Wire('Y', 4).document(listOf(family)))
        reject("No invented family census for a null family", Wire('Y', 4).document(listOf(plain), features = 4))
        val wrongHeight = InlineLineHeight.FontRelative(1f, font.copy(fontScale = 1f))
        invalid("Font-relative line-height belongs to the original declaring font") { atomicWireOwner(atomicWireLayout(wrongHeight)) }
        val computed = atomicWireLayout(InlineLineHeight.Computed(InlineComputedLength(20f, FontScaleBasis.CssPx)))
        val inherited = atomicWireOwner(computed)
        val same = inherited.copy(inlineStyle = inherited.inlineStyle!!.copy(lineHeight = computed.lineHeight))
        assertEquals(computed.lineHeight, same.inlineStyle!!.lineHeight)
        invalid("A different owner line-height is not an alias") {
            inherited.copy(inlineStyle = inherited.inlineStyle!!.copy(lineHeight = heights[1]))
        }
    }

    @Test fun atomicInlineBoxRequiresPositiveMatchingMetricsAndPlainNoncollapsibleOriginalChildren() {
        val source = atomicWireOwner()
        val group = checkNotNull(source.inlineBoxGroup)
        val layout = checkNotNull(group.atomicLayout)
        val child = group.spans.single()
        fun childOwner(value: Span) = source.copy(inlineBoxGroup = group.copy(spans = listOf(value)))
        for (value in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            invalid("Positive finite width") { layout.copy(width = StyleLength(StyleLengthUnit.Px, value)) }
            invalid("Positive finite height") { layout.copy(height = StyleLength(StyleLengthUnit.Em, value)) }
        }
        invalid("No nowrap atomic policy") { layout.copy(wrap = TextWrap.NoWrap) }
        for (value in listOf(null, 0f, -1f, Float.NaN, Float.POSITIVE_INFINITY))
            invalid("Positive known owner font") { source.copy(fontScale = value) }
        assertEquals(0f, checkNotNull(InlineFontSnapshot(0f, FontScaleBasis.NormalBody, fontNormalized = true).fontScale), 0f)
        invalid("Positive known child font") { childOwner(child.copy(fontScale = 0f)) }
        invalid("Matching zero owner and child fonts still require positive declaring size") {
            source.copy(fontScale = 0f, inlineBoxGroup = group.copy(spans = listOf(child.copy(fontScale = 0f))))
        }
        for (change in listOf<(Span) -> Span>(
            { it.copy(fontScale = 1f) }, { it.copy(fontScaleBasis = FontScaleBasis.CssPx) },
            { it.copy(fontScaleBasis = FontScaleBasis.Context) }, { it.copy(fontFamily = ContainerFontFamily.SansSerif) },
            { it.copy(fontFeatures = null) }, { it.copy(language = "en") }, { it.copy(classes = "other") },
            { it.copy(role = "example") }, { it.copy(bold = true) }, { it.copy(italic = true) }, { it.copy(code = true) },
            { it.copy(small = true) }, { it.copy(superscript = true) }, { it.copy(subscript = true) },
            { it.copy(underline = true) }, { it.copy(strike = true) }, { it.copy(direction = "ltr") },
            { it.copy(inlineStyle = null) }, { it.copy(inlineStyle = InlineTextStyle(fontNormalized = false)) },
            { it.copy(inlineStyle = it.inlineStyle!!.copy(wrap = TextWrap.Normal)) },
            { it.copy(inlineStyle = it.inlineStyle!!.copy(cursor = InlineCursor.Help)) },
            { it.copy(inlineStyle = it.inlineStyle!!.copy(baselineShift = InlineComputedLength(1f, FontScaleBasis.CssPx))) }))
            invalid("Every child metric remains the original owner metric") { childOwner(change(child)) }
        for (direction in listOf("auto", "rtl")) invalid("No unresolved or mismatched direction") { childOwner(child.copy(direction = direction)) }
        invalid("Unresolved owner direction") { atomicWireOwner(direction = "auto") }
        for (value in listOf("", " ", "   ", "x\t", "x\n", "x\r", "x\u000c", "x\u0000", "x\u007f", "x\u2028", "x\u2029"))
            invalid("No empty, collapsible-only or forced-control body") { childOwner(child.copy(text = value)) }
        assertEquals(" \u00a0 ", childOwner(child.copy(text = " \u00a0 ")).inlineBoxGroup!!.spans.single().text)
        for (change in listOf<(Span) -> Span>({ it.copy(trail = "!") }, { it.copy(kind = "link", target = "Target") },
            { it.copy(kind = "external_link", target = "https://example.org") }, { it.copy(kind = "line_break") },
            { it.copy(image = InlineImage("Probe.svg")) }, { it.copy(classes = "wikidict-media") }))
            invalid("Atomic children cannot carry actions, media, or structural content") { childOwner(change(child)) }
        invalid("Atomic owner cannot become an action") { source.copy(kind = "link", target = "Target") }
        invalid("Atomic inside Ruby") { owner(listOf(base(source))) }
        invalid("Atomic inside U") { Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Px, 1f), StyleLength(StyleLengthUnit.Px, 0f), listOf(source))) }
        invalid("Atomic inside Box") { Span("text", "", inlineBoxGroup = group.copy(atomicLayout = null, spans = listOf(source))) }
        invalid("Atomic inside V") { Span("link", "", "Target", inlineActionGroup = InlineActionGroup(listOf(source))) }
        val overlays = mutableListOf<InlineBoxOverlay>()
        val children = mutableListOf(child)
        val retained = source.copy(inlineBoxGroup = group.copy(overlays = overlays, spans = children))
        val entry = Entry("Atomic", listOf(retained), "language", "Hungarian", "hu", emptyList(), emptyList())
        overlays.add(InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            left = InlineBoxInset(StyleWidthUnit.Px, 0f)), group.border))
        invalid("Mutated overlay cannot bypass complete validation") { entry.copy() }
        overlays.clear(); children[0] = child.copy(fontScale = 1f)
        invalid("Mutated child font cannot bypass complete validation") { entry.copy() }
        children[0] = child
        assertSame(retained, entry.copy().displayTitle.single())
        assertSame(child, retained.inlineBoxGroup!!.spans.single())
        assertEquals("#20a0ff", retained.background); assertEquals("#ffffff", child.background)
    }

    @Test fun atomicInlineBoxRejectsOrphanFlagsMalformedSuffixesAndForgedDomains() {
        val source = atomicWireOwner()
        val wire = Wire('Y', 4)
        val bytes = wire.document(listOf(source))
        val fields = wire.at.getValue("root.0.fontFields")
        val start = wire.at.getValue("root.0.box.atomic")
        reject("Reserved bit0x80", changed(bytes, fields, bytes[fields].toInt() or 0x80))
        reject("No same-owner Box", changed(bytes, wire.at.getValue("root.0.box"), 0))
        reject("Suffix requires local0x40", changed(bytes, fields, bytes[fields].toInt() and 0xbf))
        reject("No extra nullable tag", replace(bytes, start, start, byteArrayOf(1)))
        reject("Strict EOF", bytes + byteArrayOf(0))
        for (count in 0 until 34) reject("Incomplete atomic suffix $count", bytes.copyOf(start + count))
        for (field in listOf("width", "height", "margin0", "margin1", "margin2", "margin3")) {
            val at = wire.at.getValue("root.0.box.atomic.$field")
            for (unit in listOf(2, 255)) reject("Only px/em $field", changed(bytes, at, unit))
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) reject("Finite nonnegative $field",
                changed32(bytes, at + 1, value.toRawBits().toLong() and 0xffff_ffffL))
            if (field == "width" || field == "height") reject("Positive $field", changed32(bytes, at + 1, 0))
        }
        for ((field, invalidTag) in listOf("sizing" to 2, "align" to 4, "wrap" to 2, "lineHeight" to 3))
            reject("Unknown atomic $field", changed(bytes, wire.at.getValue("root.0.box.atomic.$field"), invalidTag))
        val zeroRadius = changed(replace(bytes, start, start, ByteArray(5)), fields, bytes[fields].toInt() or 0x20)
        reject("Radius and atomic are mutually exclusive even at0", zeroRadius)
        val oldWire = Wire('O'); val old = oldWire.document(listOf(text("plain")))
        reject("Old header rejects atomic local flag", changed(old, oldWire.at.getValue("root.0.fontFields"), 0x40))
        val body = BodyTypography(InlineFontSnapshot(1f, FontScaleBasis.NormalBody, fontNormalized = true))
        val noBoxWire = Wire('Y', 2); val noBox = noBoxWire.document(listOf(text("plain")), bodyTypography = body)
        reject("Existing global4 required", changed(noBox, noBoxWire.at.getValue("root.0.fontFields"), 0x40))
        val siblingWire = Wire('Y', 4); val siblings = siblingWire.document(listOf(source, text("plain")))
        val sibling = siblingWire.at.getValue("root.1.fontFields")
        reject("Sibling cannot borrow atomic owner", changed(siblings, sibling, siblings[sibling].toInt() or 0x40))
        // Literal mutations bypass typed construction but retain the existing ordinary field framing.
        reject("Serialized owner font cannot be zero", changed32(bytes, fields + 1, 0))
        val childDirection = wire.at.getValue("root.0.box.body.0.direction")
        reject("Serialized mismatched child direction", replace(bytes, childDirection, childDirection + 4,
            byteArrayOf(3, 0, 0, 0) + "rtl".encodeToByteArray()))
        val childText = wire.at.getValue("root.0.box.body.0.text")
        reject("Serialized collapsible-only body", replace(bytes, childText, childText + 6, byteArrayOf(1, 0, 0, 0, 32)))
        val childStyle = wire.at.getValue("root.0.box.body.0.style.flags")
        reject("Serialized child font must be normalized", changed(bytes, childStyle, bytes[childStyle].toInt() and 0xf7))
        assertEquals(source, read(bytes).displayTitle.single())
    }

    @Test fun atomicInlineBoxChargesOneItemAndRetainsCompleteIgnoredPrefixAndDepthWork() {
        val limit = 1 shl 20
        val source = atomicWireOwner()
        val child = source.inlineBoxGroup!!.spans.single()
        fun table(count: Int) = Table(listOf(source), java.util.Collections.nCopies(count, emptyList<Cell>()))
        val seen = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { seen.add(it) } }.table(table(limit - 3))
        assertEquals(listOf(source, child), seen); assertSame(source, seen[0]); assertSame(child, seen[1])
        invalid("Owner, child and atomic object share exact model M+1") {
            PresentationSpanVisitor { _, _ -> }.table(table(limit - 2))
        }
        fun literal(count: Int) = Wire('Y', 4).apply {
            paragraphOverride = { positionedBlock(Block("table", 0, emptyList(), table = table(count)), "atomicBudget") }
        }.document(emptyList(), Sink.Body)
        val decoded = read(literal(limit - 5)).sections.single().blocks.single().table!! // Section + Block + owner + child + atom.
        assertEquals(limit - 5, decoded.rows.size); assertEquals(source, decoded.caption.single())
        reject("Exact wire M+1", literal(limit - 4))
        for (depth in listOf(15, 16)) {
            val data = Wire('Y', 4).document(listOf(source), Sink.Container, containers = depth)
            if (depth == 15) assertEquals(1, read(data).sections.size)
            else reject("Atomic child does not reset content depth", data)
        }
        for (depth in listOf(32, 33)) {
            val data = Wire('Y', 4).apply { paragraphOverride = { tableChain(depth, mixed = true) } }
                .document(listOf(source), Sink.Body)
            if (depth == 32) assertEquals(1, read(data).sections.size)
            else reject("Atomic child does not reset table depth", data)
        }
        for (kind in listOf("table", "rule")) {
            fun raw(spans: List<Span>) = Block(kind, 0, spans,
                table = Table(emptyList(), emptyList()).takeIf { kind == "table" })
            val calls = mutableListOf<List<Span>>()
            val originals = mutableListOf<Span>()
            PresentationSpanVisitor { spans, _ -> calls.add(spans) }.apply { onSpan = { originals.add(it) } }
                .block(raw(listOf(source)))
            assertEquals(listOf(source, child), originals)
            assertTrue("Ignored prefix never becomes a display callback", calls.all { it.isEmpty() })
            val legacy = java.util.Collections.nCopies(limit + 1, text("ignored legacy"))
            PresentationSpanVisitor { _, _ -> }.block(raw(legacy)) // Absence scan is non-charging, proportional to supplied input.
            invalid("An actual atomic owner selects the complete ignored-prefix budget") {
                PresentationSpanVisitor { _, _ -> }.block(raw(legacy + source))
            }
            val mutable = mutableListOf(text("ordinary"))
            val wrapper = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
                StyleLength(StyleLengthUnit.Px, 1f), StyleLength(StyleLengthUnit.Px, 0f), mutable))
            val held = raw(listOf(wrapper))
            mutable[0] = source
            invalid("Nested atomic discovery revalidates the whole original prefix") { PresentationSpanVisitor { _, _ -> }.block(held) }
            mutable[0] = wrapper
            PresentationSpanVisitor { _, _ -> }.block(held) // Identity-aware absence scan terminates the old ignored cycle.
        }
    }
    private fun percentCircleOwner(radius: StyleWidth? = StyleWidth(StyleWidthUnit.Percent, 50f),
        dotted: Boolean = true): Span {
        val pad = StyleLength(StyleLengthUnit.Em, .2f)
        val width = StyleLength(StyleLengthUnit.Px, 1f)
        val color = InlineBoxColor.Rgb("#777777")
        val edge = if (dotted) InlineBoxBorderEdge.Dotted(width, color) else InlineBoxBorderEdge.Solid(width, color)
        val child = Span("text", "e", language = "mg", small = true, foreground = "#123456")
        return Span("text", "", language = "mg", small = true, tooltip = "Original MG advisory — é",
            explanation = "original advice", inlineStyle = InlineTextStyle(cursor = InlineCursor.Help),
            inlineBoxGroup = InlineBoxGroup(StyleEdges(pad, pad, pad, pad),
                InlineBoxBorderEdges(edge, edge, edge, edge), spans = listOf(child), radius = radius))
    }

    @Test fun inlineBoxPercentRadiusRetainsRawValuesDottedEdgesAndOriginalAdvisoryOwners() {
        for (dotted in listOf(false, true)) for (value in listOf(0f, 50f, 75f, 150f)) {
            val source = percentCircleOwner(StyleWidth(StyleWidthUnit.Percent, value), dotted)
            val group = checkNotNull(source.inlineBoxGroup)
            val child = group.spans.single()
            assertEquals(StyleWidth(StyleWidthUnit.Percent, value), group.radius)
            assertEquals("e", rubyGraphicalProjection(listOf(source)).text)
            assertTrue(source.small); assertTrue(child.small)
            assertEquals("Original MG advisory — é", source.tooltip)
            assertEquals(InlineCursor.Help, source.inlineStyle!!.cursor)
            assertNull(child.tooltip); assertFalse(source.hasInternalAction()); assertFalse(child.hasInternalAction())
            val copied = source.copy(inlineBoxGroup = group.copy())
            assertSame(child, copied.inlineBoxGroup!!.spans.single())
            val noRadius = group.copy(radius = null)
            assertNull(noRadius.radius); assertSame(child, noRadius.spans.single())
        }
        val square = percentCircleOwner(null)
        val group = square.inlineBoxGroup!!
        val edge = group.border.top as InlineBoxBorderEdge.Dotted
        val zero = edge.copy(width = StyleLength(StyleLengthUnit.Em, 0f))
        val zeroEdges = InlineBoxBorderEdges(zero, zero, zero, zero)
        assertEquals(StyleWidth(StyleWidthUnit.Px, 0f), group.copy(border = zeroEdges,
            radius = StyleWidth(StyleWidthUnit.Px, 0f)).radius)
        for (value in listOf(0f, 50f)) invalid("Em remains outside the radius domain") {
            group.copy(radius = StyleWidth(StyleWidthUnit.Em, value))
        }
        for (unit in listOf(StyleWidthUnit.Px, StyleWidthUnit.Percent))
            for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
                invalid("Both admitted units require finite nonnegative values") { group.copy(radius = StyleWidth(unit, value)) }
        val mismatches = listOf<InlineBoxBorderEdge>(InlineBoxBorderEdge.Solid(edge.width, edge.color),
            edge.copy(width = StyleLength(StyleLengthUnit.Px, 2f)),
            edge.copy(width = StyleLength(StyleLengthUnit.Em, 1f)),
            edge.copy(color = InlineBoxColor.Rgb("#777778")), InlineBoxBorderEdge.None, InlineBoxBorderEdge.Hidden)
        for (bad in mismatches) {
            val mixed = group.copy(border = group.border.copy(left = bad))
            assertNull(mixed.radius)
            invalid("A radius requires a uniform style, width and color") {
                mixed.copy(radius = StyleWidth(StyleWidthUnit.Percent, 50f))
            }
        }
        for (color in listOf(InlineBoxColor.CurrentColor, InlineBoxColor.Transparent,
            InlineBoxColor.LightDark("#777777", "#777777"))) {
            val bad = edge.copy(color = color)
            val uniform = group.copy(border = InlineBoxBorderEdges(bad, bad, bad, bad))
            assertNull(uniform.radius)
            invalid("Dotted rounded borders require opaque canonical RGB") {
                uniform.copy(radius = StyleWidth(StyleWidthUnit.Percent, 50f))
            }
        }
        val atomic = atomicWireOwner().inlineBoxGroup!!
        invalid("Percentage radius cannot enter an atomic layout") {
            atomic.copy(radius = StyleWidth(StyleWidthUnit.Percent, 0f))
        }
        val overlays = mutableListOf<InlineBoxOverlay>()
        val retained = percentCircleOwner().copy(inlineBoxGroup = percentCircleOwner().inlineBoxGroup!!.copy(overlays = overlays))
        val entry = Entry("Circle", listOf(retained), "language", "Malagasy", "mg", emptyList(), emptyList())
        overlays += InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Px, 0f)), group.border)
        invalid("Mutation cannot bypass the deep radius guard") { retained.copy() }
        invalid("Complete Entry validation retains the overlay restriction") { entry.copy() }
        overlays.clear()
        assertSame(retained, entry.copy().displayTitle.single())
    }

    @Test fun inlineBoxPercentRadiusUsesSameFiveByteSlotAtEverySinkAndKeepsLegacyPixels() {
        val literals = listOf(0f to byteArrayOf(2, 0, 0, 0, 0),
            50f to byteArrayOf(2, 0, 0, 72, 66), 75f to byteArrayOf(2, 0, 0, -106, 66))
        for (dotted in listOf(false, true)) for ((value, literal) in literals) for (sink in Sink.entries) {
            val source = percentCircleOwner(StyleWidth(StyleWidthUnit.Percent, value), dotted)
            val wire = Wire('Y', 4)
            val bytes = wire.document(listOf(source), sink, headingTitle = "e")
            val decoded = selected(read(bytes), sink)
            assertEquals("$sink complete source", source, decoded)
            assertFalse(decoded.hasInternalAction())
            assertEquals("e", rubyGraphicalProjection(listOf(decoded)).text)
            val offset = wire.at.getValue("root.0.box.radius")
            assertEquals(wire.at.getValue("root.0.box.childrenEnd"), offset)
            assertEquals(offset + 5, wire.at.getValue("root.0.box.end"))
            assertArrayEquals(literal, bytes.copyOfRange(offset, offset + 5))
            val field = wire.at.getValue("root.0.fontFields")
            assertEquals(0x20, bytes[field].toInt() and 0x20)
            val px = source.copy(inlineBoxGroup = source.inlineBoxGroup!!.copy(radius = StyleWidth(StyleWidthUnit.Px, value)))
            val pxBytes = Wire('Y', 4).document(listOf(px), sink, headingTitle = "e")
            assertArrayEquals("Only the scalar unit differs", changed(bytes, offset, 0), pxBytes)
            assertEquals(px, selected(read(pxBytes), sink))
            val square = source.copy(inlineBoxGroup = source.inlineBoxGroup!!.copy(radius = null))
            var stripped = replace(bytes, offset, offset + 5, byteArrayOf())
            stripped = changed(stripped, field, stripped[field].toInt() and 0xdf)
            assertArrayEquals("Null retains the old square shape bytes", Wire('Y', 4).document(listOf(square), sink,
                headingTitle = "e"), stripped)
            assertEquals(square, selected(read(stripped), sink))
        }
        // The pre-existing pixel literals remain literal and need no new capability.
        for ((value, suffix) in listOf(0f to ByteArray(5), 2f to byteArrayOf(0, 0, 0, 0, 64))) {
            val wire = Wire('Y', 4)
            val bytes = wire.document(listOf(roundedWireOwner(StyleWidth(StyleWidthUnit.Px, value))))
            val offset = wire.at.getValue("root.0.box.radius")
            assertArrayEquals(suffix, bytes.copyOfRange(offset, offset + 5))
        }
        val owner = percentCircleOwner()
        val action = Span("link", "original action", "Target", targetFragment = "sense")
        val external = Span("external_link", "outside", "https://example.test/original")
        val sources = listOf(owner, text("\u2009"), action, text("\u2009"), external)
        val decoded = read(Wire('Y', 4).document(sources)).displayTitle
        assertEquals(sources, decoded)
        assertEquals("e\u2009original action\u2009outside", rubyGraphicalProjection(decoded).text)
        assertFalse(decoded[0].hasInternalAction()); assertEquals(EntryLink("Target", "sense"), decoded[2].entryLink())
        assertEquals(external.target, decoded[4].target)
        val family = owner.copy(fontFamily = ContainerFontFamily.SansSerif)
        assertEquals(family, read(Wire('Y', 4).document(listOf(family), features = 4)).displayTitle.single())
        reject("Existing font-family census still applies", Wire('Y', 4).document(listOf(family)))
        reject("Radius does not earn unrelated text-flow debt", Wire('Y', 4).document(listOf(owner), features = 16))
        val childGroup = owner.copy(tooltip = "nested original title")
        val nested = percentCircleOwner(null).copy(inlineBoxGroup = percentCircleOwner(null).inlineBoxGroup!!.copy(spans = listOf(childGroup)))
        val nestedWire = Wire('Y', 4); val bytes = nestedWire.document(listOf(nested))
        assertEquals(nested, read(bytes).displayTitle.single())
        assertEquals(0, bytes[nestedWire.at.getValue("root.0.fontFields")].toInt() and 0x20)
        assertEquals(0x20, bytes[nestedWire.at.getValue("root.0.box.body.0.fontFields")].toInt() and 0x20)
    }

    @Test fun inlineBoxPercentRadiusRejectsMalformedUnitsAndCannotBorrowOtherPayloadOwners() {
        val source = percentCircleOwner()
        val wire = Wire('Y', 4); val bytes = wire.document(listOf(source))
        val at = wire.at.getValue("root.0.box.radius"); val fields = wire.at.getValue("root.0.fontFields")
        for (unit in listOf(1, 3, 255)) reject("Only radius px0 and percent2", changed(bytes, at, unit))
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
            reject("Percentage scalar must remain finite nonnegative", changed32(bytes, at + 1, value.toRawBits().toLong() and 0xffff_ffffL))
        for (count in 0 until 5) reject("Fixed five-byte suffix cannot truncate", bytes.copyOf(at + count))
        reject("No nullable prefix in the scalar slot", replace(bytes, at, at, byteArrayOf(1)))
        reject("Strict final EOF", bytes + byteArrayOf(0))
        reject("Local flag is mandatory", changed(bytes, fields, bytes[fields].toInt() and 0xdf))
        reject("Actual same-owner Box is mandatory", changed(bytes, wire.at.getValue("root.0.box"), 0))
        reject("Reserved local0x80 remains refused", changed(bytes, fields, bytes[fields].toInt() or 0x80))
        val child = wire.at.getValue("root.0.box.body.0.fontFields")
        reject("A child cannot borrow its owner's radius", changed(bytes, child, bytes[child].toInt() or 0x20))
        val body = BodyTypography(InlineFontSnapshot(1f, FontScaleBasis.NormalBody, fontNormalized = true))
        val absentWire = Wire('Y', 2); val absent = absentWire.document(listOf(text("ordinary")), bodyTypography = body)
        reject("Box capability remains mandatory", changed(absent, absentWire.at.getValue("root.0.fontFields"), 0x20))
        val atomicWire = Wire('Y', 4); val atomic = atomicWire.document(listOf(atomicWireOwner()))
        val start = atomicWire.at.getValue("root.0.box.atomic")
        val field = atomicWire.at.getValue("root.0.fontFields")
        val both = replace(atomic, start, start, byteArrayOf(2, 0, 0, 72, 66))
        reject("Percent and atomic tails do not authorize the combined domain", changed(both, field, both[field].toInt() or 0x20))
        assertEquals(source, read(bytes).displayTitle.single())
    }

    @Test fun inlineBoxPercentDottedRadiusKeepsOneSharedBudgetAndBothDepthLimits() {
        val source = percentCircleOwner()
        val limit = 1 shl 20
        fun block(count: Int) = Block("table", 0, emptyList(), table = Table(listOf(source),
            java.util.Collections.nCopies(count, emptyList<Cell>())))
        fun model(count: Int) = Entry("Budget", emptyList(), "language", "Malagasy", "mg",
            listOf(Section(2, "Body", listOf(block(count)))), emptyList())
        // Original Block, original Box owner and real child; radius adds no policy item.
        assertEquals(limit - 3, model(limit - 3).sections.single().blocks.single().table!!.rows.size)
        invalid("Percentage radius cannot reset complete model work") { model(limit - 2) }
        fun literal(count: Int) = Wire('Y', 4).apply {
            paragraphOverride = { positionedBlock(block(count), "percentBudget") }
        }.document(emptyList(), Sink.Body)
        assertEquals(limit - 4, read(literal(limit - 4)).sections.single().blocks.single().table!!.rows.size)
        reject("Percentage radius cannot reset complete decode work", literal(limit - 3))
        for (depth in listOf(15, 16)) {
            val bytes = Wire('Y', 4).document(listOf(source), Sink.Container, containers = depth)
            if (depth == 15) assertEquals(1, read(bytes).sections.size) else reject("Content depth stays16", bytes)
        }
        for (depth in listOf(32, 33)) {
            val bytes = Wire('Y', 4).apply { paragraphOverride = { tableChain(depth, mixed = true) } }
                .document(listOf(source), Sink.Body)
            if (depth == 32) assertEquals(1, read(bytes).sections.size) else reject("Table depth stays32", bytes)
        }
    }

    private fun opacityTable(style: CellStyle?, spans: List<Span> = listOf(
        Span("link", "kept action", "Original target", targetFragment = "part", tooltip = "Original title"))) =
        Table(emptyList(), listOf(listOf(Cell(spans, false, 1, 1, background = "#123456", style = style))))

    @Test fun cellOpacityModelKeepsExplicitZeroOneAndOriginalChildrenWithoutNewCellRestrictions() {
        for (alpha in listOf(0f, .2f, 1f, -0f)) {
            val style = CellStyle(opacity = alpha)
            assertEquals(alpha.toRawBits(), checkNotNull(style.opacity).toRawBits())
            assertEquals(style, style.copy())
            val empty = Cell(emptyList(), false, 1, 1, style = style)
            PresentationSpanVisitor { _, _ -> }.table(Table(emptyList(), listOf(listOf(empty))))
        }
        invalid("The all-null old style remains empty") { CellStyle() }
        val source = CellStyle(border = StyleBorder.None)
        assertNull(source.opacity)
        assertEquals(source, source.copy(opacity = null))
        for (alpha in listOf(-Float.MIN_VALUE, -1f, Math.nextUp(1f), Float.NaN,
            Float.NEGATIVE_INFINITY, Float.POSITIVE_INFINITY)) {
            invalid("Invalid direct opacity $alpha") { CellStyle(opacity = alpha) }
            invalid("Copies revalidate opacity $alpha") { source.copy(opacity = alpha) }
        }
        val span = Span("link", "original", "Original target", tooltip = "title", background = "#abcdef")
        val rows = listOf(listOf(Cell(listOf(span), true, 2, 1, background = "#102030", style = CellStyle(opacity = 0f))))
        val table = Table(listOf(text("caption")), rows)
        val seen = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { seen.add(it) } }.table(table)
        assertSame(rows, table.rows)
        assertSame(span, seen.last())
        assertEquals("Original target", seen.last().target)
        assertEquals("#102030", table.rows.single().single().background)
        assertEquals("#abcdef", seen.last().background)
    }

    @Test fun cellOpacityMUsesLiteralScalarAfterAllOldFieldsAndKeepsNullBytes() {
        val name = "opacity.table.row0.cell0.style"
        fun encode(style: CellStyle?): Pair<Wire, ByteArray> {
            val wire = Wire('M').apply { paragraphOverride = {
                positionedBlock(Block("table", 0, emptyList(), table = opacityTable(style)), "opacity") } }
            return wire to wire.document(emptyList(), Sink.Body)
        }
        for ((alpha, literal) in listOf(0f to byteArrayOf(0, 0, 0, 0),
            .2f to byteArrayOf(-51, -52, 76, 62), 1f to byteArrayOf(0, 0, -128, 63))) {
            val style = CellStyle(opacity = alpha)
            val (wire, bytes) = encode(style)
            assertArrayEquals("DPRM".encodeToByteArray(), bytes.copyOfRange(0, 4))
            val start = wire.at.getValue("$name.presence")
            val tail = wire.at.getValue("$name.opacity")
            assertEquals(2, tail - start)
            assertArrayEquals(byteArrayOf(1, 16) + literal, bytes.copyOfRange(start, tail + 4))
            assertEquals(opacityTable(style), read(bytes).sections.single().blocks.single().table)
            val (_, absent) = encode(null)
            assertArrayEquals(absent, replace(bytes, start, tail + 4, byteArrayOf(0)))
            assertNull(read(absent).sections.single().blocks.single().table!!.rows.single().single().style)
        }
        val px = StyleLength(StyleLengthUnit.Px, 2f)
        val style = CellStyle(border = StyleBorder.Solid(px, "#456789"), padding = StyleEdges(px, px, px, px),
            textAlign = CellTextAlign.Right, width = StyleWidth(StyleWidthUnit.Percent, 75f), minWidth = px,
            verticalAlign = CellVerticalAlign.Middle,
            lineHeight = CellLineHeight(CellLineHeightValue.Length(CellFixedLineHeight(17f, FontScaleBasis.CssPx)),
                CellTextStrut(.8f, FontScaleBasis.NormalBody)), opacity = .2f)
        val (wire, bytes) = encode(style)
        assertEquals(255, bytes[wire.at.getValue("$name.flags")].toInt() and 255)
        assertEquals(wire.at.getValue("$name.oldEnd"), wire.at.getValue("$name.opacity"))
        assertEquals(12, wire.at.getValue("$name.opacity") - wire.at.getValue("$name.lineHeight"))
        assertEquals(style, read(bytes).sections.single().blocks.single().table!!.rows.single().single().style)
        val without = style.copy(opacity = null)
        val (_, legacy) = encode(without)
        val stripped = changed(replace(bytes, wire.at.getValue("$name.opacity"), wire.at.getValue("$name.end"),
            byteArrayOf()), wire.at.getValue("$name.flags"), 0xef)
        assertArrayEquals(legacy, stripped)
        assertEquals(without, read(legacy).sections.single().blocks.single().table!!.rows.single().single().style)
    }

    @Test fun cellOpacityRejectsPreMInvalidScalarsAndMalformedPresenceOrTail() {
        val source = opacityTable(CellStyle(opacity = .2f))
        val wire = Wire('M').apply { paragraphOverride = {
            positionedBlock(Block("table", 0, emptyList(), table = source), "invalidOpacity") } }
        val bytes = wire.document(emptyList(), Sink.Body)
        val name = "invalidOpacity.table.row0.cell0.style"
        val value = wire.at.getValue("$name.opacity")
        reject("Cell local0x10 remains refused before M", changed(bytes, 3, 'L'.code))
        for (alpha in listOf(-Float.MIN_VALUE, -1f, Math.nextUp(1f), Float.NaN,
            Float.NEGATIVE_INFINITY, Float.POSITIVE_INFINITY)) {
            reject("Invalid scalar $alpha", changed32(bytes, value, alpha.toRawBits().toLong() and 0xffff_ffffL))
        }
        for (presence in listOf(2, 255)) reject("Noncanonical CellStyle presence $presence",
            changed(bytes, wire.at.getValue("$name.presence"), presence))
        reject("Present style cannot have no fields", changed(bytes, wire.at.getValue("$name.flags"), 0))
        for (available in 0..3) reject("Truncated scalar $available", bytes.copyOf(value + available))
        reject("Missing flagged scalar", replace(bytes, value, value + 4, byteArrayOf()))
        reject("Unconsumed suffix", bytes + byteArrayOf(0))
        val legacy = opacityTable(CellStyle(border = StyleBorder.None))
        val oldWire = Wire('M').apply { paragraphOverride = {
            positionedBlock(Block("table", 0, emptyList(), table = legacy), "oldOpacity") } }
        val oldBytes = oldWire.document(emptyList(), Sink.Body)
        assertEquals(legacy, read(changed(oldBytes, 3, 'L'.code)).sections.single().blocks.single().table)
        val orphan = replace(oldBytes, oldWire.at.getValue("oldOpacity.table.row0.cell0.style.end"),
            oldWire.at.getValue("oldOpacity.table.row0.cell0.style.end"), byteArrayOf(-51, -52, 76, 62))
        reject("Unflagged scalar is not trailing metadata", orphan)
    }

    @Test fun cellOpacityZeroRetainsEveryRecursiveHolderActionAndOriginalBudget() {
        val link = Span("link", "deep action", "Original target", targetFragment = "part", tooltip = "Original title")
        val leaf = opacityTable(CellStyle(opacity = 0f), listOf(link))
        val outer = Table(listOf(text("caption")), listOf(listOf(
            Cell(emptyList(), false, 1, 1, blocks = listOf(Block("paragraph", 0, listOf(text("\u00a0"))),
                Block("table", 0, emptyList(), table = leaf)), style = CellStyle(opacity = 0f)),
            Cell(emptyList(), true, 1, 1, nestedTable = leaf, style = CellStyle(opacity = 1f)))))
        val block = Block("container", 0, emptyList(), container = Container(listOf(
            Block("table", 0, emptyList(), table = outer), Block("paragraph", 0, listOf(text("after"))))))
        for (sink in listOf(Sink.Body, Sink.Container, Sink.CellBlocks, Sink.TableRichCaption,
            Sink.ReferenceBlocks, Sink.FigureRichCaption, Sink.FlowFigure, Sink.ScopeFigure)) {
            val wire = Wire('O').apply { paragraphOverride = { positionedBlock(block, "holder") } }
            val decoded = read(wire.document(emptyList(), sink))
            val retained = mutableListOf<Span>()
            val visitor = PresentationSpanVisitor { spans, _ -> retained.addAll(spans) }
            decoded.sections.forEach { visitor.blocks(it.blocks) }
            decoded.references.forEach { reference -> reference.visitSpanRuns { spans, _ -> retained.addAll(spans) } }
            assertEquals("$sink retains both original actions", 2, retained.count { it.target == link.target })
            assertTrue("$sink retains source NBSP", retained.any { it.text == "\u00a0" })
            assertTrue("$sink consumes the following sibling", retained.any { it.text == "after" })
            assertEquals(2, retained.count { it.targetFragment == "part" && it.tooltip == "Original title" })
        }
        val rounded = percentCircleOwner(StyleWidth(StyleWidthUnit.Percent, 50f))
        val mixed = opacityTable(CellStyle(opacity = .2f), listOf(rounded))
        val mixedWire = Wire('Y', 4).apply { paragraphOverride = {
            positionedBlock(Block("table", 0, emptyList(), table = mixed), "mixedOpacity") } }
        assertEquals(mixed, read(mixedWire.document(emptyList(), Sink.Body)).sections.single().blocks.single().table)

        val limit = 1 shl 20
        fun budget(rows: Int, opacity: Float?) = Table(emptyList(),
            java.util.Collections.nCopies(rows, emptyList<Cell>()) + listOf(listOf(
                Cell(listOf(link), false, 1, 1, style = opacity?.let { CellStyle(opacity = it) }))))
        for (opacity in listOf(null, 0f, 1f)) {
            // Empty rows plus one real row/cell/action: scalar opacity adds no work item.
            val exact = budget(limit - 3, opacity)
            val seen = mutableListOf<Span>()
            PresentationSpanVisitor { _, _ -> }.apply { onSpan = { seen.add(it) } }.table(exact)
            assertEquals(listOf(link), seen)
            assertSame(link, seen.single())
            invalid("Opacity cannot restart the model budget") {
                PresentationSpanVisitor { _, _ -> }.table(budget(limit - 2, opacity))
            }
            fun literal(rows: Int) = Wire('M').apply { paragraphOverride = {
                positionedBlock(Block("table", 0, emptyList(), table = budget(rows, opacity)), "opacityBudget") }
            }.document(emptyList(), Sink.Body)
            // Decoder additionally counts the Section and Table Block slots.
            val decoded = read(literal(limit - 5)).sections.single().blocks.single().table!!
            assertEquals(limit - 4, decoded.rows.size)
            assertEquals(listOf(link), decoded.rows.last().single().spans)
            assertEquals(opacity, decoded.rows.last().single().style?.opacity)
            reject("Opacity cannot restart the wire budget", literal(limit - 4))
        }
        for (depth in listOf(LegacyMaxTableDepth, LegacyMaxTableDepth + 1)) {
            var nested = leaf
            repeat(depth - 1) { nested = Table(emptyList(), listOf(listOf(
                Cell(emptyList(), false, 1, 1, nestedTable = nested, style = CellStyle(opacity = 0f))))) }
            val wire = Wire('M').apply { paragraphOverride = {
                positionedBlock(Block("table", 0, emptyList(), table = nested), "opacityDepth") } }
            val bytes = wire.document(emptyList(), Sink.Body)
            if (depth == LegacyMaxTableDepth) assertNotNull(read(bytes)) else reject("M retains its original table depth limit", bytes)
        }
        for (depth in listOf(16, 17)) {
            val wire = Wire('O').apply { paragraphOverride = {
                positionedBlock(Block("table", 0, emptyList(), table = leaf), "opacityContent") } }
            val bytes = wire.document(emptyList(), Sink.Container, containers = depth)
            if (depth == 16) assertNotNull(read(bytes)) else reject("Opacity cannot reset content depth", bytes)
        }
        val child = mutableListOf(text("valid"))
        val action = Span("link", "", "Owner", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Px, 1f), StyleLength(StyleLengthUnit.Px, 1f), child))
        val hidden = opacityTable(CellStyle(opacity = 0f), listOf(action))
        child.add(Span("link", "illegal nested action", "Other"))
        invalid("Zero alpha does not suppress mutated child action validation") {
            PresentationSpanVisitor { _, _ -> }.table(hidden)
        }
        val invalidWire = Wire('U').apply { paragraphOverride = {
            positionedBlock(Block("table", 0, emptyList(), table = hidden), "hiddenAction") } }
        reject("Zero alpha does not suppress serialized child action validation",
            invalidWire.document(emptyList(), Sink.Body))
    }
    private fun overlayTextOwner(): Span {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdge.None
        val edges = InlineBoxBorderEdges(none, none, none, none)
        val font = InlineFontSnapshot(14f, FontScaleBasis.CssPx, fontNormalized = true)
        val detached = Span("text", "\u200b", fontScale = 14f, fontScaleBasis = FontScaleBasis.CssPx,
            tooltip = "original detached text", explanation = "independent source")
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Percent, 0f), bottom = InlineBoxInset(StyleWidthUnit.Percent, 67f)),
            edges, InlineBoxOverlayContent(1L, font, null, InlineBoxOverlayTextAlign.Start, listOf(detached)))
        return Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), edges,
            listOf(overlay), listOf(Span("link", "スリ", "Original target", targetFragment = "fragment"), text("!"))))
    }

    @Test fun inlineOverlayContentPreservesBoundariesDeclaringMetricsAndOriginalFlatSource() {
        val source = overlayTextOwner()
        val group = checkNotNull(source.inlineBoxGroup)
        val overlay = group.overlays.single()
        val body = checkNotNull(overlay.content)
        assertEquals("\u200b", body.spans.single().text)
        assertSame(body, overlay.content); assertSame(overlay, group.overlays.single())
        assertEquals(1L, body.beforeChild); assertEquals(14f, body.ownerFont.fontScale)
        assertNull(body.lineHeight); assertEquals(InlineBoxOverlayTextAlign.Start, body.textAlign)
        assertEquals(EntryLink("Original target", "fragment"), group.spans.first().entryLink())
        val last = overlay.copy(content = body.copy(beforeChild = 2L))
        val start = overlay.copy(content = body.copy(beforeChild = 0L))
        val duplicateBoundary = group.copy(overlays = listOf(start, overlay, overlay, last))
        assertEquals(listOf(0L, 1L, 1L, 2L), duplicateBoundary.overlays.map { it.content!!.beforeChild })
        assertSame(group.spans, duplicateBoundary.spans)
        for (alignment in InlineBoxOverlayTextAlign.entries) for (height in listOf(null,
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx)),
            InlineLineHeight.FontRelative(1.25f, body.ownerFont))) {
            val value = body.copy(lineHeight = height, textAlign = alignment)
            assertSame(height, value.lineHeight); assertEquals(alignment, value.textAlign)
        }
        invalid("Out-of-range source boundary") { group.copy(overlays = listOf(overlay.copy(content = body.copy(beforeChild = 3L)))) }
        invalid("Nonmonotone boundaries") { group.copy(overlays = listOf(last, overlay)) }
        invalid("Negative ordinal") { body.copy(beforeChild = -1L) }
        invalid("Ordinal exceeds u32") { body.copy(beforeChild = 0x1_0000_0000L) }
        invalid("Unknown contextual strut") { body.copy(ownerFont = InlineFontSnapshot()) }
        invalid("Font-relative height cannot name another font") { body.copy(lineHeight =
            InlineLineHeight.FontRelative(1f, body.ownerFont.copy(bold = true))) }
        val plain = body.spans.single()
        val invalidChildren = listOf(plain.copy(text = ""), plain.copy(trail = "!"), plain.copy(direction = "rtl"),
            plain.copy(bold = true), plain.copy(underline = true), plain.copy(strike = true),
            plain.copy(background = "#123456"), plain.copy(kind = "link", target = "action"),
            plain.copy(inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(InlineComputedLength(14f, FontScaleBasis.CssPx)))),
            simple(), Span("text", "", image = InlineImage("Probe.svg")))
        for (child in invalidChildren) invalid("Detached body remains flat and complete: $child") { body.copy(spans = listOf(child)) }
        for (control in listOf('\t', '\n', '\r', '\u000c')) invalid("Raw body control") {
            body.copy(spans = listOf(plain.copy(text = "x${control}y")))
        }
        val actionless = source.copy(inlineBoxGroup = group.copy(spans = listOf(text("flow"))))
        invalid("Direct Box action cannot become inherited overlay action") { actionless.copy(kind = "link", target = "owner") }
        invalid("Enclosing action still cannot reach detached body") {
            Span("link", "", "ancestor", inlineActionGroup = InlineActionGroup(listOf(actionless)))
        }
        invalid("Detached body is not in-flow text") { group.copy(spans = listOf(text(""))) }
        val mutableBody = body.spans.toMutableList()
        val retained = source.copy(inlineBoxGroup = group.copy(overlays = listOf(overlay.copy(content = body.copy(spans = mutableBody)))))
        mutableBody[0] = plain.copy(bold = true)
        invalid("A retained mutable child cannot escape shared revalidation") { PresentationSpanVisitor { _, _ -> }.spans(listOf(retained)) }
        mutableBody[0] = plain
        PresentationSpanVisitor { _, _ -> }.spans(listOf(retained))
        assertSame(plain, retained.inlineBoxGroup!!.overlays.single().content!!.spans.single())
    }

    @Test fun inlineOverlayLocalTailRoundtripsEverySinkNullBytesAndExistingAudioNamespace() {
        val source = overlayTextOwner()
        for (sink in Sink.entries) {
            val wire = Wire('Y', 4)
            val decoded = read(wire.document(listOf(source), sink, headingTitle = "スリ\u200b!"))
            assertEquals("Complete original graph at $sink", source, selected(decoded, sink))
            val body = selected(decoded, sink).inlineBoxGroup!!.overlays.single().content!!
            assertEquals("\u200b", body.spans.single().text)
            assertEquals("original detached text", body.spans.single().tooltip)
            assertEquals("independent source", body.spans.single().explanation)
        }
        val raw = Wire('Y', 4)
        val bytes = raw.document(listOf(source))
        val root = "root.0.box.overlay0"
        assertEquals(0x17, bytes[raw.at.getValue("$root.flags")].toInt() and 0xff)
        assertArrayEquals(byteArrayOf(1, 0, 0, 0), bytes.copyOfRange(raw.at.getValue("$root.content.beforeChild"),
            raw.at.getValue("$root.content.beforeChild") + 4))
        assertEquals(17, bytes[raw.at.getValue("$root.content.font.flags")].toInt() and 0xff)
        assertEquals(0, bytes[raw.at.getValue("$root.content.lineHeight")].toInt())
        assertArrayEquals(byteArrayOf(1, 0, 0, 0, 17, 0, 0, 0x60, 0x41, 2, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0),
            bytes.copyOfRange(raw.at.getValue("$root.content.start"), raw.at.getValue("$root.content.body.0.start")))
        val group = source.inlineBoxGroup!!
        val empty = source.copy(inlineBoxGroup = group.copy(overlays = listOf(group.overlays.single().copy(content = null))))
        val legacy = Wire('Y', 4).document(listOf(empty))
        val removed = replace(changed(bytes, raw.at.getValue("$root.flags"), 7),
            raw.at.getValue("$root.content.start"), raw.at.getValue("$root.content.end"), byteArrayOf())
        assertArrayEquals(legacy, removed)
        assertEquals(empty, read(legacy).displayTitle.single())
        val body = group.overlays.single().content!!
        for (alignment in InlineBoxOverlayTextAlign.entries) for (height in listOf(null,
            InlineLineHeight.Computed(InlineComputedLength(17.5f, FontScaleBasis.CssPx)),
            InlineLineHeight.FontRelative(1.25f, body.ownerFont))) {
            val owner = source.copy(inlineBoxGroup = group.copy(overlays = listOf(group.overlays.single().copy(
                content = body.copy(lineHeight = height, textAlign = alignment)))))
            assertEquals(owner, read(Wire('Y', 4).document(listOf(owner))).displayTitle.single())
        }
        val familyFont = body.ownerFont.copy(fontFamily = ContainerFontFamily.SansSerif)
        val familyBody = body.copy(ownerFont = familyFont, spans = body.spans.map { it.copy(fontFamily = familyFont.fontFamily) })
        val familySource = source.copy(inlineBoxGroup = group.copy(overlays = listOf(group.overlays.single().copy(content = familyBody))))
        assertEquals(familySource, read(Wire('Y', 4).document(listOf(familySource), features = 4)).displayTitle.single())
        reject("Snapshot and detached child require actual family feature", Wire('Y', 4).document(listOf(familySource)))
        reject("No false family census for the old generic heading font", Wire('Y', 4).document(listOf(source), features = 4))
        val audio = Span("link", "Play", "File:Tone.ogg", classes = "wikidict-media wikidict-media-file-546f6e652e6f6767", audioControl = AudioControl())
        val mixed = Wire('Z', 4 or 8192).document(listOf(source, audio), mediaValues = listOf(Media("Tone.ogg", "audio", "")))
        assertEquals(listOf(source, audio), read(mixed).displayTitle)
        val ordinary = group.spans.singleOrNull() ?: group.spans.first()
        assertEquals("Original target", ordinary.target)
    }

    @Test fun inlineOverlayLocalFlagRefusesMalformedPayloadAndInheritedActionDebt() {
        val source = overlayTextOwner()
        val raw = Wire('Y', 4)
        val bytes = raw.document(listOf(source))
        val p = "root.0.box.overlay0"
        for (bit in listOf(0x20, 0x40, 0x80)) reject("Unknown overlay flag", changed(bytes, raw.at.getValue("$p.flags"), 0x17 or bit))
        reject("Removed owning Box capability", changed(bytes, raw.at.getValue("yFeatures"), 0))
        for (tag in listOf(3, 255)) reject("Unknown detached height", changed(bytes, raw.at.getValue("$p.content.lineHeight"), tag))
        for (tag in listOf(4, 255)) reject("Unknown detached alignment", changed(bytes, raw.at.getValue("$p.content.align"), tag))
        reject("Missing normalization proof", changed(bytes, raw.at.getValue("$p.content.font.flags"), 1))
        reject("Unknown font face bits", changed(bytes, raw.at.getValue("$p.content.font.face"), 0x80))
        reject("Context size is not a detached strut", changed(bytes, raw.at.getValue("$p.content.font.scale") + 4, 0))
        reject("NaN detached size", changed32(bytes, raw.at.getValue("$p.content.font.scale"), 0x7fc00000L))
        reject("Source boundary cannot exceed in-flow children", changed32(bytes, raw.at.getValue("$p.content.beforeChild"), 3))
        reject("Body cannot be empty", changed32(bytes, raw.at.getValue("$p.content.body.count"), 0))
        reject("Computed height cannot be negative", replace(bytes, raw.at.getValue("$p.content.lineHeight"),
            raw.at.getValue("$p.content.lineHeight") + 1, byteArrayOf(1, 0, 0, 0x80.toByte(), 0xbf.toByte(), 2)))
        for (end in raw.at.getValue("$p.content.start") until raw.at.getValue("$p.content.end"))
            reject("Truncated detached payload $end", bytes.copyOf(end))
        reject("Final EOF remains strict", bytes + 0)
        val body = source.inlineBoxGroup!!.overlays.single().content!!
        val badChild = body.spans.single().copy(kind = "link", target = "unexpected")
        reject("Wire child action", replace(bytes, raw.at.getValue("$p.content.body.0.start"),
            raw.at.getValue("$p.content.body.0.end"), Wire('Y', 4).isolatedSpan(badChild)))
        val holder = Span("link", "", "ancestor", inlineActionGroup = InlineActionGroup(listOf(text("placeholder"))))
        val outer = Wire('Y', 4)
        val outerBytes = outer.document(listOf(holder))
        val plainBox = source.copy(inlineBoxGroup = source.inlineBoxGroup!!.copy(spans = listOf(text("flow"))))
        reject("Ancestor action rejected across the wire", replace(outerBytes,
            outer.at.getValue("root.0.action.body.0.start"), outer.at.getValue("root.0.action.body.0.end"),
            Wire('Y', 4).isolatedSpan(plainBox)))
        val group = source.inlineBoxGroup!!
        val pair = source.copy(inlineBoxGroup = group.copy(overlays = listOf(group.overlays.single(), group.overlays.single())))
        val order = Wire('Y', 4); val orderedBytes = order.document(listOf(pair))
        reject("Wire source boundaries are nondecreasing", changed32(orderedBytes,
            order.at.getValue("root.0.box.overlay1.content.beforeChild"), 0))
    }

    @Test fun inlineOverlaySharesItemContentTableBudgetsAndValidatesIgnoredSerializedPrefixes() {
        val source = overlayTextOwner()
        val group = source.inlineBoxGroup!!
        val oneFlow = source.copy(inlineBoxGroup = group.copy(spans = listOf(text("flow"))))
        val limit = 1 shl 20
        fun table(count: Int, prefix: List<Span> = emptyList(), caption: List<Span> = listOf(oneFlow)) =
            Block("table", 0, prefix, table = Table(caption, java.util.Collections.nCopies(count, emptyList<Cell>())))
        fun entry(block: Block) = Entry("Overlay", emptyList(), "language", "French", "fr",
            listOf(Section(2, "Body", listOf(block))), emptyList())
        // Block + Box owner + overlay + detached child + in-flow child = five items.
        assertEquals(limit - 5, entry(table(limit - 5)).sections.single().blocks.single().table!!.rows.size)
        invalid("Detached spans share the original model budget") { entry(table(limit - 4)) }
        fun wire(count: Int) = Wire('Y', 4).apply { paragraphOverride = { positionedBlock(table(count), "overlayBudget") } }
            .document(emptyList(), Sink.Body)
        assertEquals(limit - 6, read(wire(limit - 6)).sections.single().blocks.single().table!!.rows.size)
        reject("Reader also charges the Section slot", wire(limit - 5))
        for (depth in listOf(14, 15)) {
            val bytes = Wire('Y', 4).document(listOf(oneFlow), Sink.Container, containers = depth)
            if (depth == 14) assertEquals(1, read(bytes).sections.size)
            else reject("Detached body uses its second content level", bytes)
        }
        for (depth in listOf(32, 33)) {
            val bytes = Wire('Y', 4).apply { paragraphOverride = { tableChain(depth, mixed = true) } }.document(listOf(oneFlow), Sink.Body)
            if (depth == 32) assertEquals(1, read(bytes).sections.size) else reject("Overlay does not reset table depth", bytes)
        }
        val pad = StyleLength(StyleLengthUnit.Px, 1f)
        val nested = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(pad, pad, listOf(oneFlow)))
        var displayed = 0
        val ignored = table(0, listOf(nested), emptyList())
        PresentationSpanVisitor { spans, _ -> displayed += spans.size }.block(ignored)
        assertEquals(0, displayed)
        assertSame(nested, entry(ignored).sections.single().blocks.single().spans.single())
        // Root + padding owner + Box owner + overlay + both real children = six.
        assertEquals(limit - 6, entry(table(limit - 6, listOf(nested), emptyList())).sections.single().blocks.single().table!!.rows.size)
        invalid("Ignored nested overlay still consumes the one model budget") { entry(table(limit - 5, listOf(nested), emptyList())) }
        fun prefixLiteral(rows: Int) = Wire('Y', 4).apply {
            paragraphOverride = { audioPrefixTable(Table(emptyList(), java.util.Collections.nCopies(rows, emptyList<Cell>()))) }
        }.document(listOf(nested), Sink.Body)
        val decodedPrefix = read(prefixLiteral(limit - 7)).sections.single().blocks.single()
        assertEquals(listOf(nested), decodedPrefix.spans)
        assertEquals(limit - 7, decodedPrefix.table!!.rows.size)
        reject("Ignored overlay shares the decoder budget too", prefixLiteral(limit - 6))
        val mutable = mutableListOf(text("placeholder"))
        val action = Span("link", "", "ancestor", inlineActionGroup = InlineActionGroup(mutable))
        mutable[0] = oneFlow
        invalid("Ignored prefix cannot conceal inherited overlay action") { entry(table(0, listOf(action), emptyList())) }
        invalid("Ignored rule prefix has the same action custody") { entry(Block("rule", 0, listOf(action))) }
        var ruleDisplay = 0
        PresentationSpanVisitor { spans, _ -> ruleDisplay += spans.size }.block(Block("rule", 0, listOf(nested)))
        assertEquals(0, ruleDisplay)
        val legacy = table(0, listOf(text("legacy ignored")), emptyList())
        var oldDisplayed = 0
        PresentationSpanVisitor { spans, _ -> oldDisplayed += spans.size }.block(legacy)
        assertEquals(0, oldDisplayed); assertSame(legacy, entry(legacy).sections.single().blocks.single())
        // Legacy direct-only ignored prefixes were not subject to the serialized-span budget.
        // Discovery proves absence without charging that graph or recursing through shared owners.
        val plain = text("legacy")
        val noOverlay = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(pad, pad, listOf(plain)))
        for (oldSpan in listOf(plain, noOverlay)) {
            val oldPrefix = java.util.Collections.nCopies(limit + 1, oldSpan)
            assertSame(oldPrefix, entry(table(0, oldPrefix, emptyList())).sections.single().blocks.single().spans)
        }
        invalid("Actual overlay selects full serialized work despite legacy predecessors") {
            entry(table(0, java.util.Collections.nCopies(limit, plain) + oneFlow, emptyList()))
        }
    }

    @org.junit.Test fun inlineOverlayRebaseKeepsAtomicRadiusAndOpacityNamespacesAndCustody() {
        val overlay = overlayTextOwner()
        val atom = atomicWireOwner()
        val rounded = percentCircleOwner()
        val spans = listOf(overlay, atom, rounded)
        val table = opacityTable(CellStyle(opacity = 0f), spans)
        val wire = Wire('Y', 4).apply { paragraphOverride = {
            positionedBlock(Block("table", 0, emptyList(), table = table), "coexist") } }
        val bytes = wire.document(emptyList(), Sink.Body)
        assertEquals(table, read(bytes).sections.single().blocks.single().table)
        val cell = "coexist.table.row0.cell0"
        assertEquals(0, bytes[wire.at.getValue("$cell.spans.0.fontFields")].toInt() and 0x70)
        assertEquals(0x10, bytes[wire.at.getValue("$cell.spans.0.box.overlay0.flags")].toInt() and 0x10)
        assertEquals(0x40, bytes[wire.at.getValue("$cell.spans.1.fontFields")].toInt() and 0x70)
        assertEquals(0x20, bytes[wire.at.getValue("$cell.spans.2.fontFields")].toInt() and 0x70)
        assertEquals(0x10, bytes[wire.at.getValue("$cell.style.flags")].toInt() and 0xff)
        reject("Overlay content does not allocate the remaining Span bit", changed(bytes,
            wire.at.getValue("$cell.spans.0.fontFields"), 0x80))
        val bodies = checkNotNull(overlay.inlineBoxGroup).overlays
        invalid("Current atomic layout still excludes detached overlays") {
            checkNotNull(atom.inlineBoxGroup).copy(overlays = bodies)
        }
        invalid("Current percent/dotted radius still excludes detached overlays") {
            checkNotNull(rounded.inlineBoxGroup).copy(overlays = bodies)
        }
        val ignored = Block("table", 0, listOf(overlay, atom), table = Table(emptyList(), emptyList()))
        val seen = mutableListOf<Span>()
        var displayed = 0
        PresentationSpanVisitor { values, _ -> displayed += values.size }.apply { onSpan = { seen.add(it) } }.block(ignored)
        assertEquals(0, displayed)
        assertTrue(seen.any { it === overlay })
        assertTrue(seen.any { it === atom })
        assertTrue(seen.any { it === bodies.single().content!!.spans.single() })
        assertSame(atom, ignored.spans.last())
    }
}
