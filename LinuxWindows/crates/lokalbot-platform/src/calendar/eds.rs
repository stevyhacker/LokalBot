//! Evolution Data Server over D-Bus: every enabled, selected calendar the
//! desktop knows, including those GNOME Online Accounts adds (Google,
//! Microsoft 365, Nextcloud). EDS keeps its own synced copy, so reading it
//! makes no network request of LokalBot's own.
//!
//! `Sources5` lists the sources; `CalendarFactory.OpenCalendar` starts (or
//! reuses) a backend whose object lives only while this connection does, so
//! one connection serves a whole refresh.

use std::collections::{BTreeSet, HashMap};
use std::time::Duration;

use anyhow::{Context as _, Result};
use lokalbot_core::calendar::{CalendarEvent, provider};
use lokalbot_core::model::CalendarParticipantIdentity;
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

use super::ics::{self, ParseOptions};

const SOURCES_PREFIX: &str = "org.gnome.evolution.dataserver.Sources";
const CALENDAR_PREFIX: &str = "org.gnome.evolution.dataserver.Calendar";
const SOURCE_MANAGER: &str = "/org/gnome/evolution/dataserver/SourceManager";
const SOURCE_INTERFACE: &str = "org.gnome.evolution.dataserver.Source";
const CALENDAR_FACTORY: &str = "/org/gnome/evolution/dataserver/CalendarFactory";
const CALENDAR_INTERFACE: &str = "org.gnome.evolution.dataserver.Calendar";

/// One EDS calendar source.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Source {
    pub uid: String,
    pub display_name: Option<String>,
    /// An account address from the source or its parent collection.
    pub account_address: Option<String>,
}

/// Events from every enabled EDS calendar. `Ok(None)` when EDS is not
/// installed (nothing owns or can start its source registry).
pub fn fetch(options: &ParseOptions) -> Result<Option<Vec<CalendarEvent>>> {
    let bus = zbus::blocking::connection::Builder::session()?
        .method_timeout(Duration::from_secs(20))
        .build()
        .context("the session bus is not available")?;
    let Some(sources_bus) = newest_name(&bus, SOURCES_PREFIX)? else {
        return Ok(None);
    };
    let Some(calendar_bus) = newest_name(&bus, CALENDAR_PREFIX)? else {
        return Ok(None);
    };
    let sources = calendar_sources(&bus, &sources_bus)?;
    let mut events = Vec::new();
    for source in sources {
        match read_source(&bus, &calendar_bus, &source, options) {
            Ok(found) => events.extend(found),
            Err(err) => log::warn!(
                "calendar: Evolution calendar {} could not be read: {err:#}",
                source.display_name.as_deref().unwrap_or("(unnamed)")
            ),
        }
    }
    events.sort_by_key(|a| a.start);
    events.dedup_by(|a, b| a.external_id == b.external_id);
    Ok(Some(events))
}

fn read_source(
    bus: &Connection,
    calendar_bus: &str,
    source: &Source,
    options: &ParseOptions,
) -> Result<Vec<CalendarEvent>> {
    let reply = bus.call_method(
        Some(calendar_bus),
        CALENDAR_FACTORY,
        Some("org.gnome.evolution.dataserver.CalendarFactory"),
        "OpenCalendar",
        &(source.uid.as_str(),),
    )?;
    let (path, backend_bus): (String, String) = reply.body().deserialize()?;
    let properties: Vec<String> = bus
        .call_method(
            Some(backend_bus.as_str()),
            path.as_str(),
            Some(CALENDAR_INTERFACE),
            "Open",
            &(),
        )?
        .body()
        .deserialize()?;
    let query = format!(
        r#"(occur-in-time-range? (make-time "{}") (make-time "{}"))"#,
        options.from.format("%Y%m%dT%H%M%SZ"),
        options.to.format("%Y%m%dT%H%M%SZ")
    );
    let objects: Vec<String> = bus
        .call_method(
            Some(backend_bus.as_str()),
            path.as_str(),
            Some(CALENDAR_INTERFACE),
            "GetObjectList",
            &(query.as_str(),),
        )?
        .body()
        .deserialize()?;
    let mut timezones = Vec::new();
    for zone in referenced_zones(&objects) {
        let reply = bus.call_method(
            Some(backend_bus.as_str()),
            path.as_str(),
            Some(CALENDAR_INTERFACE),
            "GetTimezone",
            &(zone.as_str(),),
        );
        if let Ok(reply) = reply
            && let Ok(component) = reply.body().deserialize::<String>()
        {
            timezones.push(component);
        }
    }
    let mut my_addresses = options.my_addresses.clone();
    my_addresses.extend(source.account_address.clone());
    my_addresses.extend(
        open_property(&properties, "cal-email-address")
            .and_then(|a| CalendarParticipantIdentity::normalized_email_address(&a)),
    );
    let options = ParseOptions {
        provider: provider::EDS.into(),
        calendar_title: source.display_name.clone(),
        my_addresses,
        ..options.clone()
    };
    Ok(ics::parse_components(&objects, &timezones, &options))
}

/// `Open` returns `[key, value, key, value, …]` with GVariant-quoted values.
fn open_property(properties: &[String], key: &str) -> Option<String> {
    properties
        .chunks(2)
        .find(|pair| pair.first().map(String::as_str) == Some(key))
        .and_then(|pair| pair.get(1))
        .map(|value| value.trim_matches('\'').to_string())
        .filter(|value| !value.is_empty())
}

/// Every `TZID=` an object mentions, so their definitions come along.
fn referenced_zones(objects: &[String]) -> BTreeSet<String> {
    let mut zones = BTreeSet::new();
    for object in objects {
        let unfolded = object.replace("\r\n ", "").replace("\n ", "");
        for line in unfolded.lines() {
            let Some((head, _)) = line.split_once(':') else {
                continue;
            };
            for parameter in head.split(';').skip(1) {
                if let Some(zone) = parameter.strip_prefix("TZID=") {
                    zones.insert(zone.trim_matches('"').to_string());
                }
            }
        }
    }
    zones
}

/// The highest-numbered EDS bus name that is running or can be started
/// (`…Sources5`, `…Calendar8`).
fn newest_name(bus: &Connection, prefix: &str) -> Result<Option<String>> {
    let dbus = zbus::blocking::fdo::DBusProxy::new(bus)?;
    let mut names: Vec<String> = dbus
        .list_names()?
        .into_iter()
        .chain(dbus.list_activatable_names()?)
        .map(|name| name.to_string())
        .collect();
    names.retain(|name| {
        name.strip_prefix(prefix)
            .is_some_and(|v| !v.is_empty() && v.chars().all(|c| c.is_ascii_digit()))
    });
    names.sort_by_key(|name| name[prefix.len()..].parse::<u32>().unwrap_or(0));
    Ok(names.pop())
}

type ManagedObjects = HashMap<OwnedObjectPath, HashMap<String, HashMap<String, OwnedValue>>>;

fn calendar_sources(bus: &Connection, sources_bus: &str) -> Result<Vec<Source>> {
    let objects: ManagedObjects = bus
        .call_method(
            Some(sources_bus),
            SOURCE_MANAGER,
            Some("org.freedesktop.DBus.ObjectManager"),
            "GetManagedObjects",
            &(),
        )?
        .body()
        .deserialize()?;
    let mut files: HashMap<String, KeyFile> = HashMap::new();
    for interfaces in objects.values() {
        let Some(source) = interfaces.get(SOURCE_INTERFACE) else {
            continue;
        };
        let text = |key: &str| -> Option<String> {
            source
                .get(key)
                .and_then(|value| String::try_from(value.try_clone().ok()?).ok())
        };
        if let (Some(uid), Some(data)) = (text("UID"), text("Data")) {
            files.insert(uid, KeyFile::parse(&data));
        }
    }
    Ok(select_sources(&files))
}

/// Calendars that are enabled and selected, under an enabled collection
/// whose calendars are turned on.
pub(crate) fn select_sources(files: &HashMap<String, KeyFile>) -> Vec<Source> {
    let mut sources: Vec<Source> = files
        .iter()
        .filter(|(_, file)| file.has_section("Calendar"))
        .filter(|(_, file)| {
            file.flag("Data Source", "Enabled") != Some(false)
                && file.flag("Calendar", "Selected") != Some(false)
        })
        .filter(|(_, file)| {
            let parent = file
                .get("Data Source", "Parent")
                .and_then(|parent| files.get(parent));
            parent.is_none_or(|parent| {
                parent.flag("Data Source", "Enabled") != Some(false)
                    && parent.flag("Collection", "CalendarEnabled") != Some(false)
            })
        })
        .map(|(uid, file)| {
            let parent = file
                .get("Data Source", "Parent")
                .and_then(|parent| files.get(parent));
            let address = [Some(file), parent]
                .into_iter()
                .flatten()
                .flat_map(|f| {
                    [
                        f.get("Authentication", "User"),
                        f.get("Collection", "Identity"),
                    ]
                })
                .flatten()
                .find_map(CalendarParticipantIdentity::normalized_email_address)
                .filter(|a| a.contains('.'));
            Source {
                uid: uid.clone(),
                display_name: file.get("Data Source", "DisplayName").map(str::to_string),
                account_address: address,
            }
        })
        .collect();
    sources.sort_by(|a, b| a.uid.cmp(&b.uid));
    sources
}

/// The GKeyFile text EDS keeps per source (unlocalized keys only).
#[derive(Debug, Default)]
pub(crate) struct KeyFile {
    sections: HashMap<String, HashMap<String, String>>,
}

impl KeyFile {
    pub(crate) fn parse(text: &str) -> Self {
        let mut file = Self::default();
        let mut current = String::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                current = name.to_string();
                file.sections.entry(current.clone()).or_default();
                continue;
            }
            if let Some((key, value)) = line.split_once('=')
                && !key.contains('[')
            {
                file.sections
                    .entry(current.clone())
                    .or_default()
                    .insert(key.trim().to_string(), value.trim().to_string());
            }
        }
        file
    }

    fn has_section(&self, name: &str) -> bool {
        self.sections.contains_key(name)
    }

    fn get(&self, section: &str, key: &str) -> Option<&str> {
        self.sections
            .get(section)?
            .get(key)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }

    fn flag(&self, section: &str, key: &str) -> Option<bool> {
        match self.get(section, key)? {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_enabled_selected_calendars_under_enabled_collections() {
        let mut files = HashMap::new();
        files.insert(
            "system-calendar".to_string(),
            KeyFile::parse(
                "[Data Source]\nDisplayName[de]=Persönlich\nDisplayName=Personal\nEnabled=true\nParent=local-stub\n\n[Calendar]\nBackendName=local\nSelected=true\n",
            ),
        );
        files.insert(
            "goa-google".to_string(),
            KeyFile::parse(
                "[Data Source]\nDisplayName=ana@example.com\nEnabled=true\n\n[Collection]\nBackendName=google\nCalendarEnabled=true\nIdentity=ana@example.com\n",
            ),
        );
        files.insert(
            "goa-google-work".to_string(),
            KeyFile::parse(
                "[Data Source]\nDisplayName=Work\nParent=goa-google\n\n[Calendar]\nBackendName=caldav\n",
            ),
        );
        files.insert(
            "hidden".to_string(),
            KeyFile::parse("[Data Source]\nDisplayName=Hidden\n\n[Calendar]\nSelected=false\n"),
        );
        files.insert(
            "off-collection".to_string(),
            KeyFile::parse(
                "[Data Source]\nDisplayName=Off\n\n[Collection]\nCalendarEnabled=false\n",
            ),
        );
        files.insert(
            "off-child".to_string(),
            KeyFile::parse(
                "[Data Source]\nDisplayName=Child\nParent=off-collection\n\n[Calendar]\n",
            ),
        );
        files.insert(
            "tasks".to_string(),
            KeyFile::parse("[Data Source]\nDisplayName=Tasks\n\n[Task List]\n"),
        );
        let sources = select_sources(&files);
        let names: Vec<(&str, Option<&str>, Option<&str>)> = sources
            .iter()
            .map(|s| {
                (
                    s.uid.as_str(),
                    s.display_name.as_deref(),
                    s.account_address.as_deref(),
                )
            })
            .collect();
        assert_eq!(
            names,
            [
                ("goa-google-work", Some("Work"), Some("ana@example.com")),
                ("system-calendar", Some("Personal"), None),
            ]
        );
    }

    /// Reads the running EDS. Seed a calendar with a daily "Daily standup"
    /// and run inside its session bus:
    /// `LOKALBOT_EDS_LIVE_TEST=1 dbus-run-session -- cargo test -p lokalbot-platform live_evolution -- --ignored`
    #[test]
    #[ignore = "needs a session bus with Evolution Data Server"]
    fn live_evolution_calendar() {
        if std::env::var_os("LOKALBOT_EDS_LIVE_TEST").is_none() {
            return;
        }
        let now = chrono::Utc::now();
        let options = ParseOptions {
            provider: String::new(),
            from: now - chrono::Duration::days(1),
            to: now + chrono::Duration::days(1),
            my_addresses: Vec::new(),
            calendar_title: None,
            default_zone: None,
        };
        let events = fetch(&options)
            .unwrap()
            .expect("Evolution Data Server is installed");
        eprintln!("{events:#?}");
        let standup: Vec<&CalendarEvent> = events
            .iter()
            .filter(|e| e.title == "Daily standup")
            .collect();
        assert!(standup.len() >= 2, "found {standup:?}");
        assert!(standup.iter().all(|e| e.provider == "eds"));
        assert_eq!(standup[0].participant_names, ["Ana Petrović"]);
    }

    #[test]
    fn collects_zone_ids_and_open_properties() {
        let objects = vec![
            "BEGIN:VEVENT\r\nDTSTART;TZID=/freeassociation.sourceforge.net/Europe/Belgrade:\r\n 20260105T100000\r\nDTEND;TZID=\"Customized Time Zone\":20260105T103000\r\nEND:VEVENT".to_string(),
        ];
        let zones: Vec<String> = referenced_zones(&objects).into_iter().collect();
        assert_eq!(
            zones,
            [
                "/freeassociation.sourceforge.net/Europe/Belgrade",
                "Customized Time Zone"
            ]
        );
        let properties: Vec<String> = ["cal-email-address", "'ana@example.com'", "online", "true"]
            .map(String::from)
            .to_vec();
        assert_eq!(
            open_property(&properties, "cal-email-address").as_deref(),
            Some("ana@example.com")
        );
        assert_eq!(open_property(&properties, "missing"), None);
    }
}
