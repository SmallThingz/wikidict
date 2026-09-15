package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ExportDocumentTest {
    @Test fun directJsonIsAccepted() {
        val json = "{\"schema\":\"dict.results.v1\",\"entries\":[]}"
        assertEquals(json, ExportDocument.extractJson(json))
    }

    @Test fun htmlExtractsOnlyDictData() {
        val json = "{\"schema\":\"dict.results.v1\",\"query\":\"cat\"}"
        val html = "<html><script id=\"dict-data\" type=\"application/json\">$json</script><p>tail</p></html>"
        assertEquals(json, ExportDocument.extractJson(html))
    }

    @Test fun unrelatedHtmlIsRejected() {
        assertThrows(IllegalArgumentException::class.java) { ExportDocument.extractJson("<html>no data</html>") }
    }
}
