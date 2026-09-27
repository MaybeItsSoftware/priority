import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The Eisenhower matrix: urgency across, importance up.
///
/// Its own file because `WorkspaceDesktopView` had grown past SwiftLint's hard
/// file limit, and this is the most self-contained thing in it — three types
/// nothing else refers to.

struct WorkspaceMatrixDashboard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  /// The quadrant's meaning picks its colour out of the house palette: urgent
  /// and important is the danger hue, schedule is the app's own primary, and
  /// delegate is the warning hue. These were SwiftUI's `.red`, `.blue`,
  /// `.orange` and `.gray` — stock framework hues, which do not flip with the
  /// theme and are the one thing the house style rules out by name.
  private var quadrants: [(title: String, urgency: Int, importance: Int, tint: Color)] {
    [
      ("Do now", 1, 1, theme.danger),
      ("Schedule", 0, 1, theme.primary),
      ("Delegate", 1, 0, theme.warning),
      ("Eliminate", 0, 0, theme.dim),
    ]
  }

  var body: some View {
    let unplaced = model.boardTasks.filter {
      let position = model.matrixPosition(for: $0)
      return position.urgency == nil || position.importance == nil
    }
    return VStack(spacing: 0) {
      // The matrix used to name itself in 22pt caps and never name the list it
      // was showing, which is the one thing the other modes put at the top.
      WorkspacePaneHeader(title: model.currentBoardScopeTitle) {
        Text(
          model.isMultiListScope
            ? "Urgency across every list in scope"
            : "Urgency within this project")
          .font(theme.bodyFont(size: 11))
          .foregroundStyle(theme.muted)
          .lineLimit(1)
      } trailing: {
        WorkspacePaneCount(count: unplaced.count, noun: "unplaced")
      }
      FocusRule()
      ScrollView {
        VStack(alignment: .leading, spacing: theme.space.md) {
          if !unplaced.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.sm) {
              MicroLabel("Unplaced")
              ForEach(unplaced) { task in
                WorkspaceMatrixTaskRow(task: task)
                  .environment(model)
              }
            }
            .padding(theme.space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.well, in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay(
              RoundedRectangle(cornerRadius: theme.panelRadius)
                .strokeBorder(theme.border, lineWidth: theme.hairline))
          }
          LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: theme.space.md
          ) {
            ForEach(quadrants, id: \.title) { quadrant in
              WorkspaceMatrixQuadrant(
                title: quadrant.title, urgency: quadrant.urgency, importance: quadrant.importance,
                tint: quadrant.tint)
                .environment(model)
            }
          }
        }
        .focusSurfaceGutter()
        .padding(.vertical, theme.space.md)
      }
    }
  }
}

struct WorkspaceMatrixQuadrant: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let title: String
  let urgency: Int
  let importance: Int
  let tint: Color
  @State private var isDropTargeted = false

  private var tasks: [WorkspaceTask] {
    model.boardTasks.filter {
      let position = model.matrixPosition(for: $0)
      return position.urgency == urgency && position.importance == importance
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      HStack(spacing: theme.space.xs) {
        MicroLabel(title, tint: tint)
        Spacer(minLength: 0)
        Text("\(tasks.count)")
          .font(theme.monoFont(size: 10))
          .foregroundStyle(theme.dim)
          .monospacedDigit()
      }
      ForEach(tasks) { task in
        WorkspaceMatrixTaskRow(task: task)
          .environment(model)
      }
      if tasks.isEmpty {
        Text("Drop a task here").font(theme.bodyFont(size: 11)).foregroundStyle(theme.dim)
      }
    }
    .padding(theme.space.md)
    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
    // A tinted fill plus a border of the same hue, which is the house treatment
    // for a status surface — not a solid block, and not a shadow.
    .background(
      tint.opacity(isDropTargeted ? Theme.statusBorderOpacity : Theme.statusFillOpacity),
      in: RoundedRectangle(cornerRadius: theme.panelRadius))
    .overlay(
      RoundedRectangle(cornerRadius: theme.panelRadius)
        .strokeBorder(
          tint.opacity(isDropTargeted ? 1 : Theme.statusBorderOpacity),
          lineWidth: isDropTargeted ? theme.emphasisBorder : theme.hairline))
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
      WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
        guard let task = model.task(withID: taskID),
          model.isTaskVisibleOnBoard(task)
        else { return }
        model.selectTask(task)
        model.setMatrixPosition(.init(urgency: urgency, importance: importance), for: task)
      }
    }
  }
}

struct WorkspaceMatrixTaskRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @FocusState private var isRowFocused: Bool
  let task: WorkspaceTask

  var body: some View {
    HStack {
      Button(task.title) {
        model.selectTask(task)
        model.reportKeyboardFocus(.tasks)
      }
      .buttonStyle(.plain)
      .focusable()
      .lineLimit(1)
      .truncationMode(.tail)
      .help(task.title)
      .frame(maxWidth: .infinity, alignment: .leading)
      if model.isMultiListScope, let list = model.list(for: task) {
        Text(list.name)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(list.name)
      }
    }
    .padding(6)
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .workspaceSelection(
      isSelected: task.id == model.selectedTaskID,
      hasKeyboard: model.keyboardFocusArea == .tasks && task.id == model.selectedTaskID)
    .focusable()
    .focused($isRowFocused)
    .focusEffectDisabled()
    .onAppear {
      if model.keyboardFocusArea == .tasks && model.selectedTaskID == task.id {
        isRowFocused = true
      }
    }
    .onChange(of: model.focusRequest) { _, _ in
      if model.requestedFocusArea == .tasks && model.selectedTaskID == task.id {
        isRowFocused = true
      }
    }
    .onChange(of: isRowFocused) { _, focused in
      if focused {
        model.selectTask(task)
        model.reportKeyboardFocus(.tasks)
      }
    }
    .onChange(of: model.selectedTaskID) { _, id in
      if id == task.id && !isRowFocused { isRowFocused = true }
    }
    .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, "i", "1", "2", "3", "4"]) { press in
      guard isRowFocused else { return .ignored }
      if press.modifiers.contains(.option) {
        switch press.key {
        case "1": place(urgency: 1, importance: 1)
        case "2": place(urgency: 0, importance: 1)
        case "3": place(urgency: 1, importance: 0)
        case "4": place(urgency: 0, importance: 0)
        default: return .ignored
        }
      } else if press.key == .upArrow {
        model.selectAdjacentTask(by: -1)
      } else if press.key == .downArrow {
        model.selectAdjacentTask(by: 1)
      } else if press.key == .space {
        model.toggleTask(task)
      } else if press.key == .return {
        model.enterTask(task)
      } else if press.key == "i" {
        model.toggleInspector()
      } else {
        return .ignored
      }
      return .handled
    }
  }

  private func place(urgency: Int, importance: Int) {
    model.selectTask(task)
    model.setMatrixPosition(.init(urgency: urgency, importance: importance), for: task)
  }
}
