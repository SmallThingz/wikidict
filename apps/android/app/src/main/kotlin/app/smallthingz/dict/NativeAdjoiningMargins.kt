package app.smallthingz.dict

/** A collapsed sum alone loses information needed by a later adjoining margin. */
internal data class NativeMarginStrut(val positive: Float = 0f, val negative: Float = 0f) {
    init { require(positive.isFinite() && positive >= 0f && negative.isFinite() && negative <= 0f) }
    val value: Float get() = positive + negative
    fun join(other: NativeMarginStrut) = NativeMarginStrut(maxOf(positive, other.positive), minOf(negative, other.negative))
    companion object {
        fun of(value: Float): NativeMarginStrut {
            require(value.isFinite())
            return NativeMarginStrut(maxOf(0f, value), minOf(0f, value))
        }
    }
}

/** These are structural adjoining sets, never inferred from a zero measured height. */
internal data class NativeAdjoiningMargins(val beforeSet: NativeMarginStrut, val afterSet: NativeMarginStrut, val through: Boolean,
    val beforeAdjoins: Boolean = true, val afterAdjoins: Boolean = true) {
    constructor(before: Float, after: Float, through: Boolean,
        beforeAdjoins: Boolean = true, afterAdjoins: Boolean = true) :
        this(NativeMarginStrut.of(before), NativeMarginStrut.of(after), through, beforeAdjoins, afterAdjoins)
    val before: Float get() = beforeSet.value
    val after: Float get() = afterSet.value

    companion object {
        fun sequence(boxes: List<NativeAdjoiningMargins>): NativeAdjoiningMargins {
            var before = NativeMarginStrut()
            for (box in boxes) {
                if (!box.beforeAdjoins) break
                before = before.join(box.beforeSet)
                if (!box.through) break
                before = before.join(box.afterSet)
            }
            var after = NativeMarginStrut()
            for (box in boxes.asReversed()) {
                if (!box.afterAdjoins) { after = NativeMarginStrut(); break }
                after = after.join(box.afterSet)
                if (!box.through) break
                after = after.join(box.beforeSet)
            }
            val through = boxes.all { it.through && it.beforeAdjoins && it.afterAdjoins }
            return if (through) NativeAdjoiningMargins(before.join(after), before.join(after), true)
                else NativeAdjoiningMargins(before, after, false)
        }
    }
}

internal data class NativeMarginPlacement(val borderTop: Float, val clearance: Float?)

internal data class NativeMarginCollapse(val before: Boolean, val after: Boolean)

/** A float observes the pending set at its source position. Later adjoining margins do not
 * retroactively move it, or an already placed through-empty owner's descendants. */
internal class NativeMarginCursor(private val collapse: NativeMarginCollapse) {
    private var borderBottom = 0f
    private var pending = NativeMarginStrut()
    private var leading = collapse.before
    private var pendingCannotEscapeBottom = false
    private var opened = false

    val floatTop: Float get() = coordinate(if (leading) 0f else borderBottom + pending.value)
    val adjoiningTop: Boolean get() = leading

    fun preview(margins: NativeAdjoiningMargins, clearBottom: Float? = null,
        resolvedClearance: Boolean = false): NativeMarginPlacement {
        check(!opened)
        require(clearBottom == null || clearBottom.isFinite())
        val hypothetical = coordinate(if (leading) 0f else borderBottom + pending.join(margins.beforeSet).value)
        if (resolvedClearance && clearBottom == null)
            throw UnsupportedFloatLayout("Resolved clearance lost its source float")
        val clearance = clearBottom?.takeIf { resolvedClearance || it > hypothetical }?.let {
            // CSS clearance can be zero or negative: its presence separates the two margins.
            coordinate(it - (borderBottom + pending.value + margins.before))
        }
        if (leading && clearance != null && !resolvedClearance)
            throw UnsupportedFloatLayout("Leading clearance needs parent adjoining-origin resolution")
        return NativeMarginPlacement(if (clearance == null) hypothetical else checkNotNull(clearBottom), clearance)
    }

    fun begin(margins: NativeAdjoiningMargins, clearBottom: Float? = null,
        resolvedClearance: Boolean = false): NativeMarginPlacement =
        preview(margins, clearBottom, resolvedClearance).also { opened = true }

    fun end(placement: NativeMarginPlacement, usedHeight: Float, margins: NativeAdjoiningMargins) {
        check(opened)
        require(usedHeight.isFinite() && usedHeight >= 0f)
        if (margins.through) {
            if (usedHeight != 0f)
                throw UnsupportedFloatLayout("A structurally through-empty box acquired normal-flow height")
            if (placement.clearance != null) {
                // Its own margins still join following siblings. The set starts above
                // the preserved empty border origin and cannot escape the parent bottom.
                borderBottom = coordinate(placement.borderTop - margins.before)
                pending = margins.beforeSet.join(margins.afterSet)
                leading = false
                pendingCannotEscapeBottom = true
            } else pending = pending.join(margins.beforeSet).join(margins.afterSet)
        } else {
            borderBottom = coordinate(placement.borderTop + usedHeight)
            pending = margins.afterSet
            leading = false
            pendingCannotEscapeBottom = false
        }
        opened = false
    }

    fun finish(): Float {
        check(!opened)
        // A sequence still adjoining the parent's top has already escaped there,
        // even when bottom padding prevents escape through the other side.
        return coordinate(borderBottom + if (leading || collapse.after && !pendingCannotEscapeBottom) 0f else pending.value)
    }

    private fun coordinate(value: Float): Float {
        if (!value.isFinite() || kotlin.math.abs(value) > Int.MAX_VALUE / 4f)
            throw UnsupportedFloatLayout("Adjoining margins exceed the native coordinate range")
        return value
    }
}
