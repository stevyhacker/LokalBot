use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, SystemTime};

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use lokalbot_core::coding_agents::CodingAgentKind;
use rusqlite::{Connection, OpenFlags, params};
use serde_json::Value;

use super::builder::{Event, EventKind, TimedEvent as _, Transcript, compacting_activity};
use super::scanner::{ReadResult, SessionKey};
use super::text;

pub struct T3CodeReader {
    pub root: PathBuf,
}

impl T3CodeReader {
    pub fn transcripts(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> ReadResult {
        let mut result = ReadResult::default();
        let mut seen_threads: HashSet<String> = HashSet::new();

        let v2_path = self.root.join("statev2.sqlite");
        if let Some((modified, size)) = database_metadata(&v2_path)
            && DateTime::<Utc>::from(modified) >= start
        {
            match open_read_only(&v2_path) {
                Ok(db) => {
                    result.files_read += 1;
                    result.bytes_read += size;
                    match table_exists(&db, "orchestration_v2_projection_threads") {
                        Ok(true) => match read_v2(&db, start, end) {
                            Ok((transcripts, claimed)) => {
                                result.claimed_sessions.extend(claimed);
                                for transcript in transcripts {
                                    if seen_threads.insert(transcript.session_id.clone()) {
                                        result.transcripts.push(transcript);
                                    }
                                }
                            }
                            Err(err) => {
                                log::debug!("unreadable t3 code v2 database: {err}");
                                result.unreadable_files.push(v2_path.display().to_string());
                            }
                        },
                        Ok(false) => {}
                        Err(err) => {
                            log::debug!("unreadable t3 code v2 schema: {err}");
                            result.unreadable_files.push(v2_path.display().to_string());
                        }
                    }
                }
                Err(err) => {
                    log::debug!("could not open t3 code v2 database: {err}");
                    result.unreadable_files.push(v2_path.display().to_string());
                }
            }
        }

        let v1_path = self.root.join("state.sqlite");
        if let Some((modified, size)) = database_metadata(&v1_path)
            && DateTime::<Utc>::from(modified) >= start
        {
            match open_read_only(&v1_path) {
                Ok(db) => {
                    result.files_read += 1;
                    result.bytes_read += size;
                    match table_exists(&db, "projection_threads") {
                        Ok(true) => match read_v1(&db, start, end, &seen_threads) {
                            Ok((transcripts, claimed)) => {
                                result.claimed_sessions.extend(claimed);
                                for transcript in transcripts {
                                    if seen_threads.insert(transcript.session_id.clone()) {
                                        result.transcripts.push(transcript);
                                    }
                                }
                            }
                            Err(err) => {
                                log::debug!("unreadable t3 code v1 database: {err}");
                                result.unreadable_files.push(v1_path.display().to_string());
                            }
                        },
                        Ok(false) => {}
                        Err(err) => {
                            log::debug!("unreadable t3 code v1 schema: {err}");
                            result.unreadable_files.push(v1_path.display().to_string());
                        }
                    }
                }
                Err(err) => {
                    log::debug!("could not open t3 code v1 database: {err}");
                    result.unreadable_files.push(v1_path.display().to_string());
                }
            }
        }

        result
            .transcripts
            .sort_by(|a, b| a.session_id.cmp(&b.session_id));
        result
    }
}

struct ThreadHeader {
    title: Option<String>,
    working_directory: Option<String>,
    branch: Option<String>,
    created_at: Option<DateTime<Utc>>,
    pull_requests_json: Option<String>,
}

fn read_v2(
    db: &Connection,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> rusqlite::Result<(Vec<Transcript>, HashSet<SessionKey>)> {
    let wide_start = iso_utc(start - Duration::hours(14));
    let wide_end = iso_utc(end + Duration::hours(14));

    let mut claimed: HashSet<SessionKey> = HashSet::new();
    if table_exists(db, "orchestration_v2_projection_provider_threads")? {
        let mut stmt = db.prepare(
            "SELECT driver, json_extract(payload_json, '$.nativeThreadRef.nativeId') \
             FROM orchestration_v2_projection_provider_threads \
             WHERE driver IN ('claudeAgent', 'codex') \
               AND updated_at >= ?1 \
               AND (json_extract(payload_json, '$.createdAt') IS NULL \
                    OR json_extract(payload_json, '$.createdAt') < ?2) \
               AND json_extract(payload_json, '$.nativeThreadRef.nativeId') IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![&wide_start, &wide_end], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (driver, native_id) = row?;
            if !native_id.is_empty()
                && let Some(agent) = native_agent_kind(&driver)
            {
                claimed.insert(SessionKey {
                    agent,
                    session_id: native_id,
                });
            }
        }
    }

    let has_projects = table_exists(db, "projection_projects")?;
    let threads_sql = if has_projects {
        "SELECT t.thread_id, t.title, t.created_at, \
                json_extract(t.payload_json, '$.branch'), \
                json_extract(t.payload_json, '$.worktreePath'), \
                json_extract(t.payload_json, '$.lineage.parentThreadId'), \
                json_extract(t.payload_json, '$.lineage.relationshipToParent'), \
                json_extract(t.payload_json, '$.pullRequests'), \
                p.workspace_root \
         FROM orchestration_v2_projection_threads t \
         LEFT JOIN projection_projects p ON t.project_id = p.project_id \
         WHERE t.deleted_at IS NULL \
           AND t.updated_at >= ?1 \
           AND t.created_at < ?2"
    } else {
        "SELECT t.thread_id, t.title, t.created_at, \
                json_extract(t.payload_json, '$.branch'), \
                json_extract(t.payload_json, '$.worktreePath'), \
                json_extract(t.payload_json, '$.lineage.parentThreadId'), \
                json_extract(t.payload_json, '$.lineage.relationshipToParent'), \
                json_extract(t.payload_json, '$.pullRequests'), \
                NULL \
         FROM orchestration_v2_projection_threads t \
         WHERE t.deleted_at IS NULL \
           AND t.updated_at >= ?1 \
           AND t.created_at < ?2"
    };

    let mut threads: HashMap<String, ThreadHeader> = HashMap::new();
    {
        let mut stmt = db.prepare(threads_sql)?;
        let rows = stmt.query_map(params![&wide_start, &wide_end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, Option<String>>(8)?,
            ))
        })?;
        for row in rows {
            let (
                id,
                raw_title,
                created_at,
                branch,
                worktree_path,
                parent_id,
                relationship,
                pull_requests_json,
                workspace_root,
            ) = row?;
            if id.is_empty()
                || is_subagent_thread(&id, parent_id.as_deref(), relationship.as_deref())
            {
                continue;
            }
            let working_directory = non_empty(workspace_root).or_else(|| non_empty(worktree_path));
            let branch = non_empty(branch).filter(|b| b != "HEAD");
            threads.insert(
                id,
                ThreadHeader {
                    title: raw_title.as_deref().and_then(text::title),
                    working_directory,
                    branch,
                    created_at: created_at.as_deref().and_then(text::timestamp),
                    pull_requests_json,
                },
            );
        }
    }
    if threads.is_empty() {
        return Ok((Vec::new(), claimed));
    }

    let mut events_by_thread: HashMap<String, Vec<Event>> = HashMap::new();
    let mut consulted_by_thread: HashSet<String> = HashSet::new();

    for (thread_id, header) in &threads {
        for (url, at) in
            linked_pull_requests(header.pull_requests_json.as_deref(), header.created_at)
        {
            if at >= start && at < end {
                events_by_thread
                    .entry(thread_id.clone())
                    .or_default()
                    .push(Event::new(at, EventKind::PullRequest(url)));
            }
        }
    }
    if table_exists(db, "projection_thread_pull_requests")? {
        let mut stmt = db.prepare(
            "SELECT thread_id, url, linked_at \
             FROM projection_thread_pull_requests \
             WHERE linked_at >= ?1 AND linked_at < ?2",
        )?;
        let rows = stmt.query_map(params![&wide_start, &wide_end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;
        for row in rows {
            let (thread_id, url, linked_at) = row?;
            if !threads.contains_key(&thread_id) {
                continue;
            }
            if let Some(at) = text::timestamp(&linked_at)
                && at >= start
                && at < end
            {
                for valid in text::pull_request_urls(&url) {
                    events_by_thread
                        .entry(thread_id.clone())
                        .or_default()
                        .push(Event::new(at, EventKind::PullRequest(valid)));
                }
            }
        }
    }

    if table_exists(db, "orchestration_v2_projection_messages")? {
        let mut stmt = db.prepare(
            "SELECT thread_id, role, created_at, updated_at, \
                    json_extract(payload_json, '$.text'), \
                    json_extract(payload_json, '$.createdBy'), \
                    json_extract(payload_json, '$.creationSource') \
             FROM orchestration_v2_projection_messages \
             WHERE created_at >= ?1 AND created_at < ?2 \
             ORDER BY created_at, message_id",
        )?;
        let rows = stmt.query_map(params![&wide_start, &wide_end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
            ))
        })?;
        for row in rows {
            let (thread_id, role, created_raw, updated_raw, raw_text, created_by, creation_source) =
                row?;
            if !threads.contains_key(&thread_id) {
                continue;
            }
            let Some(created_at) = text::timestamp(&created_raw) else {
                continue;
            };
            let updated_at = updated_raw.as_deref().and_then(text::timestamp);
            let body = raw_text.unwrap_or_default();
            if role == "user" {
                if created_at < start || created_at >= end {
                    continue;
                }
                let kind = if created_by.as_deref() == Some("agent") {
                    if creation_source.as_deref() == Some("schedule") {
                        let label = text::sanitized(&body, 80);
                        let label = if label.is_empty() {
                            "unnamed".to_string()
                        } else {
                            label
                        };
                        EventKind::Prompt(format!("Scheduled task: {label}"))
                    } else {
                        EventKind::Activity
                    }
                } else if let Some(prompt) = text::prompt(&body) {
                    EventKind::Prompt(prompt)
                } else {
                    EventKind::Activity
                };
                events_by_thread
                    .entry(thread_id)
                    .or_default()
                    .push(Event::new(created_at, kind));
            } else if role == "assistant" {
                let at = updated_at
                    .filter(|t| *t >= start && *t < end)
                    .unwrap_or(created_at);
                if at < start || at >= end {
                    continue;
                }
                let kind = text::reply(&body)
                    .map(EventKind::Reply)
                    .unwrap_or(EventKind::Activity);
                events_by_thread
                    .entry(thread_id)
                    .or_default()
                    .push(Event::new(at, kind));
            }
        }
    }

    if table_exists(db, "orchestration_v2_projection_turn_items")? {
        let mut stmt = db.prepare(
            "SELECT thread_id, type, updated_at, \
                    json_extract(payload_json, '$.startedAt'), \
                    json_extract(payload_json, '$.completedAt'), \
                    CASE type \
                        WHEN 'command_execution' THEN json_extract(payload_json, '$.input') \
                        ELSE NULL \
                    END, \
                    CASE type \
                        WHEN 'file_change' THEN json_extract(payload_json, '$.fileName') \
                        ELSE NULL \
                    END, \
                    CASE type \
                        WHEN 'file_change' THEN json_extract(payload_json, '$.changes') \
                        ELSE NULL \
                    END, \
                    CASE type \
                        WHEN 'dynamic_tool' THEN json_extract(payload_json, '$.toolName') \
                        ELSE NULL \
                    END, \
                    CASE type \
                        WHEN 'dynamic_tool' THEN json_extract(payload_json, '$.input') \
                        ELSE NULL \
                    END \
             FROM orchestration_v2_projection_turn_items \
             WHERE updated_at >= ?1 \
               AND COALESCE(json_extract(payload_json, '$.startedAt'), updated_at) < ?2 \
               AND type NOT IN ('user_message', 'assistant_message') \
             ORDER BY ordinal, turn_item_id",
        )?;
        let rows = stmt.query_map(params![&wide_start, &wide_end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, Option<String>>(8)?,
                row.get::<_, Option<String>>(9)?,
            ))
        })?;
        for row in rows {
            let (
                thread_id,
                item_type,
                updated_raw,
                started_raw,
                completed_raw,
                command_input,
                file_name,
                changes_json,
                tool_name,
                tool_input_json,
            ) = row?;
            let Some(header) = threads.get(&thread_id) else {
                continue;
            };
            let updated_at = text::timestamp(&updated_raw);
            let started_at = started_raw.as_deref().and_then(text::timestamp);
            let completed_at = completed_raw.as_deref().and_then(text::timestamp);
            let raw_at = if item_type == "file_change" {
                completed_at.or(started_at).or(updated_at)
            } else {
                started_at.or(completed_at).or(updated_at)
            };
            let Some(at) = raw_at.filter(|t| *t >= start && *t < end) else {
                continue;
            };
            let list = events_by_thread.entry(thread_id.clone()).or_default();
            match item_type.as_str() {
                "command_execution" => {
                    list.push(Event::new(at, EventKind::ToolCall));
                    if let Some(command) = command_input.filter(|c| !c.is_empty()) {
                        if text::reads_lokalbot_command(&command) {
                            consulted_by_thread.insert(thread_id);
                        }
                        for action in text::actions_in_command(&command) {
                            list.push(Event::new(at, EventKind::Action(action)));
                        }
                        for url in text::pull_request_urls(&command) {
                            list.push(Event::new(at, EventKind::PullRequest(url)));
                        }
                    }
                }
                "file_change" => {
                    list.push(Event::new(at, EventKind::ToolCall));
                    for path in file_change_paths(file_name.as_deref(), changes_json.as_deref()) {
                        let named = text::display_path(&path, header.working_directory.as_deref());
                        list.push(Event::new(at, EventKind::FileChange(named)));
                    }
                }
                "dynamic_tool" => {
                    list.push(Event::new(at, EventKind::ToolCall));
                    let name = tool_name.as_deref().unwrap_or("");
                    if text::reads_lokalbot_tool(name) {
                        consulted_by_thread.insert(thread_id);
                    }
                    let input_obj = tool_input_json
                        .as_deref()
                        .and_then(|raw| serde_json::from_str::<Value>(raw).ok());
                    let pr_title = input_obj
                        .as_ref()
                        .and_then(|o| o.get("title"))
                        .and_then(Value::as_str);
                    let pr_number = input_obj
                        .as_ref()
                        .and_then(|o| o.get("number"))
                        .and_then(Value::as_i64);
                    let pr_url = input_obj
                        .as_ref()
                        .and_then(|o| o.get("url"))
                        .and_then(Value::as_str);
                    let pr_urls: Vec<String> = input_obj
                        .as_ref()
                        .and_then(|o| o.get("urls"))
                        .and_then(Value::as_array)
                        .map(|arr| {
                            arr.iter()
                                .filter_map(Value::as_str)
                                .map(str::to_string)
                                .collect()
                        })
                        .unwrap_or_default();
                    for kind in
                        text::pull_request_events(name, pr_title, pr_number, pr_url, &pr_urls)
                    {
                        list.push(Event::new(at, kind));
                    }
                }
                "file_search" | "web_search" | "subagent" => {
                    list.push(Event::new(at, EventKind::ToolCall));
                }
                _ => {
                    list.push(Event::new(at, EventKind::Activity));
                }
            }
        }

        let mut check = db.prepare(
            "SELECT DISTINCT thread_id, type, \
                    CASE type \
                        WHEN 'command_execution' THEN json_extract(payload_json, '$.input') \
                        WHEN 'dynamic_tool' THEN json_extract(payload_json, '$.toolName') \
                        ELSE NULL \
                    END \
             FROM orchestration_v2_projection_turn_items \
             WHERE type IN ('command_execution', 'dynamic_tool') \
               AND payload_json LIKE '%lokalbot%'",
        )?;
        let rows = check.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })?;
        for row in rows {
            let (thread_id, item_type, value) = row?;
            if !threads.contains_key(&thread_id) || consulted_by_thread.contains(&thread_id) {
                continue;
            }
            if let Some(value) = value
                && ((item_type == "command_execution" && text::reads_lokalbot_command(&value))
                    || (item_type == "dynamic_tool" && text::reads_lokalbot_tool(&value)))
            {
                consulted_by_thread.insert(thread_id);
            }
        }
    }

    let mut transcripts = Vec::new();
    for (thread_id, header) in threads {
        let Some(raw_events) = events_by_thread.remove(&thread_id) else {
            continue;
        };
        if !raw_events.iter().any(|e| !e.is_annotation()) {
            continue;
        }
        transcripts.push(Transcript {
            agent: CodingAgentKind::T3Code,
            session_id: thread_id.clone(),
            title: header.title,
            working_directory: header.working_directory,
            branch: header.branch,
            consulted_lokalbot: consulted_by_thread.contains(&thread_id),
            events: compacting_activity(&raw_events),
        });
    }
    Ok((transcripts, claimed))
}

fn read_v1(
    db: &Connection,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    skipping: &HashSet<String>,
) -> rusqlite::Result<(Vec<Transcript>, HashSet<SessionKey>)> {
    let wide_start = iso_utc(start - Duration::hours(14));
    let wide_end = iso_utc(end + Duration::hours(14));

    let mut claimed: HashSet<SessionKey> = HashSet::new();
    if table_exists(db, "projection_thread_sessions")? {
        let mut stmt = db.prepare(
            "SELECT provider_name, provider_session_id, provider_thread_id \
             FROM projection_thread_sessions \
             WHERE updated_at >= ?1",
        )?;
        let rows = stmt.query_map(params![&wide_start], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })?;
        for row in rows {
            let (provider, session_id, provider_thread_id) = row?;
            let Some(agent) = provider.as_deref().and_then(native_agent_kind) else {
                continue;
            };
            for candidate in [session_id, provider_thread_id].into_iter().flatten() {
                if let Some(id) = non_empty(Some(candidate)) {
                    claimed.insert(SessionKey {
                        agent,
                        session_id: id,
                    });
                }
            }
        }
    }

    let has_projects = table_exists(db, "projection_projects")?;
    let threads_sql = if has_projects {
        "SELECT t.thread_id, t.title, t.branch, t.worktree_path, p.workspace_root \
         FROM projection_threads t \
         LEFT JOIN projection_projects p ON t.project_id = p.project_id \
         WHERE t.deleted_at IS NULL AND t.updated_at >= ?1 AND t.created_at < ?2"
    } else {
        "SELECT t.thread_id, t.title, t.branch, t.worktree_path, NULL \
         FROM projection_threads t \
         WHERE t.deleted_at IS NULL AND t.updated_at >= ?1 AND t.created_at < ?2"
    };

    let mut threads: HashMap<String, ThreadHeader> = HashMap::new();
    {
        let mut stmt = db.prepare(threads_sql)?;
        let rows = stmt.query_map(params![&wide_start, &wide_end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
            ))
        })?;
        for row in rows {
            let (id, raw_title, branch, worktree_path, workspace_root) = row?;
            if id.is_empty() || skipping.contains(&id) || is_subagent_thread(&id, None, None) {
                continue;
            }
            threads.insert(
                id,
                ThreadHeader {
                    title: raw_title.as_deref().and_then(text::title),
                    working_directory: non_empty(workspace_root)
                        .or_else(|| non_empty(worktree_path)),
                    branch: non_empty(branch).filter(|b| b != "HEAD"),
                    created_at: None,
                    pull_requests_json: None,
                },
            );
        }
    }
    if threads.is_empty() {
        return Ok((Vec::new(), claimed));
    }

    let mut events_by_thread: HashMap<String, Vec<Event>> = HashMap::new();
    if table_exists(db, "projection_thread_messages")? {
        let mut stmt = db.prepare(
            "SELECT thread_id, role, text, created_at, updated_at \
             FROM projection_thread_messages \
             WHERE created_at >= ?1 AND created_at < ?2 \
             ORDER BY created_at, message_id",
        )?;
        let rows = stmt.query_map(params![&wide_start, &wide_end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
            ))
        })?;
        for row in rows {
            let (thread_id, role, raw_text, created_raw, updated_raw) = row?;
            if !threads.contains_key(&thread_id) {
                continue;
            }
            let Some(created_at) = text::timestamp(&created_raw) else {
                continue;
            };
            let updated_at = updated_raw.as_deref().and_then(text::timestamp);
            let body = raw_text.unwrap_or_default();
            if role == "user" && created_at >= start && created_at < end {
                let kind = text::prompt(&body)
                    .map(EventKind::Prompt)
                    .unwrap_or(EventKind::Activity);
                events_by_thread
                    .entry(thread_id)
                    .or_default()
                    .push(Event::new(created_at, kind));
            } else if role == "assistant" {
                let at = updated_at
                    .filter(|t| *t >= start && *t < end)
                    .unwrap_or(created_at);
                if at >= start && at < end {
                    let kind = text::reply(&body)
                        .map(EventKind::Reply)
                        .unwrap_or(EventKind::Activity);
                    events_by_thread
                        .entry(thread_id)
                        .or_default()
                        .push(Event::new(at, kind));
                }
            }
        }
    }

    if table_exists(db, "projection_thread_pull_requests")? {
        let mut stmt = db.prepare(
            "SELECT thread_id, url, linked_at \
             FROM projection_thread_pull_requests \
             WHERE linked_at >= ?1 AND linked_at < ?2",
        )?;
        let rows = stmt.query_map(params![&wide_start, &wide_end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;
        for row in rows {
            let (thread_id, url, linked_at) = row?;
            if !threads.contains_key(&thread_id) {
                continue;
            }
            if let Some(at) = text::timestamp(&linked_at)
                && at >= start
                && at < end
            {
                for valid in text::pull_request_urls(&url) {
                    events_by_thread
                        .entry(thread_id.clone())
                        .or_default()
                        .push(Event::new(at, EventKind::PullRequest(valid)));
                }
            }
        }
    }

    let mut transcripts = Vec::new();
    for (thread_id, header) in threads {
        let Some(raw_events) = events_by_thread.remove(&thread_id) else {
            continue;
        };
        if !raw_events.iter().any(|e| !e.is_annotation()) {
            continue;
        }
        transcripts.push(Transcript {
            agent: CodingAgentKind::T3Code,
            session_id: thread_id,
            title: header.title,
            working_directory: header.working_directory,
            branch: header.branch,
            consulted_lokalbot: false,
            events: compacting_activity(&raw_events),
        });
    }
    Ok((transcripts, claimed))
}

fn database_metadata(path: &Path) -> Option<(SystemTime, u64)> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let mut modified = meta.modified().ok()?;
    let mut size = meta.len();
    let mut wal_os = path.as_os_str().to_os_string();
    wal_os.push("-wal");
    if let Ok(wal_meta) = std::fs::symlink_metadata(PathBuf::from(wal_os)) {
        if let Ok(wal_mod) = wal_meta.modified()
            && wal_mod > modified
        {
            modified = wal_mod;
        }
        size += wal_meta.len();
    }
    Some((modified, size))
}

fn open_read_only(path: &Path) -> rusqlite::Result<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    if let Ok(conn) = Connection::open_with_flags(path, flags) {
        let _ = conn.busy_timeout(StdDuration::from_secs(2));
        if conn
            .query_row("SELECT 1 FROM sqlite_master LIMIT 1", [], |_| Ok(()))
            .is_ok()
            || matches!(
                conn.query_row("SELECT 1 FROM sqlite_master LIMIT 1", [], |_| Ok(())),
                Err(rusqlite::Error::QueryReturnedNoRows)
            )
        {
            return Ok(conn);
        }
    }
    let raw = path.to_string_lossy();
    let stripped = raw.strip_prefix(r"\\?\").unwrap_or(&raw);
    let normalized = stripped
        .replace('\\', "/")
        .replace('%', "%25")
        .replace('?', "%3F")
        .replace('#', "%23");
    let uri = if normalized.starts_with('/') {
        format!("file:{normalized}?mode=ro&immutable=1")
    } else {
        format!("file:///{normalized}?mode=ro&immutable=1")
    };
    let conn = Connection::open_with_flags(
        uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let _ = conn.busy_timeout(StdDuration::from_secs(2));
    match conn.query_row("SELECT 1 FROM sqlite_master LIMIT 1", [], |_| Ok(())) {
        Ok(()) | Err(rusqlite::Error::QueryReturnedNoRows) => Ok(conn),
        Err(err) => Err(err),
    }
}

fn table_exists(db: &Connection, name: &str) -> rusqlite::Result<bool> {
    let mut stmt =
        db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1")?;
    stmt.exists(params![name])
}

fn is_subagent_thread(id: &str, parent_id: Option<&str>, relationship: Option<&str>) -> bool {
    if parent_id.is_some_and(|p| !p.is_empty()) || relationship == Some("subagent") {
        return true;
    }
    id.starts_with("thread:delegated-task:") || id.starts_with("thread:subagent:")
}

fn native_agent_kind(driver: &str) -> Option<CodingAgentKind> {
    match driver.to_lowercase().as_str() {
        "claudeagent" | "claude" | "claude-code" => Some(CodingAgentKind::ClaudeCode),
        "codex" => Some(CodingAgentKind::Codex),
        _ => None,
    }
}

fn linked_pull_requests(
    json: Option<&str>,
    fallback: Option<DateTime<Utc>>,
) -> Vec<(String, DateTime<Utc>)> {
    let Some(raw) = json else {
        return Vec::new();
    };
    let Ok(Value::Array(items)) = serde_json::from_str::<Value>(raw) else {
        return Vec::new();
    };
    let mut result = Vec::new();
    for item in items {
        let Some(raw_url) = item.get("url").and_then(Value::as_str) else {
            continue;
        };
        let Some(at) = item
            .get("linkedAt")
            .and_then(Value::as_str)
            .and_then(text::timestamp)
            .or(fallback)
        else {
            continue;
        };
        for url in text::pull_request_urls(raw_url) {
            result.push((url, at));
        }
    }
    result
}

fn file_change_paths(file_name: Option<&str>, changes_json: Option<&str>) -> Vec<String> {
    let mut paths = Vec::new();
    if let Some(raw) = changes_json
        && let Ok(Value::Array(items)) = serde_json::from_str::<Value>(raw)
    {
        for item in items {
            if let Some(path) = item.get("path").and_then(Value::as_str)
                && !path.is_empty()
                && !paths.iter().any(|p| p == path)
            {
                paths.push(path.to_string());
            }
        }
    }
    if paths.is_empty()
        && let Some(name) = file_name.filter(|s| !s.is_empty())
    {
        paths.push(name.to_string());
    }
    paths
}

fn non_empty(value: Option<String>) -> Option<String> {
    value
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn iso_utc(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Millis, true)
}
