package app.smallthingz.dict

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LearnAnswerTest {
    @Test fun canonicalSpellingsMatchWithoutDroppingAccentsOrChangingComparisonPolicy() {
        assertTrue(scrambleAnswerMatches("cafe\u0301", "caf\u00e9"))
        assertTrue(scrambleAnswerMatches("caf\u00e9", "cafe\u0301"))
        assertTrue(scrambleAnswerMatches("  CAFE\u0301\t", "caf\u00e9"))
        assertTrue(scrambleAnswerMatches("a\u0315\u0300bc", "\u00e0\u0315bc"))
        assertFalse(scrambleAnswerMatches("cafe", "caf\u00e9"))
        assertFalse(scrambleAnswerMatches("caf\u00e8", "caf\u00e9"))
        assertFalse(scrambleAnswerMatches("caf\u00e9", " caf\u00e9"))
        assertFalse(scrambleAnswerMatches("ff", "\ufb00"))
    }
}
