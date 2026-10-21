import TaktCore
import TaktWorkspace
import SwiftUI

/// The real entry point, so `--mcp-server` is handled before AppKit starts.
///
/// `MCPServerShim.run()` replaces the process image with the bundled `takt`
/// CLI, so nothing here gets as far as opening a window-server connection for a
/// process that only ever speaks JSON-RPC on stdio.
@main
enum TaktEntryPoint {
  static func main() {
    if MCPServerShim.isLaunchMode(arguments: CommandLine.arguments) {
      MCPServerShim.run()
    }
    // Before anything reads preferences or Application Support. Here rather
    // than in `applicationDidFinishLaunching` because `AppDelegate`'s stored
    // properties are built before that runs, and one of them opening a file at
    // the new location first would leave the old copy behind for good. The
    // MCP server, exec'd above, needs no migration: the CLI falls back to the
    // old locations itself until the app has created the new ones.
    LegacyNameMigration.runIfNeeded()
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
        Button("Undo") { applyHistoryFromMenu(redo: false) }
          .commandShortcut(.windowUndo)
        Button("Redo") { applyHistoryFromMenu(redo: true) }
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
        Button("Takt") {
          AppDelegate.shared.showMainWindow()
        }
      }
      // Into AppKit's own View menu rather than a second one beside it. A
      // window with a toolbar is given that menu whether or not anything is
      // put in it, so declaring `CommandMenu("View")` produced two menus with
      // the same name — the system's holding Enter Full Screen, and ours
      // holding everything you would go to that menu for.
      CommandGroup(after: .toolbar) {
        // The places you can actually be, in the order the title strip shows
        // them. This menu used to list the old Checkvist root views, a Refresh
        // and a Diagnostics button — the previous app's furniture, still
        // standing in the one that replaced it.
        ForEach(WorkspaceViewMode.planningModes) { mode in
          let item = Button(mode.title) {
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
          AppDelegate.shared.workspace.openFocusPanel()
        }
        .commandShortcut(.goFocus)
        Button("Timeline") {
          AppDelegate.shared.workspace.run(.goTimeline)
        }
        .commandShortcut(.goTimeline)
        Divider()
        Button("Everything") {
          AppDelegate.shared.workspace.selectEverything()
          AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
        }
        .commandShortcut(.goEverything)
        Button("Inbox") {
          AppDelegate.shared.workspace.run(.goInbox)
        }
        .commandShortcut(.goInbox)
        Button("Inspector") {
          AppDelegate.shared.workspace.toggleInspector()
        }
        .commandShortcut(.windowToggleInspectorPane)
        Button("Right Dock") {
          AppDelegate.shared.workspace.toggleRightDock()
        }
        .commandShortcut(.windowToggleRightDock)
        Button("Done") {
          AppDelegate.shared.workspace.toggleDoneRail()
        }
        .commandShortcut(.windowToggleDoneRail)
        Button("Agent") {
          AppDelegate.shared.workspace.toggleAgentPanel()
        }
        .commandShortcut(.windowToggleAgentPanel)
        Button("Bottom Dock") {
          AppDelegate.shared.workspace.toggleBottomDock()
        }
        .commandShortcut(.windowToggleProgressDock)
        Button("Close All Docks") {
          AppDelegate.shared.workspace.closeAllDocks()
        }
        .commandShortcut(.windowCloseAllDocks)
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
        // "Focus …" for the items that move the keyboard, beside the ones
        // that show and hide the same panes.
        Button("Focus Sidebar") {
          let workspace: WorkspaceViewModel = AppDelegate.shared.workspace
          // Focusing a collapsed sidebar has to open it first, or the
          // shortcut moves focus somewhere you cannot see.
          if !workspace.isListsPaneVisible { workspace.showLeftDock(.lists) }
          workspace.requestKeyboardFocus(.sidebar)
        }
        .commandShortcut(.goSidebarRegion)
        Button("Task Surface") {
          AppDelegate.shared.workspace.requestKeyboardFocus(.tasks)
        }
        .commandShortcut(.goTaskRegion)
        Button("Focus Inspector") {
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
            .workspaceWindowOnly()
          }
          // Ending the block sits after the section that starts one.
          if index == 0 {
            Divider()
            FocusMenuItems()
          }
        }
        Divider()
        // The digits are one catalogue row that reads which digit ran it, so
        // the menu passes the digit as the key.
        Menu("Set Priority") {
          ForEach(1..<5) { digit in
            Button("Priority \(digit) — \(TaskEditorValues.priorityName(digit))") {
              AppDelegate.shared.workspace.run(.motionSetPriority, key: String(digit))
            }
          }
          Divider()
          // Behind every task with no priority; -1 is the very back.
          ForEach([-4, -3, -2], id: \.self) { level in
            Button("Priority \(TaskEditorValues.priorityName(level))") {
              AppDelegate.shared.workspace.run(.motionSetPriority, key: String(level))
            }
          }
          Button(WorkspaceCommandCatalog[.taskSendToBack].title) {
            AppDelegate.shared.workspace.run(.taskSendToBack)
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
        .workspaceWindowOnly()
        Button("New List") {
          AppDelegate.shared.workspace.requestListCreationForSelection()
        }
        .commandShortcut(.listNew)
        .workspaceWindowOnly()
        Button("New Folder") {
          AppDelegate.shared.workspace.requestFolderCreationForSelection()
        }
        .commandShortcut(.folderNew)
        .workspaceWindowOnly()
        Divider()
        Button("Search…") {
          AppDelegate.shared.workspace.run(.goSearch)
        }
        .commandShortcut(.goSearch)
        .workspaceWindowOnly()
        Button("List Settings…") {
          AppDelegate.shared.workspace.showSelectedListSettings()
        }
        .commandShortcut(.listSettings)
        .workspaceWindowOnly()
        Button("Archive Current List") {
          AppDelegate.shared.workspace.archiveSelectedList()
        }
        .commandShortcut(.listArchive)
        .workspaceWindowOnly()
        Button("Restore Most Recently Archived List") {
          AppDelegate.shared.workspace.restoreMostRecentlyArchivedList()
        }
        .commandShortcut(.listRestore)
        .workspaceWindowOnly()
        Divider()
        Button("Command Palette…") {
          AppDelegate.shared.workspace.run(.goCommandPalette)
        }
        .commandShortcut(.goCommandPalette)
        Button("Keyboard Help") {
          AppDelegate.shared.workspace.run(.goKeyboardReference)
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

/// The workspace as the menu bar may read it while it is being built, which
/// is before `AppDelegate.shared` exists. Observable, so items that read
/// through it update once the delegate fills it in and as the block changes.
@MainActor @Observable
final class MenuBarWorkspace {
  static let shared = MenuBarWorkspace()
  var workspace: WorkspaceViewModel?
  /// Whether the workspace window is the key window — not Settings, not the
  /// focus panel, not a sheet on the window. `MainWindowController` keeps it.
  var isWorkspaceWindowKey = false
}

/// Greys a menu item that acts on the window's selection while some other
/// window has the keyboard. Its key equivalent then goes to that window
/// instead: ⌘⌫ in a Settings field deletes to the start of the line, and in
/// the focus panel it is the panel's, rather than deleting the task selected
/// in a window you are not looking at.
private struct WorkspaceWindowOnly: ViewModifier {
  func body(content: Content) -> some View {
    content.disabled(!MenuBarWorkspace.shared.isWorkspaceWindowKey)
  }
}

extension View {
  fileprivate func workspaceWindowOnly() -> some View { modifier(WorkspaceWindowOnly()) }
}

/// Undo and Redo stay enabled everywhere, unlike the items above, because a
/// text field in Settings or the focus panel undoes its own typing through
/// them. Only the workspace window steps the task history; anywhere else the
/// action goes down that window's responder chain and touches nothing else.
@MainActor
private func applyHistoryFromMenu(redo: Bool) {
  if MenuBarWorkspace.shared.isWorkspaceWindowKey {
    AppDelegate.shared.workspace.applyHistoryFromMenu(redo: redo)
  } else {
    NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
  }
}

/// Finish and Stop, greyed while there is nothing running to end. A view of
/// its own so the enabled state is read where observation can see it.
private struct FocusMenuItems: View {
  var body: some View {
    let workspace = MenuBarWorkspace.shared.workspace
    ForEach(WorkspaceCommandCatalog.focusMenu, id: \.self) { id in
      Button(WorkspaceCommandCatalog[id].title) {
        AppDelegate.shared.workspace.run(id)
      }
      .commandShortcut(id)
      .disabled(!(workspace?.isOffered(id) ?? false))
    }
  }
}
