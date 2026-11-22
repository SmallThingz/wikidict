package app.smallthingz.dict

import java.net.URI
import java.security.MessageDigest
import kotlin.math.ceil

/** This demand describes the PNG poster, never the STL metadata axes. */
internal data class StaticPosterRequest(val density: Float, val occurrences: List<RasterImageOccurrence>) {
    val image = requireNotNull(occurrences.firstOrNull()).image
    val identity = checkNotNull(image.staticPoster)
    init {
        require(density.isFinite() && density > 0f && occurrences.isNotEmpty())
        require(occurrences.all { it.image.file == image.file && it.image.staticPoster?.resourceIdentity == identity.resourceIdentity })
        require(occurrences.all { it.figureSizing == null || it.figureSizing == FigureSizingPolicy.RequestedFit })
    }
    private fun pixels(value: Double): Long {
        require(value.isFinite() && value > 0 && value <= Int.MAX_VALUE / 4) { "Poster raster exceeds platform range" }
        return ceil(value).toLong()
    }
    private val minimumWidth = pixels(occurrences.maxOf { checkNotNull(it.image.widthPx).toDouble() } * density)
    private val minimumHeight = pixels(occurrences.maxOf { checkNotNull(it.image.heightPx).toDouble() } * density)
    val requestWidth: Int = maxOf(minimumWidth, (4L * minimumHeight) / 3L).also {
        require(it in 1L..(Int.MAX_VALUE / 4).toLong()) { "Poster raster exceeds platform range" }
    }.toInt()
    val cacheSuffix: String = "-stl-" + MessageDigest.getInstance("SHA-256").digest(
        "${identity.policy}:${identity.fileSha1}:${identity.fileTimestamp}:$requestWidth".toByteArray(Charsets.UTF_8)
    ).joinToString("") { "%02x".format(it) }

    fun validateIdentity(file: String, sha1: String, timestamp: String, mime: String, mediaType: String) {
        require(file.removePrefix("File:").replace('_', ' ') == image.file &&
            sha1 == identity.fileSha1 && timestamp == identity.fileTimestamp &&
            mime == "application/sla" && mediaType == "3D") { "Static poster original identity changed" }
    }

    fun validateRaster(url: String, mime: String, width: Int, height: Int): SvgRasterDemand {
        val uri = URI(url)
        require(uri.scheme == "https" && uri.host == "upload.wikimedia.org" && uri.rawUserInfo == null &&
            uri.port == -1 && uri.rawQuery == null && uri.rawFragment == null &&
            uri.path.endsWith(".png", ignoreCase = true)) { "Static poster requires an allowed PNG thumbnail URL" }
        require(mime == "image/png" && width >= requestWidth && height.toLong() == (width.toLong() * 3L + 2L) / 4L &&
            width.toLong() >= minimumWidth && height.toLong() >= minimumHeight &&
            width.toLong() * height <= 16L * 1024 * 1024) { "Static poster raster axes or MIME changed" }
        return SvgRasterDemand(width, height)
    }
}
