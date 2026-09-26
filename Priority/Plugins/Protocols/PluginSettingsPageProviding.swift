import SwiftUI

@MainActor
protocol PluginSettingsPageProviding: Plugin {
  var settingsIconSystemName: String { get }
  func makeSettingsView(manager: AppCoordinator) -> AnyView
  /// Short label SettingsView shows next to the plugin's name in the sidebar
  /// list (e.g. "Enabled", "Disabled", "Built-in plugin"). Each plugin owns
  /// the shape of this string so `SettingsView` doesn't have to switch on
  /// identifiers — see `docs/plugins.md`.
  func sidebarStatusLabel(manager: AppCoordinator) -> String
  /// Which sidebar slot this page occupies.
  ///
  /// Defaults to the plugin's own identifier, which is right for a capability
  /// with one implementation. It exists for the other kind: where the plugins
  /// are a *menu* and whichever one is active vends the page, the slot has to
  /// stay put when the user picks a different one — otherwise the id
  /// `SettingsView` is tracking disappears mid-choice and the selection snaps
  /// back to the first card. `ThemePlugin` overrides it for exactly that
  /// reason.
  var settingsCardIdentifier: String { get }
}

extension PluginSettingsPageProviding {
  /// Default: plugins that don't override the label just describe themselves
  /// as "Built-in plugin". The four native plugins override to show
  /// Enabled/Disabled against their own toggle state.
  func sidebarStatusLabel(manager: AppCoordinator) -> String { "Built-in plugin" }

  var settingsCardIdentifier: String { pluginIdentifier }
}
