import Foundation
import TaktRustCore

/// A combined scope's board — Everything's or a folder's — as the Rust core
/// selected and walked it (`board::combined_board`), so only the rows the
/// board draws cross rather than every task in every list.
///
/// The same answer as the Swift path over every list's tree: the cards are
/// `WorkspaceListTree.actionableTasks(visibleRootTaskId:)` list by list, and
/// `descendants` and `parentIDs` are `WorkspaceBoardTrees(cardIDs:trees:)`'s,
/// a parent named by id. A test holds the two to the same board.
public struct WorkspaceBoardRead: Sendable, Equatable {
  /// The open, doable tasks of every list in scope, in sidebar order.
  public var cards: [WorkspaceTask]
  /// Every level beneath each card and beneath every task inside a card's
  /// tree, as `WorkspaceBoardTrees.descendants`, less the finished rows the
  /// read was told to leave out.
  public var descendants: [String: [TaskOutlineItem]]
  /// Each task's parent, for every task the walk reached in a list holding a
  /// card. `WorkspaceBoardTrees.parents`, by id.
  public var parentIDs: [String: String]
  /// The column each drawn task is filed in, where it is filed in one.
  public var columns: [String: String]
  /// Every drawn task's matrix place, unplaced where it has none.
  public var positions: [String: TaskMatrixPosition]

  public init(
    cards: [WorkspaceTask], descendants: [String: [TaskOutlineItem]], parentIDs: [String: String],
    columns: [String: String], positions: [String: TaskMatrixPosition]
  ) {
    self.cards = cards
    self.descendants = descendants
    self.parentIDs = parentIDs
    self.columns = columns
    self.positions = positions
  }

  public static let empty = WorkspaceBoardRead(cards: [], descendants: [:], parentIDs: [:], columns: [:], positions: [:])
}

extension WorkspaceStore {
  /// The core's packed indexes: a run of little-endian `UInt32`s, read in
  /// one go rather than one value at a time across the boundary.
  static func unpacked(_ bytes: Data) -> [UInt32] {
    bytes.withUnsafeBytes { raw in
      (0..<raw.count / 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
    }
  }

  /// The board of `listIds`, in that order: the open lists of Everything, or
  /// of a folder.
  ///
  /// - Parameter cutoff: a finished task finished before this moment, or
  ///   with no recorded finish, is left out of the trees, as a board hiding
  ///   finished work would hide it. Its open subtasks stay, at their depth,
  ///   and it is still named as a parent. A task finished at or after it is
  ///   kept, so the caller decides about those itself. `nil` keeps them all.
  public func combinedBoard(listIds: [String], hidingCompletedBefore cutoff: Date?) throws -> WorkspaceBoardRead {
    guard !listIds.isEmpty else { return .empty }
    // Rounded down, so a task the core leaves out finished strictly before
    // the cutoff.
    let cutoffMs = cutoff.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }
    let read = try Self.mappingCoreErrors {
      try core.combinedBoard(listIds: listIds, hideCompletedBeforeMs: cutoffMs)
    }
    let rows = try PackedTaskRows.decode(read.rows)
    func id(_ node: Int) -> String {
      node < rows.count ? rows[node].id : read.otherIds[node - rows.count]
    }

    let keys = Self.unpacked(read.treeKeys)
    let treeRows = Self.unpacked(read.treeRows)
    let treeDepths = Self.unpacked(read.treeDepths)
    var descendants: [String: [TaskOutlineItem]] = .init(minimumCapacity: keys.count / 2)
    var start = 0
    for pair in stride(from: 0, to: keys.count - 1, by: 2) {
      let end = Int(keys[pair + 1])
      descendants[id(Int(keys[pair]))] = (start..<end).map {
        TaskOutlineItem(task: rows[Int(treeRows[$0])], depth: Int(treeDepths[$0]))
      }
      start = end
    }
    let parents = Self.unpacked(read.parents)
    var parentIDs: [String: String] = .init(minimumCapacity: parents.count)
    for (node, parent) in parents.enumerated() where parent != UInt32.max {
      parentIDs[id(node)] = id(Int(parent))
    }
    var columns: [String: String] = [:]
    var positions = Dictionary(uniqueKeysWithValues: rows.map {
      ($0.id, TaskMatrixPosition(urgency: nil, importance: nil))
    })
    for placement in read.placements {
      let task = rows[Int(placement.row)]
      if let column = placement.kanbanColumn { columns[task.id] = column }
      positions[task.id] = TaskMatrixPosition(
        urgency: placement.matrixUrgency.map { Int($0) }, importance: placement.matrixImportance.map { Int($0) })
    }
    return WorkspaceBoardRead(
      cards: Self.unpacked(read.cards).map { rows[Int($0)] }, descendants: descendants, parentIDs: parentIDs,
      columns: columns, positions: positions)
  }
}
