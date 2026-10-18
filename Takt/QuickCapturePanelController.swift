import AppKit
import SwiftUI
import TaktCore
import TaktWorkspace

/// Quick add's own window: the global hotkey brings up a field over whatever
/// app you are in, and Return or Escape puts it away again, leaving the main
/// window where it was — or closed, if it was.
///
/// Unlike the focus panel this one *is* Spotlight-like. It holds a thought on
/// its way to the inbox, not a clock, so clicking elsewhere drops it.
@MainActor
final class QuickCapturePanelController: NSObject, NSWindowDelegate {
  /// The width of the window's own overlays — the palette, the list finder —
  /// since it is drawn as one.
  private static let width = WorkspaceOverlayMetrics.width
  /// The field, the lists it can go to, and the line of keys that steer it.
  /// The list takes whatever the other two leave.
  private static let height: CGFloat = 320
  /// Where it lands: a little above centre, as Spotlight does.
  private static let verticalAnchor: CGFloat = 0.22

  private var panel: FocusPanelWindow?
  private var interruptedApp: NSRunningApplication?
  /// When the hotkey last brought the panel up, by the uptime clock.
  private var shownAt: TimeInterval?
  /// How long after the hotkey a window of this app taking the keyboard is
  /// taken as the app settling rather than as a click away.
  private static let settleInterval: TimeInterval = 0.5
  private weak var model: WorkspaceViewModel?

  var isVisible: Bool { panel?.isVisible ?? false }

  func show(model: WorkspaceViewModel) {
    self.model = model
    // Read before the panel is ordered front: the observation chain below
    // lives for as long as the panel is visible, so a second `show` while it
    // is up must not start a second one.
    let wasVisible = isVisible
    let panel = makePanelIfNeeded(model: model)
    if !NSApp.isActive { interruptedApp = NSWorkspace.shared.frontmostApplication }
    position(panel)
    model.beginQuickCapture()
    // The panel is non-activating, so it takes the keyboard without the app
    // coming forward — the way Spotlight's does. It used to activate the app
    // as well, and activation is asynchronous: once it landed, AppKit gave
    // the keyboard back to the main window, the panel resigned key and put
    // itself away as if clicked away from, and the title typed next went to
    // the main window instead, where its `d` was the due-date command.
    shownAt = ProcessInfo.processInfo.systemUptime
    panel.orderFrontRegardless()
    panel.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak panel] in
      guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
      panel.makeKeyAndOrderFront(nil)
    }
    if !wasVisible { observeCapture(model: model) }
  }

  /// Puts the panel away and hands the keyboard back to whatever the hotkey
  /// interrupted.
  func dismiss() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    if let model, model.isQuickCaptureActive { model.cancelQuickCapture() }
    if let interruptedApp, interruptedApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      interruptedApp.activate()
    }
    interruptedApp = nil
  }

  /// Return and Escape both end the capture in the model; the panel follows.
  private func observeCapture(model: WorkspaceViewModel) {
    withObservationTracking {
      _ = model.isQuickCaptureActive
    } onChange: {
      Task { @MainActor [weak self, weak model] in
        guard let self, let model, self.isVisible else { return }
        if model.isQuickCaptureActive { self.observeCapture(model: model) } else { self.dismiss() }
      }
    }
  }

  private func makePanelIfNeeded(model: WorkspaceViewModel) -> FocusPanelWindow {
    if let panel { return panel }
    let panel = FocusPanelWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    // No shadow: the overlays in the window have none, and this is one of
    // them summoned over another app. The hairline is the edge.
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.delegate = self
    let hosting = NSHostingController(
      rootView: QuickCapturePanelView()
        .focusEffectDisabled()
        .themedBodyFont()
        .environment(model)
        .themed(AppDelegate.shared.checkvistManager.theme))
    hosting.sizingOptions = []
    panel.contentViewController = hosting
    self.panel = panel
    return panel
  }

  private func position(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    // The size is set here, every time, not only at creation: handing the
    // panel a hosting controller with no sizing options resized it to the
    // hosting view's starting frame, which is zero. The field took the
    // keyboard in a window nobody could see, so the hotkey looked dead.
    let size = NSSize(width: Self.width, height: Self.height)
    guard let frame = screen?.visibleFrame else {
      panel.setContentSize(size)
      panel.center()
      return
    }
    panel.setFrame(
      NSRect(
        origin: NSPoint(
          x: frame.midX - Self.width / 2,
          y: frame.maxY - frame.height * Self.verticalAnchor - Self.height),
        size: size),
      display: false)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard let panel, (notification.object as? NSWindow) === panel else { return }
    // A window of this app taking the keyboard in the moment after the
    // hotkey is the app settling — the main window coming back as key when
    // Takt activates — not a click away: the panel takes it back.
    if let shownAt, ProcessInfo.processInfo.systemUptime - shownAt < Self.settleInterval,
      NSApp.keyWindow != nil {
      DispatchQueue.main.async { [weak panel] in
        guard let panel, panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
      }
      return
    }
    // Clicking away is a change of mind, as it is in Spotlight. The keyboard
    // has already gone where the user sent it, so it is not handed back.
    interruptedApp = nil
    dismiss()
  }
}

/// Drawn as the window's overlays are (`WorkspaceOverlayHost`), because it
/// is one of them, summoned over another app: the raised surface and its
/// hairline at the panel radius, the field row, a rule, and under it every
/// list the capture can go to in the list finder's rows — the one it is going
/// to selected, ↑ and ↓ moving it — then the overlays' foot of keys. All of it
/// in the theme the window is in.
///
/// It holds what the field's slots hold, because two of them open something
/// in the list's place: the date slot a calendar, the conditions slot the
/// conditions finder (`cc`'s, ticking the task not yet made). While a slot
/// or either of those has the keys, they come through `WindowKeyMonitor`
/// rather than a text view.
private struct QuickCapturePanelView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var title = ""
  @State private var slots = TaskEntryDraft()
  @State private var textFocusRequest = 0
  /// The day the calendar's cursor is on, while it is open.
  @State private var calendarCursor: Date?
  /// The conditions finder, while it is open.
  @State private var conditionsRequest: WorkspaceConditionPickerRequest?

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceTitleBarAddField(
        title: $title, slots: $slots, textFocusRequest: textFocusRequest,
        onSubmit: submit, onCancel: cancel)
      FocusRule()
      if let cursor = calendarCursor {
        TaskEntryCalendarView(cursor: cursor, selected: slots.dueDate) { day in
          slots.dueDate = day
          calendarCursor = nil
        }
        WorkspaceOverlayFooter(hints: "←→↑↓ day · ⇧↑⇧↓ month · ↩ pick · ⌫ no date · esc back")
      } else if let request = conditionsRequest {
        // The finder brings its own field and foot of keys.
        WorkspaceConditionPicker(overlayID: conditionsOverlayID(request), request: request, listHeight: nil)
          .frame(maxHeight: .infinity)
      } else {
        QuickCaptureDestinationList()
          .frame(maxHeight: .infinity)
        WorkspaceOverlayFooter(hints: hints)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themedSurface(theme, fill: theme.raised, radius: theme.panelRadius)
    .background(WindowKeyMonitor(handle: handleKey))
    // Each capture starts with empty slots; the title, as before, waits for
    // the next one when the window was clicked away from.
    .onChange(of: model.isQuickCaptureActive) { _, active in
      guard active else { return }
      slots = TaskEntryDraft()
      calendarCursor = nil
      conditionsRequest = nil
    }
  }

  /// The keys that do something where the keyboard is.
  private var hints: String {
    switch slots.focus {
    case .text: "↑↓ list · → date, needs, time · ↩ add · esc cancel"
    case .date: "↑ next day · ⇧↑ next week · ↓ calendar · ⌫ none · ←→ slots · ↩ add"
    case .conditions: "↓ or space choose · ⌫ last · ←→ slots · ↩ add"
    case .estimate: "↑↓ step · 0–9 minutes · ⌫ none · ← slots · ↩ add"
    }
  }

  private func conditionsOverlayID(_ request: WorkspaceConditionPickerRequest) -> String {
    "quick-capture-conditions:\(request.id)"
  }

  /// Keys while a slot, the calendar or the conditions finder has them. In
  /// the text they are the field's own.
  private func handleKey(_ event: NSEvent) -> Bool {
    guard let key = event.workspaceCommandKey else { return false }
    if let cursor = calendarCursor {
      switch key {
      case "escape": calendarCursor = nil
      case "enter", "space":
        slots.dueDate = Calendar.current.startOfDay(for: cursor)
        calendarCursor = nil
      case "delete":
        slots.dueDate = nil
        calendarCursor = nil
      default:
        if let moved = TaskEntryCalendar.moved(cursor, by: key) {
          calendarCursor = moved
        } else if key.hasPrefix("cmd+") {
          return false
        }
      }
      return true
    }
    if let request = conditionsRequest {
      // Esc puts the finder away and leaves the keys on the slot; ⌘↩, which
      // opens the Conditions tab in the main window, does too.
      if key == "escape" || key == "cmd+enter" {
        conditionsRequest = nil
        return true
      }
      if let handler = model.overlayKeyHandler, handler.overlayID == conditionsOverlayID(request) {
        return handler.handle(key)
      }
      return false
    }
    guard slots.focus.isSlot else { return false }
    switch slots.handle(key: key) {
    case .handled:
      if slots.focus == .text { textFocusRequest += 1 }
    case .ignored:
      // ⌘Q and the like still work; anything else typed at a slot is
      // swallowed rather than sent to text that does not have the keys.
      if key.hasPrefix("cmd+") { return false }
    case .submit: submit()
    case .cancel: cancel()
    case .openCalendar:
      calendarCursor = slots.dueDate ?? Calendar.current.startOfDay(for: .now)
    case .openConditions:
      conditionsRequest = WorkspaceConditionPickerRequest(
        draftTitle: TaskCapture.parse(title).title, groups: $slots.requirementGroups)
    }
    return true
  }

  private func submit() {
    let text = title
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // Nothing to file: back to the text to type it.
      if slots.focus.isSlot {
        slots.focus = .text
        textFocusRequest += 1
      }
      return
    }
    let filed = slots
    reset()
    model.submitQuickCapture(named: text, slots: filed)
  }

  private func cancel() {
    reset()
    model.cancelAddField()
  }

  private func reset() {
    title = ""
    slots = TaskEntryDraft()
    calendarCursor = nil
    conditionsRequest = nil
  }
}

/// Where a capture can go: every list, then the nested lists under it, with
/// the one it is going to selected and the home list marked. A click picks
/// one and hands the caret back.
private struct QuickCaptureDestinationList: View {
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    let homeID = model.quickCaptureHomeList?.id
    WorkspaceDestinationRows(
      destinations: model.quickCaptureDestinations, selectedID: model.quickCaptureDestination?.id,
      note: { $0.id == homeID ? "Default" : nil },
      onPick: { destination in
        model.quickCaptureDestinationID = destination.id
        model.quickCaptureFocusRequest += 1
      })
  }
}

/// Lists and nested lists in the list finder's rows (`WorkspaceListNavigator`)
/// — the name, where it lives beside it in muted type, and the selection band
/// on the chosen one, kept in view. Quick add's destinations, and the focus
/// panel's list switcher, which puts Today above them as `header`.
struct WorkspaceDestinationRows<Header: View>: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let destinations: [QuickCaptureDestination]
  let selectedID: String?
  /// What the row says at its far end — "Default", "Current" — if anything.
  var note: (QuickCaptureDestination) -> String? = { _ in nil }
  @ViewBuilder var header: Header
  let onPick: (QuickCaptureDestination) -> Void

  init(
    destinations: [QuickCaptureDestination], selectedID: String?,
    note: @escaping (QuickCaptureDestination) -> String? = { _ in nil },
    @ViewBuilder header: () -> Header, onPick: @escaping (QuickCaptureDestination) -> Void
  ) {
    self.destinations = destinations
    self.selectedID = selectedID
    self.note = note
    self.header = header()
    self.onPick = onPick
  }

  var body: some View {
    let folderNames = Dictionary(model.folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let listFolders = Dictionary(model.lists.map { ($0.id, $0.folderId) }, uniquingKeysWith: { first, _ in first })
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          header
          ForEach(destinations) { destination in
            HStack(spacing: theme.space.sm) {
              Label(
                destination.title,
                systemImage: destination.parentTaskID == nil ? "list.bullet" : "list.bullet.indent")
                .foregroundStyle(theme.ink)
                .lineLimit(1)
              if let context = context(of: destination, folderNames: folderNames, listFolders: listFolders) {
                Text(context)
                  .foregroundStyle(theme.muted)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer(minLength: theme.space.sm)
              if let note = note(destination) {
                Text(note).font(theme.captionFont).foregroundStyle(theme.dim)
              }
            }
            .font(theme.bodyFont())
            .overlayRow(isSelected: destination.id == selectedID)
            .id(destination.id)
            .onTapGesture { onPick(destination) }
          }
        }
      }
      .onAppear { if let selectedID { proxy.scrollTo(selectedID) } }
      .onChange(of: selectedID) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
  }

  /// Where it lives, as the list finder says it: a list's folder, or the
  /// lists and nested lists a nested list sits in.
  private func context(
    of destination: QuickCaptureDestination,
    folderNames: [String: String],
    listFolders: [String: String?]
  ) -> String? {
    guard destination.parentTaskID != nil else {
      return listFolders[destination.listID]?.flatMap { folderNames[$0] }
    }
    let parents = destination.path.components(separatedBy: " › ").dropLast()
    return parents.isEmpty ? nil : parents.joined(separator: " › ")
  }
}

extension WorkspaceDestinationRows where Header == EmptyView {
  init(
    destinations: [QuickCaptureDestination], selectedID: String?,
    note: @escaping (QuickCaptureDestination) -> String? = { _ in nil },
    onPick: @escaping (QuickCaptureDestination) -> Void
  ) {
    self.init(destinations: destinations, selectedID: selectedID, note: note, header: { EmptyView() }, onPick: onPick)
  }
}
