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
  @Environment(\.theme) private var theme
  /// The sidebar width the current divider drag started from, so the gesture
  /// measures a translation rather than accumulating deltas.
  @State private var dragStartWidth: CGFloat?
  @FocusState private var focusedArea: WorkspaceFocusArea?
  @State private var doneDragStartWidth: CGFloat?

  var body: some View {
    workspace
      // Over the whole window content, so it sits above every pane and a
      // click anywhere outside the panel lands on its catcher.
      .overlay(alignment: .top) { WorkspaceOverlayHost() }
      .task { await model.monitorFocus() }
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
        WorkspaceSidebarPane(focusedArea: $focusedArea)
          .focusSection()
          .frame(width: model.sidebarWidth)
        sidebarResizeHandle
      }
      mainAndInspector
      // Outside the split view, and on the same terms as the left sidebar: an
      // explicit width and a handle. Inside `HSplitView` it was a third pane
      // dividing what was already spoken for, and on a window with nothing
      // spare it was laid out at no width at all — which is the same thing as
      // not being there.
      //
      // Gone while a full-pane screen is up: focus is the one place the app
      // should not be showing you a tally, and the timeline is already a reading
      // of the same day at greater length.
      if model.isDoneRailVisible && !model.showsFocusScreen && !model.showsTimelineScreen {
        doneRailResizeHandle
        WorkspaceDoneRail()
          .environment(model)
          // Claimed the way the sidebar claims its own area: a `requestedFocusArea`
          // no view answers to is handed straight back, so the rail would take the
          // keyboard and lose it again on the next layout pass.
          .focusable()
          .focusEffectDisabled()
          .focused($focusedArea, equals: .done)
          .focusSection()
          .frame(width: model.doneRailWidth)
      }
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

  /// The sidebar's handle mirrored. Dragging left widens the rail, so the
  /// translation is subtracted.
  private var doneRailResizeHandle: some View {
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
                let base = doneDragStartWidth ?? model.doneRailWidth
                if doneDragStartWidth == nil { doneDragStartWidth = base }
                model.doneRailWidth = min(
                  max(base - value.translation.width, WorkspaceViewModel.minDoneRailWidth),
                  WorkspaceViewModel.maxDoneRailWidth)
              }
              .onEnded { _ in doneDragStartWidth = nil }
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
      //
      // `hasSelectedTask` rather than `selectedTask`: this body holds the whole
      // window, and reading the selection itself would redraw all of it on
      // every arrow key.
      if model.isInspectorVisible && model.hasSelectedTask && !model.showsFocusScreen && !model.showsTimelineScreen {
        WorkspaceInspectorPane(focusedArea: $focusedArea)
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
    // A sheet rather than an overlay on purpose. A finished block's clock is
    // held open until it is scored, and an overlay goes away on any click
    // outside it — which here would throw a block's judgement away by accident.
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
    // Diagnostics needs a titled window to attach a sheet to, and this is the
    // only one the app has. `CommandExecutor` and the Workspace menu have always
    // said it was a sheet on the main window and opened that window first to get
    // one — but nothing here presented it, so both set the flag and showed you
    // the workspace. The popover was the only surface that ever put it on screen.
    //
    // It stays a sheet rather than an overlay: it is a report as tall as the
    // window, with Copy and Export buttons, read and then put away — not
    // something you pass through on the way to the next keystroke.
    .sheet(isPresented: Bindable(manager.popoverChrome).showsDiagnostics) {
      DiagnosticsView()
        .environment(manager)
        .frame(minWidth: 620, minHeight: 520)
    }
    // A multi-field form — name, colour, icon, folder, visible root — edited
    // with the mouse as often as not. Converting it is a redesign, not a move.
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
      WorkspaceOutlinePane()
    case .matrix:
      WorkspaceMatrixDashboard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
        .focusEffectDisabled()
    }
  }
}

struct WorkspaceItemActions: View {
  @Environment(WorkspaceViewModel.self) private var model
  let task: WorkspaceTask

  var body: some View {
    Button(task.isList ? "Open list" : "Open subtasks") { model.openItemList(task) }
    Button("Rename…") { model.presentOverlay(.quickEdit(WorkspaceTaskQuickEditRequest(task: task, kind: .title))) }
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

struct TaskComposer: View {
  @Environment(\.theme) private var theme
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
        .foregroundStyle(theme.muted)
      TextField("Add a task", text: $title)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onSubmit { submit() }
        .onExitCommand { title = ""; isFocused = false; onCancel() }
      // The field you type into most often, and the only way to know you could
      // have got here with a key was to find it in the palette.
      if !isFocused, title.isEmpty {
        KeyCap(WorkspaceCommandHelpText.firstKey(for: .taskNew))
      }
    }
    .padding(theme.space.sm)
    .background(theme.well, in: RoundedRectangle(cornerRadius: theme.controlRadius))
    .overlay(
      RoundedRectangle(cornerRadius: theme.controlRadius)
        .strokeBorder(isFocused ? theme.focusRing : theme.inputBorder,
          lineWidth: isFocused ? theme.focusRingWidth : theme.hairline))
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
            .commandHelp(.listNewTaskDestination, note: "Choose the sub-list for new tasks")
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
