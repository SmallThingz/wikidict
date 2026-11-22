package app.smallthingz.dict

/** Compiled semantic policy; no source CSS or arbitrary feature string is decoded. */
enum class FontFeaturePolicy { Normal, SevenOn }

internal val FontFeaturePolicy.nativeSettings: String get() = when (this) {
    FontFeaturePolicy.Normal -> ""
    FontFeaturePolicy.SevenOn -> "'liga' 1, 'clig' 1, 'kern' 1, 'ccmp' 1, 'dist' 1, 'mark' 1, 'mkmk' 1"
}

internal fun requireEgyptianFeatureSupport(policy: FontFeaturePolicy?) {
    if (policy != null) throw UnsupportedOperationException("Explicit font features are unavailable for Egyptian glyph layout")
}
