//! Extend the pinned GPUI component backend with the app's catalogs. This
//! covers the controls we use without vendoring or changing the UI dependency.

use std::borrow::Cow;
use std::sync::Once;

use rust_i18n::Backend;

const TEXT: &[(&str, &str)] = &[
    ("DatePicker.placeholder", "Select date"),
    ("DatePicker.time", "Time"),
    ("Select.placeholder", "Please select"),
    ("ComboBox.placeholder", "Please select"),
    ("ComboBox.search_placeholder", "Search..."),
    ("ComboBox.empty", "No results"),
    ("DropdownButton.more_options", "More options"),
    ("Dialog.ok", "OK"),
    ("Dialog.cancel", "Cancel"),
    ("List.search_placeholder", "Search..."),
    ("Input.Decrement", "Decrement"),
    ("Input.Increment", "Increment"),
    ("Input.Replace", "Replace"),
    ("Input.Replace All", "Replace All"),
    ("Input.Cut", "Cut"),
    ("Input.Copy", "Copy"),
    ("Input.Paste", "Paste"),
    ("Input.Select All", "Select All"),
    ("Input.Go to Definition", "Go to Definition"),
    ("Input.Show Code Actions", "Show Code Actions"),
];

struct ComponentTranslations;
static BACKEND: ComponentTranslations = ComponentTranslations;

pub fn init() {
    static INIT: Once = Once::new();
    INIT.call_once(|| gpui_kit::component::_rust_i18n_extend(&BACKEND, "LokalBot"));
}

impl Backend for ComponentTranslations {
    fn available_locales(&self) -> Vec<Cow<'_, str>> {
        lokalbot_i18n::LANGUAGES
            .iter()
            .map(|l| Cow::Borrowed(l.code))
            .collect()
    }

    fn translate(&self, locale: &str, key: &str) -> Option<Cow<'_, str>> {
        let key = key.strip_prefix("LokalBot.")?;
        if let Some((_, text)) = TEXT.iter().find(|(candidate, _)| *candidate == key) {
            return Some(Cow::Owned(
                lokalbot_i18n::translate(locale, text).to_string(),
            ));
        }
        let date_locale = lokalbot_i18n::date_locale_for(locale);
        if let Some(day) = key
            .strip_prefix("Calendar.week.")
            .and_then(|n| n.parse::<u32>().ok())
            .filter(|day| *day < 7)
        {
            let date = chrono::NaiveDate::from_ymd_opt(2026, 10, 18 + day)?;
            return Some(Cow::Owned(
                date.format_localized("%a", date_locale).to_string(),
            ));
        }
        if let Some(month) = key.strip_prefix("Calendar.month.") {
            for number in 1..=12 {
                let date = chrono::NaiveDate::from_ymd_opt(2026, number, 1)?;
                if date.format("%B").to_string() == month {
                    return Some(Cow::Owned(
                        date.format_localized("%B", date_locale).to_string(),
                    ));
                }
            }
        }
        None
    }

    fn messages_for_locale(&self, locale: &str) -> Option<Vec<(Cow<'_, str>, Cow<'_, str>)>> {
        Some(
            TEXT.iter()
                .map(|(key, text)| {
                    (
                        Cow::Owned(format!("LokalBot.{key}")),
                        Cow::Owned(lokalbot_i18n::translate(locale, text).to_string()),
                    )
                })
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framework_controls_use_app_translations() {
        init();
        assert_eq!(
            gpui_kit::component::_rust_i18n_translate("de", "Dialog.cancel"),
            "Abbrechen"
        );
        assert_eq!(
            gpui_kit::component::_rust_i18n_translate("de", "Calendar.month.October"),
            "Oktober"
        );
        assert_eq!(
            gpui_kit::component::_rust_i18n_translate("fr", "Calendar.week.1"),
            "lun."
        );
        // A dependency update must not silently add an untranslated control.
        for (key, value) in gpui_kit::component::_rust_i18n_backend()
            .messages_for_locale("en")
            .unwrap()
        {
            if TEXT
                .iter()
                .any(|(known, _)| known.split('.').next() == key.split('.').next())
            {
                assert!(
                    TEXT.iter()
                        .any(|(known, text)| *known == key && *text == value),
                    "New component text: {key} = {value}"
                );
            }
        }
    }
}
