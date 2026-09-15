package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ExportDocumentTest {
    @Test fun directCompiledJsonIsAccepted() {
        val json = "{\"schema\":\"dict.results.v1\",\"entries\":[]}"
        assertEquals(json, ExportDocument.compiledJson(json.toByteArray()))
    }

    @Test fun htmlIsRejected() {
        val html = "<html><script id=\"dict-data\" type=\"application/json\">{}</script></html>"
        assertThrows(IllegalArgumentException::class.java) { ExportDocument.compiledJson(html.toByteArray()) }
    }

    @Test fun uncompiledTemplateSpanIsRejected() {
        assertThrows(IllegalArgumentException::class.java) { compiledSpanKind("template") }
        assertEquals("link", compiledSpanKind("link"))
    }
}
