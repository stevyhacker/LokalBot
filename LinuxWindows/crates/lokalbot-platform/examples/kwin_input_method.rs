//! The KWin input method helper on its own, for the live tests: what
//! `lokalbot --kwin-input-method` runs. KWin starts it with `--inputmethod`
//! (see `scripts/live-kwin.sh`).

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    std::process::exit(lokalbot_platform::autocomplete::run_kwin_input_method());
}
