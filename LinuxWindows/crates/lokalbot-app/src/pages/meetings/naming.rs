//! One sheet to name a meeting's unnamed voices (`MeetingSpeakerNamingSheet`):
//! play a sample, read what that voice said, then pick an invited name or
//! type one. Names are saved together, each as if that speaker had been named
//! on its own; a voice left alone stays unnamed. A voice recognized from
//! earlier meetings starts picked and is applied only when the person saves.

use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use gpui_kit::component::WindowExt as _;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, WeakEntity, Window, div, px, white,
};
use lokalbot_core::calendar::SpeakerSuggestion;
use lokalbot_core::{Meeting, Transcript};

use super::MeetingsPage;
use super::model::MeetingDoc;
use super::presentation::{self, NamingDraft, NamingKnown, NamingVoice, Pick};
use crate::i18n::h_flex;
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui;

pub(crate) struct NamingSheet {
    data: Entity<AppData>,
    meeting: Meeting,
    transcript: Transcript,
    voices: Vec<NamingVoice>,
    known: Vec<NamingKnown>,
    suggestions: Vec<SpeakerSuggestion>,
    /// Guests already assigned to a voice in this meeting.
    assigned: HashSet<String>,
    draft: NamingDraft,
    /// A name field per voice switched to "Someone else…".
    typed: HashMap<String, Entity<InputState>>,
    can_play: bool,
    busy: bool,
    notice: Option<String>,
    error: Option<SharedString>,
    page: WeakEntity<MeetingsPage>,
}

impl NamingSheet {
    pub(crate) fn open(
        data: Entity<AppData>,
        doc: Rc<MeetingDoc>,
        can_play: bool,
        page: WeakEntity<MeetingsPage>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let Some(transcript) = doc.transcript.clone() else {
            return;
        };
        let recognized: HashMap<String, String> = doc
            .recognized
            .iter()
            .map(|(label, found)| (label.clone(), found.name.clone()))
            .collect();
        let (voices, known) = presentation::naming_lists(
            &doc.speakers,
            &doc.review,
            &doc.speech,
            &recognized,
            &doc.recognized_before,
        );
        let draft = NamingDraft::new(&voices, &doc.suggestions);
        let assigned = transcript
            .speaker_calendar_identity_ids
            .values()
            .cloned()
            .collect();
        let sheet = cx.new(|_| Self {
            data,
            meeting: doc.meeting.clone(),
            transcript,
            voices,
            known,
            suggestions: doc.suggestions.clone(),
            assigned,
            draft,
            typed: HashMap::new(),
            can_play,
            busy: false,
            notice: doc.speaker_notice.clone(),
            error: None,
            page,
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(600.)).close_button(false).child(sheet.clone())
        });
    }

    fn typed_name(&self, speaker: &str, cx: &App) -> String {
        self.typed
            .get(speaker)
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_default()
    }

    fn choices(&self, cx: &App) -> Vec<presentation::NamingChoice> {
        self.draft
            .choices(self.voices.iter().map(|v| v.key.as_str()), |speaker| {
                self.typed_name(speaker, cx)
            })
    }

    fn begin_typing(&mut self, speaker: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.draft.type_name(speaker);
        if self.draft.is_typing(speaker) {
            let input = match self.typed.get(speaker) {
                Some(input) => input.clone(),
                None => {
                    let input = cx.new(|cx| {
                        InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                            "Name this speaker",
                            window,
                            cx,
                        ))
                    });
                    // Typing enables Save names; Return saves, as the sheet's
                    // default button does.
                    cx.subscribe_in(&input, window, |this, _, event: &InputEvent, window, cx| {
                        match event {
                            InputEvent::Change => cx.notify(),
                            InputEvent::PressEnter { .. } => this.save(window, cx),
                            _ => {}
                        }
                    })
                    .detach();
                    self.typed.insert(speaker.to_string(), input.clone());
                    input
                }
            };
            input.update(cx, |input, cx| input.focus(window, cx));
        }
        cx.notify();
    }

    fn play(&mut self, start: f64, cx: &mut Context<Self>) {
        let _ = self
            .page
            .update(cx, |page, cx| page.play_excerpt(start, start + 12., cx));
    }

    /// A named speaker picked from the sheet is renamed once it closes.
    fn change(&mut self, speaker: String, window: &mut Window, cx: &mut Context<Self>) {
        window.close_dialog(cx);
        let page = self.page.clone();
        window.defer(cx, move |window, cx| {
            let _ = page.update(cx, |page, cx| {
                page.open_name_speaker_key(&speaker, window, cx)
            });
        });
    }

    /// Saves every name picked, one at a time as if each speaker had been
    /// named on its own; a failure midway leaves the earlier ones saved.
    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        use lokalbot_core::voice::{Choice, DecisionAction};
        let choices = self.choices(cx);
        if self.busy || choices.is_empty() {
            return;
        }
        // The same check as naming one speaker: a person's name, never an
        // address, link or secret.
        if choices.iter().any(|choice| {
            lokalbot_core::voice::safe_name(&choice.name, &|text| {
                lokalbot_ai::sanitize::redaction(text).1 > 0
            })
            .is_none()
        }) {
            self.error = Some(
                lokalbot_i18n::tr("Enter a person's name, not an address, link or secret.").into(),
            );
            cx.notify();
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let library = self.data.read(cx).library.clone();
        let meeting = self.meeting.clone();
        let transcript = self.transcript.clone();
        let data = self.data.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    let mut current = transcript;
                    for choice in choices {
                        let mut decision =
                            Choice::new(&choice.speaker, Some(choice.name), DecisionAction::Assign);
                        // The chosen guest's opaque id, never the address.
                        decision.calendar_identity_id = choice.calendar_identity_id;
                        current = lokalbot_engine::voice::save_choice(
                            &library, &decision, &meeting, &current,
                        )?;
                    }
                    anyhow::Ok(current)
                })
                .await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.busy = false;
                data.update(cx, |data, cx| {
                    data.mark_library_changed(cx);
                    if result.is_ok() {
                        // A newly remembered voice can name speakers in
                        // other recent meetings.
                        data.request(crate::state::AppEvent::LearnSpeakerVoices, cx);
                    }
                });
                match result {
                    Ok(_) => window.close_dialog(cx),
                    Err(err) => {
                        this.error = Some(
                            lokalbot_i18n::format(
                                "Could not save speaker names: {err}",
                                &[("err", format!("{err:#}"))],
                            )
                            .into(),
                        );
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// Dimmed, and still a choice: the guest already names another voice.
    fn is_used(&self, suggestion: &SpeakerSuggestion, speaker: &str) -> bool {
        self.draft.is_taken_elsewhere(&suggestion.id, speaker)
            || suggestion
                .calendar
                .as_ref()
                .is_some_and(|guest| self.assigned.contains(&guest.id))
    }

    /// "12 min of speech · 2 actions".
    fn speech_summary(voice: &NamingVoice) -> String {
        let speech = lokalbot_i18n::tr("%lld min of speech").replace(
            "%lld",
            &presentation::speech_minutes(voice.speech_seconds).to_string(),
        );
        match voice.action_count {
            0 => speech,
            1 => format!("{speech} · {}", lokalbot_i18n::tr("1 action")),
            many => format!(
                "{speech} · {}",
                lokalbot_i18n::tr("%lld actions").replace("%lld", &lokalbot_i18n::number(many))
            ),
        }
    }

    fn chip(
        &self,
        id: SharedString,
        label: String,
        pick: Pick,
        speaker: &str,
        dimmed: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let selected = self.draft.is_picked(&pick.id, speaker);
        let speaker = speaker.to_string();
        name_chip(id, label, selected, cx)
            .when(dimmed && !selected, |this| this.opacity(0.45))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.draft.toggle(pick.clone(), &speaker);
                cx.notify();
            }))
            .into_any_element()
    }

    fn voice_row(&self, ix: usize, voice: &NamingVoice, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let can_play = voice.sample.is_some() && self.can_play;
        let start = voice.sample.as_ref().map(|(start, _)| *start).unwrap_or(0.);
        let named: Vec<&SpeakerSuggestion> = self
            .suggestions
            .iter()
            .filter(|s| s.name.is_some())
            .collect();
        let mut chips: Vec<AnyElement> = Vec::new();
        // A recognized voice that is also a guest is that guest's chip,
        // already picked; otherwise it gets a chip of its own.
        if let Some(recognized) = &voice.recognized_name {
            let pick = presentation::recognized_pick(recognized, &voice.key, &self.suggestions);
            if !named.iter().any(|s| s.id == pick.id) {
                let tooltip: SharedString =
                    lokalbot_i18n::tr("Recognized from earlier meetings").into();
                chips.push(
                    div()
                        .id(("naming-recognized-tip", ix))
                        .child(self.chip(
                            format!("naming-recognized-{ix}").into(),
                            recognized.clone(),
                            pick,
                            &voice.key,
                            false,
                            cx,
                        ))
                        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
                        .into_any_element(),
                );
            }
        }
        if named.iter().any(|s| s.calendar.is_some()) {
            chips.push(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(lokalbot_i18n::tr("Invited"))
                    .into_any_element(),
            );
        }
        for (suggestion_ix, suggestion) in named.iter().enumerate() {
            let pick = Pick {
                id: suggestion.id.clone(),
                name: suggestion.name.clone().unwrap_or_default(),
                calendar_identity_id: suggestion.calendar.as_ref().map(|guest| guest.id.clone()),
            };
            let dimmed = self.is_used(suggestion, &voice.key);
            chips.push(self.chip(
                format!("naming-choice-{ix}-{suggestion_ix}").into(),
                pick.name.clone(),
                pick,
                &voice.key,
                dimmed,
                cx,
            ));
        }
        let typing = self.draft.is_typing(&voice.key);
        let key = voice.key.clone();
        chips.push(
            name_chip(
                format!("naming-other-{ix}").into(),
                lokalbot_i18n::tr("Someone else…").to_string(),
                typing,
                cx,
            )
            .on_click(cx.listener(move |this, _, window, cx| this.begin_typing(&key, window, cx)))
            .into_any_element(),
        );
        h_flex()
            .w_full()
            .items_start()
            .gap(px(12.))
            .py(px(12.))
            .child(
                div()
                    .id(("naming-play", ix))
                    .flex_none()
                    .size(px(26.))
                    .rounded_full()
                    .bg(lb.accent_fill)
                    .flex()
                    .items_center()
                    .justify_center()
                    .when(!can_play, |this| this.opacity(0.4))
                    .when(can_play, |this| {
                        this.cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| this.play(start, cx)))
                    })
                    .child(crate::ui::waveform::play_glyph(px(10.), white()))
                    .tooltip(|window, cx| {
                        Tooltip::new(lokalbot_i18n::tr("Play Voice")).build(window, cx)
                    }),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(6.))
                    .child(
                        h_flex()
                            .gap(px(7.))
                            .items_center()
                            .child(ui::status_dot(
                                super::speaker_color(voice.color, cx),
                                px(7.),
                            ))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(voice.label.clone()),
                            )
                            .child(
                                div()
                                    .flex_none()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(Self::speech_summary(voice)),
                            ),
                    )
                    .when_some(voice.sample.clone(), |this, (_, text)| {
                        this.child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .line_clamp(3)
                                .child(format!("“{text}”")),
                        )
                    })
                    .child(
                        h_flex()
                            .flex_wrap()
                            .gap(px(6.))
                            .items_center()
                            .children(chips),
                    )
                    .when_some(
                        self.typed.get(&voice.key).filter(|_| typing).cloned(),
                        |this, input| {
                            this.child(div().max_w(px(280.)).child(Input::new(&input).small()))
                        },
                    ),
            )
            .into_any_element()
    }

    fn known_row(&self, ix: usize, known: &NamingKnown, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let key = known.key.clone();
        h_flex()
            .w_full()
            .gap(px(7.))
            .items_center()
            .pl(px(26. + 12.))
            .py(px(12.))
            .child(ui::status_dot(
                super::speaker_color(known.color, cx),
                px(7.),
            ))
            .child(
                div()
                    .flex_none()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(known.name.clone()),
            )
            .when(known.was_recognized, |this| {
                this.child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .child(lokalbot_i18n::tr("Recognized from earlier meetings")),
                )
            })
            .child(div().flex_1())
            .child(
                div().flex_none().child(
                    ui::link(
                        ("naming-change", ix),
                        lokalbot_i18n::tr("Change…"),
                        {
                            let sheet = cx.entity().downgrade();
                            move |window, cx| {
                                let key = key.clone();
                                let _ = sheet.update(cx, |this, cx| this.change(key, window, cx));
                            }
                        },
                        cx,
                    )
                    .text_size(ty::SECONDARY),
                ),
            )
            .into_any_element()
    }
}

/// A rounded name choice: outlined, filled with the accent once picked.
fn name_chip(
    id: SharedString,
    label: String,
    selected: bool,
    cx: &Context<NamingSheet>,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let lb = cx.lb();
    let hover = lb.hover;
    div()
        .id(id)
        .flex_none()
        .px(px(10.))
        .py(px(4.))
        .rounded(px(10.))
        .border_1()
        .cursor_pointer()
        .text_size(ty::SECONDARY)
        .when(selected, |this| {
            this.bg(lb.accent_fill)
                .border_color(lb.accent_fill)
                .text_color(white())
                .font_weight(FontWeight::SEMIBOLD)
        })
        .when(!selected, |this| {
            this.border_color(lb.text.opacity(0.18))
                .text_color(lb.text)
                .hover(move |s| s.bg(hover))
        })
        .child(div().truncate().child(label))
}

impl Render for NamingSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let voices = self.voices.clone();
        let known = self.known.clone();
        let mut rows: Vec<AnyElement> = Vec::new();
        for (ix, voice) in voices.iter().enumerate() {
            rows.push(self.voice_row(ix, voice, cx));
            rows.push(ui::divider(cx).into_any_element());
        }
        for (ix, speaker) in known.iter().enumerate() {
            rows.push(self.known_row(ix, speaker, cx));
            rows.push(ui::divider(cx).into_any_element());
        }
        let can_save = !self.choices(cx).is_empty() && !self.busy;
        let footer_note: SharedString = self
            .error
            .clone()
            .or_else(|| {
                self.notice
                    .clone()
                    .map(|n| lokalbot_i18n::tr(&n).to_string().into())
            })
            .unwrap_or_else(|| lokalbot_i18n::tr("Skip any voice you are not sure about.").into());
        v_flex()
            .id("meeting-naming-sheet")
            .child(
                v_flex()
                    .gap(px(4.))
                    .pb(px(10.))
                    .child(
                        div()
                            .text_size(ty::QUESTION)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(lokalbot_i18n::tr("Name speakers")),
                    )
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.supporting)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Play a voice, then pick who it is. LokalBot learns each voice for later meetings. Voices stay encrypted on this computer.",
                            ))),
                    ),
            )
            .child(
                div()
                    .id("meeting-naming-list")
                    .max_h(px(420.))
                    .overflow_y_scrollbar()
                    .child(v_flex().w_full().children(rows)),
            )
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .pt(px(12.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(if self.error.is_some() {
                                lb.attention_text
                            } else {
                                lb.supporting
                            })
                            .child(crate::ui::text::paragraph(footer_note)),
                    )
                    .child(
                        crate::ui::controls::bordered("meeting-naming-cancel", lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("meeting-naming-save")
                            .primary()
                            .label(lokalbot_i18n::tr("Save names"))
                            .disabled(!can_save)
                            .on_click(cx.listener(|this, _, window, cx| this.save(window, cx))),
                    ),
            )
    }
}
