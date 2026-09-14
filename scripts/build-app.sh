#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="无损系统录音机"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
ICON_WORK_DIR="$PROJECT_DIR/.build/AppIcon.iconset"

BUILD_ARGS=(-c release --package-path "$PROJECT_DIR")
if [[ "${LOSSLESS_RECORDER_UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

if [[ -e "$APP_BUNDLE" ]]; then
  case "$APP_BUNDLE" in
    "$PROJECT_DIR"/dist/*.app) rm -r "$APP_BUNDLE" ;;
    *) print -u2 "拒绝清理非 dist 应用路径：$APP_BUNDLE"; exit 1 ;;
  esac
fi

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$ICON_WORK_DIR"
cp "$BIN_DIR/LosslessSystemAudioRecorder" "$CONTENTS_DIR/MacOS/"
cp "$PROJECT_DIR/AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"

MASTER_ICON="$PROJECT_DIR/.build/AppIcon-1024.png"
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

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  print "Signing: stable Apple code-signing identity"
else
  codesign --force --deep --sign - "$APP_BUNDLE"
  print -u2 "Warning: no Apple signing identity found; screen-recording permission may need to be granted again after rebuilding."
fi
codesign --verify --deep --strict "$APP_BUNDLE"
plutil -lint "$CONTENTS_DIR/Info.plist"

print "$APP_BUNDLE"
