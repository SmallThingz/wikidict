package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class ContainerPixelLayoutTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun all(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private val blue = ContainerColor.Rgb("#0000ff")

    @Test fun fixedWidthKeepsVisibleOverflowWhileFloatedAutoUsesRealIntrinsicBounds() {
        val intrinsic = ContainerWidths(180f, 420f)
        val fixed = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 65f)),
            padding = all(3f), border = ContainerBorder.Solid(px(1f), blue))
        val box = containerBoxWidth(fixed, 300f, intrinsic, 1f, 20f)
        assertEquals(65f, box.content, 0f); assertEquals(73f, box.borderBox, 0f)
        assertTrue("An unbreakable child may overflow a fixed CSS box", box.content < intrinsic.minimum)
        val floated = fixed.copy(width = null, floatSide = TableFloatSide.Right)
        assertEquals(292f, containerBoxWidth(floated, 300f, intrinsic, 1f, 20f).content, 0f)
        assertEquals(180f, containerBoxWidth(floated, 100f, intrinsic, 1f, 20f).content, 0f)
        assertEquals(420f, containerBoxWidth(floated, 900f, intrinsic, 1f, 20f).content, 0f)
        assertEquals(0f, containerBoxWidth(fixed.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 0f))),
            300f, intrinsic, 1f, 20f).content, 0f)
    }

    @Test fun viewportConditionAndContainingWidthAreDifferentAxesAndBorderBoxKeepsInsetsOutsideContent() {
        val style = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 250f)),
            padding = all(4f), border = ContainerBorder.Solid(px(1f), blue),
            screenMaxWidth = ContainerScreenMaxWidth(719,
                width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
                maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
                boxSizing = ContainerBoxSizing.BorderBox, lineHeight = ContainerLineHeight.Multiplier(1.5f)))
        val intrinsic = ContainerWidths(20f, 300f)
        val wideViewport = containerBoxWidth(style.atViewport(800f), 80f, intrinsic, 1f, 20f)
        assertEquals(250f, wideViewport.content, 0f); assertEquals(260f, wideViewport.borderBox, 0f)
        val narrowViewport = containerBoxWidth(style.atViewport(719f), 80f, intrinsic, 1f, 20f)
        assertEquals(70f, narrowViewport.content, 0f); assertEquals(80f, narrowViewport.borderBox, 0f)
        val tiny = containerBoxWidth(style.atViewport(719f), 5f, intrinsic, 1f, 20f)
        assertEquals(0f, tiny.content, 0f); assertEquals(10f, tiny.borderBox, 0f)
    }

    @Test fun computedEmLengthsStayAtBodyBasisWhileInheritedUnitlessLineHeightTracksChildFont() {
        val length = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 1.35f))
        val multiplier = ContainerLineHeight.Multiplier(1.5f)
        assertEquals(27f, containerLineHeightPixels(length, 2f, 20f, 16f)!!, .0001f)
        assertEquals(27f, containerLineHeightPixels(length, 2f, 20f, 32f)!!, .0001f)
        assertEquals(24f, containerLineHeightPixels(multiplier, 2f, 20f, 16f)!!, 0f)
        assertEquals(48f, containerLineHeightPixels(multiplier, 2f, 20f, 32f)!!, 0f)
        assertEquals(0f, containerLineHeightPixels(ContainerLineHeight.Multiplier(0f), 2f, 20f, 16f)!!, 0f)
        assertNull(containerLineHeightPixels(ContainerLineHeight.Normal, 2f, 20f, 16f))
    }

    @Test fun flexNoneLogoDoesNotShrinkAndUnbreakableTextMinimumOverflowsWithoutClippingOrNewOwner() {
        val items = listOf(ContainerFlexWidth(40f, 40f, 0f, shrink = false),
            ContainerFlexWidth(180f, 70f, 11f))
        assertEquals(listOf(40f, 149f), containerFlexWidths(200f, items))
        assertEquals(listOf(40f, 70f), containerFlexWidths(80f, items))
        assertEquals(listOf(40f, 180f), containerFlexWidths(400f, items))
        val three = listOf(ContainerFlexWidth(100f, 80f, 0f), ContainerFlexWidth(100f, 20f, 0f),
            ContainerFlexWidth(100f, 20f, 0f))
        assertEquals(listOf(80f, 50f, 50f), containerFlexWidths(180f, three))
    }

    @Test fun automaticFlexBasisUsesMaxContentAndFixedSuggestionsDoNotTurnIntoTableMinimums() {
        val intrinsic = ContainerWidths(180f, 420f)
        val automatic = ContainerStyle(floatSide = TableFloatSide.Left,
            padding = all(3f), border = ContainerBorder.Solid(px(1f), blue))
        val auto = containerFlexMeasure(automatic, 800f, intrinsic, 1f, 20f)
        assertEquals(420f, auto.basis, 0f)
        assertEquals(180f, auto.minimum, 0f)
        assertEquals(8f, auto.outerEdges, 0f)
        assertEquals(listOf(420f), containerFlexWidths(800f, listOf(auto)))
        assertEquals(listOf(292f), containerFlexWidths(300f, listOf(auto)))
        val fixed = automatic.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 65f)))
        val fixedMeasure = containerFlexMeasure(fixed, 300f, intrinsic, 1f, 20f)
        assertEquals(65f, fixedMeasure.basis, 0f)
        assertEquals(65f, fixedMeasure.minimum, 0f)
        assertEquals(listOf(65f), containerFlexWidths(40f, listOf(fixedMeasure)))
        val zero = containerFlexMeasure(fixed.copy(width = ContainerWidth.Length(
            StyleWidth(StyleWidthUnit.Px, 0f))), 300f, intrinsic, 1f, 20f)
        assertEquals(0f, zero.basis, 0f); assertEquals(0f, zero.minimum, 0f)
        val limited = containerFlexMeasure(automatic.copy(maxWidth = ContainerMaxWidth.Length(
            StyleWidth(StyleWidthUnit.Px, 50f)), flexItem = ContainerFlexItem.None), 300f, intrinsic, 1f, 20f)
        assertEquals(420f, limited.basis, 0f); assertEquals(50f, limited.minimum, 0f)
        assertEquals(50f, limited.maximum!!, 0f)
        assertFalse(limited.shrink)
        assertEquals(listOf(50f), containerFlexWidths(300f, listOf(limited)))
    }

    @Test fun maxWidthClampsAfterWeightedShrinkAndBorderBoxZeroKeepsItsNegativeInnerBase() {
        val bounded = containerFlexMeasure(ContainerStyle(maxWidth = ContainerMaxWidth.Length(
            StyleWidth(StyleWidthUnit.Px, 50f))), 100f, ContainerWidths(20f, 420f), 1f, 20f)
        assertEquals(420f, bounded.basis, 0f)
        assertEquals(20f, bounded.minimum, 0f)
        assertEquals(50f, bounded.maximum!!, 0f)
        val other = ContainerFlexWidth(100f, 20f, 0f)
        assertEquals(listOf(50f, 50f), containerFlexWidths(100f, listOf(bounded, other)))
        assertEquals(listOf(50f, 100f), containerFlexWidths(200f, listOf(bounded, other)))
        val zero = containerFlexMeasure(ContainerStyle(
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 0f)),
            boxSizing = ContainerBoxSizing.BorderBox, padding = all(3f),
            border = ContainerBorder.Solid(px(1f), blue)), 100f, ContainerWidths(20f, 420f), 1f, 20f)
        assertEquals(-8f, zero.basis, 0f)
        assertEquals(8f, zero.outerEdges, 0f)
        assertEquals(0f, zero.minimum, 0f)
        assertEquals(listOf(0f), containerFlexWidths(100f, listOf(zero)))
        assertEquals(listOf(0f), containerFlexWidths(0f, listOf(zero)))
    }

    @Test fun responsiveFloatResetResolvesAutoMarginsAfterWidthAndDoesNotResizeItsNoresizeChild() {
        val margins = ContainerMargins(ContainerMargin.Length(px(0f)), ContainerMargin.Auto,
            ContainerMargin.Length(px(0f)), ContainerMargin.Auto)
        val style = ContainerStyle(floatSide = TableFloatSide.Left,
            padding = all(4f), border = ContainerBorder.Solid(px(1f), blue),
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
            overflow = ContainerOverflow.Auto,
            screenMaxWidth = ContainerScreenMaxWidth(639, floatSide = ContainerFloatOverride.None, margins = margins))
        val child = ContainerWidths(500f, 500f)
        val floated = containerBoxWidth(style.atViewport(640f), 200f, child, 1f, 20f)
        assertEquals(200f, floated.content, 0f)
        assertEquals(210f, floated.borderBox, 0f)
        assertEquals(0f, floated.marginLeft, 0f)
        assertEquals(0f, floated.marginRight, 0f)
        val reset = containerBoxWidth(style.atViewport(639f), 200f, child, 1f, 20f)
        assertEquals(190f, reset.content, 0f)
        assertEquals(200f, reset.borderBox, 0f)
        assertEquals(0f, reset.marginLeft, 0f)
        assertEquals(0f, reset.marginRight, 0f)
        assertTrue("The child retains its own width and needs a real scroll viewport", child.minimum > reset.content)
        val capped = style.copy(maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 100f)))
        val centered = containerBoxWidth(capped.atViewport(639f), 200f, child, 1f, 20f)
        assertEquals(100f, centered.content, 0f)
        assertEquals(45f, centered.marginLeft, 0f)
        assertEquals(45f, centered.marginRight, 0f)
    }

    @Test fun overconstrainedNormalBoxKeepsAuthoredWidthAndSolvesDirectionDependentUsedEndMargin() {
        val style = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 250f)),
            screenMaxWidth = ContainerScreenMaxWidth(639, margins = ContainerMargins(
                ContainerMargin.Length(px(0f)), ContainerMargin.Auto, ContainerMargin.Length(px(0f)), ContainerMargin.Auto)))
        val resolved = style.atViewport(639f)
        val ltr = containerBoxWidth(resolved, 200f, ContainerWidths(10f, 300f), 1f, 20f)
        val rtl = containerBoxWidth(resolved, 200f, ContainerWidths(10f, 300f), 1f, 20f, rtl = true)
        assertEquals(250f, ltr.content, 0f); assertEquals(250f, rtl.content, 0f)
        assertEquals(0f, ltr.marginLeft, 0f); assertEquals(-50f, ltr.marginRight, 0f)
        assertEquals(-50f, rtl.marginLeft, 0f); assertEquals(0f, rtl.marginRight, 0f)
        assertEquals(200f, ltr.marginBox, 0f); assertEquals(200f, rtl.marginBox, 0f)
        assertThrows(IllegalArgumentException::class.java) {
            containerBoxWidth(style, 200f, ContainerWidths(10f, 300f), 1f, 20f)
        }
    }

    @Test fun scrollableFlexItemCanShrinkBelowContentMinimumWithoutChangingChildPixels() {
        val child = ContainerWidths(500f, 500f)
        val normal = containerFlexMeasure(ContainerStyle(), 200f, child, 1f, 20f)
        val scrolling = containerFlexMeasure(ContainerStyle(overflow = ContainerOverflow.Auto), 200f, child, 1f, 20f)
        assertEquals(500f, normal.minimum, 0f); assertEquals(0f, scrolling.minimum, 0f)
        assertEquals(listOf(500f), containerFlexWidths(200f, listOf(normal)))
        assertEquals(listOf(200f), containerFlexWidths(200f, listOf(scrolling)))
        assertEquals(500f, scrolling.basis, 0f); assertEquals(500f, child.minimum, 0f)
    }

    @Test fun flexAutoMarginsShareOnlyRemainingRowSpaceAndDoNotInflateIntrinsicBases() {
        val style = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 40f)),
            screenMaxWidth = ContainerScreenMaxWidth(639, margins = ContainerMargins(
                ContainerMargin.Length(px(0f)), ContainerMargin.Auto,
                ContainerMargin.Length(px(0f)), ContainerMargin.Auto)))
        val centered = containerFlexMeasure(style.atViewport(639f), 200f, ContainerWidths(10f, 40f), 1f, 20f)
        val sibling = ContainerFlexWidth(60f, 60f, 0f, shrink = false)
        val items = listOf(centered, sibling)
        val widths = containerFlexWidths(200f, items)
        assertEquals(listOf(40f, 60f), widths)
        assertEquals(listOf(50f to 50f, 0f to 0f), containerFlexMargins(200f, items, widths))
        val smallWidths = containerFlexWidths(50f, items)
        assertEquals(listOf(10f, 60f), smallWidths)
        assertEquals(listOf(0f to 0f, 0f to 0f), containerFlexMargins(50f, items, smallWidths))
    }
    @Test fun rowIntrinsicContributionsKeepNativeContentButResolveDefiniteWidthsAndEdges() {
        val native = ContainerWidths(30f, 90f)
        val automatic = ContainerStyle(padding = all(2f), border = ContainerBorder.Solid(px(1f), blue),
            margins = StyleEdges(px(0f), px(5f), px(0f), px(3f)))
        fun contribution(style: ContainerStyle, maximum: Boolean) =
            containerFlexIntrinsicContribution(style.atViewport(800f), native, 1f, 20f, maximum)
        assertEquals(44f, contribution(automatic, false), 0f)
        assertEquals(104f, contribution(automatic, true), 0f)
        assertEquals(44f, contribution(automatic.copy(flexItem = ContainerFlexItem.None), false), 0f)
        assertEquals(104f, contribution(automatic.copy(width = ContainerWidth.FitContent), true), 0f)
        val fixed = automatic.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 60f)))
        assertEquals(74f, contribution(fixed, false), 0f)
        assertEquals(74f, contribution(fixed, true), 0f)
        val bounded = fixed.copy(maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 40f)))
        assertEquals(54f, contribution(bounded, false), 0f)
        assertEquals(54f, contribution(bounded, true), 0f)
        val borderBox = fixed.copy(boxSizing = ContainerBoxSizing.BorderBox)
        assertEquals(68f, contribution(borderBox, false), 0f)
        assertEquals(68f, contribution(borderBox, true), 0f)
        val zero = borderBox.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 0f)))
        assertEquals(14f, contribution(zero, false), 0f)
        val percentage = automatic.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 50f)),
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 25f)))
        assertEquals(44f, contribution(percentage, false), 0f)
        assertEquals(104f, contribution(percentage, true), 0f)
        val item = NativeFlexItemSpec(
            { width, intrinsic -> containerFlexMeasure(percentage.atViewport(800f), width, intrinsic, 1f, 20f) },
            { intrinsic, maximum -> containerFlexIntrinsicContribution(percentage.atViewport(800f), intrinsic, 1f, 20f, maximum) })
        val actual = item.measure(100.5f, native)
        assertEquals(50.25f, actual.basis, 0f)
        assertEquals(25.125f, actual.maximum!!, 0f)
        assertEquals(listOf(25.125f), containerFlexWidths(100.5f, listOf(actual)))
    }

    @Test fun rowCrossAutoMarginsTakeFreeSpaceBeforeAlignmentAndZeroRemainsZero() {
        for (alignment in ContainerAlignItems.entries) {
            assertEquals(NativeFlexCrossPlacement(38f, 20f),
                nativeFlexCrossPlacement(65f, 20f, 0f, 7f, NativeFlexCrossMargins(autoTop = true), alignment))
            assertEquals(NativeFlexCrossPlacement(22.5f, 20f),
                nativeFlexCrossPlacement(65f, 20f, 0f, 0f, NativeFlexCrossMargins(true, true), alignment))
            assertEquals(NativeFlexCrossPlacement(0f, 0f),
                nativeFlexCrossPlacement(0f, 0f, 0f, 0f, NativeFlexCrossMargins(), alignment))
        }
        assertEquals(NativeFlexCrossPlacement(5f, 53f),
            nativeFlexCrossPlacement(65f, 20f, 5f, 7f, NativeFlexCrossMargins(), ContainerAlignItems.Stretch))
        assertEquals(NativeFlexCrossPlacement(21.5f, 20f),
            nativeFlexCrossPlacement(65f, 20f, 5f, 7f, NativeFlexCrossMargins(), ContainerAlignItems.Center))
    }
}
