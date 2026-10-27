//! The follow-up draft (`FollowUpDraftSheet.swift`): review the outline
//! built from a meeting's outcomes, rewrite it with the local Think model,
//! copy it, or save it with the meeting. LokalBot never sends it.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState, Textarea, TextareaState};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, ClipboardItem, Context, Entity, FontWeight, IntoElement,
    ParentElement as _, Render, SharedString, Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::{FollowUpDraft, Meeting, MeetingOutcomes};

use crate::state::{AppData, AppEvent, FollowUpWriting};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

pub(crate) struct FollowUpSheet {
    data: Entity<AppData>,
    meeting: Meeting,
    outcomes: Option<MeetingOutcomes>,
    /// The saved draft, or the outline; edits are saved onto it.
    draft: Option<FollowUpDraft>,
    subject: Entity<InputState>,
    body: Entity<TextareaState>,
    /// This sheet asked Think for a draft and waits for the result.
    requested: bool,
    status: Option<SharedString>,
    error: Option<SharedString>,
    _subscriptions: Vec<Subscription>,
}

impl FollowUpSheet {
    /// Reads the outcomes and any saved draft off the UI thread, then opens
    /// the sheet.
    pub(crate) fn open(data: Entity<AppData>, meeting: Meeting, window: &mut Window, cx: &mut App) {
        let library = data.read(cx).library.clone();
        let loading = meeting.clone();
        window
            .spawn(cx, async move |cx| {
                let (outcomes, saved) = cx
                    .background_spawn(async move {
                        let outcomes = library.outcomes(&loading).ok().flatten();
                        let saved = library.follow_up_draft(&loading).unwrap_or_else(|err| {
                            log::warn!("follow-up draft for {}: {err:#}", loading.id);
                            None
                        });
                        (outcomes, saved)
                    })
                    .await;
                let _ =
                    cx.update(|window, cx| Self::show(data, meeting, outcomes, saved, window, cx));
            })
            .detach();
    }

    fn show(
        data: Entity<AppData>,
        meeting: Meeting,
        outcomes: Option<MeetingOutcomes>,
        saved: Option<FollowUpDraft>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let outcomes = outcomes.filter(|o| !o.is_empty());
        let draft = outcomes
            .as_ref()
            .map(|outcomes| saved.unwrap_or_else(|| FollowUpDraft::seeded(&meeting, outcomes)));
        let sheet = cx.new(|cx| {
            let subject_text = draft
                .as_ref()
                .map(|d| d.subject.clone())
                .unwrap_or_default();
            let body_text = draft.as_ref().map(|d| d.body.clone()).unwrap_or_default();
            let subject = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder("Subject", window, cx))
                    .default_value(subject_text)
            });
            let body = cx.new(|cx| {
                TextareaState::new(window, cx)
                    .rows(12)
                    .default_value(body_text)
            });
            let subscriptions =
                vec![
                    cx.observe_in(&data, window, |this: &mut Self, _, window, cx| {
                        this.apply_writing(window, cx)
                    }),
                ];
            // A rewrite started before the sheet was reopened still lands here.
            let requested = matches!(
                &data.read(cx).follow_up,
                Some((id, FollowUpWriting::Writing)) if *id == meeting.id
            );
            Self {
                data,
                meeting,
                outcomes,
                draft,
                subject,
                body,
                requested,
                status: None,
                error: None,
                _subscriptions: subscriptions,
            }
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(620.)).close_button(false).child(sheet.clone())
        });
    }

    fn writing(&self, cx: &App) -> bool {
        self.requested
            && matches!(
                &self.data.read(cx).follow_up,
                Some((id, FollowUpWriting::Writing)) if *id == self.meeting.id
            )
    }

    /// Applies a Think result meant for this meeting, once.
    fn apply_writing(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.requested {
            return;
        }
        let Some((id, writing)) = self.data.read(cx).follow_up.clone() else {
            return;
        };
        if id != self.meeting.id {
            return;
        }
        match writing {
            FollowUpWriting::Writing => {}
            FollowUpWriting::Written {
                subject,
                body,
                model,
            } => {
                self.requested = false;
                self.subject
                    .update(cx, |input, cx| input.set_value(subject, window, cx));
                self.body
                    .update(cx, |input, cx| input.set_value(body, window, cx));
                self.status = Some(
                    lokalbot_i18n::format(
                        "Written on this PC by {model}. Review before sending.",
                        &[("model", format!("{}", model))],
                    )
                    .into(),
                );
                self.error = None;
            }
            FollowUpWriting::Failed(message) => {
                self.requested = false;
                self.error = Some(message);
            }
        }
        cx.notify();
    }

    fn write(&mut self, cx: &mut Context<Self>) {
        self.requested = true;
        self.status = None;
        self.error = None;
        let id = self.meeting.id;
        self.data
            .update(cx, |data, cx| data.request(AppEvent::WriteFollowUp(id), cx));
        cx.notify();
    }

    fn reset(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(outcomes) = self.outcomes.as_ref() else {
            return;
        };
        let seeded = FollowUpDraft::seeded(&self.meeting, outcomes);
        self.subject
            .update(cx, |input, cx| input.set_value(seeded.subject, window, cx));
        self.body
            .update(cx, |input, cx| input.set_value(seeded.body, window, cx));
        self.status = Some(
            lokalbot_i18n::tr("Reset to the outline built from this meeting's outcomes.").into(),
        );
        self.error = None;
        cx.notify();
    }

    fn copy(&mut self, cx: &mut Context<Self>) {
        let subject = self.subject.read(cx).value();
        let body = self.body.read(cx).value();
        cx.write_to_clipboard(ClipboardItem::new_string(format!(
            "Subject: {subject}\n\n{body}"
        )));
        self.status = Some(lokalbot_i18n::tr("Copied.").into());
        cx.notify();
    }

    fn save(&mut self, cx: &mut Context<Self>) {
        let Some(mut draft) = self.draft.clone() else {
            return;
        };
        draft.subject = self.subject.read(cx).value().to_string();
        draft.body = self.body.read(cx).value().to_string();
        draft.seeded = false;
        draft.updated_at = lokalbot_core::time::now_millis();
        draft.source_meeting_id = Some(self.meeting.id);
        let library = self.data.read(cx).library.clone();
        let meeting = self.meeting.clone();
        let saving = draft.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { library.save_follow_up_draft(&meeting, &saving) })
                .await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(()) => {
                        this.draft = Some(draft);
                        this.status = Some(lokalbot_i18n::tr("Saved with this meeting.").into());
                        this.error = None;
                    }
                    Err(err) => {
                        this.error = Some(
                            lokalbot_i18n::format(
                                "The draft could not be saved. {err}",
                                &[("err", format!("{:#}", err))],
                            )
                            .into(),
                        )
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl Render for FollowUpSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let writing = self.writing(cx);
        let source = lokalbot_i18n::format(
            "From {0} · {1}",
            &[
                ("0", self.meeting.display_title().to_string()),
                (
                    "1",
                    format!(
                        "{}",
                        self.meeting
                            .started_at
                            .with_timezone(&chrono::Local)
                            .format_localized(
                                lokalbot_i18n::date_pattern("%b %-d, %Y"),
                                lokalbot_i18n::date_locale()
                            )
                    ),
                ),
            ],
        );
        let editor = self.draft.is_some().then(|| {
            v_flex()
                .gap(px(12.))
                .child(
                    h_flex()
                        .gap(px(12.))
                        .items_center()
                        .child(div().w(px(56.)).text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Subject"))))
                        .child(div().flex_1().child(Input::new(&self.subject))),
                )
                .child(ui::grouped_surface(cx).p(px(6.)).child(Textarea::new(&self.body).large().appearance(false).h(px(260.))))
                .child(
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .child(
                            ui::controls::bordered_icon(
                                "follow-up-write",
                                Ico::Sparkles,
                                if writing { lokalbot_i18n::tr("Writing…") } else { lokalbot_i18n::tr("Write with Think") },
                            )
                                .tooltip(lokalbot_i18n::tr("Rewrite this outline from the meeting's recap and outcomes with your on-device Think model"))
                                .disabled(writing)
                                .on_click(cx.listener(|this, _, _, cx| this.write(cx))),
                        )
                        .child(
                            ui::controls::bordered("follow-up-reset", lokalbot_i18n::tr("Reset to Outline"))
                                .disabled(writing)
                                .on_click(cx.listener(|this, _, window, cx| this.reset(window, cx))),
                        )
                        .child(div().flex_1())
                        .child(
                            ui::controls::bordered("follow-up-copy", lokalbot_i18n::tr("Copy"))
                                .on_click(cx.listener(|this, _, _, cx| this.copy(cx))),
                        )
                        .child(
                            Button::new("follow-up-save")
                                .primary()
                                .label(lokalbot_i18n::tr("Save Draft"))
                                .on_click(cx.listener(|this, _, _, cx| this.save(cx))),
                        ),
                )
                .when_some(self.status.clone(), |this, status| {
                    this.child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(status))
                })
                .when_some(self.error.clone(), |this, error| {
                    this.child(
                        h_flex()
                            .gap(px(6.))
                            .items_start()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text))
                            .child(div().flex_1().child(error)),
                    )
                })
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("LokalBot never sends this. Copy it into your mail or chat app to send it yourself."))),
                )
        });
        v_flex()
            .gap(px(14.))
            .child(
                v_flex()
                    .gap(px(4.))
                    .child(
                        div()
                            .text_size(ty::QUESTION)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Follow-up"))),
                    )
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.text_secondary)
                            .child(source),
                    ),
            )
            .when(editor.is_none(), |this| {
                this.child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "This meeting has no outcomes yet. Summarize it first.",
                        ))),
                )
            })
            .children(editor)
            .child(
                h_flex().justify_end().child(
                    ui::controls::bordered("follow-up-done", lokalbot_i18n::tr("Done"))
                        .on_click(|_, window, cx| window.close_dialog(cx)),
                ),
            )
    }
}
