//! Sheets of the meeting workspace: delete confirmation, action correction,
//! naming a speaker, merging meetings and undoing a merge, and boundaries.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Context, Entity, FontWeight, IntoElement, ParentElement as _, Render,
    SharedString, Styled as _, Window, div, px,
};
use lokalbot_core::{ActionCorrection, Meeting, Transcript};
use uuid::Uuid;

use super::model::{MeetingAction, ReviewSpeaker};
use crate::state::{AppData, AppEvent, MeetingTab};
use crate::theme::{LbThemeExt as _, ty};

/// "Delete N meeting(s)?" with the macOS wording.
pub(crate) fn confirm_delete(
    data: Entity<AppData>,
    ids: Vec<Uuid>,
    window: &mut Window,
    cx: &mut App,
) {
    if ids.is_empty() {
        return;
    }
    let title: SharedString = if ids.len() == 1 {
        lokalbot_i18n::tr("Delete 1 meeting?").into()
    } else {
        lokalbot_i18n::format("Delete {0} meetings?", &[("0", format!("{}", ids.len()))]).into()
    };
    window.open_dialog(cx, move |dialog, _, cx| {
        let lb = cx.lb().clone();
        let ids = ids.clone();
        let data = data.clone();
        dialog
            .w(px(440.))
            .title(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .child(title.clone()),
            )
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "This permanently deletes the audio, transcript and summary files.",
                    ))),
            )
            .footer(
                h_flex()
                    .w_full()
                    .gap_2()
                    .justify_end()
                    .child(
                        crate::ui::controls::bordered("delete-cancel", lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| {
                                window.close_dialog(cx);
                            }),
                    )
                    .child(
                        Button::new("delete-confirm")
                            .danger()
                            .label(lokalbot_i18n::tr(
                                "Delete (removes recordings & transcripts)",
                            ))
                            .on_click(move |_, window, cx| {
                                let ids = ids.clone();
                                data.update(cx, |data, cx| {
                                    for id in ids {
                                        data.delete_meeting(id, cx);
                                    }
                                });
                                window.close_dialog(cx);
                            }),
                    ),
            )
    });
}

// ------------------------------------------------------------ correction

pub(crate) struct CorrectionSheet {
    data: Entity<AppData>,
    meeting: Meeting,
    action: MeetingAction,
    suggestions: Vec<String>,
    text: Entity<InputState>,
    owner: Entity<InputState>,
    due: Entity<InputState>,
    error: Option<SharedString>,
}

impl CorrectionSheet {
    pub(crate) fn open(
        data: Entity<AppData>,
        meeting: Meeting,
        action: MeetingAction,
        speakers: &[ReviewSpeaker],
        window: &mut Window,
        cx: &mut App,
    ) {
        let suggestions: Vec<String> = {
            let mut seen = Vec::<String>::new();
            for speaker in speakers.iter().filter(|s| s.is_named && !s.is_user) {
                if !seen.iter().any(|n| n.eq_ignore_ascii_case(&speaker.name)) {
                    seen.push(speaker.name.clone());
                }
            }
            seen
        };
        let sheet = cx.new(|cx| {
            let text = cx.new(|cx| InputState::new(window, cx).default_value(action.text.clone()));
            let owner = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder("Owner", window, cx))
                    .default_value(action.owner.clone().unwrap_or_default())
            });
            let due = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder("Due date as agreed", window, cx))
                    .default_value(action.due.clone().unwrap_or_default())
            });
            Self {
                data,
                meeting,
                action,
                suggestions,
                text,
                owner,
                due,
                error: None,
            }
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(460.)).close_button(false).child(sheet.clone())
        });
    }

    fn set_owner(&mut self, owner: &str, window: &mut Window, cx: &mut Context<Self>) {
        let owner = owner.to_string();
        self.owner
            .update(cx, |input, cx| input.set_value(owner, window, cx));
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.text.read(cx).value().trim().to_string();
        let owner = self.owner.read(cx).value().trim().to_string();
        let due = self.due.read(cx).value().trim().to_string();
        let text_change =
            (!text.is_empty() && text != self.action.original_text && text != self.action.text)
                .then_some(text);
        let owner_change = (owner != self.action.owner.clone().unwrap_or_default()).then(|| {
            (!owner.is_empty() && owner != lokalbot_i18n::tr("Unassigned")).then_some(owner)
        });
        let due_change = (due != self.action.due.clone().unwrap_or_default())
            .then(|| (!due.is_empty()).then_some(due));
        if text_change.is_none() && owner_change.is_none() && due_change.is_none() {
            window.close_dialog(cx);
            return;
        }
        let library = self.data.read(cx).library.clone();
        let meeting = self.meeting.clone();
        let action_id = self.action.id.clone();
        let data = self.data.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    library.correct_action(
                        &meeting,
                        &action_id,
                        ActionCorrection {
                            text: text_change,
                            owner: owner_change,
                            due: due_change,
                        },
                    )
                })
                .await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(()) => {
                    data.update(cx, |data, cx| data.mark_library_changed(cx));
                    window.close_dialog(cx);
                }
                Err(err) => {
                    this.error = Some(
                        lokalbot_i18n::format(
                            "The correction could not be saved. {err}",
                            &[("err", format!("{:#}", err))],
                        )
                        .into(),
                    );
                    cx.notify();
                }
            });
        })
        .detach();
    }
}

impl Render for CorrectionSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let owner_value = self.owner.read(cx).value().to_string();
        let owner_label: SharedString = if owner_value.trim().is_empty() {
            lokalbot_i18n::tr("Unassigned").into()
        } else if owner_value.trim().eq_ignore_ascii_case("me") {
            lokalbot_i18n::tr("You").into()
        } else {
            owner_value.into()
        };
        let suggestions = self.suggestions.clone();
        let sheet = cx.entity().downgrade();
        let label = |text: &'static str| {
            div()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::MEDIUM)
                .text_color(lb.text_secondary)
                .child(text)
        };
        v_flex()
            .gap(px(14.))
            .child(
                div()
                    .text_size(ty::QUESTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Correct action details",
                    ))),
            )
            .child(
                v_flex()
                    .gap(px(6.))
                    .child(label(lokalbot_i18n::tr("Corrected wording")))
                    .child(Input::new(&self.text)),
            )
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(div().flex_1().child(label(lokalbot_i18n::tr("Owner"))))
                    .child(
                        Button::new("correction-owner-menu")
                            .outline()
                            .small()
                            .label(owner_label)
                            .dropdown_caret(true)
                            .dropdown_menu(move |menu, _, _| {
                                let pick = |name: &str| {
                                    let sheet = sheet.clone();
                                    let value = name.to_string();
                                    move |_: &gpui_kit::ClickEvent,
                                          window: &mut Window,
                                          cx: &mut App| {
                                        let _ = sheet.update(cx, |this, cx| {
                                            this.set_owner(&value, window, cx)
                                        });
                                    }
                                };
                                let mut menu = menu.item(
                                    PopupMenuItem::new(lokalbot_i18n::tr("You"))
                                        .on_click(pick(lokalbot_i18n::tr("Me"))),
                                );
                                for name in &suggestions {
                                    menu = menu.item(
                                        PopupMenuItem::new(name.clone()).on_click(pick(name)),
                                    );
                                }
                                menu.item(
                                    PopupMenuItem::new(lokalbot_i18n::tr("Unresolved speaker"))
                                        .on_click(pick(lokalbot_i18n::tr("Unresolved speaker"))),
                                )
                                .item(
                                    PopupMenuItem::new(lokalbot_i18n::tr("Unassigned"))
                                        .on_click(pick("")),
                                )
                            }),
                    ),
            )
            .child(Input::new(&self.owner))
            .child(
                v_flex()
                    .gap(px(6.))
                    .child(label(lokalbot_i18n::tr("Due date as agreed")))
                    .child(Input::new(&self.due)),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "This correction is stored separately from the extracted source.",
                    ))),
            )
            .when_some(self.error.clone(), |this, error| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(error),
                )
            })
            .child(
                h_flex()
                    .gap_2()
                    .justify_end()
                    .child(
                        crate::ui::controls::bordered(
                            "correction-cancel",
                            lokalbot_i18n::tr("Cancel"),
                        )
                        .on_click(|_, window, cx| {
                            window.close_dialog(cx);
                        }),
                    )
                    .child(
                        Button::new("correction-save")
                            .primary()
                            .label(lokalbot_i18n::tr("Save correction"))
                            .on_click(cx.listener(|this, _, window, cx| this.save(window, cx))),
                    ),
            )
    }
}

// --------------------------------------------------------- name speaker

pub(crate) struct NameSpeakerSheet {
    data: Entity<AppData>,
    meeting: Meeting,
    transcript: Transcript,
    speaker: ReviewSpeaker,
    name: Entity<InputState>,
    /// Calendar guests and name hints to choose from.
    suggestions: super::speaker_suggestions::SpeakerSuggestions,
    error: Option<SharedString>,
}

impl NameSpeakerSheet {
    pub(crate) fn open(
        data: Entity<AppData>,
        meeting: Meeting,
        transcript: Transcript,
        speaker: ReviewSpeaker,
        window: &mut Window,
        cx: &mut App,
    ) {
        let current = transcript
            .speaker_aliases
            .get(&speaker.key)
            .cloned()
            .unwrap_or_default();
        let sheet = cx.new(|cx| {
            let name = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder("Name this speaker", window, cx))
                    .default_value(current)
            });
            let suggestions = super::speaker_suggestions::SpeakerSuggestions::new(
                &meeting,
                &transcript,
                &speaker.key,
            );
            // Typing searches the suggestions; Enter fills in the top match,
            // then saves.
            cx.subscribe_in(
                &name,
                window,
                |this: &mut Self, input, event: &InputEvent, window, cx| match event {
                    InputEvent::Change => {
                        this.suggestions.query = input.read(cx).value().to_string();
                        cx.notify();
                    }
                    InputEvent::PressEnter { .. } => {
                        let name = input.read(cx).value().to_string();
                        if let Some(index) = this.suggestions.return_choice(&name) {
                            this.choose_suggestion(index, window, cx);
                        } else if !name.trim().is_empty() {
                            this.save(Some(name), window, cx);
                        }
                    }
                    _ => {}
                },
            )
            .detach();
            Self {
                data,
                meeting,
                transcript,
                speaker,
                name,
                suggestions,
                error: None,
            }
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(560.)).close_button(false).child(sheet.clone())
        });
    }

    fn save(&mut self, alias: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let mut transcript = self.transcript.clone();
        match alias.filter(|a| !a.trim().is_empty()) {
            Some(alias) => {
                transcript
                    .speaker_aliases
                    .insert(self.speaker.key.clone(), alias.trim().to_string());
                // The chosen calendar guest's opaque id, never the address.
                match self.suggestions.identity_for_save() {
                    Some(identity) => {
                        transcript
                            .speaker_calendar_identity_ids
                            .insert(self.speaker.key.clone(), identity);
                    }
                    None => {
                        transcript
                            .speaker_calendar_identity_ids
                            .remove(&self.speaker.key);
                    }
                }
            }
            None => {
                transcript.speaker_aliases.remove(&self.speaker.key);
                transcript
                    .speaker_calendar_identity_ids
                    .remove(&self.speaker.key);
            }
        }
        let library = self.data.read(cx).library.clone();
        let meeting = self.meeting.clone();
        let data = self.data.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move { library.save_transcript(&meeting, &transcript) })
                .await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(()) => {
                    data.update(cx, |data, cx| data.mark_library_changed(cx));
                    window.close_dialog(cx);
                }
                Err(err) => {
                    this.error = Some(
                        lokalbot_i18n::format(
                            "The name could not be saved. {err}",
                            &[("err", format!("{:#}", err))],
                        )
                        .into(),
                    );
                    cx.notify();
                }
            });
        })
        .detach();
    }
}

impl NameSpeakerSheet {
    /// Fills the name from a suggestion and remembers which guest it was.
    pub(super) fn choose_suggestion(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(choice) = self.suggestions.choices.get(index) else {
            return;
        };
        let name = choice.name.clone().unwrap_or_default();
        self.suggestions.selected = choice.calendar.as_ref().map(|guest| guest.id.clone());
        self.suggestions.query.clear();
        self.name
            .update(cx, |input, cx| input.set_value(name, window, cx));
        cx.notify();
    }
}

impl Render for NameSpeakerSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        v_flex()
            .gap(px(14.))
            .child(div().text_size(ty::QUESTION).font_weight(FontWeight::BOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Name Speaker"))))
            .child(match &self.speaker.sample {
                Some((start, text)) => v_flex()
                    .gap(px(4.))
                    .p(px(12.))
                    .rounded(px(10.))
                    .bg(lb.group_fill)
                    .border_1()
                    .border_color(lb.group_stroke)
                    .child(div().text_size(ty::BODY).text_color(lb.text).child(format!("“{text}”")))
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(lokalbot_core::time::stamp(*start)),
                    )
                    .into_any_element(),
                None => div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("No clear voice excerpt available. Check the transcript before confirming this speaker.")))
                    .into_any_element(),
            })
            .child(
                v_flex()
                    .gap(px(6.))
                    .child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Name"))))
                    .child(Input::new(&self.name)),
            )
            .children({
                let name = self.name.read(cx).value().to_string();
                self.suggestions.render(&name, cx)
            })
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_start()
                    .child(crate::ui::icon(crate::ui::Ico::ShieldCheck, px(14.), lb.accent_text))
                    .child(
                        div()
                            .flex_1()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Names are saved with this meeting."))),
                    ),
            )
            .when_some(self.error.clone(), |this, error| {
                this.child(div().text_size(ty::SECONDARY).text_color(lb.attention_text).child(error))
            })
            .child(
                h_flex()
                    .gap_2()
                    .child(
                        Button::new("speaker-unidentified")
                            .ghost()
                            .label(lokalbot_i18n::tr("Leave Unidentified"))
                            .on_click(cx.listener(|this, _, window, cx| this.save(None, window, cx))),
                    )
                    .child(div().flex_1())
                    .child(crate::ui::controls::bordered("speaker-cancel", lokalbot_i18n::tr("Cancel")).on_click(|_, window, cx| {
                        window.close_dialog(cx);
                    }))
                    .child(
                        Button::new("speaker-save").primary().label(lokalbot_i18n::tr("Save")).on_click(cx.listener(|this, _, window, cx| {
                            let name = this.name.read(cx).value().to_string();
                            this.save(Some(name), window, cx)
                        })),
                    ),
            )
    }
}

// ---------------------------------------------------------------- merge

/// "Merge meetings" (`MeetingMergeSheet.swift`): one new meeting from the
/// selected ones, with their originals folded into it.
pub(crate) struct MergeSheet {
    data: Entity<AppData>,
    meetings: Vec<Meeting>,
    title: Entity<InputState>,
    has_transcript: bool,
    summarize: bool,
    working: bool,
    error: Option<SharedString>,
}

impl MergeSheet {
    pub(crate) fn open(
        data: Entity<AppData>,
        mut meetings: Vec<Meeting>,
        window: &mut Window,
        cx: &mut App,
    ) {
        meetings.sort_by_key(|m| m.started_at);
        let library = data.read(cx).library.clone();
        let has_transcript = meetings.iter().any(|m| {
            library
                .meeting_dir(m)
                .join(lokalbot_core::library::TRANSCRIPT_FILE)
                .is_file()
        });
        let first = meetings
            .first()
            .map(|m| m.display_title())
            .unwrap_or_default();
        let sheet = cx.new(|cx| Self {
            title: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder("Merged meeting", window, cx))
                    .default_value(first)
            }),
            data,
            meetings,
            has_transcript,
            summarize: has_transcript,
            working: false,
            error: None,
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(560.)).close_button(false).child(sheet.clone())
        });
    }

    fn merge(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.working {
            return;
        }
        let busy = self
            .meetings
            .iter()
            .find(|m| self.data.read(cx).is_processing(m.id));
        if let Some(meeting) = busy {
            self.error = Some(
                lokalbot_core::merge::MergeError::ProcessingInProgress(meeting.display_title())
                    .localized()
                    .into(),
            );
            cx.notify();
            return;
        }
        self.working = true;
        self.error = None;
        cx.notify();
        let library = self.data.read(cx).library.clone();
        let meetings = self.meetings.clone();
        let title = self.title.read(cx).value().to_string();
        let summarize = self.summarize && self.has_transcript;
        let data = self.data.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_engine::library_ops::merge_meetings(&library, &meetings, &title)
                })
                .await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(merged) => {
                    data.update(cx, |data, cx| {
                        if summarize {
                            // A partial merged transcript must never satisfy the
                            // summary: transcribe the joined audio first.
                            data.request(
                                AppEvent::ProcessMeeting {
                                    meeting_id: merged.meeting.id,
                                    transcribe: !merged.transcript_coverage_complete,
                                    summarize: true,
                                },
                                cx,
                            );
                        }
                        data.reload(cx);
                        data.open_meeting(merged.meeting.id, MeetingTab::Summary, None, cx);
                    });
                    window.close_dialog(cx);
                }
                Err(err) => {
                    this.working = false;
                    this.error = Some(err.localized().into());
                    cx.notify();
                }
            });
        })
        .detach();
    }
}

impl Render for MergeSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let count = self.meetings.len().to_string();
        let total: f64 = self
            .meetings
            .iter()
            .map(|m| {
                let raw = m.duration_seconds();
                m.valid_content_range()
                    .map_or(raw, |r| r.end.min(raw) - r.start.min(raw))
            })
            .sum();
        let label = |text: &str| {
            div()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::MEDIUM)
                .text_color(lb.text_secondary)
                .child(crate::ui::text::paragraph(text.to_string()))
        };
        let sources = self.meetings.iter().enumerate().map(|(index, meeting)| {
            h_flex()
                .gap(px(10.))
                .items_center()
                .child(
                    div()
                        .flex_none()
                        .size(px(22.))
                        .rounded_full()
                        .bg(lb.accent_fill.opacity(0.14))
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_size(ty::CAPTION)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.accent_text)
                        .child((index + 1).to_string()),
                )
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .child(
                            div()
                                .truncate()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(meeting.display_title()),
                        )
                        .child(
                            div()
                                .truncate()
                                .text_size(ty::CAPTION)
                                .text_color(lb.text_secondary)
                                .child(format!(
                                    "{} · {}",
                                    crate::state::day_label(meeting.started_at),
                                    super::model::row_detail(meeting, false)
                                )),
                        ),
                )
        });
        let summarize = self.summarize;
        v_flex()
            .gap(px(14.))
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(crate::ui::icon_tile(crate::ui::Ico::Group, lb.accent_fill, px(32.)))
                    .child(
                        v_flex()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(ty::QUESTION)
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "Merge meetings",
                                    ))),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                        "Create one reviewable timeline from {count} recordings.",
                                        &[("count", count.clone())],
                                    ))),
                            ),
                    ),
            )
            .child(
                v_flex()
                    .gap(px(6.))
                    .child(label(lokalbot_i18n::tr("New meeting name")))
                    .child(Input::new(&self.title)),
            )
            .child(
                v_flex()
                    .gap(px(8.))
                    .child(
                        h_flex()
                            .justify_between()
                            .child(label(lokalbot_i18n::tr("Sources")))
                            .child(
                                div()
                                    .text_size(ty::CAPTION)
                                    .text_color(lb.text_secondary)
                                    .child(lokalbot_i18n::format(
                                        "{count} recordings · {duration}",
                                        &[
                                            ("count", count),
                                            (
                                                "duration",
                                                lokalbot_core::time::meeting_duration_label(total),
                                            ),
                                        ],
                                    )),
                            ),
                    )
                    .child(
                        v_flex()
                            .gap(px(8.))
                            .p(px(12.))
                            .rounded(px(10.))
                            .bg(lb.group_fill)
                            .border_1()
                            .border_color(lb.group_stroke)
                            .children(sources),
                    ),
            )
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_start()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "Generate a fresh combined summary",
                                    ))),
                            )
                            .child(
                                div()
                                    .text_size(ty::CAPTION)
                                    .text_color(lb.text_secondary)
                                    .child(crate::ui::text::paragraph(if self.has_transcript {
                                        lokalbot_i18n::tr(
                                            "Runs on the merged transcript after the new meeting is created.",
                                        )
                                    } else {
                                        lokalbot_i18n::tr(
                                            "No source transcript is available, so there is nothing to summarize yet.",
                                        )
                                    })),
                            ),
                    )
                    .child(
                        gpui_kit::component::switch::Switch::new("merge-summarize")
                            .checked(summarize && self.has_transcript)
                            .disabled(!self.has_transcript)
                            .on_click(cx.listener(|this, checked: &bool, _, cx| {
                                this.summarize = *checked;
                                cx.notify();
                            })),
                    ),
            )
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_start()
                    .child(crate::ui::icon(crate::ui::Ico::ShieldCheck, px(14.), lb.accent_text))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Original audio, transcripts, summaries, and speaker decisions stay preserved in their source folders. After the merge, those source rows are folded into one meeting, and each speaker keeps a source label so identities do not get mixed automatically.",
                            ))),
                    ),
            )
            .when_some(self.error.clone(), |this, error| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(crate::ui::text::paragraph(error)),
                )
            })
            .child(
                h_flex()
                    .gap_2()
                    .items_center()
                    .justify_end()
                    .child(
                        crate::ui::controls::bordered("merge-cancel", lokalbot_i18n::tr("Cancel"))
                            .disabled(self.working)
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(if self.working {
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(gpui_kit::component::spinner::Spinner::new().small())
                            .child(lokalbot_i18n::tr("Building merged meeting…"))
                            .into_any_element()
                    } else {
                        Button::new("merge-confirm")
                            .primary()
                            .label(lokalbot_i18n::tr("Merge meetings"))
                            .on_click(cx.listener(|this, _, window, cx| this.merge(window, cx)))
                            .into_any_element()
                    }),
            )
    }
}

/// "Undo this merge?" (`MeetingWorkspaceView`'s confirmation).
pub(crate) fn confirm_undo_merge(
    data: Entity<AppData>,
    meeting: &Meeting,
    window: &mut Window,
    cx: &mut App,
) {
    let id = meeting.id;
    let count = meeting
        .merged_source_meeting_ids
        .as_ref()
        .map_or(0, |ids| ids.len())
        .to_string();
    window.open_dialog(cx, move |dialog, _, cx| {
        let lb = cx.lb().clone();
        let data = data.clone();
        dialog
            .w(px(440.))
            .title(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .child(lokalbot_i18n::tr("Undo this merge?")),
            )
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                        "Remove this merged meeting and restore {count} original meetings? Their source folders will stay intact.",
                        &[("count", count.clone())],
                    ))),
            )
            .footer(
                h_flex()
                    .w_full()
                    .gap_2()
                    .justify_end()
                    .child(
                        crate::ui::controls::bordered("undo-merge-cancel", lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("undo-merge-confirm")
                            .danger()
                            .label(lokalbot_i18n::tr("Undo merge"))
                            .on_click(move |_, window, cx| {
                                data.update(cx, |data, cx| data.undo_merge(id, cx));
                                window.close_dialog(cx);
                            }),
                    ),
            )
    });
}

// ------------------------------------------------------------ boundaries

/// "Meeting boundaries" (`MeetingBoundaryEditor.swift`): which part of the
/// recording belongs to the meeting, on the original playback timeline.
pub(crate) struct BoundarySheet {
    data: Entity<AppData>,
    meeting: Meeting,
    start: Entity<InputState>,
    end: Entity<InputState>,
    working: bool,
    error: Option<SharedString>,
}

/// Seconds as typed: "150", "150.5", or "2:30".
fn parse_seconds(raw: &str) -> Option<f64> {
    let raw = raw.trim().replace(',', ".");
    raw.parse::<f64>()
        .ok()
        .filter(|v| v.is_finite())
        .or_else(|| lokalbot_core::time::parse_stamp(&raw))
}

fn seconds_text(value: f64) -> String {
    let text = format!("{value:.2}");
    text.trim_end_matches('0').trim_end_matches('.').to_string()
}

impl BoundarySheet {
    pub(crate) fn open(data: Entity<AppData>, meeting: Meeting, window: &mut Window, cx: &mut App) {
        let duration = meeting.duration_seconds();
        let range = meeting.valid_content_range();
        let start = range.map_or(0.0, |r| r.start);
        let end = range.map_or(duration, |r| r.end);
        let sheet = cx.new(|cx| Self {
            start: cx.new(|cx| InputState::new(window, cx).default_value(seconds_text(start))),
            end: cx.new(|cx| InputState::new(window, cx).default_value(seconds_text(end))),
            data,
            meeting,
            working: false,
            error: None,
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(480.)).close_button(false).child(sheet.clone())
        });
    }

    fn range(&self, cx: &App) -> Option<lokalbot_core::ContentRange> {
        let start = parse_seconds(&self.start.read(cx).value())?;
        let end = parse_seconds(&self.end.read(cx).value())?;
        Some(lokalbot_core::ContentRange { start, end }).filter(|r| r.is_valid())
    }

    fn use_full_recording(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let end = seconds_text(self.meeting.duration_seconds());
        self.start
            .update(cx, |input, cx| input.set_value("0", window, cx));
        self.end
            .update(cx, |input, cx| input.set_value(end, window, cx));
        cx.notify();
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.working {
            return;
        }
        let Some(range) = self.range(cx) else { return };
        if self.data.read(cx).is_processing(self.meeting.id) {
            self.error = Some(
                lokalbot_i18n::tr(
                    "Wait for meeting processing to finish before changing its boundaries.",
                )
                .into(),
            );
            cx.notify();
            return;
        }
        self.working = true;
        self.error = None;
        cx.notify();
        let library = self.data.read(cx).library.clone();
        let meeting = self.meeting.clone();
        let data = self.data.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_engine::library_ops::set_meeting_boundaries(&library, &meeting, range)
                })
                .await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(updated) => {
                    data.update(cx, |data, cx| {
                        data.request(
                            AppEvent::ProcessMeeting {
                                meeting_id: updated.id,
                                transcribe: true,
                                summarize: true,
                            },
                            cx,
                        );
                        data.reload(cx);
                    });
                    window.close_dialog(cx);
                }
                Err(err) => {
                    this.working = false;
                    this.error = Some(if err.is::<lokalbot_core::library::BoundaryError>() {
                        lokalbot_i18n::tr(
                            "Choose a start and end within the recorded audio, with the end after the start.",
                        )
                        .into()
                    } else {
                        lokalbot_i18n::format(
                            "The boundaries could not be saved. {err}",
                            &[("err", format!("{err:#}"))],
                        )
                        .into()
                    });
                    cx.notify();
                }
            });
        })
        .detach();
    }
}

impl Render for BoundarySheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let valid = self.range(cx).is_some();
        let field = |label: &str, input: &Entity<InputState>| {
            v_flex()
                .flex_1()
                .gap(px(6.))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(label.to_string())),
                )
                .child(Input::new(input))
        };
        v_flex()
            .gap(px(14.))
            .child(
                div()
                    .text_size(ty::QUESTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Meeting boundaries"))),
            )
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Keep the part that belongs to this meeting. Transcripts, summaries, and search will be rebuilt. The full audio stays available for playback.",
                    ))),
            )
            .child(
                h_flex()
                    .gap(px(12.))
                    .child(field(lokalbot_i18n::tr("Start (seconds)"), &self.start))
                    .child(field(lokalbot_i18n::tr("End (seconds)"), &self.end)),
            )
            .child(
                div()
                    .text_size(ty::CAPTION)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Use the original playback timeline; for example, 2:30 is 150 seconds.",
                    ))),
            )
            .when_some(self.error.clone(), |this, error| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(crate::ui::text::paragraph(error)),
                )
            })
            .child(
                h_flex()
                    .gap_2()
                    .items_center()
                    .child(
                        Button::new("boundaries-full")
                            .ghost()
                            .label(lokalbot_i18n::tr("Use full recording"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.use_full_recording(window, cx)
                            })),
                    )
                    .child(div().flex_1())
                    .child(
                        crate::ui::controls::bordered("boundaries-cancel", lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("boundaries-save")
                            .primary()
                            .label(lokalbot_i18n::tr("Save & rebuild"))
                            .disabled(!valid || self.working)
                            .on_click(cx.listener(|this, _, window, cx| this.save(window, cx))),
                    ),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boundary_times_accept_seconds_and_clock_times() {
        assert_eq!(parse_seconds("150"), Some(150.0));
        assert_eq!(parse_seconds(" 12,5 "), Some(12.5));
        assert_eq!(parse_seconds("2:30"), Some(150.0));
        assert_eq!(parse_seconds("1:00:00"), Some(3_600.0));
        assert_eq!(parse_seconds("soon"), None);
        assert_eq!(seconds_text(851.5), "851.5");
        assert_eq!(seconds_text(900.0), "900");
    }
}
