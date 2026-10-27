# GPUI dependency provenance

LokalBot for Linux and Windows uses GPUI, Zed's UI framework, through
[GPUI Kit](https://github.com/longbridge/gpui-kit) 0.7.3 (`gpui-kit` on crates.io,
Apache-2.0). Zed does not publish current GPUI releases to crates.io, so GPUI Kit
depends on `gpui-pre-*` crates: snapshots of Zed's GPUI crates published by a GPUI Kit
maintainer. Each snapshot crate declares the Zed commit it was taken from in
`package.metadata.gpui-pre.zed-rev`.

Pins: `gpui-kit = "=0.7.3"` in `Cargo.toml`; GPUI Kit pins every `gpui-pre-*` crate to
`=0.3.9`; `Cargo.lock` pins the exact checksums.

## Verified against Zed's source

`scripts/verify-gpui-provenance.sh` downloads the published crates, checks out Zed at
the declared commit and compares every source file. Result for 0.3.9, which declares
[zed@93d7456](https://github.com/zed-industries/zed/commit/93d745668805029476e6d7fbb19652116fed51de)
(October 10, 2026):

| Published crate | Zed crate | Result |
| --- | --- | --- |
| `gpui-pre-platform` | `gpui_platform` | identical |
| `gpui-pre-linux` | `gpui_linux` | identical |
| `gpui-pre-windows` | `gpui_windows` | identical |
| `gpui-pre-wgpu` | `gpui_wgpu` | identical |
| `gpui-pre-util` | `gpui_util` | identical |
| `gpui-pre-collections` | `collections` | identical |
| `gpui-pre-sum-tree` | `sum_tree` | identical |
| `gpui-pre-refineable` | `refineable` | identical |
| `gpui-pre` | `gpui` | one file differs: `action.rs`, where the `actions!` macro derives `$crate::Action` instead of `gpui::Action`. The change is marked with a comment. |
| `gpui-pre-macros` | `gpui_macros` | `gpui_macros.rs` routes each proc-macro's output through an added `gpui_pre_facade_paths.rs`, which rewrites `gpui::` paths to the `gpui-kit` facade. Both are marked as modified for gpui-pre. |

The two differences only change how macro-generated paths resolve when GPUI is used
through the `gpui-kit` facade. No rendering, platform or input code differs from Zed.

Run the check again after any version bump:

```bash
scripts/verify-gpui-provenance.sh 0.3.9
```

This compares source files only. It does not audit GPUI Kit's own component crates or the
wider dependency graph.
