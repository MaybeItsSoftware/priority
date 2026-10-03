package uk.co.maybeitsadam.priority.settings

import java.io.ByteArrayOutputStream

/**
 * `priority-sync://pair?server=<url>&code=<code>`: what a paired device shows
 * as a QR code or a link, and what a new device pairs with. Port of
 * `SyncPairingLink` in `Sources/PrioritySync/SyncSession.swift`, which parses
 * through `URLComponents`: the scheme must be exactly `priority-sync`, the host
 * `pair`, the first `server` item an http(s) URL and the first `code` item
 * non-empty. Query values are percent-decoded; `+` stays a plus.
 */
data class SyncPairingLink(val serverURL: String, val code: String) {
    /** The link as Swift's `url` writes it: values percent-encoded as `URLComponents.queryItems` does. */
    val url: String get() = "$SCHEME://$HOST?server=${encode(serverURL)}&code=${encode(code)}"

    override fun toString(): String = url

    companion object {
        const val SCHEME = "priority-sync"
        private const val HOST = "pair"
        private const val HEX = "0123456789ABCDEF"

        /** Null when [string] is not a pairing link this app can use. */
        fun parse(string: String): SyncPairingLink? {
            val text = string.trim()
            val schemeEnd = text.indexOf(':')
            if (schemeEnd <= 0 || text.substring(0, schemeEnd) != SCHEME) return null
            val rest = text.substring(schemeEnd + 1).substringBefore('#')
            if (!rest.startsWith("//")) return null
            val afterSlashes = rest.substring(2)
            val authorityEnd = afterSlashes.indexOfFirst { it == '/' || it == '?' }
            val authority = if (authorityEnd < 0) afterSlashes else afterSlashes.substring(0, authorityEnd)
            val host = authority.substringAfterLast('@').substringBefore(':')
            if (host != HOST) return null
            val query = afterSlashes.substringAfter('?', missingDelimiterValue = "")
            val items = query.split('&').filter { it.isNotEmpty() }.map { item ->
                val name = decode(item.substringBefore('=')) ?: return null
                val value = if ('=' in item) decode(item.substringAfter('=')) ?: return null else null
                name to value
            }
            val server = items.firstOrNull { it.first == "server" }?.second ?: return null
            val code = items.firstOrNull { it.first == "code" }?.second ?: return null
            if (code.isEmpty() || !isHttpURL(server)) return null
            return SyncPairingLink(server, code)
        }

        /**
         * Swift's `URL(string:)` plus `scheme.hasPrefix("http")`. Foundation
         * accepts (and escapes) characters such as spaces, so only the scheme
         * is checked here; the transport reports anything else when it connects.
         */
        fun isHttpURL(server: String): Boolean {
            val scheme = SCHEME_PATTERN.find(server)?.groupValues?.get(1) ?: return false
            return scheme.startsWith("http")
        }

        private val SCHEME_PATTERN = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")

        /** Characters `URLComponents` leaves alone in a query item's value. */
        private fun isAllowed(c: Char): Boolean =
            c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c in "-._~!$'()*+,;:@/?"

        internal fun encode(value: String): String {
            val out = StringBuilder()
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val c = (byte.toInt() and 0xFF).toChar()
                if (byte >= 0 && isAllowed(c)) out.append(c) else out.append('%').append(HEX[(byte.toInt() shr 4) and 0xF]).append(HEX[byte.toInt() and 0xF])
            }
            return out.toString()
        }

        /** Percent-decodes; null on a malformed escape or invalid UTF-8. */
        internal fun decode(value: String): String? {
            val bytes = ByteArrayOutputStream()
            var i = 0
            while (i < value.length) {
                val c = value[i]
                if (c == '%') {
                    val hex = value.substring(i + 1, minOf(i + 3, value.length))
                    if (hex.length != 2 || !hex.all { it in "0123456789abcdefABCDEF" }) return null
                    val byte = hex.toInt(16)
                    bytes.write(byte)
                    i += 3
                } else {
                    bytes.write(c.toString().toByteArray(Charsets.UTF_8))
                    i += 1
                }
            }
            val raw = bytes.toByteArray()
            val decoder = Charsets.UTF_8.newDecoder()
            return runCatching { decoder.decode(java.nio.ByteBuffer.wrap(raw)).toString() }.getOrNull()
        }
    }
}
