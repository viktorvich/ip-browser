#!/usr/bin/env python3
"""IP Browser icon: a globe on a deep blue field with a single bright exit point. Reproducible (Pillow)."""
from PIL import Image, ImageDraw
from pathlib import Path
import json

S = 3
img = Image.new('RGB', (1024 * S, 1024 * S), '#0b1f4d')
d = ImageDraw.Draw(img)
b = lambda v: tuple(round(n * S) for n in v)
ink = '#8fb8ff'
d.ellipse(b((170, 170, 854, 854)), outline=ink, width=26 * S)
d.ellipse(b((352, 170, 672, 854)), outline=ink, width=22 * S)
d.line([b((170, 512)), b((854, 512))], fill=ink, width=22 * S)
d.arc(b((170, 300, 854, 640)), 180, 360, fill=ink, width=20 * S)
d.arc(b((170, 384, 854, 724)), 0, 180, fill=ink, width=20 * S)
# The one exit: a bright dot on the globe's edge with a ring.
d.ellipse(b((700, 160, 900, 360)), fill='#0b1f4d')
d.ellipse(b((728, 188, 872, 332)), outline='#ffffff', width=18 * S)
d.ellipse(b((768, 228, 832, 292)), fill='#ffffff')
out = Path(__file__).resolve().parent.parent / 'App/Assets.xcassets/AppIcon.appiconset'
out.mkdir(parents=True, exist_ok=True)
img.resize((1024, 1024), Image.Resampling.LANCZOS).save(out / 'AppIcon.png')
(out / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
(out.parent / 'Contents.json').write_text('{"info":{"author":"xcode","version":1}}\n')
