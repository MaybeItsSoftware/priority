import Foundation
import TaktCore
import TaktWorkspace

/// The board's links between a subtask card and the card it hangs from.
///
/// The structure (`BoardLinks`) is rebuilt with the row index, once per board
/// read and once per fold. The space it takes (`BoardLinkLayout`) turns on
/// how tall the cards are, which only the views know, so the cards in the
/// columns a link touches report their heights as they lay out, and the
/// layout is settled again once per batch of reports — never per render, and
/// not at all on a board with no links.
extension WorkspaceViewModel {
  /// Works out the links from the columns just indexed: each subtask card
  /// filed apart from its parent, and the nearest card it hangs beneath.
  func rebuildBoardLinks(columns: [[(id: String, rowIDs: [String])]]) {
    var sources: [String: String] = [:]
    var strays = Set<String>()
    for task in boardCrossColumnTasks {
      guard let parentID = boardTaskParents[task.id], let cardID = boardCardID(owning: parentID) else {
        strays.insert(task.id)
        continue
      }
      sources[task.id] = cardID
    }
    let links = sources.isEmpty && strays.isEmpty
      ? BoardLinks.empty : BoardLinks(columns: columns, sources: sources, strays: strays)
    if boardLinks != links { boardLinks = links }
    settleBoardLinks()
  }

  /// The overlap between neighbouring cards, which share a rule: the theme's
  /// hairline, which only the views read.
  func setBoardCardSpacing(_ spacing: Double) {
    guard boardLinkMetrics.cardSpacing != spacing else { return }
    boardLinkMetrics.cardSpacing = spacing
    queueBoardLinkSettle()
  }

  /// A card's height, less the space a link let into it.
  func reportBoardCardHeight(_ cardID: String, _ height: Double) {
    update(&boardLinkMetrics.cardHeights, cardID, height)
  }

  /// The middle of a card's heading, from the card's top.
  func reportBoardHeadingMid(_ cardID: String, _ mid: Double) {
    update(&boardLinkMetrics.headingMids, cardID, mid)
  }

  /// A linked row's top and middle on its card, less the space let in above
  /// it.
  func reportBoardRow(card cardID: String, row rowID: String, top: Double, mid: Double) {
    let key = BoardRowKey(card: cardID, row: rowID)
    update(&boardLinkMetrics.rowTops, key, top)
    update(&boardLinkMetrics.rowMids, key, mid)
  }

  /// Records a measurement, and settles the links again if it moved by more
  /// than layout's own rounding.
  private func update<Key: Hashable>(_ values: inout [Key: Double], _ key: Key, _ value: Double) {
    if let old = values[key], abs(old - value) < 0.5 { return }
    values[key] = value
    if !boardLinks.isEmpty { queueBoardLinkSettle() }
  }

  /// Settles once after the layout pass that is reporting, rather than once
  /// per card in it.
  private func queueBoardLinkSettle() {
    guard !boardLinkSolveQueued else { return }
    boardLinkSolveQueued = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      boardLinkSolveQueued = false
      settleBoardLinks()
    }
  }

  /// Lets in the space the links need, animated so gaps grow and close
  /// rather than jump, and plainly under Reduce Motion.
  func settleBoardLinks() {
    let layout = BoardLinkLayout.solve(boardLinks, metrics: boardLinkMetrics)
    guard layout != boardLinkLayout else { return }
    WorkspaceMotion.animate { boardLinkLayout = layout }
  }
}
