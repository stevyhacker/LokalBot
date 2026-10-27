//! GPUI integration. A locale change redraws existing views and updates input
//! hints in place, retaining focus, drafts, selection and undo history.

use gpui_kit::component::input::{InputState, TextareaState};
use gpui_kit::{App, Context, Div, Global, SharedString, Styled as _, TextAlign, Window};
use lokalbot_i18n::tr;

pub struct InterfaceLocale;
impl Global for InterfaceLocale {}

pub fn apply(preference: &str, cx: &mut App) {
    let language = lokalbot_i18n::set_language(preference);
    crate::component_i18n::init();
    gpui_kit::component::set_locale(language.code);
    cx.set_global(InterfaceLocale);
    cx.refresh_windows();
}

pub trait LocalizedPlaceholder: Sized + 'static {
    fn update_placeholder(
        &mut self,
        text: SharedString,
        window: &mut Window,
        cx: &mut Context<Self>,
    );
}

impl LocalizedPlaceholder for InputState {
    fn update_placeholder(
        &mut self,
        text: SharedString,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.set_placeholder(text, window, cx);
    }
}

impl LocalizedPlaceholder for TextareaState {
    fn update_placeholder(
        &mut self,
        text: SharedString,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.set_placeholder(text, window, cx);
    }
}

pub fn placeholder<T: LocalizedPlaceholder>(
    key: &'static str,
    window: &mut Window,
    cx: &mut Context<T>,
) -> SharedString {
    cx.observe_global_in::<InterfaceLocale>(window, move |input, window, cx| {
        input.update_placeholder(tr(key).into(), window, cx);
    })
    .detach();
    tr(key).into()
}

pub fn language_picker(id: &'static str, cx: &App) -> impl gpui_kit::IntoElement {
    let data = crate::state::AppData::global(cx);
    let preference = data.read(cx).settings.app_language.clone();
    let mut codes = vec!["system"];
    codes.extend(lokalbot_i18n::LANGUAGES.iter().map(|l| l.code));
    let options = codes
        .iter()
        .map(|code| {
            (
                lokalbot_i18n::picker_label(code).to_string().into(),
                *code == preference,
            )
        })
        .collect();
    crate::ui::settings_row::picker(
        id,
        lokalbot_i18n::picker_label(&preference).to_string(),
        options,
        move |index, _, cx| {
            if let Some(code) = codes.get(index) {
                data.update(cx, |data, cx| {
                    data.update_settings(|s| s.app_language = (*code).into(), cx)
                });
            }
        },
    )
}

/// Mirror interface rows, while playback, charts and content retain their own
/// ordering. These controls opt out by using GPUI's original h_flex.
pub fn h_flex() -> Div {
    let row = gpui_kit::component::h_flex();
    if lokalbot_i18n::current().rtl {
        row.flex_row_reverse().text_align(TextAlign::Right)
    } else {
        row
    }
}

pub fn interface_alignment() -> TextAlign {
    if lokalbot_i18n::current().rtl {
        TextAlign::Right
    } else {
        TextAlign::Left
    }
}

pub fn content_alignment(text: &str) -> TextAlign {
    if lokalbot_i18n::content_is_rtl(text) {
        TextAlign::Right
    } else {
        TextAlign::Left
    }
}

pub fn compact_duration(seconds: f64) -> String {
    let minutes = (seconds / 60.0).floor() as u64;
    if minutes == 0 {
        tr("<1m").into()
    } else if minutes < 60 {
        lokalbot_i18n::format("{minutes}m", &[("minutes", minutes.to_string())])
    } else {
        lokalbot_i18n::format(
            "{hours}h {minutes}m",
            &[
                ("hours", (minutes / 60).to_string()),
                ("minutes", (minutes % 60).to_string()),
            ],
        )
    }
}
