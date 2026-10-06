import XCTest

@testable import TaktCore

/// The key router asks the catalogue what a key means and runs the answer —
/// it has no list of its own. These pin that the answer is the one the
/// catalogue advertises, which is the property the old hand-written router
/// lost: its reference listed `⌘⌃C` and the ladder's `o`, and neither ran.
///
/// The other half — that every command id the catalogue resolves to actually
/// does something — is the compiler's: `WorkspaceViewModel.run(_:key:)` is an
/// exhaustive `switch` over `WorkspaceCommandID`, and the router has no other
/// way to act.
final class WorkspaceCommandDispatchTests: XCTestCase {
  private static let planningPanes: [WorkspaceCommandSurface] = [.today, .board, .outline, .matrix]

  /// A row that prints a key on a surface is a row that key runs there.
  func testEverySurfaceRowIsWhatItsKeysMeanOnItsSurface() {
    for command in WorkspaceCommandCatalog.all where command.surface != .anywhere {
      for key in command.keys {
        XCTAssertEqual(
          WorkspaceCommandCatalog.command(forKey: key, on: command.surface)?.id, command.id,
          "\(key) on \(command.surface) does not run \(command.id)")
      }
    }
    for command in WorkspaceCommandCatalog.all {
      for (surface, keys) in command.surfaceKeys {
        for key in keys {
          XCTAssertEqual(
            WorkspaceCommandCatalog.command(forKey: key, on: surface)?.id, command.id,
            "\(key) on \(surface) does not run \(command.id)")
        }
      }
    }
  }

  /// An `.anywhere` row is written from a planning pane's point of view, so
  /// on the outline — which overrides nothing — every one of its keys is live.
  func testEveryAnywhereRowIsLiveOnTheOutline() {
    // ←/→ are the outline's own: they fold, as Checkvist's do.
    let outlineOwn: Set<String> = ["left", "right"]
    for command in WorkspaceCommandCatalog.all where command.surface == .anywhere {
      for key in command.keys where !outlineOwn.contains(key) {
        XCTAssertEqual(
          WorkspaceCommandCatalog.command(forKey: key, on: .outline)?.id, command.id,
          "\(key) on the outline does not run \(command.id)")
      }
    }
  }

  func testTheKeysTheOldRouterLeftDeadNowRun() {
    XCTAssertEqual(
      WorkspaceCommandCatalog.command(forKey: "cmd+ctrl+c", on: .board)?.id, .planBoardRemoveColumn)
    // Each the first letter of a sequence, and so swallowed by it.
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "x", on: .outline)?.id, .taskComplete)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "l", on: .outline)?.id, .planEnterTask)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "h", on: .outline)?.id, .planLeaveTask)
  }

  func testTheOutlineArrowsFoldAndTheOtherPanesStillEnter() {
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "right", on: .outline)?.id, .motionOutlineUnfold)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "left", on: .outline)?.id, .motionOutlineFold)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "right", on: .matrix)?.id, .planEnterTask)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "right", on: .board)?.id, .motionBoardColumn)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "za", on: .board)?.id, .planToggleFold)
  }

  /// Phase 1 made ⌘R sidebar-only by following the catalogue strictly. It
  /// renames the current list from the task panes too; F2 stays the task's
  /// rename there and the row's in the sidebar.
  func testCommandRRenamesTheListFromEveryPane() {
    for surface in Self.planningPanes + [.sidebar] {
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+r", on: surface)?.id, .listRename)
    }
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "f2", on: .sidebar)?.id, .listRename)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "f2", on: .outline)?.id, .taskRename)
  }

  // MARK: - Surfaces that own the keyboard

  /// Keys a full-pane screen does not answer to used to fall through to the
  /// task surface hidden behind it: `⌫` deleted the selected outline task, a
  /// digit changed its priority, `i` opened its inspector.
  func testTheTimelineLetsNoTaskKeyThrough() {
    for surface: WorkspaceCommandSurface in [.timeline] {
      for key in ["delete", "1", "i", "tab", "shift+space", "cmd+n", "cmd+shift+delete", "ee"] {
        XCTAssertNil(
          WorkspaceCommandCatalog.command(forKey: key, on: surface),
          "\(key) reaches the hidden workspace from \(surface)")
        XCTAssertTrue(
          WorkspaceCommandCatalog.swallowsUnhandledKey(key, on: surface),
          "\(key) passes through \(surface) to the window")
      }
    }
  }

  func testTheWindowsOwnKeysStillWorkOnAScreenThatOwnsTheKeyboard() {
    for surface: WorkspaceCommandSurface in [.timeline] {
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+1", on: surface)?.id, .goToday)
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+k", on: surface)?.id, .goCommandPalette)
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "?", on: surface)?.id, .goKeyboardReference)
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+z", on: surface)?.id, .windowUndo)
      // Not the catalogue's, so the app's: ⌘Q and ⌘W must reach the menu.
      XCTAssertFalse(WorkspaceCommandCatalog.swallowsUnhandledKey("cmd+q", on: surface))
      XCTAssertFalse(WorkspaceCommandCatalog.swallowsUnhandledKey("cmd+w", on: surface))
    }
  }

  func testOrdinarySurfacesPassUnknownKeysOn() {
    for surface in Self.planningPanes + [.sidebar, .inspector, .done] {
      XCTAssertFalse(WorkspaceCommandCatalog.swallowsUnhandledKey("z", on: surface))
    }
  }

  // MARK: - Regions

  /// The sidebar and the done rail hold cursors of their own, so a bare key
  /// that acts on "the selected task" must not act on a row in a pane that
  /// does not have the keyboard.
  func testRegionsDoNotTakeBareTaskKeys() {
    for surface: WorkspaceCommandSurface in [.sidebar, .done, .inspector] {
      for key in ["x", "1", "0", "tab", "f", "shift+enter", "option+enter"] {
        XCTAssertNil(
          WorkspaceCommandCatalog.command(forKey: key, on: surface),
          "\(key) acts on the selected task from \(surface)")
      }
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "?", on: surface)?.id, .goKeyboardReference)
    }
    for surface: WorkspaceCommandSurface in [.done, .inspector] {
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+n", on: surface)?.id, .taskNew)
    }
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "escape", on: .sidebar)?.id, .motionDismiss)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "escape", on: .inspector)?.id, .motionDismiss)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "escape", on: .done)?.id, .doneClose)
  }

  /// The sidebar is Zed's project panel, with its vim panel's netrw keys:
  /// the keys act on the sidebar row, never on a task behind it.
  func testTheSidebarAnswersToZedsProjectPanelKeys() {
    let expected: [String: WorkspaceCommandID] = [
      "d": .folderNew, "shift+d": .listDelete, "delete": .listDelete, "cmd+delete": .listDelete,
      "shift+5": .listNew, "cmd+n": .listNew, "cmd+option+n": .folderNew,
      "shift+r": .listRename, "f2": .listRename,
      "h": .motionSidebarCollapse, "-": .motionSidebarCollapse,
      "l": .motionSidebarExpand,
      "gg": .motionSidebarSelect, "shift+g": .motionSidebarSelect,
      "{": .folderSelectPrevious, "}": .folderSelectNext, ":": .goCommandPalette,
      "cmd+left": .folderCollapseAll, "cmd+right": .folderExpandAll,
    ]
    for (key, id) in expected {
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: key, on: .sidebar)?.id, id, key)
    }
    // Only on the sidebar: on a task pane these still mean the task.
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "delete", on: .outline)?.id, .taskDelete)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+n", on: .outline)?.id, .taskNew)
  }

  /// `d` makes a folder at once rather than waiting to see whether it was the
  /// start of `dd`, and `⇧X`, which nothing binds, is still `x`.
  func testASurfacesOwnLetterIsNotHeldForAnInheritedSequence() {
    let sidebar = WorkspaceCommandCatalog.sequences(on: .sidebar)
    XCTAssertFalse(sidebar.contains("dd"))
    XCTAssertFalse(sidebar.contains("dr"))
    XCTAssertTrue(sidebar.contains("gh"))
    XCTAssertTrue(WorkspaceCommandCatalog.sequences(on: .outline).contains("dd"))
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "shift+x", on: .outline)?.id, .taskComplete)
  }

  // MARK: - Sequences

  /// These were a hand-written list beside the catalogue; now they are read
  /// out of it. The set is recorded so a change to it is a deliberate one.
  func testSequencesAreDerivedFromTheCatalogue() {
    XCTAssertEqual(
      WorkspaceCommandCatalog.sequences(on: .outline),
      [
        "ee", "ea", "ei", "dd", "nn", "tt", "mm", "ll", "uu", "td", "tm", "cd", "cn", "ct",
        "dr", "hc", "hh", "ww", "gh", "sd", "oo", "pc", "xx", "gg", "za",
      ])
    let written = Set(
      WorkspaceCommandCatalog.all.flatMap(\.allKeys).filter(WorkspaceCommandCatalog.isSequence))
    XCTAssertEqual(WorkspaceCommandCatalog.sequences(on: .outline), written)
  }

  func testTheInspectorHasNoSequences() {
    XCTAssertTrue(WorkspaceCommandCatalog.sequences(on: .inspector).isEmpty)
  }

  /// Only the window's own sequences survive a screen that owns the keyboard,
  /// and none of them begins with a letter the screen uses on its own — that
  /// letter would wait out the hold on every press.
  func testFullPaneScreensHoldNoKeyTheyUseThemselves() {
    for surface: WorkspaceCommandSurface in [.timeline] {
      let starters = Set(WorkspaceCommandCatalog.sequences(on: surface).compactMap(\.first).map(String.init))
      let own = Set(WorkspaceCommandCatalog.all.filter { $0.surface == surface }.flatMap(\.keys))
      XCTAssertTrue(
        starters.isDisjoint(with: own),
        "\(surface) holds \(starters.intersection(own).sorted()) for a sequence")
    }
  }

  func testKeyNamesAreNotSequences() {
    XCTAssertFalse(WorkspaceCommandCatalog.isSequence("up"))
    XCTAssertFalse(WorkspaceCommandCatalog.isSequence("f2"))
    XCTAssertTrue(WorkspaceCommandCatalog.isSequence("gh"))
  }

  // MARK: - Text fields

  func testOnlyTheWayOutChordsReachIntoATextField() {
    XCTAssertTrue(WorkspaceCommandCatalog.reachesIntoTextField("cmd+k", on: .outline))
    XCTAssertTrue(WorkspaceCommandCatalog.reachesIntoTextField("cmd+2", on: .today))
    XCTAssertTrue(WorkspaceCommandCatalog.reachesIntoTextField("ctrl+shift+tab", on: .outline))
    XCTAssertFalse(WorkspaceCommandCatalog.reachesIntoTextField("cmd+z", on: .outline))
    // Bare, so typed: Return belongs to the field even though it adds a task.
    XCTAssertFalse(WorkspaceCommandCatalog.reachesIntoTextField("enter", on: .outline))
    XCTAssertFalse(WorkspaceCommandCatalog.reachesIntoTextField("/", on: .outline))
  }

  // MARK: - Spelling a key press

  private func key(
    _ code: UInt16, _ characters: String,
    shift: Bool = false, ctrl: Bool = false, cmd: Bool = false, option: Bool = false
  ) -> String? {
    WorkspaceCommandCatalog.key(
      keyCode: code, charactersIgnoringModifiers: characters,
      shift: shift, ctrl: ctrl, cmd: cmd, option: option)
  }

  func testKeyPressesAreSpelledTheWayTheCatalogueSpellsThem() {
    XCTAssertEqual(key(8, "c", ctrl: true, cmd: true), "cmd+ctrl+c")
    XCTAssertEqual(key(8, "C", shift: true, cmd: true), "cmd+shift+c")
    XCTAssertEqual(key(44, "?", shift: true), "?")
    XCTAssertEqual(key(7, "X", shift: true), "shift+x")
    XCTAssertEqual(key(23, "%", shift: true), "shift+5")
    XCTAssertEqual(key(27, "-"), "-")
    XCTAssertEqual(key(36, "\r", shift: true), "shift+enter")
    XCTAssertEqual(key(76, "\u{3}"), "enter")
    XCTAssertEqual(key(115, "\u{F729}"), "home")
    XCTAssertEqual(key(121, "\u{F72D}"), "pagedown")
    XCTAssertEqual(key(48, "\t", shift: true, ctrl: true), "ctrl+shift+tab")
    XCTAssertEqual(key(18, "1", option: true), "option+1")
    XCTAssertEqual(key(51, "\u{7F}", shift: true, cmd: true), "cmd+shift+delete")
    XCTAssertEqual(key(126, "\u{F700}", ctrl: true, option: true), "ctrl+option+up")
    XCTAssertNil(key(56, ""))
  }

  /// A catalogue key no key press can be spelled as is a dead key by
  /// construction. The spelling puts modifiers in one order and never writes
  /// Shift on a bare character but a letter or a named key, so the catalogue
  /// must not either.
  func testEveryCatalogueKeyIsOneAKeyPressCanProduce() {
    let order = ["cmd", "ctrl", "option", "shift"]
    for command in WorkspaceCommandCatalog.all {
      for token in command.allKeys {
        let parts = token.split(separator: "+").map(String.init)
        let modifiers = Array(parts.dropLast())
        XCTAssertEqual(
          modifiers, order.filter(modifiers.contains),
          "\(command.id) binds \(token), whose modifiers are out of order")
        if modifiers == ["shift"], let base = parts.last, base.count == 1,
          base.first?.isLetter != true, !WorkspaceCommandCatalog.keyNames.contains(base) {
          XCTFail("\(command.id) binds \(token); Shift on a character is already in the character")
        }
      }
    }
  }

  /// Zed's previous and next tab move between lists. ⌘{ arrives as Shift-[
  /// with Command held, so it is spelled with the brace the key produces.
  func testZedsTabKeysMoveBetweenLists() {
    let brace = WorkspaceCommandCatalog.key(
      keyCode: 33, charactersIgnoringModifiers: "{", shift: true, ctrl: false, cmd: true, option: false)
    XCTAssertEqual(brace, "cmd+shift+{")
    for surface in [WorkspaceCommandSurface.outline, .board, .sidebar] {
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+shift+{", on: surface)?.id, .goPreviousList)
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+shift+}", on: surface)?.id, .goNextList)
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+option+left", on: surface)?.id, .goPreviousList)
      XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+option+right", on: surface)?.id, .goNextList)
    }
  }

  /// ⌘← and ⌘→ move a card on the board, and still fold in the outline.
  func testCommandArrowsMoveACardOnlyOnTheBoard() {
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+left", on: .board)?.id, .planBoardMoveCardLeft)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+right", on: .board)?.id, .planBoardMoveCardRight)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+left", on: .outline)?.id, .planFoldAll)
  }

  func testEaAndEiEditAtTheEndAndTheStart() {
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "ea", on: .outline)?.id, .taskRenameAppend)
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "ei", on: .outline)?.id, .taskRenameInsert)
  }
}
