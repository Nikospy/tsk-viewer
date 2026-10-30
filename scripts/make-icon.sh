#!/bin/bash
# Renders Support/AppIcon.icns from the pixel mascot in NotificationSprite.swift.
# Pass a path to also keep the 1024 px PNG preview. Run after changing the `board` sprite, then rebuild with scripts/build-app.sh.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# The sprite file is compiled alone, so TskCore is replaced by the one type it uses.
sed '/^import TskCore$/d' "$repo_root/Sources/TskViewer/NotificationSprite.swift" > "$work/sprite.swift"
cat > "$work/main.swift" <<'EOF'
import AppKit
enum TskStatus { case review, done, blocked }

let side = 1024
let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
    CGColor(srgbRed: 0.36, green: 0.38, blue: 0.70, alpha: 1),
    CGColor(srgbRed: 0.18, green: 0.18, blue: 0.38, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.interpolationQuality = .none
ctx.draw(NotificationSprite.render(.board)!, in: CGRect(x: 160, y: 130, width: 704, height: 704))
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF

swiftc -O "$work/sprite.swift" "$work/main.swift" -o "$work/make-icon"
"$work/make-icon" "$work/icon.png"

iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$repo_root/Support/AppIcon.icns"
if [[ -n "${1:-}" ]]; then cp "$work/icon.png" "$1"; fi
printf 'Wrote %s\n' "$repo_root/Support/AppIcon.icns"
