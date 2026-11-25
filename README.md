# AgentPet

화면 위를 돌아다니는 데스크톱 펫이 AI 도구들의 알림을 말풍선으로 알려 주는 macOS 앱입니다.

- **Multica** — 내 SDD 리더·스쿼드 이슈, 내 에이전트에 직접 맡겨진 이슈 중 사람 차례·결정 대기 등을 알림. 빠른 답장 버튼(Claude 추천 답 포함)이나 질문별 선택으로 바로 댓글을 달 수 있어요. 같은 질문에 같은 답은 두 번 보내지 않아요.
- **Claude Code** — 작업 완료·승인 대기. 선택형 질문(AskUserQuestion)은 말풍선에서 바로 답해요. 권한 요청을 펫에서 허용/거부(실험).
- **Codex** — 작업 완료.
- **Orca** — Orca에서 실행한 Claude Code·Codex 세션. 알림을 누르면 그 Orca 탭으로 이동.
- **사용량 한도 재알림** — Claude Code·Codex 세션이 사용량 한도에 걸려 멈추면, 한도가 풀리는 시각에 세션마다 「사용량이 다시 채워졌어요 · 멈춘 작업: …」으로 다시 알려 줘요. 앱별 알림을 꺼 둬도 와요.
- **알림함** — 닫거나 답한 지난 알림을 메일함처럼 모아 보고, 다시 띄울 수 있어요.

펫은 창·Dock 위에 올라가 놀고, 졸리면 구석에서 자고, 알림이 오면 보고 있는 모니터로 점프해 와요. 앉은 창의 크기를 바꾸면 따라가고, 창을 옮기면 떨어져요.

## 설치

1. [Releases](https://github.com/MinYn/agent-pet/releases/latest) 에서 **AgentPet.dmg** 를 내려받아 열고, `AgentPet` 을 `Applications` 폴더로 끌어다 놓아요.
2. 응용 프로그램에서 AgentPet 을 열어요. 처음 한 번은 macOS 가 막아요 → 아래 「처음 열 때 (그래도 열기)」
3. 처음 실행하면 「Claude Code·Codex 알림을 연결할까요?」를 물어요. **연결하기**를 누르면 끝이에요.

### 처음 열 때 (그래도 열기)

AgentPet 은 아직 Apple 개발자 서명·공증이 없어서, 처음 열면 「Apple 은 'AgentPet' 에 악성 코드가 없음을 확인할 수 없습니다」 같은 창이 떠요. 한 번만 허용하면 그다음부터는 그냥 열려요.

1. 경고 창에서 **완료**(또는 취소)를 눌러 닫아요.
2. **시스템 설정 › 개인정보 보호 및 보안** 을 열고 아래로 내려 「보안」 항목을 봐요.
3. 「'AgentPet' 이(가) 차단되었습니다」 옆의 **그래도 열기** 를 눌러요.
4. Mac 암호(또는 Touch ID)를 넣고, 다시 뜨는 창에서 **열기** 를 눌러요.

> 최신 macOS 에서는 예전처럼 Finder 에서 우클릭 → 열기로는 넘어가지지 않아요. 위 순서대로 해 주세요.
>
> 터미널이 편하면 이 한 줄로도 돼요: `xattr -dr com.apple.quarantine /Applications/AgentPet.app`

### 필요한 것

- macOS 13 이상
- **Xcode 명령줄 도구** — 알림 연동 스크립트가 macOS 기본 `python3` 로 돌아가요. 없으면 연결할 때 설치를 안내해요 (`xcode-select --install`). Xcode 전체는 필요 없어요.

| 기능 | 필요 |
|---|---|
| Multica 알림 | `multica` CLI 로그인 |
| Multica · Orca 추천 답장, AI 캐릭터 만들기 | `claude` CLI |
| Orca 탭으로 이동 · 답장 입력 | Orca 앱 |
| Dock 아이콘 건너뛰기 | 손쉬운 사용 권한 (메뉴에서 「창·Dock 위에 올라가 놀기」를 켤 때 요청) |

없는 도구의 기능만 빠지고 나머지는 동작해요.

### 연동 설정이 하는 일

처음 실행할 때나 펫 메뉴 **연동 설정…** 에서 연결하면:

- `~/.claude/settings.json` 에 펫 훅 5개 추가 (기존 훅은 그대로) — 작업 완료(Stop)·알림(Notification)·다시 입력(UserPromptSubmit)·선택형 질문과 권한 요청(PermissionRequest)·사용량 한도(StopFailure)
- `~/.codex/config.toml` 의 `notify` 를 감싸기 (원래 notify 명령도 계속 불림, Codex 를 쓸 때만)
- Claude Code 스킬 `pet-character` 설치 (`~/.claude/skills/`)
- 고치는 설정 파일은 처음 한 번 `*.bak-agentpet` 으로 백업

같은 메뉴에서 **연결 해제** 하면 원래대로 돌아가요. 앱을 다른 폴더로 옮기거나 업데이트해도 경로는 자동으로 다시 맞춰요. 이미 열려 있던 Claude Code·Codex 세션은 다시 시작해야 알림이 와요.

## 업데이트 · 제거

- **업데이트**: 하루 한 번 새 버전을 확인해서 알려 줘요. 펫 메뉴 **업데이트 확인…** 으로 바로 확인할 수도 있어요. 「업데이트」를 누르면 받아서 바꿔 끼우고 다시 열려요.
  - 서명이 없는 앱이라, 업데이트 뒤에 손쉬운 사용 권한을 다시 물을 수 있어요.
- **제거**: 펫 메뉴 **연동 설정… › 연결 해제** → 펫 종료 → `Applications` 에서 AgentPet 을 휴지통으로. 설정·캐릭터 데이터는 `~/.agent-pet` 에 남아요(지워도 돼요).

## 소스에서 빌드 (개발용)

필요: Xcode 명령줄 도구

```bash
git clone https://github.com/MinYn/agent-pet.git
cd agent-pet
scripts/install.sh          # 빌드해서 ~/Applications 에 설치 + 연동 설정
scripts/uninstall.sh        # 앱과 연동 설정 제거 (--purge 면 ~/.agent-pet 까지)
scripts/package.sh          # dist/AgentPet.dmg · AgentPet.zip 만들기
```

`v*` 태그를 올리면 GitHub Actions 가 dmg·zip 을 만들어 Release 에 첨부해요 (`.github/workflows/release.yml`). 릴리스 순서와 노트 작성은 [docs/RELEASE.md](docs/RELEASE.md) (`scripts/release_finish.sh`).

## 쓰는 법

펫을 **클릭**하면 말풍선을 열고 닫고, **우클릭**하면 메뉴가 열려요.

- **알림 범위** — 앱별 알림 켜기/끄기와 앱별 설정 (Multica 알릴 이슈, Claude 알릴 때, 작업 완료 알림 내리는 시간 등). 「닫은 알림 다시 보기 (알림함)…」
- **알림함 — 지난 알림 보기…** — 아래 「알림함」
- **행동** — 걷기·점프·손 흔들기·졸기·잠자러 가기·창 위로 올라가기·뛰어내리기·Dock 아이콘 건너뛰기를 바로 시켜요
- **혼자 말하기** — 가끔(15분쯤)·자주(5분쯤)·말하지 않기, 「지금 한마디」, 「내 문장 고치기…」(`~/.agent-pet/talk.txt`). 시간·상황(아침·점심·퇴근, 창 위, 숨겨 둔 알림, 오늘 끝난 작업)에 맞춰 캐릭터 말투로 말해요
- **캐릭터** — 썸네일에서 고르기, 「AI로 캐릭터 만들기…」, 말투·행동 만들기, 캐릭터 크기
- **창·Dock 위에 올라가 놀기**, **모니터**(마우스 모니터 따라다니기), **말풍선 테마·글꼴**

### 말풍선

- 「자세히 보기」로 전문을 펼쳐요(마크다운 표시).
- 첫 줄(앱·세션 이름)이나 빈 곳을 끌면 펫이 함께 옮겨지고, 하던 점프도 멈춰요. 둘째 줄부터는 끌면 글자가 선택돼요.
- 알림이 여러 개면 아래 ◀ ▶ 로 넘겨요. ✕ 는 그 알림을 닫아요 (알림함에 남아요).

### 선택형 질문

Claude Code 의 선택형 질문(AskUserQuestion)과 Multica 의 여러 질문 결정은 말풍선이 **질문 모드**로 바뀌어요.

- 질문을 하나씩 보여 주고, 고르면 다음 질문으로 넘어가요. ⭐ 는 추천, 「⭐ 추천대로 채우기」로 빈 질문을 한 번에 채워요.
- **여러 개 고르기** — 여러 개를 고를 수 있는 질문은 누를 때마다 넣고 빼요. 다 고른 뒤 「다음 질문」이나 「답 보내기」.
- **직접 입력** — 선택지가 있어도 「직접 입력」 칸에 적어 답할 수 있어요 (터미널의 Other 와 같아요).
- 모든 질문에 답해야 「답 보내기」가 눌려요. Claude Code 에는 고른 선택지 이름(여러 개면 「가, 다」)이 그대로 넘어가요.
- 터미널에서 먼저 답하면 말풍선은 바로 내려가요.

### 사용량 한도 재알림

세션이 사용량 한도에 걸려 멈추면 펫이 초기화 시각을 기억해 두었다가, 그 시각이 되면 세션마다 말풍선을 띄워요. 그 전에는 보이지 않아요.

- **Claude Code** — 한도 메시지의 초기화 시각(예: `resets 3pm`)을 읽어요. 한도가 풀리기 전에 그 세션에 다시 입력하면 예약된 알림은 지워져요.
- **Codex** — 펫이 45초마다 최근 세션 기록(`~/.codex/sessions`)을 읽어 한도로 멈춘 턴과 초기화 시각을 찾아요. 크레딧 소진처럼 초기화 시각이 없으면 바로 알려요.
- 알림 범위에서 Claude·Codex·Orca 알림을 꺼 둬도 한도 재알림은 와요.

### 알림함

말풍선에서 사라진 알림(닫음·답함·열어 봄·만료·다른 곳에서 처리됨)을 모아 메일함처럼 보여 줘요.

- 왼쪽 목록에서 고르면 오른쪽에 전체 내용과 **그때 고른 답**이 나와요.
- **다시 띄우기** — 말풍선에 되살려요. Multica 알림은 그 이슈를 다시 확인해서, 아직 사람 차례면 최신 내용으로 띄워요.
- **원문 열기** · **삭제**. 답을 기다리던 요청(권한·선택형 질문)은 이미 끝나 다시 띄울 수 없어요.
- 최근 300개까지 남아요.

## 캐릭터

캐릭터는 `~/.agent-pet/characters/<이름>/` 폴더 하나예요.

```
idle.png walk1.png walk2.png sleep.png happy.png special.png   # 프레임 6장
thumb.png                                                      # 메뉴 썸네일 (없으면 idle)
character.json                                                 # {"faces": "left"|"right", "title": "이름", "persona": {...}}
```

- 「AI로 캐릭터 만들기…」 또는 Claude Code 에서 "펫 캐릭터 만들어줘"(스킬 `pet-character`)로 오리지널 픽셀 아트 캐릭터를 만들 수 있어요.
- **말투·행동(persona)** — AI로 만들 때 그 캐릭터에 맞는 혼잣말 말투(상황별 문장)와 행동 성향(자주 하는 행동·걸음 빠르기·잠드는 시간)도 함께 만들어요. 이미 있는 캐릭터는 메뉴 「캐릭터 › 이 캐릭터의 말투·행동 만들기」로 만들 수 있어요.
- 이 저장소에는 캐릭터 이미지가 들어 있지 않아요. 기존 Multica 펫을 쓰던 분은 메뉴 「기존 Multica 펫에서 캐릭터 가져오기」로 내 맥에 있는 이미지를 가져올 수 있어요.

## 데이터와 외부 전송

- 모든 데이터는 `~/.agent-pet` 에만 저장돼요 (`requests/`·`responses/` 로 소스와 앱이 파일을 주고받음).
  - `history/` 알림함(지난 알림, 최근 300개) · `notice.log` 알림이 언제 뜨고 왜 사라졌는지 기록 · `hook.log`·`motion.log` 문제 추적용 기록
- 외부로 나가는 것: Multica 추천 답장과 AI 캐릭터 만들기는 내 `claude` CLI 로 댓글 내용·캐릭터 설명을 Claude 에 보내요. 메뉴에서 끌 수 있어요.

## 구조

```
Sources/AgentPet/   Swift 앱 (AppKit) — 펫·말풍선·메뉴·창 상호작용·연동 설정·업데이트
hooks/              알림 소스 — multica_watch.py · claude_hook.py · codex_notify.py · codex_limit.py · orca_suggest.py · make_character.py
skill/              Claude Code 스킬 pet-character
scripts/            build.sh · package.sh · install.sh · uninstall.sh · setup_integrations.py · release_finish.sh
docs/               RELEASE.md — 릴리스 체크리스트
.github/workflows/  release.yml — 태그를 올리면 dmg·zip 을 Release 에 첨부
```
