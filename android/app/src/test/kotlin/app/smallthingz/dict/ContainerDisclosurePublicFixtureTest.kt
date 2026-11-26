package app.smallthingz.dict

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test

/** Public full-entry control using pinned unit-test resources.
 * The DPRa fixture contains a captured IT button in a synthetic surrounding content graph.
 * Expected Entry is transcribed from the pinned typed JSON; no alternate binary or JSON decoder.
 * This is JVM decoder/model coverage, not UI/font/native-UA or whole-IT acceptance.
 */
class ContainerDisclosurePublicFixtureTest {
    private fun pinnedFile(name: String, size: Long, sha256: String): ByteArray {
        val resource = "/it-public-button/$name"
        val stream = javaClass.getResourceAsStream(resource)
        assertNotNull("Public fixture resource is missing: $resource", stream)
        val bytes = checkNotNull(stream).use { it.readBytes() }
        assertEquals("Retained fixture byte length", size, bytes.size.toLong())
        assertEquals(size.toInt(), bytes.size)
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        assertEquals("Retained fixture SHA256", sha256, digest)
        return bytes
    }

    private fun expectedEntry(): Entry {
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        fun edges(edge: ResolvedStyleBorderEdge) = StyleBorder.ResolvedEdges(edge, edge, edge, edge)
        val normal = ContainerDisclosureButtonState(FigureColor.Rgb("#efefef"),
            edges(ResolvedStyleBorderEdge.Outset(px(2f), StyleBorderPaint.Rgb("#000000"))))
        val pressed = ContainerDisclosureButtonState(FigureColor.Rgb("#efefef"),
            edges(ResolvedStyleBorderEdge.Inset(px(2f), StyleBorderPaint.Rgb("#000000"))))
        val labelState = LinkState("#000000", false)
        val labelPaint = ContainerDisclosureTextPaint(labelState, labelState, labelState, labelState)
        val disclosure = ContainerDisclosure(contentIndex = 1, initiallyCollapsed = true,
            expandLabel = "Mostra", collapseLabel = "Nascondi", focus = null,
            placement = ContainerDisclosurePlacement.FloatRight,
            foreground = FigureColor.Rgb("#000000"), direction = BidiResolvedDirection.Ltr,
            expandRun = ContainerDisclosureLabelRun(0, 6, labelPaint),
            collapseRun = ContainerDisclosureLabelRun(0, 8, labelPaint),
            button = ContainerDisclosureButton(ContainerDisclosureButtonAppearance.NativeButton,
                ContainerDisclosureNamedFont("Arial"), px(13.3333f), 400, false, ContainerLineHeight.Normal,
                StyleEdges(px(1f), px(6f), px(1f), px(6f)), normal, normal, pressed, pressed,
                ContainerDisclosureButtonFocus(ContainerDisclosureFocusMode.UaAuto,
                    FigureFocusOutline(px(1f), FigureColor.Rgb("#3366cc"), px(0f), px(0f))),
                outlineColors = null))
        val content = Block("container", 0, emptyList(), container = Container(listOf(
            Block("paragraph", 0, listOf(Span("text", "hidden text ", italic = true), Span("link", "action", target = "Target"))))))
        val owner = Block("container", 0, emptyList(), container = Container(listOf(
            Block("paragraph", 0, listOf(Span("text", "Notes outside content"))), content), disclosure = disclosure))
        return Entry(title = "disclosure", displayTitle = emptyList(), kind = "supplemental",
            language = null, languageCode = "", sections = listOf(Section(2, "body", listOf(owner))),
            references = emptyList(), organization = PresentationOrganization(emptyList(), emptyList()))
    }

    @Test fun public910ByteEntryMatchesPinnedTypedGraphAndEnforcesEnvelope() {
        val bytes = pinnedFile("capture-public.dpr", 910,
            "27031256936c60f44ab50494bc2854b404ea6b556b60c1cecbdf91b86b889502")
        pinnedFile("capture-public.json", 17103,
            "9c345a9612c878a35fd61e7487776d06fca51bebf2cb138bb3c1a182a6eb5703")
        assertEquals("DPRa", String(bytes, 0, 4, Charsets.US_ASCII))
        assertEquals(0x100100, ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).getInt(4))
        fun decode(input: ByteArray) = BlobDecoder.decode(input, "disclosure", "supplemental", null, "")
        val decoded = decode(bytes) // Actual complete public API: no Reader reflection or sliced payload.
        assertEquals(expectedEntry(), decoded)
        val owner = checkNotNull(decoded.sections.single().blocks.single().container)
        val disclosure = checkNotNull(owner.disclosure)
        assertEquals(1L, disclosure.contentIndex)
        val content = checkNotNull(owner.blocks[disclosure.contentIndex.toInt()].container)
        val authoredAction = content.blocks.single().spans[1]
        assertEquals(Span("link", "action", target = "Target"), authoredAction)
        val button = checkNotNull(disclosure.button)
        assertSame(button.hoverActive, button.state(true, true))
        assertSame(button.active, button.state(false, true))
        assertEquals(FigureColor.Rgb("#3366cc"), button.outlineColor(true, true))
        assertNull(button.outlineColors)

        // Full-entry envelope controls use this actual public fixture, not handmade enclosing bytes.
        assertThrows(Exception::class.java) { decode(bytes.copyOf(bytes.size - 1)) }
        assertThrows(Exception::class.java) { decode(bytes + byteArrayOf(0)) }
        assertThrows(Exception::class.java) { decode(bytes.copyOf().also { it[3] = '!'.code.toByte() }) }
        for (missingCapability in listOf(0x100, 0x100000)) {
            val changed = bytes.copyOf()
            ByteBuffer.wrap(changed).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(4, 0x100100 and missingCapability.inv())
            assertThrows(Exception::class.java) { decode(changed) }
        }
    }
}
