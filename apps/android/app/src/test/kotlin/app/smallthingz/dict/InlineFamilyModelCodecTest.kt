package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** API05 transport controls. Font installation, source whitespace and native projection remain separate. */
class InlineFamilyModelCodecTest {
    private val parentFamily get() = ContainerFontFamily.Stack(listOf("Declaring Family", "Second Family"), GenericFontFamily.Serif)
    private val childFamily get() = ContainerFontFamily.Stack(listOf("Child Family"), GenericFontFamily.SansSerif)
    private fun rejects(label: String, create: () -> Any?) = assertTrue(label, runCatching(create).isFailure)
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "Entry", "language", "Thai", "th")
    private fun rejectBytes(label: String, bytes: ByteArray) = rejects(label) { read(bytes) }
    private fun header(bytes: ByteArray, version: Char) = bytes.copyOf().also { it[3] = version.code.toByte() }

    @Test fun spanFamilyPreservesCompiledTextActionsTraitsMediaAndDeepCopyIdentity() {
        val old = Span("link", " A\u00a0 ", "Target", trail = "!", language = "th", classes = "Hani",
            direction = "rtl", bold = true, italic = true, code = true, small = true, role = "label",
            fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFeatures = FontFeaturePolicy.Normal, targetFragment = "part", tooltip = "hint")
        assertNull(old.fontFamily)
        val actual = old.copy(fontFamily = childFamily)
        assertEquals(old, actual.copy(fontFamily = null)); assertEquals(" A\u00a0 ", actual.text)
        assertEquals("!", actual.trail); assertEquals(EntryLink("Target", "part"), actual.entryLink())
        assertEquals(old.copy(), old); assertEquals(actual, actual.copy(fontFamily = childFamily.copy(names = listOf("Child Family"))))
        assertEquals(actual.hashCode(), actual.copy(fontFamily = childFamily.copy(names = listOf("Child Family"))).hashCode())
        assertNotEquals(actual, actual.copy(fontFamily = ContainerFontFamily.SansSerif))
        val image = InlineImage("Source.svg", widthPx = 20, alt = "Source")
        val media = Span("text", "", image = image, fontFamily = childFamily)
        assertSame(image, media.copy().image); assertSame(media.fontFamily, media.copy().fontFamily)
        val empty = Span("text", "", fontFamily = childFamily, inlineStyle = InlineTextStyle(
            lineHeight = InlineLineHeight.Computed(InlineComputedLength(1f, FontScaleBasis.NormalBody))))
        assertEquals("", empty.text); assertEquals(childFamily, empty.fontFamily)
    }

    @Test fun declaringFamilyIsIndependentButShiftedOwnerRequiresTheCompleteDeepFamilyTuple() {
        val declaring = InlineFontSnapshot(.75f, FontScaleBasis.NormalBody, language = "th", fontFamily = parentFamily)
        val unshifted = Span("text", "child", language = "th", fontScale = .75f,
            fontScaleBasis = FontScaleBasis.NormalBody, fontFamily = childFamily,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1.5f, declaring)))
        assertEquals(parentFamily, (unshifted.inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font.fontFamily)
        val shifted = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1.5f, declaring),
            baselineShift = InlineComputedLength(-.25f, FontScaleBasis.NormalBody))
        rejects("Different declared and run families") { unshifted.copy(inlineStyle = shifted) }
        val equalRequest = ContainerFontFamily.Stack(listOf("Declaring Family", "Second Family"), GenericFontFamily.Serif)
        assertNotSame(declaring.fontFamily, equalRequest)
        val exact = unshifted.copy(fontFamily = equalRequest, inlineStyle = shifted)
        assertTrue(declaring.matches(exact, false))
        assertFalse(declaring.matches(exact.copy(fontFamily = null, inlineStyle = null), false))
        for (other in listOf(ContainerFontFamily.Stack(equalRequest.names.reversed(), equalRequest.fallback),
            equalRequest.copy(fallback = GenericFontFamily.SansSerif), ContainerFontFamily.SansSerif))
            rejects("Changed family request $other") { exact.copy(fontFamily = other) }
        val inherited = declaring.copy(fontFamily = null)
        val legacy = exact.copy(fontFamily = null, inlineStyle = shifted.copy(
            lineHeight = InlineLineHeight.FontRelative(1.5f, inherited)))
        assertTrue(inherited.matches(legacy, false)); assertNull(inherited.fontFamily)
        assertNotEquals(declaring, declaring.copy(fontFamily = childFamily))
    }

    private enum class Sink { Display, Preamble, Body, Reference, TableCell, FigureContent, FigureCaption, Scope }
    private class Wire {
        private val out = ByteArrayOutputStream()
        val fontFlags = mutableListOf<Int>()
        val snapshotFaces = mutableListOf<Int>()
        val familyTags = mutableListOf<Int>()
        val familyFallbacks = mutableListOf<Int>()
        var tail = -1
            private set
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { byte(value); byte(value ushr 8) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (8 * it)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun length(value: Float) { byte(0); f32(value) }
        fun family(value: ContainerFontFamily) {
            familyTags += out.size()
            when (value) {
                ContainerFontFamily.SansSerif -> byte(0)
                is ContainerFontFamily.Stack -> {
                    byte(1); u32(value.names.size); value.names.forEach(::string)
                    familyFallbacks += out.size(); byte(value.fallback.ordinal)
                }
            }
        }
        fun snapshot(family: ContainerFontFamily?, scale: Float = .75f) {
            byte(1); f32(scale); byte(1)
            snapshotFaces += out.size(); byte(11 or (if (family != null) 16 else 0))
            string("th"); string(""); byte(0); byte(0)
            family?.let { this.family(it) }
        }
        fun linkPaint() {
            listOf("#111111", "#222222", "#333333", "#444444", "#555555", "#666666").forEach(::string)
            byte(64); byte(0); string("#777777"); string("#888888"); byte(3)
        }
        fun span(family: ContainerFontFamily?, declaring: ContainerFontFamily? = null,
            rich: Boolean = false, text: String = " A\u00a0 ", trail: String = "!") {
            byte(1); byte(0); byte(if (rich) 7 else 0)
            string(text); string("Target"); string(trail); string("th"); string("Hani"); string(""); string("")
            byte(0); byte(0)
            fontFlags += out.size(); byte((if (rich) 15 else 0) or (if (family != null) 16 else 0))
            if (rich) {
                f32(1.25f); byte(1); byte(0) // scale, independent basis, features
                byte(1); linkPaint()
                byte(18); byte(1); f32(1.5f); snapshot(declaring); byte(0) // font-relative + Help cursor
            }
            family?.let { this.family(it) }
            byte(0); byte(1); string("part"); byte(1); string("hint")
        }
        fun block(kind: Int = 0, level: Int = 0, anchor: String = "", text: (() -> Unit)? = null,
            table: (() -> Unit)? = null, figure: (() -> Unit)? = null, flow: (() -> Unit)? = null) {
            byte(kind); byte(0); byte(level); if (text == null) u32(0) else text()
            byte(0); string(""); string(""); if (table == null) byte(0) else table()
            string(anchor); string(""); byte(0); byte(0); if (figure == null) byte(0) else figure()
            byte(if (flow == null) 0 else 1); flow?.invoke()
        }
        fun figure(content: Boolean, selected: () -> Unit) {
            byte(2); byte(1); byte(0); byte(0); repeat(12) { length(0f) }
            f32(1f); length(1f); repeat(6) { byte(0) }
            if (content) selected() else span(null, text = "Missing", trail = "")
            length(2f); length(1f); byte(0)
            u32(if (content) 0 else 1); if (!content) selected()
            byte(0); byte(0); byte(0)
        }
        fun table(selected: () -> Unit) {
            byte(1); byte(0); u32(0); u32(1); u32(1)
            byte(0); u16(1); u16(1); byte(0); u32(1); selected()
            byte(0); byte(0); byte(0); byte(0); byte(0)
        }
        fun document(sink: Sink, family: ContainerFontFamily?, declaring: ContainerFontFamily? = null,
            rich: Boolean = false, features: Int? = 4): ByteArray {
            out.write((if (features == null) "DPRO" else "DPRP").encodeToByteArray())
            val selected = { span(family, declaring, rich, trail = if (sink == Sink.FigureContent) "" else "!") }
            u32(if (sink == Sink.Display) 1 else 0); if (sink == Sink.Display) selected()
            u32(1); byte(2); string("Body"); string(""); string("")
            val body = sink in listOf(Sink.Body, Sink.TableCell, Sink.FigureContent, Sink.FigureCaption, Sink.Scope)
            u32(if (body) 1 else 0)
            if (body) when (sink) {
                Sink.Body -> block(text = { u32(1); selected() })
                Sink.TableCell -> block(12, table = { table(selected) })
                Sink.FigureContent, Sink.FigureCaption -> block(figure = { figure(sink == Sink.FigureContent, selected) })
                Sink.Scope -> block(flow = {
                    u32(1); byte(2); byte(0); byte(2); byte(1); byte(0)
                    u32(1); byte(0); u32(1); selected()
                })
                else -> error("Unexpected body sink")
            }
            u32(if (sink == Sink.Preamble) 1 else 0); if (sink == Sink.Preamble) selected()
            u32(0); u32(0)
            u32(if (sink == Sink.Reference) 1 else 0)
            if (sink == Sink.Reference) { byte(1); u32(7); string("notes"); u32(1); selected(); byte(0) }
            u32(0)
            if (features != null) { tail = out.size(); byte(features) }
            return out.toByteArray()
        }
        fun headingDocument(boxFamily: ContainerFontFamily, snapshotFamily: ContainerFontFamily?, features: Int): ByteArray {
            out.write("DPRP".encodeToByteArray()); u32(0); u32(2)
            byte(0); string(""); string(""); string(""); u32(1)
            block(text = { u32(1); span(null, text = "Prefix ", trail = "!") })
            byte(3); string("Title"); string("title"); string(""); u32(1)
            block(9, 3, "title", text = { u32(1); span(null, text = "Title", trail = "") })
            repeat(5) { u32(0) }
            tail = out.size(); byte(features); u32(1); u32(1)
            u32(1 or 2 or 16 or 2048 or 4096 or 65536 or (1 shl 22))
            repeat(8) { length(0f) }; byte(0); byte(0); byte(0); f32(1f); family(boxFamily)
            snapshot(snapshotFamily, scale = 1f); byte(1)
            return out.toByteArray()
        }
    }
    private fun selected(entry: Entry, sink: Sink): Span = when (sink) {
        Sink.Display -> entry.displayTitle.single()
        Sink.Preamble -> entry.preamble.single()
        Sink.Body -> entry.sections.single().blocks.single().spans.single()
        Sink.Reference -> entry.references.single().spans.single()
        Sink.TableCell -> entry.sections.single().blocks.single().table!!.rows.single().single().spans.single()
        Sink.FigureContent -> entry.sections.single().blocks.single().figure!!.content.span
        Sink.FigureCaption -> entry.sections.single().blocks.single().figure!!.caption.single()
        Sink.Scope -> ((entry.sections.single().blocks.single().flow!!.single() as FlowPart.Scope).scope.parts.single()
            as FlowPart.Inline).spans.single()
    }

    @Test fun combinedFontFieldsKeepExactExistingOrderAndSeparateDeclaringFamilyFromRunFamily() {
        val wire = Wire(); val bytes = wire.document(Sink.Body, childFamily, parentFamily, rich = true)
        val original = bytes.copyOf(); val span = selected(read(bytes), Sink.Body)
        assertEquals(31, bytes[wire.fontFlags.single()].toInt() and 255)
        assertEquals(childFamily, span.fontFamily)
        val relative = span.inlineStyle!!.lineHeight as InlineLineHeight.FontRelative
        assertEquals(parentFamily, relative.font.fontFamily); assertEquals(1.5f, relative.factor, 0f)
        assertEquals(.75f, relative.font.fontScale!!, 0f); assertEquals(1.25f, span.fontScale!!, 0f)
        assertEquals(FontScaleBasis.NormalBody, span.fontScaleBasis); assertEquals(FontFeaturePolicy.Normal, span.fontFeatures)
        assertTrue(span.bold && span.italic && span.code); assertEquals("Hani", span.classes)
        assertEquals(InlineCursor.Help, span.inlineStyle!!.cursor)
        assertEquals("#333333", span.linkPaint!!.active.foreground)
        assertEquals("#777777", span.linkPaint!!.hoverActive.foreground); assertTrue(span.linkPaint!!.hoverActive.underline)
        assertEquals(" A\u00a0 ", span.text); assertEquals("!", span.trail)
        assertEquals(EntryLink("Target", "part"), span.entryLink()); assertEquals("hint", span.tooltip)
        assertEquals("th", relative.font.language); assertArrayEquals(original, bytes)
        assertTrue(wire.familyTags[0] < wire.familyTags[1]) // Declaring snapshot precedes the containing Span family.
    }

    @Test fun anyInlineFamilyIncludingSansRequiresFeatureFourAtEveryActualSpanSink() {
        for (sink in Sink.entries) for (family in listOf(ContainerFontFamily.SansSerif, childFamily)) {
            val wire = Wire(); val bytes = wire.document(sink, family)
            val actual = read(bytes); assertNull(actual.bodyAdjoining)
            assertEquals(family, selected(actual, sink).fontFamily)
            rejectBytes("Unflagged family $sink/$family", bytes.copyOf().also { it[wire.tail] = 1 })
            for (version in "MNO") rejectBytes("Old $version inline family $sink", header(bytes.copyOf(wire.tail), version))
            val ordinary = read(bytes.copyOf().also { it[wire.tail] = 5 })
            assertEquals(actual.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary), ordinary)
        }
        val snapshot = Wire(); val snapshotBytes = snapshot.document(Sink.Body, null,
            ContainerFontFamily.SansSerif, rich = true)
        val span = selected(read(snapshotBytes), Sink.Body)
        assertNull(span.fontFamily)
        assertEquals(ContainerFontFamily.SansSerif, (span.inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font.fontFamily)
        rejectBytes("Snapshot-only missing feature", snapshotBytes.copyOf().also { it[snapshot.tail] = 1 })
        for (version in "MNO") rejectBytes("Old $version snapshot family", header(snapshotBytes.copyOf(snapshot.tail), version))
    }

    @Test fun extendedMasksTruncationAndPayloadTagsRefuseWithoutChangingLegacyNullBytes() {
        val wire = Wire(); val bytes = wire.document(Sink.Body, childFamily, parentFamily, rich = true)
        rejectBytes("Unknown Span field", bytes.copyOf().also { it[wire.fontFlags.single()] = 63 })
        rejectBytes("Unknown snapshot face", bytes.copyOf().also { it[wire.snapshotFaces.single()] = 59 })
        for (offset in wire.familyTags) rejectBytes("Unknown family tag at $offset", bytes.copyOf().also { it[offset] = 2 })
        for (offset in wire.familyFallbacks) rejectBytes("Unknown generic fallback at $offset", bytes.copyOf().also { it[offset] = 2 })
        for (size in wire.familyTags.first() until bytes.size) rejectBytes("Truncated inline payload $size", bytes.copyOf(size))
        rejectBytes("Unused feature", Wire().document(Sink.Body, null))
        val old = Wire().document(Sink.Body, null, rich = true, features = null)
        val inherited = read(old)
        assertNull(selected(inherited, Sink.Body).fontFamily)
        assertNull((selected(inherited, Sink.Body).inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font.fontFamily)
        assertEquals(inherited.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary), read(header(old, 'P') + byteArrayOf(1)))
        val legacy = Wire().document(Sink.Body, null, features = null)
        for (version in "MNO") assertEquals(read(legacy), read(header(legacy, version)))
        val future = runCatching { read(header(legacy, 'V')) }.exceptionOrNull()
        assertEquals("Unsupported presentation format", future!!.message)
    }

    @Test fun headingSnapshotRequiresDeepBoxIdentityAndRealPrefixRetainsItsOwnIndicesAndBody() {
        val generic = ContainerFontFamily.SansSerif
        val nullSnapshot = read(Wire().headingDocument(generic, null, 3))
        val explicitSnapshot = read(Wire().headingDocument(generic, generic, 7))
        assertEquals(2, explicitSnapshot.sections.size)
        val prefix = explicitSnapshot.sections[0]
        assertEquals(0, prefix.level); assertEquals("", prefix.title); assertEquals("", prefix.anchor)
        assertNull(prefix.headingStyle); assertEquals("Prefix ", prefix.blocks.single().spans.single().text)
        assertEquals("!", prefix.blocks.single().spans.single().trail)
        assertEquals(EntryLink("Target", "part"), prefix.blocks.single().spans.single().entryLink())
        val heading = explicitSnapshot.sections[1]
        assertEquals("title", heading.anchor); assertEquals("Title", heading.title); assertEquals(3, heading.level)
        assertEquals(generic, heading.headingStyle!!.font.fontFamily)
        assertEquals(generic, heading.headingStyle!!.box.fontFamily)
        assertEquals("", heading.blocks.single().spans.single().direction)
        assertEquals(nullSnapshot.sections[0], prefix)
        assertEquals(nullSnapshot.sections[1].blocks, heading.blocks)
        val deep = parentFamily.copy(names = listOf("Declaring Family", "Second Family"))
        val stackHeading = read(Wire().headingDocument(parentFamily, deep, 6)).sections[1].headingStyle!!
        assertEquals(parentFamily, stackHeading.font.fontFamily); assertEquals(deep, stackHeading.box.fontFamily)
        for (different in listOf(childFamily, parentFamily.copy(names = parentFamily.names.reversed()),
            parentFamily.copy(fallback = GenericFontFamily.SansSerif)))
            rejectBytes("Heading owner mismatch $different", Wire().headingDocument(parentFamily, different, 6))
        rejectBytes("Generic snapshot still requires extended feature", Wire().headingDocument(generic, generic, 2))
        assertNull(read(Wire().headingDocument(generic, null, 2)).bodyAdjoining)
    }
}
