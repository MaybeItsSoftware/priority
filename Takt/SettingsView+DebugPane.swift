#if DEBUG
  import TaktCore
  import SwiftUI

  /// Debug-only pane for `SettingsView`. Pulled out of the main file as part
  /// of the Phase-4 settings split; the contents are unchanged.
  extension SettingsView {
    var debugPane: some View {
      Section(header: MicroLabel("Debug")) {
        Text("Shortcut: Cmd+Shift+K toggles keychain mode for development.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
        Button("Reset onboarding state") {
          checkvistManager.resetOnboardingForDebug()
        }
        .foregroundStyle(theme.danger)
      }
    }
  }
#endif
