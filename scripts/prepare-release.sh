#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
python3 "$SCRIPT_DIR/configure-release.py"
: "${LOSSLESS_RECORDER_NOTARY_PROFILE:?必须设置公证钥匙串配置名}"
: "${LOSSLESS_RECORDER_OUTPUT_DIR:?必须设置新的独立发布输出目录}"
if [[ -e "$LOSSLESS_RECORDER_OUTPUT_DIR" ]]; then
  print -u2 '发布输出目录已存在，拒绝覆盖。'; exit 1
fi
IDENTITY="${LOSSLESS_RECORDER_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ { print $2; exit }')"
fi
[[ -n "$IDENTITY" ]] || { print -u2 '正式发布要求 Developer ID 签名，不能降级。'; exit 1; }
export LOSSLESS_RECORDER_SIGNING_IDENTITY="$IDENTITY"
export LOSSLESS_RECORDER_UNIVERSAL=1
"$SCRIPT_DIR/build-app.sh"
APP="$LOSSLESS_RECORDER_OUTPUT_DIR/无损系统录音机.app"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'Authority=Developer ID Application:'
SUBMISSION="$LOSSLESS_RECORDER_OUTPUT_DIR/notary-submission.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$LOSSLESS_RECORDER_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
python3 "$SCRIPT_DIR/audit-release.py" "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
ARCHIVE="$LOSSLESS_RECORDER_OUTPUT_DIR/LosslessSystemAudioRecorder-$VERSION-$BUILD-universal.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
rm "$SUBMISSION"
print "已准备签名公证包：$ARCHIVE。尚未上传或发布；下一步生成签名 appcast 并完成线上验收。"
