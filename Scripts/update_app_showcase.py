#!/usr/bin/env python3
"""Generate the README app showcase from App Store IDs."""

from __future__ import annotations

import argparse
import html
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REGISTRY = ROOT / "app.json"
DEFAULT_README = ROOT / "README.md"
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


def render_showcase(apps: list[dict[str, Any]]) -> str:
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
        icon = table_safe(required_string(app, "artworkUrl100"), attribute=True)
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
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        entries = load_registry(arguments.registry)
        apps = fetch_apps(entries)
        existing_readme = arguments.readme.read_text(encoding="utf-8")
        generated_readme = update_readme(existing_readme, render_showcase(apps))
    except (OSError, ShowcaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if arguments.check:
        if generated_readme != existing_readme:
            print(
                "error: README app showcase is stale; run "
                "python3 Scripts/update_app_showcase.py",
                file=sys.stderr,
            )
            return 1
        print("README app showcase is up to date.")
        return 0

    arguments.readme.write_text(generated_readme, encoding="utf-8")
    print(f"Updated {arguments.readme} with {len(apps)} app(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
