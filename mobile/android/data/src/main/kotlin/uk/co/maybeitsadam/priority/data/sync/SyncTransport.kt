package uk.co.maybeitsadam.priority.data.sync

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import uk.co.maybeitsadam.priority.core.SyncChangesResponse
import uk.co.maybeitsadam.priority.core.SyncCredentials
import uk.co.maybeitsadam.priority.core.SyncPairRequest
import uk.co.maybeitsadam.priority.core.SyncPairing
import uk.co.maybeitsadam.priority.core.SyncPairingCode
import uk.co.maybeitsadam.priority.core.SyncPushChange
import uk.co.maybeitsadam.priority.core.SyncPushRequest
import uk.co.maybeitsadam.priority.core.SyncPushResponse

/** The two calls a sync cycle makes. The engine knows nothing else about the server. */
interface SyncTransport {
    suspend fun push(changes: List<SyncPushChange>): SyncPushResponse
    suspend fun changes(since: Long, limit: Int, wait: Int): SyncChangesResponse
}

sealed class SyncException(message: String) : Exception(message) {
    class Server(val status: Int, val body: String) : SyncException("The sync server answered $status: $body")
    class Unauthorized : SyncException("The sync server no longer recognises this device. Pair it again.")
    class NotPaired : SyncException("This device is not paired with a sync server.")
}

/** HTTPS transport (docs/sync.md "Wire protocol"), with a bearer device token. */
class OkHttpSyncTransport(
    val credentials: SyncCredentials,
    private val client: OkHttpClient = defaultClient,
) : SyncTransport {

    override suspend fun push(changes: List<SyncPushChange>): SyncPushResponse =
        send(authorized("v1/push").post(json.encodeToString(SyncPushRequest(changes)).toRequestBody(JSON)).build())

    override suspend fun changes(since: Long, limit: Int, wait: Int): SyncChangesResponse {
        val url = endpoint(credentials.serverURL, "v1/changes").newBuilder()
            .addQueryParameter("since", since.toString())
            .addQueryParameter("limit", limit.toString())
            .addQueryParameter("wait", wait.coerceIn(0, 25).toString())
            .build()
        return send(authorized(url).get().build())
    }

    /** A one-time code another device can pair with (docs/sync.md `POST /v1/pairing-codes`). */
    suspend fun createPairingCode(): SyncPairingCode =
        send(authorized("v1/pairing-codes").post("{}".toRequestBody(JSON)).build())

    private fun authorized(path: String): Request.Builder = authorized(endpoint(credentials.serverURL, path))

    private fun authorized(url: HttpUrl): Request.Builder =
        Request.Builder().url(url).header("Authorization", "Bearer ${credentials.token}")

    private suspend inline fun <reified T> send(request: Request): T = Companion.send(client, request)

    companion object {
        private val JSON = "application/json".toMediaType()
        internal val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

        /** Long polls wait up to 25 s on the server, so reads get headroom past that. */
        val defaultClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(40, TimeUnit.SECONDS)
            .build()

        /**
         * Pairs this device: with a code from an already-paired device, or (for
         * the first device) with the server's admin token.
         */
        suspend fun pair(
            serverURL: String,
            deviceName: String,
            platform: String = "android",
            code: String? = null,
            adminToken: String? = null,
            client: OkHttpClient = defaultClient,
        ): SyncCredentials {
            val body = json.encodeToString(SyncPairRequest(deviceName, platform, code, adminToken))
            val request = Request.Builder().url(endpoint(serverURL, "v1/pair")).post(body.toRequestBody(JSON)).build()
            val pairing: SyncPairing = send(client, request)
            return SyncCredentials(serverURL, pairing.deviceId, pairing.token)
        }

        private fun endpoint(base: String, path: String): HttpUrl =
            base.toHttpUrl().newBuilder().addPathSegments(path).build()

        private suspend inline fun <reified T> send(client: OkHttpClient, request: Request): T =
            withContext(Dispatchers.IO) {
                val response = client.newCall(request).await()
                response.use {
                    val text = it.body.string()
                    when {
                        it.code == 401 -> throw SyncException.Unauthorized()
                        !it.isSuccessful -> throw SyncException.Server(it.code, text)
                        else -> json.decodeFromString<T>(text)
                    }
                }
            }

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
