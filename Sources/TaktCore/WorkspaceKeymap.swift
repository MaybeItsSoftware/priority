import Foundation

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

  /// Reads a keymap file. Never throws: what cannot be read is reported and
  /// skipped, and an unreadable file is an empty keymap plus one issue.
  public static func parse(_ data: Data) -> (keymap: WorkspaceKeymap, issues: [WorkspaceKeymapIssue]) {
    // Not UTF-8 is not empty: let the JSON reader say what is wrong with it.
    let trimmed = (String(bytes: data, encoding: .utf8) ?? "?")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return (.empty, []) }

    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      return (.empty, [.init(kind: .unreadableFile, message: "keymap.json is not valid JSON: \(Self.reason(error))")])
    }
    guard let blocks = json as? [Any] else {
      return (.empty, [
        .init(
          kind: .unreadableFile,
          message: "keymap.json should be an array of blocks, like [{\"bindings\": {…}}]")
      ])
    }

    var issues: [WorkspaceKeymapIssue] = []
    var bindings: [Binding] = []
    for (offset, element) in blocks.enumerated() {
      let label = "Block \(offset + 1)"
      guard let block = element as? [String: Any] else {
        issues.append(.init(kind: .malformedBlock, message: "\(label) is not an object; skipped"))
        continue
      }
      var context: WorkspaceCommandSurface?
      if let rawContext = block["context"], !(rawContext is NSNull) {
        guard let name = rawContext as? String, let surface = surface(named: name) else {
          issues.append(
            .init(
              kind: .unknownContext,
              message: "\(label): context \"\(rawContext)\" is not a surface — use one of \(surfaceNames); block skipped"))
          continue
        }
        context = surface == .anywhere ? nil : surface
      }
      guard let entries = block["bindings"] as? [String: Any] else {
        issues.append(.init(kind: .malformedBlock, message: "\(label) has no \"bindings\" object; skipped"))
        continue
      }

      var unbinds: [Binding] = []
      var binds: [Binding] = []
      for rawKey in entries.keys.sorted() {
        guard let key = normalizedKey(rawKey, issues: &issues, label: label) else { continue }
        let value = entries[rawKey]
        if value is NSNull {
          unbinds.append(Binding(context: context, key: key, command: nil))
        } else if let name = value as? String, let id = WorkspaceCommandID(rawValue: name) {
          binds.append(Binding(context: context, key: key, command: id))
        } else {
          issues.append(
            .init(
              kind: .unknownCommand,
              message: "\(label): \"\(rawKey)\" is bound to \(describe(value)), which is not a command id; skipped"))
        }
      }
      bindings += unbinds + binds
    }
    return (WorkspaceKeymap(bindings: bindings), issues)
  }

  // MARK: - Laying it over the catalogue

  /// The catalogue with this keymap applied, plus what could not be applied.
  public func resolve(
    over defaults: [WorkspaceCommand] = WorkspaceCommandCatalog.defaults
  ) -> (bindings: WorkspaceKeyBindings, issues: [WorkspaceKeymapIssue]) {
    var keys = defaults.map(\.keys)
    var surfaceKeys = defaults.map(\.surfaceKeys)
    var unbound: [WorkspaceCommandSurface: Set<String>] = [:]
    var issues: [WorkspaceKeymapIssue] = []
    let index = Dictionary(defaults.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
    /// Who the file itself has given a key on a surface, to name a conflict.
    var given: [String: WorkspaceCommandID] = [:]

    /// Takes `key` from every row that claims it as `scope`'s own.
    func release(_ key: String, on scope: WorkspaceCommandSurface) {
      for row in defaults.indices {
        if defaults[row].surface == scope { keys[row].removeAll { $0 == key } }
        surfaceKeys[row][scope]?.removeAll { $0 == key }
        if surfaceKeys[row][scope]?.isEmpty == true { surfaceKeys[row][scope] = nil }
      }
    }

    for binding in bindings {
      guard let id = binding.command else {
        if let context = binding.context {
          release(binding.key, on: context)
          unbound[context, default: []].insert(binding.key)
        } else {
          for row in defaults.indices {
            keys[row].removeAll { $0 == binding.key }
            for surface in surfaceKeys[row].keys {
              surfaceKeys[row][surface]?.removeAll { $0 == binding.key }
              if surfaceKeys[row][surface]?.isEmpty == true { surfaceKeys[row][surface] = nil }
            }
          }
        }
        continue
      }
      guard let row = index[id] else { continue }
      let command = defaults[row]
      let placement = binding.context.map { " on \($0.rawValue)" } ?? ""

      if Self.readsItsKey.contains(id) {
        issues.append(
          .init(
            kind: .notRebindable,
            message: "\(binding.key)\(placement): \(id.rawValue) acts on which key ran it, so it cannot be rebound; skipped"))
        continue
      }
      if let context = binding.context, command.surface != .anywhere, command.surface != context {
        issues.append(
          .init(
            kind: .wrongSurface,
            message: "\(binding.key) on \(context.rawValue): \(id.rawValue) only runs on \(command.surface.rawValue); skipped"))
        continue
      }

      let scope = binding.context ?? command.surface
      let slot = "\(scope.rawValue)/\(binding.key)"
      if let earlier = given[slot], earlier != id {
        issues.append(
          .init(
            kind: .conflict,
            message: "\(binding.key) on \(scope.rawValue) is bound to both \(earlier.rawValue) and \(id.rawValue); \(id.rawValue) wins"))
      }
      given[slot] = id

      release(binding.key, on: scope)
      if binding.context == nil || binding.context == command.surface {
        keys[row].append(binding.key)
      } else if let context = binding.context {
        surfaceKeys[row][context, default: []].append(binding.key)
      }
    }

    let commands = defaults.indices.map { row in
      defaults[row].rebound(keys: keys[row], surfaceKeys: surfaceKeys[row])
    }
    return (WorkspaceKeyBindings(commands: commands, unbound: unbound), issues)
  }

  /// Commands whose handler reads the key that ran it — which digit, which
  /// arrow — and so do nothing useful from any other key. Their keys can be
  /// unbound, but nothing can be bound to them.
  public static let readsItsKey: Set<WorkspaceCommandID> = [
    .goCycleRegion, .planMatrixPlace, .listNewTaskDestination,
    .motionSelectEnds, .motionSelectPage, .motionSidebarSelect, .motionBoardColumn,
    .motionSetPriority, .motionDoneSelect, .motionTimelineSelect,
  ]

  // MARK: - Spelling a key

  /// A key as the user wrote it, in the catalogue's spelling, or `nil` with an
  /// issue when no key press can produce it.
  ///
  /// Accepts `+` or Zed's `-` between parts, the usual aliases (`command`,
  /// `alt`, `return`, `esc`, `backspace`) and modifiers in any order.
  public static func normalizedKey(_ raw: String) -> Result<String, WorkspaceKeymapIssue> {
    var issues: [WorkspaceKeymapIssue] = []
    if let key = normalizedKey(raw, issues: &issues, label: nil) { return .success(key) }
    return .failure(issues.first ?? .init(kind: .malformedKey, message: "\"\(raw)\" is not a key"))
  }

  private static func normalizedKey(
    _ raw: String,
    issues: inout [WorkspaceKeymapIssue],
    label: String?
  ) -> String? {
    let prefix = label.map { "\($0): " } ?? ""
    func reject(_ why: String) -> String? {
      issues.append(.init(kind: .malformedKey, message: "\(prefix)\"\(raw)\" \(why); skipped"))
      return nil
    }

    let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !token.isEmpty else { return reject("is empty") }
    var parts = split(token)
    guard let rawBase = parts.popLast(), !rawBase.isEmpty else { return reject("has no key after its modifiers") }

    var modifiers: Set<String> = []
    for part in parts {
      guard let modifier = modifierAliases[part] else {
        return reject("has \"\(part)\" where a modifier should be — use cmd, ctrl, option or shift")
      }
      modifiers.insert(modifier)
    }

    let base = baseAliases[rawBase] ?? rawBase
    let isNamed = WorkspaceCommandCatalog.keyNames.contains(base)
    let isCharacter = base.count == 1
    let isSequence = WorkspaceCommandCatalog.isSequence(base)
    guard isNamed || isCharacter || isSequence else {
      return reject("is not a key Takt can recognise")
    }
    if isSequence && !modifiers.isEmpty {
      return reject("puts a modifier on a two-letter sequence, which is typed as two plain letters")
    }
    if isCharacter && !isNamed && modifiers == ["shift"] && base.first?.isLetter != true {
      return reject("holds Shift on a character, which is already in the character — write the character itself, such as \"?\"")
    }

    let ordered = ["cmd", "ctrl", "option", "shift"].filter(modifiers.contains)
    return (ordered + [base]).joined(separator: "+")
  }

  /// `cmd+k`, `cmd-k`, `cmd++`, `-`.
  private static func split(_ token: String) -> [String] {
    if token.count == 1 { return [token] }
    let separator: Character = token.contains("+") ? "+" : "-"
    var parts = token.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    // A trailing separator is the key itself: `cmd++`, `ctrl--`.
    if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
      parts.removeLast(2)
      parts.append(String(separator))
    }
    return parts
  }

  private static let modifierAliases: [String: String] = [
    "cmd": "cmd", "command": "cmd", "⌘": "cmd", "super": "cmd",
    "ctrl": "ctrl", "control": "ctrl", "⌃": "ctrl",
    "option": "option", "opt": "option", "alt": "option", "⌥": "option",
    "shift": "shift", "⇧": "shift",
  ]

  private static let baseAliases: [String: String] = [
    "return": "enter", "esc": "escape", "backspace": "delete", "del": "delete",
    "pgup": "pageup", "pgdn": "pagedown", "page_up": "pageup", "page_down": "pagedown",
    ",": "comma", " ": "space",
    "↑": "up", "↓": "down", "←": "left", "→": "right",
  ]

  // MARK: - Helpers

  public static func surface(named name: String) -> WorkspaceCommandSurface? {
    let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
    return WorkspaceCommandSurface.allCases.first { $0.rawValue.lowercased() == wanted }
  }

  private static var surfaceNames: String {
    WorkspaceCommandSurface.allCases.map(\.rawValue).joined(separator: ", ")
  }

  private static func describe(_ value: Any?) -> String {
    switch value {
    case let string as String: return "\"\(string)\""
    case let number as NSNumber: return "\(number)"
    case is [Any]: return "an array"
    case is [String: Any]: return "an object"
    default: return "nothing"
    }
  }

  private static func reason(_ error: Error) -> String {
    let nsError = error as NSError
    return (nsError.userInfo[NSDebugDescriptionErrorKey] as? String) ?? nsError.localizedDescription
  }
}
