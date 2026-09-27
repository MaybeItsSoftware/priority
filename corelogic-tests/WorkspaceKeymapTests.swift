import XCTest

@testable import PriorityCore

/// A user keymap laid over the catalogue. Every test resolves into a
/// `WorkspaceKeyBindings` value of its own rather than installing it, so none
/// of them can leak a binding into another.
final class WorkspaceKeymapTests: XCTestCase {

  private func resolve(_ json: String) -> (WorkspaceKeyBindings, [WorkspaceKeymapIssue]) {
    let (keymap, parseIssues) = WorkspaceKeymap.parse(Data(json.utf8))
    let (bindings, resolveIssues) = keymap.resolve()
    return (bindings, parseIssues + resolveIssues)
  }

  // MARK: - The file

  func testAnEmptyOrMissingFileIsTheDefaults() {
    for json in ["", "  \n", "[]"] {
      let (bindings, issues) = resolve(json)
      XCTAssertTrue(issues.isEmpty, "\(json.debugDescription): \(issues)")
      XCTAssertEqual(bindings.commands, WorkspaceCommandCatalog.defaults)
    }
  }

  func testAFileThatIsNotJSONIsReportedAndChangesNothing() {
    let (bindings, issues) = resolve("[{\"bindings\": ")
    XCTAssertEqual(issues.map(\.kind), [.unreadableFile])
    XCTAssertEqual(bindings.commands, WorkspaceCommandCatalog.defaults)
  }

  func testAFileThatIsNotAnArrayIsReported() {
    let (_, issues) = resolve("{\"bindings\": {\"x\": null}}")
    XCTAssertEqual(issues.map(\.kind), [.unreadableFile])
  }

  // MARK: - Binding

  func testABindingWithoutAContextAddsTheKeyWhereverTheCommandRuns() {
    let (bindings, issues) = resolve(#"[{"bindings": {"cmd+shift+k": "taskComplete"}}]"#)
    XCTAssertTrue(issues.isEmpty, "\(issues)")
    for surface: WorkspaceCommandSurface in [.today, .board, .outline, .matrix, .sidebar] {
      XCTAssertEqual(bindings.command(forKey: "cmd+shift+k", on: surface)?.id, .taskComplete)
    }
    // The defaults stay: a binding adds a key, it does not replace the others.
    XCTAssertEqual(bindings.command(forKey: "x", on: .outline)?.id, .taskComplete)
    XCTAssertEqual(bindings.byID[.taskComplete]?.displayKeys, ["Space", "X", "⇧↩", "⌘⇧K"])
  }

  func testABindingTakesTheKeyFromWhoeverHadItOnTheSameSurface() {
    let (bindings, issues) = resolve(#"[{"bindings": {"x": "taskDelete"}}]"#)
    XCTAssertTrue(issues.isEmpty, "\(issues)")
    XCTAssertEqual(bindings.command(forKey: "x", on: .outline)?.id, .taskDelete)
    XCTAssertEqual(bindings.byID[.taskComplete]?.keys, ["space", "shift+enter"])
    // A different surface's own `x` is a different binding, and stays.
    XCTAssertEqual(bindings.command(forKey: "x", on: .focus)?.id, .focusTickOff)
  }

  func testAContextBindsOnThatSurfaceOnly() {
    let (bindings, issues) = resolve(#"[{"context": "board", "bindings": {"cmd+shift+k": "taskComplete"}}]"#)
    XCTAssertTrue(issues.isEmpty, "\(issues)")
    XCTAssertEqual(bindings.command(forKey: "cmd+shift+k", on: .board)?.id, .taskComplete)
    XCTAssertNil(bindings.command(forKey: "cmd+shift+k", on: .outline))
    XCTAssertEqual(bindings.byID[.taskComplete]?.surfaceKeys[.board], ["cmd+shift+k"])
  }

  func testAContextBindingBeatsTheSurfacesOwnRow() {
    let (bindings, _) = resolve(#"[{"context": "board", "bindings": {"option+left": "taskOutdent"}}]"#)
    XCTAssertEqual(bindings.command(forKey: "option+left", on: .board)?.id, .taskOutdent)
    XCTAssertEqual(bindings.byID[.planBoardMoveCardLeft]?.keys, [])
  }

  func testASequenceCanBeBoundAndIsThenHeld() {
    let (bindings, issues) = resolve(#"[{"bindings": {"zz": "goToday"}}]"#)
    XCTAssertTrue(issues.isEmpty, "\(issues)")
    XCTAssertTrue(bindings.sequences(on: .outline).contains("zz"))
    XCTAssertEqual(bindings.command(forKey: "zz", on: .outline)?.id, .goToday)
  }

  // MARK: - Unbinding

  func testNullWithoutAContextUnbindsTheKeyEverywhere() {
    let (bindings, issues) = resolve(#"[{"bindings": {"x": null}}]"#)
    XCTAssertTrue(issues.isEmpty, "\(issues)")
    XCTAssertNil(bindings.command(forKey: "x", on: .outline))
    XCTAssertNil(bindings.command(forKey: "x", on: .focus))
    XCTAssertEqual(bindings.byID[.taskComplete]?.keys, ["space", "shift+enter"])
  }

  func testNullInAContextUnbindsOnThatSurfaceOnly() {
    let (bindings, issues) = resolve(#"[{"context": "board", "bindings": {"x": null}}]"#)
    XCTAssertTrue(issues.isEmpty, "\(issues)")
    XCTAssertNil(bindings.command(forKey: "x", on: .board))
    XCTAssertEqual(bindings.command(forKey: "x", on: .outline)?.id, .taskComplete)
  }

  func testUnbindingThenRebindingInOneBlockIsOrderIndependent() {
    let (bindings, _) = resolve(
      #"[{"context": "board", "bindings": {"x": "taskDelete", "delete": null}}]"#)
    XCTAssertEqual(bindings.command(forKey: "x", on: .board)?.id, .taskDelete)
    XCTAssertNil(bindings.command(forKey: "delete", on: .board))
  }

  func testAnUnboundSequenceIsNoLongerHeld() {
    let (bindings, _) = resolve(#"[{"bindings": {"gg": null}}]"#)
    XCTAssertFalse(bindings.sequences(on: .outline).contains("gg"))
  }

  // MARK: - What is reported, not fatal

  func testAnUnknownCommandIsReportedAndTheRestStillApplies() {
    let (bindings, issues) = resolve(
      #"[{"bindings": {"cmd+shift+k": "noSuchCommand", "cmd+shift+j": "taskComplete"}}]"#)
    XCTAssertEqual(issues.map(\.kind), [.unknownCommand])
    XCTAssertTrue(issues[0].message.contains("noSuchCommand"))
    XCTAssertEqual(bindings.command(forKey: "cmd+shift+j", on: .outline)?.id, .taskComplete)
  }

  func testMalformedKeysAreReported() {
    for key in ["hyper+k", "cmd+", "f13", "cmd+gg", "shift+/", "cmd+nope"] {
      let (_, issues) = resolve(#"[{"bindings": {"\#(key)": "taskComplete"}}]"#)
      XCTAssertEqual(issues.map(\.kind), [.malformedKey], key)
    }
  }

  func testAnUnknownContextSkipsTheBlockAndSaysWhich() {
    let (bindings, issues) = resolve(
      #"[{"context": "Editor", "bindings": {"x": null}}, {"bindings": {"cmd+shift+j": "taskComplete"}}]"#)
    XCTAssertEqual(issues.map(\.kind), [.unknownContext])
    XCTAssertTrue(issues[0].message.contains("Block 1"))
    XCTAssertEqual(bindings.command(forKey: "x", on: .outline)?.id, .taskComplete)
    XCTAssertEqual(bindings.command(forKey: "cmd+shift+j", on: .outline)?.id, .taskComplete)
  }

  func testABlockWithoutBindingsIsReported() {
    let (_, issues) = resolve(#"[{"context": "board"}, 3]"#)
    XCTAssertEqual(issues.map(\.kind), [.malformedBlock, .malformedBlock])
  }

  func testACommandThatReadsItsKeyCannotBeRebound() {
    let (bindings, issues) = resolve(#"[{"bindings": {"cmd+shift+1": "motionSetPriority"}}]"#)
    XCTAssertEqual(issues.map(\.kind), [.notRebindable])
    XCTAssertNil(bindings.command(forKey: "cmd+shift+1", on: .outline))
  }

  func testASurfaceCommandCannotBeBoundOnAnotherSurface() {
    let (_, issues) = resolve(#"[{"context": "outline", "bindings": {"p": "focusPause"}}]"#)
    XCTAssertEqual(issues.map(\.kind), [.wrongSurface])
  }

  /// Two of the user's own bindings for one key on one surface is a
  /// contradiction worth saying out loud; the later one wins, as in Zed.
  func testAConflictWithinASurfaceIsReportedAndTheLaterWins() {
    let (bindings, issues) = resolve(
      #"[{"bindings": {"cmd+shift+k": "taskComplete"}}, {"bindings": {"cmd-shift-k": "taskDelete"}}]"#)
    XCTAssertEqual(issues.map(\.kind), [.conflict])
    XCTAssertEqual(bindings.command(forKey: "cmd+shift+k", on: .outline)?.id, .taskDelete)
  }

  func testBindingsOnDifferentSurfacesDoNotConflict() {
    let (_, issues) = resolve(
      #"[{"context": "board", "bindings": {"cmd+shift+k": "taskComplete"}}, {"context": "outline", "bindings": {"cmd+shift+k": "taskDelete"}}]"#)
    XCTAssertTrue(issues.isEmpty, "\(issues)")
  }

  // MARK: - Spelling

  func testKeysAreNormalisedToTheCataloguesSpelling() {
    let cases: [String: String] = [
      "Shift+Cmd+K": "cmd+shift+k",
      "cmd-shift-k": "cmd+shift+k",
      "alt+return": "option+enter",
      "ctrl+option+Up": "ctrl+option+up",
      "command+,": "cmd+comma",
      "esc": "escape",
      "backspace": "delete",
      "?": "?",
      "-": "-",
      "cmd+-": "cmd+-",
      "shift+1": "shift+1",
      "GH": "gh",
    ]
    for (raw, expected) in cases {
      XCTAssertEqual(try? WorkspaceKeymap.normalizedKey(raw).get(), expected, raw)
    }
  }

  /// A normalised key has to be one a key press can be spelled as, or the
  /// binding is dead on arrival.
  func testANormalisedChordMatchesTheKeyPress() {
    let pressed = WorkspaceCommandCatalog.key(
      keyCode: 40, charactersIgnoringModifiers: "k", shift: true, ctrl: false, cmd: true, option: false)
    XCTAssertEqual(pressed, try? WorkspaceKeymap.normalizedKey("shift+cmd+k").get())
  }

  func testContextsAreSurfaceNames() {
    XCTAssertEqual(WorkspaceKeymap.surface(named: "Board"), .board)
    XCTAssertEqual(WorkspaceKeymap.surface(named: "focusRunning"), .focusRunning)
    XCTAssertNil(WorkspaceKeymap.surface(named: "Workspace"))
  }

  // MARK: - Installing

  func testTheCatalogueReadsWhateverIsInstalled() {
    let (bindings, _) = resolve(#"[{"bindings": {"cmd+shift+k": "taskComplete"}}]"#)
    WorkspaceCommandCatalog.install(bindings)
    defer { WorkspaceCommandCatalog.install(WorkspaceCommandCatalog.defaultBindings) }
    XCTAssertEqual(WorkspaceCommandCatalog.command(forKey: "cmd+shift+k", on: .outline)?.id, .taskComplete)
    XCTAssertTrue(WorkspaceCommandCatalog[.taskComplete].displayKeys.contains("⌘⇧K"))
  }
}
