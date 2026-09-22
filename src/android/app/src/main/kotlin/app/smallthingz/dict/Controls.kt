package app.smallthingz.dict

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
fun DockButton(icon: ImageVector, label: String, selected: Boolean, onClick: () -> Unit) {
    val color by animateColorAsState(if (selected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant, label = "dock ink")
    val fill by animateColorAsState(if (selected) MaterialTheme.colorScheme.primaryContainer else Color.Transparent, label = "dock fill")
    Box(Modifier.size(56.dp, 48.dp).clip(RoundedCornerShape(18.dp)).background(fill)
        .selectable(selected = selected, role = Role.Tab, onClick = onClick).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = color, modifier = Modifier.size(22.dp))
    }
}

@Composable
fun <T> Segments(values: List<T>, selected: T, label: (T) -> String, onSelect: (T) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.clip(RoundedCornerShape(18.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow).padding(4.dp).selectableGroup()) {
        values.forEach { value ->
            val fill by animateColorAsState(if (value == selected) MaterialTheme.colorScheme.surfaceContainerHigh else Color.Transparent, label = "segment")
            Box(Modifier.weight(1f).heightIn(min = 44.dp).clip(RoundedCornerShape(14.dp)).background(fill)
                .selectable(value == selected, role = Role.RadioButton, onClick = { onSelect(value) }).padding(horizontal = 3.dp, vertical = 10.dp), contentAlignment = Alignment.Center) {
                Text(label(value), style = MaterialTheme.typography.labelLarge, color = if (value == selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
fun ReaderSwitch(checked: Boolean, label: String, onChange: (Boolean) -> Unit) {
    val track by animateColorAsState(if (checked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceContainerHigh, label = "switch track")
    val offset by animateDpAsState(if (checked) 18.dp else 0.dp, label = "switch thumb")
    Box(Modifier.size(52.dp, 48.dp).toggleable(checked, role = Role.Switch, onValueChange = onChange).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(44.dp, 26.dp).background(track, RoundedCornerShape(20.dp)).padding(4.dp)) {
            Box(Modifier.offset(x = offset).size(18.dp).background(if (checked) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant, RoundedCornerShape(20.dp)))
        }
    }
}
