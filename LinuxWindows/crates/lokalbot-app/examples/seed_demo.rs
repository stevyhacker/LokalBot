//! Seeds the synthetic demo library used for screenshots and UI checks:
//! `cargo run -p lokalbot-app --example seed_demo -- <library dir>`.

fn main() -> anyhow::Result<()> {
    let root = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("usage: seed_demo <library dir>"))?;
    lokalbot_core::demo::seed(&lokalbot_core::LibraryPaths::new(root), chrono::Utc::now())
}
