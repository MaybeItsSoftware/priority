import Foundation
import PriorityWorkspace

/// Decides when to sync, so the Mac and iOS apps run the same rhythm: on
/// demand, a couple of seconds after the last local write, and in a long-poll
/// loop while the app is in front, so another device's edit appears within a
/// second or two without polling a quiet server.
public actor SyncScheduler {
  public typealias Listener = @Sendable (SyncEngine.Status, SyncEngine.Outcome?) async -> Void

  let engine: SyncEngine
  let listener: Listener
  let debounce: Duration
  private var loop: Task<Void, Never>?
  private var pending: Task<Void, Never>?
  private var failures = 0
  /// Set when the server refuses the token. Nothing runs after that: every
  /// cycle would get the same 401, so the scheduler waits to be replaced by
  /// one with a fresh sign-in.
  public private(set) var isSignedOut = false

  public init(engine: SyncEngine, debounce: Duration = .seconds(2), listener: @escaping Listener) {
    self.engine = engine
    self.debounce = debounce
    self.listener = listener
  }

  /// Syncs now and keeps a long-poll open until `stop()`. Call when the app
  /// comes to the front.
  public func start() {
    guard loop == nil, !isSignedOut else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, await !self.isSignedOut else { return }
        let delay = await self.runOnce(wait: 25)
        if let delay { try? await Task.sleep(for: delay) }
      }
    }
  }

  /// Stops the long-poll. Call when the app goes to the background.
  public func stop() {
    loop?.cancel()
    loop = nil
  }

  /// A local write happened: sync once things go quiet.
  public func noteLocalChange() {
    pending?.cancel()
    pending = Task { [weak self, debounce] in
      try? await Task.sleep(for: debounce)
      guard !Task.isCancelled, let self else { return }
      await self.flush()
    }
  }

  /// Pushes promptly. While a long-poll is open the cycle holding it would
  /// not push until the poll returned, so it is restarted instead: the new
  /// cycle pushes first, then goes back to waiting.
  private func flush() async {
    if loop != nil {
      stop()
      start()
    } else {
      _ = await runOnce(wait: 0)
    }
  }

  /// One cycle, for a background refresh or a "Sync now" button.
  @discardableResult
  public func syncNow() async -> Bool {
    guard !isSignedOut else { return false }
    return await runOnce(wait: 0) == nil && !isSignedOut
  }

  /// Runs a cycle and reports it. Returns how long to back off before the next
  /// long-poll, or nil to go straight back.
  private func runOnce(wait: Int) async -> Duration? {
    if isSignedOut { return nil }
    await listener(.syncing, nil)
    do {
      let outcome = try await engine.sync(wait: wait)
      failures = 0
      await listener(await engine.status, outcome)
      return nil
    } catch where Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
      // A long-poll restarted to push a local edit, not a failure.
      return nil
    } catch SyncError.unauthorized {
      isSignedOut = true
      stop()
      pending?.cancel()
      await listener(.signedOut, nil)
      return nil
    } catch {
      failures += 1
      await listener(.failed(error.localizedDescription), nil)
      // 2, 4, 8 … seconds, capped at five minutes, so an outage costs nothing.
      return .seconds(min(300, 1 << min(failures, 8)))
    }
  }
}
