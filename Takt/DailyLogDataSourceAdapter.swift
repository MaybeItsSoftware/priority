import Foundation
import TaktCore

/// Bridges `DailyLogManager`'s data needs to the repository, so
/// `AppCoordinator` doesn't have to conform to yet another protocol. Same role
/// as `IntegrationDataSourceAdapter`.
@MainActor
final class DailyLogDataSourceAdapter: DailyLogDataSource {
  private let repository: TaskRepository
  private let startDates: StartDateManager

  init(
    repository: TaskRepository,
    startDates: StartDateManager
  ) {
    self.repository = repository
    self.startDates = startDates
  }

  /// The day's plan over the Checkvist tasks: see `DayLogPlan` for what it
  /// counts, and for why it is not the workspace's Today.
  var plannedTaskIdsForToday: [Int] {
    DayLogPlan.plannedTaskIds(
      openTasks: repository.tasks.filter { $0.status == 0 },
      startDate: { [startDates] task in startDates.startDate(for: task) }
    )
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
