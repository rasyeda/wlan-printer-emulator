#!/bin/bash
# Build WLAN Printer.app - a self-contained macOS app, no Xcode project needed.
set -euo pipefail

cd "$(dirname "$0")"
APP="WLAN Printer.app"
BIN="WlanPrinterEmulator"
BUILD="build"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling…"
swiftc -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -framework SwiftUI -framework AppKit -framework Network \
    -framework CoreGraphics -framework ImageIO \
    Sources/*.swift \
    -o "$BUILD/$BIN"

cp "$BUILD/$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>WLAN Printer</string>
    <key>CFBundleDisplayName</key>       <string>WLAN Printer</string>
    <key>CFBundleIdentifier</key>        <string>com.rasyeda.wlanprinteremulator</string>
    <key>CFBundleExecutable</key>        <string>$BIN</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Receives print jobs from apps on your local network.</string>
</dict>
</plist>
PLIST

# App icon: a printer glyph rendered off an SF Symbol, no asset catalog needed.
if command -v iconutil >/dev/null; then
    ICONSET="$BUILD/AppIcon.iconset"
    mkdir -p "$ICONSET"
    /usr/bin/swift - "$ICONSET" >/dev/null 2>&1 <<'ICON' || true
import AppKit
let dir = CommandLine.arguments[1]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = CGFloat(size) * 0.22
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.74, alpha: 1)])
    gradient?.draw(in: rect, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.52,
                                             weight: .medium)
    if let symbol = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        let w = symbol.size.width, h = symbol.size.height
        tinted.draw(in: NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2,
                               width: w, height: h))
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let scale = size <= 32 ? size : size / 2
    try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(size)x\(size).png"))
    if size >= 32 {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(scale)x\(scale)@2x.png"))
    }
}
ICON
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || \
        echo "  (icon skipped)"
fi

# Ad-hoc signature so macOS will launch it and the firewall can remember it.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

rm -rf "$BUILD"
echo "built $APP"
echo "run it with:  open '$PWD/$APP'"
