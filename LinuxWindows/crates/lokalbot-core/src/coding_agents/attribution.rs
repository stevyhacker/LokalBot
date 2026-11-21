use std::collections::{BTreeMap, HashMap, HashSet};

use chrono::{DateTime, Utc};

use super::{CodingAgentAction, CodingAgentBurst, CodingAgentKind};
use crate::model::ActivityBlock;
use crate::projects::{matches_words, significant_terms, words};

const EDGE_MARGIN_SECONDS: i64 = 2 * 60;

#[derive(Clone, Debug, PartialEq)]
pub struct Share {
    pub project: String,
    pub seconds: f64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DaySplit {
    pub projects: Vec<Share>,
    pub unattributed_seconds: f64,
}

#[derive(Clone, Debug, Default)]
pub struct Attribution {
    pub bursts: Vec<CodingAgentBurst>,
    projects: Vec<(String, Vec<HashSet<String>>)>,
    burst_projects: Vec<Option<String>>,
}

fn seconds(delta: chrono::Duration) -> f64 {
    delta.num_milliseconds() as f64 / 1000.0
}

pub fn ranked(mut shares: Vec<Share>) -> Vec<Share> {
    shares.sort_by(|a, b| {
        b.seconds
            .partial_cmp(&a.seconds)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.project.cmp(&b.project))
    });
    shares
}

fn sorted_terms(terms: &HashSet<String>) -> Vec<String> {
    let mut sorted: Vec<String> = terms.iter().cloned().collect();
    sorted.sort();
    sorted
}

impl Attribution {
    pub fn new(source: &[CodingAgentBurst]) -> Self {
        let mut bursts: Vec<CodingAgentBurst> = source
            .iter()
            .filter(|b| !b.is_scheduled_run() && b.end > b.start)
            .cloned()
            .collect();
        bursts.sort_by_key(|b| b.start);
        let burst_projects: Vec<Option<String>> =
            bursts.iter().map(CodingAgentBurst::work_project).collect();
        let mut active: HashMap<String, f64> = HashMap::new();
        let mut links: BTreeMap<Vec<String>, BTreeMap<String, usize>> = BTreeMap::new();
        for (burst, project) in bursts.iter().zip(&burst_projects) {
            let Some(project) = project else { continue };
            *active.entry(project.clone()).or_default() += burst.active_duration;
            for pull_request in burst.pull_request_references() {
                let terms = sorted_terms(&significant_terms(&pull_request.repository));
                *links
                    .entry(terms)
                    .or_default()
                    .entry(project.clone())
                    .or_default() += 1;
            }
        }
        let mut names: Vec<String> = active.keys().cloned().collect();
        names.sort_by(|a, b| {
            active[b]
                .partial_cmp(&active[a])
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.cmp(b))
        });
        let mut term_sets: HashMap<String, Vec<HashSet<String>>> = names
            .iter()
            .map(|name| (name.clone(), vec![significant_terms(name)]))
            .collect();
        let project_names: HashSet<Vec<String>> = names
            .iter()
            .map(|name| sorted_terms(&significant_terms(name)))
            .collect();
        for (repository, linked) in links {
            if repository.is_empty() || project_names.contains(&repository) {
                continue;
            }
            let mut owner: Option<(&String, usize)> = None;
            for (project, count) in &linked {
                if let Some((current, most)) = owner
                    && (most > *count || (most == *count && current < project))
                {
                    continue;
                }
                owner = Some((project, *count));
            }
            if let Some((project, _)) = owner {
                term_sets
                    .entry(project.clone())
                    .or_default()
                    .push(repository.into_iter().collect());
            }
        }
        let projects = names
            .into_iter()
            .map(|name| {
                let sets = term_sets
                    .remove(&name)
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|set| !set.is_empty())
                    .collect();
                (name, sets)
            })
            .collect();
        Self {
            bursts,
            projects,
            burst_projects,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.projects.is_empty()
    }

    pub fn shares(&self, block: &ActivityBlock) -> Vec<Share> {
        let named = self.named_project(&block.title, &block.app);
        self.shares_with(block, named.as_deref())
    }

    pub fn shares_of(&self, blocks: &[&ActivityBlock]) -> Vec<Vec<Share>> {
        let mut named: HashMap<(&str, &str), Option<String>> = HashMap::new();
        blocks
            .iter()
            .map(|block| {
                let project = named
                    .entry((block.app.as_str(), block.title.as_str()))
                    .or_insert_with(|| self.named_project(&block.title, &block.app));
                self.shares_with(block, project.as_deref())
            })
            .collect()
    }

    pub fn split(&self, blocks: &[ActivityBlock]) -> DaySplit {
        let counted: Vec<&ActivityBlock> = blocks
            .iter()
            .filter(|b| !crate::timeline::is_system_app(&b.app))
            .collect();
        let shares = self.shares_of(&counted);
        let mut totals: HashMap<String, f64> = HashMap::new();
        let mut unattributed = 0.0;
        for (block, shares) in counted.iter().zip(shares) {
            let mut attributed = 0.0;
            for share in shares {
                *totals.entry(share.project).or_default() += share.seconds;
                attributed += share.seconds;
            }
            unattributed += (block.duration_seconds() - attributed).max(0.0);
        }
        DaySplit {
            projects: ranked(
                totals
                    .into_iter()
                    .filter(|(_, seconds)| *seconds > 0.0)
                    .map(|(project, seconds)| Share { project, seconds })
                    .collect(),
            ),
            unattributed_seconds: unattributed,
        }
    }

    fn shares_with(&self, block: &ActivityBlock, named: Option<&str>) -> Vec<Share> {
        let duration = seconds(block.end - block.start);
        if duration <= 0.0 || self.projects.is_empty() {
            return Vec::new();
        }
        if let Some(project) = named {
            return vec![Share {
                project: project.to_string(),
                seconds: duration,
            }];
        }
        self.agent_shares(block, duration)
    }

    fn named_project(&self, title: &str, app: &str) -> Option<String> {
        if self.projects.is_empty() {
            return None;
        }
        let cleaned = crate::timeline::cleaned_title(title, app)?;
        let title_words = words(&cleaned);
        self.projects
            .iter()
            .find(|(_, sets)| matches_words(sets, &title_words))
            .map(|(name, _)| name.clone())
    }

    fn agent_shares(&self, block: &ActivityBlock, duration: f64) -> Vec<Share> {
        let runs_claude = hosts(&block.app, CodingAgentKind::ClaudeCode);
        let runs_codex = hosts(&block.app, CodingAgentKind::Codex);
        if !runs_claude && !runs_codex {
            return Vec::new();
        }
        let margin = chrono::Duration::seconds(EDGE_MARGIN_SECONDS);
        let (window_start, window_end) = (block.start - margin, block.end + margin);
        let mut weights: HashMap<&str, f64> = HashMap::new();
        let mut covered: Vec<(DateTime<Utc>, DateTime<Utc>)> = Vec::new();
        for (burst, project) in self.bursts.iter().zip(&self.burst_projects) {
            if burst.start - margin >= window_end {
                break;
            }
            let runs_agent = match burst.agent {
                CodingAgentKind::ClaudeCode => runs_claude,
                CodingAgentKind::Codex => runs_codex,
            };
            let Some(project) = project.as_deref().filter(|_| runs_agent) else {
                continue;
            };
            let start = (burst.start - margin).max(window_start);
            let end = (burst.end + margin).min(window_end);
            if end <= start {
                continue;
            }
            *weights.entry(project).or_default() += seconds(end - start);
            let (covered_start, covered_end) = (start.max(block.start), end.min(block.end));
            if covered_end > covered_start {
                covered.push((covered_start, covered_end));
            }
        }
        let total: f64 = weights.values().sum();
        let covered_seconds = duration.min(merged_duration(covered));
        if total <= 0.0 || covered_seconds <= 0.0 {
            return Vec::new();
        }
        ranked(
            weights
                .into_iter()
                .map(|(project, weight)| Share {
                    project: project.to_string(),
                    seconds: covered_seconds * weight / total,
                })
                .collect(),
        )
    }
}

fn merged_duration(mut intervals: Vec<(DateTime<Utc>, DateTime<Utc>)>) -> f64 {
    intervals.sort_by_key(|i| i.0);
    let Some(&(mut start, mut end)) = intervals.first() else {
        return 0.0;
    };
    let mut total = 0.0;
    for &(next_start, next_end) in intervals.iter().skip(1) {
        if next_start <= end {
            end = end.max(next_end);
        } else {
            total += seconds(end - start);
            (start, end) = (next_start, next_end);
        }
    }
    total + seconds(end - start)
}

const SHARED_HOSTS: &[&str] = &[
    "terminal",
    "iterm",
    "iterm2",
    "ghostty",
    "warp",
    "wezterm",
    "kitty",
    "alacritty",
    "hyper",
    "tabby",
    "xcode",
    "code",
    "visual studio code",
    "cursor",
    "windsurf",
    "zed",
    "conductor",
    "herdr",
    "opencodex",
    "gnome-terminal",
    "gnome-terminal-server",
    "gnome terminal",
    "ptyxis",
    "konsole",
    "xterm",
    "xfce4-terminal",
    "tilix",
    "terminator",
    "foot",
    "rio",
    "cosmic-term",
    "code - oss",
    "code-oss",
    "vscodium",
    "windows terminal",
    "windowsterminal",
    "command prompt",
    "cmd",
    "powershell",
    "pwsh",
];

const SHARED_HOST_PREFIXES: &[&str] = &["t3 code", "zed "];

pub fn hosts(app: &str, agent: CodingAgentKind) -> bool {
    let name = app.trim().to_lowercase();
    if SHARED_HOSTS.contains(&name.as_str())
        || SHARED_HOST_PREFIXES.iter().any(|p| name.starts_with(p))
    {
        return true;
    }
    match agent {
        CodingAgentKind::ClaudeCode => name == "claude",
        CodingAgentKind::Codex => name == "codex" || name == "chatgpt",
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outcomes {
    pub opened_pull_requests: Vec<String>,
    pub merged_pull_requests: usize,
    pub commits: usize,
}

impl Outcomes {
    pub fn of<'a>(bursts: impl IntoIterator<Item = &'a CodingAgentBurst>) -> Self {
        let mut outcomes = Self::default();
        for burst in bursts {
            for action in &burst.actions {
                match action {
                    CodingAgentAction::OpenedPullRequest { title } => {
                        outcomes.opened_pull_requests.push(title.clone());
                    }
                    CodingAgentAction::MergedPullRequest { .. } => {
                        outcomes.merged_pull_requests += 1;
                    }
                    CodingAgentAction::Commit { .. } => outcomes.commits += 1,
                    _ => {}
                }
            }
        }
        outcomes
    }

    pub fn is_empty(&self) -> bool {
        self.opened_pull_requests.is_empty() && self.merged_pull_requests == 0 && self.commits == 0
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AgentTask {
    pub bursts: Vec<CodingAgentBurst>,
}

impl AgentTask {
    pub fn from_bursts(bursts: &[CodingAgentBurst]) -> Vec<Self> {
        super::sessions(bursts)
            .into_iter()
            .map(|bursts| Self { bursts })
            .collect()
    }

    pub fn title(&self) -> String {
        self.bursts
            .last()
            .map(CodingAgentBurst::work_title)
            .unwrap_or_default()
    }

    pub fn project(&self) -> Option<String> {
        self.bursts.iter().find_map(CodingAgentBurst::work_project)
    }

    pub fn agent(&self) -> Option<CodingAgentKind> {
        self.bursts.first().map(|b| b.agent)
    }

    pub fn start(&self) -> Option<DateTime<Utc>> {
        self.bursts.first().map(|b| b.start)
    }

    pub fn end(&self) -> Option<DateTime<Utc>> {
        self.bursts.iter().map(|b| b.end).max()
    }

    pub fn request(&self) -> Option<&str> {
        self.bursts
            .iter()
            .find_map(|b| b.prompts.first().map(String::as_str))
    }

    pub fn merged_numbers(&self) -> Vec<Option<i64>> {
        self.bursts
            .iter()
            .flat_map(|b| &b.actions)
            .filter_map(|action| match action {
                CodingAgentAction::MergedPullRequest { number } => Some(*number),
                _ => None,
            })
            .collect()
    }
}
