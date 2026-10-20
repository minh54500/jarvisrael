"""Tests du relais hook.py (entre Claude Code et l'app), sans toucher à tes vrais réglages ni à l'app.

    python3 tests/test_hook.py

Un faux serveur joue le rôle de l'app sur un socket temporaire ; un settings.json temporaire remplace le tien.
"""
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest

import shutil

SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hook", "hook.py")
# Le relais reconnaît ses hooks à leur chemin « …/Encoche/hook.py » : on le teste depuis un dossier Encoche,
# comme dans la vraie installation (~/Library/Application Support/Encoche/hook.py).
HOOK = os.path.join(tempfile.mkdtemp(), "Encoche", "hook.py")
os.makedirs(os.path.dirname(HOOK))
shutil.copy(SOURCE, HOOK)


class FakeApp:
    """Accepte une connexion, garde ce que le relais envoie, et répond `reply` (ou ferme sans répondre)."""

    def __init__(self, path, reply=None):
        self.path, self.reply, self.received = path, reply, []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(4)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        self.server.settimeout(5)
        try:
            conn, _ = self.server.accept()
        except OSError:
            return
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        self.received.append(json.loads(data.decode()))
        if self.reply is not None:
            conn.sendall((json.dumps(self.reply) + "\n").encode())
        conn.close()

    def close(self):
        self.server.close()


class HookTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.sock = os.path.join(self.dir, "e.sock")
        self.settings = os.path.join(self.dir, "settings.json")
        self.env = dict(os.environ, ENCOCHE_SOCKET=self.sock, ENCOCHE_SETTINGS=self.settings)
        self.env.pop("ENCOCHE_INTERNAL", None)

    def run_hook(self, payload, *args, env=None, timeout=10):
        p = subprocess.run(["/usr/bin/python3", HOOK, *args], input=json.dumps(payload) if payload is not None else "",
                           capture_output=True, text=True, env=env or self.env, timeout=timeout)
        return p.stdout.strip()

    def output(self, payload, reply):
        app = FakeApp(self.sock, reply)
        out = self.run_hook(payload)
        app.thread.join(2)
        app.close()
        return (json.loads(out) if out else None), app.received

    # Événements simples : envoyés tels quels, sans rien répondre à Claude Code.

    def test_simple_event_is_relayed(self):
        out, got = self.output({"hook_event_name": "Stop", "session_id": "s"}, None)
        self.assertIsNone(out)
        self.assertEqual(got[0]["hook_event_name"], "Stop")
        self.assertIn("cwd", got[0])

    def test_app_absent_says_nothing_and_is_quick(self):
        start = time.time()
        out = self.run_hook({"hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {}})
        self.assertEqual(out, "")
        self.assertLess(time.time() - start, 3)

    def test_internal_requests_are_ignored(self):
        app = FakeApp(self.sock, None)
        out = self.run_hook({"hook_event_name": "Stop"}, env=dict(self.env, ENCOCHE_INTERNAL="1"))
        app.thread.join(0.5)
        app.close()
        self.assertEqual(out, "")
        self.assertEqual(app.received, [])

    # Autorisations.

    def test_permission_allow(self):
        out, _ = self.output({"hook_event_name": "PermissionRequest", "tool_name": "Bash"}, {"permissionDecision": "allow"})
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "allow"})

    def test_permission_always_keeps_suggestions(self):
        sugg = [{"type": "addRules", "rules": [{"toolName": "Bash"}]}]
        out, _ = self.output({"hook_event_name": "PermissionRequest", "permission_suggestions": sugg}, {"permissionDecision": "always"})
        self.assertEqual(out["hookSpecificOutput"]["decision"]["updatedPermissions"], sugg)

    def test_permission_deny_with_message(self):
        out, _ = self.output({"hook_event_name": "PermissionRequest"}, {"permissionDecision": "deny", "message": "non"})
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "deny", "message": "non"})

    def test_permission_without_answer_lets_claude_code_ask(self):
        out, _ = self.output({"hook_event_name": "PermissionRequest"}, {})
        self.assertIsNone(out)

    # Questions et plan de Claude (PreToolUse bloquant).

    QUESTION = {"questions": [{"question": "Quel framework ?", "header": "F", "options": [{"label": "React"}], "multiSelect": False}]}

    def test_question_answered(self):
        answer = dict(self.QUESTION, answers={"Quel framework ?": "React"})
        out, _ = self.output({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": self.QUESTION},
                             {"permissionDecision": "allow", "updatedInput": answer})
        o = out["hookSpecificOutput"]
        self.assertEqual((o["hookEventName"], o["permissionDecision"]), ("PreToolUse", "allow"))
        self.assertEqual(o["updatedInput"]["answers"], {"Quel framework ?": "React"})

    def test_question_allow_without_input_is_not_sent(self):
        # « allow » seul ne suffit pas pour ces outils (doc des hooks) : on laisse Claude Code demander.
        out, _ = self.output({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": self.QUESTION},
                             {"permissionDecision": "allow"})
        self.assertIsNone(out)

    def test_plan_changes_requested(self):
        out, _ = self.output({"hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "tool_input": {"plan": "x"}},
                             {"permissionDecision": "deny", "message": "ajoute des tests"})
        o = out["hookSpecificOutput"]
        self.assertEqual((o["permissionDecision"], o["permissionDecisionReason"]), ("deny", "ajoute des tests"))

    def test_question_closed_without_answer(self):
        out, _ = self.output({"hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "tool_input": {}}, None)
        self.assertIsNone(out)

    def test_other_tools_do_not_wait(self):
        start = time.time()
        out, _ = self.output({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {}}, None)
        self.assertIsNone(out)
        self.assertLess(time.time() - start, 3)

    # Brancher / débrancher dans settings.json.

    def manage(self, flag):
        return subprocess.run(["/usr/bin/python3", HOOK, flag], capture_output=True, text=True, env=self.env).stdout.strip()

    def test_install_status_uninstall(self):
        with open(self.settings, "w") as f:
            json.dump({"model": "opus", "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "autre"}]}]}}, f)
        self.assertEqual(self.manage("--status"), "débranché")
        self.manage("--install")
        self.assertEqual(self.manage("--status"), "branché")
        data = json.load(open(self.settings))
        self.assertEqual(data["model"], "opus")  # le reste des réglages est gardé
        self.assertTrue(any(h["command"] == "autre" for g in data["hooks"]["Stop"] for h in g["hooks"]))
        self.manage("--uninstall")
        data = json.load(open(self.settings))
        self.assertEqual(self.manage("--status"), "débranché")
        self.assertEqual([h["command"] for g in data["hooks"]["Stop"] for h in g["hooks"]], ["autre"])

    def test_old_install_is_incomplete(self):
        self.manage("--install")
        data = json.load(open(self.settings))
        del data["hooks"]["SubagentStart"]
        json.dump(data, open(self.settings, "w"))
        self.assertEqual(self.manage("--status"), "incomplet")

    def test_model_setting(self):
        self.manage("--install")
        subprocess.run(["/usr/bin/python3", HOOK, "--model", "claude-sonnet-5-5"], env=self.env, capture_output=True)
        self.assertEqual(self.manage("--get-model"), "claude-sonnet-5-5")
        subprocess.run(["/usr/bin/python3", HOOK, "--model", "default"], env=self.env, capture_output=True)
        self.assertEqual(self.manage("--get-model"), "")


if __name__ == "__main__":
    unittest.main(verbosity=1)
