fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    std::process::exit(lokalbot_platform::autocomplete::run_kwin_input_method());
}
