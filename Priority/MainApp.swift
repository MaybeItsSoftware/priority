import PriorityCore
import PriorityWorkspace
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
        // Deliberately without ⌘0: that key means Everything, and a menu item
        // shadows the workspace's own handler whenever the window is up —
        // which is the only time this item is reachable at all, since a closed
        // window leaves the app an accessory with no menu bar.
        Button("Priority") {
          AppDelegate.shared.showMainWindow()
        }
      }
      // Into AppKit's own View menu rather than a second one beside it. A
      // window with a toolbar is given that menu whether or not anything is
      // put in it, so declaring `CommandMenu("View")` produced two menus with
      // the same name — the system's holding Enter Full Screen, and ours
      // holding everything you would go to that menu for.
      CommandGroup(after: .toolbar) {
        // The places you can actually be, in the order the toolbar strip shows
        // them. This menu used to list the old Checkvist root views, a Refresh
        // and a Diagnostics button — the previous app's furniture, still
        // standing in the one that replaced it.
        ForEach(WorkspaceViewMode.planningModes) { mode in
          let item = Button(mode.title) {
            AppDelegate.shared.workspace.dismissFocusScreen()
            AppDelegate.shared.workspace.dismissTimelineScreen()
            AppDelegate.shared.workspace.selectViewMode(mode)
            AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
          }
          if let digit = mode.shortcutDigit {
            item.keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
          } else {
            item
          }
        }
        Divider()
        Button("Focus") {
          AppDelegate.shared.workspace.presentFocusScreen()
        }
        .keyboardShortcut("8", modifiers: .command)
        Button("Timeline") {
          let workspace: WorkspaceViewModel = AppDelegate.shared.workspace
          if workspace.showsTimelineScreen {
            workspace.dismissTimelineScreen()
          } else {
            workspace.presentTimelineScreen()
          }
        }
        .keyboardShortcut("9", modifiers: .command)
        Divider()
        Button("Everything") {
          AppDelegate.shared.workspace.selectEverything()
          AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
        }
        .keyboardShortcut("0", modifiers: .command)
        Button("Inspector") {
          AppDelegate.shared.workspace.toggleInspector()
        }
        Divider()
        Button("Sidebar") {
          AppDelegate.shared.workspace.requestKeyboardFocus(.sidebar)
        }
        .keyboardShortcut("1", modifiers: .control)
        Button("Task Surface") {
          AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
        }
        .keyboardShortcut("2", modifiers: .control)
        Button("Inspector Pane") {
          let workspace: WorkspaceViewModel = AppDelegate.shared.workspace
          if workspace.selectedTask == nil {
            workspace.selectedTaskID = workspace.visibleNavigationTasks.first?.id
          }
          workspace.requestKeyboardFocus(workspace.selectedTask == nil ? .tasks : .inspector)
        }
        .keyboardShortcut("3", modifiers: .control)
      }
      CommandMenu("Workspace") {
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
        Button("Search…") {
          AppDelegate.shared.workspace.showsSearch = true
        }
        .keyboardShortcut("f", modifiers: .command)
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
        Button("Diagnostics") {
          AppDelegate.shared.showMainWindow()
          AppDelegate.shared.checkvistManager.popoverChrome.showsDiagnostics = true
        }
      }
    }
  }
}
