package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class RubyTextTest {
    private val baseOwner = RubyOwner(font = InlineFontSnapshot(fontScale = 1f,
        fontScaleBasis = FontScaleBasis.NormalBody, language = "ja", bold = false, italic = false), direction = "ltr")
    private val annotationOwner = RubyOwner(font = InlineFontSnapshot(fontScale = .5f,
        fontScaleBasis = FontScaleBasis.NormalBody, language = "zh", bold = false, italic = false), direction = "rtl")
    private fun text(value: String, trail: String = "") = Span("text", value, trail = trail)
    private fun base(vararg spans: Span, gap: List<Span> = emptyList()) =
        RubyBase(owner = baseOwner, gapBefore = gap, spans = spans.toList())
    private fun annotation(start: Long, count: Long, level: Long, spans: List<Span>,
        gap: List<Span> = emptyList(), before: List<Span> = emptyList(), after: List<Span> = emptyList(),
        explicit: Boolean = false) = RubyAnnotation(baseStart = start, baseCount = count, level = level,
            owner = annotationOwner, gapBefore = gap, spans = spans, fallbackBefore = before,
            fallbackAfter = after, explicitFallback = explicit)
    private fun owner(vararg segments: RubySegment) = Span("text", "", ruby = Ruby(segments.toList()))
    private fun single(base: List<Span>, reading: List<Span>) = owner(RubySegment(emptyList(),
        listOf(RubyBase(owner = baseOwner, gapBefore = emptyList(), spans = base)), listOf(annotation(0, 1, 0, reading))))

    @Test fun graphicalTraversalKeepsOriginalRolesActionsAndUtf16RangesWithoutFallbackGlyphs() {
        val prefix = text("pre(\u2066")
        val baseLink = Span("link", "A\ud83d\ude80", "base-target", trail = "\u0301", direction = "rtl", language = "he", bold = true)
        val gap = text("\t")
        val secondBase = text("B")
        val firstReading = Span("link", "read", "first-reading", trail = "!", language = "ja", italic = true)
        val secondReading = Span("link", "read", "second-reading", trail = "!", targetFragment = "", language = "zh", bold = true)
        val annotationGap = text(" ")
        val rp = Span("link", "[", "rp-target")
        val first = annotation(0, 1, 0, listOf(firstReading), before = listOf(rp), after = listOf(text("]")), explicit = true)
        val second = annotation(1, 1, 0, listOf(secondReading), gap = listOf(annotationGap))
        val segment = RubySegment(emptyList(), listOf(base(baseLink), base(secondBase, gap = listOf(gap))), listOf(first, second))
        val ruby = owner(segment)
        val suffix = text("\u2069)tail")
        val source = listOf(prefix, ruby, suffix)
        val projected = rubyGraphicalProjection(source, "entry/body/3")
        val expected = "pre(\u2066A\ud83d\ude80\u0301\tBread! read!\u2069)tail"
        assertEquals(expected, projected.text)
        assertEquals(expected, rubyGraphicalText(source))
        val leaves = projected.ranges.filter { it.span != null && it.role != RubyTextRole.Owner }
        val originals = listOf(prefix, baseLink, gap, secondBase, firstReading, annotationGap, secondReading, suffix)
        assertEquals(originals.size, leaves.size)
        originals.zip(leaves).forEach { (span, range) ->
            assertSame(span, range.span)
            assertEquals(span.text + span.trail, expected.substring(range.start, range.end))
        }
        assertEquals(originals, rubyGraphicalSpans(source))
        val baseRange = leaves.single { it.span === baseLink }
        assertEquals(prefix.text.length, baseRange.start)
        assertEquals(prefix.text.length + 4, baseRange.end) // A, two UTF-16 surrogate units, combining trail.
        assertEquals(RubyTextRole.BaseText, baseRange.role)
        assertEquals("entry/body/3/spans/1/ruby/segments/0/bases/0/spans/0", baseRange.path)
        val actions = leaves.filter { it.span!!.kind == "link" }
        assertEquals(listOf("base-target", "first-reading", "second-reading"), actions.map { it.span!!.target })
        assertEquals(listOf(null, null, ""), actions.map { it.span!!.targetFragment })
        assertEquals(listOf("read!", "read!"), actions.drop(1).map { expected.substring(it.start, it.end) })
        assertNotEquals(actions[1].path, actions[2].path)
        assertTrue(actions[1].end <= actions[2].start)
        assertFalse(projected.ranges.any { it.span === rp })
        val ownerRange = projected.ranges.single { it.role == RubyTextRole.Owner }
        assertSame(ruby, ownerRange.span)
        assertEquals(prefix.text.length, ownerRange.start)
        assertEquals(expected.length - suffix.text.length, ownerRange.end)
        assertSame(segment, projected.ranges.single { it.role == RubyTextRole.Segment }.segment)
        assertSame(first, projected.ranges.first { it.role == RubyTextRole.Annotation }.annotation)
        assertSame(segment.bases[1], projected.ranges.filter { it.role == RubyTextRole.Base }[1].base)
        assertSame(baseOwner, projected.ranges.first { it.role == RubyTextRole.Base }.base!!.owner)
        assertSame(annotationOwner, projected.ranges.first { it.role == RubyTextRole.Annotation }.annotation!!.owner)
        assertEquals("Declaring contexts add no graphical occurrences", 14, projected.ranges.size)
        assertEquals("B", expected.substring(projected.ranges.filter { it.role == RubyTextRole.Base }[1].start,
            projected.ranges.filter { it.role == RubyTextRole.Base }[1].end))
    }

    @Test fun autoHideUsesExactRecursiveBaseTextTrailsAndOnlyInternalCoveredGaps() {
        val nestedBase = text("Y")
        val nestedReading = Span("link", "why", "nested-reading")
        val nested = single(listOf(nestedBase), listOf(nestedReading))
        val readingBase = Span("link", "E\u0301", "hidden-reading")
        val nestedReadingOfReading = Span("link", "other", "hidden-nested-reading")
        fun readingCandidate(first: Span, gap: List<Span> = listOf(text("\t"))) =
            owner(RubySegment(emptyList(), listOf(base(first), base(text("Y"), gap = gap)),
                listOf(annotation(0, 2, 0, listOf(nestedReadingOfReading)))))
        val reading = readingCandidate(readingBase)
        val visible = annotation(0, 1, 0, listOf(text("P")))
        val hidden = annotation(1, 2, 0, listOf(reading), gap = listOf(text(" \n")))
        val segment = RubySegment(listOf(text("\n")), listOf(base(text("p")),
            base(text("E", trail = "\u0301"), gap = listOf(text(" "))),
            base(nested, gap = listOf(text("\t")))), listOf(visible, hidden))
        val prefix = RubySegment(emptyList(), listOf(base(text("prefix"))), emptyList())
        val ruby = owner(prefix, segment)
        assertTrue(rubyAnnotationHidden(segment, hidden))
        assertFalse(rubyAnnotationHidden(segment, hidden.copy(spans = listOf(readingCandidate(text(" E\u0301"))))))
        assertFalse(rubyAnnotationHidden(segment, hidden.copy(spans = listOf(readingCandidate(text("E\u0301"), emptyList())))))
        assertFalse(rubyAnnotationHidden(segment, hidden.copy(spans = listOf(readingCandidate(text("e\u0301"))))))
        assertFalse(rubyAnnotationHidden(segment, hidden.copy(spans = listOf(readingCandidate(text("\u00c9"))))))
        assertEquals("prefix\np E\u0301\tY", rubyBaseText(listOf(ruby)))
        assertEquals("prefix\np E\u0301\tYwhyP", rubyGraphicalText(listOf(ruby)))
        val projection = rubyGraphicalProjection(listOf(ruby))
        assertTrue(projection.ranges.none { it.annotation === hidden || it.span === readingBase || it.span === nestedReadingOfReading })
        assertTrue(rubyGraphicalSpans(listOf(ruby)).any { it === nestedReading })
        assertSame(reading, ruby.ruby!!.segments[1].annotations[1].spans.single())
        val fallback = rubyFallbackSpans(listOf(ruby))
        assertTrue(fallback.any { it === readingBase })
        assertTrue(fallback.any { it === nestedReadingOfReading })
        assertTrue(rubyFallbackText(listOf(ruby)).contains(" \n\uff08E\u0301\tY\uff08other\uff09\uff09"))
    }

    @Test fun terminalFallbackRetainsHiddenReadingsExplicitRpAndEmptyReadingActionsSeparately() {
        val baseSpan = Span("link", "\u5b57", "base")
        val reading = Span("link", "zi", "reading", targetFragment = "tone")
        val before = Span("link", "[", "rp-before", trail = " ", italic = true)
        val after = Span("link", "]", "rp-after", targetFragment = "", bold = true)
        val equal = Span("link", "\u5b57", "equal-reading")
        val emptyBefore = text("{")
        val emptyAfter = text("}")
        val emptyRun = text("")
        val annotations = listOf(
            annotation(0, 1, 0, listOf(reading), before = listOf(before), after = listOf(after), explicit = true),
            annotation(0, 1, 1, listOf(equal)),
            annotation(0, 1, 2, listOf(emptyRun), before = listOf(emptyBefore), after = listOf(emptyAfter), explicit = true),
            annotation(0, 1, 3, emptyList()))
        val ruby = owner(RubySegment(emptyList(), listOf(base(baseSpan)), annotations))
        val source = listOf(text("("), ruby, text(")"))
        assertEquals("(\u5b57zi)", rubyGraphicalText(source))
        assertEquals("(\u5b57[ zi]\uff08\u5b57\uff09{})", rubyFallbackText(source))
        val fallback = rubyFallbackSpans(source)
        val expectedOriginals = listOf(source[0], baseSpan, before, reading, after, equal, emptyBefore, emptyRun, emptyAfter, source[2])
        expectedOriginals.forEach { original -> assertEquals(1, fallback.count { it === original }) }
        assertEquals(listOf("base", "rp-before", "reading", "rp-after", "equal-reading"),
            fallback.filter { it.kind == "link" }.map { it.target })
        assertEquals("tone", fallback.single { it === reading }.targetFragment)
        assertEquals("", fallback.single { it === after }.targetFragment)
        val generated = fallback.filter { item -> expectedOriginals.none { it === item } }
        assertEquals(listOf("\uff08", "\uff09"), generated.map { it.text })
        assertTrue(generated.all { it.kind == "text" && it.target.isEmpty() && it.trail.isEmpty() && it.ruby == null })
        val graphical = rubyGraphicalProjection(source)
        assertTrue(graphical.ranges.none { it.span === equal || it.span === before || it.span === after })
        assertEquals(2, graphical.ranges.count { it.role == RubyTextRole.Annotation && it.start == it.end })
    }

    @Test fun emptyOwnersAndOrdinaryNullPathsKeepExactTextWithoutSyntheticCharacters() {
        val empty = owner(RubySegment(emptyList(), listOf(base()), emptyList()))
        val nested = owner(RubySegment(emptyList(), listOf(base(empty)), emptyList()))
        val projection = rubyGraphicalProjection(listOf(nested), "empty")
        assertEquals("", projection.text)
        assertEquals(2, projection.ranges.count { it.role == RubyTextRole.Owner })
        assertTrue(projection.ranges.all { it.start == 0 && it.end == 0 })
        assertTrue(projection.ranges.map { it.path }.distinct().size == projection.ranges.size)
        assertEquals("", rubyBaseText(listOf(nested)))
        assertEquals("", rubyFallbackText(listOf(nested)))
        assertTrue(rubyFallbackSpans(listOf(nested)).isEmpty())
        val ordinary = listOf(text("literal (rp) \uff08read\uff09\u00a0"),
            Span("link", "\ud83d\ude80e\u0301", "ordinary", trail = "!", direction = "rtl"), text("\u2067authored\u2069"))
        val exact = ordinary.joinToString("") { it.text + it.trail }
        assertSame(ordinary, rubyGraphicalSpans(ordinary))
        assertEquals(exact, rubyBaseText(ordinary))
        assertEquals(exact, rubyGraphicalText(ordinary))
        assertEquals(exact, rubyFallbackText(ordinary))
        ordinary.zip(rubyFallbackSpans(ordinary)).forEach { (first, second) -> assertSame(first, second) }
        val image = Span("text", "", image = InlineImage("Controlled.png", widthPx = 20))
        val following = text("!")
        val br = Span("line_break", "", trail = " ")
        assertEquals("\ufffc!\n ", rubyGraphicalText(listOf(image, following, br)))
        assertEquals("! ", rubyFallbackText(listOf(image, following, br)))
        assertEquals("! ", rubyBaseText(listOf(image, following, br)))
    }

    @Test fun terminalBaseDecorationCopiesAllLinkStatesAndResetsAtReadingsAndRp() {
        val outline = FigureFocusOutline(StyleLength(StyleLengthUnit.Px, 1f), FigureColor.Rgb("#ff0000"),
            StyleLength(StyleLengthUnit.Px, 2f), StyleLength(StyleLengthUnit.Px, 0f))
        val policy = LinkPaint(
            normal = LinkState("#112233", false), hover = LinkState("#223344", true),
            active = LinkState("#334455", false), hoverActive = LinkState("#445566", true),
            visited = LinkState("#556677", false), visitedHover = LinkState("#667788", true),
            visitedActive = LinkState("#778899", false), visitedHoverActive = LinkState("#8899aa", true),
            underlineOnFocus = false, focusOutline = outline)
        fun states(value: LinkPaint) = listOf(value.normal, value.hover, value.active, value.hoverActive,
            value.visited, value.visitedHover, value.visitedActive, value.visitedHoverActive)
        val originalStates = states(policy)
        val linked = Span("link", "A", "base-target", trail = "!", targetFragment = "", language = "ja",
            classes = "Latn", foreground = policy.normal.foreground, linkPaint = policy)
        val nestedBase = text("B")
        val nestedReading = text("inner")
        val nested = single(listOf(nestedBase), listOf(nestedReading)).copy(strike = true)
        val baseGap = text(" \t")
        val reading = Span("link", "reading", "reading-target", underline = true)
        val before = Span("link", "[", "rp-target", strike = true)
        val after = text("]")
        val annotationGap = text("\r\n")
        val hidden = text("B")
        val segmentGap = text("\r\n")
        val finalBase = text("C")
        val first = RubySegment(emptyList(), listOf(base(linked), base(nested, gap = listOf(baseGap))), listOf(
            annotation(0, 1, 0, listOf(reading), before = listOf(before), after = listOf(after), explicit = true),
            annotation(1, 1, 0, listOf(hidden), gap = listOf(annotationGap))))
        val second = RubySegment(listOf(segmentGap), listOf(base(finalBase)), emptyList())
        val decorated = owner(first, second).copy(underline = true)
        val outside = text("D")
        val source = listOf(decorated, outside)
        val graphical = rubyGraphicalProjection(source)
        val fallback = rubyFallbackSpans(source)
        assertEquals("A! \tB\uff08inner\uff09[reading]\r\n\uff08B\uff09\r\nCD", rubyFallbackText(source))
        val projectedLink = fallback.single { it.target == "base-target" }
        assertTrue(projectedLink.underline)
        assertFalse(projectedLink.strike)
        val painted = checkNotNull(projectedLink.linkPaint)
        assertNotSame(policy, painted)
        assertTrue(states(painted).all { it.underline })
        assertEquals(originalStates.map { it.foreground }, states(painted).map { it.foreground })
        assertEquals(policy.underlineOnFocus, painted.underlineOnFocus)
        assertSame(outline, painted.focusOutline)
        assertEquals(linked.copy(underline = true, linkPaint = painted), projectedLink)
        assertSame(policy, linked.linkPaint)
        assertFalse(linked.underline)
        assertEquals(originalStates, states(policy))
        val projectedBase = fallback.single { it.text == "B" && it.strike }
        assertEquals(nestedBase.copy(underline = true, strike = true), projectedBase)
        assertSame(nestedReading, fallback.single { it.text == "inner" })
        assertSame(reading, fallback.single { it.target == "reading-target" })
        assertSame(before, fallback.single { it.target == "rp-target" })
        assertSame(after, fallback.single { it.text == "]" })
        assertSame(hidden, fallback.single { it.text == "B" && !it.strike })
        assertTrue(fallback.single { it.text == " \t" }.underline)
        val gaps = fallback.filter { it.text == "\r\n" }
        assertEquals(2, gaps.size)
        assertSame(annotationGap, gaps[0])
        assertEquals(segmentGap.copy(underline = true), gaps[1])
        assertFalse(baseGap.underline)
        assertFalse(segmentGap.underline)
        assertEquals(finalBase.copy(underline = true), fallback.single { it.text == "C" })
        assertSame(outside, fallback.last())
        assertTrue(fallback.filter { it.text == "\uff08" || it.text == "\uff09" }.all { !it.underline && !it.strike })
        assertEquals(graphical, rubyGraphicalProjection(source))
        assertSame(linked, graphical.ranges.single { it.span === linked }.span)
    }
}
