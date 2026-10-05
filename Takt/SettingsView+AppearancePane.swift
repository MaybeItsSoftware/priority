import SwiftUI
import TaktCore

/// The Appearance page: the theme gallery, light or dark, and the reader's
/// type — faces for interface, headings and numerals, and a text size — laid
/// over whichever theme is chosen, so a theme switch keeps them.
extension SettingsView {
  private var themeManager: ThemeManager { checkvistManager.theme }

  @ViewBuilder
  var appearancePane: some View {
    ThemeSettingsPage(manager: checkvistManager, part: .choice)

    Section {
      SettingsRow(
        "Appearance",
        detail: themeManager.themeSpecification.lockedAppearance.map {
          "\(themeManager.themeSpecification.name) is always \($0.rawValue); this applies to the themes that have both."
        }
      ) {
        ThemedSegmentedPicker(
          selection: preferenceBinding(\.appearanceMode),
          options: AppearanceMode.allCases.map { ThemedPickerOption($0.title, value: $0) })
      }
    } header: {
      Text("Light and dark")
    }

    typeSection

    ThemeSettingsPage(manager: checkvistManager, part: .library)
  }

  @ViewBuilder
  private var typeSection: some View {
    let override = themeManager.typographyOverride
    let themeType = themeManager.themeSpecification.structure.typography
    Section {
      ForEach(FontRole.allCases) { role in
        SettingsRow(role.title, detail: role.detail) {
          FontFamilyPicker(
            role: role,
            family: Binding(
              get: { role.family(in: themeManager.typographyOverride) },
              set: { themeManager.typographyOverride = role.setting($0, in: themeManager.typographyOverride) }),
            themeFace: role.face(in: themeType))
        }
      }
      SettingsRow(
        "Text size",
        detail: "Scales every size the theme sets, in proportion. \(Self.points(themeType.bodySize * override.effectiveTextScale)) body text."
      ) {
        ThemedSegmentedPicker(
          selection: Binding(
            get: { Self.nearestTextScale(override.effectiveTextScale) },
            set: { scale in
              var next = themeManager.typographyOverride
              next.textScale = scale == 1 ? nil : scale
              themeManager.typographyOverride = next
            }),
          options: Self.textScales.map { ThemedPickerOption("\(Int(($0 * 100).rounded()))%", value: $0) })
      }
      typePreview
      HStack {
        Text(override.isEmpty ? "Every face and size is the theme's." : "Your choices apply over every theme.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
        Spacer(minLength: theme.space.sm)
        Button("Reset to theme") { themeManager.resetTypographyToTheme() }
          .disabled(override.isEmpty)
      }
    } header: {
      Text("Type")
    } footer: {
      Text(
        "Inter, Geist, IBM Plex Sans, Arvo, Lilex, JetBrains Mono and Geist Mono ship with Takt, so they look the same on every Mac. "
          + "A family installed only here falls back to the theme's own on a Mac without it."
      )
    }
  }

  /// The page itself is drawn in the result, but a specimen in one place
  /// makes the three faces and the scale comparable at a glance.
  private var typePreview: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Text("Plan the week")
        .font(theme.titleFont)
        .foregroundStyle(theme.ink)
      Text("Draft the release notes and send them for review before Thursday.")
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
      HStack(spacing: theme.space.sm) {
        Text("Due tomorrow").microLabel(theme)
        Text("25:00").font(theme.numeralFont(theme.scale.body)).foregroundStyle(theme.primary)
        Text("⌘K").font(theme.monoFont(size: theme.scale.caption)).foregroundStyle(theme.muted)
        Spacer(minLength: 0)
        Text("Caption text").font(theme.captionFont).foregroundStyle(theme.muted)
      }
    }
    .padding(theme.space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .themedSurface(theme, fill: theme.paper, radius: theme.controlRadius)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Type preview")
  }

  static let textScales: [Double] = [0.85, 0.9, 1, 1.1, 1.2, 1.3]

  static func nearestTextScale(_ value: Double) -> Double {
    textScales.min { abs($0 - value) < abs($1 - value) } ?? 1
  }

  static func points(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value))pt" : String(format: "%.1fpt", value)
  }
}
