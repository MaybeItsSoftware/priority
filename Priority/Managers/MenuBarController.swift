import AppKit
import Combine
import OSLog
import Observation
import PriorityCore
import PriorityWorkspace
import SwiftUI

@MainActor
class MenuBarController: NSObject {
  private struct TitleCacheInputs: Equatable {
    let taskText: String
    let timerText: String?
    let maxWidth: CGFloat
    let timerLeading: Bool
  }

  private var statusItem: NSStatusItem!
  private var window: NSWindow?
  private var keyMonitor: Any?
  private var clickMonitor: Any?

  private var cachedTitleInputs: TitleCacheInputs?
  private var cachedTitleResult: String?
  private var cachedGradientWidth: CGFloat?
  private var cachedGradientLayer: CAGradientLayer?
  private var lastToggleTime: Date = Date.distantPast
  /// Top-right anchor (screen coords) captured when the popover is shown.
  /// Used by re-anchor on tab/column changes so the popover doesn't drift
  /// horizontally as the menu bar title resizes the status item button.
  private var pinnedTopRight: NSPoint?

  private let manager: AppCoordinator
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "keyboard")

  var onShowSettings: (() -> Void)?
  var onShowMainWindow: (() -> Void)?
  var onShowFocusPanel: (() -> Void)?
  var onQuit: (() -> Void)?
  /// The local workspace owns task state. In this mode the status item is a
  /// launcher, not a miniature task view.
  var usesDesktopWorkspace = false {
    didSet { updateTitle() }
  }
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
    observeForPopoverSizing()
    setupGlobalMonitors()
  }

  deinit {
    if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = shiftMonitor { NSEvent.removeMonitor(monitor) }
    focusTicker?.invalidate()
  }

  private var shiftMonitor: Any?
  private var shiftTaps = DoubleTapModifier()

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    statusItem.button?.action = #selector(clicked)
    statusItem.button?.target = self
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  private func setupGlobalMonitors() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let popoverWindow = self.window, popoverWindow.isVisible else { return event }
      guard event.window === popoverWindow else { return event }
      self.shiftTaps.keyPressed()
      return self.handleSupplementalKey(event: event) ? nil : event
    }
    installShiftMonitorIfNeeded()
  }

  /// ⇧⇧ opens the command palette, as it does in Checkvist.
  ///
  /// A modifier alone produces no key-down, so this cannot be a binding in
  /// `ConfigurableShortcutAction` — it is a separate monitor over flag changes,
  /// with the key-down monitor feeding it so that Shift held for a capital
  /// letter is a chord rather than a tap. See `DoubleTapModifier`.
  private func installShiftMonitorIfNeeded() {
    guard shiftMonitor == nil else { return }
    shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      guard let self, let window = self.window, window.isVisible else { return event }
      guard event.window === window else { return event }
      let flags = event.modifierFlags
      let fired = self.shiftTaps.modifierChanged(
        isDown: flags.contains(.shift),
        otherModifiersHeld: !flags.isDisjoint(with: [.command, .option, .control]),
        at: event.timestamp
      )
      if fired { self.openCommandPalette() }
      // Never consumed: other views still need to know about Shift.
      return event
    }
  }

  private func openCommandPalette() {
    manager.quickEntry.keyBuffer = ""
    manager.quickEntry.quickEntryMode = .command
    manager.quickEntry.quickEntryText = ""
    manager.quickEntry.commandSuggestionIndex = 0
    manager.quickEntry.isQuickEntryFocused = true
  }

  private var currentPopoverContentSize: NSSize {
    NSSize(
      width: PopoverLayout.preferredWidth(for: manager),
      height: PopoverLayout.preferredHeight(for: manager)
    )
  }

  /// What the menu bar is pointed at.
  ///
  /// Normally the selected task, but the Daily view renders the log rather than
  /// the task list, so `visibleTasks` is empty there and `currentTaskText` came
  /// back empty however you moved the cursor — the title just sat at "…". A
  /// `Daily` isn't a `CheckvistTask`, so this can't be folded into
  /// `currentTask` alongside the kanban branch; the split has to be on the text.
  private var menuBarSelectionText: String {
    if manager.taskListViewModel.rootTaskView == .daily {
      return manager.dailyLog.selectedDaily?.title ?? ""
    }
    return manager.taskListViewModel.currentTaskText
  }

  func updateTitle() {
    guard !usesDesktopWorkspace else {
      if showFocusSessionTitle() { return }
      stopFocusTicker()
      // The desktop workspace still needs a menu-bar launcher, but spelling
      // out "Priority" turns it into a conspicuously wide status item. Keep
      // it at the standard menu-bar icon footprint instead.
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
      return
    }
    statusItem?.button?.image = nil
    statusItem?.button?.imagePosition = .noImage
    let rawTaskText = menuBarSelectionText
    let baseTaskText = menuBarDisplayTaskText(rawTaskText)
    let taskText =
      manager.integrations.pendingSyncMenuBarPrefix.isEmpty
      ? baseTaskText
      : "\(manager.integrations.pendingSyncMenuBarPrefix): \(baseTaskText)"
    if taskText.isEmpty {
      statusItem?.button?.attributedTitle = NSAttributedString(string: "…")
      statusItem?.button?.toolTip = nil
      statusItem?.length = NSStatusItem.variableLength
      statusItem?.button?.layer?.mask = nil
      return
    }

    let pStyle = NSMutableParagraphStyle()
    pStyle.lineBreakMode = .byClipping
    let menuBarFontSize = NSFont.menuBarFont(ofSize: 0).pointSize
    let font = Typography.taskNSFont(ofSize: menuBarFontSize, name: manager.preferences.appFontName)
    let horizontalPadding: CGFloat = 16
    let currentTaskId = manager.taskListViewModel.currentTask?.id
    let elapsedForCurrentTask = currentTaskId.map { manager.taskListViewModel.totalElapsed(forTaskId: $0) } ?? 0
    let timerStr = manager.timer.timerBarString(
      currentTaskId: currentTaskId,
      totalElapsedForCurrentTask: elapsedForCurrentTask
    )
    let timerVisible = timerStr != nil

    let requestedMaxWidth: CGFloat = CGFloat(manager.preferences.maxTitleWidth)
    let maxWidth: CGFloat
    if let timerStr {
      let timerOnlyWidth = NSAttributedString(
        string: timerStr, attributes: [.font: font]
      ).size().width
      // Never allow settings width to hide an active timer.
      maxWidth = max(requestedMaxWidth, timerOnlyWidth + horizontalPadding)
    } else {
      maxWidth = requestedMaxWidth
    }

    let contentWidth = max(0, maxWidth - horizontalPadding)
    let titleInputs = TitleCacheInputs(
      taskText: taskText,
      timerText: timerStr,
      maxWidth: contentWidth,
      timerLeading: manager.timer.timerBarLeading
    )
    let text: String
    if let cached = cachedTitleInputs, let cachedResult = cachedTitleResult,
      cached == titleInputs
    {
      text = cachedResult
    } else {
      text = fittedMenuTitle(
        taskText: taskText,
        timerStr: timerStr,
        maxContentWidth: contentWidth,
        font: font,
        timerLeading: manager.timer.timerBarLeading
      )
      cachedTitleInputs = titleInputs
      cachedTitleResult = text
    }
    let displayText = text.isEmpty ? "…" : text

    let attrString = NSAttributedString(
      string: displayText, attributes: [.paragraphStyle: pStyle, .font: font])

    let textWidth = attrString.size().width
    let finalWidth = min(textWidth + horizontalPadding, maxWidth)

    statusItem?.length = finalWidth
    statusItem?.button?.attributedTitle = attrString
    statusItem?.button?.toolTip = nil
    statusItem?.button?.wantsLayer = true

    if timerVisible {
      // Timer text must remain legible; clipping is already handled on task text.
      statusItem?.button?.layer?.mask = nil
    } else if textWidth > finalWidth - 16 {
      // Reuse gradient layer if width hasn't changed.
      if cachedGradientWidth != finalWidth {
        let maskLayer = CAGradientLayer()
        maskLayer.frame = CGRect(x: 0, y: 0, width: finalWidth, height: 22)
        maskLayer.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        maskLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        maskLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        let fadeStart = (finalWidth - 24) / finalWidth
        maskLayer.locations = [0.0, NSNumber(value: fadeStart), 1.0]
        cachedGradientWidth = finalWidth
        cachedGradientLayer = maskLayer
      }
      statusItem?.button?.layer?.mask = cachedGradientLayer
    } else {
      statusItem?.button?.layer?.mask = nil
    }
  }

  private static let menuBarTagRegex: NSRegularExpression = {
    guard let regex = try? NSRegularExpression(pattern: "([@#][a-zA-Z0-9_\\-]+)") else {
      fatalError("Invalid regex pattern for menu bar tags.")
    }
    return regex
  }()

  private func menuBarDisplayTaskText(_ rawText: String) -> String {
    let range = NSRange(rawText.startIndex..., in: rawText)
    let withoutTags = Self.menuBarTagRegex.stringByReplacingMatches(
      in: rawText, range: range, withTemplate: "")
    let collapsedWhitespace = withoutTags.replacingOccurrences(
      of: "\\s+", with: " ", options: .regularExpression)
    return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func clippedMenuTitleTaskText(_ taskText: String, maxWidth: CGFloat, font: NSFont)
    -> String
  {
    func width(of text: String) -> CGFloat {
      NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    guard !taskText.isEmpty else { return "…" }
    guard maxWidth > 0 else { return String(taskText.prefix(1)) }

    if width(of: taskText) <= maxWidth { return taskText }
    let ellipsis = "…"
    if width(of: ellipsis) > maxWidth {
      let chars = Array(taskText)
      var low = 1
      var high = chars.count
      var best = String(chars.prefix(1))
      while low <= high {
        let mid = (low + high) / 2
        let candidate = String(chars.prefix(mid))
        if width(of: candidate) <= maxWidth {
          best = candidate
          low = mid + 1
        } else {
          high = mid - 1
        }
      }
      return best
    }

    let chars = Array(taskText)
    var low = 0
    var high = chars.count
    var best = ellipsis

    while low <= high {
      let mid = (low + high) / 2
      let candidate = String(chars.prefix(mid)) + ellipsis
      if width(of: candidate) <= maxWidth {
        best = candidate
        low = mid + 1
      } else {
        high = mid - 1
      }
    }

    return best
  }

  private func fittedMenuTitle(
    taskText: String,
    timerStr: String?,
    maxContentWidth: CGFloat,
    font: NSFont,
    timerLeading: Bool
  ) -> String {
    func width(of text: String) -> CGFloat {
      NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    guard maxContentWidth > 0 else {
      if let timerStr, !timerStr.isEmpty { return String(timerStr.prefix(1)) }
      return String(taskText.prefix(1))
    }
    guard let timerStr, !timerStr.isEmpty else {
      return clippedMenuTitleTaskText(taskText, maxWidth: maxContentWidth, font: font)
    }

    if width(of: timerStr) > maxContentWidth {
      return clippedMenuTitleTaskText(timerStr, maxWidth: maxContentWidth, font: font)
    }

    let separator = " "
    let full =
      timerLeading ? "\(timerStr)\(separator)\(taskText)" : "\(taskText)\(separator)\(timerStr)"
    if width(of: full) <= maxContentWidth { return full }

    let chars = Array(taskText)
    let ellipsis = "…"
    var low = 0
    var high = chars.count
    var best: String = clippedMenuTitleTaskText(timerStr, maxWidth: maxContentWidth, font: font)

    while low <= high {
      let mid = (low + high) / 2
      let candidateTask: String
      if mid == chars.count {
        candidateTask = taskText
      } else if mid == 0 {
        candidateTask = ellipsis
      } else {
        candidateTask = String(chars.prefix(mid)) + ellipsis
      }

      let candidate =
        timerLeading
        ? "\(timerStr)\(separator)\(candidateTask)"
        : "\(candidateTask)\(separator)\(timerStr)"

      if width(of: candidate) <= maxContentWidth {
        best = candidate
        low = mid + 1
      } else {
        high = mid - 1
      }
    }

    return best
  }

  private func handleSupplementalKey(event: NSEvent) -> Bool {
    let router = KeyboardShortcutRouter(
      manager: manager,
      logger: logger,
      updateTitle: { [weak self] in self?.updateTitle() },
      closeWindow: { [weak self] in self?.closeWindow() }
    )
    return router.handle(event: event, hostWindow: window)
  }

  private func makeWindowIfNeeded() -> PriorityPanel {
    if let existing = window as? PriorityPanel { return existing }

    let contentSize = currentPopoverContentSize
    let popoverWindow = PriorityPanel(
      contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
      styleMask: [.nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    popoverWindow.titleVisibility = .hidden
    popoverWindow.titlebarAppearsTransparent = true
    popoverWindow.isOpaque = false
    popoverWindow.backgroundColor = .clear
    popoverWindow.hasShadow = true
    popoverWindow.level = .floating
    popoverWindow.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

    let hostingController = NSHostingController(
      rootView: PopoverView()
        .focusEffectDisabled()
        .font(Typography.interfaceFont)
        .environment(manager)
        .environment(manager.navigationState)
        .environment(manager.taskListViewModel)
        .environment(manager.repository)
    )
    popoverWindow.contentViewController = hostingController
    popoverWindow.isMovableByWindowBackground = false
    window = popoverWindow

    if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      guard let self, let popoverWindow = self.window, popoverWindow.isVisible else { return }
      let clickLocation = event.locationInWindow
      if !popoverWindow.frame.contains(clickLocation) && event.window == nil {
        self.closeWindow()
      }
    }

    return popoverWindow
  }

  func closeWindow() {
    window?.orderOut(nil)
    pinnedTopRight = nil
    if manager.quickEntry.quickEntryMode == .dueDatePicker {
      manager.quickEntry.dismissDueDatePicker()
    } else if [.addSibling, .addChild, .quickAddDefault, .quickAddSpecific].contains(
      manager.quickEntry.quickEntryMode)
    {
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.quickEntryMode = .search
    }
    manager.quickEntry.isQuickEntryFocused = false
    updateTitle()
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    if isSecondaryStatusItemClickEvent(NSApp.currentEvent) {
      showStatusItemContextMenu()
      return
    }
    // The status item is now a launcher for the desktop workspace. The old
    // task panel is no longer presented from any user-facing path.
    onShowMainWindow?()
  }

  private func showStatusItemContextMenu() {
    let menu = NSMenu()
    menu.addItem(withTitle: "Open Main Window", action: #selector(menuMainWindow), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Focus Panel", action: #selector(menuFocusPanel), keyEquivalent: "")
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

  func showPopoverWindow() {
    // Opening the popover is the app's reliable "the user is here" signal, and
    // both halves of this are idempotent within a logical day — so this is where
    // the day's plan gets snapshotted and a closed day gets mirrored into
    // Obsidian, rather than on a background ticker nobody asked for.
    manager.dailyLog.refreshForToday()

    let popoverWindow = makeWindowIfNeeded()
    guard let button = statusItem.button else { return }
    if popoverWindow.isVisible {
      popoverWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let btnRect = button.convert(button.bounds, to: nil)
    guard let buttonWindow = button.window else { return }
    let screenRect = buttonWindow.convertToScreen(btnRect)
    let paddingY: CGFloat = 4
    let trX = screenRect.maxX
    let trY = screenRect.minY - paddingY

    let anchor = NSPoint(x: trX, y: trY)
    pinnedTopRight = anchor
    popoverWindow.setAnchoredTopRight(
      contentSize: currentPopoverContentSize, topRight: anchor, display: true
    )
    popoverWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func togglePopover() {
    let now = Date()
    guard now.timeIntervalSince(lastToggleTime) > 0.2 else { return }
    lastToggleTime = now

    let popoverWindow = makeWindowIfNeeded()
    if popoverWindow.isVisible {
      closeWindow()
    } else {
      showPopoverWindow()
    }
  }

  private func reanchorPopoverToStatusItem() {
    guard let popoverWindow = window, popoverWindow.isVisible else { return }
    // Use the anchor captured when the popover opened so the title-driven
    // status item width doesn't shift the popover sideways on tab switches.
    // Fall back to the live status item rect if the cache is missing.
    let anchor: NSPoint
    if let cached = pinnedTopRight {
      anchor = cached
    } else if let button = statusItem?.button, let buttonWindow = button.window {
      let btnRect = button.convert(button.bounds, to: nil)
      let screenRect = buttonWindow.convertToScreen(btnRect)
      anchor = NSPoint(x: screenRect.maxX, y: screenRect.minY - 4)
    } else {
      return
    }
    if let panel = popoverWindow as? PriorityPanel {
      panel.setAnchoredTopRight(
        contentSize: currentPopoverContentSize, topRight: anchor, display: true
      )
    }
  }

  private func observeForPopoverSizing() {
    withObservationTracking {
      _ = self.manager.taskListViewModel.rootTaskView
      // Everything the dock row can change about the panel's height. Without
      // these the SwiftUI content would resize inside a window that stayed the
      // old size, so the panel would clip instead of growing.
      _ = self.manager.popoverChrome.panelHeightOverrides
      _ = self.manager.popoverChrome.isResizeHandleVisible
      _ = self.manager.popoverChrome.showsDailyChart
      _ = self.manager.popoverChrome.showsDailyCompletions
      _ = self.manager.popoverChrome.showsMatrixUnplaced
      // Prompt modes contribute transient height. In particular, the `dd`
      // calendar is taller than the list panel it opens from; observing the
      // mode lets the AppKit window grow with the SwiftUI content and shrink
      // again when the picker is dismissed.
      _ = self.manager.quickEntry.quickEntryMode
    } onChange: {
      Task { @MainActor [weak self] in
        self?.reanchorPopoverToStatusItem()
        self?.observeForPopoverSizing()
      }
    }
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
      _ = self.menuBarSelectionText
      // The Daily view's cursor and its list. `selectedDaily` reads the plugin
      // directly, which isn't observable — `revision` is the app-side signal
      // that the dailies themselves changed (added, archived, rescheduled, or
      // written by the MCP server), so without it the title would keep naming a
      // daily that had left today's list.
      _ = self.manager.dailyLog.selectedDailyIndex
      _ = self.manager.dailyLog.revision
      _ = self.manager.timer.timerBarLeading
      _ = self.manager.timer.timerRunning
      _ = self.manager.timer.timedTaskId
      _ = self.manager.timer.timerByTaskId
      _ = self.manager.timer.timerMode
      _ = self.manager.preferences.maxTitleWidth
      _ = self.manager.integrations.pendingObsidianSyncTaskIds
      _ = self.manager.repository.tasks
      _ = self.manager.navigationState.currentParentId
      _ = self.manager.navigationState.currentSiblingIndex
      _ = self.manager.repository.isLoading
      _ = self.manager.repository.errorMessage
      // Starting or ending a session swaps the status item between launcher
      // and clock; the per-second redraw is the ticker's job, not this one's.
      _ = self.workspace?.activeFocusSession
    } onChange: {
      Task { @MainActor [weak self] in
        self?.updateTitle()
        self?.observeForTitleUpdates()
      }
    }
  }
}

class AnchorView: NSView {}

class PriorityPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func setAnchoredTopRight(contentSize: NSSize, topRight: NSPoint, display: Bool) {
    let frameSize = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
    let origin = NSPoint(x: topRight.x - frameSize.width, y: topRight.y - frameSize.height)
    super.setFrame(NSRect(origin: origin, size: frameSize), display: display)
  }
}
