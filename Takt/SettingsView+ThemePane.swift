import TaktCore
import SwiftUI

/// Theme pane for `SettingsView`: the appearance mode and what completing a
/// task looks like. Colour and type come from the theme itself — the theme
/// plugin's page — rather than from overrides layered on here.
extension SettingsView {
  var themePane: some View {
    Section(header: MicroLabel("Appearance")) {
      Picker("Appearance", selection: preferenceBinding(\.appearanceMode)) {
        ForEach(AppearanceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      completionCelebrationPicker
    }
  }

  /// Preset picker for what completing something looks like.
  ///
  /// Lives in the theme pane rather than as plugin cards in the plugin sidebar:
  /// celebrations are a set of alternatives to choose between, and registering
  /// each as `PluginSettingsPageProviding` would spray one sidebar entry per
  /// preset for what is really a single setting.
  @ViewBuilder
  var completionCelebrationPicker: some View {
    let celebration = checkvistManager.celebration
    VStack(alignment: .leading, spacing: 6) {
      Text("Completing a task")
      Picker(
        "",
        selection: Binding(
          get: { celebration.activeCelebrationIdentifier },
          set: { celebration.activeCelebrationIdentifier = $0 }
        )
      ) {
        ForEach(celebration.availableCelebrations, id: \.pluginIdentifier) { preset in
          Label(preset.displayName, systemImage: preset.celebrationIconSystemName)
            .tag(preset.pluginIdentifier)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)

      Text(
        celebration.activeCelebration.pluginDescription
          + " Haptics are separate and always on."
      )
      .font(theme.captionFont)
      .foregroundStyle(theme.muted)

      Toggle(
        "Play a sound",
        isOn: Binding(
          get: { celebration.soundEnabled },
          set: { celebration.soundEnabled = $0 }
        )
      )
        .toggleStyle(.switch)
      .padding(.top, 2)

      // Worth saying plainly, because the obvious assumption — that the haptic
      // already covers this — is wrong for most of the people reading it.
      Text(
        "Haptics only reach a Force Touch trackpad, and only while you are touching it. On a keyboard and mouse, a sound is the only feedback you can feel."
      )
      .font(theme.captionFont)
      .foregroundStyle(theme.muted)
    }
  }
}
