import Foundation

/// A cross-process advisory lock, via `flock(2)`.
///
/// Priority's daily-log files are written by two processes: the app, and the
/// `--mcp-server` instance an AI client launches. Without a lock, the pattern
/// both need — read the file, change it, write it back — has an interleaving
/// where one process's write lands between the other's read and write, and the
/// second write silently erases the first. For `dailies.json` that means a
/// daily disappearing with no error, which is the failure this exists to stop.
///
/// The lock is taken on a sibling `.lock` file rather than the data file
/// itself, and that detail is load-bearing: `DailyDefinitionsStore` saves
/// atomically (write a temporary, then rename over the target), so the data
/// file's inode is *replaced* on every save. A lock held on the old inode
/// guards nothing — the next process opens the new one and sees a free lock.
/// The sibling file is never rewritten, so its inode is stable.
///
/// `flock` is advisory: it only excludes processes that also ask for the lock.
/// That is sufficient here because both writers go through this type, and it is
/// the right trade for a file a user may reasonably edit by hand.
public struct FileLock {
  public enum LockError: LocalizedError {
    case cannotOpen(path: String, code: Int32)
    case cannotLock(path: String, code: Int32)

    public var errorDescription: String? {
      switch self {
      case .cannotOpen(let path, let code):
        return "Could not open the lock file at \(path) (errno \(code))."
      case .cannotLock(let path, let code):
        return "Could not lock \(path) (errno \(code))."
      }
    }
  }

  public let lockFileURL: URL

  public init(protecting fileURL: URL) {
    self.lockFileURL = fileURL.appendingPathExtension("lock")
  }

  /// Runs `body` with the lock held, releasing it however `body` exits.
  ///
  /// Blocks until the lock is available. There is no timeout because the
  /// critical section is a small read/modify/write on a file measured in
  /// kilobytes — a contended wait is microseconds, and a caller that timed out
  /// would have nothing better to do than retry.
  public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: lockFileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else {
      throw LockError.cannotOpen(path: lockFileURL.path, code: errno)
    }
    // Declared before the unlock `defer` so it runs *after* it: defers unwind
    // last-declared-first, and releasing a lock on a closed descriptor is a
    // silent no-op that would leave the next process blocked.
    defer { close(descriptor) }

    guard flock(descriptor, LOCK_EX) == 0 else {
      throw LockError.cannotLock(path: lockFileURL.path, code: errno)
    }
    defer { flock(descriptor, LOCK_UN) }

    return try body()
  }
}
