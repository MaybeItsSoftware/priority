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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uk.co.maybeitsadam.priority.BuildConfig
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.appContainer
import uk.co.maybeitsadam.priority.core.SyncAccountInfo
import uk.co.maybeitsadam.priority.core.SyncCredentials
import uk.co.maybeitsadam.priority.data.sync.OkHttpSyncTransport
import uk.co.maybeitsadam.priority.data.sync.SyncEngine
import uk.co.maybeitsadam.priority.data.sync.SyncException
import uk.co.maybeitsadam.priority.data.sync.SyncLocalState
import uk.co.maybeitsadam.priority.data.sync.SyncScheduler
import uk.co.maybeitsadam.priority.data.sync.SyncStore

/** Sync as Settings shows it. Port of `SyncSession.Phase`. */
sealed interface SyncUiState {
    /** Never signed in, or signed out on purpose. */
    data object Unpaired : SyncUiState

    /** The server forgot this device's token (signed out elsewhere, or the account deleted). */
    data object SessionExpired : SyncUiState
    data class Idle(val lastSyncedAt: Instant?) : SyncUiState
    data object Syncing : SyncUiState
    data class Failed(val message: String) : SyncUiState
}

/** What the signed-out form prefills, and whether the server (not the user) signed the device out. */
data class SignedOutHint(val email: String?, val serverURL: String?, val expired: Boolean)

/** A one-time code this device minted for another to join with. */
data class PairingInvite(val link: SyncPairingLink, val expiresAt: Instant?)

/**
 * Sync for the app: the account session (credentials sealed with a Keystore
 * key), signing in, pairing, the rhythm — a long-poll while the app is in
 * front, a cycle two seconds after a local write, and a 15-minute WorkManager
 * job in the background — and the status Settings draws. Port of
 * `SyncSession.swift`.
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

    private val _isSigningIn = MutableStateFlow(false)
    val isSigningIn: StateFlow<Boolean> = _isSigningIn.asStateFlow()

    private val _signInError = MutableStateFlow<String?>(null)
    val signInError: StateFlow<String?> = _signInError.asStateFlow()

    private val _isRequestingReset = MutableStateFlow(false)
    val isRequestingReset: StateFlow<Boolean> = _isRequestingReset.asStateFlow()

    private val _passwordResetNotice = MutableStateFlow<String?>(null)

    /** Set once the server has taken a password-reset request; cleared by any edit to the form. */
    val passwordResetNotice: StateFlow<String?> = _passwordResetNotice.asStateFlow()

    private val _signedOut = MutableStateFlow<SignedOutHint?>(null)

    /** Set while signed out: the last email and server, and whether the server signed the device out. */
    val signedOut: StateFlow<SignedOutHint?> = _signedOut.asStateFlow()

    private val _account = MutableStateFlow<SyncAccountInfo?>(null)

    /** The account and its devices, as last fetched. Null until [refreshAccount] succeeds. */
    val account: StateFlow<SyncAccountInfo?> = _account.asStateFlow()

    private val _invite = MutableStateFlow<PairingInvite?>(null)
    val invite: StateFlow<PairingInvite?> = _invite.asStateFlow()

    private val storedState = container.withSession { SyncStore(it.repository.database).observeSyncState() }
        .onStart { emit(null) }

    /** Signed out, session expired, idle (with when it last synced), syncing, or failed. */
    val status: StateFlow<SyncUiState> = combine(
        _credentials,
        active.flatMapLatest { it?.engine?.status ?: flowOf(null) },
        storedState,
        _signedOut,
    ) { credentials, engine, stored, hint -> describe(credentials, engine, stored, hint?.expired == true) }
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
                } else {
                    if (saved != null) {
                        // The database forgot the session (restored, or reset): the token is orphaned.
                        withContext(Dispatchers.IO) { credentialStore.clear() }
                    }
                    _signedOut.value = withContext(Dispatchers.IO) { runCatching { credentialStore.loadSignedOut() }.getOrNull() }
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

    /** Signs in to an existing account (`POST /v1/sessions`). */
    suspend fun signIn(serverURL: String, email: String, password: String): Boolean =
        checkedServer(serverURL, email, password)?.let { server ->
            signInWith { OkHttpSyncTransport.signIn(server, email, password, deviceName(container.context)) }
        } ?: false

    /** Makes an account and signs in to it (`POST /v1/accounts`). */
    suspend fun signUp(serverURL: String, email: String, password: String): Boolean =
        checkedServer(serverURL, email, password)?.let { server ->
            signInWith { OkHttpSyncTransport.signUp(server, email, password, deviceName(container.context)) }
        } ?: false

    private fun checkedServer(serverURL: String, email: String, password: String): String? {
        val server = serverURL.trim().ifEmpty { BuildConfig.SYNC_SERVER }
        _signInError.value = when {
            !SyncPairingLink.isHttpURL(server) -> "Enter the server's full address, starting with https://."
            email.isBlank() -> "Enter your email."
            password.isEmpty() -> "Enter your password."
            else -> return server
        }
        return null
    }

    /**
     * Asks the server to email a link to its own page where a new password is
     * set (`POST /v1/password-reset`); nothing more happens in the app. The
     * server answers the same whether or not the account exists, so the notice
     * says "if". Errors land in [signInError].
     */
    suspend fun requestPasswordReset(serverURL: String, email: String): Boolean {
        val server = serverURL.trim().ifEmpty { BuildConfig.SYNC_SERVER }
        val address = email.trim()
        _passwordResetNotice.value = null
        _signInError.value = when {
            address.isEmpty() -> "Enter your email first."
            !SyncPairingLink.isHttpURL(server) -> "Enter the server's full address, starting with https://."
            else -> null
        }
        if (_signInError.value != null) return false
        _isRequestingReset.value = true
        return try {
            OkHttpSyncTransport.requestPasswordReset(server, address)
            _passwordResetNotice.value = passwordResetNotice(address)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            _signInError.value = message(error, "Couldn't send a reset link.")
            false
        } finally {
            _isRequestingReset.value = false
        }
    }

    /** Signs in with a link from a device already signed in; deep links, scans and pastes all land here. */
    fun pairFromLink(link: String) {
        val parsed = SyncPairingLink.parse(link)
        if (parsed == null) {
            _signInError.value = NOT_A_LINK
            container.undo.say(NOT_A_LINK)
            return
        }
        container.scope.launch {
            if (pair(parsed)) {
                container.undo.say("Signed in through ${hostOf(parsed.serverURL)}")
            } else {
                _signInError.value?.let { container.undo.say("Couldn't pair: $it") }
            }
        }
    }

    suspend fun pair(link: SyncPairingLink): Boolean =
        signInWith { OkHttpSyncTransport.pair(link.serverURL, link.code, deviceName(container.context)) }

    fun clearSignInError() {
        _signInError.value = null
        _passwordResetNotice.value = null
    }

    private suspend fun signInWith(request: suspend () -> SyncCredentials): Boolean {
        _isSigningIn.value = true
        _signInError.value = null
        _passwordResetNotice.value = null
        return try {
            val credentials = request()
            lock.withLock {
                deactivate()
                SyncStore(container.repository().database).beginSync(credentials.deviceId, credentials.serverURL)
                withContext(Dispatchers.IO) {
                    credentialStore.save(credentials)
                    credentialStore.clearSignedOut()
                }
                _signedOut.value = null
                activate(credentials)
            }
            container.scope.launch { refreshAccount() }
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            _signInError.value = message(error, "Couldn't sign in.")
            false
        } finally {
            _isSigningIn.value = false
        }
    }

    /** Fetches the account and its devices. Returns the error to show, or null. */
    suspend fun refreshAccount(): String? {
        val current = active.value ?: return null
        return try {
            _account.value = OkHttpSyncTransport(current.credentials).account()
            null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: SyncException.Unauthorized) {
            expire(current.credentials)
            null
        } catch (error: Exception) {
            message(error, "Couldn't load the account.")
        }
    }

    /** Mints a one-time code another device can join with. */
    suspend fun makePairingLink(): Result<PairingInvite> {
        val credentials = _credentials.value ?: return Result.failure(IllegalStateException("This device is not signed in."))
        return try {
            val code = OkHttpSyncTransport(credentials).createPairingCode()
            val invite = PairingInvite(SyncPairingLink(credentials.serverURL, code.code), parseExpiry(code.expiresAt))
            _invite.value = invite
            Result.success(invite)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: SyncException.Unauthorized) {
            expire(credentials)
            Result.failure(SyncException.Unauthorized())
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    /** Signs out of the account. The workspace stays as it is on this device. */
    fun signOut() {
        container.scope.launch {
            val credentials = _credentials.value ?: return@launch
            // Best effort: the token is forgotten here either way, and an
            // unreachable server mustn't keep the device signed in.
            runCatching { OkHttpSyncTransport(credentials).signOut() }
                .onFailure { if (it is CancellationException) throw it }
            tearDown(SignedOutHint(credentials.email, credentials.serverURL, expired = false))
            container.undo.say("Signed out. Your tasks stay on this device.")
        }
    }

    /**
     * Deletes the account, everything it synced and every device's session.
     * Each device keeps its own copy of the workspace. Returns the error to
     * show, or null once it is gone.
     */
    suspend fun deleteAccount(password: String): String? {
        val credentials = _credentials.value ?: return "This device is not signed in."
        if (password.isEmpty()) return "Enter your password."
        return try {
            OkHttpSyncTransport(credentials).deleteAccount(password)
            tearDown(SignedOutHint(email = null, serverURL = credentials.serverURL, expired = false))
            container.undo.say("Account deleted. Your tasks stay on this device.")
            null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            message(error, "Couldn't delete the account.")
        }
    }

    /** The server no longer knows this device's token: stop, and ask for the password again. */
    private suspend fun expire(credentials: SyncCredentials) {
        if (_credentials.value != credentials) return
        tearDown(SignedOutHint(credentials.email, credentials.serverURL, expired = true))
        container.undo.say("Signed out of sync. Sign in again to keep syncing.")
    }

    private suspend fun tearDown(hint: SignedOutHint) {
        lock.withLock {
            deactivate()
            SyncStore(container.repository().database).endSync()
            withContext(Dispatchers.IO) {
                credentialStore.clear()
                credentialStore.saveSignedOut(hint)
            }
            _signedOut.value = hint
            _account.value = null
            _invite.value = null
            _signInError.value = null
            WorkManager.getInstance(container.context).cancelUniqueWork(WORK_NAME)
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
        // A 401 on push or changes: tear down from outside this scope, which the teardown cancels.
        scope.launch {
            engine.status.first { it == SyncEngine.Status.SignedOut }
            container.scope.launch { expire(credentials) }
        }
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

        /** The server new accounts go to, unless Settings is told another. */
        val defaultServer: String get() = BuildConfig.SYNC_SERVER

        fun describe(credentials: SyncCredentials?, engine: SyncEngine.Status?, stored: SyncLocalState?, expired: Boolean = false): SyncUiState = when {
            credentials == null -> if (expired) SyncUiState.SessionExpired else SyncUiState.Unpaired
            engine is SyncEngine.Status.SignedOut -> SyncUiState.SessionExpired
            engine is SyncEngine.Status.Syncing -> SyncUiState.Syncing
            engine is SyncEngine.Status.Failed -> SyncUiState.Failed(engine.message)
            engine is SyncEngine.Status.Synced -> SyncUiState.Idle(engine.at)
            else -> SyncUiState.Idle(stored?.lastSyncedAt)
        }

        /** The server's own words for a [SyncException], or a plain fallback for anything else. */
        fun message(error: Throwable, fallback: String): String = when (error) {
            is SyncException -> error.message ?: fallback
            is java.io.IOException -> "Couldn't reach the sync server. Check the connection and the address."
            is IllegalArgumentException -> "That server address isn't valid."
            else -> error.message ?: fallback
        }

        fun passwordResetNotice(email: String): String =
            "If there's an account for $email, we've sent a link to reset its password. It works for an hour."

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
