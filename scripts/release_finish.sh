#!/bin/bash
# 릴리스 마무리 — 태그 push 뒤에 실행한다: Actions 빌드를 기다리고, 첨부 파일을 확인하고, 제목·노트를 쓴다.
#
#   scripts/release_finish.sh <태그> <노트 파일.md> [제목]
#   예) scripts/release_finish.sh v0.0.9 /tmp/notes.md "AgentPet 0.0.9 — 알림함"
#
# gh 활성 계정(gh auth switch)은 바꾸지 않는다. 명령마다 릴리스 계정의 토큰을 GH_TOKEN 으로 넘긴다.
#  - 활성 계정은 컴퓨터 전체에 하나라, 같은 컴퓨터의 다른 자동화(에이전트 등)가 중간에 다른 계정으로
#    바꿔 버릴 수 있다. 그러면 쓰기 권한 없는 계정으로 편집하게 되고, GitHub 는 403 이 아니라 404 를 돌려준다
#    (v0.0.8·v0.0.9 노트 작성이 이 이유로 404 가 났다).
#  - 반대로 우리가 계정을 바꿔 두면 그 사이 다른 자동화가 엉뚱한 계정으로 돈다.
#
# 환경변수: RELEASE_GH_USER (기본 MinYn) · RELEASE_REPO (기본 MinYn/agent-pet)
set -euo pipefail

TAG="${1:?태그를 주세요 (예: v0.0.9)}"
NOTES="${2:?노트 파일을 주세요}"
TITLE="${3:-AgentPet ${TAG#v}}"
GH_USER="${RELEASE_GH_USER:-MinYn}"
REPO="${RELEASE_REPO:-MinYn/agent-pet}"
ASSETS=(AgentPet.dmg AgentPet.zip)

[ -f "$NOTES" ] || { echo "노트 파일이 없어요: $NOTES" >&2; exit 2; }

# 1. 릴리스 계정 토큰 — 활성 계정은 그대로 둔다
GH_TOKEN="$(gh auth token --user "$GH_USER" 2>/dev/null)" || {
  echo "gh 에 $GH_USER 계정 로그인이 없어요: gh auth login 으로 추가해 주세요 (활성 계정은 바꾸지 않아도 됩니다)" >&2; exit 2; }
export GH_TOKEN
[ "$(gh api "repos/$REPO" --jq '.permissions.push')" = "true" ] || {
  echo "$GH_USER 계정에 $REPO 쓰기 권한이 없어요" >&2; exit 2; }
echo "· 계정 $GH_USER 토큰으로 진행 (활성 계정은 바꾸지 않음)"

# 2. 이 태그의 release 워크플로 실행을 찾아 끝날 때까지 기다린다 (태그 push 직후엔 아직 안 생겼을 수 있다)
RUN=""
for _ in $(seq 1 60); do
  RUN="$(gh run list -R "$REPO" --workflow release.yml --limit 10 --json databaseId,headBranch \
         --jq "map(select(.headBranch == \"$TAG\")) | .[0].databaseId // empty")"
  [ -n "$RUN" ] && break
  sleep 5
done
[ -n "$RUN" ] || { echo "5분 안에 $TAG 의 release 실행이 안 생겼어요 — Actions 탭에서 수동 실행(workflow_dispatch, tag=$TAG)" >&2; exit 1; }
echo "· 빌드 실행 $RUN 기다리는 중…"
gh run watch "$RUN" -R "$REPO" --exit-status >/dev/null || { echo "빌드가 실패했어요: gh run view $RUN -R $REPO --log-failed" >&2; exit 1; }
echo "· 빌드 성공"

# 3. 첨부 파일이 모두 올라올 때까지 (최대 2분)
for _ in $(seq 1 24); do
  have="$(gh release view "$TAG" -R "$REPO" --json assets --jq '[.assets[].name] | join(" ")' 2>/dev/null || true)"
  missing=0
  for a in "${ASSETS[@]}"; do [[ " $have " == *" $a "* ]] || missing=1; done
  [ "$missing" = 0 ] && break
  sleep 5
done
[ "$missing" = 0 ] || { echo "첨부 파일이 다 안 올라왔어요: [$have]" >&2; exit 1; }
echo "· 첨부 확인: $have"

# 4. 워크플로가 릴리스를 마무리할 틈을 두고 제목·노트를 쓴다 — 실패하면 조금씩 더 기다렸다가 다시
sleep 5
ok=0
for i in 1 2 3; do
  if gh release edit "$TAG" -R "$REPO" --title "$TITLE" --notes-file "$NOTES" >/dev/null; then ok=1; break; fi
  echo "· 노트 쓰기 실패 ($i/3) — $((i * 10))초 뒤 다시" >&2
  sleep $((i * 10))
done
[ "$ok" = 1 ] || { echo "노트를 쓰지 못했어요. 404 면 토큰 계정의 쓰기 권한을 확인하세요" >&2; exit 1; }

# 5. 실제로 반영됐는지 확인
got_title="$(gh release view "$TAG" -R "$REPO" --json name --jq .name)"
first_line="$(grep -m1 -v '^[[:space:]]*$' "$NOTES")"
got_body="$(gh release view "$TAG" -R "$REPO" --json body --jq .body)"
[ "$got_title" = "$TITLE" ] && [[ "$got_body" == "$first_line"* ]] || {
  echo "반영 확인 실패 — 제목: [$got_title]" >&2; exit 1; }
echo "· 완료: $got_title"
echo "  https://github.com/$REPO/releases/tag/$TAG"
