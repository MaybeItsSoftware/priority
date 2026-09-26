import Observation
import PriorityCore
import SwiftUI
import os

/// Owns which `ThemePlugin` is active and write-throughs the choice.
///
/// Modelled on `CompletionCelebrationManager`, and for the same reason: themes
/// are a menu rather than an integration, so the registry is retained past
/// `AppCoordinator.init` instead of being read once at launch, and the active
/// identifier is mirrored as `@Observable` state so a picker has something to
/// watch.
///
/// It stops at "which theme". Resolving that against light or dark is the
/// `.themed(_:)` modifier's job, because only SwiftUI knows the appearance a
/// given view is actually being drawn in.
@MainActor
@Observable final class ThemeManager {
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let registry: PluginRegistry
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.priority", category: "ThemeManager")

  /// Fallback when nothing is stored, or when a stored identifier no longer
  /// resolves — a theme removed between releases should land the user on the
  /// house style rather than on magenta.
  static let defaultThemeIdentifier = BuiltInThemeSpecifications.chalkIdentifier

  var availableThemes: [any ThemePlugin] { registry.themePlugins }

  var activeThemeIdentifier: String {
    didSet {
      guard activeThemeIdentifier != oldValue else { return }
      guard registry.activateThemePlugin(identifier: activeThemeIdentifier) else {
        activeThemeIdentifier = oldValue
        return
      }
      preferencesStore.set(activeThemeIdentifier, for: .activeThemePluginIdentifier)
    }
  }

  /// Resolved through the observed identifier rather than the registry's own
  /// active pointer, so everything derived from it redraws on a swap.
  var activeThemePlugin: any ThemePlugin {
    registry.themePluginsByIdentifier[activeThemeIdentifier] ?? ChalkThemePlugin()
  }

  var specification: ThemeSpecification { activeThemePlugin.specification }

  /// What `validate()` says about the active theme, worst first. Surfaced in
  /// the settings page — a theme audit nobody can read is a test, and this is
  /// meant to be the other thing.
  var activeThemeIssues: [ThemeIssue] { specification.validate() }

  init(preferencesStore: PreferencesStore, registry: PluginRegistry) {
    self.preferencesStore = preferencesStore
    self.registry = registry

    let stored = preferencesStore.string(.activeThemePluginIdentifier)
    let resolved =
      registry.themePluginsByIdentifier[stored] != nil ? stored : Self.defaultThemeIdentifier
    self.activeThemeIdentifier = resolved
    if !stored.isEmpty, stored != resolved {
      logger.notice(
        "Stored theme \(stored, privacy: .public) no longer registered; using \(resolved, privacy: .public)"
      )
    }
    registry.activateThemePlugin(identifier: resolved)
  }

  /// Resolve without the environment — for AppKit surfaces that have no
  /// `colorScheme` to read.
  func theme(for appearance: ThemeAppearance) -> Theme {
    Theme(specification: specification, appearance: appearance)
  }
}
