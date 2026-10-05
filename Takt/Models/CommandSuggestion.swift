import Foundation

struct CommandSuggestion: Equatable, Sendable {
  let label: String
  let command: String
  let preview: String
  let keybind: String?
  let submitImmediately: Bool
}
