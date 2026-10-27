//! Lists the speech model catalog and its install state; `--finish` runs
//! `finish_install` for every model folder that exists (after a manual
//! download + extract into `<root>/models/speech/<id>/`).
//!
//! `cargo run -p lokalbot-speech --example models -- <library root> [--finish]`

use lokalbot_core::LibraryPaths;
use lokalbot_speech::models;

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let root = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("usage: models <library root> [--finish]"))?;
    let finish = args.next().as_deref() == Some("--finish");
    let paths = LibraryPaths::new(root);
    for model in models::all() {
        if finish
            && models::model_dir(&paths, model).is_dir()
            && !models::is_installed(&paths, model)
        {
            match models::finish_install(&paths, model) {
                Ok(()) => println!("installed {}", model.id),
                Err(error) => println!("{}: {error:#}", model.id),
            }
        }
        let info = models::download_info(model);
        println!(
            "{:<26} {:<30} {:>11} B  {}  {}  {}",
            model.id,
            model.display_name,
            info.size,
            if models::is_installed(&paths, model) {
                "installed"
            } else {
                "missing  "
            },
            &info.sha256[..12],
            info.url
        );
    }
    Ok(())
}
