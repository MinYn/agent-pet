---
name: pet-character
description: AgentPet 데스크톱 펫의 오리지널 픽셀 아트 캐릭터를 만들거나 고친다 (프레임 6장 idle·walk1·walk2·sleep·happy·special). "펫 캐릭터 만들어줘", "펫을 ○○ 모양으로", "펫 캐릭터 고쳐줘", "AgentPet 캐릭터" 같은 요청에 쓴다.
---

# AgentPet 캐릭터 만들기

AgentPet(`~/Applications/AgentPet.app`, 저장소 https://github.com/MinYn/agent-pet)의 캐릭터는 `~/.agent-pet/characters/<이름>/` 폴더 하나다.

```
idle.png walk1.png walk2.png sleep.png happy.png special.png   # 프레임 6장 (96×96, 32×32 격자를 3배)
thumb.png                                                      # 메뉴 썸네일
character.json                                                 # {"faces": "left"|"right", "title": "한국어 이름", "persona": {...}}
spec.json                                                      # 그린 설계 — 고쳐서 다시 그릴 때 쓴다
```

생성기: `~/Applications/AgentPet.app/Contents/Resources/sources/make_character.py` (아래 `$MC`)

## 원칙

- **오리지널만 만든다.** 기존 게임·애니·만화·브랜드 캐릭터 이름이 오면 그대로 그리지 않고, 동물 종류·색감·성격 같은 분위기만 살린 새 캐릭터로 만든다. 사용자에게 그 점을 한 줄로 알린다.
- 만든 뒤에는 결과 PNG를 직접 열어 보고(Read) 어색한 프레임이 있으면 고친다.

## 방법 1 — 설명만으로 (빠름, 2~5분)

```bash
MC=~/Applications/AgentPet.app/Contents/Resources/sources/make_character.py
/usr/bin/python3 -I "$MC" --prompt "빨간 목도리를 한 졸린 아기 고양이"
```

- 내부에서 `claude -p` 가 설계(JSON)를 만들고 형식이 틀리면 한 번 다시 요청한다. 진행·완료는 펫 말풍선으로도 뜬다.
- 마지막 줄에 만든 캐릭터 폴더 이름을 출력한다. 실패하면 `~/.agent-pet/make_character.last.txt` 에 마지막 응답 원문이 있다.
- 시간이 오래 걸리면 백그라운드로 실행한다.

## 방법 2 — 대화하며 직접 설계 (세밀하게 고칠 때)

1. 형식 확인: `/usr/bin/python3 -I "$MC" --print-format`
2. 설계 JSON을 직접 쓴다 (스크래치패드에). 핵심:
   - `palette`: 글자 1개 → `#rrggbb` (6~14색, `.` 은 투명)
   - `idle`: 정확히 32줄 × 32글자. 발은 맨 아래 1~2줄, 몸은 가로 18~26 · 세로 20~28칸, 어두운 외곽선 1칸
   - `changes`: 프레임별로 idle 에서 **바뀌는 줄만** `{"줄번호(0~31)": "32글자"}`
     walk1/walk2 다리 · sleep 감은 눈 · happy 웃는 눈과 든 팔 · special 한 손 흔들기
   - walk 변경을 비우면 다리를 번갈아 한 칸 들어 올려 자동으로 만든다
3. 그리기: `/usr/bin/python3 -I "$MC" --spec 설계.json` (같은 이름을 고쳐 그릴 땐 `--replace`)
4. 확인: `~/.agent-pet/characters/<이름>/` 의 PNG 6장을 Read 로 열어 본다.
5. 고치기: 그 폴더의 `spec.json` 은 정규화된 전체 프레임(`frames`)이라 그대로 고쳐 `--spec ... --replace` 로 다시 그릴 수 있다.

## 끝나면

- 펫 우클릭 → 캐릭터 격자에 새 캐릭터가 보인다(메뉴를 열 때마다 다시 읽음). 고르면 바로 바뀐다.
- 얼굴이 가는 방향과 반대로 걸으면 `character.json` 의 `faces` 를 바꾼다.
- 앱 안에서도 우클릭 → 캐릭터 → 「AI로 캐릭터 만들기…」로 같은 방법 1을 쓸 수 있다고 안내한다.

## 말투·행동 (persona)

`character.json` 의 `persona` 는 펫이 혼자 말할 문장과 행동 성향이다. 「AI로 캐릭터 만들기」는 그림과 함께 만들고,
이미 있는 캐릭터는 `$MC --persona-only <폴더 이름>` (앱: 우클릭 → 캐릭터 → 「이 캐릭터의 말투·행동 만들기」)으로 만든다.

- `personality`: 성격 한 줄
- `talk`: 상황별 문장 목록 — general · morning · lunch · snack · evening · night · sleep · perched · dock · wake,
  그리고 `alerts`·`done` 은 `{n}` 이 든 한 문장. 캐릭터 말투(울음·말버릇·어미) 그대로, 한 문장 25자 이내.
- `behavior`: 행동 가중치 walk · stand · look · jump · wave · doze · climb · hopdown (0~60), `speed`(0.5~2.0 걸음 빠르기),
  `sleep_after_min`(1~30분 뒤 잠듦). 성격에 맞게 — 게으르면 doze·stand↑ speed↓, 활발하면 jump·walk↑ speed↑.
- 손으로 고쳐도 된다. 앱은 우클릭 → 캐릭터 → 「다시 읽기」로 반영한다.

