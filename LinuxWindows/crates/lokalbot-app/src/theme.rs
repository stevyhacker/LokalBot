//! LokalBot design tokens, translated from the macOS app
//! (`LokalBot/Support/DesignTokens.swift`, `Brand.swift`).
//!
//! Views read colors with `cx.lb()` and sizes from [`ty`] and [`metric`].
//! GPUI Kit components (buttons, inputs, switches, menus) are themed from the
//! same palette in [`apply`], so both layers agree.

use gpui_kit::component::{Theme, ThemeMode};
use gpui_kit::{
    App, FontFallbacks, Global, Hsla, Styled, Window, WindowAppearance, hsla, px, rgb, rgba,
};

use lokalbot_core::settings::AppTheme;

/// Colors for one appearance. Names follow the macOS tokens.
#[derive(Clone, Debug)]
pub struct Palette {
    pub dark: bool,
    /// Content background.
    pub window: Hsla,
    pub sidebar: Hsla,
    pub sidebar_selection: Hsla,
    pub title_bar: Hsla,
    /// Elevated surfaces: popovers, the Quick Recall panel, the composer.
    pub elevated: Hsla,
    pub text: Hsla,
    pub text_secondary: Hsla,
    pub text_tertiary: Hsla,
    /// Grey used for metadata lines ("FaceTime · 10:57 AM · 2 min").
    pub supporting: Hsla,
    pub separator: Hsla,
    /// Wells and the faint strips of a section panel: its footer and bands
    /// (`groupFill`).
    pub group_fill: Hsla,
    /// The edge of grouped wells and section panels (`groupStroke`).
    pub group_stroke: Hsla,
    /// Chips and quiet wells (quaternary fill at about 50%).
    pub chip_fill: Hsla,
    /// Count pills and the empty part of a bar on a panel: quiet, and still a
    /// visible shape in both appearances (`quietFill`).
    pub quiet_fill: Hsla,
    /// The page behind section panels (`windowBackgroundColor`), so each
    /// panel reads as its own raised surface.
    pub page: Hsla,
    /// A section panel's raised surface (`controlBackgroundColor`).
    pub panel: Hsla,
    pub hover: Hsla,
    /// Filled buttons, selected rows in a focused list, switches. White text on it.
    pub accent_fill: Hsla,
    pub accent_fill_hover: Hsla,
    /// Links, timestamps, sidebar symbols and evidence pills.
    pub accent_text: Hsla,
    pub accent_wash: Hsla,
    pub attention: Hsla,
    pub attention_text: Hsla,
    pub success: Hsla,
    pub success_text: Hsla,
    pub recording: Hsla,
    pub recording_text: Hsla,
    /// Due text of open work whose day has passed: the recording red's text
    /// colour. At least 4.5:1 on panels and pages in both appearances.
    pub overdue_text: Hsla,
    /// Due text of open work due within the week: the attention amber's text
    /// colour. At least 4.5:1 on panels and pages in both appearances.
    pub due_soon_text: Hsla,
    pub speakers: [Hsla; 8],
}

impl Palette {
    pub fn light() -> Self {
        Self {
            dark: false,
            window: rgb(0xFFFFFF).into(),
            sidebar: rgb(0xF2F2F3).into(),
            sidebar_selection: rgba(0x0000_0014).into(),
            title_bar: rgb(0xFFFFFF).into(),
            elevated: rgb(0xFFFFFF).into(),
            text: rgb(0x1D1D1F).into(),
            text_secondary: rgba(0x0000_008C).into(),
            text_tertiary: rgba(0x0000_005A).into(),
            supporting: rgb(0x575757).into(),
            separator: rgba(0x0000_001A).into(),
            group_fill: rgba(0x0000_0009).into(),
            group_stroke: rgba(0x0000_0012).into(),
            chip_fill: rgba(0x0000_000F).into(),
            quiet_fill: rgba(0x0000_000F).into(),
            page: rgb(0xF6F6F6).into(),
            panel: rgb(0xFFFFFF).into(),
            hover: rgba(0x0000_000A).into(),
            accent_fill: rgb(0x0C8275).into(),
            accent_fill_hover: rgb(0x0A7166).into(),
            accent_text: rgb(0x075F55).into(),
            accent_wash: rgba(0x0C82_751F).into(),
            attention: rgb(0xFF9500).into(),
            attention_text: rgb(0x984C00).into(),
            success: rgb(0x28CD41).into(),
            success_text: rgb(0x176F2C).into(),
            recording: rgb(0xFF3B30).into(),
            recording_text: rgb(0xB60012).into(),
            overdue_text: rgb(0xB60012).into(),
            due_soon_text: rgb(0x984C00).into(),
            speakers: [
                rgb(0x075F55).into(),
                rgb(0x007AFF).into(),
                rgb(0xAF52DE).into(),
                rgb(0xFF2D55).into(),
                rgb(0xD9A400).into(),
                rgb(0x5856D6).into(),
                rgb(0xA2845E).into(),
                rgb(0x32ADE6).into(),
            ],
        }
    }

    pub fn dark() -> Self {
        Self {
            dark: true,
            window: rgb(0x1E1E1F).into(),
            sidebar: rgb(0x262628).into(),
            sidebar_selection: rgba(0xFFFF_FF1A).into(),
            title_bar: rgb(0x1E1E1F).into(),
            elevated: rgb(0x2A2A2C).into(),
            text: rgba(0xFFFF_FFE0).into(),
            text_secondary: rgba(0xFFFF_FF8C).into(),
            text_tertiary: rgba(0xFFFF_FF59).into(),
            supporting: rgb(0xC2C2C2).into(),
            separator: rgba(0xFFFF_FF1A).into(),
            group_fill: rgba(0xFFFF_FF0D).into(),
            group_stroke: rgba(0xFFFF_FF0F).into(),
            chip_fill: rgba(0xFFFF_FF14).into(),
            quiet_fill: rgba(0xFFFF_FF1A).into(),
            page: rgb(0x282828).into(),
            panel: rgb(0x1E1E1F).into(),
            hover: rgba(0xFFFF_FF0F).into(),
            accent_fill: rgb(0x0C8275).into(),
            accent_fill_hover: rgb(0x0E9384).into(),
            accent_text: rgb(0x6EF2DC).into(),
            accent_wash: rgba(0x6EF2_DC24).into(),
            attention: rgb(0xFF9F0A).into(),
            attention_text: rgb(0xFFB84D).into(),
            success: rgb(0x30D158).into(),
            success_text: rgb(0x4BDC71).into(),
            recording: rgb(0xFF453A).into(),
            recording_text: rgb(0xFF9C95).into(),
            overdue_text: rgb(0xFF9C95).into(),
            due_soon_text: rgb(0xFFB84D).into(),
            speakers: [
                rgb(0x6EF2DC).into(),
                rgb(0x0A84FF).into(),
                rgb(0xBF5AF2).into(),
                rgb(0xFF375F).into(),
                rgb(0xFFD60A).into(),
                rgb(0x5E5CE6).into(),
                rgb(0xAC8E68).into(),
                rgb(0x64D2FF).into(),
            ],
        }
    }

    /// Speakers in order of first appearance; index 0 is always "You".
    pub fn speaker(&self, index: usize) -> Hsla {
        self.speakers[index % self.speakers.len()]
    }

    /// A stable color per app name: djb2 hue, saturation 0.55, brightness 0.78.
    pub fn app_color(&self, app: &str) -> Hsla {
        let mut hash: u32 = 5381;
        for byte in app.bytes() {
            hash = hash.wrapping_mul(33).wrapping_add(u32::from(byte));
        }
        hsv(f32::from((hash % 360) as u16) / 360.0, 0.55, 0.78)
    }

    /// Status surfaces: the tint at 10% with a 28% stroke.
    pub fn status_fill(&self, tint: Hsla) -> Hsla {
        tint.opacity(0.10)
    }

    pub fn status_stroke(&self, tint: Hsla) -> Hsla {
        tint.opacity(0.28)
    }
}

fn hsv(h: f32, s: f32, v: f32) -> Hsla {
    let l = v * (1.0 - s / 2.0);
    let sl = if l == 0.0 || l == 1.0 {
        0.0
    } else {
        (v - l) / l.min(1.0 - l)
    };
    hsla(h, sl, l, 1.0)
}

/// The active palette, stored as a GPUI global.
pub struct LbTheme(pub Palette);

impl Global for LbTheme {}

pub trait LbThemeExt {
    fn lb(&self) -> &Palette;
}

impl LbThemeExt for App {
    fn lb(&self) -> &Palette {
        &self.global::<LbTheme>().0
    }
}

/// Type scale in logical pixels: the macOS sizes scaled by 14/13 for the
/// larger default text on Linux and Windows.
pub mod ty {
    use gpui_kit::{Pixels, px};

    pub const PAGE_TITLE: Pixels = px(28.);
    pub const QUESTION: Pixels = px(18.);
    pub const COLUMN_TITLE: Pixels = px(16.);
    pub const SECTION: Pixels = px(14.);
    pub const BODY: Pixels = px(14.);
    pub const READING: Pixels = px(15.);
    pub const SECONDARY: Pixels = px(13.);
    pub const CAPTION: Pixels = px(12.);
    pub const SIDEBAR_SECTION: Pixels = px(12.);
    pub const SMALL: Pixels = px(11.);
    /// A section panel's title: one step above the section heading.
    pub const PANEL_TITLE: Pixels = px(15.);
    /// Count and status pills, band and group labels inside a panel.
    pub const PILL: Pixels = px(12.);
    /// The toolbar's second line under the page title ("2 open", a date).
    pub const TOOLBAR_SUBTITLE: Pixels = px(12.);
}

/// Layout metrics (`LBTokens.Metric`).
pub mod metric {
    use gpui_kit::{Pixels, px};

    pub const SIDEBAR_WIDTH: Pixels = px(224.);
    pub const CONTENT_COLUMN_WIDTH: Pixels = px(280.);
    pub const SETTINGS_CATEGORIES_WIDTH: Pixels = px(240.);
    pub const DETAIL_PADDING: Pixels = px(28.);
    pub const SECTION_SPACING: Pixels = px(22.);
    pub const HEADER_TO_CONTENT: Pixels = px(8.);
    pub const PANEL_PADDING: Pixels = px(14.);
    pub const GROUP_RADIUS: Pixels = px(10.);
    pub const ROW_RADIUS: Pixels = px(8.);
    pub const SIDEBAR_ROW_HEIGHT: Pixels = px(32.);
    pub const TOOLBAR_HEIGHT: Pixels = px(52.);
    pub const READING_MAX_WIDTH: Pixels = px(720.);
    pub const COMPOSER_RADIUS: Pixels = px(18.);
    pub const ACTION_TOGGLE: Pixels = px(18.);
    /// Section panels (`SectionPanelMetric`): the inset between a panel's
    /// edge and its text, and the heights of its strips.
    pub const PANEL_INSET: Pixels = px(16.);
    pub const PANEL_HEADER_HEIGHT: Pixels = px(46.);
    pub const PANEL_FOOTER_HEIGHT: Pixels = px(38.);
    pub const PANEL_BAND_HEIGHT: Pixels = px(30.);
    /// Space between panels on a page.
    pub const PANEL_SPACING: Pixels = px(16.);
    /// An action row's padding above and below (`rowVerticalPadding`).
    pub const ROW_VERTICAL_PADDING: Pixels = px(10.);
}

/// The interface font: Geist (Vercel with basement.studio, SIL OFL 1.1), the
/// open family that Claude Desktop's Anthropic Sans credits ("BSPK x Geist x
/// Anthropic"). Anthropic's own fonts have no license to ship.
/// Geist draws the letters of every interface language but Hausa's hooked
/// ɓ ɗ ƙ, so a Hausa interface stays on Inter.
pub const FONT_FAMILY: &str = "Geist";
/// What Geist lacks, such as Hausa's letters and the ⌘ ⌥ ⌃ key symbols.
pub const FALLBACK_FONT_FAMILY: &str = "Inter";
/// Code, paths, logs and commands.
pub const MONO_FONT_FAMILY: &str = "Geist Mono";

/// The interface font for the current interface language.
pub fn font_family() -> &'static str {
    font_family_for(lokalbot_i18n::current().code)
}

fn font_family_for(language: &str) -> &'static str {
    if language == "ha" {
        FALLBACK_FONT_FAMILY
    } else {
        FONT_FAMILY
    }
}

/// Sets a window's root to the interface font, with Inter for what it lacks.
/// Everything inside inherits both.
pub trait UiFont: Styled + Sized {
    fn ui_font(mut self) -> Self {
        let style = self.text_style();
        style.font_family = Some(font_family().into());
        style.font_fallbacks = Some(FontFallbacks::from_fonts(vec![
            FALLBACK_FONT_FAMILY.to_string(),
        ]));
        self
    }
}

impl<T: Styled> UiFont for T {}

/// Gives GPUI Kit's own components the fonts for the current language.
pub fn apply_fonts(theme: &mut Theme) {
    theme.font_family = font_family().into();
    theme.mono_font_family = MONO_FONT_FAMILY.into();
}

/// Resolves the user's theme choice against the system appearance.
pub fn is_dark(choice: AppTheme, appearance: WindowAppearance) -> bool {
    match choice {
        AppTheme::Light => false,
        AppTheme::Dark => true,
        AppTheme::System => matches!(
            appearance,
            WindowAppearance::Dark | WindowAppearance::VibrantDark
        ),
    }
}

/// Installs the palette and themes GPUI Kit's components to match.
pub fn apply(dark: bool, text_scale: f32, window: Option<&mut Window>, cx: &mut App) {
    let palette = if dark {
        Palette::dark()
    } else {
        Palette::light()
    };
    Theme::change(
        if dark {
            ThemeMode::Dark
        } else {
            ThemeMode::Light
        },
        window,
        cx,
    );
    // `Theme::update` reconciles the component tokens (buttons, tabs, sidebar)
    // with these colors; editing through `global_mut` alone leaves them stale.
    Theme::update(cx, |theme| {
        apply_fonts(theme);
        theme.font_size = px(14. * text_scale);
        theme.radius = px(8.);
        theme.radius_lg = px(10.);
        theme.shadow = false;
        let c = &mut theme.colors;
        c.background = palette.window;
        c.foreground = palette.text;
        c.muted = palette.group_fill;
        c.muted_foreground = palette.text_secondary;
        c.border = palette.separator;
        c.input = palette.separator.opacity(if dark { 1.4 } else { 1.6 });
        c.ring = palette.accent_fill.opacity(0.6);
        c.caret = palette.accent_fill;
        c.selection = palette.accent_fill.opacity(0.28);
        c.primary = palette.accent_fill;
        c.primary_hover = palette.accent_fill_hover;
        c.primary_active = palette.accent_fill_hover;
        c.primary_foreground = rgb(0xFFFFFF).into();
        c.button_primary = palette.accent_fill;
        c.button_primary_hover = palette.accent_fill_hover;
        c.button_primary_active = palette.accent_fill_hover;
        c.button_primary_foreground = rgb(0xFFFFFF).into();
        c.secondary = palette.chip_fill;
        c.secondary_hover = palette.hover.opacity(1.8);
        c.secondary_active = palette.hover.opacity(2.4);
        c.secondary_foreground = palette.text;
        c.button_secondary = palette.chip_fill;
        c.button_secondary_hover = palette.chip_fill.opacity(1.7);
        c.button_secondary_active = palette.chip_fill.opacity(2.3);
        c.button_secondary_foreground = palette.accent_text;
        c.accent = palette.hover;
        c.accent_foreground = palette.text;
        c.link = palette.accent_text;
        c.link_hover = palette.accent_text.opacity(0.85);
        c.link_active = palette.accent_text;
        c.switch = palette.chip_fill.opacity(2.0);
        c.switch_thumb = rgb(0xFFFFFF).into();
        c.list = palette.window;
        c.list_hover = palette.hover;
        c.list_active = palette.accent_wash;
        c.list_active_border = palette.accent_fill.opacity(0.0);
        c.popover = palette.elevated;
        c.popover_foreground = palette.text;
        c.sidebar = palette.sidebar;
        c.sidebar_foreground = palette.text;
        c.sidebar_accent = palette.sidebar_selection;
        c.sidebar_accent_foreground = palette.text;
        c.sidebar_border = palette.separator;
        c.sidebar_primary = palette.accent_fill;
        c.sidebar_primary_foreground = rgb(0xFFFFFF).into();
        c.title_bar = palette.title_bar;
        c.title_bar_border = palette.separator;
        c.tab_bar = palette.chip_fill;
        c.tab_bar_segmented = palette.chip_fill;
        c.tab = gpui_kit::transparent_black();
        c.tab_active = palette.accent_fill;
        c.tab_active_foreground = rgb(0xFFFFFF).into();
        c.tab_foreground = palette.text;
        c.danger = palette.recording;
        c.warning = palette.attention;
        c.success = palette.success;
        c.progress_bar = palette.accent_fill;
        c.slider_bar = palette.accent_fill;
        c.slider_thumb = rgb(0xFFFFFF).into();
        c.scrollbar_thumb = palette.text_tertiary.opacity(0.6);
        c.scrollbar_thumb_hover = palette.text_tertiary;
        c.window_border = palette.separator;
    });
    cx.set_global(LbTheme(palette));
    cx.refresh_windows();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `color` drawn over the opaque `background`, as linear sRGB luminance.
    fn luminance(color: Hsla, background: Hsla) -> f32 {
        let top = gpui_kit::Rgba::from(color);
        let base = gpui_kit::Rgba::from(background);
        let channel = |c: f32, b: f32| {
            let v = c * top.a + b * (1.0 - top.a);
            if v <= 0.03928 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * channel(top.r, base.r)
            + 0.7152 * channel(top.g, base.g)
            + 0.0722 * channel(top.b, base.b)
    }

    fn contrast(text: Hsla, background: Hsla) -> f32 {
        let (a, b) = (
            luminance(text, background),
            luminance(background, background),
        );
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    /// Text on panels, their footer strips and the page stays readable.
    #[test]
    fn panel_text_colours_meet_four_and_a_half_to_one() {
        for palette in [Palette::light(), Palette::dark()] {
            let footer = {
                let fill = gpui_kit::Rgba::from(palette.group_fill);
                let base = gpui_kit::Rgba::from(palette.panel);
                let mix = |c: f32, b: f32| c * fill.a + b * (1.0 - fill.a);
                Hsla::from(gpui_kit::Rgba {
                    r: mix(fill.r, base.r),
                    g: mix(fill.g, base.g),
                    b: mix(fill.b, base.b),
                    a: 1.0,
                })
            };
            for (name, text) in [
                ("text", palette.text),
                ("supporting", palette.supporting),
                ("accent_text", palette.accent_text),
                ("overdue_text", palette.overdue_text),
                ("due_soon_text", palette.due_soon_text),
            ] {
                for (surface, background) in [
                    ("panel", palette.panel),
                    ("page", palette.page),
                    ("footer", footer),
                ] {
                    let ratio = contrast(text, background);
                    assert!(
                        ratio >= 4.5,
                        "{name} on {surface} (dark: {}) is {ratio:.2}:1",
                        palette.dark
                    );
                }
            }
        }
    }

    /// The page and its panels differ, so a panel reads as raised.
    #[test]
    fn panels_stand_apart_from_the_page() {
        for palette in [Palette::light(), Palette::dark()] {
            assert!(contrast(palette.panel, palette.page) > 1.05);
        }
    }

    #[test]
    fn hausa_keeps_inter_for_its_hooked_letters() {
        assert_eq!(font_family_for("ha"), "Inter");
        for language in lokalbot_i18n::LANGUAGES.iter().filter(|l| l.code != "ha") {
            assert_eq!(font_family_for(language.code), "Geist", "{}", language.code);
        }
    }
}
