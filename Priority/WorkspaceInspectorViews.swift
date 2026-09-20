import PriorityWorkspace
import PriorityCore
import SwiftUI

struct LocalTaskInspector: View {
  @Environment(WorkspaceViewModel.self) private var model
  let task: WorkspaceTask
  let focusRequest: Int
  let requestedFocusArea: WorkspaceFocusArea
  @FocusState private var titleIsFocused: Bool

  var body: some View {
    Group {
      if let draft = model.taskEditor.draft(for: task.id) {
        editor(draft)
      } else if let error = model.taskEditor.errors[task.id] {
        Text(error).foregroundStyle(.red)
      } else {
        ProgressView()
      }
    }
    .onAppear {
      model.openTaskEditor(task)
      if requestedFocusArea == .inspector { titleIsFocused = true }
    }
    .onChange(of: task.id) { _, _ in model.openTaskEditor(task) }
    .onChange(of: focusRequest) { _, _ in
      if requestedFocusArea == .inspector { titleIsFocused = true }
    }
    .onDisappear { model.taskEditor.flush() }
  }

  @ViewBuilder
  private func editor(_ draft: TaskEditorDraft) -> some View {
    Button(task.isList ? "Convert to task" : "Convert to list") { model.convertItem(task) }
      .focusable()
    if task.isList {
      Picker("Icon", selection: Binding(
        get: { model.itemSymbol(for: task) },
        set: { model.setNestedListIcon($0, for: task) }
      )) {
        ForEach(WorkspaceViewModel.availableListIcons, id: \.symbol) { icon in
          Label(icon.label, systemImage: icon.symbol).tag(icon.symbol)
        }
      }.focusable()
      Button(task.isPromoted == true ? "Unpin from sidebar" : "Promote to sidebar") { model.toggleListPromotion(task) }.focusable()
      Button(task.status == .open ? "Complete list" : "Reopen list") { model.toggleTask(task) }.focusable()
      Button("Archive list") { model.archiveNestedList(task) }.focusable()
    }
    TextField("Task title", text: binding(\.title, fallback: draft.values.title))
      .font(.headline)
      .textFieldStyle(.plain)
      .focused($titleIsFocused)
      .onSubmit { model.saveTaskEditor(task) }
    if draft.isDirty {
      Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
    }
    if let error = model.taskEditor.errors[task.id] {
      Text(error).font(.caption).foregroundStyle(.red)
    }
    if let error = model.taskEditor.persistenceError {
      Text(error).font(.caption).foregroundStyle(.red)
    }
    ForEach(TaskEditorField.allCases.filter { draft.conflicts.contains($0) }, id: \.self) { field in
      VStack(alignment: .leading, spacing: 4) {
        Text("\(field.label) changed in the saved task").font(.caption.weight(.semibold))
        Text("Saved: \(display(field, in: draft.baseline.values))").font(.caption).lineLimit(3)
        Text("Your edit: \(display(field, in: draft.values))").font(.caption).lineLimit(3)
        HStack {
          Button("Use saved") { model.taskEditor.resolve(task.id, field: field, useSaved: true) }
          Button("Keep my edit") { model.taskEditor.resolve(task.id, field: field, useSaved: false) }
        }
        .buttonStyle(.bordered)
      }
    }
    Text("NOTES").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
    TextEditor(text: binding(\.notes, fallback: draft.values.notes))
      .font(.callout)
      .frame(minHeight: 120)
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    WorkspaceTaskPlanningEditor(task: task, values: draft.values)
    Toggle("Due date", isOn: Binding(
      get: { model.taskEditor.draft(for: task.id).map { $0.values.dueAt != nil || $0.values.dueDate != nil } ?? false },
      set: { enabled in model.taskEditor.edit(task.id) {
        if enabled { $0.dueDate = $0.dueDate ?? TaskCalendarDate.string(.now); $0.dueAt = nil } else { $0.dueAt = nil; $0.dueDate = nil }
      } }
    ))
      .toggleStyle(.switch).focusable()
    if draft.values.dueAt != nil || draft.values.dueDate != nil {
      Toggle("Exact deadline time", isOn: Binding(
        get: { model.taskEditor.draft(for: task.id)?.values.dueAt != nil },
        set: { exact in model.taskEditor.edit(task.id) {
          if exact { $0.dueAt = $0.dueDate.flatMap { TaskCalendarDate.date($0) } ?? .now; $0.dueDate = nil } else { $0.dueDate = TaskCalendarDate.string($0.dueAt ?? .now); $0.dueAt = nil }
        } }))
        .toggleStyle(.switch)
    }
    if let day = draft.values.dueDate {
      DatePicker("Due", selection: Binding(
        get: { TaskCalendarDate.date(model.taskEditor.draft(for: task.id)?.values.dueDate ?? day) ?? .now },
        set: { date in model.taskEditor.edit(task.id) { $0.dueDate = TaskCalendarDate.string(date); $0.dueAt = nil } }
      ), displayedComponents: [.date])
    }
    if let dueAt = draft.values.dueAt {
      DatePicker("Due", selection: Binding(
        get: { model.taskEditor.draft(for: task.id)?.values.dueAt ?? dueAt },
        set: { date in model.taskEditor.edit(task.id) { $0.dueAt = date } }
      ), displayedComponents: [.date, .hourAndMinute]).focusable()
    }
    TextField("Estimate (minutes)", text: binding(\.estimateMinutes, fallback: draft.values.estimateMinutes))
      .textFieldStyle(.roundedBorder)
    if let seconds = model.taskLoggedSeconds[task.id], seconds > 0 {
      Text("Worked \(FocusPoints.formatted(Double(seconds) / 60)) minutes" + (task.estimateSeconds.map {
        "; approximately \(FocusPoints.formatted(Double(max(0, $0 - seconds)) / 60)) minutes remain"
      } ?? "")).font(.caption).foregroundStyle(.secondary)
      if let estimate = task.estimateSeconds, seconds >= estimate {
        Text("Estimate exhausted. Revise it or choose a session duration to keep making progress.")
          .font(.caption).foregroundStyle(.orange)
      }
    }
    Picker("Priority", selection: binding(\.priority, fallback: draft.values.priority)) {
      Text("None").tag(0)
      Text("Low").tag(1)
      Text("Medium").tag(2)
      Text("High").tag(3)
      Text("Urgent").tag(4)
    }.focusable()
    TextField("Tags", text: binding(\.tags, fallback: draft.values.tags), prompt: Text("Work, launch"))
    TextField("Repeat", text: binding(\.recurrenceRule, fallback: draft.values.recurrenceRule), prompt: Text("Every Monday"))
    Toggle("Make daily progress", isOn: binding(\.dailyProgress, fallback: draft.values.dailyProgress))
      .toggleStyle(.switch)
      .focusable()
      .help("Show this ongoing task in Dailies without completing the task itself")
    Text("LINKS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
    TextEditor(text: binding(\.links, fallback: draft.values.links))
      .font(.callout)
      .frame(minHeight: 52, maxHeight: 90)
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    Menu("Move to list") {
      ForEach(model.lists.filter { $0.id != task.listId }) { list in
        Button(list.name) { model.moveTask(task, toListId: list.id) }
      }
    }.focusable()
    HStack {
      Button("Save") { model.saveTaskEditor(task) }
        .buttonStyle(.bordered)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!draft.isDirty || draft.isUnavailable || !draft.conflicts.isEmpty
          || draft.values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Revert") { model.revertTaskEditor(task) }
        .disabled(!draft.isDirty)
    }
    Divider()
    if !task.isList {
      Button { model.addTaskToGoogleCalendar(task) } label: {
        Label("Add to Google Calendar", systemImage: "calendar.badge.plus")
      }
      .buttonStyle(.bordered)
      .tint(.blue)
      .focusable()
      .help("Create a linked event using the task's due date or start time")
    }
    if !task.isList, model.activeFocusSession != nil {
      Button { model.addToFocusQueue(task) } label: {
        Label("Add to focus queue", systemImage: "plus.circle")
      }.buttonStyle(.borderedProminent).focusable()
      Button("Open focus panel") { model.showsFocusPanel = true }.buttonStyle(.link).focusable()
    } else if !task.isList {
      Button { model.startFocus(on: task) } label: {
        Label("Start focus", systemImage: "bolt.fill")
      }.buttonStyle(.borderedProminent).focusable()
    }
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<TaskEditorValues, Value>, fallback: Value) -> Binding<Value> {
    Binding(
      get: { model.taskEditor.draft(for: task.id)?.values[keyPath: keyPath] ?? fallback },
      set: { value in model.taskEditor.edit(task.id) { $0[keyPath: keyPath] = value } })
  }

  private func display(_ field: TaskEditorField, in values: TaskEditorValues) -> String {
    switch field {
    case .title: values.title
    case .notes: values.notes
    case .dueAt: values.dueAt?.formatted() ?? "None"
    case .estimateMinutes: values.estimateMinutes.isEmpty ? "None" : "\(values.estimateMinutes) minutes"
    case .priority: ["None", "Low", "Medium", "High", "Urgent"][min(max(values.priority, 0), 4)]
    case .tags: values.tags
    case .recurrenceRule: values.recurrenceRule
    case .links: values.links
    case .dailyProgress: values.dailyProgress ? "Enabled" : "Disabled"
    case .startAt: values.startAt?.formatted() ?? "None"
    case .dueDate: values.dueDate ?? "None"
    case .requirements: (values.requirementGroups ?? []).map { group in
      group.map { id in model.focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition" }.joined(separator: " or ")
    }.joined(separator: " and ")
    case .minimumBlock: values.minimumBlockMinutes ?? "None"
    case .singleSitting: values.requiresSingleSitting == true ? "Required" : "Not required"
    }
  }
}

struct WorkspaceSidebarEditorSheet: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let editor: WorkspaceSidebarEditor

  var body: some View {
    switch editor {
    case .list(let list):
      ListSettingsEditor(list: list, dismiss: dismiss)
    case .folder(let folder):
      FolderSettingsEditor(folder: folder, dismiss: dismiss)
    }
  }
}

private struct ListSettingsEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  let list: TaskList
  let dismiss: DismissAction
  @State private var name: String
  @State private var colorHex: String
  @State private var iconSymbol = "list.bullet"
  @State private var folderID: String?
  @State private var isArchived: Bool
  @State private var visibleRootTaskID: String?
  @State private var saveError: String?
  @FocusState private var nameIsFocused: Bool

  init(list: TaskList, dismiss: DismissAction) {
    self.list = list
    self.dismiss = dismiss
    _name = State(initialValue: list.name)
    _colorHex = State(initialValue: list.colorHex ?? "")
    _folderID = State(initialValue: list.folderId)
    _isArchived = State(initialValue: list.isArchived)
    _visibleRootTaskID = State(initialValue: list.visibleRootTaskId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("List settings").font(.title3.weight(.semibold))
      Form {
        TextField("Name", text: $name)
          .focused($nameIsFocused)
          .onSubmit { save() }
        TextField("Color (hex)", text: $colorHex, prompt: Text("#4F86C6"))
        Picker("Icon", selection: $iconSymbol) {
          ForEach(WorkspaceViewModel.availableListIcons, id: \.symbol) { icon in
            Label(icon.label, systemImage: icon.symbol).tag(icon.symbol)
          }
        }
        .focusable()
        Picker("Folder", selection: $folderID) {
          Text("Ungrouped").tag(nil as String?)
          ForEach(model.folders) { folder in
            Text(folder.name).tag(Optional(folder.id))
          }
        }
        .focusable()
        Toggle("Archived", isOn: $isArchived)
          .toggleStyle(.switch)
          .focusable()
          .disabled(list.isSystemList)
        if !model.visibleRootCandidates(for: list).isEmpty || visibleRootTaskID != nil {
          Picker("Show at list root", selection: $visibleRootTaskID) {
            Text("Top-level tasks").tag(nil as String?)
            ForEach(model.visibleRootCandidates(for: list)) { root in
              Text("Children of \(root.title)").tag(Optional(root.id))
            }
            if let rootID = visibleRootTaskID,
              !model.visibleRootCandidates(for: list).contains(where: { $0.id == rootID }) {
              Text("Current imported root (unavailable)").tag(Optional(rootID))
            }
          }
          Text("Choose an imported project's children as the list's visible work. Tasks keep their titles and placement.")
            .font(.caption).foregroundStyle(.secondary)
          let preview = model.visibleRootPreview(for: list, rootID: visibleRootTaskID)
          Text("Preview: \(preview.prefix(3).map(\.title).joined(separator: ", "))\(preview.count > 3 ? "…" : "")")
            .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Tasks", value: "\(model.taskCount(for: list))")
      }
      if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("Delete list", role: .destructive) {
          model.requestDeletion(of: .list(list))
          dismiss()
        }
        .focusable()
        .disabled(list.isSystemList)
        Button("Move up") { model.moveListWithinFolder(list, by: -1) }
          .focusable()
        Button("Move down") { model.moveListWithinFolder(list, by: 1) }
          .focusable()
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .buttonStyle(.borderedProminent)
          .focusable()
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 380)
    .onAppear {
      iconSymbol = model.icon(for: list)
      nameIsFocused = true
    }
  }

  private func save() {
    do {
      try model.saveListSettings(list, name: name, colorHex: colorHex, folderID: folderID,
                                isArchived: isArchived, visibleRootTaskID: visibleRootTaskID)
      model.setIcon(iconSymbol, for: list)
      dismiss()
    } catch { saveError = error.localizedDescription }
  }
}

private struct FolderSettingsEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  let folder: ListFolder
  let dismiss: DismissAction
  @State private var name: String
  @State private var parentFolderID: String?
  @State private var saveError: String?
  @FocusState private var nameIsFocused: Bool

  init(folder: ListFolder, dismiss: DismissAction) {
    self.folder = folder
    self.dismiss = dismiss
    _name = State(initialValue: folder.name)
    _parentFolderID = State(initialValue: folder.parentFolderId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Folder settings").font(.title3.weight(.semibold))
      Form {
        TextField("Name", text: $name)
          .focused($nameIsFocused)
          .onSubmit { save() }
        Picker("Parent folder", selection: $parentFolderID) {
          Text("At sidebar root").tag(nil as String?)
          ForEach(model.validParentFolders(for: folder)) { candidate in
            Text(candidate.name).tag(Optional(candidate.id))
          }
        }
        .focusable()
      }
      if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("Delete folder", role: .destructive) {
          model.requestDeletion(of: .folder(folder))
          dismiss()
        }
        .focusable()
        Button("Move up") { model.moveFolderWithinSiblings(folder, by: -1) }
          .focusable()
        Button("Move down") { model.moveFolderWithinSiblings(folder, by: 1) }
          .focusable()
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .buttonStyle(.borderedProminent)
          .focusable()
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 380)
    .onAppear { nameIsFocused = true }
  }

  private func save() {
    do {
      try model.saveFolderSettings(folder, name: name, parentFolderID: parentFolderID)
      dismiss()
    } catch { saveError = error.localizedDescription }
  }
}
