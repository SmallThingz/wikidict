package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

class BlobDecoderTest {
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

    @Test fun everyRealCorpusRecordDecodesDirectly() {
        val records=records();assertTrue(records.size>20)
        records.forEach { (title,payload)-> val e=BlobDecoder.decode(payload,title,"language","English","en");assertEquals(title,e.title);assertTrue(e.sections.isNotEmpty()) }
        val cat=records.first{it.first=="cat"}.let{BlobDecoder.decode(it.second,it.first,"language","English","en")}
        assertTrue(cat.sections.any{it.title.startsWith("Etymology")});assertTrue(cat.media.any{it.kind=="audio"});assertTrue(cat.media.any{it.kind=="image"})
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
}
