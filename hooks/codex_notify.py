#!/usr/bin/env python3
"""Codex 소스 — ~/.codex/config.toml 의 notify 로 불린다.

Codex는 턴이 끝날 때 notify 명령 끝에 JSON 하나를 인자로 붙여 부른다.
  {"type": "agent-turn-complete", "thread-id": ..., "cwd": ..., "input-messages": [...], "last-assistant-message": ...}
이것을 펫 말풍선 요청(<데이터 폴더>/requests/codex-<thread>.json)으로 쓰고,
`--` 뒤에 적힌 원래 notify 명령(예: Computer Use 클라이언트)에도 같은 JSON을 그대로 넘긴다.

등록 예:
  notify = ["/usr/bin/python3", "<이 파일>", "--", "<원래 notify 명령>", "<원래 인자>"]
"""
import json
import os
import re
import subprocess
import sys
import time

PET = os.environ.get("AGENT_PET_DIR") or os.path.expanduser("~/.agent-pet")
REQ = os.path.join(PET, "requests")
EXPIRE_SEC = 3600   # 작업 완료 알림은 1시간 뒤 저절로 내림


def settings():
    try:
        with open(os.path.join(PET, "settings.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def expires_at():
    """작업 완료 알림을 내릴 시각 — 메뉴 「알림 범위 › Codex」 값, 0 이면 직접 닫을 때까지(None)"""
    sec = (settings().get("apps", {}).get("codex") or {}).get("expire", EXPIRE_SEC)
    return time.time() + sec if sec else None


def source_on(orca=None):
    """Orca 에서 실행한 세션은 orca 설정만, 그 밖의 세션은 codex 설정을 따른다"""
    try:
        with open(os.path.join(PET, "settings.json"), encoding="utf-8") as f:
            src = json.load(f).get("sources", {})
    except (OSError, ValueError):
        src = {}
    return src.get("orca", True) if orca else src.get("codex", True)


ORCA = "/Applications/Orca.app/Contents/Resources/bin/orca"


def orca_context():
    """Orca 에서 실행한 세션이면 {"handle", "title", "session"} — 아니면 None.
    · 터미널 탭: ORCA_TERMINAL_HANDLE 이 있다 → 그 탭으로 이동·추천 답장 입력 가능
    · 채팅 모드: ORCA_STRUCTURED_SESSION / ORCA_AGENT_SESSION_ID 만 있다 → 작업 폴더로 이동만 (handle 빈 값)"""
    handle = os.environ.get("ORCA_TERMINAL_HANDLE")
    chat = os.environ.get("ORCA_STRUCTURED_SESSION") or os.environ.get("ORCA_AGENT_SESSION_ID")
    if not handle and not chat:
        return None
    title = ""
    if handle:
        try:
            r = subprocess.run([ORCA, "terminal", "show", "--terminal", handle, "--json"],
                               capture_output=True, text=True, timeout=4)
            d = json.loads(r.stdout or "{}")
            t = (d.get("result") or {}).get("terminal") or d.get("result") or {}
            title = t.get("title") or ""
        except Exception:
            pass
    return {"handle": handle or "", "title": title, "session": os.environ.get("ORCA_AGENT_SESSION_ID", "")}


def plain(text, limit):
    t = re.sub(r"```.*?```", " ", text or "", flags=re.S)
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)
    t = re.sub(r"[*`#>|]", "", t)
    t = re.sub(r"[ \t]+", " ", t).strip()
    return t if len(t) <= limit else t[: limit - 1] + "…"


def write_req(rid, req):
    os.makedirs(REQ, exist_ok=True)
    p = os.path.join(REQ, rid + ".json")
    with open(p + ".tmp", "w", encoding="utf-8") as f:
        json.dump(req, f, ensure_ascii=False)
    os.replace(p + ".tmp", p)


def main(argv):
    # `--` 앞: 이 스크립트 인자(없음), 뒤: 원래 notify 명령. 마지막 인자가 Codex가 붙인 JSON
    payload_raw = argv[-1] if len(argv) > 1 else "{}"
    forward = argv[argv.index("--") + 1:-1] if "--" in argv else []
    if forward:   # 원래 notify 는 기다리지 않고 그대로 넘긴다
        subprocess.Popen(forward + [payload_raw], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    try:
        payload = json.loads(payload_raw)
    except ValueError:
        return
    if payload.get("type") != "agent-turn-complete" or os.environ.get("AGENT_PET_INTERNAL"):
        return
    orca = orca_context()
    if not source_on(orca):
        return
    thread = str(payload.get("thread-id") or payload.get("turn-id") or int(time.time()))
    cwd = payload.get("cwd") or ""
    asked = (payload.get("input-messages") or [""])[-1]
    answer = payload.get("last-assistant-message") or ""
    rid = f"codex-{re.sub(r'[^0-9A-Za-z_-]', '', thread)[:24]}"
    write_req(rid, {
        **({"orca_handle": orca["handle"], "agent_name": "Codex", "stamp": f"{time.time():.6f}",
            "pending": bool(orca["handle"]) and bool((settings().get("apps", {}).get("orca") or {}).get("suggest", True))}
           if orca else {}),
        "source": "orca" if orca else "codex",
        "agent": "codex",
        "tag": f"Orca · Codex · {orca['title'] or os.path.basename(cwd) or '작업'}" if orca
               else f"Codex · {os.path.basename(cwd) or '작업'}",
        "headline": "작업 완료!",
        "line": plain(asked, 120),
        "detail": plain(answer, 200),
        "full": plain(answer, 4000),
        "full_md": answer[:6000],
        "options": [], "ids": [],
        "openLabel": "Orca에서 보기" if orca else "폴더 열기",
        "link": (f"orca-terminal:{orca['handle']}" if orca["handle"] else f"orca-worktree:{cwd}") if orca
                else (f"file://{cwd}" if cwd else ""),
        "expires_at": expires_at(),
    })
    if orca and orca["handle"] and (settings().get("apps", {}).get("orca") or {}).get("suggest", True):   # Orca 터미널 세션이면 추천 답장
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "orca_suggest.py")
        subprocess.Popen([sys.executable, "-I", script, os.path.join(REQ, rid + ".json")],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Exception as e:   # Codex 쪽 동작에 영향이 없게 기록만
        os.makedirs(PET, exist_ok=True)
        with open(os.path.join(PET, "watch.err"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%m-%d %H:%M:%S')} codex {e}\n")
