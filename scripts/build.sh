#!/bin/bash
# AgentPet 빌드 — Xcode 프로젝트 없이 swiftc 로 앱 번들을 만든다
#   scripts/build.sh            # build/AgentPet.app 만들기
#   scripts/build.sh --install  # ~/Applications 에 설치하고 다시 실행 (개발용)
# 버전: VERSION 환경변수 → 가장 가까운 git 태그(v 제외) → 0.0.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NO="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP=build/AgentPet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/sources" "$APP/Contents/Resources/setup" "$APP/Contents/Resources/skill"
FLAGS=(-O -swift-version 5 -enable-bare-slash-regex)
swiftc "${FLAGS[@]}" -target arm64-apple-macos13 -o build/AgentPet-arm64 Sources/AgentPet/*.swift
swiftc "${FLAGS[@]}" -target x86_64-apple-macos13 -o build/AgentPet-x86_64 Sources/AgentPet/*.swift
lipo -create build/AgentPet-arm64 build/AgentPet-x86_64 -output "$APP/Contents/MacOS/AgentPet"
rm -f build/AgentPet-arm64 build/AgentPet-x86_64
cp hooks/*.py "$APP/Contents/Resources/sources/"
cp scripts/setup_integrations.py "$APP/Contents/Resources/setup/"   # 앱 안 「연동 설정」이 쓴다
cp -R skill/pet-character "$APP/Contents/Resources/skill/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.minyn.agentpet</string>
  <key>CFBundleName</key><string>AgentPet</string>
  <key>CFBundleDisplayName</key><string>에이전트 펫</string>
  <key>CFBundleExecutable</key><string>AgentPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NO}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>AgentPetRepository</key><string>MinYn/agent-pet</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "built: $APP ($VERSION, build $BUILD_NO)"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x AgentPet || true
  rm -rf "$HOME/Applications/AgentPet.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/AgentPet.app"
  echo "installed: $HOME/Applications/AgentPet.app"
fi
