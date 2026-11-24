package app.smallthingz.dict

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em

internal val LocalTableVisibilityPreferences = staticCompositionLocalOf<SharedPreferences?> { null }
internal val LocalTableVisibilityVisit = staticCompositionLocalOf<TableVisibilityVisit?> { null }
internal val LocalDisclosureTable = staticCompositionLocalOf<DisclosureTableProjection?> { null }

/** The rendered rows share the original cell objects, including their spans, links and rowspans. */
internal class DisclosureTableProjection(val source: Table, val path: String, val expanded: Boolean) {
    val policy = requireNotNull(source.disclosure)
    private val visible = source.rows.indices.filter { index ->
        when (policy.rowModes[index]) {
            TableRowMode.Always -> true
            TableRowMode.Collapsed -> !expanded
            TableRowMode.Expanded -> expanded
        }
    }
    private val sourceOffsets = IntArray(source.rows.size + 1).also { offsets ->
        for (row in source.rows.indices) offsets[row + 1] = offsets[row] + source.rows[row].size
    }
    val headerIndex = sourceOffsets[policy.headerRow] + policy.headerCell
    val cellIndices = visible.flatMap { sourceOffsets[it] until sourceOffsets[it + 1] }
    val displayed = source.copy(rows = visible.map(source.rows::get), disclosure = null)
    // The table solver compresses boundaries for measurement. Accessibility keeps the actual
    // HTML column indices and colspan, including a header-only table whose colspan is eight.
    val physicalColumns = mutableListOf<Int>()
    val columnCount = tableGrid(displayed, physicalColumns).cells.mapIndexed { index, placement ->
        physicalColumns[index] + placement.cell.colspan
    }.maxOrNull() ?: 0
}

private class TableOccurrence(val table: Table, val path: String) {
    override fun equals(other: Any?) = other is TableOccurrence && other.table === table && other.path == path
    override fun hashCode() = 31 * System.identityHashCode(table) + path.hashCode()
}

/** An individual header changes this visit. Only the category control changes saved defaults. */
internal class TableVisibilityVisit(val categories: Map<String, Boolean>, private val categorySizes: Map<String, Int>,
    private val edition: String,
    private val prefs: SharedPreferences) {
    private val local = mutableStateMapOf<TableOccurrence, Boolean>()
    private val visitStatus = mutableStateMapOf<String, Boolean>()
    private fun preference(category: String) = "$edition/$category"
    fun categoryExpanded(category: String): Boolean = visitStatus[category] ?: prefs.getBoolean(preference(category), categories.getValue(category))
    fun expanded(table: Table, path: String): Boolean {
        val policy = requireNotNull(table.disclosure)
        return local[TableOccurrence(table, path)] ?: categoryExpanded(policy.category)
    }
    fun toggle(table: Table, path: String) {
        val category = requireNotNull(table.disclosure).category
        val occurrence = TableOccurrence(table, path)
        val value = !expanded(table, path)
        if (value == categoryExpanded(category)) {
            local.remove(occurrence)
            return
        }
        local[occurrence] = value
        val changed = local.keys.filter { it.table.disclosure?.category == category }
        if (changed.size == categorySizes.getValue(category)) {
            // The original sidebar follows unanimous local changes during this visit.
            visitStatus[category] = value
            changed.forEach(local::remove)
        }
    }
    fun toggleCategory(category: String) {
        val value = !categoryExpanded(category)
        prefs.edit().putBoolean(preference(category), value).apply()
        visitStatus[category] = value
        local.keys.filter { it.table.disclosure?.category == category }.forEach(local::remove)
    }
}

@Composable
internal fun rememberTableVisibilityVisit(entry: Entry, epoch: Any, policies: TableVisibilityPolicies): TableVisibilityVisit? {
    if (policies.categories.isEmpty()) return null
    val context = LocalContext.current
    val injected = LocalTableVisibilityPreferences.current
    val edition = entry.edition.substringBeforeLast('-')
    return remember(epoch, context, injected, edition) {
        TableVisibilityVisit(policies.categories, policies.categorySizes, edition, injected ?: context.getSharedPreferences("dict.table.visibility.v1", Context.MODE_PRIVATE))
    }
}

@Composable
internal fun DisclosureHeader(projection: DisclosureTableProjection, toggle: () -> Unit, content: @Composable () -> Unit) {
    val label = if (projection.expanded) projection.policy.collapseLabel else projection.policy.expandLabel
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = toggle)
        .testTag("table-disclosure/${projection.path}/cell-${projection.headerIndex}")
        .semantics {
            contentDescription = label
            stateDescription = if (projection.expanded) "Expanded" else "Collapsed"
        }, verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { content() }
        Text("[$label]", Modifier.padding(start = 2.dp), style = LocalTextStyle.current.copy(fontSize = .83.em,
            fontWeight = FontWeight.Normal), softWrap = false)
    }
}
