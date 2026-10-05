import XCTest

@testable import TaktCore

final class CommandEngineCommandParsingTests: XCTestCase {

  // MARK: - Simple commands

  func testParseSimpleKeywordCommands() {
    XCTAssertEqual(CommandEngine.parse("done"), .done)
    XCTAssertEqual(CommandEngine.parse("undone"), .undone)
    XCTAssertEqual(CommandEngine.parse("invalidate"), .invalidate)
    XCTAssertEqual(CommandEngine.parse("edit"), .edit)
    XCTAssertEqual(CommandEngine.parse("search"), .search)
    XCTAssertEqual(CommandEngine.parse("undo"), .undo)
    XCTAssertEqual(CommandEngine.parse("delete"), .delete)
    XCTAssertEqual(CommandEngine.parse("toggle timer"), .toggleTimer)
    XCTAssertEqual(CommandEngine.parse("pause timer"), .pauseTimer)
    XCTAssertEqual(CommandEngine.parse("toggle hide future"), .toggleHideFuture)
  }

  func testParseCaseInsensitive() {
    XCTAssertEqual(CommandEngine.parse("DONE"), .done)
    XCTAssertEqual(CommandEngine.parse("Done"), .done)
    XCTAssertEqual(CommandEngine.parse("  done  "), .done)
  }

  // MARK: - Navigation

  func testParseNavigationCommands() {
    XCTAssertEqual(CommandEngine.parse("add sibling"), .addSibling)
    XCTAssertEqual(CommandEngine.parse("add child"), .addChild)
    XCTAssertEqual(CommandEngine.parse("move up"), .moveUp)
    XCTAssertEqual(CommandEngine.parse("move down"), .moveDown)
    XCTAssertEqual(CommandEngine.parse("enter children"), .enterChildren)
    XCTAssertEqual(CommandEngine.parse("exit parent"), .exitParent)
    XCTAssertEqual(CommandEngine.parse("open link"), .openLink)
  }

  // MARK: - Preferences aliases

  func testParsePreferencesAliases() {
    XCTAssertEqual(CommandEngine.parse("preferences"), .openPreferences)
    XCTAssertEqual(CommandEngine.parse("prefs"), .openPreferences)
    XCTAssertEqual(CommandEngine.parse("settings"), .openPreferences)
  }

  // MARK: - Due date

  func testParseDueCommand() {
    XCTAssertEqual(CommandEngine.parse("due today"), .due("today"))
    XCTAssertEqual(CommandEngine.parse("due tomorrow 9am"), .due("tomorrow 9am"))
    XCTAssertEqual(CommandEngine.parse("due next week"), .due("next week"))
  }

  func testParseClearDue() {
    XCTAssertEqual(CommandEngine.parse("clear due"), .clearDue)
  }

  // MARK: - Tags

  func testParseTagCommand() {
    XCTAssertEqual(CommandEngine.parse("tag urgent"), .tag("urgent"))
    XCTAssertEqual(CommandEngine.parse("tag  spaced "), .tag("spaced"))
  }

  func testParseUntagCommand() {
    XCTAssertEqual(CommandEngine.parse("untag urgent"), .untag("urgent"))
  }

  // MARK: - List

  func testParseListCommand() {
    XCTAssertEqual(CommandEngine.parse("list my-list"), .list("my-list"))
  }

  // MARK: - Priority

  func testParsePriorityRanks() {
    for rank in 1...9 {
      XCTAssertEqual(CommandEngine.parse("priority \(rank)"), .priority(rank))
    }
  }

  func testParsePriorityOutOfRange() {
    XCTAssertEqual(CommandEngine.parse("priority 0"), .unknown("priority 0"))
  }

  func testParsePriorityAcceptsAnyPositiveRank() {
    XCTAssertEqual(CommandEngine.parse("priority 10"), .priority(10))
    XCTAssertEqual(CommandEngine.parse("priority 99"), .priority(99))
  }

  func testParsePriorityBack() {
    XCTAssertEqual(CommandEngine.parse("priority back"), .priorityBack)
    XCTAssertEqual(CommandEngine.parse("priority end"), .priorityBack)
  }

  func testParsePriorityClear() {
    XCTAssertEqual(CommandEngine.parse("priority clear"), .clearPriority)
    XCTAssertEqual(CommandEngine.parse("clear priority"), .clearPriority)
    XCTAssertEqual(CommandEngine.parse("unpriority"), .clearPriority)
  }

  // MARK: - Obsidian

  func testParseObsidianSyncAliases() {
    XCTAssertEqual(CommandEngine.parse("sync obsidian"), .syncObsidian)
    XCTAssertEqual(CommandEngine.parse("send to obsidian"), .syncObsidian)
    XCTAssertEqual(CommandEngine.parse("obsidian"), .syncObsidian)
  }

  func testParseObsidianNewWindowAliases() {
    XCTAssertEqual(CommandEngine.parse("open obsidian new window"), .syncObsidianNewWindow)
    XCTAssertEqual(CommandEngine.parse("obsidian new window"), .syncObsidianNewWindow)
    XCTAssertEqual(CommandEngine.parse("open in new window"), .syncObsidianNewWindow)
  }

  func testParseObsidianFolderCommands() {
    XCTAssertEqual(CommandEngine.parse("link obsidian folder"), .linkObsidianFolder)
    XCTAssertEqual(CommandEngine.parse("link folder"), .linkObsidianFolder)
    XCTAssertEqual(CommandEngine.parse("obsidian folder"), .linkObsidianFolder)

    XCTAssertEqual(CommandEngine.parse("create obsidian folder"), .createObsidianFolder)
    XCTAssertEqual(CommandEngine.parse("new obsidian folder"), .createObsidianFolder)
    XCTAssertEqual(CommandEngine.parse("make obsidian folder"), .createObsidianFolder)

    XCTAssertEqual(
      CommandEngine.parse("clear obsidian folder"), .clearObsidianFolderLink)
    XCTAssertEqual(
      CommandEngine.parse("unlink obsidian folder"), .clearObsidianFolderLink)
    XCTAssertEqual(CommandEngine.parse("clear folder link"), .clearObsidianFolderLink)
  }

  // MARK: - Google Calendar

  func testParseGoogleCalendarCommandAliases() {
    XCTAssertEqual(CommandEngine.parse("sync google calendar"), .syncGoogleCalendar)
    XCTAssertEqual(CommandEngine.parse("google calendar"), .syncGoogleCalendar)
    XCTAssertEqual(CommandEngine.parse("gcal"), .syncGoogleCalendar)
    XCTAssertEqual(CommandEngine.parse("open google calendar"), .syncGoogleCalendar)
    XCTAssertEqual(CommandEngine.parse("calendar"), .syncGoogleCalendar)
  }

  // MARK: - Unknown

  func testParseUnknownCommand() {
    XCTAssertEqual(CommandEngine.parse("gibberish"), .unknown("gibberish"))
    XCTAssertEqual(CommandEngine.parse(""), .unknown(""))
  }

  // MARK: - Suggestion filtering

  func testGoogleCalendarSuggestionIsAvailable() {
    let suggestions = CommandEngine.filteredSuggestions(query: "google")
    XCTAssertTrue(
      suggestions.contains(where: {
        $0.command == "sync google calendar" && $0.keybind == "gc" && $0.submitImmediately
      })
    )
  }

  func testFilteredSuggestionsReturnsAllForEmptyQuery() {
    let all = CommandEngine.filteredSuggestions(query: "")
    XCTAssertEqual(all.count, CommandEngine.suggestions.count)
  }

  func testFilteredSuggestionsMatchesLabel() {
    let results = CommandEngine.filteredSuggestions(query: "timer")
    XCTAssertTrue(results.contains(where: { $0.command == "toggle timer" }))
    XCTAssertTrue(results.contains(where: { $0.command == "pause timer" }))
  }

  // MARK: - Due date resolution edge cases

  func testResolveDueDateNoonAndMidnight() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      CommandEngine.resolveDueDate("today noon", now: now, calendar: calendar),
      "2026-04-01 12:00:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("today midnight", now: now, calendar: calendar),
      "2026-04-01 00:00:00 +0000"
    )
  }

  func testResolveDueDateTwelveHourFormats() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      CommandEngine.resolveDueDate("12pm", now: now, calendar: calendar),
      "2026-04-01 12:00:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("12am", now: now, calendar: calendar),
      "2026-04-01 00:00:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("1:30pm", now: now, calendar: calendar),
      "2026-04-01 13:30:00 +0000"
    )
  }

  func testResolveDueDateTwentyFourHourFormat() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      CommandEngine.resolveDueDate("23:45", now: now, calendar: calendar),
      "2026-04-01 23:45:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("0:00", now: now, calendar: calendar),
      "2026-04-01 00:00:00 +0000"
    )
  }

  func testResolveDueDateRelativeOffsets() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      CommandEngine.resolveDueDate("in 30m", now: now, calendar: calendar),
      "2026-04-01 10:30:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("in 2h", now: now, calendar: calendar),
      "2026-04-01 12:00:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("in 1 day", now: now, calendar: calendar),
      "2026-04-02 10:00:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("in 45 minutes", now: now, calendar: calendar),
      "2026-04-01 10:45:00 +0000"
    )
  }

  func testResolveDueDatePassthroughForUnrecognized() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    // Unrecognized input should pass through unchanged
    XCTAssertEqual(
      CommandEngine.resolveDueDate("asap", now: now, calendar: calendar),
      "asap"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("", now: now, calendar: calendar),
      ""
    )
  }

  func testResolveDueDateWeekdays() {
    let calendar = makeUTCCalendar()
    // 2026-04-01 is a Wednesday
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    // Friday should be 2 days out
    XCTAssertEqual(
      CommandEngine.resolveDueDate("friday", now: now, calendar: calendar),
      "2026-04-03"
    )
    // Next month
    XCTAssertEqual(
      CommandEngine.resolveDueDate("next month", now: now, calendar: calendar),
      "2026-05-01"
    )
  }

  func testResolveDueDateWithAtPrefix() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      CommandEngine.resolveDueDate("today at 3pm", now: now, calendar: calendar),
      "2026-04-01 15:00:00 +0000"
    )
  }

  // MARK: - Helpers

  private func makeUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }

  private func makeDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    calendar: Calendar
  ) -> Date {
    let components = DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute
    )
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
  }
}
