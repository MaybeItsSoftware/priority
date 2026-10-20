import Foundation
import OSLog
import TaktCore
import TaktWorkspace

/// The tabs of the right dock: what helps you finish the task in front of
/// you. The left dock is for getting about and the bottom dock for keeping
/// track; this one is about the work itself.
enum WorkspaceDockTab: String, CaseIterable, Identifiable {
  case inspector
  case conditions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .inspector: "Inspector"
    case .conditions: "Conditions"
    }
  }

  var symbolName: String {
    switch self {
    case .inspector: "sidebar.trailing"
    case .conditions: "location"
    }
  }

  /// The keyboard region the tab is.
  var area: WorkspaceFocusArea {
    switch self {
    case .inspector: .inspector
    case .conditions: .conditions
    }
  }

  /// The catalogue entry that toggles the dock onto this tab.
  var command: WorkspaceCommandID {
    switch self {
    case .inspector: .windowToggleInspectorPane
    case .conditions: .focusSetAvailable
    }
  }

  init?(area: WorkspaceFocusArea) {
    switch area {
    case .inspector: self = .inspector
    case .conditions: self = .conditions
    case .sidebar, .tasks, .done, .timeline: return nil
    }
  }
}

/// The tabs of the bottom dock: keeping track of what has been done. The
/// progress graph, the done rail and the day's timeline all look back, and
/// all of them read better wide than tall.
enum WorkspaceBottomDockTab: String, CaseIterable, Identifiable {
  case progress
  case done
  case timeline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .progress: "Progress"
    case .done: "Done"
    case .timeline: "Timeline"
    }
  }

  var symbolName: String {
    switch self {
    case .progress: "chart.bar.xaxis"
    case .done: "checkmark.square"
    case .timeline: "clock"
    }
  }

  /// The keyboard region the tab is. The graph has none: there is nothing in
  /// it to type into or step through.
  var area: WorkspaceFocusArea? {
    switch self {
    case .progress: nil
    case .done: .done
    case .timeline: .timeline
    }
  }

  /// The catalogue entry that toggles the dock onto this tab.
  var command: WorkspaceCommandID {
    switch self {
    case .progress: .windowToggleProgressDock
    case .done: .windowToggleDoneRail
    case .timeline: .goTimeline
    }
  }

  init?(area: WorkspaceFocusArea) {
    switch area {
    case .done: self = .done
    case .timeline: self = .timeline
    case .sidebar, .tasks, .inspector, .conditions: return nil
    }
  }
}

/// The right dock: the inspector and the conditions as tabs of one resizable
/// column.
///
/// They were two columns, each with its own idea of when to be on screen. The
/// inspector closed itself on about fifteen kinds of navigation — choosing a
/// list, entering a task, undoing, an external write — so the pane you had
/// opened on purpose kept going away under you, and the done rail took a third
/// column beside it. One dock, one width, one visibility, all persisted, and it
/// only goes away when you put it away. The done rail and the timeline were
/// tabs here too, until they moved to the bottom dock: a timeline squeezed
/// into a column wrapped its figures a letter at a time.
@MainActor
extension WorkspaceViewModel {
  var isInspectorVisible: Bool { isRightDockVisible && rightDockTab == .inspector }
  var isDoneRailVisible: Bool { isBottomDockVisible && bottomDockTab == .done }
  /// The timeline is a tab of the bottom dock. Kept under its old name
  /// because the title strip, the menu and the keys all ask it.
  var showsTimelineScreen: Bool { isBottomDockVisible && bottomDockTab == .timeline }

  /// Shows the dock on `tab`. Does not move the keyboard; the callers that
  /// mean to do that say so.
  func showRightDock(_ tab: WorkspaceDockTab) {
    if rightDockTab != tab { rightDockTab = tab }
    if !isRightDockVisible { isRightDockVisible = true }
  }

  /// Puts the dock away, handing the keyboard back to the tasks if it had it.
  func hideRightDock() {
    isRightDockVisible = false
    if WorkspaceDockTab(area: keyboardFocusArea) != nil {
      requestKeyboardFocus(.tasks)
    }
  }

  /// `r` and the status bar's dock button: on or off, keeping whichever tab
  /// it was on. Opening it hands it the keyboard, so the dock is worked from
  /// the keys like every other pane; `r` again, from anywhere, puts it away.
  /// ⌘R: open-but-elsewhere brings the keyboard over before a second press
  /// puts the dock away, the way ⌘B does for the sidebar.
  func toggleRightDock() {
    if isRightDockVisible && keyboardFocusArea != rightDockTab.area {
      requestKeyboardFocus(rightDockTab.area, onTitle: false)
    } else if isRightDockVisible {
      hideRightDock()
    } else {
      toggleDockTab(rightDockTab, onTitle: false)
    }
  }

  /// For a tab, one key, three states, the way an editor's panel toggle
  /// behaves: hidden (or on the other tab) opens it on this one and takes the
  /// keyboard, open-but-elsewhere brings the keyboard over, and
  /// open-and-focused puts it away. A toggle that only shows and hides is a
  /// pane you have to reach for separately, which is a pane you read once.
  ///
  /// The inspector only takes the keyboard when there is a task to inspect;
  /// with none it opens on its empty state and the keys stay on the tasks.
  func toggleDockTab(_ tab: WorkspaceDockTab, onTitle: Bool = true) {
    let isShowing = isRightDockVisible && rightDockTab == tab
    // The inspector hides from anywhere: `i` on a task is "show me this" and
    // pressed again "enough", without first walking into the pane.
    if isShowing && (tab == .inspector || keyboardFocusArea == tab.area) {
      hideRightDock()
      return
    }
    showRightDock(tab)
    if tab == .inspector {
      if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
      if selectedTask == nil { return }
    }
    requestKeyboardFocus(tab.area, onTitle: onTitle)
  }

  func toggleInspector() { toggleDockTab(.inspector) }

  /// ⌘{ and ⌘} (or `[` and `]`) while a dock has the keyboard: the tab beside
  /// this one in the same dock, round the end, with the keyboard brought
  /// along. Unlike `toggleDockTab` it never puts the dock away, and the
  /// inspector takes the keyboard even with nothing selected — its empty
  /// state is a stop on the way to the next tab, not somewhere to be thrown
  /// back to the tasks from. In the bottom dock it steps between the done
  /// rail and the timeline; the graph has no keyboard to bring along.
  func cycleRightDockTab(by offset: Int) {
    if WorkspaceBottomDockTab(area: keyboardFocusArea) != nil {
      let areas = WorkspaceBottomDockTab.allCases.compactMap(\.area)
      let current = areas.firstIndex(of: keyboardFocusArea) ?? 0
      requestKeyboardFocus(areas[(current + offset % areas.count + areas.count) % areas.count])
      return
    }
    let tabs = WorkspaceDockTab.allCases
    let current = tabs.firstIndex(of: rightDockTab) ?? 0
    let next = tabs[(current + offset % tabs.count + tabs.count) % tabs.count]
    requestKeyboardFocus(next.area)
  }

  /// Shows the bottom dock on `tab`, loading what the tab needs. Does not
  /// move the keyboard.
  func showBottomDock(_ tab: WorkspaceBottomDockTab) {
    let wasShowingDone = isDoneRailVisible
    if bottomDockTab != tab { bottomDockTab = tab }
    if !isBottomDockVisible { isBottomDockVisible = true }
    if tab == .done && !wasShowingDone { reloadCompleted() }
    if tab == .timeline {
      focusHistoryDate = min(focusHistoryDate, .now)
      reloadFocus()
    }
  }

  /// Puts the bottom dock away, handing the keyboard back to the tasks if it
  /// had it.
  func hideBottomDock() {
    isBottomDockVisible = false
    completedTasks = []
    completedTasksKey = nil
    if WorkspaceBottomDockTab(area: keyboardFocusArea) != nil {
      requestKeyboardFocus(.tasks)
    }
  }

  /// ⌘J, Zed's toggle bottom dock, on whichever tab it was on. On the done
  /// rail or the timeline it works as `r` does for the right dock: opening
  /// takes the keyboard, open-but-elsewhere brings it over, and again puts
  /// the dock away. The graph never takes the keyboard, so there it is a
  /// plain show and hide.
  func toggleBottomDock() {
    let area = bottomDockTab.area
    if isBottomDockVisible, let area, keyboardFocusArea != area {
      requestKeyboardFocus(area)
    } else if isBottomDockVisible {
      hideBottomDock()
    } else {
      showBottomDock(bottomDockTab)
      if let area { requestKeyboardFocus(area) }
    }
  }

  /// The done rail's and the timeline's keys: the three states of
  /// `toggleDockTab`, in the bottom dock. The progress tab has no keyboard,
  /// so its key shows it or, already showing, puts the dock away.
  func toggleBottomDockTab(_ tab: WorkspaceBottomDockTab) {
    let isShowing = isBottomDockVisible && bottomDockTab == tab
    guard let area = tab.area else {
      if isShowing { hideBottomDock() } else { showBottomDock(tab) }
      return
    }
    if isShowing && keyboardFocusArea == area {
      hideBottomDock()
      return
    }
    showBottomDock(tab)
    requestKeyboardFocus(area)
  }

  /// ⌥⌘Y, Zed's close all docks: the left, the right and the bottom, with the
  /// keyboard handed back to the tasks from whichever of them had it.
  func closeAllDocks() {
    if isRightDockVisible { hideRightDock() }
    if isSidebarVisible { hideLeftDock() }
    if isBottomDockVisible { hideBottomDock() }
  }

  /// The progress graph for the period, read from the store. Empty without
  /// one, and on a read that fails — a graph is not worth an error message.
  func loadProgressSeries() -> TaskProgressSeries {
    let interval = TaskProgressSeries.interval(for: progressPeriod)
    guard let store,
      let completions = try? store.taskCompletions(in: interval),
      let creations = try? store.taskCreations(in: interval)
    else { return TaskProgressSeries.build(period: progressPeriod, completions: [], creations: []) }
    return TaskProgressSeries.build(period: progressPeriod, completions: completions, creations: creations)
  }
  func toggleDoneRail() { toggleBottomDockTab(.done) }
}

/// The tabs of the left dock: the lists, and the agent panel beside them.
enum WorkspaceLeftDockTab: String, CaseIterable, Identifiable {
  case lists
  case agent

  var id: String { rawValue }

  var title: String {
    switch self {
    case .lists: "Lists"
    case .agent: "Agent"
    }
  }

  var symbolName: String {
    switch self {
    case .lists: "sidebar.leading"
    case .agent: "sparkles"
    }
  }

  /// The catalogue entry that toggles the dock onto this tab.
  var command: WorkspaceCommandID {
    switch self {
    case .lists: .windowToggleSidebar
    case .agent: .windowToggleAgentPanel
    }
  }
}

/// The left dock: the sidebar and the agent panel as two tabs of one column,
/// the way the right dock holds the inspector and the done rail.
///
/// Its visibility is still `isSidebarVisible` — the setting people already
/// have — and its width the sidebar's. The sidebar's keyboard region only
/// exists while the Lists tab is showing, so anything that asks for it turns
/// the dock to that tab first.
@MainActor
extension WorkspaceViewModel {
  var isAgentPanelVisible: Bool { isSidebarVisible && leftDockTab == .agent }
  var isListsPaneVisible: Bool { isSidebarVisible && leftDockTab == .lists }

  func showLeftDock(_ tab: WorkspaceLeftDockTab) {
    if leftDockTab != tab {
      if tab == .agent && keyboardFocusArea == .sidebar { requestKeyboardFocus(.tasks) }
      leftDockTab = tab
    }
    if !isSidebarVisible { isSidebarVisible = true }
  }

  /// Puts the dock away, handing the keyboard back to the tasks if the dock
  /// had it. A pending approval stays pending: hiding the panel answers
  /// nothing, and the change it asks about does not run until someone clicks.
  func hideLeftDock() {
    isSidebarVisible = false
    if keyboardFocusArea == .sidebar || agentHoldsKeyboard {
      agentHoldsKeyboard = false
      requestKeyboardFocus(.tasks)
    }
  }

  /// One key, three states, like the done rail's: hidden (or on the lists)
  /// opens the agent and puts the caret in its field, open-but-elsewhere
  /// brings the caret over, and open with the caret in it puts it away.
  func toggleAgentPanel() {
    if isAgentPanelVisible && agentHoldsKeyboard {
      hideLeftDock()
      return
    }
    showLeftDock(.agent)
    focusAgentInput()
  }

  func focusAgentInput() {
    desktopShortcutSequence.reset()
    agentInputFocusRequest += 1
  }

  /// The agent's message, with a line saying where the user is so "this
  /// list" and "this task" mean something. The standing instructions for
  /// there, and the tasks on screen, go with it whenever they differ from the
  /// last ones the thread was sent.
  func sendAgentMessage(_ text: String) {
    // An account edit still waiting out its pause goes in first, so the
    // block and the agent's own reads agree.
    agentInstructions.saveAccount()
    // Set here rather than at init: no approval can be asked for before a
    // message has been sent.
    agent.currentValues = { [weak self] tool, input in self?.agentCurrentValues(tool: tool, input: input) ?? [:] }
    let task = selectedTask
    let list = isEverythingSelected ? nil : selectedList ?? task.flatMap { task in lists.first { $0.id == task.listId } }
    agent.send(
      text,
      context: AgentSystemPrompt.context(
        listName: list?.name,
        listID: list?.id,
        taskTitle: task?.title,
        taskID: task?.id),
      blocks: [
        AgentContextBlock(
          key: "instructions",
          text: AgentStandingInstructions.block(agentInstructionScopes),
          cleared: AgentStandingInstructions.cleared),
        AgentContextBlock(
          key: "screen",
          text: AgentSystemPrompt.visibleTasks(visibleNavigationTasks.map { ($0.id, $0.title) }),
          cleared: AgentSystemPrompt.noVisibleTasks),
      ])
  }

  /// The list whose instructions apply: the selected one, or the selected
  /// task's. None in Everything, a filter list or a folder, whose tasks come
  /// from many lists.
  private var agentContextList: TaskList? {
    guard !isEverythingSelected, selectedFolderID == nil else { return nil }
    return selectedList ?? selectedTask.flatMap { task in lists.first { $0.id == task.listId } }
  }

  /// Points the standing instructions at the store, after copying in what
  /// this Mac kept in its preferences before they moved into the workspace.
  /// A copy that fails is logged and tried again next launch; the
  /// instructions still work from the workspace meanwhile.
  func attachAgentInstructions() {
    guard let store else { return }
    do {
      try store.migrateAgentInstructionPreferences(from: .standard)
    } catch {
      Logger(subsystem: AppIdentity.bundleIdentifier, category: "WorkspaceAgentInstructions")
        .error("Copying the agent instructions out of preferences failed: \(error.localizedDescription)")
    }
    agentInstructions.store = store
    agentInstructions.perform = { [weak self] work in self?.perform(mirrors: false, work) }
  }

  /// Every scope whose instructions apply where the user is, written or not,
  /// in the order they are sent: the account, the folders enclosing the list
  /// (or the folder in scope) from the outermost in, then the list. In
  /// Everything or a filter list, the account alone.
  var agentInstructionScopes: [AgentInstructionScope] {
    let list = agentContextList
    return agentInstructionScopes(
      list: list, innermostFolder: list != nil ? list?.folderId : isEverythingSelected ? nil : selectedFolderID)
  }

  /// The scopes for one list, wherever the user is: the quick ask's, which is
  /// about a task rather than about the screen.
  func agentInstructionScopes(forListID listID: String) -> [AgentInstructionScope] {
    let list = (lists + archivedLists).first { $0.id == listID }
    return agentInstructionScopes(list: list, innermostFolder: list?.folderId)
  }

  private func agentInstructionScopes(list: TaskList?, innermostFolder: String?) -> [AgentInstructionScope] {
    var scopes = [AgentInstructionScope(kind: .account, id: nil, name: "Account", text: agentInstructions.account)]
    let chain = AgentStandingInstructions.folderChain(from: innermostFolder) { id in
      folders.first { $0.id == id }?.parentFolderId
    }
    for id in chain {
      guard let folder = folders.first(where: { $0.id == id }) else { continue }
      scopes.append(
        AgentInstructionScope(kind: .folder, id: id, name: folder.name, text: agentInstructions.folder(id)))
    }
    if let list {
      scopes.append(
        AgentInstructionScope(kind: .list, id: list.id, name: list.name, text: agentInstructions.list(list.id)))
    }
    return scopes
  }

  /// Opens the place a scope's instructions are written: the Agent settings
  /// page for the account, the settings sheet for a folder or a list.
  func editAgentInstructions(_ scope: AgentInstructionScope) {
    switch scope.kind {
    case .account:
      AppDelegate.shared.menuSettings(pane: .agent)
    case .folder:
      if let folder = folders.first(where: { $0.id == scope.id }) { showSettings(for: folder) }
    case .list:
      if let list = lists.first(where: { $0.id == scope.id }) { showSettings(for: list) }
    }
  }

  /// A workspace id as the approval card should say it: a list's or a
  /// folder's name, or a task's title. Nil for an id this workspace does not
  /// know — a Checkvist id, or something the assistant made up — which the
  /// card then shows as it is.
  func agentDisplayName(for id: String) -> String? {
    if let list = lists.first(where: { $0.id == id }) ?? archivedLists.first(where: { $0.id == id }) {
      return list.name
    }
    if let folder = folders.first(where: { $0.id == id }) { return folder.name }
    if let task = taskCache[id] { return task.title }
    return (try? store?.task(id: id))??.title
  }

  /// What a change to a workspace task would replace, by input key, in the
  /// words the approval card uses, so the card can show "Milk" struck through
  /// over "Oat milk" rather than only the new value. Empty for any other
  /// tool, or a task this workspace cannot find.
  func agentCurrentValues(tool: String, input: JSONValue) -> [String: String] {
    let bare = AgentToolPolicy.priorityToolName(tool)
    if bare == "agent_instructions_set" {
      // The rows as last loaded, not read again: with changes applied
      // without asking, the tool may already have run by the time this is
      // asked, and the workspace would say "after".
      let id = input.objectValue?["id"]?.stringValue ?? ""
      let text: String =
        switch input.objectValue?["scope"]?.stringValue {
        case "account": agentInstructions.texts.account
        case "folder": agentInstructions.folder(id)
        case "list": agentInstructions.list(id)
        default: ""
        }
      return text.isEmpty ? [:] : ["text": text]
    }
    guard bare == "workspace_task_update" || bare == "workspace_task_move",
      let id = input.objectValue?["task_id"]?.stringValue,
      let task = task(withID: id)
    else { return [:] }
    let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    var values = [
      "title": task.title,
      "notes": notes.isEmpty ? "None" : notes,
      "status": task.status.rawValue,
      "kind": (task.itemKind ?? .task).rawValue,
      "parent_task_id": task.parentTaskId.map { self.task(withID: $0)?.title ?? $0 } ?? "Top level",
    ]
    values["list_id"] = (lists + archivedLists).first { $0.id == task.listId }?.name
    // The schedule, priority and estimate in the card's own words, so
    // "Fri 17 Oct" is struck through beside "Mon 20 Oct" rather than beside
    // a stored timestamp. A due day is the planning's; a due time the task's.
    let planning = taskPlanningByID[task.id]
    let due: JSONValue =
      if let day = planning?.dueDate { .string(day) } else if let at = task.dueAt {
        .string(AgentToolSummary.stamp(at))
      } else { .null }
    let current: [String: JSONValue] = [
      "due": due,
      "start": planning?.startAt.map { .string(AgentToolSummary.stamp($0)) } ?? .null,
      "priority": taskPriorities[task.id].map { .int($0) } ?? .null,
      "estimate_minutes": task.estimateSeconds.map { .int(($0 + 30) / 60) } ?? .null,
    ]
    for (key, value) in current {
      values[key] = AgentToolSummary.words(for: key, value: value) ?? "None"
    }
    return values
  }

  /// What Undo on an agent card's change would do, or nil when the card has
  /// no step or the workspace cannot say.
  func agentUndoPlan(for step: String) -> WorkspaceStepUndoPlan? {
    try? store?.stepUndoPlan(step)
  }

  /// Takes back exactly the change an agent card shows — its "MCP: …" undo
  /// step — and, only when a later step built on it, those later steps too.
  /// The assistant is told with the next message.
  func undoAgentChange(_ itemID: UUID) {
    guard let store, let step = agentUndoStep(itemID) else { return }
    taskEditor.flush()
    var labels: [String] = []
    perform {
      labels = try store.undoStep(step)
      try load()
    }
    if !labels.isEmpty { agentSession(holding: itemID)?.markUndone(itemID, labels: labels) }
  }

  /// Puts back a change taken back from its card.
  func redoAgentChange(_ itemID: UUID) {
    guard let store, let step = agentUndoStep(itemID) else { return }
    taskEditor.flush()
    var redone = false
    perform {
      redone = try store.redoStep(step)
      try load()
    }
    if redone { agentSession(holding: itemID)?.markUndone(itemID, labels: nil) }
  }

  private func agentUndoStep(_ itemID: UUID) -> String? {
    guard let item = agentSession(holding: itemID)?.items.first(where: { $0.id == itemID }),
      case .write(let approval) = item.entry
    else { return nil }
    return approval.undoStep
  }

  /// After a turn, look for its writes now rather than on the next poll.
  /// The poll would find them within a second anyway; this only saves the
  /// wait between the assistant saying "done" and the row appearing.
  func agentTurnFinished() {
    checkForExternalWrites()
  }
}
