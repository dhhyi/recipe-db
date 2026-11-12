import json
import struct
from pathlib import Path


root = Path(__file__).parent
manifest = json.loads((root / "manifest.webmanifest").read_text())

assert manifest["id"] == "/"
assert manifest["start_url"] == "/"
assert manifest["scope"] == "/"
assert manifest["display"] == "standalone"
assert manifest["name"] == manifest["short_name"] == "RezeptDB"
assert manifest["lang"] == "de"
assert manifest["theme_color"] == "#014463"
assert manifest["background_color"] == "#ffffff"

expected_icons = {
    "/pwa/icons/chef-hat-192.png": (192, "any"),
    "/pwa/icons/chef-hat-512.png": (512, "any"),
    "/pwa/icons/chef-hat-maskable-512.png": (512, "maskable"),
}
manifest_icons = {icon["src"]: icon for icon in manifest["icons"]}
assert set(manifest_icons) == set(expected_icons)

for source, (size, purpose) in expected_icons.items():
    icon = manifest_icons[source]
    assert icon["sizes"] == f"{size}x{size}"
    assert icon["type"] == "image/png"
    assert icon["purpose"] == purpose
    data = (root / source.removeprefix("/pwa/")).read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    assert struct.unpack(">II", data[16:24]) == (size, size)

data = (root / "icons/apple-touch-icon.png").read_bytes()
assert data.startswith(b"\x89PNG\r\n\x1a\n")
assert struct.unpack(">II", data[16:24]) == (180, 180)
