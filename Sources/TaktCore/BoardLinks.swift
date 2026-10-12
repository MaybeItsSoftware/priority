/// How the board ties a subtask filed in a column of its own to the card it
/// hangs from.
///
/// A subtask filed in a later (or earlier) column becomes a card there, and is
/// still a row on its parent's card. The two ends name each other rather than
/// being joined by a drawn line: the row keeps its title, muted, with the
/// column its card stands in at its end ("→ This week"), and the card says
/// whose it is ("← Adam's Campus Toolbox"). Selecting or hovering either end
/// lights both.
///
/// The board used to draw a hairline from the row across to the card, and to
/// hold the card level with the row so the line could run straight. That let
/// empty card-sized gaps into the later columns, left rows with no text but
/// the line, and — as soon as one card had several subtasks further on, or a
/// link had to cross a column of other cards — stacked the lines into a
/// staircase through cards that had nothing to do with them. Cards now stack
/// as every other card does, and nothing here or in the board turns on a
/// measured height.
///
/// The line is back, but only for the links `linkIDs(touching:)` lights —
/// the selection's and the pointer's — and drawn over the board from where
/// the cards already stand rather than levelling them: `BoardLinkRoute`.
///
/// Worked out once per board read and once per fold.
public struct BoardLinks: Equatable, Sendable {
  /// One subtask card and the card it hangs from.
  public struct Link: Equatable, Sendable {
    /// The subtask's own card, in another column.
    public let childID: String
    /// The nearest card the subtask hangs beneath, which draws it as a row.
    public let sourceCardID: String
    /// Whether the source card is drawing the subtask's row. When it is not
    /// — the card or a branch above the row is folded, or the row is past
    /// the card's row limit — the source card's heading carries the link,
    /// gathered with any others into its `Bundle` for the column.
    public let meetsRow: Bool
    public let sourceColumn: Int
    public let childColumn: Int

    /// Whether the subtask is further on than the card it hangs from.
    public var pointsForward: Bool { childColumn > sourceColumn }

    public init(childID: String, sourceCardID: String, meetsRow: Bool, sourceColumn: Int, childColumn: Int) {
      self.childID = childID
      self.sourceCardID = sourceCardID
      self.meetsRow = meetsRow
      self.sourceColumn = sourceColumn
      self.childColumn = childColumn
    }
  }

  /// The subtasks a card's heading stands for in one column, because the
  /// card is not drawing their rows: one "→ This week 3" on the card rather
  /// than a mark per subtask.
  public struct Bundle: Equatable, Sendable, Identifiable {
    public let column: Int
    /// Top to bottom in that column.
    public let childIDs: [String]
    public var id: Int { column }
    public var pointsForward: Bool
  }

  /// Every link, by the subtask card's id.
  public let byChild: [String: Link]
  /// Each source card's links: the rows it draws in their order, then the
  /// ones its heading carries by column and position.
  public let bySource: [String: [String]]
  /// The links each source card's heading carries, by column, left to right.
  public let headingBundles: [String: [Bundle]]
  /// Subtask cards filed apart from a parent that no card on the board
  /// draws — it is finished and hidden, say — so there is no row to name;
  /// the card says whose it is with a "↳ parent" hint.
  public let strays: Set<String>

  public static let empty = BoardLinks(columns: [], sources: [:])

  public var isEmpty: Bool { byChild.isEmpty && strays.isEmpty }

  /// - Parameters:
  ///   - columns: each column's cards top to bottom, with the subtask rows
  ///     each card draws, as `BoardColumnRows` takes them.
  ///   - sources: each subtask card filed apart from its parent, with the
  ///     nearest card it hangs beneath.
  ///   - strays: subtask cards filed apart from a parent no card draws.
  public init(
    columns: [[(id: String, rowIDs: [String])]], sources: [String: String], strays: Set<String> = []
  ) {
    var position: [String: (column: Int, card: Int, rows: [String])] = [:]
    for (columnIndex, cards) in columns.enumerated() {
      for (cardIndex, card) in cards.enumerated() where position[card.id] == nil {
        position[card.id] = (columnIndex, cardIndex, card.rowIDs)
      }
    }

    var byChild: [String: Link] = [:]
    for (childID, sourceID) in sources {
      guard let child = position[childID], let source = position[sourceID],
        child.column != source.column
      else { continue }
      byChild[childID] = Link(
        childID: childID, sourceCardID: sourceID, meetsRow: source.rows.contains(childID),
        sourceColumn: source.column, childColumn: child.column)
    }

    // Each source card's links in the order the card shows them: its rows
    // top to bottom, then its heading's, by column and then by card.
    var grouped: [String: [Link]] = [:]
    for link in byChild.values { grouped[link.sourceCardID, default: []].append(link) }
    var bySource: [String: [String]] = [:]
    var headingBundles: [String: [Bundle]] = [:]
    for (sourceID, links) in grouped {
      let rows = position[sourceID]!.rows
      let drawn = links.filter(\.meetsRow).sorted {
        rows.firstIndex(of: $0.childID)! < rows.firstIndex(of: $1.childID)!
      }
      let carried = links.filter { !$0.meetsRow }.sorted {
        (position[$0.childID]!.column, position[$0.childID]!.card)
          < (position[$1.childID]!.column, position[$1.childID]!.card)
      }
      bySource[sourceID] = (drawn + carried).map(\.childID)
      var bundles: [Bundle] = []
      for link in carried {
        if let last = bundles.last, last.column == link.childColumn {
          bundles[bundles.count - 1] = Bundle(
            column: last.column, childIDs: last.childIDs + [link.childID], pointsForward: last.pointsForward)
        } else {
          bundles.append(Bundle(column: link.childColumn, childIDs: [link.childID], pointsForward: link.pointsForward))
        }
      }
      if !bundles.isEmpty { headingBundles[sourceID] = bundles }
    }

    self.byChild = byChild
    self.bySource = bySource
    self.headingBundles = headingBundles
    self.strays = strays.subtracting(byChild.keys)
  }

  /// The link a card is the subtask end of.
  public func link(forChild id: String) -> Link? { byChild[id] }

  /// The link a row on `cardID` stands for, when the row is a subtask whose
  /// own card is in another column. A task drawn on two cards — a subtask
  /// of a subtask that is a card itself — leads out only from the card the
  /// link names.
  public func rowLink(_ rowID: String, onCard cardID: String) -> Link? {
    guard let link = byChild[rowID], link.sourceCardID == cardID, link.meetsRow else { return nil }
    return link
  }

  /// Whether the card is a subtask whose parent no card draws, and so says
  /// whose it is in words with nothing to point at.
  public func isStray(_ cardID: String) -> Bool { strays.contains(cardID) }

  /// The links to light for the selection or the pointer on `id`: its own,
  /// when it is either end of one — the subtask's row and card share an id —
  /// and, when it is a card that subtasks further on hang from, all of
  /// theirs, so selecting a card shows where its subtasks went.
  public func linkIDs(touching id: String?) -> Set<String> {
    guard let id else { return [] }
    var ids = Set(bySource[id] ?? [])
    if byChild[id] != nil { ids.insert(id) }
    return ids
  }

  /// Those of `ids` with an end in `column`, so a column is handed only the
  /// links it draws and redraws only when one of them changes.
  public func linkIDs(_ ids: Set<String>, inColumn column: Int) -> Set<String> {
    ids.filter { id in
      guard let link = byChild[id] else { return false }
      return link.sourceColumn == column || link.childColumn == column
    }
  }
}
