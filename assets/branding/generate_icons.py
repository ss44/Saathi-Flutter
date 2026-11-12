"""Regenerate original Saathi speech-pair launcher assets with Pillow.
Run from anywhere: python3 assets/branding/generate_icons.py
"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SIZE = 1024
image = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((8, 8, 1016, 1016), radius=226, fill='#28483F')
# Two companions in conversation: mint behind, warm white in front.
draw.rounded_rectangle((390, 280, 822, 650), radius=100, fill='#A9CEBD')
draw.polygon([(690, 595), (792, 705), (789, 548)], fill='#A9CEBD')
draw.rounded_rectangle((202, 376, 658, 720), radius=100, fill='#FAFAF8')
draw.polygon([(227, 626), (225, 786), (351, 684)], fill='#FAFAF8')
for x in (324, 430, 536):
    draw.ellipse((x-22, 525, x+22, 569), fill='#3E6559')
output = ROOT / 'assets/branding/saathi-mark.png'
image.save(output)
for density, size in {'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}.items():
    image.resize((size,size), Image.Resampling.LANCZOS).save(
        ROOT / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
for size in (16,32,64,128,256,512,1024):
    image.resize((size,size), Image.Resampling.LANCZOS).save(
        ROOT / f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png')
print('Generated Saathi mark and Android/macOS launcher icons.')
