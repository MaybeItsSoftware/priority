package uk.co.maybeitsadam.takt.core

/**
 * A hybrid logical clock: wall time where the devices agree, and a counter to
 * break ties where they do not. Its rules are the sync server's (`takt-sync-rules`),
 * reached through the Rust core, as on the Mac and iPhone.
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

    /** The stamp for a local edit made at [wallMilliseconds]: the Rust core's `hlc_tick`, the server's own clock. */
    fun tick(wallMilliseconds: Long): HybridLogicalClock =
        uniffi.takt_core.hlcTick(toString(), deviceId, wallMilliseconds)?.let(::parse)
            ?: error("A clock's own text is always a stamp: $this")

    /** Moves past a clock received from another device, so the next local edit sorts after it: `hlc_receive`. */
    fun receiving(remote: HybridLogicalClock, wallMilliseconds: Long): HybridLogicalClock =
        uniffi.takt_core.hlcReceive(toString(), remote.toString(), wallMilliseconds)?.let(::parse)
            ?: error("A clock's own text is always a stamp: $this")

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
