#!/usr/bin/env python3
"""AgentPet 연동 설정 — Claude Code 훅 · Codex notify · 펫 캐릭터 스킬을 넣고 뺀다.

  setup_integrations.py install    <앱 안 sources 폴더> <스킬 폴더>
  setup_integrations.py uninstall

고치는 파일은 처음 한 번 *.bak-agentpet 으로 백업한다. 기존 훅·설정은 건드리지 않고 AgentPet 것만 넣고 뺀다.
"""
import json
import os
import re
import shutil
import sys

HOME = os.path.expanduser("~")
CLAUDE_SETTINGS = os.path.join(HOME, ".claude", "settings.json")
CODEX_CONFIG = os.path.join(HOME, ".codex", "config.toml")
SKILL_DST = os.path.join(HOME, ".claude", "skills", "pet-character")
MARK = "claude_hook.py"   # 우리 훅을 알아보는 표시


def backup(path):
    bak = path + ".bak-agentpet"
    if os.path.exists(path) and not os.path.exists(bak):
        shutil.copy2(path, bak)


def write_atomic(path, text):
    tmp = path + ".tmp-agentpet"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


# =============================================================================
# Claude Code 훅
# =============================================================================

def claude_install(src):
    hook = f"/usr/bin/python3 -I {src}/claude_hook.py"
    add = {
        "Stop": [{"hooks": [{"type": "command", "command": hook + " stop", "async": True, "timeout": 10}]}],
        "Notification": [{"hooks": [{"type": "command", "command": hook + " notify", "async": True, "timeout": 10}]}],
        "UserPromptSubmit": [{"hooks": [{"type": "command", "command": hook + " clear", "async": True, "timeout": 10}]}],
        "PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": hook + " permission", "timeout": 120}]}],
    }
    os.makedirs(os.path.dirname(CLAUDE_SETTINGS), exist_ok=True)
    s = {}
    if os.path.exists(CLAUDE_SETTINGS):
        backup(CLAUDE_SETTINGS)
        with open(CLAUDE_SETTINGS, encoding="utf-8") as f:
            s = json.load(f)
    hooks = s.setdefault("hooks", {})
    for ev, groups in add.items():
        cur = hooks.setdefault(ev, [])
        if any(MARK in c.get("command", "") for g in cur for c in g.get("hooks", [])):
            continue   # 이미 있음 (다시 설치해도 중복되지 않게)
        cur.extend(groups)
    write_atomic(CLAUDE_SETTINGS, json.dumps(s, indent=2, ensure_ascii=False) + "\n")
    print(f"  Claude Code 훅 등록: {CLAUDE_SETTINGS}")


def claude_uninstall():
    if not os.path.exists(CLAUDE_SETTINGS):
        return
    with open(CLAUDE_SETTINGS, encoding="utf-8") as f:
        s = json.load(f)
    hooks = s.get("hooks") or {}
    for ev in list(hooks):
        groups = []
        for g in hooks[ev]:
            g["hooks"] = [c for c in g.get("hooks", []) if MARK not in c.get("command", "")]
            if g["hooks"]:
                groups.append(g)
        if groups:
            hooks[ev] = groups
        else:
            del hooks[ev]
    write_atomic(CLAUDE_SETTINGS, json.dumps(s, indent=2, ensure_ascii=False) + "\n")
    print(f"  Claude Code 훅 제거: {CLAUDE_SETTINGS}")


# =============================================================================
# Codex notify — 기존 notify 명령을 감싸 그대로 넘긴다
# =============================================================================

NOTIFY_RE = re.compile(r"^notify\s*=\s*\[(.*?)\][ \t]*$", re.M | re.S)


def toml_list(items):
    return "notify = [\n" + "".join(f"    {json.dumps(x, ensure_ascii=False)},\n" for x in items) + "]"


def codex_install(src):
    if not os.path.isdir(os.path.dirname(CODEX_CONFIG)):
        print("  Codex 없음 — 건너뜀")
        return
    text = open(CODEX_CONFIG, encoding="utf-8").read() if os.path.exists(CODEX_CONFIG) else ""
    if "codex_notify.py" in text:
        print("  Codex notify 이미 등록됨")
        return
    backup(CODEX_CONFIG)
    wrapper = ["/usr/bin/python3", "-I", f"{src}/codex_notify.py", "--"]
    m = NOTIFY_RE.search(text)
    if m:   # 기존 notify 는 -- 뒤로 넘겨 계속 불리게
        orig = json.loads("[" + re.sub(r",\s*$", "", m.group(1).strip()) + "]")
        text = text[:m.start()] + toml_list(wrapper + orig) + text[m.end():]
    else:   # notify 는 최상위 키 — 첫 [테이블] 앞에 넣는다
        text = toml_list(wrapper) + "\n" + text
    write_atomic(CODEX_CONFIG, text)
    print(f"  Codex notify 등록: {CODEX_CONFIG}")


def codex_uninstall():
    if not os.path.exists(CODEX_CONFIG):
        return
    text = open(CODEX_CONFIG, encoding="utf-8").read()
    m = NOTIFY_RE.search(text)
    if not m or "codex_notify.py" not in m.group(0):
        return
    items = json.loads("[" + re.sub(r",\s*$", "", m.group(1).strip()) + "]")
    orig = items[items.index("--") + 1:] if "--" in items else []
    new = toml_list(orig) if orig else ""
    text = text[:m.start()] + new + text[m.end():]
    write_atomic(CODEX_CONFIG, text.lstrip("\n") if not new else text)
    print(f"  Codex notify 원래대로: {CODEX_CONFIG}")


# =============================================================================
# 펫 캐릭터 스킬
# =============================================================================

def skill_install(skill_src):
    os.makedirs(SKILL_DST, exist_ok=True)
    shutil.copy2(os.path.join(skill_src, "SKILL.md"), os.path.join(SKILL_DST, "SKILL.md"))
    print(f"  Claude Code 스킬 설치: {SKILL_DST}")


def skill_uninstall():
    if os.path.isdir(SKILL_DST):
        shutil.rmtree(SKILL_DST)
        print(f"  Claude Code 스킬 제거: {SKILL_DST}")


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "install":
        claude_install(sys.argv[2])
        codex_install(sys.argv[2])
        skill_install(sys.argv[3])
    elif len(sys.argv) >= 2 and sys.argv[1] == "uninstall":
        claude_uninstall()
        codex_uninstall()
        skill_uninstall()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
