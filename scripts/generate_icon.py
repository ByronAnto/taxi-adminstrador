"""Generate a 1024x1024 app icon for Taxi Jipijapa."""
from PIL import Image, ImageDraw, ImageFont
import math
import os

SIZE = 1024
img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# === Background: rounded square with gradient-like effect ===
# Primary color: #1565C0 (dark blue), Accent: #FFC107 (amber/taxi yellow)
BG_COLOR = (21, 101, 192)  # AppTheme.primaryColor
ACCENT = (255, 193, 7)     # AppTheme.accentColor / taxi yellow
WHITE = (255, 255, 255)
DARK = (13, 71, 161)

# Draw rounded rectangle background
corner_radius = 200
draw.rounded_rectangle(
    [(0, 0), (SIZE - 1, SIZE - 1)],
    radius=corner_radius,
    fill=BG_COLOR,
)

# Draw a subtle darker band at the bottom third for depth
draw.rounded_rectangle(
    [(0, SIZE // 2), (SIZE - 1, SIZE - 1)],
    radius=corner_radius,
    fill=DARK,
)
# Re-draw middle overlap to blend
draw.rectangle(
    [(0, SIZE // 2), (SIZE - 1, SIZE // 2 + corner_radius)],
    fill=DARK,
)

# === Taxi car silhouette (simplified) ===
# Draw a yellow taxi car shape in the center

cx, cy = SIZE // 2, SIZE // 2 + 40

# Car body (main rectangle)
body_w, body_h = 520, 180
body_left = cx - body_w // 2
body_top = cy - body_h // 2 + 30
draw.rounded_rectangle(
    [(body_left, body_top), (body_left + body_w, body_top + body_h)],
    radius=40,
    fill=ACCENT,
)

# Car roof / cabin
roof_w, roof_h = 300, 160
roof_left = cx - roof_w // 2 + 20
roof_top = body_top - roof_h + 30
# Trapezoid-like roof using polygon
draw.polygon(
    [
        (roof_left + 30, body_top),
        (roof_left + roof_w - 30, body_top),
        (roof_left + roof_w + 40, body_top),
        (roof_left - 40, body_top),
        (roof_left + 20, roof_top),
        (roof_left + roof_w - 20, roof_top),
    ],
    fill=ACCENT,
)

# Windows (dark blue)
win_margin = 15
# Left window
draw.rounded_rectangle(
    [
        (roof_left + 25, roof_top + win_margin),
        (cx - 8, body_top - win_margin),
    ],
    radius=15,
    fill=DARK,
)
# Right window
draw.rounded_rectangle(
    [
        (cx + 8, roof_top + win_margin),
        (roof_left + roof_w - 25, body_top - win_margin),
    ],
    radius=15,
    fill=DARK,
)

# Taxi light on top
light_w, light_h = 80, 35
light_left = cx - light_w // 2 + 20
light_top = roof_top - light_h + 5
draw.rounded_rectangle(
    [(light_left, light_top), (light_left + light_w, light_top + light_h)],
    radius=12,
    fill=WHITE,
)

# Headlights
draw.ellipse(
    [(body_left + body_w - 30, body_top + 50), (body_left + body_w + 15, body_top + 90)],
    fill=WHITE,
)
draw.ellipse(
    [(body_left - 15, body_top + 50), (body_left + 30, body_top + 90)],
    fill=WHITE,
)

# Wheels
wheel_r = 50
# Left wheel
wl_cx = body_left + 100
wl_cy = body_top + body_h - 10
draw.ellipse(
    [(wl_cx - wheel_r, wl_cy - wheel_r), (wl_cx + wheel_r, wl_cy + wheel_r)],
    fill=(50, 50, 50),
)
draw.ellipse(
    [(wl_cx - wheel_r + 15, wl_cy - wheel_r + 15), (wl_cx + wheel_r - 15, wl_cy + wheel_r - 15)],
    fill=(150, 150, 150),
)
# Right wheel
wr_cx = body_left + body_w - 100
wr_cy = body_top + body_h - 10
draw.ellipse(
    [(wr_cx - wheel_r, wr_cy - wheel_r), (wr_cx + wheel_r, wr_cy + wheel_r)],
    fill=(50, 50, 50),
)
draw.ellipse(
    [(wr_cx - wheel_r + 15, wr_cy - wheel_r + 15), (wr_cx + wheel_r - 15, wr_cy + wheel_r - 15)],
    fill=(150, 150, 150),
)

# === Text "TAXI" below the car ===
text = "JIPIJAPA"
try:
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 80)
except:
    font = ImageFont.load_default()

bbox = draw.textbbox((0, 0), text, font=font)
tw = bbox[2] - bbox[0]
text_x = (SIZE - tw) // 2
text_y = body_top + body_h + 80
draw.text((text_x, text_y), text, fill=WHITE, font=font)

# Small "TAXI" label above
small_text = "TAXI"
try:
    small_font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 50)
except:
    small_font = ImageFont.load_default()

bbox2 = draw.textbbox((0, 0), small_text, font=small_font)
tw2 = bbox2[2] - bbox2[0]
draw.text(((SIZE - tw2) // 2, text_y - 65), small_text, fill=ACCENT, font=small_font)

# === Save ===
output = "/home/byron-realpe/Repositorios/taxis/assets/icon/app_icon.png"
img.save(output, "PNG")
print(f"Icon saved: {output} ({os.path.getsize(output)} bytes)")

# Also save an adaptive icon foreground (with transparent padding)
adaptive = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
# Paste the icon centered with some padding for adaptive icon safe zone
padding = 100
icon_resized = img.resize((SIZE - padding * 2, SIZE - padding * 2), Image.LANCZOS)
adaptive.paste(icon_resized, (padding, padding), icon_resized)
adaptive_path = "/home/byron-realpe/Repositorios/taxis/assets/icon/app_icon_foreground.png"
adaptive.save(adaptive_path, "PNG")
print(f"Adaptive foreground saved: {adaptive_path}")
