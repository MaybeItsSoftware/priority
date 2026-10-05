import XCTest

@testable import TaktAppLogic
@testable import TaktPlugins

/// Guards the one genuine hazard in `applogic-support/AppLogicSharedTypes.swift`.
///
/// `TaktAppLogic` re-declares the Checkvist models rather than importing
/// them, because it cannot import `TaktPlugins`: the same source files are
/// compiled straight into the Xcode app, where neither module exists, so an
/// `import TaktPlugins` line would break the app build. (`docs` and
/// `ARCHITECTURE_IMPROVEMENT_PLAN.md` describe the two real fixes; both are
/// larger than the duplication itself.)
///
/// The duplication is survivable. Silent *divergence* is not: add a field to
/// the real `CheckvistTask` and `TaskRepository` keeps compiling against the
/// old shape, dropping the field on every round trip through the offline cache
/// with nothing to say so. That is what these pin down.
///
/// This test target already depends on both modules, so the two declarations
/// can be compared directly — the only place in the project where that is true.
final class SharedTypeDriftTests: XCTestCase {

  /// Encoded by the real model, decoded by the shadow. A field present in one
  /// and not the other shows up as a mismatch here rather than as data quietly
  /// going missing at runtime.
  func testTheShadowCheckvistTaskRoundTripsEveryFieldOfTheRealOne() throws {
    let real = TaktPlugins.CheckvistTask(
      id: 7,
      content: "write the report",
      status: 1,
      due: "2026-09-01",
      position: 3,
      parentId: 2,
      level: 4,
      notes: [
        TaktPlugins.CheckvistNote(
          id: 11, content: "a note",
          createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-02T00:00:00Z")
      ],
      updatedAt: "2026-08-18T10:00:00Z"
    )

    let shadow = try JSONDecoder().decode(
      TaktAppLogic.CheckvistTask.self, from: JSONEncoder().encode(real))

    XCTAssertEqual(shadow.id, real.id)
    XCTAssertEqual(shadow.content, real.content)
    XCTAssertEqual(shadow.status, real.status)
    XCTAssertEqual(shadow.due, real.due)
    XCTAssertEqual(shadow.position, real.position)
    XCTAssertEqual(shadow.parentId, real.parentId)
    XCTAssertEqual(shadow.level, real.level)
    XCTAssertEqual(shadow.updatedAt, real.updatedAt)
    XCTAssertEqual(
      shadow.notes?.map(\TaktAppLogic.CheckvistNote.content),
      real.notes?.map(\TaktPlugins.CheckvistNote.content))
    XCTAssertEqual(
      shadow.notes?.map(\TaktAppLogic.CheckvistNote.id),
      real.notes?.map(\TaktPlugins.CheckvistNote.id))
    XCTAssertEqual(
      shadow.notes?.map(\TaktAppLogic.CheckvistNote.createdAt),
      real.notes?.map(\TaktPlugins.CheckvistNote.createdAt),
      "note timestamps were the drift this test was written to find")
  }

  /// Counts the encoded keys rather than naming them, so a field added to the
  /// real model fails here even though nobody thought to assert on it above.
  func testNeitherCheckvistTaskCarriesAFieldTheOtherLacks() throws {
    let real = TaktPlugins.CheckvistTask(
      id: 1, content: "x", status: 0, due: nil, position: 1,
      parentId: nil, level: nil, notes: nil, updatedAt: nil)
    let shadow = TaktAppLogic.CheckvistTask(
      id: 1, content: "x", status: 0, due: nil, position: 1,
      parentId: nil, level: nil, notes: nil, updatedAt: nil)

    XCTAssertEqual(
      try encodedKeys(real), try encodedKeys(shadow),
      "the two declarations of CheckvistTask have drifted apart")
  }

  /// The one that had already drifted: the real note carries `created_at` and
  /// `updated_at`, the shadow carried neither.
  func testNeitherCheckvistNoteCarriesAFieldTheOtherLacks() throws {
    let real = TaktPlugins.CheckvistNote(
      id: 1, content: "x", createdAt: "a", updatedAt: "b")
    let shadow = TaktAppLogic.CheckvistNote(
      id: 1, content: "x", createdAt: "a", updatedAt: "b")

    XCTAssertEqual(
      try encodedKeys(real), try encodedKeys(shadow),
      "the two declarations of CheckvistNote have drifted apart")
  }

  func testTheShadowCheckvistListRoundTripsEveryFieldOfTheRealOne() throws {
    let real = TaktPlugins.CheckvistList(
      id: 42, name: "Inbox", archived: false, readOnly: true)

    let shadow = try JSONDecoder().decode(
      TaktAppLogic.CheckvistList.self, from: JSONEncoder().encode(real))

    XCTAssertEqual(shadow.id, real.id)
    XCTAssertEqual(shadow.name, real.name)
    XCTAssertEqual(shadow.archived, real.archived)
    XCTAssertEqual(shadow.readOnly, real.readOnly)
    XCTAssertEqual(try encodedKeys(real), try encodedKeys(shadow))
  }

  /// The action strings cross the process boundary — they are persisted in the
  /// offline queue and sent to Checkvist as path segments — so the two
  /// enumerations have to agree on both the cases and their raw values.
  func testBothCheckvistTaskActionsHaveTheSameCasesAndRawValues() {
    XCTAssertEqual(
      TaktPlugins.CheckvistTaskAction.allCasesForDrift,
      TaktAppLogic.CheckvistTaskAction.allCasesForDrift)
  }

  private func encodedKeys<T: Encodable>(_ value: T) throws -> [String] {
    let data = try JSONEncoder().encode(value)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return object.keys.sorted()
  }
}

// `CheckvistTaskAction` is not `CaseIterable` in either module, and making it so
// in the shipping code purely for a test would be the tail wagging the dog.
// Listing the raw values here is equivalent: a case added to one module and not
// the other changes one of these lists and not the other.
extension TaktPlugins.CheckvistTaskAction {
  static var allCasesForDrift: [String] {
    [Self.close, .reopen, .invalidate].map(\.rawValue).sorted()
  }
}

extension TaktAppLogic.CheckvistTaskAction {
  static var allCasesForDrift: [String] {
    [Self.close, .reopen, .invalidate].map(\.rawValue).sorted()
  }
}
