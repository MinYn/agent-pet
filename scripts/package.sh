#!/bin/bash
# 배포 파일 만들기 — build/AgentPet.app 을 dmg(끌어다 설치) 와 zip(앱 안 업데이트용) 으로
#   scripts/package.sh   →  dist/AgentPet.dmg, dist/AgentPet.zip
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/AgentPet.app ]] || scripts/build.sh
rm -rf dist && mkdir -p dist/dmg
ditto -c -k --keepParent build/AgentPet.app dist/AgentPet.zip
cp -R build/AgentPet.app dist/dmg/
ln -s /Applications dist/dmg/Applications   # 창에서 응용 프로그램 폴더로 끌어다 놓게
hdiutil create -volname "AgentPet" -srcfolder dist/dmg -ov -format UDZO dist/AgentPet.dmg >/dev/null
rm -rf dist/dmg
ls -lh dist
