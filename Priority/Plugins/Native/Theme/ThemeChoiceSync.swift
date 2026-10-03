import Foundation
import Observation
import PriorityCore
import PriorityWorkspace
import os

/// Keeps the Mac's theme and appearance in step with the synced
/// `theme.selected` and `theme.appearance` preferences, so a choice made on
/// one device follows to the others (`docs/themes.md`, "The chosen theme
/// follows you").
///
/// The Mac keeps its own copy of both, where it always has: `ThemeManager`'s
/// stored pick and `PreferencesManager.appTheme`. While the Mac follows the
/// synced choice, those are updated from it and every change to them is written
/// back. "Use a different theme on this Mac" (`usesDeviceChoice`, local and not
/// synced) stops both directions, and the Mac keeps whatever it shows at that
/// point as its own choice.
///
/// It does not loop. The store skips writes that would change nothing, and
/// applying a synced value that is already in force changes nothing.
@MainActor
@Observable
final class ThemeChoiceSync {
  @ObservationIgnored private let theme: ThemeManager
  @ObservationIgnored private let preferences: PreferencesManager
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let store: WorkspaceStore
  @ObservationIgnored private var applying = false
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.priority", category: "ThemeChoiceSync")

  /// "Use a different theme on this Mac".
  var usesDeviceChoice: Bool {
    didSet {
      guard usesDeviceChoice != oldValue else { return }
      preferencesStore.set(usesDeviceChoice, for: .usesDeviceThemeChoice)
      // Back to following: what the other devices chose wins, or, if nothing
      // has been chosen yet, this Mac's choice becomes everyone's.
      if !usesDeviceChoice { seedIfUnset(); applySynced() }
    }
  }

  init(
    theme: ThemeManager, preferences: PreferencesManager, preferencesStore: PreferencesStore,
    store: WorkspaceStore
  ) {
    self.theme = theme
    self.preferences = preferences
    self.preferencesStore = preferencesStore
    self.store = store
    usesDeviceChoice = preferencesStore.bool(.usesDeviceThemeChoice, default: false)

    theme.userThemes.attach(store: store)
    // The first run after this arrived: the choice made before it becomes the
    // synced one, rather than every device starting on the default.
    seedIfUnset()
    applySynced()
    observeLocalChoice()
  }

  /// After the workspace changed under the app (a sync pull, or the CLI):
  /// the themes may have, and so may the choice.
  func workspaceDidChange() {
    theme.userThemes.reload()
    applySynced()
  }

  // MARK: - Synced → local

  private func applySynced() {
    guard !usesDeviceChoice else { return }
    applying = true
    defer { applying = false }
    if let selected = read(WorkspacePreferenceKey.themeSelected), !selected.isEmpty {
      theme.adoptSyncedChoice(selected)
    }
    if let raw = read(WorkspacePreferenceKey.themeAppearance),
      let appearance = Self.appearance(fromSynced: raw), preferences.appTheme != appearance
    {
      preferences.appTheme = appearance
    }
  }

  // MARK: - Local → synced

  private func seedIfUnset() {
    guard !usesDeviceChoice else { return }
    if read(WorkspacePreferenceKey.themeSelected) == nil {
      write(WorkspacePreferenceKey.themeSelected, theme.activeThemeIdentifier)
    }
    if read(WorkspacePreferenceKey.themeAppearance) == nil {
      write(WorkspacePreferenceKey.themeAppearance, Self.syncedValue(of: preferences.appTheme))
    }
  }

  private func observeLocalChoice() {
    withObservationTracking {
      _ = theme.activeThemeIdentifier
      _ = preferences.appTheme
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.localChoiceChanged()
        self.observeLocalChoice()
      }
    }
  }

  private func localChoiceChanged() {
    guard !usesDeviceChoice, !applying else { return }
    write(WorkspacePreferenceKey.themeSelected, theme.activeThemeIdentifier)
    write(WorkspacePreferenceKey.themeAppearance, Self.syncedValue(of: preferences.appTheme))
  }

  // MARK: - Helpers

  private func read(_ key: String) -> String? {
    do {
      return try store.preference(key)
    } catch {
      logger.error("Could not read \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private func write(_ key: String, _ value: String) {
    do {
      try store.setPreference(key, value)
    } catch {
      logger.error("Could not write \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }

  /// `system`, `light` or `dark`, the values every app writes.
  nonisolated static func syncedValue(of appearance: AppTheme) -> String {
    switch appearance {
    case .system: return "system"
    case .light: return "light"
    case .dark: return "dark"
    }
  }

  nonisolated static func appearance(fromSynced value: String) -> AppTheme? {
    switch value {
    case "system": return .system
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
  }
}
