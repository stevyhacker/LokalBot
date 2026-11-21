fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        windows_resources();
    }
}

#[cfg(windows)]
fn windows_resources() {
    let mut resource = winresource::WindowsResource::new();
    resource
        .set("ProductName", "LokalBot")
        .set("FileDescription", "LokalBot CLI and MCP Server")
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
