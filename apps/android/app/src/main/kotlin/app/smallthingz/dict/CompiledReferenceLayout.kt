package app.smallthingz.dict

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection

private class ReferenceLayoutIdentity(private val batch: ReferenceBatchPlacement,
    private val references: List<Reference>) {
    override fun equals(other: Any?) = other is ReferenceLayoutIdentity &&
        batch === other.batch && references === other.references
    override fun hashCode() = System.identityHashCode(batch) * 31 + System.identityHashCode(references)
}

/** Same native Container tree and paragraph renderer used by a complete document body. */
@Composable
internal fun CompiledReferenceBatchView(batch: ReferenceBatchPlacement, references: List<Reference>,
    path: String, onLink: (EntryLink) -> Unit, targetReferenceIndex: Int? = null) {
    val projection = remember(ReferenceLayoutIdentity(batch, references), path, targetReferenceIndex) {
        referenceLayoutProjection(batch, references, path, targetReferenceIndex)
    }
    NativeFloatBlockContext(projection.blocks, onLink, path, Modifier,
        inCell = false, gridPath = path, gapDp = 0f, trailingGap = false,
        referenceLayoutParagraphs = projection.paragraphs)
}

/** LI strut/space/marker and independent existing64 backlink remain separate metric owners. */
@Composable
internal fun prepareCompiledReferenceParagraph(leaf: NativeContainerLeaf,
    paragraph: ReferenceLayoutParagraph, media: List<Media>, settings: AppSettings, edition: String,
    onLink: (EntryLink) -> Unit,
    spans: List<Span> = paragraph.spans): PreparedNativeFloatText {
    val font = checkNotNull(leaf.format)
    val resolvedDirection = checkNotNull(paragraph.reference.bodyTypography?.direction)
    val layoutDirection = if (resolvedDirection == BidiResolvedDirection.Rtl) LayoutDirection.Rtl else LayoutDirection.Ltr
    lateinit var prepared: PreparedNativeFloatText
    CompositionLocalProvider(LocalNativeContainerTextContext provides leaf.context?.copy(bodyDirection = resolvedDirection),
        LocalLayoutDirection provides layoutDirection) {
        val annotated = styledTextAnnotation(spans, null, font.style, onLink)
        val markerColor = Color(checkNotNull(canonicalColorArgb((paragraph.item.markerForeground as FigureColor.Rgb).value)))
        prepared = prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), font.style,
            MaterialTheme.colorScheme.primary, media, settings,
            edition, onLink, prefix = paragraph.marker + " ",
            prefixStyle = font.style.copy(color = markerColor), nativeLineHeight = font.lineHeight,
            sourceFamily = font.sourceFamily, ownerDirection = resolvedDirection,
            ownerFont = font.ownerFont?.takeIf { it.snapshot == paragraph.item.box.ownerFont },
            referenceLayoutBacklink = paragraph.backlink, outsideReferenceMarker = true)
    }
    return prepared
}
