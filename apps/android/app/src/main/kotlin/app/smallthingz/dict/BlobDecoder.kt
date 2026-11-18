package app.smallthingz.dict

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction

/** Direct DPR2-DPRV, DPRY and DPRZ decoder. Dictionary presentation never passes through JSON or source text. */
object BlobDecoder {
    private val kinds = listOf("paragraph", "blank", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "heading", "preformatted", "rule", "table", "container")
    private val roles = listOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference")
    private val inline = listOf("text", "link", "external_link", "line_break")
    fun decode(bytes: ByteArray, title: String, kind: String, language: String?, code: String): Entry {
        val r = Reader(bytes)
        require(r.byte() == 68 && r.byte() == 80 && r.byte() == 82) { "Unsupported presentation format" }
        val magicVersion = r.byte()
        require(magicVersion in 50..57 || magicVersion in 65..86 || magicVersion == 89 || magicVersion == 90) { "Unsupported presentation format" }
        val extendedFeatures = magicVersion == 90
        val ownerGeometry = magicVersion == 89 || extendedFeatures
        val ownerGeometryFlags = if (extendedFeatures) r.u16().also {
            // All implemented Y low bits compose with the existing Z high features.
            require(it and 62208 != 0 && it and 62463 == it &&
                (it and 32768 == 0 || it and 16384 != 0 && it and 1 != 0)) { "Invalid extended presentation feature flags" }
        } else if (ownerGeometry) r.byte().also {
            require(it in 1..255) { "Invalid owner geometry feature flags" }
        } else 0
        val positionedContainers = ownerGeometryFlags and 256 != 0
        r.ownerGeometry = ownerGeometry
        r.positionedContainers = positionedContainers
        r.tableMinimumWidths = ownerGeometryFlags and 512 != 0
        r.columnLayouts = ownerGeometryFlags and 4096 != 0
        r.audioControls = ownerGeometryFlags and 8192 != 0
        r.containerOwnerFonts = ownerGeometryFlags and 1 != 0
        r.inlineBoxGroups = ownerGeometryFlags and 4 != 0
        r.imageOccurrences = ownerGeometryFlags and 32 != 0
        r.citationNavigation = ownerGeometryFlags and 64 != 0
        r.clippedAbsolutes = ownerGeometryFlags and 128 != 0
        val version = if (magicVersion in 65..86 || ownerGeometry) 57 else magicVersion
        r.fontScales = magicVersion in 65..86 || ownerGeometry
        r.fontScaleBases = magicVersion in 66..86 || ownerGeometry
        r.tableStyles = magicVersion in 67..86 || ownerGeometry
        r.inlineImages = magicVersion in 67..86 || ownerGeometry
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
        r.ruleStyles = magicVersion >= 78
        r.rubySpans = magicVersion >= 83
        r.inlinePaddingGroups = magicVersion >= 85
        r.inlineActionGroups = magicVersion >= 86
        r.tableDepthLimit = if (magicVersion >= 84) MaxTableDepth else LegacyMaxTableDepth
        r.ruleClears = magicVersion >= 82
        r.imageLinkPaints = magicVersion >= 82
        r.inlineStyles = magicVersion >= 79
        r.extendedFontFamilies = magicVersion >= 80
        r.tableFloatClears = magicVersion >= 80
        r.textFlow = magicVersion >= 80
        r.tableScrollPairs = magicVersion >= 80
        r.absoluteText = magicVersion >= 80
        r.cellOwnerFonts = magicVersion >= 80
        r.tableCorners = magicVersion >= 81
        r.tableIntrinsicViewports = magicVersion >= 82
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
        val features = if (magicVersion >= 80) r.byte().also {
            require(magicVersion >= 81 || it != 0) { "Unsupported body adjoining policy" }
            // All eight P features have exact recursive payload census checks below.
        } else 0
        val bodyAdjoining = if (features and 1 != 0) BodyAdjoiningPolicy.Ordinary else null
        val styledSections = if (features and 2 != 0) {
            val count = r.count(4)
            require(count > 0) { "Empty heading style list" }
            val result = sections.toMutableList()
            var previous = -1
            repeat(count) {
                val index = r.index(sections.size)
                require(index > previous) { "Heading indices must be strictly ascending" }
                result[index] = sections[index].copy(headingStyle = r.sectionHeadingStyle(features and 16 != 0))
                previous = index
            }
            result
        } else sections
        val directions = ownerGeometryFlags and 16 != 0
        val bodyTypography = if (ownerGeometryFlags and 2 != 0) r.bodyTypography(directions) else null
        val styledReferences = if (ownerGeometryFlags and 8 != 0) references.map { reference ->
            if (r.presence()) reference.copy(bodyTypography = r.bodyTypography(directions)) else reference
        } else references
        val navigationReferences = if (r.citationNavigation) styledReferences.map {
            it.copy(backlinks = r.citationBacklinks())
        } else styledReferences
        require((features and 8 != 0) == r.hasTableFloatClearFeature) { "Table float clear feature does not match payload" }
        require((features and 16 != 0) == r.hasTextFlowFeature) { "Text flow feature does not match payload" }
        require((features and 32 != 0) == r.hasTableScrollFeature) { "Table scroll feature does not match payload" }
        require((features and 64 != 0) == r.hasAbsoluteTextFeature) { "Absolute text feature does not match payload" }
        require((features and 128 != 0) == r.hasCellOwnerFontFeature) { "Cell owner font feature does not match payload" }
        require(r.tableIntrinsicViewports || r.tableCorners == (r.hasTableCorners || r.hasInlineImageAlignment)) {
            "Q version does not match corner or image alignment payload"
        }
        require(r.rubySpans || r.tableIntrinsicViewports == (r.hasTableIntrinsicViewport || r.hasRuleClearFeature || r.hasImageLinkPaintFeature)) {
            "R version does not match intrinsic table viewport, rule clear, or image link paint payload"
        }
        require(magicVersion >= 84 || r.rubySpans == r.hasRuby) { "S version does not match ruby payload" }
        require(magicVersion >= 85 || (magicVersion == 84) == (r.maximumTableDepth > LegacyMaxTableDepth)) {
            "T version does not match deep table payload"
        }
        require(ownerGeometry || magicVersion == 86 || r.inlinePaddingGroups == r.hasInlinePaddingGroup) { "U version does not match inline padding payload" }
        require(ownerGeometry || r.inlineActionGroups == r.hasInlineActionGroup) { "V version does not match inline action payload" }
        var referenceBatches = if (ownerGeometryFlags and 16384 != 0) {
            require(r.presence()) { "Reference batch capability requires a present owner" }
            val count = r.count(16)
            require(count > 0) { "Empty reference batch owner" }
            List(count) {
                val section = r.index(styledSections.size)
                val boundary = r.u32()
                require(boundary <= styledSections[section].blocks.size.toLong()) { "Invalid reference block boundary" }
                val indices = r.indices(navigationReferences.size)
                require(indices.isNotEmpty()) { "Empty reference batch" }
                ReferenceBatchPlacement(section, boundary.toInt(), indices)
            }
        } else null
        if (ownerGeometryFlags and 32768 != 0) {
            referenceBatches = r.referenceLayouts(checkNotNull(referenceBatches))
        }
        require((features and 4 != 0) == r.hasFontFamilyFeature) { "Font family feature does not match payload" }
        require(r.containerOwnerFonts == r.hasContainerOwnerFont && r.inlineBoxGroups == r.hasInlineBoxGroup &&
            (ownerGeometryFlags and 2 != 0) == (bodyTypography != null) &&
            (ownerGeometryFlags and 8 != 0) == styledReferences.any { it.bodyTypography != null } &&
            directions == (bodyTypography?.direction != null || styledReferences.any { it.bodyTypography?.direction != null }) &&
            r.imageOccurrences == r.hasImageOccurrence && positionedContainers == r.hasPositionedContainers &&
            r.tableMinimumWidths == r.hasTableMinimumWidth && r.columnLayouts == r.hasColumnLayout &&
            r.audioControls == r.hasAudioControl && r.clippedAbsolutes == r.hasClippedAbsolute) {
            "Y/Z features do not match owner geometry payload"
        }
        require(r.citationNavigation == r.hasCitationNavigation) { "Citation feature does not match payload" }
        require(!r.buffer.hasRemaining()) { "Trailing presentation data" }
        val entry = Entry(title, display, kind, language, code, styledSections, navigationReferences, preamble, media,
            etymologySections = etymologySections.toSet(), organization = organization.takeIf { r.containers },
            bodyAdjoining = bodyAdjoining, bodyTypography = bodyTypography, referenceBatches = referenceBatches)
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
        var rubySpans = false
        var hasRuby = false
        var inlinePaddingGroups = false
        var hasInlinePaddingGroup = false
        var inlineActionGroups = false
        var hasInlineActionGroup = false
        var citationNavigation = false
        var hasCitationNavigation = false
        var ownerGeometry = false
        var positionedContainers = false
        var hasPositionedContainers = false
        var tableMinimumWidths = false
        var hasTableMinimumWidth = false
        var columnLayouts = false
        var hasColumnLayout = false
        var audioControls = false
        var hasAudioControl = false
        var containerOwnerFonts = false
        var hasContainerOwnerFont = false
        var inlineBoxGroups = false
        var hasInlineBoxGroup = false
        var imageOccurrences = false
        var hasImageOccurrence = false
        var clippedAbsolutes = false
        var hasClippedAbsolute = false
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
        var ruleStyles = false
        var ruleClears = false
        var hasRuleClearFeature = false
        var imageLinkPaints = false
        var hasImageLinkPaintFeature = false
        var inlineStyles = false
        var extendedFontFamilies = false
        var tableFloatClears = false
        var textFlow = false
        var hasTextFlowFeature = false
        var absoluteText = false
        var hasAbsoluteTextFeature = false
        var tableCorners = false
        var hasTableCorners = false
        var hasInlineImageAlignment = false
        var tableIntrinsicViewports = false
        var hasTableIntrinsicViewport = false
        var cellOwnerFonts = false
        var hasCellOwnerFontFeature = false
        private var positionedParent = false
        private var positionedActive = false
        var tableScrollPairs = false
        var hasTableScrollFeature = false
        var hasTableFloatClearFeature = false
        var hasFontFamilyFeature = false
            private set
        private var remainingMapStringBytes = 32L * 1024 * 1024
        private var contentDepth = 0
        var tableDepthLimit = LegacyMaxTableDepth
        var maximumTableDepth = 0
            private set
        val minimumBlockBytes: Int get() = (if (imageMaps) 29 else if (blockStyles) 27 else if (blockLayouts) 26 else if (anchors) 25 else 17) + if (columnLayouts) 1 else 0
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
        fun spans(): List<Span> = List(count((if (inlineBoxGroups) 41 else if (inlineActionGroups) 40 else if (inlinePaddingGroups) 39 else if (rubySpans) 38 else if (tooltips) 37 else if (targetFragments) 36 else if (inlineImages) 35 else if (fontScales) 34 else if (spanBackgrounds) 33 else if (colors) 32 else if (explanations) 31 else 27) + (if (audioControls) 1 else 0) + (if (clippedAbsolutes) 1 else 0))) { span() }
        private fun span(citationBacklink: Boolean = false): Span {
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
                require(it and (if (inlineBoxGroups) 0x80 else if (extendedFontFamilies) 0xe0 else if (inlineStyles) 0xf0 else 0xf8) == 0) { "Unknown span font fields" }
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
            val linkPaint = if (fontFields and 4 != 0) {
                require(presence()) { "Span link paint requires a present policy" }
                ordinaryLinkPaint()
            } else null
            val inlineStyle = if (fontFields and 8 != 0) inlineTextStyle() else null
            val fontFamily = if (fontFields and 16 != 0) inlineFontFamily() else null
            val fontScale = rawScale?.takeUnless { it == 1f && basis == FontScaleBasis.Context }
            val imageTag = if (inlineImages) byte() else 0
            require(imageTag in 0..1 || containerFonts && imageTag == 2 ||
                tableCorners && containerFonts && imageTag == 3) { "Unsupported inline image tag" }
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
                        string(), string(), string()) else null,
                    verticalAlign = if (imageTag == 3) {
                        (InlineImageVerticalAlign.entries.getOrNull(byte()) ?: error("Unknown inline image alignment"))
                            .also { hasInlineImageAlignment = true }
                    } else null,
                    occurrenceLayout = if (imageOccurrences && presence()) imageOccurrenceLayout() else null)
            } else null
            val targetFragment = if (targetFragments && presence()) string() else null
            val tooltip = if (tooltips && presence()) string() else null
            val ruby = if (rubySpans && presence()) ruby() else null
            val inlinePaddingGroup = if (inlinePaddingGroups && presence()) inlinePaddingGroup() else null
            val inlineActionGroup = if (inlineActionGroups && presence()) inlineActionGroup() else null
            val radiusDeclared = fontFields and 0x20 != 0
            val atomicDeclared = fontFields and 0x40 != 0
            val inlineBoxGroup = if (inlineBoxGroups && presence()) inlineBoxGroup(radiusDeclared, atomicDeclared) else null
            require(!radiusDeclared || inlineBoxGroup != null) { "Inline box radius requires its same-owner box" }
            require(!atomicDeclared || inlineBoxGroup != null) { "Atomic layout requires its same-owner inline box" }
            val citationMarker = if (citationNavigation && presence()) citationMarker() else null
            val audioControl = if (audioControls && presence()) audioControl() else null
            val clippedAbsolute = if (clippedAbsolutes && presence()) clippedAbsolute() else null
            if (image != null && linkPaint != null) {
                require(imageLinkPaints) { "Image link paint requires R" }
                hasImageLinkPaintFeature = true
            }
            val source = Span(kind, text, target, trail, language, classes, direction,
                bold=f and 1 != 0, italic=f and 2 != 0, code=f and 4 != 0, small=f and 8 != 0,
                superscript=f and 16 != 0, subscript=f and 32 != 0, strike=f and 64 != 0, underline=f and 128 != 0, role=role, explanation=explanation, foreground=foreground, background=background, fontScale=fontScale, fontScaleBasis=basis, image=image, targetFragment=targetFragment, tooltip=tooltip, fontFeatures=fontFeatures, linkPaint=linkPaint.takeUnless { citationBacklink }, inlineStyle=inlineStyle.takeUnless { citationBacklink }, fontFamily=fontFamily, ruby=ruby, inlinePaddingGroup=inlinePaddingGroup, inlineActionGroup=inlineActionGroup, inlineBoxGroup=inlineBoxGroup, citationMarker=citationMarker, audioControl=audioControl, clippedAbsolute=clippedAbsolute)
            return if (citationBacklink) CitationBacklinkSpanWitness.withPolicies(source, linkPaint, inlineStyle) else source
        }
        private fun audioControl(): AudioControl {
            require(remainingItems > 0 && buffer.remaining() >= 1) { "Audio control is truncated or exceeds the item budget" }
            remainingItems--
            val fields = byte()
            require(fields and 7 == fields) { "Unknown audio control fields" }
            val width = if (fields and 1 != 0) StyleWidth(StyleWidthUnit.entries.getOrNull(byte())
                ?: error("Unknown audio width unit"), buffer.float) else null
            val height = if (fields and 2 != 0) styleLength() else null
            val focus = if (fields and 4 != 0) {
                require(remainingItems > 0 && buffer.remaining() >= 2) { "Audio focus is truncated or exceeds the item budget" }
                remainingItems--
                AudioControlFocusPaint(AudioControlFocusMode.entries.getOrNull(byte())
                    ?: error("Unknown audio focus mode"), if (presence()) figureColor() else null)
            } else null
            hasAudioControl = true
            return AudioControl(width, height, focus)
        }
        private fun citationMarker(): CitationMarker {
            require(remainingItems > 0) { "Citation marker exceeds the presentation budget" }
            remainingItems--
            val reference = u32(); val occurrence = u32(); val anchor = string()
            val policy = byte()
            require(policy and 7 == policy) { "Unknown citation marker policy" }
            val isolation = if (policy and 4 != 0)
                BidiResolvedDirection.entries.getOrNull(byte()) ?: error("Unknown citation isolation") else null
            val targeted = if (policy and 2 != 0)
                CitationTargetStyle(ordinaryLinkPaint(), if (presence()) figureColor() else null) else null
            hasCitationNavigation = true
            return CitationMarker(reference, occurrence, anchor, policy and 1 != 0, isolation, targeted)
        }
        fun citationBacklinks(): List<ReferenceBacklink> = List(count(7 + (if (audioControls) 1 else 0) + (if (clippedAbsolutes) 1 else 0))) {
            val occurrence = u32()
            require(remainingItems > 0) { "Citation backlink span exceeds the presentation budget" }
            remainingItems--
            ReferenceBacklink.withPolicies(occurrence, span(citationBacklink = true)).also { hasCitationNavigation = true }
        }
        private fun clippedAbsolute(): ClippedAbsoluteInline = content {
            require(buffer.remaining() >= 35) { "Truncated clipped absolute inline" }
            val staticParentDirection = when (byte()) {
                1 -> BidiResolvedDirection.Ltr
                2 -> BidiResolvedDirection.Rtl
                else -> throw IllegalArgumentException("Invalid clipped static-parent direction")
            }
            val width = styleLength()
            val height = styleLength()
            val margin = ContainerMargins(ContainerMargin.Length(containerMarginLength()), ContainerMargin.Length(containerMarginLength()),
                ContainerMargin.Length(containerMarginLength()), ContainerMargin.Length(containerMarginLength()))
            ClippedAbsoluteInline(width, height, margin, spans(), staticParentDirection).also { hasClippedAbsolute = true }
        }
        private fun imageOccurrenceLayout(): InlineImageOccurrenceLayout {
            require(imageOccurrences && remainingItems > 0 && buffer.remaining() >= 20) {
                "Image occurrence layout exceeds the presentation budget or is truncated"
            }
            remainingItems--
            val result = InlineImageOccurrenceLayout(containerMarginLength(), containerMarginLength(), styleLength(), styleLength())
            hasImageOccurrence = true
            return result
        }
        private fun inlineBoxColor(): InlineBoxColor = when (byte()) {
            0 -> InlineBoxColor.CurrentColor
            1 -> InlineBoxColor.Transparent
            2 -> InlineBoxColor.Rgb(styleRgb())
            3 -> InlineBoxColor.LightDark(styleRgb(), styleRgb())
            else -> error("Unknown inline box color")
        }
        private fun inlineBoxBorderEdge(): InlineBoxBorderEdge = when (byte()) {
            0 -> InlineBoxBorderEdge.None
            1 -> InlineBoxBorderEdge.Hidden
            2 -> InlineBoxBorderEdge.Solid(styleLength(), inlineBoxColor())
            3 -> InlineBoxBorderEdge.Dotted(styleLength(), inlineBoxColor())
            else -> error("Unknown inline box border")
        }
        private fun inlineBoxBorders() = InlineBoxBorderEdges(inlineBoxBorderEdge(), inlineBoxBorderEdge(),
            inlineBoxBorderEdge(), inlineBoxBorderEdge())
        private fun inlineBoxInset(): InlineBoxInset = InlineBoxInset(
            StyleWidthUnit.entries.getOrNull(byte()) ?: error("Unknown inline box inset unit"), buffer.float)
        private fun inlineBoxAtomicLayout(): InlineBoxAtomicLayout {
            require(containerFonts && extendedFontFamilies && remainingItems > 0 && buffer.remaining() >= 34) {
                "Atomic inline layout requires M/P and its presentation budget"
            }
            remainingItems--
            val width = styleLength(); val height = styleLength(); val margins = styleEdges()
            val boxSizing = ContainerBoxSizing.entries.getOrNull(byte()) ?: error("Unknown atomic inline box sizing")
            val align = InlineBoxOverlayTextAlign.entries.getOrNull(byte()) ?: error("Unknown atomic inline text alignment")
            val wrap = when (byte()) {
                0 -> TextWrap.Normal
                1 -> TextWrap.BreakWord
                else -> error("Unknown atomic inline wrapping")
            }
            val lineHeight = when (byte()) {
                0 -> null
                1 -> InlineLineHeight.Computed(inlineComputedLength())
                2 -> InlineLineHeight.FontRelative(buffer.float, inlineFontSnapshot())
                else -> error("Unknown atomic inline line-height tag")
            }
            return InlineBoxAtomicLayout(width, height, margins, boxSizing, align, wrap, lineHeight)
        }
        private fun inlineBoxOverlayContent(): InlineBoxOverlayContent = content {
            // Boundary + complete normalized font + height/alignment tags + child count.
            require(buffer.remaining() >= 26) { "Truncated inline box overlay content" }
            val boundary = u32()
            val font = inlineFontSnapshot()
            val height = when (byte()) {
                0 -> null
                1 -> InlineLineHeight.Computed(inlineComputedLength())
                2 -> InlineLineHeight.FontRelative(buffer.float, inlineFontSnapshot())
                else -> error("Unknown overlay line-height tag")
            }
            val align = InlineBoxOverlayTextAlign.entries.getOrNull(byte()) ?: error("Unknown overlay text alignment")
            InlineBoxOverlayContent(boundary, font, height, align, spans())
        }
        private fun inlineBoxGroup(radiusDeclared: Boolean, atomicDeclared: Boolean): InlineBoxGroup = content {
            require(buffer.remaining() >= 32 + (if (radiusDeclared) 5 else 0) + (if (atomicDeclared) 34 else 0)) {
                "Truncated inline box group"
            }
            val padding = styleEdges()
            val border = inlineBoxBorders()
            val overlays = List(count(15)) {
                val flags = byte()
                require(flags and 0xe0 == 0 && flags and 5 != 0 && flags and 10 != 0) {
                    "Inline box overlay requires two positioned axes"
                }
                InlineBoxOverlay(InlineBoxInsets(
                    if (flags and 1 != 0) inlineBoxInset() else null,
                    if (flags and 2 != 0) inlineBoxInset() else null,
                    if (flags and 4 != 0) inlineBoxInset() else null,
                    if (flags and 8 != 0) inlineBoxInset() else null), inlineBoxBorders(),
                    if (flags and 16 != 0) inlineBoxOverlayContent() else null)
            }
            val children = spans()
            val radius = if (radiusDeclared) {
                val unit = when (byte()) {
                    0 -> StyleWidthUnit.Px
                    2 -> StyleWidthUnit.Percent
                    else -> error("Unknown inline box radius unit")
                }
                require(buffer.remaining() >= 4) { "Truncated inline box radius" }
                StyleWidth(unit, buffer.float)
            } else null
            val atomic = if (atomicDeclared) inlineBoxAtomicLayout() else null
            InlineBoxGroup(padding, border, overlays, children, radius, atomic).also { hasInlineBoxGroup = true }
        }
        fun bodyTypography(directions: Boolean): BodyTypography {
            require(remainingItems > 0) { "Body typography exceeds the presentation budget" }
            remainingItems--
            val font = inlineFontSnapshot()
            val lineHeight = if (presence()) containerLineHeight() else null
            val direction = if (directions) when (byte()) {
                0 -> null
                1 -> BidiResolvedDirection.Ltr
                2 -> BidiResolvedDirection.Rtl
                else -> error("Unknown body paragraph direction")
            } else null
            return BodyTypography(font, lineHeight, direction)
        }
        private fun inlinePaddingGroup(): InlinePaddingGroup = content {
            require(buffer.remaining() >= 14) { "Truncated inline padding group" }
            InlinePaddingGroup(styleLength(), styleLength(), spans()).also { hasInlinePaddingGroup = true }
        }
        private fun inlineActionGroup(): InlineActionGroup = content {
            require(buffer.remaining() >= 4) { "Truncated inline action group" }
            InlineActionGroup(spans()).also { hasInlineActionGroup = true }
        }
        private fun ruby(): Ruby = content {
            val segments = List(count(38)) {
                val gap = spans()
                val bases = List(count(26)) {
                    val before = spans()
                    RubyBase(rubyOwner(), before, spans())
                }
                val annotations = List(count(47)) {
                    RubyAnnotation(u32(), u32(), u32(), rubyOwner(), spans(), spans(), spans(), spans(), presence())
                }
                RubySegment(gap, bases, annotations)
            }
            Ruby(segments).also { hasRuby = true }
        }
        private fun rubyOwner(): RubyOwner {
            require(remainingItems > 0 && buffer.remaining() >= 18) { "Ruby owner exceeds the presentation budget" }
            remainingItems--
            return RubyOwner(inlineFontSnapshot(), string(), if (presence()) inlineTextStyle() else null,
                if (presence()) styleRgb() else null, if (presence()) styleRgb() else null)
        }
        private fun inlineComputedLength(): InlineComputedLength = InlineComputedLength(buffer.float, cellMetricBasis())
        private fun inlineFontSnapshot(requireOmittedSize: Boolean = false): InlineFontSnapshot {
            val flags = byte()
            require(!requireOmittedSize || flags and 1 == 0) { "Cell owner font repeats its strut size" }
            require(flags and 0xe0 == 0) { "Unknown inline snapshot flags" }
            val rawScale = if (flags and 1 != 0) buffer.float else null
            val basis = if (rawScale != null) FontScaleBasis.entries.getOrNull(byte())
                ?: error("Unknown inline snapshot basis") else FontScaleBasis.Context
            val scale = rawScale?.takeUnless { it == 1f && basis == FontScaleBasis.Context }
            val face = byte()
            require(face and (if (extendedFontFamilies) 0xe0 else 0xf0) == 0) { "Unknown inline snapshot face flags" }
            val language = string(); val classes = string(); val role = enum(roles)
            val features = if (face and 8 != 0) FontFeaturePolicy.entries.getOrNull(byte())
                ?: error("Unknown inline snapshot font feature policy") else null
            val family = if (face and 16 != 0) inlineFontFamily() else null
            return InlineFontSnapshot(scale, basis, flags and 2 != 0, flags and 4 != 0,
                flags and 8 != 0, flags and 16 != 0, face and 1 != 0, face and 2 != 0,
                face and 4 != 0, language, classes, role, features, family)
        }
        private fun inlineTextStyle(): InlineTextStyle {
            require(inlineStyles) { "Inline text effects require O" }
            val flags = byte()
            require(flags != 0 && flags and (if (textFlow) 0xc0 else 0xe0) == 0) { "Invalid inline text effect flags" }
            val decoration = if (flags and 1 != 0) InlineUnderline(
                InlineUnderlineStyle.entries.getOrNull(byte()) ?: error("Unknown inline underline style"),
                if (presence()) string() else null, if (presence()) styleLength() else null) else null
            val lineHeight = if (flags and 2 != 0) when (byte()) {
                0 -> InlineLineHeight.Computed(inlineComputedLength())
                1 -> InlineLineHeight.FontRelative(buffer.float, inlineFontSnapshot())
                else -> error("Unknown inline line-height tag")
            } else null
            val baselineShift = if (flags and 4 != 0) inlineComputedLength() else null
            val cursor = if (flags and 16 != 0) InlineCursor.entries.getOrNull(byte())
                ?: error("Unknown inline cursor") else null
            val wrap = if (flags and 32 != 0) textWrap().also { hasTextFlowFeature = true } else null
            return InlineTextStyle(decoration, lineHeight, baselineShift, flags and 8 != 0, cursor, wrap)
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
        private fun figure(tableDepth: Int): Figure? = positionedRoot {
            if (!imageMaps) return@positionedRoot null
            val tag = byte()
            if (tag == 0) return@positionedRoot null
            require(tag == 1 || tableFlows && tag == 2 || containerFonts && tag in 5..7) { "Unknown figure content tag" }
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
            val tableCaption = if (tag == 5 || tag == 6) tableCaptionLayout() else null
            val blockMedia = if (tag == 7) figureBlockMediaLayout() else null
            Figure(content, format, placement, clear, margins, insets, padding, scale, lineHeight,
                frameBackground, frameBorder, imageBackground, imageBorder, captionForeground, captionBackground,
                caption, rich, align, frameMinWidth, tableCaption, blockMedia)
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
            val positioning = if (presence()) containerPositioning() else null
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
        private fun figureBlockMediaLayout(): FigureBlockMediaLayout {
            require(containerFonts) { "Figure block-media layout requires M" }
            val wrapper = containerStyle(); val media = figureMediaLayout()
            val preferredWidth = u32(); val naturalWidth = u32(); val naturalHeight = u32()
            val rendition1x = FigureBlockMediaRendition(string(), string())
            val rendition2x = FigureBlockMediaRendition(string(), string())
            val size = count(24).also { require(it <= 16) { "Too many Figure block viewport states" } }
            val states = List(size) { FigureBlockMediaState(u32(), containerStyle(), figureMediaLayout()) }
            return FigureBlockMediaLayout(wrapper, media, preferredWidth, naturalWidth, naturalHeight,
                rendition1x, rendition2x, states)
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
        private fun ordinaryLinkPaint(): LinkPaint {
            val prefix = figureLinkPaint()
            require(buffer.remaining() >= 23) { "Truncated combined link paint states" }
            val hoverActive = string(); val visitedHoverActive = string()
            val flags = byte().also { require(it and 0xfc == 0) { "Unknown combined link paint flags" } }
            return LinkPaint(prefix.normal, prefix.hover, prefix.active, LinkState(hoverActive, flags and 1 != 0),
                prefix.visited, prefix.visitedHover, prefix.visitedActive, LinkState(visitedHoverActive, flags and 2 != 0),
                prefix.underlineOnFocus, prefix.focusOutline)
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
        private fun textWrap(): TextWrap = TextWrap.entries.getOrNull(byte()) ?: error("Unknown text wrap policy")
        fun sectionHeadingStyle(extensions: Boolean): SectionHeadingStyle {
            val box = containerStyle()
            val font = inlineFontSnapshot()
            val direction = BidiResolvedDirection.entries.getOrNull(byte()) ?: error("Unknown heading direction")
            val flags = if (extensions) byte().also { require(it and 0xfc == 0) { "Unknown heading text flow flags" } } else 0
            val wrap = if (flags and 1 != 0) textWrap() else null
            val reveal = if (flags and 2 != 0) HeadingAnchorReveal(styleLength(), if (presence()) styleLength() else null) else null
            if (flags != 0) hasTextFlowFeature = true
            return SectionHeadingStyle(box, font, direction, wrap, reveal)
        }
        private fun inlineFontFamily(): ContainerFontFamily {
            require(extendedFontFamilies) { "Inline font families require P" }
            return containerFontFamily().also { hasFontFamilyFeature = true }
        }
        private fun containerFontFamily(): ContainerFontFamily = when (byte()) {
            0 -> ContainerFontFamily.SansSerif
            1 -> {
                require(extendedFontFamilies) { "Font family stacks require P" }
                val size = count(4)
                require(size <= 16) { "Too many named font families" }
                ContainerFontFamily.Stack(List(size) { string() }, GenericFontFamily.entries.getOrNull(byte())
                    ?: error("Unknown generic font family")).also { hasFontFamilyFeature = true }
            }
            else -> error("Unknown container font family")
        }
        private fun containerPositioning(): ContainerPositioning = when (byte()) {
            0 -> ContainerPositioning.RelativeAuto
            1 -> {
                require(absoluteText) { "Absolute text requires P" }
                ContainerPositioning.Absolute(styleLength(), styleLength(), inlineFontSnapshot(), inlineComputedLength(), textWrap())
                    .also { hasAbsoluteTextFeature = true }
            }
            else -> error("Unknown container positioning")
        }
        private fun positionedScope(): PositionedScope {
            require(absoluteText) { "Positioned scope requires P" }
            val wrap = textWrap()
            val x = PositionedOverflowX.entries.getOrNull(byte()) ?: error("Unknown positioned horizontal overflow")
            val y = PositionedOverflowY.entries.getOrNull(byte()) ?: error("Unknown positioned vertical overflow")
            val size = count(6).also { require(it <= 16) { "Too many positioned viewport states" } }
            val states = List(size) { PositionedViewportState(u32(),
                PositionedOverflowX.entries.getOrNull(byte()) ?: error("Unknown positioned horizontal overflow"),
                PositionedOverflowY.entries.getOrNull(byte()) ?: error("Unknown positioned vertical overflow")) }
            return PositionedScope(wrap, x, y, states).also { hasAbsoluteTextFeature = true }
        }
        private inline fun <T> positionedRoot(read: () -> T): T {
            val previous = positionedParent
            positionedParent = false
            return try { read() } finally { positionedParent = previous }
        }
        private fun containerOwnerFont(): InlineFontSnapshot {
            require(containerOwnerFonts && remainingItems > 0) { "Container owner font exceeds the presentation budget" }
            remainingItems--
            return inlineFontSnapshot().also { hasContainerOwnerFont = true }
        }
        private fun containerDisclosureLabelRun(): ContainerDisclosureLabelRun {
            require(remainingItems > 0 && buffer.remaining() >= 53) { "Truncated disclosure label run or exhausted budget" }
            remainingItems--
            val start = u32(); val end = u32()
            val normal = string(); val hover = string(); val active = string(); val hoverActive = string()
            val flags = byte().also { require(it and 31 == it) { "Unknown disclosure text paint flags" } }
            return ContainerDisclosureLabelRun(start, end, ContainerDisclosureTextPaint(
                LinkState(normal, flags and 1 != 0), LinkState(hover, flags and 2 != 0),
                LinkState(active, flags and 4 != 0), LinkState(hoverActive, flags and 8 != 0), flags and 16 != 0))
        }
        private fun containerDisclosure(): ContainerDisclosure {
            require(positionedContainers && remainingItems > 0 && buffer.remaining() >= 18) {
                "Truncated disclosure or exhausted budget"
            }
            remainingItems--
            val index = u32(); val collapsed = presence()
            val expand = string(); val collapse = string()
            val focus = if (presence()) {
                require(remainingItems > 0 && buffer.remaining() >= 2) { "Truncated disclosure focus or exhausted budget" }
                remainingItems--
                ContainerDisclosureFocusPaint(ContainerDisclosureFocusMode.entries.getOrNull(byte())
                    ?: error("Unknown disclosure focus mode"), if (presence()) figureColor() else null)
            } else null
            val placement = ContainerDisclosurePlacement.entries.getOrNull(byte()) ?: error("Unknown disclosure placement")
            val fields = byte().also { require(it and 15 == it) { "Unknown disclosure fields" } }
            val foreground = if (fields and 1 != 0) figureColor() else null
            val direction = if (fields and 2 != 0) BidiResolvedDirection.entries.getOrNull(byte())
                ?: error("Unknown disclosure direction") else null
            val expandRun = if (fields and 4 != 0) containerDisclosureLabelRun() else null
            val collapseRun = if (fields and 8 != 0) containerDisclosureLabelRun() else null
            return ContainerDisclosure(index, collapsed, expand, collapse, focus, placement, foreground,
                direction, expandRun, collapseRun).also { hasPositionedContainers = true }
        }
        private fun containerStyle(readDisclosure: ((ContainerDisclosure) -> Unit)? = null): ContainerStyle {
            val flags = if (containerFonts) u32().also {
                val reserved = if (ownerGeometry) {
                    if (containerOwnerFonts) 0xfe800000L else 0xff800000L
                } else if (absoluteText) 0xff000000L else 0xff800000L
                require(it and (if (columnLayouts) reserved and 0x02000000L.inv() else reserved) == 0L) { "Unknown container style field" }
            }.toInt() else u16()
            require(flags and 0x02000000 == 0 || flags and 0x40000 != 0) { "Column extension requires its count and gap prefix" }
            var extendedColumns: Pair<Int, StyleLength>? = null
            val base = ContainerStyle(if (flags and 1 != 0) containerMarginEdges() else null,
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
                if (flags and 32768 != 0) (ContainerOverflow.entries.getOrNull(byte())
                    ?: error("Unknown container overflow")).also {
                    require(containerFonts || it != ContainerOverflow.Hidden) { "Hidden container overflow requires M" }
                } else null,
                if (flags and 65536 != 0) buffer.float else null,
                if (flags and 131072 != 0) styleLength() else null,
                if (flags and 262144 != 0) {
                    val count = u16(); val gap = styleLength()
                    if (flags and 0x02000000 != 0) { extendedColumns = count to gap; null }
                    else ContainerColumns(count, gap)
                } else null,
                if (flags and 524288 != 0) containerPositioning() else null,
                if (flags and 1048576 != 0) styleLength() else null,
                if (flags and 2097152 != 0) containerMargins() else null,
                if (flags and 4194304 != 0) containerFontFamily() else null,
                if (flags and 8388608 != 0) positionedScope() else null,
                if (flags and 16777216 != 0) containerOwnerFont() else null)
            val oldStyle = if (positionedContainers) {
                val extension = byte().also { require(it and (if (readDisclosure != null) 15 else 7) == it) { "Unknown positioned Container extension" } }
                val position = if (extension and 1 != 0)
                    ContainerAbsolutePosition(containerMarginLength(), containerMarginLength()) else null
                val wrap = if (extension and 2 != 0) when (byte()) {
                    0 -> TextWrap.Normal
                    1 -> TextWrap.NoWrap
                    else -> error("Unknown Container text wrap")
                } else null
                val static = if (extension and 4 != 0) ContainerAbsoluteStaticPosition(
                    ContainerStaticDirection.entries.getOrNull(byte()) ?: error("Unknown static Container direction")) else null
                if (extension and 8 != 0) checkNotNull(readDisclosure).invoke(containerDisclosure())
                base.copy(absolutePosition = position, textWrap = wrap, absoluteStatic = static)
            } else base
            val style = extendedColumns?.let { (count, gap) ->
                val extension = byte().also { require(it in 1..3) { "Unknown column extension fields" } }
                val width = if (extension and 1 != 0) styleLength() else null
                val direction = if (extension and 2 != 0) BidiResolvedDirection.entries.getOrNull(byte())
                    ?: error("Unknown column direction") else null
                oldStyle.copy(columns = ContainerColumns(count.takeIf { it != 0 }, gap, width, direction))
                    .also { hasColumnLayout = true }
            } ?: oldStyle
            if (style.requiresPositionedContainers()) {
                require(positionedContainers) { "Positioned Container fields require Z" }
                hasPositionedContainers = true
            }
            return style
        }
        fun referenceLayouts(batches: List<ReferenceBatchPlacement>): List<ReferenceBatchPlacement> {
            var present = false
            val result = batches.map { batch ->
                if (!presence()) batch else {
                    present = true
                    require(remainingItems > 0) { "Reference layout exceeds presentation budget" }
                    remainingItems--
                    val wrapper = containerStyle(); val list = containerStyle()
                    val length = count(8)
                    require(length > 0 && length == batch.referenceIndices.size) { "Reference layout item census differs" }
                    val items = List(length) {
                        val box = containerStyle()
                        require(byte() == 0) { "Unsupported reference list marker" }
                        val foreground = figureColor()
                        require(byte() == 0) { "Unsupported backlink separator" }
                        val background = if (presence()) containerColor() else null
                        ReferenceItemLayout(box, ReferenceListMarker.DecimalOutside, foreground,
                            ReferenceBacklinkPrefix.SingleSpace, background)
                    }
                    batch.copy(layout = ReferenceBatchLayout(wrapper, list, items))
                }
            }
            require(present) { "Reference layout flag has no payload" }
            return result
        }
        private fun container(tableDepth: Int): Container = content {
            var disclosure: ContainerDisclosure? = null
            val style = containerStyle { disclosure = it }
            require(style.positioning !is ContainerPositioning.Absolute || positionedParent) {
                "Absolute text requires a direct positioned containing scope"
            }
            require(style.positionedScope == null || !positionedActive) { "Nested positioned scope is unsupported" }
            val previous = positionedParent
            val previousActive = positionedActive
            positionedParent = style.positionedScope != null
            positionedActive = previousActive || style.positionedScope != null
            try {
                Container(List(count(minimumBlockBytes)) { block(tableDepth) }, style, disclosure).also {
                    require(containerFonts || legacyContainerMarginsSupported(it)) { "Adjoining container margins require M" }
                }
            } finally { positionedParent = previous; positionedActive = previousActive }
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
            val allowed = if (containerFonts) 0xff else 0x07
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
                verticalAlign = vertical, lineHeight = if (flags and 8 != 0) cellLineHeight() else null,
                opacity = if (flags and 16 != 0) buffer.float else null)
        }
        private fun cellMetricBasis(): FontScaleBasis = when (byte()) {
            1 -> FontScaleBasis.NormalBody
            2 -> FontScaleBasis.CssPx
            else -> error("Unknown cell text metric origin")
        }
        private fun cellLineHeight(): CellLineHeight {
            val marker = byte()
            require(marker in 0..1 || cellOwnerFonts && marker == 2) { "Unknown cell strut marker" }
            val strut = if (marker == 0) null else {
                val scale = buffer.float
                val basis = cellMetricBasis()
                val owner = if (marker == 2) inlineFontSnapshot(requireOmittedSize = true).also {
                    require(it.fontScale == null && it.fontScaleBasis == FontScaleBasis.Context) {
                        "Cell owner font repeats its strut size"
                    }
                }.copy(fontScale = scale, fontScaleBasis = basis) else null
                CellTextStrut(scale, basis, owner).also { if (owner != null) hasCellOwnerFontFeature = true }
            }
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
            require(extension in 0..(if (tableMinimumWidths) 127 else if (tableCorners) 63 else if (containerFonts) 31 else 7) && flags in 0..(if (imageMaps) 255 else if (blockLayouts) 31 else 15) &&
                (flags != 0 || extension != 0)) { "Invalid table style flags" }
            val marginFlags = extension and 0x18
            val numericCornerDirection = tableCorners && extension and 0x20 != 0 && flags and 8 != 0 && marginFlags == 0x10
            require(marginFlags == 0 || marginFlags == 0x18 || numericCornerDirection) {
                "Unpaired table margins and containing direction"
            }
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
            val corners = if (extension and 0x20 != 0) {
                TableCornerRadii(styleLength(), styleLength(), styleLength(), styleLength()).also { hasTableCorners = true }
            } else null
            val minWidth = if (extension and 64 != 0) StyleWidth(
                StyleWidthUnit.entries.getOrNull(byte()) ?: error("Unknown table minimum width unit"), buffer.float)
                .also { hasTableMinimumWidth = true } else null
            return TableStyle(background, border, collapse, margins, floatSide, width, padding, clear, display, align,
                lineHeight, marginValues, containingDirection, corners, minWidth)
        }
        private fun tableBlockViewport(paired: Boolean, intrinsic: Boolean): TableBlockViewport {
            require(containerFonts && (!paired || tableScrollPairs)) { "Table paired viewport requires P" }
            val threshold = u32()
            val boxStyle = tableStyle() ?: error("Missing table viewport box style")
            val boxSizing = ContainerBoxSizing.entries.getOrNull(byte()) ?: error("Unknown table viewport box sizing")
            val maxWidth = StyleWidth(
                StyleWidthUnit.entries.getOrNull(byte()) ?: error("Unknown table viewport max-width unit"), buffer.float)
            val gridStyle = tableStyle() ?: error("Missing anonymous table grid style")
            val gridDirection = TableContainingDirection.entries.getOrNull(byte()) ?: error("Unknown anonymous table grid direction")
            val language = string()
            val intrinsicDirection = if (intrinsic)
                TableContainingDirection.entries.getOrNull(byte()) ?: error("Unknown intrinsic table containing direction") else null
            val hasFocus = paired || intrinsic || tableCorners && tableSeparateCornerViewportShape(
                threshold, boxStyle, maxWidth, gridStyle, language)
            val focus = if (hasFocus) TableScrollFocusPaint(
                TableScrollFocusMode.entries.getOrNull(byte()) ?: error("Unknown table scroll focus mode"),
                if (presence()) figureColor() else null) else null
            return TableBlockViewport(threshold, boxStyle, boxSizing, maxWidth, gridStyle, gridDirection, language, focus,
                intrinsicDirection)
        }
        private fun tableFloatViewport(hasNarrowClear: Boolean): TableFloatViewport {
            require(containerFonts) { "Table float viewport requires M" }
            require(!hasNarrowClear || tableFloatClears) { "Table float clear override requires P" }
            val threshold = u32()
            val containing = TableContainingDirection.entries.getOrNull(byte()) ?: error("Unknown table float containing direction")
            val grid = TableContainingDirection.entries.getOrNull(byte()) ?: error("Unknown table float grid direction")
            val language = string()
            val narrowClear = if (hasNarrowClear) {
                FigureClear.entries.getOrNull(byte()) ?: error("Unknown table float clear override")
            } else null
            if (narrowClear != null) hasTableFloatClearFeature = true
            return TableFloatViewport(threshold, containing, grid, language, narrowClear)
        }
        private fun table(depth: Int): Table? = positionedRoot {
            val tableFlags = byte()
            if (tableFlags == 0) return@positionedRoot null
            val hiddenRows = tableFlags and 0x20 != 0
            val baseFlags = tableFlags and 0x20.inv()
            require(!hiddenRows || containerFonts) { "Table row visibility requires M" }
            require(baseFlags == 1 || containerFonts && (baseFlags == 3 || baseFlags == 5) ||
                tableFloatClears && baseFlags == 13 || tableScrollPairs && baseFlags == 7 ||
                tableIntrinsicViewports && baseFlags == 19) { "Invalid table presence flags" }
            require(depth <= tableDepthLimit) { "Table nesting is too deep" }
            maximumTableDepth = maxOf(maximumTableDepth, depth)
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
            val paired = baseFlags == 7
            val intrinsic = baseFlags == 19
            val blockViewport = if (tableFlags and 2 != 0) tableBlockViewport(paired, intrinsic) else null
            if (paired) hasTableScrollFeature = true
            if (intrinsic) hasTableIntrinsicViewport = true
            val floatViewport = if (tableFlags and 4 != 0) tableFloatViewport(tableFlags and 8 != 0) else null
            val rowsHiddenMaxWidthPx = if (hiddenRows) {
                require(remainingItems > 0) { "Table row visibility exceeds the presentation budget" }
                remainingItems--
                u32()
            } else null
            require(containerFonts || style?.isInline != true || rows.all { row ->
                row.all { cell -> cell.spans.none { it.image != null } }
            }) { "Inline table images require M" }
            Table(caption, rows, geometry, style, rich, blockViewport, floatViewport, rowsHiddenMaxWidthPx).also { tableGrid(it) }
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
            val ruleStyle = if (ruleStyles && kind == "rule") {
                val marker = byte()
                require(marker == 0 || marker == 1 || ruleClears && marker == 2) { "Invalid rule style marker" }
                if (marker == 0) null else {
                    val height = styleLength(); val fill = containerColor(); val margins = styleEdges()
                    val clear = if (marker == 2)
                        FigureClear.entries.getOrNull(byte()) ?: error("Unknown rule clear") else null
                    if (clear != null) hasRuleClearFeature = true
                    RuleStyle(height, fill, margins, clear)
                }
            } else null
            val columnBreakInside = if (columnLayouts) when (byte()) {
                0 -> null
                1 -> ColumnBreakInside.Auto
                2 -> ColumnBreakInside.Avoid
                else -> error("Unknown column break policy")
            } else null
            if (columnBreakInside != null) hasColumnLayout = true
            return Block(kind, depth, spans, path, number, table, feature, level, anchor, fallback, textAlign,
                style, figure, flow, container, ruleStyle, columnBreakInside)
        }
    }
}
