package app.smallthingz.dict

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
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em

private val EgyptianFontFamily = FontFamily(Font(R.font.egyptian_hieroglyphs))
private val spanClassWhitespace = Regex("\\s+")

private data class TextCacheKey(val weight: FontWeight?, val direction: LayoutDirection,
    val background: String?, val normalBodySize: TextUnit, val contextSize: TextUnit, val density: Density)
private class TextCache(val link: State<(EntryLink) -> Unit>) {
    val values = java.util.IdentityHashMap<List<Span>, MutableMap<TextCacheKey, AnnotatedString>>()
}
private val LocalEntryMedia = staticCompositionLocalOf<List<Media>> { emptyList() }
private val LocalEntryMediaOwners = staticCompositionLocalOf { MediaOwners(emptyList()) }
private val LocalEntryEdition = staticCompositionLocalOf { "" }
private val LocalReaderSettings = staticCompositionLocalOf { AppSettings() }
private val LocalTextCache = staticCompositionLocalOf<TextCache?> { null }
internal val LocalAuthoredBackground = staticCompositionLocalOf<String?> { null }
private val LocalCellWeight = staticCompositionLocalOf<FontWeight?> { null }
private val LocalCellTextAlign = staticCompositionLocalOf<androidx.compose.ui.text.style.TextAlign?> { null }
private class CellHeadingRequest(val path: String)
private val LocalCellHeadingRequest = staticCompositionLocalOf<CellHeadingRequest?> { null }
private val LocalCellHeadingReached = staticCompositionLocalOf<(CellHeadingRequest) -> Unit> { {} }

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
    CompositionLocalProvider(LocalEntryMedia provides entry.media, LocalEntryMediaOwners provides mediaOwners,
        LocalEntryEdition provides entry.edition, LocalReaderSettings provides settings) {
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
        val imageOwner = if (typedImages.isEmpty()) null else rememberInlineImageViewOwner(typedImages, entry.media, settings, entry.edition, entry.legacyImageFiles)
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
                    if (entry.abbreviations.isNotEmpty()) {
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
            if (folded["abbreviations"] == false) items(entry.abbreviations.indices.toList(),
                key = { "abbreviation-$it" },
                contentType = { "abbreviation" }) { index ->
                val abbreviation = entry.abbreviations[index]
                Column(Modifier.padding(bottom = 8.dp)) {
                    Text(abbreviation.label, style = MaterialTheme.typography.labelLarge)
                    Text(abbreviation.explanation, style = MaterialTheme.typography.bodyMedium)
                    if (index == 0 || entry.abbreviations[index - 1].context != abbreviation.context) {
                        Text(abbreviation.context, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (entry.preamble.isNotEmpty()) item("preamble", contentType = "paragraph") {
                FoldHeading("About this entry", folded["preamble"] == true) { folded["preamble"] = folded["preamble"] != true }
                if (folded["preamble"] != true) StyledText(compactSpans(entry.preamble), Modifier.padding(bottom = 4.dp), onLink = readerLink)
            }
            itemsIndexed(visibleRows, key = { _, row -> row.key }, contentType = { _, row -> if (row.heading != null) "heading" else row.block?.kind }) { rowIndex, row ->
                Column(Modifier.animateItem()) {
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
                                sectionRows = sectionRows, sectionActions = actions)
                        }
                        rowIndex !in floatCovered -> Box(Modifier.padding(bottom = if (row.compact) 2.dp else 6.dp)) {
                            BlockView(block, readerLink, path = row.key)
                        }
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
private fun BlockView(block: Block, onLink: (EntryLink) -> Unit, path: String? = null, inCell: Boolean = false, gridPath: String = "root") {
    CompositionLocalProvider(LocalCellTextAlign provides (block.textAlign?.composeAlign() ?: LocalCellTextAlign.current)) {
        BlockContent(block, onLink, path, inCell, gridPath)
    }
}

@Composable
private fun BlockContent(block: Block, onLink: (EntryLink) -> Unit, path: String?, inCell: Boolean, gridPath: String) {
    when {
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
        block.kind == "preformatted" && block.textAlign != null -> BoxWithConstraints(
            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer)) {
            val viewport = maxWidth
            Box(Modifier.horizontalScroll(rememberScrollState()).widthIn(min = viewport).padding(12.dp), propagateMinConstraints = true) {
                CompositionLocalProvider(LocalAuthoredBackground provides null) {
                    StyledText(block.spans, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        onLink = onLink, preserveWhitespace = true)
                }
            }
        }
        block.kind == "preformatted" -> Box(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).horizontalScroll(rememberScrollState()).padding(12.dp)) {
            CompositionLocalProvider(LocalAuthoredBackground provides null) {
                StyledText(block.spans, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace), onLink = onLink, preserveWhitespace = true)
            }
        }
        else -> {
            val prefix = blockPrefix(block)
            Row(Modifier.padding(start = blockIndentDp(block).dp)) {
                if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp), color = canonicalColorArgb(LocalAuthoredBackground.current)?.let { Color(authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)!!) } ?: MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                StyledText(ordinaryInlineDisplaySpans(block), Modifier.weight(1f), weight = if (block.kind == "term") FontWeight.Bold else null, onLink = onLink)
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
private fun TableView(table: Table, onLink: (EntryLink) -> Unit, path: String = "root", nested: Boolean = false, semanticPath: String = "") {
  if (table.style?.floatSide != null && !LocalFloatMarginsConsumed.current) {
      NativeFloatBlockContext(listOf(Block(kind = "table", depth = 0, spans = emptyList(), table = table)),
          onLink, semanticPath, Modifier, nested, path, 0f, false)
      return
  }
  val phaseObserver = LocalTablePhaseObserver.current
  val window = LocalWindowInfo.current.containerSize
  BoxWithConstraints(Modifier.fillMaxWidth()) {
    val decorationWidth = LocalFloatTableWidthReference.current ?: listOfNotNull(constraints.maxWidth.takeIf { constraints.hasBoundedWidth }, window.width.takeIf { it > 0 }).minOrNull()
    val decorationHeight = listOfNotNull(constraints.maxHeight.takeIf { constraints.hasBoundedHeight }, window.height.takeIf { it > 0 }).minOrNull()
    val density = LocalDensity.current
    val fontPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    var decorationProjection by remember(table, density.density, fontPixels, decorationWidth, decorationHeight) { mutableDoubleStateOf(1.0) }
    val natural = remember(table, density.density, fontPixels, decorationProjection, decorationWidth, decorationHeight, phaseObserver) {
      observeTablePhase(phaseObserver, TablePhase.Preparation) {
        tableRenderMetrics(table, with(density) { 136.dp.roundToPx() }, with(density) { 10.dp.roundToPx() },
            with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = fontPixels,
            decorationScale = decorationProjection, decorationViewportWidth = decorationWidth,
            decorationViewportHeight = decorationHeight)
      }
    }
    val margin = natural?.style?.margins.takeUnless { LocalFloatMarginsConsumed.current }
    val marginModifier = if (margin == null) Modifier else with(density) {
        Modifier.absolutePadding(left = margin.left.toDp(), top = margin.top.toDp(),
            right = margin.right.toDp(), bottom = margin.bottom.toDp())
    }
    Column(Modifier.fillMaxWidth().then(marginModifier), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (table.caption.isNotEmpty()) StyledText(table.caption, onLink = onLink)
        if (nested) BoxWithConstraints(Modifier.fillMaxWidth()) {
            TableGridView(table, onLink, path, constraints.maxWidth.takeIf { constraints.hasBoundedWidth }, semanticPath,
                natural, decorationProjection, { decorationProjection = 0.0 })
        } else BoxWithConstraints(Modifier.fillMaxWidth()) {
            val viewportWidth = constraints.maxWidth.takeIf { constraints.hasBoundedWidth }
            // A child grid belongs to the same scroll surface as its outer table.
            Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
                TableGridView(table, onLink, path, viewportWidth, semanticPath,
                    natural, decorationProjection, { decorationProjection = 0.0 })
            }
        }
    }
  }
}

@Composable
private fun TableGridView(table: Table, onLink: (EntryLink) -> Unit, path: String, widthReference: Int?, semanticPath: String,
    natural: TableRenderMetrics?, decorationProjection: Double, removeDecorations: () -> Unit) {
    val resolvedWidthReference = LocalFloatTableWidthReference.current ?: widthReference
    val phaseObserver = LocalTablePhaseObserver.current
    val grid = remember(table, phaseObserver) { observeTablePhase(phaseObserver, TablePhase.Preparation) { tableGrid(table) } }
    val density = LocalDensity.current
    val inheritedBackground = LocalAuthoredBackground.current
    val inheritedColor = canonicalColorArgb(inheritedBackground)?.let { Color(it) }
    val fontPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val authoredColors = remember(table) { grid.cells.map { placed ->
        canonicalColorArgb(placed.cell.background)?.let { androidx.compose.ui.graphics.Color(it) }
    } }
    var unavailable by remember(table, density.density, density.fontScale, fontPixels, resolvedWidthReference, decorationProjection, natural) { mutableStateOf(false) }
    var drawingPixels by remember(table, density.density, density.fontScale, fontPixels, resolvedWidthReference, decorationProjection, natural) { mutableStateOf<TablePixelLayout?>(null) }
    val headerColor = MaterialTheme.colorScheme.surfaceContainerHigh
    val cellColor = MaterialTheme.colorScheme.surface
    val borderColor = MaterialTheme.colorScheme.outline
    if (natural == null && decorationProjection > 0.0 && tableContainsStyle(table)) {
        LaunchedEffect(table, decorationProjection) { removeDecorations() }
        return
    }
    if (unavailable || natural == null) {
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
    Layout(modifier = Modifier.testTag(if (path == "root") "compiled-table-grid" else "compiled-table-grid-$path")
        .semantics { collectionInfo = androidx.compose.ui.semantics.CollectionInfo(grid.rows, grid.columns) }
        .drawWithCache {
            // Measurement publishes paint geometry. Observe it in the draw cache,
            // not composition: opening a large table must not schedule a second
            // composition merely to calculate its collapsed border segments.
            val pixels = drawingPixels
            val collapsedBorders = observeTablePhase(phaseObserver, TablePhase.DrawCache) {
                if (pixels != null && styled?.collapse == true)
                    collapsedTableBorders(grid, pixels, styled) else emptyList()
            }
            onDrawBehind {
            observeTablePhase(phaseObserver, TablePhase.Draw) {
            if (pixels != null) {
            val tableBackground = styled?.background?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } }
            tableBackground?.let { drawRect(it) }
            grid.cells.forEachIndexed { index, placed ->
                val cellWidth = pixels.cellWidth(placed.colspan, placed.column)
                val left = if (layoutDirection == androidx.compose.ui.unit.LayoutDirection.Ltr)
                    pixels.cellLeft(placed.column)
                else pixels.width - pixels.cellLeft(placed.column) - cellWidth
                val top = pixels.cellTop(placed.row)
                val bottom = pixels.cellBottom(placed.row, placed.cell.rowspan)
                drawRect(authoredColors[index] ?: tableBackground ?: inheritedColor ?: if (placed.cell.header) headerColor else cellColor,
                    topLeft = Offset(left.toFloat(), top.toFloat()), size = Size(cellWidth.toFloat(), (bottom - top).toFloat()))
                val cellBorder = styled?.cellBorders?.get(index)
                val strokeWidth = cellBorder?.width ?: pixels.borderWidth.toFloat()
                if (styled?.collapse != true && strokeWidth > 0f) {
                    val inset = strokeWidth / 2f
                    val color = cellBorder?.color?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } } ?: borderColor
                    drawRect(color, Offset(left + inset, top + inset),
                        Size((cellWidth - strokeWidth).coerceAtLeast(0f), (bottom - top - strokeWidth).coerceAtLeast(0f)),
                        style = androidx.compose.ui.graphics.drawscope.Stroke(strokeWidth))
                }
            }
            if (styled?.collapse == true) collapsedBorders.forEach { edge ->
                fun x(value: Float) = if (layoutDirection == androidx.compose.ui.unit.LayoutDirection.Rtl) pixels.width - value else value
                val color = edge.color?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } } ?: borderColor
                drawLine(color, Offset(x(edge.x1), edge.y1), Offset(x(edge.x2), edge.y2), edge.width)
            } else {
                val strokeWidth = styled?.border?.width ?: pixels.borderWidth.toFloat()
                if (strokeWidth > 0f && pixels.width > 0 && pixels.height > 0) {
                    val inset = strokeWidth / 2f
                    val color = styled?.border?.color?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } } ?: borderColor
                    drawRect(color, Offset(inset, inset),
                        Size((pixels.width - strokeWidth).coerceAtLeast(0f), (pixels.height - strokeWidth).coerceAtLeast(0f)),
                        style = androidx.compose.ui.graphics.drawscope.Stroke(strokeWidth))
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
            Box(Modifier.testTag("compiled-table-cell-$path-$index").semantics {
                collectionItemInfo = androidx.compose.ui.semantics.CollectionItemInfo(
                    placed.row, placed.cell.rowspan, placed.column, placed.colspan)
                if (placed.cell.header) heading()
            }.then(padding)) {
                CompositionLocalProvider(LocalFloatTableWidthReference provides null, LocalFloatMarginsConsumed provides false, LocalAuthoredBackground provides (placed.cell.background ?: styled?.background ?: inheritedBackground),
                    LocalCellTextAlign provides textAlign,
                    LocalCellWeight provides (if (placed.cell.header) FontWeight.SemiBold else LocalCellWeight.current)) {
                    val cellPath = "$semanticPath/cell-$index"
                    val blocks = placed.cell.blocks
                    if (blocks != null) FloatBlockSequence(blocks, onLink, cellPath, inCell = true,
                        gridPath = "$path/$index", gapDp = 4f, trailingGap = false)
                    else {
                        val child = placed.cell.nestedTable
                        if (child == null) StyledText(placed.cell.spans, onLink = onLink)
                        else TableView(child, onLink, "$path/$index", nested = true, semanticPath = "$cellPath/nested")
                    }
                }
            }
        }
        }
    }) { measurables, incoming ->
        val reference = resolvedWidthReference ?: incoming.maxWidth.takeIf { incoming.hasBoundedWidth }
        val metrics = tableMetricsInWidth(table, natural, grid.columns, reference)
        val heightLimit = metrics?.let { tableHeightLimit(it.width) }
        // One measure per cell. Native Egyptian descendants do not support intrinsic queries.
        val children = if (metrics == null || heightLimit == null) emptyList() else
          observeTablePhase(phaseObserver, TablePhase.Measurement, measurables.size) {
          measurables.mapIndexed { index, measurable ->
            val placed = grid.cells[index]
            val width = metrics.cellWidth(placed.column, placed.colspan)
            measurable.measure(Constraints(minWidth = width, maxWidth = width, minHeight = 0, maxHeight = heightLimit))
        }
        }
        val pixels = observeTablePhase(phaseObserver, TablePhase.PixelLayout, children.size) {
          if (metrics == null || heightLimit == null) null else tablePixelLayout(grid, metrics.columnWidth,
            metrics.minRowHeight, IntArray(children.size) { children[it].height }, metrics.cellSpacing, metrics.borderWidth,
            metrics.width, metrics.extraColumns)
        }
        if (pixels == null) {
            drawingPixels = null
            // A decoration estimate cannot know the measured height of real body
            // text/media. Retry the same cells without decoration before using
            // the pre-existing body-size unavailable path.
            if (decorationProjection > 0.0 && tableContainsStyle(table)) removeDecorations()
            else unavailable = true
            layout(0, 0) {}
        } else {
            drawingPixels = pixels
            layout(pixels.width, pixels.height) {
                children.forEachIndexed { index, child ->
                    val placed = grid.cells[index]
                    child.placeRelative(pixels.cellLeft(placed.column), pixels.cellTop(placed.row))
                }
            }
        }
    }
}

/** Keep ordinary context em sizing; convert a capped result back through the
 * same density/font converter rather than treating 10000 pixels as 10000 sp.
 * All current StyledText callers supply Material typography with an sp size.
 */
internal fun renderedSpanFontSize(span: Span, contextSize: TextUnit, normalBodySize: TextUnit, density: Density): TextUnit {
    require(contextSize.isSp && normalBodySize.isSp)
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
            val table = block.table
            when {
                table != null -> {
                    table.visitSpanRuns { spans, literal -> include(spans, literal) }
                }
                block.kind != "rule" -> include(block.spans, preserveWhitespace = block.kind == "preformatted")
            }
        }
    }
    entry.references.forEach { reference -> reference.visitSpanRuns { spans, literal -> include(spans, literal) } }
}

@Composable
internal fun StyledText(source: List<Span>, modifier: Modifier = Modifier, weight: FontWeight? = null, style: TextStyle = MaterialTheme.typography.bodyLarge, onLink: (EntryLink) -> Unit = {}, preserveWhitespace: Boolean = false) {
    val cellTextAlign = LocalCellTextAlign.current
    val spans = remember(source, preserveWhitespace) { if (preserveWhitespace) source else compactSpans(source) }
    val availableMedia = LocalEntryMedia.current
    val owners = LocalEntryMediaOwners.current
    val embedded = owners.embedded(spans.filter { it.image == null })
    if (embedded.isNotEmpty()) {
        Column(modifier) {
            // Captions are compiled spans; the media record contains only a plain summary.
            val text = remember(spans) { spans.map { if (it.hasClassToken("wikidict-media")) it.withoutClassToken("wikidict-media") else it } }
            StyledText(text, weight = weight, style = style, onLink = onLink, preserveWhitespace = preserveWhitespace)
            embedded.forEach { MediaView(it, LocalReaderSettings.current, showFileName = false, edition=LocalEntryEdition.current, showCaption = false) }
        }
        return
    }
    val linkColor = MaterialTheme.colorScheme.primary
    val cache = LocalTextCache.current
    val currentLink = rememberUpdatedState(onLink)
    val inheritedBackground = LocalAuthoredBackground.current
    val annotated = styledTextAnnotation(spans, weight, style, onLink)
    val egyptianRuns = remember(spans) { egyptianTextRuns(spans) }
    val inlineContent = if (spans.any { it.image != null }) compiledInlineImageContent(spans, annotated, style,
        availableMedia, LocalReaderSettings.current, LocalEntryEdition.current,
        { target -> (cache?.link?.value ?: currentLink.value)(target) },
        authoredSpanForegroundArgb(null, inheritedBackground)?.let { Color(it) } ?: MaterialTheme.colorScheme.onSurfaceVariant)
        else emptyMap()
    SelectionContainer(modifier = modifier.then(if (cellTextAlign == null) Modifier else Modifier.fillMaxWidth())) {
        EgyptianInlineText(annotated, egyptianRuns, Modifier.then(if (cellTextAlign == null) Modifier else Modifier.fillMaxWidth()),
            style.copy(textDirection = TextDirection.Content, textAlign = cellTextAlign ?: style.textAlign), linkColor, inlineContent)
    }
}

@Composable
private fun styledTextAnnotation(spans: List<Span>, weight: FontWeight?, style: TextStyle,
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
    val cacheKey = TextCacheKey(effectiveWeight, layoutDirection, inheritedBackground, normalBodySize, contextSize, textDensity)
    val annotated = remember(spans, effectiveWeight, linkColor, codeColor, cache, layoutDirection, inheritedBackground, normalBodySize, contextSize, textDensity) {
        cache?.values?.get(spans)?.get(cacheKey) ?: buildAnnotatedString {
            val appendedSpans = ArrayList<Pair<Span, IntRange>>(spans.size)
            spans.forEachIndexed { index, span ->
                val effectiveBackground = span.background ?: inheritedBackground.takeIf { !span.code }
                val foreground = authoredSpanForegroundArgb(span.foreground, effectiveBackground)?.let { Color(it) }
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
                        else -> null
                    }
                    if (foreground != null || languageTag != null || fontFamily != null || effectiveWeight != null || span.bold || span.italic || span.code || span.small || span.superscript || span.subscript || span.strike || span.underline || span.fontScale != null) addStyle(SpanStyle(
                        color = foreground ?: Color.Unspecified,
                        localeList = languageTag?.let { LocaleList(Locale(it)) },
                        fontWeight = if (span.bold) FontWeight.Bold else effectiveWeight,
                        fontStyle = if (span.italic) FontStyle.Italic else null,
                        fontFamily = fontFamily,
                        letterSpacing = if (fontFamily == EgyptianFontFamily) 0.sp else TextUnit.Unspecified,
                        fontSize = renderedSpanFontSize(span, contextSize, normalBodySize, textDensity),
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

private val LocalFloatTableWidthReference = staticCompositionLocalOf<Int?> { null }
private val LocalFloatMarginsConsumed = staticCompositionLocalOf { false }

@Composable
private fun FloatBlockSequence(blocks: List<Block>, onLink: (EntryLink) -> Unit, path: String,
    modifier: Modifier = Modifier, inCell: Boolean = false, gridPath: String = "root", gapDp: Float,
    trailingGap: Boolean) {
    if (blocks.any { it.table?.style?.floatSide != null }) {
        NativeFloatBlockContext(blocks, onLink, path, modifier, inCell, gridPath, gapDp, trailingGap)
    } else Column(modifier.fillMaxWidth()) {
        blocks.forEachIndexed { index, block ->
            val gap = if (trailingGap || index + 1 < blocks.size) gapDp else 0f
            Box(Modifier.padding(bottom = gap.dp)) {
                BlockView(block, onLink, "$path/block-$index", inCell, "$gridPath/block-$index")
            }
        }
    }
}

@Composable
private fun NativeFloatBlockContext(blocks: List<Block>, onLink: (EntryLink) -> Unit, path: String,
    modifier: Modifier, inCell: Boolean, gridPath: String, gapDp: Float, trailingGap: Boolean,
    containAtEnd: Boolean = true, blockPaths: List<String>? = null, gapsDp: List<Float>? = null,
    sectionRows: Map<Int, ReadingRow> = emptyMap(), sectionActions: Map<Int, List<NativeHeadingAction>> = emptyMap()) {
    val density = LocalDensity.current
    val inheritedAlign = LocalCellTextAlign.current
    val baseStyle = MaterialTheme.typography.bodyLarge
    val fontPixels = with(density) { baseStyle.fontSize.toPx() }
    val windowHeight = LocalWindowInfo.current.containerSize.height.takeIf { it > 0 }
    val linkColor = MaterialTheme.colorScheme.primary
    val media = LocalEntryMedia.current
    val mediaOwners = LocalEntryMediaOwners.current
    val settings = LocalReaderSettings.current
    val edition = LocalEntryEdition.current
    val parts = blocks.mapIndexed { index, block ->
        val gap = if (trailingGap || index + 1 < blocks.size) (gapsDp?.get(index) ?: gapDp) * density.density else 0f
        val heading = block.kind == "heading"
        val actions = sectionActions[index].orEmpty()
        val typography = if (heading) {
            if (sectionRows[index]?.meaningSection == true) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium
        } else baseStyle
        val style = typography.copy(textAlign = block.textAlign?.composeAlign() ?: inheritedAlign ?: androidx.compose.ui.text.style.TextAlign.Unspecified)
        val nativeTextKinds = setOf("paragraph", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "heading")
        if (block.kind in nativeTextKinds && block.table == null && block.feature == null &&
            mediaOwners.embedded(block.spans.filter { it.image == null }).isEmpty()) {
            val spans = compactSpans(ordinaryInlineDisplaySpans(block))
            val annotated = styledTextAnnotation(spans, if (block.kind == "term") FontWeight.Bold else null, style, onLink)
            val prefixStyle = MaterialTheme.typography.labelMedium.copy(color =
                authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)?.let { Color(it) } ?: MaterialTheme.colorScheme.primary)
            NativeFloatContextSpec.Text(prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), style, linkColor,
                media, settings, edition, onLink, indentPixels = blockIndentDp(block) * density.density,
                prefix = blockPrefix(block), prefixStyle = prefixStyle, heading = heading, headingActions = actions), gap,
                blockPaths?.get(index) ?: "$path/block-$index")
        } else {
            val table = block.table
            val side = table?.style?.floatSide
            fun natural(originalWidth: Int): TableRenderMetrics? = table?.let {
                tableRenderMetrics(it, with(density) { 136.dp.roundToPx() }, with(density) { 10.dp.roundToPx() },
                    with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = fontPixels,
                    decorationViewportWidth = originalWidth, decorationViewportHeight = windowHeight)
            }
            NativeFloatContextSpec.Child(index, { originalWidth ->
                if (table == null || block.feature != null) originalWidth else {
                    val metrics = natural(originalWidth)?.let { tableMetricsInWidth(table, it, tableGrid(table).columns, originalWidth) }
                    val margins = if (side == null) metrics?.style?.margins?.horizontal ?: 0 else 0
                    val markerWidth = if (block.kind == "list_item") with(density) { 28.dp.roundToPx() } else 0
                    val width = metrics?.let { it.width.toLong() + margins + markerWidth + (blockIndentDp(block) * density.density).toInt() }
                        ?: originalWidth.toLong()
                    width.coerceIn(1L, originalWidth.toLong()).toInt()
                }
            }, if (side == null) gap else 0f, side, { originalWidth ->
                val edges = if (side == null) null else natural(originalWidth)?.style?.margins
                FloatMargins(edges?.top?.toFloat() ?: 0f, edges?.right?.toFloat() ?: 0f,
                    edges?.bottom?.toFloat() ?: 0f, edges?.left?.toFloat() ?: 0f)
            }, requiresUnobstructedText = table == null)
        }
    }
    val request = LocalCellHeadingRequest.current
    val reached = LocalCellHeadingReached.current
    val revealIndex = parts.indexOfFirst { it is NativeFloatContextSpec.Text && it.path == request?.path }.takeIf { request != null && it >= 0 }
    NativeFloatContextLayout(parts, modifier, linkColor, containAtEnd, revealIndex, request,
        { if (request != null) reached(request) }) { index, originalWidth ->
        CompositionLocalProvider(LocalFloatTableWidthReference provides originalWidth,
            LocalFloatMarginsConsumed provides (blocks[index].table?.style?.floatSide != null)) {
            BlockView(blocks[index], onLink, blockPaths?.get(index) ?: "$path/block-$index", inCell, "$gridPath/block-$index")
        }
    }
}
