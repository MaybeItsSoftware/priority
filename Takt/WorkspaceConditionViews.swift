import TaktCore
import TaktWorkspace
import SwiftUI

/// The words conditions are explained in, once, so the inspector and the
/// Conditions tab say the same thing.
enum WorkspaceConditionCopy {
  static let explanation =
    "Conditions are places or circumstances a task needs — Home, Campus, Floor space — filed under categories."
  static let none = "No conditions — available whenever"
}

/// The status bar's word on where you are: the conditions on, or "Anywhere".
/// Click, or ⌥⌘8, for the right dock's Conditions tab.
struct WorkspaceFocusContextIndicator: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    let summary = model.focusContextSummary
    Button { model.toggleDockTab(.conditions) } label: {
      HStack(spacing: theme.space.xs) {
        Image(systemName: summary == nil ? "location.slash" : "location.fill")
          .foregroundStyle(summary == nil ? theme.dim : theme.primary)
        if !model.focusConditions.isEmpty {
          Text(summary ?? "Anywhere")
            .foregroundStyle(summary == nil ? theme.dim : theme.ink)
            .truncationMode(.tail)
            .frame(maxWidth: 200, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .commandHelp(
      .focusSetAvailable,
      note: summary.map { "Available now: \($0). Click to change" }
        ?? "Nothing set as available: only tasks with no conditions are offered. Click to change")
    .accessibilityLabel(summary.map { "Available now: \($0)" } ?? "No conditions available")
  }
}

/// The focus panel's one line about where you are, above its field. Quiet
/// until there are conditions to talk about: a workspace without any has
/// nothing for it to say. Clicking it hands over to the window's Conditions
/// tab, which is where they are set.
struct FocusPanelContextLine: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  /// Hands the panel back so the window can take over.
  let onOpenWindow: () -> Void

  var body: some View {
    if !model.focusConditions.isEmpty {
      let summary = model.focusContextSummary
      Button {
        onOpenWindow()
        model.openConditionsTab()
      } label: {
        HStack(spacing: theme.space.xs) {
          Image(systemName: summary == nil ? "location.slash" : "location.fill")
            .foregroundStyle(summary == nil ? theme.dim : theme.primary)
          Text(summary ?? "Anywhere — only tasks with no conditions")
            .foregroundStyle(summary == nil ? theme.muted : theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
          if !model.suggestedContextIDs.isEmpty {
            Text("· last context waiting").foregroundStyle(theme.warning)
          }
          Spacer(minLength: theme.space.sm)
          Text(WorkspaceCommandHelpText.firstKey(for: .focusSetAvailable))
            .font(theme.monoCaptionFont)
            .foregroundStyle(theme.dim)
        }
        .font(theme.captionFont)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
      .commandHelp(.focusSetAvailable, note: "What is available now, in the window's Conditions tab")
      .padding(.horizontal, theme.space.lg)
      .padding(.bottom, theme.space.sm)
    }
  }
}

struct WorkspaceTaskPlanningEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let values: TaskEditorValues
  @State private var isAddingCondition = false
  @State private var newConditionName = ""
  @FocusState private var isNewConditionFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      ThemedOptionalRow(
        "Start", isSet: values.startAt != nil, stop: "start",
        add: { edit { $0.startAt = $0.startAt ?? .now } },
        clear: { edit { $0.startAt = nil } },
        value: {
          if let start = values.startAt {
            ThemedDateField(
              selection: Binding(get: { current.startAt ?? start }, set: { date in edit { $0.startAt = date } }),
              includesTime: true, stop: "start.date")
            .commandHelp(.taskEditStart)
          }
      })
      .commandHelp(.taskEditStart)
      MicroLabel("Conditions")
      if (values.requirementGroups ?? []).isEmpty {
        Text(WorkspaceConditionCopy.none).font(theme.captionFont).foregroundStyle(theme.muted)
        if model.focusConditions.isEmpty {
          Text(WorkspaceConditionCopy.explanation)
            .font(theme.captionFont).foregroundStyle(theme.dim)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      ForEach(Array((values.requirementGroups ?? []).enumerated()), id: \.offset) { index, group in
        VStack(alignment: .leading, spacing: theme.space.xs) {
          Text(index == 0 ? "Requires" : "And requires").font(theme.captionFont).foregroundStyle(theme.muted)
          ForEach(group, id: \.self) { id in
            HStack(spacing: theme.space.xs) {
              Text(model.focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition")
                .foregroundStyle(theme.ink)
              if group.count > 1 { Text("(either)").foregroundStyle(theme.muted) }
              Spacer()
              Button { remove(id, from: index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(theme.muted).inspectorStop("condition.\(index).\(id)")
                .help("Remove requirement")
                .accessibilityLabel("Remove requirement")
            }.font(theme.captionFont)
          }
          ThemedMenu("Or…") {
            WorkspaceConditionMenuSections(
              offering: { !$0.isArchived && !group.contains($0.id) },
              choose: { condition in edit { $0.requirementGroups?[index].append(condition.id) } })
          }.font(theme.captionFont).inspectorStop("condition.\(index).or")
        }
      }
      ThemedMenu("Add required condition", systemImage: "plus", expands: true) {
        WorkspaceConditionMenuSections(
          offering: { !$0.isArchived && !(values.requirementGroups ?? []).contains([$0.id]) },
          choose: { require($0.id) })
        if model.focusConditions.contains(where: { !$0.isArchived }) { Divider() }
        Button("New condition…") {
          newConditionName = ""
          isAddingCondition = true
        }
      }
      .inspectorStop("condition.add")
      .commandHelp(.taskConditions, note: "Tick conditions from the keyboard, or type a new one")
      if isAddingCondition {
        HStack(spacing: theme.space.sm) {
          TextField("New condition", text: $newConditionName, prompt: Text("Home, Floor space…"))
            .themedTextField()
            .inspectorField("condition.new")
            .focused($isNewConditionFocused)
            .onSubmit(addNewCondition)
            .onExitCommand { isAddingCondition = false }
          WorkspaceConditionCategoryMenu(
            category: model.newConditionCategory,
            choose: { model.newConditionCategory = $0 },
            newCategory: { model.presentConditionCategoryFinder(for: nil) })
          Button("Add", action: addNewCondition)
            .buttonStyle(FocusActionButtonStyle())
            .disabled(newConditionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .font(theme.captionFont)
        .onAppear { DispatchQueue.main.async { isNewConditionFocused = true } }
      }
      Toggle("Must finish in one sitting", isOn: Binding(get: { current.requiresSingleSitting == true }, set: { enabled in
        edit { $0.requiresSingleSitting = enabled ? true : nil }
      }))
        .toggleStyle(.themedSwitch)
        .inspectorStop("single-sitting")
      ThemedControlRow("Minimum block") {
        TextField("Minimum useful block (minutes)", text: Binding(get: { current.minimumBlockMinutes ?? "" }, set: { raw in
          edit { $0.minimumBlockMinutes = raw.isEmpty ? nil : raw }
        }), prompt: Text("Minutes"))
        .themedTextField()
        .inspectorField("minimum-block")
      }
      if let unavailable = model.blockedFocusTasks.first(where: { $0.id == task.id }) {
        Text(unavailable.reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
          .font(theme.captionFont).foregroundStyle(theme.warning)
      }
      Button("Apply saved requirements and start to subtasks") { model.applyPlanningToDescendants(of: task) }
        .buttonStyle(FocusActionButtonStyle())
        .inspectorStop("apply-planning")
        .font(theme.captionFont).help("Copies saved conditions, start and block rules; keeps each subtask's own estimate and deadline")
    }
  }

  private var current: TaskEditorValues { model.taskEditor.draft(for: task.id)?.values ?? values }
  private func edit(_ change: (inout TaskEditorValues) -> Void) { model.taskEditor.edit(task.id, change) }
  private func require(_ id: String) { edit { $0.requirementGroups = ($0.requirementGroups ?? []) + [[id]] } }

  /// Makes the condition and requires it in one go: the menu that offers
  /// conditions is where you find out you need one that does not exist yet.
  private func addNewCondition() {
    let name = newConditionName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let created = model.createCondition(name: name, category: model.newConditionCategory) else { return }
    require(created.id)
    isAddingCondition = false
    newConditionName = ""
  }
  private func remove(_ id: String, from index: Int) {
    edit { values in
      var groups = values.requirementGroups ?? []
      guard groups.indices.contains(index) else { return }
      groups[index].removeAll { $0 == id }
      groups.removeAll( where: \.isEmpty)
      values.requirementGroups = groups.isEmpty ? nil : groups
    }
  }
}

/// The conditions a menu offers, under their category headings.
struct WorkspaceConditionMenuSections: View {
  @Environment(WorkspaceViewModel.self) private var model
  let offering: (TaskCondition) -> Bool
  let choose: (TaskCondition) -> Void

  var body: some View {
    let sections = TaskConditionSection.sections(model.focusConditions.filter(offering))
    ForEach(sections) { section in
      Section(section.title) {
        ForEach(section.conditions) { condition in
          Button(condition.name) { choose(condition) }
        }
      }
    }
  }
}

struct WorkspaceTaskPlanningBadges: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  /// The selected row's badges show in full; the rest stop at two lines.
  var isExpanded = false

  var body: some View {
    let planning = model.taskPlanningByID[task.id]
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      if let due = planning?.dueDate {
        Label("Due \(due)", systemImage: "calendar")
      }
      if let start = planning?.startAt {
        // In the warning colour while it holds the task back.
        Label("Start \(start.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
          .foregroundStyle(start > .now ? theme.warning : theme.muted)
      }
      if let groups = planning?.requirementGroups, !groups.isEmpty {
        WorkspaceRequirementTags(groups: groups)
      }
      // A start still to come is already the line above, and a missing
      // condition is its tag in the warning colour, so neither is said twice;
      // only the other reasons are.
      if let blocked = model.blockedFocusTasks.first(where: { $0.id == task.id }) {
        let reasons = blocked.reasons.filter { reason in
          if case .startsLater = reason { return planning?.startAt == nil }
          if case .missingConditions = reason { return planning?.requirementGroups?.isEmpty ?? true }
          return true
        }
        if !reasons.isEmpty {
          Text(reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
            .foregroundStyle(theme.warning)
        }
      }
    }.font(theme.captionFont).foregroundStyle(theme.muted).expandsWhenSelected(isExpanded, lineLimit: 2)
  }
}

/// A task's required conditions as tags on its row or card, one per
/// requirement — "Home", "Campus or Library" — so what a task needs reads at
/// a glance rather than as a sentence. One that holds now is in the success
/// colour; one that does not is in the warning colour, because it is what
/// keeps the task out of the day. `cc` changes them.
struct WorkspaceRequirementTags: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let groups: [[String]]

  var body: some View {
    let available = model.focusContext.conditionIDs
    HStack(spacing: theme.space.xs) {
      Image(systemName: "location")
        .foregroundStyle(theme.muted)
        .accessibilityHidden(true)
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        let name = group.map { id in model.focusConditions.first { $0.id == id }?.name ?? "Missing condition" }
          .joined(separator: " or ")
        let holds = group.contains { available.contains($0) }
        ThemedTag(name, tint: holds ? theme.success : theme.warning)
          .help(holds ? "Needs \(name) — available now" : "Needs \(name) — not available now. cc changes what it needs")
          .accessibilityLabel(holds ? "Needs \(name), available now" : "Needs \(name), not available now")
      }
    }
  }
}
