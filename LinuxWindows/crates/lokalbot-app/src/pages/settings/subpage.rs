use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::{Icon, Sizable as _};
use gpui_kit::{
    AnyElement, App, FontWeight, IntoElement as _, ParentElement as _, SharedString, Styled as _,
    Window, div, px,
};

use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::Ico;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Subpage {
    AutocompleteProfile,
    AutocompleteExclusions,
    AutocompleteUsage,
    AutocompleteServer,
    DictationProfile,
    DictationRecent,
}

impl Subpage {
    pub const ALL: [Subpage; 6] = [
        Subpage::AutocompleteProfile,
        Subpage::AutocompleteExclusions,
        Subpage::AutocompleteUsage,
        Subpage::AutocompleteServer,
        Subpage::DictationProfile,
        Subpage::DictationRecent,
    ];

    pub fn page(self) -> SettingsCategory {
        match self {
            Subpage::AutocompleteProfile
            | Subpage::AutocompleteExclusions
            | Subpage::AutocompleteUsage
            | Subpage::AutocompleteServer => SettingsCategory::Writing,
            Subpage::DictationProfile | Subpage::DictationRecent => SettingsCategory::Dictation,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Subpage::AutocompleteProfile | Subpage::DictationProfile => "Writing profile",
            Subpage::AutocompleteExclusions => "Apps and sites to skip",
            Subpage::AutocompleteUsage => "Usage",
            Subpage::AutocompleteServer => "Where autocomplete runs",
            Subpage::DictationRecent => "Recent dictations",
        }
    }

    pub fn setting_ids(self) -> &'static [&'static str] {
        match self {
            Subpage::AutocompleteProfile => &[
                "settings.cotypingUserName",
                "settings.cotypingStyleNote",
                "settings.cotypingLanguages",
                "settings.cotypingExtendedContext",
                "settings.cotypingUseLocalLearning",
                "settings.cotypingLearningExamplesInPrompt",
                "settings.cotypingForgetLearned",
            ],
            Subpage::AutocompleteExclusions => &[
                "settings.cotypingExcludedApps",
                "settings.cotypingExcludedDomains",
                "settings.cotypingSuggestInIntegratedTerminals",
            ],
            Subpage::AutocompleteUsage => &["settings.autocompleteStatistics"],
            Subpage::AutocompleteServer => &["settings.cotypingBackend"],
            Subpage::DictationProfile => &["settings.dictationWritingProfile"],
            Subpage::DictationRecent => &[],
        }
    }

    pub fn containing(id: &str, page: SettingsCategory) -> Option<Subpage> {
        Self::ALL
            .into_iter()
            .find(|sub| sub.page() == page && sub.setting_ids().contains(&id))
    }
}

pub fn bar(
    id: &'static str,
    back: impl Into<SharedString>,
    title: impl Into<SharedString>,
    on_back: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let chevron = if lokalbot_i18n::current().rtl {
        Ico::ChevronRight
    } else {
        Ico::ChevronLeft
    };
    h_flex()
        .w_full()
        .gap(px(12.))
        .items_center()
        .child(
            Button::new(id)
                .outline()
                .small()
                .icon(Icon::new(chevron))
                .label(back.into())
                .on_click(move |_, window, cx| on_back(window, cx)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::SECTION)
                .font_weight(FontWeight::BOLD)
                .text_color(lb.text)
                .child(crate::ui::text::paragraph(title)),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_setting_opens_the_page_that_holds_it_on_its_own_page_only() {
        assert_eq!(
            Subpage::containing("settings.cotypingUserName", SettingsCategory::Writing),
            Some(Subpage::AutocompleteProfile)
        );
        assert_eq!(
            Subpage::containing(
                "settings.cotypingExcludedDomains",
                SettingsCategory::Writing
            ),
            Some(Subpage::AutocompleteExclusions)
        );
        assert_eq!(
            Subpage::containing("settings.cotypingBackend", SettingsCategory::Writing),
            Some(Subpage::AutocompleteServer)
        );
        assert_eq!(
            Subpage::containing("settings.cotypingMaxWords", SettingsCategory::Writing),
            None
        );
        assert_eq!(
            Subpage::containing("settings.cotypingUserName", SettingsCategory::Dictation),
            None
        );
    }

    #[test]
    fn every_page_belongs_to_one_settings_page_and_holds_its_own_settings() {
        for sub in Subpage::ALL {
            for id in sub.setting_ids() {
                assert_eq!(Subpage::containing(id, sub.page()), Some(sub), "{id}");
                assert!(
                    super::super::catalog::ENTRIES
                        .iter()
                        .any(|e| e.id == *id && e.category == sub.page()),
                    "{id} is a setting of {:?}",
                    sub.page()
                );
            }
        }
    }
}
