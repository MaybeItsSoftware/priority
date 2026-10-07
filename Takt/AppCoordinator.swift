import AppKit
import Foundation
import OSLog
import Observation
import TaktCore
import TaktWorkspace
import ServiceManagement
import SwiftUI

@MainActor
@Observable class AppCoordinator {
  @ObservationIgnored let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "manager")

  /// How the Google Tasks mirror reaches the workspace. Set by `AppDelegate`
  /// once the workspace exists — the coordinator is built first, and the
  /// mirror is only ever used after both of them are up.
  @ObservationIgnored var workspaceStoreProvider: (() -> WorkspaceStore?)?

  /// The Google Tasks mirror. Lazy because it closes over `self`, and because
  /// an installation that never switches it on should never build it.
  /// Watches the events the Calendar integration created, so clearing one off
  /// the calendar completes the task it stood for.
  @ObservationIgnored private(set) lazy var googleCalendarCompletions =
    GoogleCalendarCompletionWatcher(
      plugin: integrations.googleCalendarPlugin,
      storeProvider: { [weak self] in self?.workspaceStoreProvider?() },
      isEnabled: { [weak self] in self?.integrations.googleCalendarIntegrationEnabled ?? false })

  @ObservationIgnored private(set) lazy var googleTasksMirror = GoogleTasksMirrorService(
    plugin: integrations.googleTasksPlugin,
    storeProvider: { [weak self] in self?.workspaceStoreProvider?() },
    isEnabled: { [weak self] in self?.integrations.googleTasksIntegrationEnabled ?? false })

  let repository: TaskRepository
  @ObservationIgnored let cacheInvalidationBus: CacheInvalidationBus

  let navigationState: NavigationState

  /// Transient one-line feedback under the list. Clears itself after three
  /// seconds.
  ///
  /// The generation token is what makes overlapping messages behave: each
  /// assignment starts its own timer, so without it the *first* message's timer
  /// would fire three seconds later and wipe whatever the second message had
  /// put there — a message set at t=2 vanishing at t=3 instead of t=5.
  var statusMessage: String? {
    didSet {
      guard statusMessage != nil else { return }
      statusMessageGeneration &+= 1
      let generation = statusMessageGeneration
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        guard self.statusMessageGeneration == generation else { return }
        self.statusMessage = nil
      }
    }
  }

  @ObservationIgnored private var statusMessageGeneration = 0

  var orderedRootTaskViews: [RootTaskView] { Self.storedRootTaskViewOrder }

  /// The legacy tab order, read from `UserDefaults` once.
  ///
  /// Nothing writes the key any more: the settings pane that reordered these
  /// tabs went with the tabs themselves, and the `View` menu lists
  /// `WorkspaceViewMode` instead. The read stays so an order saved by an
  /// earlier build still drives what is left of root-tab cycling — and since
  /// nothing changes it while the app runs, it is decoded once rather than on
  /// every keystroke that cycles a tab.
  static let storedRootTaskViewOrder: [RootTaskView] = {
    if let data = UserDefaults.standard.data(forKey: "rootTaskViewOrder"),
      let rawValues = try? JSONDecoder().decode([Int].self, from: data)
    {
      let views = rawValues.compactMap { RootTaskView(rawValue: $0) }
      // Ensure all cases are present
      let allCases = RootTaskView.allCases
      if Set(views) == Set(allCases) && views.count == allCases.count {
        return views
      }
    }
    return RootTaskView.allCases
  }()

  enum CarbonKey {
    static let space = 49
    static let b = 11
    static let d = 2
    static let f = 3
    static let n = 45
  }
  enum CarbonModifier {
    static let option = 0x0800
    static let shiftOption = 0x0A00
    /// Command + Shift + Option + Control (the conventional macOS Hyper key).
    static let hyper = 0x1B00
  }

  let startDates: StartDateManager

  let recurrence: RecurrenceManager

  let timer: TimerManager
  let taskListViewModel: TaskListViewModel

  var integrations: IntegrationCoordinator

  var quickEntry: QuickEntryManager

  let kanban: KanbanManager

  let focusSessionManager: FocusSessionManager

  let dailyLog: DailyLogManager
  /// Which completion celebration is active, and the flourish the popover
  /// overlay is currently showing.
  let celebration: CompletionCelebrationManager
  /// Which `ThemePlugin` the app renders through. Like `celebration`, it
  /// retains the registry because the choice is switchable at runtime.
  let theme: ThemeManager
  /// Popover chrome — the dock row, the resize strip, per-view heights.
  let popoverChrome: PopoverChromeManager
  /// What has failed this session. Nothing else in the app retains a failure
  /// for longer than the three seconds `statusMessage` lasts.
  let diagnosticsLog = DiagnosticsLog()

  let preferences: PreferencesManager
  var onboardingService: OnboardingService!

  @ObservationIgnored var isApplyingLaunchAtLoginChange = false
  /// Loading a saved key must not be treated as a user edit: otherwise the
  /// repository callback immediately writes it back to Keychain after reading
  /// it, defeating the single explicit-access guarantee.
  @ObservationIgnored var isLoadingStoredRemoteKey = false
  @ObservationIgnored let preferencesStore = PreferencesStore()
  let userPluginManager: UserPluginManager
  @ObservationIgnored lazy var commandExecutor = CommandExecutor(manager: self)
  @ObservationIgnored private(set) var lifecycle: LifecycleController!
  private(set) var undoService: UndoService!
  @ObservationIgnored private(set) var taskNavigationService: TaskNavigationService!
  @ObservationIgnored private(set) var taskMutationService: TaskMutationService!
  @ObservationIgnored private(set) var syncService: SyncService!
  /// Strong-held because `KanbanManager.dataSource` is `weak`. Bridges the
  /// kanban data-source protocol to repository/navigationState/taskListViewModel
  /// so AppCoordinator no longer has to conform to `KanbanTaskDataSource`.
  @ObservationIgnored private var kanbanDataSourceAdapter: KanbanTaskDataSourceAdapter!
  /// Strong-held because `IntegrationCoordinator.dataSource` is `weak`. Same
  /// role as `kanbanDataSourceAdapter` — bridges the protocol to
  /// repository/coordinator so AppCoordinator needn't conform.
  @ObservationIgnored private var integrationDataSourceAdapter: IntegrationDataSourceAdapter!
  /// Strong-held for the same reason as the two adapters above:
  /// `DailyLogManager.dataSource` is `weak`.
  @ObservationIgnored private var dailyLogDataSourceAdapter: DailyLogDataSourceAdapter!
  /// Owned here (rather than on `LifecycleController`) so `deinit`, which is
  /// nonisolated, can call `stop()` without hopping back onto the main actor.
  @ObservationIgnored let reachabilityMonitor = NetworkReachabilityMonitor()
  /// Where the Checkvist remote key is persisted.
  ///
  /// The key is password-equivalent, so release builds keep it in the keychain
  /// (matching `GoogleCalendarOAuthTokenStore`) rather than in the preferences
  /// plist, which is world-readable by anything running as the user. This was
  /// previously hardcoded to `false`, which not only stored the key in the clear
  /// but also actively migrated it *out* of the keychain on first launch.
  ///
  /// DEBUG builds keep the opt-out (defaulting to on, see `PreferencesManager`)
  /// because locally-signed dev builds get a new signing identity on each
  /// rebuild, which makes macOS prompt for keychain access every run.
  var usesKeychainStorage: Bool {
    #if DEBUG
      return !preferences.ignoreKeychainInDebug
    #else
      return true
    #endif
  }

  init(pluginRegistry: PluginRegistry) {
    let resolvedLocalTaskStore = LocalTaskStore()
    let resolvedCheckvistSyncPlugin =
      pluginRegistry.activeCheckvistSyncPlugin ?? NativeCheckvistSyncPlugin()
    let resolvedObsidianPlugin =
      pluginRegistry.activeObsidianPlugin
      ?? NativeObsidianIntegrationPlugin()
    let resolvedAFFiNEPlugin =
      pluginRegistry.activeAFFiNEPlugin
      ?? NativeAFFiNEIntegrationPlugin()
    // The fallbacks share one account for the same reason the registry's
    // plugins do: two Google integrations, one Google user.
    let fallbackGoogleAccount = GoogleAccount()
    let resolvedGoogleCalendarPlugin =
      pluginRegistry.activeGoogleCalendarPlugin
      ?? NativeGoogleCalendarIntegrationPlugin(account: fallbackGoogleAccount)
    let resolvedGoogleTasksPlugin =
      pluginRegistry.activeGoogleTasksPlugin
      ?? NativeGoogleTasksIntegrationPlugin(account: fallbackGoogleAccount)
    let resolvedMCPIntegrationPlugin =
      pluginRegistry.activeMCPIntegrationPlugin
      ?? NativeMCPIntegrationPlugin()
    let resolvedDailyLogPlugin =
      pluginRegistry.activeDailyLogPlugin
      ?? NativeDailyLogPlugin()

    self.userPluginManager = UserPluginManager(
      builtInPluginIdentifiers: [
        resolvedCheckvistSyncPlugin.pluginIdentifier,
        resolvedObsidianPlugin.pluginIdentifier,
        resolvedAFFiNEPlugin.pluginIdentifier,
        resolvedGoogleCalendarPlugin.pluginIdentifier,
        resolvedGoogleTasksPlugin.pluginIdentifier,
        resolvedMCPIntegrationPlugin.pluginIdentifier,
        resolvedDailyLogPlugin.pluginIdentifier,
      ]
    )
    self.preferences = PreferencesManager(preferencesStore: preferencesStore)

    // Mirrors `usesKeychainStorage`, which can't be read yet because `self`
    // isn't fully initialized here.
    #if DEBUG
      let useKeychainStorageAtInit = !preferencesStore.bool(.ignoreKeychainInDebug, default: true)
    #else
      let useKeychainStorageAtInit = true
    #endif
    // Returns "" in keychain mode. Reading (or migrating) a keychain item is
    // deliberately deferred until the user explicitly requests saved
    // credentials, so a stale code-signature ACL cannot prompt at launch.
    let initialRemoteKey = resolvedCheckvistSyncPlugin.startupRemoteKey(
      useKeychainStorageAtInit: useKeychainStorageAtInit)

    let cacheInvalidationBus = CacheInvalidationBus()
    self.cacheInvalidationBus = cacheInvalidationBus

    let navigationState = NavigationState(cacheInvalidationBus: cacheInvalidationBus)
    self.navigationState = navigationState

    // Create task repository with all task-related state
    let repository = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: resolvedCheckvistSyncPlugin,
      localTaskStore: resolvedLocalTaskStore,
      initialRemoteKey: initialRemoteKey,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.repository = repository

    let storedListId = preferencesStore.string(.checkvistListId)
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedOnboardingCompletedFlag = preferencesStore.optionalBool(.onboardingCompleted)
    let storedPluginSelectionOnboardingCompletedFlag = preferencesStore.optionalBool(
      .pluginSelectionOnboardingCompleted)

    self.kanban = KanbanManager(
      preferencesStore: preferencesStore,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.focusSessionManager = FocusSessionManager(
      preferencesStore: preferencesStore,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.dailyLog = DailyLogManager(
      preferencesStore: preferencesStore,
      plugin: resolvedDailyLogPlugin
    )
    self.popoverChrome = PopoverChromeManager(preferencesStore: preferencesStore)
    // OnboardingService will compute onboardingCompleted in its init.

    if storedPluginSelectionOnboardingCompletedFlag == nil {
      let storedObsidianIntegrationEnabled = preferencesStore.optionalBool(
        .obsidianIntegrationEnabled)
      let storedGoogleCalendarIntegrationEnabled = preferencesStore.optionalBool(
        .googleCalendarIntegrationEnabled)
      let storedMCPIntegrationEnabled = preferencesStore.optionalBool(.mcpIntegrationEnabled)
      let hasLegacyState =
        storedOnboardingCompletedFlag != nil
        || !storedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || storedObsidianIntegrationEnabled != nil
        || storedGoogleCalendarIntegrationEnabled != nil
        || storedMCPIntegrationEnabled != nil
      if hasLegacyState {
        preferencesStore.set(true, for: .pluginSelectionOnboardingCompleted)
      }
    }
    let timer = TimerManager(
      preferencesStore: preferencesStore,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.timer = timer
    self.startDates = StartDateManager(
      preferencesStore: preferencesStore,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.recurrence = RecurrenceManager(preferencesStore: preferencesStore)
    let quickEntry = QuickEntryManager(cacheInvalidationBus: cacheInvalidationBus)
    self.quickEntry = quickEntry
    // Retains the registry, unlike the other capabilities: the celebration
    // preset is switchable from Settings, so resolving it once here would pin
    // whatever was active at launch.
    let celebration = CompletionCelebrationManager(
      preferencesStore: preferencesStore,
      registry: pluginRegistry
    )
    self.celebration = celebration
    self.theme = ThemeManager(preferencesStore: preferencesStore, registry: pluginRegistry)
    // The other half of the cancellation contract. `runInline` has always
    // promised to return false when the user moved on mid-animation, and every
    // preset carried a `catch` for it, but nothing in the app ever cancelled
    // the work — so the promise was unreachable. This is what fires it.
    navigationState.onNavigationChanged = { [weak celebration] in
      celebration?.cancelInFlight()
    }
    let integrations = IntegrationCoordinator(
      preferencesStore: preferencesStore,
      obsidianPlugin: resolvedObsidianPlugin,
      affinePlugin: resolvedAFFiNEPlugin,
      googleCalendarPlugin: resolvedGoogleCalendarPlugin,
      googleTasksPlugin: resolvedGoogleTasksPlugin,
      mcpIntegrationPlugin: resolvedMCPIntegrationPlugin,
      initialListId: storedListId
    )
    self.integrations = integrations
    self.onboardingService = OnboardingService(
      preferencesStore: preferencesStore,
      repository: repository,
      integrations: integrations
    )

    self.taskListViewModel = TaskListViewModel(
      repository: repository,
      preferencesStore: preferences.preferencesStore
    )

    self.taskNavigationService = TaskNavigationService(
      coordinator: self,
      repository: repository,
      navigationState: navigationState
    )
    // Attached after `self` is fully initialised, like the other hosts.
    self.taskListViewModel.host = self
    self.taskMutationService = TaskMutationService(host: self, repository: repository)
    self.undoService = UndoService(performer: self.taskMutationService)
    self.syncService = SyncService(host: self, repository: repository)
    self.lifecycle = LifecycleController(
      coordinator: self,
      reachabilityMonitor: reachabilityMonitor
    )
    self.lifecycle.start()
    timer.onTick = { [weak self] taskId, elapsed in
      self?.focusSessionManager.handleTaskElapsed(elapsed, forTaskId: taskId)
    }
    focusSessionManager.onFocusBlockEnded = { [weak timer] in
      timer?.pauseTimer()
    }
    let kanbanDataSourceAdapter = KanbanTaskDataSourceAdapter(
      repository: repository,
      navigationState: navigationState,
      taskListViewModel: taskListViewModel
    )
    self.kanbanDataSourceAdapter = kanbanDataSourceAdapter
    kanban.dataSource = kanbanDataSourceAdapter
    let integrationDataSourceAdapter = IntegrationDataSourceAdapter(
      repository: repository,
      coordinator: self
    )
    self.integrationDataSourceAdapter = integrationDataSourceAdapter
    integrations.dataSource = integrationDataSourceAdapter
    let dailyLogDataSourceAdapter = DailyLogDataSourceAdapter(
      repository: repository,
      taskListViewModel: taskListViewModel,
      startDates: startDates
    )
    self.dailyLogDataSourceAdapter = dailyLogDataSourceAdapter
    dailyLog.dataSource = dailyLogDataSourceAdapter
    dailyLog.onError = { [weak self] message in
      self?.repository.errorMessage = message
    }
    // Ticking a daily used to be entirely silent — a separate funnel from task
    // completion, with no feedback of any kind. It gets the same haptic and the
    // same celebration now. No cancellation semantics: unlike a task close there
    // is no request to abandon, the tick has already landed locally.
    dailyLog.onDailyTicked = { [weak self] daily in
      guard let self else { return }
      NSHapticFeedbackManager.defaultPerformer.perform(
        .generic, performanceTime: .drawCompleted)
      let event = self.completionEvent(for: .daily(id: daily.id), alreadyRecorded: true)
      Task { @MainActor in
        _ = await self.celebration.runInline(event)
        self.celebration.presentFlourish(for: event)
      }
    }
    // A finished focus block is the one piece of "what I did today" that no
    // task mutation records, so it's captured here rather than through the
    // `TaskMutationHost` seam.
    focusSessionManager.onFocusSessionCompleted = { [weak self] taskId, seconds in
      guard let self else { return }
      let title = self.repository.tasks.first { $0.id == taskId }?.content ?? ""
      self.dailyLog.recordFocusSession(taskId: taskId, title: title, seconds: seconds)
    }
    Task { @MainActor [weak self] in
      // Deferred rather than run inline: the data source is only wired a few
      // lines above, and this must not be the thing that snapshots an empty
      // plan before the task list has loaded. Covers launching without ever
      // opening the popover; `showPopoverWindow` handles the rest.
      self?.dailyLog.refreshForToday()
    }
  }

  convenience init() {
    self.init(pluginRegistry: .nativeFirst())
  }

  deinit {
    reachabilityMonitor.stop()
  }
}

extension TaskMutationService: UndoActionPerforming {}

extension AppCoordinator {
  // MARK: - Recurrence convenience

  /// `setRecurrenceRule` is kept here (rather than on `RecurrenceManager`)
  /// because parse failure surfaces through `errorMessage`, which is a
  /// coordinator-level concern. The other two are pass-throughs that exist
  /// only to spare callers a `.recurrence.` hop and could be inlined later.
  func recurrenceRule(for task: CheckvistTask) -> RecurrenceRule? {
    recurrence.recurrenceRule(for: task)
  }

  @MainActor func setRecurrenceRule(_ raw: String, for task: CheckvistTask) {
    if let error = recurrence.setRecurrenceRule(raw, for: task) {
      repository.errorMessage = error
    }
  }

  @MainActor func clearRecurrenceRule(for task: CheckvistTask) {
    recurrence.clearRecurrenceRule(for: task)
  }
}

/// What is left here is the kanban adapter layer: `KanbanManager` decides
/// *what* a column move means in terms of content and due date — which needs
/// the app-only `KanbanColumn` type — and `TaskMutationService` performs it.
/// The performing half used to live here too, hand-rolling its own optimistic
/// and offline handling; it now goes through the same service as every other
/// mutation.
extension AppCoordinator {
  @MainActor func moveCurrentTaskToKanbanColumn(direction: Int) {
    guard let outcome = kanban.computeMoveCurrentTask(direction: direction) else { return }
    apply(outcome)
  }

  /// A drop on the board. `insertBefore` is the slot within the target column
  /// the card was released over, or nil for a move with no position — the
  /// keyboard's column change, which leaves ordering to the column's sort.
  ///
  /// The overlay is written *before* the condition change, because
  /// `moveTaskInColumn` reads the column's current contents to anchor the new
  /// order and the condition change is precisely what alters them. Writing it
  /// second would anchor to a column the card had already moved into.
  @MainActor func moveTask(
    id taskId: Int, toColumn targetColumn: KanbanColumn, insertBefore visibleIndex: Int? = nil
  ) {
    if let visibleIndex {
      kanban.moveTaskInColumn(
        taskId: taskId, in: targetColumn, toPositionBefore: visibleIndex)
    }
    // Nil means the card already satisfies the column — a reorder within it.
    // The overlay write above was the whole point of the drop, so that is not
    // a failure and nothing more is needed.
    guard let outcome = kanban.computeMoveTask(id: taskId, toColumn: targetColumn) else { return }
    apply(outcome)
  }

  @MainActor private func apply(_ outcome: KanbanMoveOutcome) {
    switch outcome {
    case .error(let msg):
      repository.errorMessage = msg
    case .update(let task, let newContent, let newDue):
      taskMutationService.applyOptimisticUpdate(
        task: task, content: newContent, due: newDue)
    case .place(let task, let urgency, let importance):
      repository.setUrgency(taskId: task.id, level: urgency)
      repository.setImportance(taskId: task.id, level: importance)
      statusMessage =
        "\(task.content.strippingTags) → "
        + MatrixGeometry.quadrant(urgency: urgency, importance: importance).title
    }
  }

  /// Creates a new root-level task pre-configured for the given kanban column.
  /// The column-to-content/due translation is kanban's; the insert is the
  /// mutation service's.
  @MainActor func addTaskInKanbanColumn(rawContent: String, column: KanbanColumn) {
    let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let (content, due) = kanban.contentAndDueForNewTask(rawContent: trimmed, in: column)
    taskMutationService.addRootTask(content: content, due: due)
  }

  // MARK: - Keychain / Debug / Command execution

  func handleCredentialStorageModeChanged() {
    let current = repository.remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if usesKeychainStorage {
      if !current.isEmpty {
        if let failure = repository.checkvistSyncPlugin.persistRemoteKey(
          current, useKeychainStorage: true)
        {
          repository.errorMessage = failure
        }
      } else {
        repository.hasAttemptedRemoteKeyBootstrap = false
        loadRemoteKeyFromKeychainIfNeeded()
      }
    } else {
      repository.checkvistSyncPlugin.persistRemoteKeyForDebugStorageMode(current)
    }
  }

  @MainActor func loadCredentialsFromKeychain() {
    repository.hasAttemptedRemoteKeyBootstrap = false
    loadRemoteKeyFromKeychainIfNeeded()
  }

  func loadRemoteKeyFromKeychainIfNeeded() {
    let currentState = RemoteKeyBootstrapState(
      remoteKey: repository.remoteKey,
      hasAttemptedBootstrap: repository.hasAttemptedRemoteKeyBootstrap
    )
    let nextState = RemoteKeyBootstrapPolicy.bootstrap(
      state: currentState,
      usesKeychainStorage: usesKeychainStorage,
      loadFromKeychain: { repository.checkvistSyncPlugin.loadRemoteKeyFromKeychain() }
    )
    isLoadingStoredRemoteKey = true
    repository.remoteKey = nextState.remoteKey
    isLoadingStoredRemoteKey = false
    repository.hasAttemptedRemoteKeyBootstrap = nextState.hasAttemptedBootstrap
  }

  @MainActor func toggleDebugKeychainStorageMode() {
    #if DEBUG
      preferences.ignoreKeychainInDebug.toggle()
      repository.errorMessage =
        preferences.ignoreKeychainInDebug
        ? "Dev mode: keychain disabled (no password prompts)."
        : "Dev mode: keychain enabled."
    #endif
  }

  @MainActor func resetOnboardingForDebug() {
    #if DEBUG
      repository.checkvistSyncPlugin.clearAuthentication()
      repository.errorMessage = nil
      let resetState = OnboardingResetPolicy.reset(
        OnboardingResetState(
          remoteKey: repository.remoteKey,
          onboardingCompleted: onboardingService.onboardingCompleted,
          username: repository.username,
          listId: repository.listId,
          availableListsCount: repository.availableLists.count,
          tasksCount: repository.tasks.count,
          currentParentId: navigationState.currentParentId,
          currentSiblingIndex: navigationState.currentSiblingIndex
        ))

      onboardingService.onboardingCompleted = resetState.onboardingCompleted
      repository.username = resetState.username
      repository.listId = resetState.listId
      repository.availableLists = []
      repository.tasks = []
      navigationState.currentParentId = resetState.currentParentId
      navigationState.currentSiblingIndex = resetState.currentSiblingIndex

      preferencesStore.remove(.checkvistUsername)
      preferencesStore.remove(.checkvistListId)
      preferencesStore.remove(.onboardingCompleted)
      preferencesStore.remove(.pluginSelectionOnboardingCompleted)
      preferencesStore.remove(.dismissedOnboardingDialogs)
    #endif
  }

  @MainActor func executeCommandInput(_ input: String) async {
    let parsed = CommandEngine.parse(input)
    logger.log("Executing command: \(input, privacy: .public)")
    await commandExecutor.execute(parsed: parsed)
    if case .unknown(let raw) = parsed {
      logger.error("Unknown command: \(raw, privacy: .public)")
    }
  }

  /// Opens the calendar used by Checkvist's `dd`-style due-date interaction.
  /// An existing due date is highlighted, so changing one starts from the date
  /// the task already has instead of jumping back to today.
  func openDueDatePicker() {
    guard let task = taskListViewModel.currentTask else {
      repository.errorMessage = "No task selected."
      return
    }
    repository.errorMessage = nil
    quickEntry.beginDueDatePicker(forTaskId: task.id, initialDate: task.dueDate)
  }

  /// Applies (or clears) the calendar's choice to the task that opened it, then
  /// closes the picker immediately while sync runs.
  func submitDueDatePicker(clearDueDate: Bool = false) {
    guard let taskId = quickEntry.dueDatePickerTaskId,
      let task = repository.tasks.first(where: { $0.id == taskId })
    else {
      quickEntry.dismissDueDatePicker()
      repository.errorMessage = "No task selected."
      return
    }
    let due = clearDueDate ? "" : quickEntry.dueDatePickerDueString()
    quickEntry.dismissDueDatePicker()
    Task { await taskMutationService.updateTask(task: task, due: due) }
  }

  var activePluginSettingsPages: [any PluginSettingsPageProviding] {
    [
      repository.checkvistSyncPlugin as any Plugin,
      integrations.obsidianPlugin as any Plugin,
      integrations.affinePlugin as any Plugin,
      integrations.googleCalendarPlugin as any Plugin,
      integrations.googleTasksPlugin as any Plugin,
      integrations.mcpIntegrationPlugin as any Plugin,
      dailyLog.plugin as any Plugin,
      // Only the *active* theme, not every registered one: themes are a menu,
      // and listing both would put two cards in the sidebar for one setting.
      // The card's page picks between them.
      theme.activeThemePlugin as any Plugin,
    ].compactMap { $0 as? any PluginSettingsPageProviding }
  }
}
