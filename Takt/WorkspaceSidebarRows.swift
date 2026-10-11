import TaktCore
import TaktWorkspace
import SwiftUI

/// A list in the sidebar — the inbox, a loose list, or one in a folder.
///
/// One view whatever the list's place, at the depth the outline gives it.
/// There were two, one per parent, with context menus that had drifted apart
/// (the folder's lists had no icon menu).
struct WorkspaceSidebarListRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  let list: TaskList
  let depth: Int
  /// Whether this is the last list in its folder (or at the top level), and
  /// so the one whose bottom edge means "at the end".
  var isLastInGroup = false

  var body: some View {
    WorkspaceSelectableListRow(list: list, depth: depth)
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
          .commandShortcut(.listRename)
        Button("List settings…") { model.showSettings(for: list) }
          .commandShortcut(.listSettings)
        Button("New nested list…") {
          model.selectList(list.id)
          model.requestNestedListCreation()
        }
        // The Inbox can be renamed and refiled, but not taken away: quick
        // capture has to have somewhere to land.
        if !list.isSystemList {
          Divider()
          Button("Convert to task in Inbox") { model.convertListToTask(list) }
            .commandShortcut(.taskConvertToList)
          Button(list.completedAt == nil ? "Complete list" : "Reopen list") { model.toggleListCompletion(list) }
            .commandShortcut(.listComplete)
          Button("Archive") { model.archiveList(list) }
            .commandShortcut(.listArchive)
          Divider()
          Button("Delete list and tasks", role: .destructive) { model.requestDeletion(of: .list(list)) }
            .commandShortcut(.listDelete)
        }
      }
  }
}

/// The name field of a list or folder that does not exist yet, drawn with the
/// row geometry it will have. Return makes it; Esc, or clicking away with
/// nothing typed, takes the row away again.
struct WorkspaceSidebarDraftRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let draft: WorkspaceSidebarDraft
  let depth: Int

  var body: some View {
    HStack(spacing: theme.space.sm) {
      if draft.kind == .folder {
        // Where a folder's chevron goes, so the name starts where it will.
        Image(systemName: "chevron.right")
          .font(theme.captionFont)
          .frame(width: WorkspaceSidebarMetrics.iconWidth)
      }
      Image(systemName: draft.kind == .folder ? "folder" : "list.bullet")
        .frame(width: WorkspaceSidebarMetrics.iconWidth)
      WorkspaceRenameField(
        initialName: "",
        onCommit: { model.commitSidebarDraft(named: $0) },
        onCancel: { model.cancelSidebarDraft() })
    }
    .foregroundStyle(theme.muted)
    .sidebarRowPadding(theme, depth: depth)
    .background(WorkspaceSelectionBackground(isSelected: true, hasKeyboard: true))
    .accessibilityLabel(draft.kind == .folder ? "New folder name" : "New list name")
  }
}

/// A list nested in a task, under its list or — pinned — among the shortcuts.
struct WorkspaceNestedListRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let depth: Int
  /// The outline's id for this row: a pinned list is drawn twice, and the
  /// cursor is on one copy, not both.
  let rowID: String
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
    .background(WorkspaceSidebarSelectionBackground(
      isCurrent: model.isCurrentSidebarRow(task.id), rowID: rowID))
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

/// A folder's own row: its disclosure chevron, glyph and name. What it holds
/// is drawn by the outline after it, not by this view.
struct WorkspaceFolderRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let folder: ListFolder
  let depth: Int
  /// Whether this is the last folder among its siblings, and so the one whose
  /// bottom edge means "at the end of the folders" — while it is closed; open,
  /// its contents come between.
  var isLastInGroup = false

  private var isCurrent: Bool { model.selectedFolderID == folder.id }

  var body: some View {
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
      .help(
        model.isFolderExpanded(folder)
          ? WorkspaceCommandHelpText.text(for: .motionSidebarCollapse, note: "Collapse folder")
          : WorkspaceCommandHelpText.text(for: .motionSidebarExpand, note: "Expand folder"))
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
    .background(WorkspaceSidebarSelectionBackground(isCurrent: isCurrent, rowID: "folder:\(folder.id)"))
    .contentShape(Rectangle())
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
        .commandShortcut(.listRename)
      Button("Folder settings…") { model.showSettings(for: folder) }
        .commandShortcut(.listSettings)
      Button("New list in folder") { model.beginSidebarDraft(.list, in: folder.id) }
        .commandShortcut(.listNew)
      Button("New subfolder") { model.beginSidebarDraft(.folder, in: folder.id) }
        .commandShortcut(.folderNew)
      Divider()
      Button("Delete folder", role: .destructive) { model.requestDeletion(of: .folder(folder)) }
        .commandShortcut(.listDelete)
    }
  }
}
