package uk.co.maybeitsadam.takt.data.calendar

import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceRepository
import uniffi.takt_core.GoogleCalendarAgendaEntry
import uniffi.takt_core.GoogleCalendarCall
import uniffi.takt_core.GoogleCalendarEvent
import uniffi.takt_core.GoogleCalendarHttpRequest
import uniffi.takt_core.GoogleCalendarInfo
import uniffi.takt_core.GoogleCalendarPushOutcome
import uniffi.takt_core.GoogleCalendarSettings
import uniffi.takt_core.googleCalendarCalendars
import uniffi.takt_core.googleCalendarEventsPage
import uniffi.takt_core.googleCalendarRequest

/** What came back for one request: its status and body, whatever the status. */
data class GoogleCalendarAnswer(val status: Int, val body: String)

/** Sends a request the Rust core built. The only HTTP Google Calendar needs. */
fun interface GoogleCalendarSender {
    suspend fun send(request: GoogleCalendarHttpRequest): GoogleCalendarAnswer
}

sealed class GoogleCalendarException(message: String) : Exception(message) {
    /** Google refused the access token: the grant was revoked or has lapsed. */
    class Unauthorized : GoogleCalendarException("Google Calendar refused the sign-in. Connect it again.")

    /** Any other answer a read could not go on from. */
    class Http(val status: Int, body: String) : GoogleCalendarException(describe(status, body))

    companion object {
        private val message = Regex("\"message\"\\s*:\\s*\"([^\"]*)\"")

        internal fun describe(status: Int, body: String): String =
            message.find(body)?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
                ?: "Google Calendar answered $status."
    }
}

/** How a two-way pass went. */
sealed interface GoogleCalendarPassOutcome {
    /** Two-way sync is off, or another device holds the lease: nothing was read or written. */
    data object Idle : GoogleCalendarPassOutcome

    data class Done(
        val tasksUpdated: Int,
        val tasksImported: Int,
        val pushed: Int,
        /** Writes Google refused; the next pass tries them again. */
        val failures: List<String>,
    ) : GoogleCalendarPassOutcome
}

/**
 * Google Calendar for Android (docs/google-calendar.md): the transport and the
 * loop round the Rust core, which builds every request, reads every answer,
 * and does all the deciding. The access token comes from the caller, which
 * owns the sign-in; a refused token is [GoogleCalendarException.Unauthorized].
 */
class GoogleCalendarRepository(
    private val workspace: WorkspaceRepository,
    private val sender: GoogleCalendarSender = OkHttpGoogleCalendarSender(),
    private val clock: () -> Instant = { Instant.now() },
) {
    private val database get() = workspace.database
    private val zone get() = workspace.zone
    private fun nowMs(): Long = clock().toEpochMilli()

    // region Settings

    suspend fun settings(): GoogleCalendarSettings = database.coreRead { it.googleCalendarSettings() }

    /** The account's choices, re-read whenever a preference changes (here or by sync). */
    fun observeSettings(): Flow<GoogleCalendarSettings> =
        database.observe(setOf("preferences")) { it.core.googleCalendarSettings() }

    suspend fun setSettings(settings: GoogleCalendarSettings) {
        val now = nowMs()
        database.coreWrite(SETTINGS_TABLES) { it.setGoogleCalendarSettings(settings, now) }
    }

    // endregion

    /** Every calendar the account can see, all pages. */
    suspend fun calendars(accessToken: String): List<GoogleCalendarInfo> {
        val out = mutableListOf<GoogleCalendarInfo>()
        var pageToken: String? = null
        do {
            val body = read(googleCalendarRequest(GoogleCalendarCall.Calendars(pageToken), accessToken))
            val page = googleCalendarCalendars(body)
            out += page.calendars
            pageToken = page.nextPageToken
        } while (pageToken != null)
        return out
    }

    /**
     * One two-way pass: the changed events since the stored sync token (all of
     * them without one), merged by the core, then each write it asks for sent
     * and filed. The new sync token is stored last, so a pass that dies half
     * way is repeated whole.
     */
    suspend fun pass(accessToken: String): GoogleCalendarPassOutcome {
        val pass = database.coreWrite(LEASE_TABLES) { it.googleCalendarBeginPass(nowMs()) }
            ?: return GoogleCalendarPassOutcome.Idle
        val calendarId = pass.calendarId
        var syncToken = pass.syncToken
        var full = syncToken == null
        val events = mutableListOf<GoogleCalendarEvent>()
        var pageToken: String? = null
        var nextSync: String?
        while (true) {
            val request = googleCalendarRequest(GoogleCalendarCall.Changes(calendarId, syncToken, pageToken), accessToken)
            val answer = sender.send(request)
            if (answer.status == 410 && syncToken != null) {
                // The token expired: forget it and list everything again.
                database.coreWrite(TOKEN_TABLES) { it.setGoogleCalendarSyncToken(calendarId, null, nowMs()) }
                syncToken = null
                full = true
                pageToken = null
                events.clear()
                continue
            }
            val body = checked(answer)
            val page = googleCalendarEventsPage(calendarId, body)
            events += page.events
            pageToken = page.nextPageToken
            if (pageToken == null) {
                nextSync = page.nextSyncToken
                break
            }
        }

        val zoneId = zone.id
        val result = workspace.coreWrite {
            it.googleCalendarReconcile(calendarId, events, full, accessToken, nowMs(), zoneId)
        }
        val failures = mutableListOf<String>()
        var pushed = 0
        for (push in result.pushes) {
            var answer = sender.send(push.request)
            val fallback = push.onConflict
            if (answer.status == 409 && fallback != null) answer = sender.send(fallback)
            val outcome = workspace.coreWrite {
                it.googleCalendarRecordPush(push, answer.status.toUShort(), answer.body, nowMs())
            }
            when (outcome) {
                GoogleCalendarPushOutcome.Done -> pushed += 1
                GoogleCalendarPushOutcome.Unauthorized -> throw GoogleCalendarException.Unauthorized()
                is GoogleCalendarPushOutcome.Failed -> failures += outcome.detail
            }
        }
        database.coreWrite(TOKEN_TABLES) { it.setGoogleCalendarSyncToken(calendarId, nextSync, nowMs()) }
        return GoogleCalendarPassOutcome.Done(
            tasksUpdated = result.tasksUpdated.toInt(),
            tasksImported = result.tasksImported.toInt(),
            pushed = pushed,
            failures = failures,
        )
    }

    /**
     * [day]'s schedule: the events in the agenda calendars (and the two-way
     * one), interleaved by the core with the timed tasks. A calendar Google no
     * longer has is left out rather than failing the rest.
     */
    suspend fun agenda(accessToken: String, day: LocalDate = LocalDate.now(zone)): List<GoogleCalendarAgendaEntry> {
        val window = agendaEvents(accessToken, day)
        return database.coreRead { it.googleCalendarAgenda(window.events, window.fromMs, window.toMs) }
    }

    /**
     * [window]'s schedule, merged again whenever a task or a link changes, so
     * a task moved on this phone moves in Today without asking Google again.
     */
    fun observeAgenda(window: GoogleCalendarAgendaWindow): Flow<List<GoogleCalendarAgendaEntry>> =
        database.observe(AGENDA_TABLES) { it.core.googleCalendarAgenda(window.events, window.fromMs, window.toMs) }

    /** [day]'s events in the agenda calendars and the two-way one; Google's half of [agenda]. */
    suspend fun agendaEvents(accessToken: String, day: LocalDate = LocalDate.now(zone)): GoogleCalendarAgendaWindow {
        val settings = settings()
        val calendars = (settings.agendaCalendarIds + listOfNotNull(settings.calendarId)).distinct()
        val from = day.atStartOfDay(zone).toInstant().toEpochMilli()
        val to = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val events = mutableListOf<GoogleCalendarEvent>()
        for (calendarId in calendars) {
            var pageToken: String? = null
            do {
                val request = googleCalendarRequest(GoogleCalendarCall.Window(calendarId, from, to, pageToken), accessToken)
                val answer = sender.send(request)
                if (answer.status == 404 || answer.status == 403) break
                val page = googleCalendarEventsPage(calendarId, checked(answer))
                events += page.events
                pageToken = page.nextPageToken
            } while (pageToken != null)
        }
        return GoogleCalendarAgendaWindow(day, from, to, events)
    }

    private suspend fun read(request: GoogleCalendarHttpRequest): String = checked(sender.send(request))

    private fun checked(answer: GoogleCalendarAnswer): String = when {
        answer.status == 401 -> throw GoogleCalendarException.Unauthorized()
        answer.status !in 200..299 -> throw GoogleCalendarException.Http(answer.status, answer.body)
        else -> answer.body
    }

    private companion object {
        val SETTINGS_TABLES = setOf("preferences", "calendar_event_links", "sync_outbox")
        val LEASE_TABLES = setOf("preferences", "sync_outbox")
        val TOKEN_TABLES = setOf("calendar_sync_tokens")
        val AGENDA_TABLES = setOf("tasks", "task_metadata", "task_lists", "calendar_event_links")
    }
}

/** A day's events from Google, before the core merges them with the timed tasks. */
data class GoogleCalendarAgendaWindow(
    val day: LocalDate,
    val fromMs: Long,
    val toMs: Long,
    val events: List<GoogleCalendarEvent>,
)

/** [GoogleCalendarSender] over OkHttp, the client the sync transport uses. */
class OkHttpGoogleCalendarSender(private val client: OkHttpClient = defaultClient) : GoogleCalendarSender {
    override suspend fun send(request: GoogleCalendarHttpRequest): GoogleCalendarAnswer {
        val contentType = request.headers.firstOrNull { it.name.equals("Content-Type", ignoreCase = true) }?.value
        val body = request.body?.toRequestBody(contentType?.toMediaTypeOrNull())
            ?: if (request.method in BODY_METHODS) ByteArray(0).toRequestBody() else null
        val built = Request.Builder().url(request.url).apply {
            request.headers.forEach { header(it.name, it.value) }
            method(request.method, body)
        }.build()
        return withContext(Dispatchers.IO) {
            client.newCall(built).await().use { GoogleCalendarAnswer(it.code, it.body.string()) }
        }
    }

    companion object {
        private val BODY_METHODS = setOf("POST", "PUT", "PATCH")

        val defaultClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
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
