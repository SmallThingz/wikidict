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
}
