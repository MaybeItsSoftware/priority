import TaktCore
import TaktWorkspace
import SwiftUI

// MARK: - What is available now

/// The conditions that hold right now, from the keys: ↑↓ to a condition,
/// Space to turn it on or off, Return when done. Typing filters; ⌘↩ makes a
/// condition of what was typed and turns it on.
///
/// The same rule as every other way of setting it: a place replaces the last
/// place, a circumstance combines. The time window and the goal stay in the
/// status bar's popover, which is where the mouse goes.
struct WorkspaceAvailabilityPicker: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  @State private var query = ""
  @State private var selection: Int?

  private var conditions: [TaskCondition] {
    let all = model.selectableFocusConditions
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return all }
    return all.filter { WorkspaceCommandQuery.fuzzyScore(needle, in: $0.name) != nil }
  }

  /// What ⌘↩ would make: the typed name, when no condition has it already.
  private var newName: String? {
    let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      !model.focusConditions.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame })
    else { return nil }
    return name
  }

  var body: some View {
    let items = conditions
    VStack(spacing: 0) {
      WorkspaceOverlayField(
        symbol: "location", prompt: "What's available now? Type to filter or name a new one", text: $query,
        context: model.focusContextSummary ?? "Anywhere")
      FocusRule()
      if items.isEmpty {
        WorkspaceOverlayHint(text: emptyText)
          .padding(.horizontal, theme.listGutter)
          .multilineTextAlignment(.center)
          .frame(height: WorkspaceOverlayMetrics.listHeight)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(items.enumerated()), id: \.element.id) { index, condition in
                row(condition, isSelected: index == (selection ?? 0))
                  .id(condition.id)
                  .onTapGesture {
                    selection = index
                    model.toggleFocusCondition(condition)
                  }
              }
            }
          }
          .frame(height: WorkspaceOverlayMetrics.listHeight)
          .onChange(of: selection) { _, index in
            if let index, items.indices.contains(index) { proxy.scrollTo(items[index].id) }
          }
        }
      }
      WorkspaceOverlayFooter(
        hints: "↑↓ choose · space toggles · ↩ done · ⌘↩ new condition · esc close",
        trailing: "\(model.focusContext.conditionIDs.count) on")
    }
    .onChange(of: query) { _, _ in selection = nil }
    .overlayKeys(model, id: overlayID) { key in
      let items = conditions
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? 0, by: step, count: items.count)
        return true
      }
      switch key {
      // Space is a space once something is typed, so a name with one in it
      // can still be filtered for; Tab toggles either way.
      case "space" where query.isEmpty, "tab":
        let index = selection ?? 0
        if items.indices.contains(index) { model.toggleFocusCondition(items[index]) }
        return true
      case "enter":
        model.dismissOverlay()
        return true
      case "cmd+enter":
        if let name = newName, let created = model.createCondition(name: name, isLocation: false) {
          model.toggleFocusCondition(created)
          query = ""
        }
        return true
      default:
        return false
      }
    }
  }

  private var emptyText: String {
    if let newName { return "No condition matches. ⌘↩ makes “\(newName)” and turns it on." }
    return WorkspaceConditionCopy.explanation + " Type a name and press ⌘↩ to add one."
  }

  private func row(_ condition: TaskCondition, isSelected: Bool) -> some View {
    let isOn = model.focusContext.conditionIDs.contains(condition.id)
    return HStack(spacing: theme.space.sm) {
      Image(systemName: isOn ? "checkmark.square.fill" : "square")
        .foregroundStyle(isOn ? theme.primary : theme.dim)
      Text(condition.name)
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
    .font(theme.bodyFont())
    .overlayRow(isSelected: isSelected)
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
  }
}

// MARK: - Managing conditions

/// Adding, renaming and archiving conditions. Tasks refer to a condition by
/// its identity, so a rename carries every requirement with it.
///
/// It was a sheet hung off the retired focus pane; it is an overlay now, like
/// everything else drawn over the window.
struct WorkspaceConditionsManager: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  @State private var newName = ""
  @State private var newIsLocation = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: theme.space.sm) {
        WorkspaceOverlayField(symbol: "plus", prompt: "New condition — name", text: $newName)
        Toggle("Place", isOn: $newIsLocation)
          .toggleStyle(.themedSwitch)
          .fixedSize()
          .font(theme.captionFont)
          .help("A place replaces the last place when you say where you are; anything else combines")
          .padding(.trailing, theme.listGutter)
      }
      FocusRule()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(WorkspaceConditionCopy.explanation + " Renaming keeps every task's requirements.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.listGutter)
            .padding(.vertical, theme.space.sm)
          ForEach(model.focusConditions) { condition in
            WorkspaceConditionEditorRow(condition: condition)
              .id("\(condition.id)-\(condition.name)-\(condition.isLocation)-\(condition.isArchived)")
          }
        }
      }
      .frame(height: WorkspaceOverlayMetrics.listHeight)
      if let error = model.errorMessage {
        Text(error)
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
          .padding(.horizontal, theme.listGutter)
          .padding(.vertical, theme.space.xs)
      }
      WorkspaceOverlayFooter(hints: "↩ add · esc close", trailing: "\(model.focusConditions.count)")
    }
    .overlayKeys(model, id: overlayID) { key in
      // Return in a row's name field saves that row; it only adds from the
      // new-condition field, which is the one holding text here.
      guard key == "enter", !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      if model.createCondition(name: newName, isLocation: newIsLocation) != nil {
        newName = ""
        newIsLocation = false
      }
      return true
    }
  }
}

/// One condition: its name (Return saves a rename), whether it is a place,
/// and whether it is archived. The switches save as they flip.
private struct WorkspaceConditionEditorRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let condition: TaskCondition
  @State private var name: String

  init(condition: TaskCondition) {
    self.condition = condition
    _name = State(initialValue: condition.name)
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    HStack(spacing: theme.space.sm) {
      TextField("Name", text: $name)
        .themedTextField()
        .onSubmit(saveName)
      if trimmed != condition.name, !trimmed.isEmpty {
        Button("Rename", action: saveName)
          .buttonStyle(FocusActionButtonStyle())
      }
      Toggle("Place", isOn: Binding(get: { condition.isLocation }, set: { save(isLocation: $0) }))
        .toggleStyle(.themedSwitch)
        .fixedSize()
      Toggle("Archived", isOn: Binding(get: { condition.isArchived }, set: { save(isArchived: $0) }))
        .toggleStyle(.themedSwitch)
        .fixedSize()
        .help("Archived conditions are not offered for new requirements; tasks that need one keep it")
    }
    .font(theme.captionFont)
    .padding(.horizontal, theme.listGutter)
    .padding(.vertical, theme.space.xs)
  }

  private func saveName() {
    guard !trimmed.isEmpty, trimmed != condition.name else { return }
    model.saveCondition(condition, name: trimmed, isLocation: condition.isLocation, isArchived: condition.isArchived)
  }

  private func save(isLocation: Bool? = nil, isArchived: Bool? = nil) {
    model.saveCondition(
      condition, name: condition.name, isLocation: isLocation ?? condition.isLocation,
      isArchived: isArchived ?? condition.isArchived)
  }
}
