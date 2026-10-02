package uk.co.maybeitsadam.priority.focus

import android.app.Service
import android.content.Intent
import android.os.IBinder

/** Stub: the running focus block's foreground service, with Pause and Done in its notification. */
class FocusService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
}
