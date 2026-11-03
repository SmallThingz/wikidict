package app.smallthingz.dict

import android.icu.text.BreakIterator
import java.text.Normalizer
import java.util.Locale
import kotlin.random.Random

internal fun scrambleAnswerMatches(guess: String, title: String): Boolean =
    Normalizer.normalize(guess.trim(), Normalizer.Form.NFC)
        .equals(Normalizer.normalize(title, Normalizer.Form.NFC), ignoreCase = true)

internal fun scrambleLetters(value: String, boundaries: BreakIterator = BreakIterator.getCharacterInstance(Locale.ROOT)): List<String> {
    boundaries.setText(value)
    return buildList {
        var start = boundaries.first()
        var end = boundaries.next()
        while (end != BreakIterator.DONE) {
            add(value.substring(start, end))
            start = end
            end = boundaries.next()
        }
    }
}

internal fun playableScrambleWords(pool: List<SavedWord>): List<SavedWord> {
    val boundaries = BreakIterator.getCharacterInstance(Locale.ROOT)
    return pool.filter { scrambleLetters(it.title, boundaries).size > 2 }
}

internal fun scramble(value: String, random: Random = Random.Default): String {
    val letters = scrambleLetters(value)
    if (letters.size < 2) return value
    var shuffled = letters.shuffled(random)
    if (shuffled == letters) shuffled = letters.drop(1) + letters.first()
    return shuffled.joinToString("")
}
