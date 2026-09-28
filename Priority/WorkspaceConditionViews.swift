import PriorityCore
import PriorityWorkspace
import SwiftUI

struct WorkspaceFocusContextControls: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model
  @State private var showsConditions = false

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      ScrollView(.horizontal) {
        HStack(spacing: theme.space.xs) {
          MicroLabel("Available now")
          ForEach(model.focusConditions.filter { condition in
            !condition.isArchived || model.focusContext.conditionIDs.contains(condition.id) ||
              model.taskPlanningByID.values.contains { plan in
                (plan.requirementGroups ?? []).contains { $0.contains(condition.id) }
              }
          }) { condition in
            Button(condition.name) { model.toggleFocusCondition(condition) }
              .buttonStyle(FocusChipButtonStyle(isOn: model.focusContext.conditionIDs.contains(condition.id)))
              .help(condition.isLocation ? "Current location" : "Available capability")
          }
          Button { showsConditions = true } label: { Image(systemName: "slider.horizontal.3") }
            .buttonStyle(.plain)
            .foregroundStyle(theme.muted)
            .help("Manage conditions")
        }
      }
      if !model.suggestedContextIDs.isEmpty {
        HStack(spacing: theme.space.sm) {
          Text("Last context: " + model.suggestedContextIDs.sorted().map { id in
            model.focusConditions.first(where: { $0.id == id })?.name ?? ""
          }.joined(separator: ", ")).foregroundStyle(theme.muted)
          Button("Use again") { model.confirmSuggestedContext() }
            .buttonStyle(.plain)
            .foregroundStyle(theme.primary)
          Button("Dismiss") { model.suggestedContextIDs = [] }
            .buttonStyle(.plain)
            .foregroundStyle(theme.muted)
        }
        .font(theme.captionFont)
      }
      HStack(spacing: theme.space.sm) {
        Menu(model.availableUntil.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Available time") {
          Button("No time limit") { model.availableUntil = nil; model.focusContextChanged() }
          ForEach([15, 30, 60, 90], id: \.self) { minutes in
            Button("\(minutes) minutes") { model.availableUntil = Date.now.addingTimeInterval(Double(minutes * 60)); model.focusContextChanged() }
          }
          Button("Choose end time") { model.availableUntil = Date.now.addingTimeInterval(1800); model.focusContextChanged() }
        }
        if let end = model.availableUntil {
          DatePicker("Until", selection: Binding(get: { model.availableUntil ?? end }, set: { model.availableUntil = $0; model.focusContextChanged() }),
                     displayedComponents: [.date, .hourAndMinute]).labelsHidden()
        }
        Picker("Goal", selection: Binding(get: { model.focusContext.mode }, set: { model.focusContext.mode = $0; model.focusContextChanged() })) {
          Text("Make progress").tag(FocusTimeMode.progress)
          Text("Finish something").tag(FocusTimeMode.finish)
        }.fixedSize()
      }
      HStack(spacing: theme.space.sm) {
        Toggle("Context expires", isOn: Binding(get: { model.contextExpiresAt != nil }, set: {
          model.contextExpiresAt = $0 ? Date.now.addingTimeInterval(3600) : nil; model.focusContextChanged()
        })).toggleStyle(.switch).tint(theme.primary)
        if let end = model.contextExpiresAt {
          DatePicker("Context until", selection: Binding(get: { model.contextExpiresAt ?? end }, set: { model.contextExpiresAt = $0; model.focusContextChanged() }),
                     displayedComponents: [.date, .hourAndMinute]).labelsHidden()
        }
      }.font(theme.captionFont)
      if model.focusContext.conditionIDs.isEmpty {
        Text("General laptop tasks are available. Select conditions to reveal and promote matching work.")
          .font(theme.captionFont).foregroundStyle(theme.muted)
      }
    }
    .sheet(isPresented: $showsConditions) { WorkspaceConditionsEditor().environment(model) }
  }
}

private struct WorkspaceConditionsEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var newName = ""
  @State private var newIsLocation = false

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      SheetTitle(
        "Conditions",
        subject: "Tasks refer to conditions by identity. Renaming keeps their requirements intact.")
      ScrollView {
        VStack(spacing: theme.space.md) {
          ForEach(model.focusConditions) { condition in WorkspaceConditionEditorRow(condition: condition) }
        }
      }
      HStack(spacing: theme.space.sm) {
        TextField("New condition", text: $newName)
        Toggle("Location", isOn: $newIsLocation)
          .toggleStyle(.switch)
        Button("Add") {
          model.createCondition(name: newName, isLocation: newIsLocation)
          if model.errorMessage == nil { newName = "" }
        }
        .buttonStyle(FocusActionButtonStyle())
        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let error = model.errorMessage {
        Text(error).font(theme.captionFont).foregroundStyle(theme.danger)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(FocusActionButtonStyle(prominent: true))
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(theme.space.xl)
    .frame(width: 560, height: 420)
    .background(theme.raised)
  }
}

private struct WorkspaceConditionEditorRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  let condition: TaskCondition
  @State private var name: String
  @State private var location: Bool
  @State private var archived: Bool

  init(condition: TaskCondition) {
    self.condition = condition
    _name = State(initialValue: condition.name)
    _location = State(initialValue: condition.isLocation)
    _archived = State(initialValue: condition.isArchived)
  }

  var body: some View {
    HStack {
      TextField("Name", text: $name)
      Toggle("Location", isOn: $location)
        .toggleStyle(.switch)
      Toggle("Archived", isOn: $archived)
        .toggleStyle(.switch)
      Button("Save") { model.saveCondition(condition, name: name, isLocation: location, isArchived: archived) }
        .buttonStyle(FocusActionButtonStyle())
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}

struct WorkspaceTaskPlanningEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let values: TaskEditorValues

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      Toggle("Start time", isOn: Binding(get: { current.startAt != nil }, set: { enabled in
        edit { $0.startAt = enabled ? ($0.startAt ?? .now) : nil }
      }))
        .toggleStyle(.switch)
      if let start = values.startAt {
        DatePicker("Start", selection: Binding(get: { current.startAt ?? start }, set: { date in edit { $0.startAt = date } }),
                   displayedComponents: [.date, .hourAndMinute])
      }
      MicroLabel("Conditions")
      if (values.requirementGroups ?? []).isEmpty {
        Text("Anytime, on your laptop").font(theme.captionFont).foregroundStyle(theme.muted)
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
                .buttonStyle(.plain).foregroundStyle(theme.muted).help("Remove requirement")
            }.font(theme.captionFont)
          }
          Menu("Or…") {
            ForEach(model.focusConditions.filter { !$0.isArchived && !group.contains($0.id) }) { condition in
              Button(condition.name) { edit { $0.requirementGroups?[index].append(condition.id) } }
            }
          }.font(theme.captionFont)
        }
      }
      Menu("Add required condition") {
        ForEach(model.focusConditions.filter { condition in
          !condition.isArchived && !(values.requirementGroups ?? []).contains([condition.id])
        }) { condition in
          Button(condition.name) { edit { $0.requirementGroups = ($0.requirementGroups ?? []) + [[condition.id]] } }
        }
      }
      Toggle("Must finish in one sitting", isOn: Binding(get: { current.requiresSingleSitting == true }, set: { enabled in
        edit { $0.requiresSingleSitting = enabled ? true : nil }
      }))
        .toggleStyle(.switch)
      TextField("Minimum useful block (minutes)", text: Binding(get: { current.minimumBlockMinutes ?? "" }, set: { raw in
        edit { $0.minimumBlockMinutes = raw.isEmpty ? nil : raw }
      })).textFieldStyle(.roundedBorder)
      if let unavailable = model.blockedFocusTasks.first(where: { $0.id == task.id }) {
        Text(unavailable.reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
          .font(theme.captionFont).foregroundStyle(theme.warning)
      }
      Button("Apply saved requirements and start to subtasks") { model.applyPlanningToDescendants(of: task) }
        .buttonStyle(FocusActionButtonStyle())
        .font(theme.captionFont).help("Copies saved conditions, start and block rules; keeps each subtask's own estimate and deadline")
    }
  }

  private var current: TaskEditorValues { model.taskEditor.draft(for: task.id)?.values ?? values }
  private func edit(_ change: (inout TaskEditorValues) -> Void) { model.taskEditor.edit(task.id, change) }
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

struct WorkspaceTaskPlanningBadges: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask

  var body: some View {
    let planning = model.taskPlanningByID[task.id]
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      if let due = planning?.dueDate {
        Label("Due \(due)", systemImage: "calendar")
      }
      if let start = planning?.startAt {
        Label("Start \(start.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
      }
      if let groups = planning?.requirementGroups, !groups.isEmpty {
        Label(groups.map { group in
          group.map { id in model.focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition" }
            .joined(separator: " or ")
        }.joined(separator: " + "), systemImage: "location")
      }
      if let blocked = model.blockedFocusTasks.first(where: { $0.id == task.id }) {
        Text(blocked.reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
          .foregroundStyle(theme.warning)
      }
    }.font(theme.captionFont).foregroundStyle(theme.muted).lineLimit(2)
  }
}
