package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class NativeScrollportTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero = FloatMargins(0f, 0f, 0f, 0f)
    private class Wire {
        val output = ByteArrayOutputStream()
        fun byte(value: Int) { output.write(value) }
        fun short(value: Int) { byte(value); byte(value ushr 8) }
        fun int(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun text(value: String) { val bytes = value.encodeToByteArray(); int(bytes.size); output.write(bytes) }
    }
    private fun frame(version: Char, overflow: Int?) = Wire().apply {
        byte(68); byte(80); byte(82); byte(version.code); int(0)
        int(1); byte(2); text("Scrollport"); text(""); text(""); int(1)
        byte(13); byte(0); byte(0); int(0); byte(0); text(""); text(""); byte(0); text(""); text(""); repeat(4) { byte(0) }
        val flags = if (overflow == null) 0 else 0x8000
        if (version == 'M') int(flags) else short(flags)
        overflow?.let(::byte)
        int(0); int(0); int(0); int(1); int(0); int(0); int(0)
    }.output.toByteArray()
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "word", "language", "English", "en")

    @Test fun existingLAndMAutoBytesRemainSemanticAndUnknownValuesRefuse() {
        for (overflow in listOf(null, 0, 1)) {
            val legacy = frame('L', overflow)
            val current = frame('M', overflow)
            assertEquals(read(legacy).sections, read(current).sections)
            val style = read(current).sections.single().blocks.single().container!!.style
            assertEquals(when (overflow) { 0 -> ContainerOverflow.Visible; 1 -> ContainerOverflow.Auto; else -> null }, style.overflow)
            // The M style word only inserts two zero high bytes; no new scroll state is serialized.
            assertEquals(legacy.size + 2, current.size)
        }
        for (version in listOf('L', 'M')) {
            assertThrows(Exception::class.java) { read(frame(version, 2)) }
            val bytes = frame(version, 1)
            for (length in bytes.indices) assertThrows(Exception::class.java) { read(bytes.copyOf(length)) }
            assertThrows(Exception::class.java) { read(bytes + byteArrayOf(0)) }
        }
        for (version in listOf('J', 'K')) assertThrows(Exception::class.java) { read(frame(version, 1)) }
    }

    @Test fun autoHeightDomainAcceptsRealMax500ButRefusesUnprovedAxesAndContexts() {
        val auto = ContainerStyle(overflow = ContainerOverflow.Auto)
        assertNull(nativeScrollportUnavailable(auto))
        assertNull(nativeScrollportUnavailable(auto.copy(width = ContainerWidth.Auto,
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 500f)),
            padding = StyleEdges(px(1f), px(5f), px(1f), px(5f)), clear = FigureClear.Both)))
        val scalar = ContainerMargin.Length(px(0f))
        val unsupported = listOf(auto.copy(height = px(0f)), auto.copy(minHeight = px(0f)),
            auto.copy(layout = ContainerLayout.FlexRow), auto.copy(flexItem = ContainerFlexItem.None),
            auto.copy(columns = ContainerColumns(2, px(10f))), auto.copy(positioning = ContainerPositioning.RelativeAuto),
            auto.copy(floatSide = TableFloatSide.Left), auto.copy(screenMaxWidth = ContainerScreenMaxWidth(500, width = ContainerWidth.Auto)),
            auto.copy(width = ContainerWidth.FitContent), auto.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 100f))),
            auto.copy(maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 50f))),
            auto.copy(marginValues = ContainerMargins(scalar, scalar, scalar, scalar)),
            auto.copy(margins = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Px, -1f), px(0f), px(0f), px(0f))))
        unsupported.forEach { assertNotNull(it.toString(), nativeScrollportUnavailable(it)) }
        assertNotNull(nativeScrollportUnavailable(auto, flexItem = true))
        assertNull(nativeScrollportUnavailable(auto.copy(overflow = ContainerOverflow.Visible, height = px(10f))))
    }

    @Test fun scrollRangeUsesLayoutAndPaddingAndDetectsVerticalOverflowWithoutLosingBody() {
        val padding = FloatMargins(1.25f, 3.5f, 2.25f, 4.5f)
        val allocation = nativeScrollportAllocation(100, 30f, NativeFloatBounds(0f, 0f, 240f, 30f), padding)
        assertEquals(248, allocation.content); assertEquals(148, allocation.range)
        assertEquals(34, allocation.height); assertEquals(4.5f, allocation.originX, 0f)
        assertEquals(1.25f, allocation.originY, 0f); assertFalse(allocation.verticalOverflow); assertFalse(allocation.leadingOverflow)
        val fits = nativeScrollportAllocation(100, 30f, NativeFloatBounds(0f, 0f, 40f, 30f), padding)
        assertEquals(0, fits.range)
        val signed = nativeScrollportAllocation(100, 10f, NativeFloatBounds(-20f, -4f, 120f, 30f), zero)
        assertEquals(140, signed.content); assertEquals(20f, signed.originX, 0f)
        assertEquals(34, signed.height); assertEquals(4f, signed.originY, 0f)
        assertTrue(signed.verticalOverflow); assertTrue(signed.leadingOverflow)
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeScrollportAllocation(100, 10f, NativeFloatBounds(0f, 0f, TablePixelLimit.toFloat() + 1f, 10f), zero)
        }
    }

    @Test fun realAdapterKeepsOneChildGraphAndCountsPaddingAndBordersOnce() {
        val children = listOf(NativeFloatContextSpec.Child(10, { 700 }, 0f, widthFromContent = true),
            NativeFloatContextSpec.Child(11, { 800 }, 0f, widthFromContent = true))
        val style = ContainerStyle(overflow = ContainerOverflow.Auto,
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 500f)),
            padding = StyleEdges(px(3f), px(10f), px(7f), px(10f)),
            border = ContainerBorder.Solid(px(2f), ContainerColor.Transparent))
        val owner = nativeContainerSpec(7, style.atViewport(1000.0), children, 1f, 20f, false, false, false)
        assertNull(owner.unavailableReason); assertTrue(owner.isolatesFloats)
        val viewport = owner.preparedParts!!.single() as NativeFloatContextSpec.Child
        assertEquals(-8, viewport.id); assertSame(children, viewport.scrollport!!.parts)
        assertEquals(FloatMargins(3f, 10f, 7f, 10f), viewport.scrollport.padding)
        assertEquals(FloatMargins(2f, 2f, 2f, 2f), owner.padding(1000))
        assertEquals(520, owner.contentWidth(1000, ContainerWidths(820f, 820f)))
        assertEquals(296, owner.contentWidth(300, ContainerWidths(820f, 820f)))
        assertEquals(2f, owner.horizontal!!(1000, ContainerWidths(820f, 820f)).contentLeft, 0f)
        val ordinary = nativeContainerSpec(7, style.copy(overflow = ContainerOverflow.Visible).atViewport(1000.0),
            children, 1f, 20f, false, false, false)
        assertSame(children, ordinary.preparedParts)
        val refused = nativeContainerSpec(7, style.copy(height = px(10f)).atViewport(1000.0),
            children, 1f, 20f, false, false, false)
        assertNotNull(refused.unavailableReason); assertSame(children, refused.preparedParts)
    }

    @Test fun maxWidthKeepsBodyEmBasisAndBorderBoxContentResolution() {
        val style = ContainerStyle(overflow = ContainerOverflow.Auto, ownerFontScale = .5f,
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Em, 25f)),
            padding = StyleEdges(px(0f), px(5f), px(0f), px(5f)))
        val widths = ContainerWidths(800f, 800f)
        val content = containerBoxWidth(style.atViewport(1000.0), 1000f, widths, 2f, 20f)
        assertEquals(500f, content.content, 0f); assertEquals(520f, content.borderBox, 0f)
        val border = containerBoxWidth(style.copy(boxSizing = ContainerBoxSizing.BorderBox).atViewport(1000.0),
            1000f, widths, 2f, 20f)
        assertEquals(480f, border.content, 0f); assertEquals(500f, border.borderBox, 0f)
    }

    @Test fun scrollportBfcBlocksChildEscapeWithoutSummingExternalSiblingMargins() {
        val child = NativeFloatContextPart.Container(1, 100, { _, _ -> error("Structural only") },
            margins = SignedNativeContainerMargins(30f, 0f, 40f, 0f), preparedParts = emptyList())
        val owner = NativeFloatContextPart.Container(0, 100, { _, _ -> error("Structural only") },
            margins = SignedNativeContainerMargins(10f, 0f, 20f, 0f), preparedParts = listOf(child), isolatesFloats = true)
        val profile = checkNotNull(NativeFloatContextGeometry.adjoiningProfile(owner))
        assertEquals(10f, profile.before, 0f); assertEquals(20f, profile.after, 0f); assertFalse(profile.through)
        assertEquals(NativeMarginCollapse(false, false), owner.childCollapse(checkNotNull(NativeFloatContextGeometry.adjoiningProfile(child))))
        val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
        cursor.end(cursor.begin(profile), 50f, profile)
        assertEquals(90f, cursor.begin(NativeAdjoiningMargins(30f, 0f, false)).borderTop, 0f)
    }

    @Test fun failedMeasuredBodyExtentCannotLeakAcrossWidthOrSemanticRevision() {
        val input = NativeContextMeasureInput()
        val environment = NativeFlowEnvironment(1f, 1f, androidx.compose.ui.unit.LayoutDirection.Ltr,
            androidx.compose.ui.unit.IntSize(320, 640))
        val binding = NativeFlowBinding(environment, NativeTextInsets(), 0f)
        input.bind(binding)
        val constraints = androidx.compose.ui.unit.Constraints.fixedWidth(320)
        val policy = NativeFlowParentPolicy(Any(), true, null, 0f)
        val request = input.request(constraints, constraints, environment, policy, emptyList())
        val ticket = input.begin(binding, constraints)!!
        val failure = Result.failure<NativeFloatContextGeometry>(UnsupportedFloatLayout("Complete fallback body"))
        val bounds = NativeFloatBounds(0f, 0f, 900f, 100f)
        assertTrue(input.publish(ticket, failure, bounds))
        assertNull(input.ready(request))
        assertTrue(input.measured(request)!!.result.isFailure)
        assertEquals(bounds, input.measured(request)!!.fallbackBounds)
        val smaller = androidx.compose.ui.unit.Constraints.fixedWidth(200)
        val next = input.request(smaller, smaller, environment, policy, emptyList())
        assertNull(input.measured(request)); assertNull(input.measured(next))
        assertFalse(input.publish(ticket, failure, bounds))
        val current = input.begin(binding, smaller)!!
        assertTrue(input.publish(current, failure, bounds.copy(right = 700f)))
        input.semantic.changed()
        assertNull(input.measured(next)); assertFalse(input.publish(current, failure, bounds))
    }
}
