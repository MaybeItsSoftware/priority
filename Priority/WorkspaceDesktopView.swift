import Foundation
import Observation
import PriorityCore
import PriorityWorkspace
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceDesktopView: View {
  @Environment(WorkspaceViewModel.self) private var model
  private let everythingSidebarID = "priority:everything"
  @State private var floatingTimer = LocalFloatingFocusTimer()
  @FocusState private var focusedArea: WorkspaceFocusArea?

  var body: some View {
    workspace
  }

  private var workspace: some View {
    HSplitView {
      // The sidebar stays through focus mode: setting up a session often means
      // looking at which list something came from, and losing your place in the
      // workspace to do that is its own distraction.
      sidebar
        .focusSection()
        .frame(minWidth: 155, idealWidth: 185, maxWidth: 230)
      // Focus mode takes the main pane rather than floating over it. A sheet
      // leaves the board visible round the edges, which is the one thing the
      // screen exists to stop.
      Group {
        if model.showsFocusScreen {
          WorkspaceFocusScreen()
            .environment(model)
        } else {
          taskPane
        }
      }
      .animation(.easeInOut(duration: 0.15), value: model.showsFocusScreen)
      .focusSection()
      .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
      // Selection remains light-weight; only I or an explicit inspector
      // command opens the editor and consumes the third pane.
      if model.isInspectorVisible && model.selectedTask != nil && !model.showsFocusScreen {
        inspector
          .focusSection()
          .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)
      }
    }
    .frame(minWidth: 760, minHeight: 520)
    .onAppear {
      focusedArea = model.requestedFocusArea
      if model.activeFocusSession != nil { floatingTimer.show(model: model) }
    }
    .onChange(of: model.focusRequest) { _, _ in
      focusedArea = model.requestedFocusArea
    }
    .onChange(of: focusedArea) { _, area in
      model.reportKeyboardFocus(area)
    }
    .onChange(of: model.focusFloatRequest) { _, _ in
      floatingTimer.show(model: model)
    }
    .onChange(of: model.activeFocusSession?.id) { _, sessionID in
      if sessionID == nil { floatingTimer.close() }
    }
    .alert("Priority needs attention", isPresented: Binding(
      get: { model.errorMessage != nil },
      set: { if !$0 { model.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
    }
    .sheet(isPresented: Bindable(model).showsFocusPanel) {
      LocalFocusPanel(onFloat: {
        floatingTimer.show(model: model, activate: true)
        model.showsFocusPanel = false
      })
        .environment(model)
    }
    .sheet(isPresented: Bindable(model).showsKeyboardHelp) {
      WorkspaceKeyboardHelp()
    }
    .sheet(item: Bindable(model).taskMoveRequest) { task in
      WorkspaceTaskMoveSheet(task: task)
        .environment(model)
    }
    .sheet(item: Bindable(model).creationRequest) { kind in
      WorkspaceCreationSheet(kind: kind) { name in
        switch kind {
        case .list: model.createList(named: name, in: model.creationParentFolderID)
        case .folder: model.createFolder(named: name, in: model.creationParentFolderID)
        }
      }
    }
    .sheet(isPresented: Bindable(model).newKanbanColumnRequest) {
      NewKanbanColumnSheet { model.addKanbanColumn(named: $0) }
    }
    .sheet(item: Bindable(model).sidebarEditor) { editor in
      WorkspaceSidebarEditorSheet(editor: editor)
        .environment(model)
    }
    .confirmationDialog(
      model.pendingSidebarDeletion?.deletionTitle ?? "Delete item?",
      isPresented: Binding(
        get: { model.pendingSidebarDeletion != nil },
        set: { if !$0 { model.pendingSidebarDeletion = nil } }
      ),
      presenting: model.pendingSidebarDeletion
    ) { _ in
      Button("Delete", role: .destructive) { model.confirmPendingSidebarDeletion() }
      Button("Cancel", role: .cancel) {}
    } message: { item in
      Text(item.deletionMessage)
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("PRIORITY")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)

      WorkspaceFocusLauncher()
        .environment(model)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)

      Text("LISTS")
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)

      List(selection: Binding(
        get: { model.isEverythingSelected ? everythingSidebarID : model.selectedListID },
        set: { id in
          if id == everythingSidebarID { model.selectEverything() } else if let id { model.selectList(id) }
        }
      )) {
        Label("Everything", systemImage: "square.stack.3d.up")
          .tag(Optional(everythingSidebarID))
          .accessibilityLabel("Everything, all lists")
        let rootLists = model.lists.filter { $0.folderId == nil }
        Section("Sub-lists") {
          ForEach(model.folders.filter { $0.parentFolderId == nil }) { folder in
            WorkspaceFolderTree(folder: folder)
              .padding(.leading, 10)
          }
          ForEach(rootLists) { list in
            sidebarListRow(list)
              .padding(.leading, 10)
          }
        }
      }
      .listStyle(.sidebar)
      .focusable()
      .focused($focusedArea, equals: .sidebar)
      .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.sidebar) })

      Divider()
      HStack(spacing: 8) {
        AddWorkspaceItemButton(title: "New list", systemImage: "plus") { name in
          model.createList(named: name)
        }
        AddWorkspaceItemButton(title: "New folder", systemImage: "folder.badge.plus") { name in
          model.createFolder(named: name)
        }
        if !model.archivedLists.isEmpty {
          Menu {
            ForEach(model.archivedLists) { list in
              Button("Restore \(list.name)") { model.restoreList(list) }
            }
          } label: {
            Image(systemName: "archivebox")
          }
          .focusable()
          .help("Restore archived lists")
        }
      }
      .padding(10)
    }
    .background(.bar)
  }

  private func sidebarListRow(_ list: TaskList) -> some View {
    HStack(spacing: 7) {
      Circle()
        .fill(Color(priorityHex: list.colorHex))
        .frame(width: 8, height: 8)
      Text(list.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(list.name)
    }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
      .tag(Optional(list.id))
      .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: Binding(
        get: { model.dragDestinationListID == list.id },
        set: { model.dragDestinationListID = $0 ? list.id : nil }
      )) { providers in
        WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
          guard let task = model.task(withID: taskID), task.listId != list.id else { return }
          model.moveTask(task, toListId: list.id)
        }
      }
      .background(
        model.dragDestinationListID == list.id ? Color.accentColor.opacity(0.16) : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contextMenu {
        Button("List settings…") { model.showSettings(for: list) }
        Divider()
        Button("Archive") { model.archiveList(list) }
        Divider()
        Button("Delete list and tasks", role: .destructive) { model.requestDeletion(of: .list(list)) }
      }
  }

  @ViewBuilder
  private var taskPane: some View {
    switch model.viewMode {
    case .board:
      WorkspaceKanbanBoard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
    case .outline:
      outlineTaskPane
    case .dailies:
      WorkspaceDailiesDashboard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
    case .matrix:
      WorkspaceMatrixDashboard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
    case .focus:
      WorkspaceFocusDashboard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
    }
  }

  @ViewBuilder
  private var outlineTaskPane: some View {
    if model.isEverythingSelected || model.selectedList != nil {
      let outlineByList = Dictionary(grouping: model.outline) { $0.task.listId }
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(model.currentBoardScopeTitle)
              .font(.title2.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.middle)
            if let scope = model.scopeTask {
              Button {
                model.leaveTaskScope()
              } label: {
                Label(scope.title, systemImage: "chevron.left")
                  .font(.caption)
                  .lineLimit(1)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
            } else {
              Text("Open tasks and projects")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
        }
        .padding(20)

        List {
          if model.isEverythingSelected {
            ForEach(model.lists) { list in
              Section {
                let items = outlineByList[list.id] ?? []
                if items.isEmpty {
                  Text("No tasks").foregroundStyle(.tertiary)
                } else {
                  ForEach(items) { item in taskRow(item) }
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
            ForEach(model.outline) { item in taskRow(item) }
          }
        }
        .listStyle(.inset)
        .focusable()
        .focused($focusedArea, equals: .tasks)
        .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.tasks) })

        WorkspaceScopedTaskComposer(board: false)
          .environment(model)
          .padding(14)
      }
    } else {
      ContentUnavailableView("No list selected", systemImage: "list.bullet")
    }
  }

  private func taskRow(_ item: TaskOutlineItem) -> some View {
    HStack(spacing: 8) {
      Button {
        model.toggleTask(item.task)
      } label: {
        Image(systemName: item.task.status == .open ? "circle" : "checkmark.circle.fill")
          .foregroundStyle(item.task.status == .open ? Color.secondary : Color.green)
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
    }
    .padding(.leading, CGFloat(item.depth) * 22)
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: item.task.id) }
    .background(
      item.task.id == model.selectedTaskID ? Color.accentColor.opacity(0.14) : .clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .onTapGesture { model.selectTask(item.task) }
  }

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("INSPECTOR")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
      Divider()
      if let task = model.selectedTask {
        LocalTaskInspector(
          task: task,
          focusRequest: model.focusRequest,
          requestedFocusArea: model.requestedFocusArea)
          .environment(model)
      } else {
        Text("Select a task to see its notes, schedule, estimate, and focus controls here.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(18)
    .background(.background)
    .focusable()
    .focused($focusedArea, equals: .inspector)
    .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.inspector) })
  }
}

private struct WorkspaceKanbanBoard: View {
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    if model.selectedList == nil && !model.isEverythingSelected {
      ContentUnavailableView("No list selected", systemImage: "rectangle.split.3x1")
    } else {
      GeometryReader { geometry in
        let columnCount = CGFloat(max(model.boardColumns.count, 1))
        // Five default columns should be visible together at useful desktop
        // widths. Fewer/custom columns expand naturally instead of leaving an
        // oversized empty canvas; very narrow windows still scroll.
        let available = geometry.size.width - 36 - 14 * (columnCount - 1)
        let columnWidth = max(172, min(340, available / columnCount))
        VStack(spacing: 0) {
          ScrollViewReader { scrollProxy in
            ScrollView(.horizontal) {
              LazyHStack(alignment: .top, spacing: 14) {
                ForEach(model.boardColumns) { column in
                  WorkspaceKanbanColumnView(
                    column: column,
                    width: columnWidth)
                    .environment(model)
                }
              }
              .padding(18)
            }
            .onChange(of: model.selectedTaskID) { _, id in
              guard let id, let task = model.task(withID: id),
                model.isTaskVisibleOnBoard(task)
              else { return }
              withAnimation(.easeInOut(duration: 0.15)) {
                scrollProxy.scrollTo(id, anchor: .center)
              }
            }
          }
          WorkspaceScopedTaskComposer(board: true)
            .environment(model)
          .padding(14)
        }
      }
      .background(.background)
    }
  }
}

private struct WorkspaceKanbanColumnView: View {
  @Environment(WorkspaceViewModel.self) private var model
  let column: WorkspaceKanbanColumn
  let width: CGFloat
  @State private var isDropTargeted = false
  @State private var isAddingAtTop = false
  @State private var topTaskTitle = ""
  @FocusState private var topComposerFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(column.title.uppercased())
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(column.title)
        Text("\(model.tasks(in: column).count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
        Spacer()
        Button {
          isAddingAtTop = true
          topComposerFocused = true
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel("Add task at top of \(column.title)")
        .help("Add highest-priority task in \(column.title)")
        if model.boardColumns.count > 1 {
          Button(role: .destructive) {
            model.removeKanbanColumn(column)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.plain)
          .focusable()
          .help("Remove \(column.title)")
        }
      }

      if isAddingAtTop {
        TextField("Add at top", text: $topTaskTitle)
          .textFieldStyle(.roundedBorder)
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

      ForEach(model.tasks(in: column)) { task in
        WorkspaceKanbanCard(task: task, column: column)
          .environment(model)
          .id(task.id)
      }

      if model.tasks(in: column).isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "arrow.down.doc")
            .font(.title3)
          Text(isDropTargeted ? "Drop card here" : "Drop cards here")
            .font(.caption.weight(.medium))
        }
        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5]))
        )
      }

      TaskComposer(focusRequest: 0) { title in
        model.createBoardTask(named: title, in: column)
      }
      .accessibilityLabel("Add task to \(column.title)")

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(width: width, alignment: .topLeading)
    .frame(minHeight: 360, alignment: .topLeading)
    .background(
      isDropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
    )
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

private struct WorkspaceKanbanCard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @FocusState private var isCardFocused: Bool
  @State private var isExpanded = false
  @State private var isDropTargeted = false
  @State private var newSubtaskTitle = ""
  let task: WorkspaceTask
  let column: WorkspaceKanbanColumn

  var body: some View {
    cardSurface
      .help("Drag to move. Enter opens its Kanban board; Option Left/Right moves columns.")
      .focusable()
      .focused($isCardFocused)
      .onChange(of: isCardFocused) { _, focused in
        if focused {
          model.selectTask(task)
          model.reportKeyboardFocus(.tasks)
        }
      }
      .onChange(of: model.selectedTaskID) { _, id in
        if id == task.id && !isCardFocused { isCardFocused = true }
      }
      .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, .leftArrow, .rightArrow, "i"]) { press in
        handleCardKey(press)
      }
      .accessibilityElement(children: .contain)
  }

  private var cardSurface: some View {
    VStack(alignment: .leading, spacing: 8) {
      cardHeading
      if let parent = model.boardParent(of: task) {
        Button("↳ \(parent.title)") {
          model.selectTask(parent)
          model.reportKeyboardFocus(.tasks)
        }
        .buttonStyle(.plain)
        .focusable()
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help("Subtask of \(parent.title)")
      }
      if model.isEverythingSelected, let list = model.list(for: task) {
        Button {
          model.selectList(list.id)
        } label: {
          Label(list.name, systemImage: "list.bullet")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .focusable()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help("Open sub-list \(list.name)")
      }
      if let dueAt = task.dueAt {
        HStack(spacing: 4) {
          Image(systemName: "calendar")
          Text(dueAt, format: .dateTime.month().day())
        }.font(.caption).foregroundStyle(.secondary)
      }
      if isExpanded { inlineSubtasks }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      task.id == model.selectedTaskID ? Color.accentColor.opacity(0.17) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(
      isDropTargeted ? Color.accentColor : Color.primary.opacity(0.15),
      lineWidth: isDropTargeted ? 2 : 1))
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
      WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
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
    HStack(spacing: 7) {
      Image(systemName: "line.3.horizontal")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(width: 13, height: 24)
        .contentShape(Rectangle())
        .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
        .accessibilityLabel("Drag \(task.title)")
        .help("Drag this card to reorder it or move it to another column")
      Button {
        model.toggleTask(task)
      } label: {
        Image(systemName: task.status == .open ? "circle" : "checkmark.circle.fill")
          .foregroundStyle(task.status == .open ? Color.secondary : Color.green)
      }
      .buttonStyle(.plain)
      .focusable()
      Button(task.title) {
        model.selectTask(task)
        model.reportKeyboardFocus(.tasks)
      }
      .buttonStyle(.plain)
      .focusable()
      .multilineTextAlignment(.leading)
      .lineLimit(2)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(task.title)
      .strikethrough(task.status != .open)
      Button {
        if model.activeFocusSession == nil {
          model.startFocus(on: task)
        } else if model.activeFocusTask?.id == task.id {
          model.showsFocusPanel = true
        } else {
          model.addToFocusQueue(task)
        }
      } label: {
        Image(systemName: model.activeFocusTask?.id == task.id ? "bolt.fill" :
          model.activeFocusSession == nil ? "bolt" : "plus")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .focusable()
      .accessibilityLabel(model.activeFocusSession == nil ? "Focus on \(task.title)" : "Add \(task.title) to focus")
      .help(model.activeFocusSession == nil ? "Start focus" : "Add to focus queue")
      Button {
        isExpanded.toggle()
      } label: {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.plain)
      .focusable()
      .accessibilityLabel(isExpanded ? "Collapse subtasks" : "Expand subtasks")
      .help(isExpanded ? "Collapse subtasks" : "Show subtasks and add a subtask")
    }
  }

  private var inlineSubtasks: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      let items = model.descendants(of: task)
      if items.isEmpty {
        Text("No subtasks yet")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
              inlineSubtaskRow(item)
            }
          }
        }
        .frame(height: min(CGFloat(items.count) * 30, 180))
      }
      HStack(spacing: 5) {
        Image(systemName: "plus")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("Add subtask", text: $newSubtaskTitle)
          .textFieldStyle(.plain)
          .onSubmit { submitSubtask() }
          .accessibilityLabel("Add subtask under \(task.title)")
      }
      .font(.caption)
    }
  }

  private func inlineSubtaskRow(_ item: TaskOutlineItem) -> some View {
    HStack(spacing: 5) {
      Button {
        model.toggleTask(item.task)
      } label: {
        Image(systemName: item.task.status == .open ? "circle" : "checkmark.circle.fill")
          .font(.caption)
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
          .font(.caption2)
          .frame(maxWidth: 50)
      }
      .menuStyle(.borderlessButton)
      .focusable()
      .help("Move \(item.task.title) to a column")
    }
    .font(.caption)
    .padding(.leading, CGFloat(item.depth) * 10)
    .onDrag { WorkspaceTaskDrag.provider(for: item.task.id) }
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

  static func provider(for taskID: String) -> NSItemProvider {
    NSItemProvider(object: taskID as NSString)
  }

  static func readTaskID(from providers: [NSItemProvider], apply: @escaping @MainActor (String) -> Void) -> Bool {
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

private struct WorkspaceMatrixDashboard: View {
  @Environment(WorkspaceViewModel.self) private var model

  private let quadrants: [(title: String, urgency: Int, importance: Int, tint: Color)] = [
    ("Do now", 1, 1, .red),
    ("Schedule", 0, 1, .blue),
    ("Delegate", 1, 0, .orange),
    ("Eliminate", 0, 0, .gray),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("EISENHOWER MATRIX")
          .font(.title2.weight(.semibold))
        Text(model.isEverythingSelected
          ? "Place work across all lists; each task keeps its own list and project."
          : "Place the direct tasks in this project; each project keeps its own matrix.")
          .font(.callout)
          .foregroundStyle(.secondary)
        let unplaced = model.boardTasks.filter {
          let position = model.matrixPosition(for: $0)
          return position.urgency == nil || position.importance == nil
        }
        if !unplaced.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("UNPLACED")
              .font(.caption.weight(.bold))
              .foregroundStyle(.secondary)
            ForEach(unplaced) { task in
              WorkspaceMatrixTaskRow(task: task)
                .environment(model)
            }
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          ForEach(quadrants, id: \.title) { quadrant in
            WorkspaceMatrixQuadrant(
              title: quadrant.title, urgency: quadrant.urgency, importance: quadrant.importance, tint: quadrant.tint)
              .environment(model)
          }
        }
      }
      .padding(20)
    }
  }
}

private struct WorkspaceMatrixQuadrant: View {
  @Environment(WorkspaceViewModel.self) private var model
  let title: String
  let urgency: Int
  let importance: Int
  let tint: Color
  @State private var isDropTargeted = false

  private var tasks: [WorkspaceTask] {
    model.boardTasks.filter {
      let position = model.matrixPosition(for: $0)
      return position.urgency == urgency && position.importance == importance
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption.weight(.bold))
        .foregroundStyle(tint)
      ForEach(tasks) { task in
        WorkspaceMatrixTaskRow(task: task)
          .environment(model)
      }
      if tasks.isEmpty { Text("No tasks").font(.caption).foregroundStyle(.tertiary) }
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
    .background(
      isDropTargeted ? tint.opacity(0.22) : tint.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(isDropTargeted ? tint : .clear, lineWidth: 2))
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
      WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
        guard let task = model.task(withID: taskID),
          model.isTaskVisibleOnBoard(task)
        else { return }
        model.selectTask(task)
        model.setMatrixPosition(.init(urgency: urgency, importance: importance), for: task)
      }
    }
  }
}

private struct WorkspaceMatrixTaskRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @FocusState private var isRowFocused: Bool
  let task: WorkspaceTask

  var body: some View {
    HStack {
      Button(task.title) {
        model.selectTask(task)
        model.reportKeyboardFocus(.tasks)
      }
      .buttonStyle(.plain)
      .focusable()
      .lineLimit(1)
      .truncationMode(.tail)
      .help(task.title)
      .frame(maxWidth: .infinity, alignment: .leading)
      if model.isEverythingSelected, let list = model.list(for: task) {
        Text(list.name)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(list.name)
      }
    }
    .padding(6)
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .background(
      task.id == model.selectedTaskID ? Color.accentColor.opacity(0.17) : .clear,
      in: RoundedRectangle(cornerRadius: 6))
    .focusable()
    .focused($isRowFocused)
    .onChange(of: isRowFocused) { _, focused in
      if focused { model.selectTask(task) }
    }
    .onChange(of: model.selectedTaskID) { _, id in
      if id == task.id && !isRowFocused { isRowFocused = true }
    }
    .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, "i", "1", "2", "3", "4"]) { press in
      guard isRowFocused else { return .ignored }
      if press.modifiers.contains(.option) {
        switch press.key {
        case "1": place(urgency: 1, importance: 1)
        case "2": place(urgency: 0, importance: 1)
        case "3": place(urgency: 1, importance: 0)
        case "4": place(urgency: 0, importance: 0)
        default: return .ignored
        }
      } else if press.key == .upArrow {
        model.selectAdjacentTask(by: -1)
      } else if press.key == .downArrow {
        model.selectAdjacentTask(by: 1)
      } else if press.key == .space {
        model.toggleTask(task)
      } else if press.key == .return {
        model.enterTask(task)
      } else if press.key == "i" {
        model.toggleInspector()
      } else {
        return .ignored
      }
      return .handled
    }
  }

  private func place(urgency: Int, importance: Int) {
    model.selectTask(task)
    model.setMatrixPosition(.init(urgency: urgency, importance: importance), for: task)
  }
}

private struct WorkspaceFocusDashboard: View {
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("FOCUS")
        .font(.title2.weight(.semibold))
      if let task = model.activeFocusTask {
        Text(task.title)
          .font(.title3.weight(.medium))
          .lineLimit(2)
          .truncationMode(.tail)
        Text("Focus mode is active. Complete the current task to advance the queue.")
          .foregroundStyle(.secondary)
        HStack {
          Button("Complete current") { model.completeFocusedTask() }
            .buttonStyle(.borderedProminent)
            .focusable()
          Button("End session", role: .destructive) { model.finishFocus() }
            .buttonStyle(.bordered)
            .focusable()
        }
        if !model.focusQueue.isEmpty {
          Divider()
          Text("UP NEXT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
          ForEach(model.focusQueue) { item in
            Text(item.task.title)
              .lineLimit(1)
              .help(item.task.title)
          }
        }
      } else if let task = model.selectedTask {
        Text("Ready to focus on \(task.title).")
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Button("Start focus") { model.startFocus(on: task) }
          .buttonStyle(.borderedProminent)
          .focusable()
      } else {
        ContentUnavailableView(
          "Choose a task to focus on",
          systemImage: "bolt.fill",
          description: Text("Select a card or task, then open Focus."))
      }
      Spacer()
    }
    .padding(24)
  }
}

private struct WorkspaceTaskMoveSheet: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let task: WorkspaceTask
  @State private var destinationID: String?

  private var destinations: [TaskList] {
    model.lists.filter { $0.id != task.listId }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Move task to list")
        .font(.title3.weight(.semibold))
      Text(task.title)
        .lineLimit(2)
        .truncationMode(.tail)
        .help(task.title)
      Picker("Destination", selection: $destinationID) {
        ForEach(destinations) { list in
          Text(list.name).tag(Optional(list.id))
        }
      }
      .focusable()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
        Button("Move") {
          guard let destinationID else { return }
          model.moveTask(task, toListId: destinationID)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .focusable()
        .keyboardShortcut(.defaultAction)
        .disabled(destinationID == nil)
      }
    }
    .padding(24)
    .frame(width: 380)
    .onAppear { destinationID = destinations.first?.id }
  }
}

private struct NewKanbanColumnSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @FocusState private var isFocused: Bool
  let onSubmit: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New board column").font(.title3.weight(.semibold))
      TextField("Column name", text: $name)
        .focused($isFocused)
        .onSubmit { submit() }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          .focusable()
        Button("Add") { submit() }
          .focusable()
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 340)
    .onAppear { isFocused = true }
  }

  private func submit() {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    onSubmit(name)
    dismiss()
  }
}

private struct WorkspaceFolderTree: View {
  @Environment(WorkspaceViewModel.self) private var model
  let folder: ListFolder

  var body: some View {
    DisclosureGroup(isExpanded: Binding(
      get: { model.isFolderExpanded(folder) },
      set: { model.setFolderExpanded(folder, expanded: $0) }
    )) {
      ForEach(model.lists.filter { $0.folderId == folder.id }) { list in
        HStack(spacing: 7) {
          Circle()
            .fill(Color(priorityHex: list.colorHex))
            .frame(width: 8, height: 8)
          Text(list.name)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(list.name)
        }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
          .tag(Optional(list.id))
          .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: Binding(
            get: { model.dragDestinationListID == list.id },
            set: { model.dragDestinationListID = $0 ? list.id : nil }
          )) { providers in
            WorkspaceTaskDrag.readTaskID(from: providers) { taskID in
              guard let task = model.task(withID: taskID), task.listId != list.id else { return }
              model.moveTask(task, toListId: list.id)
            }
          }
          .background(
            model.dragDestinationListID == list.id ? Color.accentColor.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
          )
          .contextMenu {
            Button("List settings…") { model.showSettings(for: list) }
            Divider()
            Button("Archive") { model.archiveList(list) }
            Divider()
            Button("Delete list and tasks", role: .destructive) { model.requestDeletion(of: .list(list)) }
          }
      }
      ForEach(model.folders.filter { $0.parentFolderId == folder.id }) { child in
        WorkspaceFolderTree(folder: child)
      }
    } label: {
      Button {
        model.selectFolder(folder)
      } label: {
        Label(folder.name, systemImage: "folder")
          .lineLimit(1)
          .truncationMode(.middle)
          .help(folder.name)
      }
        .buttonStyle(.plain)
        .focusable()
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
          folder.id == model.selectedFolderID ? Color.accentColor.opacity(0.14) : .clear,
          in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .contextMenu {
          Button("Folder settings…") { model.showSettings(for: folder) }
          Button("New list in folder") { model.requestCreation(.list, in: folder.id) }
          Button("New subfolder") { model.requestCreation(.folder, in: folder.id) }
          Divider()
          Button("Delete folder", role: .destructive) { model.requestDeletion(of: .folder(folder)) }
        }
    }
  }
}

private struct LocalFocusPanel: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let onFloat: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Label("FOCUS", systemImage: "bolt.fill")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Hide") { dismiss() }
          .buttonStyle(.plain)
          .focusable()
          .keyboardShortcut(.cancelAction)
      }

      if let session = model.activeFocusSession, let task = model.activeFocusTask {
        Text(task.title)
          .font(.title2.weight(.semibold))
          .lineLimit(3)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let clock = reading(session: session, now: context.date)
          Text(clock.text)
            .font(.system(size: 42, weight: .bold, design: .monospaced))
            .foregroundStyle(clock.isOverrun ? Color.orange : Color.accentColor)
        }
        Text("One task at a time. The queue stays editable while you work.")
          .font(.callout)
          .foregroundStyle(.secondary)

        Divider()
        Text("UP NEXT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(model.focusQueue) { queued in
              HStack {
                Image(systemName: queued.item.state == .completed ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(queued.item.state == .completed ? Color.green : Color.secondary)
                Text(queued.task.title)
                  .lineLimit(1)
                  .truncationMode(.tail)
                  .help(queued.task.title)
                Spacer()
              }
            }
          }
        }
        .frame(maxHeight: 110)

        HStack {
          Button("Done") { model.completeFocusedTask() }
            .buttonStyle(.borderedProminent)
            .focusable()
            .keyboardShortcut(.defaultAction)
          Button("Float timer") { onFloat() }
            .buttonStyle(.bordered)
            .focusable()
          Button("End session", role: .destructive) { model.finishFocus() }
            .buttonStyle(.bordered)
            .focusable()
        }
      } else {
        ContentUnavailableView("Focus session complete", systemImage: "checkmark.circle")
      }
    }
    .padding(28)
    .frame(width: 440, height: 520, alignment: .topLeading)
  }

  private func reading(session: FocusSession, now: Date) -> FocusTimerDisplay.Reading {
    FocusTimerDisplay.reading(
      since: session.startedAt, planned: TimeInterval(session.workDurationSeconds), now: now)
  }
}

private struct TaskComposer: View {
  @State private var title = ""
  @FocusState private var isFocused: Bool
  let focusRequest: Int
  let onSubmit: (String) -> Void

  var body: some View {
    HStack {
      Image(systemName: "plus")
        .foregroundStyle(.secondary)
      TextField("Add a task", text: $title)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onSubmit { submit() }
    }
    .padding(10)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    .onChange(of: focusRequest) { _, _ in isFocused = true }
  }

  private func submit() {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    onSubmit(title)
    title = ""
  }
}

private struct WorkspaceScopedTaskComposer: View {
  @Environment(WorkspaceViewModel.self) private var model
  let board: Bool

  var body: some View {
    HStack(spacing: 10) {
      if model.isEverythingSelected {
        Picker("In list", selection: Bindable(model).newTaskListID) {
          ForEach(model.lists) { list in
            Text(list.name).tag(Optional(list.id))
          }
        }
        .pickerStyle(.menu)
        .focusable()
        .frame(width: 170)
        .help("Choose the sub-list for new tasks")
      }
      TaskComposer(focusRequest: model.taskComposerFocusRequest) { title in
        if board { model.createBoardTask(named: title) } else { model.createTask(named: title) }
      }
      .frame(maxWidth: .infinity)
    }
  }
}

private struct WorkspaceCreationSheet: View {
  let kind: WorkspaceCreationKind
  let onSubmit: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(kind.title).font(.title3.weight(.semibold))
      TextField("Name", text: $name)
        .focused($isFocused)
        .onSubmit { submit() }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
        Button("Create") { submit() }
          .buttonStyle(.borderedProminent)
          .focusable()
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 340)
    .onAppear { isFocused = true }
  }

  private func submit() {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    onSubmit(name)
    dismiss()
  }
}

private struct WorkspaceKeyboardHelp: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Keyboard navigation").font(.title3.weight(.semibold))
        Spacer()
        Button("Done") { dismiss() }
          .focusable()
          .keyboardShortcut(.defaultAction)
      }
      ScrollView {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
        key("↑ ↓ / J K", "Select visible tasks when the task surface has focus")
        key("⌘ 0", "Open Everything across all active lists")
        key("⌘ 1 / ⌘ 2 / ⌘ 3", "Focus the sidebar or task surface; ⌘ 3 opens the inspector")
        key("I", "Open or close the selected task’s inspector")
        key("⌘ 4–7", "View this list as Board, Outline, Dailies, or Matrix")
        key("⌘ 8", "Enter focus mode, or return to the running session")
        key("Focus: ↑ ↓ / J K", "Climb to less important work, or back down towards the most important")
        key("Focus: ↵ / Space", "Stage the task, then begin it with the estimate shown")
        key("Focus: X", "Tick the task off without starting a session")
        key("Focus: ⌥ ↑ / ↓", "Move the task itself up or down the ladder, fixing your own order")
        key("Focus: L", "Schedule it for later so it stops being offered")
        key("⌃ Tab / ⌃ ⇧ Tab", "Move focus forward or backward between those regions")
        key("Tab / ⇧ Tab", "Move between buttons, menus, and fields")
        key("Sidebar: ↑ ↓ / J K", "Select Everything, then its visible lists and folders")
        key("Sidebar: ← → / Return", "Collapse, expand, or toggle the selected folder")
        key("Board: ← →", "Move selection between columns; Enter opens a task’s nested board")
        key("Outline: ← → / H L", "Leave or enter a task’s subtasks")
        key("Space / X", "Complete or reopen selected task")
        key("⌘ ⌥ → / ←", "Indent or outdent the selected task")
        key("⌥ → / ←", "Move the selected board card to the next or previous column")
        key("⌥ 1–4", "Place the selected matrix task in a quadrant")
        key("⌘ ⇧ D", "Commit to the selected task daily, or stop")
        key("⌘ ⇧ C", "Add a board column")
        key("⌘ ↑ / ⌘ ↓", "Move the selected task, or the current list when no task is selected")
        key("Board card drop", "Drop on a sibling card to place it before that card")
        key("Delete", "Delete the selected task and its subtasks")
        key("F", "Start focus, or add to the active focus queue")
        key("M", "Move the selected task and its subtasks to another list")
        key("[  ]", "Previous or next list, including Everything")
        key("⌘ N", "Add a task")
        key("⌘ ⌥ [ / ]", "Choose the destination sub-list when adding in Everything")
        key("⌘ S", "Save edits in the task inspector")
        key("⌘ ⇧ N", "Create a list; when a folder is selected, create it there")
        key("⌘ ⌥ N", "Create a folder; when a folder is selected, create it there")
        key("⌘ I", "Open settings for the selected list or folder")
        key("⌘ ⇧ A / ⌘ ⇧ R", "Archive the current list / restore the most recently archived list")
        key("⌃ ⌥ ↑ / ↓", "Select the previous or next folder")
        key("⌘ ⌥ ↑ / ↓", "Reorder the selected folder among its siblings")
        key("⌘ ⇧ Delete", "Delete the selected folder or current list")
        key("? / ⌘ /", "Show this keyboard reference")
        key("Esc", "Clear selection or leave the current task scope")
        }
      }
      .frame(maxHeight: 520)
    }
    .padding(28)
    .frame(width: 480)
  }

  @ViewBuilder
  private func key(_ shortcut: String, _ description: String) -> some View {
    GridRow {
      Text(shortcut).font(.system(.body, design: .monospaced).weight(.semibold))
      Text(description).foregroundStyle(.secondary)
    }
  }
}

private struct AddWorkspaceItemButton: View {
  let title: String
  let systemImage: String
  let onSubmit: (String) -> Void
  @State private var isPresenting = false
  @State private var name = ""
  @FocusState private var nameIsFocused: Bool

  var body: some View {
    Button {
      isPresenting = true
    } label: {
      Image(systemName: systemImage)
    }
    .focusable()
    .help(title)
    .popover(isPresented: $isPresenting) {
      VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.headline)
        TextField("Name", text: $name)
          .focused($nameIsFocused)
          .onSubmit { submit() }
        HStack {
          Spacer()
          Button("Cancel") { isPresenting = false }
            .focusable()
            .keyboardShortcut(.cancelAction)
          Button("Add") { submit() }
            .focusable()
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding()
      .frame(width: 220)
      .onAppear { nameIsFocused = true }
    }
  }

  private func submit() {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    onSubmit(name)
    name = ""
    isPresenting = false
  }
}

private extension Color {
  init(priorityHex rawValue: String?) {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#")) ?? ""
    guard value.count == 6, let hex = UInt64(value, radix: 16) else {
      self = .accentColor
      return
    }
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1)
  }
}
