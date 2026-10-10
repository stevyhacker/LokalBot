# GPUI dependency provenance

Checked on 2026-10-02 against this port's lockfile and the downloaded registry packages. This is provenance verification, not a security audit of every transitive crate.

| Package | Pinned source | Evidence |
| --- | --- | --- |
| `gpui-kit` | crates.io `0.7.0`, published from Longbridge's repository | The package's `.cargo_vcs_info.json` points to [Longbridge commit `0c830f4`](https://github.com/longbridge/gpui-kit/commit/0c830f4d257e69fdd17200650533ab4ca9a40cc0), path `crates/kit`. Lockfile checksum: `8edb2a8eafdb6e65ad1a80625347b93f8e54cbf3fac82a584e4924cda674d5c2`. |
| `gpui-pre` and platform snapshot crates | crates.io `0.3.7` | The downloaded `gpui-pre` manifest declares `package.metadata.gpui-pre.zed-rev = 1a28cff4b409169bac058bca40dfbfeb7621d19b`. That [commit exists in Zed's repository](https://github.com/zed-industries/zed/commit/1a28cff4b409169bac058bca40dfbfeb7621d19b). It identifies a snapshot; it does not authenticate every republished file against upstream. |
| `gpui-component`, `gpui-base`, assets | crates.io `0.7.0` | Longbridge's [release manifest](https://github.com/longbridge/gpui-kit/blob/0c830f4d257e69fdd17200650533ab4ca9a40cc0/Cargo.toml) pins the GPUI snapshots exactly to `=0.3.7`. |

The crates.io owners endpoint for `gpui-pre` lists `huacnlee`, a third-party publisher. These packages are **not a direct dependency on an official Zed release**. The GPUI Kit maintainers describe their registry packaging and exact snapshot pins in the [installation guide](https://gpui-kit.com/docs/installation/) and release manifest. The dependency graph also includes a separately named `gpui-pre-reqwest` fork; application inference uses our direct `reqwest` dependency and its own credential/origin/proxy checks.

The lockfile has 927 package entries, including target-specific and optional packages and the application. `cargo tree --locked --prefix none --edges normal,build --target x86_64-unknown-linux-gnu`, deduplicated by package/version, contains 610 entries. The equivalent `--no-default-features` graph contains 175. Those are dependency graph counts, not a statement that 927 packages ship in each executable.

Keep the existing pins while correcting the port's behavior. Before a production release, decide whether to retain this publisher boundary or use an explicitly pinned upstream Zed checkout with a compatible component layer. A checksum proves the package is the one pinned in the lockfile; it does not establish that the publisher or all source changes are safe. Changing the framework source requires a separate compatibility/build review.
