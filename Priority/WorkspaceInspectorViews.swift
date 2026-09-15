import PriorityWorkspace
import SwiftUI

struct LocalTaskInspector: View {
  @Environment(WorkspaceViewModel.self) private var model
  let task: WorkspaceTask
  let focusRequest: Int
  let requestedFocusArea: WorkspaceFocusArea
  @State private var title: String
  @State private var notes: String
  @State private var dueAt: Date?
  @State private var estimateMinutes: String
  @State private var priority = 0
  @State private var tags = ""
  @State private var recurrenceRule = ""
  @State private var links = ""
  @State private var dailyProgress = false
  @FocusState private var titleIsFocused: Bool

  init(task: WorkspaceTask, focusRequest: Int, requestedFocusArea: WorkspaceFocusArea) {
    self.task = task
    self.focusRequest = focusRequest
    self.requestedFocusArea = requestedFocusArea
    _title = State(initialValue: task.title)
    _notes = State(initialValue: task.notes)
    _dueAt = State(initialValue: task.dueAt)
    _estimateMinutes = State(initialValue: task.estimateSeconds.map { String($0 / 60) } ?? "")
    _priority = State(initialValue: 0)
    _tags = State(initialValue: "")
    _recurrenceRule = State(initialValue: "")
    _links = State(initialValue: "")
  }

  var body: some View {
    TextField("Task title", text: $title)
      .font(.headline)
      .textFieldStyle(.plain)
      .focused($titleIsFocused)
      .onSubmit { save() }
      .onAppear(perform: loadTask)
      .onChange(of: task.id) { _, _ in loadTask() }
      .onChange(of: focusRequest) { _, _ in
        if requestedFocusArea == .inspector { titleIsFocused = true }
      }
    Text("NOTES")
      .font(.caption2.weight(.bold))
      .foregroundStyle(.secondary)
    TextEditor(text: $notes)
      .font(.callout)
      .frame(minHeight: 120)
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    Toggle("Due date", isOn: Binding(
      get: { dueAt != nil },
      set: { enabled in dueAt = enabled ? (dueAt ?? .now) : nil }
    ))
      .focusable()
    if dueAt != nil {
      DatePicker("Due", selection: Binding(
        get: { dueAt ?? .now },
        set: { dueAt = $0 }
      ), displayedComponents: [.date, .hourAndMinute])
        .focusable()
    }
    TextField("Estimate (minutes)", text: $estimateMinutes)
      .textFieldStyle(.roundedBorder)
    Picker("Priority", selection: $priority) {
      Text("None").tag(0)
      Text("Low").tag(1)
      Text("Medium").tag(2)
      Text("High").tag(3)
      Text("Urgent").tag(4)
    }
    .focusable()
    TextField("Tags", text: $tags, prompt: Text("Work, launch"))
    TextField("Repeat", text: $recurrenceRule, prompt: Text("Every Monday"))
    Toggle("Make daily progress", isOn: $dailyProgress)
      .focusable()
      .help("Show this ongoing task in Dailies without completing the task itself")
    Text("LINKS")
      .font(.caption2.weight(.bold))
      .foregroundStyle(.secondary)
    TextEditor(text: $links)
      .font(.callout)
      .frame(minHeight: 52, maxHeight: 90)
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    Menu("Move to list") {
      ForEach(model.lists.filter { $0.id != task.listId }) { list in
        Button(list.name) { model.moveTask(task, toListId: list.id) }
      }
    }
      .focusable()
    Button("Save") { save() }
      .buttonStyle(.bordered)
      .focusable()
      .keyboardShortcut("s", modifiers: .command)
      .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    Divider()
    if model.activeFocusSession != nil {
      Button {
        model.addToFocusQueue(task)
      } label: {
        Label("Add to focus queue", systemImage: "plus.circle")
      }
      .buttonStyle(.borderedProminent)
      .focusable()
      Button("Open focus panel") { model.showsFocusPanel = true }
        .buttonStyle(.link)
        .focusable()
    } else {
      Button {
        model.startFocus(on: task)
      } label: {
        Label("Start focus", systemImage: "bolt.fill")
      }
      .buttonStyle(.borderedProminent)
      .focusable()
    }
  }

  private func save() {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let minutes = Int(estimateMinutes.trimmingCharacters(in: .whitespacesAndNewlines))
    model.updateTask(
      task, title: title, notes: notes, dueAt: dueAt,
      estimateSeconds: minutes.map { max(0, $0) * 60 },
      metadata: TaskEditorMetadata(
        priority: priority == 0 ? nil : priority,
        tags: tags.components(separatedBy: ","),
        recurrenceRule: recurrenceRule,
        externalLinks: links.components(separatedBy: .newlines)))
    model.setDailyProgressTask(task, enabled: dailyProgress)
  }

  private func loadTask() {
    title = task.title
    notes = task.notes
    dueAt = task.dueAt
    estimateMinutes = task.estimateSeconds.map { String($0 / 60) } ?? ""
    let metadata = model.taskEditorMetadata(for: task)
    priority = metadata.priority ?? 0
    tags = metadata.tags.joined(separator: ", ")
    recurrenceRule = metadata.recurrenceRule ?? ""
    links = metadata.externalLinks.joined(separator: "\n")
    dailyProgress = model.isDailyProgressTask(task)
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
  @State private var folderID: String?
  @State private var isArchived: Bool
  @FocusState private var nameIsFocused: Bool

  init(list: TaskList, dismiss: DismissAction) {
    self.list = list
    self.dismiss = dismiss
    _name = State(initialValue: list.name)
    _colorHex = State(initialValue: list.colorHex ?? "")
    _folderID = State(initialValue: list.folderId)
    _isArchived = State(initialValue: list.isArchived)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("List settings").font(.title3.weight(.semibold))
      Form {
        TextField("Name", text: $name)
          .focused($nameIsFocused)
          .onSubmit { save() }
        TextField("Color (hex)", text: $colorHex, prompt: Text("#4F86C6"))
        Picker("Folder", selection: $folderID) {
          Text("Ungrouped").tag(nil as String?)
          ForEach(model.folders) { folder in
            Text(folder.name).tag(Optional(folder.id))
          }
        }
        .focusable()
        Toggle("Archived", isOn: $isArchived)
          .focusable()
        LabeledContent("Tasks", value: "\(model.taskCount(for: list))")
      }
      HStack {
        Button("Delete list", role: .destructive) {
          model.requestDeletion(of: .list(list))
          dismiss()
        }
        .focusable()
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
    .onAppear { nameIsFocused = true }
  }

  private func save() {
    model.updateList(list, name: name, colorHex: colorHex)
    if folderID != list.folderId {
      model.moveList(list, toFolderId: folderID)
    }
    if isArchived != list.isArchived {
      if isArchived { model.archiveList(list) } else { model.restoreList(list) }
    }
    dismiss()
  }
}

private struct FolderSettingsEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  let folder: ListFolder
  let dismiss: DismissAction
  @State private var name: String
  @State private var parentFolderID: String?
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
          ForEach(model.folders.filter { $0.id != folder.id }) { candidate in
            Text(candidate.name).tag(Optional(candidate.id))
          }
        }
        .focusable()
      }
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
    model.updateFolder(folder, name: name)
    if parentFolderID != folder.parentFolderId {
      model.moveFolder(folder, toParentFolderId: parentFolderID)
    }
    dismiss()
  }
}
