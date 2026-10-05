package uk.co.maybeitsadam.takt.data.sync

import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Where [OkHttpSyncTransport] gets the bearer token for each request. */
interface SyncAccessTokens {
    /**
     * The token to send now, refreshed first if it is about to expire.
     * Throws [SyncException.Unauthorized] when there is no session, or
     * Supabase refuses to refresh it.
     */
    suspend fun current(): String

    /**
     * A token to retry with after the server refused [rejected]. Refreshes,
     * unless another request already has since [rejected] was handed out.
     * Throws [SyncException.Unauthorized] when Supabase refuses the refresh.
     */
    suspend fun refresh(rejected: String): String
}

/** An access token and when it stops working. */
data class AccessToken(val value: String, val expiresAt: Instant)

/**
 * [SyncAccessTokens] over a session it neither stores nor refreshes itself:
 * [session] reads the current one and [refreshSession] swaps it for a new
 * one. That is Supabase's job, so this is the part that can be tested on the
 * JVM: when to refresh, refreshing one at a time (a refresh token is spent
 * on use), and what a failure means.
 *
 * [refreshSession] throws [SyncException.Unauthorized] when Supabase refuses
 * the refresh token, which ends the session; anything else it throws (an
 * unreachable Supabase, say) is passed on as it is, so a sync fails and
 * tries again later rather than signing the device out.
 */
class RefreshingAccessTokens(
    private val session: suspend () -> AccessToken?,
    private val refreshSession: suspend () -> AccessToken,
    private val now: () -> Instant = Instant::now,
    private val margin: Duration = Duration.ofSeconds(60),
) : SyncAccessTokens {
    private val lock = Mutex()

    override suspend fun current(): String = lock.withLock {
        val token = session() ?: throw SyncException.Unauthorized()
        if (token.expiresAt.isAfter(now().plus(margin))) token.value else refreshSession().value
    }

    override suspend fun refresh(rejected: String): String = lock.withLock {
        val token = session() ?: throw SyncException.Unauthorized()
        if (token.value != rejected) token.value else refreshSession().value
    }
}
