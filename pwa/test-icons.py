import json
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).parent


class PwaAssetsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ROOT / "manifest.webmanifest").read_text())

    def test_manifest_fields(self):
        expected = {
            "id": "/",
            "start_url": "/",
            "scope": "/",
            "display": "standalone",
            "name": "RezeptDB",
            "short_name": "RezeptDB",
            "lang": "de",
            "theme_color": "#014463",
            "background_color": "#ffffff",
        }
        for field, value in expected.items():
            with self.subTest(field=field):
                self.assertEqual(self.manifest[field], value)

    def test_manifest_icons(self):
        expected_icons = {
            "/pwa/icons/chef-hat-192.png": (192, "any"),
            "/pwa/icons/chef-hat-512.png": (512, "any"),
            "/pwa/icons/chef-hat-maskable-512.png": (512, "maskable"),
        }
        manifest_icons = {icon["src"]: icon for icon in self.manifest["icons"]}
        self.assertEqual(set(manifest_icons), set(expected_icons))

        for source, (size, purpose) in expected_icons.items():
            with self.subTest(source=source):
                icon = manifest_icons[source]
                self.assertEqual(icon["sizes"], f"{size}x{size}")
                self.assertEqual(icon["type"], "image/png")
                self.assertEqual(icon["purpose"], purpose)
                self.assert_png(ROOT / source.removeprefix("/pwa/"), size)

    def test_apple_touch_icon(self):
        self.assert_png(ROOT / "icons/apple-touch-icon.png", 180)

    def assert_png(self, path, size):
        data = path.read_bytes()
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(struct.unpack(">II", data[16:24]), (size, size))


if __name__ == "__main__":
    unittest.main()
