package app.smallthingz.dict

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.draw.rotate
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em

private class TextCache(val link: State<(String) -> Unit>) {
    val values = java.util.IdentityHashMap<List<Span>, MutableMap<FontWeight?, AnnotatedString>>()
}
private val LocalEntryMedia = staticCompositionLocalOf<List<Media>> { emptyList() }
private val LocalEntryEdition = staticCompositionLocalOf { "" }
private val LocalReaderSettings = staticCompositionLocalOf { AppSettings() }
private val LocalTextCache = staticCompositionLocalOf<TextCache?> { null }

@Composable
fun EntryView(entry: Entry, bookmarked: Boolean, onBookmark: () -> Unit, onLink: (String) -> Unit = {}, settings: AppSettings = AppSettings(), onScrollDirection: (Boolean) -> Unit = {}) {
    val uri = LocalUriHandler.current
    val context = LocalContext.current
    DisposableEffect(entry.key) { onDispose { SpeechPlayback.stop() } }
    val colors = MaterialTheme.colorScheme
    CompositionLocalProvider(LocalEntryMedia provides entry.media, LocalEntryEdition provides entry.edition, LocalReaderSettings provides settings) {
      key(entry.key) {
        val scroll = rememberLazyListState()
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
        val folded = remember(entry.key, settings.collapsePronunciation, settings.collapseEtymology, settings.collapseOtherSections, settings.collapseDetails) {
            mutableStateMapOf<String, Boolean>().apply {
                entry.readingRows.forEach { row -> row.heading?.let {
                    this[row.key] = initiallyFolded(row, settings)
                    if (row.meaningSection) this[row.key + "-details"] = settings.collapseDetails
                } }
                this["preamble"] = settings.collapseOtherSections && entry.kind != "alias"
                this["references"] = settings.collapseOtherSections
                this["media"] = settings.collapseOtherSections
            }
        }
        val visibleRows = visibleReadingRows(entry.readingRows, folded.filterValues { it }.keys)
        val readerLink: (String) -> Unit = { target ->
            val referenceIndex = referenceScrollIndex(entry, target, folded.filterValues { it }.keys)
            if (referenceIndex != null) {
                folded["references"] = false
                // Apply the destination in the next remeasure, after References opens.
                scroll.requestScrollToItem(referenceIndex)
            } else onLink(target)
        }
        val currentLink = rememberUpdatedState(readerLink)
        val cache = remember(entry, colors.primary, colors.surfaceContainer) { TextCache(currentLink) }
        CompositionLocalProvider(LocalTextCache provides cache) {
        LazyColumn(Modifier.fillMaxSize().nestedScroll(dockScroll).testTag("entry-scroll"), state = scroll, contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 56.dp)) {
            item("title", contentType = "title") {
                Column(Modifier.padding(bottom = 6.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text((entry.language ?: entry.kind.replace('_', ' ')).uppercase(), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                        IconButton(onClick = { SpeechPlayback.play(context, entry.title, entry.languageCode) }) { Icon(if (SpeechPlayback.active == entry.title) Icons.Outlined.Stop else Icons.Outlined.VolumeUp, "Pronounce word offline", Modifier.size(22.dp)) }
                        Box {
                            IconButton(onClick = { contents = true }) { Icon(Icons.AutoMirrored.Filled.List, "Sections", Modifier.size(22.dp)) }
                            DropdownMenu(contents, { contents = false }, Modifier.heightIn(max = 340.dp)) {
                                entry.readingRows.forEach { row -> row.heading?.let { section ->
                                    if (section.title.isNotBlank() && section.title != entry.language) DropdownMenuItem(text = { Text(section.title) }, onClick = {
                                        contents = false
                                        folded[row.key] = false
                                        val targetIndex = visibleReadingRows(entry.readingRows, folded.filterValues { it }.keys).indexOfFirst { it.key == row.key }
                                        scope.launch {
                                            androidx.compose.runtime.withFrameNanos { }
                                            scroll.animateScrollToItem(targetIndex + 1 + if (entry.preamble.isNotEmpty()) 1 else 0)
                                        }
                                    })
                                } }
                            }
                        }
                        IconButton(onClick = onBookmark) { Icon(if (bookmarked) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder, if (bookmarked) "Remove bookmark" else "Bookmark", Modifier.size(22.dp)) }
                    }
                    if (entry.displayTitle.isNotEmpty()) StyledText(entry.displayTitle, Modifier.fillMaxWidth().testTag("entry-title"), style = MaterialTheme.typography.displayMedium, onLink = readerLink)
                    else Text(entry.title, Modifier.fillMaxWidth().testTag("entry-title"), style = MaterialTheme.typography.displayMedium.copy(textDirection=TextDirection.Content))
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
            if (entry.preamble.isNotEmpty()) item("preamble", contentType = "paragraph") {
                FoldHeading("About this entry", folded["preamble"] == true) { folded["preamble"] = folded["preamble"] != true }
                if (folded["preamble"] != true) StyledText(compactSpans(entry.preamble), Modifier.padding(bottom = 4.dp), onLink = readerLink)
            }
            items(visibleRows, key = { it.key }, contentType = { if (it.heading != null) "heading" else it.block?.kind }) { row ->
                Column(Modifier.animateItem()) {
                row.heading?.let { section ->
                    if (section.title.isNotBlank() && (section.title != entry.language || section.blocks.any { it.kind != "blank" })) {
                        val label = if (section.title == entry.language) "Overview" else section.title
                        val angle by animateFloatAsState(if (folded[row.key] == true) -90f else 0f, label = "Section fold")
                        Row(Modifier.fillMaxWidth().clickable { folded[row.key] = folded[row.key] != true }.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(label, Modifier.weight(1f), style = if (row.meaningSection) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium)
                            if (row.meaningSection && section.blocks.any { it.kind !in setOf("definition", "blank") }) {
                                IconToggleButton(checked = folded[row.key + "-details"] != true, onCheckedChange = { folded[row.key + "-details"] = !it }) {
                                    Icon(Icons.Outlined.Notes, if (folded[row.key + "-details"] == true) "Show examples and notes for ${section.title}" else "Hide examples and notes for ${section.title}", Modifier.size(20.dp))
                                }
                            }
                            Icon(Icons.Filled.ExpandMore, if (folded[row.key] == true) "Expand $label" else "Collapse $label", Modifier.size(20.dp).rotate(angle))
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
            val linkedFiles = entry.sections.flatMap { it.blocks }.flatMap { block -> block.spans + block.table?.rows.orEmpty().flatten().flatMap { it.spans } }.filter { it.classes == "wikidict-media" }.map { it.target.removePrefix("File:").replace('_',' ') }.toSet()
            val remainingMedia = entry.media.filter { it.file !in linkedFiles }
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
        block.table != null -> Box(Modifier.padding(start = blockIndentDp(block).dp)) { TableView(block.table, onLink) }
        block.kind == "rule" -> HorizontalDivider()
        block.kind == "preformatted" -> Box(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).horizontalScroll(rememberScrollState()).padding(12.dp)) {
            StyledText(block.spans, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace), onLink = onLink, preserveWhitespace = true)
        }
        else -> {
            val prefix = blockPrefix(block)
            Row(Modifier.padding(start = blockIndentDp(block).dp)) {
                if (prefix.isNotEmpty()) Text(prefix, Modifier.widthIn(min = 28.dp).padding(top = 4.dp, end = 6.dp), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                StyledText(block.spans, Modifier.weight(1f), onLink = onLink)
            }
        }
    }
}

@Composable
private fun TableView(table: Table, onLink: (String) -> Unit) {
    val grid = remember(table) { tableGrid(table) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (table.caption.isNotEmpty()) StyledText(table.caption, onLink = onLink)
        Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
            Layout(content = {
                grid.cells.forEach { placed ->
                    Box(Modifier.background(if (placed.cell.header) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surface).padding(10.dp)) {
                        StyledText(placed.cell.spans, weight = if (placed.cell.header) FontWeight.SemiBold else null, onLink = onLink)
                    }
                }
            }) { measurables, _ ->
                val columnWidth = 136.dp.roundToPx()
                val heights = IntArray(grid.rows) { 40.dp.roundToPx() }
                grid.cells.forEachIndexed { index, placed ->
                    val needed = measurables[index].maxIntrinsicHeight(columnWidth * placed.cell.colspan)
                    val available = (placed.row until placed.row + placed.cell.rowspan).sumOf { heights[it] }
                    if (needed > available) heights[placed.row + placed.cell.rowspan - 1] += needed - available
                }
                val offsets = IntArray(grid.rows + 1)
                heights.forEachIndexed { i, height -> offsets[i + 1] = offsets[i] + height }
                val children = measurables.mapIndexed { index, measurable ->
                    val placed = grid.cells[index]
                    measurable.measure(Constraints.fixed(columnWidth * placed.cell.colspan, offsets[placed.row + placed.cell.rowspan] - offsets[placed.row]))
                }
                layout(columnWidth * grid.columns, offsets.last()) {
                    children.forEachIndexed { index, child -> val placed = grid.cells[index]; child.placeRelative(columnWidth * placed.column, offsets[placed.row]) }
                }
            }
        }
    }
}

@Composable
private fun StyledText(source: List<Span>, modifier: Modifier = Modifier, weight: FontWeight? = null, style: TextStyle = MaterialTheme.typography.bodyLarge, onLink: (String) -> Unit = {}, preserveWhitespace: Boolean = false) {
    val spans = remember(source, preserveWhitespace) { if (preserveWhitespace) source else compactSpans(source) }
    val availableMedia = LocalEntryMedia.current
    val embedded = spans.filter { it.classes == "wikidict-media" && it.target.startsWith("File:") }.mapNotNull { span -> availableMedia.firstOrNull { it.file == span.target.removePrefix("File:").replace('_',' ') } }.distinctBy { it.file }
    if (embedded.isNotEmpty()) {
        Column(modifier) {
            val text = spans.filter { it.classes != "wikidict-media" }.dropLastWhile { it.text.isBlank() && it.trail.isBlank() }
            if (text.any { it.text.isNotBlank() }) StyledText(text, weight = weight, style = style, onLink = onLink)
            embedded.forEach { MediaView(it, LocalReaderSettings.current, showFileName = false, edition=LocalEntryEdition.current) }
        }
        return
    }
    val linkColor = MaterialTheme.colorScheme.primary
    val codeColor = MaterialTheme.colorScheme.surfaceContainer
    val cache = LocalTextCache.current
    val currentLink = rememberUpdatedState(onLink)
    val annotated = remember(spans, weight, linkColor, codeColor, cache) {
        cache?.values?.get(spans)?.get(weight) ?: buildAnnotatedString {
            val linkStyle = TextLinkStyles(style = SpanStyle(color = linkColor), pressedStyle = SpanStyle(textDecoration = TextDecoration.Underline))
            spans.forEach { span ->
                val start = length
                if (span.direction == "rtl") append('\u2067') else if (span.direction == "ltr") append('\u2066')
                append(if (span.kind == "line_break") "\n" else span.text)
                if (span.direction in listOf("rtl", "ltr")) append('\u2069')
                val end = length
                append(span.trail)
                if (end > start) {
                    if (weight != null || span.bold || span.italic || span.code || span.small || span.superscript || span.subscript || span.strike || span.underline) addStyle(SpanStyle(
                        fontWeight = if (span.bold) FontWeight.Bold else weight,
                        fontStyle = if (span.italic) FontStyle.Italic else null,
                        fontFamily = if (span.code) FontFamily.Monospace else null,
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
                    else if (span.kind == "external_link" && (span.target.startsWith("https://") || span.target.startsWith("http://")))
                        addLink(LinkAnnotation.Url(span.target, linkStyle), start, end)
                }
            }
        }.also { cache?.values?.getOrPut(spans) { mutableMapOf() }?.put(weight, it) }
    }
    Text(annotated, modifier = modifier, style = style.copy(textDirection = TextDirection.Content))
}
