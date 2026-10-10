//! A resolved theme written back out as a file: every value stated, with
//! each other platform's differences as the smallest `platforms` entry that
//! gets back to it.

use super::color::hex_string;
use super::file::{
    CoreThemeFile, CoreThemeFileBase, CoreThemeFileBorder, CoreThemeFileFace, CoreThemeFileLock,
    CoreThemeFileMicroLabel, CoreThemeFilePalette, CoreThemeFilePlatformOverride,
    CoreThemeFilePlatforms, CoreThemeFileRadius, CoreThemeFileSpacing, CoreThemeFileStructure,
    CoreThemeFileTypeScale, CoreThemeFileTypography,
};
use super::model::{
    ColorTable, CoreThemeFontFace, CoreThemePlatform, CoreThemeSpecification, CoreThemeStructure,
};

fn face(face: &CoreThemeFontFace) -> CoreThemeFileFace {
    CoreThemeFileFace {
        families: Some(face.families.clone()),
        design: Some(face.design.clone()),
    }
}

/// Every value of `structure`, stated.
pub fn stated(structure: &CoreThemeStructure) -> CoreThemeFileStructure {
    let r = &structure.radius;
    let b = &structure.border;
    let s = &structure.spacing;
    let t = &structure.typography;
    CoreThemeFileStructure {
        radius: Some(CoreThemeFileRadius {
            panel: Some(r.panel),
            row: Some(r.row),
            control: Some(r.control),
            pill: Some(r.pill),
            shell: Some(r.shell),
        }),
        border: Some(CoreThemeFileBorder {
            hairline: Some(b.hairline),
            emphasis: Some(b.emphasis),
            focus_ring: Some(b.focus_ring),
        }),
        spacing: Some(CoreThemeFileSpacing {
            xxs: Some(s.xxs),
            xs: Some(s.xs),
            sm: Some(s.sm),
            md: Some(s.md),
            lg: Some(s.lg),
            xl: Some(s.xl),
        }),
        typography: Some(CoreThemeFileTypography {
            display: Some(face(&t.display)),
            body: Some(face(&t.body)),
            mono: Some(face(&t.mono)),
            body_size: Some(t.body_size),
            scale: Some(CoreThemeFileTypeScale {
                caption: Some(t.scale.caption),
                body: Some(t.scale.body),
                title: Some(t.scale.title),
                display: Some(t.scale.display),
                hero: Some(t.scale.hero),
            }),
            micro_label: Some(CoreThemeFileMicroLabel {
                size: Some(t.micro_label.size),
                weight: Some(t.micro_label.weight.clone()),
                tracking: Some(t.micro_label.tracking),
                uppercase: Some(t.micro_label.is_uppercased),
                role: Some(t.micro_label.role.clone()),
            }),
        }),
        touch_target: Some(structure.touch_target),
        uses_shadows: Some(structure.uses_shadows),
        uses_gradients_on_chrome: Some(structure.uses_gradients_on_chrome),
    }
}

fn changed<T: PartialEq + Clone>(old: &T, new: &T) -> Option<T> {
    (old != new).then(|| new.clone())
}

fn non_default<T: Default + PartialEq>(value: T) -> Option<T> {
    (value != T::default()).then_some(value)
}

/// The smallest partial structure that, laid over `base`, gives `target`;
/// `None` when they are the same. A changed body size carries the whole
/// scale with it, because a new `bodySize` re-proportions every step it does
/// not state.
pub fn difference(
    base: &CoreThemeStructure,
    target: &CoreThemeStructure,
) -> Option<CoreThemeFileStructure> {
    let (br, tr) = (&base.radius, &target.radius);
    let radius = CoreThemeFileRadius {
        panel: changed(&br.panel, &tr.panel),
        row: changed(&br.row, &tr.row),
        control: changed(&br.control, &tr.control),
        pill: changed(&br.pill, &tr.pill),
        shell: changed(&br.shell, &tr.shell),
    };
    let (bb, tb) = (&base.border, &target.border);
    let border = CoreThemeFileBorder {
        hairline: changed(&bb.hairline, &tb.hairline),
        emphasis: changed(&bb.emphasis, &tb.emphasis),
        focus_ring: changed(&bb.focus_ring, &tb.focus_ring),
    };
    let (bs, ts) = (&base.spacing, &target.spacing);
    let spacing = CoreThemeFileSpacing {
        xxs: changed(&bs.xxs, &ts.xxs),
        xs: changed(&bs.xs, &ts.xs),
        sm: changed(&bs.sm, &ts.sm),
        md: changed(&bs.md, &ts.md),
        lg: changed(&bs.lg, &ts.lg),
        xl: changed(&bs.xl, &ts.xl),
    };

    let (old, new) = (&base.typography, &target.typography);
    let body_size = changed(&old.body_size, &new.body_size);
    let scale = if body_size.is_some() {
        CoreThemeFileTypeScale {
            caption: Some(new.scale.caption),
            body: Some(new.scale.body),
            title: Some(new.scale.title),
            display: Some(new.scale.display),
            hero: Some(new.scale.hero),
        }
    } else {
        CoreThemeFileTypeScale {
            caption: changed(&old.scale.caption, &new.scale.caption),
            body: changed(&old.scale.body, &new.scale.body),
            title: changed(&old.scale.title, &new.scale.title),
            display: changed(&old.scale.display, &new.scale.display),
            hero: changed(&old.scale.hero, &new.scale.hero),
        }
    };
    let (om, nm) = (&old.micro_label, &new.micro_label);
    let micro_label = CoreThemeFileMicroLabel {
        size: changed(&om.size, &nm.size),
        weight: changed(&om.weight, &nm.weight),
        tracking: changed(&om.tracking, &nm.tracking),
        uppercase: changed(&om.is_uppercased, &nm.is_uppercased),
        role: changed(&om.role, &nm.role),
    };
    let typography = CoreThemeFileTypography {
        display: changed(&old.display, &new.display).map(|f| face(&f)),
        body: changed(&old.body, &new.body).map(|f| face(&f)),
        mono: changed(&old.mono, &new.mono).map(|f| face(&f)),
        body_size,
        scale: non_default(scale),
        micro_label: non_default(micro_label),
    };

    non_default(CoreThemeFileStructure {
        radius: non_default(radius),
        border: non_default(border),
        spacing: non_default(spacing),
        typography: non_default(typography),
        touch_target: changed(&base.touch_target, &target.touch_target),
        uses_shadows: changed(&base.uses_shadows, &target.uses_shadows),
        uses_gradients_on_chrome: changed(
            &base.uses_gradients_on_chrome,
            &target.uses_gradients_on_chrome,
        ),
    })
}

fn hex_table(values: &ColorTable) -> std::collections::HashMap<String, String> {
    values
        .iter()
        .map(|(role, value)| (role.clone(), hex_string(value).to_lowercase()))
        .collect()
}

/// Every value of `specification` stated: what "export current theme"
/// writes. It still extends the default, so a role added in a later release
/// is inherited rather than missing from an old export. Each variant that
/// differs becomes `platforms.<platform>.structure`.
pub fn file_from_specification(
    specification: &CoreThemeSpecification,
    variants: &[(CoreThemePlatform, &CoreThemeSpecification)],
) -> CoreThemeFile {
    let mut platforms = CoreThemeFilePlatforms::default();
    for platform in CoreThemePlatform::ALL {
        let Some((_, variant)) = variants.iter().find(|(p, _)| *p == platform) else {
            continue;
        };
        if let Some(structure) = difference(&specification.structure, &variant.structure) {
            platforms.set(
                platform,
                Some(CoreThemeFilePlatformOverride {
                    structure: Some(structure),
                }),
            );
        }
    }
    CoreThemeFile {
        identifier: Some(specification.identifier.clone()),
        name: Some(specification.name.clone()),
        summary: Some(specification.summary.clone()),
        locked_appearance: match specification.locked_appearance {
            Some(appearance) => CoreThemeFileLock::Locked {
                raw: appearance.raw().to_string(),
            },
            None => CoreThemeFileLock::Unlocked,
        },
        extends: CoreThemeFileBase::DefaultTheme,
        seeds: None,
        palette: Some(CoreThemeFilePalette {
            light: Some(hex_table(&specification.palette.light)),
            dark: Some(hex_table(&specification.palette.dark)),
        }),
        structure: Some(stated(&specification.structure)),
        platforms: non_default(platforms),
    }
}
