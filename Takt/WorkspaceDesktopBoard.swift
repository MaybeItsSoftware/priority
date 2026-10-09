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
    // The link the selection is on, drawn in the accent across every column
    // it spans; the others keep the border's colour.
    let selectedLink = selectedID.flatMap { model.boardLinks.link(forChild: $0) }.flatMap { $0.isAligned ? $0 : nil }
    let linkLayout = model.boardLinkLayout
    ScrollViewReader { scrollProxy in
      GeometryReader { viewport in
        ScrollView(.horizontal) {
          // Edge to edge, a hairline between each pair: columns are regions
          // of one surface, not cards laid on it.
          LazyHStack(alignment: .top, spacing: 0) {
            ForEach(Array(model.boardColumns.enumerated()), id: \.element.id) { index, column in
              WorkspaceKanbanColumnView(
                column: column,
                columnIndex: index,
                width: columnWidth,
                height: viewport.size.height,
                hasKeyboard: tasksHaveKeyboard && activeColumnID == column.id,
                tasksHaveKeyboard: tasksHaveKeyboard,
                selectedRowID: column.id == selectedColumnID ? selectedID : nil,
                linkLayout: linkLayout.column(index),
                selectedLink: selectedLink.flatMap {
                  ($0.sourceColumn...$0.childColumn).contains(index) ? $0 : nil
                })
                .environment(model)
                // The hairline is drawn on the column rather than beside it.
                // As a sibling it was a scroll target answering to the same
                // id, so a column scrolled almost out to the left still
                // counted as visible by its right-hand rule, and ← to it
                // never scrolled back.
                .padding(.trailing, column.id == model.boardColumns.last?.id ? 0 : theme.hairline)
                .overlay(alignment: .trailing) {
                  if column.id != model.boardColumns.last?.id {
                    Rectangle()
                      .fill(theme.border)
                      .frame(width: theme.hairline, height: viewport.size.height)
                  }
                }
                .id(column.id)
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
    // Neighbouring cards overlap by a rule, which the link layout counts.
    .onAppear { model.setBoardCardSpacing(-Double(theme.hairline)) }
    .onChange(of: theme.hairline) { _, hairline in model.setBoardCardSpacing(-Double(hairline)) }
  }
}

struct WorkspaceKanbanColumnView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  /// The draft row, drawn as a card.
  private var draftRow: some View {
    WorkspaceTaskDraftRow(isCard: true)
  }
  let column: WorkspaceKanbanColumn
  /// The column's place on the board, which the link layout counts by.
  let columnIndex: Int
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
  /// The space this column lets in to draw links level, and the links
  /// passing through it.
  let linkLayout: BoardLinkLayout.Column
  /// The selected link, when it starts, ends or passes through here.
  let selectedLink: BoardLinks.Link?
  @State private var isDropTargeted = false
  @State private var visibleCardIDs: Set<String> = []

  /// Nothing at rest — the hairline between columns is the strip's, not the
  /// column's. An edge appears only to say something: the keyboard is here, or
  /// a card is about to land here.
  private var columnBorder: Color {
    if isDropTargeted { return theme.primary }
    return hasKeyboard ? theme.focusRing : .clear
  }

  var body: some View {
    let tasks = model.tasks(in: column)
    // The card the selected row is drawn on, looked up in the index the
    // board keeps rather than found by walking each card's subtasks.
    let selectedCardID = selectedRowID.flatMap { model.boardRows(in: column).cardByRow[$0] }
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
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
          .monospacedDigit()
        Spacer()
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
              // The gap that drops a card level with the row it stands for in
              // an earlier column. A view of its own rather than padding on
              // the card, so scrolling to the card centres the card and not
              // the gap; a rule taller, as the card overlaps it by one.
              if let gap = linkLayout.gapAbove[task.id], gap >= 0.5 {
                Color.clear.frame(height: CGFloat(gap) + theme.hairline)
              }
              if model.draftsBeside(task.id, above: true) { draftRow }
              WorkspaceKanbanCard(
                task: task, column: column,
                selectedRowID: task.id == selectedCardID ? selectedRowID : nil,
                hasKeyboard: tasksHaveKeyboard && task.id == selectedCardID,
                measuresLinks: measuresLinks,
                spaceAboveRows: spaceAboveRows(on: task.id),
                selectedLinkID: selectedLink.flatMap {
                  $0.childID == task.id || $0.sourceCardID == task.id ? $0.childID : nil
                })
                .environment(model)
                .id(task.id)
              if model.draftsBeside(task.id, above: false) { draftRow }
            }
            // A new card with no task to sit beside lands at the foot of the
            // column you are in, so that is where it is typed.
            if model.draftsAtEnd(ofColumn: column.id) { draftRow }


          }
          .scrollTargetLayout()
          .background(alignment: .topLeading) { passingLines }
          // Room for a link passing below the last card, so it can be
          // scrolled to.
          .frame(minHeight: passingLinesDepth, alignment: .top)
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

  /// Whether this column's cards report their heights: only where a link
  /// starts or ends do they move one.
  private var measuresLinks: Bool {
    model.boardLinks.measuredColumns.contains(columnIndex)
  }

  /// The space let in above each linked row on a card, by row.
  private func spaceAboveRows(on cardID: String) -> [String: CGFloat] {
    guard let rows = model.boardLinks.linkedRows[cardID] else { return [:] }
    var spaces: [String: CGFloat] = [:]
    for row in rows {
      if let space = linkLayout.spaceAboveRow[BoardRowKey(card: cardID, row: row)] { spaces[row] = CGFloat(space) }
    }
    return spaces
  }

  /// Links on their way from an earlier column to a later one, drawn behind
  /// the cards: across the gaps the layout opened, and hidden by any card
  /// sitting in their path.
  @ViewBuilder private var passingLines: some View {
    if !linkLayout.passingLines.isEmpty {
      ZStack(alignment: .topLeading) {
        ForEach(linkLayout.passingLines) { line in
          Rectangle()
            .fill(line.childID == selectedLink?.childID ? theme.primary : theme.border)
            .frame(height: theme.hairline)
            .offset(y: CGFloat(line.y) - theme.hairline / 2)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private var passingLinesDepth: CGFloat {
    guard let deepest = linkLayout.passingLines.map(\.y).max() else { return 0 }
    return CGFloat(deepest) + theme.space.md
  }
}

struct WorkspaceKanbanCard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @FocusState private var isCardFocused: Bool
  @State private var isDropTargeted = false
  @State private var isHovered = false
  let task: WorkspaceTask
  let column: WorkspaceKanbanColumn
  /// The selected row when it is this card or one of the subtask rows drawn
  /// on it; nil otherwise. Handed in rather than read from the model, so
  /// moving the selection redraws the cards it moved between and no others.
  let selectedRowID: String?
  /// Whether the keyboard is on this card or a row of its tree.
  let hasKeyboard: Bool
  /// Whether the card reports its height for the link layout: only in a
  /// column a link starts or ends in.
  var measuresLinks = false
  /// The space let in above each linked row, to draw it level with the card
  /// it stands for in a later column.
  var spaceAboveRows: [String: CGFloat] = [:]
  /// The selected link, when this card is either end of it.
  var selectedLinkID: String?

  private var isSelected: Bool { selectedRowID == task.id }
  private var isTreeCollapsed: Bool { model.isFolded(task) }

  /// The card's own coordinates, which its rows and heading are measured in.
  private var cardSpace: NamedCoordinateSpace { .named("board-card:\(task.id)") }

  /// This card as the subtask end of a link, when it is one.
  private var link: BoardLinks.Link? { model.boardLinks.link(forChild: task.id) }

  /// The hairline's colour for the link to `childID`: the accent while the
  /// selection is on it, the border's otherwise.
  private func linkColour(_ childID: String) -> Color {
    selectedLinkID == childID ? theme.primary : theme.border
  }

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
    let inside = spaceAboveRows.values.reduce(0, +)
    return VStack(alignment: .leading, spacing: theme.space.xs) {
      cardHeading
      linkHint
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
        WorkspaceTaskPlanningBadges(task: task, isExpanded: isSelected)
        WorkspaceWaitingBadges(task: task)
      }
      subtaskTree
    }
    .padding(.vertical, theme.space.xs)
    .padding(.horizontal, WorkspaceBoardMetrics.columnPadding(theme))
    .frame(maxWidth: .infinity, alignment: .leading)
    .coordinateSpace(cardSpace)
    // Less the space the links let in, so the layout reads the card's own
    // height and never its own answer back. Zero, and so never reported,
    // in a column no link touches.
    .onGeometryChange(for: CGFloat.self) { proxy in
      measuresLinks ? proxy.size.height - inside : 0
    } action: { height in
      if measuresLinks { model.reportBoardCardHeight(task.id, Double(height)) }
    }
    // A bordered row on the page, not a raised card: the column is already the
    // surface, and a second tone inside it was a card on a well. Square, like
    // a table's rows, since the cards now meet edge to edge. Hover is the
    // theme's hover fill; selection draws on top of it, never instead of the
    // border's shape.
    .background {
      ZStack {
        Rectangle().fill(isHovered ? theme.hover : theme.paper)
        WorkspaceSelectionBackground(isSelected: isSelected, hasKeyboard: hasKeyboard && isSelected)
      }
    }
    .onHover { hovering in withAnimation(WorkspaceMotion.quick) { isHovered = hovering } }
    .overlay {
      // Rules above and below only: the card runs the column's full width, so
      // side edges would double the hairlines between columns. The selection
      // is a band with no edge of its own, so the rules stay over it.
      if isDropTargeted {
        Rectangle().strokeBorder(theme.primary, lineWidth: theme.emphasisBorder)
      } else {
        VStack(spacing: 0) {
          FocusRule()
          Spacer(minLength: 0)
          FocusRule()
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
      if press.key == .leftArrow { model.moveTaskToAdjacentColumn(target, by: -1) } else if press.key == .rightArrow { model.moveTaskToAdjacentColumn(target, by: 1) } else { return .ignored }

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
    // A selected card grows to its whole title, with the mark and the
    // buttons kept level with the title's first line. The card itself is the
    // drag source, so it carries no handle, and an open task keeps no blank
    // slot for a check: space completes it, and only a list or a finished
    // task has a mark worth the width.
    HStack(alignment: isSelected && headingLinkID == nil ? .firstTextBaseline : .center, spacing: theme.space.xs) {
      if task.isList || task.status != .open {
        Button {
          if task.isList { model.openItemList(task) } else { model.toggleTask(task) }
        } label: {
          WorkspaceTaskMarker(task: task)
            .frame(width: theme.space.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .commandHelp(task.isList ? .planEnterTask : .taskComplete, note: task.isList ? "Open the list" : nil)
      }
      Button(task.title) {
        model.selectTask(task)
        model.reportKeyboardFocus(.tasks)
      }
      .buttonStyle(.plain)
      .font(theme.bodyFont())
      .foregroundStyle(task.status == .open ? theme.ink : theme.muted)
      .focusable()
      .multilineTextAlignment(.leading)
      .expandsWhenSelected(isSelected, lineLimit: 2)
      .frame(maxWidth: headingLinkID == nil ? .infinity : nil, alignment: .leading)
      .help(task.title)
      .strikethrough(task.status != .open)
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
        .commandHelp(.planToggleFold, note: isTreeCollapsed ? "Show subtasks" : "Hide subtasks")
      }
      if let headingLinkID {
        WorkspaceBoardLinkLeader(colour: linkColour(headingLinkID))
      }
    }
    // A subtask drawn level with its parent's row: the hairline from the
    // earlier column comes in across the card's margin to its title.
    .background(alignment: .leading) {
      if let link, link.isAligned {
        let margin = WorkspaceBoardMetrics.columnPadding(theme)
        Rectangle()
          .fill(linkColour(link.childID))
          .frame(width: margin - theme.space.xxs, height: theme.hairline)
          .offset(x: -margin)
          .accessibilityHidden(true)
      }
    }
    .onGeometryChange(for: CGFloat.self) { [reportsHeading, cardSpace] proxy in
      reportsHeading ? proxy.frame(in: cardSpace).midY : 0
    } action: { mid in
      if mid > 0 { model.reportBoardHeadingMid(task.id, Double(mid)) }
    }
  }

  /// Whether a levelled link meets or leaves this card's heading, so the
  /// layout needs to know where its middle is.
  private var reportsHeading: Bool {
    measuresLinks && model.boardLinks.headingCards.contains(task.id)
  }

  /// The subtask a levelled link meets at this card's heading, because the
  /// card is not drawing the subtask's row.
  private var headingLinkID: String? { model.boardLinks.headingLinks[task.id] }

  /// "↳ parent" on a subtask card that could not be drawn level with the card
  /// it hangs from: one in an earlier column, one whose parent's heading
  /// another link already holds, one that would cross another link, or one
  /// whose parent no card on the board draws.
  @ViewBuilder private var linkHint: some View {
    if model.boardLinks.needsHint(task.id), let parent = model.boardParent(of: task) {
      Text("↳ \(parent.title)")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .truncationMode(.tail)
        .help("A subtask of \(parent.title)")
    }
  }

  /// The width of a subtask's mark column.
  private static func markWidth(_ theme: Theme) -> CGFloat {
    theme.space.lg
  }

  /// The card's whole subtree, every level, a compact row per task. Every
  /// row sits flush with the card's content edge, whatever its depth: the
  /// `└` mark is what says a row hangs under another, and a margin per
  /// level spent a narrow column's width on saying it again. Shown by
  /// default — the cards used to hide their subtasks behind a disclosure, and
  /// then only in a six-row scroller inside the card.
  ///
  /// Read from `boardDescendants`, which the board's load fills for every
  /// card and every task inside one, so drawing it is a dictionary lookup.
  @ViewBuilder private var subtaskTree: some View {
    let items = model.boardTreeUnfoldedRows(of: task)
    if !items.isEmpty {
      let limit = WorkspaceBoardMetrics.visibleSubtaskRows
      let parents = TaskOutlineFolding.parentIDs(model.descendants(of: task))
      let rows = model.boardTreeRows(of: task)
      let spaceThrough = spaceThroughRows(rows)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { item in
          // Space let in above a row to draw it level with the card it
          // stands for in a later column.
          if let space = spaceAboveRows[item.id], space >= 0.5 {
            Color.clear.frame(height: space)
          }
          subtaskRow(
            item, isFolded: parents.contains(item.id) ? model.foldedTaskIDs.contains(item.id) : nil,
            spaceAbove: spaceThrough[item.id] ?? 0)
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
          .padding(.vertical, theme.space.xxs)
          .commandHelp(.planEnterTask, note: "Open \(task.title) to see every subtask")
        }
      }
    }
  }

  /// The space let in above each linked row and every row before it, which
  /// its measured top is taken less of.
  private func spaceThroughRows(_ rows: [TaskOutlineItem]) -> [String: CGFloat] {
    guard !spaceAboveRows.isEmpty else { return [:] }
    var total: CGFloat = 0
    var through: [String: CGFloat] = [:]
    for row in rows {
      total += spaceAboveRows[row.id] ?? 0
      through[row.id] = total
    }
    return through
  }

  /// - Parameter spaceAbove: the space let in above the row and the rows
  ///   before it, which its reported top is taken less of.
  private func subtaskRow(_ item: TaskOutlineItem, isFolded: Bool?, spaceAbove: CGFloat) -> some View {
    let isOpen = item.task.status == .open
    let step = Self.markWidth(theme)
    let isRowSelected = selectedRowID == item.task.id
    // A levelled link leaves this row for the subtask's own card further
    // on; one that could not be levelled leaves an arrow saying which way.
    let rowLink = model.boardLinks.link(forChild: item.task.id).flatMap { $0.sourceCardID == task.id ? $0 : nil }
    let leadsOut = rowLink?.isAligned == true && rowLink?.meetsRow == true
    return HStack(alignment: isRowSelected && !leadsOut ? .firstTextBaseline : .center, spacing: 0) {
      Button {
        if item.task.isList { model.openItemList(item.task) } else { model.toggleTask(item.task) }
      } label: {
        WorkspaceTaskMarker(task: item.task, isSubtask: true)
          .frame(width: step)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        item.task.isList ? "Open \(item.task.title)" : (isOpen ? "Complete \(item.task.title)" : "Reopen \(item.task.title)"))
      .commandHelp(item.task.isList ? .planEnterTask : .taskComplete, note: item.task.isList ? "Open the list" : nil)
      Button(item.task.title) {
        model.selectTask(item.task)
        model.reportKeyboardFocus(.tasks)
      }
      .buttonStyle(.plain)
      .foregroundStyle(isOpen ? theme.ink : theme.muted)
      .strikethrough(!isOpen)
      .multilineTextAlignment(.leading)
      .expandsWhenSelected(isRowSelected)
      .frame(maxWidth: leadsOut ? nil : .infinity, alignment: .leading)
      .help(item.task.title)
      // Trailing, as the card's own fold is.
      if let isFolded {
        WorkspaceFoldButton(isFolded: isFolded, title: item.task.title) { model.toggleFold(of: item.task) }
      }
      if let rowLink {
        if leadsOut {
          WorkspaceBoardLinkLeader(colour: linkColour(rowLink.childID))
        } else {
          Image(systemName: rowLink.pointsForward ? "arrow.right" : "arrow.left")
            .foregroundStyle(theme.dim)
            .help(rowLink.pointsForward ? "Further on, as a card of its own" : "Further back, as a card of its own")
            .accessibilityHidden(true)
        }
      }
    }
    .font(theme.captionFont)
    .padding(.vertical, theme.space.xxs)
    .onGeometryChange(for: CGRect.self) { proxy in
      leadsOut && measuresLinks ? proxy.frame(in: cardSpace) : .zero
    } action: { frame in
      guard frame != .zero else { return }
      model.reportBoardRow(
        card: task.id, row: item.task.id,
        top: Double(frame.minY - spaceAbove), mid: Double(frame.midY - spaceAbove))
    }
    // The same band as a card's selection, across the tree's width, so the
    // arrow keys can be seen stepping through a card's subtasks.
    .background {
      WorkspaceSelectionBackground(
        isSelected: isRowSelected, hasKeyboard: hasKeyboard && isRowSelected, radius: 0)
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

/// The hairline from a row or heading out to its card's edge, where a link
/// leaves for the subtask's own card in a later column: across what is left
/// of the row after the title, then over the card's margin to the rule
/// between the columns.
struct WorkspaceBoardLinkLeader: View {
  @Environment(\.theme) private var theme
  let colour: Color

  var body: some View {
    let margin = WorkspaceBoardMetrics.columnPadding(theme)
    Rectangle()
      .fill(colour)
      .frame(height: theme.hairline)
      .frame(minWidth: theme.space.md, maxWidth: .infinity)
      .overlay(alignment: .trailing) {
        Rectangle()
          .fill(colour)
          .frame(width: margin, height: theme.hairline)
          .offset(x: margin)
      }
      .padding(.leading, theme.space.xs)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
