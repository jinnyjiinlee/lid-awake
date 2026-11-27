#!/bin/bash
# LidAwake 빌드: 유니버설(Apple 실리콘 + 인텔) .app + 배포용 zip
set -euo pipefail
cd "$(dirname "$0")"
APP=build/LidAwake.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos12" Sources/main.swift -o "build/LidAwake-$arch"
done
lipo -create build/LidAwake-arm64 build/LidAwake-x86_64 -output "$APP/Contents/MacOS/LidAwake"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 아이콘
ICONSET=build/AppIcon.iconset && mkdir -p "$ICONSET"
swift scripts/make_icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$APP"
(cd build && ditto -c -k --keepParent LidAwake.app LidAwake.zip)
echo "완료: build/LidAwake.app , build/LidAwake.zip"
