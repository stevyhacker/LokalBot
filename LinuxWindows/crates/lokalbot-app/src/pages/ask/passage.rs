//! The passage a citation points at, read in place (`CitationPassagePopover`):
//! the source, its time and speaker, the quote, then a button to play from
//! there or show the file, and one to open the source. Nothing leaves Ask
//! until one of those is used. Everything shown is already stored here.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, Div, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Pixels, Point, StatefulInteractiveElement as _, Styled as _, Task, Window,
    anchored, deferred, div, point, px,
};
use lokalbot_audio::Player;
use lokalbot_core::{Meeting, ScreenMoment};
use uuid::Uuid;

use super::AskPage;
use super::model::{self, PassageLine};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::citations::{self, CitationSource};
use crate::ui::{self, Ico, screen_thumbnail};

/// What a passage shows once its source is read.
pub(super) enum PassageContent {
    Loading,
    Meeting {
        meeting: Box<Meeting>,
        line: Option<PassageLine>,
    },
    Screen {
        moment: Box<ScreenMoment>,
        text: Option<String>,
    },
    File(Box<lokalbot_core::files::FileHit>),
    Note(Box<lokalbot_core::agent_notes::NoteHit>),
    Unavailable,
}

/// Which citation's passage is showing, and where it was opened.
pub(super) struct OpenPassage {
    /// The answer whose number was clicked.
    pub answer: Uuid,
    /// 1-based, as the answer shows it.
    pub number: usize,
    pub citation: CitationSource,
    /// Where the number was clicked, in window coordinates.
    pub at: Point<Pixels>,
    pub content: PassageContent,
    player: Option<Arc<Player>>,
    playing: bool,
    poll: Option<Task<()>>,
}

const WIDTH: f32 = 372.;
/// A screen moment's text is quoted shorter than a transcript line.
const SHORT_QUOTE: usize = 280;

impl AskPage {
    /// Shows the passage behind citation `number` of `answer`, or hides it when
    /// it is the one showing.
    pub(super) fn toggle_passage(
        &mut self,
        answer: Uuid,
        number: usize,
        citation: CitationSource,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let same = self
            .passage
            .as_ref()
            .is_some_and(|open| open.answer == answer && open.number == number);
        // The press that reached this number already closed its passage.
        let just_closed = self.passage_dismissed.take().is_some_and(|(at, key)| {
            key == (answer, number) && at.elapsed() < Duration::from_millis(600)
        });
        self.close_passage(cx);
        if same || just_closed {
            return;
        }
        self.passage = Some(OpenPassage {
            answer,
            number,
            citation: citation.clone(),
            at: window.mouse_position(),
            content: PassageContent::Loading,
            player: None,
            playing: false,
            poll: None,
        });
        self.load_passage(answer, number, citation, cx);
        cx.notify();
    }

    pub(super) fn close_passage(&mut self, cx: &mut Context<Self>) {
        if let Some(open) = self.passage.take()
            && let Some(player) = open.player
        {
            player.pause();
        }
        cx.notify();
    }

    pub(super) fn passage_is_open(&self, answer: Uuid, number: usize) -> bool {
        self.passage
            .as_ref()
            .is_some_and(|open| open.answer == answer && open.number == number)
    }

    fn load_passage(
        &mut self,
        answer: Uuid,
        number: usize,
        citation: CitationSource,
        cx: &mut Context<Self>,
    ) {
        let (library, meetings, files_on, notes_on, root) = {
            let data = self.data.read(cx);
            (
                data.library.clone(),
                data.meetings.clone(),
                data.settings.file_search_enabled,
                data.settings.coding_agent_notes_enabled,
                data.library.paths().root().to_path_buf(),
            )
        };
        cx.spawn(async move |this, cx| {
            let (content, player) = cx
                .background_spawn(async move {
                    match citation {
                        CitationSource::Meeting { id, at } => {
                            let Some(meeting) = citations::resolve_meeting(&id, &meetings).cloned()
                            else {
                                return (PassageContent::Unavailable, None);
                            };
                            let line = at.and_then(|seconds| {
                                let transcript = library.transcript(&meeting).ok().flatten()?;
                                let lines: Vec<PassageLine> = transcript
                                    .segments
                                    .iter()
                                    .map(|segment| PassageLine {
                                        start: segment.start,
                                        end: segment.end,
                                        speaker: super::search::speaker_label(
                                            &transcript.speaker_name(&segment.speaker),
                                        ),
                                        text: segment.text.clone(),
                                    })
                                    .collect();
                                model::passage_line(seconds, &lines).cloned()
                            });
                            let player = line.as_ref().and_then(|_| {
                                let audio = library.audio(&meeting);
                                if audio.mic.is_none() && audio.system.is_none() {
                                    return None;
                                }
                                Player::open(audio.mic.as_deref(), audio.system.as_deref())
                                    .inspect_err(|err| log::warn!("passage audio: {err:#}"))
                                    .ok()
                                    .map(Arc::new)
                            });
                            (
                                PassageContent::Meeting {
                                    meeting: Box::new(meeting),
                                    line,
                                },
                                player,
                            )
                        }
                        CitationSource::Screen { snapshot_id } => {
                            match library.screen_moment(snapshot_id).ok().flatten() {
                                Some(moment) => (
                                    PassageContent::Screen {
                                        moment: Box::new(moment),
                                        text: library.screen_text(snapshot_id, 1_200),
                                    },
                                    None,
                                ),
                                None => (PassageContent::Unavailable, None),
                            }
                        }
                        // Files and notes are read only while they are on, as on
                        // the rest of the page.
                        CitationSource::File { id } => {
                            let hit = files_on
                                .then(|| {
                                    citations::known_file_citation(id).flatten().or_else(|| {
                                        lokalbot_core::files::search::FileReader::shared(&root)
                                            .hit(id)
                                    })
                                })
                                .flatten();
                            (
                                hit.map_or(PassageContent::Unavailable, |hit| {
                                    PassageContent::File(Box::new(hit))
                                }),
                                None,
                            )
                        }
                        CitationSource::Note { id } => {
                            let hit = notes_on
                                .then(|| {
                                    lokalbot_core::agent_notes::NotesIndex::new(&root)
                                        .hit(&id)
                                        .ok()
                                        .flatten()
                                })
                                .flatten();
                            (
                                hit.map_or(PassageContent::Unavailable, |hit| {
                                    PassageContent::Note(Box::new(hit))
                                }),
                                None,
                            )
                        }
                    }
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Some(open) = this.passage.as_mut()
                    && open.answer == answer
                    && open.number == number
                {
                    open.content = content;
                    open.player = player;
                    cx.notify();
                } else if let Some(player) = player {
                    player.pause();
                }
            });
        })
        .detach();
    }

    /// "Play from 0:12" / "Pause" (`player.playExcerpt`).
    fn toggle_passage_audio(&mut self, cx: &mut Context<Self>) {
        let Some(open) = self.passage.as_mut() else {
            return;
        };
        let (
            Some(player),
            PassageContent::Meeting {
                line: Some(line), ..
            },
        ) = (open.player.clone(), &open.content)
        else {
            return;
        };
        if open.playing && player.is_playing() {
            player.pause();
            open.playing = false;
            open.poll = None;
            cx.notify();
            return;
        }
        if let Err(err) = player.play_range(line.start, line.end) {
            let message = format!("{err:#}");
            self.data
                .update(cx, |data, cx| data.show_error(message, cx));
            return;
        }
        open.playing = true;
        open.poll = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(200))
                    .await;
                let playing = this
                    .update(cx, |this, cx| {
                        let Some(open) = this.passage.as_mut() else {
                            return false;
                        };
                        let still = open.player.as_ref().is_some_and(|p| p.is_playing());
                        if !still {
                            open.playing = false;
                            cx.notify();
                        }
                        still
                    })
                    .unwrap_or(false);
                if !playing {
                    break;
                }
            }
        }));
        cx.notify();
    }

    /// The open passage, drawn above everything at the clicked number.
    pub(super) fn render_passage(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let open = self.passage.as_ref()?;
        let lb = cx.lb().clone();
        let at = open.at;
        let now = chrono::Local::now();
        let mut card = v_flex()
            .id("ask-passage")
            .occlude()
            .w(px(WIDTH))
            .gap(px(10.))
            .p(px(14.))
            .rounded(px(10.))
            .bg(lb.panel)
            .border_1()
            .border_color(lb.separator)
            .shadow_lg()
            .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                this.passage_dismissed = this
                    .passage
                    .as_ref()
                    .map(|open| (Instant::now(), (open.answer, open.number)));
                this.close_passage(cx)
            }));
        card = match &open.content {
            PassageContent::Loading => card.child(
                h_flex()
                    .w_full()
                    .min_h(px(60.))
                    .justify_center()
                    .child(Spinner::new().small().color(lb.text_secondary)),
            ),
            PassageContent::Unavailable => card.child(
                div()
                    .w_full()
                    .min_h(px(40.))
                    .text_size(ty::BODY)
                    .text_color(lb.supporting)
                    .child(lokalbot_i18n::tr("Unavailable")),
            ),
            PassageContent::Meeting { meeting, line } => {
                let stamp = line
                    .as_ref()
                    .map(|line| line.start)
                    .or(match &open.citation {
                        CitationSource::Meeting { at, .. } => *at,
                        _ => None,
                    })
                    .map(ui::action_row::short_stamp);
                let meta = [
                    Some(model::day_label(meeting.started_at, now)),
                    stamp.clone(),
                    line.as_ref().map(|line| line.speaker.clone()),
                ];
                let quote = line
                    .as_ref()
                    .and_then(|line| model::quote(Some(&line.text), model::QUOTE_LIMIT))
                    .map(|text| format!("“{text}”"));
                let can_play = open.player.is_some()
                    && line.as_ref().is_some_and(|line| line.end > line.start);
                let playing = open.playing;
                let meeting_id = meeting.id;
                let at = match &open.citation {
                    CitationSource::Meeting { at, .. } => *at,
                    _ => None,
                };
                card.child(passage_header(
                    super::matches::source_tile(Ico::AudioLines, px(44.), px(30.), &lb),
                    meeting.display_title(),
                    &meta,
                    &lb,
                ))
                .when_some(quote, |this, quote| this.child(quote_block(quote, &lb)))
                .child(
                    h_flex()
                        .w_full()
                        .gap(px(8.))
                        .items_center()
                        .when_some(stamp.filter(|_| line.is_some()), |this, stamp| {
                            this.child(
                                Button::new("ask-passage-play")
                                    .outline()
                                    .small()
                                    .icon(Icon::new(if playing { Ico::Pause } else { Ico::Play }))
                                    .label(if playing {
                                        lokalbot_i18n::tr("Pause").to_string()
                                    } else {
                                        model::mac("Play from %@", &[&stamp])
                                    })
                                    .disabled(!can_play)
                                    .on_click(
                                        cx.listener(|this, _, _, cx| this.toggle_passage_audio(cx)),
                                    ),
                            )
                        })
                        .child(div().flex_1())
                        .child(self.open_link(
                            "Open in meeting",
                            move |this, cx| this.open_meeting(meeting_id, at, cx),
                            cx,
                        )),
                )
            }
            PassageContent::Screen { moment, text } => {
                let title = if moment.window_title.trim().is_empty() {
                    moment.app.clone()
                } else {
                    moment.window_title.clone()
                };
                let meta = [
                    (!moment.window_title.trim().is_empty()).then(|| moment.app.clone()),
                    Some(model::moment_label(moment.ts, now)),
                ];
                let image = self
                    .thumbnails
                    .image(moment.as_ref(), cx, |page| &page.thumbnails);
                let opened = moment.as_ref().clone();
                card.child(passage_header(
                    super::matches::source_tile(Ico::Monitor, px(44.), px(30.), &lb),
                    title,
                    &meta,
                    &lb,
                ))
                .when(!moment.path.is_empty(), |this| {
                    this.child(screen_thumbnail::tile(
                        image,
                        moment,
                        px(WIDTH - 28.),
                        px(132.),
                        cx,
                    ))
                })
                .when_some(model::quote(text.as_deref(), SHORT_QUOTE), |this, quote| {
                    this.child(quote_block(quote, &lb))
                })
                .child(
                    h_flex()
                        .w_full()
                        .child(div().flex_1())
                        .child(self.open_link(
                            "Show in Timeline",
                            move |this, cx| super::open_screen_moment(&this.data, &opened, cx),
                            cx,
                        )),
                )
            }
            PassageContent::File(hit) => {
                let meta = [Some(hit.folder()), Some(model::day_label(hit.date(), now))];
                let (opened, revealed) = (hit.as_ref().clone(), hit.path.clone());
                card.child(passage_header(
                    div()
                        .w(px(44.))
                        .h(px(30.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(ui::icon(
                            super::search::file_icon(hit.kind),
                            px(24.),
                            lb.text_secondary,
                        ))
                        .into_any_element(),
                    hit.name(),
                    &meta,
                    &lb,
                ))
                .when_some(
                    model::quote(hit.excerpt.as_deref(), model::QUOTE_LIMIT),
                    |this, quote| this.child(quote_block(quote, &lb)),
                )
                .child(
                    h_flex()
                        .w_full()
                        .gap(px(8.))
                        .items_center()
                        .child(reveal_button(revealed))
                        .child(div().flex_1())
                        .child(self.open_link(
                            "Open",
                            move |_, _| super::search::open_file(&opened),
                            cx,
                        )),
                )
            }
            PassageContent::Note(hit) => {
                let meta = [
                    Some(hit.source_label()),
                    Some(model::day_label(hit.modified, now)),
                ];
                let (opened, revealed) = (hit.as_ref().clone(), hit.path.clone());
                let quote = model::quote(
                    Some(hit.summary.as_deref().unwrap_or(&hit.snippet)),
                    SHORT_QUOTE,
                );
                card.child(passage_header(
                    super::matches::source_tile(Ico::FileText, px(44.), px(30.), &lb),
                    hit.title.clone(),
                    &meta,
                    &lb,
                ))
                .when_some(quote, |this, quote| this.child(quote_block(quote, &lb)))
                .child(
                    h_flex()
                        .w_full()
                        .gap(px(8.))
                        .items_center()
                        .child(reveal_button(revealed))
                        .child(div().flex_1())
                        .child(self.open_link(
                            "Open",
                            move |_, _| super::search::open_note(&opened),
                            cx,
                        )),
                )
            }
        };
        Some(
            deferred(
                anchored()
                    .position(point(at.x - px(24.), at.y + px(18.)))
                    .snap_to_window_with_margin(px(8.))
                    .child(card),
            )
            .with_priority(2)
            .into_any_element(),
        )
    }

    /// "Open in meeting", "Show in Timeline" or "Open": closes the passage,
    /// then opens the source.
    fn open_link(
        &self,
        key: &'static str,
        open: impl Fn(&mut Self, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Stateful<Div> {
        let lb = cx.lb().clone();
        div()
            .id("ask-passage-open")
            .flex_none()
            .cursor_pointer()
            .text_size(ty::SECONDARY)
            .text_color(lb.accent_text)
            .hover(|style| style.underline())
            .child(lokalbot_i18n::tr(key))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.close_passage(cx);
                open(this, cx);
            }))
    }
}

fn passage_header(
    lead: AnyElement,
    title: String,
    meta: &[Option<String>],
    lb: &crate::theme::Palette,
) -> Div {
    let meta: Vec<String> = meta
        .iter()
        .flatten()
        .filter(|part| !part.is_empty())
        .cloned()
        .collect();
    h_flex()
        .w_full()
        .gap(px(10.))
        .items_center()
        .child(lead)
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(1.))
                .child(
                    div()
                        .truncate()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(title),
                )
                .child(
                    div()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .child(meta.join(" · ")),
                ),
        )
}

fn quote_block(text: String, lb: &crate::theme::Palette) -> Div {
    div()
        .w_full()
        .pl(px(10.))
        .border_l_2()
        .border_color(lb.accent_fill.opacity(0.35))
        .text_size(ty::BODY)
        .line_height(px(20.))
        .text_color(lb.text)
        .child(ui::text::paragraph(text))
}

fn reveal_button(path: String) -> Button {
    Button::new("ask-passage-reveal")
        .outline()
        .small()
        .label(lokalbot_i18n::tr("Show in folder"))
        .on_click(move |_, _, _| {
            if let Err(err) =
                lokalbot_platform::opener::reveal_in_file_manager(std::path::Path::new(&path))
            {
                log::warn!("could not show a file: {err:#}");
            }
        })
}
