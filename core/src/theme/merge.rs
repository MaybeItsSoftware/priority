//! Laying one file over its base. Each bad value is one reported issue and
//! leaves the base's value standing; only a theme that cannot paint every
//! role is dropped.

use super::audit::{CoreThemeIssue, validate};
use super::color::from_hex;
use super::file::{
    CoreThemeFile, CoreThemeFileFace, CoreThemeFileIssue, CoreThemeFileLock,
    CoreThemeFileStructure, CoreThemeFileTypography,
};
use super::json::message_number;
use super::model::{
    ColorTable, CoreThemeAppearance, CoreThemeBorder, CoreThemeFontFace, CoreThemeIssueSeverity,
    CoreThemeMicroLabel, CoreThemePalette, CoreThemePlatform, CoreThemeRadius, CoreThemeSpacing,
    CoreThemeSpecification, CoreThemeStructure, CoreThemeTypeScale, CoreThemeTypography, DESIGNS,
    ROLES, WEIGHTS, is_role,
};
use super::seeds::CoreThemeSeeds;

pub type Report<'a> = dyn FnMut(CoreThemeIssueSeverity, String) + 'a;

/// A size from a file, or `fallback` when it is absent or unusable: negative,
/// not finite, or (for `positive` ones) zero.
fn length(
    value: Option<f64>,
    fallback: f64,
    prefix: &str,
    path: &str,
    positive: bool,
    report: &mut Report,
) -> f64 {
    let Some(value) = value else { return fallback };
    let ok = value.is_finite() && if positive { value > 0.0 } else { value >= 0.0 };
    if !ok {
        report(
            CoreThemeIssueSeverity::Error,
            format!(
                "{prefix}.{path} {} should be {}",
                message_number(value),
                if positive {
                    "above zero"
                } else {
                    "zero or more"
                }
            ),
        );
        return fallback;
    }
    value
}

/// What became of one file.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreThemeFileOutcome {
    pub source: String,
    /// `None` when the theme was skipped; `skipped_reason` says why.
    pub specification: Option<CoreThemeSpecification>,
    pub skipped_reason: Option<String>,
    /// Everything reported about this file, worst first, the audit included.
    pub issues: Vec<CoreThemeFileIssue>,
}

/// Stable, worst first.
pub fn sorted(mut issues: Vec<CoreThemeFileIssue>) -> Vec<CoreThemeFileIssue> {
    issues.sort_by_key(|issue| std::cmp::Reverse(issue.severity.rank()));
    issues
}

/// A file's own name for the theme, or `fallback`.
fn non_empty(value: &Option<String>) -> Option<String> {
    let trimmed = value.as_deref()?.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

pub fn merge_file(
    file: &CoreThemeFile,
    identifier: &str,
    source: &str,
    base: Option<&CoreThemeSpecification>,
    structure_fallback: &CoreThemeStructure,
    platform: CoreThemePlatform,
) -> CoreThemeFileOutcome {
    let mut issues: Vec<CoreThemeFileIssue> = Vec::new();
    let mut report = |severity: CoreThemeIssueSeverity, message: String| {
        issues.push(CoreThemeFileIssue::new(source, severity, message));
    };

    // Seeds, then palette: the base's table, the roles grown from the seeds
    // the file gives (over those the base implies), then the roles it states.
    let table = |appearance: CoreThemeAppearance, report: &mut Report| -> ColorTable {
        let mut table = base
            .map(|b| b.palette.table(appearance).clone())
            .unwrap_or_default();
        let name = appearance.raw();
        let seeds = file.seeds.as_ref().and_then(|s| match appearance {
            CoreThemeAppearance::Light => s.light.as_ref(),
            CoreThemeAppearance::Dark => s.dark.as_ref(),
        });
        if let Some(raw) = seeds {
            let mut stated = CoreThemeSeeds::default();
            let mut keys: Vec<&String> = raw.keys().collect();
            keys.sort();
            for key in keys {
                let value = &raw[key];
                let Some(slot) = stated.slot(key) else {
                    report(
                        CoreThemeIssueSeverity::Warning,
                        format!(
                            "seeds.{name}.{key} is not a seed ({}); ignored",
                            "background, foreground, accent, success, danger or warning"
                        ),
                    );
                    continue;
                };
                let Some(color) = from_hex(value) else {
                    report(
                        CoreThemeIssueSeverity::Error,
                        format!(
                            "seeds.{name}.{key} \"{value}\" is not a hex colour (#rgb, #rrggbb or #rrggbbaa)"
                        ),
                    );
                    continue;
                };
                *slot = Some(color);
            }
            match CoreThemeSeeds::implicit_in(&table)
                .overlaid(&stated)
                .roles(appearance)
            {
                Some(roles) => table.extend(roles),
                None => report(
                    CoreThemeIssueSeverity::Error,
                    format!("seeds.{name} needs a background and a foreground; ignored"),
                ),
            }
        }
        let overrides = file.palette.as_ref().and_then(|p| match appearance {
            CoreThemeAppearance::Light => p.light.as_ref(),
            CoreThemeAppearance::Dark => p.dark.as_ref(),
        });
        if let Some(overrides) = overrides {
            let mut keys: Vec<&String> = overrides.keys().collect();
            keys.sort();
            for key in keys {
                let raw = &overrides[key];
                if !is_role(key) {
                    report(
                        CoreThemeIssueSeverity::Warning,
                        format!("palette.{name}.{key} is not a colour role; ignored"),
                    );
                    continue;
                }
                let Some(value) = from_hex(raw) else {
                    report(
                        CoreThemeIssueSeverity::Error,
                        format!(
                            "palette.{name}.{key} \"{raw}\" is not a hex colour (#rgb, #rrggbb or #rrggbbaa)"
                        ),
                    );
                    continue;
                };
                table.insert(key.clone(), value);
            }
        }
        table
    };
    let light = table(CoreThemeAppearance::Light, &mut report);
    let dark = table(CoreThemeAppearance::Dark, &mut report);
    let palette = CoreThemePalette { light, dark };

    // A role in neither table would paint magenta: the one thing that stops
    // a theme loading.
    let unpainted: Vec<&str> = ROLES
        .into_iter()
        .filter(|role| !palette.light.contains_key(*role) && !palette.dark.contains_key(*role))
        .collect();
    if !unpainted.is_empty() {
        let reason = format!("no colour for {}", unpainted.join(", "));
        let mut all = vec![CoreThemeFileIssue::new(
            source,
            CoreThemeIssueSeverity::Error,
            format!("not loaded: {reason}"),
        )];
        all.extend(issues);
        return CoreThemeFileOutcome {
            source: source.to_string(),
            specification: None,
            skipped_reason: Some(reason),
            issues: sorted(all),
        };
    }

    let mut locked_appearance = base.and_then(|b| b.locked_appearance);
    match &file.locked_appearance {
        CoreThemeFileLock::Inherit => {}
        CoreThemeFileLock::Unlocked => locked_appearance = None,
        CoreThemeFileLock::Locked { raw } => match CoreThemeAppearance::parse(raw) {
            Some(appearance) => locked_appearance = Some(appearance),
            None => report(
                CoreThemeIssueSeverity::Error,
                format!("lockedAppearance \"{raw}\" should be \"light\", \"dark\" or null"),
            ),
        },
    }

    // The base as resolved for this platform, the file's own structure, then
    // its entry for this platform. Every platform's entry is checked, so a
    // bad value for the phone is reported on the Mac too.
    let mut structure = merge_structure(
        file.structure.as_ref(),
        base.map(|b| &b.structure).unwrap_or(structure_fallback),
        "structure",
        &mut report,
    );
    if let Some(platforms) = &file.platforms {
        for candidate in CoreThemePlatform::ALL {
            let Some(entry) = platforms.get(candidate).and_then(|o| o.structure.as_ref()) else {
                continue;
            };
            let merged = merge_structure(
                Some(entry),
                &structure,
                &format!("platforms.{}.structure", candidate.raw()),
                &mut report,
            );
            if candidate == platform {
                structure = merged;
            }
        }
    }

    let specification = CoreThemeSpecification {
        identifier: identifier.to_string(),
        name: non_empty(&file.name).unwrap_or_else(|| super::loader::stem(source)),
        summary: non_empty(&file.summary).unwrap_or_else(|| format!("Your theme, from {source}.")),
        locked_appearance,
        palette,
        structure,
    };
    for finding in validate(&specification) {
        // A missing role is a fact about the file; the rest is the audit.
        let is_audit = !matches!(finding, CoreThemeIssue::MissingRole { .. });
        issues.push(CoreThemeFileIssue {
            source: source.to_string(),
            severity: finding.severity(),
            message: finding.message(),
            is_audit,
        });
    }
    CoreThemeFileOutcome {
        source: source.to_string(),
        specification: Some(specification),
        skipped_reason: None,
        issues: sorted(issues),
    }
}

/// Lays a partial structure over a whole one. Problems go to `report` with
/// `prefix` (e.g. `structure`) in front of each key.
pub fn merge_structure(
    overrides: Option<&CoreThemeFileStructure>,
    base: &CoreThemeStructure,
    prefix: &str,
    report: &mut Report,
) -> CoreThemeStructure {
    let Some(overrides) = overrides else {
        return base.clone();
    };
    let length = |value: Option<f64>, fallback: f64, path: &str, report: &mut Report| {
        length(value, fallback, prefix, path, false, report)
    };
    let radius = match &overrides.radius {
        Some(f) => CoreThemeRadius {
            panel: length(f.panel, base.radius.panel, "radius.panel", report),
            row: length(f.row, base.radius.row, "radius.row", report),
            control: length(f.control, base.radius.control, "radius.control", report),
            pill: length(f.pill, base.radius.pill, "radius.pill", report),
            shell: length(f.shell, base.radius.shell, "radius.shell", report),
        },
        None => base.radius,
    };
    let border = match &overrides.border {
        Some(f) => CoreThemeBorder {
            hairline: length(f.hairline, base.border.hairline, "border.hairline", report),
            emphasis: length(f.emphasis, base.border.emphasis, "border.emphasis", report),
            focus_ring: length(
                f.focus_ring,
                base.border.focus_ring,
                "border.focusRing",
                report,
            ),
        },
        None => base.border,
    };
    let spacing = match &overrides.spacing {
        Some(f) => CoreThemeSpacing {
            xxs: length(f.xxs, base.spacing.xxs, "spacing.xxs", report),
            xs: length(f.xs, base.spacing.xs, "spacing.xs", report),
            sm: length(f.sm, base.spacing.sm, "spacing.sm", report),
            md: length(f.md, base.spacing.md, "spacing.md", report),
            lg: length(f.lg, base.spacing.lg, "spacing.lg", report),
            xl: length(f.xl, base.spacing.xl, "spacing.xl", report),
        },
        None => base.spacing,
    };
    let typography = match &overrides.typography {
        Some(t) => merge_typography(t, &base.typography, prefix, report),
        None => base.typography.clone(),
    };
    let touch_target = length(
        overrides.touch_target,
        base.touch_target,
        "touchTarget",
        report,
    );
    CoreThemeStructure {
        radius,
        border,
        spacing,
        typography,
        touch_target,
        uses_shadows: overrides.uses_shadows.unwrap_or(base.uses_shadows),
        uses_gradients_on_chrome: overrides
            .uses_gradients_on_chrome
            .unwrap_or(base.uses_gradients_on_chrome),
    }
}

fn merge_typography(
    file: &CoreThemeFileTypography,
    base: &CoreThemeTypography,
    prefix: &str,
    report: &mut Report,
) -> CoreThemeTypography {
    let length =
        |value: Option<f64>, fallback: f64, path: &str, positive: bool, report: &mut Report| {
            length(value, fallback, prefix, path, positive, report)
        };

    let body_size = length(
        file.body_size,
        base.body_size,
        "typography.bodySize",
        true,
        report,
    );
    // A new body size with no scale re-proportions the scale from it, so
    // "make everything bigger" is one number. Stated steps still win.
    let scale_base = if file.body_size.is_some() && body_size != base.body_size {
        CoreThemeTypeScale::proportioned(body_size)
    } else {
        base.scale
    };
    let scale = match &file.scale {
        Some(steps) => CoreThemeTypeScale {
            caption: length(
                steps.caption,
                scale_base.caption,
                "typography.scale.caption",
                true,
                report,
            ),
            body: length(
                steps.body,
                scale_base.body,
                "typography.scale.body",
                true,
                report,
            ),
            title: length(
                steps.title,
                scale_base.title,
                "typography.scale.title",
                true,
                report,
            ),
            display: length(
                steps.display,
                scale_base.display,
                "typography.scale.display",
                true,
                report,
            ),
            hero: length(
                steps.hero,
                scale_base.hero,
                "typography.scale.hero",
                true,
                report,
            ),
        },
        None => scale_base,
    };

    let micro_label = match &file.micro_label {
        Some(label) => {
            let mut weight = base.micro_label.weight.clone();
            if let Some(raw) = &label.weight {
                if WEIGHTS.contains(&raw.as_str()) {
                    weight = raw.clone();
                } else {
                    report(
                        CoreThemeIssueSeverity::Error,
                        format!(
                            "{prefix}.typography.microLabel.weight \"{raw}\" should be regular, medium, semibold, bold or black"
                        ),
                    );
                }
            }
            let mut role = base.micro_label.role.clone();
            if let Some(raw) = &label.role {
                if is_role(raw) {
                    role = raw.clone();
                } else {
                    report(
                        CoreThemeIssueSeverity::Error,
                        format!(
                            "{prefix}.typography.microLabel.role \"{raw}\" is not a colour role"
                        ),
                    );
                }
            }
            CoreThemeMicroLabel {
                size: length(
                    label.size,
                    base.micro_label.size,
                    "typography.microLabel.size",
                    true,
                    report,
                ),
                weight,
                tracking: length(
                    label.tracking,
                    base.micro_label.tracking,
                    "typography.microLabel.tracking",
                    false,
                    report,
                ),
                is_uppercased: label.uppercase.unwrap_or(base.micro_label.is_uppercased),
                role,
            }
        }
        None => base.micro_label.clone(),
    };

    let mut face = |file: &Option<CoreThemeFileFace>,
                    base: &CoreThemeFontFace,
                    path: &str|
     -> CoreThemeFontFace {
        let Some(file) = file else {
            return base.clone();
        };
        let mut design = base.design.clone();
        if let Some(raw) = &file.design {
            if DESIGNS.contains(&raw.as_str()) {
                design = raw.clone();
            } else {
                report(
                    CoreThemeIssueSeverity::Error,
                    format!(
                        "{prefix}.typography.{path}.design \"{raw}\" should be serif, sans, monospaced or rounded"
                    ),
                );
            }
        }
        CoreThemeFontFace {
            families: file
                .families
                .clone()
                .unwrap_or_else(|| base.families.clone()),
            design,
        }
    };
    CoreThemeTypography {
        display: face(&file.display, &base.display, "display"),
        body: face(&file.body, &base.body, "body"),
        mono: face(&file.mono, &base.mono, "mono"),
        body_size,
        scale,
        micro_label,
    }
}
