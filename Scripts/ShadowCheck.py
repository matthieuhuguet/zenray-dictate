# 25 October 2026: a rectangular window shadow fills the corners of the capsule rectangle. With a capsule shadow those
# corners stay as light as the background. Input: window capture with shadow, composited on white.
# FR : une ombre rectangulaire assombrit les coins du rectangle de la capsule ; une ombre en capsule les laisse clairs.
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGBA'); w, h = im.size
alpha = im.getchannel('A')
ys = [y for y in range(h) if alpha.getpixel((w // 2, y)) > 250]; xs = [x for x in range(w) if alpha.getpixel((x, h // 2)) > 250]
top, bottom, left, right = min(ys), max(ys), min(xs), max(xs)        # opaque capsule body
bg = Image.new('RGBA', im.size, (255, 255, 255, 255)); bg.alpha_composite(im); g = bg.convert('L')
# darkest pixel in a 8 px box straddling each corner of the body rectangle / pixel le plus sombre autour de chaque coin
def darkest(cx, cy): return min(g.getpixel((x, y)) for x in range(cx - 4, cx + 4) for y in range(cy - 4, cy + 4))
lum = [darkest(left, top), darkest(right, top), darkest(left, bottom), darkest(right, bottom)]
print(sys.argv[1].split('/')[-1], 'body', (left, top, right, bottom), 'corner luminance', lum, 'SQUARE' if min(lum) < 235 else 'capsule')
sys.exit(1 if min(lum) < 235 else 0)
