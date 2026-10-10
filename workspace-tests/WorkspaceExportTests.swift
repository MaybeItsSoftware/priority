import Foundation
import TaktWorkspace
import XCTest

/// The export moved from the Mac (`WorkspaceViewModel+Export.swift`) into the
/// Rust core. Its files have to stay the ones the Mac wrote, so this keeps
/// the Mac's builder as the oracle: Foundation's `JSONEncoder` over the
/// store's own models, and the Markdown loop as it was, and holds the core's
/// document to it byte for byte on a workspace with every field set and unset
/// and every string the two encoders might disagree on.
final class WorkspaceExportTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var workspace: Workspace!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)")
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
    workspace = try store.bootstrapIfNeeded(now: Date(timeIntervalSince1970: 1_759_000_000.123))
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private let base = Date(timeIntervalSince1970: 1_759_100_000.875)

  private func seed() throws {
    let folder = try store.createFolder(workspaceId: workspace.id, name: "Area / one", now: base)
    let work = try store.createList(
      workspaceId: workspace.id, name: "Work \"main\" / ☕️", folderId: folder.id, now: base)
    let old = try store.createList(workspaceId: workspace.id, name: "Old", now: base.addingTimeInterval(1))
    let done = try store.createList(workspaceId: workspace.id, name: "Done", now: base.addingTimeInterval(2))
    _ = try store.createList(workspaceId: workspace.id, name: "Empty", now: base.addingTimeInterval(3))

    let plan = try store.createTask(listId: work.id, title: "Plan the week", now: base)
    try store.updateTask(
      id: plan.id, title: "Plan the week",
      notes: "First line\n\nSecond \\ line\ttab\r\nwindows\n\u{1}control \u{2028} é😀 a/b \"q\"\n",
      dueAt: base.addingTimeInterval(86_400.5), estimateSeconds: 1_800, now: base.addingTimeInterval(5))
    let step = try store.createTask(
      listId: work.id, title: "Step </tag>", parentTaskId: plan.id, now: base.addingTimeInterval(6))
    let deep = try store.createTask(
      listId: work.id, title: "Deep", parentTaskId: step.id, estimateSeconds: 0, now: base.addingTimeInterval(7))
    try store.setStatus(.completed, for: deep.id, now: base.addingTimeInterval(8.999))
    let dropped = try store.createTask(
      listId: work.id, title: "Dropped", parentTaskId: plan.id, now: base.addingTimeInterval(9))
    try store.setStatus(.cancelled, for: dropped.id, now: base.addingTimeInterval(10))
    let reading = try store.createTask(listId: work.id, title: "Reading", kind: .list, now: base.addingTimeInterval(11))
    try store.setNestedListPromoted(true, id: reading.id, now: base.addingTimeInterval(12))
    let shelved = try store.createTask(listId: work.id, title: "Shelved", kind: .list, now: base.addingTimeInterval(13))
    try store.setNestedListArchived(true, id: shelved.id, now: base.addingTimeInterval(14))
    _ = try store.createTask(listId: work.id, title: #"C:\path  "#, now: base.addingTimeInterval(15))

    let wrapper = try store.createTask(listId: old.id, title: "Wrapper", kind: .list, now: base)
    _ = try store.createTask(listId: old.id, title: "Inside", parentTaskId: wrapper.id, now: base)
    try store.saveListSettings(
      id: old.id, name: "Old", colorHex: "#d62246", folderId: nil, isArchived: true,
      visibleRootTaskId: wrapper.id, now: base.addingTimeInterval(20))

    _ = try store.createTask(listId: done.id, title: "Finished", now: base)
    try store.setListCompleted(true, id: done.id, now: base.addingTimeInterval(30.5))
  }

  func testTheCoreWritesTheJSONTheMacWrote() throws {
    try seed()
    let at = Date(timeIntervalSince1970: 1_759_752_000.75)
    let document = try XCTUnwrap(store.exportDocument(workspaceId: workspace.id, format: .json, exportedAt: at))
    XCTAssertEqual(document, try Oracle.json(Oracle.snapshot(store, workspace, at)))
    XCTAssertTrue(document.contains(#"\/"#), "the Mac escaped slashes")
  }

  func testTheCoreWritesTheMarkdownTheMacWrote() throws {
    try seed()
    let at = Date(timeIntervalSince1970: 1_759_752_000)
    let document = try XCTUnwrap(store.exportDocument(workspaceId: workspace.id, format: .markdown, exportedAt: at))
    XCTAssertEqual(document, Oracle.markdown(try Oracle.snapshot(store, workspace, at)))
    XCTAssertTrue(document.contains("## Old (archived)"))
  }

  func testAFreshWorkspaceMatchesToo() throws {
    let at = Date(timeIntervalSince1970: 0)
    for format in WorkspaceExportFormat.allCases {
      let document = try XCTUnwrap(store.exportDocument(workspaceId: workspace.id, format: format, exportedAt: at))
      let snapshot = try Oracle.snapshot(store, workspace, at)
      XCTAssertEqual(document, format == .json ? try Oracle.json(snapshot) : Oracle.markdown(snapshot))
    }
  }

  func testAMissingWorkspaceHasNoDocument() throws {
    XCTAssertNil(try store.exportDocument(workspaceId: "missing", format: .json))
  }

  func testTheFormatsNameTheirFiles() {
    XCTAssertEqual(WorkspaceExportFormat.allCases.map(\.fileExtension), ["md", "json"])
    XCTAssertEqual(WorkspaceExportFormat.allCases.map(\.title), ["Markdown", "JSON"])
  }
}

/// The Mac's export as it was before it moved into the core.
private enum Oracle {
  struct ExportedList: Encodable {
    let list: TaskList
    let tasks: [WorkspaceTask]
  }

  struct ExportSnapshot: Encodable {
    let exportedAt: Date
    let workspace: String
    let lists: [ExportedList]
  }

  static func snapshot(_ store: WorkspaceStore, _ workspace: Workspace, _ at: Date) throws -> ExportSnapshot {
    func walk(_ listId: String, _ parent: String?) throws -> [WorkspaceTask] {
      try store.tasks(in: listId, parentTaskId: parent).flatMap { task in [task] + (try walk(listId, task.id)) }
    }
    return ExportSnapshot(
      exportedAt: at, workspace: workspace.name,
      lists: try store.lists(in: workspace.id, includingArchived: true).map { list in
        ExportedList(list: list, tasks: try walk(list.id, nil))
      })
  }

  static func json(_ snapshot: ExportSnapshot) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return String(bytes: try encoder.encode(snapshot), encoding: .utf8) ?? ""
  }

  static func markdown(_ snapshot: ExportSnapshot) -> String {
    var lines = ["# \(snapshot.workspace)", ""]
    for entry in snapshot.lists {
      let suffix = entry.list.isArchived ? " (archived)" : ""
      lines.append("## \(entry.list.name)\(suffix)")
      lines.append("")
      var depth: [String: Int] = [:]
      for task in entry.tasks {
        let level = task.parentTaskId.flatMap { depth[$0].map { $0 + 1 } } ?? 0
        depth[task.id] = level
        let box = task.status == .open ? "[ ]" : "[x]"
        let indent = String(repeating: "  ", count: level)
        lines.append("\(indent)- \(box) \(task.title)")
        for note in task.notes.split(separator: "\n", omittingEmptySubsequences: true) {
          lines.append("\(indent)  > \(note)")
        }
      }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }
}
