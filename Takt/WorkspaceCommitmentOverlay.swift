import SwiftUI
import TaktCore
import TaktWorkspace

struct WorkspaceCommitmentRequest: Identifiable {
  let id = UUID()
  /// The task committed to.
  let task: WorkspaceTask
  /// The commitment being edited; nil for a new one.
  let editing: WorkspaceCommitment?
}

/// The commitment form: `⌘⇧D`, or "Commit periodically" in the inspector.
/// Committing to a task periodically makes a subtask, "Work on <task>", that
/// comes round in Dailies and Today on its days, until a last day if it has
/// one and in any case until the task is done.
///
/// One row has the keyboard at a time. Tab, ⇧Tab, ↑ and ↓ move between rows;
/// ← and → change a choice; Return saves from anywhere; ⌘⌫ stops a commitment
/// being edited; Escape is the host's and cancels.
struct WorkspaceCommitmentOverlay: View {
  let overlayID: String
  let request: WorkspaceCommitmentRequest
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var title = ""
  @State private var interval: Interval = .daily
  /// 1 = Sunday, for a weekly commitment.
  @State private var weekday = 2
  @State private var customRule = ""
  @State private var endsOnDate = false
  @State private var untilText = ""
  @State private var row: Row = .title
  @State private var error: String?
  @FocusState private var textFocus: Row?

  enum Row: Hashable, CaseIterable {
    case title, interval, weekday, custom, ends, until

    var isText: Bool { self == .title || self == .custom || self == .until }
  }

  enum Interval: CaseIterable {
    case daily, weekdays, weekly, custom

    var label: String {
      switch self {
      case .daily: "Every day"
      case .weekdays: "Weekdays"
      case .weekly: "Weekly"
      case .custom: "Custom"
      }
    }
  }

  private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
  private static let weekdayNames = ["", "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
  private static let weekdayWords = ["", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      FocusRule()
      VStack(alignment: .leading, spacing: 0) {
        formRow(.title, label: "Name") { textField("Work on it", text: $title, row: .title) }
        formRow(.interval, label: "How often") {
          chips(Interval.allCases, selected: interval, label: \.label) { setInterval($0) }
        }
        if interval == .weekly {
          formRow(.weekday, label: "On") {
            HStack(spacing: theme.space.xs) {
              ForEach(Self.weekdayOrder, id: \.self) { day in
                chip(Self.weekdayNames[day], selected: weekday == day) { weekday = day }
              }
            }
          }
        }
        if interval == .custom {
          formRow(.custom, label: "Rule") {
            VStack(alignment: .leading, spacing: theme.space.xxs) {
              textField("every 2 weeks, mon, wed, fri", text: $customRule, row: .custom)
              Text(customPreview)
                .font(theme.captionFont)
                .foregroundStyle(customIsValid || customRule.isEmpty ? theme.muted : theme.danger)
            }
          }
        }
        formRow(.ends, label: "Ends") {
          HStack(spacing: theme.space.xs) {
            chip("When the task is done", selected: !endsOnDate) { endsOnDate = false }
            chip("After a date", selected: endsOnDate) { setEndsOnDate() }
          }
        }
        if endsOnDate {
          formRow(.until, label: "Until") {
            VStack(alignment: .leading, spacing: theme.space.xxs) {
              textField("fri, 3w, 2026-12-31", text: $untilText, row: .until)
              Text(untilPreview)
                .font(theme.captionFont)
                .foregroundStyle(parsedUntil == nil && !untilText.isEmpty ? theme.danger : theme.muted)
            }
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
      WorkspaceOverlayFooter(hints: hints, trailing: trailingHint)
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
      MicroLabel(request.editing == nil ? "Commit periodically" : "Edit commitment")
      Text(request.task.title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if request.editing != nil {
        Button("Stop") { stop() }
          .buttonStyle(.plain)
          .foregroundStyle(theme.danger)
          .help("Stop this commitment · ⌘⌫")
      }
      Button("Save") { save() }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary)
        .help("Save · ↩")
    }
    .font(theme.bodyFont())
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
  }

  private func formRow<Content: View>(_ target: Row, label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
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
    _ values: [Value], selected: Value, label: KeyPath<Value, String>, choose: @escaping (Value) -> Void
  ) -> some View {
    HStack(spacing: theme.space.xs) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        chip(value[keyPath: label], selected: value == selected) { choose(value) }
      }
    }
  }

  private var hints: String {
    switch row {
    case .title, .custom, .until: "tab ↑↓ fields"
    case .interval, .ends: "←→ choose"
    case .weekday: "←→ day · 1–7 Mon–Sun"
    }
  }

  private var trailingHint: String {
    request.editing == nil ? "↩ save · esc cancel" : "↩ save · ⌘⌫ stop · esc cancel"
  }

  // MARK: - State

  private var visibleRows: [Row] {
    Row.allCases.filter { target in
      switch target {
      case .weekday: interval == .weekly
      case .custom: interval == .custom
      case .until: endsOnDate
      default: true
      }
    }
  }

  /// The schedule as the core reads it.
  private var rule: String {
    switch interval {
    case .daily: "daily"
    case .weekdays: "weekdays"
    case .weekly: "every \(Self.weekdayWords[weekday])"
    case .custom: customRule.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private var customIsValid: Bool { WorkspaceCommitment.isSchedule(customRule) }

  private var customPreview: String {
    if customRule.trimmingCharacters(in: .whitespaces).isEmpty {
      return "The repeat syntax: daily, weekdays, every friday, every 2 weeks, mon, wed, fri"
    }
    return WorkspaceCommitment.normalizedRule(customRule).map { "Reads as “\($0)”" } ?? "Not a schedule yet"
  }

  private var parsedUntil: Date? {
    TaskCapture.dateTime(from: untilText)
  }

  private var untilPreview: String {
    if untilText.trimmingCharacters(in: .whitespaces).isEmpty { return "The last day it appears" }
    guard let day = parsedUntil else { return "Not a date yet" }
    return "Last appears \(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))"
  }

  private func load() {
    guard let commitment = request.editing else {
      title = WorkspaceCommitment.defaultTitle(forTaskTitle: request.task.title)
      weekday = Calendar.current.component(.weekday, from: .now)
      return
    }
    title = commitment.title
    switch commitment.rule {
    case "daily": interval = .daily
    case "weekdays": interval = .weekdays
    default:
      if commitment.intervalDays == nil, commitment.weekdays.count == 1, let day = commitment.weekdays.first {
        interval = .weekly
        weekday = day
      } else {
        interval = .custom
        customRule = commitment.rule
      }
    }
    if let last = commitment.lastDay() {
      endsOnDate = true
      untilText = WorkspaceHabitOverlay.dayText(last)
    }
  }

  private func setInterval(_ value: Interval) {
    if value == .custom, customRule.isEmpty { customRule = rule }
    interval = value
  }

  private func setEndsOnDate() {
    endsOnDate = true
    if untilText.isEmpty {
      let month = Calendar.current.date(byAdding: .month, value: 1, to: Calendar.current.startOfDay(for: .now))
      untilText = WorkspaceHabitOverlay.dayText(month ?? .now)
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
    case "cmd+delete", "cmd+backspace":
      guard request.editing != nil else { return false }
      stop()
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
    case .interval where offset != 0:
      setInterval(cycle(Interval.allCases, from: interval, by: offset))
    case .weekday:
      if offset != 0 {
        weekday = cycle(Self.weekdayOrder, from: weekday, by: offset)
      } else if let digit = Int(key), (1...7).contains(digit) {
        weekday = Self.weekdayOrder[digit - 1]
      }
    case .ends where offset != 0:
      if endsOnDate { endsOnDate = false } else { setEndsOnDate() }
    default:
      break
    }
    // Every key is the form's while a choice has the keyboard.
    return true
  }

  // MARK: - Saving

  private func save() {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      error = "A commitment needs a name."
      move(to: .title)
      return
    }
    guard WorkspaceCommitment.isSchedule(rule) else {
      error = "Write the rule as daily, weekdays, every friday, every 2 weeks or mon, wed, fri."
      move(to: .custom)
      return
    }
    var expiresAt: Date?
    if endsOnDate {
      guard let day = parsedUntil else {
        error = "Write the last day as fri, 3w or 2026-12-31."
        move(to: .until)
        return
      }
      expiresAt = WorkspaceCommitment.expiry(forLastDay: day)
    }
    let draft = WorkspaceCommitmentDraft(title: name, rule: rule, expiresAt: expiresAt)
    if let failure = model.saveCommitment(draft, to: request.task, editing: request.editing) {
      error = failure
      return
    }
    model.dismissOverlay()
  }

  private func stop() {
    guard let commitment = request.editing else { return }
    model.stopCommitment(commitment)
    model.dismissOverlay()
  }
}
