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
import uk.co.maybeitsadam.takt.data.workspace.reconcileHabits
import uk.co.maybeitsadam.takt.data.workspace.reconcileWaitingFollowUps

/**
 * Runs the board's two engines while the app is in the foreground: once as it
 * comes forward (so whatever came due while it was away, or that sync just
 * brought, lands straight away), then every [INTERVAL_MILLIS].
 *
 * The habit engine (`reconcileHabits`) puts each habit due today in its
 * column, takes out one that is done or was dropped at the end of its day,
 * and ends habits that expired. The Mac runs the same pass on every dailies
 * reload and on the first poll of a new day; a half-minute tick here covers
 * both, and the pass only writes the rows the Mac would, so the two agree.
 *
 * The waiting follow-up engine makes due follow-ups.
 * The Mac does the same from its external-write poll every 15 seconds. The
 * follow-up field takes whole minutes, so a half-minute tick lands a
 * follow-up within half a minute of its time. Each pass is a single read
 * when nothing is due; and since both devices give a follow-up the same id,
 * one made here while the Mac also made it merges on sync.
 */
class ForegroundEngines(private val container: AppContainer) {
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
        }.onFailure { Log.w(TAG, "No process lifecycle; habits and follow-ups are not placed automatically", it) }
    }

    private fun start() {
        job?.cancel()
        job = container.scope.launch {
            val repository = container.repository()
            while (isActive) {
                try {
                    repository.reconcileHabits()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    Log.w(TAG, "Couldn't place habits", error)
                }
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
        const val TAG = "ForegroundEngines"
        const val INTERVAL_MILLIS = 30_000L
    }
}
