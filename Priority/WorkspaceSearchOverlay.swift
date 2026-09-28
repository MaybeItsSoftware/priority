import PriorityCore
import PriorityWorkspace
import SwiftUI

/// Find a task by what it says, from anywhere in the workspace.
///
/// An overlay rather than a field in the toolbar: searching is a thing you do
/// and then stop doing, and the keyboard should be entirely inside it while it
/// is up — typing narrows, arrows choose, Return goes there, Escape leaves.
struct WorkspaceSearchOverlay: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 0) {
      WorkspaceOverlayField(
        symbol: "magnifyingglass", prompt: "Search tasks", text: $model.searchQuery,
        context: model.searchIncludesCompleted ? "Including done" : nil)
      FocusRule()

      Group {
        if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
          WorkspaceOverlayHint(text: "Type to search every task’s title and notes.")
        } else if model.searchResults.isEmpty {
          WorkspaceOverlayHint(text: "No matches.")
        } else {
          results
        }
      }
      .frame(height: WorkspaceOverlayMetrics.listHeight)

      HStack(spacing: theme.space.md) {
        Toggle("Include completed", isOn: $model.searchIncludesCompleted)
          .toggleStyle(.checkbox)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
        Spacer()
      }
      .padding(.horizontal, theme.listGutter)
      .padding(.vertical, theme.space.xxs)
      WorkspaceOverlayFooter(
        hints: "↑↓ choose · ↩ open · ⌘. include done · esc close",
        trailing: model.searchResults.isEmpty ? nil : "\(model.searchResults.count)")
    }
    .overlayKeys(model, id: overlayID) { key in
      if let step = WorkspaceOverlayStep.offset(for: key) {
        model.moveSearchSelection(by: step)
        return true
      }
      switch key {
      case "enter":
        openSelection()
        return true
      case "cmd+.":
        model.searchIncludesCompleted.toggle()
        return true
      default:
        return false
      }
    }
  }

  private var results: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(model.searchResults) { result in
            row(result)
              .id(result.id)
              .onTapGesture { model.reveal(result) }
          }
        }
      }
      .onChange(of: model.selectedSearchResultID) { _, id in
        guard let id else { return }
        proxy.scrollTo(id, anchor: .center)
      }
    }
  }

  private func row(_ result: TaskSearchResult) -> some View {
    let isSelected = result.id == model.selectedSearchResultID
    return VStack(alignment: .leading, spacing: theme.space.xxs) {
      HStack(spacing: theme.space.sm) {
        Text(result.task.title)
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
          .strikethrough(result.task.status == .completed)
          .lineLimit(1)
        Spacer(minLength: theme.space.md)
        MicroLabel(result.list.name)
          .lineLimit(1)
      }
      if let snippet = result.notesSnippet {
        Text(snippet)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .lineLimit(1)
      }
    }
    .overlayRow(isSelected: isSelected)
  }

  private func openSelection() {
    guard let result = model.searchResults.first(where: { $0.id == model.selectedSearchResultID })
      ?? model.searchResults.first
    else { return }
    model.reveal(result)
  }
}
