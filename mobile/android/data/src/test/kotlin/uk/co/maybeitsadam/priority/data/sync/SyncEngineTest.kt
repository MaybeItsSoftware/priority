package uk.co.maybeitsadam.priority.data.sync

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.core.HybridLogicalClock
import uk.co.maybeitsadam.priority.core.SyncValue
import uk.co.maybeitsadam.priority.data.TestClock
import uk.co.maybeitsadam.priority.data.db.Db
import uk.co.maybeitsadam.priority.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.priority.data.workspace.WorkspaceRepository

/** Two simulated devices, two database files, one in-memory server (mirrors sync-tests/SyncEngineTests.swift). */
class SyncEngineTest {
    private val directory: File = Files.createTempDirectory("sync").toFile()
    private val server = InMemorySyncServer()
    private val clock = TestClock()
    private val opened = mutableListOf<WorkspaceDatabase>()

    private inner class Device(name: String, pair: Boolean = true) {
        val file = File(directory, "$name.sqlite")
        val database = WorkspaceDatabase.open(file.path).also { opened += it }
        val repository = WorkspaceRepository(database, clock)
        val sync = SyncStore(database)
        val deviceId = "$name-${UUID.randomUUID().toString().take(4)}"
        val engine = SyncEngine(sync, server.transport(deviceId), deviceId, clock)
        val workspaceId: String

        init {
            workspaceId = runBlocking {
                val workspace = repository.bootstrapIfNeeded()
                if (pair) sync.beginSync(deviceId, "memory://")
                workspace.id
            }
        }

        suspend fun sync() {
            clock.advance(1)
            engine.sync()
        }

        suspend fun titles(): List<String> {
            val workspace = repository.workspaces().first()
            return repository.lists(workspace.id).flatMap { list ->
                repository.outline(list.id).map { it.task.title }
            }.sorted()
        }

        /** Read through a separate plain connection, as the Swift test reads through its own queue. */
        fun foreignKeyViolations(): Int {
            val connection = BundledSQLiteDriver().open(file.path)
            try {
                return Db(connection).query("PRAGMA foreign_key_check") { 1 }.size
            } finally {
                connection.close()
            }
        }
    }

    @After
    fun tearDown() {
        opened.forEach { it.close() }
        directory.deleteRecursively()
    }

    @Test
    fun triggersStayQuietUntilPaired(): Unit = runBlocking {
        val mac = Device("mac", pair = false)
        val inbox = mac.repository.inbox(mac.workspaceId)!!
        mac.repository.createTask(listId = inbox.id, title = "unpaired")
        assertNull(mac.sync.syncState())
        assertEquals(emptyList<SyncOutgoingChange>(), mac.sync.pendingChanges().changes)
    }

    @Test
    fun aSecondDeviceAdoptsTheFirstDevicesWorkspaceAndTheInboxesMerge(): Unit = runBlocking {
        val mac = Device("mac")
        val macInbox = mac.repository.inbox(mac.workspaceId)!!
        val work = mac.repository.createList(mac.workspaceId, "Work")
        val project = mac.repository.createTask(listId = work.id, title = "project")
        mac.repository.createTask(listId = work.id, title = "step", parentTaskId = project.id)
        mac.repository.createTask(listId = macInbox.id, title = "mac inbox")
        mac.sync()

        val phone = Device("phone")
        val phoneInbox = phone.repository.inbox(phone.workspaceId)!!
        phone.repository.createTask(listId = phoneInbox.id, title = "phone inbox")
        phone.sync()
        mac.sync()

        for (device in listOf(mac, phone)) {
            assertEquals(listOf(mac.workspaceId), device.repository.workspaces().map { it.id })
            val inbox = device.repository.inbox(mac.workspaceId)!!
            assertEquals("one Inbox, the first device's", macInbox.id, inbox.id)
            assertEquals(
                listOf("mac inbox", "phone inbox"),
                device.repository.outline(inbox.id).map { it.task.title }.sorted(),
            )
            assertEquals(listOf("mac inbox", "phone inbox", "project", "step"), device.titles())
            assertEquals(0, device.foreignKeyViolations())
            // Both devices seed the same four conditions; adoption keeps one set.
            assertEquals(4, device.repository.conditions(mac.workspaceId).size)
        }
    }

    @Test
    fun concurrentEditsToDifferentFieldsOfOneTaskBothSurvive(): Unit = runBlocking {
        val mac = Device("mac")
        val inbox = mac.repository.inbox(mac.workspaceId)!!
        val task = mac.repository.createTask(listId = inbox.id, title = "draft")
        mac.sync()
        val phone = Device("phone")
        phone.sync()

        mac.repository.updateTask(task.id, title = "final title", notes = "", dueAt = null, estimateSeconds = null)
        phone.repository.updateTask(task.id, title = "draft", notes = "phone notes", dueAt = null, estimateSeconds = null)
        mac.sync()
        phone.sync()
        mac.sync()

        for (device in listOf(mac, phone)) {
            val merged = device.repository.task(task.id)!!
            assertEquals("final title", merged.title)
            assertEquals("phone notes", merged.notes)
        }
    }

    @Test
    fun deletingAParentRemovesTheSubtreeEverywhere(): Unit = runBlocking {
        val mac = Device("mac")
        val list = mac.repository.createList(mac.workspaceId, "Work")
        val parent = mac.repository.createTask(listId = list.id, title = "parent")
        val child = mac.repository.createTask(listId = list.id, title = "child", parentTaskId = parent.id)
        mac.sync()
        val phone = Device("phone")
        phone.sync()
        assertNotNull(phone.repository.task(child.id))

        phone.repository.deleteTask(parent.id)
        phone.sync()
        mac.sync()

        assertNull(mac.repository.task(parent.id))
        assertNull(mac.repository.task(child.id))
        assertEquals(0, mac.foreignKeyViolations())
    }

    @Test
    fun undoingADeleteBringsTheTaskBackEverywhere(): Unit = runBlocking {
        val mac = Device("mac")
        val inbox = mac.repository.inbox(mac.workspaceId)!!
        val task = mac.repository.createTask(listId = inbox.id, title = "keep me")
        mac.sync()
        val phone = Device("phone")
        phone.sync()

        mac.repository.deleteTask(task.id)
        mac.sync()
        phone.sync()
        assertNull(phone.repository.task(task.id))

        mac.repository.undo()
        mac.sync()
        phone.sync()
        assertEquals("keep me", phone.repository.task(task.id)?.title)
    }

    @Test
    fun aTaskAddedToAListDeletedElsewhereIsCleanedUp(): Unit = runBlocking {
        val mac = Device("mac")
        val list = mac.repository.createList(mac.workspaceId, "Doomed")
        mac.sync()
        val phone = Device("phone")
        phone.sync()

        mac.repository.deleteList(list.id)
        val stray = phone.repository.createTask(listId = list.id, title = "stray")
        mac.sync()
        phone.sync()
        mac.sync()

        for (device in listOf(mac, phone)) {
            assertNull(device.repository.task(stray.id))
            assertEquals(0, device.foreignKeyViolations())
        }
    }

    @Test
    fun outboxCoalescesARowsEditsIntoOneChange(): Unit = runBlocking {
        val mac = Device("mac")
        val inbox = mac.repository.inbox(mac.workspaceId)!!
        mac.sync.enqueueSnapshot(clock.instant())
        val snapshot = mac.sync.pendingChanges(limit = 10_000)
        mac.sync.acknowledge(snapshot.throughSeq!!)

        val task = mac.repository.createTask(listId = inbox.id, title = "one")
        mac.repository.updateTask(task.id, title = "two", notes = "", dueAt = null, estimateSeconds = null)
        val pending = mac.sync.pendingChanges().changes.filter { it.table == "tasks" }
        assertEquals(1, pending.size)
        assertEquals(SyncValue.Text("two"), pending.first().values["title"])
        assertEquals("an insert sends every column", SyncValue.Text(inbox.id), pending.first().values["listId"])
    }

    @Test
    fun anUpdateSendsOnlyTheChangedColumnsAndTheKey(): Unit = runBlocking {
        val mac = Device("mac")
        val inbox = mac.repository.inbox(mac.workspaceId)!!
        val task = mac.repository.createTask(listId = inbox.id, title = "one")
        mac.sync()
        mac.repository.updateTask(task.id, title = "two", notes = "", dueAt = null, estimateSeconds = null)
        val change = mac.sync.pendingChanges().changes.single { it.table == "tasks" }
        assertEquals(setOf("id", "title", "updatedAt"), change.values.keys)
    }

    @Test
    fun aRemoteRowIsNotWrittenOverALocalEditStillInTheOutbox(): Unit = runBlocking {
        val mac = Device("mac")
        val inbox = mac.repository.inbox(mac.workspaceId)!!
        val task = mac.repository.createTask(listId = inbox.id, title = "base")
        mac.sync()
        val phone = Device("phone")
        phone.sync()

        mac.repository.updateTask(task.id, title = "from mac", notes = "", dueAt = null, estimateSeconds = null)
        mac.sync()
        phone.repository.updateTask(task.id, title = "from phone", notes = "", dueAt = null, estimateSeconds = null)
        // Pull only: the phone's own edit is still waiting, so the mac's title must not land.
        val page = server.changes(phone.sync.syncState()!!.cursor, 1000)
        phone.sync.applyRemoteRows(page.rows, page.cursor, null, clock.instant())
        assertEquals("from phone", phone.repository.task(task.id)!!.title)

        phone.sync()
        mac.sync()
        assertEquals("from phone", mac.repository.task(task.id)!!.title)
        assertEquals("from phone", phone.repository.task(task.id)!!.title)
    }

    @Test
    fun applyingRemoteRowsWritesNothingToTheOutboxOrTheUndoJournal(): Unit = runBlocking {
        val mac = Device("mac")
        val inbox = mac.repository.inbox(mac.workspaceId)!!
        mac.repository.createTask(listId = inbox.id, title = "one")
        mac.sync()
        val phone = Device("phone")
        phone.sync()
        assertEquals(0, phone.sync.pendingChanges().changes.size)
        assertNull(phone.repository.undoableLabel())
        assertEquals(listOf("one"), phone.titles())
    }

    @Test
    fun clockOrdersByStringAndMovesPastWhatItReceives() {
        val early = HybridLogicalClock(5, 9, "b")
        val later = HybridLogicalClock(6, 0, "a")
        assertTrue(early < later)
        assertTrue(early.toString() < later.toString())
        assertEquals(early, HybridLogicalClock.parse(early.toString()))
        assertEquals("0000000000005-0009-b", early.toString())
        val local = HybridLogicalClock(1, 0, "me")
        val moved = local.receiving(later, 2)
        assertTrue(moved.tick(2) > later)
    }

    /** Mirrors Swift's testTickingOneDailyOnTwoDevicesKeepsOneTickWithTheMostTime: the smaller id wins everywhere. */
    @Test
    fun tickingOneDailyOnTwoDevicesKeepsOneTickWithTheMostTime(): Unit = runBlocking {
        val mac = Device("mac")
        val inbox = mac.repository.inbox(mac.workspaceId)!!
        val task = mac.repository.createTask(listId = inbox.id, title = "stretch")
        val daily = mac.repository.makeDaily(task.id)
        mac.sync()
        val phone = Device("phone")
        phone.sync()

        // Both tick today before either hears of the other.
        mac.repository.logContribution(daily.id, seconds = 600)
        phone.repository.logContribution(daily.id, seconds = 900)
        mac.sync()
        phone.sync()
        mac.sync()
        phone.sync()

        data class Tick(val id: String, val seconds: Long, val completedAt: String?)
        suspend fun ticks(device: Device) = device.database.read { db ->
            db.query("SELECT id, secondsLogged, completedAt FROM daily_contributions") {
                Tick(it.string("id"), it.long("secondsLogged"), it.stringOrNull("completedAt"))
            }
        }
        for (device in listOf(mac, phone)) {
            val rows = ticks(device)
            assertEquals("one tick survives on each device", 1, rows.size)
            assertEquals(900L, rows.first().seconds)
            assertNotNull(rows.first().completedAt)
            assertEquals(0, device.foreignKeyViolations())
        }
        assertEquals(ticks(mac).first().id, ticks(phone).first().id)
    }
}
