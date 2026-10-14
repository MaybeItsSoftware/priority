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
///
/// A blocker that does not exist yet is the last row, "New task", which ⌘↩
/// reaches from anywhere in the list — the list navigator's key for making
/// what you typed. It is written at the blocked task's level, just above it.
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
        if newTaskTitle == nil {
          WorkspaceOverlayHint(text: "Type to find the task it waits on, or to name a new one.")
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
        hints: "↑↓ choose · ↩ wait on it · ⌘↩ new task · esc cancel",
        trailing: results.isEmpty ? nil : "\(results.count)")
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
      let rowCount = results.count + (newTaskTitle == nil ? 0 : 1)
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? 0, by: step, count: rowCount)
        return true
      }
      switch key {
      case "enter":
        let index = selection ?? 0
        if results.indices.contains(index) {
          choose(results[index])
        } else if index == results.count {
          createNewTask()
        }
        return true
      case "cmd+enter":
        createNewTask()
        return true
      default:
        return false
      }
    }
  }

  /// What the "New task" row would write: what you typed, once there is any.
  private var newTaskTitle: String? {
    let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  private static let newTaskRowID = "new-task"

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
          if let title = newTaskTitle {
            HStack(spacing: theme.space.sm) {
              Label("New task “\(title)”", systemImage: "plus")
                .font(theme.bodyFont())
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: theme.space.md)
              KeyCapRow(keys: ShortcutReference.displayKeys(forBinding: "cmd+enter"))
            }
            .overlayRow(isSelected: results.count == (selection ?? 0))
            .id(Self.newTaskRowID)
            .onTapGesture { createNewTask() }
            .help("Make it a task beside this one, just above it, and wait on it")
          }
        }
      }
      .onChange(of: selection) { _, index in
        guard let index else { return }
        proxy.scrollTo(results.indices.contains(index) ? results[index].id : Self.newTaskRowID)
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

  private func createNewTask() {
    guard let title = newTaskTitle else { return }
    if let failure = model.addNewBlocker(titled: title, to: request.task) {
      error = failure
      return
    }
    model.dismissOverlay()
  }
}

/// The inspector's Blocked by rows: what the task waits on, each with a way
/// to stop waiting on it, the finder for another, and — read only — the
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
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      InspectorRow("Blocked by") {
        ForEach(blockers) { blocker in
          HStack(alignment: .firstTextBaseline, spacing: theme.space.xxs) {
            link(to: blocker, stop: "blocker.\(blocker.id)")
            InspectorClearButton(label: "Stop waiting on \(blocker.title)", stop: "blocker.\(blocker.id).remove") {
              model.removeBlocker(blocker, from: task)
            }
          }
        }
        Button(blockers.isEmpty ? "Add blocker" : "Add another") { model.presentBlockerFinder() }
          .buttonStyle(InspectorValueButtonStyle(tone: .dim))
          .inspectorStop("blocker.add", press: { model.presentBlockerFinder() })
          .commandHelp(.taskAddBlocker, note: "Find a task this one waits on until it is done")
      }
      if !blocking.isEmpty {
        InspectorRow("Blocks") {
          ForEach(blocking) { waiting in link(to: waiting, stop: "blocks.\(waiting.id)") }
        }
      }
    }
    .task(id: ReloadKey(taskID: task.id, revision: model.taskContentRevision)) {
      blockers = model.blockers(of: task)
      blocking = model.tasksBlocked(by: task)
    }
  }

  /// A task named in the rows: its title, done or not, and its list when it
  /// is another, and a click goes to it.
  private func link(to other: WorkspaceTask, stop: String) -> some View {
    let isOpen = other.status == .open
    return Button { model.selectTask(other) } label: {
      HStack(spacing: theme.space.xs) {
        Image(systemName: isOpen ? "circle" : "checkmark.circle")
          .font(theme.captionFont)
          .foregroundStyle(isOpen ? theme.muted : theme.success)
        Text(other.title)
          .foregroundStyle(isOpen ? theme.ink : theme.muted)
          .strikethrough(!isOpen)
          .truncationMode(.tail)
        if let list = model.list(for: other), list.id != task.listId {
          Text(list.name)
            .foregroundStyle(theme.dim)
        }
        Spacer(minLength: 0)
      }
    }
    .buttonStyle(InspectorValueButtonStyle())
    .inspectorStop(stop, press: { model.selectTask(other) })
    .help(isOpen ? "\(other.title) — open" : "\(other.title) — done")
  }
}

/// The quiet label over a group's blocked tasks — an outline parent's
/// children, a board column's cards — which sink below the rest. A
/// micro-label and a hairline, nothing to select: the keyboard walks the
/// tasks either side of it as if it were not there.
struct WorkspaceBlockedDivider: View {
  @Environment(\.theme) private var theme

  var body: some View {
    HStack(spacing: theme.space.sm) {
      MicroLabel("Blocked")
        .fixedSize()
      Rectangle()
        .fill(theme.border)
        .frame(height: theme.hairline)
    }
    .help("Waiting on other tasks; they rise again once those are done")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Blocked: these tasks wait on others")
  }
}
