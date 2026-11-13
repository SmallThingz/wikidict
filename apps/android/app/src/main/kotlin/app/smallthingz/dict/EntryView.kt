package app.smallthingz.dict

import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb

import androidx.compose.ui.graphics.Color

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Size
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.Notes
import androidx.compose.material.icons.outlined.VolumeUp
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.ui.platform.LocalContext
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.collectionInfo
import androidx.compose.ui.semantics.collectionItemInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.text.*
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import kotlin.math.roundToInt

private val EgyptianFontFamily = FontFamily(Font(R.font.egyptian_hieroglyphs))
private val spanClassWhitespace = Regex("\\s+")

private data class TextCacheKey(val weight: FontWeight?, val direction: LayoutDirection,
    val background: String?, val normalBodySize: TextUnit, val contextSize: TextUnit, val density: Density,
    val foreground: Int? = null, val cellLetterSpacingPixels: Float? = null, val cssPixelTextZoom: Float = 1f,
    val computedCellTraits: Boolean = false, val cellBodyFamily: FontFamily? = null)
private class TextCache(val link: State<(EntryLink) -> Unit>) {
    val values = java.util.IdentityHashMap<List<Span>, MutableMap<TextCacheKey, AnnotatedString>>()
}
private val LocalEntryMedia = staticCompositionLocalOf<List<Media>> { emptyList() }
private val LocalEntryMediaOwners = staticCompositionLocalOf { MediaOwners(emptyList()) }
private val LocalEntryEdition = staticCompositionLocalOf { "" }
private val LocalReaderSettings = staticCompositionLocalOf { AppSettings() }
private val LocalTextCache = staticCompositionLocalOf<TextCache?> { null }
internal val LocalAuthoredBackground = staticCompositionLocalOf<String?> { null }
internal val LocalFigureCaptionForeground = staticCompositionLocalOf<Int?> { null }
internal val LocalCellWeight = staticCompositionLocalOf<FontWeight?> { null }
private val LocalTableLineHeightPixels = staticCompositionLocalOf<Float?> { null }
private val LocalCellTextAlign = staticCompositionLocalOf<androidx.compose.ui.text.style.TextAlign?> { null }
internal val LocalCellLetterSpacingPixels = staticCompositionLocalOf<Float?> { null }
internal val LocalCssPixelTextZoom = staticCompositionLocalOf { 1f }
internal val LocalNativeContainerTextContext = staticCompositionLocalOf<ContainerTextContext?> { null }
private val LocalNativePreformattedText = staticCompositionLocalOf { false }

@Composable
internal fun inheritedContainerFormat(): NativeContainerTextFormat? = LocalNativeContainerTextContext.current?.let {
    nativeContainerTextFormat(it, MaterialTheme.typography.bodyLarge.fontSize,
        MaterialTheme.typography.bodyLarge.let { style -> if (it.cellText == null) style else
            style.copy(fontWeight = LocalCellWeight.current ?: style.fontWeight) }, LocalDensity.current)
}

@Composable
private fun inheritedContainerBodyStyle(): TextStyle = inheritedContainerFormat()?.style ?: MaterialTheme.typography.bodyLarge

@Composable
internal fun inheritedCellTextStyle(style: TextStyle): TextStyle {
    val pixels = LocalCellLetterSpacingPixels.current ?: return style
    val density = LocalDensity.current
    return style.copy(letterSpacing = with(density) { pixels.toSp() })
}
internal class CellHeadingRequest(val path: String)
internal val LocalCellHeadingRequest = staticCompositionLocalOf<CellHeadingRequest?> { null }
internal val LocalCellHeadingReached = staticCompositionLocalOf<(CellHeadingRequest) -> Unit> { {} }

@Composable
private fun CellHeading(block: Block, path: String?, onLink: (EntryLink) -> Unit) {
    val request = LocalCellHeadingRequest.current
    val reached = LocalCellHeadingReached.current
    val bringIntoView = remember { BringIntoViewRequester() }
    LaunchedEffect(request, path) {
        if (request != null && request.path == path) {
            withFrameNanos { }
            bringIntoView.bringIntoView()
            reached(request)
        }
    }
    StyledText(ordinaryInlineDisplaySpans(block), Modifier.fillMaxWidth()
        .padding(start = blockIndentDp(block).dp).bringIntoViewRequester(bringIntoView)
        .then(if (path == null) Modifier else Modifier.testTag("cell-heading-$path"))
        .semantics { heading() }, style = MaterialTheme.typography.titleMedium, onLink = onLink)
}

@Composable
internal fun EntryPronunciationButton(active: Boolean, onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Icon(if (active) Icons.Outlined.Stop else Icons.Outlined.VolumeUp,
            if (active) "Stop pronunciation" else "Pronounce word offline", Modifier.size(22.dp))
    }
}

/** A distinct request also permits repeated navigation to the same compiled anchor. */
class EntryAnchorRequest(val entryKey: String, val target: String)

/** In-memory state for one reader visit; never shared between same-title owners. */
class EntryReadingState {
    internal val scroll = androidx.compose.foundation.lazy.LazyListState()
    internal var foldKey: List<Any?>? = null
    internal var folds: androidx.compose.runtime.snapshots.SnapshotStateMap<String, Boolean>? = null
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun EntryView(entry: Entry, bookmarked: Boolean, onBookmark: () -> Unit, onLink: (EntryLink) -> Unit = {}, settings: AppSettings = AppSettings(), onScrollDirection: (Boolean) -> Unit = {}, anchorRequest: EntryAnchorRequest? = null, onAnchorConsumed: (EntryAnchorRequest) -> Unit = {}, onNavigate: () -> Unit = {}, readingState: EntryReadingState? = null) {
    val uri = LocalUriHandler.current
    val context = LocalContext.current
    DisposableEffect(entry.key) { onDispose { SpeechPlayback.stop() } }
    val colors = MaterialTheme.colorScheme
    // Share immutable catalog indexes across all text in this entry, including
    // table cells. A nested EntryView supplies its own catalog and owner scope.
    val mediaOwners = remember(entry.key, entry.media) { MediaOwners(entry.media) }
    val missingLinkVisits = LocalMissingLinkVisits.current ?: remember { MissingLinkVisits() }
    val missingLinkOwner = remember(entry, readingState) { Any() }
    CompositionLocalProvider(LocalEntryMedia provides entry.media, LocalEntryMediaOwners provides mediaOwners,
        LocalEntryEdition provides entry.edition, LocalReaderSettings provides settings, LocalMissingLinkVisits provides missingLinkVisits,
        LocalMissingLinkDocument provides entry.title, LocalMissingLinkOwner provides missingLinkOwner) {
      key(entry.key) {
        val scroll = readingState?.scroll ?: rememberLazyListState()
        val reportScroll by rememberUpdatedState(onScrollDirection)
        val threshold = with(LocalDensity.current) { 20.dp.toPx() }
        val dockScroll = remember(scroll, threshold) {
            object : NestedScrollConnection {
                var movement = 0f
                override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                    // Only actual finger-driven content movement counts, never relayout or overscroll.
                    if (source == NestedScrollSource.UserInput && consumed.y != 0f) {
                        if (movement * consumed.y < 0) movement = 0f
                        movement += consumed.y
                        if (kotlin.math.abs(movement) >= threshold) {
                            reportScroll(movement < 0)
                            movement = 0f
                        }
                        if (!scroll.canScrollBackward) reportScroll(false)
                    }
                    return Offset.Zero
                }
            }
        }
        val scope = rememberCoroutineScope()
        var contents by remember { mutableStateOf(false) }
        val foldKey = listOf(entry.key, settings.collapsePronunciation, settings.collapseEtymology, settings.collapseOtherSections, settings.collapseDetails)
        val folded = remember(readingState, foldKey) {
            readingState?.takeIf { it.foldKey == foldKey }?.folds ?: mutableStateMapOf<String, Boolean>().apply {
                entry.readingRows.forEach { row -> row.heading?.let {
                    this[row.key] = initiallyFolded(row, settings)
                    if (row.meaningSection) this[row.key + "-details"] = settings.collapseDetails
                } }
                this["preamble"] = settings.collapseOtherSections && entry.kind != "alias"
                this["references"] = settings.collapseOtherSections
                this["media"] = settings.collapseOtherSections
                this["abbreviations"] = settings.collapseDetails
            }.also { readingState?.foldKey = foldKey; readingState?.folds = it }
        }
        val foldedKeys = folded.filterValues { it }.keys
        // Keep placement stable when folds hide or reveal native float content.
        val nativeFloatEntry = remember(entry.readingRows) { floatBodyRuns(entry.readingRows).isNotEmpty() }
        val visibleRows = visibleEntryReadingRows(entry, foldedKeys)
        val floatRuns = remember(visibleRows) { floatBodyRuns(visibleRows) }
        val floatStarts = floatRuns.associateBy { it.first }
        val floatCovered = floatRuns.flatMap { (it.first + 1 until it.last + 1).toList() }.toSet()
        val entryTextSections = remember(entry, foldedKeys) { foldedEntryTextSections(entry.readingRows, foldedKeys) }
        var cellHeadingRequest by remember { mutableStateOf<CellHeadingRequest?>(null) }
        fun jumpToAnchor(target: String): Boolean {
            val destination = headingDestination(entry, target)
            val headingRow = entry.readingRows.firstOrNull { it.key == destination?.rowKey }
            val compiledHeading = destination?.compiledId == true
            cellHeadingRequest = null
            // Authored heading IDs share the page namespace; generated references are a fallback.
            val referenceIndex = when {
                destination?.referenceIndex != null -> metadataReferencesStartIndex(entry, folded.filterValues { it }.keys) + 1 + destination.referenceIndex
                headingRow?.key == metadataReferenceHeadingKey(entry) && headingRow != null ->
                    metadataReferencesStartIndex(entry, folded.filterValues { it }.keys)
                compiledHeading -> null
                else -> referenceScrollIndex(entry, target, folded.filterValues { it }.keys)
            }
            if (referenceIndex != null) {
                folded["references"] = false
                cellHeadingRequest = destination?.path?.let(::CellHeadingRequest)
                // Apply the destination in the next remeasure, after References opens.
                scroll.requestScrollToItem(referenceIndex)
            } else if (headingRow != null) {
                val sectionKey = if (headingRow.heading != null) headingRow.key else headingRow.sectionKey
                folded[sectionKey] = false
                if (headingRow.heading == null && headingRow.meaningSection) folded[sectionKey + "-details"] = false
                val headingIndex = visibleEntryReadingRows(entry, folded.filterValues { it }.keys)
                    .indexOfFirst { it.key == headingRow.key }
                if (headingIndex < 0) return false
                val openedRows = visibleEntryReadingRows(entry, folded.filterValues { it }.keys)
                val containingRun = floatBodyRuns(openedRows).firstOrNull { headingIndex in it }
                cellHeadingRequest = (destination?.path ?: headingRow.key.takeIf { containingRun != null })?.let(::CellHeadingRequest)
                scroll.requestScrollToItem((containingRun?.first ?: headingIndex) + entryReadingStartIndex(entry, folded.filterValues { it }.keys))
            } else return false
            return true
        }
        val readerLink: (EntryLink) -> Unit = { target ->
            onNavigate()
            if (target.local) jumpToAnchor("#${target.fragment}") else onLink(target)
        }
        LaunchedEffect(entry.key, anchorRequest) {
            anchorRequest?.takeIf { it.entryKey == entry.key }?.let {
                jumpToAnchor(it.target)
                // A missing fragment still opens the word; it is not a second lookup.
                onAnchorConsumed(it)
            }
        }
        val currentLink = rememberUpdatedState(readerLink)
        val cache = remember(entry, colors.primary, colors.surfaceContainer) { TextCache(currentLink) }
        val typedImages = entry.inlineImages
        val imageOwner = if (typedImages.isEmpty()) null else rememberInlineImageViewOwner(typedImages, entry.media, settings, entry.edition, entry.legacyImageFiles, entry.rasterImages)
        val remainingMedia = remember(entry) {
            val linkedFiles = inlineMediaFiles(entry)
            entry.media.filter { it.file !in linkedFiles || it.file in entry.separateImageCaptionFiles }
        }
        CompositionLocalProvider(LocalTextCache provides cache, LocalInlineImageOwner provides imageOwner, LocalCellHeadingRequest provides cellHeadingRequest,
            LocalCellHeadingReached provides { request -> if (cellHeadingRequest === request) cellHeadingRequest = null }) {
        LazyColumn(Modifier.fillMaxSize().nestedScroll(dockScroll).testTag("entry-scroll"), state = scroll, contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 56.dp)) {
            item("title", contentType = "title") {
                Column(Modifier.padding(bottom = 6.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text((entry.language ?: entry.kind.replace('_', ' ')).uppercase(), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                        EntryPronunciationButton(SpeechPlayback.active == entry.title) { SpeechPlayback.play(context, entry.title, entry.languageCode) }
                        Box {
                            IconButton(onClick = { contents = true }) { Icon(Icons.AutoMirrored.Filled.List, "Sections", Modifier.size(22.dp)) }
                            DropdownMenu(contents, { contents = false }, Modifier.heightIn(max = 340.dp)) {
                                entry.readingRows.forEach { row -> row.heading?.let { section ->
                                    if (sectionInContents(section, entry.language)) DropdownMenuItem(text = { Text(section.title) }, onClick = {
                                        onNavigate()
                                        contents = false
                                        val referenceHeading = row.key == metadataReferenceHeadingKey(entry)
                                        folded[if (referenceHeading) "references" else row.key] = false
                                        val targetIndex = if (referenceHeading) {
                                            metadataReferencesStartIndex(entry, folded.filterValues { it }.keys)
                                        } else {
                                            val openedRows = visibleEntryReadingRows(entry, folded.filterValues { it }.keys)
                                            val index = openedRows.indexOfFirst { it.key == row.key }
                                            val run = floatBodyRuns(openedRows).firstOrNull { index in it }
                                            if (run != null) cellHeadingRequest = CellHeadingRequest(row.key)
                                            (run?.first ?: index) + entryReadingStartIndex(entry, folded.filterValues { it }.keys)
                                        }
                                        scope.launch {
                                            androidx.compose.runtime.withFrameNanos { }
                                            scroll.animateScrollToItem(targetIndex)
                                        }
                                    })
                                } }
                            }
                        }
                        IconButton(onClick = onBookmark) { Icon(if (bookmarked) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder, if (bookmarked) "Remove bookmark" else "Bookmark", Modifier.size(22.dp)) }
                    }
                    if (entry.displayTitle.isNotEmpty()) StyledText(entry.displayTitle, Modifier.fillMaxWidth().testTag("entry-title"), style = MaterialTheme.typography.displayMedium, onLink = readerLink)
                    else Text(entry.title, Modifier.fillMaxWidth().testTag("entry-title"), style = MaterialTheme.typography.displayMedium.copy(textDirection=TextDirection.Content))
                    if (entryTextSections.isNotEmpty()) {
                        TextButton(onClick = { entryTextSections.forEach { folded[it] = false } },
                            modifier = Modifier.testTag("show-entry-text")) { Text("Show entry text") }
                    }
                    if (entry.textDetails.isNotEmpty()) {
                        val closed = folded["abbreviations"] != false
                        TextButton(onClick = { folded["abbreviations"] = !closed },
                            modifier = Modifier.testTag("entry-abbreviations").semantics {
                                stateDescription = if (closed) "Collapsed" else "Expanded"
                            }) { Text("Text details") }
                    }
                    entry.redirect?.let { redirect ->
                        Text("${redirect.source} -> ${redirect.target}" + if (redirect.fragment.isEmpty()) "" else "#${redirect.fragment}",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    SpeechPlayback.error?.let { message ->
                        Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                        TextButton(onClick = { runCatching { context.startActivity(android.content.Intent("com.android.settings.TTS_SETTINGS")) } }) { Text("Speech settings") }
                    }
                }
            }
            if (folded["abbreviations"] == false) items(entry.textDetails.indices.toList(),
                key = { when (entry.textDetails[it].kind) {
                    TextDetailKind.Abbreviation -> "abbreviation-$it"
                    TextDetailKind.MediaDescription -> "media-description-$it"
                    TextDetailKind.Advisory -> "advisory-$it"
                } },
                contentType = { entry.textDetails[it].kind }) { index ->
                val detail = entry.textDetails[index]
                Column(Modifier.padding(bottom = 8.dp)) {
                    if (detail.kind != TextDetailKind.Abbreviation) Text(
                        if (detail.kind == TextDetailKind.Advisory) "Advice" else "Media description",
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (detail.label.isNotBlank()) Text(detail.label, style = MaterialTheme.typography.labelLarge)
                    Text(detail.description, style = MaterialTheme.typography.bodyMedium)
                    if (index == 0 || entry.textDetails[index - 1].context != detail.context) {
                        Text(detail.context, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (entry.preamble.isNotEmpty()) item("preamble", contentType = "paragraph") {
                FoldHeading("About this entry", folded["preamble"] == true) { folded["preamble"] = folded["preamble"] != true }
                if (folded["preamble"] != true) StyledText(compactSpans(entry.preamble), Modifier.padding(bottom = 4.dp), onLink = readerLink)
            }
            itemsIndexed(visibleRows, key = { _, row -> row.key }, contentType = { _, row -> if (row.heading != null) "heading" else row.block?.kind }) { rowIndex, row ->
                Column(if (nativeFloatEntry) Modifier else Modifier.animateItem()) {
                row.heading?.let { section ->
                    if (rowIndex !in floatCovered && sectionHeadingVisible(section, entry.language)) {
                        val richHeading = row.headingBlock
                        val label = sectionHeadingLabel(section, entry.language, richHeading)
                        val angle by animateFloatAsState(if (folded[row.key] == true) { if (LocalLayoutDirection.current == androidx.compose.ui.unit.LayoutDirection.Rtl) 90f else -90f } else 0f, label = "Section fold")
                        val toggle = { folded[row.key] = folded[row.key] != true }
                        val headingModifier = if (richHeading == null) Modifier.clickable(onClick = toggle) else Modifier
                        Row(Modifier.fillMaxWidth().padding(start = richHeading?.let { blockIndentDp(it).dp } ?: 0.dp).then(headingModifier).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                            val headingStyle = if (row.meaningSection) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium
                            if (richHeading == null) Text(label, Modifier.weight(1f).semantics { heading() }, style = headingStyle)
                            else CompositionLocalProvider(LocalCellTextAlign provides (richHeading.textAlign?.composeAlign() ?: LocalCellTextAlign.current)) {
                                StyledText(richHeading.spans, Modifier.weight(1f).semantics { heading() }, style = headingStyle, onLink = readerLink)
                            }
                            if (row.meaningSection && section.blocks.any { it !== richHeading && it.kind !in setOf("definition", "blank") }) {
                                IconToggleButton(checked = folded[row.key + "-details"] != true, onCheckedChange = { folded[row.key + "-details"] = !it }) {
                                    Icon(Icons.Outlined.Notes, if (folded[row.key + "-details"] == true) "Show examples and notes for ${section.title}" else "Hide examples and notes for ${section.title}", Modifier.size(20.dp))
                                }
                            }
                            if (richHeading == null) {
                                Icon(Icons.Filled.ExpandMore, if (folded[row.key] == true) "Expand $label" else "Collapse $label", Modifier.size(20.dp).rotate(angle))
                            } else IconButton(onClick = toggle) {
                                Icon(Icons.Filled.ExpandMore, if (folded[row.key] == true) "Expand $label" else "Collapse $label", Modifier.size(20.dp).rotate(angle))
                            }
                        }
                    }
                }
                row.block?.let { block ->
                    val run = floatStarts[rowIndex]
                    when {
                        run != null -> {
                            val rows = visibleRows.slice(run).filter { it.block != null || it.heading?.let { section -> sectionHeadingVisible(section, entry.language) } == true }
                            val blocks = rows.map { item -> item.block ?: item.headingBlock ?: Block("heading", 0,
                                listOf(Span("text", sectionHeadingLabel(item.heading!!, entry.language, null))), level = item.heading!!.level) }
                            val sectionRows = rows.mapIndexedNotNull { index, item -> if (item.heading == null) null else index to item }.toMap()
                            val actions = sectionRows.mapValues { (_, item) -> buildList {
                                val section = item.heading!!
                                add(NativeHeadingAction(if (folded[item.key] == true) "Expand ${section.title}" else "Collapse ${section.title}",
                                    folded[item.key] == true) { folded[item.key] = folded[item.key] != true })
                                if (item.meaningSection && section.blocks.any { it !== item.headingBlock && it.kind !in setOf("definition", "blank") }) {
                                    val key = item.key + "-details"
                                    add(NativeHeadingAction(if (folded[key] == true) "Show examples and notes for ${section.title}" else "Hide examples and notes for ${section.title}",
                                        folded[key] == true) { folded[key] = folded[key] != true })
                                }
                            } }
                            NativeFloatBlockContext(blocks, readerLink, row.sectionKey, Modifier,
                                inCell = false, gridPath = "root", gapDp = 6f, trailingGap = true,
                                containAtEnd = true, blockPaths = rows.map { it.key }, gapsDp = rows.map { if (it.compact) 2f else 6f },
                                sectionRows = sectionRows, sectionActions = actions, sectionKeys = rows.map { it.sectionKey },
                                documentSurface = blocks.any { it.needsContainerDocumentExtent() || it.needsFigureDocumentExtent() },
                                positionedPaintRoot = true)
                        }
                        rowIndex !in floatCovered -> BlockView(block, readerLink, path = row.key,
                            outsideGapDp = if (row.compact) 2f else 6f,
                            previousBlock = visibleRows.getOrNull(rowIndex - 1)?.takeIf { it.sectionKey == row.sectionKey }?.block)
                    }
                }
                }
            }
            if (entry.references.isNotEmpty()) item("references-heading") { FoldHeading("References", folded["references"] == true) { folded["references"] = folded["references"] != true } }
            items(if (folded["references"] == true) emptyList() else entry.references, key = { "reference-${it.number}" }, contentType = { "reference" }) { ref ->
                val label = referenceLabel(ref)
                Row(Modifier.padding(bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (label != null) Text(label, style = MaterialTheme.typography.labelMedium, color = colors.primary)
                    val blocks = ref.blocks
                    if (blocks == null) StyledText(ref.spans, Modifier.weight(1f), onLink = readerLink)
                    else FloatBlockSequence(blocks, readerLink, "reference-${ref.number}",
                        modifier = Modifier.weight(1f), gapDp = 6f, trailingGap = true)

                }
            }
            if (remainingMedia.isNotEmpty()) item("media-heading") { FoldHeading("Media", folded["media"] == true) { folded["media"] = folded["media"] != true } }
            (if (folded["media"] == true) emptyList() else remainingMedia).forEachIndexed { index, media -> item("media-$index", contentType = "media") {
                MediaView(media, settings, edition=entry.edition, showFileName = media.file !in entry.separateImageCaptionFiles,
                    showImage = media.file !in entry.separateImageCaptionFiles)
            } }
            item("attribution") {
                FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                    verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = { uri.openUri(attributionUrl(entry)) }) { Text("Wiktionary contributors",style=MaterialTheme.typography.labelSmall) }
                    TextButton(onClick = { uri.openUri("https://creativecommons.org/licenses/by-sa/4.0/") }) { Text("CC BY-SA 4.0",style=MaterialTheme.typography.labelSmall) }
                }
            }
        }
        }
      }
    }
}


@Composable
private fun FoldHeading(title: String, folded: Boolean, onClick: () -> Unit) {
    val angle by animateFloatAsState(if (folded) { if (LocalLayoutDirection.current == androidx.compose.ui.unit.LayoutDirection.Rtl) 90f else -90f } else 0f, label = "Section fold")
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f).semantics { heading() }, style = MaterialTheme.typography.titleMedium)
        Icon(Icons.Filled.ExpandMore, if (folded) "Expand $title" else "Collapse $title", Modifier.size(20.dp).rotate(angle))
    }
}

@Composable
private fun BlockView(block: Block, onLink: (EntryLink) -> Unit, path: String? = null, inCell: Boolean = false,
    gridPath: String = "root", outsideGapDp: Float? = null, previousBlock: Block? = null) {
    CompositionLocalProvider(LocalCellTextAlign provides (block.textAlign?.composeAlign() ?: LocalCellTextAlign.current)) {
        if (block.style == null) {
            if (outsideGapDp == null) BlockContent(block, onLink, path, inCell, gridPath)
            else Box(Modifier.padding(bottom = outsideGapDp.dp)) { BlockContent(block, onLink, path, inCell, gridPath) }
        } else {
            val density = LocalDensity.current
            val bodyFontPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
            val box = try {
                paragraphBox(block, previousBlock, (outsideGapDp ?: 0f) * density.density, density.density,
                    bodyFontPixels)!!
            } catch (_: UnsupportedFloatLayout) { null }
            if (box == null) {
                Text("Paragraph layout unavailable at this size")
                return@CompositionLocalProvider
            }
            ParagraphBoxLayout(box, outsideGapDp != null,
                paragraphHasContent(block)) {
                BlockContent(block, onLink, path, inCell, gridPath)
            }
        }
    }
}

/** Exact source edges must not be shortened by PaddingModifier's constraint coercion. */
@Composable
private fun ParagraphBoxLayout(box: ParagraphBox, outside: Boolean, hasContent: Boolean, content: @Composable () -> Unit) {
    val message = remember { NativeLayoutInput<String?>(null) }
    val left = kotlin.math.round(box.contentLeft).toInt()
    val right = kotlin.math.round(box.contentRight).toInt()
    val top = kotlin.math.round(box.padding.top + if (outside) box.before else 0f).toInt()
    val bottom = kotlin.math.round(box.padding.bottom + if (outside) box.after else 0f).toInt()
    Layout(modifier = Modifier.fillMaxWidth(), content = {
        if (hasContent) Box { content() }
        NativeLayoutMessage(message)
    }, measurePolicy = object : MeasurePolicy {
        private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
            val contentWidth = if (!hasContent) 0 else if (maximum) measurables.first().maxIntrinsicWidth(Constraints.Infinity)
                else measurables.first().minIntrinsicWidth(Constraints.Infinity)
            val total = contentWidth.toLong() + left + right
            return if (total > TablePixelLimit) Constraints.Infinity else total.toInt()
        }
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
            val width = constraints.maxWidth.takeIf { constraints.hasBoundedWidth } ?: TablePixelLimit
            val inner = width.toLong() - left - right
            val validEdges = inner >= 0 && (!hasContent || inner > 0) && top.toLong() + bottom <= constraints.maxHeight
            var failure = !validEdges
            val measured = if (!hasContent) null else try {
                val available = if (validEdges) inner.toInt() else width
                measurables.first().measure(Constraints(minWidth = available, maxWidth = available))
            } catch (_: IllegalArgumentException) { failure = true; null }
            val height = top.toLong() + (measured?.measuredHeight ?: 0) + bottom
            if (height > constraints.maxHeight || height > Int.MAX_VALUE) failure = true
            val used = maxOf(constraints.minHeight.toLong(), height)
            if (!failure) try { Constraints.fixed(width, used.toInt()) }
                catch (_: IllegalArgumentException) { failure = true }
            message.update(if (failure) "Paragraph layout unavailable at this size" else null)
            val warning = measurables.last().measure(constraints.copy(minWidth = 0, minHeight = 0))
            val finalHeight = if (failure) nativeFallbackHeight(constraints.copy(maxWidth = width),
                warning.height.toLong() + (measured?.height ?: 0)) else used.toInt()
            return layout(width, finalHeight) {
                if (failure) {
                    warning.place(0, 0)
                    if (warning.height < finalHeight) measured?.place(0, warning.height)
                } else measured?.place(left, top)
            }
        }
    })
}

@Composable
private fun BlockContent(block: Block, onLink: (EntryLink) -> Unit, path: String?, inCell: Boolean, gridPath: String) {
    when {
        block.container != null -> NativeFloatBlockContext(listOf(block), onLink, path ?: gridPath,
            Modifier, inCell, gridPath, 0f, false)
        block.figure != null || block.flow != null -> {
            // List ownership is outside the figure/anonymous formatting owner.
            Row(Modifier.padding(start = blockIndentDp(block).dp)) {
                val prefix = blockPrefix(block)
                if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp),
                    color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                AnonymousBlockView(block, Modifier.weight(1f), onLink,
                    LocalEntryMedia.current, LocalReaderSettings.current, LocalEntryEdition.current,
                    inheritedAlign = figureInheritedAlign(LocalCellTextAlign.current, LocalLayoutDirection.current))
            }
        }
        block.table?.style?.isInline == true -> InlineTableLine(block, onLink, path, inCell, gridPath)
        block.table != null -> {
            val prefix = if (block.kind == "list_item") blockPrefix(block) else ""
            if (prefix.isEmpty()) {
                Box(Modifier.padding(start = blockIndentDp(block).dp)) { RenderCompiledTable(block.table, block.feature, gridPath, inCell, path?.let { "$it/table" }.orEmpty(), onLink) }
            } else Row(Modifier.padding(start = blockIndentDp(block).dp)) {
                Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp),
                    color = canonicalColorArgb(LocalAuthoredBackground.current)?.let { Color(authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)!!) } ?: MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.labelMedium)
                Box(Modifier.weight(1f)) { RenderCompiledTable(block.table, block.feature, gridPath, inCell, path?.let { "$it/table" }.orEmpty(), onLink) }
            }
        }
        block.kind == "heading" -> CellHeading(block, path, onLink)
        block.kind == "rule" -> HorizontalDivider(color =
            authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)?.let { Color(it) } ?: DividerDefaults.color)
        block.kind == "preformatted" && block.textAlign != null -> Box(
            Modifier.preformattedWidthIntrinsics().fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer)
                .horizontalScroll(rememberScrollState()).padding(12.dp), propagateMinConstraints = true) {
            CompositionLocalProvider(LocalAuthoredBackground provides null, LocalNativePreformattedText provides true) {
                StyledText(block.spans, style = (inheritedContainerFormat()?.style ?: MaterialTheme.typography.bodySmall).copy(fontFamily = FontFamily.Monospace),
                    onLink = onLink, preserveWhitespace = true)
            }
        }
        block.kind == "preformatted" -> Box(Modifier.preformattedWidthIntrinsics().fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).horizontalScroll(rememberScrollState()).padding(12.dp)) {
            CompositionLocalProvider(LocalAuthoredBackground provides null, LocalNativePreformattedText provides true) {
                StyledText(block.spans, style = (inheritedContainerFormat()?.style ?: MaterialTheme.typography.bodySmall).copy(fontFamily = FontFamily.Monospace), onLink = onLink, preserveWhitespace = true)
            }
        }
        else -> {
            val prefix = blockPrefix(block)
            Row(Modifier.padding(start = blockIndentDp(block).dp)) {
                if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp), color = canonicalColorArgb(LocalAuthoredBackground.current)?.let { Color(authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)!!) } ?: MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                StyledText(if (block.style != null) paragraphDisplaySpans(block) else ordinaryInlineDisplaySpans(block),
                    Modifier.weight(1f), weight = if (block.kind == "term") FontWeight.Bold else null,
                    onLink = onLink, preserveWhitespace = block.style != null)
            }
        }
    }
}

@Composable
internal fun CompiledTableView(table: Table, feature: Feature?, onLink: (EntryLink) -> Unit) =
    RenderCompiledTable(table, feature, "root", false, "", onLink)

@Composable
private fun RenderCompiledTable(table: Table, feature: Feature?, path: String, nested: Boolean, semanticPath: String, onLink: (EntryLink) -> Unit) {
    val sample = colorSwatch(feature)
    if (sample == null) {
        TableView(table, onLink, path, nested, semanticPath)
    } else {
        Row(Modifier.semantics(mergeDescendants = true) {},
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            // Decorative sample: the visible label supplies its single accessible name.
            Box(Modifier.size(40.dp).background(androidx.compose.ui.graphics.Color(sample.argb))
                .testTag("compiled-color-swatch"))
            StyledText(listOf(Span("text", "Color sample ${sample.hex}")))
        }
    }
}

@Composable
private fun tableLineHeightPixels(table: Table, contextStyle: TextStyle = inheritedContainerBodyStyle()): Float? {
    val density = LocalDensity.current
    val contextPixels = with(density) { LocalTextStyle.current.merge(contextStyle).fontSize.toPx() }
    val normalPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    return table.style?.lineHeight?.let { value ->
        value.value * if (value.fontScaleBasis == FontScaleBasis.Context) contextPixels else normalPixels
    } ?: LocalTableLineHeightPixels.current
}

@Composable
private fun InlineTableLine(block: Block, onLink: (EntryLink) -> Unit, path: String?, inCell: Boolean, gridPath: String) {
    val table = requireNotNull(block.table)
    val density = LocalDensity.current
    val parentStyle = LocalTextStyle.current.merge(inheritedContainerBodyStyle())
    val resolver = androidx.compose.ui.platform.LocalFontFamilyResolver.current
    val typeface by resolver.resolve(parentStyle.fontFamily ?: FontFamily.Default,
        parentStyle.fontWeight ?: FontWeight.Normal, parentStyle.fontStyle ?: FontStyle.Normal,
        parentStyle.fontSynthesis ?: androidx.compose.ui.text.font.FontSynthesis.All)
    val parentFontPixels = with(density) { parentStyle.fontSize.toPx() }
    val xHeight = remember(typeface, parentFontPixels) {
        val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface as android.graphics.Typeface
            textSize = parentFontPixels
        }
        val ink = android.graphics.Rect()
        paint.getTextBounds("x", 0, 1, ink)
        ink.height().toFloat()
    }
    val strut = rememberTextMeasurer().measure(AnnotatedString("x"), style = parentStyle,
        softWrap = false, maxLines = 1)
    val prefix = if (block.kind == "list_item") blockPrefix(block) else ""
    Layout(modifier = Modifier.padding(start = blockIndentDp(block).dp), content = {
        if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(end = 6.dp),
            color = canonicalColorArgb(LocalAuthoredBackground.current)?.let { Color(authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)!!) }
                ?: MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
        Box {
            RenderCompiledTable(table, block.feature, gridPath, inCell, path?.let { "$it/table" }.orEmpty(), onLink)
        }
    }) { measurables, constraints ->
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val marker = if (prefix.isEmpty()) null else measurables.first().measure(loose)
        val markerWidth = marker?.width ?: 0
        val available = (constraints.maxWidth - markerWidth).coerceAtLeast(0)
        val grid = measurables.last().measure(loose.copy(maxWidth = available))
        val baseline = strut.firstBaseline
        val gridBaseline = when (table.style?.verticalAlign) {
            InlineBoxVerticalAlign.Middle -> grid.height / 2f + xHeight / 2f
            else -> {
                val line = if (table.style?.display == TableDisplay.InlineTable)
                    grid[androidx.compose.ui.layout.FirstBaseline] else grid[androidx.compose.ui.layout.LastBaseline]
                if (line == androidx.compose.ui.layout.AlignmentLine.Unspecified) grid.height.toFloat() else line.toFloat()
            }
        }
        val markerLine = marker?.get(androidx.compose.ui.layout.FirstBaseline)
            ?.takeUnless { it == androidx.compose.ui.layout.AlignmentLine.Unspecified } ?: 0
        val line = inlineTableLinePixels(strut.size.height, baseline, grid.height, gridBaseline,
            table.style?.verticalAlign, marker?.height, markerLine)
        val width = constraints.constrainWidth(markerWidth + grid.width)
        val height = constraints.constrainHeight(line.height)
        layout(width, height, mapOf(androidx.compose.ui.layout.FirstBaseline to line.baseline,
            androidx.compose.ui.layout.LastBaseline to line.baseline)) {
            marker?.placeRelative(0, line.markerTop)
            grid.placeRelative(markerWidth, line.tableTop)
        }
    }
}

internal val LocalTableContentWidths = staticCompositionLocalOf { false }

@Composable
private fun TableView(table: Table, onLink: (EntryLink) -> Unit, path: String = "root", nested: Boolean = false, semanticPath: String = "") {
  if ((table.style?.floatSide != null || table.style?.let { it.marginValues != null && !it.isInline } == true) &&
      !LocalFloatMarginsConsumed.current) {
      NativeFloatBlockContext(listOf(Block(kind = "table", depth = 0, spans = emptyList(), table = table)),
          onLink, semanticPath, Modifier, nested, path, 0f, false)
      return
  }
  if (table.style?.marginValues != null) {
      AutoMarginTableView(table, onLink, path, nested, semanticPath)
      return
  }
  if (table.style?.isInline != true && tableUsesContentWidths(table, LocalTableContentWidths.current)) {
      ContentSizedTableView(table, onLink, path, nested, semanticPath)
      return
  }
  val phaseObserver = LocalTablePhaseObserver.current
  val window = LocalWindowInfo.current.containerSize
  val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
  val inline = table.style?.isInline == true
  val lineHeightPixels = tableLineHeightPixels(table)
  if (lineHeightPixels != null && (!lineHeightPixels.isFinite() || lineHeightPixels <= 0f || lineHeightPixels > TablePixelLimit)) {
      Text("Table line height is too large to display.")
      return
  }
  CompositionLocalProvider(LocalTableLineHeightPixels provides lineHeightPixels) {
  BoxWithConstraints(if (inline) Modifier else Modifier.fillMaxWidth()) {
    val decorationWidth = LocalFloatTableWidthReference.current?.value ?: listOfNotNull(constraints.maxWidth.takeIf { constraints.hasBoundedWidth }, window.width.takeIf { it > 0 }).minOrNull()
    val decorationHeight = listOfNotNull(constraints.maxHeight.takeIf { constraints.hasBoundedHeight }, window.height.takeIf { it > 0 }).minOrNull()
    val density = LocalDensity.current
    val fontPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    var decorationProjection by remember(table, density.density, fontPixels, decorationWidth, decorationHeight) { mutableDoubleStateOf(1.0) }
    val natural = remember(table, density.density, fontPixels, decorationProjection, decorationWidth, decorationHeight, phaseObserver, rtl) {
      observeTablePhase(phaseObserver, TablePhase.Preparation) {
        tableRenderMetrics(table, with(density) { 136.dp.roundToPx() }, with(density) { 10.dp.roundToPx() },
            with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = fontPixels,
            decorationScale = decorationProjection, decorationViewportWidth = decorationWidth,
            decorationViewportHeight = decorationHeight, rtl = rtl)
      }
    }
    val margin = natural?.style?.margins.takeUnless { LocalFloatMarginsConsumed.current }
    val marginModifier = if (margin == null) Modifier else with(density) {
        Modifier.absolutePadding(left = margin.left.toDp(), top = margin.top.toDp(),
            right = margin.right.toDp(), bottom = margin.bottom.toDp())
    }
    Column((if (inline) Modifier else Modifier.fillMaxWidth()).then(marginModifier), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (table.captionBlocks != null) FloatBlockSequence(table.captionBlocks, onLink, "$semanticPath/caption",
            gapDp = 6f, trailingGap = false)
        else if (table.caption.isNotEmpty()) StyledText(table.caption, onLink = onLink)
        if (nested || LocalNativeContainerScrollport.current) BoxWithConstraints(if (inline) Modifier else Modifier.fillMaxWidth()) {
            TableGridView(table, onLink, path, constraints.maxWidth.takeIf { constraints.hasBoundedWidth }, semanticPath,
                natural, decorationProjection, { decorationProjection = 0.0 })
        } else BoxWithConstraints(if (inline) Modifier else Modifier.fillMaxWidth()) {
            val viewportWidth = constraints.maxWidth.takeIf { constraints.hasBoundedWidth }
            // A child grid belongs to the same scroll surface as its outer table.
            Box((if (inline) Modifier else Modifier.fillMaxWidth()).horizontalScroll(rememberScrollState())) {
                TableGridView(table, onLink, path, viewportWidth, semanticPath,
                    natural, decorationProjection, { decorationProjection = 0.0 })
            }
        }
    }
  }
  }
}

/** Automatic margins share one caption/grid border box; their native parent owns block placement. */
@Composable
private fun AutoMarginTableView(table: Table, onLink: (EntryLink) -> Unit, path: String,
    nested: Boolean, semanticPath: String) {
    val density = LocalDensity.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val natural = remember(table, density.density, bodyPixels, rtl) {
        tableRenderMetrics(table, 1, with(density) { 10.dp.roundToPx() },
            with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = bodyPixels, rtl = rtl)
    }
    val lineHeight = tableLineHeightPixels(table)
    val marginValues = checkNotNull(table.style?.marginValues)
    val margins = resolveTableAutoMargins(marginValues, density.density, bodyPixels)
    val fixed = if (LocalFloatMarginsConsumed.current) FloatMargins(0f, 0f, 0f, 0f) else margins.fixed
    val captionMinimum = remember(table) { NativeLayoutInput(0) }
    val hasCaption = table.captionBlocks?.isNotEmpty() == true || table.caption.isNotEmpty()
    val scrolling = table.style?.isInline != true && !nested && !LocalNativeContainerScrollport.current
    CompositionLocalProvider(LocalTableContentWidths provides true, LocalTableLineHeightPixels provides lineHeight) {
        TableMarginBorderBox(table, captionMinimum, hasCaption, with(density) { 6.dp.roundToPx() }, scrolling, fixed) {
            if (hasCaption) TableContentColumn(Modifier, 0.dp) {
                if (table.captionBlocks != null) FloatBlockSequence(table.captionBlocks, onLink, "$semanticPath/caption",
                    gapDp = 6f, trailingGap = false)
                else StyledText(table.caption, onLink = onLink)
            }
            TableGridView(table, onLink, path, null, semanticPath, natural, 1.0, { },
                contentWidths = true, captionMinimumWidth = captionMinimum)
        }
    }
}

/** Rich cells remain composed while the grid asks those same children for their width ranges. */
@Composable
private fun ContentSizedTableView(table: Table, onLink: (EntryLink) -> Unit, path: String,
    nested: Boolean, semanticPath: String) {
    val density = LocalDensity.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val natural = remember(table, density.density, bodyPixels, rtl) {
        // This prepares decoration only. Content widths come from the real cells below.
        tableRenderMetrics(table, 1, with(density) { 10.dp.roundToPx() },
            with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = bodyPixels, rtl = rtl)
    }
    val lineHeight = tableLineHeightPixels(table)
    if (lineHeight != null && (!lineHeight.isFinite() || lineHeight <= 0f || lineHeight > TablePixelLimit)) {
        Text("Table line height is too large to display.")
        return
    }
    val margin = natural?.style?.margins.takeUnless { LocalFloatMarginsConsumed.current }
    val marginModifier = if (margin == null) Modifier else with(density) {
        Modifier.absolutePadding(left = margin.left.toDp(), top = margin.top.toDp(),
            right = margin.right.toDp(), bottom = margin.bottom.toDp())
    }
    CompositionLocalProvider(LocalTableContentWidths provides true, LocalTableLineHeightPixels provides lineHeight) {
        TableContentColumn(marginModifier, 6.dp) {
            if (table.captionBlocks != null) FloatBlockSequence(table.captionBlocks, onLink, "$semanticPath/caption",
                gapDp = 6f, trailingGap = false)
            else if (table.caption.isNotEmpty()) StyledText(table.caption, onLink = onLink)
            TableContentViewport(scrolling = !nested && !LocalNativeContainerScrollport.current) {
                TableGridView(table, onLink, path, null, semanticPath, natural, 1.0, { }, contentWidths = true)
            }
        }
    }
}

@Composable
private fun TableGridView(table: Table, onLink: (EntryLink) -> Unit, path: String, widthReference: Int?, semanticPath: String,
    natural: TableRenderMetrics?, decorationProjection: Double, removeDecorations: () -> Unit,
    selectionCells: List<CaptionCellSlot>? = null, selectionGeometry: SelectionGeometrySink? = null,
    containerStyle: TextStyle? = null, contentWidths: Boolean = false,
    captionMinimumWidth: NativeLayoutInput<Int>? = null) {
    val widthInput = LocalFloatTableWidthReference.current
    val resolvedWidthReference = widthInput?.value ?: widthReference
    val phaseObserver = LocalTablePhaseObserver.current
    val grid = remember(table, phaseObserver) { observeTablePhase(phaseObserver, TablePhase.Preparation) { tableGrid(table) } }
    val delegated = LocalNativeDelegatedTable.current?.takeIf { it.table === table && selectionCells == null }
    val delegatedFallback = delegated?.fallbackReason != null
    SideEffect { delegated?.composedFallback(delegatedFallback) }
    val density = LocalDensity.current
    val inheritedBackground = LocalAuthoredBackground.current
    val inheritedColor = canonicalColorArgb(inheritedBackground)?.let { Color(it) }
    val fontPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val authoredColors = remember(table) { grid.cells.map { placed ->
        canonicalColorArgb(placed.cell.background)?.let { androidx.compose.ui.graphics.Color(it) }
    } }
    val fallbackMessage = remember { NativeLayoutInput<String?>(null) }
    var drawingPixels by remember(table, density.density, density.fontScale, fontPixels, resolvedWidthReference, decorationProjection, natural) { mutableStateOf<TablePixelLayout?>(null) }
    val headerColor = MaterialTheme.colorScheme.surfaceContainerHigh
    val cellColor = MaterialTheme.colorScheme.surface
    val borderColor = MaterialTheme.colorScheme.outline
    if (natural == null && decorationProjection > 0.0 && tableContainsStyle(table) && !tableHasComputedCellStyle(table)) {
        LaunchedEffect(table, decorationProjection) { removeDecorations() }
        return
    }
    if (natural == null) {
        val request = LocalCellHeadingRequest.current
        val reached = LocalCellHeadingReached.current
        LaunchedEffect(request, semanticPath) {
            if (request != null && semanticPath.isNotEmpty() && request.path.startsWith("$semanticPath/")) reached(request)
        }
        Text("Table is too large to display.",
            color = authoredSpanForegroundArgb(null, inheritedBackground)?.let { Color(it) } ?: Color.Unspecified)
        return
    }
    val styled = natural.style
    val cellBaselinePolicy = LocalNativeContainerTextContext.current?.cellText != null ||
        grid.cells.any { it.cell.style?.lineHeight != null }
    val lineHeightPixels = tableLineHeightPixels(table, containerStyle ?: inheritedContainerBodyStyle())
    if (lineHeightPixels != null && (!lineHeightPixels.isFinite() || lineHeightPixels <= 0f || lineHeightPixels > TablePixelLimit)) {
        Text("Table line height is too large to display.")
        return
    }
    val widthModifier = if (table.style?.marginValues != null || captionMinimumWidth != null)
        widthInput?.tableExtentModifier ?: Modifier else widthInput?.modifier ?: Modifier
    Layout(modifier = widthModifier.then(captionMinimumWidth?.tableExtentModifier ?: Modifier)
        .testTag(if (path == "root") "compiled-table-grid" else "compiled-table-grid-$path")
        .onGloballyPositioned { coordinates ->
            delegated?.let { it.gridCoordinates = coordinates; it.validateAfterPlacement() }
        }
        .semantics { collectionInfo = androidx.compose.ui.semantics.CollectionInfo(grid.rows, grid.columns) }
        .drawWithCache {
            // Measurement publishes paint geometry. Observe it in the draw cache,
            // not composition: opening a large table must not schedule a second
            // composition merely to calculate its collapsed border segments.
            val pixels = drawingPixels
            val collapsedBorders = observeTablePhase(phaseObserver, TablePhase.DrawCache) {
                if (pixels != null && styled?.collapse == true)
                    collapsedTableBorders(grid, pixels, styled).flatMap(::tableBorderBands) else emptyList()
            }
            onDrawBehind {
            observeTablePhase(phaseObserver, TablePhase.Draw) {
            if (pixels != null) {
            val tableBackground = styled?.background?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } }
            tableBackground?.let { drawRect(it) }
            grid.cells.forEachIndexed { index, placed ->
                val cellWidth = pixels.cellWidth(placed.colspan, placed.column)
                val left = pixels.physicalCellLeft(placed.column, placed.colspan, layoutDirection == LayoutDirection.Rtl)
                val top = pixels.cellTop(placed.row)
                val bottom = pixels.cellBottom(placed.row, placed.cell.rowspan)
                drawRect(authoredColors[index] ?: tableBackground ?: inheritedColor ?: if (placed.cell.header) headerColor else cellColor,
                    topLeft = Offset(left.toFloat(), top.toFloat()), size = Size(cellWidth.toFloat(), (bottom - top).toFloat()))
                if (styled?.collapse != true) {
                    val fallback = TableStyleBorder(pixels.borderWidth.toFloat(), null)
                    val edges = styled?.cellEdges?.get(index) ?: TableCellBorders(fallback, fallback, fallback, fallback)
                    separateCellBorderSegments(left.toFloat(), top.toFloat(), (left + cellWidth).toFloat(), bottom.toFloat(), edges).forEach { edge ->
                        val color = edge.color?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } } ?: borderColor
                        paintNativeTableBorder(drawContext.canvas.nativeCanvas, edge, color.toArgb())
                    }
                }
            }
            if (styled?.collapse == true) collapsedBorders.forEach { edge ->
                fun x(value: Float) = if (layoutDirection == androidx.compose.ui.unit.LayoutDirection.Rtl) pixels.width - value else value
                val color = edge.color?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } } ?: borderColor
                paintNativeTableBorder(drawContext.canvas.nativeCanvas, edge.copy(x1 = x(edge.x1), x2 = x(edge.x2)), color.toArgb())
            } else {
                val fallback = TableStyleBorder(pixels.borderWidth.toFloat(), null)
                val outer = styled?.outerEdges ?: TableCellBorders(fallback, fallback, fallback, fallback)
                separateCellBorderSegments(0f, 0f, pixels.width.toFloat(), pixels.height.toFloat(), outer).forEach { edge ->
                    val color = edge.color?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } } ?: borderColor
                    paintNativeTableBorder(drawContext.canvas.nativeCanvas, edge, color.toArgb())
                }
            }
            }
            }
            }
        }, content = {
        observeTablePhase(phaseObserver, TablePhase.Composition, grid.cells.size) {
        grid.cells.forEachIndexed { index, placed ->
            val insets = styled?.cellInsets?.get(index)
            val padding = if (insets == null) with(density) { Modifier.padding((natural.cellPadding + natural.borderWidth).toDp()) }
                else with(density) { Modifier.absolutePadding(left = insets.left.toDp(), top = insets.top.toDp(),
                    right = insets.right.toDp(), bottom = insets.bottom.toDp()) }
            val textAlign = when (placed.cell.style?.textAlign) {
                CellTextAlign.Left -> androidx.compose.ui.text.style.TextAlign.Left
                CellTextAlign.Center -> androidx.compose.ui.text.style.TextAlign.Center
                CellTextAlign.Right -> androidx.compose.ui.text.style.TextAlign.Right
                null -> LocalCellTextAlign.current
            }
            val letterSpacing = placed.cell.style?.letterSpacing?.let { exactCellStylePixels(it, density.density, fontPixels) }
                ?: LocalCellLetterSpacingPixels.current
            val delegatedCell = delegated?.cells?.get(index)
            val cellContext = nativeCellTextContext(placed.cell, LocalNativeContainerTextContext.current,
                containerStyle ?: inheritedContainerBodyStyle(), MaterialTheme.typography.bodyLarge.fontSize,
                density, LocalCssPixelTextZoom.current, lineHeightPixels)
            val cellWeight = if (placed.cell.header) {
                if (placed.cell.style?.lineHeight != null) FontWeight.Bold else FontWeight.SemiBold
            } else LocalCellWeight.current
            Box(Modifier.testTag("compiled-table-cell-$path-$index").onGloballyPositioned { coordinates ->
                delegatedCell?.let { it.cellCoordinates = coordinates; it.table.validateAfterPlacement() }
            }.semantics {
                collectionItemInfo = androidx.compose.ui.semantics.CollectionItemInfo(
                    placed.row, placed.cell.rowspan, placed.column, placed.colspan)
                if (placed.cell.header) heading()
            }.then(padding)) {
                CompositionLocalProvider(LocalNativeDelegatedTable provides null,
                    LocalNativeDelegatedCell provides delegatedCell,
                    LocalFloatTableWidthReference provides null, LocalFloatMarginsConsumed provides false, LocalAuthoredBackground provides (placed.cell.background ?: styled?.background ?: inheritedBackground),
                    LocalCellTextAlign provides textAlign,
                    LocalNativeContainerTextContext provides cellContext,
                    LocalTableLineHeightPixels provides lineHeightPixels.takeIf { cellContext?.cellText == null },
                    LocalCellLetterSpacingPixels provides letterSpacing,
                    LocalCellWeight provides cellWeight) {
                    val cellPath = "$semanticPath/cell-$index"
                    val selection = selectionCells?.get(index)
                    val blocks = placed.cell.blocks
                    if (selection != null) selection.content { selection.geometry = it }
                    else if (blocks != null) FloatBlockSequence(blocks, onLink, cellPath, inCell = true,
                        gridPath = "$path/$index", gapDp = 4f, trailingGap = false)
                    else {
                        val child = placed.cell.nestedTable
                        if (child == null && cellContext?.cellText != null && placed.cell.spans.isEmpty()) Spacer(Modifier)
                         else if (child == null) StyledText(placed.cell.spans, onLink = onLink)
                        else TableView(child, onLink, "$path/$index", nested = true, semanticPath = "$cellPath/nested")
                    }
                }
            }
        }
        }
        NativeLayoutMessage(fallbackMessage)
    }, measurePolicy = object : MeasurePolicy {
        private fun intrinsicWidth(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
            val cells = measurables.take(grid.cells.size)
            val css = table.style?.width
            val legacy = table.geometry?.width.takeIf { css == null }
            val requested = when {
                css?.unit == StyleWidthUnit.Px -> css.value.toDouble() * density.density
                css?.unit == StyleWidthUnit.Em -> css.value.toDouble() * fontPixels
                legacy?.unit == TableWidthUnit.Px -> legacy.value.toDouble() * density.density
                else -> null // A percentage is resolved only after the containing table is assigned a width.
            }
            if (requested != null && (!requested.isFinite() || requested !in 0.0..TablePixelLimit.toDouble()))
                return Constraints.Infinity
            val result = inlineTableMetrics(natural, grid,
                IntArray(cells.size) { cells[it].minIntrinsicWidth(Constraints.Infinity) },
                IntArray(cells.size) { cells[it].maxIntrinsicWidth(Constraints.Infinity) },
                if (maximum) TablePixelLimit else 0, requested?.let { kotlin.math.round(it).toInt() },
                tableCellWidthPreferences(grid, styled?.cellInsets, 2 * (natural.cellPadding + natural.borderWidth),
                    density.density, fontPixels))
            return result?.width ?: Constraints.Infinity
        }

        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            intrinsicWidth(measurables, false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            intrinsicWidth(measurables, true)

        override fun MeasureScope.measure(measurables: List<Measurable>, incoming: Constraints): MeasureResult {
        val cells = measurables.take(grid.cells.size)
        val reference = widthInput?.value ?: widthReference ?: incoming.maxWidth.takeIf { incoming.hasBoundedWidth }
        val metrics = if (contentWidths || table.style?.isInline == true) {
            if (!contentWidths) check(selectionCells == null && table.rows.all { row -> row.all(::inlineTableCellShape) })
            val available = widthReference ?: incoming.maxWidth.takeIf { incoming.hasBoundedWidth } ?: TablePixelLimit
            val containing = reference ?: available
            val cssWidth = table.style?.width
            val legacyWidth = table.geometry?.width.takeIf { cssWidth == null }
            val requested = when {
                cssWidth?.unit == StyleWidthUnit.Px -> cssWidth.value.toDouble() * density.density
                cssWidth?.unit == StyleWidthUnit.Em -> cssWidth.value.toDouble() * fontPixels
                cssWidth?.unit == StyleWidthUnit.Percent -> cssWidth.value.toDouble() * containing / 100.0
                legacyWidth?.unit == TableWidthUnit.Px -> legacyWidth.value.toDouble() * density.density
                legacyWidth?.unit == TableWidthUnit.Percent -> legacyWidth.value.toDouble() * containing / 100.0
                else -> null
            }
            if (requested != null && (!requested.isFinite() || requested !in 0.0..TablePixelLimit.toDouble())) null
            else inlineTableMetrics(natural, grid,
                IntArray(cells.size) { cells[it].minIntrinsicWidth(Constraints.Infinity) },
                IntArray(cells.size) { cells[it].maxIntrinsicWidth(Constraints.Infinity) },
                available, requested?.let { kotlin.math.round(it).toInt() },
                tableCellWidthPreferences(grid, styled?.cellInsets, 2 * (natural.cellPadding + natural.borderWidth),
                    density.density, fontPixels), captionMinimumWidth = captionMinimumWidth?.value ?: 0)
        } else tableMetricsInWidth(table, natural, grid.columns, reference)
        val heightLimit = metrics?.let { tableHeightLimit(it.width) }
        // One actual measure per cell; native cells keep the original non-intrinsic path.
        val children = if (metrics == null || heightLimit == null) emptyList() else
          observeTablePhase(phaseObserver, TablePhase.Measurement, cells.size) {
          cells.mapIndexed { index, measurable ->
            val placed = grid.cells[index]
            val width = metrics.cellWidth(placed.column, placed.colspan)
            measurable.measure(Constraints(minWidth = width, maxWidth = width, minHeight = 0, maxHeight = heightLimit))
        }
        }
        val pixels = observeTablePhase(phaseObserver, TablePhase.PixelLayout, children.size) {
          if (metrics == null || heightLimit == null) null else tablePixelLayout(grid, metrics.columnWidth,
            metrics.minRowHeight, IntArray(children.size) { children[it].height }, metrics.cellSpacing, metrics.borderWidth,
             metrics.width, metrics.extraColumns, metrics.style?.tablePadding ?: TablePixelInsets(0, 0, 0, 0), metrics.columnWidths, metrics.outerBorder)
        }
        return if (pixels == null) {
            drawingPixels = null
            if (decorationProjection > 0.0 && tableContainsStyle(table) && !tableHasComputedCellStyle(table)) removeDecorations()
            // Keep the existing cells visible in an explicitly unavailable grid.
            // A later width change measures these same owners again, without
            // replacing active media or latching a composition-only error state.
            val width = (reference ?: incoming.maxWidth).coerceIn(0, TablePixelLimit)
            fallbackMessage.update("Table layout is unavailable at this size.")
            val warning = measurables.last().measure(Constraints(maxWidth = width))
            val retained = if (children.size == cells.size) children else cells.map {
                it.measure(Constraints(maxWidth = width, maxHeight = tableHeightLimit(width) ?: 0))
            }
            val height = nativeFallbackHeight(Constraints(maxWidth = width,
                minHeight = incoming.minHeight, maxHeight = incoming.maxHeight),
                warning.height.toLong() + retained.sumOf { it.height.toLong() })
            if (selectionCells != null && selectionGeometry != null) {
                var top = warning.height.toLong()
                val selected = selectionCells.mapIndexedNotNull { index, slot ->
                    val exact = slot.geometry
                    val insets = styled?.cellInsets?.get(index) ?: TablePixelInsets(
                        natural.cellPadding + natural.borderWidth, natural.cellPadding + natural.borderWidth,
                        natural.cellPadding + natural.borderWidth, natural.cellPadding + natural.borderWidth)
                    val item = if (exact != null && top < height) PositionedSemanticChild(NoPaintGeometry(exact),
                        insets.left.toFloat(), top.toFloat() + insets.top,
                        if (layoutDirection == LayoutDirection.Rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr) else null
                    top += retained[index].height
                    item
                }
                selectionGeometry(if (selected.size == selectionCells.size) NativeSemanticGroup(width, height, selected) else null)
            }
            layout(width, height) {
                warning.place(0, 0)
                var top = warning.height.toLong()
                retained.forEach { item ->
                    if (top < height && top <= Int.MAX_VALUE) item.place(0, top.toInt())
                    top += item.height
                }
            }
        } else {
            fallbackMessage.update(null)
            measurables.last().measure(Constraints.fixed(0, 0))
            drawingPixels = pixels
            val tableBaselines = if (cellBaselinePolicy) {
                val cellLines = children.indices.map { index ->
                    if (selectionCells != null) {
                        val padding = styled?.cellInsets?.get(index)?.top ?: (natural.cellPadding + natural.borderWidth)
                        selectionCells[index].geometry?.textBaselines?.translated(padding.toFloat())
                    } else NativeTextBaselines.of(
                        children[index][androidx.compose.ui.layout.FirstBaseline]
                            .takeUnless { it == androidx.compose.ui.layout.AlignmentLine.Unspecified }?.toFloat(),
                        children[index][androidx.compose.ui.layout.LastBaseline]
                            .takeUnless { it == androidx.compose.ui.layout.AlignmentLine.Unspecified }?.toFloat())
                }
                nativeTableTextBaselines(cellLines, grid.cells.map { it.row },
                    grid.cells.map { pixels.cellTop(it.row).toFloat() })
            } else null
            if (selectionCells != null && selectionGeometry != null) {
                val selected = selectionCells.mapIndexedNotNull { index, slot ->
                    val placed = grid.cells[index]
                    val exact = slot.geometry ?: return@mapIndexedNotNull null
                    val insets = styled?.cellInsets?.get(index)
                        ?: TablePixelInsets(natural.cellPadding + natural.borderWidth, natural.cellPadding + natural.borderWidth,
                            natural.cellPadding + natural.borderWidth, natural.cellPadding + natural.borderWidth)
                    val cellWidth = pixels.cellWidth(placed.colspan, placed.column)
                    if (exact.width + insets.horizontal != children[index].width ||
                        exact.height + insets.vertical != children[index].height)
                        return@mapIndexedNotNull null
                    val left = pixels.physicalCellLeft(placed.column, placed.colspan, layoutDirection == LayoutDirection.Rtl)
                    PositionedSemanticChild(NoPaintGeometry(exact), (left + insets.left).toFloat(),
                        (pixels.cellTop(placed.row) + insets.top).toFloat(),
                        if (layoutDirection == LayoutDirection.Ltr) BidiResolvedDirection.Ltr else BidiResolvedDirection.Rtl,
                        if (index > 0) "\n" else "")
                }
                selectionGeometry(if (selected.size == selectionCells.size) NativeSemanticGroup(pixels.width, pixels.height, selected,
                    baselineProvider = if (cellBaselinePolicy) ({ tableBaselines }) else null) else null)
            }
            val lines: Map<androidx.compose.ui.layout.AlignmentLine, Int> = if (cellBaselinePolicy) {
                listOfNotNull(tableBaselines?.first?.let { androidx.compose.ui.layout.FirstBaseline to it.roundToInt() },
                    tableBaselines?.last?.let { androidx.compose.ui.layout.LastBaseline to it.roundToInt() }).toMap()
            } else if (table.style?.isInline == true) {
                fun baseline(first: Boolean): Int? = children.indices.mapNotNull { index ->
                    val placed = grid.cells[index]
                    if (first && placed.row != 0) null else {
                        val value = children[index][if (first) androidx.compose.ui.layout.FirstBaseline else androidx.compose.ui.layout.LastBaseline]
                        value.takeUnless { it == androidx.compose.ui.layout.AlignmentLine.Unspecified }?.let { pixels.cellTop(placed.row) + it }
                    }
                }.maxOrNull()
                mapOf(androidx.compose.ui.layout.FirstBaseline to (baseline(true) ?: pixels.cellBottom(0, 1)),
                    androidx.compose.ui.layout.LastBaseline to (baseline(false) ?: pixels.height))
            } else emptyMap()
            layout(pixels.width, pixels.height, lines) {
                children.forEachIndexed { index, child ->
                    val placed = grid.cells[index]
                    child.place(pixels.physicalCellLeft(placed.column, placed.colspan, layoutDirection == LayoutDirection.Rtl),
                        pixels.cellTop(placed.row))
                }
            }
        }
        }
    })
}

/** Keep ordinary context em sizing; convert a capped result back through the
 * same density/font converter rather than treating 10000 pixels as 10000 sp.
 * All current StyledText callers supply Material typography with an sp size.
 */
internal fun renderedSpanFontSize(span: Span, contextSize: TextUnit, normalBodySize: TextUnit,
    density: Density, cssPixelTextZoom: Float = 1f): TextUnit {
    require(contextSize.isSp && normalBodySize.isSp)
    if (span.fontScaleBasis == FontScaleBasis.CssPx) {
        val nominal = cssPixelNominalFontSp(span, cssPixelTextZoom)
        val pixels = with(density) { nominal.sp.toPx() }
        require(!pixels.isNaN() && pixels >= 0f) { "Invalid native font conversion" }
        return with(density) { pixels.coerceAtMost(MaxComputedFontPixels).toSp() }
    }
    val contextPixels = with(density) { contextSize.toPx() }
    val bodyPixels = with(density) { normalBodySize.toPx() }
    val pixels = spanFontPixels(span, contextPixels, bodyPixels)
    if (span.fontScaleBasis == FontScaleBasis.NormalBody || pixels == MaxComputedFontPixels)
        return with(density) { pixels.toSp() }
    return spanFontScale(span).em
}

/** Use the same explicit ownership for inline controls and the media footer. */
internal fun inlineMediaFiles(entry: Entry): Set<String> = buildSet {
    val owners = MediaOwners(entry.media)
    fun include(spans: List<Span>, preserveWhitespace: Boolean = false) {
        val rendered = if (preserveWhitespace) spans else compactSpans(spans)
        rendered.forEach { it.image?.let { image -> add(image.file) } }
        owners.embedded(rendered.filter { it.image == null }).forEach { add(it.file) }
    }
    include(entry.displayTitle)
    include(entry.preamble)
    entry.readingRows.forEach { row ->
        row.headingBlock?.let { include(it.spans) }
        row.block?.let { block ->
            if (block.kind != "rule") block.visitSpanRuns { spans, literal -> include(spans, literal) }
        }
    }
    entry.references.forEach { reference -> reference.visitSpanRuns { spans, literal -> include(spans, literal) } }
}

@Composable
internal fun StyledText(source: List<Span>, modifier: Modifier = Modifier, weight: FontWeight? = null, style: TextStyle = inheritedContainerBodyStyle(), onLink: (EntryLink) -> Unit = {}, preserveWhitespace: Boolean = false) {
    val cellTextAlign = LocalCellTextAlign.current
    val lineHeightPixels = LocalTableLineHeightPixels.current
    val density = LocalDensity.current
    val inheritedStyle = inheritedCellTextStyle(style)
    val renderedStyle = if (lineHeightPixels == null) inheritedStyle else inheritedStyle.copy(lineHeight = with(density) { lineHeightPixels.toSp() })
    val spans = remember(source, preserveWhitespace) { if (preserveWhitespace) source else compactSpans(source) }
    val availableMedia = LocalEntryMedia.current
    val owners = LocalEntryMediaOwners.current
    val embedded = owners.embedded(spans.filter { it.image == null })
    if (embedded.isNotEmpty()) {
        Column(modifier) {
            // Captions are compiled spans; the media record contains only a plain summary.
            val text = remember(spans) { spans.map { if (it.hasClassToken("wikidict-media")) it.withoutClassToken("wikidict-media") else it } }
            StyledText(text, weight = weight, style = renderedStyle, onLink = onLink, preserveWhitespace = preserveWhitespace)
            embedded.forEach { MediaView(it, LocalReaderSettings.current, showFileName = false, edition=LocalEntryEdition.current, showCaption = false) }
        }
        return
    }
    val linkColor = MaterialTheme.colorScheme.primary
    val cache = LocalTextCache.current
    val currentLink = rememberUpdatedState(onLink)
    val inheritedBackground = LocalAuthoredBackground.current
    val annotated = styledTextAnnotation(spans, weight, renderedStyle, onLink)
    val egyptianRuns = remember(spans) { egyptianTextRuns(spans) }
    val containerFormat = inheritedContainerFormat()
    if (containerFormat != null) {
        val native = prepareNativeFloatText(spans, annotated, egyptianRuns,
            renderedStyle.copy(textDirection = TextDirection.Content, textAlign = cellTextAlign ?: style.textAlign),
            linkColor, availableMedia, LocalReaderSettings.current, LocalEntryEdition.current, onLink,
            nativeLineHeight = lineHeightPixels?.let { NativeLineHeightPolicy.Pixels(it) } ?: containerFormat.lineHeight)
        val nativeModifier = if (LocalNativePreformattedText.current) modifier.width(IntrinsicSize.Max) else modifier
        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(native, 0f)), nativeModifier, linkColor) { _, _ ->
            error("Native inline text has no delegated child")
        }
        return
    }
    val inlineContent = if (spans.any { it.image != null }) compiledInlineImageContent(spans, annotated, renderedStyle,
        availableMedia, LocalReaderSettings.current, LocalEntryEdition.current,
        { target -> (cache?.link?.value ?: currentLink.value)(target) },
        authoredSpanForegroundArgb(null, inheritedBackground)?.let { Color(it) } ?: MaterialTheme.colorScheme.onSurfaceVariant)
        else emptyMap()
    SelectionContainer(modifier = modifier.then(if (cellTextAlign == null) Modifier else Modifier.fillMaxWidth())) {
        EgyptianInlineText(annotated, egyptianRuns, Modifier.then(if (cellTextAlign == null) Modifier else Modifier.fillMaxWidth()),
            renderedStyle.copy(textDirection = TextDirection.Content, textAlign = cellTextAlign ?: style.textAlign), linkColor, inlineContent)
    }
}

@Composable
internal fun styledTextAnnotation(spans: List<Span>, weight: FontWeight?, style: TextStyle,
    onLink: (EntryLink) -> Unit): AnnotatedString {
    val effectiveWeight = weight ?: LocalCellWeight.current
    val normalBodySize = MaterialTheme.typography.bodyLarge.fontSize
    val contextSize = LocalTextStyle.current.merge(style).fontSize
    val textDensity = LocalDensity.current
    val linkColor = MaterialTheme.colorScheme.primary
    val codeColor = MaterialTheme.colorScheme.surfaceContainer
    val cache = LocalTextCache.current
    val currentLink = rememberUpdatedState(onLink)
    val layoutDirection = LocalLayoutDirection.current
    val inheritedBackground = LocalAuthoredBackground.current
    val inheritedForeground = LocalFigureCaptionForeground.current
    val cellLetterSpacing = LocalCellLetterSpacingPixels.current
    val cssPixelTextZoom = LocalCssPixelTextZoom.current
    val computedCellTraits = LocalNativeContainerTextContext.current?.cellText != null
    val bodyFamily = MaterialTheme.typography.bodyLarge.fontFamily ?: FontFamily.Default
    val cacheKey = TextCacheKey(effectiveWeight, layoutDirection, inheritedBackground, normalBodySize, contextSize, textDensity, inheritedForeground, cellLetterSpacing, cssPixelTextZoom, computedCellTraits, bodyFamily.takeIf { computedCellTraits })
    val annotated = remember(spans, effectiveWeight, linkColor, codeColor, cache, layoutDirection, inheritedBackground, normalBodySize, contextSize, textDensity, inheritedForeground, cellLetterSpacing, cssPixelTextZoom, computedCellTraits, bodyFamily) {
        cache?.values?.get(spans)?.get(cacheKey) ?: buildAnnotatedString {
            val appendedSpans = ArrayList<Pair<Span, IntRange>>(spans.size)
            spans.forEachIndexed { index, span ->
                val effectiveBackground = span.background ?: inheritedBackground.takeIf { !span.code }
                val foreground = (canonicalColorArgb(span.foreground)?.toInt() ?: inheritedForeground ?:
                    authoredSpanForegroundArgb(null, effectiveBackground)?.toInt())?.let { Color(it) }
                val background = canonicalColorArgb(span.background)?.let { Color(it) }
                val readableLinkFallback = canonicalColorArgb(span.foreground) == null && canonicalColorArgb(effectiveBackground) != null
                val linkStyle = TextLinkStyles(style = SpanStyle(color = foreground ?: linkColor,
                    textDecoration = if (readableLinkFallback) TextDecoration.Underline else null),
                    pressedStyle = SpanStyle(textDecoration = TextDecoration.Underline))
                val start = length
                when (span.direction) {
                    "rtl" -> append('\u2067')
                    "ltr" -> append('\u2066')
                    "auto" -> append('\u2068')
                }
                val displayText = if (span.image != null) InlineImageReplacement else if (span.kind == "line_break") "\n" else span.text
                val contentStart = length
                if (span.image != null) appendInlineContent("compiled-image-$index", InlineImageReplacement) else append(displayText)
                append(span.trail)
                if (span.direction in listOf("rtl", "ltr", "auto")) append('\u2069')
                val end = length
                appendedSpans.add(span to (start until end))
                if (end > start) {
                    val languageTag = spanLanguageTag(span.language)
                    val fontFamily = when {
                        span.code -> FontFamily.Monospace
                        span.classes.split(spanClassWhitespace).any { it == "Egyp" } -> EgyptianFontFamily
                        else -> if (computedCellTraits) bodyFamily else null
                    }
                    if (foreground != null || languageTag != null || fontFamily != null || effectiveWeight != null || span.bold || span.italic || span.code || span.small || span.superscript || span.subscript || span.strike || span.underline || span.fontScale != null || span.fontFeatures != null) addStyle(SpanStyle(
                        color = foreground ?: Color.Unspecified,
                        localeList = languageTag?.let { LocaleList(Locale(it)) },
                        fontWeight = if (span.bold) FontWeight.Bold else if (computedCellTraits) FontWeight.Normal else effectiveWeight,
                        fontStyle = if (span.italic) FontStyle.Italic else if (computedCellTraits) FontStyle.Normal else null,
                        fontFamily = fontFamily,
                        fontFeatureSettings = span.fontFeatures?.nativeSettings,
                        letterSpacing = cellLetterSpacing?.let { with(textDensity) { it.toSp() } }
                            ?: if (fontFamily == EgyptianFontFamily) 0.sp else TextUnit.Unspecified,
                        fontSize = renderedSpanFontSize(span, contextSize, normalBodySize, textDensity, cssPixelTextZoom),
                        baselineShift = when { span.superscript -> BaselineShift.Superscript; span.subscript -> BaselineShift.Subscript; else -> null },
                        background = if (background == null && span.code) codeColor else Color.Unspecified,
                        textDecoration = when {
                            span.strike && span.underline -> TextDecoration.combine(listOf(TextDecoration.LineThrough, TextDecoration.Underline))
                            span.strike -> TextDecoration.LineThrough
                            span.underline -> TextDecoration.Underline
                            else -> null
                        },
                    ), start, end)
                    if (background != null) {
                        // Authored paint covers text and trails, without filling line breaks.
                        var paintStart = start
                        for ((relative, character) in (displayText + span.trail).withIndex()) {
                            if (character == '\n') {
                                val offset = contentStart + relative
                                if (offset > paintStart) addStyle(SpanStyle(background = background), paintStart, offset)
                                paintStart = offset + 1
                            }
                        }
                        if (end > paintStart) addStyle(SpanStyle(background = background), paintStart, end)
                    }
                    if (span.image != null) Unit // The inline child owns this compiled action and its image semantics.
                    else if (span.hasInternalAction()) addLink(LinkAnnotation.Clickable(span.target, linkStyle) { (cache?.link?.value ?: currentLink.value)(span.entryLink()) }, start, end)
                    else {
                        val external = externalLinkUrl(span)
                        if (external != null) addLink(LinkAnnotation.Url(external, linkStyle), start, end)
                    }
                }
            }
            poemParagraphs(toAnnotatedString().text, appendedSpans).forEach { paragraph ->
                addStyle(ParagraphStyle(
                    textIndent = TextIndent(paragraph.indent.em, paragraph.indent.em),
                    textDirection = when (paragraph.direction) {
                        "ltr" -> TextDirection.Ltr
                        "rtl" -> TextDirection.Rtl
                        else -> if (layoutDirection == LayoutDirection.Rtl) TextDirection.Rtl else TextDirection.Ltr
                    }), paragraph.start, paragraph.end)
            }
        }.also { cache?.values?.getOrPut(spans) { mutableMapOf() }?.put(cacheKey, it) }
    }
    return annotated
}

private fun CellTextAlign.composeAlign(): androidx.compose.ui.text.style.TextAlign = when (this) {
    CellTextAlign.Left -> androidx.compose.ui.text.style.TextAlign.Left
    CellTextAlign.Center -> androidx.compose.ui.text.style.TextAlign.Center
    CellTextAlign.Right -> androidx.compose.ui.text.style.TextAlign.Right
}

internal fun figureInheritedAlign(align: TextAlign?, direction: LayoutDirection): CellTextAlign? = when (align) {
    null, TextAlign.Unspecified -> null
    TextAlign.Left -> CellTextAlign.Left
    TextAlign.Center -> CellTextAlign.Center
    TextAlign.Right -> CellTextAlign.Right
    TextAlign.Start -> if (direction == LayoutDirection.Ltr) CellTextAlign.Left else CellTextAlign.Right
    TextAlign.End -> if (direction == LayoutDirection.Ltr) CellTextAlign.Right else CellTextAlign.Left
    else -> throw UnsupportedFloatLayout("Anonymous flow requires a supported physical alignment")
}

private val LocalFloatTableWidthReference = staticCompositionLocalOf<NativeLayoutInput<Int>?> { null }
private val LocalFloatMarginsConsumed = staticCompositionLocalOf { false }

private fun nativeTableConsumesMargins(table: Table?): Boolean = table?.style?.let {
    !it.isInline && (it.marginValues != null || it.floatSide != null || it.clear != null && it.clear != FigureClear.None)
} == true

@Composable
private fun FloatBlockSequence(blocks: List<Block>, onLink: (EntryLink) -> Unit, path: String,
    modifier: Modifier = Modifier, inCell: Boolean = false, gridPath: String = "root", gapDp: Float,
    trailingGap: Boolean) {
    val delegatedSource = LocalNativeDelegatedCell.current?.sourceBlock
    if (blocks.needsNativeBlockSequence(delegatedSource)) {
        NativeFloatBlockContext(blocks, onLink, path, modifier, inCell, gridPath, gapDp, trailingGap)
    } else {
        val content: @Composable () -> Unit = {
            blocks.forEachIndexed { index, block ->
                val gap = if (trailingGap || index + 1 < blocks.size) gapDp else 0f
                BlockView(block, onLink, "$path/block-$index", inCell, "$gridPath/block-$index",
                    outsideGapDp = gap, previousBlock = blocks.getOrNull(index - 1))
            }
        }
        // A rich cell's width query must not ask nested grids for intrinsic heights:
        // their warning surface is subcomposed only during actual measurement.
        if (LocalTableContentWidths.current) TableContentColumn(modifier.fillMaxWidth(), 0.dp, content)
        else Column(modifier.fillMaxWidth()) { content() }
    }
}

@Composable
internal fun NativeFloatBlockContext(blocks: List<Block>, onLink: (EntryLink) -> Unit, path: String,
    modifier: Modifier, inCell: Boolean, gridPath: String, gapDp: Float, trailingGap: Boolean,
    containAtEnd: Boolean = true, blockPaths: List<String>? = null, gapsDp: List<Float>? = null,
    sectionRows: Map<Int, ReadingRow> = emptyMap(), sectionActions: Map<Int, List<NativeHeadingAction>> = emptyMap(),
    sectionKeys: List<String>? = null, documentSurface: Boolean = false,
    fixedHeightReachable: Boolean = false, positionedPaintRoot: Boolean = false) {
    val density = LocalDensity.current
    val contentWidths = LocalTableContentWidths.current
    val inheritedAlign = LocalCellTextAlign.current
    val inheritedLineHeight = LocalTableLineHeightPixels.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val inheritedContainer = inheritedContainerFormat()
    val baseStyle = inheritedCellTextStyle(inheritedContainer?.style ?: MaterialTheme.typography.bodyLarge).let { style ->
        if (inheritedLineHeight == null) style else style.copy(lineHeight = with(density) { inheritedLineHeight.toSp() })
    }
    val fontPixels = with(density) { baseStyle.fontSize.toPx() }
    val windowHeight = LocalWindowInfo.current.containerSize.height.takeIf { it > 0 }
    val linkColor = MaterialTheme.colorScheme.primary
    val media = LocalEntryMedia.current
    val mediaOwners = LocalEntryMediaOwners.current
    val settings = LocalReaderSettings.current
    val edition = LocalEntryEdition.current
    val normalBodySize = MaterialTheme.typography.bodyLarge.fontSize
    val normalBodyPixels = with(density) { normalBodySize.toPx() }
    val rootLineHeight = when {
        baseStyle.lineHeight.isSp -> ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px,
            baseStyle.lineHeight.value * density.fontScale))
        baseStyle.lineHeight.isEm -> ContainerLineHeight.Multiplier(baseStyle.lineHeight.value)
        else -> ContainerLineHeight.Normal
    }
    val rootContext = LocalNativeContainerTextContext.current?.let { context ->
        if (inheritedLineHeight == null) context else context.copy(lineHeight = rootLineHeight,
            cellText = context.cellText?.copy(lineHeight = NativeLineHeightPolicy.Pixels(inheritedLineHeight)))
    } ?: ContainerTextContext(if (normalBodySize.value == 0f) 1f else
        baseStyle.fontSize.value / normalBodySize.value, rootLineHeight)
    val sourceIds = remember { linkedMapOf<String, Int>() }
    fun sourceId(key: String): Int = sourceIds.getOrPut(key) { sourceIds.size }
    val mediaControls = mutableMapOf<Int, List<Media>>()
    val mediaLeaves = mutableMapOf<Int, NativeContainerLeaf>()
    val originalChildren = mutableMapOf<Int, NativeContainerLeaf>()
    val leafBoxes = mutableMapOf<Int, ParagraphBox?>()
    val gaps = blocks.indices.map { index ->
        if (trailingGap || index + 1 < blocks.size) (gapsDp?.get(index) ?: gapDp) * density.density else 0f
    }
    val parts = prepareNativeContainerTree(blocks, path, gridPath, blockPaths, gaps, rootContext,
        baseStyle, figureInheritedAlign(inheritedAlign, LocalLayoutDirection.current), normalBodySize,
        density, LocalWindowInfo.current.containerSize.width.toDouble() / density.density,
        rtl, LocalReaderDarkTheme.current, documentSurface || fixedHeightReachable, ::sourceId,
        positionedPaintReachable = positionedPaintRoot) { leaf ->
        val block = leaf.block
        val index = leaf.id
        val gap = leaf.gap
        val previous = leaf.previous?.takeIf {
            leaf.rootIndex == null || sectionKeys == null || leaf.rootIndex == 0 ||
                sectionKeys[leaf.rootIndex] == sectionKeys[leaf.rootIndex - 1]
        }
        var paragraphFailure: String? = null
        val box = try {
            paragraphBox(block, previous, gap, density.density,
                if (leaf.inContainer) normalBodyPixels else fontPixels)
        } catch (error: UnsupportedFloatLayout) {
            paragraphFailure = error.message ?: "Paragraph layout unavailable at this size"
            null
        }
        leafBoxes[index] = box
        val heading = block.kind == "heading"
        val format = leaf.format ?: inheritedContainer
        val actions = leaf.rootIndex?.let { sectionActions[it] }.orEmpty()
        val typography = if (heading) {
            if (leaf.rootIndex?.let { sectionRows[it]?.meaningSection } == true) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium
        } else format?.style ?: baseStyle
        val style = inheritedCellTextStyle(typography).copy(textAlign = block.textAlign?.composeAlign() ?: leaf.align?.composeAlign() ?: inheritedAlign ?: androidx.compose.ui.text.style.TextAlign.Unspecified)
        val nativeTextKinds = setOf("paragraph", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "heading")
        val rendered = if (block.figure != null || block.flow != null) {
            val prefix = blockPrefix(block)
            listOf(NativeFloatContextSpec.Flow(index, box?.after ?: gap, leaf.path,
                box, !paragraphHasContent(block) && prefix.isEmpty()) { carried, published ->
                AnonymousBlockView(block, Modifier, onLink, media, settings, edition,
                    inheritedAlign = figureInheritedAlign(style.textAlign, LocalLayoutDirection.current), style = style, interactionOwner = false,
                    carriedExclusions = carried, onFlowGeometry = published,
                    prefix = prefix, indentPixels = blockIndentDp(block) * density.density,
                    nativeLineHeight = format?.lineHeight)
            })
        } else if (block.kind in nativeTextKinds && block.table == null && block.feature == null) {
            val displayed = paragraphDisplaySpans(block)
            val embedded = mediaOwners.embedded(displayed.filter { it.image == null })
            // StyledText already separates these controls. Keep its text in the shared float owner.
            val spans = if (embedded.isEmpty()) displayed else displayed.map {
                if (it.hasClassToken("wikidict-media")) it.withoutClassToken("wikidict-media") else it
            }
            val annotated = styledTextAnnotation(spans, if (block.kind == "term") FontWeight.Bold else null, style, onLink)
            val prefixStyle = MaterialTheme.typography.labelMedium.copy(color =
                authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)?.let { Color(it) } ?: MaterialTheme.colorScheme.primary)
            val text = NativeFloatContextSpec.Text(prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), style, linkColor,
                media, settings, edition, onLink, indentPixels = blockIndentDp(block) * density.density,
                prefix = blockPrefix(block), prefixStyle = prefixStyle, heading = heading, headingActions = actions,
                nativeLineHeight = format?.lineHeight),
                if (embedded.isEmpty()) box?.after ?: gap else 0f,
                leaf.path,
                if (embedded.isEmpty()) box else box?.copy(padding = box.padding.copy(bottom = 0f)))
            if (embedded.isEmpty()) listOf(text) else {
                val id = sourceId(leaf.path + "/media")
                mediaLeaves[id] = leaf
                mediaControls[id] = embedded
                listOf(text, NativeFloatContextSpec.Child(id, { it },
                    (box?.padding?.bottom ?: 0f) + (box?.after ?: gap), logicalObject = false))
            }
        } else {
            originalChildren[index] = leaf
            val table = block.table
            val side = table?.style?.floatSide
            val externalMargins = nativeTableConsumesMargins(table)
            val automaticMargins = table?.style?.marginValues?.let {
                resolveTableAutoMargins(it, density.density, normalBodyPixels)
            }
            val automaticTable = table?.takeIf { it.style?.marginValues != null &&
                it.style.floatSide == null && !it.style.isInline && block.feature == null }
            fun natural(originalWidth: Int): TableRenderMetrics? = table?.let {
                tableRenderMetrics(it, with(density) { 136.dp.roundToPx() }, with(density) { 10.dp.roundToPx() },
                    with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = fontPixels,
                    decorationViewportWidth = originalWidth, decorationViewportHeight = windowHeight, rtl = rtl)
            }
            listOf(NativeFloatContextSpec.Child(index, { originalWidth ->
                if (table == null || block.feature != null || table.style?.isInline == true) originalWidth else {
                    val metrics = natural(originalWidth)?.let { tableMetricsInWidth(table, it, tableGrid(table).columns, originalWidth) }
                    val margins = if (!externalMargins) metrics?.style?.margins?.horizontal ?: 0 else 0
                    val markerWidth = if (block.kind == "list_item") with(density) { 28.dp.roundToPx() } else 0
                    val width = metrics?.let { it.width.toLong() + margins + markerWidth + (blockIndentDp(block) * density.density).toInt() }
                        ?: originalWidth.toLong()
                    width.coerceIn(0L, if (leaf.inScrollport) TablePixelLimit.toLong() else originalWidth.toLong()).toInt()
                }
            }, if (side == null) box?.after ?: gap else 0f, side, { originalWidth ->
                val edges = if (!externalMargins) null else natural(originalWidth)?.style?.margins
                if (externalMargins && automaticMargins != null) automaticMargins.fixed
                else FloatMargins(edges?.top?.toFloat() ?: 0f, edges?.right?.toFloat() ?: 0f,
                    edges?.bottom?.toFloat() ?: 0f, edges?.left?.toFloat() ?: 0f)
            }, requiresUnobstructedText = table == null, gapBefore = box?.before ?: 0f, clear = table?.style?.clear.takeUnless { table?.style?.isInline == true },
                atomicInline = table?.style?.isInline == true,
                widthFromContent = table != null && block.feature == null &&
                    (table.style?.marginValues != null || tableUsesContentWidths(table, leaf.inScrollport || contentWidths)),
                preferredWidth = { originalWidth ->
                    val css = table?.style?.width
                    val legacy = table?.geometry?.width.takeIf { css == null }
                    val value = when {
                        css?.unit == StyleWidthUnit.Px -> css.value.toDouble() * density.density
                        css?.unit == StyleWidthUnit.Em -> css.value.toDouble() * fontPixels
                        css?.unit == StyleWidthUnit.Percent -> css.value.toDouble() * originalWidth / 100.0
                        legacy?.unit == TableWidthUnit.Px -> legacy.value.toDouble() * density.density
                        legacy?.unit == TableWidthUnit.Percent -> legacy.value.toDouble() * originalWidth / 100.0
                        else -> null
                    }
                    if (value != null && (!value.isFinite() || value !in 0.0..TablePixelLimit.toDouble()))
                        throw UnsupportedFloatLayout("Authored child width exceeds the native range")
                    value?.let { kotlin.math.round(it).toInt() }
                }, overflowViewport = table != null && !inCell && !leaf.inScrollport,
                delegatedTable = table?.takeIf { block.feature == null && !inCell && !leaf.inScrollport && nativeDelegatedFigureTable(it) },
                autoMarginTable = automaticTable, autoMargins = automaticMargins.takeIf { automaticTable != null }))
        }
        if (paragraphFailure == null) rendered else listOf(NativeFloatContextSpec.Container(
            sourceId(leaf.path + "/unavailable"), contentWidth = { width, _ -> width },
            intrinsicWidth = { width, _ -> width }, preparedParts = rendered,
            unavailableReason = paragraphFailure, content = {}))
    }
    val request = LocalCellHeadingRequest.current
    val reached = LocalCellHeadingReached.current
    fun flattened(items: List<NativeFloatContextSpec>): List<NativeFloatContextSpec> = items.flatMap { item ->
        (item as? NativeFloatContextSpec.Container)?.preparedParts?.let(::flattened) ?: listOf(item)
    }
    val revealIndex = flattened(parts).indexOfFirst { when (it) {
        is NativeFloatContextSpec.Text -> it.path == request?.path
        is NativeFloatContextSpec.Flow -> it.path == request?.path
        else -> false
    } }.takeIf { request != null && it >= 0 }
    @Composable fun originalChild(id: Int, originalWidth: NativeLayoutInput<Int>) {
        val leaf = originalChildren.getValue(id)
        CompositionLocalProvider(LocalFloatTableWidthReference provides originalWidth,
            LocalFloatMarginsConsumed provides nativeTableConsumesMargins(leaf.block.table),
            LocalNativeContainerTextContext provides (leaf.context ?: LocalNativeContainerTextContext.current),
            LocalCellTextAlign provides (leaf.block.textAlign?.composeAlign() ?: leaf.align?.composeAlign() ?: inheritedAlign)) {
            BlockView(leaf.block, onLink, leaf.path, inCell, leaf.gridPath)
        }
    }
    NativeFloatContextLayout(parts, modifier, linkColor, containAtEnd, revealIndex, request,
        { if (request != null) reached(request) }, adjoining = parts.any { it is NativeFloatContextSpec.Container },
        documentSurface = documentSurface,
        delegatedSourceRevision = listOf(blocks, rootContext, baseStyle, settings, edition, media,
            LocalMissingLinkOwner.current, containAtEnd, documentSurface, fixedHeightReachable, positionedPaintRoot)) { id, originalWidth ->
        val controls = mediaControls[id]
        if (controls == null) originalChild(id, originalWidth) else {
            val leaf = mediaLeaves.getValue(id)
            val box = leafBoxes[leaf.id]
            val indent = (blockIndentDp(leaf.block) + if (blockPrefix(leaf.block).isEmpty()) 0f else 28f) * density.density
            val left = (box?.contentLeft ?: 0f) + if (rtl) 0f else indent
            val right = (box?.contentRight ?: 0f) + if (rtl) indent else 0f
            Column(Modifier.fillMaxWidth().absolutePadding(left = with(density) { left.toDp() }, right = with(density) { right.toDp() })) {
                controls.forEach { MediaView(it, settings, showFileName = false, edition = edition, showCaption = false) }
            }
        }
    }
}

/** Rich figure captions use the existing grid paint/measure route, publishing cell geometry once. */
@Composable
internal fun FigureCaptionTable(table: Table, context: AnonymousFlowContext, style: TextStyle,
    reader: FigureReaderContext, sink: SelectionGeometrySink) {
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val lineHeightPixels = tableLineHeightPixels(table, style)
    if (lineHeightPixels != null && (!lineHeightPixels.isFinite() || lineHeightPixels <= 0f || lineHeightPixels > TablePixelLimit)) {
        UnavailableSelectionContent("Caption table line height is too large", sink)
        return
    }
    if (table.style?.floatSide != null) {
        UnavailableSelectionContent("Nested floated caption table needs a shared exclusion owner", sink)
        return
    }
    val inheritedStyle = inheritedCellTextStyle(style)
    val tableStyle = if (lineHeightPixels == null) inheritedStyle else inheritedStyle.copy(lineHeight = with(density) { lineHeightPixels.toSp() })
    val inheritedCellContext = LocalNativeContainerTextContext.current
    val tableCellContext = if (lineHeightPixels == null) inheritedCellContext else inheritedCellContext?.let {
        it.copy(cellText = it.cellText?.copy(lineHeight = NativeLineHeightPolicy.Pixels(lineHeightPixels)))
    }
    val grid = remember(table) { tableGrid(table) }
    val cells = grid.cells.map { placed -> CaptionCellSlot { cellSink ->
        val childContext = context.copy(textAlign = placed.cell.style?.textAlign ?: context.textAlign)
        val cellFormat = LocalNativeContainerTextContext.current?.takeIf { it.cellText != null }?.let {
            nativeContainerTextFormat(it, MaterialTheme.typography.bodyLarge.fontSize,
                tableStyle.copy(fontWeight = LocalCellWeight.current ?: tableStyle.fontWeight), density)
        }
        val weightedStyle = cellFormat?.style ?: if (placed.cell.header) tableStyle.copy(fontWeight = FontWeight.SemiBold) else tableStyle
        val childStyle = placed.cell.style?.letterSpacing?.let {
            weightedStyle.copy(letterSpacing = with(density) { exactCellStylePixels(it, density.density, bodyPixels).toSp() })
        } ?: weightedStyle
        when {
            placed.cell.blocks != null -> FigureCaptionBlocks(placed.cell.blocks, childContext, childStyle, reader, cellSink, gapDp = 4f)
            placed.cell.nestedTable != null -> FigureCaptionTable(placed.cell.nestedTable, childContext, childStyle, reader, cellSink)
            cellFormat != null && placed.cell.spans.isEmpty() -> SelectionEmptyBox(sink = cellSink)
            else -> AnonymousBlockView(Block("paragraph", 0, compactSpans(placed.cell.spans)), Modifier,
                reader.onLink, reader.media, reader.settings, reader.edition, inherited = childContext,
                style = childStyle, onGeometry = cellSink, interactionOwner = false, nativeLineHeight = cellFormat?.lineHeight)
        }
    } }
    val contentWidths = LocalTableContentWidths.current || tableHasComputedCellStyle(table) || table.style?.marginValues != null
    val rtl = context.direction == BidiResolvedDirection.Rtl
    val natural = remember(table, contentWidths, density.density, bodyPixels, rtl) {
            tableRenderMetrics(table, if (contentWidths) 1 else with(density) { 136.dp.roundToPx() }, with(density) { 10.dp.roundToPx() },
                with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = bodyPixels,
                rtl = rtl)
    }
    CompositionLocalProvider(LocalTableContentWidths provides contentWidths,
        LocalNativeContainerTextContext provides tableCellContext,
        LocalTableLineHeightPixels provides lineHeightPixels.takeIf { tableCellContext?.cellText == null }) {
        val marginValues = table.style?.marginValues
        if (marginValues != null) {
            val resolved = remember(marginValues, density.density, bodyPixels) {
                runCatching { resolveTableAutoMargins(marginValues, density.density, bodyPixels) }
            }
            val caption: (@Composable (SelectionGeometrySink) -> Unit)? =
                if (table.captionBlocks?.isNotEmpty() == true || table.caption.isNotEmpty()) ({ captionSink ->
                    if (table.captionBlocks != null) FigureCaptionBlocks(table.captionBlocks, context, tableStyle, reader, captionSink)
                    else AnonymousBlockView(Block("paragraph", 0, table.caption), Modifier, reader.onLink,
                        reader.media, reader.settings, reader.edition, inherited = context, style = tableStyle,
                        onGeometry = captionSink, interactionOwner = false,
                        nativeLineHeight = tableCellContext?.takeIf { it.cellText != null }?.let {
                            nativeContainerTextFormat(it, MaterialTheme.typography.bodyLarge.fontSize, tableStyle, density).lineHeight
                        })
                }) else null
            CompositionLocalProvider(LocalLayoutDirection provides if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                SelectionAutoMarginTable(resolved.getOrNull(), table.style?.containingDirection, context.direction,
                    table.style?.isInline == true, with(density) { 6.dp.roundToPx() }, sink,
                    preparationFailure = resolved.exceptionOrNull()?.message, caption = caption) { available, captionMinimum, tableSink ->
                    CompositionLocalProvider(LocalFloatTableWidthReference provides available) {
                        TableGridView(table, reader.onLink, "figure-caption", null, "", natural, 1.0,
                            { }, selectionCells = cells, selectionGeometry = tableSink, containerStyle = tableStyle,
                            contentWidths = true, captionMinimumWidth = captionMinimum)
                    }
                }
            }
        } else {
        val margin = natural?.style?.margins
        SelectionInsetsBox(margin?.left ?: 0, margin?.top ?: 0, margin?.right ?: 0, margin?.bottom ?: 0,
            context.direction, sink) { insideSink ->
            val parts = mutableListOf<@Composable (SelectionGeometrySink) -> Unit>()
            if (table.captionBlocks?.isNotEmpty() == true || table.caption.isNotEmpty()) parts += { captionSink ->
                SelectionInsetsBox(0, 0, 0, with(density) { 6.dp.roundToPx() }, context.direction, captionSink) { textSink ->
                    if (table.captionBlocks != null) FigureCaptionBlocks(table.captionBlocks, context, tableStyle, reader, textSink)
                    else AnonymousBlockView(Block("paragraph", 0, table.caption), Modifier, reader.onLink,
                        reader.media, reader.settings, reader.edition, inherited = context, style = tableStyle,
                        onGeometry = textSink, interactionOwner = false,
                        nativeLineHeight = tableCellContext?.takeIf { it.cellText != null }?.let {
                            nativeContainerTextFormat(it, MaterialTheme.typography.bodyLarge.fontSize, tableStyle, density).lineHeight
                        })
                }
            }
            parts += { gridSink ->
                SelectionGridBox(context.direction, gridSink) { available, tableSink ->
                    CompositionLocalProvider(LocalFloatTableWidthReference provides available) {
                        TableGridView(table, reader.onLink, "figure-caption", null, "", natural, 1.0,
                            { }, selectionCells = cells, selectionGeometry = tableSink, containerStyle = tableStyle,
                            contentWidths = contentWidths)
                    }
                }
            }
            SelectionColumn(parts, context.direction, insideSink)
        }
        }
    }
}
