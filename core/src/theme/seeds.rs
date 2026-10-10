//! The few colours a whole palette can be grown from: a background, a
//! foreground and an accent per appearance, and optionally the three status
//! colours. The neutrals are mixed from them by fixed proportions; a role the
//! theme also states in `palette` still wins.

use super::color::{mix, rgba};
use super::model::{ColorTable, CoreThemeAppearance, CoreThemeColor};

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct CoreThemeSeeds {
    pub background: Option<CoreThemeColor>,
    pub foreground: Option<CoreThemeColor>,
    pub accent: Option<CoreThemeColor>,
    pub success: Option<CoreThemeColor>,
    pub danger: Option<CoreThemeColor>,
    pub warning: Option<CoreThemeColor>,
}

/// How far from the background towards the foreground each neutral sits.
const NEUTRAL_STEPS: [(&str, f64); 8] = [
    ("altRow", 0.025),
    ("hover", 0.05),
    ("well", 0.07),
    ("borderMuted", 0.07),
    ("border", 0.12),
    ("inputBorder", 0.2),
    ("dimText", 0.38),
    ("mutedText", 0.75),
];

impl CoreThemeSeeds {
    pub fn slot(&mut self, key: &str) -> Option<&mut Option<CoreThemeColor>> {
        match key {
            "background" => Some(&mut self.background),
            "foreground" => Some(&mut self.foreground),
            "accent" => Some(&mut self.accent),
            "success" => Some(&mut self.success),
            "danger" => Some(&mut self.danger),
            "warning" => Some(&mut self.warning),
            _ => None,
        }
    }

    /// The seeds a resolved table already implies: its page, ink, primary
    /// and status colours.
    pub fn implicit_in(table: &ColorTable) -> Self {
        CoreThemeSeeds {
            background: table.get("paper").copied(),
            foreground: table.get("ink").copied(),
            accent: table.get("primary").copied(),
            success: table.get("success").copied(),
            danger: table.get("danger").copied(),
            warning: table.get("warning").copied(),
        }
    }

    /// `self`, with every seed `overrides` states laid over it.
    pub fn overlaid(&self, overrides: &CoreThemeSeeds) -> Self {
        CoreThemeSeeds {
            background: overrides.background.or(self.background),
            foreground: overrides.foreground.or(self.foreground),
            accent: overrides.accent.or(self.accent),
            success: overrides.success.or(self.success),
            danger: overrides.danger.or(self.danger),
            warning: overrides.warning.or(self.warning),
        }
    }

    /// The roles these seeds paint, or `None` without both a background and
    /// a foreground. `raised` heads away from the text: whiter in the light,
    /// a step lighter in the dark.
    pub fn roles(&self, appearance: CoreThemeAppearance) -> Option<ColorTable> {
        let background = self.background?;
        let foreground = self.foreground?;
        let mut roles = ColorTable::new();
        roles.insert("paper".into(), background);
        roles.insert("ink".into(), foreground);
        for (role, step) in NEUTRAL_STEPS {
            roles.insert(role.into(), mix(&background, &foreground, step));
        }
        let raised = match appearance {
            CoreThemeAppearance::Light => mix(&background, &rgba(1.0, 1.0, 1.0, 1.0), 0.6),
            CoreThemeAppearance::Dark => mix(&background, &foreground, 0.04),
        };
        roles.insert("raised".into(), raised);
        for (role, value) in [
            ("primary", self.accent),
            ("success", self.success),
            ("danger", self.danger),
            ("warning", self.warning),
        ] {
            if let Some(value) = value {
                roles.insert(role.into(), value);
            }
        }
        Some(roles)
    }
}
