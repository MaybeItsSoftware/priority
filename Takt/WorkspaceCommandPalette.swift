import TaktCore
import SwiftUI

/// The shortcuts for one command, with the alternatives separated rather than
/// run together — `E E` and `F2` are two ways to rename, not one four-key
/// incantation, and the old help sheet's `EE / F2` made that a guess.
struct KeyCapRow: View {
  @Environment(\.theme) private var theme
  let keys: [String]

  var body: some View {
    HStack(spacing: theme.space.xs) {
      if keys.isEmpty {
        // Blank would read as "we forgot to print it". One command really has
        // no key of its own, and saying so is the honest answer.
        Text("no key").font(theme.monoCaptionFont).foregroundStyle(theme.dim)
      }
      ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
        if index > 0 {
          Text("or").font(theme.monoCaptionFont).foregroundStyle(theme.dim)
        }
        KeyCap(key)
      }
    }
  }
}

/// Everything the workspace can do, and every key that does it.
///
/// It is one surface rather than two because the two questions turn out to be
/// the same question. "What can I do here" and "what does this key do" were
/// answered by a palette and a reference sheet in most apps, and by a
/// reference sheet alone in this one; a list that runs the row you land on
/// answers both, and can only ever print shortcuts that work, because the row
/// and the key come from the same catalogue entry.
struct WorkspaceCommandPalette: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String

  @State private var query = ""
  @State private var selection: WorkspaceCommandID?

  private var matches: [WorkspaceCommandQuery.Match] {
    model.commandMatches(for: query)
  }

  /// Only actions can be landed on. Arrowing through the list skips the
  /// motions rather than stopping on rows that Return would do nothing to.
  private var runnable: [WorkspaceCommandID] {
    matches.filter { $0.command.kind == .action }.map(\.id)
  }

  var body: some View {
    let matches = matches
    VStack(alignment: .leading, spacing: 0) {
      WorkspaceOverlayField(
        symbol: "command", prompt: "Run a command, or find a key", text: $query,
        context: model.commandSurface.title)
      FocusRule()
      if matches.isEmpty {
        WorkspaceOverlayHint(text: "Nothing matches “\(query)”.")
          .frame(height: WorkspaceOverlayMetrics.listHeight)
      } else {
        list(matches)
      }
      WorkspaceOverlayFooter(
        hints: "↑↓ choose · ↩ run · esc close",
        trailing: "\(matches.count) of \(WorkspaceCommandCatalog.all.count)")
    }
    .onAppear { selection = runnable.first }
    .onChange(of: query) { _, _ in selection = runnable.first }
    .overlayKeys(model, id: overlayID) { key in
      if let step = WorkspaceOverlayStep.offset(for: key) {
        move(by: step)
        return true
      }
      guard key == "enter" else { return false }
      runSelection()
      return true
    }
  }

  private func list(_ matches: [WorkspaceCommandQuery.Match]) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(matches) { match in
            row(match)
              .id(match.id)
              .onTapGesture { run(match.command) }
          }
        }
      }
      .frame(height: WorkspaceOverlayMetrics.listHeight)
      .onChange(of: selection) { _, id in
        guard let id else { return }
        proxy.scrollTo(id, anchor: .center)
      }
    }
  }

  private func row(_ match: WorkspaceCommandQuery.Match) -> some View {
    let command = match.command
    let isSelected = selection == command.id
    let isMotion = command.kind == .motion
    return HStack(alignment: .firstTextBaseline, spacing: theme.space.md) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text(command.title)
          .font(theme.bodyFont())
          // A motion is still readable, just visibly not a thing you can pick.
          .foregroundStyle(isMotion ? theme.muted : theme.ink)
        if let note = command.note {
          Text(note)
            .font(theme.captionFont)
            .foregroundStyle(theme.dim)
        }
      }
      Spacer(minLength: theme.space.md)
      if command.surface != .anywhere, command.surface != model.commandSurface {
        MicroLabel(command.surface.title)
      }
      KeyCapRow(keys: command.displayKeys)
    }
    .overlayRow(isSelected: isSelected)
  }

  private func move(by offset: Int) {
    let ids = runnable
    guard !ids.isEmpty else { return }
    guard let current = selection, let index = ids.firstIndex(of: current) else {
      selection = ids.first
      return
    }
    selection = ids[min(max(index + offset, 0), ids.count - 1)]
  }

  private func runSelection() {
    guard let id = selection, let command = WorkspaceCommandCatalog.byID[id] else { return }
    run(command)
  }

  private func run(_ command: WorkspaceCommand) {
    guard command.kind == .action else { return }
    // Closed first, handing the keyboard back to the region it came from:
    // several of these put the caret somewhere else — a composer, a rename
    // field, the sidebar — or open an overlay of their own, and this one
    // still being up would toggle that shut. Those that move the caret move
    // it after this, so they win.
    model.dismissOverlay()
    model.run(command.id)
  }
}
