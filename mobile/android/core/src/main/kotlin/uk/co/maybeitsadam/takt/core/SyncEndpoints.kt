package uk.co.maybeitsadam.takt.core

import java.net.URI
import kotlinx.serialization.Serializable

/**
 * Where a device syncs: the sync server, and the Supabase project whose
 * accounts that server trusts. Takt's own unless "Use a different server"
 * names a self-hosted pair (docs/self-hosting.md). Port of `SyncEndpoints.swift`.
 *
 * The three travel together because they only work together: the server
 * checks every access token against one Supabase project, so a session from
 * another project gets a token it refuses.
 */
@Serializable
data class SyncEndpoints(
    val serverURL: String,
    val supabaseURL: String,
    /** The project's publishable key (`sb_publishable_…`) or legacy anon key, made to ship in apps. */
    val supabaseKey: String,
) {
    /** Accounts are [hosted]'s project, whatever server holds the rows. */
    fun usesAccountsOf(hosted: SyncEndpoints): Boolean = supabaseURL == hosted.supabaseURL && supabaseKey == hosted.supabaseKey

    companion object {
        /**
         * The endpoints as typed under "Use a different server". A blank
         * server is [hosted]'s; a blank Supabase URL *and* key are [hosted]'s
         * project. Throws [InvalidSyncEndpoints], with something to show, for
         * anything else that can't be used.
         */
        fun resolve(server: String, supabaseURL: String, supabaseKey: String, hosted: SyncEndpoints): SyncEndpoints {
            val typedServer = server.trim()
            val project = supabaseURL.trim()
            val key = supabaseKey.trim()

            var endpoints = hosted
            if (typedServer.isNotEmpty()) {
                val url = httpURL(typedServer) ?: throw InvalidSyncEndpoints("The sync server address isn't a web address.")
                endpoints = endpoints.copy(serverURL = url)
            }
            when {
                project.isEmpty() && key.isEmpty() -> Unit
                key.isEmpty() -> throw InvalidSyncEndpoints("Enter the Supabase project's publishable key as well as its URL.")
                project.isEmpty() -> throw InvalidSyncEndpoints("Enter the Supabase project's URL as well as its key.")
                else -> {
                    val url = httpURL(project, droppingSuffixes = listOf("/auth/v1", "/rest/v1"))
                        ?: throw InvalidSyncEndpoints("The Supabase URL isn't a web address.")
                    endpoints = endpoints.copy(supabaseURL = url, supabaseKey = checkedKey(key))
                }
            }
            return endpoints
        }

        /**
         * [typed] as an http(s) address: `https://` added when it has no
         * scheme, and without a query, fragment, trailing slash or any of
         * [droppingSuffixes] (a Supabase URL copied from an API example often
         * ends `/rest/v1`). Null when it still isn't one with a host.
         */
        fun httpURL(typed: String, droppingSuffixes: List<String> = emptyList()): String? {
            val trimmed = typed.trim()
            if (trimmed.isEmpty()) return null
            val withScheme = if ("://" in trimmed) trimmed else "https://$trimmed"
            val uri = runCatching { URI(withScheme) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase() ?: return null
            if (scheme != "http" && scheme != "https") return null
            val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
            var path = uri.rawPath.orEmpty()
            var trimming = true
            while (trimming) {
                trimming = false
                path = path.trimEnd('/')
                droppingSuffixes.firstOrNull { path.lowercase().endsWith(it) }?.let {
                    path = path.dropLast(it.length)
                    trimming = true
                }
            }
            // A user and password in the address is never what was meant.
            if (uri.rawUserInfo != null) return null
            val port = if (uri.port >= 0) ":${uri.port}" else ""
            return "$scheme://$host$port$path"
        }

        private fun checkedKey(key: String): String {
            if (key.any(Char::isWhitespace)) throw InvalidSyncEndpoints("The Supabase key has a space in it. Paste it again.")
            // The secret key bypasses row-level security: it belongs on the server, never in an app.
            if (key.startsWith("sb_secret_")) {
                throw InvalidSyncEndpoints("That's the project's secret key. Use the publishable key here; the secret one is for the server.")
            }
            return key
        }
    }
}

/** Typed endpoints that can't be used, with the reason in words to show. */
class InvalidSyncEndpoints(message: String) : IllegalArgumentException(message)
