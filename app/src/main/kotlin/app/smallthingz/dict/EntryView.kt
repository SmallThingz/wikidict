package app.smallthingz.dict

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.platform.LocalLayoutDirection
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em

private val EgyptianFontFamily = FontFamily(Font(R.font.egyptian_hieroglyphs))
private val spanClassWhitespace = Regex("\\s+")

private class TextCache(val link: State<(String) -> Unit>) {
    val values = java.util.IdentityHashMap<List<Span>, MutableMap<Pair<FontWeight?, LayoutDirection>, AnnotatedString>>()
}
private val LocalEntryMedia = staticCompositionLocalOf<List<Media>> { emptyList() }
private val LocalEntryEdition = staticCompositionLocalOf { "" }
private val LocalReaderSettings = staticCompositionLocalOf { AppSettings() }
private val LocalTextCache = staticCompositionLocalOf<TextCache?> { null }

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

@Composable
fun EntryView(entry: Entry, bookmarked: Boolean, onBookmark: () -> Unit, onLink: (String) -> Unit = {}, settings: AppSettings = AppSettings(), onScrollDirection: (Boolean) -> Unit = {}, anchorRequest: EntryAnchorRequest? = null, onAnchorConsumed: (EntryAnchorRequest) -> Unit = {}, onNavigate: () -> Unit = {}, readingState: EntryReadingState? = null) {
    val uri = LocalUriHandler.current
    val context = LocalContext.current
    DisposableEffect(entry.key) { onDispose { SpeechPlayback.stop() } }
    val colors = MaterialTheme.colorScheme
    CompositionLocalProvider(LocalEntryMedia provides entry.media, LocalEntryEdition provides entry.edition, LocalReaderSettings provides settings) {
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
        val visibleRows = visibleReadingRows(entry.readingRows, folded.filterValues { it }.keys)
        fun jumpToAnchor(target: String): Boolean {
            val referenceIndex = referenceScrollIndex(entry, target, folded.filterValues { it }.keys)
            val sectionKey = if (referenceIndex == null) sectionScrollKey(entry, target) else null
            if (referenceIndex != null) {
                folded["references"] = false
                // Apply the destination in the next remeasure, after References opens.
                scroll.requestScrollToItem(referenceIndex)
            } else if (sectionKey != null) {
                folded[sectionKey] = false
                val sectionIndex = visibleReadingRows(entry.readingRows, folded.filterValues { it }.keys)
                    .indexOfFirst { it.key == sectionKey }
                scroll.requestScrollToItem(sectionIndex + entryReadingStartIndex(entry, folded.filterValues { it }.keys))
            } else return false
            return true
        }
        val readerLink: (String) -> Unit = { target ->
            onNavigate()
            if (!jumpToAnchor(target)) onLink(target)
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
        val remainingMedia = remember(entry) {
            val linkedFiles = inlineMediaFiles(entry)
            entry.media.filter { it.file !in linkedFiles }
        }
        CompositionLocalProvider(LocalTextCache provides cache) {
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
                                    if (section.title.isNotBlank() && section.title != entry.language) DropdownMenuItem(text = { Text(section.title) }, onClick = {
                                        onNavigate()
                                        contents = false
                                        folded[row.key] = false
                                        val targetIndex = visibleReadingRows(entry.readingRows, folded.filterValues { it }.keys).indexOfFirst { it.key == row.key }
                                        scope.launch {
                                            androidx.compose.runtime.withFrameNanos { }
                                            scroll.animateScrollToItem(targetIndex + entryReadingStartIndex(entry, folded.filterValues { it }.keys))
                                        }
                                    })
                                } }
                            }
                        }
                        IconButton(onClick = onBookmark) { Icon(if (bookmarked) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder, if (bookmarked) "Remove bookmark" else "Bookmark", Modifier.size(22.dp)) }
                    }
                    if (entry.displayTitle.isNotEmpty()) StyledText(entry.displayTitle, Modifier.fillMaxWidth().testTag("entry-title"), style = MaterialTheme.typography.displayMedium, onLink = readerLink)
                    else Text(entry.title, Modifier.fillMaxWidth().testTag("entry-title"), style = MaterialTheme.typography.displayMedium.copy(textDirection=TextDirection.Content))
                    if (entry.abbreviations.isNotEmpty()) {
                        val closed = folded["abbreviations"] != false
                        TextButton(onClick = { folded["abbreviations"] = !closed },
                            modifier = Modifier.testTag("entry-abbreviations").semantics {
                                stateDescription = if (closed) "Collapsed" else "Expanded"
                            }) { Text("Abbreviations") }
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
            items(visibleRows, key = { it.key }, contentType = { if (it.heading != null) "heading" else it.block?.kind }) { row ->
                Column(Modifier.animateItem()) {
                row.heading?.let { section ->
                    if (section.title.isNotBlank() && (section.title != entry.language || section.blocks.any { it.kind != "blank" })) {
                        val richHeading = row.headingBlock
                        val label = if (richHeading == null && section.title == entry.language) "Overview" else section.title
                        val angle by animateFloatAsState(if (folded[row.key] == true) -90f else 0f, label = "Section fold")
                        val toggle = { folded[row.key] = folded[row.key] != true }
                        val headingModifier = if (richHeading == null) Modifier.clickable(onClick = toggle) else Modifier
                        Row(Modifier.fillMaxWidth().then(headingModifier).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                            val headingStyle = if (row.meaningSection) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium
                            if (richHeading == null) Text(label, Modifier.weight(1f), style = headingStyle)
                            else StyledText(richHeading.spans, Modifier.weight(1f), style = headingStyle, onLink = readerLink)
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
                    Box(Modifier.padding(bottom = if (row.compact) 2.dp else 6.dp)) { BlockView(block, readerLink) }
                }
                }
            }
            if (entry.references.isNotEmpty()) item("references-heading") { FoldHeading("References", folded["references"] == true) { folded["references"] = folded["references"] != true } }
            items(if (folded["references"] == true) emptyList() else entry.references, key = { "reference-${it.number}" }, contentType = { "reference" }) { ref ->
                val label = referenceLabel(ref)
                Row(Modifier.padding(bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { Text(label, style = MaterialTheme.typography.labelMedium, color = colors.primary); StyledText(ref.spans, Modifier.weight(1f), onLink = readerLink) }
            }
            if (remainingMedia.isNotEmpty()) item("media-heading") { FoldHeading("Media", folded["media"] == true) { folded["media"] = folded["media"] != true } }
            (if (folded["media"] == true) emptyList() else remainingMedia).forEachIndexed { index, media -> item("media-$index", contentType = "media") {
                MediaView(media, settings, edition=entry.edition)
            } }
            item("attribution") {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
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
    val angle by animateFloatAsState(if (folded) -90f else 0f, label = "Section fold")
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
        Icon(Icons.Filled.ExpandMore, if (folded) "Expand $title" else "Collapse $title", Modifier.size(20.dp).rotate(angle))
    }
}

@Composable
private fun BlockView(block: Block, onLink: (String) -> Unit) {
    when {
        block.table != null -> Box(Modifier.padding(start = blockIndentDp(block).dp)) { CompiledTableView(block.table, block.feature, onLink) }
        block.kind == "rule" -> HorizontalDivider()
        block.kind == "preformatted" -> Box(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).horizontalScroll(rememberScrollState()).padding(12.dp)) {
            StyledText(block.spans, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace), onLink = onLink, preserveWhitespace = true)
        }
        else -> {
            val prefix = blockPrefix(block)
            Row(Modifier.padding(start = blockIndentDp(block).dp)) {
                if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                StyledText(ordinaryInlineDisplaySpans(block), Modifier.weight(1f), weight = if (block.kind == "term") FontWeight.Bold else null, onLink = onLink)
            }
        }
    }
}

@Composable
internal fun CompiledTableView(table: Table, feature: Feature?, onLink: (String) -> Unit) {
    val sample = colorSwatch(feature)
    if (sample == null) {
        TableView(table, onLink)
    } else {
        Row(Modifier.semantics(mergeDescendants = true) {},
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            // Decorative sample: the visible label supplies its single accessible name.
            Box(Modifier.size(40.dp).background(androidx.compose.ui.graphics.Color(sample.argb))
                .testTag("compiled-color-swatch"))
            Text("Color sample ${sample.hex}", color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
private fun TableView(table: Table, onLink: (String) -> Unit) {
    val grid = remember(table) { tableGrid(table) }
    var unavailable by remember(table) { mutableStateOf(false) }
    var drawingPixels by remember(table) { mutableStateOf<TablePixelLayout?>(null) }
    val headerColor = MaterialTheme.colorScheme.surfaceContainerHigh
    val cellColor = MaterialTheme.colorScheme.surface
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (table.caption.isNotEmpty()) StyledText(table.caption, onLink = onLink)
        if (unavailable) {
            Text("Table is too large to display.")
        } else Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
            Layout(modifier = Modifier.drawBehind {
                val pixels = drawingPixels ?: return@drawBehind
                grid.cells.forEach { placed ->
                    val left = if (layoutDirection == androidx.compose.ui.unit.LayoutDirection.Ltr)
                        pixels.columnWidth * placed.column
                    else pixels.width - pixels.columnWidth * (placed.column + placed.colspan)
                    val top = pixels.rowOffsets[placed.row]
                    val bottom = pixels.rowOffsets[placed.row + placed.cell.rowspan]
                    drawRect(if (placed.cell.header) headerColor else cellColor,
                        topLeft = Offset(left.toFloat(), top.toFloat()),
                        size = Size((pixels.columnWidth * placed.colspan).toFloat(), (bottom - top).toFloat()))
                }
            }, content = {
                grid.cells.forEach { placed ->
                    Box(Modifier.background(if (placed.cell.header) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surface).padding(10.dp)) {
                        StyledText(placed.cell.spans, weight = if (placed.cell.header) FontWeight.SemiBold else null, onLink = onLink)
                    }
                }
            }) { measurables, _ ->
                val columnWidth = tableColumnWidth(grid.columns, 136.dp.roundToPx())
                val heightLimit = columnWidth?.let { tableHeightLimit(it * grid.columns) }
                // Measure once; native Egyptian cells use SubcomposeLayout, which
                // deliberately has no intrinsic measurement implementation.
                val children = if (columnWidth == null || heightLimit == null) emptyList() else measurables.mapIndexed { index, measurable ->
                    val width = columnWidth * grid.cells[index].colspan
                    measurable.measure(Constraints(minWidth = width, maxWidth = width,
                        minHeight = 0, maxHeight = heightLimit))
                }
                // Saturation at the child height limit is unavailable: it could
                // mean clipped content, so it must not be promoted to success.
                val pixels = if (columnWidth == null || heightLimit == null) null else tablePixelLayout(grid, columnWidth,
                    40.dp.roundToPx(), IntArray(children.size) { children[it].height })
                if (pixels == null) {
                    // A following composition exposes the explicit unavailable state.
                    // No partial table or clipped cell is presented as successful layout.
                    drawingPixels = null
                    unavailable = true
                    layout(0, 0) {}
                } else {
                    val offsets = pixels.rowOffsets
                    drawingPixels = pixels
                    layout(pixels.width, pixels.height) {
                        children.forEachIndexed { index, child ->
                            val placed = grid.cells[index]
                            child.placeRelative(pixels.columnWidth * placed.column, offsets[placed.row])
                        }
                    }
                }
            }
        }
    }
}

/** Use the same explicit ownership for inline controls and the media footer. */
private fun inlineMediaFiles(entry: Entry): Set<String> = buildSet {
    val owners = MediaOwners(entry.media)
    fun include(spans: List<Span>, preserveWhitespace: Boolean = false) {
        val rendered = if (preserveWhitespace) spans else compactSpans(spans)
        owners.embedded(rendered).forEach { add(it.file) }
    }
    include(entry.displayTitle)
    include(entry.preamble)
    entry.readingRows.forEach { row ->
        row.headingBlock?.let { include(it.spans) }
        row.block?.let { block ->
            val table = block.table
            when {
                table != null -> {
                    include(table.caption)
                    table.rows.forEach { cells -> cells.forEach { include(it.spans) } }
                }
                block.kind != "rule" -> include(block.spans, preserveWhitespace = block.kind == "preformatted")
            }
        }
    }
    entry.references.forEach { include(it.spans) }
}

@Composable
internal fun StyledText(source: List<Span>, modifier: Modifier = Modifier, weight: FontWeight? = null, style: TextStyle = MaterialTheme.typography.bodyLarge, onLink: (String) -> Unit = {}, preserveWhitespace: Boolean = false) {
    val spans = remember(source, preserveWhitespace) { if (preserveWhitespace) source else compactSpans(source) }
    val availableMedia = LocalEntryMedia.current
    val owners = remember(availableMedia) { MediaOwners(availableMedia) }
    val embedded = owners.embedded(spans)
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
    val codeColor = MaterialTheme.colorScheme.surfaceContainer
    val cache = LocalTextCache.current
    val currentLink = rememberUpdatedState(onLink)
    val layoutDirection = LocalLayoutDirection.current
    val cacheKey = weight to layoutDirection
    val annotated = remember(spans, weight, linkColor, codeColor, cache, layoutDirection) {
        cache?.values?.get(spans)?.get(cacheKey) ?: buildAnnotatedString {
            val linkStyle = TextLinkStyles(style = SpanStyle(color = linkColor), pressedStyle = SpanStyle(textDecoration = TextDecoration.Underline))
            val appendedSpans = ArrayList<Pair<Span, IntRange>>(spans.size)
            spans.forEach { span ->
                val start = length
                when (span.direction) {
                    "rtl" -> append('\u2067')
                    "ltr" -> append('\u2066')
                    "auto" -> append('\u2068')
                }
                append(if (span.kind == "line_break") "\n" else span.text)
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
                    if (languageTag != null || fontFamily != null || weight != null || span.bold || span.italic || span.code || span.small || span.superscript || span.subscript || span.strike || span.underline) addStyle(SpanStyle(
                        localeList = languageTag?.let { LocaleList(Locale(it)) },
                        fontWeight = if (span.bold) FontWeight.Bold else weight,
                        fontStyle = if (span.italic) FontStyle.Italic else null,
                        fontFamily = fontFamily,
                        letterSpacing = if (fontFamily == EgyptianFontFamily) 0.sp else TextUnit.Unspecified,
                        fontSize = if (span.small || span.superscript || span.subscript) 0.8.em else 1.em,
                        baselineShift = when { span.superscript -> BaselineShift.Superscript; span.subscript -> BaselineShift.Subscript; else -> null },
                        background = if (span.code) codeColor else androidx.compose.ui.graphics.Color.Unspecified,
                        textDecoration = when {
                            span.strike && span.underline -> TextDecoration.combine(listOf(TextDecoration.LineThrough, TextDecoration.Underline))
                            span.strike -> TextDecoration.LineThrough
                            span.underline -> TextDecoration.Underline
                            else -> null
                        },
                    ), start, end)
                    if (span.kind == "link" && span.target.isNotBlank()) addLink(LinkAnnotation.Clickable(span.target, linkStyle) { (cache?.link?.value ?: currentLink.value)(span.target) }, start, end)
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
    val egyptianRuns = remember(spans) { egyptianTextRuns(spans) }
    SelectionContainer(modifier = modifier) {
        EgyptianInlineText(annotated, egyptianRuns, Modifier, style.copy(textDirection = TextDirection.Content), linkColor)
    }
}
