//! The conversation (`ChatTranscriptView`, `EditorialTurn`) and the empty state.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash as _, Hasher as _};
use std::rc::Rc;

use crate::i18n::h_flex;
use chrono::{DateTime, Local, Utc};
use gpui_kit::component::button::Button;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Div, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    Window, div, px, relative,
};
use lokalbot_core::{ChatActivity, ChatRole, settings::SummarizerBackend};
use uuid::Uuid;

use super::AskPage;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::answer_text::{self, Answer, AnswerStyle};
use crate::ui::citations::{self, CitationSource};
use crate::ui::{self, Ico};

const SUGGESTIONS: [&str; 3] = [
    "What did we decide in my last meeting?",
    "List my recent meetings",
    "Search my meetings for action items",
];

/// One step of tool activity.
#[derive(Clone)]
struct Step {
    text: String,
    icon: Ico,
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
    },
    Assistant {
        id: Uuid,
        text: String,
        created_at: Option<DateTime<Utc>>,
        steps: Vec<Step>,
        pending: bool,
        status: Option<SharedString>,
        error: Option<SharedString>,
        can_retry: bool,
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
        let last_assistant = messages
            .iter()
            .rev()
            .find(|m| m.role == ChatRole::Assistant)
            .map(|m| m.id);
        let mut turns = Vec::new();
        let mut previous_user: Option<Option<DateTime<Utc>>> = None;
        for (index, message) in messages.iter().enumerate() {
            match message.role {
                ChatRole::User => {
                    let divider = date_divider(message.created_at, previous_user, Local::now());
                    turns.push(Turn::User {
                        id: message.id,
                        text: message.text.clone(),
                        created_at: message.created_at,
                        separator: index > 0 && divider.is_none(),
                        divider,
                        latest: Some(message.id) == latest_user,
                    });
                    previous_user = Some(message.created_at);
                }
                ChatRole::Assistant => turns.push(Turn::Assistant {
                    id: message.id,
                    text: message.text.clone(),
                    created_at: message.created_at,
                    steps: message.activity.iter().map(step).collect(),
                    pending: false,
                    status: None,
                    error: None,
                    can_retry: stream.is_none() && Some(message.id) == last_assistant,
                }),
            }
        }
        if let Some(stream) = stream {
            let saved_question = messages
                .last()
                .is_some_and(|m| m.role == ChatRole::User && m.text == stream.question);
            if !saved_question {
                let now = Utc::now();
                let divider = date_divider(Some(now), previous_user, Local::now());
                turns.push(Turn::User {
                    id: Uuid::from_u128(STREAM_ID.as_u128() + 1),
                    text: stream.question.clone(),
                    created_at: Some(now),
                    separator: !messages.is_empty() && divider.is_none(),
                    divider,
                    latest: true,
                });
            } else if let Some(Turn::User { latest, .. }) = turns.last_mut() {
                *latest = true;
            }
            let answering = stream.error.is_none();
            let count = stream.activity.len();
            turns.push(Turn::Assistant {
                id: STREAM_ID,
                text: stream.text.clone(),
                created_at: None,
                steps: stream
                    .activity
                    .iter()
                    .enumerate()
                    .map(|(i, text)| Step {
                        text: text.clone(),
                        icon: Ico::Search,
                        done: !answering || i + 1 < count || !stream.text.is_empty(),
                    })
                    .collect(),
                pending: answering,
                status: stream.status.clone(),
                error: stream.error.clone(),
                can_retry: false,
            });
        }
        turns
    }

    pub(super) fn render_transcript(
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
                                .max_w(metric::READING_MAX_WIDTH + metric::DETAIL_PADDING * 2.)
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
    }

    fn render_user_turn(&self, turn: Turn, cx: &mut Context<Self>) -> Div {
        let Turn::User {
            id,
            text,
            created_at,
            divider,
            separator,
            latest,
        } = turn
        else {
            return div();
        };
        let lb = cx.lb().clone();
        let long = text.chars().count() > 180 || text.lines().count() > 3;
        let expanded = latest || self.turns.questions.contains(&id);
        v_flex()
            .gap(px(12.))
            .when_some(divider, |this, title| {
                this.child(date_divider_row(title, cx))
            })
            .when(separator, |this| this.child(ui::divider(cx)))
            .child(
                v_flex()
                    .gap(px(7.))
                    .child(turn_meta(
                        Ico::CircleUser,
                        lokalbot_i18n::tr("You"),
                        created_at,
                        cx,
                    ))
                    .child(
                        div()
                            .text_size(ty::QUESTION)
                            .line_height(px(25.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .when(!expanded, |this| this.line_clamp(3))
                            .child(text),
                    )
                    .when(long && !latest, |this| {
                        let label = if expanded {
                            lokalbot_i18n::tr("Show less")
                        } else {
                            lokalbot_i18n::tr("Show full question")
                        };
                        this.child(
                            div()
                                .id(("ask-question-toggle", super::history::element_key(id)))
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
            created_at,
            steps,
            pending,
            status,
            error,
            can_retry,
        } = turn
        else {
            return div();
        };
        let lb = cx.lb().clone();
        let stopped = {
            let normalized = text.trim().to_lowercase();
            normalized == "stopped." || normalized.starts_with("response stopped")
        };
        let answer = self.parsed_answer(id, &text);
        let mut column = v_flex().gap(px(10.)).w_full();

        if stopped {
            column = column.child(status_row(
                lokalbot_i18n::tr("Response stopped"),
                lokalbot_i18n::tr("The response was interrupted. You can try the question again."),
                Ico::CircleStop,
                lb.text_secondary,
                cx,
            ));
        } else if let Some(error) = error.clone() {
            column = column.child(status_row(
                lokalbot_i18n::tr("Answer unavailable"),
                &error,
                Ico::TriangleAlert,
                lb.attention_text,
                cx,
            ));
        } else {
            let title = if pending {
                lokalbot_i18n::tr("LokalBot is answering")
            } else {
                "LokalBot"
            };
            column = column.child(turn_meta(Ico::Sparkles, title, created_at, cx));
            if !steps.is_empty() {
                column = column.child(self.render_worked_line(id, &steps, cx));
            }
        }

        if pending && text.trim().is_empty() && error.is_none() {
            column = column.child(self.render_preparation(status, cx));
        } else if !stopped && error.is_none() && !answer.is_empty() {
            let page = cx.entity();
            let citations = answer.citations.clone();
            let on_cite: answer_text::CiteHandler = Rc::new(move |index, _, cx| {
                if let Some(source) = citations.get(index).cloned() {
                    page.update(cx, |page, cx| page.open_citation(&source, cx));
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

        let copy_text = citations::display_text(&text);
        let has_text = !copy_text.trim().is_empty() && !stopped;
        let copied = self.turns.copied == Some(id);
        let responding = self.is_responding(cx);
        column = column.child(
            h_flex()
                .gap(px(8.))
                .pt(px(2.))
                .when(has_text && !pending, |this| {
                    this.child(
                        Button::new(("ask-copy", super::history::element_key(id)))
                            .outline()
                            .small()
                            .icon(Icon::new(if copied { Ico::Check } else { Ico::Copy }))
                            .label(if copied {
                                lokalbot_i18n::tr("Copied")
                            } else {
                                lokalbot_i18n::tr("Copy")
                            })
                            .disabled(copied)
                            .tooltip(lokalbot_i18n::tr("Copy this answer"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.copy_answer(id, copy_text.clone(), cx)
                            })),
                    )
                })
                .when(can_retry && !responding, |this| {
                    this.child(
                        Button::new(("ask-retry", super::history::element_key(id)))
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::RotateCw))
                            .label(lokalbot_i18n::tr("Retry"))
                            .tooltip(lokalbot_i18n::tr("Try this question again"))
                            .on_click(cx.listener(move |this, _, _, cx| this.retry(id, cx))),
                    )
                })
                .when(pending && responding, |this| {
                    this.child(
                        Button::new("ask-stop-answer")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::Square))
                            .label(lokalbot_i18n::tr("Stop"))
                            .tooltip(lokalbot_i18n::tr("Stop answering (Esc)"))
                            .on_click(cx.listener(|this, _, _, cx| this.stop_answer(cx))),
                    )
                }),
        );

        if !answer.citations.is_empty() && !stopped && error.is_none() {
            self.load_screen_citations(&answer.citations, cx);
            column = column.child(self.render_evidence(id, &answer.citations, cx));
        }
        column
    }

    /// Reads the cited screen moments that are not loaded yet, off the UI thread.
    fn load_screen_citations(&mut self, sources: &[CitationSource], cx: &mut Context<Self>) {
        let missing: Vec<i64> = sources
            .iter()
            .filter_map(|source| match source {
                CitationSource::Screen { snapshot_id } => Some(*snapshot_id),
                CitationSource::Meeting { .. } => None,
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
        if let CitationSource::Screen { snapshot_id } = source {
            if let Some(Some(moment)) = self.screen_citations.get(snapshot_id) {
                super::open_screen_moment(&self.data, moment, cx);
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

    fn render_worked_line(&self, id: Uuid, steps: &[Step], cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        if let Some(current) = steps.iter().find(|s| !s.done) {
            return h_flex()
                .gap(px(6.))
                .items_center()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(Spinner::new().xsmall().color(lb.text_secondary))
                .child(current.text.clone());
        }
        let expanded = self.turns.worked.contains(&id);
        let summary = format!(
            "worked: {}",
            steps
                .iter()
                .map(|s| s.text.as_str())
                .collect::<Vec<_>>()
                .join(" · ")
        );
        v_flex()
            .gap(px(6.))
            .child(
                h_flex()
                    .id(("ask-worked", super::history::element_key(id)))
                    .gap(px(6.))
                    .items_center()
                    .cursor_pointer()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .hover(|s| s.text_color(lb.text))
                    .child(ui::icon(Ico::CircleCheck, px(12.), lb.text_secondary))
                    .child(div().min_w_0().truncate().child(summary))
                    .child(ui::icon(
                        if expanded {
                            Ico::ChevronDown
                        } else {
                            Ico::ChevronRight
                        },
                        px(12.),
                        lb.text_secondary,
                    ))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if !this.turns.worked.remove(&id) {
                            this.turns.worked.insert(id);
                        }
                        cx.notify();
                    })),
            )
            .when(expanded, |this| {
                this.child(
                    h_flex()
                        .flex_wrap()
                        .gap(px(6.))
                        .children(steps.iter().map(|step| {
                            h_flex()
                                .gap(px(6.))
                                .items_center()
                                .px(px(8.))
                                .py(px(3.))
                                .rounded(px(6.))
                                .bg(lb.chip_fill)
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(ui::icon(step.icon, px(12.), lb.text_secondary))
                                .child(step.text.clone())
                        })),
                )
            })
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

    fn render_evidence(&self, id: Uuid, sources: &[CitationSource], cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let meetings = self.data.read(cx).meetings.clone();
        let expanded = self
            .turns
            .evidence
            .get(&id)
            .copied()
            .unwrap_or(sources.len() <= 3);
        let summary = citations::evidence_summary(sources, &meetings, &self.screen_citations);
        let key = super::history::element_key(id);
        let rows: Vec<AnyElement> = sources
            .iter()
            .enumerate()
            .map(|(index, source)| {
                let resolved = citations::resolve(source, &meetings, &self.screen_citations);
                let source = source.clone();
                let available = resolved.available;
                h_flex()
                    .id(("ask-evidence-row", key.wrapping_add(index as u64 + 1)))
                    .gap(px(10.))
                    .items_center()
                    .p(px(12.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.group_fill)
                    .border_1()
                    .border_color(lb.group_stroke)
                    .when(available, |this| {
                        this.cursor_pointer().hover(|s| s.bg(lb.hover))
                    })
                    .child(
                        div()
                            .size(px(20.))
                            .flex_none()
                            .rounded(px(4.))
                            .bg(lb.accent_fill)
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(gpui_kit::white())
                            .child((index + 1).to_string()),
                    )
                    .child(div().w(px(20.)).flex_none().child(ui::icon(
                        if resolved.is_screen {
                            Ico::Monitor
                        } else {
                            Ico::Users
                        },
                        px(15.),
                        lb.text_secondary,
                    )))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(if available {
                                        lb.text
                                    } else {
                                        lb.text_secondary
                                    })
                                    .line_clamp(2)
                                    .child(resolved.title),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(resolved.detail),
                            ),
                    )
                    .child(if available {
                        ui::icon(Ico::ChevronRight, px(12.), lb.text_tertiary).into_any_element()
                    } else {
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Unavailable")))
                            .into_any_element()
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if available {
                            this.open_citation(&source, cx);
                        }
                    }))
                    .into_any_element()
            })
            .collect();

        v_flex()
            .w_full()
            .rounded(metric::GROUP_RADIUS)
            .bg(lb.chip_fill.opacity(0.5))
            .child(
                h_flex()
                    .id(("ask-evidence", key))
                    .gap(px(8.))
                    .items_center()
                    .px(px(12.))
                    .py(px(9.))
                    .cursor_pointer()
                    .child(ui::icon(if expanded { Ico::ChevronDown } else { Ico::ChevronRight }, px(12.), lb.text_secondary))
                    .child(ui::icon(Ico::ShieldCheck, px(14.), lb.accent_text))
                    .child(div().text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Evidence"))))
                    .child(div().min_w_0().truncate().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(summary))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.turns.evidence.insert(id, !expanded);
                        cx.notify();
                    })),
            )
            .when(expanded, |this| {
                this.child(
                    v_flex()
                        .gap(px(8.))
                        .px(px(12.))
                        .pb(px(12.))
                        .children(rows)
                        .child(
                            div()
                                .pt(px(2.))
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr("LokalBot used only the sources enabled for this question. Citation numbers remain stable even when a local source is later removed."))),
                        ),
                )
            })
    }

    pub(super) fn render_empty_state(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let suggestions: Vec<AnyElement> = SUGGESTIONS
            .iter()
            .enumerate()
            .map(|(index, suggestion)| {
                h_flex()
                    .id(("ask-suggestion", index))
                    .w_full()
                    .max_w(px(400.))
                    .gap(px(8.))
                    .items_center()
                    .px(px(12.))
                    .py(px(9.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.chip_fill)
                    .cursor_pointer()
                    .hover(|s| s.bg(lb.hover.opacity(2.0)))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(suggestion))),
                    )
                    .child(ui::icon(Ico::CircleArrowUp, px(16.), lb.accent_text))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.ask_suggestion(lokalbot_i18n::tr(suggestion), window, cx)
                    }))
                    .into_any_element()
            })
            .collect();
        v_flex()
            .size_full()
            .items_center()
            .justify_center()
            .p(px(24.))
            .gap(px(12.))
            .child(crate::ui::glyphs::ask_glyph(px(34.), lb.text))
            .child(div().text_size(ty::PAGE_TITLE).font_weight(FontWeight::BOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Ask your work memory"))))
            .child(
                div()
                    .max_w(px(400.))
                    .text_center()
                    .text_size(ty::BODY)
                    .line_height(px(21.))
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Type keywords to find meetings and screen moments, or ask a question. Return opens a keyword result or asks a question; Ctrl+Return always asks."))),
            )
            .child(v_flex().w_full().items_center().gap(px(8.)).pt(px(4.)).children(suggestions))
    }
}

fn step(activity: &ChatActivity) -> Step {
    let icon = match activity.icon.as_str() {
        "magnifyingglass" => Ico::Search,
        "doc.text" => Ico::FileText,
        "calendar" | "calendar.day.timeline.left" => Ico::Calendar,
        "rectangle.on.rectangle" | "display" => Ico::Monitor,
        "list.bullet" | "checklist" => Ico::ListChecks,
        _ => Ico::CircleCheck,
    };
    Step {
        text: activity.text.clone(),
        icon,
        done: activity.done,
    }
}

/// "You · 10:42 AM" in callout type at 68% of the primary color.
fn turn_meta(icon: Ico, title: &str, created_at: Option<DateTime<Utc>>, cx: &App) -> Div {
    let lb = cx.lb();
    let color = lb.text.opacity(0.68);
    h_flex()
        .gap(px(7.))
        .items_center()
        .text_size(ty::SECONDARY)
        .text_color(color)
        .child(ui::icon(icon, px(14.), color))
        .child(
            div()
                .font_weight(FontWeight::SEMIBOLD)
                .child(title.to_string()),
        )
        .when_some(created_at, |this, at| {
            this.child(div().text_color(lb.text_tertiary).child("·"))
                .child(
                    at.with_timezone(&Local)
                        .format_localized(
                            lokalbot_i18n::date_pattern("%-I:%M %p"),
                            lokalbot_i18n::date_locale(),
                        )
                        .to_string(),
                )
        })
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

fn status_row(title: &str, detail: &str, icon: Ico, tint: gpui_kit::Hsla, cx: &App) -> Div {
    let lb = cx.lb();
    h_flex()
        .gap(px(10.))
        .items_start()
        .p(px(10.))
        .rounded(metric::GROUP_RADIUS)
        .bg(lb.chip_fill.opacity(0.4))
        .border_1()
        .border_color(lb.text.opacity(0.08))
        .child(ui::icon(icon, px(16.), tint))
        .child(
            v_flex()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(title.to_string()),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(detail.to_string()),
                ),
        )
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
