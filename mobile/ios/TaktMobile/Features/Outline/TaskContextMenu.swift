import TaktCore
import TaktWorkspace
import SwiftUI
import UIKit

/// What a task's menu needs to know to label itself, without reading the
/// store while a list scrolls. Every surface's row model can make one.
struct TaskMenuContext: Equatable {
  let taskID: String
  let title: String
  let status: TaskStatus
  let isList: Bool
  let isPromoted: Bool
  let isPlanned: Bool
  /// Whether outline structure applies — indent, outdent, reorder. False in
  /// combined scopes and on the day, whose rows are not siblings.
  var allowsStructure = true
}

/// The Task group of the Mac's command catalogue, as a long-press menu.
///
/// Built from `WorkspaceCommandCatalog.taskMenu` — the same rows, in the same
/// groups, with the same titles — so a command added there turns up here.
/// Commands a phone has no meaning for are left out by `isSupported`.
struct TaskContextMenu: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  let context: TaskMenuContext
  /// The surface's own way to add a subtask (the outline's inline composer);
  /// nil to add it through quick add.
  var onNewChild: (() -> Void)?
  var onNewAbove: (() -> Void)?
  /// The surface's own way to rename in place; nil to open the inspector.
  var onRename: (() -> Void)?

  var body: some View {
    ForEach(Array(WorkspaceCommandCatalog.taskMenu.enumerated()), id: \.offset) { _, group in
      Section {
        ForEach(group.filter(isSupported), id: \.self) { id in
          item(id)
        }
      }
    }
  }

  private func isSupported(_ id: WorkspaceCommandID) -> Bool {
    switch id {
    case .taskIndent, .taskOutdent, .taskMoveUp, .taskMoveDown:
      return context.allowsStructure
    case .taskNewAbove:
      return context.allowsStructure && onNewAbove != nil
    case .taskPromoteList:
      return context.isList
    case .taskStartFocus:
      return !context.isList && context.status == .open
    case .taskToggleInspector:
      return false
    default:
      return true
    }
  }

  @ViewBuilder
  private func item(_ id: WorkspaceCommandID) -> some View {
    let role: ButtonRole? = id == .taskDelete ? .destructive : nil
    if id == .taskMove {
      Button { model.navigation.movingTaskID = context.taskID } label: {
        Label("Move to list…", systemImage: Self.symbol(for: id))
      }
    } else {
      Button(role: role) { run(id) } label: {
        Label(title(for: id), systemImage: Self.symbol(for: id))
      }
    }
  }

  private func title(for id: WorkspaceCommandID) -> String {
    switch id {
    case .taskComplete: return context.status == .open ? "Complete" : "Reopen"
    case .taskInvalidate: return context.status == .cancelled ? "Reopen" : "Invalidate"
    case .taskTogglePlannedToday: return context.isPlanned ? "Take off today" : "Plan for today"
    case .taskToggleDaily: return model.isDaily(context.taskID) ? "Stop daily progress" : "Make daily progress"
    case .taskConvertToList: return context.isList ? "Convert to task" : "Convert to list"
    case .taskPromoteList: return context.isPromoted ? "Unpin from lists" : "Pin to lists"
    case .taskNewChild: return "New subtask"
    case .taskNewAbove: return "New task above"
    case .taskShowProgress: return "Show progress"
    default:
      // The catalogue's titles are written for a menu bar ("Move Task Up");
      // sentence case reads better in a context menu.
      let title = WorkspaceCommandCatalog[id].title
      return title.prefix(1) + title.dropFirst().lowercased()
    }
  }

  private func run(_ id: WorkspaceCommandID) {
    let taskID = context.taskID
    switch id {
    case .taskComplete: model.toggleComplete(taskID)
    case .taskInvalidate: model.toggleInvalidated(taskID)
    case .taskDelete: model.delete(taskID)
    case .taskStartFocus: model.requestFocus(on: taskID, isPad: isPad)
    case .taskNewAbove: onNewAbove?()
    case .taskNewChild:
      if let onNewChild { onNewChild() } else { model.navigation.quickAddParentTaskID = taskID; model.navigation.isQuickAddPresented = true }
    case .taskRename:
      if let onRename { onRename() } else { model.navigation.inspect(taskID, isPad: isPad) }
    case .taskEditDue, .taskEditStart, .taskEditEstimate, .taskEditNotes, .taskEditTags,
      .taskEditRecurrence, .taskToggleInspector:
      model.navigation.inspect(taskID, isPad: isPad)
    case .taskDueToday: model.setDue(taskID, daysFromToday: 0)
    case .taskDueTomorrow: model.setDue(taskID, daysFromToday: 1)
    case .taskClearDue: model.clearDue(taskID)
    case .taskClearNotes: model.editValues(taskID) { $0.notes = "" }
    case .taskClearTags: model.editValues(taskID) { $0.tags = "" }
    case .taskIndent: model.indent(taskID)
    case .taskOutdent: model.outdent(taskID)
    case .taskMoveUp: model.move(taskID, by: -1)
    case .taskMoveDown: model.move(taskID, by: 1)
    case .taskMoveToPreviousList: model.moveToAdjacentList(taskID, by: -1)
    case .taskMoveToNextList: model.moveToAdjacentList(taskID, by: 1)
    case .taskMove: model.navigation.movingTaskID = taskID
    case .taskConvertToList: model.toggleListKind(taskID)
    case .taskPromoteList: model.togglePromoted(taskID)
    case .taskExtractBranch: model.extractBranch(taskID)
    case .taskTogglePlannedToday: model.togglePlannedToday(taskID)
    case .taskToggleDaily: model.toggleDaily(taskID)
    case .taskOpenLink: model.openFirstLink(taskID)
    case .taskShowProgress: model.showProgress(taskID)
    case .taskClearPriority: model.clearPriority(taskID)
    default: break
    }
  }

  static func symbol(for id: WorkspaceCommandID) -> String {
    switch id {
    case .taskComplete: "checkmark.square"
    case .taskInvalidate: "xmark.square"
    case .taskStartFocus: "scope"
    case .taskDelete: "trash"
    case .taskNewAbove: "arrow.up.to.line"
    case .taskNewChild: "arrow.turn.down.right"
    case .taskRename: "pencil"
    case .taskEditDue: "calendar"
    case .taskEditStart: "calendar.badge.clock"
    case .taskEditEstimate: "timer"
    case .taskEditNotes: "note.text"
    case .taskEditTags: "number"
    case .taskEditRecurrence: "repeat"
    case .taskDueToday: "sun.max"
    case .taskDueTomorrow: "sunrise"
    case .taskClearDue: "calendar.badge.minus"
    case .taskClearNotes: "text.badge.minus"
    case .taskClearTags: "tag.slash"
    case .taskIndent: "increase.indent"
    case .taskOutdent: "decrease.indent"
    case .taskMoveUp: "arrow.up"
    case .taskMoveDown: "arrow.down"
    case .taskMoveToPreviousList: "arrow.up.to.line.compact"
    case .taskMoveToNextList: "arrow.down.to.line.compact"
    case .taskMove: "folder"
    case .taskConvertToList: "list.bullet.rectangle"
    case .taskPromoteList: "pin"
    case .taskExtractBranch: "arrow.up.right.square"
    case .taskTogglePlannedToday: "sun.max.circle"
    case .taskToggleDaily: "repeat.circle"
    case .taskOpenLink: "link"
    case .taskShowProgress: "chart.bar"
    case .taskClearPriority: "flag.slash"
    default: "circle"
    }
  }
}

private struct IsPadLayoutKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Whether the iPad split layout is showing — the inspector is a column
  /// rather than a sheet, and root views are sidebar rows rather than tabs.
  var isPadLayout: Bool {
    get { self[IsPadLayoutKey.self] }
    set { self[IsPadLayoutKey.self] = newValue }
  }
}
