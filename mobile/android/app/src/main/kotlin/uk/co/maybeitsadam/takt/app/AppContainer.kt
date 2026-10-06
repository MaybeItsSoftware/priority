package uk.co.maybeitsadam.takt.app

import android.content.Context
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import androidx.glance.appwidget.updateAll
import uk.co.maybeitsadam.takt.widget.NextUpWidget
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.core.Workspace
import uk.co.maybeitsadam.takt.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceRepository
import uk.co.maybeitsadam.takt.focus.FocusServiceLauncher
import uk.co.maybeitsadam.takt.settings.SyncController
import uk.co.maybeitsadam.takt.ui.actions.TaskCommands
import uk.co.maybeitsadam.takt.ui.undo.UndoCenter

/** The open workspace: what every screen needs before it can draw anything. */
data class WorkspaceSession(
    val repository: WorkspaceRepository,
    val workspace: Workspace,
    /** The list quick capture files into. */
    val inboxId: String,
)

/**
 * The process's object graph, owned by [uk.co.maybeitsadam.takt.TaktApplication].
 *
 * The database is opened and bootstrapped on [Dispatchers.IO] as soon as the
 * container exists, so the first frame never waits on disk. Anything that
 * needs it either collects [session] or suspends on [awaitSession].
 */
class AppContainer(
    val context: Context,
    /** Overridable so instrumentation tests and benchmarks can use their own file. */
    databaseFile: File = File(context.filesDir, "Priority/priority.sqlite"),
) {
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _session = MutableStateFlow<WorkspaceSession?>(null)

    /** Null until the database is open; then the session for the life of the process. */
    val session: StateFlow<WorkspaceSession?> = _session.asStateFlow()

    private val opening: Deferred<WorkspaceSession> = scope.async(Dispatchers.IO) {
        databaseFile.parentFile?.mkdirs()
        val repository = WorkspaceRepository(WorkspaceDatabase.open(databaseFile.path))
        val workspace = repository.bootstrapIfNeeded()
        val inbox = repository.inbox(workspace.id) ?: error("The workspace has no Inbox after bootstrapping")
        WorkspaceSession(repository, workspace, inbox.id).also { _session.value = it }
    }

    suspend fun awaitSession(): WorkspaceSession = opening.await()

    suspend fun repository(): WorkspaceRepository = awaitSession().repository

    /** A flow built from the session once it exists; the usual way a ViewModel starts. */
    fun <T> withSession(block: (WorkspaceSession) -> Flow<T>): Flow<T> =
        session.filterNotNull().flatMapLatest { block(it) }

    val settings = SettingsStore(context)
    val themes = ThemeStore(settings, this)

    /**
     * The theme library, kept current for the surfaces outside Compose (the
     * widget, the focus notification) that read it synchronously.
     */
    val theme: StateFlow<ThemeLibraryState> = themes.state.stateIn(scope, SharingStarted.Eagerly, ThemeLibraryState())
    val folds = FoldStore(context)
    val inspector = InspectorController()
    val quickAdd = QuickAddController()
    val undo = UndoCenter(this)
    val commands = TaskCommands(this)
    val sync = SyncController(this)
    private val followUps = WaitingFollowUps(this)

    init {
        scope.launch { awaitSession() }
        FocusServiceLauncher.attach(this)
        sync.attach()
        followUps.attach()
        // The widget is drawn from the theme in force, so a new one redraws it.
        scope.launch {
            theme.map { it.specification to it.mode }.distinctUntilChanged().drop(1).collect {
                runCatching { NextUpWidget().updateAll(context) }
            }
        }
    }

    companion object {
        /** An empty flow, for screens that have nothing to show before the session opens. */
        fun <T> nothing(): Flow<T> = emptyFlow()
    }
}
