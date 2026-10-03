package uk.co.maybeitsadam.priority.data.sync

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import uk.co.maybeitsadam.priority.core.SyncAccountInfo
import uk.co.maybeitsadam.priority.core.SyncChangesResponse
import uk.co.maybeitsadam.priority.core.SyncErrorBody
import uk.co.maybeitsadam.priority.core.SyncPushChange
import uk.co.maybeitsadam.priority.core.SyncPushRequest
import uk.co.maybeitsadam.priority.core.SyncPushResponse
import uk.co.maybeitsadam.priority.core.SyncRegisterDevice

/** The two calls a sync cycle makes. The engine knows nothing else about the server. */
interface SyncTransport {
    suspend fun push(changes: List<SyncPushChange>): SyncPushResponse
    suspend fun changes(since: Long, limit: Int, wait: Int): SyncChangesResponse
}

sealed class SyncException(message: String) : Exception(message) {
    /**
     * The server said no. The message is the server's own `{"error": "..."}`
     * text when it sent one, which is written to be shown to a person.
     */
    class Server(val status: Int, val body: String) : SyncException(describe(status, body))

    /**
     * The account's session is over: Supabase refused to refresh it (signed
     * out elsewhere, or the account deleted), or the server refused even a
     * freshly refreshed token. Retrying cannot help; the user signs in again.
     */
    class Unauthorized : SyncException("Signed out. Sign in again.")

    class NotPaired : SyncException("This device is not signed in to a sync server.")

    companion object {
        /** The `error` field of a server error body, or null when there isn't one. */
        fun serverMessage(body: String): String? =
            runCatching { OkHttpSyncTransport.json.decodeFromString<SyncErrorBody>(body).error }
                .getOrNull()
                ?.trim()
                ?.takeIf { it.isNotEmpty() }

        /** `deleting accounts isn't set up` reads as `Deleting accounts isn't set up.` */
        internal fun describe(status: Int, body: String): String {
            val message = serverMessage(body) ?: return "The sync server answered $status."
            return sentence(message)
        }

        /** Capitalised, and ending in a full stop unless it already ends a sentence. */
        fun sentence(message: String): String {
            val text = message.trim().replaceFirstChar { it.uppercaseChar() }
            return if (text.isEmpty() || text.last() in ".!?") text else "$text."
        }
    }
}

/**
 * HTTPS transport (docs/sync.md "Wire protocol"). Every request carries
 * `Authorization: Bearer <Supabase access token>` and `X-Priority-Device`.
 * The token comes from [tokens] afresh for each request; a 401 refreshes it
 * once and retries. Only a refresh Supabase refuses, or a 401 to the
 * refreshed token, is [SyncException.Unauthorized], which reads as signed out.
 */
class OkHttpSyncTransport(
    val serverURL: String,
    val deviceId: String,
    private val tokens: SyncAccessTokens,
    private val client: OkHttpClient = defaultClient,
) : SyncTransport {

    override suspend fun push(changes: List<SyncPushChange>): SyncPushResponse {
        val body = json.encodeToString(SyncPushRequest(changes))
        return send(endpoint("v1/push")) { post(body.toRequestBody(JSON)) }
    }

    override suspend fun changes(since: Long, limit: Int, wait: Int): SyncChangesResponse {
        val url = endpoint("v1/changes").newBuilder()
            .addQueryParameter("since", since.toString())
            .addQueryParameter("limit", limit.toString())
            .addQueryParameter("wait", wait.coerceIn(0, 25).toString())
            .build()
        return send(url) { get() }
    }

    /** Records this device on the account (`POST /v1/devices`). Sent after every sign-in. */
    suspend fun registerDevice(name: String, platform: String = PLATFORM) {
        val body = json.encodeToString(SyncRegisterDevice(deviceId, name, platform))
        send<JsonObject>(endpoint("v1/devices")) { post(body.toRequestBody(JSON)) }
    }

    /** Who this device is signed in as, and every device on the account (`GET /v1/account`). */
    suspend fun account(): SyncAccountInfo = send(endpoint("v1/account")) { get() }

    /** Takes this device off the account's list (`POST /v1/sign-out`). The device keeps its workspace. */
    suspend fun signOut() {
        send<JsonObject>(endpoint("v1/sign-out")) { post(EMPTY_OBJECT.toRequestBody(JSON)) }
    }

    /** Deletes the account's rows, its devices and the Supabase user (`POST /v1/account/delete`). */
    suspend fun deleteAccount() {
        send<JsonObject>(endpoint("v1/account/delete")) { post(EMPTY_OBJECT.toRequestBody(JSON)) }
    }

    private fun endpoint(path: String): HttpUrl = serverURL.trim().toHttpUrl().newBuilder().addPathSegments(path).build()

    private suspend inline fun <reified T> send(url: HttpUrl, crossinline method: Request.Builder.() -> Request.Builder): T {
        val request = { token: String ->
            Request.Builder().url(url)
                .header("Authorization", "Bearer $token")
                .header(DEVICE_HEADER, deviceId)
                .method()
                .build()
        }
        val token = tokens.current()
        val first = execute(request(token))
        val answer = if (first.status == 401) execute(request(tokens.refresh(rejected = token))) else first
        return when {
            answer.status == 401 -> throw SyncException.Unauthorized()
            answer.status !in 200..299 -> throw SyncException.Server(answer.status, answer.body)
            else -> json.decodeFromString<T>(answer.body)
        }
    }

    private class Answer(val status: Int, val body: String)

    private suspend fun execute(request: Request): Answer = withContext(Dispatchers.IO) {
        client.newCall(request).await().use { Answer(it.code, it.body.string()) }
    }

    companion object {
        const val DEVICE_HEADER = "X-Priority-Device"
        const val PLATFORM = "android"
        private val JSON = "application/json".toMediaType()
        private const val EMPTY_OBJECT = "{}"
        internal val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

        /** Long polls wait up to 25 s on the server, so reads get headroom past that. */
        val defaultClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(40, TimeUnit.SECONDS)
            .build()

        private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { cancel() }
            enqueue(object : Callback {
                override fun onResponse(call: Call, response: Response) {
                    continuation.resumeWith(Result.success(response))
                }

                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWith(Result.failure(e))
                }
            })
        }
    }
}
