import PriorityCore
import PriorityWorkspace
import SwiftUI

struct WorkspaceFocusContextControls: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model
  @State private var showsConditions = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView(.horizontal) {
        HStack {
          Text("AVAILABLE NOW").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
          ForEach(model.focusConditions.filter { condition in
            !condition.isArchived || model.focusContext.conditionIDs.contains(condition.id) ||
              model.taskPlanningByID.values.contains { plan in
                (plan.requirementGroups ?? []).contains { $0.contains(condition.id) }
              }
          }) { condition in
            Button(condition.name) { model.toggleFocusCondition(condition) }
              .buttonStyle(.bordered)
              .tint(model.focusContext.conditionIDs.contains(condition.id) ? theme.primary : theme.muted)
              .help(condition.isLocation ? "Current location" : "Available capability")
          }
          Button { showsConditions = true } label: { Image(systemName: "slider.horizontal.3") }
            .help("Manage conditions")
        }
      }
      if !model.suggestedContextIDs.isEmpty {
        HStack {
          Text("Last context: " + model.suggestedContextIDs.sorted().map { id in
            model.focusConditions.first(where: { $0.id == id })?.name ?? ""
          }.joined(separator: ", ")).font(.caption)
          Button("Use again") { model.confirmSuggestedContext() }
          Button("Dismiss") { model.suggestedContextIDs = [] }
        }
      }
      HStack {
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
      HStack {
        Toggle("Context expires", isOn: Binding(get: { model.contextExpiresAt != nil }, set: {
          model.contextExpiresAt = $0 ? Date.now.addingTimeInterval(3600) : nil; model.focusContextChanged()
        })).toggleStyle(.switch)
        if let end = model.contextExpiresAt {
          DatePicker("Context until", selection: Binding(get: { model.contextExpiresAt ?? end }, set: { model.contextExpiresAt = $0; model.focusContextChanged() }),
                     displayedComponents: [.date, .hourAndMinute]).labelsHidden()
        }
      }.font(.caption)
      if model.focusContext.conditionIDs.isEmpty {
        Text("General laptop tasks are available. Select conditions to reveal and promote matching work.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .sheet(isPresented: $showsConditions) { WorkspaceConditionsEditor().environment(model) }
  }
}

private struct WorkspaceConditionsEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var newName = ""
  @State private var newIsLocation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Conditions").font(.title2)
      Text("Tasks refer to conditions by identity. Renaming keeps their requirements intact.")
        .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        VStack(spacing: 12) {
          ForEach(model.focusConditions) { condition in WorkspaceConditionEditorRow(condition: condition) }
        }
      }
      HStack {
        TextField("New condition", text: $newName)
        Toggle("Location", isOn: $newIsLocation)
          .toggleStyle(.switch)
        Button("Add") {
          model.createCondition(name: newName, isLocation: newIsLocation)
          if model.errorMessage == nil { newName = "" }
        }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let error = model.errorMessage {
        Text(error).font(.caption).foregroundStyle(model.themeColor(.danger))
      }
      HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }.padding(24).frame(width: 560, height: 420)
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
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}

struct WorkspaceTaskPlanningEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  let task: WorkspaceTask
  let values: TaskEditorValues

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Start time", isOn: Binding(get: { current.startAt != nil }, set: { enabled in
        edit { $0.startAt = enabled ? ($0.startAt ?? .now) : nil }
      }))
        .toggleStyle(.switch)
      if let start = values.startAt {
        DatePicker("Start", selection: Binding(get: { current.startAt ?? start }, set: { date in edit { $0.startAt = date } }),
                   displayedComponents: [.date, .hourAndMinute])
      }
      Text("CONDITIONS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
      if (values.requirementGroups ?? []).isEmpty {
        Text("Anytime, on your laptop").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array((values.requirementGroups ?? []).enumerated()), id: \.offset) { index, group in
        VStack(alignment: .leading, spacing: 4) {
          Text(index == 0 ? "Requires" : "And requires").font(.caption).foregroundStyle(.secondary)
          ForEach(group, id: \.self) { id in
            HStack {
              Text(model.focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition")
              if group.count > 1 { Text("(either)").foregroundStyle(.secondary) }
              Spacer()
              Button { remove(id, from: index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).help("Remove requirement")
            }.font(.caption)
          }
          Menu("Or…") {
            ForEach(model.focusConditions.filter { !$0.isArchived && !group.contains($0.id) }) { condition in
              Button(condition.name) { edit { $0.requirementGroups?[index].append(condition.id) } }
            }
          }.font(.caption)
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
          .font(.caption).foregroundStyle(model.themeColor(.warning))
      }
      Button("Apply saved requirements and start to subtasks") { model.applyPlanningToDescendants(of: task) }
        .font(.caption).help("Copies saved conditions, start and block rules; keeps each subtask's own estimate and deadline")
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
  let task: WorkspaceTask

  var body: some View {
    let planning = model.taskPlanningByID[task.id]
    VStack(alignment: .leading, spacing: 3) {
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
          .foregroundStyle(model.themeColor(.warning))
      }
    }.font(.caption2).foregroundStyle(.secondary).lineLimit(2)
  }
}
