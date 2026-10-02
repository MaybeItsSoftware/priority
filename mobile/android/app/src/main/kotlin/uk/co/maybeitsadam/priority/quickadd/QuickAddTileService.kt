package uk.co.maybeitsadam.priority.quickadd

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import uk.co.maybeitsadam.priority.MainActivity
import uk.co.maybeitsadam.priority.R
import uk.co.maybeitsadam.priority.ui.ShellIntents

/**
 * The Quick Settings tile: one tap opens the app on the quick-add sheet and
 * collapses the shade. The tile is an action, not a switch, so it always
 * reads as inactive.
 */
class QuickAddTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.label = getString(R.string.quick_add)
        tile.contentDescription = getString(R.string.quick_add_long)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_quick_add)
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { open() } else open()
    }

    // The Intent overload only runs below API 34, where it is the only one there is.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun open() {
        val intent = Intent(this, MainActivity::class.java)
            .setAction(ShellIntents.ACTION_QUICK_ADD)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = PendingIntent.getActivity(
                this, REQUEST_QUICK_ADD, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private companion object {
        const val REQUEST_QUICK_ADD = 7
    }
}
