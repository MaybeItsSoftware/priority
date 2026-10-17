import Foundation
import TaktCore
import TaktWorkspace

/// Bringing work in from elsewhere, once: the old offline store, plugin-era
/// dailies, and Checkvist lists. Split from `WorkspaceViewModel.swift` for
/// size — it is the same type.
extension WorkspaceViewModel {
  private static let legacyMigrationKey = "localWorkspaceMigratedOfflineTasksV1"
  static let checkvistWorkspaceListIDsKey = "localWorkspaceCheckvistListIDsV1"

  /// Read once by `migrateLegacyDailiesIfNeeded`, never written again.
  private static let dailyProgressTaskIDsKey = "localWorkspaceDailyProgressTaskIDsV1"
  private static let dailyMigrationKey = "localWorkspaceMigratedDailiesV1"

  /// Brings both kinds of pre-existing daily into the new model, once.
  ///
  /// Plugin-era dailies stood alone; they become tasks in a Habits list with a
  /// daily attached. Tasks flagged under the old UserDefaults scheme keep their
  /// task and simply gain one. The old tick history is not carried over — it
  /// recorded that a day was ticked, not what was done, and the new schema's
  /// per-day rows would be inventing the second half.
  func migrateLegacyDailiesIfNeeded(store: WorkspaceStore) throws {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.dailyMigrationKey) else { return }
    let seeds = legacyDailyDefinitions().map { daily in
      LegacyDailySeed(
        id: daily.id,
        title: daily.title,
        activeWeekdays: daily.activeWeekdays,
        intervalDays: daily.intervalDays,
        intervalAnchor: daily.intervalAnchor,
        archivedAt: daily.archivedAt,
        createdAt: daily.createdAt)
    }
    let progressIDs = defaults.stringArray(forKey: Self.dailyProgressTaskIDsKey) ?? []
    try store.importLegacyDailies(seeds, progressTaskIDs: progressIDs)
    defaults.set(true, forKey: Self.dailyMigrationKey)
  }

  /// Reads the plugin's own file through the plugin's own path, rather than
  /// rebuilding it here — `DailyLogService` documents that resolving it twice
  /// is two chances to disagree about where the history lives.
  private func legacyDailyDefinitions() -> [Daily] {
    DailyDefinitionsStore(directoryURL: DailyLogService.defaultStoreDirectoryURL()).load().dailies
  }

  /// The remote ids of the Checkvist lists this workspace has already copied,
  /// so the app fetches only the rest.
  ///
  /// A copy that has since been deleted still counts unless
  /// `includingDeleted` is false: deleting an imported list is how it is got
  /// rid of, and the import that runs whenever the app comes to the front
  /// used to bring every such list straight back. Only the settings page's
  /// Import button, asked for by name, restores them.
  func importedCheckvistListIDs(includingDeleted: Bool = true) -> Set<String> {
    let localIDs = UserDefaults.standard.dictionary(forKey: Self.checkvistWorkspaceListIDsKey) as? [String: String] ?? [:]
    guard !includingDeleted else { return Set(localIDs.keys) }
    let present = Set(lists.map(\.id))
    return Set(localIDs.filter { present.contains($0.value) }.keys)
  }

  /// Mirrors newly discovered Checkvist lists into the desktop sidebar once.
  ///
  /// The desktop workspace deliberately remains local-first: this creates a
  /// local copy of each remote list and its currently open task tree, rather
  /// than making sidebar edits unexpectedly mutate Checkvist. The persisted
  /// mapping prevents every app launch from adding another copy.
  func importCheckvistLists(_ snapshots: [(list: CheckvistList, tasks: [CheckvistTask])]) {
    guard let store, let workspace, !snapshots.isEmpty else { return }

    let defaults = UserDefaults.standard
    var localIDs = defaults.dictionary(forKey: Self.checkvistWorkspaceListIDsKey) as? [String: String] ?? [:]
    var changed = false

    do {
      for snapshot in snapshots {
        let remoteID = String(snapshot.list.id)
        if let localID = localIDs[remoteID], lists.contains(where: { $0.id == localID }) {
          continue
        }

        let seeds = CheckvistWire.importSeeds(prefix: "checkvist:\(remoteID):", tasks: snapshot.tasks)

        let localList: TaskList
        if seeds.isEmpty {
          localList = try store.createList(workspaceId: workspace.id, name: snapshot.list.name)
        } else if let outcome = try store.importTasks(
          workspaceId: workspace.id, listName: snapshot.list.name,
          sourceSystem: Self.checkvistSourceSystem, coreSeeds: seeds)
        {
          localList = outcome.list
        } else {
          continue
        }
        localIDs[remoteID] = localList.id
        changed = true
      }

      guard changed else { return }
      defaults.set(localIDs, forKey: Self.checkvistWorkspaceListIDsKey)
      try load()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func migrateLegacyTasksIfNeeded(into workspace: Workspace, store: WorkspaceStore) throws -> TaskList? {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.legacyMigrationKey) else { return nil }
    let payload = legacyStore.load()
    let legacyTasks = payload.openTasks + payload.archivedTasks
    guard !legacyTasks.isEmpty else {
      defaults.set(true, forKey: Self.legacyMigrationKey)
      return nil
    }

    let seeds = CheckvistWire.importSeeds(prefix: "", tasks: legacyTasks)
    let date = ISO8601DateFormatter().string(from: .now).prefix(10)
    let outcome = try store.importTasks(
      workspaceId: workspace.id, listName: "Imported from old Priority — \(date)",
      sourceSystem: Self.legacyOfflineSourceSystem, coreSeeds: seeds)
    defaults.set(true, forKey: Self.legacyMigrationKey)
    return outcome?.list
  }
}
