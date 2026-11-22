package app.smallthingz.dict

import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb

/** These are actual semantic owner boundaries, never inferred from a painted leaf. */
internal enum class NativeSemanticBorderInkOrigin { ReaderRoot, FigureCaption, Container, Cell }

internal class NativeSemanticBorderInk(val argb: Int, val declaringOwner: Any,
    val origin: NativeSemanticBorderInkOrigin, val authoredArgb: Int? = null,
    val authoredOwner: Any? = null) {
    init { require((authoredArgb == null) == (authoredOwner == null)) }
    override fun equals(other: Any?): Boolean = other is NativeSemanticBorderInk &&
        argb == other.argb && declaringOwner === other.declaringOwner && origin == other.origin &&
        authoredArgb == other.authoredArgb && authoredOwner === other.authoredOwner
    override fun hashCode(): Int = 31 * (31 * (31 * (31 * argb + System.identityHashCode(declaringOwner)) +
        origin.hashCode()) + (authoredArgb ?: 0)) + System.identityHashCode(authoredOwner)
}

/** Null is unknown provenance, not a request to restart native defaults at a nested owner. */
internal val LocalNativeSemanticBorderInk = staticCompositionLocalOf<NativeSemanticBorderInk?> { null }

/** Called only by the real Entry root or the standalone compiled-table root.
 * Source admission proves that a nearer unrepresented color declaration was not lost. */
@Composable
internal fun nativeReaderRootBorderInk(owner: Any): NativeSemanticBorderInk? {
    val color = LocalTextStyle.current.color.takeIf { it != Color.Unspecified } ?: LocalContentColor.current
    if (color == Color.Unspecified) return null
    return NativeSemanticBorderInk(color.toArgb(), owner, NativeSemanticBorderInkOrigin.ReaderRoot)
}

/** Resolve the original owner's normal policy before any child Span exists.
 * Owner readability belongs here; span background, code and link paint do not. */
internal fun nativeBorderNormalOwnerInk(inherited: NativeSemanticBorderInk?, owner: Any,
    origin: NativeSemanticBorderInkOrigin, cellContext: NativeCellForegroundContext?,
    effectiveBackground: String?): NativeSemanticBorderInk? {
    if (inherited == null) return null
    val normal = nativeCellPlainForeground(cellContext, explicit = null,
        authored = inherited.authoredArgb, ownBackground = null,
        effectiveBackground = effectiveBackground, code = false) ?: inherited.argb
    return NativeSemanticBorderInk(normal, owner, origin, inherited.authoredArgb, inherited.authoredOwner)
}

internal enum class NativeTableBorderOrigin { Table, Cell }

/** Retain position as well as source identity: one Cell object can occur twice. */
internal class NativeTableBorderOwner(val table: Table, val source: Any,
    val origin: NativeTableBorderOrigin, val cellIndex: Int? = null) {
    init {
        require(if (origin == NativeTableBorderOrigin.Cell) cellIndex != null && cellIndex >= 0
            else cellIndex == null && source === table)
    }
    override fun equals(other: Any?): Boolean = other is NativeTableBorderOwner &&
        table === other.table && source === other.source && origin == other.origin && cellIndex == other.cellIndex
    override fun hashCode(): Int = 31 * (31 * (31 * System.identityHashCode(table) +
        System.identityHashCode(source)) + origin.hashCode()) + (cellIndex ?: -1)
}

internal data class NativeTableBorderOwnerInk(val owner: NativeTableBorderOwner,
    val semantic: NativeSemanticBorderInk?)

internal fun nativeTableOwnerCurrentColor(owner: NativeTableBorderOwner,
    receipt: NativeTableBorderOwnerInk?): Int {
    if (receipt?.owner != owner || receipt.semantic == null)
        throw UnsupportedFloatLayout("Table border owner foreground is unavailable. Table content is retained.")
    return receipt.semantic.argb
}

/** Source-bearing grids and resolved styles must not reuse equal replacement owners.
 * Old trees retain their original structural cache keys. */
internal fun nativeTableBorderSourceKey(table: Table): Any =
    if (nativeHasResolvedTableBorders(table)) NativeTableBorderOwner(table, table, NativeTableBorderOrigin.Table)
    else table

@Composable
internal fun rememberNativeTableBorderSourceKey(table: Table): Any =
    remember(NativeTableBorderOwner(table, table, NativeTableBorderOrigin.Table)) {
        nativeTableBorderSourceKey(table)
    }
