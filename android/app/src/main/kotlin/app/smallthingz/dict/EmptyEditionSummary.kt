package app.smallthingz.dict

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
internal fun EmptyEditionSummary(edition: EmptyEditionInfo, onLibrary: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(sourceLabel(edition.edition), style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("Completed release", style = MaterialTheme.typography.headlineLarge)
        Text("No published dictionaries", style = MaterialTheme.typography.titleLarge)
        Text("${edition.sourcePages} source pages processed. This release contains no word entries to browse.",
            style = MaterialTheme.typography.bodyLarge)
        Text("Your other dictionaries and saved words are unchanged.", style = MaterialTheme.typography.bodyMedium)
        TextButton(onClick = onLibrary) { Text("Open library") }
    }
}
