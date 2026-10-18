import Foundation
import TaktCore
import TaktWorkspace

/// Blocked by: a task that waits on other tasks until they are done. The rule
/// — which tasks are blocked, that they sink below their siblings and are
/// never next up — is the Rust core's; the screen only greys what
/// `blockedTaskIDs` names and edits the edges. Buried tasks, whose start is
/// still to come, sink further, below the blocked ones (`core/src/buried.rs`),
/// and are greyed the same way.
@MainActor
extension WorkspaceViewModel {
  /// Whether `task` is open and still waits on an open task.
  func isBlocked(_ task: WorkspaceTask) -> Bool {
    task.status == .open && blockedTaskIDs.contains(task.id)
  }

  /// Whether `task` is open and its start still to come: drawn greyed in the
  /// buried section, below its blocked siblings (the core's order).
  func isBuried(_ task: WorkspaceTask) -> Bool {
    task.status == .open && buriedStarts[task.id] != nil
  }

  /// Whether `task` is drawn stepped back: blocked or buried.
  func isGreyed(_ task: WorkspaceTask) -> Bool {
    isBlocked(task) || isBuried(task)
  }

  /// The outline rows to draw a section label above: the first of each
  /// sibling group's blocked run, and of its buried tail.
  func siblingSectionStarts(in items: [TaskOutlineItem]) -> [String: WorkspaceSiblingSection] {
    guard !blockedTaskIDs.isEmpty || !buriedStarts.isEmpty else { return [:] }
    let labels = BlockedSection.labelledIDs(
      items.map { (id: $0.id, group: "\($0.task.listId)/\($0.task.parentTaskId ?? "")") },
      blocked: Set(items.lazy.filter { self.isBlocked($0.task) }.map(\.id)),
      buried: Set(items.lazy.filter { self.isBuried($0.task) }.map(\.id)))
    return Self.sections(labels)
  }

  /// The cards in a column to draw a section label above, where its cards
  /// end with blocked or buried ones.
  func siblingSectionStarts(inCards cards: [WorkspaceTask]) -> [String: WorkspaceSiblingSection] {
    guard !blockedTaskIDs.isEmpty || !buriedStarts.isEmpty else { return [:] }
    let labels = BlockedSection.labelledIDs(
      cards.map { (id: $0.id, group: 0) },
      blocked: Set(cards.lazy.filter { self.isBlocked($0) }.map(\.id)),
      buried: Set(cards.lazy.filter { self.isBuried($0) }.map(\.id)))
    return Self.sections(labels)
  }

  private static func sections(
    _ labels: (blocked: Set<String>, buried: Set<String>)
  ) -> [String: WorkspaceSiblingSection] {
    var sections: [String: WorkspaceSiblingSection] = [:]
    for id in labels.blocked { sections[id] = .blocked }
    for id in labels.buried { sections[id] = .buried }
    return sections
  }

  /// The finder for a task to wait on, on the selected task. Nothing for a
  /// list or no task.
  func presentBlockerFinder() {
    guard let task = selectedTask, !task.isList else { return }
    presentOverlay(.blocker(WorkspaceBlockerRequest(task: task)))
  }

  /// The tasks `task` waits on, open or done.
  func blockers(of task: WorkspaceTask) -> [WorkspaceTask] {
    (try? store?.blockers(of: task.id)) ?? []
  }

  /// The tasks waiting on `task`.
  func tasksBlocked(by task: WorkspaceTask) -> [WorkspaceTask] {
    (try? store?.tasksBlocked(by: task.id)) ?? []
  }

  /// Makes `task` wait on `blocker`, as one undo step. Returns an error
  /// message — a cycle, most likely — or nil once saved.
  @discardableResult
  func addBlocker(_ blocker: WorkspaceTask, to task: WorkspaceTask) -> String? {
    guard let store else { return "The workspace is not open." }
    var failure: String?
    perform {
      do {
        try store.addBlocker(blocker.id, to: task.id)
      } catch {
        failure = error.localizedDescription
        throw error
      }
      // The blocked task sinks below its siblings, and leaves next up.
      refresh([.outline, .nextUp])
    }
    return failure
  }

  /// Makes `task` wait on a task that does not exist yet: `title`, read as
  /// the add field reads it, written at `task`'s level just above it. Above,
  /// because it has to be done first — and as the blocked task sinks below
  /// its siblings, the new one takes the place it held. One undo step.
  /// Returns an error message, or nil once saved.
  @discardableResult
  func addNewBlocker(titled title: String, to task: WorkspaceTask) -> String? {
    guard let store else { return "The workspace is not open." }
    taskEditor.flush()
    var failure: String?
    perform {
      do {
        _ = try store.createBlocker(capturing: title, for: task)
      } catch {
        failure = error.localizedDescription
        throw error
      }
      refresh([.outline, .sidebar, .nextUp])
    }
    return failure
  }

  func removeBlocker(_ blocker: WorkspaceTask, from task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.removeBlocker(blocker.id, from: task.id)
      refresh([.outline, .nextUp])
    }
  }
}
