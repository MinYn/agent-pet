#!/usr/bin/env python3
"""Multica 소스 — AgentPet 앱이 45초마다 실행한다 (데이터 폴더: AGENT_PET_DIR, 기본 ~/.agent-pet).

팀 스쿼드 메뉴바와 같은 범위·판정으로 — 내 SDD 리더의 최상위 이슈 + 내가 만든 스쿼드의 이슈 중
펫 메뉴 「알림 범위」에 맞는 🔴 줄만 골라
  · 사람 차례만(기본): 하위 이슈가 모두 끝나 사람이 할 일을 기다리는 SDD 리더 최상위 이슈
  · 결정 대기: AI가 내 선택을 기다림 (waiting_for=decision)
  · 내가 볼 것 전부: 실행 실패·사람 대기 표시·답 대기·사람 차례·멈춤(20분 넘게)
을 찾아 <데이터 폴더>/requests/<id>.json 으로 펫 말풍선에 띄운다.
(맨 위 칩: "Multica · 이슈 번호 · 에이전트 이름", 본문: 이슈 제목 + 에이전트의 마지막 댓글)

말풍선에서 빠른 답장을 누르면 펫이 responses/<id>.json 을 쓰고 `--respond` 로 이 스크립트를 바로 부른다
→ 에이전트의 마지막 댓글에 답글로 그 문장을 단다. [이슈 열기]·✕ 는 그 상태가 바뀔 때까지 다시 안 띄움.

사용: python3 multica_watch.py            # 한 번 훑기
      python3 multica_watch.py --respond  # 눌린 답장 보내기
      python3 multica_watch.py --demo     # 가짜 요청 2개 (말풍선·뱃지 확인용)
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

PET = os.environ.get("AGENT_PET_DIR") or os.path.expanduser("~/.agent-pet")
REQ, RESP = os.path.join(PET, "requests"), os.path.join(PET, "responses")
STATE = os.path.join(PET, "state.json")
SETTINGS = os.path.join(PET, "settings.json")   # {"scope": "human_turn"(기본) | "decision" | "all"} — 펫 메뉴 「알림 범위」가 씀. 판정은 스쿼드 메뉴바와 같다
MULTICA = shutil.which("multica", path=os.pathsep.join([os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin"])) or "multica"
APP_URL = "https://multica.ai"
LOCK = os.path.join(PET, "watch.lock")
FULL_LIMIT = 900
ANSWERED = os.path.join(PET, "answered")   # 답했지만 아직 상태에 반영 전인 요청 표시
# 빠른 답장 추천 — 댓글이 답 형식을 정해 주지 않은 질문에 Claude가 답 2~3개와 추천 1개를 만든다
CLAUDE = shutil.which("claude", path=os.pathsep.join([os.environ.get("PATH", ""), os.path.expanduser("~/.local/bin"),
                                                     "/opt/homebrew/bin", "/usr/local/bin"]))
SUGGEST_MODEL = "claude-sonnet-5-5"
SUGGEST_TIMEOUT = 60
SUGGEST_RETRY_SEC = 600      # 추천 생성이 실패하면 10분 뒤 다시 시도
SUGGEST_PROMPT = """너는 Multica(AI 에이전트 협업 도구)의 사용자 대신 빠른 답장 버튼을 만든다.
에이전트가 사용자에게 선택·판단을 요청한 댓글을 읽고, 사용자가 버튼 하나로 바로 보낼 수 있는 답 2~3개를 만든다.

규칙
- 댓글이 실제로 묻는 선택지를 답으로 만든다. 일반적인 "좋아요/싫어요"보다 구체적인 행동을 담는다.
- 정확히 하나에 recommended=true를 준다. 댓글의 근거(중복 작업 방지, 규칙 준수, 위험 최소화)로 가장 타당한 답이다.
- label: 버튼 글자, 18자 이내 한국어, 명사형·짧은 동사형.
- reply: 에이전트에게 댓글로 달 문장, 한두 문장 존댓말. 무엇을 하라는지 분명하게 쓴다.
- reason: 추천 이유 한 줄, 60자 이내.
- 출력은 JSON 하나만: {"options":[{"label":"","reply":"","recommended":true}],"reason":""}"""

DONE = {"done", "cancelled", "canceled"}
TURN = {"blocked", "in_review"}
ACTIVE = {"queued", "dispatched", "running", "waiting_local_directory", "pending", "claimed", "starting"}
FAILED = {"failed", "error", "timed_out"}   # 사람이 취소한 실행(cancelled)은 뜻이 있어 멈춘 것이라 안 알림
QUEUED = {"backlog", "todo"}                # 앞 단계를 기다리는 하위 이슈
QA_STATUS = "qa"                            # 「QA 중」 — QA 요청·결과를 기다리는 중
LEADER = "SDD 리더"                          # 스쿼드 설치가 만드는 리더 이름 앞부분 — 리더는 최상위 이슈만 본다
HUMAN_WAIT = {"decision", "pr-approval", "qa-human", "deploy"}   # 사람을 기다리는 waiting_for (ci·review는 에이전트 대기)
STUCK_MIN = 5   # 기본 — 펫 메뉴 「알림 범위 › Multica › 멈춤 알림 기준」(apps.multica.stuck_min) 로 바꾼다
WAIT_LABEL = {"decision": "결정이 필요해요", "pr-approval": "PR 승인을 기다려요", "qa-human": "QA 확인이 필요해요", "deploy": "배포를 기다려요"}
REPLIES = {   # 「all」 범위의 기본 답장 (선택 대기는 댓글이 정해 준 답으로 버튼을 만든다)
    "turn": ["좋아요, 진행해 주세요", "잠깐 보류해 주세요"],
    "fail": ["다시 시도해 주세요", "실패한 이유를 알려 주세요"],
    "stuck": ["이어서 진행해 주세요", "멈춘 이유를 알려 주세요"],
}


def desktop_link(web_url):
    """Multica 데스크톱 앱이 받는 딥링크로 감싼다 (multica://open/issue?url=<이슈 웹 주소>)

    데스크톱 앱은 https 주소를 직접 받지 않고 이 형식만 이슈 화면으로 라우팅한다.
    """
    return "multica://open/issue?url=" + urllib.parse.quote(web_url, safe="")


def cli(*args, timeout=30):
    r = subprocess.run([MULTICA, *args, "--output", "json"], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[:200])
    return json.loads(r.stdout or "null")


def rows(d, key):
    return d if isinstance(d, list) else (d or {}).get(key, [])


def load_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(st):
    os.makedirs(PET, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False)
    os.replace(tmp, STATE)


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


def minutes_since(iso):
    if not iso:
        return 0
    then = datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - then).total_seconds() / 60


def plain(text, limit=170):
    t = re.sub(r"```.*?```", " ", text or "", flags=re.S)
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)
    t = re.sub(r"[*_`#>|]", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t if len(t) <= limit else t[: limit - 1] + "…"


def stuck_minutes():
    """멈춤 알림 기준(분) — 마지막 활동 뒤 이만큼 조용하면 알린다"""
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            return int((json.load(f).get("apps", {}).get("multica") or {}).get("stuck_min", STUCK_MIN))
    except (OSError, ValueError, TypeError):
        return STUCK_MIN


def scope():
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            return json.load(f).get("scope") or "human_turn"
    except (OSError, ValueError):
        return "human_turn"


def refresh_static(st):
    """10분마다: 내 id, 내 에이전트·스쿼드, 에이전트 이름, 워크스페이스 주소"""
    if time.time() - st.get("static_at", 0) < 600 and st.get("me"):
        return
    me = cli("user", "profile", "get")["id"]
    agents = rows(cli("agent", "list"), "agents")
    squads = rows(cli("squad", "list"), "squads")
    st["me"] = me
    st["names"] = {a["id"]: a.get("name", "") for a in agents} | {s["id"]: s.get("name", "") for s in squads}
    st["agents"] = [{"id": a["id"], "name": a.get("name", ""), "mine": a.get("owner_id") == me} for a in agents if not a.get("archived_at")]
    st["owners"] = [a["id"] for a in agents if a.get("owner_id") == me and not a.get("archived_at")] + \
                   [s["id"] for s in squads if s.get("creator_id") == me and not s.get("archived_at")]
    st["squads"] = [s["id"] for s in squads if s.get("creator_id") == me and not s.get("archived_at")]
    st["leaders"] = [a["id"] for a in agents if a.get("owner_id") == me and not a.get("archived_at") and a.get("name", "").startswith(LEADER)]
    st["slug"] = (cli("workspace", "get") or {}).get("slug", "")
    st["static_at"] = time.time()


FIELDS = "id,identifier,title,status,status_category,creator_id,assignee_id,assignee_type,last_activity_at,updated_at,metadata,parent_issue_id"


OPEN_STATUSES = ("backlog", "todo", "in_progress", "in_review", "blocked")


def my_issues(st):
    """스쿼드 메뉴바와 같은 범위: 내 SDD 리더가 맡은 최상위 이슈 + 내가 만든 스쿼드가 맡은 이슈.
    끝난 이슈가 한 쪽(100건)을 채워 미완료 이슈가 밀려나지 않게 상태로 서버에서 거른다"""
    found = {}
    leaders = set(st.get("leaders", []))
    for owner in st.get("leaders", []) + st.get("squads", []):
        off, statuses = 0, (*OPEN_STATUSES, QA_STATUS)
        while True:
            try:
                d = cli("issue", "list", "--assignee-id", owner, "--status", ",".join(statuses),
                        "--limit", "100", "--offset", str(off), "--fields", FIELDS)
            except RuntimeError as e:
                # 「QA 중」 상태가 없는 워크스페이스는 기본 상태로만 다시 찾는다
                if "invalid status" not in str(e) or statuses == OPEN_STATUSES:
                    raise
                statuses = OPEN_STATUSES
                continue
            page = rows(d, "issues")
            for i in page:
                if i.get("status_category") not in DONE and not (owner in leaders and i.get("parent_issue_id")):
                    found[i["id"]] = i
            if not (isinstance(d, dict) and d.get("has_more")) or not page:
                break
            off += len(page)
    return list(found.values())


STATUS_KO = {"in_review": "검토 대기", "blocked": "답 대기", "todo": "시작 전", "backlog": "시작 전", "in_progress": "진행 중", "qa": "QA 중"}


def has_wakeup(issue_id):
    """아직 울리지 않은 wakeup(시간 예약·이벤트 대기)이 있으면 True — 메뉴바의 🟣 예약 대기.
    조회에 실패하면 예약이 없는 것처럼 본다(메뉴바와 같이 사람이 열어 보게)"""
    try:
        for w in rows(cli("issue", "wakeup", "list", issue_id), "wakeups"):
            if not w.get("enabled") or w.get("disabled_at") or w.get("paused_reason"):
                continue
            if w.get("mode") == "once" and (w.get("fire_count") or 0) >= 1:
                continue
            return True
    except Exception:
        pass
    return False


def failure_text(run):
    """실패한 실행의 오류 한 줄 — 사용량 한도는 다시 실행할 수 있는 시각을 적는다 (메뉴바와 같은 문구)"""
    error = str(run.get("error") or "")
    if "limit" in error.lower():
        resets = error.split("resets", 1)[1].split("(")[0].strip() if "resets" in error else ""
        return "사용량 한도" + (f", {resets} 이후 다시 실행" if resets else "")
    return (error.splitlines() or ["오류 내용 없음"])[0][:40]


def menubar_kind(issue, runs, parents, leaders):
    """메뉴바 kind()와 같은 순서로 판정 → (분류, 세부)
    분류: working · children · queued · qa · scheduled · attention(🔴 내가 볼 것)
    attention 세부: fail(실행 실패) · decision/pr-approval/qa-human/deploy(사람 대기 표시) ·
                   reply(답 대기) · human(사람 차례, 하위 이슈 모두 끝남) · stuck(멈춤)"""
    status = issue.get("status")
    if any(r.get("status") in ACTIVE for r in runs):
        return "working", ""
    last = max(runs, key=lambda r: r.get("created_at") or "", default=None)
    if last and last.get("status") in FAILED:
        return "attention", "fail"   # 하위 이슈·예약을 기다리는 것처럼 보여도 실행이 실패해 멈춰 있다
    wait_kind = ((issue.get("metadata") or {}).get("waiting_for") or "").split(":")[0]
    if status in TURN and wait_kind in HUMAN_WAIT:
        return "attention", wait_kind   # 하위 이슈가 남아 있어도 이 이슈가 사람의 답을 기다린다
    if issue["id"] in parents:
        return "children", ""
    if status in QUEUED:
        return "queued", ""
    if status == QA_STATUS:
        return "qa", ""
    if has_wakeup(issue["id"]):
        return "scheduled", ""
    if status in TURN:
        return "attention", "reply"
    if issue.get("assignee_id") in leaders:
        return "attention", "human"
    return "attention", "stuck"


def classify(issue, parents, leaders=()):
    """(종류, 큰 글씨, 실행 목록) — 메뉴바 판정을 알림 범위로 거른다
    · human_turn(기본): 🔴 사람 차례, 하위 이슈 모두 끝남 — SDD 리더 최상위 이슈
    · decision      : 🔴 결정 대기 — waiting_for=decision 으로 사람의 선택을 기다림
    · all           : 🔴 내가 볼 것 전부 — 실행 실패·사람 대기 표시·답 대기·사람 차례·멈춤
    종류(말풍선): ask(결정) · human(사람 차례) · turn(대기·답 대기) · fail(실패) · stuck(멈춤)"""
    runs = rows(cli("issue", "runs", issue["id"]), "runs")
    group, sub = menubar_kind(issue, runs, parents, leaders)
    if group != "attention":
        return None, "", runs
    sc = scope()
    if sc == "human_turn" and sub != "human":
        return None, "", runs
    if sc == "decision" and sub != "decision":
        return None, "", runs
    if sub == "fail":
        last = max(runs, key=lambda r: r.get("created_at") or "")
        return "fail", f"실행이 실패했어요 · {failure_text(last)}", runs
    if sub == "decision":
        return "ask", "", runs
    if sub in HUMAN_WAIT:
        return "turn", WAIT_LABEL[sub], runs
    if sub == "reply":
        return "turn", "검토를 기다려요" if issue.get("status") == "in_review" else "답을 기다리고 있어요", runs
    if sub == "human":
        return "human", "사람 차례예요 · 하위 이슈가 모두 끝났어요", runs
    # 멈춤: 메뉴바는 바로 빨간 줄이지만, 실행 사이 잠깐 빈 틈마다 말풍선이 뜨지 않게 몇 분은 기다린다
    stuck_min = stuck_minutes()
    if minutes_since(issue.get("last_activity_at")) <= stuck_min:
        return None, "", runs
    return "stuck", f"{stuck_min}분 넘게 멈춰 있어요", runs


MENTION = re.compile(r"\[@?([^\]]*)\]\(mention://(member|agent|issue)/([0-9a-f-]+)\)")


def ask_comment(comments):
    """사람을 부른 에이전트 댓글 — 첫 줄에 사람(member) 멘션이 있는 가장 최근 댓글. 없으면 가장 최근 에이전트 댓글"""
    agent = [c for c in comments if c.get("author_type") == "agent"]
    calling = [c for c in agent if "mention://member/" in (c.get("content") or "").split("\n")[0]]
    return max(calling or agent, key=lambda c: c.get("created_at") or "", default=None)


def question_of(text):
    """첫 줄에서 멘션·링크 표시를 걷어 낸 질문 한 줄"""
    for line in (text or "").strip().split("\n")[:6]:   # 첫 줄이 멘션뿐이면 다음 줄
        q = plain(MENTION.sub(lambda m: "" if m.group(2) == "member" else m.group(1), line), 90)
        if len(q) >= 4:
            return q
    return "선택이 필요해요"


def answers_of(text, agents):
    """댓글이 정해 준 답 방법대로 (버튼 글자, 실제로 달 댓글) 목록을 만든다
    · `계속`·「없음」이라고 답해 주세요 → 그 말 그대로
    · 번호로 답해 주세요 + 1. 2. 목록 → 「1번」…
    · ○○를 멘션해 → 답 앞에 그 에이전트 멘션"""
    body = MENTION.sub(lambda m: m.group(1), text or "")
    prefix = ""
    m = re.search(r"([^\s`「」]+?)(?:를|을)\s*멘션해", body)
    if m:
        name = m.group(1)
        cands = [a for a in agents if name in a["name"]]
        cands.sort(key=lambda a: (not a["mine"], len(a["name"])))
        if cands:
            prefix = f"[@{cands[0]['name']}](mention://agent/{cands[0]['id']}) "
    out = []
    for lab in re.findall(r"[`「]([^`」\n]{1,24})[`」]\s*(?:이?라고|으?로)\s*답", body):
        out.append((lab, prefix + lab))
    if re.search(r"번호로\s*(?:골라|답|알려)", body):
        for num, lab in re.findall(r"(?m)^\s*(?:\*\*)?(\d{1,2})[.)]\s*(?:\*\*)?\s*(.+)$", body):
            out.append((f"{num}. {plain(lab, 26)}", prefix + f"{num}번으로 해 주세요."))
    seen, uniq = set(), []
    for o in out:
        if o[0] not in seen:
            seen.add(o[0]); uniq.append(o)
    return uniq[:4]


def suggest(st, issue, comment):
    """질문 댓글에 대한 추천 빠른 답장 — ([(버튼 글자, 달 댓글)], 추천 이유). 댓글 id별로 한 번만 만든다"""
    try:   # 펫 메뉴 「알림 범위 › Multica › 추천 답장 만들기」
        with open(SETTINGS, encoding="utf-8") as f:
            if (json.load(f).get("apps", {}).get("multica") or {}).get("suggest") is False:
                return [], ""
    except (OSError, ValueError):
        pass
    cache = st.setdefault("suggest", {})
    cid = comment.get("id")
    hit = cache.get(cid)
    if hit and (hit.get("pairs") or time.time() - hit.get("at", 0) < SUGGEST_RETRY_SEC):
        return [tuple(x) for x in hit.get("pairs", [])], hit.get("reason", "")
    pairs, reason = [], ""
    try:
        if not CLAUDE:
            raise RuntimeError("claude CLI를 찾지 못함")
        body = MENTION.sub(lambda m: m.group(1), comment.get("content") or "")[:6000]
        r = subprocess.run(
            [CLAUDE, "-p", "--model", SUGGEST_MODEL, "--tools", "", "--strict-mcp-config", "--setting-sources", "",
             "--no-session-persistence", "--system-prompt", SUGGEST_PROMPT],
            input=f"이슈: {issue.get('identifier', '')} {issue.get('title', '')}\n\n에이전트 댓글:\n{body}",
            capture_output=True, text=True, timeout=SUGGEST_TIMEOUT, cwd=PET)
        m = re.search(r"\{.*\}", r.stdout, re.S)
        if not m:
            raise RuntimeError(f"추천 응답 해석 실패: {(r.stderr or r.stdout).strip()[:150]}")
        data = json.loads(m.group(0))
        opts = [o for o in data.get("options", []) if o.get("label") and o.get("reply")][:3]
        opts.sort(key=lambda o: not o.get("recommended"))   # 추천을 맨 앞에
        pairs = [(("⭐ " if o.get("recommended") else "") + o["label"][:18], o["reply"]) for o in opts]
        reason = plain(data.get("reason", ""), 60)
    except Exception as e:   # 추천이 안 돼도 말풍선은 띄운다
        with open(os.path.join(PET, "watch.err"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%m-%d %H:%M:%S')} suggest {issue.get('identifier', '')} {e}\n")
    cache[cid] = {"pairs": pairs, "reason": reason, "at": time.time()}
    return pairs, reason


def full_text(text, limit=FULL_LIMIT):
    """말풍선을 펼쳤을 때 보일 본문 — 마크다운 표시만 걷고 문단 줄바꿈은 살린다"""
    lines = []
    for line in MENTION.sub(lambda m: m.group(1), text or "").split("\n"):
        if line.strip().startswith("```"):
            continue
        t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", line)
        t = re.sub(r"[*`#>|]", "", t)
        t = re.sub(r"(?<![0-9A-Za-z])_|_(?![0-9A-Za-z])", "", t).strip()   # 단어 안 밑줄(waiting_for)은 남김
        if t or (lines and lines[-1]):
            lines.append(t)
    t = "\n".join(lines).strip()
    return t if len(t) <= limit else t[: limit - 1] + "… (전체는 Multica에서)"


def parent_of(st, issue):
    """상위 이슈의 (번호, 제목) — 하루 동안 캐시. 없거나 조회 실패면 None"""
    pid = issue.get("parent_issue_id")
    if not pid:
        return None
    cache = st.setdefault("parents", {})
    hit = cache.get(pid)
    if hit and time.time() - hit.get("at", 0) < 86400:
        return hit["identifier"], hit["title"]
    try:
        d = cli("issue", "get", pid)
        d = d.get("issue", d) if isinstance(d, dict) else {}
        cache[pid] = {"identifier": d.get("identifier", ""), "title": d.get("title", ""), "at": time.time()}
        return cache[pid]["identifier"], cache[pid]["title"]
    except Exception:
        return None


def scan():
    st = load_state()
    refresh_static(st)
    names = st["names"]
    notified, dismissed = st.setdefault("notified", {}), st.setdefault("dismissed", {})
    keep = set()
    issues = my_issues(st)
    # 끝나지 않은 하위 이슈가 있는 이슈 — 메뉴바와 같이 내 스쿼드·SDD 리더가 맡은 이슈 안에서만 센다
    parents = {i.get("parent_issue_id") for i in issues if i.get("parent_issue_id")}
    leaders = set(st.get("leaders", []))
    with ThreadPoolExecutor(max_workers=6) as pool:   # 이슈마다 실행·예약 조회 — 메뉴바처럼 병렬로
        judged = list(pool.map(lambda i: classify(i, parents, leaders), issues))
    for issue, (kind, headline, runs) in zip(issues, judged):
        if not kind:
            continue
        sig = f"{kind}:{issue.get('status')}:{issue.get('last_activity_at') or issue.get('updated_at')}"
        rid = f"{issue['id'][:13].replace('-', '')}-{kind}"
        if dismissed.get(issue["id"]) == sig:
            continue
        keep.add(rid)
        if notified.get(rid) == sig and os.path.exists(os.path.join(REQ, rid + ".json")):
            continue
        if os.path.exists(os.path.join(ANSWERED, rid)):   # 방금 답한 요청 — 반영 대기 중
            continue
        # 에이전트 이름: 마지막 실행을 한 에이전트 → 없으면 담당자(에이전트·스쿼드) 이름
        last = max(runs, key=lambda r: r.get("created_at") or "", default=None)
        agent = names.get((last or {}).get("agent_id")) or names.get(issue.get("assignee_id")) or "에이전트"
        comments = rows(cli("issue", "comment", "list", issue["id"]), "comments")
        lastc = ask_comment(comments)
        text = (lastc or {}).get("content", "")
        if kind in ("ask", "human"):   # 사람을 부른 댓글: 큰 글씨 = 그 댓글 첫 줄, 버튼 = 댓글이 정해 준 답
            if lastc and lastc.get("author_id") in names:   # 부른 에이전트 이름이 더 정확
                agent = names[lastc["author_id"]]
            calling = lastc and "mention://member/" in text.split("\n")[0]
            headline = question_of(text) if (kind == "ask" or calling) else headline
            pairs = answers_of(text, st.get("agents", []))
            detail = plain("\n".join(text.strip().split("\n")[1:])) if (kind == "ask" or calling) else plain(text)
            if not pairs and lastc:   # 답 형식을 정해 주지 않은 질문 → Claude 추천 답장
                pairs, reason = suggest(st, issue, lastc)
                if reason:
                    detail = plain(f"⭐ 추천: {reason} · {detail}", 200)
        else:
            pairs = [(r, r) for r in REPLIES[kind]]
            detail = plain(text)
        link = desktop_link(f"{APP_URL}/{st.get('slug', '')}/issues/{issue['id']}"
                            + (f"#comment-{lastc['id']}" if (lastc or {}).get("id") else ""))   # 말풍선에 띄운 댓글 위치로
        parent = parent_of(st, issue)
        line = issue.get("title", "")
        if parent:   # 상위 이슈가 있으면 그 제목을 앞에
            line = f"↑ {parent[0]} {parent[1]} › {line}"
        options, ids = [p[0] for p in pairs], [f"reply:{i}" for i in range(len(pairs))]
        full = full_text(text) if lastc else ""
        primary = next((i for i, o in enumerate(options) if o.startswith("⭐")), None)
        write_req(rid, {
            "source": "multica",
            "full": full,   # 앱이 「자세히」로 펼쳐 보여 줄 전문
            "full_md": (text or "")[:6000],   # 원문 마크다운 — 앱이 마크다운으로 그린다
            "primary": primary,   # 추천 답 버튼 (강조)
            "tag": f"Multica · {issue.get('identifier', '')} · {agent}",
            "title": issue.get("identifier", ""), "headline": headline,
            "line": line,
            "detail": detail,
            "options": options, "ids": ids,
            "openLabel": "Multica에서 열기",
            "link": link,
            "session": issue["id"],
        })
        notified[rid] = sig
        st.setdefault("reqs", {})[rid] = {"issue": issue["id"], "parent": (lastc or {}).get("id"), "kind": kind, "sig": sig,
                                          "replies": [p[1] for p in pairs], "full": full}
    live = {r.get("parent") for r in st.get("reqs", {}).values()}
    st["suggest"] = {k: v for k, v in st.get("suggest", {}).items() if k in live}
    # 더는 해당 안 되는 요청은 말풍선에서 내림
    for f in os.listdir(REQ) if os.path.isdir(REQ) else []:
        rid = f[:-5]
        if f.endswith(".json") and not rid.startswith("demo") and rid not in keep:
            remove(os.path.join(REQ, f))
            st.get("reqs", {}).pop(rid, None)
            notified.pop(rid, None)
    save_state(st)


def respond():
    """눌린 답장 처리 — 화면에 보이는 동작(페이지 열기·댓글 달기)은 락 없이 바로 하고,
    상태 기록(다시 안 띄움)만 scan이 끝나길 기다렸다가 최신 상태에 반영한다"""
    snap = load_state().get("reqs", {})
    done = []   # 상태에 반영할 (rid, info)
    for f in os.listdir(RESP) if os.path.isdir(RESP) else []:
        if not f.endswith(".json") or f.startswith("demo"):
            continue
        rid = f[:-5]
        work = os.path.join(RESP, f + ".work")
        try:
            os.rename(os.path.join(RESP, f), work)   # 선점 — 겹쳐 불려도 한 번만 처리(댓글 중복 방지)
            with open(work, encoding="utf-8") as fh:
                d = json.load(fh).get("decision", "")
        except (OSError, ValueError):
            continue
        info = snap.get(rid)
        with open(os.path.join(PET, "respond.log"), "a", encoding="utf-8") as fl:   # 눌린 버튼 기록 (문제 추적용)
            fl.write(f"{time.strftime('%m-%d %H:%M:%S')} {rid} {d} info={'있음' if info else '없음'}\n")
        if info and d.startswith("reply:"):
            replies = info.get("replies") or REPLIES.get(info["kind"], [])
            i = int(d.split(":")[1])
            if i < len(replies):
                args = ["issue", "comment", "add", info["issue"], "--content", replies[i]]
                try:
                    cli(*args, *(["--parent", info["parent"]] if info.get("parent") else []))
                except Exception:
                    try:
                        cli(*args)   # 답글이 안 되면 새 댓글로
                    except Exception:
                        os.rename(work, os.path.join(RESP, f))   # 다음에 다시 시도
                        continue
        base = rid
        if info:   # 답했거나 [이슈 열기]·✕ → scan이 상태에 반영하기 전에 다시 띄우지 않게 표시
            os.makedirs(ANSWERED, exist_ok=True)
            open(os.path.join(ANSWERED, base), "w").close()
            done.append((base, info))
        remove(work)
        remove(os.path.join(REQ, base + ".json"))
    return done


def record_answered(done):
    """락 안에서: 답한 요청을 상태에 반영 — 그 이슈 상태가 바뀔 때까지 다시 안 띄움"""
    st = load_state()
    reqs = st.setdefault("reqs", {})
    for rid, info in done:
        st.setdefault("dismissed", {})[info["issue"]] = info["sig"]
        reqs.pop(rid, None)
    save_state(st)
    for rid, _ in done:
        remove(os.path.join(ANSWERED, rid))


def demo():
    samples = [
        ("demo1", "DEMO-1", "SDD 리더", "하위 이슈가 모두 끝났어요. 운영 배포를 마치면 「배포 완료」라고 답해 주세요.", "예시 기능 개발",
         "스펙·개발·QA 하위 이슈가 모두 끝났어요. 배포 뒤 단계(정리·결과 공유)를 이어서 할게요.",
         [("배포 완료", "배포 완료")]),
        ("demo2", "DEMO-2", "스펙리뷰어", "재리뷰를 계속 진행할까요? 계속하려면 「계속」이라고 답해 주세요.", "예시 스펙 검토",
         "지적 2건은 반영됐고, 남은 1건은 플랜 수정이 필요해요.", [("계속", "계속")]),
    ]
    st = load_state()
    for rid, ident, agent, head, title, detail, pairs in samples:
        write_req(rid, {"tag": f"Multica · {ident} · {agent}", "title": ident, "headline": head, "line": title,
                        "detail": detail, "options": [p[0] for p in pairs], "ids": [f"reply:{i}" for i in range(len(pairs))],
                        "openLabel": "Multica에서 열기", "link": APP_URL, "session": rid})

if __name__ == "__main__":
    os.makedirs(PET, exist_ok=True)
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    lock = open(LOCK, "w")
    try:
        if arg == "--respond":
            done = respond()   # 보이는 동작은 바로
            if done:
                fcntl.flock(lock, fcntl.LOCK_EX)   # 진행 중인 scan이 끝나길 기다렸다가 상태에 반영
                record_answered(done)
            # 가짜 요청의 답은 그냥 지움
            for f in os.listdir(RESP) if os.path.isdir(RESP) else []:
                if f.startswith("demo"):
                    remove(os.path.join(RESP, f)); remove(os.path.join(REQ, f))
        elif arg == "--undismiss":   # 펫 메뉴 「닫은 알림 다시 보기」 — 닫음·알림 기록을 지우고 바로 다시 훑는다
            fcntl.flock(lock, fcntl.LOCK_EX)
            st = load_state()
            st["dismissed"], st["notified"] = {}, {}
            save_state(st)
            scan()
        elif arg == "--demo":
            demo()
        else:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit(0)   # 앞선 scan(추천 생성 중)이 아직 도는 중
            scan()
    except Exception as e:   # 펫이 계속 부르니 오류는 기록만
        with open(os.path.join(PET, "watch.err"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%m-%d %H:%M:%S')} {arg} {e}\n")
