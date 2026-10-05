import AppKit
import Foundation
import OSLog
import Observation
import TaktCore

@MainActor
@Observable class TimerManager {
  @ObservationIgnored private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "timer")
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let cacheInvalidationBus: CacheInvalidationBus
  @ObservationIgnored private var sleepObserver: NSObjectProtocol?
  
  var timedTaskId: Int?
  var timerByTaskId: [Int: TimeInterval] = [:] {
    didSet {
      let encoded = Dictionary(uniqueKeysWithValues: timerByTaskId.map { (String($0.key), $0.value) })
      preferencesStore.set(encoded, for: .timerByTaskId)
      cacheInvalidationBus.invalidate()
    }
  }
  var timerRunning: Bool = false
  @ObservationIgnored var timerTask: Task<Void, Never>?

  /// Called on the main actor after every per-second increment with
  /// `(taskId, newElapsed)`. Used by `FocusSessionManager` to detect when
  /// the focus block has ended.
  @ObservationIgnored var onTick: ((Int, TimeInterval) -> Void)?

  init(
    preferencesStore: PreferencesStore,
    cacheInvalidationBus: CacheInvalidationBus = CacheInvalidationBus()
  ) {
    self.preferencesStore = preferencesStore
    self.cacheInvalidationBus = cacheInvalidationBus
    self.timerByTaskId = Self.timerDictionaryFromDefaults(preferencesStore: preferencesStore)
    
    self.sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.pauseTimer()
      }
    }
  }

  deinit {
    if let observer = sleepObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  // MARK: - Timer Operations

  func toggleTimer(forTaskId taskId: Int) {
    if timedTaskId == taskId {
      if timerRunning {
        pauseTimer()
      } else {
        resumeTimer()
      }
    } else {
      pauseTimer()
      timedTaskId = taskId
      if timerByTaskId[taskId] == nil {
        timerByTaskId[taskId] = 0
      }
      resumeTimer()
    }
  }

  func pauseTimer() {
    timerRunning = false
    timerTask?.cancel()
    timerTask = nil
  }

  func resumeTimer() {
    guard let activeTaskId = timedTaskId, !timerRunning else { return }
    timerRunning = true
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { break }
        await MainActor.run {
          guard let self else { return }
          self.timerByTaskId[activeTaskId, default: 0] += 1
          self.onTick?(activeTaskId, self.timerByTaskId[activeTaskId, default: 0])
        }
      }
    }
  }

  func stopTimer() {
    pauseTimer()
    timedTaskId = nil
  }

  /// Stop the timer if the currently-timed task is no longer in the given set of open task IDs.
  func stopTimerIfTaskRemoved(openTaskIds: Set<Int>) {
    if let activeTimerTaskId = timedTaskId, !openTaskIds.contains(activeTimerTaskId) {
      stopTimer()
    }
  }

  // MARK: - Display

  static func formattedTimer(_ elapsed: TimeInterval) -> String {
    TimerStore.formatted(elapsed)
  }

  // MARK: - Persistence Helpers

  static func timerDictionaryFromDefaults(
    preferencesStore: PreferencesStore
  ) -> [Int: TimeInterval] {
    let raw = preferencesStore.timerDictionary()
    guard !raw.isEmpty else { return [:] }
    var result: [Int: TimeInterval] = [:]
    for (key, value) in raw {
      if let id = Int(key) { result[id] = value }
    }
    return result
  }
}
