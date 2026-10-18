import TaktCore
import TaktWorkspace

/// The habit form's reads and its one write (`WorkspaceStore+Habits.swift`),
/// as the Mac's `WorkspaceViewModel+Dailies` and Android's
/// `WorkspaceRepositoryHabits` make them.
extension WorkspaceModel {
  /// What the form opens on for `taskID`: the habit on it, a new habit from
  /// it, or (nil) a standalone habit. A list is not a habit's task, so it
  /// opens a standalone one, as `gb` on a list does on the Mac.
  func habitFormContext(forTaskID taskID: String?) -> HabitFormContext? {
    do {
      let task = try taskID.flatMap { try store.task(id: $0) }
      return try store.habitFormContext(forTaskId: task?.isList == true ? nil : task?.id)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  /// Saves the form: one undo step, announced with Undo. False when the
  /// store refused it, whose reason is then on screen.
  @discardableResult
  func saveHabit(_ draft: HabitDraft, habitTaskID: String?) -> Bool {
    guard perform({ try $0.saveHabit(draft, habitTaskId: habitTaskID) }) else { return false }
    announce(habitTaskID == nil ? "Habit added" : "Habit saved")
    return true
  }
}
