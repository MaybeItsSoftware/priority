import Foundation
import Observation
import TaktCore
import TaktWorkspace

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

  /// The cell a stored position falls in, by the core's rule; nil while
  /// either axis is unset.
  init?(_ position: TaskMatrixPosition) {
    guard
      let quadrant = MatrixQuadrantCell.of(urgency: position.urgency, importance: position.importance),
      let cell = Self.allCases.first(where: { $0.quadrant == quadrant })
    else { return nil }
    self = cell
  }

  /// The cell in `MatrixQuadrantIndex`'s reading order.
  var quadrant: MatrixQuadrantCell {
    MatrixQuadrantCell(urgency: position.urgency ?? 0, importance: position.importance ?? 0)
  }
}

/// The matrix over a scope's board cards: which quadrant each sits in, and
/// placing them.
@MainActor
@Observable
final class MatrixModel {
  let scope: ListScope
  private(set) var cards: [BoardCard] = [] {
    didSet { arrange() }
  }
  private(set) var positions: [String: TaskMatrixPosition] = [:] {
    didSet { arrange() }
  }
  /// The cards sorted into the quadrants once, when they or their positions
  /// change, by the core's rule (`MatrixQuadrantIndex`); a render only reads.
  private(set) var unplaced: [BoardCard] = []
  private var quadrantCards: [MatrixCell: [BoardCard]] = [:]
  private var cellByID: [String: MatrixCell] = [:]
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
    cellByID[cardID]
  }

  /// A quadrant's cards in the order the Mac draws them: those dropped at a
  /// point first, by rank (`v22_matrix_order`), then the rest in board order.
  func cards(in cell: MatrixCell) -> [BoardCard] {
    quadrantCards[cell] ?? []
  }

  private func arrange() {
    let index = MatrixQuadrantIndex(
      cards,
      position: { [positions] card in (positions[card.id]?.urgency, positions[card.id]?.importance) },
      rank: { [positions] card in positions[card.id]?.rank })
    unplaced = index.unplaced
    var byCell: [MatrixCell: [BoardCard]] = [:]
    var cells: [String: MatrixCell] = [:]
    for cell in MatrixCell.allCases {
      let placed = index.items(in: cell.quadrant)
      byCell[cell] = placed
      for card in placed { cells[card.id] = cell }
    }
    quadrantCards = byCell
    cellByID = cells
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
