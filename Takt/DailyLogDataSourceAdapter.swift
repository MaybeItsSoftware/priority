import Foundation
import TaktCore

/// Bridges `DailyLogManager`'s data needs to the repository and view model, so
/// `AppCoordinator` doesn't have to conform to yet another protocol. Same role
/// as `IntegrationDataSourceAdapter` and `KanbanTaskDataSourceAdapter`.
@MainActor
final class DailyLogDataSourceAdapter: DailyLogDataSource {
  private let repository: TaskRepository
  private let taskListViewModel: TaskListViewModel
  private let startDates: StartDateManager

  init(
    repository: TaskRepository,
    taskListViewModel: TaskListViewModel,
    startDates: StartDateManager
  ) {
    self.repository = repository
    self.taskListViewModel = taskListViewModel
    self.startDates = startDates
  }

  /// The day's plan: open tasks due today or already overdue, plus anything
  /// whose start date has arrived.
  ///
  /// Overdue tasks are included deliberately. They are on today's plate whether
  /// or not today is when they were meant to be done, and a "planned" figure
  /// that ignored them would flatter the day.
  var plannedTaskIdsForToday: [Int] {
    repository.tasks
      .filter { task in
        guard task.status == 0 else { return false }
        switch taskListViewModel.rootDueBucket(for: task) {
        case .overdue, .asap, .today:
          return true
        case .tomorrow, .nextSevenDays, .future, .noDueDate:
          return startDates.startDate(for: task).map { startDate in
            Calendar.current.isDateInToday(startDate)
              || startDate < Calendar.current.startOfDay(for: Date())
          } ?? false
        }
      }
      .map(\.id)
  }

  var taskTitlesById: [Int: String] {
    Dictionary(repository.tasks.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
  }

  /// A genuinely empty list is indistinguishable from one that hasn't arrived,
  /// and treating the second as the first would snapshot an empty plan at
  /// launch and keep it all day. Erring towards "not loaded" only costs a
  /// deferred snapshot on the next popover open.
  var hasLoadedTasks: Bool { !repository.tasks.isEmpty }
}
