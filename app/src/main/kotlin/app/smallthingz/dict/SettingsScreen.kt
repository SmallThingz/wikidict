package app.smallthingz.dict

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun SettingsScreen(learning: LearningStore) {
    val settings = learning.data.settings
    var clear by remember { mutableStateOf<String?>(null) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = 24.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
        item { Text("Settings", style = MaterialTheme.typography.headlineMedium) }
        item {
            PreferenceGroup(Icons.Outlined.Palette, "Atmosphere") {
                Segments(listOf("system", "light", "dark"), settings.darkMode, { it.replaceFirstChar(Char::uppercase) }, { mode -> learning.updateSettings { it.copy(darkMode = mode) } }, Modifier.fillMaxWidth())
            }
        }
        item {
            PreferenceGroup(Icons.Outlined.History, "Your trail") {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Remember words", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    ReaderSwitch(settings.historyEnabled, "Remember words") { enabled -> learning.updateSettings { it.copy(historyEnabled = enabled) } }
                }
                androidx.compose.animation.AnimatedVisibility(settings.historyEnabled) {
                    Segments(listOf(25, 100, 250, 500), settings.historyLimit, { "$it" }, { value -> learning.updateSettings { it.copy(historyLimit = value) } }, Modifier.fillMaxWidth())
                }
            }
        }
        item {
            PreferenceGroup(Icons.Outlined.AutoAwesome, "A little practice") {
                Text("Questions per round", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Segments(listOf(5, 10, 20, 50), settings.quizLength, { "$it" }, { value -> learning.updateSettings { it.copy(quizLength = value) } }, Modifier.fillMaxWidth())
                Spacer(Modifier.height(6.dp))
                Text("Pick words from", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Segments(listOf("all", "history", "bookmarks"), settings.randomPool, { when(it) { "all" -> "Everywhere"; "history" -> "History"; else -> "Saved" } }, { value -> learning.updateSettings { it.copy(randomPool = value) } }, Modifier.fillMaxWidth())
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TextButton(onClick = { clear = "history" }, modifier = Modifier.weight(1f)) { Icon(Icons.Outlined.History, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("Clear history") }
                TextButton(onClick = { clear = "scores" }, modifier = Modifier.weight(1f)) { Icon(Icons.Outlined.RestartAlt, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("Reset scores") }
            }
            androidx.compose.animation.AnimatedVisibility(clear != null) {
                Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Clear ${clear.orEmpty()}?", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    TextButton(onClick = { clear = null }) { Text("Keep") }
                    TextButton(onClick = { if (clear == "history") learning.clearHistory() else learning.clearStudy(); clear = null }) { Text("Clear") }
                }
            }
        }
    }
}

@Composable
private fun PreferenceGroup(icon: ImageVector, title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(icon, null, Modifier.size(19.dp), tint = MaterialTheme.colorScheme.primary)
            Text(title, style = MaterialTheme.typography.titleLarge.copy(fontSize = 24.sp))
        }
        content()
    }
}
