package uk.co.maybeitsadam.priority.data.sync

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import uk.co.maybeitsadam.priority.core.SyncCredentials

/**
 * The transport against a scripted server: an interceptor that records each
 * request and answers with the next canned response, so nothing touches the
 * network. Shapes are docs/sync.md "Accounts" and sync-server/src/accounts.rs.
 */
class OkHttpSyncTransportTest {
    private class Recorded(val method: String, val url: String, val authorization: String?, val body: JsonObject?)

    private class ScriptedServer : Interceptor {
        val requests = mutableListOf<Recorded>()
        private val answers = ArrayDeque<Pair<Int, String>>()

        fun answer(status: Int, body: String) = apply { answers.addLast(status to body) }

        val client: OkHttpClient get() = OkHttpClient.Builder().addInterceptor(this).build()

        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            requests += Recorded(request.method, request.url.toString(), request.header("Authorization"), bodyOf(request))
            val (status, body) = answers.removeFirstOrNull() ?: error("no answer scripted for ${request.url}")
            return Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(status)
                .message("scripted")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }

        private fun bodyOf(request: Request): JsonObject? {
            val body = request.body ?: return null
            val buffer = Buffer().also(body::writeTo)
            return Json.parseToJsonElement(buffer.readUtf8()).jsonObject
        }
    }

    private val server = ScriptedServer()
    private val base = "https://sync.example.com"
    private val signedIn = """{"accountId":"acc-1","email":"me@example.com","deviceId":"dev-1","token":"tok-1"}"""

    private fun JsonObject.text(key: String): String? = this[key]?.jsonPrimitive?.content

    private inline fun <reified E : Throwable> expect(block: () -> Unit): E {
        try {
            block()
        } catch (error: Throwable) {
            if (error is E) return error
            throw error
        }
        fail("expected ${E::class.simpleName}")
        error("unreachable")
    }

    @Test
    fun signUpPostsTheAccountAndKeepsTheEmailWithTheCredentials(): Unit = runBlocking {
        server.answer(200, signedIn)
        val credentials = OkHttpSyncTransport.signUp(" $base ", " me@example.com ", "hunter22", "Pixel", client = server.client)

        assertEquals(SyncCredentials(base, "dev-1", "tok-1", "me@example.com", "acc-1"), credentials)
        val request = server.requests.single()
        assertEquals("POST", request.method)
        assertEquals("$base/v1/accounts", request.url)
        assertNull("signing up sends no bearer", request.authorization)
        assertEquals("me@example.com", request.body!!.text("email"))
        assertEquals("hunter22", request.body.text("password"))
        assertEquals("Pixel", request.body.text("deviceName"))
        assertEquals("android", request.body.text("platform"))
    }

    @Test
    fun signInUsesSessions(): Unit = runBlocking {
        server.answer(200, signedIn)
        OkHttpSyncTransport.signIn(base, "me@example.com", "hunter22", "Pixel", client = server.client)
        assertEquals("$base/v1/sessions", server.requests.single().url)
    }

    @Test
    fun aWrongPasswordIsTheServersMessageNotASignOut(): Unit = runBlocking {
        server.answer(401, """{"error":"wrong email or password"}""")
        val error = expect<SyncException.Server> {
            runBlocking { OkHttpSyncTransport.signIn(base, "me@example.com", "nope", "Pixel", client = server.client) }
        }
        assertEquals(401, error.status)
        assertEquals("Wrong email or password.", error.message)
    }

    @Test
    fun takenEmailsBadFieldsAndLockoutsSayWhatTheServerSaid(): Unit = runBlocking {
        server.answer(409, """{"error":"an account with that email already exists"}""")
            .answer(400, """{"error":"the password needs at least 8 characters"}""")
            .answer(429, """{"error":"too many wrong passwords; try again in 15 minutes"}""")
            .answer(502, "<html>bad gateway</html>")
        val messages = List(4) {
            expect<SyncException.Server> {
                runBlocking { OkHttpSyncTransport.signUp(base, "me@example.com", "short", "Pixel", client = server.client) }
            }
        }
        assertEquals(listOf(409, 400, 429, 502), messages.map { it.status })
        assertEquals("An account with that email already exists.", messages[0].message)
        assertEquals("The password needs at least 8 characters.", messages[1].message)
        assertEquals("Too many wrong passwords; try again in 15 minutes.", messages[2].message)
        assertEquals("The sync server answered 502.", messages[3].message)
    }

    @Test
    fun pairingSendsTheCodeAndAnswersAsSigningIn(): Unit = runBlocking {
        server.answer(200, """{"accountId":"acc-1","email":null,"deviceId":"dev-2","token":"tok-2"}""")
        val credentials = OkHttpSyncTransport.pair(base, " ABCD-EFGH ", "Pixel", client = server.client)

        assertEquals(SyncCredentials(base, "dev-2", "tok-2", null, "acc-1"), credentials)
        val request = server.requests.single()
        assertEquals("$base/v1/pair", request.url)
        assertEquals("ABCD-EFGH", request.body!!.text("code"))
        assertFalse("admin-token pairing is gone", "adminToken" in request.body)
    }

    @Test
    fun aBadPairingCodeIsTheServersMessage(): Unit = runBlocking {
        server.answer(403, """{"error":"that pairing code is wrong, used or expired"}""")
        val error = expect<SyncException.Server> {
            runBlocking { OkHttpSyncTransport.pair(base, "ABCD-EFGH", "Pixel", client = server.client) }
        }
        assertEquals("That pairing code is wrong, used or expired.", error.message)
    }

    private fun device() = OkHttpSyncTransport(SyncCredentials(base, "dev-1", "tok-1", "me@example.com", "acc-1"), server.client)

    @Test
    fun readsTheAccountWithItsDevices(): Unit = runBlocking {
        server.answer(
            200,
            """
            {"accountId":"acc-1","email":"me@example.com","devices":[
              {"id":"dev-0","name":"Adam's Mac","platform":"macos","createdAt":"2026-10-01T09:00:00Z","lastSeenAt":"2026-10-03T08:00:00Z","current":false},
              {"id":"dev-1","name":null,"platform":"android","createdAt":"2026-10-02T09:00:00Z","lastSeenAt":null,"current":true}
            ]}
            """.trimIndent(),
        )
        val account = device().account()

        val request = server.requests.single()
        assertEquals("GET", request.method)
        assertEquals("$base/v1/account", request.url)
        assertEquals("Bearer tok-1", request.authorization)
        assertEquals("me@example.com", account.email)
        assertEquals(listOf("dev-0", "dev-1"), account.devices.map { it.id })
        assertEquals("Adam's Mac", account.devices[0].name)
        assertNull(account.devices[1].name)
        assertNull(account.devices[1].lastSeenAt)
        assertTrue(account.devices[1].current)
    }

    @Test
    fun signsOutWithTheBearer(): Unit = runBlocking {
        server.answer(200, """{"ok":true}""")
        device().signOut()
        val request = server.requests.single()
        assertEquals("POST", request.method)
        assertEquals("$base/v1/sign-out", request.url)
        assertEquals("Bearer tok-1", request.authorization)
    }

    @Test
    fun deletesTheAccountWithThePasswordAndAWrongOneIsNotASignOut(): Unit = runBlocking {
        server.answer(200, """{"ok":true}""").answer(401, """{"error":"wrong email or password"}""")
        device().deleteAccount("hunter22")
        val request = server.requests.single()
        assertEquals("$base/v1/account/delete", request.url)
        assertEquals("Bearer tok-1", request.authorization)
        assertEquals("hunter22", request.body!!.text("password"))

        val error = expect<SyncException.Server> { runBlocking { device().deleteAccount("nope") } }
        assertEquals("Wrong email or password.", error.message)
    }

    @Test
    fun mintsAPairingCode(): Unit = runBlocking {
        server.answer(200, """{"code":"ABCD-EFGH","expiresAt":"2026-10-03T10:10:00Z"}""")
        val code = device().createPairingCode()
        assertEquals("ABCD-EFGH", code.code)
        assertEquals("$base/v1/pairing-codes", server.requests.single().url)
        assertEquals("Bearer tok-1", server.requests.single().authorization)
    }

    @Test
    fun aRevokedTokenOnPushOrChangesIsASignOut(): Unit = runBlocking {
        server.answer(401, """{"error":"missing or unknown bearer token"}""")
            .answer(401, """{"error":"missing or unknown bearer token"}""")
            .answer(401, """{"error":"missing or unknown bearer token"}""")
        expect<SyncException.Unauthorized> { runBlocking { device().push(emptyList()) } }
        expect<SyncException.Unauthorized> { runBlocking { device().changes(0, 100, 0) } }
        expect<SyncException.Unauthorized> { runBlocking { device().account() } }
        assertEquals("$base/v1/changes?since=0&limit=100&wait=0", server.requests[1].url)
    }
}
