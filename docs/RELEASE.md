# 릴리스 체크리스트

버전은 git 태그에서 읽는다(`scripts/build.sh`). `v*` 태그를 push 하면 Actions(`release.yml`)가 macOS 에서 빌드해
Release 에 `AgentPet.dmg` · `AgentPet.zip` 을 첨부한다.

## 순서

1. **커밋 정리** — 기능별 커밋. 각 커밋 시점이 빌드되는지 확인한다
   (`swiftc -typecheck -swift-version 5 -enable-bare-slash-regex -target arm64-apple-macos13 Sources/AgentPet/*.swift`).
2. **로컬 설치로 확인** — `scripts/build.sh --install`.
3. **태그와 push** — push 대상(브랜치·커밋 범위·태그)을 먼저 보여 주고 승인받은 뒤 실행한다.
   ```
   git tag vX.Y.Z <커밋>
   git push origin master
   git push origin vX.Y.Z
   ```
4. **노트 파일 작성** — 새 기능 · 개선 · 버그 수정 · 업데이트 방법. 공개 저장소이므로 사내 정보는 넣지 않는다.
5. **마무리 스크립트** — 빌드 대기 → 첨부 확인 → 제목·노트 작성 → 반영 확인까지 한 번에 한다.
   ```
   scripts/release_finish.sh vX.Y.Z /path/to/notes.md "AgentPet X.Y.Z — 한 줄 요약"
   ```
6. **확인** — 릴리스 페이지의 제목·노트·첨부 2개, 펫 메뉴 「업데이트 확인…」.

## gh 계정은 바꾸지 않는다

릴리스 편집은 쓰기 권한이 있는 계정(기본 `MinYn`)으로 해야 한다. 이때 `gh auth switch` 로 활성 계정을 바꾸지 않는다.
스크립트는 `gh auth token --user <계정>` 으로 받은 토큰을 그 명령에만 `GH_TOKEN` 으로 넘긴다.

- **v0.0.8 · v0.0.9 에서 노트 작성이 404 로 실패한 원인**: gh 활성 계정은 컴퓨터 전체에 하나뿐이다.
  `gh auth switch` 로 바꿔 둔 사이에 같은 컴퓨터의 다른 자동화(에이전트 세션)가 다른 계정으로 되돌렸다.
  그 계정은 이 저장소에 쓰기 권한이 없는데, GitHub 는 권한 없는 쓰기 요청에 403 이 아니라 **404** 를 돌려준다.
  다시 바꾼 뒤 재시도하면 성공해서, 타이밍 문제처럼 보였다.
- 반대로 우리가 계정을 바꿔 두면, 그동안 다른 자동화가 엉뚱한 계정으로 동작한다.
- 404 가 나면 먼저 권한부터 본다: `GH_TOKEN=$(gh auth token --user MinYn) gh api repos/MinYn/agent-pet --jq .permissions.push`

## 문제가 생기면

- 태그를 push 했는데 Actions 실행이 안 생김 → Actions 탭에서 `release` 를 수동 실행하고 tag 를 넣는다
  (`GH_TOKEN=$(gh auth token --user MinYn) gh workflow run release -R MinYn/agent-pet --ref master -f tag=vX.Y.Z`).
- 빌드 실패 → `gh run view <id> -R MinYn/agent-pet --log-failed`.
