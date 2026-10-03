import PriorityWorkspace
import SwiftUI

/// Search: FTS through the store, with "include completed". Tapping a result
/// opens its list with the task selected.
struct SearchScreen: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  @State private var search = SearchModel()
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    List {
      if !search.trimmedQuery.isEmpty && !search.results.isEmpty {
        Section {
          ForEach(search.results) { result in
            resultRow(result)
          }
        } header: {
          Text(header).font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(theme.paper)
    .overlay {
      if search.trimmedQuery.isEmpty {
        EmptyState(
          title: "Search every task", message: "Titles and notes, across all your lists.", systemImage: "magnifyingglass")
      } else if search.results.isEmpty && search.searchedQuery == search.trimmedQuery {
        EmptyState(
          title: "No matches", message: search.includesCompleted ? nil : "Completed tasks are hidden.",
          systemImage: "magnifyingglass")
      }
    }
    .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tasks")
    .searchFocused($isFieldFocused)
    .navigationTitle("Search")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Toggle(isOn: $search.includesCompleted) {
          Label("Include completed", systemImage: search.includesCompleted ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .toggleStyle(.button)
        .accessibilityIdentifier("search.includeCompleted")
      }
    }
    .task(id: search.key(revision: model.revision)) {
      // Debounce: a keystroke within 150ms cancels this read before it runs.
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await search.search(store: model.store, workspaceID: model.workspace.id)
    }
    .onChange(of: model.navigation.searchFocusRequest) { _, _ in isFieldFocused = true }
    .onAppear { if model.navigation.searchFocusRequest > 0 { isFieldFocused = true } }
  }

  private var header: String {
    let count = search.results.count
    return count == 1 ? "1 task" : "\(count) tasks"
  }

  private func resultRow(_ result: TaskSearchResult) -> some View {
    let task = result.task
    return Button {
      reveal(result)
    } label: {
      HStack(alignment: .top, spacing: theme.space.sm) {
        TaskCheckbox(status: task.status, isList: task.isList).padding(.top, theme.space.xxs)
        VStack(alignment: .leading, spacing: theme.space.xxs) {
          Text(task.title)
            .font(theme.type.body)
            .foregroundStyle(task.status == .open ? theme.ink : theme.muted)
            .strikethrough(task.status != .open, color: theme.dim)
            .lineLimit(2)
          if let snippet = result.notesSnippet, !snippet.isEmpty {
            Text(snippet).font(theme.type.caption).foregroundStyle(theme.muted).lineLimit(2)
          }
          HStack(spacing: theme.space.xs) {
            Image(systemName: "list.bullet").font(theme.type.glyph(10))
            Text(result.list.name)
          }
          .font(theme.type.footnote)
          .foregroundStyle(ListColor.color(hex: result.list.colorHex) ?? theme.muted)
        }
        Spacer(minLength: 0)
        if let due = task.dueAt {
          Tag(
            text: Format.due(due),
            tint: task.status == .open && Format.isOverdue(due) ? theme.danger : theme.muted)
        }
      }
      .padding(.vertical, theme.space.xs)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(theme.paper)
    .listRowSeparatorTint(theme.borderMuted)
    .contextMenu {
      TaskContextMenu(
        context: TaskMenuContext(
          taskID: task.id, title: task.title, status: task.status, isList: task.isList,
          isPromoted: task.isPromoted == true, isPlanned: model.isPlannedToday(task.id), allowsStructure: false))
    }
    .accessibilityIdentifier("search.result.\(task.title)")
  }

  /// Opens the task's list with the task selected.
  private func reveal(_ result: TaskSearchResult) {
    isFieldFocused = false
    model.navigation.open(.list(result.list.id), isPad: isPad)
    model.navigation.selectedTaskID = result.task.id
  }
}
