import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The way into the focus screen, sitting above the lists.
///
/// It shows what it would start on, because a button that hides its own
/// consequence gets pressed once and then avoided. When a session is already
/// running it becomes the way back to it rather than a second start.
struct WorkspaceFocusLauncher: View {
  @Environment(WorkspaceViewModel.self) private var model
  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        model.sidebarCursorID = "row:focus"
        model.presentFocusScreen()
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Image(systemName: model.activeFocusSession == nil ? "target" : "timer")
              .font(.system(size: 11, weight: .semibold))
            MicroLabel(
              model.activeFocusSession == nil ? "Focus" : "In session",
              tint: model.activeFocusSession == nil ? .secondary : Color.accentColor)
            Spacer(minLength: 0)
            KeyCap("⌘8")
          }
          .foregroundStyle(model.activeFocusSession == nil ? .secondary : Color.accentColor)

          Text(headline)
            .font(.callout.weight(.medium))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.primary)

          if let detail {
            Text(detail)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
          isHovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03),
          in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        // Focus is a sidebar row, so it takes the sidebar's cursor ring. It
        // could not be highlighted at all before, which is most of why
        // arrowing up onto it felt like arrowing into nothing.
        .overlay(WorkspaceSidebarSelectionBackground(rowID: "row:focus"))
        .contentShape(RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .focusable()
      .onHover { isHovering = $0 }
      .help(model.activeFocusSession == nil ? "Start a focus session on your next task" : "Return to the running session")
      .accessibilityLabel(model.activeFocusSession == nil ? "Start focus. Next up: \(headline)" : "Return to focus session")
      Button {
        model.sidebarCursorID = "row:timeline"
        model.presentTimelineScreen()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chart.bar.doc.horizontal")
            .font(.system(size: 11, weight: .semibold))
          MicroLabel("Timeline", tint: model.showsTimelineScreen ? Color.accentColor : .secondary)
          Spacer(minLength: 0)
          KeyCap("⌘9")
        }
        .foregroundStyle(model.showsTimelineScreen ? Color.accentColor : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WorkspaceSidebarSelectionBackground(
          isCurrent: model.showsTimelineScreen, rowID: "row:timeline"))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable()
      .help("See where the day's focused time went")
    }
  }

  private var headline: String {
    if let active = model.activeFocusTask { return active.title }
    return model.nextUp?.candidate.title ?? "Nothing to pick up"
  }

  private var detail: String? {
    if model.activeFocusSession != nil { return "Session running" }
    guard let scored = model.nextUp else { return "Add a task or a daily to get started" }
    return model.focusExplanation(scored).localizedCapitalized
  }
}

/// Focus mode: one task, centred, with everything you have already been
/// through drifting up and away above it.
///
/// The column is a single file of work. The task you are on sits in the middle
/// of the pane; the ones you have passed stack above it and recede. Acting on
/// the current task moves the whole column up by one, so the screen reads as
/// progress rather than as a list you are indexing into.
struct WorkspaceFocusScreen: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(AppCoordinator.self) private var manager

  /// How much history stays on screen. Enough to feel the run you are on,
  /// few enough that it never becomes something to read.
  private static let historyDepth = 4
  /// How many still to come are hinted at below.
  private static let previewDepth = 2
  /// What a rung shrinks to once you are not on it. Big enough that history
  /// stays readable, small enough that the current rung is unmistakable.
  private static let passedScale = 0.62
  /// The height a shrunken rung occupies, so the scale does not leave a hole.
  private static let passedRowHeight: CGFloat = 26

  var body: some View {
    VStack(spacing: 0) {
      header
      FocusRule()
      staleNotice
      // One screen, two states: choosing what to do, and then doing it. They
      // were a pane and a sheet before, which made returning to a running
      // session a different gesture from starting one.
      if let session = model.activeFocusSession, let task = model.activeFocusTask {
        WorkspaceFocusRunning(session: session, task: task)
      } else {
        chooser
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
    // Over the whole screen rather than the rung: the rung it belongs to is
    // gone by the time this plays, and a cleared ladder is exactly when the
    // flourish has the most to say.
    .onChange(of: model.focusCompletionRequest) { _, _ in tickOff() }
    .overlay {
      if let flourish = manager.celebration.activeFlourish?.view {
        flourish
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
  }

  /// Plays the chosen preset, then mutates — in that order, because the preset
  /// is allowed to cancel. Cancelling means the row stays, so the tick has to
  /// wait on it rather than race it.
  private func tickOff() {
    guard let event = model.focusCompletionEvent() else { return }
    Task {
      guard await manager.celebration.runInline(event) else { return }
      model.completeFocusLadderSelection()
      manager.celebration.presentFlourish(for: event)
    }
  }

  // MARK: - Chrome

  private var isRunning: Bool { model.activeFocusSession != nil && model.activeFocusTask != nil }

  /// Says what launch did with the block left over from last time.
  ///
  /// Quitting pauses the running block, so every quit leaves one behind. The
  /// app now settles it on the way back in rather than restoring a session
  /// from a day that is over — but a block that quietly vanished is its own
  /// small mystery, and this is the screen you would come looking for it on.
  @ViewBuilder private var staleNotice: some View {
    if model.staleFocusResolution != .keep {
      HStack(spacing: 8) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 11, weight: .semibold))
        Text(
          model.staleFocusResolution == .close
            ? "A block left paused on an earlier day was closed out. Its time is on the timeline for that day."
            : "A block left paused on an earlier day was ended. It had no time on it to keep.")
          .font(.caption)
        Spacer(minLength: 0)
        Button("Dismiss") { model.staleFocusResolution = .keep }
          .buttonStyle(.plain)
          .font(.caption)
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      FocusRule()
    }
  }

  /// The same bar in both states, so leaving is always in the same place and
  /// the day's total never moves out from under you.
  private var header: some View {
    HStack(spacing: 12) {
      MicroLabel(isRunning ? "In session" : "Focus", tint: isRunning ? Color.accentColor : nil)
      Spacer(minLength: 0)
      Text("\(FocusPoints.formatted(model.focusPoints.today)) pts today")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .help("Minutes focused, multiplied by how well each block went")
      Button { model.presentTimelineScreen() } label: {
        Image(systemName: "chart.bar.doc.horizontal")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .focusable()
      .help("See where the day's focused time went (⌘9)")
      Button("Leave") { model.dismissFocusScreen() }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .focusable()
      KeyCap("esc")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
  }

  /// Picking the next thing: the conditions it has to satisfy, the ladder of
  /// what qualifies, and what is currently ruled out.
  private var chooser: some View {
    VStack(spacing: 0) {
      WorkspaceFocusContextControls()
        .padding(.horizontal, 24)
        .padding(.top, 12)
      if model.focusLadder.isEmpty {
        emptyState
      } else {
        column
      }
      if !model.blockedFocusTasks.isEmpty {
        blocked
      }
      FocusRule()
      footer
    }
  }

  private var blocked: some View {
    DisclosureGroup("\(model.blockedFocusTasks.count) tasks unavailable") {
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(model.blockedFocusTasks) { blocked in
            Button {
              if let task = model.task(withID: blocked.id) {
                model.selectTask(task)
                model.showsFocusScreen = false
                model.isInspectorVisible = true
              }
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(blocked.candidate.title).font(.caption.weight(.medium))
                let urgency = NextUpSelector.score(blocked.candidate)
                if [.overdue, .dueToday, .deadlineRisk].contains(urgency.reason) {
                  Text(urgency.explanation).font(.caption2).foregroundStyle(model.themeColor(.warning))
                }
                Text(blocked.reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
                  .font(.caption2).foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.plain)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 100)
    }
    .font(.caption)
    .padding(.horizontal, 24)
    .padding(.bottom, 8)
  }

  private var footer: some View {
    HStack(spacing: 14) {
      Spacer()
      KeyHint("↑ ↓", "Move through")
      KeyHint("⌥ ↑ ↓", "Reorder within urgency")
      if model.hasManualFocusOrder {
        Button("Reset order") { model.clearManualFocusOrder() }
          .buttonStyle(.plain)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .focusable()
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "Nothing waiting",
      systemImage: "checkmark.circle",
      description: Text("No task matches the current conditions, start times and available time."))
      .frame(maxHeight: .infinity)
  }

  // MARK: - The column

  private var column: some View {
    let index = model.focusLadderIndex
    let historyTop = min(model.focusLadder.count - 1, index + Self.historyDepth)
    let previewEnd = max(0, index - Self.previewDepth)
    let visible = stride(from: historyTop, through: previewEnd, by: -1)
      .compactMap { model.focusLadder[safe: $0] }

    return VStack(spacing: 0) {
      Spacer(minLength: 12)
      // One view type for every rung, keyed by the task rather than by its
      // position. That is what lets a rung you climb past *travel* to where it
      // ends up: keyed by position, each row keeps its identity and swaps its
      // contents instead, which is the teleporting.
      ForEach(visible, id: \.candidate.id) { scored in
        rung(scored)
          .transition(.opacity)
      }
      Spacer(minLength: 12)
    }
    .frame(maxWidth: .infinity)
    // One spring for the whole column, so history slides up as a body rather
    // than each row animating on its own account.
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.focusLadderIndex)
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.stagedTaskID)
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.focusLadder.count)
  }

  /// Every rung is the same view; how far it sits from the cursor decides how
  /// big it is and how much of itself it shows.
  ///
  /// The title is always set at one size and *scaled*, rather than given a
  /// smaller font when it is not current. Fonts do not interpolate — swapping
  /// `.callout` for `.title` is a jump cut however long the animation is — but
  /// a scale factor and a row height are both numbers, so both can be sprung.
  private func rung(_ scored: ScoredNextUp) -> some View {
    let distance = rungOffset(to: scored)
    let isCurrent = distance == 0
    let task = isCurrent ? model.focusLadderTask : nil

    // The active preset decides what completing looks like; this screen only
    // says which rung it is happening to. Multiplying the treatment's scale
    // into the ladder's own keeps the two independent — a rung being completed
    // while you climb past it still shrinks.
    let phase = celebrationPhase(for: scored)
    let treatment = manager.celebration.rowTreatment
    let scale = (isCurrent ? 1 : Self.passedScale) * treatment.rowScale(for: phase)
    let tint = manager.preferences.themeColor(for: .success)
    let celebrating = phase != .idle

    return VStack(spacing: 10) {
      // The reason line rises out of the title rather than appearing above it.
      if isCurrent {
        reasonLine(scored, task: task)
          .transition(.opacity.combined(with: .offset(y: 8)))
      }

      HStack(spacing: 10) {
        // The icon becomes the tick it is about to earn, and pops as it does.
        Image(systemName: celebrating ? "checkmark.circle.fill" : icon(for: scored.reason))
          .font(.system(size: 20))
          .foregroundStyle(celebrating ? tint : (isCurrent ? self.tint(for: scored.reason) : Color.secondary))
          .scaleEffect(treatment.iconScale(for: phase))
        Text(scored.candidate.title)
          .font(.system(size: 28, weight: .semibold))
          .multilineTextAlignment(.center)
          .lineLimit(isCurrent ? 3 : 1)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: isCurrent)
          .strikethrough(treatment.drawsStrikethrough && phase == .celebrating, color: tint)
      }
      .scaleEffect(scale, anchor: .center)
      // Scaling alone leaves a full-height gap behind a shrunken row, so the
      // row's own height comes down with it. Both are numbers; both spring.
      .frame(height: isCurrent ? nil : Self.passedRowHeight)

      if isCurrent {
        details(scored, task: task)
          .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
      }
    }
    .foregroundStyle(isCurrent ? .primary : .secondary)
    .background {
      if celebrating {
        RoundedRectangle(cornerRadius: 12)
          .fill(tint.opacity(treatment.tintOpacity))
      }
    }
    .opacity(opacity(forDistance: distance) * (treatment.fades && phase == .celebrating ? 0 : 1))
    // A preset that collapses takes the row's height with it, so the ladder
    // closes over the gap instead of leaving one.
    .frame(maxWidth: 620)
    .frame(height: treatment.collapses && phase == .celebrating ? 0 : nil)
    .padding(.vertical, isCurrent ? 20 : 3)
    .overlay { rowAccent(for: scored) }
    .contentShape(Rectangle())
    .onTapGesture { model.moveFocusLadder(by: distance) }
  }

  /// `.idle` for every rung but the one actually being completed.
  private func celebrationPhase(for scored: ScoredNextUp) -> CelebrationPhase {
    guard let task = model.focusLadderTask, task.id == scored.candidate.id else { return .idle }
    let kind: CompletionKind = model.dailyItem(for: task)
      .map { .daily(id: $0.daily.id) } ?? .workspaceTask(id: task.id)
    return manager.celebration.phase(for: kind)
  }

  @ViewBuilder
  private func rowAccent(for scored: ScoredNextUp) -> some View {
    if celebrationPhase(for: scored) != .idle,
      let task = model.focusLadderTask,
      task.id == scored.candidate.id
    {
      let kind: CompletionKind = model.dailyItem(for: task)
        .map { .daily(id: $0.daily.id) } ?? .workspaceTask(id: task.id)
      manager.celebration.rowAccent(for: kind)
        .allowsHitTesting(false)
    }
  }

  /// Legible rather than faint. These are the things you just dealt with, and a
  /// history you cannot read is only decoration — so the ramp is shallow and
  /// does not start until a few rungs out.
  private func opacity(forDistance distance: Int) -> Double {
    let steps = max(0, abs(distance) - 1)
    return max(0.5, 1 - Double(steps) * 0.11)
  }

  private func reasonLine(_ scored: ScoredNextUp, task: WorkspaceTask?) -> some View {
    HStack(spacing: 7) {
      Text(model.focusExplanation(scored).localizedCapitalized)
        .font(.caption.weight(.medium))
      if let task, let list = model.list(for: task) {
        Text("·").foregroundStyle(.tertiary)
        Text(list.name).font(.caption).foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(tint(for: scored.reason))
  }

  @ViewBuilder
  private func details(_ scored: ScoredNextUp, task: WorkspaceTask?) -> some View {
    let isStaged = model.stagedTask?.id == scored.candidate.id
    VStack(spacing: 12) {
      if let meta = metaLine(for: scored, task: task) {
        Text(meta)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if isStaged {
        estimatePicker
        stagedActions
      } else {
        unstagedActions
      }
    }
  }

  private func rungOffset(to scored: ScoredNextUp) -> Int {
    guard let target = model.focusLadder.firstIndex(where: { $0.candidate.id == scored.candidate.id })
    else { return 0 }
    return target - model.focusLadderIndex
  }

  private func metaLine(for scored: ScoredNextUp, task: WorkspaceTask?) -> String? {
    var parts: [String] = []
    if let day = scored.candidate.dueDate { parts.append("Due \(day)") }
    if let due = scored.candidate.dueAt {
      parts.append("Due \(due.formatted(.relative(presentation: .named)))")
    }
    if let estimate = scored.candidate.remainingSeconds {
      parts.append(estimate > 0 ? "~\(FocusPoints.formatted(Double(estimate) / 60))m remaining" : "Estimate exhausted")
    }
    if let task, let item = model.dailyItem(for: task), item.secondsLoggedToday > 0 {
      parts.append("\(item.secondsLoggedToday / 60)m done today")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Actions

  /// Each action carries its key, because the key is how it will actually be
  /// used once the screen is familiar — and a shortcut you have to go and look
  /// up is a shortcut nobody learns.
  private var unstagedActions: some View {
    HStack(spacing: 8) {
      actionButton("Stage this", systemImage: "target", key: "↵", prominent: true) {
        model.stageFocusLadderSelection()
      }
      actionButton("Tick off", systemImage: "checkmark", key: "X") {
        tickOff()
      }
      HStack(spacing: 0) {
        actionButton("Later", systemImage: "clock", key: "L") {
          model.deferFocusLadderSelection()
        }
        Menu {
          ForEach(WorkspaceDeferral.allCases) { option in
            Button(option.title) { model.deferFocusLadderSelection(option) }
          }
        } label: {
          EmptyView()
        }
        .menuStyle(.borderlessButton)
        .frame(width: 14)
        .help("Choose when")
      }
    }
  }

  private var stagedActions: some View {
    HStack(spacing: 8) {
      actionButton("Begin", systemImage: "play.fill", key: "↵", prominent: true) {
        model.beginStagedFocus()
      }
      actionButton("Back", systemImage: "chevron.left", key: "esc") {
        model.unstageFocusTask()
      }
    }
  }

  @ViewBuilder
  private func actionButton(
    _ title: String, systemImage: String, key: String, prominent: Bool = false, action: @escaping () -> Void
  ) -> some View {
    let label = HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(title)
      Text(key)
        .font(.system(size: 10, design: .monospaced))
        .opacity(0.65)
    }
    if prominent {
      Button(action: action) { label }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .focusable()
    } else {
      Button(action: action) { label }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .focusable()
    }
  }

  private var estimatePicker: some View {
    VStack(spacing: 8) {
      MicroLabel("How long?")
      HStack(spacing: 6) {
        ForEach([5, 10, 15, 25, 45, 60, 90], id: \.self) { minutes in
          Button("\(minutes)m") { model.focusEstimateMinutes = Double(minutes) }
            .buttonStyle(.bordered)
            .tint(model.focusEstimateMinutes == Double(minutes) ? Color.accentColor : Color.secondary)
            .focusable()
        }
      }
      Stepper(
        "\(FocusPoints.formatted(model.focusEstimateMinutes)) minutes",
        value: Bindable(model).focusEstimateMinutes, in: 1...480, step: 5)
        .fixedSize()
    }
  }

  // MARK: - Reason vocabulary

  private func icon(for reason: NextUpReason) -> String {
    switch reason {
    case .daily: return "arrow.triangle.2.circlepath"
    case .overdue: return "exclamationmark.triangle.fill"
    case .dueToday: return "calendar.badge.exclamationmark"
    case .dueSoon: return "calendar"
    case .today: return "sun.max"
    case .importance: return "star.fill"
    case .priority: return "flag.fill"
    case .order: return "list.bullet"
    case .condition: return "location.fill"
    case .started: return "clock.badge.checkmark"
    case .deadlineRisk: return "hourglass"
    }
  }

  private func tint(for reason: NextUpReason) -> Color {
    switch reason {
    // Status reads from the theme's four-way convention, so a retheme moves
    // these with everything else. Purple stays a literal: it is categorical
    // colour — "this one matters" — and has no status token to belong to.
    case .daily: return model.themeColor(.success)
    case .overdue: return model.themeColor(.danger)
    case .dueToday, .dueSoon, .deadlineRisk: return model.themeColor(.warning)
    case .condition, .started: return .accentColor
    case .today: return .accentColor
    case .importance, .priority: return .purple
    case .order: return .secondary
    }
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

enum WorkspaceDeferral: String, CaseIterable, Identifiable {
  case anHour
  case thisAfternoon
  case tomorrow
  case nextWeek

  var id: String { rawValue }

  var title: String {
    switch self {
    case .anHour: return "In an hour"
    case .thisAfternoon: return "This afternoon"
    case .tomorrow: return "Tomorrow morning"
    case .nextWeek: return "Next week"
    }
  }

  func date(from now: Date, calendar: Calendar = .current) -> Date {
    switch self {
    case .anHour:
      return now.addingTimeInterval(3_600)
    case .thisAfternoon:
      let afternoon = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now
      // Already past two o'clock: an hour from now is the honest reading.
      return afternoon > now ? afternoon : now.addingTimeInterval(3_600)
    case .tomorrow:
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    case .nextWeek:
      let week = calendar.date(byAdding: .day, value: 7, to: now) ?? now
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: week) ?? week
    }
  }
}
