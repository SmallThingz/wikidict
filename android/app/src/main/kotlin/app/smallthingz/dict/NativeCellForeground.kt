package app.smallthingz.dict

import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb

/** Only a marked cell installs this context. Body inheritance is distinct from the
 * existing link fallback and from a real foreground declared by an inline ancestor. */
internal data class NativeCellForegroundContext(
    val plain: Int,
    val link: Int?,
    val authored: Int?,
    val background: String?,
)

internal val LocalNativeCellForeground = staticCompositionLocalOf<NativeCellForegroundContext?> { null }

/** Existing generated source markers/control labels use this only in the new branch. */
@Composable
internal fun nativeMarkedCellForeground(): Int? = LocalNativeCellForeground.current?.let {
    LocalFigureCaptionForeground.current ?: it.plain
}

internal fun nativeCellForegroundContext(policy: CellForeground?, enclosing: Int,
    background: String?, authored: Int?): NativeCellForegroundContext? = when (policy) {
    null -> null
    CellForeground.Inherit -> NativeCellForegroundContext(enclosing,
        authored ?: authoredSpanForegroundArgb(null, background)?.toInt(), authored, background)
}

/** Capture before the new cell's background provider is entered. In particular an
 * automatic outer cell's computed contrast is nearer than an ambient TextStyle. */
@Composable
internal fun nativeCellForegroundContext(cell: Cell, background: String?): NativeCellForegroundContext? {
    val inherited = LocalNativeCellForeground.current
    val authored = LocalFigureCaptionForeground.current ?: inherited?.authored
    val enclosing = authored ?: inherited?.plain
        ?: authoredSpanForegroundArgb(null, LocalAuthoredBackground.current)?.toInt()
        ?: LocalTextStyle.current.color.takeIf { it != Color.Unspecified }?.toArgb()
        ?: LocalContentColor.current.toArgb()
    return nativeCellForegroundContext(cell.style?.foreground, enclosing, background, authored)
}

/** A real explicit foreground (including the Figure caption owner) has precedence. */
internal fun NativeCellForegroundContext.withAuthored(foreground: Int?): NativeCellForegroundContext =
    if (foreground == null) this else copy(plain = foreground, link = foreground, authored = foreground)

/** A Container's own background remains its existing contrast boundary. This does
 * not manufacture an authored foreground, so a later background can resolve anew. */
internal fun NativeCellForegroundContext.atBackground(background: String?, foreground: Int?): NativeCellForegroundContext {
    val explicit = foreground ?: authored
    val contrast = authoredSpanForegroundArgb(null, background)?.toInt()
    return copy(plain = explicit ?: contrast ?: plain, link = explicit ?: contrast ?: link,
        authored = explicit, background = background)
}

/** Group foreground/background/action paint is real descendant provenance. A font
 * probe or an unpainted Box does not turn cell inheritance into authored color. */
internal fun NativeCellForegroundContext.inGroup(ownsPaint: Boolean, resolved: Int): NativeCellForegroundContext =
    if (ownsPaint) copy(plain = resolved, link = resolved, authored = resolved) else this

internal fun nativeCellPlainForeground(context: NativeCellForegroundContext?, explicit: Int?,
    authored: Int?, ownBackground: String?, effectiveBackground: String?, code: Boolean): Int? =
    explicit ?: authored ?: when {
        // Inline code's incidental surface is not an authored foreground boundary.
        ownBackground != null || code && context == null -> authoredSpanForegroundArgb(null, effectiveBackground)?.toInt()
        context != null -> context.plain
        else -> authoredSpanForegroundArgb(null, effectiveBackground)?.toInt()
    }

internal fun nativeCellLinkForeground(context: NativeCellForegroundContext?, explicit: Int?,
    authored: Int?, ownBackground: String?, effectiveBackground: String?, code: Boolean): Int? =
    explicit ?: authored ?: when {
        ownBackground != null || code -> authoredSpanForegroundArgb(null, effectiveBackground)?.toInt()
        context != null -> context.link
        else -> authoredSpanForegroundArgb(null, effectiveBackground)?.toInt()
    }

internal fun nativeHasCellForeground(table: Table): Boolean {
    var found = false
    PresentationSpanVisitor { _, _ -> }.apply {
        onTable = { value, _, _ -> if (value.rows.any { row -> row.any { it.style?.foreground != null } }) found = true }
    }.table(table)
    return found
}
