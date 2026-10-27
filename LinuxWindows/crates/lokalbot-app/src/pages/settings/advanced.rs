//! Advanced: setup, the Agent CLI, logs and build details.

use std::path::PathBuf;

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::{AppContext as _, Context, ParentElement as _, SharedString, Styled as _, px};

use super::{Section, SettingsPage};
use crate::state::AppEvent;
use crate::ui::{Ico, settings_row};

/// Where `InstallCli` puts the command for coding agents: the path
/// `lokalbot-cli install-skill` installs to.
pub fn cli_install_path() -> PathBuf {
    lokalbot_cli::install::command_path_for_current_user().unwrap_or_else(|| {
        PathBuf::from(if cfg!(target_os = "windows") {
            "lokalbot-cli.exe"
        } else {
            "lokalbot-cli"
        })
    })
}

/// Commands that connect a coding agent to LokalBot over MCP, each with a
/// Copy button (the external-agent setup that sat on the Agent page before
/// Agent Mode).
fn mcp_commands(
    path: &std::path::Path,
    data: &gpui_kit::Entity<crate::state::AppData>,
    cx: &mut Context<SettingsPage>,
) -> gpui_kit::Div {
    use crate::theme::{LbThemeExt as _, ty};
    use gpui_kit::component::button::ButtonVariants as _;
    use gpui_kit::{ClipboardItem, FontWeight};
    let path_text = path.display().to_string();
    let command = if cfg!(target_os = "windows") {
        format!("\"{path_text}\"")
    } else {
        path_text.clone()
    };
    let entries = [
        (
            "claude",
            lokalbot_i18n::tr("Claude Code"),
            format!("claude mcp add lokalbot -- {command} mcp"),
        ),
        (
            "codex",
            lokalbot_i18n::tr("Codex"),
            format!("codex mcp add lokalbot -- {command} mcp"),
        ),
        (
            "json",
            lokalbot_i18n::tr("Other MCP clients"),
            format!(
                "{{\"mcpServers\": {{\"lokalbot\": {{\"command\": \"{}\", \"args\": [\"mcp\"]}}}}}}",
                path_text.replace('\\', "\\\\")
            ),
        ),
    ];
    let lb = cx.lb().clone();
    let mono = {
        use gpui_kit::component::ActiveTheme as _;
        cx.theme().mono_font_family.clone()
    };
    let mut column = v_flex().gap(px(10.)).child(
        gpui_kit::div()
            .text_size(ty::BODY)
            .font_weight(FontWeight::MEDIUM)
            .text_color(lb.text)
            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                "Connect a coding agent over MCP",
            ))),
    );
    for (key, label, text) in entries {
        let copy = text.clone();
        let data = data.clone();
        column = column.child(
            v_flex()
                .gap(px(4.))
                .child(
                    gpui_kit::div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(label),
                )
                .child(
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .px(px(10.))
                        .py(px(6.))
                        .rounded(px(8.))
                        .bg(lb.chip_fill)
                        .child(
                            gpui_kit::div()
                                .flex_1()
                                .min_w_0()
                                .font_family(mono.clone())
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text)
                                .child(text),
                        )
                        .child(
                            Button::new(SharedString::from(format!("settings-mcp-copy-{key}")))
                                .ghost()
                                .xsmall()
                                .icon(Icon::new(Ico::Copy))
                                .label(lokalbot_i18n::tr("Copy"))
                                .on_click(move |_, _, cx| {
                                    cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()));
                                    data.update(cx, |data, cx| {
                                        data.show_message(lokalbot_i18n::tr("Copied."), cx)
                                    });
                                }),
                        ),
                ),
        );
    }
    column.child(settings_row::help(
        lokalbot_i18n::tr("Agents also need \"Allow external agents to read your meeting library\" in Privacy & Data. Try it in a terminal with: lokalbot-cli brief"),
        cx,
    ))
}

/// "Linux · x86_64" / "Windows · x86_64".
pub fn platform_line() -> String {
    let os = match std::env::consts::OS {
        "linux" => lokalbot_i18n::tr("Linux"),
        "windows" => lokalbot_i18n::tr("Windows"),
        "macos" => "macOS",
        other => other,
    };
    format!("{os} · {}", std::env::consts::ARCH)
}

impl SettingsPage {
    /// Runs the bundled `lokalbot-cli install-skill`, which installs the CLI
    /// and the agent skill, then refreshes the Agent CLI status.
    fn install_cli(&mut self, cx: &mut Context<Self>) {
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    let exe = std::env::current_exe()?;
                    let name = if cfg!(windows) {
                        "lokalbot-cli.exe"
                    } else {
                        "lokalbot-cli"
                    };
                    let cli = exe.with_file_name(name);
                    anyhow::ensure!(
                        cli.is_file(),
                        "{} was not found next to LokalBot",
                        cli.display()
                    );
                    let output = std::process::Command::new(&cli)
                        .arg("install-skill")
                        .output()?;
                    if output.status.success() {
                        Ok(())
                    } else {
                        anyhow::bail!("{}", String::from_utf8_lossy(&output.stderr).trim())
                    }
                })
                .await;
            data.update(cx, |data, cx| match result {
                Ok(()) => data.show_message(
                    lokalbot_i18n::tr("Installed lokalbot-cli for your coding agents."),
                    cx,
                ),
                Err(err) => data.show_error(
                    lokalbot_i18n::format(
                        "Installing lokalbot-cli failed: {err}",
                        &[("err", format!("{:#}", err))],
                    ),
                    cx,
                ),
            });
            let _ = this.update(cx, |this, cx| this.reload_access(cx));
        })
        .detach();
    }

    pub(super) fn advanced_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let (paths, data) = (
            self.data.read(cx).library.paths().clone(),
            self.data.clone(),
        );
        let path = cli_install_path();
        let installed = self.cli_installed;
        let status = match installed {
            Some(true) => settings_row::value(lokalbot_i18n::tr("Installed"), cx),
            Some(false) => settings_row::value(lokalbot_i18n::tr("Not installed"), cx),
            None => settings_row::value(lokalbot_i18n::tr("Checking…"), cx),
        };
        let setup_data = data.clone();
        let setup = Section::new(lokalbot_i18n::tr("Setup")).row(
            "settings.setupAgain",
            settings_row::row(
                "settings.setupAgain",
                lokalbot_i18n::tr("Setup assistant"),
                Some(lokalbot_i18n::tr("Walk through meeting recording, day memory, and models again. Nothing changes until you apply your choices at the end.").into()),
                Button::new("settings-setup-again")
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Set Up LokalBot Again…"))
                    .on_click(move |_, _, cx| {
                        setup_data.update(cx, |data, cx| data.request(AppEvent::OpenOnboarding, cx))
                    }),
                self.is_focused("settings.setupAgain"),
                cx,
            ),
        );

        let cli = Section::new(lokalbot_i18n::tr("Agent CLI"))
            .row("settings.agentCLI", settings_row::row("settings.agentCLI", lokalbot_i18n::tr("Status"), None, status, self.is_focused("settings.agentCLI"), cx))
            .row(
                "settings.agentCLIInstall",
                settings_row::content_row(
                    "settings.agentCLIInstall",
                    v_flex()
                        .gap(px(8.))
                        .child(
                            h_flex().gap(px(8.)).child(
                                Button::new("settings-install-cli")
                                    .outline()
                                    .small()
                                    .icon(Icon::new(Ico::Terminal))
                                    .label(if installed == Some(true) { lokalbot_i18n::tr("Reinstall…") } else { lokalbot_i18n::tr("Install for your coding agent…") })
                                    .on_click(cx.listener(|this, _, _, cx| this.install_cli(cx))),
                            ),
                        )
                        .child(settings_row::help(
                            lokalbot_i18n::format("Installs lokalbot-cli at {0} and the LokalBot skill into ~/.agents/skills and ~/.claude/skills. Read-only by design.", &[("0", format!("{}", path.display()))]),
                            cx,
                        )),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.agentMCP",
                settings_row::content_row(
                    "settings.agentMCP",
                    mcp_commands(&path, &data, cx),
                    false,
                    cx,
                ),
            );

        let logs = paths.logs_dir();
        let open_logs = logs.clone();
        let root = paths.root().to_path_buf();
        let diagnostics = Section::new(lokalbot_i18n::tr("Logs")).row(
            "settings.logs",
            settings_row::row(
                "settings.logs",
                lokalbot_i18n::tr("Logs folder"),
                Some(SharedString::from(logs.display().to_string())),
                Button::new("settings-open-logs")
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Open Folder"))
                    .on_click(move |_, _, cx| {
                        let target = if open_logs.is_dir() {
                            open_logs.clone()
                        } else {
                            root.clone()
                        };
                        cx.open_with_system(&target);
                    }),
                self.is_focused("settings.logs"),
                cx,
            ),
        );

        let build = if cfg!(debug_assertions) {
            lokalbot_i18n::tr("Debug build")
        } else {
            lokalbot_i18n::tr("Release build")
        };
        let system = Section::new(lokalbot_i18n::tr("System"))
            .row(
                "settings.version",
                settings_row::row(
                    "settings.version",
                    lokalbot_i18n::tr("Version"),
                    None,
                    settings_row::value(
                        lokalbot_i18n::format(
                            "LokalBot {0} · {build}",
                            &[
                                ("0", env!("CARGO_PKG_VERSION").to_string()),
                                ("build", build.to_string()),
                            ],
                        ),
                        cx,
                    ),
                    self.is_focused("settings.version"),
                    cx,
                ),
            )
            .row(
                "settings.thisPC",
                settings_row::row(
                    "settings.thisPC",
                    lokalbot_i18n::tr("This PC"),
                    None,
                    settings_row::value(platform_line(), cx),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.processors",
                settings_row::row(
                    "settings.processors",
                    lokalbot_i18n::tr("Processor threads"),
                    None,
                    settings_row::value(
                        std::thread::available_parallelism()
                            .map(|n| n.get().to_string())
                            .unwrap_or_else(|_| lokalbot_i18n::tr("Unknown").into()),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );

        vec![setup, cli, diagnostics, system]
    }
}
