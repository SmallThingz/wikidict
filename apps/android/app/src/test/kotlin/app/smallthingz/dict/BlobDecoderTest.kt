package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

class BlobDecoderTest {
    private var projectionVersion: Char = 'J'
    private fun producerEnvironment(name: String): String = System.getenv(name)?.takeIf { it.isNotEmpty() }
        ?: error("Required producer conformance input is absent: $name")
    private fun producerDigest(bytes: ByteArray): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun producerInput(name: String): File {
        val file = File(producerEnvironment(name)).canonicalFile
        require(file.isFile) { "Missing producer conformance file: $name" }
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        require(actual == producerEnvironment(name + "_SHA256")) { "Producer input identity differs: $name" }
        return file
    }
    private fun producerJson(value: Any?): String = when (value) {
        null -> "null"
        is String -> buildString {
            append('"')
            for (character in value) when (character) {
                '"' -> append("\\\""); '\\' -> append("\\\\")
                '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
                else -> if (character.code < 32) append("\\u%04x".format(character.code)) else append(character)
            }
            append('"')
        }
        is Boolean, is Int, is Long -> value.toString()
        // Preserve the exact decoded f32 numeric value in the JSON graph. The
        // shortest Float spelling would round when another decoder reads Double.
        is Float -> { require(value.isFinite()); value.toDouble().toString() }
        is Double -> { require(value.isFinite()); value.toString() }
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { (key, item) ->
            require(key is String); producerJson(key) + ":" + producerJson(item)
        }
        is Iterable<*> -> value.joinToString(",", "[", "]") { producerJson(it) }
        else -> error("Unsupported conformance projection value")
    }
    private fun producerSpan(span: Span): Map<String, Any?> = linkedMapOf<String, Any?>(
        "kind" to span.kind, "text" to span.text, "target" to span.target, "trail" to span.trail,
        "language" to span.language, "classes" to span.classes, "direction" to span.direction,
        "explanation" to span.explanation, "foreground" to span.foreground, "background" to span.background,
        "bold" to span.bold, "italic" to span.italic, "code" to span.code, "small" to span.small,
        "superscript" to span.superscript, "subscript" to span.subscript, "strike" to span.strike,
        "underline" to span.underline, "role" to span.role).also { fields ->
            if (projectionVersion >= 'H') fields["tooltip"] = span.tooltip
            span.targetFragment?.let { fields["target_fragment"] = it }
            span.fontScale?.let { fields["font_scale"] = it }
            if (span.fontScaleBasis == FontScaleBasis.NormalBody) fields["font_scale_basis"] = "normal_body"
            span.image?.let { image -> fields["image"] = linkedMapOf<String, Any?>("file" to image.file).also { values ->
                image.widthPx?.let { values["width_px"] = it }; image.heightPx?.let { values["height_px"] = it }
                image.alt?.let { values["alt"] = it }; image.tooltip?.let { values["tooltip"] = it }
                if (image.border) values["border"] = true
                image.map?.let { values["map"] = producerImageMap(it) }
                image.darkModeFilter?.let { values["dark_mode_filter"] = when (it) {
                    ImageDarkModeFilter.InvertHueRotate180 -> "invert_hue_rotate_180"
                } }
            } }
        }
    private fun producerMapAction(value: ImageMapAction): Map<String, Any?> = linkedMapOf(
        "kind" to if (value.kind == ImageMapActionKind.Internal) "internal" else "external",
        "target" to value.target, "target_fragment" to value.targetFragment, "label" to value.label)
    private fun producerImageMap(value: ImageMap): Map<String, Any?> = linkedMapOf(
        "regions" to value.regions.map { linkedMapOf("shape" to when (it.shape) {
            ImageMapShape.Rect -> "rectangle"; ImageMapShape.Circle -> "circle"; ImageMapShape.Polygon -> "polygon"
        }, "coordinates" to it.coordinates, "action" to producerMapAction(it.action)) },
        "default_action" to value.defaultAction?.let(::producerMapAction), "description" to when (value.description) {
            ImageMapDescription.None -> "none"; ImageMapDescription.TopRight -> "top_right"
            ImageMapDescription.BottomRight -> "bottom_right"; ImageMapDescription.BottomLeft -> "bottom_left"
            ImageMapDescription.TopLeft -> "top_left"
        })
    private fun producerFigureColor(value: FigureColor): Map<String, Any?> = when (value) {
        FigureColor.NativeTheme -> linkedMapOf("kind" to "native_theme")
        FigureColor.Transparent -> linkedMapOf("kind" to "transparent")
        is FigureColor.Rgb -> linkedMapOf("kind" to "rgb", "value" to value.value)
    }
    private fun producerFigureBorder(value: FigureBorder): Map<String, Any?> = when (value) {
        FigureBorder.None -> linkedMapOf("kind" to "none")
        is FigureBorder.Solid -> linkedMapOf("kind" to "solid", "width" to producerStyleLength(value.width),
            "color" to producerFigureColor(value.color))
    }
    private fun producerFigure(value: Figure): Map<String, Any?> = linkedMapOf<String, Any?>(
        "image_span" to producerSpan(value.imageSpan), "caption" to value.caption.map(::producerSpan),
        "format" to if (value.format == FigureFormat.Thumbnail) "thumbnail" else "framed",
        "sizing" to when (value.sizing) {
            FigureSizingPolicy.Intrinsic -> "intrinsic"
            FigureSizingPolicy.OriginalWidthWithHeightBound -> "original_width_with_height_bound"
            FigureSizingPolicy.RequestedFit -> "requested_fit"
            FigureSizingPolicy.RequestedFitCapOriginalWidth -> "requested_fit_cap_original_width"
        },
        "placement" to when (value.placement) { FigurePlacement.None -> "none"; FigurePlacement.Center -> "center"
            FigurePlacement.FloatLeft -> "float_left"; FigurePlacement.FloatRight -> "float_right" },
        "clear" to when (value.clear) { FigureClear.None -> "none"; FigureClear.Left -> "left"
            FigureClear.Right -> "right"; FigureClear.Both -> "both" },
        "margins" to producerStyleEdges(value.margins), "image_insets" to producerStyleEdges(value.imageInsets),
        "caption_padding" to producerStyleEdges(value.captionPadding), "caption_font_scale" to value.captionFontScale,
        "caption_line_height" to producerStyleLength(value.captionLineHeight),
        "frame_background" to producerFigureColor(value.frameBackground), "frame_border" to producerFigureBorder(value.frameBorder),
        "image_background" to producerFigureColor(value.imageBackground), "image_border" to producerFigureBorder(value.imageBorder),
        "caption_foreground" to producerFigureColor(value.captionForeground), "caption_background" to producerFigureColor(value.captionBackground),
    ).also { fields ->
        value.frameMinWidth?.let { fields["frame_min_width"] = producerStyleLength(it) }
        value.captionBlocks?.let { fields["caption_blocks"] = it.map(::producerBlock) }
        value.captionTextAlign?.let { fields["caption_text_align"] = when (it) {
            CellTextAlign.Left -> "left"; CellTextAlign.Center -> "center"; CellTextAlign.Right -> "right"
        } }
    }
    private fun producerFlow(value: FlowPart): Map<String, Any?> = linkedMapOf(
        "kind" to when (value) { is FlowPart.Inline -> "inline"; is FlowPart.ImageFigure -> "figure"; is FlowPart.Scope -> "scope" },
        "spans" to (value as? FlowPart.Inline)?.spans.orEmpty().map(::producerSpan),
        "figure" to (value as? FlowPart.ImageFigure)?.figure?.let(::producerFigure),
        "scope" to (value as? FlowPart.Scope)?.scope?.let { scope -> linkedMapOf(
            "mode" to if (scope.mode == BidiMode.Isolate) "isolate" else "isolate_override",
            "authored_direction" to scope.authoredDirection?.let { when (it) {
                BidiDirectionInput.Ltr -> "ltr"; BidiDirectionInput.Rtl -> "rtl"; BidiDirectionInput.Auto -> "auto" } },
            "resolved_direction" to if (scope.resolvedDirection == BidiResolvedDirection.Ltr) "ltr" else "rtl",
            "language" to scope.language, "parts" to scope.parts.map(::producerFlow)) })
    private fun producerStyleLength(value: StyleLength): Map<String, Any?> = linkedMapOf(
        "unit" to if (value.unit == StyleLengthUnit.Px) "px" else "em", "value" to value.value)
    private fun producerStyleEdges(value: StyleEdges): Map<String, Any?> = linkedMapOf(
        "top" to producerStyleLength(value.top), "right" to producerStyleLength(value.right),
        "bottom" to producerStyleLength(value.bottom), "left" to producerStyleLength(value.left))
    private fun producerStyleBorder(value: StyleBorder): Map<String, Any?> = when (value) {
        StyleBorder.None -> linkedMapOf("none" to emptyMap<String, Any?>())
        is StyleBorder.Solid -> linkedMapOf("solid" to linkedMapOf("width" to producerStyleLength(value.width), "color" to value.color))
    }
    private fun producerCellStyle(value: CellStyle): Map<String, Any?> = linkedMapOf<String, Any?>().also { fields ->
        value.border?.let { fields["border"] = producerStyleBorder(it) }
        value.padding?.let { fields["padding"] = producerStyleEdges(it) }
        value.textAlign?.let { fields["text_align"] = when (it) { CellTextAlign.Left -> "left"; CellTextAlign.Center -> "center"; CellTextAlign.Right -> "right" } }
    }
    private fun producerTableStyle(value: TableStyle): Map<String, Any?> = linkedMapOf<String, Any?>().also { fields ->
        value.background?.let { fields["background"] = it }
        value.border?.let { fields["border"] = producerStyleBorder(it) }
        value.collapse?.let { fields["collapse"] = if (it == TableCollapse.Separate) "separate" else "collapse" }
        value.margins?.let { fields["margins"] = producerStyleEdges(it) }
        value.floatSide?.let { fields["float_side"] = if (it == TableFloatSide.Left) "left" else "right" }
        value.width?.let { fields["width"] = linkedMapOf("unit" to when (it.unit) {
            StyleWidthUnit.Px -> "px"; StyleWidthUnit.Em -> "em"; StyleWidthUnit.Percent -> "percent"
        }, "value" to it.value.toDouble()) }
        value.padding?.let { fields["padding"] = producerStyleEdges(it) }
        value.clear?.let { fields["clear"] = when (it) {
            FigureClear.None -> "none"; FigureClear.Left -> "left"; FigureClear.Right -> "right"; FigureClear.Both -> "both"
        } }
        value.display?.let { fields["display"] = when (it) {
            TableDisplay.Table -> "table"; TableDisplay.InlineBlock -> "inline_block"; TableDisplay.InlineTable -> "inline_table"
        } }
        value.verticalAlign?.let { fields["vertical_align"] = if (it == InlineBoxVerticalAlign.Middle) "middle" else "baseline" }
        value.lineHeight?.let { fields["line_height"] = linkedMapOf("value" to it.value,
            "font_scale_basis" to if (it.fontScaleBasis == FontScaleBasis.NormalBody) "normal_body" else "context") }
    }
    private fun producerTable(table: Table): Map<String, Any?> = linkedMapOf<String, Any?>(
        "caption" to table.caption.map(::producerSpan),
        "geometry" to table.geometry?.let { geometry -> linkedMapOf(
            "border" to geometry.border, "cell_spacing" to geometry.cellSpacing, "cell_padding" to geometry.cellPadding,
            "width" to geometry.width?.let { linkedMapOf("unit" to if (it.unit == TableWidthUnit.Px) "px" else "percent", "value" to it.value) }) },
        "rows" to table.rows.map { row -> linkedMapOf("cells" to row.map { cell -> linkedMapOf<String, Any?>(
            "spans" to cell.spans.map(::producerSpan), "header" to cell.header, "colspan" to cell.colspan,
            "rowspan" to cell.rowspan, "background" to cell.background, "nested_table" to cell.nestedTable?.let(::producerTable))
                .also { fields ->
                    cell.blocks?.let { blocks -> fields["blocks"] = blocks.map(::producerBlock) }
                    cell.style?.let { fields["style"] = producerCellStyle(it) }
                } }) }).also { fields ->
                    table.style?.let { fields["style"] = producerTableStyle(it) }
                    table.captionBlocks?.let { fields["caption_blocks"] = it.map(::producerBlock) }
                }
    private fun producerBlock(block: Block): Map<String, Any?> = linkedMapOf(
        "kind" to block.kind, "depth" to block.depth, "spans" to block.spans.map(::producerSpan),
        "feature" to block.feature?.let { linkedMapOf("kind" to it.kind, "language" to it.language,
            "data" to it.data, "tail_kind" to it.tailKind, "tail" to it.tail) },
        "list_path" to block.listPath, "number" to block.number, "level" to block.level,
        "anchor" to block.anchor, "anchor_fallback" to block.anchorFallback, "table" to block.table?.let(::producerTable)).also { fields ->
        block.textAlign?.let { fields["text_align"] = when (it) { CellTextAlign.Left -> "left"; CellTextAlign.Center -> "center"; CellTextAlign.Right -> "right" } }
        block.figure?.let { fields["figure"] = producerFigure(it) }
        block.flow?.let { fields["flow"] = it.map(::producerFlow) }
        block.style?.let { style -> fields["style"] = linkedMapOf<String, Any?>().also { values ->
            style.margins?.let { values["margins"] = producerStyleEdges(it) }
            style.padding?.let { values["padding"] = producerStyleEdges(it) }
        } }
    }
    private fun producerEntry(entry: Entry): Map<String, Any?> = linkedMapOf(
        "title" to entry.title, "kind" to entry.kind, "language" to entry.language, "language_code" to entry.languageCode,
        "display_title" to entry.displayTitle.map(::producerSpan), "preamble_spans" to entry.preamble.map(::producerSpan),
        "sections" to entry.sections.map { linkedMapOf("level" to it.level, "title" to it.title,
            "anchor" to it.anchor, "anchor_fallback" to it.anchorFallback, "blocks" to it.blocks.map(::producerBlock)) },
        "references" to entry.references.map { linkedMapOf<String, Any?>("number" to it.number, "group_number" to it.groupNumber,
            "group" to it.group, "spans" to it.spans.map(::producerSpan)).also { fields ->
                it.blocks?.let { blocks -> fields["blocks"] = blocks.map(::producerBlock) }
                if (it.kind == ReferenceKind.Fragment) fields["kind"] = "fragment"
            } },
        "media" to entry.media.map { linkedMapOf("file" to it.file, "kind" to it.kind, "caption" to it.caption) })

    @Test fun producerProjectionOmitsAbsentBlockStyleAndPreservesZeroEdgesAtRecursiveSinks() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, StyleLength(StyleLengthUnit.Em, 1.6f))
        val plain = Block("paragraph", 0, listOf(Span("link", "word", "title#literal", targetFragment = "", tooltip = null)))
        assertFalse(producerBlock(plain).containsKey("style"))
        val styled = plain.copy(style = BlockStyle(padding = edges))
        assertEquals(mapOf("padding" to producerStyleEdges(edges)), producerBlock(styled)["style"])
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(styled)))))
        val entry = Entry("word", emptyList(), "language", "English", "en",
            listOf(Section(2, "", listOf(plain, Block("table", 0, emptyList(), table = table)))),
            listOf(Reference(1, 1, "", emptyList(), blocks = listOf(styled))))
        val json = producerJson(producerEntry(entry))
        assertEquals(2, Regex("\\\"style\\\":").findAll(json).count())
        assertEquals(2, Regex("\\\"padding\\\":").findAll(json).count())
        assertTrue(json.contains("\"target_fragment\":\"\""))
        assertTrue(json.contains("\"tooltip\":null"))
        assertFalse(json.contains("\"margins\""))
    }

    @Test fun jProjectionRetainsScopeOwnershipTaggedPaintAndExplicitEmptyCaptionAtEverySink() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val action = ImageMapAction(ImageMapActionKind.Internal, "title#literal", "", "")
        val map = ImageMap(ImageMapDescription.None,
            listOf(ImageMapRegion(ImageMapShape.Circle, listOf(1.25, -2.5, 3.0), action)))
        val image = Span("link", "", "source", image = InlineImage("Image.svg", map = map), tooltip = "")
        val figure = Figure(image, FigureFormat.Framed, FigurePlacement.Center, FigureClear.Both,
            edges, edges, edges, .884f, StyleLength(StyleLengthUnit.Em, 1.2376f),
            FigureColor.NativeTheme, FigureBorder.None, FigureColor.Transparent,
            FigureBorder.Solid(zero, FigureColor.Rgb("#010203")), FigureColor.NativeTheme,
            FigureColor.Transparent, captionBlocks = emptyList(), sizing = FigureSizingPolicy.Intrinsic)
        val scoped = FlowPart.Scope(BidiScope(BidiMode.Isolate, BidiDirectionInput.Auto,
            BidiResolvedDirection.Ltr, "", listOf(FlowPart.ImageFigure(figure))))
        val flow = producerFlow(scoped)
        assertEquals(setOf("kind", "spans", "figure", "scope"), flow.keys)
        assertEquals("scope", flow["kind"]); assertEquals(emptyList<Any>(), flow["spans"]); assertNull(flow["figure"])
        val scope = flow["scope"] as Map<*, *>
        assertEquals("auto", scope["authored_direction"]); assertEquals("ltr", scope["resolved_direction"])
        assertEquals("", scope["language"])
        val projected = producerFigure(figure)
        assertEquals("intrinsic", projected["sizing"])
        val sizingNames = listOf("intrinsic", "original_width_with_height_bound", "requested_fit", "requested_fit_cap_original_width")
        for (policy in FigureSizingPolicy.entries) {
            val sized = figure.copy(sizing = policy,
                format = if (policy == FigureSizingPolicy.Intrinsic || policy == FigureSizingPolicy.OriginalWidthWithHeightBound)
                    FigureFormat.Framed else FigureFormat.Thumbnail,
                imageSpan = figure.imageSpan.copy(image = figure.imageSpan.image!!.copy(widthPx = 1200, heightPx = 600)))
            assertEquals(sizingNames[policy.ordinal], producerFigure(sized)["sizing"])
            assertEquals(1200L, sized.imageSpan.image!!.widthPx)
            assertEquals(600L, sized.imageSpan.image!!.heightPx)
        }
        assertEquals(emptyList<Any>(), projected["caption_blocks"])
        assertFalse(projected.containsKey("caption_text_align"))
        assertFalse(producerFigure(figure.copy(captionBlocks = null)).containsKey("caption_blocks"))
        assertEquals(mapOf("kind" to "none"), projected["frame_border"])
        assertEquals(mapOf("kind" to "solid", "width" to mapOf("unit" to "px", "value" to 0f),
            "color" to mapOf("kind" to "rgb", "value" to "#010203")), projected["image_border"])
        val block = Block("paragraph", 0, emptyList(), flow = listOf(scoped))
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(block)))),
            captionBlocks = listOf(block))
        val entry = Entry("J", emptyList(), "language", "English", "en",
            listOf(Section(2, "Section", listOf(Block("table", 0, emptyList(), table = table)))),
            listOf(Reference(1, 1, "", emptyList(), blocks = listOf(block))), media = listOf(Media("Image.svg", "image", "")))
        val json = producerJson(producerEntry(entry))
        assertEquals(3, Regex("\\\"image_span\\\":").findAll(json).count())
        assertEquals(3, Regex("\\\"caption_blocks\\\":\\[\\]").findAll(json).count())
        assertEquals(3, Regex("\\\"sizing\\\":\\\"intrinsic\\\"").findAll(json).count())
        assertTrue(json.contains("\"coordinates\":[1.25,-2.5,3.0]"))
        assertTrue(json.contains("\"target_fragment\":\"\""))
        assertTrue(json.contains("\"default_action\":null"))
        projectionVersion = 'G'
        assertFalse(producerSpan(Span("text", "plain")).containsKey("tooltip"))
        projectionVersion = 'J'
        assertTrue(producerSpan(Span("text", "plain")).containsKey("tooltip"))
        assertNull(producerSpan(Span("text", "plain"))["tooltip"])
    }

    private fun requiredProducerVersion(environment: Map<String, String>): Char? {
        val configured = environment.filterKeys { it.startsWith("WIKBLB_DPR") }
        if (configured.isEmpty()) return null
        val versions = configured.keys.map { name ->
            val match = Regex("WIKBLB_DPR([0-9A-Z])_[A-Z0-9_]+").matchEntire(name)
                ?: error("Malformed required producer input name: $name")
            match.groupValues[1].single().also { require(it in "789BCDEFGJK") { "Unsupported required producer version: $it" } }
        }.toSet()
        require(versions.size == 1) { "Select exactly one required producer case" }
        val version = versions.single()
        require(configured["WIKBLB_DPR${version}_REQUIRED"] == "1") {
            "Configured producer inputs require an explicit REQUIRED=1; never use the bundled fixture as fallback"
        }
        return version
    }

    private fun requiredJProducerHeader(title: String, kind: String, language: String?, code: String) {
        // These are the selected retained MG/UZ/SR cases. The translated heading is
        // authenticated by the actual header and complete Reader graph, not guessed here.
        val expectedCode = when (title) {
            "トペ" -> "ain"
            "ipak" -> "uz"
            "Србија" -> "sr"
            else -> error("Unselected required J producer title: $title")
        }
        require(kind == "language" && code == expectedCode && !language.isNullOrEmpty()) {
            "Required J producer owner differs from the selected source case"
        }
    }

    private fun requiredKProducerHeader(title: String, kind: String, language: String?, code: String) {
        val expected = when (title) {
            "drinking straw", "stool" -> "en" to "อังกฤษ"
            "Ilirice" -> "ang" to "Old English"
            else -> error("Unselected required K producer title: $title")
        }
        require(kind == "language" && code == expected.first && language == expected.second) {
            "Required K producer owner differs from the selected source case"
        }
    }

    @Test fun kProjectionRetainsTableFlowComputedBasisAndImageThemeWithoutInventingAbsentFields() {
        val plain = TableStyle(collapse = TableCollapse.Collapse)
        assertEquals(mapOf("collapse" to "collapse"), producerTableStyle(plain))
        val styled = plain.copy(display = TableDisplay.InlineBlock, verticalAlign = InlineBoxVerticalAlign.Middle,
            lineHeight = ComputedLineHeight(1f))
        assertEquals(mapOf("collapse" to "collapse", "display" to "inline_block", "vertical_align" to "middle",
            "line_height" to mapOf("value" to 1f, "font_scale_basis" to "context")), producerTableStyle(styled))
        assertEquals(mapOf("value" to .8f, "font_scale_basis" to "normal_body"),
            producerTableStyle(styled.copy(lineHeight = ComputedLineHeight(.8f, FontScaleBasis.NormalBody)))["line_height"])
        assertEquals("table", producerTableStyle(plain.copy(display = TableDisplay.Table))["display"])
        assertEquals("inline_table", producerTableStyle(plain.copy(display = TableDisplay.InlineTable))["display"])
        assertEquals("baseline", producerTableStyle(plain.copy(verticalAlign = InlineBoxVerticalAlign.Baseline))["vertical_align"])
        val image = InlineImage("Map.png")
        fun projected(value: InlineImage) = producerSpan(Span("text", "", image = value))["image"] as Map<*, *>
        assertEquals(mapOf("file" to "Map.png"), projected(image))
        assertEquals(mapOf("file" to "Map.png", "dark_mode_filter" to "invert_hue_rotate_180"),
            projected(image.copy(darkModeFilter = ImageDarkModeFilter.InvertHueRotate180)))
    }

    @Test fun requiredKProducerHeaderBindsExactRetainedTitlesAndOwners() {
        requiredKProducerHeader("drinking straw", "language", "อังกฤษ", "en")
        requiredKProducerHeader("stool", "language", "อังกฤษ", "en")
        requiredKProducerHeader("Ilirice", "language", "Old English", "ang")
        for ((title, language, code) in listOf(Triple("stool", "English", "en"), Triple("stool", "อังกฤษ", "th"),
            Triple("Ilirice", "English", "en"), Triple("ilirice", "Old English", "ang")))
            assertThrows(Exception::class.java) { requiredKProducerHeader(title, "language", language, code) }
        assertThrows(Exception::class.java) { requiredKProducerHeader("stool", "supplemental", "อังกฤษ", "en") }
        assertThrows(Exception::class.java) { requiredKProducerHeader("Ilirice", "language", null, "ang") }
    }

    @Test fun requiredProducerDispatchNeverFallsBackForUnknownOrIncompleteConfiguredInputs() {
        assertNull(requiredProducerVersion(emptyMap()))
        assertNull(requiredProducerVersion(mapOf("PATH" to "/unused")))
        for (version in "789BCDEFGJK") {
            assertEquals(version, requiredProducerVersion(mapOf("WIKBLB_DPR${version}_REQUIRED" to "1")))
        }
        for (environment in listOf(
            mapOf("WIKBLB_DPRJ_REQUIRED" to ""),
            mapOf("WIKBLB_DPRJ_REQUIRED" to "0"),
            mapOf("WIKBLB_DPRJ_TITLE" to "トペ"),
            mapOf("WIKBLB_DPRK_TITLE" to "stool"),
            mapOf("WIKBLB_DPRK_REQUIRED" to "1", "WIKBLB_DPRJ_BLOB" to "stale"),
            mapOf("WIKBLB_DPRJ_REQUIRED" to "1", "WIKBLB_DPRG_REQUIRED" to "1"),
            mapOf("WIKBLB_DPRJ_REQUIRED" to "1", "WIKBLB_DPRG_BLOB" to "stale"),
            mapOf("WIKBLB_DPRH_REQUIRED" to "1"),
            mapOf("WIKBLB_DPRI_REQUIRED" to "1"),
            mapOf("WIKBLB_DPRZ_REQUIRED" to "1"),
            mapOf("WIKBLB_DPRJJ_REQUIRED" to "1"),
        )) assertThrows(Exception::class.java) { requiredProducerVersion(environment) }
    }

    @Test fun requiredJProducerHeaderBindsSelectedTitleAndOwnerWithoutGuessingHeading() {
        requiredJProducerHeader("トペ", "language", "authenticated MG heading", "ain")
        requiredJProducerHeader("ipak", "language", "authenticated UZ heading", "uz")
        requiredJProducerHeader("Србија", "language", "authenticated SR heading", "sr")
        assertThrows(Exception::class.java) { requiredJProducerHeader("Србија", "language", "Unclassified", "") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("Србија", "language", "heading", "uz") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("Србија", "language", null, "sr") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("Srbija", "language", "heading", "sr") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("tope", "language", "heading", "ain") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("Ispanija", "language", "heading", "ain") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("トペ", "supplemental", "heading", "ain") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("トペ", "language", "heading", "mg") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("ipak", "language", "heading", "ain") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("トペ", "language", null, "ain") }
        assertThrows(Exception::class.java) { requiredJProducerHeader("ipak", "language", "", "uz") }
    }

    /** Configured producer case is a separate required run of the existing conformance target. */
    private fun requiredProducerConformance(version: Char) {
        require(version in "789BCDEFGJK")
        projectionVersion = version
        val prefix = "WIKBLB_DPR$version"
        fun name(suffix: String) = "${prefix}_$suffix"
        val fixtureTitle = when (version) {
            '7' -> "geacen"
            '8' -> "cell-heading-regression"
            '9' -> "DPR9 reference fragments"
            'B' -> "DPRB font scale basis"
            'D' -> "image-border-contract"
            'E' -> "dwa"
            'F' -> "ISBN"
            'G' -> "Ispanija"
            'J', 'K' -> null
            else -> "נספח:שיבושי הגייה/תבנית"
        }
        require(producerEnvironment(name("REQUIRED")) == "1")
        val blob = producerInput(name("BLOB"))
        val headerFile = producerInput(name("HEADER"))
        val payloadFile = producerInput(name("PAYLOAD"))
        val titleFile = producerInput(name("TITLE"))
        producerInput(name("CORE"))
        producerInput(name("SOURCE_FACTS"))
        producerInput(name("CASE"))
        val wantedTitle = titleFile.readBytes().decodeToString(throwOnInvalidSequence = true)
        if (version == 'J') require(wantedTitle == "トペ" || wantedTitle == "ipak" || wantedTitle == "Србија")
        else if (version == 'K') require(wantedTitle == "drinking straw" || wantedTitle == "stool" || wantedTitle == "Ilirice")
        else require(wantedTitle == fixtureTitle || version == 'C' && wantedTitle == "skakavica" ||
            version == 'D' && wantedTitle == "alarmować")
        var selected: Entry? = null
        var selectedOffset = -1L
        var selectedLength = -1
        var actualHeader: Map<String, Any?>? = null
        RandomAccessFile(blob, "r").use { input ->
            fun nul(): String {
                val bytes = java.io.ByteArrayOutputStream()
                while (true) { val b = input.read(); require(b >= 0 && bytes.size() < 65536); if (b == 0) break; bytes.write(b) }
                return bytes.toByteArray().decodeToString(throwOnInvalidSequence = true)
            }
            fun size(): Int {
                var value = 0L; var shift = 0
                while (true) {
                    val b = input.read(); require(b >= 0 && shift < 35)
                    value = value or ((b and 127).toLong() shl shift)
                    if (b and 128 == 0) { require(shift == 0 || b != 0); break }; shift += 7
                }
                require(value in 4..128L * 1024 * 1024 && value <= input.length() - input.filePointer)
                return value.toInt()
            }
            val magic = ByteArray(8); input.readFully(magic); require(magic.decodeToString() == "WIKBLB08")
            val kind = blobKind(input.read()); require(kind != "alias")
            val code = if (kind == "language") nul() else ""
            val language = if (kind == "language") nul() else null
            if (version == 'J') requiredJProducerHeader(wantedTitle, kind, language, code)
            if (version == 'K') requiredKProducerHeader(wantedTitle, kind, language, code)
            val headerEnd = input.filePointer
            require(headerEnd <= 131080)
            input.seek(0); val headerBytes = ByteArray(headerEnd.toInt()); input.readFully(headerBytes)
            require(headerBytes.contentEquals(headerFile.readBytes()))
            actualHeader = linkedMapOf("kind" to kind, "language" to language, "language_code" to code)
            var recordCount = 0
            val recordTitles = mutableListOf<String>()
            while (input.filePointer < input.length()) {
                val title = nul(); require(title.isNotEmpty())
                val length = size(); val offset = input.filePointer; recordCount++; recordTitles.add(title)
                if (title == wantedTitle) {
                    require(selected == null) { "Producer fixture title is duplicated" }
                    val payload = ByteArray(length); input.readFully(payload)
                    require(payload.copyOfRange(0, 4).decodeToString() == "DPR$version")
                    require(payload.contentEquals(payloadFile.readBytes()))
                    selected = BlobDecoder.decode(payload, title, kind, language, code)
                    selectedOffset = offset; selectedLength = length
                } else input.seek(offset + length)
            }
            if (version == 'F') {
                require(recordCount == 3 && recordTitles.toSet() == setOf(
                    "ISBN", "page", "Special:Booksources/9781234567890#tail")) {
                    "Controlled Writer fixture must contain the source and two exact destinations"
                }
                require(selected != null)
            } else {
                require(recordCount == 1 && selected != null) { "Writer fixture must contain its one selected record" }
            }
        }
        if (version == '9') {
            // This required Writer case exercises fragment-first footer order; the
            // general decoder separately accepts otherwise valid all-note DPR9.
            val items = checkNotNull(selected).references
            require(items.map { it.kind } == listOf(ReferenceKind.Fragment, ReferenceKind.Note, ReferenceKind.Note))
            require(items.map { it.number } == listOf(2L, 1L, 3L))
            require(items.map { it.groupNumber } == listOf(null, 1L, 2L))
        }
        if (version == 'B') {
            val entry = checkNotNull(selected)
            val spans = buildList {
                addAll(entry.displayTitle); addAll(entry.preamble)
                entry.sections.forEach { section -> section.blocks.forEach { block ->
                    addAll(block.spans)
                    block.table?.visitSpanRuns { values, _ -> addAll(values) }
                } }
                entry.references.forEach { reference -> reference.visitSpanRuns { spans, _ -> addAll(spans) } }
            }
            val headingSpans = entry.sections.flatMap { section ->
                section.blocks.filter { it.kind == "heading" }.flatMap { it.spans }
            }
            require(entry.displayTitle.any { it.fontScale == 1.25f && it.fontScaleBasis == FontScaleBasis.Context })
            require(headingSpans.any { it.fontScale == 1f && it.fontScaleBasis == FontScaleBasis.NormalBody })
            require(headingSpans.any { it.fontScale == 1.25f && it.fontScaleBasis == FontScaleBasis.Context })
            require(spans.any { it.fontScale == 0f })
        }
        if (version == 'C') {
            val entry = checkNotNull(selected)
            if (wantedTitle == "skakavica") {
                require(entry.languageCode == "hr")
                val reference = entry.references.single()
                require(reference.spans.isEmpty() && reference.blocks != null)
                val table = checkNotNull(reference.blocks).mapNotNull { it.table }.single()
                require(table.rows.size == 2 && table.rows.all { it.size == 5 } && table.style != null)
            } else {
                val images = entry.inlineImages
                require(images.size == 3)
                require(images.map { it.file }.toSet() == setOf("Vraagteken-2.svg", "X mark.svg", "Yes check.svg"))
                require(images.all { it.widthPx == 15L && it.heightPx == null })
            }
        }
        if (version == 'D') {
            val entry = checkNotNull(selected)
            require(entry.inlineImages.any { it.border } && entry.inlineImages.any { !it.border })
            if (wantedTitle == "alarmować") {
                require(entry.languageCode == "pl")
                val flag = entry.inlineImages.single { it.file == "Flag of Poland.svg" }
                val book = entry.inlineImages.single { it.file == "Open book 01.svg" }
                require(flag.border && flag.widthPx == 40L && flag.heightPx == null)
                require(!book.border && book.widthPx == 30L && book.heightPx == null)
            }
        }
        if (version == 'E') {
            val entry = checkNotNull(selected)
            require(entry.title == "dwa" && entry.kind == "language" && entry.language == "poloniera" && entry.languageCode == "pl")
            // The complete modeled graph below is compared with actual Writer/Reader outputs
            // by the existing producer comparator. Do not substitute a synthetic E byte fixture.
        }
        if (version == 'F') {
            val entry = checkNotNull(selected)
            require(entry.kind == "language" && entry.language == "English" && entry.languageCode == "en")
            val actions = buildList<Span> {
                addAll(entry.displayTitle); addAll(entry.preamble)
                entry.sections.forEach { section -> section.blocks.forEach { it.visitSpanRuns { spans, _ -> addAll(spans) } } }
                entry.references.forEach { it.visitSpanRuns { spans, _ -> addAll(spans) } }
            }.filter { it.targetFragment != null }
            require(actions.any { it.kind == "link" && it.target == "Special:Booksources/9781234567890#tail" && it.targetFragment == "" })
        }
        if (version == 'G') {
            val entry = checkNotNull(selected)
            // This selected genuine producer case must require G's larger catalog.
            // Exact names, widths, actions and body order come from Writer/Reader parity,
            // not the separate source-derived 280-item synthetic fixture.
            require(entry.media.size > 256 && entry.inlineImages.isNotEmpty()) {
                "Required G producer case must contain typed images and a catalog beyond F capacity"
            }
        }
        val output = File(producerEnvironment(name("ACTUAL"))).canonicalFile
        require(output.parentFile.isDirectory && output.createNewFile()) { "Use a fresh owned output path" }
        output.writeText(producerJson(linkedMapOf(
            "schema" to "wikidict.android.dpr${version.lowercaseChar()}-producer-actual.v1",
            "case_sha256" to producerEnvironment(name("CASE_SHA256")),
            "blob_sha256" to producerEnvironment(name("BLOB_SHA256")),
            "header_sha256" to producerDigest(headerFile.readBytes()),
            "payload_sha256" to producerDigest(payloadFile.readBytes()),
            "core_sha256" to producerEnvironment(name("CORE_SHA256")),
            "source_facts_sha256" to producerEnvironment(name("SOURCE_FACTS_SHA256")),
            "record_offset" to selectedOffset, "record_length" to selectedLength,
            "header" to actualHeader, "entry" to producerEntry(checkNotNull(selected)))), Charsets.UTF_8)
    }

    private fun records(): List<Pair<String, ByteArray>> = RandomAccessFile(File("src/debug/assets/English.wikblb"), "r").use { f ->
        fun nul(): String { val b = java.io.ByteArrayOutputStream(); while(true) { val v=f.read(); require(v>=0); if(v==0)break; b.write(v) }; return b.toByteArray().decodeToString() }
        val magic=ByteArray(8);f.readFully(magic);assertEquals("WIKBLB08",magic.decodeToString());assertEquals(1,f.read());assertEquals("en",nul());assertEquals("English",nul())
        buildList { while(f.filePointer<f.length()) { val title=nul();var size=0;var shift=0;while(true){val v=f.read();size=size or ((v and 127) shl shift);if(v and 128==0)break;shift+=7};val b=ByteArray(size);f.readFully(b);add(title to b) } }
    }
    @Test fun supplementalKindIsValidatedAndFullTitlesStayDistinct() {
        assertEquals(listOf("language", "thesaurus", "citations", "reconstruction", "rhymes", "sign_gloss", "supplemental", "alias"), (1..8).map(::blobKind))
        for (tag in listOf(-1, 0, 9, 255)) assertThrows(Exception::class.java) { blobKind(tag) }
        RandomAccessFile(File("src/androidTest/assets/supplemental.wikblb"), "r").use { f ->
            val magic = ByteArray(8); f.readFully(magic); assertEquals("WIKBLB08", magic.decodeToString())
            assertEquals("supplemental", blobKind(f.read()))
            val titles = mutableListOf<String>()
            while (f.filePointer < f.length()) {
                val text = java.io.ByteArrayOutputStream()
                while (true) { val v=f.read(); require(v>=0); if(v==0)break; text.write(v) }
                val title=text.toByteArray().decodeToString(); titles.add(title)
                var size=0; var shift=0
                while(true) { val v=f.read(); require(v>=0 && shift<28); size=size or ((v and 127) shl shift); if(v and 128==0)break; shift+=7 }
                val payload=ByteArray(size); f.readFully(payload)
                val entry=BlobDecoder.decode(payload,title,"supplemental",null,"")
                assertEquals(title,entry.title)
                assertEquals(title,entry.sections.single().blocks.single().spans.single().text)
            }
            assertEquals(listOf("Annexe:école", "Appendix:école"),titles)
        }
    }

    @Test fun producerLinkProjectionOmitsAbsentAndPreservesEmptyOrExplicitFragment() {
        val legacy = Span("link", "label", "Title#literal")
        assertFalse(producerSpan(legacy).containsKey("target_fragment"))
        assertEquals("", producerSpan(legacy.copy(targetFragment = ""))["target_fragment"])
        assertEquals("part#literal", producerSpan(legacy.copy(targetFragment = "part#literal"))["target_fragment"])
        assertTrue(producerJson(producerSpan(legacy.copy(targetFragment = ""))).contains("\"target_fragment\":\"\""))
    }

    @Test fun producerImageProjectionOmitsFalseBorderAndRetainsTrueWithoutLosingNullableFields() {
        val plain = InlineImage("Controlled.svg", 40, alt = "", tooltip = "Detail")
        val span = Span("link", "", "File:Controlled.svg", image = plain)
        val expected = linkedMapOf<String, Any?>("file" to "Controlled.svg", "width_px" to 40L,
            "alt" to "", "tooltip" to "Detail")
        assertEquals(expected, producerSpan(span)["image"])
        assertEquals(expected + ("border" to true), producerSpan(span.copy(image = plain.copy(border = true)))["image"])
        assertFalse(producerJson(producerSpan(span)).contains("\"border\""))
        assertTrue(producerJson(producerSpan(span.copy(image = plain.copy(border = true)))).contains("\"border\":true"))
    }

    @Test fun producerFigureMinimumProjectionOmitsNullButRetainsZeroAndExactF32() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val base = Figure(Span("text", "", image = InlineImage("Controlled.png", widthPx = 20)),
            FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, edges, edges, edges,
            1f, StyleLength(StyleLengthUnit.Em, 1f), FigureColor.NativeTheme, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("text", "Full caption")), sizing = FigureSizingPolicy.RequestedFit)
        val absent = producerFigure(base)
        assertFalse(absent.containsKey("frame_min_width"))
        assertFalse(producerJson(absent).contains("frame_min_width"))
        for (value in listOf(0f, 100f, 100.1f)) {
            val present = producerFigure(base.copy(frameMinWidth = StyleLength(StyleLengthUnit.Px, value)))
            assertEquals(absent, present.filterKeys { it != "frame_min_width" })
            assertEquals("{\"unit\":\"px\",\"value\":${value.toDouble()}}", producerJson(present["frame_min_width"]))
        }
    }

    @Test fun everyRealCorpusRecordDecodesDirectly() {
        val requiredVersion = requiredProducerVersion(System.getenv())
        if (requiredVersion != null) {
            requiredProducerConformance(requiredVersion)
            return
        }
        val records=records();assertTrue(records.size>20)
        records.forEach { (title,payload)-> val e=BlobDecoder.decode(payload,title,"language","English","en");assertEquals(title,e.title);assertTrue(e.sections.isNotEmpty()) }
        val cat=records.first{it.first=="cat"}.let{BlobDecoder.decode(it.second,it.first,"language","English","en")}
        assertTrue(cat.sections.any{it.title.startsWith("Etymology")});assertTrue(cat.media.any{it.kind=="audio"});assertTrue(cat.media.any{it.kind=="image"})
        // This historical fixture has a real parent definition, not a media fallback.
        assertEquals("Terms relating to animals.", cat.clue())
        assertEquals("Terms relating to animals. · (countable) A mammal of the family Felidae.", cat.studyClue())
        assertFalse(cat.studyClue().contains("eaten as food"))
    }
    @Test fun truncatedUnknownAndTrailingPayloadsAreRejected() {
        val bytes=records().first().second
        for(n in listOf(0,3,10,bytes.size-1)) assertThrows(Exception::class.java){BlobDecoder.decode(bytes.copyOf(n),"bad","language","English","en")}
        assertThrows(Exception::class.java){BlobDecoder.decode(bytes+byteArrayOf(0),"bad","language","English","en")}
        assertThrows(Exception::class.java){BlobDecoder.decode("{\"entries\":[]}".toByteArray(),"bad","language","English","en")}
        val huge=bytes.copyOf();for(i in 4..7)huge[i]=(-1).toByte()
        assertThrows(Exception::class.java){BlobDecoder.decode(huge,"bad","language","English","en")}
    }
    @Test fun catalogueAcceptsBareAndVerifiedLinksAndRejectsUnsafeRows() {
        assertEquals("English", Catalog.parse("# catalogue\nhttps://example.org/English.wikblb\n").single().label)
        assertEquals(123L,Catalog.parse("https://example.org/en.wikblb\tEnglish\t123\t"+"a".repeat(64)).single().bytes)
        for(row in listOf("http://example.org/a.wikblb","file:///a.wikblb","https://user:secret@example.org/a","https:///a","https://example.org/a\tA\t-1","https://example.org/a\tA\t1\tbad")) assertThrows(Exception::class.java){Catalog.parse(row)}
        assertThrows(Exception::class.java){Catalog.parse("asset://English.wikblb")}
        assertEquals(1,Catalog.parse("asset://English.wikblb",true).size)
    }
    private fun explanationFixture(version: Int, background: String? = null, backgroundPresence: Int? = null, foreground: String? = null, foregroundPresence: Int? = null,
        spanBackground: String? = null, spanBackgroundPresence: Int? = null, anchored: Boolean = false,
        breton: Boolean = false, etymologyIndex: Int = -1, lexemeSection: Int = 2, hasLexeme: Boolean = true): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        fun byte(v: Int) { out.write(v) }
        fun u32(v: Int) { repeat(4) { byte(v ushr (it * 8) and 255) } }
        fun string(v: String) { val b = v.toByteArray(Charsets.UTF_8); u32(b.size); out.write(b) }
        fun spans(label: String) {
            u32(1); byte(1); byte(1); byte(10)
            listOf(label, "glossary", "!", "en", "abbr", "ltr").forEach(::string)
            if (version >= 3) string("Meaning & <plain> \u2067معنى\u2069: $label")
            if (version >= 4) {
                byte(foregroundPresence ?: if (foreground == null) 0 else 1)
                if (foreground != null) string(foreground)
            }
            if (version >= 6) {
                byte(spanBackgroundPresence ?: if (spanBackground == null) 0 else 1)
                if (spanBackground != null) string(spanBackground)
            }
        }
        fun block(table: Boolean) {
            byte(if (table) 12 else 0); byte(0); byte(0)
            spans(if (table) "table-body" else "body")
            byte(0); string(""); string(""); byte(if (table) 1 else 0)
            if (table) {
                spans("caption"); u32(1); u32(1); byte(0); byte(1); byte(0); byte(1); byte(0)
                if (version >= 4) {
                    byte(backgroundPresence ?: if (background == null) 0 else 1)
                    if (background != null) string(background)
                }
                spans("cell")
            }
            if (version >= 5) { string(""); string("") }
        }
        out.write("DPR$version".toByteArray())
        if (breton) {
            // The captured laezh-glas organization: language0, Gerdarzh1, noun2,
            // related translations3. The native correction only changes null to1.
            fun plainSpans(text: String) {
                u32(1); byte(0); byte(0); byte(0)
                listOf(text, "", "", "", "", "").forEach(::string)
                if (version >= 3) string("")
                if (version >= 4) byte(0)
                if (version >= 6) byte(0)
            }
            fun plainBlock(kind: Int, text: String, depth: Int = 0, path: String = "") {
                byte(kind); byte(depth); byte(0); plainSpans(text)
                byte(0); string(path); string(""); byte(0)
                if (version >= 5) { string(""); string("") }
            }
            fun heading(level: Int, title: String, blocks: Int) {
                byte(level); string(title)
                if (version >= 5) { string(title); string("") }
                u32(blocks)
            }
            u32(0); u32(4)
            heading(2, "Brezhoneg", 0)
            heading(3, "Gerdarzh", 1)
            plainBlock(7, "Ger kevrennek savet diwar an anv-kadarn laezh hag an anv-gwan glas", 1, ":")
            heading(3, "Anv-kadarn", 4)
            plainBlock(0, "laezh-glas /lɛzˈɡlɑːs/ hollek gourel")
            plainBlock(2, "Laezh-bihan", 1, "#")
            plainBlock(4, "First retained quotation", 1, "#:")
            plainBlock(4, "Second retained quotation", 1, "#:")
            heading(4, "Troidigezhioù", 1)
            plainBlock(5, "galleg : petit-lait (fr)", 1, "*")
            u32(0); u32(if (hasLexeme) 1 else 0)
            if (hasLexeme) {
                string("brezhoneg"); string("Noun"); u32(lexemeSection); u32(etymologyIndex)
                u32(1); u32(1); u32(-1) // Definition block1, no parent sense.
                u32(0); u32(2); u32(2); u32(3); u32(0); byte(0)
                u32(1); u32(0); u32(0); u32(1); u32(3)
            }
            u32(if (hasLexeme) 2 else 4); u32(0); u32(1)
            if (!hasLexeme) { u32(2); u32(3) } // With no owner, all sections remain unowned.
            u32(0); u32(0) // References and media.
            return out.toByteArray()
        }
        spans("display")
        u32(1); byte(3); string("Noun")
        if (version >= 5) { string(if (anchored) "Noun" else ""); string(if (anchored) "Noun_fallback" else "") }
        u32(2); block(false); block(true)
        spans("preamble"); u32(0); u32(0)
        u32(1); u32(1); u32(1); string(""); string(""); spans("reference"); u32(0)
        return out.toByteArray()
    }
    @Test fun typedBretonEtymologySurvivesDecodingAndDrivesOnlyItsOwnFold() {
        for (version in 2..9) {
            fun decode(index: Int = 1, owner: Int = 2, hasLexeme: Boolean = true) = BlobDecoder.decode(
                explanationFixture(version, breton = true, etymologyIndex = index, lexemeSection = owner, hasLexeme = hasLexeme),
                "laezh-glas", "language", "brezhoneg", "br")
            val entry = decode()
            assertEquals(setOf(1), entry.etymologySections)
            assertEquals(listOf("Brezhoneg", "Gerdarzh", "Anv-kadarn", "Troidigezhioù"), entry.sections.map { it.title })
            val folded = entry.readingRows.filter { initiallyFolded(it,
                AppSettings(collapseEtymology = true, collapseOtherSections = false, collapseDetails = false)) }.map { it.key }.toSet()
            assertEquals(setOf("heading-1"), folded)
            val visible = visibleReadingRows(entry.readingRows, folded).mapNotNull { it.block }
            assertEquals(entry.sections.drop(2).flatMap { it.blocks }, visible)
            assertEquals("Laezh-bihan", textOf(visible[1].spans))
            assertEquals(entry.etymologySections, entry.copy(title = "same typed body").etymologySections)
            val unassociated = decode(-1)
            assertTrue(unassociated.etymologySections.isEmpty())
            assertFalse(initiallyFolded(unassociated.readingRows.first { it.key == "heading-1" },
                AppSettings(collapseEtymology = true, collapseOtherSections = false)))
            assertTrue(decode(hasLexeme = false).etymologySections.isEmpty())
            for (invalid in listOf(4, -2)) {
                assertThrows(IllegalArgumentException::class.java) { decode(invalid) }
            }
            assertThrows(IllegalArgumentException::class.java) { decode(owner = 4) }
        }
    }
    @Test fun legacyAndExplainedWirePreserveAllSpanContainersAndCompactText() {
        val explained = BlobDecoder.decode(explanationFixture(3), "Word", "language", "English", "en")
        val lists = listOf(explained.displayTitle, explained.preamble,
            explained.sections.single().blocks[0].spans, explained.sections.single().blocks[1].spans,
            explained.sections.single().blocks[1].table!!.caption,
            explained.sections.single().blocks[1].table!!.rows.single().single().spans,
            explained.references.single().spans)
        assertEquals(7, lists.size)
        lists.forEach { spans ->
            val span = spans.single()
            assertEquals("Meaning & <plain> \u2067معنى\u2069: " + span.text, span.explanation)
            assertEquals(span.text + "!", textOf(spans))
            assertEquals("glossary", span.target); assertEquals("ltr", span.direction)
            assertTrue(span.italic && span.small); assertEquals("label", span.role)
        }
        val legacy = BlobDecoder.decode(explanationFixture(2), "Word", "language", "English", "en")
        assertTrue(legacy.abbreviations.isEmpty())
        assertEquals(textOf(explained.displayTitle), textOf(legacy.displayTitle))
        records().forEach { (title, payload) ->
            assertEquals("DPR2", payload.copyOfRange(0, 4).decodeToString())
            assertTrue(BlobDecoder.decode(payload, title, "language", "English", "en").abbreviations.isEmpty())
        }
    }
    @Test fun explainedWireRejectsTruncatedMalformedUtf8AndUnsupportedVersions() {
        val bytes = explanationFixture(3)
        for (length in listOf(0, 3, 8, bytes.size - 1)) assertThrows(Exception::class.java) {
            BlobDecoder.decode(bytes.copyOf(length), "Word", "language", "English", "en")
        }
        val unknown = bytes.copyOf().also { it[3] = '7'.code.toByte() }
        assertThrows(Exception::class.java) { BlobDecoder.decode(unknown, "Word", "language", "English", "en") }
        val marker = "Meaning &".toByteArray()
        val start = bytes.asList().windowed(marker.size).indexOfFirst { it == marker.asList() }
        assertTrue(start >= 0)
        val invalid = bytes.copyOf().also { it[start] = 0xff.toByte() }
        assertThrows(Exception::class.java) { BlobDecoder.decode(invalid, "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(bytes + byteArrayOf(0), "Word", "language", "English", "en") }
        for (color in listOf("", "red", "#FFF000", "#ff0", "#ff000000", "#gggggg", " #ffff00", "#ffff00 ", "background:#ffff00"))
            assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(6, spanBackground = color), "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(6, spanBackgroundPresence = 2), "Word", "language", "English", "en") }
        val painted = explanationFixture(6, background = "#fffdd0", foreground = "#008000", spanBackground = "#ffffe0")
        for (length in painted.indices) assertThrows(Exception::class.java) {
            BlobDecoder.decode(painted.copyOf(length), "Word", "language", "English", "en")
        }
        assertThrows(Exception::class.java) { BlobDecoder.decode(painted + byteArrayOf(0), "Word", "language", "English", "en") }
    }

    @Test fun cellBackgroundWirePreservesEveryOtherEntryFieldAndLegacyRecords() {
        val legacy = BlobDecoder.decode(explanationFixture(3), "Word", "language", "English", "en")
        val absent = BlobDecoder.decode(explanationFixture(4), "Word", "language", "English", "en")
        assertEquals(legacy, absent)
        val colored = BlobDecoder.decode(explanationFixture(4, "#12ab34"), "Word", "language", "English", "en")
        val cell = colored.sections.single().blocks[1].table!!.rows.single().single()
        assertEquals("#12ab34", cell.background)
        val cleared = colored.copy(sections = colored.sections.map { section -> section.copy(blocks = section.blocks.map { block ->
            block.copy(table = block.table?.let { table -> table.copy(rows = table.rows.map { row -> row.map { it.copy(background = null) } }) })
        }) })
        assertEquals(legacy, cleared)
        assertNull(BlobDecoder.decode(explanationFixture(2), "Word", "language", "English", "en")
            .sections.single().blocks[1].table!!.rows.single().single().background)
    }
    @Test fun cellBackgroundWireRejectsMalformedPresenceColorAndIncompleteRecords() {
        for (color in listOf("", "red", "#FFF000", "#ff0", "#ff000000", "#gggggg", " #ffff00", "#ffff00 ", "background:#ffff00"))
            assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(4, color), "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(4, backgroundPresence = 2), "Word", "language", "English", "en") }
        val bytes = explanationFixture(4, "#12ab34")
        for (length in bytes.indices) assertThrows(Exception::class.java) {
            BlobDecoder.decode(bytes.copyOf(length), "Word", "language", "English", "en")
        }
        assertThrows(Exception::class.java) { BlobDecoder.decode(bytes + byteArrayOf(0), "Word", "language", "English", "en") }
    }

    @Test fun spanForegroundWirePreservesAllContainersExplanationsAndActions() {
        val legacy = BlobDecoder.decode(explanationFixture(3), "Word", "language", "English", "en")
        val colored = BlobDecoder.decode(explanationFixture(4, foreground = "#008000"), "Word", "language", "English", "en")
        fun containers(entry: Entry) = listOf(entry.displayTitle, entry.preamble,
            entry.sections.single().blocks[0].spans, entry.sections.single().blocks[1].spans,
            entry.sections.single().blocks[1].table!!.caption,
            entry.sections.single().blocks[1].table!!.rows.single().single().spans,
            entry.references.single().spans)
        val before = containers(legacy)
        val after = containers(colored)
        for (version in 2..6) {
            val absent = BlobDecoder.decode(explanationFixture(version), "Word", "language", "English", "en")
            assertTrue(containers(absent).flatten().all { it.background == null })
            if (version >= 3) assertEquals(legacy, absent)
        }
        val backgroundOnly = BlobDecoder.decode(explanationFixture(6, spanBackground = "#ffffe0"), "Word", "language", "English", "en")
        containers(backgroundOnly).zip(before).forEach { (spans, original) ->
            assertNull(spans.single().foreground)
            assertEquals("#ffffe0", spans.single().background)
            assertEquals(original, spans.map { it.copy(background = null) })
        }
        val painted = BlobDecoder.decode(explanationFixture(6, background = "#fffdd0", foreground = "#008000", spanBackground = "#ffffe0", anchored = true), "Word", "language", "English", "en")
        containers(painted).zip(before).forEach { (spans, original) ->
            assertEquals("#008000", spans.single().foreground)
            assertEquals("#ffffe0", spans.single().background)
            assertEquals(original, spans.map { it.copy(foreground = null, background = null) })
        }
        assertEquals("#fffdd0", painted.sections.single().blocks[1].table!!.rows.single().single().background)
        assertEquals("Noun", painted.sections.single().anchor)
        assertEquals("Noun_fallback", painted.sections.single().anchorFallback)
        assertEquals(7, after.size)
        after.zip(before).forEach { (spans, original) ->
            assertEquals("#008000", spans.single().foreground)
            assertEquals(original, spans.map { it.copy(foreground = null) })
            assertEquals(textOf(original), textOf(spans))
        }
        assertEquals(legacy, BlobDecoder.decode(explanationFixture(4), "Word", "language", "English", "en"))
        for (color in listOf("", "green", "#00800A", "#080", "#ff008000", " #008000"))
            assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(4, foreground = color), "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(4, foregroundPresence = 2), "Word", "language", "English", "en") }
        val bytes = explanationFixture(4, "#eeeeee", foreground = "#008000")
        for (length in bytes.indices) assertThrows(Exception::class.java) {
            BlobDecoder.decode(bytes.copyOf(length), "Word", "language", "English", "en")
        }
    }

}
