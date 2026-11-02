//! How a day's coding-agent work reads on Timeline (`TimelineAgentTaskRow`,
//! `TimelineOutcomeText`, `DayActivityOverview.projectRows`). Recorded actions
//! come from the commands the agent ran; its own report is left out because it
//! is only a claim.

use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement as _,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lokalbot_core::coding_agents::CodingAgentBurst;
use lokalbot_core::coding_agents::attribution::{AgentTask, DaySplit, Outcomes};

use super::TimelinePage;
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

/// A whole count phrase, so each language can word it.
pub(crate) fn counted(count: usize, one: &str, many: &str) -> String {
    lokalbot_i18n::format(
        if count == 1 { one } else { many },
        &[("count", lokalbot_i18n::number(count))],
    )
}

fn commits(count: usize) -> String {
    counted(count, "{count} commit", "{count} commits")
}

/// "2 PRs opened · 1 merged", or the commits when nothing more was recorded.
pub(crate) fn outcome_text(outcomes: &Outcomes) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    let opened = outcomes.opened_pull_requests.len();
    if opened == 1 {
        parts.push(lokalbot_i18n::tr("1 PR opened").to_string());
    } else if opened > 1 {
        parts.push(lokalbot_i18n::format(
            "{0} PRs opened",
            &[("0", format!("{opened}"))],
        ));
    }
    if outcomes.merged_pull_requests > 0 {
        parts.push(lokalbot_i18n::format(
            "{0} merged",
            &[("0", format!("{}", outcomes.merged_pull_requests))],
        ));
    }
    if parts.is_empty() && outcomes.commits > 0 {
        parts.push(commits(outcomes.commits));
    }
    (!parts.is_empty()).then(|| parts.join(" · "))
}

/// What the day's agents recorded, scheduled runs left out like in the sessions.
pub(crate) fn day_outcomes(bursts: &[CodingAgentBurst]) -> Outcomes {
    Outcomes::of(bursts.iter().filter(|burst| !burst.is_scheduled_run()))
}

/// One row of the day's split.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ProjectRow {
    pub label: String,
    pub seconds: f64,
    pub kind: RowKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RowKind {
    Project,
    OtherProjects,
    OtherActivity,
}

const MINIMUM_ROW_SECONDS: f64 = 60.0;

/// The four busiest projects, the rest folded together, then the time no project
/// claims.
pub(crate) fn project_rows(split: &DaySplit) -> Vec<ProjectRow> {
    const CAP: usize = 4;
    let mut rows: Vec<ProjectRow> = Vec::new();
    let mut other = 0.0;
    for share in &split.projects {
        if rows.len() < CAP && share.seconds >= MINIMUM_ROW_SECONDS {
            rows.push(ProjectRow {
                label: share.project.clone(),
                seconds: share.seconds,
                kind: RowKind::Project,
            });
        } else {
            other += share.seconds;
        }
    }
    if other >= MINIMUM_ROW_SECONDS {
        rows.push(ProjectRow {
            label: lokalbot_i18n::tr("Other projects").to_string(),
            seconds: other,
            kind: RowKind::OtherProjects,
        });
    }
    if split.unattributed_seconds >= MINIMUM_ROW_SECONDS {
        rows.push(ProjectRow {
            label: lokalbot_i18n::tr("Other activity").to_string(),
            seconds: split.unattributed_seconds,
            kind: RowKind::OtherActivity,
        });
    }
    rows
}

pub(crate) fn row_color(row: &ProjectRow, cx: &App) -> Hsla {
    let lb = cx.lb();
    match row.kind {
        RowKind::Project => lb.app_color(&row.label),
        RowKind::OtherProjects => lb.text_tertiary.opacity(0.55),
        RowKind::OtherActivity => lb.text_tertiary.opacity(0.8),
    }
}

/// The pull requests a session linked, at most three, as "repository #number".
fn links(task: &AgentTask) -> Vec<(String, String)> {
    let mut result: Vec<(String, String)> = Vec::new();
    for url in task.bursts.iter().flat_map(|burst| &burst.pull_requests) {
        if result.len() >= 3 || !url.starts_with("https://") {
            continue;
        }
        let Some(reference) = lokalbot_core::coding_agents::PullRequestReference::parse(url) else {
            continue;
        };
        if result.iter().any(|(_, seen)| seen == url) {
            continue;
        }
        result.push((
            format!("{} #{}", reference.repository, reference.number),
            url.clone(),
        ));
    }
    result
}

/// "bizstats · Claude Code · 09:06–09:32".
fn metadata(task: &AgentTask) -> String {
    let mut parts: Vec<String> = Vec::new();
    parts.extend(task.project());
    if let Some(agent) = task.agent() {
        parts.push(agent.display_name().to_string());
    }
    if let (Some(start), Some(end)) = (task.start(), task.end()) {
        parts.push(format!(
            "{}–{}",
            lokalbot_core::time::clock_time(start),
            lokalbot_core::time::clock_time(end)
        ));
    }
    parts.join(" · ")
}

impl TimelinePage {
    /// The session's agent work, or `None` when no agent worked during it.
    pub(super) fn render_agent_work(
        &self,
        bursts: &[CodingAgentBurst],
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if bursts.is_empty() {
            return None;
        }
        let lb = cx.lb().clone();
        let tasks = AgentTask::from_bursts(bursts);
        Some(
            v_flex()
                .gap(px(12.))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(ui::text::paragraph(lokalbot_i18n::tr(
                            "What you asked Claude Code and Codex during this session, and what they recorded doing.",
                        ))),
                )
                .children(
                    tasks
                        .iter()
                        .enumerate()
                        .map(|(index, task)| self.render_agent_task(index, task, cx)),
                )
                .into_any_element(),
        )
    }

    fn render_agent_task(
        &self,
        index: usize,
        task: &AgentTask,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let outcomes = Outcomes::of(&task.bursts);
        let line = |icon: Ico, text: SharedString, tint: Hsla| {
            h_flex()
                .gap(px(6.))
                .items_start()
                .text_size(ty::SECONDARY)
                .text_color(lb.text)
                .child(ui::icon(icon, px(13.), tint))
                .child(div().flex_1().min_w_0().child(ui::text::paragraph(text)))
        };
        let merged: Vec<SharedString> = task
            .merged_numbers()
            .into_iter()
            .map(|number| match number {
                Some(number) => {
                    lokalbot_i18n::format("Merged #{0}", &[("0", format!("{number}"))]).into()
                }
                None => lokalbot_i18n::tr("Merged a pull request").into(),
            })
            .collect();
        let task_links = links(task);
        v_flex()
            .gap(px(5.))
            .child(
                div()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(ui::text::paragraph(task.title())),
            )
            .child(
                div()
                    .truncate()
                    .text_size(ty::CAPTION)
                    .text_color(lb.text_secondary)
                    .child(metadata(task)),
            )
            .when_some(task.request().map(str::to_string), |this, request| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .line_clamp(2)
                        .child(request),
                )
            })
            .children(
                outcomes
                    .opened_pull_requests
                    .iter()
                    .map(|title| line(Ico::ArrowUpRight, title.clone().into(), lb.accent_text)),
            )
            .children(
                merged
                    .into_iter()
                    .map(|text| line(Ico::Check, text, lb.accent_text)),
            )
            .when(outcomes.commits > 0, |this| {
                this.child(line(
                    Ico::CircleCheck,
                    commits(outcomes.commits).into(),
                    lb.text_secondary,
                ))
            })
            .when(!task_links.is_empty(), |this| {
                this.child(
                    h_flex()
                        .gap(px(10.))
                        .children(task_links.into_iter().enumerate().map(
                            |(link_index, (label, url))| {
                                div()
                                    .id(SharedString::from(format!(
                                        "agent-link-{index}-{link_index}"
                                    )))
                                    .cursor_pointer()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.accent_text)
                                    .child(label)
                                    .on_click(move |_, _, cx| cx.open_url(&url))
                            },
                        )),
                )
            })
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::coding_agents::attribution::Share;

    #[test]
    fn outcome_lines_read_like_the_mac() {
        let mut outcomes = Outcomes::default();
        assert_eq!(outcome_text(&outcomes), None);
        outcomes.commits = 2;
        assert_eq!(outcome_text(&outcomes).as_deref(), Some("2 commits"));
        outcomes.opened_pull_requests = vec!["a".into()];
        outcomes.merged_pull_requests = 1;
        assert_eq!(
            outcome_text(&outcomes).as_deref(),
            Some("1 PR opened · 1 merged")
        );
    }

    #[test]
    fn the_split_keeps_four_projects_and_folds_the_rest() {
        let share = |project: &str, seconds| Share {
            project: project.into(),
            seconds,
        };
        let split = DaySplit {
            projects: vec![
                share("a", 500.0),
                share("b", 400.0),
                share("c", 300.0),
                share("d", 200.0),
                share("e", 100.0),
                share("f", 30.0),
            ],
            unattributed_seconds: 120.0,
        };
        let rows = project_rows(&split);
        assert_eq!(rows.len(), 6);
        assert_eq!(rows[3].label, "d");
        assert_eq!(rows[4].kind, RowKind::OtherProjects);
        assert_eq!(rows[4].seconds, 130.0);
        assert_eq!(rows[5].kind, RowKind::OtherActivity);
        // Under a minute isn't worth a row.
        let small = DaySplit {
            projects: vec![share("a", 30.0)],
            unattributed_seconds: 20.0,
        };
        assert!(project_rows(&small).is_empty());
    }
}
