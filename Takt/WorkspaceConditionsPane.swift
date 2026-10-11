import TaktCore
import TaktWorkspace
import SwiftUI

/// The right dock's Conditions tab, in two halves under one cursor.
///
/// **Available now** is the conditions that hold here — a place replaces the
/// last place, anything else combines — with the time you have, what you want
/// from it and when to stop trusting the answer. **Conditions** is the list
/// itself: add one, rename it in its row, make it a place, archive it, and
/// see how many open tasks need it.
///
/// `↑` `↓` walk both halves, Space turns a condition on or off, Return or F2
/// renames (on the new-condition row, puts the caret in its field), `p`
/// makes it a place, `e` archives it, `c` clears, Esc goes back to the work.
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
      if !model.focusContext.conditionIDs.isEmpty {
        Button("Clear") { model.clearFocusConditions() }
          .buttonStyle(.plain)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .commandHelp(.conditionsClear)
      } else {
        Text("Anywhere").font(theme.captionFont).foregroundStyle(theme.dim)
      }
    }
    if model.focusConditions.isEmpty {
      Text(WorkspaceConditionCopy.explanation + " None yet: add one below.")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .fixedSize(horizontal: false, vertical: true)
        .focusSurfaceGutter()
        .padding(.bottom, theme.space.sm)
    }
    ForEach(model.selectableFocusConditions) { condition in
      let stop = WorkspaceConditionsStop.available(condition.id)
      WorkspaceAvailableConditionRow(
        condition: condition,
        isOn: model.focusContext.conditionIDs.contains(condition.id),
        isCursor: cursor == stop, hasKeyboard: hasKeyboard && cursor == stop)
        .id(stop.anchor)
    }
    if !model.suggestedContextIDs.isEmpty {
      lastContext
    }
    timeControls
  }

  /// The conditions that held before the last context expired, offered back.
  private var lastContext: some View {
    HStack(spacing: theme.space.sm) {
      Text("Last context: " + model.suggestedContextIDs.sorted().map { id in
        model.focusConditions.first(where: { $0.id == id })?.name ?? ""
      }.joined(separator: ", "))
      .foregroundStyle(theme.muted)
      .lineLimit(2)
      Spacer(minLength: theme.space.xs)
      Button("Use again") { model.confirmSuggestedContext() }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary)
        .commandHelp(.conditionsUseAgain)
      Button("Dismiss") { model.suggestedContextIDs = [] }
        .buttonStyle(.plain)
        .foregroundStyle(theme.muted)
    }
    .font(theme.captionFont)
    .focusSurfaceGutter()
    .padding(.vertical, theme.space.xs)
  }

  /// The time you have, what you want from it, and when the answer lapses.
  private var timeControls: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      ThemedControlRow("Available time") {
        HStack(spacing: theme.space.xs) {
          ThemedMenu(model.availableUntil.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "No limit") {
            Button("No time limit") { setAvailableUntil(nil) }
            ForEach([15, 30, 60, 90], id: \.self) { minutes in
              Button("\(minutes) minutes") { setAvailableUntil(Date.now.addingTimeInterval(Double(minutes * 60))) }
            }
            Button("Choose end time") { setAvailableUntil(Date.now.addingTimeInterval(1800)) }
          }
          if let end = model.availableUntil {
            ThemedDateField(
              selection: Binding(get: { model.availableUntil ?? end }, set: { setAvailableUntil($0) }),
              includesTime: true)
          }
        }
      }
      ThemedControlRow("Goal") {
        ThemedSegmentedPicker(
          selection: Binding(get: { model.focusContext.mode }, set: { model.focusContext.mode = $0; model.focusContextChanged() }),
          options: [
            ThemedPickerOption("Progress", value: FocusTimeMode.progress),
            ThemedPickerOption("Finish", value: FocusTimeMode.finish),
          ])
        .accessibilityLabel("Goal: make progress or finish something")
        .help("Make progress on something, or finish something in the time you have")
      }
      HStack(spacing: theme.space.sm) {
        Toggle("Context expires", isOn: Binding(get: { model.contextExpiresAt != nil }, set: {
          model.contextExpiresAt = $0 ? Date.now.addingTimeInterval(3600) : nil; model.focusContextChanged()
        }))
        .toggleStyle(.themedSwitch)
        .help("When it lapses the conditions are set aside and offered back with Use again")
        if let end = model.contextExpiresAt {
          ThemedDateField(
            selection: Binding(get: { model.contextExpiresAt ?? end }, set: { model.contextExpiresAt = $0; model.focusContextChanged() }),
            includesTime: true)
        }
      }
    }
    .font(theme.captionFont)
    .focusSurfaceGutter()
    .padding(.vertical, theme.space.md)
  }

  private func setAvailableUntil(_ date: Date?) {
    model.availableUntil = date
    model.focusContextChanged()
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
    ForEach(model.focusConditions) { condition in
      let stop = WorkspaceConditionsStop.condition(condition.id)
      WorkspaceConditionManageRow(
        condition: condition, requiredBy: counts[condition.id] ?? 0,
        isRenaming: model.renamingConditionID == condition.id,
        isCursor: cursor == stop, hasKeyboard: hasKeyboard && cursor == stop)
        // Keyed on what it shows, so a rename or a switch saved elsewhere
        // starts the row's name field afresh.
        .id(stop.anchor)
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

/// A condition you can say holds: a box for a circumstance, a radio for a
/// place, since you are in one place at a time. Clicking it turns it on or off.
private struct WorkspaceAvailableConditionRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let condition: TaskCondition
  let isOn: Bool
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
      Spacer(minLength: theme.space.sm)
      if condition.isArchived {
        Text("Archived").font(theme.captionFont).foregroundStyle(theme.dim)
      }
      Text(condition.isLocation ? "Place" : "Circumstance")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
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
      note: condition.isLocation ? "A place: turning it on replaces the last one" : "A circumstance: combines with the rest")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(condition.name)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
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
  @State private var isLocation = false
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
      Toggle("Place", isOn: $isLocation)
        .toggleStyle(.themedSwitch)
        .fixedSize()
        .help("A place replaces the last place when you say where you are; anything else combines")
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
    guard model.createCondition(name: trimmed, isLocation: isLocation) != nil else { return }
    name = ""
    isLocation = false
    DispatchQueue.main.async { isFieldFocused = true }
  }
}

/// One condition to manage: its name (a field while it is being renamed),
/// how many open tasks need it, whether it is a place, and archiving.
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
      Image(systemName: condition.isLocation ? "location" : "checkmark.circle")
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
        Spacer(minLength: theme.space.xs)
      }
      if requiredBy > 0 {
        Text("\(requiredBy)")
          .font(theme.monoCaptionFont)
          .monospacedDigit()
          .foregroundStyle(theme.dim)
          .help("\(requiredBy) open \(requiredBy == 1 ? "task needs" : "tasks need") it")
      }
      Toggle("Place", isOn: Binding(get: { condition.isLocation }, set: { save(isLocation: $0) }))
        .toggleStyle(.themedSwitch)
        .fixedSize()
        .commandHelp(.conditionsTogglePlace)
      Button { save(isArchived: !condition.isArchived) } label: {
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

  private func save(isLocation: Bool? = nil, isArchived: Bool? = nil) {
    model.saveCondition(
      condition, name: condition.name, isLocation: isLocation ?? condition.isLocation,
      isArchived: isArchived ?? condition.isArchived)
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
      model.saveCondition(condition, name: trimmed, isLocation: condition.isLocation, isArchived: condition.isArchived)
    }
    finish()
  }

  private func finish() {
    guard model.renamingConditionID == condition.id else { return }
    model.finishConditionsEditing()
  }
}
