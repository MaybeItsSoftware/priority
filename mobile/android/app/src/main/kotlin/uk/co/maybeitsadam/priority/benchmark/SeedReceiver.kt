package uk.co.maybeitsadam.priority.benchmark

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.appContainer
import uk.co.maybeitsadam.priority.data.workspace.seedBenchmarkList

/**
 * Seeds the 5,000-task list the macrobenchmark and baseline-profile generator
 * scroll. Guarded in the manifest by `android.permission.DUMP`, which only the
 * shell (`adb shell am broadcast`) holds, so no other app can trigger it.
 *
 *   adb shell am broadcast -a uk.co.maybeitsadam.priority.SEED_BENCHMARK -n uk.co.maybeitsadam.priority/.benchmark.SeedReceiver
 */
class SeedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val container = context.appContainer
        val count = intent.getIntExtra(EXTRA_COUNT, 5_000).coerceIn(1, 50_000)
        container.scope.launch {
            try {
                val session = container.awaitSession()
                val list = session.repository.seedBenchmarkList(session.workspace.id, count = count)
                pending.resultData = list.id
                pending.resultCode = 1
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION = "uk.co.maybeitsadam.priority.SEED_BENCHMARK"
        const val EXTRA_COUNT = "count"
    }
}
