import Foundation

/// A whole theme: who it is, what it is made of, and what it claims to be good
/// for. Pure data — the plugin that vends one is a wrapper, and the SwiftUI
/// `Theme` the app renders through is a projection.
public struct ThemeSpecification: Equatable, Sendable {
  public let identifier: String
  public let name: String
  public let summary: String
  /// A theme that exists in one appearance only.
  ///
  /// `nil` is the normal case: the theme has both tables and follows the
  /// system, so macOS's light/dark setting decides. A theme that sets this is
  /// saying it *is* that appearance — "Chalk Dark" is not Chalk with a
  /// preference, it is the dark half offered as a thing you can pick.
  ///
  /// This used to be advisory, on the reasoning that a theme should not
  /// override the system setting behind the user's back. That reasoning does
  /// not survive the theme being named after its appearance and chosen from a
  /// menu: picking "Chalk Dark" *is* the request, and honouring it everywhere
  /// except on screen would be the surprising behaviour.
  public let lockedAppearance: ThemeAppearance?
  public let palette: ThemePalette
  public let structure: ThemeStructure

  public init(
    identifier: String,
    name: String,
    summary: String,
    lockedAppearance: ThemeAppearance? = nil,
    palette: ThemePalette,
    structure: ThemeStructure
  ) {
    self.identifier = identifier
    self.name = name
    self.summary = summary
    self.lockedAppearance = lockedAppearance
    self.palette = palette
    self.structure = structure
  }

  public func color(_ role: ThemeColorRole, in appearance: ThemeAppearance) -> ThemeColorValue {
    palette.color(role, in: appearance)
  }

  /// Everything wrong with this theme, worst first. Empty means it is fit to
  /// ship.
  public func validate() -> [ThemeIssue] {
    var issues: [ThemeIssue] = []
    for appearance in ThemeAppearance.allCases {
      issues += palette.missingRoles(in: appearance).map {
        .missingRole(role: $0, appearance: appearance)
      }
    }
    issues += ThemeContrastAudit.findings(for: self)
    issues += ThemeStructureAudit.findings(for: structure)
    return issues.sorted { $0.severity.rank > $1.severity.rank }
  }
}

public enum ThemeIssueSeverity: Sendable {
  /// The theme is broken: something will render wrong.
  case error
  /// The theme renders, but a rule of the house style is being bent.
  case warning
  /// True, and worth knowing, but intended.
  case note

  public var rank: Int {
    switch self {
    case .error: return 2
    case .warning: return 1
    case .note: return 0
    }
  }
}

public enum ThemeIssue: Equatable, Sendable {
  case missingRole(role: ThemeColorRole, appearance: ThemeAppearance)
  /// A role used for running text that does not clear 4.5:1 on its surface.
  case bodyTextBelowAA(role: ThemeColorRole, appearance: ThemeAppearance, ratio: Double)
  /// An accent that does not clear 4.5:1 on the paper: headlines, large text,
  /// UI components and tinted fills only, never a paragraph. Azure on chalk is
  /// the house example, and it is deliberate — hence a note, not a warning.
  case largeTextOnly(role: ThemeColorRole, appearance: ThemeAppearance, ratio: Double)
  /// `primary` below 3:1. It is the one accent that carries chrome — focus
  /// rings, selection edges, link glyphs — so it cannot go under the WCAG
  /// minimum for a UI component the way a status tint can.
  case accentBelowUIMinimum(role: ThemeColorRole, appearance: ThemeAppearance, ratio: Double)
  /// A card you cannot tell from the page it is on.
  case raisedIndistinctFromPaper(appearance: ThemeAppearance, ratio: Double)
  case shadowsUsed
  case gradientsOnChrome
  case radiusScaleOutOfOrder
  /// A shell radius outside the 18–22 the house style reserves for it, and
  /// not zero (a theme with no rounded shell at all).
  case shellRadiusOffScale(value: Double)
  case hairlineTooHeavy(value: Double)
  /// A touch target set, but under the 44pt that iOS and Material both treat
  /// as the least a finger can reliably hit. Zero (a pointer platform) is fine.
  case touchTargetTooSmall(value: Double)

  public var severity: ThemeIssueSeverity {
    switch self {
    case .missingRole, .radiusScaleOutOfOrder:
      return .error
    case .bodyTextBelowAA, .accentBelowUIMinimum, .raisedIndistinctFromPaper,
      .shadowsUsed, .gradientsOnChrome, .shellRadiusOffScale, .hairlineTooHeavy, .touchTargetTooSmall:
      return .warning
    case .largeTextOnly:
      return .note
    }
  }

  public var message: String {
    switch self {
    case .missingRole(let role, let appearance):
      return "\(role.rawValue) has no \(appearance.rawValue) value"
    case .bodyTextBelowAA(let role, let appearance, let ratio):
      return
        "\(role.rawValue) is \(Self.format(ratio)):1 on \(appearance.rawValue) paper — below AA for body text"
    case .largeTextOnly(let role, let appearance, let ratio):
      return
        "\(role.rawValue) is \(Self.format(ratio)):1 on \(appearance.rawValue) paper — not for body copy"
    case .accentBelowUIMinimum(let role, let appearance, let ratio):
      return
        "\(role.rawValue) is \(Self.format(ratio)):1 on \(appearance.rawValue) paper — too low even for a UI component"
    case .raisedIndistinctFromPaper(let appearance, let ratio):
      return
        "raised is \(Self.format(ratio)):1 against paper in \(appearance.rawValue) — the card needs its hairline to exist"
    case .shadowsUsed:
      return "the theme declares shadows; separation is supposed to come from 1px borders"
    case .gradientsOnChrome:
      return "the theme declares gradients on chrome"
    case .radiusScaleOutOfOrder:
      return "the radius scale is not panel ≥ control (or a square panel), or the pill is not a pill"
    case .shellRadiusOffScale(let value):
      return "shell radius \(Self.format(value)) is outside the 18–22 reserved for the app shell"
    case .hairlineTooHeavy(let value):
      return "a \(Self.format(value))pt hairline is a border, not a hairline"
    case .touchTargetTooSmall(let value):
      return
        "a \(Self.format(value))pt touch target is under the \(Self.format(ThemeStructureAudit.smallestTouchTarget))pt a finger needs"
    }
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}

/// Reads a palette the way a reader does: every role against the surface it is
/// actually drawn on.
public enum ThemeContrastAudit {
  /// WCAG AA for body text.
  public static let bodyTextMinimum = 4.5
  /// WCAG AA for large text and UI components.
  public static let uiMinimum = 3.0
  /// Below this, a card is not distinguishable from the page without its
  /// border. Not a WCAG number — 1.03 is roughly where a half-step of tone
  /// stops being a half-step.
  public static let raisedMinimum = 1.03

  /// The four status hues, in the order they are reported.
  public static let accentRoles: [ThemeColorRole] = [.primary, .success, .danger, .warning]

  /// The one accent held to the UI-component minimum as well.
  ///
  /// The other three are a *tinted fill plus a border plus text of the same
  /// hue* — they are never a bare edge on the paper, so measuring them that
  /// way would condemn every amber that has ever worked. `primary` really does
  /// sit on the paper as a focus ring, so it really does need 3:1.
  public static let chromeCarryingRole: ThemeColorRole = .primary

  public static func ratio(
    _ role: ThemeColorRole,
    on surface: ThemeColorRole,
    in appearance: ThemeAppearance,
    of palette: ThemePalette
  ) -> Double {
    palette.color(role, in: appearance)
      .contrastRatio(against: palette.color(surface, in: appearance))
  }

  public static func findings(for specification: ThemeSpecification) -> [ThemeIssue] {
    var issues: [ThemeIssue] = []
    let palette = specification.palette

    for appearance in ThemeAppearance.allCases {
      for role in ThemeColorRole.bodyTextRoles {
        let value = ratio(role, on: .paper, in: appearance, of: palette)
        if value < bodyTextMinimum {
          issues.append(.bodyTextBelowAA(role: role, appearance: appearance, ratio: value))
        }
      }

      // Every accent under 4.5:1 is recorded as a note, which is how the
      // "never a paragraph of body copy" list gets generated rather than
      // remembered. Only `primary` is additionally held to 3:1.
      for role in accentRoles {
        let value = ratio(role, on: .paper, in: appearance, of: palette)
        if role == chromeCarryingRole, value < uiMinimum {
          issues.append(.accentBelowUIMinimum(role: role, appearance: appearance, ratio: value))
        } else if value < bodyTextMinimum {
          issues.append(.largeTextOnly(role: role, appearance: appearance, ratio: value))
        }
      }

      let raised = ratio(.raised, on: .paper, in: appearance, of: palette)
      if raised < raisedMinimum {
        issues.append(.raisedIndistinctFromPaper(appearance: appearance, ratio: raised))
      }
    }
    return issues
  }
}

/// The structural half of the same check.
public enum ThemeStructureAudit {
  public static let shellRadiusRange: ClosedRange<Double> = 18...22
  public static let heaviestHairline = 2.0
  /// The smallest non-zero `touchTarget` that passes.
  public static let smallestTouchTarget = 44.0

  public static func findings(for structure: ThemeStructure) -> [ThemeIssue] {
    var issues: [ThemeIssue] = []
    let radius = structure.radius
    // A square panel is the one exception to "panel ≥ control": a button in a
    // square pane may keep a small corner, but a panel rounder than zero and
    // tighter than its own buttons is a scale out of order.
    let panelOutOfOrder = radius.panel != 0 && radius.panel < radius.control
    if panelOutOfOrder || radius.pill < 999 {
      issues.append(.radiusScaleOutOfOrder)
    }
    if radius.shell != 0, !shellRadiusRange.contains(radius.shell) {
      issues.append(.shellRadiusOffScale(value: radius.shell))
    }
    if structure.border.hairline > heaviestHairline {
      issues.append(.hairlineTooHeavy(value: structure.border.hairline))
    }
    if structure.touchTarget != 0, structure.touchTarget < smallestTouchTarget {
      issues.append(.touchTargetTooSmall(value: structure.touchTarget))
    }
    if structure.usesShadows { issues.append(.shadowsUsed) }
    if structure.usesGradientsOnChrome { issues.append(.gradientsOnChrome) }
    return issues
  }
}
