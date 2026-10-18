import Foundation
import XCTest

@testable import TaktPlugins

final class NativeLinksPluginTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktLinks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func make(_ path: String, folder: Bool = false) throws {
    let url = directory.appendingPathComponent(path)
    if folder {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } else {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("# note".utf8).write(to: url)
    }
  }

  func testAVaultListsItsNotesAndFoldersButNotItsDotFolders() throws {
    try make("Life/.obsidian", folder: true)
    try make("Life/Projects/Takt plan.md")
    try make("Life/Projects/diagram.png")
    try make("Life/.trash/Old.md")
    let vault = ObsidianVault(url: directory.appendingPathComponent("Life"))
    let entries = ObsidianVaultIndex.entries(in: vault)
    XCTAssertEqual(Set(entries.map(\.searchText)), ["Projects", "Projects/Takt plan"])
    let note = try XCTUnwrap(entries.first { !$0.isFolder })
    XCTAssertEqual(note.url, "obsidian://open?vault=Life&file=Projects%2FTakt%20plan.md")
    XCTAssertEqual(note.title, "Takt plan")
    XCTAssertEqual(note.subtitle, "Life · Projects")
  }

  func testTheVaultAroundAFolderIsTheNearestWithAnObsidianFolder() throws {
    try make("Life/.obsidian", folder: true)
    try make("Life/Journal/Daily", folder: true)
    let root = ObsidianVaultIndex.vaultRoot(containing: directory.appendingPathComponent("Life/Journal/Daily"))
    XCTAssertEqual(root?.standardizedFileURL.path, directory.appendingPathComponent("Life").standardizedFileURL.path)
    XCTAssertNil(ObsidianVaultIndex.vaultRoot(containing: directory))
  }

  func testObsidiansOwnListOfVaultsIsRead() throws {
    let config = directory.appendingPathComponent("obsidian.json")
    try Data(#"{"vaults":{"a":{"path":"/tmp/Life","ts":1},"b":{"path":"/tmp/Studies"}}}"#.utf8).write(to: config)
    XCTAssertEqual(ObsidianVaultIndex.configuredVaults(at: config).map(\.path), ["/tmp/Life", "/tmp/Studies"])
  }

  func testADriveSearchAsksForNamesAndReadsFilesBack() throws {
    XCTAssertEqual(
      GoogleDriveSearch.query(for: "Q3 'plan'"), #"name contains 'Q3 \'plan\'' and trashed = false"#)
    let request = try XCTUnwrap(GoogleDriveSearch.request(for: "budget"))
    XCTAssertTrue(request.url?.absoluteString.hasPrefix(GoogleDriveSearch.endpoint) ?? false)
    let data = Data(
      #"""
      {"files":[
        {"id":"1","name":"Budget","mimeType":"application/vnd.google-apps.spreadsheet",
         "webViewLink":"https://docs.google.com/spreadsheets/d/1/edit"},
        {"id":"2","name":"Receipts","mimeType":"application/vnd.google-apps.folder"}
      ]}
      """#.utf8)
    let found = try GoogleDriveSearch.candidates(from: data)
    XCTAssertEqual(found.map(\.title), ["Budget", "Receipts"])
    XCTAssertEqual(found[0].subtitle, "Google Sheet")
    XCTAssertEqual(found[1].url, "https://drive.google.com/open?id=2")
    XCTAssertTrue(found[1].isFolder)
  }
}
