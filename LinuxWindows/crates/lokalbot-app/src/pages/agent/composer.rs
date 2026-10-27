//! The composer (`AgentComposer.swift`): queued follow-ups, attachments, the
//! working folder, approval mode and reasoning level, send/steer/stop, and the
//! model line with the task's access details.

use std::path::PathBuf;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::input::Textarea;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, ExternalPaths, Focusable as _, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, PathPromptOptions, SharedString,
    StatefulInteractiveElement as _, Styled as _, Window, div, linear_color_stop, linear_gradient,
    px,
};
use uuid::Uuid;

use lokalbot_agent::endpoint::{Destination, ModelContext};
use lokalbot_agent::session::{ReasoningChoices, reasoning_name};
use lokalbot_agent::tasks::{Attachment, AttachmentKind, QueuedPrompt};
use lokalbot_agent::{ApprovalMode, SessionState};
use lokalbot_core::settings::ReasoningLevel;

use super::AgentPage;
use super::conversation::Snapshot;
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
    queue_paused: bool,
    notice: Option<&'static str>,
    error: Option<String>,
    attachments: Vec<Attachment>,
    mode: ApprovalMode,
    choices: ReasoningChoices,
    model: ModelContext,
    model_differs: bool,
    workspace_name: String,
    workspace_path: PathBuf,
    state: SessionState,
    stopping: bool,
    sending: bool,
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
            queue_paused: session.queue_is_paused,
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
            workspace_path: session.workspace.clone(),
            state: session.state.clone(),
            stopping: session.is_stopping,
            sending: session.is_sending || session.is_waiting_to_send(),
        })
    }

    pub(super) fn render_composer(
        &mut self,
        snapshot: &Snapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(view) = self.composer_view(cx) else {
            return div().into_any_element();
        };
        let lb = cx.lb().clone();
        let mut rows: Vec<AnyElement> = Vec::new();
        if !view.queued.is_empty() {
            rows.push(self.render_queue(&view, cx).into_any_element());
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
            rows.push(self.render_surface(&view, window, cx).into_any_element());
        }
        rows.push(self.render_model_line(&view, cx).into_any_element());

        div()
            .relative()
            .w_full()
            .flex_none()
            .child(
                div()
                    .absolute()
                    .top(px(-14.))
                    .left_0()
                    .right_0()
                    .h(px(14.))
                    .bg(linear_gradient(
                        180.,
                        linear_color_stop(lb.window.opacity(0.), 0.),
                        linear_color_stop(lb.window.opacity(0.7), 1.),
                    )),
            )
            .child(
                v_flex().w_full().items_center().bg(lb.window).child(
                    v_flex()
                        .w_full()
                        .max_w(metric::READING_MAX_WIDTH + px(40.))
                        .px(px(20.))
                        .pt(px(12.))
                        .pb(px(14.))
                        .gap(px(8.))
                        .children(rows),
                ),
            )
            .into_any_element()
    }

    fn render_queue(&mut self, view: &View, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let expanded = self.queue_expanded;
        let task = view.task;
        let idle = !matches!(view.state, SessionState::Running | SessionState::Starting);
        let title = lokalbot_i18n::format(
            if view.queue_paused {
                "Queued follow-ups: {count} · paused"
            } else {
                "Queued follow-ups: {count}"
            },
            &[("count", view.queued.len().to_string())],
        );
        let mut list = v_flex().gap(px(6.)).pt(px(6.));
        for prompt in &view.queued {
            let edit_id = prompt.id;
            let cancel_id = prompt.id;
            list = list.child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .line_clamp(2)
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(prompt.text.clone()),
                    )
                    .child(
                        Button::new(("agent-queue-edit", super::key(prompt.id)))
                            .ghost()
                            .xsmall()
                            .label(lokalbot_i18n::tr("Edit"))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.with_session(cx, |s| s.edit_queued(edit_id));
                                this.sync_composer(window, cx);
                                this.focus_composer(window, cx);
                            })),
                    )
                    .child(
                        Button::new(("agent-queue-cancel", super::key(prompt.id)))
                            .ghost()
                            .xsmall()
                            .label(lokalbot_i18n::tr("Cancel"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.with_session(cx, |s| s.cancel_queued(cancel_id))
                            })),
                    ),
            );
        }
        v_flex()
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .child(
                        h_flex()
                            .id("agent-queue-toggle")
                            .flex_1()
                            .gap(px(6.))
                            .items_center()
                            .cursor_pointer()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(ui::icon(
                                if expanded {
                                    Ico::ChevronDown
                                } else {
                                    Ico::ChevronRight
                                },
                                px(11.),
                                lb.text_secondary,
                            ))
                            .child(title)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.queue_expanded = !this.queue_expanded;
                                cx.notify();
                            })),
                    )
                    .when(idle, |this| {
                        this.child(
                            Button::new("agent-queue-send-next")
                                .ghost()
                                .xsmall()
                                .label(lokalbot_i18n::tr("Send next"))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.with_tasks(cx, |tasks| tasks.send_next_queued(task))
                                })),
                        )
                    }),
            )
            .when(expanded, |this| {
                this.child(
                    div()
                        .id("agent-queue")
                        .max_h(px(120.))
                        .overflow_y_scroll()
                        .child(list),
                )
            })
    }

    fn render_surface(&mut self, view: &View, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let focused = self
            .composer
            .read(cx)
            .focus_handle(cx)
            .contains_focused(window, cx);
        let has_prompt = !self.synced_draft.trim().is_empty();
        let running = view.state == SessionState::Running;
        let starting = view.state == SessionState::Starting;

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

        let send_label = if running {
            lokalbot_i18n::tr("Queue follow-up")
        } else {
            lokalbot_i18n::tr("Send")
        };
        let send_icon = if running { Ico::ListPlus } else { Ico::ArrowUp };
        let send = h_flex()
            .gap(px(8.))
            .items_center()
            .when(running, |this| {
                this.child(
                    Button::new("agent-stop")
                        .outline()
                        .small()
                        .icon(Icon::new(Ico::CircleStop))
                        .label(lokalbot_i18n::tr("Stop"))
                        .disabled(view.stopping)
                        .on_click(
                            cx.listener(|this, _, _, cx| this.with_session(cx, |s| s.abort())),
                        ),
                )
                .child(
                    Button::new("agent-steer")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Send now"))
                        .tooltip(lokalbot_i18n::tr(
                            "Steer the current task at its next opportunity (Ctrl+Enter)",
                        ))
                        .disabled(!has_prompt || view.sending || view.stopping)
                        .on_click(cx.listener(|this, _, window, cx| this.submit(true, window, cx))),
                )
            })
            .child(
                Button::new("agent-send")
                    .primary()
                    .icon(Icon::new(send_icon))
                    .label(send_label)
                    .font_weight(FontWeight::SEMIBOLD)
                    .disabled(!has_prompt || view.stopping || starting || view.sending)
                    .on_click(cx.listener(|this, _, window, cx| this.submit(false, window, cx))),
            );

        let controls = h_flex()
            .gap(px(6.))
            .items_center()
            .flex_wrap()
            .child(self.attach_menu(cx))
            .child(
                Button::new("agent-workspace")
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::Folder))
                    .label(view.workspace_name.clone())
                    .tooltip(lokalbot_i18n::tr("Files in the chosen folder can be read automatically and sent to the displayed model. Private-library reads still follow the approval mode. Changing folders in an existing conversation starts a new task."))
                    .on_click(cx.listener(|this, _, window, cx| this.choose_workspace(window, cx))),
            )
            .child(self.approval_menu(view.mode, cx))
            .when(view.choices.is_adjustable(), |this| {
                this.child(self.reasoning_menu(&view.choices, cx))
            })
            .child(div().flex_1())
            .child(send);

        v_flex()
            .w_full()
            .gap(px(12.))
            .px(px(10.))
            .pt(px(12.))
            .pb(px(12.))
            .rounded(metric::COMPOSER_RADIUS)
            .bg(lb.elevated)
            .border_1()
            .border_color(if focused {
                lb.accent_fill.opacity(0.45)
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

    fn approval_menu(
        &self,
        mode: ApprovalMode,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let page = cx.entity();
        Button::new("agent-approval-mode")
            .ghost()
            .small()
            .icon(Icon::new(mode_icon(mode)))
            .label(lokalbot_i18n::tr(mode.title()))
            .dropdown_caret(true)
            .tooltip(lokalbot_i18n::tr(mode.detail()))
            .dropdown_menu(move |mut menu, _, _| {
                menu = menu.min_w(px(240.));
                for option in ApprovalMode::ALL {
                    let page = page.clone();
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(option.title()))
                            .checked(option == mode)
                            .on_click(move |_, window, cx| {
                                if option > mode {
                                    confirm_mode(page.clone(), option, window, cx);
                                } else {
                                    page.update(cx, |page, cx| {
                                        page.with_session(cx, |s| s.set_approval_mode(option))
                                    });
                                }
                            }),
                    );
                }
                menu
            })
    }

    /// Agent Mode's own level, or "Same as Think", offering only the levels
    /// the model accepts.
    fn reasoning_menu(
        &self,
        choices: &ReasoningChoices,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let settings = self.data.read(cx).settings.clone();
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
        let data = self.data.clone();
        let choices = choices.clone();
        Button::new("agent-reasoning")
            .ghost()
            .small()
            .icon(Icon::new(Ico::Brain))
            .label(lokalbot_i18n::format("Reasoning: {0}", &[("0", lokalbot_i18n::tr(reasoning_name(shown)).to_string())]))
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

    fn render_model_line(&mut self, view: &View, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let (icon, tint) = match &view.model.destination {
            Destination::OnDevice => (Ico::Monitor, lb.text_secondary),
            Destination::Remote(_) => (Ico::Network, lb.accent_text),
            Destination::Blocked(_) => (Ico::TriangleAlert, lb.attention_text),
        };
        let label = format!(
            "{} · {}",
            view.model.name,
            destination_label(&view.model.destination)
        );
        let mode = view.mode;
        let path = view.workspace_path.display().to_string();
        let destination = destination_label(&view.model.destination);
        let differs = view.model_differs;
        let shell = self
            .model(cx)
            .map(|m| m.shell.description())
            .filter(|_| cfg!(windows));
        h_flex()
            .gap(px(5.))
            .items_center()
            .text_size(ty::SECONDARY)
            .text_color(lb.text_secondary)
            .child(ui::icon(icon, px(13.), tint))
            .child(div().flex_1().min_w_0().truncate().child(label))
            .child(
                Popover::new("agent-access")
                    .anchor(gpui_kit::Anchor::BottomRight)
                    .trigger(
                        Button::new("agent-access-button")
                            .ghost()
                            .xsmall()
                            .icon(Icon::new(Ico::Info))
                            .tooltip(lokalbot_i18n::tr("Task access details")),
                    )
                    .content(move |_, _, cx| {
                        let lb = cx.lb().clone();
                        let paragraph = |text: String| {
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text)
                                .child(text)
                        };
                        v_flex()
                            .w(px(360.))
                            .gap(px(12.))
                            .p(px(6.))
                            .child(
                                div()
                                    .text_size(ty::SECTION)
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("This task’s access"))),
                            )
                            .child(
                                h_flex()
                                    .gap(px(6.))
                                    .items_center()
                                    .child(ui::icon(Ico::Folder, px(13.), lb.text_secondary))
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .truncate()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.text)
                                            .child(path.clone()),
                                    ),
                            )
                            .child(paragraph(lokalbot_i18n::tr(mode.detail()).to_string()))
                            .child(paragraph(lokalbot_i18n::tr("The working folder is separate from LokalBot’s private data. Meeting Library tools provide scoped local read access when this task runs. Saved screen moments require the separate screen-memory grant. Raw private-library file reads follow the approval mode even when a parent folder is selected.").to_string()))
                            .child(paragraph(lokalbot_i18n::format("{destination}. Attached text is included when you send. Files and tool actions follow the approval mode above.", &[("destination", destination.to_string())])))
                            .when_some(shell.clone(), |this, shell| this.child(paragraph(shell)))
                            .when(differs, |this| {
                                this.child(paragraph(lokalbot_i18n::tr("New tasks use the model selected in Settings.").to_string()))
                            })
                    }),
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

fn mode_icon(mode: ApprovalMode) -> Ico {
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
