import Foundation
import TaktCore
import TaktWorkspace

/// Keeping the scopes you move between resident, so a switch draws what is
/// already in memory instead of reading it again. The cache itself is
/// `WorkspaceScopeCache`; this is the desktop's use of it. See
/// `docs/performance.md`.
///
/// - A read is kept with the `WorkspaceChangeStamp` it was made at. While the
///   store's stamp has not moved, nothing has been written, so going back to
///   the scope reads nothing and reshapes nothing.
/// - After a write the stamp has moved and every kept read may be behind. A
///   refresh after a write reads its scope again, on this thread, because
///   what you just did has to be on screen. A switch, which wrote nothing,
///   draws a kept combined scope as it was and reads it again in the
///   background, swapping the answer in only if it differs.
/// - Once a switch has drawn, the scopes the next one is likely to land on —
///   the sidebar rows either side of the cursor, the lists either side, the
///   list before, Everything — are read and shaped in the background, so it
///   finds them resident.
@MainActor
extension WorkspaceViewModel {
  /// Runs a switch: timed under `name` (`SwitchSignpost`), allowed to draw a
  /// kept combined scope while it is read again, and followed by reading
  /// ahead the scopes beside the new one.
  func switchScope(_ name: StaticString, _ body: () -> Void) {
    SwitchSignpost.measure(name) {
      scopeReadMayBeStale = true
      body()
      if refreshDepth == 0 { scopeReadMayBeStale = false }
    }
    prefetchAdjacentScopes()
  }

  /// What the main pane is drawn from now.
  var currentScope: WorkspaceScope? {
    if isMultiListScope {
      if let filter = selectedFilterList {
        return .filter(filter.id, lists.filter { $0.completedAt == nil }.map(\.id))
      }
      return combinedScope(folderID: selectedFolderID)
    }
    return selectedListID.map(WorkspaceScope.list)
  }

  var scopeShapeOptions: WorkspaceScopeShapeOptions {
    // A combined scope enters no task and has no wrapper root, so its shapes
    // are kept under one key whatever was last entered elsewhere.
    isMultiListScope
      ? WorkspaceScopeShapeOptions(
        scopeTaskID: nil, registeredRootTaskID: nil, hidesCompletedTasks: scopeHidesCompletedTasks)
      : WorkspaceScopeShapeOptions(
        scopeTaskID: scopeTaskID, registeredRootTaskID: selectedList?.visibleRootTaskId,
        hidesCompletedTasks: hidesCompletedTasks)
  }

  /// The cutoff a combined read leaves finished work out before.
  private func scopeReadCutoff(_ scope: WorkspaceScope, now: Date) -> Date? {
    guard scope.isCombined, scopeHidesCompletedTasks else { return nil }
    return now.addingTimeInterval(-Self.completedLingerInterval)
  }

  /// Makes sure the cache holds a read of `scope` the pane may draw: current,
  /// or — on a switch, for a combined scope — kept and being read again.
  func ensureScopeRead(_ scope: WorkspaceScope, store: WorkspaceStore) throws {
    let stamp = try store.changeStamp()
    if let entry = scopeCache.entry(for: scope),
      // A read that left finished work in the core cannot show it.
      entry.cutoff == nil || scopeHidesCompletedTasks
    {
      if entry.stamp == stamp {
        scopeCache.touch(scope)
        return
      }
      if scopeReadMayBeStale, scope.isCombined {
        scopeCache.touch(scope)
        revalidateScope(scope, store: store)
        return
      }
    }
    let cutoff = scopeReadCutoff(scope, now: Date())
    let read = try store.scopeRead(scope, hidingCompletedBefore: cutoff)
    // A combined read takes milliseconds to compare, and one read again on
    // this thread follows a write, which has most likely changed it: shaped
    // afresh rather than compared first. A list's read is cheap to compare,
    // and a match keeps its shapes.
    let combined = scope.isCombined
    scopeCache.store(read, for: scope, stamp: stamp, cutoff: cutoff, knownToDiffer: combined)
  }

  /// Reads a kept scope again off this thread, and shapes it there too. If
  /// the answer differs and the scope is still on screen, the pane is
  /// refreshed from it, which then has only its indexes to build.
  private func revalidateScope(_ scope: WorkspaceScope, store: WorkspaceStore) {
    guard revalidatingScopes.insert(scope).inserted else { return }
    let held = scopeCache.entry(for: scope)?.read
    let cutoff = scopeReadCutoff(scope, now: Date())
    let options = scopeShapeOptions
    let wantsOutline = viewMode == .outline
    let wantsBoard = isBoardOnScreen
    Task.detached(priority: .userInitiated) { [weak self] in
      let result = Result { () throws -> ScopeRevalidation in
        // Before the read, so a write landing in between leaves it behind.
        let stamp = try store.changeStamp()
        let read = try store.scopeRead(scope, hidingCompletedBefore: cutoff, inBackground: true)
        // Compared here, so an unchanged answer costs the main thread nothing.
        guard read != held else { return ScopeRevalidation(stamp: stamp, read: nil, outline: nil, board: nil) }
        let now = Date()
        return ScopeRevalidation(
          stamp: stamp, read: read,
          outline: wantsOutline ? WorkspaceScopeShaping.outline(read, options: options, now: now) : nil,
          board: wantsBoard ? WorkspaceScopeShaping.board(read, options: options, now: now) : nil)
      }
      await self?.finishRevalidation(scope, result: result, options: options, cutoff: cutoff, store: store)
    }
  }

  private func finishRevalidation(
    _ scope: WorkspaceScope, result: Result<ScopeRevalidation, Error>, options: WorkspaceScopeShapeOptions,
    cutoff: Date?, store: WorkspaceStore
  ) {
    revalidatingScopes.remove(scope)
    guard self.store === store, case .success(let value) = result else { return }
    guard let read = value.read else {
      scopeCache.confirm(scope, at: value.stamp)
      return
    }
    guard scopeCache.store(read, for: scope, stamp: value.stamp, cutoff: cutoff, knownToDiffer: true) else { return }
    scopeCache.keepShapes(for: scope, options: options, outline: value.outline, board: value.board)
    guard scope == currentScope else { return }
    SwitchSignpost.event("Revalidated scope changed")
    // What was drawn kept was older than the stamp the task cache last
    // noted, so the rebuild below has to say the tasks changed.
    taskContentStamp = nil
    reloadOutline(refreshSidebar: false)
  }

  /// Reads the scopes the next switch is likely to land on, off this thread,
  /// so it finds them resident and already shaped. Coalesced to one pass per
  /// turn of the run loop. See `scopePrefetchCandidates`.
  func prefetchAdjacentScopes() {
    guard !scopePrefetchQueued, store != nil else { return }
    scopePrefetchQueued = true
    Task { @MainActor [weak self] in self?.launchScopePrefetch() }
  }

  /// The combined scope Everything (nil) or a folder is drawn from: its open
  /// lists, in sidebar order. The same answer as `currentScope` gives there.
  func combinedScope(folderID: String?) -> WorkspaceScope {
    let open = lists.filter { $0.completedAt == nil }
    guard let folderID else { return .combined(open.map(\.id)) }
    let openIDs = Set(open.map(\.id))
    return .combined(listIDs(inFolder: folderID).filter { openIDs.contains($0) })
  }

  /// Where the next switch probably goes, cheapest first:
  ///
  /// - the rows either side of the sidebar's cursor, for `j` and `k`, which
  ///   switch as they move;
  /// - the lists either side in sidebar order, for ⌥⌘↑ and ⌥⌘↓;
  /// - the list before this one, for ⌃-;
  /// - Everything, never yet read: the one scope that takes tens of
  ///   milliseconds to read cold, and ⌘0 away from anywhere.
  ///
  /// Each with the shape options the switch to it will ask for, so its first
  /// draw shapes nothing either. A nested list is read, not shaped: it opens
  /// with its task entered.
  private func scopePrefetchCandidates() -> [ScopePrefetchRequest] {
    var requests: [ScopePrefetchRequest] = []
    let current = currentScope
    let listsByID = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func add(_ scope: WorkspaceScope, shapes: Bool = true) {
      guard scope != current, !requests.contains(where: { $0.scope == scope }) else { return }
      if case .combined(let ids) = scope, ids.isEmpty { return }
      let options: WorkspaceScopeShapeOptions?
      switch scope {
      case .list(let id):
        options = shapes
          ? WorkspaceScopeShapeOptions(
            scopeTaskID: nil, registeredRootTaskID: listsByID[id]?.visibleRootTaskId,
            hidesCompletedTasks: hidesCompletedTasks)
          : nil
      case .combined:
        options = WorkspaceScopeShapeOptions(
          scopeTaskID: nil, registeredRootTaskID: nil, hidesCompletedTasks: hidesCompletedTasks)
      case .filter:
        return
      }
      requests.append(ScopePrefetchRequest(
        scope: scope, options: options,
        cutoff: scope.isCombined && hidesCompletedTasks ? Date().addingTimeInterval(-Self.completedLingerInterval) : nil,
        // A combined scope opens as a board, except a folder from the outline.
        outline: !scope.isCombined || viewMode == .outline, board: true))
    }

    let rows = sidebarRows
    if let cursor = sidebarCursorRow, let index = rows.firstIndex(where: { $0.id == cursor.id }) {
      for neighbour in [index + 1, index - 1] where rows.indices.contains(neighbour) {
        switch rows[neighbour].kind {
        case .list(let id) where listsByID[id]?.completedAt == nil: add(.list(id))
        case .nestedList(let id):
          if let listID = nestedLists.first(where: { $0.task.id == id })?.task.listId { add(.list(listID), shapes: false) }
        case .folder(let id): add(combinedScope(folderID: id))
        case .everything, .today, .list, .filterList: break
        }
      }
    }
    let ordered = listsInSidebarOrder.filter { $0.completedAt == nil }
    if case .list(let id) = current, let index = ordered.firstIndex(where: { $0.id == id }) {
      if index + 1 < ordered.count { add(.list(ordered[index + 1].id)) }
      if index > 0 { add(.list(ordered[index - 1].id)) }
    } else if let first = ordered.first {
      add(.list(first.id))
    }
    if let previous = listBackStack.last, listsByID[previous]?.completedAt == nil { add(.list(previous)) }
    let everything = combinedScope(folderID: nil)
    if scopeCache.entry(for: everything) == nil {
      add(everything)
    }
    return requests
  }

  private func launchScopePrefetch() {
    scopePrefetchQueued = false
    guard let store else { return }
    var requests = scopePrefetchCandidates()
    let held = Dictionary(uniqueKeysWithValues: requests.compactMap { request in
      scopeCache.entry(for: request.scope).map { (request.scope, (stamp: $0.stamp, read: $0.read)) }
    })
    requests.removeAll { revalidatingScopes.contains($0.scope) }
    guard !requests.isEmpty else { return }
    let scopes = requests.map(\.scope)
    revalidatingScopes.formUnion(scopes)
    Task.detached(priority: .utility) { [weak self] in
      var results: [ScopePrefetch] = []
      if let stamp = try? store.changeStamp() {
        for request in requests where held[request.scope]?.stamp != stamp {
          guard let read = try? store.scopeRead(request.scope, hidingCompletedBefore: request.cutoff, inBackground: true)
          else { continue }
          // Compared here, as a reread is: an unchanged answer keeps the
          // shapes already made from it, and costs the main thread nothing.
          if read == held[request.scope]?.read {
            results.append(ScopePrefetch(request: request, stamp: stamp, read: nil, outline: nil, board: nil))
            continue
          }
          let now = Date()
          let options = request.options
          results.append(ScopePrefetch(
            request: request, stamp: stamp, read: read,
            outline: options.flatMap { request.outline ? WorkspaceScopeShaping.outline(read, options: $0, now: now) : nil },
            board: options.flatMap { request.board ? WorkspaceScopeShaping.board(read, options: $0, now: now) : nil }))
        }
      }
      await self?.finishPrefetch(scopes, results: results, store: store)
    }
  }

  private func finishPrefetch(_ scopes: [WorkspaceScope], results: [ScopePrefetch], store: WorkspaceStore) {
    revalidatingScopes.subtract(scopes)
    guard self.store === store else { return }
    for result in results {
      let scope = result.request.scope
      guard let read = result.read else {
        scopeCache.confirm(scope, at: result.stamp)
        continue
      }
      // Held apart until used, so a prefetch never pushes out a scope you
      // have actually been to in favour of one you have not.
      guard scopeCache.store(
        read, for: scope, stamp: result.stamp, cutoff: result.request.cutoff, asPrefetch: true, knownToDiffer: true)
      else { continue }
      if let options = result.request.options {
        scopeCache.keepShapes(for: scope, options: options, outline: result.outline, board: result.board)
      }
    }
  }
}

/// A scope to read ahead, and how to shape it: `options` nil reads it only.
struct ScopePrefetchRequest: Sendable {
  let scope: WorkspaceScope
  let options: WorkspaceScopeShapeOptions?
  let cutoff: Date?
  let outline: Bool
  let board: Bool
}

/// A scope read ahead, shaped off the main thread: `read` is nil when it
/// matched the read already held.
struct ScopePrefetch: Sendable {
  let request: ScopePrefetchRequest
  let stamp: WorkspaceChangeStamp
  let read: WorkspaceScopeRead?
  let outline: (items: [TaskOutlineItem], expiry: Date?)?
  let board: (board: WorkspaceBoardShape, expiry: Date?)?
}

/// A background reread's answer: `read` is nil when it matched the read
/// already held.
struct ScopeRevalidation: Sendable {
  let stamp: WorkspaceChangeStamp
  let read: WorkspaceScopeRead?
  let outline: (items: [TaskOutlineItem], expiry: Date?)?
  let board: (board: WorkspaceBoardShape, expiry: Date?)?
}

/// One board's indexes, kept under the shape they were built from. See
/// `WorkspaceViewModel.rebuildBoardIndex()`.
struct BoardIndexMemo {
  struct Key: Equatable {
    /// `WorkspaceScopeCache`'s number for the board shape.
    let generation: Int
    let columns: [WorkspaceKanbanColumn]
    /// Where the rule columns and an entered card's floor put tasks.
    let placements: [String: String]
    let folded: Set<String>
  }

  let key: Key
  let columnsByID: [String: WorkspaceKanbanColumn]
  let visible: Set<String>
  let byColumn: [String: [WorkspaceTask]]
  let quadrants: MatrixQuadrantIndex<WorkspaceTask>
  let rowsByColumn: [String: BoardColumnRows]
  let links: BoardLinks
}
