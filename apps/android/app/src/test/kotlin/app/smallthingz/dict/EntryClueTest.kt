package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class EntryClueTest {

    @Test fun definitionClueKeepsPriorityWithoutSplittingSupplementaryTextAtCap() {
        val prose = Block("paragraph", 0, listOf(Span("text", "Fallback before the definition")))
        val text = "a".repeat(419) + "😀tail"
        val definition = Block("definition", 1, listOf(Span("text", text)))
        val clue = entry(prose, definition).clue()
        assertEquals("a".repeat(419), clue)
        assertTrue(clue.length <= 420)
        assertFalse(Character.isHighSurrogate(clue.last()))
        assertEquals(text, textOf(definition.spans))
    }

    @Test fun capturedAsBodyRemainsDiscoverableAfterHeadwordAndLanguageParagraphs() {
        fun paragraph(text: String) = Block("paragraph", 0, listOf(Span("text", text)))
        fun meaning() = Block("list_item", 2, listOf(Span("link", "অসমীয়া ", target = "অসমীয়া")), listPath = ":#", number = "1")
        val father = Entry("father", emptyList(), "language", "ইংৰাজী", "en", listOf(
            Section(1, "ইংৰাজী", emptyList()), Section(2, "নাম", listOf(paragraph("father"),
                Block("list_item", 2, listOf(Span("link", "জনক", target = "জনক")), listPath = ":#", number = "1")))), emptyList())
        val assamese = Entry("assamese", emptyList(), "language", "Unclassified", "", listOf(
            Section(2, "Unclassified", listOf(paragraph("ইংৰাজী"))),
            Section(2, "নাম", listOf(paragraph("assamese"), meaning())),
            Section(2, "বিশেষণ", listOf(paragraph("assamese"), meaning()))), emptyList())
        val before = listOf(father.sections, assamese.sections)
        assertEquals("father · জনক", father.clue())
        assertEquals("ইংৰাজী · assamese · অসমীয়া · assamese · অসমীয়া", assamese.clue())
        assertEquals(before, listOf(father.sections, assamese.sections))
        assertTrue(before.flatten().flatMap { it.blocks }.none { it.kind == "definition" })
    }

    @Test fun fallbackOmitsOnlyExplicitCompanionHeadingsAndMediaControls() {
        val heading = Block("heading", 0, listOf(Span("text", "নাম", bold = true)), level = 2)
        val control = Block("paragraph", 0, listOf(Span("link", "audio.wav", classes = "wikidict-media")))
        val headword = Block("paragraph", 0, listOf(Span("text", "headword")))
        val body = Block("list_item", 2, listOf(Span("text", "meaning")), listPath = ";#")
        val value = Entry("headword", emptyList(), "language", "Language", "und",
            listOf(Section(2, "নাম", listOf(heading, control, headword, body))), emptyList())
        assertSame(heading, sectionHeadingCompanion(value.sections.single()))
        assertEquals("headword · meaning", value.clue())
        assertEquals(listOf(heading, control, headword, body), value.sections.single().blocks)
    }

    @Test fun fallbackStopsAtItsExistingCapWithoutSplittingSupplementaryText() {
        val first = Block("paragraph", 0, listOf(Span("text", "a".repeat(410))))
        val second = Block("list_item", 1, listOf(Span("text", "😀".repeat(10))), listPath = "*")
        val last = Block("paragraph", 0, listOf(Span("text", "later body")))
        val clue = entry(first, second, last).clue()
        assertEquals("a".repeat(410) + " · " + "😀".repeat(3), clue)
        assertTrue(clue.length <= 420)
        assertFalse(Character.isHighSurrogate(clue.last()))
        assertFalse(clue.contains("later body"))
    }
    private fun actualAfEntry(): Entry = BlobDecoder.decode(
        requireNotNull(javaClass.getResourceAsStream("/af-spinal-cord.dpr2")).use { it.readBytes() },
        "spinal cord", "language", "Engels", "en"
    )

    private fun entry(vararg blocks: Block) = Entry(
        "word", emptyList(), "language", "Language", "und",
        listOf(Section(3, "Any heading", blocks.toList())), emptyList()
    )

    @Test fun actualAfMeaningFollowsMediaOnlyPronunciationWithoutChangingReaderContent() {
        val entry = actualAfEntry()
        assertFalse(entry.sections.flatMap { it.blocks }.any { it.kind == "definition" })
        assertEquals("(anatomie) Rugmurg", entry.clue())
        val pronunciation = entry.sections.single { it.title == "Uitspraak" }.blocks.single()
        assertTrue(textOf(pronunciation.spans).contains("LL-Q1860 (eng)-Vealhurl-spinal cord.wav"))
        assertTrue(entry.media.any { it.kind == "audio" })
    }

    @Test fun definitionsKeepPriorityAndOrdinaryFallbacksKeepTheirText() {
        val prose = Block("indent", 1, listOf(Span("link", "Useful linked prose", target = "word")))
        val definition = Block("definition", 1, listOf(Span("text", "Actual definition")))
        assertEquals("Actual definition", entry(prose, definition).clue())
        assertEquals("Useful linked prose", entry(prose).clue())
        assertEquals("lesson.wav", entry(Block("paragraph", 0, listOf(Span("text", "lesson.wav")))).clue())
        assertEquals("/wɜːd/", entry(Block("paragraph", 0, listOf(Span("text", "/wɜːd/", role = "pronunciation")))).clue())
    }

    @Test fun onlyExplicitMediaControlClassesAreExcludedFromPreviewText() {
        val controls = listOf(
            Span("link", "photo.png", classes = "thumbnail wikidict-media"),
            Span("text", " (", classes = "audiotable\tcompact"),
            Span("link", "file", classes = "audiotable"),
            Span("text", ")", classes = "audiotable")
        )
        assertEquals("Definition unavailable.", entry(Block("indent", 1, controls)).clue())
        assertEquals("Useful prose", entry(Block("paragraph", 0, controls + Span("text", " Useful prose"))).clue())
        assertEquals("Ordinary class", entry(Block("paragraph", 0,
            listOf(Span("text", "Ordinary class", classes = "wikidict-media-other")))).clue())
    }

    private fun resolvedAlias(): Entry {
        val edition = "afwiktionary-20261001"
        val source = WordHit("af-aliases", "spinal chord", "Engels", "language", 0, 0,
            recordKey = "1\tspinal chord", contextDictionary = "af-engels", edition = edition)
        return actualAfEntry().copy(edition = edition, origin = source,
            redirect = Redirect("spinal chord", "spinal cord", "", true))
    }

    private fun cached(entry: Entry): SavedWord {
        val source = requireNotNull(entry.origin)
        return SavedWord(entry.key, "spinal chord", "Engels", "language", "Old pronunciation filename preview",
            savedAt = 101, lastViewed = 202, views = 7,
            dictionary = source.dictionary, recordKey = source.recordKey,
            contextDictionary = source.contextDictionary, edition = entry.edition)
    }

    @Test fun exactScopedReopenRefreshesOnlyCluesWhenHistoryIsDisabled() {
        val entry = resolvedAlias()
        val old = cached(entry)
        val otherContext = old.copy(key = "other-context", contextDictionary = "af-afrikaans", language = "Afrikaans")
        val otherEdition = old.copy(key = "other-edition", dictionary = "other-aliases", edition = "enwiktionary-20260901")
        val ambiguousLegacy = old.copy(dictionary = null, recordKey = null, contextDictionary = null, edition = null)
        val wrongDictionary = old.copy(dictionary = "different-dictionary")
        val words = listOf(old, otherContext, otherEdition, ambiguousLegacy, wrongDictionary)
        val before = LearningData(history = words, bookmarks = words,
            study = mapOf(old.key to StudyStat(right = 3, wrong = 2, last = 303)),
            settings = AppSettings(historyEnabled = false))
        val after = before.recordEntry(entry, 999)
        val expected = listOf(old.copy(clue = "(anatomie) Rugmurg")) + words.drop(1)
        assertEquals(before.copy(history = expected, bookmarks = expected), after)
    }

    @Test fun ordinaryHistoryRecordingStillCountsTheReopenAndPreservesBookmarkMetadata() {
        val entry = resolvedAlias()
        val old = cached(entry)
        val before = LearningData(history = listOf(old), bookmarks = listOf(old),
            study = mapOf(old.key to StudyStat(right = 3, wrong = 2, last = 303)))
        val after = before.recordEntry(entry, 999)
        assertEquals(old.copy(clue = "(anatomie) Rugmurg"), after.bookmarks.single())
        assertEquals("spinal chord", after.history.single().title)
        assertEquals(8, after.history.single().views)
        assertEquals(999L, after.history.single().lastViewed)
        assertEquals("(anatomie) Rugmurg", after.history.single().clue)
        assertEquals(before.study, after.study)
        assertEquals(before.settings, after.settings)
    }
    private fun unscoped(dictionary: String): Entry = entry(
        Block("definition", 1, listOf(Span("text", "Definition from $dictionary")))
    ).copy(origin = WordHit(dictionary, "word", "Language", "language", 0, 4),
        contentDictionary = dictionary)

    private fun oldUnscoped(entry: Entry): SavedWord {
        val hit = requireNotNull(entry.origin)
        return SavedWord("language\u0000Language\u0000word", "word", "Language", "language", "Old clue",
            savedAt = 101, lastViewed = 202, views = 7,
            dictionary = hit.dictionary, recordKey = hit.recordKey,
            contextDictionary = hit.contextDictionary)
    }

    @Test fun retainedOriginsKeepUnscopedReadersAndHistoryDistinct() {
        val raw = unscoped("raw")
        val xz = unscoped("xz")
        assertEquals(raw.origin!!.key, raw.key)
        assertEquals(xz.origin!!.key, xz.key)
        assertNotEquals(raw.key, xz.key)
        assertEquals("language\u0000Language\u0000word", raw.copy(origin = null).key)
        val data = LearningData().recordEntry(raw, 10).recordEntry(xz, 20)
        assertEquals(listOf(xz.key, raw.key), data.history.map { it.key })
        assertEquals(listOf("xz", "raw"), data.history.map { it.dictionary })
        assertEquals(listOf(1, 1), data.history.map { it.views })
    }

    @Test fun provenUnscopedRowsMigrateWhileUnprovenStudyStateStaysAtItsOldKey() {
        val entry = unscoped("raw")
        val old = oldUnscoped(entry)
        val stats = StudyStat(right = 3, wrong = 2, last = 303)
        for (enabled in listOf(false, true)) {
            val before = LearningData(history = listOf(old), bookmarks = listOf(old),
                study = mapOf(old.key to stats, "unrelated" to StudyStat(right = 8)),
                settings = AppSettings(historyEnabled = enabled))
            val after = before.recordEntry(entry, 999)
            val migrated = old.copy(key = entry.key, clue = entry.clue())
            assertEquals(listOf(migrated), after.bookmarks)
            if (enabled) {
                assertEquals(entry.key, after.history.single().key)
                assertEquals(8, after.history.single().views)
                assertEquals(999L, after.history.single().lastViewed)
                assertEquals(old.dictionary, after.history.single().dictionary)
            } else assertEquals(listOf(migrated), after.history)
            assertEquals(before.study, after.study)
            assertFalse(entry.key in after.study)
            assertEquals(before.settings, after.settings)
            if (!enabled) assertEquals(after, after.recordEntry(entry, 999))
        }
    }

    @Test fun unresolvedOrDifferentLegacyClaimsRemainUnchanged() {
        val entry = unscoped("raw")
        val old = oldUnscoped(entry)
        val unrelated = listOf(
            old.copy(dictionary = null, recordKey = null),
            old.copy(dictionary = "other"),
            old.copy(recordKey = "other"),
            old.copy(contextDictionary = "other"),
            old.copy(edition = "otherwiktionary-20261001"),
        )
        for (other in unrelated) {
            val before = LearningData(history = listOf(old, other), bookmarks = listOf(old, other),
                study = mapOf(old.key to StudyStat(right = 3)),
                settings = AppSettings(historyEnabled = false))
            val after = before.recordEntry(entry, 999)
            assertEquals(listOf(old.copy(key = entry.key, clue = entry.clue()), other), after.history)
            assertEquals(after.history, after.bookmarks)
            assertEquals(before.study, after.study)
        }
        val duplicate = LearningData(history = listOf(old, old), bookmarks = listOf(old, old),
            study = mapOf(old.key to StudyStat(right = 3)), settings = AppSettings(historyEnabled = false))
        assertEquals(duplicate, duplicate.recordEntry(entry, 999))
    }

    @Test fun existingTargetRowsAndStudyStateAreNotOverwrittenByLegacyMigration() {
        val entry = unscoped("raw")
        val old = oldUnscoped(entry)
        val target = old.copy(key = entry.key, savedAt = 404, lastViewed = 505, views = 20)
        for (enabled in listOf(false, true)) {
            val before = LearningData(history = listOf(target, old), bookmarks = listOf(target, old),
                study = mapOf(old.key to StudyStat(right = 3), entry.key to StudyStat(right = 9)),
                settings = AppSettings(historyEnabled = enabled))
            val after = before.recordEntry(entry, 999)
            assertEquals(listOf(target.copy(clue = entry.clue()), old), after.bookmarks)
            assertEquals(old, after.history.last())
            assertEquals(if (enabled) 21 else 20, after.history.first().views)
            assertEquals(if (enabled) 999L else target.lastViewed, after.history.first().lastViewed)
            assertEquals(before.study, after.study)
        }
    }

    @Test fun existingTargetStudySurvivesAnOtherwiseProvenRowMigration() {
        val entry = unscoped("raw")
        val old = oldUnscoped(entry)
        val before = LearningData(history = listOf(old), bookmarks = listOf(old),
            study = mapOf(old.key to StudyStat(right = 3), entry.key to StudyStat(right = 9)),
            settings = AppSettings(historyEnabled = false))
        val after = before.recordEntry(entry, 999)
        assertEquals(listOf(entry.key), after.history.map { it.key })
        assertEquals(listOf(entry.key), after.bookmarks.map { it.key })
        assertEquals(before.study, after.study)
    }
}
