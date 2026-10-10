import Foundation
import TaktRustCore

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
  /// ship. The audit is the Rust core's (`core/src/theme/audit.rs`).
  public func validate() -> [ThemeIssue] {
    themeValidate(specification: core).map(ThemeIssue.init)
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

  public var severity: ThemeIssueSeverity { ThemeIssueSeverity(themeIssueSeverity(issue: core)) }

  /// The finding in a sentence, worded by the core so a file's audit reads
  /// the same on every platform.
  public var message: String { themeIssueMessage(issue: core) }
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
    themeContrastFindings(specification: specification.core).map(ThemeIssue.init)
  }
}

/// The structural half of the same check.
public enum ThemeStructureAudit {
  public static let shellRadiusRange: ClosedRange<Double> = 18...22
  public static let heaviestHairline = 2.0
  /// The smallest non-zero `touchTarget` that passes.
  public static let smallestTouchTarget = 44.0

  public static func findings(for structure: ThemeStructure) -> [ThemeIssue] {
    themeStructureFindings(structure: structure.core).map(ThemeIssue.init)
  }
}
