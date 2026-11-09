//! The selection actions panel (`SelectionActionsView.swift`): the selected
//! text and where it came from, the actions that fit it, and the streamed
//! result with ways to use it. A 620×460 window; everything it shows comes from
//! the engine and is forgotten when it closes.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::{Escape, Input, InputEvent, InputState, MoveDown, MoveUp};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Entity, FocusHandle, FontWeight, Hsla,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Render, ScrollHandle,
    SharedString, StatefulInteractiveElement as _, Styled as _, Subscription, Window, WindowBounds,
    WindowKind, WindowOptions, div, px, size,
};
use lokalbot_ai::selection::{Action, ActionResult, MemorySource, SELECTION_CHARACTER_LIMIT};
use lokalbot_engine::{Command, SelectionCommand, SelectionPhase, SelectionView};
use lokalbot_platform::SelectionIssue;

use crate::pages::ask::composer_inference;
use crate::state::{AppData, MeetingTab};
use crate::theme::{FONT_FAMILY, LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

const WIDTH: f32 = 620.;
const HEIGHT: f32 = 460.;

fn send(command: SelectionCommand, cx: &mut App) {
    crate::bridge::send(Command::Selection(command), cx);
}

/// Opens the panel, or brings the open one forward.
pub fn open(cx: &mut App) {
    let existing = super::secondary(cx).selection_actions;
    if super::activate(existing, cx) {
        let view = super::secondary(cx)
            .selection_actions_view
            .clone()
            .and_then(|view| view.upgrade());
        if let (Some(handle), Some(view)) = (existing, view) {
            let _ = handle.update(cx, |_, window, cx| {
                view.update(cx, |view, cx| view.focus_for_phase(window, cx))
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
    #[cfg(target_os = "linux")]
    let layer = super::layer_surface(
        "lokalbot-selection-actions",
        gpui_kit::layer_shell::Anchor::empty(),
        None,
        gpui_kit::layer_shell::KeyboardInteractivity::Exclusive,
    );
    #[cfg(not(target_os = "linux"))]
    let layer: Option<WindowKind> = None;
    let opened = match layer {
        Some(kind) => gpui_kit::open_window(options(kind), cx, build).or_else(|err| {
            log::debug!("selection actions: no layer shell, opening a window: {err:#}");
            gpui_kit::open_window(options(window_kind()), cx, build)
        }),
        None => gpui_kit::open_window(options(window_kind()), cx, build),
    };
    match opened {
        Ok((handle, view)) => {
            let windows = super::secondary(cx);
            windows.selection_actions = Some(handle);
            windows.selection_actions_view = Some(view.downgrade());
        }
        Err(err) => log::error!("could not open selection actions: {err:#}"),
    }
}

fn build(window: &mut Window, cx: &mut App) -> Entity<SelectionActions> {
    window.set_window_title(lokalbot_i18n::tr("Selection actions"));
    let view = cx.new(|cx| SelectionActions::new(window, cx));
    view.update(cx, |view, cx| view.focus_for_phase(window, cx));
    view
}

pub struct SelectionActions {
    data: Entity<AppData>,
    input: Entity<InputState>,
    query: String,
    selection: usize,
    /// Typed instructions read matching meetings and work memory unless this
    /// is turned off.
    instruction_uses_memory: bool,
    focus: FocusHandle,
    scroll: ScrollHandle,
    was_choosing: bool,
    _subscriptions: Vec<Subscription>,
}

impl SelectionActions {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Choose an action or describe what to do…",
                window,
                cx,
            ))
        });
        let subscriptions = vec![
            cx.subscribe_in(
                &input,
                window,
                |this, input, event: &InputEvent, _, cx| match event {
                    InputEvent::Change => {
                        let value = input.read(cx).value().to_string();
                        if value != this.query {
                            this.query = value;
                            this.selection = 0;
                            cx.notify();
                        }
                    }
                    InputEvent::PressEnter { .. } => this.run_selected(cx),
                    _ => {}
                },
            ),
            cx.observe_in(&data, window, |this, _, window, cx| {
                let choosing = this.data.read(cx).selection_actions.is_choosing();
                // A new press with the panel still open starts over.
                if this.data.read(cx).selection_actions.phase == SelectionPhase::Capturing
                    && !this.query.is_empty()
                {
                    this.query.clear();
                    this.selection = 0;
                    this.input
                        .update(cx, |input, cx| input.set_value("", window, cx));
                }
                if choosing != this.was_choosing {
                    this.was_choosing = choosing;
                    this.focus_for_phase(window, cx);
                }
                cx.notify();
            }),
            // However the window goes away, the selection goes with it.
            cx.on_release(|_, cx| send(SelectionCommand::PanelClosed, cx)),
        ];
        Self {
            was_choosing: data.read(cx).selection_actions.is_choosing(),
            data,
            input,
            query: String::new(),
            selection: 0,
            instruction_uses_memory: true,
            focus: cx.focus_handle(),
            scroll: ScrollHandle::new(),
            _subscriptions: subscriptions,
        }
    }

    fn view(&self, cx: &App) -> SelectionView {
        self.data.read(cx).selection_actions.clone()
    }

    /// The input while choosing; the panel itself takes Enter and the
    /// shortcuts while a result shows.
    fn focus_for_phase(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.view(cx).is_choosing() {
            let placeholder = if self.view(cx).has_selection() {
                "Choose an action or describe what to do…"
            } else {
                "Describe what to write…"
            };
            self.input.update(cx, |input, cx| {
                input.set_placeholder(
                    crate::i18n::placeholder(placeholder, window, cx),
                    window,
                    cx,
                );
                input.focus(window, cx);
            });
        } else {
            window.focus(&self.focus, cx);
        }
    }

    fn rows(&self, view: &SelectionView) -> Vec<Action> {
        Action::rows(
            &self.query,
            view.has_selection(),
            self.instruction_uses_memory,
            |title| lokalbot_i18n::tr(title).to_string(),
        )
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        let view = self.view(cx);
        if !view.is_choosing() {
            return;
        }
        let count = self.rows(&view).len();
        if count == 0 {
            return;
        }
        self.selection = (self.selection as isize + delta).rem_euclid(count as isize) as usize;
        self.scroll.scroll_to_item(self.selection);
        cx.notify();
    }

    fn run_selected(&mut self, cx: &mut Context<Self>) {
        let view = self.view(cx);
        if let Some(action) = self.rows(&view).get(self.selection).cloned() {
            self.run(action, cx);
        }
    }

    fn run(&mut self, action: Action, cx: &mut Context<Self>) {
        self.query.clear();
        self.selection = 0;
        send(SelectionCommand::Run(action), cx);
    }

    fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let windows = super::secondary(cx);
        windows.selection_actions = None;
        windows.selection_actions_view = None;
        window.remove_window();
    }

    fn dismiss(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        send(SelectionCommand::Dismiss, cx);
        self.close(window, cx);
    }

    fn copy(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        send(SelectionCommand::Copy, cx);
        self.close(window, cx);
    }

    fn insert(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        send(SelectionCommand::Insert, cx);
        self.close(window, cx);
    }

    fn choose_again(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.input
            .update(cx, |input, cx| input.set_value("", window, cx));
        send(SelectionCommand::ChooseAgain, cx);
    }

    fn open_source(&mut self, source: &MemorySource, window: &mut Window, cx: &mut Context<Self>) {
        let id = source.id;
        self.data.update(cx, |data, cx| {
            data.open_meeting(id, MeetingTab::Summary, None, cx)
        });
        super::activate_main(cx);
        send(SelectionCommand::PanelClosed, cx);
        self.close(window, cx);
    }

    /// Whether the replace button is the default one (`resultButtons`).
    fn replaces_by_default(view: &SelectionView) -> bool {
        view.can_insert
            && view
                .action
                .as_ref()
                .is_some_and(|action| action.result == ActionResult::Replacement)
    }

    /// Enter and the panel's shortcuts while a result shows.
    fn on_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let view = self.view(cx);
        let keystroke = &event.keystroke;
        let control = keystroke.modifiers.control;
        match keystroke.key.as_str() {
            "escape" => self.dismiss(window, cx),
            _ if view.is_choosing() => return,
            "enter" if view.phase == SelectionPhase::Finished => {
                let replaces = Self::replaces_by_default(&view);
                if replaces != control {
                    if view.can_insert {
                        self.insert(window, cx);
                    }
                } else {
                    self.copy(window, cx);
                }
            }
            "r" if control && view.phase != SelectionPhase::Generating => {
                send(SelectionCommand::Retry, cx)
            }
            "[" if control => self.choose_again(window, cx),
            _ => return,
        }
        cx.stop_propagation();
    }

    fn render_header(
        &self,
        view: &SelectionView,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let choosing = view.is_choosing();
        v_flex()
            .gap(px(10.))
            .px(px(18.))
            .py(px(14.))
            .child(if choosing {
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(ui::icon(Ico::TextCursor, px(20.), lb.accent_text))
                    .child(
                        div().flex_1().min_w_0().child(
                            Input::new(&self.input)
                                .appearance(false)
                                .disabled(
                                    view.issue.is_some() || view.phase == SelectionPhase::Capturing,
                                )
                                .text_size(px(20.))
                                .line_height(px(28.))
                                .h(px(32.))
                                .px_0(),
                        ),
                    )
                    .into_any_element()
            } else {
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        Button::new("selection-actions-back")
                            .ghost()
                            .small()
                            .icon(Icon::new(Ico::ChevronLeft))
                            .tooltip(
                                lokalbot_i18n::tr("Choose another action (Ctrl+[)").to_string(),
                            )
                            .on_click(
                                cx.listener(|this, _, window, cx| this.choose_again(window, cx)),
                            ),
                    )
                    .when_some(view.action.as_ref(), |this, action| {
                        this.child(ui::icon(action_icon(action), px(16.), lb.accent_text))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::SECTION)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(action_title(action)),
                            )
                    })
                    .into_any_element()
            })
            .child(
                div()
                    .truncate()
                    .text_size(ty::CAPTION)
                    .text_color(lb.text_secondary)
                    .child(source_line(view)),
            )
            .when(view.has_selection(), |this| {
                this.child(
                    div()
                        .px(px(10.))
                        .py(px(7.))
                        .rounded(metric::ROW_RADIUS)
                        .bg(lb.chip_fill)
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .line_clamp(if choosing { 3 } else { 1 })
                        .child(view.text.trim().to_string()),
                )
            })
    }

    fn render_issue(&self, issue: SelectionIssue, view: &SelectionView, cx: &App) -> AnyElement {
        let lb = cx.lb();
        let app = view
            .source
            .as_ref()
            .map(|source| source.app_name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| lokalbot_i18n::tr("this app").to_string());
        let message: String = match issue {
            SelectionIssue::ExcludedApp => lokalbot_i18n::format(
                "{0} is in your excluded apps, so LokalBot did not read anything from it.",
                &[("0", app)],
            ),
            SelectionIssue::SecureField => lokalbot_i18n::tr(
                "A password field has focus. LokalBot does not read or paste into password fields.",
            )
            .to_string(),
            SelectionIssue::FocusChanged => lokalbot_i18n::tr(
                "LokalBot could not confirm the selected field. Select the text again and press the shortcut.",
            )
            .to_string(),
        };
        v_flex()
            .id("selection-actions-issue")
            .size_full()
            .p(px(24.))
            .gap(px(12.))
            .items_center()
            .justify_center()
            .child(ui::icon(Ico::ShieldCheck, px(26.), lb.text_secondary))
            .child(
                div()
                    .max_w(px(420.))
                    .text_size(ty::BODY)
                    .text_center()
                    .child(message),
            )
            .into_any_element()
    }

    fn render_rows(&self, view: &SelectionView, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let rows = self.rows(view);
        if rows.is_empty() {
            return v_flex()
                .size_full()
                .p(px(24.))
                .gap(px(8.))
                .items_center()
                .justify_center()
                .child(ui::icon(Ico::TextCursor, px(26.), lb.text_secondary))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(lokalbot_i18n::tr("Write with your memory").to_string()),
                )
                .child(
                    div()
                        .max_w(px(420.))
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .text_center()
                        .child(
                            lokalbot_i18n::tr(
                                "Describe what to write, like “a status update on the beta launch”. LokalBot drafts it with the local model and, when on, your meetings and work memory.",
                            )
                            .to_string(),
                        ),
                )
                .into_any_element();
        }
        let white: Hsla = gpui_kit::white();
        v_flex()
            .id("selection-actions-rows")
            .size_full()
            .p(px(8.))
            .gap(px(2.))
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .children(rows.into_iter().enumerate().map(|(index, action)| {
                let selected = index == self.selection;
                let (primary, secondary) = if selected {
                    (white, white)
                } else {
                    (lb.text, lb.text_secondary)
                };
                let detail: Option<&str> = if action.is_custom() {
                    Some(if action.uses_memory {
                        "Run this instruction with your memory"
                    } else {
                        "Run this instruction"
                    })
                } else if action.uses_memory {
                    Some("Uses your meetings and work memory")
                } else {
                    None
                };
                let run = action.clone();
                h_flex()
                    .id(SharedString::from(format!("selection-action-{index}")))
                    .gap(px(12.))
                    .items_center()
                    .px(px(10.))
                    .py(px(8.))
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .when(selected, |this| this.bg(lb.accent_fill))
                    .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
                    .on_click(cx.listener(move |this, _, _, cx| this.run(run.clone(), cx)))
                    .child(div().w(px(26.)).flex().justify_center().child(ui::icon(
                        action_icon(&action),
                        px(16.),
                        if selected { white } else { lb.accent_text },
                    )))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(1.))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .text_color(primary)
                                    .child(action_title(&action)),
                            )
                            .when_some(detail, |this, detail| {
                                this.child(
                                    div()
                                        .text_size(ty::CAPTION)
                                        .text_color(secondary)
                                        .child(lokalbot_i18n::tr(detail).to_string()),
                                )
                            }),
                    )
                    .when(selected, |this| {
                        this.child(ui::icon(Ico::CornerDownLeft, px(13.), white))
                    })
            }))
            .into_any_element()
    }

    fn render_result(&self, view: &SelectionView, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let now = chrono::Local::now();
        v_flex()
            .id("selection-actions-result")
            .size_full()
            .p(px(18.))
            .gap(px(12.))
            .overflow_y_scroll()
            .when_some(view.notice.clone(), |this, notice| {
                this.child(
                    h_flex()
                        .gap(px(8.))
                        .items_start()
                        .p(px(10.))
                        .rounded(metric::ROW_RADIUS)
                        .bg(lb.attention.opacity(0.12))
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(ui::icon(Ico::ClipboardCheck, px(14.), lb.text_secondary))
                        .child(div().flex_1().min_w_0().child(notice)),
                )
            })
            .child(match &view.phase {
                SelectionPhase::Failed(message) => h_flex()
                    .gap(px(8.))
                    .items_start()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text))
                    .child(div().flex_1().min_w_0().child(message.clone()))
                    .into_any_element(),
                _ if view.output.is_empty() => h_flex()
                    .gap(px(8.))
                    .items_center()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(gpui_kit::component::spinner::Spinner::new().small())
                    .child(loading_text(view))
                    .into_any_element(),
                _ => div()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(view.output.clone())
                    .into_any_element(),
            })
            .when(!view.memory_sources.is_empty(), |this| {
                this.child(
                    v_flex()
                        .gap(px(6.))
                        .child(
                            div()
                                .text_size(ty::CAPTION)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text_secondary)
                                .child(lokalbot_i18n::tr("From your memory").to_string()),
                        )
                        .child(
                            h_flex().flex_wrap().gap(px(6.)).children(
                                view.memory_sources
                                    .iter()
                                    .enumerate()
                                    .map(|(index, source)| {
                                        let open = source.clone();
                                        Button::new(SharedString::from(format!(
                                            "selection-actions-source-{index}"
                                        )))
                                        .outline()
                                        .xsmall()
                                        .icon(Icon::new(Ico::AudioLines))
                                        .label(source_label(source, now))
                                        .tooltip(lokalbot_i18n::tr("Open this meeting").to_string())
                                        .on_click(
                                            cx.listener(move |this, _, window, cx| {
                                                this.open_source(&open, window, cx)
                                            }),
                                        )
                                    }),
                            ),
                        ),
                )
            })
            .into_any_element()
    }

    fn render_footer(
        &self,
        view: &SelectionView,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let inference = composer_inference(cx);
        let inference_label = h_flex()
            .gap(px(5.))
            .items_center()
            .text_size(ty::CAPTION)
            .text_color(lb.text_secondary)
            .child(ui::icon(inference.icon, px(12.), lb.text_secondary))
            .child(inference.label);
        let row = h_flex()
            .gap(px(12.))
            .items_center()
            .px(px(18.))
            .py(px(10.))
            .min_h(px(44.));
        if view.is_choosing() {
            return row
                .child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(lokalbot_i18n::tr("↑↓ Navigate   ↩ Run   esc Close").to_string()),
                )
                .child(div().flex_1().min_w_0())
                .child(
                    Checkbox::new("selection-actions-memory")
                        .small()
                        .checked(self.instruction_uses_memory)
                        .label(lokalbot_i18n::tr("Use my memory for typed instructions").to_string())
                        .tooltip(
                            lokalbot_i18n::tr(
                                "Typed instructions search your meetings and work memory first. Built-in rewrites never do.",
                            )
                            .to_string(),
                        )
                        .on_click(cx.listener(|this, checked: &bool, _, cx| {
                            this.instruction_uses_memory = *checked;
                            cx.notify();
                        })),
                )
                .child(inference_label);
        }
        let finished = view.phase == SelectionPhase::Finished;
        let insert_title = if view.has_selection() {
            "Replace Selection"
        } else {
            "Insert"
        };
        let insert = Button::new("selection-actions-insert")
            .small()
            .label(lokalbot_i18n::tr(insert_title).to_string())
            .disabled(!finished)
            .on_click(cx.listener(|this, _, window, cx| this.insert(window, cx)));
        let copy = Button::new("selection-actions-copy")
            .small()
            .label(lokalbot_i18n::tr("Copy").to_string())
            .disabled(!finished)
            .on_click(cx.listener(|this, _, window, cx| this.copy(window, cx)));
        let replaces = Self::replaces_by_default(view);
        row.child(
            Button::new("selection-actions-retry")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Try Again").to_string())
                .disabled(view.phase == SelectionPhase::Generating)
                .on_click(|_, _, cx| send(SelectionCommand::Retry, cx)),
        )
        .child(div().flex_1().min_w_0())
        .child(inference_label)
        .when(replaces, |this| {
            this.child(copy.outline()).child(insert.primary())
        })
        .when(!replaces, |this| {
            let copy = Button::new("selection-actions-copy")
                .small()
                .primary()
                .label(lokalbot_i18n::tr("Copy").to_string())
                .disabled(!finished)
                .on_click(cx.listener(|this, _, window, cx| this.copy(window, cx)));
            let insert = Button::new("selection-actions-insert")
                .small()
                .outline()
                .label(lokalbot_i18n::tr(insert_title).to_string())
                .disabled(!finished)
                .on_click(cx.listener(|this, _, window, cx| this.insert(window, cx)));
            this.when(view.can_insert, |this| this.child(insert))
                .child(copy)
        })
    }
}

/// Built-in titles are interface text; a typed instruction is the user's.
fn action_title(action: &Action) -> String {
    if action.is_custom() {
        action.title.clone()
    } else {
        lokalbot_i18n::tr(&action.title).to_string()
    }
}

fn action_icon(action: &Action) -> Ico {
    match action.id {
        "fixGrammar" => Ico::CircleCheck,
        "improve" => Ico::WandSparkles,
        "shorter" => Ico::Minimize2,
        "professional" => Ico::Briefcase,
        "friendly" => Ico::Heart,
        "translateToEnglish" => Ico::Languages,
        "summarize" => Ico::TextAlignStart,
        "explain" => Ico::Lightbulb,
        "reply" => Ico::Reply,
        _ => Ico::Sparkles,
    }
}

/// Where the text came from and what can happen to the result.
fn source_line(view: &SelectionView) -> String {
    let app = view
        .source
        .as_ref()
        .map_or("", |source| source.app_name.as_str());
    if view.phase == SelectionPhase::Capturing {
        return lokalbot_i18n::tr("Reading the selection…").to_string();
    }
    if view.has_selection() {
        let count = view.text.chars().count();
        let shown = if app.is_empty() {
            lokalbot_i18n::tr("the app").to_string()
        } else {
            app.to_string()
        };
        let mut parts = vec![
            lokalbot_i18n::format("Selected in {0}", &[("0", shown)]),
            lokalbot_i18n::format("{0} characters", &[("0", count.to_string())]),
        ];
        if count > SELECTION_CHARACTER_LIMIT {
            parts.push(lokalbot_i18n::format(
                "the first {0} are used",
                &[("0", SELECTION_CHARACTER_LIMIT.to_string())],
            ));
        }
        if !view.can_insert {
            parts.push(lokalbot_i18n::tr("read-only, so results are copied").to_string());
        }
        return parts.join(" · ");
    }
    if view.can_insert {
        lokalbot_i18n::format(
            "Nothing selected in {0}. The result is inserted at the cursor.",
            &[("0", app.to_string())],
        )
    } else if !app.is_empty() {
        lokalbot_i18n::format(
            "Nothing selected in {0}. The result is copied to the clipboard.",
            &[("0", app.to_string())],
        )
    } else {
        lokalbot_i18n::tr("Nothing selected. The result is copied to the clipboard.").to_string()
    }
}

fn loading_text(view: &SelectionView) -> String {
    let reading_memory = view.action.as_ref().is_some_and(|a| a.uses_memory);
    match &view.model_name {
        None if reading_memory => {
            lokalbot_i18n::tr("Looking through your meetings and work memory…").to_string()
        }
        Some(model) => lokalbot_i18n::format("Writing with {0}…", &[("0", model.clone())]),
        None => lokalbot_i18n::tr("Writing…").to_string(),
    }
}

/// "Design review · 2 Nov".
fn source_label(source: &MemorySource, _now: chrono::DateTime<chrono::Local>) -> String {
    match source.date {
        Some(date) => format!(
            "{} · {}",
            source.title,
            date.with_timezone(&chrono::Local).format_localized(
                lokalbot_i18n::date_pattern("%-d %b"),
                lokalbot_i18n::date_locale(),
            )
        ),
        None => source.title.clone(),
    }
}

impl Render for SelectionActions {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let view = self.view(cx);
        let content: AnyElement = if let Some(issue) = view.issue {
            self.render_issue(issue, &view, cx)
        } else if matches!(view.phase, SelectionPhase::Idle | SelectionPhase::Capturing) {
            div().into_any_element()
        } else if view.phase == SelectionPhase::Choosing {
            self.render_rows(&view, cx)
        } else {
            self.render_result(&view, cx)
        };
        v_flex()
            .size_full()
            .track_focus(&self.focus)
            .key_context("SelectionActions")
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
            .on_action(cx.listener(|this, _: &Escape, window, cx| this.dismiss(window, cx)))
            .on_key_down(cx.listener(Self::on_key))
            .child(self.render_header(&view, cx))
            .child(ui::divider(cx))
            .child(div().flex_1().min_h_0().child(content))
            .child(ui::divider(cx))
            .child(self.render_footer(&view, cx))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_platform::FrontApp;

    fn view(app: &str, text: &str, can_insert: bool) -> SelectionView {
        SelectionView {
            phase: SelectionPhase::Choosing,
            source: Some(FrontApp {
                app_name: app.into(),
                ..FrontApp::default()
            }),
            text: text.into(),
            can_insert,
            ..SelectionView::default()
        }
    }

    #[test]
    fn the_source_line_says_what_can_happen_to_the_result() {
        assert_eq!(
            source_line(&view("Editor", "hello", true)),
            "Selected in Editor · 5 characters"
        );
        assert_eq!(
            source_line(&view("Reader", "hello", false)),
            "Selected in Reader · 5 characters · read-only, so results are copied"
        );
        assert_eq!(
            source_line(&view("Editor", " ", true)),
            "Nothing selected in Editor. The result is inserted at the cursor."
        );
        assert_eq!(
            source_line(&view("Reader", "", false)),
            "Nothing selected in Reader. The result is copied to the clipboard."
        );
        assert_eq!(
            source_line(&SelectionView::default()),
            "Nothing selected. The result is copied to the clipboard."
        );
        let long = "a".repeat(SELECTION_CHARACTER_LIMIT + 1);
        assert!(source_line(&view("Editor", &long, true)).contains("the first 12000 are used"),);
    }

    #[test]
    fn replacing_is_the_default_only_for_replacements() {
        let mut result = view("Editor", "hello", true);
        result.action = Some(Action::custom("shorter please", false));
        assert!(SelectionActions::replaces_by_default(&result));
        result.action = Action::built_in().into_iter().find(|a| a.id == "summarize");
        assert!(!SelectionActions::replaces_by_default(&result));
        result.action = Some(Action::custom("shorter please", false));
        result.can_insert = false;
        assert!(!SelectionActions::replaces_by_default(&result));
    }

    #[test]
    fn loading_says_what_it_is_waiting_for() {
        let mut waiting = SelectionView::default();
        assert_eq!(loading_text(&waiting), "Writing…");
        waiting.action = Action::built_in().into_iter().find(|a| a.id == "reply");
        assert_eq!(
            loading_text(&waiting),
            "Looking through your meetings and work memory…"
        );
        waiting.model_name = Some("Qwen".into());
        assert_eq!(loading_text(&waiting), "Writing with Qwen…");
    }
}
