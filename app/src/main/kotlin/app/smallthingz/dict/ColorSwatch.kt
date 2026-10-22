package app.smallthingz.dict

/** Compiled metadata only. Invalid or unknown features leave the stored table visible. */
internal data class ColorSwatch(val hex: String, val argb: Long)
internal fun colorSwatch(feature: Feature?): ColorSwatch? {
    if (feature?.kind != "color_swatch" || feature.language.isNotEmpty() ||
        feature.tailKind != "none" || feature.tail.isNotEmpty() || !Regex("#[0-9a-f]{6}").matches(feature.data)) return null
    return ColorSwatch(feature.data, 0xff000000L or feature.data.substring(1).toLong(16))
}

/** Canonical compiled cell metadata only; never interpret CSS or synthesize a label. */
internal fun canonicalColorArgb(value: String?): Long? =
    value?.takeIf { Regex("#[0-9a-f]{6}").matches(it) }?.let { 0xff000000L or it.substring(1).toLong(16) }
