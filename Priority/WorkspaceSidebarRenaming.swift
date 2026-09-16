import PriorityWorkspace
import SwiftUI

/// A sidebar list row, which becomes a text field while it is being renamed.
///
/// The row keeps its own geometry either way — colour dot, single line, middle
/// truncation — so starting a rename does not make the sidebar jump.
struct WorkspaceListRowLabel: View {
  @Environment(WorkspaceViewModel.self) private var model
  let list: TaskList

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(Color(priorityHex: list.colorHex))
        .frame(width: 8, height: 8)
      if model.isRenaming(.list(list)) {
        WorkspaceRenameField(
          initialName: list.name,
          onCommit: { model.renameList(list, to: $0) },
          onCancel: { model.cancelRenaming() })
      } else {
        Text(list.name)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(list.name)
      }
    }
    // Double-click to rename, the way the Finder does it. A simultaneous
    // gesture so the row's own single-click selection still happens.
    .simultaneousGesture(TapGesture(count: 2).onEnded {
      model.beginRenaming(.list(list))
    })
  }
}

/// The field itself: opens with the old name selected, commits on return,
/// abandons on escape, and commits on losing focus rather than discarding —
/// clicking away from a rename you have typed should keep it.
struct WorkspaceRenameField: View {
  let initialName: String
  let onCommit: (String) -> Void
  let onCancel: () -> Void

  @State private var name: String
  @FocusState private var isFocused: Bool

  init(initialName: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
    self.initialName = initialName
    self.onCommit = onCommit
    self.onCancel = onCancel
    _name = State(initialValue: initialName)
  }

  var body: some View {
    TextField("Name", text: $name)
      .textFieldStyle(.roundedBorder)
      .font(.body)
      .focused($isFocused)
      .onSubmit { commit() }
      .onExitCommand { onCancel() }
      .onAppear { isFocused = true }
      .onChange(of: isFocused) { wasFocused, nowFocused in
        if wasFocused && !nowFocused { commit() }
      }
  }

  private func commit() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    // An empty name is not a rename; the store would refuse it anyway, and a
    // dialog about it would be a strange answer to someone clicking away.
    guard !trimmed.isEmpty, trimmed != initialName else {
      onCancel()
      return
    }
    onCommit(trimmed)
  }
}
