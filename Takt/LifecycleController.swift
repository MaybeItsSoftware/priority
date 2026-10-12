import Foundation
import TaktCore
import ServiceManagement

/// Owns the wiring that has to happen exactly once during `AppCoordinator`
/// construction: the managers' callback fan-out and launch at login.
/// Splitting this out shrinks `AppCoordinator` itself and keeps "what fires
/// when" readable in one place.
///
/// The controller intentionally holds a `weak` reference to `AppCoordinator`:
/// the coordinator owns the controller, every callback originates from a
/// child manager that the coordinator also owns, so a strong reference here
/// would form a cycle. `start()` is called from `AppCoordinator.init`.
@MainActor
final class LifecycleController {
  private weak var coordinator: AppCoordinator?

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
  }

  func start() {
    setupChildCallbacks()
    syncLaunchAtLogin()
  }

  // MARK: - Child callbacks

  private func setupChildCallbacks() {
    guard let coordinator else { return }

    // These are single closure slots, not multicast, so the diagnostics record
    // has to be chained onto the existing behaviour rather than added beside it.
    coordinator.integrations.onError = { [weak coordinator] err in
      guard let coordinator, let err else { return }
      coordinator.statusMessage = err
      coordinator.diagnosticsLog.record(category: "Integrations", message: err, isFailure: true)
    }
    coordinator.integrations.onStatus = { [weak coordinator] message in
      coordinator?.statusMessage = message
      coordinator?.diagnosticsLog.record(
        category: "Integrations", message: message, isFailure: false)
    }

    coordinator.preferences.onLaunchAtLoginChanged = { [weak self] newValue in
      self?.applyLaunchAtLoginChange(newValue)
    }

    #if DEBUG
      coordinator.preferences.onIgnoreKeychainInDebugChanged = { [weak coordinator] in
        coordinator?.handleCredentialStorageModeChanged()
      }
    #endif
  }

  // MARK: - Launch at login

  private var shouldSuppressLaunchAtLoginAvailabilityError: Bool {
    #if DEBUG
      let env = ProcessInfo.processInfo.environment
      return env["XCODE_VERSION_ACTUAL"] != nil || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    #else
      return false
    #endif
  }

  private func applyLaunchAtLoginChange(_ newValue: Bool) {
    guard let coordinator else { return }
    if coordinator.isApplyingLaunchAtLoginChange { return }
    guard #available(macOS 13.0, *) else { return }
    do {
      if newValue {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      let nsError = error as NSError
      if nsError.domain == SMAppServiceErrorDomain && nsError.code == 1 {
        if !shouldSuppressLaunchAtLoginAvailabilityError {
          coordinator.statusMessage =
            "Launch at login is unavailable for this app build. Install in /Applications and try again."
        }
      } else {
        coordinator.statusMessage =
          "Launch at login failed: \(error.localizedDescription)"
      }
      if newValue {
        coordinator.isApplyingLaunchAtLoginChange = true
        coordinator.preferences.launchAtLogin = false
        coordinator.isApplyingLaunchAtLoginChange = false
      }
    }
  }

  private func syncLaunchAtLogin() {
    guard let coordinator else { return }
    guard #available(macOS 13.0, *) else { return }
    let registered = SMAppService.mainApp.status == .enabled
    if registered != coordinator.preferences.launchAtLogin {
      coordinator.isApplyingLaunchAtLoginChange = true
      coordinator.preferences.launchAtLogin = registered
      coordinator.isApplyingLaunchAtLoginChange = false
    }
  }
}
