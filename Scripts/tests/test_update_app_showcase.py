import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from update_app_showcase import (  # noqa: E402
    END_MARKER,
    START_MARKER,
    ShowcaseError,
    build_icon_asset,
    load_registry,
    render_showcase,
    update_readme,
)


class UpdateAppShowcaseTests(unittest.TestCase):
    def test_load_registry_accepts_ids_and_rejects_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "apps.json"
            registry.write_text(json.dumps({"appStoreIds": [1, 2]}), encoding="utf-8")
            self.assertEqual(load_registry(registry), [1, 2])

            registry.write_text(json.dumps({"appStoreIds": [1, 1]}), encoding="utf-8")
            with self.assertRaises(ShowcaseError):
                load_registry(registry)

    def test_load_registry_requires_named_app_store_ids_array(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "apps.json"
            registry.write_text(json.dumps([1, 2]), encoding="utf-8")
            with self.assertRaisesRegex(ShowcaseError, "JSON object"):
                load_registry(registry)

            registry.write_text(json.dumps({"apps": [1, 2]}), encoding="utf-8")
            with self.assertRaisesRegex(ShowcaseError, "appStoreIds"):
                load_registry(registry)

    def test_render_showcase_escapes_app_store_metadata(self):
        rendered = render_showcase(
            [
                {
                    "trackId": 123,
                    "trackName": "Notes & Tasks",
                    "artistName": "Example <Studio>",
                    "primaryGenreName": "Productivity",
                    "trackViewUrl": "https://apps.apple.com/app/id123?a=1&b=2",
                    "artworkUrl100": "https://example.com/icon?a=1&b=2",
                }
            ]
        )
        self.assertIn("Notes &amp; Tasks", rendered)
        self.assertIn("Example &lt;Studio&gt;", rendered)
        self.assertNotIn("App Store ID", rendered)
        self.assertIn("a=1&amp;b=2", rendered)
        self.assertIn("| Icon | App | Developer | Category |", rendered)
        self.assertNotIn("<td", rendered)

    def test_build_icon_asset_applies_estimated_apple_corner_radius(self):
        rendered = build_icon_asset(b"image data", "image/png")
        self.assertIn('rx="22"', rendered)
        self.assertIn('ry="22"', rendered)
        self.assertIn("data:image/png;base64,aW1hZ2UgZGF0YQ==", rendered)

    def test_update_readme_only_replaces_marked_content(self):
        readme = f"Before\n{START_MARKER}\nold\n{END_MARKER}\nAfter\n"
        self.assertEqual(
            update_readme(readme, "new"),
            f"Before\n{START_MARKER}\nnew\n{END_MARKER}\nAfter\n",
        )

    def test_update_readme_requires_markers(self):
        with self.assertRaises(ShowcaseError):
            update_readme("No markers", "new")


if __name__ == "__main__":
    unittest.main()
