package app.smallthingz.dict

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.*
import org.junit.Test

class LanguageOwnerFragmentTest {
    private val edition = "kuwiktionary-20261101"
    private fun dictionary(id: String, language: String, code: String = "", kind: String = "language",
        sourceEdition: String = edition) = DictionaryInfo(id, language, code, kind, 1, 1L, sourceEdition)
    private val kurmanji = dictionary("installed-ku-hash", "kurmancî", "ku")
    private val zazaki = dictionary("installed-zza-hash", "zazakî", "zza")
    private fun source() = Entry("şeş", emptyList(), "language", "zazakî", "zza",
        emptyList(), emptyList(), edition = edition)

    @Test fun languageOwnerUsesExactLabelBeforeUniqueUnicodeCaseInsensitiveMatch() {
        val action = EntryLink("şeş#Kurmancî")
        val owners = listOf(dictionary("unclassified", "Unclassified"), kurmanji, zazaki)
        assertSame(kurmanji, installedLinkOwner(action, source(), owners))
        assertSame(kurmanji, installedLinkOwner(EntryLink("şeş", "KURMANCÎ"), source(), owners))
        assertEquals("installed-ku-hash", installedLinkOwner(action, source(), owners)?.id)
        assertEquals("kurmancî", installedLinkOwner(action, source(), owners)?.language)
        assertEquals("şeş#Kurmancî", action.target)
        assertEquals("Kurmancî", action.fragment)
        assertNull(action.targetFragment)

        val exact = dictionary("capital-label-hash", "Kurmancî")
        for (order in listOf(listOf(kurmanji, exact), listOf(exact, kurmanji)))
            assertSame(exact, installedLinkOwner(action, source(), order))
        val ancient = dictionary("ancient-greek-hash", "Ancient Greek", "grc")
        assertSame(ancient, installedLinkOwner(EntryLink("κρώζω#Ancient_Greek"), source(), listOf(ancient)))
        assertSame(ancient, installedLinkOwner(EntryLink("κρώζω", "Ancient_Greek"), source(), listOf(ancient)))
        // A code is never an owner label, even when it is the installed language's code.
        assertNull(installedLinkOwner(EntryLink("şeş#ku"), source(), owners))
    }

    @Test fun languageOwnerRefusesAmbiguousForeignAndNonLanguageCandidates() {
        val action = EntryLink("şeş", "KURMANCÎ")
        val capital = dictionary("capital-label-hash", "Kurmancî")
        for (order in listOf(listOf(kurmanji, capital), listOf(capital, kurmanji)))
            assertNull(installedLinkOwner(action, source(), order))
        val foreign = dictionary("foreign-hash", "KURMANCÎ", sourceEdition = "other-edition")
        val supplemental = dictionary("supplemental-hash", "KURMANCÎ", kind = "supplemental")
        assertNull(installedLinkOwner(action, source(), listOf(foreign, supplemental)))
        assertSame(kurmanji, installedLinkOwner(action, source(), listOf(foreign, supplemental, kurmanji)))
        assertNull(installedLinkOwner(action, source().copy(edition = ""), listOf(kurmanji)))
        assertNull(installedLinkOwner(action, source().copy(navigationKind = "supplemental"), listOf(kurmanji)))
        assertNull(installedLinkOwner(action, source().copy(navigationLanguage = null), listOf(kurmanji)))
        for (target in listOf(EntryLink("şeş"), EntryLink("şeş", ""), EntryLink("şeş#Usage_notes"),
            EntryLink("şeş#Missing owner")))
            assertNull(installedLinkOwner(target, source(), listOf(kurmanji, zazaki)))
        // Owner selection is independent of word presence: an explicit owner's miss must
        // remain that owner's miss in LibraryStore.link, never choose the current homograph.
        assertSame(kurmanji, installedLinkOwner(EntryLink("absent#Kurmancî"), source(), listOf(kurmanji, zazaki)))
        assertEquals("KURMANCÎ", action.fragment)
    }

    @Test fun languageOwnerNavigationKeepsOriginalFragmentAndExactBackVisit() = runBlocking {
        withTimeout(5_000) {
            val owners = listOf(kurmanji, zazaki)
            val from = WordHit(zazaki.id, "şeş", zazaki.language, "language", 0, 1, edition = edition)
            val destination = WordHit(kurmanji.id, "şeş", kurmanji.language, "language", 0, 1, edition = edition)
            val entries = mapOf(from.key to source().copy(origin = from, contentDictionary = from.dictionary), destination.key to
                source().copy(language = kurmanji.language, languageCode = kurmanji.code,
                    navigationLanguage = kurmanji.language, origin = destination, contentDictionary = destination.dictionary))
            val committed = mutableListOf<Pair<WordHit, EntryLink>>()
            val restored = mutableListOf<WordHit>()
            val errors = mutableListOf<String>()
            val lookups = mutableListOf<String>()
            var visits = EntryVisitState()
            val navigation = EntryNavigation(this, { hit -> checkNotNull(entries[hit.key]) },
                { target, entry ->
                    val owner = installedLinkOwner(target, entry, owners)
                    val language = owner?.language ?: entry.navigationLanguage.orEmpty()
                    lookups += language
                    listOf(from, destination).singleOrNull { it.title == target.title && it.language == language }
                }, { null }, { null }, { null },
                { hit, _, target -> committed += hit to target }, {}, { errors += it },
                installed = { id -> owners.any { it.id == id } },
                visitsChanged = { visits = it }, restore = { hit, _ -> restored += hit })
            try {
                navigation.open(from).join()
                val originalVisit = visits.currentId
                for (action in listOf(EntryLink("şeş#Kurmancî"), EntryLink("şeş", "Kurmancî"))) {
                    navigation.openLink(action, checkNotNull(entries[from.key])).join()
                    assertEquals(destination, committed.last().first)
                    assertSame(action, committed.last().second)
                    assertEquals("Kurmancî", committed.last().second.fragment)
                    assertEquals("kurmancî", lookups.last())
                    assertNotEquals(originalVisit, visits.currentId)
                    assertTrue(navigation.goBack())
                    yield()
                    assertEquals(from, restored.last())
                    assertEquals(originalVisit, visits.currentId)
                }
                navigation.openLink(EntryLink("missing#Kurmancî"), checkNotNull(entries[from.key])).join()
                assertEquals(3, committed.size) // Initial visit and the two successful actions only.
                assertEquals(listOf("This word is not in your installed dictionaries."), errors)
                assertEquals(originalVisit, visits.currentId)
            } finally { navigation.cancel() }
        }
    }

    @Test fun ordinaryFallbackKeepsCurrentAndUnclassifiedPrecedenceBeforeUniqueOwner() {
        val source = source()
        fun hit(owner: String, title: String = "Gvangjcouh") =
            WordHit(owner, title, owner, "language", 0, 1, edition = edition)
        val zhuang = hit("Vahcuengh")
        val other = hit("Other")
        val ownerless = hit("Unclassified")
        val current = hit(source.language.orEmpty(), "GVANGJCOUH")
        val queries = mutableListOf<OrdinaryLinkQuery>()
        var rows = listOf(zhuang)
        fun exact(query: OrdinaryLinkQuery): List<WordHit> {
            queries += query
            return rows.filter { it.edition == query.edition && it.kind == query.kind && it.title == query.title &&
                (query.language == null || it.language == query.language) }
        }
        assertSame(current, ordinaryLinkChoices("Gvangjcouh", source, current, null, ::exact).singleOrNull())
        assertTrue(queries.isEmpty()) // Existing folded current-owner result still wins.
        rows = listOf(other, ownerless, zhuang)
        assertSame(ownerless, ordinaryLinkChoices("Gvangjcouh", source, null, null, ::exact).singleOrNull())
        assertEquals(listOf(OrdinaryLinkQuery("Gvangjcouh", edition, "language", "Unclassified")), queries)
        queries.clear()
        rows = listOf(zhuang) // No Unclassified dictionary is required.
        assertSame(zhuang, ordinaryLinkChoices("Gvangjcouh", source, null, null, ::exact).singleOrNull())
        assertEquals(listOf("Unclassified", null), queries.map { it.language })
        assertTrue(queries.all { it.title == "Gvangjcouh" && it.edition == edition && it.kind == "language" })
        queries.clear()
        for (guarded in listOf(source.copy(edition = ""), source.copy(kind = "supplemental"),
            source.copy(navigationKind = "supplemental"), source.copy(navigationLanguage = null),
            source.copy(redirect = Redirect("old", "new", "Noun", true))))
            assertNull(ordinaryLinkChoices("Gvangjcouh", guarded, null, null, ::exact).singleOrNull())
        assertNull(ordinaryLinkChoices("Gvangjcouh", source, null, kurmanji, ::exact).singleOrNull())
        assertTrue(queries.isEmpty()) // Explicit owner misses and redirects never broaden.
    }

    @Test fun ordinaryFallbackRefusesAmbiguityAndRetainsExactEditionKindAndTitleScope() {
        val source = source()
        val base = WordHit("za", "Gvangjcouh", "Vahcuengh", "language", 0, 1, edition = edition)
        var rows = listOf(base.copy(edition = "other-edition"), base.copy(kind = "supplemental"),
            base.copy(title = "GVANGJCOUH"), base.copy(title = "Gvangjcouh suffix"))
        val queries = mutableListOf<OrdinaryLinkQuery>()
        fun exact(query: OrdinaryLinkQuery): List<WordHit> {
            queries += query
            return rows.filter { it.edition == query.edition && it.kind == query.kind && it.title == query.title &&
                (query.language == null || it.language == query.language) }
        }
        assertNull(ordinaryLinkChoices("Gvangjcouh", source, null, null, ::exact).singleOrNull())
        assertNull(ordinaryLinkChoices("missing", source, null, null, ::exact).singleOrNull())
        val second = base.copy(dictionary = "second", language = "Second owner")
        val third = base.copy(dictionary = "third", language = "Third owner")
        for (order in listOf(listOf(base, second, third), listOf(third, second, base))) {
            rows = order
            val choices = ordinaryLinkChoices("Gvangjcouh", source, null, null, ::exact)
            assertEquals(order, choices)
            assertNull(choices.singleOrNull())
        }
        // Even a malformed duplicate Unclassified result must not fall through to another owner.
        rows = listOf(base.copy(dictionary = "u1", language = "Unclassified"),
            base.copy(dictionary = "u2", language = "Unclassified"), base)
        queries.clear()
        assertNull(ordinaryLinkChoices("Gvangjcouh", source, null, null, ::exact).singleOrNull())
        assertEquals(1, queries.size)
        assertEquals("Unclassified", queries.single().language)
    }

    @Test fun ordinaryFallbackNavigationPreservesFragmentsFailedVisitsAndExactBackOwner() = runBlocking {
        withTimeout(5_000) {
            val from = WordHit("english", "Canton", "English", "language", 0, 1, edition = edition)
            val to = WordHit("za", "Gvangjcouh#literal", "Vahcuengh", "language", 0, 1, edition = edition)
            fun body(hit: WordHit) = Entry(hit.title, emptyList(), hit.kind, hit.language, "", emptyList(), emptyList(),
                edition = hit.edition, origin = hit, contentDictionary = hit.dictionary)
            val entries = mapOf(from.key to body(from), to.key to body(to))
            var candidates = listOf(to)
            val committed = mutableListOf<Pair<WordHit, EntryLink>>()
            val restored = mutableListOf<WordHit>()
            val reads = mutableListOf<WordHit>()
            val errors = mutableListOf<String>()
            var queries = 0
            var visits = EntryVisitState()
            val navigation = EntryNavigation(this, { hit -> reads += hit; checkNotNull(entries[hit.key]) },
                { target, entry -> ordinaryLinkChoices(target.title, entry, null, null) { query ->
                    queries++
                    candidates.filter { it.title == query.title && it.edition == query.edition && it.kind == query.kind &&
                        (query.language == null || it.language == query.language) }
                }.singleOrNull() }, { null }, { null }, { null }, { hit, _, target -> committed += hit to target }, {}, { errors += it },
                installed = { true }, restore = { hit, _ -> restored += hit }, visitsChanged = { visits = it })
            try {
                navigation.open(from).join()
                val originalVisit = visits.currentId
                val action = EntryLink("Gvangjcouh#literal", "Noun#part")
                navigation.openLink(action, checkNotNull(entries[from.key])).join()
                assertEquals(to, committed.last().first)
                assertSame(action, committed.last().second)
                assertNotEquals(originalVisit, visits.currentId)
                val targetVisit = visits.currentId
                candidates = listOf(to, to.copy(dictionary = "other", language = "Other owner"))
                navigation.openLink(action, checkNotNull(entries[from.key])).join()
                navigation.openLink(EntryLink("missing"), checkNotNull(entries[from.key])).join()
                assertEquals(2, committed.size)
                assertEquals(2, errors.size)
                assertEquals(targetVisit, visits.currentId)
                val beforeBack = queries
                assertTrue(navigation.goBack())
                while (restored.isEmpty()) yield()
                assertEquals(listOf(from), restored)
                assertEquals(listOf(from, to, from), reads)
                assertEquals(beforeBack, queries) // Back never repeats a now-ambiguous title lookup.
                assertEquals(originalVisit, visits.currentId)
                assertFalse(navigation.goBack())
            } finally { navigation.cancel() }
        }
    }
}
