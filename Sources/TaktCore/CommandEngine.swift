import Foundation
import TaktRustCore

// MARK: - Date Parsing Config

/// User-customisable named-time shortcuts used by the natural language date parser.
public struct TaktDateParsingConfig: Equatable, Sendable {
  public var morningHour: Int = 9
  public var afternoonHour: Int = 14
  public var eveningHour: Int = 18
  public var eodHour: Int = 17

  // Spelled out rather than left to the memberwise initialiser, which is
  // internal and so unusable as a default argument now the app links this.
  public init(
    morningHour: Int = 9,
    afternoonHour: Int = 14,
    eveningHour: Int = 18,
    eodHour: Int = 17
  ) {
    self.morningHour = morningHour
    self.afternoonHour = afternoonHour
    self.eveningHour = eveningHour
    self.eodHour = eodHour
  }
}

public struct CommandPaletteSuggestion: Equatable, Sendable {
  public let label: String
  public let command: String
  public let preview: String
  public let keybind: String?
  public let submitImmediately: Bool
  /// If set, the live keybinding is read from preferences for this action and overrides `keybind`.
  public let boundActionRawValue: String?

  public init(
    label: String,
    command: String,
    preview: String,
    keybind: String?,
    submitImmediately: Bool,
    boundActionRawValue: String? = nil
  ) {
    self.label = label
    self.command = command
    self.preview = preview
    self.keybind = keybind
    self.submitImmediately = submitImmediately
    self.boundActionRawValue = boundActionRawValue
  }
}

public enum Command: Equatable, Sendable {
  case done
  case undone
  case invalidate
  case due(String)
  case clearDue
  case setStart(String)
  case clearStart
  case setRecurrence(String)
  case clearRecurrence
  case edit
  case search
  case openPreferences
  case openMainWindow
  case openDiagnostics
  case reloadCheckvistLists
  case uploadOfflineTasks
  case addSibling
  case addChild
  case openLink
  case undo
  case toggleTimer
  case pauseTimer
  case toggleHideFuture
  case delete
  case moveUp
  case moveDown
  case enterChildren
  case exitParent
  case expandTask
  case collapseTask
  case expandAll
  case collapseAll
  case tag(String)
  case untag(String)
  case list(String)
  case priority(Int)
  case priorityBack
  case clearPriority
  case syncObsidian
  case syncObsidianNewWindow
  case chooseObsidianInbox
  case clearObsidianInbox
  case linkObsidianFolder
  case createObsidianFolder
  case clearObsidianFolderLink
  case syncAFFiNE
  case openAFFiNEDocument
  case syncAFFiNEDay
  case syncGoogleCalendar
  case refreshMCPPath
  case copyMCPClientConfig
  case openMCPGuide
  case quickAdd
  case toggleContext
  case toggleChildrenInMenus
  case editAtStart
  case openCommandPalette
  case unknown(String)
}

public enum CommandEngine {
  /// A row's `keybind` is the key that performs *that row*, or nothing.
  ///
  /// Four due rows and five start rows used to print `dd` and `ds`, which are
  /// the sequences that *open* those lists rather than anything that picks one
  /// from them — so the palette showed one shortcut against nine different
  /// commands, which is worse than showing none: it reads as a collision.
  /// `CommandEngineSuggestionTests` pins it, and the pending-sequence hint is
  /// where "what does `d` offer" is answered now.
  public static let suggestions: [CommandPaletteSuggestion] = [
    .init(
      label: "Mark done", command: "done", preview: "Close selected task", keybind: "Space",
      submitImmediately: true),
    .init(
      label: "Mark undone", command: "undone", preview: "Undo last completion/action", keybind: "⌘Z",
      submitImmediately: true),
    .init(
      label: "Invalidate task", command: "invalidate", preview: "Invalidate selected task",
      keybind: "Shift+Space", submitImmediately: true),
    .init(
      label: "Due today", command: "due today", preview: "Set due date to today", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Due tomorrow", command: "due tomorrow", preview: "Set due date to tomorrow",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Due next week", command: "due next week", preview: "Set due date to next week",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Due today at time", command: "due today ",
      preview: "Set due date with time (for example 14:30 or 9am)", keybind: "dt",
      submitImmediately: false),
    .init(
      label: "Clear due date", command: "clear due", preview: "Remove due date", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Start today", command: "start today", preview: "Set start date to today",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Start tomorrow", command: "start tomorrow", preview: "Set start date to tomorrow",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Start next week", command: "start next week",
      preview: "Set start date to next week", keybind: nil, submitImmediately: true),
    .init(
      label: "Start at time", command: "start today ",
      preview: "Set start date with time (e.g. 9am, 14:30, next mon 9am)",
      keybind: nil, submitImmediately: false),
    .init(
      label: "Clear start date", command: "clear start", preview: "Remove start date",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Add tag", command: "tag ", preview: "Append #tag to task", keybind: "gt",
      submitImmediately: false),
    .init(
      label: "Remove tag", command: "untag ", preview: "Remove #tag from task", keybind: "gu",
      submitImmediately: false),
    .init(
      label: "Set priority", command: "priority ",
      preview: "Set priority rank within parent scope (any number)", keybind: "1-9",
      submitImmediately: false),
    .init(
      label: "Send to priority back", command: "priority back",
      preview: "Move selected task to end of priority list", keybind: "=",
      submitImmediately: true),
    .init(
      label: "Clear priority", command: "clear priority",
      preview: "Remove selected task from priority list", keybind: "-",
      submitImmediately: true),
    .init(
      label: "Repeat daily", command: "repeat daily",
      preview: "Schedule this task to recur every day", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Repeat weekdays", command: "repeat weekdays",
      preview: "Schedule this task to recur every weekday (Mon–Fri)", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Repeat weekly", command: "repeat weekly",
      preview: "Schedule this task to recur every week on the same day", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Repeat every N days/weeks", command: "repeat every ",
      preview: "e.g. repeat every 3 days, repeat every 2 weeks", keybind: nil,
      submitImmediately: false),
    .init(
      label: "Repeat every weekday", command: "repeat every monday",
      preview: "Recur on a specific weekday (e.g. every monday)", keybind: nil,
      submitImmediately: false),
    .init(
      label: "Clear repeat", command: "clear repeat",
      preview: "Remove recurring rule from task", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Reload Checkvist lists", command: "reload checkvist lists",
      preview: "Refresh available Checkvist workspaces", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Upload offline tasks", command: "upload offline tasks",
      preview: "Copy the offline workspace into the active or first loaded Checkvist list",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Open in Obsidian", command: "sync obsidian",
      preview: "Write selected task and notes, then open it in Obsidian", keybind: "o",
      submitImmediately: true),
    .init(
      label: "Open in Obsidian (New Window)", command: "open obsidian new window",
      preview: "Write selected task and open it in a new Obsidian window", keybind: "O",
      submitImmediately: true),
    .init(
      label: "Choose Obsidian inbox folder", command: "choose obsidian inbox",
      preview: "Pick the default Obsidian inbox used for task sync", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Clear Obsidian inbox folder", command: "clear obsidian inbox",
      preview: "Remove the default Obsidian inbox folder", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Link Obsidian folder", command: "link obsidian folder",
      preview: "Choose a folder for this task and its subtasks", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Create Obsidian folder", command: "create obsidian folder",
      preview: "Create and link a new folder for this task subtree", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Clear Obsidian folder link", command: "clear obsidian folder",
      preview: "Remove the linked folder for this task subtree", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Sync AFFiNE checklist", command: "sync affine",
      preview: "Close what you ticked in AFFiNE, then write back what's still open",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Open AFFiNE checklist", command: "open affine",
      preview: "Open this list's AFFiNE checklist in the browser", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Write today's log to AFFiNE", command: "affine daily",
      preview: "Write today's completions and dailies into today's AFFiNE document",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Create Google Calendar event", command: "sync google calendar",
      preview: "Create a Google Calendar event from the selected task", keybind: "gc",
      submitImmediately: true),
    .init(
      label: "Refresh MCP path", command: "refresh mcp path",
      preview: "Re-detect the built-in MCP server command path", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Copy MCP client config", command: "copy mcp config",
      preview: "Copy the MCP client configuration to the clipboard", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Open MCP guide", command: "open mcp guide",
      preview: "Open the local MCP setup guide", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Switch list", command: "list ", preview: "Find and switch list", keybind: "Shift+L",
      submitImmediately: false),
    .init(
      label: "Edit task", command: "edit", preview: "Edit selected task",
      keybind: "i / a / F2", submitImmediately: true),
    .init(
      label: "Focus search", command: "search", preview: "Search tasks", keybind: "/",
      submitImmediately: true),
    .init(
      label: "Open preferences", command: "preferences",
      preview: "Open Takt preferences",
      keybind: "Cmd+,", submitImmediately: true),
    .init(
      label: "Open main window", command: "window",
      preview: "Open the resizable window",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Diagnostics", command: "diagnostics",
      preview: "Connection, plugin health, recent problems",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Add sibling task", command: "add sibling", preview: "Create sibling below selection",
      keybind: "Enter", submitImmediately: true),
    .init(
      label: "Add child task", command: "add child", preview: "Create child under selection",
      keybind: "Shift+Enter / Tab", submitImmediately: true),
    .init(
      label: "Open first link", command: "open link", preview: "Open first URL in task text",
      keybind: "gg", submitImmediately: true),
    .init(
      label: "Undo last action", command: "undo", preview: "Undo add/complete/edit", keybind: "u",
      submitImmediately: true),
    .init(
      label: "Toggle timer", command: "toggle timer",
      preview: "Start/switch timer on selected task",
      keybind: "t", submitImmediately: true),
    .init(
      label: "Pause/resume timer", command: "pause timer", preview: "Pause or resume active timer",
      keybind: "p", submitImmediately: true),
    .init(
      label: "Toggle hide future", command: "toggle hide future",
      preview: "Show/hide future tasks", keybind: "Shift+H", submitImmediately: true),
    .init(
      label: "Delete selected task", command: "delete", preview: "Delete current task",
      keybind: "Del", submitImmediately: true),
    .init(
      label: "Move task up", command: "move up", preview: "Reorder current task upward",
      keybind: "Cmd+↑", submitImmediately: true),
    .init(
      label: "Move task down", command: "move down", preview: "Reorder current task downward",
      keybind: "Cmd+↓", submitImmediately: true),
    .init(
      label: "Zoom into subtasks (tree)", command: "enter children",
      preview: "Make the selected task the whole list", keybind: "Shift+→",
      submitImmediately: true, boundActionRawValue: "zoomIntoTask"),
    .init(
      label: "Zoom out to parent (tree)", command: "exit parent",
      preview: "Go up one level in list/tree views", keybind: "Shift+←",
      submitImmediately: true, boundActionRawValue: "zoomOutOfTask"),
    .init(
      label: "Expand selected task", command: "expand",
      preview: "Show subtasks indented underneath", keybind: "→", submitImmediately: true,
      boundActionRawValue: "enterChildren"),
    .init(
      label: "Collapse selected task", command: "collapse",
      preview: "Hide the subtasks shown underneath", keybind: "←", submitImmediately: true,
      boundActionRawValue: "exitToParent"),
    .init(
      label: "Expand all", command: "expand all",
      preview: "Open every task that has subtasks", keybind: nil, submitImmediately: true),
    .init(
      label: "Collapse all", command: "collapse all",
      preview: "Shut every expanded task", keybind: nil, submitImmediately: true),
    .init(
      label: "Quick add task", command: "quick add",
      preview: "Open the configured quick add prompt", keybind: nil, submitImmediately: true,
      boundActionRawValue: "quickAdd"),
    .init(
      label: "Edit task at start", command: "edit start",
      preview: "Open the editor with cursor at the beginning", keybind: nil,
      submitImmediately: true, boundActionRawValue: "editTaskAtStart"),
    .init(
      label: "Toggle breadcrumb context", command: "toggle context",
      preview: "Show or hide the breadcrumb path on tasks", keybind: nil,
      submitImmediately: true, boundActionRawValue: "sequenceToggleContext"),
    .init(
      label: "Toggle children in menus", command: "toggle children",
      preview: "Show siblings + descendants (default) or just siblings in non-All views",
      keybind: nil, submitImmediately: true),
  ]

  public static func filteredSuggestions(query: String, limit: Int? = nil) -> [CommandPaletteSuggestion]
  {
    let queryText = query.lowercased().trimmingCharacters(in: .whitespaces)
    let candidates = suggestions.filter { suggestion in
      queryText.isEmpty
        || suggestion.label.lowercased().contains(queryText)
        || suggestion.command.lowercased().contains(queryText)
        || suggestion.preview.lowercased().contains(queryText)
        || (suggestion.keybind?.lowercased().contains(queryText) ?? false)
    }
    guard let limit else { return candidates }
    return Array(candidates.prefix(limit))
  }

  /// What a typed palette command means: the Rust core's
  /// `palette_command_parse` (`core/src/command.rs`), case-insensitive, with
  /// anything it does not know as `.unknown` carrying the input as typed.
  public static func parse(_ input: String) -> Command {
    Command(paletteCommandParse(input: input))
  }

  /// A `due` or `start` command's words as the string the task stores:
  /// `yyyy-MM-dd` for a day, `yyyy-MM-dd HH:mm:ss Z` for a moment, in the
  /// calendar's zone, and the input unchanged for anything else (`asap`).
  /// The Rust core's `resolve_due_date` (`core/src/command.rs`) reads it.
  public static func resolveDueDate(
    _ input: String,
    now: Date = Date(),
    calendar: Calendar = .current,
    config: TaktDateParsingConfig = .init()
  ) -> String {
    let hours = NamedHours(
      morning: Int64(config.morningHour), afternoon: Int64(config.afternoonHour),
      evening: Int64(config.eveningHour), endOfDay: Int64(config.eodHour))
    return TaktRustCore.resolveDueDate(
      input: input, nowMs: now.rankingMilliseconds, zone: calendar.timeZone.identifier, hours: hours)
  }
}

extension Command {
  // swiftlint:disable:next cyclomatic_complexity
  init(_ core: PaletteCommand) {
    switch core {
    case .done: self = .done
    case .undone: self = .undone
    case .invalidate: self = .invalidate
    case .due(let raw): self = .due(raw)
    case .clearDue: self = .clearDue
    case .setStart(let raw): self = .setStart(raw)
    case .clearStart: self = .clearStart
    case .setRecurrence(let raw): self = .setRecurrence(raw)
    case .clearRecurrence: self = .clearRecurrence
    case .edit: self = .edit
    case .search: self = .search
    case .openPreferences: self = .openPreferences
    case .openMainWindow: self = .openMainWindow
    case .openDiagnostics: self = .openDiagnostics
    case .reloadCheckvistLists: self = .reloadCheckvistLists
    case .uploadOfflineTasks: self = .uploadOfflineTasks
    case .addSibling: self = .addSibling
    case .addChild: self = .addChild
    case .openLink: self = .openLink
    case .undo: self = .undo
    case .toggleTimer: self = .toggleTimer
    case .pauseTimer: self = .pauseTimer
    case .toggleHideFuture: self = .toggleHideFuture
    case .delete: self = .delete
    case .moveUp: self = .moveUp
    case .moveDown: self = .moveDown
    case .enterChildren: self = .enterChildren
    case .exitParent: self = .exitParent
    case .expandTask: self = .expandTask
    case .collapseTask: self = .collapseTask
    case .expandAll: self = .expandAll
    case .collapseAll: self = .collapseAll
    case .tag(let tag): self = .tag(tag)
    case .untag(let tag): self = .untag(tag)
    case .list(let query): self = .list(query)
    case .priority(let rank): self = .priority(Int(rank))
    case .priorityBack: self = .priorityBack
    case .clearPriority: self = .clearPriority
    case .syncObsidian: self = .syncObsidian
    case .syncObsidianNewWindow: self = .syncObsidianNewWindow
    case .chooseObsidianInbox: self = .chooseObsidianInbox
    case .clearObsidianInbox: self = .clearObsidianInbox
    case .linkObsidianFolder: self = .linkObsidianFolder
    case .createObsidianFolder: self = .createObsidianFolder
    case .clearObsidianFolderLink: self = .clearObsidianFolderLink
    case .syncAffine: self = .syncAFFiNE
    case .openAffineDocument: self = .openAFFiNEDocument
    case .syncAffineDay: self = .syncAFFiNEDay
    case .syncGoogleCalendar: self = .syncGoogleCalendar
    case .refreshMcpPath: self = .refreshMCPPath
    case .copyMcpClientConfig: self = .copyMCPClientConfig
    case .openMcpGuide: self = .openMCPGuide
    case .quickAdd: self = .quickAdd
    case .toggleContext: self = .toggleContext
    case .toggleChildrenInMenus: self = .toggleChildrenInMenus
    case .editAtStart: self = .editAtStart
    case .openCommandPalette: self = .openCommandPalette
    case .unknown(let input): self = .unknown(input)
    }
  }
}
