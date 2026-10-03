import Foundation
import Observation
import OSLog
import PriorityCore
import PriorityWorkspace

/// The lists, folders and sidebar index — everything the list tree draws —
/// read in one go off the main actor.
struct WorkspaceStructure: Sendable, Equatable {
  var folders: [ListFolder] = []
  var lists: [TaskList] = []
  var archivedLists: [TaskList] = []
  var sidebar = WorkspaceSidebarIndex(nestedLists: [], archivedNestedLists: [], taskCounts: [:])

  static let empty = WorkspaceStructure()

  /// Reads the structure. Safe on any thread: only reads, and the store's
  /// pool serves reads concurrently with its writer.
  static func load(store: WorkspaceStore, workspaceId: String) throws -> WorkspaceStructure {
    let all = try store.lists(in: workspaceId, includingArchived: true)
    let active = all.filter { !$0.isArchived }
    let trees = try store.listTrees(in: active.map(\.id))
    return WorkspaceStructure(
      folders: try store.folders(in: workspaceId),
      lists: active,
      archivedLists: all.filter(\.isArchived),
      sidebar: WorkspaceSidebarIndex(lists: active, trees: trees))
  }

  var inbox: TaskList? { lists.first { $0.systemRole == .inbox } }

  func list(_ id: String?) -> TaskList? {
    guard let id else { return nil }
    return lists.first { $0.id == id } ?? archivedLists.first { $0.id == id }
  }

  func folder(_ id: String?) -> ListFolder? {
    guard let id else { return nil }
    return folders.first { $0.id == id }
  }

  var promotedLists: [WorkspaceTask] {
    sidebar.nestedLists.map(\.task).filter { $0.isPromoted == true && $0.status == .open }
  }

  /// Lists in the order the tree draws them: folders depth-first, each
  /// folder's lists after its subfolders, then the root lists. What "previous
  /// list" and "next list" walk.
  var listsInTreeOrder: [TaskList] {
    var result: [TaskList] = []
    func walk(_ parent: String?) {
      for folder in folders where folder.parentFolderId == parent {
        walk(folder.id)
        result += lists.filter { $0.folderId == folder.id }
      }
    }
    walk(nil)
    return lists.filter { $0.folderId == nil } + result
  }

  /// A folder's lists, including those in its subfolders.
  func listIDs(inFolder folderID: String) -> [String] {
    var ids: [String] = []
    func walk(_ id: String) {
      ids += lists.filter { $0.folderId == id }.map(\.id)
      for child in folders where child.parentFolderId == id { walk(child.id) }
    }
    walk(folderID)
    return ids
  }
}

/// The app's one handle on the workspace.
///
/// Every write passes through `perform`, which runs it, then moves
/// `revision`. Every read a screen makes is keyed on `revision` (see
/// `StoreQuery`), so a write anywhere re-reads whatever is on screen, and only
/// that — a screen that is not visible holds no query and reads nothing.
///
/// Writes from other processes — the widget's intents, the sync agent, the
/// Mac CLI if the file is shared — are noticed with `PRAGMA data_version`,
/// which the store exposes as `readExternalChangeToken()`.
@MainActor
@Observable
final class WorkspaceModel {
  @ObservationIgnored nonisolated let store: WorkspaceStore
  let workspace: Workspace
  private(set) var structure = WorkspaceStructure.empty
  /// Moves after every write, local or external. What every query keys on.
  private(set) var revision = 0
  private(set) var undoLabel: String?
  private(set) var redoLabel: String?
  var errorMessage: String?
  /// Moves when something is completed, so a view can play the haptic.
  private(set) var completionCount = 0
  /// A passing line of feedback ("Moved to Work") for actions whose result is
  /// off screen.
  var toast: String?
  /// A task someone asked to focus on from elsewhere — a context menu, a day
  /// card. The Focus screen stages it and clears this.
  var focusRequestTaskID: String?
  /// A block that has been ended and is waiting to be scored. Whoever ended
  /// it, the root presents the one `BlockQualityPrompt` for it.
  var pendingBlock: PendingBlockCompletion?
  /// What the last scored block earned, until someone dismisses it.
  var lastBlockResult: BlockCompletionResult?

  let navigation = AppNavigation()
  /// The row being celebrated, if any. See `CelebrationStage`.
  let celebration = CelebrationStage()

  /// Called after every change, on the main actor. The widget bridge and the
  /// Live Activity hang off this.
  @ObservationIgnored var changeObservers: [(WorkspaceModel) -> Void] = []

  @ObservationIgnored private var externalToken: Int?
  @ObservationIgnored private var externalWatch: Task<Void, Never>?
  @ObservationIgnored private var structureGeneration = 0
  @ObservationIgnored let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "WorkspaceModel")

  init(store: WorkspaceStore) throws {
    self.store = store
    self.workspace = try store.bootstrapIfNeeded()
    try? store.recoverInterruptedFocus()
    _ = try? store.resolveStaleFocusSession()
    // The first frame is the list tree: read it here so it does not paint
    // empty and then fill.
    structure = (try? WorkspaceStructure.load(store: store, workspaceId: workspace.id)) ?? .empty
    refreshHistoryLabels()
  }

  /// Opens the workspace in the app group container. UI tests get a fresh,
  /// empty one in a temporary directory.
  static func live() throws -> WorkspaceModel {
    if AppGroup.isUITesting {
      try? FileManager.default.removeItem(at: AppGroup.containerURL)
    }
    let store = try WorkspaceStore(databaseURL: AppGroup.databaseURL)
    return try WorkspaceModel(store: store)
  }

  /// A workspace in a throwaway file, for tests and previews.
  static func temporary() throws -> WorkspaceModel {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "priority-\(UUID().uuidString)/priority.sqlite")
    return try WorkspaceModel(store: WorkspaceStore(databaseURL: url))
  }

  // MARK: - Writing

  /// The one funnel every local write passes through. Returns whether it
  /// succeeded; a failure is shown rather than thrown.
  @discardableResult
  func perform(_ work: (WorkspaceStore) throws -> Void) -> Bool {
    do {
      try work(store)
      errorMessage = nil
      didChange()
      return true
    } catch {
      logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
      errorMessage = error.localizedDescription
      // A failed write can still have half-landed through a sibling call.
      didChange()
      return false
    }
  }

  /// As `perform`, returning what the write produced.
  func performReturning<T>(_ work: (WorkspaceStore) throws -> T) -> T? {
    var result: T?
    perform { store in result = try work(store) }
    return result
  }

  /// Something changed: every query on screen re-reads, the structure is
  /// read again off the main actor, and the observers hear about it.
  func didChange() {
    revision &+= 1
    refreshHistoryLabels()
    reloadStructure()
    for observer in changeObservers { observer(self) }
  }

  func noteCompletion() { completionCount &+= 1 }

  func showToast(_ text: String) {
    toast = text
    let shown = text
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      if self?.toast == shown { self?.toast = nil }
    }
  }

  private func refreshHistoryLabels() {
    let undo = (try? store.undoableLabel()) ?? nil
    let redo = (try? store.redoableLabel()) ?? nil
    if undoLabel != undo { undoLabel = undo }
    if redoLabel != redo { redoLabel = redo }
  }

  /// Reads the list tree off the main actor and lands it if nothing newer
  /// was asked for meanwhile.
  func reloadStructure() {
    structureGeneration &+= 1
    let generation = structureGeneration
    let store = store
    let workspaceID = workspace.id
    Task.detached(priority: .userInitiated) { [weak self] in
      guard let loaded = try? WorkspaceStructure.load(store: store, workspaceId: workspaceID) else { return }
      await self?.applyStructure(loaded, generation: generation)
    }
  }

  /// Reads the structure on the spot, for a caller that needs it on the next
  /// line (a deep link naming a list just created).
  func reloadStructureNow() {
    structureGeneration &+= 1
    if let loaded = try? WorkspaceStructure.load(store: store, workspaceId: workspace.id), loaded != structure {
      structure = loaded
    }
  }

  private func applyStructure(_ loaded: WorkspaceStructure, generation: Int) {
    guard generation == structureGeneration, loaded != structure else { return }
    structure = loaded
  }

  // MARK: - Undo

  func undo() {
    var label: String?
    perform { store in label = try store.undo() }
    if let label { showToast("Undid \(label.lowercased())") }
  }

  func redo() {
    var label: String?
    perform { store in label = try store.redo() }
    if let label { showToast("Redid \(label.lowercased())") }
  }

  // MARK: - Other processes

  /// Polls for commits made by another process while the app is in the
  /// foreground. Cheap: one pragma on the writer connection.
  func startWatchingExternalWrites() {
    guard externalWatch == nil else { return }
    externalWatch = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.checkExternalWrites()
        try? await Task.sleep(for: .seconds(1.5))
      }
    }
  }

  func stopWatchingExternalWrites() {
    externalWatch?.cancel()
    externalWatch = nil
  }

  func checkExternalWrites() async {
    guard let token = try? await store.readExternalChangeToken() else { return }
    defer { externalToken = token }
    guard let previous = externalToken, previous != token else { return }
    didChange()
  }

  // MARK: - Lookups

  var lists: [TaskList] { structure.lists }
  var folders: [ListFolder] { structure.folders }
  var inbox: TaskList? { structure.inbox }

  func task(_ id: String) -> WorkspaceTask? {
    try? store.task(id: id)
  }

  func listName(for listID: String) -> String {
    structure.list(listID)?.name ?? ""
  }
}
