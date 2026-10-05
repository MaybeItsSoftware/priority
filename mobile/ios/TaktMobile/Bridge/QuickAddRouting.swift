import Foundation
import UIKit

/// Opens the quick-add sheet when the Control Center control (or the Quick add
/// shortcut) asks for it — straight away if the app is running, or on the
/// next activation if the request arrived before the workspace was open.
@MainActor
enum QuickAddRouting {
  private static var observer: NSObjectProtocol?

  static func install(on model: WorkspaceModel) {
    QuickAddRequest.handler = { [weak model] in
      guard let model else { return }
      open(model)
    }
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak model] _ in
      MainActor.assumeIsolated {
        guard let model, QuickAddRequest.takePending() else { return }
        open(model)
      }
    }
    if QuickAddRequest.takePending() { open(model) }
  }

  static func open(_ model: WorkspaceModel) {
    model.navigation.quickAddListID = nil
    model.navigation.quickAddParentTaskID = nil
    model.navigation.isQuickAddPresented = true
  }
}
