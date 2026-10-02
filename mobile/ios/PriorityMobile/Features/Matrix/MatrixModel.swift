import Foundation
import Observation
import PriorityWorkspace

/// One of the four Eisenhower quadrants, as the Mac's matrix files them:
/// urgency and importance are each 0 or 1. A task with either unset is
/// unplaced.
enum MatrixCell: String, CaseIterable, Identifiable, Hashable {
  case doNow, schedule, delegate, eliminate

  var id: String { rawValue }

  var title: String {
    switch self {
    case .doNow: "Do now"
    case .schedule: "Schedule"
    case .delegate: "Delegate"
    case .eliminate: "Eliminate"
    }
  }

  var detail: String {
    switch self {
    case .doNow: "Urgent and important"
    case .schedule: "Important, not urgent"
    case .delegate: "Urgent, not important"
    case .eliminate: "Neither"
    }
  }

  var position: TaskMatrixPosition {
    switch self {
    case .doNow: TaskMatrixPosition(urgency: 1, importance: 1)
    case .schedule: TaskMatrixPosition(urgency: 0, importance: 1)
    case .delegate: TaskMatrixPosition(urgency: 1, importance: 0)
    case .eliminate: TaskMatrixPosition(urgency: 0, importance: 0)
    }
  }

  init?(_ position: TaskMatrixPosition) {
    guard let cell = Self.allCases.first(where: { $0.position == position }) else { return nil }
    self = cell
  }
}

/// The matrix over a scope's board cards: which quadrant each sits in, and
/// placing them.
@MainActor
@Observable
final class MatrixModel {
  let scope: ListScope
  private(set) var cards: [BoardCard] = []
  private(set) var positions: [String: TaskMatrixPosition] = [:]
  private(set) var isLoaded = false
  @ObservationIgnored private var generation = 0

  init(scope: ListScope) {
    self.scope = scope
  }

  func load(_ model: WorkspaceModel) async {
    generation &+= 1
    let mine = generation
    let store = model.store
    let workspaceID = model.workspace.id
    let structure = model.structure
    let scope = scope
    let hides = UserDefaults.standard.bool(forKey: "outlineHidesCompleted")
    let result = await Task.detached(priority: .userInitiated) {
      try? BoardSnapshot.load(
        store: store, workspaceID: workspaceID, scope: scope, structure: structure, hidesCompleted: hides)
    }.value
    guard mine == generation, let result else { return }
    // The board's own cards, not subtasks filed in another column.
    let cards = result.allCards.filter { $0.parentTitle == nil }
    if self.cards != cards { self.cards = cards }
    if positions != result.positions { positions = result.positions }
    isLoaded = true
  }

  func cell(of cardID: String) -> MatrixCell? {
    positions[cardID].flatMap(MatrixCell.init)
  }

  func cards(in cell: MatrixCell) -> [BoardCard] {
    cards.filter { self.cell(of: $0.id) == cell }
  }

  var unplaced: [BoardCard] {
    cards.filter { cell(of: $0.id) == nil }
  }

  /// Files a card in a quadrant, or takes it out of the matrix with nil.
  func place(_ cardID: String, in cell: MatrixCell?, model: WorkspaceModel) {
    guard cards.contains(where: { $0.id == cardID }), self.cell(of: cardID) != cell else { return }
    let position = cell?.position ?? TaskMatrixPosition(urgency: nil, importance: nil)
    if model.perform({ try $0.setMatrixPosition(position, for: cardID) }) {
      positions[cardID] = position
    }
  }
}
