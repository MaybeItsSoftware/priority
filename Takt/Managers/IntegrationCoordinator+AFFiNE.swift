import AppKit
import Foundation
import TaktCore

/// The AFFiNE half of `IntegrationCoordinator`.
///
/// Lifted into its own file because the coordinator is already at the size the
/// linter tolerates, and because these three are one story: a list, its
/// checklist document, and the day beside it.
@MainActor
extension IntegrationCoordinator {

  /// Squares the current list with its AFFiNE checklist.
  ///
  /// Boxes ticked in AFFiNE close their tasks in Checkvist first; what is still
  /// open is then written back. Doing it in that order is what keeps the two
  /// ends from undoing each other.
  func syncAFFiNEChecklist() async {
    guard affineIntegrationEnabled else {
      onError?("Enable the AFFiNE integration in Preferences first.")
      return
    }
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }

    do {
      let outcome = try await affinePlugin.syncChecklist(
        tasks: ds.tasks,
        listId: ds.listId,
        listTitle: ds.listTitle,
        closingTicked: { [weak self] tickedTaskIds in
          guard let self, let onCloseTasks = self.onCloseTasks else { return ds.tasks }
          await onCloseTasks(tickedTaskIds)
          // Re-read rather than subtract: closing a recurring task creates its
          // next occurrence, which belongs in the checklist that is about to be
          // written.
          return self.dataSource?.tasks ?? []
        }
      )
      onError?(nil)
      onStatus?(affineChecklistStatusMessage(for: outcome))
    } catch {
      onError?(error.localizedDescription)
    }
  }

  /// Writes a day into the AFFiNE document that day owns.
  ///
  /// - Parameter renderedSection: the day as `DailyNoteMarkdown` renders it for
  ///   the vault. Passed in because the daily log is not this coordinator's to
  ///   read, and because both destinations should show the same day.
  func exportDayToAFFiNE(
    day: Date = Date(),
    renderedSection: String,
    titlePattern: String
  ) async {
    guard affineIntegrationEnabled else {
      onError?("Enable the AFFiNE integration in Preferences first.")
      return
    }

    do {
      let document = try await affinePlugin.exportDay(
        day,
        renderedSection: renderedSection,
        titlePattern: titlePattern
      )
      onError?(nil)
      onStatus?(affineStatusMessage(for: document))
    } catch {
      onError?(error.localizedDescription)
    }
  }

  /// Opens the list's AFFiNE checklist in the browser. `false` when the list
  /// has never been synced, or when the workspace URL was never learned.
  @discardableResult
  func openAFFiNEDocument(listId: String) -> Bool {
    guard let url = affinePlugin.checklistDocumentURL(forListId: listId) else {
      onError?("This list has no AFFiNE checklist yet. Run `sync affine` first.")
      return false
    }
    NSWorkspace.shared.open(url)
    onError?(nil)
    return true
  }

  private func affineChecklistStatusMessage(for outcome: AFFiNEChecklistOutcome) -> String {
    let closed = outcome.closedTaskIds.count
    if closed > 0 {
      let plural = closed == 1 ? "task" : "tasks"
      return "AFFiNE: closed \(closed) ticked \(plural), checklist updated"
    }
    return affineStatusMessage(for: outcome.document)
  }

  private func affineStatusMessage(for document: AFFiNEDocumentRef) -> String {
    guard document.didWrite else {
      return "AFFiNE: \u{201C}\(document.title)\u{201D} already up to date"
    }
    // A lossy import is still an import. Saying so beats a silent success the
    // user only notices when a table has become paragraphs.
    if document.lossy || !document.warnings.isEmpty {
      return "AFFiNE: wrote \u{201C}\(document.title)\u{201D} (some formatting simplified)"
    }
    return "AFFiNE: wrote \u{201C}\(document.title)\u{201D}"
  }
}
