import PriorityWorkspace
import SwiftUI

/// Use a real button for navigation so drag and rename gestures do not own
/// the single-click action. Keep text-field interaction separate while editing.
struct WorkspaceSelectableListRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  let list: TaskList

  var body: some View {
    if model.isRenaming(.list(list)) {
      rowLabel
    } else {
      Button {
        model.selectList(list.id)
        model.reportKeyboardFocus(.sidebar)
      } label: {
        rowLabel
      }
      .buttonStyle(.plain)
    }
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
    .padding(.vertical, 5)
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

/// The gap between two sidebar rows, as a drop target.
///
/// Dropping a list *on* another list nests it, which is a different and
/// useful thing — so reordering needed somewhere else to land. This is that
/// somewhere: a hairline that only shows itself while a drag is over it, so
/// the sidebar does not grow a row of empty strips at rest.
struct WorkspaceSidebarDropSeparator: View {
  @Environment(WorkspaceViewModel.self) private var model
  /// The row this gap sits above, or nil for the gap after the last row.
  let beforeID: String?
  /// The folder this group belongs to; nil at the top level.
  let folderID: String?

  @State private var isTargeted = false

  var body: some View {
    Rectangle()
      .fill(isTargeted ? Color.accentColor : .clear)
      .frame(height: isTargeted ? 2 : 1)
      .frame(maxWidth: .infinity)
      // Bigger than it looks, because a 2pt target is one nobody can hit.
      .padding(.vertical, 3)
      .contentShape(Rectangle())
      .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isTargeted) { providers in
        WorkspaceTaskDrag.readItemID(from: providers) { payload in
          model.placeDroppedItem(payload, before: beforeID, inFolderID: folderID)
        }
      }
      .accessibilityHidden(true)
  }
}
