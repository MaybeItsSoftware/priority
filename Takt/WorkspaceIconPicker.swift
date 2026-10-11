import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// A list's icon: a symbol, or an emoji drawn as text in the same column.
struct WorkspaceIconImage: View {
  let name: String

  var body: some View {
    if WorkspaceListIconName.isEmoji(name) {
      // Emoji ignore the foreground style, which is the point of one.
      Text(name)
    } else {
      Image(systemName: name)
    }
  }
}

extension View {
  /// Opens the icon picker as a popover on this row while it is the row
  /// `iconPickerRowID` names — from the context menu's Icon… or `⇧I`.
  func workspaceIconPicker(rowID: String, target: WorkspaceIconTarget) -> some View {
    modifier(WorkspaceIconPickerPresenter(rowID: rowID, target: target))
  }
}

private struct WorkspaceIconPickerPresenter: ViewModifier {
  @Environment(WorkspaceViewModel.self) private var model
  let rowID: String
  let target: WorkspaceIconTarget

  func body(content: Content) -> some View {
    content.popover(
      isPresented: Binding(
        get: { model.iconPickerRowID == rowID },
        set: { if !$0, model.iconPickerRowID == rowID { model.closeIconPicker() } }),
      arrowEdge: .trailing
    ) {
      WorkspaceIconPicker(target: target)
    }
  }
}

/// A grid of symbols, and for lists and folders a field for an emoji.
///
/// The keyboard opens on the grid at the current icon: the arrows (or h j k l)
/// walk it, Return chooses, Esc closes, and Tab goes to the emoji field.
struct WorkspaceIconPicker: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let target: WorkspaceIconTarget

  @State private var cursor = 0
  @State private var emoji = ""
  @FocusState private var focus: Field?

  private enum Field { case grid, emoji }
  private static let columns = 6

  private var choices: [(symbol: String, label: String)] { model.iconChoices(for: target) }
  private var current: String { model.icon(for: target) }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      grid
      if target.allowsEmoji {
        Divider()
        emojiField
      }
      Divider()
      HStack {
        Button("Default") { choose(nil) }
          .help("Put the default icon back")
        Spacer()
        Text("↩ choose · ⎋ close")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
      }
      .buttonStyle(.plain)
      .font(theme.captionFont)
    }
    .padding(theme.space.md)
    .frame(width: 6 * 32 + 2 * 12)
    .onAppear {
      cursor = choices.firstIndex { $0.symbol == current } ?? 0
      focus = .grid
    }
  }

  private var grid: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: Self.columns), spacing: 4) {
      ForEach(Array(choices.enumerated()), id: \.element.symbol) { index, choice in
        Button { choose(choice.symbol) } label: {
          Image(systemName: choice.symbol)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .background(
              choice.symbol == current ? theme.selectionFill : .clear,
              in: RoundedRectangle(cornerRadius: theme.rowRadius))
            .overlay(
              RoundedRectangle(cornerRadius: theme.rowRadius)
                .strokeBorder(
                  index == cursor && focus == .grid ? theme.primary : .clear,
                  lineWidth: theme.emphasisBorder))
        }
        .buttonStyle(.plain)
        .help(choice.label)
        .accessibilityLabel(choice.label)
      }
    }
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .grid)
    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, "h", "j", "k", "l"]) { press in
      step(press.key)
      return .handled
    }
    .onKeyPress(.return) {
      if choices.indices.contains(cursor) { choose(choices[cursor].symbol) }
      return .handled
    }
    .onKeyPress(.escape) {
      model.closeIconPicker()
      return .handled
    }
  }

  private var emojiField: some View {
    HStack(spacing: theme.space.xs) {
      TextField("Emoji", text: $emoji)
        .textFieldStyle(.roundedBorder)
        .focused($focus, equals: .emoji)
        .onSubmit {
          if let picked = WorkspaceListIconName.emoji(from: emoji) { choose(picked) }
        }
        .onExitCommand { model.closeIconPicker() }
        .help("Type or paste an emoji, then Return")
      Button {
        focus = .emoji
        NSApp.orderFrontCharacterPalette(nil)
      } label: {
        Image(systemName: "face.smiling")
      }
      .buttonStyle(.plain)
      .help("Emoji & Symbols")
      .accessibilityLabel("Emoji and symbols palette")
    }
  }

  private func step(_ key: KeyEquivalent) {
    let count = choices.count
    guard count > 0 else { return }
    let offset: Int
    switch key {
    case .leftArrow, "h": offset = -1
    case .rightArrow, "l": offset = 1
    case .upArrow, "k": offset = -Self.columns
    default: offset = Self.columns
    }
    let next = cursor + offset
    if next >= 0, next < count { cursor = next }
  }

  private func choose(_ name: String?) {
    model.setIcon(name, for: target)
    model.closeIconPicker()
  }
}
