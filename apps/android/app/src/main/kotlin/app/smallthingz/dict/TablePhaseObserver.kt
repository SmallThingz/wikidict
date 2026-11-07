package app.smallthingz.dict

import androidx.compose.runtime.staticCompositionLocalOf

/** Temporary opt-in diagnostics; no snapshot writes or per-cell event stream. */
internal enum class TablePhase { Preparation, Composition, Measurement, PixelLayout, DrawCache, Draw }
internal fun interface TablePhaseObserver {
    fun record(phase: TablePhase, elapsedNanos: Long, items: Int, completed: Boolean)
}
internal val LocalTablePhaseObserver = staticCompositionLocalOf<TablePhaseObserver?> { null }

internal inline fun <T> observeTablePhase(observer: TablePhaseObserver?, phase: TablePhase,
    items: Int = 0, block: () -> T): T {
    if (observer == null) return block()
    val started = System.nanoTime()
    var completed = false
    try {
        val result = block()
        completed = true
        return result
    } finally {
        observer.record(phase, System.nanoTime() - started, items, completed)
    }
}
