#!/usr/bin/env python3
"""Draws the PaneLink icon (Mac screen beaming to two Windows monitors) and exports every format:
mac/Resources/AppIcon.icns, mac/Resources/MenuIcon{On,Off}{,@2x}.png (template), windows/panelink.ico."""
import os, subprocess, shutil, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 4096                      # supersampled canvas, downscaled for anti-aliasing

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def gradient(size, c0, c1, angle=135):
    w, h = size
    g = Image.new("RGBA", (256, 1))
    for x in range(256): g.putpixel((x, 0), lerp(c0, c1, x / 255))
    g = g.resize((int(math.hypot(w, h)) + 2, int(math.hypot(w, h)) + 2))
    g = g.rotate(-angle + 90 if False else angle - 180, resample=Image.BICUBIC, expand=False)
    l = (g.width - w) // 2; t = (g.height - h) // 2
    return g.crop((l, t, l + w, t + h))

def rrect_mask(size, box, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, r, fill=255)
    return m

def paste_grad(img, box, r, c0, c1, angle=135):
    x0, y0, x1, y1 = [int(v) for v in box]
    g = gradient((x1 - x0, y1 - y0), c0, c1, angle)
    m = rrect_mask((x1 - x0, y1 - y0), (0, 0, x1 - x0 - 1, y1 - y0 - 1), r)
    img.paste(g, (x0, y0), m)

def shadow(img, box, r, blur, offset, alpha):
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([box[0], box[1] + offset, box[2], box[3] + offset], r, fill=(0, 0, 0, alpha))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur)))

def monitor(img, cx, cy, w, h, screen0, screen1, frame=(236, 241, 252, 255), stand=True):
    """Bezel + screen + stand, centred at (cx, cy) for the panel."""
    x0, y0, x1, y1 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
    shadow(img, (x0, y0, x1, y1), w * 0.06, S * 0.012, S * 0.012, 110)
    if stand:
        d = ImageDraw.Draw(img)
        sw = w * 0.10
        d.rectangle([cx - sw / 2, y1 - h * 0.02, cx + sw / 2, y1 + h * 0.16], fill=(205, 214, 235, 255))
        d.rounded_rectangle([cx - w * 0.22, y1 + h * 0.14, cx + w * 0.22, y1 + h * 0.20], h * 0.03, fill=(220, 228, 246, 255))
    paste_grad(img, (x0, y0, x1, y1), w * 0.06, frame, (196, 207, 232, 255), 160)
    b = w * 0.045
    paste_grad(img, (x0 + b, y0 + b, x1 - b, y1 - b), w * 0.035, screen0, screen1, 135)
    # glass sheen
    sheen = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sheen).polygon([(x0 + b, y0 + b), (x0 + (x1 - x0) * 0.55, y0 + b), (x0 + b, y0 + (y1 - y0) * 0.75)], fill=(255, 255, 255, 38))
    m = rrect_mask(img.size, (x0 + b, y0 + b, x1 - b, y1 - b), w * 0.035)
    img.alpha_composite(Image.composite(sheen, Image.new("RGBA", img.size, (0, 0, 0, 0)), m))

def app_icon():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # macOS icon grid: 824/1024 body, ~185/1024 corner radius
    m = S * 100 / 1024; body = (m, m, S - m, S - m); r = S * 185 / 1024
    shadow(img, body, r, S * 0.02, S * 0.012, 120)
    paste_grad(img, body, r, (24, 30, 82, 255), (46, 108, 255, 255), 135)
    # soft glow where the beam travels
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([S * 0.42, S * 0.44, S * 0.78, S * 0.80], fill=(120, 220, 255, 80))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S * 0.07)))

    # the two Windows monitors (one landscape, one portrait, like the real desk), then the Mac in front
    monitor(img, S * 0.465, S * 0.385, S * 0.40, S * 0.25, (40, 215, 255, 255), (60, 110, 255, 255))
    monitor(img, S * 0.775, S * 0.415, S * 0.175, S * 0.31, (90, 235, 210, 255), (40, 150, 255, 255))
    monitor(img, S * 0.315, S * 0.69, S * 0.29, S * 0.195, (255, 190, 90, 255), (255, 95, 140, 255), stand=False)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([S * 0.145, S * 0.69 + S * 0.0975, S * 0.485, S * 0.69 + S * 0.127], S * 0.012, fill=(214, 222, 242, 255))

    # beam: arcs from the Mac's corner up towards the monitors
    beam = Image.new("RGBA", img.size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(beam)
    c = (S * 0.505, S * 0.70)
    for i, rad in enumerate([S * 0.055, S * 0.095, S * 0.135]):
        bd.arc([c[0] - rad, c[1] - rad, c[0] + rad, c[1] + rad], -72, -8, fill=(255, 255, 255, 255 - i * 50), width=int(S * 0.02))
    img.alpha_composite(beam.filter(ImageFilter.GaussianBlur(S * 0.003)))
    return img

def menu_icon(filled):
    """Template image: black + alpha, drawn on an 18 pt grid."""
    n = 18 * 16
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    u = n / 18
    lw = int(u * 1.5)
    def screen(x0, y0, x1, y1):
        if filled:
            d.rounded_rectangle([x0 * u, y0 * u, x1 * u, y1 * u], u * 1.4, fill=(0, 0, 0, 255))
        else:
            d.rounded_rectangle([x0 * u, y0 * u, x1 * u, y1 * u], u * 1.4, outline=(0, 0, 0, 255), width=lw)
    screen(4.2, 1.2, 12.6, 7.4)             # Windows landscape monitor
    screen(13.6, 1.2, 17.4, 9.6)            # Windows portrait monitor
    screen(1.2, 9.6, 7.8, 14.6)             # Mac
    d.rounded_rectangle([0.3 * u, 15.3 * u, 8.7 * u, 16.7 * u], u * 0.6, fill=(0, 0, 0, 255))
    cx, cy = 8.8 * u, 14.2 * u               # beam from the Mac towards the monitors
    for rad in [2.2, 4.0]:
        d.arc([cx - rad * u, cy - rad * u, cx + rad * u, cy + rad * u], -80, -10, fill=(0, 0, 0, 255), width=int(u * 1.3))
    return img

def main():
    icon = app_icon()
    res = os.path.join(ROOT, "mac", "Resources")
    os.makedirs(res, exist_ok=True)
    iconset = os.path.join(res, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True); os.makedirs(iconset)
    for pt in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(res, "AppIcon.icns")], check=True)
    shutil.rmtree(iconset)
    icon.resize((1024, 1024), Image.LANCZOS).save(os.path.join(res, "AppIcon-1024.png"))
    for filled, nm in [(True, "MenuIconOn"), (False, "MenuIconOff")]:
        m = menu_icon(filled)
        m.resize((18, 18), Image.LANCZOS).save(os.path.join(res, f"{nm}.png"))
        m.resize((36, 36), Image.LANCZOS).save(os.path.join(res, f"{nm}@2x.png"))
    # Windows: square icon, a touch less margin than the macOS grid
    win = icon.crop((int(S * 0.07), int(S * 0.07), int(S * 0.93), int(S * 0.93)))
    win.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, "windows", "panelink.ico"),
                                               sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icons written")

main()
