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
    Button {
      if model.activeFocusSession != nil {
        model.showsFocusPanel = true
      } else {
        model.presentFocusScreen()
      }
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: model.activeFocusSession == nil ? "target" : "timer")
          Text(model.activeFocusSession == nil ? "FOCUS" : "IN SESSION")
            .font(.caption2.weight(.bold))
            .tracking(1.2)
          Spacer(minLength: 0)
          Text("⌘8")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
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
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .focusable()
    .onHover { isHovering = $0 }
    .help(model.activeFocusSession == nil ? "Start a focus session on your next task" : "Return to the running session")
    .accessibilityLabel(model.activeFocusSession == nil ? "Start focus. Next up: \(headline)" : "Return to focus session")
  }

  private var headline: String {
    if let active = model.activeFocusTask { return active.title }
    return model.nextUp?.candidate.title ?? "Nothing to pick up"
  }

  private var detail: String? {
    if model.activeFocusSession != nil { return "Session running" }
    guard let reason = model.nextUp?.reason else { return "Add a task or a daily to get started" }
    return reason.explanation.localizedCapitalized
  }
}/// Focus mode: one task, centred, with everything you have already been
/// through drifting up and away above it.
///
/// The column is a single file of work. The task you are on sits in the middle
/// of the pane; the ones you have passed stack above it and recede. Acting on
/// the current task moves the whole column up by one, so the screen reads as
/// progress rather than as a list you are indexing into.
struct WorkspaceFocusScreen: View {
  @Environment(WorkspaceViewModel.self) private var model

  /// How much history stays on screen. Enough to feel the run you are on,
  /// few enough that it never becomes something to read.
  private static let historyDepth = 4
  /// How many still to come are hinted at below.
  private static let previewDepth = 2

  var body: some View {
    VStack(spacing: 0) {
      header
      if model.focusLadder.isEmpty {
        emptyState
      } else {
        column
      }
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }

  // MARK: - Chrome

  private var header: some View {
    HStack {
      Text("FOCUS")
        .font(.caption.weight(.bold))
        .tracking(1.5)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Leave") { model.dismissFocusScreen() }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focusable()
      keyCap("esc")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private var footer: some View {
    HStack(spacing: 14) {
      Spacer()
      hint("↑ ↓", "Move through")
      hint("⌥ ↑ ↓", "Reorder")
      if model.hasManualFocusOrder {
        Button("Reset order") { model.clearManualFocusOrder() }
          .buttonStyle(.plain)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .focusable()
      }
      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private func hint(_ key: String, _ label: String) -> some View {
    HStack(spacing: 5) {
      keyCap(key)
      Text(label)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private func keyCap(_ key: String) -> some View {
    Text(key)
      .font(.caption2.monospaced())
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "Nothing waiting",
      systemImage: "checkmark.circle",
      description: Text("Every daily is done and no task is due. Add something, or enjoy it."))
      .frame(maxHeight: .infinity)
  }

  // MARK: - The column

  private var column: some View {
    let index = model.focusLadderIndex
    let historyTop = min(model.focusLadder.count - 1, index + Self.historyDepth)
    let previewEnd = max(0, index - Self.previewDepth)

    return VStack(spacing: 0) {
      Spacer(minLength: 12)

      // Above the cursor: where you have been, receding.
      ForEach(Array(stride(from: historyTop, to: index, by: -1)), id: \.self) { rung in
        passedRung(model.focusLadder[rung], distance: rung - index)
      }

      if let current = model.focusLadder[safe: index] {
        currentRung(current)
          .id(current.candidate.id)
          .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)))
      }

      // Below: just enough of what follows to know the column continues.
      ForEach(Array(stride(from: index - 1, through: previewEnd, by: -1)), id: \.self) { rung in
        passedRung(model.focusLadder[rung], distance: index - rung)
      }

      Spacer(minLength: 12)
    }
    .frame(maxWidth: .infinity)
    // One spring for the whole column, so history slides up as a body rather
    // than each row animating on its own account.
    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.focusLadderIndex)
    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.focusLadder.count)
  }

  /// A rung you are not on. Legible rather than faint: these are the things you
  /// just dealt with, and a history you cannot read is only decoration.
  private func passedRung(_ scored: ScoredNextUp, distance: Int) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon(for: scored.reason))
        .font(.caption)
      Text(scored.candidate.title)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .opacity(max(0.45, 1 - Double(abs(distance)) * 0.13))
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { model.moveFocusLadder(by: rungOffset(to: scored)) }
  }

  private func rungOffset(to scored: ScoredNextUp) -> Int {
    guard let target = model.focusLadder.firstIndex(where: { $0.candidate.id == scored.candidate.id })
    else { return 0 }
    return target - model.focusLadderIndex
  }

  /// The task in hand. No border and no card: it is the only thing arguing its
  /// case, so it does not need an outline to say where it begins.
  private func currentRung(_ scored: ScoredNextUp) -> some View {
    let task = model.focusLadderTask
    let isStaged = model.stagedTask?.id == scored.candidate.id

    return VStack(spacing: 12) {
      HStack(spacing: 7) {
        Image(systemName: icon(for: scored.reason))
        Text(scored.reason.explanation.localizedCapitalized)
          .font(.caption.weight(.medium))
        if let task, let list = model.list(for: task) {
          Text("·").foregroundStyle(.tertiary)
          Text(list.name).font(.caption).foregroundStyle(.secondary)
        }
      }
      .foregroundStyle(tint(for: scored.reason))

      Text(scored.candidate.title)
        .font(.system(size: 28, weight: .semibold))
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

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
    .frame(maxWidth: 620)
    .padding(.vertical, 22)
  }

  private func metaLine(for scored: ScoredNextUp, task: WorkspaceTask?) -> String? {
    var parts: [String] = []
    if let due = scored.candidate.dueAt {
      parts.append("Due \(due.formatted(.relative(presentation: .named)))")
    }
    if let estimate = scored.candidate.estimateSeconds {
      parts.append("~\(max(1, estimate / 60))m")
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
        model.completeFocusLadderSelection()
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
        .font(.caption2.monospaced())
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
      Text("HOW LONG?")
        .font(.caption2.weight(.bold))
        .tracking(1.2)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        ForEach([5, 10, 15, 25, 45, 60, 90], id: \.self) { minutes in
          Button("\(minutes)m") { model.focusEstimateMinutes = minutes }
            .buttonStyle(.bordered)
            .tint(model.focusEstimateMinutes == minutes ? Color.accentColor : Color.secondary)
            .focusable()
        }
      }
      Stepper(
        "\(model.focusEstimateMinutes) minutes",
        value: Bindable(model).focusEstimateMinutes, in: 1...480, step: 5)
        .labelsHidden()
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
    }
  }

  private func tint(for reason: NextUpReason) -> Color {
    switch reason {
    case .daily: return .green
    case .overdue: return .red
    case .dueToday, .dueSoon: return .orange
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
