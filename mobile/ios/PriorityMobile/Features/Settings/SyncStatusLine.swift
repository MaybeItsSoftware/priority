import PrioritySync
import SwiftUI

/// The sync state, quietly: at the foot of the list tree, and beside the
/// Sync row in settings (`compact`). Draws nothing until the device is paired
/// unless it is the compact form, where "Off" is the answer.
struct SyncStatusLine: View {
  @Environment(\.theme) private var theme
  var compact = false

  var body: some View {
    if let controller = SyncController.shared {
      let phase = controller.session.phase
      if compact {
        Text(SyncPhaseText.short(phase))
          .font(theme.type.caption)
          .foregroundStyle(tint(phase))
      } else if phase != .unpaired {
        TimelineView(.periodic(from: .now, by: 30)) { context in
          HStack(spacing: theme.space.xs) {
            Image(systemName: SyncPhaseText.symbol(phase))
              .symbolEffect(.rotate, isActive: phase == .syncing)
            Text(SyncPhaseText.describe(phase, now: context.date)).lineLimit(1)
          }
          .font(theme.type.footnote)
          .foregroundStyle(tint(phase))
        }
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("sync.status")
      }
    }
  }

  private func tint(_ phase: SyncSession.Phase) -> Color {
    SyncPhaseText.isProblem(phase) ? theme.danger : theme.muted
  }
}
