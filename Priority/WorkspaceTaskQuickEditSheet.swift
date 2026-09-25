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

struct WorkspaceTaskQuickEditSheet: View {
  let request: WorkspaceTaskQuickEditRequest
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var date = Date()
  @State private var text = ""
  @State private var error: String?
  @FocusState private var focus: Field?
  private enum Field: Hashable { case calendar, hour, minute, text }
  private let calendar = Calendar.current
  private var isDate: Bool { request.kind == .due || request.kind == .start }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(request.kind.label).font(.title3.bold())
      Text(request.task.title).foregroundStyle(.secondary).lineLimit(2)
      if isDate {
        calendarView
        HStack {
          Text("Time")
          timePart(.hour, field: .hour)
          Text(":")
          timePart(.minute, field: .minute)
        }
        Text("Arrows: day/week · Shift ← →: month · Tab: time · Return: save · Delete: clear")
          .font(.caption).foregroundStyle(.secondary)
      } else if request.kind == .notes {
        TextEditor(text: $text)
          .focused($focus, equals: .text)
          .frame(height: 180)
          .accessibilityLabel("Task notes")
      } else {
        TextField(request.kind == .estimate ? "Minutes" : request.kind.label, text: $text)
          .textFieldStyle(.roundedBorder).focused($focus, equals: .text)
          .onSubmit { save() }
        if request.kind == .estimate {
          Text("Enter minutes; ↑ ↓ adjusts by 5, Shift ↑ ↓ by 30.")
            .font(.caption).foregroundStyle(.secondary)
        } else if request.kind == .tags {
          Text("Separate tags with commas.").font(.caption).foregroundStyle(.secondary)
        } else if request.kind == .recurrence {
          Text("For example: daily, weekdays, weekly, or every 3 days.").font(.caption).foregroundStyle(.secondary)
        }
      }
      if let error { Text(error).foregroundStyle(model.themeColor(.danger)).font(.caption) }
      HStack {
        Button("Cancel") { dismiss() }.focusable().keyboardShortcut(.cancelAction)
        if request.kind != .title { Button("Clear") { save(clear: true) }.focusable() }
        Spacer()
        Button("Save") { save() }.focusable().keyboardShortcut(request.kind == .notes ? "s" : .return, modifiers: request.kind == .notes ? .command : [])
      }
    }
    .padding(24).frame(width: 420)
    .onAppear { load(); focus = isDate ? .calendar : .text }
    .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in adjustEstimate(1, shift: press.modifiers.contains(.shift)) }
    .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in adjustEstimate(-1, shift: press.modifiers.contains(.shift)) }
    .onKeyPress(.delete) {
      guard isDate else { return .ignored }
      save(clear: true); return .handled
    }
  }

  private var calendarView: some View {
    VStack(spacing: 10) {
      HStack {
        Button { move(.month, -1) } label: { Image(systemName: "chevron.left") }
          .focusable()
          .accessibilityLabel("Previous month")
        Spacer()
        Text(date, format: .dateTime.month(.wide).year())
        Spacer()
        Button { move(.month, 1) } label: { Image(systemName: "chevron.right") }
          .focusable()
          .accessibilityLabel("Next month")
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
        ForEach(0..<7, id: \.self) { index in
          Text(calendar.veryShortWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
            .foregroundStyle(.secondary)
        }
        ForEach(0..<42, id: \.self) { index in
          let day = gridDay(index)
          Text(day, format: .dateTime.day())
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .foregroundStyle(calendar.isDate(day, equalTo: date, toGranularity: .month) ? Color.primary : Color.secondary)
            .background(calendar.isDate(day, inSameDayAs: date) ? Color.accentColor.opacity(0.3) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onTapGesture { selectDay(day) }
        }
      }
    }
    .padding(8)
    .focusable().focusEffectDisabled().focused($focus, equals: .calendar)
    .background(focus == .calendar ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8))
    .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in move(press.modifiers.contains(.shift) ? .month : .day, -1); return .handled }
    .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in move(press.modifiers.contains(.shift) ? .month : .day, 1); return .handled }
    .onKeyPress(.upArrow) { move(.day, -7); return .handled }
    .onKeyPress(.downArrow) { move(.day, 7); return .handled }
    .onKeyPress(.delete) { save(clear: true); return .handled }
    .onKeyPress(.return) { save(); return .handled }
  }

  private func timePart(_ component: Calendar.Component, field: Field) -> some View {
    Text(String(format: "%02d", calendar.component(component, from: date)))
      .monospacedDigit().padding(8)
      .background(focus == field ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1),
                  in: RoundedRectangle(cornerRadius: 6))
      .focusable().focused($focus, equals: field)
      .accessibilityLabel(component == .hour ? "Hour" : "Minute")
      .onTapGesture { focus = field }
      .onKeyPress(.upArrow) { move(component, 1); return .handled }
      .onKeyPress(.downArrow) { move(component, -1); return .handled }
      .onKeyPress(.leftArrow) { focus = field == .minute ? .hour : .calendar; return .handled }
      .onKeyPress(.rightArrow) { focus = field == .hour ? .minute : .calendar; return .handled }
      .onKeyPress(.return) { save(); return .handled }
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

  private func adjustEstimate(_ amount: Int, shift: Bool) -> KeyPress.Result {
    guard request.kind == .estimate else { return .ignored }
    text = String(max(1, (Int(text) ?? 25) + amount * (shift ? 30 : 5)))
    return .handled
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
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
