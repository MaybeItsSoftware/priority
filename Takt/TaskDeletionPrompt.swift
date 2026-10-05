import TaktCore
import TaktWorkspace
import SwiftUI

/// The question a delete key asks before it acts, as a band along the foot
/// of the list rather than a dialog: the answer is one key, and a dialog
/// would take the keyboard away from the list it is asking about.
struct TaskDeletionPrompt: View {
  @Environment(\.theme) private var theme
  let task: WorkspaceTask

  var body: some View {
    VStack(spacing: 0) {
      FocusRule()
      HStack(spacing: theme.space.md) {
        Text("Delete “\(task.title)”?")
          .font(theme.bodyFont())
          .foregroundStyle(theme.danger)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: theme.space.sm)
        KeyHint("↩", "Delete")
        KeyHint("esc", "Cancel")
      }
      .padding(.horizontal, theme.space.lg)
      .padding(.vertical, theme.space.sm)
      .background(theme.danger.opacity(0.08))
    }
    .help("Takes its subtasks with it")
  }
}
