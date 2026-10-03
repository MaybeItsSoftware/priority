import Foundation
import PriorityCore
import XCTest

/// The Mac's themes folder against the synced `themes` table: which side
/// changed, and that nothing goes round in a loop.
final class ThemeFolderMirrorTests: XCTestCase {
  private typealias Mirror = ThemeFolderMirror

  private func file(_ name: String, _ text: String) -> ThemeFileSource {
    ThemeFileSource(name: name, data: Data(text.utf8))
  }

  /// Runs a plan to completion against an in-memory folder and table, the way
  /// `UserThemeLibrary` does, and returns how many passes it took to settle.
  private func settle(
    folder: inout [String: String], rows: inout [String: String], digests: inout [String: String]
  ) -> Int {
    for pass in 1...5 {
      let plan = Mirror.plan(
        files: folder.map { file($0.key, $0.value) }, rows: rows, digests: digests)
      digests = plan.digests
      if plan.actions.isEmpty { return pass }
      for action in plan.actions {
        switch action {
        case .upsertRow(let identifier, let json): rows[identifier] = json
        case .deleteRow(let identifier): rows[identifier] = nil
        case .writeFile(_, let name, let json): folder[name] = json
        case .removeFile(_, let name): folder[name] = nil
        }
      }
    }
    XCTFail("did not settle")
    return 0
  }

  func testANewFileBecomesARow() {
    let plan = Mirror.plan(files: [file("dusk.json", "{}")], rows: [:], digests: [:])
    XCTAssertEqual(plan.actions, [.upsertRow(identifier: "user.dusk", json: "{}")])
    XCTAssertEqual(plan.digests["user.dusk"], Mirror.digest("{}"))
  }

  func testAnEditedFileUpdatesItsRow() {
    let plan = Mirror.plan(
      files: [file("dusk.json", #"{"name":"New"}"#)], rows: ["user.dusk": "{}"],
      digests: ["user.dusk": Mirror.digest("{}")])
    XCTAssertEqual(plan.actions, [.upsertRow(identifier: "user.dusk", json: #"{"name":"New"}"#)])
  }

  func testARowEditedElsewhereIsWrittenIntoTheUnchangedFile() {
    let plan = Mirror.plan(
      files: [file("dusk.json", "{}")], rows: ["user.dusk": #"{"name":"Remote"}"#],
      digests: ["user.dusk": Mirror.digest("{}")])
    XCTAssertEqual(
      plan.actions, [.writeFile(identifier: "user.dusk", name: "dusk.json", json: #"{"name":"Remote"}"#)])
  }

  func testWhenBothChangedTheFileOnThisMacWins() {
    let plan = Mirror.plan(
      files: [file("dusk.json", #"{"name":"Local"}"#)], rows: ["user.dusk": #"{"name":"Remote"}"#],
      digests: ["user.dusk": Mirror.digest("{}")])
    XCTAssertEqual(plan.actions, [.upsertRow(identifier: "user.dusk", json: #"{"name":"Local"}"#)])
  }

  func testRemovingAFileDeletesItsRow() {
    let plan = Mirror.plan(files: [], rows: ["user.dusk": "{}"], digests: ["user.dusk": Mirror.digest("{}")])
    XCTAssertEqual(plan.actions, [.deleteRow(identifier: "user.dusk")])
    XCTAssertNil(plan.digests["user.dusk"])
  }

  func testARowFromAnotherDeviceIsWrittenUnderANameThatReadsBackAsIt() {
    let plan = Mirror.plan(
      files: [],
      rows: ["user.dusk": #"{"name":"Dusk"}"#, "mine.amber": #"{"identifier":"mine.amber"}"#],
      digests: [:])
    XCTAssertEqual(
      plan.actions,
      [
        .writeFile(identifier: "mine.amber", name: "mine.amber.json", json: #"{"identifier":"mine.amber"}"#),
        .writeFile(identifier: "user.dusk", name: "dusk.json", json: #"{"name":"Dusk"}"#),
      ])
  }

  func testARowDeletedElsewhereRemovesTheUnchangedFile() {
    let plan = Mirror.plan(files: [file("dusk.json", "{}")], rows: [:], digests: ["user.dusk": Mirror.digest("{}")])
    XCTAssertEqual(plan.actions, [.removeFile(identifier: "user.dusk", name: "dusk.json")])
  }

  func testARowDeletedElsewhereComesBackIfTheFileWasEditedHere() {
    let plan = Mirror.plan(
      files: [file("dusk.json", #"{"name":"Edited"}"#)], rows: [:], digests: ["user.dusk": Mirror.digest("{}")])
    XCTAssertEqual(plan.actions, [.upsertRow(identifier: "user.dusk", json: #"{"name":"Edited"}"#)])
  }

  /// A typo mid-edit must not read as "the file was removed": nothing is
  /// deleted or written while a file cannot be read.
  func testAnUnreadableFileHoldsBackDeletionsAndWrites() {
    let plan = Mirror.plan(
      files: [file("dusk.json", "{ not json"), file("other.json", "{}")],
      rows: ["user.dusk": "{}", "user.remote": "{}"],
      digests: ["user.dusk": Mirror.digest("{}")])
    XCTAssertEqual(plan.actions, [.upsertRow(identifier: "user.other", json: "{}")])
    XCTAssertEqual(plan.digests["user.dusk"], Mirror.digest("{}"), "remembered for when it reads again")
  }

  func testBuiltInsAndDuplicateIdentifiersAreNotMirrored() {
    let plan = Mirror.plan(
      files: [
        file("a.json", #"{"identifier":"native.theme.chalk"}"#),
        file("b.json", #"{"identifier":"mine.same","name":"B"}"#),
        file("c.json", #"{"identifier":"mine.same","name":"C"}"#),
      ],
      rows: [:], digests: [:])
    XCTAssertEqual(plan.actions, [.upsertRow(identifier: "mine.same", json: #"{"identifier":"mine.same","name":"B"}"#)])
  }

  func testARowWhoseFileNameIsTakenIsLeftAlone() {
    let plan = Mirror.plan(
      files: [file("dusk.json", #"{"identifier":"mine.other"}"#)],
      rows: ["user.dusk": "{}", "mine.other": #"{"identifier":"mine.other"}"#], digests: [:])
    XCTAssertEqual(plan.actions, [])
  }

  /// Two Macs sharing the table, by way of their own folders, settle in one
  /// round and then stay still.
  func testTwoFoldersSettleWithoutPingPong() {
    var macFolder = ["dusk.json": #"{"name":"Dusk"}"#]
    var otherFolder: [String: String] = [:]
    var rows: [String: String] = [:]
    var macDigests: [String: String] = [:]
    var otherDigests: [String: String] = [:]

    XCTAssertEqual(settle(folder: &macFolder, rows: &rows, digests: &macDigests), 2)
    XCTAssertEqual(settle(folder: &otherFolder, rows: &rows, digests: &otherDigests), 2)
    XCTAssertEqual(otherFolder, macFolder)

    // An edit on the other one reaches the Mac, and then everything is still.
    otherFolder["dusk.json"] = #"{"name":"Dusker"}"#
    XCTAssertEqual(settle(folder: &otherFolder, rows: &rows, digests: &otherDigests), 2)
    XCTAssertEqual(settle(folder: &macFolder, rows: &rows, digests: &macDigests), 2)
    XCTAssertEqual(macFolder["dusk.json"], #"{"name":"Dusker"}"#)
    XCTAssertEqual(settle(folder: &otherFolder, rows: &rows, digests: &otherDigests), 1)

    // A removal on the Mac removes it from the other one.
    macFolder["dusk.json"] = nil
    XCTAssertEqual(settle(folder: &macFolder, rows: &rows, digests: &macDigests), 2)
    XCTAssertEqual(rows, [:])
    XCTAssertEqual(settle(folder: &otherFolder, rows: &rows, digests: &otherDigests), 2)
    XCTAssertEqual(otherFolder, [:])
    XCTAssertEqual(otherDigests, [:])
  }
}
