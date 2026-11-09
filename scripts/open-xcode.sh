#!/bin/sh
# Generates both Xcode projects and opens 3lay.xcworkspace (3lay iOS, 3lay Mac, packages/scan-link).
# Usage: scripts/open-xcode.sh [--no-open]   (--no-open: generate and resolve only, used by CI)
# Rerun after pulling changes to a project.yml or adding source files.
set -eu
cd "$(dirname "$0")/.."

open_workspace=1
for arg in "$@"; do
  case "$arg" in
    --no-open) open_workspace=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo "This needs macOS with Xcode." >&2; exit 1; }
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required, but only the Command Line Tools are selected." >&2
  echo "Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || { echo "Install Homebrew (https://brew.sh), then rerun." >&2; exit 1; }
  echo "Installing xcodegen with Homebrew..."
  brew install xcodegen
fi

(cd apps/3lay-ios && xcodegen generate)
(cd apps/3lay-mac && xcodegen generate)

# Resolve the local path packages now so the first build in Xcode needs no network or extra step.
for scheme in ThreeLayIOS ThreeLayMacOS; do
  xcodebuild -resolvePackageDependencies -workspace 3lay.xcworkspace -scheme "$scheme" >/dev/null
done

if [ "$open_workspace" = 1 ]; then
  open 3lay.xcworkspace
else
  echo "Generated projects and resolved packages."
fi
