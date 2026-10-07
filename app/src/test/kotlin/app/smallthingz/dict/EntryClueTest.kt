package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class EntryClueTest {
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
}
