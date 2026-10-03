import Foundation
import OSLog
import PriorityCore
import SwiftUI
import UIKit
import WidgetKit

/// Which theme is chosen, which appearance, and the `Theme` they resolve to.
///
/// Owned by the app root and read through `@Environment(\.theme)` (the
/// resolved value) or `@Environment(ThemeStore.self)` (the choices, for
/// Settings). Every change rebuilds `theme`, so the window redraws in the new
/// theme at once; it also re-dresses the UIKit chrome and writes the resolved
/// palette to the app group for the widgets.
///
/// The choice of theme and appearance are the values docs/themes.md syncs
/// (`theme.selected`, `theme.appearance`); "Use a different theme on this
/// device" keeps a second pair that never leaves the device. Imported themes
/// are files in the app group's `themes` folder.
@MainActor
@Observable
final class ThemeStore {
  /// The store the app root owns, for the UIKit and widget side effects that
  /// cannot read the environment.
  private(set) static var shared: ThemeStore?

  private(set) var theme: Theme
  /// Every imported file and what became of it: the theme, or why not, and
  /// the issues found on the way.
  private(set) var library: ThemeFileLibrary = .empty

  /// The theme followed on every device, unless this one opts out.
  var selectedIdentifier: String {
    didSet { persist(selectedIdentifier, Keys.selected); refresh() }
  }

  var appearance: AppearanceChoice {
    didSet { persist(appearance.rawValue, Keys.appearance); refresh() }
  }

  /// "Use a different theme on this device".
  var usesDeviceTheme: Bool {
    didSet { defaults.set(usesDeviceTheme, forKey: Keys.deviceEnabled); refresh() }
  }

  var deviceSelectedIdentifier: String {
    didSet { persist(deviceSelectedIdentifier, Keys.deviceSelected); refresh() }
  }

  var deviceAppearance: AppearanceChoice {
    didSet { persist(deviceAppearance.rawValue, Keys.deviceAppearance); refresh() }
  }

  private let defaults: UserDefaults
  private let themesFolder: URL
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "ThemeStore")
  private var lastWidgetTheme: WidgetTheme?

  enum Keys {
    static let selected = "theme.selected"
    /// The key the appearance picker has always used, so a choice made
    /// before themes survives.
    static let appearance = AppearanceChoice.storageKey
    static let deviceEnabled = "theme.device.enabled"
    static let deviceSelected = "theme.device.selected"
    static let deviceAppearance = "theme.device.appearance"
  }

  init(defaults: UserDefaults = .standard, themesFolder: URL = ThemeStore.defaultThemesFolder) {
    self.defaults = defaults
    self.themesFolder = themesFolder
    let chalk = BuiltInThemeSpecifications.chalkIdentifier
    selectedIdentifier = defaults.string(forKey: Keys.selected) ?? chalk
    appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceChoice.init(rawValue:)) ?? .system
    usesDeviceTheme = defaults.bool(forKey: Keys.deviceEnabled)
    deviceSelectedIdentifier = defaults.string(forKey: Keys.deviceSelected) ?? chalk
    deviceAppearance =
      defaults.string(forKey: Keys.deviceAppearance).flatMap(AppearanceChoice.init(rawValue:)) ?? .system
    theme = .chalk
    library = Self.loadLibrary(from: themesFolder)
    theme = resolveTheme()
  }

  /// Makes this the store the chrome and widgets follow, and dresses them.
  func install() {
    Self.shared = self
    ThemeChrome.apply(theme)
    publishToWidgets()
  }

  nonisolated static var defaultThemesFolder: URL {
    AppGroup.containerURL.appending(path: "Priority/themes", directoryHint: .isDirectory)
  }

  // MARK: What is in force

  /// The identifier actually being followed on this device.
  var effectiveIdentifier: String { usesDeviceTheme ? deviceSelectedIdentifier : selectedIdentifier }
  var effectiveAppearance: AppearanceChoice { usesDeviceTheme ? deviceAppearance : appearance }

  /// The scheme to force: the theme's lock if it has one, else the choice.
  var colorScheme: ColorScheme? { theme.lockedColorScheme ?? effectiveAppearance.colorScheme }

  /// The built-ins, then every imported theme that loaded.
  var available: [ThemeSpecification] { BuiltInThemeSpecifications.all + library.themes }

  /// The chosen theme is unknown here (it failed to load, or has not
  /// arrived), so Chalk is standing in.
  var isFallingBack: Bool { theme.specification.identifier != effectiveIdentifier }

  /// Selects a theme for wherever the choice is being made: this device if it
  /// has opted out, everywhere otherwise.
  func select(_ identifier: String) {
    if usesDeviceTheme { deviceSelectedIdentifier = identifier } else { selectedIdentifier = identifier }
  }

  func setAppearance(_ choice: AppearanceChoice) {
    if usesDeviceTheme { deviceAppearance = choice } else { appearance = choice }
  }

  // MARK: Imported themes

  /// Copies a theme file in and reloads. Returns what the loader made of it.
  @discardableResult
  func importTheme(from url: URL) throws -> ThemeFileOutcome? {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let data = try Data(contentsOf: url)
    try FileManager.default.createDirectory(at: themesFolder, withIntermediateDirectories: true)
    let name = url.lastPathComponent.hasSuffix(".json") ? url.lastPathComponent : url.lastPathComponent + ".json"
    try data.write(to: themesFolder.appending(path: name, directoryHint: .notDirectory), options: .atomic)
    reloadLibrary()
    return library.outcomes.first { $0.source == name }
  }

  /// Deletes an imported file. A theme in use falls back to Chalk.
  func removeTheme(source: String) {
    try? FileManager.default.removeItem(at: themesFolder.appending(path: source, directoryHint: .notDirectory))
    reloadLibrary()
  }

  func reloadLibrary() {
    library = Self.loadLibrary(from: themesFolder)
    refresh()
  }

  private static func loadLibrary(from folder: URL) -> ThemeFileLibrary {
    let files =
      (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let sources = files.filter { $0.pathExtension == ThemeFileLoader.fileExtension }.compactMap { url in
      (try? Data(contentsOf: url)).map { ThemeFileSource(name: url.lastPathComponent, data: $0) }
    }
    return ThemeFileLoader.load(sources)
  }

  // MARK: Resolution

  private func resolveTheme() -> Theme {
    let identifier = effectiveIdentifier
    let specification =
      available.first { $0.identifier == identifier } ?? BuiltInThemeSpecifications.chalk
    return Theme(
      specification: specification, platform: PlatformStructure.resolve(specification),
      displayScale: UIScreen.main.scale)
  }

  private func refresh() {
    let resolved = resolveTheme()
    guard resolved != theme else { return }
    theme = resolved
    guard Self.shared === self else { return }
    ThemeChrome.apply(resolved)
    ThemeChrome.redrawWindows()
    publishToWidgets()
  }

  private func persist(_ value: String, _ key: String) {
    defaults.set(value, forKey: key)
  }

  // MARK: Widgets

  /// Writes the resolved palette for both appearances where the widgets and
  /// the Live Activity read it, and reloads their timelines.
  private func publishToWidgets() {
    let widgetTheme = WidgetTheme(theme)
    guard widgetTheme != lastWidgetTheme else { return }
    if lastWidgetTheme == nil, WidgetTheme.load() == widgetTheme {
      lastWidgetTheme = widgetTheme
      return
    }
    do {
      try widgetTheme.write()
      lastWidgetTheme = widgetTheme
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      logger.error("Widget theme write failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}

extension WidgetTheme {
  init(_ theme: Theme) {
    let specification = theme.specification
    func table(_ appearance: ThemeAppearance) -> [String: String] {
      Dictionary(
        uniqueKeysWithValues: ThemeColorRole.allCases.map {
          ($0.rawValue, specification.palette.color($0, in: appearance).hexString)
        })
    }
    let typography = theme.structure.typography
    let installed = Set(UIFont.familyNames)
    self.init(
      identifier: specification.identifier,
      lockedAppearance: specification.lockedAppearance?.rawValue,
      light: table(.light), dark: table(.dark),
      bodyFamily: typography.body.families.first { installed.contains($0) },
      monoFamily: typography.mono.families.first { installed.contains($0) },
      controlRadius: theme.radius.control, hairline: theme.structure.border.hairline)
  }
}

/// The appearance the user chose. Themes follow the system by default; the
/// other two pin it. A theme locked to one appearance overrides this.
enum AppearanceChoice: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  static let storageKey = "appearanceChoice"
}

/// The UIKit chrome — navigation bars, tab bars, segmented controls — dressed
/// in the theme's faces and colours rather than San Francisco on material.
@MainActor
enum ThemeChrome {
  static func apply(_ theme: Theme) {
    let type = theme.type
    let paper = theme.uiColor(.paper)
    let border = theme.uiColor(.border)
    let ink = theme.uiColor(.ink)
    let muted = theme.uiColor(.mutedText)
    let primary = theme.uiColor(.primary)
    let body = theme.structure.typography.scale.body

    let navigation = UINavigationBarAppearance()
    navigation.configureWithOpaqueBackground()
    navigation.backgroundColor = paper
    navigation.shadowColor = border
    navigation.titleTextAttributes = [.font: type.uiFont(body, weight: .semibold), .foregroundColor: ink]
    navigation.largeTitleTextAttributes = [
      .font: type.uiFont(theme.structure.typography.scale.display - 4, weight: .semibold), .foregroundColor: ink,
    ]
    let button = UIBarButtonItemAppearance()
    button.normal.titleTextAttributes = [.font: type.uiFont(body - 1)]
    navigation.buttonAppearance = button
    UINavigationBar.appearance().standardAppearance = navigation
    UINavigationBar.appearance().scrollEdgeAppearance = navigation
    UINavigationBar.appearance().compactAppearance = navigation

    let tabLabel = (theme.structure.typography.scale.caption - 2).rounded()
    let tab = UITabBarAppearance()
    tab.configureWithOpaqueBackground()
    tab.backgroundColor = paper
    tab.shadowColor = border
    for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
      item.normal.titleTextAttributes = [.font: type.uiFont(tabLabel), .foregroundColor: muted]
      item.normal.iconColor = muted
      item.selected.titleTextAttributes = [.font: type.uiFont(tabLabel, weight: .medium), .foregroundColor: primary]
      item.selected.iconColor = primary
    }
    UITabBar.appearance().standardAppearance = tab
    UITabBar.appearance().scrollEdgeAppearance = tab

    let segment = theme.structure.typography.scale.caption
    UISegmentedControl.appearance().setTitleTextAttributes([.font: type.uiFont(segment)], for: .normal)
    UISegmentedControl.appearance().setTitleTextAttributes(
      [.font: type.uiFont(segment, weight: .medium)], for: .selected)
  }

  /// Appearance proxies only dress views created after they are set, so a
  /// live theme change re-adds each window's views to pick them up.
  static func redrawWindows() {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        for view in window.subviews {
          view.removeFromSuperview()
          window.addSubview(view)
        }
      }
    }
  }
}
