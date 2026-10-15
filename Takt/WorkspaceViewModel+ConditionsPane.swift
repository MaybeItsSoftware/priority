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
      available: selectableFocusConditions.filter { !$0.isLocation }.map(\.id), sections: conditionsLayoutSections,
      folded: foldedConditionSections, archived: archivedConditions.map(\.id),
      showsArchived: showsArchivedConditions, hasPlaces: !availablePlaces.isEmpty,
      hasTimeLimit: availableUntil != nil)
  }

  /// The places "Available now" steps through on its Location row.
  var availablePlaces: [TaskCondition] {
    selectableFocusConditions.filter(\.isLocation)
  }

  /// The place said to hold now, if one is.
  var currentPlace: TaskCondition? {
    availablePlaces.first { focusContext.conditionIDs.contains($0.id) }
  }

  /// The whole minutes left before the available time runs out, nil with no
  /// limit.
  func availableMinutesLeft(now: Date = .now) -> Int? {
    availableUntil.map { max(0, Int(($0.timeIntervalSince(now) / 60).rounded(.up))) }
  }

  /// `←`/`→` on "Available now": the place, a quarter of an hour of time,
  /// finishing or not, when it expires, and a condition off or on.
  private func adjustConditionsStop(by step: Int, now: Date = .now) {
    switch conditionsCursorStop {
    case .location:
      let id = ConditionsPaneSteps.place(from: currentPlace?.id, in: availablePlaces.map(\.id), by: step)
      setFocusPlace(id.flatMap { id in availablePlaces.first { $0.id == id } })
    case .time:
      let minutes = ConditionsPaneSteps.minutes(from: availableMinutesLeft(now: now), by: step)
      availableUntil = minutes.map { now.addingTimeInterval(Double($0) * 60) }
      focusContextChanged()
    case .finishOnly:
      let mode: FocusTimeMode = step > 0 ? .finish : .progress
      guard focusContext.mode != mode else { return }
      focusContext.mode = mode
      focusContextChanged()
    case .expiry:
      let stop = ConditionsPaneSteps.Expiry.nearest(to: contextExpiresAt, now: now).stepped(by: step)
      contextExpiresAt = stop.date(now: now)
      focusContextChanged()
    case .available(let id):
      // → turns it on, ← off, as a switch would.
      guard let condition = selectableFocusConditions.first(where: { $0.id == id }),
        focusContext.conditionIDs.contains(id) != (step > 0)
      else { return }
      toggleFocusCondition(condition)
    case .add, .condition, .folded, .archived: break
    }
  }

  /// Starts typing the time you have, on its row, with what was typed so far.
  func beginTypingAvailableTime(_ text: String = "") {
    conditionsCursor = .time
    conditionsTimeEntry = text
  }

  /// Sets the time typed on the Time row: nothing typed is no limit, and an
  /// entry it cannot read is said so and left to fix.
  func commitTypedAvailableTime(now: Date = .now) {
    guard let entry = conditionsTimeEntry else { return }
    let trimmed = entry.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      availableUntil = nil
    } else if let end = ConditionsPaneSteps.time(typed: trimmed, now: now) {
      availableUntil = end
    } else {
      onStatusMessage?("“\(trimmed)” is not a time: try 45, 1h30 or 5pm.")
      return
    }
    conditionsTimeEntry = nil
    focusContextChanged()
    finishConditionsEditing()
  }

  func cancelTypedAvailableTime() {
    conditionsTimeEntry = nil
    finishConditionsEditing()
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
    case .conditionsAdjust:
      adjustConditionsStop(by: key == "left" || key == "h" ? -1 : 1)
    case .conditionsTypeTime:
      // Typing a number anywhere in the tab is saying how long you have.
      beginTypingAvailableTime(key ?? "")
    case .conditionsToggle where conditionsCursorStop == .finishOnly:
      adjustConditionsStop(by: focusContext.mode == .finish ? -1 : 1)
    case .conditionsToggle where conditionsCursorStop == .location:
      // Space steps on to the next place, round to nowhere after the last.
      if currentPlace?.id == availablePlaces.last?.id {
        setFocusPlace(nil)
      } else {
        adjustConditionsStop(by: 1)
      }
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
    case .time: beginTypingAvailableTime()
    case .location, .finishOnly, .expiry: break
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
