import Foundation
import TaktCore
import TaktWorkspace
import XCTest

/// The standing instructions in the workspace: the store's reads and writes,
/// their undo, and the one-time copy out of the Mac's preferences.
final class WorkspaceAgentInstructionTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var workspace: Workspace!
  private var inbox: TaskList!
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktAgentInstructionTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    workspace = try store.bootstrapIfNeeded()
    inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
    suiteName = "TaktAgentInstructionTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testEachScopeIsReadBackAndAnEditIsOneUndoStep() throws {
    XCTAssertEqual(try store.agentInstructionTexts(), WorkspaceAgentInstructionTexts())
    XCTAssertEqual(try store.setAgentInstructions("  Verbs first.  ", kind: .account, id: nil), "Verbs first.")
    try store.setAgentInstructions("Shop on Saturdays.", kind: .list, id: inbox.id)
    let texts = try store.agentInstructionTexts()
    XCTAssertEqual(texts.account, "Verbs first.")
    XCTAssertEqual(texts.lists, [inbox.id: "Shop on Saturdays."])
    XCTAssertTrue(texts.folders.isEmpty)

    XCTAssertEqual(try store.undo(), "Edit Agent Instructions")
    XCTAssertTrue(try store.agentInstructionTexts().lists.isEmpty)

    try store.setAgentInstructions("", kind: .account, id: nil)
    XCTAssertEqual(try store.agentInstructionTexts().account, "", "blank text clears the scope")
  }

  func testAListThatIsNotThereIsRefused() throws {
    XCTAssertThrowsError(try store.setAgentInstructions("x", kind: .list, id: "NOT-A-LIST"))
  }

  func testThePreferencesAreCopiedInOnceAndKeepWhatTheWorkspaceHas() throws {
    typealias Keys = WorkspaceStore.LegacyAgentInstructionKeys
    defaults.set("From preferences.", forKey: Keys.account)
    defaults.set([inbox.id: "Inbox rules.", "GONE-LIST": "Orphan."], forKey: Keys.lists)
    // Another device, or the agent, wrote the account already: that wins.
    try store.setAgentInstructions("Already here.", kind: .account, id: nil)

    XCTAssertEqual(try store.migrateAgentInstructionPreferences(from: defaults), 1)
    var texts = try store.agentInstructionTexts()
    XCTAssertEqual(texts.account, "Already here.")
    XCTAssertEqual(texts.lists, [inbox.id: "Inbox rules."], "an entry for a deleted list is skipped")
    XCTAssertTrue(defaults.bool(forKey: Keys.migrated))
    XCTAssertEqual(defaults.string(forKey: Keys.account), "From preferences.", "copied, not moved")
    // The copy is not an undo step: undo takes back the edit before it.
    XCTAssertEqual(try store.undo(), "Edit Agent Instructions")

    // Once only: clearing the scope afterwards is not undone by a second run.
    try store.setAgentInstructions("", kind: .list, id: inbox.id)
    XCTAssertEqual(try store.migrateAgentInstructionPreferences(from: defaults), 0)
    texts = try store.agentInstructionTexts()
    XCTAssertTrue(texts.lists.isEmpty)
  }
}
