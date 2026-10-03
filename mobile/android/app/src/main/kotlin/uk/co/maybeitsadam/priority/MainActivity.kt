package uk.co.maybeitsadam.priority

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import uk.co.maybeitsadam.priority.ui.AppShell
import uk.co.maybeitsadam.priority.app.ThemeLibraryState
import uk.co.maybeitsadam.priority.core.theme.ThemeAppearance
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.ResolvedTheme

/** The one activity. Edge to edge; intents (quick add, tabs, sign-in redirects) go to the shell. */
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
            // The theme is state, not configuration: choosing or editing one
            // recomposes in place, with no activity restart.
            val themes by container.themes.state.collectAsStateWithLifecycle(ThemeLibraryState())
            val spec = themes.specification
            val mode = themes.mode
            // A locked theme (Zed Dark) wins over both the setting and the system.
            val dark = ResolvedTheme.appearance(spec, mode, isSystemInDarkTheme()) == ThemeAppearance.DARK
            // Status and navigation bar icons follow the app's appearance, not the system's.
            DisposableEffect(dark) {
                val transparent = android.graphics.Color.TRANSPARENT
                val style = if (dark) SystemBarStyle.dark(transparent) else SystemBarStyle.light(transparent, transparent)
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
                onDispose { }
            }
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
