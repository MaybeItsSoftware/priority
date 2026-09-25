import PriorityCore
import PriorityWorkspace
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
/// conditions, an available-time window, an estimate to commit to before you
/// may begin. That ceremony belongs to deciding what a day should be. This is
/// the surface you work a day from, so a task is a row you press play on, and
/// the row you are on grows a pause, a skip and a tick.
struct DayView: View {
  @Environment(WorkspaceViewModel.self) private var model
  let surface: DaySurface
  /// Changes whenever the surface is presented afresh, so it opens ready to
  /// type rather than holding the last thing that was searched.
  let resetToken: Int
  var onClose: ((FocusPanelDismissal) -> Void)?

  @State private var query = ""
  @State private var results: [TaskSearchResult] = []
  @State private var selectedID: String?
  @FocusState private var isFieldFocused: Bool

  /// The id the create row answers to. A task's id is a UUID, so this cannot
  /// collide with one.
  private static let createRowID = "priority:create"

  var body: some View {
    VStack(spacing: 0) {
      if surface.isPanel, let pending = model.panelFocusCompletion {
        // Scoring a block is one question with one answer, so it gets the
        // panel to itself rather than sitting under a list it cannot act on.
        ScrollView { WorkspaceFocusQualityPrompt(pending: pending, fixedWidth: nil) }
      } else {
        header
        summary
        field
        FocusRule()
        content
        FocusRule()
        hints
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { reset() }
    .onChange(of: resetToken) { _, _ in reset() }
    .onChange(of: query) { _, new in
      let trimmed = new.trimmingCharacters(in: .whitespaces)
      results = trimmed.isEmpty ? [] : model.searchResults(matching: trimmed)
      selectDefault()
    }
    .onChange(of: rows.map(\.id)) { _, _ in selectDefault() }
  }

  // MARK: - Chrome

  private var header: some View {
    HStack(spacing: 8) {
      Text("Today")
        .font(.system(size: 20, weight: .semibold))
      MicroLabel(scopeName)
      Spacer(minLength: 8)
      Text("\(FocusPoints.formatted(model.focusPoints.today)) pts")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .help("Minutes focused today, multiplied by how well each block went")
      if surface.isPanel {
        Button { openInWindow() } label: {
          Image(systemName: "macwindow")
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("Open the main window (⌘↵)")
        .accessibilityLabel("Open the main window")
        Button { onClose?(.back) } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("Hide the panel (esc)")
        .accessibilityLabel("Hide the focus panel")
      }
    }
    .padding(.horizontal, 18)
    .padding(.top, 16)
    .padding(.bottom, 10)
  }

  /// What the day is supposed to cost against what it has cost so far. A bar
  /// rather than a second row of numbers: the question it answers is "how far
  /// through", which is a length, not a figure to read.
  private var summary: some View {
    let estimated = dayTasks.reduce(0) { $0 + ($1.estimateSeconds ?? 0) }
    let logged = loggedToday
    let fraction = estimated > 0 ? min(1, Double(logged) / Double(estimated)) : 0
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 0) {
        MicroLabel(estimated > 0 ? "Est \(duration(estimated))" : "No estimates yet")
        Spacer(minLength: 8)
        MicroLabel(logged > 0 ? "\(duration(logged)) logged" : "Nothing logged yet")
      }
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(0.08))
          Capsule()
            .fill(Color.accentColor)
            .frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * fraction))
        }
      }
      .frame(height: 4)
      weekLine
    }
    .padding(.horizontal, 18)
    .padding(.bottom, 12)
  }

  /// Today's finished work set against the week so far.
  ///
  /// The day's own bar answers "how far through today am I"; this answers the
  /// question you only notice on a bad day — whether today is actually worse
  /// than the rest of the week, or only feels it. The week is its own
  /// denominator, so there is no target to set up before the line means
  /// anything.
  @ViewBuilder private var weekLine: some View {
    let progress = model.workProgress
    if progress.week.seconds > 0 || progress.week.completed > 0 {
      HStack(spacing: 0) {
        MicroLabel(
          progress.today.completed == 1
            ? "1 done today" : "\(progress.today.completed) done today")
        Spacer(minLength: 8)
        MicroLabel(
          "\(duration(progress.week.seconds)) this week · \(duration(progress.averageSecondsPerDay))/day")
      }
      .padding(.top, 2)
    }
  }

  private var field: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
      TextField("Search, or type to add a task…", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused($isFieldFocused)
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
        .onKeyPress(.escape) { dismissOrClear() }
        .onKeyPress(keys: [.return], phases: .down) { press in
          if press.modifiers.contains(.command) { openInWindow() } else { activateSelection() }
          return .handled
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    .padding(.horizontal, 18)
    .padding(.bottom, 12)
  }

  private var hints: some View {
    HStack(spacing: 14) {
      KeyHint("↑ ↓", "Choose")
      KeyHint("↵", returnHint)
      Spacer(minLength: 0)
      if surface.isPanel {
        KeyHint("esc", query.isEmpty ? "Hide" : "Clear")
      } else if !query.isEmpty {
        KeyHint("esc", "Clear")
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 9)
  }

  private var returnHint: String {
    if selectedID == Self.createRowID { return "Add to today" }
    if let id = selectedID, id == model.activeFocusTask?.id { return "Done" }
    return "Start it"
  }

  // MARK: - The list

  @ViewBuilder
  private var content: some View {
    if rows.isEmpty {
      empty
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(rows) { row in
              view(for: row)
                .id(row.id)
            }
            if query.isEmpty { addHint }
            if !loggedBlocks.isEmpty { logged }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
        }
        .onChange(of: selectedID) { _, id in
          guard let id else { return }
          withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
  }

  private var empty: some View {
    VStack(spacing: 6) {
      Spacer()
      Text(query.isEmpty ? "Nothing planned for today" : "No matches")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(query.isEmpty
        ? "Type a title and press Return to add the first one."
        : "Return adds “\(query.trimmingCharacters(in: .whitespaces))” to today.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
  }

  @ViewBuilder
  private func view(for row: DayRow) -> some View {
    switch row.kind {
    case .create:
      createRow(row)
    case .task(let task, let index, let isActive):
      if isActive, let session = model.activeFocusSession {
        activeCard(task: task, index: index, session: session)
      } else {
        taskCard(task: task, index: index, listName: row.listName, detail: row.detail)
      }
    }
  }

  /// An ordinary row: what it is, what it should cost, what it has cost.
  private func taskCard(task: WorkspaceTask, index: Int?, listName: String?, detail: String?) -> some View {
    card(id: task.id) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          if let index {
            Text("\(index)")
              .font(.system(size: 11, weight: .semibold, design: .monospaced))
              .foregroundStyle(.tertiary)
              .frame(minWidth: 12, alignment: .trailing)
          }
          Text(task.title)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
          if model.isDailyProgressTask(task) {
            DailyBadge(task: task, isDoneToday: model.isDailyProgressComplete(task))
          }
          Spacer(minLength: 8)
          if let listName { MicroLabel(listName).lineLimit(1) }
        }
        HStack(spacing: 8) {
          Text(task.estimateSeconds.map { duration($0) } ?? "No estimate")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
          if let detail {
            Text(detail)
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Text(clock(model.taskLoggedSeconds[task.id] ?? 0))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
      }
    } action: {
      start(task)
    }
  }

  /// The row you are on. Same card, grown: a live clock, and the controls that
  /// only ever apply to the task actually running.
  private func activeCard(task: WorkspaceTask, index: Int?, session: FocusSession) -> some View {
    card(id: task.id, isActive: true) {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 8) {
          if let index {
            Text("\(index)")
              .font(.system(size: 11, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.accentColor)
              .frame(minWidth: 12, alignment: .trailing)
          }
          Text(task.title)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(2)
          Spacer(minLength: 8)
          if let list = model.list(for: task) { MicroLabel(list.name).lineLimit(1) }
        }
        HStack(spacing: 10) {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let reading = FocusTimerDisplay.reading(
              elapsed: TimeInterval(session.elapsedSeconds(now: context.date)),
              planned: TimeInterval(session.workDurationSeconds))
            Text(reading.text)
              .font(.system(size: 26, weight: .semibold, design: .monospaced))
              .monospacedDigit()
              .foregroundStyle(session.pausedAt == nil
                ? (reading.isOverrun ? model.themeColor(.warning) : Color.accentColor) : Color.secondary)
              .contentTransition(.numericText())
          }
          MicroLabel(
            session.pausedAt == nil ? "of \(duration(session.workDurationSeconds))" : "paused",
            tint: session.pausedAt == nil ? nil : model.themeColor(.warning))
          Spacer(minLength: 0)
        }
        controlStrip(session: session)
      }
    } action: {
      finish()
    }
  }

  /// Blitzit's strip, in Priority's vocabulary: pause, skip to the next queued
  /// task, log the time without closing anything, and tick it off.
  private func controlStrip(session: FocusSession) -> some View {
    HStack(spacing: 4) {
      control(session.pausedAt == nil ? "pause.fill" : "play.fill",
        session.pausedAt == nil ? "Pause" : "Resume") { model.toggleFocusPause() }
      control("forward.end.fill", "Skip to the next task in the queue") { skip() }
        .disabled(!hasQueuedSuccessor)
      control("clock.arrow.circlepath", "Log the time so far and leave the task open") { logProgress() }
      Spacer(minLength: 0)
      Button { finish() } label: {
        Label("Done", systemImage: "checkmark")
          .font(.system(size: 12, weight: .medium))
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .focusable(false)
    }
  }

  private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12))
        .frame(width: 26, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .focusable(false)
    .help(help)
    .accessibilityLabel(help)
  }

  private func createRow(_ row: DayRow) -> some View {
    card(id: row.id) {
      HStack(spacing: 8) {
        Image(systemName: "plus")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.accentColor)
        Text("Add “\(row.title)” to today")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
    } action: {
      createFromQuery()
    }
  }

  private var addHint: some View {
    HStack(spacing: 8) {
      Image(systemName: "plus")
        .font(.system(size: 11, weight: .semibold))
      MicroLabel("Add task")
      Spacer(minLength: 0)
      Text("type a title, then ↵")
        .font(.system(size: 11))
    }
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture { isFieldFocused = true }
  }

  /// One card shape for every row, so a row that gains controls is visibly the
  /// same row rather than a different kind of thing.
  private func card<Content: View>(
    id: String, isActive: Bool = false, @ViewBuilder content: () -> Content,
    action: @escaping () -> Void
  ) -> some View {
    let isSelected = id == selectedID
    return content()
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isActive ? Color.accentColor.opacity(0.10) : Color.primary.opacity(isSelected ? 0.07 : 0.035),
        in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(
            isActive ? Color.accentColor.opacity(0.55)
              : Color.primary.opacity(isSelected ? 0.22 : 0.08),
            lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .onTapGesture { selectedID = id; action() }
  }

  // MARK: - Today's logged work

  private var logged: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 0) {
        MicroLabel("\(loggedBlocks.count) logged today")
        Spacer(minLength: 8)
        MicroLabel(duration(loggedToday))
      }
      .padding(.top, 8)
      ForEach(loggedBlocks, id: \.title) { entry in
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
          Text(entry.title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 8)
          Text(duration(entry.seconds))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 4)
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

  private var scopeName: String {
    model.isEverythingSelected ? "Everything" : (model.selectedList?.name ?? "Workspace")
  }

  private var activeTaskID: String? { model.activeFocusTask?.id }

  /// The day, in the order it is read: the running block, the Today column as
  /// it was arranged by hand, then everything the dates put there — overdue,
  /// due today, starting today. Shared with the menu bar so the two cannot
  /// disagree about what is on today.
  private var day: [DayItem] { model.dayItems }

  private var dayTasks: [WorkspaceTask] { day.map(\.task) }

  /// Every row the keyboard can land on, in the order it sees them.
  private var rows: [DayRow] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      return day.enumerated().map { index, entry in
        DayRow(
          id: entry.task.id, title: entry.task.title,
          listName: model.list(for: entry.task)?.name,
          // Why it is in the day beats when it is due: "overdue" is the thing
          // worth reading, and the deadline is what made it say that.
          detail: detail(for: entry.task, reason: entry.reason),
          kind: .task(entry.task, index + 1, entry.task.id == activeTaskID))
      }
    }
    var found: [DayRow] = results.prefix(10).map { result in
      DayRow(
        id: result.task.id, title: result.task.title, listName: result.list.name,
        detail: result.notesSnippet,
        kind: .task(result.task, nil, result.task.id == activeTaskID))
    }
    found.append(DayRow(id: Self.createRowID, title: trimmed, listName: nil, detail: nil, kind: .create))
    return found
  }

  /// A derived reason is worth saying; `.planned` is not, because every card
  /// under an empty field is in the day and saying so on each one is noise.
  private func detail(for task: WorkspaceTask, reason: DayPlanReason?) -> String? {
    switch reason {
    case .overdue, .dueToday, .startsToday: return reason?.label
    case .running, .planned, nil:
      return task.dueAt.map { "Due \($0.formatted(.relative(presentation: .named)))" }
    }
  }

  private var hasQueuedSuccessor: Bool {
    model.focusQueue.contains { $0.item.state == .queued && $0.task.id != activeTaskID }
  }

  // MARK: - Selection

  /// What a fresh presentation looks like: an empty field with the caret in it,
  /// and the running task — or the top of the day — under the cursor.
  private func reset() {
    query = ""
    results = []
    // The pane is entered by a shortcut from somewhere else in the window, and
    // stealing the caret would make every ⌘1 a typing surprise. The panel is
    // summoned *to* be typed into.
    isFieldFocused = surface.isPanel
    selectedID = activeTaskID ?? rows.first?.id
  }

  private func selectDefault() {
    let ids = rows.map(\.id)
    if let selectedID, ids.contains(selectedID) { return }
    selectedID = ids.first
  }

  private func move(by offset: Int) {
    let ids = rows.map(\.id)
    guard !ids.isEmpty else { return }
    let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
    selectedID = ids[min(max(0, current + offset), ids.count - 1)]
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
    guard task.id != activeTaskID else { finish(); return }
    if model.activeFocusSession != nil {
      model.addToFocusQueue(task)
      query = ""
      return
    }
    model.startFocus(on: task, override: true)
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

  private func createFromQuery() {
    let title = query.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }
    model.createBoardTask(named: title, in: model.boardColumns.first { $0.id == "today" })
    query = ""
  }

  private func openInWindow() {
    guard surface.isPanel else { return }
    onClose?(.toWindow)
    AppDelegate.shared.showMainWindow()
    if let id = selectedID, let result = results.first(where: { $0.task.id == id }) {
      model.reveal(result)
    } else if let id = selectedID, let task = model.task(withID: id) {
      model.selectTask(task)
      model.dismissFocusScreen()
    }
  }

  // MARK: - Formatting

  /// Hours and minutes, never seconds: an estimate measured to the second is
  /// a precision nobody typed in.
  private func duration(_ seconds: Int) -> String {
    let minutes = max(0, seconds) / 60
    if minutes < 60 { return "\(minutes)m" }
    let remainder = minutes % 60
    return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
  }

  /// A stopwatch reading for time already spent on a task, so the column of
  /// them lines up whatever the numbers are.
  private func clock(_ seconds: Int) -> String {
    let total = max(0, seconds)
    return String(format: "%02d:%02d", total / 3600, (total % 3600) / 60)
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
  let task: WorkspaceTask
  let isDoneToday: Bool

  var body: some View {
    Button {
      model.toggleDailyProgress(task)
    } label: {
      Image(systemName: isDoneToday ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(isDoneToday ? model.themeColor(.success) : Color.secondary)
        .frame(width: 16, height: 16)
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
    /// The task, its position in the day, and whether it is the one running.
    case task(WorkspaceTask, Int?, Bool)
    case create
  }

  let id: String
  let title: String
  let listName: String?
  let detail: String?
  let kind: Kind
}
