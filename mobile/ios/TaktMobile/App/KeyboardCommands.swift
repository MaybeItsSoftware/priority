import TaktCore
import TaktWorkspace
import SwiftUI

/// Hardware-keyboard shortcuts, read from the Mac's command catalogue.
///
/// Each command's keys come from `WorkspaceCommandCatalog`, so ⌘1 here is ⌘1
/// there because both read the same entry. Only single chords translate — the
/// Mac's two-letter sequences (`dd`, `mm`) have no meaning on a key-command
/// responder chain — and of those, only the ones a touch layout can act on.
/// Holding ⌘ on an iPad lists them, grouped as the catalogue groups them.
struct KeyboardCommands: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad

  /// The commands offered, in the order the ⌘ overlay lists them.
  static let commandIDs: [WorkspaceCommandID] = [
    .goToday, .goBoard, .goOutline, .goMatrix, .goEverything, .goFocus, .goTimeline, .goSearch, .goCommandPalette,
    .taskNew, .taskNewAbove, .taskNewChild, .taskComplete, .taskInvalidate, .taskDelete,
    .taskDueToday, .taskDueTomorrow, .taskToggleDaily, .taskTogglePlannedToday, .taskMove,
    .taskIndent, .taskOutdent, .taskMoveUp, .taskMoveDown, .taskMoveToPreviousList, .taskMoveToNextList,
    .taskConvertToList, .taskPromoteList, .taskToggleInspector, .taskOpenLink,
    .planEnterTask, .planLeaveTask, .planFoldAll, .planUnfoldAll,
    .listNew, .folderNew, .listComplete, .listRestore, .windowUndo, .windowRedo,
  ]

  var body: some View {
    ZStack {
      ForEach(Self.bindings, id: \.self) { binding in
        Button(binding.title) { run(binding.id) }
          .keyboardShortcut(binding.key, modifiers: binding.modifiers)
      }
      // Walking the rows is not in the catalogue as a command — on the Mac it
      // is the list's own behaviour — so it is spelled out here.
      Button("Select next task") { model.navigation.outlineCommand = .selectNext }
        .keyboardShortcut(.downArrow, modifiers: [])
      Button("Select previous task") { model.navigation.outlineCommand = .selectPrevious }
        .keyboardShortcut(.upArrow, modifiers: [])
      // The Mac reaches these by two-letter sequences (`tc`, `za`, `pc`),
      // which a key-command chain cannot express; they get chords here.
      Button(WorkspaceCommandCatalog[.planHideCompleted].title) { model.navigation.outlineCommand = .toggleHideCompleted }
        .keyboardShortcut("h", modifiers: [.command, .option])
      Button(WorkspaceCommandCatalog[.planToggleFold].title) { model.navigation.outlineCommand = .toggleFold }
        .keyboardShortcut("f", modifiers: [.command, .option])
      Button(WorkspaceCommandCatalog[.taskShowProgress].title) {
        if let selected = model.navigation.selectedTaskID { model.showProgress(selected) }
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      Button(WorkspaceCommandCatalog[.taskExtractBranch].title) {
        if let selected = model.navigation.selectedTaskID { model.extractBranch(selected) }
      }
      .keyboardShortcut("e", modifiers: [.command, .option])
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
  }

  struct ShortcutBinding: Hashable {
    let id: WorkspaceCommandID
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers

    static func == (lhs: ShortcutBinding, rhs: ShortcutBinding) -> Bool {
      lhs.id == rhs.id && lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(id)
      hasher.combine(String(key.character))
      hasher.combine(modifiers.rawValue)
    }
  }

  /// Every translatable chord of every offered command, first come first
  /// served, so two commands never claim one chord.
  static let bindings: [ShortcutBinding] = {
    var seen = Set<String>()
    var result: [ShortcutBinding] = []
    for id in commandIDs {
      let command = WorkspaceCommandCatalog[id]
      for key in command.keys {
        guard let (equivalent, modifiers) = parse(key), seen.insert(key).inserted else { continue }
        result.append(ShortcutBinding(id: id, title: command.title, key: equivalent, modifiers: modifiers))
      }
    }
    return result
  }()

  /// `cmd+shift+z` → (`z`, [.command, .shift]): the core's chord, mapped to
  /// SwiftUI's key type. Nil for a sequence (`dd`), a key this platform has
  /// no equivalent for, or one a text field owns (a bare letter, return, tab,
  /// delete).
  static func parse(_ key: String) -> (KeyEquivalent, EventModifiers)? {
    guard let chord = WorkspaceKeyChord(key), !chord.belongsToTyping else { return nil }
    var modifiers: EventModifiers = []
    if chord.cmd { modifiers.insert(.command) }
    if chord.ctrl { modifiers.insert(.control) }
    if chord.option { modifiers.insert(.option) }
    if chord.shift { modifiers.insert(.shift) }
    let equivalent: KeyEquivalent
    switch chord.key {
    case "up": equivalent = .upArrow
    case "down": equivalent = .downArrow
    case "left": equivalent = .leftArrow
    case "right": equivalent = .rightArrow
    case "space": equivalent = .space
    case "enter": equivalent = .return
    case "delete": equivalent = .delete
    case "tab": equivalent = .tab
    default:
      guard chord.key.count == 1, let character = chord.key.first else { return nil }
      equivalent = KeyEquivalent(character)
    }
    return (equivalent, modifiers)
  }

  // MARK: - Dispatch

  private func run(_ id: WorkspaceCommandID) {
    let navigation = model.navigation
    let selected = navigation.selectedTaskID
    switch id {
    case .goToday: navigation.go(to: .today, isPad: isPad)
    case .goBoard: showList(.board)
    case .goOutline: showList(.outline)
    case .goMatrix: showList(.matrix)
    case .goEverything: navigation.open(.everything, isPad: isPad)
    case .goFocus: navigation.go(to: .focus, isPad: isPad)
    case .goTimeline: navigation.go(to: .review, isPad: isPad)
    case .goSearch, .goCommandPalette:
      navigation.go(to: .search, isPad: isPad)
      navigation.searchFocusRequest &+= 1
    case .taskNew:
      if navigation.currentScope?.isSingleTree == true, navigation.viewMode == .outline, isOnList {
        navigation.outlineCommand = .add
      } else {
        navigation.quickAddListID = navigation.currentScope?.listID
        navigation.quickAddParentTaskID = nil
        navigation.isQuickAddPresented = true
      }
    case .taskNewAbove: navigation.outlineCommand = .addAbove
    case .taskNewChild: navigation.outlineCommand = .addChild
    case .planEnterTask: navigation.outlineCommand = .expand
    case .planLeaveTask: navigation.outlineCommand = .collapse
    case .planFoldAll: navigation.outlineCommand = .foldAll
    case .planUnfoldAll: navigation.outlineCommand = .unfoldAll
    case .listNew: navigation.namePrompt = .newList(folderID: nil)
    case .listRestore: model.restoreLastArchivedList()
    case .listComplete:
      if let listID = navigation.currentScope?.listID { model.toggleCompleted(list: listID) }
    case .folderNew: navigation.namePrompt = .newFolder(parentID: nil)
    case .windowUndo: model.undo()
    case .windowRedo: model.redo()
    default:
      guard let selected else { return }
      runTaskCommand(id, on: selected)
    }
  }

  private var isOnList: Bool {
    isPad ? navigationIsScoped : model.navigation.tab == .lists && !model.navigation.listPath.isEmpty
  }

  private var navigationIsScoped: Bool {
    if case .scope = model.navigation.sidebarSelection { return true }
    return false
  }

  private func showList(_ mode: ListViewMode) {
    model.navigation.viewMode = mode
    if model.navigation.currentScope == nil || !isOnList {
      model.navigation.open(model.navigation.currentScope ?? .everything, isPad: isPad)
    }
  }

  private func runTaskCommand(_ id: WorkspaceCommandID, on taskID: String) {
    switch id {
    case .taskComplete: model.toggleComplete(taskID)
    case .taskInvalidate: model.toggleInvalidated(taskID)
    case .taskDelete: model.delete(taskID)
    case .taskDueToday: model.setDue(taskID, daysFromToday: 0)
    case .taskDueTomorrow: model.setDue(taskID, daysFromToday: 1)
    case .taskToggleDaily: model.toggleDaily(taskID)
    case .taskTogglePlannedToday: model.togglePlannedToday(taskID)
    case .taskMove: model.navigation.movingTaskID = taskID
    case .taskIndent: model.indent(taskID)
    case .taskOutdent: model.outdent(taskID)
    case .taskMoveUp: model.move(taskID, by: -1)
    case .taskMoveDown: model.move(taskID, by: 1)
    case .taskMoveToPreviousList: model.moveToAdjacentList(taskID, by: -1)
    case .taskMoveToNextList: model.moveToAdjacentList(taskID, by: 1)
    case .taskToggleInspector: model.navigation.inspect(taskID, isPad: isPad)
    case .taskOpenLink: model.openFirstLink(taskID)
    case .taskConvertToList: model.toggleListKind(taskID)
    case .taskPromoteList: model.togglePromoted(taskID)
    default: break
    }
  }
}
