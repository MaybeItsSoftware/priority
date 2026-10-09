/// Which board cards are subtasks standing in a later column than the card
/// they are drawn on, and which of those can be drawn level with it.
///
/// A subtask filed in a column of its own becomes a card there, and is still
/// a row on its parent's card. The board ties the two together: the card in
/// the later column sits level with the row that stands for it, a hairline
/// running from one to the other. Getting them level takes space — a gap
/// above the card, or above the row inside the parent's card — and
/// `BoardLinkLayout` works out how much from the cards' measured heights.
///
/// This half is the structure, worked out once per board read and once per
/// fold: who links to whom, the order the links are levelled in, and which
/// cannot be levelled at all. Those fall back to a "↳ parent" hint on the
/// card. Nothing here turns on a height, so whether a card shows the hint
/// never depends on where the layout put it.
public struct BoardLinks: Equatable, Sendable {
  /// One subtask card and the card it hangs from.
  public struct Link: Equatable, Sendable {
    /// The subtask's own card, in the later column.
    public let childID: String
    /// The nearest card the subtask hangs beneath, which draws it as a row.
    public let sourceCardID: String
    /// Whether the source card is drawing the subtask's row. When it is not
    /// — the card or a branch above the row is folded, or the row is past
    /// the card's row limit — the link meets the card's heading instead.
    public let meetsRow: Bool
    public let sourceColumn: Int
    public let childColumn: Int
    /// Whether the card can be drawn level with its source: it is in a later
    /// column, nothing else claims the same row or heading, and it does not
    /// cross another link that was levelled first.
    public internal(set) var isAligned: Bool

    /// Whether the subtask is further on than the card it hangs from.
    public var pointsForward: Bool { childColumn > sourceColumn }
  }

  /// Where space can be let into a column: above a card (`slot` 0), or above
  /// the `slot`-th linked row drawn on it.
  struct Point: Hashable, Comparable {
    let column: Int
    let card: Int
    let slot: Int

    static func < (lhs: Point, rhs: Point) -> Bool {
      (lhs.card, lhs.slot) < (rhs.card, rhs.slot)
    }
  }

  /// Every link, by the subtask card's id.
  public let byChild: [String: Link]
  /// Each card's rows that a levelled link meets, in the card's row order:
  /// row id to the subtask card it stands for. The row is the subtask itself,
  /// so the two ids are the same; the map exists to say which rows have one.
  public let linkedRows: [String: [String]]
  /// The card each levelled link meets at its heading, by source card.
  public let headingLinks: [String: String]
  /// The columns a levelled link starts or ends in. Only their cards are
  /// measured, since only their heights move a link.
  public let measuredColumns: Set<Int>
  /// The cards whose heading a levelled link meets or leaves from.
  public let headingCards: Set<String>
  /// Subtask cards filed apart from a parent that no card on the board
  /// draws — it is finished and hidden, say — so there is nothing to link
  /// them to but a hint.
  public let strays: Set<String>

  /// The levelled links in the order `BoardLinkLayout` settles them, so each
  /// column's space is only ever let in below what is already settled.
  let order: [Link]
  let sourcePoints: [String: Point]
  let childPoints: [String: Point]
  /// Each measured column's cards, top to bottom.
  let columnCards: [Int: [String]]
  /// Where each linked row sits among the rows its card draws, for an
  /// estimate before the row has been measured.
  let rowOrdinals: [String: Int]

  public static let empty = BoardLinks(columns: [], sources: [:])

  public var isEmpty: Bool { byChild.isEmpty }

  /// Whether the card is a subtask filed apart from its parent that is not
  /// drawn level with it, and so says whose subtask it is in words.
  public func needsHint(_ cardID: String) -> Bool {
    if let link = byChild[cardID] { return !link.isAligned }
    return strays.contains(cardID)
  }

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

    // The links, in column order so that every tie below breaks the same way
    // whichever order the dictionary handed them over in.
    var links: [Link] = []
    for (childID, sourceID) in sources {
      guard let child = position[childID], let source = position[sourceID] else { continue }
      let link = Link(
        childID: childID, sourceCardID: sourceID, meetsRow: source.rows.contains(childID),
        sourceColumn: source.column, childColumn: child.column, isAligned: child.column > source.column)
      links.append(link)
    }
    links.sort { lhs, rhs in
      let left = position[lhs.childID]!
      let right = position[rhs.childID]!
      return (left.column, left.card) < (right.column, right.card)
    }

    // Each linked row's slot on its card, in the card's row order.
    var slots: [String: Int] = [:]
    var rowOrdinals: [String: Int] = [:]
    var rowsOnCard: [String: [String]] = [:]
    for link in links where link.meetsRow {
      rowsOnCard[link.sourceCardID, default: []].append(link.childID)
    }
    for (cardID, rows) in rowsOnCard {
      let drawn = position[cardID]!.rows
      let ordered = rows.sorted { drawn.firstIndex(of: $0)! < drawn.firstIndex(of: $1)! }
      for (slot, row) in ordered.enumerated() {
        slots[row] = slot + 1
        rowOrdinals[row] = drawn.firstIndex(of: row)!
      }
    }

    var sourcePoints: [String: Point] = [:]
    var childPoints: [String: Point] = [:]
    for link in links {
      let source = position[link.sourceCardID]!
      let child = position[link.childID]!
      sourcePoints[link.childID] = Point(
        column: source.column, card: source.card, slot: link.meetsRow ? slots[link.childID]! : 0)
      childPoints[link.childID] = Point(column: child.column, card: child.card, slot: 0)
    }

    // A point can be held level with one other only. A card both levelled
    // with its own parent and met at its heading by a folded subtask, or two
    // subtasks of one folded card, would ask one heading to sit at two
    // heights; the first link to claim it keeps it.
    var claimed = Set<Point>()
    for index in links.indices where links[index].isAligned {
      let mine = [sourcePoints[links[index].childID]!, childPoints[links[index].childID]!]
      if mine.contains(where: claimed.contains) {
        links[index].isAligned = false
      } else {
        claimed.formUnion(mine)
      }
    }

    // Settle the links so that, in every column, each one's point is below
    // every point settled before it: space let in at a point moves everything
    // under it, so a link settled out of order would undo one above it. A
    // link is ready once it heads the queue in both its columns. When none
    // is, two links cross — one is higher in its source column and lower in
    // its child column — and the upper one in the leftmost stuck column is
    // left unlevelled so the rest can go on.
    var queues: [Int: [String]] = [:]
    for link in links where link.isAligned {
      queues[link.sourceColumn, default: []].append(link.childID)
      queues[link.childColumn, default: []].append(link.childID)
    }
    func point(of childID: String, in column: Int) -> Point {
      let source = sourcePoints[childID]!
      return source.column == column ? source : childPoints[childID]!
    }
    for column in queues.keys {
      queues[column]!.sort { point(of: $0, in: column) < point(of: $1, in: column) }
    }
    var heads = Dictionary(uniqueKeysWithValues: queues.keys.map { ($0, 0) })
    var settled = Set<String>()
    var dropped = Set<String>()
    var order: [String] = []
    let queueColumns = queues.keys.sorted()
    func head(_ column: Int) -> String? {
      guard let queue = queues[column] else { return nil }
      var index = heads[column]!
      while index < queue.count, settled.contains(queue[index]) || dropped.contains(queue[index]) { index += 1 }
      heads[column] = index
      return index < queue.count ? queue[index] : nil
    }
    let linkByChild = Dictionary(uniqueKeysWithValues: links.map { ($0.childID, $0) })
    while true {
      var ready: String?
      var stuck: String?
      for column in queueColumns {
        guard let id = head(column) else { continue }
        if stuck == nil { stuck = id }
        let link = linkByChild[id]!
        let other = link.sourceColumn == column ? link.childColumn : link.sourceColumn
        if head(other) == id { ready = id; break }
      }
      if let ready {
        settled.insert(ready)
        order.append(ready)
      } else if let stuck {
        dropped.insert(stuck)
      } else {
        break
      }
    }
    for index in links.indices where dropped.contains(links[index].childID) {
      links[index].isAligned = false
    }

    var byChild: [String: Link] = [:]
    var linkedRows: [String: [String]] = [:]
    var headingLinks: [String: String] = [:]
    var measured = Set<Int>()
    var headingCards = Set<String>()
    for link in links {
      byChild[link.childID] = link
      guard link.isAligned else { continue }
      measured.insert(link.sourceColumn)
      measured.insert(link.childColumn)
      headingCards.insert(link.childID)
      if link.meetsRow {
        linkedRows[link.sourceCardID, default: []].append(link.childID)
      } else {
        headingLinks[link.sourceCardID] = link.childID
        headingCards.insert(link.sourceCardID)
      }
    }
    for (cardID, rows) in linkedRows {
      linkedRows[cardID] = rows.sorted { slots[$0]! < slots[$1]! }
    }
    var columnCards: [Int: [String]] = [:]
    for column in measured {
      columnCards[column] = columns[column].map(\.id)
    }

    self.byChild = byChild
    self.linkedRows = linkedRows
    self.headingLinks = headingLinks
    self.measuredColumns = measured
    self.headingCards = headingCards
    self.strays = strays.subtracting(byChild.keys)
    self.order = order.map { byChild[$0]! }
    self.sourcePoints = sourcePoints.filter { byChild[$0.key]?.isAligned == true }
    self.childPoints = childPoints.filter { byChild[$0.key]?.isAligned == true }
    self.columnCards = columnCards
    self.rowOrdinals = rowOrdinals.filter { byChild[$0.key]?.isAligned == true }
  }

  /// The link a card is the subtask end of.
  public func link(forChild id: String) -> Link? { byChild[id] }
}

/// A row on a card, for keying a row's measurements: a task can be drawn as a
/// row on more than one card.
public struct BoardRowKey: Hashable, Sendable {
  public let card: String
  public let row: String

  public init(card: String, row: String) {
    self.card = card
    self.row = row
  }
}

/// The board's cards as last measured, each without the space a link let
/// into it, so a measurement never feeds back into itself.
public struct BoardLinkMetrics: Equatable, Sendable {
  /// Each card's height.
  public var cardHeights: [String: Double] = [:]
  /// The middle of each card's heading, from the card's top.
  public var headingMids: [String: Double] = [:]
  /// Each linked row's top and middle, from its card's top.
  public var rowTops: [BoardRowKey: Double] = [:]
  public var rowMids: [BoardRowKey: Double] = [:]
  /// The space between one card and the next in a column: negative when
  /// neighbours overlap to share a rule.
  public var cardSpacing: Double
  /// What a card, a heading's middle and a row are taken to measure before
  /// they have been: a card off screen in a lazy column has not.
  public var estimatedCardHeight: Double
  public var estimatedHeadingMid: Double
  public var estimatedRowHeight: Double

  public init(
    cardSpacing: Double = 0, estimatedCardHeight: Double = 40, estimatedHeadingMid: Double = 16,
    estimatedRowHeight: Double = 20
  ) {
    self.cardSpacing = cardSpacing
    self.estimatedCardHeight = estimatedCardHeight
    self.estimatedHeadingMid = estimatedHeadingMid
    self.estimatedRowHeight = estimatedRowHeight
  }
}

/// How much space the board lets in to draw its links level, and where the
/// hairlines run.
public struct BoardLinkLayout: Equatable, Sendable {
  /// A hairline crossing a column between the two ends of a link.
  public struct PassingLine: Equatable, Sendable, Identifiable {
    public let childID: String
    /// From the top of the column's cards.
    public let y: Double
    public var id: String { childID }
  }

  /// One column's share.
  public struct Column: Equatable, Sendable {
    /// Space above a card, by card id.
    public var gapAbove: [String: Double] = [:]
    /// Space above a linked row inside a card.
    public var spaceAboveRow: [BoardRowKey: Double] = [:]
    /// Links passing through on their way to a later column.
    public var passingLines: [PassingLine] = []

    public init() {}

    /// The space let into a card, above its rows: what its measured height
    /// carries on top of its own.
    public func spaceInside(card: String, rows: [String]) -> Double {
      rows.reduce(0) { $0 + (spaceAboveRow[BoardRowKey(card: card, row: $1)] ?? 0) }
    }
  }

  public var columns: [Int: Column] = [:]
  /// Where each levelled link's hairline runs, from the top of the cards.
  public var lineY: [String: Double] = [:]

  public static let empty = BoardLinkLayout()

  public init() {}

  public func column(_ index: Int) -> Column { columns[index] ?? Column() }

  /// Lets in the least space that draws every levelled link level.
  ///
  /// Space only ever opens downwards: a link whose row sits higher than its
  /// card opens a gap above the row, inside the parent's card; one whose card
  /// sits higher opens a gap above the card. Links are settled in
  /// `BoardLinks`' order, every one below everything settled before it in
  /// both its columns, so a column's space so far is a running total and the
  /// whole pass is linear in the cards of the columns that hold a link.
  public static func solve(_ links: BoardLinks, metrics: BoardLinkMetrics) -> BoardLinkLayout {
    var layout = BoardLinkLayout()
    guard !links.order.isEmpty else { return layout }

    // Each measured column's natural card tops, before any space is let in.
    var tops: [String: Double] = [:]
    for (_, cards) in links.columnCards {
      let measured = cards.compactMap { metrics.cardHeights[$0] }
      let estimate = measured.isEmpty ? metrics.estimatedCardHeight : measured.reduce(0, +) / Double(measured.count)
      var y = 0.0
      for card in cards {
        tops[card] = y
        y += (metrics.cardHeights[card] ?? estimate) + metrics.cardSpacing
      }
    }
    func headingMid(_ card: String) -> Double { metrics.headingMids[card] ?? metrics.estimatedHeadingMid }

    var inserted: [Int: Double] = [:]
    for link in links.order {
      let sourcePoint = links.sourcePoints[link.childID]!
      let childPoint = links.childPoints[link.childID]!
      let rowKey = BoardRowKey(card: link.sourceCardID, row: link.childID)

      // Each end's anchor: where the point sits now, and how far below the
      // point the hairline meets it.
      let sourceTop = tops[link.sourceCardID] ?? 0
      let sourcePointY: Double
      let sourceAnchor: Double
      if link.meetsRow {
        let estimatedTop = 2 * metrics.estimatedHeadingMid
          + Double(links.rowOrdinals[link.childID] ?? 0) * metrics.estimatedRowHeight
        let rowTop = metrics.rowTops[rowKey] ?? estimatedTop
        sourcePointY = sourceTop + rowTop
        sourceAnchor = (metrics.rowMids[rowKey] ?? rowTop + metrics.estimatedRowHeight / 2) - rowTop
      } else {
        sourcePointY = sourceTop
        sourceAnchor = headingMid(link.sourceCardID)
      }
      let sourceY = sourcePointY + (inserted[sourcePoint.column] ?? 0) + sourceAnchor
      let childY = (tops[link.childID] ?? 0) + (inserted[childPoint.column] ?? 0) + headingMid(link.childID)

      if sourceY > childY {
        let gap = sourceY - childY
        layout.columns[childPoint.column, default: Column()].gapAbove[link.childID, default: 0] += gap
        inserted[childPoint.column, default: 0] += gap
      } else if childY > sourceY {
        let gap = childY - sourceY
        if link.meetsRow {
          layout.columns[sourcePoint.column, default: Column()].spaceAboveRow[rowKey, default: 0] += gap
        } else {
          layout.columns[sourcePoint.column, default: Column()].gapAbove[link.sourceCardID, default: 0] += gap
        }
        inserted[sourcePoint.column, default: 0] += gap
      }
      let y = max(sourceY, childY)
      layout.lineY[link.childID] = y
      for column in (link.sourceColumn + 1)..<link.childColumn {
        layout.columns[column, default: Column()].passingLines.append(PassingLine(childID: link.childID, y: y))
      }
    }
    return layout
  }
}
