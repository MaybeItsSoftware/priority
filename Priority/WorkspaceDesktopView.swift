import AppKit
import Foundation
import Observation
import PriorityCore
import PriorityWorkspace
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceDesktopView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(AppCoordinator.self) private var manager
  private let everythingSidebarID = "priority:everything"
  @State private var isTopLevelDropTargeted = false
  /// The sidebar width the current divider drag started from, so the gesture
  /// measures a translation rather than accumulating deltas.
  @State private var dragStartWidth: CGFloat?
  @FocusState private var focusedArea: WorkspaceFocusArea?

  var body: some View {
    workspace.task { await model.monitorFocus() }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reloadNextUp() }
      .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.pauseFocus() }
  }

  private var workspaceLayout: some View {
    // The sidebar sits outside the `HSplitView` and carries its own divider.
    //
    // Inside it, the column was a resizable pane like any other, so the split
    // view handed it a share of any width the window had spare — on a wide
    // display it opened at 367pt having been asked for 185. Worse, once that
    // laid-out width was being remembered it ratcheted: each launch started
    // wider than the last. An explicit width can only be changed by dragging
    // the handle, which is the behaviour "remember what I dragged it to"
    // actually needs.
    HStack(spacing: 0) {
      // The sidebar stays through focus mode: setting up a session often means
      // looking at which list something came from, and losing your place in the
      // workspace to do that is its own distraction.
      if model.isSidebarVisible {
        sidebar
          .focusSection()
          .frame(width: model.sidebarWidth)
        sidebarResizeHandle
      }
      mainAndInspector
    }
    .frame(minWidth: 760, minHeight: 520)
  }

  /// A one-point rule with an eight-point grab area either side of it: the
  /// visible line stays a hairline while the target stays something you can
  /// actually hit.
  private var sidebarResizeHandle: some View {
    Divider()
      .frame(width: 1)
      .overlay(
        Rectangle()
          .fill(Color.clear)
          .frame(width: 9)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
          }
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .onChanged { value in
                let base = dragStartWidth ?? model.sidebarWidth
                if dragStartWidth == nil { dragStartWidth = base }
                model.sidebarWidth = min(
                  max(base + value.translation.width, WorkspaceViewModel.minSidebarWidth),
                  WorkspaceViewModel.maxSidebarWidth)
              }
              .onEnded { _ in dragStartWidth = nil }
          )
      )
  }

  private var mainAndInspector: some View {
    HSplitView {
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
    .onAppear {
      if model.requestedFocusArea != .tasks || (model.viewMode != .board && model.viewMode != .outline) {
        focusedArea = model.requestedFocusArea
      }
    }
    .onChange(of: model.focusRequest) { _, _ in
      if model.requestedFocusArea != .tasks || (model.viewMode != .board && model.viewMode != .outline) {
        focusedArea = model.requestedFocusArea
      }
    }
    .onChange(of: focusedArea) { _, area in
      model.reportKeyboardFocus(area)
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
    .sheet(item: Binding(
      get: { model.windowFocusCompletion },
      set: { if $0 == nil { model.cancelFocusCompletion() } }
    )) { pending in
      WorkspaceFocusQualityPrompt(pending: pending)
        .environment(model)
    }
  }

  private var workspace: some View {
    workspaceAlerts
    .sheet(isPresented: Bindable(model).showsListNavigator) {
      WorkspaceListNavigator().environment(model)
    }
    .sheet(isPresented: Bindable(model).showsCommandPalette) {
      WorkspaceCommandPalette()
    }
    .sheet(isPresented: Bindable(model).showsKeyboardHelp) {
      WorkspaceKeyboardHelp()
    }
    // Diagnostics needs a titled window to attach a sheet to, and this is the
    // only one the app has. `CommandExecutor` and the Workspace menu have always
    // said it was a sheet on the main window and opened that window first to get
    // one — but nothing here presented it, so both set the flag and showed you
    // the workspace. The popover was the only surface that ever put it on screen.
    .sheet(isPresented: Bindable(manager.popoverChrome).showsDiagnostics) {
      DiagnosticsView()
        .environment(manager)
        .frame(minWidth: 620, minHeight: 520)
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
            .fontWeight(model.isCurrentSidebarRow(everythingSidebarID) ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(everythingSidebarID)
        .listRowBackground(
          WorkspaceSidebarSelectionBackground(
            isCurrent: model.isCurrentSidebarRow(everythingSidebarID),
            rowID: "row:everything"))
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
      // A sidebar row is otherwise given the height AppKit reserves for a
      // two-line source-list item, which on a list of one-line names reads as
      // double spacing.
      .environment(\.defaultMinListRowHeight, 22)
      .animation(.easeInOut(duration: 0.22), value: model.lists.map { "\($0.id)/\($0.folderId ?? "root")" })
      .animation(.easeInOut(duration: 0.22), value: model.folders.map { "\($0.id)/\($0.parentFolderId ?? "root")" })
      .animation(.easeInOut(duration: 0.22), value: model.nestedLists.map { "\($0.id)/\($0.task.parentTaskId ?? "root")/\($0.task.isPromoted == true)" })
      .focusable()
      .focused($focusedArea, equals: .sidebar)
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

  private func sidebarListRow(_ list: TaskList, isLastInGroup: Bool = false) -> some View {
    WorkspaceSelectableListRow(list: list)
      .tag(Optional(list.id))
      .id(list.id)
      .onDrag { WorkspaceTaskDrag.provider(forList: list.id) }
      .listRowBackground(
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

  @ViewBuilder
  private var taskPane: some View {
    switch model.viewMode {
    case .today:
      // The same view the hotkey summons over other apps. One component, two
      // mounts: the day cannot read differently depending on where you open it.
      DayView(surface: .window, resetToken: model.dayPresentationCount)
        .environment(model)
        .background(Color(nsColor: .textBackgroundColor))
    case .board:
      WorkspaceKanbanBoard()
        .environment(model)
    case .outline:
      outlineTaskPane
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
    if model.isMultiListScope || model.selectedList != nil {
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
          if model.isMultiListScope {
            // Grouped by list, because the point of a combined view is seeing
            // where each task came from. A folder shows only its own lists.
            ForEach(model.scopeLists) { list in
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
          .foregroundStyle(item.task.status == .open ? Color.secondary : model.themeColor(.success))
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
        Text(model.isMultiListScope
          ? "Place work across every list in scope; each task keeps its own list and project."
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
      if model.isMultiListScope, let list = model.list(for: task) {
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

struct WorkspaceItemActions: View {
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
struct WorkspaceSidebarSelectionBackground: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  var isCurrent = false
  var rowID: String?

  private var hasKeyboard: Bool { model.keyboardFocusArea == .sidebar }
  private var isCursor: Bool { hasKeyboard && rowID.map(model.isSidebarCursorRow) == true }

  private var fill: Double {
    if isCurrent { return isCursor ? 0.24 : 0.13 }
    return isCursor ? 0.12 : 0
  }

  private var border: Color {
    if isCursor { return theme.focusRing }
    return isCurrent ? theme.color(.primary, opacity: 0.55) : .clear
  }

  var body: some View {
    RoundedRectangle(cornerRadius: theme.controlRadius)
      .fill(theme.color(.primary, opacity: fill))
      .overlay(
        RoundedRectangle(cornerRadius: theme.controlRadius)
          .strokeBorder(border, lineWidth: isCursor ? theme.focusRingWidth : theme.hairline)
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
    HStack(spacing: 7) {
      Image(systemName: model.itemSymbol(for: task)).frame(width: 18)
      Text(task.title)
        .lineLimit(1)
        .truncationMode(.middle)
        .strikethrough(task.status != .open)
        .fontWeight(model.isCurrentSidebarRow(task.id) ? .semibold : .regular)
      Spacer(minLength: 0)
      if promotedShortcut { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .onTapGesture { model.selectNestedList(task) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(task.title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.selectNestedList(task) }
    .focusable().focusEffectDisabled()
    .id(promotedShortcut ? "promoted:\(task.id)" : task.id)
    .listRowBackground(WorkspaceSidebarSelectionBackground(
      isCurrent: model.isCurrentSidebarRow(task.id),
      rowID: promotedShortcut ? "pinned:\(task.id)" : "nested:\(task.listId):\(task.id)"))
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
          .listRowBackground(
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
        WorkspaceNestedListRows(list: list)
      }
      .padding(.leading, 14)
      let childFolders = model.folders.filter { $0.parentFolderId == folder.id }
      ForEach(childFolders) { child in
        WorkspaceFolderTree(folder: child, isLastInGroup: child.id == childFolders.last?.id)
      }
      .padding(.leading, 14)
      }
    }
  }

  private var isCurrent: Bool { model.selectedFolderID == folder.id }

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
          Label(folder.name, systemImage: "folder")
            .fontWeight(isCurrent ? .semibold : .regular)
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
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
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

struct TaskComposer: View {
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

struct WorkspaceScopedTaskComposer: View {
  @Environment(WorkspaceViewModel.self) private var model
  let board: Bool

  var body: some View {
    Group {
      if model.isQuickCaptureActive {
        GlobalQuickCaptureComposer()
      } else {
        HStack(spacing: 10) {
          if model.isMultiListScope {
            Picker("In list", selection: Bindable(model).newTaskListID) {
              ForEach(model.scopeLists) { list in
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

/// The full keyboard reference, read off the same catalogue the keys are.
///
/// It used to be seventy rows typed out by hand next to a switch statement
/// that did the actual work, so the two could disagree and did — it credited
/// `u` with undo months after `u` became something else. Nothing here is
/// written twice: a row exists because a command exists, and prints the key
/// that command is bound to.
///
/// ⌘K reaches the same list and can run what it lands on; this stays for the
/// times the question really is "show me everything" rather than "do this".
private struct WorkspaceKeyboardHelp: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  private var groups: [(name: String, commands: [WorkspaceCommand])] {
    var order: [String] = []
    var byGroup: [String: [WorkspaceCommand]] = [:]
    for command in WorkspaceCommandCatalog.all {
      if byGroup[command.group] == nil { order.append(command.group) }
      byGroup[command.group, default: []].append(command)
    }
    return order.map { ($0, byGroup[$0] ?? []) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Keyboard reference").font(.title3.weight(.semibold))
        Spacer()
        Button("Done") { dismiss() }
          .focusable()
          .keyboardShortcut(.defaultAction)
      }
      Text("⌘K opens the same list and runs what you pick.")
        .font(.callout)
        .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(groups, id: \.name) { group in
            VStack(alignment: .leading, spacing: 8) {
              Text(group.name)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .kerning(1.2)
                .foregroundStyle(.secondary)
              ForEach(group.commands) { command in
                row(command)
              }
            }
          }
        }
        .padding(.trailing, 6)
      }
      .frame(maxHeight: 520)
    }
    .padding(28)
    .frame(width: 560)
  }

  private func row(_ command: WorkspaceCommand) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(command.title)
        if let note = command.note {
          Text(note).font(.caption).foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: 12)
      if command.surface != .anywhere {
        Text(command.surface.title)
          .font(.system(size: 9, weight: .bold))
          .textCase(.uppercase)
          .kerning(1.1)
          .foregroundStyle(.quaternary)
      }
      KeyCapRow(keys: command.displayKeys)
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
struct WorkspaceHorizontalOverscrollDisabler: NSViewRepresentable {
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
