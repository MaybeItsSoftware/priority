import AppKit
import SwiftUI
import TaktCore
import TaktWorkspace

/// The focus panel's list, as its keys see it: the rows the cursor walks and
/// what the place does at its edges. Built afresh by the view that owns the
/// cursor — Today's cards or a list's outline — each time a key arrives.
@MainActor
struct FocusPanelListContext {
  /// Which of the catalogue's surfaces the keys are read on: `.today` on the
  /// day, `.outline` on a list, so a key means what it means in the window.
  let surface: WorkspaceCommandSurface
  let rowIDs: [String]
  /// The rows `:` numbers, in order.
  let numberedIDs: [String]
  let cursorID: String?
  let setCursor: (String?) -> Void
  /// → and ← on the cursor row.
  let right: () -> Void
  let left: () -> Void
  let complete: (WorkspaceTask) -> Void
  let start: (WorkspaceTask) -> Void
  /// Return on a delete waiting to be confirmed.
  let confirmDeletion: () -> Void
  /// Back to the field: `/` to search, Return to add.
  let toField: () -> Void
  let dismiss: () -> Void
  let openInWindow: () -> Void
}

/// Runs the panel's keys once the keyboard has left its field: the window's
/// own keys (`FocusPanelKeys`), two-letter sequences included, acting on the
/// panel's cursor rather than the window's selection. An edit goes through
/// the very calls the window's keys make — the quick-edit overlay, drawn in
/// the panel (`WorkspaceViewModel.overlaySurface`), `editTaskValues(of:)`
/// with its repeat-clash question, the conditions finder — so undo and
/// validation are the window's too.
@MainActor
@Observable
final class FocusPanelKeyRouter {
  /// The digits typed after `:`, while a jump is being typed.
  private(set) var numberJump: String?
  @ObservationIgnored private var sequence = DesktopShortcutSequence()
  /// The list as the last key found it, for a held key released by its
  /// timeout rather than by a second key.
  @ObservationIgnored private var lastContext: FocusPanelListContext?

  /// A key while the list has the keyboard. Returns whether it was used; a
  /// bare key nothing here answers to is swallowed all the same, so a stray
  /// letter neither types nowhere nor beeps.
  func handleListKey(
    _ event: NSEvent, model: WorkspaceViewModel, summons: FocusPanelSummons, context: FocusPanelListContext
  ) -> Bool {
    guard model.panelOverlay == nil, let key = event.workspaceCommandKey else { return false }
    lastContext = context
    // A delete waiting for Return owns the next key, as in the window.
    if model.pendingTaskDeletionID != nil {
      if key == "enter" { context.confirmDeletion() } else { model.cancelPendingTaskDeletion() }
      return true
    }
    if let digits = numberJump {
      typeNumber(key, after: digits, context: context)
      return true
    }
    guard event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) else {
      if let held = sequence.flush() { dispatch(held, model: model, summons: summons, context: context) }
      return dispatch(key, model: model, summons: summons, context: context)
    }
    let sequences = FocusPanelKeys.sequences(on: context.surface)
    switch sequence.advance(key, at: event.timestamp, sequences: sequences) {
    case .pending:
      releaseAfterTimeout(heldAt: event.timestamp, model: model, summons: summons)
      return true
    case .command(let keys):
      dispatch(keys, model: model, summons: summons, context: context)
      return true
    case .flush(let held):
      dispatch(held, model: model, summons: summons, context: context)
      return dispatch(key, model: model, summons: summons, context: context)
    case .flushAndHold(let held):
      dispatch(held, model: model, summons: summons, context: context)
      releaseAfterTimeout(heldAt: event.timestamp, model: model, summons: summons)
      return true
    case .pass:
      return dispatch(key, model: model, summons: summons, context: context)
    }
  }

  /// A key with the caret in the field: only the chorded ones that cannot be
  /// typed into a search — ⌘D, ⌥T, F2, ⌘P and the like (`reachesFromField`).
  func handleFieldKey(
    _ event: NSEvent, model: WorkspaceViewModel, summons: FocusPanelSummons, context: FocusPanelListContext
  ) -> Bool {
    guard model.panelOverlay == nil, model.pendingTaskDeletionID == nil,
      let key = event.workspaceCommandKey,
      let action = FocusPanelKeys.action(forKey: key, on: context.surface),
      FocusPanelKeys.reachesFromField(action, key: key)
    else { return false }
    perform(action, model: model, summons: summons, context: context)
    return true
  }

  /// Lets go of a held key and a half-typed jump, as moving away does.
  func reset() {
    sequence.reset()
    numberJump = nil
  }

  // MARK: - Dispatch

  @discardableResult
  private func dispatch(
    _ key: String, model: WorkspaceViewModel, summons: FocusPanelSummons, context: FocusPanelListContext
  ) -> Bool {
    // The panel's own two: Tab starts, as it does from the field, and ⌘↩
    // opens the window on the row.
    switch key {
    case "tab":
      if let task = cursorTask(model, context) { context.start(task) }
      return true
    case "cmd+enter":
      context.openInWindow()
      return true
    default:
      break
    }
    guard let action = FocusPanelKeys.action(forKey: key, on: context.surface) else {
      // ⌘Q, ⌘W, ⌘, and copy are the app's; a bare key is the list's.
      return !WorkspaceCommandCatalog.isChord(key)
    }
    perform(action, model: model, summons: summons, context: context)
    return true
  }

  private func perform(
    _ action: FocusPanelAction, model: WorkspaceViewModel, summons: FocusPanelSummons,
    context: FocusPanelListContext
  ) {
    switch action {
    case .step(let offset): step(by: offset, context: context)
    case .first: context.setCursor(context.rowIDs.first)
    case .last: context.setCursor(context.rowIDs.last)
    case .right: context.right()
    case .left: context.left()
    case .numberJump:
      sequence.reset()
      numberJump = ""
    case .search, .add: context.toField()
    case .dismiss: context.dismiss()
    case .undo: model.undoLastChange()
    case .redo: model.redoLastUndoneChange()
    case .goToday, .chooseList, .place: summons.go(action, model: model)
    default:
      guard let task = cursorTask(model, context) else { return }
      perform(action, on: task, model: model, context: context)
    }
  }

  /// The edits, each the call the window's key makes, on the panel's row.
  private func perform(
    _ action: FocusPanelAction, on task: WorkspaceTask, model: WorkspaceViewModel, context: FocusPanelListContext
  ) {
    switch action {
    case .complete: context.complete(task)
    case .start: context.start(task)
    case .edit(let field):
      model.presentOverlay(.quickEdit(WorkspaceTaskQuickEditRequest(task: task, kind: .init(field))))
    case .priority(let priority):
      // The core moves a task given a priority to the top of its list.
      model.editTaskValues(of: task) { $0.priority = priority }
    case .conditions:
      guard !task.isList else { return }
      model.presentOverlay(.conditions(WorkspaceConditionPickerRequest(task: task)))
    case .due(let days):
      let start = Calendar.current.startOfDay(for: .now)
      let day = Calendar.current.date(byAdding: .day, value: days, to: start)
      model.editTaskValues(of: task) { $0.dueAt = day; $0.dueDate = nil }
    case .clearDue:
      model.editTaskValues(of: task) { $0.dueAt = nil; $0.dueDate = nil }
    case .clearStart:
      model.editTaskValues(of: task) { $0.startAt = nil }
    case .goToList:
      context.openInWindow()
      model.goToTaskList(task)
    case .delete:
      // Never the running block: that one ends through its own finish.
      guard task.id != model.activeFocusSession?.activeTaskId else { return }
      model.requestTaskDeletion(task)
    default:
      break
    }
  }

  private func cursorTask(_ model: WorkspaceViewModel, _ context: FocusPanelListContext) -> WorkspaceTask? {
    context.cursorID.flatMap(model.task(withID:))
  }

  private func step(by offset: Int, context: FocusPanelListContext) {
    let ids = context.rowIDs
    guard !ids.isEmpty else { return }
    guard let current = context.cursorID.flatMap(ids.firstIndex(of:)) else {
      context.setCursor(offset < 0 ? ids.last : ids.first)
      return
    }
    context.setCursor(ids[CursorStepping.index(from: current, by: offset, count: ids.count)])
  }

  /// `:` owns the keys until Return, as vim's command line does: digits, ⌫
  /// to take one back, anything else to give up.
  private func typeNumber(_ key: String, after digits: String, context: FocusPanelListContext) {
    switch key {
    case _ where key.count == 1 && key.first?.isNumber == true:
      if digits.count < 5 { numberJump = digits + key }
    case "delete":
      numberJump = digits.isEmpty ? nil : String(digits.dropLast())
    case "enter":
      numberJump = nil
      if let number = Int(digits),
        let index = FocusPanelKeys.numberedIndex(number, count: context.numberedIDs.count) {
        context.setCursor(context.numberedIDs[index])
      }
    default:
      numberJump = nil
    }
  }

  private func releaseAfterTimeout(heldAt time: TimeInterval, model: WorkspaceViewModel, summons: FocusPanelSummons) {
    Task { @MainActor [weak self, weak model, weak summons] in
      try? await Task.sleep(for: .seconds(DesktopShortcutSequence.timeout))
      guard let self, let model, let summons, let context = self.lastContext,
        let held = self.sequence.expire(heldAt: time)
      else { return }
      self.dispatch(held, model: model, summons: summons, context: context)
    }
  }
}

extension WorkspaceTaskQuickEditKind {
  init(_ field: FocusPanelAction.Field) {
    switch field {
    case .title: self = .title
    case .due: self = .due
    case .start: self = .start
    case .estimate: self = .estimate
    case .notes: self = .notes
    case .tags: self = .tags
    case .recurrence: self = .recurrence
    }
  }
}

/// What the panel's footer says while `:` is being typed.
extension FocusPanelKeyRouter {
  var numberJumpHint: String? {
    numberJump.map { ":\($0) · ↩ go · ⌫ back · esc cancel" }
  }
}
