//! One task (`AgentSessionView.swift`): a new task's heading and composer
//! mid-page, or the conversation with the composer docked under it. While
//! the agent works its words show in full and its steps fold to one line a
//! run; a finished turn folds its work into one steps line above its answer
//! and the files it changed. An approval request docks above the composer.

use std::borrow::Cow;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash as _, Hasher as _};
use std::path::PathBuf;
use std::rc::Rc;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px, relative,
};
use uuid::Uuid;

use lokalbot_agent::presentation::{self, Block, ChangedFile, Place, StepGroup, TaskStatus};
use lokalbot_agent::tasks::{AttachmentKind, ResultPreview};
use lokalbot_agent::transcript::ApprovalRequest;
use lokalbot_agent::{RecoveryAction, SessionState, ToolStatus, TranscriptItem};

use super::words::{self, StepContext, StepLabel};
use super::{AgentPage, small_icon_button};
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::answer_text::{self, Answer, AnswerStyle};
use crate::ui::citations::CitationSource;
use crate::ui::{self, Ico};

/// What the conversation shows for the selected task, copied out of the
/// model so rendering can borrow the page mutably.
pub(super) struct Snapshot {
    pub task: Uuid,
    pub status: TaskStatus,
    pub state: SessionState,
    pub items: Vec<TranscriptItem>,
    pub approvals: Vec<ApprovalRequest>,
    pub recovery: Option<RecoveryAction>,
    pub has_failed_prompt: bool,
    pub archived: bool,
    pub can_branch: bool,
    /// Nothing has been said yet, so the composer sits mid-page.
    pub is_new_task: bool,
    pub workspace: PathBuf,
    pub workspace_name: String,
    pub write_targets: Vec<(String, bool)>,
}

impl Snapshot {
    fn is_working(&self) -> bool {
        self.state == SessionState::Running
    }

    /// The files the given steps wrote or edited.
    pub fn changed_files(&self, steps: &[TranscriptItem]) -> Vec<ChangedFile> {
        ChangedFile::list(steps, &self.workspace, &self.workspace_name, |id| {
            self.write_targets
                .iter()
                .find(|(step, _)| step == id)
                .map(|(_, existed)| *existed)
        })
    }
}

/// `starters` in `AgentSessionView`.
const STARTERS: [(&str, &str, Ico); 3] = [
    (
        "Draft follow-up",
        "Draft a follow-up from my most recent meeting. Do not send it.",
        Ico::CornerDownRight,
    ),
    (
        "Prepare stand-up",
        "Prepare a concise stand-up update from my recent meetings and open actions.",
        Ico::Users,
    ),
    (
        "Export actions",
        "Prepare a local Markdown export of my open meeting actions. Show me the plan before writing files.",
        Ico::Share,
    ),
];

impl AgentPage {
    pub(super) fn snapshot(&self, cx: &App) -> Option<Snapshot> {
        let tasks = self.model(cx)?.tasks.as_ref()?;
        let tab = tasks.selected()?;
        let session = &tab.session;
        let approvals: Vec<ApprovalRequest> =
            session.pending_approvals().into_iter().cloned().collect();
        let busy = matches!(
            session.state,
            SessionState::Running | SessionState::Starting
        ) || session.is_sending;
        let items = session.items().to_vec();
        let write_targets = items
            .iter()
            .filter_map(|item| match item {
                TranscriptItem::Tool { id, .. } => session
                    .write_target_existed(id)
                    .map(|existed| (id.clone(), existed)),
                _ => None,
            })
            .collect();
        Some(Snapshot {
            task: tab.id,
            status: super::task_status(tab),
            state: session.state.clone(),
            is_new_task: items.is_empty()
                && tab.saved.is_none()
                && !session.is_failed()
                && session.state != SessionState::Running,
            items,
            approvals,
            recovery: session.recovery_action,
            has_failed_prompt: session.failed_prompt.is_some(),
            archived: tab.record.is_archived,
            can_branch: !busy
                && (session.active_session_file.is_some() || tab.record.session_file.is_some()),
            workspace: session.workspace.clone(),
            workspace_name: session.workspace_display_name(),
            write_targets,
        })
    }

    /// A meeting's title from the ID or ID prefix a lookup names.
    pub(super) fn meeting_title(&self, cx: &App) -> impl Fn(&str) -> Option<String> + 'static {
        let meetings: Vec<(String, String)> = self
            .data
            .read(cx)
            .meetings
            .iter()
            .map(|m| (m.id.to_string().to_lowercase(), m.display_title()))
            .collect();
        move |id: &str| {
            if id.chars().count() < 6 {
                return None;
            }
            let id = id.to_lowercase();
            meetings
                .iter()
                .find(|(meeting, _)| meeting.starts_with(&id))
                .map(|(_, title)| title.clone())
        }
    }

    pub(super) fn render_conversation(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(snapshot) = self.snapshot(cx) else {
            return div().into_any_element();
        };
        let lb = cx.lb().clone();
        if snapshot.is_new_task {
            return self.render_new_task(&snapshot, window, cx);
        }
        let approval = snapshot
            .approvals
            .first()
            .cloned()
            .map(|request| self.render_approval_dock(&request, &snapshot, window, cx));
        let composer = self.render_composer(&snapshot, false, window, cx);
        v_flex()
            .size_full()
            .bg(lb.page)
            .when(self.find_visible, |this| {
                this.child(self.render_find_bar(&snapshot, cx))
            })
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(self.render_transcript(&snapshot, window, cx)),
            )
            .when_some(approval, |this, dock| {
                this.child(reading_column(dock).pb(px(8.)))
            })
            .child(reading_column(composer).pt(px(4.)).pb(px(14.)))
            .into_any_element()
    }

    /// The heading, what the agent may do, the composer and three starters,
    /// a little above the middle of the pane.
    fn render_new_task(
        &mut self,
        snapshot: &Snapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let mode = self
            .model(cx)
            .and_then(|m| m.tasks.as_ref()?.selected())
            .map(|t| t.session.approval_mode())
            .unwrap_or_default();
        let mut starters = h_flex().flex_wrap().gap(px(10.));
        for (index, (title, prompt, icon)) in STARTERS.iter().enumerate() {
            let prompt = prompt.to_string();
            starters = starters.child(
                Button::new(("agent-starter", index as u64))
                    .outline()
                    .icon(Icon::new(*icon))
                    .label(lokalbot_i18n::tr(title))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        let prompt = prompt.clone();
                        this.with_session(cx, |session| session.draft = prompt);
                        this.sync_composer(window, cx);
                        this.focus_composer(window, cx);
                    })),
            );
        }
        let composer = self.render_composer(snapshot, true, window, cx);
        div()
            .id("agent-new-task")
            .size_full()
            .bg(lb.page)
            .overflow_y_scroll()
            .child(
                v_flex()
                    .min_h_full()
                    .w_full()
                    .items_center()
                    .justify_center()
                    .px(px(20.))
                    .pt(px(24.))
                    .pb(px(84.))
                    .child(
                        v_flex()
                            .w_full()
                            .max_w(px(640.))
                            .child(
                                div()
                                    .text_size(ty::QUESTION)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "What would you like to work on?",
                                    ))),
                            )
                            .child(
                                div()
                                    .pt(px(8.))
                                    .text_size(ty::SECONDARY)
                                    .text_color(if words::needs_caution(mode) {
                                        lb.attention_text
                                    } else {
                                        lb.text_secondary
                                    })
                                    .child(crate::ui::text::paragraph(words::capability(mode))),
                            )
                            .child(div().pt(px(18.)).child(composer))
                            .child(div().pt(px(22.)).child(starters)),
                    ),
            )
            .into_any_element()
    }

    // ------------------------------------------------------------ find

    /// Block ids whose text contains the find query.
    fn matches(&self, blocks: &[Block]) -> Vec<String> {
        let query = self.find_query.trim().to_lowercase();
        if query.is_empty() {
            return Vec::new();
        }
        blocks
            .iter()
            .filter(|block| block.searchable_text().to_lowercase().contains(&query))
            .map(Block::id)
            .collect()
    }

    pub(super) fn scroll_to_match(&mut self, cx: &mut Context<Self>) {
        let Some(snapshot) = self.snapshot(cx) else {
            return;
        };
        let blocks = presentation::layout(&snapshot.items, snapshot.is_working());
        // A match inside a folded run of steps opens that run.
        let query = self.find_query.trim().to_lowercase();
        if !query.is_empty() {
            for block in &blocks {
                if let Block::Steps(group) = block
                    && group
                        .entries
                        .iter()
                        .any(|e| e.searchable_text().to_lowercase().contains(&query))
                {
                    self.expanded_steps.insert(group.id.clone());
                }
            }
        }
        let matches = self.matches(&blocks);
        let Some(target) = matches.get(self.match_index) else {
            return;
        };
        if let Some(index) = blocks.iter().position(|b| &b.id() == target) {
            self.transcript_scroll.scroll_to_item(index);
        }
    }

    pub(super) fn next_match(&mut self, step: isize, cx: &mut Context<Self>) {
        let Some(snapshot) = self.snapshot(cx) else {
            return;
        };
        let blocks = presentation::layout(&snapshot.items, snapshot.is_working());
        let count = self.matches(&blocks).len() as isize;
        if count == 0 {
            return;
        }
        self.match_index =
            ((self.match_index as isize + step) % count + count) as usize % count as usize;
        self.follow_output = false;
        self.scroll_to_match(cx);
        cx.notify();
    }

    fn render_find_bar(&self, snapshot: &Snapshot, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let blocks = presentation::layout(&snapshot.items, snapshot.is_working());
        let count = self.matches(&blocks).len();
        let label = if count == 0 {
            lokalbot_i18n::tr("0 matches").to_string()
        } else {
            lokalbot_i18n::format(
                "{0} of {count}",
                &[
                    ("0", format!("{}", self.match_index.min(count - 1) + 1)),
                    ("count", format!("{}", count)),
                ],
            )
        };
        reading_column(
            h_flex()
                .w_full()
                .gap(px(8.))
                .items_center()
                .child(
                    div().flex_1().child(
                        Input::new(&self.find_input)
                            .small()
                            .cleanable(true)
                            .prefix(ui::icon(Ico::Search, px(13.), lb.text_secondary)),
                    ),
                )
                .child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(label),
                )
                .child(
                    small_icon_button(
                        "agent-find-previous",
                        Ico::ChevronUp,
                        lokalbot_i18n::tr("Previous match"),
                    )
                    .on_click(cx.listener(|this, _, _, cx| this.next_match(-1, cx))),
                )
                .child(
                    small_icon_button(
                        "agent-find-next",
                        Ico::ChevronDown,
                        lokalbot_i18n::tr("Next match"),
                    )
                    .on_click(cx.listener(|this, _, _, cx| this.next_match(1, cx))),
                )
                .child(
                    small_icon_button("agent-find-close", Ico::X, lokalbot_i18n::tr("Close find"))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.find_visible = false;
                            this.find_query.clear();
                            this.find_input
                                .update(cx, |state, cx| state.set_value("", window, cx));
                            cx.notify();
                        })),
                )
                .into_any_element(),
        )
        .pt(px(10.))
        .pb(px(8.))
    }

    // ------------------------------------------------------- transcript

    fn render_transcript(
        &mut self,
        snapshot: &Snapshot,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let blocks = presentation::layout(&snapshot.items, snapshot.is_working());
        let matches = self.matches(&blocks);
        let current = matches.get(self.match_index).cloned();
        let first_id = snapshot.items.first().map(|i| i.id().to_string());
        let meeting_title = self.meeting_title(cx);
        let context = StepContext {
            workspace: &snapshot.workspace,
            workspace_name: &snapshot.workspace_name,
            meeting_title: &meeting_title,
        };
        let mut rows: Vec<AnyElement> = Vec::new();
        for block in &blocks {
            let highlighted = current.as_deref() == Some(block.id().as_str());
            let element = match block {
                Block::User(item) => {
                    self.render_user(item, first_id.as_deref() == Some(item.id()), snapshot, cx)
                }
                Block::Said(item) => self.render_said(item, cx),
                Block::Answer { item, steps } => self.render_answer(item, steps, snapshot, cx),
                Block::Notice(item) => render_notice(item, cx),
                Block::Steps(group) => self.render_steps(group, &context, snapshot, cx),
                Block::Live(item) => render_live(item, &context, cx),
            };
            rows.push(
                reading_column(
                    div()
                        .w_full()
                        .rounded(metric::GROUP_RADIUS)
                        .when(highlighted, |this| {
                            this.border_1().border_color(lb.accent_fill.opacity(0.6))
                        })
                        .child(element)
                        .into_any_element(),
                )
                .into_any_element(),
            );
        }
        if let SessionState::Failed(message) = &snapshot.state {
            rows.push(
                reading_column(
                    self.render_recovery(message, snapshot, cx)
                        .into_any_element(),
                )
                .into_any_element(),
            );
        }
        if !snapshot.approvals.is_empty() {
            rows.push(
                reading_column(
                    h_flex()
                        .gap(px(7.))
                        .items_center()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(lb.attention_text)
                        .child(ui::icon(Ico::Hand, px(14.), lb.attention_text))
                        .child(lokalbot_i18n::tr("Waiting for your answer below"))
                        .into_any_element(),
                )
                .into_any_element(),
            );
        } else if snapshot.status == TaskStatus::Stopped {
            rows.push(
                reading_column(
                    h_flex()
                        .gap(px(7.))
                        .items_center()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(ui::icon(Ico::CircleStop, px(14.), lb.text_secondary))
                        .child(lokalbot_i18n::tr("Stopped. Send a message to continue."))
                        .into_any_element(),
                )
                .into_any_element(),
            );
        }
        rows.push(div().h(px(12.)).into_any_element());
        let near_end = {
            let offset = self.transcript_scroll.offset();
            let max = self.transcript_scroll.max_offset();
            max.y + offset.y < px(120.)
        };
        let show_jump = !self.follow_output && !near_end && !snapshot.items.is_empty();
        div()
            .relative()
            .size_full()
            .child(
                div()
                    .id("agent-transcript")
                    .size_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.transcript_scroll)
                    .on_scroll_wheel(cx.listener(|this, _, _, cx| {
                        let offset = this.transcript_scroll.offset();
                        let max = this.transcript_scroll.max_offset();
                        this.follow_output = max.y + offset.y < px(120.);
                        cx.notify();
                    }))
                    .pt(px(24.))
                    .flex()
                    .flex_col()
                    .gap(px(14.))
                    .children(rows),
            )
            .when(show_jump, |this| {
                this.child(
                    h_flex().absolute().bottom(px(12.)).right(px(16.)).child(
                        Button::new("agent-jump-latest")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::ArrowDown))
                            .label(lokalbot_i18n::tr("Jump to latest"))
                            .bg(lb.elevated)
                            .shadow_md()
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.follow_output = true;
                                this.transcript_scroll.scroll_to_bottom();
                                cx.notify();
                            })),
                    ),
                )
            })
            .into_any_element()
    }

    fn render_recovery(
        &mut self,
        message: &str,
        snapshot: &Snapshot,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let data = self.data.clone();
        let task = snapshot.task;
        ui::status_surface(lb.attention, cx)
            .w_full()
            .p(px(14.))
            .child(
                v_flex()
                    .gap(px(10.))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .child(ui::icon(Ico::TriangleAlert, px(15.), lb.attention_text))
                            .child(
                                div()
                                    .text_size(ty::SECTION)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "Task needs attention",
                                    ))),
                            ),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(message.to_string()),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .when(
                                snapshot.recovery == Some(RecoveryAction::OpenModels),
                                |this| {
                                    this.child(
                                        Button::new("agent-open-models")
                                            .outline()
                                            .small()
                                            .label(lokalbot_i18n::tr("Open Models"))
                                            .on_click(move |_, _, cx| {
                                                data.update(cx, |data, cx| {
                                                    data.open_settings(SettingsCategory::Models, cx)
                                                })
                                            }),
                                    )
                                },
                            )
                            .child(
                                Button::new("agent-restart")
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Reconnect"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.with_tasks(cx, |tasks| {
                                            tasks.start(task);
                                        })
                                    })),
                            )
                            .when(snapshot.has_failed_prompt, |this| {
                                this.child(
                                    Button::new("agent-review-retry")
                                        .outline()
                                        .small()
                                        .label(lokalbot_i18n::tr("Review & retry"))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.with_session(cx, |s| s.review_retry());
                                            this.sync_composer(window, cx);
                                            this.focus_composer(window, cx);
                                        })),
                                )
                            }),
                    ),
            )
    }

    /// The user's message on the trailing side; Copy, Edit as follow-up and
    /// Branch from here are in its menu.
    fn render_user(
        &mut self,
        item: &TranscriptItem,
        is_first: bool,
        snapshot: &Snapshot,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let TranscriptItem::User { id, text } = item else {
            return div().into_any_element();
        };
        let lb = cx.lb().clone();
        let size = px(self.text_size);
        let page = cx.entity();
        let (item_id, can_branch, task, copy_text) =
            (id.clone(), snapshot.can_branch, snapshot.task, text.clone());
        let copy_key = format!("user-{id}");
        h_flex()
            .w_full()
            .justify_end()
            .when(!is_first, |this| this.pt(px(18.)))
            .child(
                div()
                    .id(SharedString::from(format!("agent-user-{id}")))
                    .max_w(relative(0.85))
                    .px(px(14.))
                    .py(px(10.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.panel)
                    .border_1()
                    .border_color(lb.group_stroke)
                    .text_size(size)
                    .line_height(size * 1.45)
                    .text_color(lb.text)
                    .child(text.clone())
                    .context_menu(move |menu, _, _| {
                        let copy = page.clone();
                        let edit = page.clone();
                        let branch = page.clone();
                        let (copy_text, copy_key, edit_id, branch_id) = (
                            copy_text.clone(),
                            copy_key.clone(),
                            item_id.clone(),
                            item_id.clone(),
                        );
                        menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Copy")).on_click(
                            move |_, _, cx| {
                                let (key, text) = (copy_key.clone(), copy_text.clone());
                                copy.update(cx, |page, cx| page.copy(key, text, cx))
                            },
                        ))
                        .item(
                            PopupMenuItem::new(lokalbot_i18n::tr("Edit as follow-up")).on_click(
                                move |_, window, cx| {
                                    let edit_id = edit_id.clone();
                                    edit.update(cx, |page, cx| {
                                        page.with_session(cx, |s| s.edit_as_follow_up(&edit_id));
                                        page.sync_composer(window, cx);
                                        page.focus_composer(window, cx);
                                    })
                                },
                            ),
                        )
                        .item(
                            PopupMenuItem::new(lokalbot_i18n::tr("Branch from here"))
                                .disabled(!can_branch)
                                .on_click(move |_, _, cx| {
                                    let branch_id = branch_id.clone();
                                    branch.update(cx, |page, cx| {
                                        page.with_tasks(cx, |tasks| tasks.fork(task, &branch_id))
                                    })
                                }),
                        )
                    }),
            )
            .into_any_element()
    }

    /// The agent's words, in full: plain while they stream, formatted after.
    fn render_text(
        &mut self,
        id: &str,
        text: &str,
        streaming: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let size = px(self.text_size);
        if streaming {
            return div()
                .w_full()
                .text_size(size)
                .line_height(size * 1.5)
                .text_color(lb.text)
                .child(text.to_string())
                .into_any_element();
        }
        let answer = self.parsed_answer(id, text);
        let style = AnswerStyle {
            size,
            line_height: size * 1.5,
            color: lb.text,
        };
        let citations = answer.citations.clone();
        let cite_page = cx.entity();
        let on_cite: answer_text::CiteHandler = Rc::new(move |index, _, cx| {
            if let Some(source) = citations.get(index).cloned() {
                cite_page.update(cx, |page, cx| page.open_cited_source(&source, cx));
            }
        });
        let link_page = cx.entity();
        let on_link: answer_text::LinkHandler = Rc::new(move |url, _, cx| {
            link_page.update(cx, |page, cx| page.open_answer_link(url, cx));
        });
        answer_text::render_linked(
            SharedString::from(format!("agent-answer-{id}")),
            &answer,
            style,
            on_cite,
            Some(on_link),
            cx,
        )
        .w_full()
        .into_any_element()
    }

    /// What the agent says while it works, in full and without actions.
    fn render_said(&mut self, item: &TranscriptItem, cx: &mut Context<Self>) -> AnyElement {
        match item {
            TranscriptItem::Assistant {
                id,
                text,
                is_streaming,
            } => self.render_text(id, text, *is_streaming, cx),
            _ => div().into_any_element(),
        }
    }

    /// The answer a finished turn ends with: the focal point, then the files
    /// that turn changed and quiet copy and retry controls.
    fn render_answer(
        &mut self,
        item: &TranscriptItem,
        steps: &[TranscriptItem],
        snapshot: &Snapshot,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let TranscriptItem::Assistant { id, text, .. } = item else {
            return div().into_any_element();
        };
        let body = self.render_text(id, text, false, cx);
        let files = snapshot.changed_files(steps);
        let copy_key = format!("assistant-{id}");
        let copied = self.copied.as_deref() == Some(copy_key.as_str());
        let page = cx.entity();
        let (retry_id, more_id) = (id.clone(), id.clone());
        let (text_for_copy, text_for_results) = (text.clone(), text.clone());
        let (can_branch, task) = (snapshot.can_branch, snapshot.task);
        let actions = h_flex()
            .gap(px(4.))
            .child(
                Button::new(SharedString::from(format!("agent-copy-{id}")))
                    .ghost()
                    .small()
                    .icon(Icon::new(if copied { Ico::Check } else { Ico::Copy }))
                    .label(if copied {
                        lokalbot_i18n::tr("Copied")
                    } else {
                        lokalbot_i18n::tr("Copy")
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.copy(copy_key.clone(), text_for_copy.clone(), cx)
                    })),
            )
            .child(
                Button::new(SharedString::from(format!("agent-retry-{id}")))
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::RotateCcw))
                    .label(lokalbot_i18n::tr("Retry"))
                    .tooltip(lokalbot_i18n::tr("Retry response"))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        let retry_id = retry_id.clone();
                        this.with_session(cx, |s| s.review_response_retry(&retry_id));
                        this.sync_composer(window, cx);
                        this.focus_composer(window, cx);
                    })),
            )
            .child(
                Button::new(SharedString::from(format!("agent-answer-more-{id}")))
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::Ellipsis))
                    .tooltip(lokalbot_i18n::tr("More response actions"))
                    .dropdown_menu(move |menu, _, _| {
                        let open = page.clone();
                        let branch = page.clone();
                        let text = text_for_results.clone();
                        let more_id = more_id.clone();
                        let branch_id = more_id.clone();
                        menu.item(
                            PopupMenuItem::new(lokalbot_i18n::tr("Open in results")).on_click(
                                move |_, _, cx| {
                                    let preview = ResultPreview {
                                        id: more_id.clone(),
                                        title: lokalbot_i18n::tr("Agent response").into(),
                                        detail: lokalbot_i18n::tr("Conversation result").into(),
                                        text: text.clone(),
                                        original: None,
                                        proposed: None,
                                        file_path: None,
                                    };
                                    open.update(cx, |page, cx| page.show_preview(preview, cx))
                                },
                            ),
                        )
                        .item(
                            PopupMenuItem::new(lokalbot_i18n::tr("Branch from here"))
                                .disabled(!can_branch)
                                .on_click(move |_, _, cx| {
                                    let branch_id = branch_id.clone();
                                    branch.update(cx, |page, cx| {
                                        page.with_tasks(cx, |tasks| tasks.fork(task, &branch_id))
                                    })
                                }),
                        )
                    }),
            );
        v_flex()
            .w_full()
            .gap(px(14.))
            .child(body)
            .when(!files.is_empty(), |this| {
                this.child(self.render_changed_files(&files, steps, cx))
            })
            .child(actions)
            .into_any_element()
    }

    /// The files one turn wrote or edited, under its answer.
    fn render_changed_files(
        &mut self,
        files: &[ChangedFile],
        steps: &[TranscriptItem],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let mut card = v_flex()
            .w_full()
            .gap(px(10.))
            .p(px(12.))
            .rounded(metric::GROUP_RADIUS)
            .bg(lb.panel)
            .border_1()
            .border_color(lb.group_stroke)
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::tr("Changed files")),
            );
        for (index, file) in files.iter().enumerate() {
            let exists = file.target.path.exists();
            let preview = steps
                .iter()
                .find(|s| s.id() == file.step_id)
                .and_then(ResultPreview::tool);
            let (open_path, reveal_path) = (file.target.path.clone(), file.target.path.clone());
            let detail_tint: Hsla = if file.target.place == Place::Outside {
                lb.attention_text
            } else {
                lb.text_secondary
            };
            card = card.child(
                h_flex()
                    .w_full()
                    .gap(px(10.))
                    .items_center()
                    .flex_wrap()
                    .child(
                        h_flex()
                            .id(("agent-changed-file", index as u64))
                            .flex_1()
                            .min_w(px(160.))
                            .gap(px(10.))
                            .items_center()
                            .cursor_pointer()
                            .child(ui::icon(Ico::FileText, px(22.), lb.accent_text))
                            .child(
                                v_flex()
                                    .flex_1()
                                    .min_w_0()
                                    .gap(px(2.))
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(ty::BODY)
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .text_color(lb.text)
                                            .child(file.target.name.clone()),
                                    )
                                    .child(
                                        div()
                                            .line_clamp(2)
                                            .text_size(ty::SECONDARY)
                                            .text_color(detail_tint)
                                            .child(words::changed_file_detail(file)),
                                    ),
                            )
                            .when_some(preview, |this, preview| {
                                this.on_click(cx.listener(move |this, _, _, cx| {
                                    this.show_preview(preview.clone(), cx)
                                }))
                            }),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .child(
                                Button::new(("agent-changed-open", index as u64))
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Open"))
                                    .disabled(!exists)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if let Err(err) =
                                            lokalbot_platform::opener::open_path(&open_path)
                                        {
                                            let message = format!("{err:#}");
                                            this.with_session(cx, |s| {
                                                s.composer_error = Some(message)
                                            });
                                        }
                                    })),
                            )
                            .child(
                                Button::new(("agent-changed-reveal", index as u64))
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Show in folder"))
                                    .disabled(!exists)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if let Err(err) =
                                            lokalbot_platform::opener::reveal_in_file_manager(
                                                &reveal_path,
                                            )
                                        {
                                            let message = format!("{err:#}");
                                            this.with_session(cx, |s| {
                                                s.composer_error = Some(message)
                                            });
                                        }
                                    })),
                            ),
                    ),
            );
        }
        card.into_any_element()
    }

    /// A run of steps as one quiet line that opens to a row per step. A
    /// finished turn's line counts its steps and holds what the agent said
    /// between them.
    fn render_steps(
        &mut self,
        group: &StepGroup,
        context: &StepContext,
        snapshot: &Snapshot,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let working = snapshot.is_working();
        let expanded = self.expanded_steps.contains(&group.id);
        let labels: Vec<(StepLabel, ToolStatus)> = group
            .steps()
            .filter_map(|step| match step {
                TranscriptItem::Tool {
                    name,
                    args_json,
                    status,
                    ..
                } => Some((words::step_label(name, args_json, context), *status)),
                _ => None,
            })
            .collect();
        let texts: Vec<(String, bool)> = labels
            .iter()
            .map(|(label, status)| (label.text(*status, working), label.begins_with_name))
            .collect();
        let summary = words::steps_summary(&texts, words::lowercases_list_items());
        let count =
            (group.is_turn_summary && labels.len() > 1).then(|| words::steps_count(labels.len()));
        let failed = group.has_failure();
        let group_id = group.id.clone();
        let header = h_flex()
            .id(SharedString::from(format!("agent-steps-{}", group.id)))
            .w_full()
            .gap(px(7.))
            .items_center()
            .cursor_pointer()
            .text_size(ty::SECONDARY)
            .text_color(lb.text_secondary)
            // Points along the reading direction while folded, down once open.
            .child(ui::icon(
                if expanded {
                    Ico::ChevronDown
                } else if lokalbot_i18n::current().rtl {
                    Ico::ChevronLeft
                } else {
                    Ico::ChevronRight
                },
                px(11.),
                lb.text_secondary,
            ))
            .child(ui::icon(
                if failed {
                    Ico::CircleAlert
                } else {
                    Ico::CircleCheck
                },
                px(14.),
                if failed {
                    lb.attention_text
                } else {
                    lb.text_secondary
                },
            ))
            .when_some(count, |this, count| {
                this.child(
                    div()
                        .flex_none()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(count),
                )
            })
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .when(expanded, |this| this.line_clamp(3))
                    .when(!expanded, |this| this.truncate())
                    .child(summary),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                if !this.expanded_steps.remove(&group_id) {
                    this.expanded_steps.insert(group_id.clone());
                }
                cx.notify();
            }));
        let mut column = v_flex().w_full().gap(px(8.)).child(header);
        if expanded {
            let mut rows = v_flex()
                .gap(px(8.))
                .ml(px(4.))
                .pl(px(12.))
                .border_l_1()
                .border_color(lb.group_stroke);
            for entry in &group.entries {
                rows = rows.child(self.render_step_row(entry, context, working, cx));
            }
            column = column.child(rows);
        }
        column.into_any_element()
    }

    fn render_step_row(
        &mut self,
        entry: &TranscriptItem,
        context: &StepContext,
        working: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        match entry {
            TranscriptItem::Tool {
                id,
                name,
                args_json,
                status,
                ..
            } => {
                let label = words::step_label(name, args_json, context);
                let icon: AnyElement = match status {
                    ToolStatus::Succeeded => {
                        ui::icon(Ico::Check, px(13.), lb.text_secondary).into_any_element()
                    }
                    ToolStatus::Failed => {
                        ui::icon(Ico::CircleAlert, px(13.), lb.attention_text).into_any_element()
                    }
                    ToolStatus::Running if working => Spinner::new()
                        .xsmall()
                        .color(lb.text_secondary)
                        .into_any_element(),
                    ToolStatus::Running => {
                        ui::icon(Ico::Minus, px(13.), lb.text_secondary).into_any_element()
                    }
                };
                let preview = ResultPreview::tool(entry);
                h_flex()
                    .w_full()
                    .gap(px(8.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .child(div().flex_none().w(px(14.)).child(icon))
                    .child(
                        div()
                            .flex_none()
                            .max_w(relative(0.6))
                            .text_color(lb.text)
                            .child(label.text(*status, working)),
                    )
                    .when_some(label.detail.clone(), |this, detail| {
                        this.child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_color(lb.text_secondary)
                                .child(detail),
                        )
                    })
                    .when(label.detail.is_none(), |this| this.child(div().flex_1()))
                    .when_some(preview, |this, preview| {
                        this.child(div().flex_none().child(ui::link(
                            SharedString::from(format!("agent-step-open-{id}")),
                            lokalbot_i18n::tr("Open"),
                            {
                                let page = cx.entity();
                                move |_, cx| {
                                    let preview = preview.clone();
                                    page.update(cx, |page, cx| page.show_preview(preview, cx))
                                }
                            },
                            cx,
                        )))
                    })
                    .into_any_element()
            }
            // What the agent said between steps, kept in order and quieter than the answer.
            TranscriptItem::Assistant { text, .. } => div()
                .w_full()
                .text_size(px((self.text_size - 2.).max(12.)))
                .line_height(px((self.text_size - 2.).max(12.) * 1.4))
                .text_color(lb.text_secondary)
                .child(text.clone())
                .into_any_element(),
            _ => div().into_any_element(),
        }
    }

    fn parsed_answer(&mut self, id: &str, text: &str) -> Rc<Answer> {
        let mut hasher = DefaultHasher::new();
        text.hash(&mut hasher);
        let hash = hasher.finish();
        if let Some((cached, answer)) = self.answers.get(id)
            && *cached == hash
        {
            return answer.clone();
        }
        let answer = Rc::new(answer_text::parse(&cite_sources(text)));
        self.answers.insert(id.to_string(), (hash, answer.clone()));
        answer
    }

    /// A numbered reference opens its attached source beside the task, as
    /// source links in macOS answers do; references to anything else do
    /// nothing.
    fn open_cited_source(&mut self, source: &CitationSource, cx: &mut Context<Self>) {
        let attachment = self
            .model(cx)
            .and_then(|m| m.tasks.as_ref()?.selected())
            .and_then(|tab| {
                tab.session
                    .source_attachments
                    .iter()
                    .find(|a| match source {
                        CitationSource::Meeting { id, .. } => {
                            a.kind == AttachmentKind::Meeting
                                && a.reference.to_lowercase().starts_with(&id.to_lowercase())
                        }
                        CitationSource::Screen { snapshot_id } => {
                            a.kind == AttachmentKind::Moment
                                && a.reference == snapshot_id.to_string()
                        }
                        CitationSource::File { .. } | CitationSource::Note { .. } => false,
                    })
                    .cloned()
            });
        if let Some(attachment) = attachment {
            self.preview_source(&attachment, cx);
        }
    }

    /// A link in an answer opens the source or tool result it names beside the
    /// task (`AgentSessionView`'s `openURL`); any other link does nothing.
    fn open_answer_link(&mut self, url: &str, cx: &mut Context<Self>) {
        let Some(tab) = self.model(cx).and_then(|m| m.tasks.as_ref()?.selected()) else {
            return;
        };
        let source = tab
            .session
            .source_attachments
            .iter()
            .find(|attachment| attachment.id == url)
            .cloned();
        let results: Vec<ResultPreview> = tab
            .session
            .items()
            .iter()
            .filter_map(ResultPreview::tool)
            .collect();
        let result =
            lokalbot_agent::tasks::result_for_file_link(url, &results, &tab.session.workspace);
        if let Some(source) = source {
            self.preview_source(&source, cx);
        } else if let Some(result) = result {
            self.show_preview(result, cx);
        }
    }

    /// Task errors (`sessions.error`, an alert on macOS) appear as a toast once.
    pub(super) fn show_task_error(&mut self, cx: &mut Context<Self>) {
        let Some(error) = self
            .model(cx)
            .and_then(|m| m.tasks.as_ref())
            .and_then(|t| t.error.clone())
        else {
            return;
        };
        if let Some(model) = &self.model {
            model.update(cx, |model, _| {
                if let Some(tasks) = model.tasks.as_mut() {
                    tasks.error = None;
                }
            });
        }
        self.data.update(cx, |data, cx| data.show_error(error, cx));
    }
}

/// A denial, an error or a note from the task.
fn render_notice(item: &TranscriptItem, cx: &App) -> AnyElement {
    let TranscriptItem::Notice { text, is_error, .. } = item else {
        return div().into_any_element();
    };
    let lb = cx.lb();
    let tint: Hsla = if *is_error {
        lb.attention_text
    } else {
        lb.text_secondary
    };
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_start()
        .child(div().pt(px(2.)).child(ui::icon(
            if *is_error {
                Ico::TriangleAlert
            } else {
                Ico::Info
            },
            px(14.),
            tint,
        )))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::SECONDARY)
                .text_color(tint)
                .child(text.clone()),
        )
        .into_any_element()
}

/// The step the agent is on right now: "Reading open actions…".
fn render_live(item: &TranscriptItem, context: &StepContext, cx: &App) -> AnyElement {
    let TranscriptItem::Tool {
        name, args_json, ..
    } = item
    else {
        return div().into_any_element();
    };
    let lb = cx.lb();
    let label = words::step_label(name, args_json, context);
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_center()
        .text_size(ty::SECONDARY)
        .child(Spinner::new().xsmall().color(lb.text_secondary))
        .child(
            div()
                .flex_none()
                .text_color(lb.text_secondary)
                .child(format!("{}…", label.doing)),
        )
        .when_some(label.detail, |this, detail| {
            this.child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_color(lb.text_tertiary)
                    .child(detail),
            )
        })
        .into_any_element()
}

/// A row centred at the reading width, 20 px from the pane's edges.
fn reading_column(element: AnyElement) -> Div {
    h_flex().w_full().justify_center().px(px(20.)).child(
        div()
            .w_full()
            .max_w(metric::READING_MAX_WIDTH)
            .child(element),
    )
}

pub(super) fn mono_font(cx: &App) -> SharedString {
    use gpui_kit::component::ActiveTheme as _;
    cx.theme().mono_font_family.clone()
}

/// Agent answers cite attached sources by their identifiers, often as
/// Markdown links such as `[meeting:<id>](meeting:<id>)` or
/// `[Title](moment:<n>)`. The shared answer renderer shows `[meeting:<id>]`
/// and `[screen:<n>]` markers as numbered references, so links to a source
/// and bare moment ids become those markers.
fn cite_sources(text: &str) -> Cow<'_, str> {
    if !text.contains("meeting:") && !text.contains("moment:") && !text.contains("screen:") {
        return Cow::Borrowed(text);
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        out.push_str(&rest[..open]);
        let tail = &rest[open..];
        match source_reference(tail) {
            Some((consumed, replacement)) => {
                out.push_str(&replacement);
                rest = &tail[consumed..];
            }
            None => {
                out.push('[');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    Cow::Owned(out)
}

/// At a `[`: a `[label](source)` link or a bare `[moment:<n>]`, as the
/// length to replace and its replacement.
fn source_reference(tail: &str) -> Option<(usize, String)> {
    let close = tail.find(']')?;
    let label = &tail[1..close];
    if label.contains(['[', '\n']) {
        return None;
    }
    if let Some(link) = tail[close + 1..].strip_prefix('(') {
        let end = link.find(')')?;
        let target = link[..end].trim();
        let marker = source_marker(target)?;
        let label = label.trim();
        let replacement = if label.is_empty() || source_marker(label).is_some() {
            marker
        } else {
            lokalbot_i18n::format(
                "{label} {marker}",
                &[("label", label.to_string()), ("marker", marker.to_string())],
            )
        };
        return Some((close + 2 + end + 1, replacement));
    }
    let marker = label
        .strip_prefix("moment:")
        .and_then(|_| source_marker(label))?;
    Some((close + 1, marker))
}

/// `meeting:<id>[@m:ss]` → `[meeting:<id>[@m:ss]]`; `moment:<n>` or
/// `screen:<n>` → `[screen:<n>]`.
fn source_marker(target: &str) -> Option<String> {
    if let Some(id) = target.strip_prefix("meeting:") {
        let valid = id.len() >= 3
            && id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '@' | ':'));
        return valid.then(|| format!("[meeting:{id}]"));
    }
    let id = target
        .strip_prefix("moment:")
        .or_else(|| target.strip_prefix("screen:"))?;
    let valid = !id.is_empty() && id.chars().all(|c| c.is_ascii_digit());
    valid.then(|| format!("[screen:{id}]"))
}

#[cfg(test)]
mod tests {
    use super::cite_sources;

    #[test]
    fn source_links_become_reference_markers() {
        let id = "55555555-5555-4555-8555-555555555555";
        assert_eq!(
            cite_sources(&format!(
                "The meeting ([meeting:{id}](meeting:{id})) was short."
            )),
            format!("The meeting ([meeting:{id}]) was short.")
        );
        assert_eq!(
            cite_sources(&format!("See [Holiday shoot](meeting:{id}@1:05).")),
            format!("See Holiday shoot [meeting:{id}@1:05].")
        );
        assert_eq!(
            cite_sources("Saved in [moment:42] and [the window](moment:43)."),
            "Saved in [screen:42] and the window [screen:43]."
        );
    }

    #[test]
    fn other_links_and_brackets_stay() {
        for text in [
            "Plain [link](https://example.com) and [x] and [moment:abc].",
            "No sources here.",
            "Unclosed [meeting:12345678",
            "[label](meeting:has space)",
        ] {
            assert_eq!(cite_sources(text), text);
        }
    }
}
