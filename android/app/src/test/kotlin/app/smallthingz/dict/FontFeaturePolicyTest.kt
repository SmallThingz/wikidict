package app.smallthingz.dict

import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class FontFeaturePolicyTest {
    @Test fun explicitPoliciesReplaceTheWholeListAndNullKeepsLegacyInheritance() {
        val inherited = SpanStyle(fontFeatureSettings = "'dlig' 1, 'ss01' 1, 'liga' 0",
            fontWeight = FontWeight.Bold, fontStyle = FontStyle.Italic, letterSpacing = 2.sp)
        val on = inherited.merge(SpanStyle(fontFeatureSettings = FontFeaturePolicy.SevenOn.nativeSettings))
        assertEquals("'liga' 1, 'clig' 1, 'kern' 1, 'ccmp' 1, 'dist' 1, 'mark' 1, 'mkmk' 1", on.fontFeatureSettings)
        assertFalse(on.fontFeatureSettings!!.contains("dlig")); assertFalse(on.fontFeatureSettings!!.contains("ss01"))
        val reset = on.merge(SpanStyle(fontFeatureSettings = FontFeaturePolicy.Normal.nativeSettings))
        assertEquals("", reset.fontFeatureSettings)
        assertEquals(inherited, inherited.merge(SpanStyle(fontFeatureSettings = null)))
        assertEquals(reset, reset.merge(SpanStyle(fontFeatureSettings = null)))
        for (style in listOf(on, reset)) {
            assertEquals(FontWeight.Bold, style.fontWeight); assertEquals(FontStyle.Italic, style.fontStyle)
            assertEquals(2.sp, style.letterSpacing)
        }
    }

    @Test fun egyptianRunsRetainExplicitNormalAndOnPoliciesForVisibleRefusal() {
        val source = Span("link", "\uD80C\uDC00", "Glyph", trail = "!", classes = "Egyp", direction = "ltr")
        requireEgyptianFeatureSupport(null)
        for (policy in FontFeaturePolicy.entries) {
            val span = source.copy(fontFeatures = policy)
            val run = egyptianTextRuns(listOf(span)).single()
            assertEquals(policy, run.fontFeatures); assertEquals(source.text, run.text)
            assertEquals(1, run.start); assertEquals(1 + source.text.length, run.end)
            assertEquals("Glyph", span.target); assertEquals("!", span.trail)
            assertThrows(UnsupportedOperationException::class.java) { requireEgyptianFeatureSupport(run.fontFeatures) }
        }
        assertNull(egyptianTextRuns(listOf(source)).single().fontFeatures)
    }

    private class Wire(val version: Char = 'M') {
        private val out = ByteArrayOutputStream()
        var fieldsAt = -1
        var policyAt = -1
        fun byte(n: Int) { out.write(n) }
        fun u32(n: Int) { repeat(4) { byte(n ushr (it * 8)) } }
        fun string(s: String) { val b = s.encodeToByteArray(); u32(b.size); out.write(b) }
        fun document(policy: Int?, size: Float? = null, basis: Int = 0): ByteArray {
            out.write("DPR$version".encodeToByteArray()); u32(1)
            byte(1); byte(0); byte(3)
            listOf("office", "Target", "!", "th", "source-feature", "ltr", "meaning").forEach(::string)
            byte(0); byte(0); fieldsAt = out.size(); byte((if (size != null) 1 else 0) or (if (policy != null) 2 else 0))
            if (size != null) { u32(size.toRawBits()); byte(basis) }
            if (policy != null) { policyAt = out.size(); byte(policy) }
            byte(0); byte(1); string("part"); byte(1); string("feature tooltip")
            repeat(6) { u32(0) }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "feature", "language", "Thai", "th").displayTitle.single()

    @Test fun mFontFlagsPreserveExplicitPoliciesAlongsideZeroOneAndCssPixelScale() {
        for (policy in FontFeaturePolicy.entries) for (size in listOf<Float?>(null, 0f, 1f, 12.375f)) {
            val value = read(Wire().document(policy.ordinal, size, 2))
            assertEquals(policy, value.fontFeatures); assertEquals(size, value.fontScale)
            assertEquals(if (size == null) FontScaleBasis.Context else FontScaleBasis.CssPx, value.fontScaleBasis)
            assertEquals("office", value.text); assertEquals("Target", value.target); assertEquals("part", value.targetFragment)
            assertEquals("!", value.trail); assertEquals("feature tooltip", value.tooltip)
            assertTrue(value.bold && value.italic); assertEquals("th", value.language)
        }
    }

    @Test fun absentFeatureBytesRemainOldCompatibleAndUnknownFlagsPoliciesAndTruncationsRefuse() {
        for (size in listOf<Float?>(null, 0f, 1.25f)) {
            val old = Wire('L').document(null, size, 1)
            val current = Wire('M').document(null, size, 1)
            assertArrayEquals(old.drop(4).toByteArray(), current.drop(4).toByteArray())
            assertEquals(read(old), read(current)); assertNull(read(current).fontFeatures)
        }
        for (policy in listOf(0, 1)) {
            val wire = Wire(); val good = wire.document(policy, 12f, 2)
            for (flag in listOf(8, 16, 255)) {
                val bad = good.copyOf(); bad[wire.fieldsAt] = flag.toByte()
                assertThrows(RuntimeException::class.java) { read(bad) }
            }
            for (unknown in listOf(2, 255)) {
                val bad = good.copyOf(); bad[wire.policyAt] = unknown.toByte()
                assertThrows(RuntimeException::class.java) { read(bad) }
            }
            for (end in good.indices) assertThrows("prefix $end", RuntimeException::class.java) { read(good.copyOf(end)) }
            assertThrows(RuntimeException::class.java) { read(good + byteArrayOf(0)) }
            for (version in listOf('H', 'I', 'J', 'K', 'L')) {
                val bad = good.copyOf(); bad[3] = version.code.toByte()
                assertThrows(RuntimeException::class.java) { read(bad) }
            }
        }
    }
}
