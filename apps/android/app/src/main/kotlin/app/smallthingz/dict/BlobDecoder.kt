package app.smallthingz.dict

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction

/** Direct DPR2-DPRM decoder. Dictionary presentation never passes through JSON or source text. */
object BlobDecoder {
    private val kinds = listOf("paragraph", "blank", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "heading", "preformatted", "rule", "table", "container")
    private val roles = listOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference")
    private val inline = listOf("text", "link", "external_link", "line_break")
    fun decode(bytes: ByteArray, title: String, kind: String, language: String?, code: String): Entry {
        val r = Reader(bytes)
        require(r.byte() == 68 && r.byte() == 80 && r.byte() == 82) { "Unsupported presentation format" }
        val magicVersion = r.byte()
        require(magicVersion in 50..57 || magicVersion in 65..77) { "Unsupported presentation format" }
        val version = if (magicVersion in 65..77) 57 else magicVersion
        r.fontScales = magicVersion in 65..77
        r.fontScaleBases = magicVersion in 66..77
        r.tableStyles = magicVersion in 67..77
        r.inlineImages = magicVersion in 67..77
        r.imageBorders = magicVersion >= 68
        r.blockLayouts = magicVersion >= 69
        r.targetFragments = magicVersion >= 70
        r.tooltips = magicVersion >= 72
        r.blockStyles = magicVersion >= 73
        r.imageMaps = magicVersion >= 74
        r.tableFlows = magicVersion >= 75
        r.imageDarkFilters = magicVersion >= 75
        r.containers = magicVersion >= 76
        r.containerFonts = magicVersion >= 77
        r.explanations = version >= 51
        r.colors = version >= 52
        r.anchors = version >= 53
        r.spanBackgrounds = version >= 54
        r.nestedTables = version >= 55
        r.cellBlocks = version >= 56
        if (r.nestedTables) r.remainingItems = 1 shl 20
        val display = r.spans()
        val sections = List(r.count(if (r.anchors) 17 else 9)) {
            val level = r.byte(); val name = r.string()
            val anchor = if (r.anchors) r.string() else ""
            val fallback = if (r.anchors) r.string() else ""
            Section(level, name, List(r.count(r.minimumBlockBytes)) { r.block() }, anchor, fallback)
        }
        val preamble = r.spans()
        // Preserve typed etymology ownership while retaining the authored section order.
        val etymologySections = mutableSetOf<Int>()
        val lexemes = List(r.count(29)) {
            val lexemeLanguage = r.string(); val lexemeKind = r.string()
            val section = r.index(sections.size)
            val etymology = r.optionalIndex(sections.size)?.also(etymologySections::add)
            val blocks = sections[section].blocks.size
            val definitions = List(r.count(18)) { sense ->
                val block = r.index(blocks); val parent = r.optionalIndex(sense)
                val examples = r.indices(blocks); val quotations = r.indices(blocks); val notes = r.indices(blocks)
                val form = if (r.presence()) PresentationForm(r.string(), r.string(), r.string()) else null
                PresentationSense(block, parent, examples, quotations, notes, form,
                    if (r.containers) r.blockPath() else emptyList(),
                    if (r.containers) r.blockPaths() else emptyList(),
                    if (r.containers) r.blockPaths() else emptyList(),
                    if (r.containers) r.blockPaths() else emptyList())
            }
            val introduction = r.indices(blocks); val other = r.indices(blocks); val related = r.indices(sections.size)
            PresentationLexeme(lexemeLanguage, lexemeKind, section, etymology, definitions, introduction, other, related,
                if (r.containers) r.blockPaths() else emptyList(), if (r.containers) r.blockPaths() else emptyList())
        }
        val organization = PresentationOrganization(lexemes, r.indices(sections.size))
        organization.validate(sections)
        val references = List(r.count(if (r.inlineImages) 14 else if (version >= 57) 13 else 20)) {
            val referenceKind = if (version < 57) ReferenceKind.Note else when (r.byte()) {
                0 -> ReferenceKind.Note
                1 -> ReferenceKind.Fragment
                else -> error("Unknown reference item kind")
            }
            val number = r.u32()
            require(number in 1L..0xffff_fffeL)
            val groupNumber = if (referenceKind == ReferenceKind.Note) {
                val ordinal = r.u32()
                require(ordinal in 1L..0xffff_fffeL)
                r.string() // Authored note name; navigation uses its stable item identity.
                ordinal
            } else null
            val group = r.string()
            val spans = r.spans()
            val blocks = if (r.inlineImages && r.presence()) List(r.count(r.minimumBlockBytes)) { r.block() } else null
            Reference(number, groupNumber, group, spans, referenceKind, blocks)
        }
        val media = List(r.count(9)) { Media(r.string(), r.enum(listOf("image", "audio")), r.string()) }
        require(!r.buffer.hasRemaining()) { "Trailing presentation data" }
        val entry = Entry(title, display, kind, language, code, sections, references, preamble, media,
            etymologySections = etymologySections.toSet(), organization = organization.takeIf { r.containers })
        // G uses the shared count/byte budget; C/D and E/F retain their wire limits.
        // Historical media-only entries do not acquire a typed-image catalog limit.
        require(magicVersion >= 71 || entry.inlineImages.isEmpty() || media.size <= (if (magicVersion >= 69) 256 else 128)) {
            "Too many inline image assets for legacy presentation"
        }
        return entry
    }
    private class Reader(bytes: ByteArray) {
        val buffer: ByteBuffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        private val utf8 = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        var remainingItems = 1_000_000
        var explanations = false
        var colors = false
        var anchors = false
        var spanBackgrounds = false
        var nestedTables = false
        var cellBlocks = false
        var fontScales = false
        var fontScaleBases = false
        var tableStyles = false
        var inlineImages = false
        var imageBorders = false
        var blockLayouts = false
        var targetFragments = false
        var tooltips = false
        var blockStyles = false
        var imageMaps = false
        var tableFlows = false
        var imageDarkFilters = false
        var containers = false
        var containerFonts = false
        private var remainingMapStringBytes = 32L * 1024 * 1024
        private var contentDepth = 0
        val minimumBlockBytes: Int get() = if (imageMaps) 29 else if (blockStyles) 27 else if (blockLayouts) 26 else if (anchors) 25 else 17
        fun byte(): Int { require(buffer.remaining() >= 1); return buffer.get().toInt() and 255 }
        fun u16(): Int { require(buffer.remaining() >= 2); return buffer.short.toInt() and 65535 }
        fun u32(): Long { require(buffer.remaining() >= 4); return buffer.int.toLong() and 0xffffffffL }
        fun count(minBytes: Int): Int {
            val n = u32(); require(n <= remainingItems && n <= buffer.remaining() / minBytes)
            remainingItems -= n.toInt(); return n.toInt()
        }
        fun string(mapString: Boolean = false): String {
            val n = u32(); require(n <= 32*1024*1024 && n <= buffer.remaining())
            if (mapString) { require(n <= remainingMapStringBytes); remainingMapStringBytes -= n }
            if (n == 0L) return ""
            val slice = buffer.slice(); slice.limit(n.toInt()); buffer.position(buffer.position() + n.toInt())
            // decode(ByteBuffer) resets the decoder for each independent field.
            return utf8.decode(slice).toString()
        }
        fun enum(values: List<String>): String = values.getOrNull(byte()) ?: error("Unknown presentation tag")
        fun presence(): Boolean = when(byte()) { 0 -> false; 1 -> true; else -> error("Invalid presence flag") }
        fun index(limit: Int): Int { val n = u32(); require(n < limit); return n.toInt() }
        fun optionalIndex(limit: Int): Int? {
            val n = u32(); require(n == 0xffffffffL || n < limit)
            return if (n == 0xffffffffL) null else n.toInt()
        }
        fun indices(limit: Int): List<Int> = List(count(4)) { index(limit) }
        fun blockPath(): List<Int> {
            val size = count(4); require(size <= MaxContentDepth) { "Container address is too deep" }
            return List(size) { index(Int.MAX_VALUE) }
        }
        fun blockPaths(): List<List<Int>> = List(count(4)) { blockPath() }
        fun spans(): List<Span> = List(count(if (tooltips) 37 else if (targetFragments) 36 else if (inlineImages) 35 else if (fontScales) 34 else if (spanBackgrounds) 33 else if (colors) 32 else if (explanations) 31 else 27)) { span() }
        private fun span(): Span {
            val kind = enum(inline); val role = enum(roles); val f = byte()
            val text = string(); val target = string(); val trail = string()
            val language = string(); val classes = string(); val direction = string()
            val explanation = if (explanations) string() else ""
            val foreground = if (colors && presence()) string().also {
                require(canonicalColorArgb(it) != null) { "Invalid span foreground" }
            } else null
            val background = if (spanBackgrounds && presence()) string().also {
                require(canonicalColorArgb(it) != null) { "Invalid span background" }
            } else null
            val fontFields = if (!fontScales) 0 else if (containerFonts) byte().also {
                require(it and 0xfc == 0) { "Unknown span font fields" }
            } else if (presence()) 1 else 0
            val rawScale = if (fontFields and 1 != 0) {
                require(buffer.remaining() >= 4) { "Truncated span font scale" }
                buffer.float.also { require(it.isFinite() && it >= 0f) { "Invalid span font scale" } }
            } else null
            val basis = if (fontScaleBases && rawScale != null) when (byte()) {
                0 -> FontScaleBasis.Context
                1 -> FontScaleBasis.NormalBody
                2 -> {
                    require(containerFonts) { "CSS-pixel span font size requires M" }
                    FontScaleBasis.CssPx
                }
                else -> error("Invalid span font scale basis")
            } else FontScaleBasis.Context
            val fontFeatures = if (fontFields and 2 != 0)
                FontFeaturePolicy.entries.getOrNull(byte()) ?: error("Unknown span font feature policy") else null
            val fontScale = rawScale?.takeUnless { it == 1f && basis == FontScaleBasis.Context }
            val imageTag = if (inlineImages) byte() else 0
            require(imageTag in 0..1 || containerFonts && imageTag == 2) { "Unsupported inline image tag" }
            val image = if (imageTag != 0) {
                val file = string(); val flags = byte()
                require(flags and (if (imageDarkFilters) 0 else if (imageMaps) 0xc0 else if (imageBorders) 0xe0 else 0xf0) == 0) { "Unknown inline image flags" }
                InlineImage(file, if (flags and 1 != 0) u32() else null, if (flags and 2 != 0) u32() else null,
                    if (flags and 4 != 0) string() else null, if (flags and 8 != 0) string() else null,
                    border = flags and 0x10 != 0, map = if (flags and 0x20 != 0) imageMap() else null,
                    darkModeFilter = if (flags and 0x40 != 0)
                        ImageDarkModeFilter.entries.getOrNull(byte()) ?: error("Unknown image dark-mode filter") else null,
                    svgLanguage = if (flags and 0x80 != 0) string() else null,
                    staticPoster = if (imageTag == 2) StaticPoster(
                        StaticPosterPolicy.entries.getOrNull(byte()) ?: error("Unknown static poster policy"),
                        string(), string(), string()) else null)
            } else null
            val targetFragment = if (targetFragments && presence()) string() else null
            val tooltip = if (tooltips && presence()) string() else null
            return Span(kind, text, target, trail, language, classes, direction,
                bold=f and 1 != 0, italic=f and 2 != 0, code=f and 4 != 0, small=f and 8 != 0,
                superscript=f and 16 != 0, subscript=f and 32 != 0, strike=f and 64 != 0, underline=f and 128 != 0, role=role, explanation=explanation, foreground=foreground, background=background, fontScale=fontScale, fontScaleBasis=basis, image=image, targetFragment=targetFragment, tooltip=tooltip, fontFeatures=fontFeatures)
        }
        private fun imageMapAction(): ImageMapAction {
            val kind = ImageMapActionKind.entries.getOrNull(byte()) ?: error("Unknown image map action")
            return ImageMapAction(kind, string(true), if (presence()) string(true) else null, string(true))
        }
        private fun imageMap(): ImageMap {
            val description = ImageMapDescription.entries.getOrNull(byte()) ?: error("Unknown image map description")
            val regions = List(count(39)) {
                val shape = ImageMapShape.entries.getOrNull(byte()) ?: error("Unknown image map shape")
                val size = count(8)
                require(when (shape) {
                    ImageMapShape.Rect -> size == 4
                    ImageMapShape.Circle -> size == 3
                    ImageMapShape.Polygon -> size >= 6 && size % 2 == 0
                }) { "Invalid image map coordinate count" }
                val coordinates = List(size) { buffer.double.also { require(it.isFinite()) { "Nonfinite image map coordinate" } } }
                ImageMapRegion(shape, coordinates, imageMapAction())
            }
            val default = if (presence()) {
                require(remainingItems > 0 && buffer.remaining() >= 10); remainingItems--
                imageMapAction()
            } else null
            return ImageMap(description, regions, default)
        }
        private fun figureColor(): FigureColor = when (byte()) {
            0 -> FigureColor.NativeTheme
            1 -> FigureColor.Transparent
            2 -> FigureColor.Rgb(styleRgb())
            else -> error("Unknown figure color")
        }
        private fun figureBorder(): FigureBorder = when (byte()) {
            0 -> FigureBorder.None
            1 -> FigureBorder.Solid(styleLength(), figureColor())
            else -> error("Unknown figure border")
        }
        private fun figure(tableDepth: Int): Figure? {
            if (!imageMaps) return null
            val tag = byte()
            if (tag == 0) return null
            require(tag == 1 || tableFlows && tag == 2 || containerFonts && tag in 5..6) { "Unknown figure content tag" }
            require(buffer.remaining() >= 123) { "Truncated figure" }
            val format = FigureFormat.entries.getOrNull(byte()) ?: error("Unknown figure format")
            val placement = FigurePlacement.entries.getOrNull(byte()) ?: error("Unknown figure placement")
            val clear = FigureClear.entries.getOrNull(byte()) ?: error("Unknown figure clear")
            val margins = styleEdges(); val insets = styleEdges(); val padding = styleEdges()
            require(buffer.remaining() >= 4)
            val scale = buffer.float.also { require(it.isFinite() && it >= 0f) }
            val lineHeight = styleLength()
            val frameBackground = figureColor(); val frameBorder = figureBorder()
            val imageBackground = figureColor(); val imageBorder = figureBorder()
            val captionForeground = figureColor(); val captionBackground = figureColor()
            require(remainingItems > 0 && buffer.remaining() >= 37); remainingItems--
            val contentSpan = span()
            val missing = if (tag == 2 || tag == 6) FigureContent.Missing(contentSpan, styleLength(), styleLength(),
                if (presence()) MissingLinkPaint.entries.getOrNull(byte()) ?: error("Unknown missing-link paint") else null) else null
            val caption = spans(); val rich = captionBlocks(caption, tableDepth)
            val align = if (presence()) CellTextAlign.entries.getOrNull(byte()) ?: error("Unknown caption alignment") else null
            val content = missing ?: FigureContent.Image(contentSpan,
                FigureSizingPolicy.entries.getOrNull(byte()) ?: error("Unknown figure sizing policy"))
            val frameMinWidth = if (presence()) styleLength() else null
            val tableCaption = if (tag >= 5) tableCaptionLayout() else null
            return Figure(content, format, placement, clear, margins, insets, padding, scale, lineHeight,
                frameBackground, frameBorder, imageBackground, imageBorder, captionForeground, captionBackground,
                caption, rich, align, frameMinWidth, tableCaption)
        }
        private fun figureBorderEdge(): FigureBorderEdge = when (byte()) {
            0 -> FigureBorderEdge.None
            1 -> FigureBorderEdge.Hidden
            2 -> FigureBorderEdge.Solid(styleLength(), figureColor())
            3 -> FigureBorderEdge.Dotted(styleLength(), figureColor())
            else -> error("Unknown Figure border edge")
        }
        private fun figureBorderEdges() = FigureBorderEdges(figureBorderEdge(), figureBorderEdge(), figureBorderEdge(), figureBorderEdge())
        private fun figureMediaLayout(): FigureMediaLayout {
            require(buffer.remaining() >= 15) { "Truncated Figure media layout" }
            val scale = buffer.float
            val flags = byte().also { require(it and 0xf0 == 0) { "Unknown Figure media font flags" } }
            val language = string()
            val direction = BidiResolvedDirection.entries.getOrNull(byte()) ?: error("Unknown Figure media direction")
            val fontFeatures = if (flags and 8 != 0)
                FontFeaturePolicy.entries.getOrNull(byte()) ?: error("Unknown Figure font feature policy") else null
            val strut = FigureMediaStrut(scale, flags and 1 != 0, flags and 2 != 0, flags and 4 != 0,
                language, direction, fontFeatures)
            val align = InlineBoxVerticalAlign.entries.getOrNull(byte()) ?: error("Unknown Figure media alignment")
            val maximum = if (presence()) {
                require(buffer.remaining() >= 4) { "Truncated Figure media maximum" }
                AvailableWidthLimit(buffer.float, styleLength())
            } else null
            val positioning = if (presence()) ContainerPositioning.entries.getOrNull(byte())
                ?: error("Unknown Figure media positioning") else null
            val after = if (presence()) {
                val width = styleLength(); val height = styleLength()
                val side = TableFloatSide.entries.getOrNull(byte()) ?: error("Unknown Figure after side")
                val inset = styleLength(); val bottom = containerMarginLength()
                val paint = if (presence()) FigureGraphicPaint(FigureMediaGraphic.entries.getOrNull(byte())
                    ?: error("Unknown Figure graphic"), presence()) else null
                FigureMediaAfter(width, height, side, inset, bottom, paint)
            } else null
            val focus = if (presence()) FigureFocusOutline(styleLength(), figureColor(), styleLength(),
                containerMarginLength()) else null
            return FigureMediaLayout(strut, align, maximum, positioning, after, focus)
        }
        private fun tableCaptionLayout(): TableCaptionLayout {
            require(containerFonts) { "Figure table-caption layout requires M" }
            val collapse = TableCollapse.entries.getOrNull(byte()) ?: error("Unknown Figure border collapse")
            val wrapper = containerStyle()
            val table = figureBorderEdges(); val caption = figureBorderEdges()
            val media = figureMediaLayout()
            val before = if (presence()) containerStyle() else null
            val size = count(24).also { require(it <= 16) { "Too many Figure viewport states" } }
            val states = List(size) {
                FigureViewportState(u32(), containerStyle(), figureMediaLayout(), if (presence()) containerStyle() else null)
            }
            val missingPaint = if (presence()) figureLinkPaint() else null
            val captionPaint = if (presence()) figureLinkPaint() else null
            return TableCaptionLayout(collapse, wrapper, table, caption, media, before, states, missingPaint, captionPaint)
        }
        private fun figureLinkPaint(): FigureLinkPaint {
            require(buffer.remaining() >= 68) { "Truncated Figure link paint" }
            val colors = List(6) { string() }
            val mask = byte().also { require(it and 0x80 == 0) { "Unknown Figure link paint flags" } }
            val states = colors.mapIndexed { index, color -> FigureLinkState(color, mask and (1 shl index) != 0) }
            val focus = if (presence()) FigureFocusOutline(styleLength(), figureColor(), styleLength(),
                containerMarginLength()) else null
            return FigureLinkPaint(states[0], states[1], states[2], states[3], states[4], states[5],
                mask and 0x40 != 0, focus)
        }
        private fun <T> content(read: () -> T): T {
            require(contentDepth < MaxContentDepth) { "Content nesting is too deep" }
            contentDepth++
            try { return read() } finally { contentDepth-- }
        }
        private fun captionBlocks(flat: List<Span>, tableDepth: Int): List<Block>? {
            if (!imageMaps || !presence()) return null
            require(flat.isEmpty()) { "Rich caption cannot repeat flat content" }
            return content { List(count(minimumBlockBytes)) { block(tableDepth) } }
        }
        private fun scope(tableDepth: Int): BidiScope = content {
            require(buffer.remaining() >= 8) { "Truncated bidi scope" }
            val mode = BidiMode.entries.getOrNull(byte()) ?: error("Unknown bidi mode")
            val authored = when (byte()) {
                0 -> null; 1 -> BidiDirectionInput.Ltr; 2 -> BidiDirectionInput.Rtl; 3 -> BidiDirectionInput.Auto
                else -> error("Unknown authored direction")
            }
            val resolved = BidiResolvedDirection.entries.getOrNull(byte()) ?: error("Unknown resolved direction")
            val language = if (presence()) string() else null
            // Validate the header before allocating descendants; no client auto scan.
            val header = BidiScope(mode, authored, resolved, language, emptyList())
            header.copy(parts = flowParts(tableDepth))
        }
        private fun flowParts(tableDepth: Int): List<FlowPart> = List(count(5)) {
            when (byte()) {
                0 -> FlowPart.Inline(spans())
                1 -> FlowPart.ImageFigure(figure(tableDepth) ?: error("Missing flow figure"))
                2 -> FlowPart.Scope(scope(tableDepth))
                else -> error("Unknown flow part")
            }
        }
        private fun flow(tableDepth: Int): List<FlowPart>? {
            if (!imageMaps || !presence()) return null
            return content { flowParts(tableDepth) }
        }
        private fun styleLength(): StyleLength {
            val unit = when (byte()) { 0 -> StyleLengthUnit.Px; 1 -> StyleLengthUnit.Em; else -> error("Unknown style length unit") }
            require(buffer.remaining() >= 4) { "Truncated style length" }
            return StyleLength(unit, buffer.float)
        }
        private fun styleEdges() = StyleEdges(styleLength(), styleLength(), styleLength(), styleLength())
        private fun containerMarginLength(): ContainerMarginLength {
            if (!containerFonts) return styleLength()
            val unit = when (byte()) { 0 -> StyleLengthUnit.Px; 1 -> StyleLengthUnit.Em; else -> error("Unknown container margin unit") }
            require(buffer.remaining() >= 4) { "Truncated container margin" }
            val value = buffer.float
            return if (value >= 0f) StyleLength(unit, value) else SignedContainerMargin(unit, value)
        }
        private fun containerMarginEdges(): ContainerMarginEdges {
            val edges = List(4) { containerMarginLength() }
            return if (edges.all { it is StyleLength }) StyleEdges(edges[0] as StyleLength, edges[1] as StyleLength,
                edges[2] as StyleLength, edges[3] as StyleLength)
            else SignedContainerEdges(edges[0], edges[1], edges[2], edges[3])
        }
        private fun containerWidth(): ContainerWidth = when (byte()) {
            0 -> ContainerWidth.Auto
            1 -> ContainerWidth.Length(StyleWidth(StyleWidthUnit.entries.getOrNull(byte())
                ?: error("Unknown container width unit"), buffer.float))
            2 -> ContainerWidth.FitContent
            else -> error("Unknown container width")
        }
        private fun containerMaxWidth(): ContainerMaxWidth = when (byte()) {
            0 -> ContainerMaxWidth.None
            1 -> ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.entries.getOrNull(byte())
                ?: error("Unknown container maximum width unit"), buffer.float))
            else -> error("Unknown container maximum width")
        }
        private fun containerColor(): ContainerColor = when (byte()) {
            0 -> ContainerColor.Transparent
            1 -> ContainerColor.Rgb(styleRgb())
            2 -> ContainerColor.LightDark(styleRgb(), styleRgb())
            else -> error("Unknown container color")
        }
        private fun containerBorder(): ContainerBorder = when (byte()) {
            0 -> ContainerBorder.None
            1 -> ContainerBorder.Solid(styleLength(), containerColor())
            2 -> { require(containerFonts) { "Per-edge container borders require M" }
                ContainerBorder.Edges(containerBorderEdge(), containerBorderEdge(), containerBorderEdge(), containerBorderEdge()) }
            else -> error("Unknown container border")
        }
        private fun containerBorderEdge(): ContainerBorderEdge = when (byte()) {
            0 -> ContainerBorderEdge.None
            1 -> ContainerBorderEdge.Hidden
            2 -> ContainerBorderEdge.Solid(styleLength(), containerColor())
            3 -> ContainerBorderEdge.Dotted(styleLength(), containerColor())
            else -> error("Unknown container border side")
        }
        private fun containerLineHeight(): ContainerLineHeight = when (byte()) {
            0 -> ContainerLineHeight.Normal
            1 -> ContainerLineHeight.Multiplier(buffer.float)
            2 -> ContainerLineHeight.Length(styleLength())
            else -> error("Unknown container line height")
        }
        private fun containerMargin(): ContainerMargin = when (byte()) {
            0 -> ContainerMargin.Auto
            1 -> ContainerMargin.Length(containerMarginLength())
            else -> error("Unknown container margin")
        }
        private fun containerMargins() = ContainerMargins(containerMargin(), containerMargin(),
            containerMargin(), containerMargin())
        private fun containerScreen(allowFollowing: Boolean = true): ContainerScreenMaxWidth {
            val width = u32(); val flags = byte()
            require(flags != 0 && (allowFollowing || flags and 128 == 0)) { "Invalid viewport override flags" }
            return ContainerScreenMaxWidth(width, if (flags and 1 != 0) containerWidth() else null,
                if (flags and 2 != 0) containerMaxWidth() else null,
                if (flags and 4 != 0) ContainerBoxSizing.entries.getOrNull(byte())
                    ?: error("Unknown container box sizing") else null,
                if (flags and 8 != 0) containerLineHeight() else null,
                if (flags and 16 != 0) ContainerFloatOverride.entries.getOrNull(byte())
                    ?: error("Unknown viewport float override") else null,
                if (flags and 32 != 0) containerMargins() else null,
                if (flags and 64 != 0) FigureClear.entries.getOrNull(byte())
                    ?: error("Unknown viewport clear override") else null,
                if (flags and 128 != 0) {
                    val size = count(5)
                    require(size in 1..15) { "Invalid viewport override count" }
                    List(size) { containerScreen(false) }
                } else emptyList())
        }
        private fun containerStyle(): ContainerStyle {
            val flags = if (containerFonts) u32().also {
                require(it and 0xffc00000L == 0L) { "Unknown container style field" }
            }.toInt() else u16()
            return ContainerStyle(if (flags and 1 != 0) containerMarginEdges() else null,
                if (flags and 2 != 0) styleEdges() else null,
                if (flags and 4 != 0) containerWidth() else null,
                if (flags and 8 != 0) TableFloatSide.entries.getOrNull(byte()) ?: error("Unknown container float") else null,
                if (flags and 16 != 0) FigureClear.entries.getOrNull(byte()) ?: error("Unknown container clear") else null,
                if (flags and 32 != 0) containerMaxWidth() else null,
                if (flags and 64 != 0) ContainerBoxSizing.entries.getOrNull(byte()) ?: error("Unknown container box sizing") else null,
                if (flags and 128 != 0) ContainerLayout.entries.getOrNull(byte()) ?: error("Unknown container layout") else null,
                if (flags and 256 != 0) ContainerAlignItems.entries.getOrNull(byte()) ?: error("Unknown container alignment") else null,
                if (flags and 512 != 0) ContainerFlexItem.entries.getOrNull(byte()) ?: error("Unknown container flex item") else null,
                if (flags and 1024 != 0) containerColor() else null,
                if (flags and 2048 != 0) containerBorder() else null,
                if (flags and 4096 != 0) containerLineHeight() else null,
                if (flags and 8192 != 0) CellTextAlign.entries.getOrNull(byte()) ?: error("Unknown container text alignment") else null,
                if (flags and 16384 != 0) containerScreen() else null,
                if (flags and 32768 != 0) ContainerOverflow.entries.getOrNull(byte())
                    ?: error("Unknown container overflow") else null,
                if (flags and 65536 != 0) buffer.float else null,
                if (flags and 131072 != 0) styleLength() else null,
                if (flags and 262144 != 0) ContainerColumns(u16(), styleLength()) else null,
                if (flags and 524288 != 0) ContainerPositioning.entries.getOrNull(byte())
                    ?: error("Unknown container positioning") else null,
                if (flags and 1048576 != 0) styleLength() else null,
                if (flags and 2097152 != 0) containerMargins() else null)
        }
        private fun container(tableDepth: Int): Container = content {
            val style = containerStyle()
            Container(List(count(minimumBlockBytes)) { block(tableDepth) }, style).also {
                require(containerFonts || legacyContainerMarginsSupported(it)) { "Adjoining container margins require M" }
            }
        }
        private fun blockStyle(): BlockStyle? {
            if (!blockStyles || !presence()) return null
            val flags = byte(); require(flags in 1..3) { "Invalid block style flags" }
            val margins = if (flags and 1 != 0) styleEdges() else null
            val padding = if (flags and 2 != 0) styleEdges() else null
            return BlockStyle(margins, padding)
        }
        private fun styleRgb(): String = string().also { require(Regex("#[0-9a-f]{6}").matches(it)) { "Invalid style RGB" } }
        private fun styleBorder(): StyleBorder = when (byte()) {
            0 -> StyleBorder.None
            1 -> StyleBorder.Solid(styleLength(), styleRgb())
            2 -> { require(containerFonts) { "Per-edge style borders require M" }
                StyleBorder.Edges(styleBorderEdge(), styleBorderEdge(), styleBorderEdge(), styleBorderEdge()) }
            else -> error("Unknown style border")
        }
        private fun styleBorderEdge(): StyleBorderEdge = when (byte()) {
            0 -> StyleBorderEdge.None
            1 -> StyleBorderEdge.Hidden
            2 -> StyleBorderEdge.Solid(styleLength(), styleRgb())
            3 -> StyleBorderEdge.Dotted(styleLength(), styleRgb())
            else -> error("Unknown style border side")
        }
        private fun cellStyle(): CellStyle? {
            if (!tableStyles || !presence()) return null
            val flags = byte()
            val allowed = if (containerFonts) 0xef else 0x07
            require(flags != 0 && flags and allowed.inv() == 0) { "Invalid cell style flags" }
            val border = if (flags and 1 != 0) styleBorder() else null
            val padding = if (flags and 2 != 0) styleEdges() else null
            val align = if (flags and 4 != 0) when (byte()) {
                0 -> CellTextAlign.Left; 1 -> CellTextAlign.Center; 2 -> CellTextAlign.Right
                else -> error("Unknown cell text alignment")
            } else null
            val width = if (flags and 32 != 0) StyleWidth(
                StyleWidthUnit.entries.getOrNull(byte()) ?: error("Unknown cell width unit"), buffer.float) else null
            val minimum = if (flags and 64 != 0) styleLength() else null
            val vertical = if (flags and 128 != 0) when (byte()) {
                0 -> CellVerticalAlign.Top; 1 -> CellVerticalAlign.Middle
                else -> error("Unknown cell vertical alignment")
            } else null
            return CellStyle(border = border, padding = padding, textAlign = align, width = width, minWidth = minimum,
                verticalAlign = vertical, lineHeight = if (flags and 8 != 0) cellLineHeight() else null)
        }
        private fun cellMetricBasis(): FontScaleBasis = when (byte()) {
            1 -> FontScaleBasis.NormalBody
            2 -> FontScaleBasis.CssPx
            else -> error("Unknown cell text metric origin")
        }
        private fun cellLineHeight(): CellLineHeight {
            val strut = if (presence()) CellTextStrut(buffer.float, cellMetricBasis()) else null
            val height = when (byte()) {
                0 -> CellLineHeightValue.Normal
                1 -> CellLineHeightValue.Multiplier(buffer.float)
                2 -> CellLineHeightValue.Length(CellFixedLineHeight(buffer.float, cellMetricBasis()))
                else -> error("Unknown cell line height")
            }
            return CellLineHeight(height, strut)
        }
        private fun tableStyle(): TableStyle? {
            if (!tableStyles || !presence()) return null
            val flags = byte()
            val extension = if (tableFlows) byte() else 0
            require(extension in 0..(if (containerFonts) 31 else 7) && flags in 0..(if (imageMaps) 255 else if (blockLayouts) 31 else 15) &&
                (flags != 0 || extension != 0)) { "Invalid table style flags" }
            val marginFlags = extension and 0x18
            require(marginFlags == 0 || marginFlags == 0x18) { "Unpaired table margins and containing direction" }
            val background = if (flags and 1 != 0) styleRgb() else null
            val border = if (flags and 2 != 0) styleBorder() else null
            val collapse = if (flags and 4 != 0) when (byte()) {
                0 -> TableCollapse.Separate; 1 -> TableCollapse.Collapse
                else -> error("Unknown border collapse")
            } else null
            val margins = if (flags and 8 != 0) styleEdges() else null
            val floatSide = if (flags and 16 != 0) when (byte()) {
                0 -> TableFloatSide.Left; 1 -> TableFloatSide.Right
                else -> error("Unknown table float side")
            } else null
            val width = if (flags and 32 != 0) StyleWidth(
                StyleWidthUnit.entries.getOrNull(byte()) ?: error("Unknown style width unit"), buffer.float) else null
            val padding = if (flags and 64 != 0) styleEdges() else null
            val clear = if (flags and 128 != 0) FigureClear.entries.getOrNull(byte()) ?: error("Unknown table clear") else null
            val display = if (extension and 1 != 0)
                TableDisplay.entries.getOrNull(byte()) ?: error("Unknown table display") else null
            val align = if (extension and 2 != 0)
                InlineBoxVerticalAlign.entries.getOrNull(byte()) ?: error("Unknown inline table alignment") else null
            require(containerFonts || align != InlineBoxVerticalAlign.Top) { "Inline table top alignment requires M" }
            val lineHeight = if (extension and 4 != 0) {
                val value = buffer.float
                val basis = when (byte()) {
                    0 -> FontScaleBasis.Context
                    1 -> FontScaleBasis.NormalBody
                    else -> error("Unknown line height font basis")
                }
                ComputedLineHeight(value, basis)
            } else null
            val marginValues = if (extension and 8 != 0) containerMargins() else null
            val containingDirection = if (extension and 16 != 0)
                TableContainingDirection.entries.getOrNull(byte()) ?: error("Unknown table containing direction") else null
            return TableStyle(background, border, collapse, margins, floatSide, width, padding, clear, display, align,
                lineHeight, marginValues, containingDirection)
        }
        private fun tableBlockViewport(): TableBlockViewport {
            require(containerFonts) { "Table block viewport requires M" }
            return TableBlockViewport(u32(), tableStyle() ?: error("Missing table viewport box style"),
                ContainerBoxSizing.entries.getOrNull(byte()) ?: error("Unknown table viewport box sizing"),
                StyleWidth(StyleWidthUnit.entries.getOrNull(byte()) ?: error("Unknown table viewport max-width unit"), buffer.float),
                tableStyle() ?: error("Missing anonymous table grid style"),
                TableContainingDirection.entries.getOrNull(byte()) ?: error("Unknown anonymous table grid direction"),
                string())
        }
        private fun table(depth: Int): Table? {
            val tableFlags = byte()
            if (tableFlags == 0) return null
            require(tableFlags == 1 || containerFonts && tableFlags == 3) { "Invalid table presence flags" }
            require(depth <= MaxTableDepth) { "Table nesting is too deep" }
            val geometry = if (!nestedTables) null else {
                val flags = byte()
                require(flags and 0xf0 == 0) { "Unknown table geometry flags" }
                val border = if (flags and 1 != 0) u16() else null
                val spacing = if (flags and 2 != 0) u16() else null
                val padding = if (flags and 4 != 0) u16() else null
                val width = if (flags and 8 == 0) null else {
                    val unit = when (byte()) { 0 -> TableWidthUnit.Px; 1 -> TableWidthUnit.Percent; else -> error("Unknown table width unit") }
                    val value = u32()
                    require(unit != TableWidthUnit.Percent || value <= 100) { "Invalid table percent width" }
                    TableWidth(unit, value)
                }
                if (flags == 0) null else TableGeometry(border, spacing, padding, width)
            }
            val caption = spans()
            val rows = List(count(4)) { List(count(if (tableStyles) 13 else if (cellBlocks) 12 else if (nestedTables) 11 else if (colors) 10 else 9)) {
                val header = presence(); val cols = u16(); val rowspan = u16()
                require(cols in 1..100 && rowspan in 1..100) { "Invalid table span" }
                val background = if (colors && presence()) string().also {
                    require(canonicalColorArgb(it) != null) { "Invalid cell background" }
                } else null
                val content = spans()
                val child = if (nestedTables) table(depth + 1) else null
                val blocks = if (cellBlocks && presence()) List(count(minimumBlockBytes)) { block(depth) } else null
                Cell(content, header, cols, rowspan, background, child, blocks, cellStyle())
            } }
            val style = tableStyle(); val rich = captionBlocks(caption, depth)
            val blockViewport = if (tableFlags and 2 != 0) tableBlockViewport() else null
            require(containerFonts || style?.isInline != true || rows.all { row ->
                row.all { cell -> cell.spans.none { it.image != null } }
            }) { "Inline table images require M" }
            return Table(caption, rows, geometry, style, rich, blockViewport).also { tableGrid(it) }
        }
        fun block(tableDepth: Int = 0): Block {
            val kind = enum(if (containers) kinds else kinds.dropLast(1)); val depth = byte(); val level = byte()
            val spans = spans()
            val feature = if (presence()) Feature(string(), string(), string(), string(), string()) else null
            val path = string(); val number = string()
            val table = table(tableDepth + 1)
            val anchor = if (anchors) string() else ""
            val fallback = if (anchors) string() else ""
            require(kind == "heading" || (anchor.isEmpty() && fallback.isEmpty())) { "Only headings may have a destination anchor" }
            val textAlign = if (blockLayouts && presence()) when (byte()) {
                0 -> CellTextAlign.Left; 1 -> CellTextAlign.Center; 2 -> CellTextAlign.Right
                else -> error("Unknown block text alignment")
            } else null
            val style = blockStyle(); val figure = figure(tableDepth); val flow = flow(tableDepth)
            val container = if (kind == "container") container(tableDepth) else null
            return Block(kind, depth, spans, path, number, table, feature, level, anchor, fallback, textAlign,
                style, figure, flow, container)
        }
    }
}
