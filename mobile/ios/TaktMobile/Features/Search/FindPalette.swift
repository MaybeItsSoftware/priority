import Foundation
import TaktCore
import TaktWorkspace

/// A place Find can open: Everything, a filter list, or a list.
struct FindPlace: Identifiable, Hashable {
  let scope: ListScope
  let name: String
  let detail: String
  let colorHex: String?
  var id: ListScope { scope }

  var symbol: String {
    switch scope {
    case .everything: "tray.full"
    case .filter: "line.3.horizontal.decrease.circle"
    default: "list.bullet"
    }
  }

  /// Everything, the filter lists, then every live list with its folder as detail.
  static func all(in structure: WorkspaceStructure) -> [FindPlace] {
    let folders = Dictionary(structure.folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    var places = [FindPlace(scope: .everything, name: "Everything", detail: "All active lists", colorHex: nil)]
    places += structure.filterLists.map {
      FindPlace(scope: .filter($0.id), name: $0.name, detail: "Filter list", colorHex: $0.colorHex)
    }
    places += structure.listsInTreeOrder.filter { $0.completedAt == nil }.map { list in
      FindPlace(
        scope: .list(list.id), name: list.name, detail: list.folderId.flatMap { folders[$0] } ?? "",
        colorHex: list.colorHex)
    }
    return places
  }
}

/// What Find shows besides tasks: the phones' commands and the places to go,
/// ranked by the core (`core/src/palette.rs`), so the same row wins here and
/// on Android. Nothing typed: every command, recent ones first, and every place.
enum FindPalette {
  static let commandLimit = 5
  static let placeLimit = 6
  private static let recentsKey = "findRecentCommands"

  static var recents: [String] {
    UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
  }

  static func record(_ id: String) {
    UserDefaults.standard.set(PhonePalette.recording(id, recents: recents), forKey: recentsKey)
  }

  static func commands(_ query: String, recents: [String]) -> [PhonePalette.Command] {
    let ranked = PhonePalette.rankCommands(query, recents: recents)
    return query.isEmpty ? ranked : Array(ranked.prefix(commandLimit))
  }

  static func places(_ query: String, in all: [FindPlace]) -> [FindPlace] {
    guard !query.isEmpty else { return all }
    let order = PhonePalette.rank(query, all.map { PhonePalette.Candidate(title: $0.name, detail: $0.detail) })
    return order.prefix(placeLimit).map { all[$0] }
  }
}

/// What each of Find's commands does on the iPhone. The list is the core's
/// (`phone_palette_commands`), shared with Android; `handled` is held to it by
/// a test so a command the core adds cannot go quietly missing.
@MainActor
enum PhoneCommandRunner {
  static let handled: Set<String> = [
    "taskNew", "goToday", "goInbox", "goEverything", "goFocus", "goTimeline",
    "listNew", "folderNew", "windowUndo", "windowRedo",
    "phoneHabitNew", "phoneGoLists", "phoneHistory", "phoneSettings",
  ]

  static func run(_ id: String, model: WorkspaceModel, isPad: Bool) {
    let navigation = model.navigation
    switch id {
    case "taskNew":
      navigation.quickAddListID = navigation.currentScope?.listID
      navigation.quickAddParentTaskID = nil
      navigation.quickAddPlansToday = false
      navigation.isQuickAddPresented = true
    case "goToday": navigation.go(to: .today, isPad: isPad)
    case "goInbox":
      if let inbox = model.structure.inbox { navigation.open(.list(inbox.id), isPad: isPad) }
    case "goEverything": navigation.open(.everything, isPad: isPad)
    case "goFocus": navigation.go(to: .focus, isPad: isPad)
    case "goTimeline": navigation.go(to: .review, isPad: isPad)
    case "listNew": navigation.namePrompt = .newList(folderID: nil)
    case "folderNew": navigation.namePrompt = .newFolder(parentID: nil)
    case "windowUndo": model.undo()
    case "windowRedo": model.redo()
    case "phoneHabitNew": navigation.habitRequest = HabitRequest(taskID: nil)
    case "phoneGoLists": navigation.go(to: .lists, isPad: isPad)
    case "phoneHistory": navigation.isHistoryPresented = true
    case "phoneSettings": navigation.isSettingsPresented = true
    default: break
    }
  }
}
