import Foundation

// What the iPhone and the Apple Watch say to each other over
// WatchConnectivity. Compiled into the iPhone app, the watch app and the
// watch's complications, so the two ends cannot drift apart.
//
// The iPhone is the source of truth: it holds the workspace, ranks the day
// and runs the clock. The watch holds only the last snapshot it was sent and
// asks for things to happen. The Wear OS companion is held to the same
// shapes, so the two watches agree on what a row, a block and an action are.

/// The day and the running block, as the watch draws them. Sent by the iPhone
/// with `updateApplicationContext` whenever either changes.
struct WatchSnapshot: Codable, Equatable, Sendable {
  /// One row of Today, in the order the iPhone's Today shows it.
  struct Task: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// The small line under the title: why it is in the day ("Overdue",
    /// "Due today") or, when nothing more pressing applies, its list.
    let detail: String?
    /// A daily: tapping logs today's contribution rather than completing it.
    let isDaily: Bool
    let dailyDone: Bool
    /// The task the running (or paused) block is on.
    let isRunning: Bool
    let estimateSeconds: Int?

    init(
      id: String, title: String, detail: String? = nil, isDaily: Bool = false, dailyDone: Bool = false,
      isRunning: Bool = false, estimateSeconds: Int? = nil
    ) {
      self.id = id
      self.title = title
      self.detail = detail
      self.isDaily = isDaily
      self.dailyDone = dailyDone
      self.isRunning = isRunning
      self.estimateSeconds = estimateSeconds
    }
  }

  /// The block in hand. Its clock is carried as the session's own two
  /// numbers, so the watch draws the time itself and nothing is sent each
  /// second: `elapsed = accumulatedSeconds + (running ? now - startedAt : 0)`.
  struct Session: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
      case running
      case paused
    }

    let taskId: String
    let title: String
    var phase: Phase
    /// When the clock last started counting: the block's start, or its last
    /// resume.
    var startedAt: Date
    /// Seconds counted before `startedAt` — everything up to the last pause.
    var accumulatedSeconds: Int
    /// How long the block was meant to run, when that is known.
    let plannedSeconds: Int?

    init(
      taskId: String, title: String, phase: Phase, startedAt: Date, accumulatedSeconds: Int, plannedSeconds: Int?
    ) {
      self.taskId = taskId
      self.title = title
      self.phase = phase
      self.startedAt = startedAt
      self.accumulatedSeconds = accumulatedSeconds
      self.plannedSeconds = plannedSeconds
    }

    var isPaused: Bool { phase == .paused }

    func elapsedSeconds(at now: Date) -> Int {
      max(0, accumulatedSeconds) + (phase == .running ? Int(max(0, now.timeIntervalSince(startedAt))) : 0)
    }

    /// When the clock would have started had it never paused: what a
    /// `Text(timerInterval:)` counts from.
    var timerStart: Date { startedAt.addingTimeInterval(-TimeInterval(max(0, accumulatedSeconds))) }

    /// When the planned block runs out, while it is running.
    var plannedEnd: Date? {
      guard phase == .running, let plannedSeconds else { return nil }
      return timerStart.addingTimeInterval(TimeInterval(plannedSeconds))
    }

    /// The same block, paused at `now`.
    func paused(at now: Date) -> Session {
      guard phase == .running else { return self }
      var copy = self
      copy.accumulatedSeconds = elapsedSeconds(at: now)
      copy.startedAt = now
      copy.phase = .paused
      return copy
    }

    /// The same block, running again from `now`.
    func resumed(at now: Date) -> Session {
      guard phase == .paused else { return self }
      var copy = self
      copy.startedAt = now
      copy.phase = .running
      return copy
    }
  }

  var tasks: [Task]
  var session: Session?
  var generatedAt: Date

  init(tasks: [Task], session: Session?, generatedAt: Date) {
    self.tasks = tasks
    self.session = session
    self.generatedAt = generatedAt
  }

  static let empty = WatchSnapshot(tasks: [], session: nil, generatedAt: .distantPast)

  /// What is still to do: open tasks and dailies not yet logged today.
  var openTasks: [Task] { tasks.filter { !($0.isDaily && $0.dailyDone) } }

  /// The first thing to do that is not already running.
  var nextUp: Task? { openTasks.first { !$0.isRunning } }

  /// Equal apart from when it was made: what decides whether to send it again.
  func hasSameContent(as other: WatchSnapshot) -> Bool {
    var copy = other
    copy.generatedAt = generatedAt
    return copy == self
  }

  // MARK: Wire

  /// The application-context key the encoded snapshot travels under.
  static let contextKey = "snapshot"

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }

  func encoded() throws -> Data { try Self.encoder().encode(self) }

  static func decode(_ data: Data) throws -> WatchSnapshot { try decoder().decode(WatchSnapshot.self, from: data) }

  /// As an application context or a message reply.
  func context() throws -> [String: Any] { [Self.contextKey: try encoded()] }

  init?(context: [String: Any]) {
    guard let data = context[Self.contextKey] as? Data, let snapshot = try? Self.decode(data) else { return nil }
    self = snapshot
  }
}

/// Something the watch asks the iPhone to do. Sent with `sendMessage` when
/// the phone is reachable, otherwise queued with `transferUserInfo` and
/// applied when it arrives.
struct WatchAction: Equatable, Sendable {
  enum Kind: String, CaseIterable, Sendable {
    /// Complete a task — the running one included, which also ends its block.
    case complete
    /// Log today's contribution to a daily.
    case logDaily
    /// Start a focus block on a task.
    case start
    case pause
    case resume
    /// End the session: the block's time is logged and the task stays open.
    case stop
    /// Complete the running task and end its block.
    case done
    /// Nothing to change: send the latest snapshot back. The watch asks on
    /// launch, in case the phone's last context is older than its own.
    case refresh
  }

  let kind: Kind
  let taskId: String?
  /// Distinguishes one tap from another, so a message that was delivered
  /// and then queued again is applied once.
  let id: String
  /// When it was tapped, which is the day a queued daily is logged against.
  let issuedAt: Date

  init(kind: Kind, taskId: String? = nil, id: String = UUID().uuidString, issuedAt: Date = .now) {
    self.kind = kind
    self.taskId = taskId
    self.id = id
    self.issuedAt = issuedAt
  }

  /// How long a queued timer action stays worth applying. A pause tapped an
  /// hour ago, landing now, would stop a block the user has since got on
  /// with; ticking a task off stays true however late it arrives.
  static let timerActionLifetime: TimeInterval = 10 * 60

  /// Whether the action still makes sense at `now`.
  func isCurrent(at now: Date) -> Bool {
    switch kind {
    case .complete, .logDaily, .refresh: true
    case .start, .pause, .resume, .stop, .done: now.timeIntervalSince(issuedAt) <= Self.timerActionLifetime
    }
  }

  // MARK: Wire

  /// Plain property-list values, as WatchConnectivity carries them.
  var message: [String: Any] {
    var message: [String: Any] = ["action": kind.rawValue, "id": id, "issuedAt": issuedAt.timeIntervalSince1970]
    if let taskId { message["taskId"] = taskId }
    return message
  }

  init?(message: [String: Any]) {
    guard let raw = message["action"] as? String, let kind = Kind(rawValue: raw) else { return nil }
    let taskId = message["taskId"] as? String
    switch kind {
    case .complete, .logDaily, .start: guard taskId != nil else { return nil }
    case .pause, .resume, .stop, .done, .refresh: break
    }
    let issuedAt = (message["issuedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
    self.init(kind: kind, taskId: taskId, id: message["id"] as? String ?? UUID().uuidString, issuedAt: issuedAt)
  }
}
