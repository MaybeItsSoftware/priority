package uk.co.maybeitsadam.takt.data.sync

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import uk.co.maybeitsadam.takt.core.SyncEndpoints
import uniffi.takt_core.syncBodyIsJsonObject
import uniffi.takt_core.syncHealthIsOk

/**
 * Asks both halves of a self-hosted setup whether they are there before the
 * app switches to them: the sync server's `/health`, and the Supabase
 * project's `/auth/v1/settings` with the key, which Supabase's gateway refuses
 * for a wrong one. Port of `SyncEndpointCheck` in `SyncEndpoints.swift`.
 */
class SyncEndpointCheck(private val client: OkHttpClient = defaultClient) {
    /** Throws [SyncEndpointProblem], saying which half failed and how. */
    suspend fun check(endpoints: SyncEndpoints) {
        checkServer(endpoints.serverURL)
        checkSupabase(endpoints.supabaseURL, endpoints.supabaseKey)
    }

    private suspend fun checkServer(server: String) {
        val base = server.toHttpUrlOrNull() ?: throw SyncEndpointProblem("The sync server address isn't a web address.")
        val url = base.newBuilder().addPathSegment("health").build()
        val (status, body) = fetch(Request.Builder().url(url).get().build()) { "Couldn't reach the sync server at ${base.host}: $it" }
        if (status != 200 || !syncHealthIsOk(body)) {
            throw SyncEndpointProblem("${base.host} answered $status to /health, not a Takt sync server's {\"ok\":true}. Check the address.")
        }
    }

    private suspend fun checkSupabase(project: String, key: String) {
        val base = project.toHttpUrlOrNull() ?: throw SyncEndpointProblem("The Supabase URL isn't a web address.")
        val url = base.newBuilder().addPathSegments("auth/v1/settings").build()
        val request = Request.Builder().url(url).header("apikey", key).get().build()
        val (status, body) = fetch(request) { "Couldn't reach the Supabase project at ${base.host}: $it" }
        when (status) {
            200 -> if (!syncBodyIsJsonObject(body)) {
                throw SyncEndpointProblem("${base.host} answered, but not as a Supabase project would. Check the URL.")
            }
            401, 403 -> throw SyncEndpointProblem("Supabase refused that key. Use the project's publishable (or anon) key.")
            else -> throw SyncEndpointProblem("${base.host} answered $status to /auth/v1/settings. Check that the URL is the project's own.")
        }
    }

    private suspend fun fetch(request: Request, unreachable: (String) -> String): Pair<Int, String> = withContext(Dispatchers.IO) {
        try {
            client.newCall(request).execute().use { it.code to it.body.string() }
        } catch (error: IOException) {
            throw SyncEndpointProblem(unreachable(error.message ?: error.javaClass.simpleName))
        }
    }

    companion object {
        val defaultClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .build()
    }
}

/** A self-hosted server or Supabase project that didn't answer as it should, in words to show. */
class SyncEndpointProblem(message: String) : Exception(message)
