package uk.co.maybeitsadam.priority.settings

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.time.Instant
import java.time.OffsetDateTime
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.appContainer
import uk.co.maybeitsadam.priority.core.SyncCredentials
import uk.co.maybeitsadam.priority.data.sync.OkHttpSyncTransport
import uk.co.maybeitsadam.priority.data.sync.SyncEngine
import uk.co.maybeitsadam.priority.data.sync.SyncLocalState
import uk.co.maybeitsadam.priority.data.sync.SyncScheduler
import uk.co.maybeitsadam.priority.data.sync.SyncStore

/** Sync as Settings shows it. Port of `SyncSession.Phase`. */
sealed interface SyncUiState {
    data object Unpaired : SyncUiState
    data class Idle(val lastSyncedAt: Instant?) : SyncUiState
    data object Syncing : SyncUiState
    data class Failed(val message: String) : SyncUiState
}

/** A one-time code this device minted for another to join with. */
data class PairingInvite(val link: SyncPairingLink, val expiresAt: Instant?)

/**
 * Sync for the app: credentials (sealed with a Keystore key), pairing, the
 * rhythm — a long-poll while the app is in front, a cycle two seconds after a
 * local write, and a 15-minute WorkManager job in the background — and the
 * status Settings draws. Port of `SyncSession.swift`.
 *
 * The repository's flows re-query when a pull writes, so nothing here has to
 * tell the screens to reload.
 */
class SyncController(private val container: AppContainer) {
    private class Active(val credentials: SyncCredentials, val engine: SyncEngine, val scheduler: SyncScheduler, val scope: CoroutineScope)

    private val credentialStore by lazy { SyncCredentialStore(container.context) }
    private val lock = Mutex()
    private val ready = CompletableDeferred<Unit>()
    private val active = MutableStateFlow<Active?>(null)

    @Volatile private var inForeground = false

    private val _credentials = MutableStateFlow<SyncCredentials?>(null)
    val credentials: StateFlow<SyncCredentials?> = _credentials.asStateFlow()

    private val _isPairing = MutableStateFlow(false)
    val isPairing: StateFlow<Boolean> = _isPairing.asStateFlow()

    private val _pairingError = MutableStateFlow<String?>(null)
    val pairingError: StateFlow<String?> = _pairingError.asStateFlow()

    private val _invite = MutableStateFlow<PairingInvite?>(null)
    val invite: StateFlow<PairingInvite?> = _invite.asStateFlow()

    private val storedState = container.withSession { SyncStore(it.repository.database).observeSyncState() }
        .onStart { emit(null) }

    /** Unpaired, idle (with when it last synced), syncing, or failed. */
    val status: StateFlow<SyncUiState> = combine(
        _credentials,
        active.flatMapLatest { it?.engine?.status ?: flowOf(null) },
        storedState,
    ) { credentials, engine, stored -> describe(credentials, engine, stored) }
        .stateIn(container.scope, SharingStarted.WhileSubscribed(5_000), SyncUiState.Unpaired)

    /** Called once from the container's init, on the main thread. */
    fun attach() {
        runCatching {
            ProcessLifecycleOwner.get().lifecycle.addObserver(
                LifecycleEventObserver { _, event ->
                    when (event) {
                        Lifecycle.Event.ON_START -> {
                            inForeground = true
                            active.value?.scheduler?.start()
                        }
                        Lifecycle.Event.ON_STOP -> {
                            inForeground = false
                            active.value?.scheduler?.stop()
                        }
                        else -> Unit
                    }
                },
            )
        }.onFailure { Log.w(TAG, "No process lifecycle; sync runs only on demand", it) }
        container.scope.launch {
            try {
                val session = container.awaitSession()
                val saved = withContext(Dispatchers.IO) { runCatching { credentialStore.load() }.getOrNull() }
                val state = SyncStore(session.repository.database).syncState()
                if (saved != null && state != null) {
                    lock.withLock { activate(saved) }
                } else if (saved != null) {
                    // The database forgot the pairing (restored, or reset): the token is orphaned.
                    withContext(Dispatchers.IO) { credentialStore.clear() }
                }
            } finally {
                ready.complete(Unit)
            }
        }
    }

    /** One cycle, for the background worker and "Sync now". True when it succeeded, or there was nothing to do. */
    suspend fun syncOnce(): Boolean {
        ready.await()
        val current = active.value ?: return true
        return current.scheduler.syncNow()
    }

    fun syncNow() {
        container.scope.launch {
            if (!syncOnce()) (status.value as? SyncUiState.Failed)?.let { container.undo.say("Couldn't sync: ${it.message}") }
        }
    }

    /** Pairs with a link from a paired device; deep links, scans and pastes all land here. */
    fun pairFromLink(link: String) {
        val parsed = SyncPairingLink.parse(link)
        if (parsed == null) {
            _pairingError.value = NOT_A_LINK
            container.undo.say(NOT_A_LINK)
            return
        }
        container.scope.launch {
            if (pair(parsed)) container.undo.say("Paired with ${hostOf(parsed.serverURL)}")
        }
    }

    suspend fun pair(link: SyncPairingLink): Boolean = pairWith(link.serverURL, code = link.code, adminToken = null)

    /** The first device on a server pairs with its admin token. */
    suspend fun pair(serverURL: String, adminToken: String): Boolean {
        if (!SyncPairingLink.isHttpURL(serverURL.trim())) {
            _pairingError.value = "Enter the server's full address, starting with https://."
            return false
        }
        return pairWith(serverURL.trim(), code = null, adminToken = adminToken.trim())
    }

    fun clearPairingError() {
        _pairingError.value = null
    }

    private suspend fun pairWith(serverURL: String, code: String?, adminToken: String?): Boolean {
        _isPairing.value = true
        _pairingError.value = null
        return try {
            val credentials = OkHttpSyncTransport.pair(serverURL, deviceName(container.context), "android", code = code, adminToken = adminToken)
            lock.withLock {
                deactivate()
                SyncStore(container.repository().database).beginSync(credentials.deviceId, credentials.serverURL)
                withContext(Dispatchers.IO) { credentialStore.save(credentials) }
                activate(credentials)
            }
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            val message = error.message ?: "Couldn't pair."
            _pairingError.value = message
            container.undo.report(error)
            false
        } finally {
            _isPairing.value = false
        }
    }

    /** Mints a one-time code another device can join with. */
    suspend fun makePairingLink(): Result<PairingInvite> {
        val credentials = _credentials.value ?: return Result.failure(IllegalStateException("This device is not paired."))
        return try {
            val code = OkHttpSyncTransport(credentials).createPairingCode()
            val invite = PairingInvite(SyncPairingLink(credentials.serverURL, code.code), parseExpiry(code.expiresAt))
            _invite.value = invite
            Result.success(invite)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    /** Leaves the account. The workspace stays as it is on this device. */
    fun unpair() {
        container.scope.launch {
            lock.withLock {
                deactivate()
                SyncStore(container.repository().database).endSync()
                withContext(Dispatchers.IO) { credentialStore.clear() }
                _invite.value = null
                _pairingError.value = null
                WorkManager.getInstance(container.context).cancelUniqueWork(WORK_NAME)
            }
            container.undo.say("Unpaired. Your tasks stay on this device.")
        }
    }

    private suspend fun activate(credentials: SyncCredentials) {
        val database = container.repository().database
        val store = SyncStore(database)
        val scope = CoroutineScope(SupervisorJob(container.scope.coroutineContext[Job]) + Dispatchers.Default)
        val engine = SyncEngine(store, OkHttpSyncTransport(credentials), credentials.deviceId)
        val scheduler = SyncScheduler(engine, scope)
        scheduler.watchLocalWrites(store)
        active.value = Active(credentials, engine, scheduler, scope)
        _credentials.value = credentials
        if (inForeground) scheduler.start() else scope.launch { scheduler.syncNow() }
        schedulePeriodicWork(container.context)
    }

    private fun deactivate() {
        val current = active.value ?: return
        current.scheduler.stop()
        current.scope.cancel()
        active.value = null
        _credentials.value = null
    }

    companion object {
        private const val TAG = "PrioritySync"
        const val WORK_NAME = "priority.sync.periodic"
        const val NOT_A_LINK = "That isn't a Priority pairing link."

        fun describe(credentials: SyncCredentials?, engine: SyncEngine.Status?, stored: SyncLocalState?): SyncUiState = when {
            credentials == null -> SyncUiState.Unpaired
            engine is SyncEngine.Status.Syncing -> SyncUiState.Syncing
            engine is SyncEngine.Status.Failed -> SyncUiState.Failed(engine.message)
            engine is SyncEngine.Status.Synced -> SyncUiState.Idle(engine.at)
            else -> SyncUiState.Idle(stored?.lastSyncedAt)
        }

        fun parseExpiry(text: String): Instant? =
            runCatching { Instant.parse(text) }.getOrNull() ?: runCatching { OffsetDateTime.parse(text).toInstant() }.getOrNull()

        fun hostOf(serverURL: String): String = runCatching { java.net.URI(serverURL).host }.getOrNull() ?: serverURL

        fun deviceName(context: Context): String =
            runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
                ?.takeIf { it.isNotBlank() } ?: Build.MODEL ?: "Android"

        fun schedulePeriodicWork(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}

/** The background cycle: one push-then-pull every 15 minutes or so, on any network. */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result =
        if (applicationContext.appContainer.sync.syncOnce()) Result.success() else Result.retry()
}
