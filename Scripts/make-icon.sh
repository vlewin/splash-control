#!/bin/bash
# Renders AppIcon.icns from Resources/AppIcon.png into the multi-resolution iconset
# and compiles it with iconutil.

set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"

python3 -c "
import os, subprocess
from PIL import Image

src = Image.open('Resources/AppIcon.png')
iconset_dir = '$ICONSET'

specs = [
    ('icon_16x16.png', 16),
    ('icon_16x16@2x.png', 32),
    ('icon_32x32.png', 32),
    ('icon_32x32@2x.png', 64),
    ('icon_128x128.png', 128),
    ('icon_128x128@2x.png', 256),
    ('icon_256x256.png', 256),
    ('icon_256x256@2x.png', 512),
    ('icon_512x512.png', 512),
    ('icon_512x512@2x.png', 1024),
]

for filename, size in specs:
    resized = src.resize((size, size), Image.Resampling.LANCZOS)
    resized.save(os.path.join(iconset_dir, filename))
"

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
rm -rf "$ICONSET"
