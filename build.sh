#!/bin/zsh
# TCC は素の CLI バイナリにアラートを表示できないので .app バンドルに包む。
# バンドルにすると TCC 識別子が CFBundleIdentifier になり、再ビルドしても許可が維持される。
set -e
cd "$(dirname "$0")"

# SwiftPM は -sectcreate に渡した Info.plist をビルド依存として追跡しないので、
# Info.plist だけ変えても再リンクされない。毎回バイナリを消して確実に埋め込み直す。
rm -f swift/.build/release/eventkit-cli
# swiftly などで入れた swift は Xcode の SDK と版がずれてビルドできないことがあるので、
# xcode-select で選ばれたツールチェーンを使う。
xcrun swift build --package-path swift -c release

APP="bin/EventKitCLI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp -f swift/.build/release/eventkit-cli "$APP/Contents/MacOS/eventkit-cli"
cp -f swift/Sources/eventkit-cli/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true

codesign -f -s - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "installed: $(pwd)/$APP/Contents/MacOS/eventkit-cli"
