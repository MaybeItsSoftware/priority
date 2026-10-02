package uk.co.maybeitsadam.priority.ui.commands

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf

/** One row in the command palette: a catalogue entry made runnable. */
@Immutable
data class PaletteCommand(
    val id: String,
    val title: String,
    val group: String,
    /** The keys shown beside it, e.g. `Ctrl+Z`; empty for none. */
    val keys: String = "",
    val run: () -> Unit,
)

/**
 * The commands the visible screens contribute. A screen registers with
 * [RegisterCommands]; the palette lists these after the shell's own.
 */
class CommandRegistry {
    private val byOwner = mutableStateMapOf<Any, List<PaletteCommand>>()

    val commands: List<PaletteCommand> get() = byOwner.values.flatten()

    fun set(owner: Any, commands: List<PaletteCommand>) {
        byOwner[owner] = commands
    }

    fun remove(owner: Any) {
        byOwner.remove(owner)
    }
}

val LocalCommandRegistry = staticCompositionLocalOf { CommandRegistry() }

/** Contributes [commands] to the palette while this composable is on screen. */
@Composable
fun RegisterCommands(commands: List<PaletteCommand>) {
    val registry = LocalCommandRegistry.current
    val owner = remember { Any() }
    SideEffect { registry.set(owner, commands) }
    DisposableEffect(registry, owner) {
        onDispose { registry.remove(owner) }
    }
}
