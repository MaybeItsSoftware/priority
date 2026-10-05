import Foundation
import TaktCore
import XCTest

@testable import TaktPlugins

/// A stand-in for a running `affine-mcp`: it records what was asked of it and
/// answers with the shapes the real server's output schemas promise.
private final class StubToolCaller: AFFiNEToolCalling, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [String: [JSONValue]] = [:]
  private var recorded: [(tool: String, arguments: [String: JSONValue])] = []

  var calls: [(tool: String, arguments: [String: JSONValue])] {
    lock.withLock { recorded }
  }

  var toolNames: [String] { calls.map(\.tool) }

  func arguments(for tool: String) -> [String: JSONValue]? {
    calls.last(where: { $0.tool == tool })?.arguments
  }

  /// Queued in order, so a tool called twice in one flow can answer differently
  /// the second time.
  func stub(_ tool: String, _ values: JSONValue...) {
    lock.withLock { responses[tool, default: []].append(contentsOf: values) }
  }

  func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
    let value = lock.withLock { () -> JSONValue in
      recorded.append((name, arguments))
      let queued = responses[name] ?? []
      if queued.count > 1 { responses[name] = Array(queued.dropFirst()) }
      return queued.first ?? .object([:])
    }

    if MCPWire.toolResultIsError(value) {
      throw AFFiNEMCPError.toolFailed(tool: name, message: MCPWire.toolResultText(value))
    }
    return value
  }
}

private func structured(_ fields: [String: JSONValue]) -> JSONValue {
  .object(["structuredContent": .object(fields)])
}

@MainActor
final class NativeAFFiNEIntegrationPluginTests: XCTestCase {

  private var suiteName = ""
  private var defaults = UserDefaults.standard
  private var caller = StubToolCaller()

  override func setUp() {
    super.setUp()
    suiteName = "affine-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName) ?? .standard
    caller = StubToolCaller()
  }

  override func tearDown() {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func makePlugin() -> NativeAFFiNEIntegrationPlugin {
    let stub = caller
    return NativeAFFiNEIntegrationPlugin(
      service: AFFiNEExportService(defaults: defaults, makeCaller: { stub })
    )
  }

  private func task(
    id: Int = 42,
    content: String = "Write the release notes",
    notes: [String] = ["Mention the CLI."],
    updatedAt: String? = "2026-08-18 10:00:00 +0000"
  ) -> CheckvistTask {
    CheckvistTask(
      id: id,
      content: content,
      status: 0,
      due: nil,
      notes: notes.map { CheckvistNote(id: nil, content: $0, createdAt: nil, updatedAt: nil) },
      updatedAt: updatedAt
    )
  }

  // MARK: - Checklist

  private func checklistDoc(_ markdown: String, exists: Bool = true, lossy: Bool = false)
    -> JSONValue
  {
    structured([
      "markdown": .string(markdown),
      "exists": .bool(exists),
      "lossy": .bool(lossy),
    ])
  }

  func testAFirstSyncCreatesTheListsDocumentWithItsTasks() async throws {
    caller.stub("find_doc_by_title", structured(["matches": .array([])]))
    caller.stub("create_doc_from_markdown", structured(["docId": .string("list-doc")]))

    let plugin = makePlugin()
    let outcome = try await plugin.syncChecklist(
      tasks: [task(id: 34, content: "Write the release notes")],
      listId: "12",
      listTitle: "Work",
      closingTicked: { _ in XCTFail("nothing was ticked"); return [] }
    )

    XCTAssertEqual(outcome.document.docId, "list-doc")
    XCTAssertTrue(outcome.closedTaskIds.isEmpty)

    let arguments = try XCTUnwrap(caller.arguments(for: "create_doc_from_markdown"))
    XCTAssertEqual(arguments["title"]?.stringValue, "Work")
    let markdown = try XCTUnwrap(arguments["markdown"]?.stringValue)
    XCTAssertTrue(markdown.contains("## Tasks"))
    XCTAssertTrue(
      markdown.contains("- [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)"))
  }

  /// The point of the whole design: tick it in AFFiNE, and it closes here.
  func testATickedBoxClosesTheTaskAndDisappearsFromTheChecklist() async throws {
    caller.stub("find_doc_by_title", structured(["matches": .array([.object(["id": .string("d1")])])]))
    caller.stub(
      "export_doc_markdown",
      checklistDoc(
        """
        ## Tasks

        - [x] [Ship the DMG](https://checkvist.com/checklists/12#t31)
        - [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)
        """))
    caller.stub("replace_doc_with_markdown", structured(["docId": .string("d1")]))

    var closed: [Int] = []
    let outcome = try await makePlugin().syncChecklist(
      tasks: [task(id: 31, content: "Ship the DMG"), task(id: 34, content: "Write the release notes")],
      listId: "12",
      listTitle: "Work",
      closingTicked: { ticked in
        closed = ticked
        // What the repository looks like once the close has landed.
        return [self.task(id: 34, content: "Write the release notes")]
      }
    )

    XCTAssertEqual(closed, [31])
    XCTAssertEqual(outcome.closedTaskIds, [31])

    let markdown = try XCTUnwrap(
      caller.arguments(for: "replace_doc_with_markdown")?["markdown"]?.stringValue)
    XCTAssertFalse(markdown.contains("#t31"), "a closed task leaves the checklist")
    XCTAssertTrue(markdown.contains("#t34"))
  }

  /// Ticks are read before the write, and the write reflects the closes. The
  /// other order would put every ticked box straight back.
  func testTheChecklistIsWrittenAfterTheClosesLand() async throws {
    caller.stub("find_doc_by_title", structured(["matches": .array([.object(["id": .string("d1")])])]))
    caller.stub(
      "export_doc_markdown",
      checklistDoc("## Tasks\n\n- [x] [Ship](https://checkvist.com/checklists/12#t31)"))
    caller.stub("replace_doc_with_markdown", structured(["docId": .string("d1")]))

    var closeHadRun = false
    _ = try await makePlugin().syncChecklist(
      tasks: [task(id: 31, content: "Ship")],
      listId: "12",
      listTitle: "Work",
      closingTicked: { _ in
        XCTAssertFalse(
          self.caller.toolNames.contains("replace_doc_with_markdown"),
          "the document must not be written before the close")
        closeHadRun = true
        return []
      }
    )

    XCTAssertTrue(closeHadRun)
    XCTAssertEqual(caller.toolNames.last, "replace_doc_with_markdown")
  }

  /// AFFiNE's exporter backslash-escapes punctuation, so the text never comes
  /// back the way it was sent. Comparing text rather than items would rewrite
  /// the document on every sync forever.
  func testAnUnchangedListIsNotRewrittenDespiteEscaping() async throws {
    caller.stub("find_doc_by_title", structured(["matches": .array([.object(["id": .string("d1")])])]))
    caller.stub(
      "export_doc_markdown",
      checklistDoc(
        "## Tasks\n\n- [ ] [Ship the DMG \\(v1\\.2\\)](https://checkvist.com/checklists/12#t31)"
      ))

    let outcome = try await makePlugin().syncChecklist(
      tasks: [task(id: 31, content: "Ship the DMG (v1.2)")],
      listId: "12",
      listTitle: "Work",
      closingTicked: { _ in [] }
    )

    XCTAssertFalse(outcome.document.didWrite)
    XCTAssertFalse(caller.toolNames.contains("replace_doc_with_markdown"))
  }

  func testWhatSomeoneTypedIntoTheSectionIsPutBack() async throws {
    caller.stub("find_doc_by_title", structured(["matches": .array([.object(["id": .string("d1")])])]))
    caller.stub(
      "export_doc_markdown",
      checklistDoc(
        """
        Morning notes.

        ## Tasks

        - [ ] [Ship](https://checkvist.com/checklists/12#t31)
        - [ ] buy milk

        ## Evening

        Read two chapters.
        """))
    caller.stub("replace_doc_with_markdown", structured(["docId": .string("d1")]))

    _ = try await makePlugin().syncChecklist(
      tasks: [task(id: 31, content: "Ship"), task(id: 34, content: "New task")],
      listId: "12",
      listTitle: "Work",
      closingTicked: { _ in [] }
    )

    let markdown = try XCTUnwrap(
      caller.arguments(for: "replace_doc_with_markdown")?["markdown"]?.stringValue)
    XCTAssertTrue(markdown.contains("- [ ] buy milk"), "a hand-written item is not ours to delete")
    XCTAssertTrue(markdown.contains("Morning notes."))
    XCTAssertTrue(markdown.contains("## Evening"))
    XCTAssertTrue(markdown.contains("#t34"))
  }

  /// The exporter renders a block it cannot describe as a comment, so writing
  /// the document back would delete that block. Refusing is the only safe move.
  func testADocumentWithBlocksMarkdownCannotCarryIsNotRewritten() async {
    caller.stub("find_doc_by_title", structured(["matches": .array([.object(["id": .string("d1")])])]))
    caller.stub("export_doc_markdown", checklistDoc("## Tasks\n\n- [ ] x", lossy: true))

    do {
      _ = try await makePlugin().syncChecklist(
        tasks: [], listId: "12", listTitle: "Work", closingTicked: { _ in [] })
      XCTFail("expected the sync to refuse")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("cannot rewrite safely"))
    }
    XCTAssertFalse(caller.toolNames.contains("replace_doc_with_markdown"))
  }

  /// A checklist document deleted in AFFiNE is forgotten rather than written
  /// into, which would put the list somewhere nobody can see.
  /// A checklist document deleted in AFFiNE is forgotten rather than written
  /// into, which would put the list somewhere nobody can see.
  func testADeletedChecklistDocumentIsForgottenAndRemade() async throws {
    // Queued in order: the first sync finds and writes d1; by the second, the
    // document is gone and nothing answers by title.
    caller.stub(
      "find_doc_by_title",
      structured(["matches": .array([.object(["id": .string("d1")])])]),
      structured(["matches": .array([])]))
    caller.stub(
      "export_doc_markdown",
      checklistDoc("## Tasks\n\n- [ ] x"),
      checklistDoc("", exists: false))
    caller.stub("replace_doc_with_markdown", structured(["docId": .string("d1")]))
    caller.stub("create_doc_from_markdown", structured(["docId": .string("d2")]))

    let plugin = makePlugin()
    let first = try await plugin.syncChecklist(
      tasks: [task(id: 34, content: "First")], listId: "12", listTitle: "Work",
      closingTicked: { _ in [] })
    XCTAssertEqual(first.document.docId, "d1")

    let second = try await plugin.syncChecklist(
      tasks: [task(id: 34, content: "First")], listId: "12", listTitle: "Work",
      closingTicked: { _ in [] })

    XCTAssertEqual(second.document.docId, "d2")
  }

  func testAnOfflineListStillGetsAChecklist() async throws {
    caller.stub("find_doc_by_title", structured(["matches": .array([])]))
    caller.stub("create_doc_from_markdown", structured(["docId": .string("offline-doc")]))

    _ = try await makePlugin().syncChecklist(
      tasks: [task(id: -3, content: "Offline task", updatedAt: nil)],
      listId: "",
      listTitle: "",
      closingTicked: { _ in [] }
    )

    let arguments = try XCTUnwrap(caller.arguments(for: "create_doc_from_markdown"))
    XCTAssertEqual(arguments["title"]?.stringValue, "Priority Tasks")
    // No list means no permalink, so the item carries its text alone.
    XCTAssertTrue(arguments["markdown"]?.stringValue?.contains("- [ ] Offline task") == true)
  }

  func testCompletedTasksAreNotWrittenToTheChecklist() {
    let rows = NativeAFFiNEIntegrationPlugin.checklistTasks(
      from: [
        CheckvistTask(id: 1, content: "Open", status: 0, due: nil),
        CheckvistTask(id: 2, content: "Closed", status: 1, due: nil),
        CheckvistTask(id: 3, content: "Subtask", status: 0, due: nil, parentId: 1),
      ],
      listId: "12"
    )

    XCTAssertEqual(rows.map(\.id), [1, 3])
    XCTAssertEqual(rows.last?.depth, 1, "subtasks nest under their parent")
  }

  func testAToolFailureIsThrown() async {
    caller.stub("find_doc_by_title", structured(["matches": .array([])]))
    caller.stub(
      "create_doc_from_markdown",
      .object([
        "isError": .bool(true),
        "content": .array([
          .object(["type": .string("text"), "text": .string("workspace not found")])
        ]),
      ]))

    do {
      _ = try await makePlugin().syncChecklist(
        tasks: [], listId: "12", listTitle: "Work", closingTicked: { _ in [] })
      XCTFail("expected the tool failure to surface")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("workspace not found"))
    }
  }

  // MARK: - Days

  func testADayWithNoDocumentYetIsCreated() async throws {
    caller.stub("find_doc_by_title", structured(["matches": .array([])]))
    caller.stub("create_doc_from_markdown", structured(["docId": .string("day-1")]))

    let day = Date(timeIntervalSince1970: 1_755_500_000)
    let document = try await makePlugin().exportDay(
      day,
      renderedSection: """
        \(DailyNoteMarkdown.beginMarker)
        ## Log

        **2 done**
        \(DailyNoteMarkdown.endMarker)
        """,
      titlePattern: "yyyy-MM-dd"
    )

    XCTAssertEqual(document.docId, "day-1")
    let arguments = try XCTUnwrap(caller.arguments(for: "create_doc_from_markdown"))
    let markdown = try XCTUnwrap(arguments["markdown"]?.stringValue)
    XCTAssertTrue(markdown.contains("**2 done**"))
    XCTAssertFalse(markdown.contains(DailyNoteMarkdown.beginMarker))
  }

  /// The day's document belongs to the user as much as to Priority: the log is
  /// replaced, and everything they wrote around it is left alone.
  func testAnExistingDayIsSplicedRatherThanOverwritten() async throws {
    caller.stub(
      "find_doc_by_title",
      structured([
        "matches": .array([
          .object(["id": .string("day-1"), "inTrash": .bool(false)])
        ])
      ]))
    caller.stub(
      "export_doc_markdown",
      structured([
        "markdown": .string("Woke up late.\n\n## Log\n\n**1 done**\n\n## Evening\n\nRead."),
        "exists": .bool(true),
      ]))
    caller.stub("replace_doc_with_markdown", structured(["docId": .string("day-1")]))

    _ = try await makePlugin().exportDay(
      Date(), renderedSection: "## Log\n\n**6 done**", titlePattern: "yyyy-MM-dd")

    let markdown = try XCTUnwrap(
      caller.arguments(for: "replace_doc_with_markdown")?["markdown"]?.stringValue)
    XCTAssertTrue(markdown.contains("Woke up late."))
    XCTAssertTrue(markdown.contains("## Evening"))
    XCTAssertTrue(markdown.contains("**6 done**"))
    XCTAssertFalse(markdown.contains("**1 done**"))
  }

  /// A deleted document still matches by title. Writing the day into it would
  /// put it somewhere the user cannot see.
  func testATrashedDocumentIsNotWrittenInto() async throws {
    caller.stub(
      "find_doc_by_title",
      structured([
        "matches": .array([
          .object(["id": .string("old-day"), "inTrash": .bool(true)])
        ])
      ]))
    caller.stub("create_doc_from_markdown", structured(["docId": .string("day-2")]))

    let document = try await makePlugin().exportDay(
      Date(), renderedSection: "## Log\n\n**1 done**", titlePattern: "yyyy-MM-dd")

    XCTAssertEqual(document.docId, "day-2")
    XCTAssertFalse(caller.toolNames.contains("replace_doc_with_markdown"))
  }

  func testADayThatHasNotChangedIsNotRewritten() async throws {
    caller.stub(
      "find_doc_by_title",
      structured(["matches": .array([.object(["id": .string("day-1")])])]))
    caller.stub("export_doc_markdown", structured(["markdown": .string("## Log\n\n**1 done**")]))

    let document = try await makePlugin().exportDay(
      Date(), renderedSection: "## Log\n\n**1 done**", titlePattern: "yyyy-MM-dd")

    XCTAssertFalse(document.didWrite)
    XCTAssertFalse(caller.toolNames.contains("replace_doc_with_markdown"))
  }

  // MARK: - Workspaces

  func testWorkspacesAreReadFromEitherShapeTheServerSends() async throws {
    caller.stub(
      "list_workspaces",
      structured([
        "items": .array([
          .object([
            "id": .string("ws-1"), "name": .string("Notes"),
            "url": .string("https://app.affine.pro/workspace/ws-1"),
          ]),
          .object(["id": .string("ws-2"), "name": .null]),
          .object(["name": .string("no id, dropped")]),
        ])
      ]))

    let plugin = makePlugin()
    let workspaces = try await plugin.availableWorkspaces()

    XCTAssertEqual(workspaces.map(\.id), ["ws-1", "ws-2"])
    XCTAssertEqual(workspaces[1].displayName, "ws-2")

    plugin.selectWorkspace(workspaces[0])
    XCTAssertEqual(plugin.workspaceId, "ws-1")
    XCTAssertEqual(
      plugin.checklistDocumentURL(forListId: "12"), nil,
      "a list that has never synced has no document to open")
  }

  func testADocumentURLIsBuiltFromTheSelectedWorkspace() async throws {
    caller.stub(
      "list_workspaces",
      structured([
        "items": .array([
          .object([
            "id": .string("ws-1"), "name": .string("Notes"),
            "url": .string("https://app.affine.pro/workspace/ws-1"),
          ])
        ])
      ]))
    caller.stub("find_doc_by_title", structured(["matches": .array([])]))
    caller.stub("create_doc_from_markdown", structured(["docId": .string("doc-9")]))

    let plugin = makePlugin()
    plugin.selectWorkspace(try await plugin.availableWorkspaces()[0])
    _ = try await plugin.syncChecklist(
      tasks: [task()], listId: "77", listTitle: "Work", closingTicked: { _ in [] })

    XCTAssertEqual(
      plugin.checklistDocumentURL(forListId: "77")?.absoluteString,
      "https://app.affine.pro/workspace/ws-1/doc-9"
    )
  }
}
