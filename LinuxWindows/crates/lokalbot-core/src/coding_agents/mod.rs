//! Coding-agent evidence (`CodingAgentSession.swift`): Claude Code and Codex
//! work saved as bursts in `coding_agent_bursts`, with sorted-key JSON payloads
//! whose dates are Swift-reference seconds. The transcript readers live in
//! `lokalbot-engine`; this is the data every other feature reads.

pub mod attribution;
pub mod text;

use std::collections::HashMap;
use std::sync::LazyLock;

use anyhow::{Result, bail};
use chrono::{DateTime, Local, NaiveDate, Utc};
use regex::Regex;
use rusqlite::params;
use serde::{Deserialize, Serialize};

use crate::library::Library;
use crate::time::{swift_date, to_epoch};
use crate::timeline::table_exists;

/// Matches the digest's segment split: later events start a new burst.
pub const INACTIVITY_GAP_SECONDS: f64 = 10.0 * 60.0;
/// Longer gaps between events count as waiting, not active work.
pub const ACTIVE_GAP_CAP_SECONDS: f64 = 5.0 * 60.0;
pub const STORED_PROMPTS: usize = 6;
pub const STORED_FILES: usize = 16;
/// The title of a session with neither a title nor a request.
pub const UNTITLED: &str = "Untitled session";
pub const UNKNOWN_PROJECT: &str = "Unknown project";

/// `CodingAgentKind`, by its stored raw value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum CodingAgentKind {
    #[serde(rename = "claude-code")]
    ClaudeCode,
    #[serde(rename = "codex")]
    Codex,
}

impl CodingAgentKind {
    pub const ALL: [Self; 2] = [Self::ClaudeCode, Self::Codex];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude-code",
            Self::Codex => "codex",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::ClaudeCode => "Claude Code",
            Self::Codex => "Codex",
        }
    }
}

/// An outcome parsed from a command the agent ran. These are recorded actions,
/// unlike the agent's own report, which is only a claim. Encoded as Swift
/// encodes enums with associated values: `{"commit":{"message":"…"}}`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CodingAgentAction {
    Commit {
        message: String,
    },
    OpenedPullRequest {
        title: String,
    },
    /// `number` is absent when the command merged the current branch's PR.
    MergedPullRequest {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        number: Option<i64>,
    },
    Release {
        tag: String,
    },
    Pushed {},
    RanTests {},
}

impl CodingAgentAction {
    pub fn summary(&self) -> String {
        match self {
            Self::Commit { message } => format!("commit: {message}"),
            Self::OpenedPullRequest { title } => format!("opened PR: {title}"),
            Self::MergedPullRequest { number: Some(n) } => format!("merged PR #{n}"),
            Self::MergedPullRequest { number: None } => "merged PR".into(),
            Self::Release { tag } => format!("release: {tag}"),
            Self::Pushed {} => "pushed".into(),
            Self::RanTests {} => "ran tests".into(),
        }
    }
}

/// A GitHub-style pull request a session linked.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct PullRequestReference {
    pub owner: String,
    pub repository: String,
    pub number: i64,
}

impl PullRequestReference {
    pub fn parse(url: &str) -> Option<Self> {
        let parts: Vec<&str> = url.split('/').filter(|p| !p.is_empty()).collect();
        if parts.len() < 6 || parts[parts.len() - 2] != "pull" {
            return None;
        }
        Some(Self {
            owner: parts[parts.len() - 4].to_string(),
            repository: parts[parts.len() - 3].to_string(),
            number: parts[parts.len() - 1].parse().ok()?,
        })
    }
}

/// `owner/repo#N` for a GitHub pull request URL (`DayDigestEvidence.pullRequestLabel`).
pub fn pull_request_label(url: &str) -> Option<String> {
    let parts: Vec<&str> = url.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() < 6 || parts[parts.len() - 2] != "pull" {
        return None;
    }
    Some(format!(
        "{}/{}#{}",
        parts[parts.len() - 4],
        parts[parts.len() - 3],
        parts[parts.len() - 1]
    ))
}

/// A contiguous run of agent work inside one session. The fields are in
/// sorted-key order, so the payload reads as the Mac's `.sortedKeys` encoder
/// writes it. Absent optionals are left out, as Swift leaves them out.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodingAgentBurst {
    #[serde(default)]
    pub actions: Vec<CodingAgentAction>,
    #[serde(default)]
    pub active_duration: f64,
    pub agent: CodingAgentKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default)]
    pub changed_file_count: usize,
    #[serde(default)]
    pub changed_files: Vec<String>,
    #[serde(with = "swift_date")]
    pub end: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub final_reply: Option<String>,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub prompt_count: usize,
    #[serde(default)]
    pub prompts: Vec<String>,
    #[serde(default)]
    pub pull_requests: Vec<String>,
    #[serde(rename = "sessionID", default)]
    pub session_id: String,
    #[serde(with = "swift_date")]
    pub start: DateTime<Utc>,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub tool_call_count: usize,
}

/// `String(Double)`, as the Mac's evidence signatures format numbers.
fn number(value: f64) -> String {
    format!("{value:?}")
}

fn time(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local).format("%H:%M").to_string()
}

impl CodingAgentBurst {
    /// Stable within a day: bursts are keyed by session and first event.
    pub fn id(&self) -> String {
        format!(
            "{}:{}:{}",
            self.agent.raw_value(),
            self.session_id,
            self.start.timestamp()
        )
    }

    /// `agent:session`, for grouping a session's bursts.
    pub fn session_key(&self) -> String {
        format!("{}:{}", self.agent.raw_value(), self.session_id)
    }

    /// A burst idle for the full inactivity gap can never grow again. Only
    /// settled bursts become evidence, so a saved digest's inputs cannot
    /// change underneath it.
    pub fn is_settled(&self, now: DateTime<Utc>) -> bool {
        (now - self.end).num_milliseconds() as f64 / 1000.0 >= INACTIVITY_GAP_SECONDS
    }

    /// Every request came from a schedule, not from the person at the time.
    /// Such runs often report on earlier days.
    pub fn is_scheduled_run(&self) -> bool {
        !self.prompts.is_empty()
            && self
                .prompts
                .iter()
                .all(|p| p.starts_with("Scheduled automation:") || p.starts_with("Scheduled task:"))
    }

    /// Committed, opened or merged a pull request, released, pushed, ran
    /// tests, or linked a pull request.
    pub fn recorded_outcome(&self) -> bool {
        !self.actions.is_empty() || !self.pull_requests.is_empty()
    }

    /// The same requests, reply, actions, pull requests and tool calls in the
    /// same session. A settled burst's work never changes, but how it is
    /// presented can: a session is renamed, and bursts saved by earlier readers
    /// carry the session's folder and branch, file names relative to another
    /// folder, and edges moved by activity on the other side of midnight.
    pub fn has_same_work(&self, other: &Self) -> bool {
        self.agent == other.agent
            && self.session_id == other.session_id
            && self.prompts == other.prompts
            && self.prompt_count == other.prompt_count
            && self.final_reply == other.final_reply
            && self.actions == other.actions
            && self.pull_requests == other.pull_requests
            && self.tool_call_count == other.tool_call_count
    }

    /// Equal in every stored field. Times and durations are compared to within
    /// a millisecond: a scan's times come from the transcript, a stored burst's
    /// from Swift-reference seconds, and the two differ by rounding only.
    pub fn is_same_as_stored(&self, other: &Self) -> bool {
        let close = |a: DateTime<Utc>, b: DateTime<Utc>| {
            (a - b)
                .num_microseconds()
                .is_some_and(|delta| delta.abs() < 1_000)
        };
        self.has_same_work(other)
            && self.title == other.title
            && self.project == other.project
            && self.branch == other.branch
            && close(self.start, other.start)
            && close(self.end, other.end)
            && (self.active_duration - other.active_duration).abs() < 0.001
            && self.changed_files == other.changed_files
            && self.changed_file_count == other.changed_file_count
    }

    /// Every field the digest can read, in a fixed order, for evidence
    /// signatures that change exactly when the burst's content does.
    pub fn signature_fields(&self) -> Vec<String> {
        vec![
            self.id(),
            self.agent.raw_value().to_string(),
            self.session_id.clone(),
            self.title.clone(),
            self.project.clone(),
            self.branch.clone().unwrap_or_default(),
            number(to_epoch(self.start)),
            number(to_epoch(self.end)),
            number(self.active_duration),
            self.prompts.join("\u{1e}"),
            self.prompt_count.to_string(),
            self.final_reply.clone().unwrap_or_default(),
            self.changed_files.join("\u{1e}"),
            self.changed_file_count.to_string(),
            self.actions
                .iter()
                .map(CodingAgentAction::summary)
                .collect::<Vec<_>>()
                .join("\u{1e}"),
            self.pull_requests.join("\u{1e}"),
            self.tool_call_count.to_string(),
        ]
    }

    /// Model-facing evidence in the same shape as the digest's other work
    /// sources: substantive content first, trace metadata last and labeled.
    pub fn evidence_text(&self, max_prompts: usize) -> String {
        let short_session: String = self.session_id.chars().take(8).collect();
        let mut lines = vec![
            format!(
                "WORK SOURCE: AGENT SESSION [agent:{}:{short_session}]",
                self.agent.raw_value()
            ),
            format!("Agent: {}", self.agent.display_name()),
        ];
        // A request or placeholder title names no work; the requests below
        // already say what was asked.
        if self.title_names_work() {
            lines.push(format!("Session: {}", self.title));
        }
        lines.push(format!(
            "Project: {}{}",
            self.work_project().as_deref().unwrap_or("unknown"),
            self.branch
                .as_ref()
                .map(|b| format!(" (branch {b})"))
                .unwrap_or_default()
        ));
        if self.is_scheduled_run() {
            lines.push(
                "Scheduled run: its report is omitted because it may describe other days; only recorded actions show what happened in this session."
                    .into(),
            );
        }
        if self.prompts.is_empty() {
            lines.push("Requests: continued work from an earlier request".into());
        } else {
            lines.push("Requests:".into());
            lines.extend(
                self.prompts
                    .iter()
                    .take(max_prompts)
                    .map(|p| format!("- {p}")),
            );
            let remaining = self
                .prompt_count
                .saturating_sub(max_prompts.min(self.prompts.len()));
            if remaining > 0 {
                lines.push(format!("- (+{remaining} more)"));
            }
        }
        if !self.changed_files.is_empty() {
            let hidden = self
                .changed_file_count
                .saturating_sub(self.changed_files.len());
            lines.push(format!(
                "Changed files ({}): {}{}",
                self.changed_file_count,
                self.changed_files.join(", "),
                if hidden > 0 {
                    format!(", +{hidden} more")
                } else {
                    String::new()
                }
            ));
        }
        if !self.actions.is_empty() {
            lines.push(format!(
                "Recorded actions: {}",
                self.actions
                    .iter()
                    .map(CodingAgentAction::summary)
                    .collect::<Vec<_>>()
                    .join("; ")
            ));
        }
        if !self.pull_requests.is_empty() {
            lines.push(format!("Pull requests: {}", self.pull_requests.join(", ")));
        }
        if let Some(reply) = self
            .final_reply
            .as_ref()
            .filter(|_| !self.is_scheduled_run())
        {
            lines.push(format!(
                "Agent's final report (a claim; corroborate with actions): {reply}"
            ));
        }
        lines.push(format!(
            "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n{}–{}; active={}m; tool_calls={}",
            time(self.start),
            time(self.end),
            (self.active_duration / 60.0).round() as i64,
            self.tool_call_count
        ));
        lines.join("\n")
    }

    /// The title came from the transcript and names the work. A session the
    /// transcript leaves untitled is labeled with its first request or a
    /// placeholder, which name a conversation instead.
    pub fn title_names_work(&self) -> bool {
        if self.title == UNTITLED {
            return false;
        }
        if let Some(first) = self.prompts.first()
            && self.title == request_title(first)
        {
            return false;
        }
        !text::reads_as_request(&self.title)
    }

    /// A short work title for a task list: the session's own title when it
    /// names the work, otherwise the deliverable its recorded actions name (an
    /// opened pull request, then a commit), then its request when that is a
    /// short instruction. "can you add a demo to the PR?" and "Untitled
    /// session" never become a task.
    pub fn work_title(&self) -> String {
        if self.title_names_work() {
            return self.title.clone();
        }
        let mut opened = None;
        let mut commits = Vec::new();
        let mut provisional = Vec::new();
        for action in &self.actions {
            match action {
                CodingAgentAction::OpenedPullRequest { title } => {
                    if opened.is_none() {
                        opened = work_subject(title);
                    }
                }
                CodingAgentAction::Commit { message } => {
                    let Some(subject) = work_subject(message) else {
                        continue;
                    };
                    if PROVISIONAL_COMMIT.is_match(message) {
                        provisional.push(subject);
                    } else {
                        commits.push(subject);
                    }
                }
                _ => {}
            }
        }
        if let Some(opened) = opened {
            return opened;
        }
        if let Some(commit) = commits.into_iter().next() {
            return commit;
        }
        let requests = (self.title != UNTITLED)
            .then_some(self.title.as_str())
            .into_iter()
            .chain(self.prompts.first().map(String::as_str));
        if let Some(instruction) = requests.filter_map(text::instruction).next() {
            return instruction;
        }
        if let Some(commit) = provisional.into_iter().next() {
            return commit;
        }
        if let Some(pull_request) = self.pull_request_references().first() {
            return format!("Work on PR #{}", pull_request.number);
        }
        format!("{} session", self.agent.display_name())
    }

    /// The repository the work belongs to. A session started in a folder that
    /// names no project, such as a scratch folder or the folder holding every
    /// checkout, takes it from its pull requests, as does a sibling checkout
    /// such as `LokalBot-port`. `None` when nothing names one.
    pub fn work_project(&self) -> Option<String> {
        let mut repositories: Vec<String> = Vec::new();
        for pull_request in self.pull_request_references() {
            if !repositories
                .iter()
                .any(|r| r.eq_ignore_ascii_case(&pull_request.repository))
            {
                repositories.push(pull_request.repository);
            }
        }
        let repository = (repositories.len() == 1).then(|| repositories.remove(0));
        if names_no_project(&self.project) {
            return repository;
        }
        if let Some(repository) = repository
            && self.project.chars().count() > repository.chars().count()
            && self
                .project
                .to_lowercase()
                .starts_with(&repository.to_lowercase())
            && self
                .project
                .chars()
                .nth(repository.chars().count())
                .is_some_and(|c| "-_. ".contains(c))
        {
            return Some(repository);
        }
        Some(self.project.clone())
    }

    pub fn pull_request_references(&self) -> Vec<PullRequestReference> {
        self.pull_requests
            .iter()
            .filter_map(|url| PullRequestReference::parse(url))
            .collect()
    }
}

/// The title of a session its transcript leaves untitled: its first request.
pub fn request_title(prompt: &str) -> String {
    crate::text::sanitize(prompt, Some(80))
}

static WORK_SUBJECT_TYPE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-z]+(\([^)]*\))?!?:\s+").expect("valid regex"));
/// Scaffolding that names a step rather than the work: temporary and
/// work-in-progress commits, fixups, merges and reverts.
static PROVISIONAL_COMMIT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\s*((temporary|temp|tmp|wip|merge|revert)\b|(fixup|squash|amend)!)")
        .expect("valid regex")
});

/// A commit or pull request title as a work title, without a
/// conventional-commit type such as `feat(onchain):`.
fn work_subject(message: &str) -> Option<String> {
    let trimmed = message.trim();
    let mut subject = WORK_SUBJECT_TYPE.replace(trimmed, "").into_owned();
    while subject.ends_with('.') {
        subject.pop();
    }
    let mut chars = subject.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().chain(chars).collect())
}

/// One session's bursts as a single view, for a summary that should see the
/// session once rather than once per burst.
pub fn merging(bursts: &[CodingAgentBurst]) -> Option<CodingAgentBurst> {
    let mut ordered: Vec<&CodingAgentBurst> = bursts.iter().collect();
    ordered.sort_by_key(|b| b.start);
    let mut merged = (*ordered.first()?).clone();
    let mut files = merged.changed_files.clone();
    let mut hidden = merged
        .changed_file_count
        .saturating_sub(merged.changed_files.len());
    for burst in ordered.iter().skip(1) {
        merged.end = merged.end.max(burst.end);
        merged.active_duration += burst.active_duration;
        merged.prompts.extend(burst.prompts.iter().cloned());
        merged.prompt_count += burst.prompt_count;
        if burst.final_reply.is_some() {
            merged.final_reply = burst.final_reply.clone();
        }
        if burst.branch.is_some() {
            merged.branch = burst.branch.clone();
        }
        for file in &burst.changed_files {
            if !files.contains(file) {
                files.push(file.clone());
            }
        }
        hidden += burst
            .changed_file_count
            .saturating_sub(burst.changed_files.len());
        for action in &burst.actions {
            if !merged.actions.contains(action) {
                merged.actions.push(action.clone());
            }
        }
        for url in &burst.pull_requests {
            if !merged.pull_requests.contains(url) {
                merged.pull_requests.push(url.clone());
            }
        }
        merged.tool_call_count += burst.tool_call_count;
    }
    merged.changed_file_count = files.len() + hidden;
    files.truncate(STORED_FILES);
    merged.changed_files = files;
    Some(merged)
}

/// Bursts of one session, in order, one group per session.
pub fn sessions(bursts: &[CodingAgentBurst]) -> Vec<Vec<CodingAgentBurst>> {
    let mut order: Vec<String> = Vec::new();
    let mut groups: HashMap<String, Vec<CodingAgentBurst>> = HashMap::new();
    for burst in bursts {
        let key = burst.session_key();
        if !groups.contains_key(&key) {
            order.push(key.clone());
        }
        groups.entry(key).or_default().push(burst.clone());
    }
    order
        .into_iter()
        .filter_map(|key| groups.remove(&key))
        .collect()
}

fn path_components(path: &str) -> Vec<&str> {
    let mut components: Vec<&str> = Vec::new();
    for part in path.split(['/', '\\']) {
        match part {
            "" | "." => {}
            ".." => {
                components.pop();
            }
            part => components.push(part),
        }
    }
    components
}

/// The repository name, not the checkout folder: agent worktrees live under
/// `<repo>/.claude/worktrees/<name>`.
pub fn project_name(working_directory: Option<&str>) -> String {
    let Some(directory) = working_directory.filter(|d| !d.is_empty()) else {
        return UNKNOWN_PROJECT.into();
    };
    let components = path_components(directory);
    if let Some(marker) = components.iter().rposition(|c| *c == ".claude")
        && marker >= 1
        && components.get(marker + 1) == Some(&"worktrees")
    {
        return components[marker - 1].to_string();
    }
    components
        .last()
        .map(|c| c.trim())
        .filter(|c| !c.is_empty())
        .map_or_else(|| UNKNOWN_PROJECT.into(), str::to_string)
}

const CHECKOUT_FOLDERS: &[&str] = &[
    "code",
    "desktop",
    "dev",
    "developer",
    "documents",
    "downloads",
    "git",
    "github",
    "projects",
    "repos",
    "repositories",
    "scratchpad",
    "src",
    "tmp",
    "workspace",
    "workspaces",
];

static SCRATCH_FOLDER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^scratch(-[0-9a-f-]+)?$").expect("valid regex"));

/// A folder that holds work without naming it: no folder at all, a Claude
/// scratch folder such as `scratch-2026-10-19-6f7eb7`, or a folder that holds
/// checkouts, such as `~/Documents/GitHub` or the home folder.
pub fn names_no_project(name: &str) -> bool {
    let lowered = name.to_lowercase();
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_default()
        .to_lowercase();
    name == UNKNOWN_PROJECT
        || CHECKOUT_FOLDERS.contains(&lowered.as_str())
        || (!user.is_empty() && lowered == user)
        || SCRATCH_FOLDER.is_match(&lowered)
}

/// A stored payload; one that doesn't decode reads as nothing.
fn decode(payload: &str) -> Option<CodingAgentBurst> {
    serde_json::from_str(payload).ok()
}

impl Library {
    /// Settled bursts that began in `[start, end)`, oldest first. A burst never
    /// crosses midnight, so its start names its day. An undecodable payload
    /// is skipped, as the Mac skips it.
    pub fn coding_agent_bursts(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<CodingAgentBurst>> {
        self.with_db(|db| {
            if !table_exists(db, "coding_agent_bursts")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT payload FROM coding_agent_bursts WHERE start >= ?1 AND start < ?2 ORDER BY start, id",
            )?;
            let rows = statement.query_map(params![to_epoch(start), to_epoch(end)], |row| {
                row.get::<_, String>(0)
            })?;
            let mut bursts = Vec::new();
            for payload in rows {
                if let Some(burst) = decode(&payload?) {
                    bursts.push(burst);
                }
            }
            Ok(bursts)
        })
    }

    pub fn coding_agent_bursts_on(&self, day: NaiveDate) -> Result<Vec<CodingAgentBurst>> {
        let (start, end) = crate::time::local_day_bounds(day);
        self.coding_agent_bursts(start, end)
    }

    /// Inserts or replaces bursts by id. Callers compute what changed; this
    /// only writes, so a failure never looks like an empty source.
    pub fn upsert_coding_agent_bursts(&self, bursts: &[CodingAgentBurst]) -> Result<()> {
        if bursts.is_empty() {
            return Ok(());
        }
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            for burst in bursts {
                tx.execute(
                    "INSERT OR REPLACE INTO coding_agent_bursts (id, agent, start, end, payload) \
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![
                        burst.id(),
                        burst.agent.raw_value(),
                        to_epoch(burst.start),
                        to_epoch(burst.end),
                        serde_json::to_string(burst)?,
                    ],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    pub fn delete_coding_agent_bursts(&self, ids: &[String]) -> Result<()> {
        if ids.is_empty() {
            return Ok(());
        }
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            for id in ids {
                tx.execute("DELETE FROM coding_agent_bursts WHERE id = ?1", [id])?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// Start times of every stored burst, for the days a full clear withdraws.
    pub fn coding_agent_burst_starts(&self) -> Result<HashMap<String, DateTime<Utc>>> {
        self.with_db(|db| {
            if !table_exists(db, "coding_agent_bursts")? {
                return Ok(HashMap::new());
            }
            let mut statement = db.prepare("SELECT id, start FROM coding_agent_bursts")?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    crate::time::from_epoch(row.get(1)?),
                ))
            })?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    /// Deletes every saved burst, withdrawing the generated journals that used
    /// them (`AppState.deleteCodingAgentEvidence`). The agents' own transcripts
    /// are never touched. The caller stops reading first.
    pub fn delete_coding_agent_evidence(&self) -> Result<usize> {
        let starts = self.coding_agent_burst_starts()?;
        if starts.is_empty() {
            return Ok(0);
        }
        let dates: Vec<DateTime<Utc>> = starts.values().copied().collect();
        let ids: Vec<String> = starts.into_keys().collect();
        crate::evidence::with_screen_mutation(
            self.paths().root(),
            &dates,
            crate::evidence::EvidenceChange::Removal,
            || self.delete_coding_agent_bursts(&ids),
        )?;
        Ok(ids.len())
    }
}

#[cfg(test)]
mod tests;
