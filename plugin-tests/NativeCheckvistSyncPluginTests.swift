import Foundation
import XCTest

@testable import TaktPlugins

@MainActor
final class NativeCheckvistSyncPluginTests: XCTestCase {
  func testCreateListBuildsFormEncodedRequestAndDecodesWrappedResponse() async throws {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
    session.nextResponseStatusCode = 201
    session.nextResponseData = Data(
      #"{"checklist":{"id":901,"name":"My New List","archived":false}}"#.utf8
    )
    let credentials = CheckvistCredentials(username: " user@example.com ", remoteKey: " rkey ")

    let created = try await plugin.createList(name: "  My New List  ", credentials: credentials)

    XCTAssertEqual(created?.id, 901)
    XCTAssertEqual(created?.name, "My New List")
    XCTAssertEqual(session.performRequestCallCount, 1)
    XCTAssertEqual(session.lastRequestUsername, "user@example.com")
    XCTAssertEqual(session.lastRequestRemoteKey, "rkey")

    let request = try XCTUnwrap(session.recordedRequests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/checklists.json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Token"), session.issuedToken)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )
    let body = String(data: request.httpBody ?? Data(), encoding: .utf8)
    XCTAssertEqual(body, "checklist[name]=My%20New%20List")
  }

  func testFetchListsFiltersArchivedLists() async throws {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
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

  func testCreateTaskBuildsFormEncodedRequestAndDecodesCreatedTask() async throws {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
    session.nextResponseStatusCode = 201
    session.nextResponseData = Data(
      #"{"id":77,"content":"New task","status":0,"parent_id":55,"position":2}"#.utf8
    )
    let credentials = CheckvistCredentials(username: " user@example.com ", remoteKey: " rkey ")

    let created = try await plugin.createTask(
      listId: "12",
      content: "  New task  ",
      parentId: 55,
      position: 2,
      credentials: credentials
    )

    XCTAssertEqual(created?.id, 77)
    XCTAssertEqual(created?.content, "New task")
    XCTAssertEqual(created?.parentId, 55)
    XCTAssertEqual(created?.position, 2)

    let request = try XCTUnwrap(session.recordedRequests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/checklists/12/tasks.json")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    let body = String(data: request.httpBody ?? Data(), encoding: .utf8)
    XCTAssertEqual(body, "task[content]=New%20task&task[parent_id]=55&task[position]=2")
  }

  func testCreateTaskDecodesWrappedTaskResponse() async throws {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
    session.nextResponseStatusCode = 201
    session.nextResponseData = Data(
      #"{"task":{"id":88,"content":"Wrapped task","status":0,"parent_id":null,"position":1}}"#.utf8
    )
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "rkey")

    let created = try await plugin.createTask(
      listId: "12",
      content: "Wrapped task",
      parentId: nil,
      position: 1,
      credentials: credentials
    )

    XCTAssertEqual(created?.id, 88)
    XCTAssertEqual(created?.content, "Wrapped task")
  }

  func testCreateTaskDecodesTaskArrayResponse() async throws {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
    session.nextResponseStatusCode = 201
    session.nextResponseData = Data(
      #"[{"id":99,"content":"Array task","status":0,"parent_id":null,"position":1}]"#.utf8
    )
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "rkey")

    let created = try await plugin.createTask(
      listId: "12",
      content: "Array task",
      parentId: nil,
      position: 1,
      credentials: credentials
    )

    XCTAssertEqual(created?.id, 99)
    XCTAssertEqual(created?.content, "Array task")
  }

  func testUpdateTaskWithNoFieldsSkipsNetworkCall() async throws {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "key")

    let success = try await plugin.updateTask(
      listId: "12",
      taskId: 5,
      content: nil,
      due: nil,
      credentials: credentials
    )

    XCTAssertTrue(success)
    XCTAssertEqual(session.performRequestCallCount, 0)
  }

  func testUpdateTaskWithDueOnlyOmitsParseFlag() async throws {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
    session.nextResponseStatusCode = 200
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "key")

    let success = try await plugin.updateTask(
      listId: "12",
      taskId: 5,
      content: nil,
      due: "tomorrow",
      credentials: credentials
    )

    XCTAssertTrue(success)
    let request = try XCTUnwrap(session.recordedRequests.first)
    XCTAssertEqual(request.httpMethod, "PUT")
    XCTAssertEqual(request.url?.path, "/checklists/12/tasks/5.json")
    // parse=true must NOT be sent for due-only updates — it causes the
    // server to re-parse the content and overwrite the explicit due_date.
    XCTAssertNil(request.url?.query)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )
    let body = String(data: request.httpBody ?? Data(), encoding: .utf8)
    XCTAssertEqual(body, "task[due_date]=tomorrow")
  }

  func testUpdateTaskWithContentAndDueOmitsParseFlag() async throws {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
    session.nextResponseStatusCode = 200
    let credentials = CheckvistCredentials(username: "user@example.com", remoteKey: "key")

    let success = try await plugin.updateTask(
      listId: "12",
      taskId: 5,
      content: "Updated task",
      due: "tomorrow",
      credentials: credentials
    )

    XCTAssertTrue(success)
    let request = try XCTUnwrap(session.recordedRequests.first)
    // parse=true must never be sent — it strips inline #tags from content
    // and can overwrite explicit due_date values.
    XCTAssertNil(request.url?.query)
    let body = String(data: request.httpBody ?? Data(), encoding: .utf8)
    XCTAssertEqual(body, "task[content]=Updated%20task&task[due_date]=tomorrow")
  }

  func testPersistAndLoadTaskCacheDelegatesToRepository() {
    let session = CheckvistSession()
    let repository = CheckvistTaskRepository()
    let plugin = NativeCheckvistSyncPlugin(session: session, taskRepository: repository)
    let tasks = [CheckvistTask(id: 50, content: "Task", status: 0, due: nil)]

    plugin.persistTaskCache(listId: "42", tasks: tasks)
    let persisted = repository.persistedPayload
    XCTAssertEqual(persisted?.listId, "42")
    XCTAssertEqual(persisted?.tasks, tasks)

    repository.cachedPayloadByListId["99"] = CheckvistTaskCachePayload(
      listId: "99",
      fetchedAt: Date(timeIntervalSince1970: 100),
      tasks: tasks
    )

    let loaded = plugin.loadTaskCache(for: "99")
    XCTAssertEqual(loaded?.listId, "99")

    repository.isCacheOutdatedResult = true
    XCTAssertTrue(plugin.isTaskCacheOutdated(loaded!))
  }
}
