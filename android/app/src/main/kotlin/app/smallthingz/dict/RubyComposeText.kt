package app.smallthingz.dict

import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextDecoration

internal data class RubyGroupTextContext(
    val range: RubyTextRange,
    val style: TextStyle,
    val enclosingStyle: TextStyle,
    val sourceFamily: ContainerFontFamily?,
    val parentGroupPath: String?,
    val legacyFamily: LegacySpanFontFamily?,
    val fontBasisStyle: TextStyle,
    val cellForeground: NativeCellForegroundContext? = null,
)

internal data class RubyLeafTextContext(
    val range: RubyTextRange,
    val enclosingStyle: TextStyle,
    val sourceFamily: ContainerFontFamily?,
    val parentGroupPath: String?,
    val legacyFamily: LegacySpanFontFamily?,
    val fontBasisStyle: TextStyle,
    val cellForeground: NativeCellForegroundContext? = null,
)

internal data class RubyStyledTextContexts(
    val projection: RubyTextProjection,
    val groups: Map<String, RubyGroupTextContext>,
    val leaves: List<RubyLeafTextContext>,
)

/** Equal data from a new source still owns new original occurrence references. */
internal class RubySourceIdentity(private val source: List<Span>) {
    override fun equals(other: Any?): Boolean = other is RubySourceIdentity && source === other.source
    override fun hashCode(): Int = System.identityHashCode(source)
}

/** Group paint and vertical alignment are applied by the native group, once. */
private fun TextStyle.rubyChildStyle(): TextStyle = copy(baselineShift = BaselineShift.None,
    textDecoration = TextDecoration.None, background = Color.Unspecified)

/** Complete declaring traits resolve independently of descendants. This is a font probe,
 * not a source glyph. Native admission still checks the original locale/family request. */
@Composable
internal fun rubyFontSnapshotStyle(snapshot: InlineFontSnapshot, enclosingStyle: TextStyle,
    fontBasisStyle: TextStyle = enclosingStyle): TextStyle {
    val seed = enclosingStyle.copy(
        fontSize = fontBasisStyle.fontSize,
        fontWeight = if (snapshot.bold) FontWeight.Bold else FontWeight.Normal,
        fontStyle = if (snapshot.italic) FontStyle.Italic else FontStyle.Normal,
        fontFeatureSettings = snapshot.fontFeatures?.nativeSettings ?: enclosingStyle.fontFeatureSettings,
        baselineShift = BaselineShift.None,
    )
    var result = seed
    CompositionLocalProvider(LocalCellWeight provides null, LocalCellLetterSpacingPixels provides null) {
        result = rubySpanTextStyle(inlineFontSnapshotSpan(snapshot), null, seed)
    }
    return seed.copy(fontSize = result.fontSize, fontWeight = result.fontWeight,
        fontStyle = result.fontStyle, fontFamily = result.fontFamily,
        fontSynthesis = result.fontSynthesis, fontFeatureSettings = result.fontFeatureSettings,
        localeList = result.localeList, baselineShift = result.baselineShift,
        letterSpacing = result.letterSpacing, textGeometricTransform = result.textGeometricTransform)
}

@Composable
private fun rubySpanTextStyle(span: Span, weight: FontWeight?, enclosingStyle: TextStyle,
    declaringAction: Boolean = false): TextStyle {
    val density = LocalDensity.current
    val probe = remember(span, declaringAction) { listOf(span.copy(
        kind = if (declaringAction) span.kind else "text", text = " ",
        target = if (declaringAction) span.target else "", trail = "",
        targetFragment = span.targetFragment.takeIf { declaringAction }, image = null, ruby = null,
        inlinePaddingGroup = null, inlineActionGroup = null, inlineBoxGroup = null, clippedAbsolute = null, citationMarker = null,
        linkPaint = span.linkPaint.takeIf { declaringAction })) }
    val annotation = styledTextAnnotationWithoutDirectionControls(probe, weight, enclosingStyle) { }
    val plain = annotation.spanStyles.fold(enclosingStyle.toSpanStyle()) { value, range -> value.merge(range.item) }
    val resolved = if (!declaringAction) plain else annotation.getLinkAnnotations(0, annotation.length)
        .fold(plain) { value, range -> value.merge(range.item.styles?.style ?: SpanStyle()) }
    val size = if (resolved.fontSize.isEm) with(density) {
        (enclosingStyle.fontSize.toPx() * resolved.fontSize.value).toSp()
    } else resolved.fontSize
    return enclosingStyle.copy(fontSize = size, fontWeight = resolved.fontWeight,
        fontStyle = resolved.fontStyle, fontFamily = resolved.fontFamily,
        fontSynthesis = resolved.fontSynthesis, fontFeatureSettings = resolved.fontFeatureSettings,
        localeList = resolved.localeList, baselineShift = resolved.baselineShift,
        letterSpacing = resolved.letterSpacing, textGeometricTransform = resolved.textGeometricTransform,
        color = resolved.color, background = resolved.background, textDecoration = resolved.textDecoration)
}

@Composable
internal fun rubyStyledTextContexts(spans: List<Span>, weight: FontWeight?, style: TextStyle): RubyStyledTextContexts? {
    if (!spans.hasNativeInlineGroups()) return null
    val sourceIdentity = RubySourceIdentity(spans)
    val projection = remember(sourceIdentity) { rubyGraphicalProjection(spans) }
    val inheritedContext = LocalNativeContainerTextContext.current
    val inheritedForeground = LocalFigureCaptionForeground.current
    val rootCellForeground = LocalNativeCellForeground.current?.withAuthored(inheritedForeground)
    val rootFamily = inheritedContext?.fontFamily
    val rootLegacy = if (LocalNativePreformattedText.current) LegacySpanFontFamily.Code else null
    val effectiveWeight = weight ?: LocalCellWeight.current
    val rootStyle = LocalTextStyle.current.merge(style).let {
        if (effectiveWeight == null) it else it.copy(fontWeight = effectiveWeight)
    }
    val groups = linkedMapOf<String, RubyGroupTextContext>()
    val leaves = mutableListOf<RubyLeafTextContext>()
    for (range in projection.ranges) {
        val parent = groups.values.lastOrNull { range.path.startsWith(it.range.path + "/") }
        val enclosing = parent?.style?.rubyChildStyle() ?: rootStyle
        val cellForeground = parent?.cellForeground ?: rootCellForeground
        val familyOwner = groups.values.lastOrNull { group ->
            if (!range.path.startsWith(group.range.path + "/")) false else {
                val declared = group.range.span ?: inlineFontSnapshotSpan(group.range.overlayContent?.ownerFont
                    ?: checkNotNull(group.range.base?.owner ?: group.range.annotation?.owner).font)
                declared.fontFamily != null || declared.legacyFontFamily() == LegacySpanFontFamily.Egyptian
            }
        }
        val inheritedFamily = if (familyOwner == null) rootFamily else familyOwner.sourceFamily
        // Boolean code/super/sub traits are already complete in Ruby children.
        // They do not inherit a group's true flag, or its already-scaled font size.
        // Egyptian is a real inherited family mapping, not a complete Boolean code trait.
        val inheritedLegacy = if (familyOwner == null) rootLegacy else familyOwner.legacyFamily
        val inheritedFace = familyOwner?.style?.fontFamily ?: rootStyle.fontFamily
        val owner = range.base?.owner ?: range.annotation?.owner
        if (range.role == RubyTextRole.Owner || range.role == RubyTextRole.PaddingGroup ||
            range.role == RubyTextRole.ActionGroup || range.role == RubyTextRole.BoxGroup ||
            range.role == RubyTextRole.ClippedAbsolute || range.overlayContent != null || owner != null) {
            val declaredFont = range.overlayContent?.ownerFont ?: owner?.font
            val source = range.span ?: inlineFontSnapshotSpan(checkNotNull(declaredFont))
            val ownLegacy = source.legacyFontFamily()
            val family = source.fontFamily ?: inheritedFamily.takeIf { ownLegacy == null }
            val legacy = if (source.fontFamily != null) null else ownLegacy ?: inheritedLegacy
            val inheritsRootTraits = parent == null && owner == null && range.overlayContent == null && range.role != RubyTextRole.PaddingGroup &&
                range.role != RubyTextRole.ActionGroup && range.role != RubyTextRole.BoxGroup &&
                range.role != RubyTextRole.ClippedAbsolute
            val fontSeed = if (inheritsRootTraits) enclosing else enclosing.copy(
                fontSize = rootStyle.fontSize, fontWeight = FontWeight.Normal, fontStyle = FontStyle.Normal,
                baselineShift = BaselineShift.None,
                fontFamily = family?.let(::nativeTerminalFontFamily) ?: inheritedFace)
            var resolved = fontSeed
            CompositionLocalProvider(LocalTextStyle provides fontSeed,
                LocalCellWeight provides (effectiveWeight.takeIf { inheritsRootTraits }),
                LocalNativeContainerTextContext provides (if (inheritsRootTraits)
                    inheritedContext else ContainerTextContext(fontFamily = family.takeIf { legacy == null })),
                LocalNativeCellForeground provides cellForeground,
                LocalFigureCaptionForeground provides (if (cellForeground != null) cellForeground.authored else
                    enclosing.color.takeIf { it != Color.Unspecified }?.toArgb() ?: inheritedForeground)) {
                resolved = if (declaredFont == null) rubySpanTextStyle(source, effectiveWeight.takeIf { inheritsRootTraits }, fontSeed,
                    declaringAction = range.role == RubyTextRole.PaddingGroup || range.role == RubyTextRole.ActionGroup ||
                        range.role == RubyTextRole.BoxGroup || range.role == RubyTextRole.ClippedAbsolute)
                    else rubyFontSnapshotStyle(declaredFont, fontSeed, rootStyle)
            }
            if (owner != null) {
                // The snapshot resolves font traits only. Its seed color is not the
                // computed ink of this separately painted base/annotation owner.
                val ownerForeground = if (cellForeground == null) owner.foreground?.let(::canonicalColorArgb)?.toInt()
                    else nativeCellPlainForeground(cellForeground, owner.foreground?.let(::canonicalColorArgb)?.toInt(),
                        cellForeground.authored, owner.background, owner.background ?: cellForeground.background, false)
                resolved = resolved.copy(color = ownerForeground?.let { Color(it) } ?: resolved.color,
                    background = owner.background?.let(::canonicalColorArgb)?.let { Color(it) } ?: Color.Unspecified)
            }
            val ownsPaint = source.foreground != null || source.background != null ||
                source.hasInternalAction() || externalLinkUrl(source) != null || source.linkPaint != null ||
                owner?.foreground != null || owner?.background != null
            val childForeground = cellForeground?.let {
                if (ownsPaint) it.inGroup(true, resolved.color.toArgb()) else it
            }
            groups[range.path] = RubyGroupTextContext(range, resolved, enclosing, family, parent?.range?.path, legacy, rootStyle,
                childForeground)
        } else if (range.span != null) {
            // Nullable family/features/language retain their existing inheritance rules;
            // only the complete Boolean traits and cumulative Context size reset here.
            val inherited = if (parent == null) enclosing else enclosing.copy(fontSize = rootStyle.fontSize,
                fontWeight = FontWeight.Normal, fontStyle = FontStyle.Normal, baselineShift = BaselineShift.None,
                fontFamily = inheritedFamily?.let(::nativeTerminalFontFamily) ?: inheritedFace)
            leaves += RubyLeafTextContext(range, inherited, inheritedFamily, parent?.range?.path, inheritedLegacy, rootStyle, cellForeground)
        }
    }
    return remember(sourceIdentity, projection, groups, leaves) {
        RubyStyledTextContexts(projection, groups.toMap(), leaves.toList())
    }
}

/** Logical annotations use source UTF-16 offsets; native isolation is shaping metadata.
 * Private hypothetical measurement can request ordinary style lowering for clipped children. */
@Composable
internal fun rubyStyledTextAnnotation(contexts: RubyStyledTextContexts, weight: FontWeight?,
    onLink: (EntryLink) -> Unit, measureClippedChildren: Boolean = false): AnnotatedString {
    val builder = AnnotatedString.Builder()
    val currentLink = rememberUpdatedState(onLink)
    val inheritedContext = LocalNativeContainerTextContext.current
    val cellWeight = LocalCellWeight.current
    val inheritedForeground = LocalFigureCaptionForeground.current
    val sourceBreaks = contexts.projection.ranges.filter { it.role == RubyTextRole.IntrinsicLineBreak }
    var sourceBreakIndex = 0
    fun appendSourceBreaks(end: Int) {
        while (builder.length < end) {
            val range = sourceBreaks.getOrNull(sourceBreakIndex++)
                ?: error("Unowned gap in the original inline source")
            check(range.span == null && range.intrinsicLine?.breakAfter == true &&
                range.start == builder.length && range.end == range.start + 1 && range.end <= end &&
                contexts.projection.text[range.start] == '\n')
            builder.append('\n')
        }
        check(builder.length == end)
    }
    for (leaf in contexts.leaves) {
        appendSourceBreaks(leaf.range.start)
        val span = checkNotNull(leaf.range.span)
        if (leaf.range.role == RubyTextRole.ClippedText && !measureClippedChildren) {
            // Retain genuine source/actions, without asking a clipped descendant for a font or glyph probe.
            check(builder.length == leaf.range.start)
            builder.append(span.text)
            builder.append(span.trail)
            check(builder.length == leaf.range.end)
            val styles = TextLinkStyles(style = SpanStyle())
            if (leaf.range.start < leaf.range.end) {
                if (span.hasInternalAction()) builder.addLink(LinkAnnotation.Clickable(span.target, styles) {
                    currentLink.value(span.entryLink())
                }, leaf.range.start, leaf.range.end)
                else externalLinkUrl(span)?.let { builder.addLink(LinkAnnotation.Url(it, styles),
                    leaf.range.start, leaf.range.end) }
            }
            continue
        }
        var annotation = AnnotatedString("")
        CompositionLocalProvider(LocalTextStyle provides leaf.enclosingStyle,
            LocalCellWeight provides cellWeight.takeIf { leaf.parentGroupPath == null },
            LocalNativeContainerTextContext provides (if (leaf.parentGroupPath == null) inheritedContext else
                ContainerTextContext(fontFamily = leaf.sourceFamily.takeIf { leaf.legacyFamily == null })),
            LocalNativeCellForeground provides leaf.cellForeground,
            LocalFigureCaptionForeground provides (if (leaf.cellForeground != null) leaf.cellForeground.authored else
                leaf.enclosingStyle.color.takeIf { it != Color.Unspecified }?.toArgb() ?: inheritedForeground)) {
            annotation = styledTextAnnotationWithoutDirectionControls(listOf(span),
                weight.takeIf { leaf.parentGroupPath == null }, leaf.enclosingStyle, onLink)
        }
        check(builder.length == leaf.range.start && annotation.length == leaf.range.end - leaf.range.start)
        builder.pushStyle(leaf.enclosingStyle.toSpanStyle())
        builder.append(annotation)
        builder.pop()
    }
    appendSourceBreaks(contexts.projection.text.length)
    check(sourceBreakIndex == sourceBreaks.size)
    // The declaring action owns one interval. Its normal paint already entered the
    // inherited context; these annotations must not overwrite explicit child paints.
    contexts.groups.values.filter { it.range.role == RubyTextRole.PaddingGroup ||
        it.range.role == RubyTextRole.ActionGroup || it.range.role == RubyTextRole.BoxGroup ||
        it.range.role == RubyTextRole.ClippedAbsolute }.forEach { group ->
        val range = group.range
        val span = checkNotNull(range.span)
        if (range.start < range.end) {
            val styles = TextLinkStyles(style = SpanStyle())
            if (span.hasInternalAction()) builder.addLink(LinkAnnotation.Clickable(span.target, styles) {
                currentLink.value(span.entryLink())
            }, range.start, range.end)
            else externalLinkUrl(span)?.let { builder.addLink(LinkAnnotation.Url(it, styles), range.start, range.end) }
        }
    }
    return builder.toAnnotatedString().also { check(it.text == contexts.projection.text) }
}
