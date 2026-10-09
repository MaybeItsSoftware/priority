/// The Eisenhower matrix's tasks, sorted into their quadrants in one pass.
///
/// The matrix used to filter the whole board once for the unplaced tasks and
/// three times more for each of its four quadrants — a count, the rows and an
/// emptiness check — on every render. This is that sorting done once, when
/// the board is read, keeping the board's order within each quadrant.
public struct MatrixQuadrantIndex<Item: Equatable>: Equatable {
  public struct Cell: Hashable, Sendable {
    public let urgency: Int
    public let importance: Int

    public init(urgency: Int, importance: Int) {
      self.urgency = urgency
      self.importance = importance
    }
  }

  /// Items missing either coordinate, in the order they were given.
  public private(set) var unplaced: [Item] = []
  private var placed: [Cell: [Item]] = [:]

  public init() {}

  /// - Parameter position: an item's urgency and importance; nil for either
  ///   leaves the item unplaced.
  public init(_ items: [Item], position: (Item) -> (urgency: Int?, importance: Int?)) {
    for item in items {
      let coordinates = position(item)
      if let urgency = coordinates.urgency, let importance = coordinates.importance {
        placed[Cell(urgency: urgency, importance: importance), default: []].append(item)
      } else {
        unplaced.append(item)
      }
    }
  }

  public func items(urgency: Int, importance: Int) -> [Item] {
    placed[Cell(urgency: urgency, importance: importance)] ?? []
  }
}
