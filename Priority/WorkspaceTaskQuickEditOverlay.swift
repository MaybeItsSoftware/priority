import SwiftUI
import PriorityCore
import PriorityWorkspace

enum WorkspaceTaskQuickEditKind: String {
  case estimate = "t", due = "d", start = "s", title = "e"
  case notes = "n", tags = "tags", recurrence = "recurrence"

  var label: String {
    switch self {
    case .estimate: "Time estimate"
    case .due: "Due date and time"
    case .start: "Start date and time"
    case .title: "Task title"
    case .notes: "Task notes"
    case .tags: "Task tags"
    case .recurrence: "Repeating due settings"
    }
  }
}

struct WorkspaceTaskQuickEditRequest: Identifiable {
  let id = UUID()
  let task: WorkspaceTask
  let kind: WorkspaceTaskQuickEditKind
}

/// One field of one task, edited without opening the inspector: `t` for the
/// estimate, `dd` for the due date, and so on. Drawn by the overlay host.
///
/// Return saves, whatever is being edited — notes included, where ⇧↩ is the
/// new line. Escape is the host's and always cancels.
struct WorkspaceTaskQuickEditOverlay: View {
  let overlayID: String
  let request: WorkspaceTaskQuickEditRequest
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var date = Date()
  @State private var text = ""
  @State private var error: String?
  @FocusState private var focus: Field?
  private enum Field: Hashable { case calendar, hour, minute, text }
  private let calendar = Calendar.current
  private var isDate: Bool { request.kind == .due || request.kind == .start }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      FocusRule()
      VStack(alignment: .leading, spacing: theme.space.sm) {
        editor
        if let error {
          Text(error).font(theme.captionFont).foregroundStyle(theme.danger)
        }
      }
      .padding(theme.space.md)
      WorkspaceOverlayFooter(hints: hints, trailing: request.kind == .title ? nil : "⌘⌫ clear")
    }
    .onAppear {
      load()
      DispatchQueue.main.async { focus = isDate ? .calendar : .text }
    }
    .overlayKeys(model, id: overlayID) { key in
      switch key {
      case "enter", "cmd+enter":
        save()
        return true
      case "up", "down", "shift+up", "shift+down":
        guard request.kind == .estimate else { return false }
        adjustEstimate(key.hasSuffix("up") ? 1 : -1, shift: key.hasPrefix("shift"))
        return true
      case "cmd+backspace":
        guard request.kind != .title else { return false }
        save(clear: true)
        return true
      default:
        return false
      }
    }
  }

  private var header: some View {
    HStack(spacing: theme.space.sm) {
      MicroLabel(request.kind.label)
      Text(request.task.title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if request.kind != .title {
        Button("Clear") { save(clear: true) }
          .buttonStyle(.plain)
          .foregroundStyle(theme.muted)
      }
      Button("Save") { save() }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary)
    }
    .font(theme.bodyFont())
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
  }

  @ViewBuilder
  private var editor: some View {
    if isDate {
      calendarView
      HStack(spacing: theme.space.xs) {
        MicroLabel("Time")
        timePart(.hour, field: .hour)
        Text(":").font(theme.numeralFont(theme.scale.body)).foregroundStyle(theme.muted)
        timePart(.minute, field: .minute)
      }
    } else if request.kind == .notes {
      TextEditor(text: $text)
        .font(theme.bodyFont())
        .scrollContentBackground(.hidden)
        .focused($focus, equals: .text)
        .frame(height: WorkspaceOverlayMetrics.listHeight / 2)
        .padding(theme.space.xs)
        .overlay(
          RoundedRectangle(cornerRadius: theme.controlRadius)
            .strokeBorder(theme.inputBorder, lineWidth: theme.hairline))
        .accessibilityLabel("Task notes")
    } else {
      TextField(request.kind == .estimate ? "Minutes" : request.kind.label, text: $text)
        .textFieldStyle(.plain)
        .font(theme.bodyFont())
        .focused($focus, equals: .text)
        .padding(theme.space.xs)
        .overlay(
          RoundedRectangle(cornerRadius: theme.controlRadius)
            .strokeBorder(theme.inputBorder, lineWidth: theme.hairline))
    }
  }

  private var hints: String {
    switch request.kind {
    case .due, .start: "arrows day/week · ⇧←→ month · tab time · ↩ save · esc cancel"
    case .estimate: "minutes · ↑↓ ±5 · ⇧↑↓ ±30 · ↩ save · esc cancel"
    case .notes: "↩ save · ⇧↩ new line · esc cancel"
    case .tags: "comma separated · ↩ save · esc cancel"
    case .recurrence: "daily, weekdays, every 3 days · ↩ save · esc cancel"
    case .title: "↩ save · esc cancel"
    }
  }

  private var calendarView: some View {
    VStack(spacing: theme.space.sm) {
      HStack {
        Button { move(.month, -1) } label: { Image(systemName: "chevron.left") }
          .buttonStyle(.plain)
          .foregroundStyle(theme.muted)
          .focusable()
          .accessibilityLabel("Previous month")
        Spacer()
        Text(date, format: .dateTime.month(.wide).year())
          .font(theme.bodyFont(weight: .medium))
          .foregroundStyle(theme.ink)
        Spacer()
        Button { move(.month, 1) } label: { Image(systemName: "chevron.right") }
          .buttonStyle(.plain)
          .foregroundStyle(theme.muted)
          .focusable()
          .accessibilityLabel("Next month")
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
        ForEach(0..<7, id: \.self) { index in
          Text(calendar.veryShortWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
            .microLabel(theme)
        }
        ForEach(0..<42, id: \.self) { index in
          let day = gridDay(index)
          Text(day, format: .dateTime.day())
            .font(theme.numeralFont(theme.scale.body, weight: .regular))
            .frame(maxWidth: .infinity).padding(.vertical, theme.space.xs)
            .foregroundStyle(calendar.isDate(day, equalTo: date, toGranularity: .month) ? theme.ink : theme.dim)
            .workspaceSelection(isSelected: calendar.isDate(day, inSameDayAs: date), hasKeyboard: false)
            .onTapGesture { selectDay(day) }
        }
      }
    }
    .padding(theme.space.sm)
    .focusable().focusEffectDisabled().focused($focus, equals: .calendar)
    .overlay(
      RoundedRectangle(cornerRadius: theme.controlRadius)
        .strokeBorder(focus == .calendar ? theme.focusRing : theme.border, lineWidth: theme.hairline))
    .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in move(press.modifiers.contains(.shift) ? .month : .day, -1); return .handled }
    .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in move(press.modifiers.contains(.shift) ? .month : .day, 1); return .handled }
    .onKeyPress(.upArrow) { move(.day, -7); return .handled }
    .onKeyPress(.downArrow) { move(.day, 7); return .handled }
    .onKeyPress(.delete) { save(clear: true); return .handled }
  }

  private func timePart(_ component: Calendar.Component, field: Field) -> some View {
    Text(String(format: "%02d", calendar.component(component, from: date)))
      .font(theme.numeralFont(theme.scale.body))
      .foregroundStyle(theme.ink)
      .monospacedDigit().padding(theme.space.xs)
      .workspaceSelection(isSelected: focus == field, hasKeyboard: focus == field)
      .focusable().focused($focus, equals: field)
      .accessibilityLabel(component == .hour ? "Hour" : "Minute")
      .onTapGesture { focus = field }
      .onKeyPress(.upArrow) { move(component, 1); return .handled }
      .onKeyPress(.downArrow) { move(component, -1); return .handled }
      .onKeyPress(.leftArrow) { focus = field == .minute ? .hour : .calendar; return .handled }
      .onKeyPress(.rightArrow) { focus = field == .hour ? .minute : .calendar; return .handled }
  }

  private func gridDay(_ index: Int) -> Date {
    let first = calendar.dateInterval(of: .month, for: date)!.start
    let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    return calendar.date(byAdding: .day, value: index - offset, to: first)!
  }

  private func selectDay(_ day: Date) {
    date = calendar.date(bySettingHour: calendar.component(.hour, from: date),
                         minute: calendar.component(.minute, from: date), second: 0, of: day) ?? day
    focus = .calendar
  }

  private func move(_ component: Calendar.Component, _ amount: Int) {
    date = calendar.date(byAdding: component, value: amount, to: date) ?? date
  }

  private func adjustEstimate(_ amount: Int, shift: Bool) {
    text = String(max(1, (Int(text) ?? 25) + amount * (shift ? 30 : 5)))
  }

  private func load() {
    guard let store = model.store else { return }
    do {
      let snapshot = try store.taskEditorSnapshot(for: request.task.id)
      switch request.kind {
      case .estimate: text = snapshot.values.estimateMinutes
      case .title: text = snapshot.title
      case .notes: text = snapshot.notes
      case .tags: text = snapshot.values.tags
      case .recurrence: text = snapshot.values.recurrenceRule
      case .due: date = snapshot.dueAt ?? snapshot.planning?.dueDate.flatMap { TaskCalendarDate.date($0) } ?? defaultDate
      case .start: date = snapshot.planning?.startAt ?? defaultDate
      }
    } catch { self.error = error.localizedDescription }
  }

  private var defaultDate: Date {
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
    return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
  }

  private func save(clear: Bool = false) {
    guard let store = model.store else { return }
    do {
      var draft = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: request.task.id))
      switch request.kind {
      case .estimate: draft.values.estimateMinutes = clear ? "" : text
      case .title: draft.values.title = text
      case .notes: draft.values.notes = clear ? "" : text
      case .tags: draft.values.tags = clear ? "" : text
      case .recurrence: draft.values.recurrenceRule = clear ? "" : text
      case .due: draft.values.dueAt = clear ? nil : date; draft.values.dueDate = nil
      case .start: draft.values.startAt = clear ? nil : date
      }
      _ = try store.saveTaskEditor(draft)
      model.taskEditor.refresh(store: store)
      model.reloadOutline(); model.reloadDailies(); model.reloadFocus(); model.reloadNextUp()
      model.dismissOverlay()
    } catch { self.error = error.localizedDescription }
  }
}
