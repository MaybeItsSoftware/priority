/// How far down the board moves a subtask's card so that the line from its
/// row on the parent's card runs straight across, for the most part.
///
/// The cards stack as they would with no links (`BoardLinks`), and a line
/// from a row to a card at another height turns in the gutter between
/// (`BoardLinkRoute`). When the card sits a little *above* its row — no more
/// than about a compact card's height — the board opens that much space over
/// the card instead, and the line runs flat. Anything further, and the card
/// stays where it is and the line steps down: the levelled layout this
/// replaces held every card level with its row whatever the distance, which
/// let card-sized gaps into the columns and stacked into a staircase.
///
/// A card is only ever moved down, by whole points, never by more than
/// `cap`. A card below its row stays put, and so does one filed in an
/// earlier column than its parent: its line steps rather than the columns
/// that come first being pushed about for one that comes later.
///
/// Settled left to right, as the old levelling was: a nudge moves the cards
/// below it in its column, rows and all, and so the rows that lead out of
/// that column, so each column's nudges are worked out from the ones before
/// it. Nothing depends on a later column, so working it out again from the
/// frames the nudges produced gives the same nudges back, and the board
/// settles rather than chasing itself.
///
/// Pure arithmetic over measured heights, so it is tested without the app.
public enum BoardLinkNudge {
  /// One link's ends, as measured with the current nudges in place.
  public struct End: Equatable, Sendable {
    /// The subtask's id, which its card goes by too.
    public let childID: String
    public let sourceColumn: Int
    public let childColumn: Int
    /// The middle of the row (or the heading's label) on the parent's card,
    /// and of the subtask card's heading, in a space every column shares as
    /// if none were scrolled. Nil while that end has not been measured.
    public let sourceY: Double?
    public let targetY: Double?

    public init(childID: String, sourceColumn: Int, childColumn: Int, sourceY: Double?, targetY: Double?) {
      self.childID = childID
      self.sourceColumn = sourceColumn
      self.childColumn = childColumn
      self.sourceY = sourceY
      self.targetY = targetY
    }
  }

  /// About a compact card's height: past this the line steps down instead.
  public static let defaultCap = 56.0

  /// The space to open above each subtask's card, by its id; cards with
  /// none are left out.
  ///
  /// - Parameters:
  ///   - ends: every link, its ends measured with `current` in place.
  ///   - current: the space open above each card as it was measured.
  ///   - cap: the most a card is moved.
  public static func offsets(for ends: [End], current: [String: Double], cap: Double = defaultCap) -> [String: Double] {
    var next: [String: Double] = [:]
    // Each column's measured subtask cards, top to bottom, with the space
    // above each before and after: what a row or card further down that
    // column has been moved by is read off them.
    var settled: [Int: [(y: Double, before: Double, after: Double)]] = [:]

    func shift(inColumn column: Int, at y: Double) -> (before: Double, after: Double) {
      var before = 0.0
      var after = 0.0
      for card in settled[column] ?? [] where card.y <= y {
        before += card.before
        after += card.after
      }
      return (before, after)
    }

    let byColumn = Dictionary(grouping: ends, by: \.childColumn)
    for column in byColumn.keys.sorted() {
      let cards = byColumn[column]!.sorted {
        ($0.targetY ?? .infinity, $0.childID) < ($1.targetY ?? .infinity, $1.childID)
      }
      // Every measured card's space as it was, before any is reworked, so a
      // card's height as if nothing were moved can be told from its measure.
      let measured = cards.compactMap { card in
        card.targetY.map { (y: $0, before: current[card.childID] ?? 0) }
      }
      var placed: [(y: Double, before: Double, after: Double)] = []
      for card in cards {
        let was = current[card.childID] ?? 0
        let now: Double
        if card.childColumn <= card.sourceColumn {
          // Filed before its parent's column: never moved.
          now = 0
        } else if let targetY = card.targetY, let sourceY = card.sourceY {
          // Where the card would be with nothing above it moved, and where
          // the cards above it in this column have now been moved to.
          let natural = targetY - measured.filter { $0.y <= targetY }.reduce(0) { $0 + $1.before }
          let above = placed.reduce(0) { $0 + $1.after }
          // Where the row now is, its own column already settled.
          let rowShift = shift(inColumn: card.sourceColumn, at: sourceY)
          let row = sourceY - rowShift.before + rowShift.after
          let needed = row - (natural + above)
          let rounded = needed.rounded()
          let wanted = rounded >= 1 && needed <= cap ? rounded : 0
          // Less than a point from what it is: left alone, so a measure that
          // wobbles by a fraction never moves a card.
          now = abs(wanted - was) < 1 ? was : wanted
        } else {
          // An end not measured yet, or scrolled out of a lazy stack before
          // it ever was: left as it is.
          now = was
        }
        if now > 0 { next[card.childID] = now }
        if let targetY = card.targetY { placed.append((targetY, was, now)) }
      }
      settled[column] = placed
    }
    return next
  }
}
