import AppKit
import Foundation
import TaktWorkspace

/// A task's links: Drive files and folders, Obsidian notes and folders, web
/// pages. Stored and described by the Rust core (core/src/links.rs); found by
/// the Links plugin; see docs/links.md.
@MainActor
extension WorkspaceViewModel {
  /// The link picker, on the selected task. Nothing for a list or no task.
  func presentLinkPicker() {
    guard let task = selectedTask, !task.isList else { return }
    presentOverlay(.link(WorkspaceLinkRequest(task: task)))
  }

  /// The task's links, described for drawing.
  func links(of task: WorkspaceTask) -> [WorkspaceTaskLink] {
    (try? store?.links(of: task.id)) ?? []
  }

  /// Links `url` to `task` as one undo step, named as the picker found it.
  /// Returns an error message, or nil once saved.
  @discardableResult
  func addLink(_ url: String, title: String? = nil, mimeType: String? = nil, to task: WorkspaceTask) -> String? {
    guard let store else { return "The workspace is not open." }
    var failure: String?
    perform {
      do {
        try store.addLink(url, title: title, mimeType: mimeType, to: task.id)
      } catch {
        failure = error.localizedDescription
        throw error
      }
      waitingDetailsAreStale = true
      refresh([.outline])
    }
    return failure
  }

  /// Takes `url` off `task`'s links, as one undo step.
  func removeLink(_ url: String, from task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.removeLink(url, from: task.id)
      waitingDetailsAreStale = true
      refresh([.outline])
    }
  }

  /// Opens a link where it lives: the browser, Obsidian, Finder.
  func openLink(_ url: String) {
    guard let target = URL(string: url) else { return }
    NSWorkspace.shared.open(target)
  }
}
