//! Quick Recall (`QuickRecallView.swift`, `QuickRecallRow.swift`,
//! `QuickRecallFooter.swift`): a 660×480 search and command panel over meetings
//! and screen memory. Typing a command runs it on Return, like a launcher. Return
//! opens the selected result in the main window, Ctrl+Return opens Ask with the
//! query, Escape or leaving the panel closes it. Reopened while an answer is being
//! written, it shows that conversation (`ChatTranscriptView`, the same one Ask
//! shows), with follow-ups inside its latest question's scope.

use std::time::Duration;

use crate::i18n::h_flex;
use chrono::{DateTime, Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Escape, Input, InputEvent, InputState, MoveDown, MoveUp};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Entity, FontWeight, Hsla,
    InteractiveElement as _, IntoElement, ObjectFit, ParentElement as _, Render, ScrollHandle,
    SharedString, StatefulInteractiveElement as _, Styled as _, StyledImage as _, Subscription,
    Task, Window, WindowBounds, WindowKind, WindowOptions, div, img, px, size,
};
use lokalbot_core::ScreenMoment;
use uuid::Uuid;

use crate::pages::ask::search::{self, Hit, MeetingGroup, ScreenResult};
use crate::pages::ask::{AskPage, composer_inference, open_screen_moment, stop_answer_speech};
use crate::palette::{self, Matching, PaletteCommand};
use crate::state::{AppData, AppEvent, AskRequest, MeetingTab, Section};
use crate::theme::{FONT_FAMILY, LbThemeExt as _, metric, ty};
use crate::ui::screen_thumbnail::ScreenThumbnails;
use crate::ui::{self, Ico, result_row};
use crate::windows::screen_image::ScreenImage;

const WIDTH: f32 = 660.;
const HEIGHT: f32 = 480.;
/// Saved moments to look through, and how many show with no query.
const SAVED_MOMENTS: usize = 200;
const SAVED_ROWS: usize = 12;
const SUGGESTIONS: [&str; 3] = [
    "What did we decide in my last meeting?",
    "List my recent meetings",
    "Search my meetings for action items",
];

/// Opens Quick Recall, or brings the open panel forward with its text selected.
pub fn open(cx: &mut App) {
    let existing = super::secondary(cx).quick_recall;
    if super::activate(existing, cx) {
        let view = super::secondary(cx)
            .quick_recall_view
            .clone()
            .and_then(|view| view.upgrade());
        if let (Some(handle), Some(view)) = (existing, view) {
            let _ = handle.update(cx, |_, window, cx| {
                view.update(cx, |view, cx| view.focus_input(window, cx))
            });
        }
        return;
    }
    let bounds = Bounds::centered(None, size(px(WIDTH), px(HEIGHT)), cx);
    let options = |kind| WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: true,
        show: true,
        kind,
        is_resizable: false,
        is_minimizable: false,
        app_id: Some(lokalbot_platform::APP_ID.into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..Default::default()
    };
    // Windows takes a borderless, topmost tool window; X11 only gives
    // keyboard focus to managed windows, so Linux uses a normal one.
    let window_kind = || {
        if cfg!(target_os = "windows") {
            WindowKind::PopUp
        } else {
            WindowKind::Normal
        }
    };
    // On Wayland, a centered layer surface that takes the keyboard: a tiling
    // compositor would otherwise split the screen with it.
    #[cfg(target_os = "linux")]
    let layer = super::layer_surface(
        "lokalbot-quick-recall",
        gpui_kit::layer_shell::Anchor::empty(),
        None,
        gpui_kit::layer_shell::KeyboardInteractivity::Exclusive,
    );
    #[cfg(not(target_os = "linux"))]
    let layer: Option<WindowKind> = None;
    let opened = match layer {
        Some(kind) => gpui_kit::open_window(options(kind), cx, build).or_else(|err| {
            log::debug!("Quick Recall: no layer shell, opening a window: {err:#}");
            gpui_kit::open_window(options(window_kind()), cx, build)
        }),
        None => gpui_kit::open_window(options(window_kind()), cx, build),
    };
    match opened {
        Ok((handle, view)) => {
            let windows = super::secondary(cx);
            windows.quick_recall = Some(handle);
            windows.quick_recall_view = Some(view.downgrade());
        }
        Err(err) => log::error!("could not open Quick Recall: {err:#}"),
    }
}

fn build(window: &mut Window, cx: &mut App) -> Entity<QuickRecall> {
    window.set_window_title(lokalbot_i18n::tr("Ask"));
    let view = cx.new(|cx| QuickRecall::new(window, cx));
    view.update(cx, |view, cx| view.focus_input(window, cx));
    view
}

/// Commands lead the list, so a typed command runs on Return like a launcher.
/// Only a few show, so memory searches keep their results in view.
const COMMAND_LIMIT: usize = 4;

/// One selectable row.
#[allow(clippy::large_enum_variant)]
#[derive(Clone)]
enum Row {
    Command(PaletteCommand),
    Screen {
        moment: ScreenMoment,
        snippet: Option<String>,
        captures: usize,
    },
    File {
        hit: lokalbot_core::files::FileHit,
    },
    Meeting {
        group: MeetingGroup,
    },
}

pub struct QuickRecall {
    data: Entity<AppData>,
    input: Entity<InputState>,
    query: String,
    results: search::Results,
    saved: Vec<ScreenMoment>,
    selection: usize,
    searching: bool,
    search_task: Option<Task<()>>,
    scroll: ScrollHandle,
    was_active: bool,
    thumbnails: ScreenThumbnails,
    /// The conversation on show instead of results, when one is.
    conversation: Option<Uuid>,
    /// Draws it: citations, evidence, copy, read aloud and retry, as in Ask.
    transcript: Option<Entity<AskPage>>,
    _transcript_changes: Option<Subscription>,
    _subscriptions: Vec<Subscription>,
}

impl QuickRecall {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search memory or run a command…",
                window,
                cx,
            ))
        });
        let subscriptions = vec![
            cx.subscribe_in(
                &input,
                window,
                |this, input, event: &InputEvent, window, cx| match event {
                    InputEvent::Change => {
                        let value = input.read(cx).value().to_string();
                        if value != this.query {
                            this.query = value;
                            this.selection = 0;
                            if this.conversation.is_none() {
                                this.search(window, cx);
                            }
                        }
                    }
                    InputEvent::PressEnter { secondary, .. } => {
                        if this.conversation.is_some() {
                            this.send_follow_up(window, cx);
                        } else if *secondary {
                            this.ask_about_query(window, cx);
                        } else {
                            this.open_selected(window, cx);
                        }
                    }
                    _ => {}
                },
            ),
            cx.observe_in(&data, window, |this, data, window, cx| {
                // A question from Ask moves the panel to its conversation.
                let streaming = data.read(cx).ask_stream.as_ref().map(|s| s.conversation_id);
                if let Some(id) = streaming
                    && this.conversation.is_some_and(|shown| shown != id)
                {
                    this.show_conversation(id, window, cx);
                }
                cx.notify();
            }),
            cx.observe_window_activation(window, |this, window, cx| {
                if window.is_window_active() {
                    this.was_active = true;
                } else if this.was_active {
                    // Like the macOS panel, leaving Quick Recall dismisses it.
                    this.close(window, cx);
                }
            }),
        ];
        // The answer already being written, as on the Mac.
        let conversation = data
            .read(cx)
            .ask_stream
            .as_ref()
            .filter(|stream| stream.error.is_none())
            .map(|stream| stream.conversation_id);
        let mut view = Self {
            data,
            input,
            query: String::new(),
            results: search::Results::default(),
            saved: Vec::new(),
            selection: 0,
            searching: false,
            search_task: None,
            scroll: ScrollHandle::new(),
            was_active: false,
            thumbnails: ScreenThumbnails::default(),
            conversation: None,
            transcript: None,
            _transcript_changes: None,
            _subscriptions: subscriptions,
        };
        view.load_saved(cx);
        if let Some(id) = conversation {
            view.show_conversation(id, window, cx);
        }
        view
    }

    fn show_conversation(&mut self, id: Uuid, window: &mut Window, cx: &mut Context<Self>) {
        let page = cx.new(|cx| AskPage::embedded(id, window, cx));
        self._transcript_changes = Some(cx.observe(&page, |_, _, cx| cx.notify()));
        self.transcript = Some(page);
        self.conversation = Some(id);
        self.set_placeholder("Ask a follow-up…", window, cx);
    }

    fn set_placeholder(
        &mut self,
        placeholder: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.input.update(cx, |input, cx| {
            input.set_placeholder(lokalbot_i18n::tr(placeholder), window, cx)
        });
    }

    fn focus_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.input.update(cx, |input, cx| {
            input.focus(window, cx);
            input.select_all(window, cx);
        });
    }

    fn load_saved(&mut self, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            let saved = cx
                .background_spawn(async move { library.saved_moments().unwrap_or_default() })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.saved = saved.into_iter().take(SAVED_MOMENTS).collect();
                cx.notify();
            });
        })
        .detach();
    }

    fn search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.query.trim().to_string();
        self.results = search::Results::default();
        if text.is_empty() {
            self.searching = false;
            self.search_task = None;
            cx.notify();
            return;
        }
        self.searching = true;
        let (library, meetings, file_folders) = {
            let data = self.data.read(cx);
            (
                data.library.clone(),
                data.meetings.clone(),
                if data.settings.file_search_enabled {
                    data.settings.file_search_folders.clone()
                } else {
                    Vec::new()
                },
            )
        };
        let query = search::Query {
            text,
            meetings: true,
            screen: true,
            file_folders,
            limit: 20,
            ..Default::default()
        };
        let for_query = self.query.clone();
        self.search_task = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(120))
                .await;
            let (lexical_library, lexical_query) = (library.clone(), query.clone());
            let found = cx
                .background_spawn(async move {
                    search::run(&lexical_library, &meetings, &lexical_query)
                })
                .await;
            let mut refined = found.clone();
            let _ = this.update(cx, |this, cx| {
                if this.query != for_query {
                    return;
                }
                this.results = found;
                this.searching = false;
                this.selection = 0;
                cx.notify();
            });
            // Meaning second, so words show at once.
            let refined = cx
                .background_spawn(async move {
                    let vector = lokalbot_engine::query_vector(query.text.trim())?;
                    search::refine(&library, &query, &vector, &mut refined);
                    Some(refined)
                })
                .await;
            if let Some(refined) = refined {
                let _ = this.update(cx, |this, cx| {
                    if this.query == for_query {
                        this.results = refined;
                        cx.notify();
                    }
                });
            }
        }));
        cx.notify();
    }

    /// Matching commands, computed live so titles follow recording and dictation.
    fn command_rows(&self, cx: &App) -> Vec<Row> {
        let query = self.query.trim();
        if self.conversation.is_some() || query.is_empty() {
            return Vec::new();
        }
        let commands = palette::commands(self.data.read(cx), false, cx);
        palette::filter(&commands, query, Matching::WordPrefix)
            .into_iter()
            .take(COMMAND_LIMIT)
            .map(Row::Command)
            .collect()
    }

    /// Screens first (saved moments without a query), then meetings.
    fn rows(&self) -> (Vec<Row>, Vec<Row>) {
        if self.query.trim().is_empty() {
            let screens = self
                .saved
                .iter()
                .take(SAVED_ROWS)
                .map(|moment| Row::Screen {
                    moment: moment.clone(),
                    snippet: None,
                    captures: 1,
                })
                .collect();
            return (screens, Vec::new());
        }
        let screens = search::screens_with_saved_first(&self.results.screens, &self.saved)
            .into_iter()
            .map(
                |ScreenResult {
                     moment,
                     snippet,
                     captures,
                     ..
                 }| {
                    let title = screen_title(&moment);
                    Row::Screen {
                        snippet: result_row::without_title_echo(&snippet, &title),
                        moment,
                        captures,
                    }
                },
            )
            .collect();
        let meetings = self
            .results
            .meetings
            .iter()
            .map(|group| Row::Meeting {
                group: group.clone(),
            })
            .collect();
        (screens, meetings)
    }

    fn all_rows(&self, cx: &App) -> Vec<Row> {
        let mut rows = self.command_rows(cx);
        let (screens, meetings) = self.rows();
        rows.extend(screens);
        rows.extend(meetings);
        rows.extend(self.file_rows());
        rows
    }

    /// Files, after meetings.
    fn file_rows(&self) -> Vec<Row> {
        if self.query.trim().is_empty() {
            return Vec::new();
        }
        self.results
            .files
            .iter()
            .map(|hit| Row::File { hit: hit.clone() })
            .collect()
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        if self.conversation.is_some() {
            return;
        }
        let count = self.all_rows(cx).len();
        if count == 0 {
            return;
        }
        self.selection = ((self.selection as isize + delta).rem_euclid(count as isize)) as usize;
        self.scroll.scroll_to_item(self.selection);
        cx.notify();
    }

    fn open_selected(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let rows = self.all_rows(cx);
        if let Some(row) = rows.get(self.selection).cloned() {
            self.open_row(row, window, cx);
        }
    }

    fn open_row(&mut self, row: Row, window: &mut Window, cx: &mut Context<Self>) {
        match row {
            // Recording and dictation act on the app the person came from, which
            // gets the keyboard back as this panel closes.
            Row::Command(command) => {
                self.close(window, cx);
                cx.defer(move |cx| palette::run(&command, cx));
                return;
            }
            Row::Screen { moment, .. } => open_screen_moment(&self.data, &moment, cx),
            // Files open in their own app, not in LokalBot's main window.
            Row::File { hit } => {
                search::open_file(&hit);
                self.close(window, cx);
                return;
            }
            Row::Meeting { group } => {
                let at = group.hits[0].moment();
                let tab = if at.is_some() {
                    MeetingTab::Transcript
                } else {
                    MeetingTab::Summary
                };
                self.data.update(cx, |data, cx| {
                    data.open_meeting(group.meeting.id, tab, at, cx)
                });
            }
        }
        super::activate_main(cx);
        self.close(window, cx);
    }

    /// A follow-up in the conversation on show, inside its latest question's scope
    /// (`model.currentQuestionScope`). Until that is known, nothing is sent.
    fn send_follow_up(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let question = self.query.trim().to_string();
        let Some(conversation_id) = self.conversation else {
            return;
        };
        let responding = self
            .data
            .read(cx)
            .ask_stream
            .as_ref()
            .is_some_and(|stream| stream.error.is_none());
        if question.is_empty() || responding {
            return;
        }
        let scope = self
            .transcript
            .as_ref()
            .and_then(|page| page.read(cx).follow_up_scope(conversation_id));
        let Some(scope) = scope else {
            return;
        };
        self.data.update(cx, |data, cx| {
            data.ask_question(conversation_id, question, scope, None, cx)
        });
        self.input
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.query.clear();
        cx.notify();
    }

    /// Back to results (`showRecall`).
    fn show_recall(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        stop_answer_speech(cx);
        self.conversation = None;
        self.transcript = None;
        self._transcript_changes = None;
        self.selection = 0;
        self.set_placeholder("Search memory or run a command…", window, cx);
        self.load_saved(cx);
        self.search(window, cx);
        self.focus_input(window, cx);
    }

    /// Opens Ask with the query and the meetings it matched (`ask(_:usingResults:)`).
    fn ask_about_query(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let question = self.query.trim().to_string();
        if question.is_empty() || self.searching {
            return;
        }
        let meeting_ids = self.results.meetings.iter().map(|g| g.meeting.id).collect();
        let screen_ids: Vec<i64> = self.results.screens.iter().map(|s| s.moment.id).collect();
        self.data.update(cx, |data, cx| {
            data.ask_screens = (!screen_ids.is_empty()).then_some(screen_ids);
            data.ask(
                AskRequest {
                    question,
                    meeting_ids,
                    submit: false,
                    day: None,
                },
                cx,
            )
        });
        super::activate_main(cx);
        self.close(window, cx);
    }

    fn ask_suggestion(&mut self, suggestion: &str, window: &mut Window, cx: &mut Context<Self>) {
        let question = suggestion.to_string();
        self.data.update(cx, |data, cx| {
            data.ask(
                AskRequest {
                    question,
                    meeting_ids: Vec::new(),
                    submit: false,
                    day: None,
                },
                cx,
            )
        });
        super::activate_main(cx);
        self.close(window, cx);
    }

    fn open_full_ask(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // Both surfaces share the conversation; opening it never re-submits.
        if let Some(id) = self.conversation {
            self.data.update(cx, |data, cx| {
                data.ask_open_conversation = Some(id);
                data.navigate(Section::Ask, cx)
            });
            super::activate_main(cx);
            self.close(window, cx);
            return;
        }
        let question = self.query.trim().to_string();
        self.data.update(cx, |data, cx| {
            data.ask(
                AskRequest {
                    question,
                    meeting_ids: Vec::new(),
                    submit: false,
                    day: None,
                },
                cx,
            )
        });
        super::activate_main(cx);
        self.close(window, cx);
    }

    fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search_task = None;
        stop_answer_speech(cx);
        self.thumbnails.clear(window, cx);
        let windows = super::secondary(cx);
        windows.quick_recall = None;
        windows.quick_recall_view = None;
        window.remove_window();
    }

    fn render_search_row(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let has_text = !self.query.is_empty();
        let in_conversation = self.conversation.is_some();
        let responding = in_conversation
            && self
                .data
                .read(cx)
                .ask_stream
                .as_ref()
                .is_some_and(|stream| stream.error.is_none());
        h_flex()
            .gap(px(10.))
            .items_center()
            .px(metric::PANEL_PADDING)
            .py(px(16.))
            .when(in_conversation, |this| {
                this.child(
                    Button::new("quick-recall-back")
                        .ghost()
                        .small()
                        .icon(Icon::new(Ico::ChevronLeft))
                        .tooltip(lokalbot_i18n::tr("Back to recall"))
                        .on_click(cx.listener(|this, _, window, cx| this.show_recall(window, cx))),
                )
            })
            .when(!in_conversation, |this| {
                this.child(ui::glyphs::ask_glyph(px(22.), lb.accent_text))
            })
            .child(
                div().flex_1().min_w_0().child(
                    Input::new(&self.input)
                        .appearance(false)
                        .text_size(px(22.))
                        .line_height(px(30.))
                        .h(px(36.))
                        .px_0(),
                ),
            )
            .when(responding, |this| {
                let data = self.data.clone();
                this.child(
                    Button::new("quick-recall-stop")
                        .ghost()
                        .small()
                        .icon(Icon::new(Ico::CircleStop))
                        .tooltip(lokalbot_i18n::tr("Stop"))
                        .on_click(move |_, _, cx| {
                            data.update(cx, |data, cx| data.request(AppEvent::StopAnswer, cx))
                        }),
                )
            })
            .when(has_text && !responding, |this| {
                this.child(
                    Button::new("quick-recall-clear")
                        .ghost()
                        .small()
                        .icon(Icon::new(Ico::CircleX))
                        .tooltip(lokalbot_i18n::tr("Clear"))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.input
                                .update(cx, |input, cx| input.set_value("", window, cx));
                            this.query.clear();
                            this.search(window, cx);
                            this.focus_input(window, cx);
                        })),
                )
            })
            .child(
                Button::new("quick-recall-open-ask")
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::SquareArrowOutUpRight))
                    .tooltip(lokalbot_i18n::tr("Open full Ask"))
                    .on_click(cx.listener(|this, _, window, cx| this.open_full_ask(window, cx))),
            )
    }

    fn render_command_row(
        &self,
        index: usize,
        command: &PaletteCommand,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let selected = index == self.selection;
        let white: Hsla = gpui_kit::white();
        let row_value = Row::Command(command.clone());
        h_flex()
            .id(("quick-recall-row", index))
            .w_full()
            .gap(px(12.))
            .items_center()
            .px(px(12.))
            .py(px(10.))
            .rounded(metric::GROUP_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.accent_fill))
            .when(!selected, |this| {
                this.hover(|s| s.bg(lb.text.opacity(0.05)))
            })
            .child(
                div()
                    .w(px(64.))
                    .h(px(40.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(ui::icon(
                        command.icon,
                        px(18.),
                        if selected { white } else { lb.accent_text },
                    )),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(3.))
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(if selected { white } else { lb.text })
                            .child(command.title.clone()),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::CAPTION)
                            .text_color(if selected {
                                white.opacity(0.85)
                            } else {
                                lb.text_secondary
                            })
                            .child(command.subtitle.clone()),
                    ),
            )
            .when(selected, |this| {
                this.child(ui::icon(Ico::CornerDownLeft, px(13.), white))
            })
            .on_click(
                cx.listener(move |this, _, window, cx| {
                    this.open_row(row_value.clone(), window, cx)
                }),
            )
            .into_any_element()
    }

    fn render_row(&self, index: usize, row: &Row, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let selected = index == self.selection;
        let white: Hsla = gpui_kit::white();
        let primary = if selected { white } else { lb.text };
        let secondary = if selected {
            white.opacity(0.85)
        } else {
            lb.text_secondary
        };
        let (leading, title, snippet, meta): (AnyElement, String, Option<String>, String) =
            match row {
                Row::Command(command) => return self.render_command_row(index, command, cx),
                Row::Screen {
                    moment,
                    snippet,
                    captures,
                } => {
                    let title = moment
                        .saved_note
                        .clone()
                        .filter(|n| !n.trim().is_empty())
                        .unwrap_or_else(|| screen_title(moment));
                    let mut meta = moment.app.clone();
                    if *captures > 1 {
                        meta.push_str(&lokalbot_i18n::format(
                            " · {captures} captures",
                            &[("captures", format!("{}", captures))],
                        ));
                    }
                    meta.push_str(&format!(" · {}", date_label(moment.ts, Local::now())));
                    let tint = lb.app_color(&moment.app);
                    let image = self.thumbnails.image(moment, cx, |view| &view.thumbnails);
                    let picture = match image {
                        Some(ScreenImage::Ready(image)) => Some(image),
                        _ => None,
                    };
                    let leading = div()
                        .relative()
                        .w(px(64.))
                        .h(px(40.))
                        .rounded(metric::ROW_RADIUS)
                        .overflow_hidden()
                        .bg(if selected {
                            white.opacity(0.18)
                        } else {
                            tint.opacity(0.16)
                        })
                        .border_1()
                        .border_color(if selected {
                            white.opacity(0.3)
                        } else {
                            tint.opacity(0.28)
                        })
                        .flex()
                        .items_center()
                        .justify_center()
                        .map(|this| match picture {
                            Some(image) => {
                                this.child(img(image).size_full().object_fit(ObjectFit::Cover))
                            }
                            None => this.child(ui::icon(
                                if moment.path.is_empty() {
                                    Ico::ScanText
                                } else {
                                    Ico::AppWindow
                                },
                                px(18.),
                                if selected { white } else { tint },
                            )),
                        })
                        .when(moment.is_saved, |this| {
                            this.child(
                                div()
                                    .absolute()
                                    .right(px(2.))
                                    .bottom(px(2.))
                                    .size(px(14.))
                                    .rounded_full()
                                    .bg(lb.elevated)
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .child(ui::icon(Ico::Bookmark, px(9.), lb.speakers[4])),
                            )
                        })
                        .into_any_element();
                    (leading, title, snippet.clone(), meta)
                }
                Row::File { hit } => {
                    let meta = format!(
                        "{} · {} · {}",
                        hit.folder(),
                        search::file_kind_label(hit),
                        date_label(hit.date(), Local::now())
                    );
                    let leading = div()
                        .w(px(64.))
                        .h(px(40.))
                        .flex()
                        .justify_center()
                        .child(
                            div()
                                .size(px(40.))
                                .rounded(metric::ROW_RADIUS)
                                .bg(if selected {
                                    white.opacity(0.18)
                                } else {
                                    lb.chip_fill
                                })
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(ui::icon(
                                    search::file_icon(hit.kind),
                                    px(18.),
                                    if selected { white } else { lb.accent_text },
                                )),
                        )
                        .into_any_element();
                    (leading, hit.name(), hit.excerpt.clone(), meta)
                }
                Row::Meeting { group } => {
                    let hit: &Hit = &group.hits[0];
                    let meta = format!(
                        "{} · {} · {}",
                        group.meeting.app_name,
                        hit.recall_kind(),
                        date_label(group.meeting.started_at, Local::now())
                    );
                    let leading = div()
                        .w(px(64.))
                        .h(px(40.))
                        .flex()
                        .justify_center()
                        .child(
                            div()
                                .size(px(40.))
                                .rounded(metric::ROW_RADIUS)
                                .bg(if selected {
                                    white.opacity(0.18)
                                } else {
                                    lb.chip_fill
                                })
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(ui::icon(
                                    Ico::AudioLines,
                                    px(18.),
                                    if selected { white } else { lb.accent_text },
                                )),
                        )
                        .into_any_element();
                    (
                        leading,
                        group.meeting.display_title(),
                        Some(hit.snippet.clone()),
                        meta,
                    )
                }
            };
        let row_value = row.clone();
        h_flex()
            .id(("quick-recall-row", index))
            .w_full()
            .gap(px(12.))
            .items_center()
            .px(px(12.))
            .py(px(10.))
            .rounded(metric::GROUP_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.accent_fill))
            .when(!selected, |this| {
                this.hover(|s| s.bg(lb.text.opacity(0.05)))
            })
            .child(leading)
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(3.))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(primary)
                                    .child(title),
                            )
                            .child(div().w(px(14.)).flex_none().when(selected, |this| {
                                this.child(ui::icon(Ico::CornerDownLeft, px(13.), white))
                            })),
                    )
                    .when_some(snippet.filter(|s| !s.trim().is_empty()), |this, snippet| {
                        this.child(
                            div()
                                .truncate()
                                .text_size(ty::SECONDARY)
                                .text_color(secondary)
                                .child(result_row::highlighted(&snippet, primary)),
                        )
                    })
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::CAPTION)
                            .text_color(secondary)
                            .child(meta),
                    ),
            )
            .on_click(
                cx.listener(move |this, _, window, cx| {
                    this.open_row(row_value.clone(), window, cx)
                }),
            )
            .into_any_element()
    }

    fn render_content(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        if let Some(page) = self.transcript.clone() {
            return page.update(cx, |page, cx| {
                page.render_transcript(window, cx).into_any_element()
            });
        }
        let commands = self.command_rows(cx);
        let (screens, meetings) = self.rows();
        let trimmed = self.query.trim();
        if trimmed.is_empty() && screens.is_empty() {
            return self.render_empty(cx);
        }
        let mut children: Vec<AnyElement> = Vec::new();
        if self.searching {
            children.push(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .px(px(12.))
                    .py(px(10.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(Spinner::new().xsmall().color(lb.text_secondary))
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Searching your local memory…",
                    )))
                    .into_any_element(),
            );
        } else if !trimmed.is_empty()
            && commands.is_empty()
            && screens.is_empty()
            && meetings.is_empty()
            && self.results.files.is_empty()
        {
            children.push(
                v_flex()
                    .items_center()
                    .gap(px(8.))
                    .py(px(28.))
                    .px(px(20.))
                    .child(
                        h_flex()
                            .gap(px(6.))
                            .items_center()
                            .child(ui::icon(Ico::Search, px(14.), lb.text))
                            .child(
                                div()
                                    .text_size(ty::SECTION)
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("No local matches"))),
                            ),
                    )
                    .child(
                        div()
                            .text_center()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Nothing in saved moments, captured screens, or meetings matches this search."))),
                    )
                    .into_any_element(),
            );
        }
        // The scroll handle reveals rows by child index; section headers and
        // dividers are folded into the row elements to keep indexes aligned.
        let mut index = 0;
        let mut rows: Vec<AnyElement> = Vec::new();
        let files = self.file_rows();
        for (title, section) in [
            (lokalbot_i18n::tr("Commands"), &commands),
            (lokalbot_i18n::tr("Screens"), &screens),
            (lokalbot_i18n::tr("Meetings"), &meetings),
            (lokalbot_i18n::tr("Files"), &files),
        ] {
            for (position, row) in section.iter().enumerate() {
                let element = self.render_row(index, row, cx);
                rows.push(
                    v_flex()
                        .w_full()
                        .when(position == 0, |this| {
                            this.child(
                                div()
                                    .px(px(12.))
                                    .pt(px(12.))
                                    .pb(px(6.))
                                    .text_size(ty::CAPTION)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text_secondary)
                                    .child(title),
                            )
                        })
                        .child(element)
                        .child(div().mx(px(12.)).my(px(2.)).h(px(1.)).bg(lb.separator))
                        .into_any_element(),
                );
                index += 1;
            }
        }
        v_flex()
            .size_full()
            .children(children)
            .child(
                v_flex()
                    .id("quick-recall-results")
                    .flex_1()
                    .min_h_0()
                    .px(px(10.))
                    .pb(px(10.))
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .children(rows),
            )
            .into_any_element()
    }

    fn render_empty(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let suggestions: Vec<AnyElement> = SUGGESTIONS
            .iter()
            .enumerate()
            .map(|(index, suggestion)| {
                h_flex()
                    .id(("quick-recall-suggestion", index))
                    .w(px(420.))
                    .gap(px(8.))
                    .items_center()
                    .px(px(12.))
                    .py(px(8.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.chip_fill)
                    .cursor_pointer()
                    .hover(|s| s.bg(lb.hover.opacity(2.0)))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
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
            .gap(px(8.))
            .px(px(24.))
            .child(ui::glyphs::ask_glyph(px(30.), lb.text_secondary))
            .child(div().text_size(ty::COLUMN_TITLE).font_weight(FontWeight::BOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Ask anything"))))
            .child(
                div()
                    .max_w(px(420.))
                    .text_center()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Type to search meetings, screens, and saved moments, or to run a command like Record now. Return opens a result; Ask is a separate action."))),
            )
            .child(v_flex().gap(px(7.)).pt(px(6.)).children(suggestions))
            .into_any_element()
    }

    fn render_footer(&self, has_results: bool, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let query = self.query.trim().to_string();
        let inference = composer_inference(cx);
        h_flex()
            .gap(px(16.))
            .items_center()
            .px(px(20.))
            .py(px(10.))
            .min_h(px(42.))
            .when(has_results, |this| {
                this.child(
                    h_flex()
                        .gap(px(12.))
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("↑↓ Navigate")))
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("↩ Open"))),
                )
            })
            .child(div().flex_1().min_w_0())
            .when(!query.is_empty(), |this| {
                let label: SharedString =
                    lokalbot_i18n::format("Ask about “{query}”", &[("query", query.to_string())])
                        .into();
                this.child(
                    v_flex()
                        .items_end()
                        .gap(px(4.))
                        .max_w(px(350.))
                        .child(
                            Button::new("quick-recall-ask")
                                .outline()
                                .icon(Icon::new(Ico::Sparkles))
                                .label(label)
                                .child(
                                    div()
                                        .pl(px(3.))
                                        .text_size(ty::CAPTION)
                                        .text_color(lb.text_secondary)
                                        .child("Ctrl↩"),
                                )
                                .tooltip(lokalbot_i18n::tr(
                                    "Open Ask with this query and its matching sources",
                                ))
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.ask_about_query(window, cx)
                                })),
                        )
                        .child(
                            h_flex()
                                .gap(px(5.))
                                .items_center()
                                .text_size(ty::CAPTION)
                                .text_color(lb.text_secondary)
                                .child(ui::icon(inference.icon, px(12.), lb.text_secondary))
                                .child(inference.label),
                        ),
                )
            })
    }
}

impl Render for QuickRecall {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.thumbnails.drop_released(window, cx);
        let lb = cx.lb().clone();
        let has_results = !self.all_rows(cx).is_empty();
        let in_conversation = self.conversation.is_some();
        v_flex()
            .size_full()
            .key_context("QuickRecall")
            .font_family(FONT_FAMILY)
            .text_align(crate::i18n::interface_alignment())
            .bg(lb.elevated)
            .text_color(lb.text)
            .capture_action(cx.listener(|this, _: &MoveUp, _, cx| {
                this.move_selection(-1, cx);
                cx.stop_propagation();
            }))
            .capture_action(cx.listener(|this, _: &MoveDown, _, cx| {
                this.move_selection(1, cx);
                cx.stop_propagation();
            }))
            .on_action(cx.listener(|this, _: &Escape, window, cx| this.close(window, cx)))
            .child(self.render_search_row(cx))
            .child(ui::divider(cx))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(self.render_content(window, cx)),
            )
            .when(!in_conversation, |this| {
                this.child(ui::divider(cx))
                    .child(self.render_footer(has_results, cx))
            })
    }
}

fn screen_title(moment: &ScreenMoment) -> String {
    if moment.window_title.trim().is_empty() {
        moment.app.clone()
    } else {
        moment.window_title.clone()
    }
}

/// "Today · 10:43 AM", "Yesterday · …", "Wed · …" within a week, else "Sep 25 · …"
/// (`QuickRecallDateLabel`).
pub fn date_label(at: DateTime<Utc>, now: DateTime<Local>) -> String {
    let local = at.with_timezone(&Local);
    let time = local.format_localized(
        lokalbot_i18n::date_pattern("%-I:%M %p"),
        lokalbot_i18n::date_locale(),
    );
    let days = (now.date_naive() - local.date_naive()).num_days();
    let day = match days {
        0 => lokalbot_i18n::tr("Today").to_string(),
        1 => lokalbot_i18n::tr("Yesterday").to_string(),
        2..=6 => local
            .format_localized(
                lokalbot_i18n::date_pattern("%a"),
                lokalbot_i18n::date_locale(),
            )
            .to_string(),
        _ => local
            .format_localized(
                lokalbot_i18n::date_pattern("%b %-d"),
                lokalbot_i18n::date_locale(),
            )
            .to_string(),
    };
    lokalbot_i18n::format(
        "{day} · {time}",
        &[("day", day.to_string()), ("time", format!("{}", time))],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    #[test]
    fn date_labels() {
        let now = Local.with_ymd_and_hms(2026, 10, 18, 15, 0, 0).unwrap();
        let at = |d: u32, h: u32| {
            Local
                .with_ymd_and_hms(2026, 10, d, h, 43, 0)
                .unwrap()
                .with_timezone(&Utc)
        };
        assert_eq!(date_label(at(18, 10), now), "Today · 10:43 AM");
        assert_eq!(date_label(at(17, 13), now), "Yesterday · 1:43 PM");
        assert_eq!(date_label(at(14, 9), now), "Wed · 9:43 AM");
        assert_eq!(date_label(at(1, 9), now), "Oct 1 · 9:43 AM");
    }
}
