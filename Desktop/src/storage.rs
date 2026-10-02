use crate::domain::*;
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest as _, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

pub struct Library {
    pub root: PathBuf,
    connection: Connection,
}
pub struct GuiLock(fs::File);
impl Drop for GuiLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.0);
    }
}

pub fn default_root() -> Result<PathBuf> {
    if let Some(root) = std::env::var_os("LOKALBOT_STORAGE_ROOT") {
        return Ok(PathBuf::from(root));
    }
    Ok(
        directories::ProjectDirs::from("me", "dotenv", "LokalBotDesktop")
            .context("No user data directory")?
            .data_local_dir()
            .to_owned(),
    )
}
pub fn valid_id(id: &str) -> Result<()> {
    ensure!(
        !id.is_empty()
            && id.len() <= 128
            && id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "-_:".contains(c)),
        "Invalid record ID"
    );
    Ok(())
}
pub fn private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
pub fn atomic_write(path: &Path, data: &[u8]) -> Result<()> {
    let parent = path.parent().context("Missing parent directory")?;
    if !parent.exists() {
        private_directory(parent)?;
    }
    let mut tmp = tempfile::NamedTempFile::new_in(parent)?;
    use std::io::Write;
    tmp.write_all(data)?;
    tmp.as_file().sync_all()?;
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}
pub fn fingerprint<T: serde::Serialize>(data: &T) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(data)?)))
}

impl Library {
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref().to_path_buf();
        private_directory(&root)?;
        let connection = Connection::open(root.join("desktop.sqlite"))?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;",
        )?;
        let version: i64 = connection.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        ensure!(
            version <= 2,
            "This library was created by a newer app; refusing to downgrade it"
        );
        connection.execute_batch("BEGIN;
            CREATE TABLE IF NOT EXISTS meetings(id TEXT PRIMARY KEY,title TEXT NOT NULL,started_at INTEGER NOT NULL,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS evidence(id TEXT PRIMARY KEY,meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,title TEXT NOT NULL,kind TEXT NOT NULL,start REAL NOT NULL,text TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS evidence_fts USING fts5(id UNINDEXED,title,text,tokenize='unicode61');
            CREATE TRIGGER IF NOT EXISTS evidence_insert AFTER INSERT ON evidence BEGIN INSERT INTO evidence_fts(id,title,text) VALUES(new.id,new.title,new.text); END;
            CREATE TRIGGER IF NOT EXISTS evidence_delete AFTER DELETE ON evidence BEGIN DELETE FROM evidence_fts WHERE id=old.id; END;
            CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY CHECK(id=1),data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY,created_at INTEGER NOT NULL,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS activity(id TEXT PRIMARY KEY,start INTEGER NOT NULL,end INTEGER NOT NULL,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS moments(id TEXT PRIMARY KEY,created_at INTEGER NOT NULL,saved INTEGER NOT NULL,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS digests(day TEXT PRIMARY KEY,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,status TEXT NOT NULL,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS generations(id INTEGER PRIMARY KEY,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS embeddings(id TEXT PRIMARY KEY REFERENCES evidence(id) ON DELETE CASCADE,version TEXT NOT NULL,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS agent_tasks(id TEXT PRIMARY KEY,data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS summary_parts(meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,version TEXT NOT NULL,part INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(meeting_id,version,part));
            PRAGMA user_version=2; COMMIT;")?;
        Ok(Self { root, connection })
    }
    // Hold the SQLite writer lock across permission/source validation and persistence.
    // The save methods use savepoints so they can participate in this transaction.
    fn begin_guarded_write(&self, revision: u64) -> Result<()> {
        self.connection.execute_batch("BEGIN IMMEDIATE")?;
        let result = self.settings().and_then(|s| {
            ensure!(
                s.revision == revision,
                "Permissions changed; the result was discarded"
            );
            Ok(())
        });
        if result.is_err() {
            let _ = self.connection.execute_batch("ROLLBACK");
        }
        result
    }
    fn finish_guarded_write<T>(&self, result: Result<T>) -> Result<T> {
        match result {
            Ok(value) => {
                if let Err(error) = self.connection.execute_batch("COMMIT") {
                    let _ = self.connection.execute_batch("ROLLBACK");
                    return Err(error.into());
                }
                Ok(value)
            }
            Err(error) => {
                let _ = self.connection.execute_batch("ROLLBACK");
                Err(error)
            }
        }
    }
    pub fn guarded_write<T>(
        &self,
        revision: u64,
        operation: impl FnOnce(&Self) -> Result<T>,
    ) -> Result<T> {
        self.begin_guarded_write(revision)?;
        let result = operation(self);
        self.finish_guarded_write(result)
    }
    pub fn guarded_write_mut<T>(
        &mut self,
        revision: u64,
        operation: impl FnOnce(&mut Self) -> Result<T>,
    ) -> Result<T> {
        self.begin_guarded_write(revision)?;
        let result = operation(self);
        self.finish_guarded_write(result)
    }
    pub fn gui_lock(&self) -> Result<GuiLock> {
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(self.root.join(".gui.lock"))?;
        fs2::FileExt::try_lock_exclusive(&file)
            .context("Another desktop app is already using this library")?;
        Ok(GuiLock(file))
    }
    pub fn settings(&self) -> Result<Settings> {
        self.connection
            .query_row("SELECT data FROM settings WHERE id=1", [], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
            .map(|s| serde_json::from_str(&s).map_err(Into::into))
            .unwrap_or_else(|| Ok(Settings::default()))
    }
    pub fn save_settings(&mut self, settings: &mut Settings) -> Result<()> {
        ensure!(
            (1..=3650).contains(&settings.retention_days),
            "Retention must be between 1 and 3650 days"
        );
        ensure!(
            settings
                .screen_access_days
                .is_none_or(|days| (1..=3650).contains(&days)),
            "Screen access scope must be 1–3650 days"
        );
        ensure!(
            settings.digest_hour.is_none_or(|h| h < 24),
            "Invalid digest hour"
        );
        let tx = self.connection.savepoint()?;
        let current: Option<String> = tx
            .query_row("SELECT data FROM settings WHERE id=1", [], |r| r.get(0))
            .optional()?;
        settings.revision = current
            .as_deref()
            .map(serde_json::from_str::<Settings>)
            .transpose()?
            .map_or(1, |s| s.revision + 1);
        tx.execute("INSERT INTO settings(id,data) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET data=excluded.data",[serde_json::to_string(settings)?])?;
        tx.commit()?;
        Ok(())
    }
    pub fn meeting(&self, id: &str) -> Result<Meeting> {
        valid_id(id)?;
        let data: String = self
            .connection
            .query_row("SELECT data FROM meetings WHERE id=?1", [id], |r| r.get(0))
            .context("Meeting not found")?;
        Ok(serde_json::from_str(&data)?)
    }
    pub fn meetings(&self) -> Result<Vec<Meeting>> {
        let mut statement = self
            .connection
            .prepare("SELECT data FROM meetings ORDER BY started_at DESC,id")?;
        let rows = statement.query_map([], |r| r.get::<_, String>(0))?;
        rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
    }
    pub fn save_meeting(&mut self, meeting: &Meeting) -> Result<()> {
        valid_id(&meeting.id)?;
        ensure!(
            !meeting.title.trim().is_empty() && meeting.title.len() <= 500,
            "Meeting title is missing or too long"
        );
        ensure!(
            meeting.duration.is_finite() && meeting.duration >= 0.,
            "Invalid duration"
        );
        let mut ids = std::collections::HashSet::new();
        for s in &meeting.segments {
            valid_id(&s.id)?;
            ensure!(ids.insert(&s.id), "Duplicate segment ID");
            ensure!(
                s.start.is_finite() && s.end.is_finite() && s.start >= 0. && s.end >= s.start,
                "Invalid segment timestamps"
            );
        }
        let tx = self.connection.savepoint()?;
        tx.execute("INSERT INTO meetings(id,title,started_at,data) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET title=excluded.title,started_at=excluded.started_at,data=excluded.data",params![meeting.id,meeting.title,meeting.started_at,serde_json::to_string(meeting)?])?;
        tx.execute("DELETE FROM evidence WHERE meeting_id=?1", [&meeting.id])?;
        for s in &meeting.segments {
            tx.execute(
                "INSERT INTO evidence VALUES(?1,?2,?3,'transcript',?4,?5)",
                params![
                    s.id,
                    meeting.id,
                    meeting.title,
                    s.start,
                    format!("{}: {}", s.speaker, s.text)
                ],
            )?;
        }
        for (suffix, kind, text) in [
            ("notes", "notes", meeting.notes.clone()),
            (
                "summary",
                "summary",
                meeting
                    .summary
                    .as_ref()
                    .map(|s| s.overview.clone())
                    .unwrap_or_default(),
            ),
        ] {
            if !text.is_empty() {
                tx.execute(
                    "INSERT INTO evidence VALUES(?1,?2,?3,?4,0,?5)",
                    params![
                        format!("{}-{suffix}", meeting.id),
                        meeting.id,
                        meeting.title,
                        kind,
                        text
                    ],
                )?;
            }
        }
        if let Some(summary) = &meeting.summary {
            for a in &summary.actions {
                valid_id(&a.id)?;
                tx.execute(
                    "INSERT INTO evidence VALUES(?1,?2,?3,'action',0,?4)",
                    params![
                        a.id,
                        meeting.id,
                        meeting.title,
                        format!(
                            "{} · {} · {} · {}",
                            a.text,
                            a.owner,
                            a.due,
                            if a.done { "done" } else { "open" }
                        )
                    ],
                )?;
            }
        }
        // Generated journals must never outlive a correction or source deletion.
        tx.execute("DELETE FROM digests", [])?;
        tx.commit()?;
        Ok(())
    }
    pub fn delete_meeting(&mut self, id: &str) -> Result<()> {
        valid_id(id)?;
        let tx = self.connection.savepoint()?;
        tx.execute("DELETE FROM meetings WHERE id=?1", [id])?;
        tx.execute("DELETE FROM digests", [])?;
        tx.commit()?;
        let path = self.root.join("meetings").join(id);
        if path.exists() {
            fs::remove_dir_all(path)
                .context("Meeting removed from the index, but audio cleanup failed")?;
        }
        Ok(())
    }
    pub fn toggle_action(&mut self, meeting_id: &str, action_id: &str) -> Result<()> {
        let mut m = self.meeting(meeting_id)?;
        let a = m
            .summary
            .as_mut()
            .context("No summary")?
            .actions
            .iter_mut()
            .find(|a| a.id == action_id)
            .context("Action not found")?;
        a.done = !a.done;
        a.corrected = true;
        self.save_meeting(&m)
    }
    pub fn correct_action(
        &mut self,
        meeting_id: &str,
        action_id: &str,
        text: String,
        owner: String,
        due: String,
    ) -> Result<()> {
        ensure!(!text.trim().is_empty(), "Action text is empty");
        let mut m = self.meeting(meeting_id)?;
        let a = m
            .summary
            .as_mut()
            .context("No summary")?
            .actions
            .iter_mut()
            .find(|a| a.id == action_id)
            .context("Action not found")?;
        a.text = text;
        a.owner = owner;
        a.due = due;
        a.corrected = true;
        self.save_meeting(&m)
    }
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<Evidence>> {
        let words: Vec<_> = query
            .split(|c: char| !c.is_alphanumeric())
            .filter(|s| s.len() > 1)
            .take(16)
            .map(|s| format!("\"{s}\"*"))
            .collect();
        if words.is_empty() {
            return Ok(vec![]);
        }
        let expression = words.join(" OR ");
        let mut stmt=self.connection.prepare("SELECT e.id,e.meeting_id,e.title,e.kind,e.start,e.text FROM evidence_fts f JOIN evidence e ON e.id=f.id WHERE evidence_fts MATCH ?1 ORDER BY bm25(evidence_fts) LIMIT ?2")?;
        Ok(stmt
            .query_map(params![expression, limit.min(100) as i64], |r| {
                Ok(Evidence {
                    id: r.get(0)?,
                    meeting_id: r.get(1)?,
                    title: r.get(2)?,
                    kind: r.get(3)?,
                    start: r.get(4)?,
                    text: r.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?)
    }
    pub fn evidence(&self, id: &str) -> Result<Evidence> {
        Ok(self.connection.query_row(
            "SELECT id,meeting_id,title,kind,start,text FROM evidence WHERE id=?1",
            [id],
            |r| {
                Ok(Evidence {
                    id: r.get(0)?,
                    meeting_id: r.get(1)?,
                    title: r.get(2)?,
                    kind: r.get(3)?,
                    start: r.get(4)?,
                    text: r.get(5)?,
                })
            },
        )?)
    }
    pub fn save_conversation(&self, c: &Conversation) -> Result<()> {
        self.connection.execute(
            "INSERT INTO conversations VALUES(?1,?2,?3)",
            params![c.id, c.created_at, serde_json::to_string(c)?],
        )?;
        Ok(())
    }
    pub fn conversations(&self) -> Result<Vec<Conversation>> {
        self.json_rows("SELECT data FROM conversations ORDER BY created_at DESC LIMIT 100")
    }
    pub fn clear_conversations(&self) -> Result<()> {
        self.connection.execute("DELETE FROM conversations", [])?;
        Ok(())
    }
    fn json_rows<T: serde::de::DeserializeOwned>(&self, sql: &str) -> Result<Vec<T>> {
        let mut s = self.connection.prepare(sql)?;
        s.query_map([], |r| r.get::<_, String>(0))?
            .map(|row| Ok(serde_json::from_str(&row?)?))
            .collect()
    }
    pub fn save_activity(&self, a: &Activity) -> Result<()> {
        valid_id(&a.id)?;
        self.connection.execute(
            "INSERT OR REPLACE INTO activity VALUES(?1,?2,?3,?4)",
            params![a.id, a.start, a.end, serde_json::to_string(a)?],
        )?;
        Ok(())
    }
    pub fn activity(&self) -> Result<Vec<Activity>> {
        self.json_rows("SELECT data FROM activity ORDER BY start DESC LIMIT 2000")
    }
    pub fn save_moment(&mut self, m: &Moment) -> Result<()> {
        valid_id(&m.id)?;
        let tx = self.connection.savepoint()?;
        tx.execute(
            "INSERT OR REPLACE INTO moments VALUES(?1,?2,?3,?4)",
            params![
                m.id,
                m.created_at,
                m.saved as i64,
                serde_json::to_string(m)?
            ],
        )?;
        tx.execute("DELETE FROM evidence WHERE id=?1", [&m.id])?;
        tx.execute(
            "INSERT INTO evidence VALUES(?1,NULL,?2,'screen',0,?3)",
            params![m.id, m.title, m.text],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub fn moments(&self) -> Result<Vec<Moment>> {
        self.json_rows("SELECT data FROM moments ORDER BY created_at DESC LIMIT 1000")
    }
    pub fn delete_moment(&mut self, id: &str) -> Result<()> {
        valid_id(id)?;
        let tx = self.connection.savepoint()?;
        tx.execute("DELETE FROM evidence WHERE id=?1", [id])?;
        tx.execute("DELETE FROM moments WHERE id=?1", [id])?;
        tx.execute("DELETE FROM digests", [])?;
        tx.commit()?;
        let pixels = self.root.join("pixels").join(format!("{id}.enc"));
        if pixels.exists() {
            fs::remove_file(pixels)?;
        }
        Ok(())
    }
    pub fn expire(&mut self, at: i64) -> Result<usize> {
        let settings = self.settings()?;
        let cutoff = at - i64::from(settings.retention_days) * 86400;
        let expired = self
            .moments()?
            .into_iter()
            .filter(|m| !m.saved && m.created_at < cutoff)
            .collect::<Vec<_>>();
        let count = expired.len();
        for m in expired {
            self.delete_moment(&m.id)?;
        }
        let mut changed = false;
        for mut a in self.activity()? {
            if a.end < cutoff && !a.title.is_empty() {
                a.title.clear();
                self.save_activity(&a)?;
                changed = true;
            }
        }
        if changed {
            self.connection.execute("DELETE FROM digests", [])?;
        }
        Ok(count)
    }
    pub fn save_digest(&self, d: &Digest) -> Result<()> {
        self.connection.execute(
            "INSERT OR REPLACE INTO digests VALUES(?1,?2)",
            params![d.day, serde_json::to_string(d)?],
        )?;
        Ok(())
    }
    pub fn digest(&self, day: &str) -> Result<Option<Digest>> {
        let s: Option<String> = self
            .connection
            .query_row("SELECT data FROM digests WHERE day=?1", [day], |r| r.get(0))
            .optional()?;
        s.map(|s| Ok(serde_json::from_str(&s)?)).transpose()
    }
    pub fn save_job(&self, job: &Job) -> Result<()> {
        self.connection.execute(
            "INSERT OR REPLACE INTO jobs VALUES(?1,?2,?3)",
            params![job.id, job.status, serde_json::to_string(job)?],
        )?;
        Ok(())
    }
    pub fn jobs(&self) -> Result<Vec<Job>> {
        self.json_rows("SELECT data FROM jobs ORDER BY rowid DESC LIMIT 100")
    }
    pub fn recover_jobs(&self) -> Result<usize> {
        let mut count = 0;
        for mut job in self.jobs()? {
            if job.status == "running" {
                job.status = "interrupted".into();
                job.error=Some("The app stopped before this job finished. Retry explicitly; recording was not restarted.".into());
                job.updated_at = now();
                self.save_job(&job)?;
                count += 1;
            }
        }
        Ok(count)
    }
    pub fn summary_part(&self, id: &str, version: &str, part: usize) -> Result<Option<Summary>> {
        let data: Option<String> = self
            .connection
            .query_row(
                "SELECT data FROM summary_parts WHERE meeting_id=?1 AND version=?2 AND part=?3",
                params![id, version, part as i64],
                |row| row.get(0),
            )
            .optional()?;
        data.map(|s| serde_json::from_str(&s).map_err(Into::into))
            .transpose()
    }
    pub fn save_summary_part(
        &self,
        id: &str,
        version: &str,
        part: usize,
        summary: &Summary,
    ) -> Result<()> {
        self.connection.execute(
            "DELETE FROM summary_parts WHERE meeting_id=?1 AND version<>?2",
            params![id, version],
        )?;
        self.connection.execute(
            "INSERT OR REPLACE INTO summary_parts VALUES(?1,?2,?3,?4)",
            params![id, version, part as i64, serde_json::to_string(summary)?],
        )?;
        Ok(())
    }
    pub fn clear_summary_parts(&self, id: &str) -> Result<()> {
        self.connection
            .execute("DELETE FROM summary_parts WHERE meeting_id=?1", [id])?;
        Ok(())
    }
    pub fn save_generation(&self, g: &Generation) -> Result<()> {
        self.connection.execute(
            "INSERT INTO generations(data) VALUES(?1)",
            [serde_json::to_string(g)?],
        )?;
        Ok(())
    }
    pub fn generations(&self) -> Result<Vec<Generation>> {
        self.json_rows("SELECT data FROM generations ORDER BY id DESC LIMIT 100")
    }
    pub fn export_meeting(&self, id: &str, path: &Path) -> Result<()> {
        atomic_write(path, self.meeting(id)?.markdown().as_bytes())
    }
    pub fn external_meetings(&self) -> Result<Vec<Meeting>> {
        ensure!(
            self.settings()?.meeting_access,
            "Meeting-library access is disabled"
        );
        self.meetings()
    }
    pub fn external_moments(&self, at: i64) -> Result<Vec<Moment>> {
        let settings = self.settings()?;
        ensure!(settings.screen_access, "Screen-memory access is disabled");
        let cutoff = settings
            .screen_access_days
            .map(|days| at - i64::from(days.max(1)) * 86400)
            .unwrap_or(i64::MIN);
        Ok(self
            .moments()?
            .into_iter()
            .filter(|m| m.created_at >= cutoff)
            .map(|mut m| {
                m.pixels = None;
                m
            })
            .collect())
    }
    pub fn save_agent_task<T: serde::Serialize>(&self, id: &str, task: &T) -> Result<()> {
        valid_id(id)?;
        self.connection.execute(
            "INSERT OR REPLACE INTO agent_tasks VALUES(?1,?2)",
            params![id, serde_json::to_string(task)?],
        )?;
        Ok(())
    }
    pub fn agent_tasks<T: serde::de::DeserializeOwned>(&self) -> Result<Vec<T>> {
        self.json_rows("SELECT data FROM agent_tasks ORDER BY rowid DESC LIMIT 100")
    }
    pub fn clear_agent_history(&self) -> Result<()> {
        self.connection.execute("DELETE FROM agent_tasks", [])?;
        Ok(())
    }
    pub fn save_embedding(&self, id: &str, version: &str, vector: &[f32]) -> Result<()> {
        ensure!(
            !vector.is_empty() && vector.iter().all(|n| n.is_finite()),
            "Invalid embedding"
        );
        self.connection.execute(
            "INSERT OR REPLACE INTO embeddings VALUES(?1,?2,?3)",
            params![id, version, serde_json::to_string(vector)?],
        )?;
        Ok(())
    }
    pub fn semantic_search(
        &self,
        vector: &[f32],
        version: &str,
        limit: usize,
    ) -> Result<Vec<Evidence>> {
        let mut stmt = self
            .connection
            .prepare("SELECT id,data FROM embeddings WHERE version=?1")?;
        let mut scored = vec![];
        for row in stmt.query_map([version], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })? {
            let (id, data) = row?;
            let stored: Vec<f32> = serde_json::from_str(&data)?;
            if stored.len() != vector.len() {
                continue;
            }
            let dot: f32 = stored.iter().zip(vector).map(|(a, b)| a * b).sum();
            let length = stored.iter().map(|x| x * x).sum::<f32>().sqrt()
                * vector.iter().map(|x| x * x).sum::<f32>().sqrt();
            if length > 0. {
                scored.push((dot / length, id));
            }
        }
        scored.sort_by(|a, b| b.0.total_cmp(&a.0));
        scored
            .into_iter()
            .take(limit.min(100))
            .map(|(_, id)| self.evidence(&id))
            .collect()
    }
}
