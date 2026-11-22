package app.smallthingz.dict

import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** This identifies the rendered source raster, independently of the original File metadata. */
internal data class FigureBlockMediaIdentity(val url: String, val sha256: String, val width: Int, val height: Int)

internal class FigureBlockMediaRequest(val layout: FigureBlockMediaLayout, density: Float) {
    init { require(density.isFinite() && density > 0f) }
    private val multiplier = if (density <= 1f) 1L else 2L
    private val selected = if (multiplier == 1L) layout.rendition1x else layout.rendition2x
    private val width = layout.naturalWidth * multiplier
    private val height = layout.naturalHeight * multiplier
    init {
        require(width in 1L..Int.MAX_VALUE && height in 1L..Int.MAX_VALUE &&
            width <= 16L * 1024 * 1024 / height) { "Source Figure raster exceeds the decoder pixel budget" }
    }
    val identity = FigureBlockMediaIdentity(selected.url, selected.sha256, width.toInt(), height.toInt())
    val cacheSuffix = "-block-png-" + MessageDigest.getInstance("SHA-256")
        .digest((identity.url + "\u0000" + identity.sha256).toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    suspend fun verifyBody(file: File) {
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                require(total <= 50L * 1024 * 1024) { "Source Figure raster is too large" }
                digest.update(buffer, 0, count)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        require(actual == identity.sha256) { "Source Figure raster body differs from its authenticated identity" }
    }

    fun resource(file: File, ephemeral: Boolean = false) = MediaFile(file, identity.url, "", ephemeral,
        originalWidth = layout.naturalWidth, originalHeight = layout.naturalHeight, originalMime = "image/png",
        requiredRasterWidth = identity.width, requiredRasterHeight = identity.height,
        exactRasterWidth = identity.width, exactRasterHeight = identity.height)

    fun assertReady(ready: InlineImageAssetState.Ready) {
        if (ready.blockMediaIdentity != identity || ready.mime != "image/png" ||
            ready.originalWidth != layout.naturalWidth || ready.originalHeight != layout.naturalHeight ||
            ready.decoded.width != identity.width || ready.decoded.height != identity.height ||
            ready.decoded.bitmap.width != identity.width || ready.decoded.bitmap.height != identity.height)
            throw UnsupportedFloatLayout("Source Figure raster identity or decoded axes are unavailable")
    }
}
