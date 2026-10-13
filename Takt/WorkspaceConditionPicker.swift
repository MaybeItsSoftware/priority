import SwiftUI
import TaktCore
import TaktWorkspace

struct WorkspaceConditionPickerRequest: Identifiable {
  let id = UUID()
  let task: WorkspaceTask
}

/// The conditions a task needs, ticked from the keyboard: `cc`.
///
/// Requiring a condition used to be a menu in the inspector's Plan section,
/// and a condition that did not exist yet meant a trip to the Conditions tab
/// first. Here every condition is a row with a box: type to narrow, Space or
/// Return ticks the row you are on, and a name nothing is called yet offers
/// "New condition" — made and required in one Return. It stays up, so a task
/// that needs two things takes two ticks and one Esc.
struct WorkspaceConditionPicker: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceConditionPickerRequest
  @State private var query = ""
  @State private var selection: Int?
  /// The task's requirements, read when the picker opens and again after
  /// every tick, so the boxes show what was saved rather than what was meant.
  @State private var groups: [[String]]?
  /// Whether the last key moved the cursor rather than typed. Space ticks
  /// then, or with nothing typed; otherwise it is a space in the name,
  /// because "Floor space" has one.
  @State private var hasMoved = false

  private static let newRowID = "new-condition"

  /// Every condition you could require, plus any archived one this task
  /// already needs so it can be ticked off. Under their category headings
  /// with nothing typed; filtered the way the list finder filters once you
  /// type, and never reordered by a tick.
  private var conditions: [TaskCondition] {
    let offered = TaskConditionSection.sections(model.focusConditions.filter {
      !$0.isArchived || TaskRequirementToggle.requires($0.id, in: groups)
    }).flatMap(\.conditions)
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return offered }
    let scored: [(TaskCondition, Int)] = offered.compactMap { condition in
      WorkspaceCommandQuery.fuzzyScore(needle, in: condition.name).map { (condition, $0) }
    }
    return scored.enumerated()
      .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
      .map(\.element.0)
  }

  /// What the last row would make: the name typed, when no condition —
  /// archived ones included — is called that already.
  private var newName: String? {
    let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      !model.focusConditions.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame })
    else { return nil }
    return name
  }

  var body: some View {
    let items = conditions
    let new = newName
    let counts = model.conditionRequirementCounts
    VStack(spacing: 0) {
      WorkspaceOverlayField(
        symbol: "location", prompt: "Needs… or type a new condition", text: $query, context: request.task.title)
      FocusRule()
      if items.isEmpty && new == nil {
        WorkspaceOverlayHint(text: model.focusConditions.isEmpty
          ? "No conditions yet. Type one — Home, Campus, Floor space — and Return."
          : "No condition matches.")
          .frame(height: WorkspaceOverlayMetrics.listHeight)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(items.enumerated()), id: \.element.id) { index, condition in
                if let heading = heading(before: index, in: items) {
                  Text(heading)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.muted)
                    .padding(.horizontal, theme.space.md)
                    .padding(.top, theme.space.sm)
                    .padding(.bottom, theme.space.xxs)
                    .accessibilityAddTraits(.isHeader)
                }
                row(condition, count: counts[condition.id] ?? 0)
                  .overlayRow(isSelected: index == (selection ?? 0))
                  .id(condition.id)
                  .onTapGesture { choose(index) }
              }
              if let new {
                Label("New condition “\(new)”", systemImage: "plus")
                  .font(theme.bodyFont())
                  .foregroundStyle(theme.primary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .overlayRow(isSelected: items.count == (selection ?? 0))
                  .id(Self.newRowID)
                  .onTapGesture { choose(items.count) }
              }
            }
          }
          .frame(height: WorkspaceOverlayMetrics.listHeight)
          .onChange(of: selection) { _, index in
            guard let index else { return }
            proxy.scrollTo(items.indices.contains(index) ? items[index].id : Self.newRowID)
          }
        }
      }
      WorkspaceOverlayFooter(
        hints: "↑↓ choose · space or ↩ tick · ⌘↩ manage · esc done",
        trailing: summary)
    }
    .onAppear { groups = model.requirementGroups(of: request.task) }
    .onChange(of: query) { _, _ in
      selection = nil
      hasMoved = false
    }
    .overlayKeys(model, id: overlayID) { key in
      let rowCount = conditions.count + (newName == nil ? 0 : 1)
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? 0, by: step, count: rowCount)
        hasMoved = true
        return true
      }
      switch key {
      case "space":
        guard hasMoved || query.isEmpty else { return false }
        choose(selection ?? 0)
        return true
      case "enter":
        choose(selection ?? 0)
        // Typed to find it, so the next name starts from an empty field.
        if !query.isEmpty { query = "" }
        return true
      case "cmd+enter":
        model.dismissOverlay(restoringFocus: false)
        model.openConditionsTab(onNewCondition: true)
        return true
      default:
        return false
      }
    }
  }

  private func row(_ condition: TaskCondition, count: Int) -> some View {
    let isRequired = TaskRequirementToggle.requires(condition.id, in: groups)
    return HStack(spacing: theme.space.sm) {
      Image(systemName: isRequired ? "checkmark.square.fill" : "square")
        .foregroundStyle(isRequired ? theme.primary : theme.muted)
      Text(condition.name)
        .font(theme.bodyFont())
        .foregroundStyle(condition.isArchived ? theme.muted : theme.ink)
        .lineLimit(1)
      if let alternatives = alternatives(to: condition) {
        Text("or \(alternatives)")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .lineLimit(1)
      }
      Spacer(minLength: theme.space.sm)
      // Typed into, the rows leave their headings, so each says its own.
      if !query.trimmingCharacters(in: .whitespaces).isEmpty {
        Text(condition.categoryTitle).font(theme.captionFont).foregroundStyle(theme.muted)
      }
      if condition.isArchived { Text("Archived").font(theme.captionFont).foregroundStyle(theme.dim) }
      if count > 0 {
        Text("\(count)")
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
          .help("\(count) open \(count == 1 ? "task needs" : "tasks need") it")
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isRequired ? .isSelected : [])
  }

  /// The category heading that starts at `index`, with nothing typed.
  private func heading(before index: Int, in items: [TaskCondition]) -> String? {
    guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    guard index == 0 || items[index - 1].categoryTitle != items[index].categoryTitle else { return nil }
    return items[index].categoryTitle
  }

  /// The other conditions sharing a requirement with this one — "or Campus"
  /// — so an either-or set in the inspector reads as one here too.
  private func alternatives(to condition: TaskCondition) -> String? {
    guard let group = (groups ?? []).first(where: { $0.contains(condition.id) && $0.count > 1 }) else { return nil }
    return group.filter { $0 != condition.id }
      .map { id in model.focusConditions.first { $0.id == id }?.name ?? "Missing condition" }
      .joined(separator: " or ")
  }

  /// What the task needs, as the footer's count: "Needs Home + Floor space".
  private var summary: String? {
    guard let groups, !groups.isEmpty else { return "Anytime" }
    return groups.map { group in
      group.map { id in model.focusConditions.first { $0.id == id }?.name ?? "?" }.joined(separator: " or ")
    }.joined(separator: " + ")
  }

  private func choose(_ index: Int) {
    let items = conditions
    if items.indices.contains(index) {
      groups = model.toggleRequirement(items[index].id, on: request.task)
    } else if index == items.count, let name = newName {
      groups = model.requireNewCondition(named: name, on: request.task)
    }
  }
}

@MainActor
extension WorkspaceViewModel {
  /// `cc`: the conditions picker, on the selected task. With no task — or a
  /// list, which is never offered as work — the Conditions tab, where the
  /// conditions themselves are made and renamed.
  func presentConditionPicker() {
    guard let task = selectedTask, !task.isList else {
      openConditionsTab(onNewCondition: true)
      return
    }
    presentOverlay(.conditions(WorkspaceConditionPickerRequest(task: task)))
  }

  /// The task's saved requirements, read from the store rather than the
  /// ranking's cache so a task the ranking skips still answers.
  func requirementGroups(of task: WorkspaceTask) -> [[String]]? {
    (try? store?.taskEditorSnapshot(for: task.id))?.planning?.requirementGroups
  }

  /// Ticks a condition on the task, or off: one "Edit Task" step to undo.
  /// Returns the requirements as saved.
  @discardableResult
  func toggleRequirement(_ conditionID: String, on task: WorkspaceTask) -> [[String]]? {
    let places = Set(focusConditions.filter(\.isLocation).map(\.id))
    editTaskValues(of: task) { values in
      values.requirementGroups = TaskRequirementToggle.toggling(conditionID, in: values.requirementGroups, places: places)
    }
    return requirementGroups(of: task)
  }

  /// Makes a condition and requires it on the task. Two steps to undo — the
  /// requirement, then the condition — because the condition outlives the
  /// task it was made for.
  @discardableResult
  func requireNewCondition(named name: String, on task: WorkspaceTask) -> [[String]]? {
    guard let condition = createCondition(name: name, category: nil) else { return requirementGroups(of: task) }
    return toggleRequirement(condition.id, on: task)
  }
}
