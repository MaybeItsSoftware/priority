import AppKit
import Foundation
import Observation
import PriorityCore
import PriorityWorkspace
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceDesktopView: View {
  @Environment(WorkspaceViewModel.self) private var model
  private let everythingSidebarID = "priority:everything"
  @State private var isTopLevelDropTargeted = false
  @State private var floatingTimer = LocalFloatingFocusTimer()
  @FocusState private var focusedArea: WorkspaceFocusArea?

  var body: some View {
    workspace.task { await model.monitorFocus() }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reloadNextUp() }
      .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.pauseFocus() }
  }

  private var workspaceLayout: some View {
    HSplitView {
      // The sidebar stays through focus mode: setting up a session often means
      // looking at which list something came from, and losing your place in the
      // workspace to do that is its own distraction.
      sidebar
        .focusSection()
        .frame(minWidth: 155, idealWidth: 185, maxWidth: 230)
      // Focus mode takes the main pane rather than floating over it. A sheet
      // leaves the board visible round the edges, which is the one thing the
      // screen exists to stop. The timeline is the same kind of surface and
      // takes the pane the same way — it is read at the scale of a day.
      Group {
        if model.showsFocusScreen {
          WorkspaceFocusScreen()
            .environment(model)
        } else if model.showsTimelineScreen {
          WorkspaceTimelineScreen()
            .environment(model)
        } else {
          taskPane
        }
      }
      .animation(.easeInOut(duration: 0.15), value: model.showsFocusScreen)
      .animation(.easeInOut(duration: 0.15), value: model.showsTimelineScreen)
      .focusSection()
      .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
      // Selection remains light-weight; only I or an explicit inspector
      // command opens the editor and consumes the third pane.
      if model.isInspectorVisible && model.selectedTask != nil && !model.showsFocusScreen && !model.showsTimelineScreen {
        inspector
          .focusSection()
          .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)
      }
    }
    .frame(minWidth: 760, minHeight: 520)
    .onAppear {
      if model.requestedFocusArea != .tasks || (model.viewMode != .board && model.viewMode != .outline) {
        focusedArea = model.requestedFocusArea
      }
      if model.activeFocusSession != nil { floatingTimer.show(model: model) }
    }
    .onChange(of: model.focusRequest) { _, _ in
      if model.requestedFocusArea != .tasks || (model.viewMode != .board && model.viewMode != .outline) {
        focusedArea = model.requestedFocusArea
      }
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
  }

  private var workspaceAlerts: some View {
    workspaceLayout
    .alert("Start this task anyway?", isPresented: Binding(
      get: { model.focusStartOverride != nil }, set: { if !$0 { model.focusStartOverride = nil } }
    ), presenting: model.focusStartOverride) { request in
      Button("Start anyway") { model.startFocus(on: request.task, plannedSeconds: request.plannedSeconds, override: true); model.focusStartOverride = nil }
      Button("Cancel", role: .cancel) { model.focusStartOverride = nil }
    } message: { request in Text(request.explanation) }
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
    .sheet(item: Bindable(model).pendingFocusCompletion) { pending in
      WorkspaceFocusQualityPrompt(pending: pending)
        .environment(model)
    }
  }

  private var workspace: some View {
    workspaceAlerts
    .sheet(isPresented: Bindable(model).showsListNavigator) {
      WorkspaceListNavigator().environment(model)
    }
    .sheet(isPresented: Bindable(model).showsKeyboardHelp) {
      WorkspaceKeyboardHelp()
    }
    .sheet(item: Bindable(model).taskMoveRequest) { request in
      WorkspaceTaskMoveSheet(request: request)
        .environment(model)
    }
    .sheet(item: Bindable(model).taskQuickEditRequest, onDismiss: { model.requestKeyboardFocus(.tasks) }) { request in
      WorkspaceTaskQuickEditSheet(request: request)
        .environment(model)
    }
    .sheet(item: Bindable(model).creationRequest) { kind in
      WorkspaceCreationSheet(kind: kind) { name in
        switch kind {
        case .list:
          if model.creationIsNested { model.createNestedList(named: name) }
          else { model.createList(named: name, in: model.creationParentFolderID) }
        case .folder: model.createFolder(named: name, in: model.creationParentFolderID)
        }
      }
    }
    .sheet(isPresented: Bindable(model).showsSearch) {
      WorkspaceSearchSheet()
        .environment(model)
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
      HStack {
        Text("PRIORITY")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        Menu {
          Button(model.undoLabel.map { "Undo \($0)" } ?? "Undo") { model.undoLastChange() }
            .disabled(model.undoLabel == nil)
          Button(model.redoLabel.map { "Redo \($0)" } ?? "Redo") { model.redoLastUndoneChange() }
            .disabled(model.redoLabel == nil)
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Undo or redo workspace changes")
        .accessibilityLabel("Workspace history")
      }
      .padding(.horizontal, 16)
      .padding(.top, 18)
      .padding(.bottom, 12)

      WorkspaceFocusLauncher()
        .environment(model)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)

      ScrollViewReader { sidebarProxy in
      List {
        Button {
          model.selectEverything()
          model.reportKeyboardFocus(.sidebar)
        } label: {
          Label("Everything", systemImage: "square.stack.3d.up")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(everythingSidebarID)
        .listRowBackground(
          WorkspaceSidebarSelectionBackground(
            isSelected: model.isEverythingSelected && model.selectedFolderID == nil))
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
          ForEach(model.folders.filter { $0.parentFolderId == nil }) { folder in
            WorkspaceFolderTree(folder: folder)
          }
          ForEach(model.lists.filter { $0.folderId == nil && $0.systemRole != .inbox }) { list in
            sidebarListRow(list)
            WorkspaceNestedListRows(list: list)
          }
        } header: {
          HStack {
            Text("Lists")
            Spacer()
            Image(systemName: "arrow.up.left")
          }
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .background(isTopLevelDropTargeted ? Color.accentColor.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
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
      .animation(.easeInOut(duration: 0.22), value: model.lists.map { "\($0.id)/\($0.folderId ?? "root")" })
      .animation(.easeInOut(duration: 0.22), value: model.folders.map { "\($0.id)/\($0.parentFolderId ?? "root")" })
      .animation(.easeInOut(duration: 0.22), value: model.nestedLists.map { "\($0.id)/\($0.task.parentTaskId ?? "root")/\($0.task.isPromoted == true)" })
      .focusable()
      .focused($focusedArea, equals: .sidebar)
      .focusEffectDisabled()
      .onChange(of: model.focusRequest) { _, _ in
        if model.requestedFocusArea == .sidebar {
          sidebarProxy.scrollTo(model.currentSidebarID)
        }
      }
      }

      Divider()
      HStack(spacing: 8) {
        AddWorkspaceItemButton(title: "New list", systemImage: "plus") { name in
          model.createList(named: name)
        }
        AddWorkspaceItemButton(title: "New folder", systemImage: "folder.badge.plus") { name in
          model.createFolder(named: name)
        }
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
          .focusable()
          .help("Restore archived lists")
        }
      }
      .padding(10)
    }
    .background(.bar)
  }

  private func sidebarListRow(_ list: TaskList) -> some View {
    WorkspaceSelectableListRow(list: list)
      .tag(Optional(list.id))
      .id(list.id)
      .onDrag { WorkspaceTaskDrag.provider(forList: list.id) }
      .listRowBackground(
        WorkspaceSidebarSelectionBackground(
          isSelected: model.selectedFolderID == nil && model.currentSidebarID == list.id))
      .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: Binding(
        get: { model.dragDestinationListID == list.id },
        set: { model.dragDestinationListID = $0 ? list.id : nil }
      )) { providers in
        WorkspaceTaskDrag.readItemID(from: providers) { payload in
          model.moveDroppedItem(payload, toListID: list.id)
        }
      }
      .background(
        model.dragDestinationListID == list.id ? Color.accentColor.opacity(0.16) : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
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

  @ViewBuilder
  private var taskPane: some View {
    switch model.viewMode {
    case .board:
      WorkspaceKanbanBoard()
        .environment(model)
    case .outline:
      outlineTaskPane
    case .dailies:
      WorkspaceDailiesDashboard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
        .focusEffectDisabled()
    case .matrix:
      WorkspaceMatrixDashboard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
        .focusEffectDisabled()
    case .focus:
      WorkspaceFocusDashboard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
        .focusEffectDisabled()
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
        if item.task.isList { model.openItemList(item.task) } else { model.toggleTask(item.task) }
      } label: {
        Image(systemName: model.itemSymbol(for: item.task))
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
      WorkspaceTaskPlanningBadges(task: item.task).frame(maxWidth: 170, alignment: .leading)
    }
    .padding(.leading, CGFloat(item.depth) * 22)
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: item.task.id) }
    .background(
      item.task.id == model.selectedTaskID ? Color.accentColor.opacity(0.14) : .clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
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
    .focusEffectDisabled()
    .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.inspector) })
  }
}

private struct WorkspaceKanbanBoard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @State private var visibleColumnIDs: Set<String> = []

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
            GeometryReader { viewport in
              ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                  ForEach(model.boardColumns) { column in
                    WorkspaceKanbanColumnView(
                      column: column,
                      width: columnWidth,
                      height: max(100, viewport.size.height - 36))
                      .environment(model)
                      .id(column.id)
                  }
                }
                .scrollTargetLayout()
                .padding(18)
                .background(WorkspaceHorizontalOverscrollDisabler())
              }
              .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { ids in
                visibleColumnIDs = Set(ids)
              }
            }
            .onChange(of: model.activeBoardColumnID) { _, columnID in
              guard let columnID, !visibleColumnIDs.contains(columnID) else { return }
              scrollProxy.scrollTo(columnID, anchor: .center)
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
  let height: CGFloat
  @State private var isDropTargeted = false
  @State private var isAddingAtTop = false
  @State private var topTaskTitle = ""
  @State private var visibleCardIDs: Set<String> = []
  @FocusState private var topComposerFocused: Bool

  var body: some View {
    let tasks = model.tasks(in: column)
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(column.title.uppercased())
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(column.title)
        Text("\(tasks.count)")
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

      ScrollViewReader { cardProxy in
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(tasks) { task in
              WorkspaceKanbanCard(task: task, column: column)
                .environment(model)
                .id(task.id)
            }

            if tasks.isEmpty {
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
          }
          .scrollTargetLayout()
          .padding(.bottom, 2)
          .background(WorkspaceHorizontalOverscrollDisabler())
        }
        .onScrollTargetVisibilityChange(idType: String.self) { ids in
          visibleCardIDs = Set(ids)
        }
        .onChange(of: model.selectedTaskID) { _, id in
          guard let id, !visibleCardIDs.contains(id),
            tasks.contains(where: { $0.id == id }) else { return }
          cardProxy.scrollTo(id, anchor: .center)
        }
        .onAppear {
          if let id = model.selectedTaskID, tasks.contains(where: { $0.id == id }) {
            cardProxy.scrollTo(id, anchor: .center)
          }
        }
      }
    }
    .padding(12)
    .frame(width: width, alignment: .topLeading)
    .frame(height: height, alignment: .topLeading)
    .background(
      isDropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(isDropTargeted || (model.keyboardFocusArea == .tasks && model.activeBoardColumnID == column.id) ? Color.accentColor : .clear, lineWidth: 2)
    )
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
      .onChange(of: model.selectedTaskID) { _, id in
        if id == task.id && !isCardFocused { isCardFocused = true }
      }
      .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, .leftArrow, .rightArrow, "i"]) { press in
        handleCardKey(press)
      }
      .accessibilityElement(children: .contain)
      .contextMenu { WorkspaceItemActions(task: task) }
  }

  private var cardSurface: some View {
    VStack(alignment: .leading, spacing: 8) {
      cardHeading
      if !task.isList, let dueAt = task.dueAt {
        HStack(spacing: 4) {
          Image(systemName: "calendar")
          Text(dueAt, format: .dateTime.month().day())
        }.font(.caption).foregroundStyle(.secondary)
      }
      if task.isList {
        Text("List · \(model.descendants(of: task).filter { !$0.task.isList }.count) tasks")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        WorkspaceTaskPlanningBadges(task: task)
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
        if task.isList { model.openItemList(task) } else { model.toggleTask(task) }
      } label: {
        Image(systemName: model.itemSymbol(for: task))
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
      if !task.isList {
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
      }
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
        if item.task.isList { model.openItemList(item.task) } else { model.toggleTask(item.task) }
      } label: {
        Image(systemName: model.itemSymbol(for: item.task))
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

  static func provider(forList listID: String) -> NSItemProvider {
    provider(for: listPrefix + listID)
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
    .focusEffectDisabled()
    .onAppear {
      if model.keyboardFocusArea == .tasks && model.selectedTaskID == task.id {
        isRowFocused = true
      }
    }
    .onChange(of: model.focusRequest) { _, _ in
      if model.requestedFocusArea == .tasks && model.selectedTaskID == task.id {
        isRowFocused = true
      }
    }
    .onChange(of: isRowFocused) { _, focused in
      if focused {
        model.selectTask(task)
        model.reportKeyboardFocus(.tasks)
      }
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
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("FOCUS")
          .font(.title2.weight(.semibold))
        WorkspaceFocusContextControls()
        if let task = model.activeFocusTask {
          Text(task.title)
            .font(.title3.weight(.medium))
            .lineLimit(2)
            .truncationMode(.tail)
          Text("Focus mode is active. Complete the current task to advance the queue.")
            .foregroundStyle(.secondary)
          Text("\(FocusPoints.formatted(model.focusPoints.today)) points today over \(model.focusPoints.blocksToday) blocks")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
          HStack {
            Button("Complete current") { model.requestFocusCompletion() }
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
        Divider()
        Button { model.presentTimelineScreen() } label: {
          Label("See the day's timeline", systemImage: "chart.bar.doc.horizontal")
            .font(.callout)
        }
        .buttonStyle(.plain)
        .focusable()
      }
      .padding(24)
    }
  }
}

private struct WorkspaceTaskMoveSheet: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let request: WorkspaceItemMoveRequest
  @State private var destinationID: String?
  @FocusState private var destinationIsFocused: Bool

  private struct Destination: Identifiable {
    let id: String
    let name: String
    let listID: String
    let parentTaskID: String?
    var folderID: String? = nil
  }

  private var destinations: [Destination] {
    var blocked = Set<String>()
    if let taskID = request.taskID {
      blocked.insert(taskID)
      for item in (try? model.store?.outline(in: request.sourceListID, parentTaskId: taskID)) ?? [] { blocked.insert(item.id) }
    }
    let roots = model.lists.filter { request.taskID != nil || $0.id != request.sourceListID }
    let listDestinations = roots.flatMap { list in
      [Destination(id: "root:\(list.id)", name: list.name, listID: list.id, parentTaskID: nil)]
        + model.nestedLists.filter { $0.task.listId == list.id && !blocked.contains($0.id) }.map { item in
          Destination(id: item.id, name: "\(list.name) › \(item.task.title)", listID: list.id, parentTaskID: item.id)
        }
    }
    return listDestinations + model.folders.map { folder in
      Destination(id: "folder:\(folder.id)", name: "Folder: \(folder.name)", listID: "", parentTaskID: nil, folderID: folder.id)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Move to list or folder")
        .font(.title3.weight(.semibold))
      Text(request.title)
        .lineLimit(2)
        .truncationMode(.tail)
        .help(request.title)
      Picker("Destination", selection: $destinationID) {
        ForEach(destinations) { list in
          Text(list.name).tag(Optional(list.id))
        }
      }
      .focusable()
      .focused($destinationIsFocused)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
        Button("Move") {
          guard let destinationID else { return }
          guard let destination = destinations.first(where: { $0.id == destinationID }) else { return }
          if let folderID = destination.folderID { model.moveDroppedItem(request.payload, toFolderID: folderID) }
          else { model.moveDroppedItem(request.payload, toListID: destination.listID, parentTaskID: destination.parentTaskID) }
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
    .onAppear {
      destinationID = destinations.first?.id
      destinationIsFocused = true
    }
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

private struct WorkspaceItemActions: View {
  @Environment(WorkspaceViewModel.self) private var model
  let task: WorkspaceTask

  var body: some View {
    Button(task.isList ? "Open list" : "Open subtasks") { model.openItemList(task) }
    Button("Rename…") { model.taskQuickEditRequest = WorkspaceTaskQuickEditRequest(task: task, kind: .title) }
    Button(task.isList ? "Convert to task" : "Convert to list") { model.convertItem(task) }
    Button("Move to list or folder…") { model.requestMove(task) }
    Button("New nested list…") { model.requestNestedListCreation(under: task) }
    if task.isList {
      Button("Move to top level") { model.moveDroppedItem(task.id, toFolderID: nil) }
      Button(task.isPromoted == true ? "Unpin from sidebar" : "Promote to sidebar") { model.toggleListPromotion(task) }
      Menu("Choose icon") {
        ForEach(WorkspaceViewModel.availableListIcons, id: \.symbol) { icon in
          Button { model.setNestedListIcon(icon.symbol, for: task) } label: { Label(icon.label, systemImage: icon.symbol) }
        }
      }
      Divider()
      Button(task.status == .open ? "Complete list" : "Reopen list") { model.toggleTask(task) }
      Button("Archive list") { model.archiveNestedList(task) }
    }
  }
}

private struct WorkspaceSidebarSelectionBackground: View {
  @Environment(WorkspaceViewModel.self) private var model
  let isSelected: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(isSelected ? Color.accentColor.opacity(0.17) : .clear)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(
            isSelected && model.keyboardFocusArea == .sidebar ? Color.accentColor : .clear,
            lineWidth: 2)
      )
  }
}

private struct WorkspaceNestedListRows: View {
  @Environment(WorkspaceViewModel.self) private var model
  let list: TaskList

  var body: some View {
    ForEach(model.nestedLists.filter { $0.task.listId == list.id }) { item in
      WorkspaceNestedListRow(task: item.task)
        .padding(.leading, CGFloat(item.depth + 1) * 12)
    }
  }
}

private struct WorkspaceNestedListRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  let task: WorkspaceTask
  var promotedShortcut = false
  @State private var isDropTargeted = false

  var body: some View {
    Button { model.selectNestedList(task) } label: {
      HStack(spacing: 7) {
        Image(systemName: model.itemSymbol(for: task)).frame(width: 18)
        Text(task.title).lineLimit(1).truncationMode(.middle).strikethrough(task.status != .open)
        Spacer(minLength: 0)
        if promotedShortcut { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable().focusEffectDisabled()
    .id(promotedShortcut ? "promoted:\(task.id)" : task.id)
    .listRowBackground(WorkspaceSidebarSelectionBackground(
      isSelected: model.selectedFolderID == nil && model.currentSidebarID == task.id))
    .contextMenu { WorkspaceItemActions(task: task) }
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .background(isDropTargeted ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
      WorkspaceTaskDrag.readItemID(from: providers) { payload in
        model.moveDroppedItem(payload, toListID: task.listId, parentTaskID: task.id)
      }
    }
  }
}

private struct WorkspaceFolderTree: View {
  @Environment(WorkspaceViewModel.self) private var model
  let folder: ListFolder
  @State private var isDropTargeted = false

  var body: some View {
    Group {
      folderHeader
      if model.isFolderExpanded(folder) {
      ForEach(model.lists.filter { $0.folderId == folder.id && $0.systemRole != .inbox }) { list in
        WorkspaceSelectableListRow(list: list)
          .tag(Optional(list.id))
          .id(list.id)
          .onDrag { WorkspaceTaskDrag.provider(forList: list.id) }
          .listRowBackground(
            WorkspaceSidebarSelectionBackground(
              isSelected: model.selectedFolderID == nil && model.currentSidebarID == list.id))
          .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: Binding(
            get: { model.dragDestinationListID == list.id },
            set: { model.dragDestinationListID = $0 ? list.id : nil }
          )) { providers in
            WorkspaceTaskDrag.readItemID(from: providers) { payload in
              model.moveDroppedItem(payload, toListID: list.id)
            }
          }
          .background(
            model.dragDestinationListID == list.id ? Color.accentColor.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
          )
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
      .padding(.leading, 14)
      ForEach(model.folders.filter { $0.parentFolderId == folder.id }) { child in
        WorkspaceFolderTree(folder: child)
      }
      .padding(.leading, 14)
      }
    }
  }

  private var folderHeader: some View {
      HStack(spacing: 6) {
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            model.setFolderExpanded(folder, expanded: !model.isFolderExpanded(folder))
          }
        } label: {
          Image(systemName: model.isFolderExpanded(folder) ? "chevron.down" : "chevron.right")
            .font(.caption)
            .frame(width: 14, height: 20)
        }
        .accessibilityLabel(model.isFolderExpanded(folder) ? "Collapse folder" : "Expand folder")
        if model.isRenaming(.folder(folder)) {
          WorkspaceRenameField(
            initialName: folder.name,
            onCommit: { model.renameFolder(folder, to: $0) },
            onCancel: { model.cancelRenaming(itemID: folder.id) })
        } else {
          Button { model.selectFolder(folder) } label: {
            Label(folder.name, systemImage: "folder")
              .lineLimit(1)
              .truncationMode(.middle)
              .help(folder.name)
          }
        }
      }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .background(
          isDropTargeted || folder.id == model.selectedFolderID ? Color.accentColor.opacity(0.14) : .clear,
          in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(
              model.keyboardFocusArea == .sidebar && model.selectedFolderID == folder.id
                ? Color.accentColor : .clear,
              lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: $isDropTargeted) { providers in
          WorkspaceTaskDrag.readItemID(from: providers) { payload in
            model.moveDroppedItem(payload, toFolderID: folder.id)
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

private struct TaskComposer: View {
  @State private var title = ""
  @FocusState private var isFocused: Bool
  let focusRequest: Int
  let onCancel: () -> Void
  let onSubmit: (String) -> Void

  init(focusRequest: Int, onCancel: @escaping () -> Void = {}, onSubmit: @escaping (String) -> Void) {
    self.focusRequest = focusRequest
    self.onCancel = onCancel
    self.onSubmit = onSubmit
  }

  var body: some View {
    HStack {
      Image(systemName: "plus")
        .foregroundStyle(.secondary)
      TextField("Add a task", text: $title)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onSubmit { submit() }
        .onExitCommand { title = ""; isFocused = false; onCancel() }
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

/// A focused capture field owns the arrows while it is active: vertical
/// arrows file the thought, horizontal arrows defer it. A native text field
/// is used because SwiftUI's TextField consumes those commands for cursor
/// movement before a view-level key handler can see them.
private final class QuickCaptureNSTextField: NSTextField {
  var onSubmit: (() -> Void)?
  var onCancel: (() -> Void)?
  var onMoveDestination: ((Int) -> Void)?
  var onMoveStartDay: ((Int) -> Void)?

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: onSubmit?()
    case 53: onCancel?()
    case 126: onMoveDestination?(-1)
    case 125: onMoveDestination?(1)
    case 123: onMoveStartDay?(-1)
    case 124: onMoveStartDay?(1)
    default: super.keyDown(with: event)
    }
  }
}

private struct QuickCaptureTextField: NSViewRepresentable {
  @Binding var text: String
  let focusRequest: Int
  let onSubmit: () -> Void
  let onCancel: () -> Void
  let onMoveDestination: (Int) -> Void
  let onMoveStartDay: (Int) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> QuickCaptureNSTextField {
    let field = QuickCaptureNSTextField()
    field.delegate = context.coordinator
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 14, weight: .medium)
    field.placeholderString = "What needs doing?"
    return field
  }

  func updateNSView(_ field: QuickCaptureNSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    field.onSubmit = onSubmit
    field.onCancel = onCancel
    field.onMoveDestination = onMoveDestination
    field.onMoveStartDay = onMoveStartDay
    if context.coordinator.lastFocusRequest != focusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: QuickCaptureTextField
    var lastFocusRequest = -1
    init(_ parent: QuickCaptureTextField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }
  }
}

private struct GlobalQuickCaptureComposer: View {
  @Environment(WorkspaceViewModel.self) private var model
  @State private var title = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 9) {
        Image(systemName: "tray.and.arrow.down.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.tint)
        QuickCaptureTextField(
          text: $title,
          focusRequest: model.taskComposerFocusRequest,
          onSubmit: submit,
          onCancel: cancel,
          onMoveDestination: model.moveQuickCaptureDestination,
          onMoveStartDay: model.moveQuickCaptureStartDay)
          .frame(height: 22)
      }

      HStack(spacing: 8) {
        capturePill(
          icon: "arrow.up.arrow.down",
          text: model.quickCaptureDestination?.path ?? "Inbox",
          accessibility: "Destination list")
        capturePill(
          icon: "arrow.left.arrow.right",
          text: model.quickCaptureStartLabel,
          accessibility: "Start day")
        Spacer(minLength: 6)
        Text("↩ Add  ·  Esc Cancel")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(12)
    .background(
      LinearGradient(
        colors: [Color.accentColor.opacity(0.13), Color.accentColor.opacity(0.035)],
        startPoint: .topLeading, endPoint: .bottomTrailing),
      in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.3)))
  }

  private func capturePill(icon: String, text: String, accessibility: String) -> some View {
    Label(text, systemImage: icon)
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.background.opacity(0.65), in: Capsule())
      .accessibilityLabel("\(accessibility): \(text)")
  }

  private func submit() {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    model.submitQuickCapture(named: title)
    title = ""
  }

  private func cancel() {
    title = ""
    model.cancelQuickCapture()
    model.requestKeyboardFocus(.tasks)
  }
}

private struct WorkspaceScopedTaskComposer: View {
  @Environment(WorkspaceViewModel.self) private var model
  let board: Bool

  var body: some View {
    Group {
      if model.isQuickCaptureActive {
        GlobalQuickCaptureComposer()
      } else {
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
          TaskComposer(focusRequest: model.taskComposerFocusRequest, onCancel: {
            model.taskInsertionReference = nil
            model.requestKeyboardFocus(.tasks)
          }) { title in
            if board { model.createBoardTask(named: title) } else { model.createTask(named: title) }
          }
          .frame(maxWidth: .infinity)
        }
      }
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

private struct WorkspaceListNavigator: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var selection = 0
  @FocusState private var isFocused: Bool

  private struct Destination: Identifiable {
    let id: String
    let title: String
    let task: WorkspaceTask?
  }

  private var destinations: [Destination] {
    let lists = model.lists.map { Destination(id: $0.id, title: $0.name, task: nil) }
    let nested = model.nestedLists.map { Destination(id: $0.task.id, title: $0.task.title, task: $0.task) }
    return (lists + nested).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Lists and locations").font(.title3.bold())
      TextField("Find a list", text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit { openSelection() }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.downArrow) { selection = min(max(0, destinations.count - 1), selection + 1); return .handled }
        .onChange(of: query) { _, _ in selection = 0 }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
              Button { open(destination) } label: {
                Label(destination.title, systemImage: destination.task == nil ? "list.bullet" : "list.bullet.indent")
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(8)
                  .background(index == selection ? Color.accentColor.opacity(0.17) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
              }
              .buttonStyle(.plain)
              .id(index)
            }
          }
        }
        .onChange(of: selection) { _, index in proxy.scrollTo(index) }
      }
      HStack {
        Button("New list…") { dismiss(); model.requestListCreationForSelection() }
        Spacer()
        Text("↑↓ choose · Return open · Esc close").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .frame(width: 460, height: 380)
    .onAppear { isFocused = true }
    .onExitCommand { dismiss() }
  }

  private func openSelection() {
    guard destinations.indices.contains(selection) else { return }
    open(destinations[selection])
  }

  private func open(_ destination: Destination) {
    if let task = destination.task { model.selectNestedList(task) }
    else { model.selectList(destination.id) }
    dismiss()
    model.requestKeyboardFocus(.tasks)
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
        key("EE / F2", "Edit the task title; F2 also renames a sidebar list or folder")
        key("DD / NN / TT / DR", "Edit due date, notes, tags, or repeating due settings")
        key("TD / TM / CD", "Due today / tomorrow / clear due date")
        key("CN / CT", "Clear notes / tags")
        key("⌥ S / ⌥ T", "Edit start date / time estimate")
        key("0–9", "Set task priority; 0 clears it")
        key("HC", "Hide or show completed tasks")
        key("LL / GH", "Find or create a list / open Everything")
        key("SD / OO / PC", "Toggle inspector / list settings / show task progress")
        key("XX / GG", "Extract a branch as a list / open its first linked URL")
        key("Home / End / PgUp / PgDown", "Navigate to either end, or eight tasks at a time")
        key("Date picker: ← → / ↑ ↓", "Select a day / week immediately; Shift ← → changes month")
        key("Date picker: Tab", "Switch between calendar, hour, minute, and buttons")
        key("Picker: ↵ / Esc", "Save / cancel; Delete clears the selected planning value")
        key("⌘ 4–7", "View this list as Board, Outline, Dailies, or Matrix")
        key("⌘ 8", "Enter focus mode, or return to the running session")
        key("Focus: ↑ ↓ / J K", "Climb to less important work, or back down towards the most important")
        key("Focus: ↵ / Space", "Stage the task, then begin it with the estimate shown")
        key("Focus: X", "Tick the task off without starting a session")
        key("Focus: ⌥ ↑ / ↓", "Move the task itself up or down the ladder, fixing your own order")
        key("Focus: L", "Schedule it for later so it stops being offered")
        key("⌘ 9", "Open the timeline of the day's focused work, or close it")
        key("Timeline: ← → / H L", "Step back or forward a day; T returns to today")
        key("⌃ Tab / ⌃ ⇧ Tab", "Move focus forward or backward between those regions")
        key("Task surface: Tab / ⇧ Tab", "Indent / outdent; controls and text fields retain normal Tab navigation")
        key("Sidebar: ↑ ↓ / J K", "Select Everything, then its visible lists and folders")
        key("Sidebar: ← → / Return", "Collapse, expand, or toggle the selected folder")
        key("Board: ← → / Return", "Focus any column; Return opens a task or adds to an empty column")
        key("Outline: ← →", "Leave or enter a task’s subtasks")
        key("Outline: Return / ⌥ Return / ⇧ Return", "Add below / above / as a child")
        key("⇧ → / ⇧ ←", "Open the selected branch / return to its parent")
        key("Space", "Complete or reopen selected task")
        key("⇧ Space", "Invalidate or reopen selected task")
        key("⌘ ⌥ → / ←", "Indent or outdent the selected task")
        key("⌥ → / ←", "Move the selected board card to the next or previous column")
        key("⌥ 1–4", "Place the selected matrix task in a quadrant")
        key("⌘ ⇧ D", "Commit to the selected task daily, or stop")
        key("⌘ ⇧ C", "Add a board column")
        key("⌘ ↑ / ⌘ ↓", "Move the selected task, or the current list when no task is selected")
        key("Board card drop", "Drop on a sibling card to place it before that card")
        key("Delete", "Delete the selected task and its subtasks")
        key("F", "Start focus, or add to the active focus queue")
        key("MM", "Move the selected task or list, including its contents, to a list or folder")
        key("[ / ]", "Return to the parent list / open the selected task as a list")
        key("⌘ ⇧ L", "Convert selected task to a list, or list back to a task")
        key("⌘ ⇧ P", "Promote / unpin a nested list in the sidebar")
        key("⌘ ⇧ X", "Complete / reopen the current list")
        key("⌘ N", "Add a task")
        key("⌘ ⌥ [ / ]", "Choose the destination sub-list when adding in Everything")
        key("⌘ S", "Save edits in the task inspector")
        key("⌘ ⇧ N", "Create a nested list in the task pane; otherwise create a sidebar list")
        key("⌘ ⌥ N", "Create a folder; when a folder is selected, create it there")
        key("⌘ R", "Rename the selected list or folder in place")
        key("⌘ I", "Open settings for the selected list or folder")
        key("⌘ F", "Search every task’s title and notes")
        key("UU / ⌘ Z / ⌘ ⇧ Z", "Undo / undo / redo the last complete workspace action")
        key("⌘ ⇧ A / ⌘ ⇧ R", "Archive the current list / restore the most recently archived list")
        key("⌃ ⌥ ↑ / ↓", "Select the previous or next folder")
        key("⌘ ⌥ ↑ / ↓", "Reorder the selected folder among its siblings")
        key("⌘ ⇧ Delete", "Delete the selected folder or current list")
        key("? / ⌘ / / ⇧ ⇧", "Show this keyboard reference")
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

/// A list's colour, or the accent colour when it has none. Internal rather
/// than file-private because sidebar rows moved out into their own file.
extension Color {
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

/// SwiftUI has no API for disabling macOS scroll elasticity entirely.
private struct WorkspaceHorizontalOverscrollDisabler: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ nsView: Probe, context: Context) {
    nsView.disableOverscroll()
  }

  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      disableOverscroll()
    }

    func disableOverscroll() {
      DispatchQueue.main.async { [weak self] in
        self?.enclosingScrollView?.horizontalScrollElasticity = .none
      }
    }
  }
}
