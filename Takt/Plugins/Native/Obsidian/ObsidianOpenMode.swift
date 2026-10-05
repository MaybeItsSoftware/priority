import Foundation

/// How to surface a synced Obsidian note. Extracted from
/// `ObsidianSyncService.swift` so the type can be shared with
/// `TaktPlugins` / `TaktAppLogic` without the AppKit-bound sync
/// implementation.
enum ObsidianOpenMode {
  case standard
  case newWindow
}
