package uk.co.maybeitsadam.priority.app

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
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.core.Workspace
import uk.co.maybeitsadam.priority.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.priority.data.workspace.WorkspaceRepository
import uk.co.maybeitsadam.priority.focus.FocusServiceLauncher
import uk.co.maybeitsadam.priority.settings.SyncController
import uk.co.maybeitsadam.priority.ui.actions.TaskCommands
import uk.co.maybeitsadam.priority.ui.undo.UndoCenter

/** The open workspace: what every screen needs before it can draw anything. */
data class WorkspaceSession(
    val repository: WorkspaceRepository,
    val workspace: Workspace,
    /** The list quick capture files into. */
    val inboxId: String,
)

/**
 * The process's object graph, owned by [uk.co.maybeitsadam.priority.PriorityApplication].
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
    val folds = FoldStore(context)
    val inspector = InspectorController()
    val quickAdd = QuickAddController()
    val undo = UndoCenter(this)
    val commands = TaskCommands(this)
    val sync = SyncController(this)

    init {
        scope.launch { awaitSession() }
        FocusServiceLauncher.attach(this)
        sync.attach()
    }

    companion object {
        /** An empty flow, for screens that have nothing to show before the session opens. */
        fun <T> nothing(): Flow<T> = emptyFlow()
    }
}
