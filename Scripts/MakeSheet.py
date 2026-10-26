# 26 October 2026, 13:00 CEST: builds the presentation sheet of the two orange widgets (recording capsule, result card) over the
# Create wallpaper. Used as the Assets project thumbnail and as the GitHub README header. Every value lives in PARAMS.
# FR : planche de présentation des deux widgets orangés ; miniature du projet Assets et en-tête du README GitHub.
# Usage: python3 Scripts/MakeSheet.py [out.png]
import os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARAMS = {
    'size': (1920, 1080),
    'wallpaper': '/Users/zenray/.claude/skills/zenray-edit/templates/liquid-glass/wallpaper.webp',
    'veil': 0.42,                                   # dark veil over the wallpaper (Liquid Glass template: 0.34)
    'shade_top': 0.60, 'shade_top_height': 0.42,    # extra darkening behind the title, fading out downwards
    'shade_bottom': 0.45, 'shade_bottom_height': 0.30,
    'widget_scale': 0.90,                           # the captures are 2 px per pt; 0.90 gives 1.8 px per pt on the 1920 px sheet
    'capsule': 'docs/widgets/capsule-claude-orange.png',
    'card': 'docs/widgets/card-claude-orange.png',
    'icon': 'docs/AppIcon-claude-1024.png',
    'icon_size': 150,
    'edge_inset': 40,                               # capsule distance to the right edge (px)
    'card_bottom': 120,                             # card distance to the bottom (px)
    'title': 'ZenRay Dictate',
    'subtitle': 'Dictée par la voix : Fn, parle, le texte arrive',
    'tag': 'harmonic-asr-8',
    'font_title': '/Users/zenray/Library/Fonts/GT-Sectra-LCGV-Regular-Italic.otf',
    'font_ui': '/Users/zenray/Library/Fonts/InterVariable.ttf',
    'font_title_size': 104, 'font_subtitle_size': 36, 'font_label_size': 28, 'title_gap': 40,
    'margin': 90,
}

def font(path, size, variation=None):
    f = ImageFont.truetype(path, size)
    if variation:
        try: f.set_variation_by_name(variation)
        except Exception: pass
    return f

def build(out):
    P = PARAMS; W, H = P['size']
    bg = Image.open(P['wallpaper']).convert('RGB')
    scale = max(W / bg.width, H / bg.height)
    bg = bg.resize((int(bg.width * scale) + 1, int(bg.height * scale) + 1), Image.LANCZOS)
    bg = bg.crop(((bg.width - W) // 2, (bg.height - H) // 2, (bg.width - W) // 2 + W, (bg.height - H) // 2 + H)).convert('RGBA')
    veil = Image.new('RGBA', (W, H), (10, 12, 16, int(255 * P['veil'])))
    bg.alpha_composite(veil)
    def shade(strength, height_ratio, from_top):
        h = int(H * height_ratio); layer = Image.new('RGBA', (W, h))
        px = layer.load()
        for y in range(h):
            t = 1 - y / h if from_top else y / h          # 1 at the edge, 0 at the inner end
            for x in range(W): px[x, y] = (8, 10, 14, int(255 * strength * t * t))
        bg.alpha_composite(layer, (0, 0 if from_top else H - h))
    shade(P['shade_top'], P['shade_top_height'], True); shade(P['shade_bottom'], P['shade_bottom_height'], False)
    d = ImageDraw.Draw(bg)

    icon = Image.open(os.path.join(ROOT, P['icon'])).convert('RGBA').resize((P['icon_size'], P['icon_size']), Image.LANCZOS)
    bg.alpha_composite(icon, (P['margin'], P['margin']))
    tx = P['margin'] + P['icon_size'] + 36
    d.text((tx, P['margin'] - 8), P['title'], font=font(P['font_title'], P['font_title_size']), fill=(255, 255, 255, 255))
    d.text((tx + 4, P['margin'] + P['font_title_size'] + P['title_gap']), P['subtitle'], font=font(P['font_ui'], P['font_subtitle_size'], 'Medium'), fill=(255, 255, 255, 215))

    def widget(name):
        img = Image.open(os.path.join(ROOT, P[name])).convert('RGBA')
        return img.resize((int(img.width * P['widget_scale']), int(img.height * P['widget_scale'])), Image.LANCZOS)
    capsule, card = widget('capsule'), widget('card')
    cx = W - P['edge_inset'] - capsule.width; cy = (H - capsule.height) // 2
    bg.alpha_composite(capsule, (cx, cy))
    kx = (W - card.width) // 2; ky = H - P['card_bottom'] - card.height
    bg.alpha_composite(card, (kx, ky))

    label = font(P['font_ui'], P['font_label_size'], 'Medium')
    capsule_label = 'Fn : tu parles'
    d.text((cx + capsule.width - d.textlength(capsule_label, font=label) - 8, cy - 46), capsule_label, font=label, fill=(255, 255, 255, 240))
    d.text((kx + 8, ky - 46), 'Fn encore : le texte, déjà copié', font=label, fill=(255, 255, 255, 240))
    d.text((P['margin'], H - P['margin'] - 8), P['tag'] + '  ·  Claude  ·  repli Whisper local', font=label, fill=(255, 255, 255, 170))
    bg.convert('RGB').save(out)
    return out

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'docs/ZenRayDictate-sheet.png')
    print(build(out), PARAMS['size'])
