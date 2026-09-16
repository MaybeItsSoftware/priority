import PriorityWorkspace
import SwiftUI

/// Find a task by what it says, from anywhere in the workspace.
///
/// A sheet rather than a field in the toolbar: searching is a thing you do and
/// then stop doing, and the keyboard should be entirely inside it while it is
/// up — typing narrows, arrows choose, Return goes there, Escape leaves.
struct WorkspaceSearchSheet: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search tasks", text: $model.searchQuery)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($isFieldFocused)
          .onSubmit { openSelection() }
          .onKeyPress(.upArrow) { model.moveSearchSelection(by: -1); return .handled }
          .onKeyPress(.downArrow) { model.moveSearchSelection(by: 1); return .handled }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)

      Divider()

      if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
        hint("Type to search every task’s title and notes.")
      } else if model.searchResults.isEmpty {
        hint("No matches.")
      } else {
        results
      }

      Divider()
      HStack(spacing: 16) {
        Toggle("Include completed", isOn: $model.searchIncludesCompleted)
          .toggleStyle(.checkbox)
        Spacer()
        Text("↑↓ choose · ↩ open · esc close")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
    }
    .frame(width: 560, height: 420)
    .onAppear { isFieldFocused = true }
    .onExitCommand { dismiss() }
  }

  private var results: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(model.searchResults) { result in
            row(result)
              .id(result.id)
              .contentShape(Rectangle())
              .onTapGesture { open(result) }
          }
        }
      }
      .onChange(of: model.selectedSearchResultID) { _, id in
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
      }
    }
  }

  private func row(_ result: TaskSearchResult) -> some View {
    let isSelected = result.id == model.selectedSearchResultID
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text(result.task.title)
          .fontWeight(.medium)
          .strikethrough(result.task.status == .completed)
          .lineLimit(1)
        Spacer(minLength: 12)
        Text(result.list.name)
          .font(.caption)
          .foregroundStyle(isSelected ? .primary : .secondary)
          .lineLimit(1)
      }
      if let snippet = result.notesSnippet {
        Text(snippet)
          .font(.caption)
          .foregroundStyle(isSelected ? .primary : .secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 8)
    .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
  }

  private func hint(_ text: String) -> some View {
    VStack {
      Spacer()
      Text(text).foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private func openSelection() {
    guard let result = model.searchResults.first(where: { $0.id == model.selectedSearchResultID })
      ?? model.searchResults.first
    else { return }
    open(result)
  }

  private func open(_ result: TaskSearchResult) {
    model.reveal(result)
    dismiss()
  }
}
