//! Commands that do their work and exit, without opening a window
//! (`HeadlessCommands.swift`): `lokalbot --health [--day YYYY-MM-DD] [--json]`,
//! `lokalbot --dream [YYYY-MM-DD]` and `lokalbot --export-diagnostics <zip>`.

use chrono::{Local, NaiveDate, Utc};
use lokalbot_core::{Library, LibraryPaths, Settings};

#[derive(Debug, PartialEq, Eq)]
pub enum Command {
    Health { day: Option<String>, json: bool },
    Dream { day: Option<String> },
    ExportDiagnostics(std::path::PathBuf),
}

pub fn parse(arguments: &[String]) -> Option<Command> {
    let value = |flag: &str| {
        arguments
            .iter()
            .position(|argument| argument == flag)
            .and_then(|index| arguments.get(index + 1))
    };
    if arguments.iter().any(|argument| argument == "--health") {
        return Some(Command::Health {
            day: value("--day").cloned(),
            json: arguments.iter().any(|argument| argument == "--json"),
        });
    }
    if arguments.iter().any(|argument| argument == "--dream") {
        return Some(Command::Dream {
            day: value("--dream")
                .filter(|day| !day.starts_with("--"))
                .cloned(),
        });
    }
    value("--export-diagnostics").map(|path| Command::ExportDiagnostics(path.into()))
}

fn health(
    library: &Library,
    settings: &Settings,
    day: Option<&str>,
    json: bool,
) -> Result<(), String> {
    let day = match day {
        Some(key) => NaiveDate::parse_from_str(key, "%Y-%m-%d")
            .map_err(|_| format!("{key} isn't a day. Use YYYY-MM-DD."))?,
        None => Local::now().date_naive() - chrono::Duration::days(1),
    };
    let report = lokalbot_engine::health_check::report(library, settings, day, Utc::now())
        .map_err(|err| format!("{err:#}"))?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&report).map_err(|err| err.to_string())?
        );
    } else {
        print!("{}", report.markdown());
    }
    library
        .write_health_report(&report)
        .map_err(|err| format!("{err:#}"))?;
    Ok(())
}

/// Runs `command`; returns the process's exit code.
pub fn run(command: &Command, paths: &LibraryPaths) -> i32 {
    let result = (|| -> Result<(), String> {
        let settings = Settings::load(&paths.settings_file());
        let library = Library::open(paths.clone()).map_err(|err| format!("{err:#}"))?;
        match command {
            Command::Health { day, json } => health(&library, &settings, day.as_deref(), *json),
            Command::Dream { day } => {
                let day = lokalbot_engine::dreaming::validated_day(
                    day.as_deref(),
                    Local::now().date_naive(),
                )
                .map_err(|message| format!("--dream: {message}"))?;
                let report = lokalbot_engine::dreaming::review_once(&library, &settings, day)
                    .map_err(|err| format!("--dream: FAILED — {err:#}"))?;
                let kind = match &report.engine_name {
                    Some(engine) => format!("model ({engine})"),
                    None => match report.fallback_reason {
                        Some(reason) => format!("fallback ({reason:?})"),
                        None => "fallback (legacy)".to_string(),
                    },
                };
                println!(
                    "lokalbot --dream: {kind} → {}",
                    lokalbot_core::dream::DreamStore::new(paths.root())
                        .report_path(&report.day)
                        .display()
                );
                Ok(())
            }
            Command::ExportDiagnostics(destination) => {
                let manifest =
                    lokalbot_engine::diagnostics::export(&library, &settings, destination)
                        .map_err(|err| format!("{err:#}"))?;
                let missing = if manifest.missing.is_empty() {
                    "none".to_string()
                } else {
                    manifest.missing.join(", ")
                };
                println!(
                    "lokalbot --export-diagnostics: {} (missing: {missing})",
                    destination.display()
                );
                Ok(())
            }
        }
    })();
    match result {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("lokalbot: {message}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn flags_parse_like_the_mac() {
        assert_eq!(parse(&args(&["lokalbot"])), None);
        assert_eq!(
            parse(&args(&["lokalbot", "--dream"])),
            Some(Command::Dream { day: None })
        );
        assert_eq!(
            parse(&args(&["lokalbot", "--dream", "2026-10-19"])),
            Some(Command::Dream {
                day: Some("2026-10-19".into())
            })
        );
        assert_eq!(
            parse(&args(&["lokalbot", "--health"])),
            Some(Command::Health {
                day: None,
                json: false
            })
        );
        assert_eq!(
            parse(&args(&[
                "lokalbot",
                "--health",
                "--day",
                "2026-10-15",
                "--json"
            ])),
            Some(Command::Health {
                day: Some("2026-10-15".into()),
                json: true
            })
        );
        assert_eq!(
            parse(&args(&["lokalbot", "--export-diagnostics", "/tmp/d.zip"])),
            Some(Command::ExportDiagnostics("/tmp/d.zip".into()))
        );
        assert_eq!(parse(&args(&["lokalbot", "--export-diagnostics"])), None);
    }

    #[test]
    fn both_commands_run_against_a_temporary_library() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        let code = run(
            &Command::Health {
                day: Some("2026-10-15".into()),
                json: true,
            },
            &paths,
        );
        assert_eq!(code, 0);
        assert!(
            dir.path()
                .join("diagnostics/health/2026-10-15.json")
                .is_file()
        );
        assert_eq!(
            run(
                &Command::Health {
                    day: Some("yesterday".into()),
                    json: false
                },
                &paths
            ),
            1
        );
        let zip = dir.path().join("out.zip");
        assert_eq!(run(&Command::ExportDiagnostics(zip.clone()), &paths), 0);
        assert!(zip.is_file());
    }
}
