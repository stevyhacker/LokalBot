//! "Remembered people" (`SpeakerVoiceProfileManager`): rename or forget the
//! encrypted voice profiles naming a speaker creates.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, IntoElement, ParentElement as _,
    Render, SharedString, Styled as _, Window, div, px,
};
use lokalbot_core::voice::VoiceProfile;
use uuid::Uuid;

use crate::i18n::h_flex;
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, ty};

struct Person {
    profile: VoiceProfile,
    name: Entity<InputState>,
}

pub(crate) struct RememberedPeople {
    data: Entity<AppData>,
    people: Vec<Person>,
    error: Option<SharedString>,
    busy: bool,
}

fn safe(name: &str) -> bool {
    lokalbot_core::voice::safe_name(name, &|text| lokalbot_ai::sanitize::redaction(text).1 > 0)
        .is_some()
}

impl RememberedPeople {
    pub(crate) fn open(data: Entity<AppData>, window: &mut Window, cx: &mut App) {
        let sheet = cx.new(|cx| {
            let mut this = Self {
                data,
                people: Vec::new(),
                error: None,
                busy: false,
            };
            this.reload(window, cx);
            this
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(520.)).close_button(false).child(sheet.clone())
        });
    }

    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(
                    async move { lokalbot_engine::voice::memory(&library).profiles() },
                )
                .await;
            let _ = this.update_in(cx, |this, window, cx| {
                match result {
                    Ok(profiles) => {
                        this.people = profiles
                            .into_iter()
                            .map(|profile| {
                                let name = cx.new(|cx| {
                                    InputState::new(window, cx)
                                        .placeholder(crate::i18n::placeholder(
                                            "Person's name",
                                            window,
                                            cx,
                                        ))
                                        .default_value(profile.name.clone())
                                });
                                cx.subscribe_in(
                                    &name,
                                    window,
                                    |_, _, event: &InputEvent, _, cx| {
                                        if let InputEvent::Change = event {
                                            cx.notify();
                                        }
                                    },
                                )
                                .detach();
                                Person { profile, name }
                            })
                            .collect();
                        this.error = None;
                    }
                    Err(err) => {
                        this.error = Some(
                            lokalbot_i18n::format(
                                "Could not read remembered people: {err}",
                                &[("err", err.to_string())],
                            )
                            .into(),
                        );
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn perform(
        &mut self,
        action: impl FnOnce(
            &lokalbot_core::voice::VoiceMemory,
        ) -> Result<(), lokalbot_core::voice::Failure>
        + Send
        + 'static,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.busy = true;
        cx.notify();
        let library = self.data.read(cx).library.clone();
        let data = self.data.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move { action(&lokalbot_engine::voice::memory(&library)) })
                .await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.busy = false;
                match result {
                    Ok(()) => {
                        this.error = None;
                        this.reload(window, cx);
                        data.update(cx, |data, cx| data.mark_library_changed(cx));
                    }
                    Err(err) => {
                        // A deletion that didn't happen must not read as done.
                        this.error = Some(
                            lokalbot_i18n::format(
                                "Change pending: {err}",
                                &[("err", err.to_string())],
                            )
                            .into(),
                        );
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn rename(&mut self, id: Uuid, name: String, window: &mut Window, cx: &mut Context<Self>) {
        self.perform(move |memory| memory.rename_profile(id, &name), window, cx);
    }

    fn forget(&mut self, id: Option<Uuid>, window: &mut Window, cx: &mut Context<Self>) {
        self.perform(move |memory| memory.forget_profile(id), window, cx);
    }

    fn render_person(&self, ix: usize, person: &Person, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let id = person.profile.id;
        let typed = person.name.read(cx).value().to_string();
        let changed = typed.trim() != person.profile.name && safe(&typed);
        let short: String = crate_id(&id).chars().take(6).collect();
        v_flex()
            .gap(px(6.))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(Input::new(&person.name).small()),
                    )
                    .child(
                        Button::new(("person-rename", ix))
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Rename"))
                            .disabled(!changed || self.busy)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                let name = this.people[ix].name.read(cx).value().to_string();
                                this.rename(id, name, window, cx);
                            })),
                    )
                    .child(
                        Button::new(("person-forget", ix))
                            .danger()
                            .small()
                            .label(lokalbot_i18n::tr("Forget"))
                            .disabled(self.busy)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.forget(Some(id), window, cx);
                            })),
                    ),
            )
            .child(
                div()
                    .text_size(ty::CAPTION)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::format(
                        "{count} confirmed recording(s) · Profile {id}",
                        &[
                            ("count", person.profile.contributions.len().to_string()),
                            ("id", short),
                        ],
                    )),
            )
            .into_any_element()
    }
}

fn crate_id(id: &Uuid) -> String {
    lokalbot_core::ids::uuid_upper(id)
}

impl Render for RememberedPeople {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let rows: Vec<AnyElement> = (0..self.people.len())
            .map(|ix| {
                // Split borrow: rendering a row reads only this person.
                let person = Person {
                    profile: self.people[ix].profile.clone(),
                    name: self.people[ix].name.clone(),
                };
                self.render_person(ix, &person, cx)
            })
            .collect();
        v_flex()
            .gap(px(16.))
            .child(
                div()
                    .text_size(ty::QUESTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(lokalbot_i18n::tr("Remembered people")),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Voice profiles stay on this computer. Forgetting a person removes their samples and identity links. Existing transcript names remain.",
                    ))),
            )
            .when(self.people.is_empty(), |this| {
                this.child(
                    div()
                        .py(px(8.))
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "No remembered voices yet. Confirm a speaker after a recording with enough clear speech.",
                        ))),
                )
            })
            .child(v_flex().gap(px(12.)).children(rows))
            .when_some(self.error.clone(), |this, error| {
                this.child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.attention_text)
                        .child(error),
                )
            })
            .child(
                h_flex()
                    .gap_2()
                    .child(
                        Button::new("people-clear")
                            .danger()
                            .label(lokalbot_i18n::tr("Clear all"))
                            .disabled(self.people.is_empty() || self.busy)
                            .on_click(cx.listener(|this, _, window, cx| this.forget(None, window, cx))),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("people-done")
                            .primary()
                            .label(lokalbot_i18n::tr("Done"))
                            .on_click(|_, window, cx| {
                                window.close_dialog(cx);
                            }),
                    ),
            )
    }
}
