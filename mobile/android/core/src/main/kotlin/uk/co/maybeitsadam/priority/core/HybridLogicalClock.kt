package uk.co.maybeitsadam.priority.core

/**
 * A hybrid logical clock: wall time where the devices agree, and a counter to
 * break ties where they do not. Port of Sources/PrioritySync/HybridLogicalClock.swift.
 *
 * Rendered as `"<ms:013d>-<counter:04d>-<deviceId>"`. Every part is fixed
 * width, so string comparison is clock order; the server compares them as
 * strings and never parses them.
 */
data class HybridLogicalClock(
    val milliseconds: Long,
    val counter: Int,
    val deviceId: String,
) : Comparable<HybridLogicalClock> {

    override fun toString(): String = "%013d-%04d-".format(milliseconds, counter) + deviceId

    /** The stamp for a local edit made at [wallMilliseconds]. */
    fun tick(wallMilliseconds: Long): HybridLogicalClock =
        if (wallMilliseconds > milliseconds) {
            HybridLogicalClock(wallMilliseconds, 0, deviceId)
        } else {
            HybridLogicalClock(milliseconds, counter + 1, deviceId)
        }

    /** Moves past a clock received from another device, so the next local edit sorts after it. */
    fun receiving(remote: HybridLogicalClock, wallMilliseconds: Long): HybridLogicalClock {
        val ms = maxOf(milliseconds, remote.milliseconds, wallMilliseconds)
        val next = when {
            ms == milliseconds && ms == remote.milliseconds -> maxOf(counter, remote.counter) + 1
            ms == milliseconds -> counter + 1
            ms == remote.milliseconds -> remote.counter + 1
            else -> 0
        }
        return HybridLogicalClock(ms, next, deviceId)
    }

    override fun compareTo(other: HybridLogicalClock): Int = toString().compareTo(other.toString())

    companion object {
        /** Parses the wire form; nil for anything that is not one. */
        fun parse(string: String): HybridLogicalClock? {
            val parts = string.split("-", limit = 3)
            if (parts.size != 3) return null
            val ms = parts[0].toLongOrNull() ?: return null
            val counter = parts[1].toIntOrNull() ?: return null
            return HybridLogicalClock(ms, counter, parts[2])
        }
    }
}
