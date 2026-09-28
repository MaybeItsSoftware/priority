import AppKit
import PriorityCore
import PriorityWorkspace
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

  /// The inset before the first column and after the last. The pane gutter
  /// less a column's own padding, so the first column's label lines up with
  /// the pane title above it.
  static func edgeInset(_ theme: Theme) -> CGFloat {
    max(FocusSurfaceMetrics.gutter - theme.space.md, 0)
  }

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
      ContentUnavailableView("No list selected", systemImage: "rectangle.split.3x1")
    } else {
      GeometryReader { geometry in
        let columnWidth = WorkspaceBoardMetrics.columnWidth(
          available: geometry.size.width, columns: model.boardColumns.count, theme: theme)
        VStack(spacing: 0) {
          // The board said nowhere on its face which list it was showing, so
          // ⌘2 from the outline took the scope name off the screen.
          WorkspacePaneHeader(title: model.currentBoardScopeTitle) {
            if let exit = model.scopeExitTitle {
              WorkspacePaneScopeExit(title: exit) { model.leaveTaskScope() }
            }
          } trailing: {
            WorkspacePaneCount(count: model.boardColumns.reduce(0) { $0 + model.tasks(in: $1).count })
          }
          FocusRule()
          WorkspaceKanbanColumnStrip(columnWidth: columnWidth)
          FocusRule()
          WorkspaceScopedTaskComposer(board: true)
            .environment(model)
            .padding(.horizontal, FocusSurfaceMetrics.gutter)
            .padding(.vertical, theme.space.sm)
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
    let selectedColumnID = selectedID.flatMap { model.boardColumnID(forTaskID: $0) }
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
                selectedCardID: column.id == selectedColumnID ? selectedID : nil)
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
  /// The selected card, when it is one of this column's; nil otherwise, so a
  /// selection moving between two other columns does not redraw this one.
  let selectedCardID: String?
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
            RoundedRectangle(cornerRadius: theme.controlRadius)
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

      ScrollViewReader { cardProxy in
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: theme.space.xs) {
            ForEach(tasks) { task in
              WorkspaceKanbanCard(
                task: task, column: column,
                isSelected: task.id == selectedCardID,
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
                RoundedRectangle(cornerRadius: theme.controlRadius)
                  .stroke(
                    isDropTargeted ? theme.primary : theme.border,
                    style: StrokeStyle(lineWidth: theme.hairline, dash: [5]))
              )
            }

            TaskComposer(focusRequest: 0) { title in
              model.createBoardTask(named: title, in: column)
            }
            .accessibilityLabel("Add task to \(column.title)")
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
    .padding(theme.space.md)
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
  @State private var isExpanded = false
  @State private var isDropTargeted = false
  @State private var isHovered = false
  @State private var newSubtaskTitle = ""
  let task: WorkspaceTask
  let column: WorkspaceKanbanColumn
  /// Handed in rather than read from the model, so moving the selection
  /// redraws the two cards it moved between and no others.
  let isSelected: Bool
  let hasKeyboard: Bool

  var body: some View {
    cardSurface
      .help("Drag to move. \(WorkspaceCommandHelpText.text(for: .planEnterTask)); \(WorkspaceCommandHelpText.text(for: .planBoardMoveCardLeft))")
      .focusable()
      .focused($isCardFocused)
      .focusEffectDisabled()
      .onAppear {
        if model.keyboardFocusArea == .tasks && model.selectedTaskID == task.id {
          isCardFocused = true
        }
      }
      .onChange(of: model.focusRequest) { _, _ in
        if model.requestedFocusArea == .tasks && model.selectedTaskID == task.id {
          isCardFocused = true
        }
      }
      .onChange(of: isCardFocused) { _, focused in
        if focused {
          model.selectTask(task)
          model.reportKeyboardFocus(.tasks)
        }
      }
      .onChange(of: isSelected) { _, selected in
        if selected && !isCardFocused { isCardFocused = true }
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
      if isExpanded { inlineSubtasks }
    }
    .padding(theme.space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    // A bordered row on the page, not a raised card: the column is already the
    // surface, and a second tone inside it was a card on a well. Hover is the
    // theme's hover fill; selection draws on top of it, never instead of the
    // border's shape.
    .background {
      let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
      ZStack {
        shape.fill(isHovered ? theme.hover : theme.paper)
        WorkspaceSelectionBackground(
          isSelected: isSelected, hasKeyboard: hasKeyboard, radius: theme.controlRadius)
      }
    }
    .onHover { isHovered = $0 }
    .overlay {
      let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
      // Nothing when the selection is already drawing an edge, so the card
      // never carries two borders of different colours at once.
      shape.strokeBorder(
        isDropTargeted ? theme.primary : (isSelected ? .clear : theme.border),
        lineWidth: isDropTargeted ? theme.emphasisBorder : theme.hairline)
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
    if press.modifiers.contains(.option) {
      if press.key == .leftArrow { model.moveTaskToAdjacentColumn(task, by: -1) } else if press.key == .rightArrow { model.moveTaskToAdjacentColumn(task, by: 1) } else { return .ignored }

    } else if press.key == .space {
      model.toggleTask(task)
    } else if press.key == .return {
      model.enterTask(task)
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
          model.presentFocusScreen()
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
        isExpanded.toggle()
      } label: {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
      }
      .buttonStyle(.plain)
      .focusable()
      .accessibilityLabel(isExpanded ? "Collapse subtasks" : "Expand subtasks")
      .help(isExpanded ? "Collapse subtasks" : "Show subtasks and add a subtask")
    }
  }

  private var inlineSubtasks: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      FocusRule()
      let items = model.descendants(of: task)
      if items.isEmpty {
        Text("No subtasks yet")
          .font(theme.captionFont)
          .foregroundStyle(theme.dim)
      } else {
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: theme.space.xs) {
            ForEach(items) { item in
              inlineSubtaskRow(item)
            }
          }
        }
        .frame(height: min(CGFloat(items.count) * Self.subtaskRowPitch(theme), Self.subtaskListMaxHeight(theme)))
      }
      HStack(spacing: theme.space.xs) {
        Image(systemName: "plus")
          .foregroundStyle(theme.muted)
        TextField("Add subtask", text: $newSubtaskTitle)
          .textFieldStyle(.plain)
          .onSubmit { submitSubtask() }
          .accessibilityLabel("Add subtask under \(task.title)")
      }
      .font(theme.captionFont)
    }
  }

  /// One inline subtask row and the gap after it: a caption line, room for
  /// its column menu, and the stack's spacing.
  private static func subtaskRowPitch(_ theme: Theme) -> CGFloat {
    theme.space.xl + theme.space.xs
  }

  /// Six rows, then the list scrolls inside the card rather than pushing the
  /// rest of the column off screen.
  private static func subtaskListMaxHeight(_ theme: Theme) -> CGFloat {
    subtaskRowPitch(theme) * 6
  }

  /// Room for a short column name in the subtask's column menu; a longer one
  /// truncates rather than squeezing the subtask's title.
  private static let subtaskColumnMenuWidth: CGFloat = 50

  private func inlineSubtaskRow(_ item: TaskOutlineItem) -> some View {
    HStack(spacing: theme.space.xs) {
      Button {
        if item.task.isList { model.openItemList(item.task) } else { model.toggleTask(item.task) }
      } label: {
        Image(systemName: model.itemSymbol(for: item.task))
          .foregroundStyle(theme.muted)
      }
      .buttonStyle(.plain)
      .focusable()
      Button(item.task.title) {
        model.selectTask(item.task)
        model.reportKeyboardFocus(.tasks)
      }
      .buttonStyle(.plain)
      .focusable()
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(item.task.title)
      Menu {
        ForEach(model.boardColumns) { destination in
          Button(destination.title) { model.moveTask(item.task, toKanbanColumn: destination) }
        }
      } label: {
        Text(model.column(for: item.task)?.title ?? "Backlog")
          .lineLimit(1)
          .font(theme.microLabelFont)
          .frame(maxWidth: Self.subtaskColumnMenuWidth)
      }
      .menuStyle(.borderlessButton)
      .focusable()
      .commandHelp(.taskMove, note: "Move \(item.task.title) to a column")
    }
    .font(theme.captionFont)
    .padding(.leading, CGFloat(item.depth) * theme.space.md)
    .onDrag { WorkspaceTaskDrag.provider(for: item.task.id) }
    .contextMenu { WorkspaceItemActions(task: item.task) }
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

