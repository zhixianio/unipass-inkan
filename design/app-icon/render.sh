#!/bin/sh
# Regenerates everything derived from the two source SVGs:
#   textured-1024.png        inkan-icon-textured.svg rasterized by headless Chrome (AppKit can't render SVG filters);
#                            kept in the repo so the rest runs without Chrome
#   ios-1024.png             iOS icon: the plain artwork, full bleed, opaque sRGB, no alpha (the signer uses it)
#   macos-clean-1024.png     macOS icon (Big Sur grid) from the plain artwork
#   macos-textured-1024.png  macOS icon from the textured artwork
#   apps/coordinator/Coordinator/Assets.xcassets/AppIcon.appiconset:
#                            128 px and smaller from the plain version (the ink texture turns into noise when small),
#                            256 px and larger from the textured version
# Run from anywhere:
#   sh design/app-icon/render.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
catalog="$repo/apps/coordinator/Coordinator/Assets.xcassets"
appicon="$catalog/AppIcon.appiconset"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -x "$chrome" ]; then
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$tmp/chrome" \
    --window-size=1024,1024 --screenshot="$here/textured-1024.png" "file://$here/inkan-icon-textured.svg" 2>/dev/null
else
  echo "Google Chrome not found: keeping the existing textured-1024.png" >&2
fi

swift "$here/render.swift" "$here/inkan-icon-clean.svg" "$here/ios-1024.png" "$here/macos-clean-1024.png"
swift "$here/render.swift" "$here/textured-1024.png" "$tmp/textured-full.png" "$here/macos-textured-1024.png"

mkdir -p "$appicon"
rm -f "$appicon"/icon_*.png

images=""
for s in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((s * scale))
    if [ "$scale" = 1 ]; then name="icon_${s}x${s}.png"; else name="icon_${s}x${s}@2x.png"; fi
    if [ "$px" -le 128 ]; then src="$here/macos-clean-1024.png"; else src="$here/macos-textured-1024.png"; fi
    if [ "$px" = 1024 ]; then
      cp "$src" "$appicon/$name"
    else
      sips -z "$px" "$px" "$src" --out "$appicon/$name" >/dev/null
    fi
    [ -n "$images" ] && images="$images,"
    images="$images
    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${s}x${s}\" }"
  done
done

cat > "$appicon/Contents.json" <<EOF
{
  "images" : [$images
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

cat > "$catalog/Contents.json" <<'EOF'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

echo "wrote $catalog"
