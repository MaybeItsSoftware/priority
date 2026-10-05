import SwiftUI
import TaktCore

/// The General and Focus pages. Every row here is a preference the app reads
/// today; the Checkvist-era rows that changed nothing (menu bar width, named
/// times, the legacy timer) are gone, and the Checkvist tools moved to the
/// Checkvist page, where they belong.
extension SettingsView {
  @ViewBuilder
  var generalPane: some View {
    Section {
      SettingsToggleRow(
        "Launch at login",
        detail: "Start Takt when you log in, so the hotkeys and the menu bar are ready.",
        isOn: preferenceBinding(\.launchAtLogin))
    } header: {
      Text("Startup")
    }

    Section {
      SettingsToggleRow(
        "Confirm before deleting tasks",
        detail: "Ask before a delete. Undo works either way.",
        isOn: preferenceBinding(\.confirmBeforeDelete))
    } header: {
      Text("Tasks")
    }

    completionCelebrationSection
  }

  @ViewBuilder
  var focusPane: some View {
    Section {
      SettingsToggleRow(
        "Open on the focus screen",
        detail:
          "The window comes up on Today. Turn this on to land on the focus ladder instead, with its conditions and available time. A running session is shown either way.",
        isOn: preferenceBinding(\.opensOnFocusScreen))
    } header: {
      Text("Opening the window")
    }

    Section {
      SettingsRow(
        "Run focus blocks in",
        detail:
          "Starting a block puts the window away. The floating panel stays over your work, shrunk to the task and its clock; "
          + "the menu bar shows the same in the status item and hands the keyboard straight back."
      ) {
        ThemedSegmentedPicker(
          selection: preferenceBinding(\.focusRunSurface),
          options: [
            ThemedPickerOption("Panel", value: FocusRunSurface.panel),
            ThemedPickerOption("Menu bar", value: FocusRunSurface.menuBar),
            ThemedPickerOption("Both", value: FocusRunSurface.both),
          ])
      }
      SettingsToggleRow(
        "Ask how each focus block went",
        detail:
          "Finishing a block asks for a quality multiplier, which is what turns minutes into points. Turn this off to log every block at ×1 and keep moving.",
        isOn: preferenceBinding(\.scoresEachFocusBlock))
    } header: {
      Text("Running a block")
    }
  }

  /// What completing something looks like. A set of alternatives to choose
  /// between rather than one plugin card per preset in the sidebar.
  @ViewBuilder
  private var completionCelebrationSection: some View {
    let celebration = checkvistManager.celebration
    Section {
      SettingsRow("Celebration", detail: celebration.activeCelebration.pluginDescription) {
        ThemedMenuPicker(
          "Celebration",
          selection: Binding(
            get: { celebration.activeCelebrationIdentifier },
            set: { celebration.activeCelebrationIdentifier = $0 }),
          options: celebration.availableCelebrations.map {
            ThemedPickerOption(
              $0.displayName, value: $0.pluginIdentifier, systemImage: $0.celebrationIconSystemName)
          })
      }
      SettingsToggleRow(
        "Play a sound",
        detail:
          "Haptics only reach a Force Touch trackpad, and only while you are touching it. On a keyboard and mouse, a sound is the only feedback you can feel.",
        isOn: Binding(
          get: { celebration.soundEnabled },
          set: { celebration.soundEnabled = $0 }))
    } header: {
      Text("Completing a task")
    }
  }
}
