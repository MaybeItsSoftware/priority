import XCTest

@testable import PriorityCore

/// The catalogue is the only place the workspace's keys are written down, so
/// these are the properties that make that claim worth anything.
final class WorkspaceCommandCatalogTests: XCTestCase {

  func testEveryCommandHasAnEntry() {
    let missing = WorkspaceCommandID.allCases.filter { WorkspaceCommandCatalog.byID[$0] == nil }
    XCTAssertTrue(missing.isEmpty, "no catalogue entry for: \(missing.map(\.rawValue))")
    XCTAssertEqual(WorkspaceCommandCatalog.all.count, WorkspaceCommandID.allCases.count)
  }

  func testNoCommandIsListedTwice() {
    var seen: Set<WorkspaceCommandID> = []
    for command in WorkspaceCommandCatalog.all {
      XCTAssertTrue(seen.insert(command.id).inserted, "\(command.id.rawValue) listed twice")
    }
  }

  /// Two rows on the same surface claiming one key is a contradiction: the
  /// reference would be telling you a key does two things at once.
  ///
  /// A surface-specific row *shadowing* an `anywhere` row is not that — it is
  /// how the router already works, since the focus screen and the timeline
  /// take the keyboard before the workspace's own keys are consulted.
  func testNoKeyIsClaimedTwiceOnOneSurface() {
    var owners: [String: [String]] = [:]
    for command in WorkspaceCommandCatalog.all {
      for key in command.keys {
        owners["\(command.surface.rawValue)/\(key)", default: []].append(command.title)
      }
    }
    let shared = owners.filter { $0.value.count > 1 }
    XCTAssertTrue(shared.isEmpty, "keys claimed by more than one command: \(shared)")
  }

  func testEveryRowPrintsSomethingReadable() {
    for command in WorkspaceCommandCatalog.all {
      XCTAssertFalse(command.title.isEmpty, "\(command.id.rawValue) has no title")
      XCTAssertFalse(command.group.isEmpty, "\(command.id.rawValue) has no group")
      XCTAssertEqual(
        command.displayKeys.count, command.keys.count,
        "\(command.id.rawValue) has a key that renders to nothing: \(command.keys)")
    }
  }

  /// Only one row is allowed to have no shortcut: the second press on a staged
  /// focus task, which is a state rather than a key. Anything else with an
  /// empty binding is a row nobody can reach from the keyboard.
  func testOnlyTheStagedSecondPressLacksAKey() {
    let keyless = WorkspaceCommandCatalog.all.filter(\.keys.isEmpty).map(\.id)
    XCTAssertEqual(keyless, [.focusBegin])
  }

  func testNamedKeysRenderAsSymbols() {
    XCTAssertEqual(WorkspaceCommandCatalog[.goToday].displayKeys, ["⌘1"])
    XCTAssertEqual(WorkspaceCommandCatalog[.taskRename].displayKeys, ["E E", "F2"])
    XCTAssertEqual(WorkspaceCommandCatalog[.motionSelectEnds].displayKeys, ["Home", "End"])
    XCTAssertEqual(WorkspaceCommandCatalog[.taskDelete].displayKeys, ["⌫"])
  }
}

final class WorkspaceCommandQueryTests: XCTestCase {

  func testAnEmptyQueryShowsEverything() {
    let matches = WorkspaceCommandQuery.matches(query: "", surface: .anywhere)
    XCTAssertEqual(matches.count, WorkspaceCommandCatalog.all.count)
  }

  func testTheCurrentSurfaceSortsFirst() {
    let matches = WorkspaceCommandQuery.matches(query: "", surface: .board)
    let firstOtherSurface = matches.firstIndex { $0.command.surface != .board }
    let lastBoard = matches.lastIndex { $0.command.surface == .board }
    XCTAssertNotNil(firstOtherSurface)
    XCTAssertNotNil(lastBoard)
    XCTAssertLessThan(lastBoard!, firstOtherSurface!)
  }

  /// A key you cannot press here is still worth knowing about, so rows for
  /// other surfaces sort last rather than disappearing.
  func testOtherSurfacesAreKeptButSortLast() {
    let matches = WorkspaceCommandQuery.matches(query: "", surface: .board)
    XCTAssertTrue(matches.contains { $0.command.surface == .timeline })
    XCTAssertEqual(matches.last?.command.surface.rawValue.isEmpty, false)
  }

  func testAPrefixBeatsAMatchInTheMiddle() {
    let matches = WorkspaceCommandQuery.matches(query: "add", surface: .anywhere)
    XCTAssertEqual(matches.first?.command.title, "Add a task")
  }

  func testTypingTheKeyFindsTheCommand() {
    let matches = WorkspaceCommandQuery.matches(query: "cmd+shift+d", surface: .anywhere)
    XCTAssertEqual(matches.first?.id, .taskToggleDaily)
  }

  func testInitialsFindACommand() {
    let matches = WorkspaceCommandQuery.matches(query: "adt", surface: .anywhere)
    XCTAssertTrue(matches.contains { $0.id == .taskNew }, "initials should reach 'Add a task'")
  }

  func testNonsenseMatchesNothing() {
    XCTAssertTrue(WorkspaceCommandQuery.matches(query: "zzqx", surface: .anywhere).isEmpty)
  }

  func testSubsequenceIsNotSubstring() {
    XCTAssertTrue(WorkspaceCommandQuery.isSubsequence("adt", of: "add a task"))
    XCTAssertFalse(WorkspaceCommandQuery.isSubsequence("tda", of: "add a task"))
  }
}

/// The catalogue is now the only place the keys are written down: the router
/// reads it, the palette lists it, the tooltips quote it, and the main menu
/// derives its `keyboardShortcut` from it. That last one fails *silently* —
/// a token the parser does not recognise yields no menu key rather than an
/// error — so the shape of every token needs a test of its own.
final class WorkspaceCommandTokenShapeTests: XCTestCase {
  private static let modifiers: Set<String> = ["cmd", "shift", "option", "ctrl"]

  func testEveryModifierInEveryTokenIsOneTheAppKnows() {
    for command in WorkspaceCommandCatalog.all {
      for token in command.keys {
        let parts = token.split(separator: "+").map(String.init)
        guard parts.count > 1 else { continue }
        for modifier in parts.dropLast() {
          XCTAssertTrue(
            Self.modifiers.contains(modifier),
            "\(command.id) binds \(token), whose modifier \"\(modifier)\" is not one of \(Self.modifiers.sorted())")
        }
      }
    }
  }

  func testTokensAreLowercaseAndUnpadded() {
    for command in WorkspaceCommandCatalog.all {
      for token in command.keys {
        XCTAssertEqual(token, token.lowercased(), "\(command.id) binds \(token) with capitals")
        XCTAssertEqual(
          token, token.trimmingCharacters(in: .whitespaces),
          "\(command.id) binds \(token) with surrounding space")
      }
    }
  }

  /// `cmd` first is the repository's convention, and a tooltip renders tokens in
  /// the order they are written.
  func testCommandIsWrittenFirstAmongModifiers() {
    for command in WorkspaceCommandCatalog.all {
      for token in command.keys {
        let parts = token.split(separator: "+").map(String.init)
        guard let index = parts.firstIndex(of: "cmd") else { continue }
        XCTAssertEqual(index, 0, "\(command.id) binds \(token); cmd goes first")
      }
    }
  }

  func testEveryCommandRendersAtLeastOneKeyOrDeclaresItHasNone() {
    for command in WorkspaceCommandCatalog.all where !command.keys.isEmpty {
      XCTAssertFalse(
        command.displayKeys.isEmpty,
        "\(command.id) binds \(command.keys) but renders nothing, so no tooltip or palette row can show it")
    }
  }
}

/// Two commands that can both hear the same key on the same screen is a bug the
/// router resolves silently, by order of declaration — so the catalogue is asked
/// to be unambiguous instead.
final class WorkspaceCommandCollisionTests: XCTestCase {
  /// Only commands declared on the *same* surface are ambiguous. A surface
  /// command sharing a key with an `.anywhere` one is the intended arrangement,
  /// not a clash: `.anywhere` is the fallback and the surface overrides it, which
  /// is how `l` means "go in" everywhere and "log the block" while one is
  /// running. The scoring in `WorkspaceCommandQuery` is what makes that work,
  /// and a test that forbade it would forbid the design.
  func testNoTwoCommandsOnTheSameSurfaceShareAKey() {
    let all = WorkspaceCommandCatalog.all
    for (index, command) in all.enumerated() {
      for other in all[(index + 1)...] where command.surface == other.surface {
        let shared = Set(command.keys).intersection(other.keys)
        XCTAssertTrue(
          shared.isEmpty,
          "\(command.id) and \(other.id) both answer to \(shared.sorted()) on \(command.surface)")
      }
    }
  }

  /// A surface command that overrides an `.anywhere` one takes that key away on
  /// that screen, so each override should be a deliberate one. This records the
  /// set; a new entry in it means a key stopped working somewhere, and the
  /// question to ask is whether that was the intention.
  func testTheSurfaceOverridesAreTheOnesWeMeant() {
    var overrides: Set<String> = []
    for command in WorkspaceCommandCatalog.all where command.surface != .anywhere {
      for other in WorkspaceCommandCatalog.all where other.surface == .anywhere {
        for key in Set(command.keys).intersection(other.keys) {
          overrides.insert("\(command.surface.rawValue):\(key)")
        }
      }
    }
    let expected: Set<String> = [
      // The focus ladder replaces ordinary selection, and staging replaces both
      // "new task" and "complete": there is no task list under the ladder for
      // those to act on.
      "focus:up", "focus:down", "focus:k", "focus:j", "focus:enter", "focus:space",
      "focus:x", "focus:l",
      // A running block has exactly one task, so the list keys have nothing to
      // mean and the block's own controls take them.
      "focusRunning:enter", "focusRunning:escape", "focusRunning:l", "focusRunning:f",
      // The timeline is a day at a time, so ←/→ and h/l step days rather than
      // entering and leaving a task.
      "timeline:left", "timeline:right", "timeline:h", "timeline:l", "timeline:escape",
      // In the sidebar the arrows walk rows and open folders, rename acts on the
      // row, and ⌘↑/⌘↓ reorder the row rather than a task.
      "sidebar:up", "sidebar:down", "sidebar:left", "sidebar:right", "sidebar:enter",
      "sidebar:k", "sidebar:j", "sidebar:f2", "sidebar:cmd+up", "sidebar:cmd+down",
      // On the board ←/→ change column instead of entering and leaving a task.
      "board:left", "board:right",
    ]
    XCTAssertEqual(
      overrides, expected,
      "the set of keys a surface takes over from .anywhere changed")
  }
}
