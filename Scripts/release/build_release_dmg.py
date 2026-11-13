#!/usr/bin/env python3
"""Build a styled release DMG for LokalBot with dmgbuild.

The GitHub Actions workflow decides *when* to package; this script decides
*how* the installer disk image is assembled, so the layout policy (window
geometry, the drag-to-Applications arrangement, the volume icon) lives in one
auditable place rather than scattered through YAML.

Flow:
1. Validate the built `LokalBot.app` (auto-discovered when --app is omitted).
2. Resolve a best-effort volume icon from the app bundle (CFBundleIconFile).
3. Optionally normalize a background PNG (combining a sibling @2x rep for HiDPI).
4. Render an ephemeral dmgbuild settings module and invoke dmgbuild.

dmgbuild owns the actual copy into the image; it preserves the app's code
signature, which is why this script can stay declarative and skip hand-rolled
staging.

Usage (all flags optional):
    python3 Scripts/release/build_release_dmg.py \
        --app build/export/LokalBot.app \
        --output build/LokalBot.dmg \
        --background assets/release/dmg_background.png
"""

from __future__ import annotations

import argparse
import importlib.util
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
from textwrap import dedent

# Product constants. LokalBot ships as a single window; keep the geometry
# compact so the mounted volume opens without scrollbars on a laptop display.
VOLUME_NAME = "LokalBot"
APP_BUNDLE_NAME = "LokalBot.app"
WINDOW_RECT = ((200, 120), (520, 360))  # ((origin_x, origin_y), (width, height))
ICON_SIZE = 128
APP_ICON_LOCATION = (130, 170)
APPLICATIONS_ICON_LOCATION = (390, 170)


def repo_root() -> Path:
    """Repo root, derived from this script's location under Scripts/."""

    return Path(__file__).resolve().parents[2]


def parse_args() -> argparse.Namespace:
    """Parse the small CLI contract used by local releases and CI."""

    parser = argparse.ArgumentParser(
        description="Build a styled LokalBot release DMG with dmgbuild."
    )
    parser.add_argument(
        "--app",
        default=None,
        help=(
            "Path to the built LokalBot.app. When omitted, the newest bundle "
            "under build/export/ or the Xcode DerivedData Release products is used."
        ),
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Path for the final DMG. Defaults to build/LokalBot.dmg.",
    )
    parser.add_argument(
        "--background",
        default=None,
        help=(
            "Optional background image (PNG). A sibling <name>@2x.png is merged "
            "for HiDPI when present. Omit for a plain styled DMG."
        ),
    )
    parser.add_argument(
        "--volume-name",
        default=VOLUME_NAME,
        help=f"Mounted volume name shown by Finder. Defaults to {VOLUME_NAME}.",
    )
    return parser.parse_args()


def run_command(command: list[str]) -> None:
    """Run a subprocess, surfacing its output when it fails."""

    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        if result.stdout:
            print(result.stdout, file=sys.stderr, end="")
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        raise RuntimeError(
            f"Command failed with exit code {result.returncode}: {' '.join(command)}"
        )


def ensure_dmgbuild_available() -> None:
    """Fail early when the release machine is missing the DMG builder."""

    if importlib.util.find_spec("dmgbuild") is None:
        raise RuntimeError(
            "dmgbuild is not installed. Run `pip3 install dmgbuild` "
            "(or `pip3 install \"dmgbuild[badge_icons]\"` for badged volume icons) "
            "before packaging."
        )


def resolve_app_path(explicit: str | None) -> Path:
    """Resolve the app bundle to package, preferring an explicit --app.

    Without --app, look where the release export lands first, then fall back to
    the newest Xcode DerivedData Release build so a local `xcodebuild` flow Just
    Works without remembering the derived-data path.
    """

    if explicit:
        path = Path(explicit).expanduser()
        if not path.exists():
            raise FileNotFoundError(f"App bundle not found at {path}")
        return path.resolve()

    candidates: list[Path] = [repo_root() / "build" / "export" / APP_BUNDLE_NAME]
    derived = Path.home() / "Library/Developer/Xcode/DerivedData"
    if derived.exists():
        for configuration in ("Release", "Debug"):
            built = sorted(
                derived.glob(f"LokalBot-*/Build/Products/{configuration}/{APP_BUNDLE_NAME}"),
                key=lambda candidate: candidate.stat().st_mtime,
                reverse=True,
            )
            candidates.extend(built)

    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()

    raise FileNotFoundError(
        f"Could not locate {APP_BUNDLE_NAME}. Build the app first or pass --app /path/to/{APP_BUNDLE_NAME}."
    )


def resolve_volume_icon(app_path: Path) -> Path | None:
    """Resolve an .icns volume icon from the bundle's CFBundleIconFile.

    The bundle is the shipping truth, so badging the volume from it keeps the
    mounted image aligned with the icon users actually install. Only .icns is
    returned because that is what dmgbuild's `icon` setting accepts; anything
    else is skipped so packaging never fails over a cosmetic detail.
    """

    resource_dir = app_path / "Contents" / "Resources"
    if not resource_dir.exists():
        return None

    info_path = app_path / "Contents" / "Info.plist"
    if info_path.exists():
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        icon_name = info.get("CFBundleIconFile") or info.get("CFBundleIconName")
        if isinstance(icon_name, str) and icon_name:
            named = icon_name if icon_name.endswith(".icns") else f"{icon_name}.icns"
            candidate = resource_dir / named
            if candidate.is_file():
                return candidate.resolve()

    for candidate in sorted(resource_dir.glob("*.icns")):
        if candidate.is_file():
            return candidate.resolve()
    return None


def resolve_background(background: str | None, work_dir: Path) -> Path | None:
    """Resolve the optional background, merging a sibling @2x rep for HiDPI.

    A single PNG cannot carry two resolutions, so when both 1x and @2x exist we
    combine them into a multi-rep TIFF (the format Apple's own installers use)
    and let Finder pick the right rep per display.
    """

    if not background:
        return None

    source = Path(background).expanduser()
    if not source.is_file():
        raise FileNotFoundError(f"Background image not found at {source}")
    source = source.resolve()

    sibling_2x = source.with_name(f"{source.stem}@2x{source.suffix}")
    if sibling_2x.is_file():
        merged = work_dir / "dmg-background.tiff"
        run_command(
            ["tiffutil", "-cathidpicheck", str(source), str(sibling_2x), "-out", str(merged)]
        )
        return merged
    return source


def write_settings_file(
    settings_path: Path,
    *,
    app_path: Path,
    volume_icon: Path | None,
    background: Path | None,
) -> None:
    """Write the ephemeral dmgbuild settings module for this packaging run."""

    settings = dedent(
        f"""
        # Generated by Scripts/release/build_release_dmg.py for a single packaging run.
        # dmgbuild copies `files` into the image root (preserving the app's code
        # signature) and creates the Applications symlink itself.

        app_path = {str(app_path)!r}
        app_name = {app_path.name!r}

        files = [app_path]
        symlinks = {{"Applications": "/Applications"}}
        format = "UDZO"
        default_view = "icon-view"
        include_icon_view_settings = True
        arrange_by = None
        icon_size = {ICON_SIZE}
        text_size = 14
        label_pos = "bottom"
        icon_locations = {{
            app_name: {APP_ICON_LOCATION},
            "Applications": {APPLICATIONS_ICON_LOCATION},
        }}
        window_rect = {WINDOW_RECT}
        show_status_bar = False
        show_tab_view = False
        show_toolbar = False
        show_pathbar = False
        show_sidebar = False
        show_icon_preview = False
        grid_spacing = 96
        """
    ).strip() + "\n"

    if background is not None:
        settings += f"background = {str(background)!r}\n"
    if volume_icon is not None:
        settings += f"icon = {str(volume_icon)!r}\n"

    settings_path.write_text(settings, encoding="utf-8")


def build_dmg(*, volume_name: str, output_path: Path, settings_path: Path) -> None:
    """Invoke dmgbuild through the active interpreter so it uses our deps."""

    if output_path.exists():
        output_path.unlink()
    run_command(
        [
            sys.executable,
            "-m",
            "dmgbuild",
            "-s",
            str(settings_path),
            volume_name,
            str(output_path),
        ]
    )


def main() -> int:
    """Coordinate the end-to-end packaging flow for one DMG build."""

    args = parse_args()
    ensure_dmgbuild_available()

    app_path = resolve_app_path(args.app)
    if app_path.suffix != ".app":
        raise ValueError(f"Expected a .app bundle, got {app_path}")

    output_path = (
        Path(args.output).expanduser().resolve()
        if args.output
        else repo_root() / "build" / "LokalBot.dmg"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="LokalBot-dmgbuild-") as temporary_root:
        work_dir = Path(temporary_root)
        background = resolve_background(args.background, work_dir)
        volume_icon = resolve_volume_icon(app_path)

        settings_path = work_dir / "dmgbuild-settings.py"
        write_settings_file(
            settings_path,
            app_path=app_path,
            volume_icon=volume_icon,
            background=background,
        )
        build_dmg(
            volume_name=args.volume_name,
            output_path=output_path,
            settings_path=settings_path,
        )

    print(f"Built styled DMG at {output_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # pragma: no cover - exercised by manual release validation.
        print(f"Failed to build release DMG: {error}", file=sys.stderr)
        raise SystemExit(1)
