import Foundation
import TaktCore

/// What the desktop's main pane draws from: one list, or several together
/// (Everything, a folder). See `docs/performance.md`.
public enum WorkspaceScope: Hashable, Sendable {
  case list(String)
  /// The open lists of a combined scope, in sidebar order.
  case combined([String])

  /// The lists the scope's read covers.
  public var listIDs: [String] {
    switch self {
    case .list(let id): [id]
    case .combined(let ids): ids
    }
  }
}

/// Everything the main pane is shaped from, as one read of the store. A
/// value, so it can be read off the main thread and kept between switches.
public enum WorkspaceScopeRead: Sendable, Equatable {
  /// One list's whole tree, with the column and matrix place of every task
  /// in it, so any task the list opens onto finds its placement here.
  case list(tree: WorkspaceListTree, columns: [String: String], positions: [String: TaskMatrixPosition])
  /// A combined scope's board, walked in the core.
  case combined(WorkspaceBoardRead)
}

extension WorkspaceStore {
  /// Reads `scope` once, for every view of it: the outline, the board and the
  /// matrix are all shaped from the answer (`WorkspaceScopeShaping`).
  ///
  /// - Parameter cutoff: for a combined scope, finished tasks finished before
  ///   it are left in the core; see `combinedBoard(listIds:hidingCompletedBefore:)`.
  ///   - inBackground: reads on the store's background handle, for a caller
  ///     off the main thread, so the main thread's reads and writes never
  ///     queue behind it. See `backgroundCoreStorage`.
  public func scopeRead(
    _ scope: WorkspaceScope, hidingCompletedBefore cutoff: Date?, inBackground: Bool = false
  ) throws -> WorkspaceScopeRead {
    let handle = inBackground ? try backgroundCore() : core
    switch scope {
    case .list(let id):
      let tree = try listTree(in: id, using: handle)
      let metadata = try boardMetadata(for: tree.tasks.map(\.id), using: handle)
      return .list(tree: tree, columns: metadata.columns, positions: metadata.positions)
    case .combined(let ids):
      return .combined(try combinedBoard(listIds: ids, hidingCompletedBefore: cutoff, using: handle))
    }
  }
}

/// What shapes a read into the pane, besides the read itself.
public struct WorkspaceScopeShapeOptions: Hashable, Sendable {
  /// The task whose children the pane shows, when a task has been entered.
  public var scopeTaskID: String?
  /// The list's registered root (`TaskList.visibleRootTaskId`), for the
  /// imported wrapper whose children stand in for the list's roots.
  public var registeredRootTaskID: String?
  public var hidesCompletedTasks: Bool

  public init(scopeTaskID: String?, registeredRootTaskID: String?, hidesCompletedTasks: Bool) {
    self.scopeTaskID = scopeTaskID
    self.registeredRootTaskID = registeredRootTaskID
    self.hidesCompletedTasks = hidesCompletedTasks
  }
}

/// A scope's board, shaped: the cards, every level beneath them, where each
/// is filed, and the subtasks filed further along than their card.
public struct WorkspaceBoardShape: Sendable, Equatable {
  public var parentTaskID: String?
  public var cards: [WorkspaceTask]
  public var descendants: [String: [TaskOutlineItem]]
  public var parents: [String: String]
  /// The cards and every task in their trees, each once.
  public var treeTasks: [WorkspaceTask]
  public var columns: [String: String]
  public var positions: [String: TaskMatrixPosition]
  public var crossColumnTasks: [WorkspaceTask]

  public static let empty = WorkspaceBoardShape(
    parentTaskID: nil, cards: [], descendants: [:], parents: [:], treeTasks: [], columns: [:], positions: [:],
    crossColumnTasks: [])
}

/// Turns a read into what the pane draws. Pure, so it runs on any thread and
/// its answer can be kept for as long as its inputs hold.
///
/// `expiry` is when the soonest finished task still lingering on the answer
/// leaves it: until then the same inputs give the same answer, which is what
/// lets `WorkspaceScopeCache` keep it.
public enum WorkspaceScopeShaping {
  /// How long a task you have just ticked off stays put before it goes.
  public static let completedLingerInterval: TimeInterval = 3

  /// Tracks which finished tasks are kept off the pane at `now`, and the
  /// soonest a lingering one will go.
  struct Completions {
    let hides: Bool
    let now: Date
    var expiry: Date?

    mutating func hides(_ task: WorkspaceTask) -> Bool {
      guard hides, task.status != .open else { return false }
      // Completions from before `completedAt` was recorded are long past.
      guard let completedAt = task.completedAt else { return true }
      let expires = completedAt.addingTimeInterval(WorkspaceScopeShaping.completedLingerInterval)
      guard expires > now else { return true }
      expiry = min(expiry ?? expires, expires)
      return false
    }
  }

  /// The parent whose children the pane shows in a single list.
  static func parentTaskID(tree: WorkspaceListTree, options: WorkspaceScopeShapeOptions) -> String? {
    options.scopeTaskID ?? tree.visibleRootParentTaskID(registeredRootId: options.registeredRootTaskID)
  }

  /// The outline: a list's tree under the scope's parent, or a combined
  /// scope's cards, flat.
  public static func outline(
    _ read: WorkspaceScopeRead, options: WorkspaceScopeShapeOptions, now: Date
  ) -> (items: [TaskOutlineItem], expiry: Date?) {
    var completions = Completions(hides: options.hidesCompletedTasks, now: now)
    var items: [TaskOutlineItem]
    switch read {
    case .list(let tree, _, _):
      items = tree.visibleOutline(under: parentTaskID(tree: tree, options: options))
    case .combined(let board):
      items = board.cards.map { TaskOutlineItem(task: $0, depth: 0) }
    }
    items.removeAll { completions.hides($0.task) }
    return (items, completions.expiry)
  }

  /// The board, and the matrix, which places the same cards.
  public static func board(
    _ read: WorkspaceScopeRead, options: WorkspaceScopeShapeOptions, now: Date
  ) -> (board: WorkspaceBoardShape, expiry: Date?) {
    var completions = Completions(hides: options.hidesCompletedTasks, now: now)
    var cards: [WorkspaceTask]
    let parentTaskID: String?
    let allDescendants: [String: [TaskOutlineItem]]
    let parents: [String: String]
    let allColumns: [String: String]
    let allPositions: [String: TaskMatrixPosition]
    switch read {
    case .list(let tree, let columns, let positions):
      parentTaskID = Self.parentTaskID(tree: tree, options: options)
      cards = tree.children(of: parentTaskID)
      cards.removeAll { ($0.isList && $0.archivedAt != nil) || completions.hides($0) }
      if cards.isEmpty {
        allDescendants = [:]
        parents = [:]
      } else {
        // Every level beneath every card, the nested cards' own trees
        // included, in one walk of rows already read.
        let trees = WorkspaceBoardTrees(cardIDs: Set(cards.map(\.id)), trees: [tree])
        allDescendants = trees.descendants
        parents = trees.parents.mapValues(\.id)
      }
      allColumns = columns
      allPositions = positions
    case .combined(let board):
      parentTaskID = nil
      cards = board.cards
      cards.removeAll { ($0.isList && $0.archivedAt != nil) || completions.hides($0) }
      allDescendants = board.descendants
      parents = board.parentIDs
      allColumns = board.columns
      allPositions = board.positions
    }
    let cardIDs = Set(cards.map(\.id))
    // A card's tree loses its finished rows as the outline does, once their
    // few seconds are up. Row by row: an open task under a closed one stays.
    let descendants = allDescendants.mapValues { rows in rows.filter { !completions.hides($0.task) } }
    var treeIDs = Set<String>()
    let treeTasks = (cards + cards.flatMap { descendants[$0.id, default: []].map(\.task) })
      .filter { treeIDs.insert($0.id).inserted }
    // Only the board's own rows keep their placement, as a read of just
    // those would have answered.
    let columnsByTask = allColumns.filter { treeIDs.contains($0.key) }
    // Both reads carry a place for every row, unplaced ones included.
    let positions = allPositions.filter { treeIDs.contains($0.key) }
    // A subtask nobody filed is in whatever column its parent is in.
    var effectiveColumns: [String: String] = [:]
    func effectiveColumn(ofID id: String) -> String {
      if let known = effectiveColumns[id] { return known }
      let column = columnsByTask[id]
        ?? parents[id].map { effectiveColumn(ofID: $0) }
        ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
      effectiveColumns[id] = column
      return column
    }
    let crossColumn = treeTasks.filter { task in
      if completions.hides(task) { return false }
      guard !task.isList else { return false }
      guard !cardIDs.contains(task.id), let parent = parents[task.id], let filed = columnsByTask[task.id]
      else { return false }
      return filed != effectiveColumn(ofID: parent)
    }
    let shape = WorkspaceBoardShape(
      parentTaskID: parentTaskID, cards: cards, descendants: descendants, parents: parents, treeTasks: treeTasks,
      columns: columnsByTask, positions: positions, crossColumnTasks: crossColumn)
    return (shape, completions.expiry)
  }
}

/// The scopes the pane has shown lately, kept resident so that going back to
/// one draws it without reading it again. See `docs/performance.md`.
///
/// Each entry is a read and the `WorkspaceChangeStamp` it was made at, plus
/// the outline and board last shaped from it. An entry whose stamp matches
/// the store's is current, so the switch reads nothing; one behind it is
/// stale, and is either read again or drawn while it is read again in the
/// background. Shapes are kept per options and stay good until the soonest
/// lingering completion on them expires.
///
/// Least recently used goes first once `capacity` is passed. A read stored
/// `asPrefetch` is held apart, `prefetchCapacity` of them, until it is first
/// used: guessing at the next switch never pushes out a scope you have been
/// to. Not thread-safe: the desktop owns it on the main actor and hands reads
/// made elsewhere back to it there.
public final class WorkspaceScopeCache {
  public struct Entry {
    public var read: WorkspaceScopeRead
    public var stamp: WorkspaceChangeStamp
    /// The cutoff a combined read was made with, for the background reread.
    public var cutoff: Date?
    var outlines: [WorkspaceScopeShapeOptions: (items: [TaskOutlineItem], expiry: Date?)] = [:]
    var boards: [WorkspaceScopeShapeOptions: (board: WorkspaceBoardShape, expiry: Date?, generation: Int)] = [:]
  }

  public let capacity: Int
  public let prefetchCapacity: Int
  private var entries: [WorkspaceScope: Entry] = [:]
  /// Scopes in use, most recent last.
  private var order: [WorkspaceScope] = []
  /// Scopes read ahead and not yet used, most recent last.
  private var prefetched: [WorkspaceScope] = []
  private var shapedBoards = 0

  public init(capacity: Int = 8, prefetchCapacity: Int = 2) {
    self.capacity = capacity
    self.prefetchCapacity = prefetchCapacity
  }

  /// The scopes in use, least recently used first.
  public var scopes: [WorkspaceScope] { order }
  public var prefetchedScopes: [WorkspaceScope] { prefetched }

  public func entry(for scope: WorkspaceScope) -> Entry? { entries[scope] }

  /// Keeps `read`, made at `stamp`, as the scope's answer. A read older than
  /// the one already held is ignored, so a background read that lost a race
  /// with a newer one cannot put the older answer back.
  @discardableResult
  public func store(
    _ read: WorkspaceScopeRead, for scope: WorkspaceScope, stamp: WorkspaceChangeStamp, cutoff: Date?,
    asPrefetch: Bool = false, knownToDiffer: Bool = false
  ) -> Bool {
    if let held = entries[scope], held.stamp.isNewer(than: stamp) { return false }
    // A combined read takes milliseconds to compare, so a caller that has
    // already compared it, off the main thread, says so.
    if !knownToDiffer, let held = entries[scope], held.read == read {
      // The same answer, newer: keep the shapes made from it.
      entries[scope]?.stamp = stamp
      entries[scope]?.cutoff = cutoff
    } else {
      entries[scope] = Entry(read: read, stamp: stamp, cutoff: cutoff)
    }
    if asPrefetch {
      // Already in use: it stays where it is.
      guard !order.contains(scope) else { return true }
      prefetched.removeAll { $0 == scope }
      prefetched.append(scope)
      while prefetched.count > prefetchCapacity { entries[prefetched.removeFirst()] = nil }
    } else {
      touch(scope)
    }
    return true
  }

  /// Marks a held read current at `stamp` without replacing it: a background
  /// reread found it unchanged.
  public func confirm(_ scope: WorkspaceScope, at stamp: WorkspaceChangeStamp) {
    guard let held = entries[scope], !held.stamp.isNewer(than: stamp) else { return }
    entries[scope]?.stamp = stamp
  }

  /// Counts `scope` as just used, taking a prefetched one into use.
  public func touch(_ scope: WorkspaceScope) {
    guard entries[scope] != nil else { return }
    prefetched.removeAll { $0 == scope }
    order.removeAll { $0 == scope }
    order.append(scope)
    while order.count > capacity { entries[order.removeFirst()] = nil }
  }

  public func removeAll() {
    entries = [:]
    order = []
    prefetched = []
  }

  /// The scope's outline at `now`, shaped once per read and options.
  public func outline(for scope: WorkspaceScope, options: WorkspaceScopeShapeOptions, now: Date)
    -> (items: [TaskOutlineItem], expiry: Date?)?
  {
    guard let entry = entries[scope] else { return nil }
    if let kept = entry.outlines[options], Self.holds(kept.expiry, at: now) { return kept }
    let shaped = WorkspaceScopeShaping.outline(entry.read, options: options, now: now)
    entries[scope]?.outlines[options] = shaped
    return shaped
  }

  /// The scope's board at `now`, shaped once per read and options.
  ///
  /// `generation` names the shape: the same number is the same shape, kept,
  /// so whatever a caller derives from it can be kept under that number too
  /// rather than compared field by field.
  public func board(for scope: WorkspaceScope, options: WorkspaceScopeShapeOptions, now: Date)
    -> (board: WorkspaceBoardShape, expiry: Date?, generation: Int)?
  {
    guard let entry = entries[scope] else { return nil }
    if let kept = entry.boards[options], Self.holds(kept.expiry, at: now) { return kept }
    let shaped = WorkspaceScopeShaping.board(entry.read, options: options, now: now)
    shapedBoards += 1
    let kept = (board: shaped.board, expiry: shaped.expiry, generation: shapedBoards)
    entries[scope]?.boards[options] = kept
    return kept
  }

  /// Keeps shapes made off the main thread, so drawing the scope does not
  /// shape it again. Only for the read just held: call it straight after a
  /// `store` of that read returned true, in the same turn.
  public func keepShapes(
    for scope: WorkspaceScope, options: WorkspaceScopeShapeOptions,
    outline: (items: [TaskOutlineItem], expiry: Date?)?, board: (board: WorkspaceBoardShape, expiry: Date?)?
  ) {
    guard entries[scope] != nil else { return }
    if let outline { entries[scope]?.outlines[options] = outline }
    if let board {
      shapedBoards += 1
      entries[scope]?.boards[options] = (board: board.board, expiry: board.expiry, generation: shapedBoards)
    }
  }

  /// Every lingering completion on a shape is still lingering, and every
  /// hidden one still hidden, until the soonest of them expires.
  static func holds(_ expiry: Date?, at now: Date) -> Bool {
    guard let expiry else { return true }
    return now < expiry
  }
}

extension WorkspaceChangeStamp {
  /// Whether this stamp was taken after `other`. Both halves only grow while
  /// the store is open, so either moving on is enough.
  public func isNewer(than other: WorkspaceChangeStamp) -> Bool {
    (external >= other.external && own >= other.own) && self != other
  }
}
