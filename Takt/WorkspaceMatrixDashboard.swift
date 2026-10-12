import TaktCore
import TaktWorkspace
import SwiftUI

/// The Eisenhower matrix, drawn the way a printed one is: urgent and not
/// urgent across the top, important and not important down the side, and
/// four equal quadrants filling the pane between them.
///
/// The unplaced tasks have a column of their own beside the grid. They used
/// to be a list stacked above it on one scrolling page, so a long list pushed
/// the matrix itself off the bottom of the window. Each of the five regions
/// now scrolls on its own and the grid always fills what is left.

struct WorkspaceMatrixDashboard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  /// The quadrant's meaning picks its colour out of the house palette: urgent
  /// and important is the danger hue, schedule is the app's own primary, and
  /// delegate is the warning hue — never a stock framework hue, which would
  /// not flip with the theme.
  private func quadrant(_ cell: MatrixQuadrantCell) -> some View {
    let (title, tint): (String, Color) = switch (cell.urgency, cell.importance) {
    case (1, 1): ("Do now", theme.danger)
    case (0, 1): ("Schedule", theme.primary)
    case (1, 0): ("Delegate", theme.warning)
    default: ("Eliminate", theme.dim)
    }
    return WorkspaceMatrixQuadrant(cell: cell, title: title, tint: tint)
      .environment(model)
  }

  /// The unplaced column's width: a task title's worth, no more, so the grid
  /// keeps most of the pane.
  static let unplacedWidth: CGFloat = 240
  /// The band down the grid's left edge that carries the importance labels.
  static let sideAxisWidth: CGFloat = 28

  var body: some View {
    VStack(spacing: 0) {
      // The matrix used to name itself in 22pt caps and never name the list it
      // was showing, which is the one thing the other modes put at the top.
      WorkspacePaneHeader(title: model.currentBoardScopeTitle, switchesList: true) {
        Text(
          model.isMultiListScope
            ? "Urgency across every list in scope"
            : "Urgency within this project")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .lineLimit(1)
      } trailing: {
        WorkspacePaneCount(count: model.matrixQuadrants.unplaced.count, noun: "unplaced")
      }
      FocusRule()
      HStack(spacing: 0) {
        WorkspaceMatrixUnplacedColumn()
          .environment(model)
          .frame(width: Self.unplacedWidth)
        verticalRule
        grid
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(theme.paper)
  }

  /// A 2×2 grid ruled with hairlines — one surface cut into four, the way a
  /// printed matrix is drawn — rather than four tinted cards with gutters
  /// between them. Both rows and both columns take an equal share of the
  /// pane, whatever is in them; a full quadrant scrolls rather than grows.
  private var grid: some View {
    let cells = MatrixQuadrantCell.readingOrder
    return VStack(spacing: 0) {
      HStack(spacing: 0) {
        Color.clear.frame(width: Self.sideAxisWidth + theme.hairline, height: 0)
        axisLabel("Urgent")
        Color.clear.frame(width: theme.hairline, height: 0)
        axisLabel("Not urgent")
      }
      .padding(.vertical, theme.space.sm)
      FocusRule()
      HStack(spacing: 0) {
        sideLabel("Important")
        verticalRule
        quadrant(cells[0])
        verticalRule
        quadrant(cells[1])
      }
      .frame(maxHeight: .infinity)
      FocusRule()
      HStack(spacing: 0) {
        sideLabel("Not important")
        verticalRule
        quadrant(cells[2])
        verticalRule
        quadrant(cells[3])
      }
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func axisLabel(_ text: String) -> some View {
    MicroLabel(text)
      .frame(maxWidth: .infinity)
      .accessibilityAddTraits(.isHeader)
  }

  /// Turned to read up the side, as a printed matrix's row labels are.
  private func sideLabel(_ text: String) -> some View {
    MicroLabel(text)
      .fixedSize()
      .rotationEffect(.degrees(-90))
      .frame(width: Self.sideAxisWidth)
      .frame(maxHeight: .infinity)
      .accessibilityAddTraits(.isHeader)
  }

  private var verticalRule: some View {
    Rectangle()
      .fill(theme.border)
      .frame(width: theme.hairline)
      .frame(maxHeight: .infinity)
  }
}

/// The tasks with no quadrant yet: a column beside the grid, scrolling on its
/// own. Dropping a task here takes it off the matrix again.
struct WorkspaceMatrixUnplacedColumn: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var isDropTargeted = false

  var body: some View {
    let unplaced = model.matrixQuadrants.unplaced
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: theme.space.xs) {
        MicroLabel("Unplaced")
        Spacer(minLength: 0)
        Text("\(unplaced.count)")
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
          .monospacedDigit()
      }
      .padding(.horizontal, theme.space.md)
      .padding(.vertical, theme.space.sm)
      FocusRule()
      ScrollViewReader { proxy in
        ScrollView {
          // Lazy: Everything's matrix can have thousands of unplaced tasks,
          // and an eager stack laid every one out on the switch.
          LazyVStack(alignment: .leading, spacing: theme.space.xs) {
            ForEach(unplaced) { task in
              WorkspaceMatrixTaskRow(task: task)
                .environment(model)
            }
            // A new task has no urgency or importance yet, so it is
            // unplaced: it is typed where it will first appear.
            if model.isDraftingTask {
              WorkspaceTaskDraftRow(namesDestination: true)
            }
            if unplaced.isEmpty && !model.isDraftingTask {
              Text("Every task has a quadrant")
                .font(theme.captionFont)
                .foregroundStyle(theme.dim)
                .padding(.horizontal, theme.space.sm)
            }
          }
          .padding(theme.space.sm)
        }
        .onChange(of: model.selectedTaskID) { _, id in
          guard let id, unplaced.contains(where: { $0.id == id }) else { return }
          proxy.scrollTo(id)
        }
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(isDropTargeted ? theme.primary.opacity(Theme.statusFillOpacity) : .clear)
    .overlay(
      Rectangle()
        .strokeBorder(isDropTargeted ? theme.primary.opacity(Theme.statusBorderOpacity) : .clear, lineWidth: theme.emphasisBorder)
        .allowsHitTesting(false))
    .contentShape(Rectangle())
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
      WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
        guard let task = model.task(withID: taskID), model.isTaskVisibleOnBoard(task) else { return }
        let position = model.matrixPosition(for: task)
        model.selectTask(task)
        guard position.urgency != nil || position.importance != nil else { return }
        model.setMatrixPosition(.init(urgency: nil, importance: nil), for: task)
      }
    }
  }
}

/// Where each drawn row of a quadrant is, for the drop to aim by. A box rather
/// than state, so that a row moving as the quadrant scrolls does not redraw
/// the quadrant.
private final class MatrixRowFrames {
  var frames: [String: ClosedRange<Double>] = [:]
}

struct WorkspaceMatrixQuadrant: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let cell: MatrixQuadrantCell
  let title: String
  let tint: Color

  /// Where a drag over the quadrant would land: before a task, or at the
  /// foot when `before` is nil. `line` is where the insertion line is drawn,
  /// nil for an empty quadrant, which tints instead.
  @State private var dropMark: (before: String?, line: Double?)?
  @State private var rowFrames = MatrixRowFrames()

  private var space: String { "matrix-quadrant-\(cell.urgency)-\(cell.importance)" }

  /// The quadrant's own key, ⌥1 to ⌥4 in the order the catalogue lists them:
  /// do now, schedule, delegate, eliminate.
  private var placeHelp: String {
    let index = MatrixQuadrantCell.readingOrder.firstIndex(of: cell) ?? 0
    let keys = WorkspaceCommandCatalog.byID[.planMatrixPlace]?.displayKeys ?? []
    let subject = "Place the selected task in \(title)"
    return keys.indices.contains(index) ? "\(subject) · \(keys[index])" : subject
  }

  var body: some View {
    // Looked up once per render, from an index built once per board read.
    let tasks = model.matrixQuadrants.items(in: cell)
    let tintsWhole = dropMark != nil && dropMark?.line == nil
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: theme.space.xs) {
        MicroLabel(title, tint: tint)
        Spacer(minLength: 0)
        Text("\(tasks.count)")
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
          .monospacedDigit()
      }
      .padding(.horizontal, theme.space.md)
      .padding(.top, theme.space.md)
      .padding(.bottom, theme.space.sm)
      .help(placeHelp)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: theme.space.xs) {
            ForEach(tasks) { task in
              WorkspaceMatrixTaskRow(task: task)
                .environment(model)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame in
                  rowFrames.frames[task.id] = Double(frame.minY)...Double(frame.maxY)
                }
                .onDisappear { rowFrames.frames[task.id] = nil }
            }
            if tasks.isEmpty {
              Text("Drop a task here")
                .font(theme.captionFont)
                .foregroundStyle(theme.dim)
                .padding(.horizontal, theme.space.sm)
            }
          }
          .padding(.horizontal, theme.space.sm)
          .padding(.bottom, theme.space.md)
        }
        .onChange(of: model.selectedTaskID) { _, id in
          guard let id, tasks.contains(where: { $0.id == id }) else { return }
          proxy.scrollTo(id)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .coordinateSpace(.named(space))
    // Flat at rest: the grid's hairlines are the structure. A drop between
    // rows draws the insertion line where the task will land; a drop on an
    // empty quadrant tints it in its own hue and rings it, the status
    // treatment.
    .background(tintsWhole ? tint.opacity(Theme.statusFillOpacity) : .clear)
    .overlay(
      Rectangle()
        .strokeBorder(tintsWhole ? tint.opacity(Theme.statusBorderOpacity) : .clear,
          lineWidth: theme.emphasisBorder)
        .allowsHitTesting(false))
    .overlay(alignment: .topLeading) {
      if let line = dropMark?.line {
        Rectangle()
          .fill(theme.primary)
          .frame(height: theme.emphasisBorder)
          .padding(.horizontal, theme.space.sm)
          .offset(y: CGFloat(line) - theme.emphasisBorder / 2)
          .allowsHitTesting(false)
      }
    }
    .clipped()
    .contentShape(Rectangle())
    .onDrop(
      of: [WorkspaceTaskDrag.typeIdentifier],
      delegate: MatrixQuadrantDropDelegate(
        target: { y in
          MatrixQuadrantOrder.dropTarget(
            at: Double(y), order: model.matrixQuadrants.items(in: cell).map(\.id), frames: rowFrames.frames)
        },
        hover: { dropMark = $0 },
        drop: { taskID, before in
          guard let task = model.task(withID: taskID), model.isTaskVisibleOnBoard(task) else { return }
          model.selectTask(task)
          model.placeTaskInMatrix(task, in: cell, before: before)
        }))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityHint("Drop a task here to place it in \(title)")
  }
}

/// Reads where in the quadrant a drag is, which is why it is a delegate
/// rather than the closure form of `onDrop`: that is told what was dropped
/// but not where.
private struct MatrixQuadrantDropDelegate: DropDelegate {
  let target: @MainActor (CGFloat) -> (before: String?, line: Double?)
  let hover: @MainActor ((before: String?, line: Double?)?) -> Void
  let drop: @MainActor (String, String?) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [WorkspaceTaskDrag.typeIdentifier])
  }

  func dropEntered(info: DropInfo) {
    track(info)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    track(info)
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    MainActor.assumeIsolated { hover(nil) }
  }

  func performDrop(info: DropInfo) -> Bool {
    // `DropDelegate` is not main-actor bound, but AppKit calls every one of
    // these on the main thread while it tracks the drag.
    let before = MainActor.assumeIsolated {
      let mark = target(info.location.y)
      hover(nil)
      return mark.before
    }
    let providers = info.itemProviders(for: [WorkspaceTaskDrag.typeIdentifier])
    return WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
      drop(taskID, before)
    }
  }

  private func track(_ info: DropInfo) {
    MainActor.assumeIsolated {
      let mark = target(info.location.y)
      hover(mark)
    }
  }
}

struct WorkspaceMatrixTaskRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @FocusState private var isRowFocused: Bool
  let task: WorkspaceTask

  var body: some View {
    // The selected row grows to show its whole title and list name.
    let isSelected = task.id == model.selectedTaskID
    HStack(alignment: isSelected ? .firstTextBaseline : .center, spacing: theme.space.sm) {
      if model.editingTaskTitleID == task.id {
        WorkspaceTaskTitleField(
          initialTitle: task.title,
          caret: model.editingTaskTitleCaret,
          onCommit: { model.commitTaskTitleEdit(task, text: $0) },
          onCancel: { model.cancelTaskTitleEdit() })
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Button(task.title) {
          // A click on the row already selected edits its title in place,
          // as in the outline; the first click only selects.
          if isSelected && model.keyboardFocusArea == .tasks {
            model.editSelectedTaskTitle()
          } else {
            model.selectTask(task)
            model.reportKeyboardFocus(.tasks)
          }
        }
        .buttonStyle(.plain)
        .font(theme.bodyFont())
        .foregroundStyle(model.isBlocked(task) ? theme.muted : theme.ink)
        .focusable()
        .multilineTextAlignment(.leading)
        .expandsWhenSelected(isSelected)
        .help(task.title)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      WorkspacePriorityBadge(taskID: task.id)
      if model.isMultiListScope, let list = model.list(for: task) {
        Text(list.name)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .expandsWhenSelected(isSelected, truncation: .middle)
          .help(list.name)
      }
    }
    .padding(.horizontal, theme.space.sm)
    .padding(.vertical, theme.space.xs)
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .workspaceSelection(
      isSelected: isSelected, hasKeyboard: model.keyboardFocusArea == .tasks && isSelected)
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
        // ⌥↑ and ⌥↓ fall through to the command catalogue's move, which on
        // the matrix steps the task within its quadrant.
        let digits: [KeyEquivalent] = ["1", "2", "3", "4"]
        guard let index = digits.firstIndex(of: press.key) else { return .ignored }
        let cell = MatrixQuadrantCell.readingOrder[index]
        model.selectTask(task)
        model.setMatrixPosition(.init(urgency: cell.urgency, importance: cell.importance), for: task)
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
}
