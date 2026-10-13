import AppKit
import SwiftUI
import TaktCore
import TaktWorkspace

/// The three slots to the right of the add field's title: the day it is
/// due, the conditions it needs, and how long it will take. → at the end of
/// the text walks into them; the keys each one answers are in
/// `TaskEntryDraft.handle(key:)`. A click puts the keyboard on one.
///
/// Quiet until they hold something or have the keyboard: a hairline at the
/// control radius round each, dim words for an empty one, and the focus
/// colour's band and border on the one the keys go to — the field's selection,
/// not a raised button.
struct TaskEntrySlotStrip: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Binding var slots: TaskEntryDraft

  var body: some View {
    HStack(spacing: theme.space.xs) {
      slot(.date, symbol: "calendar", help: "Due day. ↑ a day on, ⇧↑ a week, ↓ the calendar, ⌫ none") {
        if let date = slots.dueDate {
          Text(TaskEntryDate.label(date)).foregroundStyle(theme.ink)
        } else {
          Text("No date").foregroundStyle(theme.dim)
        }
      }
      slot(.conditions, symbol: "location", help: "What it needs. ↓ or Space to choose, ⌫ the last one") {
        conditions
      }
      slot(.estimate, symbol: "timer", help: "Time to complete. ↑↓ step, type minutes, ⌫ none") {
        if let minutes = slots.estimateMinutes {
          Text(TaskEntryEstimate.label(minutes)).foregroundStyle(theme.ink)
        } else {
          Text("No time").foregroundStyle(theme.dim)
        }
      }
    }
    .fixedSize()
  }

  /// The requirements as a row's tags show them: one per requirement, in the
  /// success colour when it holds now and the warning colour when it does
  /// not. Two at most, then a count, so the title keeps its room.
  @ViewBuilder
  private var conditions: some View {
    let groups = slots.requirementGroups
    if groups.isEmpty {
      Text("Anytime").foregroundStyle(theme.dim)
    } else {
      let available = model.focusContext.conditionIDs
      HStack(spacing: theme.space.xxs) {
        ForEach(Array(groups.prefix(2).enumerated()), id: \.offset) { _, group in
          let name = group.map { id in model.focusConditions.first { $0.id == id }?.name ?? "Missing condition" }
            .joined(separator: " or ")
          ThemedTag(name, tint: group.contains { available.contains($0) } ? theme.success : theme.warning)
        }
        if groups.count > 2 {
          Text("+\(groups.count - 2)").foregroundStyle(theme.muted)
        }
      }
    }
  }

  private func slot<Content: View>(
    _ focus: TaskEntryFocus, symbol: String, help: String, @ViewBuilder content: () -> Content
  ) -> some View {
    let isFocused = slots.focus == focus
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    return HStack(spacing: theme.space.xxs) {
      Image(systemName: symbol)
        .foregroundStyle(isFocused ? theme.primary : theme.muted)
        .accessibilityHidden(true)
      content()
    }
    .font(theme.captionFont)
    .lineLimit(1)
    .padding(.horizontal, theme.space.xs)
    .padding(.vertical, theme.space.xxs)
    .background(shape.fill(isFocused ? theme.selectionFill : .clear))
    .overlay(
      shape.strokeBorder(isFocused ? theme.focusRing : theme.border, lineWidth: theme.hairline))
    .contentShape(shape)
    .onTapGesture { slots.focus = focus }
    .help(help)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
  }
}

/// The date slot's calendar: one month, the cursor on a day, the arrows
/// moving it a day or a week and ⇧↑ ⇧↓ a month, Return taking it. Drawn in
/// the overlays' rows rather than the system's graphical picker, whose keys
/// cannot be reached from a field that keeps the keyboard.
struct TaskEntryCalendarView: View {
  @Environment(\.theme) private var theme
  let cursor: Date
  let selected: Date?
  let pick: (Date) -> Void

  private var calendar: Calendar { .current }

  var body: some View {
    let weeks = TaskEntryCalendar.weeks(containing: cursor, calendar: calendar)
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      Text(cursor.formatted(.dateTime.month(.wide).year()))
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .padding(.bottom, theme.space.xxs)
      HStack(spacing: 0) {
        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(theme.monoCaptionFont)
            .foregroundStyle(theme.dim)
            .frame(maxWidth: .infinity)
        }
      }
      ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
        HStack(spacing: 0) {
          ForEach(Array(week.enumerated()), id: \.offset) { _, day in
            cell(day)
          }
        }
      }
    }
    .padding(.horizontal, theme.listGutter)
    .padding(.vertical, theme.space.sm)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// The weekday initials from the calendar's first weekday.
  private var weekdaySymbols: [String] {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let first = calendar.firstWeekday - 1
    return Array(symbols[first...] + symbols[..<first])
  }

  @ViewBuilder
  private func cell(_ day: Date?) -> some View {
    if let day {
      let isCursor = calendar.isDate(day, inSameDayAs: cursor)
      let isSelected = selected.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
      let isToday = calendar.isDateInToday(day)
      let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
      Text("\(calendar.component(.day, from: day))")
        .font(theme.monoCaptionFont)
        .foregroundStyle(isToday ? theme.primary : theme.ink)
        .frame(maxWidth: .infinity, minHeight: 24)
        .background(WorkspaceSelectionBackground(isSelected: isCursor, hasKeyboard: true, radius: theme.controlRadius))
        .overlay(shape.strokeBorder(isSelected ? theme.focusRing : .clear, lineWidth: theme.hairline))
        .contentShape(shape)
        .onTapGesture { pick(day) }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    } else {
      Color.clear.frame(maxWidth: .infinity, minHeight: 24)
    }
  }
}

/// Hears the keys pressed in one window before its first responder does,
/// for as long as it is in the view tree. The add field's slots take the
/// keyboard without a text view of their own to take it with.
struct WindowKeyMonitor: NSViewRepresentable {
  /// Returns whether the key was used; one that was not goes on as usual.
  let handle: (NSEvent) -> Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.view = view
    context.coordinator.handle = handle
    context.coordinator.start()
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.handle = handle
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    weak var view: NSView?
    var handle: ((NSEvent) -> Bool)?
    private var monitor: Any?

    func start() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, let window = self.view?.window, event.window === window,
          let handle = self.handle
        else { return event }
        return handle(event) ? nil : event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
