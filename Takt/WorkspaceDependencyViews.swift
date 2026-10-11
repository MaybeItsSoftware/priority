import SwiftUI
import TaktCore
import TaktWorkspace

/// The task a blocker is being found for.
struct WorkspaceBlockerRequest: Identifiable {
  let id = UUID()
  let task: WorkspaceTask
}

/// Blocked by: `bb`. Finds the task this one waits on, from anywhere in the
/// workspace, by what it says — the search's own index, filtered as you type.
/// Return makes the selected task a blocker; one that would close a loop is
/// refused, and says so.
struct WorkspaceBlockerFinder: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceBlockerRequest
  @State private var query = ""
  @State private var results: [TaskSearchResult] = []
  @State private var selection: Int?
  @State private var error: String?
  /// The task itself and what it already waits on, read once when the
  /// finder opens: neither is worth offering.
  @State private var excluded: Set<String> = []

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceOverlayField(
        symbol: "link", prompt: "Blocked by… find the task it waits on", text: $query,
        context: request.task.title)
      FocusRule()
      Group {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
          WorkspaceOverlayHint(text: "Type to find the task it waits on.")
        } else if results.isEmpty {
          WorkspaceOverlayHint(text: "No open task matches.")
        } else {
          list
        }
      }
      .frame(height: WorkspaceOverlayMetrics.listHeight)
      if let error {
        Text(error)
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, theme.listGutter)
          .padding(.vertical, theme.space.xxs)
      }
      WorkspaceOverlayFooter(
        hints: "↑↓ choose · ↩ wait on it · esc cancel", trailing: results.isEmpty ? nil : "\(results.count)")
    }
    .onAppear {
      excluded = Set([request.task.id] + model.blockers(of: request.task).map(\.id))
    }
    .onChange(of: query) { _, text in
      selection = nil
      error = nil
      results = model.searchResults(matching: text).filter { !$0.task.isList && !excluded.contains($0.id) }
    }
    .overlayKeys(model, id: overlayID) { key in
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? 0, by: step, count: results.count)
        return true
      }
      guard key == "enter" else { return false }
      let index = selection ?? 0
      if results.indices.contains(index) { choose(results[index]) }
      return true
    }
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
            let isSelected = index == (selection ?? 0)
            HStack(alignment: isSelected ? .firstTextBaseline : .center, spacing: theme.space.sm) {
              Text(result.task.title)
                .font(theme.bodyFont())
                .foregroundStyle(model.isBlocked(result.task) ? theme.muted : theme.ink)
                .expandsWhenSelected(isSelected)
              Spacer(minLength: theme.space.md)
              MicroLabel(result.list.name)
                .lineLimit(1)
                .fixedSize(horizontal: isSelected, vertical: false)
            }
            .overlayRow(isSelected: isSelected)
            .id(result.id)
            .onTapGesture { choose(result) }
          }
        }
      }
      .onChange(of: selection) { _, index in
        guard let index, results.indices.contains(index) else { return }
        proxy.scrollTo(results[index].id)
      }
    }
  }

  private func choose(_ result: TaskSearchResult) {
    if let failure = model.addBlocker(result.task, to: request.task) {
      error = failure
      return
    }
    model.dismissOverlay()
  }
}

/// The inspector's Blocked by section: what the task waits on, each with a
/// way to stop waiting on it, the finder for another, and — read only — the
/// tasks that wait on this one.
struct WorkspaceDependencyInspectorSection: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  @State private var blockers: [WorkspaceTask] = []
  @State private var blocking: [WorkspaceTask] = []

  private struct ReloadKey: Hashable {
    let taskID: String
    let revision: Int
  }

  var body: some View {
    InspectorSection("Blocked by") {
      ForEach(blockers) { blocker in
        HStack(spacing: theme.space.xs) {
          link(to: blocker, stop: "blocker.\(blocker.id)")
          Button {
            model.removeBlocker(blocker, from: task)
          } label: {
            Image(systemName: "xmark")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
          }
          .buttonStyle(.plain)
          .inspectorStop("blocker.\(blocker.id).remove")
          .accessibilityLabel("Stop waiting on \(blocker.title)")
          .help("Stop waiting on \(blocker.title)")
        }
      }
      Button { model.presentBlockerFinder() } label: {
        Label(blockers.isEmpty ? "Wait on a task…" : "Wait on another…", systemImage: "link")
      }
      .buttonStyle(FocusActionButtonStyle())
      .inspectorStop("blocker.add")
      .commandHelp(.taskAddBlocker, note: "Find a task this one waits on until it is done")
      if !blocking.isEmpty {
        Text(blocking.count == 1 ? "Blocks" : "Blocks \(blocking.count)")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .padding(.top, theme.space.xxs)
        ForEach(blocking) { waiting in link(to: waiting, stop: "blocks.\(waiting.id)") }
      }
    }
    .task(id: ReloadKey(taskID: task.id, revision: model.taskContentRevision)) {
      blockers = model.blockers(of: task)
      blocking = model.tasksBlocked(by: task)
    }
  }

  /// A task named in the section: its title, done or not, and its list, and
  /// a click goes to it.
  private func link(to other: WorkspaceTask, stop: String) -> some View {
    let isOpen = other.status == .open
    return Button { model.selectTask(other) } label: {
      HStack(spacing: theme.space.xs) {
        Image(systemName: isOpen ? "circle" : "checkmark.circle")
          .foregroundStyle(isOpen ? theme.muted : theme.success)
        Text(other.title)
          .foregroundStyle(isOpen ? theme.ink : theme.muted)
          .strikethrough(!isOpen)
          .lineLimit(1)
          .truncationMode(.tail)
        if let list = model.list(for: other), list.id != task.listId {
          Text(list.name)
            .foregroundStyle(theme.dim)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .font(theme.captionFont)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .inspectorStop(stop)
    .help(isOpen ? "\(other.title) — open" : "\(other.title) — done")
  }
}
