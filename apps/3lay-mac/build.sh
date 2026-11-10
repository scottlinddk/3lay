#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build .cache
export CLANG_MODULE_CACHE_PATH="$PWD/.cache"
export SWIFT_MODULE_CACHE_PATH="$PWD/.cache"
. ./sources.sh
swiftc -disable-sandbox -swift-version 5 -parse-as-library $APP_SOURCES -o .build/ThreeLayMacOS -framework AppKit -framework SwiftUI
bundle="build/ThreeLayMacOS.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/ThreeLayMacOS "$bundle/Contents/MacOS/ThreeLayMacOS"
cp convert_usdz.swift "$bundle/Contents/Resources/convert_usdz.swift"
rm -rf "$bundle/Contents/Resources/skill"
cp -R skill "$bundle/Contents/Resources/skill"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ThreeLayMacOS</string>
  <key>CFBundleIdentifier</key><string>com.craftanything.threelaymacos</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>3lay Mac</string>
  <key>CFBundleDisplayName</key><string>3lay Mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>3lay Mac receives scans from your phone over your local network.</string>
  <key>NSBonjourServices</key><array><string>_threelaymacos._tcp</string></array>
</dict></plist>
PLIST
printf 'APPL????' > "$bundle/Contents/PkgInfo"
xattr -cr "$bundle"
codesign --force --deep --sign - "$bundle"
echo "Built $bundle"
