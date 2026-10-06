package uk.co.maybeitsadam.takt.app

import android.util.Log
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.data.workspace.reconcileWaitingFollowUps

/**
 * Runs the waiting follow-up engine while the app is in the foreground: once
 * as it comes forward (so a follow-up that came due while it was away, or that
 * sync just made due, lands straight away), then every [INTERVAL_MILLIS].
 *
 * The Mac does the same from its external-write poll every 15 seconds. The
 * follow-up field takes whole minutes, so a half-minute tick lands a
 * follow-up within half a minute of its time. Each pass is a single read
 * when nothing is due; and since both devices give a follow-up the same id,
 * one made here while the Mac also made it merges on sync.
 */
class WaitingFollowUps(private val container: AppContainer) {
    private var job: Job? = null

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
        }.onFailure { Log.w(TAG, "No process lifecycle; due follow-ups are not made automatically", it) }
    }

    private fun start() {
        job?.cancel()
        job = container.scope.launch {
            val repository = container.repository()
            while (isActive) {
                try {
                    repository.reconcileWaitingFollowUps()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    Log.w(TAG, "Couldn't make due follow-ups", error)
                }
                delay(INTERVAL_MILLIS)
            }
        }
    }

    private fun stop() {
        job?.cancel()
        job = null
    }

    private companion object {
        const val TAG = "WaitingFollowUps"
        const val INTERVAL_MILLIS = 30_000L
    }
}
