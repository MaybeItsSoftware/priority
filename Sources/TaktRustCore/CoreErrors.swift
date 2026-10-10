import Foundation

// Hand-written, beside the generated TaktRustCore.swift, which
// scripts/build_core_apple.sh overwrites. UniFFI generates the core's error
// enum without `public`, so code outside this module cannot match on its
// cases; this is the public face of the ones a caller has to tell apart.

/// What a call into the Rust core failed with, for a caller that must react
/// to a particular failure rather than only report it.
public enum CoreFailure: Equatable, Sendable {
  case missingTask(id: String)
  case missingDaily(id: String)
  case missingList(id: String)
  case missingFolder(id: String)
  case systemListIsPermanent
  case emptyName
  case invalidFolderMove
  case invalidCondition
  case invalidSchedule
  case invalidMinimum
  case estimateRequired
  case invalidDate
  case editorConflict
  case invalidVisibleRoot
  case noActiveFocusTask
  case duplicateSourceId
  case unavailable
  case invalidTaskMove
  case noJournal
  /// Anything a caller only reports; its message is the error's own.
  case other
}

extension Error {
  /// This error as one of the core's failures, or nil if it did not come
  /// from the core.
  public var coreFailure: CoreFailure? {
    guard let error = self as? CoreError else { return nil }
    switch error {
    case .MissingTask(let id): return .missingTask(id: id)
    case .MissingDaily(let id): return .missingDaily(id: id)
    case .MissingList(let id): return .missingList(id: id)
    case .MissingFolder(let id): return .missingFolder(id: id)
    case .SystemListIsPermanent: return .systemListIsPermanent
    case .EmptyName: return .emptyName
    case .InvalidFolderMove: return .invalidFolderMove
    case .InvalidCondition: return .invalidCondition
    case .InvalidSchedule: return .invalidSchedule
    case .InvalidMinimum: return .invalidMinimum
    case .EstimateRequired: return .estimateRequired
    case .InvalidDate: return .invalidDate
    case .EditorConflict: return .editorConflict
    case .InvalidVisibleRoot: return .invalidVisibleRoot
    case .NoActiveFocusTask: return .noActiveFocusTask
    case .DuplicateSourceId: return .duplicateSourceId
    case .Unavailable: return .unavailable
    case .InvalidTaskMove: return .invalidTaskMove
    case .NoJournal: return .noJournal
    default: return .other
    }
  }
}

/// Why the core left a config file alone (`client_config.rs`), as a caller
/// outside this module can match on it.
public enum ClientConfigFailure: Equatable, Sendable {
  case missingCredentials
  case unreadableConfig(path: String)
  case serversKeyNotAnObject(key: String)
  case readFailed(path: String, detail: String)
  case writeFailed(path: String, detail: String)
}

extension Error {
  /// This error as one of the core's config-file failures, or nil if it is
  /// not one.
  public var clientConfigFailure: ClientConfigFailure? {
    guard let error = self as? ClientConfigError else { return nil }
    switch error {
    case .MissingCredentials: return .missingCredentials
    case .UnreadableConfig(let path): return .unreadableConfig(path: path)
    case .ServersKeyNotAnObject(let key): return .serversKeyNotAnObject(key: key)
    case .ReadFailed(let path, let detail): return .readFailed(path: path, detail: detail)
    case .WriteFailed(let path, let detail): return .writeFailed(path: path, detail: detail)
    }
  }
}
