import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// The right dock's Conditions tab, in two halves under one cursor.
///
/// **Available now** is the settings first — where you are, your free time
/// and what you want from it, then any other category whose conditions
/// provide something ("Tools on hand") — and then the properties tasks
/// need, under their category headings, only those an open task needs, so a
/// condition nothing waits on is not asked about. What a setting provides
/// shows as on, "from Home"; turning it off switches it off for now, until
/// the setting changes. Then when to stop trusting the answer.
/// **Conditions** is every condition, by category: add one, rename it in its
/// row, file it under a category, choose what it provides, archive it, and
/// see how many open tasks need it.
///
/// `↑` `↓` walk both halves; `←` `→` step where you are, your free time and
/// when it is forgotten, and typing a number sets the time. Space turns a
/// condition on or off, Return or F2 renames (on the new-condition row,
/// puts the caret in its field), `t` files it under a category and `⇧T`
/// renames the category, `p` chooses what it provides, `⌥↑`/`⌥↓` move it
/// and `⌥⇧↑`/`⌥⇧↓` its category, `m` merges it into another, `o` lists the
/// tasks that need it, `z` folds its category, `e` archives it, `c` clears,
/// Esc goes back to the work.
struct WorkspaceConditionsPane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    // Worked out once and handed to the rows, as the done rail does.
    let cursor = model.conditionsCursorStop
    let hasKeyboard = model.keyboardFocusArea == .conditions
    let counts = model.conditionRequirementCounts
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          availableNow(cursor: cursor, hasKeyboard: hasKeyboard)
          FocusRule()
          conditions(cursor: cursor, hasKeyboard: hasKeyboard, counts: counts)
        }
        .padding(.bottom, theme.space.md)
      }
      .onChange(of: model.conditionsCursor) { _, _ in
        withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(model.conditionsCursorStop.anchor) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(theme.paper)
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.conditions) })
  }

  // MARK: - Available now

  @ViewBuilder
  private func availableNow(cursor: WorkspaceConditionsStop, hasKeyboard: Bool) -> some View {
    WorkspaceConditionsSectionHeader(title: "Available now") {
      if !model.focusContext.conditionIDs.isEmpty || !model.contextOffIDs.isEmpty {
        Button("Clear") { model.clearFocusConditions() }
          .buttonStyle(.plain)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .commandHelp(.conditionsClear)
      } else {
        Text("Anywhere").font(theme.captionFont).foregroundStyle(theme.dim)
      }
    }
    let sections = model.availableConditionSections
    if sections.isEmpty {
      Text(model.focusConditions.isEmpty
        ? WorkspaceConditionCopy.explanation + " None yet: add one below."
        : "No open tasks need a condition.")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .fixedSize(horizontal: false, vertical: true)
        .focusSurfaceGutter()
        .padding(.bottom, theme.space.sm)
    }
    if model.isFocusContextStale {
      staleNotice
    }
    let waiting = model.conditionWaitingCounts
    let holdings = model.conditionHoldings
    if !model.availablePlaces.isEmpty {
      WorkspaceLocationRow(
        waiting: waiting, isCursor: cursor == .location, hasKeyboard: hasKeyboard && cursor == .location)
        .id(WorkspaceConditionsStop.location.anchor)
    }
    freeTimeRows(cursor: cursor, hasKeyboard: hasKeyboard)
    // The other settings, then the properties: the core's order.
    ForEach(sections.filter { $0.conditions.contains { !$0.isLocation } }) { section in
      WorkspaceConditionsCategoryHeading(title: section.title)
      ForEach(section.conditions.filter { !$0.isLocation }) { condition in
        let stop = WorkspaceConditionsStop.available(condition.id)
        WorkspaceAvailableConditionRow(
          condition: condition,
          isOn: holdings[condition.id]?.holds ?? false,
          note: model.conditionHoldingNote(condition.id),
          waiting: waiting[condition.id] ?? 0,
          isCursor: cursor == stop, hasKeyboard: hasKeyboard && cursor == stop)
          .id(stop.anchor)
      }
    }
    if !model.suggestedContextIDs.isEmpty {
      lastContext
    }
    expiryRow(cursor: cursor, hasKeyboard: hasKeyboard)
  }

  /// Said on an earlier day: probably not where you are now.
  private var staleNotice: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: "clock.badge.exclamationmark")
        .foregroundStyle(theme.warning)
      Text(model.contextConditionsSetAt.map {
        "Set \($0.formatted(.relative(presentation: .named))) — still true?"
      } ?? "Set on an earlier day — still true?")
      .foregroundStyle(theme.muted)
      .lineLimit(2)
      Spacer(minLength: theme.space.xs)
      Button("Clear") { model.clearFocusConditions() }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary)
        .commandHelp(.conditionsClear)
    }
    .font(theme.captionFont)
    .focusSurfaceGutter()
    .padding(.vertical, theme.space.xs)
  }

  /// The conditions that held before the last context expired, offered back.
  private var lastContext: some View {
    HStack(spacing: theme.space.sm) {
      // In the tab's order, as the rows above are: sorted by id, the names
      // came out in an order nothing on screen explained.
      Text("Last context: " + model.focusConditions.filter { model.suggestedContextIDs.contains($0.id) }
        .map(\.name).joined(separator: ", "))
      .foregroundStyle(theme.muted)
      .lineLimit(2)
      Spacer(minLength: theme.space.xs)
      Button("Use again") { model.confirmSuggestedContext() }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary)
        .commandHelp(.conditionsUseAgain)
      Button("Dismiss") { model.dismissSuggestedContext() }
        .buttonStyle(.plain)
        .foregroundStyle(theme.muted)
    }
    .font(theme.captionFont)
    .focusSurfaceGutter()
    .padding(.vertical, theme.space.xs)
  }

  /// Your free time and whether to offer only what fits in it: rows the
  /// cursor stands on, `←` `→` to change. A setting, beside where you are.
  @ViewBuilder
  private func freeTimeRows(cursor: WorkspaceConditionsStop, hasKeyboard: Bool) -> some View {
    WorkspaceTimeRow(isCursor: cursor == .time, hasKeyboard: hasKeyboard && cursor == .time)
      .id(WorkspaceConditionsStop.time.anchor)
    if model.availableUntil != nil {
      WorkspaceConditionsSettingRow(
        title: "Only what I can finish", stop: .finishOnly, isCursor: cursor == .finishOnly,
        hasKeyboard: hasKeyboard && cursor == .finishOnly,
        note: "Offers only the tasks whose remaining work fits in the time you have"
      ) {
        Toggle("", isOn: Binding(get: { model.focusContext.mode == .finish }, set: {
          model.focusContext.mode = $0 ? .finish : .progress
          model.focusContextChanged()
        }))
        .labelsHidden()
        .toggleStyle(.themedSwitch)
      }
      .id(WorkspaceConditionsStop.finishOnly.anchor)
    }
  }

  /// When what you have said is forgotten.
  private func expiryRow(cursor: WorkspaceConditionsStop, hasKeyboard: Bool) -> some View {
    WorkspaceConditionsSettingRow(
      title: "Forget this", stop: .expiry, isCursor: cursor == .expiry, hasKeyboard: hasKeyboard && cursor == .expiry,
      note: "When where you are and your free time stop counting; Shift+U offers them back"
    ) {
      ThemedMenu(Self.expiryText(model.contextExpiresAt)) {
        ForEach(ConditionsPaneSteps.Expiry.allCases, id: \.self) { stop in
          Button(Self.expiryChoice(stop)) {
            model.contextExpiresAt = stop.date(now: .now)
            model.focusContextChanged()
          }
        }
      }
    }
    .id(WorkspaceConditionsStop.expiry.anchor)
    .padding(.bottom, theme.space.sm)
  }

  private static func expiryText(_ date: Date?) -> String {
    guard let date else { return "Never" }
    let time = date.formatted(date: .omitted, time: .shortened)
    return Calendar.current.isDateInToday(date) ? "At \(time)" : "Tomorrow \(time)"
  }

  private static func expiryChoice(_ stop: ConditionsPaneSteps.Expiry) -> String {
    switch stop {
    case .never: "Never"
    case .oneHour: "In an hour"
    case .twoHours: "In two hours"
    case .fourHours: "In four hours"
    case .endOfDay: "At midnight"
    }
  }

  // MARK: - Conditions

  @ViewBuilder
  private func conditions(cursor: WorkspaceConditionsStop, hasKeyboard: Bool, counts: [String: Int]) -> some View {
    WorkspaceConditionsSectionHeader(title: "Conditions") {
      Text("\(model.focusConditions.count)")
        .font(theme.monoCaptionFont)
        .monospacedDigit()
        .foregroundStyle(theme.dim)
    }
    Text(WorkspaceConditionCopy.explanation + " Renaming keeps every task's requirements.")
      .font(theme.captionFont)
      .foregroundStyle(theme.muted)
      .fixedSize(horizontal: false, vertical: true)
      .focusSurfaceGutter()
      .padding(.bottom, theme.space.sm)
    WorkspaceNewConditionRow(isCursor: cursor == .add, hasKeyboard: hasKeyboard && cursor == .add)
      .id(WorkspaceConditionsStop.add.anchor)
    ForEach(model.liveConditionSections) { section in
      let isFolded = model.foldedConditionSections.contains(section.id)
      let stop = WorkspaceConditionsStop.folded(section.id)
      WorkspaceConditionsFoldHeading(
        title: section.title, count: section.conditions.count, isFolded: isFolded,
        isCursor: isFolded && cursor == stop, hasKeyboard: hasKeyboard && cursor == stop
      ) { model.toggleConditionSectionFold(section) }
      .id(stop.anchor)
      if !isFolded {
        ForEach(section.conditions) { condition in
          manageRow(condition, cursor: cursor, hasKeyboard: hasKeyboard, counts: counts)
        }
      }
    }
    let archived = model.archivedConditions
    if !archived.isEmpty {
      WorkspaceConditionsFoldHeading(
        title: "Archived", count: archived.count, isFolded: !model.showsArchivedConditions,
        isCursor: cursor == .archived, hasKeyboard: hasKeyboard && cursor == .archived
      ) { model.showsArchivedConditions.toggle() }
      .id(WorkspaceConditionsStop.archived.anchor)
      if model.showsArchivedConditions {
        ForEach(archived) { condition in
          manageRow(condition, cursor: cursor, hasKeyboard: hasKeyboard, counts: counts)
        }
      }
    }
    if let error = model.errorMessage {
      Text(error)
        .font(theme.captionFont)
        .foregroundStyle(theme.danger)
        .focusSurfaceGutter()
        .padding(.vertical, theme.space.xs)
    }
  }
}

extension WorkspaceConditionsPane {
  /// A condition's row in the lower half, and under it, when `o` asked, the
  /// open tasks that need it.
  @ViewBuilder
  fileprivate func manageRow(
    _ condition: TaskCondition, cursor: WorkspaceConditionsStop, hasKeyboard: Bool, counts: [String: Int]
  ) -> some View {
    let stop = WorkspaceConditionsStop.condition(condition.id)
    WorkspaceConditionManageRow(
      condition: condition, requiredBy: counts[condition.id] ?? 0,
      isRenaming: model.renamingConditionID == condition.id,
      isCursor: cursor == stop, hasKeyboard: hasKeyboard && cursor == stop)
      .id(stop.anchor)
    if model.conditionTasksShownFor == condition.id {
      WorkspaceConditionTasksList(tasks: model.conditionTasks)
    }
  }
}

/// The open tasks a condition gates, under its row: `o`. Clicking one shows
/// it where it lives.
private struct WorkspaceConditionTasksList: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let tasks: [ConditionRequiringTask]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if tasks.isEmpty {
        Text("No open task needs it.")
          .foregroundStyle(theme.dim)
          .padding(.vertical, theme.space.xxs)
      }
      ForEach(tasks) { task in
        Button { model.revealRequiringTask(task.id) } label: {
          HStack(spacing: theme.space.sm) {
            Text(task.title).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: theme.space.xs)
            Text(task.listName).foregroundStyle(theme.dim).lineLimit(1)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .padding(.vertical, theme.space.xxs)
        .help("Show it where it lives")
      }
    }
    .font(theme.captionFont)
    .padding(.leading, theme.paneGutter + 14 + theme.space.sm)
    .padding(.trailing, theme.paneGutter)
    .padding(.bottom, theme.space.xs)
    .overlay(alignment: .leading) {
      Rectangle().fill(theme.border).frame(width: 1)
        .padding(.leading, theme.paneGutter + 6)
    }
  }
}

/// A category's heading in the Conditions half, with a disclosure: click, or
/// `z`, folds it. Folded, it is a row the cursor stands on and says how many
/// conditions it holds.
private struct WorkspaceConditionsFoldHeading: View {
  @Environment(\.theme) private var theme
  let title: String
  let count: Int
  let isFolded: Bool
  let isCursor: Bool
  let hasKeyboard: Bool
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: theme.space.xs) {
      Image(systemName: isFolded ? "chevron.right" : "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(theme.dim)
        .frame(width: 10)
      Text(title)
        .foregroundStyle(theme.muted)
        .lineLimit(1)
      if isFolded {
        Text("\(count)")
          .font(theme.monoCaptionFont)
          .monospacedDigit()
          .foregroundStyle(theme.dim)
      }
      Spacer(minLength: 0)
    }
    .font(theme.captionFont)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, theme.paneGutter)
    .padding(.top, theme.space.sm)
    .padding(.bottom, theme.space.xxs)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: isCursor, hasKeyboard: hasKeyboard)
    .onTapGesture(perform: toggle)
    .commandHelp(.conditionsFold)
    .accessibilityAddTraits([.isHeader, .isButton])
    .accessibilityLabel("\(title), \(isFolded ? "folded" : "open")")
  }
}

/// A section's eyebrow, with whatever the section puts at its right.
private struct WorkspaceConditionsSectionHeader<Trailing: View>: View {
  @Environment(\.theme) private var theme
  let title: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: theme.space.xs) {
      MicroLabel(title)
      Spacer(minLength: theme.space.xs)
      trailing
    }
    .focusSurfaceGutter()
    .padding(.top, theme.space.md)
    .padding(.bottom, theme.space.xs)
  }
}

/// A category's heading in either half: quieter than the half's own.
private struct WorkspaceConditionsCategoryHeading: View {
  @Environment(\.theme) private var theme
  let title: String

  var body: some View {
    Text(title)
      .font(theme.captionFont)
      .foregroundStyle(theme.muted)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .focusSurfaceGutter()
      .padding(.top, theme.space.sm)
      .padding(.bottom, theme.space.xxs)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A condition you can say holds: a box, or a radio under Location, since
/// you are in one place at a time. Clicking it turns it on or off. One a
/// setting provides is on with a note of what provides it ("from Home");
/// turned off, it reads "off for now" until that setting changes.
private struct WorkspaceAvailableConditionRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let condition: TaskCondition
  let isOn: Bool
  /// "from Home" or "off for now"; nil for one said to hold, or off.
  let note: String?
  /// How many held-back tasks wait on it.
  let waiting: Int
  let isCursor: Bool
  let hasKeyboard: Bool

  private var glyph: String {
    if condition.isLocation { return isOn ? "largecircle.fill.circle" : "circle" }
    return isOn ? "checkmark.square.fill" : "square"
  }

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: glyph)
        .foregroundStyle(isOn ? theme.primary : theme.dim)
        .frame(width: 14)
      Text(condition.name)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .lineLimit(1)
      if let note {
        Text(note)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: theme.space.sm)
      if condition.isArchived {
        Text("Archived").font(theme.captionFont).foregroundStyle(theme.dim)
      }
      if waiting > 0, !isOn {
        Text("\(waiting) waiting")
          .font(theme.captionFont)
          .foregroundStyle(theme.warning)
          .help("\(waiting) open \(waiting == 1 ? "task waits" : "tasks wait") for it")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, theme.rowVerticalPadding)
    .padding(.horizontal, theme.paneGutter)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: isCursor, hasKeyboard: hasKeyboard)
    .onTapGesture {
      model.conditionsCursor = .available(condition.id)
      model.reportKeyboardFocus(.conditions)
      model.toggleFocusCondition(condition)
    }
    .commandHelp(
      .conditionsToggle,
      note: condition.isLocation ? "A location: turning it on replaces the last one"
        : note != nil ? "Provided by a setting: off stays off until that setting changes" : "Combines with the rest")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(note.map { "\(condition.name), \($0)" } ?? condition.name)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
  }
}

/// A setting in "Available now": its name, then its value, with arrows on
/// the cursor's row saying `←` `→` change it. A click puts the cursor on it.
private struct WorkspaceConditionsSettingRow<Value: View>: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let title: String
  let stop: WorkspaceConditionsStop
  let isCursor: Bool
  let hasKeyboard: Bool
  let note: String
  @ViewBuilder var value: Value

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Text(title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .lineLimit(1)
      Spacer(minLength: theme.space.sm)
      if isCursor { Image(systemName: "chevron.left").foregroundStyle(theme.dim) }
      value
      if isCursor { Image(systemName: "chevron.right").foregroundStyle(theme.dim) }
    }
    .font(theme.captionFont)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, theme.rowVerticalPadding)
    .padding(.horizontal, theme.paneGutter)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: isCursor, hasKeyboard: hasKeyboard)
    .onTapGesture {
      model.conditionsCursor = stop
      model.reportKeyboardFocus(.conditions)
    }
    .commandHelp(.conditionsAdjust, note: note)
  }
}

/// Where you are, as one row: `←` `→` step through the places an open task
/// needs, from nowhere in particular; the menu picks one with the mouse.
private struct WorkspaceLocationRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let waiting: [String: Int]
  let isCursor: Bool
  let hasKeyboard: Bool

  var body: some View {
    WorkspaceConditionsSettingRow(
      title: "Where you are", stop: .location, isCursor: isCursor, hasKeyboard: hasKeyboard,
      note: "One place at a time; tasks that need another wait"
    ) {
      ThemedMenu(model.currentPlace?.name ?? "Anywhere") {
        Button("Anywhere") { model.setFocusPlace(nil) }
        ForEach(model.availablePlaces) { place in
          let count = waiting[place.id] ?? 0
          Button(count > 0 ? "\(place.name) — \(count) waiting" : place.name) { model.setFocusPlace(place) }
        }
      }
    }
  }
}

/// Your free time: how long is left and when it runs out. `←` `→` take or
/// give a quarter of an hour; typing a number, Return or a click opens the
/// field, which reads 45, 1h30, 17:00 or 5pm.
private struct WorkspaceTimeRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let isCursor: Bool
  let hasKeyboard: Bool
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    WorkspaceConditionsSettingRow(
      title: "Free time", stop: .time, isCursor: isCursor, hasKeyboard: hasKeyboard,
      note: "A quarter of an hour less or more; type 45, 1h30 or 5pm to set it"
    ) {
      if model.conditionsTimeEntry != nil {
        TextField("", text: Binding(get: { model.conditionsTimeEntry ?? "" }, set: { model.conditionsTimeEntry = $0 }),
          prompt: Text("45, 1h30, 5pm"))
          .themedTextField()
          .frame(width: 110)
          .focused($isFieldFocused)
          .onSubmit { model.commitTypedAvailableTime() }
          .onExitCommand { model.cancelTypedAvailableTime() }
          .onAppear {
            // SwiftUI selects a field's text on focus, so the digit that
            // opened it would be typed over: the caret goes after it.
            DispatchQueue.main.async {
              isFieldFocused = true
              DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
              }
            }
          }
      } else {
        // Redrawn each minute, so the minutes left count down.
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(Self.text(until: model.availableUntil, minutesLeft: model.availableMinutesLeft(now: context.date)))
            .foregroundStyle(model.availableUntil == nil ? theme.muted : theme.ink)
            .monospacedDigit()
            .onTapGesture { model.beginTypingAvailableTime() }
        }
      }
    }
  }

  private static func text(until end: Date?, minutesLeft: Int?) -> String {
    guard let end, let minutes = minutesLeft else { return "No limit" }
    let left = minutes >= 60
      ? "\(minutes / 60)h" + (minutes % 60 == 0 ? "" : " \(minutes % 60)m")
      : "\(minutes) min"
    return "\(left) · until \(end.formatted(date: .omitted, time: .shortened))"
  }
}

/// The row a new condition is named in. Return in the field makes it and
/// leaves the caret there for the next; Esc, or Return with nothing typed,
/// hands the keyboard back to the cursor.
private struct WorkspaceNewConditionRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let isCursor: Bool
  let hasKeyboard: Bool
  @State private var name = ""
  @FocusState private var isFieldFocused: Bool

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: "plus")
        .foregroundStyle(theme.muted)
        .frame(width: 14)
      TextField("New condition", text: $name, prompt: Text("New condition — Home, Floor space…"))
        .themedTextField()
        .focused($isFieldFocused)
        .onSubmit(create)
        .onExitCommand {
          isFieldFocused = false
          model.finishConditionsEditing()
        }
      WorkspaceConditionCategoryMenu(
        category: model.newConditionCategory,
        choose: { model.newConditionCategory = $0 },
        newCategory: { model.presentConditionCategoryFinder(for: nil) })
    }
    .font(theme.captionFont)
    .padding(.vertical, theme.rowVerticalPadding)
    .padding(.horizontal, theme.paneGutter)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: isCursor, hasKeyboard: hasKeyboard)
    .onTapGesture { model.conditionsCursor = .add }
    .onChange(of: isFieldFocused) { _, focused in
      if focused { model.conditionsCursor = .add }
    }
    .onChange(of: model.conditionsAddFieldRequest) { _, _ in
      DispatchQueue.main.async { isFieldFocused = true }
    }
    .commandHelp(.conditionsNew, note: "Return makes it")
  }

  private func create() {
    guard !trimmed.isEmpty else {
      isFieldFocused = false
      model.finishConditionsEditing()
      return
    }
    // The category stays chosen, for the next one in it.
    guard model.createCondition(name: trimmed, category: model.newConditionCategory) != nil else { return }
    name = ""
    DispatchQueue.main.async { isFieldFocused = true }
  }
}

/// One condition to manage: its name (a field while it is being renamed),
/// what it provides, how many open tasks need it, its category, and
/// archiving.
private struct WorkspaceConditionManageRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let condition: TaskCondition
  let requiredBy: Int
  let isRenaming: Bool
  let isCursor: Bool
  let hasKeyboard: Bool

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: condition.isLocation ? "location" : "checkmark.square")
        .foregroundStyle(condition.isArchived ? theme.dim : theme.muted)
        .frame(width: 14)
      if isRenaming {
        WorkspaceConditionNameField(condition: condition)
      } else {
        Text(condition.name)
          .font(theme.bodyFont())
          .foregroundStyle(condition.isArchived ? theme.muted : theme.ink)
          .lineLimit(1)
        if condition.isArchived {
          Text("Archived").font(theme.captionFont).foregroundStyle(theme.dim)
        }
        if let provided = model.providedNames(of: condition) {
          Text("provides \(provided)")
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .onTapGesture { model.presentProvidesPicker(for: condition) }
            .commandHelp(.conditionsProvides)
        }
        Spacer(minLength: theme.space.xs)
      }
      if requiredBy > 0 {
        Text("\(requiredBy)")
          .font(theme.monoCaptionFont)
          .monospacedDigit()
          .foregroundStyle(theme.dim)
          .help("\(requiredBy) open \(requiredBy == 1 ? "task needs" : "tasks need") it")
      }
      WorkspaceConditionCategoryMenu(
        category: condition.category,
        choose: { model.setConditionCategory(condition, category: $0) },
        newCategory: { model.presentConditionCategoryFinder(for: condition) })
      Button { model.saveCondition(condition, name: condition.name, isArchived: !condition.isArchived) } label: {
        Image(systemName: condition.isArchived ? "arrow.uturn.backward" : "archivebox")
      }
      .buttonStyle(.plain)
      .focusable(false)
      .foregroundStyle(theme.muted)
      .commandHelp(.conditionsArchive, note: condition.isArchived ? "Restore it" : "Archive it")
      .accessibilityLabel(condition.isArchived ? "Restore \(condition.name)" : "Archive \(condition.name)")
    }
    .font(theme.captionFont)
    .padding(.vertical, theme.rowVerticalPadding)
    .padding(.horizontal, theme.paneGutter)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: isCursor, hasKeyboard: hasKeyboard)
    .onTapGesture(count: 2) {
      model.conditionsCursor = .condition(condition.id)
      model.renamingConditionID = condition.id
    }
    .onTapGesture {
      model.conditionsCursor = .condition(condition.id)
      model.reportKeyboardFocus(.conditions)
    }
    .commandHelp(.conditionsEdit, note: "Double-click to rename")
  }

}

/// A condition's name as a field: Return saves the rename, Esc drops it.
/// Tasks refer to a condition by its identity, so a rename carries every
/// requirement with it.
private struct WorkspaceConditionNameField: View {
  @Environment(WorkspaceViewModel.self) private var model
  let condition: TaskCondition
  @State private var name: String
  @FocusState private var isFocused: Bool

  init(condition: TaskCondition) {
    self.condition = condition
    _name = State(initialValue: condition.name)
  }

  var body: some View {
    TextField("Name", text: $name)
      .themedTextField()
      .focused($isFocused)
      .onSubmit(save)
      .onExitCommand { finish() }
      .onAppear { DispatchQueue.main.async { isFocused = true } }
      // Clicking away keeps what was typed, as leaving any field does.
      .onChange(of: isFocused) { _, focused in
        if !focused, model.renamingConditionID == condition.id { save() }
      }
  }

  private func save() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, trimmed != condition.name {
      model.saveCondition(condition, name: trimmed, isArchived: condition.isArchived)
    }
    finish()
  }

  private func finish() {
    guard model.renamingConditionID == condition.id else { return }
    model.finishConditionsEditing()
  }
}
