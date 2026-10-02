import Foundation

/// A hybrid logical clock: wall time where the devices agree, and a counter to
/// break ties where they do not, so every edit gets a timestamp no other edit
/// on any device shares, and a device that has seen an edit always stamps its
/// next one later.
///
/// Rendered as `"<ms:013d>-<counter:04d>-<deviceId>"`. Every part is fixed
/// width, so string comparison is clock order. The server compares them as
/// strings and never parses them.
public struct HybridLogicalClock: Comparable, Sendable, CustomStringConvertible {
  public var milliseconds: Int64
  public var counter: Int
  public var deviceId: String

  public init(milliseconds: Int64, counter: Int, deviceId: String) {
    self.milliseconds = milliseconds
    self.counter = counter
    self.deviceId = deviceId
  }

  public init?(_ string: String) {
    let parts = string.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, let ms = Int64(parts[0]), let counter = Int(parts[1]) else { return nil }
    self.init(milliseconds: ms, counter: counter, deviceId: String(parts[2]))
  }

  public var description: String {
    String(format: "%013lld-%04d-", milliseconds, counter) + deviceId
  }

  /// The stamp for a local edit made at `wallMilliseconds`.
  public func tick(wallMilliseconds: Int64) -> HybridLogicalClock {
    if wallMilliseconds > milliseconds {
      return HybridLogicalClock(milliseconds: wallMilliseconds, counter: 0, deviceId: deviceId)
    }
    return HybridLogicalClock(milliseconds: milliseconds, counter: counter + 1, deviceId: deviceId)
  }

  /// This clock moved past one received from another device, so the next local
  /// edit sorts after everything this device has seen.
  public func receiving(_ remote: HybridLogicalClock, wallMilliseconds: Int64) -> HybridLogicalClock {
    let ms = max(milliseconds, remote.milliseconds, wallMilliseconds)
    let counter: Int
    if ms == milliseconds && ms == remote.milliseconds {
      counter = max(self.counter, remote.counter) + 1
    } else if ms == milliseconds {
      counter = self.counter + 1
    } else if ms == remote.milliseconds {
      counter = remote.counter + 1
    } else {
      counter = 0
    }
    return HybridLogicalClock(milliseconds: ms, counter: counter, deviceId: deviceId)
  }

  public static func < (lhs: HybridLogicalClock, rhs: HybridLogicalClock) -> Bool {
    lhs.description < rhs.description
  }
}
