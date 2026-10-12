import Foundation
import TaktCore
import TaktWorkspace

/// The tabs of the right dock.
enum WorkspaceDockTab: String, CaseIterable, Identifiable {
  case inspector
  case done
  case timeline
  case conditions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .inspector: "Inspector"
    case .done: "Done"
    case .timeline: "Timeline"
    case .conditions: "Conditions"
    }
  }

  var symbolName: String {
    switch self {
    case .inspector: "sidebar.trailing"
    case .done: "checkmark.circle"
    case .timeline: "clock"
    case .conditions: "location"
    }
  }

  /// The keyboard region the tab is.
  var area: WorkspaceFocusArea {
    switch self {
    case .inspector: .inspector
    case .done: .done
    case .timeline: .timeline
    case .conditions: .conditions
    }
  }

  /// The catalogue entry that toggles the dock onto this tab.
  var command: WorkspaceCommandID {
    switch self {
    case .inspector: .windowToggleInspectorPane
    case .done: .windowToggleDoneRail
    case .timeline: .goTimeline
    case .conditions: .focusSetAvailable
    }
  }

  init?(area: WorkspaceFocusArea) {
    switch area {
    case .inspector: self = .inspector
    case .done: self = .done
    case .timeline: self = .timeline
    case .conditions: self = .conditions
    case .sidebar, .tasks: return nil
    }
  }
}

/// The right dock: the inspector, the done rail, the timeline and the
/// conditions as tabs of one resizable column.
///
/// They were two columns, each with its own idea of when to be on screen. The
/// inspector closed itself on about fifteen kinds of navigation — choosing a
/// list, entering a task, undoing, an external write — so the pane you had
/// opened on purpose kept going away under you, and the done rail took a third
/// column beside it. One dock, one width, one visibility, all persisted, and it
/// only goes away when you put it away.
@MainActor
extension WorkspaceViewModel {
  var isInspectorVisible: Bool { isRightDockVisible && rightDockTab == .inspector }
  var isDoneRailVisible: Bool { isRightDockVisible && rightDockTab == .done }
  /// The timeline is the dock's third tab. Kept under its old name because
  /// the title strip, the menu and the keys all ask it.
  var showsTimelineScreen: Bool { isRightDockVisible && rightDockTab == .timeline }

  /// Shows the dock on `tab`, loading what the tab needs. Does not move the
  /// keyboard; the callers that mean to do that say so.
  func showRightDock(_ tab: WorkspaceDockTab) {
    let wasShowingDone = isDoneRailVisible
    if rightDockTab != tab { rightDockTab = tab }
    if !isRightDockVisible { isRightDockVisible = true }
    if tab == .done && !wasShowingDone { reloadCompleted() }
    if tab == .timeline {
      focusHistoryDate = min(focusHistoryDate, .now)
      reloadFocus()
    }
  }

  /// Puts the dock away, handing the keyboard back to the tasks if it had it.
  func hideRightDock() {
    isRightDockVisible = false
    completedTasks = []
    completedTasksKey = nil
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

  /// For the rail, one key, three states, the way an editor's panel toggle behaves: hidden
  /// (or on the other tab) opens it on this one and takes the keyboard,
  /// open-but-elsewhere brings the keyboard over, and open-and-focused puts it
  /// away. A toggle that only shows and hides is a pane you have to reach for
  /// separately, which is a pane you read once.
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

  /// ⌘{ and ⌘} (or `[` and `]`) while the dock has the keyboard: the tab
  /// beside this one, round the end, with the keyboard brought along. Unlike
  /// `toggleDockTab` it never puts the dock away, and the inspector takes the
  /// keyboard even with nothing selected — its empty state is a stop on the
  /// way to the next tab, not somewhere to be thrown back to the tasks from.
  func cycleRightDockTab(by offset: Int) {
    let tabs = WorkspaceDockTab.allCases
    let current = tabs.firstIndex(of: rightDockTab) ?? 0
    let next = tabs[(current + offset % tabs.count + tabs.count) % tabs.count]
    requestKeyboardFocus(next.area)
  }

  /// The bottom dock has one thing in it and nothing to type into, so it
  /// never takes the keyboard: the key shows it and hides it.
  func toggleBottomDock() { isBottomDockVisible.toggle() }

  /// ⌥⌘Y, Zed's close all docks: the left, the right and the bottom, with the
  /// keyboard handed back to the tasks from whichever of them had it.
  func closeAllDocks() {
    if isRightDockVisible { hideRightDock() }
    if isSidebarVisible { hideLeftDock() }
    isBottomDockVisible = false
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
  func toggleDoneRail() { toggleDockTab(.done) }
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

  /// Every scope whose instructions apply where the user is, written or not,
  /// in the order they are sent: the account, the folders enclosing the list
  /// (or the folder in scope) from the outermost in, then the list. In
  /// Everything or a filter list, the account alone.
  var agentInstructionScopes: [AgentInstructionScope] {
    var scopes = [AgentInstructionScope(kind: .account, id: nil, name: "Account", text: agentInstructions.account)]
    let list = agentContextList
    let innermostFolder = list != nil ? list?.folderId : isEverythingSelected ? nil : selectedFolderID
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
    return values
  }

  /// After a turn, look for its writes now rather than on the next poll.
  /// The poll would find them within a second anyway; this only saves the
  /// wait between the assistant saying "done" and the row appearing.
  func agentTurnFinished() {
    checkForExternalWrites()
  }
}
