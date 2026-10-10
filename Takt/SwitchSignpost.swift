import Foundation
import TaktCore
import os

/// Signposts for switching what the window shows — a list, a scope, a view
/// mode, the palette, the inspector — under the app's subsystem, category
/// `Switching`. In Instruments' os_signpost track, each switch is two
/// intervals: the switch itself, which is the time the main thread was
/// blocked by it and after which the new content is ready, and the same
/// switch up to the next turn of the main queue, which takes in SwiftUI's
/// update of what it changed. See `docs/performance.md`.
@MainActor
enum SwitchSignpost {
  static let signposter = OSSignposter(subsystem: AppIdentity.bundleIdentifier, category: "Switching")

  static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(name, id: id)
    let drawn = signposter.beginInterval("Switch to next turn", id: id)
    defer {
      signposter.endInterval(name, state)
      DispatchQueue.main.async { signposter.endInterval("Switch to next turn", drawn) }
    }
    return try body()
  }

  static func event(_ name: StaticString) {
    signposter.emitEvent(name)
  }
}
