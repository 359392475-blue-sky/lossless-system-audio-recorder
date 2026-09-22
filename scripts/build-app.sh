#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="无损系统录音机"
OUTPUT_DIR="${LOSSLESS_RECORDER_OUTPUT_DIR:-$PROJECT_DIR/dist}"
SCRATCH_DIR="${LOSSLESS_RECORDER_SCRATCH_DIR:-$PROJECT_DIR/.build}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
ICON_WORK_DIR="$SCRATCH_DIR/AppIcon.iconset"

# Validate before compiling or touching an output bundle. There is no offline build switch.
python3 "$SCRIPT_DIR/configure-release.py"

# Keep build-machine paths out of Swift runtime diagnostics and debug metadata.
# Resolve the scratch path so the mapping also covers caller-selected build directories.
SCRATCH_DIR="${SCRATCH_DIR:A}"
BUILD_ARGS=(-c release --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH_DIR"
            -Xswiftc -enable-upcoming-feature -Xswiftc ConciseMagicFile)
for mapping in "$PROJECT_DIR=/source/LosslessSystemAudioRecorder" "$SCRATCH_DIR=/build/LosslessSystemAudioRecorder"; do
  BUILD_ARGS+=(-Xswiftc -file-prefix-map -Xswiftc "$mapping"
              -Xswiftc -debug-prefix-map -Xswiftc "$mapping")
done
if [[ "${LOSSLESS_RECORDER_UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

if [[ -e "$APP_BUNDLE" ]]; then
  print -u2 "输出应用已存在，拒绝覆盖：$APP_BUNDLE。请指定新的 LOSSLESS_RECORDER_OUTPUT_DIR。"
  exit 1
fi

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$ICON_WORK_DIR"
cp "$BIN_DIR/LosslessSystemAudioRecorder" "$CONTENTS_DIR/MacOS/"
cp "$PROJECT_DIR/AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"

python3 "$SCRIPT_DIR/configure-release.py" --plist "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/LICENSE" "$CONTENTS_DIR/Resources/LICENSE.txt"
cp "$PROJECT_DIR/docs/privacy.md" "$CONTENTS_DIR/Resources/Privacy.md"

FRAMEWORK_SOURCE="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$FRAMEWORK_SOURCE" ]]; then
  print -u2 "Sparkle.framework missing from build products"; exit 1
fi
mkdir -p "$CONTENTS_DIR/Frameworks"
ditto "$FRAMEWORK_SOURCE" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
cp "$SCRATCH_DIR/checkouts/Sparkle/LICENSE" "$CONTENTS_DIR/Resources/Sparkle-LICENSE.txt"

MASTER_ICON="$SCRATCH_DIR/AppIcon-1024.png"
swift "$PROJECT_DIR/scripts/generate-icon.swift" "$MASTER_ICON"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512" "1024:512x512@2x"; do
  pixels="${spec%%:*}"
  name="${spec#*:}"
  sips -z "$pixels" "$pixels" "$MASTER_ICON" --out "$ICON_WORK_DIR/icon_$name.png" >/dev/null
done
iconutil -c icns "$ICON_WORK_DIR" -o "$CONTENTS_DIR/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS_DIR/Info.plist"

SIGNING_IDENTITY="${LOSSLESS_RECORDER_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application:/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/ { print $2; exit }')"
fi

SIGN_ARGS=(--force --sign "${SIGNING_IDENTITY:--}")
if [[ -n "$SIGNING_IDENTITY" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
  print "Signing: stable Apple code-signing identity"
else
  print -u2 "Warning: no Apple signing identity found; local ad-hoc signature only."
fi
# Sign nested executables first, then their containers; do not rely on --deep signing.
SPARKLE="$CONTENTS_DIR/Frameworks/Sparkle.framework/Versions/B"
for nested in "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc"; do
  [[ -e "$nested" ]] || { print -u2 "Sparkle helper missing: $nested"; exit 1; }
  codesign "${SIGN_ARGS[@]}" "$nested"
done
codesign "${SIGN_ARGS[@]}" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
plutil -lint "$CONTENTS_DIR/Info.plist"

print "$APP_BUNDLE"
