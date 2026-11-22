package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class AuthoredRuleTest {
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val edges = StyleEdges(StyleLength(StyleLengthUnit.Em, .2f), StyleLength(StyleLengthUnit.Px, 2f),
        StyleLength(StyleLengthUnit.Em, .3f), StyleLength(StyleLengthUnit.Px, 4f))
    private val policy = RuleStyle(StyleLength(StyleLengthUnit.Px, 1f),
        ContainerColor.LightDark("#123456", "#abcdef"), edges)
    private fun rule(style: RuleStyle? = policy) = Block("rule", 0, emptyList(), ruleStyle = style)
    private fun figure(): Figure {
        val emptyEdges = StyleEdges(zero, zero, zero, zero)
        return Figure(FigureContent.Image(Span("text", "", image = InlineImage("Controlled.svg")), FigureSizingPolicy.Intrinsic),
            FigureFormat.Framed, FigurePlacement.None, FigureClear.None, emptyEdges, emptyEdges, emptyEdges,
            1f, StyleLength(StyleLengthUnit.Em, 1f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent)
    }
    private fun rejects(label: String, action: () -> Any?) { assertTrue(label, runCatching(action).isFailure) }

    @Test fun mandatoryTypedPolicyPreservesPhysicalEdgesThemeFillAndZeroHeight() {
        val value = rule()
        assertEquals(policy, value.ruleStyle)
        assertEquals(StyleLength(StyleLengthUnit.Em, .2f), value.ruleStyle!!.margins.top)
        assertEquals(StyleLength(StyleLengthUnit.Px, 2f), value.ruleStyle!!.margins.right)
        assertEquals(StyleLength(StyleLengthUnit.Em, .3f), value.ruleStyle!!.margins.bottom)
        assertEquals(StyleLength(StyleLengthUnit.Px, 4f), value.ruleStyle!!.margins.left)
        assertEquals(ContainerColor.LightDark("#123456", "#abcdef"), value.ruleStyle!!.fill)
        val empty = RuleStyle(zero, ContainerColor.Transparent, StyleEdges(zero, zero, zero, zero))
        assertEquals(empty, rule(empty).ruleStyle)
        assertEquals(StyleLength(StyleLengthUnit.Em, .125f), rule(policy.copy(
            height = StyleLength(StyleLengthUnit.Em, .125f), fill = ContainerColor.Rgb("#112233"))).ruleStyle!!.height)
        for (invalid in listOf(-.1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            rejects("length $invalid") { policy.copy(height = StyleLength(StyleLengthUnit.Px, invalid)) }
        }
        rejects("noncanonical fill") { policy.copy(fill = ContainerColor.Rgb("#ABCDEF")) }
    }

    @Test fun presentRulePolicyRejectsEveryCompetingBlockOwnerAndMetadataField() {
        val good = rule()
        val table = Table(emptyList(), emptyList())
        val feature = Feature("feature", "en", "data", "", "")
        val invalid: List<Pair<String, () -> Block>> = listOf(
            "kind" to { good.copy(kind = "paragraph") }, "depth" to { good.copy(depth = 1) },
            "level" to { good.copy(level = 1) }, "spans" to { good.copy(spans = listOf(Span("text", ""))) },
            "list path" to { good.copy(listPath = "*") }, "number" to { good.copy(number = "1") },
            "anchor" to { good.copy(anchor = "destination") }, "anchor fallback" to { good.copy(anchorFallback = "fallback") },
            "feature" to { good.copy(feature = feature) }, "table" to { good.copy(table = table) },
            "figure" to { good.copy(figure = figure()) }, "flow" to { good.copy(flow = emptyList()) },
            "container" to { good.copy(container = Container(emptyList())) },
            "BlockStyle" to { good.copy(style = BlockStyle(padding = edges)) },
            "text alignment" to { good.copy(textAlign = CellTextAlign.Center) })
        invalid.forEach { (label, mutate) -> rejects(label, mutate) }
        assertEquals(CellTextAlign.Center, rule(null).copy(textAlign = CellTextAlign.Center).textAlign)
        assertEquals(table, rule(null).copy(table = table).table)
    }

    @Test fun authoredAndLegacyRulesRemainNonTextualWithoutDroppingNeighborActions() {
        val before = Block("paragraph", 0, listOf(Span("link", "Before", "before-target")))
        val after = Block("paragraph", 0, listOf(Span("external_link", "After", "https://example.test/after")))
        val blocks = listOf(before, rule(), rule(null), after)
        val parent = Block("container", 0, emptyList(), container = Container(blocks))
        val observed = mutableListOf<Span>()
        parent.visitSpanRuns { spans, _ -> observed += spans }
        assertEquals(listOf("Before", "After"), observed.map { it.text })
        assertEquals(listOf("before-target", "https://example.test/after"), observed.map { it.target })
        assertEquals(blocks, parent.container!!.blocks)
        assertEquals(policy, parent.container!!.blocks[1].copy().ruleStyle)
        assertNull(parent.container!!.blocks[2].ruleStyle)
        val reference = Reference(1, 1, "", emptyList(), blocks = blocks)
        observed.clear(); reference.visitSpanRuns { spans, _ -> observed += spans }
        assertEquals(listOf("Before", "After"), observed.map { it.text })
    }

    @Test fun legacyContainerPredicateRejectsOnlyAuthoredVerticalMarginsRecursively() {
        fun direct(block: Block) = Container(listOf(block))
        fun nested(block: Block) = Container(listOf(Block("container", 0, emptyList(), container = direct(block))))
        for (wrap in listOf<(Block) -> Container>(::direct, ::nested)) {
            assertFalse(legacyContainerMarginsSupported(wrap(rule())))
            val topOnly = policy.copy(margins = edges.copy(bottom = zero))
            val bottomOnly = policy.copy(margins = edges.copy(top = zero))
            assertFalse(legacyContainerMarginsSupported(wrap(rule(topOnly))))
            assertFalse(legacyContainerMarginsSupported(wrap(rule(bottomOnly))))
            val horizontalOnly = policy.copy(margins = edges.copy(top = zero, bottom = zero))
            assertTrue(legacyContainerMarginsSupported(wrap(rule(horizontalOnly))))
            val empty = policy.copy(height = zero, margins = StyleEdges(
                StyleLength(StyleLengthUnit.Em, 0f), zero, zero, zero))
            assertTrue(legacyContainerMarginsSupported(wrap(rule(empty))))
            assertTrue(legacyContainerMarginsSupported(wrap(rule(null).copy(textAlign = CellTextAlign.Center))))
        }
    }
}
