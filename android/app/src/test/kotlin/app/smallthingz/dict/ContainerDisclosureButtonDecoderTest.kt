package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import java.lang.reflect.InvocationTargetException
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

/** Integrate under android/app/src/test/kotlin/app/smallthingz/dict/.
 * Minimal NEW JVM delta inputs: patched BlobDecoder.kt and ContainerStyle.kt, new
 * ContainerDisclosureButton.kt, and this test; use the matching existing model/support module
 * as sources or friend module plus JDK 17, Kotlin stdlib, JUnit 4.13+ and Hamcrest.
 * No geometry/painter/toggle/Compose sources are added for the decoder-only target.
 * This does not establish a standalone support source closure or installed toolchain.
 * Deliberately synthetic tests of the actual private Reader seam. These are NOT encoder fixtures,
 * full DPRa round-trips, HU regression qualification, Android rendering or whole-edition acceptance.
 * Contract d0953f130cb7bd916be113ab9de9947b5424e9b12044b5cc0adb84d8e577eff2.
 */
class ContainerDisclosureButtonDecoderTest {
    private data class Packet(val bytes: ByteArray,val offsets: Map<String,Int>)
    private class Wire {
        val out=ByteArrayOutputStream()
        val offsets=mutableMapOf<String,Int>()
        fun mark(name: String) { offsets[name]=out.size() }
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { byte(value); byte(value ushr 8) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it*8)) } }
        fun float(value: Float) = u32(value.toRawBits())
        fun text(value: String) { val bytes=value.encodeToByteArray(); u32(bytes.size); out.write(bytes) }
        fun length(value: Float) { byte(0); float(value) }
        fun color(value: String) { byte(2); text(value) }
        fun run(end: Int) { u32(0); u32(end); repeat(4) { text("#000000") }; byte(0) }
        fun packet()=Packet(out.toByteArray(),offsets.toMap())
    }
    private fun packet(button: Boolean=true, options: Int=1, runs: Boolean=true,
        borderless: Boolean=false, legacyFocus: Boolean=false): Packet = Wire().apply {
        u32(1); byte(1); text("Mostra"); text("Nascondi")
        byte(if (legacyFocus) 1 else 0)
        if (legacyFocus) { byte(1); byte(0) }
        byte(2) // FloatRight
        mark("fields"); byte((if (button) 0x10 else 0) or if (runs) 0x0f else 0)
        if (runs) { color("#000000"); byte(0); run(6); run(8) }
        if (button) {
            mark("appearance"); byte(0)
            mark("family"); text("Arial")
            mark("size"); length(13.3333f)
            mark("weight"); u16(400)
            mark("italic"); byte(0)
            mark("lineHeight"); byte(0)
            mark("padding"); listOf(1f,6f,1f,6f).forEach(::length)
            repeat(4) { state ->
                mark("state$state"); color("#efefef")
                repeat(4) { edge ->
                    mark("edge$state-$edge")
                    if (borderless) byte(edge%2) else {
                        byte(if (state<2) 5 else 4); length(2f); byte(0); text("#000000")
                    }
                }
            }
            mark("options"); byte(options)
            if (options and 1 != 0) {
                mark("focus"); byte(1); length(1f); color("#3366cc"); length(0f); length(0f)
            }
            if (options and 2 != 0) {
                mark("outlineColors"); color("#111111"); color("#222222")
            }
        }
    }.packet()

    // Reflection confines tests to this new local field without introducing production test APIs
    // or pretending a handcrafted enclosing document came from the public encoder.
    private class Reader(bytes: ByteArray,budget: Int,positioned: Boolean,resolved: Boolean) {
        private val type=Class.forName("app.smallthingz.dict.BlobDecoder\$Reader")
        private val instance=type.getDeclaredConstructor(ByteArray::class.java).apply { isAccessible=true }.newInstance(bytes)
        private fun field(name: String)=type.getDeclaredField(name).apply { isAccessible=true }
        init {
            field("remainingItems").setInt(instance,budget)
            field("positionedContainers").setBoolean(instance,positioned)
            field("resolvedStyleBorders").setBoolean(instance,resolved)
            field("containerFonts").setBoolean(instance,true)
        }
        val remaining: Int get()=field("remainingItems").getInt(instance)
        val resolvedSeen: Boolean get()=field("hasResolvedStyleBorder").getBoolean(instance)
        val positionedSeen: Boolean get()=field("hasPositionedContainers").getBoolean(instance)
        val buffer: ByteBuffer get()=field("buffer").get(instance) as ByteBuffer
        fun read(): ContainerDisclosure = try {
            type.getDeclaredMethod("containerDisclosure").apply { isAccessible=true }.invoke(instance) as ContainerDisclosure
        } catch (failure: InvocationTargetException) { throw checkNotNull(failure.cause) }
    }
    private fun read(bytes: ByteArray,budget: Int=100,positioned: Boolean=true,resolved: Boolean=true)=
        Reader(bytes,budget,positioned,resolved)
    private fun changed(packet: Packet,key: String,value: Int,offset: Int=0)=packet.bytes.copyOf().also {
        it[checkNotNull(packet.offsets[key])+offset]=value.toByte()
    }

    @Test fun exactFieldOrderRetainsLabelsRunsAndConsumesOnlyDeclaredItems() {
        val packet=packet(options=3)
        val reader=read(packet.bytes,budget=6) // disclosure + two runs + button + focus + colors
        val decoded=reader.read()
        assertEquals(1L,decoded.contentIndex); assertTrue(decoded.initiallyCollapsed)
        assertEquals("Mostra",decoded.expandLabel); assertEquals("Nascondi",decoded.collapseLabel)
        assertEquals(ContainerDisclosurePlacement.FloatRight,decoded.placement)
        assertEquals(6L,decoded.expandRun!!.end); assertEquals(8L,decoded.collapseRun!!.end)
        assertEquals(BidiResolvedDirection.Ltr,decoded.direction)
        assertNull(decoded.focus)
        val button=checkNotNull(decoded.button)
        assertEquals(ContainerDisclosureNamedFont("Arial"),button.fontFamily)
        assertEquals(13.3333f,button.fontSize.value,0f)
        assertEquals(400,button.fontWeight); assertFalse(button.fontItalic)
        assertEquals(ContainerLineHeight.Normal,button.lineHeight)
        assertTrue(button.normal.border.top is ResolvedStyleBorderEdge.Outset)
        assertTrue(button.active.border.top is ResolvedStyleBorderEdge.Inset)
        assertEquals(FigureColor.Rgb("#3366cc"),button.outlineColor(true,true))
        assertEquals(FigureColor.Rgb("#111111"),button.outlineColor(false,false))
        assertEquals(FigureColor.Rgb("#222222"),button.outlineColor(true,false))
        assertEquals(0,reader.remaining); assertFalse(reader.buffer.hasRemaining())
        assertTrue(reader.resolvedSeen); assertTrue(reader.positionedSeen)
    }

    @Test fun everyOptionalCombinationHasExactBudgetAndNullRemainsUnspecified() {
        for (options in 0..3) {
            val bytes=packet(options=options,runs=false).bytes
            val items=2+Integer.bitCount(options)
            val reader=read(bytes,budget=items)
            val b=checkNotNull(reader.read().button)
            assertEquals(options and 1 != 0,b.focusVisible != null)
            assertEquals(options and 2 != 0,b.outlineColors != null)
            assertEquals(0,reader.remaining); assertFalse(reader.buffer.hasRemaining())
            assertThrows(Exception::class.java) { read(bytes,budget=items-1).read() }
        }
    }

    @Test fun borderlessButtonStillRequiresAndDiscoversResolvedCapability() {
        val bytes=packet(options=0,runs=false,borderless=true).bytes
        val reader=read(bytes,budget=2)
        val button=checkNotNull(reader.read().button)
        assertEquals(ResolvedStyleBorderEdge.None,button.normal.border.top)
        assertEquals(ResolvedStyleBorderEdge.Hidden,button.normal.border.right)
        assertTrue(reader.resolvedSeen); assertEquals(0,reader.remaining)
        assertThrows(Exception::class.java) { read(bytes,resolved=false).read() }
        assertThrows(Exception::class.java) { read(bytes,positioned=false).read() }
    }

    @Test fun absentButtonLeavesNextByteAndOldFocusAndBudgetUntouched() {
        for (focus in listOf(false,true)) {
            val packet=packet(button=false,runs=false,legacyFocus=focus)
            val reader=read(packet.bytes+byteArrayOf(0x71),budget=if (focus) 2 else 1,resolved=false)
            val decoded=reader.read()
            assertNull(decoded.button); assertEquals(focus,decoded.focus != null)
            assertEquals(0,reader.remaining); assertFalse(reader.resolvedSeen)
            assertEquals(0x71,reader.buffer.get().toInt())
        }
        assertThrows(Exception::class.java) { read(packet(legacyFocus=true).bytes).read() }
    }

    @Test fun unknownDisclosureAndButtonBitsNeverBecomeAnotherCapability() {
        val packet=packet(options=0,runs=false)
        for (bit in listOf(0x20,0x40,0x80))
            assertThrows(Exception::class.java) { read(changed(packet,"fields",0x10 or bit)).read() }
        for (bit in listOf(4,8,16,32,64,128))
            assertThrows(Exception::class.java) { read(changed(packet,"options",bit)).read() }
        // The unchanged public entry point must never admit private magic.
        assertThrows(Exception::class.java) { BlobDecoder.decode("DPR!".encodeToByteArray(),"test","language",null,"it") }
    }

    @Test fun malformedEnumsBooleansUnitsUtf8ColorsAndTruncationReject() {
        val packet=packet(options=3)
        for ((key,value,offset) in listOf(Triple("appearance",2,0),Triple("italic",2,0),
            Triple("italic",1,0),Triple("size",1,0),Triple("padding",1,0),Triple("weight",0,0),
            Triple("lineHeight",3,0),Triple("family",0xff,4),Triple("state0",0,0),
            Triple("edge0-0",6,0),Triple("edge0-0",1,6),Triple("focus",0,0),
            Triple("outlineColors",1,0)))
            assertThrows(Exception::class.java) { read(changed(packet,key,value,offset)).read() }
        for (length in packet.bytes.indices)
            assertThrows(Exception::class.java) { read(packet.bytes.copyOf(length)).read() }
    }
}
