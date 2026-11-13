#!/bin/bash
# AgentPet 빌드·설치 — Xcode 프로젝트 없이 swiftc 로 앱 번들을 만든다
#   scripts/build.sh            # build/AgentPet.app 만들기
#   scripts/build.sh --install  # ~/Applications 에 설치하고 다시 실행
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/AgentPet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/sources"
swiftc -O -swift-version 5 -enable-bare-slash-regex -target arm64-apple-macos13 -o build/AgentPet-arm64 Sources/AgentPet/*.swift
swiftc -O -swift-version 5 -enable-bare-slash-regex -target x86_64-apple-macos13 -o build/AgentPet-x86_64 Sources/AgentPet/*.swift
lipo -create build/AgentPet-arm64 build/AgentPet-x86_64 -output "$APP/Contents/MacOS/AgentPet"
rm -f build/AgentPet-arm64 build/AgentPet-x86_64
cp hooks/*.py "$APP/Contents/Resources/sources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.minyn.agentpet</string>
  <key>CFBundleName</key><string>AgentPet</string>
  <key>CFBundleDisplayName</key><string>에이전트 펫</string>
  <key>CFBundleExecutable</key><string>AgentPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "built: $APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x AgentPet || true
  rm -rf "$HOME/Applications/AgentPet.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/AgentPet.app"
  echo "installed: $HOME/Applications/AgentPet.app"
fi
