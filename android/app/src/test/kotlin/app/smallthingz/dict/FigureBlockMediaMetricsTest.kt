package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FigureBlockMediaMetricsTest {
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val cap = AvailableWidthLimit(100f, zero)
    private val font = FigureMediaFont(NativePrimaryFontMetrics(-12f, 4f, 16f, 0f), 6f)
    private val normal = NativeUsedLineMetrics(-15f, 5f)
    private fun edges(left: Float = 0f, right: Float = 0f, top: Float = 0f, bottom: Float = 0f) =
        SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Px, top),
            SignedContainerMargin(StyleLengthUnit.Px, right), SignedContainerMargin(StyleLengthUnit.Px, bottom),
            SignedContainerMargin(StyleLengthUnit.Px, left))
    private fun wrapper(align: CellTextAlign = CellTextAlign.Left,
        height: ContainerLineHeight = ContainerLineHeight.Normal) = ContainerStyle(
        margins = edges(), width = ContainerWidth.Auto, textAlign = align, lineHeight = height, ownerFontScale = 1f)
    private fun metrics(wrapper: ContainerStyle = wrapper(), limit: AvailableWidthLimit? = cap,
        preferred: Long = 44, naturalWidth: Long = 60, naturalHeight: Long = 55,
        density: Float = 1f, normalBody: Float = 16f, mediaFont: FigureMediaFont = font,
        normalStrut: NativeUsedLineMetrics = normal, direction: BidiResolvedDirection = BidiResolvedDirection.Ltr,
        mediaDirection: BidiResolvedDirection = BidiResolvedDirection.Ltr) = FigureBlockMediaMetrics(
        wrapper, FigureMediaLayout(FigureMediaStrut(checkNotNull(wrapper.ownerFontScale), language = "vi",
            direction = mediaDirection), InlineBoxVerticalAlign.Middle, limit), preferred, naturalWidth,
        naturalHeight, density, normalBody, mediaFont, normalStrut, direction)

    @Test fun blockFillsAvailableWidthButImageUsesAuthenticatedRenditionRatio() {
        val result = metrics().resolve(200f)
        assertEquals(200f, result.box.content, 0f)
        assertEquals(200, result.metrics.width)
        assertEquals(44f, result.metrics.image.width, 0f)
        assertEquals(44f * 55f / 60f, result.metrics.image.height, .00001f)
        assertTrue(result.metrics.image.height != 40f)
        assertEquals(result.metrics.image.height, result.lineHeight, .00001f)
        assertEquals(0f, result.metrics.imageLeft, 0f)
        val dense = metrics(density = 1.5f).resolve(200f)
        assertEquals(66f, dense.metrics.image.width, 0f)
        assertEquals(60.5f, dense.metrics.image.height, 0f)
    }

    @Test fun percentageCapUsesFractionalContentWidthAndOneRatio() {
        val result = metrics().resolve(20.25f)
        assertEquals(20.25f, result.metrics.image.width, 0f)
        assertEquals(18.5625f, result.metrics.image.height, 0f)
        assertEquals(21, result.metrics.width)
        assertEquals(0, metrics().intrinsic().minimum)
        assertEquals(44, metrics().intrinsic().maximum)
        assertEquals(44, metrics(limit = null).intrinsic().minimum)
    }

    @Test fun physicalAlignmentRetainsOverflowOutsideAutoBlock() {
        val left = metrics(wrapper(CellTextAlign.Left), limit = null).resolve(20f)
        val centered = metrics(wrapper(CellTextAlign.Center), limit = null).resolve(20f)
        val right = metrics(wrapper(CellTextAlign.Right), limit = null).resolve(20f)
        assertEquals(20, centered.metrics.width)
        assertEquals(44f, centered.metrics.image.width, 0f)
        assertEquals(0f, left.metrics.imageLeft, 0f)
        assertEquals(-12f, centered.metrics.imageLeft, 0f)
        assertEquals(-24f, right.metrics.imageLeft, 0f)
        assertEquals(32f, centered.metrics.imageLeft + centered.metrics.image.width, 0f)
    }

    @Test fun normalStrutSurvivesTinyAndZeroCappedImageWithoutCaption() {
        val tiny = metrics(preferred = 2, naturalWidth = 1, naturalHeight = 1).resolve(100f)
        assertEquals(20f, tiny.lineHeight, 0f)
        assertEquals(11f, tiny.metrics.imageTop, 0f)
        assertEquals(20, tiny.metrics.height(0))
        val zeroWidth = metrics().resolve(0f)
        assertEquals(0f, zeroWidth.metrics.image.width, 0f)
        assertEquals(0f, zeroWidth.metrics.image.height, 0f)
        assertEquals(0, zeroWidth.metrics.width)
        assertEquals(20, zeroWidth.metrics.height(0))
        val zeroFont = FigureMediaFont(NativePrimaryFontMetrics(0f, 0f, 0f, 0f), 0f)
        val zeroLine = metrics(wrapper(height = ContainerLineHeight.Multiplier(0f)).copy(ownerFontScale = 0f),
            mediaFont = zeroFont, normalStrut = NativeUsedLineMetrics(0f, 0f)).resolve(0f)
        assertEquals(0, zeroLine.metrics.height(0))
    }

    @Test fun authoredLineHeightUsesOwnerFontButNormalizedLengthUsesBody() {
        val smallFont = FigureMediaFont(NativePrimaryFontMetrics(-8f, 2f, 10f, 0f), 4f)
        val multiplied = metrics(wrapper(height = ContainerLineHeight.Multiplier(3f)).copy(ownerFontScale = .5f),
            preferred = 1, naturalWidth = 1, naturalHeight = 1, normalBody = 20f, mediaFont = smallFont).resolve(100f)
        val length = metrics(wrapper(height = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 2f)))
            .copy(ownerFontScale = .5f), preferred = 1, naturalWidth = 1, naturalHeight = 1,
            normalBody = 20f, mediaFont = smallFont).resolve(100f)
        assertEquals(30f, multiplied.lineHeight, 0f)
        assertEquals(40f, length.lineHeight, 0f)
        // Null remains the original table-caption zero-strut policy.
        assertEquals(2f, figureMediaLine(font, InlineBoxVerticalAlign.Middle, 2f).height, 0f)
        assertEquals(20f, figureMediaLine(font, InlineBoxVerticalAlign.Middle, 2f, lineStrut = normal).height, 0f)
    }

    @Test fun imageSafetyProjectionKeepsBothAxesInOneScale() {
        val result = metrics(limit = null, preferred = 20000, naturalWidth = 1, naturalHeight = 2).resolve(100f)
        assertEquals(5000f, result.metrics.image.width, 0f)
        assertEquals(MaxComputedFontPixels, result.metrics.image.height, 0f)
        assertEquals(2f, result.metrics.image.height / result.metrics.image.width, 0f)
        assertEquals(100, result.metrics.width)
        assertEquals(5000, metrics(limit = null, preferred = 20000, naturalWidth = 1, naturalHeight = 2).intrinsic().maximum)
    }

    @Test fun fractionalAndSignedMarginsRemainSeparateFromIntegerAllocation() {
        val fraction = metrics(wrapper().copy(margins = edges(left = .25f, right = .5f))).resolve(200f)
        assertEquals(199.25f, fraction.box.borderBox, 0f)
        assertEquals(.25f, fraction.box.marginLeft, 0f)
        assertEquals(200, fraction.metrics.width)
        val signed = metrics(wrapper().copy(margins = edges(left = -2f, right = 1f, top = -3f))).resolve(100f)
        assertEquals(101f, signed.box.borderBox, 0f)
        assertEquals(-2f, signed.box.marginLeft, 0f)
        assertEquals(-3f, signed.margins.top, 0f)
        val auto = ContainerMargins(ContainerMargin.Length(zero), ContainerMargin.Auto,
            ContainerMargin.Length(zero), ContainerMargin.Auto)
        val filled = metrics(wrapper().copy(margins = null, marginValues = auto)).resolve(200f)
        assertEquals(200f, filled.box.borderBox, 0f)
        assertEquals(0f, filled.box.marginLeft, 0f)
    }

    @Test fun overconstrainedMarginsUseContainingDirectionIndependentlyOfMediaDirection() {
        val style = wrapper().copy(margins = edges(left = 60f, right = 70f))
        val ltr = metrics(style, direction = BidiResolvedDirection.Ltr,
            mediaDirection = BidiResolvedDirection.Rtl).resolve(100f)
        val rtl = metrics(style, direction = BidiResolvedDirection.Rtl,
            mediaDirection = BidiResolvedDirection.Ltr).resolve(100f)
        assertEquals(0f, ltr.box.content, 0f)
        assertEquals(60f, ltr.box.marginLeft, 0f)
        assertEquals(40f, ltr.box.marginRight, 0f)
        assertEquals(30f, rtl.box.marginLeft, 0f)
        assertEquals(70f, rtl.box.marginRight, 0f)
    }
}
