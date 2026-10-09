package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class EntrySourceTest {
    private fun entry(kind: String = "language", title: String = "word", edition: String = "arwiktionary-20261001") =
        Entry(title,emptyList(),kind,null,"",emptyList(),emptyList(),edition=edition)
    @Test fun attributionUsesAcquisitionEditionWithoutInventingSourceNamespaces() {
        assertEquals("https://ar.wiktionary.org/w/index.php?title=word&action=history",attributionUrl(entry()))
        assertEquals("https://www.wiktionary.org/",attributionUrl(entry(edition="")))
        assertEquals("https://www.wiktionary.org/",attributionUrl(entry(edition="bad")))
        assertEquals("https://ar.wiktionary.org/",attributionUrl(entry(kind="rhymes")))
        assertEquals("https://ar.wiktionary.org/w/index.php?title=Rhymes%3Atarget&action=history",
            attributionUrl(entry(kind="rhymes").copy(redirect=Redirect("source","Rhymes:target","",true))))
        assertEquals("https://ar.wiktionary.org/w/index.php?title=ChainB&action=history",
            attributionUrl(entry(kind="alias",title="ChainB").copy(redirect=Redirect("ChainA","ChainB","",true))))
        assertEquals("https://zh-min-nan.wiktionary.org/",sourceWiki("zh_min_nanwiktionary-20261001"))
        assertEquals("https://ar.wiktionary.org/wiki/File%3Aa%20b.png",sourcePage(entry(),"File:a b.png"))
    }
    @Test fun mediaSourceAndCacheIdentityFollowTheKnownEdition() {
        assertEquals("ar.wiktionary.org · 2026-10-01",sourceLabel("arwiktionary-20261001"))
        assertEquals("Unknown source",sourceLabel(""))
        assertEquals(listOf("commons.wikimedia.org"),mediaHosts(""))
        assertEquals(listOf("commons.wikimedia.org","ar.wiktionary.org"),mediaHosts("arwiktionary-20261001"))
        assertEquals(listOf("commons.wikimedia.org","af.wiktionary.org"),mediaHosts("afwiktionary-20261001"))
        val media = Media("Shared-name.png","image","")
        assertNotEquals(mediaKey(media,"afwiktionary-20261001"),mediaKey(media,"arwiktionary-20261001"))
        assertNotEquals(mediaKey(media,""),mediaKey(media,"arwiktionary-20261001"))
        assertNotEquals(mediaKey(media,""),mediaKey(media.copy(kind="audio"),""))
    }

    @Test fun compiledExternalLinksResolveNetworkPathsAndPreserveHttpUrls() {
        // Exact Navbar target from the source-backed Arabic حُرّ record.
        val navbar = "//en.wiktionary.org/w/index.php?title=%D9%82%D8%A7%D9%84%D8%A8:%D8%AD_%D8%B1_%D8%B1&action=edit"
        for (target in listOf(navbar, "//example.test", "//[2001:db8::1]:8443/path?q=%26#part",
            "//例え.テスト/辞書?語=%E8%AA%9E#章", "//example.test/辞書?語=自由&x=%26#章")) {
            assertEquals("https:$target", externalLinkUrl(Span("external_link", "ت", target = target)))
        }
        for (target in listOf("https://example.test/a?x=%26#part", "http://example.test:8080/path",
            "https://例え.テスト/辞書?x=%26#章", "HTTP://EXAMPLE.TEST/path?x=%2F")) {
            assertEquals(target, externalLinkUrl(Span("external_link", "visible", target = target)))
        }
    }

    @Test fun compiledExternalLinksRejectMalformedNetworkPathsAndUnrelatedKinds() {
        for (target in listOf("", "//", "///path", "//:443/path", "//exa mple.test/path", "//example.test/%", "//example.test\\path",
            "http://", "https:///path", "http://:443/path", "https://exa mple.test/", "https://example.test/%",
            "https://example.test:65536/", "https://example.test:bad/", "https://-invalid.test/", "https://.test/",
            "//example.test:65536/path", "//[bad-ipv6]/",
            "javascript:alert(1)", "data:text/html,test", "file:///tmp/file", "mailto:test@example.test", "/relative")) {
            assertNull(target, externalLinkUrl(Span("external_link", "visible", target = target)))
        }
        for (kind in listOf("text", "link", "line_break", "unknown")) {
            for (target in listOf("//example.test/path", "https://example.test/path")) {
                assertNull(kind, externalLinkUrl(Span(kind, "visible", target = target)))
            }
        }
    }
}
