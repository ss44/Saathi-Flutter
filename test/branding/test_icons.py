"""Checks the generated native icon identity (Pillow required)."""
import unittest
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]

class BrandingIconsTest(unittest.TestCase):
    def test_native_icons_use_saathi_green(self):
        paths = [ROOT / 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
                 ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
                 ROOT / 'windows/runner/resources/app_icon.ico']
        for path in paths:
            with self.subTest(path=path), Image.open(path) as icon:
                rgb = icon.convert('RGB')
                self.assertEqual(rgb.getpixel((rgb.width // 2, rgb.height // 8)), (40, 72, 63))

if __name__ == '__main__':
    unittest.main()
