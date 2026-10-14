import TaktWorkspace
import TaktCore
import SwiftUI

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
  @Environment(\.theme) private var theme
  let list: TaskList
  let dismiss: DismissAction
  @State private var name: String
  @State private var colorHex: String
  @State private var iconSymbol = "list.bullet"
  @State private var folderID: String?
  @State private var isArchived: Bool
  @State private var visibleRootTaskID: String?
  @State private var agentInstructions = ""
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
    VStack(alignment: .leading, spacing: theme.space.lg) {
      SheetTitle("List settings")
      VStack(alignment: .leading, spacing: theme.space.sm) {
        ThemedControlRow("Name") {
          TextField("Name", text: $name)
            .themedTextField()
            .focused($nameIsFocused)
            .onSubmit { save() }
            .help("↩ saves, esc cancels")
        }
        ThemedControlRow("Color (hex)") {
          TextField("Color (hex)", text: $colorHex, prompt: Text("#4F86C6"))
            .themedTextField()
        }
        ThemedPicker("Icon", selection: $iconSymbol, options: LocalTaskInspector.iconOptions(including: iconSymbol))
          .focusable()
        ThemedPicker(
          "Folder", selection: $folderID,
          options: [ThemedPickerOption("Ungrouped", value: nil as String?)]
            + model.folders.map { ThemedPickerOption($0.name, value: Optional($0.id)) }
        )
        .focusable()
        Toggle("Archived", isOn: $isArchived)
          .toggleStyle(.themedSwitch)
          .focusable()
          .disabled(list.isSystemList)
          .commandHelp(.listArchive, note: "Archive the list")
        if !model.visibleRootCandidates(for: list).isEmpty || visibleRootTaskID != nil {
          ThemedPicker(
            "Show at list root", selection: $visibleRootTaskID, options: visibleRootOptions)
          Text("Choose an imported project's children as the list's visible work. Tasks keep their titles and placement.")
            .font(theme.captionFont).foregroundStyle(theme.muted)
          let preview = model.visibleRootPreview(for: list, rootID: visibleRootTaskID)
          Text("Preview: \(preview.prefix(3).map(\.title).joined(separator: ", "))\(preview.count > 3 ? "…" : "")")
            .font(theme.captionFont).foregroundStyle(theme.muted)
        }
        ThemedControlRow("Tasks") {
          Text("\(model.taskCount(for: list))")
            .font(theme.bodyFont())
            .monospacedDigit()
            .foregroundStyle(theme.muted)
        }
        AgentInstructionsField(
          prompt: "Agent instructions for this list", text: $agentInstructions, onSubmit: save)
      }
      if let saveError { Text(saveError).font(theme.captionFont).foregroundStyle(theme.danger) }
      HStack(spacing: theme.space.xs) {
        Button("Delete list", role: .destructive) {
          model.requestDeletion(of: .list(list))
          dismiss()
        }
        .focusable()
        .disabled(list.isSystemList)
        .commandHelp(.listDelete, note: "Delete the list")
        Button("Move up") { model.moveListWithinFolder(list, by: -1) }
          .focusable()
          .commandHelp(.listMoveUp, note: "Move the list up")
        Button("Move down") { model.moveListWithinFolder(list, by: 1) }
          .focusable()
          .commandHelp(.listMoveDown, note: "Move the list down")
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
          .help("Cancel · esc")
        Button("Save") { save() }
          .buttonStyle(FocusActionButtonStyle(prominent: true))
          .focusable()
          .keyboardShortcut(.defaultAction)
          .help("Save · ↩")
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .buttonStyle(FocusActionButtonStyle())
    }
    .padding(theme.space.xl)
    .frame(width: 380)
    .background(theme.raised)
    .onAppear {
      iconSymbol = model.icon(for: list)
      agentInstructions = model.agentInstructions.list(list.id)
      nameIsFocused = true
    }
  }

  private var visibleRootOptions: [ThemedPickerOption<String?>] {
    let candidates = model.visibleRootCandidates(for: list)
    var options = [ThemedPickerOption("Top-level tasks", value: nil as String?)]
    options += candidates.map { ThemedPickerOption("Children of \($0.title)", value: Optional($0.id)) }
    if let rootID = visibleRootTaskID, !candidates.contains(where: { $0.id == rootID }) {
      options.append(ThemedPickerOption("Current imported root (unavailable)", value: Optional(rootID)))
    }
    return options
  }

  private func save() {
    do {
      try model.saveListSettings(list, name: name, colorHex: colorHex, folderID: folderID,
                                isArchived: isArchived, visibleRootTaskID: visibleRootTaskID)
      model.setIcon(iconSymbol, for: list)
      model.agentInstructions.setList(agentInstructions, for: list.id)
      dismiss()
    } catch { saveError = error.localizedDescription }
  }
}

private struct FolderSettingsEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let folder: ListFolder
  let dismiss: DismissAction
  @State private var name: String
  @State private var parentFolderID: String?
  @State private var agentInstructions = ""
  @State private var saveError: String?
  @FocusState private var nameIsFocused: Bool

  init(folder: ListFolder, dismiss: DismissAction) {
    self.folder = folder
    self.dismiss = dismiss
    _name = State(initialValue: folder.name)
    _parentFolderID = State(initialValue: folder.parentFolderId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      SheetTitle("Folder settings")
      VStack(alignment: .leading, spacing: theme.space.sm) {
        ThemedControlRow("Name") {
          TextField("Name", text: $name)
            .themedTextField()
            .focused($nameIsFocused)
            .onSubmit { save() }
            .help("↩ saves, esc cancels")
        }
        ThemedPicker(
          "Parent folder", selection: $parentFolderID,
          options: [ThemedPickerOption("At sidebar root", value: nil as String?)]
            + model.validParentFolders(for: folder).map { ThemedPickerOption($0.name, value: Optional($0.id)) }
        )
        .focusable()
        AgentInstructionsField(
          prompt: "Agent instructions for every list in this folder", text: $agentInstructions, onSubmit: save)
      }
      if let saveError { Text(saveError).font(theme.captionFont).foregroundStyle(theme.danger) }
      HStack(spacing: theme.space.xs) {
        Button("Delete folder", role: .destructive) {
          model.requestDeletion(of: .folder(folder))
          dismiss()
        }
        .focusable()
        .commandHelp(.listDelete, note: "Delete the folder")
        Button("Move up") { model.moveFolderWithinSiblings(folder, by: -1) }
          .focusable()
          .commandHelp(.folderMoveUp)
        Button("Move down") { model.moveFolderWithinSiblings(folder, by: 1) }
          .focusable()
          .commandHelp(.folderMoveDown)
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
          .help("Cancel · esc")
        Button("Save") { save() }
          .buttonStyle(FocusActionButtonStyle(prominent: true))
          .focusable()
          .keyboardShortcut(.defaultAction)
          .help("Save · ↩")
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .buttonStyle(FocusActionButtonStyle())
    }
    .padding(theme.space.xl)
    .frame(width: 380)
    .background(theme.raised)
    .onAppear {
      agentInstructions = model.agentInstructions.folder(folder.id)
      nameIsFocused = true
    }
  }

  private func save() {
    do {
      try model.saveFolderSettings(folder, name: name, parentFolderID: parentFolderID)
      model.agentInstructions.setFolder(agentInstructions, for: folder.id)
      dismiss()
    } catch { saveError = error.localizedDescription }
  }
}
