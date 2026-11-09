//! Speaker review inside Name Speaker (`SpeakerIdentityReview`) and the
//! "Recognized voices" line. Evidence stays out of the transcript model and
//! its search and export paths; only names a person accepts reach them.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, IntoElement, ParentElement as _, Styled as _,
    Window, div, px,
};
use lokalbot_core::voice::{Choice, DecisionAction, NameMatch};

use super::MeetingsPage;
use super::dialogs::NameSpeakerSheet;
use super::model::MeetingDoc;
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

/// `SpeakerNameMatch.explanation`.
fn explanation(found: &NameMatch) -> String {
    lokalbot_i18n::format(
        "Matched a remembered voice across {count} speaking turns",
        &[("count", found.independent_turns.to_string())],
    )
}

impl NameSpeakerSheet {
    fn heading(text: &'static str, cx: &Context<Self>) -> impl IntoElement + use<> {
        div()
            .text_size(ty::SECONDARY)
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(cx.lb().text)
            .child(lokalbot_i18n::tr(text))
    }

    fn caption(text: String, cx: &Context<Self>) -> impl IntoElement + use<> {
        div()
            .text_size(ty::CAPTION)
            .text_color(cx.lb().text_secondary)
            .child(crate::ui::text::paragraph(text))
    }

    fn play_button(
        &self,
        id: (&'static str, usize),
        label: &'static str,
        seconds: f64,
        cx: &mut Context<Self>,
    ) -> Button {
        let page = self.page.clone();
        Button::new(id)
            .outline()
            .small()
            .label(lokalbot_i18n::tr(label))
            .on_click(cx.listener(move |_, _, _, cx| {
                let _ = page.update(cx, |page, cx| page.play_excerpt(seconds, seconds + 12., cx));
            }))
    }

    fn act(
        &mut self,
        action: DecisionAction,
        name: Option<String>,
        profile_id: Option<uuid::Uuid>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mut choice = Choice::new(self.speaker_key(), name, action);
        choice.profile_id = profile_id;
        choice.expected_revision = self.identity.as_ref().map(|state| state.revision);
        self.perform(choice, window, cx);
    }

    pub(super) fn render_identity_review(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let speaker = self.speaker_key().to_string();
        let identity = self.identity.clone();
        let assignment = identity
            .as_ref()
            .and_then(|state| state.assignment(&speaker).cloned());
        let (can_confirm, microphone_is_user) = self.speaker_identity_facts();
        let mut out = v_flex().gap(px(8.));

        if can_confirm {
            let description = match assignment.as_ref().and_then(|a| a.is_local_user) {
                Some(true) => "Confirmed as you",
                Some(false) => "Confirmed as someone else",
                None if microphone_is_user => "Attributed to you from your microphone",
                None => "Confirm who is speaking",
            };
            let start = assignment
                .as_ref()
                .and_then(|a| a.anchors.first())
                .map(|anchor| anchor.start);
            out = out.child(Self::heading(description, cx)).child(
                h_flex()
                    .gap(px(8.))
                    .when_some(start, |row, start| {
                        row.child(self.play_button(
                            ("speaker-play-speech", 0),
                            "Play Speech",
                            start,
                            cx,
                        ))
                    })
                    .child(
                        Button::new("speaker-this-is-me")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("This Is Me"))
                            .disabled(self.busy)
                            .on_click(cx.listener(|this, _, window, cx| {
                                let name = this.typed_name(cx);
                                let profile = this.profile_id;
                                this.act(DecisionAction::ConfirmUser, name, profile, window, cx);
                            })),
                    )
                    .child(
                        Button::new("speaker-someone-else")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Someone Else"))
                            .disabled(self.busy)
                            .on_click(cx.listener(|this, _, window, cx| {
                                let name = this.typed_name(cx);
                                let profile = this.profile_id;
                                this.act(DecisionAction::ConfirmOther, name, profile, window, cx);
                            })),
                    ),
            );
        } else {
            out = out.child(Self::caption(
                lokalbot_i18n::tr("This audio mixes voices, so it can't be confirmed as one person. You can still name it.").to_string(),
                cx,
            ));
        }

        if let Some(assignment) = &assignment {
            if let Some(found) = assignment
                .matched
                .clone()
                .filter(|_| !assignment.origin.is_protected())
            {
                let current = assignment.name.clone();
                let start = found.evidence.first().map(|anchor| anchor.start);
                out = out
                    .child(Self::heading("Automatically identified", cx))
                    .child(Self::caption(explanation(&found), cx))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .when_some(start, |row, start| {
                                row.child(self.play_button(
                                    ("speaker-play-support", 0),
                                    "Play supporting speech",
                                    start,
                                    cx,
                                ))
                            })
                            .child(
                                Button::new("speaker-undo")
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Undo"))
                                    .disabled(self.busy)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.act(
                                            DecisionAction::Undo,
                                            current.clone(),
                                            None,
                                            window,
                                            cx,
                                        );
                                    })),
                            ),
                    );
            }
            if assignment.automatic_disabled {
                out = out
                    .child(Self::caption(
                        if lokalbot_engine::voice::NAME_SPEAKERS_AUTOMATICALLY {
                            lokalbot_i18n::tr("Automatic naming is paused for this speaker.")
                        } else {
                            lokalbot_i18n::tr("Voice suggestions are paused for this speaker.")
                        }
                        .to_string(),
                        cx,
                    ))
                    .child(
                        h_flex().child(
                            Button::new("speaker-resume")
                                .outline()
                                .small()
                                .label(if lokalbot_engine::voice::NAME_SPEAKERS_AUTOMATICALLY {
                                    lokalbot_i18n::tr("Resume automatic identification")
                                } else {
                                    lokalbot_i18n::tr("Resume suggestions")
                                })
                                .disabled(self.busy)
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.act(DecisionAction::Resume, None, None, window, cx);
                                })),
                        ),
                    );
            }
        }

        let protected = assignment.as_ref().is_some_and(|a| a.origin.is_protected());
        let candidates = identity
            .as_ref()
            .and_then(|state| state.suggestions.get(&speaker).cloned())
            .unwrap_or_default();
        if !candidates.is_empty() && !protected {
            out = out.child(Self::heading("Suggested Names", cx));
            for (ix, candidate) in candidates.into_iter().enumerate() {
                let name = candidate.name.clone();
                let profile = candidate.profile_id;
                let dismiss = candidate.name.clone();
                let start = candidate.evidence.first().map(|anchor| anchor.start);
                out = out.child(
                    v_flex()
                        .gap(px(4.))
                        .p(px(10.))
                        .rounded(px(10.))
                        .bg(cx.lb().group_fill)
                        .border_1()
                        .border_color(cx.lb().group_stroke)
                        .child(
                            h_flex()
                                .gap(px(8.))
                                .items_center()
                                .child(
                                    Button::new(("speaker-suggested", ix))
                                        .ghost()
                                        .small()
                                        .label(candidate.name.clone())
                                        .on_click(cx.listener(move |this, _, window, cx| {
                                            this.fill_name(name.clone(), profile, window, cx);
                                        })),
                                )
                                .child(div().flex_1())
                                .when_some(start, |row, start| {
                                    row.child(self.play_button(
                                        ("speaker-suggested-play", ix),
                                        "Play",
                                        start,
                                        cx,
                                    ))
                                })
                                .child(
                                    Button::new(("speaker-suggested-dismiss", ix))
                                        .ghost()
                                        .small()
                                        .label(lokalbot_i18n::tr("Dismiss"))
                                        .disabled(self.busy)
                                        .on_click(cx.listener(move |this, _, window, cx| {
                                            this.act(
                                                DecisionAction::Dismiss,
                                                Some(dismiss.clone()),
                                                None,
                                                window,
                                                cx,
                                            );
                                        })),
                                ),
                        )
                        .child(Self::caption(explanation(&candidate), cx)),
                );
            }
        }

        let previous: Vec<_> = identity
            .as_ref()
            .map(|state| {
                state
                    .assignments
                    .iter()
                    .filter(|a| a.is_unresolved_label() && a.name.is_some())
                    .take(6)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        if !previous.is_empty() {
            out = out
                .child(Self::heading("Previously named voices", cx))
                .child(Self::caption(
                    lokalbot_i18n::tr("Speaker separation changed. Play the saved speech before choosing a previous name for this speaker.").to_string(),
                    cx,
                ));
            for (ix, item) in previous.into_iter().enumerate() {
                let name = item.name.clone().unwrap_or_default();
                let start = item.anchors.first().map(|anchor| anchor.start);
                out = out.child(
                    h_flex()
                        .gap(px(8.))
                        .child(
                            Button::new(("speaker-previous", ix))
                                .ghost()
                                .small()
                                .label(name.clone())
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.fill_name(name.clone(), None, window, cx);
                                })),
                        )
                        .when_some(start, |row, start| {
                            row.child(self.play_button(
                                ("speaker-previous-play", ix),
                                "Play saved speech",
                                start,
                                cx,
                            ))
                        }),
                );
            }
        }

        if identity.as_ref().is_some_and(|state| state.revision > 0) {
            out = out
                .child(
                    h_flex().child(
                        Button::new("speaker-delete-evidence")
                            .ghost()
                            .small()
                            .label(lokalbot_i18n::tr("Delete meeting speaker evidence"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.delete_evidence(window, cx);
                            })),
                    ),
                )
                .child(Self::caption(
                    lokalbot_i18n::tr(
                        "Keeps your saved speaker names and remembered voice profiles.",
                    )
                    .to_string(),
                    cx,
                ));
        }
        out.into_any_element()
    }
}

impl MeetingsPage {
    /// Applies every recognized name as if the user named each speaker.
    pub(super) fn apply_recognized(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(doc) = self.doc.clone() else { return };
        let Some(transcript) = doc.transcript.clone() else {
            return;
        };
        if self.applying_names || doc.recognized.is_empty() {
            return;
        }
        self.applying_names = true;
        cx.notify();
        let recognized = doc.recognized.clone();
        let meeting = doc.meeting.clone();
        let library = self.data.read(cx).library.clone();
        let data = self.data.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_engine::voice::apply_recognized_names(
                        &library,
                        &meeting,
                        &transcript,
                        &recognized,
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.applying_names = false;
                data.update(cx, |data, cx| {
                    match result {
                        Ok(_) => data.request(crate::state::AppEvent::LearnSpeakerVoices, cx),
                        Err(err) => data.show_error(
                            lokalbot_i18n::format(
                                "Could not save speaker names: {err}",
                                &[("err", format!("{err:#}"))],
                            ),
                            cx,
                        ),
                    }
                    data.mark_library_changed(cx);
                });
                cx.notify();
            });
        })
        .detach();
    }

    /// "Recognized voices: Ana, Marko" with Apply Names. On these platforms a
    /// person always confirms a voice match, so this is how a name is applied.
    pub(super) fn render_recognized(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let names = doc
            .recognized
            .iter()
            .map(|(_, found)| found.name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        ui::status_surface(lb.accent_fill, cx)
            .px(px(12.))
            .py(px(10.))
            .flex()
            .items_center()
            .gap(px(10.))
            .child(ui::icon(Ico::Users, px(16.), lb.accent_text))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(lokalbot_i18n::format(
                        "Recognized voices: {names}",
                        &[("names", names)],
                    )),
            )
            .child(
                Button::new("apply-recognized")
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Apply Names"))
                    .disabled(self.applying_names)
                    .on_click(cx.listener(|this, _, window, cx| this.apply_recognized(window, cx))),
            )
            .into_any_element()
    }
}
