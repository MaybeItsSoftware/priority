import PriorityCore
import PriorityWorkspace
import SwiftUI

/// What the summoned panel shows: a field you are already typing into, and
/// under it either the block you are running or the shortlist of what to start.
///
/// The field is always there and always first responder, because the fastest
/// path to a task is its name and the panel cannot know in advance whether you
/// summoned it to check the clock or to go and find something.
struct FocusPanelView: View {
  @Environment(WorkspaceViewModel.self) private var model
  let onDismiss: () -> Void

  @State private var query = ""
  @State private var results: [TaskSearchResult] = []
  @State private var selectedID: String?
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      field
      FocusRule()
      content
      FocusRule()
      hints
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .overlay(
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    .onAppear {
      isFieldFocused = true
      selectDefault()
    }
    .onChange(of: query) { _, new in
      let trimmed = new.trimmingCharacters(in: .whitespaces)
      results = trimmed.isEmpty ? [] : model.searchResults(matching: trimmed)
      selectDefault()
    }
    .onChange(of: model.focusLadder.map(\.id)) { _, _ in selectDefault() }
  }

  // MARK: - The field

  private var field: some View {
    HStack(spacing: 10) {
      Image(systemName: isRunning && query.isEmpty ? "timer" : "magnifyingglass")
        .font(.system(size: 15))
        .foregroundStyle(isRunning && query.isEmpty ? Color.accentColor : .secondary)
      TextField(fieldPrompt, text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 19))
        .focused($isFieldFocused)
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
        .onKeyPress(.escape) { dismissOrClear(); return .handled }
        .onKeyPress(keys: [.return], phases: .down) { press in
          if press.modifiers.contains(.command) { revealSelection() } else { act() }
          return .handled
        }
      Text("\(FocusPoints.formatted(model.focusPoints.today)) pts")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .help("Minutes focused today, multiplied by how well each block went")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  private var fieldPrompt: String {
    if isRunning { return "Search to queue something else…" }
    return "Search every task, or pick one below…"
  }

  // MARK: - Body states

  @ViewBuilder
  private var content: some View {
    if isRunning, query.isEmpty, let session = model.activeFocusSession, let task = model.activeFocusTask {
      running(session: session, task: task)
    } else if picks.isEmpty {
      empty
    } else {
      list
    }
  }

  private var empty: some View {
    VStack(spacing: 6) {
      Spacer()
      Text(query.isEmpty ? "Nothing is available right now" : "No matches")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(query.isEmpty
        ? "No task fits the current conditions, start times and available time."
        : "Try part of a title, or a word from the notes.")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(picks) { pick in
            row(pick)
              .id(pick.id)
              .contentShape(Rectangle())
              .onTapGesture { selectedID = pick.id; act() }
          }
        }
        .padding(.vertical, 6)
      }
      .onChange(of: selectedID) { _, id in
        guard let id else { return }
        proxy.scrollTo(id, anchor: .center)
      }
    }
  }

  private func row(_ pick: FocusPanelPick) -> some View {
    let isSelected = pick.id == selectedID
    return HStack(spacing: 10) {
      Image(systemName: pick.icon)
        .font(.system(size: 13))
        .foregroundStyle(pick.tint)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(pick.title)
          .font(.system(size: 14, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
        if let detail = pick.detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 12)
      if let listName = pick.listName {
        MicroLabel(listName)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 9)
    .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
    .overlay(alignment: .leading) {
      if isSelected {
        Rectangle().fill(Color.accentColor).frame(width: 2)
      }
    }
  }

  /// The running block, cut down to what you summoned the panel to see: what
  /// you are on, how long it has been, and the one key that ends it.
  private func running(session: FocusSession, task: WorkspaceTask) -> some View {
    VStack(spacing: 14) {
      Spacer(minLength: 0)
      if let list = model.list(for: task) { MicroLabel(list.name) }
      Text(task.title)
        .font(.system(size: 21, weight: .semibold))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let reading = FocusTimerDisplay.reading(
          elapsed: TimeInterval(session.elapsedSeconds(now: context.date)),
          planned: TimeInterval(session.workDurationSeconds))
        VStack(spacing: 4) {
          Text(reading.text)
            .font(.system(size: 54, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(session.pausedAt == nil
              ? (reading.isOverrun ? Color.orange : Color.accentColor) : Color.secondary)
            .contentTransition(.numericText())
          MicroLabel(session.pausedAt == nil ? "of \(plannedMinutes(session))m" : "paused",
            tint: session.pausedAt == nil ? nil : Color.orange)
        }
      }
      HStack(spacing: 8) {
        Button {
          model.toggleFocusPause()
        } label: {
          Label(session.pausedAt == nil ? "Pause" : "Resume",
            systemImage: session.pausedAt == nil ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.bordered)
        .focusable(false)
        Button {
          finish()
        } label: {
          Label("Done", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .focusable(false)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
  }

  private func plannedMinutes(_ session: FocusSession) -> String {
    FocusPoints.formatted(Double(session.workDurationSeconds) / 60)
  }

  // MARK: - Hints

  private var hints: some View {
    HStack(spacing: 14) {
      if isRunning, query.isEmpty {
        KeyHint("↵", "Done")
        KeyHint("⌘↵", "Open in window")
      } else {
        KeyHint("↑ ↓", "Choose")
        KeyHint("↵", isRunning ? "Queue it" : "Start focus")
        KeyHint("⌘↵", "Open in window")
      }
      Spacer(minLength: 0)
      KeyHint("esc", query.isEmpty ? "Close" : "Clear")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  // MARK: - What is on offer

  private var isRunning: Bool { model.activeFocusSession != nil && model.activeFocusTask != nil }

  /// The ladder when there is no query, matches when there is. Capped because
  /// this is a shortlist to act on, not a list to read.
  private var picks: [FocusPanelPick] {
    if query.trimmingCharacters(in: .whitespaces).isEmpty {
      return model.focusLadder.prefix(8).map { scored in
        FocusPanelPick(
          id: scored.candidate.id,
          title: scored.candidate.title,
          listName: model.task(withID: scored.candidate.id).flatMap { model.list(for: $0)?.name },
          detail: model.focusExplanation(scored).localizedCapitalized,
          icon: Self.icon(for: scored.reason),
          tint: Self.tint(for: scored.reason))
      }
    }
    return results.prefix(12).map { result in
      FocusPanelPick(
        id: result.task.id,
        title: result.task.title,
        listName: result.list.name,
        detail: result.notesSnippet,
        icon: result.task.status == .completed ? "checkmark.circle" : "circle",
        tint: .secondary)
    }
  }

  private func selectDefault() {
    let ids = picks.map(\.id)
    if let selectedID, ids.contains(selectedID) { return }
    selectedID = ids.first
  }

  private func move(by offset: Int) {
    let ids = picks.map(\.id)
    guard !ids.isEmpty else { return }
    let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
    selectedID = ids[min(max(0, current + offset), ids.count - 1)]
  }

  // MARK: - Acting

  private func dismissOrClear() {
    if query.isEmpty { onDismiss() } else { query = "" }
  }

  /// Return. What it does depends on what the panel is showing, which is the
  /// point: one key, always the obvious thing.
  private func act() {
    if isRunning, query.isEmpty { finish(); return }
    guard let id = selectedID, let task = model.task(withID: id) else { return }
    if isRunning {
      // A session is already running, so a second pick joins the queue rather
      // than interrupting the block that is underway.
      model.addToFocusQueue(task)
      query = ""
      return
    }
    // Summoning a task by name is an explicit choice, so it is started even if
    // the conditions would not have offered it — the alert that would ask
    // about that lives in the main window, which is not on screen here.
    model.startFocus(on: task, override: true)
    onDismiss()
  }

  /// Done. The quality prompt is a sheet in the main window, so the window has
  /// to come with it — there is one prompt, and it lives there.
  private func finish() {
    model.requestFocusCompletion()
    onDismiss()
    AppDelegate.shared.showMainWindow()
  }

  private func revealSelection() {
    AppDelegate.shared.showMainWindow()
    if isRunning, query.isEmpty {
      model.presentFocusScreen()
    } else if let id = selectedID, let result = results.first(where: { $0.task.id == id }) {
      model.reveal(result)
    } else if let id = selectedID, let task = model.task(withID: id) {
      model.selectTask(task)
      model.dismissFocusScreen()
    }
    onDismiss()
  }

  // MARK: - Reason vocabulary

  private static func icon(for reason: NextUpReason) -> String {
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

  private static func tint(for reason: NextUpReason) -> Color {
    switch reason {
    case .daily: return .green
    case .overdue: return .red
    case .dueToday, .dueSoon, .deadlineRisk: return .orange
    case .condition, .started, .today: return .accentColor
    case .importance, .priority: return .purple
    case .order: return .secondary
    }
  }
}

/// One offered task, however it was found. The ladder and the search index
/// produce different shapes; the row only ever sees this one.
private struct FocusPanelPick: Identifiable {
  let id: String
  let title: String
  let listName: String?
  let detail: String?
  let icon: String
  let tint: Color
}
