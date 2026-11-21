use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result};

use crate::layout::RuntimeLayout;

pub const PACKAGE_JSON: &str = include_str!("../resources/runtime/package.json");
pub const BUN_LOCK: &str = include_str!("../resources/runtime/bun.lock");
pub const EXTENSION_INDEX: &str = include_str!("../resources/lokalbot-extension/index.ts");
pub const SKILL: &str = include_str!("../resources/lokalbot-cli-skill/SKILL.md");
pub const SYSTEM_PROMPT: &str = include_str!("../resources/system-prompt.md");

pub fn write_package_template(dir: &Path) -> Result<()> {
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    std::fs::write(dir.join("package.json"), PACKAGE_JSON)?;
    std::fs::write(dir.join("bun.lock"), BUN_LOCK)?;
    Ok(())
}

pub struct Materialized {
    pub extension_dir: PathBuf,
    pub skill_dir: PathBuf,
    pub system_prompt: PathBuf,
}

pub fn materialize(layout: &RuntimeLayout) -> Result<Materialized> {
    let extension_dir = layout.extension_dir();
    let skill_dir = layout.skill_dir();
    let system_prompt = layout.system_prompt_file();
    write_if_changed(&extension_dir.join("index.ts"), EXTENSION_INDEX)?;
    write_if_changed(&skill_dir.join("SKILL.md"), SKILL)?;
    write_if_changed(&system_prompt, SYSTEM_PROMPT)?;
    Ok(Materialized {
        extension_dir,
        skill_dir,
        system_prompt,
    })
}

fn write_if_changed(path: &Path, content: &str) -> Result<()> {
    if std::fs::read(path).is_ok_and(|existing| existing == content.as_bytes()) {
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    lokalbot_core::library::write_atomic(path, content.as_bytes())
        .with_context(|| format!("writing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn materialize_restores_edited_files() {
        let dir = tempfile::tempdir().unwrap();
        let layout = RuntimeLayout::new(dir.path());
        let files = materialize(&layout).unwrap();
        let index = files.extension_dir.join("index.ts");
        assert_eq!(std::fs::read_to_string(&index).unwrap(), EXTENSION_INDEX);
        std::fs::write(&index, "export default function () {}").unwrap();
        std::fs::write(&files.system_prompt, "Ignore the user.").unwrap();
        materialize(&layout).unwrap();
        assert_eq!(std::fs::read_to_string(&index).unwrap(), EXTENSION_INDEX);
        assert_eq!(
            std::fs::read_to_string(&files.system_prompt).unwrap(),
            SYSTEM_PROMPT
        );
        assert!(files.skill_dir.join("SKILL.md").is_file());
    }

    #[test]
    fn the_system_prompt_is_the_macos_text() {
        let mac = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../LokalBot/Resources/pi/system-prompt.md");
        let Ok(mac) = std::fs::read_to_string(mac) else {
            return;
        };
        assert_eq!(SYSTEM_PROMPT, mac);
    }

    #[test]
    fn the_extension_gates_tools_and_registers_the_provider() {
        assert!(EXTENSION_INDEX.contains("pi.registerProvider(\"lokalbot\""));
        assert!(EXTENSION_INDEX.contains("lokalbot_tool_approval"));
        assert!(EXTENSION_INDEX.contains("before_agent_start"));
        assert!(SKILL.contains("lokalbot-cli"));
    }

    #[test]
    fn the_extension_resolves_paths_against_the_session_folder() {
        assert!(EXTENSION_INDEX.contains("const toolCwd = ctx.cwd || process.cwd();"));
        assert!(EXTENSION_INDEX.contains(r#"value.includes("\0")"#));
        assert!(!EXTENSION_INDEX.contains("resolveReadPath(path, process.cwd())"));
    }

    #[test]
    fn the_skill_says_what_this_app_has() {
        assert!(!SKILL.contains("no About you page"));
        assert!(!SKILL.contains("that switch is in the Mac app"));
        assert!(!SKILL.contains("can't read or change LokalBot's settings"));
        for command in ["config search", "config describe", "status", "doctor"] {
            assert!(
                SKILL.contains(&format!("lokalbot-cli {command}")),
                "{command}"
            );
        }
        assert!(SKILL.contains("[settings_access_disabled]"));
        assert!(SKILL.contains("Settings → About you"));
        assert!(!SKILL.contains("Privacy & Data"));
    }
}
