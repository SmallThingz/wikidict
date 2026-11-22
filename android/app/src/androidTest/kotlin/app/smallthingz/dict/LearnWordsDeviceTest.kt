package app.smallthingz.dict

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.random.Random

@RunWith(AndroidJUnit4::class)
class LearnWordsDeviceTest {
    private val scientist = "\uD83D\uDC69\u200D\uD83D\uDD2C"
    private val flag = "\uD83C\uDDF3\uD83C\uDDFF"
    private val accented = "e\u0301"
    private val fixtures get() = listOf(
        listOf(accented, "t", "s"),
        listOf("a", scientist, "b"),
        listOf("a", flag, "b"),
    )

    @Test fun platformCharacterBoundariesKeepCombiningMarksAndEmojiTogether() {
        for (letters in fixtures) assertEquals(letters, scrambleLetters(letters.joinToString("")))
        assertEquals(emptyList<String>(), scrambleLetters(""))
    }

    @Test fun eligibilityCountsVisibleCharactersInsteadOfCodePoints() {
        val titles = listOf("", accented, scientist, flag, accented + "t", scientist + "a") +
            fixtures.map { it.joinToString("") }
        val words = titles.mapIndexed { index, title -> SavedWord("word-$index", title, "English", "language", "Clue") }
        assertEquals(words.takeLast(fixtures.size), playableScrambleWords(words))
    }

    @Test fun shufflePreservesEveryCompleteCharacterAcrossOrders() {
        for (letters in fixtures) {
            val title = letters.joinToString("")
            for (seed in 0 until 32) {
                val result = scramble(title, Random(seed))
                assertEquals(letters.sorted(), scrambleLetters(result).sorted())
                assertNotEquals(title, result)
            }
        }
    }

    @Test fun unchangedShuffleRotatesCompleteCharacters() {
        val unchanged = object : Random() {
            override fun nextBits(bitCount: Int): Int = 0
            override fun nextInt(until: Int): Int = until - 1
        }
        for (letters in fixtures) {
            assertEquals((letters.drop(1) + letters.first()).joinToString(""), scramble(letters.joinToString(""), unchanged))
        }
    }

    @Test fun zeroOrOneCharacterRemainsIntact() {
        for (title in listOf("", "a", accented, scientist, flag)) assertEquals(title, scramble(title, Random(0)))
    }
}
