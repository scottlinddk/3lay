#!/usr/bin/env bash
# Build and run both apps: 3lay Mac on this Mac, 3lay iOS on a connected iPhone.
#
#   DEVELOPMENT_TEAM=ABCDE12345 ./scripts/run-both.sh
#
# Options:
#   --xcode       Open both in Xcode instead (to run with the debugger), then stop.
#   --mac-only    Only build and launch the Mac app.
#   --ios-only    Only build, install and launch the iPhone app.
#
# Environment:
#   DEVELOPMENT_TEAM  Apple team ID used to sign the iPhone build (Xcode > Settings > Accounts,
#                     or developer.apple.com > Membership). Required for the iPhone.
#   DEVICE            Device name or identifier to use when more than one iPhone is connected.
#
# Needs Xcode 15+, xcodegen (brew install xcodegen), python3, and an iPhone that is paired, unlocked,
# trusted, and has Developer Mode on (Settings > Privacy & Security > Developer Mode).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$ROOT/apps/3lay-mac"
IOS_DIR="$ROOT/apps/3lay-ios"
IOS_BUNDLE_ID="app.scan3d.capture"
IOS_BUILD_DIR="$IOS_DIR/build"

DO_MAC=1; DO_IOS=1; OPEN_XCODE=0
for arg in "$@"; do
  case "$arg" in
    --xcode) OPEN_XCODE=1 ;;
    --mac-only) DO_IOS=0 ;;
    --ios-only) DO_MAC=0 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "This runs on macOS only."
command -v xcodebuild >/dev/null || die "Xcode is not installed or not selected (xcode-select -s)."

# --- iOS project (generated, not committed) --------------------------------------------------
gen_ios_project() {
  command -v xcodegen >/dev/null || die "xcodegen is missing. Run: brew install xcodegen"
  say "Generating ThreeLayIOS.xcodeproj"
  (cd "$IOS_DIR" && xcodegen generate)
}

if [ "$OPEN_XCODE" = 1 ]; then
  if [ "$DO_IOS" = 1 ]; then gen_ios_project; xed "$IOS_DIR/ThreeLayIOS.xcodeproj"; fi
  if [ "$DO_MAC" = 1 ]; then xed "$MAC_DIR"; fi
  cat <<MSG

Opened in Xcode. Run each one from its own window:
  - 3lay Mac: choose the ThreeLayMacOS scheme, destination "My Mac", then Run.
  - 3lay iOS: choose the ThreeLayIOS scheme, set your team under Signing & Capabilities,
    pick your iPhone as the destination, then Run.
MSG
  exit 0
fi

# --- Mac ---------------------------------------------------------------------------------------
if [ "$DO_MAC" = 1 ]; then
  say "Building 3lay Mac"
  (cd "$MAC_DIR" && ./build.sh)
  say "Launching 3lay Mac"
  # -n opens a fresh instance so a rebuilt app replaces one that is already running.
  pkill -x ThreeLayMacOS 2>/dev/null || true
  open -n "$MAC_DIR/build/ThreeLayMacOS.app"
fi

# --- iPhone ------------------------------------------------------------------------------------
if [ "$DO_IOS" = 1 ]; then
  [ -n "${DEVELOPMENT_TEAM:-}" ] || die "Set DEVELOPMENT_TEAM to your Apple team ID, e.g. DEVELOPMENT_TEAM=ABCDE12345 $0"
  command -v python3 >/dev/null || die "python3 is missing (xcode-select --install)."
  xcrun devicectl --version >/dev/null 2>&1 || die "devicectl needs Xcode 15 or later."

  say "Looking for a connected iPhone"
  DEVICES_JSON="$(mktemp)"; trap 'rm -f "$DEVICES_JSON"' EXIT
  xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || die "devicectl could not list devices."

  # Prints "<coredevice-id> <udid> <name>" for each available iPhone/iPad, one per line.
  PICK="$(DEVICE="${DEVICE:-}" python3 - "$DEVICES_JSON" <<'PY'
import json, os, sys
want = os.environ.get("DEVICE", "").lower()
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
rows = []
for d in devices:
    hw, conn, props = d.get("hardwareProperties", {}), d.get("connectionProperties", {}), d.get("deviceProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality", "physical") != "physical":
        continue
    if conn.get("tunnelState") == "unavailable":
        continue
    name = props.get("name", "iPhone")
    ident, udid = d.get("identifier", ""), hw.get("udid", "")
    if want and want not in (name.lower(), ident.lower(), udid.lower()):
        continue
    rows.append(f"{ident} {udid} {name}")
print("\n".join(rows))
PY
)"
  COUNT="$(printf '%s' "$PICK" | grep -c . || true)"
  [ "$COUNT" -ge 1 ] || die "No connected iPhone found. Connect it, unlock it, tap Trust, and turn on Developer Mode. 'xcrun devicectl list devices' shows what Xcode sees."
  [ "$COUNT" -eq 1 ] || die "More than one device found. Re-run with DEVICE=<name or id>:
$PICK"
  CORE_ID="$(printf '%s' "$PICK" | awk '{print $1}')"
  UDID="$(printf '%s' "$PICK" | awk '{print $2}')"
  NAME="$(printf '%s' "$PICK" | cut -d' ' -f3-)"
  echo "Using: $NAME"

  gen_ios_project
  say "Building 3lay iOS for $NAME (signing with team $DEVELOPMENT_TEAM)"
  xcodebuild -project "$IOS_DIR/ThreeLayIOS.xcodeproj" -scheme ThreeLayIOS \
    -configuration Debug -destination "id=$UDID" -derivedDataPath "$IOS_BUILD_DIR" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build

  APP="$IOS_BUILD_DIR/Build/Products/Debug-iphoneos/ThreeLayIOS.app"
  [ -d "$APP" ] || die "Build finished but $APP was not produced."

  say "Installing on $NAME"
  xcrun devicectl device install app --device "$CORE_ID" "$APP"
  say "Launching on $NAME (keep the phone unlocked)"
  xcrun devicectl device process launch --device "$CORE_ID" --terminate-existing "$IOS_BUNDLE_ID"
fi

say "Done"
[ "$DO_MAC" = 1 ] && echo "Mac app: running (look for 3lay Mac in the Dock)."
[ "$DO_IOS" = 1 ] && echo "iPhone app: launched. First time: allow Local Network and Camera when asked."
exit 0
