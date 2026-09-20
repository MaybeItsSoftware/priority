import Foundation

/// Checkvist-style commands only retain a prefix briefly, within one surface.
public struct DesktopShortcutSequence {
  public enum Result: Equatable { case pass, pending, command(String) }
  public private(set) var prefix = ""
  private var lastKeyAt: TimeInterval = 0
  public static let commands: Set<String> = [
    "ee", "dd", "nn", "tt", "mm", "ll", "uu", "td", "tm", "cd", "cn", "ct",
    "dr", "hc", "gh", "sd", "oo", "pc", "xx", "gg"
  ]

  public init() {}
  public mutating func reset() { prefix = "" }

  public mutating func advance(_ key: String, at time: TimeInterval) -> Result {
    if time - lastKeyAt > 1.2 { reset() }
    lastKeyAt = time
    let candidate = prefix + key.lowercased()
    reset()
    if Self.commands.contains(candidate) { return .command(candidate) }
    let character = key.lowercased()
    if Self.commands.contains(where: { $0.hasPrefix(character) }) && character.count == 1 {
      prefix = character
      return .pending
    }
    return .pass
  }
}
