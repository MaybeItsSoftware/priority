import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// The left-hand column: lists and folders.
///
/// Its own view rather than a computed property of the window, so moving the
/// sidebar's cursor redraws the sidebar and nothing else, and a keystroke in
/// the task pane does not redraw it at all.
struct WorkspaceSidebarPane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  var focusedArea: FocusState<WorkspaceFocusArea?>.Binding
  private let everythingSidebarID = "priority:everything"
  private let todaySidebarID = "priority:today"
  @State private var isTopLevelDropTargeted = false
  @State private var isBottomDropTargeted = false

  var body: some View {
    // No header of its own: the left dock's tab bar is drawn over it, and
    // carries the pane's actions (`WorkspaceSidebarActions`) on its right.
    VStack(alignment: .leading, spacing: 0) {
      sidebarRows
    }
    // The page, like the panes beside it. Not `.bar`: a vibrant material
    // re-tints whatever is behind the window, so the selection wash was being
    // averaged into the desktop and arriving as nothing. And not `altRow`
    // either, which made the sidebar a second surface — the resize handle's
    // hairline is what separates it, the way a dock is separated in an editor.
    .background(theme.paper)
  }

  private var sidebarRows: some View {
    ScrollViewReader { sidebarProxy in
      // A plain scroll of rows rather than a `.sidebar` List. The source-list
      // style insets every row from the column's edges and rounds its ends,
      // and neither can be fully turned off from SwiftUI — so a selection
      // could never run the width of the pane, and the tree sat in a column
      // narrower than the header above it. Laid out here, a row is exactly as
      // tall and as wide as its padding says, which is also what lets the
      // indent guides of one row meet the next.
      ScrollView {
        // Drawn from `model.sidebarRows` — the outline the arrow keys walk —
        // as one flat run of rows, each keyed by its outline id.
        //
        // It used to be a tree of views: the folders' lists in a `ForEach`
        // inside each folder, the loose lists in another, every row tagged
        // `.id(list.id)`. A lazy stack keys its cells by those explicit ids,
        // so a list moved into a folder kept the cell it had at the top level
        // — same id — and was drawn with the old cell's indent: in its new
        // place, one level out, with the next list looking nested under it.
        // A flat run has one place for a row to be, and drawing the outline
        // itself means the order on screen is the order the keys walk.
        LazyVStack(alignment: .leading, spacing: 0) {
          let lookup = WorkspaceSidebarLookup(model: model)
          ForEach(sidebarLines(lookup: lookup)) { line in
            sidebarLine(line, lookup: lookup)
              .id(line.id)
          }
          topLevelDropZone
        }
        .padding(.bottom, theme.space.sm)
      }
      .scrollContentBackground(.hidden)
      .font(theme.bodyFont())
      .foregroundStyle(theme.ink)
      // One number standing for where every list, folder and nested list
      // sits, worked out when they are reloaded rather than as three arrays of
      // strings on every render.
      .animation(.easeInOut(duration: 0.22), value: model.sidebarLayoutKey)
      .focusable()
      .focused(focusedArea, equals: .sidebar)
      .focusEffectDisabled()
      .onChange(of: model.focusRequest) { _, _ in
        if model.requestedFocusArea == .sidebar {
          sidebarProxy.scrollTo(model.sidebarCursorScrollID)
        }
      }
      // Arrowing past the bottom of the visible rows used to walk the cursor
      // off screen, because only a focus request scrolled.
      .onChange(of: model.sidebarCursorID) { _, _ in
        guard let id = model.sidebarCursorScrollID else { return }
        withAnimation(.easeInOut(duration: 0.12)) { sidebarProxy.scrollTo(id) }
      }
    }
  }

  /// The space under the tree, as a drop target for "top level, at the end".
  ///
  /// The "Lists" caption was the only other way out of a folder, and it is a
  /// strip one caption tall at the far end of a drag. On the way to it the
  /// pointer crosses list rows whose middles nest what is dropped on them, so
  /// taking a list out of a folder tended to put it inside another list.
  /// This is a big, empty target at the end you are already heading for.
  private var topLevelDropZone: some View {
    Text(isBottomDropTargeted ? "Drop here to make it top level" : "")
      .font(theme.captionFont)
      .foregroundStyle(theme.primary)
      .frame(maxWidth: .infinity, minHeight: 96)
      .contentShape(Rectangle())
      .background(
        isBottomDropTargeted ? theme.selectionFill : .clear,
        in: RoundedRectangle(cornerRadius: theme.rowRadius))
      .padding(.horizontal, theme.listGutter)
      .accessibilityHidden(true)
      .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isBottomDropTargeted) { providers in
        WorkspaceTaskDrag.readItemID(from: providers) { payload in
          // A task dropped here is a task made into a top-level list, which
          // is what the caption does with one too.
          model.moveDroppedItem(payload, toFolderID: nil)
        }
      }
  }

  /// The gap between the stock lists and yours, which is also where a list is
  /// dropped to make it top level. It used to be captioned "Lists", over a
  /// group of rows that were plainly lists already; a gap says the same.
  private var listsHeader: some View {
    HStack {
      Spacer()
      // The affordance only means anything while something is in the air,
      // so it only appears then. A permanent ↖ beside a section title is
      // a control as far as anyone can tell, and it is not one.
      if isTopLevelDropTargeted {
        Image(systemName: "arrow.up.left")
          .font(theme.microLabelFont)
          .foregroundStyle(theme.primary)
      }
    }
    .frame(height: theme.space.md)
    .padding(.horizontal, theme.listGutter)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(
      isTopLevelDropTargeted ? theme.selectionFill : .clear,
      in: RoundedRectangle(cornerRadius: theme.rowRadius))
    .help("Drop a list here to make it a top level list")
    .accessibilityLabel("Drop here to move to top level")
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isTopLevelDropTargeted) { providers in
      WorkspaceTaskDrag.readItemID(from: providers) { payload in
        model.moveDroppedItem(payload, toFolderID: nil)
      }
    }
  }

  /// The outline's rows, with the gap that separates the stock rows from
  /// yours, in drawing order.
  private func sidebarLines(lookup: WorkspaceSidebarLookup) -> [WorkspaceSidebarLine] {
    let rows = model.sidebarRows
    let inboxID = lookup.inboxID
    // Today, Everything, the inbox with its nested lists and the filter
    // lists are the stock rows; the gap goes after the last of them.
    let isStock: (WorkspaceSidebarRow) -> Bool = { row in
      switch row.kind {
      case .today, .everything, .filterList: return true
      case .list(let id): return id == inboxID
      case .nestedList: return inboxID.map { row.id.hasPrefix("nested:\($0):") } ?? false
      case .folder: return false
      }
    }
    let split = rows.lastIndex(where: isStock).map { $0 + 1 } ?? 0
    var lines = rows.map(WorkspaceSidebarLine.row)
    lines.insert(.gap, at: split)
    return lines
  }

  @ViewBuilder
  private func sidebarLine(_ line: WorkspaceSidebarLine, lookup: WorkspaceSidebarLookup) -> some View {
    switch line {
    case .gap:
      listsHeader
    case .row(let row):
      switch row.kind {
      case .today: todayRow
      case .everything: everythingRow
      case .filterList(let id):
        if let filter = lookup.filterLists[id] { WorkspaceFilterListRow(filter: filter) }
      case .list(let id):
        if let list = lookup.lists[id] {
          WorkspaceSidebarListRow(list: list, depth: row.depth, isLastInGroup: lookup.lastInGroup.contains(id))
        }
      case .folder(let id):
        if let folder = lookup.folders[id] {
          WorkspaceFolderRow(folder: folder, depth: row.depth, isLastInGroup: lookup.lastInGroup.contains(id))
        }
      case .nestedList(let id):
        if let task = lookup.nestedLists[id] {
          let pinned = row.id.hasPrefix("pinned:")
          WorkspaceNestedListRow(task: task, depth: pinned ? 0 : row.depth, rowID: row.id, promotedShortcut: pinned)
        }
      }
    }
  }

  private var todayRow: some View {
    Button {
      model.selectToday()
      model.reportKeyboardFocus(.sidebar)
    } label: {
      HStack(spacing: theme.space.sm) {
        Image(systemName: "sun.max")
          .foregroundStyle(theme.muted)
          .frame(width: WorkspaceSidebarMetrics.iconWidth)
        Text("Today")
      }
      .sidebarRowPadding(theme)
    }
    .buttonStyle(.plain)
    .background(
      WorkspaceSidebarSelectionBackground(
        isCurrent: model.isCurrentSidebarRow(todaySidebarID),
        rowID: "row:today"))
    .accessibilityLabel("Today, across all lists")
    .commandHelp(.goToday, note: "Today, across all lists")
  }

  private var everythingRow: some View {
    Button {
      model.selectEverything()
      model.reportKeyboardFocus(.sidebar)
    } label: {
      HStack(spacing: theme.space.sm) {
        Image(systemName: "square.stack.3d.up")
          .foregroundStyle(theme.muted)
          .frame(width: WorkspaceSidebarMetrics.iconWidth)
        Text("Everything")
      }
      .sidebarRowPadding(theme)
    }
    .buttonStyle(.plain)
    .background(
      WorkspaceSidebarSelectionBackground(
        isCurrent: model.isCurrentSidebarRow(everythingSidebarID),
        rowID: "row:everything"))
    .accessibilityLabel("Everything, all lists")
    .commandHelp(.goEverything, note: "Everything, all lists")
    .contextMenu {
      Button("New Filter List…") { model.requestNewFilterList() }
    }
  }
}

/// One line of the sidebar: an outline row, or the gap under the stock rows.
enum WorkspaceSidebarLine: Identifiable {
  case row(WorkspaceSidebarRow)
  case gap

  var id: String {
    switch self {
    case .row(let row): row.id
    case .gap: "line:gap"
    }
  }
}

/// What the rows name, by id, worked out once per drawing rather than a
/// linear search per row.
@MainActor
struct WorkspaceSidebarLookup {
  let inboxID: String?
  let lists: [String: TaskList]
  let folders: [String: ListFolder]
  let nestedLists: [String: WorkspaceTask]
  let filterLists: [String: WorkspaceFilterList]
  /// The lists and folders that are the last of their siblings, whose bottom
  /// edge is "at the end of the group" for a drop.
  let lastInGroup: Set<String>

  init(model: WorkspaceViewModel) {
    inboxID = model.inboxList?.id
    lists = Dictionary(model.lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    folders = Dictionary(model.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    nestedLists = Dictionary(model.nestedLists.map { ($0.task.id, $0.task) }, uniquingKeysWith: { first, _ in first })
    filterLists = Dictionary(model.filterLists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var last: [String: String] = [:]
    for list in model.lists where list.systemRole != .inbox { last["list:\(list.folderId ?? "")"] = list.id }
    for folder in model.folders { last["folder:\(folder.parentFolderId ?? "")"] = folder.id }
    lastInGroup = Set(last.values)
  }
}

/// Which list you are on, and whether the sidebar is the thing listening.
///
/// These are two facts, and the row used to spend one cue on both: a wash of
/// accent at 17%, with a border added only while the sidebar had the keyboard.
/// Over the sidebar's own material that wash is nearly nothing, so the common
/// case — the sidebar not focused, which is most of the time — left the
/// current list marked by a tint you had to look for.
///
/// Now the border always draws, so *where you are* is never in doubt, and
/// focus is the difference between a hairline and a ring. That is the house
/// rule anyway: separation comes from borders, and selection is a border
/// change rather than a heavier fill.
/// Two facts about a sidebar row, drawn as two different things.
///
/// `isCurrent` is which list is open — it persists, and it is what you are
/// looking at in the main pane. `isCursor` is where the arrow keys are, which
/// is usually the same row and deliberately is not always: standing on Focus
/// or the timeline must not close the list you were reading. Conflating them
/// meant those two rows could never be highlighted at all, because neither is
/// a list to be current.
///
/// The fill says "open", the ring says "here". A ring needs the keyboard to
/// mean anything, so it only draws while the sidebar has it.
/// Applied with `.background` outside the row's padding, so it spans the
/// column edge to edge — the sidebar's rows are laid out on a plain stack
/// now, with nothing between them and the pane's sides.
struct WorkspaceSidebarSelectionBackground: View {
  @Environment(WorkspaceViewModel.self) private var model
  var isCurrent = false
  var rowID: String?

  /// The sidebar is the one place where "selected" and "under the keyboard"
  /// routinely name different rows, so the cursor is looked up per row rather
  /// than inherited from the region.
  private var isCursor: Bool {
    model.keyboardFocusArea == .sidebar && rowID.map(model.isSidebarCursorRow) == true
  }

  var body: some View {
    WorkspaceSelectionBackground(isSelected: isCurrent, hasKeyboard: isCursor)
  }
}

/// The sidebar's row geometry, named once so that every kind of row —
/// Everything, a list, a nested list, a folder — is the same height and starts
/// its name at the same x. They were 2, 3 and 6pt of padding, a 14pt and an
/// 18pt icon column, and indents of 12 and 14, one per row kind.
enum WorkspaceSidebarMetrics {
  /// The icon column. Wide enough for the widest symbol the rows draw at body
  /// size, so names line up whichever glyph precedes them.
  static let iconWidth: CGFloat = WorkspaceRowMetrics.iconWidth

  /// One indent step for anything nested — a list in a folder, a list inside
  /// a list. The same step as the outline's.
  static func indent(_ theme: Theme) -> CGFloat { WorkspaceRowMetrics.indent(theme) }

  /// Where the outermost indent guide falls: down the middle of a top-level
  /// row's icon column, so each guide hangs from its parent's glyph.
  static func guideOrigin(_ theme: Theme) -> CGFloat { theme.listGutter + iconWidth / 2 }
}

extension View {
  /// The padding every sidebar row carries inside its selection background,
  /// and its face. Everything that places a row — the gutter, the indent for
  /// its depth, the guides for its ancestors — is laid *inside* the row, so
  /// the selection behind it runs the full width of the column whatever the
  /// depth, as it does in an editor's project panel.
  func sidebarRowPadding(_ theme: Theme, depth: Int = 0) -> some View {
    font(theme.bodyFont())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, CGFloat(depth) * WorkspaceSidebarMetrics.indent(theme))
      .padding(.vertical, theme.rowVerticalPadding)
      .padding(.horizontal, theme.listGutter)
      .workspaceIndentGuides(
        depth: depth,
        origin: WorkspaceSidebarMetrics.guideOrigin(theme),
        step: WorkspaceSidebarMetrics.indent(theme))
      .contentShape(Rectangle())
  }
}

/// A filter list in the sidebar: its icon and name, selected like a list,
/// with its sheet, icon, order and deletion on the context menu.
struct WorkspaceFilterListRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let filter: WorkspaceFilterList

  private var sidebarID: String { WorkspaceViewModel.filterListSidebarID(filter.id) }

  var body: some View {
    Button {
      model.selectFilterList(filter)
      model.reportKeyboardFocus(.sidebar)
    } label: {
      HStack(spacing: theme.space.sm) {
        Image(systemName: filter.icon ?? WorkspaceFilterList.defaultIcon)
          .foregroundStyle(theme.muted)
          .frame(width: WorkspaceSidebarMetrics.iconWidth)
        Text(filter.name)
          .lineLimit(1)
      }
      .sidebarRowPadding(theme)
    }
    .buttonStyle(.plain)
    .background(
      WorkspaceSidebarSelectionBackground(
        isCurrent: model.isCurrentSidebarRow(sidebarID),
        rowID: sidebarID))
    .accessibilityLabel("\(filter.name), filter list")
    .help(filter.definition.summary)
    .contextMenu {
      Button("Edit Filter List…") { model.requestEditFilterList(filter) }
      Menu("Icon") {
        ForEach(WorkspaceFilterList.iconOptions, id: \.symbol) { icon in
          Button {
            model.setIcon(icon.symbol, for: filter)
          } label: {
            Label(icon.label, systemImage: icon.symbol)
          }
        }
      }
      Divider()
      if let index = model.filterLists.firstIndex(of: filter) {
        Button("Move Up") { model.moveFilterList(filter, to: index - 1) }
          .disabled(index == 0)
        Button("Move Down") { model.moveFilterList(filter, to: index + 1) }
          .disabled(index + 1 >= model.filterLists.count)
      }
      Divider()
      Button("New Filter List…") { model.requestNewFilterList() }
      Button("Delete Filter List", role: .destructive) { model.deleteFilterList(filter) }
    }
  }
}
