import Foundation
import XCTest

@testable import PriorityPlugins

@MainActor
final class NativeGoogleCalendarIntegrationPluginTests: XCTestCase {
  func testMakeCreateEventURLUsesAllDayRangeForDateOnlyDue() {
    let defaults = makeIsolatedDefaults()
    let calendar = makeUTCCalendar()
    let plugin = NativeGoogleCalendarIntegrationPlugin(
      account: makeAccount(defaults: defaults),
      defaultEventDurationMinutes: 30,
      calendar: calendar,
      defaults: defaults
    )
    let task = CheckvistTask(
      id: 101,
      content: "Plan launch",
      status: 0,
      due: "2026-04-02"
    )

    let url = plugin.makeCreateEventURL(task: task, listId: "55", now: makeDate(2026, 4, 1, 9, 0))
    let query = queryDictionary(from: url)

    XCTAssertEqual(query["action"], "TEMPLATE")
    XCTAssertEqual(query["text"], "Plan launch")
    XCTAssertEqual(query["dates"], "20260402/20260403")
    XCTAssertEqual(query["ctz"], calendar.timeZone.identifier)
  }

  func testMakeCreateEventURLUsesDateTimeRangeWhenDueIncludesTime() {
    let defaults = makeIsolatedDefaults()
    let calendar = makeUTCCalendar()
    let plugin = NativeGoogleCalendarIntegrationPlugin(
      account: makeAccount(defaults: defaults),
      defaultEventDurationMinutes: 30,
      calendar: calendar,
      defaults: defaults
    )
    let task = CheckvistTask(
      id: 202,
      content: "Ship release",
      status: 0,
      due: "2026-04-02T08:30:00Z"
    )

    let url = plugin.makeCreateEventURL(task: task, listId: "77", now: makeDate(2026, 4, 1, 9, 0))
    let query = queryDictionary(from: url)

    XCTAssertEqual(query["dates"], "20260402T083000Z/20260402T090000Z")
  }

  func testCreateEventRequiresOAuthWhenOAuthNotConfigured() async {
    let defaults = makeIsolatedDefaults()
    let plugin = NativeGoogleCalendarIntegrationPlugin(
      account: makeAccount(defaults: defaults), defaults: defaults)
    let now = makeDate(2026, 4, 3, 10, 0)
    let task = CheckvistTask(id: 303, content: "Review notes", status: 0, due: nil)

    do {
      _ = try await plugin.createEvent(task: task, listId: "88", now: now)
      XCTFail("Expected createEvent to require OAuth configuration")
    } catch {
      XCTAssertEqual(
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        "Set a Google OAuth client ID first."
      )
    }
  }

  /// An account with nowhere to read a token from, so these tests never touch
  /// the login keychain: every one of them is about an unconfigured client.
  private func makeAccount(defaults: UserDefaults) -> GoogleAccount {
    GoogleAccount(defaults: defaults, legacyTokenStore: nil)
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "priority-plugin-tests-google-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  private func makeUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }

  private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var calendar = makeUTCCalendar()
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
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

  private func queryDictionary(from url: URL?) -> [String: String] {
    guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return [:]
    }
    return (components.queryItems ?? []).reduce(into: [:]) { partialResult, item in
      partialResult[item.name] = item.value
    }
  }
}
