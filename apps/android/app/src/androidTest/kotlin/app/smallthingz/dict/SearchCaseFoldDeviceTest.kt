package app.smallthingz.dict

import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.os.Looper
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class SearchCaseFoldDeviceTest {
    private val expectedKeys = linkedMapOf(
        "ΣΊΣΥΦΟΣ" to "σίσυφοσ",
        "σίσυφος" to "σίσυφοσ",
        "Straße" to "strasse",
        "STRASSE" to "strasse",
        "\uD801\uDC00bc" to "\uD801\uDC28bc",
        "\uFEFFΣΊΣΥΦΟΣ" to "\uFEFFσίσυφοσ",
        "\uFB03xture" to "ffixture",
        "Prefix\uDBFF\uDFFF" to "prefix\uDBFF\uDFFF",
        "Prefix\uDBFF\uDFFFtail" to "prefix\uDBFF\uDFFFtail",
        "Prefiy" to "prefiy",
        "\uDBFF\uDFFF" to "\uDBFF\uDFFF",
        "\uDBFF\uDFFFtail" to "\uDBFF\uDFFFtail",
        "\uDBFF\uDFFF\uDBFF\uDFFFtail" to "\uDBFF\uDFFF\uDBFF\uDFFFtail",
        "\uD7FFedge" to "\uD7FFedge",
        "\uE000outside" to "\uE000outside",
    )

    @Test fun componentLookupKeepsLiteralHashTitlesSeparateFromLegacyFragments(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue(context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        val heading = "Component owner"
        val edition = "components${UUID.randomUUID().toString().replace("-", "")}wiktionary-20261001"
        val ownerHash = MessageDigest.getInstance("SHA-256").digest(heading.toByteArray()).joinToString("") { "%02x".format(it) }
        val titles = listOf("Source", "Literal", "Literal#title", "Literal%23title", "Literal#title?&語", "Literal_title", "Literal title")
        try {
            library.importFile(name = { "$edition-$ownerHash.wikblb" }) { ByteArrayInputStream(dictionary(heading, titles)) }.join()
            assertNull(library.error)
            val source = library.read(checkNotNull(library.exact("Source", heading, edition)))
            assertEquals("Literal", library.link(EntryLink("Literal#title"), source)?.title)
            assertEquals("Literal#title", library.link(EntryLink("Literal#title", ""), source)?.title)
            assertEquals("Literal#title", library.link(EntryLink("Literal#title", "Noun#part"), source)?.title)
            assertEquals("Literal%23title", library.link(EntryLink("Literal%23title", ""), source)?.title)
            assertEquals("Literal#title?&語", library.link(EntryLink("Literal#title?&語", ""), source)?.title)
            assertEquals("Literal title", library.link(EntryLink("Literal_title"), source)?.title)
            assertEquals("Literal_title", library.link(EntryLink("Literal_title", ""), source)?.title)
            assertEquals("Literal_title", library.link(EntryLink("Literal_title", "Noun"), source)?.title)
        } finally {
            library.dictionaries.filter { it.edition == edition }.forEach { library.remove(it.id).join() }
        }
    }

    @Test fun importedUnicodePrefixesFoldWithoutLosingExactTitlePreference(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue(context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        val heading = "Casefold Greek"
        val edition = "casefold${UUID.randomUUID().toString().replace("-", "")}wiktionary-20261001"
        val hash = MessageDigest.getInstance("SHA-256").digest(heading.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        val fixture = dictionary(heading, expectedKeys.keys.toList())
        try {
            library.importFile(name = { "$edition-$hash.wikblb" }) { ByteArrayInputStream(fixture) }.join()
            assertNull(library.error)
            val installed = library.dictionaries.single { it.edition == edition }
            suspend fun titles(prefix: String) = library.search(prefix)
                .filter { it.dictionary == installed.id }.map { it.title }.toSet()
            assertEquals(setOf("ΣΊΣΥΦΟΣ", "σίσυφος"), titles("ΣΊΣ"))
            assertEquals(setOf("ΣΊΣΥΦΟΣ", "σίσυφος"), titles("σίσ"))
            assertEquals(setOf("Straße", "STRASSE"), titles("STRASS"))
            assertEquals(setOf("\uD801\uDC00bc"), titles("\uD801\uDC28"))
            assertEquals(setOf("\uFEFFΣΊΣΥΦΟΣ"), titles("\uFEFFΣΊΣ"))
            assertEquals(setOf("\uFB03xture"), titles("FFI"))
            val maximum = "\uDBFF\uDFFF"
            assertEquals(setOf("Prefix$maximum", "Prefix${maximum}tail"), titles("PREFIX"))
            assertEquals(setOf("Prefix$maximum", "Prefix${maximum}tail"), titles("PREFIX$maximum"))
            assertEquals(setOf(maximum, "${maximum}tail", "$maximum${maximum}tail"), titles(maximum))
            assertEquals(setOf("$maximum${maximum}tail"), titles("$maximum$maximum"))
            assertEquals(setOf("\uD7FFedge"), titles("\uD7FF"))
            assertEquals(setOf("\uE000outside"), titles("\uE000"))
            for (title in expectedKeys.keys) {
                val exact = library.exact(title, heading, edition)!!
                assertEquals(title, exact.title)
                assertEquals(title, exact.recordKey)
            }
            val fallback = library.exact("strasse", heading, edition)!!
            assertTrue(fallback.title in setOf("Straße", "STRASSE"))
            val source = library.read(library.exact("Straße", heading, edition)!!)
            assertEquals("STRASSE", library.link(EntryLink("STRASSE"), source)!!.title)
            assertEquals("ΣΊΣΥΦΟΣ", library.link(EntryLink("ΣΊΣΥΦΟΣ"), source)!!.title)
        } finally {
            library.dictionaries.filter { it.edition == edition }.forEach { library.remove(it.id).join() }
        }
        verifyExplicitLanguageOwnerFragments(library)
    }

    private suspend fun verifyExplicitLanguageOwnerFragments(library: LibraryStore) = kotlinx.coroutines.coroutineScope {
        val edition = "ownernav${UUID.randomUUID().toString().replace("-", "")}wiktionary-20261001"
        val otherEdition = "other$edition"
        val editions = setOf(edition, otherEdition)
        suspend fun install(owner: String, code: String, selectedEdition: String, titles: List<String>) {
            val bytes = dictionary(owner, titles, code)
            val hash = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            library.importFile(name = { "$selectedEdition-$hash.wikblb" }) { ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
        }
        try {
            install("Greek", "el", edition, listOf("κρώζω", "μόνο"))
            install("Ancient Greek", "grc", edition, listOf("κρώζω"))
            install("Latin", "la", otherEdition, listOf("κρώζω"))
            val modern = library.read(requireNotNull(library.exact("κρώζω", "Greek", edition)))
            val ancient = library.read(requireNotNull(library.exact("κρώζω", "Ancient Greek", edition)))
            val explicit = requireNotNull(library.link(EntryLink("κρώζω#Ancient Greek"), modern))
            assertEquals("Ancient Greek", explicit.language)
            assertEquals(edition, explicit.edition)
            assertEquals("grc", library.read(explicit).languageCode)
            assertEquals(explicit.key, library.link(EntryLink("κρώζω#Ancient_Greek"), modern)?.key)
            assertEquals(ancient.origin?.key, explicit.key)
            assertEquals(modern.origin?.key, library.link(EntryLink("κρώζω#Greek"), ancient)?.key)
            // Installed owner but absent entry must not fall back to the modern homograph.
            assertNull(library.link(EntryLink("μόνο#Ancient Greek"), modern))
            // Ordinary subsections and owners absent from this edition keep existing lookup behavior.
            for (target in listOf("κρώζω", "κρώζω#Etymology_2", "κρώζω#Missing owner", "κρώζω#Latin"))
                assertEquals(modern.origin?.key, library.link(EntryLink(target), modern)?.key)
            val legacy = modern.copy(edition = "")
            assertEquals(modern.origin?.key, library.link(EntryLink("κρώζω#Ancient Greek"), legacy)?.key)
            val supplemental = modern.copy(navigationKind = "supplemental", navigationLanguage = null)
            assertNull(library.link(EntryLink("κρώζω#Ancient Greek"), supplemental))

            val committed = mutableListOf<Triple<WordHit, Entry, EntryLink>>()
            val errors = mutableListOf<String>()
            val navigation = EntryNavigation(this, library::read, library::link, library::savedWord,
                library::random, { null }, { hit, entry, target -> committed += Triple(hit, entry, target) },
                {}, { errors += it }, { id -> library.dictionaries.any { it.id == id } })
            try {
                navigation.openLink(EntryLink("κρώζω#Ancient_Greek"), modern).join()
                val (hit, entry, target) = committed.single()
                assertEquals(explicit.key, hit.key)
                assertEquals(explicit.key, entry.origin?.key)
                assertEquals("Ancient Greek", entry.language)
                assertEquals(EntryLink("κρώζω#Ancient_Greek"), target)
                assertTrue(errors.isEmpty())
                navigation.openLink(EntryLink("μόνο#Ancient Greek"), modern).join()
                assertEquals(1, committed.size)
                assertEquals(listOf("This word is not in your installed dictionaries."), errors)
            } finally { navigation.cancel() }
        } finally {
            library.dictionaries.filter { it.edition in editions }.forEach { library.remove(it.id).join() }
        }
    }

    @Test fun ordinaryLinksKeepExactSameEditionUnclassifiedPrecedence(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue(context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        val edition = "unclassifiedlink${UUID.randomUUID().toString().replace("-", "")}wiktionary-20261001"
        val otherEdition = "other$edition"
        val editions = setOf(edition, otherEdition)
        val beforeIds = library.dictionaries.map { it.id }.toSet()
        suspend fun install(owner: String, code: String, selectedEdition: String, titles: List<String>) {
            val bytes = dictionary(owner, titles, code)
            val hash = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            library.importFile(name = { "$selectedEdition-$hash.wikblb" }) { ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
        }
        try {
            install("aragonés", "an", edition, listOf("templlar", "same", "LOCAL"))
            install("Unclassified", "", edition, listOf("templlar/conj.BEN", "same", "local", "ExactOnly"))
            install("Other owner", "en", edition, listOf("elsewhere"))
            install("Unclassified", "", otherEdition, listOf("foreign-only"))
            val source = library.read(requireNotNull(library.exact("templlar", "aragonés", edition)))
            val target = requireNotNull(library.exact("templlar/conj.BEN", "Unclassified", edition))
            val hit = requireNotNull(library.link(EntryLink("templlar/conj.BEN"), source))
            assertEquals(target.key, hit.key)
            assertEquals("Unclassified", hit.language)
            assertEquals(edition, hit.edition)
            assertEquals(target.key, library.link(EntryLink("templlar/conj.BEN#Conjugation"), source)?.key)
            assertEquals(library.exact("same", "aragonés", edition)?.key, library.link(EntryLink("same"), source)?.key)
            // Keep the old current-owner folded match ahead of an exact unowned match.
            assertEquals("LOCAL", library.link(EntryLink("local"), source)?.title)
            assertNull(library.link(EntryLink("exactonly"), source))
            assertEquals("Other owner", library.link(EntryLink("elsewhere"), source)?.language)
            assertNull(library.link(EntryLink("foreign-only"), source))
            assertNull(library.link(EntryLink("templlar/conj.BEN#Other_owner"), source))
            assertNull(library.link(EntryLink("templlar/conj.BEN#aragonés"), source))
            assertEquals(target.key, library.link(EntryLink("templlar/conj.BEN#Unclassified"), source)?.key)
            assertNull(library.link(EntryLink("templlar/conj.BEN"), source.copy(edition = "")))
            assertNull(library.link(EntryLink("templlar/conj.BEN"), source.copy(kind = "supplemental", navigationKind = "supplemental", navigationLanguage = null)))
            assertNull(library.link(EntryLink("templlar/conj.BEN"), source.copy(redirect = Redirect("old", "templlar", "", true))))
            val committed = mutableListOf<Triple<WordHit, Entry, EntryLink>>()
            val errors = mutableListOf<String>()
            val navigation = EntryNavigation(this, library::read, library::link, library::savedWord,
                library::random, { null }, { selected, entry, action -> committed += Triple(selected, entry, action) },
                {}, { errors += it }, { id -> library.dictionaries.any { it.id == id } })
            try {
                navigation.open(requireNotNull(source.origin)).join()
                navigation.openLink(EntryLink("templlar/conj.BEN#Conjugation"), source).join()
                val (selected, entry, action) = committed.last()
                assertEquals(2, committed.size)
                assertEquals(target.key, selected.key)
                assertEquals(target.key, entry.origin?.key)
                assertEquals("Unclassified", entry.language)
                assertEquals(EntryLink("templlar/conj.BEN#Conjugation"), action)
                assertTrue(errors.isEmpty())
                navigation.openLink(EntryLink("templlar/conj.BEN#Other_owner"), source).join()
                assertEquals(2, committed.size)
                assertEquals(listOf("This word is not in your installed dictionaries."), errors)
                assertTrue(navigation.goBack())
                kotlinx.coroutines.withTimeout(5_000) {
                    while (committed.size != 3) kotlinx.coroutines.yield()
                }
                assertEquals(source.origin?.key, committed.last().first.key)
                assertFalse(navigation.goBack())
            } finally { navigation.cancel() }
            val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
            val release = kotlinx.coroutines.CompletableDeferred<Unit>()
            val cancelledCommits = mutableListOf<WordHit>()
            val cancelledErrors = mutableListOf<String>()
            val cancelled = EntryNavigation(this, library::read, { action, entry ->
                val resolved = library.link(action, entry)
                entered.complete(Unit)
                release.await()
                resolved
            }, library::savedWord, library::random, { null }, { selected, _, _ -> cancelledCommits += selected },
                {}, { cancelledErrors += it }, { id -> library.dictionaries.any { it.id == id } })
            try {
                val pending = cancelled.openLink(EntryLink("templlar/conj.BEN"), source)
                kotlinx.coroutines.withTimeout(5_000) { entered.await() }
                cancelled.cancel()
                release.complete(Unit)
                pending.join()
                assertTrue(cancelledCommits.isEmpty())
                assertTrue(cancelledErrors.isEmpty())
            } finally { cancelled.cancel(); release.complete(Unit) }
        } finally {
            library.dictionaries.filter { it.edition in editions }.forEach { library.remove(it.id).join() }
            assertEquals(beforeIds, library.dictionaries.map { it.id }.toSet())
        }
    }


    @Test fun ordinaryLinksFindOneExactOtherOwnerAndBackRetainsItsOriginalVisit(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue(context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        val edition = "zafallback${UUID.randomUUID().toString().replace("-", "")}wiktionary-20261001"
        val otherEdition = "other$edition"
        val editions = setOf(edition, otherEdition)
        val before = library.dictionaries.map { it.id }.toSet()
        suspend fun install(owner: String, code: String, selectedEdition: String, titles: List<String>) {
            val bytes = dictionary(owner, titles, code)
            val hash = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray()).joinToString("") { "%02x".format(it) }
            library.importFile(name = { "$selectedEdition-$hash.wikblb" }) { ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
        }
        try {
            install("English", "en", edition, listOf("Canton"))
            install("Vahcuengh", "za", edition, listOf("Gvangjcouh", "Ambiguous", "Ownerless", "Literal#title", "Under_score", "Under score"))
            install("Other owner", "fr", edition, listOf("Ambiguous", "Ownerless", "Canton"))
            install("Dutch", "nl", edition, listOf("Canton"))
            install("Foreign owner", "za", otherEdition, listOf("ForeignOnly", "Gvangjcouh"))
            // Reuse the valid maintained entry payload with an ordinary supplemental header.
            val languageBytes = dictionary("Supplemental donor", listOf("KindOnly"))
            var records = 9
            repeat(2) { while (languageBytes[records++].toInt() != 0) Unit }
            val supplemental = "WIKBLB08".toByteArray() + byteArrayOf(7) + languageBytes.copyOfRange(records, languageBytes.size)
            library.importFile(name = { "$edition-supplemental.wikblb" }) { ByteArrayInputStream(supplemental) }.join()
            assertNull(library.error)
            val from = requireNotNull(library.exact("Canton", "English", edition))
            val source = library.read(from)
            val expected = requireNotNull(library.exact("Gvangjcouh", "Vahcuengh", edition))
            assertFalse(library.dictionaries.any { it.edition == edition && it.language == "Unclassified" })
            val found = requireNotNull(library.link(EntryLink("Gvangjcouh"), source))
            assertEquals(expected, found)
            assertEquals("Vahcuengh", library.read(found).language)
            assertEquals("za", library.read(found).languageCode)
            for (target in listOf("Ambiguous", "Missing", "ForeignOnly", "KindOnly", "gvangjcouh"))
                assertNull(target, library.link(EntryLink(target), source))
            assertNull(library.link(EntryLink("Gvangjcouh", "Other_owner"), source))
            assertEquals("Literal#title", library.link(EntryLink("Literal#title", "Noun#part"), source)?.title)
            assertNull(library.link(EntryLink("Literal#title"), source)) // Legacy fragment is not a literal hash title.
            assertEquals("Under score", library.link(EntryLink("Under_score"), source)?.title)
            assertEquals("Under_score", library.link(EntryLink("Under_score", ""), source)?.title)
            install("Unclassified", "", edition, listOf("Ownerless"))
            assertEquals("Unclassified", library.link(EntryLink("Ownerless"), source)?.language)
            val reverseAction = EntryLink("Canton", "Noun#part")
            val reverseBody = library.read(found)
            val reverse = library.linkChoices(reverseAction, reverseBody)
            assertEquals(setOf("English", "Other owner", "Dutch"), reverse.map { it.language }.toSet())
            assertEquals(3, reverse.size)
            assertTrue(reverse.all { it.title == "Canton" && it.edition == edition && it.kind == "language" })
            assertNull(library.link(reverseAction, reverseBody)) // Legacy single-hit API still refuses ambiguity.
            val choiceCommits = mutableListOf<Triple<WordHit, Entry, EntryLink>>()
            val choiceErrors = mutableListOf<String>()
            val chosen = requireNotNull(reverse.singleOrNull { it.language == "Other owner" })
            val choiceNavigation = EntryNavigation(this, library::read, library::link, library::savedWord,
                library::random, { null }, { hit, entry, action -> choiceCommits += Triple(hit, entry, action) },
                {}, { choiceErrors += it }, { id -> library.dictionaries.any { it.id == id } },
                linkChoices = library::linkChoices, chooseLink = { action, hits ->
                    assertSame(reverseAction, action)
                    assertEquals(reverse, hits)
                    chosen
                })
            try {
                choiceNavigation.open(found).join()
                choiceNavigation.openLink(reverseAction, reverseBody).join()
                assertEquals(chosen, choiceCommits.last().first)
                assertSame(reverseAction, choiceCommits.last().third)
                assertTrue(choiceNavigation.goBack())
                kotlinx.coroutines.withTimeout(5_000) { while (choiceCommits.size != 3) kotlinx.coroutines.yield() }
                assertEquals(found, choiceCommits.last().first)
                assertEquals(EntryLink(""), choiceCommits.last().third)
                assertTrue(choiceErrors.isEmpty())
            } finally { choiceNavigation.cancel() }
            val committed = mutableListOf<Triple<WordHit, Entry, EntryLink>>()
            val errors = mutableListOf<String>()
            var visits = EntryVisitState()
            val navigation = EntryNavigation(this, library::read, library::link, library::savedWord,
                library::random, { null }, { hit, entry, target -> committed += Triple(hit, entry, target) },
                {}, { errors += it }, { id -> library.dictionaries.any { it.id == id } },
                visitsChanged = { visits = it })
            try {
                navigation.open(from).join()
                val originalVisit = visits.currentId
                val action = EntryLink("Gvangjcouh", "Noun#part")
                navigation.openLink(action, source).join()
                assertEquals(expected, committed.last().first)
                assertEquals(expected.key, committed.last().second.origin?.key)
                assertSame(action, committed.last().third)
                val targetVisit = visits.currentId
                install("Later owner", "de", edition, listOf("Gvangjcouh", "Canton"))
                navigation.openLink(action, source).join()
                navigation.openLink(EntryLink("Missing"), source).join()
                assertEquals(2, committed.size)
                assertEquals(2, errors.size)
                assertEquals(targetVisit, visits.currentId)
                assertTrue(navigation.goBack())
                kotlinx.coroutines.withTimeout(5_000) { while (committed.size != 3) kotlinx.coroutines.yield() }
                assertEquals(from, committed.last().first)
                assertEquals(from.key, committed.last().second.origin?.key)
                assertEquals(EntryLink(""), committed.last().third)
                assertEquals(originalVisit, visits.currentId)
                assertFalse(navigation.goBack())
            } finally { navigation.cancel() }
        } finally {
            library.dictionaries.filter { it.edition in editions }.forEach { library.remove(it.id).join() }
            assertEquals(before, library.dictionaries.map { it.id }.toSet())
        }
    }

    @Test fun versionTwoRekeyRollsBackFailureThenPreservesRowsAndIndexedLookup(): Unit = runBlocking {
        withContext(Dispatchers.IO) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            assumeTrue(context.packageName.endsWith(".validation"))
            assertNotEquals(Looper.getMainLooper(), Looper.myLooper())
            val name = "casefold-upgrade-${UUID.randomUUID()}.db"
            val titles = expectedKeys.keys.toList() + (0 until 256).map { "Fixture%03d".format(it) }
            try {
                var before: List<List<Any>> = emptyList()
                var schemaBefore: Map<String, String> = emptyMap()
                var dictionariesBefore: List<List<Any>> = emptyList()
                val oldKeys = titles.mapIndexed { index, title -> (index * 3L + 5) to title.lowercase(Locale.ROOT) }.toMap()
                context.openOrCreateDatabase(name, 0, null).use { db ->
                    createVersionTwo(db)
                    db.beginTransaction()
                    try {
                        db.execSQL("INSERT INTO dictionaries VALUES('fixture','Greek','el','language',?,9000,'greekwiktionary-20261001')", arrayOf(titles.size))
                        titles.forEachIndexed { index, title ->
                            val rowid = index * 3L + 5
                            db.execSQL("INSERT INTO words(rowid,dictionary,title,normalized,payload,length,record_key,source_kind) VALUES(?,?,CAST(? AS TEXT),CAST(? AS TEXT),?,?,CAST(? AS TEXT),?)",
                                arrayOf<Any>(rowid, "fixture", title.toByteArray(Charsets.UTF_8), oldKeys.getValue(rowid).toByteArray(Charsets.UTF_8), 1000L + rowid, 17, title.toByteArray(Charsets.UTF_8), "language"))
                        }
                        db.setTransactionSuccessful()
                    } finally { db.endTransaction() }
                    db.version = 2
                    before = rows(db)
                    schemaBefore = schema(db)
                    dictionariesBefore = dictionaryRows(db)
                    // Fail beyond the first keyset batch, after real earlier UPDATEs.
                    db.execSQL("CREATE TRIGGER fail_casefold BEFORE UPDATE OF normalized ON words WHEN OLD.rowid=389 BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END")
                }
                val failed = LibraryDatabase(context, name)
                try {
                    try {
                        failed.writableDatabase
                        fail("The real SQLite migration failure must be reported")
                    } catch (_: SQLiteException) { /* Expected real trigger abort. */ }
                } finally { failed.close() }
                context.openOrCreateDatabase(name, 0, null).use { db ->
                    assertEquals(2, db.version)
                    assertEquals(before, rows(db))
                    assertEquals(dictionariesBefore, dictionaryRows(db))
                    assertEquals(oldKeys, keys(db))
                    db.execSQL("DROP TRIGGER fail_casefold")
                }
                val upgraded = LibraryDatabase(context, name)
                try {
                    val db = upgraded.writableDatabase
                    assertEquals(3, db.version)
                    assertEquals(before, rows(db))
                    assertEquals(dictionariesBefore, dictionaryRows(db))
                    assertEquals(schemaBefore, schema(db))
                    val folded = titles.mapIndexed { index, title ->
                        (index * 3L + 5) to (expectedKeys[title] ?: title.lowercase(Locale.ROOT))
                    }.toMap()
                    assertEquals(folded, keys(db))
                    fun prefixRows(prefix: String): Set<String> {
                        val lower = foldSearchKey(prefix)
                        val upper = searchPrefixUpperBound(lower)
                        val range = if (upper == null) "normalized>=substr(?,2)"
                            else "normalized>=substr(?,2) AND normalized<substr(?,2)"
                        val arguments = if (upper == null) arrayOf("x$lower") else arrayOf("x$lower", "x$upper")
                        val sql = "SELECT title FROM words WHERE $range ORDER BY normalized,title LIMIT 500"
                        db.rawQuery("EXPLAIN QUERY PLAN $sql", arguments).use { c ->
                            val plans = buildList { while (c.moveToNext()) add(c.getString(3)) }
                            assertTrue(plans.toString(), plans.any { "word_lookup" in it && "SEARCH" in it })
                        }
                        return db.rawQuery(sql, arguments).use { c -> buildSet { while (c.moveToNext()) add(c.getString(0)) } }
                    }
                    assertEquals(setOf("ΣΊΣΥΦΟΣ", "σίσυφος"), prefixRows("ΣΊΣ"))
                    // This database is test-owned and contains fewer than the search limit.
                    assertTrue(titles.size < 500)
                    assertEquals(titles.toSet(), prefixRows(""))
                    val maximum = "\uDBFF\uDFFF"
                    assertEquals(setOf(maximum, "${maximum}tail", "$maximum${maximum}tail"), prefixRows(maximum))
                    assertEquals(setOf("$maximum${maximum}tail"), prefixRows("$maximum$maximum"))
                    assertEquals(setOf("Prefix$maximum", "Prefix${maximum}tail"), prefixRows("PREFIX$maximum"))
                    assertEquals(setOf("\uD7FFedge"), prefixRows("\uD7FF"))
                    assertEquals(setOf("\uE000outside"), prefixRows("\uE000"))
                    db.rawQuery("EXPLAIN QUERY PLAN SELECT title FROM words WHERE normalized=substr(?,2)", arrayOf("xstrasse")).use { c ->
                        val plans = buildList { while (c.moveToNext()) add(c.getString(3)) }
                        assertTrue(plans.toString(), plans.any { "word_lookup" in it && "SEARCH" in it })
                    }
                    db.rawQuery("SELECT title,typeof(normalized),record_key FROM words WHERE normalized=substr(?,2) ORDER BY CASE WHEN title=substr(?,2) THEN 0 ELSE 1 END LIMIT 1", arrayOf("xstrasse", "xStraße")).use { c ->
                        assertTrue(c.moveToFirst())
                        assertEquals("Straße", c.getString(0)); assertEquals("text", c.getString(1)); assertEquals("Straße", c.getString(2))
                    }
                } finally { upgraded.close() }
            } finally { context.deleteDatabase(name) }
        }
    }

    private fun rows(db: SQLiteDatabase): List<List<Any>> = db.rawQuery(
        "SELECT rowid,dictionary,title,payload,length,record_key,source_kind FROM words ORDER BY rowid", null,
    ).use { c -> buildList {
        while (c.moveToNext()) add(listOf(c.getLong(0), c.getString(1), c.getString(2), c.getLong(3), c.getLong(4), c.getString(5), c.getString(6)))
    } }

    private fun dictionaryRows(db: SQLiteDatabase): List<List<Any>> = db.rawQuery(
        "SELECT id,language,code,kind,count,bytes,edition FROM dictionaries ORDER BY id", null,
    ).use { c -> buildList {
        while (c.moveToNext()) add(listOf(c.getString(0), c.getString(1), c.getString(2), c.getString(3), c.getLong(4), c.getLong(5), c.getString(6)))
    } }

    private fun keys(db: SQLiteDatabase): Map<Long, String> = db.rawQuery(
        "SELECT rowid,normalized FROM words ORDER BY rowid", null,
    ).use { c -> buildMap { while (c.moveToNext()) put(c.getLong(0), c.getString(1)) } }

    private fun schema(db: SQLiteDatabase): Map<String, String> = db.rawQuery(
        "SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY name", null,
    ).use { c -> buildMap { while (c.moveToNext()) put(c.getString(0), c.getString(1)) } }

    private fun createVersionTwo(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE dictionaries(id TEXT PRIMARY KEY,language TEXT,code TEXT,kind TEXT,count INTEGER,bytes INTEGER,edition TEXT NOT NULL DEFAULT '')")
        db.execSQL("CREATE TABLE words(dictionary TEXT,title TEXT,normalized TEXT,payload INTEGER,length INTEGER,record_key TEXT NOT NULL,source_kind TEXT NOT NULL)")
        db.execSQL("CREATE INDEX word_lookup ON words(normalized,title)")
        db.execSQL("CREATE INDEX word_dictionary ON words(dictionary)")
        db.execSQL("CREATE UNIQUE INDEX scoped_dictionary ON dictionaries(edition,kind,language) WHERE edition<>''")
        db.execSQL("CREATE INDEX word_record ON words(dictionary,record_key)")
        db.execSQL("""CREATE VIEW word_choices AS
            SELECT w.dictionary,w.title,w.normalized,w.payload,w.length,w.record_key,d.kind,d.language,d.edition,
                   NULL AS context_dictionary,w.rowid AS wordid
              FROM words w JOIN dictionaries d ON d.id=w.dictionary WHERE d.kind<>'alias'
            UNION ALL
            SELECT w.dictionary,w.title,w.normalized,w.payload,w.length,w.record_key,w.source_kind,
                   CASE WHEN w.source_kind='language' THEN COALESCE(c.language,'') ELSE w.source_kind END,
                   d.edition,c.id,w.rowid
              FROM words w JOIN dictionaries d ON d.id=w.dictionary
              LEFT JOIN dictionaries c ON d.edition<>'' AND c.edition=d.edition AND c.kind=w.source_kind
             WHERE d.kind='alias'""")
    }

    private fun dictionary(heading: String, titles: List<String>, code: String = "el"): ByteArray {
        val payload = InstrumentationRegistry.getInstrumentation().context.assets.open("bom-identities.wikblb").use { source ->
            val input = ByteArrayInputStream(source.readBytes())
            val header = ByteArray(9); assertEquals(9, input.read(header))
            assertTrue(header.copyOfRange(0, 8).contentEquals("WIKBLB08".toByteArray()))
            assertEquals(1, header[8].toInt())
            repeat(3) { while (true) { val value = input.read(); require(value >= 0); if (value == 0) break } }
            var size = 0; var shift = 0
            while (true) { val value = input.read(); require(value >= 0 && shift < 28); size = size or ((value and 127) shl shift); if (value and 128 == 0) break; shift += 7 }
            ByteArray(size).also { assertEquals(size, input.read(it)); assertEquals(-1, input.read()) }
        }
        return ByteArrayOutputStream().apply {
            fun nul(value: String) { write(value.toByteArray(Charsets.UTF_8)); write(0) }
            write("WIKBLB08".toByteArray()); write(1); nul(code); nul(heading)
            titles.sortedWith { a, b ->
                val x = a.toByteArray(Charsets.UTF_8); val y = b.toByteArray(Charsets.UTF_8)
                var result = 0
                for (i in 0 until minOf(x.size, y.size)) { result = (x[i].toInt() and 255) - (y[i].toInt() and 255); if (result != 0) break }
                if (result == 0) x.size - y.size else result
            }.forEach { title ->
                nul(title); var size = payload.size
                while (size >= 128) { write((size and 127) or 128); size = size ushr 7 }
                write(size); write(payload)
            }
        }.toByteArray()
    }
}
