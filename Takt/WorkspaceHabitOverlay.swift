import SwiftUI
import TaktCore
import TaktWorkspace

struct WorkspaceHabitRequest: Identifiable {
  let id = UUID()
  let context: HabitFormContext
}

/// The habit form: `hh` or ⇧⌘H. Opened on a task, it makes a habit from it
/// ("learn drums" → a daily "practise drums" that ends when the goal is done);
/// opened on a habit, it edits it; opened on nothing, a standalone habit.
///
/// One row has the keyboard at a time. Tab, ⇧Tab, ↑ and ↓ move between rows;
/// ← and → change a choice; Space flips the toggle; Return saves from
/// anywhere; Escape is the host's and cancels.
struct WorkspaceHabitOverlay: View {
  let overlayID: String
  let request: WorkspaceHabitRequest
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var draft = HabitDraft(title: "")
  @State private var row: Row = .title
  @State private var intervalText = "3"
  @State private var estimateText = ""
  @State private var expiryDateText = ""
  @State private var error: String?
  @FocusState private var textFocus: Row?

  enum Row: Hashable, CaseIterable {
    case title, frequency, column, dropsAtDayEnd, estimate, expiry, expiryDate

    var isText: Bool { self == .title || self == .estimate || self == .expiryDate }
  }

  /// The frequency choices, in ←→ order.
  private enum FrequencyKind: CaseIterable {
    case daily, weekdays, everyNDays, weekly

    var label: String {
      switch self {
      case .daily: "Every day"
      case .weekdays: "On days"
      case .everyNDays: "Every N days"
      case .weekly: "Weekly"
      }
    }
  }

  private enum ExpiryKind: CaseIterable {
    case source, date, never
  }

  private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
  private static let weekdayNames = ["", "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      FocusRule()
      VStack(alignment: .leading, spacing: 0) {
        formRow(.title, label: "Habit") { textField("Practise drums", text: $draft.title, row: .title) }
        formRow(.frequency, label: "How often") { frequencyControl }
        formRow(.column, label: "Appears in") {
          chips(HabitPlacement.allCases, selected: draft.placement, label: \.label) { draft.placement = $0 }
        }
        formRow(.dropsAtDayEnd, label: "End of day") { dropsControl }
        formRow(.estimate, label: "Estimate") { textField("30m", text: $estimateText, row: .estimate) }
        formRow(.expiry, label: "Ends") {
          chips(expiryKinds, selected: expiryKind, label: expiryLabel) { setExpiryKind($0) }
        }
        if expiryKind == .date {
          formRow(.expiryDate, label: "Ends on") {
            textField("2026-12-31, 3w, friday", text: $expiryDateText, row: .expiryDate)
          }
        }
        if let error {
          Text(error)
            .font(theme.captionFont)
            .foregroundStyle(theme.danger)
            .padding(.horizontal, theme.space.md)
            .padding(.vertical, theme.space.xs)
        }
      }
      .padding(.vertical, theme.space.xs)
      WorkspaceOverlayFooter(hints: hints, trailing: "↩ save · esc cancel")
    }
    .onAppear {
      load()
      DispatchQueue.main.async { textFocus = .title }
    }
    .overlayKeys(model, id: overlayID) { key in handle(key) }
  }

  // MARK: - Chrome

  private var header: some View {
    HStack(spacing: theme.space.sm) {
      MicroLabel(request.context.habitTaskId == nil ? "New habit" : "Edit habit")
      if let source = request.context.sourceTitle {
        Text("from \(source)")
          .font(theme.bodyFont())
          .foregroundStyle(theme.muted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
      Button("Save") { save() }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary)
    }
    .font(theme.bodyFont())
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
  }

  private func formRow<Content: View>(_ target: Row, label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: theme.space.sm) {
      MicroLabel(label)
        .frame(width: 92, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.xs)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: row == target, hasKeyboard: row == target && !target.isText)
    .onTapGesture { move(to: target) }
  }

  private func textField(_ prompt: String, text: Binding<String>, row target: Row) -> some View {
    TextField(prompt, text: text)
      .textFieldStyle(.plain)
      .font(theme.bodyFont())
      .focused($textFocus, equals: target)
      .padding(theme.space.xs)
      .overlay(
        RoundedRectangle(cornerRadius: theme.controlRadius)
          .strokeBorder(row == target ? theme.focusRing : theme.inputBorder, lineWidth: theme.hairline))
      .onChange(of: textFocus) { _, focused in
        if focused == target { row = target }
      }
  }

  private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Text(text)
      .font(theme.bodyFont())
      .foregroundStyle(selected ? theme.ink : theme.muted)
      .padding(.horizontal, theme.space.sm)
      .padding(.vertical, theme.space.xxs)
      .overlay(
        RoundedRectangle(cornerRadius: theme.controlRadius)
          .strokeBorder(selected ? theme.primary : theme.border, lineWidth: theme.hairline))
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
  }

  private func chips<Value: Equatable>(
    _ values: [Value], selected: Value, label: @escaping (Value) -> String, choose: @escaping (Value) -> Void
  ) -> some View {
    HStack(spacing: theme.space.xs) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        chip(label(value), selected: value == selected) { choose(value) }
      }
    }
  }

  private func chips<Value: Equatable>(
    _ values: [Value], selected: Value, label: KeyPath<Value, String>, choose: @escaping (Value) -> Void
  ) -> some View {
    chips(values, selected: selected, label: { $0[keyPath: label] }, choose: choose)
  }

  @ViewBuilder
  private var frequencyControl: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      chips(FrequencyKind.allCases, selected: frequencyKind, label: \.label) { setFrequencyKind($0) }
      switch draft.frequency {
      case .weekdays(let days):
        HStack(spacing: theme.space.xs) {
          ForEach(Array(Self.weekdayOrder.enumerated()), id: \.offset) { _, weekday in
            chip(Self.weekdayNames[weekday], selected: days.contains(weekday)) { toggleWeekday(weekday) }
          }
        }
      case .everyNDays(let days):
        Text("Every \(days) days")
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
      default:
        EmptyView()
      }
    }
  }

  private var dropsControl: some View {
    HStack(spacing: theme.space.xs) {
      chip("Disappears", selected: draft.dropsAtDayEnd) { draft.dropsAtDayEnd = true }
      chip("Stays until done", selected: !draft.dropsAtDayEnd) { draft.dropsAtDayEnd = false }
    }
  }

  private var hints: String {
    switch row {
    case .title, .estimate, .expiryDate: "tab ↑↓ fields"
    case .frequency:
      switch draft.frequency {
      case .weekdays: "←→ choose · 1–7 Mon–Sun"
      case .everyNDays: "←→ choose · digits set N"
      default: "←→ choose"
      }
    case .column, .expiry: "←→ choose"
    case .dropsAtDayEnd: "←→ or space"
    }
  }

  // MARK: - State

  private var visibleRows: [Row] {
    Row.allCases.filter { $0 != .expiryDate || expiryKind == .date }
  }

  private var frequencyKind: FrequencyKind {
    switch draft.frequency {
    case .daily: .daily
    case .weekdays: .weekdays
    case .everyNDays: .everyNDays
    case .weekly: .weekly
    }
  }

  private var expiryKinds: [ExpiryKind] {
    draft.sourceTaskId == nil ? [.date, .never] : ExpiryKind.allCases
  }

  private var expiryKind: ExpiryKind {
    switch draft.expiry {
    case .whenSourceCompleted: .source
    case .on: .date
    case .never: .never
    }
  }

  private func expiryLabel(_ kind: ExpiryKind) -> String {
    switch kind {
    case .source: "When \(request.context.sourceTitle ?? "its task") is done"
    case .date: "On a date"
    case .never: "Never"
    }
  }

  private func load() {
    draft = request.context.draft
    estimateText = draft.estimateSeconds.map { WorkspaceHabitOverlay.estimateLabel($0) } ?? ""
    if case .on(let date) = draft.expiry {
      expiryDateText = Self.dayText(date)
    }
    if case .everyNDays(let days) = draft.frequency { intervalText = String(days) }
  }

  /// `2026-12-31`, in the user's calendar — what the "Ends on" field reads.
  static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func estimateLabel(_ seconds: Int) -> String {
    let minutes = seconds / 60
    if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60)h" }
    if minutes > 60 { return "\(minutes / 60)h\(minutes % 60)" }
    return "\(minutes)m"
  }

  private func setFrequencyKind(_ kind: FrequencyKind) {
    switch kind {
    case .daily: draft.frequency = .daily
    case .weekdays:
      if case .weekdays = draft.frequency { return }
      draft.frequency = .weekdays([2, 3, 4, 5, 6])
    case .everyNDays: draft.frequency = .everyNDays(max(2, Int(intervalText) ?? 3))
    case .weekly: draft.frequency = .weekly
    }
  }

  private func toggleWeekday(_ weekday: Int) {
    guard case .weekdays(var days) = draft.frequency else { return }
    if days.contains(weekday) {
      guard days.count > 1 else { return }
      days.remove(weekday)
    } else {
      days.insert(weekday)
    }
    draft.frequency = days.count == 7 ? .daily : .weekdays(days)
  }

  private func setExpiryKind(_ kind: ExpiryKind) {
    switch kind {
    case .source: draft.expiry = .whenSourceCompleted
    case .never: draft.expiry = .never
    case .date:
      let date = HabitPolicy.date(from: expiryDateText)
        ?? Calendar.current.date(byAdding: .month, value: 1, to: Calendar.current.startOfDay(for: .now))
        ?? .now
      draft.expiry = .on(date)
      if expiryDateText.isEmpty { expiryDateText = Self.dayText(date) }
    }
  }

  private func move(to target: Row) {
    row = target
    textFocus = target.isText ? target : nil
  }

  private func step(_ offset: Int) {
    let rows = visibleRows
    let index = rows.firstIndex(of: row) ?? 0
    move(to: rows[(index + offset + rows.count) % rows.count])
  }

  private func cycle<Value: Equatable>(_ values: [Value], from current: Value, by offset: Int) -> Value {
    let index = values.firstIndex(of: current) ?? 0
    return values[(index + offset + values.count) % values.count]
  }

  // MARK: - Keys

  private func handle(_ key: String) -> Bool {
    switch key {
    case "enter", "cmd+enter":
      save()
      return true
    case "tab", "down":
      step(1)
      return true
    case "shift+tab", "up":
      step(-1)
      return true
    default:
      break
    }
    // A text row keeps every other key for its field.
    guard !row.isText else { return false }
    let offset = key == "right" ? 1 : key == "left" ? -1 : 0
    switch row {
    case .frequency:
      if offset != 0 {
        setFrequencyKind(cycle(FrequencyKind.allCases, from: frequencyKind, by: offset))
      } else if let digit = Int(key) {
        if case .weekdays = draft.frequency, (1...7).contains(digit) {
          toggleWeekday(Self.weekdayOrder[digit - 1])
        } else if case .everyNDays = draft.frequency {
          intervalText = String((intervalText + key).suffix(3))
          draft.frequency = .everyNDays(min(366, max(2, Int(intervalText) ?? 2)))
        }
      } else if key == "delete", case .everyNDays = draft.frequency {
        intervalText = String(intervalText.dropLast())
        draft.frequency = .everyNDays(min(366, max(2, Int(intervalText) ?? 2)))
      }
    case .column where offset != 0:
      draft.placement = cycle(HabitPlacement.allCases, from: draft.placement, by: offset)
    case .dropsAtDayEnd where offset != 0 || key == "space":
      draft.dropsAtDayEnd.toggle()
    case .expiry where offset != 0:
      setExpiryKind(cycle(expiryKinds, from: expiryKind, by: offset))
    default:
      break
    }
    // Every key is the form's while a choice has the keyboard: nothing typed
    // here should reach the list behind it.
    return true
  }

  // MARK: - Saving

  private func save() {
    var result = draft
    result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.title.isEmpty else {
      error = "A habit needs a name."
      move(to: .title)
      return
    }
    let estimate = estimateText.trimmingCharacters(in: .whitespaces)
    if estimate.isEmpty {
      result.estimateSeconds = nil
    } else if let seconds = HabitPolicy.estimateSeconds(from: estimate) {
      result.estimateSeconds = seconds
    } else {
      error = "Write the estimate as 30m, 1h or 1h30."
      move(to: .estimate)
      return
    }
    if case .on = result.expiry {
      guard let date = HabitPolicy.date(from: expiryDateText) else {
        error = "Write the end date as 2026-12-31, 3w or a weekday."
        move(to: .expiryDate)
        return
      }
      result.expiry = .on(date)
    }
    if let failure = model.saveHabit(result, habitTaskId: request.context.habitTaskId) {
      error = failure
      return
    }
    model.dismissOverlay()
  }
}
