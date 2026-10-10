//! The audit every theme is put through: every role against the surface it
//! is drawn on, and the structure against the house style's rules.

use super::color::contrast_ratio;
use super::model::{
    BODY_TEXT_ROLES, CoreThemeAppearance, CoreThemeIssueSeverity, CoreThemePalette,
    CoreThemeSpecification, CoreThemeStructure,
};

/// WCAG AA for body text.
pub const BODY_TEXT_MINIMUM: f64 = 4.5;
/// WCAG AA for large text and UI components.
pub const UI_MINIMUM: f64 = 3.0;
/// Below this a card cannot be told from the page without its border.
pub const RAISED_MINIMUM: f64 = 1.03;
/// The four status hues, in the order they are reported.
pub const ACCENT_ROLES: [&str; 4] = ["primary", "success", "danger", "warning"];
/// The one accent that sits on the paper as chrome, held to 3:1 as well.
pub const CHROME_CARRYING_ROLE: &str = "primary";
pub const SHELL_RADIUS_MIN: f64 = 18.0;
pub const SHELL_RADIUS_MAX: f64 = 22.0;
pub const HEAVIEST_HAIRLINE: f64 = 2.0;
/// The smallest non-zero touch target that passes.
pub const SMALLEST_TOUCH_TARGET: f64 = 44.0;

/// One finding.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreThemeIssue {
    MissingRole {
        role: String,
        appearance: CoreThemeAppearance,
    },
    /// Running text under 4.5:1 on the paper.
    BodyTextBelowAa {
        role: String,
        appearance: CoreThemeAppearance,
        ratio: f64,
    },
    /// An accent under 4.5:1: headlines, fills and controls, never a paragraph.
    LargeTextOnly {
        role: String,
        appearance: CoreThemeAppearance,
        ratio: f64,
    },
    /// `primary` under 3:1, too low even for a focus ring.
    AccentBelowUiMinimum {
        role: String,
        appearance: CoreThemeAppearance,
        ratio: f64,
    },
    RaisedIndistinctFromPaper {
        appearance: CoreThemeAppearance,
        ratio: f64,
    },
    ShadowsUsed,
    GradientsOnChrome,
    RadiusScaleOutOfOrder,
    ShellRadiusOffScale {
        value: f64,
    },
    HairlineTooHeavy {
        value: f64,
    },
    TouchTargetTooSmall {
        value: f64,
    },
}

fn format(value: f64) -> String {
    format!("{value:.2}")
}

impl CoreThemeIssue {
    pub fn severity(&self) -> CoreThemeIssueSeverity {
        match self {
            CoreThemeIssue::MissingRole { .. } | CoreThemeIssue::RadiusScaleOutOfOrder => {
                CoreThemeIssueSeverity::Error
            }
            CoreThemeIssue::LargeTextOnly { .. } => CoreThemeIssueSeverity::Note,
            _ => CoreThemeIssueSeverity::Warning,
        }
    }

    pub fn message(&self) -> String {
        match self {
            CoreThemeIssue::MissingRole { role, appearance } => {
                format!("{role} has no {} value", appearance.raw())
            }
            CoreThemeIssue::BodyTextBelowAa {
                role,
                appearance,
                ratio,
            } => format!(
                "{role} is {}:1 on {} paper — below AA for body text",
                format(*ratio),
                appearance.raw()
            ),
            CoreThemeIssue::LargeTextOnly {
                role,
                appearance,
                ratio,
            } => format!(
                "{role} is {}:1 on {} paper — not for body copy",
                format(*ratio),
                appearance.raw()
            ),
            CoreThemeIssue::AccentBelowUiMinimum {
                role,
                appearance,
                ratio,
            } => format!(
                "{role} is {}:1 on {} paper — too low even for a UI component",
                format(*ratio),
                appearance.raw()
            ),
            CoreThemeIssue::RaisedIndistinctFromPaper { appearance, ratio } => format!(
                "raised is {}:1 against paper in {} — the card needs its hairline to exist",
                format(*ratio),
                appearance.raw()
            ),
            CoreThemeIssue::ShadowsUsed => {
                "the theme declares shadows; separation is supposed to come from 1px borders".to_string()
            }
            CoreThemeIssue::GradientsOnChrome => "the theme declares gradients on chrome".to_string(),
            CoreThemeIssue::RadiusScaleOutOfOrder => {
                "the radius scale is not panel ≥ control (or a square panel), or the pill is not a pill"
                    .to_string()
            }
            CoreThemeIssue::ShellRadiusOffScale { value } => format!(
                "shell radius {} is outside the 18–22 reserved for the app shell",
                format(*value)
            ),
            CoreThemeIssue::HairlineTooHeavy { value } => {
                format!("a {}pt hairline is a border, not a hairline", format(*value))
            }
            CoreThemeIssue::TouchTargetTooSmall { value } => format!(
                "a {}pt touch target is under the {}pt a finger needs",
                format(*value),
                format(SMALLEST_TOUCH_TARGET)
            ),
        }
    }
}

pub fn ratio(
    palette: &CoreThemePalette,
    role: &str,
    surface: &str,
    appearance: CoreThemeAppearance,
) -> f64 {
    contrast_ratio(
        &palette.color(role, appearance),
        &palette.color(surface, appearance),
    )
}

pub fn contrast_findings(specification: &CoreThemeSpecification) -> Vec<CoreThemeIssue> {
    let palette = &specification.palette;
    let mut issues = Vec::new();
    for appearance in CoreThemeAppearance::ALL {
        for role in BODY_TEXT_ROLES {
            let value = ratio(palette, role, "paper", appearance);
            if value < BODY_TEXT_MINIMUM {
                issues.push(CoreThemeIssue::BodyTextBelowAa {
                    role: role.into(),
                    appearance,
                    ratio: value,
                });
            }
        }
        for role in ACCENT_ROLES {
            let value = ratio(palette, role, "paper", appearance);
            if role == CHROME_CARRYING_ROLE && value < UI_MINIMUM {
                issues.push(CoreThemeIssue::AccentBelowUiMinimum {
                    role: role.into(),
                    appearance,
                    ratio: value,
                });
            } else if value < BODY_TEXT_MINIMUM {
                issues.push(CoreThemeIssue::LargeTextOnly {
                    role: role.into(),
                    appearance,
                    ratio: value,
                });
            }
        }
        let raised = ratio(palette, "raised", "paper", appearance);
        if raised < RAISED_MINIMUM {
            issues.push(CoreThemeIssue::RaisedIndistinctFromPaper {
                appearance,
                ratio: raised,
            });
        }
    }
    issues
}

pub fn structure_findings(structure: &CoreThemeStructure) -> Vec<CoreThemeIssue> {
    let mut issues = Vec::new();
    let radius = &structure.radius;
    // A square panel may hold a button with a small corner; a rounded panel
    // tighter than its own buttons is a scale out of order.
    let panel_out_of_order = radius.panel != 0.0 && radius.panel < radius.control;
    if panel_out_of_order || radius.pill < 999.0 {
        issues.push(CoreThemeIssue::RadiusScaleOutOfOrder);
    }
    if radius.shell != 0.0 && !(SHELL_RADIUS_MIN..=SHELL_RADIUS_MAX).contains(&radius.shell) {
        issues.push(CoreThemeIssue::ShellRadiusOffScale {
            value: radius.shell,
        });
    }
    if structure.border.hairline > HEAVIEST_HAIRLINE {
        issues.push(CoreThemeIssue::HairlineTooHeavy {
            value: structure.border.hairline,
        });
    }
    if structure.touch_target != 0.0 && structure.touch_target < SMALLEST_TOUCH_TARGET {
        issues.push(CoreThemeIssue::TouchTargetTooSmall {
            value: structure.touch_target,
        });
    }
    if structure.uses_shadows {
        issues.push(CoreThemeIssue::ShadowsUsed);
    }
    if structure.uses_gradients_on_chrome {
        issues.push(CoreThemeIssue::GradientsOnChrome);
    }
    issues
}

/// Everything wrong with a theme, worst first. Empty means fit to ship.
pub fn validate(specification: &CoreThemeSpecification) -> Vec<CoreThemeIssue> {
    let mut issues = Vec::new();
    for appearance in CoreThemeAppearance::ALL {
        issues.extend(
            specification
                .palette
                .missing_roles(appearance)
                .into_iter()
                .map(|role| CoreThemeIssue::MissingRole {
                    role: role.into(),
                    appearance,
                }),
        );
    }
    issues.extend(contrast_findings(specification));
    issues.extend(structure_findings(&specification.structure));
    // Stable, worst first.
    issues.sort_by_key(|issue| std::cmp::Reverse(issue.severity().rank()));
    issues
}
