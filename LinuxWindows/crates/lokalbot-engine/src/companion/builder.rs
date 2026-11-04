//! Turns a `CompanionLibrary` into companion records
//! (`CompanionRecordBuilder.swift`). Pure reads: every field a record carries
//! is chosen here, from display-ready sources, so attendee emails, speaker
//! evidence, screenshot paths and screen text never enter one.

use std::collections::{BTreeSet, HashMap};
use std::sync::LazyLock;

use chrono::{DateTime, Local, NaiveDate, Offset as _, TimeZone as _, Timelike as _, Utc};
use lokalbot_core::Meeting;
use lokalbot_core::coding_agents::attribution::{AgentTask, Attribution};
use lokalbot_core::library::sha256_hex;
use lokalbot_core::model::{
    ActionStatus, ActionThread, ActivityBlock, MeetingOutcomes, OutcomeSourceCitation,
    ProjectSummary, SpeakerIdentity, Transcript, WorkSession,
};
use lokalbot_core::time::{local_day, local_day_bounds};
use lokalbot_core::timeline::{
    app_summary, app_usage, attributed_sessions, cleaned_title, clip_blocks, is_system_app,
    merged_duration,
};
use regex::Regex;
use uuid::Uuid;

use super::library::{CompanionLibrary, is_shared};
use super::records::{self, *};
use super::sharing::{DataClasses, Sharing, day_key, parse_day_key};

pub const LIBRARY_NAME: &str = "LokalBot";
/// More than a person saves in a day; the query wants a bound.
const SAVED_MOMENTS_PER_DAY: usize = 10_000;

pub struct RecordBuilder<'a> {
    library: &'a CompanionLibrary,
    people_by_meeting: HashMap<Uuid, Vec<NamedRef>>,
    projects_by_meeting: HashMap<Uuid, Vec<ProjectRef>>,
}

impl<'a> RecordBuilder<'a> {
    pub fn new(library: &'a CompanionLibrary) -> Self {
        let mut people: HashMap<Uuid, Vec<NamedRef>> = HashMap::new();
        for person in &library.people {
            for meeting in &person.meetings {
                people.entry(meeting.id).or_default().push(NamedRef {
                    id: person.id.clone(),
                    display_name: person.name.clone(),
                });
            }
        }
        let mut projects: HashMap<Uuid, Vec<ProjectRef>> = HashMap::new();
        for project in &library.projects {
            let Some(id) = project.tracked_id() else {
                continue;
            };
            for meeting in &project.meetings {
                projects.entry(meeting.id).or_default().push(ProjectRef {
                    id: records::id(id),
                    name: project.name.clone(),
                });
            }
        }
        Self {
            library,
            people_by_meeting: people,
            projects_by_meeting: projects,
        }
    }

    fn classes(&self) -> DataClasses {
        self.library.scope.data_classes
    }

    // ----------------------------------------------------------- everything

    /// Every record the current scope shares, manifest excluded.
    pub fn all_records(&self) -> Vec<Record> {
        let mut records = Vec::new();
        for meeting in &self.library.meetings {
            records.extend(self.meeting_records(meeting));
        }
        records.extend(
            self.day_keys()
                .iter()
                .filter_map(|key| self.day_record(key)),
        );
        records.extend(self.person_records());
        records.extend(self.project_records());
        records
    }

    // ------------------------------------------------------------- meetings

    /// The meeting record and, when transcripts are shared, its transcript.
    pub fn meeting_records(&self, meeting: &Meeting) -> Vec<Record> {
        if !self.classes().meetings
            || !is_shared(meeting, self.library.scope.history, self.library.now)
        {
            return Vec::new();
        }
        let transcript = load_transcript(self.library, meeting);
        let presentation = SpeakerPresentation::new(transcript.as_ref());
        let transcript_body = if self.classes().shares_transcripts() {
            transcript_body(meeting, transcript.as_ref(), &presentation)
        } else {
            None
        };
        let Some(body) = self.meeting_body(
            meeting,
            transcript.as_ref(),
            &presentation,
            transcript_body.is_some(),
        ) else {
            return Vec::new();
        };
        let Some(json) = encode(&body) else {
            return Vec::new();
        };
        let mut records = vec![Record {
            kind: RecordKind::Meeting,
            key: body.id.clone(),
            body_json: json,
        }];
        if let Some(json) = transcript_body.as_ref().and_then(encode) {
            records.push(Record {
                kind: RecordKind::Transcript,
                key: body.id,
                body_json: json,
            });
        }
        records
    }

    fn meeting_body(
        &self,
        meeting: &Meeting,
        transcript: Option<&Transcript>,
        presentation: &SpeakerPresentation,
        has_transcript: bool,
    ) -> Option<MeetingBody> {
        let ended_at = meeting.ended_at?;
        let projection = self.library.projections.get(&meeting.id);
        let speaker = |key: &str| -> Option<String> {
            let trimmed = key.trim();
            if trimmed.is_empty() {
                return None;
            }
            Some(match transcript {
                Some(transcript) => presentation.speaker(trimmed, transcript),
                None => label(&Transcript::default_speaker_name(trimmed)),
            })
        };
        let citations = |list: &[OutcomeSourceCitation]| -> Vec<Citation> {
            list.iter()
                .map(|citation| Citation {
                    start: citation.start,
                    end: citation.end,
                    speaker: speaker(&citation.speaker),
                    excerpt: citation.excerpt.clone(),
                })
                .collect()
        };
        let actions = projection
            .map(|projection| projection.action_references())
            .unwrap_or_default()
            .iter()
            .map(|reference| {
                let owner_is_user = reference.is_for_user;
                let owner_unclear = !owner_is_user
                    && if reference.owner_was_corrected {
                        reference.owner.is_none()
                    } else {
                        reference.action.ownership_is_unclear()
                    };
                let owner = if owner_is_user {
                    Some(presentation.owner("Me", true))
                } else if owner_unclear {
                    None
                } else {
                    reference
                        .owner
                        .as_deref()
                        .map(|owner| presentation.owner(owner, false))
                };
                let due = reference
                    .due
                    .as_deref()
                    .map(str::trim)
                    .filter(|due| !due.is_empty());
                Action {
                    id: reference.action.id.clone(),
                    text: reference.text.clone(),
                    owner,
                    owner_is_user,
                    owner_unclear,
                    due_date: reference.resolved_due_date.map(day_key),
                    due_text: due.map(str::to_string),
                    status: reference.status.raw().to_string(),
                    importance: reference.action.importance,
                    citations: citations(&reference.action.citations),
                }
            })
            .collect();
        let decisions = projection
            .map(|projection| projection.outcomes.decision_records.as_slice())
            .unwrap_or_default()
            .iter()
            .map(|decision| Statement {
                id: decision.id.clone(),
                text: decision.text.clone(),
                citations: citations(&decision.citations),
            })
            .collect();
        let open_questions = projection
            .map(|projection| projection.outcomes.open_questions.as_slice())
            .unwrap_or_default()
            .iter()
            .map(|question| Statement {
                id: MeetingOutcomes::stable_id("question", question, None, None, &[]),
                text: question.clone(),
                citations: Vec::new(),
            })
            .collect();
        let summary = self
            .library
            .library
            .summary(meeting)
            .ok()
            .flatten()
            .and_then(|markdown| shareable_summary(&markdown, meeting))
            .map(|summary| rewriting_screen_citations(&summary, &|id| self.screen_time(id)));
        let notes = self.library.library.notes(meeting).unwrap_or_default();
        let notes = notes.trim();
        let app = meeting.app_name.trim();
        Some(MeetingBody {
            id: records::id(meeting.id),
            title: meeting.display_title(),
            started_at: instant(meeting.started_at),
            ended_at: instant(ended_at),
            day: day_key(local_day(meeting.started_at)),
            time_zone_offset_minutes: Local
                .offset_from_utc_datetime(&meeting.started_at.naive_utc())
                .fix()
                .local_minus_utc()
                / 60,
            duration_seconds: meeting.duration_seconds().max(0.0),
            app_name: (!app.is_empty()).then(|| app.to_string()),
            people: self
                .people_by_meeting
                .get(&meeting.id)
                .cloned()
                .unwrap_or_default(),
            projects: self
                .projects_by_meeting
                .get(&meeting.id)
                .cloned()
                .unwrap_or_default(),
            summary_markdown: summary,
            notes_markdown: (!notes.is_empty()).then(|| notes.to_string()),
            actions,
            decisions,
            open_questions,
            has_transcript,
            merged_into: None,
        })
    }

    // ----------------------------------------------------------------- days

    /// Days that have a digest, recorded activity, or a shared meeting,
    /// inside the history window, newest first.
    pub fn day_keys(&self) -> Vec<String> {
        let mut keys: BTreeSet<String> = BTreeSet::new();
        let classes = self.classes();
        let history = self.library.scope.history;
        let now = self.library.now;
        if classes.meetings || classes.timeline {
            for meeting in &self.library.meetings {
                keys.insert(day_key(local_day(meeting.started_at)));
            }
        }
        if classes.digests {
            let folder = self.library.library.paths().journal_dir();
            for entry in std::fs::read_dir(folder).into_iter().flatten().flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                let Some(key) = name.strip_suffix(".md") else {
                    continue;
                };
                if parse_day_key(key).is_some_and(|day| history.contains_day(day, now)) {
                    keys.insert(key.to_string());
                }
            }
        }
        if classes.timeline
            && let Ok(Some(earliest)) = self.library.library.earliest_activity_start()
        {
            let today = local_day(now);
            let first = local_day(earliest);
            let mut day = history
                .first_day(today)
                .map_or(first, |window| window.max(first));
            while day <= today {
                let (start, end) = local_day_bounds(day);
                if self
                    .library
                    .library
                    .has_activity(start, end)
                    .unwrap_or(false)
                {
                    keys.insert(day_key(day));
                }
                let Some(next) = day.succ_opt() else {
                    break;
                };
                day = next;
            }
        }
        keys.into_iter().rev().collect()
    }

    pub fn day_record(&self, key: &str) -> Option<Record> {
        let day = parse_day_key(key)?;
        if !self
            .library
            .scope
            .history
            .contains_day(day, self.library.now)
        {
            return None;
        }
        let (start, end) = local_day_bounds(day);
        let mut meetings: Vec<&Meeting> = self
            .library
            .meetings
            .iter()
            .filter(|meeting| meeting.started_at >= start && meeting.started_at < end)
            .collect();
        meetings.sort_by_key(|meeting| meeting.started_at);
        let digest = self.digest(day);
        let timeline = self.timeline(start, end, &meetings);
        let meeting_ids: Vec<String> = if self.classes().meetings {
            meetings
                .iter()
                .map(|meeting| records::id(meeting.id))
                .collect()
        } else {
            Vec::new()
        };
        let has_activity = timeline
            .as_ref()
            .is_some_and(|t| !t.sessions.is_empty() || !t.saved_moments.is_empty());
        if digest.is_none() && !has_activity && meeting_ids.is_empty() {
            return None;
        }
        let body = DayBody {
            date: key.to_string(),
            digest,
            timeline,
            meeting_ids,
        };
        Some(Record {
            kind: RecordKind::Day,
            key: key.to_string(),
            body_json: encode(&body)?,
        })
    }

    fn digest(&self, day: NaiveDate) -> Option<DigestBody> {
        if !self.classes().digests {
            return None;
        }
        let library = &self.library.library;
        let raw = library.journal_markdown(day).ok().flatten()?;
        if raw.trim().is_empty() {
            return None;
        }
        // An unknown sidecar version is not one this build wrote or understands.
        let metadata = library
            .digest_meta(day)
            .ok()
            .flatten()
            .filter(|meta| (1..=2).contains(&meta.version));
        let generated = metadata
            .as_ref()
            .is_some_and(|meta| meta.journal_digest == sha256_hex(raw.as_bytes()));
        let modified = std::fs::metadata(library.journal_path(day))
            .and_then(|metadata| metadata.modified())
            .ok()
            .map(DateTime::<Utc>::from);
        let generated_at = if generated {
            metadata.as_ref().map(|meta| meta.generated_at)
        } else {
            modified
        };
        let markdown = shareable_digest(&raw, &|id| self.screen_time(id));
        let parsed = lokalbot_core::parse_digest(&markdown);
        let line = |title: &str, summary: &str| -> Option<String> {
            let text = if title.trim().is_empty() {
                summary
            } else {
                title
            };
            let text = text.trim();
            (!text.is_empty()).then(|| text.to_string())
        };
        let tasks = parsed
            .tasks
            .iter()
            .filter_map(|task| line(&task.title, &task.summary))
            .collect();
        let mut follow_ups: Vec<String> = parsed
            .follow_up_tasks
            .iter()
            .filter_map(|task| line(&task.title, &task.summary))
            .collect();
        follow_ups.extend(parsed.tasks.iter().filter_map(|t| t.next_step.clone()));
        Some(DigestBody {
            sections: DigestSections {
                highlights: items(&parsed.at_a_glance_markdown),
                decisions: parsed.decisions,
                tasks,
                blockers: parsed.blockers,
                follow_ups,
            },
            markdown,
            generated_at: generated_at.map(instant),
            user_edited: !generated,
        })
    }

    fn timeline(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        meetings: &[&Meeting],
    ) -> Option<Timeline> {
        let classes = self.classes();
        if !classes.timeline {
            return None;
        }
        let library = &self.library.library;
        let raw = library.activity_blocks(start, end).unwrap_or_default();
        // One definition of active time for every day surface: valid,
        // non-system intervals clipped to the day (`DayActivityProjection`).
        let blocks: Vec<ActivityBlock> = clip_blocks(&raw, start, end)
            .into_iter()
            .filter(|block| !is_system_app(&block.app) && block.end > block.start)
            .collect();
        let bursts = library.coding_agent_bursts(start, end).unwrap_or_default();
        let attribution = Attribution::new(&bursts);
        let work = attributed_sessions(&blocks, Some(&attribution));
        let tracked_seconds = work.iter().map(|session| session.active_seconds).sum();
        let mut sessions: Vec<Session> = work
            .iter()
            .map(|session| self.work_session(session, &blocks))
            .collect();
        for task in AgentTask::from_bursts(&attribution.bursts) {
            let (Some(task_start), Some(task_end), Some(agent)) =
                (task.start(), task.end(), task.agent())
            else {
                continue;
            };
            sessions.push(Session {
                start: instant(task_start),
                end: instant(task_end),
                title: task.title(),
                kind: "agent".into(),
                meeting_id: None,
                project: task.project(),
                apps: vec![Seconds {
                    name: agent.display_name().to_string(),
                    seconds: task.bursts.iter().map(|b| b.active_duration).sum(),
                }],
                window_titles: None,
            });
        }
        if classes.meetings {
            for meeting in meetings {
                let meeting_end = meeting.ended_at.unwrap_or(meeting.started_at);
                let app = meeting.app_name.trim();
                let seconds =
                    (meeting_end - meeting.started_at).num_milliseconds().max(0) as f64 / 1000.0;
                sessions.push(Session {
                    start: instant(meeting.started_at),
                    end: instant(meeting_end),
                    title: meeting.display_title(),
                    kind: "meeting".into(),
                    meeting_id: Some(records::id(meeting.id)),
                    project: self
                        .projects_by_meeting
                        .get(&meeting.id)
                        .and_then(|projects| projects.first())
                        .map(|project| project.name.clone()),
                    apps: if app.is_empty() {
                        Vec::new()
                    } else {
                        vec![Seconds {
                            name: app.to_string(),
                            seconds,
                        }]
                    },
                    window_titles: None,
                });
            }
        }
        sessions.sort_by(|a, b| a.start.cmp(&b.start).then_with(|| a.kind.cmp(&b.kind)));
        let split = attribution.split(&blocks);
        let mut by_project: Vec<Seconds> = split
            .projects
            .iter()
            .map(|share| Seconds {
                name: share.project.clone(),
                seconds: share.seconds,
            })
            .collect();
        if !by_project.is_empty() && split.unattributed_seconds > 0.0 {
            by_project.push(Seconds {
                name: "Other".into(),
                seconds: split.unattributed_seconds,
            });
        }
        by_project.sort_by(|a, b| {
            b.seconds
                .partial_cmp(&a.seconds)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.name.cmp(&b.name))
        });
        let saved_moments = library
            .saved_moments_between(start, end, SAVED_MOMENTS_PER_DAY)
            .unwrap_or_default()
            .into_iter()
            .map(|moment| {
                let note = moment.note.trim();
                let title = moment.window_title.trim();
                let label = if !note.is_empty() {
                    note.to_string()
                } else if classes.shares_window_titles() && !title.is_empty() {
                    title.to_string()
                } else {
                    moment.app.clone()
                };
                SavedMoment {
                    at: instant(moment.captured_at),
                    label,
                }
            })
            .collect();
        Some(Timeline {
            tracked_seconds,
            sessions,
            by_project,
            by_app: app_usage(&blocks)
                .into_iter()
                .map(|usage| Seconds {
                    name: usage.app,
                    seconds: usage.seconds,
                })
                .collect(),
            saved_moments,
        })
    }

    /// A work session as the Timeline rail shows it. Without the window
    /// titles class, a title made from window titles falls back to the
    /// session's project or apps.
    fn work_session(&self, session: &WorkSession, blocks: &[ActivityBlock]) -> Session {
        let own: Vec<&ActivityBlock> = blocks
            .iter()
            .filter(|block| session.block_ids.contains(&block.id))
            .collect();
        let mut by_app: HashMap<&str, Vec<&ActivityBlock>> = HashMap::new();
        for block in &own {
            by_app.entry(block.app.as_str()).or_default().push(block);
        }
        let mut apps: Vec<Seconds> = by_app
            .iter()
            .map(|(name, blocks)| Seconds {
                name: name.to_string(),
                seconds: merged_duration(blocks),
            })
            .collect();
        apps.sort_by(|a, b| {
            b.seconds
                .partial_cmp(&a.seconds)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.name.cmp(&b.name))
        });
        let project = session
            .title_names_project
            .then(|| {
                session
                    .project_shares
                    .first()
                    .map(|share| share.project.clone())
            })
            .flatten();
        let mut title = session.title.clone();
        let lowered = title.to_lowercase();
        let names_window = session
            .notable_titles
            .iter()
            .any(|window| !window.is_empty() && lowered.contains(&window.to_lowercase()));
        let shares_titles = self.classes().shares_window_titles();
        if !shares_titles && !session.title_names_apps && names_window {
            title = project.clone().unwrap_or_else(|| {
                app_summary(&apps.iter().map(|app| app.name.as_str()).collect::<Vec<_>>())
            });
        }
        let titles = if shares_titles {
            let titles = sustained_titles(session, &own);
            (!titles.is_empty()).then_some(titles)
        } else {
            None
        };
        Session {
            start: instant(session.start),
            end: instant(session.end),
            title,
            kind: "work".into(),
            meeting_id: None,
            project,
            apps,
            window_titles: titles,
        }
    }

    fn screen_time(&self, id: i64) -> Option<DateTime<Utc>> {
        let moment = self.library.library.screen_moment(id).ok().flatten()?;
        Some(moment.ts)
    }

    // ------------------------------------------------- people and projects

    pub fn person_records(&self) -> Vec<Record> {
        if !self.classes().people {
            return Vec::new();
        }
        self.library
            .people
            .iter()
            .filter_map(|person| {
                let mut open_work = open_work(&person.their_actions, true);
                open_work.extend(self::open_work(&person.my_actions, false));
                let body = PersonBody {
                    id: person.id.clone(),
                    display_name: person.name.clone(),
                    last_met_at: person.last_met().map(instant),
                    open_work,
                    decisions_together: person
                        .decisions
                        .iter()
                        .map(|(meeting, decision)| DecisionRef {
                            meeting_id: records::id(meeting.id),
                            text: decision.text.clone(),
                        })
                        .collect(),
                    meeting_ids: person
                        .meetings
                        .iter()
                        .map(|meeting| records::id(meeting.id))
                        .collect(),
                };
                Some(Record {
                    kind: RecordKind::Person,
                    key: person.id.clone(),
                    body_json: encode(&body)?,
                })
            })
            .collect()
    }

    pub fn project_records(&self) -> Vec<Record> {
        if !self.classes().projects {
            return Vec::new();
        }
        let mut people_by_name: HashMap<String, &lokalbot_core::model::PersonProfile> =
            HashMap::new();
        for person in &self.library.people {
            for name in std::iter::once(&person.name).chain(&person.other_names) {
                people_by_name
                    .entry(lokalbot_core::people::normalized(name))
                    .or_insert(person);
            }
        }
        self.library
            .projects
            .iter()
            .filter_map(|project| {
                let tracked = project.tracked_id()?;
                let key = records::id(tracked);
                let mut seen: BTreeSet<&str> = BTreeSet::new();
                let people = project
                    .people
                    .iter()
                    .filter_map(|name| {
                        let person =
                            people_by_name.get(&lokalbot_core::people::normalized(name))?;
                        seen.insert(person.id.as_str()).then(|| NamedRef {
                            id: person.id.clone(),
                            display_name: person.name.clone(),
                        })
                    })
                    .collect();
                let body = ProjectBody {
                    id: key.clone(),
                    name: project.name.clone(),
                    where_it_stands: self
                        .library
                        .project_summaries
                        .get(&tracked)
                        .and_then(where_it_stands),
                    your_actions: project
                        .my_actions
                        .iter()
                        .filter(|thread| thread.status() == ActionStatus::Open)
                        .map(|thread| {
                            let reference = thread.latest();
                            YourAction {
                                meeting_id: records::id(reference.meeting_id),
                                action_id: reference.action.id.clone(),
                                text: thread.text.clone(),
                                due_date: thread.resolved_due_date.map(day_key),
                                status: thread.status().raw().to_string(),
                            }
                        })
                        .collect(),
                    waiting_on_others: project
                        .others_actions
                        .iter()
                        .chain(&project.older_others_actions)
                        .filter(|thread| thread.status() == ActionStatus::Open)
                        .map(|thread| {
                            let reference = thread.latest();
                            WaitingOn {
                                meeting_id: records::id(reference.meeting_id),
                                action_id: reference.action.id.clone(),
                                text: thread.text.clone(),
                                owner: thread.owner.as_deref().map(label),
                                due_date: thread.resolved_due_date.map(day_key),
                            }
                        })
                        .collect(),
                    decisions: project
                        .decisions
                        .iter()
                        .map(|(meeting, decision)| DecisionRef {
                            meeting_id: records::id(meeting.id),
                            text: decision.text.clone(),
                        })
                        .collect(),
                    time_this_week_seconds: project.week_seconds,
                    people,
                    meeting_ids: project
                        .meetings
                        .iter()
                        .map(|meeting| records::id(meeting.id))
                        .collect(),
                };
                Some(Record {
                    kind: RecordKind::Project,
                    key,
                    body_json: encode(&body)?,
                })
            })
            .collect()
    }
}

pub fn manifest(sharing: &Sharing, mac_name: &str, now: DateTime<Utc>) -> Option<String> {
    encode(&ManifestBody {
        schema_version: 1,
        library_name: LIBRARY_NAME.to_string(),
        mac_name: mac_name.to_string(),
        data_classes: sharing.data_classes.effective(),
        history_days: sharing.history.days(),
        ask_enabled: sharing.answers_questions,
        recordings_enabled: sharing.accepts_recordings,
        generated_at: instant(now),
    })
}

fn load_transcript(library: &CompanionLibrary, meeting: &Meeting) -> Option<Transcript> {
    let mut transcript = library.library.transcript(meeting).ok().flatten()?;
    if let Some(range) = meeting.valid_content_range() {
        range.apply(&mut transcript);
    }
    Some(transcript)
}

/// Display text, times, display names and a stable color per speaker; never
/// attribution, identity evidence or calendar identity links.
fn transcript_body(
    meeting: &Meeting,
    transcript: Option<&Transcript>,
    presentation: &SpeakerPresentation,
) -> Option<TranscriptBody> {
    let transcript = transcript?;
    let segments: Vec<TranscriptSegment> = transcript
        .segments
        .iter()
        .filter_map(|segment| {
            let text = Transcript::display_text(&segment.text);
            if text.is_empty() {
                return None;
            }
            Some(TranscriptSegment {
                start: segment.start,
                end: segment.end,
                speaker: presentation.speaker(&segment.speaker, transcript),
                color_index: color_index(
                    presentation.color_index(&segment.speaker),
                    &segment.speaker,
                ),
                text,
            })
        })
        .collect();
    if segments.is_empty() {
        return None;
    }
    Some(TranscriptBody {
        meeting_id: records::id(meeting.id),
        segments,
    })
}

/// 0 is the person themselves, 1–7 the speaker palette in order of first
/// appearance, -1 a voice that could not be told apart.
pub fn color_index(presentation_index: i32, speaker: &str) -> i32 {
    if Transcript::default_speaker_name(speaker) == "Speaker unclear" {
        return -1;
    }
    if presentation_index <= 0 {
        return 0;
    }
    (presentation_index - 1) % 7 + 1
}

fn open_work(threads: &[ActionThread], theirs: bool) -> Vec<OpenWork> {
    threads
        .iter()
        .filter(|thread| thread.status() == ActionStatus::Open)
        .map(|thread| {
            let reference = thread.latest();
            OpenWork {
                meeting_id: records::id(reference.meeting_id),
                action_id: reference.action.id.clone(),
                text: thread.text.clone(),
                due_date: thread.resolved_due_date.map(day_key),
                theirs,
            }
        })
        .collect()
}

/// A session's window titles that held attention for at least a minute,
/// most time first, at most six (`titleEvidence`).
fn sustained_titles(session: &WorkSession, own: &[&ActivityBlock]) -> Vec<String> {
    let mut by_title: HashMap<String, Vec<&ActivityBlock>> = HashMap::new();
    for block in own {
        if let Some(title) = cleaned_title(&block.title, &block.app) {
            by_title
                .entry(title.to_lowercase())
                .or_default()
                .push(block);
        }
    }
    session
        .notable_titles
        .iter()
        .filter(|title| {
            by_title
                .get(&title.to_lowercase())
                .is_some_and(|blocks| merged_duration(blocks) >= 60.0)
        })
        .take(6)
        .cloned()
        .collect()
}

/// The note's overview and the points taken from meetings. Points from
/// overnight review notes stay on this computer with the rest of Dream memory.
pub fn where_it_stands(summary: &ProjectSummary) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    let overview = summary.overview.trim();
    if !overview.is_empty() {
        parts.push(overview.to_string());
    }
    let points: Vec<String> = summary
        .points
        .iter()
        .filter(|point| point.meeting_id.is_some())
        .map(|point| format!("- {}", point.text))
        .collect();
    if !points.is_empty() {
        parts.push(points.join("\n"));
    }
    let questions: Vec<String> = summary
        .open_questions
        .iter()
        .map(|question| format!("- {question}"))
        .collect();
    if !questions.is_empty() {
        parts.push(format!("**Open questions**\n{}", questions.join("\n")));
    }
    (!parts.is_empty()).then(|| parts.join("\n\n"))
}

// ------------------------------------------------------------------ summary

/// The summary as the Meetings page shows it: no provenance line and no title
/// heading, which the phone draws from the record itself.
pub fn shareable_summary(markdown: &str, meeting: &Meeting) -> Option<String> {
    let body = merged_meeting_body(&without_provenance(markdown), meeting);
    let mut lines: Vec<&str> = body.split('\n').collect();
    if let Some(first) = lines.iter().position(|line| !line.trim().is_empty())
        && lines[first].starts_with("# ")
    {
        lines.remove(first);
    }
    let text = without_provenance(&lines.join("\n"));
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// `SummaryPresentation.split`: lifts out the first non-empty, non-heading
/// line among the leading four when it holds at least two `**Label:** value`
/// pairs joined by "·", so a body opening with bold text stays intact.
fn without_provenance(markdown: &str) -> String {
    let lines: Vec<&str> = markdown.split('\n').collect();
    for (index, line) in lines.iter().enumerate().take(4) {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if !is_provenance_line(trimmed) {
            break;
        }
        let mut kept = lines.clone();
        kept.remove(index);
        return kept.join("\n").trim().to_string();
    }
    markdown.to_string()
}

fn is_provenance_line(line: &str) -> bool {
    let mut count = 0;
    for piece in line.split(" · ") {
        let piece = piece.trim();
        let Some(rest) = piece.strip_prefix("**") else {
            return false;
        };
        let Some((label, value)) = rest.split_once(":**") else {
            return false;
        };
        if label.trim().is_empty() || value.trim().is_empty() {
            return false;
        }
        count += 1;
    }
    count >= 2
}

/// `SummaryPresentation.meetingBody`: older merge drafts open with
/// implementation details instead of meeting content.
fn merged_meeting_body(markdown: &str, meeting: &Meeting) -> String {
    if !meeting.is_merged_meeting() {
        return markdown.to_string();
    }
    let heading = format!("# {}", meeting.title);
    markdown
        .split('\n')
        .enumerate()
        .filter(|(_, line)| {
            !line.starts_with(
                "This is a non-destructive merge. Source evidence remains on disk for provenance,",
            )
        })
        .map(|(index, line)| {
            if index == 0 && (line == heading || line.starts_with(&format!("{heading} — "))) {
                format!("# {}{}", meeting.display_title(), &line[heading.len()..])
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

// ------------------------------------------------------------------- digest

/// Level-2 sections LokalBot renders from raw capture rather than writes.
const EVIDENCE_SECTIONS: [&str; 2] = ["full activity log", "chronological work log"];

/// Day Digest Markdown made fit for a phone: the raw evidence log, which
/// quotes screen text and window titles, stays on this computer, and screen
/// citations become the time of the moment they point at.
pub fn shareable_digest(markdown: &str, time: &dyn Fn(i64) -> Option<DateTime<Utc>>) -> String {
    rewriting_screen_citations(&removing_evidence_sections(markdown), time)
        .trim()
        .to_string()
}

pub fn removing_evidence_sections(markdown: &str) -> String {
    let mut kept = Vec::new();
    let mut skipping = false;
    for line in markdown.split('\n') {
        if let Some(title) = line.strip_prefix("## ") {
            skipping = EVIDENCE_SECTIONS.contains(&title.trim().to_lowercase().as_str());
        } else if line.starts_with("# ") {
            skipping = false;
        }
        if !skipping {
            kept.push(line);
        }
    }
    kept.join("\n")
}

static SCREEN_CITATION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[ \t]?\[screen(?::(\d+))?\]").expect("valid pattern"));

/// `[screen:42]` becomes "(screen moment at 14:32)"; a marker whose capture
/// is gone, and a bare `[screen]`, are dropped.
pub fn rewriting_screen_citations(
    text: &str,
    time: &dyn Fn(i64) -> Option<DateTime<Utc>>,
) -> String {
    if !text.contains("[screen") {
        return text.to_string();
    }
    SCREEN_CITATION
        .replace_all(text, |captures: &regex::Captures| {
            captures
                .get(1)
                .and_then(|id| id.as_str().parse::<i64>().ok())
                .and_then(time)
                .map(|at| {
                    let local = at.with_timezone(&Local);
                    format!(
                        " (screen moment at {:02}:{:02})",
                        local.hour(),
                        local.minute()
                    )
                })
                .unwrap_or_default()
        })
        .into_owned()
}

/// Top-level list items without their markers, or the paragraphs of a passage
/// written as prose.
pub fn items(markdown: &str) -> Vec<String> {
    let bullets: Vec<String> = markdown
        .split('\n')
        .filter(|line| line.starts_with("- ") || line.starts_with("* "))
        .map(|line| line[2..].trim().to_string())
        .filter(|line| !line.is_empty())
        .collect();
    if !bullets.is_empty() {
        return bullets;
    }
    markdown
        .split("\n\n")
        .map(str::trim)
        .filter(|paragraph| !paragraph.is_empty())
        .map(str::to_string)
        .collect()
}

// ----------------------------------------------------------------- speakers

/// `SpeakerDisplayName.label`: stored keys keep their canonical names ("Me",
/// "Them 2"); "Local speaker" stays because that voice is not yet confirmed
/// as the user. These go to the phone in English, as from the Mac.
pub fn label(name: &str) -> String {
    let trimmed = name.trim();
    let lower = trimmed.to_lowercase();
    if lower == "them" {
        return "Other speaker".into();
    }
    if let Some(number) = trimmed
        .strip_prefix("Them ")
        .or_else(|| trimmed.strip_prefix("them "))
        && !number.is_empty()
        && number.chars().all(|c| c.is_ascii_digit())
    {
        return format!("Speaker {number}");
    }
    name.to_string()
}

fn label_with(name: &str, identity: SpeakerIdentity) -> String {
    if identity == SpeakerIdentity::User && name.trim().eq_ignore_ascii_case("me") {
        return "You".into();
    }
    label(name)
}

static SOURCE_SUFFIX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?: · source \d+)+$").expect("valid pattern"));
static PLACEHOLDER_SPEAKER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:Them(?: \d+)?|Speaker(?: \d+| unclear)?|Local speaker)$")
        .expect("valid pattern")
});

/// Display-only names for a meeting's speakers (`MeetingSpeakerPresentation`).
/// Source-scoped keys, confirmed identities, and saved aliases stay untouched.
#[derive(Default)]
pub struct SpeakerPresentation {
    names: HashMap<String, String>,
    replacements: HashMap<String, String>,
    owner_identities: HashMap<String, SpeakerIdentity>,
    identities: HashMap<String, SpeakerIdentity>,
    color_indices: HashMap<String, i32>,
}

impl SpeakerPresentation {
    pub fn new(transcript: Option<&Transcript>) -> Self {
        let mut this = Self::default();
        let Some(transcript) = transcript else {
            return this;
        };
        let roster = transcript.speaker_roster();
        for key in roster.keys() {
            this.identities
                .insert(key.clone(), transcript.speaker_identity(key));
        }
        let mut next_color = 1;
        for segment in &transcript.segments {
            let key = Transcript::canonical_speaker_key(&segment.speaker);
            if this.color_indices.contains_key(&key) {
                continue;
            }
            if this.identities.get(&key) == Some(&SpeakerIdentity::User) {
                this.color_indices.insert(key, 0);
            } else {
                this.color_indices.insert(key, next_color);
                next_color += 1;
            }
        }
        let mut by_name: HashMap<String, Vec<SpeakerIdentity>> = HashMap::new();
        for (key, name) in &roster {
            by_name
                .entry(name.to_lowercase())
                .or_default()
                .push(this.identities[key]);
        }
        for (name, group) in by_name {
            if let [only] = group.as_slice() {
                this.owner_identities.insert(name, *only);
            }
        }
        let mut next_speaker = 1;
        for segment in &transcript.segments {
            let key = Transcript::canonical_speaker_key(&segment.speaker);
            if this.names.contains_key(&key) {
                continue;
            }
            let original = roster
                .get(&key)
                .cloned()
                .unwrap_or_else(|| Transcript::default_speaker_name(&key));
            if !key.starts_with("source")
                || !key.contains(':')
                || !SOURCE_SUFFIX.is_match(&original)
            {
                this.names.insert(key, original);
                continue;
            }
            let clean = SOURCE_SUFFIX.replace(&original, "").into_owned();
            let name = if PLACEHOLDER_SPEAKER.is_match(&clean) {
                next_speaker += 1;
                format!("Speaker {}", next_speaker - 1)
            } else {
                clean
            };
            this.names.insert(key, name.clone());
            this.replacements.insert(original, name);
        }
        this
    }

    pub fn speaker(&self, key: &str, transcript: &Transcript) -> String {
        let canonical = Transcript::canonical_speaker_key(key);
        let name = self
            .names
            .get(&canonical)
            .cloned()
            .unwrap_or_else(|| transcript.speaker_name(key));
        label_with(
            &name,
            self.identities
                .get(&canonical)
                .copied()
                .unwrap_or(SpeakerIdentity::Unresolved),
        )
    }

    /// Stable across alias edits and the action-prioritized review ordering.
    pub fn color_index(&self, key: &str) -> i32 {
        self.color_indices
            .get(&Transcript::canonical_speaker_key(key))
            .copied()
            .unwrap_or(1)
    }

    /// An action owner as people should read it ("You", "Other speaker").
    pub fn owner(&self, value: &str, is_for_user: bool) -> String {
        let key = value.trim().to_lowercase();
        let identity = if is_for_user {
            SpeakerIdentity::User
        } else {
            self.owner_identities
                .get(&key)
                .copied()
                .unwrap_or(SpeakerIdentity::Unresolved)
        };
        label_with(&self.text(value), identity)
    }

    fn text(&self, value: &str) -> String {
        // Longest first protects nested merges and source 1 versus source 10.
        let mut originals: Vec<&String> = self.replacements.keys().collect();
        originals.sort_by_key(|original| std::cmp::Reverse(original.chars().count()));
        originals
            .into_iter()
            .fold(value.to_string(), |text, original| {
                replacing_whole(&text, original, &self.replacements[original])
            })
    }
}

/// Replaces `original` where no letter or number touches it on either side.
fn replacing_whole(text: &str, original: &str, replacement: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    let mut before: Option<char> = None;
    while let Some(found) = rest.find(original) {
        let head = &rest[..found];
        let tail = &rest[found + original.len()..];
        let left = head.chars().next_back().or(before);
        let touches = |c: Option<char>| c.is_some_and(char::is_alphanumeric);
        out.push_str(head);
        if touches(left) || touches(tail.chars().next()) {
            out.push_str(original);
        } else {
            out.push_str(replacement);
        }
        before = original.chars().next_back();
        rest = tail;
    }
    out.push_str(rest);
    out
}
