import Foundation

/// On-disk shape of the per-list task cache. Extracted from
/// `CheckvistTaskRepository.swift` so the type can be shared with
/// `TaktPlugins` / `TaktAppLogic` without pulling in the network
/// fetcher.
struct CheckvistTaskCachePayload: Codable, Sendable {
  let listId: String
  let fetchedAt: Date
  let tasks: [CheckvistTask]
}
