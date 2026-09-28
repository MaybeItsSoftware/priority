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

  /// The user's own theme files. Observed, so an edit to the file in force
  /// redraws everything that reads `specification`.
  let userThemes: UserThemeLibrary

  /// Fallback when nothing is stored, or when a stored identifier no longer
  /// resolves — a theme removed between releases should land the user on the
  /// house style rather than on magenta.
  static let defaultThemeIdentifier = BuiltInThemeSpecifications.chalkIdentifier

  /// The built-ins in registration order, then the user's files in name order.
  var availableThemes: [any ThemePlugin] {
    registry.themePlugins + userThemes.plugins.map { $0 as any ThemePlugin }
  }

  /// The user's pick. For a user theme this can outlive its file — a save that
  /// briefly removes it, or a typo that stops it loading — in which case
  /// `activeThemePlugin` renders Chalk until the file is back, and the pick
  /// comes back with it rather than having been overwritten.
  var activeThemeIdentifier: String {
    didSet {
      guard activeThemeIdentifier != oldValue else { return }
      guard plugin(withIdentifier: activeThemeIdentifier) != nil else {
        activeThemeIdentifier = oldValue
        return
      }
      // User themes are not in the registry, so this is a no-op for them.
      registry.activateThemePlugin(identifier: activeThemeIdentifier)
      preferencesStore.set(activeThemeIdentifier, for: .activeThemePluginIdentifier)
    }
  }

  /// Resolved through the observed identifier rather than the registry's own
  /// active pointer, so everything derived from it redraws on a swap.
  var activeThemePlugin: any ThemePlugin {
    plugin(withIdentifier: activeThemeIdentifier) ?? ChalkThemePlugin()
  }

  /// True while the pick is a user theme whose file is missing or did not
  /// load, so Chalk is standing in for it.
  var isFallingBack: Bool { plugin(withIdentifier: activeThemeIdentifier) == nil }

  var specification: ThemeSpecification { activeThemePlugin.specification }

  /// What `validate()` says about the active theme, worst first. Surfaced in
  /// the settings page — a theme audit nobody can read is a test, and this is
  /// meant to be the other thing.
  var activeThemeIssues: [ThemeIssue] { specification.validate() }

  init(
    preferencesStore: PreferencesStore,
    registry: PluginRegistry,
    userThemes: UserThemeLibrary = .shared
  ) {
    self.preferencesStore = preferencesStore
    self.registry = registry
    self.userThemes = userThemes
    // Before resolving the stored pick, which may be one of these.
    userThemes.start()

    let stored = preferencesStore.string(.activeThemePluginIdentifier)
    let known =
      registry.themePluginsByIdentifier[stored] != nil
      || userThemes.plugins.contains { $0.pluginIdentifier == stored }
    // An unknown built-in identifier is a theme removed between releases, and
    // is dropped. Anything else is taken to be a user theme whose file did
    // not load this time, and is kept so it returns when the file is fixed.
    let keep = known || (!stored.isEmpty && !stored.hasPrefix("native."))
    let resolved = keep ? stored : Self.defaultThemeIdentifier
    self.activeThemeIdentifier = resolved
    if !stored.isEmpty, !known {
      logger.notice(
        "Stored theme \(stored, privacy: .public) is not loaded; rendering \(Self.defaultThemeIdentifier, privacy: .public)"
      )
    }
    registry.activateThemePlugin(identifier: known ? resolved : Self.defaultThemeIdentifier)

    userThemes.currentSpecification = { [weak self] in
      self?.specification ?? BuiltInThemeSpecifications.chalk
    }
    userThemes.onExported = { [weak self] identifier in
      self?.activeThemeIdentifier = identifier
    }
  }

  func plugin(withIdentifier identifier: String) -> (any ThemePlugin)? {
    registry.themePluginsByIdentifier[identifier]
      ?? userThemes.plugins.first { $0.pluginIdentifier == identifier }
  }

  /// Resolve without the environment — for AppKit surfaces that have no
  /// `colorScheme` to read.
  func theme(for appearance: ThemeAppearance) -> Theme {
    Theme(specification: specification, appearance: appearance)
  }
}
