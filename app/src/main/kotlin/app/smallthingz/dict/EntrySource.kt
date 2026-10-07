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

internal fun mediaHosts(edition: String): List<String> = listOf("commons.wikimedia.org") + listOfNotNull(sourceWiki(edition)?.let { java.net.URI(it).host })

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
