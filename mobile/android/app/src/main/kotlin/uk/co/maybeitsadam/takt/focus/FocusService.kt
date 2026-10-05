package uk.co.maybeitsadam.takt.focus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import java.time.Instant
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.MainActivity
import uk.co.maybeitsadam.takt.R
import uk.co.maybeitsadam.takt.appContainer
import uk.co.maybeitsadam.takt.core.FocusSession
import uk.co.maybeitsadam.takt.core.FocusSessionPhase
import uk.co.maybeitsadam.takt.ui.ShellIntents
import uk.co.maybeitsadam.takt.ui.theme.ResolvedTheme
import uk.co.maybeitsadam.takt.core.theme.ThemeColorRole

/**
 * The running focus block's foreground service: an ongoing notification with
 * the task, a chronometer counting the block up, and Pause/Resume and Done.
 * It follows the database, so a block paused or finished anywhere (the app,
 * the Mac through sync, the notification) is reflected here, and it stops
 * itself when no session is left. While the clock runs it checkpoints the
 * block every 30 seconds, as the Mac does, so a killed process keeps the time.
 */
class FocusService : LifecycleService() {
    private var watching: Job? = null
    private var current: FocusSession? = null
    private var lastNotification: Notification? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        // Must be in the foreground within seconds of startForegroundService, before any read.
        goForeground(lastNotification ?: placeholder())
        when (intent?.action) {
            ACTION_PAUSE -> act { session -> pauseOrResume(session, pause = true) }
            ACTION_RESUME -> act { session -> pauseOrResume(session, pause = false) }
            ACTION_DONE -> act { session -> done(session) }
        }
        watch()
        return START_STICKY
    }

    private fun watch() {
        if (watching?.isActive == true) return
        val container = applicationContext.appContainer
        watching = lifecycleScope.launch {
            launch { checkpointLoop() }
            @OptIn(ExperimentalCoroutinesApi::class)
            container.withSession { session ->
                session.repository.observeActiveFocusSession().flatMapLatest { focus ->
                    val taskId = focus?.activeTaskId
                    if (focus == null || taskId == null) {
                        flowOf(focus to null)
                    } else {
                        session.repository.observeTask(taskId).map { focus to it?.title }
                    }
                }
            }.distinctUntilChanged().collect { (focus, title) ->
                current = focus
                if (!focus.needsForegroundService()) {
                    stopForegroundCompat()
                    stopSelf()
                    return@collect
                }
                post(FocusNotificationModel.of(focus!!, title, Instant.now()))
            }
        }
    }

    private suspend fun checkpointLoop() {
        val container = applicationContext.appContainer
        while (lifecycleScope.isActive) {
            delay(CHECKPOINT_MILLIS)
            val session = current ?: continue
            if (session.phase != FocusSessionPhase.RUNNING || session.pausedAt != null || session.activeTaskId == null) continue
            runCatching { container.repository().checkpointFocusSession(session.id) }
        }
    }

    private fun act(block: suspend (FocusSession) -> Unit) {
        val container = applicationContext.appContainer
        container.scope.launch {
            val session = container.repository().activeFocusSession() ?: return@launch
            block(session)
        }
    }

    private fun pauseOrResume(session: FocusSession, pause: Boolean) {
        applicationContext.appContainer.undo.perform(announce = false) { repo ->
            if (pause) repo.pauseFocusSession(session.id) else repo.resumeFocusSession(session.id)
        }
    }

    /** Done from the notification: credit the block and complete the task, without a quality judgement. */
    private fun done(session: FocusSession) {
        applicationContext.appContainer.undo.perform { repo ->
            repo.completeActiveFocusTask(
                sessionId = session.id,
                elapsedSeconds = session.elapsedSeconds(Instant.now()),
                completeTask = true,
                expectedBlockId = session.activeBlockId,
            )
        }
    }

    private fun post(model: FocusNotificationModel) {
        val notification = build(model)
        lastNotification = notification
        goForeground(notification)
    }

    private fun goForeground(notification: Notification) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        runCatching { ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type) }
            .onFailure { stopSelf() }
    }

    private fun stopForegroundCompat() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
    }

    private fun accent(): Int {
        val state = appContainer.theme.value
        val night = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        val appearance = ResolvedTheme.appearance(state.specification, state.mode, night)
        return state.specification.color(ThemeColorRole.PRIMARY, appearance).argb
    }

    private fun placeholder(): Notification = baseBuilder()
        .setContentTitle("Focus block")
        .build()

    private fun baseBuilder(): NotificationCompat.Builder = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_notification)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setSilent(true)
        .setCategory(NotificationCompat.CATEGORY_STOPWATCH)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .setContentIntent(openFocusTab(this))
        // The only colour a notification may carry: the theme's primary, in
        // the appearance the app is drawn in.
        .setColor(accent())

    private fun build(model: FocusNotificationModel): Notification {
        val builder = baseBuilder()
            .setContentTitle(model.title)
            .setContentText(model.text)
        if (model.isCounting) {
            builder.setWhen(model.chronometerBaseMillis).setUsesChronometer(true).setShowWhen(true)
        } else {
            builder.setUsesChronometer(false).setShowWhen(false)
        }
        if (model.hasActions) {
            if (model.isPaused) {
                builder.addAction(0, "Resume", serviceAction(ACTION_RESUME, 1))
            } else {
                builder.addAction(0, "Pause", serviceAction(ACTION_PAUSE, 2))
            }
            builder.addAction(0, "Done", serviceAction(ACTION_DONE, 3))
        }
        return builder.build()
    }

    private fun serviceAction(action: String, requestCode: Int): PendingIntent = PendingIntent.getService(
        this,
        requestCode,
        Intent(this, FocusService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        const val CHANNEL_ID = "focus_block"
        const val NOTIFICATION_ID = 7001
        const val ACTION_PAUSE = "uk.co.maybeitsadam.priority.focus.PAUSE"
        const val ACTION_RESUME = "uk.co.maybeitsadam.priority.focus.RESUME"
        const val ACTION_DONE = "uk.co.maybeitsadam.priority.focus.DONE"
        private const val CHECKPOINT_MILLIS = 30_000L

        /** The low-importance "Focus block" channel: no sound, no peeking, just the ongoing row. */
        fun ensureChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(CHANNEL_ID, context.getString(R.string.focus_channel), NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            manager.createNotificationChannel(channel)
        }

        /** Tapping the notification: the app on the Focus tab. */
        fun openFocusTab(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .putExtra(ShellIntents.EXTRA_TAB, "FOCUS")
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
