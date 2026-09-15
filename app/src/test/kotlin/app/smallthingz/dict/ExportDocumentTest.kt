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

    @Test fun legacyReaderFieldsAreRejected() {
        for (field in listOf("source", "source_base64", "payload_base64", "unexpanded_templates", "expansion", "deferred", "content")) {
            assertThrows(IllegalArgumentException::class.java) { compiledFieldName(field) }
        }
        assertEquals("sections", compiledFieldName("sections"))
    }

    @Test fun uncompiledTemplateSpanIsRejected() {
        assertThrows(IllegalArgumentException::class.java) { compiledSpanKind("template") }
        assertEquals("link", compiledSpanKind("link"))
    }
}
