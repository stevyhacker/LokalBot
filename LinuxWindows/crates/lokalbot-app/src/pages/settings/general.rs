//! General: startup, appearance, the Ask shortcut, updates and about.

use crate::i18n::h_flex;
use crate::updates;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{Context, IntoElement as _, ParentElement as _, SharedString, Styled as _, div, px};
use lokalbot_core::settings::{AppTheme, TextSize};

use super::{Section, SettingsPage, catalog};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{Ico, settings_row};

const THEMES: [AppTheme; 3] = [AppTheme::System, AppTheme::Light, AppTheme::Dark];
const SIZES: [TextSize; 5] = [
    TextSize::Small,
    TextSize::Standard,
    TextSize::Large,
    TextSize::Larger,
    TextSize::Largest,
];
pub const REPOSITORY: &str = "https://github.com/stevyhacker/LokalBot";

impl SettingsPage {
    pub(super) fn general_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let settings = self.data.read(cx).settings.clone();
        let data = self.data.clone();
        let theme_index = THEMES
            .iter()
            .position(|t| *t == settings.app_theme)
            .unwrap_or(0);
        let size_index = SIZES
            .iter()
            .position(|t| *t == settings.text_size)
            .unwrap_or(1);

        let general = Section::new(lokalbot_i18n::tr("General"))
            .row(
                "settings.launchAtLogin",
                self.toggle(
                    "settings.launchAtLogin",
                    lokalbot_i18n::tr("Launch LokalBot at login"),
                    Some(lokalbot_i18n::tr("Start automatically so it's ready to catch meetings.")),
                    settings.launch_at_login,
                    |s, v| s.launch_at_login = v,
                    cx,
                ),
            )
            .row(
                "settings.runInTray",
                self.toggle(
                    "settings.runInTray",
                    lokalbot_i18n::tr("Keep LokalBot running in the system tray"),
                    Some(lokalbot_i18n::tr("Closing the window keeps LokalBot running in the system tray, ready to catch meetings. Quit from the tray menu.")),
                    settings.run_in_tray,
                    |s, v| s.run_in_tray = v,
                    cx,
                ),
            );

        let theme_data = data.clone();
        let size_data = data.clone();
        let appearance = Section::new(lokalbot_i18n::tr("Appearance"))
            .row(
                "settings.appLanguage",
                settings_row::row(
                    "settings.appLanguage",
                    lokalbot_i18n::tr("App language"),
                    None,
                    crate::i18n::language_picker("settings-language", cx),
                    self.is_focused("settings.appLanguage"),
                    cx,
                ),
            )
            .row(
                "settings.appTheme",
                settings_row::row(
                    "settings.appTheme",
                    lokalbot_i18n::tr("Theme"),
                    Some(
                        lokalbot_i18n::tr("Use light or dark windows regardless of the system setting, or follow it.")
                            .into(),
                    ),
                    settings_row::segmented(
                        "settings-theme",
                        &THEMES.map(catalog::theme_label),
                        theme_index,
                        move |index, _, cx| {
                            let theme = THEMES[index];
                            theme_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.app_theme = theme, cx)
                            });
                        },
                        cx,
                    ),
                    self.is_focused("settings.appTheme"),
                    cx,
                ),
            )
            .row(
                "settings.textSize",
                settings_row::row(
                    "settings.textSize",
                    lokalbot_i18n::tr("Text size"),
                    Some(lokalbot_i18n::tr("Scales text across LokalBot's windows.").into()),
                    settings_row::segmented(
                        "settings-text-size",
                        &SIZES.map(catalog::text_size_label),
                        size_index,
                        move |index, _, cx| {
                            let size = SIZES[index];
                            size_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.text_size = size, cx)
                            });
                        },
                        cx,
                    ),
                    self.is_focused("settings.textSize"),
                    cx,
                ),
            )
            .row(
                "settings.textPreview",
                settings_row::content_row(
                    "settings.textPreview",
                    div()
                        .text_size(ty::BODY)
                        .text_color(cx.lb().text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Meeting notes, transcripts, and actions will look like this."))),
                    false,
                    cx,
                ),
            );

        let shortcut_help: SharedString = lokalbot_i18n::format("Press {0} in any app to search your work memory or ask a question. LokalBot registers only this shortcut and never reads other keystrokes.", &[("0", settings.quick_recall_shortcut.to_string())])
        .into();
        let shortcut_data = data.clone();
        let shortcut = Section::new(lokalbot_i18n::tr("Shortcut"))
            .row(
                "settings.quickRecallEnabled",
                settings_row::row(
                    "settings.quickRecallEnabled",
                    lokalbot_i18n::tr("Enable the system-wide Ask shortcut"),
                    Some(shortcut_help),
                    settings_row::switch(
                        "settings.quickRecallEnabled",
                        settings.quick_recall_enabled,
                        move |on, _, cx| {
                            shortcut_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.quick_recall_enabled = on, cx)
                            })
                        },
                    ),
                    self.is_focused("settings.quickRecallEnabled"),
                    cx,
                ),
            )
            .row(
                "settings.quickRecallShortcut",
                settings_row::row(
                    "settings.quickRecallShortcut",
                    lokalbot_i18n::tr("Ask shortcut"),
                    None,
                    self.quick_recall_shortcut.clone(),
                    self.is_focused("settings.quickRecallShortcut"),
                    cx,
                ),
            );

        let updates = self.updates_section(&settings, cx);
        let about = Section::new(lokalbot_i18n::tr("About"))
            .row(
                "settings.githubStar",
                settings_row::row(
                    "settings.githubStar",
                    lokalbot_i18n::tr("Open source"),
                    Some(
                        lokalbot_i18n::tr("LokalBot is free and built by one person. A GitHub star helps others find it.")
                            .into(),
                    ),
                    Button::new("settings-github-star")
                        .outline()
                        .small()
                        .icon(Icon::new(Ico::Star))
                        .label(lokalbot_i18n::tr("Star on GitHub"))
                        .on_click(|_, _, cx| cx.open_url(REPOSITORY))
                        .into_any_element(),
                    false,
                    cx,
                ),
            );

        vec![general, appearance, shortcut, updates, about]
    }

    /// Mirrors macOS Settings → General → Updates: the automatic-check
    /// switch, the version with Check for Updates…, and the update on offer.
    fn updates_section(
        &mut self,
        settings: &lokalbot_core::Settings,
        cx: &mut Context<Self>,
    ) -> Section {
        let Some(entity) = updates::global(cx) else {
            return Section::new(lokalbot_i18n::tr("Updates"));
        };
        let updates = entity.read(cx);
        let enabled = updates.enabled();
        let busy = updates.status.busy();
        let status = updates::status_text(updates);
        let offer = updates.status.release().cloned().map(|release| {
            (
                updates::offer_text(updates, &release),
                updates.route(&release),
                release,
            )
        });
        let mut section = Section::new(lokalbot_i18n::tr("Updates"));
        if enabled {
            section = section.row(
                "settings.checkForUpdates",
                self.toggle(
                    "settings.checkForUpdates",
                    lokalbot_i18n::tr("Check for updates automatically"),
                    Some(lokalbot_i18n::tr("Checks GitHub when LokalBot starts and once a day. Nothing is downloaded until you choose to install.")),
                    settings.check_for_updates,
                    |s, v| s.check_for_updates = v,
                    cx,
                ),
            );
        }
        let check = entity.clone();
        section = section.row(
            "settings.currentVersion",
            settings_row::row(
                "settings.currentVersion",
                lokalbot_i18n::tr("Current version"),
                Some(status),
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(settings_row::value(env!("CARGO_PKG_VERSION"), cx))
                    .when(enabled, |row| {
                        row.child(
                            Button::new("settings-check-updates")
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Check for Updates…"))
                                .disabled(busy)
                                .on_click(move |_, _, cx| {
                                    check.update(cx, |updates, cx| updates.check(true, cx))
                                }),
                        )
                    })
                    .child(settings_row::link_button(
                        "settings-releases",
                        lokalbot_i18n::tr("Releases"),
                        |_, cx| cx.open_url(&format!("{REPOSITORY}/releases")),
                        cx,
                    )),
                self.is_focused("settings.currentVersion"),
                cx,
            ),
        );
        if let Some((help, route, release)) = offer {
            let install = entity.clone();
            let notes = release.feed.release_notes_url.clone();
            // A package manager's copy has nothing to download here.
            let action = match route {
                updates::Route::Install => Some(
                    Button::new("settings-install-update")
                        .primary()
                        .small()
                        .label(lokalbot_i18n::tr("Install and Relaunch"))
                        .disabled(busy)
                        .on_click(move |_, _, cx| {
                            install.update(cx, |updates, cx| updates.install(cx))
                        }),
                ),
                updates::Route::Download => Some(
                    Button::new("settings-download-update")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Download"))
                        .on_click(|_, _, cx| updates::open_release_page(cx)),
                ),
                updates::Route::PackageManager => None,
            };
            section = section.row(
                "settings.updateAvailable",
                settings_row::row(
                    "settings.updateAvailable",
                    lokalbot_i18n::format(
                        "LokalBot {version} is available",
                        &[("version", release.version.to_string())],
                    ),
                    Some(help),
                    h_flex().gap(px(10.)).items_center().children(action).child(
                        settings_row::link_button(
                            "settings-release-notes",
                            lokalbot_i18n::tr("Release Notes"),
                            move |_, cx| cx.open_url(&notes),
                            cx,
                        ),
                    ),
                    self.is_focused("settings.updateAvailable"),
                    cx,
                ),
            );
        }
        section
    }
}
