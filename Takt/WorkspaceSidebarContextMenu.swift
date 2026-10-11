import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// The sidebar's right-click menu, Zed's project panel's: making things at
/// the top, then what acts on the row, then the folders, with each item's key
/// on its right.
///
/// One menu for every kind of row, so a list, a folder, a nested list and a
/// filter list offer the same things in the same places, and only what does
/// not apply is missing. The keys are the sidebar's as bound — `%` and `d`,
/// not the chords that also reach those commands from anywhere — read from the
/// catalogue, so a rebound key is the one shown. They act only while the menu
/// is open: a context menu's key equivalents are not the main menu's, and a
/// bare `d` here cannot fire while you are typing elsewhere.
struct WorkspaceSidebarContextMenu: View {
  @Environment(WorkspaceViewModel.self) private var model
  let target: WorkspaceIconTarget
  /// The row's outline id, which the icon picker opens on.
  let rowID: String

  var body: some View {
    Button("New List") { model.beginSidebarDraft(.list, in: creationFolderID) }
      .sidebarMenuKey(.listNew)
    Button("New Folder") { model.beginSidebarDraft(.folder, in: creationFolderID) }
      .sidebarMenuKey(.folderNew)
    Divider()
    renameItem
    Button("Icon…") { model.iconPickerRowID = rowID }
      .sidebarMenuKey(.listIcon)
    settingsItem
    Button("Move Up") { move(by: -1) }
      .sidebarMenuKey(.listMoveUp)
      .disabled(!canMove(by: -1))
    Button("Move Down") { move(by: 1) }
      .sidebarMenuKey(.listMoveDown)
      .disabled(!canMove(by: 1))
    Divider()
    rowActions
    archiveItem
    deleteItem
    Divider()
    Button("Expand All") { model.setAllFoldersExpanded(true) }
      .sidebarMenuKey(.folderExpandAll)
    Button("Collapse All") { model.setAllFoldersExpanded(false) }
      .sidebarMenuKey(.folderCollapseAll)
  }

  /// Where New List and New Folder put what they make: into a folder, as
  /// Zed's New File on a directory does, and beside anything else.
  private var creationFolderID: String? {
    switch target {
    case .folder(let folder): folder.id
    case .list(let list): list.isSystemList ? nil : list.folderId
    case .nestedList(let task): model.lists.first { $0.id == task.listId }?.folderId
    case .filterList: nil
    }
  }

  @ViewBuilder private var renameItem: some View {
    switch target {
    case .list(let list):
      Button("Rename") { model.beginRenaming(.list(list)) }.sidebarMenuKey(.listRename)
    case .folder(let folder):
      Button("Rename") { model.beginRenaming(.folder(folder)) }.sidebarMenuKey(.listRename)
    case .nestedList(let task):
      Button("Rename…") {
        model.presentOverlay(.quickEdit(WorkspaceTaskQuickEditRequest(task: task, kind: .title)))
      }
      .sidebarMenuKey(.listRename)
    case .filterList(let filter):
      Button("Rename…") { model.requestEditFilterList(filter) }
    }
  }

  @ViewBuilder private var settingsItem: some View {
    switch target {
    case .list(let list):
      Button("List Settings…") { model.showSettings(for: list) }.sidebarMenuKey(.listSettings)
    case .folder(let folder):
      Button("Folder Settings…") { model.showSettings(for: folder) }.sidebarMenuKey(.listSettings)
    case .filterList(let filter):
      Button("Edit Filter List…") { model.requestEditFilterList(filter) }.sidebarMenuKey(.filterListEdit)
    case .nestedList:
      EmptyView()
    }
  }

  /// What only this kind of row has — kept from the menus the rows had before
  /// this one.
  @ViewBuilder private var rowActions: some View {
    switch target {
    case .list(let list):
      Button("New Nested List…") {
        model.selectList(list.id)
        model.requestNestedListCreation()
      }
      if !list.isSystemList {
        Button("Convert to Task in Inbox") { model.convertListToTask(list) }
        Button(list.completedAt == nil ? "Complete List" : "Reopen List") { model.toggleListCompletion(list) }
      }
    case .nestedList(let task):
      Button("Open List") { model.openItemList(task) }
      Button("Convert to Task") { model.convertItem(task) }
      Button("Move to List or Folder…") { model.requestMove(task) }
      Button("New Nested List…") { model.requestNestedListCreation(under: task) }
      Button("Move to Top Level") { model.moveDroppedItem(task.id, toFolderID: nil) }
      Button(task.isPromoted == true ? "Unpin from Sidebar" : "Pin to Sidebar") { model.toggleListPromotion(task) }
      Button(task.status == .open ? "Complete List" : "Reopen List") { model.toggleTask(task) }
    case .filterList:
      Button("New Filter List…") { model.requestNewFilterList() }
    case .folder:
      EmptyView()
    }
  }

  @ViewBuilder private var archiveItem: some View {
    switch target {
    case .list(let list) where !list.isSystemList:
      Button("Archive") { model.archiveList(list) }.sidebarMenuKey(.listArchive)
    case .nestedList(let task):
      Button("Archive") { model.archiveNestedList(task) }.sidebarMenuKey(.listArchive)
    default:
      EmptyView()
    }
  }

  /// Everything but the inbox, which quick capture has to have somewhere to
  /// land.
  @ViewBuilder private var deleteItem: some View {
    switch target {
    case .list(let list) where !list.isSystemList:
      Button("Delete", role: .destructive) { model.requestDeletion(of: .list(list)) }.sidebarMenuKey(.listDelete)
    case .folder(let folder):
      Button("Delete", role: .destructive) { model.requestDeletion(of: .folder(folder)) }.sidebarMenuKey(.listDelete)
    case .nestedList(let task):
      Button("Delete", role: .destructive) { model.requestTaskDeletion(task) }.sidebarMenuKey(.listDelete)
    case .filterList(let filter):
      Button("Delete", role: .destructive) { model.deleteFilterList(filter) }.sidebarMenuKey(.listDelete)
    default:
      EmptyView()
    }
  }

  private func canMove(by offset: Int) -> Bool {
    switch target {
    case .filterList(let filter):
      guard let index = model.filterLists.firstIndex(of: filter) else { return false }
      return model.filterLists.indices.contains(index + offset)
    case .list(let list):
      return !list.isSystemList
    case .folder, .nestedList:
      return true
    }
  }

  private func move(by offset: Int) {
    switch target {
    case .list(let list): model.moveListWithinFolder(list, by: offset)
    case .folder(let folder): model.moveFolderWithinSiblings(folder, by: offset)
    case .nestedList(let task): model.moveTaskWithinSiblings(task, by: offset)
    case .filterList(let filter):
      if let index = model.filterLists.firstIndex(of: filter) { model.moveFilterList(filter, to: index + offset) }
    }
  }
}

extension View {
  /// The key a sidebar context menu item shows: the command's sidebar key as
  /// bound, by `WorkspaceCommand.contextMenuKeyEquivalent(on:)`.
  @ViewBuilder
  func sidebarMenuKey(_ id: WorkspaceCommandID) -> some View {
    if let shortcut = WorkspaceCommandHelpText.sidebarMenuShortcut(for: id) {
      keyboardShortcut(shortcut)
    } else {
      self
    }
  }
}

extension WorkspaceCommandHelpText {
  @MainActor
  static func sidebarMenuShortcut(for id: WorkspaceCommandID) -> KeyboardShortcut? {
    _ = WorkspaceKeymapStore.shared.revision
    guard let equivalent = WorkspaceCommandCatalog.byID[id]?.contextMenuKeyEquivalent(on: .sidebar),
      let key = keyEquivalent(equivalent.key)
    else { return nil }
    var modifiers: EventModifiers = []
    for modifier in equivalent.modifiers {
      switch modifier {
      case "cmd": modifiers.insert(.command)
      case "shift": modifiers.insert(.shift)
      case "option": modifiers.insert(.option)
      case "ctrl": modifiers.insert(.control)
      default: return nil
      }
    }
    return KeyboardShortcut(key, modifiers: modifiers)
  }

  private static func keyEquivalent(_ key: String) -> KeyEquivalent? {
    if key.count == 1, let character = key.first { return KeyEquivalent(character) }
    if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...12).contains(number),
      let scalar = Unicode.Scalar(NSF1FunctionKey + number - 1) {
      return KeyEquivalent(Character(scalar))
    }
    let named: [String: KeyEquivalent] = [
      "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
      "delete": .delete, "enter": .return, "tab": .tab, "space": .space, "escape": .escape,
      "comma": ",", "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
    ]
    return named[key]
  }
}
