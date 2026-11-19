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

    @Test fun paddingGroupsKeepChildOnlyUtf16TextAndDistinctStoredActionOwners() {
        val edge = StyleLength(StyleLengthUnit.Em, .25f)
        fun group(children: List<Span>, scale: Float, action: String = "") = Span(
            if (action.isEmpty()) "text" else "link", "", action, fontScale = scale,
            fontScaleBasis = FontScaleBasis.NormalBody, language = "vi", direction = "ltr",
            inlinePaddingGroup = InlinePaddingGroup(edge, edge, children))
        // Synthetic resolved contexts: two cumulative 1.35 factors, then one factor.
        val first = Span("link", "nhân", "nhan", fontScale = 1.8225f, fontScaleBasis = FontScaleBasis.NormalBody)
        val second = Span("link", "chất", "chat", fontScale = 1.8225f, fontScaleBasis = FontScaleBasis.NormalBody)
        val third = Span("text", "thiết", fontScale = 1.35f, fontScaleBasis = FontScaleBasis.NormalBody)
        val owners = listOf(group(listOf(first), 1.8225f), group(listOf(second), 1.8225f),
            group(listOf(third), 1.35f, "fanqie"))
        val source = owners.mapIndexed { index, value -> single(listOf(text("${index + 1}")), listOf(value)) }
        val projection = rubyGraphicalProjection(source, "entry/reading")
        assertEquals("1nhân2chất3thiết", projection.text)
        assertEquals("123", rubyBaseText(source))
        assertEquals("1（nhân）2（chất）3（thiết）", rubyFallbackText(source))
        val groups = projection.ranges.filter { it.role == RubyTextRole.PaddingGroup }
        assertEquals(3, groups.size)
        owners.zip(groups).forEach { (span, range) ->
            assertSame(span, range.span)
            val child = checkNotNull(span.inlinePaddingGroup).spans.single()
            assertEquals(child.text, projection.text.substring(range.start, range.end))
            val leaf = projection.ranges.single { it.span === child }
            assertEquals(range.start, leaf.start); assertEquals(range.end, leaf.end)
            assertTrue(leaf.path.startsWith(range.path + "/inlinePaddingGroup/spans/"))
        }
        val storedActions = projection.ranges.filter { it.span?.kind == "link" }
        assertEquals(listOf(first, second, owners[2]), storedActions.map { it.span })
        assertEquals(listOf("nhan", "chat", "fanqie"), storedActions.map { it.span!!.target })
        assertSame(third, projection.ranges.single { it.span === third }.span)
        assertEquals("text", third.kind)
        val flat = rubyGraphicalSpans(source)
        assertSame(first, flat.single { it.text == "nhân" })
        assertSame(second, flat.single { it.text == "chất" })
        assertEquals(third.copy(kind = "link", target = "fanqie"), flat.single { it.text == "thiết" })
        assertEquals(listOf(1.8225f, 1.8225f, 1.35f), groups.map { it.span!!.fontScale })
        assertTrue(rubyFallbackSpans(source).filter { it.text == "（" || it.text == "）" }.all { it.kind == "text" && it.target.isEmpty() })

        val whole = group(listOf(text("A\ud83d\ude80\u0301!")), 1f)
        val split = group(listOf(text("A\ud83d\ude80", trail = "\u0301"), text("!")), 1f)
        assertEquals(rubyGraphicalText(listOf(whole)), rubyGraphicalText(listOf(split)))
        val splitProjection = rubyGraphicalProjection(listOf(split))
        assertEquals(1, splitProjection.ranges.count { it.role == RubyTextRole.PaddingGroup })
        assertEquals(5, splitProjection.text.length)
        val empty = group(listOf(text("")), 0f)
        val emptyProjection = rubyGraphicalProjection(listOf(empty))
        assertEquals("", emptyProjection.text)
        assertTrue(emptyProjection.ranges.all { it.start == 0 && it.end == 0 })
        assertSame(empty, emptyProjection.ranges.first().span)
        val metric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(12f, FontScaleBasis.CssPx))))
        val metricTrail = metric.copy(trail = "!")
        val plainTrail = text("", trail = ":")
        val metricGroup = group(listOf(metric, metricTrail, plainTrail, text("body")), 1f, "metric-action")
        for (flatMetric in listOf(rubyGraphicalSpans(listOf(metricGroup)), rubyFallbackSpans(listOf(metricGroup)))) {
            assertSame(metric, flatMetric.first())
            assertEquals("text", flatMetric.first().kind)
            assertEquals("metric-action", flatMetric.single { it.text == "body" }.target)
            val projectedTrail = flatMetric.single { it.text == "!" }
            assertEquals("", projectedTrail.trail); assertEquals("metric-action", projectedTrail.target)
            assertSame(metricTrail.inlineStyle, projectedTrail.inlineStyle)
            assertEquals("", flatMetric.single { it.text == ":" }.trail)
            assertEquals("metric-action", flatMetric.single { it.text == ":" }.target)
            assertEquals("!:body", flatMetric.joinToString("") { it.text + it.trail })
        }
        assertEquals("", metricTrail.text); assertEquals("!", metricTrail.trail)
        assertEquals("", plainTrail.text); assertEquals(":", plainTrail.trail)
        assertSame(metricTrail, rubyGraphicalProjection(listOf(metricGroup)).ranges.single { it.span === metricTrail }.span)
        val hidden = annotation(0, 1, 0, listOf(group(listOf(text("same")), 1f)))
        val segment = RubySegment(emptyList(), listOf(base(text("same"))), listOf(hidden))
        assertTrue(rubyAnnotationHidden(segment, hidden))
        assertEquals("same", rubyGraphicalText(listOf(owner(segment))))
        assertEquals("same（same）", rubyFallbackText(listOf(owner(segment))))
    }

    @Test fun paddingFallbackProjectsInheritedActionWithoutActingOnNestedSyntheticParentheses() {
        val outline = FigureFocusOutline(StyleLength(StyleLengthUnit.Px, 1f), FigureColor.Rgb("#ff0000"),
            StyleLength(StyleLengthUnit.Px, 2f), StyleLength(StyleLengthUnit.Px, 0f))
        val policy = LinkPaint(normal = LinkState("#112233", false), hover = LinkState("#223344", true),
            active = LinkState("#334455", false), hoverActive = LinkState("#445566", true),
            visited = LinkState("#556677", false), visitedHover = LinkState("#667788", true),
            visitedActive = LinkState("#778899", false), visitedHoverActive = LinkState("#8899aa", true),
            underlineOnFocus = false, focusOutline = outline)
        fun states(value: LinkPaint) = listOf(value.normal, value.hover, value.active, value.hoverActive,
            value.visited, value.visitedHover, value.visitedActive, value.visitedHoverActive)
        val originalStates = states(policy)
        val baseLeaf = Span("text", "Z", underline = true, italic = true, fontScale = .75f,
            fontScaleBasis = FontScaleBasis.NormalBody)
        val readingLeaf = Span("text", "zed", tooltip = "child tooltip", explanation = "child explanation")
        val before = text("["); val explicitReading = text("zee"); val after = text("]")
        val nested = owner(RubySegment(emptyList(), listOf(base(baseLeaf)), listOf(
            annotation(0, 1, 0, listOf(readingLeaf)), annotation(0, 1, 1, listOf(explicitReading),
                before = listOf(before), after = listOf(after), explicit = true))))
        val group = Span("link", "", "fanqie", targetFragment = "", tooltip = "owner tooltip",
            explanation = "owner explanation", foreground = policy.normal.foreground, linkPaint = policy,
            inlinePaddingGroup = InlinePaddingGroup(StyleLength(StyleLengthUnit.Px, 0f),
                StyleLength(StyleLengthUnit.Em, .25f), listOf(nested)))
        val projection = rubyGraphicalProjection(listOf(group))
        val fallback = rubyFallbackSpans(listOf(group))
        assertEquals("Z（zed）[zee]", rubyFallbackText(listOf(group)))
        assertEquals("Zzedzee", projection.text)
        val projectedBase = fallback.single { it.text == "Z" }
        assertEquals("link", projectedBase.kind); assertEquals("fanqie", projectedBase.target)
        assertEquals("", projectedBase.targetFragment)
        assertEquals(.75f, projectedBase.fontScale!!, 0f); assertTrue(projectedBase.italic)
        assertEquals("owner tooltip", projectedBase.tooltip); assertEquals("owner explanation", projectedBase.explanation)
        val copiedPolicy = checkNotNull(projectedBase.linkPaint)
        assertTrue(states(copiedPolicy).all { it.underline })
        assertEquals(originalStates.map { it.foreground }, states(copiedPolicy).map { it.foreground })
        assertSame(outline, copiedPolicy.focusOutline); assertEquals(policy.underlineOnFocus, copiedPolicy.underlineOnFocus)
        val projectedReading = fallback.single { it.text == "zed" }
        assertEquals("child tooltip", projectedReading.tooltip); assertEquals("child explanation", projectedReading.explanation)
        assertSame(policy, projectedReading.linkPaint)
        val absentForeground = group.copy(foreground = null)
        val inheritedNormal = rubyFallbackSpans(listOf(absentForeground)).single { it.text == "zed" }
        assertEquals(policy.normal.foreground, inheritedNormal.foreground)
        assertSame(policy, inheritedNormal.linkPaint)
        assertNull(absentForeground.foreground)
        val plainChild = text("plain")
        val explicitInk = Span("text", "override", foreground = "#00bb00")
        val plainOwner = group.copy(linkPaint = null, foreground = "#aa0000",
            inlinePaddingGroup = group.inlinePaddingGroup!!.copy(spans = listOf(plainChild, explicitInk)))
        for (projected in listOf(rubyGraphicalSpans(listOf(plainOwner)), rubyFallbackSpans(listOf(plainOwner)))) {
            assertEquals(listOf("#aa0000", "#00bb00"), projected.map { it.foreground })
            assertTrue(projected.all { it.target == "fanqie" && it.linkPaint == null })
        }
        assertNull(plainChild.foreground); assertEquals("#00bb00", explicitInk.foreground)
        for (value in listOf("[", "zee", "]")) {
            val explicit = fallback.single { it.text == value }
            assertEquals("link", explicit.kind); assertEquals("fanqie", explicit.target)
        }
        val generated = fallback.filter { it.text == "（" || it.text == "）" }
        assertEquals(2, generated.size)
        assertTrue(generated.all { it.kind == "text" && it.target.isEmpty() && it.linkPaint == null && it.tooltip == null })
        assertSame(policy, group.linkPaint); assertEquals(originalStates, states(policy))
        assertEquals("text", baseLeaf.kind); assertEquals("text", readingLeaf.kind)
        assertNull(baseLeaf.linkPaint); assertNull(readingLeaf.linkPaint)
        assertSame(baseLeaf, projection.ranges.single { it.span === baseLeaf }.span)
        assertSame(group, projection.ranges.single { it.role == RubyTextRole.PaddingGroup }.span)
        assertEquals(1, projection.ranges.count { it.span?.kind == "link" })
    }
    @Test fun actionGroupsRetainOriginalOwnersAcrossRichChildrenAndEqualTargets() {
        fun action(children: List<Span>) = Span("link", "", "d", targetFragment = "entry",
            tooltip = "one source A", bold = true, fontScale = 1.25f,
            fontScaleBasis = FontScaleBasis.NormalBody, inlineActionGroup = InlineActionGroup(children))
        val first = text("d")
        val suffix = Span("text", "a", italic = true, superscript = true, fontScale = .8f,
            fontScaleBasis = FontScaleBasis.NormalBody, trail = "\u00a0\u2192")
        val whole = action(listOf(first, suffix))
        val projection = rubyGraphicalProjection(listOf(whole), "entry/form")
        assertEquals("da\u00a0\u2192", projection.text)
        val ownerRange = projection.ranges.single { it.role == RubyTextRole.ActionGroup }
        assertSame(whole, ownerRange.span)
        assertEquals(0, ownerRange.start); assertEquals(4, ownerRange.end)
        assertEquals("entry/form/spans/0", ownerRange.path)
        assertEquals(listOf(whole), projection.ranges.mapNotNull { it.span }.filter { it.kind == "link" })
        assertSame(first, projection.ranges.single { it.span === first }.span)
        val suffixRange = projection.ranges.single { it.span === suffix }
        assertEquals(1, suffixRange.start); assertEquals(4, suffixRange.end)
        assertEquals("entry/form/spans/0/inlineActionGroup/spans/1", suffixRange.path)
        assertEquals(projection.text, rubyBaseText(listOf(whole)))
        assertEquals(projection.text, rubyFallbackText(listOf(whole)))
        val flat = rubyGraphicalSpans(listOf(whole))
        assertEquals(listOf("d", "a"), flat.map { it.text })
        assertTrue(flat.all { it.kind == "link" && it.target == "d" && it.targetFragment == "entry" })
        assertTrue(flat[1].italic); assertTrue(flat[1].superscript); assertFalse(flat[1].bold)
        assertEquals(.8f, flat[1].fontScale!!, 0f); assertEquals("\u00a0\u2192", flat[1].trail)
        assertEquals("text", first.kind); assertEquals("text", suffix.kind)

        val left = action(listOf(text("d"))); val right = action(listOf(text("d")))
        assertEquals(left, right); assertNotSame(left, right)
        val adjacent = rubyGraphicalProjection(listOf(left, right))
        val owners = adjacent.ranges.filter { it.role == RubyTextRole.ActionGroup }
        assertEquals("dd", adjacent.text); assertEquals(2, owners.size)
        assertSame(left, owners[0].span); assertSame(right, owners[1].span)
        assertEquals(listOf(0 to 1, 1 to 2), owners.map { it.start to it.end })
        assertNotEquals(owners[0].path, owners[1].path)
        assertEquals(adjacent.text, rubyGraphicalText(listOf(action(listOf(text("dd"))))))
        assertEquals(1, rubyGraphicalProjection(listOf(action(listOf(text("dd"))))).ranges.count {
            it.role == RubyTextRole.ActionGroup })
        val metric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(12f, FontScaleBasis.CssPx))))
        val emptyOwner = action(listOf(metric))
        val empty = rubyGraphicalProjection(listOf(emptyOwner))
        assertEquals("", empty.text); assertTrue(empty.ranges.all { it.start == 0 && it.end == 0 })
        assertSame(emptyOwner, empty.ranges.first().span)
        val repeatedEmpty = rubyGraphicalProjection(listOf(emptyOwner, emptyOwner)).ranges.filter {
            it.role == RubyTextRole.ActionGroup }
        assertEquals(2, repeatedEmpty.size)
        assertTrue(repeatedEmpty.all { it.span === emptyOwner && it.start == 0 && it.end == 0 })
        assertNotEquals(repeatedEmpty[0].path, repeatedEmpty[1].path)
        assertSame(metric, rubyGraphicalSpans(listOf(emptyOwner)).single())
        assertSame(metric, rubyFallbackSpans(listOf(emptyOwner)).single())
        val ordinary = listOf(text("unchanged", "!"))
        assertSame(ordinary, rubyGraphicalSpans(ordinary)); assertEquals("unchanged!", rubyGraphicalText(ordinary))
    }

    @Test fun actionFallbackKeepsRubyPaddingUtf16AndOnlyRealDescendantsActionable() {
        val policy = LinkPaint(normal = LinkState("#112233", false), hover = LinkState("#223344", true),
            active = LinkState("#334455", false), hoverActive = LinkState("#445566", true),
            visited = LinkState("#556677", false), visitedHover = LinkState("#667788", true),
            visitedActive = LinkState("#778899", false), visitedHoverActive = LinkState("#8899aa", true),
            underlineOnFocus = false, focusOutline = null)
        fun states(value: LinkPaint) = listOf(value.normal, value.hover, value.active, value.hoverActive,
            value.visited, value.visitedHover, value.visitedActive, value.visitedHoverActive)
        val originalStates = states(policy)
        val glyph = text("A\ud83d\ude80", "\u0301").copy(underline = true, italic = true)
        val reading = text("read"); val before = text("["); val explicit = text("reading"); val after = text("]")
        val ruby = owner(RubySegment(emptyList(), listOf(base(glyph)), listOf(
            annotation(0, 1, 0, listOf(reading)), annotation(0, 1, 1, listOf(explicit),
                before = listOf(before), after = listOf(after), explicit = true))))
        val paddingLeaf = text("P", "!")
        val padding = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Em, .25f), StyleLength(StyleLengthUnit.Em, .25f), listOf(paddingLeaf)))
        val metric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(9f, FontScaleBasis.CssPx))))
        val trail = metric.copy(trail = ":")
        val group = Span("external_link", "", "https://example.test/source?q=a%20b#part",
            tooltip = "source tooltip", explanation = "source explanation", linkPaint = policy,
            inlineActionGroup = InlineActionGroup(listOf(ruby, padding, metric, trail)))
        val projection = rubyGraphicalProjection(listOf(group))
        assertEquals("A\ud83d\ude80\u0301readreadingP!:", projection.text)
        assertEquals("A\ud83d\ude80\u0301P!:", rubyBaseText(listOf(group)))
        assertEquals("A\ud83d\ude80\u0301（read）[reading]P!:", rubyFallbackText(listOf(group)))
        val root = projection.ranges.single { it.role == RubyTextRole.ActionGroup }
        assertSame(group, root.span); assertSame(padding, projection.ranges.single { it.role == RubyTextRole.PaddingGroup }.span)
        assertEquals(0, root.start); assertEquals(projection.text.length, root.end)
        val glyphRange = projection.ranges.single { it.span === glyph }
        assertEquals(0, glyphRange.start); assertEquals(4, glyphRange.end)
        assertEquals("A\ud83d\ude80\u0301", projection.text.substring(glyphRange.start, glyphRange.end))
        assertSame(paddingLeaf, projection.ranges.single { it.span === paddingLeaf }.span)
        assertEquals(1, projection.ranges.count { it.span?.kind == "external_link" })
        val fallback = rubyFallbackSpans(listOf(group))
        val generated = fallback.filter { it.text == "（" || it.text == "）" }
        assertEquals(2, generated.size)
        assertTrue(generated.all { it.kind == "text" && it.target.isEmpty() && it.linkPaint == null })
        for (value in listOf("[", "reading", "]", "P", "read")) {
            val projected = fallback.single { it.text == value }
            assertEquals("external_link", projected.kind); assertEquals(group.target, projected.target)
            assertSame(policy, projected.linkPaint); assertEquals("source tooltip", projected.tooltip)
        }
        val decorated = fallback.single { it.text == glyph.text }
        assertTrue(states(decorated.linkPaint!!).all { it.underline })
        assertEquals(originalStates.map { it.foreground }, states(decorated.linkPaint!!).map { it.foreground })
        assertTrue(decorated.italic); assertEquals(glyph.trail, decorated.trail)
        assertSame(metric, fallback.single { it.text.isEmpty() && it.trail.isEmpty() })
        val projectedTrail = fallback.single { it.text == ":" }
        assertEquals("", projectedTrail.trail); assertEquals(group.target, projectedTrail.target)
        assertSame(trail.inlineStyle, projectedTrail.inlineStyle)
        assertEquals("", trail.text); assertEquals(":", trail.trail)
        assertEquals("text", glyph.kind); assertEquals("text", paddingLeaf.kind)
        assertSame(policy, group.linkPaint); assertEquals(originalStates, states(policy))
        assertEquals(projection.text, rubyGraphicalSpans(listOf(group)).joinToString("") { it.text + it.trail })
    }


    @Test fun inlineBoxesKeepOriginalRichRangesRepeatedOwnersAndChildFontFields() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val noBorder = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val edge = InlineBoxBorderEdge.Solid(StyleLength(StyleLengthUnit.Em, .125f), InlineBoxColor.CurrentColor)
        val border = noBorder.copy(right = edge)
        val overlays = listOf(
            InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
                right = InlineBoxInset(StyleWidthUnit.Em, -.25f), bottom = InlineBoxInset(StyleWidthUnit.Percent, 67f)), border),
            InlineBoxOverlay(InlineBoxInsets(bottom = InlineBoxInset(StyleWidthUnit.Px, -1f),
                left = InlineBoxInset(StyleWidthUnit.Percent, 25f)), noBorder.copy(top = edge)))
        val first = Span("text", "A\ud83d\ude80", trail = "\u0301\u00a0\u2192", italic = true,
            fontScale = 1.35f, foreground = "#123456", language = "ja")
        val second = Span("text", "\u05d0", direction = "rtl", fontScale = 1f,
            fontScaleBasis = FontScaleBasis.NormalBody)
        val third = Span("text", "!", fontScale = 20f, fontScaleBasis = FontScaleBasis.CssPx)
        val children = listOf(first, second, third)
        val payload = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), border, overlays, spans = children)
        val sourceOwner = Span("link", "", "source-target", targetFragment = "section", bold = true,
            fontScale = 1.35f, inlineBoxGroup = payload)
        val source = listOf(sourceOwner, sourceOwner)
        val projection = rubyGraphicalProjection(source, "entry/pitch")
        val body = "A\ud83d\ude80\u0301\u00a0\u2192\u05d0!"
        assertEquals(body + body, projection.text)
        val owners = projection.ranges.filter { it.role == RubyTextRole.BoxGroup }
        assertEquals(2, owners.size)
        assertTrue(owners.all { it.span === sourceOwner })
        assertEquals(listOf(0 to 8, 8 to 16), owners.map { it.start to it.end })
        assertEquals(listOf("entry/pitch/spans/0", "entry/pitch/spans/1"), owners.map { it.path })
        val firstRange = projection.ranges.first { it.span === first }
        assertEquals(0, firstRange.start); assertEquals(6, firstRange.end)
        assertEquals("entry/pitch/spans/0/inlineBoxGroup/spans/0", firstRange.path)
        assertEquals(8, projection.ranges.size)
        assertEquals(2, projection.ranges.count { it.span?.hasInternalAction() == true })
        assertEquals(body + body, rubyBaseText(source))
        assertEquals(body + body, rubyFallbackText(source))
        for (flat in listOf(rubyGraphicalSpans(source), rubyFallbackSpans(source))) {
            assertEquals(6, flat.size)
            assertTrue(flat.all { it.kind == "link" && it.target == "source-target" && it.targetFragment == "section" })
            assertEquals(listOf(1.35f, 1f, 20f, 1.35f, 1f, 20f), flat.map { it.fontScale })
            assertEquals(listOf(FontScaleBasis.Context, FontScaleBasis.NormalBody, FontScaleBasis.CssPx),
                flat.take(3).map { it.fontScaleBasis })
            assertTrue(flat[0].italic); assertFalse(flat[0].bold)
            assertEquals(first.foreground, flat[0].foreground)
            assertEquals(first.language, flat[0].language)
            assertEquals(first.trail, flat[0].trail)
            assertEquals(second.direction, flat[1].direction)
        }
        assertSame(children, sourceOwner.inlineBoxGroup!!.spans)
        assertSame(overlays, sourceOwner.inlineBoxGroup!!.overlays)
        assertSame(overlays[0], sourceOwner.inlineBoxGroup!!.overlays[0])
        assertEquals(listOf("text", "text", "text"), children.map { it.kind })
        assertTrue(children.all { it.target.isEmpty() && !it.bold })
        assertEquals(1.35f, first.fontScale!!, 0f)
        assertEquals(1.35f, sourceOwner.fontScale!!, 0f)
    }

    @Test fun inlineBoxFallbackKeepsRubyDelimitersActionCensusAndIndependentChildLinks() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        fun box(children: List<Span>) = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), none,
            overlays = listOf(InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
                left = InlineBoxInset(StyleWidthUnit.Px, 0f)), none)), spans = children)
        val glyph = text("B"); val reading = text("r")
        val ruby = owner(RubySegment(emptyList(), listOf(base(glyph)), listOf(annotation(0, 1, 0, listOf(reading)))))
        val inner = text("!")
        val nested = Span("text", "", inlineBoxGroup = box(listOf(inner)))
        val metric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(9f, FontScaleBasis.CssPx))))
        val whole = Span("external_link", "", "https://example.test/pitch#part", tooltip = "source box",
            underline = true, inlineBoxGroup = box(listOf(ruby, nested, metric)))
        val projection = rubyGraphicalProjection(listOf(whole))
        assertEquals("Br!", projection.text)
        assertEquals(2, projection.ranges.count { it.role == RubyTextRole.BoxGroup })
        assertEquals(1, projection.ranges.count { it.span?.kind == "external_link" })
        val flat = rubyFallbackSpans(listOf(whole))
        assertEquals("B\uff08r\uff09!", flat.joinToString("") { it.text + it.trail })
        assertTrue(flat.filter { it.text == "\uff08" || it.text == "\uff09" }.all {
            it.kind == "text" && it.target.isEmpty() && it.linkPaint == null
        })
        for (value in listOf("B", "r", "!")) {
            val leaf = flat.single { it.text == value }
            assertEquals(whole.target, leaf.target); assertEquals("external_link", leaf.kind)
            assertEquals("source box", leaf.tooltip)
        }
        val flatMetric = flat.single { it.text.isEmpty() && it.trail.isEmpty() }
        assertSame(metric.inlineStyle, flatMetric.inlineStyle)
        assertEquals("text", flatMetric.kind); assertTrue(flatMetric.target.isEmpty())
        assertTrue(flatMetric.underline); assertFalse(metric.underline)
        assertEquals("text", glyph.kind); assertEquals("text", reading.kind); assertEquals("text", inner.kind)
        assertSame(ruby, whole.inlineBoxGroup!!.spans[0])
        assertSame(nested, whole.inlineBoxGroup!!.spans[1])
        val independent = Span("link", "child", "child-target", targetFragment = "child-section")
        val textOwner = Span("text", "", inlineBoxGroup = box(listOf(independent)))
        assertSame(independent, rubyGraphicalSpans(listOf(textOwner)).single())
        assertSame(independent, rubyFallbackSpans(listOf(textOwner)).single())
        assertEquals("child", rubyFallbackText(listOf(textOwner)))
        assertEquals(listOf(independent), rubyGraphicalProjection(listOf(textOwner)).ranges
            .mapNotNull { it.span }.filter { it.hasInternalAction() })
        val ordinary = listOf(text("ordinary", "!"))
        assertSame(ordinary, rubyGraphicalSpans(ordinary))
        assertSame(ordinary.single(), rubyFallbackSpans(ordinary).single())
    }
    @Test fun clippedAbsoluteKeepsOriginalSemanticOccurrencesButEmitsNoVisualFallback() {
        val px = StyleLength(StyleLengthUnit.Px, 1f)
        val negative = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, -1f))
        val margins = ContainerMargins(negative, negative, negative, negative)
        val first = Span("link", "A\ud83d\ude80", "first-target", trail = "\u0301", italic = true,
            fontScale = 17f, fontScaleBasis = FontScaleBasis.CssPx, language = "hu",
            tooltip = "child advisory", explanation = "child explanation")
        val second = Span("link", "A", "second-target", trail = "\u00a0", bold = true,
            fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody)
        val children = listOf(first, second)
        val payload = ClippedAbsoluteInline(px, px, margins, children, staticParentDirection = BidiResolvedDirection.Ltr)
        val clipped = Span("text", "", tooltip = "owner advisory", explanation = "owner explanation",
            clippedAbsolute = payload)
        val before = text("before:"); val after = text(":after")
        val source = listOf(before, clipped, clipped, after)
        val body = "A\ud83d\ude80\u0301A\u00a0"
        val projection = rubyGraphicalProjection(source, "entry/clipped")
        assertEquals("before:$body$body:after", projection.text)
        assertEquals(projection.text, rubyBaseText(source))
        assertEquals(projection.text, rubyFallbackText(source))
        val owners = projection.ranges.filter { it.role == RubyTextRole.ClippedAbsolute }
        assertEquals(2, owners.size); assertTrue(owners.all { it.span === clipped })
        assertEquals(listOf(7 to 13, 13 to 19), owners.map { it.start to it.end })
        assertEquals(listOf("entry/clipped/spans/1", "entry/clipped/spans/2"), owners.map { it.path })
        assertTrue(owners.all { projection.text.substring(it.start, it.end) == body })
        assertTrue(owners.all { it.span!!.tooltip == "owner advisory" && it.span!!.explanation == "owner explanation" })
        val leaves = projection.ranges.filter { it.role == RubyTextRole.ClippedText }
        assertEquals(4, leaves.size)
        assertEquals(listOf(first, second, first, second), leaves.map { it.span })
        assertEquals(listOf(7 to 11, 11 to 13, 13 to 17, 17 to 19), leaves.map { it.start to it.end })
        assertEquals("entry/clipped/spans/1/clippedAbsolute/children/0", leaves.first().path)
        for (flat in listOf(rubyGraphicalSpans(source), rubyFallbackSpans(source))) {
            assertEquals(listOf(before, first, second, first, second, after), flat)
            assertSame(first, flat[1]); assertSame(second, flat[2])
            assertEquals("child advisory", flat[1].tooltip); assertNull(flat[2].tooltip)
            assertEquals("child explanation", flat[1].explanation); assertEquals("", flat[2].explanation)
        }
        val visual = rubyVisualFallbackSpans(source)
        assertEquals(listOf(before, after), visual); assertSame(before, visual[0]); assertSame(after, visual[1])
        assertEquals("before::after", visual.joinToString("") { it.text + it.trail })
        assertTrue(rubyVisualFallbackSpans(listOf(clipped)).isEmpty())
        assertSame(children, clipped.clippedAbsolute!!.children)
        assertSame(margins, clipped.clippedAbsolute!!.margin)
        assertEquals(-1f, (clipped.clippedAbsolute!!.margin.left as ContainerMargin.Length).value.value, 0f)
        assertEquals(listOf("first-target", "second-target"), children.map { it.target })

        val policy = LinkPaint(normal = LinkState("#112233", false), hover = LinkState("#223344", true),
            active = LinkState("#334455", false), hoverActive = LinkState("#445566", true),
            visited = LinkState("#556677", false), visitedHover = LinkState("#667788", true),
            visitedActive = LinkState("#778899", false), visitedHoverActive = LinkState("#8899aa", true),
            underlineOnFocus = false, focusOutline = null)
        fun states(value: LinkPaint) = listOf(value.normal, value.hover, value.active, value.hoverActive,
            value.visited, value.visitedHover, value.visitedActive, value.visitedHoverActive)
        val original = states(policy)
        val glyph = text("read", "!").copy(underline = true, italic = true, fontScale = .5f,
            tooltip = "own child tooltip")
        val action = Span("link", "", "owner-action", targetFragment = "part", foreground = "#112233",
            tooltip = "action tooltip", explanation = "action explanation", linkPaint = policy,
            clippedAbsolute = payload.copy(children = listOf(glyph)))
        val semantic = rubyFallbackSpans(listOf(action)).single()
        assertEquals("owner-action", semantic.target); assertEquals("part", semantic.targetFragment)
        assertEquals("read!", rubyFallbackText(listOf(action)))
        assertEquals("own child tooltip", semantic.tooltip); assertEquals("action explanation", semantic.explanation)
        assertEquals(.5f, semantic.fontScale!!, 0f); assertTrue(semantic.italic)
        assertTrue(states(semantic.linkPaint!!).all { it.underline })
        assertEquals(original.map { it.foreground }, states(semantic.linkPaint!!).map { it.foreground })
        assertEquals(original, states(policy)); assertSame(policy, action.linkPaint)
        assertEquals("text", glyph.kind); assertEquals("", glyph.target)
        assertTrue(rubyVisualFallbackSpans(listOf(action)).isEmpty())
        val ordinary = listOf(text("ordinary", "!"))
        assertSame(ordinary, rubyGraphicalSpans(ordinary))
        assertSame(ordinary.single(), rubyVisualFallbackSpans(ordinary).single())
    }

    @Test fun nativeTerminalProjectionFlattensFallbackOwnersButKeepsClippedSourceAndPolicies() {
        val px = StyleLength(StyleLengthUnit.Px, 1f)
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val negative = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, -1f))
        val first = Span("link", "A\ud83d\ude80", "hidden-first", trail = "\u0301", italic = true,
            fontScale = 17f, fontScaleBasis = FontScaleBasis.CssPx, language = "hu",
            tooltip = "child tooltip", explanation = "child explanation")
        val second = Span("link", "A", "hidden-second", trail = "\u00a0", bold = true)
        val children = listOf(first, second)
        val clipped = Span("text", "", tooltip = "owner tooltip", explanation = "owner explanation",
            clippedAbsolute = ClippedAbsoluteInline(px, px,
                ContainerMargins(negative, negative, negative, negative), children,
                staticParentDirection = BidiResolvedDirection.Ltr))
        val hiddenReading = text("B")
        val ruby = single(listOf(text("B")), listOf(hiddenReading))
        assertTrue(rubyAnnotationHidden(ruby.ruby!!.segments.single(), ruby.ruby!!.segments.single().annotations.single()))
        val policy = LinkPaint(normal = LinkState("#112233", false), hover = LinkState("#223344", true),
            active = LinkState("#334455", false), hoverActive = LinkState("#445566", true),
            visited = LinkState("#556677", false), visitedHover = LinkState("#667788", true),
            visitedActive = LinkState("#778899", false), visitedHoverActive = LinkState("#8899aa", true),
            underlineOnFocus = false, focusOutline = null)
        val action = Span("link", "", "outer-action", foreground = "#112233", linkPaint = policy,
            inlineActionGroup = InlineActionGroup(listOf(ruby)))
        val ownLink = Span("external_link", "U", "https://example.test/child", italic = true,
            fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody)
        val padding = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(px, px, listOf(ownLink)))
        val boxLeaf = text("X", "!").copy(inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(9f, FontScaleBasis.CssPx))))
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val box = Span("text", "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero),
            none.copy(right = InlineBoxBorderEdge.Solid(px, InlineBoxColor.CurrentColor)), emptyList(), listOf(boxLeaf)))
        val image = Span("text", "", image = InlineImage("Controlled.png", widthPx = 20))
        val source = listOf(action, clipped, padding, box, clipped, image)
        val terminal = rubyNativeTerminalProjection(source, "entry/terminal")
        assertSame(source, terminal.source)
        assertTrue(terminal.spans.all { it.ruby == null && it.inlinePaddingGroup == null &&
            it.inlineActionGroup == null && it.inlineBoxGroup == null })
        assertTrue(terminal.spans.filter { it.clippedAbsolute != null }.all { it === clipped })
        val body = "A\ud83d\ude80\u0301A\u00a0"
        assertEquals("B\uff08B\uff09${body}UX!${body}\ufffc", terminal.projection.text)
        assertEquals("B${body}UX!${body}\ufffc", rubyGraphicalText(source))
        val clipRanges = terminal.projection.ranges.filter { it.role == RubyTextRole.ClippedAbsolute }
        assertEquals(listOf(4 to 10, 13 to 19), clipRanges.map { it.start to it.end })
        assertEquals(listOf("entry/terminal/spans/4", "entry/terminal/spans/7"), clipRanges.map { it.path })
        assertTrue(clipRanges.all { it.span === clipped && terminal.projection.text.substring(it.start, it.end) == body })
        val childRanges = terminal.projection.ranges.filter { it.role == RubyTextRole.ClippedText }
        assertEquals(listOf(first, second, first, second), childRanges.map { it.span })
        assertEquals(listOf(4 to 8, 8 to 10, 13 to 17, 17 to 19), childRanges.map { it.start to it.end })
        assertSame(children, clipped.clippedAbsolute!!.children)
        assertEquals("owner tooltip", clipped.tooltip); assertEquals("child tooltip", first.tooltip)
        assertEquals("child explanation", first.explanation); assertEquals(17f, first.fontScale!!, 0f)
        val flattenedReadings = terminal.spans.filter { it.text == "B" }
        assertEquals(2, flattenedReadings.size)
        assertTrue(flattenedReadings.all { it.target == "outer-action" && it.linkPaint === policy })
        assertTrue(terminal.spans.filter { it.text == "\uff08" || it.text == "\uff09" }.all {
            it.kind == "text" && it.target.isEmpty() && it.linkPaint == null
        })
        assertSame(ownLink, terminal.spans.single { it.text == "U" })
        assertSame(boxLeaf, terminal.spans.single { it.text == "X" })
        assertSame(boxLeaf.inlineStyle, terminal.spans.single { it.text == "X" }.inlineStyle)
        assertSame(image, terminal.spans.last()); assertSame(image.image, terminal.spans.last().image)
        val replay = rubyNativeTerminalProjection(terminal.spans, "entry/terminal")
        assertSame(terminal.spans, replay.spans)
        assertEquals(terminal.projection, replay.projection)
        assertSame(policy, action.linkPaint); assertFalse(policy.normal.underline)
        assertEquals("text", hiddenReading.kind); assertEquals("", hiddenReading.target)
        val ordinary = listOf(text("unchanged", "!"))
        assertSame(ordinary, rubyNativeTerminalProjection(ordinary).spans)
        assertSame(clipped, rubyNativeTerminalProjection(listOf(clipped)).spans.single())
        assertTrue(rubyNativeTerminalProjection(emptyList()).projection.text.isEmpty())
    }

    @Test fun nativeAdvisoryDeclarationsKeepOriginalOwnersNullInheritanceAndLocalEmptySuppression() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        fun box(children: List<Span>, title: String?) = Span("text", "", tooltip = title,
            inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), none, spans = children))
        val inherited = Span("text", "e")
        val suppressed = Span("text", "x", tooltip = "")
        val own = Span("text", "y", tooltip = "Child title")
        val linked = Span("link", "real", "Original", targetFragment = "Part")
        val nested = box(listOf(linked), null)
        val owner = box(listOf(inherited, suppressed, own, nested), "Owner title")
        val outside = Span("text", "\u2009label")
        val source = listOf(owner, outside, owner)
        val projection = rubyGraphicalProjection(source)
        val index = NativeTextAdvisoryIndex(projection)
        val declarations = index.declarations
        assertEquals("exyreal\u2009labelexyreal", projection.text)
        assertEquals(listOf("Owner title", "", "Child title", "Owner title", "", "Child title"),
            declarations.map { it.span!!.tooltip })
        fun ranges(span: Span) = projection.ranges.filter { it.span === span }
        ranges(inherited).forEach { assertEquals("Owner title", index.title(it)) }
        ranges(suppressed).forEach { assertEquals("", index.title(it)) }
        ranges(own).forEach { assertEquals("Child title", index.title(it)) }
        ranges(linked).forEach { assertEquals("Owner title", index.title(it)) }
        assertNull(index.title(ranges(outside).single()))
        assertNull(inherited.tooltip); assertNull(linked.tooltip); assertEquals("", suppressed.tooltip)
        assertSame(owner, source[0]); assertSame(owner, source[2])
        assertEquals(2, projection.ranges.count { it.span?.kind == "link" })
        val first = ranges(owner).first(); val repeated = ranges(owner).last()
        assertEquals(NativeTextAdvisoryIdentity(owner, first.path), NativeTextAdvisoryIdentity(owner, first.path))
        assertNotEquals(NativeTextAdvisoryIdentity(owner, first.path), NativeTextAdvisoryIdentity(owner, repeated.path))
        assertNotEquals(NativeTextAdvisoryIdentity(owner, first.path), NativeTextAdvisoryIdentity(owner.copy(), first.path))
        assertSame(inherited, owner.inlineBoxGroup!!.spans[0]); assertSame(linked, nested.inlineBoxGroup!!.spans.single())
    }

    @Test fun nativeAdvisoryIndexKeepsCoincidentActionOwnersAndImageTitlePrecedence() {
        val empty = Span("text", "")
        val first = Span("link", "", "First", tooltip = "First title", inlineActionGroup = InlineActionGroup(listOf(empty)))
        val second = Span("link", "", "Second", tooltip = "Second title", inlineActionGroup = InlineActionGroup(listOf(empty)))
        val own = Span("text", "", tooltip = "Raw span title", image = InlineImage("One.png", tooltip = "Own image title"))
        val suppressed = own.copy(image = own.image!!.copy(file = "Two.png", tooltip = ""))
        val inherited = own.copy(image = own.image!!.copy(file = "Three.png", tooltip = null))
        val projection = rubyGraphicalProjection(listOf(first, second, own, suppressed, inherited))
        val index = NativeTextAdvisoryIndex(projection)
        val a = projection.ranges.single { it.span === first }
        val b = projection.ranges.single { it.span === second }
        assertEquals(a.start, b.start); assertEquals(a.end, b.end)
        assertEquals("First title", index.title(a)); assertEquals("Second title", index.title(b))
        assertNotEquals(NativeTextAdvisoryIdentity(first, a.path), NativeTextAdvisoryIdentity(second, b.path))
        assertEquals("Own image title", index.imageTitle(projection.ranges.single { it.span === own }, "fallback"))
        assertEquals("", index.imageTitle(projection.ranges.single { it.span === suppressed }, "fallback"))
        assertEquals("Raw span title", index.imageTitle(projection.ranges.single { it.span === inherited }, "fallback"))
        assertEquals(EntryLink("First"), first.entryLink()); assertEquals(EntryLink("Second"), second.entryLink())
        assertEquals("\ufffc\ufffc\ufffc", projection.text)
        assertEquals(2, projection.ranges.count { it.span?.hasInternalAction() == true })
        assertSame(empty, first.inlineActionGroup!!.spans.single()); assertSame(empty, second.inlineActionGroup!!.spans.single())
    }


    private fun chemicalIntrinsicOwner(digit: String = "2"): Span {
        val height = InlineLineHeight.Computed(InlineComputedLength(.8f, FontScaleBasis.NormalBody))
        val style = InlineTextStyle(fontNormalized = true, lineHeight = height, wrap = TextWrap.Normal)
        val child = Span("text", digit, fontScale = .8f, fontScaleBasis = FontScaleBasis.NormalBody,
            language = "hu", inlineStyle = style)
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val layout = InlineBoxIntrinsicLinesLayout(
            marginBottom = InlineBoxSignedLength(StyleLengthUnit.Em, -.3f),
            verticalAlign = InlineBoxSignedLength(StyleLengthUnit.Em, -.4f),
            lineHeight = height, textAlign = InlineBoxOverlayTextAlign.Left, wrap = TextWrap.Normal,
            lines = listOf(InlineBoxIntrinsicLine(0, InlineBoxIntrinsicLineKind.Sup, true),
                InlineBoxIntrinsicLine(1, InlineBoxIntrinsicLineKind.Sub, false)))
        return child.copy(text = "", inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero),
            none, spans = listOf(child), intrinsicLinesLayout = layout))
    }

    @Test fun intrinsicSourceBreakOwnsItsRangeWithoutInventingAChildOrNeighborAction() {
        val owner = chemicalIntrinsicOwner()
        val box = owner.inlineBoxGroup!!
        val child = box.spans.single()
        val before = Span("link", "H", "hydrogen", targetFragment = "symbol")
        val after = Span("link", "O", "oxygen", targetFragment = "symbol")
        val unit = Span("external_link", " mol", "https://example.test/unit")
        val source = listOf(before, owner, after, unit)
        val projection = rubyGraphicalProjection(source, "chemical")
        assertEquals("H\n2O mol", projection.text)
        val group = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        val br = projection.ranges.single { it.role == RubyTextRole.IntrinsicLineBreak }
        val digit = projection.ranges.single { it.span === child }
        assertEquals(1 to 3, group.start to group.end)
        assertEquals(1 to 2, br.start to br.end)
        assertEquals(2 to 3, digit.start to digit.end)
        assertEquals("chemical/spans/1/inlineBoxGroup/intrinsicLinesLayout/lines/0", br.path)
        assertEquals("chemical/spans/1/inlineBoxGroup/spans/0", digit.path)
        assertSame(owner, group.span)
        assertSame(box.intrinsicLinesLayout!!.lines[0], br.intrinsicLine)
        assertEquals(0, br.intrinsicLineIndex)
        assertNull(br.span)
        assertSame(child, digit.span)
        assertEquals("\n", projection.text.substring(br.start, br.end))
        assertEquals("2", projection.text.substring(digit.start, digit.end))
        assertEquals(listOf(before, child, after, unit), rubyGraphicalSpans(source))
        rubyGraphicalSpans(source).zip(listOf(before, child, after, unit)).forEach { (a, b) -> assertSame(a, b) }
        assertEquals(listOf(before, after, unit), projection.ranges.mapNotNull { it.span }
            .filter { it.hasInternalAction() || it.kind == "external_link" })
        assertEquals(listOf(0 to 1, 3 to 4, 4 to 8), projection.ranges.filter {
            it.span === before || it.span === after || it.span === unit }.map { it.start to it.end })
        assertEquals(2, group.end - group.start) // Actual BR plus the one original digit.
        assertEquals(1, box.spans.size)
        assertSame(child, box.spans.single())
        assertEquals("2", child.text)
        assertFalse(child.superscript); assertFalse(child.subscript)
        assertEquals(3, source.count { it.hasInternalAction() || it.kind == "external_link" })

        val repeated = rubyGraphicalProjection(listOf(owner, owner), "repeat")
        assertEquals("\n2\n2", repeated.text)
        assertEquals(listOf(0 to 1, 2 to 3), repeated.ranges.filter {
            it.role == RubyTextRole.IntrinsicLineBreak }.map { it.start to it.end })
        assertEquals(2, repeated.ranges.filter { it.role == RubyTextRole.IntrinsicLineBreak }.map { it.path }.distinct().size)
        assertTrue(repeated.ranges.filter { it.role == RubyTextRole.IntrinsicLineBreak }.all {
            it.intrinsicLine === box.intrinsicLinesLayout!!.lines[0] })
    }

    @Test fun intrinsicSourceBreakSurvivesTerminalBaseAndAnonymousCopyWithoutChangingLegacyGroups() {
        val owner = chemicalIntrinsicOwner("7") // Projection is not hardcoded to the genuine source's digit.
        val child = owner.inlineBoxGroup!!.spans.single()
        val prefix = Span("link", "H", "hydrogen")
        val suffix = Span("link", "O", "oxygen")
        val source = listOf(prefix, owner, suffix)
        assertEquals("H\n7O", rubyGraphicalText(source))
        assertEquals("H\n7O", rubyBaseText(source))
        assertEquals("H\n7O", rubyFallbackText(source))
        val fallback = rubyFallbackSpans(source)
        assertEquals(3, fallback.size)
        assertSame(prefix, fallback[0]); assertSame(suffix, fallback[2])
        assertEquals(child.copy(text = "\n7"), fallback[1])
        assertEquals("text", fallback[1].kind); assertTrue(fallback[1].target.isEmpty())
        assertNull(fallback[1].inlineBoxGroup); assertEquals("7", child.text)
        val terminal = rubyNativeTerminalProjection(source, "terminal")
        assertSame(source, terminal.source)
        assertEquals("H\n7O", terminal.projection.text)
        assertEquals("H\n7O", rubyVisualFallbackSpans(source).joinToString("") { it.text + it.trail })
        val semantic = anonymousInlineSemantic(source, rubyGraphicalText(source))
        assertEquals(listOf(0 to 1, 1 to 2, 2 to 3, 3 to 4), semantic.map { it.start to it.end })
        assertEquals(listOf("H", "\n", "7", "O"), semantic.map { it.text })
        assertTrue(semantic.none { it.replacement })
        assertEquals("H\n7O", semantic.joinToString("") { it.text })
        assertEquals("H 7O", textOf(source)) // Existing preview whitespace normalization remains explicit.
        assertThrows(IllegalArgumentException::class.java) {
            owner.inlineBoxGroup!!.intrinsicLinesLayout!!.copy(lines = listOf(
                InlineBoxIntrinsicLine(0, InlineBoxIntrinsicLineKind.Sup, false),
                InlineBoxIntrinsicLine(1, InlineBoxIntrinsicLineKind.Sub, false)))
        }
        val ordinary = owner.copy(inlineBoxGroup = owner.inlineBoxGroup!!.copy(intrinsicLinesLayout = null))
        assertEquals("7", rubyGraphicalText(listOf(ordinary)))
        assertEquals("7", rubyBaseText(listOf(ordinary)))
        assertEquals("7", rubyFallbackText(listOf(ordinary)))
        assertTrue(rubyGraphicalProjection(listOf(ordinary)).ranges.none { it.role == RubyTextRole.IntrinsicLineBreak })
        assertSame(child, rubyFallbackSpans(listOf(ordinary)).single())
        assertSame(child, rubyGraphicalSpans(listOf(ordinary)).single())
        assertSame(child, owner.inlineBoxGroup!!.spans.single())
    }
}
