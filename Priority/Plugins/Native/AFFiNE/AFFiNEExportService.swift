import Foundation
import OSLog
import PriorityCore

struct AFFiNEWorkspace: Identifiable, Sendable, Equatable {
  let id: String
  let name: String
  let url: String?

  /// Workspaces are routinely unnamed — a new one shows as its own id in
  /// AFFiNE too, so a picker showing a truncated id is not a bug.
  var displayName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? String(id.prefix(8)) : name
  }
}

/// The result of squaring a list with its checklist document.
struct AFFiNEChecklistOutcome: Sendable, Equatable {
  let document: AFFiNEDocumentRef
  /// Tasks that were ticked in AFFiNE, and have now been closed in Checkvist.
  let closedTaskIds: [Int]
}

/// A document Priority has written, and what happened when it did.
struct AFFiNEDocumentRef: Sendable, Equatable {
  let docId: String
  let workspaceId: String
  let title: String
  let url: URL?
  /// What the markdown importer had to drop or approximate. Surfaced rather
  /// than swallowed: "it synced" while quietly losing a table is worse than
  /// saying so.
  let warnings: [String]
  let lossy: Bool
  /// `false` when the export was a no-op because nothing had changed remotely.
  let didWrite: Bool
}

/// Talks to an AFFiNE workspace, and remembers which document each task landed
/// in.
///
/// Everything here is transport and memory. What a task *reads* like as a
/// document is `AFFiNEDocumentMarkdown`'s business, and the mapping from a
/// `CheckvistTask` onto it is the plugin's — this layer never sees one.
@MainActor
final class AFFiNEExportService {

  private static let serverCommandPathKey = "affineServerCommandPath"
  private static let workspaceIdKey = "affineWorkspaceId"
  private static let workspaceURLKey = "affineWorkspaceURL"
  private static let parentDocIdKey = "affineParentDocId"
  private static let docIdsKey = "affineChecklistDocIdsByListId"

  private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "affine")
  private let defaults: UserDefaults
  private let makeCaller: (() throws -> AFFiNEToolCalling)?

  init(
    defaults: UserDefaults = .standard,
    makeCaller: (() throws -> AFFiNEToolCalling)? = nil
  ) {
    self.defaults = defaults
    self.makeCaller = makeCaller
  }

  // MARK: - Settings

  /// An explicit path to `affine-mcp`, when the automatic search misses it.
  var serverCommandPath: String {
    get { defaults.string(forKey: Self.serverCommandPathKey) ?? "" }
    set { defaults.set(newValue, forKey: Self.serverCommandPathKey) }
  }

  /// Empty means "whatever the server is configured for" — `affine-mcp` has
  /// its own `AFFINE_WORKSPACE_ID`, and overriding it with a blank would be
  /// worse than not overriding it at all.
  var workspaceId: String {
    get { defaults.string(forKey: Self.workspaceIdKey) ?? "" }
    set { defaults.set(newValue, forKey: Self.workspaceIdKey) }
  }

  /// Cached when a workspace is picked, so a document link can be built without
  /// a round trip.
  var workspaceURL: String {
    get { defaults.string(forKey: Self.workspaceURLKey) ?? "" }
    set { defaults.set(newValue, forKey: Self.workspaceURLKey) }
  }

  /// The document a new checklist is filed under. Without one it is created as
  /// an orphan — reachable by search, absent from the sidebar.
  var parentDocId: String {
    get { defaults.string(forKey: Self.parentDocIdKey) ?? "" }
    set { defaults.set(newValue, forKey: Self.parentDocIdKey) }
  }

  var isConfigured: Bool {
    (try? resolvedServerCommandPath()) != nil
  }

  // MARK: - Helper resolution

  func helperCandidates() -> [String] {
    AFFiNEHelperLocator.candidates(
      configuredPath: serverCommandPath,
      environmentOverride: ProcessInfo.processInfo.environment[
        AFFiNEHelperLocator.environmentOverrideKey],
      homeDirectory: NSHomeDirectory(),
      nodeVersionDirectories: nodeVersionDirectories()
    )
  }

  func resolvedServerCommandPath() throws -> String {
    let candidates = helperCandidates()
    guard
      let resolved = AFFiNEHelperLocator.resolve(
        candidates: candidates,
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
      throw AFFiNEMCPError.helperNotFound(
        AFFiNEHelperLocator.missingHelperMessage(candidates: candidates))
    }
    return resolved
  }

  /// nvm's installed node versions, newest first. Newest-first is a plain
  /// reverse sort on the directory name, which is wrong for `v9` vs `v10` —
  /// and harmless, because every candidate is tried in turn anyway.
  private func nodeVersionDirectories() -> [String] {
    let root = "\(NSHomeDirectory())/.nvm/versions/node"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    return names.sorted(by: >).map { "\(root)/\($0)" }
  }

  func makeSession() throws -> AFFiNEToolCalling {
    if let makeCaller { return try makeCaller() }

    let path = try resolvedServerCommandPath()
    var environment: [String: String] = [:]
    if !workspaceId.isEmpty { environment["AFFINE_WORKSPACE_ID"] = workspaceId }

    return AFFiNEMCPSession(
      launch: .init(
        executablePath: path,
        searchPath: AFFiNEHelperLocator.searchPath(
          forHelperPath: path,
          basePATH: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ),
        extraEnvironment: environment
      ))
  }

  // MARK: - Document memory

  /// The checklist document for a list, once one has been created or found.
  /// Remembered by list id rather than by title, so renaming the document in
  /// AFFiNE does not orphan it.
  func rememberedChecklistDocId(listId: String) -> String? {
    checklistDocIds()[Self.scope(listId)]
  }

  func forgetChecklistDocument(listId: String) {
    var docIds = checklistDocIds()
    docIds.removeValue(forKey: Self.scope(listId))
    defaults.set(docIds, forKey: Self.docIdsKey)
  }

  /// Tasks created offline have no list to belong to yet, and share a scope
  /// until a real list id arrives.
  private static func scope(_ listId: String) -> String {
    let trimmed = listId.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "offline" : trimmed
  }

  private func checklistDocIds() -> [String: String] {
    (defaults.dictionary(forKey: Self.docIdsKey) as? [String: String]) ?? [:]
  }

  private func rememberChecklist(docId: String, listId: String) {
    var docIds = checklistDocIds()
    docIds[Self.scope(listId)] = docId
    defaults.set(docIds, forKey: Self.docIdsKey)
  }

  // MARK: - Operations

  func workspaces(using caller: AFFiNEToolCalling) async throws -> [AFFiNEWorkspace] {
    let result = try await caller.callTool("list_workspaces", arguments: [:])
    guard let structured = MCPWire.structuredContent(result) else {
      throw AFFiNEMCPError.unexpectedResult(tool: "list_workspaces")
    }

    let items = structured["items"]?.arrayValue ?? structured.arrayValue ?? []
    return items.compactMap { item in
      guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
      return AFFiNEWorkspace(
        id: id,
        name: item["name"]?.stringValue ?? "",
        url: item["url"]?.stringValue
      )
    }
  }

  /// Brings a list and its AFFiNE checklist into agreement, in that order:
  /// read what was ticked in AFFiNE, close those tasks, then write back what is
  /// still open.
  ///
  /// - Parameter closingTicked: called with the tasks ticked in AFFiNE, and
  ///   returns the list as it stands afterwards. Closing a Checkvist task is
  ///   not this layer's business — it belongs to the mutation service — but the
  ///   ordering is, because writing the checklist back before those closes land
  ///   would restore every box that was just ticked.
  @discardableResult
  func syncChecklist(
    listId: String,
    documentTitle: String,
    tasks: [AFFiNEChecklistTask],
    using caller: AFFiNEToolCalling,
    closingTicked: ([Int]) async -> [AFFiNEChecklistTask]
  ) async throws -> AFFiNEChecklistOutcome {
    guard
      let located = try await locateChecklist(
        listId: listId, title: documentTitle, using: caller)
    else {
      let created = try await createDocument(
        title: documentTitle,
        markdown: AFFiNEChecklistMarkdown.section(tasks: tasks),
        using: caller
      )
      rememberChecklist(docId: created.docId, listId: listId)
      return AFFiNEChecklistOutcome(document: created, closedTaskIds: [])
    }

    let docId = located.docId
    let existing = located.exported

    // Reading is safe whatever the document holds; writing it back is not. The
    // exporter renders a block it cannot describe as a comment, so replacing a
    // document with its own exported markdown would delete that block outright.
    guard !existing.lossy else {
      throw AFFiNEMCPError.documentNotRewritable(title: documentTitle)
    }

    let ticked = AFFiNEChecklistMarkdown.tickedTaskIds(in: existing.markdown)
    let remaining = ticked.isEmpty ? tasks : await closingTicked(ticked)
    let carriedOver = AFFiNEChecklistMarkdown.unownedLines(in: existing.markdown)
    let items = AFFiNEChecklistMarkdown.items(in: existing.markdown)

    // Nothing ticked and nothing moved. Worth checking, because the document
    // is read on every sync and rewriting it would churn its history for no
    // change anyone made.
    if ticked.isEmpty, AFFiNEChecklistMarkdown.matches(items, tasks: remaining) {
      return AFFiNEChecklistOutcome(
        document: AFFiNEDocumentRef(
          docId: docId,
          workspaceId: workspaceId,
          title: documentTitle,
          url: documentURL(docId: docId),
          warnings: [],
          lossy: false,
          didWrite: false
        ),
        closedTaskIds: []
      )
    }

    let merged = AFFiNEDocumentMarkdown.merged(
      section: AFFiNEChecklistMarkdown.section(tasks: remaining, carriedOver: carriedOver),
      heading: AFFiNEChecklistMarkdown.heading,
      into: existing.markdown
    )
    let document = try await replaceDocument(
      docId: docId, title: documentTitle, markdown: merged, using: caller)
    return AFFiNEChecklistOutcome(document: document, closedTaskIds: ticked)
  }

  /// The list's checklist document and its current contents, or `nil` when
  /// there is not one yet.
  ///
  /// Fetched once rather than twice: the export that proves a remembered
  /// document still exists is the same export the sync then reads, and each one
  /// is a websocket round trip.
  private func locateChecklist(
    listId: String,
    title: String,
    using caller: AFFiNEToolCalling
  ) async throws -> (docId: String, exported: ExportedDocument)? {
    if let remembered = rememberedChecklistDocId(listId: listId) {
      let exported = try await exportedDocument(docId: remembered, using: caller)
      if exported.exists { return (remembered, exported) }
      // Deleted in AFFiNE. Forget it rather than write into a document nobody
      // can see.
      forgetChecklistDocument(listId: listId)
    }

    guard let found = try await findDocument(titled: title, using: caller) else { return nil }
    let exported = try await exportedDocument(docId: found, using: caller)
    guard exported.exists else { return nil }
    rememberChecklist(docId: found, listId: listId)
    return (found, exported)
  }

  /// Writes a day into the document that day owns, creating it if it does not
  /// exist and splicing into it if it does.
  @discardableResult
  func exportDay(
    title: String,
    section: String,
    using caller: AFFiNEToolCalling
  ) async throws -> AFFiNEDocumentRef {
    guard let docId = try await findDocument(titled: title, using: caller) else {
      let body = AFFiNEDocumentMarkdown.merged(section: section, into: "")
      return try await createDocument(title: title, markdown: body, using: caller)
    }

    let existing = try await exportedDocument(docId: docId, using: caller)
    guard !existing.lossy else {
      throw AFFiNEMCPError.documentNotRewritable(title: title)
    }

    let merged = AFFiNEDocumentMarkdown.merged(section: section, into: existing.markdown)
    guard merged.trimmingCharacters(in: .whitespacesAndNewlines)
      != existing.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return AFFiNEDocumentRef(
        docId: docId,
        workspaceId: workspaceId,
        title: title,
        url: documentURL(docId: docId),
        warnings: [],
        lossy: false,
        didWrite: false
      )
    }

    return try await replaceDocument(docId: docId, title: title, markdown: merged, using: caller)
  }

  func documentURL(docId: String) -> URL? {
    let base = workspaceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty, !docId.isEmpty else { return nil }
    return URL(string: "\(base)/\(docId)")
  }

  // MARK: - Tool calls

  private func findDocument(titled title: String, using caller: AFFiNEToolCalling) async throws
    -> String?
  {
    var arguments: [String: JSONValue] = ["title": .string(title), "limit": .int(5)]
    if !workspaceId.isEmpty { arguments["workspaceId"] = .string(workspaceId) }

    let result = try await caller.callTool("find_doc_by_title", arguments: arguments)
    guard let structured = MCPWire.structuredContent(result) else {
      throw AFFiNEMCPError.unexpectedResult(tool: "find_doc_by_title")
    }

    // A trashed document still matches by title. Writing into it would put the
    // day somewhere the user cannot see.
    return structured["matches"]?.arrayValue?
      .first(where: { $0["inTrash"]?.boolValue != true })?["id"]?.stringValue
  }

  private struct ExportedDocument {
    let markdown: String
    let exists: Bool
    /// The exporter could not represent something in the document. A caller
    /// about to write that document back must not.
    let lossy: Bool
  }

  private func exportedDocument(docId: String, using caller: AFFiNEToolCalling) async throws
    -> ExportedDocument
  {
    var arguments: [String: JSONValue] = ["docId": .string(docId)]
    if !workspaceId.isEmpty { arguments["workspaceId"] = .string(workspaceId) }

    let result = try await caller.callTool("export_doc_markdown", arguments: arguments)
    guard let structured = MCPWire.structuredContent(result) else {
      throw AFFiNEMCPError.unexpectedResult(tool: "export_doc_markdown")
    }
    return ExportedDocument(
      markdown: structured["markdown"]?.stringValue ?? "",
      // Absent means present: only a server that looked and found nothing says
      // so, and one that says nothing still returned markdown for something.
      exists: structured["exists"]?.boolValue ?? true,
      lossy: structured["lossy"]?.boolValue ?? false
    )
  }

  private func createDocument(
    title: String,
    markdown: String,
    using caller: AFFiNEToolCalling
  ) async throws -> AFFiNEDocumentRef {
    var arguments: [String: JSONValue] = [
      "title": .string(title),
      // The importer rejects empty markdown, and a task with no notes and no
      // list is genuinely close to empty.
      "markdown": .string(markdown.isEmpty ? "_No content_" : markdown),
    ]
    if !workspaceId.isEmpty { arguments["workspaceId"] = .string(workspaceId) }
    if !parentDocId.isEmpty { arguments["parentDocId"] = .string(parentDocId) }

    let result = try await caller.callTool("create_doc_from_markdown", arguments: arguments)
    guard
      let structured = MCPWire.structuredContent(result),
      let docId = structured["docId"]?.stringValue
    else {
      throw AFFiNEMCPError.unexpectedResult(tool: "create_doc_from_markdown")
    }

    return reference(from: structured, docId: docId, title: title)
  }

  private func replaceDocument(
    docId: String,
    title: String,
    markdown: String,
    using caller: AFFiNEToolCalling
  ) async throws -> AFFiNEDocumentRef {
    var arguments: [String: JSONValue] = [
      "docId": .string(docId),
      "markdown": .string(markdown.isEmpty ? "_No content_" : markdown),
    ]
    if !workspaceId.isEmpty { arguments["workspaceId"] = .string(workspaceId) }

    let result = try await caller.callTool("replace_doc_with_markdown", arguments: arguments)
    guard let structured = MCPWire.structuredContent(result) else {
      throw AFFiNEMCPError.unexpectedResult(tool: "replace_doc_with_markdown")
    }
    return reference(from: structured, docId: docId, title: title)
  }

  private func reference(
    from structured: JSONValue,
    docId: String,
    title: String
  ) -> AFFiNEDocumentRef {
    AFFiNEDocumentRef(
      docId: docId,
      workspaceId: structured["workspaceId"]?.stringValue ?? workspaceId,
      title: structured["title"]?.stringValue ?? title,
      url: documentURL(docId: docId),
      warnings: structured["warnings"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
      lossy: structured["lossy"]?.boolValue ?? false,
      didWrite: true
    )
  }
}
