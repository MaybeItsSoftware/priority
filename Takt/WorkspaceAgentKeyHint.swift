import SwiftUI
import TaktCore

/// "Keys `D D` then type “friday”": how to make a change card's change from
/// the keyboard, under the card, in the muted ink. The parts are the core's
/// (`AgentKeyHintLine`, worked out from the tool call and the keymap in
/// force), each key drawn as the palette draws it.
struct WorkspaceAgentKeyHint: View {
  @Environment(\.theme) private var theme
  let hint: AgentKeyHintLine

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.xs) {
      Text("Keys")
        .font(theme.captionFont)
        .foregroundStyle(theme.dim)
      ForEach(Array(hint.parts.enumerated()), id: \.offset) { _, part in
        switch part {
        case .key(let key):
          KeyCap(ShortcutReference.displayKeys(forBinding: key).joined(separator: " "))
        case .text(let text):
          Text(text)
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
    }
    .help("You could have pressed \(hint.plainText)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Keys: \(hint.plainText)")
  }
}
