package app.smallthingz.dict

/** One original occurrence. Equal text or equal stored values are not source identity. */
internal class NativeTextAdvisoryIdentity(val span: Span, val path: String) {
    override fun equals(other: Any?): Boolean = other is NativeTextAdvisoryIdentity &&
        span === other.span && path == other.path
    override fun hashCode(): Int = 31 * System.identityHashCode(span) + path.hashCode()
}

/** Source paths, never coincident numeric intervals, select inherited metadata. */
internal class NativeTextAdvisoryIndex(projection: RubyTextProjection) {
    private val byPath = projection.ranges.associateBy { it.path }
    val declarations = projection.ranges.filter { it.span?.tooltip != null }
    private val ancestors = projection.ranges.associate { range ->
        val result = mutableListOf<RubyTextRange>()
        var path = range.path
        while (true) {
            val end = path.lastIndexOf('/')
            if (end < 0) break
            path = path.substring(0, end)
            byPath[path]?.let(result::add)
        }
        range.path to result.asReversed()
    }
    private val overrides = mutableMapOf<String, MutableList<RubyTextRange>>().apply {
        declarations.forEach { declaration ->
            ancestors[declaration.path].orEmpty().forEach { parent ->
                getOrPut(parent.path) { mutableListOf() }.add(declaration)
            }
        }
    }
    fun ancestors(range: RubyTextRange): List<RubyTextRange> = ancestors[range.path].orEmpty()
    fun descendants(range: RubyTextRange): List<RubyTextRange> = overrides[range.path].orEmpty()
    /** Empty suppresses locally; only null inherits. */
    fun title(range: RubyTextRange): String? = range.span?.tooltip ?: ancestors(range).asReversed()
        .firstNotNullOfOrNull { it.span?.tooltip }
    fun imageTitle(range: RubyTextRange, fallback: CharSequence?): CharSequence? =
        range.span?.image?.tooltip ?: title(range) ?: fallback
}
