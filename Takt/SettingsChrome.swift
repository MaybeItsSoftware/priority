import SwiftUI
import TaktCore

// The settings window's own vocabulary, drawn by the theme.
//
// Every page is a `Form` of `Section`s — the app's panes and the plugin pages
// alike, since a plugin's page is a `Form` fragment it vends without knowing
// where it will be shown. `SettingsFormStyle` is what makes them one surface:
// each section is a micro-label eyebrow over a raised, hairline-bordered panel
// whose rows are divided by hairlines, with the footer in muted caption under
// it. No system grouped-form fill, no bezels, no shadows; the radius is the
// theme's panel radius and every colour is a role.

/// The layout every settings page uses.
struct SettingsFormStyle: FormStyle {
  func makeBody(configuration: Configuration) -> some View {
    SettingsFormBody(content: configuration.content)
  }
}

private struct SettingsFormBody<Content: View>: View {
  @Environment(\.theme) private var theme
  let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      ForEach(sections: content) { section in
        SettingsSectionPanel(section: section)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SettingsSectionPanel: View {
  @Environment(\.theme) private var theme
  let section: SectionConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      if !section.header.isEmpty {
        section.header
          .microLabel(theme)
          .padding(.horizontal, theme.space.xxs)
          .accessibilityAddTraits(.isHeader)
      }
      Group(subviews: section.content) { rows in
        if !rows.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
              if index > 0 {
                Rectangle().fill(theme.borderMuted).frame(height: theme.hairline)
              }
              row
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, theme.space.md)
                .padding(.vertical, theme.space.sm)
            }
          }
          .themedSurface(theme, fill: theme.raised, radius: theme.panelRadius)
        }
      }
      if !section.footer.isEmpty {
        section.footer
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .padding(.horizontal, theme.space.xxs)
      }
    }
  }
}

/// A label on the left and its value or control on the right, the shape a
/// settings row takes. Replaces the grouped form's own, which the custom form
/// style no longer supplies.
struct SettingsLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    SettingsLabeledRow(configuration: configuration)
  }
}

private struct SettingsLabeledRow: View {
  @Environment(\.theme) private var theme
  let configuration: LabeledContentStyleConfiguration

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.md) {
      configuration.label
        .foregroundStyle(theme.ink)
      Spacer(minLength: theme.space.sm)
      configuration.content
        .foregroundStyle(theme.muted)
        .multilineTextAlignment(.trailing)
    }
  }
}

/// One row: a title, an optional line of explanation under it, and the
/// control on the right. The explanation is muted caption, so a page can say
/// what a setting does without a paragraph between every switch.
struct SettingsRow<Control: View>: View {
  @Environment(\.theme) private var theme
  let title: String
  var detail: String?
  @ViewBuilder var control: Control

  init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.detail = detail
    self.control = control()
  }

  var body: some View {
    HStack(alignment: .center, spacing: theme.space.md) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text(title)
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
        if let detail {
          Text(detail)
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      control
    }
    .accessibilityElement(children: .combine)
  }
}

/// A switch row: `SettingsRow` whose control is the themed switch, with the
/// whole row as the hit target.
struct SettingsToggleRow: View {
  @Environment(\.theme) private var theme
  let title: String
  var detail: String?
  @Binding var isOn: Bool

  init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.detail = detail
    _isOn = isOn
  }

  var body: some View {
    Toggle(isOn: $isOn) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text(title)
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
        if let detail {
          Text(detail)
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .toggleStyle(.themedSwitch)
  }
}

/// A page's title band: the pane's name in the display face and a line saying
/// what lives here.
struct SettingsPageHeader: View {
  @Environment(\.theme) private var theme
  let title: String
  let summary: String

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Text(title)
        .font(theme.displayFont(size: theme.scale.display, weight: .medium))
        .foregroundStyle(theme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(summary)
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A status tag: a squarish 6px-radius rectangle in the status convention
/// (tinted fill, border and text of one hue), never a capsule.
struct SettingsTag: View {
  @Environment(\.theme) private var theme
  let text: String
  var tint: Color?

  var body: some View {
    let hue = tint ?? theme.muted
    Text(text)
      .font(theme.microLabelFont)
      .tracking(theme.microLabelTracking)
      .textCase(theme.microLabelIsUppercased ? .uppercase : nil)
      .foregroundStyle(hue)
      .lineLimit(1)
      .padding(.horizontal, theme.space.xs)
      .padding(.vertical, theme.space.xxs / 2)
      .themedSurface(
        theme,
        fill: hue.opacity(Theme.statusFillOpacity),
        radius: theme.controlRadius,
        stroke: hue.opacity(Theme.statusBorderOpacity))
  }
}

extension View {
  /// The settings window's defaults for anything a page draws without saying
  /// how: the form layout, labelled rows, buttons and switches in the theme.
  /// Text fields take `.themedTextField()` where they are written.
  func settingsChrome() -> some View {
    formStyle(SettingsFormStyle())
      .labeledContentStyle(SettingsLabeledContentStyle())
      .toggleStyle(.themedSwitch)
      .buttonStyle(FocusActionButtonStyle())
  }
}
