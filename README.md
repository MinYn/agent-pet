# AgentPet

화면 위를 돌아다니는 데스크톱 펫이 AI 도구들의 알림을 말풍선으로 알려 주는 macOS 앱입니다.

- **Multica** — 내 SDD 리더·스쿼드 이슈 중 사람 차례·결정 대기 등을 알림. 빠른 답장 버튼(Claude 추천 답 포함)으로 바로 댓글을 달 수 있어요.
- **Claude Code** — 작업 완료·입력 대기·승인 대기. 권한 요청을 펫에서 허용/거부(실험).
- **Codex** — 작업 완료.
- **Orca** — Orca에서 실행한 Claude Code·Codex 세션. 알림을 누르면 그 Orca 탭으로 이동.

펫은 창·Dock 위에 올라가 놀고, 졸리면 구석에서 자고, 알림이 오면 보고 있는 모니터로 점프해 와요.

## 설치

필요한 것: macOS 13 이상, Xcode 명령줄 도구(`xcode-select --install`)

```bash
git clone https://github.com/MinYn/agent-pet.git
cd agent-pet
scripts/install.sh
```

`install.sh` 가 하는 일
- 앱을 빌드해 `~/Applications/AgentPet.app` 에 설치하고 실행
- `~/.claude/settings.json` 에 펫 훅 4개 추가 (기존 훅은 그대로)
- `~/.codex/config.toml` 의 `notify` 를 감싸기 (원래 notify 명령도 계속 불림, Codex 를 쓸 때만)
- Claude Code 스킬 `pet-character` 설치 (`~/.claude/skills/`)
- 고치는 설정 파일은 처음 한 번 `*.bak-agentpet` 으로 백업

이미 열려 있던 Claude Code·Codex 세션은 다시 시작해야 알림이 와요.

### 기능별로 필요한 것

| 기능 | 필요 |
|---|---|
| Multica 알림 | `multica` CLI 로그인 |
| Multica 추천 답장 · AI 캐릭터 만들기 | `claude` CLI |
| Orca 탭으로 이동 | Orca 앱 |
| Dock 아이콘 건너뛰기 | 손쉬운 사용 권한 (메뉴에서 「창·Dock 위에 올라가 놀기」를 켤 때 요청) |

없는 도구의 기능만 빠지고 나머지는 동작해요.

## 업데이트 · 제거

```bash
git pull && scripts/install.sh     # 업데이트 (연동 설정은 중복되지 않음)
scripts/uninstall.sh               # 앱과 연동 설정 제거 (설정·캐릭터 데이터는 남김)
scripts/uninstall.sh --purge       # 데이터(~/.agent-pet)까지 제거
```

## 쓰는 법

펫을 **클릭**하면 말풍선을 열고 닫고, **우클릭**하면 메뉴가 열려요.

- **알림 범위** — 앱별 알림 켜기/끄기와 앱별 설정 (Multica 알릴 이슈, Claude 알릴 때, 작업 완료 알림 내리는 시간 등)
- **캐릭터** — 썸네일에서 고르기, 「AI로 캐릭터 만들기…」, 캐릭터 크기
- **창·Dock 위에 올라가 놀기**, **모니터**(마우스 모니터 따라다니기), **말풍선 테마·글꼴**

말풍선의 「자세히 보기」로 전문을 펼쳐요(마크다운 표시).

## 캐릭터

캐릭터는 `~/.agent-pet/characters/<이름>/` 폴더 하나예요.

```
idle.png walk1.png walk2.png sleep.png happy.png special.png   # 프레임 6장
thumb.png                                                      # 메뉴 썸네일 (없으면 idle)
character.json                                                 # {"faces": "left"|"right", "title": "이름"}
```

- 「AI로 캐릭터 만들기…」 또는 Claude Code 에서 "펫 캐릭터 만들어줘"(스킬 `pet-character`)로 오리지널 픽셀 아트 캐릭터를 만들 수 있어요.
- 이 저장소에는 캐릭터 이미지가 들어 있지 않아요. 기존 Multica 펫을 쓰던 분은 메뉴 「기존 Multica 펫에서 캐릭터 가져오기」로 내 맥에 있는 이미지를 가져올 수 있어요.

## 데이터와 외부 전송

- 모든 데이터는 `~/.agent-pet` 에만 저장돼요 (`requests/`·`responses/` 로 소스와 앱이 파일을 주고받음).
- 외부로 나가는 것: Multica 추천 답장과 AI 캐릭터 만들기는 내 `claude` CLI 로 댓글 내용·캐릭터 설명을 Claude 에 보내요. 메뉴에서 끌 수 있어요.

## 구조

```
Sources/AgentPet/   Swift 앱 (AppKit) — 펫·말풍선·메뉴·창 상호작용
hooks/              알림 소스 — multica_watch.py · claude_hook.py · codex_notify.py · make_character.py
skill/              Claude Code 스킬 pet-character
scripts/            build.sh · install.sh · uninstall.sh · setup_integrations.py
```
