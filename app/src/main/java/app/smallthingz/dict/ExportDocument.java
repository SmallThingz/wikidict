package app.smallthingz.dict;

final class ExportDocument {
    static final String SLOT =
            "<script id=\"dict-data\" type=\"application/json\">\"__DICT_DATA__\"</script>";

    private ExportDocument() {}

    static String render(String source, String shell) throws FormatException {
        String text = stripBom(source);
        int first = firstNonWhitespace(text);
        if (first == text.length()) throw new FormatException("The selected file is empty.");
        char marker = text.charAt(first);
        if (marker == '<') return html(text);
        if (marker == '{') return json(text, shell);
        throw new FormatException("Open a Dict HTML export or dict.results.v1 JSON file.");
    }

    private static String html(String text) throws FormatException {
        if (!text.contains("id=\"dict-data\"") && !text.contains("id='dict-data'")) {
            throw new FormatException("This HTML file is not a Dict export.");
        }
        return text;
    }

    private static String json(String text, String shell) throws FormatException {
        if (!text.contains("\"dict.results.v1\"")) {
            throw new FormatException("This JSON file is not dict.results.v1 output.");
        }
        int at = shell.indexOf(SLOT);
        if (at < 0) throw new FormatException("The bundled renderer shell is incompatible.");
        String safe = text.replace("&", "\\u0026")
                .replace("<", "\\u003c")
                .replace(">", "\\u003e");
        String payload = "<script id=\"dict-data\" type=\"application/json\">"
                + safe + "</script>";
        return shell.substring(0, at) + payload + shell.substring(at + SLOT.length());
    }

    private static String stripBom(String text) {
        return !text.isEmpty() && text.charAt(0) == '\ufeff' ? text.substring(1) : text;
    }

    private static int firstNonWhitespace(String text) {
        int i = 0;
        while (i < text.length() && Character.isWhitespace(text.charAt(i))) i++;
        return i;
    }

    static final class FormatException extends Exception {
        private static final long serialVersionUID = 1L;
        FormatException(String message) { super(message); }
    }
}
