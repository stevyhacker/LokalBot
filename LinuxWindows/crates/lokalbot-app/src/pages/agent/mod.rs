//! Agent (`AgentView.swift`): a local coding and file agent powered by the
//! selected Think model. Before setup the page explains Agent Mode and offers
//! "Set Up Agent Mode"; afterwards it shows the task list, the conversation
//! with its approval dock and composer, and an optional results panel.
//!
//! The work happens in [`model::AgentModel`] (the installer and the
//! `lokalbot-agent` task list); this view owns only presentation state.

mod approval;
mod composer;
mod conversation;
mod dialogs;
pub mod model;
mod results;
mod setup;
mod sidebar;

use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use crate::i18n::h_flex;
use gpui_kit::component::input::{InputEvent, InputState, TextareaState};
use gpui_kit::component::{Icon, Selectable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClipboardItem, Context, Entity, InteractiveElement as _,
    IntoElement, KeyBinding, ParentElement as _, Render, ScrollHandle, SharedString, Styled as _,
    Subscription, Window, actions, div,
};
use uuid::Uuid;

use lokalbot_agent::InstallPhase;
use lokalbot_agent::tasks::ResultPreview;

use self::model::AgentModel;
use crate::pages::Page;
use crate::state::{AppData, Section};
use crate::theme::LbThemeExt as _;
use crate::ui::{Ico, controls};

actions!(
    agent,
    [
        NewTask,
        SearchTasks,
        FindInTask,
        PreviousTask,
        NextTask,
        ToggleResults,
        FocusComposer,
        IncreaseTextSize,
        DecreaseTextSize,
        ResetTextSize
    ]
);

const KEY_CONTEXT: &str = "Agent";
const DEFAULT_TEXT_SIZE: f32 = 15.;

/// `AgentCommands.swift`, with Ctrl for ⌘.
fn bind_keys(cx: &mut App) {
    let context = Some(KEY_CONTEXT);
    cx.bind_keys([
        KeyBinding::new("ctrl-n", NewTask, context),
        KeyBinding::new("ctrl-shift-f", SearchTasks, context),
        KeyBinding::new("ctrl-f", FindInTask, context),
        KeyBinding::new("ctrl-alt-left", PreviousTask, context),
        KeyBinding::new("ctrl-alt-right", NextTask, context),
        KeyBinding::new("ctrl-alt-b", ToggleResults, context),
        KeyBinding::new("ctrl-l", FocusComposer, context),
        KeyBinding::new("ctrl-=", IncreaseTextSize, context),
        KeyBinding::new("ctrl-+", IncreaseTextSize, context),
        KeyBinding::new("ctrl--", DecreaseTextSize, context),
        KeyBinding::new("ctrl-0", ResetTextSize, context),
    ]);
}

pub struct AgentPage {
    data: Entity<AppData>,
    model: Option<Entity<AgentModel>>,
    composer: Entity<TextareaState>,
    /// The task whose draft the composer shows, and that draft as last synced.
    composer_task: Option<Uuid>,
    synced_draft: String,
    composer_placeholder: &'static str,
    task_search: Entity<InputState>,
    task_query: String,
    find_input: Entity<InputState>,
    find_query: String,
    find_visible: bool,
    match_index: usize,
    show_archived: bool,
    results_visible: bool,
    preview: Option<ResultPreview>,
    preview_error: Option<String>,
    transcript_scroll: ScrollHandle,
    follow_output: bool,
    last_item_count: usize,
    expanded_groups: HashSet<String>,
    expanded_details: HashSet<String>,
    collapsed_approvals: HashSet<String>,
    queue_expanded: bool,
    text_size: f32,
    copied: Option<String>,
    /// Parsed responses by item id, with the hash of the text they came from.
    answers: HashMap<String, (u64, Rc<crate::ui::answer_text::Answer>)>,
    last_section: Section,
    _subscriptions: Vec<Subscription>,
}

impl AgentPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        bind_keys(cx);
        let data = AppData::global(cx);
        let composer = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(2, 8)
                .submit_on_enter(true)
                .placeholder(crate::i18n::placeholder("Ask the agent…", window, cx))
        });
        let task_search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search tasks",
                window,
                cx,
            ))
        });
        let find_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Find in this task",
                window,
                cx,
            ))
        });
        let subscriptions = vec![
            cx.observe_in(&data, window, |this, data, window, cx| {
                let section = data.read(cx).section;
                if section == Section::Agent {
                    this.ensure_model(window, cx);
                    if this.last_section != Section::Agent {
                        this.focus_composer(window, cx);
                    }
                }
                this.last_section = section;
            }),
            cx.subscribe_in(
                &composer,
                window,
                |this, input, event: &InputEvent, window, cx| match event {
                    InputEvent::Change => {
                        let value = input.read(cx).value().to_string();
                        if value != this.synced_draft {
                            this.synced_draft = value.clone();
                            this.with_session(cx, |session| session.draft = value);
                        }
                    }
                    InputEvent::PressEnter { secondary, shift } if !shift => {
                        this.submit(*secondary, window, cx)
                    }
                    _ => {}
                },
            ),
            cx.subscribe_in(
                &task_search,
                window,
                |this, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        this.task_query = input.read(cx).value().to_string();
                        cx.notify();
                    }
                },
            ),
            cx.subscribe_in(
                &find_input,
                window,
                |this, input, event: &InputEvent, _, cx| match event {
                    InputEvent::Change => {
                        this.find_query = input.read(cx).value().to_string();
                        this.match_index = 0;
                        this.follow_output = false;
                        this.scroll_to_match(cx);
                        cx.notify();
                    }
                    InputEvent::PressEnter { .. } => this.next_match(1, cx),
                    _ => {}
                },
            ),
        ];
        let last_section = data.read(cx).section;
        let mut page = Self {
            data,
            model: None,
            composer,
            composer_task: None,
            synced_draft: String::new(),
            composer_placeholder: lokalbot_i18n::tr("Ask the agent…"),
            task_search,
            task_query: String::new(),
            find_input,
            find_query: String::new(),
            find_visible: false,
            match_index: 0,
            show_archived: false,
            results_visible: false,
            preview: None,
            preview_error: None,
            transcript_scroll: ScrollHandle::new(),
            follow_output: true,
            last_item_count: 0,
            expanded_groups: HashSet::new(),
            expanded_details: HashSet::new(),
            collapsed_approvals: HashSet::new(),
            queue_expanded: true,
            text_size: DEFAULT_TEXT_SIZE,
            copied: None,
            answers: HashMap::new(),
            last_section,
            _subscriptions: subscriptions,
        };
        if last_section == Section::Agent {
            page.ensure_model(window, cx);
            // `AgentComposer.onAppear`: the composer is ready for typing.
            page.focus_composer(window, cx);
        }
        page
    }

    /// The controller is created on the first visit, so a library that
    /// never uses Agent Mode never touches its files.
    fn ensure_model(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.model.is_some() {
            return;
        }
        let data = self.data.clone();
        let model = cx.new(|cx| AgentModel::new(data, cx));
        let subscription = cx.observe_in(&model, window, |this, _, window, cx| {
            this.sync_composer(window, cx);
            this.follow_transcript(cx);
            this.show_task_error(cx);
            cx.notify();
        });
        self._subscriptions.push(subscription);
        self.model = Some(model);
    }

    // ------------------------------------------------------------ helpers

    fn model<'a>(&self, cx: &'a App) -> Option<&'a AgentModel> {
        self.model.as_ref().map(|m| m.read(cx))
    }

    fn selected_id(&self, cx: &App) -> Option<Uuid> {
        self.model(cx)?.tasks.as_ref().map(|t| t.selected_id)
    }

    /// Changes the selected task's session.
    fn with_session(
        &mut self,
        cx: &mut Context<Self>,
        change: impl FnOnce(&mut lokalbot_agent::AgentSession),
    ) {
        self.with_tasks(cx, |tasks| {
            let id = tasks.selected_id;
            if let Some(session) = tasks.session_mut(id) {
                change(session);
            }
        });
    }

    /// Changes the task list (and schedules a save).
    fn with_tasks(
        &mut self,
        cx: &mut Context<Self>,
        change: impl FnOnce(&mut lokalbot_agent::TaskList),
    ) {
        if let Some(model) = &self.model {
            model.update(cx, |model, cx| {
                model.update_tasks(cx, change);
            });
        }
    }

    /// Keeps the composer showing the selected task's draft. Typing writes
    /// the draft; a change made by the task (sent, restored, edited from the
    /// queue) is written back into the composer.
    fn sync_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((id, draft, running)) = self.model(cx).and_then(|m| {
            let tasks = m.tasks.as_ref()?;
            let tab = tasks.selected()?;
            Some((
                tab.id,
                tab.session.draft.clone(),
                tab.session.state == lokalbot_agent::SessionState::Running,
            ))
        }) else {
            return;
        };
        let placeholder = if running {
            lokalbot_i18n::tr("Add a follow-up or steer the agent…")
        } else {
            lokalbot_i18n::tr("Ask the agent…")
        };
        if self.composer_task != Some(id) || draft != self.synced_draft {
            self.composer_task = Some(id);
            self.synced_draft = draft.clone();
            self.composer
                .update(cx, |state, cx| state.set_value(draft, window, cx));
        }
        if self.composer_placeholder != placeholder {
            self.composer_placeholder = placeholder;
            self.composer.update(cx, |state, cx| {
                state.set_placeholder(placeholder, window, cx)
            });
        }
    }

    fn follow_transcript(&mut self, cx: &mut Context<Self>) {
        let count = self
            .model(cx)
            .and_then(|m| {
                m.tasks
                    .as_ref()?
                    .selected()
                    .map(|t| t.session.items().len())
            })
            .unwrap_or(0);
        if self.follow_output && !self.find_visible && count != self.last_item_count {
            self.transcript_scroll.scroll_to_bottom();
        }
        self.last_item_count = count;
    }

    fn focus_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer
            .update(cx, |state, cx| state.focus(window, cx));
    }

    /// Send, queue a follow-up, or (with `steer`) steer the running turn.
    fn submit(&mut self, steer: bool, _window: &mut Window, cx: &mut Context<Self>) {
        self.follow_output = true;
        self.with_tasks(cx, |tasks| {
            let id = tasks.selected_id;
            let running = tasks
                .tab(id)
                .is_some_and(|t| t.session.state == lokalbot_agent::SessionState::Running);
            tasks.submit(id, steer && running);
        });
        self.transcript_scroll.scroll_to_bottom();
    }

    fn select_task(&mut self, id: Uuid, window: &mut Window, cx: &mut Context<Self>) {
        self.preview = None;
        self.preview_error = None;
        self.find_query.clear();
        self.find_visible = false;
        self.follow_output = true;
        self.with_tasks(cx, |tasks| tasks.select(id));
        self.sync_composer(window, cx);
        self.transcript_scroll.scroll_to_bottom();
        self.focus_composer(window, cx);
    }

    fn new_task(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let mut created = None;
        self.with_tasks(cx, |tasks| created = Some(tasks.add_session()));
        if let Some(id) = created {
            self.select_task(id, window, cx);
        }
    }

    fn show_preview(&mut self, preview: ResultPreview, cx: &mut Context<Self>) {
        self.preview = Some(preview);
        self.preview_error = None;
        self.results_visible = true;
        cx.notify();
    }

    fn copy(&mut self, key: String, text: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        self.copied = Some(key.clone());
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(1500))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.copied.as_deref() == Some(key.as_str()) {
                    this.copied = None;
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn set_text_size(&mut self, size: f32, cx: &mut Context<Self>) {
        self.text_size = size.clamp(12., 24.);
        cx.notify();
    }
}

impl Page for AgentPage {
    fn title(&self, _cx: &App) -> SharedString {
        lokalbot_i18n::tr("Agent").into()
    }

    /// Find and the results panel (`taskActions`).
    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let installed = self.model(cx)?.phase == InstallPhase::Installed;
        if !installed {
            return None;
        }
        Some(
            h_flex()
                .gap_1()
                .child(
                    controls::toolbar_icon(
                        "agent-find",
                        Ico::Search,
                        lokalbot_i18n::tr("Find in task (Ctrl+F)"),
                    )
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.open_find(window, cx);
                    })),
                )
                .child(
                    controls::toolbar_icon(
                        "agent-results",
                        Ico::PanelRight,
                        lokalbot_i18n::tr("Results and sources (Ctrl+Alt+B)"),
                    )
                    .when(self.results_visible, |this| this.selected(true))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.results_visible = !this.results_visible;
                        cx.notify();
                    })),
                )
                .into_any_element(),
        )
    }
}

impl AgentPage {
    fn open_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.find_visible = true;
        self.find_input
            .update(cx, |state, cx| state.focus(window, cx));
        cx.notify();
    }
}

impl Render for AgentPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let installed = self
            .model(cx)
            .is_some_and(|m| m.phase == InstallPhase::Installed && m.tasks.is_some());
        let body = if installed {
            h_flex()
                .size_full()
                .child(self.render_sidebar(window, cx))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .h_full()
                        .child(self.render_conversation(window, cx)),
                )
                .when(self.results_visible, |this| {
                    this.child(self.render_results(window, cx))
                })
                .into_any_element()
        } else {
            self.render_setup(cx).into_any_element()
        };
        div()
            .id("agent-page")
            .size_full()
            .key_context(KEY_CONTEXT)
            .bg(lb.window)
            .on_action(cx.listener(|this, _: &NewTask, window, cx| this.new_task(window, cx)))
            .on_action(cx.listener(|this, _: &SearchTasks, window, cx| {
                this.task_search
                    .update(cx, |state, cx| state.focus(window, cx));
            }))
            .on_action(cx.listener(|this, _: &FindInTask, window, cx| this.open_find(window, cx)))
            .on_action(cx.listener(|this, _: &PreviousTask, window, cx| {
                this.with_tasks(cx, |tasks| tasks.select_neighbor(-1));
                this.sync_composer(window, cx);
            }))
            .on_action(cx.listener(|this, _: &NextTask, window, cx| {
                this.with_tasks(cx, |tasks| tasks.select_neighbor(1));
                this.sync_composer(window, cx);
            }))
            .on_action(cx.listener(|this, _: &ToggleResults, _, cx| {
                this.results_visible = !this.results_visible;
                cx.notify();
            }))
            .on_action(
                cx.listener(|this, _: &FocusComposer, window, cx| this.focus_composer(window, cx)),
            )
            .on_action(cx.listener(|this, _: &IncreaseTextSize, _, cx| {
                this.set_text_size(this.text_size + 1., cx)
            }))
            .on_action(cx.listener(|this, _: &DecreaseTextSize, _, cx| {
                this.set_text_size(this.text_size - 1., cx)
            }))
            .on_action(cx.listener(|this, _: &ResetTextSize, _, cx| {
                this.set_text_size(DEFAULT_TEXT_SIZE, cx)
            }))
            .on_action(
                cx.listener(|this, _: &gpui_kit::component::input::Escape, _, cx| {
                    // Escape denies the approval on screen (`.cancelAction`).
                    if !this.deny_visible_approval(cx) {
                        cx.propagate();
                    }
                }),
            )
            .child(body)
    }
}

/// A 64-bit element key derived from a UUID.
fn key(id: Uuid) -> u64 {
    let (high, low) = id.as_u64_pair();
    high ^ low
}

/// An icon button for small inline actions.
fn small_icon_button(
    id: impl Into<gpui_kit::ElementId>,
    icon: Ico,
    tooltip: impl Into<SharedString>,
) -> gpui_kit::component::button::Button {
    use gpui_kit::component::Sizable as _;
    use gpui_kit::component::button::ButtonVariants as _;
    gpui_kit::component::button::Button::new(id)
        .ghost()
        .xsmall()
        .icon(Icon::new(icon))
        .tooltip(tooltip)
}
