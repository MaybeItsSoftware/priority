/// The Eisenhower matrix's tasks, sorted into their quadrants in one pass.
///
/// The matrix used to filter the whole board once for the unplaced tasks and
/// three times more for each of its four quadrants — a count, the rows and an
/// emptiness check — on every render. This is that sorting done once, when
/// the board is read. Within a quadrant the tasks dropped at a point come
/// first, by their rank, then the rest in the board's order.
public struct MatrixQuadrantIndex<Item: Equatable>: Equatable {
  public typealias Cell = MatrixQuadrantCell

  /// Items missing either coordinate, in the order they were given.
  public private(set) var unplaced: [Item] = []
  private var placed: [Cell: [Item]] = [:]

  public init() {}

  /// - Parameters:
  ///   - position: an item's urgency and importance; nil for either leaves
  ///     the item unplaced.
  ///   - rank: an item's place within its quadrant, lowest first; nil puts
  ///     it after the ranked ones.
  public init(
    _ items: [Item],
    position: (Item) -> (urgency: Int?, importance: Int?),
    rank: (Item) -> Int? = { _ in nil }
  ) {
    var ranked: [Cell: [(rank: Int?, index: Int, item: Item)]] = [:]
    for (index, item) in items.enumerated() {
      let coordinates = position(item)
      if let urgency = coordinates.urgency, let importance = coordinates.importance {
        ranked[Cell(urgency: urgency, importance: importance), default: []]
          .append((rank(item), index, item))
      } else {
        unplaced.append(item)
      }
    }
    for (cell, entries) in ranked {
      placed[cell] = entries.sorted { lhs, rhs in
        switch (lhs.rank, rhs.rank) {
        case let (left?, right?): left == right ? lhs.index < rhs.index : left < right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs.index < rhs.index
        }
      }.map(\.item)
    }
  }

  public func items(urgency: Int, importance: Int) -> [Item] {
    placed[Cell(urgency: urgency, importance: importance)] ?? []
  }

  public func items(in cell: Cell) -> [Item] {
    placed[cell] ?? []
  }

  /// Every item in the order the matrix draws them: the unplaced column,
  /// then each quadrant in reading order. Up and down walk this.
  public var drawnOrder: [Item] {
    unplaced + Cell.readingOrder.flatMap { items(in: $0) }
  }
}

/// Where a task lands in a quadrant's order when it is dropped or moved.
public enum MatrixQuadrantOrder {
  /// `order` with `id` taken out of wherever it was and put before
  /// `target`, or last when `target` is nil, is `id` itself, or is not in
  /// the order.
  public static func moving<ID: Equatable>(_ id: ID, before target: ID?, in order: [ID]) -> [ID] {
    var result = order.filter { $0 != id }
    if let target, target != id, let index = result.firstIndex(of: target) {
      result.insert(id, at: index)
    } else {
      result.append(id)
    }
    return result
  }

  /// `order` with `id` stepped `offset` places along it, or nil when it is
  /// not in the order or is already at that end.
  public static func stepping<ID: Equatable>(_ id: ID, by offset: Int, in order: [ID]) -> [ID]? {
    guard let index = order.firstIndex(of: id) else { return nil }
    let destination = index + offset
    guard destination != index, order.indices.contains(destination) else { return nil }
    var result = order
    result.remove(at: index)
    result.insert(id, at: destination)
    return result
  }

  /// Where a drag at `y` would land in a quadrant drawn in `order`, given
  /// the vertical extent of each row on screen (`frames`; a row scrolled out
  /// of sight has none). Above a row's middle is before it; below the last
  /// row on screen is before the one after it, or the foot when there is
  /// none. `line` is where to draw the insertion line, nil when no row is on
  /// screen to put it against.
  public static func dropTarget<ID: Hashable>(
    at y: Double, order: [ID], frames: [ID: ClosedRange<Double>]
  ) -> (before: ID?, line: Double?) {
    var lastShown: Int?
    for (index, id) in order.enumerated() {
      guard let frame = frames[id] else { continue }
      if y < (frame.lowerBound + frame.upperBound) / 2 { return (id, frame.lowerBound) }
      lastShown = index
    }
    guard let lastShown else { return (nil, nil) }
    let next = order.index(after: lastShown)
    return (order.indices.contains(next) ? order[next] : nil, frames[order[lastShown]]?.upperBound)
  }
}

/// A quadrant of the matrix: urgency and importance, each 0 or 1.
public struct MatrixQuadrantCell: Hashable, Sendable {
  public let urgency: Int
  public let importance: Int

  public init(urgency: Int, importance: Int) {
    self.urgency = urgency
    self.importance = importance
  }

  /// The four quadrants in the order the matrix is read and `⌥1`–`⌥4`
  /// number them: do now, schedule, delegate, eliminate.
  public static let readingOrder: [MatrixQuadrantCell] = [
    MatrixQuadrantCell(urgency: 1, importance: 1),
    MatrixQuadrantCell(urgency: 0, importance: 1),
    MatrixQuadrantCell(urgency: 1, importance: 0),
    MatrixQuadrantCell(urgency: 0, importance: 0),
  ]
}
