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
        LazyVStack(alignment: .leading, spacing: 0) {
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
          .id(todaySidebarID)
          .background(
            WorkspaceSidebarSelectionBackground(
              isCurrent: model.isCurrentSidebarRow(todaySidebarID),
              rowID: "row:today"))
          .accessibilityLabel("Today, across all lists")
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
          .id(everythingSidebarID)
          .background(
            WorkspaceSidebarSelectionBackground(
              isCurrent: model.isCurrentSidebarRow(everythingSidebarID),
              rowID: "row:everything"))
          .accessibilityLabel("Everything, all lists")
          if let inbox = model.inboxList {
            sidebarListRow(inbox)
            WorkspaceNestedListRows(list: inbox, depth: 1)
          }
          listsHeader
          ForEach(model.promotedLists) { task in
            WorkspaceNestedListRow(task: task, depth: 0, promotedShortcut: true)
          }
          let rootFolders = model.folders.filter { $0.parentFolderId == nil }
          ForEach(rootFolders) { folder in
            WorkspaceFolderTree(folder: folder, depth: 0, isLastInGroup: folder.id == rootFolders.last?.id)
          }
          let rootLists = model.lists.filter { $0.folderId == nil && $0.systemRole != .inbox }
          ForEach(rootLists) { list in
            sidebarListRow(list, isLastInGroup: list.id == rootLists.last?.id)
            WorkspaceNestedListRows(list: list, depth: 1)
          }
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

  /// The "Lists" caption over the tree, which is also where a list is dropped
  /// to make it top level. A row of its own rather than a List section header
  /// now, on the rows' gutter so the caption starts where the names do.
  private var listsHeader: some View {
    HStack {
      MicroLabel("Lists")
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
    .padding(.top, theme.space.sm)
    .padding(.bottom, theme.space.xxs)
    .padding(.horizontal, theme.listGutter)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(
      isTopLevelDropTargeted ? theme.selectionFill : .clear,
      in: RoundedRectangle(cornerRadius: theme.rowRadius))
    .help("Drop a list here to make it a top level list")
    .accessibilityLabel("Lists, drop here to move to top level")
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isTopLevelDropTargeted) { providers in
      WorkspaceTaskDrag.readItemID(from: providers) { payload in
        model.moveDroppedItem(payload, toFolderID: nil)
      }
    }
  }

  private func sidebarListRow(_ list: TaskList, isLastInGroup: Bool = false) -> some View {
    WorkspaceSelectableListRow(list: list, depth: 0)
      .id(list.id)
      .onDrag { WorkspaceTaskDrag.provider(forList: list.id) }
      .background(
        WorkspaceSidebarSelectionBackground(
          isCurrent: model.isCurrentSidebarRow(list.id),
          rowID: "list:\(list.id)"))
      .workspaceSidebarDrop(isLastInGroup: isLastInGroup) { payload, placement in
        switch placement {
        case .into: model.moveDroppedItem(payload, toListID: list.id)
        case .before: model.placeDroppedItem(payload, before: list.id, inFolderID: list.folderId)
        case .after: model.placeDroppedItem(payload, before: nil, inFolderID: list.folderId)
        }
      }
      .contextMenu {
        Menu("Choose icon") {
          ForEach(WorkspaceViewModel.availableListIcons, id: \.symbol) { icon in
            Button { model.setIcon(icon.symbol, for: list) } label: {
              Label(icon.label, systemImage: icon.symbol)
            }
          }
        }
        Button("Rename") { model.beginRenaming(.list(list)) }
        Button("List settings…") { model.showSettings(for: list) }
        Button("New nested list…") {
          model.selectList(list.id)
          model.requestNestedListCreation()
        }
        // The Inbox can be renamed and refiled, but not taken away: quick
        // capture has to have somewhere to land.
        if !list.isSystemList {
          Divider()
          Button("Convert to task in Inbox") { model.convertListToTask(list) }
          Button(list.completedAt == nil ? "Complete list" : "Reopen list") { model.toggleListCompletion(list) }
          Button("Archive") { model.archiveList(list) }
          Divider()
          Button("Delete list and tasks", role: .destructive) { model.requestDeletion(of: .list(list)) }
        }
      }
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

private struct WorkspaceNestedListRows: View {
  @Environment(WorkspaceViewModel.self) private var model
  let list: TaskList
  /// The depth of the list's own children: one below the list row.
  let depth: Int

  var body: some View {
    ForEach(model.nestedLists.filter { $0.task.listId == list.id }) { item in
      WorkspaceNestedListRow(task: item.task, depth: depth + item.depth)
    }
  }
}

private struct WorkspaceNestedListRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let depth: Int
  var promotedShortcut = false
  @State private var isDropTargeted = false

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: model.itemSymbol(for: task))
        .foregroundStyle(theme.muted)
        .frame(width: WorkspaceSidebarMetrics.iconWidth)
      Text(task.title)
        .lineLimit(1)
        .truncationMode(.middle)
        .strikethrough(task.status != .open)
      Spacer(minLength: 0)
      if promotedShortcut {
        Image(systemName: "pin.fill").font(theme.microLabelFont).foregroundStyle(theme.dim)
      }
    }
    .sidebarRowPadding(theme, depth: depth)
    .onTapGesture { model.selectNestedList(task) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(task.title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.selectNestedList(task) }
    .focusable().focusEffectDisabled()
    .id(promotedShortcut ? "promoted:\(task.id)" : task.id)
    .background(WorkspaceSidebarSelectionBackground(
      isCurrent: model.isCurrentSidebarRow(task.id),
      rowID: promotedShortcut ? "pinned:\(task.id)" : "nested:\(task.listId):\(task.id)"))
    .contextMenu { WorkspaceItemActions(task: task) }
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .background(
      isDropTargeted ? theme.selectionFill : .clear,
      in: RoundedRectangle(cornerRadius: theme.rowRadius))
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
      WorkspaceTaskDrag.readItemID(from: providers) { payload in
        model.moveDroppedItem(payload, toListID: task.listId, parentTaskID: task.id)
      }
    }
  }
}

private struct WorkspaceFolderTree: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let folder: ListFolder
  /// Whether this is the last folder among its siblings, and so the one whose
  /// bottom edge means "at the end of the folders".
  var isLastInGroup = false

  /// The folder header's own depth; its lists and subfolders sit one below.
  /// Passed down rather than applied as padding round the children, because
  /// padding outside a row would indent its selection with it.
  let depth: Int

  init(folder: ListFolder, depth: Int, isLastInGroup: Bool = false) {
    self.folder = folder
    self.depth = depth
    self.isLastInGroup = isLastInGroup
  }

  var body: some View {
    Group {
      folderHeader
      if model.isFolderExpanded(folder) {
      let folderLists = model.lists.filter { $0.folderId == folder.id && $0.systemRole != .inbox }
      ForEach(folderLists) { list in
        WorkspaceSelectableListRow(list: list, depth: depth + 1)
          .id(list.id)
          .onDrag { WorkspaceTaskDrag.provider(forList: list.id) }
          .background(
            WorkspaceSidebarSelectionBackground(
              isCurrent: model.isCurrentSidebarRow(list.id),
              rowID: "list:\(list.id)"))
          .workspaceSidebarDrop(isLastInGroup: list.id == folderLists.last?.id) { payload, placement in
            switch placement {
            case .into: model.moveDroppedItem(payload, toListID: list.id)
            case .before: model.placeDroppedItem(payload, before: list.id, inFolderID: folder.id)
            case .after: model.placeDroppedItem(payload, before: nil, inFolderID: folder.id)
            }
          }
          .contextMenu {
            Button("Rename") { model.beginRenaming(.list(list)) }
            Button("List settings…") { model.showSettings(for: list) }
            Button("New nested list…") {
              model.selectList(list.id)
              model.requestNestedListCreation()
            }
            if !list.isSystemList {
              Divider()
              Button("Convert to task in Inbox") { model.convertListToTask(list) }
              Button(list.completedAt == nil ? "Complete list" : "Reopen list") { model.toggleListCompletion(list) }
              Button("Archive") { model.archiveList(list) }
              Divider()
              Button("Delete list and tasks", role: .destructive) { model.requestDeletion(of: .list(list)) }
            }
          }
        WorkspaceNestedListRows(list: list, depth: depth + 2)
      }
      let childFolders = model.folders.filter { $0.parentFolderId == folder.id }
      ForEach(childFolders) { child in
        WorkspaceFolderTree(folder: child, depth: depth + 1, isLastInGroup: child.id == childFolders.last?.id)
      }
      }
    }
  }

  private var isCurrent: Bool { model.selectedFolderID == folder.id }

  private var folderHeader: some View {
      // The disclosure chevron takes the icon column, and the folder's own
      // glyph and name follow it at the list rows' spacing, so a folder's name
      // starts one indent in from a list's — which is where its lists start.
      HStack(spacing: theme.space.sm) {
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            model.setFolderExpanded(folder, expanded: !model.isFolderExpanded(folder))
          }
        } label: {
          Image(systemName: model.isFolderExpanded(folder) ? "chevron.down" : "chevron.right")
            .font(theme.captionFont)
            .frame(width: WorkspaceSidebarMetrics.iconWidth)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(model.isFolderExpanded(folder) ? "Collapse folder" : "Expand folder")
        Image(systemName: "folder")
          .frame(width: WorkspaceSidebarMetrics.iconWidth)
        if model.isRenaming(.folder(folder)) {
          WorkspaceRenameField(
            initialName: folder.name,
            onCommit: { model.renameFolder(folder, to: $0) },
            onCancel: { model.cancelRenaming(itemID: folder.id) })
        } else {
          Text(folder.name)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(folder.name)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.selectFolder(folder) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectFolder(folder) }
        }
      }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .foregroundStyle(theme.muted)
        .sidebarRowPadding(theme, depth: depth)
        // The same component as every other sidebar row, rather than the same
        // two opacities written out again: a folder that disagreed with a list
        // about what "you are here" looks like is the bug this replaces.
        .background(
          WorkspaceSidebarSelectionBackground(
            isCurrent: isCurrent, rowID: "folder:\(folder.id)"))
        .contentShape(Rectangle())
        .id(folder.id)
        .onDrag { WorkspaceTaskDrag.provider(forFolder: folder.id) }
        .workspaceSidebarDrop(isLastInGroup: isLastInGroup && !model.isFolderExpanded(folder)) { payload, placement in
          switch placement {
          case .into: model.moveDroppedItem(payload, toFolderID: folder.id)
          case .before: model.placeDroppedItem(payload, before: folder.id, inFolderID: folder.parentFolderId)
          case .after: model.placeDroppedItem(payload, before: nil, inFolderID: folder.parentFolderId)
          }
        }
        .contextMenu {
          Button("Rename") { model.beginRenaming(.folder(folder)) }
          Button("Folder settings…") { model.showSettings(for: folder) }
          Button("New list in folder") { model.requestCreation(.list, in: folder.id) }
          Button("New subfolder") { model.requestCreation(.folder, in: folder.id) }
          Divider()
          Button("Delete folder", role: .destructive) { model.requestDeletion(of: .folder(folder)) }
        }
  }
}
