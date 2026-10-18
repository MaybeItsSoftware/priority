package uk.co.maybeitsadam.takt.settings

import android.app.PendingIntent
import android.content.Intent
import android.util.Log
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.data.calendar.GoogleCalendarAgendaWindow
import uk.co.maybeitsadam.takt.data.calendar.GoogleCalendarException
import uk.co.maybeitsadam.takt.data.calendar.GoogleCalendarPassOutcome
import uk.co.maybeitsadam.takt.data.calendar.GoogleCalendarRepository
import uniffi.takt_core.CoreException
import uniffi.takt_core.GoogleCalendarAgendaEntry
import uniffi.takt_core.GoogleCalendarInfo
import uniffi.takt_core.GoogleCalendarSettings

/**
 * Google Calendar on this phone (docs/google-calendar.md): the grant, a
 * two-way pass and Today's events on foreground and every [INTERVAL_MILLIS]
 * while the app is open. The deciding is the Rust core's, through
 * [GoogleCalendarRepository]; this holds only the token and the timing.
 *
 * "Connected" is a local flag: the grant is per device and never synced.
 * Background passes ask for a token silently and skip when Google would need
 * to ask the person again.
 */
class GoogleCalendarController(private val container: AppContainer) {
    private val context = container.context.applicationContext
    private val scope = container.scope

    val connected: StateFlow<Boolean> =
        container.settings.string(CONNECTED).map { it == "true" }.stateIn(scope, SharingStarted.Eagerly, false)

    /** The account's choices, from the workspace's synced preferences. */
    val settings: StateFlow<GoogleCalendarSettings?> =
        container.withSession { GoogleCalendarRepository(it.repository).observeSettings() }
            .stateIn(scope, SharingStarted.Eagerly, null)

    private val _calendars = MutableStateFlow<List<GoogleCalendarInfo>>(emptyList())
    val calendars: StateFlow<List<GoogleCalendarInfo>> = _calendars.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)

    /** What went wrong last, worded for the settings section; null once a pass goes through. */
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _needsConsent = MutableStateFlow(false)

    /** Google wants to ask again (the grant was withdrawn): Connect shows again. */
    val needsConsent: StateFlow<Boolean> = _needsConsent.asStateFlow()

    private val window = MutableStateFlow<GoogleCalendarAgendaWindow?>(null)

    /** Today's events and timed tasks, interleaved by the core; empty when not connected. */
    val agenda: StateFlow<List<GoogleCalendarAgendaEntry>> = combine(connected, window, container.session) { on, w, session ->
        Triple(on, w, session)
    }.flatMapLatest { (on, w, session) ->
        if (!on || w == null || session == null) flowOf(emptyList()) else GoogleCalendarRepository(session.repository).observeAgenda(w)
    }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    private var token: String? = null
    private var tokenExpiresAt = 0L
    private val running = Mutex()
    private var job: Job? = null

    private suspend fun repository() = GoogleCalendarRepository(container.repository())

    fun attach() {
        runCatching {
            ProcessLifecycleOwner.get().lifecycle.addObserver(
                LifecycleEventObserver { _, event ->
                    when (event) {
                        Lifecycle.Event.ON_START -> start()
                        Lifecycle.Event.ON_STOP -> stop()
                        else -> Unit
                    }
                },
            )
        }.onFailure { Log.w(TAG, "No process lifecycle; Google Calendar syncs only from settings", it) }
    }

    private fun start() {
        job?.cancel()
        job = scope.launch {
            while (isActive) {
                refreshNow()
                delay(INTERVAL_MILLIS)
            }
        }
    }

    private fun stop() {
        job?.cancel()
        job = null
    }

    /** Runs a pass and reloads Today's events now, e.g. after a settings change. */
    fun refresh() {
        scope.launch { refreshNow() }
    }

    private suspend fun refreshNow() = running.withLock {
        if (container.settings.string(CONNECTED).first() != "true") return@withLock
        attempt {
            val access = accessToken() ?: return@attempt
            val repository = repository()
            if (_calendars.value.isEmpty()) _calendars.value = repository.calendars(access)
            val outcome = repository.pass(access)
            window.value = repository.agendaEvents(access)
            _error.value = (outcome as? GoogleCalendarPassOutcome.Done)?.failures?.firstOrNull()
        }
    }

    /** Loads the account's calendars for the pickers. */
    suspend fun loadCalendars() {
        attempt {
            val access = accessToken() ?: return@attempt
            _calendars.value = repository().calendars(access)
        }
    }

    /**
     * Asks Google for the grant. Null when it was given straight away; otherwise
     * the consent screen to launch, whose answer goes to [finishConsent].
     */
    suspend fun connect(): PendingIntent? {
        _error.value = null
        return try {
            when (val grant = GoogleCalendarAuth.authorize(context)) {
                is GoogleCalendarAuth.Grant.NeedsConsent -> grant.intent
                is GoogleCalendarAuth.Grant.Token -> {
                    connected(grant.accessToken)
                    null
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            _error.value = error.message ?: "Couldn't connect Google Calendar."
            null
        }
    }

    suspend fun finishConsent(data: Intent?) {
        val access = GoogleCalendarAuth.tokenFrom(context, data) ?: return
        connected(access)
    }

    private suspend fun connected(access: String) {
        remember(access)
        _needsConsent.value = false
        container.settings.putString(CONNECTED, "true")
        refresh()
    }

    /** Stops using Google Calendar on this phone. The account's choices stay, for the other devices. */
    suspend fun disconnect() {
        container.settings.putString(CONNECTED, null)
        token?.let { GoogleCalendarAuth.clear(context, it) }
        token = null
        window.value = null
        _calendars.value = emptyList()
        _error.value = null
        _needsConsent.value = false
    }

    suspend fun update(change: (GoogleCalendarSettings) -> GoogleCalendarSettings) {
        attempt {
            val repository = repository()
            repository.setSettings(change(repository.settings()))
        }
        refresh()
    }

    /** A cached token, or a silent new one; null when Google would have to ask the person. */
    private suspend fun accessToken(): String? {
        val cached = token
        if (cached != null && System.currentTimeMillis() < tokenExpiresAt) return cached
        return when (val grant = GoogleCalendarAuth.authorize(context)) {
            is GoogleCalendarAuth.Grant.Token -> grant.accessToken.also(::remember)
            is GoogleCalendarAuth.Grant.NeedsConsent -> {
                _needsConsent.value = true
                _error.value = "Google Calendar needs connecting again."
                null
            }
        }
    }

    private fun remember(access: String) {
        token = access
        tokenExpiresAt = System.currentTimeMillis() + TOKEN_LIFETIME_MILLIS
    }

    private suspend inline fun attempt(block: () -> Unit) {
        try {
            block()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: GoogleCalendarException.Unauthorized) {
            // The token was refused: forget it, and the next pass asks again silently.
            token?.let { GoogleCalendarAuth.clear(context, it) }
            token = null
            _error.value = "Google Calendar refused the sign-in. It will try again."
        } catch (error: GoogleCalendarException) {
            _error.value = error.message
        } catch (error: IOException) {
            Log.w(TAG, "Couldn't reach Google Calendar", error)
            _error.value = "Couldn't reach Google Calendar."
        } catch (error: CoreException) {
            Log.w(TAG, "Google Calendar pass failed", error)
            _error.value = error.message ?: "Google Calendar sync failed."
        } catch (error: Exception) {
            Log.w(TAG, "Google Calendar failed", error)
            _error.value = error.message ?: "Google Calendar sync failed."
        }
    }

    private companion object {
        const val TAG = "GoogleCalendar"
        const val CONNECTED = "googleCalendar.connected"
        const val INTERVAL_MILLIS = 5 * 60_000L

        /** Google's tokens last an hour; this one is renewed well before. */
        const val TOKEN_LIFETIME_MILLIS = 45 * 60_000L
    }
}
