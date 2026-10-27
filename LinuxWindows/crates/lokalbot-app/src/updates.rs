//! Automatic updates (`AppUpdateManager.swift`, Sparkle's standard driver).
//!
//! While "Check for updates automatically" is on, LokalBot reads the latest
//! release's feed shortly after launch and once a day. "Check for Updates…"
//! in Settings checks at any time. As with Sparkle's defaults, nothing is
//! downloaded or installed until the user chooses Install and Relaunch in
//! Settings → General or the tray menu; a newly found version is announced
//! once with a notification. Installing downloads the archive, verifies it
//! (size, SHA-256, Ed25519 signature) before unpacking, swaps the files,
//! stops the llama.cpp servers, starts the new copy and quits; Agent Mode
//! stops its processes as LokalBot quits. When this copy cannot replace its
//! own files (`/opt`, Program Files, a source build), the update is offered
//! as a download from GitHub instead. A copy a package manager installed is
//! told to update through it: the AUR's `lokalbot-bin` with `yay -Syu`, the
//! release's .deb and .rpm with `apt upgrade` and `dnf upgrade` once they
//! added LokalBot's repository, and otherwise (the Arch package, or a .deb
//! or .rpm from before the repository) by installing the new package.

use std::ffi::OsString;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use gpui_kit::{App, AppContext as _, Context, Entity, Global, SharedString};
use lokalbot_update::install::{self, Installation, Placement};
use lokalbot_update::package::{self, Package};
use lokalbot_update::{Check, Release, UpdateError, Updater, Version};

use crate::state::{AppData, RecordingState};

/// The first automatic check waits for startup work to settle.
const FIRST_CHECK_DELAY: Duration = Duration::from_secs(20);
/// Sparkle's `SUScheduledCheckInterval`.
const CHECK_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);
/// After a failed automatic check (offline at login, say).
const RETRY_INTERVAL: Duration = Duration::from_secs(60 * 60);
const TICK: Duration = Duration::from_secs(60);

pub struct UpdatesHandle(pub Entity<Updates>);

impl Global for UpdatesHandle {}

pub fn global(cx: &App) -> Option<Entity<Updates>> {
    cx.try_global::<UpdatesHandle>().map(|h| h.0.clone())
}

#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    /// A development build, or a platform without published archives.
    Unavailable,
    Idle,
    Checking,
    UpToDate,
    /// The latest release has no feed for this platform.
    Unpublished,
    Available(Release),
    Downloading {
        release: Release,
        /// 0…1.
        progress: f32,
    },
    Installing(Release),
    CheckFailed(SharedString),
    InstallFailed {
        release: Release,
        message: SharedString,
    },
}

/// How the update on offer reaches this copy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// Install and Relaunch replaces this copy.
    Install,
    /// The release page: a copy that cannot replace itself, or the
    /// release's own package, which has no repository to update from.
    Download,
    /// A package manager updates this copy from a repository (the AUR's
    /// `lokalbot-bin`, a distribution's package).
    PackageManager,
}

impl Status {
    /// The release on offer, in any state that has one.
    pub fn release(&self) -> Option<&Release> {
        match self {
            Status::Available(release)
            | Status::Downloading { release, .. }
            | Status::Installing(release)
            | Status::InstallFailed { release, .. } => Some(release),
            _ => None,
        }
    }

    pub fn busy(&self) -> bool {
        matches!(
            self,
            Status::Checking | Status::Downloading { .. } | Status::Installing(_)
        )
    }
}

pub struct Updates {
    data: Entity<AppData>,
    updater: Option<Arc<Updater>>,
    installation: Option<Installation>,
    /// The package that installed this copy, looked up with the first check
    /// (the inner `None`: no package lists it).
    package: Option<Option<Package>>,
    pub status: Status,
    next_check: Instant,
    /// The newest version a notification already announced.
    announced: Option<Version>,
    /// `lokalbot install-update`: install as soon as a check finds one.
    install_when_found: bool,
}

/// Creates the updater and its daily schedule. Leftovers of an earlier
/// update (`.old` binaries, downloads) are removed first.
pub fn start(data: &Entity<AppData>, cx: &mut App) {
    let work_dir = data.read(cx).library.paths().root().join("updates");
    let updater = Updater::for_this_build(work_dir).map(Arc::new);
    let installation = match Installation::current() {
        Ok(installation) => Some(installation),
        Err(err) => {
            log::warn!("updates: could not find this installation: {err}");
            None
        }
    };
    match (&updater, &installation) {
        (Some(updater), Some(installation)) => log::info!(
            "updates: {} at {} ({:?}), feed {}",
            updater.current(),
            installation.dir.display(),
            installation.placement,
            updater.feed_url()
        ),
        _ => log::info!("updates: off in this build"),
    }
    // Before anything can start a download into it.
    if let Some(updater) = &updater {
        updater.clear_work_dir();
    }
    if let Some(installation) = &installation {
        let targets = installation.targets();
        cx.background_spawn(async move {
            // The copy that installed this update may predate this call.
            record_installed_version(&targets.dir, &Version::current());
            // The copy this one replaced may still be closing.
            for delay in [0, 10, 60] {
                smol::Timer::after(Duration::from_secs(delay)).await;
                install::remove_leftovers(&targets);
            }
        })
        .detach();
    }
    let entity = cx.new(|_: &mut Context<Updates>| Updates {
        data: data.clone(),
        status: if updater.is_some() {
            Status::Idle
        } else {
            Status::Unavailable
        },
        updater,
        installation,
        package: None,
        next_check: Instant::now() + FIRST_CHECK_DELAY,
        announced: None,
        install_when_found: false,
    });
    cx.set_global(UpdatesHandle(entity.clone()));
    let scheduled = entity.downgrade();
    cx.spawn(async move |cx| {
        loop {
            smol::Timer::after(TICK.min(FIRST_CHECK_DELAY)).await;
            let alive = scheduled.update(cx, |updates, cx| updates.scheduled_check(cx));
            if alive.is_err() {
                break;
            }
        }
    })
    .detach();
}

impl Updates {
    pub fn enabled(&self) -> bool {
        self.updater.is_some()
    }

    /// Whether Install and Relaunch can replace this copy.
    pub fn can_install(&self, release: &Release) -> bool {
        release.installable
            && self
                .installation
                .as_ref()
                .is_some_and(Installation::can_replace)
    }

    /// Install and Relaunch, the download, or the package manager.
    pub fn route(&self, release: &Release) -> Route {
        route(self.can_install(release), self.package())
    }

    /// The package that installed this copy, once the first check looked.
    pub fn package(&self) -> Option<&Package> {
        self.package.as_ref().and_then(Option::as_ref)
    }

    pub fn install_dir(&self) -> Option<String> {
        self.installation
            .as_ref()
            .map(|i| i.dir.display().to_string())
    }

    fn scheduled_check(&mut self, cx: &mut Context<Self>) {
        let automatic = self.data.read(cx).settings.check_for_updates;
        if !automatic || self.updater.is_none() || self.status.busy() {
            return;
        }
        // An offered update stays offered; the feed is read again daily.
        if Instant::now() >= self.next_check {
            self.check(false, cx);
        }
    }

    /// "Check for Updates…" (`manual`) or the daily check.
    pub fn check(&mut self, manual: bool, cx: &mut Context<Self>) {
        let Some(updater) = self.updater.clone() else {
            return;
        };
        if self.status.busy() {
            return;
        }
        let previous = self.status.clone();
        self.status = Status::Checking;
        cx.notify();
        // Only a copy that cannot replace itself needs to know its package.
        let executable = match (&self.package, &self.installation) {
            (None, Some(installation)) if installation.placement == Placement::Managed => {
                Some(installation.dir.join(install::APP_BINARY))
            }
            _ => None,
        };
        cx.spawn(async move |this, cx| {
            let (result, package) = cx
                .background_spawn(async move {
                    let package = executable.map(|exe| package::owner(&exe));
                    (updater.check(), package)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Some(package) = package {
                    log::info!("updates: installed by package {package:?}");
                    this.package = Some(package);
                }
                this.checked(result, previous, manual, cx)
            });
        })
        .detach();
    }

    fn checked(
        &mut self,
        result: Result<Check, UpdateError>,
        previous: Status,
        manual: bool,
        cx: &mut Context<Self>,
    ) {
        self.next_check = Instant::now()
            + if result.is_ok() {
                CHECK_INTERVAL
            } else {
                RETRY_INTERVAL
            };
        self.status = match result {
            Ok(Check::UpToDate) => {
                if let Some(updater) = &self.updater {
                    log::info!("updates: up to date at {}", updater.current());
                }
                Status::UpToDate
            }
            Ok(Check::Unpublished) => {
                log::info!("updates: the latest release has no feed for this platform");
                Status::Unpublished
            }
            Ok(Check::Newer(release)) => {
                log::info!(
                    "updates: LokalBot {} is available ({:?} here)",
                    release.version,
                    self.route(&release)
                );
                Status::Available(*release)
            }
            Err(err) => {
                log::warn!("updates: check failed: {err}");
                // A failed automatic check keeps showing what was known.
                match previous {
                    Status::Available(release) if !manual => Status::Available(release),
                    _ => Status::CheckFailed(check_error(&err)),
                }
            }
        };
        cx.notify();
        let Status::Available(release) = &self.status else {
            if self.install_when_found {
                self.install_when_found = false;
                log::warn!("updates: install-update found nothing to install");
            }
            return;
        };
        let release = release.clone();
        if self.install_when_found {
            self.install_when_found = false;
            self.install(cx);
            return;
        }
        if !manual && self.announced.is_none_or(|v| v < release.version) {
            self.announced = Some(release.version);
            let body = match self.route(&release) {
                Route::Install => {
                    lokalbot_i18n::tr("Choose Install and Relaunch in Settings or the tray menu.")
                        .into()
                }
                _ => offer_text(self, &release),
            };
            crate::desktop::notify_update_available(release.version.to_string(), body, cx);
        }
    }

    /// `lokalbot install-update`: installs the offered update, checking first
    /// when none is known yet. The user asked for it, so no further consent.
    pub fn install_from_command(&mut self, cx: &mut Context<Self>) {
        if self.updater.is_none() {
            log::warn!("updates: install-update ignored; updates are off in this build");
            return;
        }
        match &self.status {
            Status::Available(_) | Status::InstallFailed { .. } => self.install(cx),
            status if status.busy() => {}
            _ => {
                self.install_when_found = true;
                self.check(true, cx);
            }
        }
    }

    /// Install and Relaunch.
    pub fn install(&mut self, cx: &mut Context<Self>) {
        let (Some(updater), Some(release)) = (self.updater.clone(), self.status.release().cloned())
        else {
            return;
        };
        if self.status.busy() {
            return;
        }
        match self.route(&release) {
            Route::Install => {}
            Route::Download => {
                self.open_release_page(cx);
                return;
            }
            Route::PackageManager => {
                let text = offer_text(self, &release);
                self.data.update(cx, |data, cx| data.show_message(text, cx));
                return;
            }
        }
        let recording = matches!(
            self.data.read(cx).recording,
            RecordingState::Recording { .. }
        );
        if recording {
            self.data.update(cx, |data, cx| {
                data.show_error(
                    lokalbot_i18n::tr("Stop the recording before installing the update."),
                    cx,
                )
            });
            return;
        }
        let Some(targets) = self.installation.as_ref().map(Installation::targets) else {
            return;
        };
        self.status = Status::Downloading {
            release: release.clone(),
            progress: 0.0,
        };
        cx.notify();
        let (progress_tx, progress_rx) = smol::channel::unbounded::<f32>();
        let (done_tx, done_rx) = smol::channel::bounded::<Result<install::Installed, String>>(1);
        let job_release = release.clone();
        cx.background_spawn(async move {
            let cancel = AtomicBool::new(false);
            let result = updater
                .prepare(&job_release, &cancel, &mut |done, total| {
                    if total > 0 {
                        let _ = progress_tx.try_send(done as f32 / total as f32);
                    }
                })
                .map_err(|err| {
                    log::warn!("updates: {err}");
                    install_error(&err)
                })
                .and_then(|staged| {
                    let _ = progress_tx.try_send(-1.0);
                    let installed = install::install(&staged, &targets, install::SwapStyle::NATIVE)
                        .map_err(|err| {
                            log::error!("updates: install failed: {err}");
                            err.to_string()
                        });
                    if installed.is_ok() {
                        record_installed_version(&targets.dir, &job_release.version);
                    }
                    updater.clear_work_dir();
                    installed
                });
            let _ = done_tx.send(result).await;
        })
        .detach();
        cx.spawn(async move |this, cx| {
            while let Ok(progress) = progress_rx.recv().await {
                let alive = this.update(cx, |this, cx| {
                    let next = match &this.status {
                        Status::Downloading { release, .. } if progress < 0.0 => {
                            Status::Installing(release.clone())
                        }
                        Status::Downloading { release, .. } => Status::Downloading {
                            release: release.clone(),
                            progress,
                        },
                        other => other.clone(),
                    };
                    this.status = next;
                    cx.notify();
                });
                if alive.is_err() {
                    return;
                }
            }
            let Ok(result) = done_rx.recv().await else {
                return;
            };
            let _ = this.update(cx, |this, cx| match result {
                Ok(installed) => this.relaunch(installed, release, cx),
                Err(message) => {
                    this.status = Status::InstallFailed {
                        release,
                        message: message.into(),
                    };
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// The files are in place: stop the llama.cpp servers, start the new
    /// copy, quit (Agent Mode stops its processes on quit).
    fn relaunch(
        &mut self,
        installed: install::Installed,
        release: Release,
        cx: &mut Context<Self>,
    ) {
        log::info!(
            "updates: installed LokalBot {} ({} files) in {}; relaunching",
            release.version,
            installed.replaced.len(),
            installed
                .executable
                .parent()
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        );
        self.status = Status::Installing(release);
        cx.notify();
        let engine = cx
            .try_global::<crate::bridge::EngineHandle>()
            .map(|e| e.0.clone());
        cx.spawn(async move |_, cx| {
            if let Some(engine) = engine {
                cx.background_spawn(async move { engine.runtime().shutdown() })
                    .await;
            }
            let args = relaunch_args();
            match install::relaunch(
                &installed.executable,
                &args,
                &[lokalbot_update::CURRENT_VERSION_ENV],
            ) {
                Ok(()) => cx.update(|cx| cx.quit()),
                Err(err) => {
                    log::error!("updates: could not start the new copy: {err}");
                    cx.update(|cx| {
                        AppData::global(cx).update(cx, |data, cx| {
                            data.show_error(
                                lokalbot_i18n::format(
                                    "LokalBot was updated but could not restart. Quit and open it again. ({err})",
                                    &[("err", err.to_string())],
                                ),
                                cx,
                            )
                        })
                    });
                }
            }
        })
        .detach();
    }

    /// Release Notes, or Download for copies that cannot replace themselves.
    pub fn open_release_page(&self, cx: &mut App) {
        if let Some(release) = self.status.release() {
            cx.open_url(&release.feed.release_notes_url);
        }
    }
}

/// [`Updates::open_release_page`] for callers holding only the app.
pub fn open_release_page(cx: &mut App) {
    let url = global(cx).and_then(|updates| {
        updates
            .read(cx)
            .status
            .release()
            .map(|release| release.feed.release_notes_url.clone())
    });
    if let Some(url) = url {
        cx.open_url(&url);
    }
}

/// Shows `version` in the installer's Installed apps entry (Windows), which an
/// update LokalBot installs itself would otherwise leave at the installer's
/// version. Failures only log: the update itself is in place.
fn record_installed_version(dir: &std::path::Path, version: &Version) {
    match lokalbot_update::installed_apps::record_version(dir, version) {
        Ok(true) => log::info!("updates: Installed apps now shows LokalBot {version}"),
        Ok(false) => {}
        Err(err) => log::warn!("updates: could not update the Installed apps entry: {err}"),
    }
}

/// The library this copy uses, passed on to the new copy.
fn relaunch_args() -> Vec<OsString> {
    let args: Vec<String> = std::env::args().collect();
    match lokalbot_core::LibraryPaths::root_from_args(&args) {
        Some(root) => vec![
            lokalbot_core::paths::STORAGE_ROOT_FLAG.into(),
            root.into_os_string(),
        ],
        None => Vec::new(),
    }
}

fn check_error(err: &UpdateError) -> SharedString {
    lokalbot_i18n::format(
        "Couldn't check for updates: {err}",
        &[("err", err.to_string())],
    )
    .into()
}

fn install_error(err: &UpdateError) -> String {
    match err {
        UpdateError::Integrity(_) => {
            lokalbot_i18n::tr("The download failed its integrity check and was discarded.").into()
        }
        other => other.to_string(),
    }
}

/// The status line under "Current version" in Settings.
pub fn status_text(updates: &Updates) -> SharedString {
    match &updates.status {
        Status::Unavailable => {
            lokalbot_i18n::tr("Updates are turned off in development builds.").into()
        }
        Status::Idle | Status::Available(_) | Status::Downloading { .. } | Status::Installing(_) | Status::InstallFailed { .. } => lokalbot_i18n::tr(
            "Updates are signed and downloaded from GitHub. Only the update feed and the chosen download are fetched.",
        )
        .into(),
        Status::Checking => lokalbot_i18n::tr("Checking…").into(),
        Status::UpToDate => lokalbot_i18n::tr("LokalBot is up to date.").into(),
        Status::Unpublished => {
            lokalbot_i18n::tr("No update has been published for this platform yet.").into()
        }
        Status::CheckFailed(message) => message.clone(),
    }
}

/// Help under the "LokalBot <version> is available" row.
pub fn offer_text(updates: &Updates, release: &Release) -> SharedString {
    let dir = updates.install_dir().unwrap_or_default();
    match &updates.status {
        Status::Downloading { progress, .. } => lokalbot_i18n::format(
            "Downloading LokalBot {version}… {percent}%",
            &[
                ("version", release.version.to_string()),
                ("percent", format!("{}", (progress * 100.0).round() as u32)),
            ],
        )
        .into(),
        Status::Installing(_) => lokalbot_i18n::format(
            "Installing LokalBot {version}…",
            &[("version", release.version.to_string())],
        )
        .into(),
        Status::InstallFailed { message, .. } => lokalbot_i18n::format(
            "The update could not be installed: {err}",
            &[("err", message.to_string())],
        )
        .into(),
        _ => advice(updates.route(release), updates.package(), release, dir).into(),
    }
}

fn route(can_install: bool, package: Option<&Package>) -> Route {
    if can_install {
        Route::Install
    } else if package.is_some_and(|p| !p.from_release()) {
        Route::PackageManager
    } else {
        Route::Download
    }
}

/// [`offer_text`] while nothing is downloading or installing.
fn advice(route: Route, package: Option<&Package>, release: &Release, dir: String) -> String {
    match (route, package) {
        (Route::Install, _) => lokalbot_i18n::format(
            "Installing replaces LokalBot in {dir} and relaunches it.",
            &[("dir", dir)],
        ),
        (Route::PackageManager, Some(package)) => lokalbot_i18n::format(
            "Update LokalBot with your package manager, for example {command}.",
            &[("command", package.update_command().to_string())],
        ),
        // The release's own package.
        (_, Some(package)) => lokalbot_i18n::format(
            "Download the new package and install it with {command}.",
            &[("command", package.install_command(release.version))],
        ),
        _ if !release.installable => lokalbot_i18n::tr(
            "This version is too old to update itself. Download the new version from GitHub.",
        )
        .to_string(),
        _ => lokalbot_i18n::format(
            "LokalBot can't replace itself in {dir}. Download the new version from GitHub instead.",
            &[("dir", dir)],
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_update::package::Manager;

    fn release(installable: bool) -> Release {
        Release {
            feed: lokalbot_update::Feed {
                platform: "linux-x86_64".into(),
                version: "0.11.1".into(),
                minimum_version: "0.11.0".into(),
                url: "https://github.com/stevyhacker/lokalbot/releases/download/v0.11.1/LokalBot-0.11.1-linux-x86_64.tar.gz".into(),
                size: 1,
                sha256: "0".repeat(64),
                signature: String::new(),
                release_notes_url: "https://github.com/stevyhacker/lokalbot/releases/tag/v0.11.1"
                    .into(),
            },
            version: Version::new(0, 11, 1),
            installable,
        }
    }

    fn package(manager: Manager, name: &str) -> Package {
        Package {
            manager,
            name: name.into(),
            repository: false,
        }
    }

    /// What a copy that cannot replace itself is told.
    fn offered(package: Option<&Package>, installable: bool) -> (Route, String) {
        let release = release(installable);
        let route = route(false, package);
        (route, advice(route, package, &release, "/usr/bin".into()))
    }

    #[test]
    fn package_manager_copies_are_told_to_update_through_it() {
        let aur = package(Manager::Pacman, "lokalbot-bin");
        assert_eq!(
            offered(Some(&aur), true),
            (
                Route::PackageManager,
                "Update LokalBot with your package manager, for example yay -Syu.".into()
            )
        );
        // Even when the copy is too old to update itself.
        assert_eq!(offered(Some(&aur), false).0, Route::PackageManager);
        let debian = package(Manager::Dpkg, "lokalbot-desktop");
        assert_eq!(
            offered(Some(&debian), true).1,
            "Update LokalBot with your package manager, for example sudo apt upgrade."
        );
    }

    #[test]
    fn release_packages_with_the_repository_are_told_to_upgrade() {
        let with_repository = |manager| Package {
            repository: true,
            ..package(manager, "lokalbot")
        };
        assert_eq!(
            offered(Some(&with_repository(Manager::Dpkg)), true),
            (
                Route::PackageManager,
                "Update LokalBot with your package manager, for example sudo apt upgrade.".into()
            )
        );
        assert_eq!(
            offered(Some(&with_repository(Manager::Rpm)), false),
            (
                Route::PackageManager,
                "Update LokalBot with your package manager, for example sudo dnf upgrade.".into()
            )
        );
    }

    #[test]
    fn release_packages_are_told_to_install_the_new_package() {
        let deb = package(Manager::Dpkg, "lokalbot");
        assert_eq!(
            offered(Some(&deb), true),
            (
                Route::Download,
                "Download the new package and install it with \
                 sudo apt install ./LokalBot-0.11.1-linux-amd64.deb."
                    .into()
            )
        );
        let arch = package(Manager::Pacman, "lokalbot");
        assert_eq!(
            offered(Some(&arch), false).1,
            "Download the new package and install it with \
             sudo pacman -U ./LokalBot-0.11.1-linux-x86_64.pkg.tar.zst."
        );
    }

    #[test]
    fn other_copies_keep_the_download_and_installable_ones_install() {
        assert_eq!(
            offered(None, true),
            (
                Route::Download,
                "LokalBot can't replace itself in /usr/bin. Download the new version from GitHub instead."
                    .into()
            )
        );
        assert_eq!(route(true, None), Route::Install);
        assert_eq!(
            route(true, Some(&package(Manager::Pacman, "lokalbot-bin"))),
            Route::Install
        );
    }
}
