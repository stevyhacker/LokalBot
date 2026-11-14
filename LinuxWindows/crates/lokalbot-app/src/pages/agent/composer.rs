//! The composer (`AgentComposer.swift`): what the agent is told to do, what
//! to attach, the working folder and how much it may do on its own. A message
//! sent while the agent works waits above the field until the turn ends.

use std::path::PathBuf;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::input::Textarea;
use gpui_kit::component::menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Div, ExternalPaths, Focusable as _, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, PathPromptOptions, SharedString,
    StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use uuid::Uuid;

use lokalbot_agent::endpoint::{Destination, ModelContext};
use lokalbot_agent::session::{ReasoningChoices, reasoning_name};
use lokalbot_agent::tasks::{Attachment, AttachmentKind, QueuedPrompt};
use lokalbot_agent::{ApprovalMode, SessionState};
use lokalbot_core::settings::ReasoningLevel;

use super::conversation::Snapshot;
use super::{AgentPage, words};
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

fn destination_label(destination: &Destination) -> String {
    match destination {
        Destination::OnDevice => lokalbot_i18n::tr("On this PC").into(),
        Destination::Remote(host) => {
            lokalbot_i18n::format("Remote · {host}", &[("host", host.clone())])
        }
        Destination::Blocked(_) => lokalbot_i18n::tr("Model connection blocked").into(),
    }
}

/// What the composer shows, copied out of the selected task.
struct View {
    task: Uuid,
    queued: Vec<QueuedPrompt>,
    notice: Option<&'static str>,
    error: Option<String>,
    attachments: Vec<Attachment>,
    mode: ApprovalMode,
    choices: ReasoningChoices,
    model: ModelContext,
    model_differs: bool,
    workspace_name: String,
    state: SessionState,
    stopping: bool,
    sending: bool,
}

/// What the access popover needs, cloned into its content builder.
#[derive(Clone)]
struct Access {
    mode: ApprovalMode,
    workspace_name: String,
    model: ModelContext,
    model_differs: bool,
    choices: ReasoningChoices,
    shell: Option<String>,
}

impl AgentPage {
    fn composer_view(&self, cx: &App) -> Option<View> {
        let model = self.model(cx)?;
        let tasks = model.tasks.as_ref()?;
        let tab = tasks.selected()?;
        let session = &tab.session;
        let settings = self.data.read(cx).settings.clone();
        let presented = session.presented_model();
        Some(View {
            task: tab.id,
            queued: session.queued_prompts.clone(),
            notice: session.workspace_access_notice(),
            error: session.composer_error.clone(),
            attachments: session.attachments.clone(),
            mode: session.approval_mode(),
            choices: session
                .reasoning_choices
                .clone()
                .unwrap_or_else(|| ReasoningChoices::for_settings(&settings)),
            model_differs: session.model_context.is_some()
                && presented != ModelContext::from_settings(&settings),
            model: presented,
            workspace_name: session.workspace_display_name(),
            state: session.state.clone(),
            stopping: session.is_stopping,
            sending: session.is_sending || session.is_waiting_to_send(),
        })
    }

    /// Asks the Think server what the selected model accepts, once per model
    /// (`AgentComposer`). A task started afterwards offers those levels.
    fn look_up_reasoning(&mut self, cx: &mut Context<Self>) {
        let settings = self.data.read(cx).settings.clone();
        let key = lokalbot_ai::think::reasoning_lookup_key(&settings);
        if self.reasoning_asked.as_ref() == Some(&key) {
            return;
        }
        self.reasoning_asked = Some(key);
        cx.spawn(async move |this, cx| {
            cx.background_spawn(async move {
                lokalbot_ai::think::refresh_reasoning_choices(&settings);
            })
            .await;
            let _ = this.update(cx, |_, cx| cx.notify());
        })
        .detach();
    }

    /// The queue, notices, the field and its controls, and where prompts go
    /// when the model is not on this computer.
    pub(super) fn render_composer(
        &mut self,
        snapshot: &Snapshot,
        is_new_task: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.look_up_reasoning(cx);
        let Some(view) = self.composer_view(cx) else {
            return div().into_any_element();
        };
        let lb = cx.lb().clone();
        let mut rows: Vec<AnyElement> = Vec::new();
        if !view.queued.is_empty() {
            rows.push(self.render_queue(&view, cx));
        }
        if let Some(notice) = view.notice {
            rows.push(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.attention_text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(notice)))
                    .into_any_element(),
            );
        }
        if let Some(error) = view.error.clone() {
            rows.push(
                h_flex()
                    .gap(px(8.))
                    .items_start()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(error),
                    )
                    .child(
                        super::small_icon_button(
                            "agent-dismiss-error",
                            Ico::X,
                            lokalbot_i18n::tr("Dismiss message"),
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.with_session(cx, |s| s.composer_error = None)
                        })),
                    )
                    .into_any_element(),
            );
        }
        if snapshot.archived {
            let task = view.task;
            rows.push(
                Button::new("agent-restore-task")
                    .outline()
                    .w_full()
                    .label(lokalbot_i18n::tr("Restore task to continue"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.with_tasks(cx, |tasks| tasks.set_archived(task, false))
                    }))
                    .into_any_element(),
            );
        } else {
            rows.push(
                self.render_surface(&view, is_new_task, window, cx)
                    .into_any_element(),
            );
        }
        if let Some(line) = self.render_destination_line(&view, cx) {
            rows.push(line);
        }
        v_flex()
            .w_full()
            .gap(px(8.))
            .children(rows)
            .into_any_element()
    }

    /// Up to three rows show whole; a longer queue scrolls in the same space.
    fn render_queue(&mut self, view: &View, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let working = view.state == SessionState::Running;
        let task = view.task;
        let send_disabled = view.sending || view.stopping || view.state == SessionState::Starting;
        let label = if working {
            lokalbot_i18n::tr("Sends when done")
        } else {
            lokalbot_i18n::tr("Not sent yet")
        };
        let page = cx.entity();
        let mut list = v_flex().gap(px(6.));
        for prompt in &view.queued {
            let id = prompt.id;
            let key = super::key(id);
            let menu_page = page.clone();
            list = list.child(
                h_flex()
                    .id(("agent-queue", key))
                    .gap(px(8.))
                    .items_center()
                    .pl(px(12.))
                    .pr(px(6.))
                    .py(px(5.))
                    .rounded(px(10.))
                    .bg(lb.panel)
                    .border_1()
                    .border_color(lb.group_stroke)
                    .text_size(ty::SECONDARY)
                    .child(ui::icon(Ico::Clock, px(13.), lb.text_secondary))
                    .child(div().flex_none().text_color(lb.text_secondary).child(label))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_color(lb.text)
                            .child(prompt.text.clone()),
                    )
                    .child(
                        Button::new(("agent-queue-send", key))
                            .outline()
                            .xsmall()
                            .label(lokalbot_i18n::tr("Send now"))
                            .tooltip(if working {
                                lokalbot_i18n::tr("Steer the current task at its next opportunity")
                            } else {
                                lokalbot_i18n::tr("Send now")
                            })
                            .disabled(send_disabled)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.follow_output = true;
                                this.with_tasks(cx, |tasks| tasks.send_queued_now(task, id));
                            })),
                    )
                    .child(
                        super::small_icon_button(
                            ("agent-queue-remove", key),
                            Ico::X,
                            lokalbot_i18n::tr("Remove queued message"),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.with_session(cx, |s| s.cancel_queued(id))
                        })),
                    )
                    .context_menu(move |menu, _, _| {
                        let edit = menu_page.clone();
                        let remove = menu_page.clone();
                        menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Edit")).on_click(
                            move |_, window, cx| {
                                edit.update(cx, |page, cx| {
                                    page.with_session(cx, |s| s.edit_queued(id));
                                    page.sync_composer(window, cx);
                                    page.focus_composer(window, cx);
                                })
                            },
                        ))
                        .item(
                            PopupMenuItem::new(lokalbot_i18n::tr("Remove")).on_click(
                                move |_, _, cx| {
                                    remove.update(cx, |page, cx| {
                                        page.with_session(cx, |s| s.cancel_queued(id))
                                    })
                                },
                            ),
                        )
                    }),
            );
        }
        if view.queued.len() <= 3 {
            list.into_any_element()
        } else {
            div()
                .id("agent-queue-scroll")
                .h(px(118.))
                .overflow_y_scroll()
                .child(list)
                .into_any_element()
        }
    }

    fn render_surface(
        &mut self,
        view: &View,
        is_new_task: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let focused = self
            .composer
            .read(cx)
            .focus_handle(cx)
            .contains_focused(window, cx);
        let has_prompt = !self.synced_draft.trim().is_empty();
        let working = view.state == SessionState::Running;
        let starting = view.state == SessionState::Starting;
        self.update_placeholder(working, is_new_task, window, cx);

        let mut chips = h_flex().gap(px(8.)).flex_wrap();
        for attachment in &view.attachments {
            let preview = attachment.clone();
            let remove = attachment.id.clone();
            chips = chips.child(
                h_flex()
                    .gap(px(2.))
                    .items_center()
                    .pl(px(8.))
                    .rounded_full()
                    .bg(lb.chip_fill)
                    .child(
                        h_flex()
                            .id(SharedString::from(format!("agent-chip-{}", attachment.id)))
                            .gap(px(4.))
                            .items_center()
                            .cursor_pointer()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text)
                            .child(ui::icon(
                                attachment_icon(attachment.kind),
                                px(12.),
                                lb.text_secondary,
                            ))
                            .child(
                                div()
                                    .max_w(px(220.))
                                    .truncate()
                                    .child(attachment.title.clone()),
                            )
                            .on_click(
                                cx.listener(move |this, _, _, cx| {
                                    this.preview_source(&preview, cx)
                                }),
                            ),
                    )
                    .child(
                        super::small_icon_button(
                            SharedString::from(format!("agent-chip-remove-{}", attachment.id)),
                            Ico::X,
                            lokalbot_i18n::format(
                                "Remove {0}",
                                &[("0", attachment.title.to_string())],
                            ),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            let remove = remove.clone();
                            this.with_session(cx, |s| s.remove_attachment(&remove))
                        })),
                    ),
            );
        }

        // While the agent works, Send queues the message (Ctrl+Enter steers).
        let send = h_flex()
            .gap(px(8.))
            .items_center()
            .when(working, |this| {
                this.child(
                    Button::new("agent-stop")
                        .outline()
                        .icon(Icon::new(Ico::Square))
                        .label(lokalbot_i18n::tr("Stop"))
                        .disabled(view.stopping)
                        .on_click(
                            cx.listener(|this, _, _, cx| this.with_session(cx, |s| s.abort())),
                        ),
                )
            })
            .child(
                Button::new("agent-send")
                    .primary()
                    .icon(Icon::new(Ico::ArrowUp))
                    .label(lokalbot_i18n::tr("Send"))
                    .font_weight(FontWeight::SEMIBOLD)
                    .disabled(!has_prompt || view.stopping || starting || view.sending)
                    .on_click(cx.listener(|this, _, window, cx| this.submit(false, window, cx))),
            );

        let controls = h_flex()
            .w_full()
            .gap(px(4.))
            .items_center()
            .flex_wrap()
            .child(self.attach_menu(cx))
            .child(
                Button::new("agent-workspace")
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::Folder))
                    .label(view.workspace_name.clone())
                    .tooltip(lokalbot_i18n::tr("The agent works in this folder. Choosing another folder after a task has started opens a new task."))
                    .on_click(cx.listener(|this, _, window, cx| this.choose_workspace(window, cx))),
            )
            .child(self.access_chip(view, cx))
            .child(div().flex_1().min_w(px(4.)))
            .child(send);

        v_flex()
            .w_full()
            .gap(px(10.))
            .pl(px(14.))
            .pr(px(10.))
            .pt(px(14.))
            .pb(px(10.))
            .rounded(metric::COMPOSER_RADIUS)
            .bg(lb.panel)
            .border_1()
            .border_color(if focused {
                lb.accent_fill.opacity(0.6)
            } else {
                lb.separator
            })
            .shadow_sm()
            .drag_over::<ExternalPaths>(|style, _, _, cx| style.border_color(cx.lb().accent_fill))
            .on_drop(cx.listener(|this, paths: &ExternalPaths, _, cx| {
                let files: Vec<PathBuf> = paths.paths().to_vec();
                this.attach_files(files, cx);
            }))
            .when(!view.attachments.is_empty(), |this| this.child(chips))
            .child(
                Textarea::new(&self.composer)
                    .appearance(false)
                    .xsmall()
                    .text_size(px(self.text_size.min(17.)))
                    .line_height(px(21.))
                    .disabled(starting),
            )
            .child(controls)
    }

    /// "Add to this task" while it works, "Ask the agent…" for a new task,
    /// "Ask a follow-up" otherwise.
    fn update_placeholder(
        &mut self,
        working: bool,
        is_new_task: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let placeholder = if working {
            lokalbot_i18n::tr("Add to this task")
        } else if is_new_task {
            lokalbot_i18n::tr("Ask the agent…")
        } else {
            lokalbot_i18n::tr("Ask a follow-up")
        };
        if self.composer_placeholder != placeholder {
            self.composer_placeholder = placeholder;
            self.composer.update(cx, |state, cx| {
                state.set_placeholder(placeholder, window, cx)
            });
        }
    }

    fn attach_menu(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let page = cx.entity();
        Button::new("agent-attach")
            .ghost()
            .small()
            .icon(Icon::new(Ico::Plus))
            .tooltip(lokalbot_i18n::tr("Attach context"))
            .dropdown_menu(move |menu, _, _| {
                let files = page.clone();
                let context = page.clone();
                menu.item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Files…"))
                        .on_click(move |_, _, cx| files.update(cx, |page, cx| page.pick_files(cx))),
                )
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Meetings and saved moments…")).on_click(
                        move |_, window, cx| {
                            context.update(cx, |page, cx| page.open_context_picker(window, cx))
                        },
                    ),
                )
            })
    }

    /// Names what the agent does on its own, and opens the levels with the
    /// model and reasoning below them.
    fn access_chip(&self, view: &View, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let mode = view.mode;
        let access = Access {
            mode,
            workspace_name: view.workspace_name.clone(),
            model: view.model.clone(),
            model_differs: view.model_differs,
            choices: view.choices.clone(),
            shell: self
                .model(cx)
                .map(|m| m.shell.description())
                .filter(|_| cfg!(windows)),
        };
        let page = cx.entity();
        let data = self.data.clone();
        let tint = if words::needs_caution(mode) {
            lb.attention_text
        } else {
            lb.text
        };
        Popover::new("agent-access")
            .anchor(gpui_kit::Anchor::TopLeft)
            .trigger(
                Button::new("agent-approval-mode")
                    .ghost()
                    .small()
                    .icon(Icon::new(mode_icon(mode)).text_color(tint))
                    .child(
                        div()
                            .text_color(tint)
                            .font_weight(FontWeight::MEDIUM)
                            .child(words::chip_title(mode)),
                    )
                    .dropdown_caret(true)
                    .tooltip(words::level_detail(mode, &view.workspace_name)),
            )
            .content(move |_, _, cx| render_access(&access, &page, &data, cx))
    }

    /// Shown only when the model is not on this computer, so where a task's
    /// prompts go stays in view without opening the access list.
    fn render_destination_line(&self, view: &View, cx: &mut Context<Self>) -> Option<AnyElement> {
        if view.model.destination == Destination::OnDevice {
            return None;
        }
        let lb = cx.lb().clone();
        let icon = match view.model.destination {
            Destination::Remote(_) => Ico::Network,
            _ => Ico::TriangleAlert,
        };
        Some(
            h_flex()
                .gap(px(5.))
                .items_center()
                .px(px(4.))
                .text_size(ty::SECONDARY)
                .text_color(lb.attention_text)
                .child(ui::icon(icon, px(13.), lb.attention_text))
                .child(div().flex_1().min_w_0().child(format!(
                    "{} · {}",
                    view.model.name,
                    destination_label(&view.model.destination)
                )))
                .into_any_element(),
        )
    }

    // ------------------------------------------------------- attachments

    fn pick_files(&mut self, cx: &mut Context<Self>) {
        let receiver = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some(lokalbot_i18n::tr("Attach").into()),
        });
        cx.spawn(async move |this, cx| {
            let picked = receiver.await;
            let _ = this.update(cx, |this, cx| match picked {
                Ok(Ok(Some(paths))) => this.attach_files(paths, cx),
                Ok(Ok(None)) => {}
                Ok(Err(err)) => this.with_session(cx, |s| {
                    s.composer_error = Some(lokalbot_i18n::format(
                        "No file chooser is available: {err}",
                        &[("err", format!("{:#}", err))],
                    ))
                }),
                Err(_) => {}
            });
        })
        .detach();
    }

    fn attach_files(&mut self, paths: Vec<PathBuf>, cx: &mut Context<Self>) {
        self.with_session(cx, |session| {
            for path in paths.iter().filter(|p| p.is_file()) {
                session.add_attachment(Attachment::file(path));
            }
        });
    }

    pub(super) fn preview_source(&mut self, attachment: &Attachment, cx: &mut Context<Self>) {
        let resolver = self.model(cx).and_then(|m| {
            m.tasks
                .as_ref()?
                .selected()
                .map(|t| t.session.context_resolver())
        });
        let Some(resolver) = resolver else { return };
        match resolver.resolve(attachment) {
            Ok(preview) => self.show_preview(preview, cx),
            Err(error) => {
                let message = error.to_string();
                self.with_session(cx, |s| s.composer_error = Some(message));
            }
        }
    }

    /// A new working folder applies to this task while it is empty and
    /// unsaved; otherwise it starts a new task (`pickingFolder`).
    fn choose_workspace(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        let receiver = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some(lokalbot_i18n::tr("Choose Working Folder").into()),
        });
        cx.spawn(async move |this, cx| {
            let picked = receiver.await;
            let _ = this.update(cx, |this, cx| match picked {
                Ok(Ok(Some(paths))) => {
                    if let Some(folder) = paths.into_iter().next() {
                        this.apply_workspace(folder, cx);
                    }
                }
                Ok(Err(err)) => this.with_session(cx, |s| {
                    s.composer_error = Some(lokalbot_i18n::format(
                        "No folder chooser is available: {err}",
                        &[("err", format!("{:#}", err))],
                    ))
                }),
                _ => {}
            });
        })
        .detach();
    }

    fn apply_workspace(&mut self, folder: PathBuf, cx: &mut Context<Self>) {
        let folder = dunce_like(folder);
        self.with_tasks(cx, |tasks| {
            let id = tasks.selected_id;
            let Some(tab) = tasks.tab(id) else { return };
            if let Some(notice) = tab.session.workspace_access_notice_for(&folder) {
                if let Some(session) = tasks.session_mut(id) {
                    session.composer_error = Some(notice.into());
                }
                return;
            }
            let reuse = tab.session.items().is_empty()
                && !tab.session.has_live_runtime()
                && tab.record.session_file.is_none();
            let target = if reuse { id } else { tasks.add_session() };
            if let Some(session) = tasks.session_mut(target) {
                session.workspace = folder;
            }
            tasks.persist();
        });
    }
}

/// The access list: the levels by what still asks, then the model and
/// reasoning. The level is one remembered choice for every task.
fn render_access(
    access: &Access,
    page: &gpui_kit::Entity<AgentPage>,
    data: &gpui_kit::Entity<crate::state::AppData>,
    cx: &mut Context<gpui_kit::component::popover::PopoverState>,
) -> AnyElement {
    let lb = cx.lb().clone();
    let mut levels = v_flex().gap(px(10.));
    for mode in ApprovalMode::ALL {
        let selected = mode == access.mode;
        let current = access.mode;
        let page = page.clone();
        levels = levels.child(
            h_flex()
                .id(("agent-access-level", mode.raw_value() as u64))
                .gap(px(10.))
                .items_start()
                .cursor_pointer()
                .rounded(px(6.))
                .child(div().pt(px(2.)).child(ui::icon(
                    if selected {
                        Ico::CircleDot
                    } else {
                        Ico::Circle
                    },
                    px(15.),
                    if selected {
                        lb.accent_text
                    } else {
                        lb.text_secondary
                    },
                )))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(words::level_title(mode)),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(if words::needs_caution(mode) {
                                    lb.attention_text
                                } else {
                                    lb.text_secondary
                                })
                                .child(crate::ui::text::paragraph(words::level_detail(
                                    mode,
                                    &access.workspace_name,
                                ))),
                        ),
                )
                .on_click(cx.listener(move |state, _, window, cx| {
                    state.dismiss(window, cx);
                    // Raising the level is confirmed; lowering it applies at once.
                    if mode > current {
                        confirm_mode(page.clone(), mode, window, cx);
                    } else {
                        page.update(cx, |page, cx| {
                            page.with_session(cx, |s| s.set_approval_mode(mode))
                        });
                    }
                })),
        );
    }
    let label = |text: &'static str| {
        div()
            .w(px(78.))
            .flex_none()
            .text_color(lb.text_secondary)
            .child(text)
    };
    let open_models = data.clone();
    let model_row = h_flex()
        .gap(px(10.))
        .items_start()
        .child(label(lokalbot_i18n::tr("Model")))
        .child(div().flex_1().min_w_0().text_color(lb.text).child(format!(
            "{} · {}",
            access.model.name,
            destination_label(&access.model.destination)
        )))
        .child(ui::link(
            "agent-change-model",
            lokalbot_i18n::tr("Change…"),
            move |_, cx| {
                open_models.update(cx, |data, cx| {
                    data.open_settings(SettingsCategory::Models, cx)
                })
            },
            cx,
        ));
    let remote = match &access.model.destination {
        Destination::Remote(host) => Some(lokalbot_i18n::mac(
            "Your messages, attached context and what the agent reads are sent to %@.",
            &[host],
        )),
        _ => None,
    };
    v_flex()
        .w(px(360.))
        .p(px(6.))
        .gap(px(12.))
        .text_size(ty::SECONDARY)
        .child(
            h_flex()
                .items_center()
                .child(
                    div()
                        .flex_1()
                        .text_size(ty::SECTION)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(lokalbot_i18n::tr("Access")),
                )
                .child(
                    div()
                        .text_color(lb.text_secondary)
                        .child(lokalbot_i18n::tr("All tasks")),
                ),
        )
        .child(levels)
        .child(
            div()
                .text_color(lb.text_secondary)
                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                    "Editing LokalBot’s own data files always asks first.",
                ))),
        )
        .child(ui::divider(cx))
        .child(model_row)
        .when(access.choices.is_adjustable(), |this| {
            this.child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(label(lokalbot_i18n::tr("Reasoning")))
                    .child(reasoning_menu(&access.choices, data, cx)),
            )
        })
        .when_some(remote, |this, remote| {
            this.child(
                div()
                    .text_color(lb.attention_text)
                    .child(crate::ui::text::paragraph(remote)),
            )
        })
        .when(access.model_differs, |this| {
            this.child(
                div()
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "New tasks use the model selected in Settings.",
                    ))),
            )
        })
        .when_some(access.shell.clone(), |this, shell| {
            this.child(
                div()
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(shell)),
            )
        })
        .into_any_element()
}

/// Agent Mode's own level, or "Same as Think", offering only the levels the
/// model accepts.
fn reasoning_menu(
    choices: &ReasoningChoices,
    data: &gpui_kit::Entity<crate::state::AppData>,
    cx: &App,
) -> impl IntoElement + use<> {
    let settings = data.read(cx).settings.clone();
    let chosen = settings.agent_reasoning_level;
    let shown = choices.displayed(settings.effective_agent_reasoning_level());
    let checked = chosen.map(|level| choices.displayed(level));
    let same_as_think = lokalbot_i18n::format(
        "Same as Think ({0})",
        &[(
            "0",
            lokalbot_i18n::tr(reasoning_name(
                choices.displayed(settings.think_reasoning_level),
            ))
            .to_string(),
        )],
    );
    let data = data.clone();
    let choices = choices.clone();
    Button::new("agent-reasoning")
        .outline()
        .small()
        .label(lokalbot_i18n::tr(reasoning_name(shown)))
        .dropdown_caret(true)
        .tooltip(lokalbot_i18n::tr("How much the agent reasons before each step, from the levels this model accepts. Same as Think follows Settings → Models. A change applies from the agent's next step."))
        .dropdown_menu(move |mut menu, _, _| {
            let choose = |level: Option<ReasoningLevel>| {
                let data = data.clone();
                move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                    data.update(cx, |data, cx| {
                        data.update_settings(|s| s.agent_reasoning_level = level, cx)
                    })
                }
            };
            menu = menu
                .min_w(px(220.))
                .item(
                    PopupMenuItem::new(same_as_think.clone())
                        .checked(chosen.is_none())
                        .on_click(choose(None)),
                )
                .separator();
            let mut levels = vec![ReasoningLevel::Automatic];
            levels.extend(choices.levels.iter().copied());
            for level in levels {
                let title = if level == ReasoningLevel::Automatic {
                    match choices.default_level {
                        Some(default) => lokalbot_i18n::format("Automatic ({level})", &[("level", lokalbot_i18n::tr(reasoning_name(default)).into())]),
                        None => lokalbot_i18n::tr("Automatic").into(),
                    }
                } else {
                    lokalbot_i18n::tr(reasoning_name(level)).to_string()
                };
                menu = menu.item(
                    PopupMenuItem::new(title)
                        .checked(checked == Some(level))
                        .on_click(choose(Some(level))),
                );
            }
            menu
        })
}

/// Canonical folder paths (no `\\?\` on Windows) compare and display cleanly.
fn dunce_like(path: PathBuf) -> PathBuf {
    std::fs::canonicalize(&path)
        .map(|p| {
            let text = p.to_string_lossy().into_owned();
            PathBuf::from(text.strip_prefix(r"\\?\").unwrap_or(&text))
        })
        .unwrap_or(path)
}

fn attachment_icon(kind: AttachmentKind) -> Ico {
    match kind {
        AttachmentKind::File => Ico::FileText,
        AttachmentKind::Meeting => Ico::AudioLines,
        AttachmentKind::Moment => Ico::Bookmark,
    }
}

pub(super) fn mode_icon(mode: ApprovalMode) -> Ico {
    match mode {
        ApprovalMode::AskBeforeChanges => Ico::Hand,
        ApprovalMode::ApproveReads => Ico::Eye,
        ApprovalMode::ApproveReadsAndEdits => Ico::Pencil,
        ApprovalMode::FullAccess => Ico::LockOpen,
    }
}

/// Escalations ask first (`pendingMode` alert).
fn confirm_mode(
    page: gpui_kit::Entity<AgentPage>,
    mode: ApprovalMode,
    window: &mut Window,
    cx: &mut App,
) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let page = page.clone();
        alert
            .title(lokalbot_i18n::tr(mode.confirmation_title()))
            .description(lokalbot_i18n::tr(mode.confirmation_message()))
            .confirm()
            .ok_text(lokalbot_i18n::tr(mode.confirmation_action()))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Keep Current Mode"))
            .on_ok(move |_, _, cx| {
                page.update(cx, |page, cx| {
                    page.with_session(cx, |s| s.set_approval_mode(mode))
                });
                true
            })
    });
}
