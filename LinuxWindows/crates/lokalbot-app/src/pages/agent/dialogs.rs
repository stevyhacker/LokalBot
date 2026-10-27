//! Agent dialogs: attaching meetings and saved moments (`AgentContextPicker`),
//! browsing saved sessions (`AgentSessionHistoryView`) and renaming a task.

use std::path::PathBuf;

use crate::i18n::h_flex;
use chrono::{DateTime, Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Window, div, px,
};
use uuid::Uuid;

use lokalbot_agent::context::ContextError;
use lokalbot_agent::history::SavedSession;
use lokalbot_agent::tasks::Attachment;
use lokalbot_core::ScreenMoment;

use super::AgentPage;
use crate::state::{AppData, SettingsCategory};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

fn formatted(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%b %-d, %Y, %-I:%M %p"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

impl AgentPage {
    // The dialogs are built while this page is being updated, so their
    // constructors take what they need from the page instead of reading it.

    pub(super) fn open_context_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let page = cx.entity();
        let data = self.data.clone();
        let moments = self
            .model(cx)
            .and_then(|m| {
                m.tasks
                    .as_ref()?
                    .selected()
                    .map(|t| t.session.context_resolver())
            })
            .map(|resolver| resolver.saved_moments());
        let picker = cx.new(|cx| ContextPicker::new(page, data, moments, window, cx));
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(580.)).close_button(false).child(picker.clone())
        });
    }

    pub(super) fn open_saved_sessions(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let page = cx.entity();
        let directory = self.model(cx).and_then(|m| {
            m.tasks
                .as_ref()
                .map(|t| t.sessions_directory().to_path_buf())
        });
        let view = cx.new(|cx| SavedSessions::new(page, directory, window, cx));
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(780.)).close_button(false).child(view.clone())
        });
    }

    pub(super) fn open_rename(
        &mut self,
        id: Uuid,
        title: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Task name",
                window,
                cx,
            ))
        });
        input.update(cx, |state, cx| state.set_value(title, window, cx));
        let page = cx.entity();
        window.open_dialog(cx, move |dialog, _, cx| {
            let lb = cx.lb().clone();
            let save_input = input.clone();
            let page = page.clone();
            dialog
                .w(px(420.))
                .title(
                    div()
                        .text_size(ty::COLUMN_TITLE)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Rename task"))),
                )
                .child(Input::new(&input))
                .footer(
                    h_flex()
                        .w_full()
                        .gap_2()
                        .justify_end()
                        .child(
                            crate::ui::controls::bordered(
                                "agent-rename-cancel",
                                lokalbot_i18n::tr("Cancel"),
                            )
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                        )
                        .child(
                            Button::new("agent-rename-save")
                                .primary()
                                .label(lokalbot_i18n::tr("Save"))
                                .on_click(move |_, window, cx| {
                                    let name = save_input.read(cx).value().to_string();
                                    page.update(cx, |page, cx| {
                                        page.with_tasks(cx, |tasks| tasks.rename(id, &name))
                                    });
                                    window.close_dialog(cx);
                                }),
                        ),
                )
        });
    }

    fn has_attachment(&self, id: &str, cx: &App) -> bool {
        self.model(cx)
            .and_then(|m| m.tasks.as_ref()?.selected())
            .is_some_and(|tab| tab.session.attachments.iter().any(|a| a.id == id))
    }
}

// ------------------------------------------------------------ context picker

pub(super) struct ContextPicker {
    page: Entity<AgentPage>,
    data: Entity<AppData>,
    input: Entity<InputState>,
    query: String,
    moments: Vec<ScreenMoment>,
    moment_error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl ContextPicker {
    fn new(
        page: Entity<AgentPage>,
        data: Entity<AppData>,
        moments: Option<Result<Vec<ScreenMoment>, ContextError>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search meetings and saved moments",
                window,
                cx,
            ))
        });
        let subscriptions = vec![
            cx.subscribe(&input, |this, input, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    this.query = input.read(cx).value().to_string();
                    cx.notify();
                }
            }),
            cx.observe(&page, |_, _, cx| cx.notify()),
        ];
        let (moments, moment_error) = match moments {
            Some(Ok(moments)) => (moments, None),
            Some(Err(error)) => (Vec::new(), Some(error.to_string())),
            None => (Vec::new(), None),
        };
        input.update(cx, |state, cx| state.focus(window, cx));
        Self {
            page,
            data,
            input,
            query: String::new(),
            moments,
            moment_error,
            _subscriptions: subscriptions,
        }
    }

    fn row(
        &self,
        source: Attachment,
        detail: String,
        icon: Ico,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let attached = self.page.read(cx).has_attachment(&source.id, cx);
        let page = self.page.clone();
        h_flex()
            .id(SharedString::from(format!("agent-context-{}", source.id)))
            .w_full()
            .gap(px(10.))
            .items_center()
            .px(px(8.))
            .py(px(6.))
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .hover(|s| s.bg(lb.hover))
            .child(ui::icon(icon, px(15.), lb.text_secondary))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(3.))
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(source.title.clone()),
                    )
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(detail),
                    ),
            )
            .child(ui::icon(
                if attached {
                    Ico::CircleCheck
                } else {
                    Ico::CirclePlus
                },
                px(15.),
                if attached {
                    lb.accent_text
                } else {
                    lb.text_secondary
                },
            ))
            .on_click(move |_, _, cx| {
                let source = source.clone();
                page.update(cx, |page, cx| {
                    page.with_session(cx, |session| session.add_attachment(source))
                });
            })
            .into_any_element()
    }
}

impl Render for ContextPicker {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let query = self.query.trim().to_lowercase();
        let meetings: Vec<_> = self
            .data
            .read(cx)
            .meetings
            .iter()
            .filter(|m| query.is_empty() || m.display_title().to_lowercase().contains(&query))
            .take(50)
            .cloned()
            .collect();
        let mut list: Vec<AnyElement> = vec![section(lokalbot_i18n::tr("Meetings"), cx)];
        if meetings.is_empty() {
            list.push(note(lokalbot_i18n::tr("No meetings match."), cx));
        }
        for meeting in meetings {
            let title = meeting.display_title();
            let source = Attachment::meeting(meeting.id, &title);
            list.push(self.row(source, formatted(meeting.started_at), Ico::AudioLines, cx));
        }
        list.push(section(lokalbot_i18n::tr("Saved moments"), cx));
        if let Some(error) = self.moment_error.clone() {
            let data = self.data.clone();
            list.push(note(&error, cx));
            list.push(
                div()
                    .px(px(8.))
                    .child(
                        Button::new("agent-context-privacy")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Open Privacy settings"))
                            .on_click(move |_, window, cx| {
                                window.close_dialog(cx);
                                data.update(cx, |data, cx| {
                                    data.open_settings(SettingsCategory::Privacy, cx)
                                })
                            }),
                    )
                    .into_any_element(),
            );
        } else if self.moments.is_empty() {
            list.push(note(
                lokalbot_i18n::tr("No saved moments in the current screen-memory grant."),
                cx,
            ));
        }
        let moments: Vec<ScreenMoment> = self
            .moments
            .iter()
            .filter(|m| {
                query.is_empty()
                    || format!(
                        "{} {}",
                        m.window_title,
                        m.saved_note.as_deref().unwrap_or("")
                    )
                    .to_lowercase()
                    .contains(&query)
            })
            .cloned()
            .collect();
        for moment in moments {
            let note_text = moment.saved_note.clone().unwrap_or_default();
            let title = if note_text.trim().is_empty() {
                moment.window_title.clone()
            } else {
                note_text
            };
            let detail = format!("{} · {}", moment.app, formatted(moment.ts));
            list.push(self.row(
                Attachment::moment(moment.id, &title),
                detail,
                Ico::Bookmark,
                cx,
            ));
        }
        v_flex()
            .w_full()
            .gap(px(12.))
            .child(
                h_flex()
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .text_size(ty::COLUMN_TITLE)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Attach context"))),
                    )
                    .child(
                        Button::new("agent-context-done")
                            .primary()
                            .small()
                            .label(lokalbot_i18n::tr("Done"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    ),
            )
            .child(
                Input::new(&self.input)
                    .cleanable(true)
                    .prefix(ui::icon(Ico::Search, px(14.), lb.text_secondary)),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Choose sources to include with your next message. Screen pixels are never attached."))),
            )
            .child(
                div()
                    .id("agent-context-list")
                    .h(px(380.))
                    .overflow_y_scroll()
                    .child(v_flex().gap(px(2.)).children(list)),
            )
    }
}

fn section(title: &'static str, cx: &App) -> AnyElement {
    div()
        .px(px(8.))
        .pt(px(10.))
        .pb(px(4.))
        .text_size(ty::SECONDARY)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(cx.lb().supporting)
        .child(title)
        .into_any_element()
}

fn note(text: &str, cx: &App) -> AnyElement {
    div()
        .px(px(8.))
        .py(px(4.))
        .text_size(ty::SECONDARY)
        .text_color(cx.lb().text_secondary)
        .child(text.to_string())
        .into_any_element()
}

// ------------------------------------------------------------ saved sessions

/// Searchable local history of pi sessions; Open reopens one in its
/// original working folder.
pub(super) struct SavedSessions {
    page: Entity<AgentPage>,
    directory: Option<PathBuf>,
    input: Entity<InputState>,
    query: String,
    sessions: Vec<SavedSession>,
    loading: bool,
    load_error: Option<String>,
    selected: Option<String>,
    open_error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl SavedSessions {
    fn new(
        page: Entity<AgentPage>,
        directory: Option<PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search sessions",
                window,
                cx,
            ))
        });
        let subscriptions = vec![cx.subscribe(&input, |this, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.query = input.read(cx).value().to_string();
                if !this
                    .filtered()
                    .iter()
                    .any(|s| Some(&s.id) == this.selected.as_ref())
                {
                    this.selected = this.filtered().first().map(|s| s.id.clone());
                }
                cx.notify();
            }
        })];
        let mut view = Self {
            page,
            directory,
            input,
            query: String::new(),
            sessions: Vec::new(),
            loading: true,
            load_error: None,
            selected: None,
            open_error: None,
            _subscriptions: subscriptions,
        };
        view.reload(cx);
        view
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        let Some(directory) = self.directory.clone() else {
            self.loading = false;
            return;
        };
        self.loading = true;
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move { lokalbot_agent::history::load(&directory) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.loading = false;
                match loaded {
                    Ok(sessions) => {
                        this.sessions = sessions;
                        this.load_error = None;
                        if !this
                            .sessions
                            .iter()
                            .any(|s| Some(&s.id) == this.selected.as_ref())
                        {
                            this.selected = this.sessions.first().map(|s| s.id.clone());
                        }
                    }
                    Err(err) => this.load_error = Some(format!("{err:#}")),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn filtered(&self) -> Vec<SavedSession> {
        let query = self.query.trim().to_lowercase();
        self.sessions
            .iter()
            .filter(|s| query.is_empty() || s.searchable_text().to_lowercase().contains(&query))
            .cloned()
            .collect()
    }

    fn is_open(&self, session: &SavedSession, cx: &App) -> bool {
        self.page
            .read(cx)
            .model(cx)
            .and_then(|m| m.tasks.as_ref())
            .is_some_and(|t| t.is_open(session))
    }

    fn workspace_name(&self, session: &SavedSession, cx: &App) -> String {
        self.page
            .read(cx)
            .model(cx)
            .and_then(|m| m.tasks.as_ref())
            .map(|t| t.workspace_display_name(&session.workspace))
            .unwrap_or_default()
    }
}

impl Render for SavedSessions {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let _ = window;
        let lb = cx.lb().clone();
        let filtered = self.filtered();
        let selected = filtered
            .iter()
            .find(|s| Some(&s.id) == self.selected.as_ref())
            .cloned();

        let mut rows: Vec<AnyElement> = Vec::new();
        if self.loading && self.sessions.is_empty() {
            rows.push(note(lokalbot_i18n::tr("Loading saved sessions…"), cx));
        } else if let Some(error) = self.load_error.clone() {
            rows.push(note(
                &lokalbot_i18n::format(
                    "Couldn’t load sessions: {error}",
                    &[("error", error.to_string())],
                ),
                cx,
            ));
        } else if filtered.is_empty() {
            rows.push(note(
                if self.query.trim().is_empty() {
                    lokalbot_i18n::tr(
                        "Sessions appear here after Agent Mode has created local history.",
                    )
                } else {
                    lokalbot_i18n::tr(
                        "No matching sessions. Try a session title or workspace name.",
                    )
                },
                cx,
            ));
        }
        for session in &filtered {
            let chosen = Some(&session.id) == self.selected.as_ref();
            let id = session.id.clone();
            let open = self.is_open(session, cx);
            rows.push(
                h_flex()
                    .id(SharedString::from(format!(
                        "agent-saved-{}",
                        session.session_id
                    )))
                    .w_full()
                    .gap(px(10.))
                    .items_start()
                    .px(px(10.))
                    .py(px(7.))
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .when(chosen, |this| this.bg(lb.sidebar_selection))
                    .when(!chosen, |this| this.hover(|s| s.bg(lb.hover)))
                    .child(div().pt(px(2.)).child(ui::icon(
                        Ico::MessageSquareText,
                        px(15.),
                        lb.accent_text,
                    )))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(
                                div()
                                    .line_clamp(2)
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(session.title.clone()),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(format!(
                                        "{} · {}",
                                        self.workspace_name(session, cx),
                                        formatted(session.modified_at)
                                    )),
                            ),
                    )
                    .when(open, |this| {
                        this.child(ui::icon(Ico::CircleCheck, px(14.), lb.success_text))
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected = Some(id.clone());
                        this.open_error = None;
                        cx.notify();
                    }))
                    .into_any_element(),
            );
        }

        // The details scroll; the Open button below them stays in view.
        let (detail, footer): (AnyElement, Option<AnyElement>) = match selected {
            Some(session) => {
                let open = self.is_open(&session, cx);
                let page = self.page.clone();
                let opening = session.clone();
                let row = |label: &str, value: String| {
                    h_flex()
                        .gap(px(18.))
                        .items_start()
                        .child(
                            div()
                                .w(px(90.))
                                .flex_none()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(label.to_string()),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text)
                                .child(value),
                        )
                };
                let body = v_flex()
                    .gap(px(18.))
                    .child(
                        v_flex()
                            .gap(px(7.))
                            .child(
                                div()
                                    .text_size(px(20.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(session.title.clone()),
                            )
                            .child(
                                h_flex()
                                    .gap(px(6.))
                                    .items_center()
                                    .child(ui::icon(Ico::Folder, px(13.), lb.text_secondary))
                                    .child(
                                        div()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.text_secondary)
                                            .child(self.workspace_name(&session, cx)),
                                    ),
                            ),
                    )
                    .child(
                        v_flex()
                            .gap(px(10.))
                            .child(row(
                                lokalbot_i18n::tr("Last active"),
                                formatted(session.modified_at),
                            ))
                            .child(row(
                                lokalbot_i18n::tr("Created"),
                                formatted(session.created_at),
                            ))
                            .child(row(
                                lokalbot_i18n::tr("Messages"),
                                lokalbot_i18n::count(session.message_count, "message"),
                            ))
                            .child(row(
                                lokalbot_i18n::tr("Workspace"),
                                session.workspace.display().to_string(),
                            )),
                    )
                    .child(ui::divider(cx))
                    .when(!session.preview.is_empty(), |this| {
                        this.child(
                            div()
                                .text_size(ty::SECTION)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "Last message preview",
                                ))),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text)
                                .child(session.preview.clone()),
                        )
                        .child(
                            div()
                                .text_size(ty::CAPTION)
                                .text_color(lb.text_secondary)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "Preview only. The session starts when you send a message.",
                                ))),
                        )
                    })
                    .into_any_element();
                let footer = v_flex()
                    .gap(px(9.))
                    .child(
                        h_flex().child(
                            Button::new("agent-saved-open")
                                .primary()
                                .icon(Icon::new(if open {
                                    Ico::CircleCheck
                                } else {
                                    Ico::SquareArrowOutUpRight
                                }))
                                .label(if open { lokalbot_i18n::tr("Already Open") } else { lokalbot_i18n::tr("Open Session") })
                                .disabled(open)
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    let session = opening.clone();
                                    let mut result = Ok(());
                                    page.update(cx, |page, cx| {
                                        page.with_tasks(cx, |tasks| {
                                            result = tasks.open_saved_session(&session)
                                        });
                                        page.preview = None;
                                    });
                                    match result {
                                        Ok(()) => window.close_dialog(cx),
                                        Err(error) => {
                                            this.open_error = Some(error);
                                            cx.notify();
                                        }
                                    }
                                })),
                        ),
                    )
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(if open {
                                lokalbot_i18n::tr("This session is already open as a task.")
                            } else {
                                lokalbot_i18n::tr("The full conversation will reopen in its original working folder.")
                            }),
                    )
                    .when_some(self.open_error.clone(), |this, error| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.attention_text)
                                .child(error),
                        )
                    })
                    .into_any_element();
                (body, Some(footer))
            }
            None => (
                ui::empty_state(
                    Ico::Clock,
                    lokalbot_i18n::tr("Select a Session"),
                    lokalbot_i18n::tr("Choose a saved session to see its workspace and reopen it."),
                    cx,
                )
                .into_any_element(),
                None,
            ),
        };

        v_flex()
            .w_full()
            .gap(px(12.))
            .child(
                h_flex()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        div()
                            .flex_1()
                            .text_size(ty::COLUMN_TITLE)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Saved Sessions",
                            ))),
                    )
                    .child(
                        Button::new("agent-saved-refresh")
                            .ghost()
                            .small()
                            .icon(Icon::new(Ico::RefreshCw))
                            .tooltip(lokalbot_i18n::tr("Refresh"))
                            .disabled(self.loading)
                            .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
                    )
                    .child(
                        Button::new("agent-saved-close")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Close"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    ),
            )
            .child(
                h_flex()
                    .h(px(460.))
                    .gap(px(16.))
                    .items_start()
                    .child(
                        v_flex()
                            .w(px(290.))
                            .h_full()
                            .gap(px(8.))
                            .child(Input::new(&self.input).cleanable(true).prefix(ui::icon(
                                Ico::Search,
                                px(14.),
                                lb.text_secondary,
                            )))
                            .child(
                                div()
                                    .id("agent-saved-list")
                                    .flex_1()
                                    .min_h_0()
                                    .overflow_y_scroll()
                                    .child(v_flex().gap(px(2.)).children(rows)),
                            ),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .h_full()
                            .gap(px(14.))
                            .child(
                                div()
                                    .id("agent-saved-detail")
                                    .flex_1()
                                    .min_h_0()
                                    .overflow_y_scroll()
                                    .px(px(12.))
                                    .child(detail),
                            )
                            .when_some(footer, |this, footer| {
                                this.child(div().px(px(12.)).child(footer))
                            }),
                    ),
            )
    }
}
