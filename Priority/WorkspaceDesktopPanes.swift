import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The outline, as a view of its own. (The inspector, which was split out
/// alongside it, now lives in the right dock — `WorkspaceRightDock.swift`.)
///
/// Both used to be computed properties of `WorkspaceDesktopView`, which meant
/// the window's one body read the selection — and SwiftUI redraws a body when
/// anything it read changes, so every arrow key rebuilt the sidebar, the task
/// pane and the inspector together. Split out, a selection change reaches the
/// outline pane, which hands each row a plain `isSelected`, and only the two
/// rows whose answer changed redraw.

struct WorkspaceOutlinePane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    if model.isMultiListScope || model.selectedList != nil {
      let selectedID = model.selectedTaskID
      let tasksHaveKeyboard = model.keyboardFocusArea == .tasks
      VStack(spacing: 0) {
        WorkspacePaneHeader(title: model.currentBoardScopeTitle) {
          if let exit = model.scopeExitTitle {
            WorkspacePaneScopeExit(title: exit) { model.leaveTaskScope() }
          }
        } trailing: {
          WorkspacePaneCount(count: model.outlineOpenCount)
        }
        FocusRule()

        List {
          if model.isMultiListScope {
            // Grouped by list, because the point of a combined view is seeing
            // where each task came from. A folder shows only its own lists.
            ForEach(model.scopeLists) { list in
              Section {
                let items = model.outlineByList[list.id] ?? []
                if items.isEmpty {
                  Text("No tasks").font(theme.bodyFont()).foregroundStyle(theme.dim)
                } else {
                  ForEach(items) { item in
                    row(item, selectedID: selectedID, tasksHaveKeyboard: tasksHaveKeyboard)
                  }
                }
              } header: {
                Button(list.name) { model.selectList(list.id) }
                  .buttonStyle(.plain)
                  .font(theme.bodyFont(weight: .medium))
                  .focusable()
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .help(list.name)
              }
            }
          } else {
            ForEach(model.outline) { item in
              row(item, selectedID: selectedID, tasksHaveKeyboard: tasksHaveKeyboard)
            }
          }
        }
        .listStyle(.inset)
        // The inset style paints the system's own grey behind the rows, which
        // left the outline the one pane not on the theme's paper.
        .scrollContentBackground(.hidden)
        .background(theme.paper)
        .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.tasks) })
      }
    } else {
      ContentUnavailableView("No list selected", systemImage: "list.bullet")
    }
  }

  private func row(_ item: TaskOutlineItem, selectedID: String?, tasksHaveKeyboard: Bool) -> some View {
    let isSelected = item.id == selectedID
    return WorkspaceOutlineRow(item: item, isSelected: isSelected, hasKeyboard: isSelected && tasksHaveKeyboard)
  }
}

/// One outline row, fed the answers it draws rather than the model's
/// selection, so it redraws only when its own answer changes.
struct WorkspaceOutlineRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let item: TaskOutlineItem
  let isSelected: Bool
  let hasKeyboard: Bool

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Button {
        if item.task.isList { model.openItemList(item.task) } else { model.toggleTask(item.task) }
      } label: {
        Image(systemName: model.itemSymbol(for: item.task))
          .foregroundStyle(item.task.status == .open ? theme.muted : theme.success)
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
        .strikethrough(item.task.status != .open)
        .foregroundStyle(item.task.status == .open ? theme.ink : theme.muted)
      WorkspaceTaskPlanningBadges(task: item.task).frame(maxWidth: 170, alignment: .leading)
    }
    // On the row itself: a List row takes its face from the table style, not
    // from the window, so without this every title was in the system sans.
    .font(theme.bodyFont())
    .padding(.leading, CGFloat(item.depth) * theme.space.lg)
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: item.task.id) }
    .workspaceSelection(isSelected: isSelected, hasKeyboard: hasKeyboard)
    .onTapGesture { model.selectTask(item.task) }
    .contextMenu { WorkspaceItemActions(task: item.task) }
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: Binding(
      get: { model.dragDestinationListID == item.task.id },
      set: { model.dragDestinationListID = $0 ? item.task.id : nil }
    )) { providers in
      guard item.task.isList else { return false }
      return WorkspaceTaskDrag.readItemID(from: providers) { payload in
        model.moveDroppedItem(payload, toListID: item.task.listId, parentTaskID: item.task.id)
      }
    }
    .overlay(RoundedRectangle(cornerRadius: theme.controlRadius)
      .stroke(
        model.dragDestinationListID == item.task.id && item.task.isList ? theme.primary : .clear,
        lineWidth: theme.borders.emphasis))
  }
}
