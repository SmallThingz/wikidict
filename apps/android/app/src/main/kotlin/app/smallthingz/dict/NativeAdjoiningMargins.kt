package app.smallthingz.dict

/** These are structural adjoining sets, never inferred from a zero measured height. */
internal data class NativeAdjoiningMargins(val before: Float, val after: Float, val through: Boolean,
    val beforeAdjoins: Boolean = true, val afterAdjoins: Boolean = true) {
    init { require(before.isFinite() && before >= 0f && after.isFinite() && after >= 0f) }

    companion object {
        fun sequence(boxes: List<NativeAdjoiningMargins>): NativeAdjoiningMargins {
            var before = 0f
            for (box in boxes) {
                if (!box.beforeAdjoins) break
                before = maxOf(before, box.before)
                if (!box.through) break
                before = maxOf(before, box.after)
            }
            var after = 0f
            for (box in boxes.asReversed()) {
                if (!box.afterAdjoins) { after = 0f; break }
                after = maxOf(after, box.after)
                if (!box.through) break
                after = maxOf(after, box.before)
            }
            val through = boxes.all { it.through && it.beforeAdjoins && it.afterAdjoins }
            return if (through) NativeAdjoiningMargins(maxOf(before, after), maxOf(before, after), true)
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
    private var pending = 0f
    private var leading = collapse.before
    private var pendingCannotEscapeBottom = false
    private var opened = false

    val floatTop: Float get() = coordinate(if (leading) 0f else borderBottom + pending)
    val adjoiningTop: Boolean get() = leading

    fun preview(margins: NativeAdjoiningMargins, clearBottom: Float? = null,
        resolvedClearance: Boolean = false): NativeMarginPlacement {
        check(!opened)
        require(clearBottom == null || clearBottom.isFinite())
        val hypothetical = coordinate(if (leading) 0f else borderBottom + maxOf(pending, margins.before))
        if (resolvedClearance && clearBottom == null)
            throw UnsupportedFloatLayout("Resolved clearance lost its source float")
        val clearance = clearBottom?.takeIf { resolvedClearance || it > hypothetical }?.let {
            // CSS clearance can be zero or negative: its presence separates the two margins.
            coordinate(it - (borderBottom + pending + margins.before))
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
                pending = maxOf(margins.before, margins.after)
                leading = false
                pendingCannotEscapeBottom = true
            } else pending = maxOf(pending, margins.before, margins.after)
        } else {
            borderBottom = coordinate(placement.borderTop + usedHeight)
            pending = margins.after
            leading = false
            pendingCannotEscapeBottom = false
        }
        opened = false
    }

    fun finish(): Float {
        check(!opened)
        // A sequence still adjoining the parent's top has already escaped there,
        // even when bottom padding prevents escape through the other side.
        return coordinate(borderBottom + if (leading || collapse.after && !pendingCannotEscapeBottom) 0f else pending)
    }

    private fun coordinate(value: Float): Float {
        if (!value.isFinite() || kotlin.math.abs(value) > Int.MAX_VALUE / 4f)
            throw UnsupportedFloatLayout("Adjoining margins exceed the native coordinate range")
        return value
    }
}
