#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# SlapMac build script — no Xcode IDE required.
# Requires: Xcode Command Line Tools  →  xcode-select --install
# Usage:    bash build.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Preflight ─────────────────────────────────────────────────────────────────
if ! command -v swiftc &>/dev/null; then
    echo "❌  swiftc not found."
    echo "    Install Xcode Command Line Tools and try again:"
    echo "    xcode-select --install"
    exit 1
fi

SWIFT_VERSION=$(swiftc --version 2>&1 | head -1)
echo "╔══════════════════════════════════════════╗"
echo "║          SlapMac — build.sh              ║"
echo "╚══════════════════════════════════════════╝"
echo "  Swift: $SWIFT_VERSION"
echo ""

# ── Directories ───────────────────────────────────────────────────────────────
BUILD="build"
APP_BUNDLE="$BUILD/SlapMac.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

rm -rf "$BUILD"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

# Resolve the macOS SDK path so swiftc finds all system frameworks
SDK=$(xcrun --sdk macosx --show-sdk-path)

# ── 1. SlapMacDaemon ──────────────────────────────────────────────────────────
echo "▶  Compiling SlapMacDaemon..."
xcrun swiftc \
    SlapMacDaemon/main.swift \
    SlapMacDaemon/AccelerometerReader.swift \
    SlapMacDaemon/ImpactDetector.swift \
    SlapMacDaemon/SocketServer.swift \
    Shared/ImpactEvent.swift \
    -sdk "$SDK" \
    -framework Foundation \
    -framework IOKit \
    -o "$BUILD/SlapMacDaemon"
echo "   ✓ build/SlapMacDaemon"

# ── 2. SlapMacApp ─────────────────────────────────────────────────────────────
echo ""
echo "▶  Compiling SlapMac.app..."
# -parse-as-library: tells swiftc the entry point comes from @main, not main.swift
xcrun swiftc \
    -parse-as-library \
    SlapMacApp/AppDelegate.swift \
    SlapMacApp/MenuBarController.swift \
    SlapMacApp/AudioManager.swift \
    SlapMacApp/DaemonConnection.swift \
    Shared/ImpactEvent.swift \
    -sdk "$SDK" \
    -framework Foundation \
    -framework AppKit \
    -framework AVFoundation \
    -framework Combine \
    -o "$APP_MACOS/SlapMac"
echo "   ✓ $APP_MACOS/SlapMac"

# ── 3. Assemble app bundle ────────────────────────────────────────────────────
echo ""
echo "▶  Assembling bundle..."

# Info.plist — hardcoded values (no Xcode variable substitution needed)
cat > "$APP_CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SlapMac</string>
    <key>CFBundleIdentifier</key>
    <string>com.personal.slapmac</string>
    <key>CFBundleExecutable</key>
    <string>SlapMac</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <!-- Hides the app from the Dock and App Switcher -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
echo "   ✓ Info.plist"

# Sounds — copy both .wav and .mp3
mkdir -p "$APP_RESOURCES/Sounds"
COUNT=0
for ext in wav mp3; do
    if ls Sounds/*.$ext &>/dev/null 2>&1; then
        cp Sounds/*.$ext "$APP_RESOURCES/Sounds/"
        N=$(ls Sounds/*.$ext | wc -l | tr -d ' ')
        COUNT=$((COUNT + N))
    fi
done
if [ $COUNT -gt 0 ]; then
    echo "   ✓ $COUNT sound files copied"
else
    echo "   ⚠  No .wav/.mp3 files found in Sounds/ — run: python3 Sounds/generate_sounds.py"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Build complete!                         ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  App bundle:  $APP_BUNDLE"
echo "  Daemon:      $BUILD/SlapMacDaemon"
echo ""
echo "  ┌─ How to run ─────────────────────────────"
echo "  │  1. sudo $(pwd)/$BUILD/SlapMacDaemon"
echo "  │  2. open $(pwd)/$APP_BUNDLE"
echo "  └──────────────────────────────────────────"
echo ""
