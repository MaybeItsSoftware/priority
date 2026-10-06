package uk.co.maybeitsadam.takt.settings

import android.net.Uri
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.ExternalAuthAction
import io.github.jan.supabase.auth.FlowType
import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.auth.exception.AuthWeakPasswordException
import io.github.jan.supabase.auth.exception.NoSessionFoundException
import io.github.jan.supabase.auth.providers.Apple
import io.github.jan.supabase.auth.providers.Google
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.providers.builtin.IDToken
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.exceptions.RestException
import io.ktor.client.engine.okhttp.OkHttp
import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import uk.co.maybeitsadam.takt.core.SyncEndpoints
import uk.co.maybeitsadam.takt.data.sync.AccessToken
import uk.co.maybeitsadam.takt.data.sync.RefreshingAccessTokens
import uk.co.maybeitsadam.takt.data.sync.SyncAccessTokens
import uk.co.maybeitsadam.takt.data.sync.SyncException

/** A sign-in problem worth showing as it is. */
class AccountException(message: String) : Exception(message)

/** Who is signed in, as far as the app needs to know. */
data class AccountSession(val userId: String?, val email: String?)

/**
 * The Supabase Auth session behind sync (docs/sync.md "Wire protocol"):
 * signing in with a password, Google or Apple; the session sealed in
 * [store]; and the bearer tokens the sync transport sends.
 *
 * Supabase's own auto-refresh is off. [tokens] refreshes before a request
 * when the token is about to expire, and once more when the server refuses
 * it, so a session only ends when Supabase refuses the refresh token.
 *
 * [project] is the Supabase project of the endpoints in use: Takt's, or a
 * self-hosted one. [SyncController] makes a new instance when it changes,
 * after forgetting the old project's session.
 */
class SupabaseAccounts(private val store: SyncCredentialStore, val project: SyncEndpoints = SyncController.hostedEndpoints) {
    private val client = createSupabaseClient(project.supabaseURL, project.supabaseKey) {
        httpEngine = OkHttp.create()
        install(Auth) {
            flowType = FlowType.PKCE
            scheme = REDIRECT_SCHEME
            host = REDIRECT_HOST
            alwaysAutoRefresh = false
            autoLoadFromStorage = true
            enableLifecycleCallbacks = false
            sessionManager = SealedSessionManager(store)
            defaultExternalAuthAction = ExternalAuthAction.CustomTabs()
        }
    }

    private val auth get() = client.auth

    /** Waits for the saved session (if any) to be loaded. */
    suspend fun ready() = auth.awaitInitialization()

    fun session(): AccountSession? = auth.currentSessionOrNull()?.let { AccountSession(it.user?.id, it.user?.email) }

    val tokens: SyncAccessTokens = RefreshingAccessTokens(
        session = { auth.currentSessionOrNull()?.toAccessToken() },
        refreshSession = { refreshed() },
    )

    private suspend fun refreshed(): AccessToken {
        try {
            auth.refreshCurrentSession()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: RestException) {
            // A refresh token Supabase refuses (revoked, spent, its user deleted) ends the session;
            // a Supabase that is down for a moment doesn't.
            if (error.statusCode in 400..499) {
                forget()
                throw SyncException.Unauthorized()
            }
            throw IOException("Supabase answered ${error.statusCode} while refreshing the session.", error)
        } catch (error: IllegalStateException) {
            // No session, or no refresh token in it.
            throw SyncException.Unauthorized()
        }
        return auth.currentSessionOrNull()?.toAccessToken() ?: throw SyncException.Unauthorized()
    }

    suspend fun signIn(email: String, password: String) = auth.signInWith(Email) {
        this.email = email
        this.password = password
    }

    /**
     * Makes an account. True when it is signed in straight away; false when
     * Supabase wants the email confirmed first. The confirmation link comes
     * back to [REDIRECT_URL], which signs this device in when opened here.
     */
    suspend fun signUp(email: String, password: String): Boolean {
        auth.signUpWith(Email, redirectUrl = REDIRECT_URL) {
            this.email = email
            this.password = password
        }
        return auth.currentSessionOrNull() != null
    }

    /** Emails a link that comes back to [REDIRECT_URL] and signs this device in, to choose a new password. */
    suspend fun sendPasswordReset(email: String) = auth.resetPasswordForEmail(email, redirectUrl = REDIRECT_URL)

    suspend fun setPassword(password: String) {
        auth.updateUser { this.password = password }
    }

    /** Signs in with an ID token from Credential Manager, and the nonce its hash was asked for with. */
    suspend fun signInWithGoogle(idToken: String, rawNonce: String) = auth.signInWith(IDToken) {
        this.idToken = idToken
        provider = Google
        nonce = rawNonce
    }

    /** Opens Sign in with Apple in a Custom Tab. It finishes in [completeRedirect], when the browser comes back. */
    suspend fun startApple() = auth.signInWith(Apple, redirectUrl = REDIRECT_URL)

    /**
     * Finishes a sign-in the browser came back from ([REDIRECT_URL] with a
     * PKCE `code`, or Supabase's `error_description`).
     */
    suspend fun completeRedirect(uri: Uri) {
        val described = uri.getQueryParameter("error_description") ?: uri.fragmentParameter("error_description")
        if (described != null) throw AccountException(SyncException.sentence(described))
        val code = uri.getQueryParameter("code") ?: throw AccountException("That sign-in link is incomplete. Try again.")
        try {
            auth.exchangeCodeForSession(code)
        } catch (missing: IllegalArgumentException) {
            // The code verifier lives on the device that asked; this isn't it, or it asked again since.
            throw AccountException("Open the link on the device you asked from, or sign in with your password.")
        }
    }

    /** Signs out of Supabase, as far as it can be reached; the session is forgotten here either way. */
    suspend fun signOut() {
        try {
            auth.signOut()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            forget()
        }
    }

    /** Forgets the session on this device only (the account is gone, or the refresh token refused). */
    suspend fun forget() = auth.clearSession()

    private fun Uri.fragmentParameter(name: String): String? =
        fragment?.split('&')?.firstOrNull { it.startsWith("$name=") }?.substringAfter('=')?.let(Uri::decode)

    companion object {
        const val REDIRECT_SCHEME = "takt"
        const val REDIRECT_HOST = "auth-callback"
        const val REDIRECT_URL = "$REDIRECT_SCHEME://$REDIRECT_HOST"

        fun isRedirect(uri: Uri?): Boolean = uri?.scheme == REDIRECT_SCHEME && uri.host == REDIRECT_HOST

        private fun UserSession.toAccessToken() = AccessToken(accessToken, Instant.ofEpochMilli(expiresAt.toEpochMilliseconds()))

        /** What to show for a Supabase Auth failure, or null when it isn't one. */
        fun message(error: Throwable): String? = when (error) {
            is AuthWeakPasswordException ->
                "Choose a stronger password" + error.reasons.takeIf { it.isNotEmpty() }?.joinToString(", ", prefix = ": ").orEmpty() + "."
            is AuthRestException -> describe(error.error, error.errorDescription)
            is RestException -> describe(error.error, error.description)
            else -> null
        }

        /** Supabase's message for an error code, in the app's words where it has some. */
        internal fun describe(code: String?, description: String?): String = when (code) {
            "invalid_credentials" -> "Wrong email or password."
            "email_not_confirmed" -> "Confirm your email first: open the link we sent you."
            "user_already_exists", "email_exists" -> "There's already an account for that email. Sign in instead."
            "over_email_send_rate_limit", "over_request_rate_limit" -> "Too many tries. Wait a minute, then try again."
            else -> SyncException.sentence(description?.takeIf { it.isNotBlank() } ?: code ?: "Supabase refused that")
        }
    }
}

/** Keeps Supabase's session sealed in the [SyncCredentialStore], instead of in plain preferences. */
private class SealedSessionManager(private val store: SyncCredentialStore) : SessionManager {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    override suspend fun saveSession(session: UserSession) = withContext(Dispatchers.IO) {
        store.saveSession(json.encodeToString(UserSession.serializer(), session))
    }

    override suspend fun loadSession(): UserSession = withContext(Dispatchers.IO) {
        val text = store.loadSession() ?: throw NoSessionFoundException()
        json.decodeFromString(UserSession.serializer(), text)
    }

    override suspend fun deleteSession() = withContext(Dispatchers.IO) { store.clearSession() }
}
