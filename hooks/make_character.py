#!/usr/bin/env python3
"""AI 캐릭터 만들기 — 설명 한 줄로 오리지널 픽셀 아트 펫 캐릭터(프레임 6장)를 만든다.

  make_character.py --prompt "모자 쓴 졸린 고양이"      Claude(claude -p)에게 설계를 맡겨 만든다
  make_character.py --spec spec.json                   직접 쓴 설계(JSON)로 그리기만 한다
  make_character.py --print-format                     설계 JSON 형식 안내를 출력한다 (스킬·사람용)

설계 JSON:
  {"name": "sleepy-cat", "title": "졸린 고양이", "faces": "left"|"right",
   "palette": {".": "transparent", "k": "#1d1b22", ...},
   "idle": [32줄 × 32글자], "changes": {"walk1": {"줄번호": "32글자"}, "walk2": ..., "sleep": ..., "happy": ..., "special": ...}}
  (예전 형식 "frames": {"idle": [...], ...} 도 읽는다)

결과: <데이터 폴더>/characters/<name>/{idle,walk1,walk2,sleep,happy,special,thumb}.png + character.json
진행·완료는 펫 말풍선(requests/pet-make-*.json)으로 알린다. 데이터 폴더: AGENT_PET_DIR, 기본 ~/.agent-pet
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import zlib

PET = os.environ.get("AGENT_PET_DIR") or os.path.expanduser("~/.agent-pet")
CHARS = os.path.join(PET, "characters")
REQ = os.path.join(PET, "requests")
FRAMES = ("idle", "walk1", "walk2", "sleep", "happy", "special")
GRID = 32
SCALE = 3   # 32px → 96px (앱이 크기에 맞춰 다시 줄이고 늘린다)
CLAUDE = shutil.which("claude", path=os.pathsep.join([os.environ.get("PATH", ""), os.path.expanduser("~/.local/bin"),
                                                     "/opt/homebrew/bin", "/usr/local/bin"]))
MODEL = os.environ.get("PET_CHARACTER_MODEL", "claude-sonnet-5-5")

FORMAT = f"""너는 데스크톱 펫용 픽셀 아트 캐릭터 디자이너다. 사용자의 설명으로 **오리지널** 캐릭터를 설계한다.

저작권
- 기존 게임·애니·만화·브랜드 캐릭터를 그대로 또는 닮게 그리지 않는다. 그런 이름이 오면 이름은 쓰지 말고,
  설명의 분위기(동물 종류·색감·성격)만 살린 새 캐릭터를 만든다.

출력: JSON 하나만 (설명·코드 블록 없이)
{{"name": "영문 소문자-하이픈 이름", "title": "한국어 이름", "faces": "left" 또는 "right",
  "palette": {{"글자 1개": "#rrggbb", ...}},
  "idle": [{GRID}개 문자열],
  "changes": {{"walk1": {{"줄번호": "{GRID}글자", ...}}, "walk2": {{...}}, "sleep": {{...}}, "happy": {{...}}, "special": {{...}}}}}}

격자 규칙
- idle 은 정확히 {GRID}줄, 줄마다 정확히 {GRID}글자. "." 은 투명. 팔레트 글자만 쓴다 (팔레트 6~14색).
- 캐릭터는 아래쪽에 발을 붙여 서 있고(맨 아래 1~2줄에 발), 몸통은 가로 18~26칸, 세로 20~28칸.
- 외곽선은 어두운 색 1칸. 눈·볼 같은 얼굴 디테일로 귀엽게. faces 는 얼굴이 향한 방향.
- changes 는 idle 에서 **바뀌는 줄만** 적는다. 줄번호는 0부터({GRID - 1}까지), 값은 그 줄 전체({GRID}글자).
  · walk1/walk2: 걸음 두 박자 — 아래쪽 다리 줄을 서로 다르게 (한쪽 발 들기)
  · sleep: 눈을 감은 선(─)으로, 가능하면 몸을 조금 웅크리기
  · happy: 눈을 ^ ^ 웃는 눈으로, 입을 벌리고 팔을 위로
  · special: 한쪽 팔을 들어 손 흔들기
- 모든 프레임에 바뀌는 줄을 꼭 넣는다 (프레임마다 3~12줄).
"""


# =============================================================================
# 말풍선 알림
# =============================================================================

def notify(rid, headline, detail="", options=(), expires=None, line=""):
    os.makedirs(REQ, exist_ok=True)
    body = {"source": "pet", "tag": "AI 캐릭터 만들기", "headline": headline, "line": line, "detail": detail,
            "options": list(options), "ids": [f"reply:{i}" for i in range(len(options))]}
    if expires:
        body["expires_at"] = time.time() + expires
    p = os.path.join(REQ, rid + ".json")
    with open(p + ".tmp", "w", encoding="utf-8") as f:
        json.dump(body, f, ensure_ascii=False)
    os.replace(p + ".tmp", p)


def clear(rid):
    try:
        os.remove(os.path.join(REQ, rid + ".json"))
    except OSError:
        pass


# =============================================================================
# 설계 받기 · 검사 · 그리기
# =============================================================================

def ask_claude(message):
    if not CLAUDE:
        raise RuntimeError("claude CLI 를 찾지 못했어요")
    r = subprocess.run(
        [CLAUDE, "-p", "--model", MODEL, "--tools", "", "--strict-mcp-config", "--setting-sources", "",
         "--no-session-persistence", "--system-prompt", FORMAT],
        input=message, capture_output=True, text=True, timeout=600, cwd=PET)
    with open(os.path.join(PET, "make_character.last.txt"), "w", encoding="utf-8") as f:   # 마지막 응답 원문 (문제 추적용)
        f.write(r.stdout)
    m = re.search(r"\{.*\}", r.stdout, re.S)
    if not m:
        raise RuntimeError(f"설계를 받지 못했어요: {(r.stderr or r.stdout).strip()[:200]}")
    text = m.group(0)
    try:
        return json.loads(text), text
    except ValueError as e:   # JSON 이 깨졌으면 그 오류를 문제로 돌려 다시 요청하게 한다
        return {"_json_error": str(e)}, text


def problems(raw):
    """설계의 형식 문제 — 다시 요청할 때 그대로 알려 준다. 문제가 없으면 빈 목록"""
    if raw.get("_json_error"):
        return [f"JSON 문법 오류: {raw['_json_error']} — 올바른 JSON 하나만 출력할 것 (주석·끝 쉼표 금지, 키는 큰따옴표)"]
    out = []
    pal = set((raw.get("palette") or {}).keys()) | {"."}
    rows = split_rows(raw.get("idle") or (raw.get("frames") or {}).get("idle"))
    if len(rows) != GRID:
        out.append(f"idle: {len(rows)}줄 (정확히 {GRID}줄이어야 함)")
    bad = [i for i, r in enumerate(rows) if len(r) != GRID]
    if bad:
        out.append(f"idle: {len(bad)}개 줄의 길이가 {GRID}글자가 아님 (예: {bad[0]}번 줄 {len(rows[bad[0]])}글자)")
    unknown = {c for r in rows for c in r} - pal
    if unknown:
        out.append(f"idle: 팔레트에 없는 글자 {''.join(sorted(unknown))}")
    filled = sum(1 for r in rows if r.strip("."))
    if filled < 16:
        out.append(f"idle: 그림이 {filled}줄뿐 — 몸 전체를 20~28줄 높이로 그려야 함")
    changes = raw.get("changes") or {}
    missing = [f for f in FRAMES[1:] if not changes.get(f)]
    if missing:
        out.append(f"changes 에 빠진 프레임: {', '.join(missing)} (프레임마다 바뀌는 줄 3~12개)")
    return out


def split_rows(value):
    """한 프레임을 줄 목록으로 — 한 문자열로 오면 줄바꿈으로, 32글자보다 길게 붙어 오면 32글자씩 나눈다"""
    if value is None:
        return []
    if isinstance(value, str):
        value = value.split("\n")
    rows = []
    for r in (str(x).strip() for x in value):
        if len(r) > GRID and len(r) % GRID == 0:
            rows += [r[i:i + GRID] for i in range(0, len(r), GRID)]
        elif r:
            rows.append(r)
    return rows


def fit(row):
    """줄 하나를 정확히 GRID 글자로"""
    return (str(row) + "." * GRID)[:GRID]


def auto_walk(rows, side):
    """걷기 자동 생성 — 아래쪽 다리(맨 아래 4줄)의 한쪽 절반을 한 칸 위로 올린다"""
    out = [list(r) for r in rows]
    filled = [i for i, r in enumerate(rows) if r.strip(".")]
    if not filled:
        return rows
    bottom = filled[-1]
    xs = [x for x in range(GRID) if rows[bottom][x] != "."]
    mid = (min(xs) + max(xs)) // 2 if xs else GRID // 2
    cols = range(0, mid + 1) if side == 0 else range(mid + 1, GRID)
    for y in range(max(bottom - 3, 1), bottom + 1):
        for x in cols:
            out[y - 1][x] = rows[y][x] if rows[y][x] != "." else out[y - 1][x]
            if y == bottom:
                out[y][x] = "."
    return ["".join(r) for r in out]


def normalize(spec):
    """격자 크기·팔레트를 맞추고 idle + changes 로 6프레임을 만든다"""
    palette = {k[:1]: v for k, v in (spec.get("palette") or {}).items()}
    palette["."] = "transparent"
    idle = split_rows(spec.get("idle") or (spec.get("frames") or {}).get("idle"))
    if not idle:
        raise ValueError("idle 그림이 없어요")
    idle = [fit(r) for r in idle][-GRID:]
    idle = ["." * GRID] * (GRID - len(idle)) + idle   # 모자란 줄은 위쪽에 채워 발이 바닥에 붙게
    idle = ["".join(c if c in palette else "." for c in r) for r in idle]
    changes = spec.get("changes") or {}
    full = spec.get("frames") or {}   # 전체 프레임 형식(저장된 spec.json)이면 그대로 쓴다
    frames = {"idle": idle}
    for name in FRAMES[1:]:
        given = split_rows(full.get(name))
        if given and not changes.get(name):
            rows = [fit(r) for r in given][-GRID:]
            rows = ["." * GRID] * (GRID - len(rows)) + rows
            frames[name] = ["".join(c if c in palette else "." for c in r) for r in rows]
            continue
        rows = list(idle)
        for k, v in (changes.get(name) or {}).items():
            try:
                y = int(k)
            except ValueError:
                continue
            if 0 <= y < GRID:
                rows[y] = "".join(c if c in palette else "." for c in fit(v))
        if name.startswith("walk") and not changes.get(name):
            rows = auto_walk(idle, 0 if name == "walk1" else 1)
        frames[name] = rows
    name = re.sub(r"[^a-z0-9-]", "", (spec.get("name") or "pet").lower().replace(" ", "-"))[:32] or "pet"
    return {"name": name, "title": spec.get("title") or name, "faces": "right" if spec.get("faces") == "right" else "left",
            "palette": palette, "frames": frames}


def write_png(path, pixels, scale=1):
    """RGBA 픽셀 격자(행 목록)를 PNG 로 — 표준 라이브러리만 써서 시스템 파이썬에서도 돈다. scale 배로 픽셀을 반복해 키운다"""
    def chunk(kind, data):
        c = kind + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    h, w = len(pixels) * scale, len(pixels[0]) * scale
    raw = bytearray()
    for row in pixels:
        line = b"".join(bytes(px) * scale for px in row)
        for _ in range(scale):
            raw += b"\x00" + line
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def render(spec, replace=False):
    def rgba(v):
        if v == "transparent":
            return (0, 0, 0, 0)
        v = v.lstrip("#")
        return (int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16), 255)

    colors = {k: rgba(v) for k, v in spec["palette"].items()}
    name, n = spec["name"], 2
    if replace:   # 같은 이름을 덮어쓴다 (스킬에서 고쳐 그릴 때)
        shutil.rmtree(os.path.join(CHARS, name), ignore_errors=True)
    while os.path.exists(os.path.join(CHARS, name)):   # 같은 이름이 있으면 번호를 붙인다
        name = f"{spec['name']}-{n}"
        n += 1
    out = os.path.join(CHARS, name)
    os.makedirs(out)
    for frame, rows in spec["frames"].items():
        pixels = [[colors[c] for c in row] for row in rows]
        write_png(os.path.join(out, f"{frame}.png"), pixels, SCALE)
        if frame == "idle":   # 썸네일: 빈 테두리를 잘라 낸 idle
            ys = [y for y, r in enumerate(rows) if r.strip(".")]
            xs = [x for r in rows for x, c in enumerate(r) if c != "."]
            if ys and xs:
                crop = [row[min(xs):max(xs) + 1] for row in pixels[min(ys):max(ys) + 1]]
                write_png(os.path.join(out, "thumb.png"), crop, SCALE)
    with open(os.path.join(out, "character.json"), "w", encoding="utf-8") as f:
        json.dump({"faces": spec["faces"], "title": spec["title"], "generated": True}, f, ensure_ascii=False, indent=2)
    with open(os.path.join(out, "spec.json"), "w", encoding="utf-8") as f:   # 나중에 고쳐 다시 그릴 수 있게
        json.dump(spec, f, ensure_ascii=False)
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt")
    ap.add_argument("--spec")
    ap.add_argument("--print-format", action="store_true")
    ap.add_argument("--replace", action="store_true", help="같은 이름의 캐릭터를 덮어쓴다")
    a = ap.parse_args()
    if a.print_format:
        print(FORMAT)
        return 0
    rid = f"pet-make-{int(time.time())}"
    try:
        if a.spec:
            with open(a.spec, encoding="utf-8") as f:
                raw = json.load(f)
        elif a.prompt:
            notify(rid, "캐릭터를 그리는 중이에요… (2~4분)", a.prompt)
            raw, text = ask_claude(f"캐릭터 설명: {a.prompt}")
            issues = problems(raw)
            if issues:   # 형식이 틀리면 무엇이 틀렸는지 알려 주고 한 번 더
                notify(rid, "캐릭터를 다듬는 중이에요… (조금만 더)", a.prompt)
                raw, text = ask_claude(f"캐릭터 설명: {a.prompt}\n\n이전 설계에 형식 문제가 있었다. 고쳐서 JSON 전체를 다시 출력하라.\n"
                                       + "\n".join(f"- {x}" for x in issues) + f"\n\n이전 설계:\n{text}")
        else:
            ap.error("--prompt 나 --spec 이 필요해요")
        if raw.get("_json_error"):
            raise RuntimeError(f"설계 JSON 이 깨졌어요: {raw['_json_error']}")
        spec = normalize(raw)
        name = render(spec, replace=a.replace)
        with open(os.path.join(CHARS, name, "raw.json"), "w", encoding="utf-8") as f:   # 원본 응답 (문제 추적용)
            json.dump(raw, f, ensure_ascii=False)
        clear(rid)
        notify(rid + "-done", f"새 캐릭터 「{spec['title']}」 완성!", "펫 우클릭 → 캐릭터에서 고를 수 있어요.",
               expires=600, line=str(name))
        print(name)
        return 0
    except Exception as e:
        clear(rid)
        notify(rid + "-fail", "캐릭터를 만들지 못했어요", str(e)[:300], expires=600)
        print(f"실패: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
