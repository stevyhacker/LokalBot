//! The agent setup window (`AgentSetupView.swift`): an agent ran `lokalbot-cli
//! setup start` and asks to set LokalBot up for the person. Allow turns on
//! settings access and any read access the person ticks; Don't Allow leaves
//! everything off.

use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, TitleBar, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Bounds, Context, Entity, FontWeight, IntoElement, ParentElement as _,
    Render, SharedString, Styled as _, Subscription, Window, WindowBounds, WindowKind,
    WindowOptions, div, px, size,
};
use lokalbot_core::control::setup::Grant;

use crate::control::{self, ControlHost};
use crate::i18n::h_flex;
use crate::theme::{FONT_FAMILY, LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, settings_row};

const WIDTH: f32 = 540.;
const HEIGHT: f32 = 520.;

/// Opens the window, or brings it forward.
pub fn open(cx: &mut App) {
    let existing = super::secondary(cx).agent_setup;
    if super::activate(existing, cx) {
        return;
    }
    let bounds = Bounds::centered(None, size(px(WIDTH), px(HEIGHT)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        kind: WindowKind::Normal,
        is_minimizable: false,
        app_id: Some(lokalbot_platform::APP_ID.into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title(lokalbot_i18n::tr("Set Up with Your Agent"));
        cx.new(|cx| AgentSetup::new(window, cx))
    }) {
        Ok((handle, _)) => super::secondary(cx).agent_setup = Some(handle),
        Err(err) => log::error!("could not open the agent setup window: {err:#}"),
    }
}

pub fn close(cx: &mut App) {
    if let Some(handle) = super::secondary(cx).agent_setup.take() {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
}

pub struct AgentSetup {
    host: Option<Entity<ControlHost>>,
    nonce: Option<String>,
    meeting_library: bool,
    screen_memory: bool,
    files: bool,
    _subscriptions: Vec<Subscription>,
}

impl AgentSetup {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let host = control::global(cx);
        let mut subscriptions = Vec::new();
        if let Some(host) = &host {
            subscriptions.push(cx.observe_in(host, window, |this, host, window, cx| {
                let nonce = host
                    .read(cx)
                    .setup_pending
                    .as_ref()
                    .map(|request| request.nonce.clone());
                if nonce != this.nonce {
                    // A new request starts with nothing ticked.
                    this.meeting_library = false;
                    this.screen_memory = false;
                    this.files = false;
                    if nonce.is_none() {
                        super::secondary(cx).agent_setup = None;
                        window.remove_window();
                        return;
                    }
                    this.nonce = nonce;
                }
                cx.notify();
            }));
        }
        let nonce = host.as_ref().and_then(|host| {
            host.read(cx)
                .setup_pending
                .as_ref()
                .map(|request| request.nonce.clone())
        });
        Self {
            host,
            nonce,
            meeting_library: false,
            screen_memory: false,
            files: false,
            _subscriptions: subscriptions,
        }
    }
}

impl Render for AgentSetup {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let pending = self
            .host
            .as_ref()
            .and_then(|host| host.read(cx).setup_pending.clone());
        let title_bar = TitleBar::new().h(metric::TOOLBAR_HEIGHT);
        let Some(request) = pending else {
            return v_flex()
                .size_full()
                .bg(lb.window)
                .text_color(lb.text)
                .font_family(FONT_FAMILY)
                .child(title_bar)
                .child(
                    v_flex()
                        .flex_1()
                        .items_center()
                        .justify_center()
                        .gap(px(16.))
                        .child(ui::text::paragraph(lokalbot_i18n::tr(
                            "Nothing is waiting for your approval.",
                        )))
                        .child(
                            Button::new("agent-setup-close")
                                .small()
                                .outline()
                                .label(lokalbot_i18n::tr("Close"))
                                .on_click(|_, _, cx| close(cx)),
                        ),
                );
        };
        let requester: String = request.requester.chars().take(80).collect();
        let allow_host = self.host.clone();
        let deny_host = self.host.clone();
        let (meeting_library, screen_memory, files) =
            (self.meeting_library, self.screen_memory, self.files);
        v_flex()
            .size_full()
            .bg(lb.window)
            .text_color(lb.text)
            .font_family(FONT_FAMILY)
            .child(title_bar)
            .child(
                v_flex()
                    .flex_1()
                    .min_h_0()
                    .px(px(24.))
                    .pb(px(24.))
                    .gap(px(16.))
                    .child(
                        h_flex()
                            .gap(px(10.))
                            .items_center()
                            .child(ui::icon(Ico::Terminal, px(20.), lb.accent_text))
                            .child(
                                div()
                                    .text_size(ty::COLUMN_TITLE)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                                        "Set up LokalBot with your agent",
                                    ))),
                            ),
                    )
                    .child(
                        v_flex()
                            .gap(px(4.))
                            .child(
                                div()
                                    .text_size(ty::SECTION)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(SharedString::from(requester)),
                            )
                            .child(div().text_size(ty::BODY).child(ui::text::paragraph(
                                lokalbot_i18n::tr(
                                    "asks to set up LokalBot for you from the terminal.",
                                ),
                            ))),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(ui::text::paragraph(lokalbot_i18n::tr("Allowing it lets the agent change your LokalBot settings and download models. Turning on capture, a data source, or sharing still asks you here. You can turn this off at any time in Settings → Privacy & Data."))),
                    )
                    .when(request.grants.contains(&Grant::MeetingLibrary), |this| {
                        this.child(settings_row::row(
                            "agent-setup-meeting-library",
                            lokalbot_i18n::tr("Let agents read your meetings"),
                            Some(lokalbot_i18n::tr("Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) list, read, search, and ask about your meetings: read-only, on this PC only.").into()),
                            settings_row::switch(
                                "agent-setup-meeting-library",
                                meeting_library,
                                {
                                    let page = cx.entity();
                                    move |on, _, cx| {
                                        page.update(cx, |this, cx| {
                                            this.meeting_library = on;
                                            cx.notify();
                                        })
                                    }
                                },
                            ),
                            false,
                            cx,
                        ))
                    })
                    .when(request.grants.contains(&Grant::ScreenMemory), |this| {
                        this.child(settings_row::row(
                            "agent-setup-screen-memory",
                            lokalbot_i18n::tr("Let agents read screen memory"),
                            Some(lokalbot_i18n::tr("Captured text and metadata from the last 7 days. Screenshot pixels are never returned.").into()),
                            settings_row::switch(
                                "agent-setup-screen-memory",
                                screen_memory,
                                {
                                    let page = cx.entity();
                                    move |on, _, cx| {
                                        page.update(cx, |this, cx| {
                                            this.screen_memory = on;
                                            cx.notify();
                                        })
                                    }
                                },
                            ),
                            false,
                            cx,
                        ))
                    })
                    .when(request.grants.contains(&Grant::Files), |this| {
                        this.child(settings_row::row(
                            "agent-setup-files",
                            lokalbot_i18n::tr("Let agents search your files"),
                            Some(lokalbot_i18n::tr("Search the folders you chose under Files by their words. Files are never changed.").into()),
                            settings_row::switch(
                                "agent-setup-files",
                                files,
                                {
                                    let page = cx.entity();
                                    move |on, _, cx| {
                                        page.update(cx, |this, cx| {
                                            this.files = on;
                                            cx.notify();
                                        })
                                    }
                                },
                            ),
                            false,
                            cx,
                        ))
                    })
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(ui::text::paragraph(lokalbot_i18n::tr("Allow only an agent you started yourself. Any program on this PC can make this request."))),
                    )
                    .child(div().flex_1())
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .child(div().flex_1())
                            .child(
                                Button::new("agent-setup-deny")
                                    .outline()
                                    .label(lokalbot_i18n::tr("Don't Allow"))
                                    .on_click(move |_, _, cx| {
                                        if let Some(host) = &deny_host {
                                            host.update(cx, |host, cx| host.deny_setup(cx));
                                        }
                                    }),
                            )
                            .child(
                                Button::new("agent-setup-allow")
                                    .with_variant(ButtonVariant::Primary)
                                    .label(lokalbot_i18n::tr("Allow"))
                                    .on_click(move |_, _, cx| {
                                        if let Some(host) = &allow_host {
                                            host.update(cx, |host, cx| {
                                                host.allow_setup(
                                                    control::setup::Ticked {
                                                        meeting_library,
                                                        screen_memory,
                                                        files,
                                                    },
                                                    cx,
                                                )
                                            });
                                        }
                                    }),
                            ),
                    ),
            )
    }
}
