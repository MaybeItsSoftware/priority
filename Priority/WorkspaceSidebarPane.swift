import AppKit
import PriorityCore
import PriorityWorkspace
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
  @State private var isTopLevelDropTargeted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sidebarHeader
      FocusRule()
      sidebarRows
      sidebarFooter
    }
    // The page, like the panes beside it. Not `.bar`: a vibrant material
    // re-tints whatever is behind the window, so the selection wash was being
    // averaged into the desktop and arriving as nothing. And not `altRow`
    // either, which made the sidebar a second surface — the resize handle's
    // hairline is what separates it, the way a dock is separated in an editor.
    .background(theme.paper)
  }

  private var sidebarHeader: some View {
    // The same band as the pane header beside it — the same height and the
    // same rule under it — so the two read as one strip across the window.
    HStack(spacing: theme.space.sm) {
      // The app's own name, which the window title, the Dock icon and the
      // menu bar were already saying. A pane's eyebrow should name the pane.
      MicroLabel("Workspace")
      Spacer()
      Menu {
        Button(model.undoLabel.map { "Undo \($0)" } ?? "Undo") { model.run(.windowUndo) }
          .disabled(model.undoLabel == nil)
          .commandShortcut(.windowUndo)
        Button(model.redoLabel.map { "Redo \($0)" } ?? "Redo") { model.run(.windowRedo) }
          .disabled(model.redoLabel == nil)
          .commandShortcut(.windowRedo)
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .commandHelp(.windowUndo, note: "Undo or redo workspace changes")
      .accessibilityLabel("Workspace history")
    }
    .frame(minHeight: theme.space.xl)
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
  }

  private var sidebarRows: some View {
    ScrollViewReader { sidebarProxy in
      List {
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
        .listRowBackground(Color.clear)
        .tag(Optional(everythingSidebarID))
        .accessibilityLabel("Everything, all lists")
        if let inbox = model.inboxList {
          sidebarListRow(inbox)
          WorkspaceNestedListRows(list: inbox)
        }
        Section {
          ForEach(model.promotedLists) { task in
            WorkspaceNestedListRow(task: task, promotedShortcut: true)
          }
          let rootFolders = model.folders.filter { $0.parentFolderId == nil }
          ForEach(rootFolders) { folder in
            WorkspaceFolderTree(folder: folder, isLastInGroup: folder.id == rootFolders.last?.id)
          }
          let rootLists = model.lists.filter { $0.folderId == nil && $0.systemRole != .inbox }
          ForEach(rootLists) { list in
            sidebarListRow(list, isLastInGroup: list.id == rootLists.last?.id)
            WorkspaceNestedListRows(list: list)
          }
        } header: {
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
          .padding(.vertical, theme.space.xs)
          .padding(.horizontal, theme.space.xs)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .background(
            isTopLevelDropTargeted ? theme.selectionFill : .clear,
            in: RoundedRectangle(cornerRadius: theme.controlRadius))
          .help("Drop a list here to make it a top level list")
          .accessibilityLabel("Lists, drop here to move to top level")
          .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isTopLevelDropTargeted) { providers in
            WorkspaceTaskDrag.readItemID(from: providers) { payload in
              model.moveDroppedItem(payload, toFolderID: nil)
            }
          }
        }
      }
      .listStyle(.sidebar)
      // `.sidebar` is kept for its row metrics and disclosure behaviour, but
      // its own vibrancy is not wanted over the flat surface above.
      .scrollContentBackground(.hidden)
      // Every row in the theme's body face, rather than the system font the
      // `.sidebar` style supplies — the sidebar was the one list in the window
      // whose names did not match the task titles beside it.
      .font(theme.bodyFont())
      .foregroundStyle(theme.ink)
      // A sidebar row is otherwise given the height AppKit reserves for a
      // two-line source-list item, which on a list of one-line names reads as
      // double spacing.
      .environment(\.defaultMinListRowHeight, WorkspaceSidebarMetrics.rowHeight(theme))
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

  private var sidebarFooter: some View {
    VStack(spacing: 0) {
      FocusRule()
      HStack(spacing: theme.space.xs) {
        // Named, not just drawn: two bare glyphs in a bottom bar gave no clue
        // which was which, and neither said it had a key.
        AddWorkspaceItemButton(
          title: "New list", systemImage: "plus", command: .listNew, kind: .list, showsTitle: true)
        AddWorkspaceItemButton(
          title: "New folder", systemImage: "folder.badge.plus", command: .folderNew, kind: .folder)
        Spacer(minLength: 0)
        if !model.archivedLists.isEmpty || !model.archivedNestedLists.isEmpty {
          Menu {
            ForEach(model.archivedLists) { list in
              Button("Restore \(list.name)") { model.restoreList(list) }
            }
            ForEach(model.archivedNestedLists) { task in
              Button("Restore \(task.title)") { model.archiveNestedList(task, archived: false) }
            }
          } label: {
            Image(systemName: "archivebox")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .focusable()
          .commandHelp(.listRestore, note: "Restore archived lists")
        }
      }
      .padding(.horizontal, theme.space.sm)
      .padding(.vertical, theme.space.xs)
    }
  }

  private func sidebarListRow(_ list: TaskList, isLastInGroup: Bool = false) -> some View {
    WorkspaceSelectableListRow(list: list)
      .tag(Optional(list.id))
      .id(list.id)
      .onDrag { WorkspaceTaskDrag.provider(forList: list.id) }
      .background(
        WorkspaceSidebarSelectionBackground(
          isCurrent: model.isCurrentSidebarRow(list.id),
          rowID: "list:\(list.id)"))
      .listRowBackground(Color.clear)
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
/// Internal rather than file-private: the Focus and timeline rows live in
/// `WorkspaceFocusScreen.swift` and are sidebar rows like any other.
/// Always applied with `.background`, never `.listRowBackground`. A `.sidebar`
/// List draws its own row chrome and swallowed the row background whole: the
/// folder header, which had always used a plain background, was the only row in
/// the sidebar that showed a selection at all.
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
  static let iconWidth: CGFloat = 18

  /// One indent step for anything nested — a list in a folder, a list inside
  /// a list. The icon column plus the gap after it, so a child's glyph sits
  /// under its parent's name.
  static func indent(_ theme: Theme) -> CGFloat { iconWidth + theme.space.sm }

  /// A single line of body text plus the row's own padding. Without a floor a
  /// `.sidebar` List gives each row the height AppKit reserves for a two-line
  /// source-list item.
  static func rowHeight(_ theme: Theme) -> CGFloat {
    theme.type.scale.body + 2 * (theme.space.xs + theme.space.xxs)
  }
}

extension View {
  /// The padding every sidebar row carries inside its selection background,
  /// and its face. The font is set here, on the row, rather than trusted to
  /// the `.font` on the List: the `.sidebar` style hands each row its own
  /// system font, which beats one inherited from outside the table.
  func sidebarRowPadding(_ theme: Theme) -> some View {
    font(theme.bodyFont())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, theme.space.xxs)
      .padding(.horizontal, theme.space.xs)
      .contentShape(Rectangle())
  }
}

private struct WorkspaceNestedListRows: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let list: TaskList

  var body: some View {
    ForEach(model.nestedLists.filter { $0.task.listId == list.id }) { item in
      WorkspaceNestedListRow(task: item.task)
        .padding(.leading, CGFloat(item.depth + 1) * WorkspaceSidebarMetrics.indent(theme))
    }
  }
}

private struct WorkspaceNestedListRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
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
    .sidebarRowPadding(theme)
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
    .listRowBackground(Color.clear)
    .contextMenu { WorkspaceItemActions(task: task) }
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .background(
      isDropTargeted ? theme.selectionFill : .clear,
      in: RoundedRectangle(cornerRadius: theme.controlRadius))
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

  var body: some View {
    Group {
      folderHeader
      if model.isFolderExpanded(folder) {
      let folderLists = model.lists.filter { $0.folderId == folder.id && $0.systemRole != .inbox }
      ForEach(folderLists) { list in
        WorkspaceSelectableListRow(list: list)
          .tag(Optional(list.id))
          .id(list.id)
          .onDrag { WorkspaceTaskDrag.provider(forList: list.id) }
          .background(
            WorkspaceSidebarSelectionBackground(
              isCurrent: model.isCurrentSidebarRow(list.id),
              rowID: "list:\(list.id)"))
          .listRowBackground(Color.clear)
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
        WorkspaceNestedListRows(list: list)
      }
      .padding(.leading, WorkspaceSidebarMetrics.indent(theme))
      let childFolders = model.folders.filter { $0.parentFolderId == folder.id }
      ForEach(childFolders) { child in
        WorkspaceFolderTree(folder: child, isLastInGroup: child.id == childFolders.last?.id)
      }
      .padding(.leading, WorkspaceSidebarMetrics.indent(theme))
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
        .sidebarRowPadding(theme)
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

/// A footer button that asks for a new list or folder. The name is taken in
/// the overlay, the same place ⌘⇧N and the list finder take it, rather than
/// in a popover of its own that only the mouse could open.
private struct AddWorkspaceItemButton: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let title: String
  let systemImage: String
  let command: WorkspaceCommandID
  let kind: WorkspaceCreationKind
  var showsTitle = false

  var body: some View {
    Button {
      model.requestCreation(kind)
    } label: {
      HStack(spacing: theme.space.xs) {
        Image(systemName: systemImage)
        if showsTitle {
          Text(title)
        }
      }
      .font(theme.captionFont)
      .foregroundStyle(theme.muted)
      .padding(.horizontal, theme.space.xs)
      .padding(.vertical, theme.space.xxs)
      .contentShape(RoundedRectangle(cornerRadius: theme.controlRadius))
    }
    // Plain rather than a bezelled push button: chrome is quiet, and these
    // are the only two raised controls the sidebar had.
    .buttonStyle(.plain)
    .focusable()
    .commandHelp(command, note: title)
  }
}
