package app.smallthingz.dict

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Test

class ContainerOwnerFontStateTest {
    private val density = Density(2f, 1.5f)
    private val body = TextStyle(fontSize = 20.sp, fontFamily = FontFamily.Serif,
        fontWeight = FontWeight.Normal, fontStyle = FontStyle.Normal, fontFeatureSettings = "'kern' 0")
    private fun font(size: Float = 2f, basis: FontScaleBasis = FontScaleBasis.NormalBody) =
        InlineFontSnapshot(fontScale = size, fontScaleBasis = basis, fontNormalized = true,
            bold = true, italic = true, superscript = true, language = "th",
            fontFamily = ContainerFontFamily.SansSerif, fontFeatures = FontFeaturePolicy.SevenOn)

    // This state-only control supplies an already resolved metric font. The device control
    // independently exercises the actual composable resolver and native font metrics.
    private fun resolved(context: ContainerTextContext, pixels: Float): ContainerTextContext {
        val state = checkNotNull(context.containerText)
        val owner = NativeDeclaringFont(state.snapshot, TextStyle(fontSize = with(density) { pixels.toSp() },
            fontFamily = state.snapshot.fontFamily?.let(::nativeTerminalFontFamily) ?: body.fontFamily,
            fontWeight = if (state.snapshot.bold) FontWeight.Bold else FontWeight.Normal,
            fontStyle = if (state.snapshot.italic) FontStyle.Italic else FontStyle.Normal,
            fontFeatureSettings = state.snapshot.fontFeatures?.nativeSettings ?: body.fontFeatureSettings,
            baselineShift = BaselineShift.None),
            NativeDeclaringFontKind.Container, pixels)
        return context.copy(containerText = state.copy(resolved = owner))
    }

    @Test fun fullOwnerReplacesCellMetricsButPreservesTheConvertedLineHeightAndChildDefaults() {
        val cellFont = font(.5f).copy(superscript = false, fontNormalized = false)
        val cell = Cell(listOf(Span("text", "cell")), false, 1, 1, style = CellStyle(lineHeight =
            CellLineHeight(CellLineHeightValue.Length(CellFixedLineHeight(7f, FontScaleBasis.CssPx)),
                CellTextStrut(.5f, FontScaleBasis.NormalBody, cellFont))))
        val parent = checkNotNull(nativeCellTextContext(cell, null, body, 20.sp, density, 2f, null))
        val invalid = ContainerStyle(ownerFontScale = 3f).textContext(parent)
        assertTrue(invalid.cellText!!.ownerFontInvalidated)
        val source = font(10f, FontScaleBasis.CssPx)
        val raw = ContainerStyle(ownerFont = source).textContext(invalid)
        assertNull(raw.cellText)
        assertSame(source, raw.containerText!!.snapshot)
        assertSame(parent.cellText!!.lineHeight, raw.containerText.lineHeight)
        assertEquals(NativeLineHeightPolicy.Pixels(with(density) { 14.sp.toPx() }), raw.containerText.lineHeight)
        assertThrows(UnsupportedFloatLayout::class.java) { nativeContainerTextFormat(raw, 20.sp, body, density) }
        val context = resolved(raw, 60f)
        val format = nativeContainerTextFormat(context, 20.sp, body, density)
        assertSame(context.containerText!!.resolved, format.ownerFont)
        assertEquals(with(density) { 60f.toSp() }, format.style.fontSize)
        assertEquals(FontFamily.SansSerif, format.style.fontFamily)
        assertEquals(FontWeight.Normal, format.style.fontWeight)
        assertEquals(FontStyle.Normal, format.style.fontStyle)
        assertEquals("'kern' 0", format.style.fontFeatureSettings)
        assertEquals(FontWeight.Bold, format.ownerFont!!.style!!.fontWeight)
        assertEquals(FontFeaturePolicy.SevenOn.nativeSettings, format.ownerFont.style!!.fontFeatureSettings)
        assertEquals(NativeLineHeightPolicy.Pixels(with(density) { 14.sp.toPx() }), format.lineHeight)
        assertSame(cellFont, parent.cellText.ownerFont!!.snapshot)
        assertTrue(invalid.cellText.ownerFontInvalidated)

        val explicit = ContainerStyle(lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 1.2f)))
            .textContext(context)
        assertSame(context.containerText.resolved, explicit.containerText!!.resolved)
        assertNull(explicit.containerText.lineHeight)
        assertEquals(72f, (nativeContainerTextFormat(explicit, 20.sp, body, density).lineHeight as NativeLineHeightPolicy.Pixels).value, .001f)
    }

    @Test fun nestedAliasesUpdateOnlyTheRuntimeFontAndExactNoOpsKeepItsResolution() {
        val source = font(12f, FontScaleBasis.CssPx)
        val parent = resolved(ContainerStyle(ownerFont = source).textContext(ContainerTextContext()), 72f)
        val owner = parent.containerText!!.resolved
        assertSame(owner, ContainerStyle().textContext(parent).containerText!!.resolved)
        assertSame(owner, ContainerStyle(fontFamily = ContainerFontFamily.SansSerif).textContext(parent).containerText!!.resolved)
        val alias = ContainerStyle(ownerFontScale = .75f, fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)).textContext(parent)
        val changed = alias.containerText!!
        assertEquals(source.copy(fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)), changed.snapshot)
        assertNull(changed.resolved)
        assertEquals(ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif), alias.fontFamily)
        assertEquals(12f, source.fontScale!!, 0f)
        assertEquals(FontScaleBasis.CssPx, source.fontScaleBasis)
        assertSame(source, parent.containerText.snapshot)
        assertSame(owner, parent.containerText.resolved)
        val normalized = resolved(alias, 45f)
        assertSame(normalized.containerText!!.resolved,
            ContainerStyle(ownerFontScale = .75f).textContext(normalized).containerText!!.resolved)
        val full = font(0f).copy(bold = false, italic = false, superscript = false, fontFamily = null,
            fontFeatures = null, language = "")
        val replaced = ContainerStyle(ownerFont = full).textContext(normalized)
        assertSame(full, replaced.containerText!!.snapshot)
        assertNull(replaced.containerText.resolved)
        assertEquals(ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif), replaced.fontFamily)
        assertEquals(0.sp, nativeContainerTextFormat(resolved(replaced, 0f), 20.sp, body, density).style.fontSize)
    }

    @Test fun cellsDistinguishInheritanceLineHeightOnlyFullReplacementAndUnresolvedScalarOwnership() {
        val context = resolved(ContainerStyle(ownerFont = font()).textContext(ContainerTextContext()), 120f)
        val plain = Cell(listOf(Span("text", "child")), false, 1, 1)
        assertSame(context, nativeCellTextContext(plain, context, body, 20.sp, density, 1f, null))
        val heightOnly = plain.copy(style = CellStyle(lineHeight = CellLineHeight(CellLineHeightValue.Multiplier(1.25f))))
        val inherited = checkNotNull(nativeCellTextContext(heightOnly, context, body, 20.sp, density, 1f, null))
        assertNull(inherited.cellText)
        assertSame(context.containerText!!.resolved, inherited.containerText!!.resolved)
        assertSame(context.containerText.snapshot, inherited.containerText.snapshot)
        assertEquals(NativeLineHeightPolicy.Multiplier(1.25f), nativeContainerTextFormat(inherited, 20.sp, body, density).lineHeight)
        val cellFont = font(.5f).copy(bold = false, italic = false, superscript = false, fontNormalized = false)
        val complete = plain.copy(style = CellStyle(lineHeight = CellLineHeight(CellLineHeightValue.Normal,
            CellTextStrut(.5f, FontScaleBasis.NormalBody, cellFont))))
        val replaced = checkNotNull(nativeCellTextContext(complete, context, body, 20.sp, density, 1f, null))
        assertNull(replaced.containerText)
        assertSame(cellFont, replaced.cellText!!.ownerFont!!.snapshot)
        assertEquals(with(density) { 20.sp.toPx() } * .5f, replaced.cellText.fontPixels!!, 0f)
        val scalar = plain.copy(style = CellStyle(lineHeight = CellLineHeight(CellLineHeightValue.Normal,
            CellTextStrut(.5f, FontScaleBasis.NormalBody))))
        val refusal = assertThrows(UnsupportedFloatLayout::class.java) {
            nativeCellTextContext(scalar, context, body, 20.sp, density, 1f, null)
        }
        assertEquals("A scalar Cell strut cannot replace an inherited Container declaring font.", refusal.message)
        val legacy = checkNotNull(nativeCellTextContext(scalar, null, body, 20.sp, density, 1f, null))
        assertNull(legacy.containerText)
        assertNull(legacy.cellText!!.ownerFont)
        assertSame(context, nativeCellTextContext(plain, context, body, 20.sp, density, 1f, null))
    }
    @Test fun bodyExclusionRestoresNullableOriginalAndRetainsOnlyNearerLineHeight() {
        val root = body.copy(lineHeight = 24.sp)
        val baseline = nativeRootTextContext(root, 20.sp, density)
        val source = font(1.8f)
        fun seeded(original: ContainerTextContext?, height: ContainerLineHeight?): ContainerTextContext {
            val before = original ?: baseline
            return resolved(ContainerStyle(ownerFont = source, lineHeight = height).textContext(before)
                .copy(bodyOrigin = NativeBodyTextOrigin(original, before)), 108f)
        }
        val selected = seeded(null, ContainerLineHeight.Multiplier(1.5f))
        assertNull(nativeWithoutBodyTextContext(selected, 20.sp, density))
        val original = ContainerTextContext(.8f, ContainerLineHeight.Multiplier(1.1f),
            fontFamily = ContainerFontFamily.SansSerif)
        assertSame(original, nativeWithoutBodyTextContext(seeded(original, null), 20.sp, density))
        assertEquals(NativeLineHeightPolicy.Multiplier(1.1f),
            nativeContainerTextFormat(seeded(original, null), 20.sp, body, density).lineHeight)
        assertEquals(NativeLineHeightPolicy.Pixels(72f),
            nativeContainerTextFormat(seeded(null, null), 20.sp, body, density).lineHeight)
        assertEquals(NativeLineHeightPolicy.Normal,
            nativeContainerTextFormat(seeded(original, ContainerLineHeight.Normal), 20.sp, body, density).lineHeight)

        val cell = Cell(listOf(Span("text", "child")), false, 1, 1,
            style = CellStyle(lineHeight = CellLineHeight(CellLineHeightValue.Length(
                CellFixedLineHeight(7f, FontScaleBasis.CssPx)))))
        val near = checkNotNull(nativeCellTextContext(cell, selected, body, 20.sp, density, 2f, null))
        assertSame(selected.containerText!!.resolved, near.containerText!!.resolved)
        assertTrue(near.bodyOrigin!!.fontInherited)
        assertFalse(near.bodyOrigin.lineHeightInherited)
        val excluded = checkNotNull(nativeWithoutBodyTextContext(near, 20.sp, density))
        assertNull(excluded.bodyOrigin); assertNull(excluded.containerText); assertNull(excluded.cellText)
        assertEquals(1f, excluded.ownerFontScale, 0f)
        val expected = NativeLineHeightPolicy.Pixels(with(density) { 14.sp.toPx() })
        assertEquals(expected, excluded.resolvedLineHeight)
        assertEquals(expected, nativeContainerTextFormat(excluded, 20.sp, body, density).lineHeight)
        assertSame(source, selected.containerText.snapshot)
        assertEquals(ContainerLineHeight.Multiplier(1.5f), selected.lineHeight)
    }

    @Test fun excludedCaptionKeepsExplicitAliasesWithoutBorrowingBodyMetricTraits() {
        val original = ContainerTextContext(.8f, ContainerLineHeight.Multiplier(1.1f))
        val source = font(12f, FontScaleBasis.CssPx)
        val selected = resolved(ContainerStyle(ownerFont = source,
            lineHeight = ContainerLineHeight.Multiplier(1.5f)).textContext(original)
            .copy(bodyOrigin = NativeBodyTextOrigin(original, original)), 72f)
        val family = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)
        val aliased = ContainerStyle(ownerFontScale = .75f, fontFamily = family).textContext(selected)
        assertNull(aliased.containerText!!.resolved)
        assertTrue(aliased.bodyOrigin!!.fontInherited)
        assertFalse(aliased.bodyOrigin.sizeInherited); assertFalse(aliased.bodyOrigin.familyInherited)
        val excluded = checkNotNull(nativeWithoutBodyTextContext(aliased, 20.sp, density))
        assertNull(excluded.containerText); assertNull(excluded.cellText); assertNull(excluded.bodyOrigin)
        assertEquals(.75f, excluded.ownerFontScale, 0f); assertEquals(family, excluded.fontFamily)
        val format = nativeContainerTextFormat(excluded, 20.sp, body, density)
        assertNull(format.ownerFont)
        assertEquals(15.sp, format.style.fontSize)
        assertEquals(FontWeight.Normal, format.style.fontWeight)
        assertEquals(FontStyle.Normal, format.style.fontStyle)
        assertEquals(body.fontFeatureSettings, format.style.fontFeatureSettings)
        assertEquals(NativeLineHeightPolicy.Multiplier(1.1f), format.lineHeight)

        val heightOnly = Cell(emptyList(), false, 1, 1, style = CellStyle(lineHeight =
            CellLineHeight(CellLineHeightValue.Multiplier(1.25f))))
        val resolvedAlias = resolved(aliased, 45f)
        val withHeight = checkNotNull(nativeCellTextContext(heightOnly, resolvedAlias, body, 20.sp, density, 1f, null))
        val caption = checkNotNull(nativeWithoutBodyTextContext(withHeight, 20.sp, density))
        assertNull(caption.containerText); assertNull(caption.cellText)
        assertEquals(family, caption.fontFamily); assertEquals(.75f, caption.ownerFontScale, 0f)
        assertEquals(NativeLineHeightPolicy.Multiplier(1.25f),
            nativeContainerTextFormat(caption, 20.sp, body, density).lineHeight)
        assertSame(source, selected.containerText!!.snapshot)
        assertEquals(12f, source.fontScale!!, 0f); assertEquals(FontScaleBasis.CssPx, source.fontScaleBasis)
        assertTrue(source.bold && source.italic && source.superscript)
        assertEquals(original, ContainerTextContext(.8f, ContainerLineHeight.Multiplier(1.1f)))
    }

    @Test fun nearerFullOwnersReplaceBodyFontWithoutDiscardingIndependentHeightPolicy() {
        val baseline = nativeRootTextContext(body.copy(lineHeight = 24.sp), 20.sp, density)
        val source = font(1.8f)
        val selected = resolved(ContainerStyle(ownerFont = source,
            lineHeight = ContainerLineHeight.Multiplier(1.5f)).textContext(baseline)
            .copy(bodyOrigin = NativeBodyTextOrigin(null, baseline)), 108f)
        val own = font(.5f).copy(bold = false, italic = false, superscript = false)
        val replaced = resolved(ContainerStyle(ownerFont = own).textContext(selected), 30f)
        assertFalse(replaced.bodyOrigin!!.fontInherited); assertTrue(replaced.bodyOrigin.lineHeightInherited)
        val excluded = checkNotNull(nativeWithoutBodyTextContext(replaced, 20.sp, density))
        assertSame(own, excluded.containerText!!.snapshot)
        assertSame(replaced.containerText!!.resolved, excluded.containerText.resolved)
        assertEquals(NativeLineHeightPolicy.Pixels(72f),
            nativeContainerTextFormat(excluded, 20.sp, body, density).lineHeight)
        assertEquals(10.sp, nativeContainerTextFormat(excluded, 20.sp, body, density).style.fontSize)
        val ownHeight = ContainerStyle(lineHeight = ContainerLineHeight.Normal).textContext(replaced)
        val independent = checkNotNull(nativeWithoutBodyTextContext(ownHeight, 20.sp, density))
        assertSame(ownHeight.containerText, independent.containerText)
        assertEquals(NativeLineHeightPolicy.Normal,
            nativeContainerTextFormat(independent, 20.sp, body, density).lineHeight)

        val cellFont = own.copy(fontNormalized = false)
        val fullCell = Cell(emptyList(), false, 1, 1, style = CellStyle(lineHeight =
            CellLineHeight(CellLineHeightValue.Normal,
                CellTextStrut(.5f, FontScaleBasis.NormalBody, cellFont))))
        val cell = checkNotNull(nativeCellTextContext(fullCell, selected, body, 20.sp, density, 1f, null))
        val cellExcluded = checkNotNull(nativeWithoutBodyTextContext(cell, 20.sp, density))
        assertNull(cellExcluded.containerText); assertNull(cellExcluded.bodyOrigin)
        assertSame(cell.cellText, cellExcluded.cellText)
        assertSame(cellFont, cellExcluded.cellText!!.ownerFont!!.snapshot)
        assertEquals(NativeLineHeightPolicy.Normal,
            nativeContainerTextFormat(cellExcluded, 20.sp, body, density).lineHeight)
        assertSame(source, selected.containerText!!.snapshot)
    }

    @Test fun bodyDirectionSurvivesNearerFontAndHeightButNotAnExcludedSink() {
        val baseline = nativeRootTextContext(body.copy(lineHeight = 24.sp), 20.sp, density)
        val source = font(1.8f)
        val selected = resolved(ContainerStyle(ownerFont = source,
            lineHeight = ContainerLineHeight.Multiplier(1.5f)).textContext(baseline)
            .copy(bodyOrigin = NativeBodyTextOrigin(null, baseline), bodyDirection = BidiResolvedDirection.Rtl), 108f)
        assertNull(nativeWithoutBodyTextContext(selected, 20.sp, density))
        val own = font(.5f).copy(bold = false, italic = false, superscript = false)
        val near = resolved(ContainerStyle(ownerFont = own, lineHeight = ContainerLineHeight.Normal)
            .textContext(selected), 30f)
        assertFalse(near.bodyOrigin!!.fontInherited)
        assertFalse(near.bodyOrigin.lineHeightInherited)
        assertEquals(BidiResolvedDirection.Rtl, near.bodyDirection)
        val excluded = checkNotNull(nativeWithoutBodyTextContext(near, 20.sp, density))
        assertNull(excluded.bodyDirection)
        assertSame(near.containerText, excluded.containerText)
        assertSame(own, excluded.containerText!!.snapshot)
        assertEquals(NativeLineHeightPolicy.Normal, nativeContainerTextFormat(excluded, 20.sp, body, density).lineHeight)

        val alias = ContainerStyle(ownerFontScale = .75f,
            fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)).textContext(selected)
        assertEquals(BidiResolvedDirection.Rtl, alias.bodyDirection)
        val aliasExcluded = checkNotNull(nativeWithoutBodyTextContext(alias, 20.sp, density))
        assertNull(aliasExcluded.bodyDirection); assertNull(aliasExcluded.containerText)
        assertEquals(.75f, aliasExcluded.ownerFontScale, 0f)
        assertEquals(alias.fontFamily, aliasExcluded.fontFamily)
        val cellFont = own.copy(fontNormalized = false)
        val cell = Cell(emptyList(), false, 1, 1, style = CellStyle(lineHeight = CellLineHeight(
            CellLineHeightValue.Multiplier(1.25f), CellTextStrut(.5f, FontScaleBasis.NormalBody, cellFont))))
        val cellContext = checkNotNull(nativeCellTextContext(cell, selected, body, 20.sp, density, 1f, null))
        assertEquals(BidiResolvedDirection.Rtl, cellContext.bodyDirection)
        val caption = checkNotNull(nativeWithoutBodyTextContext(cellContext, 20.sp, density))
        assertNull(caption.bodyDirection); assertSame(cellContext.cellText, caption.cellText)
        assertSame(cellFont, caption.cellText!!.ownerFont!!.snapshot)
        assertEquals(NativeLineHeightPolicy.Multiplier(1.25f), caption.resolvedLineHeight)
        assertSame(source, selected.containerText!!.snapshot)
        assertEquals(BidiResolvedDirection.Rtl, selected.bodyDirection)

        assertSame(baseline, nativeWithoutBodyTextContext(baseline, 20.sp, density))
        assertNull(compiledBodyParagraphDirection(null, null))
        assertEquals(androidx.compose.ui.text.style.TextDirection.Rtl,
            compiledBodyParagraphDirection(null, BidiResolvedDirection.Rtl))
        assertEquals(androidx.compose.ui.text.style.TextDirection.Ltr,
            compiledBodyParagraphDirection(TableContainingDirection.Ltr, BidiResolvedDirection.Rtl))
        assertEquals(androidx.compose.ui.text.style.TextDirection.Rtl,
            compiledBodyParagraphDirection(TableContainingDirection.Rtl, BidiResolvedDirection.Ltr))
        val directionOnly = baseline.copy(bodyDirection = BidiResolvedDirection.Rtl)
        assertEquals(baseline, nativeWithoutBodyTextContext(directionOnly, 20.sp, density))
    }

    @Test fun qualifiedBacklinkStartsWithIndependentNormalInsteadOfTheExcludedBodyPolicy() {
        val numeric = ContainerTextContext(lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 53f)),
            fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif))
        val bodyOwner = resolved(ContainerStyle(ownerFont = font(2f),
            lineHeight = ContainerLineHeight.Multiplier(3f)).textContext(numeric), 120f)
            .copy(bodyOrigin = NativeBodyTextOrigin(numeric, numeric))
        val excluded = checkNotNull(nativeWithoutBodyTextContext(bodyOwner, 20.sp, density))
        assertEquals(NativeLineHeightPolicy.Pixels(106f), nativeContainerTextFormat(excluded, 20.sp, body, density).lineHeight)
        val backlink = ReferenceBacklink.withPolicies(7, Span("link", "return", targetFragment = "stored-return"))
        val source = backlink.span
        val basis = nativeReferenceBacklinkStyle(20.sp)
        assertEquals(20.sp, basis.fontSize)
        assertEquals(FontFamily.Default, basis.fontFamily)
        assertEquals(FontWeight.Normal, basis.fontWeight)
        assertEquals(FontStyle.Normal, basis.fontStyle)
        assertNull(basis.fontFeatureSettings)
        assertNull(basis.localeList)
        assertEquals(BaselineShift.None, basis.baselineShift)
        assertEquals(0.sp, basis.letterSpacing)
        assertNull(basis.textGeometricTransform)
        assertEquals(androidx.compose.ui.text.style.TextDecoration.None, basis.textDecoration)
        assertEquals(androidx.compose.ui.unit.TextUnit.Unspecified, basis.lineHeight)
        assertEquals(NativeLineHeightPolicy.Normal, nativeReferenceBacklinkLineHeight(backlink, null))
        assertEquals(NativeLineHeightPolicy.Normal, nativeReferenceBacklinkLineHeight(backlink, 106f))
        assertSame(source, backlink.span)
        assertSame(numeric, nativeWithoutBodyTextContext(bodyOwner, 20.sp, density))
    }

    @Test fun qualifiedBacklinkNumericHeightOverridesItsRootIncludingZeroAndMissingResolutionRefuses() {
        val source = Span("link", "a", targetFragment = "return-a")
        val zero = ReferenceBacklink.withPolicies(1, source, inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx))))
        assertEquals(NativeLineHeightPolicy.Pixels(0f), nativeReferenceBacklinkLineHeight(zero, 0f))
        val font = InlineFontSnapshot(fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody,
            superscript = true)
        val script = Span("link", "b", targetFragment = "return-b", fontScale = .5f,
            fontScaleBasis = FontScaleBasis.NormalBody, superscript = true)
        val relative = ReferenceBacklink.withPolicies(2, script, inlineStyle = InlineTextStyle(
            lineHeight = InlineLineHeight.FontRelative(1.25f, font)))
        assertEquals(NativeLineHeightPolicy.Pixels(30f), nativeReferenceBacklinkLineHeight(relative, 30f))
        assertThrows(UnsupportedFloatLayout::class.java) { nativeReferenceBacklinkLineHeight(relative, null) }
        assertThrows(UnsupportedFloatLayout::class.java) { nativeReferenceBacklinkLineHeight(relative, Float.NaN) }
        assertNull(source.inlineStyle)
        assertNull(script.inlineStyle)
        assertEquals("b", relative.span.text)
        assertEquals("return-b", relative.span.targetFragment)
    }

    @Test fun qualifiedBacklinkMetricProbePreservesOriginalBasisAndAppliesLegacyScriptOnlyOnce() {
        val backlink = ReferenceBacklink.withPolicies(3,
            Span("link", "2", targetFragment = "return-script", fontScale = .5f, superscript = true))
        val source = backlink.span
        val snapshot = nativeReferenceBacklinkFont(backlink)
        val probe = inlineFontSnapshotSpan(snapshot)
        assertEquals(FontScaleBasis.Context, snapshot.fontScaleBasis)
        assertEquals(.5f, snapshot.fontScale!!, 0f)
        assertTrue(snapshot.superscript)
        assertFalse(snapshot.fontNormalized)
        assertFalse(snapshot.bold); assertFalse(snapshot.italic); assertFalse(snapshot.code)
        assertNull(snapshot.fontFamily); assertNull(snapshot.fontFeatures)
        assertEquals(24f, spanFontPixels(probe, 60f, 90f), .0001f)
        assertEquals(spanFontPixels(source, 60f, 90f), spanFontPixels(probe, 60f, 90f), 0f)
        val absolute = Span("link", "n", targetFragment = "return-normalized", fontScale = .5f,
            fontScaleBasis = FontScaleBasis.NormalBody, superscript = true)
        val normalized = ReferenceBacklink.withPolicies(4, absolute, inlineStyle = InlineTextStyle(fontNormalized = true))
        assertEquals(45f, spanFontPixels(inlineFontSnapshotSpan(nativeReferenceBacklinkFont(normalized)), 60f, 90f), 0f)
        val copiedProbe = inlineMetricOwnerSpan(normalized.span)
        assertEquals("text", copiedProbe.kind)
        assertEquals(" ", copiedProbe.text)
        assertNull(copiedProbe.targetFragment)
        assertNull(copiedProbe.citationMarker)
        assertTrue(copiedProbe.inlineStyle!!.fontNormalized)
        assertSame(source, backlink.span)
        assertNull(source.inlineStyle)
    }


    @Test fun staticInlineParentRetainsItsOwnResolvedFontAndPolicyBeforeChildOverrides() {
        val parentSnapshot = font(1.5f)
        val parent = resolved(ContainerStyle(ownerFont = parentSnapshot,
            lineHeight = ContainerLineHeight.Multiplier(1.5f)).textContext(ContainerTextContext()), 72f)
        val parentFormat = nativeContainerTextFormat(parent, 20.sp, body, density)
        val childSnapshot = font(.5f).copy(bold = false, italic = false, superscript = false,
            fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif))
        val child = resolved(ContainerStyle(ownerFont = childSnapshot,
            lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 9f)))
            .textContext(parent), 24f)
        val childFormat = nativeContainerTextFormat(child, 20.sp, body, density)
        val inherited = nativeStaticInlineParent(parentFormat, ContainerAbsoluteStaticPosition(),
            TableContainingDirection.Rtl, BidiResolvedDirection.Ltr,
            androidx.compose.ui.text.style.TextAlign.Start)
        assertSame(parentFormat, inherited.format)
        assertSame(parent.containerText!!.resolved, inherited.format.ownerFont)
        assertSame(parentSnapshot, inherited.format.ownerFont!!.snapshot)
        assertEquals(NativeLineHeightPolicy.Multiplier(1.5f), inherited.format.lineHeight)
        assertEquals(72f, inherited.format.ownerFont!!.fontPixels!!, 0f)
        assertEquals(ContainerFontFamily.SansSerif, inherited.format.sourceFamily)
        assertEquals(BidiResolvedDirection.Rtl, inherited.direction)
        assertEquals(android.text.Layout.Alignment.ALIGN_NORMAL, inherited.alignment)
        assertEquals(NativeLineHeightPolicy.Pixels(18f), childFormat.lineHeight)
        assertEquals(24f, childFormat.ownerFont!!.fontPixels!!, 0f)
        assertFalse(childFormat.ownerFont!!.snapshot.bold)
        assertFalse(childFormat.ownerFont!!.snapshot.italic)
        assertSame(childSnapshot, childFormat.ownerFont!!.snapshot)
        assertEquals(android.text.Layout.Alignment.ALIGN_OPPOSITE,
            nativeStaticInlineParent(parentFormat, ContainerAbsoluteStaticPosition(), TableContainingDirection.Rtl,
                null, androidx.compose.ui.text.style.TextAlign.Left).alignment)
    }

    @Test fun staticInlineInheritRequiresParentDirectionAndPreservesPositionedBodyExclusion() {
        val original = ContainerTextContext()
        val bodyOwner = resolved(ContainerStyle(ownerFont = font(),
            lineHeight = ContainerLineHeight.Multiplier(2f)).textContext(original), 60f).copy(
            bodyOrigin = NativeBodyTextOrigin(original, original), bodyDirection = BidiResolvedDirection.Rtl)
        val excluded = checkNotNull(nativeWithoutBodyTextContext(bodyOwner, 20.sp, density))
        assertSame(original, excluded)
        assertNull(excluded.bodyDirection)
        val format = nativeContainerTextFormat(excluded, 20.sp, body.copy(
            textDirection = androidx.compose.ui.text.style.TextDirection.Content), density)
        val failure = assertThrows(UnsupportedFloatLayout::class.java) {
            nativeStaticInlineParent(format, ContainerAbsoluteStaticPosition(), null, excluded.bodyDirection,
                androidx.compose.ui.text.style.TextAlign.Start)
        }
        assertEquals("Static inline parent paragraph direction is unresolved", failure.message)
        val explicit = nativeStaticInlineParent(format,
            ContainerAbsoluteStaticPosition(ContainerStaticDirection.Rtl), TableContainingDirection.Ltr,
            BidiResolvedDirection.Ltr, androidx.compose.ui.text.style.TextAlign.End)
        assertEquals(BidiResolvedDirection.Rtl, explicit.direction)
        assertEquals(android.text.Layout.Alignment.ALIGN_OPPOSITE, explicit.alignment)
        val styled = nativeStaticInlineParent(format.copy(style = format.style.copy(
            textDirection = androidx.compose.ui.text.style.TextDirection.Ltr)), ContainerAbsoluteStaticPosition(),
            null, null, androidx.compose.ui.text.style.TextAlign.Right)
        assertEquals(BidiResolvedDirection.Ltr, styled.direction)
        assertEquals(android.text.Layout.Alignment.ALIGN_OPPOSITE, styled.alignment)
        val bodyDirection = nativeStaticInlineParent(format, ContainerAbsoluteStaticPosition(),
            null, BidiResolvedDirection.Rtl, androidx.compose.ui.text.style.TextAlign.Center)
        assertEquals(BidiResolvedDirection.Rtl, bodyDirection.direction)
        assertEquals(android.text.Layout.Alignment.ALIGN_CENTER, bodyDirection.alignment)
    }
}
