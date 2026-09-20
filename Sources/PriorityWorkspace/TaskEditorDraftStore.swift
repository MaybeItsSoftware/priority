import Foundation

/// Drafts are local editing state, never task mutations or undo entries.
public struct TaskEditorDraftStore {
  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  private struct Payload: Codable {
    var version = 2
    let drafts: [TaskEditorDraft]
  }

  public func load() throws -> [TaskEditorDraft] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
    guard (1...2).contains(payload.version) else {
      throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "Unsupported task draft format."])
    }
    return payload.drafts
  }

  public func save(_ drafts: [TaskEditorDraft]) throws {
    let pending = drafts.filter(\.isDirty).sorted {
      ($0.baseline.workspaceId, $0.baseline.taskId) < ($1.baseline.workspaceId, $1.baseline.taskId)
    }
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(Payload(drafts: pending)).write(to: fileURL, options: .atomic)
  }
}
