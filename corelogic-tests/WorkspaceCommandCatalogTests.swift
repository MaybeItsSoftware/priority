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
