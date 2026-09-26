import PriorityCore
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
}

extension ChalkThemePlugin: PluginSettingsPageProviding {}
extension PitchThemePlugin: PluginSettingsPageProviding {}

struct ThemeSettingsPage: View {
  let manager: AppCoordinator
  @Environment(\.theme) private var theme

  private var themeManager: ThemeManager { manager.theme }

  var body: some View {
    Form {
      Section("Theme") {
        Picker("Look", selection: themeBinding) {
          ForEach(themeManager.availableThemes, id: \.pluginIdentifier) { plugin in
            Label(plugin.displayName, systemImage: plugin.themeIconSystemName)
              .tag(plugin.pluginIdentifier)
          }
        }
        .pickerStyle(.inline)

        Text(themeManager.activeThemePlugin.pluginDescription)
          .font(.caption)
          .foregroundStyle(.secondary)

        if let preferred = themeManager.specification.preferredAppearance {
          Text(
            "Drawn for \(preferred.rawValue) mode. Appearance still follows your Light/Dark/System setting above — a theme does not get to change that for you."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Section("Palette") {
        ForEach(ThemeAppearance.allCases, id: \.self) { appearance in
          VStack(alignment: .leading, spacing: 6) {
            Text(appearance.rawValue)
              .microLabel(theme)
            swatchGrid(for: appearance)
          }
          .padding(.vertical, 2)
        }
      }

      Section("Structure") {
        LabeledContent("Radii") {
          Text(radiusSummary).font(.caption).monospaced()
        }
        LabeledContent("Borders") {
          Text(borderSummary).font(.caption).monospaced()
        }
        LabeledContent("Spacing") {
          Text(spacingSummary).font(.caption).monospaced()
        }
        LabeledContent("Faces") {
          Text(faceSummary).font(.caption)
        }
        Text(
          "Font families are requests, not bundled files: the named face is used if it is installed on this Mac, and the fallback design is what you see otherwise."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Audit") {
        let issues = themeManager.activeThemeIssues
        if issues.isEmpty {
          Text("No findings.").font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
            Label {
              Text(issue.message).font(.caption)
            } icon: {
              Image(systemName: icon(for: issue.severity))
                .foregroundStyle(color(for: issue.severity))
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var themeBinding: Binding<String> {
    Binding(
      get: { themeManager.activeThemeIdentifier },
      set: { themeManager.activeThemeIdentifier = $0 }
    )
  }

  /// Every role, in both appearances, as the thing it actually is. A palette
  /// you can only read as hex is a palette nobody checks.
  private func swatchGrid(for appearance: ThemeAppearance) -> some View {
    let specification = themeManager.specification
    let resolved = Theme(specification: specification, appearance: appearance)
    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
      spacing: 4
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
      "panel \(number(radius.panel)) · control \(number(radius.control)) · pill \(number(radius.pill)) · shell \(number(radius.shell))"
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
      face.families.isEmpty ? "system \(face.design.rawValue)" : face.families.joined(separator: "/")
    }
    return
      "\(describe(type.display)) display · \(describe(type.body)) body · \(describe(type.mono)) mono"
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
