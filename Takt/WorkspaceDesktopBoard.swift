import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI
import UniformTypeIdentifiers

/// The workspace board: columns of cards, the cards themselves, and the drag
/// payload they travel as.
///
/// Split out of `WorkspaceDesktopView.swift`, which had grown past the point
/// where the shell it is named after was findable in it. These types are
/// internal rather than file-private now only because they are read from the
/// shell's file; nothing outside the app should reach for them.

/// The board's column geometry.
///
/// Columns sit edge to edge with a hairline between them rather than as
/// separate filled wells with gaps, so the only figures left are the clamp on a
/// column's width. They are layout decisions, not theme tokens: a theme owns
/// spacing and type, not how many cards fit across a window.
enum WorkspaceBoardMetrics {
  /// The narrowest a column gets before the board scrolls sideways instead:
  /// room for a card's handle, check, two or three words of title, and its
  /// focus and disclosure controls.
  static let minColumnWidth: CGFloat = 172
  /// The widest. Past this a card's title runs to a line length that is read
  /// rather than scanned, and five default columns stop fitting on a laptop.
  static let maxColumnWidth: CGFloat = 340

  /// The inset of a column's header and composers. The cards themselves
  /// have none: they run the column's full width, rows of a table rather
  /// than tiles in a well.
  static func columnPadding(_ theme: Theme) -> CGFloat {
    theme.space.sm
  }

  /// The inset before the first column and after the last: none. The board
  /// runs to the pane's edges the way Zed's panes do, and the hairlines
  /// between columns are all the division it needs.
  static func edgeInset(_ theme: Theme) -> CGFloat {
    0
  }

  /// Most rows of a card's subtask tree drawn on the card. Past this the tree
  /// stops with a count, and opening the card shows the rest — one deep
  /// project should not push the whole column off screen.
  static let visibleSubtaskRows = 12

  /// Five default columns should be visible together at useful desktop
  /// widths. Fewer or custom columns expand instead of leaving an oversized
  /// empty canvas; very narrow windows still scroll.
  static func columnWidth(available width: CGFloat, columns: Int, theme: Theme) -> CGFloat {
    let count = CGFloat(max(columns, 1))
    let rules = theme.hairline * (count - 1)
    let usable = width - 2 * edgeInset(theme) - rules
    return max(minColumnWidth, min(maxColumnWidth, usable / count))
  }
}

struct WorkspaceKanbanBoard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    if model.selectedList == nil && !model.isMultiListScope {
      WorkspaceEmptyPane(title: "Board", message: "Choose a list in the sidebar to see its board.")
    } else {
      GeometryReader { geometry in
        let columnWidth = WorkspaceBoardMetrics.columnWidth(
          available: geometry.size.width, columns: model.boardColumns.count, theme: theme)
        VStack(spacing: 0) {
          // The board said nowhere on its face which list it was showing, so
          // ⌘2 from the outline took the scope name off the screen.
          WorkspacePaneHeader(title: model.currentBoardScopeTitle, switchesList: true) {
            if let exit = model.scopeExitTitle {
              WorkspacePaneScopeExit(title: exit) { model.leaveTaskScope() }
            }
          } trailing: {
            WorkspacePaneCount(count: model.boardColumns.reduce(0) { $0 + model.tasks(in: $1).count })
          }
          WorkspaceKanbanColumnStrip(columnWidth: columnWidth)
        }
      }
      .background(theme.paper)
    }
  }
}

/// The columns themselves. The one part of the board that reads the
/// selection, so an arrow key redraws this strip and the columns whose answer
/// changed, not the board's header, composer and geometry.
private struct WorkspaceKanbanColumnStrip: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let columnWidth: CGFloat
  @State private var visibleColumnIDs: Set<String> = []

  var body: some View {
    let activeColumnID = model.activeBoardColumnID
    let tasksHaveKeyboard = model.keyboardFocusArea == .tasks
    let selectedID = model.selectedTaskID
    // The column the selection is drawn in — for a subtask row, the column
    // of the card it is drawn on.
    let selectedColumnID = selectedID == nil ? nil : activeColumnID
    ScrollViewReader { scrollProxy in
      GeometryReader { viewport in
        ScrollView(.horizontal) {
          // Edge to edge, a hairline between each pair: columns are regions
          // of one surface, not cards laid on it.
          LazyHStack(alignment: .top, spacing: 0) {
            ForEach(model.boardColumns) { column in
              WorkspaceKanbanColumnView(
                column: column,
                width: columnWidth,
                height: viewport.size.height,
                hasKeyboard: tasksHaveKeyboard && activeColumnID == column.id,
                tasksHaveKeyboard: tasksHaveKeyboard,
                selectedRowID: column.id == selectedColumnID ? selectedID : nil)
                .environment(model)
                .id(column.id)
              if column.id != model.boardColumns.last?.id {
                Rectangle()
                  .fill(theme.border)
                  .frame(width: theme.hairline, height: viewport.size.height)
              }
            }
          }
          .scrollTargetLayout()
          .padding(.horizontal, WorkspaceBoardMetrics.edgeInset(theme))
          .background(WorkspaceHorizontalOverscrollDisabler())
        }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { ids in
          visibleColumnIDs = Set(ids)
        }
      }
      .onChange(of: activeColumnID) { _, columnID in
        guard let columnID, !visibleColumnIDs.contains(columnID) else { return }
        scrollProxy.scrollTo(columnID, anchor: .center)
      }
    }
  }
}

struct WorkspaceKanbanColumnView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let column: WorkspaceKanbanColumn
  let width: CGFloat
  let height: CGFloat
  /// Whether the arrow keys are in this column.
  let hasKeyboard: Bool
  /// Whether the task pane holds the keyboard at all.
  let tasksHaveKeyboard: Bool
  /// The selected card or subtask row, when it is drawn in this column; nil
  /// otherwise, so a selection moving between two other columns does not
  /// redraw this one.
  let selectedRowID: String?
  @State private var isDropTargeted = false
  @State private var isAddingAtTop = false
  @State private var topTaskTitle = ""
  @State private var visibleCardIDs: Set<String> = []
  @FocusState private var topComposerFocused: Bool

  /// Nothing at rest — the hairline between columns is the strip's, not the
  /// column's. An edge appears only to say something: the keyboard is here, or
  /// a card is about to land here.
  private var columnBorder: Color {
    if isDropTargeted { return theme.primary }
    return hasKeyboard ? theme.focusRing : .clear
  }

  var body: some View {
    let tasks = model.tasks(in: column)
    let selectedCardID = selectedRowID.flatMap { id in
      tasks.first { $0.id == id || model.boardTreeRows(of: $0).contains { $0.task.id == id } }?.id
    }
    VStack(alignment: .leading, spacing: theme.space.sm) {
      VStack(alignment: .leading, spacing: theme.space.sm) {
      HStack(spacing: theme.space.xs) {
        // The micro-label exists for exactly this and was being hand-rolled
        // one point smaller with no tracking, so column titles read narrower
        // than every other eyebrow in the app.
        MicroLabel(column.title)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(column.title)
        Text("\(tasks.count)")
          .font(theme.monoFont(size: theme.type.microLabel.size))
          .foregroundStyle(theme.dim)
          .monospacedDigit()
        Spacer()
        Button {
          isAddingAtTop = true
          topComposerFocused = true
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.muted)
        .focusable()
        .accessibilityLabel("Add task at top of \(column.title)")
        .commandHelp(.taskNew, note: "Add highest-priority task in \(column.title)")
        if model.boardColumns.count > 1 {
          Button(role: .destructive) {
            model.removeKanbanColumn(column)
          } label: {
            Image(systemName: "minus")
          }
          .buttonStyle(.plain)
          .foregroundStyle(theme.muted)
          .focusable()
          .commandHelp(.planBoardRemoveColumn, note: "Remove \(column.title)")
        }
      }

      if isAddingAtTop {
        TextField("Add at top", text: $topTaskTitle)
          .textFieldStyle(.plain)
          .font(theme.bodyFont())
          .padding(theme.space.xs)
          .overlay(
            Rectangle()
              .strokeBorder(theme.focusRing, lineWidth: theme.hairline))
          .focused($topComposerFocused)
          .onSubmit {
            let title = topTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            model.createBoardTask(named: title, in: column, atTop: true)
            topTaskTitle = ""
            isAddingAtTop = false
          }
          .onExitCommand {
            topTaskTitle = ""
            isAddingAtTop = false
          }
          .accessibilityLabel("New task at top of \(column.title)")
      }
      }
      .padding([.horizontal, .top], WorkspaceBoardMetrics.columnPadding(theme))

      ScrollViewReader { cardProxy in
        ScrollView(.vertical) {
          // Cards overlap by a hairline, so two neighbours share one rule the
          // way rows of a table do, rather than drawing a double line with a
          // gap between.
          LazyVStack(alignment: .leading, spacing: -theme.hairline) {
            ForEach(tasks) { task in
              WorkspaceKanbanCard(
                task: task, column: column,
                selectedRowID: task.id == selectedCardID ? selectedRowID : nil,
                hasKeyboard: tasksHaveKeyboard && task.id == selectedCardID)
                .environment(model)
                .id(task.id)
            }

            if tasks.isEmpty {
              VStack(spacing: theme.space.xs) {
                Image(systemName: "arrow.down.doc")
                  .font(theme.titleFont)
                Text(isDropTargeted ? "Drop card here" : "Drop cards here")
                  .font(theme.captionFont)
              }
              .foregroundStyle(isDropTargeted ? theme.primary : theme.dim)
              .frame(maxWidth: .infinity)
              .padding(.vertical, theme.space.lg)
              .overlay(
                Rectangle()
                  .stroke(
                    isDropTargeted ? theme.primary : theme.border,
                    style: StrokeStyle(lineWidth: theme.hairline, dash: [5]))
              )
              .padding(.horizontal, WorkspaceBoardMetrics.columnPadding(theme))
            }

            TaskComposer(focusRequest: 0) { title in
              model.createBoardTask(named: title, in: column)
            }
            .accessibilityLabel("Add task to \(column.title)")
            .padding(.horizontal, WorkspaceBoardMetrics.columnPadding(theme))
          }
          .scrollTargetLayout()
          .padding(.bottom, theme.space.xxs)
          .background(WorkspaceHorizontalOverscrollDisabler())
        }
        .onScrollTargetVisibilityChange(idType: String.self) { ids in
          visibleCardIDs = Set(ids)
        }
        .onChange(of: selectedCardID) { _, id in
          guard let id, !visibleCardIDs.contains(id) else { return }
          cardProxy.scrollTo(id, anchor: .center)
        }
        .onAppear {
          if let id = selectedCardID {
            cardProxy.scrollTo(id, anchor: .center)
          }
        }
      }
    }
    .frame(width: width, alignment: .topLeading)
    .frame(height: height, alignment: .topLeading)
    // On the page, not in a well: a column is a region of the board, and the
    // hairlines between columns are what divide it.
    .background(isDropTargeted ? theme.color(.primary, opacity: Theme.statusFillOpacity) : .clear)
    // "A card is about to land here" is the primary hue at the emphasis
    // weight; "the arrow keys are in this column" is the focus ring at a
    // hairline. They used to be the same 2pt accent ring.
    .overlay(
      Rectangle()
        .strokeBorder(columnBorder, lineWidth: isDropTargeted ? theme.emphasisBorder : theme.hairline)
        .allowsHitTesting(false)
    )
    // The fill used to make the whole column hit-testable; with none, the
    // shape has to say so, or a click on an empty column falls through.
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded {
      if tasks.isEmpty {
        model.focusedBoardColumnID = column.id
        model.selectedTaskID = nil
        model.reportKeyboardFocus(.tasks)
      }
    })
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
      WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
        guard let task = model.task(withID: taskID), model.isTaskVisibleOnBoard(task) else { return }
        model.moveTask(task, toKanbanColumn: column)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(column.title) column")
    .accessibilityHint("Drop a task here to move it to \(column.title)")
  }
}

struct WorkspaceKanbanCard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @FocusState private var isCardFocused: Bool
  @FocusState private var subtaskComposerFocused: Bool
  @State private var isAddingSubtask = false
  @State private var isDropTargeted = false
  @State private var isHovered = false
  @State private var newSubtaskTitle = ""
  let task: WorkspaceTask
  let column: WorkspaceKanbanColumn
  /// The selected row when it is this card or one of the subtask rows drawn
  /// on it; nil otherwise. Handed in rather than read from the model, so
  /// moving the selection redraws the cards it moved between and no others.
  let selectedRowID: String?
  /// Whether the keyboard is on this card or a row of its tree.
  let hasKeyboard: Bool

  private var isSelected: Bool { selectedRowID == task.id }
  private var isTreeCollapsed: Bool { model.isFolded(task) }

  var body: some View {
    cardSurface
      .help("Drag to move. \(WorkspaceCommandHelpText.text(for: .planEnterTask)); \(WorkspaceCommandHelpText.text(for: .planBoardMoveCardLeft))")
      .focusable()
      .focused($isCardFocused)
      .focusEffectDisabled()
      .onAppear {
        if model.keyboardFocusArea == .tasks && selectedRowID != nil {
          isCardFocused = true
        }
      }
      .onChange(of: model.focusRequest) { _, _ in
        if model.requestedFocusArea == .tasks && selectedRowID != nil {
          isCardFocused = true
        }
      }
      .onChange(of: isCardFocused) { _, focused in
        if focused {
          // A subtask row already selected keeps the selection: the card
          // holds the keyboard for the rows drawn on it.
          if selectedRowID == nil { model.selectTask(task) }
          model.reportKeyboardFocus(.tasks)
        }
      }
      .onChange(of: selectedRowID) { _, selected in
        if selected != nil && !isCardFocused { isCardFocused = true }
      }
      .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, .leftArrow, .rightArrow, "i"]) { press in
        handleCardKey(press)
      }
      .accessibilityElement(children: .contain)
      .contextMenu { WorkspaceItemActions(task: task) }
  }

  private var cardSurface: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      cardHeading
      if !task.isList, let dueAt = task.dueAt {
        HStack(spacing: theme.space.xs) {
          Image(systemName: "calendar")
          Text(dueAt, format: .dateTime.month().day())
        }.font(theme.captionFont).foregroundStyle(theme.muted)
      }
      if task.isList {
        Text("List · \(model.descendants(of: task).filter { !$0.task.isList }.count) tasks")
          .font(theme.captionFont).foregroundStyle(theme.muted)
      } else {
        WorkspaceTaskPlanningBadges(task: task)
      }
      subtaskTree
    }
    .padding(.vertical, theme.space.xs)
    .padding(.horizontal, WorkspaceBoardMetrics.columnPadding(theme))
    .frame(maxWidth: .infinity, alignment: .leading)
    // A bordered row on the page, not a raised card: the column is already the
    // surface, and a second tone inside it was a card on a well. Square, like
    // a table's rows, since the cards now meet edge to edge. Hover is the
    // theme's hover fill; selection draws on top of it, never instead of the
    // border's shape.
    .background {
      ZStack {
        Rectangle().fill(isHovered ? theme.hover : theme.paper)
        WorkspaceSelectionBackground(isSelected: isSelected, hasKeyboard: hasKeyboard && isSelected, radius: 0)
      }
    }
    .onHover { isHovered = $0 }
    .overlay {
      // Rules above and below only: the card runs the column's full width, so
      // side edges would double the hairlines between columns. Nothing when
      // the selection is already drawing an edge — which it does only while
      // it has the keyboard — so the card never carries two borders at once.
      if isDropTargeted {
        Rectangle().strokeBorder(theme.primary, lineWidth: theme.emphasisBorder)
      } else if !(isSelected && hasKeyboard) {
        VStack(spacing: 0) {
          Rectangle().fill(theme.border).frame(height: theme.hairline)
          Spacer(minLength: 0)
          Rectangle().fill(theme.border).frame(height: theme.hairline)
        }
        .allowsHitTesting(false)
      }
    }
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
      if task.isList {
        return WorkspaceTaskDrag.readItemID(from: providers) { payload in
          model.moveDroppedItem(payload, toListID: task.listId, parentTaskID: task.id)
        }
      }
      return WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
        guard let dragged = model.task(withID: taskID), dragged.id != task.id else { return }
        model.placeTask(dragged, before: task)
      }
    }
  }

  private func handleCardKey(_ press: KeyPress) -> KeyPress.Result {
    guard isCardFocused else { return .ignored }
    // The keys act on the row the selection is on, which may be a subtask.
    let target = selectedRowID.flatMap { model.task(withID: $0) } ?? task
    if press.modifiers.contains(.option) {
      if press.key == .leftArrow { model.moveTaskToAdjacentColumn(task, by: -1) } else if press.key == .rightArrow { model.moveTaskToAdjacentColumn(task, by: 1) } else { return .ignored }

    } else if press.key == .space {
      model.toggleTask(target)
    } else if press.key == .return {
      if target.isList { model.openItemList(target) } else { model.enterTask(target) }
    } else if press.key == .upArrow {
      model.selectAdjacentTask(by: -1)
    } else if press.key == .downArrow {
      model.selectAdjacentTask(by: 1)
    } else if press.key == .leftArrow {
      model.selectTaskInAdjacentColumn(from: task, by: -1)
    } else if press.key == .rightArrow {
      model.selectTaskInAdjacentColumn(from: task, by: 1)
    } else if press.key == "i" {
      model.toggleInspector()
    } else { return .ignored }
    return .handled
  }

  private var cardHeading: some View {
    HStack(spacing: theme.space.xs) {
      Image(systemName: "line.3.horizontal")
        .font(theme.microLabelFont)
        .foregroundStyle(theme.dim)
        .frame(width: theme.space.md, height: theme.space.xl)
        .contentShape(Rectangle())
        .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
        .accessibilityLabel("Drag \(task.title)")
        .help("Drag this card to reorder it or move it to another column")
      Button {
        if task.isList { model.openItemList(task) } else { model.toggleTask(task) }
      } label: {
        Image(systemName: model.itemSymbol(for: task))
          .foregroundStyle(task.status == .open ? theme.muted : theme.success)
      }
      .buttonStyle(.plain)
      .focusable()
      Button(task.title) {
        model.selectTask(task)
        model.reportKeyboardFocus(.tasks)
      }
      .buttonStyle(.plain)
      .font(theme.bodyFont())
      .foregroundStyle(task.status == .open ? theme.ink : theme.muted)
      .focusable()
      .multilineTextAlignment(.leading)
      .lineLimit(2)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(task.title)
      .strikethrough(task.status != .open)
      if !task.isList {
      Button {
        if model.activeFocusSession == nil {
          model.startFocus(on: task)
        } else if model.activeFocusSession?.activeTaskId == task.id {
          model.openFocusPanel()
        } else {
          model.addToFocusQueue(task)
        }
      } label: {
        Image(systemName: model.activeFocusSession?.activeTaskId == task.id ? "bolt.fill" :
          model.activeFocusSession == nil ? "bolt" : "plus")
          .font(theme.captionFont)
          .foregroundStyle(model.activeFocusSession?.activeTaskId == task.id ? theme.primary : theme.muted)
      }
      .buttonStyle(.plain)
      .focusable()
      .accessibilityLabel(model.activeFocusSession == nil ? "Focus on \(task.title)" : "Add \(task.title) to focus")
      .commandHelp(
        .taskStartFocus,
        note: model.activeFocusSession == nil ? "Start focus" : "Add to focus queue")
      }
      Button {
        isAddingSubtask = true
        if isTreeCollapsed { model.toggleFold(of: task) }
        subtaskComposerFocused = true
      } label: {
        Image(systemName: "plus")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
      }
      .buttonStyle(.plain)
      .focusable()
      .accessibilityLabel("Add subtask under \(task.title)")
      .help("Add a subtask")
      if !model.descendants(of: task).isEmpty {
        Button {
          model.toggleFold(of: task)
        } label: {
          Image(systemName: isTreeCollapsed ? "chevron.down" : "chevron.up")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel(isTreeCollapsed ? "Show subtasks" : "Hide subtasks")
        .help(isTreeCollapsed ? "Show subtasks" : "Hide subtasks")
      }
    }
  }

  /// Where the tree starts: past the heading's drag handle and its gap, so a
  /// direct child's check sits under the card's own.
  private static func treeInset(_ theme: Theme) -> CGFloat {
    theme.space.md + theme.space.xs
  }

  /// One level of the tree: the width of a subtask's check, so each indent
  /// guide runs straight down beneath the check of the task it belongs to.
  private static func indentStep(_ theme: Theme) -> CGFloat {
    theme.space.lg
  }

  /// The card's whole subtree, every level, drawn the way an editor's project
  /// panel draws one: a compact row per task, indented a check's width per
  /// level, with a hairline guide down each level it is nested in. Shown by
  /// default — the cards used to hide their subtasks behind a disclosure, and
  /// then only in a six-row scroller inside the card.
  ///
  /// Read from `boardDescendants`, which the board's load fills for every
  /// card and every task inside one, so drawing it is a dictionary lookup.
  @ViewBuilder private var subtaskTree: some View {
    let items = model.boardTreeUnfoldedRows(of: task)
    if !items.isEmpty || isAddingSubtask {
      let limit = WorkspaceBoardMetrics.visibleSubtaskRows
      let parents = TaskOutlineFolding.parentIDs(model.descendants(of: task))
      VStack(alignment: .leading, spacing: 0) {
        ForEach(model.boardTreeRows(of: task)) { item in
          subtaskRow(item, isFolded: parents.contains(item.id) ? model.foldedTaskIDs.contains(item.id) : nil)
        }
        if items.count > limit {
          Button {
            if task.isList { model.openItemList(task) } else { model.enterTask(task) }
          } label: {
            Text("+\(items.count - limit) more")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(.leading, Self.indentStep(theme))
          .padding(.vertical, theme.space.xxs)
          .help("Open \(task.title) to see every subtask")
        }
        if isAddingSubtask { subtaskComposer }
      }
      .padding(.leading, Self.treeInset(theme))
    }
  }

  private var subtaskComposer: some View {
    HStack(spacing: 0) {
      Image(systemName: "plus")
        .foregroundStyle(theme.muted)
        .frame(width: Self.indentStep(theme))
      TextField("Add subtask", text: $newSubtaskTitle)
        .textFieldStyle(.plain)
        .focused($subtaskComposerFocused)
        .onSubmit { submitSubtask() }
        .onExitCommand {
          newSubtaskTitle = ""
          isAddingSubtask = false
        }
        .accessibilityLabel("Add subtask under \(task.title)")
    }
    .font(theme.captionFont)
    .padding(.vertical, theme.space.xxs)
  }

  private func subtaskRow(_ item: TaskOutlineItem, isFolded: Bool?) -> some View {
    let isOpen = item.task.status == .open
    let step = Self.indentStep(theme)
    return HStack(spacing: 0) {
      Button {
        if item.task.isList { model.openItemList(item.task) } else { model.toggleTask(item.task) }
      } label: {
        Image(systemName: model.itemSymbol(for: item.task))
          .foregroundStyle(isOpen ? theme.muted : theme.success)
          .frame(width: step)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        item.task.isList ? "Open \(item.task.title)" : (isOpen ? "Complete \(item.task.title)" : "Reopen \(item.task.title)"))
      Button(item.task.title) {
        model.selectTask(item.task)
        model.reportKeyboardFocus(.tasks)
      }
      .buttonStyle(.plain)
      .foregroundStyle(isOpen ? theme.ink : theme.muted)
      .strikethrough(!isOpen)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(item.task.title)
      // Trailing, as the card's own fold is, so the guides stay under the
      // checks.
      if let isFolded {
        WorkspaceFoldButton(isFolded: isFolded, title: item.task.title) { model.toggleFold(of: item.task) }
      }
    }
    .font(theme.captionFont)
    .padding(.vertical, theme.space.xxs)
    .padding(.leading, CGFloat(item.depth) * step)
    // The same band as a card's selection, across the tree's width, so the
    // arrow keys can be seen stepping through a card's subtasks.
    .background {
      WorkspaceSelectionBackground(
        isSelected: selectedRowID == item.task.id,
        hasKeyboard: hasKeyboard && selectedRowID == item.task.id, radius: 0)
    }
    // Behind the padded row, so each guide runs its full height and meets
    // the next row's without a gap.
    .background(alignment: .leading) {
      HStack(spacing: 0) {
        ForEach(0..<item.depth, id: \.self) { _ in
          Rectangle()
            .fill(theme.border)
            .frame(width: theme.hairline)
            .frame(width: step)
        }
      }
    }
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: item.task.id) }
    .contextMenu {
      WorkspaceItemActions(task: item.task)
      // The row used to carry this as an always-visible menu of its own; in
      // the context menu it costs the tree no width.
      Menu("Move to Column") {
        ForEach(model.boardColumns) { destination in
          Button(destination.title) { model.moveTask(item.task, toKanbanColumn: destination) }
        }
      }
    }
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: nil) { providers in
      guard item.task.isList else { return false }
      return WorkspaceTaskDrag.readItemID(from: providers) { payload in
        model.moveDroppedItem(payload, toListID: item.task.listId, parentTaskID: item.task.id)
      }
    }
  }

  private func submitSubtask() {
    let title = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    model.createSubtask(named: title, under: task)
    newSubtaskTitle = ""
  }
}

/// String objects advertise macOS's standard text pasteboard type. Each drop
/// still resolves the ID through the local store before changing any task.
enum WorkspaceTaskDrag {
  static var typeIdentifier: String { UTType.utf8PlainText.identifier }
  static let listPrefix = "priority-list:"
  static let folderPrefix = "priority-folder:"

  static func provider(forList listID: String) -> NSItemProvider {
    provider(for: listPrefix + listID)
  }

  static func provider(forFolder folderID: String) -> NSItemProvider {
    provider(for: folderPrefix + folderID)
  }

  /// The id inside a sidebar payload, whichever kind it is. `nil` for a task
  /// drag, which sidebar *placement* has no meaning for — a task is moved into
  /// a list, not between them.
  static func sidebarItemID(from payload: String) -> (id: String, isFolder: Bool)? {
    if payload.hasPrefix(folderPrefix) {
      return (String(payload.dropFirst(folderPrefix.count)), true)
    }
    if payload.hasPrefix(listPrefix) {
      return (String(payload.dropFirst(listPrefix.count)), false)
    }
    return nil
  }

  static func provider(for taskID: String) -> NSItemProvider {
    NSItemProvider(object: taskID as NSString)
  }

  static func readTaskID(from providers: [NSItemProvider], apply: @escaping @MainActor (String) -> Void) -> Bool {
    readItemID(from: providers) { payload in
      guard !payload.hasPrefix(listPrefix) else { return }
      apply(payload)
    }
  }

  static func readItemID(from providers: [NSItemProvider], apply: @escaping @MainActor (String) -> Void) -> Bool {
    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
      return false
    }
    provider.loadObject(ofClass: NSString.self) { value, _ in
      guard let taskID = value as? String, !taskID.isEmpty else { return }
      DispatchQueue.main.async { apply(taskID) }
    }
    return true
  }
}

