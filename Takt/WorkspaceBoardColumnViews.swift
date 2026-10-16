import SwiftUI
import TaktCore
import TaktWorkspace

/// A board column header's right-click menu: what can be done to the column,
/// each item with its key as bound on the board. The same commands are in
/// the palette, acting on the column you are in.
struct WorkspaceBoardColumnMenu: View {
  @Environment(WorkspaceViewModel.self) private var model
  let column: WorkspaceKanbanColumn

  var body: some View {
    Button("Rename…") { model.requestRenameBoardColumn(column) }
      .menuKey(.planBoardRenameColumn, on: .board)
    Button(column.isRuleColumn ? "Edit Rules…" : "Add Rules…") { model.requestEditBoardColumnRules(column) }
      .menuKey(.planBoardEditColumnRules, on: .board)
    Divider()
    Button("Move Left") { model.moveKanbanColumn(column.id, by: -1) }
      .menuKey(.planBoardMoveColumnLeft, on: .board)
      .disabled(!model.canMoveKanbanColumn(column.id, by: -1))
    Button("Move Right") { model.moveKanbanColumn(column.id, by: 1) }
      .menuKey(.planBoardMoveColumnRight, on: .board)
      .disabled(!model.canMoveKanbanColumn(column.id, by: 1))
    Divider()
    Button("Add Column to the Left…") { model.requestNewBoardColumn(beside: column.id, after: false) }
      .menuKey(.planBoardAddColumnLeft, on: .board)
    Button("Add Column to the Right…") { model.requestNewBoardColumn(beside: column.id, after: true) }
      .menuKey(.planBoardAddColumnRight, on: .board)
    Divider()
    Button("Make These the Default Columns") { model.makeBoardColumnsDefault() }
      .menuKey(.planBoardMakeDefaultColumns, on: .board)
    Button("Reset to Default Columns") { model.resetBoardColumnsToDefault() }
      .menuKey(.planBoardResetColumns, on: .board)
      .disabled(model.boardColumnSource != .own)
    Divider()
    Button("Delete Column…", role: .destructive) { model.requestDeleteBoardColumn(column) }
      .menuKey(.planBoardRemoveColumn, on: .board)
      .disabled(model.editableBoardColumns.count <= 1)
  }
}

/// The right-click menu on the empty space of a task pane — between the
/// cards of a board column, below an outline, around the matrix or Today:
/// making a task, a column on the board, switching view, and the completed
/// tasks. Each item shows its key as bound on that pane.
struct WorkspacePaneContextMenu: View {
  @Environment(WorkspaceViewModel.self) private var model
  let surface: WorkspaceCommandSurface
  /// The board column clicked in, where a new task goes.
  var column: WorkspaceKanbanColumn?

  var body: some View {
    Button(column.map { "New Task in \($0.title)" } ?? "New Task") {
      if let column {
        model.focusedBoardColumnID = column.id
        model.selectedTaskID = nil
      }
      model.run(.taskNew)
    }
    .menuKey(.taskNew, on: surface)
    if surface == .board {
      Button("New Column…") { model.requestNewBoardColumn(beside: column?.id, after: true) }
        .menuKey(.planBoardNewColumn, on: .board)
    }
    Divider()
    Button("Today") { model.run(.goToday) }
      .menuKey(.goToday, on: surface)
      .disabled(model.viewMode == .today)
    Button("Board") { model.run(.goBoard) }
      .menuKey(.goBoard, on: surface)
      .disabled(model.viewMode == .board)
    Button("Outline") { model.run(.goOutline) }
      .menuKey(.goOutline, on: surface)
      .disabled(model.viewMode == .outline)
    Button("Matrix") { model.run(.goMatrix) }
      .menuKey(.goMatrix, on: surface)
      .disabled(model.viewMode == .matrix)
    Divider()
    Button(model.hidesCompletedTasks ? "Show Completed Tasks" : "Hide Completed Tasks") {
      model.run(.planHideCompleted)
    }
    .menuKey(.planHideCompleted, on: surface)
    Button(model.hidesLaterTasks ? "Show Buried Tasks" : "Hide Buried Tasks") {
      model.run(.planHideLater)
    }
    .menuKey(.planHideLater, on: surface)
  }
}

/// Deleting a board column: where its tasks go, picked from the columns that
/// remain, the first already chosen. ↑↓ choose and ↩ deletes, in one undo
/// step with the move.
///
/// A rule column, Today and Waiting on move nothing — a rule column holds
/// nothing filed in it, and the other two mean something beyond the board —
/// so for those the overlay only confirms.
struct WorkspaceDeleteColumnOverlay: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let columnID: String
  @State private var selection = 0

  private var column: WorkspaceKanbanColumn? {
    model.editableBoardColumns.first { $0.id == columnID }
  }

  private var keepsTasks: Bool { column.map(model.boardColumnKeepsTasksWhenDeleted) ?? true }

  private var targets: [WorkspaceKanbanColumn] {
    keepsTasks ? [] : model.boardColumnDeletionTargets(for: columnID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(heading)
        .font(theme.bodyFont().weight(.semibold))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, theme.listGutter)
        .padding(.vertical, theme.space.sm)
      FocusRule()
      if keepsTasks {
        Text(keepNote)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, theme.listGutter)
          .padding(.vertical, theme.space.sm)
      } else {
        ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
          Button {
            selection = index
            submit()
          } label: {
            HStack {
              Text(target.title).foregroundStyle(theme.ink)
              Spacer()
              if index == 0 {
                Text("first column").font(theme.captionFont).foregroundStyle(theme.dim)
              }
            }
            .overlayRow(isSelected: index == selection)
          }
          .buttonStyle(.plain)
        }
      }
      WorkspaceOverlayFooter(hints: keepsTasks ? "↩ delete · esc cancel" : "↑↓ choose · ↩ delete · esc cancel")
    }
    .overlayKeys(model, id: overlayID) { key in
      if let offset = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection, by: offset, count: targets.count) ?? 0
        return true
      }
      guard key == "enter" else { return false }
      submit()
      return true
    }
  }

  private var heading: String {
    let title = column?.title ?? "column"
    return keepsTasks ? "Delete “\(title)”?" : "Delete “\(title)” — move its tasks to"
  }

  private var keepNote: String {
    guard let column else { return "" }
    if column.isRuleColumn {
      return "Its tasks are the ones its rules match; they go back to the columns they are filed in."
    }
    let state = column.id == "today" ? "planned for today" : "waiting"
    return "Its tasks stay \(state). On this board they show in the first column."
  }

  private func submit() {
    model.dismissOverlay()
    let target = targets.indices.contains(selection) ? targets[selection].id : nil
    model.deleteKanbanColumn(columnID, movingTasksTo: target)
  }
}

/// A board column's rules: the filter list sheet's match picker and rule
/// rows (`WorkspaceFilterRulesSection`), so a column asks the same
/// questions a filter list does, and the core evaluates both the same way.
///
/// Tasks the rules match are drawn in the column, the first rule column
/// from the left winning; a task matching none stays in the column it is
/// filed in. Clearing every rule makes it an ordinary column again.
struct WorkspaceBoardColumnRulesEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  let request: WorkspaceBoardColumnRulesRequest

  @State private var definition: WorkspaceFilterDefinition
  @State private var saveError: String?

  init(request: WorkspaceBoardColumnRulesRequest) {
    self.request = request
    _definition = State(
      initialValue: request.rules
        // A column's rules ask about every task on the board, whatever its
        // status; finished ones are hidden or shown by the board itself.
        ?? WorkspaceFilterDefinition(show: .all, rules: [WorkspaceFilterRule(field: "tag", op: "has")]))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      SheetTitle("Rules for “\(request.title)”")
      Text("Tasks these rules match show in this column, whichever column they are filed in. "
        + "Dropping a task here edits it to match, where one edit does.")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .fixedSize(horizontal: false, vertical: true)
      ThemedPicker("Match", selection: $definition.match, options: WorkspaceFilterListEditor.matchOptions)
        .keyboardFocusable()
      WorkspaceFilterRulesSection(
        definition: $definition, emptyText: "No rules: an ordinary column, holding the tasks filed in it.")
      preview
      if let saveError {
        Text(saveError).font(theme.captionFont).foregroundStyle(theme.danger)
      }
      HStack(spacing: theme.space.xs) {
        if request.rules != nil {
          Button("Remove rules", role: .destructive) { save(nil) }
            .keyboardFocusable()
            .help("Make it an ordinary column again")
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardFocusable()
          .keyboardShortcut(.cancelAction)
          .help("Cancel · esc")
        Button("Save") { save(definition) }
          .buttonStyle(FocusActionButtonStyle(prominent: true))
          .keyboardFocusable()
          .keyboardShortcut(.defaultAction)
          .help("Save · ↩")
      }
      .buttonStyle(FocusActionButtonStyle())
    }
    .padding(theme.space.xl)
    .frame(width: 560)
    .background(theme.raised)
  }

  private var preview: some View {
    let reading: (text: String, isError: Bool) = {
      do {
        let tidy = try definition.validated()
        return tidy.rules.isEmpty ? ("An ordinary column.", false) : (tidy.summary, false)
      } catch {
        return (error.localizedDescription, true)
      }
    }()
    return Text(reading.text)
      .font(theme.captionFont)
      .foregroundStyle(reading.isError ? theme.warning : theme.muted)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func save(_ rules: WorkspaceFilterDefinition?) {
    do {
      var rules = rules
      rules?.show = .all
      try model.setBoardColumnRules(request.columnID, rules: rules)
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
  }
}
