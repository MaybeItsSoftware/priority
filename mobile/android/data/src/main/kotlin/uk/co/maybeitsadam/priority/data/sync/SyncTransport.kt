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
import uk.co.maybeitsadam.priority.core.SyncAccountRequest
import uk.co.maybeitsadam.priority.core.SyncChangesResponse
import uk.co.maybeitsadam.priority.core.SyncCredentials
import uk.co.maybeitsadam.priority.core.SyncDeleteAccountRequest
import uk.co.maybeitsadam.priority.core.SyncErrorBody
import uk.co.maybeitsadam.priority.core.SyncPairRequest
import uk.co.maybeitsadam.priority.core.SyncPairingCode
import uk.co.maybeitsadam.priority.core.SyncPushChange
import uk.co.maybeitsadam.priority.core.SyncPushRequest
import uk.co.maybeitsadam.priority.core.SyncPushResponse
import uk.co.maybeitsadam.priority.core.SyncSignedIn

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

    /** A device route answered 401: the token is gone (signed out, or the account deleted). */
    class Unauthorized : SyncException("Signed out. Sign in again.")

    class NotPaired : SyncException("This device is not signed in to a sync server.")

    companion object {
        /** The `error` field of a server error body, or null when there isn't one. */
        fun serverMessage(body: String): String? =
            runCatching { OkHttpSyncTransport.json.decodeFromString<SyncErrorBody>(body).error }
                .getOrNull()
                ?.trim()
                ?.takeIf { it.isNotEmpty() }

        /** `wrong email or password` reads as `Wrong email or password.` */
        internal fun describe(status: Int, body: String): String {
            val message = serverMessage(body) ?: return "The sync server answered $status."
            val sentence = message.replaceFirstChar { it.uppercaseChar() }
            return if (sentence.last() in ".!?") sentence else "$sentence."
        }
    }
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
        send(authorized("v1/pairing-codes").post(EMPTY_OBJECT.toRequestBody(JSON)).build())

    /** Who this device is signed in as, and every device on the account (`GET /v1/account`). */
    suspend fun account(): SyncAccountInfo = send(authorized("v1/account").get().build())

    /** Forgets this device's token on the server (`POST /v1/sign-out`). The device keeps its workspace. */
    suspend fun signOut() {
        send<JsonObject>(authorized("v1/sign-out").post(EMPTY_OBJECT.toRequestBody(JSON)).build())
    }

    /**
     * Deletes the account, its rows and its devices (`POST /v1/account/delete`).
     * A wrong password is a 401 as well, so here a 401 comes back as the
     * server's message rather than [SyncException.Unauthorized]: mistyping the
     * password must not sign the device out.
     */
    suspend fun deleteAccount(password: String) {
        val body = json.encodeToString(SyncDeleteAccountRequest(password)).toRequestBody(JSON)
        send<JsonObject>(authorized("v1/account/delete").post(body).build(), unauthorizedIsSignedOut = false)
    }

    private fun authorized(path: String): Request.Builder = authorized(endpoint(credentials.serverURL, path))

    private fun authorized(url: HttpUrl): Request.Builder =
        Request.Builder().url(url).header("Authorization", "Bearer ${credentials.token}")

    private suspend inline fun <reified T> send(request: Request, unauthorizedIsSignedOut: Boolean = true): T =
        Companion.send(client, request, unauthorizedIsSignedOut)

    companion object {
        private val JSON = "application/json".toMediaType()
        private const val EMPTY_OBJECT = "{}"
        internal val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

        /** Long polls wait up to 25 s on the server, so reads get headroom past that. */
        val defaultClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(40, TimeUnit.SECONDS)
            .build()

        /** Makes an account and signs this device in to it (`POST /v1/accounts`). */
        suspend fun signUp(
            serverURL: String,
            email: String,
            password: String,
            deviceName: String,
            platform: String = "android",
            client: OkHttpClient = defaultClient,
        ): SyncCredentials = postSignIn(client, serverURL, "v1/accounts", SyncAccountRequest(email.trim(), password, deviceName, platform))

        /** Signs this device in to an account that already exists (`POST /v1/sessions`). */
        suspend fun signIn(
            serverURL: String,
            email: String,
            password: String,
            deviceName: String,
            platform: String = "android",
            client: OkHttpClient = defaultClient,
        ): SyncCredentials = postSignIn(client, serverURL, "v1/sessions", SyncAccountRequest(email.trim(), password, deviceName, platform))

        /** Signs this device in with a one-time code from a device already signed in (`POST /v1/pair`). */
        suspend fun pair(
            serverURL: String,
            code: String,
            deviceName: String,
            platform: String = "android",
            client: OkHttpClient = defaultClient,
        ): SyncCredentials = postSignIn(client, serverURL, "v1/pair", SyncPairRequest(code.trim(), deviceName, platform))

        private suspend inline fun <reified B> postSignIn(client: OkHttpClient, serverURL: String, path: String, body: B): SyncCredentials {
            val server = serverURL.trim()
            val request = Request.Builder().url(endpoint(server, path)).post(json.encodeToString(body).toRequestBody(JSON)).build()
            val signedIn: SyncSignedIn = send(client, request, unauthorizedIsSignedOut = false)
            return SyncCredentials(server, signedIn.deviceId, signedIn.token, signedIn.email, signedIn.accountId)
        }

        private fun endpoint(base: String, path: String): HttpUrl =
            base.toHttpUrl().newBuilder().addPathSegments(path).build()

        /**
         * On a device route a 401 means the token is gone ([unauthorizedIsSignedOut]);
         * on signing in, pairing or deleting it means a wrong password or code,
         * which the caller shows as the server's message instead.
         */
        private suspend inline fun <reified T> send(client: OkHttpClient, request: Request, unauthorizedIsSignedOut: Boolean): T =
            withContext(Dispatchers.IO) {
                val response = client.newCall(request).await()
                response.use {
                    val text = it.body.string()
                    when {
                        it.code == 401 && unauthorizedIsSignedOut -> throw SyncException.Unauthorized()
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
