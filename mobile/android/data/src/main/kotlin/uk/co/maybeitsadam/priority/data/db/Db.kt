package uk.co.maybeitsadam.priority.data.db

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import java.time.Instant
import uk.co.maybeitsadam.priority.core.SyncValue

/**
 * A connection inside a transaction, with the handful of helpers the store's
 * SQL needs. Arguments may be `null`, `String`, `Int`, `Long`, `Double`,
 * `Boolean` (written 0/1), `Instant` (written as GRDB text) or a [SyncValue].
 */
class Db internal constructor(val connection: SQLiteConnection) {

    fun execute(sql: String, vararg args: Any?) {
        connection.prepare(sql).use { statement ->
            bind(statement, args)
            @Suppress("ControlFlowWithEmptyBody")
            while (statement.step()) {
            }
        }
    }

    fun <T> query(sql: String, vararg args: Any?, map: (Row) -> T): List<T> =
        connection.prepare(sql).use { statement ->
            bind(statement, args)
            val row = Row(statement)
            buildList { while (statement.step()) add(map(row)) }
        }

    fun <T> queryOne(sql: String, vararg args: Any?, map: (Row) -> T): T? =
        connection.prepare(sql).use { statement ->
            bind(statement, args)
            if (statement.step()) map(Row(statement)) else null
        }

    fun long(sql: String, vararg args: Any?): Long? =
        queryOne(sql, *args) { if (it.isNull(0)) null else it.long(0) }

    fun int(sql: String, vararg args: Any?): Int? = long(sql, *args)?.toInt()

    fun string(sql: String, vararg args: Any?): String? =
        queryOne(sql, *args) { if (it.isNull(0)) null else it.string(0) }

    fun strings(sql: String, vararg args: Any?): List<String> =
        query(sql, *args) { it.string(0) }

    fun exists(sql: String, vararg args: Any?): Boolean = (long("SELECT EXISTS($sql)", *args) ?: 0L) != 0L

    /** Rows changed by the most recent INSERT, UPDATE or DELETE. */
    fun changes(): Int = int("SELECT changes()") ?: 0

    /** Column names of a table, in declaration order, as `PRAGMA table_info` reports them. */
    fun columns(table: String): List<String> = query("PRAGMA table_info(\"$table\")") { it.string("name") }

    fun tableExists(table: String): Boolean =
        exists("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", table)

    companion object {
        internal fun bind(statement: SQLiteStatement, args: Array<out Any?>) {
            args.forEachIndexed { i, arg ->
                val index = i + 1
                when (arg) {
                    null -> statement.bindNull(index)
                    is String -> statement.bindText(index, arg)
                    is Int -> statement.bindLong(index, arg.toLong())
                    is Long -> statement.bindLong(index, arg)
                    is Double -> statement.bindDouble(index, arg)
                    is Boolean -> statement.bindLong(index, if (arg) 1L else 0L)
                    is Instant -> statement.bindText(index, SqlDates.format(arg))
                    is SyncValue -> when (arg) {
                        SyncValue.Null -> statement.bindNull(index)
                        is SyncValue.Integer -> statement.bindLong(index, arg.value)
                        is SyncValue.Real -> statement.bindDouble(index, arg.value)
                        is SyncValue.Text -> statement.bindText(index, arg.value)
                    }
                    is ByteArray -> statement.bindBlob(index, arg)
                    else -> error("Cannot bind ${arg::class.simpleName}")
                }
            }
        }
    }
}

/** The current row of a statement, readable by column name or index. */
class Row internal constructor(private val statement: SQLiteStatement) {
    private val indices: Map<String, Int> by lazy {
        (0 until statement.getColumnCount()).associateBy { statement.getColumnName(it) }
    }

    val columnNames: List<String> get() = (0 until statement.getColumnCount()).map { statement.getColumnName(it) }

    private fun index(name: String): Int = indices[name] ?: error("No column $name")

    fun isNull(index: Int): Boolean = statement.isNull(index)
    fun isNull(name: String): Boolean = statement.isNull(index(name))
    fun string(index: Int): String = statement.getText(index)
    fun long(index: Int): Long = statement.getLong(index)
    fun double(index: Int): Double = statement.getDouble(index)

    fun string(name: String): String = statement.getText(index(name))
    fun stringOrNull(name: String): String? = if (isNull(name)) null else string(name)
    fun int(name: String): Int = statement.getLong(index(name)).toInt()
    fun intOrNull(name: String): Int? = if (isNull(name)) null else int(name)
    fun long(name: String): Long = statement.getLong(index(name))
    fun double(name: String): Double = statement.getDouble(index(name))
    fun bool(name: String): Boolean = statement.getLong(index(name)) != 0L
    fun boolOrNull(name: String): Boolean? = if (isNull(name)) null else bool(name)
    fun instant(name: String): Instant =
        instantOrNull(name) ?: error("Unreadable date in $name: ${stringOrNull(name)}")
    fun instantOrNull(name: String): Instant? = if (isNull(name)) null else SqlDates.parse(string(name))

    /** The column's value with its storage class, as sync carries it. */
    fun syncValue(index: Int): SyncValue = when (statement.getColumnType(index)) {
        SQLITE_NULL -> SyncValue.Null
        SQLITE_INTEGER -> SyncValue.Integer(statement.getLong(index))
        SQLITE_FLOAT -> SyncValue.Real(statement.getDouble(index))
        SQLITE_BLOB -> SyncValue.Text(java.util.Base64.getEncoder().encodeToString(statement.getBlob(index)))
        else -> SyncValue.Text(statement.getText(index))
    }

    private companion object {
        const val SQLITE_INTEGER = 1
        const val SQLITE_FLOAT = 2
        const val SQLITE_BLOB = 4
        const val SQLITE_NULL = 5
    }
}
