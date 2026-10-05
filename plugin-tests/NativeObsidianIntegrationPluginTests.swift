import Foundation
import XCTest

@testable import TaktPlugins

@MainActor
final class NativeObsidianIntegrationPluginTests: XCTestCase {
  func testInboxAndFolderLinkingFlowDelegatesToService() throws {
    let service = ObsidianSyncService()
    service.inboxPath = "/tmp/obsidian-inbox"
    service.createAndLinkFolderResult = "/tmp/obsidian-task-folder"
    let plugin = NativeObsidianIntegrationPlugin(service: service)

    XCTAssertEqual(plugin.inboxPath, "/tmp/obsidian-inbox")

    let linkedPath = try plugin.createAndLinkFolder(forTaskId: 12, taskContent: "Parent task")
    XCTAssertEqual(linkedPath, "/tmp/obsidian-task-folder")
    XCTAssertTrue(plugin.hasLinkedFolder(forTaskId: 12))

    plugin.clearLinkedFolder(forTaskId: 12)
    XCTAssertFalse(plugin.hasLinkedFolder(forTaskId: 12))
  }

  func testSyncTaskForwardsArguments() throws {
    let service = ObsidianSyncService()
    service.syncResultURL = URL(fileURLWithPath: "/tmp/synced-task.md")
    let plugin = NativeObsidianIntegrationPlugin(service: service)
    let now = Date(timeIntervalSince1970: 123456)
    let task = CheckvistTask(id: 55, content: "Write summary", status: 0, due: nil)

    let url = try plugin.syncTask(
      task,
      listId: "777",
      linkedFolderTaskId: 99,
      openMode: .newWindow,
      syncDate: now
    )

    XCTAssertEqual(url.path, "/tmp/synced-task.md")
    XCTAssertEqual(service.lastSyncCall?.task.id, 55)
    XCTAssertEqual(service.lastSyncCall?.listId, "777")
    XCTAssertEqual(service.lastSyncCall?.linkedFolderTaskId, 99)
    XCTAssertEqual(service.lastSyncCall?.syncDate, now)
    XCTAssertEqual(service.lastSyncCall?.openMode, .newWindow)
  }
}
