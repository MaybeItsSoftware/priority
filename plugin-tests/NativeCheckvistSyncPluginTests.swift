import Foundation
import XCTest

@testable import TaktPlugins

@MainActor
final class NativeCheckvistSyncPluginTests: XCTestCase {
  func testFetchListsFiltersArchivedLists() async throws {
    let session = CheckvistSession()
    let plugin = NativeCheckvistSyncPlugin(session: session)
    session.nextResponseStatusCode = 200
    session.nextResponseData = Data(
      #"[{"id":1,"name":"Open","archived":false},{"id":2,"name":"Archived","archived":true},{"id":3,"name":"NoArchiveFlag"}]"#
        .utf8
    )
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "key")

    let lists = try await plugin.fetchLists(credentials: credentials)

    XCTAssertEqual(lists.map(\.id), [1, 3])
    XCTAssertEqual(lists.map(\.name), ["Open", "NoArchiveFlag"])
  }

  func testFetchListsThrowsOnServerErrorInsteadOfReportingNoLists() async throws {
    let session = CheckvistSession()
    let plugin = NativeCheckvistSyncPlugin(session: session)
    session.nextResponseStatusCode = 503
    session.nextResponseData = Data("<html>unavailable</html>".utf8)
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "key")

    do {
      _ = try await plugin.fetchLists(credentials: credentials)
      XCTFail("A 503 must surface as a failed fetch, not an empty list.")
    } catch CheckvistSessionError.invalidResponse(let statusCode) {
      XCTAssertEqual(statusCode, 503)
    }
  }

  func testFetchListsThrowsAuthenticationUnavailableOnUnauthorized() async throws {
    let session = CheckvistSession()
    let plugin = NativeCheckvistSyncPlugin(session: session)
    session.nextResponseStatusCode = 401
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "key")

    do {
      _ = try await plugin.fetchLists(credentials: credentials)
      XCTFail("A 401 must surface as an authentication failure.")
    } catch CheckvistSessionError.authenticationUnavailable {
      // expected
    }
  }

  func testFetchOpenTasksAsksForNotesAndReadsParentsFirstWithoutClosedTasks() async throws {
    let session = CheckvistSession()
    let plugin = NativeCheckvistSyncPlugin(session: session)
    session.nextResponseData = Data(
      #"""
      [{"id":2,"content":"Child","status":0,"parent_id":1,"position":1},
       {"id":3,"content":"Done","status":1,"parent_id":0,"position":2},
       {"id":1,"content":"Parent","status":0,"parent_id":0,"position":1,
        "notes":[{"id":9,"comment":"A note"}]}]
      """#.utf8)
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "key")

    let tasks = try await plugin.fetchOpenTasks(listId: "42", credentials: credentials)

    XCTAssertEqual(tasks.map(\.id), [1, 2])
    XCTAssertEqual(tasks.first?.notes?.first?.content, "A note")
    let url = try XCTUnwrap(session.recordedRequests.first?.url?.absoluteString)
    XCTAssertTrue(url.contains("/checklists/42/tasks.json"), url)
    XCTAssertTrue(url.contains("with_notes=true"), url)
  }

  func testFetchOpenTasksThrowsAuthenticationUnavailableOnUnauthorized() async throws {
    let session = CheckvistSession()
    let plugin = NativeCheckvistSyncPlugin(session: session)
    session.nextResponseStatusCode = 401
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "key")

    do {
      _ = try await plugin.fetchOpenTasks(listId: "42", credentials: credentials)
      XCTFail("A 401 must surface as an authentication failure.")
    } catch CheckvistSessionError.authenticationUnavailable {
      // expected
    }
  }
}
