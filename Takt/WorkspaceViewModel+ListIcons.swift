import Foundation
import TaktCore
import TaktWorkspace

/// What a sidebar row's icon belongs to.
enum WorkspaceIconTarget: Equatable {
  case list(TaskList)
  case nestedList(WorkspaceTask)
  case folder(ListFolder)
  case filterList(WorkspaceFilterList)

  /// Filter lists keep their icon in the workspace, which every client reads;
  /// an emoji there would be a string the others have to learn to draw. The
  /// rest keep theirs in this Mac's preferences, where an emoji is only ever
  /// drawn here.
  var allowsEmoji: Bool {
    if case .filterList = self { return false }
    return true
  }
}

/// Icons for lists, nested lists, folders and filter lists: what each is, and
/// the picker the sidebar opens to change it.
@MainActor
extension WorkspaceViewModel {
  /// A folder's icon, kept beside the lists' — lists and folders both carry
  /// UUIDs, so one dictionary holds both.
  func icon(forFolder folder: ListFolder) -> String {
    listIcons[folder.id] ?? "folder"
  }

  func icon(for target: WorkspaceIconTarget) -> String {
    switch target {
    case .list(let list): icon(for: list)
    case .nestedList(let task): itemSymbol(for: task)
    case .folder(let folder): icon(forFolder: folder)
    case .filterList(let filter): filter.icon ?? WorkspaceFilterList.defaultIcon
    }
  }

  /// The symbols the picker offers.
  func iconChoices(for target: WorkspaceIconTarget) -> [(symbol: String, label: String)] {
    switch target {
    case .filterList: WorkspaceFilterList.iconOptions.map { ($0.symbol, $0.label) }
    case .folder: [("folder", "Folder")] + Self.availableListIcons
    case .list, .nestedList: Self.availableListIcons
    }
  }

  /// Sets an icon, a symbol's name or an emoji; nil puts the default back.
  func setIcon(_ name: String?, for target: WorkspaceIconTarget) {
    switch target {
    case .filterList(let filter):
      setIcon(name ?? WorkspaceFilterList.defaultIcon, for: filter)
      return
    case .list(let list): listIcons[list.id] = name
    case .nestedList(let task): listIcons[task.id] = name
    case .folder(let folder): listIcons[folder.id] = name
    }
    UserDefaults.standard.set(listIcons, forKey: "workspaceListIconsV1")
  }

  /// `⇧I` in the sidebar: the picker, on the row the cursor is on.
  func chooseIconForSidebarCursor() {
    if !isListsPaneVisible { showLeftDock(.lists) }
    guard let row = sidebarCursorRow else { return }
    switch row.kind {
    case .today, .everything: return
    case .list, .nestedList, .folder, .filterList: iconPickerRowID = row.id
    }
  }

  func closeIconPicker() {
    guard iconPickerRowID != nil else { return }
    iconPickerRowID = nil
    requestKeyboardFocus(.sidebar)
  }
}
