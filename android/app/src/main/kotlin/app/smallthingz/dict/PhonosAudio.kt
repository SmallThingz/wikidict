package app.smallthingz.dict

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** The compact playback owner and its superscript description link are distinct inline targets.
 * Source text outside that no-wrap pair goes through the normal styled-span renderer. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun PhonosInlineContent(spans: List<Span>, modifier: Modifier, weight: FontWeight?, style: TextStyle,
    owners: MediaOwners, settings: AppSettings, onLink: (EntryLink) -> Unit) {
    val edition = LocalEntryEdition.current
    FlowRow(modifier) {
        var index = 0
        while (index < spans.size) {
            val start = index++
            val span = spans[start]
            if (!span.isPhonosButton) {
                while (index < spans.size && !spans[index].isPhonosButton) index++
                StyledText(spans.subList(start, index), Modifier.alignByBaseline(), weight, style, onLink, preserveWhitespace = true)
            } else {
                val attribution = spans.getOrNull(index)?.takeIf { it.kind == "link" && it.superscript && it.audioControl == null }
                if (attribution != null) index++
                key(start, span.target) {
                    Row(Modifier.alignByBaseline()) {
                        Box(Modifier.alignByBaseline()) {
                            MediaView(checkNotNull(owners.media(span)), settings, showFileName = false, edition = edition,
                                showCaption = false, audioControl = span.audioControl, phonosSource = span, phonosStyle = style)
                        }
                        if (attribution != null) StyledText(listOf(attribution), Modifier.alignByBaseline(), weight, style, onLink,
                            preserveWhitespace = true)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PhonosPlaybackButton(source: Span, style: TextStyle, enabled: Boolean, loading: Boolean,
    playing: Boolean, progress: AudioPlaybackProgress?, error: String?, onClick: () -> Unit) {
    val label = checkNotNull(source.tooltip)
    val control = checkNotNull(source.audioControl)
    val interactions = remember { MutableInteractionSource() }
    val hovered by interactions.collectIsHoveredAsState()
    val focused by interactions.collectIsFocusedAsState()
    val density = LocalDensity.current
    val sourceStyle = styledTextAnnotation(listOf(source.copy(kind = "text", target = "", classes = "", audioControl = null,
        tooltip = null)), FontWeight.Normal, style) {}
    val em = sourceStyle.spanStyles.firstOrNull { it.item.fontSize.isSp }?.item?.fontSize ?: style.fontSize
    val icon = with(density) { em.toDp() }
    val iconWidth = with(density) { (icon + 2.dp).toSp() }
    val text = buildAnnotatedString {
        appendInlineContent("volume", "\uFFFC")
        append(sourceStyle)
    }
    val foreground = canonicalColorArgb(source.foreground)?.let { Color(it.toInt()) } ?: LocalContentColor.current
    val theme = MaterialTheme.colorScheme
    val focusColor = (control.focus?.color as? FigureColor.Rgb)?.value?.let(::canonicalColorArgb)?.let { Color(it.toInt()) }
        ?: theme.primary
    val highlight = if (LocalReaderDarkTheme.current) theme.primaryContainer else Color(0xffe8eeff)
    val errorColor = if (LocalReaderDarkTheme.current) theme.surfaceVariant else Color(0xffeaecf0)
    val fraction = if (!playing || progress == null || progress.durationMillis <= 0) 0f
        else (progress.positionMillis.toFloat() / progress.durationMillis).coerceIn(0f, 1f)
    TooltipBox(positionProvider = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Above),
        tooltip = { PlainTooltip { Text(label) } }, state = rememberTooltipState()) {
        Text(text, modifier = Modifier.drawBehind {
            if (error != null) drawRect(errorColor) else if (hovered && enabled) drawRect(highlight)
            if (fraction > 0f) drawRect(highlight, size = Size(size.width * fraction, size.height))
            if (focused && control.focus?.mode != AudioControlFocusMode.AuthoredNone && control.focus?.color != FigureColor.Transparent)
                drawRect(focusColor, style = Stroke(1.dp.toPx()))
        }.clickable(interactionSource = interactions, indication = null, enabled = enabled, role = Role.Button,
            onClickLabel = label, onClick = onClick).semantics {
            contentDescription = label
            if (error != null) stateDescription = error else if (loading) stateDescription = "Loading"
            else if (playing) stateDescription = "Playing"
        }, style = style, color = foreground, softWrap = false, maxLines = 1,
            inlineContent = mapOf("volume" to InlineTextContent(Placeholder(iconWidth, em, PlaceholderVerticalAlign.AboveBaseline)) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                    Icon(painterResource(R.drawable.phonos_volume_up), null,
                        Modifier.size(icon).offset(y = icon * .1f), tint = foreground)
                }
            }))
    }
}
