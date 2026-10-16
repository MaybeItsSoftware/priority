import Foundation
import TaktCore
import XCTest

final class FocusNoteTests: XCTestCase {
  func testAnEmptyNoteLeavesTheNotesAlone() {
    XCTAssertEqual(FocusNote.appending("  \n ", to: "Existing", stamp: "16 Oct"), "Existing")
  }

  func testTheFirstNoteIsTheWholeOfTheNotes() {
    XCTAssertEqual(FocusNote.appending(" Drafted the intro ", to: "", stamp: "16 Oct"), "16 Oct — Drafted the intro")
  }

  func testALaterNoteIsItsOwnParagraph() {
    XCTAssertEqual(
      FocusNote.appending("Sent it", to: "16 Oct — Drafted\n\n", stamp: "17 Oct"),
      "16 Oct — Drafted\n\n17 Oct — Sent it")
  }

  func testTheStampIsDayAndShortMonth() {
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 16, hour: 12).date!
    XCTAssertEqual(FocusNote.stamp(for: date, locale: Locale(identifier: "en_GB")), "16 Oct")
  }
}
