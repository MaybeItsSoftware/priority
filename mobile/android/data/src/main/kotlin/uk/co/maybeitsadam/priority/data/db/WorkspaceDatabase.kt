package uk.co.maybeitsadam.priority.data.db

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
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
            }
        }
    }

    companion object {
        /**
         * Opens (creating and migrating if needed) the workspace at [path].
         * [fixture] overrides the bundled schema script, for tests.
         */
        fun open(
            path: String,
            readerCount: Int = 3,
            dispatcher: CoroutineDispatcher = Dispatchers.IO,
            fixture: String? = null,
        ): WorkspaceDatabase {
            File(path).absoluteFile.parentFile?.mkdirs()
            val driver = BundledSQLiteDriver()
            val writer = driver.open(path)
            configure(writer)
            writer.execSQL("PRAGMA journal_mode = WAL")
            val db = Db(writer)
            writer.execSQL("BEGIN IMMEDIATE")
            try {
                if (fixture != null) WorkspaceSchema.migrate(db, fixture) else WorkspaceSchema.migrate(db)
                writer.execSQL("COMMIT")
            } catch (error: Throwable) {
                runCatching { writer.execSQL("ROLLBACK") }
                writer.close()
                throw error
            }
            installChangeTracking(db)
            val readerConnections = List(readerCount.coerceAtLeast(1)) {
                driver.open(path).also { reader ->
                    configure(reader)
                    reader.execSQL("PRAGMA query_only = ON")
                }
            }
            val pool = Channel<SQLiteConnection>(readerConnections.size)
            readerConnections.forEach { pool.trySend(it) }
            return WorkspaceDatabase(path, writer, pool, readerConnections, dispatcher)
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
