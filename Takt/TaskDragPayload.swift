import CoreTransferable
import Foundation
import TaktCore
import UniformTypeIdentifiers

/// What a dragged task carries between the views that can accept it.
///
/// The board used to drag `String(task.id)` and drop with
/// `.dropDestination(for: String.self)`, which had two costs. It accepted *any*
/// string — a fragment of text dragged in from another app parsed as a task ID
/// if it happened to be digits — and it had nowhere to put anything beyond the
/// ID, so a drop could not know which column the card came from.
///
/// Now that the matrix, priority and due views are all becoming drop targets
/// too, the payload is the shared vocabulary between them: one draggable card
/// type, several surfaces that each write the axis they display.
///
/// The transfer representation is JSON rather than a bespoke exported UTI,
/// because the app generates its `Info.plist` from build settings
/// (`GENERATE_INFOPLIST_FILE = YES`) and so has nowhere to declare one. A
/// foreign JSON file dropped on the board would decode only if it happened to
/// match this shape exactly; `TaskDropResolver.resolve` then rejects it anyway
/// unless the ID names a task that is actually in the list.
struct TaskDragPayload: Codable, Transferable, Equatable {
  let taskId: Int
  /// Which kanban column the drag started in, when it started on the board.
  /// `nil` for a drag that began anywhere else — the matrix, a list row, the
  /// unplaced rail — and used only to tell a reorder from a column change.
  let sourceColumnId: String?

  init(taskId: Int, sourceColumnId: String? = nil) {
    self.taskId = taskId
    self.sourceColumnId = sourceColumnId
  }

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .json)
  }
}
