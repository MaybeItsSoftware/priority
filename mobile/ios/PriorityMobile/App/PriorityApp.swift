import PrioritySync
import PriorityWorkspace
import SwiftUI

@main
struct PriorityApp: App {
  @State private var boot = Boot()
  @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system
  @Environment(\.scenePhase) private var scenePhase

  init() {
    Typeface.applyChrome()
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let model = boot.model {
          RootView()
            .environment(model)
            .onOpenURL { url in DeepLink.handle(url, model: model) }
            .task { DeepLink.handleLaunchArguments(model: model) }
            .onChange(of: scenePhase) { _, phase in
              if phase == .active {
                model.startWatchingExternalWrites()
                Task { await model.checkExternalWrites() }
                SyncController.shared?.sceneBecameActive()
              } else {
                model.stopWatchingExternalWrites()
                if phase == .background { SyncController.shared?.sceneLeftForeground() }
              }
            }
        } else {
          LaunchFailureView(message: boot.failure ?? "")
        }
      }
      .preferredColorScheme(appearance.colorScheme)
      .tint(Palette.primary)
      .font(Typeface.body)
    }
    .backgroundTask(.appRefresh(SyncController.refreshTaskID)) {
      await SyncController.shared?.backgroundRefresh()
    }
  }
}

/// Opens the workspace once, for the life of the process.
@MainActor
@Observable
final class Boot {
  let model: WorkspaceModel?
  let failure: String?

  init() {
    do {
      let model = try WorkspaceModel.live()
      self.model = model
      self.failure = nil
      AppServices.install(on: model)
    } catch {
      self.model = nil
      self.failure = error.localizedDescription
    }
  }
}

/// Hooks for features that live outside the screens — the widget bridge, the
/// Live Activity — installed once the workspace is open. Each feature adds a
/// line here.
@MainActor
enum AppServices {
  static func install(on model: WorkspaceModel) {
    for installer in featureInstallers { installer(model) }
  }
}

struct LaunchFailureView: View {
  let message: String

  var body: some View {
    VStack(spacing: Metrics.md) {
      Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Palette.danger)
      Text("Priority couldn't open its workspace").font(Typeface.title)
      Text(message).font(Typeface.caption).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
    }
    .padding(Metrics.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.paper)
  }
}

/// `priority://` links from the widgets, the Control Center control and the
/// Live Activity.
@MainActor
enum DeepLink {
  /// DEBUG: `-demo` seeds a sample workspace and `-open <url>` follows a
  /// link at launch, so screenshots can be scripted without tapping.
  static func handleLaunchArguments(model: WorkspaceModel) {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-demo"), model.structure.lists.count <= 1 { model.seedDemo(); model.reloadStructureNow() }
    if arguments.contains("-seed5000"), !model.structure.lists.contains(where: { $0.name.hasPrefix("Seed") }) {
      model.seedTasks()
    }
    if let index = arguments.firstIndex(of: "-open"), arguments.indices.contains(index + 1),
      let url = URL(string: arguments[index + 1]) {
      handle(url, model: model)
    }
    #endif
  }

  static func handle(_ url: URL, model: WorkspaceModel) {
    if url.scheme == SyncPairingLink.scheme {
      // Settings shows the attempt and, if it fails, why — a bad link or an
      // unreachable server is a message there, never a crash or a no-op.
      guard let sync = SyncController.shared else {
        model.errorMessage = "Sync isn't available in this build."
        return
      }
      model.navigation.isSettingsPresented = true
      model.navigation.isSyncSettingsPresented = true
      guard let link = SyncPairingLink(url.absoluteString) else {
        sync.pairingError = "That isn't a Priority pairing link."
        return
      }
      Task {
        if await sync.pair(with: link) {
          model.showToast("Paired")
        } else {
          model.showToast("Couldn't pair")
        }
      }
      return
    }
    guard url.scheme == "priority" else { return }
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    switch url.host() {
    case "add":
      model.navigation.quickAddListID = nil
      model.navigation.quickAddParentTaskID = nil
      model.navigation.isQuickAddPresented = true
    case "today": model.navigation.go(to: .today, isPad: isPad)
    case "focus": model.navigation.go(to: .focus, isPad: isPad)
    case "review": model.navigation.go(to: .review, isPad: isPad)
    case "search": model.navigation.go(to: .search, isPad: isPad)
    case "lists":
      model.navigation.go(to: .lists, isPad: isPad)
      if let name = url.pathComponents.dropFirst().first?.removingPercentEncoding,
        let list = model.structure.lists.first(where: { $0.name == name }) {
        model.navigation.open(.list(list.id), isPad: isPad)
      }
    #if DEBUG
    case "demo": model.seedDemo()
    case "seed": model.seedTasks()
    #endif
    case "task":
      if let id = url.pathComponents.dropFirst().first {
        model.navigation.go(to: .today, isPad: isPad)
        model.navigation.inspect(id, isPad: isPad)
      }
    default: break
    }
  }
}
