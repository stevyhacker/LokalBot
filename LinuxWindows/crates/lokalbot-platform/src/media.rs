//! Pausing what is playing while dictation listens, then resuming exactly that
//! (`MediaPlaybackController.swift`). Linux uses MPRIS over the session bus,
//! Windows the System Media Transport Controls. Every call is bounded, so a
//! player that doesn't answer can never hold up push-to-talk.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use parking_lot::Mutex;

/// How long the microphone waits for players to answer.
const PAUSE_DEADLINE: Duration = Duration::from_millis(1500);

/// Calls and conference pages are never paused, whatever the desktop reports
/// about them (`pauseHTMLMediaJavaScript`).
const CONFERENCE_HOSTS: &[&str] = &[
    "meet.google.com",
    "teams.microsoft.com",
    "teams.live.com",
    "zoom.us",
    "webex.com",
    "app.slack.com",
    "discord.com",
];

/// Conference apps that can publish a media session of their own.
const CONFERENCE_PLAYERS: &[&str] = &["teams", "zoom", "webex", "slack", "discord"];

/// Browsers publish one player per page. A page with no known length is a live
/// stream or a call, which pausing would lose (`pauseHTMLMediaJavaScript`).
const BROWSER_PLAYERS: &[&str] = &[
    "chrome",
    "chromium",
    "firefox",
    "edge",
    "brave",
    "vivaldi",
    "opera",
    "librewolf",
    "zen",
    "arc",
];

/// One media session the desktop knows about.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Player {
    /// The MPRIS bus name, or Windows' app id for the session.
    pub id: String,
    pub playing: bool,
    pub paused: bool,
    pub can_pause: bool,
    /// The page or file it is playing, when it says.
    pub url: Option<String>,
    /// Whether it reports a finite length.
    pub has_length: bool,
}

pub(crate) trait Players {
    fn list(&mut self) -> Vec<Player>;
    fn pause(&mut self, id: &str) -> bool;
    fn play(&mut self, id: &str) -> bool;
}

/// Whether dictation may pause this player.
fn may_pause(player: &Player) -> bool {
    if !player.playing || !player.can_pause {
        return false;
    }
    let id = player.id.to_lowercase();
    if CONFERENCE_PLAYERS.iter().any(|name| id.contains(name)) {
        return false;
    }
    if let Some(host) = player.url.as_deref().and_then(url_host)
        && CONFERENCE_HOSTS
            .iter()
            .any(|domain| host == *domain || host.ends_with(&format!(".{domain}")))
    {
        return false;
    }
    let browser = BROWSER_PLAYERS.iter().any(|name| id.contains(name));
    !browser || player.has_length
}

fn url_host(url: &str) -> Option<String> {
    url::Url::parse(url)
        .ok()?
        .host_str()
        .map(|host| host.to_lowercase())
}

/// What one dictation paused. Dropping it resumes nothing.
#[derive(Clone, Debug, Default)]
pub struct PausedMedia {
    players: Arc<Mutex<Vec<String>>>,
    /// Stops a pause still going through players past its deadline.
    stop: Arc<AtomicBool>,
}

impl PausedMedia {
    pub fn is_empty(&self) -> bool {
        self.players.lock().is_empty()
    }

    fn take(&self) -> Vec<String> {
        std::mem::take(&mut *self.players.lock())
    }
}

/// Pauses what is playing. Returns within [`PAUSE_DEADLINE`], and a player
/// that answers later still counts as paused by this dictation.
pub fn pause_playing() -> PausedMedia {
    let paused = PausedMedia::default();
    let (done, finished) = crossbeam_channel::bounded(1);
    let worker = paused.clone();
    let spawned = std::thread::Builder::new()
        .name("lokalbot-media-pause".into())
        .spawn(move || {
            with_players(|players| pause_with(players, &worker));
            let _ = done.send(());
        });
    if let Err(err) = spawned {
        log::debug!("media was not paused: {err}");
        return paused;
    }
    if finished.recv_timeout(PAUSE_DEADLINE).is_err() {
        paused.stop.store(true, Ordering::SeqCst);
    }
    paused
}

/// Resumes what [`pause_playing`] paused, unless the person changed it since.
pub fn resume(paused: PausedMedia) {
    paused.stop.store(true, Ordering::SeqCst);
    if paused.is_empty() {
        return;
    }
    with_players(|players| resume_with(players, &paused));
}

fn pause_with(players: &mut dyn Players, paused: &PausedMedia) {
    for player in players.list().iter().filter(|p| may_pause(p)) {
        if paused.stop.load(Ordering::SeqCst) {
            return;
        }
        if players.pause(&player.id) {
            log::info!("media paused for dictation: {}", player.id);
            paused.players.lock().push(player.id.clone());
        }
    }
}

fn resume_with(players: &mut dyn Players, paused: &PausedMedia) {
    let ours = paused.take();
    for player in players.list() {
        if player.paused && ours.contains(&player.id) && players.play(&player.id) {
            log::info!("media resumed after dictation: {}", player.id);
        }
    }
}

#[cfg(target_os = "linux")]
mod mpris {
    use std::collections::HashMap;
    use std::time::Duration;

    use zbus::blocking::Connection;
    use zbus::blocking::fdo::{DBusProxy, PropertiesProxy};
    use zbus::names::InterfaceName;
    use zbus::zvariant::OwnedValue;

    use super::{Player, Players};

    const PREFIX: &str = "org.mpris.MediaPlayer2.";
    const OBJECT: &str = "/org/mpris/MediaPlayer2";
    const INTERFACE: &str = "org.mpris.MediaPlayer2.Player";
    /// A player that doesn't answer this quickly is skipped.
    const CALL_TIMEOUT: Duration = Duration::from_millis(400);

    pub(super) struct Mpris {
        bus: Connection,
    }

    impl Mpris {
        pub(super) fn connect() -> zbus::Result<Self> {
            let bus = zbus::blocking::connection::Builder::session()?
                .method_timeout(CALL_TIMEOUT)
                .build()?;
            Ok(Self { bus })
        }

        fn read(&self, name: &str) -> zbus::Result<Player> {
            let properties = PropertiesProxy::builder(&self.bus)
                .destination(name)?
                .path(OBJECT)?
                .cache_properties(zbus::proxy::CacheProperties::No)
                .build()?;
            let all = properties.get_all(InterfaceName::from_static_str_unchecked(INTERFACE))?;
            let text = |key: &str| {
                all.get(key)
                    .and_then(|value| value.downcast_ref::<&str>().ok().map(str::to_string))
            };
            let flag = |key: &str| {
                all.get(key)
                    .and_then(|value| value.downcast_ref::<bool>().ok())
            };
            let metadata = all
                .get("Metadata")
                .and_then(|value| value.try_clone().ok())
                .and_then(|value| HashMap::<String, OwnedValue>::try_from(value).ok())
                .unwrap_or_default();
            let status = text("PlaybackStatus").unwrap_or_default();
            let url = metadata
                .get("xesam:url")
                .and_then(|value| value.downcast_ref::<&str>().ok().map(str::to_string));
            let length = metadata.get("mpris:length").and_then(|value| {
                value
                    .downcast_ref::<i64>()
                    .ok()
                    .or_else(|| value.downcast_ref::<u64>().ok().map(|v| v as i64))
            });
            Ok(Player {
                id: name.to_string(),
                playing: status == "Playing",
                paused: status == "Paused",
                can_pause: flag("CanPause").unwrap_or(true),
                url,
                has_length: length.is_some_and(|length| length > 0),
            })
        }

        fn call(&self, name: &str, method: &str) -> bool {
            self.bus
                .call_method(Some(name), OBJECT, Some(INTERFACE), method, &())
                .inspect_err(|err| log::debug!("{method} on {name} failed: {err}"))
                .is_ok()
        }
    }

    impl Players for Mpris {
        fn list(&mut self) -> Vec<Player> {
            let names = DBusProxy::new(&self.bus)
                .ok()
                .and_then(|dbus| dbus.list_names().ok())
                .unwrap_or_default();
            names
                .iter()
                .filter(|name| name.as_str().starts_with(PREFIX))
                .filter_map(|name| {
                    self.read(name.as_str())
                        .inspect_err(|err| log::debug!("media player {name}: {err}"))
                        .ok()
                })
                .collect()
        }

        fn pause(&mut self, id: &str) -> bool {
            self.call(id, "Pause")
        }

        fn play(&mut self, id: &str) -> bool {
            self.call(id, "Play")
        }
    }
}

#[cfg(windows)]
mod smtc {
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };

    use super::{Player, Players};

    pub(super) struct Smtc {
        manager: Manager,
    }

    impl Smtc {
        pub(super) fn connect() -> windows::core::Result<Self> {
            Ok(Self {
                manager: Manager::RequestAsync()?.join()?,
            })
        }

        fn sessions(&self) -> Vec<Session> {
            self.manager
                .GetSessions()
                .map(|sessions| sessions.into_iter().collect())
                .unwrap_or_default()
        }

        fn session(&self, id: &str) -> Option<Session> {
            self.sessions()
                .into_iter()
                .find(|session| session_id(session).is_some_and(|known| known == id))
        }
    }

    fn session_id(session: &Session) -> Option<String> {
        Some(session.SourceAppUserModelId().ok()?.to_string())
    }

    fn read(session: &Session) -> Option<Player> {
        let info = session.GetPlaybackInfo().ok()?;
        let status = info.PlaybackStatus().ok()?;
        let controls = info.Controls().ok()?;
        Some(Player {
            id: session_id(session)?,
            playing: status == Status::Playing,
            paused: status == Status::Paused,
            can_pause: controls.IsPauseEnabled().unwrap_or(false),
            url: None,
            // Windows doesn't say which page a browser's session is for, or
            // whether it has an end.
            has_length: true,
        })
    }

    impl Players for Smtc {
        fn list(&mut self) -> Vec<Player> {
            self.sessions().iter().filter_map(read).collect()
        }

        fn pause(&mut self, id: &str) -> bool {
            self.session(id)
                .and_then(|session| session.TryPauseAsync().ok()?.join().ok())
                .unwrap_or(false)
        }

        fn play(&mut self, id: &str) -> bool {
            self.session(id)
                .and_then(|session| session.TryPlayAsync().ok()?.join().ok())
                .unwrap_or(false)
        }
    }
}

#[cfg(target_os = "linux")]
fn with_players(run: impl FnOnce(&mut dyn Players)) {
    match mpris::Mpris::connect() {
        Ok(mut players) => run(&mut players),
        Err(err) => log::debug!("no session bus for media players: {err}"),
    }
}

#[cfg(windows)]
fn with_players(run: impl FnOnce(&mut dyn Players)) {
    use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize};
    // SAFETY: balanced below; this runs on a thread of its own or the caller's.
    let initialized = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok();
    match smtc::Smtc::connect() {
        Ok(mut players) => run(&mut players),
        Err(err) => log::debug!("no media session manager: {err}"),
    }
    if initialized {
        // SAFETY: matches the CoInitializeEx above; the manager is gone.
        unsafe { CoUninitialize() };
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
fn with_players(_run: impl FnOnce(&mut dyn Players)) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Fake {
        players: Vec<Player>,
        calls: Vec<String>,
        refuse: Vec<String>,
    }

    impl Players for Fake {
        fn list(&mut self) -> Vec<Player> {
            self.players.clone()
        }

        fn pause(&mut self, id: &str) -> bool {
            self.calls.push(format!("pause {id}"));
            if self.refuse.iter().any(|known| known == id) {
                return false;
            }
            for player in self.players.iter_mut().filter(|p| p.id == id) {
                player.playing = false;
                player.paused = true;
            }
            true
        }

        fn play(&mut self, id: &str) -> bool {
            self.calls.push(format!("play {id}"));
            true
        }
    }

    fn playing(id: &str) -> Player {
        Player {
            id: id.into(),
            playing: true,
            can_pause: true,
            has_length: true,
            ..Player::default()
        }
    }

    #[test]
    fn only_what_it_paused_is_resumed() {
        let mut fake = Fake {
            players: vec![
                playing("spotify"),
                Player {
                    id: "vlc".into(),
                    paused: true,
                    can_pause: true,
                    ..Player::default()
                },
            ],
            ..Fake::default()
        };
        let paused = PausedMedia::default();
        pause_with(&mut fake, &paused);
        assert!(!paused.is_empty());
        resume_with(&mut fake, &paused);
        // VLC was already paused, by the person: it stays that way.
        assert_eq!(fake.calls, vec!["pause spotify", "play spotify"]);
        assert!(paused.is_empty());
    }

    #[test]
    fn a_player_the_person_started_again_is_left_alone() {
        let mut fake = Fake {
            players: vec![playing("spotify")],
            ..Fake::default()
        };
        let paused = PausedMedia::default();
        pause_with(&mut fake, &paused);
        fake.players[0].playing = true;
        fake.players[0].paused = false;
        resume_with(&mut fake, &paused);
        assert_eq!(fake.calls, vec!["pause spotify"]);
    }

    #[test]
    fn a_player_that_refuses_is_not_resumed_later() {
        let mut fake = Fake {
            players: vec![playing("spotify")],
            refuse: vec!["spotify".into()],
            ..Fake::default()
        };
        let paused = PausedMedia::default();
        pause_with(&mut fake, &paused);
        assert!(paused.is_empty());
    }

    #[test]
    fn calls_and_live_pages_are_never_paused() {
        assert!(may_pause(&playing("org.mpris.MediaPlayer2.spotify")));
        assert!(may_pause(&Player {
            has_length: false,
            ..playing("org.mpris.MediaPlayer2.vlc")
        }));
        assert!(!may_pause(&Player {
            playing: false,
            ..playing("org.mpris.MediaPlayer2.vlc")
        }));
        assert!(!may_pause(&Player {
            can_pause: false,
            ..playing("org.mpris.MediaPlayer2.vlc")
        }));
        assert!(!may_pause(&playing("MSTeams_8wekyb3d8bbwe!MSTeams")));
        // A browser page with a length, on a video site and on a call.
        let page = |url: &str| Player {
            url: Some(url.into()),
            ..playing("org.mpris.MediaPlayer2.chromium.instance42")
        };
        assert!(may_pause(&page("https://www.youtube.com/watch?v=1")));
        assert!(!may_pause(&page("https://meet.google.com/abc-defg-hij")));
        assert!(!may_pause(&page("https://us02web.zoom.us/j/1")));
        // No length: a live stream, or a call on a site this list doesn't know.
        assert!(!may_pause(&Player {
            has_length: false,
            ..page("https://example.com/live")
        }));
    }

    /// A real MPRIS player on the session bus.
    #[cfg(target_os = "linux")]
    mod over_dbus {
        use super::super::*;
        use std::collections::HashMap;
        use zbus::zvariant::Value;

        struct FakePlayer {
            status: Arc<Mutex<String>>,
        }

        #[zbus::interface(name = "org.mpris.MediaPlayer2.Player")]
        impl FakePlayer {
            fn pause(&self) {
                *self.status.lock() = "Paused".into();
            }

            fn play(&self) {
                *self.status.lock() = "Playing".into();
            }

            #[zbus(property)]
            fn playback_status(&self) -> String {
                self.status.lock().clone()
            }

            #[zbus(property)]
            fn can_pause(&self) -> bool {
                true
            }

            #[zbus(property)]
            fn metadata(&self) -> HashMap<String, Value<'static>> {
                HashMap::from([("mpris:length".to_string(), Value::I64(180_000_000))])
            }
        }

        fn serve(
            name: &str,
            status: &str,
        ) -> Option<(zbus::blocking::Connection, Arc<Mutex<String>>)> {
            let status = Arc::new(Mutex::new(status.to_string()));
            let connection = zbus::blocking::connection::Builder::session()
                .ok()?
                .name(name.to_string())
                .ok()?
                .serve_at(
                    "/org/mpris/MediaPlayer2",
                    FakePlayer {
                        status: status.clone(),
                    },
                )
                .ok()?
                .build()
                .ok()?;
            Some((connection, status))
        }

        #[test]
        fn pauses_and_resumes_a_player_on_the_bus() {
            let Some((_first, playing)) =
                serve("org.mpris.MediaPlayer2.lokalbot_test_a", "Playing")
            else {
                eprintln!("no session bus: skipped");
                return;
            };
            let (_second, stopped) =
                serve("org.mpris.MediaPlayer2.lokalbot_test_b", "Paused").unwrap();

            let paused = pause_playing();
            assert_eq!(*playing.lock(), "Paused");
            assert_eq!(*stopped.lock(), "Paused");
            assert!(!paused.is_empty());

            resume(paused);
            assert_eq!(*playing.lock(), "Playing");
            // Already paused before dictation began.
            assert_eq!(*stopped.lock(), "Paused");
        }
    }
}
