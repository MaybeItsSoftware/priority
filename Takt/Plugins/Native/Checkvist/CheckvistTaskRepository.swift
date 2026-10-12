import Foundation
import TaktCore
import TaktRustCore
import OSLog

// `CheckvistTaskCachePayload` moved to `CheckvistTaskCachePayload.swift` so it
// can be shared with `TaktPlugins` / `TaktAppLogic` without the
// fetcher.

struct CheckvistTaskRepository {
  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "task-repository")
  private static let cacheFreshnessInterval: TimeInterval = 15 * 60

  func fetchTasks(
    listId: String,
    performAuthenticatedRequest:
      @escaping @MainActor (
        (String) throws -> URLRequest
      ) async throws -> (Data, HTTPURLResponse)
  ) async throws -> [CheckvistTask] {
    let call = CheckvistCall.tasks(listId: listId, withNotes: true)
    guard (try? CheckvistWire.request(call, token: nil)) != nil else {
      throw CheckvistTaskRepositoryError.invalidListURL
    }
    let (data, httpResponse) = try await performAuthenticatedRequest { validToken in
      try CheckvistWire.request(call, token: validToken)
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw CheckvistTaskRepositoryError.fetchFailed(statusCode: httpResponse.statusCode)
    }

    // Open tasks only, parents before their children, read by the core.
    return try checkvistTasks(body: CheckvistWire.text(data), includeClosed: false)
      .map(CheckvistTask.init(core:))
  }

  func persistTaskCache(_ payload: CheckvistTaskCachePayload) {
    guard let cacheURL = taskCacheURL(for: payload.listId) else { return }

    do {
      let data = try JSONEncoder().encode(payload)
      try data.write(to: cacheURL, options: [.atomic])
    } catch {
      logger.error("Failed to persist task cache: \(error.localizedDescription, privacy: .public)")
    }
  }

  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? {
    guard let cacheURL = taskCacheURL(for: listId) else { return nil }

    do {
      let data = try Data(contentsOf: cacheURL)
      return try JSONDecoder().decode(CheckvistTaskCachePayload.self, from: data)
    } catch {
      return nil
    }
  }

  func isCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool {
    Date().timeIntervalSince(payload.fetchedAt) > Self.cacheFreshnessInterval
  }

  private func taskCacheURL(for listId: String) -> URL? {
    guard !listId.isEmpty else { return nil }

    let fileManager = FileManager.default
    let containerDirectory = AppIdentity.applicationSupportDirectory(fileManager: fileManager)

    do {
      try fileManager.createDirectory(at: containerDirectory, withIntermediateDirectories: true)
    } catch {
      return nil
    }

    return containerDirectory.appendingPathComponent("tasks-cache-\(listId).json")
  }
}

enum CheckvistTaskRepositoryError: LocalizedError {
  case invalidListURL
  case fetchFailed(statusCode: Int)

  var errorDescription: String? {
    switch self {
    case .invalidListURL:
      return "Invalid list URL."
    case .fetchFailed:
      return "Failed to fetch tasks."
    }
  }
}
