//! Seconds since the last input on Linux. X11 asks MIT-SCREEN-SAVER; GNOME
//! asks Mutter's IdleMonitor; other Wayland compositors use the
//! `ext-idle-notify-v1` protocol, then `org.freedesktop.ScreenSaver`.

use std::sync::Arc;
use std::time::Instant;

use parking_lot::Mutex;
use zbus::blocking::Connection;

use super::linux::{IdleProbe, session_bus};
use crate::session::Desktop;

pub(super) fn probe_for(desktop: &Desktop) -> Option<Box<dyn IdleProbe>> {
    type Attempt = fn() -> anyhow::Result<Box<dyn IdleProbe>>;
    let attempts: Vec<Attempt> = match desktop {
        Desktop::X11 => vec![|| Ok(Box::new(super::x11::X11Idle::connect()?))],
        Desktop::Gnome => vec![|| Ok(Box::new(MutterIdle::connect()?)), || {
            Ok(Box::new(IdleNotify::start()?))
        }],
        Desktop::Kde | Desktop::Hyprland | Desktop::Sway | Desktop::OtherWayland(_) => {
            vec![|| Ok(Box::new(IdleNotify::start()?)), || {
                Ok(Box::new(ScreenSaverIdle::connect()?))
            }]
        }
        Desktop::Headless | Desktop::Windows => Vec::new(),
    };
    for attempt in attempts {
        match attempt() {
            Ok(probe) => return Some(probe),
            Err(err) => log::debug!("idle probe unavailable: {err:#}"),
        }
    }
    None
}

/// GNOME: `org.gnome.Mutter.IdleMonitor.GetIdletime`, in milliseconds.
struct MutterIdle {
    bus: Connection,
}

impl MutterIdle {
    fn connect() -> anyhow::Result<Self> {
        let mut probe = Self {
            bus: session_bus()?,
        };
        probe.read()?;
        Ok(probe)
    }

    fn read(&mut self) -> anyhow::Result<f64> {
        let reply = self.bus.call_method(
            Some("org.gnome.Mutter.IdleMonitor"),
            "/org/gnome/Mutter/IdleMonitor/Core",
            Some("org.gnome.Mutter.IdleMonitor"),
            "GetIdletime",
            &(),
        )?;
        let ms: u64 = reply.body().deserialize()?;
        Ok(ms as f64 / 1000.0)
    }
}

impl IdleProbe for MutterIdle {
    fn idle_seconds(&mut self) -> Option<f64> {
        self.read()
            .inspect_err(|err| log::debug!("mutter idle: {err:#}"))
            .ok()
    }
}

/// `org.freedesktop.ScreenSaver.GetSessionIdleTime`. The specification says
/// seconds; KDE answers in milliseconds. The unit is learned from how fast
/// the value grows while the user is away.
struct ScreenSaverIdle {
    bus: Connection,
    units: IdleUnits,
}

impl ScreenSaverIdle {
    fn connect() -> anyhow::Result<Self> {
        let kde = matches!(crate::session::desktop(), Desktop::Kde);
        let mut probe = Self {
            bus: session_bus()?,
            units: IdleUnits::new(kde),
        };
        probe.raw()?;
        Ok(probe)
    }

    fn raw(&mut self) -> anyhow::Result<u32> {
        let reply = self.bus.call_method(
            Some("org.freedesktop.ScreenSaver"),
            "/org/freedesktop/ScreenSaver",
            Some("org.freedesktop.ScreenSaver"),
            "GetSessionIdleTime",
            &(),
        )?;
        Ok(reply.body().deserialize()?)
    }
}

impl IdleProbe for ScreenSaverIdle {
    fn idle_seconds(&mut self) -> Option<f64> {
        match self.raw() {
            Ok(raw) => Some(self.units.seconds(raw, Instant::now())),
            Err(err) => {
                log::debug!("screensaver idle: {err:#}");
                None
            }
        }
    }
}

/// Learns whether an idle counter counts seconds or milliseconds.
#[derive(Debug)]
struct IdleUnits {
    milliseconds: bool,
    last: Option<(u32, Instant)>,
}

impl IdleUnits {
    fn new(milliseconds: bool) -> Self {
        Self {
            milliseconds,
            last: None,
        }
    }

    fn seconds(&mut self, raw: u32, now: Instant) -> f64 {
        if let Some((previous, at)) = self.last {
            let wall = now.duration_since(at).as_secs_f64();
            if raw > previous && wall >= 2.0 {
                let rate = f64::from(raw - previous) / wall;
                if rate > 100.0 {
                    self.milliseconds = true;
                } else if rate < 10.0 {
                    self.milliseconds = false;
                }
            }
        }
        self.last = Some((raw, now));
        if self.milliseconds {
            f64::from(raw) / 1000.0
        } else {
            f64::from(raw)
        }
    }
}

/// `ext-idle-notify-v1`: the compositor says when input has been quiet for a
/// second and when it resumes, which gives the idle time exactly. Version 2
/// ignores idle inhibitors such as a playing video, like macOS input idle.
struct IdleNotify {
    idle_since: Arc<Mutex<Option<Instant>>>,
}

mod notify_protocol {
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use parking_lot::Mutex;
    use wayland_client::globals::GlobalListContents;
    use wayland_client::protocol::{wl_registry, wl_seat};
    use wayland_client::{Connection, Dispatch, QueueHandle};
    use wayland_protocols::ext::idle_notify::v1::client::ext_idle_notification_v1::{
        self, ExtIdleNotificationV1,
    };
    use wayland_protocols::ext::idle_notify::v1::client::ext_idle_notifier_v1::ExtIdleNotifierV1;

    pub(super) const THRESHOLD: Duration = Duration::from_secs(1);

    pub(super) struct State {
        pub(super) idle_since: Arc<Mutex<Option<Instant>>>,
    }

    impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
        fn event(
            _: &mut Self,
            _: &wl_registry::WlRegistry,
            _: wl_registry::Event,
            _: &GlobalListContents,
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
        }
    }

    impl Dispatch<wl_seat::WlSeat, ()> for State {
        fn event(
            _: &mut Self,
            _: &wl_seat::WlSeat,
            _: wl_seat::Event,
            _: &(),
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
        }
    }

    impl Dispatch<ExtIdleNotifierV1, ()> for State {
        fn event(
            _: &mut Self,
            _: &ExtIdleNotifierV1,
            _: <ExtIdleNotifierV1 as wayland_client::Proxy>::Event,
            _: &(),
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
        }
    }

    impl Dispatch<ExtIdleNotificationV1, ()> for State {
        fn event(
            state: &mut Self,
            _: &ExtIdleNotificationV1,
            event: ext_idle_notification_v1::Event,
            _: &(),
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
            let mut idle = state.idle_since.lock();
            match event {
                ext_idle_notification_v1::Event::Idled => {
                    let now = Instant::now();
                    *idle = Some(now.checked_sub(THRESHOLD).unwrap_or(now));
                }
                ext_idle_notification_v1::Event::Resumed => *idle = None,
                _ => {}
            }
        }
    }
}

impl IdleNotify {
    fn start() -> anyhow::Result<Self> {
        use wayland_client::Proxy as _;
        use wayland_client::globals::registry_queue_init;
        use wayland_client::protocol::wl_seat::WlSeat;
        use wayland_protocols::ext::idle_notify::v1::client::ext_idle_notifier_v1::ExtIdleNotifierV1;

        let conn = wayland_client::Connection::connect_to_env()?;
        let (globals, mut queue) = registry_queue_init::<notify_protocol::State>(&conn)?;
        let handle = queue.handle();
        let seat: WlSeat = globals.bind(&handle, 1..=1, ())?;
        let notifier: ExtIdleNotifierV1 = globals.bind(&handle, 1..=2, ())?;
        let threshold = notify_protocol::THRESHOLD.as_millis() as u32;
        let notification = if notifier.version() >= 2 {
            notifier.get_input_idle_notification(threshold, &seat, &handle, ())
        } else {
            notifier.get_idle_notification(threshold, &seat, &handle, ())
        };
        let idle_since = Arc::new(Mutex::new(None));
        let mut state = notify_protocol::State {
            idle_since: idle_since.clone(),
        };
        queue.roundtrip(&mut state)?;
        std::thread::Builder::new()
            .name("lokalbot-idle".into())
            .spawn(move || {
                let _alive = (seat, notifier, notification, conn);
                // Ends with the source (or the session) at the next event.
                while Arc::strong_count(&state.idle_since) > 1 {
                    if queue.blocking_dispatch(&mut state).is_err() {
                        break;
                    }
                }
            })?;
        Ok(Self { idle_since })
    }
}

impl IdleProbe for IdleNotify {
    fn idle_seconds(&mut self) -> Option<f64> {
        Some(
            self.idle_since
                .lock()
                .map_or(0.0, |since| since.elapsed().as_secs_f64()),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn idle_units_are_learned_from_growth() {
        let start = Instant::now();
        let mut units = IdleUnits::new(true);
        assert_eq!(units.seconds(10, start), 0.01);
        // Grew by 5 over 5 s: seconds after all.
        assert_eq!(units.seconds(15, start + Duration::from_secs(5)), 15.0);
        assert_eq!(units.seconds(20, start + Duration::from_secs(10)), 20.0);
        let mut units = IdleUnits::new(false);
        assert_eq!(units.seconds(1, start), 1.0);
        // Grew by 5000 over 5 s: milliseconds.
        assert_eq!(units.seconds(5001, start + Duration::from_secs(5)), 5.001);
    }
}
