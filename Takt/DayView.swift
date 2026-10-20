import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// Which mount of the day list this is.
///
/// The day has exactly one presentation and two places it can appear: summoned
/// over another app, and as the main window's home. They differ in their
/// chrome — a summoned panel needs a way out and a way into the window; the
/// pane needs neither — and in nothing else, because a day that looked
/// different depending on where you read it would be two days.
enum DaySurface {
  case panel
  case window

  var isPanel: Bool { self == .panel }
}

/// The day as a list of cards: what is on today, what it should cost, what it
/// has cost, and the one you are on carrying its own controls.
///
/// It deliberately does *not* put you through the focus screen's questions —
/// an available-time window, an estimate to commit to before you may begin.
/// That ceremony belongs to deciding what a day should be. Conditions get one
/// quiet line on the panel, since they decide what is on offer at all. This is
/// the surface you work a day from, so a task is a row you press play on, and
/// the row you are on grows a pause, a skip and a tick.
struct DayView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme
  let surface: DaySurface
  /// Changes whenever the surface is presented afresh, so it opens ready to
  /// type rather than holding the last thing that was searched.
  let resetToken: Int
  /// The panel's places, which ⌘P and ← at the top of the day go to. Set
  /// only on the panel.
  var summons: FocusPanelSummons?
  var onClose: ((FocusPanelDismissal) -> Void)?
  /// Shrinks the panel back to the running block's strip. Set only on the
  /// panel, and only while a block runs.
  var onMinimise: (() -> Void)?

  @State private var query = ""
  @State private var results: [TaskSearchResult] = []
  @State private var selectedID: String?
  @State private var hoveredID: String?
  @FocusState private var isFieldFocused: Bool
  /// The panel's keyboard is on the cards rather than in the field: ↓ from
  /// an empty field puts it there, and the window's keys work.
  @State private var keysInList = false
  @State private var router = FocusPanelKeyRouter()

  /// The id the create row answers to. A task's id is a UUID, so this cannot
  /// collide with one.
  private static let createRowID = "priority:create"

  var body: some View {
    // Built once per render and handed down, rather than a computed property
    // read by the list and again by the change handler below.
    let rows = rows
    VStack(spacing: 0) {
      if surface.isPanel, let pending = model.panelFocusCompletion {
        // Scoring a block is one question with one answer, so it gets the
        // panel to itself rather than sitting under a list it cannot act on.
        ScrollView { WorkspaceFocusQualityPrompt(pending: pending, fixedWidth: nil) }
      } else if surface.isPanel {
        // No tallies and no conditions line under the header: the panel is
        // for finding and working tasks, and the window's status bar and
        // Conditions tab already say both.
        header
        field
        FocusRule()
        content(rows)
        WorkspaceHeldBackLine {
          onClose?(.toWindow)
          AppDelegate.shared.showMainWindow()
          model.openConditionsTab()
        }
        if model.pendingTaskDeletionID != nil, let pending = model.pendingTaskDeletion {
          TaskDeletionPrompt(task: pending)
        } else {
          WorkspaceOverlayFooter(hints: hints)
        }
      } else {
        // The window's mount is the header band and the list, and nothing
        // else. The field, the two rows of tallies, the "add task" row, the
        // logged list and the key hints are the panel's: summoned over another
        // app it has no title bar to add from, no status bar to read the day's
        // numbers in and no reference to look keys up in. In the window each
        // of those already has a home, and here they were a second copy of it.
        header
        content(rows)
        // Why the day is shorter than the list: the tasks a condition is
        // holding back, and which conditions. Click for the Conditions tab.
        WorkspaceHeldBackLine { model.openConditionsTab() }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      if surface.isPanel { WindowKeyMonitor(handle: handlePanelKey) }
    }
    // An edit put away in the panel hands the keyboard back to where it was.
    .onChange(of: model.panelOverlay == nil) { _, closed in
      if closed && surface.isPanel && !keysInList { isFieldFocused = true }
    }
    // The caret back in the field, by a click or otherwise, is typing again.
    .onChange(of: isFieldFocused) { _, focused in
      if focused && keysInList {
        keysInList = false
        router.reset()
      }
    }
    // Over the whole surface rather than the card: by the time this plays the
    // card it belongs to has usually left the day, and a cleared day is
    // exactly when the flourish has the most to say.
    .overlay {
      if let flourish = manager.celebration.activeFlourish?.view {
        flourish
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .onAppear { reset() }
    .onChange(of: resetToken) { _, _ in reset() }
    // A delete asked about one row is not a delete of whichever row the
    // cursor moves to: moving on, or typing, lets the question go.
    .onChange(of: selectedID) { _, _ in model.cancelPendingTaskDeletion() }
    .onChange(of: query) { _, new in
      model.cancelPendingTaskDeletion()
      let trimmed = new.trimmingCharacters(in: .whitespaces)
      results = trimmed.isEmpty ? [] : model.searchResults(matching: trimmed)
      selectDefault()
    }
    .onChange(of: rows.map(\.outline)) { old, _ in selectDefault(previous: old) }
  }

  // MARK: - Chrome

  private var header: some View {
    // The same band as every other mode, so ⌘1 does not move the content down
    // by a different amount than ⌘2 does. The panel mounts this view too, and
    // gets its own two controls on the end of it.
    // No subtitle: the day draws from every list whichever one the sidebar
    // has selected, so naming that list here only misled.
    WorkspacePaneHeader(title: "Today") {
      EmptyView()
    } trailing: {
      if surface.isPanel {
        if manager.preferences.scoresEachFocusBlock && model.focusPoints.today > 0 {
          Text("\(FocusPoints.formatted(model.focusPoints.today)) pts")
            .font(theme.numeralFont(theme.scale.caption))
            .foregroundStyle(theme.dim)
            .monospacedDigit()
            .help("Minutes focused today, multiplied by how well each block went")
        }
      } else {
        dayTally
        // The way into focus from the window: the panel, which is where a
        // block is picked and where it runs. The day's cards are what it
        // offers, so this sits on the day rather than in a pane of its own.
        Button { model.openFocusPanel() } label: {
          Label(model.activeFocusSession == nil ? "Focus" : "Back to the block", systemImage: "arrow.up.right")
        }
        .buttonStyle(FocusActionButtonStyle(prominent: model.activeFocusSession == nil))
        .commandHelp(.goFocus, note: "Open the focus panel to pick a task and start it")
      }
      if surface.isPanel {
        FocusPanelHeaderButtons(
          onChooseList: { summons?.isChoosingList = true }, onOpenWindow: openInWindow,
          onClose: { onClose?(.back) })
      }
    }
  }

  /// The window's one figure for the day: what it has cost against what it
  /// was meant to. The panel's bar and its week line said this in two rows of
  /// capitals above the list; the week and the points are the status bar's
  /// now, and this is the part only the day pane can say.
  ///
  /// It also says when the day ends — Blitzit's signature, and the one number
  /// a list with estimates can work out that you would otherwise do in your
  /// head. Inside a timeline so the finish time keeps moving: every minute
  /// while idle (it slides later as the clock runs on without you), every
  /// half-minute while a block runs (the running task's cost grows with it).
  private var dayTally: some View {
    TimelineView(.periodic(from: .now, by: model.isFocusBlockTicking ? 30 : 60)) { context in
      let forecast = model.dayForecast(for: dayTasks, now: context.date)
      // Silent until there is something to tally: "0m logged" on a fresh
      // morning is a figure that says nothing.
      if forecast.loggedSeconds > 0 || forecast.remainingSeconds > 0 {
        Text(forecast.tallyText)
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.muted)
          .monospacedDigit()
          .lineLimit(1)
          .help(forecast.helpText)
      }
    }
  }

  private var field: some View {
    FocusPanelField(
      prompt: "Search, or type to add a task…", query: $query, isFocused: $isFieldFocused,
      help: "⌘⌫ deletes the task you are on, with the field empty · ⌘↵ opens the main window · "
        + "↓ with the field empty puts the keys on the cards",
      onKey: fieldKey)
  }

  /// Return always adds, Space always completes, as in Checkvist and the
  /// window. Starting an existing task is Tab, which has nothing else to do
  /// in a one-field panel.
  private func fieldKey(_ key: FocusPanelFieldKey) -> KeyPress.Result {
    switch key {
    case .up, .down:
      move(by: key == .up ? -1 : 1)
      // With nothing typed there is nothing to refine, so the keys go to the
      // cards, where the window's keys work.
      if query.isEmpty {
        keysInList = true
        isFieldFocused = false
      }
      return .handled
    case .left:
      return leaveForSidebar()
    case .escape:
      if model.pendingTaskDeletionID != nil { model.cancelPendingTaskDeletion(); return .handled }
      return dismissOrClear()
    case .commandDelete:
      // ⌘⌫ with text is the field's; with none, delete the task you are on.
      guard query.isEmpty else { return .ignored }
      return requestDeletion() ? .handled : .ignored
    case .enter, .commandEnter:
      if model.pendingTaskDeletionID != nil {
        confirmDeletion()
      } else if key == .commandEnter {
        openInWindow()
      } else {
        createFromQuery()
      }
      return .handled
    case .space:
      // Only with the field empty: once you are typing, Space is a space.
      guard query.isEmpty, model.pendingTaskDeletionID == nil else { return .ignored }
      tickOffSelection()
      return .handled
    case .tab:
      activateSelection()
      return .handled
    }
  }

  /// The foot of the panel: the keys that do something where the keyboard is.
  private var hints: String {
    if let jump = router.numberJumpHint { return jump }
    let start = startHint.lowercased()
    let escape = !query.isEmpty ? "clear" : onMinimise != nil ? "minimise" : "hide"
    if keysInList {
      return "space done · ee dd ⌥t edit · 1–4 priority · cc needs · / search · esc \(escape)"
    }
    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
      return "↑↓ choose · ↩ add · ⇥ \(start) · ⌘D due · F2 title · esc clear"
    }
    return "↓ the cards · space done · ⇥ \(start) · ⌘P lists · esc \(escape)"
  }

  private var startHint: String {
    if selectedID == Self.createRowID { return "Add and start" }
    if let id = selectedID, id == activeTaskID { return "Done" }
    return "Start it"
  }

  // MARK: - The list

  /// The window's draft row; the panel has its own field to type into.
  private var isDrafting: Bool { !surface.isPanel && model.draftsAtEnd }

  @ViewBuilder
  private func content(_ rows: [DayRow]) -> some View {
    if rows.isEmpty && !isDrafting {
      empty
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          // Rows on the one surface, ruled apart, rather than cards stacked
          // on a well: the day is a list to be read down, and a gap between
          // boxes is a second separator doing the hairline's job.
          LazyVStack(spacing: 0) {
            ForEach(rows) { row in
              view(for: row)
                .id(row.id)
              // Return on a subtask drawn under an unfolded task adds the
              // next of its parent's subtasks, typed in place beneath it.
              if !surface.isPanel && row.outline.depth > 0 && model.draftsBeside(row.id, above: false) {
                WorkspaceTaskDraftRow(depth: row.outline.depth)
                  .id("takt:draft")
              }
            }
            if isDrafting {
              // Where the new task will be: the foot of the day.
              WorkspaceTaskDraftRow(namesDestination: true)
                .id("takt:draft")
            }
            if surface.isPanel {
              if !loggedBlocks.isEmpty { logged }
            }
          }
          .padding(.bottom, theme.space.sm)
        }
        .onChange(of: cursorID) { _, id in
          guard let id else { return }
          withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
  }

  @ViewBuilder
  private var empty: some View {
    if surface.isPanel {
      VStack(spacing: theme.space.xs) {
        Spacer()
        Text(query.isEmpty ? "Nothing planned for today" : "No matches")
          .font(theme.bodyFont())
          .foregroundStyle(theme.muted)
        Text(query.isEmpty
          ? "Type a title and press Return to add the first one."
          : "Return adds “\(query.trimmingCharacters(in: .whitespaces))” to today.")
          .font(theme.captionFont)
          .foregroundStyle(theme.dim)
          .multilineTextAlignment(.center)
        Spacer()
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, theme.space.xl)
    } else {
      // One line of muted text in the middle of the pane, like every other
      // empty surface in the window.
      Text(
        "Nothing planned for today. Add a task from the title bar "
          + "(\(WorkspaceCommandHelpText.firstKey(for: .taskNew))) and it lands here.")
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
        .multilineTextAlignment(.center)
        .padding(theme.space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func view(for row: DayRow) -> some View {
    switch row.kind {
    case .create:
      createRow(row)
    case .task(let facts):
      if facts.isActive, let session = model.activeFocusSession {
        activeCard(facts: facts, session: session)
      } else {
        DayTaskRow(
          facts: facts, listName: row.listName, detail: row.detail,
          chrome: chrome(
            id: row.id, completion: facts.completion, depth: row.outline.depth,
            fold: row.outline.hasChildren ? !row.outline.isUnfolded : nil),
          onHover: { hover(row.id, $0) },
          onTap: { setCursor(row.id); start(facts.task) },
          onTick: { tickOff(facts.task) })
          .equatable()
      }
    }
  }

  /// The row's shell, from the list's state. `hasKeyboard` reads the focus
  /// area only for the cursor row, as the row used to.
  private func chrome(
    id: String, isActive: Bool = false, completion: CompletionKind?, depth: Int = 0, fold: Bool? = nil
  ) -> DayRowChrome {
    let isSelected = id == cursorID
    return DayRowChrome(
      id: id, isPanel: surface.isPanel, isSelected: isSelected,
      hasKeyboard: isSelected && !surface.isPanel && model.keyboardFocusArea == .tasks,
      isHovered: hoveredID == id, isActive: isActive, completion: completion, depth: depth, fold: fold)
  }

  private func hover(_ id: String, _ inside: Bool) {
    if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
  }

  /// Finishing something that never needed a block. A task that owes the day a
  /// contribution gets the contribution rather than being closed — that is the
  /// distinction the daily model rests on, and it must hold wherever the tick
  /// is pressed.
  private func tickOff(_ task: WorkspaceTask) {
    if model.isDailyProgressTask(task) {
      guard !model.isDailyProgressComplete(task) else { return }
      model.toggleDailyProgress(task)
    } else {
      model.toggleTask(task)
    }
    query = ""
  }

  /// Asks to delete the selected task; Return confirms. Never the running
  /// block: that one ends through its own finish, not by vanishing from
  /// under the clock.
  private func requestDeletion() -> Bool {
    guard let id = selectedID, id != Self.createRowID, id != activeTaskID,
      let task = model.task(withID: id) else { return false }
    model.requestTaskDeletion(task)
    return true
  }

  /// Deletes and lands on the neighbour, so ⌘⌫ ↩ repeated clears a run of rows.
  private func confirmDeletion() {
    let ids = rows.map(\.id)
    let neighbour = model.pendingTaskDeletionID.flatMap { ids.firstIndex(of: $0) }.flatMap { index in
      ids.indices.contains(index + 1) ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
    }
    model.confirmPendingTaskDeletion()
    selectedID = neighbour
  }

  private func tickOffSelection() {
    guard let id = selectedID, id != Self.createRowID, let task = model.task(withID: id) else { return }
    if id == activeTaskID { finish(); return }
    tickOff(task)
  }

  /// The row you are on. Same card, grown: a live clock, and the controls that
  /// only ever apply to the task actually running.
  private func activeCard(facts: DayTaskFacts, session: FocusSession) -> some View {
    let task = facts.task
    let index = facts.index
    let isExpanded = task.id == cursorID
    return DayRowCard(
      chrome: chrome(id: task.id, isActive: true, completion: facts.completion),
      onHover: { hover(task.id, $0) },
      onTap: {
        // Clicking is choosing, never finishing: a stray click on the row you
        // are working through closed the block. Done is its own button.
        setCursor(task.id)
      },
      content: {
      VStack(alignment: .leading, spacing: theme.space.sm) {
        HStack(alignment: isExpanded ? .firstTextBaseline : .center, spacing: theme.space.sm) {
          if let index {
            Text("\(index)")
              .font(theme.numeralFont(theme.scale.caption))
              .monospacedDigit()
              .foregroundStyle(theme.primary)
              .frame(minWidth: WorkspaceRowMetrics.iconWidth, alignment: .trailing)
          }
          Text(task.title)
            .font(theme.titleFont)
            .foregroundStyle(facts.isBlocked ? theme.muted : theme.ink)
            .expandsWhenSelected(isExpanded, lineLimit: 2)
          Spacer(minLength: theme.space.sm)
          if let list = model.list(for: task) {
            MicroLabel(list.name).lineLimit(1).fixedSize(horizontal: isExpanded, vertical: false)
          }
        }
        if session.phase == .onBreak {
          breakClock(session: session)
        } else {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let reading = FocusTimerDisplay.reading(
              elapsed: TimeInterval(session.elapsedSeconds(now: context.date)),
              planned: TimeInterval(session.workDurationSeconds))
            Text(reading.text)
              .font(theme.numeralFont(theme.scale.display, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(session.pausedAt == nil
                ? (reading.isOverrun ? theme.warning : theme.primary) : theme.muted)
              .contentTransition(.numericText())
          }
          MicroLabel(
            session.pausedAt == nil ? "of \(duration(session.workDurationSeconds))" : "paused",
            tint: session.pausedAt == nil ? nil : theme.warning)
          Spacer(minLength: 0)
        }
        }
        controlStrip(session: session)
      }
    })
  }

  /// A break in place of the block's clock: the time left on it in the
  /// success colour, then counting up past it in the warning colour. Going
  /// back is never automatic — a clock that restarted unattended would log a
  /// sitting nobody was at.
  private func breakClock(session: FocusSession) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let reading = FocusTimerDisplay.breakReading(endsAt: session.breakEndsAt, now: context.date)
      HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
        Text(reading.text)
          .font(theme.numeralFont(theme.scale.display, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(reading.isOverrun ? theme.warning : theme.success)
          .contentTransition(.numericText())
        MicroLabel(
          reading.isOverrun ? "break's over · p back to work" : "break · p back to work",
          tint: reading.isOverrun ? theme.warning : nil)
        Spacer(minLength: 0)
      }
    }
  }

  /// Blitzit's strip, in Priority's vocabulary: pause, skip to the next queued
  /// task, log the time without closing anything, stop altogether, and tick
  /// it off.
  private func controlStrip(session: FocusSession) -> some View {
    HStack(spacing: theme.space.xs) {
      if session.phase == .onBreak {
        control("play.fill", "Back to work (p)") { model.endFocusBreak() }
      } else {
        control(session.pausedAt == nil ? "pause.fill" : "play.fill",
          session.pausedAt == nil ? "Pause" : "Resume") { model.toggleFocusPause() }
      }
      control("forward.end.fill", "Skip to the next task in the queue") { skip() }
        .disabled(!hasQueuedSuccessor || session.phase == .onBreak)
      control("clock.arrow.circlepath", "Log the time so far and leave the task open") { logProgress() }
        .disabled(session.phase == .onBreak)
      if let onMinimise {
        control("arrow.down.right.and.arrow.up.left", "Minimise to the task and its clock (esc)") { onMinimise() }
      }
      Spacer(minLength: 0)
      // Out of the block without closing the task or answering for it.
      FocusStopButton()
      Button { finish() } label: {
        Label("Done", systemImage: "checkmark")
      }
      .buttonStyle(FocusActionButtonStyle(prominent: true))
      .focusable(false)
      .help("Done · ⇥ on the running task, or space with the field empty")
    }
  }

  private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
    }
    .buttonStyle(FocusActionButtonStyle())
    .focusable(false)
    .help(help)
    .accessibilityLabel(help)
  }

  /// The title the task will actually get, with what the trailing words set
  /// beside it — the same parse `createTask(capturing:)` runs on Return.
  private func createRow(_ row: DayRow) -> some View {
    let capture = TaskCapture.parse(row.title)
    return DayRowCard(
      chrome: chrome(id: row.id, completion: nil),
      onHover: { hover(row.id, $0) },
      onTap: { setCursor(row.id); createFromQuery() },
      content: {
      HStack(spacing: theme.space.sm) {
        Image(systemName: "plus")
          .font(theme.bodyFont())
          .foregroundStyle(theme.primary)
        Text("Add “\(capture.title)” to today")
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        if capture.hasDetails {
          TaskCapturePreview(capture: capture)
        }
        Spacer(minLength: 0)
      }
      .help(TaskCapturePreview.syntaxHint)
    })
  }

  // MARK: - Today's logged work

  private var logged: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      HStack(spacing: 0) {
        MicroLabel("\(loggedBlocks.count) logged today")
        Spacer(minLength: theme.space.sm)
        MicroLabel(duration(loggedToday))
      }
      .padding(.top, theme.space.sm)
      ForEach(loggedBlocks, id: \.title) { entry in
        HStack(spacing: theme.space.sm) {
          Image(systemName: "checkmark")
            .font(theme.bodyFont(size: theme.scale.caption))
            .foregroundStyle(theme.success)
          Text(entry.title)
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: theme.space.sm)
          Text(duration(entry.seconds))
            .font(theme.numeralFont(theme.scale.caption, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(theme.dim)
        }
      }
    }
    .padding(.horizontal, theme.space.lg)
    .padding(.top, theme.space.xs)
  }

  /// Today's blocks, one line per task rather than one per sitting: three
  /// twenty-minute goes at the same thing is an hour on it, not three rows.
  private var loggedBlocks: [(title: String, seconds: Int)] {
    var order: [String] = []
    var totals: [String: Int] = [:]
    for block in model.todayWorkBlocks {
      if totals[block.taskTitle] == nil { order.append(block.taskTitle) }
      totals[block.taskTitle, default: 0] += block.seconds
    }
    return order.map { (title: $0, seconds: totals[$0] ?? 0) }
  }

  private var loggedToday: Int { model.todayWorkBlocks.reduce(0) { $0 + $1.seconds } }

  // MARK: - What is in the list

  /// The running block's task, by id. Not `activeFocusTask`, which resolves
  /// the task through the model's cache and so would redraw the whole day on
  /// every refresh whether or not anything on it changed.
  private var activeTaskID: String? { model.activeFocusSession?.activeTaskId }

  /// The row under the cursor. The panel keeps its own, because its list can
  /// be a page of search results; the window's is the workspace selection, so
  /// the ordinary keys walk it, the inspector follows it and the title bar's
  /// `a` knows which task it is below.
  private var cursorID: String? { surface.isPanel ? selectedID : model.selectedTaskID }

  private func setCursor(_ id: String?) {
    if surface.isPanel {
      selectedID = id
    } else {
      model.selectedTaskID = id
      model.reportKeyboardFocus(.tasks)
    }
  }

  /// The day, in the order it is read: the running block, the Today column as
  /// it was arranged by hand, then everything the dates put there — overdue,
  /// due today, starting today. Shared with the menu bar so the two cannot
  /// disagree about what is on today.
  private var day: [DayItem] { model.dayItems }

  private var dayTasks: [WorkspaceTask] { day.map(\.task) }

  /// Every row the keyboard can land on, in the order it sees them.
  ///
  /// Everything a row draws is settled here, from lookups built once, so the
  /// rows themselves are plain values: a list name by id rather than a scan
  /// of the lists per row, a daily by task rather than a scan of the dailies.
  private var rows: [DayRow] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let activeID = activeTaskID
    let dailies = Dictionary(
      model.dailyItems.map { ($0.task.id, $0) }, uniquingKeysWith: { first, _ in first })
    let logged = model.taskLoggedSeconds
    let priorities = model.taskPriorities
    func facts(_ task: WorkspaceTask, index: Int?) -> DayTaskFacts {
      let daily = dailies[task.id]
      let isDaily = model.isDailyProgressTask(task)
      return DayTaskFacts(
        task: task, index: index, isActive: task.id == activeID,
        completion: daily.map { .daily(id: $0.daily.id) } ?? .workspaceTask(id: task.id),
        isDaily: isDaily, isDailyDone: isDaily && (daily?.isDoneToday ?? false),
        priority: priorities[task.id],
        cost: DayTaskFacts.cost(estimate: task.estimateSeconds, logged: logged[task.id] ?? 0),
        isBlocked: model.isBlocked(task))
    }
    if trimmed.isEmpty {
      let listNames = Dictionary(model.lists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
      // Numbered by the day's own tasks; a subtask drawn under one is not a
      // place in the day, so it takes no number, and no list name either —
      // it is in its parent's.
      var position = 0
      return model.dayTree.map { entry in
        let isSubtask = entry.row.depth > 0
        if !isSubtask { position += 1 }
        return DayRow(
          id: entry.task.id, title: entry.task.title,
          listName: isSubtask ? nil : listNames[entry.task.listId],
          // Why it is in the day beats when it is due: "overdue" is the thing
          // worth reading, and the deadline is what made it say that.
          detail: detail(for: entry.task, reason: entry.reason),
          kind: .task(facts(entry.task, index: isSubtask ? nil : position)),
          outline: entry.row)
      }
    }
    var found: [DayRow] = results.prefix(10).map { result in
      DayRow(
        id: result.task.id, title: result.task.title, listName: result.list.name,
        detail: result.notesSnippet,
        kind: .task(facts(result.task, index: nil)))
    }
    found.append(DayRow(id: Self.createRowID, title: trimmed, listName: nil, detail: nil, kind: .create))
    return found
  }

  /// A derived reason is worth saying; `.planned` is not, because every card
  /// under an empty field is in the day and saying so on each one is noise.
  ///
  /// The relative date is read through a cache: formatting one costs tens of
  /// microseconds, and the list is rebuilt on every arrow key.
  private func detail(for task: WorkspaceTask, reason: DayPlanReason?) -> String? {
    switch reason {
    case .overdue, .dueToday: return reason?.label
    case .startsToday, .running, .planned, nil:
      return task.dueAt.map { "Due \(RelativeDateTextCache.shared.text(for: $0))" }
    }
  }

  private var hasQueuedSuccessor: Bool {
    model.focusQueue.contains { $0.item.state == .queued && $0.task.id != activeTaskID }
  }
}

// MARK: - Selection

/// Which row is under the cursor, and what a fresh presentation looks like.
/// An extension rather than more of the struct: the body above is already at
/// the length SwiftLint is willing to read in one piece.
extension DayView {
  /// What a fresh presentation looks like: an empty field with the caret in it,
  /// and the running task — or the top of the day — under the cursor.
  private func reset() {
    query = ""
    results = []
    guard surface.isPanel else {
      // The window has no field to take the caret: the list is the tasks
      // region, and the catalogue's ordinary keys walk it. A selection left
      // over from another mode that is not on the day gives way to the
      // running task, or the top of the day.
      if let id = model.selectedTaskID, rows.contains(where: { $0.id == id }) { return }
      model.selectedTaskID = activeTaskID ?? rows.first?.id
      return
    }
    // The panel takes the caret: every key it advertises hangs off its field.
    keysInList = false
    router.reset()
    isFieldFocused = true
    selectedID = activeTaskID ?? rows.first?.id
  }

  /// - Parameter previous: the rows before the change, when the day changed
  ///   under the cursor rather than a new query replacing it. A card ticked
  ///   off leaves the day, and the cursor goes to the card that took its
  ///   place rather than back to the top.
  private func selectDefault(previous: [DayOutlineRow] = []) {
    let ids = rows.map(\.id)
    if let cursorID, ids.contains(cursorID) { return }
    // In the window only while the pane has the keyboard: a task selected in
    // the sidebar's list, or left by another mode, is not the day's to take.
    if !surface.isPanel && model.keyboardFocusArea != .tasks { return }
    // A ticked-off subtask hands the cursor to its next sibling, then its
    // parent; one of the day's own tasks, to the task after it.
    let successor = cursorID.flatMap { DayOutline.successor(of: $0, previous: previous, remaining: ids) }
    setCursor(successor ?? ids.first)
  }

  private func move(by offset: Int) {
    let ids = rows.map(\.id)
    guard !ids.isEmpty else { return }
    let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
    selectedID = ids[min(max(0, current + offset), ids.count - 1)]
  }

  /// Left is out, the same as it is on the board and in the outline: the day
  /// has no hierarchy of its own to step out of, so one press goes straight to
  /// the list it came from, with the sidebar taking the keyboard.
  ///
  /// Only with an empty field. Once there is a query in it, left and right are
  /// the caret's, and a search box you cannot move around in is worse than no
  /// shortcut. The panel has no sidebar to reach, so it declines.
  private func leaveForSidebar() -> KeyPress.Result {
    guard query.isEmpty, !surface.isPanel else { return .ignored }
    model.returnToCurrentListInSidebar()
    return .handled
  }

  // MARK: - Acting

  /// Escape means "undo the last narrowing". In the panel the last narrowing
  /// may be the summon itself; in the pane there is nothing behind it, so an
  /// empty field lets the key through to the window.
  private func dismissOrClear() -> KeyPress.Result {
    if !query.isEmpty {
      query = ""
      return .handled
    }
    guard surface.isPanel else { return .ignored }
    // With a block running, the first Escape goes back to its strip rather
    // than out of the panel; the strip's own Escape hides it.
    if let onMinimise { onMinimise(); return .handled }
    onClose?(.back)
    return .handled
  }

  private func activateSelection() {
    guard let id = selectedID else { return }
    if id == Self.createRowID { createFromQuery(); return }
    if id == activeTaskID { finish(); return }
    guard let task = model.task(withID: id) else { return }
    start(task)
  }

  /// Starting from here is deliberately unconditional. The focus screen asks
  /// whether a task is available; pressing play on a row is an answer to that,
  /// and the block runs for as long as the task's own estimate says.
  private func start(_ task: WorkspaceTask) {
    model.startOrQueueFocus(on: task, from: completionSurface)
    query = ""
  }

  private func skip() {
    // Logging the current block is what advances the queue; nothing is thrown
    // away by moving on.
    model.requestFocusCompletion(completeTask: false, from: completionSurface)
  }

  /// Done. In the panel the question that follows is asked here rather than in
  /// the window: a panel you can run a whole block from but not close one in
  /// would send you to the app at the only moment that matters.
  private func finish() {
    model.requestFocusCompletion(from: completionSurface)
  }

  /// The same stop, without closing the task. Scored too — the minutes were
  /// still spent.
  private func logProgress() {
    model.requestFocusCompletion(completeTask: false, from: completionSurface)
  }

  private var completionSurface: FocusCompletionSurface {
    surface.isPanel ? .panel : .window
  }

  /// In the panel, adding a task is deciding to do it: it goes into today and
  /// starts at once, so summon, type and Return is the whole way into a block.
  /// The window only files it.
  private func createFromQuery() {
    let title = query.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }
    let task = model.createBoardTask(named: title, in: model.boardColumns.first { $0.id == "today" })
    query = ""
    if surface.isPanel, let task { start(task) }
  }

  private func openInWindow() {
    guard surface.isPanel else { return }
    onClose?(.toWindow)
    AppDelegate.shared.showMainWindow()
    if let id = selectedID, let result = results.first(where: { $0.task.id == id }) {
      model.reveal(result)
    } else if let id = selectedID, let task = model.task(withID: id) {
      model.selectTask(task)
    }
  }

  // MARK: - Formatting

  /// Hours and minutes, never seconds: an estimate measured to the second is
  /// a precision nobody typed in.
  private func duration(_ seconds: Int) -> String {
    DayForecast.hoursAndMinutes(seconds)
  }
}

// MARK: - The panel's keys on the cards

extension DayView {
  /// The panel's keys, once they are on the cards — and the chorded few that
  /// reach out of the field (`FocusPanelKeyRouter`). Never while the score
  /// is being asked for, which has keys of its own.
  private func handlePanelKey(_ event: NSEvent) -> Bool {
    guard surface.isPanel, model.panelFocusCompletion == nil, let summons, !summons.isChoosingList
    else { return false }
    return keysInList
      ? router.handleListKey(event, model: model, summons: summons, context: listContext)
      : router.handleFieldKey(event, model: model, summons: summons, context: listContext)
  }

  private var listContext: FocusPanelListContext {
    let rows = rows
    let outline = rows.map(\.outline)
    return FocusPanelListContext(
      surface: .today, rowIDs: rows.map(\.id),
      // As the cards number themselves: a subtask drawn under one is not a
      // place in the day.
      numberedIDs: rows.filter { $0.outline.depth == 0 && $0.id != Self.createRowID }.map(\.id),
      cursorID: selectedID, setCursor: { selectedID = $0 },
      right: { stepAcross(right: true, in: outline) },
      left: { stepAcross(right: false, in: outline) },
      complete: { task in
        if task.id == activeTaskID { finish() } else { tickOff(task) }
      },
      start: start, confirmDeletion: confirmDeletion,
      toField: {
        keysInList = false
        router.reset()
        isFieldFocused = true
      },
      dismiss: { _ = dismissOrClear() }, openInWindow: openInWindow)
  }

  /// → and ← on a card, as on the window's Today: open a task's subtasks
  /// and step in, fold them and step out — and from the top of the day, out
  /// to the lists, where the window goes to the sidebar.
  private func stepAcross(right: Bool, in outline: [DayOutlineRow]) {
    guard let id = selectedID else {
      selectedID = outline.first?.id
      return
    }
    switch right ? DayOutline.right(from: id, in: outline) : DayOutline.left(from: id, in: outline) {
    case .unfold(let id): WorkspaceMotion.animate { model.setDayTaskUnfolded(id, true) }
    case .fold(let id): WorkspaceMotion.animate { model.setDayTaskUnfolded(id, false) }
    case .select(let next): selectedID = next
    case .leave: if !right { summons?.isChoosingList = true }
    }
  }
}

/// A task that owes the day a contribution, marked where it is read rather
/// than gathered into a place of its own. A daily is a requirement on an
/// ordinary task, so it shows up as something the task *is*, next to its title.
///
/// It is also the way to answer the requirement without starting a block, which
/// is what the dailies screen used to be for: some days a daily is discharged
/// by having done it, not by sitting down to it.
struct DailyBadge: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let isDoneToday: Bool

  var body: some View {
    Button {
      model.toggleDailyProgress(task)
    } label: {
      Group {
        if isDoneToday {
          TaskCheckBox(isDone: true, size: CGFloat(theme.scale.caption))
        } else {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(theme.microLabelFont)
            .foregroundStyle(theme.muted)
        }
      }
        .frame(width: theme.paneIconButtonSize, height: theme.paneIconButtonSize)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .help(isDoneToday
      ? "Daily: today's contribution is in. Click to take it back."
      : "Daily: still owes today a contribution. Click to record one.")
    .accessibilityLabel(isDoneToday ? "Daily, done today" : "Daily, not yet done today")
  }
}

/// One row of the day, whatever put it there. The list only ever sees this.
private struct DayRow: Identifiable {
  enum Kind {
    /// The task, its position in the day, whether it is the one running, and
    /// the rest of what its row draws.
    case task(DayTaskFacts)
    case create
  }

  let id: String
  let title: String
  let listName: String?
  let detail: String?
  let kind: Kind
  /// Where it hangs in the day; a search result or the create row is a
  /// top-level row with nothing beneath it.
  var outline: DayOutlineRow

  init(id: String, title: String, listName: String?, detail: String?, kind: Kind, outline: DayOutlineRow? = nil) {
    self.id = id
    self.title = title
    self.listName = listName
    self.detail = detail
    self.kind = kind
    self.outline = outline ?? DayOutlineRow(id: id, depth: 0, parentID: nil, hasChildren: false, isUnfolded: false)
  }
}
