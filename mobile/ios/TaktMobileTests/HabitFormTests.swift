import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

/// The habit form: Android's `HabitFormTest` rules, and a save through the store.
@MainActor
final class HabitFormTests: XCTestCase {
  func testWeekdaysKeepOneAndAllSevenIsEveryDay() {
    let start = HabitForm.with(.daily, kind: .weekdays)
    XCTAssertEqual(start, .weekdays([2, 3, 4, 5, 6]))
    XCTAssertEqual(HabitForm.toggle(2, in: .weekdays([2])), .weekdays([2]))
    XCTAssertEqual(HabitForm.toggle(7, in: HabitForm.toggle(1, in: start)), .daily)
    XCTAssertEqual(HabitForm.step(.everyNDays(2), by: -1), .everyNDays(2))
    XCTAssertEqual(HabitForm.step(.everyNDays(3), by: 1), .everyNDays(4))
  }

  func testEstimateTextRoundTrips() {
    XCTAssertEqual(HabitForm.estimateText(1800), "30m")
    XCTAssertEqual(HabitForm.estimateText(3600), "1h")
    XCTAssertEqual(HabitForm.estimateText(5400), "1h30")
    XCTAssertEqual(HabitForm.estimateText(nil), "")
  }

  func testValidationNamesTheField() {
    let draft = HabitDraft(title: "  ")
    guard case .failure(let blank) = HabitForm.validate(draft, estimateText: "", expiryDateText: "") else {
      return XCTFail("a blank title saved")
    }
    XCTAssertEqual(blank.field, .title)
    let named = HabitDraft(title: " Drums ")
    guard case .failure(let estimate) = HabitForm.validate(named, estimateText: "soon", expiryDateText: "") else {
      return XCTFail("an unreadable estimate saved")
    }
    XCTAssertEqual(estimate.field, .estimate)
    guard case .success(let valid) = HabitForm.validate(named, estimateText: "30m", expiryDateText: "") else {
      return XCTFail("a good draft was refused")
    }
    XCTAssertEqual(valid.title, "Drums")
    XCTAssertEqual(valid.estimateSeconds, 1800)
  }

  func testAStandaloneHabitSavesAsADailyWithUndo() throws {
    let model = try WorkspaceModel.temporary()
    let context = try XCTUnwrap(model.habitFormContext(forTaskID: nil))
    XCTAssertNil(context.habitTaskId)
    var draft = context.draft
    draft.title = "Practise drums"
    XCTAssertTrue(model.saveHabit(draft, habitTaskID: nil))
    XCTAssertEqual(model.toastAction, .undo)
    let daily = try XCTUnwrap(try model.store.allDailies().first)
    XCTAssertTrue(daily.isHabit)
    let edit = try XCTUnwrap(model.habitFormContext(forTaskID: daily.taskId))
    XCTAssertEqual(edit.habitTaskId, daily.taskId)
    XCTAssertEqual(edit.draft.title, "Practise drums")
  }
}
