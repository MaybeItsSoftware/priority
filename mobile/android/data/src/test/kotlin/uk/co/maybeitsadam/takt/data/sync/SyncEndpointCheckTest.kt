package uk.co.maybeitsadam.takt.data.sync

import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.SyncEndpoints

/** Checking a self-hosted pair before switching to it, against canned answers keyed by path. */
class SyncEndpointCheckTest {
    private val own = SyncEndpoints("https://sync.example.com", "https://abc.supabase.co", "sb_publishable_own")

    private class Answers(vararg answers: Pair<String, Pair<Int, String>>) : Interceptor {
        private val byPath = answers.toMap()
        val asked = mutableListOf<String>()
        val keys = mutableListOf<String?>()

        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            asked += request.url.host + request.url.encodedPath
            keys += request.header("apikey")
            val (status, body) = byPath[request.url.encodedPath] ?: throw IOException("connection refused")
            return Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(status)
                .message("canned")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }
    }

    private fun check(answers: Answers) = runBlocking {
        SyncEndpointCheck(OkHttpClient.Builder().addInterceptor(answers).build()).check(own)
    }

    private fun failure(answers: Answers): String {
        try {
            check(answers)
        } catch (problem: SyncEndpointProblem) {
            return problem.message.orEmpty()
        }
        error("the check passed")
    }

    private val healthy = "/health" to (200 to """{"ok":true}""")
    private val project = "/auth/v1/settings" to (200 to """{"external":{"email":true}}""")

    @Test
    fun asksBothHalves() {
        val answers = Answers(healthy, project)
        check(answers)
        assertEquals(listOf("sync.example.com/health", "abc.supabase.co/auth/v1/settings"), answers.asked)
        assertEquals("sb_publishable_own", answers.keys.last())
    }

    @Test
    fun saysWhichHalfFailed() {
        assertTrue(failure(Answers(project)).contains("Couldn't reach the sync server at sync.example.com"))
        assertTrue(failure(Answers("/health" to (200 to "<html>"), project)).contains("/health"))
        assertTrue(failure(Answers(healthy)).contains("Couldn't reach the Supabase project"))
        assertTrue(failure(Answers(healthy, "/auth/v1/settings" to (401 to "{}"))).contains("refused that key"))
        assertTrue(failure(Answers(healthy, "/auth/v1/settings" to (404 to ""))).contains("404"))
    }
}
