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
//
// A long page — several titled sections and a lot of rows between them — is
// drawn as disclosures instead: each titled section's eyebrow becomes a header
// that opens and closes its panel, so the page reads as a short list of
// headings. The form style decides that from the page's shape, not from which
// page it is, so a plugin's page is treated like the app's own without
// `SettingsView` naming it. What is open is remembered per page.

/// The layout every settings page uses.
struct SettingsFormStyle: FormStyle {
  func makeBody(configuration: Configuration) -> some View {
    SettingsFormBody(content: configuration.content)
  }
}

private struct SettingsFormBody<Content: View>: View {
  @Environment(\.theme) private var theme
  @Environment(\.settingsPageKey) private var pageKey
  @Environment(\.settingsSearchQuery) private var searchQuery
  let content: Content

  var body: some View {
    Group(sections: content) { sections in
      let collapsible = SettingsDisclosurePolicy.isLong(
        titledSections: sections.filter { !$0.header.isEmpty }.count,
        rows: sections.reduce(0) { $0 + $1.content.count })
      // The first titled section is open until it is closed, so a long page
      // never opens onto nothing but headings; the rest start closed. Which
      // was first is settled the first time each section is drawn and kept
      // under its title, so a section that comes and goes above it later
      // does not open or close the ones below.
      let firstTitled = sections.firstIndex { !$0.header.isEmpty }
      VStack(alignment: .leading, spacing: collapsible ? theme.space.sm : theme.space.lg) {
        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
          if collapsible && !section.header.isEmpty {
            // Remembered by its title, so a section that comes and goes —
            // signed in or not — does not hand its state to the next one.
            let title = section.header.first?.containerValues.settingsSectionTitle
            SettingsDisclosureSection(
              section: section,
              key: "\(pageKey)#\(title ?? String(index))",
              opensByDefault: index == firstTitled,
              matchesSearch: title.map { Self.matches($0, searchQuery) } ?? false)
          } else {
            SettingsSectionPanel(section: section)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Whether the sidebar's search names this section, so the page it opened
  /// onto shows the section rather than its heading.
  private static func matches(_ title: String, _ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces)
    return !needle.isEmpty && title.localizedCaseInsensitiveContains(needle)
  }
}

/// When a page is long enough to be drawn as disclosures. A handful of
/// controls stays a page of open panels: folding three switches away hides
/// more than it tidies.
enum SettingsDisclosurePolicy {
  static let minimumTitledSections = 3
  static let minimumRows = 8

  static func isLong(titledSections: Int, rows: Int) -> Bool {
    titledSections >= minimumTitledSections && rows >= minimumRows
  }
}

/// Which page a settings form is drawing, so a disclosure can remember its
/// state per page. Set by the window round each page's `Form`.
extension EnvironmentValues {
  @Entry var settingsPageKey: String = "settings"
  /// What the sidebar's search holds, so a section it names opens.
  @Entry var settingsSearchQuery: String = ""
}

/// A settings section's title, as its header carries it to the form style.
extension ContainerValues {
  @Entry var settingsSectionTitle: String?
}

/// A settings section's header: its title, drawn as the eyebrow, and named to
/// the form style, which remembers a folded section by it.
struct SettingsHeader: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(LocalizedStringKey(title))
      .containerValue(\.settingsSectionTitle, title)
  }
}

/// The disclosures the reader opened or closed, by page and section, kept in
/// the preferences so the window opens the way it was left.
@MainActor
@Observable
final class SettingsDisclosureMemory {
  static let shared = SettingsDisclosureMemory()
  private static let defaultsKey = "settingsDisclosureState"

  private var state: [String: Bool]

  private init() {
    state = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
  }

  func isOpen(_ key: String, default opensByDefault: Bool) -> Bool {
    state[key] ?? opensByDefault
  }

  /// Keeps a section's default the first time it is drawn, so where it then
  /// sits on the page no longer decides whether it opens.
  func settle(_ key: String, default opensByDefault: Bool) {
    guard state[key] == nil else { return }
    set(key, open: opensByDefault)
  }

  func set(_ key: String, open: Bool) {
    state[key] = open
    UserDefaults.standard.set(state, forKey: Self.defaultsKey)
  }
}

/// A titled section as a disclosure: the eyebrow, with a chevron, is a button
/// across the page's width that opens and closes the panel and its footer.
private struct SettingsDisclosureSection: View {
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.settingsSearchQuery) private var searchQuery
  let section: SectionConfiguration
  let key: String
  let opensByDefault: Bool
  /// Named by the settings search: open while it is, without remembering so.
  let matchesSearch: Bool
  /// The search this section was folded under by hand. Folding a section the
  /// search opened lasts as long as that search and is never saved, so the
  /// remembered state is still the reader's own once the search is cleared.
  @State private var foldedForSearch: String?
  private var memory: SettingsDisclosureMemory { .shared }

  var body: some View {
    let isOpen =
      matchesSearch
      ? foldedForSearch != searchQuery
      : memory.isOpen(key, default: opensByDefault)
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
          if matchesSearch {
            foldedForSearch = isOpen ? searchQuery : nil
          } else {
            memory.set(key, open: !isOpen)
          }
        }
      } label: {
        HStack(spacing: theme.space.xs) {
          Image(systemName: "chevron.right")
            .font(.system(size: theme.scale.caption * 0.8, weight: .semibold))
            .foregroundStyle(theme.muted)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .frame(width: theme.scale.caption)
          section.header
            .microLabel(theme)
          Spacer(minLength: theme.space.sm)
        }
        .padding(.horizontal, theme.space.xxs)
        .padding(.vertical, theme.space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(.isHeader)
      .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
      .accessibilityHint(isOpen ? "Collapses this group" : "Expands this group")
      .help(isOpen ? "Collapse" : "Expand")
      if isOpen {
        SettingsSectionRows(rows: section.content)
        SettingsSectionFooter(footer: section.footer)
      }
    }
    .onAppear { memory.settle(key, default: opensByDefault) }
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
      SettingsSectionRows(rows: section.content)
      SettingsSectionFooter(footer: section.footer)
    }
  }
}

/// A section's rows: a raised, hairline-bordered panel, divided by hairlines.
private struct SettingsSectionRows: View {
  @Environment(\.theme) private var theme
  let rows: SubviewsCollection

  var body: some View {
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 {
            FocusRule(muted: true)
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
}

private struct SettingsSectionFooter: View {
  @Environment(\.theme) private var theme
  let footer: SubviewsCollection

  var body: some View {
    if !footer.isEmpty {
      footer
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .padding(.horizontal, theme.space.xxs)
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
