import Foundation
import Observation
import TaktCore

@MainActor
@Observable final class PreferencesManager {
  @ObservationIgnored let preferencesStore: PreferencesStore

  @ObservationIgnored var onLaunchAtLoginChanged: ((Bool) -> Void)?
  @ObservationIgnored var onIgnoreKeychainInDebugChanged: (() -> Void)?

  var confirmBeforeDelete: Bool {
    didSet { preferencesStore.set(confirmBeforeDelete, for: .confirmBeforeDelete) }
  }
  var launchAtLogin: Bool {
    didSet {
      preferencesStore.set(launchAtLogin, for: .launchAtLogin)
      onLaunchAtLoginChanged?(launchAtLogin)
    }
  }
  var ignoreKeychainInDebug: Bool {
    didSet {
      #if DEBUG
        preferencesStore.set(ignoreKeychainInDebug, for: .ignoreKeychainInDebug)
        onIgnoreKeychainInDebugChanged?()
      #endif
    }
  }
  /// Light, dark or follow the system. Kept under its old storage key.
  var appearanceMode: AppearanceMode {
    didSet { preferencesStore.set(appearanceMode.rawValue, for: .appThemeRawValue) }
  }
  var globalHotkeyEnabled: Bool {
    didSet { preferencesStore.set(globalHotkeyEnabled, for: .globalHotkeyEnabled) }
  }
  /// Carbon keyCode for the global hotkey (default 49 = Space)
  var globalHotkeyKeyCode: Int {
    didSet { preferencesStore.set(globalHotkeyKeyCode, for: .globalHotkeyKeyCode) }
  }
  /// Carbon modifier mask (default 0x0800 = optionKey i.e. ⌥)
  var globalHotkeyModifiers: Int {
    didSet { preferencesStore.set(globalHotkeyModifiers, for: .globalHotkeyModifiers) }
  }
  /// The summoned focus panel — the one hotkey that works from inside
  /// whatever you are actually doing.
  var focusPanelHotkeyEnabled: Bool {
    didSet { preferencesStore.set(focusPanelHotkeyEnabled, for: .focusPanelHotkeyEnabled) }
  }
  /// Carbon keyCode for the focus panel hotkey (default 3 = F)
  var focusPanelHotkeyKeyCode: Int {
    didSet { preferencesStore.set(focusPanelHotkeyKeyCode, for: .focusPanelHotkeyKeyCode) }
  }
  /// Carbon modifier mask (default 0x1B00 = Hyper, matching Quick Add)
  var focusPanelHotkeyModifiers: Int {
    didSet { preferencesStore.set(focusPanelHotkeyModifiers, for: .focusPanelHotkeyModifiers) }
  }
  var quickAddHotkeyEnabled: Bool {
    didSet { preferencesStore.set(quickAddHotkeyEnabled, for: .quickAddHotkeyEnabled) }
  }
  /// Carbon keyCode for the quick add hotkey (default 45 = N)
  var quickAddHotkeyKeyCode: Int {
    didSet { preferencesStore.set(quickAddHotkeyKeyCode, for: .quickAddHotkeyKeyCode) }
  }
  /// Carbon modifier mask (default 0x1B00 = command+shift+option+control / Hyper)
  var quickAddHotkeyModifiers: Int {
    didSet { preferencesStore.set(quickAddHotkeyModifiers, for: .quickAddHotkeyModifiers) }
  }
  /// Whether opening the window lands on the focus screen rather than on
  /// Today. Off by default now that Today exists: it answers the same question
  /// — what to do next — without the ladder's conditions, time window and
  /// estimate to commit to before anything may start. A restored session
  /// overrides this either way, since a running clock is always what you came
  /// back for.
  var opensOnFocusScreen: Bool {
    didSet { preferencesStore.set(opensOnFocusScreen, for: .opensOnFocusScreen) }
  }
  /// Whether finishing a block stops to ask how it went. On by default,
  /// because the score is the thing that makes a logged hour mean something —
  /// but a day of eight blocks is eight interruptions, and someone who only
  /// wants the minutes should be able to say so once.
  var scoresEachFocusBlock: Bool {
    didSet { preferencesStore.set(scoresEachFocusBlock, for: .scoresEachFocusBlock) }
  }
  /// Where a block started on purpose runs once the window is put away. The
  /// panel by default, because that is what the app always did; the menu bar
  /// for someone who wants nothing on screen but the clock.
  var focusRunSurface: FocusRunSurface {
    didSet { preferencesStore.set(focusRunSurface.rawValue, for: .focusRunSurfaceRawValue) }
  }
  /// The workspace list the quick-add hotkey captures into. Empty is the
  /// inbox, and so is a list that has since been deleted.
  var quickCaptureListID: String {
    didSet { preferencesStore.set(quickCaptureListID, for: .quickCaptureListID) }
  }
  var showTaskBreadcrumbContext: Bool {
    didSet { preferencesStore.set(showTaskBreadcrumbContext, for: .showTaskBreadcrumbContext) }
  }

  init(preferencesStore: PreferencesStore) {
    self.preferencesStore = preferencesStore
    self.confirmBeforeDelete = preferencesStore.bool(.confirmBeforeDelete, default: true)
    self.launchAtLogin = preferencesStore.bool(.launchAtLogin, default: false)
    #if DEBUG
      self.ignoreKeychainInDebug = preferencesStore.bool(.ignoreKeychainInDebug, default: true)
    #else
      self.ignoreKeychainInDebug = true
    #endif
    self.appearanceMode =
      AppearanceMode(rawValue: preferencesStore.int(.appThemeRawValue, default: 0)) ?? .system
    self.globalHotkeyEnabled = preferencesStore.bool(.globalHotkeyEnabled, default: false)
    self.globalHotkeyKeyCode = preferencesStore.int(
      .globalHotkeyKeyCode,
      default: AppCoordinator.CarbonKey.space
    )
    self.globalHotkeyModifiers = preferencesStore.int(
      .globalHotkeyModifiers,
      default: AppCoordinator.CarbonModifier.option
    )
    self.focusPanelHotkeyEnabled = preferencesStore.bool(.focusPanelHotkeyEnabled, default: true)
    self.focusPanelHotkeyKeyCode = preferencesStore.int(
      .focusPanelHotkeyKeyCode,
      default: AppCoordinator.CarbonKey.f
    )
    self.focusPanelHotkeyModifiers = preferencesStore.int(
      .focusPanelHotkeyModifiers,
      default: AppCoordinator.CarbonModifier.hyper
    )
    self.quickAddHotkeyEnabled = preferencesStore.bool(.quickAddHotkeyEnabled, default: true)
    self.quickAddHotkeyKeyCode = preferencesStore.int(
      .quickAddHotkeyKeyCode,
      default: AppCoordinator.CarbonKey.n
    )
    self.quickAddHotkeyModifiers = preferencesStore.int(
      .quickAddHotkeyModifiers,
      default: AppCoordinator.CarbonModifier.hyper
    )
    self.opensOnFocusScreen = preferencesStore.bool(.opensOnFocusScreen, default: false)
    self.scoresEachFocusBlock = preferencesStore.bool(.scoresEachFocusBlock, default: true)
    self.focusRunSurface =
      FocusRunSurface(rawValue: preferencesStore.int(.focusRunSurfaceRawValue, default: 0)) ?? .panel
    self.quickCaptureListID = preferencesStore.string(.quickCaptureListID)
    self.showTaskBreadcrumbContext = preferencesStore.bool(.showTaskBreadcrumbContext, default: false)

    // Move untouched installs from the old, opt-in Shift-Option-B capture to
    // the product default. A customised binding is never rewritten.
    if !preferencesStore.bool(.quickAddHyperNMigrationCompleted, default: false) {
      if quickAddHotkeyKeyCode == AppCoordinator.CarbonKey.b,
        quickAddHotkeyModifiers == AppCoordinator.CarbonModifier.shiftOption
      {
        quickAddHotkeyEnabled = true
        quickAddHotkeyKeyCode = AppCoordinator.CarbonKey.n
        quickAddHotkeyModifiers = AppCoordinator.CarbonModifier.hyper
      }
      preferencesStore.set(true, for: .quickAddHyperNMigrationCompleted)
    }
  }

  /// The typed-command language's dates (`due tomorrow morning`), at the
  /// parser's own hours for the named times. The hours used to be settings,
  /// but nothing the window can reach parses a typed command any more (see
  /// `TODO.md`, "The typed-command language"), so they changed nothing.
  func resolveDueDate(_ input: String) -> String {
    CommandEngine.resolveDueDate(input, config: TaktDateParsingConfig())
  }
}
