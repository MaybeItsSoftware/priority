package uk.co.maybeitsadam.priority

import android.app.Application
import java.io.File
import uk.co.maybeitsadam.priority.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.priority.data.workspace.WorkspaceRepository

/** Owns the one workspace database for the process, at `files/Priority/priority.sqlite` (the Mac's path, under app storage). */
class PriorityApplication : Application() {
    val repository: WorkspaceRepository by lazy {
        val path = File(filesDir, "Priority/priority.sqlite").path
        WorkspaceRepository(WorkspaceDatabase.open(path))
    }
}
