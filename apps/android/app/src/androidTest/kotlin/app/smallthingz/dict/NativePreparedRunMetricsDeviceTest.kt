package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.ParagraphStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativePreparedRunMetricsDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun preparedSourceKeepsInheritedNumberAndExplicitChildLengthWithResolvedRunFonts() {
        val text = "Aa\nBb"
        val annotated = AnnotatedString(text,
            spanStyles = listOf(AnnotatedString.Range(SpanStyle(fontSize = 40.sp), 1, 2),
                AnnotatedString.Range(SpanStyle(fontSize = 30.sp), 4, 5)),
            paragraphStyles = listOf(AnnotatedString.Range(ParagraphStyle(lineHeight = 18.sp), 3, 5)))
        var prepared: PreparedNativeFloatText? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val value = prepareNativeFloatText(listOf(Span("text", text)), annotated, emptyList(),
                            TextStyle(fontSize = 20.sp, lineHeight = 99.sp, fontFamily = FontFamily.Monospace),
                            MaterialTheme.colorScheme.primary, emptyList(),
                            AppSettings(allowImages = false, allowAudio = false), "", {},
                            nativeLineHeight = NativeLineHeightPolicy.Multiplier(1.5f))
                        SideEffect { prepared = value }
                    }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val value = checkNotNull(prepared)
                val native = checkNotNull(value.native)
                val source = native.source(300)
                val first = source.getSpans(0, 2, NativeRunLineMetrics::class.java)
                val second = source.getSpans(3, 5, NativeRunLineMetrics::class.java)
                assertTrue(first.isNotEmpty() && second.isNotEmpty())
                assertTrue(first.all { it.policy == NativeLineHeightPolicy.Multiplier(1.5f) })
                assertTrue(second.all { it.policy == NativeLineHeightPolicy.Pixels(18f) })
                assertEquals(setOf(20f, 40f), first.map { it.primary.fontSize }.toSet())
                assertEquals(setOf(20f, 30f), second.map { it.primary.fontSize }.toSet())
                assertEquals(1, first.count { it.strut }); assertEquals(1, second.count { it.strut })
                val geometry = checkNotNull(value.geometry).invoke(300, emptyList(), false)
                val firstBounds = first.map { it.primary.authored(it.policy)!! }.reduce { a, b -> a.including(b) }
                val secondBounds = second.map { it.primary.authored(it.policy)!! }.reduce { a, b -> a.including(b) }
                assertEquals(firstBounds.height + secondBounds.height, geometry.textBottom, 0.001f)
                assertEquals(-firstBounds.top, geometry.baselineForOffset(0), 0.001f)
                assertEquals(firstBounds.height - secondBounds.top, geometry.baselineForOffset(3), 0.001f)
                assertEquals(text, geometry.text.toString())
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun actualContainerOwnerStrutSurvivesEveryChildOverrideNestedResetAndZeroOwner() {
        val inherited = ContainerStyle(ownerFontScale = .9f, lineHeight = ContainerLineHeight.Multiplier(1.5f))
            .textContext(ContainerTextContext())
        val contexts = listOf(inherited, inherited, ContainerStyle(ownerFontScale = 1f).textContext(inherited),
            ContainerStyle(ownerFontScale = 0f).textContext(inherited),
            ContainerStyle(lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Em, 1.35f)))
                .textContext(inherited))
        val childSizes = listOf(9f, 36f, 20f, 40f, 40f)
        val prepared = arrayOfNulls<PreparedNativeFloatText>(contexts.size)
        val actions = mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        contexts.forEachIndexed { index, owner ->
                            val format = nativeContainerTextFormat(owner, 20.sp,
                                TextStyle(fontSize = 99.sp, lineHeight = 99.sp, fontFamily = FontFamily.Monospace),
                                LocalDensity.current)
                            val annotated = androidx.compose.ui.text.buildAnnotatedString {
                                append("W")
                                addStyle(SpanStyle(fontSize = childSizes[index].sp), 0, 1)
                                addLink(androidx.compose.ui.text.LinkAnnotation.Clickable("owner-$index", linkInteractionListener = null), 0, 1)
                            }
                            val value = prepareNativeFloatText(listOf(Span("link", "W", "owner-$index")),
                                annotated, emptyList(), format.style, MaterialTheme.colorScheme.primary,
                                emptyList(), AppSettings(allowImages = false, allowAudio = false), "",
                                { actions += it }, nativeLineHeight = format.lineHeight)
                            SideEffect { prepared[index] = value }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                contexts.forEachIndexed { index, owner ->
                    val value = checkNotNull(prepared[index])
                    val native = checkNotNull(value.native)
                    val source = native.source(200)
                    val runs = source.getSpans(0, source.length, NativeRunLineMetrics::class.java)
                    val strut = runs.single { it.strut }
                    assertEquals(20f * owner.ownerFontScale, native.paint.textSize, .001f)
                    assertEquals(native.paint.textSize, strut.primary.fontSize, .001f)
                    assertEquals(childSizes[index], runs.single { !it.strut }.primary.fontSize, .001f)
                    val policy = if (index == 4) NativeLineHeightPolicy.Pixels(27f)
                        else NativeLineHeightPolicy.Multiplier(1.5f)
                    assertTrue(runs.all { it.policy == policy })
                    // Independent primary-font half-leading oracle for the real prepared strut and run.
                    val boxes = runs.map { run ->
                        val metrics = run.primary
                        val height = if (index == 4) 27f else metrics.fontSize * 1.5f
                        val leading = (height - (metrics.descent - metrics.ascent)) / 2f
                        (metrics.ascent - leading + metrics.baselineShift) to
                            (metrics.descent + leading + metrics.baselineShift)
                    }
                    val top = boxes.minOf { it.first }; val bottom = boxes.maxOf { it.second }
                    val geometry = checkNotNull(value.geometry).invoke(200, emptyList(), false)
                    assertEquals(bottom - top, geometry.textBottom, .001f)
                    assertEquals(-top, geometry.baselineForOffset(0), .001f)
                    if (index == 0) assertEquals(27f, geometry.textBottom, .001f)
                    if (index == 3) assertTrue("Zero owner must retain the positive child", geometry.textBottom > 0f)
                    assertEquals("W", geometry.text.toString())
                    assertTrue(geometry.rectsForRange(0, 1).any { it.width() > 0f && it.height() > 0f })
                    val bitmap = android.graphics.Bitmap.createBitmap(256, 180, android.graphics.Bitmap.Config.ARGB_8888)
                    try {
                        val canvas = android.graphics.Canvas(bitmap); canvas.translate(24f, 48f); geometry.paint(canvas)
                        val pixels = IntArray(256 * 180); bitmap.getPixels(pixels, 0, 256, 0, 0, 256, 180)
                        assertTrue("Actual owner/child glyph paint must survive", pixels.count { android.graphics.Color.alpha(it) != 0 } > 10)
                    } finally { bitmap.recycle() }
                    geometry.nodes.single { it.onClick != null }.onClick!!()
                    assertEquals("owner-$index", actions.last().target)
                }
                assertEquals(contexts.indices.map { "owner-$it" }, actions.map { it.target })
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }
}
