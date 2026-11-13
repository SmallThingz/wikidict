package app.smallthingz.dict

internal const val NativeTableLanguageUnavailable = "Table language is unavailable for this layout."

/** Native admission is stricter than the wire's nonempty UTF-8 domain. Keep the
 * source spelling in the model; use its explicit canonical identity for paint. */
internal fun nativeTableOwnerLanguageTag(language: String): String? {
    val canonical = spanLanguageTag(language) ?: return null
    // This carrier has no equivalence proof for dropped or remapped subtags.
    if (!canonical.equals(language, ignoreCase = true)) return null
    val native = java.util.Locale.forLanguageTag(canonical).toLanguageTag()
    return canonical.takeIf { native == it }
}
