package app.smallthingz.dict

internal fun sourceLabel(edition: String): String {
    val host = sourceWiki(edition)?.let { java.net.URI(it).host } ?: return "Unknown source"
    val date = edition.substringAfterLast('-')
    return "$host · ${date.take(4)}-${date.substring(4,6)}-${date.takeLast(2)}"
}

internal fun sourceWiki(edition: String): String? {
    if (dictionaryEdition("$edition-aliases.wikblb") != edition || edition.isEmpty()) return null
    val language = edition.substringBeforeLast('-').removeSuffix("wiktionary").replace('_','-')
    return "https://$language.wiktionary.org/"
}

internal fun sourcePage(entry: Entry, title: String): String = sourceWiki(entry.edition)?.let {
    it + "wiki/" + java.net.URLEncoder.encode(title,"UTF-8").replace("+","%20")
} ?: "https://www.wiktionary.org/"

// Match the normalized target emitted by the compiler, including its terminal-X form.
private val compiledBookSourcesTarget = Regex("Special:BookSources/(?:[0-9]{9}[0-9X]|97[89][0-9]{9}[0-9X])")

internal fun bookSourcesUrl(entry: Entry, target: String): String? {
    if (!compiledBookSourcesTarget.matches(target) || sourceWiki(entry.edition) == null) return null
    return sourcePage(entry, target)
}

internal fun mediaHosts(edition: String): List<String> = listOf("commons.wikimedia.org") + listOfNotNull(sourceWiki(edition)?.let { java.net.URI(it).host })

/** Inline actions use the compiled target. A description-page image link is not
 * a lookup in the bundled namespace-zero dictionary. Never derive it from alt,
 * caption or a filename when the compiled action is absent/overridden. */
internal fun inlineImageLinkUrl(span: Span, edition: String): String? {
    if (span.image == null) return null
    if (span.kind == "external_link") return externalLinkUrl(span)
    if (span.kind != "link" || !span.target.startsWith("File:")) return null
    val wiki = sourceWiki(edition) ?: return null
    val title = span.target.substringBefore('#')
    val fragment = span.target.substringAfter('#', "")
    return wiki + "wiki/" + java.net.URLEncoder.encode(title, "UTF-8").replace("+", "%20") +
        if (fragment.isEmpty()) "" else "#" + java.net.URLEncoder.encode(fragment, "UTF-8").replace("+", "%20")
}

internal fun mediaKey(media: Media, edition: String): String = java.security.MessageDigest.getInstance("SHA-256")
    .digest((mediaHosts(edition).joinToString("|") + "\u0000" + media.kind + "\u0000" + media.file).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

internal fun attributionUrl(entry: Entry): String {
    val wiki = sourceWiki(entry.edition) ?: return "https://www.wiktionary.org/"
    val fullTitle = when {
        entry.kind == "alias" -> entry.title
        entry.redirect?.followed == true -> entry.redirect.target
        entry.kind == "language" || entry.kind == "supplemental" -> entry.title
        else -> return wiki
    }
    return wiki + "w/index.php?title=" + java.net.URLEncoder.encode(fullTitle,"UTF-8") + "&action=history"
}

/** Validate compiled web links, resolving network paths to HTTPS without rewriting their text. */
internal fun externalLinkUrl(span: Span): String? {
    if (span.kind != "external_link") return null
    val target = if (span.target.startsWith("//")) "https:${span.target}" else span.target
    val uri = runCatching { java.net.URI(target) }.getOrNull() ?: return null
    if (!"http".equals(uri.scheme, ignoreCase = true) && !"https".equals(uri.scheme, ignoreCase = true)) return null
    if (uri.rawAuthority.isNullOrBlank()) return null
    // URL parsing does not open a connection; it also exposes Unicode DNS authorities.
    val parsed = runCatching { uri.toURL() }.getOrNull() ?: return null
    val host = parsed.host
    if (host.isNullOrBlank() || parsed.port !in -1..65535) return null
    val validHost = if (host.startsWith("[")) !uri.host.isNullOrBlank() else
        runCatching { java.net.IDN.toASCII(host, java.net.IDN.USE_STD3_ASCII_RULES) }
            .getOrNull()?.trimEnd('.')?.isNotEmpty() == true
    return if (validHost) target else null
}
