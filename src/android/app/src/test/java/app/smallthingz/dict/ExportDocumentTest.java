package app.smallthingz.dict;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

public final class ExportDocumentTest {
    private static final String SHELL = "A" + ExportDocument.SLOT + "B";

    @Test public void htmlExportPassesThrough() throws Exception {
        String html = "<!doctype html><script id=\"dict-data\" type=\"application/json\">{}</script>";
        assertEquals(html, ExportDocument.render(html, SHELL));
    }

    @Test public void jsonIsInsertedWithoutClosingTheScriptElement() throws Exception {
        String json = "{\"schema\":\"dict.results.v1\",\"query\":\"</script><&\"}";
        String rendered = ExportDocument.render(json, SHELL);
        assertTrue(rendered.startsWith("A<script id=\"dict-data\""));
        assertTrue(rendered.endsWith("</script>B"));
        assertFalse(rendered.contains("</script><"));
        assertTrue(rendered.contains("\\u003c/script\\u003e\\u003c\\u0026"));
    }

    @Test public void unrelatedTextAndJsonAreRejected() throws Exception {
        reject("hello");
        reject("{\"schema\":\"something-else\"}");
        reject("<html><p>not a dict export</p></html>");
    }

    private static void reject(String text) throws Exception {
        try {
            ExportDocument.render(text, SHELL);
            fail("expected FormatException");
        } catch (ExportDocument.FormatException expected) {}
    }
}
