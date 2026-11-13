#!/bin/bash
# AgentPet 제거 — 앱과 연동 설정을 뺀다. 데이터(~/.agent-pet: 설정·캐릭터)는 --purge 를 줄 때만 지운다.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x AgentPet || true
/usr/bin/python3 -I scripts/setup_integrations.py uninstall
rm -rf "$HOME/Applications/AgentPet.app"
echo "  앱 제거: ~/Applications/AgentPet.app"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/.agent-pet"
  echo "  데이터 제거: ~/.agent-pet"
fi
echo "✅ 제거 완료"
