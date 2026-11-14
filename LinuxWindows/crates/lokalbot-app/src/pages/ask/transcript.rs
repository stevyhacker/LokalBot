//! The conversation (`ChatTranscriptView`, `EditorialTurn`): each question
//! with its time, then the answer as flat text, one sources list that ends it,
//! and quiet actions; a failed answer keeps its matches. Also the questions an
//! empty page suggests.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash as _, Hasher as _};
use std::rc::Rc;

use crate::i18n::h_flex;
use chrono::{DateTime, Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Div, ElementId, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    Window, div, px, relative,
};
use lokalbot_core::{ChatActivity, ChatMessage, ChatRole, settings::SummarizerBackend};
use uuid::Uuid;

use super::AskPage;
use super::model::{self, SourceGroup, SourceKind, Suggestion, SuggestionKind};
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::answer_text::{self, Answer, AnswerStyle};
use crate::ui::citations::{self, CitationSource};
use crate::ui::{self, Ico, screen_thumbnail};

/// Read aloud as it applies to one answer.
struct AnswerSpeech {
    /// Reading this answer, or preparing to.
    reading: bool,
    preparing: bool,
    error: Option<SharedString>,
}

fn speech_key(id: Uuid) -> String {
    format!("answer:{id}")
}

fn answer_speech(id: Uuid, cx: &App) -> AnswerSpeech {
    let speech = &crate::state::AppData::global(cx).read(cx).speech;
    let key = speech_key(id);
    let reading = speech.reading.as_deref() == Some(key.as_str());
    AnswerSpeech {
        reading,
        preparing: reading && speech.preparing,
        error: speech
            .error
            .as_ref()
            .filter(|(failed, _)| *failed == key)
            .map(|(_, message)| lokalbot_i18n::tr(message).to_string().into()),
    }
}

fn toggle_answer_speech(id: Uuid, text: &str, cx: &mut App) {
    let speech = answer_speech(id, cx);
    let command = if speech.reading {
        lokalbot_engine::SpeechCommand::Stop
    } else {
        lokalbot_engine::SpeechCommand::Read {
            key: speech_key(id),
            text: text.to_string(),
        }
    };
    crate::bridge::send(lokalbot_engine::Command::Speech(command), cx);
}

/// The answer being read is leaving the screen (`ChatView.onDisappear`).
pub(crate) fn stop_answer_speech(cx: &mut App) {
    let speech = &crate::state::AppData::global(cx).read(cx).speech;
    if speech
        .reading
        .as_deref()
        .is_some_and(|key| key.starts_with("answer:"))
    {
        crate::bridge::send(
            lokalbot_engine::Command::Speech(lokalbot_engine::SpeechCommand::Stop),
            cx,
        );
    }
}

/// One step of tool activity.
#[derive(Clone)]
struct Step {
    text: String,
    done: bool,
}

/// One turn as shown on screen.
enum Turn {
    User {
        id: Uuid,
        text: String,
        created_at: Option<DateTime<Utc>>,
        divider: Option<String>,
        separator: bool,
        latest: bool,
        /// What it was limited to, for the time's tooltip.
        scope: Option<String>,
    },
    Assistant {
        id: Uuid,
        text: String,
        steps: Vec<Step>,
        pending: bool,
        status: Option<SharedString>,
        error: Option<SharedString>,
        can_retry: bool,
        can_ask_again: bool,
        receipt: Option<lokalbot_core::RememberReceipt>,
        used_claims: Vec<Uuid>,
        /// The question a failed last answer replied to: its matches stay.
        failed_question: Option<Box<ChatMessage>>,
    },
}

/// Id of the streamed answer before the engine saves it.
const STREAM_ID: Uuid = Uuid::from_u128(0x5a5a_0000_0000_4000_8000_0000_0000_0001);

impl AskPage {
    fn turns(&self, cx: &App) -> Vec<Turn> {
        let data = self.data.read(cx);
        let stream = data
            .ask_stream
            .as_ref()
            .filter(|s| Some(s.conversation_id) == self.selected);
        let messages = self
            .selected_conversation()
            .map(|c| c.messages.as_slice())
            .unwrap_or(&[]);
        let latest_user = if stream.is_some() {
            None
        } else {
            messages
                .iter()
                .rev()
                .find(|m| m.role == ChatRole::User)
                .map(|m| m.id)
        };
        let live_attachments = self
            .selected
            .is_some_and(|id| data.attached_asks.contains_key(&id));
        let responding = stream.is_some_and(|s| s.error.is_none());
        let offered = super::scope::Offered::new(&data.settings);
        let now = Local::now();
        let last_id = messages.last().map(|m| m.id);
        let mut turns = Vec::new();
        let mut previous_user: Option<Option<DateTime<Utc>>> = None;
        let mut previous_question: Option<&ChatMessage> = None;
        for (index, message) in messages.iter().enumerate() {
            // An older turn dated from its conversation shows no time.
            let created_at = message
                .created_at
                .filter(|_| !message.created_at_is_estimated);
            match message.role {
                ChatRole::User => {
                    let divider = model::visible_date_divider(created_at, previous_user, now);
                    turns.push(Turn::User {
                        id: message.id,
                        text: message.text.clone(),
                        created_at,
                        separator: index > 0 && divider.is_none(),
                        divider,
                        latest: Some(message.id) == latest_user,
                        scope: super::scope::question_scope_summary(message, offered),
                    });
                    previous_user = Some(created_at);
                    previous_question = Some(message);
                }
                ChatRole::Assistant => turns.push(Turn::Assistant {
                    id: message.id,
                    text: message.text.clone(),
                    steps: message.activity.iter().map(step).collect(),
                    pending: false,
                    status: None,
                    error: message.is_error.then(|| message.text.clone().into()),
                    can_retry: stream.is_none()
                        && lokalbot_core::can_retry(messages, message.id, live_attachments),
                    can_ask_again: !responding && model::ask_again(messages, message.id).is_some(),
                    receipt: message.remember_receipt.clone(),
                    used_claims: message.used_claim_ids.clone().unwrap_or_default(),
                    failed_question: (message.is_error
                        && Some(message.id) == last_id
                        && stream.is_none())
                    .then(|| previous_question.cloned().map(Box::new))
                    .flatten(),
                }),
            }
        }
        if let Some(stream) = stream {
            let saved_question = messages
                .last()
                .is_some_and(|m| m.role == ChatRole::User && m.text == stream.question);
            if !saved_question {
                let at = Utc::now();
                let divider = model::visible_date_divider(Some(at), previous_user, now);
                turns.push(Turn::User {
                    id: Uuid::from_u128(STREAM_ID.as_u128() + 1),
                    text: stream.question.clone(),
                    created_at: Some(at),
                    separator: !messages.is_empty() && divider.is_none(),
                    divider,
                    latest: true,
                    scope: None,
                });
            } else if let Some(Turn::User { latest, .. }) = turns.last_mut() {
                *latest = true;
            }
            let answering = stream.error.is_none();
            let count = stream.activity.len();
            turns.push(Turn::Assistant {
                id: STREAM_ID,
                text: stream.text.clone(),
                steps: stream
                    .activity
                    .iter()
                    .enumerate()
                    .map(|(i, text)| Step {
                        text: text.clone(),
                        done: !answering || i + 1 < count || !stream.text.is_empty(),
                    })
                    .collect(),
                pending: answering,
                receipt: None,
                used_claims: Vec::new(),
                status: stream.status.clone(),
                error: stream.error.clone(),
                can_retry: false,
                can_ask_again: false,
                failed_question: None,
            });
        }
        turns
    }

    /// The conversation, scrolled to its end while an answer streams. Quick
    /// Recall shows the same view for its one conversation.
    pub(crate) fn render_transcript(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let turns = self.turns(cx);
        let elements: Vec<AnyElement> = turns
            .into_iter()
            .map(|turn| match turn {
                Turn::User { .. } => self.render_user_turn(turn, cx).into_any_element(),
                Turn::Assistant { .. } => self.render_assistant_turn(turn, cx).into_any_element(),
            })
            .collect();
        let near_bottom = {
            let offset = self.transcript_scroll.offset();
            let max = self.transcript_scroll.max_offset();
            max.y + offset.y < px(96.)
        };
        let lb = cx.lb().clone();
        let passage = self.render_passage(cx);
        // The tray of matches covers the end of the conversation while typing.
        let near_bottom = near_bottom
            || (!self.embedded
                && self.ask_phase(cx).matches_placement()
                    == Some(super::model::MatchesPlacement::TrayAboveField));
        div()
            .relative()
            .size_full()
            .child(
                div()
                    .id("ask-transcript")
                    .size_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.transcript_scroll)
                    .on_scroll_wheel(cx.listener(|this, _, _, cx| {
                        let offset = this.transcript_scroll.offset();
                        let max = this.transcript_scroll.max_offset();
                        this.follow_stream = max.y + offset.y < px(96.);
                        cx.notify();
                    }))
                    .child(
                        v_flex().w_full().items_center().child(
                            v_flex()
                                .w_full()
                                .max_w(metric::READING_MAX_WIDTH)
                                .px(metric::DETAIL_PADDING)
                                .pt(px(20.))
                                .pb(metric::DETAIL_PADDING)
                                .gap(px(16.))
                                .children(elements),
                        ),
                    ),
            )
            .when(!near_bottom, |this| {
                this.child(
                    h_flex()
                        .absolute()
                        .bottom(px(16.))
                        .left_0()
                        .right_0()
                        .justify_center()
                        .child(
                            Button::new("ask-jump-latest")
                                .outline()
                                .small()
                                .icon(Icon::new(Ico::ArrowDown))
                                .label(lokalbot_i18n::tr("Jump to latest"))
                                .bg(lb.elevated)
                                .shadow_md()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.follow_stream = true;
                                    this.transcript_scroll.scroll_to_bottom();
                                    cx.notify();
                                })),
                        ),
                )
            })
            .children(passage)
    }

    /// The question in its own words, with the time it was asked. What it was
    /// limited to is in the time's tooltip; the composer's two menus are where
    /// scope is chosen.
    fn render_user_turn(&self, turn: Turn, cx: &mut Context<Self>) -> Div {
        let Turn::User {
            id,
            text,
            created_at,
            divider,
            separator,
            latest,
            scope,
        } = turn
        else {
            return div();
        };
        let lb = cx.lb().clone();
        let long = text.chars().count() > 180 || text.lines().count() > 3;
        let expanded = latest || self.turns.questions.contains(&id);
        let key = super::history::element_key(id);
        let time = created_at.map(|at| {
            at.with_timezone(&Local)
                .format_localized(
                    lokalbot_i18n::date_pattern("%-I:%M %p"),
                    lokalbot_i18n::date_locale(),
                )
                .to_string()
        });
        v_flex()
            .gap(px(12.))
            .when_some(divider, |this, title| {
                this.child(date_divider_row(title, cx))
            })
            .when(separator, |this| {
                this.child(div().pb(px(8.)).child(ui::divider(cx)))
            })
            .child(
                v_flex()
                    .gap(px(7.))
                    .child(
                        h_flex()
                            .w_full()
                            .gap(px(12.))
                            .items_start()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(ty::QUESTION)
                                    .line_height(px(25.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .when(!expanded, |this| this.line_clamp(3))
                                    .child(text),
                            )
                            .when_some(time, |this, time| {
                                let scope = scope.clone();
                                this.child(
                                    div()
                                        .id(("ask-question-time", key))
                                        .flex_none()
                                        .pt(px(3.))
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.supporting)
                                        .child(time)
                                        .when_some(scope, |this, scope| {
                                            this.tooltip(move |window, cx| {
                                                gpui_kit::component::tooltip::Tooltip::new(
                                                    scope.clone(),
                                                )
                                                .build(window, cx)
                                            })
                                        }),
                                )
                            }),
                    )
                    .when(long && !latest, |this| {
                        let label = if expanded {
                            lokalbot_i18n::tr("Show less")
                        } else {
                            lokalbot_i18n::tr("Show full question")
                        };
                        this.child(
                            div()
                                .id(("ask-question-toggle", key))
                                .cursor_pointer()
                                .text_size(ty::SECONDARY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.accent_text)
                                .hover(|s| s.underline())
                                .child(label)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if !this.turns.questions.remove(&id) {
                                        this.turns.questions.insert(id);
                                    }
                                    cx.notify();
                                })),
                        )
                    }),
            )
    }

    fn render_assistant_turn(&mut self, turn: Turn, cx: &mut Context<Self>) -> Div {
        let Turn::Assistant {
            id,
            text,
            steps,
            pending,
            status,
            error,
            can_retry,
            can_ask_again,
            receipt,
            used_claims,
            failed_question,
        } = turn
        else {
            return div();
        };
        if let Some(receipt) = &receipt {
            return self.render_remember_receipt(id, receipt, &text, cx);
        }
        let lb = cx.lb().clone();
        let stopped = {
            let normalized = text.trim().to_lowercase();
            normalized == "stopped." || normalized.starts_with("response stopped")
        };
        let answer = self.parsed_answer(id, &text);
        let mut column = v_flex().gap(px(12.)).w_full();

        if stopped {
            return column.child(self.status_card(
                id,
                lokalbot_i18n::tr("Response stopped"),
                None,
                Ico::CircleStop,
                lb.text_secondary,
                false,
                can_retry,
                cx,
            ));
        }
        if let Some(error) = error {
            column = column.child(self.status_card(
                id,
                lokalbot_i18n::tr("Couldn't answer"),
                Some(error),
                Ico::TriangleAlert,
                lb.attention_text,
                true,
                can_retry,
                cx,
            ));
            if let Some(question) = failed_question {
                column = column.children(self.render_failed_matches(id, &question, cx));
            }
            return column;
        }
        if steps.iter().any(|step| !step.done) {
            column = column.child(render_worked_line(&steps, cx));
        }
        if pending && text.trim().is_empty() {
            return column.child(self.render_preparation(status, cx));
        }
        if !answer.is_empty() {
            let page = cx.entity();
            let citations = answer.citations.clone();
            let on_cite: answer_text::CiteHandler = Rc::new(move |index, window, cx| {
                if let Some(source) = citations.get(index).cloned() {
                    page.update(cx, |page, cx| {
                        if pending {
                            page.open_citation(&source, cx)
                        } else {
                            page.toggle_passage(id, index + 1, source, window, cx)
                        }
                    });
                }
            });
            column = column.child(answer_text::render(
                ("ask-answer", super::history::element_key(id)),
                &answer,
                AnswerStyle::editorial(cx),
                on_cite,
                cx,
            ));
        }
        let speech = answer_speech(id, cx);
        if let Some(message) = speech.error.clone() {
            column = column.child(
                div()
                    .text_size(ty::CAPTION)
                    .text_color(cx.lb().attention_text)
                    .truncate()
                    .child(message),
            );
        }
        if pending {
            return column;
        }
        if !answer.citations.is_empty() {
            self.load_screen_citations(&answer.citations, cx);
            self.load_file_citations(&answer.citations, cx);
            self.load_note_citations(&answer.citations, cx);
        }
        if !answer.citations.is_empty() || !used_claims.is_empty() {
            column =
                column.child(self.render_sources_list(id, &answer.citations, &used_claims, cx));
        }
        let copy_text = citations::display_text(&text);
        column.child(self.render_answer_actions(id, copy_text, can_ask_again, speech, cx))
    }

    /// A short notice in place of an answer, with the way to fix it.
    #[allow(clippy::too_many_arguments)]
    fn status_card(
        &self,
        id: Uuid,
        title: &str,
        detail: Option<SharedString>,
        icon: Ico,
        tint: gpui_kit::Hsla,
        offers_model_settings: bool,
        can_retry: bool,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let key = super::history::element_key(id);
        let responding = self.is_responding(cx);
        h_flex()
            .w_full()
            .gap(px(10.))
            .items_center()
            .px(px(12.))
            .py(px(10.))
            .rounded(metric::GROUP_RADIUS)
            .bg(lb.panel)
            .border_1()
            .border_color(lb.group_stroke)
            .child(ui::icon(icon, px(16.), tint))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(1.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(title.to_string()),
                    )
                    .when_some(detail, |this, detail| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.supporting)
                                .child(ui::text::paragraph(detail)),
                        )
                    }),
            )
            .when(offers_model_settings, |this| {
                this.child(
                    Button::new(("ask-model-settings", key))
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Model settings"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.data.update(cx, |data, cx| {
                                data.open_settings(SettingsCategory::Models, cx)
                            })
                        })),
                )
            })
            .when(can_retry && !responding, |this| {
                this.child(
                    Button::new(("ask-retry", key))
                        .outline()
                        .small()
                        .icon(Icon::new(Ico::RotateCw))
                        .label(lokalbot_i18n::tr("Retry"))
                        .on_click(cx.listener(move |this, _, _, cx| this.retry(id, cx))),
                )
            })
    }

    /// Copy, read aloud and ask again: quiet icons, each named in its tooltip.
    fn render_answer_actions(
        &self,
        id: Uuid,
        copy_text: String,
        can_ask_again: bool,
        speech: AnswerSpeech,
        cx: &mut Context<Self>,
    ) -> Div {
        let key = super::history::element_key(id);
        let has_text = !copy_text.trim().is_empty();
        let copied = self.turns.copied == Some(id);
        let speech_text = copy_text.clone();
        h_flex()
            .gap(px(2.))
            .ml(px(-6.))
            .mt(px(-4.))
            .when(has_text, |this| {
                this.child(
                    Button::new(("ask-copy", key))
                        .ghost()
                        .small()
                        .icon(Icon::new(if copied { Ico::Check } else { Ico::Copy }))
                        .disabled(copied)
                        .tooltip(if copied {
                            lokalbot_i18n::tr("Copied")
                        } else {
                            lokalbot_i18n::tr("Copy this answer")
                        })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.copy_answer(id, copy_text.clone(), cx)
                        })),
                )
                .child(
                    Button::new(("ask-read-aloud", key))
                        .ghost()
                        .small()
                        .icon(Icon::new(if speech.preparing {
                            Ico::Hourglass
                        } else if speech.reading {
                            Ico::Square
                        } else {
                            Ico::Volume2
                        }))
                        .tooltip(if speech.reading {
                            lokalbot_i18n::tr("Stop reading aloud")
                        } else {
                            lokalbot_i18n::tr("Read aloud")
                        })
                        .on_click(cx.listener(move |_, _, _, cx| {
                            toggle_answer_speech(id, &speech_text, cx)
                        })),
                )
            })
            .when(can_ask_again, |this| {
                this.child(
                    Button::new(("ask-again", key))
                        .ghost()
                        .small()
                        .icon(Icon::new(Ico::RotateCw))
                        .tooltip(lokalbot_i18n::tr("Ask again"))
                        .on_click(cx.listener(move |this, _, _, cx| this.ask_again(id, cx))),
                )
            })
    }

    /// The list that ends an answer (`AnswerSourcesList`): a row per meeting,
    /// screen moment, file or note it cited, with the answer's numbers and
    /// times, and one row for what the person told LokalBot when that went into
    /// the answer. It replaces the Evidence disclosure.
    fn render_sources_list(
        &mut self,
        id: Uuid,
        sources: &[CitationSource],
        used_claims: &[Uuid],
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let meetings = self.data.read(cx).meetings.clone();
        let groups = model::source_groups(
            sources,
            |id| citations::resolve_meeting(id, &meetings).map(|m| m.id.to_string()),
            |file| {
                citations::known_file_citation(file)
                    .flatten()
                    .map(|hit| hit.path)
            },
        );
        let mut card = v_flex()
            .w_full()
            .rounded(metric::GROUP_RADIUS)
            .bg(lb.panel)
            .border_1()
            .border_color(lb.group_stroke)
            .overflow_hidden();
        let key = super::history::element_key(id);
        let mut first = true;
        for (index, group) in groups.iter().enumerate() {
            if !first {
                card = card.child(div().h(px(1.)).bg(lb.separator));
            }
            first = false;
            card = card.child(self.source_row(id, key, index, group, &meetings, cx));
        }
        if !used_claims.is_empty() {
            if !first {
                card = card.child(div().h(px(1.)).bg(lb.separator));
            }
            card = card.child(self.render_used_claims(id, used_claims, cx));
        }
        card
    }

    fn source_row(
        &self,
        answer: Uuid,
        key: u64,
        index: usize,
        group: &SourceGroup,
        meetings: &[lokalbot_core::Meeting],
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let now = Local::now();
        let first = group.first().clone();
        let (lead, title, meta, available) = match &first {
            CitationSource::Meeting { id, .. } => match citations::resolve_meeting(id, meetings) {
                Some(meeting) => (
                    super::matches::source_tile(Ico::AudioLines, px(32.), px(22.), &lb),
                    meeting.display_title(),
                    model::moment_label(meeting.started_at, now),
                    true,
                ),
                None => (
                    super::matches::source_tile(Ico::AudioLines, px(32.), px(22.), &lb),
                    lokalbot_i18n::tr("Meeting").to_string(),
                    lokalbot_i18n::tr("Unavailable").to_string(),
                    false,
                ),
            },
            CitationSource::Screen { snapshot_id } => {
                match self.screen_citations.get(snapshot_id) {
                    Some(Some(moment)) => {
                        let when = model::moment_label(moment.ts, now);
                        let titled = !moment.window_title.trim().is_empty();
                        let image = self.thumbnails.image(moment, cx, |page| &page.thumbnails);
                        (
                            screen_thumbnail::tile(image, moment, px(32.), px(22.), cx)
                                .rounded(px(5.))
                                .into_any_element(),
                            if titled {
                                moment.window_title.clone()
                            } else {
                                moment.app.clone()
                            },
                            if titled {
                                format!("{} · {when}", moment.app)
                            } else {
                                when
                            },
                            true,
                        )
                    }
                    known => (
                        super::matches::source_tile(Ico::Monitor, px(32.), px(22.), &lb),
                        lokalbot_i18n::tr("Screen").to_string(),
                        if known.is_some() {
                            lokalbot_i18n::tr("Unavailable").to_string()
                        } else {
                            String::new()
                        },
                        false,
                    ),
                }
            }
            CitationSource::File { id } => match citations::known_file_citation(*id) {
                Some(Some(hit)) => (
                    div()
                        .w(px(32.))
                        .h(px(22.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(ui::icon(
                            super::search::file_icon(hit.kind),
                            px(18.),
                            lb.text_secondary,
                        ))
                        .into_any_element(),
                    hit.name(),
                    hit.folder(),
                    true,
                ),
                known => (
                    super::matches::source_tile(Ico::File, px(32.), px(22.), &lb),
                    lokalbot_i18n::tr("Files").to_string(),
                    if known.is_some() {
                        lokalbot_i18n::tr("Unavailable").to_string()
                    } else {
                        String::new()
                    },
                    false,
                ),
            },
            CitationSource::Note { id } => match citations::known_note_citation(id) {
                Some(Some(hit)) => (
                    super::matches::source_tile(Ico::FileText, px(32.), px(22.), &lb),
                    hit.title.clone(),
                    format!(
                        "{} · {}",
                        lokalbot_i18n::tr("Agent note"),
                        hit.source_label()
                    ),
                    true,
                ),
                known => (
                    super::matches::source_tile(Ico::FileText, px(32.), px(22.), &lb),
                    lokalbot_i18n::tr("Agent note").to_string(),
                    if known.is_some() {
                        lokalbot_i18n::tr("Unavailable").to_string()
                    } else {
                        String::new()
                    },
                    false,
                ),
            },
        };
        let row_key = key.wrapping_mul(64).wrapping_add(index as u64);
        let open_source = first.clone();
        let mut numbers = h_flex().flex_none().gap(px(12.)).items_center();
        for (number, citation) in &group.entries {
            let number = *number;
            let on = self.passage_is_open(answer, number);
            let cited = citation.clone();
            let mut entry = h_flex().gap(px(5.)).items_center().child(citation_pill(
                ElementId::NamedInteger(
                    SharedString::from(format!("ask-cite-{row_key}")),
                    number as u64,
                ),
                number,
                on,
                cx.listener(move |this, _, window, cx| {
                    this.toggle_passage(answer, number, cited.clone(), window, cx)
                }),
                &lb,
            ));
            if let (SourceKind::Meeting, CitationSource::Meeting { at: Some(at), .. }) =
                (group.kind, citation)
                && available
            {
                let at = *at;
                let meeting = citations::resolve_meeting(
                    match citation {
                        CitationSource::Meeting { id, .. } => id,
                        _ => unreachable!(),
                    },
                    meetings,
                )
                .map(|m| m.id);
                entry = entry.child(
                    h_flex()
                        .id(ElementId::NamedInteger(
                            SharedString::from(format!("ask-cite-time-{row_key}")),
                            number as u64,
                        ))
                        .gap(px(3.))
                        .items_center()
                        .cursor_pointer()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.accent_text)
                        .child(ui::icon(Ico::Play, px(7.), lb.accent_text))
                        .child(ui::action_row::short_stamp(at))
                        .tooltip(|window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(lokalbot_i18n::tr(
                                "Open in meeting",
                            ))
                            .build(window, cx)
                        })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(meeting) = meeting {
                                this.open_meeting(meeting, Some(at), cx);
                            }
                        })),
                );
            }
            numbers = numbers.child(entry);
        }
        h_flex()
            .w_full()
            .min_h(px(36.))
            .gap(px(10.))
            .items_center()
            .pl(px(8.))
            .pr(px(12.))
            .py(px(7.))
            .child(div().flex_none().child(lead))
            .child(
                h_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        div()
                            .id(("ask-source-title", row_key))
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(if available {
                                lb.text
                            } else {
                                lb.text_secondary
                            })
                            .when(available, |this| {
                                this.cursor_pointer()
                                    .hover(|style| style.underline())
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.open_citation(&open_source, cx)
                                    }))
                            })
                            .child(title),
                    )
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .child(meta),
                    ),
            )
            .child(numbers)
    }

    /// The matches for a question whose answer failed, found again here within
    /// the sources, dates and evidence limits recorded with the question.
    fn render_failed_matches(
        &mut self,
        answer: Uuid,
        question: &ChatMessage,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let found = match self.failed_matches.get(&answer) {
            Some(Some(found)) => found.clone(),
            Some(None) => return None,
            None => {
                self.load_failed_matches(answer, question, cx);
                return None;
            }
        };
        if found.meetings.is_empty()
            && found.screens.is_empty()
            && found.files.is_empty()
            && found.notes.is_empty()
        {
            return None;
        }
        let lb = cx.lb().clone();
        Some(
            v_flex()
                .w_full()
                .gap(px(8.))
                .child(
                    div()
                        .text_size(ty::CAPTION)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.supporting)
                        .child(lokalbot_i18n::tr("Matches")),
                )
                .child(self.match_card(&found, "ask-failed-match", cx))
                .into_any_element(),
        )
    }

    fn load_failed_matches(
        &mut self,
        answer: Uuid,
        question: &ChatMessage,
        cx: &mut Context<Self>,
    ) {
        self.failed_matches.insert(answer, None);
        let (library, meetings, settings) = {
            let data = self.data.read(cx);
            (
                data.library.clone(),
                data.meetings.clone(),
                data.settings.clone(),
            )
        };
        let sources = super::scope::Sources::from_saved(&question.source_scopes);
        let bounds = question
            .day_scope_key
            .as_deref()
            .map_or(super::scope::DateScope::AnyTime, |key| {
                super::scope::DateScope::from_storage_key(key)
            })
            .bounds();
        let query = super::search::Query {
            text: question.text.trim().to_string(),
            facet: super::search::Facet::All,
            meetings: sources.meetings,
            screen: sources.screen,
            file_folders: if sources.files && settings.file_search_enabled {
                settings.file_search_folders.clone()
            } else {
                Vec::new()
            },
            agent_notes: sources.agent_notes && settings.coding_agent_notes_enabled,
            screen_app: question.screen_app.clone(),
            screen_ids: question.screen_snapshot_ids.clone(),
            meeting_ids: question.meeting_ids.clone(),
            since: bounds.map(|(since, _)| since),
            until: bounds.map(|(_, until)| until),
            limit: super::search::DISPLAY_LIMIT,
        };
        cx.spawn(async move |this, cx| {
            let found = cx
                .background_spawn(async move { super::search::run(&library, &meetings, &query) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.failed_matches.insert(answer, Some(found));
                cx.notify();
            });
        })
        .detach();
    }

    /// Questions about the person's own latest meeting, a colleague and a
    /// project, then one word to search for.
    pub(super) fn render_suggestions(&mut self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        let all = self.suggestions(cx);
        let mut rows: Vec<AnyElement> = vec![div().h(px(14.)).into_any_element()];
        for (index, suggestion) in all
            .iter()
            .filter(|s| s.kind != SuggestionKind::Keyword)
            .enumerate()
        {
            let text = suggestion.text.clone();
            rows.push(
                suggestion_row(("ask-suggestion", index), suggestion, None, &lb)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.ask_suggestion(&text, window, cx)
                    }))
                    .into_any_element(),
            );
        }
        if let Some(word) = all.iter().find(|s| s.kind == SuggestionKind::Keyword) {
            rows.push(
                div()
                    .pt(px(6.))
                    .pb(px(5.))
                    .child(div().h(px(1.)).bg(lb.separator))
                    .into_any_element(),
            );
            let text = word.text.clone();
            rows.push(
                suggestion_row(
                    ("ask-suggestion-word", 0usize),
                    word,
                    Some(lokalbot_i18n::tr("Type a word to see where it came up")),
                    &lb,
                )
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.set_composer_text(&text, window, cx);
                    this.focus_composer(window, cx);
                }))
                .into_any_element(),
            );
        }
        rows
    }

    fn suggestions(&mut self, cx: &mut Context<Self>) -> Vec<Suggestion> {
        self.load_suggestion_names(cx);
        let latest = self
            .data
            .read(cx)
            .meetings
            .iter()
            .filter(|m| m.is_own_work() && m.ended_at.is_some())
            .max_by_key(|m| m.started_at)
            .map(|m| m.display_title());
        let (person, project) = self
            .suggestion_names
            .as_ref()
            .map(|names| (names.person.clone(), names.project.clone()))
            .unwrap_or_default();
        model::suggestions(latest.as_deref(), person.as_deref(), project.as_deref())
    }

    /// A colleague and a project to name, read off the UI thread once per
    /// library change.
    fn load_suggestion_names(&mut self, cx: &mut Context<Self>) {
        let revision = self.data.read(cx).revision;
        if self.suggestion_names_revision == Some(revision) {
            return;
        }
        self.suggestion_names_revision = Some(revision);
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            let names = cx
                .background_spawn(async move {
                    let (people, projects) =
                        lokalbot_core::projects::build_people_and_projects(&library).ok()?;
                    let project = projects
                        .iter()
                        .find(|p| p.kind == lokalbot_core::ProjectKind::Tracked)
                        .or(projects.first())
                        .map(|p| p.name.clone());
                    Some(super::SuggestionNames {
                        person: people.first().map(|p| p.name.clone()),
                        project,
                    })
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.suggestion_names = names;
                cx.notify();
            });
        })
        .detach();
    }

    /// Reads the cited screen moments that are not loaded yet, off the UI thread.
    fn load_screen_citations(&mut self, sources: &[CitationSource], cx: &mut Context<Self>) {
        let missing: Vec<i64> = sources
            .iter()
            .filter_map(|source| match source {
                CitationSource::Screen { snapshot_id } => Some(*snapshot_id),
                CitationSource::Meeting { .. }
                | CitationSource::File { .. }
                | CitationSource::Note { .. } => None,
            })
            .filter(|id| {
                !self.screen_citations.contains_key(id)
                    && !self.loading_screen_citations.contains(id)
            })
            .collect();
        if missing.is_empty() {
            return;
        }
        self.loading_screen_citations
            .extend(missing.iter().copied());
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            let loaded: Vec<(i64, Option<lokalbot_core::ScreenMoment>)> = cx
                .background_spawn(async move {
                    missing
                        .into_iter()
                        .map(|id| (id, library.screen_moment(id).ok().flatten()))
                        .collect()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                for (id, moment) in loaded {
                    this.loading_screen_citations.remove(&id);
                    this.screen_citations.insert(id, moment);
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Reads the cited files that are not loaded yet, off the UI thread. Nothing
    /// resolves while Files is off: the index is gone with it.
    fn load_file_citations(&mut self, sources: &[CitationSource], cx: &mut Context<Self>) {
        let missing: Vec<i64> = sources
            .iter()
            .filter_map(|source| match source {
                CitationSource::File { id } => Some(*id),
                _ => None,
            })
            .filter(|id| citations::known_file_citation(*id).is_none())
            .filter(|id| self.loading_file_citations.insert(*id))
            .collect();
        if missing.is_empty() {
            return;
        }
        let (root, enabled) = {
            let data = self.data.read(cx);
            (
                data.library.paths().root().to_path_buf(),
                data.settings.file_search_enabled,
            )
        };
        cx.spawn(async move |this, cx| {
            cx.background_spawn(async move {
                let reader = lokalbot_core::files::search::FileReader::shared(&root);
                for id in missing {
                    let hit = enabled.then(|| reader.hit(id)).flatten();
                    citations::remember_file_citation(id, hit);
                }
            })
            .await;
            let _ = this.update(cx, |_, cx| cx.notify());
        })
        .detach();
    }

    /// Reads the cited coding-agent notes that are not loaded yet, off the UI
    /// thread. Nothing resolves while Read coding agent notes is off: the saved
    /// copy is gone with it.
    fn load_note_citations(&mut self, sources: &[CitationSource], cx: &mut Context<Self>) {
        let missing: Vec<String> = sources
            .iter()
            .filter_map(|source| match source {
                CitationSource::Note { id } => Some(id.clone()),
                _ => None,
            })
            .filter(|id| citations::known_note_citation(id).is_none())
            .filter(|id| self.loading_note_citations.insert(id.clone()))
            .collect();
        if missing.is_empty() {
            return;
        }
        let (root, enabled) = {
            let data = self.data.read(cx);
            (
                data.library.paths().root().to_path_buf(),
                data.settings.coding_agent_notes_enabled,
            )
        };
        cx.spawn(async move |this, cx| {
            cx.background_spawn(async move {
                let index = lokalbot_core::agent_notes::NotesIndex::new(&root);
                for id in missing {
                    let hit = enabled.then(|| index.hit(&id).ok().flatten()).flatten();
                    citations::remember_note_citation(&id, hit);
                }
            })
            .await;
            let _ = this.update(cx, |_, cx| cx.notify());
        })
        .detach();
    }

    fn parsed_answer(&mut self, id: Uuid, text: &str) -> Rc<Answer> {
        let mut hasher = DefaultHasher::new();
        text.hash(&mut hasher);
        let hash = hasher.finish();
        if let Some((cached, answer)) = self.turns.answers.get(&id)
            && *cached == hash
        {
            return answer.clone();
        }
        let answer = Rc::new(answer_text::parse(text));
        self.turns.answers.insert(id, (hash, answer.clone()));
        answer
    }

    fn open_citation(&mut self, source: &CitationSource, cx: &mut Context<Self>) {
        if let CitationSource::File { id } = source {
            if let Some(Some(hit)) = citations::known_file_citation(*id) {
                super::search::open_file(&hit);
            }
            return;
        }
        if let CitationSource::Note { id } = source {
            // A cited note opens the agent's own file, while notes are read.
            if self.data.read(cx).settings.coding_agent_notes_enabled
                && let Some(Some(hit)) = citations::known_note_citation(id)
            {
                super::search::open_note(&hit);
            }
            return;
        }
        if let CitationSource::Screen { snapshot_id } = source {
            if let Some(Some(moment)) = self.screen_citations.get(snapshot_id) {
                super::open_screen_moment(&self.data, moment, cx);
                self.reveal_main_window(cx);
            }
            return;
        }
        let meetings = self.data.read(cx).meetings.clone();
        if let CitationSource::Meeting { at, .. } = source
            && let Some(meeting) = source.meeting(&meetings)
        {
            let id = meeting.id;
            self.open_meeting(id, *at, cx);
        }
    }

    fn render_preparation(&self, status: Option<SharedString>, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let data = self.data.read(cx);
        let built_in = data.settings.summarizer_backend == SummarizerBackend::BuiltIn;
        let download = data
            .downloads
            .get(&data.settings.built_in_model_id)
            .filter(|_| built_in)
            .cloned();
        let (title, detail) = match (&download, status) {
            (Some(progress), _) => (
                SharedString::from(lokalbot_i18n::tr("Preparing the on-device model")),
                SharedString::from(lokalbot_i18n::format(
                    "Downloading the on-device model — {0}%",
                    &[("0", format!("{}", (progress.fraction() * 100.0).round()))],
                )),
            ),
            (None, Some(status)) => (
                status,
                SharedString::from(if built_in {
                    lokalbot_i18n::tr("Loading the model into memory…")
                } else {
                    lokalbot_i18n::tr("Waiting for the first response…")
                }),
            ),
            (None, None) => (
                SharedString::from(lokalbot_i18n::tr("Preparing the assistant")),
                SharedString::from(if built_in {
                    lokalbot_i18n::tr("Checking the selected on-device model…")
                } else {
                    lokalbot_i18n::tr("Connecting to the selected model…")
                }),
            ),
        };
        ui::grouped_surface(cx)
            .p(px(12.))
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(Spinner::new().small().color(lb.accent_text))
                    .child(
                        v_flex()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(title),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(detail),
                            ),
                    ),
            )
            .when_some(download, |this, progress| {
                this.child(
                    div()
                        .mt(px(10.))
                        .h(px(4.))
                        .w_full()
                        .rounded_full()
                        .bg(lb.chip_fill)
                        .child(
                            div()
                                .h_full()
                                .rounded_full()
                                .bg(lb.accent_fill)
                                .w(relative(progress.fraction().clamp(0.0, 1.0))),
                        ),
                )
            })
    }
}

/// The step in flight, with a spinner (`WorkedLine` while a tool runs).
fn render_worked_line(steps: &[Step], cx: &App) -> Div {
    let lb = cx.lb();
    let current = steps.iter().find(|s| !s.done);
    h_flex()
        .gap(px(6.))
        .items_center()
        .text_size(ty::SECONDARY)
        .text_color(lb.text_secondary)
        .child(Spinner::new().xsmall().color(lb.text_secondary))
        .when_some(current, |this, step| {
            this.child(div().min_w_0().truncate().child(step.text.clone()))
        })
}

/// A citation number as a small pill, filled while its passage is showing.
fn citation_pill(
    id: ElementId,
    number: usize,
    on: bool,
    on_click: impl Fn(&gpui_kit::ClickEvent, &mut Window, &mut App) + 'static,
    lb: &crate::theme::Palette,
) -> gpui_kit::Stateful<Div> {
    let (bg, fg) = if on {
        (lb.accent_fill, gpui_kit::white())
    } else {
        (lb.accent_fill.opacity(0.12), lb.accent_text)
    };
    div()
        .id(id)
        .flex_none()
        .min_w(px(17.))
        .h(px(16.))
        .px(px(4.))
        .rounded(px(4.))
        .bg(bg)
        .flex()
        .items_center()
        .justify_center()
        .cursor_pointer()
        .text_size(ty::CAPTION)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(fg)
        .child(number.to_string())
        .tooltip(|window, cx| {
            gpui_kit::component::tooltip::Tooltip::new(lokalbot_i18n::tr("Show the quoted passage"))
                .build(window, cx)
        })
        .on_click(on_click)
}

/// One suggestion: its symbol, the question, and for the word a hint.
fn suggestion_row(
    id: impl Into<ElementId>,
    suggestion: &Suggestion,
    hint: Option<&str>,
    lb: &crate::theme::Palette,
) -> gpui_kit::Stateful<Div> {
    let icon = match suggestion.kind {
        SuggestionKind::Project => Ico::Folder,
        SuggestionKind::Meeting => Ico::AudioLines,
        SuggestionKind::Person => Ico::Users,
        SuggestionKind::General => Ico::Sparkles,
        SuggestionKind::Keyword => Ico::Search,
    };
    let hover = lb.hover;
    h_flex()
        .id(id)
        .w_full()
        .min_h(px(34.))
        .gap(px(11.))
        .items_center()
        .px(px(12.))
        .rounded(px(8.))
        .cursor_pointer()
        .hover(move |style| style.bg(hover))
        .child(
            div()
                .w(px(18.))
                .flex_none()
                .flex()
                .justify_center()
                .child(ui::icon(icon, px(14.), lb.accent_text)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(ty::BODY)
                .text_color(lb.text)
                .child(suggestion.text.clone()),
        )
        .when_some(hint, |this, hint| {
            this.child(
                div()
                    .flex_none()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(hint.to_string()),
            )
        })
}

fn step(activity: &ChatActivity) -> Step {
    Step {
        text: activity.text.clone(),
        done: activity.done,
    }
}

fn date_divider_row(title: String, cx: &App) -> Div {
    let lb = cx.lb();
    h_flex()
        .gap(px(10.))
        .items_center()
        .child(
            div()
                .flex_none()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(title),
        )
        .child(div().flex_1().min_w_0().h(px(1.)).bg(lb.text.opacity(0.10)))
}

/// `ChatTranscriptPresentation.dateDividerTitle`. `previous` is the previous
/// question's time (`Some(None)` when that one had no saved time).
pub fn date_divider(
    created_at: Option<DateTime<Utc>>,
    previous: Option<Option<DateTime<Utc>>>,
    now: DateTime<Local>,
) -> Option<String> {
    let Some(at) = created_at else {
        return match previous {
            Some(None) => None,
            _ => Some(lokalbot_i18n::tr("Earlier conversation").into()),
        };
    };
    let day = at.with_timezone(&Local).date_naive();
    if let Some(Some(previous)) = previous
        && previous.with_timezone(&Local).date_naive() == day
    {
        return None;
    }
    let today = now.date_naive();
    if day == today {
        Some(lokalbot_i18n::tr("Today").into())
    } else if Some(day) == today.pred_opt() {
        Some(lokalbot_i18n::tr("Yesterday").into())
    } else {
        Some(
            day.format_localized(
                lokalbot_i18n::date_pattern("%B %-d, %Y"),
                lokalbot_i18n::date_locale(),
            )
            .to_string(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    #[test]
    fn dividers_follow_the_mac_rules() {
        let now = Local.with_ymd_and_hms(2026, 10, 18, 15, 0, 0).unwrap();
        let today = Local
            .with_ymd_and_hms(2026, 10, 18, 9, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        let older = Local
            .with_ymd_and_hms(2026, 10, 8, 9, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(
            date_divider(None, None, now).as_deref(),
            Some("Earlier conversation")
        );
        assert_eq!(date_divider(None, Some(None), now), None);
        assert_eq!(
            date_divider(Some(today), None, now).as_deref(),
            Some("Today")
        );
        assert_eq!(date_divider(Some(today), Some(Some(today)), now), None);
        assert_eq!(
            date_divider(Some(older), Some(None), now).as_deref(),
            Some("October 8, 2026")
        );
    }
}
