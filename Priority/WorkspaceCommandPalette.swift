import PriorityCore
import SwiftUI

/// The shortcuts for one command, with the alternatives separated rather than
/// run together — `E E` and `F2` are two ways to rename, not one four-key
/// incantation, and the old help sheet's `EE / F2` made that a guess.
struct KeyCapRow: View {
  let keys: [String]

  var body: some View {
    HStack(spacing: 4) {
      if keys.isEmpty {
        // Blank would read as "we forgot to print it". One command really has
        // no key of its own, and saying so is the honest answer.
        Text("no key").font(.system(size: 9)).foregroundStyle(.quaternary)
      }
      ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
        if index > 0 {
          Text("or").font(.system(size: 9)).foregroundStyle(.quaternary)
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
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFieldFocused: Bool

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
    VStack(alignment: .leading, spacing: 0) {
      field
      Divider()
      if matches.isEmpty { empty } else { list }
      Divider()
      footer
    }
    .frame(width: 620, height: 480)
    .onAppear {
      isFieldFocused = true
      selection = runnable.first
    }
    .onChange(of: query) { _, _ in selection = runnable.first }
    .onExitCommand { dismiss() }
  }

  private var field: some View {
    HStack(spacing: 8) {
      Image(systemName: "command").foregroundStyle(.secondary)
      TextField("Run a command, or find a key", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($isFieldFocused)
        .onSubmit { runSelection() }
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
      Text(model.commandSurface.title)
        .font(.system(size: 10, weight: .bold))
        .textCase(.uppercase)
        .kerning(1.2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  private var empty: some View {
    Text("Nothing matches “\(query)”.")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(matches) { match in
            row(match)
              .id(match.id)
              .contentShape(Rectangle())
              .onTapGesture { run(match.command) }
          }
        }
        .padding(.vertical, 4)
      }
      .onChange(of: selection) { _, id in
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
      }
    }
  }

  private func row(_ match: WorkspaceCommandQuery.Match) -> some View {
    let command = match.command
    let isSelected = selection == command.id
    let isMotion = command.kind == .motion
    return HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(command.title)
          .font(.body)
          // A motion is still readable, just visibly not a thing you can pick.
          .foregroundStyle(isMotion ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        if let note = command.note {
          Text(note).font(.caption).foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: 12)
      if command.surface != .anywhere, command.surface != model.commandSurface {
        Text(command.surface.title)
          .font(.system(size: 9, weight: .bold))
          .textCase(.uppercase)
          .kerning(1.1)
          .foregroundStyle(.quaternary)
      }
      KeyCapRow(keys: command.displayKeys)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.accentColor.opacity(isSelected ? 0.16 : 0))
        .padding(.horizontal, 10))
  }

  private var footer: some View {
    HStack(spacing: 14) {
      Text("↑↓ choose · ↩ run · esc close")
      Spacer()
      Text("\(matches.count) of \(WorkspaceCommandCatalog.all.count)")
    }
    .font(.caption)
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
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
    // Dismiss first: several of these put the caret somewhere — a composer, a
    // rename field, the sidebar — and a sheet still on screen would take it
    // straight back.
    dismiss()
    model.run(command.id)
  }
}
