package app.smallthingz.dict

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
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

@Composable
fun EntryView(entry: Entry, bookmarked: Boolean, onBookmark: () -> Unit, onLink: (String) -> Unit = {}) {
    key(entry.key) {
        LazyColumn(Modifier.fillMaxSize().testTag("entry-scroll"), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item("title") {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column(Modifier.weight(1f)) {
                        Text(entry.language ?: entry.kind.replace('_', ' '), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (entry.displayTitle.isNotEmpty()) StyledText(entry.displayTitle, style = MaterialTheme.typography.displayMedium, onLink = onLink)
                        else Text(entry.title, style = MaterialTheme.typography.displayMedium)
                    }
                    IconButton(onClick = onBookmark) { Icon(if (bookmarked) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder, if (bookmarked) "Remove bookmark" else "Bookmark") }
                }
            }
            if (entry.preamble.isNotEmpty()) item("preamble") { StyledText(entry.preamble, onLink = onLink) }
            entry.sections.forEachIndexed { sectionIndex, section ->
                if (section.title.isNotBlank() && section.title != entry.language) item("heading-$sectionIndex") {
                    Text(section.title, style = if (section.level <= 3) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
                section.blocks.forEachIndexed { blockIndex, block ->
                    if (block.kind != "blank") item("block-$sectionIndex-$blockIndex") { BlockView(block, onLink) }
                }
            }
            if (entry.references.isNotEmpty()) item("references-heading") { Text("References", style = MaterialTheme.typography.titleMedium) }
            entry.references.forEachIndexed { index, ref -> item("reference-$index") {
                val label = if (ref.group.isBlank()) "[${ref.groupNumber}]" else "[${ref.group} ${ref.groupNumber}]"
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { Text(label, fontWeight = FontWeight.SemiBold); StyledText(ref.spans, Modifier.weight(1f), onLink = onLink) }
            } }
            if (entry.media.isNotEmpty()) item("media-heading") { Text("Media", style = MaterialTheme.typography.titleMedium) }
            entry.media.forEachIndexed { index, media -> item("media-$index") {
                Column {
                    Text(media.file, style = MaterialTheme.typography.bodyMedium)
                    Text(listOf(media.kind, media.caption).filter { it.isNotBlank() }.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } }
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
                "definition" -> if (block.number.isNotBlank()) "${block.number}. " else "• "
                "example", "quotation" -> "│ "
                "list_item" -> "• "
                "list_detail" -> "↳ "
                else -> ""
            }
            Row(Modifier.padding(start = (block.depth.coerceIn(0, 8) * 7).dp)) {
                if (prefix.isNotEmpty()) Text(prefix, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
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
    val linkColor = MaterialTheme.colorScheme.primary
    val codeColor = MaterialTheme.colorScheme.surfaceContainer
    val annotated = remember(spans, weight, linkColor, codeColor, onLink) {
        buildAnnotatedString {
            spans.forEach { span ->
                val start = length
                if (span.direction == "rtl") append('\u2067') else if (span.direction == "ltr") append('\u2066')
                append(if (span.kind == "line_break") "\n" else span.text)
                if (span.direction in listOf("rtl", "ltr")) append('\u2069')
                val end = length
                append(span.trail)
                if (end > start) {
                    addStyle(SpanStyle(
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
                    val linkStyle = TextLinkStyles(style = SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline))
                    if (span.kind == "link" && span.target.isNotBlank()) addLink(LinkAnnotation.Clickable(span.target, linkStyle) { onLink(span.target) }, start, end)
                    else if (span.kind == "external_link" && (span.target.startsWith("https://") || span.target.startsWith("http://")))
                        addLink(LinkAnnotation.Url(span.target, linkStyle), start, end)
                }
            }
        }
    }
    Text(annotated, modifier = modifier, style = style.copy(textDirection = TextDirection.Content))
}
