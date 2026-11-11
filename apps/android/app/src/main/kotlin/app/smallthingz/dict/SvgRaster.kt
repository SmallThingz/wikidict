package app.smallthingz.dict

import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import kotlin.math.ceil

internal fun validSvgLanguage(value: String): Boolean = Regex("[a-z]+(?:-[a-z]+)*").matches(value)
internal fun inlineImageAssetKey(image: InlineImage): String =
    image.file + (image.svgLanguage?.let { "\u0000$it" } ?: "")

/** The same occurrence can use intrinsic Figure sizing or ordinary inline bounds. */
internal data class RasterImageOccurrence(val image: InlineImage, val figureSizing: FigureSizingPolicy? = null)
internal data class SvgRasterDemand(val width: Int, val height: Int) {
    fun naturalRequestWidth(originalWidth: Long, originalHeight: Long): Int {
        require(width > 0 && height > 0 && originalWidth > 0 && originalHeight > 0)
        // Client axes round before DPR scaling; a natural-width raster must still cover both.
        // A one-pixel backing height needs no aspect-ratio expansion, even for a zero-height Figure.
        val fromHeight = if (height == 1) java.math.BigInteger.ONE else {
            val divisor = originalHeight.toBigInteger()
            (height.toBigInteger() * originalWidth.toBigInteger() + divisor - java.math.BigInteger.ONE) / divisor
        }
        val requested = maxOf(width.toBigInteger(), fromHeight)
        require(requested <= (Int.MAX_VALUE / 4).toBigInteger()) { "SVG raster request exceeds platform range" }
        return requested.toInt()
    }
}

internal data class SvgRasterRequest(val language: String, val density: Float,
    val occurrences: List<RasterImageOccurrence>) {
    init {
        require(validSvgLanguage(language) && density.isFinite() && density > 0f)
        require(occurrences.isNotEmpty() && occurrences.all { it.image.svgLanguage == language })
        require(occurrences.map { it.image.file }.distinct().size == 1)
    }
    // Keep explicit language, DPR and source sizing in the disk identity even before intrinsic axes are known.
    val cacheSuffix: String = "-svg-" + MessageDigest.getInstance("SHA-256").digest(buildString {
        append(language); append(':'); append(density.toRawBits()); append(':')
        occurrences.map { "${it.image.widthPx},${it.image.heightPx},${it.figureSizing?.ordinal}" }
            .distinct().sorted().forEach { append(it); append(';') }
    }.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    fun requiredWidth(originalWidth: Long, originalHeight: Long, mime: String?): Int =
        requiredSize(originalWidth, originalHeight, mime).width

    fun requiredSize(originalWidth: Long, originalHeight: Long, mime: String?): SvgRasterDemand {
        require(mime == "image/svg+xml" && originalWidth > 0 && originalHeight > 0) { "SVG dimensions unavailable" }
        val sizes = occurrences.map { occurrence ->
            val policy = occurrence.figureSizing
            if (policy == null) checkNotNull(inlineImagePixels(occurrence.image, originalWidth, originalHeight, density, mime)).let {
                it.width.toDouble() to it.height.toDouble()
            } else figureSourceSize(occurrence.image, policy, originalWidth, originalHeight).let {
                it.width.toDouble() * density to it.height.toDouble() * density
            }
        }
        fun pixels(value: Double, allowZero: Boolean = false): Int {
            require(value.isFinite() && (value > 0 || allowZero && value == 0.0) && value <= Int.MAX_VALUE / 4) { "SVG raster demand exceeds platform range" }
            return ceil(value).toInt().coerceAtLeast(1)
        }
        return SvgRasterDemand(pixels(sizes.maxOf { it.first }), pixels(sizes.maxOf { it.second }, allowZero = true))
    }
}

/** The returned bucket may exceed iiurlwidth, but cannot change file, language or required resolution. */
internal fun svgRasterWidth(url: String, file: String, language: String, requiredWidth: Int): Int {
    require(requiredWidth > 0 && validSvgLanguage(language))
    val uri = URI(url)
    require(uri.scheme == "https" && uri.host == "upload.wikimedia.org" && uri.rawUserInfo == null &&
        uri.port == -1 && uri.rawQuery == null && uri.rawFragment == null) { "Unsafe SVG raster URL" }
    val parts = uri.rawPath.split('/')
    require(parts.size >= 7 && parts[1] == "wikipedia" && parts[3] == "thumb") { "Not a Wikimedia thumbnail" }
    fun decoded(value: String) = URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
    val sourceName = decoded(parts[parts.lastIndex - 1])
    require(sourceName.replace('_', ' ') == file) { "SVG raster file mismatch" }
    val raster = decoded(parts.last())
    val prefix = "lang$language-"
    require(raster.startsWith(prefix)) { "SVG raster language mismatch" }
    val tail = raster.removePrefix(prefix)
    val split = tail.indexOf("px-")
    require(split > 0 && tail.take(split).all { it in '0'..'9' }) { "Invalid SVG raster width" }
    val width = tail.take(split).toIntOrNull() ?: error("SVG raster width overflow")
    require(width >= requiredWidth && tail.substring(split + 3) == "$sourceName.png") { "Undersized or mismatched SVG raster" }
    return width
}
