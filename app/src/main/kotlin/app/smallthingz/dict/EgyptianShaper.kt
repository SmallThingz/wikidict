package app.smallthingz.dict

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.fonts.Font
import androidx.annotation.RequiresApi
import java.nio.ByteBuffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Private application engine: never changes or hooks the device's text stack. */
internal object EgyptianNative {
    init { System.loadLibrary("wikidict_egyptian") }
    external fun version(): String
    external fun shape(font: ByteBuffer, text: String): FloatArray
}

@RequiresApi(31)
internal class EgyptianGlyphRun internal constructor(
    private val font: Font,
    internal val glyphIds: IntArray,
    internal val positions: FloatArray,
    internal val clusters: IntArray,
    val advance: Float,
    val ascent: Float,
    val descent: Float,
    val textSize: Float,
) {
    fun glyphCount(): Int = glyphIds.size
    fun getGlyphId(index: Int): Int = glyphIds[index]
    fun getGlyphX(index: Int): Float = positions[2 * index]
    fun getGlyphY(index: Int): Float = positions[2 * index + 1]
    fun getFont(index: Int): Font { require(index in glyphIds.indices); return font }

    /** Caller positions the baseline and supplies colour; the font and scale stay bound to this run. */
    fun draw(canvas: Canvas, paint: Paint) {
        val previousSize = paint.textSize
        try {
            paint.textSize = textSize
            canvas.drawGlyphs(glyphIds, 0, positions, 0, glyphCount(), font, paint)
        } finally {
            paint.textSize = previousSize
        }
    }
}

@RequiresApi(31)
internal object EgyptianShaper {
    private data class LoadedFont(val font: Font, val bytes: ByteBuffer)
    @Volatile private var loaded: LoadedFont? = null

    private fun load(context: Context): LoadedFont = loaded ?: synchronized(this) {
        loaded ?: run {
            check(EgyptianNative.version() == "11.4.4") { "Unexpected Egyptian shaping engine" }
            val font = Font.Builder(context.resources, R.font.egyptian_hieroglyphs).build()
            check(font.ttcIndex == 0 && font.axes.isNullOrEmpty()) { "Unexpected Egyptian font instance" }
            val source = font.buffer.duplicate().apply { clear() }
            // Font's buffer can be read-only or indirect; JNI gets an exact, owned direct copy.
            val bytes = ByteBuffer.allocateDirect(source.remaining()).apply { put(source); flip() }
            LoadedFont(font, bytes.asReadOnlyBuffer()).also { loaded = it }
        }
    }

    /** Font I/O and all decoding/shaping stay off Main, including the first library load. */
    suspend fun shape(context: Context, text: String, textSize: Float): EgyptianGlyphRun = withContext(Dispatchers.IO) {
        require(textSize.isFinite() && textSize > 0f)
        val loadedFont = load(context.applicationContext)
        val raw = EgyptianNative.shape(loadedFont.bytes, text)
        check(raw.size >= 7 && raw.all { it.isFinite() }) { "Invalid Egyptian shaping result" }
        val count = raw[6].toInt()
        check(count in 1..262144 && raw[6] == count.toFloat() && raw.size == 7 + 4 * count)
        check(raw[0] > 0f && raw[1] > 0f && raw[2] == 0f)
        val scale = textSize / raw[0]
        val advance = raw[1] * scale
        val ascent = raw[3] * scale
        val descent = raw[4] * scale
        check(scale.isFinite() && scale > 0f && advance.isFinite() && advance > 0f && ascent.isFinite() && descent.isFinite()) { "Egyptian text metrics exceed the supported drawing range" }
        val ids = IntArray(count)
        val xy = FloatArray(count * 2)
        val clusters = IntArray(count)
        repeat(count) { index ->
            val at = 7 + index * 4
            ids[index] = raw[at].toInt()
            clusters[index] = raw[at + 3].toInt()
            check(ids[index] > 0 && raw[at] == ids[index].toFloat())
            check(clusters[index] in text.indices && raw[at + 3] == clusters[index].toFloat())
            xy[index * 2] = raw[at + 1] * scale
            xy[index * 2 + 1] = raw[at + 2] * scale
        }
        check(xy.all { it.isFinite() })
        EgyptianGlyphRun(loadedFont.font, ids, xy, clusters, advance, ascent, descent, textSize)
    }
}
