import Foundation
import GRDB
import PrioritySync
import PriorityWorkspace
import XCTest

/// The client cycle from `docs/sync.md`, run between real stores through a
/// server that keeps the spec's merge rules in memory. Each test is two or
/// three devices editing, syncing and agreeing.
final class SyncEngineTests: XCTestCase {
  private var directory: URL!
  private var server: InMemorySyncServer!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sync-\(UUID().uuidString)")
    server = InMemorySyncServer()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private struct Device {
    let store: WorkspaceStore
    let engine: SyncEngine
    let workspaceID: String
    let url: URL
  }

  private func device(_ name: String, pair: Bool = true) throws -> Device {
    let url = directory.appendingPathComponent("\(name).sqlite")
    let store = try WorkspaceStore(databaseURL: url)
    let workspace = try store.bootstrapIfNeeded()
    let deviceID = "\(name)-\(UUID().uuidString.prefix(4))"
    if pair { try store.beginSync(deviceId: deviceID, serverURL: "memory://") }
    let engine = SyncEngine(store: store, transport: server.transport(for: deviceID), deviceId: deviceID)
    return Device(store: store, engine: engine, workspaceID: workspace.id, url: url)
  }

  private func titles(_ device: Device) throws -> [String] {
    let lists = try device.store.lists(in: device.store.workspaces()[0].id)
    return try lists.flatMap { try device.store.outline(in: $0.id).map(\.task.title) }.sorted()
  }

  private func contributions(_ device: Device) throws -> [Row] {
    let queue = try DatabaseQueue(path: device.url.path)
    return try queue.read { try Row.fetchAll($0, sql: "SELECT id, secondsLogged, completedAt FROM daily_contributions") }
  }

  private func foreignKeyViolations(_ device: Device) throws -> Int {
    let queue = try DatabaseQueue(path: device.url.path)
    return try queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
  }

  func testTriggersStayQuietUntilPaired() throws {
    let mac = try device("mac", pair: false)
    let inbox = try XCTUnwrap(mac.store.inbox(in: mac.workspaceID))
    _ = try mac.store.createTask(listId: inbox.id, title: "unpaired")
    XCTAssertNil(try mac.store.syncState())
    XCTAssertEqual(try mac.store.pendingSyncChanges().changes, [])
  }

  func testASecondDeviceAdoptsTheFirstDevicesWorkspace() async throws {
    let mac = try device("mac")
    let macInbox = try XCTUnwrap(mac.store.inbox(in: mac.workspaceID))
    let work = try mac.store.createList(workspaceId: mac.workspaceID, name: "Work")
    let project = try mac.store.createTask(listId: work.id, title: "project")
    _ = try mac.store.createTask(listId: work.id, title: "step", parentTaskId: project.id)
    _ = try mac.store.createTask(listId: macInbox.id, title: "mac inbox")
    try await mac.engine.sync()

    let phone = try device("phone")
    let phoneInbox = try XCTUnwrap(phone.store.inbox(in: phone.workspaceID))
    _ = try phone.store.createTask(listId: phoneInbox.id, title: "phone inbox")
    try await phone.engine.sync()
    try await mac.engine.sync()

    for device in [mac, phone] {
      XCTAssertEqual(try device.store.workspaces().map(\.id), [mac.workspaceID])
      let inbox = try XCTUnwrap(device.store.inbox(in: mac.workspaceID))
      XCTAssertEqual(inbox.id, macInbox.id, "one Inbox, the first device's")
      XCTAssertEqual(
        try device.store.outline(in: inbox.id).map(\.task.title).sorted(), ["mac inbox", "phone inbox"])
      XCTAssertEqual(try titles(device), ["mac inbox", "phone inbox", "project", "step"])
      XCTAssertEqual(try foreignKeyViolations(device), 0)
    }
  }

  func testConcurrentEditsToDifferentFieldsBothSurvive() async throws {
    let mac = try device("mac")
    let inbox = try XCTUnwrap(mac.store.inbox(in: mac.workspaceID))
    let task = try mac.store.createTask(listId: inbox.id, title: "draft")
    try await mac.engine.sync()
    let phone = try device("phone")
    try await phone.engine.sync()

    try mac.store.updateTask(id: task.id, title: "final title", notes: "", dueAt: nil, estimateSeconds: nil)
    try phone.store.updateTask(id: task.id, title: "draft", notes: "phone notes", dueAt: nil, estimateSeconds: nil)
    try await mac.engine.sync()
    try await phone.engine.sync()
    try await mac.engine.sync()

    for device in [mac, phone] {
      let merged = try XCTUnwrap(device.store.task(id: task.id))
      XCTAssertEqual(merged.title, "final title")
      XCTAssertEqual(merged.notes, "phone notes")
    }
  }

  func testDeletingAParentRemovesTheSubtreeEverywhere() async throws {
    let mac = try device("mac")
    let list = try mac.store.createList(workspaceId: mac.workspaceID, name: "Work")
    let parent = try mac.store.createTask(listId: list.id, title: "parent")
    let child = try mac.store.createTask(listId: list.id, title: "child", parentTaskId: parent.id)
    try await mac.engine.sync()
    let phone = try device("phone")
    try await phone.engine.sync()
    XCTAssertNotNil(try phone.store.task(id: child.id))

    try phone.store.deleteTask(id: parent.id)
    try await phone.engine.sync()
    try await mac.engine.sync()

    XCTAssertNil(try mac.store.task(id: parent.id))
    XCTAssertNil(try mac.store.task(id: child.id))
  }

  func testUndoingADeleteBringsTheTaskBackEverywhere() async throws {
    let mac = try device("mac")
    let inbox = try XCTUnwrap(mac.store.inbox(in: mac.workspaceID))
    let task = try mac.store.createTask(listId: inbox.id, title: "keep me")
    try await mac.engine.sync()
    let phone = try device("phone")
    try await phone.engine.sync()

    try mac.store.deleteTask(id: task.id)
    try await mac.engine.sync()
    try await phone.engine.sync()
    XCTAssertNil(try phone.store.task(id: task.id))

    try mac.store.undo()
    try await mac.engine.sync()
    try await phone.engine.sync()
    XCTAssertEqual(try phone.store.task(id: task.id)?.title, "keep me")
  }

  func testATaskAddedToAListDeletedElsewhereIsCleanedUp() async throws {
    let mac = try device("mac")
    let list = try mac.store.createList(workspaceId: mac.workspaceID, name: "Doomed")
    try await mac.engine.sync()
    let phone = try device("phone")
    try await phone.engine.sync()

    try mac.store.deleteList(id: list.id)
    let stray = try phone.store.createTask(listId: list.id, title: "stray")
    try await mac.engine.sync()
    try await phone.engine.sync()
    try await mac.engine.sync()

    for device in [mac, phone] {
      XCTAssertNil(try device.store.task(id: stray.id))
      XCTAssertEqual(try foreignKeyViolations(device), 0)
    }
  }

  func testTickingOneDailyOnTwoDevicesKeepsOneTickWithTheMostTime() async throws {
    let mac = try device("mac")
    let inbox = try XCTUnwrap(mac.store.inbox(in: mac.workspaceID))
    let task = try mac.store.createTask(listId: inbox.id, title: "stretch")
    let daily = try mac.store.makeDaily(taskId: task.id)
    try await mac.engine.sync()
    let phone = try device("phone")
    try await phone.engine.sync()

    // Both tick today before either hears of the other.
    _ = try mac.store.logContribution(dailyId: daily.id, seconds: 600)
    _ = try phone.store.logContribution(dailyId: daily.id, seconds: 900)
    try await mac.engine.sync()
    try await phone.engine.sync()
    try await mac.engine.sync()
    try await phone.engine.sync()

    for device in [mac, phone] {
      let rows = try contributions(device)
      XCTAssertEqual(rows.count, 1, "one tick survives on each device")
      XCTAssertEqual(rows.first?["secondsLogged"] as Int64?, 900)
      XCTAssertNotNil(rows.first?["completedAt"] as String?)
    }
    XCTAssertEqual(try contributions(mac).first?["id"] as String?, try contributions(phone).first?["id"] as String?)
  }

  /// A theme file saved on one device and the choice of it reach the other,
  /// and a deletion follows them.
  func testAThemeAndTheChoiceOfItReachTheOtherDevice() async throws {
    let mac = try device("mac")
    try mac.store.upsertTheme(id: "user.dusk", json: #"{ "name": "Dusk" }"#)
    try mac.store.setPreference(WorkspacePreferenceKey.themeSelected, "user.dusk")
    try mac.store.setPreference(WorkspacePreferenceKey.themeAppearance, "dark")
    try await mac.engine.sync()
    let phone = try device("phone")
    try await phone.engine.sync()

    XCTAssertEqual(try phone.store.themes().map(\.json), [#"{ "name": "Dusk" }"#])
    XCTAssertEqual(try phone.store.preference(WorkspacePreferenceKey.themeSelected), "user.dusk")
    XCTAssertEqual(try phone.store.preference(WorkspacePreferenceKey.themeAppearance), "dark")

    // The phone changes its mind; the Mac hears of it.
    try phone.store.setPreference(WorkspacePreferenceKey.themeAppearance, "system")
    try phone.store.setPreference(WorkspacePreferenceKey.themeSelected, nil)
    try await phone.engine.sync()
    try await mac.engine.sync()
    XCTAssertEqual(try mac.store.preference(WorkspacePreferenceKey.themeAppearance), "system")
    XCTAssertNil(try mac.store.preference(WorkspacePreferenceKey.themeSelected))

    try mac.store.deleteTheme(id: "user.dusk")
    try await mac.engine.sync()
    try await phone.engine.sync()
    XCTAssertEqual(try phone.store.themes(), [])
  }

  func testOutboxCoalescesARowsEditsIntoOneChange() throws {
    let mac = try device("mac")
    let inbox = try XCTUnwrap(mac.store.inbox(in: mac.workspaceID))
    try mac.store.enqueueSyncSnapshot()
    let snapshot = try mac.store.pendingSyncChanges(limit: 10_000)
    try mac.store.acknowledgeSyncChanges(throughSeq: try XCTUnwrap(snapshot.throughSeq))

    let task = try mac.store.createTask(listId: inbox.id, title: "one")
    try mac.store.updateTask(id: task.id, title: "two", notes: "", dueAt: nil, estimateSeconds: nil)
    let pending = try mac.store.pendingSyncChanges().changes.filter { $0.table == "tasks" }
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending.first?.values["title"], .text("two"))
    XCTAssertEqual(pending.first?.values["listId"], .text(inbox.id), "an insert sends every column")
  }

  func testClockOrdersByStringAndMovesPastWhatItReceives() {
    let early = HybridLogicalClock(milliseconds: 5, counter: 9, deviceId: "b")
    let later = HybridLogicalClock(milliseconds: 6, counter: 0, deviceId: "a")
    XCTAssertLessThan(early, later)
    XCTAssertEqual(HybridLogicalClock(early.description), early)
    let local = HybridLogicalClock(milliseconds: 1, counter: 0, deviceId: "me")
    let moved = local.receiving(later, wallMilliseconds: 2)
    XCTAssertGreaterThan(moved.tick(wallMilliseconds: 2), later)
  }
}

/// The server's merge rules from `docs/sync.md`, in memory: per-column
/// last-write-wins, deletes that win over older edits, and resurrection by a
/// newer upsert.
final class InMemorySyncServer: @unchecked Sendable {
  struct Stored {
    var data: [String: SyncValue] = [:]
    var columnClocks: [String: String] = [:]
    var deleted = false
    var deletedClock: String?
    var seq: Int64 = 0
    var lastDevice: String?
  }

  private let lock = NSLock()
  private var rows: [String: Stored] = [:]
  private var seq: Int64 = 0

  func transport(for device: String) -> any SyncTransport { Transport(server: self, device: device) }

  struct Transport: SyncTransport {
    let server: InMemorySyncServer
    let device: String
    func push(_ changes: [SyncPushChange]) async throws -> SyncPushResponse {
      server.push(changes, device: device)
    }
    func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesResponse {
      server.changes(since: cursor, limit: limit, device: device)
    }
  }

  func push(_ changes: [SyncPushChange], device: String) -> SyncPushResponse {
    lock.withLock {
      for change in changes {
        let key = change.table + "/" + change.id
        var row = rows[key] ?? Stored()
        let before = (row.data, row.deleted)
        var everyColumnWon = true
        if change.op == "delete" {
          if row.columnClocks.values.allSatisfy({ change.hlc > $0 }) {
            row.deleted = true
            row.deletedClock = change.hlc
          } else {
            everyColumnWon = false
          }
        } else {
          if row.deleted, let deletedClock = row.deletedClock, change.hlc <= deletedClock { continue }
          row.deleted = false
          for (column, value) in change.values ?? [:] {
            if let clock = row.columnClocks[column], clock >= change.hlc {
              everyColumnWon = false
              continue
            }
            row.data[column] = value
            row.columnClocks[column] = change.hlc
          }
        }
        if before.0 != row.data || before.1 != row.deleted || rows[key] == nil {
          seq += 1
          row.seq = seq
          row.lastDevice = everyColumnWon ? device : nil
        }
        rows[key] = row
      }
      return SyncPushResponse(accepted: changes.count, cursor: seq)
    }
  }

  func changes(since cursor: Int64, limit: Int, device: String) -> SyncChangesResponse {
    lock.withLock {
      let newer = rows.filter { $0.value.seq > cursor }.sorted { $0.value.seq < $1.value.seq }
      let page = newer.prefix(limit)
      let rows = page.map { key, row in
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return SyncIncomingRow(
          table: parts[0], id: parts[1], deleted: row.deleted, values: row.data,
          hlc: ([row.deletedClock].compactMap { $0 } + row.columnClocks.values).max())
      }
      return SyncChangesResponse(
        rows: rows, cursor: page.last?.value.seq ?? cursor, hasMore: newer.count > limit)
    }
  }
}
