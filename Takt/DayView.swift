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
/// conditions, an available-time window, an estimate to commit to before you
/// may begin. That ceremony belongs to deciding what a day should be. This is
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
  var onClose: ((FocusPanelDismissal) -> Void)?
  /// Shrinks the panel back to the running block's strip. Set only on the
  /// panel, and only while a block runs.
  var onMinimise: (() -> Void)?

  @State private var query = ""
  @State private var results: [TaskSearchResult] = []
  @State private var selectedID: String?
  @State private var hoveredID: String?
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
      } else if surface.isPanel {
        header
        summary
        field
        FocusRule()
        content
        FocusRule()
        hints
      } else {
        // The window's mount is the header band and the list, and nothing
        // else. The field, the two rows of tallies, the "add task" row, the
        // logged list and the key hints are the panel's: summoned over another
        // app it has no title bar to add from, no status bar to read the day's
        // numbers in and no reference to look keys up in. In the window each
        // of those already has a home, and here they were a second copy of it.
        header
        content
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    .onChange(of: query) { _, new in
      let trimmed = new.trimmingCharacters(in: .whitespaces)
      results = trimmed.isEmpty ? [] : model.searchResults(matching: trimmed)
      selectDefault()
    }
    .onChange(of: rows.map(\.id)) { _, _ in selectDefault() }
  }

  // MARK: - Chrome

  private var header: some View {
    // The same band as every other mode, so ⌘1 does not move the content down
    // by a different amount than ⌘2 does. The panel mounts this view too, and
    // gets its own two controls on the end of it.
    WorkspacePaneHeader(title: "Today") {
      Text(scopeName)
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .lineLimit(1)
    } trailing: {
      if surface.isPanel {
        if manager.preferences.scoresEachFocusBlock {
          Text("\(FocusPoints.formatted(model.focusPoints.today)) pts")
            .font(theme.numeralFont(theme.scale.caption))
            .foregroundStyle(theme.dim)
            .monospacedDigit()
            .help("Minutes focused today, multiplied by how well each block went")
        }
      } else {
        dayTally
      }
      if surface.isPanel {
        Button { openInWindow() } label: {
          Image(systemName: "macwindow")
            .font(theme.bodyFont())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dim)
        .help("Open the main window (⌘↵)")
        .accessibilityLabel("Open the main window")
        Button { onClose?(.back) } label: {
          Image(systemName: "xmark")
            .font(theme.bodyFont(size: theme.scale.caption))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dim)
        .help("Hide the panel (esc)")
        .accessibilityLabel("Hide the focus panel")
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
      Text(forecast.tallyText)
        .font(theme.monoFont(size: theme.type.microLabel.size))
        .foregroundStyle(forecast.loggedSeconds > 0 || forecast.remainingSeconds > 0 ? theme.muted : theme.dim)
        .monospacedDigit()
        .lineLimit(1)
        .help(forecast.helpText)
    }
  }

  /// What the day is supposed to cost against what it has cost so far. A bar
  /// rather than a second row of numbers: the question it answers is "how far
  /// through", which is a length, not a figure to read.
  private var summary: some View {
    let estimated = dayTasks.reduce(0) { $0 + ($1.estimateSeconds ?? 0) }
    let logged = loggedToday
    let fraction = estimated > 0 ? min(1, Double(logged) / Double(estimated)) : 0
    return VStack(alignment: .leading, spacing: theme.space.xs) {
      // The finish time rides on the estimate it came from, and ticks for the
      // same reason the window's tally does.
      TimelineView(.periodic(from: .now, by: model.isFocusBlockTicking ? 30 : 60)) { context in
        let forecast = model.dayForecast(for: dayTasks, now: context.date)
        HStack(spacing: 0) {
          MicroLabel(forecast.panelLine)
            .lineLimit(1)
            .help(forecast.helpText)
          Spacer(minLength: theme.space.sm)
          MicroLabel(logged > 0 ? "\(duration(logged)) logged" : "Nothing logged yet")
        }
      }
      // Square-ended: a bar is a length, and a rounded end makes the last
      // few percent read as decoration rather than progress.
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Rectangle().fill(theme.well)
          Rectangle()
            .fill(theme.primary)
            .frame(width: max(fraction > 0 ? theme.emphasisBorder : 0, proxy.size.width * fraction))
        }
      }
      .frame(height: theme.space.xs)
      weekLine
    }
    .padding(.horizontal, theme.space.lg)
    .padding(.bottom, theme.space.md)
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
        Spacer(minLength: theme.space.sm)
        MicroLabel(
          "\(duration(progress.week.seconds)) this week · \(duration(progress.averageSecondsPerDay))/day")
      }
      .padding(.top, theme.space.xxs)
    }
  }

  private var field: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: "magnifyingglass")
        .font(theme.bodyFont())
        .foregroundStyle(theme.dim)
      TextField("Search, or type to add a task…", text: $query)
        .textFieldStyle(.plain)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .focused($isFieldFocused)
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
        .onKeyPress(.leftArrow) { leaveForSidebar() }
        .onKeyPress(.escape) { dismissOrClear() }
        // ⌘⌫ is the field's own "delete to the start of the line" while
        // there is text in it; with the field empty there is nothing to
        // delete there, so it takes the task you are on instead.
        .onKeyPress(keys: [.delete], phases: .down) { press in
          guard press.modifiers.contains(.command), query.isEmpty else { return .ignored }
          return deleteSelection() ? .handled : .ignored
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
          if press.modifiers.contains(.command) {
            openInWindow()
          } else if press.modifiers.contains(.shift) {
            tickOffSelection()
          } else {
            activateSelection()
          }
          return .handled
        }
    }
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
    // An input is a hairline on the page, not a well sunk into it.
    .overlay(
      RoundedRectangle(cornerRadius: theme.controlRadius)
        .strokeBorder(isFieldFocused ? theme.focusRing : theme.inputBorder, lineWidth: theme.hairline))
    .padding(.horizontal, theme.space.lg)
    .padding(.bottom, theme.space.md)
  }

  private var hints: some View {
    HStack(spacing: theme.space.md) {
      KeyHint("↑ ↓", "Choose")
      KeyHint("↵", returnHint)
      // Only while it does something: with a query in the field the caret
      // owns left, and advertising a key that is busy is worse than silence.
      if !surface.isPanel && query.isEmpty {
        KeyHint("←", "Lists")
      }
      Spacer(minLength: 0)
      if surface.isPanel {
        KeyHint("esc", !query.isEmpty ? "Clear" : onMinimise != nil ? "Minimise" : "Hide")
      } else if !query.isEmpty {
        KeyHint("esc", "Clear")
      }
    }
    .padding(.horizontal, theme.space.lg)
    .padding(.vertical, theme.space.sm)
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
          // Rows on the one surface, ruled apart, rather than cards stacked
          // on a well: the day is a list to be read down, and a gap between
          // boxes is a second separator doing the hairline's job.
          LazyVStack(spacing: 0) {
            ForEach(rows) { row in
              view(for: row)
                .id(row.id)
            }
            if surface.isPanel {
              if query.isEmpty { addHint }
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
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        HStack(spacing: theme.space.sm) {
          marker(for: task, index: index)
          Text(task.title)
            .font(theme.bodyFont())
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
          if model.isDailyProgressTask(task) {
            DailyBadge(task: task, isDoneToday: model.isDailyProgressComplete(task))
          }
          Spacer(minLength: theme.space.sm)
          if let listName { MicroLabel(listName).lineLimit(1) }
        }
        HStack(spacing: theme.space.sm) {
          // In the window the estimate opens its quick edit: the finish time is
          // only as good as the estimates under it, and "No estimate" was a
          // dead end for anyone not already using the key.
          DayEstimateLabel(
            text: task.estimateSeconds.map { duration($0) } ?? "No estimate",
            help: "Set the time estimate (\(WorkspaceCommandHelpText.firstKey(for: .taskEditEstimate)))",
            action: surface.isPanel ? nil : {
              model.selectedTaskID = task.id
              model.quickEdit(.estimate)
            })
          if let detail {
            Text(detail)
              .font(theme.captionFont)
              .foregroundStyle(theme.dim)
              .lineLimit(1)
          }
          Spacer(minLength: theme.space.sm)
          Text(clock(model.taskLoggedSeconds[task.id] ?? 0))
            .font(theme.numeralFont(theme.scale.caption, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(theme.dim)
        }
      }
    } action: {
      start(task)
    }
  }

  /// A row's number, which becomes the way to tick it off when the pointer is
  /// over it.
  ///
  /// Blitzit's list has a checkbox on every row and this one had nothing: the
  /// day list could start work but not finish it, so anything already done had
  /// to be closed somewhere else. The number and the tick share one slot
  /// because the row is narrow and they are never both wanted at once.
  private func marker(for task: WorkspaceTask, index: Int?) -> some View {
    let isHovering = hoveredID == task.id
    return Button {
      tickOff(task)
    } label: {
      Group {
        if isHovering {
          Image(systemName: "checkmark.circle")
            .font(theme.bodyFont())
            .foregroundStyle(theme.success)
        } else if let index {
          Text("\(index)")
            .font(theme.numeralFont(theme.scale.caption))
            .monospacedDigit()
            .foregroundStyle(theme.dim)
        } else {
          Image(systemName: "circle")
            .font(theme.captionFont)
            .foregroundStyle(theme.dim)
        }
      }
      .frame(width: 14, alignment: .trailing)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .help("Tick off without running a block (⇧↵)")
    .accessibilityLabel("Tick off \(task.title)")
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

  /// Deletes the selected task and lands on its neighbour, so a run of
  /// ⌘⌫ clears a run of rows. Never the running block: that one ends
  /// through its own finish, not by vanishing from under the clock.
  private func deleteSelection() -> Bool {
    guard let id = selectedID, id != Self.createRowID, id != activeTaskID,
      let task = model.task(withID: id) else { return false }
    let ids = rows.map(\.id)
    let neighbour = ids.firstIndex(of: id).flatMap { index in
      ids.indices.contains(index + 1) ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
    }
    model.deleteTask(task)
    selectedID = neighbour
    return true
  }

  private func tickOffSelection() {
    guard let id = selectedID, id != Self.createRowID, let task = model.task(withID: id) else { return }
    if id == activeTaskID { finish(); return }
    tickOff(task)
  }

  /// The row you are on. Same card, grown: a live clock, and the controls that
  /// only ever apply to the task actually running.
  private func activeCard(task: WorkspaceTask, index: Int?, session: FocusSession) -> some View {
    card(id: task.id, isActive: true) {
      VStack(alignment: .leading, spacing: theme.space.sm) {
        HStack(spacing: theme.space.sm) {
          if let index {
            Text("\(index)")
              .font(theme.numeralFont(theme.scale.caption))
              .monospacedDigit()
              .foregroundStyle(theme.primary)
              .frame(minWidth: 12, alignment: .trailing)
          }
          Text(task.title)
            .font(theme.titleFont)
            .foregroundStyle(theme.ink)
            .lineLimit(2)
          Spacer(minLength: theme.space.sm)
          if let list = model.list(for: task) { MicroLabel(list.name).lineLimit(1) }
        }
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
        controlStrip(session: session)
      }
    } action: {
      // Clicking is choosing, never finishing: a stray click on the row you
      // are working through closed the block. Done is its own button.
    }
  }

  /// Blitzit's strip, in Priority's vocabulary: pause, skip to the next queued
  /// task, log the time without closing anything, and tick it off.
  private func controlStrip(session: FocusSession) -> some View {
    HStack(spacing: theme.space.xs) {
      control(session.pausedAt == nil ? "pause.fill" : "play.fill",
        session.pausedAt == nil ? "Pause" : "Resume") { model.toggleFocusPause() }
      control("forward.end.fill", "Skip to the next task in the queue") { skip() }
        .disabled(!hasQueuedSuccessor)
      control("clock.arrow.circlepath", "Log the time so far and leave the task open") { logProgress() }
      if let onMinimise {
        control("arrow.down.right.and.arrow.up.left", "Minimise to the task and its clock (esc)") { onMinimise() }
      }
      Spacer(minLength: 0)
      Button { finish() } label: {
        Label("Done", systemImage: "checkmark")
      }
      .buttonStyle(FocusActionButtonStyle(prominent: true))
      .focusable(false)
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
    return card(id: row.id) {
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
    } action: {
      createFromQuery()
    }
  }

  private var addHint: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: "plus")
        .font(theme.bodyFont(size: theme.scale.caption))
      MicroLabel("Add task")
      Spacer(minLength: 0)
      Text("type a title, then ↵")
        .font(theme.captionFont)
    }
    .foregroundStyle(theme.dim)
    .padding(.horizontal, theme.space.lg)
    .padding(.vertical, theme.space.sm)
    .contentShape(Rectangle())
    .onTapGesture { isFieldFocused = true }
  }

  /// The side padding inside a row. In the window, the pane's gutter, so a
  /// task's title starts under the header's "Today" the way the outline's
  /// start under its list name; the panel keeps its own narrower figure,
  /// being a small floating surface rather than a pane.
  private var rowGutter: CGFloat { surface.isPanel ? theme.space.lg : theme.paneGutter }

  /// Above and below a row's content. The window uses the rows' shared
  /// figure, so a two-line day row is as dense as two outline rows.
  private var rowPadding: CGFloat { surface.isPanel ? theme.space.sm : theme.rowVerticalPadding }

  /// One row shape for every row, so a row that gains controls is visibly the
  /// same row rather than a different kind of thing.
  ///
  /// Flat on the page with a hairline under it. What a row *is* reads from a
  /// tint of the matching hue: the running one in primary, the one under the
  /// cursor in the selection fill, the one being finished in success — never
  /// a raised card or a stock accent.
  private func card<Content: View>(
    id: String, isActive: Bool = false, @ViewBuilder content: () -> Content,
    action: @escaping () -> Void
  ) -> some View {
    let isSelected = id == cursorID
    // In the window the cursor row carries the same hairline in the focus
    // colour as every other pane's while the keyboard is on the tasks. The
    // panel has one region, so its fill says it all.
    let hasKeyboard = isSelected && !surface.isPanel && model.keyboardFocusArea == .tasks
    // The card being finished takes whatever the active celebration preset
    // does to a row, so the tick, the tint and the collapse are the same
    // gesture here as on the focus ladder.
    let phase = celebrationPhase(forTaskID: id)
    let treatment = manager.celebration.rowTreatment
    let celebrating = phase != .idle
    let isHovered = hoveredID == id
    let fill: Color =
      celebrating ? theme.success.opacity(treatment.tintOpacity)
      : isSelected ? theme.selectionFill
      : isActive ? theme.primary.opacity(Theme.statusFillOpacity)
      : isHovered ? theme.hover : Color.clear
    return content()
      .padding(.horizontal, rowGutter)
      .padding(.vertical, rowPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .scaleEffect(treatment.rowScale(for: phase))
      .background(fill)
      // The running row keeps a primary edge even under the cursor, so the
      // selection never hides which task is the one on the clock.
      .overlay(alignment: .leading) {
        if isActive || celebrating {
          Rectangle()
            .fill(celebrating ? theme.success : theme.primary)
            .frame(width: theme.emphasisBorder)
        }
      }
      .overlay(alignment: .bottom) { FocusRule() }
      .overlay {
        if hasKeyboard {
          Rectangle().strokeBorder(theme.focusRing, lineWidth: theme.hairline)
        }
      }
      .overlay { rowAccent(forTaskID: id) }
      .opacity(treatment.fades && phase == .celebrating ? 0 : 1)
      .contentShape(Rectangle())
      .onHover { inside in
        if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
      }
      .onTapGesture { setCursor(id); action() }
  }

  /// `.idle` for every card but the one actually being finished. A daily is
  /// celebrated under its own identity, so the lookup has to go through the
  /// task rather than assume the two ids are the same.
  private func celebrationPhase(forTaskID id: String) -> CelebrationPhase {
    guard let task = model.task(withID: id) else { return .idle }
    return manager.celebration.phase(for: completionKind(for: task))
  }

  @ViewBuilder
  private func rowAccent(forTaskID id: String) -> some View {
    if celebrationPhase(forTaskID: id) != .idle, let task = model.task(withID: id) {
      manager.celebration.rowAccent(for: completionKind(for: task))
        .allowsHitTesting(false)
    }
  }

  private func completionKind(for task: WorkspaceTask) -> CompletionKind {
    model.dailyItem(for: task).map { .daily(id: $0.daily.id) } ?? .workspaceTask(id: task.id)
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

  private var scopeName: String {
    model.isEverythingSelected ? "Everything" : (model.selectedList?.name ?? "Workspace")
  }

  private var activeTaskID: String? { model.activeFocusTask?.id }

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
    isFieldFocused = true
    selectedID = activeTaskID ?? rows.first?.id
  }

  private func selectDefault() {
    let ids = rows.map(\.id)
    if let cursorID, ids.contains(cursorID) { return }
    // In the window only while the pane has the keyboard: a task selected in
    // the sidebar's list, or left by another mode, is not the day's to take.
    if !surface.isPanel && model.keyboardFocusArea != .tasks { return }
    if surface.isPanel { selectedID = ids.first } else { model.selectedTaskID = ids.first }
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
      model.leaveFullPaneScreens()
    }
  }

  // MARK: - Formatting

  /// Hours and minutes, never seconds: an estimate measured to the second is
  /// a precision nobody typed in.
  private func duration(_ seconds: Int) -> String {
    DayForecast.hoursAndMinutes(seconds)
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
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let isDoneToday: Bool

  var body: some View {
    Button {
      model.toggleDailyProgress(task)
    } label: {
      Image(systemName: isDoneToday ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
        .font(theme.bodyFont(size: theme.type.microLabel.size))
        .foregroundStyle(isDoneToday ? theme.success : theme.muted)
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
