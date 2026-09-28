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
          .commandShortcut(.windowUndo)
        Button("Redo") { AppDelegate.shared.workspace.applyHistoryFromMenu(redo: true) }
          .commandShortcut(.windowRedo)
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
            AppDelegate.shared.workspace.leaveFullPaneScreens()
            AppDelegate.shared.workspace.selectViewMode(mode)
            AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
          }
          if let command = mode.command {
            item.commandShortcut(command)
          } else {
            item
          }
        }
        Divider()
        Button("Focus") {
          AppDelegate.shared.workspace.presentFocusScreen()
        }
        .commandShortcut(.goFocus)
        Button("Timeline") {
          let workspace: WorkspaceViewModel = AppDelegate.shared.workspace
          if workspace.showsTimelineScreen {
            workspace.dismissTimelineScreen()
          } else {
            workspace.presentTimelineScreen()
          }
        }
        .commandShortcut(.goTimeline)
        Divider()
        Button("Everything") {
          AppDelegate.shared.workspace.selectEverything()
          AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
        }
        .commandShortcut(.goEverything)
        Button("Inspector") {
          AppDelegate.shared.workspace.toggleInspector()
        }
        .commandShortcut(.windowToggleInspectorPane)
        Button("Done") {
          AppDelegate.shared.workspace.toggleDoneRail()
        }
        .commandShortcut(.windowToggleDoneRail)
        Divider()
        // Deliberately a fixed title rather than Hide/Show: every other item
        // here touches `AppDelegate.shared` only inside its action, which runs
        // long after launch. A title that reads the workspace is evaluated
        // while the menu is being built, which is before the delegate is
        // installed — and that crashed the app on startup.
        Button("Toggle Sidebar") {
          AppDelegate.shared.workspace.toggleSidebar()
        }
        .commandShortcut(.windowToggleSidebar)
        Button("Sidebar") {
          let workspace: WorkspaceViewModel = AppDelegate.shared.workspace
          // Focusing a collapsed sidebar has to open it first, or the
          // shortcut moves focus somewhere you cannot see.
          if !workspace.isSidebarVisible { workspace.toggleSidebar() }
          workspace.requestKeyboardFocus(.sidebar)
        }
        .commandShortcut(.goSidebarRegion)
        Button("Task Surface") {
          AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
        }
        .commandShortcut(.goTaskRegion)
        Button("Inspector Pane") {
          let workspace: WorkspaceViewModel = AppDelegate.shared.workspace
          if workspace.selectedTask == nil {
            workspace.selectedTaskID = workspace.visibleNavigationTasks.first?.id
          }
          workspace.requestKeyboardFocus(workspace.selectedTask == nil ? .tasks : .inspector)
        }
        .commandShortcut(.goInspectorRegion)
      }
      // Every task action, with its key where it has a chord. The palette
      // lists them too, but only once you know to open it; a menu is where a
      // Mac user looks, and where the key is printed beside the name.
      CommandMenu("Task") {
        ForEach(WorkspaceCommandCatalog.taskMenu.indices, id: \.self) { index in
          if index > 0 { Divider() }
          ForEach(WorkspaceCommandCatalog.taskMenu[index], id: \.self) { id in
            Button(WorkspaceCommandCatalog[id].title) {
              AppDelegate.shared.workspace.run(id)
            }
            .commandShortcut(id)
          }
        }
        Divider()
        // The digits are one catalogue row that reads which digit ran it, so
        // the menu passes the digit as the key.
        Menu("Set Priority") {
          ForEach(1..<10) { digit in
            Button("Priority \(digit)") {
              AppDelegate.shared.workspace.run(.motionSetPriority, key: String(digit))
            }
          }
          Divider()
          Button(WorkspaceCommandCatalog[.taskClearPriority].title) {
            AppDelegate.shared.workspace.run(.taskClearPriority)
          }
        }
      }
      CommandMenu("Workspace") {
        Button("New Task") {
          AppDelegate.shared.workspace.run(.taskNew)
        }
        .commandShortcut(.taskNew)
        Button("New List") {
          AppDelegate.shared.workspace.requestListCreationForSelection()
        }
        .commandShortcut(.listNew)
        Button("New Folder") {
          AppDelegate.shared.workspace.requestFolderCreationForSelection()
        }
        .commandShortcut(.folderNew)
        Divider()
        Button("Search…") {
          AppDelegate.shared.workspace.showsSearch = true
        }
        .commandShortcut(.goSearch)
        Button("List Settings…") {
          AppDelegate.shared.workspace.showSelectedListSettings()
        }
        .commandShortcut(.listSettings)
        Button("Archive Current List") {
          AppDelegate.shared.workspace.archiveSelectedList()
        }
        .commandShortcut(.listArchive)
        Button("Restore Most Recently Archived List") {
          AppDelegate.shared.workspace.restoreMostRecentlyArchivedList()
        }
        .commandShortcut(.listRestore)
        Divider()
        Button("Command Palette…") {
          AppDelegate.shared.workspace.run(.goCommandPalette)
        }
        .commandShortcut(.goCommandPalette)
        Button("Keyboard Help") {
          AppDelegate.shared.workspace.showsKeyboardHelp = true
        }
        .commandShortcut(.goKeyboardReference)
        Button("Diagnostics") {
          AppDelegate.shared.showMainWindow()
          AppDelegate.shared.workspace.run(.windowShowDiagnostics)
        }
      }
    }
  }
}
