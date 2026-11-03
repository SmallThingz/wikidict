package app.smallthingz.dict

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction

/** Direct DPR2-DPR9 decoder. Dictionary presentation never passes through JSON or source text. */
object BaselineBlobDecoder {
    private val kinds = listOf("paragraph", "blank", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "heading", "preformatted", "rule", "table")
    private val roles = listOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference")
    private val inline = listOf("text", "link", "external_link", "line_break")
    fun decode(bytes: ByteArray, title: String, kind: String, language: String?, code: String): Entry {
        val r = Reader(bytes)
        require(r.byte() == 68 && r.byte() == 80 && r.byte() == 82) { "Unsupported presentation format" }
        val version = r.byte()
        require(version in 50..57) { "Unsupported presentation format" }
        r.explanations = version >= 51
        r.colors = version >= 52
        r.anchors = version >= 53
        r.spanBackgrounds = version >= 54
        r.nestedTables = version >= 55
        r.cellBlocks = version >= 56
        if (r.nestedTables) r.remainingItems = 1 shl 20
        val display = r.spans()
        val sections = List(r.count(if (r.anchors) 17 else 9)) {
            val level = r.byte(); val name = r.string()
            val anchor = if (r.anchors) r.string() else ""
            val fallback = if (r.anchors) r.string() else ""
            Section(level, name, List(r.count(if (r.anchors) 25 else 17)) { r.block() }, anchor, fallback)
        }
        val preamble = r.spans()
        // Validate semantic organization even though this renderer preserves section order.
        repeat(r.count(29)) {
            r.string(); r.string()
            val section = r.index(sections.size); r.optionalIndex(sections.size)
            val blocks = sections[section].blocks.size
            repeat(r.count(18)) { sense ->
                r.index(blocks); r.optionalIndex(sense)
                repeat(3) { r.indices(blocks) }
                if (r.presence()) repeat(3) { r.string() }
            }
            r.indices(blocks); r.indices(blocks); r.indices(sections.size)
        }
        r.indices(sections.size)
        val references = List(r.count(if (version >= 57) 13 else 20)) {
            val referenceKind = if (version < 57) ReferenceKind.Note else when (r.byte()) {
                0 -> ReferenceKind.Note
                1 -> ReferenceKind.Fragment
                else -> error("Unknown reference item kind")
            }
            val number = r.u32()
            require(number in 1L..0xffff_fffeL)
            val groupNumber = if (referenceKind == ReferenceKind.Note) {
                val ordinal = r.u32()
                require(ordinal in 1L..0xffff_fffeL)
                r.string() // Authored note name; navigation uses its stable item identity.
                ordinal
            } else null
            val group = r.string()
            Reference(number, groupNumber, group, r.spans(), referenceKind)
        }
        val media = List(r.count(9)) { Media(r.string(), r.enum(listOf("image", "audio")), r.string()) }
        require(!r.buffer.hasRemaining()) { "Trailing presentation data" }
        return Entry(title, display, kind, language, code, sections, references, preamble, media)
    }
    private class Reader(bytes: ByteArray) {
        val buffer: ByteBuffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var remainingItems = 1_000_000
        var explanations = false
        var colors = false
        var anchors = false
        var spanBackgrounds = false
        var nestedTables = false
        var cellBlocks = false
        fun byte(): Int { require(buffer.remaining() >= 1); return buffer.get().toInt() and 255 }
        fun u16(): Int { require(buffer.remaining() >= 2); return buffer.short.toInt() and 65535 }
        fun u32(): Long { require(buffer.remaining() >= 4); return buffer.int.toLong() and 0xffffffffL }
        fun count(minBytes: Int): Int {
            val n = u32(); require(n <= remainingItems && n <= buffer.remaining() / minBytes)
            remainingItems -= n.toInt(); return n.toInt()
        }
        fun string(): String {
            val n = u32(); require(n <= 32*1024*1024 && n <= buffer.remaining())
            val slice = buffer.slice(); slice.limit(n.toInt()); buffer.position(buffer.position() + n.toInt())
            return Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(slice).toString()
        }
        fun enum(values: List<String>): String = values.getOrNull(byte()) ?: error("Unknown presentation tag")
        fun presence(): Boolean = when(byte()) { 0 -> false; 1 -> true; else -> error("Invalid presence flag") }
        fun index(limit: Int): Int { val n = u32(); require(n < limit); return n.toInt() }
        fun optionalIndex(limit: Int) { val n = u32(); require(n == 0xffffffffL || n < limit) }
        fun indices(limit: Int) { repeat(count(4)) { index(limit) } }
        fun spans(): List<Span> = List(count(if (spanBackgrounds) 33 else if (colors) 32 else if (explanations) 31 else 27)) {
            val kind = enum(inline); val role = enum(roles); val f = byte()
            val text = string(); val target = string(); val trail = string()
            val language = string(); val classes = string(); val direction = string()
            val explanation = if (explanations) string() else ""
            val foreground = if (colors && presence()) string().also {
                require(canonicalColorArgb(it) != null) { "Invalid span foreground" }
            } else null
            val background = if (spanBackgrounds && presence()) string().also {
                require(canonicalColorArgb(it) != null) { "Invalid span background" }
            } else null
            Span(kind, text, target, trail, language, classes, direction,
                bold=f and 1 != 0, italic=f and 2 != 0, code=f and 4 != 0, small=f and 8 != 0,
                superscript=f and 16 != 0, subscript=f and 32 != 0, strike=f and 64 != 0, underline=f and 128 != 0, role=role, explanation=explanation, foreground=foreground, background=background)
        }
        private fun table(depth: Int): Table? {
            if (!presence()) return null
            require(depth <= MaxTableDepth) { "Table nesting is too deep" }
            val geometry = if (!nestedTables) null else {
                val flags = byte()
                require(flags and 0xf0 == 0) { "Unknown table geometry flags" }
                val border = if (flags and 1 != 0) u16() else null
                val spacing = if (flags and 2 != 0) u16() else null
                val padding = if (flags and 4 != 0) u16() else null
                val width = if (flags and 8 == 0) null else {
                    val unit = when (byte()) { 0 -> TableWidthUnit.Px; 1 -> TableWidthUnit.Percent; else -> error("Unknown table width unit") }
                    val value = u32()
                    require(unit != TableWidthUnit.Percent || value <= 100) { "Invalid table percent width" }
                    TableWidth(unit, value)
                }
                if (flags == 0) null else TableGeometry(border, spacing, padding, width)
            }
            val caption = spans()
            val rows = List(count(4)) { List(count(if (cellBlocks) 12 else if (nestedTables) 11 else if (colors) 10 else 9)) {
                val header = presence(); val cols = u16(); val rowspan = u16()
                require(cols in 1..100 && rowspan in 1..100) { "Invalid table span" }
                val background = if (colors && presence()) string().also {
                    require(canonicalColorArgb(it) != null) { "Invalid cell background" }
                } else null
                val content = spans()
                val child = if (nestedTables) table(depth + 1) else null
                val blocks = if (cellBlocks && presence()) List(count(25)) { block(depth) } else null
                Cell(content, header, cols, rowspan, background, child, blocks)
            } }
            return Table(caption, rows, geometry).also { tableGrid(it) }
        }
        fun block(tableDepth: Int = 0): Block {
            val kind = enum(kinds); val depth = byte(); val level = byte()
            val spans = spans()
            val feature = if (presence()) Feature(string(), string(), string(), string(), string()) else null
            val path = string(); val number = string()
            val table = table(tableDepth + 1)
            val anchor = if (anchors) string() else ""
            val fallback = if (anchors) string() else ""
            require(kind == "heading" || (anchor.isEmpty() && fallback.isEmpty())) { "Only headings may have a destination anchor" }
            return Block(kind, depth, spans, path, number, table, feature, level, anchor, fallback)
        }
    }
}
