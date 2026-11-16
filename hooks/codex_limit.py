#!/usr/bin/env python3
"""Codex 사용량 한도 감시 — 펫이 45초마다 부른다.

Codex notify 는 정상으로 끝난 턴(agent-turn-complete)에만 불려서, 한도에 걸려 멈춘 턴은 알 수 없다.
그래서 최근 세션 기록(~/.codex/sessions/**/rollout-*.jsonl)을 읽어
마지막 턴이 usage_limit_exceeded 로 끝난 세션을 찾고, 기록에 있는 초기화 시각(rate_limits.*.resets_at)에
펫이 그 세션 말풍선을 띄우도록 codex-<thread>.json 에 "show_at" 을 써 둔다.
한 턴은 한 번만 알린다 (codex_limit_seen.json).
"""
import glob
import json
import os
import re
import time

PET = os.environ.get("AGENT_PET_DIR") or os.path.expanduser("~/.agent-pet")
REQ = os.path.join(PET, "requests")
SEEN = os.path.join(PET, "codex_limit_seen.json")
SESSIONS = os.environ.get("CODEX_SESSIONS_DIR") or os.path.expanduser("~/.codex/sessions")   # 시험용으로 바꿀 수 있다
RECENT_SEC = 6 * 3600     # 이만큼 안에 바뀐 세션 기록만 본다
TAIL_BYTES = 2_000_000    # 기록 끝에서 읽을 양 — 마지막 턴만 보면 된다
EXPIRE_SEC = 3600


def settings():
    try:
        with open(os.path.join(PET, "settings.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(path + ".tmp", path)


def plain(text, limit):
    t = re.sub(r"[*`#>|]", "", text or "")
    t = re.sub(r"\s+", " ", t).strip()
    return t if len(t) <= limit else t[: limit - 1] + "…"


def recent_rollouts(now):
    """오늘·어제 폴더에서 최근에 바뀐 세션 기록"""
    out = []
    for day in (now, now - 86400):
        pattern = os.path.join(SESSIONS, time.strftime("%Y/%m/%d", time.localtime(day)), "rollout-*.jsonl")
        for p in glob.glob(pattern):
            try:
                if now - os.path.getmtime(p) < RECENT_SEC:
                    out.append(p)
            except OSError:
                pass
    return sorted(set(out))


def session_meta(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.loads(f.readline())
        return d.get("payload") or {} if d.get("type") == "session_meta" else {}
    except (OSError, ValueError):
        return {}


def tail_events(path):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - TAIL_BYTES))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def reset_at(rate_limits):
    """한도에 닿은 창(100% 이상)의 초기화 시각 — 여럿이면 가장 늦은 것. 없으면 None (크레딧 소진 등)"""
    rl = rate_limits or {}
    wins = [w for w in (rl.get("primary"), rl.get("secondary")) if isinstance(w, dict) and w.get("resets_at")]
    full = [w for w in wins if (w.get("used_percent") or 0) >= 100]
    pick = full or (wins if rl.get("rate_limit_reached_type") else [])
    return max(w["resets_at"] for w in pick) if pick else None


def limited_turn(events):
    """마지막 턴이 사용량 한도로 끝났으면 (turn_id, 오류 메시지, 초기화 시각, 마지막 요청) — 아니면 None"""
    last_done = None
    for i in range(len(events) - 1, -1, -1):
        p = events[i].get("payload") or {}
        if events[i].get("type") == "event_msg" and p.get("type") == "task_complete":
            last_done = i
            break
    if last_done is None:
        return None
    p = events[last_done]["payload"]
    err = p.get("error") or {}
    if err.get("codex_error_info") != "usage_limit_exceeded":
        return None
    at, asked = None, ""
    for e in reversed(events[:last_done]):
        q = e.get("payload") or {}
        if at is None and q.get("type") == "token_count" and "rate_limits" in q:
            at = reset_at(q.get("rate_limits"))
            at = at if at is not None else False   # 찾았지만 초기화 시각 없음
        if not asked and q.get("type") == "message" and q.get("role") == "user":
            asked = " ".join(c.get("text", "") for c in q.get("content") or [] if c.get("type") == "input_text")
        if at is not None and asked:
            break
    return p.get("turn_id") or "", err.get("message") or "", at or None, asked


def main():
    now = time.time()
    src = settings().get("sources", {})
    seen = load_json(SEEN, {})
    seen = {k: v for k, v in seen.items() if now - v < 7 * 86400}
    changed = False
    for path in recent_rollouts(now):
        meta = session_meta(path)
        if meta.get("thread_source") == "subagent" or not meta.get("id"):
            continue
        hit = limited_turn(tail_events(path))
        if not hit or hit[0] in seen:
            continue
        turn, msg, at, asked = hit
        seen[turn] = now
        changed = True
        orca = meta.get("originator") == "orca_desktop"   # Orca 채팅 모드에서 띄운 Codex
        if not (src.get("orca", True) if orca else src.get("codex", True)):
            continue
        if at and at + 30 < now:   # 이미 풀린 지 오래 — 다시 알릴 필요 없음
            continue
        cwd = meta.get("cwd") or ""
        rid = f"codex-{re.sub(r'[^0-9A-Za-z_-]', '', meta['id'])[:24]}"
        sec = (settings().get("apps", {}).get("codex") or {}).get("expire", EXPIRE_SEC)
        req: dict = {
            "source": "orca" if orca else "codex",
            "agent": "codex",
            "tag": f"Orca · Codex · {os.path.basename(cwd) or '작업'}" if orca else f"Codex · {os.path.basename(cwd) or '작업'}",
            "line": "",
            "options": [], "ids": [],
            "openLabel": "Orca에서 보기" if orca else "폴더 열기",
            "link": f"orca-worktree:{cwd}" if orca else (f"file://{cwd}" if cwd else ""),
        }
        if at:   # 초기화 시각에 다시 알린다 — 그 전에는 펫이 숨겨 둔다
            show = at + 30
            req.update({
                "headline": "사용량이 다시 채워졌어요",
                "detail": f"멈춘 작업: {plain(asked, 180)}" if asked else "한도로 멈췄던 세션을 이어서 할 수 있어요",
                "full": "\n\n".join(x for x in (f"멈춘 작업: {plain(asked, 1000)}" if asked else "", msg) if x),
                "show_at": show,
                "expires_at": show + sec if sec else None,
            })
        else:   # 크레딧 소진처럼 초기화 시각이 없으면 지금 알린다
            req.update({
                "headline": "사용량 한도에 걸렸어요",
                "detail": plain(msg, 200),
                "full": "\n\n".join(x for x in (f"멈춘 작업: {plain(asked, 1000)}" if asked else "", msg) if x),
                "expires_at": now + sec if sec else None,
            })
        write_json(os.path.join(REQ, rid + ".json"), req)
    if changed:
        write_json(SEEN, seen)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:   # 감시가 실패해도 펫에는 영향이 없게 기록만
        os.makedirs(PET, exist_ok=True)
        with open(os.path.join(PET, "watch.err"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%m-%d %H:%M:%S')} codex_limit {e}\n")
