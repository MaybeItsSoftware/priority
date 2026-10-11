import SwiftUI
import TaktCore
import TaktWorkspace

/// The filter list sheet: a name, an icon, which tasks by status, whether
/// every rule must hold or any, and the rules.
///
/// Each rule is a row of three controls — field, comparison, value — drawn
/// from the core's catalog (`WorkspaceFilterCatalog`), so the sheet never
/// offers a rule the core cannot evaluate. Rows are separated by hairlines
/// rather than boxed; the preview under them is the core's own reading of
/// the rules and how many tasks they match now, so what you are building is
/// visible before you save it.
///
/// Tab walks every control in order; Return saves and Esc cancels, as in the
/// other sidebar sheets.
struct WorkspaceFilterListEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  let request: WorkspaceFilterListEditorRequest

  @State private var name: String
  @State private var icon: String
  @State private var definition: WorkspaceFilterDefinition
  @State private var saveError: String?
  @FocusState private var nameIsFocused: Bool

  init(request: WorkspaceFilterListEditorRequest) {
    self.request = request
    let existing = request.existing
    _name = State(initialValue: existing?.name ?? "")
    _icon = State(initialValue: existing?.icon ?? WorkspaceFilterList.defaultIcon)
    _definition = State(
      initialValue: existing?.definition
        ?? WorkspaceFilterDefinition(rules: [WorkspaceFilterRule(field: "tag", op: "has")]))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      SheetTitle(request.existing == nil ? "New filter list" : "Filter list")
      VStack(alignment: .leading, spacing: theme.space.sm) {
        ThemedControlRow("Name") {
          TextField("Name", text: $name, prompt: Text("Due this week"))
            .themedTextField()
            .focused($nameIsFocused)
            .onSubmit { save() }
            .help("↩ saves, esc cancels")
        }
        ThemedPicker("Icon", selection: $icon, options: Self.iconOptions)
          .keyboardFocusable()
        ThemedPicker("Show", selection: $definition.show, options: Self.showOptions)
          .keyboardFocusable()
        ThemedPicker("Match", selection: $definition.match, options: Self.matchOptions)
          .keyboardFocusable()
      }
      rules
      preview
      if let saveError {
        Text(saveError).font(theme.captionFont).foregroundStyle(theme.danger)
      }
      buttons
    }
    .padding(theme.space.xl)
    .frame(width: 560)
    .background(theme.raised)
    .onAppear { nameIsFocused = true }
  }

  // MARK: - Rules

  private var rules: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Rules")
        .font(theme.captionFont.weight(.bold))
        .foregroundStyle(theme.muted)
        .padding(.bottom, theme.space.xs)
      Rectangle().fill(theme.border).frame(height: theme.hairline)
      if definition.rules.isEmpty {
        Text("No rules: every task the status above allows.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .padding(.vertical, theme.space.sm)
        Rectangle().fill(theme.border).frame(height: theme.hairline)
      }
      ForEach($definition.rules) { $rule in
        WorkspaceFilterRuleRow(rule: $rule) {
          definition.rules.removeAll { $0.id == rule.id }
        }
        Rectangle().fill(theme.border).frame(height: theme.hairline)
      }
      Button {
        definition.rules.append(WorkspaceFilterRule(field: "due", op: "within", value: "7"))
      } label: {
        Label("Add rule", systemImage: "plus")
      }
      .buttonStyle(FocusActionButtonStyle())
      .keyboardFocusable()
      .padding(.top, theme.space.sm)
      .help("Add another condition")
    }
  }

  // MARK: - Preview

  /// The core's reading of the rules and how many tasks match now, or why
  /// the rules cannot be saved yet.
  private var preview: some View {
    let reading: (text: String, isError: Bool) = {
      do {
        let tidy = try definition.validated()
        let count = model.filterListMatchCount(tidy)
        let noun = count == 1 ? "task" : "tasks"
        return ("\(tidy.summary) — \(count.map { "\($0) \(noun)" } ?? "")", false)
      } catch {
        return (error.localizedDescription, true)
      }
    }()
    return Text(reading.text)
      .font(theme.captionFont)
      .foregroundStyle(reading.isError ? theme.warning : theme.muted)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Buttons

  private var buttons: some View {
    HStack(spacing: theme.space.xs) {
      if let existing = request.existing {
        Button("Delete filter list", role: .destructive) {
          model.deleteFilterList(existing)
          dismiss()
        }
        .keyboardFocusable()
      }
      Spacer()
      Button("Cancel") { dismiss() }
        .keyboardFocusable()
        .keyboardShortcut(.cancelAction)
        .help("Cancel · esc")
      Button("Save") { save() }
        .buttonStyle(FocusActionButtonStyle(prominent: true))
        .keyboardFocusable()
        .keyboardShortcut(.defaultAction)
        .help("Save · ↩")
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .buttonStyle(FocusActionButtonStyle())
  }

  private func save() {
    do {
      try model.saveFilterList(request, name: name, icon: icon, definition: definition)
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
  }

  static let iconOptions = WorkspaceFilterList.iconOptions.map {
    ThemedPickerOption($0.label, value: $0.symbol, systemImage: $0.symbol)
  }

  static let showOptions: [ThemedPickerOption<WorkspaceFilterDefinition.Show>] = [
    ThemedPickerOption("Open tasks", value: .open),
    ThemedPickerOption("Finished tasks", value: .done),
    ThemedPickerOption("All tasks", value: .all),
  ]

  static let matchOptions: [ThemedPickerOption<WorkspaceFilterDefinition.Match>] = [
    ThemedPickerOption("Every rule", value: .all),
    ThemedPickerOption("Any rule", value: .any),
  ]
}

/// One rule: field, comparison and value, then a button that removes it.
private struct WorkspaceFilterRuleRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Binding var rule: WorkspaceFilterRule
  let remove: () -> Void

  private var field: WorkspaceFilterCatalog.Field? { WorkspaceFilterCatalog.field(rule.field) }
  private var op: WorkspaceFilterCatalog.Operator? { WorkspaceFilterCatalog.op(rule.op, of: rule.field) }

  var body: some View {
    HStack(spacing: theme.space.sm) {
      ThemedMenuPicker("Field", selection: fieldBinding, options: Self.fieldOptions)
        .keyboardFocusable()
        .frame(width: 150)
      ThemedMenuPicker("Comparison", selection: $rule.op, options: opOptions)
        .keyboardFocusable()
        .frame(width: 170)
      value
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: remove) {
        Image(systemName: "xmark")
          .foregroundStyle(theme.muted)
      }
      .buttonStyle(.plain)
      .keyboardFocusable()
      .help("Remove this rule")
      .accessibilityLabel("Remove rule")
    }
    .padding(.vertical, theme.space.xs)
  }

  /// Choosing another field resets the comparison to its first and clears a
  /// value that would no longer mean anything.
  private var fieldBinding: Binding<String> {
    Binding(
      get: { rule.field },
      set: { newField in
        guard newField != rule.field else { return }
        let first = WorkspaceFilterCatalog.field(newField)?.ops.first
        rule.field = newField
        rule.op = first?.op ?? ""
        rule.value = ""
      })
  }

  private static let fieldOptions = WorkspaceFilterCatalog.fields.map {
    ThemedPickerOption($0.label, value: $0.field)
  }

  private var opOptions: [ThemedPickerOption<String>] {
    (field?.ops ?? []).map { ThemedPickerOption($0.label, value: $0.op) }
  }

  @ViewBuilder
  private var value: some View {
    switch op?.valueKind ?? "none" {
    case "none":
      Color.clear.frame(height: 1)
    case "lists":
      listsMenu
    case "folder":
      ThemedMenuPicker(
        "Folder", selection: $rule.value,
        options: [ThemedPickerOption("Choose a folder", value: "")]
          + model.folders.map { ThemedPickerOption($0.name, value: $0.id) })
        .keyboardFocusable()
    case "column":
      ThemedMenuPicker(
        "Column", selection: $rule.value,
        options: [ThemedPickerOption("Choose a column", value: "")]
          + model.boardColumns.map { ThemedPickerOption($0.title, value: $0.id) })
        .keyboardFocusable()
    default:
      TextField(placeholder, text: $rule.value, prompt: Text(placeholder))
        .themedTextField()
    }
  }

  private var placeholder: String {
    switch op?.valueKind {
    case "date": "yyyy-mm-dd"
    case "days": "Days"
    case "minutes": "Minutes"
    case "number": "Number"
    case "tag": "Tag"
    default: "Text"
    }
  }

  /// A menu of every list with a tick against the chosen ones; the value is
  /// their ids, comma separated, as the core reads it.
  private var listsMenu: some View {
    let chosen = Set(rule.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    let names = model.lists.filter { chosen.contains($0.id) }.map(\.name)
    return ThemedMenu(names.isEmpty ? "Choose lists" : names.joined(separator: ", "), expands: true) {
      ForEach(model.lists.filter { !$0.isArchived }) { list in
        Toggle(
          list.name,
          isOn: Binding(
            get: { chosen.contains(list.id) },
            set: { isOn in
              var ids = model.lists.map(\.id).filter { chosen.contains($0) }
              if isOn { ids.append(list.id) } else { ids.removeAll { $0 == list.id } }
              rule.value = ids.joined(separator: ",")
            }))
      }
    }
    .keyboardFocusable()
  }
}

@MainActor
extension WorkspaceViewModel {
  /// How many tasks `definition` matches now, for the sheet's preview; nil
  /// when the store cannot say.
  func filterListMatchCount(_ definition: WorkspaceFilterDefinition) -> Int? {
    guard let store, let workspace else { return nil }
    return try? store.filterListTasks(definition, in: workspace.id).count
  }
}
