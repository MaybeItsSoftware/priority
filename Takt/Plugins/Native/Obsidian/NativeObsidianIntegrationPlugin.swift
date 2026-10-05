import Foundation

@MainActor
final class NativeObsidianIntegrationPlugin: ObsidianIntegrationPlugin {
  let pluginIdentifier = "native.obsidian.integration"
  let displayName = "Native Obsidian Integration"
  let pluginDescription = "Sync tasks into markdown notes and open them directly in Obsidian."

  private let service: ObsidianSyncService

  init(service: ObsidianSyncService = ObsidianSyncService()) {
    self.service = service
  }

  var inboxPath: String {
    service.inboxPath
  }

  func chooseInboxFolder() throws -> String? {
    try service.chooseInboxFolder()
  }

  func clearInboxFolder() {
    service.clearInboxFolder()
  }

  func chooseLinkedFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    try service.chooseLinkedFolder(forTaskId: taskId, taskContent: taskContent)
  }

  func createAndLinkFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    try service.createAndLinkFolder(forTaskId: taskId, taskContent: taskContent)
  }

  func clearLinkedFolder(forTaskId taskId: Int) {
    service.clearLinkedFolder(forTaskId: taskId)
  }

  func hasLinkedFolder(forTaskId taskId: Int) -> Bool {
    service.hasLinkedFolder(forTaskId: taskId)
  }

  func hasSyncedNote(task: CheckvistTask, linkedFolderTaskId: Int?) -> Bool {
    service.hasSyncedNote(task: task, linkedFolderTaskId: linkedFolderTaskId)
  }

  func syncTask(
    _ task: CheckvistTask,
    listId: String,
    linkedFolderTaskId: Int?,
    openMode: ObsidianOpenMode,
    syncDate: Date
  ) throws -> URL {
    try service.syncTask(
      task,
      listId: listId,
      linkedFolderTaskId: linkedFolderTaskId,
      openMode: openMode,
      syncDate: syncDate
    )
  }
}
