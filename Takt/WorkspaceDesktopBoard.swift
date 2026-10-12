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
/// separate filled wells with gaps — unless the board has links, when the
/// rule sits in a narrow gutter the lines turn in — so the only figures left
/// are the clamp on a column's width and the lines'. They are layout
/// decisions, not theme tokens: a theme owns spacing and type, not how many
/// cards fit across a window.
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

  /// The corners of the line drawn between a subtask's row and its card in
  /// another column. A layout figure, like the clamps above, rather than the
  /// theme's: a square theme still wants the line to turn smoothly.
  static let linkCornerRadius: CGFloat = 6

  /// How far apart the lines turning in one gutter run.
  static let linkLaneSpacing: Double = 3

  /// The space between two columns, with the rule down its middle: the
  /// rule's own width on a board with no links, edge to edge as ever, and
  /// room for a few lines to turn in, side by side, on one with them.
  static func columnGutter(_ theme: Theme, hasLinks: Bool) -> CGFloat {
    hasLinks ? max(theme.space.md, theme.hairline) : theme.hairline
  }

  /// Five default columns should be visible together at useful desktop
  /// widths. Fewer or custom columns expand instead of leaving an oversized
  /// empty canvas; very narrow windows still scroll.
  static func columnWidth(available width: CGFloat, columns: Int, gutter: CGFloat, theme: Theme) -> CGFloat {
    let count = CGFloat(max(columns, 1))
    let rules = gutter * (count - 1)
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
        let gutter = WorkspaceBoardMetrics.columnGutter(theme, hasLinks: !model.boardLinks.byChild.isEmpty)
        let columnWidth = WorkspaceBoardMetrics.columnWidth(
          available: geometry.size.width, columns: model.boardColumns.count, gutter: gutter, theme: theme)
        VStack(spacing: 0) {
          // The board said nowhere on its face which list it was showing, so
          // ⌘2 from the outline took the scope name off the screen.
          WorkspacePaneHeader(title: model.currentBoardScopeTitle, switchesList: true) {
          } trailing: {
            WorkspacePaneCount(count: model.boardColumns.reduce(0) { $0 + model.tasks(in: $1).count })
          }
          WorkspaceKanbanColumnStrip(columnWidth: columnWidth, gutter: gutter)
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
  /// The space between two columns, the rule down its middle.
  let gutter: CGFloat
  @State private var visibleColumnIDs: Set<String> = []
  /// Where the link ends are, for the lines drawn between them.
  @State private var linkGeometry = WorkspaceBoardLinkGeometry()

  var body: some View {
    let activeColumnID = model.activeBoardColumnID
    let tasksHaveKeyboard = model.keyboardFocusArea == .tasks && !model.isDraftingTask
    let selectedID = model.selectedTaskID
    // The column the selection is drawn in — for a subtask row, the column
    // of the card it is drawn on.
    let selectedColumnID = selectedID == nil ? nil : activeColumnID
    // The links lit at both ends, their lines in the accent: the
    // selection's, and those of the end under the pointer. Each column is
    // handed only those with an end in it.
    let links = model.boardLinks
    let litLinks = links.isEmpty
      ? Set<String>()
      : links.linkIDs(touching: selectedID).union(links.linkIDs(touching: model.hoveredBoardLinkID))
    let columnIDs = model.boardColumns.map(\.id)
    let allLinks = links.byChild.values.sorted { $0.childID < $1.childID }
    ScrollViewReader { scrollProxy in
      GeometryReader { viewport in
        ScrollView(.horizontal) {
          // Edge to edge, a hairline between each pair: columns are regions
          // of one surface, not cards laid on it. With links, the hairline
          // sits in a gutter the lines turn in.
          LazyHStack(alignment: .top, spacing: 0) {
            ForEach(Array(model.boardColumns.enumerated()), id: \.element.id) { index, column in
              let columnLinks = litLinks.isEmpty ? Set<String>() : links.linkIDs(litLinks, inColumn: index)
              WorkspaceKanbanColumnView(
                column: column,
                width: columnWidth,
                height: viewport.size.height,
                hasKeyboard: tasksHaveKeyboard && activeColumnID == column.id,
                tasksHaveKeyboard: tasksHaveKeyboard,
                selectedRowID: column.id == selectedColumnID ? selectedID : nil,
                litLinks: columnLinks)
                .environment(model)
                // A link's line turns on the rule beside its source column,
                // so the column measures where its edges are.
                .onGeometryChange(for: CGRect.self) { proxy in
                  proxy.frame(in: .named(WorkspaceBoardLinkGeometry.boardSpace))
                } action: { [linkGeometry] frame in
                  linkGeometry.setColumn(column.id, frame: frame)
                }
                // The hairline is drawn on the column rather than beside it.
                // As a sibling it was a scroll target answering to the same
                // id, so a column scrolled almost out to the left still
                // counted as visible by its right-hand rule, and ← to it
                // never scrolled back.
                .padding(.trailing, column.id == model.boardColumns.last?.id ? 0 : gutter)
                .overlay(alignment: .trailing) {
                  if column.id != model.boardColumns.last?.id {
                    Rectangle()
                      .fill(theme.border)
                      .frame(width: theme.hairline, height: viewport.size.height)
                      .padding(.trailing, (gutter - theme.hairline) / 2)
                  }
                }
                .id(column.id)
            }
          }
          .scrollTargetLayout()
          // The space the ends are placed in: the columns' content, inside
          // the scroller, so it moves with them.
          .coordinateSpace(.named(WorkspaceBoardLinkGeometry.boardSpace))
          .environment(linkGeometry)
          // Inside the scroller, so the lines move with the cards they join:
          // beneath the columns for the resting lines that cross one, over
          // them for the rest. A background or an overlay takes the strip's
          // size and adds none, so drawing a line never moves a card. Always
          // there, so a line that goes out fades rather than vanishing with
          // its layer.
          .background {
            WorkspaceBoardLinkLines(
              layer: .beneath, geometry: linkGeometry, links: allLinks, lit: litLinks, columnIDs: columnIDs,
              gutter: gutter)
          }
          .overlay {
            WorkspaceBoardLinkLines(
              layer: .above, geometry: linkGeometry, links: allLinks, lit: litLinks, columnIDs: columnIDs,
              gutter: gutter)
          }
          .onChange(of: links, initial: true) { _, links in linkGeometry.retain(links) }
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
  @Environment(WorkspaceBoardLinkGeometry.self) private var linkGeometry: WorkspaceBoardLinkGeometry?

  /// The draft row, drawn as a card.
  private var draftRow: some View {
    WorkspaceTaskDraftRow(isCard: true)
  }
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
  /// The lit links with an end in this column, by subtask id.
  let litLinks: Set<String>
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
    let blockedStart = model.blockedSectionStart(inCards: tasks)
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
          .help(column.rules.map { "\(column.title) — \($0.summary)" } ?? column.title)
        if column.isRuleColumn {
          // A rule column holds what its rules match, not what is filed in it.
          Image(systemName: "line.3.horizontal.decrease")
            .font(theme.monoCaptionFont)
            .foregroundStyle(theme.dim)
            .accessibilityLabel("Rule column")
        }
        Text("\(tasks.count)")
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
          .monospacedDigit()
        Spacer()
      }
      .contentShape(Rectangle())
      .contextMenu { WorkspaceBoardColumnMenu(column: column).environment(model) }

      }
      .padding([.horizontal, .top], WorkspaceBoardMetrics.columnPadding(theme))

      ScrollViewReader { cardProxy in
        ScrollView(.vertical) {
          // Cards overlap by a hairline, so two neighbours share one rule the
          // way rows of a table do, rather than drawing a double line with a
          // gap between.
          LazyVStack(alignment: .leading, spacing: -theme.hairline) {
            ForEach(tasks) { task in
              if !model.boardDraftIsSubtaskRow, model.draftsBeside(task.id, above: true) { draftRow }
              // The label over the column's blocked cards rides with the
              // first of them, so the card's gap and id carry both.
              VStack(alignment: .leading, spacing: 0) {
                if task.id == blockedStart { blockedDivider }
                WorkspaceKanbanCard(
                  task: task, column: column,
                  selectedRowID: task.id == selectedCardID ? selectedRowID : nil,
                  hasKeyboard: tasksHaveKeyboard && task.id == selectedCardID,
                  litLinkIDs: litLinks(of: task.id))
                  .environment(model)
              }
                .id(task.id)
              if !model.boardDraftIsSubtaskRow, model.draftsBeside(task.id, above: false) { draftRow }
            }
            // A new card with no task to sit beside lands at the foot of the
            // column you are in, so that is where it is typed.
            if model.draftsAtEnd(ofColumn: column.id) { draftRow }
          }
          .scrollTargetLayout()
          // The space a link's ends measure themselves in, so scrolling the
          // column moves only the stack's origin.
          .coordinateSpace(.named(WorkspaceBoardLinkGeometry.StackSpace(columnID: column.id)))
          .onGeometryChange(for: CGPoint.self) { proxy in
            proxy.frame(in: .named(WorkspaceBoardLinkGeometry.boardSpace)).origin
          } action: { [linkGeometry, columnID = column.id] origin in
            linkGeometry?.setStack(columnID, origin: origin)
          }
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
        // The band a link's line is clipped to.
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(WorkspaceBoardLinkGeometry.boardSpace))
        } action: { [linkGeometry, columnID = column.id] frame in
          linkGeometry?.setBand(columnID, frame: frame)
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
    // The column's empty space; a card's own menu is nearer and wins over it.
    .contextMenu { WorkspacePaneContextMenu(surface: .board, column: column).environment(model) }
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

  /// The label over the column's blocked cards, which sink to its foot.
  private var blockedDivider: some View {
    WorkspaceBlockedDivider()
      .padding(.horizontal, WorkspaceBoardMetrics.columnPadding(theme))
      .padding(.top, theme.space.sm)
      .padding(.bottom, theme.space.xs)
  }

  /// The lit links a card is an end of: its own, as a subtask card, and
  /// those of the subtasks further on that hang from it.
  private func litLinks(of cardID: String) -> Set<String> {
    guard !litLinks.isEmpty else { return [] }
    return litLinks.filter { $0 == cardID || model.boardLinks.link(forChild: $0)?.sourceCardID == cardID }
  }
}

struct WorkspaceKanbanCard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Environment(WorkspaceBoardLinkGeometry.self) private var linkGeometry: WorkspaceBoardLinkGeometry?
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
  /// The links lit at this card's end — selected or under the pointer — by
  /// subtask id.
  var litLinkIDs: Set<String> = []

  private var isSelected: Bool { selectedRowID == task.id }
  private var isTreeCollapsed: Bool { model.isFolded(task) }

  /// This card as the subtask end of a link, when it is one.
  private var link: BoardLinks.Link? { model.boardLinks.link(forChild: task.id) }

  /// Whether the card is an end of any link — a subtask's card, or one that
  /// subtasks further on hang from — and so lights and draws them while
  /// the pointer is on it.
  private var isLinkEnd: Bool { !model.boardLinks.linkIDs(touching: task.id).isEmpty }

  /// The colour a link's words take at this end: the accent while the
  /// selection or the pointer is on either end, dim otherwise.
  private func linkColour(_ childIDs: [String]) -> Color {
    childIDs.contains(where: litLinkIDs.contains) ? theme.primary : theme.dim
  }

  /// The title of a column a link names.
  private func columnTitle(_ index: Int) -> String {
    model.boardColumns.indices.contains(index) ? model.boardColumns[index].title : ""
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
    return VStack(alignment: .leading, spacing: theme.space.xs) {
      cardHeading
        // Where a link's line arrives, as this card is its subtask end.
        .boardLinkEnds(link == nil ? [] : [.target(task.id)], inColumn: column.id, geometry: linkGeometry)
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
      headingBundles
    }
    // Blocked, the whole card steps back — mark, title, badges and the
    // subtasks that wait with it — while its rules and selection keep theirs.
    .opacity(model.isBlocked(task) ? Theme.disabledOpacity : 1)
    .padding(.vertical, theme.space.xs)
    .padding(.horizontal, WorkspaceBoardMetrics.columnPadding(theme))
    .frame(maxWidth: .infinity, alignment: .leading)
    // A bordered row on the page, not a raised card: the column is already the
    // surface, and a second tone inside it was a card on a well. Square, like
    // a table's rows, since the cards now meet edge to edge. Hover is the
    // theme's hover fill; selection draws on top of it, never instead of the
    // border's shape.
    // Opaque, hover or not: a resting link line that crosses this column
    // runs beneath its cards.
    .background {
      ZStack {
        Rectangle().fill(theme.paper)
        if isHovered { Rectangle().fill(theme.hover) }
        WorkspaceSelectionBackground(isSelected: isSelected, hasKeyboard: hasKeyboard && isSelected)
      }
    }
    .onHover { hovering in
      withAnimation(WorkspaceMotion.quick) { isHovered = hovering }
      if isLinkEnd { model.hoverBoardLink(task.id, hovering) }
    }
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
    // slot for a check: space completes it, and only a list has a mark worth
    // the width.
    HStack(alignment: isSelected ? .firstTextBaseline : .center, spacing: theme.space.xs) {
      if task.isList {
        Button {
          model.openItemList(task)
        } label: {
          WorkspaceTaskMarker(task: task)
            .frame(width: theme.space.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .commandHelp(.planEnterTask, note: "Open the list")
      }
      if model.editingTaskTitleID == task.id {
        // Edited in place, as the outline's rows are: Return saves with the
        // add field's tokens read, Esc cancels, clicking away saves.
        WorkspaceTaskTitleField(
          initialTitle: task.title, caret: model.editingTaskTitleCaret,
          onCommit: { model.commitTaskTitleEdit(task, text: $0) },
          onCancel: { model.cancelTaskTitleEdit() })
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Button(task.title) {
          // A click on the card already selected edits its title in place,
          // as the outline's rows do; the first click only selects.
          if isSelected && model.keyboardFocusArea == .tasks {
            model.editSelectedTaskTitle()
          } else {
            model.selectTask(task)
            model.reportKeyboardFocus(.tasks)
          }
        }
        .buttonStyle(.plain)
        .font(theme.bodyFont())
        .foregroundStyle(task.status == .open ? theme.ink : theme.muted)
        .focusable()
        .multilineTextAlignment(.leading)
        .expandsWhenSelected(isSelected, lineLimit: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(task.title)
        .strikethrough(task.status != .open)
      }
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
    }
  }

  /// Whose subtask this card is, on a card filed in another column than its
  /// parent: "← parent", pointing the way to the card that draws it as a
  /// row, which a click selects. "↳ parent" when no card on the board draws
  /// the parent — it is finished and hidden, say — so there is nowhere to go.
  @ViewBuilder private var linkHint: some View {
    if let link, let parent = model.boardParent(of: task) {
      Button {
        model.selectBoardLinkSource(of: task.id)
      } label: {
        WorkspaceBoardLinkLabel(
          arrow: link.pointsForward ? "←" : "→", text: parent.title, colour: linkColour([task.id]))
      }
      .buttonStyle(.plain)
      .help("A subtask of \(parent.title), drawn on its card in \(columnTitle(link.sourceColumn))")
    } else if model.boardLinks.isStray(task.id), let parent = model.boardParent(of: task) {
      WorkspaceBoardLinkLabel(arrow: "↳", text: parent.title, colour: theme.dim)
        .help("A subtask of \(parent.title)")
    }
  }

  /// The subtasks in other columns whose rows this card is not drawing —
  /// it is folded, or they are past its row limit — said once per column:
  /// "→ This week 3". A click selects the first of them.
  @ViewBuilder private var headingBundles: some View {
    if let bundles = model.boardLinks.headingBundles[task.id] {
      HStack(spacing: theme.space.sm) {
        ForEach(bundles) { bundle in
          let title = columnTitle(bundle.column)
          Button {
            if let first = bundle.childIDs.first { model.selectBoardLinkedCard(first) }
          } label: {
            WorkspaceBoardLinkLabel(
              arrow: bundle.pointsForward ? "→" : "←",
              text: bundle.childIDs.count > 1 ? "\(title) \(bundle.childIDs.count)" : title,
              colour: linkColour(bundle.childIDs))
          }
          .buttonStyle(.plain)
          // The label stands for every subtask it counts, so each of their
          // lines leaves from it.
          .boardLinkEnds(bundle.childIDs.map { .source($0) }, inColumn: column.id, geometry: linkGeometry)
          .help("\(bundle.childIDs.count) subtask\(bundle.childIDs.count == 1 ? "" : "s") filed in \(title)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
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
      VStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { item in
          // A sibling being added beside a subtask row is drawn here, on the
          // card it will be drawn on, not as a card below it.
          if draftsRow(beside: item.id, above: true) { WorkspaceTaskDraftRow(isSubtaskRow: true) }
          subtaskRow(item, isFolded: parents.contains(item.id) ? model.foldedTaskIDs.contains(item.id) : nil)
          if draftsRow(beside: item.id, above: false) { WorkspaceTaskDraftRow(isSubtaskRow: true) }
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

  /// Whether the board's draft is a subtask row beside `rowID` on this card,
  /// in the column the keys are in.
  private func draftsRow(beside rowID: String, above: Bool) -> Bool {
    column.id == model.activeBoardColumnID && model.boardDraftIsSubtaskRow
      && model.draftsBeside(rowID, above: above)
  }

  private func subtaskRow(_ item: TaskOutlineItem, isFolded: Bool?) -> some View {
    let isOpen = item.task.status == .open
    let step = Self.markWidth(theme)
    let isRowSelected = selectedRowID == item.task.id
    // A subtask filed in another column keeps its row here, its title muted
    // since its card is elsewhere, and names that column at its end.
    let rowLink = model.boardLinks.rowLink(item.task.id, onCard: task.id)
    return HStack(alignment: isRowSelected ? .firstTextBaseline : .center, spacing: 0) {
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
      if model.editingTaskTitleID == item.task.id {
        WorkspaceTaskTitleField(
          initialTitle: item.task.title, caret: model.editingTaskTitleCaret, font: theme.captionFont,
          onCommit: { model.commitTaskTitleEdit(item.task, text: $0) },
          onCancel: { model.cancelTaskTitleEdit() })
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Button(item.task.title) {
          if isRowSelected && model.keyboardFocusArea == .tasks {
            model.editSelectedTaskTitle()
          } else {
            // The subtask is a card in another column too; this column keeps
            // the selection, so it lands on the row clicked.
            if rowLink != nil { model.focusedBoardColumnID = column.id }
            model.selectTask(item.task)
            model.reportKeyboardFocus(.tasks)
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOpen && rowLink == nil ? theme.ink : theme.muted)
        .strikethrough(!isOpen)
        .multilineTextAlignment(.leading)
        .expandsWhenSelected(isRowSelected)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(item.task.title)
      }
      // Trailing, as the card's own fold is.
      if let isFolded {
        WorkspaceFoldButton(isFolded: isFolded, title: item.task.title) { model.toggleFold(of: item.task) }
      }
      if let rowLink {
        let title = columnTitle(rowLink.childColumn)
        Button {
          model.selectBoardLinkedCard(rowLink.childID)
        } label: {
          WorkspaceBoardLinkLabel(
            arrow: rowLink.pointsForward ? "→" : "←", text: title, colour: linkColour([rowLink.childID]))
            .frame(maxWidth: WorkspaceBoardMetrics.minColumnWidth / 2, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .padding(.leading, theme.space.xs)
        .help("A card of its own in \(title)")
      }
    }
    // A blocked subtask on a card that is not: the row steps back as a
    // blocked card does. On a blocked card it already has.
    .opacity(model.isBlocked(item.task) && !model.isBlocked(task) ? Theme.disabledOpacity : 1)
    .font(theme.captionFont)
    .padding(.vertical, theme.space.xxs)
    // Where a link's line leaves for the subtask's own card: the row's
    // trailing end, where it names the column.
    .boardLinkEnds(rowLink.map { [.source($0.childID)] } ?? [], inColumn: column.id, geometry: linkGeometry)
    // The pointer on either end lights both and draws the line. Off the
    // row and still on the card, the card's own links take over again.
    .onHover { hovering in
      if let rowLink {
        model.hoverBoardLink(rowLink.childID, hovering, fallback: isHovered && isLinkEnd ? task.id : nil)
      }
    }
    // The same band as a card's selection, across the tree's width, so the
    // arrow keys can be seen stepping through a card's subtasks.
    .background {
      // Edge to edge across the card, as a selected card's band is: inset by
      // the card's margin it read as a box inside the card.
      WorkspaceSelectionBackground(isSelected: isRowSelected, hasKeyboard: hasKeyboard && isRowSelected, radius: 0)
        .padding(.horizontal, -WorkspaceBoardMetrics.columnPadding(theme))
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

/// One end of a board link naming the other: "→ This week" at the end of a
/// subtask's row, "← Adam's Campus Toolbox" on the subtask's own card. Dim at
/// rest, the accent while the selection or the pointer is on either end.
struct WorkspaceBoardLinkLabel: View {
  @Environment(\.theme) private var theme
  let arrow: String
  let text: String
  let colour: Color

  var body: some View {
    HStack(spacing: theme.space.xxs) {
      Text(arrow).accessibilityHidden(true)
      Text(text).lineLimit(1).truncationMode(.tail)
    }
    .font(theme.captionFont)
    .foregroundStyle(colour)
    .contentShape(Rectangle())
  }
}

/// The `└` a subtask's row hangs from: down from the row's top to its
/// middle, then across to the box's edge.
struct WorkspaceBoardLinkElbow: View {
  @Environment(\.theme) private var theme
  let colour: Color

  var body: some View {
    GeometryReader { proxy in
      let hairline = theme.hairline
      let x = (proxy.size.width - hairline) / 2
      let y = (proxy.size.height - hairline) / 2
      ZStack(alignment: .topLeading) {
        Rectangle().fill(colour)
          .frame(width: hairline, height: y + hairline)
          .offset(x: x)
        Rectangle().fill(colour)
          .frame(width: proxy.size.width - x, height: hairline)
          .offset(x: x, y: y)
      }
    }
    .accessibilityHidden(true)
  }
}
