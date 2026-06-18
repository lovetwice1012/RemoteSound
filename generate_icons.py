#!/usr/bin/env python3
"""Generate placeholder app icons for RemoteSound"""
from PIL import Image, ImageDraw

# Icon sizes and names from Contents.json
icons = [
    ("icon-20@2x.png", 40, 40),
    ("icon-20@3x.png", 60, 60),
    ("icon-29@2x.png", 58, 58),
    ("icon-29@3x.png", 87, 87),
    ("icon-40@2x.png", 80, 80),
    ("icon-40@3x.png", 120, 120),
    ("icon-60@2x.png", 120, 120),
    ("icon-60@3x.png", 180, 180),
    ("icon-20-ipad.png", 20, 20),
    ("icon-20-ipad@2x.png", 40, 40),
    ("icon-29-ipad.png", 29, 29),
    ("icon-29-ipad@2x.png", 58, 58),
    ("icon-40-ipad.png", 40, 40),
    ("icon-40-ipad@2x.png", 80, 80),
    ("icon-76-ipad.png", 76, 76),
    ("icon-76-ipad@2x.png", 152, 152),
    ("icon-83.5-ipad@2x.png", 167, 167),
    ("icon-1024.png", 1024, 1024),
]

# Color from AccentColor.colorset - RGB(26, 178, 152)
color = (26, 178, 152, 255)  # RGBA

output_dir = "RemoteSound/Assets.xcassets/AppIcon.appiconset"

for filename, width, height in icons:
    img = Image.new("RGBA", (width, height), color)
    
    # Add a simple border
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, width-1, height-1], outline=(255, 255, 255, 255), width=2)
    
    filepath = f"{output_dir}/{filename}"
    img.save(filepath)
    print(f"Generated {filepath}")

print(f"\nGenerated {len(icons)} app icons successfully!")
