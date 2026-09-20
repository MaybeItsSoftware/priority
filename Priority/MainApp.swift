import PriorityCore
import SwiftUI

/// The real entry point, so `--mcp-server` is handled before AppKit starts.
///
/// `MCPServerShim.run()` replaces the process image with the bundled `priority`
/// CLI, so nothing here gets as far as opening a window-server connection for a
/// process that only ever speaks JSON-RPC on stdio.
@main
enum PriorityEntryPoint {
  static func main() {
    if MCPServerShim.isLaunchMode(arguments: CommandLine.arguments) {
      MCPServerShim.run()
    }
    MainApp.main()
  }
}

struct MainApp: App {
  // AppDelegate owns the single AppCoordinator instance
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .undoRedo) {
        Button("Undo") { AppDelegate.shared.workspace.applyHistoryFromMenu(redo: false) }
          .keyboardShortcut("z", modifiers: .command)
        Button("Redo") { AppDelegate.shared.workspace.applyHistoryFromMenu(redo: true) }
          .keyboardShortcut("z", modifiers: [.command, .shift])
      }
      CommandGroup(replacing: .appSettings) {
        Button("Preferences...") {
          AppDelegate.shared.menuSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
      }
      // Only visible once the main window puts the app in `.regular` — an
      // accessory app has no menu bar to hang these off. They exist so a
      // windowed user has a discoverable route to everything the keyboard
      // already does, and so the window can be reopened after it is closed.
      CommandGroup(after: .windowList) {
        Button("Priority") {
          AppDelegate.shared.showMainWindow()
        }
        .keyboardShortcut("0", modifiers: .command)
      }
      CommandMenu("View") {
        // Same order the tab strip uses, so the menu and the strip cannot
        // disagree about what the tabs are or which order they are in.
        //
        // Read from the static rather than through `AppDelegate.shared`: this
        // list is built while SwiftUI evaluates `body`, and the adaptor has not
        // made the delegate by then — `shared` is still nil and the implicit
        // unwrap trapped every launch. The *actions* below may reach through it
        // freely, because a click cannot happen before the app has finished
        // starting.
        ForEach(AppCoordinator.storedRootTaskViewOrder, id: \.rawValue) { scope in
          Button(scope.title) {
            AppDelegate.shared.checkvistManager.taskNavigationService.setRootTaskView(scope)
          }
        }
        Divider()
        Button("Refresh") {
          Task { await AppDelegate.shared.checkvistManager.syncService.fetchTopTask() }
        }
        .keyboardShortcut("r", modifiers: .command)
        Button("Diagnostics") {
          AppDelegate.shared.showMainWindow()
          AppDelegate.shared.checkvistManager.popoverChrome.showsDiagnostics = true
        }
      }
      CommandMenu("Workspace") {
        Button("Focus Sidebar") {
          AppDelegate.shared.workspace.requestKeyboardFocus(.sidebar)
        }
        .keyboardShortcut("1", modifiers: .command)
        Button("Focus Task Outline") {
          AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
        }
        .keyboardShortcut("2", modifiers: .command)
        Button("Focus Inspector") {
          AppDelegate.shared.workspace.requestKeyboardFocus(.inspector)
        }
        .keyboardShortcut("3", modifiers: .command)
        Divider()
        Button("New Task") {
          AppDelegate.shared.workspace.requestTaskComposerFocus()
        }
        .keyboardShortcut("n", modifiers: .command)
        Button("New List") {
          AppDelegate.shared.workspace.requestListCreationForSelection()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        Button("New Folder") {
          AppDelegate.shared.workspace.requestFolderCreationForSelection()
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
        Divider()
        Button("List Settings…") {
          AppDelegate.shared.workspace.showSelectedListSettings()
        }
        .keyboardShortcut("i", modifiers: .command)
        Button("Archive Current List") {
          AppDelegate.shared.workspace.archiveSelectedList()
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        Button("Restore Most Recently Archived List") {
          AppDelegate.shared.workspace.restoreMostRecentlyArchivedList()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        Divider()
        Button("Keyboard Help") {
          AppDelegate.shared.workspace.showsKeyboardHelp = true
        }
        .keyboardShortcut("/", modifiers: .command)
      }
    }
  }
}
