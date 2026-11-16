#!/usr/bin/env python3
"""Claude Code 소스 — ~/.claude/settings.json 의 훅으로 불린다. 훅 입력 JSON은 stdin 으로 온다.

  claude_hook.py stop        Stop 훅: 「작업 완료!」 (last_assistant_message)
  claude_hook.py notify      Notification 훅: 입력 대기·승인 대기 알림
  claude_hook.py limit       StopFailure 훅(rate_limit): 사용량 한도로 멈춘 세션을 초기화 시각에 다시 알림
  claude_hook.py clear       UserPromptSubmit 훅: 터미널에서 다시 입력하면 그 세션 알림을 내림
  claude_hook.py permission  PermissionRequest 훅(동기): 펫 버튼으로 허용/거부 — 설정 「claude_permission」이 켜져 있을 때만

말풍선 하나 = 세션 하나(claude-<세션>.json). 같은 세션의 새 알림은 이전 것을 덮어쓴다.
권한 요청은 claude-perm-<세션>-<시각>.json 에 "await": true 로 쓰고 responses/ 의 답을 기다린다.
"""
import json
import os
import re
import subprocess
import sys
import time

PET = os.environ.get("AGENT_PET_DIR") or os.path.expanduser("~/.agent-pet")
REQ, RESP = os.path.join(PET, "requests"), os.path.join(PET, "responses")
DONE_EXPIRE_SEC = 3600       # 작업 완료 알림은 1시간 뒤 저절로 내림
ORCA_CTX = None   # main 에서 채움 — Orca 세션이면 {"handle", "title"}
PERMISSION_WAIT_SEC = 90     # 펫 답을 기다리는 시간 — 넘으면 결정 없이 끝나 터미널에서 묻는다
# 터미널 프로그램(TERM_PROGRAM) → 「열기」로 앞으로 가져올 앱
TERMINAL_APPS = {"vscode": "Visual Studio Code", "iTerm.app": "iTerm", "Apple_Terminal": "Terminal",
                 "WarpTerminal": "Warp", "ghostty": "Ghostty", "WezTerm": "WezTerm"}


def settings():
    try:
        with open(os.path.join(PET, "settings.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def app_setting(app, key, default):
    """펫 메뉴 「알림 범위」의 앱별 설정 apps.<앱>.<키>"""
    return (settings().get("apps", {}).get(app) or {}).get(key, default)


def expires_at(app):
    """작업 완료 알림을 내릴 시각 — 0 이면 직접 닫을 때까지(None)"""
    sec = app_setting(app, "expire", DONE_EXPIRE_SEC)
    return time.time() + sec if sec else None


def source_on(orca=None):
    """Orca 에서 실행한 세션은 orca 설정만, 그 밖의 세션은 claude 설정을 따른다"""
    src = settings().get("sources", {})
    return src.get("orca", True) if orca else src.get("claude", True)


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


def pet_running():
    return subprocess.run(["/usr/bin/pgrep", "-x", "AgentPet"], capture_output=True).returncode == 0


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


def remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def safe(s, n=12):
    return re.sub(r"[^0-9A-Za-z_-]", "", s or "")[:n] or "x"


def base(hook, orca=None):
    """세션 공통 필드 — 칩·열기 링크. Orca 세션이면 그 Orca 터미널 탭으로 이동한다"""
    cwd = hook.get("cwd") or ""
    if orca:
        return {
            "source": "orca", "agent": "claude",
            "orca_handle": orca["handle"], "agent_name": "Claude Code",
            "orca_cwd": cwd,
            "stamp": f"{time.time():.6f}",   # 추천 답장이 늦게 붙을 때 같은 알림인지 확인
            "tag": f"Orca · Claude Code · {orca['title'] or os.path.basename(cwd) or '세션'}",
            "openLabel": "Orca에서 보기",
            # 터미널 탭이면 그 탭으로, 채팅 모드면 그 작업 폴더로
            "link": f"orca-terminal:{orca['handle']}" if orca["handle"] else f"orca-worktree:{cwd}",
        }
    term = os.environ.get("TERM_PROGRAM", "")
    app = TERMINAL_APPS.get(term)
    return {
        "source": "claude",
        "tag": f"Claude Code · {os.path.basename(cwd) or '세션'}",
        "openLabel": f"{app}로 가기" if app else "폴더 열기",
        "link": f"app:{app}" if app else (f"file://{cwd}" if cwd else ""),
    }


def tool_summary(name, tool_input):
    """권한 요청 도구를 한 줄로"""
    ti = tool_input or {}
    if name == "Bash":
        return ti.get("command", "")
    if name in ("Edit", "Write", "Read", "MultiEdit", "NotebookEdit"):
        return ti.get("file_path") or ti.get("notebook_path") or ""
    if name in ("WebFetch",):
        return ti.get("url", "")
    return json.dumps(ti, ensure_ascii=False)[:300]


def suggest_on():
    """이 알림에 Orca 추천 답장을 붙일지"""
    return bool(ORCA_CTX and ORCA_CTX["handle"]) and app_setting("orca", "suggest", True)   # 답을 넣을 터미널이 있을 때만


def orca_followup(rid):
    """Orca 세션이면 추천 답장을 백그라운드로 만든다 (메뉴 「알림 범위 › Orca › 추천 답장 만들기」)"""
    if not suggest_on():
        return
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "orca_suggest.py")
    subprocess.Popen([sys.executable, "-I", script, os.path.join(REQ, rid + ".json")],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def on_stop(hook):
    if hook.get("stop_hook_active") or not app_setting("claude", "stop", True):
        return
    answer = hook.get("last_assistant_message") or ""
    rid = f"claude-{safe(hook.get('session_id'))}"
    write_req(rid, {
        **base(hook, ORCA_CTX),
        "headline": "작업 완료!",
        "line": "",
        "detail": plain(answer, 200),
        "full": plain(answer, 4000),
        "full_md": answer[:6000],
        "pending": suggest_on(),   # 추천 답장이 붙을 때까지 앱이 숨긴다
        "options": [], "ids": [],
        "expires_at": expires_at("claude"),
    })
    orca_followup(rid)


def on_notify(hook):
    kind = hook.get("notification_type") or ""
    if kind == "idle_prompt" and not app_setting("claude", "idle", True):
        return
    if kind == "permission_prompt" and not app_setting("claude", "permission_prompt", True):
        return
    sid = safe(hook.get("session_id"))
    if kind == "permission_prompt" and any(f.startswith(f"claude-perm-{sid}-") for f in os.listdir(REQ) if os.path.isdir(REQ)):
        return   # 펫 권한 요청 말풍선이 이미 떠 있음
    headline = {"permission_prompt": "허용할까요? 터미널에서 확인해 주세요",
                "idle_prompt": "입력을 기다리고 있어요",
                "elicitation_dialog": "선택이 필요해요",
                "agent_needs_input": "입력이 필요해요"}.get(kind, hook.get("title") or "확인이 필요해요")
    write_req(f"claude-{sid}", {
        **base(hook, ORCA_CTX),
        "headline": headline,
        "line": "",
        "detail": plain(hook.get("message", ""), 200),
        "full": plain(hook.get("message", ""), 2000),
        "options": [], "ids": [],
        "pending": suggest_on() and kind in ("idle_prompt", "agent_needs_input", "elicitation_dialog"),
        "expires_at": expires_at("claude"),
    })
    if kind in ("idle_prompt", "agent_needs_input", "elicitation_dialog"):   # 입력을 기다릴 때만 추천 답장
        orca_followup(f"claude-{sid}")


MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
# 한도 메시지의 초기화 시각 — 「… · resets 3pm (Asia/Seoul)」「resets 3:30pm」「resets Nov 20, 3pm」「resets Jan 2, 2027, 9am」
RESET_RE = re.compile(r"resets\s+(?:(?P<mon>[A-Za-z]{3})\s+(?P<day>\d{1,2}),\s+(?:(?P<year>\d{4}),\s+)?)?"
                      r"(?P<h>\d{1,2})(?::(?P<m>\d{2}))?\s*(?P<ap>am|pm)(?:\s*\((?P<tz>[^)]+)\))?", re.I)


def reset_time(text):
    """한도 메시지에서 초기화 시각(epoch 초)을 읽는다 — 못 읽으면 None"""
    from datetime import datetime, timedelta
    m = RESET_RE.search(text or "")
    if not m:
        return None
    tz = None
    if m["tz"]:
        try:
            from zoneinfo import ZoneInfo
            tz = ZoneInfo(m["tz"].strip())
        except Exception:
            tz = None
    now = datetime.now(tz) if tz else datetime.now().astimezone()
    hour = int(m["h"]) % 12 + (12 if m["ap"].lower() == "pm" else 0)
    minute = int(m["m"] or 0)
    try:
        if m["mon"]:
            month = MONTHS.index(m["mon"].lower()) + 1
            year = int(m["year"]) if m["year"] else now.year
            t = now.replace(year=year, month=month, day=int(m["day"]), hour=hour, minute=minute, second=0, microsecond=0)
            if not m["year"] and t < now - timedelta(days=1):   # 연말에 걸친 날짜
                t = t.replace(year=year + 1)
        else:
            t = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if t <= now:   # 시각만 있으면 다음에 오는 그 시각
                t += timedelta(days=1)
    except ValueError:
        return None
    return t.timestamp()


def last_prompt(path):
    """대화 기록에서 마지막으로 입력한 요청 — 어떤 작업이 멈췄는지 보여 주려고.
    Claude Code 가 턴마다 남기는 {"type": "last-prompt"} 줄을 끝에서부터 찾는다 (긴 도구 출력이 많아 넉넉히 읽음)"""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 4_000_000))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except (OSError, TypeError):
        return ""
    for line in reversed(lines):
        if '"last-prompt"' not in line:
            continue
        try:
            return (json.loads(line).get("lastPrompt") or "").strip()
        except ValueError:
            continue
    return ""


def on_limit(hook):
    """사용량 한도로 멈춘 세션 — 초기화 시각에 펫이 세션마다 다시 알린다 (그 전에는 숨겨 둔다)"""
    if (hook.get("error") or "") != "rate_limit" or not app_setting("claude", "limit", True):
        return
    msg = hook.get("last_assistant_message") or ""
    at = reset_time(msg)
    task = plain(last_prompt(hook.get("transcript_path")), 200)
    rid = f"claude-{safe(hook.get('session_id'))}"
    if at is None:   # 시각을 못 읽으면 지금 알린다
        write_req(rid, {**base(hook, ORCA_CTX), "headline": "사용량 한도에 걸렸어요", "line": "",
                        "detail": plain(msg, 200), "full": plain(msg, 2000), "options": [], "ids": [],
                        "expires_at": expires_at("claude")})
        hook_log("limit", hook, "초기화 시각 못 읽음 → 바로 알림")
        return
    at += 30   # 초기화 직후 조금 여유를 둔다
    hhmm = time.strftime("%H:%M", time.localtime(at))
    sec = app_setting("claude", "expire", DONE_EXPIRE_SEC)
    write_req(rid, {
        **base(hook, ORCA_CTX),
        "headline": "사용량이 다시 채워졌어요",
        "line": "",
        "detail": f"멈춘 작업: {task}" if task else "한도로 멈췄던 세션을 이어서 할 수 있어요",
        "full": "\n\n".join(x for x in (f"멈춘 작업: {task}" if task else "", plain(msg, 1000)) if x),
        "options": [], "ids": [],
        "show_at": at,   # 이 시각까지 앱이 숨긴다
        "expires_at": at + sec if sec else None,
    })
    hook_log("limit", hook, f"{hhmm} 초기화 때 다시 알림 예약")


def on_clear(hook):
    path = os.path.join(REQ, f"claude-{safe(hook.get('session_id'))}.json")
    if os.path.exists(path):
        notice_log(f"지움 claude-{safe(hook.get('session_id'))} 터미널에서 다시 입력함")
    remove(path)


def notice_log(msg):
    """앱과 같은 알림 기록(notice.log)에 한 줄 — 알림이 왜 사라졌는지 추적용"""
    path = os.path.join(PET, "notice.log")
    try:
        lines = open(path, encoding="utf-8").read().splitlines()[-499:] if os.path.exists(path) else []
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines + [f"{time.strftime('%m-%d %H:%M:%S')} {msg}"]) + "\n")
    except OSError:
        pass


def ask_questions(tool_input):
    """AskUserQuestion 입력 → 말풍선 질문 모드 목록 (질문마다 번호 붙은 선택지)"""
    out, seen = [], set()
    for i, q in enumerate((tool_input or {}).get("questions") or []):
        qid = (q.get("header") or "").strip() or str(i + 1)
        if qid in seen:
            qid = f"{qid}{i + 1}"
        seen.add(qid)
        opts = [{"no": str(k + 1), "label": o.get("label", "")} for k, o in enumerate(q.get("options") or [])]
        out.append({"id": qid, "title": q.get("question", ""), "free": not opts, "options": opts})
    return out


def ask_markdown(tool_input):
    """「자세히 보기」에 펼칠 질문·선택지 설명"""
    lines = []
    for i, q in enumerate((tool_input or {}).get("questions") or []):
        lines.append(f"**{i + 1}. {q.get('question', '')}**" + (" (여러 개 고를 수 있음)" if q.get("multiSelect") else ""))
        for k, o in enumerate(q.get("options") or []):
            desc = o.get("description") or ""
            lines.append(f"- {k + 1}. {o.get('label', '')}" + (f" — {desc}" if desc else ""))
        lines.append("")
    return "\n".join(lines).strip()


def ask_answers(tool_input, picked):
    """말풍선 답 {질문id: 번호 또는 직접 적은 글} → AskUserQuestion answers {질문 원문: 선택지 이름}"""
    answers = {}
    for spec, q in zip(ask_questions(tool_input), (tool_input or {}).get("questions") or []):
        v = (picked.get(spec["id"]) or "").strip()
        if not v:
            return None
        label = next((o["label"] for o in spec["options"] if o["no"] == v), v)
        answers[q.get("question", "")] = label
    return answers


def wait_decision(rid):
    """펫 말풍선 답을 기다린다 — 닫기·시간 초과면 None. 요청·응답 파일은 정리한다"""
    resp = os.path.join(RESP, rid + ".json")
    deadline = time.time() + PERMISSION_WAIT_SEC
    decision = None
    try:
        while time.time() < deadline:
            if os.path.exists(resp):
                try:
                    with open(resp, encoding="utf-8") as f:
                        decision = json.load(f).get("decision")
                except (OSError, ValueError):
                    decision = None
                break
            time.sleep(0.3)
    finally:
        remove(resp)
        remove(os.path.join(REQ, rid + ".json"))
    return decision


def permission_output(decision):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}},
                     ensure_ascii=False))


def on_ask(hook):
    """AskUserQuestion(선택형 질문) — JSON 대신 질문 모드 말풍선으로 묻고, 고른 답을 그대로 넘긴다"""
    ti = hook.get("tool_input") or {}
    questions = ask_questions(ti)
    if not questions:
        return
    rid = f"claude-perm-{safe(hook.get('session_id'))}-{int(time.time() * 1000) % 10**9}"
    first = questions[0]["title"]
    write_req(rid, {
        **base(hook, ORCA_CTX),
        "headline": "선택이 필요해요" + (f" · 질문 {len(questions)}개" if len(questions) > 1 else ""),
        "line": "",
        "detail": plain(first, 200),
        "full": plain(ask_markdown(ti), 4000),
        "full_md": ask_markdown(ti)[:6000],
        "questions": questions,
        "options": [], "ids": [],
        "await": True,
        "expires_at": time.time() + PERMISSION_WAIT_SEC,
    })
    decision = wait_decision(rid)
    if not (decision or "").startswith("multi:"):
        hook_log("ask", hook, f"답 없음({decision})")
        return   # 답이 없으면 결정 없이 끝 → 터미널에서 평소처럼 묻는다
    try:
        answers = ask_answers(ti, json.loads(decision[len("multi:"):]))
    except ValueError:
        answers = None
    if answers:
        permission_output({"behavior": "allow", "updatedInput": {**ti, "answers": answers}})
    hook_log("ask", hook, f"답={answers}" if answers else f"답 없음({decision})")


def on_permission(hook):
    """펫 버튼의 답을 stdout 결정으로 돌려준다. 답이 없으면 아무것도 출력하지 않고 끝나 평소처럼 터미널에서 묻는다"""
    if not settings().get("claude_permission") or not pet_running():
        return
    name = hook.get("tool_name", "")
    if name == "AskUserQuestion":
        on_ask(hook)
        return
    summary = tool_summary(name, hook.get("tool_input"))
    rid = f"claude-perm-{safe(hook.get('session_id'))}-{int(time.time() * 1000) % 10**9}"
    write_req(rid, {
        **base(hook, ORCA_CTX),
        "headline": f"허용할까요? · {name}",
        "line": "",
        "detail": plain(summary, 200),
        "full": summary[:4000],
        "options": ["허용", "거부"], "ids": ["allow", "deny"], "primary": 0,
        "await": True,
        "expires_at": time.time() + PERMISSION_WAIT_SEC,
    })
    decision = wait_decision(rid)
    if decision in ("allow", "deny"):
        permission_output({"behavior": decision})
    # 그 밖(닫기·열기·시간 초과)은 결정 없이 끝 → 터미널에서 평소처럼 묻는다


def hook_log(mode, hook, result):
    """훅이 불린 기록 — 알림이 안 뜰 때 원인을 보려고 (최근 500줄만 유지)"""
    path = os.path.join(PET, "hook.log")
    line = (f"{time.strftime('%m-%d %H:%M:%S')} {mode} 세션={safe(hook.get('session_id'))} "
            f"orca={'예' if ORCA_CTX else '아니오'} 종류={hook.get('notification_type', '')} → {result}\n")
    try:
        os.makedirs(PET, exist_ok=True)
        lines = open(path, encoding="utf-8").readlines()[-499:] if os.path.exists(path) else []
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(lines + [line])
    except OSError:
        pass


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if os.environ.get("AGENT_PET_INTERNAL"):   # 펫이 띄운 claude -p (추천 답장 등) 는 알리지 않는다
        return
    try:
        hook = json.load(sys.stdin)
    except ValueError:
        hook = {}
    global ORCA_CTX
    if mode == "clear":   # 다시 입력하면 그 세션 말풍선을 내린다 — 소스 설정과 상관없이 (Orca 세션도)
        on_clear(hook)
        hook_log(mode, hook, "말풍선 내림")
        return
    ORCA_CTX = orca_context()
    on = source_on(ORCA_CTX)
    hook_log(mode, hook, "처리" if on else "꺼짐(소스 설정)")
    if not on:
        return
    {"stop": on_stop, "notify": on_notify, "limit": on_limit, "clear": on_clear, "permission": on_permission}.get(mode, lambda h: None)(hook)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:   # Claude Code 동작에 영향이 없게 기록만
        os.makedirs(PET, exist_ok=True)
        with open(os.path.join(PET, "watch.err"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%m-%d %H:%M:%S')} claude {e}\n")
