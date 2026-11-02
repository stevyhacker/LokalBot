//! The request an agent left with `lokalbot-cli setup start`, shown to the person
//! in the agent setup window (`AgentSetupRequests.swift`). Allowing it turns on
//! the settings grant, plus whichever read access the person ticks; declining
//! leaves everything off. Each request is answered once, and the answer is written
//! back to `control/setup-answer.json` for the CLI to read.

use chrono::Utc;
use gpui_kit::Context;
use lokalbot_core::access;
use lokalbot_core::control::protocol::RequestState;
use lokalbot_core::control::setup::{self, Grant, SetupAnswer, SetupRequest};
use lokalbot_core::paths::LibraryPaths;

use super::ControlHost;

/// The boxes the person ticked.
#[derive(Clone, Copy, Debug, Default)]
pub struct Ticked {
    pub meeting_library: bool,
    pub screen_memory: bool,
    pub files: bool,
}

/// Turns on what the person ticked among what the request asked for, and says what
/// took. A box counts only if the request asked for it, and asking grants nothing.
/// `file_folders` is what Files reads, or `None` while Files is off.
fn grant_read_access(
    paths: &LibraryPaths,
    requested: &[Grant],
    ticked: Ticked,
    file_folders: Option<&[String]>,
) -> Vec<Grant> {
    let mut grants = vec![Grant::Settings];
    if ticked.meeting_library
        && requested.contains(&Grant::MeetingLibrary)
        && access::set_meetings_access(paths, true).is_ok()
    {
        grants.push(Grant::MeetingLibrary);
    }
    if ticked.screen_memory
        && requested.contains(&Grant::ScreenMemory)
        && access::set_screen_access(paths, Some(access::ScreenScope::RecentWeek)).is_ok()
    {
        grants.push(Grant::ScreenMemory);
    }
    if ticked.files && requested.contains(&Grant::Files) {
        match lokalbot_core::files::access::set_enabled(paths, true) {
            Ok(()) => {
                // A list that can't be written doesn't undo the grant: the CLI
                // then says Files has no folder yet.
                if let Err(err) = lokalbot_core::files::access::refresh(paths, file_folders) {
                    log::warn!("could not update which folders agents can search: {err:#}");
                }
                grants.push(Grant::Files);
            }
            Err(err) => log::warn!("could not turn on file access: {err:#}"),
        }
    }
    grants
}

impl ControlHost {
    /// Picks up a request left by the CLI. An unreadable or expired request is
    /// answered and removed. A new one opens its window.
    pub(super) fn check_setup(&mut self, cx: &mut Context<Self>) {
        let control = self.paths.control_dir();
        let path = setup::request_path(&control);
        if !path.exists() {
            if self.setup_pending.take().is_some() {
                cx.notify();
            }
            return;
        }
        let Some(request) = setup::read::<SetupRequest>(&path) else {
            let _ = std::fs::remove_file(&path);
            self.setup_pending = None;
            cx.notify();
            return;
        };
        if !request.is_live(Utc::now()) {
            self.answer_setup(&request, RequestState::Expired, Vec::new(), cx);
            return;
        }
        if self.setup_pending.as_ref().map(|r| &r.nonce) != Some(&request.nonce) {
            self.setup_pending = Some(request);
            cx.notify();
            cx.defer(crate::windows::agent_setup::open);
        }
    }

    /// The person allowed the request, with the read access they ticked.
    pub fn allow_setup(&mut self, ticked: Ticked, cx: &mut Context<Self>) {
        let Some(request) = self.setup_pending.clone() else {
            return;
        };
        if !request.is_live(Utc::now()) {
            self.answer_setup(&request, RequestState::Expired, Vec::new(), cx);
            return;
        }
        self.set_enabled(true, cx);
        if !self.enabled {
            // The marker could not be written; the error is already shown.
            self.answer_setup(&request, RequestState::Denied, Vec::new(), cx);
            return;
        }
        let grants = {
            let settings = &self.data.read(cx).settings;
            let folders = settings
                .file_search_enabled
                .then_some(settings.file_search_folders.as_slice());
            grant_read_access(&self.paths, &request.grants, ticked, folders)
        };
        self.access_generation += 1;
        self.changes
            .record_setup(&grants, &request.requester, Utc::now());
        self.answer_setup(&request, RequestState::Approved, grants, cx);
        self.after_setup_answer(cx);
    }

    /// A new install still needs its setup, so declining leads to onboarding.
    pub fn deny_setup(&mut self, cx: &mut Context<Self>) {
        let Some(request) = self.setup_pending.clone() else {
            return;
        };
        self.answer_setup(&request, RequestState::Denied, Vec::new(), cx);
        if !self.data.read(cx).settings.onboarding_completed {
            cx.defer(crate::windows::onboarding::open);
        }
        self.after_setup_answer(cx);
    }

    /// A setup launch has no main window; without a tray icon nothing else would
    /// lead back to LokalBot.
    fn after_setup_answer(&self, cx: &mut Context<Self>) {
        let tray = crate::desktop::desktop(cx).is_some_and(|d| d.has_tray());
        let main_window = crate::desktop::desktop(cx).is_some_and(|d| d.main_window_is_set());
        if !tray && !main_window {
            cx.defer(crate::desktop::show_main_window);
        }
    }

    fn answer_setup(
        &mut self,
        request: &SetupRequest,
        state: RequestState,
        grants: Vec<Grant>,
        cx: &mut Context<Self>,
    ) {
        let control = self.paths.control_dir();
        let answer = SetupAnswer {
            answered_at: Utc::now(),
            grants,
            nonce: request.nonce.clone(),
            state,
        };
        if let Err(err) = setup::write(&answer, &setup::answer_path(&control)) {
            log::warn!("could not answer the agent's setup request: {err}");
        }
        // Only remove the request this answers; the CLI may have left a newer one.
        let path = setup::request_path(&control);
        if setup::read::<SetupRequest>(&path).is_some_and(|r| r.nonce == request.nonce) {
            let _ = std::fs::remove_file(path);
        }
        if self.setup_pending.as_ref().map(|r| &r.nonce) == Some(&request.nonce) {
            self.setup_pending = None;
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::files::access as files_access;

    fn paths() -> (tempfile::TempDir, LibraryPaths) {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        (dir, paths)
    }

    const ALL: [Grant; 4] = [
        Grant::Settings,
        Grant::MeetingLibrary,
        Grant::ScreenMemory,
        Grant::Files,
    ];

    #[test]
    fn nothing_is_read_unless_the_person_ticks_it() {
        let (_dir, paths) = paths();
        let grants = grant_read_access(&paths, &ALL, Ticked::default(), None);
        assert_eq!(grants, [Grant::Settings]);
        assert!(!access::meetings_access_enabled(&paths));
        assert!(access::screen_access_scope(&paths).is_none());
        assert!(!files_access::is_enabled(&paths));
    }

    #[test]
    fn a_box_the_request_did_not_ask_for_counts_for_nothing() {
        let (_dir, paths) = paths();
        let ticked = Ticked {
            meeting_library: true,
            screen_memory: true,
            files: true,
        };
        let folders = vec!["/home/me/Documents".to_string()];
        let grants = grant_read_access(&paths, &[Grant::Settings], ticked, Some(&folders));
        assert_eq!(grants, [Grant::Settings]);
        assert!(!files_access::is_enabled(&paths));
        assert!(files_access::read_projection(&paths).is_none());
    }

    #[test]
    fn allowing_files_writes_its_grant_and_folder_list_only() {
        let (_dir, paths) = paths();
        let ticked = Ticked {
            files: true,
            ..Default::default()
        };
        let folders = vec!["/home/me/Documents".to_string()];
        let grants = grant_read_access(
            &paths,
            &[Grant::Settings, Grant::Files],
            ticked,
            Some(&folders),
        );
        assert_eq!(grants, [Grant::Settings, Grant::Files]);
        assert!(files_access::is_enabled(&paths));
        assert_eq!(
            files_access::read_projection(&paths).unwrap().folders,
            folders
        );
        assert!(!access::meetings_access_enabled(&paths));
        assert!(access::screen_access_scope(&paths).is_none());
    }

    #[test]
    fn files_can_be_allowed_before_it_has_folders() {
        let (_dir, paths) = paths();
        let ticked = Ticked {
            files: true,
            ..Default::default()
        };
        let grants = grant_read_access(&paths, &[Grant::Settings, Grant::Files], ticked, None);
        assert_eq!(grants, [Grant::Settings, Grant::Files]);
        assert!(files_access::is_enabled(&paths));
        assert!(files_access::read_projection(&paths).is_none());
    }
}
