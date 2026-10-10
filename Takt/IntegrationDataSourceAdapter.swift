import Foundation

/// Satisfies `IntegrationCoordinator`'s `IntegrationDataSource` requirement from
/// the concrete state owners instead of routing through `AppCoordinator`'s
/// forwarders: `tasks` / `listId` / `activeCredentials` come from
/// `TaskRepository`. `currentTask` is the view model's, which the coordinator
/// owns, so the adapter reaches it through a `weak` `AppCoordinator`.
///
/// It's what let the `tasks` forwarder be deleted from `AppCoordinator`.
@MainActor
final class IntegrationDataSourceAdapter: IntegrationDataSource {
  private let repository: TaskRepository
  private weak var coordinator: AppCoordinator?

  init(repository: TaskRepository, coordinator: AppCoordinator) {
    self.repository = repository
    self.coordinator = coordinator
  }

  var tasks: [CheckvistTask] { repository.tasks }
  var listId: String { repository.listId }
  var listTitle: String { repository.currentListName }
  var activeCredentials: CheckvistCredentials { repository.activeCredentials }
  var currentTask: CheckvistTask? { coordinator?.taskListViewModel.currentTask }
}
