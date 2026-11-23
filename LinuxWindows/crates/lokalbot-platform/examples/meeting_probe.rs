fn main() {
    #[cfg(windows)]
    {
        let show_titles = std::env::args().any(|arg| arg == "--show-titles");
        for window in lokalbot_platform::meeting::probe_browser_windows() {
            let title = if show_titles {
                format!(" title={:?}", window.title)
            } else {
                String::new()
            };
            println!(
                "family={} title_chars={} title_marker={} interface={}{title}",
                window.family,
                window.title.chars().count(),
                window.title_marker,
                window.interface,
            );
        }
    }
    #[cfg(not(windows))]
    eprintln!("meeting_probe reads browser windows on Windows only");
}
