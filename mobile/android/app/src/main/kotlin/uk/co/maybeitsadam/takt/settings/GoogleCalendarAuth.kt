package uk.co.maybeitsadam.takt.settings

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Task
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/**
 * Google Calendar's grant on Android (docs/google-calendar.md "OAuth"): the
 * Authorization API asks for the two calendar scopes against the package's
 * Android OAuth clients (registered by package and SHA-1), so no client id is
 * needed. Once consented, [authorize] answers silently with a fresh access
 * token of about an hour; no refresh token is kept.
 */
object GoogleCalendarAuth {
    private val scopes = listOf(
        Scope("https://www.googleapis.com/auth/calendar.events"),
        Scope("https://www.googleapis.com/auth/calendar.readonly"),
    )

    sealed interface Grant {
        data class Token(val accessToken: String) : Grant

        /** Google needs to ask the person; launch this from an activity, then read [tokenFrom]. */
        data class NeedsConsent(val intent: PendingIntent) : Grant
    }

    suspend fun authorize(context: Context): Grant {
        val request = AuthorizationRequest.builder().setRequestedScopes(scopes).build()
        val result = Identity.getAuthorizationClient(context).authorize(request).await()
        val pending = result.pendingIntent
        return when {
            result.hasResolution() && pending != null -> Grant.NeedsConsent(pending)
            else -> Grant.Token(result.accessToken ?: throw AccountException("Google gave no access to the calendar."))
        }
    }

    /** The access token from the consent screen's answer; null when the person backed out. */
    fun tokenFrom(context: Context, data: Intent?): String? = try {
        val result: AuthorizationResult = Identity.getAuthorizationClient(context).getAuthorizationResultFromIntent(data)
        result.accessToken
    } catch (_: ApiException) {
        null
    }

    /** Forgets a token Google refused, so the next [authorize] mints a new one rather than handing it back. */
    suspend fun clear(context: Context, accessToken: String) {
        withContext(Dispatchers.IO) { runCatching { GoogleAuthUtil.clearToken(context, accessToken) } }
    }

    private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
        addOnSuccessListener { continuation.resumeWith(Result.success(it)) }
        addOnFailureListener { continuation.resumeWith(Result.failure(it)) }
        addOnCanceledListener { continuation.cancel() }
    }
}
