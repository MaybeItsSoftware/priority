import Foundation
import TaktCore
import TaktWorkspace

/// A row of the Conditions tab the keyboard can stand on: TaktCore's
/// `ConditionsPaneRow`, where the folding rules are tested.
typealias WorkspaceConditionsStop = ConditionsPaneRow

/// The right dock's Conditions tab: saying what is available now, and adding,
/// renaming, filing under a category and archiving the conditions themselves.
///
/// It replaces a popover on the status bar, another on the focus panel, a
/// picker overlay and a manager overlay — four ways into two halves of one
/// job, none of which could show you both halves at once.
@MainActor
extension WorkspaceViewModel {
  /// The live conditions under their headings, for managing them; the
  /// archived ones are apart, under their own heading at the foot.
  var liveConditionSections: [TaskConditionSection] {
    TaskConditionSection.sections(focusConditions.filter { !$0.isArchived })
  }

  /// The archived conditions, in the order the workspace keeps.
  var archivedConditions: [TaskCondition] {
    TaskConditionSection.sections(focusConditions.filter(\.isArchived)).flatMap(\.conditions)
  }

  private var conditionsLayoutSections: [ConditionsPaneLayout.Section] {
    liveConditionSections.map { .init(id: $0.id, conditionIDs: $0.conditions.map(\.id)) }
  }

  /// Every row the cursor can stand on, top to bottom.
  var conditionsStops: [WorkspaceConditionsStop] {
    ConditionsPaneLayout.rows(
      available: selectableFocusConditions.map(\.id), sections: conditionsLayoutSections,
      folded: foldedConditionSections, archived: archivedConditions.map(\.id),
      showsArchived: showsArchivedConditions)
  }

  /// The row the keyboard is on. A cursor whose row has gone — a condition
  /// archived out of the "Available now" half, or folded away — lands on the
  /// nearest row about the same condition rather than jumping to the top.
  var conditionsCursorStop: WorkspaceConditionsStop {
    ConditionsPaneLayout.landing(conditionsCursor, in: conditionsStops, sections: conditionsLayoutSections)
  }

  /// Opens the tab with the keyboard in it. "Manage conditions…" lands on the
  /// new-condition row, which is where managing usually starts.
  func openConditionsTab(onNewCondition: Bool = false) {
    if onNewCondition { conditionsCursor = .add }
    requestKeyboardFocus(.conditions)
  }

  func moveConditionsCursor(_ key: String) {
    let stops = conditionsStops
    guard !stops.isEmpty else { return }
    switch CursorStep(key: key) {
    case .by(let offset):
      let current = stops.firstIndex(of: conditionsCursorStop) ?? 0
      conditionsCursor = stops[CursorStepping.index(from: current, by: offset, count: stops.count)]
    case .first: conditionsCursor = stops.first
    case .last: conditionsCursor = stops.last
    case nil: break
    }
  }

  var conditionUnderCursor: TaskCondition? {
    conditionsCursorStop.conditionID.flatMap { id in focusConditions.first { $0.id == id } }
  }

  /// The tab's own commands. `key` is the one that asked, which the
  /// cursor's motion reads to know which way to go.
  func runConditionsCommand(_ id: WorkspaceCommandID, key: String? = nil) {
    switch id {
    case .motionConditionsSelect: if let key { moveConditionsCursor(key) }
    case .conditionsToggle where conditionsCursorStop.isFolded:
      // On a folded heading, Space opens it, as Return does.
      runConditionsOrganiseCommand(.conditionsFold)
    case .conditionsToggle:
      // Only the conditions you can say hold: an archived one nothing needs
      // is in the lower half to be restored, not to be turned on.
      if let condition = conditionUnderCursor, selectableFocusConditions.contains(where: { $0.id == condition.id }) {
        toggleFocusCondition(condition)
      }
    case .conditionsEdit: editConditionsStop()
    case .conditionsNew:
      // From a condition, the new one starts in that condition's category.
      if let condition = conditionUnderCursor { newConditionCategory = condition.category }
      conditionsCursor = .add
      conditionsAddFieldRequest += 1
    case .conditionsCategory:
      if conditionsCursorStop == .add {
        presentConditionCategoryFinder(for: nil)
      } else if let condition = conditionUnderCursor {
        presentConditionCategoryFinder(for: condition)
      }
    case .conditionsArchive:
      if let condition = conditionUnderCursor {
        saveCondition(condition, name: condition.name, isArchived: !condition.isArchived)
      }
    case .conditionsClear: clearFocusConditions()
    case .conditionsUseAgain: if !suggestedContextIDs.isEmpty { confirmSuggestedContext() }
    case .conditionsClose: leaveConditionsTab()
    default: runConditionsOrganiseCommand(id)
    }
  }

  /// Return and F2: the new-condition row takes the caret; a condition is
  /// renamed in its row in the lower half, where its name is a field.
  private func editConditionsStop() {
    switch conditionsCursorStop {
    case .add: conditionsAddFieldRequest += 1
    case .available(let id), .condition(let id):
      conditionsCursor = .condition(id)
      renamingConditionID = id
    case .folded, .archived: runConditionsOrganiseCommand(.conditionsFold)
    }
  }

  /// A rename saved or abandoned, or the new-condition field left: the
  /// keyboard goes back to the tab's cursor.
  func finishConditionsEditing() {
    renamingConditionID = nil
    requestKeyboardFocus(.conditions)
  }

  func leaveConditionsTab() {
    guard keyboardFocusArea == .conditions else { return }
    requestKeyboardFocus(.tasks)
  }
}
