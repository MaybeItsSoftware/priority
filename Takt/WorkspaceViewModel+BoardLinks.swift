import Foundation
import TaktCore
import TaktWorkspace

/// The board's links between a subtask card and the card it hangs from.
///
/// The structure (`BoardLinks`) is rebuilt with the row index, once per board
/// read and once per fold. Nothing about it turns on how tall a card is: the
/// two ends name each other rather than being joined by a line, so the cards
/// stack as they would with no links at all.
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
  }

  /// Selects a link's subtask card in its own column, from the row or
  /// heading on its parent's card that names the column.
  func selectBoardLinkedCard(_ childID: String) {
    guard let link = boardLinks.link(forChild: childID), boardColumns.indices.contains(link.childColumn),
      let task = task(withID: childID)
    else { return }
    focusedBoardColumnID = boardColumns[link.childColumn].id
    selectTask(task)
    reportKeyboardFocus(.tasks)
  }

  /// Selects the card a subtask card hangs from, from the caption that
  /// names it.
  func selectBoardLinkSource(of childID: String) {
    guard let link = boardLinks.link(forChild: childID), boardColumns.indices.contains(link.sourceColumn),
      let task = task(withID: link.sourceCardID)
    else { return }
    focusedBoardColumnID = boardColumns[link.sourceColumn].id
    selectTask(task)
    reportKeyboardFocus(.tasks)
  }

  /// The link under the pointer, lit at both ends as a selected one is.
  func hoverBoardLink(_ childID: String, _ hovering: Bool) {
    if hovering {
      if hoveredBoardLinkID != childID { hoveredBoardLinkID = childID }
    } else if hoveredBoardLinkID == childID {
      hoveredBoardLinkID = nil
    }
  }
}
