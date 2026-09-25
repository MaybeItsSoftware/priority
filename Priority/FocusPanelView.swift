import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The summoned panel: the day, over whatever app you were in.
///
/// It is deliberately thin. The day has one presentation — `DayView` — and this
/// only supplies the panel's own chrome: a floating surface with a border and
/// a corner radius, and the dismissal the hotkey implies. What you can read and
/// do here is identical to the window's home pane, because a day that behaved
/// differently depending on where you opened it would be two days.
struct FocusPanelView: View {
  @Environment(WorkspaceViewModel.self) private var model
  let summons: FocusPanelSummons
  let onClose: (FocusPanelDismissal) -> Void

  var body: some View {
    DayView(surface: .panel, resetToken: summons.count, onClose: onClose)
      .environment(model)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
      .overlay(
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
  }
}
