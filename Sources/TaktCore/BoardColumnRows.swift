/// One board column's rows as the arrow keys walk them — each card, then the
/// subtask rows drawn on it — and which card each row is drawn on.
///
/// Worked out once per board read and once per fold. The board used to work
/// it out per arrow key: the active column flattened every card's tree to ask
/// whether it held the selection, and the selected column asked again, card
/// by card, to find the card to ring.
public struct BoardColumnRows: Equatable, Sendable {
  /// Every row in the column, top to bottom.
  public let ids: [String]
  /// The card each row is drawn on; a card maps to itself. A row drawn on two
  /// cards in one column belongs to the first, as a top-down search found.
  public let cardByRow: [String: String]

  public static let empty = BoardColumnRows(cards: [])

  /// - Parameter cards: each card's id and the ids of the subtask rows drawn
  ///   on it, in column order.
  public init(cards: [(id: String, rowIDs: [String])]) {
    var ids: [String] = []
    var cardByRow: [String: String] = [:]
    for card in cards {
      ids.append(card.id)
      if cardByRow[card.id] == nil { cardByRow[card.id] = card.id }
      for row in card.rowIDs {
        ids.append(row)
        if cardByRow[row] == nil { cardByRow[row] = card.id }
      }
    }
    self.ids = ids
    self.cardByRow = cardByRow
  }

  /// Whether the row is drawn in this column.
  public func contains(_ rowID: String) -> Bool { cardByRow[rowID] != nil }
}
