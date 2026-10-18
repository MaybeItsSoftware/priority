import Foundation
import TaktRustCore

/// The phones' Find sheet: the commands it offers and how it orders what
/// matches. All of it is the Rust core's (`core/src/palette.rs`), shared with
/// Android, so a query lands on the same row on both phones.
public enum PhonePalette {

  /// One command Find offers: its id (a catalogue id, or one of the phones'
  /// own, `phone…`), its title and its group.
  public struct Command: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let group: String

    public init(id: String, title: String, group: String) {
      self.id = id
      self.title = title
      self.group = group
    }
  }

  /// A row to rank that is not a command: a list, by its name and where it lives.
  public struct Candidate: Hashable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
      self.title = title
      self.detail = detail
    }
  }

  /// Every command, in the order Find lists them with nothing typed.
  public static let commands: [Command] = coreCommands.map {
    Command(id: $0.id, title: $0.title, group: $0.group)
  }

  private static let coreCommands = phonePaletteCommands()

  /// The commands matching `query`, best first, with `recents` (newest
  /// first) lifted. Nothing typed: every command, recent ones first.
  public static func rankCommands(_ query: String, recents: [String]) -> [Command] {
    let byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
    return paletteRankCommands(query: query, commands: coreCommands, recents: recents).compactMap { byID[$0] }
  }

  /// The indices of `candidates` that match `query`, best first.
  public static func rank(_ query: String, _ candidates: [Candidate]) -> [Int] {
    paletteRank(
      query: query,
      candidates: candidates.map { PaletteCandidate(title: $0.title, detail: $0.detail, keys: [], boost: 0) }
    ).map { Int($0) }
  }

  /// `recents` with `id` moved to the front and capped: what to store after
  /// running a command.
  public static func recording(_ id: String, recents: [String]) -> [String] {
    paletteRecording(id: id, recents: recents)
  }
}
