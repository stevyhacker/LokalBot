//! Wayland has no common way to see the focused window, so each compositor
//! is asked through its own interface: Hyprland's IPC socket, Sway's i3 IPC,
//! a short KWin script on KDE Plasma, and on GNOME the "Window Calls" or
//! "Focused Window D-Bus" Shell extension when installed.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context as _, bail};
use serde_json::Value;

use super::linux::{FocusedWindow, WindowProbe, session_bus};

const IPC_TIMEOUT: Duration = Duration::from_millis(500);

fn text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn pid(value: &Value, key: &str) -> Option<u32> {
    value
        .get(key)
        .and_then(Value::as_i64)
        .filter(|pid| *pid > 0)
        .and_then(|pid| u32::try_from(pid).ok())
}

fn unix_request(path: &PathBuf, request: &[u8]) -> anyhow::Result<UnixStream> {
    let mut stream = UnixStream::connect(path)
        .with_context(|| format!("could not connect to {}", path.display()))?;
    stream.set_read_timeout(Some(IPC_TIMEOUT))?;
    stream.set_write_timeout(Some(IPC_TIMEOUT))?;
    stream.write_all(request)?;
    Ok(stream)
}

// ------------------------------------------------------------- Hyprland

/// `j/activewindow` on `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`
/// (`/tmp/hypr/…` before Hyprland 0.40).
pub(super) struct Hyprland {
    socket: PathBuf,
}

fn hyprland_socket() -> anyhow::Result<PathBuf> {
    let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
        .context("HYPRLAND_INSTANCE_SIGNATURE is not set")?;
    let mut candidates = Vec::new();
    if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") {
        candidates.push(
            PathBuf::from(runtime)
                .join("hypr")
                .join(&signature)
                .join(".socket.sock"),
        );
    }
    candidates.push(
        PathBuf::from("/tmp/hypr")
            .join(&signature)
            .join(".socket.sock"),
    );
    candidates
        .into_iter()
        .find(|path| path.exists())
        .context("Hyprland's IPC socket was not found")
}

fn hyprland_request(socket: &PathBuf, request: &[u8]) -> anyhow::Result<String> {
    let mut stream = unix_request(socket, request)?;
    let mut reply = String::new();
    stream.read_to_string(&mut reply)?;
    Ok(reply)
}

impl Hyprland {
    pub(super) fn new() -> anyhow::Result<Self> {
        let mut probe = Self {
            socket: hyprland_socket()?,
        };
        probe.focused()?;
        Ok(probe)
    }
}

/// Class and title of every Hyprland window (`j/clients`).
pub(super) fn hyprland_windows() -> anyhow::Result<Vec<(String, String)>> {
    let reply = hyprland_request(&hyprland_socket()?, b"j/clients")?;
    let value: Value = serde_json::from_str(&reply).context("unexpected Hyprland reply")?;
    Ok(value
        .as_array()
        .map(|clients| {
            clients
                .iter()
                .filter_map(|client| Some((text(client, "class")?, text(client, "title")?)))
                .collect()
        })
        .unwrap_or_default())
}

impl WindowProbe for Hyprland {
    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        parse_hyprland(&hyprland_request(&self.socket, b"j/activewindow")?)
    }

    fn name(&self) -> &'static str {
        "hyprland"
    }
}

fn parse_hyprland(reply: &str) -> anyhow::Result<Option<FocusedWindow>> {
    let value: Value = serde_json::from_str(reply).context("unexpected Hyprland reply")?;
    let class = text(&value, "class").or_else(|| text(&value, "initialClass"));
    let title = text(&value, "title").unwrap_or_default();
    if class.is_none() && title.is_empty() {
        return Ok(None);
    }
    Ok(Some(FocusedWindow {
        title,
        pid: pid(&value, "pid"),
        class,
        instance: None,
        desktop_file: None,
    }))
}

// ------------------------------------------------------------- Sway

/// i3 IPC `GET_TREE` on `$SWAYSOCK`.
pub(super) struct Sway {
    socket: PathBuf,
}

const I3_MAGIC: &[u8; 6] = b"i3-ipc";
const I3_GET_TREE: u32 = 4;

impl Sway {
    pub(super) fn new() -> anyhow::Result<Self> {
        let mut probe = Self {
            socket: sway_socket()?,
        };
        probe.focused()?;
        Ok(probe)
    }
}

fn sway_tree(socket: &PathBuf) -> anyhow::Result<Value> {
    let mut request = I3_MAGIC.to_vec();
    request.extend(0u32.to_ne_bytes());
    request.extend(I3_GET_TREE.to_ne_bytes());
    let mut stream = unix_request(socket, &request)?;
    let mut header = [0u8; 14];
    stream.read_exact(&mut header)?;
    if &header[..6] != I3_MAGIC {
        bail!("unexpected reply from Sway");
    }
    let length = u32::from_ne_bytes([header[6], header[7], header[8], header[9]]) as usize;
    if length > 64 * 1024 * 1024 {
        bail!("Sway's window tree is implausibly large");
    }
    let mut payload = vec![0u8; length];
    stream.read_exact(&mut payload)?;
    serde_json::from_slice(&payload).context("unexpected Sway tree")
}

fn sway_socket() -> anyhow::Result<PathBuf> {
    std::env::var_os("SWAYSOCK")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .context("SWAYSOCK is not set")
}

/// Class (app id) and title of every Sway window.
pub(super) fn sway_windows() -> anyhow::Result<Vec<(String, String)>> {
    fn collect(node: &Value, out: &mut Vec<(String, String)>) {
        let kind = node.get("type").and_then(Value::as_str).unwrap_or("");
        if kind == "con" || kind == "floating_con" {
            let class = text(node, "app_id").or_else(|| {
                node.get("window_properties")
                    .and_then(|properties| text(properties, "class"))
            });
            if let (Some(class), Some(title)) = (class, text(node, "name")) {
                out.push((class, title));
            }
        }
        for key in ["nodes", "floating_nodes"] {
            for child in node
                .get(key)
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                collect(child, out);
            }
        }
    }
    let tree = sway_tree(&sway_socket()?)?;
    let mut out = Vec::new();
    collect(&tree, &mut out);
    Ok(out)
}

impl WindowProbe for Sway {
    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        Ok(parse_sway_tree(&sway_tree(&self.socket)?))
    }

    fn name(&self) -> &'static str {
        "sway"
    }
}

fn find_focused(node: &Value) -> Option<&Value> {
    if node.get("focused").and_then(Value::as_bool) == Some(true) {
        return Some(node);
    }
    ["nodes", "floating_nodes"]
        .iter()
        .filter_map(|key| node.get(*key).and_then(Value::as_array))
        .flatten()
        .find_map(find_focused)
}

fn parse_sway_tree(tree: &Value) -> Option<FocusedWindow> {
    let node = find_focused(tree)?;
    let kind = node.get("type").and_then(Value::as_str).unwrap_or("");
    if kind != "con" && kind != "floating_con" {
        // An empty workspace or an output has the focus.
        return None;
    }
    let properties = node.get("window_properties");
    let class = text(node, "app_id").or_else(|| properties.and_then(|p| text(p, "class")));
    let instance = properties.and_then(|p| text(p, "instance"));
    Some(FocusedWindow {
        title: text(node, "name").unwrap_or_default(),
        pid: pid(node, "pid"),
        class,
        instance,
        desktop_file: None,
    })
}

// ------------------------------------------------------------- KDE Plasma

/// Loads a one-shot KWin script that reports the active window back over
/// D-Bus, the way kdotool does; works with Plasma 5 and 6.
pub(super) struct Kwin {
    bus: zbus::blocking::Connection,
    reports: crossbeam_channel::Receiver<(String, String)>,
    script: PathBuf,
    counter: u64,
}

const PROBE_PATH: &str = "/com/lokalbot/ActivityProbe";
const PROBE_INTERFACE: &str = "com.lokalbot.ActivityProbe";
const KWIN_WAIT: Duration = Duration::from_millis(800);

struct Reporter {
    reports: crossbeam_channel::Sender<(String, String)>,
}

#[zbus::interface(name = "com.lokalbot.ActivityProbe")]
impl Reporter {
    fn result(&self, token: String, payload: String) {
        let _ = self.reports.send((token, payload));
    }
}

impl Kwin {
    pub(super) fn new() -> anyhow::Result<Self> {
        let (tx, reports) = crossbeam_channel::unbounded();
        let bus = zbus::blocking::connection::Builder::session()?
            .method_timeout(Duration::from_secs(2))
            .serve_at(PROBE_PATH, Reporter { reports: tx })?
            .build()?;
        let script = crate::instance::private_runtime_dir()?
            .join(format!("kwin-activity-{}.js", std::process::id()));
        let mut probe = Self {
            bus,
            reports,
            script,
            counter: 0,
        };
        probe
            .focused()
            .context("KWin did not run the window script")?;
        Ok(probe)
    }

    fn script_source(&self, token: &str) -> anyhow::Result<String> {
        let address = self
            .bus
            .unique_name()
            .context("the D-Bus connection has no name")?
            .to_string();
        Ok(format!(
            r#"(function () {{
  function text(v) {{
    if (v === undefined || v === null) return "";
    if (typeof v === "string") return v;
    if (v instanceof ArrayBuffer) {{
      var bytes = new Uint8Array(v), out = "";
      for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
      return out;
    }}
    return String(v);
  }}
  var payload;
  try {{
    var w = workspace.activeWindow || workspace.activeClient;
    payload = w ? {{
      caption: text(w.caption),
      resourceClass: text(w.resourceClass),
      resourceName: text(w.resourceName),
      desktopFileName: text(w.desktopFileName),
      pid: Number(w.pid) || 0
    }} : null;
  }} catch (e) {{
    payload = {{ error: String(e) }};
  }}
  callDBus("{address}", "{PROBE_PATH}", "{PROBE_INTERFACE}", "Result", "{token}", JSON.stringify(payload));
}})();
"#
        ))
    }

    fn run_script(&self, plugin: &str) -> anyhow::Result<()> {
        let scripting = zbus::blocking::Proxy::new(
            &self.bus,
            "org.kde.KWin",
            "/Scripting",
            "org.kde.kwin.Scripting",
        )?;
        let path = self.script.to_string_lossy().into_owned();
        let id: i32 = scripting.call("loadScript", &(path, plugin))?;
        if id < 0 {
            bail!("KWin refused the window script");
        }
        let run = |path: String| -> zbus::Result<()> {
            let script =
                zbus::blocking::Proxy::new(&self.bus, "org.kde.KWin", path, "org.kde.kwin.Script")?;
            script.call("run", &())
        };
        // Plasma 6 path first, then Plasma 5.
        run(format!("/Scripting/Script{id}")).or_else(|_| run(format!("/{id}")))?;
        Ok(())
    }

    fn unload(&self, plugin: &str) {
        let unloaded = zbus::blocking::Proxy::new(
            &self.bus,
            "org.kde.KWin",
            "/Scripting",
            "org.kde.kwin.Scripting",
        )
        .and_then(|scripting| scripting.call::<_, _, bool>("unloadScript", &(plugin,)));
        if let Err(err) = unloaded {
            log::debug!("kwin: unloading {plugin} failed: {err}");
        }
    }
}

impl WindowProbe for Kwin {
    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        self.counter += 1;
        let token = format!("{}-{}", std::process::id(), self.counter);
        let plugin = format!("lokalbot-activity-{token}");
        std::fs::write(&self.script, self.script_source(&token)?)?;
        let ran = self.run_script(&plugin);
        let payload = ran.and_then(|()| {
            let deadline = Instant::now() + KWIN_WAIT;
            loop {
                match self.reports.recv_deadline(deadline) {
                    Ok((reported, payload)) if reported == token => break Ok(payload),
                    Ok(_) => continue,
                    Err(_) => bail!("KWin did not report the active window"),
                }
            }
        });
        self.unload(&plugin);
        parse_kwin(&payload?)
    }

    fn name(&self) -> &'static str {
        "kwin"
    }
}

impl Drop for Kwin {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.script);
    }
}

fn parse_kwin(payload: &str) -> anyhow::Result<Option<FocusedWindow>> {
    let value: Value = serde_json::from_str(payload).context("unexpected KWin reply")?;
    if value.is_null() {
        return Ok(None);
    }
    if let Some(error) = text(&value, "error") {
        bail!("KWin script error: {error}");
    }
    Ok(Some(FocusedWindow {
        title: text(&value, "caption").unwrap_or_default(),
        pid: pid(&value, "pid"),
        class: text(&value, "resourceClass"),
        instance: text(&value, "resourceName"),
        desktop_file: text(&value, "desktopFileName"),
    }))
}

// ------------------------------------------------------------- GNOME

pub(super) const GNOME_HINT: &str = "GNOME on Wayland does not tell apps which window is in front. Install the “Window Calls” GNOME Shell extension (extensions.gnome.org/extension/4724/window-calls) so day memory can record apps and window titles; until then it records nothing.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum GnomeExtension {
    /// `org.gnome.Shell.Extensions.Windows` ("Window Calls").
    WindowCalls,
    /// `org.gnome.shell.extensions.FocusedWindow` ("Focused Window D-Bus").
    FocusedWindow,
}

/// Looks for a supported extension again every minute, so installing one
/// starts tracking without a restart.
pub(super) struct Gnome {
    bus: zbus::blocking::Connection,
    extension: Option<GnomeExtension>,
    checked_at: Option<Instant>,
}

const RECHECK: Duration = Duration::from_secs(60);

impl Gnome {
    pub(super) fn new() -> anyhow::Result<Self> {
        let mut probe = Self {
            bus: session_bus()?,
            extension: None,
            checked_at: None,
        };
        probe.detect();
        if probe.extension.is_none() {
            log::info!("activity: no GNOME window extension found");
        }
        Ok(probe)
    }

    fn call(
        &self,
        path: &str,
        interface: &str,
        method: &str,
        args: &(impl serde::Serialize + zbus::zvariant::DynamicType),
    ) -> anyhow::Result<String> {
        let reply =
            self.bus
                .call_method(Some("org.gnome.Shell"), path, Some(interface), method, args)?;
        Ok(reply.body().deserialize::<String>()?)
    }

    fn detect(&mut self) {
        self.checked_at = Some(Instant::now());
        self.extension = [GnomeExtension::WindowCalls, GnomeExtension::FocusedWindow]
            .into_iter()
            .find(|extension| match extension {
                GnomeExtension::WindowCalls => self.window_calls_list().is_ok(),
                // Fails while nothing is focused, so only "unknown" counts.
                GnomeExtension::FocusedWindow => match self.focused_window_get() {
                    Ok(_) => true,
                    Err(err) => {
                        !format!("{err:#}").contains("UnknownObject")
                            && !format!("{err:#}").contains("UnknownMethod")
                            && !format!("{err:#}").contains("UnknownInterface")
                    }
                },
            });
    }

    fn window_calls_list(&self) -> anyhow::Result<String> {
        self.call(
            "/org/gnome/Shell/Extensions/Windows",
            "org.gnome.Shell.Extensions.Windows",
            "List",
            &(),
        )
    }

    fn focused_window_get(&self) -> anyhow::Result<String> {
        self.call(
            "/org/gnome/shell/extensions/FocusedWindow",
            "org.gnome.shell.extensions.FocusedWindow",
            "Get",
            &(),
        )
    }

    fn read(&self, extension: GnomeExtension) -> anyhow::Result<Option<FocusedWindow>> {
        match extension {
            GnomeExtension::WindowCalls => {
                let list = self.window_calls_list()?;
                let Some((id, mut window)) = parse_window_calls(&list)? else {
                    return Ok(None);
                };
                if window.title.is_empty()
                    && let Some(id) = id
                {
                    window.title = self
                        .call(
                            "/org/gnome/Shell/Extensions/Windows",
                            "org.gnome.Shell.Extensions.Windows",
                            "GetTitle",
                            &(id,),
                        )
                        .unwrap_or_default();
                }
                Ok(Some(window))
            }
            GnomeExtension::FocusedWindow => match self.focused_window_get() {
                Ok(json) => Ok(parse_gnome_window(&serde_json::from_str(&json)?)),
                // Raised while nothing has focus.
                Err(_) => Ok(None),
            },
        }
    }
}

impl WindowProbe for Gnome {
    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        if self.extension.is_none() && self.checked_at.is_none_or(|at| at.elapsed() > RECHECK) {
            self.detect();
        }
        let Some(extension) = self.extension else {
            return Ok(None);
        };
        match self.read(extension) {
            Ok(window) => Ok(window),
            Err(err) => {
                // Disabled or removed since: look again later.
                log::info!("activity: GNOME extension stopped answering: {err:#}");
                self.extension = None;
                Ok(None)
            }
        }
    }

    fn name(&self) -> &'static str {
        "gnome-extension"
    }

    fn limitation(&self) -> Option<String> {
        self.extension.is_none().then(|| GNOME_HINT.to_string())
    }
}

fn parse_gnome_window(value: &Value) -> Option<FocusedWindow> {
    let class = text(value, "wm_class");
    let title = text(value, "title").unwrap_or_default();
    if class.is_none() && title.is_empty() {
        return None;
    }
    Some(FocusedWindow {
        title,
        pid: pid(value, "pid"),
        class,
        instance: text(value, "wm_class_instance"),
        desktop_file: None,
    })
}

/// The focused entry of Window Calls' `List`, with its id for `GetTitle`.
fn parse_window_calls(list: &str) -> anyhow::Result<Option<(Option<u32>, FocusedWindow)>> {
    let value: Value = serde_json::from_str(list).context("unexpected Window Calls reply")?;
    let Some(entries) = value.as_array() else {
        bail!("unexpected Window Calls reply");
    };
    Ok(entries
        .iter()
        .find(|entry| entry.get("focus").and_then(Value::as_bool) == Some(true))
        .and_then(|entry| {
            let id = entry
                .get("id")
                .and_then(Value::as_u64)
                .and_then(|id| u32::try_from(id).ok());
            parse_gnome_window(entry).map(|window| (id, window))
        }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hyprland_replies() {
        let reply = r#"{"address":"0x5","class":"firefox","title":"Docs — Mozilla Firefox","initialClass":"firefox","pid":4242,"xwayland":false}"#;
        assert_eq!(
            parse_hyprland(reply).unwrap(),
            Some(FocusedWindow {
                title: "Docs — Mozilla Firefox".into(),
                pid: Some(4242),
                class: Some("firefox".into()),
                ..Default::default()
            })
        );
        assert_eq!(parse_hyprland("{}").unwrap(), None);
        assert!(parse_hyprland("Invalid").is_err());
    }

    #[test]
    fn sway_trees() {
        let tree = serde_json::json!({
            "type": "root", "focused": false, "nodes": [{
                "type": "output", "focused": false, "nodes": [{
                    "type": "workspace", "focused": false, "nodes": [
                        {"type": "con", "focused": false, "name": "other", "app_id": "foot", "pid": 1},
                        {"type": "con", "focused": true, "name": "README.md - Code", "app_id": null,
                         "pid": 77, "window_properties": {"class": "Code", "instance": "code"}}
                    ], "floating_nodes": []
                }]
            }]
        });
        assert_eq!(
            parse_sway_tree(&tree),
            Some(FocusedWindow {
                title: "README.md - Code".into(),
                pid: Some(77),
                class: Some("Code".into()),
                instance: Some("code".into()),
                desktop_file: None,
            })
        );
        let empty = serde_json::json!({"type": "root", "nodes": [
            {"type": "workspace", "focused": true, "nodes": []}
        ]});
        assert_eq!(parse_sway_tree(&empty), None);
        let floating = serde_json::json!({"type": "workspace", "nodes": [], "floating_nodes": [
            {"type": "floating_con", "focused": true, "name": "calc", "app_id": "qalculate", "pid": 9}
        ]});
        assert_eq!(
            parse_sway_tree(&floating).map(|w| w.title),
            Some("calc".into())
        );
    }

    #[test]
    fn kwin_reports() {
        let payload = r#"{"caption":"Inbox — Thunderbird","resourceClass":"thunderbird","resourceName":"Mail","desktopFileName":"org.mozilla.Thunderbird","pid":321}"#;
        let window = parse_kwin(payload).unwrap().unwrap();
        assert_eq!(window.title, "Inbox — Thunderbird");
        assert_eq!(
            window.desktop_file.as_deref(),
            Some("org.mozilla.Thunderbird")
        );
        assert_eq!(window.pid, Some(321));
        assert_eq!(parse_kwin("null").unwrap(), None);
        assert!(parse_kwin(r#"{"error":"ReferenceError"}"#).is_err());
    }

    #[test]
    fn gnome_extension_replies() {
        let list = r#"[{"wm_class":"org.gnome.Nautilus","wm_class_instance":"org.gnome.Nautilus","pid":10,"id":111,"focus":false},
                       {"wm_class":"firefox","wm_class_instance":"firefox","pid":20,"id":222,"focus":true}]"#;
        let (id, window) = parse_window_calls(list).unwrap().unwrap();
        assert_eq!(id, Some(222));
        assert_eq!(window.class.as_deref(), Some("firefox"));
        assert_eq!(window.title, "");
        assert_eq!(parse_window_calls("[]").unwrap(), None);
        let focused: Value = serde_json::from_str(
            r#"{"title":"Terminal","wm_class":"org.gnome.Ptyxis","pid":5,"focus":true}"#,
        )
        .unwrap();
        assert_eq!(
            parse_gnome_window(&focused).map(|w| w.title),
            Some("Terminal".into())
        );
    }
}
