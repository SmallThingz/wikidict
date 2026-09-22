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
import androidx.compose.material.icons.outlined.VolumeUp
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.ui.platform.LocalContext
import androidx.compose.material3.*
import androidx.compose.runtime.*
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
private val LocalReaderSettings = staticCompositionLocalOf { AppSettings() }
private val LocalTextCache = staticCompositionLocalOf<TextCache?> { null }

@Composable
fun EntryView(entry: Entry, bookmarked: Boolean, onBookmark: () -> Unit, onLink: (String) -> Unit = {}, settings: AppSettings = AppSettings()) {
    val uri = LocalUriHandler.current
    val context = LocalContext.current
    DisposableEffect(entry.key) { onDispose { SpeechPlayback.stop() } }
    val currentLink = rememberUpdatedState(onLink)
    val colors = MaterialTheme.colorScheme
    val cache = remember(entry, colors.primary, colors.surfaceContainer) { TextCache(currentLink) }
    CompositionLocalProvider(LocalTextCache provides cache, LocalEntryMedia provides entry.media, LocalReaderSettings provides settings) {
      key(entry.key) {
        val scroll = rememberLazyListState()
        val scope = rememberCoroutineScope()
        var contents by remember { mutableStateOf(false) }
        val folded = remember(entry.key, settings.collapsePronunciation, settings.collapseEtymology) {
            mutableStateMapOf<String, Boolean>().apply {
                entry.readingRows.forEach { row -> row.heading?.let {
                    this[row.key] = (settings.collapsePronunciation && it.title.startsWith("Pronunciation", true)) ||
                        (settings.collapseEtymology && it.title.startsWith("Etymology", true))
                } }
            }
        }
        val visibleRows = visibleReadingRows(entry.readingRows, folded.filterValues { it }.keys)
        LazyColumn(Modifier.fillMaxSize().testTag("entry-scroll"), state = scroll, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)) {
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
                    if (entry.displayTitle.isNotEmpty()) StyledText(entry.displayTitle, style = MaterialTheme.typography.displayMedium, onLink = onLink)
                    else Text(entry.title, style = MaterialTheme.typography.displayMedium)
                    SpeechPlayback.error?.let { message ->
                        Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                        TextButton(onClick = { runCatching { context.startActivity(android.content.Intent("com.android.settings.TTS_SETTINGS")) } }) { Text("Speech settings") }
                    }
                }
            }
            if (entry.preamble.isNotEmpty()) item("preamble", contentType = "paragraph") { StyledText(entry.preamble, Modifier.padding(bottom = 6.dp), onLink = onLink) }
            items(visibleRows, key = { it.key }, contentType = { if (it.heading != null) "heading" else it.block?.kind }) { row ->
                Column(Modifier.animateItem()) {
                row.heading?.let { section ->
                    if (section.title.isNotBlank() && section.title != entry.language) {
                        val angle by animateFloatAsState(if (folded[row.key] == true) -90f else 0f, label = "Section fold")
                        Row(Modifier.fillMaxWidth().clickable { folded[row.key] = folded[row.key] != true }.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(section.title, Modifier.weight(1f), style = if (section.level <= 3) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium)
                            Icon(Icons.Filled.ExpandMore, if (folded[row.key] == true) "Expand ${section.title}" else "Collapse ${section.title}", Modifier.size(20.dp).rotate(angle))
                        }
                    }
                }
                row.block?.let { block ->
                    Row(Modifier.padding(bottom = if (row.compact) 2.dp else 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) { BlockView(block, onLink) }
                        block.spans.filter { it.role == "pronunciation" && Pronunciation.ssml(it.text, entry.languageCode) != null }.distinctBy { it.text }.forEach { span ->
                            IconButton(onClick = { SpeechPlayback.play(context, entry.title, entry.languageCode, span.text) }) {
                                Icon(if (SpeechPlayback.active == span.text) Icons.Outlined.Stop else Icons.Outlined.VolumeUp, "Pronounce ${span.text} offline", Modifier.size(18.dp))
                            }
                        }
                    }
                }
                }
            }
            if (entry.references.isNotEmpty()) item("references-heading") { Text("References", Modifier.padding(top = 18.dp, bottom = 10.dp), style = MaterialTheme.typography.titleLarge) }
            items(entry.references, key = { "reference-${it.number}" }, contentType = { "reference" }) { ref ->
                val label = if (ref.group.isBlank()) "[${ref.groupNumber}]" else "[${ref.group} ${ref.groupNumber}]"
                Row(Modifier.padding(bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { Text(label, style = MaterialTheme.typography.labelMedium, color = colors.primary); StyledText(ref.spans, Modifier.weight(1f), onLink = onLink) }
            }
            val linkedFiles = entry.sections.flatMap { it.blocks }.flatMap { block -> block.spans + block.table?.rows.orEmpty().flatten().flatMap { it.spans } }.filter { it.classes == "wikidict-media" }.map { it.target.removePrefix("File:").replace('_',' ') }.toSet()
            val remainingMedia = entry.media.filter { it.file !in linkedFiles }
            if (remainingMedia.isNotEmpty()) item("media-heading") { Text("Media", Modifier.padding(top = 18.dp, bottom = 10.dp), style = MaterialTheme.typography.titleLarge) }
            remainingMedia.forEachIndexed { index, media -> item("media-$index", contentType = "media") {
                MediaView(media, settings)
            } }
            item("attribution") {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(onClick = { uri.openUri("https://en.wiktionary.org/w/index.php?title=" + java.net.URLEncoder.encode(entry.title,"UTF-8") + "&action=history") }) { Text("Wiktionary contributors",style=MaterialTheme.typography.labelSmall) }
                    TextButton(onClick = { uri.openUri("https://creativecommons.org/licenses/by-sa/4.0/") }) { Text("CC BY-SA 4.0",style=MaterialTheme.typography.labelSmall) }
                }
            }
        }
      }
    }
}

@Composable
private fun BlockView(block: Block, onLink: (String) -> Unit) {
    when {
        block.table != null -> TableView(block.table, onLink)
        block.kind == "rule" -> HorizontalDivider()
        block.kind == "preformatted" -> Box(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).horizontalScroll(rememberScrollState()).padding(12.dp)) {
            StyledText(block.spans, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace), onLink = onLink)
        }
        else -> {
            val prefix = when (block.kind) {
                "definition" -> if (block.number.isNotBlank()) "${block.number.padStart(2, '0')}" else "•"
                "example", "quotation" -> "│ "
                "list_item" -> "• "
                "list_detail" -> "↳ "
                else -> ""
            }
            Row(Modifier.padding(start = ((block.depth - 1).coerceIn(0, 8) * 7).dp)) {
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
private fun StyledText(spans: List<Span>, modifier: Modifier = Modifier, weight: FontWeight? = null, style: TextStyle = MaterialTheme.typography.bodyLarge, onLink: (String) -> Unit = {}) {
    val availableMedia = LocalEntryMedia.current
    val embedded = spans.filter { it.classes == "wikidict-media" && it.target.startsWith("File:") }.mapNotNull { span -> availableMedia.firstOrNull { it.file == span.target.removePrefix("File:").replace('_',' ') } }.distinctBy { it.file }
    if (embedded.isNotEmpty()) {
        Column(modifier) {
            val text = spans.filter { it.classes != "wikidict-media" }.dropLastWhile { it.text.isBlank() && it.trail.isBlank() }
            if (text.any { it.text.isNotBlank() }) StyledText(text, weight = weight, style = style, onLink = onLink)
            embedded.forEach { MediaView(it, LocalReaderSettings.current, showFileName = false) }
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
