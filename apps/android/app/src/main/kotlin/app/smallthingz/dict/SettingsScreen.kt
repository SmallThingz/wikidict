package app.smallthingz.dict

import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(learning: LearningStore, onDictionaries: () -> Unit = {}) {
    val settings = learning.data.settings
    val media = MediaCache.get(LocalContext.current)
    val scope = rememberCoroutineScope()
    var clear by remember { mutableStateOf<String?>(null) }
    val confirmationVisibility = remember { MutableTransitionState(false) }
    val confirmationReveal = remember { BringIntoViewRequester() }
    confirmationVisibility.targetState = clear != null
    LaunchedEffect(clear, confirmationVisibility.isIdle, confirmationVisibility.currentState) {
        if (clear != null && confirmationVisibility.isIdle && confirmationVisibility.currentState) {
            // Reveal the complete row after its animated size has reached the final bounds.
            withFrameNanos { }
            confirmationReveal.bringIntoView()
        }
    }
    LazyColumn(Modifier.fillMaxSize().testTag("settings-scroll"), contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { Text("Settings", style = MaterialTheme.typography.headlineMedium) }
        item { TextButton(onClick = onDictionaries, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Outlined.FolderOpen, null); Spacer(Modifier.width(12.dp))
            Text("Dictionaries", Modifier.weight(1f)); Icon(Icons.Outlined.ChevronRight, null)
        } }
        item {
            PreferenceGroup(Icons.Outlined.Palette, "Atmosphere") {
                Segments(listOf("system", "light", "dark"), settings.darkMode, { it.replaceFirstChar(Char::uppercase) }, { mode -> learning.updateSettings { it.copy(darkMode = mode) } }, Modifier.fillMaxWidth())
            }
        }
        item {
            PreferenceGroup(Icons.Outlined.UnfoldLess, "Start folded") {
                TogglePreference("Pronunciation", settings.collapsePronunciation) { value -> learning.updateSettings { it.copy(collapsePronunciation=value) } }
                TogglePreference("Other sections", settings.collapseOtherSections) { value -> learning.updateSettings { it.copy(collapseOtherSections=value) } }
                TogglePreference("Examples & notes", settings.collapseDetails) { value -> learning.updateSettings { it.copy(collapseDetails=value) } }
                TogglePreference("Etymology", settings.collapseEtymology) { value -> learning.updateSettings { it.copy(collapseEtymology=value) } }
            }
        }
        item {
            PreferenceGroup(Icons.Outlined.PermMedia, "Images & sound") {
                TogglePreference("Load images online", settings.allowImages) { value -> learning.updateSettings { it.copy(allowImages=value) } }
                TogglePreference("Play online audio", settings.allowAudio) { value -> learning.updateSettings { it.copy(allowAudio=value) }; if(!value) MediaPlayback.stop() }
                ReaderSlider("Media cache", settings.mediaCacheMb, SliderScale(0, 4096, logarithmic = true), { if (it == 0) "Off" else if (it >= 1024) "%.1f GB".format(it / 1024f) else "$it MB" }) { value ->
                    learning.updateSettings { it.copy(mediaCacheMb = value) }; scope.launch { media.trim(value) }
                }
                TextButton(onClick={scope.launch{MediaPlayback.stop();media.clear()}}) { Text("Clear cached media") }
            }
        }
        item {
            PreferenceGroup(Icons.Outlined.History, "Your trail") {
                ReaderSlider("Remember words", if (settings.historyEnabled) settings.historyLimit else 0,
                    SliderScale(0, 100_000, logarithmic = true), { if (it == 0) "Off" else "$it" }) { value ->
                    learning.updateSettings { it.copy(historyEnabled = value > 0, historyLimit = if (value == 0) it.historyLimit else value) }
                }
            }
        }
        item {
            PreferenceGroup(Icons.Outlined.AutoAwesome, "A little practice") {
                ReaderSlider("Questions per round", settings.quizLength, SliderScale(3, 50)) { value -> learning.updateSettings { it.copy(quizLength = value) } }
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
            androidx.compose.animation.AnimatedVisibility(visibleState = confirmationVisibility) {
                Row(Modifier.fillMaxWidth().bringIntoViewRequester(confirmationReveal).padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
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

@Composable
private fun TogglePreference(label: String, checked: Boolean, onChange: (Boolean)->Unit) {
    Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
        Text(label,Modifier.weight(1f),style=MaterialTheme.typography.bodyMedium)
        ReaderSwitch(checked,label,onChange)
    }
}
