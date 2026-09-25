import AppKit
import Observation
import PriorityCore
import PriorityWorkspace

@MainActor
class MenuBarController: NSObject {
  private var statusItem: NSStatusItem!
  private let manager: AppCoordinator

  var onShowSettings: (() -> Void)?
  var onShowMainWindow: (() -> Void)?
  var onShowFocusPanel: (() -> Void)?
  var onQuit: (() -> Void)?
  /// The local workspace, read only for the focus session the status item
  /// reports. Weak because the workspace outlives nothing here.
  weak var workspace: WorkspaceViewModel? {
    didSet {
      observeForTitleUpdates()
      updateTitle()
    }
  }
  /// Drives the once-a-second redraw, and exists only while a session runs.
  private var focusTicker: Timer?

  init(manager: AppCoordinator) {
    self.manager = manager
    super.init()
    setupStatusItem()
    observeForTitleUpdates()
  }

  deinit {
    focusTicker?.invalidate()
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    statusItem.button?.action = #selector(clicked)
    statusItem.button?.target = self
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  /// The status item says what is next, or what is running. That is all it says.
  ///
  /// It used to be a miniature Checkvist task view: the selected task's text,
  /// clipped to a width preference, with the legacy timer beside it and a
  /// gradient mask fading the overflow. `usesDesktopWorkspace` was set to true
  /// at launch and never anywhere else, so that whole path — and the binary
  /// search that fitted the text — has been unreachable since the desktop
  /// workspace became the app.
  func updateTitle() {
    if showFocusSessionTitle() { return }
    stopFocusTicker()
    if showDayTitle() { return }
    // A launcher still needs an icon, but spelling out "Priority" turns it into
    // a conspicuously wide status item. Keep it at the standard menu-bar icon
    // footprint instead.
    statusItem?.button?.title = ""
    statusItem?.button?.attributedTitle = NSAttributedString(string: "")
    let image = NSImage(
      systemSymbolName: "checkmark.circle",
      accessibilityDescription: "Open Priority")
    image?.isTemplate = true
    statusItem?.button?.image = image
    statusItem?.button?.imagePosition = .imageOnly
    statusItem?.button?.toolTip = "Open Priority"
    statusItem?.length = NSStatusItem.squareLength
    statusItem?.button?.layer?.mask = nil
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    if isSecondaryStatusItemClickEvent(NSApp.currentEvent) {
      showStatusItemContextMenu()
      return
    }
    showStatusItemContextMenu()
  }

  /// The status item's menu: today's tasks, then the ways into the app.
  ///
  /// Clicking used to open the main window, which made the menu bar a launcher
  /// and nothing more. Listing the day here is the point of having a status
  /// item at all — you can see what is on, and start any of it, without the
  /// app coming to the front.
  private func showStatusItemContextMenu() {
    let menu = NSMenu()
    appendDayItems(to: menu)
    menu.addItem(withTitle: "Focus Panel", action: #selector(menuFocusPanel), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Open Main Window", action: #selector(menuMainWindow), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Preferences…", action: #selector(menuSettings), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Priority", action: #selector(menuQuit), keyEquivalent: "")
      .target = self
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  /// Today as menu items, each of which starts a focus session on the task.
  /// Adds nothing at all when the day is empty, rather than a "Nothing on
  /// today" row that would have to be explained.
  private func appendDayItems(to menu: NSMenu) {
    guard let workspace else { return }
    let day = workspace.dayItems
    guard !day.isEmpty else { return }

    let header = NSMenuItem(title: "Today", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    let running = workspace.activeFocusTask?.id
    for item in day.prefix(Self.dayMenuLimit) {
      let entry = NSMenuItem(
        title: Self.truncatedFocusTitle(item.task.title, limit: 44),
        action: #selector(menuStartFocus(_:)), keyEquivalent: "")
      entry.target = self
      entry.representedObject = item.task.id
      entry.indentationLevel = 1
      // The reason rides along as the item's state rather than more text: a
      // menu of tasks should read as a list of tasks.
      if item.task.id == running { entry.state = .on }
      if let reason = item.reason { entry.toolTip = reason.label }
      menu.addItem(entry)
    }
    if day.count > Self.dayMenuLimit {
      let more = NSMenuItem(
        title: "\(day.count - Self.dayMenuLimit) more…", action: #selector(menuFocusPanel),
        keyEquivalent: "")
      more.target = self
      more.indentationLevel = 1
      menu.addItem(more)
    }
    menu.addItem(.separator())
  }

  /// Past this the menu is a list you scan rather than a day you read, and the
  /// focus panel is the better surface for it.
  private static let dayMenuLimit = 8

  private func isSecondaryStatusItemClickEvent(_ event: NSEvent?) -> Bool {
    guard let event else { return false }
    if event.type == .rightMouseUp || event.type == .rightMouseDown { return true }
    return event.type == .leftMouseUp && event.modifierFlags.contains(.control)
  }

  @objc private func menuSettings() {
    onShowSettings?()
  }

  @objc private func menuMainWindow() {
    onShowMainWindow?()
  }

  @objc private func menuFocusPanel() {
    onShowFocusPanel?()
  }

  @objc private func menuQuit() {
    onQuit?()
  }

  /// Starts a session on the task the menu item carries, overriding whatever
  /// is running — picking a different task from the day is a decision to work
  /// on that instead, not a request to queue it behind the current block.
  @objc private func menuStartFocus(_ sender: NSMenuItem) {
    guard let workspace, let id = sender.representedObject as? String,
      let task = workspace.task(withID: id)
    else { return }
    workspace.startFocus(on: task, override: true)
  }

  // MARK: - Focus session in the menu bar

  /// Replaces the launcher icon with the task being focused and its clock.
  /// Returns false when no session is running, leaving the icon to the caller.
  ///
  /// The point of putting it here is that the menu bar is the one surface
  /// visible while you are working in another app — a focus timer you have to
  /// switch away to read is a timer you stop consulting.
  private func showFocusSessionTitle() -> Bool {
    guard let workspace,
      let session = workspace.activeFocusSession,
      session.phase != .finished,
      let task = workspace.activeFocusTask
    else { return false }

    startFocusTickerIfNeeded()
    let reading = FocusTimerDisplay.reading(
      since: session.startedAt, planned: TimeInterval(session.workDurationSeconds))
    let title = "\(Self.truncatedFocusTitle(task.title))  \(reading.text)"

    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: Self.clippingParagraphStyle]
    // Overrun is coloured rather than re-worded: the clock already says `+`,
    // and a second signal in the same place would just be noise.
    if reading.isOverrun { attributes[.foregroundColor] = NSColor.systemOrange }

    statusItem?.button?.image = nil
    statusItem?.button?.imagePosition = .noImage
    statusItem?.button?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    statusItem?.button?.toolTip = "Focusing: \(task.title)"
    statusItem?.length = NSStatusItem.variableLength
    statusItem?.button?.layer?.mask = nil
    return true
  }

  /// Names the next thing on today, with how much is left behind it.
  /// Returns false when today is empty, leaving the launcher icon to the caller.
  ///
  /// This is the constant reminder: the status item is the one part of the app
  /// visible while you work in something else, and an icon that only says the
  /// app exists reminds you of nothing. The clock takes precedence over it,
  /// because while a session runs the answer to "what now" is already settled.
  private func showDayTitle() -> Bool {
    guard let workspace else { return false }
    let day = workspace.dayItems
    guard let next = day.first else { return false }

    let remaining = day.count - 1
    let title = remaining > 0
      ? "\(Self.truncatedFocusTitle(next.task.title, limit: 24))  +\(remaining)"
      : Self.truncatedFocusTitle(next.task.title)
    let font = NSFont.menuBarFont(ofSize: 0)
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: Self.clippingParagraphStyle]
    // Overdue is the one state worth colouring: it is the only reason a task
    // is on today that you were supposed to have acted on already.
    if next.reason == .overdue { attributes[.foregroundColor] = NSColor.systemOrange }

    statusItem?.button?.image = nil
    statusItem?.button?.imagePosition = .noImage
    statusItem?.button?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    statusItem?.button?.toolTip = day.count == 1
      ? "1 task today — click for the list"
      : "\(day.count) tasks today — click for the list"
    statusItem?.length = NSStatusItem.variableLength
    statusItem?.button?.layer?.mask = nil
    return true
  }

  /// Long titles are clipped here rather than by the status item, so the clock
  /// keeps its place instead of being the part that falls off the end.
  private static func truncatedFocusTitle(_ title: String, limit: Int = 28) -> String {
    guard title.count > limit else { return title }
    return title.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
  }

  private static let clippingParagraphStyle: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byClipping
    return style
  }()

  private func startFocusTickerIfNeeded() {
    guard focusTicker == nil else { return }
    let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.updateTitle() }
    }
    // Common mode, or the clock freezes while a menu is open or a window is
    // being dragged — exactly when a glance at it is most likely.
    RunLoop.main.add(ticker, forMode: .common)
    focusTicker = ticker
  }

  private func stopFocusTicker() {
    focusTicker?.invalidate()
    focusTicker = nil
  }

  private func observeForTitleUpdates() {
    withObservationTracking {
      _ = self.manager.repository.isLoading
      _ = self.manager.repository.errorMessage
      // Starting or ending a session swaps the status item between launcher
      // and clock; the per-second redraw is the ticker's job, not this one's.
      _ = self.workspace?.activeFocusSession
      // And the day itself, so the reminder names what is actually next rather
      // than whatever was next when the app launched.
      _ = self.workspace?.todayPlan
      _ = self.workspace?.focusLadder
    } onChange: {
      Task { @MainActor [weak self] in
        self?.updateTitle()
        self?.observeForTitleUpdates()
      }
    }
  }
}
