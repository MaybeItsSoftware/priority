import Foundation

/// The catalogue as it is actually bound: every command with the keys in
/// force, indexed for the key router.
///
/// `WorkspaceCommandCatalog.defaults` is what ships. A user keymap
/// (`WorkspaceKeymap`) is laid over it to make one of these, and the catalogue
/// installs it, so the router, the palette, the reference and the menus all
/// read the same answer — rebinding a key moves its key cap as well as its
/// behaviour.
public struct WorkspaceKeyBindings: Sendable {
  /// In catalogue order, with the keys in force.
  public let commands: [WorkspaceCommand]
  public let byID: [WorkspaceCommandID: WorkspaceCommand]
  /// Keys taken away from a surface with `null` in a keymap block that names
  /// it. A surface's own rows still answer; what these stop is the key being
  /// inherited from `.anywhere`.
  public let unbound: [WorkspaceCommandSurface: Set<String>]

  /// Rows that answer to a key *as* a surface's own: the surface's rows, and
  /// any row that lists the key under `surfaceKeys` for it.
  private let ownByKey: [WorkspaceCommandSurface: [String: WorkspaceCommand]]
  /// Every key anything claims, anywhere — for `swallowsUnhandledKey`.
  private let claimedKeys: Set<String>

  public init(
    commands: [WorkspaceCommand],
    unbound: [WorkspaceCommandSurface: Set<String>] = [:]
  ) {
    self.commands = commands
    self.byID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.unbound = unbound
    var own: [WorkspaceCommandSurface: [String: WorkspaceCommand]] = [:]
    var claimed: Set<String> = []
    // First claimant wins, in catalogue order, which is what the router did
    // when it walked the list.
    for command in commands {
      for key in command.keys {
        claimed.insert(key)
        if own[command.surface]?[key] == nil { own[command.surface, default: [:]][key] = command }
      }
      for (surface, keys) in command.surfaceKeys {
        for key in keys {
          claimed.insert(key)
          if own[surface]?[key] == nil { own[surface, default: [:]][key] = command }
        }
      }
    }
    self.ownByKey = own
    self.claimedKeys = claimed
  }

  /// The command a key means on a surface, or `nil` when it means nothing
  /// there. See `WorkspaceCommandCatalog.command(forKey:on:)` for the rules.
  public func command(forKey key: String, on surface: WorkspaceCommandSurface) -> WorkspaceCommand? {
    if let own = ownByKey[surface]?[key] { return own }
    guard surface != .anywhere, unbound[surface]?.contains(key) != true,
      let fallback = ownByKey[.anywhere]?[key],
      WorkspaceCommandCatalog.inherits(fallback, key: key, on: surface)
    else { return nil }
    return fallback
  }

  public func swallowsUnhandledKey(_ key: String, on surface: WorkspaceCommandSurface) -> Bool {
    guard surface.ownsKeyboard else { return false }
    return !WorkspaceCommandCatalog.isChord(key) || claimedKeys.contains(key)
  }

  public func reachesIntoTextField(_ key: String, on surface: WorkspaceCommandSurface) -> Bool {
    guard WorkspaceCommandCatalog.isChord(key), let command = command(forKey: key, on: surface) else {
      return false
    }
    return WorkspaceCommandCatalog.reachableFromTextField.contains(command.id)
  }

  /// The two-letter sequences live on a surface, so a letter is held exactly
  /// where some key in force begins a sequence with it.
  public func sequences(on surface: WorkspaceCommandSurface) -> Set<String> {
    Set(
      claimedKeys.filter { key in
        WorkspaceCommandCatalog.isSequence(key) && command(forKey: key, on: surface) != nil
      })
  }
}

extension WorkspaceCommandCatalog {
  /// The shipped bindings, with no keymap over them.
  public static let defaultBindings = WorkspaceKeyBindings(commands: defaults)

  private final class Installed: @unchecked Sendable {
    private let lock = NSLock()
    private var value = WorkspaceCommandCatalog.defaultBindings
    func get() -> WorkspaceKeyBindings { lock.withLock { value } }
    func set(_ bindings: WorkspaceKeyBindings) { lock.withLock { value = bindings } }
  }

  private static let installed = Installed()

  /// The bindings in force. Everything that reads the catalogue reads these.
  public static var bindings: WorkspaceKeyBindings { installed.get() }

  /// Puts a resolved keymap in force — or the defaults back, given
  /// `defaultBindings`.
  public static func install(_ bindings: WorkspaceKeyBindings) { installed.set(bindings) }

  /// Every command with the keys in force, in catalogue order.
  public static var all: [WorkspaceCommand] { bindings.commands }
}
