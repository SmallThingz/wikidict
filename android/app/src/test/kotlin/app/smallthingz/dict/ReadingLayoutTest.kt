package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import androidx.compose.ui.unit.em

class ReadingLayoutTest {
    private fun sourceHeadingStyle(): SectionHeadingStyle {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        return SectionHeadingStyle(ContainerStyle(margins = edges, padding = edges,
            border = ContainerBorder.None, clear = FigureClear.None, ownerFontScale = 1f,
            lineHeight = ContainerLineHeight.Multiplier(1f), fontFamily = ContainerFontFamily.SansSerif),
            InlineFontSnapshot(fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody, language = "th"),
            BidiResolvedDirection.Ltr)
    }

    @Test fun typedSectionCompanionRetainsActionsAnchorsAndOriginalIndicesOnce() {
        val heading = Block("heading", 0, listOf(Span("link", "Owner", "title-action"), Span("text", " heading")),
            level = 3, anchor = "owner", anchorFallback = "owner-fallback")
        val body = Block("paragraph", 0, listOf(Span("link", "Body", "body-action")))
        val section = Section(3, "Owner heading", listOf(heading, body), "owner", "owner-fallback", sourceHeadingStyle())
        for (policy in listOf(null, BodyAdjoiningPolicy.Ordinary)) {
            val entry = Entry("word", emptyList(), "language", "Japanese", "ja", listOf(section),
                listOf(Reference(1, 1, "", listOf(Span("text", "Reference")))), bodyAdjoining = policy)
            val rows = entry.readingRows
            assertEquals(listOf("heading-0", "block-0-1"), rows.map { it.key })
            assertSame(section, rows.first().heading)
            assertSame(heading, rows.first().headingBlock)
            assertSame(body, rows.last().block)
            assertEquals(listOf("title-action", "body-action"), rows.flatMap {
                (it.headingBlock ?: it.block)?.spans.orEmpty()
            }.filter { it.kind == "link" }.map { it.target })
            assertEquals("heading-0", headingDestination(entry, "#owner")!!.rowKey)
            assertEquals("heading-0", headingDestination(entry, "#owner-fallback")!!.rowKey)
            assertEquals(listOf("heading-0"), visibleEntryReadingRows(entry, setOf("heading-0")).map { it.key })
            assertEquals(entryReadingStartIndex(entry, emptySet()) + 2, metadataReferencesStartIndex(entry, emptySet()))
            assertEquals(listOf(heading, body), entry.sections.single().blocks)
        }
    }

    @Test fun typedPlainAndWhitespaceHeadingBoxesStayVisibleWithoutChangingNullCompanionHeuristic() {
        for (title in listOf("Plain", " ")) {
            val heading = Block("heading", 0, listOf(Span("text", title)), level = 3)
            val legacy = Section(3, title, listOf(heading))
            val typed = legacy.copy(headingStyle = sourceHeadingStyle())
            assertNull(sectionHeadingCompanion(legacy))
            assertSame(heading, sectionHeadingCompanion(typed))
            assertTrue(sectionHeadingVisible(typed, "Japanese"))
            assertEquals(title, sectionHeadingLabel(typed, "Japanese", heading))
            val rows = readingRows(listOf(typed))
            assertEquals(1, rows.size)
            assertSame(heading, rows.single().headingBlock)
            assertTrue(rows.none { it.block != null })
            assertEquals(if (title == " ") 1 else 2, readingRows(listOf(legacy)).size)
            assertEquals(readingRows(listOf(legacy)), readingRows(listOf(typed.copy(headingStyle = null))))
            assertSame(heading, typed.blocks.single())
        }
    }

    @Test fun explicitBodyRowsKeepSourceBlocksSpansAndEmptyBoundariesWithoutDenseSplitting() {
        val whitespace = Block("paragraph", 0, listOf(Span("text", " "), Span("text", "Body"), Span("text", " ")))
        val dense = Block("paragraph", 0, List(90) {
            if (it % 2 == 0) Span("text", "Word$it") else Span("line_break", "\n")
        })
        val blank = Block("blank", 0, emptyList())
        val empty = Block("paragraph", 0, emptyList())
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val styledEmpty = empty.copy(style = BlockStyle(margins = StyleEdges(zero, zero, zero, zero)))
        val table = Block("table", 0, emptyList(), table = Table(listOf(Span("text", " ")),
            listOf(listOf(Cell(listOf(Span("text", " ")), false, 1, 1)))))
        val source = listOf(whitespace, dense, blank, empty, styledEmpty, table)
        val sections = listOf(Section(3, "", source))
        val owned = readingRows(sections, bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        assertEquals(listOf("heading-0") + source.indices.map { "block-0-$it" }, owned.map { it.key })
        assertTrue(owned.none { it.compact })
        owned.mapNotNull { it.block }.zip(source).forEach { (actual, original) ->
            assertSame(original, actual)
            assertSame(original.spans, actual.spans)
        }
        val legacy = readingRows(sections)
        assertEquals(legacy, readingRows(sections, bodyAdjoining = null))
        assertTrue(legacy.none { it.key == "block-0-2" || it.key == "block-0-3" })
        assertTrue(legacy.count { it.key.startsWith("block-0-1-") } > 1)
        assertEquals(listOf(Span("text", "Body")), legacy.single { it.key == "block-0-0" }.block!!.spans)
        assertTrue(legacy.single { it.key == "block-0-5" }.block!!.table!!.caption.isEmpty())
        assertEquals(source, sections.single().blocks)
    }

    @Test fun explicitBodyCompanionFoldAndMetadataIndicesKeepEachSourceActionOnce() {
        val heading = Block("heading", 0, listOf(Span("link", "Notes", "heading-action")), level = 3)
        val body = Block("paragraph", 0, listOf(Span("link", "Body", "body-action")))
        val sections = listOf(Section(3, "Notes", listOf(heading, body)), Section(3, "Other", emptyList()))
        val rows = readingRows(sections, bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        assertSame(heading, rows.first().headingBlock)
        assertTrue(rows.none { it.block === heading })
        assertSame(body, rows.single { it.block != null }.block)
        assertEquals(listOf("heading-action", "body-action"), rows.flatMap {
            (it.headingBlock ?: it.block)?.spans.orEmpty()
        }.filter { it.kind == "link" }.map { it.target })
        val folded = visibleReadingRows(rows, setOf("heading-0"))
        assertEquals(listOf("heading-0", "heading-1"), folded.map { it.key })
        assertSame(heading, folded.first().headingBlock)
        assertEquals(rows, visibleReadingRows(rows, emptySet()))
    }

    @Test fun paragraphEdgesKeepLargeFiniteGeometryAndRejectOnlyUnrepresentableCoordinates() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val large = StyleLength(StyleLengthUnit.Px, 50000f)
        val block = Block("paragraph", 0, emptyList(), style = BlockStyle(
            margins = StyleEdges(large, zero, zero, zero), padding = StyleEdges(zero, zero, large, zero)))
        val box = paragraphBox(block, null, 6f, 2f, 20f)!!
        assertEquals(100000f, box.before, 0f)
        assertEquals(100000f, box.padding.bottom, 0f)
        assertEquals(0f, box.after, 0f)
        assertEquals(50000f, block.style!!.margins!!.top.value, 0f)
        assertEquals(50000f, paragraphLengthPixels(StyleLength(StyleLengthUnit.Em, 2500f), 2f, 20f), 0f)
        val enormous = StyleLength(StyleLengthUnit.Px, Float.MAX_VALUE)
        assertEquals(Float.MAX_VALUE, enormous.value, 0f)
        assertThrows(UnsupportedFloatLayout::class.java) { paragraphLengthPixels(enormous, 1f, 20f) }
    }

    @Test fun paragraphMarginsReplaceOnlyOwnedGapsAndCollapseOnlyAdjacentAuthoredParagraphs() {
        fun edges(top: Float, bottom: Float) = StyleEdges(StyleLength(StyleLengthUnit.Px, top),
            StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, bottom), StyleLength(StyleLengthUnit.Em, 1.6f))
        val plain = Block("paragraph", 0, listOf(Span("text", "Body")))
        val first = plain.copy(style = BlockStyle(margins = edges(3f, 10f)))
        val second = plain.copy(style = BlockStyle(margins = edges(7f, 2f), padding = edges(4f, 5f)))
        fun box(block: Block, previous: Block? = null, gap: Float = 6f) = paragraphBox(block, previous, gap, 2f, 20f)!!
        assertNull(paragraphBox(plain, first, 6f, 2f, 20f))
        assertEquals(6f, box(first).before, 0f); assertEquals(20f, box(first).after, 0f)
        assertEquals(0f, box(second, first).before, 0f)
        assertEquals(20f, box(first).after + box(second, first).before, 0f)
        assertEquals(14f, box(second, plain).before, 0f)
        assertEquals(14f, box(second, Block("list_item", 1, plain.spans, listPath = "*")).before, 0f)
        assertEquals(14f, box(second, Block("table", 0, emptyList(), table = Table(emptyList(), emptyList()))).before, 0f)
        assertEquals(14f, box(second).before, 0f) // New cell/reference/container: no predecessor.
        assertEquals(10f, box(second.copy(style = BlockStyle(margins = edges(15f, 2f))), first).before, 0f)
        assertEquals(8f, box(second).padding.top, 0f); assertEquals(10f, box(second).padding.bottom, 0f)
        assertEquals(32f, box(second).margins.left, 0f); assertEquals(32f, box(second).padding.left, 0f)
        assertEquals(32f, box(second.copy(spans = listOf(Span("text", "small", fontScale = .5f)))).padding.left, 0f)
        val paddingOnly = plain.copy(style = BlockStyle(padding = edges(0f, 0f)))
        assertEquals(6f, box(paddingOnly, first).after, 0f)
        assertEquals(0f, box(paddingOnly, first).before, 0f)
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val zeroMargins = plain.copy(style = BlockStyle(margins = StyleEdges(zero, zero, zero, zero)))
        assertEquals(0f, box(zeroMargins).after, 0f)
        assertEquals(0f, box(zeroMargins, first).before, 0f)
        assertEquals(2f, box(paddingOnly, gap = 2f).after, 0f)
        assertEquals(0f, box(paddingOnly, gap = 0f).after, 0f) // Last paragraph's old trailing policy.
    }

    @Test fun styledEmptyBoxesHaveOnlyExplicitGeometryAndDenseSourceBoxesStayWhole() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val allZero = StyleEdges(zero, zero, zero, zero)
        val empty = Block("paragraph", 0, emptyList(), style = BlockStyle(padding = allZero))
        for (spans in listOf(emptyList(), listOf(Span("text", " \t\r\n")), listOf(Span("text", "", code = true)))) {
            val block = empty.copy(spans = spans)
            assertTrue(paragraphDisplaySpans(block).isEmpty())
            val box = paragraphBox(block, null, 6f, 1f, 20f)!!
            assertEquals(0f, box.before + box.after + box.padding.top + box.padding.bottom, 0f)
            assertEquals(listOf(block.copy(spans = emptyList())), readingRows(listOf(Section(2, "", listOf(block)))).mapNotNull { it.block })
        }
        assertTrue(readingRows(listOf(Section(2, "", listOf(empty.copy(style = null))))).mapNotNull { it.block }.isEmpty())
        val br = empty.copy(spans = listOf(Span("line_break", "\n")))
        assertEquals(br.spans, paragraphDisplaySpans(br))
        assertEquals(6f, paragraphBox(br, null, 6f, 1f, 20f)!!.after, 0f)
        assertEquals(listOf(Span("text", "\u00a0")), paragraphDisplaySpans(empty.copy(spans = listOf(Span("text", "\u00a0")))))
        val dense = empty.copy(spans = List(90) { if (it % 2 == 0) Span("text", "Word$it") else Span("line_break", "\n") })
        val rows = readingRows(listOf(Section(2, "", listOf(dense)))).mapNotNull { it.block }
        assertEquals(listOf(dense), rows)
        assertTrue(readingRows(listOf(Section(2, "", listOf(dense.copy(style = null))))).mapNotNull { it.block }.size > 1)
    }

    @Test fun emptySpanContainersRetainExactTableActionsAndNativeEntryRows() {
        val zero = ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 0f))
        val policy = TableBlockViewport(639,
            TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f),
                marginValues = ContainerMargins(zero, ContainerMargin.Auto, zero, ContainerMargin.Auto),
                containingDirection = TableContainingDirection.Ltr),
            ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
            TableStyle(collapse = TableCollapse.Collapse), TableContainingDirection.Rtl, "ru")
        val action = Span("link", "reset", "native-reset-target")
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(action), false, 1, 1))), blockViewport = policy)
        val tableBlock = Block("table", 0, emptyList(), table = table)
        val container = Container(listOf(tableBlock), ContainerStyle())
        val outer = Block("container", 0, emptyList(), container = container)
        val nested = Block("container", 0, emptyList(), container = Container(listOf(outer), ContainerStyle()))
        val emptyParagraph = Block("paragraph", 0, emptyList())
        for (source in listOf(outer, nested)) {
            val entry = Entry("Native source owner", emptyList(), "language", "Japanese", "ja",
                listOf(Section(2, "", listOf(emptyParagraph, source))), emptyList(), edition = "ja")
            val rows = entry.readingRows
            assertEquals(listOf("heading-0", "block-0-1"), rows.map { it.key })
            assertSame(source, rows.last().block)
            val visible = visibleEntryReadingRows(entry, setOf("heading-0"))
            assertEquals(rows, visible)
            assertEquals(listOf(1..1), floatBodyRuns(visible))
            val retained = checkNotNull(visible.last().block!!.container)
            val actual = if (source === outer) retained else checkNotNull(retained.blocks.single().container)
            assertSame(container, actual)
            assertSame(tableBlock, actual.blocks.single())
            assertSame(table, actual.blocks.single().table)
            assertSame(policy, actual.blocks.single().table!!.blockViewport)
            assertSame(action, actual.blocks.single().table!!.rows.single().single().spans.single())
            assertTrue(visible.none { it.block === emptyParagraph })
        }
    }

    @Test fun descriptionOnlyAndImageOwnedAdviceStayDiscoverableWithoutChangingImageNames() {
        val own = Span("text", "", image = InlineImage("Own.svg", 15, alt = " ", tooltip = "Own D"), tooltip = "Raw C")
        val silent = Span("text", "", image = InlineImage("Silent.svg", 15, alt = "Silent label", tooltip = ""), tooltip = "Raw C")
        val parent = Span("text", "", image = InlineImage("Parent.svg", 15, alt = " Authored label "), tooltip = "Parent E")
        val unnamed = Span("text", "", image = InlineImage("File:Opaque.svg", 15), tooltip = "Parent F")
        val spans = listOf(Span("text", "", tooltip = "Empty advice"), Span("text", " \t", tooltip = "Whitespace advice"),
            Span("line_break", "\n", tooltip = "Break advice"), own, silent, parent, unnamed)
        val entry = Entry("word", emptyList(), "language", "English", "en",
            listOf(Section(3, "Notes", listOf(Block("paragraph", 0, spans)))), emptyList(),
            media = listOf(own, silent, parent, unnamed).map { Media(it.image!!.file, "image", "") })
        val advice = entry.textDetails.filter { it.kind == TextDetailKind.Advisory }
        assertEquals(listOf("Empty advice", "Whitespace advice", "Break advice", "Own D", "Parent E", "Parent F"), advice.map { it.description })
        assertTrue(advice.take(4).all { it.label.isBlank() })
        assertEquals(" Authored label ", advice[4].label)
        assertEquals("", advice[5].label)
        assertTrue(advice[3].context.endsWith(" · Own.svg"))
        assertTrue(advice[5].context.endsWith(" · File:Opaque.svg"))
        assertFalse(advice.any { it.description == "Raw C" })
        assertEquals(spans, entry.sections.single().blocks.single().spans)
        assertEquals(" ", own.image!!.alt); assertNull(unnamed.image!!.alt)
        assertEquals("Raw C", own.tooltip); assertEquals("Own D", own.image!!.tooltip)
        assertEquals("", silent.image!!.tooltip)
        assertTrue(entry.abbreviations.isEmpty())
        assertEquals("", textOf(spans))
        assertEquals(1 + advice.size, entryReadingStartIndex(entry, emptySet()))
    }

    @Test fun typedMediaDescriptionsRequireActualCatalogOwnershipAndNeverRetypeAbbreviationMeaning() {
        val token = "wikidict-media-file-546f6e652e6f6767"
        val audio = Span("link", "Audio label", "File:Tone.ogg", classes = "wikidict-media $token", explanation = "B")
        val abbreviation = Span("text", "abbr", explanation = "B")
        val unknown = audio.copy(text = "Unknown", classes = "wikidict-media wikidict-media-file-00", explanation = "Unknown expansion")
        val missing = audio.copy(text = "Missing", target = "File:Missing.ogg", classes = "wikidict-media", explanation = "Missing expansion")
        val ambiguous = audio.copy(text = "Ambiguous", classes = "wikidict-media $token wikidict-media-file-00", explanation = "Ambiguous expansion")
        val unlabelled = audio.copy(text = " ", explanation = "Media only")
        val spans = listOf(audio, abbreviation, unknown, missing, ambiguous, unlabelled)
        val media = listOf(Media("Tone.ogg", "audio", ""))
        val owners = MediaOwners(media)
        assertEquals(media.single(), owners.media(audio))
        for (span in listOf(unknown, missing, ambiguous)) assertNull(owners.media(span))
        val entry = Entry("word", emptyList(), "language", "English", "en",
            listOf(Section(3, "Notes", listOf(Block("paragraph", 0, spans)))), emptyList(), media = media)
        assertEquals(listOf(TextDetailKind.MediaDescription, TextDetailKind.Abbreviation, TextDetailKind.Abbreviation,
            TextDetailKind.Abbreviation, TextDetailKind.Abbreviation, TextDetailKind.MediaDescription), entry.textDetails.map { it.kind })
        assertEquals(listOf("B", "B", "Unknown expansion", "Missing expansion", "Ambiguous expansion", "Media only"), entry.textDetails.map { it.description })
        assertEquals("Audio label", entry.textDetails[0].label)
        assertEquals("abbr", entry.textDetails[1].label)
        assertTrue(entry.textDetails.last().label.isBlank())
        assertTrue(entry.textDetails.last().context.endsWith(" · Tone.ogg"))
        // The legacy abbreviation collector retains its exact original grouping/blank-label behavior.
        assertEquals("Audio labelabbr", entry.abbreviations.first().label)
        assertEquals(listOf("B", "Unknown expansion", "Missing expansion", "Ambiguous expansion"), entry.abbreviations.map { it.explanation })
        assertEquals(spans, entry.sections.single().blocks.single().spans)
    }

    @Test fun richHeadingAdviceAndDenseLineTrailsRetainNullableMetadataOnce() {
        for (advice in listOf(null, "", "Heading advice")) {
            val heading = Block("heading", 0, listOf(Span("text", "Notes", tooltip = advice)), level = 3)
            val section = Section(3, "Notes", listOf(heading))
            if (advice == null) assertNull(sectionHeadingCompanion(section))
            else {
                assertSame(heading, sectionHeadingCompanion(section))
                assertTrue(readingRows(listOf(section)).none { it.block === heading })
            }
            val entry = Entry("word", emptyList(), "language", "English", "en", listOf(section), emptyList())
            assertEquals(if (advice.isNullOrEmpty()) emptyList<String>() else listOf(advice),
                entry.textDetails.filter { it.kind == TextDetailKind.Advisory }.map { it.description })
        }
        val advice = List(40) { listOf(null, "", "Trail advice")[it % 3] }
        val spans = advice.flatMap { value -> listOf(Span("text", "word"),
            Span("line_break", "\n", trail = "tail", explanation = "Expansion", background = "#ffffe0", tooltip = value)) }
        val rows = readingRows(listOf(Section(3, "Derived terms", listOf(Block("paragraph", 0, spans)))))
        val trails = rows.mapNotNull { it.block }.flatMap { it.spans }.filter { it.text == "tail" }
        assertEquals(advice, trails.map { it.tooltip })
        assertTrue(trails.all { it.explanation == "Expansion" && it.background == "#ffffe0" })
    }

    @Test fun genericAdviceKeepsLiteralMetadataSeparateFromAbbreviationsAndMainText() {
        val sg = Span("link", "\\bə.lɑs.tɪŋ\\", "Aide:Sêndagô/Holandëe", classes = "API", tooltip = "Sêndagô API")
        val uz = Span("link", "koʻchma", "Vikilugʻat:Shartli qisqartmalar", italic = true,
            background = "#ccffff", tooltip = "koʻchma soʻz", targetFragment = "")
        val spans = listOf(sg, Span("text", " "), uz)
        val entry = Entry("Advice", emptyList(), "language", "Language", "und",
            listOf(Section(3, "Notes", listOf(Block("paragraph", 0, spans)))), emptyList())
        assertTrue(entry.abbreviations.isEmpty())
        assertEquals(listOf("Sêndagô API", "koʻchma soʻz"), entry.textDetails.map { it.description })
        assertTrue(entry.textDetails.all { it.kind == TextDetailKind.Advisory })
        assertEquals(listOf(sg.text, uz.text), entry.textDetails.map { it.label })
        assertEquals(spans, entry.sections.single().blocks.single().spans)
        assertEquals("\\bə.lɑs.tɪŋ\\ koʻchma", textOf(spans))
        assertEquals(entry.clue(), entry.copy(sections = listOf(Section(3, "Notes", listOf(
            Block("paragraph", 0, spans.map { it.copy(tooltip = null) }))))).clue())
        assertEquals(1, entryReadingStartIndex(entry, setOf("abbreviations")))
        assertEquals(3, entryReadingStartIndex(entry, emptySet()))
        assertEquals(3, listOf(sg.copy(tooltip = null), sg.copy(tooltip = ""), sg).toSet().size)
        assertEquals(sg.tooltip, sg.copy(text = "Copied label").tooltip)
    }

    @Test fun abbreviationExpansionSurvivesOwnResetAndNestedEmptyOrChangedAdvice() {
        fun entry(spans: List<Span>) = Entry("Scopes", emptyList(), "language", "English", "en",
            listOf(Section(3, "Notes", listOf(Block("paragraph", 0, spans)))), emptyList())
        val own = entry(listOf(Span("text", "Parent", tooltip = "A"), Span("text", "abbr", explanation = "B")))
        assertEquals(listOf("B"), own.abbreviations.map { it.explanation })
        assertEquals(listOf("A"), own.textDetails.filter { it.kind == TextDetailKind.Advisory }.map { it.description })
        val emptyOwn = entry(listOf(Span("text", "abbr", tooltip = null, explanation = "")))
        assertTrue(emptyOwn.textDetails.isEmpty())
        for (advice in listOf("", "C")) {
            val nested = entry(listOf(Span("text", "label", explanation = "B", tooltip = advice)))
            assertEquals(listOf("B"), nested.abbreviations.map { it.explanation })
            assertEquals(listOf("B"), nested.textDetails.filter { it.kind == TextDetailKind.Abbreviation }.map { it.description })
            assertEquals(if (advice.isEmpty()) emptyList<String>() else listOf("C"),
                nested.textDetails.filter { it.kind == TextDetailKind.Advisory }.map { it.description })
        }
        val image = Span("text", "", image = InlineImage("Asset.svg", alt = "Independent alt"), tooltip = "Parent advice")
        assertEquals("Parent advice", image.imageTooltip)
        assertEquals("", image.copy(image = image.image!!.copy(tooltip = "")).imageTooltip)
        assertEquals("Own", image.copy(image = image.image!!.copy(tooltip = "Own")).imageTooltip)
        assertEquals("Independent alt", image.image!!.alt)
        assertThrows(IllegalArgumentException::class.java) { Span("text", "x", tooltip = "\uD800") }
    }


    @Test fun typedEtymologyUsesItsOwnPreferenceWithoutGuessingOwnersOrHidingChildBodies() {
        val etymology = Block("indent", 1, listOf(Span("text", "Savet diwar an anv-kadarn reol hag al lostger -iek")), listPath = ":")
        val definition = Block("definition", 1, listOf(Span("text", "Adjective body")), listPath = "#")
        val related = Block("list_item", 1, listOf(Span("text", "kantreol")), listPath = "*")
        val sections = listOf(Section(2, "Brezhoneg", emptyList()), Section(3, "Gerdarzh", listOf(etymology)),
            Section(3, "Anv-gwan", listOf(definition)), Section(4, "Gerioù kar dre o ster", listOf(related)))
        val entry = Entry("reoliek", emptyList(), "language", "brezhoneg", "br", sections, emptyList(), etymologySections = setOf(1))
        fun folds(value: Entry, etymology: Boolean, other: Boolean): Set<String> = value.readingRows.filter {
            initiallyFolded(it, AppSettings(collapseEtymology = etymology, collapseOtherSections = other, collapseDetails = false))
        }.map { it.key }.toSet()
        assertEquals(setOf("heading-1"), folds(entry, true, false))
        assertEquals(listOf(definition, related), visibleReadingRows(entry.readingRows, folds(entry, true, false)).mapNotNull { it.block })
        val otherFolded = folds(entry, false, true)
        assertFalse("heading-1" in otherFolded)
        assertEquals(listOf(etymology, definition), visibleReadingRows(entry.readingRows, otherFolded).mapNotNull { it.block })
        assertEquals(sections, entry.sections)

        // Actual kuzhheolioù remains Unclassified with no lexemes. Neither its
        // language label nor a localized heading may invent an etymology owner.
        val unknown = Entry("kuzhheolioù", emptyList(), "language", "Unclassified", "", listOf(
            Section(2, "Unclassified", listOf(Block("definition", 1, listOf(Span("text", "furm lies kuzh-heol."))))),
            Section(4, "Gerioù heñvelster", listOf(related))), emptyList())
        assertTrue(unknown.etymologySections.isEmpty())
        assertEquals(listOf(unknown.sections[0].blocks.single(), related),
            visibleReadingRows(unknown.readingRows, folds(unknown, true, false)).mapNotNull { it.block })
        val unassociated = entry.copy(etymologySections = emptySet())
        assertFalse("heading-1" in folds(unassociated, true, false))
        assertTrue("heading-1" in folds(unassociated, false, true))

        val bounded = readingRows(sections, etymologySections = setOf(-1, 1, 99))
        assertEquals(listOf("heading-1"), bounded.filter { it.etymologySection }.map { it.key })
        val blank = readingRows(listOf(Section(3, "", listOf(etymology))), etymologySections = setOf(0))
        assertFalse(initiallyFolded(blank.first(), AppSettings(collapseEtymology = true)))
        assertEquals(listOf(etymology), visibleReadingRows(blank, setOf("heading-0")).mapNotNull { it.block })
    }

    @Test fun definitionlessLocalizedSectionsExposeBodyOnlyOnExplicitRequest() {
        // Captured AS assamese has an overview paragraph before two localized POS sections.
        val overview = Block("paragraph", 0, listOf(Span("text", "ইংৰাজী")))
        val noun = Block("list_item", 2, listOf(Span("text", "noun body")), listPath = ":#")
        val adjective = Block("list_item", 2, listOf(Span("text", "adjective body")), listPath = ":#")
        val rows = readingRows(listOf(Section(2, "Unclassified", listOf(overview)),
            Section(2, "নাম", listOf(noun)), Section(2, "বিশেষণ", listOf(adjective))))
        val preferences = AppSettings(collapseOtherSections = true)
        val folds = rows.filter { initiallyFolded(it, preferences) }.associate { it.key to true }.toMutableMap()
        folds["preamble"] = true; folds["references"] = true; folds["media"] = true; folds["abbreviations"] = true
        val before = folds.toMap()
        val keys = foldedEntryTextSections(rows, folds.filterValues { it }.keys)
        assertEquals(listOf("heading-0", "heading-1", "heading-2"), keys)
        assertEquals(before, folds) // Merely offering the action never overrides saved/manual folds.
        assertTrue(visibleReadingRows(rows, folds.filterValues { it }.keys).none { it.block != null })
        keys.forEach { folds[it] = false } // Explicit button action.
        assertEquals(listOf(overview, noun, adjective), visibleReadingRows(rows, folds.filterValues { it }.keys).mapNotNull { it.block })
        assertTrue(foldedEntryTextSections(rows, folds.filterValues { it }.keys).isEmpty())
        for (key in listOf("preamble", "references", "media", "abbreviations")) assertEquals(true, folds[key])
        assertTrue(preferences.collapseOtherSections)
        folds["heading-1"] = true // Manual collapse still wins and the action becomes available again.
        assertEquals(listOf("heading-1"), foldedEntryTextSections(rows, folds.filterValues { it }.keys))
        assertFalse(visibleReadingRows(rows, folds.filterValues { it }.keys).any { it.block == noun })
    }

    @Test fun recognizedDefinitionsKeepSupportingSectionPolicy() {
        val definition = Block("definition", 1, listOf(Span("text", "Meaning")))
        val support = Block("paragraph", 0, listOf(Span("text", "Support")))
        val rows = readingRows(listOf(Section(3, "Noun", listOf(definition)), Section(3, "Notes", listOf(support))))
        val folded = rows.filter { initiallyFolded(it, AppSettings()) }.map { it.key }.toSet()
        assertTrue(foldedEntryTextSections(rows, folded).isEmpty())
        assertEquals(listOf(definition), visibleReadingRows(rows, folded).mapNotNull { it.block })
    }

    @Test fun bodyActionRequiresAnActuallyFoldedNamedBody() {
        val body = Block("list_item", 2, listOf(Span("text", "Body")), listPath = ";#")
        val rows = readingRows(listOf(Section(2, "", listOf(body)), Section(3, "References", emptyList())))
        assertTrue(foldedEntryTextSections(rows, setOf("heading-0", "heading-1", "references")).isEmpty())
        val named = readingRows(listOf(Section(3, "নাম", listOf(body))))
        assertTrue(foldedEntryTextSections(named, emptySet()).isEmpty())
        val openDefaults = named.filter { initiallyFolded(it, AppSettings(collapseOtherSections = false)) }.map { it.key }.toSet()
        assertTrue(foldedEntryTextSections(named, openDefaults).isEmpty())
    }

    @Test fun plainNestedHeadingCompanionUsesExplicitMetadataWithoutDuplicatingItsLabel() {
        val heading = Block("heading", 1, listOf(Span("text", "Plain nested heading")), listPath = ":", level = 4)
        val body = Block("paragraph", 0, listOf(Span("text", "Following body")))
        val section = Section(4, "Plain nested heading", listOf(heading, body))
        assertSame(heading, sectionHeadingCompanion(section))
        val rows = readingRows(listOf(section))
        assertSame(heading, rows.first().headingBlock)
        assertEquals(listOf(body), rows.mapNotNull { it.block })
        assertEquals(7, blockIndentDp(rows.first().headingBlock!!))
        assertTrue(visibleReadingRows(rows, setOf(rows.first().key)).mapNotNull { it.block }.isEmpty())
        for (notCompanion in listOf(heading.copy(depth = 0), heading.copy(listPath = ""),
            heading.copy(level = 3), heading.copy(kind = "paragraph"),
            heading.copy(spans = listOf(Span("text", "Different label"))))) {
            assertNull(sectionHeadingCompanion(section.copy(blocks = listOf(notCompanion, body))))
        }
    }

    @Test fun templlarRichHeadingsRetainCompanionDepthWithoutDuplicatingTextOrIndentingFollowingBody() {
        for ((dialect, target) in listOf("benasquesa" to "templlar/conj.BEN", "ribagorzana" to "templlar/conj.RIB")) {
            val spans = listOf(Span("text", "Se beiga ", italic = true),
                Span("link", "la conchugazión $dialect", target = target, bold = true, italic = true),
                Span("text", " d'este berbo.", italic = true))
            val label = spans.joinToString("") { it.text }
            val heading = Block("heading", 1, spans, listPath = ":", level = 4)
            val body = Block("paragraph", 0, listOf(Span("text", "Following body")))
            val rows = readingRows(listOf(Section(4, label, listOf(heading, body))))
            assertSame(heading, rows.first().headingBlock)
            assertEquals(listOf(body), rows.mapNotNull { it.block })
            assertEquals(listOf(body), visibleReadingRows(rows, emptySet()).mapNotNull { it.block })
            assertTrue(visibleReadingRows(rows, setOf(rows.first().key)).mapNotNull { it.block }.isEmpty())
            assertEquals(7, blockIndentDp(heading))
            assertEquals(0, blockIndentDp(heading.copy(depth = 0, listPath = "")))
            assertEquals(0, blockIndentDp(body))
            assertEquals("", blockPrefix(heading))
            assertEquals(spans, rows.first().headingBlock!!.spans)
            val ordinary = readingRows(listOf(Section(3, "Conchugazión", listOf(heading, body))))
            assertNull(ordinary.first().headingBlock)
            assertEquals(listOf(heading, body), ordinary.mapNotNull { it.block })
        }
        // Existing non-heading nesting must not change with the heading repair.
        assertEquals(listOf(0, 14, 7, 7, 7, 14, 7, 14), listOf(
            Block("list_item", 1, emptyList()), Block("list_item", 3, emptyList()),
            Block("definition", 2, emptyList()), Block("example", 2, emptyList()),
            Block("quotation", 2, emptyList()), Block("list_detail", 3, emptyList()),
            Block("term", 2, emptyList()), Block("indent", 3, emptyList())).map(::blockIndentDp))
    }


    @Test fun richHeadingCompanionRequiresExactFirstLevelLabelAndActionableSpans() {
        val linked = Block("heading", 0, listOf(
            Span("text", "\u00a0 \t"), Span("link", "Usage", target = "usage", trail = " notes", bold = true),
            Span("line_break", "ignored"), Span("text", "\r ")), level = 3)
        fun section(block: Block = linked, title: String = "Usage notes") = Section(3, title, listOf(block))
        assertSame(linked, sectionHeadingCompanion(section()))
        val nestedDepth = linked.copy(depth = 5)
        assertSame(nestedDepth, sectionHeadingCompanion(section(nestedDepth)))
        val external = linked.copy(spans = listOf(Span("external_link", "Usage notes", target = "https://example.org/notes")))
        assertSame(external, sectionHeadingCompanion(section(external)))
        val trail = linked.copy(spans = listOf(Span("link", "", target = "notes", trail = "Usage notes")))
        assertSame(trail, sectionHeadingCompanion(section(trail)))
        val unicode = linked.copy(spans = listOf(Span("link", "\u2003Usage notes", target = "notes")))
        assertNull(sectionHeadingCompanion(section(unicode)))
        assertSame(unicode, sectionHeadingCompanion(section(unicode, "\u2003Usage notes")))
        for (invalid in listOf(
            linked.copy(kind = "paragraph"), linked.copy(level = 2), linked.copy(depth = 3, level = 0),
            linked.copy(spans = listOf(Span("link", "usage notes", target = "notes"))),
            linked.copy(spans = listOf(Span("link", "Usage notes", target = ""))),
            linked.copy(spans = listOf(Span("text", "Usage notes", target = "notes"))),
            linked.copy(spans = listOf(Span("link", "Usage notes", target = "notes"),
                Span("line_break", "\n", trail = "extra"))),
        )) {
            val value = section(invalid)
            assertNull(sectionHeadingCompanion(value))
            assertEquals(1, readingRows(listOf(value)).count { it.block != null })
        }
        val later = Section(3, "Usage notes", listOf(Block("paragraph", 0, listOf(Span("text", "Before"))), linked))
        assertNull(sectionHeadingCompanion(later))
        assertEquals(2, readingRows(listOf(later)).count { it.block != null })
        val blankBody = Block("paragraph", 0, listOf(Span("text", "Visible "), Span("link", "body", target = "retained-body")))
        val blank = Section(3, " \t", listOf(
            linked.copy(spans = listOf(Span("link", " \t", target = "notes"))), blankBody))
        assertNull(sectionHeadingCompanion(blank))
        assertEquals(listOf(blankBody), visibleReadingRows(readingRows(listOf(blank)), setOf("heading-0")).mapNotNull { it.block })
    }

    @Test fun selfHeadingCompanionRetainsProducerStylingWithoutAddingAnAction() {
        val self = Span("text", "Usage notes", classes = "mw-selflink selflink", bold = true, italic = true)
        val companion = Block("heading", 0, listOf(self), level = 3)
        val body = Block("paragraph", 0, listOf(Span("text", "Visible body")))
        fun section(block: Block = companion, title: String = "Usage notes") = Section(3, title, listOf(block, body))
        val plain = Span("text", "Usage notes")
        val attributed = listOf(
            plain.copy(bold = true), plain.copy(italic = true), plain.copy(code = true),
            plain.copy(small = true), plain.copy(superscript = true), plain.copy(subscript = true),
            plain.copy(strike = true), plain.copy(underline = true),
            plain.copy(foreground = "#123456"), plain.copy(background = "#ffffe0"), plain.copy(classes = "note"),
            plain.copy(language = "de"), plain.copy(direction = "rtl"), plain.copy(role = "label"),
        )
        for (span in listOf(self, self.copy(bold = false, italic = false),
            self.copy(classes = "note\tmw-selflink\nselflink extra"),
            self.copy(classes = ""), self.copy(classes = "mw-selflink"), self.copy(classes = "selflink"),
            self.copy(classes = "not-mw-selflink selflink"), self.copy(classes = "mw-selflink selflink-suffix")) + attributed) {
            val heading = companion.copy(spans = listOf(span))
            val rows = readingRows(listOf(section(heading)))
            assertSame(heading, sectionHeadingCompanion(section(heading)))
            assertSame(heading, rows.first().headingBlock)
            assertEquals(listOf("heading-0", "block-0-1"), rows.map { it.key })
            assertEquals(listOf(body), rows.mapNotNull { it.block })
            assertEquals(listOf(body), visibleReadingRows(rows, emptySet()).mapNotNull { it.block })
            assertTrue(visibleReadingRows(rows, setOf("heading-0")).mapNotNull { it.block }.isEmpty())
            assertEquals("text", rows.first().headingBlock!!.spans.single().kind)
            assertEquals("", rows.first().headingBlock!!.spans.single().target)
            assertEquals(span, rows.first().headingBlock!!.spans.single())
        }
        val styled = companion.copy(spans = listOf(attributed.first()))
        val definition = Block("definition", 1, listOf(Span("text", "A dictionary meaning")))
        val meaningRows = readingRows(listOf(section(styled).copy(blocks = listOf(styled, definition, body))))
        assertTrue(meaningRows.first().meaningSection)
        assertSame(styled, meaningRows.first().headingBlock)
        assertEquals(listOf(definition, body), meaningRows.mapNotNull { it.block })
        assertEquals(listOf(definition), visibleReadingRows(meaningRows, setOf("heading-0-details")).mapNotNull { it.block })
        for (span in listOf(plain, self.copy(target = "notes"),
            self.copy(kind = "link"), self.copy(text = "", trail = "Usage notes"))) {
            val heading = companion.copy(spans = listOf(span))
            assertNull(sectionHeadingCompanion(section(heading)))
            assertEquals(listOf(heading, body), readingRows(listOf(section(heading))).mapNotNull { it.block })
        }
        assertNull(sectionHeadingCompanion(section(companion.copy(level = 2))))
        assertNull(sectionHeadingCompanion(section(title = "usage notes")))
        assertNull(sectionHeadingCompanion(section(companion.copy(spans = listOf(self,
            Span("line_break", "\n", trail = "extra"))))))
        val entry = Entry("Fixture", emptyList(), "language", "English", "en", listOf(section()), emptyList())
        assertEquals("heading-0", headingScrollKey(entry, "#Usage_notes"))
    }

    @Test fun richHeadingKeepsStableSectionKeysFoldsAndFragmentDestinations() {
        val heading = Block("heading", 0, listOf(Span("link", "Etymology 1", target = "origin")), level = 3)
        val body = Block("paragraph", 0, listOf(Span("text", "Origin body")))
        val definition = Block("definition", 1, listOf(Span("text", "Following meaning")))
        val nested = Block("heading", 0, listOf(Span("link", "Nested", target = "nested")), level = 5)
        val sections = listOf(
            Section(3, "Etymology 1", listOf(heading, body)),
            Section(4, "Noun", listOf(definition, nested)),
        )
        val rows = readingRows(sections)
        assertEquals(listOf("heading-0", "block-0-1", "heading-1", "block-1-0", "block-1-1"), rows.map { it.key })
        assertSame(heading, rows.first().headingBlock)
        assertEquals(listOf(body, definition, nested), rows.mapNotNull { it.block })
        assertTrue(initiallyFolded(rows.first(), AppSettings()))
        val folded = setOf("heading-0", "heading-1-details")
        assertEquals(listOf(definition), visibleReadingRows(rows, folded).mapNotNull { it.block })
        assertEquals(listOf(body, definition), visibleReadingRows(rows, folded - "heading-0").mapNotNull { it.block })
        val entry = Entry("Rich fixture", emptyList(), "language", "English", "en", sections,
            listOf(Reference(1, 1, "", listOf(Span("text", "Reference")))))
        assertEquals("heading-0", headingScrollKey(entry, "#Etymology_1"))
        assertEquals("heading-1", headingScrollKey(entry, "#Noun"))
        assertEquals(5, referenceScrollIndex(entry, "#reference-1", folded))
        val owner = Section(2, "English", listOf(heading.copy(level = 2,
            spans = listOf(Span("link", "English", target = "language"))), definition))
        assertEquals("English", readingRows(listOf(owner)).first().headingBlock!!.spans.single().text)
    }

    @Test fun anchoredOwnerHeadingKeepsItsLabelContentsAndDestinationAfterSharedPrefix() {
        // Model the retained mnw ost prefix/authored-L2 shape. The anchor is an
        // explicit test identity, not a claim about an observed serialized record.
        val language = "သွဳဒေန်"
        val prefix = Block("paragraph", 0, listOf(Span("text", "ဗဵုရံၚ်ဝေါဟာ:", italic = true),
            Span("text", " "), Span("link", "Ost", target = "Ost", bold = true)))
        val body = Block("paragraph", 0, listOf(Span("text", "Authored owner body")))
        val sections = listOf(Section(2, language, listOf(prefix)),
            Section(2, language, listOf(body), anchor = "authored-owner"))
        val entry = Entry("ost", emptyList(), "language", language, "sv", sections, emptyList())
        val rows = entry.readingRows
        val headings = rows.filter { it.heading != null }
        assertEquals(listOf("Overview", language), headings.map {
            sectionHeadingLabel(it.heading!!, entry.language, it.headingBlock)
        })
        assertEquals(listOf("heading-1"), headings.filter { sectionInContents(it.heading!!, entry.language) }.map { it.key })
        assertEquals(listOf("heading-0", "block-0-0", "heading-1", "block-1-0"), rows.map { it.key })
        assertEquals("heading-1", headingScrollKey(entry, "#authored-owner"))
        assertNull(headingScrollKey(entry, "#$language")) // Duplicate titles do not invent a fragment destination.
        assertEquals(listOf(body), visibleReadingRows(rows, setOf("heading-0")).mapNotNull { it.block })
        assertEquals(listOf(prefix), visibleReadingRows(rows, setOf("heading-1")).mapNotNull { it.block })
        assertEquals(listOf(prefix, body), visibleReadingRows(rows, emptySet()).mapNotNull { it.block })
        assertEquals(sections, entry.sections)
        assertEquals(listOf(prefix.spans, body.spans), rows.mapNotNull { it.block?.spans })
    }

    @Test fun ownerHeadingPresentationKeepsEmptyAnchorFallbackRichSpansAndExplicitEmptyHeadings() {
        val language = "English"
        val plain = Section(2, language, emptyList())
        assertEquals("Overview", sectionHeadingLabel(plain, language, null))
        assertFalse(sectionInContents(plain, language))
        assertFalse(sectionHeadingVisible(plain, language))
        assertFalse(sectionHeadingVisible(plain.copy(blocks = listOf(Block("blank", 0, emptyList()))), language))
        val legacy = Entry("Legacy", emptyList(), "language", language, "en", listOf(plain), emptyList())
        assertEquals("heading-0", headingScrollKey(legacy, "#English"))
        for (anchored in listOf(plain.copy(anchor = "English"), plain.copy(anchorFallback = "English"))) {
            assertEquals(language, sectionHeadingLabel(anchored, language, null))
            assertTrue(sectionInContents(anchored, language))
            assertTrue(sectionHeadingVisible(anchored, language))
            assertEquals("heading-0", headingScrollKey(legacy.copy(sections = listOf(anchored)), "#English"))
        }
        val span = Span("link", language, target = "language", italic = true, explanation = "Authored title")
        val rich = Block("heading", 0, listOf(span), level = 2)
        val section = plain.copy(blocks = listOf(rich))
        val row = readingRows(listOf(section)).single()
        assertSame(rich, row.headingBlock)
        assertEquals(listOf(span), row.headingBlock!!.spans)
        assertEquals(language, sectionHeadingLabel(section, language, row.headingBlock))
        assertFalse(sectionInContents(section, language)) // Keep the legacy empty-anchor menu policy.
        assertTrue(sectionHeadingVisible(section, language))
        val ordinary = plain.copy(title = "Usage notes")
        assertEquals("Usage notes", sectionHeadingLabel(ordinary, language, null))
        assertTrue(sectionInContents(ordinary, language))
        assertTrue(sectionHeadingVisible(ordinary, language))
        assertEquals(language, sectionHeadingLabel(plain, null, null))
        assertTrue(sectionInContents(plain, null))
        assertFalse(sectionInContents(plain.copy(title = "", anchor = "empty"), language))
        assertFalse(sectionHeadingVisible(plain.copy(title = "", anchor = "empty"), language))
    }

    @Test fun denseListsAreLazyWithoutLosingTextOrLinkSemantics() {
        val spans = (0 until 330).flatMap { index -> listOf(Span("text", "• "), Span("link", "word $index", target = "word $index", italic = true), Span("line_break", "\n")) }
        val rows = readingRows(listOf(Section(3, "Derived terms", listOf(Block("paragraph", 0, spans)))))
        val blocks = rows.mapNotNull { it.block }
        assertEquals(330, blocks.size)
        assertEquals(rows.size, rows.map { it.key }.toSet().size)
        assertTrue(blocks.all { it.spans.size == 2 })
        assertEquals(spans.filter { it.kind != "line_break" }, blocks.flatMap { it.spans })
        val painted = Span("text", " \u00a0 ", background = "#ffffe0")
        val breakWithTrail = Span("line_break", "\n", trail = "  ", background = "#ffffe0")
        val paintedSpans = List(40) { listOf(painted, breakWithTrail) }.flatten() + painted
        val paintedRows = readingRows(listOf(Section(3, "Notes", listOf(Block("paragraph", 0, paintedSpans)))))
            .mapNotNull { it.block }
        assertEquals(41, paintedRows.size)
        assertEquals(listOf(painted), paintedRows.first().spans)
        paintedRows.drop(1).forEach { row ->
            assertEquals(listOf(Span("text", "  ", background = "#ffffe0"), painted), row.spans)
        }
    }

    @Test fun explicitMediaOwnersKeepActionsAndRejectUnknownOrAmbiguousTokens() {
        val tone = Media("Tone.ogg", "audio", "same")
        val other = Media("Other.ogg", "audio", "same")
        val unicode = Media("Écho 🔊.ogg", "audio", "same")
        val owners = MediaOwners(listOf(tone, other, unicode))
        val toneToken = "wikidict-media-file-546f6e652e6f6767"
        val otherToken = "wikidict-media-file-4f746865722e6f6767"
        val unicodeToken = "wikidict-media-file-c38963686f20f09f948a2e6f6767"
        val lexical = Span("link", "same", target = "cat", classes = "note\twikidict-media $toneToken", bold = true)
        val external = lexical.copy(kind = "external_link", target = "https://example.org", classes = "wikidict-media $otherToken")
        val before = listOf(lexical, external)
        assertEquals(listOf(tone, other), owners.embedded(before))
        assertEquals("cat", lexical.target)
        assertEquals("https://example.org", external.target)
        assertEquals(before, listOf(lexical, external))
        assertEquals(unicode.file, owners.file(lexical.copy(classes = "wikidict-media $unicodeToken")))
        // Even a usable legacy target cannot override a present invalid owner.
        for (marker in listOf(
            "wikidict-media-file-", "wikidict-media-file-0", "wikidict-media-file-ff",
            "wikidict-media-file-546F6E652E6F6767", "wikidict-media-file-556e6b6e6f776e2e6f6767",
            "$toneToken $toneToken", "$toneToken $otherToken"
        )) assertNull(marker, owners.file(lexical.copy(target = "File:Tone.ogg", classes = "wikidict-media $marker")))
        assertNull(owners.file(lexical.copy(classes = "not-wikidict-media $toneToken")))
        assertEquals(tone.file, owners.file(lexical.copy(target = "File:Tone.ogg", classes = "wikidict-media")))
        assertEquals("Missing file.ogg", owners.file(lexical.copy(target = "File:Missing_file.ogg", classes = "wikidict-media")))
        assertTrue(owners.embedded(listOf(lexical.copy(target = "File:Missing_file.ogg", classes = "wikidict-media"))).isEmpty())
    }

    @Test fun mediaOwnerCatalogsStayIndependentAndKeepLastDuplicate() {
        val older = Media("Tone.ogg", "audio", "Old caption")
        val outerTone = Media("Tone.ogg", "audio", "Outer caption")
        val innerTone = Media("Tone.ogg", "audio", "Inner caption")
        val outerOnly = Media("Other.ogg", "audio", "Outer only")
        val innerOnly = Media("Inner.ogg", "audio", "Inner only")
        val outerCatalog = listOf(older, outerOnly, outerTone)
        val innerCatalog = listOf(innerTone, innerOnly)
        val outerOwners = MediaOwners(outerCatalog)
        val innerOwners = MediaOwners(innerCatalog)
        val tone = Span("link", "Shared label", target = "Lexical target", classes =
            "wikidict-media wikidict-media-file-546f6e652e6f6767")
        val other = tone.copy(classes = "wikidict-media wikidict-media-file-4f746865722e6f6767")
        val inner = tone.copy(classes = "wikidict-media wikidict-media-file-496e6e65722e6f6767")
        val spans = listOf(tone, other, tone, inner)

        // Switching catalogs (or returning from a nested reader) cannot reuse
        // the same filename's metadata from the previous owner.
        for (owners in listOf(outerOwners, innerOwners, outerOwners)) {
            val expected = if (owners === outerOwners) listOf(outerTone, outerOnly) else listOf(innerTone, innerOnly)
            val embedded = owners.embedded(spans)
            assertEquals(expected, embedded)
            assertSame(expected.first(), embedded.first())
            assertEquals("Lexical target", tone.target)
        }
        assertTrue(MediaOwners(emptyList()).embedded(spans).isEmpty())
        // A marker absent from this catalog must not fall back to a usable
        // legacy File action, nor borrow another live catalog's known token.
        assertNull(innerOwners.file(other.copy(target = "File:Tone.ogg")))
        assertNull(outerOwners.file(inner.copy(target = "File:Tone.ogg")))
        assertNull(outerOwners.file(tone.copy(classes = tone.classes + " wikidict-media-file-4f746865722e6f6767")))
        assertEquals(listOf(older, outerOnly, outerTone), outerCatalog)
        assertEquals(listOf(innerTone, innerOnly), innerCatalog)
        assertEquals(listOf(tone, other, tone, inner), spans)
    }

    @Test fun denseAuthoredMediaCaptionKeepsOneRowWithoutAFileNavigationTarget() {
        val media = Media("Tone.ogg", "audio", "a".repeat(40) + "\n" + "b".repeat(40))
        val classes = "wikidict-media wikidict-media-file-546f6e652e6f6767"
        val first = List(40) { Span("link", "a", target = "cat", classes = classes) }
        val second = List(40) { Span("external_link", "b", target = "https://example.org", classes = classes) }
        val spans = first + Span("line_break", "\n", classes = classes) + second
        val block = Block("paragraph", 0, spans)
        val entry = Entry("Caption", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(block))), emptyList(), media = listOf(media))
        assertEquals(81, spans.size)
        assertEquals(2, entry.readingRows.size)
        assertSame(block, entry.readingRows.last().block)
        assertEquals(spans, entry.readingRows.last().block!!.spans)
        assertEquals(listOf(media), MediaOwners(entry.media).embedded(spans))
        // A token for an unavailable file is not proof of ownership.
        assertEquals(3, readingRows(entry.sections).size)
    }

    @Test fun denseMediaCaptionKeepsOneRowAndAllCompiledSpans() {
        val owner = "File:Tone.ogg"
        val mediaClass = "caption wikidict-media"
        fun line(text: String) = text.mapIndexed { index, character ->
            Span("link", character.toString(), target = owner, classes = mediaClass, bold = index % 2 == 0)
        }
        val first = "First caption line " + "a".repeat(21)
        val second = "Second caption line " + "b".repeat(20)
        val caption = line(first) + Span("line_break", "\n", target = owner, classes = mediaClass) + line(second)
        assertEquals(81, caption.size)
        val block = Block("paragraph", 0, caption)
        val rows = readingRows(listOf(Section(3, "Pronunciation", listOf(block))))
        assertEquals(2, rows.size) // Heading plus the one original media container.
        assertSame(block, rows.last().block)
        assertEquals(caption, rows.last().block!!.spans)
        assertEquals("$first\n$second", caption.joinToString("") { it.text })
        // A substring class or an ordinary word target does not own inline media.
        for (unowned in listOf(
            caption.map { it.copy(classes = "wikidict-media-extra") },
            caption.map { it.copy(target = "Tone") },
        )) {
            val split = readingRows(listOf(Section(3, "Notes", listOf(block.copy(spans = unowned)))))
                .mapNotNull { it.block }
            assertEquals(2, split.size)
            assertEquals(unowned.filter { it.kind != "line_break" }, split.flatMap { it.spans })
        }
    }

    @Test fun preformattedAndShortStyledParagraphsKeepExplicitBreaks() {
        val spans = listOf(Span("text", "first"), Span("line_break", "\n"), Span("text", "second", bold = true))
        val pre = Block("preformatted", 0, List(40) { spans }.flatten())
        val paragraph = Block("paragraph", 0, spans)
        val rows = readingRows(listOf(Section(3, "Noun", listOf(pre, paragraph))))
        assertSame(pre, rows[1].block)
        assertSame(paragraph, rows[2].block)
    }

    @org.junit.Test fun foldingEtymologyKeepsNestedDefinitionsVisible() {
        val sections=listOf(Section(3,"Etymology 1",listOf(Block("paragraph",0,listOf(Span("text","Origin"))))),Section(4,"Noun",listOf(Block("definition",1,listOf(Span("text","Meaning"))))))
        val visible=visibleReadingRows(readingRows(sections),setOf("heading-0"))
        org.junit.Assert.assertFalse(visible.any{it.block?.spans?.any{span->span.text=="Origin"}==true})
        org.junit.Assert.assertTrue(visible.any{it.block?.spans?.any{span->span.text=="Meaning"}==true})
    }

    @Test fun defaultsShowDefinitionsAndFoldSupportingSections() {
        val meaning = Block("definition", 1, listOf(Span("text", "A meaning")))
        val note = Block("quotation", 1, listOf(Span("text", "A quotation")))
        val rows = readingRows(listOf(
            Section(3, "Alternative forms", listOf(note)),
            Section(3, "Etymology 1", listOf(note)),
            Section(4, "Adjective", listOf(note, meaning, note)),
            Section(5, "Derived terms", listOf(note))
        ))
        val folded = rows.filter { initiallyFolded(it, AppSettings()) }.map { it.key }.toSet() + "heading-2-details"
        val visible = visibleReadingRows(rows, folded)
        assertEquals(listOf(meaning), visible.mapNotNull { it.block })
        assertEquals(3, visibleReadingRows(rows, folded - "heading-2-details").count { it.block != null })
        assertFalse(initiallyFolded(rows.first(), AppSettings(collapseOtherSections = false)))
    }


    @Test fun blankHeadingsKeepBodiesAndDetailsVisibleUnderDefaultsAndRetainedFolds() {
        for (title in listOf("", " \t\n")) {
            val prose = Block("paragraph", 0, listOf(Span("link", "Read prose", target = "prose")))
            val item = Block("list_item", 1, listOf(Span("text", "List content")), listPath = "*")
            val table = Block("table", 0, emptyList(), table = Table(emptyList(),
                listOf(listOf(Cell(listOf(Span("link", "Cell content", target = "cell")), false, 1, 1)))))
            val meaning = Block("definition", 1, listOf(Span("text", "Meaning")))
            val note = Block("quotation", 1, listOf(Span("text", "Supporting detail")))
            val named = Block("paragraph", 0, listOf(Span("text", "Named section body")))
            val rows = readingRows(listOf(
                Section(3, "Before", listOf(named)),
                Section(3, title, listOf(prose, item, table)),
                Section(3, title, listOf(meaning, note)),
                Section(3, "After", listOf(named)),
                Section(3, "Noun", listOf(meaning, note))
            ))
            val defaults = rows.filter { initiallyFolded(it, AppSettings()) }.map { it.key }.toSet() +
                setOf("heading-2-details", "heading-4-details")
            assertFalse(initiallyFolded(rows.single { it.key == "heading-1" }, AppSettings()))
            assertFalse(initiallyFolded(rows.single { it.key == "heading-2" }, AppSettings()))
            val expected = listOf(prose, item, table, meaning, note, meaning)
            assertEquals(expected, visibleReadingRows(rows, defaults).mapNotNull { it.block })
            // Retained fold indices must not hide bodies with no visible way to reopen them.
            val retained = defaults + setOf("heading-1", "heading-1-details", "heading-2")
            val visible = visibleReadingRows(rows, retained)
            assertEquals(expected, visible.mapNotNull { it.block })
            assertEquals(rows.filter { it.heading != null }, visible.filter { it.heading != null })
            // Ordinary named section and detail toggles still work.
            assertEquals(listOf(named) + expected,
                visibleReadingRows(rows, retained - "heading-0").mapNotNull { it.block })
            assertEquals(expected + note,
                visibleReadingRows(rows, retained - "heading-4-details").mapNotNull { it.block })
        }
    }

    @Test fun semanticSpacingDropsEmptyRowsAndRepeatedBreaksButKeepsLiteralSpacing() {
        val br = Span("line_break", "\n")
        val spans = listOf(br, br, Span("text", "one"), br, br, Span("text", " "), br, Span("text", "two"), br, br)
        val rows = readingRows(listOf(Section(3, "Noun", listOf(
            Block("definition", 1, spans), Block("paragraph", 0, listOf(br, br)), Block("preformatted", 0, spans)
        ))))
        assertEquals(3, rows.size)
        assertEquals(listOf(Span("text", "one"), br, Span("text", "two")), rows[1].block!!.spans)
        assertEquals(spans, rows[2].block!!.spans)
        val painted = Span("text", " \u00a0 ", trail = "  ", background = "#ffffe0")
        assertEquals(listOf(painted, br, painted, br, painted), compactSpans(listOf(painted, br, br, painted, br, painted)))
        assertTrue(compactSpans(listOf(Span("text", "", background = "#ffffe0"), br.copy(background = "#ffffe0"))).isEmpty())
    }
    @Test fun numberedListItemsDisplayCompiledLabelsWithoutBecomingSenses() {
        fun item(number: String, path: String = "#", depth: Int = 1) =
            Block("list_item", depth, listOf(Span("text", "An instruction")), listPath = path, number = number)
        for (number in listOf("3", "8", "9", "-2", "AA", "iii", "xxvi")) assertEquals("$number. ", blockPrefix(item(number)))
        assertEquals("• ", blockPrefix(item("", "#*", 2)))
        assertEquals("3.1. ", blockPrefix(item("3.1", "#*#", 3)))
        assertEquals("↳ ", blockPrefix(Block("list_detail", 1, emptyList(), listPath = "#:")))
        val meaning = Block("definition", 1, listOf(Span("text", "Actual dictionary meaning")), number = "1")
        assertEquals("01", blockPrefix(meaning))
        val sections = listOf(Section(3, "Instructions", listOf(item("3"))), Section(3, "Meaning", listOf(meaning)))
        val rows = readingRows(sections)
        assertFalse(rows.first { it.block?.kind == "list_item" }.meaningSection)
        assertTrue(rows.first { it.block?.kind == "definition" }.meaningSection)
        val entry = Entry("word", emptyList(), "language", "Language", "und", sections, emptyList())
        assertEquals("Actual dictionary meaning", entry.clue())
    }

    @Test fun sameEntryFragmentsMatchCompiledHeadingsWithoutChangingWordLinks() {
        val entry = Entry("cat", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", emptyList()),
            Section(3, "Usage notes", listOf(Block("paragraph", 0, listOf(Span("text", "Usage body"))))),
            Section(4, "日本語", emptyList())
        ), emptyList())
        assertEquals("heading-1", headingScrollKey(entry, "#Usage_notes"))
        assertEquals("heading-1", headingScrollKey(entry, "#Usage notes"))
        assertEquals("heading-2", headingScrollKey(entry, "#日本語"))
        listOf("cat", "cat#Usage_notes", "#", "#Missing", "#usage_notes").forEach {
            assertNull(headingScrollKey(entry, it))
        }
    }

    @Test fun qichwaReferencesPlaceholderUsesOneFooterWithStableFoldedReferenceOffsets() {
        // The emitted qichwa shape has an empty References leaf before Further reading,
        // with its two citations carried separately in entry metadata.
        val example = Block("example", 1, listOf(
            Span("text", "Ñuqanchik qhichwa simita rimachkanchik.", italic = true),
            Span("line_break", ""), Span("text", "We are speaking Quechua (language).")))
        val entry = Entry("qichwa", emptyList(), "language", "Quechua", "qu", listOf(
            Section(2, "Quechua", emptyList()),
            Section(3, "Alternative forms", emptyList()),
            Section(3, "Etymology", emptyList()),
            Section(3, "Pronunciation", emptyList()),
            Section(3, "Noun", listOf(Block("definition", 1, listOf(Span("text", "Quechua"))), example)),
            Section(4, "Declension", emptyList()),
            Section(4, "See also", emptyList()),
            Section(3, "References", emptyList(), anchor = "References"),
            Section(3, "Further reading", List(5) { Block("list_item", 1, listOf(Span("text", "Bibliography $it"))) })
        ), listOf(Reference(1, 1, "", listOf(Span("text", "First citation"))),
            Reference(2, 2, "", listOf(Span("text", "Second citation")))),
            preamble = listOf(Span("text", "Entry preamble")))
        assertEquals("heading-7", metadataReferenceHeadingKey(entry))
        assertEquals("heading-7", headingDestination(entry, "#References")!!.rowKey)
        assertTrue(headingDestination(entry, "#References")!!.compiledId)
        assertEquals(listOf(example), visibleEntryReadingRows(entry, emptySet()).mapNotNull { it.block }.filter { it.kind == "example" })
        assertEquals(15, visibleEntryReadingRows(entry, emptySet()).size)
        assertFalse(visibleEntryReadingRows(entry, emptySet()).any { it.key == "heading-7" })
        assertEquals(17, metadataReferencesStartIndex(entry, emptySet()))
        assertEquals(18, referenceScrollIndex(entry, "#reference-1", emptySet()))
        assertEquals(19, referenceScrollIndex(entry, "#reference-2", emptySet()))
        val folded = setOf("heading-4", "heading-8", "references", "preamble")
        assertEquals(10, metadataReferencesStartIndex(entry, folded))
        assertEquals(11, referenceScrollIndex(entry, "#reference-1", folded))
        assertEquals(12, referenceScrollIndex(entry, "#reference-2", folded))
        assertEquals(11, referenceScrollIndex(entry.copy(preamble = emptyList()), "#reference-2", folded))
        assertNull(referenceScrollIndex(entry, "#reference-3", folded))
    }

    @Test fun referencesSuppressionPreservesAuthoredBodiesParentsAmbiguityAndCompiledIds() {
        val placeholder = Section(3, "References", emptyList(), anchor = "References")
        val following = Section(3, "Further reading", emptyList())
        val body = Block("paragraph", 0, listOf(Span("text", "Authored reference prose")))
        val base = Entry("word", emptyList(), "language", "English", "en", listOf(placeholder, following),
            listOf(Reference(1, 1, "", listOf(Span("text", "Metadata citation")))))
        val controls = listOf(
            base.copy(references = emptyList()),
            base.copy(sections = listOf(placeholder.copy(blocks = listOf(body)), following)),
            base.copy(sections = listOf(placeholder, Section(4, "Child references", listOf(body)), following)),
            base.copy(sections = listOf(following)),
            base.copy(sections = listOf(placeholder, following, placeholder.copy(anchor = "References_2"))),
            base.copy(sections = listOf(placeholder.copy(title = "Sources"), following)))
        for (entry in controls) {
            assertNull(metadataReferenceHeadingKey(entry))
            assertEquals(visibleReadingRows(entry.readingRows, emptySet()), visibleEntryReadingRows(entry, emptySet()))
        }
        // A real authored ID still wins the page namespace over a generated citation ID.
        val collision = base.copy(sections = listOf(placeholder, following,
            Section(3, "Authored citation heading", listOf(body), anchor = "reference-1")))
        val destination = headingDestination(collision, "#reference-1")!!
        assertTrue(destination.compiledId)
        assertEquals("heading-2", destination.rowKey)
        assertTrue(visibleEntryReadingRows(collision, emptySet()).any { it.key == destination.rowKey })
        assertEquals("heading-0", metadataReferenceHeadingKey(collision))
    }

    @Test fun compiledReferenceTargetsUseGlobalIdentityAndGroupedDisplayLabels() {
        val references = listOf(
            Reference(1, 1, "notes", listOf(Span("text", "Grouped note"))),
            Reference(2, 1, "", listOf(Span("text", "Default note"))),
            Reference(3, 2, "notes", listOf(Span("text", "Second grouped note")))
        )
        val entry = Entry("reference fixture", emptyList(), "language", "English", "en", listOf(
            Section(3, "Usage notes", listOf(Block("paragraph", 0, listOf(Span("text", "Body")))))
        ), references, listOf(Span("text", "Preamble")), emptyList())
        assertEquals(listOf("[notes 1]", "[1]", "[notes 2]"), references.map(::referenceLabel))
        val folded = setOf("heading-0", "references")
        // Title, preamble, folded section heading, references heading, then reference rows.
        assertEquals(4, referenceScrollIndex(entry, "#reference-1", folded))
        assertEquals(5, referenceScrollIndex(entry, "#reference-2", folded))
        assertEquals(6, referenceScrollIndex(entry, "#reference-3", folded))
        assertEquals(7, referenceScrollIndex(entry, "#reference-3", emptySet()))
        assertEquals(5, referenceScrollIndex(entry.copy(preamble = emptyList()), "#reference-3", folded))
        listOf("word", "word#reference-1", "#reference-01", "#reference-4", "#cite_note-1").forEach {
            assertNull(referenceScrollIndex(entry, it, folded))
        }
    }

    @Test fun spanLanguageTagsPreserveExplicitScriptRegionAndExtensions() {
        for ((raw, expected) in listOf(
            "ja" to "ja", "EN-us" to "en-US", "zh-Hant-TW" to "zh-Hant-TW",
            "sr-Latn-RS" to "sr-Latn-RS", "de-DE-x-goethe" to "de-DE-x-goethe",
            "en-US-u-nu-latn" to "en-US-u-nu-latn",
            "und" to "und", "und-Latn" to "und-Latn", "x-private" to "x-private"
        )) assertEquals(raw, expected, spanLanguageTag(raw))
    }

    @Test fun absentOrMalformedLanguageTagsAreIgnored() {
        for (raw in listOf("", " ", "en_US", "en--US", "en,fr", "1en", "en-US-", " en", "en ")) {
            assertNull(raw, spanLanguageTag(raw))
        }
    }


    @Test fun markedPoemSpacingSurvivesCompactionDenseRowsAndTables() {
        val br = Span("line_break", "", classes = "wikidict-poem")
        val spaces = Span("text", " \u00a0 ", trail = "  ", classes = "wikidict-poem")
        val verse = Span("link", "Verse", target = "verse#Noun", trail = " ", classes = "wikidict-poem")
        val spans = listOf(br, br, spaces, verse, br, br, spaces, br)
        assertSame(spans, compactSpans(spans))
        val dense = List(45) { listOf(verse, br) }.flatten() + listOf(br, spaces, br)
        val table = Table(dense, listOf(listOf(Cell(dense, false, 1, 1))))
        val rows = readingRows(listOf(Section(3, "Poem", listOf(
            Block("paragraph", 0, dense), Block("table", 0, emptyList(), table = table)))))
        assertEquals(3, rows.size)
        assertEquals(dense, rows[1].block!!.spans)
        assertEquals(dense, rows[2].block!!.table!!.caption)
        assertEquals(dense, rows[2].block!!.table!!.rows.single().single().spans)
        val ordinaryBreak = Span("line_break", "")
        val boundary = listOf(Span("text", "before"), ordinaryBreak, verse, ordinaryBreak, Span("text", "after"))
        assertEquals(boundary, compactSpans(boundary))
        assertEquals("verse#Noun", rows[1].block!!.spans.first().target)
    }

    @Test fun poemParagraphsUseActualOffsetsRawNewlinesAndLineBoundaries() {
        val rtl = "wikidict-poem mw-poem-indented wikidict-poem-indent-3 wikidict-poem-dir-rtl"
        val ltr = "wikidict-poem mw-poem-indented wikidict-poem-indent-1 wikidict-poem-dir-ltr"
        val parts = listOf(
            Span("link", "alpha", target = "alpha", classes = rtl, direction = "ltr") to "\u2066alpha\u2069",
            Span("line_break", "", classes = rtl) to "\n",
            Span("line_break", "", classes = "wikidict-poem") to "\n",
            Span("text", "אב\n", classes = ltr, direction = "rtl") to "\u2067אב\n\u2069",
            Span("text", "ordinary") to "ordinary")
        val text = StringBuilder()
        val offsets = parts.map { (span, rendered) ->
            val start = text.length
            text.append(rendered)
            span to (start until text.length)
        }
        assertEquals("\u2066alpha\u2069\n\n\u2067אב\n\u2069ordinary", text.toString())
        assertEquals(listOf(
            PoemParagraph(0, 8, 3, "rtl"),
            PoemParagraph(8, 9, 0, null),
            PoemParagraph(9, 13, 1, "ltr")), poemParagraphs(text.toString(), offsets))
        val raw = Span("text", "a\nb", classes = rtl)
        assertEquals(listOf(PoemParagraph(0, 2, 3, "rtl"), PoemParagraph(2, 3, 0, "rtl")),
            poemParagraphs("a\nb", listOf(raw to (0 until 3))))
        val separatelyMarked = Span("text", "b", classes = ltr)
        assertEquals(listOf(PoemParagraph(0, 2, 3, "rtl"), PoemParagraph(2, 3, 1, "ltr")),
            poemParagraphs("a\nb", listOf(raw.copy(text = "a\n") to (0 until 2),
                separatelyMarked to (2 until 3))))
        val trailing = Span("text", "a\n\n", classes = "wikidict-poem")
        assertEquals(listOf(PoemParagraph(0, 2, 0, null), PoemParagraph(2, 3, 0, null)),
            poemParagraphs("a\n\n", listOf(trailing to (0 until 3))))
    }

    @Test fun poemMetadataRejectsMalformedDuplicateAndDisagreeingTokensIndependently() {
        fun line(first: String, second: String = first): PoemParagraph? =
            poemParagraphs("ab", listOf(Span("text", "a", classes = first) to (0 until 1),
                Span("text", "b", classes = second) to (1 until 2))).singleOrNull()
        val marker = "wikidict-poem"
        val depth = "$marker wikidict-poem-indent-3"
        assertEquals(PoemParagraph(0, 2, 3, "rtl"), line("$depth wikidict-poem-dir-rtl"))
        assertEquals(32, line("$marker wikidict-poem-indent-32")!!.indent)
        assertNull(line("wikidict-poem-indent-3 wikidict-poem-dir-rtl"))
        for (bad in listOf("0", "03", "+3", "33", "", "x", "999999999999999999999")) {
            assertEquals(PoemParagraph(0, 2, 0, "rtl"),
                line("$marker wikidict-poem-indent-$bad wikidict-poem-dir-rtl"))
        }
        for (bad in listOf("wikidict-poem-indent", "wikidict-poem-indentjunk")) {
            assertEquals(PoemParagraph(0, 2, 0, "rtl"),
                line("$depth $bad wikidict-poem-dir-rtl"))
        }
        for (bad in listOf("wikidict-poem-dir", "wikidict-poem-dirjunk")) {
            assertEquals(PoemParagraph(0, 2, 3, null),
                line("$depth wikidict-poem-dir-rtl $bad"))
        }
        assertEquals(0, line("$depth wikidict-poem-indent-3")!!.indent)
        assertEquals(0, line("$depth wikidict-poem-indent-2")!!.indent)
        assertEquals(0, line(depth, "$marker wikidict-poem-indent-2")!!.indent)
        assertEquals(0, line(depth, marker)!!.indent)
        for (suffix in listOf("rtl wikidict-poem-dir-rtl", "rtl wikidict-poem-dir-ltr", "auto", "")) {
            assertEquals(PoemParagraph(0, 2, 3, null), line("$depth wikidict-poem-dir-$suffix"))
        }
        assertEquals(PoemParagraph(0, 2, 3, null),
            line("$depth wikidict-poem-dir-rtl", "$depth wikidict-poem-dir-ltr"))
        assertEquals(PoemParagraph(0, 2, 3, null),
            line("$depth wikidict-poem-dir-rtl", depth))
        val mixed = Span("link", "Tone", target = "File:Tone.ogg",
            classes = "wikidict-poem\twikidict-media\nwikidict-poem-indent-3")
        assertTrue(mixed.hasClassToken("wikidict-media"))
        assertFalse(mixed.hasClassToken("media"))
        assertEquals(mixed.copy(classes = "wikidict-poem wikidict-poem-indent-3"),
            mixed.withoutClassToken("wikidict-media"))
    }

    @Test fun nativeEgyptianMappingPreservesExplicitPoemDirectionAndOrdinaryInference() {
        val witness = "𓂜"
        val cases = listOf(
            "Latin" to androidx.compose.ui.text.style.TextDirection.Rtl,
            "אב" to androidx.compose.ui.text.style.TextDirection.Ltr)
        for ((prefix, direction) in cases) {
            val text = prefix + witness
            val paragraph = androidx.compose.ui.text.ParagraphStyle(
                textDirection = direction,
                textIndent = androidx.compose.ui.text.style.TextIndent(
                    2.em, 2.em))
            val original = androidx.compose.ui.text.AnnotatedString(text,
                paragraphStyles = listOf(androidx.compose.ui.text.AnnotatedString.Range(paragraph, 0, text.length)))
            val run = EgyptianTextRun(prefix.length, text.length, witness, false)
            val mapped = egyptianInlineText(original, listOf(run), rtlFallback = false)
            assertEquals(prefix + "\u2066" + witness + "\u2069", mapped.text)
            assertEquals(listOf(androidx.compose.ui.text.AnnotatedString.Range(paragraph, 0, mapped.length)),
                mapped.paragraphStyles)
            val inferred = egyptianInlineText(androidx.compose.ui.text.AnnotatedString(text), listOf(run), rtlFallback = false)
            assertEquals(if (prefix == "Latin") androidx.compose.ui.text.style.TextDirection.Ltr
                else androidx.compose.ui.text.style.TextDirection.Rtl, inferred.paragraphStyles.single().item.textDirection)
        }
    }

    @Test fun composeBuilderParagraphsKeepActualTextAndUtf16Boundaries() {
        val marker = "wikidict-poem wikidict-poem-indent-2 wikidict-poem-dir-ltr"
        fun verify(parts: List<Pair<Span, String>>, expectedText: String,
                   expectedParagraphs: List<PoemParagraph>) {
            var paragraphs = emptyList<PoemParagraph>()
            var ranges = emptyList<Pair<Span, IntRange>>()
            val rendered = androidx.compose.ui.text.buildAnnotatedString {
                ranges = parts.mapIndexed { index, (span, text) ->
                    val start = length
                    append(text)
                    addStringAnnotation("source", index.toString(), start, length)
                    span to (start until length)
                }
                // This is an AnnotatedString.Builder, whose Object.toString() is not its text.
                val actualText = toAnnotatedString().text
                assertEquals(expectedText, actualText)
                paragraphs = poemParagraphs(actualText, ranges)
                paragraphs.forEach { paragraph ->
                    addStyle(androidx.compose.ui.text.ParagraphStyle(
                        textIndent = androidx.compose.ui.text.style.TextIndent(
                            paragraph.indent.em, paragraph.indent.em),
                        textDirection = when (paragraph.direction) {
                            "ltr" -> androidx.compose.ui.text.style.TextDirection.Ltr
                            "rtl" -> androidx.compose.ui.text.style.TextDirection.Rtl
                            else -> androidx.compose.ui.text.style.TextDirection.Content
                        }), paragraph.start, paragraph.end)
                }
            }
            assertEquals(expectedText, rendered.text)
            assertEquals(expectedParagraphs, paragraphs)
            assertEquals(expectedParagraphs.map { it.start to it.end },
                rendered.paragraphStyles.map { it.start to it.end })
            assertEquals(parts.size, rendered.getStringAnnotations("source", 0, rendered.length).size)
            ranges.forEachIndexed { index, (_, range) ->
                val annotation = rendered.getStringAnnotations("source", range.first, range.last + 1)
                    .single { it.item == index.toString() }
                assertEquals(range.first, annotation.start)
                assertEquals(range.last + 1, annotation.end)
                assertEquals(parts[index].second, rendered.text.substring(annotation.start, annotation.end))
            }
        }
        // Exact pre-shaping text from the failing device test's long Egyptian case.
        val long = "𓂜𓐰𓏏𓐱𓏭𓅪𓆑".repeat(12)
        assertTrue(long.length > 56)
        verify(listOf(Span("text", long, classes = "Egyp") to long), long, emptyList())
        verify(emptyList(), "", emptyList())
        verify(listOf(Span("text", "", classes = marker) to ""), "", emptyList())
        val unicode = "\u2066𓂜e\u0301  \u2069"
        verify(listOf(Span("link", "𓂜e\u0301", target = "word#Noun", trail = "  ",
            classes = marker, direction = "ltr") to unicode), unicode,
            listOf(PoemParagraph(0, unicode.length, 2, "ltr")))
        for ((text, expected) in listOf(
            "a" to listOf(PoemParagraph(0, 1, 2, "ltr")),
            "a\n" to listOf(PoemParagraph(0, 2, 2, "ltr")),
            "a\n\n" to listOf(PoemParagraph(0, 2, 2, "ltr"), PoemParagraph(2, 3, 0, "ltr")),
            "\n\n" to listOf(PoemParagraph(0, 1, 2, "ltr"), PoemParagraph(1, 2, 0, "ltr")),
            "𓂜\nb" to listOf(PoemParagraph(0, 3, 2, "ltr"), PoemParagraph(3, 4, 0, "ltr"))
        )) verify(listOf(Span("text", text, classes = marker) to text), text, expected)
        val markedBreak = Span("line_break", "", classes = marker)
        verify(listOf(markedBreak to "\n", markedBreak to "\n"), "\n\n",
            listOf(PoemParagraph(0, 1, 2, "ltr"), PoemParagraph(1, 2, 2, "ltr")))
    }

    @Test fun authoredEmptyListsKeepMarkersIndentAndNumbering() {
        val blocks = listOf(
            Block("list_item", 1, emptyList(), listPath = "*"),
            Block("list_item", 3, emptyList(), listPath = "###", number = "7"),
            Block("definition", 2, emptyList(), listPath = "##", number = "4"),
            Block("example", 2, emptyList(), listPath = "#:"),
            Block("quotation", 2, emptyList(), listPath = "#*"),
            Block("list_detail", 3, emptyList(), listPath = "*::"),
            Block("term", 2, emptyList(), listPath = "*;"),
            Block("indent", 3, emptyList(), listPath = ":::"),
        )
        val rows = readingRows(listOf(Section(3, "Usage", blocks)))
        assertEquals(blocks, rows.mapNotNull { it.block })
        assertEquals(listOf("• ", "7. ", "04", "│ ", "│ ", "↳ ", "", ""),
            rows.mapNotNull { it.block }.map(::blockPrefix))
        assertEquals(listOf(0, 14, 7, 7, 7, 14, 7, 14), blocks.map(::blockIndentDp))
        assertEquals(listOf("block-0-0", "block-0-1", "block-0-2", "block-0-3", "block-0-4", "block-0-5", "block-0-6", "block-0-7"),
            rows.filter { it.block != null }.map { it.key })
        assertTrue(visibleReadingRows(rows, setOf("heading-0")).none { it.block != null })
    }

    @Test fun emptyNonListBlocksDoNotInventVisibleMarkers() {
        val blanks = listOf(
            Block("blank", 2, emptyList(), listPath = "**"),
            Block("paragraph", 2, emptyList(), listPath = "**"),
            Block("list_item", 0, emptyList()),
        )
        assertTrue(readingRows(listOf(Section(3, "Usage", blanks))).none { it.block != null })
    }


    @Test fun citationDestinationsKeepEqualLabelsDistinctAndOpenTheirActualSourceRow() {
        fun marker(occurrence: Long, anchor: String) = Span("link", "[7]", "", role = "reference",
            targetFragment = "reference-7", citationMarker = CitationMarker(7, occurrence, anchor, nowrap = true))
        val first = marker(3, "stored-cite-first")
        val second = marker(9, "stored-cite-second")
        val body = Block("paragraph", 0, listOf(first, Span("text", " retained body "), second))
        val definition = Block("definition", 1, listOf(Span("text", "meaning")), number = "1")
        fun backlink(occurrence: Long, anchor: String) = ReferenceBacklink.withPolicies(occurrence,
            Span("link", "return-$occurrence", "", targetFragment = anchor))
        val links = listOf(backlink(9, "stored-cite-second"), backlink(3, "stored-cite-first"))
        val reference = Reference(7, 1, "", listOf(Span("text", "note body")), backlinks = links)
        val entry = Entry("citation fixture", emptyList(), "language", "English", "en",
            listOf(Section(3, "Usage", listOf(body, definition))), listOf(reference))
        val destinations = citationDestinations(entry)
        assertEquals(listOf("stored-cite-first", "stored-cite-second"), destinations.keys.toList())
        val one = destinations.getValue("stored-cite-first")
        val two = destinations.getValue("stored-cite-second")
        assertSame(first, one.span)
        assertSame(second, two.span)
        assertEquals(3L, one.marker.occurrence)
        assertEquals(9L, two.marker.occurrence)
        assertEquals("block-0-0", one.rowKey)
        assertEquals(one.rowKey, two.rowKey)
        assertTrue(one.graphical && two.graphical)
        assertNull(destinations["[7]"])
        assertNull(destinations["reference-7"])
        assertNull(citationScrollIndex(entry, one, setOf("heading-0")))
        assertEquals(setOf("heading-0", "heading-0-details"), citationFoldKeys(entry, one))
        val folded = mutableSetOf("heading-0", "heading-0-details", "references")
        folded.removeAll(citationFoldKeys(entry, one))
        assertEquals(2, citationScrollIndex(entry, one, folded))
        assertEquals(2, citationScrollIndex(entry, two, folded))
        assertEquals(listOf(9L, 3L), reference.backlinks.map { it.occurrence })
        val reordered = entry.copy(references = listOf(reference.copy(backlinks = links.reversed())))
        val changed = citationDestinations(reordered)
        assertSame(first, changed.getValue("stored-cite-first").span)
        assertSame(second, changed.getValue("stored-cite-second").span)
        assertEquals(listOf(first, body.spans[1], second), body.spans)
        assertEquals("[7] retained body [7]", textOf(body.spans))
    }

    @Test fun citationDestinationsUseAuthoritativeCaptionCellPreambleAndReferenceBodySinks() {
        fun marker(occurrence: Long) = Span("link", "[7]", "", role = "reference",
            targetFragment = "reference-7", citationMarker = CitationMarker(7, occurrence, "saved-anchor-$occurrence"))
        val preamble = marker(1)
        val caption = marker(2)
        val cell = marker(3)
        val referenceMarker = marker(4)
        val table = Table(listOf(caption), listOf(listOf(Cell(listOf(cell), false, 1, 1))))
        val reference = Reference(7, 1, "", listOf(referenceMarker), backlinks = listOf(4L, 2L, 1L, 3L).map {
            ReferenceBacklink.withPolicies(it, Span("link", "return-$it", "", targetFragment = "saved-anchor-$it"))
        })
        val entry = Entry("citation sinks", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(Block("table", 0, emptyList(), table = table)))),
            listOf(reference), preamble = listOf(preamble))
        val destinations = citationDestinations(entry)
        assertEquals(4, destinations.size)
        assertEquals(listOf(1L, 2L, 3L, 4L), destinations.values.map { it.marker.occurrence })
        val pre = destinations.getValue("saved-anchor-1")
        val cap = destinations.getValue("saved-anchor-2")
        val content = destinations.getValue("saved-anchor-3")
        val note = destinations.getValue("saved-anchor-4")
        assertSame(preamble, pre.span)
        assertSame(caption, cap.span)
        assertSame(cell, content.span)
        assertSame(referenceMarker, note.span)
        assertEquals(CitationSourceSlot.Preamble, pre.slot)
        assertEquals(CitationSourceSlot.Reference, note.slot)
        assertEquals(0, note.referenceIndex)
        assertEquals("block-0-0", cap.rowKey)
        assertEquals(cap.rowKey, content.rowKey)
        assertEquals(setOf("preamble"), citationFoldKeys(entry, pre))
        assertEquals(setOf("references"), citationFoldKeys(entry, note))
        assertEquals(1, citationScrollIndex(entry, pre, emptySet()))
        assertEquals(3, citationScrollIndex(entry, cap, emptySet()))
        assertEquals(3, citationScrollIndex(entry, content, emptySet()))
        assertEquals(5, citationScrollIndex(entry, note, emptySet()))
        assertTrue(destinations.values.all { it.graphical })
        assertEquals("[1]", referenceLabel(reference))
        assertEquals(listOf(preamble), entry.preamble)
        assertSame(table, entry.sections.single().blocks.single().table)
        assertSame(referenceMarker, entry.references.single().spans.single())
    }


    @Test fun audioControlOccurrencesKeepIndependentPolicyAndLegacyFileGrouping() {
        val media = Media("Tone.ogg", "audio", "Tone")
        val owners = MediaOwners(listOf(media))
        val classes = "note wikidict-media wikidict-media-file-546f6e652e6f6767"
        val legacy = Span("link", "legacy", "File:Tone.ogg", classes = classes)
        val automatic = legacy.copy(text = "first", direction = "rtl", audioControl = AudioControl(focus = AudioControlFocusPaint(AudioControlFocusMode.UaAuto,
            FigureColor.Rgb("#3366cc"))))
        val suppressed = legacy.copy(text = "second", audioControl = AudioControl(focus = AudioControlFocusPaint(AudioControlFocusMode.AuthoredNone)))
        val unstyled = legacy.copy(text = "unstyled", audioControl = AudioControl())
        val spans = listOf(legacy, legacy.copy(text = "caption fragment"), automatic, suppressed, automatic, unstyled)
        val controls = owners.embeddedControls(spans)
        assertEquals(5, controls.size)
        assertEquals(listOf(null, 2, 3, 4, 5), controls.map { it.sourceIndex })
        assertEquals(listOf(null, automatic.audioControl, suppressed.audioControl, automatic.audioControl, unstyled.audioControl),
            controls.map { it.audioControl })
        assertTrue(controls.all { it.media === media })
        assertEquals(listOf("", "rtl", "", "rtl", ""), controls.map { it.sourceDirection })
        assertEquals(listOf(media), owners.embedded(spans))
        assertEquals(listOf(EmbeddedMediaControl(media, null, null)), owners.embeddedControls(spans.take(2)))
        assertSame(automatic, spans[2])
        assertSame(automatic, spans[4])
        assertEquals("File:Tone.ogg", automatic.target)
    }

    @Test fun audioControlProjectionPreservesLexicalDataAndZeroTextControlWithoutMetricOwnership() {
        val owner = Span("link", "", "File:Tone.ogg", classes =
            "note wikidict-media wikidict-media-file-546f6e652e6f6767", bold = true,
            explanation = "source explanation", audioControl = AudioControl(focus = AudioControlFocusPaint(AudioControlFocusMode.UaAuto)))
        val media = Media("Tone.ogg", "audio", "Tone")
        assertEquals(listOf(owner), compactSpans(listOf(owner)))
        assertTrue(listOf(owner).hasCompiledInlineContent())
        assertTrue(paragraphHasContent(Block("paragraph", 0, listOf(owner))))
        assertEquals(listOf(EmbeddedMediaControl(media, 0, owner.audioControl)),
            MediaOwners(listOf(media)).embeddedControls(listOf(owner)))
        val projected = owner.withoutClassToken("wikidict-media")
        assertEquals(owner.copy(classes = "note wikidict-media-file-546f6e652e6f6767", audioControl = null), projected)
        assertEquals(owner.audioControl, owner.withoutClassToken("note").audioControl)
        assertEquals("File:Tone.ogg", projected.target)
        assertTrue(projected.bold)
        assertEquals("source explanation", projected.explanation)
        assertEquals("", textOf(listOf(projected)))
        val metric = inlineMetricOwnerSpan(owner)
        assertEquals("text", metric.kind)
        assertNull(metric.audioControl)
        assertTrue(metric.bold)
        assertEquals("", metric.target)
        assertEquals(AudioControlFocusMode.UaAuto, owner.audioControl?.focus?.mode)
        val collapsed = ordinaryInlineDisplaySpans(Block("paragraph", 0,
            listOf(Span("text", " "), owner.copy(text = " "))))
        assertEquals(2, collapsed.size)
        assertEquals("", collapsed[1].text)
        assertEquals(owner.audioControl, collapsed[1].audioControl)
        assertEquals(listOf(collapsed[1]), compactSpans(collapsed))
        assertEquals(listOf(EmbeddedMediaControl(media, 0, owner.audioControl)),
            MediaOwners(listOf(media)).embeddedControls(compactSpans(collapsed)))
    }


    @Test fun audioControlSlotAllocationUsesOriginalContainingBasisAndStackedMaximum() {
        val media = Media("Tone.ogg", "audio", "Tone")
        val owner = Span("link", "Audio", "File:Tone.ogg",
            classes = "wikidict-media wikidict-media-file-546f6e652e6f6767", audioControl = AudioControl())
        val body = Block("paragraph", 0, listOf(owner))
        val entry = Entry("word", emptyList(), "language", "English", "en",
            listOf(Section(3, "Notes", listOf(body))), emptyList(), media = listOf(media))
        val rows = entry.readingRows
        val bodyIndex = rows.indexOfFirst { it.block === body }
        assertTrue(bodyIndex >= 0)
        assertEquals(listOf(bodyIndex until rows.size), floatBodyRuns(rows))
        assertTrue(body.hasNativeAudioControlBody())
        val legacy = body.copy(spans = listOf(owner.copy(audioControl = null)))
        assertFalse(legacy.hasNativeAudioControlBody())
        assertFalse(legacy.needsNativeBlockContext())
        val ignoredTablePrefix = Block("table", 0, listOf(owner), table = Table(emptyList(), emptyList()))
        assertFalse(ignoredTablePrefix.hasNativeAudioControlBody())
        assertFalse(ignoredTablePrefix.needsNativeBlockContext())
        fun control(width: StyleWidth?, index: Int) = EmbeddedMediaControl(media, index, AudioControl(width = width))
        val fixed = control(StyleWidth(StyleWidthUnit.Px, 250f), 0)
        val percent = control(StyleWidth(StyleWidthUnit.Percent, 100f), 1)
        val controls = listOf(fixed, percent)
        assertEquals(270, embeddedMediaSlotWidth(controls, 180, 16f, 4f, 1f, 20f, overflowOwned = true))
        assertEquals(270, embeddedMediaSlotWidth(controls, 190, 16f, 4f, 1f, 20f, overflowOwned = true))
        assertEquals(160f, audioControlWidthPixels(checkNotNull(percent.audioControl), 160f, 1f, 20f)!!, 0f)
        assertEquals(170f, audioControlWidthPixels(checkNotNull(percent.audioControl), 170f, 1f, 20f)!!, 0f)
        assertEquals(180, embeddedMediaSlotWidth(listOf(percent), 180, 16f, 4f, 1f, 20f))
        assertEquals(180, embeddedMediaSlotWidth(listOf(percent), 180, .1f, .1f, 1f, 20f))
        assertEquals(180, embeddedMediaSlotWidth(listOf(percent), 180, .1f, .1f, 1f, 20f, overflowOwned = true))
        assertThrows(UnsupportedFloatLayout::class.java) {
            embeddedMediaSlotWidth(controls, 180, 16f, 4f, 1f, 20f)
        }
        val fractional = control(StyleWidth(StyleWidthUnit.Percent, 150.25f), 2)
        assertEquals(270, embeddedMediaSlotWidth(listOf(fractional), 180, .25f, .75f, 1f, 20f, overflowOwned = true))
        assertEquals(268.9475f, audioControlWidthPixels(checkNotNull(fractional.audioControl), 179f, 1f, 20f)!!, .0001f)
        val em = control(StyleWidth(StyleWidthUnit.Em, 10f), 3)
        assertEquals(320, embeddedMediaSlotWidth(listOf(em), 180, 16f, 4f, 1f, 30f, overflowOwned = true))
        assertEquals(180, embeddedMediaSlotWidth(listOf(EmbeddedMediaControl(media, null, null)), 180, 16f, 4f, 2f, 60f))
        assertThrows(UnsupportedFloatLayout::class.java) {
            embeddedMediaSlotWidth(listOf(fixed), 180, Float.NaN, 4f, 1f, 20f)
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            embeddedMediaSlotWidth(listOf(control(StyleWidth(StyleWidthUnit.Px, Float.MAX_VALUE), 4)),
                180, 16f, 4f, 2f, 20f)
        }
    }


    @Test fun containerDisclosureStateSeparatesSourceEpochOwnerOccurrenceAndReferenceSlot() {
        val action = Span("link", "hidden", target = "retained-action")
        val content = Block("container", 0, emptyList(), container = Container(
            listOf(Block("paragraph", 0, listOf(action)))))
        val header = Block("paragraph", 0, listOf(Span("text", "header")))
        val policy = ContainerDisclosure(1L, true, "[show]", "[hide]")
        val owner = Container(listOf(header, content), disclosure = policy)
        val original = Block("container", 0, emptyList(), container = owner)
        val entry = Entry("disclosure", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(original))), emptyList())
        val equalEntry = entry.copy()
        val equalOwner = owner.copy()
        assertEquals(entry, equalEntry); assertNotSame(entry, equalEntry)
        assertEquals(owner, equalOwner); assertNotSame(owner, equalOwner)
        val identity = NativeContainerDisclosureSourceIdentity(entry)
        assertEquals(identity, NativeContainerDisclosureSourceIdentity(entry))
        assertNotEquals(identity, NativeContainerDisclosureSourceIdentity(equalEntry))
        val visit = NativeContainerDisclosureVisit()
        val state = visit.stateFor(entry)
        assertSame(state, visit.stateFor(entry))
        val firstPath = "block-0-0"
        val secondPath = "block-0-1"
        assertFalse(state.isExpanded(owner, firstPath))
        state.toggle(owner, firstPath)
        assertTrue(state.isExpanded(owner, firstPath))
        assertFalse(state.isExpanded(owner, secondPath))
        assertFalse(state.isExpanded(equalOwner, firstPath))
        assertFalse(state.expand(owner, firstPath))
        assertTrue(state.expand(owner, secondPath))
        assertTrue(state.isExpanded(owner, secondPath))
        state.toggle(owner, firstPath)
        assertFalse(state.isExpanded(owner, firstPath)); assertTrue(state.isExpanded(owner, secondPath))
        val referencePath = "reference-7/block-0"
        val firstReference = state.inReference(0)
        val secondReference = state.inReference(1)
        assertSame(firstReference, state.inReference(0))
        assertSame(firstReference, firstReference.inReference(0))
        assertTrue(firstReference.expand(owner, referencePath))
        assertTrue(firstReference.isExpanded(owner, referencePath))
        assertFalse(secondReference.isExpanded(owner, referencePath))
        assertFalse(state.isExpanded(owner, referencePath))
        assertTrue(state.isExpanded(NativeContainerDisclosureOwner(owner, referencePath, null, 0)))
        assertFalse(state.isExpanded(NativeContainerDisclosureOwner(owner, referencePath, null, 1)))
        val selectedOwner = NativeContainerDisclosureOwner(owner, referencePath, null, 0)
        val heldHeading = CellHeadingRequest("compiled-reference-0", referenceIndex = 0,
            disclosureReveal = true, disclosureOwners = listOf(selectedOwner))
        assertSame(heldHeading, referenceHeadingRequest(heldHeading, null, firstReference.referenceIndex))
        assertNull(referenceHeadingRequest(heldHeading, null, secondReference.referenceIndex))
        assertNull(referenceHeadingRequest(heldHeading, null, state.referenceIndex))
        assertSame(heldHeading, referenceHeadingRequest(heldHeading, 0))
        assertNull(referenceHeadingRequest(heldHeading, 1))
        assertSame(selectedOwner, heldHeading.disclosureOwners.single())
        val legacyHeading = CellHeadingRequest(referencePath, referenceIndex = 0)
        assertSame(legacyHeading, referenceHeadingRequest(legacyHeading, null, null))
        assertNull(referenceHeadingRequest(legacyHeading, 1, null))
        val initiallyOpen = owner.copy(disclosure = policy.copy(initiallyCollapsed = false))
        assertTrue(state.isExpanded(initiallyOpen, firstPath))
        state.toggle(initiallyOpen, firstPath)
        assertFalse(state.isExpanded(initiallyOpen, firstPath))
        assertTrue(state.expand(initiallyOpen, firstPath))
        assertSame(state, visit.stateFor(entry))
        assertTrue(visit.stateFor(entry).isExpanded(owner, secondPath))
        assertTrue(visit.stateFor(entry).inReference(0).isExpanded(owner, referencePath))
        val replacementState = visit.stateFor(equalEntry)
        assertNotSame(state, replacementState)
        assertSame(replacementState, visit.stateFor(equalEntry))
        assertFalse(replacementState.isExpanded(owner, secondPath))
        assertFalse(replacementState.inReference(0).isExpanded(owner, referencePath))
        assertTrue(replacementState.isExpanded(initiallyOpen, firstPath))
        val returnedState = visit.stateFor(entry)
        assertNotSame(state, returnedState)
        assertNotSame(replacementState, returnedState)
        assertFalse(returnedState.isExpanded(owner, secondPath))
        assertSame(content, owner.blocks[1]); assertSame(header, owner.blocks[0])
        assertSame(action, owner.blocks[1].container!!.blocks.single().spans.single())
        assertEquals("retained-action", action.target)
    }

    @Test fun disclosureHeadingInventoryExpandsOriginalContainerCellAndCaptionPaths() {
        fun paragraph(label: String) = Block("paragraph", 0, listOf(Span("text", label)))
        fun child(value: Container) = Block("container", 0, emptyList(), container = value)
        val heading = Block("heading", 0, listOf(Span("link", "Hidden heading", target = "heading-action")),
            level = 3, anchor = "hidden-heading", anchorFallback = "Hidden_heading")
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
            blocks = listOf(paragraph("before heading"), heading, paragraph("after heading"))))))
        val content = child(Container(listOf(Block("table", 0, emptyList(), table = table))))
        val inner = Container(listOf(paragraph("inner header"), content, paragraph("inner tail")),
            disclosure = ContainerDisclosure(1L, true, "inner show", "inner hide"))
        val innerBlock = child(inner)
        val outer = Container(listOf(paragraph("outer header"), innerBlock, paragraph("outer tail")),
            disclosure = ContainerDisclosure(1L, true, "outer show", "outer hide"))
        val captionHeading = heading.copy(anchor = "caption-heading", anchorFallback = "")
        val captionTable = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
            blocks = listOf(captionHeading)))))
        val captionContent = child(Container(listOf(Block("table", 0, emptyList(), table = captionTable))))
        val captionOwner = Container(listOf(captionContent),
            disclosure = ContainerDisclosure(0L, true, "caption show", "caption hide"))
        val outerTable = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "visible cell")), false, 1, 1))),
            captionBlocks = listOf(child(captionOwner)))
        val first = child(outer)
        val second = Block("table", 0, emptyList(), table = outerTable)
        val entry = Entry("disclosure paths", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(first, second))), emptyList())
        val index = NativeContainerDisclosureIndex(entry)
        val ownerPath = "block-0-0"
        val innerPath = "$ownerPath/container/block-1"
        val headingPath = "$innerPath/container/block-1/container/block-0/table/cell-0/block-1"
        val captionPath = "block-0-1/table/caption/block-0"
        val captionHeadingPath = "$captionPath/container/block-0/container/block-0/table/cell-0/block-0"
        assertEquals(listOf(ownerPath, innerPath, captionPath), index.owners.map { it.path })
        assertSame(outer, index.owners[0].container); assertSame(inner, index.owners[1].container)
        assertSame(captionOwner, index.owners[2].container)
        assertSame(innerBlock, index.owners[0].content); assertSame(content, index.owners[1].content)
        val selected = checkNotNull(headingDestination(entry, "#hidden-heading"))
        assertEquals("block-0-0", selected.rowKey); assertEquals(headingPath, selected.path)
        assertTrue(selected.compiledId)
        assertEquals(HeadingAnchorSelection("hidden-heading", HeadingAnchorKind.Primary, null), selected.anchorMatch)
        assertEquals(headingPath, headingDestination(entry, "#Hidden heading")!!.path)
        assertEquals(captionHeadingPath, headingDestination(entry, "#caption-heading")!!.path)
        val enclosing = index.enclosingPath(checkNotNull(selected.path))
        assertEquals(index.owners.take(2), enclosing)
        assertTrue(index.enclosingPath("$ownerPath/container/block-0").isEmpty())
        assertTrue(index.enclosingPath("${index.owners[0].contentPath}0").isEmpty())
        val state = NativeContainerDisclosureState()
        assertTrue(enclosing.all { !state.isExpanded(it) })
        assertTrue(state.expandOwners(enclosing)); assertFalse(state.expandOwners(enclosing))
        assertTrue(enclosing.all(state::isExpanded)); assertFalse(state.isExpanded(index.owners[2]))
        assertEquals(selected, headingDestination(entry, "#hidden-heading"))
        assertTrue(state.expandOwners(index.enclosingPath(captionHeadingPath)))
        assertTrue(index.owners.all(state::isExpanded))
        assertEquals(listOf("heading-0", "block-0-0", "block-0-1"), entry.readingRows.map { it.key })
        assertSame(first, entry.sections.single().blocks[0]); assertSame(second, entry.sections.single().blocks[1])
        assertSame(heading, table.rows.single().single().blocks!![1])
        assertEquals(listOf("inner header", "", "inner tail"), inner.blocks.map { textOf(it.spans) })
        assertEquals(1L, inner.disclosure!!.contentIndex)
        val legacy = Entry("legacy paths", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(child(Container(listOf(Block("table", 0, emptyList(), table = table))))))), emptyList())
        assertTrue(NativeContainerDisclosureIndex(legacy).owners.isEmpty())
        assertNull(headingDestination(legacy, "#hidden-heading")) // Keep the old null-disclosure admission unchanged.
    }

    @Test fun disclosureCitationExpansionKeepsOriginalSpanIdentityAndEveryStoredAction() {
        fun marker(occurrence: Long, anchor: String) = Span("link", "[7]", "", role = "reference",
            targetFragment = "reference-7", citationMarker = CitationMarker(7, occurrence, anchor))
        fun owner(spans: List<Span>, label: String): Container {
            val hidden = Block("container", 0, emptyList(), container = Container(
                listOf(Block("paragraph", 0, spans))))
            return Container(listOf(Block("paragraph", 0, listOf(Span("text", label))), hidden),
                disclosure = ContainerDisclosure(1L, true, "[show]", "[hide]"))
        }
        val bodyMarker = marker(1, "hidden-body-cite")
        val noteMarker = marker(2, "hidden-note-cite")
        val retained = Span("link", "retained text", target = "independent-target", tooltip = "retained tooltip")
        val bodyOwner = owner(listOf(bodyMarker, Span("text", " "), retained), "visible header")
        val noteOwner = owner(listOf(noteMarker, Span("text", " note body")), "visible note header")
        val body = Block("container", 0, emptyList(), container = bodyOwner)
        val note = Block("container", 0, emptyList(), container = noteOwner)
        val backlinks = listOf(1L to "hidden-body-cite", 2L to "hidden-note-cite").map { (occurrence, anchor) ->
            ReferenceBacklink.withPolicies(occurrence, Span("link", "return-$occurrence", "", targetFragment = anchor))
        }
        val reference = Reference(7, 1, "", emptyList(), blocks = listOf(note), backlinks = backlinks)
        val entry = Entry("hidden citations", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(body))), listOf(reference))
        val index = NativeContainerDisclosureIndex(entry)
        val destinations = citationDestinations(entry)
        val bodyDestination = destinations.getValue("hidden-body-cite")
        val noteDestination = destinations.getValue("hidden-note-cite")
        assertSame(bodyMarker, bodyDestination.span); assertSame(noteMarker, noteDestination.span)
        assertTrue(bodyDestination.graphical && noteDestination.graphical) // Source ranges, not current visibility.
        assertEquals("block-0-0", bodyDestination.rowKey)
        assertEquals(CitationSourceSlot.Reference, noteDestination.slot); assertEquals(0, noteDestination.referenceIndex)
        val bodyOwners = index.enclosingSpan(bodyDestination.span, bodyDestination.rowKey, bodyDestination.referenceIndex)
        val noteOwners = index.enclosingSpan(noteDestination.span, noteDestination.rowKey, noteDestination.referenceIndex)
        assertEquals(listOf("block-0-0"), bodyOwners.map { it.path })
        assertEquals(listOf("reference-7/block-0"), noteOwners.map { it.path })
        assertTrue(index.enclosingSpan(bodyMarker.copy(), bodyDestination.rowKey, null).isEmpty())
        assertTrue(index.enclosingSpan(bodyMarker, "block-0-1", null).isEmpty())
        assertTrue(index.enclosingSpan(noteMarker, null, 1).isEmpty())
        val state = NativeContainerDisclosureState()
        assertTrue(state.expandOwners(bodyOwners))
        assertFalse(state.isExpanded(noteOwners.single()))
        assertTrue(state.expandOwners(noteOwners)); assertFalse(state.expandOwners(noteOwners))
        assertTrue(state.inReference(0).isExpanded(noteOwner, "reference-7/block-0"))
        assertFalse(state.isExpanded(noteOwner, "reference-7/block-0"))
        val after = citationDestinations(entry)
        assertSame(bodyMarker, after.getValue("hidden-body-cite").span)
        assertSame(noteMarker, after.getValue("hidden-note-cite").span)
        val all = mutableListOf<Span>()
        PresentationSpanVisitor { _, _ -> }.apply { onSpan = { all += it } }.also {
            it.block(body); it.block(note)
        }
        assertEquals(listOf("visible header", "[7]", " ", "retained text", "visible note header", "[7]", " note body"), all.map { it.text })
        assertSame(retained, all[3]); assertEquals("independent-target", all[3].target)
        assertEquals("retained tooltip", all[3].tooltip)
        assertEquals("reference-7", bodyMarker.targetFragment)
        assertSame(note, reference.blocks!!.single()); assertSame(backlinks, reference.backlinks)
        assertEquals(setOf("references"), citationFoldKeys(entry, noteDestination))
        assertNotNull(citationScrollIndex(entry, bodyDestination, emptySet()))
        assertNotNull(citationScrollIndex(entry, noteDestination, emptySet()))
    }

    @Test fun citationRowVisibilityKeepsCaptionAndNestedRowAncestryWithoutFilteringSource() {
        fun marker(occurrence: Long) = Span("link", "[$occurrence]", role = "reference", targetFragment = "reference-7",
            citationMarker = CitationMarker(7, occurrence, "row-cite-$occurrence"))
        val markers = (1L..9L).map(::marker)
        fun paragraph(span: Span) = Block("paragraph", 0, listOf(span))
        fun tableBlock(table: Table) = Block("table", 0, emptyList(), table = table)
        val high = Table(listOf(markers[2]), listOf(listOf(Cell(listOf(markers[3]), false, 1, 1))),
            rowsHiddenMaxWidthPx = 719L)
        val low = Table(listOf(markers[4]), listOf(listOf(Cell(listOf(markers[5]), false, 1, 1))),
            rowsHiddenMaxWidthPx = 500L)
        val outer = Table(listOf(markers[0]), listOf(listOf(
            Cell(emptyList(), false, 1, 1, blocks = listOf(paragraph(markers[1]), tableBlock(high))),
            Cell(emptyList(), false, 1, 1, nestedTable = low))), rowsHiddenMaxWidthPx = 639L)
        val outside = paragraph(markers[6])
        val reference = Reference(7, 1, "", listOf(markers[8]), backlinks = markers.map { source ->
            val citation = checkNotNull(source.citationMarker)
            ReferenceBacklink.withPolicies(citation.occurrence,
                Span("link", "return-${citation.occurrence}", targetFragment = citation.anchor))
        })
        val entry = Entry("row visibility citations", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(tableBlock(outer), outside))), listOf(reference),
            preamble = listOf(markers[7]))
        val destinations = citationDestinations(entry)
        val expected = listOf<Long?>(null, 639L, 639L, 719L, 639L, 639L, null, null, null)
        assertEquals(listOf(8L, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 9L), destinations.values.map { it.marker.occurrence })
        markers.forEachIndexed { index, source ->
            val destination = destinations.getValue("row-cite-${index + 1}")
            assertSame(source, destination.span)
            assertEquals(expected[index], destination.rowsHiddenMaxWidthPx)
            assertTrue(destination.graphical) // Logical source participation is independent of current row visibility.
        }
        assertEquals("block-0-0", destinations.getValue("row-cite-1").rowKey)
        assertEquals("block-0-0", destinations.getValue("row-cite-6").rowKey)
        assertEquals("block-0-1", destinations.getValue("row-cite-7").rowKey)
        assertEquals(CitationSourceSlot.Preamble, destinations.getValue("row-cite-8").slot)
        assertEquals(CitationSourceSlot.Reference, destinations.getValue("row-cite-9").slot)
        assertEquals(0, destinations.getValue("row-cite-9").referenceIndex)
        assertTrue(entry.hasTableRowVisibilityPolicy())
        assertTrue(nativeTableRowsHiddenAt(outer, 0.0))
        assertTrue(nativeTableRowsHiddenAt(outer, 639.0))
        assertFalse(nativeTableRowsHiddenAt(outer, 639.25))
        val nestedRow = destinations.getValue("row-cite-4")
        assertTrue(nativeTableRowsHiddenAt(nestedRow.rowsHiddenMaxWidthPx, 719.0))
        assertFalse(nativeTableRowsHiddenAt(nestedRow.rowsHiddenMaxWidthPx, 719.25))
        assertFalse(nativeTableRowsHiddenAt(destinations.getValue("row-cite-1").rowsHiddenMaxWidthPx, 0.0))
        assertTrue(nativeTableRowsHiddenAt(0xffff_ffffL, 4294967295.0))
        assertFalse(nativeTableRowsHiddenAt(0xffff_ffffL, 4294967295.5))
        assertEquals(destinations, citationDestinations(entry))
        assertSame(outer, entry.sections.single().blocks[0].table)
        assertSame(outside, entry.sections.single().blocks[1])
        assertSame(markers[0], outer.caption.single())
        assertSame(markers[2], high.caption.single())
        assertSame(markers[4], low.caption.single())
        assertEquals(markers.map { it.citationMarker!!.occurrence }, reference.backlinks.map { it.occurrence })

        val clearedHigh = high.copy(rowsHiddenMaxWidthPx = null)
        val clearedLow = low.copy(rowsHiddenMaxWidthPx = null)
        val clearedOuter = outer.copy(rowsHiddenMaxWidthPx = null, rows = listOf(listOf(
            outer.rows.single()[0].copy(blocks = listOf(paragraph(markers[1]), tableBlock(clearedHigh))),
            outer.rows.single()[1].copy(nestedTable = clearedLow))))
        val legacy = entry.copy(sections = listOf(entry.sections.single().copy(blocks = listOf(tableBlock(clearedOuter), outside))))
        val restored = citationDestinations(legacy)
        assertFalse(legacy.hasTableRowVisibilityPolicy())
        assertFalse(nativeTableRowsHiddenAt(clearedOuter, 0.0))
        assertEquals(destinations.keys, restored.keys)
        destinations.forEach { (anchor, destination) ->
            assertEquals(destination.copy(rowsHiddenMaxWidthPx = null), restored.getValue(anchor))
            assertSame(destination.span, restored.getValue(anchor).span)
        }
        assertEquals(719L, high.rowsHiddenMaxWidthPx)
        assertEquals(639L, outer.rowsHiddenMaxWidthPx)
    }

    @Test fun headingRowVisibilityKeepsNestedPathsReferenceCustodyAndSourceAmbiguity() {
        fun heading(anchor: String) = Block("heading", 0, listOf(Span("link", anchor, target = "action-$anchor")),
            level = 3, anchor = anchor, anchorFallback = anchor.replace('-', '_'))
        fun tableBlock(table: Table) = Block("table", 0, emptyList(), table = table)
        fun grid(blocks: List<Block>, maximum: Long?) = Table(emptyList(),
            listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = blocks))), rowsHiddenMaxWidthPx = maximum)
        val own = heading("outer-heading")
        val highHeading = heading("high-heading")
        val lowHeading = heading("low-heading")
        val outside = heading("outside-heading")
        val referenceHeading = heading("note-heading")
        val high = grid(listOf(highHeading), 719L)
        val low = grid(listOf(lowHeading), 500L)
        val outer = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, blocks = listOf(own, tableBlock(high))),
            Cell(emptyList(), false, 1, 1, nestedTable = low))), rowsHiddenMaxWidthPx = 639L)
        val noteTable = grid(listOf(referenceHeading), 799L)
        val reference = Reference(7, 1, "", emptyList(), blocks = listOf(tableBlock(noteTable)))
        val entry = Entry("row visibility headings", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(tableBlock(outer), outside))), listOf(reference))
        val expected = listOf(
            Triple("outer-heading", "block-0-0/table/cell-0/block-0", 639L),
            Triple("high-heading", "block-0-0/table/cell-0/block-1/table/cell-0/block-0", 719L),
            Triple("low-heading", "block-0-0/table/cell-1/nested/cell-0/block-0", 639L))
        expected.forEach { (anchor, path, maximum) ->
            val destination = checkNotNull(headingDestination(entry, "#$anchor"))
            assertEquals("block-0-0", destination.rowKey)
            assertEquals(path, destination.path)
            assertEquals(maximum, destination.rowsHiddenMaxWidthPx)
            assertTrue(destination.compiledId)
            assertEquals(HeadingAnchorSelection(anchor, HeadingAnchorKind.Primary, null), destination.anchorMatch)
            assertEquals(destination.copy(anchorMatch = HeadingAnchorSelection(anchor.replace('-', '_'), HeadingAnchorKind.Fallback, null)),
                headingDestination(entry, "#${anchor.replace('-', ' ')}"))
            assertTrue(nativeTableRowsHiddenAt(destination.rowsHiddenMaxWidthPx, maximum.toDouble()))
            assertFalse(nativeTableRowsHiddenAt(destination.rowsHiddenMaxWidthPx, maximum.toDouble() + 0.25))
        }
        assertNull(headingDestination(entry, "#outside-heading")!!.rowsHiddenMaxWidthPx)
        val note = checkNotNull(headingDestination(entry, "#note-heading"))
        assertEquals("reference-7/block-0/table/cell-0/block-0", note.path)
        assertEquals(0, note.referenceIndex)
        assertEquals(799L, note.rowsHiddenMaxWidthPx)
        val request = CellHeadingRequest(checkNotNull(note.path), note.anchorMatch,
            referenceIndex = note.referenceIndex, rowsHiddenMaxWidthPx = note.rowsHiddenMaxWidthPx)
        assertSame(request, referenceHeadingRequest(request, null, 0))
        assertNull(referenceHeadingRequest(request, null, 1))
        assertNull(referenceHeadingRequest(request, null, null))
        assertSame(referenceHeading, reference.blocks!!.single().table!!.rows.single().single().blocks!!.single())
        assertSame(highHeading, high.rows.single().single().blocks!!.single())
        assertEquals("action-high-heading", highHeading.spans.single().target)
        assertTrue(entry.copy(sections = listOf(Section(3, "Body", emptyList()))).hasTableRowVisibilityPolicy())

        val captionHeading = heading("caption-heading")
        val nestedCaptionHeading = heading("nested-caption-heading")
        val highWithCaption = high.copy(captionBlocks = listOf(nestedCaptionHeading))
        val wrappedTable = outer.copy(captionBlocks = listOf(captionHeading), rows = listOf(listOf(
            outer.rows.single()[0].copy(blocks = listOf(own, tableBlock(highWithCaption))),
            outer.rows.single()[1])))
        val wrapper = Container(listOf(tableBlock(wrappedTable)),
            ContainerStyle(positioning = ContainerPositioning.RelativeAuto, overflow = ContainerOverflow.Hidden))
        val wrappedBlock = Block("container", 0, emptyList(), container = wrapper)
        val wrappedEntry = entry.copy(sections = listOf(entry.sections.single().copy(blocks = listOf(wrappedBlock, outside))))
        assertNull(wrapper.disclosure)
        assertTrue(wrappedBlock.hasTableRowVisibilityPolicy())
        val wrappedHeading = checkNotNull(headingDestination(wrappedEntry, "#high-heading"))
        assertEquals("block-0-0/container/block-0/table/cell-0/block-1/table/cell-0/block-0", wrappedHeading.path)
        assertEquals(719L, wrappedHeading.rowsHiddenMaxWidthPx)
        val ownCaption = checkNotNull(headingDestination(wrappedEntry, "#caption-heading"))
        assertEquals("block-0-0/container/block-0/table/caption/block-0", ownCaption.path)
        assertNull(ownCaption.rowsHiddenMaxWidthPx)
        val nestedCaption = checkNotNull(headingDestination(wrappedEntry, "#nested-caption-heading"))
        assertEquals("block-0-0/container/block-0/table/cell-0/block-1/table/caption/block-0", nestedCaption.path)
        assertEquals(639L, nestedCaption.rowsHiddenMaxWidthPx)
        assertSame(captionHeading, wrappedTable.captionBlocks!!.single())
        assertSame(nestedCaptionHeading, highWithCaption.captionBlocks!!.single())

        val duplicate = heading("same-heading")
        val duplicateTable = grid(listOf(duplicate), 639L)
        val ambiguous = entry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(duplicateTable), duplicate))), references = emptyList())
        assertTrue(nativeTableRowsHiddenAt(duplicateTable, 639.0))
        assertNull(headingDestination(ambiguous, "#same-heading"))
        assertNull(headingDestination(ambiguous, "#same heading"))
        assertSame(duplicate, ambiguous.sections.single().blocks[1])
        assertSame(duplicate, duplicateTable.rows.single().single().blocks!!.single())

        val blockedHeading = heading("figure-heading")
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val figure = Figure(
            FigureContent.Missing(Span("text", "Missing"), StyleLength(StyleLengthUnit.Px, 20f), StyleLength(StyleLengthUnit.Em, 1f)),
            FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, edges, edges, edges, 1f,
            StyleLength(StyleLengthUnit.Em, 1.2f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            captionBlocks = listOf(blockedHeading))
        val figureBlock = Block("paragraph", 0, emptyList(), figure = figure)
        val figureTable = grid(listOf(figureBlock), 639L)
        val figureEntry = entry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(figureTable)))))
        val blocked = checkNotNull(headingDestination(figureEntry, "#figure-heading"))
        assertTrue(blocked.nativeNavigationUnavailable)
        assertTrue(blocked.compiledId)
        assertNull(blocked.path)
        assertEquals(639L, blocked.rowsHiddenMaxWidthPx)
        assertEquals(HeadingAnchorSelection("figure-heading", HeadingAnchorKind.Primary, null), blocked.anchorMatch)
        assertSame(blockedHeading, figure.captionBlocks!!.single())
        assertEquals("action-figure-heading", blockedHeading.spans.single().target)
        val flowScope = BidiScope(BidiMode.Isolate, BidiDirectionInput.Rtl, BidiResolvedDirection.Rtl, null,
            listOf(FlowPart.ImageFigure(figure)))
        val flowBlock = Block("paragraph", 0, emptyList(), flow = listOf(
            FlowPart.Inline(listOf(Span("text", "before figure"))), FlowPart.Scope(flowScope)))
        val flowTable = grid(listOf(flowBlock), 639L)
        val flowEntry = figureEntry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(flowTable)))))
        val flowTarget = checkNotNull(headingDestination(flowEntry, "#figure-heading"))
        assertTrue(flowTarget.nativeNavigationUnavailable)
        assertNull(flowTarget.path)
        assertEquals(639L, flowTarget.rowsHiddenMaxWidthPx)
        assertSame(figure, (flowScope.parts.single() as FlowPart.ImageFigure).figure)
        val oldFlowEntry = flowEntry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(flowTable.copy(rowsHiddenMaxWidthPx = null))))))
        assertNull(headingDestination(oldFlowEntry, "#figure-heading"))
        val collision = figureEntry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(figureTable), blockedHeading))))
        val collisionTarget = checkNotNull(headingDestination(collision, "#figure-heading"))
        assertTrue(collisionTarget.nativeNavigationUnavailable)
        assertNull(collisionTarget.path)
        assertEquals(639L, collisionTarget.rowsHiddenMaxWidthPx)
        val numericHeading = blockedHeading.copy(anchor = "reference-7", anchorFallback = "")
        val numericFigure = figure.copy(captionBlocks = listOf(numericHeading))
        val numericTable = grid(listOf(figureBlock.copy(figure = numericFigure)), 639L)
        val numericEntry = figureEntry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(numericTable)))))
        assertEquals(0, referenceTargetIndex(numericEntry, "#reference-7"))
        val numericTarget = checkNotNull(headingDestination(numericEntry, "#reference-7"))
        assertTrue(numericTarget.nativeNavigationUnavailable)
        assertNull(numericTarget.path)
        assertEquals(639L, numericTarget.rowsHiddenMaxWidthPx)
        val oldFigureTable = figureTable.copy(rowsHiddenMaxWidthPx = null)
        val oldFigureEntry = figureEntry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(oldFigureTable)))))
        assertNull(headingDestination(oldFigureEntry, "#figure-heading"))
        val oldCollision = oldFigureEntry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(oldFigureTable), blockedHeading))))
        assertFalse(checkNotNull(headingDestination(oldCollision, "#figure-heading")).nativeNavigationUnavailable)
        val oldNumericEntry = numericEntry.copy(sections = listOf(Section(3, "Body", listOf(tableBlock(numericTable.copy(rowsHiddenMaxWidthPx = null))))))
        assertNull(headingDestination(oldNumericEntry, "#reference-7"))
        assertEquals(0, referenceTargetIndex(oldNumericEntry, "#reference-7"))

        val legacyOuter = outer.copy(rowsHiddenMaxWidthPx = null, rows = listOf(listOf(
            outer.rows.single()[0].copy(blocks = listOf(own, tableBlock(high.copy(rowsHiddenMaxWidthPx = null)))),
            outer.rows.single()[1].copy(nestedTable = low.copy(rowsHiddenMaxWidthPx = null)))))
        val legacy = entry.copy(sections = listOf(entry.sections.single().copy(blocks = listOf(tableBlock(legacyOuter), outside))),
            references = listOf(reference.copy(blocks = listOf(tableBlock(noteTable.copy(rowsHiddenMaxWidthPx = null))))))
        assertFalse(legacy.hasTableRowVisibilityPolicy())
        (expected.map { it.first } + "note-heading").forEach { anchor ->
            assertEquals(headingDestination(entry, "#$anchor")!!.copy(rowsHiddenMaxWidthPx = null),
                headingDestination(legacy, "#$anchor"))
        }
        assertEquals(639L, outer.rowsHiddenMaxWidthPx)
        assertEquals(799L, noteTable.rowsHiddenMaxWidthPx)
        val legacyWrapper = wrapper.copy(blocks = listOf(tableBlock(legacyOuter.copy(captionBlocks = listOf(captionHeading)))))
        val legacyWrappedBlock = wrappedBlock.copy(container = legacyWrapper)
        val legacyWrappedEntry = legacy.copy(sections = listOf(legacy.sections.single().copy(blocks = listOf(legacyWrappedBlock, outside))))
        assertFalse(legacyWrappedBlock.hasTableRowVisibilityPolicy())
        assertNull(headingDestination(legacyWrappedEntry, "#high-heading"))
        assertNull(headingDestination(legacyWrappedEntry, "#caption-heading"))
    }

    @Test fun plainBoxOwnerAdviceKeepsBothOriginalCellOccurrencesAndRealTextOrder() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edge = InlineBoxBorderEdge.Dotted(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.Rgb("#445566"))
        val child = Span("text", "e")
        val owner = Span("text", "", tooltip = "Endrika mifarana", inlineBoxGroup = InlineBoxGroup(
            StyleEdges(zero, zero, zero, zero), InlineBoxBorderEdges(edge, edge, edge, edge), spans = listOf(child)))
        val first = listOf(Span("text", "one\u2009"), owner, Span("text", ","))
        val second = listOf(Span("text", "two\u2009"), owner, Span("link", "!", "real-target"))
        val table = Table(emptyList(), listOf(listOf(Cell(first, false, 1, 1), Cell(second, false, 1, 1))))
        val entry = Entry("advisory cells", emptyList(), "language", "Malagasy", "mg",
            listOf(Section(3, "Body", listOf(Block("table", 0, emptyList(), table = table)))), emptyList())
        val advice = entry.textDetails.filter { it.kind == TextDetailKind.Advisory }
        assertEquals(listOf("e", "e"), advice.map { it.label })
        assertEquals(listOf("Endrika mifarana", "Endrika mifarana"), advice.map { it.description })
        assertNotEquals(advice[0].context, advice[1].context)
        assertEquals("one\u2009e,", rubyGraphicalText(first))
        assertEquals("two\u2009e!", rubyGraphicalText(second))
        assertSame(owner, table.rows.single()[0].spans[1]); assertSame(owner, table.rows.single()[1].spans[1])
        assertSame(child, owner.inlineBoxGroup!!.spans.single())
        assertFalse(owner.hasInternalAction()); assertFalse(child.hasInternalAction())
        assertEquals("real-target", table.rows.single()[1].spans.last().target)
        assertTrue(entry.abbreviations.isEmpty())
    }

    @Test fun boxOwnerAdviceRetainsBorderTitleAcrossEmptyChildrenWithoutDuplicatingLinkedOwner() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val borders = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        fun box(children: List<Span>) = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), borders, spans = children)
        val inherited = Span("text", "a")
        val suppressed = Span("text", "b", tooltip = "")
        val nestedChild = Span("text", "c")
        val nestedSuppression = Span("text", "", tooltip = "", inlineBoxGroup = box(listOf(nestedChild)))
        val own = Span("text", "d", tooltip = "Child advice")
        val children = listOf(inherited, suppressed, nestedSuppression, own)
        val owner = Span("link", "", "actual-owner-target", tooltip = "Owner advice", inlineBoxGroup = box(children))
        val source = listOf(Span("text", "("), owner, Span("text", ")"))
        val entry = Entry("border advice", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(Block("paragraph", 0, source)))), emptyList())
        val advice = entry.textDetails.filter { it.kind == TextDetailKind.Advisory }
        // Empty titles suppress their child fragments, not the original parent's border/padding.
        // The linked fallback's inherited copies must not add separate a/c owner records.
        assertEquals(listOf("Owner advice", "Child advice"), advice.map { it.description })
        assertEquals(listOf("abcd", "d"), advice.map { it.label })
        assertEquals("(abcd)", rubyGraphicalText(source))
        assertNull(inherited.tooltip); assertEquals("", suppressed.tooltip)
        assertEquals("", nestedSuppression.tooltip); assertNull(nestedChild.tooltip)
        assertSame(children, owner.inlineBoxGroup!!.spans)
        assertSame(owner, entry.sections.single().blocks.single().spans[1])
        assertEquals("actual-owner-target", owner.target)
        assertTrue(owner.hasInternalAction()); assertTrue(children.none { it.hasInternalAction() })
        val untitled = owner.copy(tooltip = null)
        val empty = owner.copy(tooltip = "")
        for (withoutOwnerAdvice in listOf(untitled, empty)) {
            val other = entry.copy(sections = listOf(Section(3, "Body",
                listOf(Block("paragraph", 0, listOf(withoutOwnerAdvice))))))
            assertEquals(listOf("Child advice"), other.textDetails.map { it.description })
        }
    }

    @Test fun boxAdvicePreservesExistingSetAggregationAndIndependentImageAndLinkAdvice() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val borders = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val owner = Span("text", "", tooltip = "Same advice", inlineBoxGroup = InlineBoxGroup(
            StyleEdges(zero, zero, zero, zero), borders, spans = listOf(Span("text", "e"))))
        val image = Span("text", "", tooltip = "Raw image advice", image = InlineImage("Advice.svg", 15,
            alt = "Image name", tooltip = "Actual image advice"))
        val link = Span("link", "outside", "actual-link", tooltip = "Link advice")
        val source = listOf(owner, Span("text", " "), owner.copy(), image, link)
        val entry = Entry("advisory aggregation", emptyList(), "language", "English", "en",
            listOf(Section(3, "Body", listOf(Block("paragraph", 0, source)))), emptyList(),
            media = listOf(Media("Advice.svg", "image", "")))
        val advice = entry.textDetails.filter { it.kind == TextDetailKind.Advisory }
        // Existing details aggregate equal label/description/context, even across equal owners.
        assertEquals(listOf("Same advice", "Actual image advice", "Link advice"), advice.map { it.description })
        assertEquals(listOf("e", "Image name", "outside"), advice.map { it.label })
        assertSame(image, entry.sections.single().blocks.single().spans[3])
        assertSame(link, entry.sections.single().blocks.single().spans[4])
        assertEquals("actual-link", link.target)
        assertEquals("Raw image advice", image.tooltip)
        assertEquals("Actual image advice", image.image!!.tooltip)
        val noBox = entry.copy(sections = listOf(Section(3, "Body",
            listOf(Block("paragraph", 0, listOf(image, link))))))
        assertEquals(listOf("Actual image advice", "Link advice"), noBox.textDetails.map { it.description })
    }

    @Test fun publishedPolishEmptyEntryGetsNoticeWithoutChangingOriginalIdentityOrRows() {
        // Exact empty fields of retained pl-owner-000.stdout: czytać, selected owner polski.
        val entry = Entry("czytać", emptyList(), "language", "polski", "pl", emptyList(), emptyList(),
            organization = PresentationOrganization(emptyList(), emptyList()))
        val key = entry.key
        assertTrue(entryHasNoContent(entry))
        assertEquals("language\u0000polski\u0000czytać", key)
        assertEquals(emptyList<ReadingRow>(), entry.readingRows)
        assertEquals(1, entryReadingStartIndex(entry, emptySet()))
        assertEquals(1, entryReadingStartIndex(entry, setOf("preamble", "references", "media")))
        assertTrue(entryHasNoContent(entry.copy(displayTitle = listOf(Span("text", "czytać")))))
        assertTrue(entryHasNoContent(entry.copy(organization = null)))
        assertEquals(key, entry.key)
        assertTrue(entry.sections.isEmpty()); assertTrue(entry.preamble.isEmpty())
        assertTrue(entry.references.isEmpty()); assertTrue(entry.media.isEmpty())
    }

    @Test fun emptyEntryNoticeDoesNotReplaceAuthoredRowsAliasesMediaOrReferences() {
        val empty = Entry("czytać", emptyList(), "language", "polski", "pl", emptyList(), emptyList())
        val body = Block("definition", 0, listOf(Span("text", "Retained definition")))
        val source = listOf(Section(3, "Meaning", listOf(body)))
        val nonempty = empty.copy(sections = source)
        val reference = Reference(1, 1L, "", listOf(Span("text", "Retained reference")))
        val media = Media("Retained.ogg", "audio", "Retained audio")
        for (entry in listOf(nonempty,
            empty.copy(sections = listOf(Section(3, "Authored heading", emptyList()))),
            empty.copy(sections = listOf(Section(2, "", listOf(Block("blank", 0, emptyList()))))),
            empty.copy(preamble = listOf(Span("text", "Retained preamble"))),
            empty.copy(kind = "alias"),
            empty.copy(redirect = Redirect("czytać", "Target", "Meaning", false)),
            empty.copy(media = listOf(media)), empty.copy(references = listOf(reference)))) {
            assertFalse(entry.toString(), entryHasNoContent(entry))
        }
        assertSame(source, nonempty.sections); assertSame(body, nonempty.sections.single().blocks.single())
        assertEquals("heading-0", headingScrollKey(nonempty, "#Meaning"))
        assertFalse(entryHasNoContent(nonempty))
        assertEquals(listOf("heading-0"), visibleEntryReadingRows(nonempty, setOf("heading-0")).map { it.key })
        assertEquals(1, entryReadingStartIndex(nonempty, setOf("heading-0")))
        assertEquals(2, entryReadingStartIndex(empty.copy(preamble = listOf(Span("text", "About"))), emptySet()))
        val referenced = empty.copy(references = listOf(reference))
        assertSame(reference, referenced.references.single())
        assertEquals(1, metadataReferencesStartIndex(referenced, emptySet()))
    }
}
