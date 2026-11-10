//! Notification and tray round trips against fake D-Bus servers, ignored by
//! default. Run on a private bus: `dbus-run-session -- cargo test -p
//! lokalbot-platform --test live_dbus -- --ignored --test-threads=1`.

#![cfg(target_os = "linux")]

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use crossbeam_channel::{Sender, unbounded};
use zbus::zvariant::OwnedValue;

const WAIT: Duration = Duration::from_secs(5);

struct FakeNotifications {
    posted: Sender<(u32, String, Vec<String>)>,
    closed: Sender<u32>,
    next: AtomicU32,
}

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl FakeNotifications {
    fn get_capabilities(&self) -> Vec<String> {
        vec!["actions".into(), "body".into()]
    }

    #[allow(clippy::too_many_arguments)]
    fn notify(
        &self,
        _app_name: String,
        _replaces_id: u32,
        _app_icon: String,
        summary: String,
        _body: String,
        actions: Vec<String>,
        _hints: HashMap<String, OwnedValue>,
        _expire_timeout: i32,
    ) -> u32 {
        let id = self.next.fetch_add(1, Ordering::SeqCst) + 1;
        let _ = self.posted.send((id, summary, actions));
        id
    }

    fn close_notification(&self, id: u32) {
        let _ = self.closed.send(id);
    }

    fn get_server_information(&self) -> (String, String, String, String) {
        ("fake".into(), "LokalBot".into(), "1".into(), "1.2".into())
    }
}

type Posted = crossbeam_channel::Receiver<(u32, String, Vec<String>)>;

/// A notification server on the session bus, with what was posted to it and
/// the ids it was asked to close.
fn fake_notifications() -> (
    zbus::blocking::Connection,
    Posted,
    crossbeam_channel::Receiver<u32>,
) {
    let (posted_tx, posted) = unbounded();
    let (closed_tx, closed) = unbounded();
    let server = zbus::blocking::connection::Builder::session()
        .unwrap()
        .name("org.freedesktop.Notifications")
        .unwrap()
        .serve_at(
            "/org/freedesktop/Notifications",
            FakeNotifications {
                posted: posted_tx,
                closed: closed_tx,
                next: AtomicU32::new(0),
            },
        )
        .unwrap()
        .build()
        .unwrap();
    (server, posted, closed)
}

/// What the server sends when the user chooses `action` on notification `id`.
fn choose(server: &zbus::blocking::Connection, id: u32, action: &str) {
    // Give the waiting thread time to subscribe first.
    std::thread::sleep(Duration::from_millis(500));
    server
        .emit_signal(
            None::<zbus::names::BusName<'_>>,
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            "ActionInvoked",
            &(id, action),
        )
        .unwrap();
}

#[test]
#[ignore]
fn notification_actions_reach_the_callback() {
    let (server, posted, closed) = fake_notifications();

    let (action_tx, actions) = unbounded();
    let handle = lokalbot_platform::notify_with_timeout(
        "Meeting detected",
        "Record Zoom meeting?",
        &[("record", "Record"), ("ignore", "Ignore")],
        Some(Box::new(move |action| {
            let _ = action_tx.send(action);
        })),
        Some(Duration::from_secs(120)),
    )
    .unwrap();
    let (id, summary, offered) = posted.recv_timeout(WAIT).unwrap();
    assert_eq!(summary, "Meeting detected");
    // The last pair is the click on the body.
    assert_eq!(
        offered,
        [
            "record", "Record", "ignore", "Ignore", "default", "LokalBot"
        ]
    );

    choose(&server, id, "record");
    assert_eq!(actions.recv_timeout(WAIT).unwrap(), "record");

    handle.close();
    assert_eq!(closed.recv_timeout(WAIT).unwrap(), id);
}

/// The update and settings-approval notifications have no buttons: a click on
/// the body is all they can report, and nothing listened for it.
#[test]
#[ignore]
fn a_click_on_a_notification_without_buttons_reaches_the_callback() {
    let (server, posted, _closed) = fake_notifications();

    let (action_tx, actions) = unbounded();
    lokalbot_platform::notify(
        "LokalBot 9.9.9 is available",
        "Open Settings to install it.",
        &[],
        Some(Box::new(move |action| {
            let _ = action_tx.send(action);
        })),
    )
    .unwrap();
    let (id, _, offered) = posted.recv_timeout(WAIT).unwrap();
    assert_eq!(offered, ["default", "LokalBot"]);

    choose(&server, id, "default");
    assert_eq!(actions.recv_timeout(WAIT).unwrap(), "default");
}

/// Nothing is listening for a click that nobody asked to hear about.
#[test]
#[ignore]
fn a_notification_without_a_callback_offers_no_action() {
    let (_server, posted, _closed) = fake_notifications();
    lokalbot_platform::notify("Recording saved", "Weekly sync · 25 min", &[], None).unwrap();
    let (_, _, offered) = posted.recv_timeout(WAIT).unwrap();
    assert!(offered.is_empty(), "{offered:?}");
}

struct FakeWatcher {
    items: Sender<String>,
}

#[zbus::interface(name = "org.kde.StatusNotifierWatcher")]
impl FakeWatcher {
    fn register_status_notifier_item(
        &self,
        service: String,
        #[zbus(header)] header: zbus::message::Header<'_>,
    ) {
        let sender = header.sender().map(|s| s.to_string()).unwrap_or_default();
        let _ = self.items.send(if service.starts_with('/') {
            sender
        } else {
            service
        });
    }

    fn register_status_notifier_host(&self, _service: String) {}

    #[zbus(property)]
    fn registered_status_notifier_items(&self) -> Vec<String> {
        Vec::new()
    }

    #[zbus(property)]
    fn is_status_notifier_host_registered(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn protocol_version(&self) -> i32 {
        0
    }
}

type Layout = (i32, HashMap<String, OwnedValue>, Vec<OwnedValue>);
/// Icon name, pixmaps, title and description.
type ToolTip = (String, Vec<(i32, i32, Vec<u8>)>, String, String);

fn labels(children: &[OwnedValue]) -> Vec<(i32, String)> {
    children
        .iter()
        .filter_map(|child| {
            let (id, properties, _): Layout = child.try_clone().ok()?.try_into().ok()?;
            let label = properties
                .get("label")
                .and_then(|value| String::try_from(value.try_clone().ok()?).ok())
                .unwrap_or_default();
            Some((id, label))
        })
        .collect()
}

#[test]
#[ignore]
fn tray_menu_items_reach_the_callback() {
    use lokalbot_platform::tray::{TrayMenuState, standard_items};
    use lokalbot_platform::{Tray, TrayEvent};

    let (items_tx, registered) = unbounded();
    let _watcher = zbus::blocking::connection::Builder::session()
        .unwrap()
        .name("org.kde.StatusNotifierWatcher")
        .unwrap()
        .serve_at("/StatusNotifierWatcher", FakeWatcher { items: items_tx })
        .unwrap()
        .build()
        .unwrap();

    let (events_tx, events) = unbounded();
    let icon = (vec![0x40u8; 22 * 22 * 4], 22, 22);
    let tray = Tray::new(
        icon,
        "LokalBot",
        standard_items(&TrayMenuState {
            subtitle: "Asks before recording meetings".into(),
            ..Default::default()
        }),
        Box::new(move |event| {
            let _ = events_tx.send(event);
        }),
    )
    .unwrap();
    let service = registered.recv_timeout(WAIT).unwrap();
    println!("tray registered as {service}");

    let client = zbus::blocking::Connection::session().unwrap();
    // The item announces changes with its own signals, so read properties
    // fresh instead of from zbus's cache.
    let item: zbus::blocking::Proxy<'_> = zbus::blocking::proxy::Builder::new(&client)
        .destination(service.as_str())
        .unwrap()
        .path("/StatusNotifierItem")
        .unwrap()
        .interface("org.kde.StatusNotifierItem")
        .unwrap()
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .unwrap();
    assert_eq!(item.get_property::<String>("Title").unwrap(), "LokalBot");
    let menu_path: zbus::zvariant::OwnedObjectPath = item.get_property("Menu").unwrap();
    let menu = zbus::blocking::Proxy::new(
        &client,
        service.as_str(),
        menu_path.as_str(),
        "com.canonical.dbusmenu",
    )
    .unwrap();
    let (_, (_, _, children)): (u32, Layout) = menu
        .call("GetLayout", &(0i32, -1i32, Vec::<String>::new()))
        .unwrap();
    let rows = labels(&children);
    println!("menu: {rows:?}");
    let record = rows
        .iter()
        .find(|(_, label)| label == "Record Now")
        .map(|(id, _)| *id)
        .expect("a Record Now item");
    let _: () = menu
        .call(
            "Event",
            &(record, "clicked", zbus::zvariant::Value::from(0i32), 0u32),
        )
        .unwrap();
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        TrayEvent::Item("record".into())
    );

    let _: () = item.call("Activate", &(0i32, 0i32)).unwrap();
    assert_eq!(events.recv_timeout(WAIT).unwrap(), TrayEvent::Activated);

    tray.set_recording(true, Some("01:02".into())).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    let (_, _, title, _): ToolTip = item.get_property("ToolTip").unwrap();
    assert_eq!(title, "LokalBot — Recording 01:02");
    drop(tray);
}
