import Foundation
import TaktCore
import TaktWorkspace

/// The tabs of the right dock.
enum WorkspaceDockTab: String, CaseIterable, Identifiable {
  case inspector
  case done
  case timeline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .inspector: "Inspector"
    case .done: "Done"
    case .timeline: "Timeline"
    }
  }

  var symbolName: String {
    switch self {
    case .inspector: "sidebar.trailing"
    case .done: "checkmark.circle"
    case .timeline: "clock"
    }
  }

  /// The keyboard region the tab is.
  var area: WorkspaceFocusArea {
    switch self {
    case .inspector: .inspector
    case .done: .done
    case .timeline: .timeline
    }
  }

  /// The catalogue entry that toggles the dock onto this tab.
  var command: WorkspaceCommandID {
    switch self {
    case .inspector: .windowToggleInspectorPane
    case .done: .windowToggleDoneRail
    case .timeline: .goTimeline
    }
  }

  init?(area: WorkspaceFocusArea) {
    switch area {
    case .inspector: self = .inspector
    case .done: self = .done
    case .timeline: self = .timeline
    case .sidebar, .tasks: return nil
    }
  }
}

/// The right dock: the inspector and the done rail as two tabs of one
/// resizable column.
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
  /// the toolbar, the menu and the keys all ask it.
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
    if keyboardFocusArea == .inspector || keyboardFocusArea == .done || keyboardFocusArea == .timeline {
      requestKeyboardFocus(.tasks)
    }
  }

  /// `r` and the status bar's dock button: on or off, keeping whichever tab
  /// it was on. Opening it hands it the keyboard, so the dock is worked from
  /// the keys like every other pane; `r` again, from anywhere, puts it away.
  func toggleRightDock() {
    if isRightDockVisible { hideRightDock() } else { toggleDockTab(rightDockTab) }
  }

  /// For the rail, one key, three states, the way an editor's panel toggle behaves: hidden
  /// (or on the other tab) opens it on this one and takes the keyboard,
  /// open-but-elsewhere brings the keyboard over, and open-and-focused puts it
  /// away. A toggle that only shows and hides is a pane you have to reach for
  /// separately, which is a pane you read once.
  ///
  /// The inspector only takes the keyboard when there is a task to inspect;
  /// with none it opens on its empty state and the keys stay on the tasks.
  func toggleDockTab(_ tab: WorkspaceDockTab) {
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
    requestKeyboardFocus(tab.area)
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

  /// The agent's message, with a line saying what is on screen so "this
  /// list" and "this task" mean something.
  func sendAgentMessage(_ text: String) {
    let task = selectedTask
    let list = selectedList ?? task.flatMap { task in lists.first { $0.id == task.listId } }
    agent.send(
      text,
      context: AgentSystemPrompt.context(
        listName: isEverythingSelected ? nil : list?.name,
        listID: isEverythingSelected ? nil : list?.id,
        taskTitle: task?.title,
        taskID: task?.id))
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

  /// After a turn, look for its writes now rather than on the next poll.
  /// The poll would find them within a second anyway; this only saves the
  /// wait between the assistant saying "done" and the row appearing.
  func agentTurnFinished() {
    checkForExternalWrites()
  }
}
