import Foundation
import TaktCore
import TaktWorkspace

/// A row of the Conditions tab the keyboard can stand on.
///
/// The tab has two halves — what is available now, and the conditions
/// themselves — and one cursor walks down through both, the way the done
/// rail's walks through its day groups.
enum WorkspaceConditionsStop: Hashable {
  /// A condition in the "Available now" half: Space turns it on or off.
  case available(String)
  /// The new-condition row: Return puts the caret in its field.
  case add
  /// A condition in the "Conditions" half: rename, place, archive.
  case condition(String)

  /// The condition the row is about, if it is about one.
  var conditionID: String? {
    switch self {
    case .available(let id), .condition(let id): id
    case .add: nil
    }
  }

  /// The scroll anchor for the row.
  var anchor: String {
    switch self {
    case .available(let id): "available.\(id)"
    case .add: "add"
    case .condition(let id): "condition.\(id)"
    }
  }
}

/// The right dock's Conditions tab: saying what is available now, and adding,
/// renaming, re-placing and archiving the conditions themselves.
///
/// It replaces a popover on the status bar, another on the focus panel, a
/// picker overlay and a manager overlay — four ways into two halves of one
/// job, none of which could show you both halves at once.
@MainActor
extension WorkspaceViewModel {
  /// Every row the cursor can stand on, top to bottom.
  var conditionsStops: [WorkspaceConditionsStop] {
    selectableFocusConditions.map { .available($0.id) } + [.add] + focusConditions.map { .condition($0.id) }
  }

  /// The row the keyboard is on. A cursor whose row has gone — a condition
  /// archived out of the "Available now" half, say — lands on the same
  /// condition in the other half rather than jumping to the top.
  var conditionsCursorStop: WorkspaceConditionsStop {
    let stops = conditionsStops
    if let cursor = conditionsCursor {
      if stops.contains(cursor) { return cursor }
      if let id = cursor.conditionID, stops.contains(.condition(id)) { return .condition(id) }
    }
    return stops.first ?? .add
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

  /// How many open tasks require each condition, by condition id. Read from
  /// the plans the ranking already holds, so it costs no query.
  var conditionRequirementCounts: [String: Int] {
    var counts: [String: Int] = [:]
    for plan in taskPlanningByID.values {
      for id in Set((plan.requirementGroups ?? []).flatMap { $0 }) { counts[id, default: 0] += 1 }
    }
    return counts
  }

  private var conditionUnderCursor: TaskCondition? {
    conditionsCursorStop.conditionID.flatMap { id in focusConditions.first { $0.id == id } }
  }

  /// The tab's own commands. `key` is the one that asked, which the
  /// cursor's motion reads to know which way to go.
  func runConditionsCommand(_ id: WorkspaceCommandID, key: String? = nil) {
    switch id {
    case .motionConditionsSelect: if let key { moveConditionsCursor(key) }
    case .conditionsToggle:
      // Only the conditions you can say hold: an archived one nothing needs
      // is in the lower half to be restored, not to be turned on.
      if let condition = conditionUnderCursor, selectableFocusConditions.contains(where: { $0.id == condition.id }) {
        toggleFocusCondition(condition)
      }
    case .conditionsEdit: editConditionsStop()
    case .conditionsNew:
      conditionsCursor = .add
      conditionsAddFieldRequest += 1
    case .conditionsTogglePlace:
      if let condition = conditionUnderCursor {
        saveCondition(
          condition, name: condition.name, isLocation: !condition.isLocation, isArchived: condition.isArchived)
      }
    case .conditionsArchive:
      if let condition = conditionUnderCursor {
        saveCondition(
          condition, name: condition.name, isLocation: condition.isLocation, isArchived: !condition.isArchived)
      }
    case .conditionsClear: clearFocusConditions()
    case .conditionsUseAgain: if !suggestedContextIDs.isEmpty { confirmSuggestedContext() }
    case .conditionsClose: leaveConditionsTab()
    default: break
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
