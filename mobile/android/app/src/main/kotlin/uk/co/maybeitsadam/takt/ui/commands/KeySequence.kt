package uk.co.maybeitsadam.takt.ui.commands

/**
 * Two-key commands on a hardware keyboard, after the Mac's
 * `DesktopShortcutSequence`: a key that could begin one is held for
 * [TIMEOUT_MS] to see whether the second key follows.
 *
 * A held key is never lost. It runs on its own at once when the next key
 * turns out not to complete a sequence, or when the hold times out with no
 * next key. The timer is the caller's, which is why [expire] exists.
 *
 * Android types only the catalogue's `-1`–`-4` (the priorities behind none):
 * `-` alone is priority −1 and the start of each, so it waits. It used to
 * set −1 at once and read the digit after it as a priority of its own, so
 * `-3` made a task urgent.
 */
class KeySequence(private val sequences: Set<String>) {
    sealed interface Result {
        /** Not part of a sequence: dispatch the key as it is. */
        data object Pass : Result

        /** Held, waiting for a second key. The caller arranges to call [expire] after [TIMEOUT_MS]. */
        data object Pending : Result

        /** Two keys made a sequence. */
        data class Command(val sequence: String) : Result

        /** The held key did not start a sequence with this one: run it on its own, then dispatch this key. */
        data class Flush(val held: String) : Result

        /** As [Flush], except this key could itself begin a sequence, so it is now the one held. */
        data class FlushAndHold(val held: String) : Result
    }

    var prefix: String = ""
        private set
    private var heldAt = 0L

    /** Drops a held key without running it. */
    fun reset() {
        prefix = ""
    }

    /** Releases the held key, if any, for the caller to run on its own. */
    fun flush(): String? {
        if (prefix.isEmpty()) return null
        return prefix.also { reset() }
    }

    /**
     * The timer's half of [flush]. Only releases the hold that started at
     * [time]: a timer armed for an earlier hold must not cut a later one short.
     */
    fun expire(time: Long): String? {
        if (prefix.isEmpty() || heldAt != time) return null
        return flush()
    }

    /**
     * [key] is a single unmodified key as the catalogue spells it (`-`, `3`),
     * or empty for any other key press, which can only end a hold. [time] is
     * in milliseconds.
     */
    fun advance(key: String, time: Long): Result {
        var held: String? = null
        if (prefix.isNotEmpty()) {
            val candidate = prefix + key
            if (key.isNotEmpty() && time - heldAt <= TIMEOUT_MS && candidate in sequences) {
                reset()
                return Result.Command(candidate)
            }
            held = flush()
        }
        if (key.length == 1 && sequences.any { it.startsWith(key) }) {
            prefix = key
            heldAt = time
            return held?.let { Result.FlushAndHold(it) } ?: Result.Pending
        }
        return held?.let { Result.Flush(it) } ?: Result.Pass
    }

    companion object {
        /** The Mac's: long enough to type two keys deliberately, short enough that a lone key does not feel ignored. */
        const val TIMEOUT_MS = 1_200L
    }
}
