import PriorityWorkspace
import SwiftUI

/// A selectable sidebar row, which is deliberately not a `Button`.
///
/// It was one, on the reasoning that a real button keeps the single-click
/// action away from the drag and rename gestures. What that actually did was
/// hand the whole row to the button: a button owns the mouse from the moment it
/// goes down, so the `.onDrag` wrapped around this row never started and lists
/// could not be dragged at all. A tap gesture yields to a drag that passes the
/// distance threshold, which is the behaviour both need.
struct WorkspaceSelectableListRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  let list: TaskList

  var body: some View {
    if model.isRenaming(.list(list)) {
      rowLabel
    } else {
      rowLabel
        .onTapGesture { select() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(list.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
    }
  }

  private func select() {
    model.selectList(list.id)
    model.reportKeyboardFocus(.sidebar)
  }

  private var rowLabel: some View {
    HStack {
      WorkspaceListRowLabel(list: list)
      if list.name.caseInsensitiveCompare("Everything") == .orderedSame {
        Text("(list)").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 3)
    .contentShape(Rectangle())
  }
}

/// A sidebar list row, which becomes a text field while it is being renamed.
///
/// The row keeps its own geometry either way — colour dot, single line, middle
/// truncation — so starting a rename does not make the sidebar jump.
struct WorkspaceListRowLabel: View {
  @Environment(WorkspaceViewModel.self) private var model
  let list: TaskList

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: model.icon(for: list))
        .foregroundStyle(Color(priorityHex: list.colorHex))
        .frame(width: 18)
      if model.isRenaming(.list(list)) {
        WorkspaceRenameField(
          initialName: list.name,
          onCommit: { model.renameList(list, to: $0) },
          onCancel: { model.cancelRenaming(itemID: list.id) })
      } else {
        Text(list.name)
          .strikethrough(list.completedAt != nil)
          // Weight, so the current list survives being looked at quickly and
          // survives the tint being hard to see — against the sidebar's own
          // material a wash of accent is not much on its own.
          .fontWeight(model.isCurrentSidebarRow(list.id) ? .semibold : .regular)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(list.name)
      }
    }

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
  @State private var didFinish = false
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
      .onExitCommand { cancel() }
      .onAppear { isFocused = true }
      .onChange(of: isFocused) { wasFocused, nowFocused in
        if wasFocused && !nowFocused { commit() }
      }
      .onDisappear { commit() }
  }

  private func commit() {
    guard !didFinish else { return }
    didFinish = true
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    // An empty name is not a rename; the store would refuse it anyway, and a
    // dialog about it would be a strange answer to someone clicking away.
    guard !trimmed.isEmpty, trimmed != initialName else {
      onCancel()
      return
    }
    onCommit(trimmed)
  }

  private func cancel() {
    guard !didFinish else { return }
    didFinish = true
    onCancel()
  }
}
