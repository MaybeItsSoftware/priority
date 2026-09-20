import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
class GlobalShortcutManager {
  private enum RegisteredHotkeyID: UInt32 {
    case togglePopover = 1
    case quickAdd = 2
    case focusPanel = 3
  }

  private static let globalHotkeySignature = OSType(0x4356_464B)  // "CVFK"

  private var globalHotkeyRef: EventHotKeyRef?
  private var quickAddHotkeyRef: EventHotKeyRef?
  private var focusPanelHotkeyRef: EventHotKeyRef?
  private let manager: AppCoordinator
  private var cancellables = Set<AnyCancellable>()

  // Event handlers
  var onTogglePopover: (() -> Void)?
  var onQuickAdd: (() -> Void)?
  var onToggleFocusPanel: (() -> Void)?

  init(manager: AppCoordinator) {
    self.manager = manager
    setupEventHandler()
    registerGlobalHotkeys()
    observeForHotkeyChanges()
  }

  private func setupEventHandler() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
    )

    let handler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
      guard let eventRef else { return noErr }
      var hotKeyID = EventHotKeyID()
      let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
      )
      guard status == noErr else { return noErr }

      // Dispatch to main thread
      Task { @MainActor in
        AppDelegate.shared.shortcutManager?.handleGlobalHotkeyPressed(id: hotKeyID.id)
      }
      return noErr
    }

    InstallEventHandler(
      GetApplicationEventTarget(),
      handler,
      1,
      &eventType,
      nil,
      nil
    )
  }

  func handleGlobalHotkeyPressed(id: UInt32) {
    guard let registeredID = RegisteredHotkeyID(rawValue: id) else { return }
    switch registeredID {
    case .togglePopover:
      onTogglePopover?()
    case .quickAdd:
      onQuickAdd?()
    case .focusPanel:
      onToggleFocusPanel?()
    }
  }

  private func registerGlobalHotkeys() {
    unregisterGlobalHotkeys()

    if manager.preferences.globalHotkeyEnabled {
      globalHotkeyRef = registerHotkey(
        id: .togglePopover,
        keyCode: manager.preferences.globalHotkeyKeyCode,
        modifiers: manager.preferences.globalHotkeyModifiers
      )
    }
    if manager.preferences.focusPanelHotkeyEnabled {
      focusPanelHotkeyRef = registerHotkey(
        id: .focusPanel,
        keyCode: manager.preferences.focusPanelHotkeyKeyCode,
        modifiers: manager.preferences.focusPanelHotkeyModifiers
      )
    }
    if manager.preferences.quickAddHotkeyEnabled {
      quickAddHotkeyRef = registerHotkey(
        id: .quickAdd,
        keyCode: manager.preferences.quickAddHotkeyKeyCode,
        modifiers: manager.preferences.quickAddHotkeyModifiers
      )
    }
  }

  private func registerHotkey(id: RegisteredHotkeyID, keyCode: Int, modifiers: Int)
    -> EventHotKeyRef?
  {
    var hotKeyRef: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: Self.globalHotkeySignature, id: id.rawValue)
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      UInt32(modifiers),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    return status == noErr ? hotKeyRef : nil
  }

  func unregisterGlobalHotkeys() {
    if let ref = globalHotkeyRef {
      UnregisterEventHotKey(ref)
      globalHotkeyRef = nil
    }
    if let ref = quickAddHotkeyRef {
      UnregisterEventHotKey(ref)
      quickAddHotkeyRef = nil
    }
    if let ref = focusPanelHotkeyRef {
      UnregisterEventHotKey(ref)
      focusPanelHotkeyRef = nil
    }
  }

  private func observeForHotkeyChanges() {
    withObservationTracking {
      _ = manager.preferences.globalHotkeyEnabled
      _ = manager.preferences.globalHotkeyKeyCode
      _ = manager.preferences.globalHotkeyModifiers
      _ = manager.preferences.focusPanelHotkeyEnabled
      _ = manager.preferences.focusPanelHotkeyKeyCode
      _ = manager.preferences.focusPanelHotkeyModifiers
      _ = manager.preferences.quickAddHotkeyEnabled
      _ = manager.preferences.quickAddHotkeyKeyCode
      _ = manager.preferences.quickAddHotkeyModifiers
    } onChange: {
      Task { @MainActor [weak self] in
        self?.registerGlobalHotkeys()
        self?.observeForHotkeyChanges()
      }
    }
  }
}
