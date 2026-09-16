package app.smallthingz.dict

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp

@Composable
fun EntryView(entry: Entry, bookmarked: Boolean, onBookmark: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Column(Modifier.weight(1f)) {
                Text(entry.language ?: entry.kind.replace('_', ' '), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (entry.displayTitle.isNotEmpty()) StyledText(entry.displayTitle, style = MaterialTheme.typography.displayMedium)
                else Text(entry.title, style = MaterialTheme.typography.displayMedium)
            }
            IconButton(onClick = onBookmark) { Icon(if (bookmarked) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder, if (bookmarked) "Remove bookmark" else "Bookmark") }
        }
        Spacer(Modifier.height(12.dp))
        ReadingView(entry)
    }
}
@Composable
private fun ReadingView(entry: Entry) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        entry.sections.forEach { section ->
            if (section.title.isNotBlank()) Text(section.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            section.blocks.filterNot { it.kind == "blank" }.forEach { block -> BlockView(block) }
        }
        if (entry.references.isNotEmpty()) {
            HorizontalDivider()
            Text("References", style = MaterialTheme.typography.titleMedium)
            entry.references.forEach { ref ->
                val label = if (ref.group.isBlank()) "[${ref.groupNumber}]" else "[${ref.group} ${ref.groupNumber}]"
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { Text(label, fontWeight = FontWeight.SemiBold); StyledText(ref.spans, Modifier.weight(1f)) }
            }
        }
        Spacer(Modifier.height(48.dp))
    }
}

@Composable
private fun BlockView(block: Block) {
    when {
        block.table != null -> TableView(block.table)
        block.kind == "rule" -> HorizontalDivider()
        block.kind == "preformatted" -> Surface(tonalElevation = 2.dp, shape = MaterialTheme.shapes.small) { SelectionContainer { Text(textOf(block.spans), Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall) } }
        else -> {
            val prefix = when (block.kind) {
                "definition" -> if (block.number.isNotBlank()) "${block.number}. " else "• "
                "example" -> "Example · "
                "quotation" -> "Quote · "
                "list_item" -> "• "
                "list_detail" -> "↳ "
                else -> ""
            }
            Row(Modifier.padding(start = (block.depth.coerceAtMost(8) * 7).dp)) {
                if (prefix.isNotEmpty()) Text(prefix, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
                StyledText(block.spans, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TableView(table: Table) {
    Column(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
        if (table.caption.isNotEmpty()) StyledText(table.caption)
        table.rows.forEach { row ->
            Row {
                row.forEach { cell -> Surface(Modifier.widthIn(min = 96.dp).padding(1.dp), tonalElevation = if (cell.header) 3.dp else 1.dp) {
                    Box(Modifier.padding(8.dp)) { StyledText(cell.spans, weight = if (cell.header) FontWeight.SemiBold else null) }
                } }
            }
        }
    }
}
@Composable
private fun StyledText(spans: List<Span>, modifier: Modifier = Modifier, weight: FontWeight? = null, style: TextStyle = MaterialTheme.typography.bodyLarge) {
    val annotated = buildAnnotatedString {
        spans.forEach { span ->
            val start = length
            append(span.text)
            append(span.trail)
            if (length > start) addStyle(SpanStyle(
                fontWeight = if (span.bold) FontWeight.Bold else weight,
                fontStyle = if (span.italic) FontStyle.Italic else null,
                textDecoration = when {
                    span.strike && span.underline -> TextDecoration.combine(listOf(TextDecoration.LineThrough, TextDecoration.Underline))
                    span.strike -> TextDecoration.LineThrough
                    span.underline -> TextDecoration.Underline
                    else -> null
                },
            ), start, length)
        }
    }
    Text(annotated, modifier = modifier, style = style)
}
