package app.smallthingz.dict

import android.text.Spanned

/** The interval is actual native marker text, excluding its outer private isolate controls. */
internal data class NativeCitationMarkerSpan(val marker: CitationMarker)

internal fun nativeHasCitationNoWrap(source: Spanned): Boolean =
    source.getSpans(0, source.length, NativeCitationMarkerSpan::class.java).any { it.marker.nowrap }

/** Public UTF-16 coordinates and the original stored occurrence, never private bidi controls. */
internal data class NativeCitationMarkerRange(val marker: CitationMarker,
    val start: Int, val end: Int, val nodeId: Int)
