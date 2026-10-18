package uk.co.maybeitsadam.takt.watch.complication

import android.app.PendingIntent
import android.content.Intent
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationText
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.CountUpTimeReference
import androidx.wear.watchface.complications.data.LongTextComplicationData
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.data.TimeDifferenceComplicationText
import androidx.wear.watchface.complications.data.TimeDifferenceStyle
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import java.time.Instant
import java.util.concurrent.TimeUnit
import uk.co.maybeitsadam.takt.watch.MainActivity
import uk.co.maybeitsadam.takt.watch.WatchGlance
import uk.co.maybeitsadam.takt.watch.watch
import uk.co.maybeitsadam.takt.wear.contract.withPending

/**
 * The running block's timer, counted on the watch face itself; otherwise how
 * many are left today (short) or the next task (long). Pushed on every new
 * day rather than polled.
 */
class TodayComplicationService : SuspendingComplicationDataSourceService() {
    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        val store = watch.store
        val snapshot = store.snapshot.value?.withPending(store.awaiting.value + store.queued.value)
        return data(request.complicationType, WatchGlance.of(snapshot, System.currentTimeMillis()))
    }

    override fun getPreviewData(type: ComplicationType): ComplicationData? {
        val now = System.currentTimeMillis()
        val preview = WatchGlance("Focusing", "Write the report", "3 left today", 3, true, now - 12 * 60_000L, 25 * 60, 12 * 60)
        return data(type, preview)
    }

    private fun data(type: ComplicationType, glance: WatchGlance): ComplicationData? {
        val tap = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val timer: ComplicationText? = glance.countingFrom?.let { from ->
            TimeDifferenceComplicationText.Builder(TimeDifferenceStyle.STOPWATCH, CountUpTimeReference(Instant.ofEpochMilli(from)))
                .setMinimumTimeUnit(TimeUnit.SECONDS)
                .build()
        }
        val description = plain(listOfNotNull(glance.eyebrow, glance.title, glance.footer).joinToString(", "))
        return when (type) {
            ComplicationType.SHORT_TEXT -> {
                val (text, title) = when {
                    timer != null -> timer to plain("Focus")
                    glance.isFocusing -> plain("${glance.elapsedSeconds / 60}m") to plain("Paused")
                    glance.openCount == 0 && glance.title == null -> plain("Done") to plain("Today")
                    else -> plain("${glance.openCount}") to plain("left")
                }
                ShortTextComplicationData.Builder(text, description).setTitle(title).setTapAction(tap).build()
            }
            ComplicationType.LONG_TEXT -> {
                val text = when {
                    glance.title == null -> plain(glance.footer)
                    glance.isFocusing -> plain(glance.title)
                    else -> plain("Next: ${glance.title}")
                }
                val title = timer ?: plain(if (glance.isFocusing) "Paused" else glance.footer)
                LongTextComplicationData.Builder(text, description).setTitle(title).setTapAction(tap).build()
            }
            else -> null
        }
    }

    private fun plain(text: String) = PlainComplicationText.Builder(text).build()
}
