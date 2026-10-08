package uk.co.maybeitsadam.takt.data.db

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import uniffi.takt_core.CoreWorkspace
import uniffi.takt_core.migrateWorkspace
import androidx.sqlite.execSQL
import java.io.Closeable
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The workspace database file: one writer connection and a small pool of
 * readers over WAL, all on [dispatcher], exposed as suspend functions.
 *
 * Writes report the tables they touched. The writer carries TEMP triggers
 * (visible to no other connection, and not part of the schema) that note each
 * changed table, so undo replays and sync pulls are covered without any write
 * having to declare what it did. [observe] re-runs a read when one of its
 * tables changes.
 */
class WorkspaceDatabase private constructor(
    val path: String,
    private val writer: SQLiteConnection,
    private val readers: Channel<SQLiteConnection>,
    private val readerConnections: List<SQLiteConnection>,
    private val dispatcher: CoroutineDispatcher,
    /**
     * The Rust core's handle on the same file (core/src/workspace.rs): a
     * connection of its own on the same SQLite library as the driver, so the
     * two cannot release each other's locks. What has moved into the core
     * (docs/rust-core-migration.md) goes through it.
     */
    val core: CoreWorkspace,
) : Closeable {

    private val writerLock = Mutex()
    private val changes = MutableSharedFlow<Set<String>>(extraBufferCapacity = 64)

    /** Each committed write's changed tables. */
    val invalidations: SharedFlow<Set<String>> = changes.asSharedFlow()

    /** Runs [block] in one IMMEDIATE transaction on the writer; rolls back if it throws. */
    suspend fun <T> write(block: (Db) -> T): T = withContext(dispatcher) {
        val (result, touched) = writerLock.withLock { transaction(writer, "BEGIN IMMEDIATE", track = true, block) }
        if (touched.isNotEmpty()) changes.emit(touched)
        result
    }

    /**
     * Runs a write the Rust core makes on its own connection, then announces
     * [tables] as changed, since the TEMP triggers that report this database's
     * own writes cannot see the core's. Holds the writer lock throughout, so
     * the core never waits on this database's writer or it on the core.
     */
    suspend fun <T> coreWrite(tables: Set<String>, block: (CoreWorkspace) -> T): T = withContext(dispatcher) {
        val result = writerLock.withLock {
            // The writer's data_version counts every commit but its own, which now
            // includes the core's. Whatever it moves across this write is ours, so
            // [ownCoreCommits] takes it back out of the external-change token.
            val db = Db(writer)
            val before = db.long("PRAGMA data_version") ?: 0L
            val value = block(core)
            ownCoreCommits += (db.long("PRAGMA data_version") ?: 0L) - before
            value
        }
        changes.emit(tables)
        result
    }

    /** How far the writer's `data_version` has moved because of [coreWrite]; only touched under the writer lock. */
    @Volatile
    var ownCoreCommits: Long = 0L
        private set

    /** Runs a read through the Rust core's connection. */
    suspend fun <T> coreRead(block: (CoreWorkspace) -> T): T = withContext(dispatcher) { block(core) }

    /** Runs [block] on the writer outside a transaction (for `PRAGMA data_version` and the like). */
    suspend fun <T> writerWithoutTransaction(block: (Db) -> T): T = withContext(dispatcher) {
        writerLock.withLock { block(Db(writer)) }
    }

    /** Runs [block] in a read transaction on a pooled reader, so it sees one consistent moment. */
    suspend fun <T> read(block: (Db) -> T): T = withContext(dispatcher) {
        val connection = readers.receive()
        try {
            transaction(connection, "BEGIN", track = false, block).first
        } finally {
            readers.send(connection)
        }
    }

    /**
     * A flow of [block]'s result, re-queried whenever a write touches one of
     * [tables] (or any table, when [tables] is empty).
     */
    fun <T> observe(tables: Set<String>, block: (Db) -> T): Flow<T> = channelFlow {
        val pending = Channel<Unit>(Channel.CONFLATED)
        pending.trySend(Unit)
        launch(start = CoroutineStart.UNDISPATCHED) {
            invalidations.collect { touched ->
                if (tables.isEmpty() || touched.any { it in tables }) pending.trySend(Unit)
            }
        }
        for (ignored in pending) send(read(block))
    }.conflate()

    private fun <T> transaction(
        connection: SQLiteConnection,
        begin: String,
        track: Boolean,
        block: (Db) -> T,
    ): Pair<T, Set<String>> {
        connection.execSQL(begin)
        try {
            val db = Db(connection)
            val result = block(db)
            val touched = if (track) {
                db.strings("SELECT tableName FROM temp.priority_changed").toSet().also {
                    db.execute("DELETE FROM temp.priority_changed")
                }
            } else {
                emptySet()
            }
            connection.execSQL("COMMIT")
            return result to touched
        } catch (error: Throwable) {
            runCatching { connection.execSQL("ROLLBACK") }
            throw error
        }
    }

    override fun close() {
        runBlocking {
            writerLock.withLock {
                writer.close()
                readerConnections.forEach { it.close() }
                core.close()
            }
        }
    }

    companion object {
        /** Opens (creating and migrating if needed) the workspace at [path]. */
        fun open(
            path: String,
            readerCount: Int = 3,
            dispatcher: CoroutineDispatcher = Dispatchers.IO,
        ): WorkspaceDatabase {
            File(path).absoluteFile.parentFile?.mkdirs()
            // The schema is the Rust core's (core/src/schema). It opens the file
            // on its own connection, migrates it and closes it before the driver
            // below opens it. The core links this driver's SQLite library
            // (libsqliteJni.so), so later core connections share its locks.
            migrateWorkspace(path)
            val driver = BundledSQLiteDriver()
            val writer = driver.open(path)
            configure(writer)
            writer.execSQL("PRAGMA journal_mode = WAL")
            val db = Db(writer)
            installChangeTracking(db)
            val readerConnections = List(readerCount.coerceAtLeast(1)) {
                driver.open(path).also { reader ->
                    configure(reader)
                    reader.execSQL("PRAGMA query_only = ON")
                }
            }
            val pool = Channel<SQLiteConnection>(readerConnections.size)
            readerConnections.forEach { pool.trySend(it) }
            return WorkspaceDatabase(path, writer, pool, readerConnections, dispatcher, CoreWorkspace.open(path))
        }

        private fun configure(connection: SQLiteConnection) {
            connection.execSQL("PRAGMA foreign_keys = ON")
            connection.execSQL("PRAGMA busy_timeout = 5000")
        }

        /** TEMP triggers on the writer that record each table a write touches. */
        private fun installChangeTracking(db: Db) {
            db.execute("CREATE TEMP TABLE IF NOT EXISTS priority_changed (tableName TEXT PRIMARY KEY)")
            val tables = db.strings(
                "SELECT name FROM main.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' " +
                    "AND name NOT LIKE 'tasks_fts%'",
            )
            for (table in tables) {
                for (operation in listOf("INSERT", "UPDATE", "DELETE")) {
                    db.execute(
                        "CREATE TEMP TRIGGER IF NOT EXISTS \"priority_changed_${table}_$operation\" " +
                            "AFTER $operation ON main.\"$table\" " +
                            // Not INSERT OR IGNORE: an UPSERT's own conflict clause overrides a
                            // trigger's, so the second upsert of a table in one write would fail
                            // on the primary key. A guarded insert never conflicts at all.
                            "BEGIN INSERT INTO priority_changed SELECT '$table' WHERE NOT EXISTS " +
                            "(SELECT 1 FROM priority_changed WHERE tableName = '$table'); END",
                    )
                }
            }
        }
    }
}
