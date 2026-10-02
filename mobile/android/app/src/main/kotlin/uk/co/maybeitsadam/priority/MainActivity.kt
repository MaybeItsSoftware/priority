package uk.co.maybeitsadam.priority

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import uk.co.maybeitsadam.priority.ui.AppShell
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.ThemeMode
import uk.co.maybeitsadam.priority.ui.theme.ThemeSpec

/** The one activity. Edge to edge; intents (quick add, tabs, pairing links) go to the shell. */
class MainActivity : ComponentActivity() {
    private var pendingIntent by mutableStateOf<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) pendingIntent = intent
        val container = appContainer
        setContent {
            val mode by container.settings.themeMode.collectAsStateWithLifecycle(ThemeMode.SYSTEM)
            val spec by container.settings.themeSpec.collectAsStateWithLifecycle(ThemeSpec.Chalk)
            PriorityTheme(spec = spec, mode = mode) {
                AppShell(container, pendingIntent, onIntentHandled = { pendingIntent = null })
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingIntent = intent
    }
}
