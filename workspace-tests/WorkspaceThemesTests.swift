import Foundation
import GRDB
import TaktWorkspace
import XCTest

/// The `themes` and `preferences` tables: synced, unjournalled, and quiet
/// when a write would change nothing.
final class WorkspaceThemesTests: XCTestCase {
  private var directoryURL: URL!
  private var databaseURL: URL!
  private var store: WorkspaceStore!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktThemesTests-\(UUID().uuidString)", isDirectory: true)
    databaseURL = directoryURL.appendingPathComponent("priority.sqlite")
    store = try WorkspaceStore(databaseURL: databaseURL)
    _ = try store.bootstrapIfNeeded()
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testAThemeIsStoredReplacedAndDeleted() throws {
    let first = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(try store.themes(), [])
    XCTAssertTrue(try store.upsertTheme(id: "user.dusk", json: #"{"name":"Dusk"}"#, now: first))
    XCTAssertTrue(try store.upsertTheme(id: "user.amber", json: "{}", now: first))
    XCTAssertEqual(try store.themes().map(\.id), ["user.amber", "user.dusk"])

    let later = first.addingTimeInterval(60)
    XCTAssertFalse(
      try store.upsertTheme(id: "user.dusk", json: #"{"name":"Dusk"}"#, now: later),
      "the same text is not a change")
    XCTAssertEqual(try store.themes().first { $0.id == "user.dusk" }?.updatedAt, first)

    XCTAssertTrue(try store.upsertTheme(id: "user.dusk", json: #"{"name":"Dusker"}"#, now: later))
    let dusk = try XCTUnwrap(try store.themes().first { $0.id == "user.dusk" })
    XCTAssertEqual(dusk.json, #"{"name":"Dusker"}"#)
    XCTAssertEqual(dusk.updatedAt, later)

    XCTAssertTrue(try store.deleteTheme(id: "user.dusk"))
    XCTAssertFalse(try store.deleteTheme(id: "user.dusk"))
    XCTAssertEqual(try store.themes().map(\.id), ["user.amber"])
  }

  func testAPreferenceIsSetChangedAndCleared() throws {
    XCTAssertNil(try store.preference(WorkspacePreferenceKey.themeSelected))
    XCTAssertTrue(try store.setPreference(WorkspacePreferenceKey.themeSelected, "user.dusk"))
    XCTAssertFalse(try store.setPreference(WorkspacePreferenceKey.themeSelected, "user.dusk"))
    XCTAssertEqual(try store.preference(WorkspacePreferenceKey.themeSelected), "user.dusk")

    XCTAssertTrue(try store.setPreference(WorkspacePreferenceKey.themeAppearance, "dark"))
    XCTAssertTrue(try store.setPreference(WorkspacePreferenceKey.themeSelected, nil))
    XCTAssertFalse(try store.setPreference(WorkspacePreferenceKey.themeSelected, nil))
    XCTAssertNil(try store.preference(WorkspacePreferenceKey.themeSelected))

    let all = try store.preferences()
    XCTAssertEqual(all.count, 2, "a cleared key is kept, as null")
    XCTAssertEqual(all[WorkspacePreferenceKey.themeAppearance], .some("dark"))
    XCTAssertEqual(all[WorkspacePreferenceKey.themeSelected], .some(nil))
  }

  /// Neither table is in the undo journal: a theme edit is not a step ⌘Z in
  /// the task list takes back.
  func testThemesAndPreferencesAreNotUndoSteps() throws {
    let before = try store.undoableLabel()
    try store.upsertTheme(id: "user.dusk", json: "{}")
    try store.setPreference(WorkspacePreferenceKey.themeSelected, "user.dusk")
    XCTAssertEqual(try store.undoableLabel(), before)
    let journalled = try DatabaseQueue(path: databaseURL.path).read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM change_log WHERE tableName IN ('themes', 'preferences')")
    }
    XCTAssertEqual(journalled, 0)
  }

  /// Both tables are synced: a paired device queues their writes, keyed by
  /// `id` and `key`, and only real changes are queued.
  func testThemesAndPreferencesReachTheSyncOutbox() throws {
    try store.beginSync(deviceId: "device-a", serverURL: "https://sync.example")
    try store.enqueueSyncSnapshot()
    if let seq = try store.latestSyncOutboxSeq() { try store.acknowledgeSyncChanges(throughSeq: seq) }

    try store.upsertTheme(id: "user.dusk", json: #"{"name":"Dusk"}"#)
    try store.upsertTheme(id: "user.dusk", json: #"{"name":"Dusk"}"#)
    try store.setPreference(WorkspacePreferenceKey.themeSelected, "user.dusk")

    let pending = try store.pendingSyncChanges().changes
    XCTAssertEqual(pending.map(\.table).sorted(), ["preferences", "themes"])
    let theme = try XCTUnwrap(pending.first { $0.table == "themes" })
    XCTAssertEqual(theme.rowId, "user.dusk")
    XCTAssertEqual(theme.values["json"], .text(#"{"name":"Dusk"}"#))
    let preference = try XCTUnwrap(pending.first { $0.table == "preferences" })
    XCTAssertEqual(preference.rowId, WorkspacePreferenceKey.themeSelected)
    XCTAssertEqual(preference.values["value"], .text("user.dusk"))

    try store.acknowledgeSyncChanges(throughSeq: try XCTUnwrap(store.latestSyncOutboxSeq()))
    try store.deleteTheme(id: "user.dusk")
    let deletion = try XCTUnwrap(try store.pendingSyncChanges().changes.first)
    XCTAssertEqual(deletion.operation, .delete)
    XCTAssertEqual(deletion.rowId, "user.dusk")
  }

  func testTheSnapshotIncludesThemesAndPreferences() throws {
    try store.upsertTheme(id: "user.dusk", json: "{}")
    try store.setPreference(WorkspacePreferenceKey.themeAppearance, "light")
    try store.beginSync(deviceId: "device-a", serverURL: "https://sync.example")
    try store.enqueueSyncSnapshot()
    let tables = Set(try store.pendingSyncChanges(limit: 10_000).changes.map(\.table))
    XCTAssertTrue(tables.isSuperset(of: ["themes", "preferences"]), "\(tables)")
  }

  func testRemoteRowsLandInBothTables() throws {
    try store.beginSync(deviceId: "device-a", serverURL: "https://sync.example")
    try store.applyRemoteRows(
      [
        SyncIncomingRow(
          table: "themes", id: "user.remote", deleted: false,
          values: ["id": .text("user.remote"), "json": .text("{}"), "updatedAt": .text("2026-10-02 09:00:00.000")]),
        SyncIncomingRow(
          table: "preferences", id: WorkspacePreferenceKey.themeSelected, deleted: false,
          values: [
            "key": .text(WorkspacePreferenceKey.themeSelected), "value": .text("user.remote"),
            "updatedAt": .text("2026-10-02 09:00:00.000"),
          ]),
      ], cursor: 2, hlc: nil)
    XCTAssertEqual(try store.themes().map(\.id), ["user.remote"])
    XCTAssertEqual(try store.preference(WorkspacePreferenceKey.themeSelected), "user.remote")
    XCTAssertEqual(try store.pendingSyncChanges().changes, [], "applied rows are not echoed back")
  }
}
