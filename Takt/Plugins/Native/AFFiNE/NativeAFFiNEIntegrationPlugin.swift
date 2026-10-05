import Foundation
import TaktCore

@MainActor
final class NativeAFFiNEIntegrationPlugin: AFFiNEIntegrationPlugin {
  let pluginIdentifier = "native.affine.integration"
  let displayName = "Native AFFiNE Integration"
  let pluginDescription = "Write tasks and the day's log into an AFFiNE workspace."

  private let service: AFFiNEExportService

  /// The service is built here rather than defaulted in the signature: it is
  /// `@MainActor`, and a default argument is evaluated outside the actor.
  init(service: AFFiNEExportService? = nil) {
    self.service = service ?? AFFiNEExportService()
  }

  // MARK: - Configuration

  var isConfigured: Bool { service.isConfigured }

  var serverCommandPath: String {
    get { service.serverCommandPath }
    set { service.serverCommandPath = newValue }
  }

  var workspaceId: String {
    get { service.workspaceId }
    set { service.workspaceId = newValue }
  }

  var parentDocId: String {
    get { service.parentDocId }
    set { service.parentDocId = newValue }
  }

  var resolvedServerCommandPath: String? {
    try? service.resolvedServerCommandPath()
  }

  func helperDiagnostic() -> String {
    AFFiNEHelperLocator.missingHelperMessage(candidates: service.helperCandidates())
  }

  // MARK: - Workspaces

  func availableWorkspaces() async throws -> [AFFiNEWorkspace] {
    let session = try service.makeSession()
    defer { (session as? AFFiNEMCPSession)?.close() }
    return try await service.workspaces(using: session)
  }

  func selectWorkspace(_ workspace: AFFiNEWorkspace) {
    service.workspaceId = workspace.id
    service.workspaceURL = workspace.url ?? ""
  }

  // MARK: - Export

  func syncChecklist(
    tasks: [CheckvistTask],
    listId: String,
    listTitle: String,
    closingTicked: ([Int]) async -> [CheckvistTask]
  ) async throws -> AFFiNEChecklistOutcome {
    let trimmedListId = listId.trimmingCharacters(in: .whitespacesAndNewlines)
    let session = try service.makeSession()
    defer { (session as? AFFiNEMCPSession)?.close() }

    return try await service.syncChecklist(
      listId: listId,
      documentTitle: Self.documentTitle(forListTitle: listTitle),
      tasks: Self.checklistTasks(from: tasks, listId: trimmedListId),
      using: session,
      closingTicked: { tickedIds in
        Self.checklistTasks(from: await closingTicked(tickedIds), listId: trimmedListId)
      }
    )
  }

  /// The list's own name, so the checklist lands in the document you would have
  /// made for it by hand. An offline list has no name to borrow.
  static func documentTitle(forListTitle listTitle: String) -> String {
    let trimmed = listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Priority Tasks" : trimmed
  }

  /// Flattens the task tree into checklist rows, carrying depth so subtasks
  /// nest, and a permalink so a ticked box can be traced back to its task.
  ///
  /// Only open tasks: a checklist of things already done is a log, and the log
  /// is `affine daily`'s job.
  static func checklistTasks(from tasks: [CheckvistTask], listId: String) -> [AFFiNEChecklistTask] {
    let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    func depth(of task: CheckvistTask) -> Int {
      var depth = 0
      var current = task
      // Bounded rather than trusted: a parent cycle in cached data would
      // otherwise hang the sync rather than produce a slightly flat list.
      while let parentId = current.parentId, parentId != 0, depth < 8,
        let parent = byId[parentId]
      {
        depth += 1
        current = parent
      }
      return depth
    }

    return tasks.filter { $0.status == 0 }.map { task in
      AFFiNEChecklistTask(
        id: task.id,
        title: task.content,
        permalink: listId.isEmpty
          ? nil
          : CheckvistEndpoints.taskPermalink(listId: listId, taskId: task.id),
        depth: depth(of: task)
      )
    }
  }

  func exportDay(
    _ day: Date,
    renderedSection: String,
    titlePattern: String
  ) async throws -> AFFiNEDocumentRef {
    let session = try service.makeSession()
    defer { (session as? AFFiNEMCPSession)?.close() }

    return try await service.exportDay(
      title: AFFiNEDocumentMarkdown.dayDocumentTitle(for: day, pattern: titlePattern),
      section: AFFiNEDocumentMarkdown.daySection(from: renderedSection),
      using: session
    )
  }

  func checklistDocumentURL(forListId listId: String) -> URL? {
    guard let docId = service.rememberedChecklistDocId(listId: listId) else { return nil }
    return service.documentURL(docId: docId)
  }

  func forgetChecklistDocument(forListId listId: String) {
    service.forgetChecklistDocument(listId: listId)
  }
}
