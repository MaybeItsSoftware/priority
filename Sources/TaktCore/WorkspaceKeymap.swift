import Foundation
import TaktRustCore

/// Something wrong with a keymap file, said in a sentence someone editing it
/// can act on.
///
/// A keymap is never all-or-nothing. An entry that cannot be understood is
/// skipped and reported, and everything else in the file still applies — one
/// typo should not throw away the rest of somebody's bindings, and it should
/// certainly not stop the app launching.
public struct WorkspaceKeymapIssue: Error, Sendable, Equatable, CustomStringConvertible {
  public enum Kind: String, Sendable, Equatable {
    /// Not JSON, or not an array of blocks. Nothing in the file applies.
    case unreadableFile
    /// A block that is not an object with a `bindings` object.
    case malformedBlock
    /// A `context` that names no surface.
    case unknownContext
    /// A command id the catalogue does not have.
    case unknownCommand
    /// A key no key press can be spelled as.
    case malformedKey
    /// A command that reads which key ran it — the digit that sets a priority,
    /// the arrow that picks a direction — so another key cannot stand in.
    case notRebindable
    /// A command that belongs to one surface, bound in the `context` of another.
    case wrongSurface
    /// One key bound to two commands on the same surface. The later wins.
    case conflict
  }

  public let kind: Kind
  public let message: String

  public init(kind: Kind, message: String) {
    self.kind = kind
    self.message = message
  }

  public var description: String { message }
}

/// A user keymap: key bindings laid over `WorkspaceCommandCatalog.defaults`.
///
/// The file is Zed's shape — an array of blocks, each with an optional
/// `context` naming a surface and a `bindings` object from key to command id.
/// `null` unbinds.
///
/// ```json
/// [
///   { "bindings": { "cmd+shift+k": "taskComplete" } },
///   { "context": "board", "bindings": { "x": null } }
/// ]
/// ```
///
/// Without a `context`, a binding applies wherever the command does: the key
/// is added to the command and taken from any other command on the same
/// surface. With one, it applies on that surface only. A `null` without a
/// context removes the key from every command; with one, the key stops
/// meaning anything on that surface unless a binding there gives it a new job.
public struct WorkspaceKeymap: Sendable, Equatable {

  public struct Binding: Sendable, Equatable {
    /// `nil` for a block with no context.
    public let context: WorkspaceCommandSurface?
    /// Normalised to the catalogue's spelling — `cmd+shift+k`.
    public let key: String
    /// `nil` unbinds.
    public let command: WorkspaceCommandID?

    public init(context: WorkspaceCommandSurface?, key: String, command: WorkspaceCommandID?) {
      self.context = context
      self.key = key
      self.command = command
    }
  }

  /// In the order they apply: file order by block, and within a block the
  /// unbindings before the bindings, so `{"x": null, "cmd+x": "…"}` means the
  /// same whichever way round it is written.
  public let bindings: [Binding]

  public init(bindings: [Binding]) {
    self.bindings = bindings
  }

  public static let empty = WorkspaceKeymap(bindings: [])

  // MARK: - Reading the file

  /// Reads a keymap file. Every rule (the blocks, contexts, key spellings,
  /// command ids, unbinds before binds) is the core's `keymap_parse`; this
  /// converts its answer. Run once per load of the file.
  public static func parse(_ data: Data) -> (keymap: WorkspaceKeymap, issues: [WorkspaceKeymapIssue]) {
    // Not UTF-8 is not empty: hand the core something it will refuse to read.
    let text = String(data: data, encoding: .utf8) ?? "\u{FFFD}"
    let parsed = keymapParse(text: text)
    let bindings = parsed.bindings.compactMap { binding -> Binding? in
      let command = binding.command.flatMap(WorkspaceCommandID.init(rawValue:))
      // The core knows every id in its catalogue; one this build's enum lacks
      // could not run, so it is dropped as the core would drop an unknown one.
      if binding.command != nil, command == nil { return nil }
      return Binding(
        context: binding.context.map(WorkspaceCommandSurface.init(core:)), key: binding.key, command: command)
    }
    return (WorkspaceKeymap(bindings: bindings), parsed.issues.map(WorkspaceKeymapIssue.init(core:)))
  }

  // MARK: - Laying it over the catalogue

  /// The bindings laid over `defaults`: the core's `keymap_resolve`, made
  /// into the Mac's lookup table. Run once per load, never per key press.
  public func resolve(
    over defaults: [WorkspaceCommand] = WorkspaceCommandCatalog.defaults
  ) -> (bindings: WorkspaceKeyBindings, issues: [WorkspaceKeymapIssue]) {
    let resolved = keymapResolve(
      bindings: bindings.map {
        KeymapBinding(context: $0.context?.core, key: $0.key, command: $0.command?.rawValue)
      },
      defaults: defaults.map(\.core))
    let commands = zip(defaults, resolved.commands).map { command, entry in
      command.rebound(
        keys: entry.keys,
        surfaceKeys: Dictionary(
          entry.surfaceKeys.map { (WorkspaceCommandSurface(core: $0.surface), $0.keys) },
          uniquingKeysWith: { first, _ in first }))
    }
    let unbound = Dictionary(
      resolved.unbound.map { (WorkspaceCommandSurface(core: $0.surface), Set($0.keys)) },
      uniquingKeysWith: { first, _ in first })
    return (
      WorkspaceKeyBindings(commands: commands, unbound: unbound),
      resolved.issues.map(WorkspaceKeymapIssue.init(core:))
    )
  }

  /// Commands that act on which key ran them, so another key cannot stand in.
  public static let readsItsKey: Set<WorkspaceCommandID> = Set(
    keymapReadsItsKey().compactMap(WorkspaceCommandID.init(rawValue:)))

  // MARK: - Spelling a key

  /// `raw` in the catalogue's spelling: modifiers in the order `cmd`, `ctrl`,
  /// `option`, `shift`, then the key. The core's `keymap_normalized_key`.
  public static func normalizedKey(_ raw: String) -> Result<String, WorkspaceKeymapIssue> {
    do {
      return .success(try keymapNormalizedKey(raw: raw))
    } catch KeymapKeyError.Malformed(let reason) {
      return .failure(.init(kind: .malformedKey, message: reason))
    } catch {
      return .failure(.init(kind: .malformedKey, message: "\"\(raw)\" is not a key"))
    }
  }

  // MARK: - Helpers

  /// The surface a keymap `context` names, ignoring case.
  public static func surface(named name: String) -> WorkspaceCommandSurface? {
    keymapSurfaceNamed(name: name).map(WorkspaceCommandSurface.init(core:))
  }
}
