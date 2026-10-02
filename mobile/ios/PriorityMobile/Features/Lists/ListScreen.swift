import PriorityWorkspace
import SwiftUI

/// One list scope, with the Outline / Board / Matrix switcher.
struct ListScreen: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  let scope: ListScope

  var body: some View {
    @Bindable var navigation = model.navigation
    VStack(spacing: 0) {
      Picker("View", selection: $navigation.viewMode) {
        ForEach(ListViewMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, Metrics.lg)
      .padding(.vertical, Metrics.sm)
      .accessibilityIdentifier("list.mode")
      Hairline()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle(model.title(for: scope))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      WorkspaceToolbar(onAdd: add)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.navigation.viewMode {
    case .outline: OutlineView(scope: scope).id(scope)
    case .board: BoardView(scope: scope).id(scope)
    case .matrix: MatrixView(scope: scope).id(scope)
    }
  }

  /// The outline adds in place; elsewhere, quick add files into this list.
  private func add() {
    if model.navigation.viewMode == .outline, scope.isSingleTree {
      model.navigation.outlineCommand = .add
    } else {
      model.navigation.quickAddListID = scope.listID
      if case .nested(_, let taskID) = scope { model.navigation.quickAddParentTaskID = taskID } else {
        model.navigation.quickAddParentTaskID = nil
      }
      model.navigation.isQuickAddPresented = true
    }
  }
}

/// Moves a task to another list — or a new one — the Mac's list picker.
struct MoveToListSheet: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let taskID: String
  @State private var query = ""
  @State private var newListName = ""
  @State private var isCreating = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button {
            isCreating = true
          } label: {
            Label("New list…", systemImage: "plus").font(Typeface.body)
          }
          .accessibilityIdentifier("move.newList")
        }
        Section {
          ForEach(candidates) { list in
            Button {
              model.move(taskID, toList: list.id)
              model.showToast("Moved to \(list.name)")
              dismiss()
            } label: {
              HStack {
                Image(systemName: list.systemRole == .inbox ? "tray" : "list.bullet")
                  .foregroundStyle(Palette.color(hex: list.colorHex) ?? Palette.muted)
                VStack(alignment: .leading, spacing: 1) {
                  Text(list.name).font(Typeface.body).foregroundStyle(Palette.ink)
                  if let folder = model.structure.folder(list.folderId) {
                    Text(folder.name).font(Typeface.footnote).foregroundStyle(Palette.muted)
                  }
                }
                Spacer()
                if list.id == currentListID {
                  Image(systemName: "checkmark").foregroundStyle(Palette.primary)
                }
              }
            }
            .disabled(list.id == currentListID)
          }
        }
      }
      .searchable(text: $query, prompt: "Find a list")
      .navigationTitle("Move to list")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
      .alert("New list", isPresented: $isCreating) {
        TextField("Name", text: $newListName)
        Button("Cancel", role: .cancel) {}
        Button("Move") {
          model.move(taskID, toNewListNamed: newListName)
          dismiss()
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var currentListID: String? { model.task(taskID)?.listId }

  /// Lists whose letters appear in the query in order, as the Mac's list
  /// finder matches.
  private var candidates: [TaskList] {
    let lists = model.structure.listsInTreeOrder.filter { $0.completedAt == nil }
    let needle = query.lowercased().filter { !$0.isWhitespace }
    guard !needle.isEmpty else { return lists }
    return lists.filter { list in
      var remaining = Substring(needle)
      for character in list.name.lowercased() where character == remaining.first {
        remaining = remaining.dropFirst()
        if remaining.isEmpty { return true }
      }
      return remaining.isEmpty
    }
  }
}
