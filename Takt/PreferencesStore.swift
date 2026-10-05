import Foundation
import TaktCore

final class PreferencesStore {
  enum Key: String {
    case checkvistUsername
    case checkvistListId
    case confirmBeforeDelete
    case showTaskBreadcrumbContext
    case rootTaskView
    case selectedRootDueBucketRawValue
    case selectedRootTag
    case launchAtLogin
    case globalHotkeyEnabled
    case globalHotkeyKeyCode
    case globalHotkeyModifiers
    case timerByTaskId
    case onboardingCompleted
    case pluginSelectionOnboardingCompleted
    case ignoreKeychainInDebug
    case checkvistIntegrationEnabled
    case obsidianIntegrationEnabled
    case affineIntegrationEnabled
    case googleCalendarIntegrationEnabled
    case googleCalendarEventLinksByTaskKey
    case googleTasksIntegrationEnabled
    case mcpIntegrationEnabled
    case focusPanelHotkeyEnabled
    case focusPanelHotkeyKeyCode
    case focusPanelHotkeyModifiers
    case quickAddHotkeyEnabled
    case quickAddHotkeyKeyCode
    case quickAddHotkeyModifiers
    case quickAddHyperNMigrationCompleted
    /// The workspace list the quick-add hotkey captures into; empty is the inbox.
    case quickCaptureListID
    case appThemeRawValue
    /// `pluginIdentifier` of the chosen `ThemePlugin` — the palette and
    /// structure the app renders through. Distinct from `appThemeRawValue`,
    /// which is the light/dark/system question a theme does not get to answer
    /// on the user's behalf.
    case activeThemePluginIdentifier
    /// "Use a different theme on this Mac": when true, the theme and
    /// appearance are this Mac's own, and the synced `theme.selected` and
    /// `theme.appearance` preferences are neither read nor written.
    case usesDeviceThemeChoice
    /// Identifier → SHA-256 of the text last mirrored between a theme file and
    /// its `themes` row, so `UserThemeLibrary` can tell which side changed.
    case mirroredUserThemeDigests
    /// JSON of the reader's `ThemeTypographyOverride` — interface, heading and
    /// numeral families and a text size — laid over whichever theme is active.
    /// This Mac's own, like the window it is read in: not synced.
    case themeTypographyOverride
    case dismissedOnboardingDialogs
    case kanbanColumns
    case taskStartDatesByTaskId
    case recurrenceRulesByTaskId
    case rootTaskViewOrder
    /// Whether the window comes up on the focus screen rather than the lists.
    /// Whether finishing a block stops to ask how it went.
    case scoresEachFocusBlock
    /// Where a deliberately started block runs: the floating panel or the menu bar.
    case focusRunSurfaceRawValue
    case focusDurationMinutes
    case focusBreakDurationMinutes
    case kanbanManualOrderByColumnId
    /// Whether the board groups into a row per top-level goal.
    case kanbanSwimlanesByGoal
    case dailyLogIntegrationEnabled
    case dailyLogChartRangeRawValue
    case dailyChartVisible
    /// Whether the Daily view shows the "done today" list of completed tasks.
    /// Off by default — the Daily view is about dailies, and the task list is
    /// reachable from the dock when you do want it.
    case dailyCompletionsVisible
    /// Whether the Matrix view opens its list of unplaced tasks below the plot.
    /// Off by default: the panel is 400pt wide and the list used to take 190 of
    /// them permanently, which left the grid — the thing the view is for — as
    /// the narrower half of its own screen.
    case matrixUnplacedVisible
    /// `pluginIdentifier` of the chosen completion celebration preset. Empty or
    /// unrecognised falls back to whatever `PluginRegistry.nativeFirst()`
    /// activated.
    case completionCelebrationIdentifier
    /// Whether the active celebration preset's tick is audible. Off unless the
    /// user asks: see `CelebrationSound`, which exists because the haptic
    /// reaches only Force Touch trackpads.
    case completionSoundEnabled
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func string(_ key: Key, default defaultValue: String = "") -> String {
    defaults.string(forKey: key.rawValue) ?? defaultValue
  }

  func set(_ value: String, for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func bool(_ key: Key, default defaultValue: Bool) -> Bool {
    defaults.object(forKey: key.rawValue) as? Bool ?? defaultValue
  }

  func optionalBool(_ key: Key) -> Bool? {
    defaults.object(forKey: key.rawValue) as? Bool
  }

  func set(_ value: Bool, for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func int(_ key: Key, default defaultValue: Int) -> Int {
    defaults.object(forKey: key.rawValue) as? Int ?? defaultValue
  }

  func set(_ value: Int, for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func double(_ key: Key, default defaultValue: Double) -> Double {
    defaults.object(forKey: key.rawValue) as? Double ?? defaultValue
  }

  func set(_ value: Double, for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func stringArray(_ key: Key) -> [String] {
    defaults.stringArray(forKey: key.rawValue) ?? []
  }

  func set(_ value: [String], for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func stringDictionary(_ key: Key) -> [String: String] {
    defaults.dictionary(forKey: key.rawValue) as? [String: String] ?? [:]
  }

  func set(_ value: [String: String], for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func doubleDictionary(_ key: Key) -> [String: Double] {
    defaults.dictionary(forKey: key.rawValue) as? [String: Double] ?? [:]
  }

  func timerDictionary() -> [String: Double] {
    defaults.dictionary(forKey: Key.timerByTaskId.rawValue) as? [String: Double] ?? [:]
  }

  func set(_ value: [String: Double], for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func remove(_ key: Key) {
    defaults.removeObject(forKey: key.rawValue)
  }
}
