import Foundation
import XCTest

@testable import TaktAppLogic

/// Returns a `UserDefaults` instance backed by a fresh suite. Each test that
/// hits defaults should use one of these so suite contents from prior tests
/// can't leak into the suite under test. Caller is responsible for calling
/// `removePersistentDomain` on teardown if it wants the bytes wiped.
func makeIsolatedDefaults(file: StaticString = #file, line: UInt = #line) -> UserDefaults {
  let suiteName = "applogic-tests-\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    XCTFail("Could not create isolated UserDefaults suite", file: file, line: line)
    return .standard
  }
  return defaults
}

extension XCTestCase {
  /// `makeIsolatedDefaults` plus a teardown that wipes the suite, so repeated
  /// runs don't accumulate suite plists on disk. Prefer this in new tests.
  func makeIsolatedDefaultsSuite(file: StaticString = #file, line: UInt = #line) -> UserDefaults {
    let suiteName = "applogic-tests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Could not create isolated UserDefaults suite", file: file, line: line)
      return .standard
    }
    // Only the suite name crosses into the teardown block; the `UserDefaults`
    // instance itself isn't `Sendable`, and a fresh handle wipes the domain
    // just as well.
    addTeardownBlock {
      UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
    return defaults
  }
}

/// Convenience constructor matching the offline plugin's expectations.
func makeTask(
  id: Int,
  content: String = "",
  parentId: Int? = nil,
  status: Int = 0,
  position: Int? = nil,
  due: String? = nil
) -> CheckvistTask {
  CheckvistTask(
    id: id,
    content: content,
    status: status,
    due: due,
    position: position,
    parentId: parentId,
    level: nil,
    notes: nil,
    updatedAt: nil
  )
}

/// In-memory `CheckvistSyncPlugin` used to drive `TaskRepository` tests through
/// the "online" branch without touching the network. Records calls and lets the
/// test programme responses.
@MainActor
final class FakeCheckvistSyncPlugin: CheckvistSyncPlugin {
  let pluginIdentifier = "test.fake.checkvist"
  let displayName = "Fake Checkvist"
  let pluginDescription = "Test double"

  // Responses
  var loginResult: Bool = true
  var loginError: Error?
  var lists: [CheckvistList] = []
  var openTasksByListId: [String: [CheckvistTask]] = [:]
  var nextCreatedTaskId: Int = 1_000

  // Failure injection. Defaults keep every call succeeding, so tests that
  // don't care about failure paths are unaffected.
  var createTaskError: Error?
  /// Fires inside `createTask`, before it succeeds or throws — i.e. at the
  /// moment a real flush would be waiting on the network. Lets a test inspect
  /// what is on disk *during* the replay, which is the window a quit or crash
  /// falls into.
  var onCreateTask: (() -> Void)?
  /// Makes `createTask` report "no task created" without throwing — the
  /// server-said-no branch, which is distinct from the transport-failed one.
  var createTaskReturnsNil = false
  var updateTaskError: Error?
  var updateTaskResult = true
  var performTaskActionError: Error?
  var performTaskActionResult = true
  var deleteTaskError: Error?
  var deleteTaskResult = true
  /// Runs on the main actor immediately before `updateTask` returns or throws,
  /// so a test can shuffle the task list underneath an in-flight mutation.
  var beforeUpdateTaskReturns: (@MainActor () -> Void)?
  /// Same idea for `performTaskAction` — the window a refetch can land in while
  /// a close is on the wire.
  var beforePerformTaskActionReturns: (@MainActor () -> Void)?
  /// Same idea for `fetchOpenTasks`, and `async` so a test can drive a whole
  /// second fetch to completion while the first is still suspended.
  var beforeFetchOpenTasksReturns: (@MainActor () async -> Void)?

  // Recorded calls
  private(set) var loginCallCount = 0
  private(set) var fetchOpenTasksCalls: [String] = []
  private(set) var fetchListsCallCount = 0
  private(set) var createTaskCalls:
    [(listId: String, content: String, parentId: Int?, position: Int?)] = []
  private(set) var updateTaskCalls: [(taskId: Int, content: String?, due: String?)] = []
  private(set) var deleteTaskCalls: [Int] = []
  private(set) var moveTaskCalls: [(listId: String, taskId: Int, position: Int)] = []
  private(set) var performTaskActionCalls:
    [(listId: String, taskId: Int, action: CheckvistTaskAction)] = []
  private(set) var didClearAuthentication = false

  func login(credentials: CheckvistCredentials) async throws -> Bool {
    loginCallCount += 1
    if let loginError { throw loginError }
    return loginResult
  }

  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  {
    fetchOpenTasksCalls.append(listId)
    // Read before the hook runs: a real response is assembled server-side
    // before whatever the hook simulates happening mid-flight.
    let response = openTasksByListId[listId] ?? []
    await beforeFetchOpenTasksReturns?()
    return response
  }

  func fetchLists(credentials: CheckvistCredentials) async throws -> [CheckvistList] {
    fetchListsCallCount += 1
    return lists
  }

  func clearAuthentication() {
    didClearAuthentication = true
  }

  func performTaskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    performTaskActionCalls.append((listId, taskId, action))
    beforePerformTaskActionReturns?()
    if let performTaskActionError { throw performTaskActionError }
    return performTaskActionResult
  }

  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    updateTaskCalls.append((taskId, content, due))
    beforeUpdateTaskReturns?()
    if let updateTaskError { throw updateTaskError }
    return updateTaskResult
  }

  func createTask(
    listId: String,
    content: String,
    parentId: Int?,
    position: Int?,
    credentials: CheckvistCredentials
  ) async throws -> CheckvistTask? {
    createTaskCalls.append((listId, content, parentId, position))
    onCreateTask?()
    // A real create is a network round trip, so the replay genuinely suspends
    // here and anything else queued on the main actor gets to run. Yielding
    // reproduces that, which is what lets a test drive two overlapping flushes.
    await Task.yield()
    if let createTaskError { throw createTaskError }
    if createTaskReturnsNil { return nil }
    let id = nextCreatedTaskId
    nextCreatedTaskId += 1
    return makeTask(id: id, content: content, parentId: parentId, position: position)
  }

  func deleteTask(listId: String, taskId: Int, credentials: CheckvistCredentials) async throws
    -> Bool
  {
    deleteTaskCalls.append(taskId)
    if let deleteTaskError { throw deleteTaskError }
    return deleteTaskResult
  }

  func moveTask(
    listId: String,
    taskId: Int,
    position: Int,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    moveTaskCalls.append((listId, taskId, position))
    return true
  }

  func reparentTask(
    listId: String,
    taskId: Int,
    parentId: Int?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    true
  }

  func persistTaskCache(listId: String, tasks: [CheckvistTask]) {}
  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? { nil }
  func isTaskCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool { true }
}
