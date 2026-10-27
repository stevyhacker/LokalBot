//! Embeds the app icon and version details into the Windows executable.
//! GPUI already embeds the application manifest (per-monitor DPI awareness,
//! common controls v6), so this adds no manifest of its own.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        windows_resources();
    }
}

#[cfg(windows)]
fn windows_resources() {
    let packaging = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../packaging");
    let icon = packaging.join("icons/lokalbot.ico");
    println!("cargo:rerun-if-changed={}", icon.display());
    let mut resource = winresource::WindowsResource::new();
    resource
        .set_icon(&icon.to_string_lossy())
        .set("ProductName", "LokalBot")
        .set("FileDescription", "LokalBot")
        .set("CompanyName", "LokalBot")
        .set("LegalCopyright", "GPL-3.0-only");
    if let Err(err) = resource.compile() {
        panic!("embedding Windows resources failed: {err}");
    }
}

#[cfg(not(windows))]
fn windows_resources() {
    println!("cargo:warning=Windows resources can only be embedded when building on Windows");
}
