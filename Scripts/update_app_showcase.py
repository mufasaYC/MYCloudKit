#!/usr/bin/env python3
"""Generate the README app showcase from App Store IDs."""

from __future__ import annotations

import argparse
import base64
import html
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REGISTRY = ROOT / "app.json"
DEFAULT_README = ROOT / "README.md"
DEFAULT_ASSETS_DIRECTORY = ROOT / ".github" / "assets" / "app-icons"
START_MARKER = "<!-- apps-using-mycloudkit:start -->"
END_MARKER = "<!-- apps-using-mycloudkit:end -->"


class ShowcaseError(Exception):
    """An actionable error while loading or generating the showcase."""


def load_registry(path: Path) -> list[int]:
    try:
        raw_entries = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ShowcaseError(f"Could not read {path}: {error}") from error

    if not isinstance(raw_entries, dict):
        raise ShowcaseError(f"{path} must contain a JSON object.")

    app_store_ids = raw_entries.get("appStoreIds")
    if not isinstance(app_store_ids, list):
        raise ShowcaseError(f'{path} must contain an "appStoreIds" array.')

    app_ids: list[int] = []
    seen_ids: set[int] = set()
    for index, app_id in enumerate(app_store_ids):
        if isinstance(app_id, bool) or not isinstance(app_id, int) or app_id <= 0:
            raise ShowcaseError(f"Entry {index + 1} has an invalid App Store ID.")
        if app_id in seen_ids:
            raise ShowcaseError(f"App Store ID {app_id} is listed more than once.")

        seen_ids.add(app_id)
        app_ids.append(app_id)

    return app_ids


def fetch_apps(app_ids: list[int]) -> list[dict[str, Any]]:
    """Fetch apps from the default US storefront in registry order."""
    results_by_id: dict[int, dict[str, Any]] = {}
    if app_ids:
        query = urllib.parse.urlencode(
            {"id": ",".join(map(str, app_ids)), "entity": "software", "country": "us"}
        )
        request = urllib.request.Request(
            f"https://itunes.apple.com/lookup?{query}",
            headers={"User-Agent": "MYCloudKit-App-Showcase/1.0"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.load(response)
        except (OSError, json.JSONDecodeError) as error:
            raise ShowcaseError(f"App Store lookup failed: {error}") from error

        for result in payload.get("results", []):
            if isinstance(result, dict) and isinstance(result.get("trackId"), int):
                results_by_id[result["trackId"]] = result

    missing_ids = [app_id for app_id in app_ids if app_id not in results_by_id]
    if missing_ids:
        missing = ", ".join(map(str, missing_ids))
        raise ShowcaseError(
            f"No App Store listing was found for: {missing}. "
            "Check each ID and confirm the app is available in the US storefront."
        )

    return [results_by_id[app_id] for app_id in app_ids]


def build_icon_asset(image_data: bytes, content_type: str) -> str:
    if not content_type.startswith("image/"):
        raise ShowcaseError(f"App icon has unsupported content type {content_type}.")

    encoded_image = base64.b64encode(image_data).decode("ascii")
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\n'
        "  <defs>\n"
        '    <clipPath id="app-icon-mask">\n'
        '      <rect width="100" height="100" rx="22" ry="22"/>\n'
        "    </clipPath>\n"
        "  </defs>\n"
        f'  <image width="100" height="100" preserveAspectRatio="xMidYMid slice" '
        f'clip-path="url(#app-icon-mask)" href="data:{content_type};base64,{encoded_image}"/>\n'
        "</svg>\n"
    )


def fetch_icon_assets(apps: list[dict[str, Any]]) -> dict[int, str]:
    assets: dict[int, str] = {}
    for app in apps:
        app_id = app.get("trackId")
        if not isinstance(app_id, int):
            raise ShowcaseError("An App Store result is missing trackId.")

        icon_url = required_string(app, "artworkUrl100")
        request = urllib.request.Request(
            icon_url,
            headers={"User-Agent": "MYCloudKit-App-Showcase/1.0"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                image_data = response.read()
                content_type = response.headers.get_content_type()
        except OSError as error:
            raise ShowcaseError(f"App icon lookup failed for {app_id}: {error}") from error

        assets[app_id] = build_icon_asset(image_data, content_type)

    return assets


def required_string(app: dict[str, Any], key: str) -> str:
    value = app.get(key)
    if not isinstance(value, str) or not value:
        raise ShowcaseError(
            f"App Store result {app.get('trackId', '<unknown>')} is missing {key}."
        )
    return value


def table_safe(value: str, *, attribute: bool = False) -> str:
    """Escape App Store metadata for an HTML value inside a Markdown table."""
    return html.escape(value, quote=attribute).replace("|", "&#124;")


def render_showcase(
    apps: list[dict[str, Any]], icon_sources: dict[int, str] | None = None
) -> str:
    if not apps:
        return "_No apps have been added yet. Be the first!_"

    rows = [
        "| Icon | App | Developer | Category |",
        "| :--: | :-- | :-- | :-- |",
    ]
    for app in apps:
        app_id = app.get("trackId")
        if not isinstance(app_id, int):
            raise ShowcaseError("An App Store result is missing trackId.")

        raw_name = required_string(app, "trackName")
        name = table_safe(raw_name)
        name_attribute = table_safe(raw_name, attribute=True)
        developer = table_safe(required_string(app, "artistName"))
        genre = table_safe(required_string(app, "primaryGenreName"))
        url = table_safe(required_string(app, "trackViewUrl"), attribute=True)
        icon_source = (
            icon_sources[app_id]
            if icon_sources is not None
            else required_string(app, "artworkUrl100")
        )
        icon = table_safe(icon_source, attribute=True)
        rows.append(
            f'| <a href="{url}"><img src="{icon}" width="56" height="56" '
            f'alt="{name_attribute} app icon"></a> | <a href="{url}"><strong>{name}</strong></a> '
            f"| {developer} | {genre} |"
        )

    return "\n".join(rows)


def update_readme(readme: str, rendered_showcase: str) -> str:
    start = readme.find(START_MARKER)
    end = readme.find(END_MARKER)
    if start == -1 or end == -1 or end < start:
        raise ShowcaseError("README showcase markers are missing or out of order.")

    content_start = start + len(START_MARKER)
    return (
        readme[:content_start]
        + "\n"
        + rendered_showcase.rstrip()
        + "\n"
        + readme[end:]
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if README is stale.")
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--readme", type=Path, default=DEFAULT_README)
    parser.add_argument(
        "--assets-directory", type=Path, default=DEFAULT_ASSETS_DIRECTORY
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        entries = load_registry(arguments.registry)
        apps = fetch_apps(entries)
        icon_assets = fetch_icon_assets(apps)
        icon_sources = {}
        for app_id in icon_assets:
            relative_asset_path = os.path.relpath(
                arguments.assets_directory / f"{app_id}.svg",
                arguments.readme.parent,
            )
            icon_sources[app_id] = Path(relative_asset_path).as_posix()
        existing_readme = arguments.readme.read_text(encoding="utf-8")
        generated_readme = update_readme(
            existing_readme, render_showcase(apps, icon_sources)
        )
    except (OSError, ShowcaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if arguments.check:
        stale_assets = [
            app_id
            for app_id, content in icon_assets.items()
            if not (arguments.assets_directory / f"{app_id}.svg").is_file()
            or (arguments.assets_directory / f"{app_id}.svg").read_text(encoding="utf-8")
            != content
        ]
        expected_asset_paths = {
            arguments.assets_directory / f"{app_id}.svg" for app_id in icon_assets
        }
        extra_assets = {
            path
            for path in arguments.assets_directory.glob("*.svg")
            if path.stem.isdigit() and path not in expected_asset_paths
        }
        if generated_readme != existing_readme or stale_assets or extra_assets:
            print(
                "error: README app showcase or icon assets are stale; run "
                "python3 Scripts/update_app_showcase.py",
                file=sys.stderr,
            )
            return 1
        print("README app showcase is up to date.")
        return 0

    arguments.assets_directory.mkdir(parents=True, exist_ok=True)
    expected_asset_paths = set()
    for app_id, content in icon_assets.items():
        asset_path = arguments.assets_directory / f"{app_id}.svg"
        asset_path.write_text(content, encoding="utf-8")
        expected_asset_paths.add(asset_path)
    for asset_path in arguments.assets_directory.glob("*.svg"):
        if asset_path.stem.isdigit() and asset_path not in expected_asset_paths:
            asset_path.unlink()

    arguments.readme.write_text(generated_readme, encoding="utf-8")
    print(f"Updated {arguments.readme} with {len(apps)} app(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
