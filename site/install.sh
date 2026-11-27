#!/bin/bash
# LidAwake 한 줄 설치: 최신 버전을 받아 응용 프로그램 폴더에 넣고 실행해요.
# 사용법: curl -fsSL https://getlidawake.vercel.app/install.sh | bash
set -euo pipefail
URL="https://github.com/jinnyjiinlee/lid-awake/releases/latest/download/LidAwake.zip"
DEST="/Applications/LidAwake.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "LidAwake 받는 중..."
curl -fsSL "$URL" -o "$TMP/LidAwake.zip"
/usr/bin/ditto -x -k "$TMP/LidAwake.zip" "$TMP"

pkill -x LidAwake 2>/dev/null || true
if [ -w /Applications ]; then
  rm -rf "$DEST" && mv "$TMP/LidAwake.app" "$DEST"
else
  echo "응용 프로그램 폴더에 넣으려면 맥 비밀번호가 필요해요."
  sudo rm -rf "$DEST" && sudo mv "$TMP/LidAwake.app" "$DEST"
fi
/usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
open "$DEST"
echo ""
echo "설치 끝! 화면 맨 위 메뉴바에 해/달 아이콘이 생겼어요."
