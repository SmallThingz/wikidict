package app.smallthingz.dict

import android.content.Context
import android.content.res.AssetManager
import android.graphics.Typeface
import android.graphics.fonts.Font as PlatformFont
import android.graphics.fonts.FontFamily as PlatformFontFamily
import android.graphics.fonts.FontStyle as PlatformFontStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import java.io.DataInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Session-owned, static upright TrueType only. These are exact identities, not aliases. */
internal data class NativeUserFontRequest(val family: String, val weight: FontWeight,
    val style: FontStyle, val sha256: String) {
    init {
        require(family.isNotEmpty() && family.length <= 128 && family == family.trim() &&
            family.none { it.isISOControl() }) { "Invalid requested font family" }
        require(weight == FontWeight.Normal && style == FontStyle.Normal) { "Only exact weight400 upright faces are supported" }
        require(Regex("[0-9a-f]{64}").matches(sha256)) { "Expected font SHA256 is required" }
    }
}

internal data class NativeSfntIdentity(val family: String, val postScriptName: String,
    val weight: Int, val sha256: String)

private const val MaxUserFontBytes = 4 * 1024 * 1024
private data class UserFontTable(val offset: Int, val length: Int)

/** Owns the sole private copy. No mutable buffer or caller-owned storage escapes. */
internal class NativeVerifiedUserFont private constructor(private val backing: ByteBuffer,
    val identity: NativeSfntIdentity) {
    fun load(): NativeRegisteredFont {
        // Duplicate cursors, not bytes: hash, SFNT inspection and Android use this same allocation.
        val font = PlatformFont.Builder(backing.asReadOnlyBuffer()).build()
        require(font.style.weight == identity.weight &&
            font.style.slant == PlatformFontStyle.FONT_SLANT_UPRIGHT && font.ttcIndex == 0 &&
            font.axes.isNullOrEmpty()) { "Platform font style differs from verified SFNT" }
        val family = PlatformFontFamily.Builder(font).build()
        val face = Typeface.CustomFallbackBuilder(family).setStyle(font.style).build()
        require(face.weight == identity.weight && !face.isItalic) { "Typeface style differs from verified SFNT" }
        return NativeRegisteredFont(this, font, identity, face)
    }

    companion object {
        /** Caller may release/mutate its array once this returns; registration never uses it again. */
        fun verify(bytes: ByteArray, request: NativeUserFontRequest): NativeVerifiedUserFont {
            require(bytes.size in 12..MaxUserFontBytes) { "User font exceeds the bounded SFNT input" }
            val owned = ByteBuffer.allocateDirect(bytes.size).apply { put(bytes); flip() }
                .asReadOnlyBuffer().order(ByteOrder.BIG_ENDIAN)
            val digest = MessageDigest.getInstance("SHA-256").apply { update(owned.asReadOnlyBuffer()) }
                .digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(digest == request.sha256) { "User font SHA256 mismatch" }
            val identity = inspectStaticSfnt(owned, request, digest)
            return NativeVerifiedUserFont(owned, identity)
        }
    }
}

/** Retain this entry/its registry for the composition lifetime; both native font and bytes stay live. */
internal class NativeRegisteredFont internal constructor(
    private val backingOwner: NativeVerifiedUserFont,
    private val platformFont: PlatformFont,
    val identity: NativeSfntIdentity,
    val typeface: Typeface,
) {
    val family: FontFamily = FontFamily(typeface)
}

internal fun registerNativeUserFont(bytes: ByteArray, request: NativeUserFontRequest): NativeRegisteredFont =
    NativeVerifiedUserFont.verify(bytes, request).load()

/** Immutable snapshot. Failed explicit registrations never become a device/default-font request. */
internal class NativeRegisteredFonts private constructor(private val entries: Map<Key, NativeRegisteredFont>) :
    NativeNamedFontProbe {
    private data class Key(val name: String, val weight: Int, val style: FontStyle)
    private val families = entries.keys.map { it.name }.toSet()

    fun registeredFont(name: String, weight: FontWeight, style: FontStyle): NativeRegisteredFont? {
        if (name !in families) return null
        return entries[Key(name, weight.weight, style)]
            ?: throw UnsupportedFloatLayout("Registered font has no exact requested weight/style: $name")
    }

    override fun load(context: Context, name: String, weight: FontWeight, style: FontStyle): Typeface? =
        registeredFont(name, weight, style)?.typeface

    /** Supply the inherited real OptionalLocal probe; only unregistered names reach it. */
    fun withDeviceFonts(inherited: NativeNamedFontProbe): NativeNamedFontProbe = object : NativeNamedFontProbe {
        override fun load(context: Context, name: String, weight: FontWeight, style: FontStyle): Typeface? =
            if (name in families) this@NativeRegisteredFonts.load(context, name, weight, style)
            else inherited.load(context, name, weight, style)
    }

    companion object {
        fun of(vararg faces: NativeRegisteredFont): NativeRegisteredFonts {
            require(faces.isNotEmpty() && faces.size <= 16) { "A font session needs 1..16 exact faces" }
            val entries = linkedMapOf<Key, NativeRegisteredFont>()
            for (face in faces) {
                val key = Key(face.identity.family, face.identity.weight, FontStyle.Normal)
                require(entries.put(key, face) == null) { "Duplicate registered font identity" }
            }
            return NativeRegisteredFonts(entries.toMap())
        }
    }
}

/** One immutable application asset, prepared before reader content is published. */
internal object NativePackagedFont {
    const val family = "Liberation Sans"
    private const val asset = "fonts/LiberationSans-Regular.ttf"
    private const val length = 410_820
    private const val sha256 = "bade59d822652f76e6941aa87b40a87c13d1cc70db98ededb5011127efafd1d3"

    @Volatile private var prepared: Result<NativeRegisteredFont>? = null

    suspend fun prepare(context: Context) {
        if (prepared != null) return
        withContext(Dispatchers.IO) {
            synchronized(this@NativePackagedFont) {
                if (prepared == null) {
                    prepared = try {
                        val bytes = DataInputStream(context.applicationContext.assets.open(asset, AssetManager.ACCESS_STREAMING))
                            .use { input ->
                                ByteArray(length).also {
                                    input.readFully(it)
                                    require(input.read() == -1) { "Packaged font length mismatch" }
                                }
                            }
                        Result.success(registerNativeUserFont(bytes,
                            NativeUserFontRequest(family, FontWeight.Normal, FontStyle.Normal, sha256)))
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (failure: Exception) {
                        Result.failure(failure)
                    }
                }
            }
        }
    }

    /** The synchronous Compose probe only reads the already prepared result. */
    fun load(weight: FontWeight, style: FontStyle): Typeface {
        if (weight != FontWeight.Normal || style != FontStyle.Normal)
            throw UnsupportedFloatLayout("Packaged Liberation Sans requires weight 400 upright.")
        val result = prepared ?: throw UnsupportedFloatLayout("Packaged Liberation Sans was not initialized.")
        return result.getOrElse { failure ->
            throw UnsupportedFloatLayout("Packaged Liberation Sans is unavailable.").apply { initCause(failure) }
        }.typeface
    }
}

private fun inspectStaticSfnt(data: ByteBuffer, request: NativeUserFontRequest, digest: String): NativeSfntIdentity {
    fun checkRange(offset: Long, length: Long, end: Int = data.limit()) {
        require(offset >= 0 && length >= 0 && offset <= end.toLong() && length <= end.toLong() - offset) {
            "SFNT range is out of bounds"
        }
    }
    fun u16(at: Int): Int { checkRange(at.toLong(), 2); return data.getShort(at).toInt() and 0xffff }
    fun u32(at: Int): Long { checkRange(at.toLong(), 4); return data.getInt(at).toLong() and 0xffffffffL }
    require(u32(0) == 0x00010000L) { "Only single-face TrueType SFNT is supported" }
    val count = u16(4)
    require(count in 1..64) { "SFNT table count is unsupported" }
    val directoryEnd = 12 + count * 16
    checkRange(12, count.toLong() * 16)
    val tables = linkedMapOf<String, UserFontTable>()
    repeat(count) { index ->
        val at = 12 + index * 16
        val tag = (0..3).map { (data.get(at + it).toInt() and 255).also { c ->
            require(c in 32..126) { "Invalid SFNT table tag" }
        }.toChar() }.joinToString("")
        val offset = u32(at + 8); val length = u32(at + 12)
        checkRange(offset, length)
        require(offset >= directoryEnd && offset % 4 == 0L && length > 0) { "Invalid SFNT table extent" }
        require(tables.put(tag, UserFontTable(offset.toInt(), length.toInt())) == null) { "Duplicate SFNT table" }
    }
    tables.values.sortedBy { it.offset }.zipWithNext().forEach { (a, b) ->
        require(a.offset.toLong() + a.length <= b.offset) { "Overlapping SFNT tables" }
    }
    require(listOf("fvar", "gvar", "avar", "CFF ", "CFF2").none { it in tables }) { "Variable/CFF fonts are unsupported" }
    fun table(tag: String, minimum: Int): UserFontTable = checkNotNull(tables[tag]) { "Missing SFNT $tag" }
        .also { require(it.length >= minimum) { "Truncated SFNT $tag" } }
    table("glyf", 1); table("loca", 4); table("hmtx", 4); table("cmap", 4)
    val hhea = table("hhea", 36)
    require(u32(hhea.offset) == 0x00010000L) { "Unsupported TrueType hhea version" }
    val maxp = table("maxp", 32)
    require(u32(maxp.offset) == 0x00010000L && u16(maxp.offset + 4) > 0) { "Unsupported TrueType maxp" }
    val head = table("head", 54)
    require(u32(head.offset) == 0x00010000L) { "Unsupported TrueType head version" }
    require(u32(head.offset + 12) == 0x5f0f3cf5L && u16(head.offset + 18) in 16..16384 &&
        u16(head.offset + 50) in 0..1) { "Invalid TrueType head" }
    val os2 = table("OS/2", 2)
    val os2Version = u16(os2.offset)
    val os2Minimum = when (os2Version) {
        0 -> 78
        1 -> 86
        2, 3, 4 -> 96
        5 -> 100
        else -> throw IllegalArgumentException("Unsupported OS/2 version")
    }
    require(os2.length >= os2Minimum) { "Truncated OS/2 version$os2Version" }
    val weight = u16(os2.offset + 4)
    val selection = u16(os2.offset + 62)
    val macStyle = u16(head.offset + 44)
    require(weight == request.weight.weight) { "SFNT weight differs from request" }
    require(selection and 0x201 == 0 && macStyle and 2 == 0) { "SFNT is not upright" }
    require(selection and 32 == 0 && macStyle and 1 == 0) { "Weight400 font must not declare bold" }
    require((selection and 32 != 0) == (macStyle and 1 != 0) &&
        !(selection and 64 != 0 && selection and 32 != 0)) { "Conflicting SFNT style metadata" }

    val name = table("name", 6)
    require(name.length <= 65536 && u16(name.offset) == 0) { "Unsupported SFNT name table" }
    val records = u16(name.offset + 2); val strings = u16(name.offset + 4)
    require(records in 1..512 && strings >= 6 + records * 12 && strings <= name.length) { "Invalid name directory" }
    checkRange(name.offset.toLong() + 6, records.toLong() * 12, name.offset + name.length)
    val names = mutableMapOf<Int, MutableSet<String>>()
    repeat(records) { index ->
        val at = name.offset + 6 + index * 12
        val platform = u16(at); val encoding = u16(at + 2); val id = u16(at + 6)
        val length = u16(at + 8); val offset = u16(at + 10)
        val first = name.offset.toLong() + strings + offset
        checkRange(first, length.toLong(), name.offset + name.length)
        if ((platform == 0 || platform == 3 && encoding in listOf(1, 10)) && id in listOf(1, 6, 16)) {
            require(length in 2..512 && length % 2 == 0) { "Invalid Unicode font name length" }
            val bytes = data.asReadOnlyBuffer().apply { position(first.toInt()); limit(first.toInt() + length) }
            val value = StandardCharsets.UTF_16BE.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(bytes).toString()
            require(value.isNotBlank() && value.none { it.isISOControl() }) { "Invalid Unicode font name" }
            names.getOrPut(id) { linkedSetOf() }.add(value)
        }
    }
    val family = (names[16] ?: names[1])?.singleOrNull()
    require(family == request.family) { "Requested family differs from actual SFNT family" }
    val postScript = names[6]?.singleOrNull()
    require(!postScript.isNullOrBlank()) { "Missing or conflicting SFNT PostScript name" }
    return NativeSfntIdentity(request.family, postScript, weight, digest)
}
