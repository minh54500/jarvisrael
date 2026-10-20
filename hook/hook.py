#!/usr/bin/env python3
"""Relais entre Claude Code et l'app Encoche.

Claude Code lance ce script à chaque événement (hook) et lui passe un JSON sur stdin.
- PermissionRequest : on attend la décision prise dans l'encoche (jusqu'à 118 s).
- Les autres événements : envoi sans attendre (0,3 s max), Claude n'est jamais bloqué.
Si l'app ne tourne pas, le script ne dit rien et Claude Code se comporte normalement.

  hook.py --install    branche Encoche dans ~/.claude/settings.json (avec sauvegarde)
  hook.py --uninstall  le débranche
  hook.py --status     dit s'il est branché
"""
import json
import os
import socket
import sys
import time

SOCKET = os.path.expanduser("~/Library/Application Support/Encoche/encoche.sock")
SETTINGS = os.path.expanduser("~/.claude/settings.json")
EVENTS = {  # événement -> délai max accordé par Claude Code (s)
    "SessionStart": 10, "UserPromptSubmit": 10, "PreToolUse": 10, "PostToolUse": 10,
    "PostToolUseFailure": 10, "PermissionRequest": 120, "Notification": 10,
    "Stop": 10, "StopFailure": 10, "SessionEnd": 10,
}


def command():
    return f"/usr/bin/python3 '{os.path.abspath(__file__)}'"


def is_ours(hook):
    return "Encoche/hook.py" in hook.get("command", "")


def load_settings():
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS) as f:
        return json.load(f)


def save_settings(data):
    if os.path.exists(SETTINGS):
        backup = f"{SETTINGS}.avant-encoche-{time.strftime('%Y%m%d-%H%M%S')}"
        with open(SETTINGS) as src, open(backup, "w") as dst:
            dst.write(src.read())
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(SETTINGS, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def uninstall(data):
    hooks = data.get("hooks", {})
    for event in list(hooks):
        groups = []
        for group in hooks[event]:
            group["hooks"] = [h for h in group.get("hooks", []) if not is_ours(h)]
            if group["hooks"]:
                groups.append(group)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    if not hooks:
        data.pop("hooks", None)
    return data


def installed(data):
    return any(is_ours(h) for groups in data.get("hooks", {}).values() for g in groups for h in g.get("hooks", []))


def manage(flag):
    data = load_settings()
    if flag == "--status":
        print("branché" if installed(data) else "débranché")
        return
    data = uninstall(data)
    if flag == "--install":
        hooks = data.setdefault("hooks", {})
        for event, timeout in EVENTS.items():
            hooks.setdefault(event, []).append(
                {"matcher": "", "hooks": [{"type": "command", "command": command(), "timeout": timeout}]})
    save_settings(data)
    print("branché" if flag == "--install" else "débranché")


def send(payload, wait):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(wait)
    s.connect(SOCKET)
    s.sendall((json.dumps(payload) + "\n").encode())
    if wait < 1:
        s.close()
        return None
    chunks = []
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            break
    s.close()
    text = b"".join(chunks).decode().strip()
    return json.loads(text) if text else None


def relay():
    try:
        payload = json.loads(sys.stdin.buffer.read() or b"{}")
    except Exception:
        return
    env = os.environ
    payload.setdefault("term_program", env.get("TERM_PROGRAM", ""))
    payload.setdefault("bundle_id", env.get("__CFBundleIdentifier", ""))
    payload.setdefault("entrypoint", env.get("CLAUDE_CODE_ENTRYPOINT", ""))  # "claude-vscode" = extension VS Code
    payload.setdefault("cwd", os.getcwd())
    event = payload.get("hook_event_name", "")

    if event != "PermissionRequest":
        try:
            send(payload, 0.3)
        except Exception:
            pass
        return

    try:
        answer = send(payload, 118) or {}
    except Exception:
        return  # app absente ou délai dépassé : Claude Code demande dans le terminal
    decision = answer.get("permissionDecision")
    if decision == "allow":
        out = {"behavior": "allow"}
    elif decision == "always":
        out = {"behavior": "allow", "updatedPermissions": payload.get("permission_suggestions", [])}
    elif decision == "deny":
        out = {"behavior": "deny", "message": "Refusé depuis l'encoche"}
    else:
        return
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": out}}))


if __name__ == "__main__":
    flag = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if flag in ("--install", "--uninstall", "--status"):
            manage(flag)
        else:
            relay()
    except Exception as e:
        if flag:
            print(f"erreur : {e}", file=sys.stderr)
            sys.exit(1)
    sys.exit(0)
