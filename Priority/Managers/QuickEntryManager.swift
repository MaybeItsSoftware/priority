import Foundation
import Observation
import PriorityCore

@MainActor
@Observable class QuickEntryManager {
  var searchText: String = "" {
    didSet { cacheInvalidationBus.invalidate() }
  }
  var quickEntryText: String = ""
  var quickEntryMode: QuickEntryMode = .search {
    didSet { cacheInvalidationBus.invalidate() }
  }
  var isQuickEntryFocused: Bool = false
  var editCursorAtEnd: Bool = true  // true = append (a), false = insert (i)
  var pendingDeleteConfirmation: Bool = false
  // `completingTaskId` used to live here, which made the celebration's state
  // span two managers — this one for tasks, `CompletionCelebrationManager` for
  // dailies — and every surface had to know which. It is now owned entirely by
  // the latter, as `completingKind` + `phase`, read through `phase(for:)`.
  var commandSuggestionIndex: Int = 0
  var keyBuffer: String = ""
  /// The date highlighted by the `dd` calendar. It lives beside the other
  /// quick-entry state so the popover and main window share one selection and
  /// the global key router can move it without reaching into a SwiftUI view.
  var dueDatePickerSelection: Date = Date()
  /// The calendar belongs to the row that opened it. Keeping the id prevents a
  /// mouse click on a visible row behind the picker from silently retargeting
  /// the eventual confirmation.
  var dueDatePickerTaskId: Int?

  @ObservationIgnored private let cacheInvalidationBus: CacheInvalidationBus
  @ObservationIgnored var integrationFlagsProvider:
    (() -> (obsidian: Bool, affine: Bool, googleCalendar: Bool, mcp: Bool))?
  @ObservationIgnored var shortcutBindingProvider: ((ConfigurableShortcutAction) -> String)?

  init(cacheInvalidationBus: CacheInvalidationBus = CacheInvalidationBus()) {
    self.cacheInvalidationBus = cacheInvalidationBus
  }

  // MARK: - Due-date calendar

  func beginDueDatePicker(forTaskId taskId: Int, initialDate: Date?, now: Date = Date()) {
    dueDatePickerTaskId = taskId
    dueDatePickerSelection = initialDate ?? now
    quickEntryText = ""
    commandSuggestionIndex = 0
    quickEntryMode = .dueDatePicker
    // The calendar itself owns the keys. Leaving the hidden command field
    // focused would make arrow presses edit text instead of moving by date.
    isQuickEntryFocused = false
  }

  func dismissDueDatePicker() {
    dueDatePickerTaskId = nil
    quickEntryMode = .search
    quickEntryText = ""
    commandSuggestionIndex = 0
    isQuickEntryFocused = false
  }

  func moveDueDatePickerSelection(byDays days: Int, calendar: Calendar = .current) {
    guard let moved = calendar.date(byAdding: .day, value: days, to: dueDatePickerSelection)
    else { return }
    dueDatePickerSelection = moved
  }

  func moveDueDatePickerSelection(byMonths months: Int, calendar: Calendar = .current) {
    let source = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: dueDatePickerSelection)
    guard
      let year = source.year,
      let month = source.month,
      let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
      let targetMonth = calendar.date(byAdding: .month, value: months, to: monthStart),
      let dayRange = calendar.range(of: .day, in: .month, for: targetMonth)
    else { return }

    var target = calendar.dateComponents([.year, .month], from: targetMonth)
    target.day = min(source.day ?? 1, dayRange.count)
    target.hour = source.hour
    target.minute = source.minute
    target.second = source.second
    guard let moved = calendar.date(from: target) else { return }
    dueDatePickerSelection = moved
  }

  func dueDatePickerDueString(calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents(
      [.year, .month, .day], from: dueDatePickerSelection)
    guard let year = components.year, let month = components.month, let day = components.day
    else { return "" }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  static let commandSuggestions: [CommandSuggestion] =
    CommandEngine.suggestions.map {
      .init(
        label: $0.label,
        command: $0.command,
        preview: $0.preview,
        keybind: $0.keybind,
        submitImmediately: $0.submitImmediately
      )
    }

  // MARK: - Command Palette

  func filteredCommandSuggestions(
    query: String,
    obsidianEnabled: Bool,
    affineEnabled: Bool,
    googleCalendarEnabled: Bool,
    mcpEnabled: Bool
  ) -> [CommandSuggestion] {
    let filtered = CommandEngine.filteredSuggestions(query: query).filter { suggestion in
      switch suggestion.command {
      case "sync obsidian", "open obsidian new window", "choose obsidian inbox",
        "clear obsidian inbox", "link obsidian folder", "create obsidian folder",
        "clear obsidian folder":
        return obsidianEnabled
      case "sync affine", "open affine", "affine daily":
        return affineEnabled
      case "sync google calendar":
        return googleCalendarEnabled
      case "refresh mcp path", "copy mcp config", "open mcp guide":
        return mcpEnabled
      default:
        return true
      }
    }

    return filtered.map { suggestion in
      let keybind = resolvedKeybindLabel(for: suggestion)
      return CommandSuggestion(
        label: suggestion.label,
        command: suggestion.command,
        preview: suggestion.preview,
        keybind: keybind,
        submitImmediately: suggestion.submitImmediately
      )
    }
  }

  private func resolvedKeybindLabel(for suggestion: CommandPaletteSuggestion) -> String? {
    guard
      let raw = suggestion.boundActionRawValue,
      let action = ConfigurableShortcutAction(rawValue: raw),
      let provider = shortcutBindingProvider
    else { return suggestion.keybind }
    let binding = provider(action).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !binding.isEmpty else { return suggestion.keybind }
    return Self.formatBinding(binding)
  }

  /// Formats a comma-separated raw binding string (e.g. "cmd+k,;,shift+;") into a
  /// compact display like "⌘K · ;" suitable for the palette row.
  static func formatBinding(_ raw: String) -> String {
    raw.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map(prettifyToken)
      .joined(separator: " · ")
  }

  private static func prettifyToken(_ token: String) -> String {
    let parts = token.lowercased().split(separator: "+")
    var modifiers = ""
    var key = ""
    for part in parts {
      switch part {
      case "cmd": modifiers += "⌘"
      case "shift": modifiers += "⇧"
      case "ctrl": modifiers += "⌃"
      case "option", "opt", "alt": modifiers += "⌥"
      default: key = String(part)
      }
    }
    let prettyKey: String
    switch key {
    case "left": prettyKey = "←"
    case "right": prettyKey = "→"
    case "up": prettyKey = "↑"
    case "down": prettyKey = "↓"
    case "enter", "return": prettyKey = "⏎"
    case "tab": prettyKey = "⇥"
    case "escape", "esc": prettyKey = "⎋"
    case "space": prettyKey = "␣"
    case "delete", "del": prettyKey = "⌫"
    default: prettyKey = key.count == 1 ? key.uppercased() : key.capitalized
    }
    return modifiers + prettyKey
  }

  func selectNextCommandSuggestion(
    for query: String,
    obsidianEnabled: Bool,
    affineEnabled: Bool,
    googleCalendarEnabled: Bool,
    mcpEnabled: Bool
  ) {
    let total = filteredCommandSuggestions(
      query: query,
      obsidianEnabled: obsidianEnabled,
      affineEnabled: affineEnabled,
      googleCalendarEnabled: googleCalendarEnabled,
      mcpEnabled: mcpEnabled
    ).count
    guard total > 0 else { return }
    commandSuggestionIndex = min(commandSuggestionIndex + 1, total - 1)
  }

  func selectPreviousCommandSuggestion(
    for query: String,
    obsidianEnabled: Bool,
    affineEnabled: Bool,
    googleCalendarEnabled: Bool,
    mcpEnabled: Bool
  ) {
    let total = filteredCommandSuggestions(
      query: query,
      obsidianEnabled: obsidianEnabled,
      affineEnabled: affineEnabled,
      googleCalendarEnabled: googleCalendarEnabled,
      mcpEnabled: mcpEnabled
    ).count
    guard total > 0 else { return }
    commandSuggestionIndex = max(commandSuggestionIndex - 1, 0)
  }

  // MARK: - Command palette (no-argument overloads using integrationFlagsProvider)

  private func currentIntegrationFlags()
    -> (obsidian: Bool, affine: Bool, googleCalendar: Bool, mcp: Bool)
  {
    integrationFlagsProvider?() ?? (obsidian: false, affine: false, googleCalendar: false, mcp: false)
  }

  func filteredCommandSuggestions(query: String) -> [CommandSuggestion] {
    let flags = currentIntegrationFlags()
    return filteredCommandSuggestions(
      query: query,
      obsidianEnabled: flags.obsidian,
      affineEnabled: flags.affine,
      googleCalendarEnabled: flags.googleCalendar,
      mcpEnabled: flags.mcp
    )
  }

  func selectNextCommandSuggestion(for query: String) {
    let flags = currentIntegrationFlags()
    selectNextCommandSuggestion(
      for: query,
      obsidianEnabled: flags.obsidian,
      affineEnabled: flags.affine,
      googleCalendarEnabled: flags.googleCalendar,
      mcpEnabled: flags.mcp
    )
  }

  func selectPreviousCommandSuggestion(for query: String) {
    let flags = currentIntegrationFlags()
    selectPreviousCommandSuggestion(
      for: query,
      obsidianEnabled: flags.obsidian,
      affineEnabled: flags.affine,
      googleCalendarEnabled: flags.googleCalendar,
      mcpEnabled: flags.mcp
    )
  }

  // MARK: - Search state

  var isSearchFilterActive: Bool { !searchText.isEmpty && quickEntryMode == .search }
}
