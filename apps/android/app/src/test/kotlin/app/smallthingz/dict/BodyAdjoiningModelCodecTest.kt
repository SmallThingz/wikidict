package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal entry-tail controls; the body policy is data, not a source-cut certificate. */
class BodyAdjoiningModelCodecTest {
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "Body", "language", "Thai", "th")
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun header(bytes: ByteArray, version: Char) = bytes.copyOf().also { it[3] = version.code.toByte() }
    private fun rejects(label: String, bytes: ByteArray) = assertTrue(label, runCatching { read(bytes) }.isFailure)
    private val emptyO = hex("4450524f" + "00000000".repeat(7))
    private val emptyP = hex("44505250" + "00000000".repeat(7) + "01")

    private class Wire {
        private val out = ByteArrayOutputStream()
        var rulePresence = -1
            private set
        var inlineFlags = -1
            private set
        var mediaStart = -1
            private set
        fun byte(value: Int) { out.write(value) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (8 * it)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun span(text: String, target: String = "", external: Boolean = false,
            fragment: String? = null, styled: Boolean = false, trail: String = "") {
            byte(if (target.isEmpty()) 0 else if (external) 2 else 1); byte(0); byte(0)
            string(text); string(target); string(trail); string("th"); string(""); string(""); string("")
            byte(0); byte(0) // foreground and background
            byte(if (styled) 11 else 0) // scale, complete feature policy, independent inline effect
            if (styled) {
                f32(.75f); byte(1); byte(0) // normal-body basis and Normal font features
                inlineFlags = out.size(); byte(16); byte(0) // explicit Help, strict enum0
            }
            byte(0) // no image
            byte(if (fragment == null) 0 else 1); fragment?.let(::string)
            byte(0) // tooltip
        }
        fun block(kind: Int, body: () -> Unit = { u32(0) }) {
            byte(kind); byte(0); byte(0); body(); byte(0) // absent Feature
            string(""); string(""); byte(0) // list path/number and absent Table
            string(""); string("") // anchor and fallback
            repeat(4) { byte(0) } // absent alignment, style, Figure, anonymous flow
        }
        fun paragraph(text: String, target: String, styled: Boolean = false) {
            block(0) { u32(1); span(text, target, fragment = "part", styled = styled, trail = "!") }
        }
        fun rule() {
            block(11)
            rulePresence = out.size(); byte(1)
            length(1f); byte(1); string("#aabbcc")
            length(.2f, 1); length(0f); length(.2f, 1); length(0f)
        }
        fun section(name: String, anchor: String, content: () -> Unit) {
            byte(2); string(name); string(anchor); string(""); content()
        }
        fun document(): ByteArray {
            out.write("DPRO".encodeToByteArray())
            u32(1); span("Display outside body")
            u32(2)
            section("First", "first") {
                u32(1); block(13); u32(0); u32(2) // Container style and original ordered children
                rule(); paragraph("Body action", "Target", styled = true)
            }
            section("Second", "second") { u32(1); paragraph("Second action", "SecondTarget") }
            u32(1); span("Preamble outside body", "https://example.test/preamble", external = true)
            u32(0); u32(0) // organization lexemes and other sections
            u32(1); byte(1); u32(7); string("notes") // reference fragment
            u32(1); span("Reference outside body", "ReferenceTarget", fragment = "ref"); byte(0)
            mediaStart = out.size(); u32(1)
            string("Sound.ogg"); byte(1); string("Media outside body")
            return out.toByteArray()
        }
    }

    @Test fun policyIsExplicitAndEntryCopiesPreserveRawBodyMetadataNavigationAndActions() {
        val action = Span("link", "Body", "Target", targetFragment = "part")
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val child = Block("paragraph", 0, listOf(action))
        val container = Block("container", 0, emptyList(), container = Container(listOf(child),
            ContainerStyle(margins = StyleEdges(StyleLength(StyleLengthUnit.Px, 20f), zero,
                StyleLength(StyleLengthUnit.Px, 30f), zero))))
        val sections = listOf(Section(2, "First", emptyList(), "first"), Section(2, "Second", listOf(container), "second"))
        val reference = Reference(7, null, "notes", listOf(Span("link", "Reference", "ReferenceTarget")), ReferenceKind.Fragment)
        val legacy = Entry("Body", listOf(Span("text", "Display")), "language", "Thai", "th",
            sections, listOf(reference), preamble = listOf(Span("text", "Preamble")),
            media = listOf(Media("Sound.ogg", "audio", "Media")), edition = "th",
            navigationKind = "supplemental", navigationLanguage = "Navigation", contentDictionary = "immutable-source")
        assertNull(legacy.bodyAdjoining)
        val ordinary = legacy.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        assertEquals(BodyAdjoiningPolicy.Ordinary, ordinary.bodyAdjoining)
        assertSame(legacy.sections, ordinary.sections)
        assertSame(container.container!!.blocks.single(), ordinary.sections[1].blocks.single().container!!.blocks.single())
        assertSame(legacy.displayTitle, ordinary.displayTitle); assertSame(legacy.preamble, ordinary.preamble)
        assertSame(legacy.references, ordinary.references); assertSame(legacy.media, ordinary.media)
        assertEquals(legacy.key, ordinary.key); assertEquals(legacy.edition, ordinary.edition)
        assertEquals(legacy.navigationKind, ordinary.navigationKind)
        assertEquals(legacy.navigationLanguage, ordinary.navigationLanguage)
        assertEquals(legacy.contentDictionary, ordinary.contentDictionary)
        assertEquals(EntryLink("Target", "part"), action.entryLink())
        assertEquals(legacy, ordinary.copy(bodyAdjoining = null))
        val empty = Entry("Empty", emptyList(), "language", null, "", emptyList(), emptyList(),
            bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        assertTrue(empty.sections.isEmpty()); assertTrue(empty.readingRows.isEmpty())
    }

    @Test fun literalPEmptyTailIsRequiredWhileEveryOlderHeaderKeepsNullAndExactInputBytes() {
        assertEquals(33, emptyP.size)
        assertArrayEquals(header(emptyO, 'P') + byteArrayOf(1), emptyP)
        val ordinary = read(emptyP)
        assertEquals(BodyAdjoiningPolicy.Ordinary, ordinary.bodyAdjoining)
        assertTrue(ordinary.sections.isEmpty()); assertTrue(ordinary.readingRows.isEmpty())
        for (version in "23456789ABCDEFGHIJKLMNO") {
            val bytes = header(emptyO, version); val original = bytes.copyOf()
            val entry = read(bytes)
            assertNull("Legacy $version must not acquire body ownership", entry.bodyAdjoining)
            assertTrue(entry.sections.isEmpty()); assertTrue(entry.readingRows.isEmpty())
            assertArrayEquals(original, bytes)
            rejects("Legacy $version has no policy tail", bytes + byteArrayOf(1))
        }
    }

    @Test fun pInheritsCompleteOAndNBodyActionsAndLeavesReferenceMediaAndPreambleOutsideThePolicyField() {
        val wire = Wire(); val oldBytes = wire.document()
        val bytes = header(oldBytes, 'P') + byteArrayOf(1)
        val old = read(oldBytes); val actual = read(bytes)
        assertNull(old.bodyAdjoining)
        assertEquals(old.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary), actual)
        assertArrayEquals(oldBytes.copyOfRange(4, oldBytes.size), bytes.copyOfRange(4, bytes.size - 1))
        assertEquals(listOf("First", "Second"), actual.sections.map { it.title })
        assertEquals(listOf("first", "second"), actual.sections.map { it.anchor })
        val blocks = actual.sections[0].blocks.single().container!!.blocks
        assertEquals(listOf("rule", "paragraph"), blocks.map { it.kind })
        assertEquals(RuleStyle(StyleLength(StyleLengthUnit.Px, 1f), ContainerColor.Rgb("#aabbcc"),
            StyleEdges(StyleLength(StyleLengthUnit.Em, .2f), StyleLength(StyleLengthUnit.Px, 0f),
                StyleLength(StyleLengthUnit.Em, .2f), StyleLength(StyleLengthUnit.Px, 0f))), blocks[0].ruleStyle)
        val action = blocks[1].spans.single()
        assertEquals("Body action", action.text); assertEquals("!", action.trail)
        assertEquals(EntryLink("Target", "part"), action.entryLink())
        assertEquals(InlineTextStyle(cursor = InlineCursor.Help), action.inlineStyle)
        assertEquals(.75f, checkNotNull(action.fontScale), 0f)
        assertEquals(FontScaleBasis.NormalBody, action.fontScaleBasis)
        assertEquals(FontFeaturePolicy.Normal, action.fontFeatures)
        assertEquals(EntryLink("SecondTarget", "part"), actual.sections[1].blocks.single().spans.single().entryLink())
        assertEquals(old.preamble, actual.preamble); assertEquals(old.references, actual.references)
        assertEquals(listOf(Media("Sound.ogg", "audio", "Media outside body")), actual.media)
        assertEquals("https://example.test/preamble", actual.preamble.single().target)
        assertEquals(EntryLink("ReferenceTarget", "ref"), actual.references.single().spans.single().entryLink())
    }

    @Test fun pRejectsMissingZeroUnknownRepeatedOrTruncatedPolicyAndAnyTrailingData() {
        val bytes = header(Wire().document(), 'P') + byteArrayOf(1)
        for (value in listOf(0, 2, 127, 255))
            rejects("Closed policy byte$value", bytes.copyOf().also { it[it.lastIndex] = value.toByte() })
        for (length in 0 until bytes.size) rejects("P prefix$length", bytes.copyOf(length))
        rejects("Repeated policy", bytes + byteArrayOf(1))
        rejects("Trailing zero", bytes + byteArrayOf(0))
        rejects("Missing empty-body policy", header(emptyO, 'P'))
    }

    @Test fun pStillRejectsMalformedInheritedEffectsRuleFlagsAndPolicyBeforeMedia() {
        val wire = Wire(); val old = wire.document(); val bytes = header(old, 'P') + byteArrayOf(1)
        rejects("P inherited O reserved flags", bytes.copyOf().also { it[wire.inlineFlags] = 32 })
        rejects("P inherited N strict presence", bytes.copyOf().also { it[wire.rulePresence] = 2 })
        val moved = header(old, 'P').let {
            it.copyOfRange(0, wire.mediaStart) + byteArrayOf(1) + it.copyOfRange(wire.mediaStart, it.size)
        }
        rejects("Policy before media", moved)
        rejects("O cannot borrow the P tail", old + byteArrayOf(1))
    }

    @Test fun futureVRemainsUnknownWhileKnownPQRHaveNamedMalformedTailContrasts() {
        val future = runCatching { read(header(emptyP, 'V')) }.exceptionOrNull()
        assertTrue(future is IllegalArgumentException)
        assertEquals("Unsupported presentation format", future!!.message)
        val missingCorners = runCatching { read(header(emptyP, 'Q')) }.exceptionOrNull()
        assertTrue(missingCorners is IllegalArgumentException)
        assertEquals("Q version does not match corner or image alignment payload", missingCorners!!.message)
        val missingRFeatures = runCatching { read(header(emptyP, 'R')) }.exceptionOrNull()
        assertTrue(missingRFeatures is IllegalArgumentException)
        assertEquals("R version does not match intrinsic table viewport, rule clear, or image link paint payload", missingRFeatures!!.message)
        val malformed = runCatching { read(emptyP.copyOf().also { it[it.lastIndex] = 0 }) }.exceptionOrNull()
        assertTrue(malformed is IllegalArgumentException)
        assertEquals("Unsupported body adjoining policy", malformed!!.message)
        rejects("Known P missing mandatory tail", header(emptyO, 'P'))
        assertEquals(BodyAdjoiningPolicy.Ordinary, read(emptyP).bodyAdjoining)
        // Existing historical unknown-header controls remain unchanged; this names the new boundary.
    }
}
