#!/usr/bin/env python3
"""Orca 세션 추천 답장 — 훅이 말풍선을 띄운 뒤 백그라운드로 불러, 이어서 보낼 답 2~3개를 버튼으로 붙인다.

  orca_suggest.py <요청 파일 경로>

훅의 제한 시간(10초)에 걸리지 않게 훅과 떨어진 프로세스로 돈다. 요청 파일에서 에이전트의 마지막 답을 읽어
claude -p 로 답을 만들고, 그사이 말풍선이 그대로 있으면 options·ids·replies·primary 를 채운다.
버튼을 누르면 앱이 `orca terminal send --terminal <orca_handle> --text <답> --enter` 로 그 터미널에 보낸다.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

PET = os.environ.get("AGENT_PET_DIR") or os.path.expanduser("~/.agent-pet")
CLAUDE = shutil.which("claude", path=os.pathsep.join([os.environ.get("PATH", ""), os.path.expanduser("~/.local/bin"),
                                                     "/opt/homebrew/bin", "/usr/local/bin"]))
MODEL = os.environ.get("PET_SUGGEST_MODEL", "claude-sonnet-5-5")
PROMPT = """너는 개발자 대신 빠른 답장 버튼을 만든다. AI 코딩 에이전트(Claude Code 또는 Codex)가 방금 턴을 마치고
사용자의 다음 입력을 기다린다. 에이전트의 마지막 메시지를 읽고, 사용자가 버튼 하나로 바로 보낼 만한 답 2~3개를 만든다.

규칙
- 에이전트가 질문·선택지를 냈으면 그 선택지를 답으로. 작업을 끝냈다고 보고했으면 자연스러운 다음 지시
  (예: 검증·커밋·다음 단계 진행·수정 요청)를 답으로. 막연한 "좋아요" 보다 구체적인 행동을 담는다.
- 되돌리기 어려운 일(push·배포·삭제·운영 반영)을 추천(⭐)으로 고르지 않는다.
- 정확히 하나에 recommended=true. 가장 타당하고 안전한 답.
- label: 버튼 글자, 18자 이내 한국어. reply: 에이전트에게 보낼 문장, 한두 문장 존댓말 없이 간결한 지시형도 괜찮다.
- reason: 추천 이유 한 줄, 60자 이내.
- 출력은 JSON 하나만: {"options":[{"label":"","reply":"","recommended":true}],"reason":""}"""


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def ask(agent, message):
    if not CLAUDE:
        raise RuntimeError("claude CLI 를 찾지 못함")
    env = dict(os.environ, AGENT_PET_INTERNAL="1")   # 이 claude 실행이 다시 펫 훅을 부르지 않게
    r = subprocess.run(
        [CLAUDE, "-p", "--model", MODEL, "--tools", "", "--strict-mcp-config", "--setting-sources", "",
         "--no-session-persistence", "--system-prompt", PROMPT],
        input=f"에이전트: {agent}\n\n에이전트의 마지막 메시지:\n{message[:6000]}",
        capture_output=True, text=True, timeout=90, cwd=PET, env=env)
    m = re.search(r"\{.*\}", r.stdout, re.S)
    if not m:
        raise RuntimeError(f"추천 응답 해석 실패: {(r.stderr or r.stdout).strip()[:150]}")
    return json.loads(m.group(0))


def main(path):
    req = load(path)
    if not req or not req.get("orca_handle"):
        return
    stamp = req.get("stamp")
    message = req.get("full_md") or req.get("full") or req.get("detail") or ""
    if not message.strip():
        return
    data = ask(req.get("agent_name") or "에이전트", message)
    opts = [o for o in data.get("options", []) if o.get("label") and o.get("reply")][:3]
    opts.sort(key=lambda o: not o.get("recommended"))   # 추천을 맨 앞에
    if not opts:
        return
    cur = load(path)
    if not cur or cur.get("stamp") != stamp:   # 그사이 닫혔거나 새 알림으로 바뀌었으면 손대지 않는다
        return
    cur["options"] = [("⭐ " if o.get("recommended") else "") + o["label"][:18] for o in opts]
    cur["ids"] = [f"reply:{i}" for i in range(len(opts))]
    cur["replies"] = [o["reply"] for o in opts]
    cur["primary"] = 0 if opts[0].get("recommended") else None
    reason = (data.get("reason") or "").strip()
    if reason:
        cur["detail"] = f"⭐ 추천: {reason[:60]} · {cur.get('detail', '')}"[:220]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cur, f, ensure_ascii=False)
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except Exception as e:   # 추천이 안 돼도 말풍선은 그대로
        with open(os.path.join(PET, "watch.err"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%m-%d %H:%M:%S')} orca-suggest {e}\n")
