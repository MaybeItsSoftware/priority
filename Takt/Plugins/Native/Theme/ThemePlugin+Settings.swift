import TaktCore
import SwiftUI

/// One settings page, shared by every registered theme.
///
/// The convention is a plugin-local `+Settings.swift` conforming to
/// `PluginSettingsPageProviding`, and this is that — but written once against
/// the protocol rather than once per theme, because the page is a picker and
/// two copies of a picker is two bugs. `AppCoordinator.activePluginSettingsPages`
/// lists only the active theme, so exactly one card appears in the sidebar
/// however many themes are registered.
extension ThemePlugin where Self: PluginSettingsPageProviding {
  var settingsIconSystemName: String { themeIconSystemName }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(ThemeSettingsPage(manager: manager))
  }

  func sidebarStatusLabel(manager: AppCoordinator) -> String { "Active theme" }

  /// The capability's slot, not this theme's. Switching theme swaps which
  /// plugin vends the page; if the card's id went with it, the sidebar would
  /// lose its selection on every switch and throw the user out of the page
  /// they were switching from.
  var settingsCardIdentifier: String { "native.theme" }
}

extension PriorityThemePlugin: PluginSettingsPageProviding {}
extension ChalkThemePlugin: PluginSettingsPageProviding {}
extension ChalkDarkThemePlugin: PluginSettingsPageProviding {}
extension GrapeThemePlugin: PluginSettingsPageProviding {}
extension UserThemePlugin: PluginSettingsPageProviding {}

/// The theme half of Settings → Appearance: a gallery of every theme drawn in
/// its own colours and faces, the themes folder, and what the active theme is
/// made of. Sections only, no `Form` of its own — it is laid into the
/// Appearance page's form, which is what gives it the settings layout.
struct ThemeSettingsPage: View {
  /// Which half to draw: the gallery, or the themes folder and the details.
  /// Two halves so the Appearance page can put light/dark and type between.
  enum Part {
    case choice
    case library
  }

  let manager: AppCoordinator
  var part: Part = .choice
  @Environment(\.theme) private var theme

  private var themeManager: ThemeManager { manager.theme }

  var body: some View {
    switch part {
    case .choice: choiceSection
    case .library:
      userThemesSection
      detailsSection
    }
  }

  @ViewBuilder private var choiceSection: some View {
      Section {
        ThemeGallery(themeManager: themeManager)
        if let choiceSync = themeManager.choiceSync {
          SettingsToggleRow(
            "Use a different theme on this Mac",
            detail: choiceSync.usesDeviceChoice
              ? "This Mac keeps its own theme and appearance; your other devices neither change it nor are changed by it."
              : "Your theme and appearance follow you to your other devices, and a change on any of them shows here.",
            isOn: Binding(
              get: { choiceSync.usesDeviceChoice },
              set: { choiceSync.usesDeviceChoice = $0 }))
        }
        if themeManager.isFallingBack {
          Label(
            "Your theme \"\(themeManager.activeThemeIdentifier)\" did not load, so Priority is standing in until its file is fixed. Why is under Your themes.",
            systemImage: "exclamationmark.triangle"
          )
          .font(theme.captionFont)
          .foregroundStyle(theme.warning)
        }
      } header: {
        Text("Theme")
      } footer: {
        Text(footerText)
      }
  }

  private var footerText: String {
    let plugin = themeManager.activeThemePlugin
    if let locked = themeManager.themeSpecification.lockedAppearance {
      return "\(plugin.pluginDescription) Always \(locked.rawValue), whatever the appearance below is set to."
    }
    return plugin.pluginDescription
  }

  /// The themes folder: where it is, the ways in, and what the files got
  /// wrong. The format is in `docs/themes.md`.
  @ViewBuilder private var userThemesSection: some View {
    let library = themeManager.userThemes
    Section {
      LabeledContent("Folder") {
        Text(library.folderURL.path(percentEncoded: false))
          .font(theme.monoFont(size: theme.scale.caption))
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      HStack(spacing: theme.space.xs) {
        Button("Open themes folder") { library.openFolder() }
        Button("Duplicate current theme") { library.exportCurrentTheme() }
          .help("Writes the theme in force to a new file in the themes folder and switches to it, so you can edit a copy")
        Spacer(minLength: 0)
        Button("Reload") { library.reload(force: true) }
      }
      ForEach(library.skipped, id: \.source) { skipped in
        issueRow("\(skipped.source) not loaded: \(skipped.reason)", severity: .error)
      }
      // Errors and warnings across every file. Notes are left to the details
      // below, which give them for the theme in force; skips are above.
      let fileIssues = library.issues.filter {
        $0.severity != .note && !$0.message.hasPrefix("not loaded:")
      }
      ForEach(Array(fileIssues.enumerated()), id: \.offset) { _, issue in
        issueRow(issue.description, severity: issue.severity)
      }
    } header: {
      Text("Your themes")
    } footer: {
      Text(
        "Any .json file in the themes folder is a theme, and it reloads as you save it. "
          + "Three seed colours — background, foreground and accent — are enough; the rest is worked out from them. "
          + "The format is in docs/themes.md."
      )
    }
  }

  @ViewBuilder private var detailsSection: some View {
    Section {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: theme.space.sm) {
          ForEach(ThemeAppearance.allCases, id: \.self) { appearance in
            VStack(alignment: .leading, spacing: theme.space.xs) {
              Text(appearance.rawValue).microLabel(theme)
              swatchGrid(for: appearance)
            }
          }
          LabeledContent("Radii") { Text(radiusSummary).font(theme.monoFont(size: theme.scale.caption)) }
          LabeledContent("Borders") { Text(borderSummary).font(theme.monoFont(size: theme.scale.caption)) }
          LabeledContent("Spacing") { Text(spacingSummary).font(theme.monoFont(size: theme.scale.caption)) }
          LabeledContent("Faces") { Text(faceSummary).font(theme.captionFont) }
          let issues = themeManager.activeThemeIssues
          if issues.isEmpty {
            Text("The audit has no findings.").font(theme.captionFont).foregroundStyle(theme.muted)
          } else {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
              issueRow(issue.message, severity: issue.severity)
            }
          }
        }
        .padding(.top, theme.space.sm)
      } label: {
        Text("Palette, structure and audit of \(themeManager.themeSpecification.name)")
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
      }
    } header: {
      Text("Details")
    }
  }

  private func issueRow(_ message: String, severity: ThemeIssueSeverity) -> some View {
    Label {
      Text(message).font(theme.captionFont).foregroundStyle(theme.ink)
    } icon: {
      Image(systemName: icon(for: severity)).foregroundStyle(color(for: severity))
    }
  }

  /// Every role, in both appearances, as the thing it actually is. A palette
  /// you can only read as hex is a palette nobody checks.
  private func swatchGrid(for appearance: ThemeAppearance) -> some View {
    let specification = themeManager.specification
    let resolved = Theme(specification: specification, appearance: appearance)
    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: theme.space.xxs), count: 7),
      spacing: theme.space.xxs
    ) {
      ForEach(ThemeColorRole.allCases, id: \.self) { role in
        RoundedRectangle(cornerRadius: resolved.controlRadius, style: .continuous)
          .fill(resolved.color(role))
          .frame(height: 20)
          .overlay(
            RoundedRectangle(cornerRadius: resolved.controlRadius, style: .continuous)
              .strokeBorder(resolved.border, lineWidth: resolved.hairline)
          )
          .help("\(role.rawValue) — \(specification.color(role, in: appearance).hexString)")
      }
    }
  }

  private var radiusSummary: String {
    let radius = themeManager.specification.structure.radius
    return
      "panel \(number(radius.panel)) · row \(number(radius.row)) · control \(number(radius.control)) · pill \(number(radius.pill)) · shell \(number(radius.shell))"
  }

  private var borderSummary: String {
    let border = themeManager.specification.structure.border
    return
      "hairline \(number(border.hairline)) · emphasis \(number(border.emphasis)) · focus \(number(border.focusRing))"
  }

  private var spacingSummary: String {
    let space = themeManager.specification.structure.spacing
    return [space.xxs, space.xs, space.sm, space.md, space.lg, space.xl]
      .map(number)
      .joined(separator: " · ")
  }

  private var faceSummary: String {
    let type = themeManager.specification.structure.typography
    func describe(_ face: ThemeFontFace) -> String {
      face.families.first ?? "system \(face.design.rawValue)"
    }
    return
      "\(describe(type.display)) display · \(describe(type.body)) body · \(describe(type.mono)) mono · \(number(type.bodySize))pt"
  }

  private func number(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }

  private func icon(for severity: ThemeIssueSeverity) -> String {
    switch severity {
    case .error: return "xmark.octagon"
    case .warning: return "exclamationmark.triangle"
    case .note: return "info.circle"
    }
  }

  private func color(for severity: ThemeIssueSeverity) -> Color {
    switch severity {
    case .error: return theme.danger
    case .warning: return theme.warning
    case .note: return theme.primary
    }
  }
}

/// Every theme as a small window drawn in its own palette, radii and faces —
/// with the reader's font choices over it, since those apply to all of them.
/// Choosing one is a click or Return on the focused card.
struct ThemeGallery: View {
  let themeManager: ThemeManager
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: theme.space.sm)],
      alignment: .leading,
      spacing: theme.space.sm
    ) {
      ForEach(themeManager.availableThemes, id: \.pluginIdentifier) { plugin in
        let specification = themeManager.previewSpecification(for: plugin)
        let appearance =
          specification.lockedAppearance ?? (colorScheme == .dark ? .dark : .light)
        ThemeGalleryCard(
          preview: Theme(specification: specification, appearance: appearance),
          name: plugin.displayName,
          isUserTheme: plugin is UserThemePlugin,
          isSelected: themeManager.activeThemeIdentifier == plugin.pluginIdentifier
        ) {
          themeManager.activeThemeIdentifier = plugin.pluginIdentifier
        }
      }
    }
    .padding(.vertical, theme.space.xxs)
  }
}

private struct ThemeGalleryCard: View {
  /// The theme being previewed — not the window's.
  let preview: Theme
  let name: String
  let isUserTheme: Bool
  let isSelected: Bool
  let choose: () -> Void
  /// The window's theme, for the card's caption and selection ring.
  @Environment(\.theme) private var theme
  @FocusState private var isFocused: Bool
  @State private var isHovering = false

  var body: some View {
    Button(action: choose) {
      VStack(alignment: .leading, spacing: theme.space.xs) {
        miniature
        HStack(spacing: theme.space.xs) {
          Text(name)
            .font(theme.bodyFont(weight: isSelected ? .medium : .regular))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
          Spacer(minLength: 0)
          if isUserTheme { ThemedTag("File") }
          if isSelected {
            Image(systemName: "checkmark")
              .font(theme.captionFont)
              .foregroundStyle(theme.primary)
              .accessibilityHidden(true)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable()
    .focused($isFocused)
    .onKeyPress(.return) {
      choose()
      return .handled
    }
    .onHover { isHovering = $0 }
    .accessibilityLabel("\(name) theme")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// A window in miniature: a sidebar, a title in the theme's display face,
  /// three rows with the selection on one, and the four status hues.
  private var miniature: some View {
    let shape = RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
    return HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(0..<4, id: \.self) { index in
          RoundedRectangle(cornerRadius: 1.5)
            .fill(index == 1 ? preview.primary : preview.muted.opacity(0.55))
            .frame(width: index == 1 ? 26 : 22, height: 3)
        }
        Spacer(minLength: 0)
      }
      .padding(6)
      .frame(width: 40)
      .frame(maxHeight: .infinity, alignment: .top)
      .background(preview.altRow)
      .overlay(alignment: .trailing) {
        Rectangle().fill(preview.border).frame(width: preview.hairline)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Aa")
          .font(preview.displayFont(size: 15, weight: .medium))
          .foregroundStyle(preview.ink)
        miniRow(width: 70, selected: false)
        miniRow(width: 54, selected: true)
        miniRow(width: 62, selected: false)
        Spacer(minLength: 0)
        HStack(spacing: 3) {
          ForEach([preview.success, preview.danger, preview.warning, preview.primary].indices, id: \.self) { index in
            Circle()
              .fill([preview.success, preview.danger, preview.warning, preview.primary][index])
              .frame(width: 6, height: 6)
          }
          Spacer(minLength: 0)
          Text("12:30")
            .font(preview.monoFont(size: 8))
            .foregroundStyle(preview.muted)
        }
      }
      .padding(6)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(preview.paper)
    }
    .frame(height: 92)
    .clipShape(shape)
    .overlay(
      shape.strokeBorder(
        isSelected || isFocused ? theme.primary : (isHovering ? theme.inputBorder : theme.border),
        lineWidth: isSelected || isFocused ? theme.emphasisBorder : theme.hairline))
    .accessibilityHidden(true)
  }

  private func miniRow(width: CGFloat, selected: Bool) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 1.5)
        .strokeBorder(preview.inputBorder, lineWidth: 1)
        .frame(width: 6, height: 6)
      RoundedRectangle(cornerRadius: 1.5)
        .fill(preview.ink.opacity(0.7))
        .frame(width: width, height: 3)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 3)
    .padding(.vertical, 2)
    .background(
      RoundedRectangle(cornerRadius: min(preview.rowRadius, 3))
        .fill(selected ? preview.selectionFill : Color.clear))
  }
}
