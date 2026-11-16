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
DIRECT_RECENT_MIN = 3 * 24 * 60   # 내 에이전트에 직접 맡겨진 사람 대기 이슈는 이 안에 활동이 있을 때만 알린다
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
    # 내 에이전트에게 직접 맡겨진 이슈(스쿼드 멤버가 이어받은 하위 이슈 등) — 스쿼드·리더 범위 밖이라 위에서 빠진다.
    # 사람의 결정·승인을 기다리는 것만, 오래 묵은 것이 한꺼번에 뜨지 않게 최근 활동이 있는 것만 더한다
    owners, off = set(st.get("owners", [])), 0
    while True:
        d = cli("issue", "list", "--status", ",".join(sorted(TURN)), "--limit", "100", "--offset", str(off), "--fields", FIELDS)
        page = rows(d, "issues")
        for i in page:
            wait = ((i.get("metadata") or {}).get("waiting_for") or "").split(":")[0]
            if (i["id"] not in found and i.get("assignee_id") in owners and wait in HUMAN_WAIT
                    and minutes_since(i.get("last_activity_at")) <= DIRECT_RECENT_MIN):
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
        try:
            data = first_json(r.stdout)
        except ValueError:
            raise RuntimeError(f"추천 응답 해석 실패: {(r.stderr or r.stdout).strip()[:150]}")
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


QUESTIONS_PROMPT = """너는 AI 에이전트가 사람에게 남긴 댓글에서 「사람이 골라야 할 질문들」을 빠짐없이 뽑는다.

출력은 JSON 하나만:
{"multi": true|false,
 "questions": [{"id": "댓글에 적힌 질문 번호 그대로(예: R1, Q2, 3, 질문4)", "title": "질문 한 줄 요약(60자 이내)",
                "options": [{"no": "선택지 번호 그대로(예: 1, A)", "label": "선택지 요약(40자 이내)", "recommended": true|false}],
                "free": true|false}],
 "item_format": "답 하나의 모양 — {id} 와 {option} 자리표시 (예: {id}-{option})",
 "separator": "답 사이 구분자 (예: , )"}

규칙
- 질문이 2개 이상이고 각 질문에 번호가 있을 때만 multi=true. 질문이 하나뿐이면 multi=false, questions 는 비운다.
- 댓글의 모든 질문을 순서대로 빠짐없이 넣는다. 질문 번호 형식(R1·Q1·1)·1. ·질문 1·①)이 무엇이든 댓글에 적힌 그대로 id 에 쓴다.
- 「(추천)」 「추천」 「권장」 표시가 있는 선택지만 recommended=true.
- 선택지 없이 값을 적어 달라는 질문(버전·이름·날짜 등)은 free=true, options 는 비운다.
- item_format·separator 는 댓글이 예시로 준 답 형식(예: `R1-1, R2-1`)을 따른다. 예시가 없으면 {id}-{option} 과 , 를 쓴다."""

QID_PATTERNS = [   # 댓글에서 질문 번호처럼 보이는 것 — Claude 결과에 빠진 번호가 없는지 대조용
    r"(?m)^\s*(?:[*_>#\s]*)([A-Za-z]{1,2}\d{1,2})\s*[.):]",   # R1. Q2) A3:
    r"(?m)^\s*(?:[*_>#\s]*)질문\s*(\d{1,2})",                 # 질문 1
]


def question_ids_in(text):
    """댓글에 보이는 질문 번호들 (형식별로 2개 이상일 때만 질문 목록으로 본다)"""
    found = []
    for pat in QID_PATTERNS:
        ids = [m.group(1) for m in re.finditer(pat, text or "")]
        if len(set(ids)) >= 2:
            found += ids
    return list(dict.fromkeys(found))


def norm_id(x):
    return re.sub(r"[^0-9a-z가-힣]", "", str(x).lower())


def id_letters(v):
    """질문 번호의 영문 머리(R·Q 등) — 숫자와 한글(「질문」)은 뺀다"""
    return re.sub(r"[\d가-힣]", "", v)


def same_id(a, b):
    """질문 번호가 같은지 — 「질문1」과 「1」처럼 표기가 달라도 숫자가 같으면 같은 질문.
    R·Q 같은 영문 머리가 양쪽에 다 있으면 그것도 같아야 한다"""
    na, nb = norm_id(a), norm_id(b)
    if na == nb:
        return True
    da, db = re.sub(r"\D", "", na), re.sub(r"\D", "", nb)
    la, lb = id_letters(na), id_letters(nb)
    return bool(da) and da == db and (not la or not lb or la == lb)


def first_json(text):
    """응답에서 첫 JSON 객체만 읽는다 (뒤에 덧붙은 글은 무시)"""
    i = text.find("{")
    if i < 0:
        raise ValueError("JSON 없음")
    return json.JSONDecoder().raw_decode(text[i:])[0]


def ask_questions(text, feedback=""):
    if not CLAUDE:
        raise RuntimeError("claude CLI 를 찾지 못함")
    env = dict(os.environ, AGENT_PET_INTERNAL="1")
    r = subprocess.run(
        [CLAUDE, "-p", "--model", SUGGEST_MODEL, "--tools", "", "--strict-mcp-config", "--setting-sources", "",
         "--no-session-persistence", "--system-prompt", QUESTIONS_PROMPT],
        input=f"댓글:\n{MENTION.sub(lambda m: m.group(1), text)[:9000]}" + (f"\n\n{feedback}" if feedback else ""),
        capture_output=True, text=True, timeout=SUGGEST_TIMEOUT * 2, cwd=PET, env=env)
    try:
        return first_json(r.stdout)
    except ValueError:
        raise RuntimeError(f"질문 응답 해석 실패: {(r.stderr or r.stdout).strip()[:150]}")


def parse_questions(st, comment):
    """여러 질문에 번호로 답해야 하는 댓글이면 질문 목록 — 아니면 None. 댓글 id별로 한 번만 읽는다.
    Claude 가 읽은 질문 번호를 댓글에서 따로 찾은 번호와 대조해, 하나라도 빠지면 다시 읽히고 그래도 빠지면 None"""
    cache = st.setdefault("questions", {})
    cid = comment.get("id")
    if cid in cache:
        return cache[cid] or None
    text = comment.get("content") or ""
    result = None
    try:
        seen = question_ids_in(text)
        try:
            data = ask_questions(text)
        except (RuntimeError, subprocess.TimeoutExpired):
            data = ask_questions(text)   # 한 번 더
        for attempt in range(2):
            qs = [q for q in data.get("questions") or [] if q.get("id")]
            missing = [x for x in seen if not any(same_id(x, q["id"]) for q in qs)]
            bad = [q["id"] for q in qs if not q.get("free") and not q.get("options")]
            if data.get("multi") and len(qs) >= 2 and not missing and not bad:
                fmt = data.get("item_format") or "{id}-{option}"
                if "{id}" not in fmt or "{option}" not in fmt:
                    fmt = "{id}-{option}"
                fmt = re.sub(r"^[A-Za-z가-힣]+\{id\}", "{id}", fmt)   # 질문 번호에 이미 머리글자가 있으니 겹치지 않게 (R{id} → {id})
                result = {"questions": [{"id": str(q["id"]), "title": str(q.get("title", ""))[:80],
                                         "free": bool(q.get("free")),
                                         "options": [{"no": str(o.get("no")), "label": str(o.get("label", ""))[:60],
                                                      "recommended": bool(o.get("recommended"))}
                                                     for o in (q.get("options") or []) if o.get("no") is not None]}
                                        for q in qs],
                          "item_format": fmt, "separator": data.get("separator") or ", "}
                break
            if not data.get("multi") and not seen:
                break   # 질문이 하나뿐인 댓글
            if attempt == 0:   # 빠진 번호를 알려 주고 한 번 더
                data = ask_questions(text, "이전 결과에서 빠지거나 선택지가 없는 질문: "
                                     + ", ".join(missing + bad) + " — 모든 질문을 빠짐없이 다시 출력하라.")
        if result is None and seen:
            result = {"incomplete": True, "count": len(seen)}   # 질문은 여럿인데 다 못 읽음 → 직접 답하라고 안내
    except Exception as e:
        with open(os.path.join(PET, "watch.err"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%m-%d %H:%M:%S')} questions {e}\n")
    cache[cid] = result or {}
    return result


def build_answer(info, answers):
    """질문별 답 → 댓글 문장. 모든 질문 번호가 정확히 한 번씩 채워졌을 때만 (아니면 None)"""
    qs = info.get("questions") or []
    if not qs or any(not str(answers.get(q["id"], "")).strip() for q in qs):
        return None
    fmt, sep = info.get("item_format") or "{id}-{option}", info.get("separator") or ", "
    parts = []
    for q in qs:
        a = str(answers[q["id"]]).strip()
        parts.append(f"{q['id']}: {a}" if q.get("free") else fmt.replace("{id}", q["id"]).replace("{option}", a))
    return sep.join(parts)


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
            detail = plain("\n".join(text.strip().split("\n")[1:])) if (kind == "ask" or calling) else plain(text)
            qs = parse_questions(st, lastc) if lastc else None
            pairs = [] if (qs and qs.get("questions")) else answers_of(text, st.get("agents", []))
            if qs and qs.get("incomplete"):   # 질문은 여럿인데 다 못 읽음 — 틀린 답을 보내지 않게 버튼 없이
                detail = plain(f"질문 {qs['count']}개 — Multica에서 직접 답해 주세요. · {detail}", 200)
            elif not pairs and lastc and not qs:   # 답 형식을 정해 주지 않은 질문 → Claude 추천 답장
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
        multi = qs if (kind in ("ask", "human") and qs and qs.get("questions")) else None
        write_req(rid, {
            **({"questions": multi["questions"]} if multi else {}),
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
                                          "replies": [p[1] for p in pairs], "full": full,
                                          **(multi or {})}
    live = {r.get("parent") for r in st.get("reqs", {}).values()}
    st["suggest"] = {k: v for k, v in st.get("suggest", {}).items() if k in live}
    st["questions"] = {k: v for k, v in st.get("questions", {}).items() if k in live}
    # 더는 해당 안 되는 요청은 말풍선에서 내림
    for f in os.listdir(REQ) if os.path.isdir(REQ) else []:
        rid = f[:-5]
        if f.endswith(".json") and not rid.startswith("demo") and rid not in keep and is_multica_req(f):
            notice_log(f"지움 {rid} [multica] 더는 사람 차례가 아님 (Multica 감시)")
            remove(os.path.join(REQ, f))
            st.get("reqs", {}).pop(rid, None)
            notified.pop(rid, None)
    save_state(st)


def notice_log(msg):
    """앱과 같은 알림 기록(notice.log)에 한 줄 — 알림이 왜 사라졌는지 추적용"""
    path = os.path.join(PET, "notice.log")
    try:
        lines = open(path, encoding="utf-8").read().splitlines()[-499:] if os.path.exists(path) else []
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines + [f"{time.strftime('%m-%d %H:%M:%S')} {msg}"]) + "\n")
    except OSError:
        pass


def is_multica_req(name):
    """Multica 가 쓴 알림인지 — 정리는 자기 알림만 (Claude·Codex·Orca·펫 안내는 건드리지 않는다)"""
    try:
        with open(os.path.join(REQ, name), encoding="utf-8") as fh:
            return json.load(fh).get("source") == "multica"
    except (OSError, ValueError):
        return False


def notice(rid, headline, detail):
    """펫 자체 안내 말풍선 (잠깐 보였다 사라짐)"""
    write_req(f"pet-info-{rid}", {"source": "pet", "tag": "Multica", "headline": headline, "detail": detail,
                                  "options": [], "ids": [], "expires_at": time.time() + 20})


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
        content = None
        if info and d.startswith("multi:"):   # 질문 모드 — 모든 질문 번호가 채워졌을 때만 보낸다
            try:
                content = build_answer(info, json.loads(d[len("multi:"):]))
            except ValueError:
                content = None
            if content is None:
                notice(rid, "답이 빠진 질문이 있어 보내지 않았어요", "말풍선에서 모든 질문에 답한 뒤 다시 보내 주세요.")
                remove(work)
                continue
        elif info and d.startswith("reply:"):
            replies = info.get("replies") or REPLIES.get(info["kind"], [])
            i = int(d.split(":")[1])
            content = replies[i] if i < len(replies) else None
        if content:
            args = ["issue", "comment", "add", info["issue"], "--content", content]
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
