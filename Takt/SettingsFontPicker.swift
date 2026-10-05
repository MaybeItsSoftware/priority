import AppKit
import SwiftUI
import TaktCore

/// Which face a font control sets.
enum FontRole: String, CaseIterable, Identifiable {
  case body
  case display
  case mono

  var id: String { rawValue }

  var title: String {
    switch self {
    case .body: "Interface"
    case .display: "Headings"
    case .mono: "Numerals and code"
    }
  }

  var detail: String {
    switch self {
    case .body: "Rows, fields, captions and labels."
    case .display: "Pane titles and headings."
    case .mono: "The clock, estimates, key caps and code."
    }
  }

  func face(in typography: ThemeTypography) -> ThemeFontFace {
    switch self {
    case .body: typography.body
    case .display: typography.display
    case .mono: typography.mono
    }
  }

  func family(in override: ThemeTypographyOverride) -> String? {
    switch self {
    case .body: override.bodyFamily
    case .display: override.displayFamily
    case .mono: override.monoFamily
    }
  }

  func setting(_ family: String?, in override: ThemeTypographyOverride) -> ThemeTypographyOverride {
    var copy = override
    switch self {
    case .body: copy.bodyFamily = family
    case .display: copy.displayFamily = family
    case .mono: copy.monoFamily = family
    }
    return copy
  }
}

/// A font control: the current choice written in its own face, opening a
/// searchable list of every family — the theme's default, the bundled ones,
/// then everything installed on this Mac — each set in itself.
struct FontFamilyPicker: View {
  let role: FontRole
  /// The family chosen, or nil for the theme's.
  @Binding var family: String?
  /// The theme's own request for this role, before any choice.
  let themeFace: ThemeFontFace
  @Environment(\.theme) private var theme
  @State private var isOpen = false

  private var label: String {
    family ?? "Theme default · \(Self.describe(themeFace))"
  }

  var body: some View {
    Button {
      isOpen.toggle()
    } label: {
      HStack(spacing: theme.space.xs) {
        Text(label)
          .font(Self.previewFont(family.map { [$0] } ?? themeFace.families, design: themeFace.design, size: theme.scale.body))
          .lineLimit(1)
          .foregroundStyle(theme.ink)
        Image(systemName: "chevron.up.chevron.down")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
      }
      .frame(minWidth: 180, alignment: .leading)
      .themedControlFrame()
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(role.title) font")
    .accessibilityValue(label)
    .popover(isPresented: $isOpen, arrowEdge: .bottom) {
      FontFamilyList(
        role: role,
        selection: family,
        themeFace: themeFace,
        choose: { chosen in
          family = chosen
          isOpen = false
        })
        // Popovers are their own window, so the theme is handed over.
        .environment(\.theme, theme)
    }
  }

  static func describe(_ face: ThemeFontFace) -> String {
    face.families.first ?? "System \(face.design.rawValue)"
  }

  static func previewFont(_ families: [String], design: ThemeFontDesign, size: CGFloat) -> Font {
    Theme.font(ThemeFontFace(families: families, design: design), size: size, weight: .regular)
  }
}

private struct FontFamilyList: View {
  let role: FontRole
  let selection: String?
  let themeFace: ThemeFontFace
  let choose: (String?) -> Void
  @Environment(\.theme) private var theme
  @State private var query = ""
  @State private var highlighted: Entry?
  @FocusState private var searchFocused: Bool

  enum Entry: Hashable {
    case themeDefault
    case family(String)

    var family: String? {
      if case .family(let name) = self { return name }
      return nil
    }
  }

  /// Every family installed, the bundled ones included — read once per
  /// process; the list only changes when fonts are installed.
  @MainActor private static let installed: [String] = NSFontManager.shared.availableFontFamilies
    .filter { !$0.hasPrefix(".") }
    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

  private var bundled: [BundledFontFamily] {
    let preferred = BundledFontFamily.all.filter { family in
      switch role {
      case .mono: family.design == .monospaced
      case .body, .display: family.design != .monospaced
      }
    }
    let rest = BundledFontFamily.all.filter { !preferred.contains($0) }
    return (preferred + rest).filter { matches($0.name) }
  }

  private var system: [String] {
    let bundledNames = Set(BundledFontFamily.all.map(\.name))
    return Self.installed.filter { !bundledNames.contains($0) && matches($0) }
  }

  private var entries: [Entry] {
    (matches("theme default") || query.isEmpty ? [Entry.themeDefault] : [])
      + bundled.map { .family($0.name) } + system.map { .family($0) }
  }

  private func matches(_ name: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces)
    return needle.isEmpty || name.localizedCaseInsensitiveContains(needle)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: theme.space.xs) {
        Image(systemName: "magnifyingglass").foregroundStyle(theme.muted)
        TextField("Search \(Self.installed.count) families", text: $query)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .onSubmit { choose((highlighted ?? entries.first)?.family) }
          .onKeyPress(.downArrow) { move(1) }
          .onKeyPress(.upArrow) { move(-1) }
      }
      .font(theme.bodyFont())
      .padding(theme.space.sm)
      Rectangle().fill(theme.border).frame(height: theme.hairline)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if entries.contains(.themeDefault) {
              row(.themeDefault, title: "Theme default", note: FontFamilyPicker.describe(themeFace),
                  families: themeFace.families)
            }
            if !bundled.isEmpty {
              eyebrow("Included with Takt")
              ForEach(bundled) { family in
                row(.family(family.name), title: family.name, note: family.note, families: [family.name])
              }
            }
            if !system.isEmpty {
              eyebrow("Installed on this Mac")
              ForEach(system, id: \.self) { name in
                row(.family(name), title: name, note: nil, families: [name])
              }
            }
            if entries.isEmpty {
              Text("No family matches “\(query)”.")
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
                .padding(theme.space.md)
            }
          }
          .padding(.vertical, theme.space.xs)
        }
        .onChange(of: highlighted) { _, entry in
          if let entry { proxy.scrollTo(entry) }
        }
      }
    }
    .frame(width: 340, height: 420)
    .background(theme.raised)
    .onAppear {
      searchFocused = true
      highlighted = selection.map { .family($0) } ?? .themeDefault
    }
    .onChange(of: query) { _, _ in highlighted = entries.first }
  }

  private func move(_ delta: Int) -> KeyPress.Result {
    let all = entries
    guard !all.isEmpty else { return .ignored }
    let index = highlighted.flatMap { all.firstIndex(of: $0) } ?? (delta > 0 ? -1 : all.count)
    highlighted = all[min(max(index + delta, 0), all.count - 1)]
    return .handled
  }

  private func eyebrow(_ text: String) -> some View {
    MicroLabel(text)
      .padding(.horizontal, theme.space.md)
      .padding(.top, theme.space.sm)
      .padding(.bottom, theme.space.xxs)
  }

  private func row(_ entry: Entry, title: String, note: String?, families: [String]) -> some View {
    let isChosen = entry == (selection.map { .family($0) } ?? .themeDefault)
    let isHighlighted = entry == highlighted
    return Button {
      choose(entry.family)
    } label: {
      HStack(spacing: theme.space.sm) {
        VStack(alignment: .leading, spacing: 1) {
          // The family's name in the family itself: the preview is the point.
          Text(title)
            .font(FontFamilyPicker.previewFont(families, design: themeFace.design, size: theme.scale.body + 2))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
          if let note {
            Text(note).font(theme.captionFont).foregroundStyle(theme.muted).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        if isChosen {
          Image(systemName: "checkmark").font(theme.captionFont).foregroundStyle(theme.primary)
        }
      }
      .padding(.horizontal, theme.space.md)
      .padding(.vertical, theme.space.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHighlighted ? theme.selectionFill : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { highlighted = entry } }
    .id(entry)
  }
}
