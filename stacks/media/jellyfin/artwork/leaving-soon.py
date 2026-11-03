# Poster for the Maintainerr "Leaving soon" collections (Jellyfin Primary image).
# Usage: python3 leaving-soon.py SHOWS out.png   (label, output file)
# Upload: POST /Items/<collection id>/Images/Primary, body = base64 of the PNG,
# Content-Type image/png. Redo it if Maintainerr recreates the collection.
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1000, 1500
FONT = str(__import__("pathlib").Path(__file__).resolve().parent.parent / "ui/fonts/inter-latin-wght-normal.woff2")
label = sys.argv[1] if len(sys.argv) > 1 else "SHOWS"
out = sys.argv[2] if len(sys.argv) > 2 else "leaving-soon.png"

def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    try: f.set_variation_by_axes([weight])
    except Exception as e: print("variation:", e)
    return f

# Frappé base #303446 -> crust #232634, top to bottom.
img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
for y in range(H):
    t = y / (H - 1)
    d.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip((48, 52, 70), (35, 38, 52))))

# Soft mauve glow behind the mark.
glow = Image.new("RGB", (W, H), 0)
ImageDraw.Draw(glow).ellipse([200, 260, 800, 860], fill=(202, 158, 230))
glow = glow.filter(ImageFilter.GaussianBlur(160))
img = Image.blend(img, Image.composite(glow, img, glow.convert("L").point(lambda v: v)), 0.35)
d = ImageDraw.Draw(img)

# Hourglass, minimal icon style (2026-11-03): one rounded stroke, drawn at
# 4x and scaled down for smooth edges. The sand is the lower glass cut at a
# fill line, drawn BEFORE the outline, so it reaches into the corners and the
# stroke covers its edge.
mauve, peach, text = (202, 158, 230), (239, 159, 118), (198, 208, 245)
S = 4
icon = Image.new("RGBA", (420 * S, 520 * S), (0, 0, 0, 0))
g = ImageDraw.Draw(icon)
cx, top, bot, half, neck = 210 * S, 60 * S, 460 * S, 140 * S, 260 * S
stroke = 26 * S
fill_y = neck + (bot - neck) * 0.42           # sand surface in the lower glass
def side(y):                                   # half width of the glass at y
    return half * abs(y - neck) / (bot - neck)
g.polygon([(cx - side(fill_y), fill_y), (cx + side(fill_y), fill_y), (cx + half, bot), (cx - half, bot)], fill=peach)
outline = [(cx - half, top), (cx + half, top), (cx, neck), (cx + half, bot), (cx - half, bot), (cx, neck), (cx - half, top)]
g.line(outline, fill=mauve, width=stroke, joint="curve")
for x, y in outline:                           # round the corners
    g.ellipse([x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2], fill=mauve)
for y in (top, bot):                           # caps, a bit wider than the glass
    g.line([(cx - half - 40 * S, y), (cx + half + 40 * S, y)], fill=mauve, width=stroke)
    for x in (cx - half - 40 * S, cx + half + 40 * S):
        g.ellipse([x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2], fill=mauve)
icon = icon.resize((420, 520), Image.LANCZOS)
img.paste(icon, (W // 2 - 210, 300), icon)

def center(txt, y, f, fill, spacing=0):
    if spacing:
        widths = [d.textlength(c, font=f) for c in txt]
        x = (W - (sum(widths) + spacing * (len(txt) - 1))) / 2
        for c, w in zip(txt, widths):
            d.text((x, y), c, font=f, fill=fill); x += w + spacing
    else:
        d.text(((W - d.textlength(txt, font=f)) / 2, y), txt, font=f, fill=fill)

center("Leaving", 900, font(150, 800), text)
center("Soon", 1060, font(150, 800), mauve)
center(label, 1290, font(44, 600), (165, 173, 206), spacing=14)
img.save(out, optimize=True)
print(out, img.size)
