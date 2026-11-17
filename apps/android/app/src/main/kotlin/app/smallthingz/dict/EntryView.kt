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
import androidx.compose.foundation.gestures.scrollBy
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
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.positionInWindow
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
    val computedCellTraits: Boolean = false, val cellBodyFamily: FontFamily? = null,
    val compiledTableDirection: TableContainingDirection? = null, val compiledTableLanguage: String? = null,
    val inheritedFamily: ContainerFontFamily? = null, val authoredPreformatted: Boolean = false,
    val computedContainerTraits: Boolean = false, val bodyDirection: BidiResolvedDirection? = null,
    val columnDirection: BidiResolvedDirection? = null)
private class TextCache(val link: State<(EntryLink) -> Unit>) {
    val values = java.util.IdentityHashMap<List<Span>, MutableMap<TextCacheKey, AnnotatedString>>()
}
private val LocalEntryMedia = staticCompositionLocalOf<List<Media>> { emptyList() }
private val LocalEntryMediaOwners = staticCompositionLocalOf { MediaOwners(emptyList()) }
internal val LocalEntryEdition = staticCompositionLocalOf { "" }
private val LocalReaderSettings = staticCompositionLocalOf { AppSettings() }
private val LocalTextCache = staticCompositionLocalOf<TextCache?> { null }
internal val LocalAuthoredBackground = staticCompositionLocalOf<String?> { null }
internal val LocalFigureCaptionForeground = staticCompositionLocalOf<Int?> { null }
internal val LocalCellWeight = staticCompositionLocalOf<FontWeight?> { null }
internal val LocalTableLineHeightPixels = staticCompositionLocalOf<Float?> { null }
private val LocalCellTextAlign = staticCompositionLocalOf<androidx.compose.ui.text.style.TextAlign?> { null }
internal val LocalCellLetterSpacingPixels = staticCompositionLocalOf<Float?> { null }
internal val LocalCssPixelTextZoom = staticCompositionLocalOf { 1f }
internal val LocalNativeContainerTextContext = staticCompositionLocalOf<ContainerTextContext?> { null }
internal val LocalNativePreformattedText = staticCompositionLocalOf { false }
private val LocalReferenceBodyTypography = staticCompositionLocalOf { false }

@Composable
internal fun inheritedContainerFormat(context: ContainerTextContext? = LocalNativeContainerTextContext.current): NativeContainerTextFormat? = context?.let {
    nativeContainerTextFormat(it, MaterialTheme.typography.bodyLarge.fontSize,
        compiledTableOwnerTextStyle(MaterialTheme.typography.bodyLarge).let { style -> if (it.cellText == null) style else
            style.copy(fontWeight = LocalCellWeight.current ?: style.fontWeight) }, LocalDensity.current)
}

@Composable
private fun inheritedContainerBodyStyle(): TextStyle = inheritedContainerFormat()?.style
    ?: compiledTableOwnerTextStyle(MaterialTheme.typography.bodyLarge)

@Composable
private fun compiledTableOwnerTextStyle(style: TextStyle): TextStyle {
    val language = LocalCompiledTableSourceLanguage.current
    val direction = LocalCompiledTableTextDirection.current
    if (language == null && direction == null) return style
    return style.copy(localeList = language?.let { LocaleList(Locale(it)) } ?: style.localeList,
        textDirection = direction?.paragraphDirection() ?: style.textDirection)
}

@Composable
internal fun inheritedCellTextStyle(style: TextStyle): TextStyle {
    val ownerStyle = compiledTableOwnerTextStyle(style)
    val pixels = LocalCellLetterSpacingPixels.current ?: return ownerStyle
    val density = LocalDensity.current
    return ownerStyle.copy(letterSpacing = with(density) { pixels.toSp() })
}
internal class CellHeadingRequest(val path: String, val anchorMatch: HeadingAnchorSelection? = null,
    val externalRequest: EntryAnchorRequest? = null)
internal val LocalCellHeadingRequest = staticCompositionLocalOf<CellHeadingRequest?> { null }
internal val LocalCellHeadingReached = staticCompositionLocalOf<(CellHeadingRequest) -> Unit> { {} }
internal val LocalSourceHeadingReveal = staticCompositionLocalOf<suspend (CellHeadingRequest, Float?) -> Unit> { { _, _ -> } }
internal const val SourceHeadingRevealUnavailable = "Unable to position this heading."

@Composable
private fun CellHeading(block: Block, path: String?, onLink: (EntryLink) -> Unit) {
    val request = LocalCellHeadingRequest.current
    val reached = LocalCellHeadingReached.current
    val bringIntoView = remember { BringIntoViewRequester() }
    val sourceReveal = LocalSourceHeadingReveal.current
    LaunchedEffect(request, path) {
        if (request != null && request.path == path) {
            if (request.anchorMatch?.revealTop != null) sourceReveal(request, null)
            else {
                withFrameNanos { }
                bringIntoView.bringIntoView()
                reached(request)
            }
        }
    }
    val textContext = nativeWithoutBodyTextContext(LocalNativeContainerTextContext.current,
        MaterialTheme.typography.bodyLarge.fontSize, LocalDensity.current)
    CompositionLocalProvider(LocalNativeContainerTextContext provides textContext) {
    StyledText(if (textContext?.fontFamily is ContainerFontFamily.Stack) block.spans
        else ordinaryInlineDisplaySpans(block), Modifier.fillMaxWidth()
        .padding(start = blockIndentDp(block).dp).bringIntoViewRequester(bringIntoView)
        .then(if (path == null) Modifier else Modifier.testTag("cell-heading-$path"))
        .semantics { heading() }, style = MaterialTheme.typography.titleMedium, onLink = onLink)
    }
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
    internal val documentScroll = NativeDocumentScrollState()
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
        val documentScroll = readingState?.documentScroll ?: remember { NativeDocumentScrollState() }
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
        val nativeFloatEntry = remember(entry.readingRows, entry.bodyAdjoining, entry.language) {
            floatBodyRuns(entry.readingRows, entry.bodyAdjoining, entry.language).isNotEmpty()
        }
        val visibleRows = visibleEntryReadingRows(entry, foldedKeys)
        val floatRuns = remember(visibleRows, entry.bodyAdjoining, entry.language) {
            floatBodyRuns(visibleRows, entry.bodyAdjoining, entry.language)
        }
        val floatStarts = floatRuns.associateBy { it.first }
        val floatCovered = floatRuns.flatMap { (it.first + 1 until it.last + 1).toList() }.toSet()
        fun actionsForSection(item: ReadingRow): List<NativeHeadingAction> = buildList {
            val section = checkNotNull(item.heading)
            add(NativeHeadingAction(if (folded[item.key] == true) "Expand ${section.title}" else "Collapse ${section.title}",
                folded[item.key] == true) { folded[item.key] = folded[item.key] != true })
            if (item.meaningSection && section.blocks.any { it !== item.headingBlock && it.kind !in setOf("definition", "blank") }) {
                val key = item.key + "-details"
                add(NativeHeadingAction(if (folded[key] == true) "Show examples and notes for ${section.title}" else "Hide examples and notes for ${section.title}",
                    folded[key] == true) { folded[key] = folded[key] != true })
            }
        }
        val entryTextSections = remember(entry, foldedKeys) { foldedEntryTextSections(entry.readingRows, foldedKeys) }
        var cellHeadingRequest by remember { mutableStateOf<CellHeadingRequest?>(null) }
        var sourceRevealFailed by remember { mutableStateOf(false) }
        var citationRevealFailed by remember { mutableStateOf(false) }
        val citationEnabled = entry.references.any { it.backlinks.isNotEmpty() }
        val citationLocations = remember(entry) { if (citationEnabled) citationDestinations(entry) else emptyMap() }
        val citationNavigation = remember(entry, readingState) { NativeCitationNavigation() }
        val citationRequest = citationNavigation.request
        LaunchedEffect(citationNavigation, citationRequest, citationNavigation.revision) {
            val request = citationRequest ?: return@LaunchedEffect
            val currentOwner = citationNavigation.owner(request.marker)
            if (currentOwner == null && citationNavigation.failure(request.marker.anchor) != null) {
                if (citationNavigation.complete(request)) {
                    citationRevealFailed = true
                    request.externalRequest?.let(onAnchorConsumed)
                }
                return@LaunchedEffect
            }
            if (request.revealStarted) return@LaunchedEffect
            if (currentOwner == null) return@LaunchedEffect
            withFrameNanos { }
            if (citationNavigation.request === request) {
                val owner = citationNavigation.owner(request.marker) ?: return@LaunchedEffect
                val completed: (Boolean) -> Unit = { success ->
                    if (citationNavigation.complete(request)) {
                        citationRevealFailed = !success
                        request.externalRequest?.let(onAnchorConsumed)
                    }
                }
                if (!owner.view.revealCitation(owner.geometry, request,
                    current = { citationNavigation.request === request }, completed = completed)) completed(false)
            }
        }
        fun clearCitationRequest(replacingExternal: EntryAnchorRequest? = null) {
            citationNavigation.clear()?.externalRequest?.takeIf { it !== replacingExternal }?.let(onAnchorConsumed)
        }
        var viewportCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
        val revealDensity = LocalDensity.current.density
        fun clearHeadingRequest(replacingExternal: EntryAnchorRequest? = null) {
            val previous = cellHeadingRequest
            cellHeadingRequest = null
            previous?.externalRequest?.takeIf { it !== replacingExternal }?.let(onAnchorConsumed)
        }
        fun jumpToAnchor(target: String, externalRequest: EntryAnchorRequest? = null): Boolean {
            clearCitationRequest(externalRequest)
            citationRevealFailed = false
            val citation = target.takeIf { it.startsWith("#") }?.substring(1)?.let(citationLocations::get)
            if (citation != null) {
                clearHeadingRequest(externalRequest)
                sourceRevealFailed = false
                if (!citation.graphical) { citationRevealFailed = true; return false }
                citationFoldKeys(entry, citation).forEach { folded[it] = false }
                val index = citationScrollIndex(entry, citation, folded.filterValues { it }.keys)
                if (index == null) { citationRevealFailed = true; return false }
                citationNavigation.start(citation.marker, externalRequest)
                scroll.requestScrollToItem(index)
                return true
            }
            val destination = headingDestination(entry, target)
            val headingRow = entry.readingRows.firstOrNull { it.key == destination?.rowKey }
            val compiledHeading = destination?.compiledId == true
            clearHeadingRequest(externalRequest)
            sourceRevealFailed = false
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
                cellHeadingRequest = destination?.path?.let { CellHeadingRequest(it, destination.anchorMatch) }
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
                val containingRun = floatBodyRuns(openedRows, entry.bodyAdjoining, entry.language).firstOrNull { headingIndex in it }
                val match = destination?.anchorMatch
                if (match?.revealTop != null && containingRun == null) {
                    sourceRevealFailed = true
                    return false
                }
                cellHeadingRequest = (destination?.path ?: headingRow.key.takeIf { containingRun != null })?.let {
                    CellHeadingRequest(it, match, externalRequest.takeIf { match?.revealTop != null })
                }
                scroll.requestScrollToItem((containingRun?.first ?: headingIndex) + entryReadingStartIndex(entry, folded.filterValues { it }.keys))
            } else return false
            return true
        }
        val readerLink: (EntryLink) -> Unit = { target ->
            onNavigate()
            if (target.local) jumpToAnchor("#${target.fragment}") else { clearCitationRequest(); onLink(target) }
        }
        LaunchedEffect(entry.key, anchorRequest) {
            anchorRequest?.takeIf { it.entryKey == entry.key }?.let {
                jumpToAnchor(it.target, it)
                // Source positioning completes after its measured scroll (or explicit refusal).
                // Missing and legacy fragments retain their existing one-shot behavior.
                if (cellHeadingRequest?.externalRequest !== it && citationNavigation.request?.externalRequest !== it) onAnchorConsumed(it)
            }
        }
        val bodyText = entry.bodyTypography?.let { typography -> nativeBodyTextContext(
            typography.ownerFont, typography.lineHeight, LocalNativeContainerTextContext.current,
            MaterialTheme.typography.bodyLarge.fontSize, compiledTableOwnerTextStyle(MaterialTheme.typography.bodyLarge),
            LocalDensity.current, direction = typography.direction) }
        val currentLink = rememberUpdatedState(readerLink)
        val cache = remember(entry, colors.primary, colors.surfaceContainer) { TextCache(currentLink) }
        val typedImages = entry.inlineImages
        val imageOwner = if (typedImages.isEmpty()) null else rememberInlineImageViewOwner(typedImages, entry.media, settings, entry.edition, entry.legacyImageFiles, entry.rasterImages)
        val remainingMedia = remember(entry) {
            val linkedFiles = inlineMediaFiles(entry)
            entry.media.filter { it.file !in linkedFiles || it.file in entry.separateImageCaptionFiles }
        }
        val revealSourceHeading: suspend (CellHeadingRequest, Float?) -> Unit = reveal@ { request, targetTop ->
            if (cellHeadingRequest !== request) return@reveal
            val coordinates = viewportCoordinates
            val outset = request.anchorMatch?.revealTop
            val delta = if (targetTop != null && coordinates?.isAttached == true && outset != null)
                headingRevealScrollDelta(targetTop, coordinates.positionInWindow().y, outset, revealDensity) else null
            try {
                if (delta == null) sourceRevealFailed = true
                else scroll.scrollBy(delta)
            } finally {
                // A user scroll may cancel alignment; do not replay that source request later.
                if (cellHeadingRequest === request) {
                    cellHeadingRequest = null
                    request.externalRequest?.let(onAnchorConsumed)
                }
            }
        }
        CompositionLocalProvider(LocalTextCache provides cache, LocalInlineImageOwner provides imageOwner, LocalCellHeadingRequest provides cellHeadingRequest,
            LocalNativeCitationNavigation provides citationNavigation.takeIf { citationEnabled },
            LocalNativeCitationTargetAnchor provides citationNavigation.targetAnchor,
            LocalSourceHeadingReveal provides revealSourceHeading,
            LocalCellHeadingReached provides { request -> if (cellHeadingRequest === request) cellHeadingRequest = null }) {
        Column(Modifier.fillMaxSize()) {
        if (sourceRevealFailed) Text(SourceHeadingRevealUnavailable, color = MaterialTheme.colorScheme.error)
        if (citationRevealFailed) Text(CitationRevealUnavailable, color = MaterialTheme.colorScheme.error)
        NativeDocumentScroll(documentScroll, enabled = remember(entry) { nativeDocumentScrollNeeded(entry) },
            resourceKey = listOf(entry, settings, imageOwner, MaterialTheme.typography.bodyLarge,
                LocalNativeContainerTextContext.current, LocalCssPixelTextZoom.current),
            sourceKeys = floatRuns.map { run -> visibleRows.slice(run).map { it.key } }.toSet(),
            direction = entry.bodyTypography?.direction, imageOwner = imageOwner, images = typedImages,
            modifier = Modifier.weight(1f).fillMaxWidth()) { listModifier, documentPadding, documentOverflow ->
        LazyColumn(listModifier.nestedScroll(dockScroll).testTag("entry-scroll")
            .onGloballyPositioned { viewportCoordinates = it }, state = scroll, contentPadding = documentPadding) {
            item("title", contentType = "title") {
                Column(Modifier.padding(bottom = 6.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text((entry.language ?: entry.kind.replace('_', ' ')).uppercase(), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                        EntryPronunciationButton(SpeechPlayback.active == entry.title) { SpeechPlayback.play(context, entry.title, entry.languageCode) }
                        Box {
                            IconButton(onClick = { contents = true }) { Icon(Icons.AutoMirrored.Filled.List, "Sections", Modifier.size(22.dp)) }
                            DropdownMenu(contents, { contents = false }, Modifier.heightIn(max = 340.dp)) {
                                entry.readingRows.forEach { row -> row.heading?.let { section ->
                                    if (section.headingStyle != null || sectionInContents(section, entry.language)) DropdownMenuItem(text = { Text(section.title) }, onClick = {
                                        clearCitationRequest()
                                        citationRevealFailed = false
                                        onNavigate()
                                        contents = false
                                        if (cellHeadingRequest?.anchorMatch?.revealTop != null) clearHeadingRequest()
                                        val referenceHeading = row.key == metadataReferenceHeadingKey(entry)
                                        folded[if (referenceHeading) "references" else row.key] = false
                                        val targetIndex = if (referenceHeading) {
                                            metadataReferencesStartIndex(entry, folded.filterValues { it }.keys)
                                        } else {
                                            val openedRows = visibleEntryReadingRows(entry, folded.filterValues { it }.keys)
                                            val index = openedRows.indexOfFirst { it.key == row.key }
                                            val run = floatBodyRuns(openedRows, entry.bodyAdjoining, entry.language).firstOrNull { index in it }
                                            if (run != null) cellHeadingRequest = CellHeadingRequest(row.key)
                                            (run?.first ?: index) + entryReadingStartIndex(entry, folded.filterValues { it }.keys)
                                        }
                                        scope.launch {
                                            androidx.compose.runtime.withFrameNanos { }
                                            scroll.animateScrollToItem(targetIndex)
                                        }
                                    })
                                    if (section.headingStyle != null) actionsForSection(row).forEach { action ->
                                        DropdownMenuItem(text = { Text(action.label) }, onClick = {
                                            action.onClick()
                                            contents = false
                                        })
                                    }
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
                val run = floatStarts[rowIndex]
                if (run != null) {
                    val rows = visibleRows.slice(run).filter { it.block != null || it.heading?.let { section -> sectionHeadingVisible(section, entry.language) } == true }
                    val blocks = rows.map { item -> item.block ?: item.headingBlock ?: Block("heading", 0,
                        listOf(Span("text", sectionHeadingLabel(item.heading!!, entry.language, null))), level = item.heading!!.level) }
                    val sectionRows = rows.mapIndexedNotNull { index, item -> if (item.heading == null) null else index to item }.toMap()
                    val actions = sectionRows.mapValues { (_, item) -> actionsForSection(item) }
                    bodyText?.exceptionOrNull()?.let { ReaderLayoutUnavailable(it.message ?: NativeContainerOwnerFontUnavailable) }
                    NativeDocumentOverflowItem(documentOverflow, visibleRows.slice(run).map { it.key }) {
                    NativeFloatBlockContext(blocks, readerLink, row.sectionKey, Modifier,
                        inCell = false, gridPath = "root", gapDp = 6f, trailingGap = true,
                        containAtEnd = true, blockPaths = rows.map { it.key }, gapsDp = rows.map { if (it.compact) 2f else 6f },
                        sectionRows = sectionRows, sectionActions = actions, sectionKeys = rows.map { it.sectionKey },
                        documentSurface = entry.bodyAdjoining == BodyAdjoiningPolicy.Ordinary || blocks.any { it.needsContainerDocumentExtent() || it.needsFigureDocumentExtent() },
                        positionedPaintRoot = true, bodyAdjoining = entry.bodyAdjoining,
                        bodyTextContext = bodyText?.getOrNull())
                    }
                } else if (rowIndex !in floatCovered) {
                    row.heading?.let { section ->
                        if (sectionHeadingVisible(section, entry.language)) {
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
                        val content: @Composable () -> Unit = {
                            BlockView(block, readerLink, path = row.key,
                                outsideGapDp = if (row.compact) 2f else 6f,
                                previousBlock = visibleRows.getOrNull(rowIndex - 1)?.takeIf { it.sectionKey == row.sectionKey }?.block)
                        }
                        if (bodyText == null || block.kind == "heading") content() else {
                            bodyText.exceptionOrNull()?.let { ReaderLayoutUnavailable(it.message ?: NativeContainerOwnerFontUnavailable) }
                            CompositionLocalProvider(LocalNativeContainerTextContext provides
                                (bodyText.getOrNull() ?: LocalNativeContainerTextContext.current), content = content)
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
                    ref.backlinks.forEach { ReferenceBacklinkView(it, readerLink) }
                    ReferenceBody(ref, Modifier.weight(1f), readerLink)

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
    }
}


/** Only the existing weighted reference body enters this scope; label/backlink UI stays outside. */
@Composable
internal fun ReferenceBody(reference: Reference, modifier: Modifier, onLink: (EntryLink) -> Unit) {
    if (LocalNativeContainerTextWrap.current != null) {
        CompositionLocalProvider(LocalNativeContainerTextWrap provides null) { ReferenceBody(reference, modifier, onLink) }
        return
    }
    WithoutBodyTypography {
        val content: @Composable () -> Unit = {
            val blocks = reference.blocks
            if (blocks == null && reference.bodyTypography != null && !reference.spans.hasCompiledInlineContent())
                Spacer(modifier)
            else if (blocks == null) StyledText(reference.spans, modifier, onLink = onLink)
            else FloatBlockSequence(blocks, onLink, "reference-${reference.number}",
                modifier = modifier, gapDp = 6f, trailingGap = true)
        }
        val typography = reference.bodyTypography
        val emptyBody = reference.blocks?.isEmpty() ?: !reference.spans.hasCompiledInlineContent()
        if (typography == null || emptyBody) content() else {
            val context = nativeBodyTextContext(typography.ownerFont, typography.lineHeight,
                LocalNativeContainerTextContext.current, MaterialTheme.typography.bodyLarge.fontSize,
                compiledTableOwnerTextStyle(MaterialTheme.typography.bodyLarge), LocalDensity.current,
                direction = typography.direction)
            context.exceptionOrNull()?.let { ReaderLayoutUnavailable(it.message ?: NativeContainerOwnerFontUnavailable) }
            CompositionLocalProvider(LocalReferenceBodyTypography provides true,
                LocalNativeContainerTextContext provides
                    (context.getOrNull() ?: LocalNativeContainerTextContext.current), content = content)
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
        if (block.ruleStyle != null) {
            BlockContent(block, onLink, path, inCell, gridPath)
        } else if (block.style == null) {
            if (outsideGapDp == null) BlockContent(block, onLink, path, inCell, gridPath)
            else Box(Modifier.padding(bottom = outsideGapDp.dp)) { BlockContent(block, onLink, path, inCell, gridPath) }
        } else {
            val density = LocalDensity.current
            val bodyFontPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
            val preserveCompiledText = LocalNativeContainerTextContext.current?.fontFamily is ContainerFontFamily.Stack
            val box = try {
                paragraphBox(block, previousBlock, (outsideGapDp ?: 0f) * density.density, density.density,
                    bodyFontPixels, preserveCompiledText)!!
            } catch (_: UnsupportedFloatLayout) { null }
            if (box == null) {
                Text("Paragraph layout unavailable at this size")
                return@CompositionLocalProvider
            }
            ParagraphBoxLayout(box, outsideGapDp != null,
                paragraphHasContent(block, preserveCompiledText)) {
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
    // Preserve the old bare-paragraph branch and spacing, without a line/strut grant
    // from the new reference metadata. Real empty metrics and BR remain source lines.
    if (LocalReferenceBodyTypography.current && LocalNativeContainerTextContext.current?.bodyOrigin != null &&
        block.kind == "paragraph" && block.container == null && block.figure == null && block.flow == null &&
        block.table == null && !block.spans.hasCompiledInlineContent()) {
        WithoutBodyTypography {
            CompositionLocalProvider(LocalReferenceBodyTypography provides false) {
                BlockContent(block, onLink, path, inCell, gridPath)
            }
        }
        return
    }
    when {
        block.container != null -> NativeFloatBlockContext(listOf(block), onLink, path ?: gridPath,
            Modifier, inCell, gridPath, 0f, false)
        block.figure != null || block.flow != null -> {
            // List ownership is outside the figure/anonymous formatting owner.
            Row(Modifier.padding(start = blockIndentDp(block).dp)) {
                val prefix = blockPrefix(block)
                if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp),
                    color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                val sourceFormat = if (LocalNativeContainerTextContext.current?.containerText != null)
                    inheritedContainerFormat() else null
                AnonymousBlockView(block, Modifier.weight(1f), onLink,
                    LocalEntryMedia.current, LocalReaderSettings.current, LocalEntryEdition.current,
                    inheritedAlign = figureInheritedAlign(LocalCellTextAlign.current, LocalLayoutDirection.current),
                    style = sourceFormat?.style ?: MaterialTheme.typography.bodyLarge,
                    nativeLineHeight = sourceFormat?.lineHeight, ownerFont = sourceFormat?.ownerFont)
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
        block.kind == "heading" -> if (LocalNativeContainerTextWrap.current == null) CellHeading(block, path, onLink)
            else CompositionLocalProvider(LocalNativeContainerTextWrap provides null) { CellHeading(block, path, onLink) }
        block.ruleStyle != null -> AuthoredRule(block.ruleStyle)
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
                StyledText(if (LocalNativeContainerTextContext.current?.fontFamily is ContainerFontFamily.Stack) block.spans
                    else if (block.style != null) paragraphDisplaySpans(block) else ordinaryInlineDisplaySpans(block),
                    Modifier.weight(1f), weight = if (block.kind == "term") FontWeight.Bold else null,
                    onLink = onLink, preserveWhitespace = block.style != null)
            }
        }
    }
}

@Composable
internal fun CompiledTableView(table: Table, feature: Feature?, onLink: (EntryLink) -> Unit) =
    RenderCompiledTable(table, feature, "root", false, "", onLink)

private fun tableHasMinimumWidth(table: Table): Boolean {
    var found = false
    PresentationSpanVisitor { _, _ -> }.apply {
        onTable = { value, _, _ -> if (value.style?.minWidth != null) found = true }
    }.table(table)
    return found
}

private fun tableLayoutFeature(table: Table, feature: Feature?): Feature? =
    feature?.takeUnless { tableHasMinimumWidth(table) }

@Composable
private fun TableCaptionContext(table: Table, content: @Composable () -> Unit) {
    // A caption establishes the nested table's actual containing width. The outer
    // table's percentage input cannot replace that nearer measured constraint.
    if (remember(table) { tableHasMinimumWidth(table) }) {
        CompositionLocalProvider(LocalFloatTableWidthReference provides null) {
            WithoutBodyTypography(content)
        }
    } else WithoutBodyTypography(content)
}

@Composable
private fun RenderCompiledTable(table: Table, feature: Feature?, path: String, nested: Boolean, semanticPath: String, onLink: (EntryLink) -> Unit) {
    val sample = if (table.blockViewport == null && table.floatViewport == null && LocalNativeContainerTextContext.current?.fontFamily !is ContainerFontFamily.Stack &&
        !tableHasOrdinaryLinkPaint(table) && !tableHasAuthoredInlineStyles(table))
        colorSwatch(tableLayoutFeature(table, feature)) else null
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
private fun tableLineHeightPixels(table: Table, contextStyle: TextStyle = inheritedContainerBodyStyle(),
    authoredStyle: TableStyle? = table.style): Float? {
    val density = LocalDensity.current
    val contextPixels = with(density) { LocalTextStyle.current.merge(contextStyle).fontSize.toPx() }
    val normalPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    return authoredStyle?.lineHeight?.let { value ->
        value.value * if (value.fontScaleBasis == FontScaleBasis.Context) contextPixels else normalPixels
    } ?: LocalTableLineHeightPixels.current
}

@Composable
private fun InlineTableLine(block: Block, onLink: (EntryLink) -> Unit, path: String?, inCell: Boolean, gridPath: String) {
    val table = requireNotNull(block.table)
    if (table.style?.minWidth != null && LocalFloatTableWidthReference.current == null) {
        TableMinimumContainingWidth { InlineTableLine(block, onLink, path, inCell, gridPath) }
        return
    }
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
internal val LocalTableDocumentViewportCssWidth = staticCompositionLocalOf<Double?> { null }
// Recursive owner guards use reference identity, including equal reconstructed Tables.
private val LocalCompiledTableDirectionOwner = compositionLocalOf(referentialEqualityPolicy<Table?>()) { null }
internal val LocalCompiledTableTextDirection = staticCompositionLocalOf<TableContainingDirection?> { null }
internal val LocalNativeColumnTextDirection = staticCompositionLocalOf<BidiResolvedDirection?> { null }

/** The nearest column owner precedes its outer Table/BODY; a nearer Table resets that local. */
internal fun compiledBodyParagraphDirection(table: TableContainingDirection?,
    body: BidiResolvedDirection?, column: BidiResolvedDirection? = null): TextDirection? = when (column) {
    BidiResolvedDirection.Ltr -> TextDirection.Ltr
    BidiResolvedDirection.Rtl -> TextDirection.Rtl
    null -> table?.paragraphDirection() ?: when (body) {
        BidiResolvedDirection.Ltr -> TextDirection.Ltr
        BidiResolvedDirection.Rtl -> TextDirection.Rtl
        null -> null
    }
}
internal val LocalCompiledTableSourceLanguage = staticCompositionLocalOf<String?> { null }

private fun TableContainingDirection.paragraphDirection(): TextDirection =
    if (this == TableContainingDirection.Rtl) TextDirection.Rtl else TextDirection.Ltr

@Composable
private fun tableDocumentViewportCssWidth(): Double = LocalTableDocumentViewportCssWidth.current
    ?: (LocalWindowInfo.current.containerSize.width.toDouble() / LocalDensity.current.density)

@Composable
private fun activeTableBlockViewport(table: Table): TableBlockViewport? =
    if (table.blockViewport == null) null else table.blockViewportAt(tableDocumentViewportCssWidth())

/** Publish only an actual containing width, before source margins or inline markers.
 * Intrinsic queries retain percentage dependency without manufacturing a containing block. */
@Composable
private fun TableMinimumContainingWidth(content: @Composable () -> Unit) {
    val input = remember { NativeLayoutInput(-1) }
    CompositionLocalProvider(LocalFloatTableWidthReference provides input) {
        Layout(content = content, measurePolicy = object : MeasurePolicy {
            override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                measurables.single().minIntrinsicWidth(height)
            override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                measurables.single().maxIntrinsicWidth(height)
            override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
                measurables.single().minIntrinsicHeight(width)
            override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
                measurables.single().maxIntrinsicHeight(width)
            override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                // -1 is unavailable, never a source width or a retained previous allocation.
                input.update(if (constraints.hasBoundedWidth) constraints.maxWidth else -1)
                val child = measurables.single().measure(constraints)
                return layout(child.width, child.height) { child.place(0, 0) }
            }
        })
    }
}

@Composable
private fun TableView(table: Table, onLink: (EntryLink) -> Unit, path: String = "root", nested: Boolean = false, semanticPath: String = "") {
  if (table.style?.minWidth != null && LocalFloatTableWidthReference.current == null) {
      TableMinimumContainingWidth { TableView(table, onLink, path, nested, semanticPath) }
      return
  }
  val ownerDirection = table.blockViewport?.gridDirection ?: table.floatViewport?.gridDirection
  val ownerLanguage = table.blockViewport?.language ?: table.floatViewport?.language
  val ownLanguage = ownerLanguage?.let(::nativeTableOwnerLanguageTag)
  if (ownerDirection != null && ownLanguage == null) {
      UnavailableTableLanguage(table, ownerDirection, onLink)
      return
  }
  if (ownerDirection != null && LocalCompiledTableDirectionOwner.current !== table) {
      CompositionLocalProvider(LocalCompiledTableDirectionOwner provides table,
          LocalCompiledTableTextDirection provides ownerDirection,
          LocalNativeColumnTextDirection provides null,
          LocalCompiledTableSourceLanguage provides ownLanguage,
          LocalLayoutDirection provides if (ownerDirection == TableContainingDirection.Rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
          TableView(table, onLink, path, nested, semanticPath)
      }
      return
  }
  val blockViewport = activeTableBlockViewport(table)
  if ((blockViewport != null || table.blockViewport?.isSeparateCornerGrid == true || table.blockViewport?.intrinsicContainingDirection != null || table.floatViewport != null || table.style?.floatSide != null || table.style?.let { it.marginValues != null && !it.isInline } == true) &&
      !LocalFloatMarginsConsumed.current) {
      NativeFloatBlockContext(listOf(Block(kind = "table", depth = 0, spans = emptyList(), table = table)),
          onLink, semanticPath, Modifier, nested, path, 0f, false)
      return
  }
  val captionFailure = if (table.caption.isNotEmpty() || table.captionBlocks?.isNotEmpty() == true) when {
      table.blockViewport?.isSeparateCornerGrid == true -> "Corner-table focus with a caption is unavailable."
      table.blockViewport?.intrinsicContainingDirection != null -> "Intrinsic table focus with a caption is unavailable."
      else -> null
  } else null
  if (captionFailure != null) {
      val retained = remember(table) { Block("table", 0, emptyList(), table = table) }
      val reader = FigureReaderContext(LocalEntryMedia.current, LocalReaderSettings.current,
          LocalEntryEdition.current, onLink, table)
      UnavailableAnonymousContent(retained, Modifier, captionFailure,
          inheritedContainerBodyStyle(), reader, reasonVisible = true)
      return
  }
  if (table.blockViewport != null && (table.floatViewport != null || table.blockViewport.isSeparateCornerGrid || table.blockViewport.intrinsicContainingDirection != null)) {
      PairedViewportTableView(table, table.blockViewport, blockViewport != null, onLink, path, semanticPath)
      return
  }
  if (blockViewport != null) {
      BlockViewportTableView(table, blockViewport, onLink, path, semanticPath)
      return
  }
  if (table.style?.let { it.cornerRadii != null && it.marginValues == null && it.containingDirection != null } == true) {
      val retained = remember(table) { Block("table", 0, emptyList(), table = table) }
      val reader = FigureReaderContext(LocalEntryMedia.current, LocalReaderSettings.current,
          LocalEntryEdition.current, onLink, table)
      UnavailableAnonymousContent(retained, Modifier, "Numeric corner-table margins outside the responsive block are unavailable.",
          inheritedContainerBodyStyle(), reader, reasonVisible = true)
      return
  }
  if (table.floatViewport != null) {
      FloatViewportTableView(table, onLink, path, semanticPath)
      return
  }
  if (table.style?.marginValues != null) {
      AutoMarginTableView(table, onLink, path, nested, semanticPath)
      return
  }
  if (table.style?.isInline != true && (table.blockViewport?.isSeparateCornerGrid == true || tableUsesContentWidths(table, LocalTableContentWidths.current))) {
      ContentSizedTableView(table, onLink, path, nested, semanticPath)
      return
  }
  val phaseObserver = LocalTablePhaseObserver.current
  val window = LocalWindowInfo.current.containerSize
  val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
  val inline = table.style?.isInline == true
  val lineHeightPixels = tableLineHeightPixels(table)
  if (table.style?.minWidth == null && lineHeightPixels != null && (!lineHeightPixels.isFinite() || lineHeightPixels <= 0f || lineHeightPixels > TablePixelLimit)) {
      Text("Table line height is too large to display.")
      return
  }
  CompositionLocalProvider(LocalTableLineHeightPixels provides lineHeightPixels?.takeUnless {
      table.style?.minWidth != null && (!it.isFinite() || it <= 0f || it > TablePixelLimit)
  }) {
  BoxWithConstraints(if (inline) Modifier else Modifier.fillMaxWidth()) {
    val decorationWidth = LocalFloatTableWidthReference.current?.value?.takeUnless { table.style?.minWidth != null && it < 0 }
        ?: listOfNotNull(constraints.maxWidth.takeIf { constraints.hasBoundedWidth }, window.width.takeIf { it > 0 }).minOrNull()
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
        TableCaptionContext(table) {
        if (table.captionBlocks != null) FloatBlockSequence(table.captionBlocks, onLink, "$semanticPath/caption",
            gapDp = 6f, trailingGap = false)
        else if (table.caption.isNotEmpty()) StyledText(table.caption, onLink = onLink)
        }
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

@Composable
private fun UnavailableTableLanguage(table: Table, direction: TableContainingDirection, onLink: (EntryLink) -> Unit) {
    val retained = remember(table) { Block("table", 0, emptyList(), table = table) }
    val reader = FigureReaderContext(LocalEntryMedia.current, LocalReaderSettings.current,
        LocalEntryEdition.current, onLink, table)
    CompositionLocalProvider(LocalCompiledTableDirectionOwner provides table,
        LocalCompiledTableTextDirection provides direction,
        LocalNativeColumnTextDirection provides null,
        LocalCompiledTableSourceLanguage provides null,
        LocalNativeContainerTextContext provides null, LocalTableLineHeightPixels provides null,
        LocalNativeDelegatedTable provides null, LocalNativeDelegatedCell provides null,
        LocalNativeTableMarginMeasureInput provides null, LocalTableBlockLayoutFailure provides null,
        LocalFloatTableWidthReference provides null, LocalFloatMarginsConsumed provides false,
        LocalCellWeight provides null, LocalCellLetterSpacingPixels provides null,
        LocalLayoutDirection provides if (direction == TableContainingDirection.Rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
        UnavailableAnonymousContent(retained, Modifier.testTag("compiled-table-language-unavailable"),
            NativeTableLanguageUnavailable, MaterialTheme.typography.bodyLarge.copy(localeList = null),
            reader, reasonVisible = true)
    }
}

@Composable
private fun BlockViewportTableView(table: Table, policy: TableBlockViewport,
    onLink: (EntryLink) -> Unit, path: String, semanticPath: String) {
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val rtl = policy.gridDirection == TableContainingDirection.Rtl
    val natural = remember(table, policy, density.density, bodyPixels) {
        anonymousTableRenderMetrics(table, policy.gridStyle, density.density, bodyPixels, rtl)
    }
    val lineHeight = tableLineHeightPixels(table, authoredStyle = policy.gridStyle)?.takeIf {
        it.isFinite() && it > 0f && it <= TablePixelLimit
    }
    val captionMinimum = remember(table) { NativeLayoutInput(0) }
    val hasCaption = table.captionBlocks?.isNotEmpty() == true || table.caption.isNotEmpty()
    CompositionLocalProvider(LocalTableContentWidths provides true,
        LocalLayoutDirection provides if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr,
        LocalTableLineHeightPixels provides lineHeight) {
        TableBlockViewportBox(table, policy, captionMinimum, hasCaption, 0) {
            if (hasCaption) TableContentColumn(Modifier, 0.dp) {
                TableCaptionContext(table) {
                if (table.captionBlocks != null) FloatBlockSequence(table.captionBlocks, onLink, "$semanticPath/caption",
                    gapDp = 6f, trailingGap = false)
                else StyledText(table.caption, onLink = onLink)
                }
            }
            TableGridView(table, onLink, path, null, semanticPath, natural, 1.0, { },
                contentWidths = true, captionMinimumWidth = captionMinimum, anonymousGridStyle = policy.gridStyle)
        }
    }
}

/** Both responsive states retain this one source grid and its common scroll/focus owner. */
@Composable
private fun PairedViewportTableView(table: Table, policy: TableBlockViewport, narrow: Boolean,
    onLink: (EntryLink) -> Unit, path: String, semanticPath: String) {
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val rtl = policy.gridDirection == TableContainingDirection.Rtl
    val natural = remember(table, policy, narrow, density.density, bodyPixels) {
        if (narrow) anonymousTableRenderMetrics(table, policy.gridStyle, density.density, bodyPixels, rtl)
        else tableRenderMetrics(table, 1, with(density) { 10.dp.roundToPx() }, 0,
            density.density, containerFontPixels = bodyPixels, rtl = rtl, marginsConsumed = true)
    }
    val lineHeight = tableLineHeightPixels(table, authoredStyle = if (narrow) policy.gridStyle else table.style)
    val minimum = remember(table) { NativeLayoutInput(0) }
    CompositionLocalProvider(LocalTableContentWidths provides true,
        LocalNativeFractionalTableCoordinates provides true, LocalTableLineHeightPixels provides lineHeight) {
        TableBlockViewportBox(table, policy, minimum, false, 0, narrow = narrow) {
            TableGridView(table, onLink, path, null, semanticPath, natural, 1.0, { },
                contentWidths = true, captionMinimumWidth = minimum,
                anonymousGridStyle = policy.gridStyle.takeIf { narrow },
                pairedHeightIntrinsics = table.floatViewport != null || policy.intrinsicContainingDirection != null, ownCollectionSemantics = false)
        }
    }
}

/** Responsive placement keeps the real grid border box and never creates a local scrollport. */
@Composable
private fun FloatViewportTableView(table: Table, onLink: (EntryLink) -> Unit, path: String,
    semanticPath: String) {
    val density = LocalDensity.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val natural = remember(table, density.density, bodyPixels, rtl) {
        tableRenderMetrics(table, 1, with(density) { 10.dp.roundToPx() },
            with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = bodyPixels,
            rtl = rtl, marginsConsumed = true)
    }
    val minimum = remember(table) { NativeLayoutInput(0) }
    CompositionLocalProvider(LocalTableContentWidths provides true,
        LocalNativeFractionalTableCoordinates provides true) {
        TableMarginBorderBox(table, minimum, false, 0, false, FloatMargins(0f, 0f, 0f, 0f)) {
            TableGridView(table, onLink, path, null, semanticPath, natural, 1.0, { },
                contentWidths = true, captionMinimumWidth = minimum)
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
                TableCaptionContext(table) {
                if (table.captionBlocks != null) FloatBlockSequence(table.captionBlocks, onLink, "$semanticPath/caption",
                    gapDp = 6f, trailingGap = false)
                else StyledText(table.caption, onLink = onLink)
                }
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
    if (table.style?.minWidth == null && lineHeight != null && (!lineHeight.isFinite() || lineHeight <= 0f || lineHeight > TablePixelLimit)) {
        Text("Table line height is too large to display.")
        return
    }
    val margin = natural?.style?.margins.takeUnless { LocalFloatMarginsConsumed.current }
    val marginModifier = if (margin == null) Modifier else with(density) {
        Modifier.absolutePadding(left = margin.left.toDp(), top = margin.top.toDp(),
            right = margin.right.toDp(), bottom = margin.bottom.toDp())
    }
    CompositionLocalProvider(LocalTableContentWidths provides true, LocalTableLineHeightPixels provides lineHeight?.takeUnless {
        table.style?.minWidth != null && (!it.isFinite() || it <= 0f || it > TablePixelLimit)
    }) {
        TableContentColumn(marginModifier, 6.dp) {
            TableCaptionContext(table) {
            if (table.captionBlocks != null) FloatBlockSequence(table.captionBlocks, onLink, "$semanticPath/caption",
                gapDp = 6f, trailingGap = false)
            else if (table.caption.isNotEmpty()) StyledText(table.caption, onLink = onLink)
            }
            TableContentViewport(scrolling = !nested && !LocalNativeContainerScrollport.current) {
                TableGridView(table, onLink, path, null, semanticPath, natural, 1.0, { }, contentWidths = true)
            }
        }
    }
}

@Composable
private fun UnavailableAnonymousGrid(table: Table, onLink: (EntryLink) -> Unit, path: String,
    semanticPath: String, cells: List<CaptionCellSlot>?, sink: SelectionGeometrySink?, reason: String,
    refuseIntrinsicQueries: Boolean = false, showWarning: Boolean = false) {
    val bodyGeometry = remember(table) { arrayOfNulls<FloatTextGeometry>(1) }
    val failure = LocalTableBlockLayoutFailure.current
    val direction = if (LocalLayoutDirection.current == LayoutDirection.Rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr
    Layout(modifier = (failure?.tableExtentModifier ?: Modifier).testTag(if (path == "root") "compiled-table-grid" else "compiled-table-grid-$path"), content = {
        if (showWarning) Text(reason)
        CompositionLocalProvider(LocalFloatTableWidthReference provides null,
            LocalFloatMarginsConsumed provides false, LocalNativeTableMarginMeasureInput provides null,
            LocalNativeDelegatedTable provides null, LocalNativeDelegatedCell provides null,
            LocalTableLineHeightPixels provides null, LocalTableBlockLayoutFailure provides null) {
        if (cells != null && sink != null) {
            val parts: List<@Composable (SelectionGeometrySink) -> Unit> = cells.map { cell ->
                { cellSink -> cell.content(cellSink) }
            }
            SelectionColumn(parts, direction, if (showWarning) { value -> bodyGeometry[0] = value } else sink)
        } else TableContentColumn(Modifier, 0.dp) {
            table.rows.flatten().forEachIndexed { index, cell ->
                when {
                    cell.blocks != null -> FloatBlockSequence(cell.blocks, onLink, "$semanticPath/cell-$index",
                        inCell = true, gridPath = "$path/$index", gapDp = 4f, trailingGap = false)
                    cell.nestedTable != null -> TableView(cell.nestedTable, onLink, "$path/$index", true, "$semanticPath/cell-$index/nested")
                    cell.spans.isNotEmpty() -> StyledText(cell.spans, onLink = onLink)
                    else -> Spacer(Modifier)
                }
            }
        }
        }
    }, measurePolicy = object : MeasurePolicy {
        private val defaultIntrinsics = this.defaultIntrinsicPolicy()
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            if (refuseIntrinsicQueries) Constraints.Infinity else measurables.last().minIntrinsicWidth(height)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            if (refuseIntrinsicQueries) Constraints.Infinity else measurables.last().maxIntrinsicWidth(height)
        override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
            if (refuseIntrinsicQueries) Constraints.Infinity else with(defaultIntrinsics) { this@minIntrinsicHeight.minIntrinsicHeight(measurables, width) }
        override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
            if (refuseIntrinsicQueries) Constraints.Infinity else with(defaultIntrinsics) { this@maxIntrinsicHeight.maxIntrinsicHeight(measurables, width) }
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
            failure?.update(reason)
            if (!showWarning) {
                val body = measurables.single().measure(constraints)
                return layout(body.width, body.height) { body.place(0, 0) }
            }
            val warning = measurables.first().measure(constraints.copy(minWidth = 0, minHeight = 0))
            val bodyMaximum = if (constraints.hasBoundedHeight) (constraints.maxHeight - warning.measuredHeight).coerceAtLeast(0)
                else Constraints.Infinity
            val body = measurables.last().measure(constraints.copy(minHeight = 0, maxHeight = bodyMaximum))
            val width = maxOf(warning.width, body.width)
            val height = nativeFallbackHeight(constraints, warning.measuredHeight.toLong() + body.measuredHeight)
            if (cells != null && sink != null) {
                val exact = bodyGeometry[0]?.takeIf { it.width == body.measuredWidth && it.height == body.measuredHeight }
                val status = NativeSemanticGroup(warning.measuredWidth, warning.measuredHeight, emptyList(),
                    extraNodes = listOf(FloatInteractionNode(0, FloatInteractionKind.MARKER, 0, 0,
                        listOf(android.graphics.RectF(0f, 0f, warning.measuredWidth.toFloat(), warning.measuredHeight.toFloat())),
                        reason, null, null)))
                sink(exact?.let { NativeSemanticGroup(width, height, listOf(
                    PositionedSemanticChild(NoPaintGeometry(it), 0f, warning.measuredHeight.toFloat(), direction),
                    PositionedSemanticChild(status, 0f, 0f, direction))) })
            }
            return layout(width, height) {
                warning.place(-(warning.width - warning.measuredWidth) / 2, -(warning.height - warning.measuredHeight) / 2)
                body.place(-(body.width - body.measuredWidth) / 2,
                    warning.measuredHeight - (body.height - body.measuredHeight) / 2)
            }
        }
    })
}

/** These actual cell owners expose synchronous height intrinsics; richer surfaces fail closed. */
internal fun pairedTableCellHasIntrinsicHeight(cell: Cell): Boolean = cell.blocks == null && cell.nestedTable == null &&
    cell.spans.all { it.ruby == null && it.inlinePaddingGroup == null && it.inlineActionGroup == null && it.inlineBoxGroup == null && it.image == null && !it.hasClassToken("wikidict-media") &&
        it.kind in setOf("text", "link", "external_link", "line_break") } && egyptianTextRuns(cell.spans).isEmpty()

/** One unchanged centered paragraph has the same real text height as a spans-only cell. */
internal fun intrinsicTableSingleParagraph(cell: Cell): Block? {
    if (cell.spans.isNotEmpty() || cell.nestedTable != null) return null
    val block = cell.blocks?.singleOrNull() ?: return null
    if (block != Block("paragraph", 0, block.spans, textAlign = CellTextAlign.Center) ||
        !block.spans.hasCompiledInlineContent() || block.spans.any { it.ruby != null || it.inlinePaddingGroup != null || it.inlineActionGroup != null || it.inlineBoxGroup != null || it.image != null ||
            it.hasClassToken("wikidict-media") || it.kind !in setOf("text", "link", "external_link", "line_break") } ||
        egyptianTextRuns(block.spans).isNotEmpty()) return null
    return block
}

@Composable
private fun TableGridView(table: Table, onLink: (EntryLink) -> Unit, path: String, widthReference: Int?, semanticPath: String,
    natural: TableRenderMetrics?, decorationProjection: Double, removeDecorations: () -> Unit,
    selectionCells: List<CaptionCellSlot>? = null, selectionGeometry: SelectionGeometrySink? = null,
    containerStyle: TextStyle? = null, contentWidths: Boolean = false,
    captionMinimumWidth: NativeLayoutInput<Int>? = null, anonymousGridStyle: TableStyle? = null,
    pairedHeightIntrinsics: Boolean = false, ownCollectionSemantics: Boolean = true) {
    val widthInput = LocalFloatTableWidthReference.current
    val resolvedWidthReference = widthInput?.value ?: widthReference
    val phaseObserver = LocalTablePhaseObserver.current
    val grid = remember(table, phaseObserver) { observeTablePhase(phaseObserver, TablePhase.Preparation) { tableGrid(table) } }
    val intrinsicTable = table.blockViewport?.intrinsicContainingDirection != null
    val pairedIntrinsicContent = !pairedHeightIntrinsics || grid.cells.all {
        pairedTableCellHasIntrinsicHeight(it.cell) || intrinsicTable && intrinsicTableSingleParagraph(it.cell) != null
    }
    val blockLayoutFailure = LocalTableBlockLayoutFailure.current.takeIf { anonymousGridStyle != null || pairedHeightIntrinsics }
    val hasCorners = anonymousGridStyle == null && table.style?.cornerRadii != null
    val separateCornerTable = table.blockViewport?.isSeparateCornerGrid == true
    val sourceSizedGrid = separateCornerTable || table.blockViewport?.intrinsicContainingDirection != null
    if (anonymousGridStyle != null && grid.cells.isEmpty() && !sourceSizedGrid) {
        val captionLineHeight = if (table.caption.isNotEmpty() || table.captionBlocks?.isNotEmpty() == true)
            tableLineHeightPixels(table, containerStyle ?: inheritedContainerBodyStyle(), anonymousGridStyle) else null
        val failure = if (captionLineHeight != null &&
            (!captionLineHeight.isFinite() || captionLineHeight <= 0f || captionLineHeight > TablePixelLimit))
            "Anonymous table caption line height exceeds native geometry" else null
        Layout(modifier = (widthInput?.tableExtentModifier ?: Modifier)
            .then(blockLayoutFailure?.tableExtentModifier ?: Modifier)
            .testTag(if (path == "root") "compiled-table-grid" else "compiled-table-grid-$path"), content = { },
            measurePolicy = object : MeasurePolicy {
                override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = 0
                override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = 0
                override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                    blockLayoutFailure?.update(failure)
                    selectionGeometry?.invoke(NativeSemanticGroup(0, 0, emptyList()))
                    return layout(0, 0) { }
                }
            })
        return
    }
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
    if (table.style?.minWidth == null && !hasCorners && !pairedHeightIntrinsics && anonymousGridStyle == null && natural == null && decorationProjection > 0.0 && tableContainsStyle(table) && !tableHasComputedCellStyle(table)) {
        LaunchedEffect(table, decorationProjection) { removeDecorations() }
        return
    }
    if (natural == null) {
        if (table.style?.minWidth != null) {
            UnavailableAnonymousGrid(table, onLink, path, semanticPath, selectionCells, selectionGeometry,
                "Table minimum-width layout is unavailable. Table content is retained.",
                refuseIntrinsicQueries = true, showWarning = true)
            return
        }
        if (hasCorners) {
            UnavailableAnonymousGrid(table, onLink, path, semanticPath, selectionCells, selectionGeometry,
                "Authored table corner geometry is unavailable. Table content is retained.",
                refuseIntrinsicQueries = pairedHeightIntrinsics, showWarning = true)
            return
        }
        if (anonymousGridStyle != null || pairedHeightIntrinsics) {
            UnavailableAnonymousGrid(table, onLink, path, semanticPath, selectionCells, selectionGeometry,
                "Anonymous table grid exceeds native geometry", refuseIntrinsicQueries = pairedHeightIntrinsics)
            return
        }
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
    val cornerDecoration = remember(styled) { styled?.cornerRadii?.let { corners ->
        NativeContainerDecoration(canonicalColorArgb(styled.background)?.toInt(),
            canonicalColorArgb(styled.border.color)?.toInt(), styled.border.width, nativeCorners = corners)
    } }
    val cellBaselinePolicy = LocalNativeContainerTextContext.current?.cellText != null ||
        grid.cells.any { it.cell.style?.lineHeight != null || it.cell.style?.verticalAlign == CellVerticalAlign.Middle }
    val lineHeightPixels = tableLineHeightPixels(table, containerStyle ?: inheritedContainerBodyStyle(),
        anonymousGridStyle ?: table.style)
    if (lineHeightPixels != null && (!lineHeightPixels.isFinite() || lineHeightPixels <= 0f || lineHeightPixels > TablePixelLimit)) {
        if (table.style?.minWidth != null) {
            UnavailableAnonymousGrid(table, onLink, path, semanticPath, selectionCells, selectionGeometry,
                "Table line height exceeds native geometry. Table content is retained.",
                refuseIntrinsicQueries = true, showWarning = true)
            return
        }
        if (hasCorners) {
            UnavailableAnonymousGrid(table, onLink, path, semanticPath, selectionCells, selectionGeometry,
                "Authored table corner geometry is unavailable because its line height exceeds native geometry. Table content is retained.",
                refuseIntrinsicQueries = pairedHeightIntrinsics, showWarning = true)
            return
        }
        if (anonymousGridStyle != null || pairedHeightIntrinsics) {
            UnavailableAnonymousGrid(table, onLink, path, semanticPath, selectionCells, selectionGeometry,
                "Anonymous table line height exceeds native geometry", refuseIntrinsicQueries = pairedHeightIntrinsics)
            return
        }
        Text("Table line height is too large to display.")
        return
    }
    val widthModifier = if (table.style?.minWidth != null || table.style?.marginValues != null || captionMinimumWidth != null)
        widthInput?.tableExtentModifier ?: Modifier else widthInput?.modifier ?: Modifier
    Layout(modifier = widthModifier.then(captionMinimumWidth?.tableExtentModifier ?: Modifier)
        .then(blockLayoutFailure?.tableExtentModifier ?: Modifier)
        .testTag(if (path == "root") "compiled-table-grid" else "compiled-table-grid-$path")
        .onGloballyPositioned { coordinates ->
            delegated?.let { it.gridCoordinates = coordinates; it.validateAfterPlacement() }
        }
        .then(if (ownCollectionSemantics) Modifier.semantics {
            collectionInfo = androidx.compose.ui.semantics.CollectionInfo(grid.rows, grid.columns)
        } else Modifier)
        .drawWithCache {
            // Measurement publishes paint geometry. Observe it in the draw cache,
            // not composition: opening a large table must not schedule a second
            // composition merely to calculate its collapsed border segments.
            val pixels = drawingPixels
            val rounded = cornerDecoration
            val collapsedBorders = observeTablePhase(phaseObserver, TablePhase.DrawCache) {
                if (pixels != null && styled?.collapse == true)
                    collapsedTableBorders(grid, pixels, styled).flatMap(::tableBorderBands) else emptyList()
            }
            onDrawBehind {
            observeTablePhase(phaseObserver, TablePhase.Draw) {
            if (pixels != null) {
            val tableBackground = styled?.background?.let { canonicalColorArgb(it)?.let { argb -> Color(argb) } }
            if (rounded == null) tableBackground?.let { drawRect(it) }
            else rounded.paint(drawContext.canvas.nativeCanvas,
                android.graphics.RectF(0f, 0f, pixels.width.toFloat(), pixels.height.toFloat()), paintBorder = false)
            grid.cells.forEachIndexed { index, placed ->
                val cellWidth = pixels.cellWidth(placed.colspan, placed.column)
                val left = pixels.physicalCellLeft(placed.column, placed.colspan, layoutDirection == LayoutDirection.Rtl)
                val top = pixels.cellTop(placed.row)
                val bottom = pixels.cellBottom(placed.row, placed.cell.rowspan)
                val background = authoredColors[index] ?: if (rounded != null && tableBackground != null) null
                    else tableBackground ?: if (anonymousGridStyle != null) null
                    else inheritedColor ?: if (placed.cell.header) headerColor else cellColor
                background?.let { drawRect(it,
                    topLeft = Offset(left.toFloat(), top.toFloat()), size = Size(cellWidth.toFloat(), (bottom - top).toFloat())) }
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
            } else if (rounded != null) {
                rounded.paint(drawContext.canvas.nativeCanvas,
                    android.graphics.RectF(0f, 0f, pixels.width.toFloat(), pixels.height.toFloat()), paintBackground = false)
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
                    val paragraph = if (intrinsicTable) intrinsicTableSingleParagraph(placed.cell) else null
                    if (selection != null) selection.content { selection.geometry = it }
                    else if (paragraph != null) BlockView(paragraph, onLink, "$cellPath/block-0", inCell = true,
                        gridPath = "$path/$index/block-0")
                    else if (blocks != null) FloatBlockSequence(blocks, onLink, cellPath, inCell = true,
                        gridPath = "$path/$index", gapDp = 4f, trailingGap = false)
                    else {
                        val child = placed.cell.nestedTable
                        if (child == null && (pairedHeightIntrinsics || separateCornerTable || anonymousGridStyle != null || cellContext?.cellText != null ||
                            placed.cell.style?.verticalAlign == CellVerticalAlign.Middle) && placed.cell.spans.isEmpty()) Spacer(Modifier)
                         else if (child == null) StyledText(placed.cell.spans, onLink = onLink)
                        else TableView(child, onLink, "$path/$index", nested = true, semanticPath = "$cellPath/nested")
                    }
                }
            }
        }
        }
        NativeLayoutMessage(fallbackMessage)
    }, measurePolicy = object : MeasurePolicy {
        private val defaultIntrinsics = this.defaultIntrinsicPolicy()
        private fun minimumWidth(containing: Int?, intrinsic: Boolean = false): Float? {
            val value = table.style?.minWidth ?: return null
            if (anonymousGridStyle != null || table.blockViewport != null || table.floatViewport != null)
                throw UnsupportedFloatLayout("Table minimum width is unavailable in this viewport policy")
            // Zero is only the known intrinsic contribution; the original percentage
            // still resolves against its actual containing width during measurement.
            if (intrinsic && value.unit == StyleWidthUnit.Percent) return 0f
            return tableMinimumWidthPixels(value, density.density, fontPixels, containing)
        }
        private fun intrinsicWidth(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
            if (!pairedIntrinsicContent) return Constraints.Infinity
            if (sourceSizedGrid && grid.cells.isEmpty()) return natural.width
            val cells = measurables.take(grid.cells.size)
            val minimum = try { minimumWidth(null, intrinsic = true) }
                catch (_: UnsupportedFloatLayout) { return Constraints.Infinity }
            val css = if (anonymousGridStyle == null) table.style?.width else null
            val legacy = table.geometry?.width.takeIf { anonymousGridStyle == null && css == null }
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
                    density.density, fontPixels), minimumWidth = minimum)
            return result?.width ?: Constraints.Infinity
        }

        private fun pairedMetrics(cells: List<IntrinsicMeasurable>, available: Int, containing: Int): TableRenderMetrics? {
            if (!pairedIntrinsicContent || cells.size != grid.cells.size ||
                available !in 0..TablePixelLimit || containing !in 0..TablePixelLimit) return null
            val css = table.style?.width.takeIf { anonymousGridStyle == null }
            val requested = when (css?.unit) {
                StyleWidthUnit.Px -> css.value.toDouble() * density.density
                StyleWidthUnit.Em -> css.value.toDouble() * fontPixels
                StyleWidthUnit.Percent -> css.value.toDouble() * containing / 100.0
                null -> null
            }
            if (requested != null && (!requested.isFinite() || requested !in 0.0..TablePixelLimit.toDouble())) return null
            if (sourceSizedGrid && grid.cells.isEmpty()) return natural
            val minimum = try { minimumWidth(containing) } catch (_: UnsupportedFloatLayout) { return null }
            return inlineTableMetrics(natural, grid,
                IntArray(cells.size) { cells[it].minIntrinsicWidth(Constraints.Infinity) },
                IntArray(cells.size) { cells[it].maxIntrinsicWidth(Constraints.Infinity) },
                available, requested?.let { kotlin.math.round(it).toInt() },
                tableCellWidthPreferences(grid, styled?.cellInsets, 2 * (natural.cellPadding + natural.borderWidth),
                    density.density, fontPixels), captionMinimumWidth = captionMinimumWidth?.value ?: 0,
                minimumWidth = minimum)
        }

        private fun pairedHeight(measurables: List<IntrinsicMeasurable>, width: Int): Int {
            if (!pairedIntrinsicContent || width !in 0..TablePixelLimit) return Constraints.Infinity
            val cells = measurables.take(grid.cells.size)
            val metrics = pairedMetrics(cells, width, widthInput?.value ?: widthReference ?: width)
                ?: return Constraints.Infinity
            val heights = IntArray(cells.size) { index ->
                val placed = grid.cells[index]
                cells[index].maxIntrinsicHeight(metrics.cellWidth(placed.column, placed.colspan))
            }
            return tablePixelLayout(grid, metrics.columnWidth, metrics.minRowHeight, heights,
                metrics.cellSpacing, metrics.borderWidth, metrics.width, metrics.extraColumns,
                metrics.style?.tablePadding ?: TablePixelInsets(0, 0, 0, 0), metrics.columnWidths, metrics.outerBorder,
                anonymousGrid = anonymousGridStyle != null, pairedGrid = true)?.height ?: Constraints.Infinity
        }

        override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
            if (pairedHeightIntrinsics) pairedHeight(measurables, width) else with(defaultIntrinsics) { this@minIntrinsicHeight.minIntrinsicHeight(measurables, width) }
        override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
            if (pairedHeightIntrinsics) pairedHeight(measurables, width) else with(defaultIntrinsics) { this@maxIntrinsicHeight.maxIntrinsicHeight(measurables, width) }

        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            intrinsicWidth(measurables, false)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            intrinsicWidth(measurables, true)

        override fun MeasureScope.measure(measurables: List<Measurable>, incoming: Constraints): MeasureResult {
        blockLayoutFailure?.update(null)
        val cells = measurables.take(grid.cells.size)
        val reference = widthInput?.value?.takeUnless { table.style?.minWidth != null && it < 0 }
            ?: widthReference ?: incoming.maxWidth.takeIf { incoming.hasBoundedWidth }
        // An unavailable real containing input must not fall back to the viewport's
        // arbitrary unbounded limit or to its already margin-reduced available lane.
        val minimumContaining = if (widthInput != null) widthInput.value.takeIf { it in 0..TablePixelLimit }
            else reference
        val minimum = try { minimumWidth(minimumContaining) } catch (_: UnsupportedFloatLayout) { null }
        val minimumUnavailable = table.style?.minWidth != null && minimum == null
        val metrics = if (minimumUnavailable) null else if (sourceSizedGrid && grid.cells.isEmpty()) {
            if (anonymousGridStyle != null) natural else tableMetricsInWidth(table, natural, grid.columns, reference)
        } else if (pairedHeightIntrinsics) {
            val available = widthReference ?: incoming.maxWidth.takeIf { incoming.hasBoundedWidth } ?: TablePixelLimit
            pairedMetrics(cells, available, reference ?: available)
        } else if (contentWidths || table.style?.isInline == true) {
            if (!contentWidths) check(selectionCells == null && table.rows.all { row -> row.all(::inlineTableCellShape) })
            val available = widthReference ?: incoming.maxWidth.takeIf { incoming.hasBoundedWidth } ?: TablePixelLimit
            val containing = reference ?: available
            val cssWidth = if (anonymousGridStyle == null) table.style?.width else null
            val legacyWidth = table.geometry?.width.takeIf { anonymousGridStyle == null && cssWidth == null }
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
                    density.density, fontPixels), captionMinimumWidth = captionMinimumWidth?.value ?: 0,
                minimumWidth = minimum)
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
             metrics.width, metrics.extraColumns, metrics.style?.tablePadding ?: TablePixelInsets(0, 0, 0, 0), metrics.columnWidths, metrics.outerBorder,
             anonymousGrid = anonymousGridStyle != null, pairedGrid = pairedHeightIntrinsics || sourceSizedGrid)
        }
        val cornerFailure = if (pixels != null && cornerDecoration != null) try {
            cornerDecoration.prepareCorners(android.graphics.RectF(0f, 0f, pixels.width.toFloat(), pixels.height.toFloat()))
            null
        } catch (error: UnsupportedFloatLayout) { error } else null
        return if (pixels == null || cornerFailure != null) {
            if (anonymousGridStyle != null || pairedHeightIntrinsics) blockLayoutFailure?.update(
                if (hasCorners) "Authored table corner geometry is unavailable at this size" else "Anonymous table grid is unavailable at this size")
            drawingPixels = null
            if (table.style?.minWidth == null && !hasCorners && anonymousGridStyle == null && decorationProjection > 0.0 && tableContainsStyle(table) && !tableHasComputedCellStyle(table)) removeDecorations()
            // Keep the existing cells visible in an explicitly unavailable grid.
            // A later width change measures these same owners again, without
            // replacing active media or latching a composition-only error state.
            val width = (reference ?: incoming.maxWidth).coerceIn(0, TablePixelLimit)
            fallbackMessage.update(if (hasCorners) "Authored table corner geometry is unavailable at this size. Table content is retained."
                else "Table layout is unavailable at this size.")
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
                val status = if (hasCorners) listOf(PositionedSemanticChild(NativeSemanticGroup(
                    warning.measuredWidth, warning.measuredHeight, emptyList(), extraNodes = listOf(FloatInteractionNode(
                        0, FloatInteractionKind.MARKER, 0, 0, listOf(android.graphics.RectF(0f, 0f,
                            warning.measuredWidth.toFloat(), warning.measuredHeight.toFloat())), fallbackMessage.value, null, null))),
                    (warning.width - warning.measuredWidth) / 2f, (warning.height - warning.measuredHeight) / 2f,
                    if (layoutDirection == LayoutDirection.Rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr)) else emptyList()
                selectionGeometry(if (selected.size == selectionCells.size) NativeSemanticGroup(width, height, selected + status) else null)
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
            val cellContentOffsets = children.indices.map { index ->
                tableCellContentOffset(pixels, grid.cells[index], children[index].height,
                    grid.cells[index].cell.style?.verticalAlign)
            }
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
                    grid.cells.mapIndexed { index, placed -> pixels.cellTop(placed.row) + cellContentOffsets[index] })
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
                        pixels.cellTop(placed.row) + insets.top + cellContentOffsets[index],
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
                        value.takeUnless { it == androidx.compose.ui.layout.AlignmentLine.Unspecified }?.let {
                            (pixels.cellTop(placed.row) + cellContentOffsets[index] + it).roundToInt()
                        }
                    }
                }.maxOrNull()
                mapOf(androidx.compose.ui.layout.FirstBaseline to (baseline(true) ?: pixels.cellBottom(0, 1)),
                    androidx.compose.ui.layout.LastBaseline to (baseline(false) ?: pixels.height))
            } else emptyMap()
            layout(pixels.width, pixels.height, lines) {
                children.forEachIndexed { index, child ->
                    val placed = grid.cells[index]
                    val left = pixels.physicalCellLeft(placed.column, placed.colspan, layoutDirection == LayoutDirection.Rtl)
                    val offset = cellContentOffsets[index]
                    if (offset == 0f) child.place(left, pixels.cellTop(placed.row))
                    else {
                        val top = pixels.cellTop(placed.row) + offset
                        val integralTop = kotlin.math.floor(top).toInt()
                        child.placeWithLayer(left, integralTop) { translationY = top - integralTop }
                    }
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

internal val LocalAuthoredInlineNative = staticCompositionLocalOf { true }
internal val LocalRubyNative = staticCompositionLocalOf { true }

/** Resolve a complete declaring font from the original typography context, never a descendant Paint. */
@Composable
internal fun inlineFontSnapshotAnnotation(snapshot: InlineFontSnapshot, style: TextStyle): AnnotatedString =
    styledTextAnnotation(listOf(inlineFontSnapshotSpan(snapshot)), null, style) { }

@Composable
internal fun inlineMetricOwnerAnnotation(span: Span, style: TextStyle): AnnotatedString =
    styledTextAnnotation(listOf(inlineMetricOwnerSpan(span)), null, style) { }

@Composable
internal fun StyledText(source: List<Span>, modifier: Modifier = Modifier, weight: FontWeight? = null, style: TextStyle = inheritedContainerBodyStyle(), onLink: (EntryLink) -> Unit = {}, preserveWhitespace: Boolean = false) {
    val nativeRuby = LocalRubyNative.current
    if (source.hasNativeInlineGroups() && !nativeRuby) {
        StyledText(rubyFallbackSpans(source), modifier, weight, style, onLink,
            preserveWhitespace = true)
        return
    }
    val compiledDirection = compiledBodyParagraphDirection(LocalCompiledTableTextDirection.current,
        LocalNativeContainerTextContext.current?.bodyDirection, LocalNativeColumnTextDirection.current) ?: TextDirection.Content
    val cellTextAlign = LocalCellTextAlign.current
    val lineHeightPixels = LocalTableLineHeightPixels.current
    val density = LocalDensity.current
    val inheritedStyle = inheritedCellTextStyle(style)
    val childStyle = LocalNativeContainerTextContext.current?.takeIf { it.containerText != null }?.let {
        nativeContainerTextFormat(it, MaterialTheme.typography.bodyLarge.fontSize, inheritedStyle, density).style
    } ?: inheritedStyle
    val renderedStyle = if (lineHeightPixels == null) childStyle else childStyle.copy(lineHeight = with(density) { lineHeightPixels.toSp() })
    val sourceFamily = LocalNativeContainerTextContext.current?.fontFamily
    val sourceFontStack = sourceFamily is ContainerFontFamily.Stack
    val authoredFamily = sourceFontStack || source.hasAuthoredFontFamily()
    val containerWrap = LocalNativeContainerTextWrap.current
    val preserveOwner = preserveWhitespace || authoredFamily || source.hasNativeInlineGroups() || containerWrap == TextWrap.NoWrap
    val spans = if (source.hasNativeInlineGroups()) source else
        remember(source, preserveOwner) { if (preserveOwner) source else compactSpans(source) }
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
    if (authoredFamily && !source.hasCompiledInlineContent()) return
    val linkColor = MaterialTheme.colorScheme.primary
    val cache = LocalTextCache.current
    val currentLink = rememberUpdatedState(onLink)
    val inheritedBackground = LocalAuthoredBackground.current
    val annotated = styledTextAnnotation(spans, weight, renderedStyle, onLink)
    val egyptianRuns = remember(spans) { egyptianTextRuns(spans) }
    val containerFormat = inheritedContainerFormat()
    val sourceLinkPaint = spans.any { it.linkPaint != null }
    val nativeLinkPaint = LocalOrdinaryLinkPaintNative.current
    val sourceInlineStyle = spans.any { it.inlineStyle != null }
    val sourceRuby = spans.hasNativeInlineGroups()
    val sourceImageOccurrence = spans.any { it.image?.occurrenceLayout != null }
    val terminalImageFallback = sourceImageOccurrence && LocalInlineImageOccurrenceFallback.current
    val sourceInlineFamily = spans.hasAuthoredFontFamily()
    val nativeInlineStyle = LocalAuthoredInlineNative.current
    if (sourceLinkPaint && nativeLinkPaint && ordinaryLinkPaintUnavailable(spans.filter { it.inlinePaddingGroup == null && it.inlineActionGroup == null && it.inlineBoxGroup == null }) != null) {
        Column(modifier) {
            Text(NativeOrdinaryLinkPaintUnavailable)
            CompositionLocalProvider(LocalOrdinaryLinkPaintNative provides false,
                LocalRubyNative provides (nativeRuby && !sourceRuby)) {
                StyledText(source, weight = weight, style = style, onLink = onLink, preserveWhitespace = preserveWhitespace)
            }
        }
        return
    }
    if (!terminalImageFallback && (sourceImageOccurrence || nativeRuby && (sourceRuby || (containerWrap != null && nativeInlineStyle || containerFormat != null || sourceLinkPaint || sourceInlineStyle || sourceFontStack || sourceInlineFamily) &&
        (!sourceLinkPaint || nativeLinkPaint) && (!(sourceInlineStyle || sourceFontStack || sourceInlineFamily) || nativeInlineStyle)))) {
        val native = prepareNativeFloatText(spans, annotated, egyptianRuns,
            renderedStyle.copy(textDirection = compiledDirection, textAlign = cellTextAlign ?: style.textAlign),
            linkColor, availableMedia, LocalReaderSettings.current, LocalEntryEdition.current, onLink,
            nativeLineHeight = lineHeightPixels?.let { NativeLineHeightPolicy.Pixels(it) } ?: containerFormat?.lineHeight,
            sourceFamily = sourceFamily, ownerFont = containerFormat?.ownerFont, rubyWeight = weight,
            ownerWrap = containerWrap.takeIf { nativeInlineStyle })
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
            renderedStyle.copy(textDirection = compiledDirection, textAlign = cellTextAlign ?: style.textAlign), linkColor, inlineContent)
    }
}

@Composable
internal fun styledTextAnnotation(spans: List<Span>, weight: FontWeight?, style: TextStyle,
    onLink: (EntryLink) -> Unit): AnnotatedString {
    val ruby = rubyStyledTextContexts(spans, weight, style)
    return if (ruby == null) ordinaryStyledTextAnnotation(spans, weight, style, onLink)
        else rubyStyledTextAnnotation(ruby, weight, onLink)
}

@Composable
internal fun styledTextAnnotationWithoutDirectionControls(spans: List<Span>, weight: FontWeight?, style: TextStyle,
    onLink: (EntryLink) -> Unit): AnnotatedString =
    ordinaryStyledTextAnnotation(spans, weight, style, onLink, directionControls = false)

@Composable
private fun ordinaryStyledTextAnnotation(spans: List<Span>, weight: FontWeight?, style: TextStyle,
    onLink: (EntryLink) -> Unit, directionControls: Boolean = true): AnnotatedString {
    val effectiveWeight = weight ?: LocalCellWeight.current
    val normalBodySize = MaterialTheme.typography.bodyLarge.fontSize
    val contextSize = LocalTextStyle.current.merge(style).fontSize
    val textDensity = LocalDensity.current
    val linkColor = MaterialTheme.colorScheme.primary
    val codeColor = MaterialTheme.colorScheme.surfaceContainer
    val cache = LocalTextCache.current.takeIf { directionControls }
    val currentLink = rememberUpdatedState(onLink)
    val layoutDirection = LocalLayoutDirection.current
    val compiledTableDirection = LocalCompiledTableTextDirection.current
    val bodyDirection = LocalNativeContainerTextContext.current?.bodyDirection
    val columnDirection = LocalNativeColumnTextDirection.current
    val compiledTableLanguage = LocalCompiledTableSourceLanguage.current
    val inheritedBackground = LocalAuthoredBackground.current
    val inheritedForeground = LocalFigureCaptionForeground.current
    val cellLetterSpacing = LocalCellLetterSpacingPixels.current
    val cssPixelTextZoom = LocalCssPixelTextZoom.current
    val inheritedStack = LocalNativeContainerTextContext.current?.fontFamily?.takeIf { it is ContainerFontFamily.Stack }
    val authoredPreformatted = LocalNativePreformattedText.current && (inheritedStack != null || spans.hasAuthoredFontFamily())
    val inheritedFamily = inheritedStack.takeUnless { authoredPreformatted }
    val computedContainerTraits = LocalNativeContainerTextContext.current?.containerText != null
    val computedCellTraits = LocalNativeContainerTextContext.current?.cellText != null || computedContainerTraits
    val bodyFamily = (if (computedContainerTraits) LocalTextStyle.current.merge(style).fontFamily
        else MaterialTheme.typography.bodyLarge.fontFamily) ?: FontFamily.Default
    val cacheKey = TextCacheKey(effectiveWeight, layoutDirection, inheritedBackground, normalBodySize, contextSize, textDensity, inheritedForeground, cellLetterSpacing, cssPixelTextZoom, computedCellTraits, bodyFamily.takeIf { computedCellTraits }, compiledTableDirection, compiledTableLanguage, inheritedFamily, authoredPreformatted, computedContainerTraits, bodyDirection, columnDirection)
    val annotated = remember(spans, directionControls, effectiveWeight, linkColor, codeColor, cache, layoutDirection, inheritedBackground, normalBodySize, contextSize, textDensity, inheritedForeground, cellLetterSpacing, cssPixelTextZoom, computedCellTraits, computedContainerTraits, bodyFamily, compiledTableDirection, compiledTableLanguage, inheritedFamily, authoredPreformatted, bodyDirection, columnDirection) {
        cache?.values?.get(spans)?.get(cacheKey) ?: buildAnnotatedString {
            val appendedSpans = ArrayList<Pair<Span, IntRange>>(spans.size)
            spans.forEachIndexed { index, span ->
                val effectiveBackground = span.background ?: inheritedBackground.takeIf { !span.code }
                val foreground = (canonicalColorArgb(span.linkPaint?.normal?.foreground ?: span.foreground)?.toInt() ?: inheritedForeground ?:
                    authoredSpanForegroundArgb(null, effectiveBackground)?.toInt())?.let { Color(it) }
                val background = canonicalColorArgb(span.background)?.let { Color(it) }
                val readableLinkFallback = span.linkPaint == null && canonicalColorArgb(span.foreground) == null && canonicalColorArgb(effectiveBackground) != null
                val linkStyle = span.linkPaint?.let { policy ->
                    // Native draw state owns interaction; an explicit unavailable projection retains normal paint.
                    TextLinkStyles(style = SpanStyle(color = Color(checkNotNull(canonicalColorArgb(policy.normal.foreground))),
                        textDecoration = if (policy.normal.underline) TextDecoration.Underline else TextDecoration.None))
                } ?: TextLinkStyles(style = SpanStyle(color = foreground ?: linkColor,
                    textDecoration = if (readableLinkFallback) TextDecoration.Underline else null),
                    pressedStyle = SpanStyle(textDecoration = TextDecoration.Underline))
                val start = length
                if (directionControls && span.usesInlineDirectionIsolate()) when (span.direction) {
                    "rtl" -> append('\u2067')
                    "ltr" -> append('\u2066')
                    "auto" -> append('\u2068')
                }
                val displayText = if (span.image != null) InlineImageReplacement else if (span.kind == "line_break") "\n" else span.text
                val contentStart = length
                if (span.image != null) appendInlineContent("compiled-image-$index", InlineImageReplacement) else append(displayText)
                append(span.trail)
                if (directionControls && span.usesInlineDirectionIsolate()) append('\u2069')
                val end = length
                appendedSpans.add(span to (start until end))
                if (end > start) {
                    val languageTag = spanLanguageTag(span.language)
                    val fontFamily = span.fontFamily?.let(::nativeTerminalFontFamily) ?: when (span.legacyFontFamily()) {
                        LegacySpanFontFamily.Code -> FontFamily.Monospace
                        LegacySpanFontFamily.Egyptian -> EgyptianFontFamily
                        null -> if (authoredPreformatted) FontFamily.Monospace else
                            inheritedFamily?.let(::nativeTerminalFontFamily) ?: if (computedCellTraits) bodyFamily else null
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
                        baselineShift = when { span.superscript -> BaselineShift.Superscript; span.subscript -> BaselineShift.Subscript;
                            computedContainerTraits -> BaselineShift.None; else -> null },
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
            compiledBodyParagraphDirection(compiledTableDirection, bodyDirection, columnDirection)?.let {
                addStyle(ParagraphStyle(textDirection = it), 0, length)
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

internal fun CellTextAlign.composeAlign(): androidx.compose.ui.text.style.TextAlign = when (this) {
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

internal val LocalFloatTableWidthReference = staticCompositionLocalOf<NativeLayoutInput<Int>?> { null }
internal val LocalFloatMarginsConsumed = staticCompositionLocalOf { false }

private fun nativeTableConsumesMargins(table: Table?, blockViewport: TableBlockViewport? = null): Boolean =
    table?.floatViewport != null || table?.blockViewport?.isSeparateCornerGrid == true || table?.blockViewport?.intrinsicContainingDirection != null || (blockViewport?.boxStyle ?: table?.style)?.let {
    !it.isInline && (it.marginValues != null || it.floatSide != null || it.clear != null && it.clear != FigureClear.None)
} == true

@Composable
private fun FloatBlockSequence(blocks: List<Block>, onLink: (EntryLink) -> Unit, path: String,
    modifier: Modifier = Modifier, inCell: Boolean = false, gridPath: String = "root", gapDp: Float,
    trailingGap: Boolean) {
    val delegatedOwner = LocalNativeDelegatedCell.current
    val delegatedSource = delegatedOwner?.sourceBlock
    val absoluteCell = nativeDelegatedAbsoluteCell(delegatedOwner, blocks)
    if (blocks.needsNativeBlockSequence(delegatedSource)) {
        // The real expanded cell surface still needs the delegated post-placement proof.
        // Do not allocate its out-of-flow ink as normal cell/document height.
        NativeFloatBlockContext(blocks, onLink, path, modifier, inCell, gridPath, gapDp, trailingGap,
            fixedHeightReachable = absoluteCell != null, positionedPaintRoot = absoluteCell != null)
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
    fixedHeightReachable: Boolean = false, positionedPaintRoot: Boolean = false,
    bodyAdjoining: BodyAdjoiningPolicy? = null, bodyTextContext: ContainerTextContext? = null) {
    val density = LocalDensity.current
    val contentWidths = LocalTableContentWidths.current
    val inheritedAlign = LocalCellTextAlign.current
    val inheritedLineHeight = LocalTableLineHeightPixels.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val normalBodySize = MaterialTheme.typography.bodyLarge.fontSize
    val localContext = LocalNativeContainerTextContext.current
    val excludedContext = nativeWithoutBodyTextContext(localContext, normalBodySize, density)
    val inheritedContainer = inheritedContainerFormat(excludedContext)
    val baseStyle = inheritedCellTextStyle(inheritedContainer?.style ?: MaterialTheme.typography.bodyLarge).let { style ->
        if (inheritedLineHeight == null) style else style.copy(lineHeight = with(density) { inheritedLineHeight.toSp() })
    }
    val fontPixels = with(density) { baseStyle.fontSize.toPx() }
    val windowHeight = LocalWindowInfo.current.containerSize.height.takeIf { it > 0 }
    val documentViewport = tableDocumentViewportCssWidth()
    val linkColor = MaterialTheme.colorScheme.primary
    val media = LocalEntryMedia.current
    val mediaOwners = LocalEntryMediaOwners.current
    val settings = LocalReaderSettings.current
    val edition = LocalEntryEdition.current
    val normalBodyPixels = with(density) { normalBodySize.toPx() }
    val rootLineHeight = when {
        baseStyle.lineHeight.isSp -> ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px,
            baseStyle.lineHeight.value * density.fontScale))
        baseStyle.lineHeight.isEm -> ContainerLineHeight.Multiplier(baseStyle.lineHeight.value)
        else -> ContainerLineHeight.Normal
    }
    val rootContext = (bodyTextContext ?: localContext)?.let { context ->
        if (inheritedLineHeight == null) context else context.copy(lineHeight = rootLineHeight,
            cellText = context.cellText?.copy(lineHeight = NativeLineHeightPolicy.Pixels(inheritedLineHeight)),
            containerText = context.containerText?.copy(lineHeight = NativeLineHeightPolicy.Pixels(inheritedLineHeight)),
            resolvedLineHeight = NativeLineHeightPolicy.Pixels(inheritedLineHeight),
            bodyOrigin = context.bodyOrigin?.copy(lineHeightInherited = false))
    } ?: ContainerTextContext(if (normalBodySize.value == 0f) 1f else
        baseStyle.fontSize.value / normalBodySize.value, rootLineHeight)
    val absoluteCell = nativeDelegatedAbsoluteCell(LocalNativeDelegatedCell.current, blocks)
    val sourceIds = remember { linkedMapOf<String, Int>() }
    fun sourceId(key: String): Int = sourceIds.getOrPut(key) { sourceIds.size }
    val mediaControls = mutableMapOf<Int, List<Media>>()
    val mediaLeaves = mutableMapOf<Int, NativeContainerLeaf>()
    val originalChildren = mutableMapOf<Int, NativeContainerLeaf>()
    val leafBoxes = mutableMapOf<Int, ParagraphBox?>()
    val gaps = blocks.indices.map { index ->
        if (blocks[index].ruleStyle == null && (trailingGap || index + 1 < blocks.size))
            (gapsDp?.get(index) ?: gapDp) * density.density else 0f
    }
    val ruleDarkTheme = LocalReaderDarkTheme.current
    val originalParts = prepareNativeContainerTree(blocks, path, gridPath, blockPaths, gaps, rootContext,
        baseStyle, figureInheritedAlign(inheritedAlign, LocalLayoutDirection.current), normalBodySize,
        density, documentViewport,
        rtl, LocalReaderDarkTheme.current, documentSurface || fixedHeightReachable, ::sourceId,
        positionedPaintReachable = positionedPaintRoot, staticInlineAlign = inheritedAlign) { leaf ->
        val block = leaf.block
        val index = leaf.id
        val gap = leaf.gap
        val section = leaf.rootIndex?.let { sectionRows[it]?.heading }
        val authoredHeading = section?.headingStyle
        if (authoredHeading != null) {
            val headingParts = mutableListOf<NativeFloatContextSpec>()
            val background = when (val value = authoredHeading.box.background) {
                is ContainerColor.Rgb -> value.value
                is ContainerColor.LightDark -> if (LocalReaderDarkTheme.current) value.dark else value.light
                null, ContainerColor.Transparent -> LocalAuthoredBackground.current
            }
            val direction = if (authoredHeading.direction == BidiResolvedDirection.Rtl) LayoutDirection.Rtl else LayoutDirection.Ltr
            CompositionLocalProvider(LocalLayoutDirection provides direction,
                LocalAuthoredBackground provides background, LocalCaptionBreakWord provides true) {
                val result = nativeSectionHeadingTextFormat(authoredHeading, normalBodySize, baseStyle, density)
                val format = result.getOrNull()
                // The producer already compiled this title's whitespace and action boundaries.
                val spans = block.spans
                val style = (format?.style ?: baseStyle).copy(textAlign =
                    authoredHeading.box.textAlign?.composeAlign() ?: inheritedAlign ?: androidx.compose.ui.text.style.TextAlign.Unspecified)
                val annotated = styledTextAnnotation(spans, null, style, onLink)
                val prepared = prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), style,
                    linkColor, media, settings, edition, onLink, heading = true,
                    headingActions = leaf.rootIndex?.let { sectionActions[it] }.orEmpty(),
                    nativeLineHeight = format?.lineHeight, authoredHeading = true,
                    sourceFamily = format?.sourceFamily, ownerDirection = authoredHeading.direction, headingLabel = checkNotNull(section).title,
                    ownerWrap = authoredHeading.titleWrap)
                val child = NativeFloatContextSpec.Text(prepared, 0f, leaf.path,
                    ParagraphBox(ParagraphEdges(), ParagraphEdges(), 0f, 0f))
                val owner = nativeSectionHeadingSpec(sourceId(leaf.path + "/section-heading"),
                    authoredHeading, child, density.density, normalBodyPixels, LocalReaderDarkTheme.current)
                val failure = result.exceptionOrNull()?.message
                headingParts += if (failure == null) owner else owner.copy(unavailableReason = failure)
            }
            return@prepareNativeContainerTree headingParts
        }
        val previous = leaf.previous?.takeIf {
            leaf.rootIndex == null || sectionKeys == null || leaf.rootIndex == 0 ||
                sectionKeys[leaf.rootIndex] == sectionKeys[leaf.rootIndex - 1]
        }
        val format = leaf.format ?: inheritedContainer.takeUnless { leaf.bodyTypographyExcluded }
        val preserveCompiledText = leaf.ownerWrap == TextWrap.NoWrap || format?.ownerFont != null ||
            format?.sourceFamily is ContainerFontFamily.Stack
        var paragraphFailure: String? = null
        val box = try {
            paragraphBox(block, previous, gap, density.density,
                if (leaf.inContainer || leaf.bodyTypographyExcluded && block.kind == "heading") normalBodyPixels else fontPixels,
                preserveCompiledText = preserveCompiledText)
        } catch (error: UnsupportedFloatLayout) {
            paragraphFailure = error.message ?: "Paragraph layout unavailable at this size"
            null
        }
        leafBoxes[index] = box
        val heading = block.kind == "heading"
        val actions = leaf.rootIndex?.let { sectionActions[it] }.orEmpty()
        val typography = if (heading) {
            if (leaf.rootIndex?.let { sectionRows[it]?.meaningSection } == true) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium
        } else format?.style ?: baseStyle
        val style = (if (format?.ownerFont != null) typography else inheritedCellTextStyle(typography))
            .copy(textAlign = block.textAlign?.composeAlign() ?: leaf.align?.composeAlign() ?: inheritedAlign ?: androidx.compose.ui.text.style.TextAlign.Unspecified)
        val nativeTextKinds = setOf("paragraph", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "heading")
        val rendered = if (block.ruleStyle != null) {
            try {
                listOf(NativeFloatContextSpec.Rule(index,
                    resolveAuthoredRuleMetrics(block.ruleStyle, density.density, normalBodyPixels, ruleDarkTheme)))
            } catch (failure: UnsupportedFloatLayout) {
                paragraphFailure = failure.message ?: "Authored rule geometry is unavailable"
                originalChildren[index] = leaf
                listOf(NativeFloatContextSpec.Child(index, { it }, 0f, logicalObject = false))
            }
        } else if (block.figure != null || block.flow != null) {
            val prefix = blockPrefix(block)
            listOf(NativeFloatContextSpec.Flow(index, box?.after ?: gap, leaf.path,
                box, !paragraphHasContent(block, preserveCompiledText = preserveCompiledText) && prefix.isEmpty()) { carried, published ->
                val content: @Composable () -> Unit = {
                    AnonymousBlockView(block, Modifier, onLink, media, settings, edition,
                        inheritedAlign = figureInheritedAlign(style.textAlign, LocalLayoutDirection.current), style = style, interactionOwner = false,
                        carriedExclusions = carried, onFlowGeometry = published,
                        prefix = prefix, indentPixels = blockIndentDp(block) * density.density,
                        nativeLineHeight = format?.lineHeight, ownerFont = format?.ownerFont)
                }
                // Flow is composed after the preparation provider has returned. Retain
                // this source leaf's direction and its independent exclusion provenance.
                val context = leaf.context
                val occurrence = absoluteCell?.takeIf { it.ownsAbsoluteFlow(block) }?.let {
                    NativeDelegatedAbsoluteFlow(it, block, leaf.path)
                }
                if (context?.bodyDirection == null && occurrence == null && leaf.ownerWrap == null) content() else
                    CompositionLocalProvider(LocalNativeContainerTextContext provides
                        (if (context?.bodyDirection != null) context else LocalNativeContainerTextContext.current),
                        LocalNativeContainerTextWrap provides leaf.ownerWrap,
                        LocalNativeDelegatedAbsoluteFlow provides occurrence, content = content)
            })
        } else if (block.kind in nativeTextKinds && block.table == null && block.feature == null) {
            val displayed = if (preserveCompiledText) block.spans else paragraphDisplaySpans(block)
            val embedded = mediaOwners.embedded(displayed.filter { it.image == null })
            // StyledText already separates these controls. Keep its text in the shared float owner.
            val spans = if (embedded.isEmpty()) displayed else displayed.map {
                if (it.hasClassToken("wikidict-media")) it.withoutClassToken("wikidict-media") else it
            }
            val annotated = styledTextAnnotation(spans, if (block.kind == "term") FontWeight.Bold else null, style, onLink)
            val prefixStyle = compiledTableOwnerTextStyle(MaterialTheme.typography.labelMedium).copy(color =
                authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)?.let { Color(it) } ?: MaterialTheme.colorScheme.primary)
            val text = NativeFloatContextSpec.Text(prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), style, linkColor,
                media, settings, edition, onLink, indentPixels = blockIndentDp(block) * density.density,
                prefix = blockPrefix(block), prefixStyle = prefixStyle, heading = heading, headingActions = actions,
                nativeLineHeight = format?.lineHeight, sourceFamily = format?.sourceFamily,
                ownerWrap = leaf.ownerWrap, ownerFont = format?.ownerFont,
                rubyWeight = if (block.kind == "term") FontWeight.Bold else null,
                staticInlineParent = leaf.staticInlineParent),
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
            val tableFeature = if (table == null) block.feature else tableLayoutFeature(table, block.feature)
            val ownerLanguage = table?.blockViewport?.language ?: table?.floatViewport?.language
            val nativeTableAdmitted = ownerLanguage?.let { nativeTableOwnerLanguageTag(it) != null } ?: true
            val blockViewport = table?.takeIf { nativeTableAdmitted && it.blockViewport != null }?.blockViewportAt(documentViewport)
            val floatViewport = table?.floatViewport.takeIf { nativeTableAdmitted }
            val activeStyle = if (nativeTableAdmitted) blockViewport?.boxStyle ?: table?.effectiveFloatStyle(documentViewport) else null
            val side = activeStyle?.floatSide
            val cornerFocusTable = nativeTableAdmitted && table?.blockViewport?.isSeparateCornerGrid == true
            val intrinsicTable = if (!nativeTableAdmitted) null else table?.blockViewport?.intrinsicContainingDirection?.let {
                NativeFixedMarginTableInput(table, it)
            }
            val externalMargins = nativeTableAdmitted && nativeTableConsumesMargins(table, blockViewport)
            val automaticMargins = activeStyle?.marginValues?.let {
                resolveTableAutoMargins(it, density.density, normalBodyPixels)
            }
            val automaticTable = table?.takeIf { (activeStyle?.marginValues != null || cornerFocusTable) &&
                activeStyle?.floatSide == null && activeStyle?.isInline != true && tableFeature == null }
            val pairedTable = if (blockViewport == null || floatViewport == null) null else
                NativeFixedMarginTableInput(checkNotNull(table), floatViewport.containingDirection)
            val fixedTable = if (floatViewport == null || pairedTable != null) null else
                NativeFixedMarginTableInput(checkNotNull(table), floatViewport.containingDirection)
            fun natural(originalWidth: Int): TableRenderMetrics? = table?.let {
                tableRenderMetrics(it, with(density) { 136.dp.roundToPx() }, with(density) { 10.dp.roundToPx() },
                    if (table.blockViewport != null && floatViewport != null) 0 else with(density) { 40.dp.roundToPx() }, density.density,
                    containerFontPixels = if (floatViewport != null || cornerFocusTable || intrinsicTable != null) normalBodyPixels else fontPixels,
                    decorationViewportWidth = originalWidth, decorationViewportHeight = windowHeight,
                    rtl = (floatViewport?.gridDirection ?: table.blockViewport?.gridDirection.takeIf { cornerFocusTable || intrinsicTable != null })
                        ?.let { it == TableContainingDirection.Rtl } ?: rtl,
                    marginsConsumed = floatViewport != null || cornerFocusTable || intrinsicTable != null)
            }
            listOf(NativeFloatContextSpec.Child(index, { originalWidth ->
                if (!nativeTableAdmitted || table == null || tableFeature != null || table.style?.isInline == true) originalWidth else {
                    val metrics = natural(originalWidth)?.let { tableMetricsInWidth(table, it, tableGrid(table).columns, originalWidth) }
                    val margins = if (!externalMargins) metrics?.style?.margins?.horizontal ?: 0 else 0
                    val markerWidth = if (block.kind == "list_item") with(density) { 28.dp.roundToPx() } else 0
                    val width = metrics?.let { it.width.toLong() + margins + markerWidth + (blockIndentDp(block) * density.density).toInt() }
                        ?: originalWidth.toLong()
                    width.coerceIn(0L, if (leaf.inScrollport) TablePixelLimit.toLong() else originalWidth.toLong()).toInt()
                }
            }, if (side == null) box?.after ?: gap else 0f, side, { originalWidth ->
                val edges = if (!externalMargins) null else natural(originalWidth)?.style?.margins
                if (fixedTable != null || pairedTable != null || cornerFocusTable || intrinsicTable != null) {
                    if (intrinsicTable != null && (table?.caption?.isNotEmpty() == true || table?.captionBlocks?.isNotEmpty() == true))
                        throw UnsupportedFloatLayout("Intrinsic table focus with a caption is unavailable.")
                    if (cornerFocusTable && (table?.caption?.isNotEmpty() == true || table?.captionBlocks?.isNotEmpty() == true))
                        throw UnsupportedFloatLayout("Corner-table focus with a caption is unavailable.")
                    if (block.style != null || blockIndentDp(block) != 0 ||
                        block.kind == "list_item" && blockPrefix(block).isNotEmpty() || tableFeature != null)
                        throw UnsupportedFloatLayout("Responsive table needs its own unshifted source box")
                    resolveTableFixedMargins(checkNotNull(activeStyle?.margins), density.density, normalBodyPixels)
                } else if (externalMargins && automaticMargins != null) automaticMargins.fixed
                else FloatMargins(edges?.top?.toFloat() ?: 0f, edges?.right?.toFloat() ?: 0f,
                    edges?.bottom?.toFloat() ?: 0f, edges?.left?.toFloat() ?: 0f)
            }, requiresUnobstructedText = table == null, gapBefore = box?.before ?: 0f, clear = activeStyle?.clear.takeUnless { activeStyle?.isInline == true },
                atomicInline = table?.style?.isInline == true,
                widthFromContent = nativeTableAdmitted && table != null && tableFeature == null &&
                    (blockViewport != null || table.blockViewport?.isSeparateCornerGrid == true || intrinsicTable != null || floatViewport != null || table.style?.marginValues != null || tableUsesContentWidths(table, leaf.inScrollport || contentWidths)),
                preferredWidth = { originalWidth ->
                    val css = if (pairedTable != null) activeStyle?.width else table?.style?.width
                    val legacy = table?.geometry?.width.takeIf { css == null }
                    val value = when {
                        css?.unit == StyleWidthUnit.Px -> css.value.toDouble() * density.density
                        css?.unit == StyleWidthUnit.Em -> css.value.toDouble() *
                            if (floatViewport != null) normalBodyPixels else fontPixels
                        css?.unit == StyleWidthUnit.Percent -> css.value.toDouble() * originalWidth / 100.0
                        legacy?.unit == TableWidthUnit.Px -> legacy.value.toDouble() * density.density
                        legacy?.unit == TableWidthUnit.Percent -> legacy.value.toDouble() * originalWidth / 100.0
                        else -> null
                    }
                    if (value != null && (!value.isFinite() || value !in 0.0..TablePixelLimit.toDouble()))
                        throw UnsupportedFloatLayout("Authored child width exceeds the native range")
                    value?.let { kotlin.math.round(it).toInt() }
                }, minimumWidth = { containingWidth -> table?.style?.minWidth?.let {
                    tableMinimumWidthPixels(it, density.density, normalBodyPixels, containingWidth)
                } }, overflowViewport = nativeTableAdmitted && table != null && floatViewport == null && !cornerFocusTable && intrinsicTable == null && !inCell && !leaf.inScrollport,
                delegatedTable = table?.takeIf { nativeTableAdmitted && blockViewport == null && floatViewport == null && !cornerFocusTable && intrinsicTable == null && tableFeature == null && !inCell && !leaf.inScrollport && (nativeDelegatedFigureTable(it) || nativeDelegatedAbsoluteTable(it)) },
                autoMarginTable = automaticTable, autoMargins = automaticMargins.takeIf { automaticTable != null },
                fixedMarginTable = fixedTable, pairedMarginTable = pairedTable,
                blockViewport = blockViewport,
                pairedBlockBox = pairedTable?.let { paired -> { containingWidth: Int, assignedWidth: Float, intrinsic: ContainerWidths ->
                    if (block.style != null || blockIndentDp(block) != 0 ||
                        block.kind == "list_item" && blockPrefix(block).isNotEmpty() || tableFeature != null)
                        throw UnsupportedFloatLayout("Paired table needs its own unshifted source box")
                    resolvePairedTableBlockBox(checkNotNull(blockViewport), checkNotNull(paired.table.floatViewport),
                        containingWidth.toFloat(), assignedWidth, intrinsic, density.density, normalBodyPixels)
                } } ?: intrinsicTable?.takeIf { blockViewport != null }?.let { intrinsic ->
                    { containingWidth: Int, assignedWidth: Float, widths: ContainerWidths ->
                        if (block.style != null || blockIndentDp(block) != 0 ||
                            block.kind == "list_item" && blockPrefix(block).isNotEmpty() || tableFeature != null)
                            throw UnsupportedFloatLayout("Intrinsic table needs its own unshifted source box")
                        resolveIntrinsicTableBlockBox(checkNotNull(intrinsic.table.blockViewport), containingWidth.toFloat(),
                            assignedWidth, widths, density.density, normalBodyPixels)
                    }
                },
                blockBox = blockViewport?.takeIf { pairedTable == null && intrinsicTable == null }?.let { policy -> { containingWidth: Int ->
                    if (block.style != null || blockIndentDp(block) != 0 ||
                        block.kind == "list_item" && blockPrefix(block).isNotEmpty() || tableFeature != null)
                        throw UnsupportedFloatLayout("Table block viewport needs its own unshifted source box")
                    resolveTableBlockBox(policy, containingWidth.toFloat(), density.density, normalBodyPixels)
                } }, intrinsicMarginTable = intrinsicTable))
        }
        if (paragraphFailure == null) rendered else listOf(NativeFloatContextSpec.Container(
            sourceId(leaf.path + "/unavailable"), contentWidth = { width, _ -> width },
            intrinsicWidth = { width, _ -> width }, preparedParts = rendered,
            unavailableReason = paragraphFailure, content = {}))
    }
    val request = LocalCellHeadingRequest.current
    val reached = LocalCellHeadingReached.current
    val sourceReveal = LocalSourceHeadingReveal.current
    fun flattened(items: List<NativeFloatContextSpec>): List<NativeFloatContextSpec> = items.flatMap { item ->
        (item as? NativeFloatContextSpec.Container)?.preparedParts?.let(::flattened) ?: listOf(item)
    }
    if (absoluteCell != null) {
        val revision = listOf(blocks, rootContext, baseStyle, settings, edition, media,
            LocalMissingLinkOwner.current, flattened(originalParts).filterIsInstance<NativeFloatContextSpec.Text>().map {
                listOf(it.prepared.native?.paint?.typeface, it.prepared.native?.paint?.textSize,
                    it.prepared.stateDescription, it.prepared.ordinaryLinkPaintRevision)
            })
        SideEffect { absoluteCell.preparedAbsoluteSource(revision) }
    }
    val delegatedFailure = absoluteCell?.table?.fallbackReason
    // Keep the same source slots and resource preparation alive. The existing unavailable
    // context path retains all original text/actions after a measured table proof refuses.
    val parts = if (delegatedFailure == null) originalParts else originalParts.map { part ->
        if (part is NativeFloatContextSpec.Container) part.copy(unavailableReason = delegatedFailure) else part
    }
    val revealIndex = flattened(parts).indexOfFirst { when (it) {
        is NativeFloatContextSpec.Text -> it.path == request?.path
        is NativeFloatContextSpec.Flow -> it.path == request?.path
        else -> false
    } }.takeIf { request != null && it >= 0 }
    @Composable fun originalChild(id: Int, originalWidth: NativeLayoutInput<Int>) {
        val leaf = originalChildren.getValue(id)
        CompositionLocalProvider(LocalFloatTableWidthReference provides originalWidth,
            LocalNativeContainerTextWrap provides leaf.ownerWrap,
            LocalFloatMarginsConsumed provides nativeTableConsumesMargins(leaf.block.table,
                leaf.block.table?.takeIf { it.blockViewport != null }?.blockViewportAt(documentViewport)),
            LocalNativeContainerTextContext provides (if (leaf.bodyTypographyExcluded) leaf.context
                else leaf.context ?: LocalNativeContainerTextContext.current),
            LocalCellTextAlign provides (leaf.block.textAlign?.composeAlign() ?: leaf.align?.composeAlign() ?: inheritedAlign)) {
            BlockView(leaf.block, onLink, leaf.path, inCell, leaf.gridPath)
        }
    }
    NativeFloatContextLayout(parts, modifier, linkColor, containAtEnd, revealIndex, request,
        { if (request != null) reached(request) }, adjoining = parts.any {
            it is NativeFloatContextSpec.Container || it is NativeFloatContextSpec.Rule
        },
        documentSurface = documentSurface, bodyAdjoining = bodyAdjoining,
        sourceReveal = if (request?.anchorMatch?.revealTop != null && revealIndex != null)
            { top -> sourceReveal(request, top) } else null,
        delegatedSourceRevision = listOf(blocks, rootContext, baseStyle, settings, edition, media,
            LocalMissingLinkOwner.current, containAtEnd, documentSurface, fixedHeightReachable, positionedPaintRoot) +
            listOfNotNull(bodyAdjoining)) { id, originalWidth ->
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
    if (table.style?.minWidth != null && LocalFloatTableWidthReference.current == null) {
        TableMinimumContainingWidth { FigureCaptionTable(table, context, style, reader, sink) }
        return
    }
    val minimumContainingWidth = LocalFloatTableWidthReference.current.takeIf { table.style?.minWidth != null }
    val ownerDirection = table.blockViewport?.gridDirection ?: table.floatViewport?.gridDirection
    val ownerLanguage = table.blockViewport?.language ?: table.floatViewport?.language
    val ownLanguage = ownerLanguage?.let(::nativeTableOwnerLanguageTag)
    val languageFailure = NativeTableLanguageUnavailable.takeIf { ownerDirection != null && ownLanguage == null }
    val placementFailure = languageFailure ?: "Intrinsic table focus inside a figure caption is unavailable.".takeIf {
        table.blockViewport?.intrinsicContainingDirection != null
    } ?: "Corner-table focus inside a figure caption is unavailable.".takeIf {
        table.blockViewport?.isSeparateCornerGrid == true
    } ?: "Responsive floated caption table needs a shared exclusion owner".takeIf {
        table.floatViewport != null
    } ?: "Numeric corner-table margins outside the responsive block are unavailable.".takeIf {
        table.style?.let { it.cornerRadii != null && it.marginValues == null && it.containingDirection != null } == true &&
            activeTableBlockViewport(table) == null
    }
    if (ownerDirection != null && LocalCompiledTableDirectionOwner.current !== table) {
        val ownDirection = if (ownerDirection == TableContainingDirection.Rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr
        CompositionLocalProvider(LocalCompiledTableDirectionOwner provides table,
            LocalCompiledTableTextDirection provides ownerDirection,
            LocalNativeColumnTextDirection provides null,
            LocalCompiledTableSourceLanguage provides ownLanguage,
            LocalLayoutDirection provides if (ownDirection == BidiResolvedDirection.Rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
            FigureCaptionTable(table, context.copy(direction = ownDirection, language = ownLanguage),
                if (languageFailure == null) style else style.copy(localeList = null), reader, sink)
        }
        return
    }
    val density = LocalDensity.current
    val bodyPixels = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val blockViewport = activeTableBlockViewport(table)
    val tableContext = ownerDirection?.let { context.copy(direction =
        if (it == TableContainingDirection.Rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr,
        language = ownLanguage) } ?: context
    val requestedLineHeight = tableLineHeightPixels(table, style, blockViewport?.gridStyle ?: table.style)
    val invalidLineHeight = requestedLineHeight != null &&
        (!requestedLineHeight.isFinite() || requestedLineHeight <= 0f || requestedLineHeight > TablePixelLimit)
    val lineHeightPixels = requestedLineHeight.takeUnless {
        (blockViewport != null || table.style?.minWidth != null) && invalidLineHeight
    }
    if (invalidLineHeight && blockViewport == null && table.style?.minWidth == null) {
        UnavailableSelectionContent("Caption table line height is too large", sink)
        return
    }
    if (table.style?.floatSide != null && table.floatViewport == null) {
        UnavailableSelectionContent("Nested floated caption table needs a shared exclusion owner", sink)
        return
    }
    val inheritedStyle = inheritedCellTextStyle(style)
    val tableStyle = if (lineHeightPixels == null) inheritedStyle else inheritedStyle.copy(lineHeight = with(density) { lineHeightPixels.toSp() })
    val inheritedCellContext = LocalNativeContainerTextContext.current
    val tableCellContext = if (lineHeightPixels == null) inheritedCellContext else inheritedCellContext?.let {
        it.copy(cellText = it.cellText?.copy(lineHeight = NativeLineHeightPolicy.Pixels(lineHeightPixels)),
            resolvedLineHeight = NativeLineHeightPolicy.Pixels(lineHeightPixels).takeIf { _ ->
                it.bodyOrigin != null || it.resolvedLineHeight != null },
            bodyOrigin = it.bodyOrigin?.copy(lineHeightInherited = false))
    }
    val grid = remember(table) { tableGrid(table) }
    val cells = grid.cells.map { placed -> CaptionCellSlot { cellSink ->
        val childContext = tableContext.copy(textAlign = placed.cell.style?.textAlign ?: tableContext.textAlign)
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
            (blockViewport != null || table.blockViewport?.isSeparateCornerGrid == true || cellFormat != null || placed.cell.style?.verticalAlign == CellVerticalAlign.Middle) &&
                placed.cell.spans.isEmpty() -> SelectionEmptyBox(sink = cellSink)
            else -> AnonymousBlockView(Block("paragraph", 0,
                if (LocalNativeContainerTextContext.current?.fontFamily is ContainerFontFamily.Stack) placed.cell.spans
                else compactSpans(placed.cell.spans)), Modifier,
                reader.onLink, reader.media, reader.settings, reader.edition, inherited = childContext,
                style = childStyle, onGeometry = cellSink, interactionOwner = false, nativeLineHeight = cellFormat?.lineHeight)
        }
    } }
    val contentWidths = blockViewport != null || table.blockViewport?.isSeparateCornerGrid == true || LocalTableContentWidths.current || tableHasComputedCellStyle(table) || table.style?.marginValues != null || table.style?.minWidth != null
    val rtl = tableContext.direction == BidiResolvedDirection.Rtl
    val natural = remember(table, blockViewport, contentWidths, density.density, bodyPixels, rtl) {
        if (blockViewport != null) anonymousTableRenderMetrics(table, blockViewport.gridStyle, density.density, bodyPixels, rtl)
        else tableRenderMetrics(table, if (contentWidths) 1 else with(density) { 136.dp.roundToPx() }, with(density) { 10.dp.roundToPx() },
                with(density) { 40.dp.roundToPx() }, density.density, containerFontPixels = bodyPixels,
                rtl = rtl)
    }
    CompositionLocalProvider(LocalTableContentWidths provides contentWidths,
        LocalNativeContainerTextContext provides tableCellContext,
        LocalTableLineHeightPixels provides lineHeightPixels.takeIf { tableCellContext?.cellText == null }) {
        val marginValues = table.style?.marginValues
        if (placementFailure != null || blockViewport != null || marginValues != null) {
            val caption: (@Composable (SelectionGeometrySink) -> Unit)? =
                if (table.captionBlocks?.isNotEmpty() == true || table.caption.isNotEmpty()) ({ captionSink ->
                  TableCaptionContext(table) {
                    if (table.captionBlocks != null) FigureCaptionBlocks(table.captionBlocks, tableContext, tableStyle, reader, captionSink)
                    else AnonymousBlockView(Block("paragraph", 0, table.caption), Modifier, reader.onLink,
                        reader.media, reader.settings, reader.edition, inherited = tableContext, style = tableStyle,
                        onGeometry = captionSink, interactionOwner = false,
                        nativeLineHeight = tableCellContext?.takeIf { it.cellText != null }?.let {
                            nativeContainerTextFormat(it, MaterialTheme.typography.bodyLarge.fontSize, tableStyle, density).lineHeight
                        })
                  }
                }) else null
            CompositionLocalProvider(LocalLayoutDirection provides if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                if (placementFailure != null) {
                    SelectionAutoMarginTable(null, null, tableContext.direction, false, 0, sink,
                        preparationFailure = placementFailure, retainFailureIntrinsics = true,
                        caption = caption) { available, captionMinimum, tableSink ->
                        CompositionLocalProvider(LocalFloatTableWidthReference provides (minimumContainingWidth ?: available)) {
                            TableGridView(table, reader.onLink, "figure-caption", null, "", natural, 1.0,
                                { }, selectionCells = cells, selectionGeometry = tableSink, containerStyle = tableStyle,
                                contentWidths = true, captionMinimumWidth = captionMinimum,
                                anonymousGridStyle = blockViewport?.gridStyle)
                        }
                    }
                } else if (blockViewport != null) {
                    SelectionBlockViewportTable(table, blockViewport, 0, sink,
                        caption = caption) { captionMinimum, tableSink ->
                        TableGridView(table, reader.onLink, "figure-caption", null, "", natural, 1.0,
                            { }, selectionCells = cells, selectionGeometry = tableSink, containerStyle = tableStyle,
                            contentWidths = true, captionMinimumWidth = captionMinimum, anonymousGridStyle = blockViewport.gridStyle)
                    }
                } else {
                val resolved = remember(marginValues, density.density, bodyPixels) {
                    runCatching { resolveTableAutoMargins(checkNotNull(marginValues), density.density, bodyPixels) }
                }
                SelectionAutoMarginTable(resolved.getOrNull(), table.style?.containingDirection, context.direction,
                    table.style?.isInline == true, with(density) { 6.dp.roundToPx() }, sink,
                    preparationFailure = resolved.exceptionOrNull()?.message, caption = caption) { available, captionMinimum, tableSink ->
                    CompositionLocalProvider(LocalFloatTableWidthReference provides (minimumContainingWidth ?: available)) {
                        TableGridView(table, reader.onLink, "figure-caption", null, "", natural, 1.0,
                            { }, selectionCells = cells, selectionGeometry = tableSink, containerStyle = tableStyle,
                            contentWidths = true, captionMinimumWidth = captionMinimum)
                    }
                }
                }
            }
        } else {
        val margin = natural?.style?.margins
        SelectionInsetsBox(margin?.left ?: 0, margin?.top ?: 0, margin?.right ?: 0, margin?.bottom ?: 0,
            context.direction, sink) { insideSink ->
            val parts = mutableListOf<@Composable (SelectionGeometrySink) -> Unit>()
            if (table.captionBlocks?.isNotEmpty() == true || table.caption.isNotEmpty()) parts += { captionSink ->
              TableCaptionContext(table) {
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
            }
            parts += { gridSink ->
                SelectionGridBox(context.direction, gridSink) { available, tableSink ->
                    CompositionLocalProvider(LocalFloatTableWidthReference provides (minimumContainingWidth ?: available)) {
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

private class ReferenceBacklinkSourceIdentity(private val source: ReferenceBacklink) {
    override fun equals(other: Any?): Boolean = other is ReferenceBacklinkSourceIdentity && source === other.source
    override fun hashCode(): Int = System.identityHashCode(source)
}

/** A prefix is independent of both Entry and Reference BODY typography. This provider is
 * also retained by the existing visible-unavailable fallback; no source Span is rewritten. */
@Composable
private fun ReferenceBacklinkTextContext(style: TextStyle, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalTextStyle provides style,
        LocalNativeContainerTextContext provides null, LocalNativeContainerTextWrap provides null,
        LocalCellWeight provides null, LocalCellLetterSpacingPixels provides null,
        LocalCellTextAlign provides null, LocalTableLineHeightPixels provides null,
        LocalNativePreformattedText provides false, LocalAuthoredBackground provides null,
        LocalFigureCaptionForeground provides null, LocalFigureCaptionLinkScope provides null,
        LocalCompiledTableSourceLanguage provides null,
        LocalReferenceBodyTypography provides false, content = content)
}

@Composable
internal fun prepareNativeReferenceBacklink(backlink: ReferenceBacklink,
    onLink: (EntryLink) -> Unit): PreparedNativeFloatText {
    val style = nativeReferenceBacklinkStyle(MaterialTheme.typography.bodyLarge.fontSize)
    val spans = remember(ReferenceBacklinkSourceIdentity(backlink)) { listOf(backlink.span) }
    val snapshot = nativeReferenceBacklinkFont(backlink)
    lateinit var prepared: PreparedNativeFloatText
    ReferenceBacklinkTextContext(style) {
        val annotated = styledTextAnnotation(spans, null, style, onLink)
        prepared = prepareNativeFloatText(spans, annotated, egyptianTextRuns(spans), style,
            MaterialTheme.colorScheme.primary, emptyList(), LocalReaderSettings.current,
            LocalEntryEdition.current, onLink, nativeLineHeight = NativeLineHeightPolicy.Normal,
            sourceFamily = null, ownerFont = NativeDeclaringFont(snapshot, style,
                NativeDeclaringFontKind.ReferenceBacklink), referenceBacklink = backlink)
    }
    return prepared.copy(fallback = {
        ReferenceBacklinkTextContext(style) { prepared.fallback() }
    })
}

@Composable
internal fun ReferenceBacklinkView(backlink: ReferenceBacklink, onLink: (EntryLink) -> Unit) {
    val prepared = prepareNativeReferenceBacklink(backlink, onLink)
    NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f)),
        Modifier.width(IntrinsicSize.Max), MaterialTheme.colorScheme.primary) { _, _ ->
        error("Reference backlink has no delegated child")
    }
}
