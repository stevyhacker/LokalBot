//! Settings → Phones & tablets (`CompanionSettingsView.swift`). Turning sharing
//! on starts a listener for paired devices on the local network and Tailscale;
//! everything below the switch only exists while it is on.

use std::sync::Arc;
use std::time::Duration;

use chrono::{Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariant};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, IntoElement, ParentElement as _,
    RenderImage, SharedString, Styled as _, Subscription, Window, div, img, px,
};
use lokalbot_core::Settings;
use lokalbot_engine::companion::{HistoryWindow, clamped_port, device_display_name};
use lokalbot_engine::{
    Command, CompanionCommand, CompanionDevice, CompanionNetwork, CompanionPairing,
    CompanionSnapshot, CompanionStatus, PairingRequest,
};

use super::{Section, SettingsPage, sync_input};
use crate::i18n::h_flex;
use crate::state::{AppData, SettingsCategory};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, settings_row};

const QR_SIZE: f32 = 196.;
/// Pixels per QR module, and the blank border a scanner needs around the code.
const QR_SCALE: u32 = 6;
const QR_QUIET_MODULES: u32 = 4;
/// Enough to show every code a device needs.
const COUNTDOWN_TICK: Duration = Duration::from_secs(1);

pub struct DevicesState {
    port: Entity<InputState>,
    /// The drawn code and the offer it's for.
    code: Option<(String, Arc<RenderImage>)>,
    released_codes: Vec<Arc<RenderImage>>,
    counting_down: bool,
}

impl DevicesState {
    pub fn new(settings: &Settings, window: &mut Window, cx: &mut Context<SettingsPage>) -> Self {
        let port = cx.new(|cx| {
            InputState::new(window, cx).default_value(settings.companion_port.to_string())
        });
        Self {
            port,
            code: None,
            released_codes: Vec::new(),
            counting_down: false,
        }
    }

    /// The port applies when editing ends, so a half-typed number never
    /// restarts the listener.
    pub fn subscribe(
        state: &Self,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) -> Vec<Subscription> {
        vec![cx.subscribe_in(
            &state.port,
            window,
            |page, input, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    let text = input.read(cx).value().to_string();
                    let current = page.data.read(cx).settings.companion_port;
                    let port = parsed_port(&text, current);
                    if port.to_string() != text {
                        input.update(cx, |input, cx| {
                            input.set_value(port.to_string(), window, cx)
                        });
                    }
                    page.update_settings(move |s| s.companion_port = port, cx);
                }
            },
        )]
    }

    pub fn sync(&mut self, old: &Settings, new: &Settings, window: &mut Window, cx: &mut App) {
        if old.companion_port != new.companion_port {
            sync_input(&self.port, &new.companion_port.to_string(), window, cx);
        }
    }
}

/// A number clamped to the range a listener may use, or the current port when
/// it isn't a number.
fn parsed_port(text: &str, current: u16) -> u16 {
    match text.trim().parse::<u64>() {
        Ok(value) => clamped_port(u16::try_from(value).unwrap_or(u16::MAX)),
        Err(_) => current,
    }
}

fn send(command: CompanionCommand, cx: &App) {
    crate::bridge::send(Command::Companion(command), cx);
}

impl SettingsPage {
    pub(super) fn devices_sections(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<Section> {
        for image in std::mem::take(&mut self.devices.released_codes) {
            cx.drop_image(image, Some(window));
        }
        let settings = self.data.read(cx).settings.clone();
        let snapshot = self.data.read(cx).companion.clone();
        let mut top = Section::new(lokalbot_i18n::tr("Phones & tablets")).row(
            "settings.companionSharingEnabled",
            self.toggle(
                "settings.companionSharingEnabled",
                lokalbot_i18n::tr("Share with my phones and tablets"),
                Some(lokalbot_i18n::tr(
                    "Your iPhone, iPad, or Android device keeps an encrypted copy of what you choose below and reaches this computer over your local network or Tailscale only. Nothing listens while this is off.",
                )),
                settings.companion_sharing_enabled,
                |s, on| s.companion_sharing_enabled = on,
                cx,
            ),
        );
        if settings.companion_sharing_enabled {
            top = top.row("settings.companionStatus", status_row(&snapshot, cx));
        }
        let mut sections = vec![top];
        if settings.companion_sharing_enabled {
            sections.push(self.devices_section(&snapshot, cx));
            sections.push(self.shared_data_section(&settings, cx));
            sections.push(self.questions_section(&settings, cx));
            sections.push(self.network_section(&settings, &snapshot, cx));
        } else {
            // A code held after sharing stopped would be a dead picture.
            self.release_code();
        }
        sections
    }

    fn devices_section(&mut self, snapshot: &CompanionSnapshot, cx: &mut Context<Self>) -> Section {
        let listening = matches!(snapshot.status, CompanionStatus::Listening { .. });
        let adding: AnyElement = match &snapshot.pairing {
            Some(pairing) => self.pairing_panel(pairing, cx),
            None => {
                self.release_code();
                settings_row::row(
                    "settings.companionDevices",
                    lokalbot_i18n::tr("Add a device"),
                    Some(
                        lokalbot_i18n::tr(
                            "Shows a code to scan with LokalBot on your phone or tablet. The device must be able to reach this computer.",
                        )
                        .into(),
                    ),
                    Button::new("settings.companionAddDevice")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Add a Device…"))
                        .disabled(!listening)
                        .on_click(|_, _, cx| send(CompanionCommand::BeginPairing, cx)),
                    self.is_focused("settings.companionDevices"),
                    cx,
                )
                .into_any_element()
            }
        };
        let mut section =
            Section::new(lokalbot_i18n::tr("Devices")).row("settings.companionDevices", adding);
        if snapshot.devices.is_empty() {
            section = section.row(
                "settings.companionNoDevices",
                settings_row::content_row(
                    "settings.companionNoDevices",
                    settings_row::help(lokalbot_i18n::tr("No devices yet."), cx),
                    false,
                    cx,
                ),
            );
        }
        for device in &snapshot.devices {
            let connected = snapshot.connected_device_ids.contains(&device.id);
            section = section.row(
                "settings.companionDevice",
                device_row(device, connected, cx),
            );
        }
        if let Some(error) = &snapshot.action_error {
            section = section.row(
                "settings.companionDevicesError",
                settings_row::content_row(
                    "settings.companionDevicesError",
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(cx.lb().attention_text)
                        .child(ui::text::paragraph(error.clone())),
                    false,
                    cx,
                ),
            );
        }
        section
    }

    fn release_code(&mut self) {
        if let Some((_, image)) = self.devices.code.take() {
            self.devices.released_codes.push(image);
        }
    }

    fn pairing_panel(&mut self, pairing: &CompanionPairing, cx: &mut Context<Self>) -> AnyElement {
        if self
            .devices
            .code
            .as_ref()
            .is_none_or(|(payload, _)| *payload != pairing.qr_payload)
        {
            self.release_code();
            self.devices.code =
                qr_image(&pairing.qr_payload).map(|image| (pairing.qr_payload.clone(), image));
        }
        self.keep_counting_down(cx);
        let lb = cx.lb().clone();
        let remaining = (pairing.expires_at - Utc::now()).num_seconds().max(0);
        let expiry = if remaining > 0 {
            lokalbot_i18n::format(
                "Expires in {time}",
                &[("time", format!("{}:{:02}", remaining / 60, remaining % 60))],
            )
        } else {
            lokalbot_i18n::tr("This code expired. Cancel and add the device again.").to_string()
        };
        settings_row::content_row(
            "settings.companionPairing",
            h_flex()
                .gap(px(16.))
                .items_start()
                .flex_wrap()
                .when_some(self.devices.code.as_ref(), |this, (_, image)| {
                    this.child(
                        div()
                            .flex_none()
                            .p(px(8.))
                            .rounded(metric::GROUP_RADIUS)
                            .bg(gpui_kit::white())
                            .child(img(image.clone()).size(px(QR_SIZE))),
                    )
                })
                .child(
                    v_flex()
                        .flex_1()
                        .min_w(px(220.))
                        .gap(px(8.))
                        .child(
                            div()
                                .text_size(ty::SECTION)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(ui::text::paragraph(lokalbot_i18n::tr(
                                    "Scan with LokalBot on your phone or tablet",
                                ))),
                        )
                        .child(settings_row::help(
                            lokalbot_i18n::tr(
                                "Open LokalBot on the device, choose Pair with a Mac, and point the camera at this code. Then allow the device here.",
                            ),
                            cx,
                        ))
                        .child(settings_row::help(expiry, cx))
                        .child(
                            h_flex().child(
                                Button::new("settings.companionCancelPairing")
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Cancel"))
                                    .on_click(|_, _, cx| {
                                        send(CompanionCommand::CancelPairing, cx)
                                    }),
                            ),
                        ),
                ),
            self.is_focused("settings.companionDevices"),
            cx,
        )
        .into_any_element()
    }

    /// Redraws once a second while a code is on screen, for its countdown.
    fn keep_counting_down(&mut self, cx: &mut Context<Self>) {
        if self.devices.counting_down {
            return;
        }
        self.devices.counting_down = true;
        cx.spawn(async move |page, cx| {
            loop {
                cx.background_executor().timer(COUNTDOWN_TICK).await;
                let keep_going = page
                    .update(cx, |page, cx| {
                        let showing = {
                            let data = page.data.read(cx);
                            data.section == crate::state::Section::Settings
                                && data.settings_category == SettingsCategory::Devices
                                && data.companion.pairing.is_some()
                        };
                        if showing {
                            cx.notify();
                        } else {
                            page.devices.counting_down = false;
                        }
                        showing
                    })
                    .unwrap_or(false);
                if !keep_going {
                    return;
                }
            }
        })
        .detach();
    }

    fn shared_data_section(&self, settings: &Settings, cx: &mut Context<Self>) -> Section {
        let meetings_on = settings.companion_share_meetings;
        let timeline_on = settings.companion_share_timeline;
        Section::new(lokalbot_i18n::tr("What your devices receive"))
            .row(
                "settings.companionShareMeetings",
                self.toggle(
                    "settings.companionShareMeetings",
                    lokalbot_i18n::tr("Share meetings"),
                    Some(lokalbot_i18n::tr(
                        "Titles, times, people's names, projects, summaries, your notes, actions, decisions, and open questions.",
                    )),
                    settings.companion_share_meetings,
                    |s, on| s.companion_share_meetings = on,
                    cx,
                ),
            )
            .row(
                "settings.companionShareTranscripts",
                self.dependent_toggle(
                    "settings.companionShareTranscripts",
                    lokalbot_i18n::tr("Share transcripts"),
                    lokalbot_i18n::tr("Transcript text with times and speaker names."),
                    settings.companion_share_transcripts,
                    meetings_on,
                    |s, on| s.companion_share_transcripts = on,
                    cx,
                ),
            )
            .row(
                "settings.companionShareDigests",
                self.toggle(
                    "settings.companionShareDigests",
                    lokalbot_i18n::tr("Share Day Digests"),
                    Some(lokalbot_i18n::tr(
                        "Each day's digest. Screen citations show only their time.",
                    )),
                    settings.companion_share_digests,
                    |s, on| s.companion_share_digests = on,
                    cx,
                ),
            )
            .row(
                "settings.companionShareTimeline",
                self.toggle(
                    "settings.companionShareTimeline",
                    lokalbot_i18n::tr("Share the Timeline"),
                    Some(lokalbot_i18n::tr(
                        "Work sessions, apps, time per project, coding-agent sessions, and saved moments.",
                    )),
                    settings.companion_share_timeline,
                    |s, on| s.companion_share_timeline = on,
                    cx,
                ),
            )
            .row(
                "settings.companionShareWindowTitles",
                self.dependent_toggle(
                    "settings.companionShareWindowTitles",
                    lokalbot_i18n::tr("Include window titles"),
                    lokalbot_i18n::tr(
                        "Titles this computer's retention already cleared stay cleared.",
                    ),
                    settings.companion_share_window_titles,
                    timeline_on,
                    |s, on| s.companion_share_window_titles = on,
                    cx,
                ),
            )
            .row(
                "settings.companionSharePeople",
                self.toggle(
                    "settings.companionSharePeople",
                    lokalbot_i18n::tr("Share people"),
                    Some(lokalbot_i18n::tr(
                        "Names, open work, decisions, and meetings together.",
                    )),
                    settings.companion_share_people,
                    |s, on| s.companion_share_people = on,
                    cx,
                ),
            )
            .row(
                "settings.companionShareProjects",
                self.toggle(
                    "settings.companionShareProjects",
                    lokalbot_i18n::tr("Share projects"),
                    Some(lokalbot_i18n::tr(
                        "Tracked projects with where they stand, actions, decisions, and time.",
                    )),
                    settings.companion_share_projects,
                    |s, on| s.companion_share_projects = on,
                    cx,
                ),
            )
            .row(
                "settings.companionHistory",
                self.choice(
                    "settings.companionHistory",
                    lokalbot_i18n::tr("Shared history"),
                    Some(
                        lokalbot_i18n::tr("Older records are removed from your devices.").into(),
                    ),
                    HistoryWindow::ALL
                        .iter()
                        .map(|window| {
                            (
                                window.days(),
                                SharedString::from(history_label(*window)),
                            )
                        })
                        .collect(),
                    HistoryWindow::from_days(settings.companion_history).days(),
                    |s, days| s.companion_history = days,
                    cx,
                ),
            )
            .row(
                "settings.companionNeverShared",
                settings_row::content_row(
                    "settings.companionNeverShared",
                    settings_row::help(
                        lokalbot_i18n::tr(
                            "Never shared: attendee email addresses, speaker evidence and voice profiles, screenshots and screen text, email, Personal Context, overnight memory, settings, and keys.",
                        ),
                        cx,
                    ),
                    false,
                    cx,
                ),
            )
    }

    /// A switch that means nothing without the one above it.
    #[allow(clippy::too_many_arguments)]
    fn dependent_toggle(
        &self,
        id: &'static str,
        title: &'static str,
        help: &'static str,
        value: bool,
        enabled: bool,
        set: fn(&mut Settings, bool),
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let data = self.data.clone();
        settings_row::row(
            id,
            title,
            Some(help.into()),
            settings_row::switch(id, value, move |on, _, cx| {
                data.update(cx, |data, cx| data.update_settings(|s| set(s, on), cx))
            })
            .disabled(!enabled),
            self.is_focused(id),
            cx,
        )
        .into_any_element()
    }

    fn questions_section(&self, settings: &Settings, cx: &mut Context<Self>) -> Section {
        let mut section = Section::new(lokalbot_i18n::tr("Questions")).row(
            "settings.companionAnswersQuestions",
            self.toggle(
                "settings.companionAnswersQuestions",
                lokalbot_i18n::tr("Answer questions from my devices"),
                Some(lokalbot_i18n::tr(
                    "This computer answers with your Think model and its approvals, from the meetings and Timeline you share. Screen memory is never searched for a device.",
                )),
                settings.companion_answers_questions,
                |s, on| s.companion_answers_questions = on,
                cx,
            ),
        );
        if settings.companion_answers_questions {
            let hosts = self.data.read(cx).remote_hosts.clone();
            let disclosure = if hosts.is_empty() {
                lokalbot_i18n::tr("Answers are written on this computer.").to_string()
            } else {
                lokalbot_i18n::format(
                    "Questions from your devices and the context they need go to your approved Think server ({server}).",
                    &[(
                        "server",
                        hosts
                            .iter()
                            .map(SharedString::as_ref)
                            .collect::<Vec<_>>()
                            .join(", "),
                    )],
                )
            };
            section = section.row(
                "settings.companionQuestionsDisclosure",
                settings_row::content_row(
                    "settings.companionQuestionsDisclosure",
                    settings_row::help(disclosure, cx),
                    false,
                    cx,
                ),
            );
        }
        section
    }

    fn network_section(
        &self,
        settings: &Settings,
        snapshot: &CompanionSnapshot,
        cx: &mut Context<Self>,
    ) -> Section {
        let mut section = Section::new(lokalbot_i18n::tr("Network"))
            .row(
                "settings.companionPort",
                settings_row::row(
                    "settings.companionPort",
                    lokalbot_i18n::tr("Port"),
                    Some(
                        lokalbot_i18n::tr("Change it only if another app already uses this port.")
                            .into(),
                    ),
                    div().w(px(90.)).child(Input::new(&self.devices.port)),
                    self.is_focused("settings.companionPort"),
                    cx,
                ),
            )
            .row(
                "settings.companionAdvertisesOnBonjour",
                self.toggle(
                    "settings.companionAdvertisesOnBonjour",
                    lokalbot_i18n::tr("Advertise on the local network"),
                    Some(lokalbot_i18n::tr(
                        "Devices on the same Wi-Fi find this computer by itself. Turn off to use only the addresses saved when a device paired, such as Tailscale.",
                    )),
                    settings.companion_advertises_on_bonjour,
                    |s, on| s.companion_advertises_on_bonjour = on,
                    cx,
                ),
            );
        for (id, text) in network_notes(settings, snapshot) {
            section = section.row(
                id,
                settings_row::content_row(
                    id,
                    div()
                        .text_size(ty::SECONDARY)
                        .line_height(px(18.))
                        .text_color(cx.lb().attention_text)
                        .child(ui::text::paragraph(text)),
                    false,
                    cx,
                ),
            );
        }
        section.row(
            "settings.companionFirewall",
            settings_row::content_row(
                "settings.companionFirewall",
                v_flex()
                    .gap(px(8.))
                    .child(settings_row::help(firewall_note(settings.companion_port), cx))
                    .child(self.details(
                        "settings.companionHowItWorks",
                        lokalbot_i18n::tr("How it works"),
                        lokalbot_i18n::tr(
                            "This computer accepts connections only from private network addresses and Tailscale, and only from devices you paired by scanning a code and allowing them here. Every connection is end-to-end encrypted with the Noise protocol. Phones sync whenever they can reach this computer and keep their copy for offline reading. LokalBot runs no server and receives nothing.",
                        ),
                        cx,
                    )),
                self.is_focused("settings.companionFirewall"),
                cx,
            ),
        )
    }
}

fn status_row(snapshot: &CompanionSnapshot, cx: &App) -> AnyElement {
    let lb = cx.lb().clone();
    let value = |text: String, color| {
        div()
            .text_size(ty::BODY)
            .text_color(color)
            .child(SharedString::from(text))
    };
    let control = match &snapshot.status {
        CompanionStatus::Off => {
            value(lokalbot_i18n::tr("Off").to_string(), lb.text_secondary).into_any_element()
        }
        CompanionStatus::Starting => value(
            lokalbot_i18n::tr("Starting…").to_string(),
            lb.text_secondary,
        )
        .into_any_element(),
        CompanionStatus::Listening { port } => value(
            lokalbot_i18n::format("Listening on port {port}", &[("port", port.to_string())]),
            lb.accent_text,
        )
        .into_any_element(),
        CompanionStatus::Failed(message) => v_flex()
            .gap(px(4.))
            .items_end()
            .max_w(px(420.))
            .child(value(
                lokalbot_i18n::tr("Unavailable").to_string(),
                lb.attention_text,
            ))
            .child(settings_row::help(message.clone(), cx))
            .into_any_element(),
    };
    settings_row::row(
        "settings.companionStatus",
        lokalbot_i18n::tr("Status"),
        None,
        control,
        false,
        cx,
    )
    .into_any_element()
}

fn device_row(device: &CompanionDevice, connected: bool, cx: &App) -> AnyElement {
    let lb = cx.lb().clone();
    let confirm = device.clone();
    settings_row::content_row(
        SharedString::from(format!("settings.companionDevice-{}", device.id)),
        h_flex()
            .w_full()
            .gap(px(10.))
            .items_center()
            .child(ui::icon(
                device_icon(&device.platform),
                px(18.),
                lb.accent_text,
            ))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(ui::text::paragraph(device_display_name(&device.name))),
                    )
                    .child(settings_row::help(device_detail(device, connected), cx)),
            )
            .child(
                Button::new(SharedString::from(format!(
                    "settings.companionRemove-{}",
                    device.id
                )))
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Remove…"))
                .on_click(move |_, window, cx| confirm_removal(&confirm, window, cx)),
            ),
        false,
        cx,
    )
    .into_any_element()
}

pub(crate) fn history_label(window: HistoryWindow) -> &'static str {
    match window {
        HistoryWindow::All => lokalbot_i18n::tr("All history"),
        HistoryWindow::Days30 => lokalbot_i18n::tr("Last 30 days"),
        HistoryWindow::Days90 => lokalbot_i18n::tr("Last 90 days"),
        HistoryWindow::Days365 => lokalbot_i18n::tr("Last year"),
    }
}

/// A device names its own platform; only the known ones are translated.
fn platform_label(raw: &str) -> String {
    match raw.to_lowercase().as_str() {
        "ios" => lokalbot_i18n::tr("iPhone").to_string(),
        "ipados" => lokalbot_i18n::tr("iPad").to_string(),
        "android" => lokalbot_i18n::tr("Android").to_string(),
        "" => lokalbot_i18n::tr("Device").to_string(),
        _ => raw.to_string(),
    }
}

fn device_icon(platform: &str) -> Ico {
    if platform.eq_ignore_ascii_case("ipados") {
        Ico::Tablet
    } else {
        Ico::Smartphone
    }
}

fn device_detail(device: &CompanionDevice, connected: bool) -> String {
    let mut parts = vec![platform_label(&device.platform)];
    if connected {
        parts.push(lokalbot_i18n::tr("Connected").to_string());
    } else if let Some(seen) = device.last_seen_at {
        parts.push(lokalbot_i18n::format(
            "Last seen {when}",
            &[("when", ui::profile::relative_day(seen, Local::now()))],
        ));
    } else {
        parts.push(lokalbot_i18n::tr("Not connected yet").to_string());
    }
    if let Some(network) = device
        .last_address
        .as_deref()
        .and_then(CompanionNetwork::classify)
    {
        parts.push(
            match network {
                CompanionNetwork::Tailscale => lokalbot_i18n::tr("Tailscale"),
                CompanionNetwork::LocalNetwork => lokalbot_i18n::tr("Local network"),
            }
            .to_string(),
        );
    }
    parts.join(" · ")
}

fn confirm_removal(device: &CompanionDevice, window: &mut Window, cx: &mut App) {
    let id = device.id.clone();
    let name = device_display_name(&device.name);
    window.open_alert_dialog(cx, move |alert, _, _| {
        let id = id.clone();
        alert
            .title(lokalbot_i18n::format(
                "Remove “{name}”?",
                &[("name", name.clone())],
            ))
            .description(lokalbot_i18n::tr(
                "It can no longer connect, and if it is connected now it erases its copy.",
            ))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Remove Device"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                send(CompanionCommand::RemoveDevice(id.clone()), cx);
                true
            })
    });
}

/// What stands between a device and this computer that the person can act on.
fn network_notes(settings: &Settings, snapshot: &CompanionSnapshot) -> Vec<(&'static str, String)> {
    let mut notes = Vec::new();
    if !matches!(snapshot.status, CompanionStatus::Listening { .. }) {
        return notes;
    }
    if snapshot.addresses.is_empty() {
        notes.push((
            "settings.companionNoAddress",
            lokalbot_i18n::tr(
                "This computer has no private network or Tailscale address, so no device can reach it right now.",
            )
            .to_string(),
        ));
    }
    if settings.companion_advertises_on_bonjour
        && let Some(error) = &snapshot.discovery_error
    {
        notes.push((
            "settings.companionDiscoveryError",
            lokalbot_i18n::format(
                "Devices can't find this computer by themselves right now ({error}). Devices you paired still try the addresses they saved.",
                &[("error", error.clone())],
            ),
        ));
    }
    notes
}

/// LokalBot can't see past a firewall, so it says what to check.
#[cfg(windows)]
fn firewall_note(_port: u16) -> String {
    lokalbot_i18n::tr(
        "Windows Firewall may ask whether LokalBot can accept connections when sharing starts. Choose private networks. If a device can't connect, allow LokalBot in Windows Security → Firewall & network protection.",
    )
    .to_string()
}

#[cfg(not(windows))]
fn firewall_note(port: u16) -> String {
    lokalbot_i18n::format(
        "If a device can't connect, a firewall on this computer may be blocking it. Allow incoming TCP on port {port} from your local network and Tailscale, and UDP on port 5353 so devices can find it.",
        &[("port", port.to_string())],
    )
}

/// One grid cell per module, for a code scanners read at error level M, as
/// on the Mac.
fn qr_modules(payload: &str) -> Option<(u32, Vec<bool>)> {
    let code =
        qrcode::QrCode::with_error_correction_level(payload.as_bytes(), qrcode::EcLevel::M).ok()?;
    let width = u32::try_from(code.width()).ok()?;
    let modules = code
        .to_colors()
        .iter()
        .map(|color| *color == qrcode::Color::Dark)
        .collect();
    Some((width, modules))
}

fn qr_pixels(width: u32, modules: &[bool]) -> image::RgbaImage {
    let side = (width + 2 * QR_QUIET_MODULES) * QR_SCALE;
    image::RgbaImage::from_fn(side, side, |x, y| {
        let cell = |value: u32| (value / QR_SCALE).checked_sub(QR_QUIET_MODULES);
        let dark = match (cell(x), cell(y)) {
            (Some(column), Some(row)) if column < width && row < width => {
                modules[(row * width + column) as usize]
            }
            _ => false,
        };
        // Black and white read the same in GPUI's BGRA.
        image::Rgba(if dark {
            [0, 0, 0, 255]
        } else {
            [255, 255, 255, 255]
        })
    })
}

fn qr_image(payload: &str) -> Option<Arc<RenderImage>> {
    let (width, modules) = qr_modules(payload)?;
    let pixels = qr_pixels(width, &modules);
    Some(Arc::new(RenderImage::new(vec![image::Frame::new(pixels)])))
}

// ---------------------------------------------------------- the pairing prompt

/// Brings the window up with the question a scanning device is waiting on, or
/// takes it away once the request is gone. Called off the engine's update.
pub(crate) fn pairing_prompt_changed(
    data: Entity<AppData>,
    request: Option<PairingRequest>,
    cx: &mut App,
) {
    let Some(request) = request else {
        if data
            .update(cx, |data, _| data.pairing_prompt.take())
            .is_some()
        {
            on_main_window(cx, |window, cx| window.close_dialog(cx));
        }
        return;
    };
    data.update(cx, |data, cx| {
        data.pairing_prompt = Some(request.id);
        data.open_settings(SettingsCategory::Devices, cx);
    });
    crate::desktop::show_main_window(cx);
    on_main_window(cx, move |window, cx| {
        open_pairing_prompt(data.clone(), request.clone(), window, cx)
    });
}

fn on_main_window(cx: &mut App, action: impl FnOnce(&mut Window, &mut App)) {
    let handle = crate::desktop::desktop(cx)
        .and_then(|desktop| *desktop.main_window.lock())
        .or_else(|| cx.windows().into_iter().next());
    if let Some(handle) = handle {
        let _ = handle.update(cx, |_, window, cx| action(window, cx));
    }
}

fn open_pairing_prompt(
    data: Entity<AppData>,
    request: PairingRequest,
    window: &mut Window,
    cx: &mut App,
) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let answer = {
            let data = data.clone();
            let id = request.id;
            move |allow: bool, cx: &mut App| {
                data.update(cx, |data, _| data.pairing_prompt = None);
                send(CompanionCommand::AnswerPairing { id, allow }, cx);
            }
        };
        let (allow, refuse) = (answer.clone(), answer);
        alert
            .title(lokalbot_i18n::format(
                "Allow “{name}” to read your shared LokalBot data?",
                &[("name", request.device_name.clone())],
            ))
            .description(lokalbot_i18n::format(
                "This {platform} scanned the code in Settings → Phones & tablets. It will receive an encrypted copy of what you share, over your local network or Tailscale. You can remove it at any time.",
                &[("platform", platform_label(&request.platform))],
            ))
            .confirm()
            .keyboard(false)
            .ok_text(lokalbot_i18n::tr("Allow"))
            .cancel_text(lokalbot_i18n::tr("Don't Allow"))
            .on_ok(move |_, _, cx| {
                allow(true, cx);
                true
            })
            .on_cancel(move |_, _, cx| {
                refuse(false, cx);
                true
            })
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_port_is_clamped_and_a_bad_entry_keeps_the_current_one() {
        assert_eq!(parsed_port("17891", 17890), 17891);
        assert_eq!(parsed_port(" 2000 ", 17890), 2000);
        assert_eq!(parsed_port("80", 17890), 1024);
        assert_eq!(parsed_port("70000", 17890), 65535);
        assert_eq!(parsed_port("abc", 17890), 17890);
        assert_eq!(parsed_port("", 17890), 17890);
    }

    #[test]
    fn the_code_draws_the_payload_with_a_quiet_border() {
        let payload = "lokalbot://pair?d=eyJ2IjoxLCJtYWNOYW1lIjoiVGVzdCJ9";
        let (width, modules) = qr_modules(payload).unwrap();
        assert!(width >= 21 && width % 2 == 1, "{width}");
        assert_eq!(modules.len(), (width * width) as usize);
        // A finder pattern starts at each of three corners.
        assert!(modules[0] && modules[(width - 1) as usize]);
        assert!(modules[((width - 1) * width) as usize]);
        let pixels = qr_pixels(width, &modules);
        assert_eq!(pixels.width(), (width + 8) * QR_SCALE);
        let white = image::Rgba([255, 255, 255, 255]);
        assert_eq!(*pixels.get_pixel(0, 0), white, "the quiet zone");
        let corner = QR_QUIET_MODULES * QR_SCALE;
        assert_eq!(
            *pixels.get_pixel(corner, corner),
            image::Rgba([0, 0, 0, 255])
        );
        assert_eq!(*pixels.get_pixel(corner - 1, corner), white);
    }

    #[test]
    fn a_real_pairing_code_fits_with_many_addresses() {
        let long = format!("lokalbot://pair?d={}", "A".repeat(600));
        assert!(qr_modules(&long).is_some());
    }

    #[test]
    fn device_detail_says_how_it_was_last_reached() {
        let device = CompanionDevice {
            id: "d".into(),
            name: "Pixel".into(),
            platform: "android".into(),
            paired_at: None,
            last_seen_at: None,
            last_address: Some("100.100.1.2".into()),
        };
        assert_eq!(
            device_detail(&device, true),
            "Android · Connected · Tailscale"
        );
        assert_eq!(
            device_detail(&device, false),
            "Android · Not connected yet · Tailscale"
        );
    }

    #[test]
    fn a_device_names_its_platform() {
        assert_eq!(platform_label("ios"), "iPhone");
        assert_eq!(platform_label("ipados"), "iPad");
        assert_eq!(platform_label("android"), "Android");
        assert_eq!(platform_label(""), "Device");
        assert_eq!(platform_label("visionos"), "visionos");
    }

    #[test]
    fn notes_appear_only_while_listening() {
        let settings = Settings::default();
        let mut snapshot = CompanionSnapshot::default();
        assert!(network_notes(&settings, &snapshot).is_empty());
        snapshot.status = CompanionStatus::Listening { port: 17890 };
        assert_eq!(network_notes(&settings, &snapshot).len(), 1, "no address");
        snapshot.addresses = vec!["192.168.1.2".into()];
        snapshot.discovery_error = Some("mDNS could not start".into());
        let notes = network_notes(&settings, &snapshot);
        assert_eq!(notes.len(), 1);
        assert!(notes[0].1.contains("mDNS could not start"));
    }

    #[test]
    fn the_firewall_note_names_the_port_or_the_prompt() {
        let note = firewall_note(17890);
        assert!(note.contains("17890") || note.contains("Windows Firewall"));
    }
}
