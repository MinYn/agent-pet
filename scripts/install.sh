#!/bin/bash
# AgentPet 설치·업데이트 — 빌드해서 ~/Applications 에 넣고, Claude Code·Codex 연동과 캐릭터 스킬을 설정한다.
#   git pull 뒤 다시 실행하면 업데이트된다 (연동 설정은 중복되지 않는다).
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v swiftc >/dev/null; then
  echo "Xcode 명령줄 도구가 필요해요. 먼저 실행: xcode-select --install"
  exit 1
fi
echo "▶ 앱 빌드·설치"
scripts/build.sh --install
echo "▶ 연동 설정"
/usr/bin/python3 -I scripts/setup_integrations.py install \
  "$HOME/Applications/AgentPet.app/Contents/Resources/sources" "$PWD/skill/pet-character"
echo
echo "✅ 설치 완료 — 화면 오른쪽 아래에 펫이 나타나요. 펫을 우클릭하면 설정 메뉴가 열려요."
command -v multica >/dev/null || echo "  · Multica 알림을 쓰려면 multica CLI 로그인이 필요해요."
command -v claude  >/dev/null || echo "  · 추천 답장·AI 캐릭터 만들기는 claude CLI 가 필요해요."
echo "  · 이미 열려 있는 Claude Code·Codex 세션은 다시 시작해야 알림이 와요."
