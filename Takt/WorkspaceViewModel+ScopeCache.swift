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
/// - Once a switch has drawn, the lists either side of it in the sidebar are
///   read in the background, so the next ↑ or ↓ finds them resident.
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
      let open = lists.filter { $0.completedAt == nil }
      guard let ids = folderScopeListIDs else { return .combined(open.map(\.id)) }
      let openIDs = Set(open.map(\.id))
      return .combined(ids.filter { openIDs.contains($0) })
    }
    return selectedListID.map(WorkspaceScope.list)
  }

  var scopeShapeOptions: WorkspaceScopeShapeOptions {
    // A combined scope enters no task and has no wrapper root, so its shapes
    // are kept under one key whatever was last entered elsewhere.
    isMultiListScope
      ? WorkspaceScopeShapeOptions(scopeTaskID: nil, registeredRootTaskID: nil, hidesCompletedTasks: hidesCompletedTasks)
      : WorkspaceScopeShapeOptions(
        scopeTaskID: scopeTaskID, registeredRootTaskID: selectedList?.visibleRootTaskId,
        hidesCompletedTasks: hidesCompletedTasks)
  }

  /// The cutoff a combined read leaves finished work out before.
  private func scopeReadCutoff(_ scope: WorkspaceScope, now: Date) -> Date? {
    guard case .combined = scope, hidesCompletedTasks else { return nil }
    return now.addingTimeInterval(-Self.completedLingerInterval)
  }

  /// Makes sure the cache holds a read of `scope` the pane may draw: current,
  /// or — on a switch, for a combined scope — kept and being read again.
  func ensureScopeRead(_ scope: WorkspaceScope, store: WorkspaceStore) throws {
    let stamp = try store.changeStamp()
    if let entry = scopeCache.entry(for: scope),
      // A read that left finished work in the core cannot show it.
      entry.cutoff == nil || hidesCompletedTasks
    {
      if entry.stamp == stamp {
        scopeCache.touch(scope)
        return
      }
      if scopeReadMayBeStale, case .combined = scope {
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
    let combined = if case .combined = scope { true } else { false }
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
    reloadOutline(refreshSidebar: false)
  }

  /// Reads the lists beside the one on screen, and Everything's first list
  /// from Everything, off this thread, so the likely next switch is resident.
  /// Coalesced to one pass per turn of the run loop.
  func prefetchAdjacentScopes() {
    guard !scopePrefetchQueued, store != nil else { return }
    scopePrefetchQueued = true
    Task { @MainActor [weak self] in self?.launchScopePrefetch() }
  }

  private func launchScopePrefetch() {
    scopePrefetchQueued = false
    guard let store else { return }
    let open = lists.filter { $0.completedAt == nil }
    var candidates: [WorkspaceScope] = []
    if case .list(let id) = currentScope, let index = open.firstIndex(where: { $0.id == id }) {
      if index > 0 { candidates.append(.list(open[index - 1].id)) }
      if index + 1 < open.count { candidates.append(.list(open[index + 1].id)) }
    } else if isEverythingSelected, let first = open.first {
      candidates.append(.list(first.id))
    }
    let held = Dictionary(uniqueKeysWithValues: candidates.compactMap { scope in
      scopeCache.entry(for: scope).map { (scope, $0.stamp) }
    })
    candidates.removeAll { revalidatingScopes.contains($0) }
    guard !candidates.isEmpty else { return }
    revalidatingScopes.formUnion(candidates)
    Task.detached(priority: .utility) { [weak self] in
      var reads: [(WorkspaceScope, WorkspaceChangeStamp, WorkspaceScopeRead)] = []
      if let stamp = try? store.changeStamp() {
        for scope in candidates where held[scope] != stamp {
          if let read = try? store.scopeRead(scope, hidingCompletedBefore: nil, inBackground: true) {
            reads.append((scope, stamp, read))
          }
        }
      }
      await self?.finishPrefetch(candidates, reads: reads, store: store)
    }
  }

  private func finishPrefetch(
    _ candidates: [WorkspaceScope], reads: [(WorkspaceScope, WorkspaceChangeStamp, WorkspaceScopeRead)],
    store: WorkspaceStore
  ) {
    revalidatingScopes.subtract(candidates)
    guard self.store === store else { return }
    for (scope, stamp, read) in reads {
      // Held apart until used, so a prefetch never pushes out a scope you
      // have actually been to in favour of one you have not.
      scopeCache.store(read, for: scope, stamp: stamp, cutoff: nil, asPrefetch: true)
    }
  }
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
