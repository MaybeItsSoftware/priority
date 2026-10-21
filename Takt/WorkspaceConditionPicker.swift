import SwiftUI
import TaktCore
import TaktWorkspace

struct WorkspaceConditionPickerRequest: Identifiable {
  /// What the ticks are for: a task that exists, saved as each is ticked,
  /// one still being typed in the add field, whose ticks wait in its slot
  /// until Return files them with it, or a condition, whose ticks are what
  /// it provides — `p` in the Conditions tab.
  enum Target {
    case task(WorkspaceTask)
    case draft(title: String, groups: Binding<[[String]]>)
    case provides(TaskCondition)
  }

  let id = UUID()
  let target: Target

  init(task: WorkspaceTask) { target = .task(task) }
  init(draftTitle: String, groups: Binding<[[String]]>) { target = .draft(title: draftTitle, groups: groups) }
  init(provides condition: TaskCondition) { target = .provides(condition) }

  var title: String {
    switch target {
    case .task(let task): task.title
    case .draft(let title, _): title.isEmpty ? "New task" : title
    case .provides(let condition): condition.name
    }
  }

  /// The condition whose ticks are what it provides, if that is the job.
  var provider: TaskCondition? {
    if case .provides(let condition) = target { return condition }
    return nil
  }
}

/// The conditions a task needs, ticked from the keyboard: `cc`.
///
/// Requiring a condition used to be a menu in the inspector's Plan section,
/// and a condition that did not exist yet meant a trip to the Conditions tab
/// first. Here every condition is a row with a box: type to narrow, Space or
/// Return ticks the row you are on, and a name nothing is called yet offers
/// "New condition" — made and required in one Return. It stays up, so a task
/// that needs two things takes two ticks and one Esc. `!` ticks the row as
/// *not* holding ("not Home"), or ticks a "not" off again.
///
/// Opened on a condition (`p` in the Conditions tab), the same list ticks
/// what that condition provides: Home, Floor space and Quiet. There is no
/// "not" there, and the condition itself is not offered.
struct WorkspaceConditionPicker: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceConditionPickerRequest
  /// The result list's height, fixed so it does not jump as matches narrow;
  /// nil to take whatever its container leaves, as in quick add's window.
  var listHeight: CGFloat? = WorkspaceOverlayMetrics.listHeight
  @State private var query = ""
  @State private var selection: Int?
  /// The task's requirements, read when the picker opens and again after
  /// every tick, so the boxes show what was saved rather than what was meant.
  @State private var groups: [[String]]?
  /// What the condition provides, when the picker is for one: read when it
  /// opens and again after every tick.
  @State private var provided: [String] = []
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
    let provider = request.provider
    let offered = TaskConditionSection.sections(model.focusConditions.filter {
      if let provider { return $0.id != provider.id && (!$0.isArchived || provided.contains($0.id)) }
      return !$0.isArchived || TaskRequirementToggle.requires($0.id, in: groups)
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
        symbol: "location",
        prompt: request.provider == nil ? "Needs… or type a new condition" : "Provides… or type a new condition",
        text: $query, context: request.title)
      FocusRule()
      if items.isEmpty && new == nil {
        WorkspaceOverlayHint(text: model.focusConditions.isEmpty
          ? "No conditions yet. Type one — Home, Campus, Floor space — and Return."
          : "No condition matches.")
          .frame(minHeight: listHeight, maxHeight: listHeight ?? .infinity)
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
          .frame(minHeight: listHeight, maxHeight: listHeight ?? .infinity)
          .onChange(of: selection) { _, index in
            guard let index else { return }
            proxy.scrollTo(items.indices.contains(index) ? items[index].id : Self.newRowID)
          }
        }
      }
      WorkspaceOverlayFooter(
        hints: request.provider == nil
          ? "↑↓ choose · space or ↩ tick · ! not · ⌘↩ manage · esc done"
          : "↑↓ choose · space or ↩ tick · esc done",
        trailing: summary)
    }
    .onAppear {
      groups = currentGroups
      if let provider = request.provider { provided = model.providedIDs(of: provider) }
    }
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
      // `!`, which a name could hold but almost never does: on a condition's
      // row it ticks "not"; on the new-condition row it is typed.
      case "shift+1", "!":
        let index = selection ?? 0
        guard request.provider == nil, conditions.indices.contains(index) else { return false }
        choose(index, negated: true)
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
    let requirement = request.provider == nil ? TaskRequirementToggle.requirement(of: condition.id, in: groups) : nil
    let isRequired = requirement != nil || (request.provider != nil && provided.contains(condition.id))
    let isNegated = requirement?.isNegated == true
    return HStack(spacing: theme.space.sm) {
      Image(systemName: isNegated ? "minus.square.fill" : isRequired ? "checkmark.square.fill" : "square")
        .foregroundStyle(isRequired ? theme.primary : theme.muted)
      (Text(isNegated ? "not " : "").foregroundStyle(theme.muted)
        + Text(condition.name).foregroundStyle(condition.isArchived ? theme.muted : theme.ink))
        .font(theme.bodyFont())
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
    .accessibilityValue(isNegated ? "Needed not to hold" : "")
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
    let names = { (member: String) in TaskRequirement(member).conditionID == condition.id }
    guard let group = (groups ?? []).first(where: { $0.contains(where: names) && $0.count > 1 }) else { return nil }
    return TaskRequirement.label(group: group.filter { !names($0) }, name: model.conditionName)
  }

  /// What the task needs, as the footer's count: "Needs Home + Floor space";
  /// for a condition, what it provides.
  private var summary: String? {
    if request.provider != nil {
      let names = model.focusConditions.filter { provided.contains($0.id) }.map(\.name)
      return names.isEmpty ? "Provides nothing" : "Provides " + names.joined(separator: ", ")
    }
    guard let groups, !groups.isEmpty else { return "Anytime" }
    return groups.map { TaskRequirement.label(group: $0, missing: "?", name: model.conditionName) }.joined(separator: " + ")
  }

  /// The requirements as they stand: saved on the task, or held by the draft.
  private var currentGroups: [[String]]? {
    switch request.target {
    case .task(let task): model.requirementGroups(of: task)
    case .draft(_, let groups): groups.wrappedValue
    case .provides: nil
    }
  }

  /// Ticks the row at `index`, or off; `negated` ticks it as "not", or a
  /// "not" off.
  private func choose(_ index: Int, negated: Bool = false) {
    let items = conditions
    let conditionID: String
    if items.indices.contains(index) {
      conditionID = items[index].id
    } else if index == items.count, let name = newName {
      if case .provides(let provider) = request.target {
        // Made, with no category, and ticked at once: Home provides
        // "Garden" the moment it is named.
        guard let condition = model.createCondition(name: name, category: nil) else { return }
        provided = model.toggleProvided(condition.id, by: provider)
        return
      }
      if case .task(let task) = request.target {
        groups = model.requireNewCondition(named: name, on: task)
        return
      }
      // Made now — a condition outlives the task it was made for — and
      // ticked on the draft, to be required when the task is.
      guard let condition = model.createCondition(name: name, category: nil) else { return }
      conditionID = condition.id
    } else {
      return
    }
    switch request.target {
    case .task(let task):
      groups = model.toggleRequirement(conditionID, on: task, negated: negated)
    case .draft(_, let binding):
      binding.wrappedValue = model.toggling(conditionID, in: binding.wrappedValue, negated: negated) ?? []
      groups = binding.wrappedValue
    case .provides(let provider):
      provided = model.toggleProvided(conditionID, by: provider)
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

  /// Ticks a condition on the task, or off — as "not" when `negated` — in
  /// one "Edit Task" step to undo. Returns the requirements as saved.
  @discardableResult
  func toggleRequirement(_ conditionID: String, on task: WorkspaceTask, negated: Bool = false) -> [[String]]? {
    editTaskValues(of: task) { values in
      values.requirementGroups = toggling(conditionID, in: values.requirementGroups, negated: negated)
    }
    return requirementGroups(of: task)
  }

  /// `groups` with a condition ticked on or off, or as "not" when `negated`.
  func toggling(_ conditionID: String, in groups: [[String]]?, negated: Bool) -> [[String]]? {
    if negated { return TaskRequirementToggle.negating(conditionID, in: groups) }
    let places = Set(focusConditions.filter(\.isLocation).map(\.id))
    return TaskRequirementToggle.toggling(conditionID, in: groups, places: places)
  }

  /// `p` in the Conditions tab: the picker, ticking what `condition`
  /// provides.
  func presentProvidesPicker(for condition: TaskCondition) {
    presentOverlay(.conditions(WorkspaceConditionPickerRequest(provides: condition)))
  }

  /// What a condition provides, read from the store rather than the
  /// ranking's copy, which lags a tick made a moment ago.
  func providedIDs(of condition: TaskCondition) -> [String] {
    guard let store, let workspace else { return condition.provides }
    return (try? store.conditions(in: workspace.id))?.first { $0.id == condition.id }?.provides ?? condition.provides
  }

  /// The names of what a condition provides, in the tab's order, or nil
  /// when it provides nothing.
  func providedNames(of condition: TaskCondition) -> String? {
    let names = focusConditions.filter { condition.provides.contains($0.id) && !$0.isArchived }.map(\.name)
    return names.isEmpty ? nil : names.joined(separator: ", ")
  }

  /// Ticks `conditionID` as provided by `provider`, or off, in one "Edit
  /// Condition" step to undo. Returns what it provides as saved.
  @discardableResult
  func toggleProvided(_ conditionID: String, by provider: TaskCondition) -> [String] {
    guard let store else { return provider.provides }
    var next = providedIDs(of: provider)
    if let index = next.firstIndex(of: conditionID) { next.remove(at: index) } else { next.append(conditionID) }
    perform {
      try store.setConditionProvides(id: provider.id, provides: next)
      reloadNextUpNow(); taskEditor.refresh(store: store)
    }
    return providedIDs(of: provider)
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
