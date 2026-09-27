import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The outline and the inspector, as views of their own.
///
/// Both used to be computed properties of `WorkspaceDesktopView`, which meant
/// the window's one body read the selection — and SwiftUI redraws a body when
/// anything it read changes, so every arrow key rebuilt the sidebar, the task
/// pane and the inspector together. Split out, a selection change reaches the
/// outline pane, which hands each row a plain `isSelected`, and only the two
/// rows whose answer changed redraw.

struct WorkspaceOutlinePane: View {
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    if model.isMultiListScope || model.selectedList != nil {
      let selectedID = model.selectedTaskID
      let tasksHaveKeyboard = model.keyboardFocusArea == .tasks
      VStack(spacing: 0) {
        WorkspacePaneHeader(title: model.currentBoardScopeTitle) {
          if let scope = model.scopeTask {
            WorkspacePaneScopeExit(title: scope.title) { model.leaveTaskScope() }
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
                  Text("No tasks").foregroundStyle(.tertiary)
                } else {
                  ForEach(items) { item in
                    row(item, selectedID: selectedID, tasksHaveKeyboard: tasksHaveKeyboard)
                  }
                }
              } header: {
                Button(list.name) { model.selectList(list.id) }
                  .buttonStyle(.plain)
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
        .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.tasks) })

        WorkspaceScopedTaskComposer(board: false)
          .environment(model)
          .padding(14)
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
    HStack(spacing: 8) {
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
        .foregroundStyle(item.task.status == .open ? .primary : .secondary)
      WorkspaceTaskPlanningBadges(task: item.task).frame(maxWidth: 170, alignment: .leading)
    }
    .padding(.leading, CGFloat(item.depth) * 16)
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
    .overlay(RoundedRectangle(cornerRadius: 6)
      .stroke(model.dragDestinationListID == item.task.id && item.task.isList ? Color.accentColor : .clear, lineWidth: 2))
  }
}

/// The right-hand editor. It is the one pane that has to redraw when the
/// selection moves, since it shows the selection, so it reads it here rather
/// than making the window read it.
struct WorkspaceInspectorPane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  var focusedArea: FocusState<WorkspaceFocusArea?>.Binding

  var body: some View {
    let selected = model.selectedTask
    VStack(alignment: .leading, spacing: 0) {
      // The pane names the task rather than itself. "INSPECTOR" told you
      // something you could already see; which task you are editing is the
      // thing that is genuinely ambiguous when the selection moves behind you.
      WorkspacePaneHeader(title: selected?.title ?? "Nothing selected") {
        if let task = selected, let list = model.list(for: task) {
          Text(list.name)
            .font(theme.bodyFont(size: 11))
            .foregroundStyle(theme.muted)
            .lineLimit(1)
        }
      }
      FocusRule()
      // The editor is about twenty-five controls tall. It was in a plain
      // VStack, so on anything short of a full-height window the last of them
      // — Save, Revert and Start focus — were simply off the bottom with no
      // way to reach them.
      ScrollView {
        if let task = selected {
          VStack(alignment: .leading, spacing: theme.space.md) {
            LocalTaskInspector(
              task: task,
              focusRequest: model.focusRequest,
              requestedFocusArea: model.requestedFocusArea)
              .environment(model)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .focusSurfaceGutter()
          .padding(.vertical, theme.space.md)
        } else {
          Text("Select a task to see its notes, schedule, estimate, and focus controls here.")
            .font(theme.bodyFont(size: 12))
            .foregroundStyle(theme.muted)
            .focusSurfaceGutter()
            .padding(.vertical, theme.space.md)
        }
      }
    }
    .background(.background)
    .focusable()
    .focused(focusedArea, equals: .inspector)
    .focusEffectDisabled()
    .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.inspector) })
  }
}
