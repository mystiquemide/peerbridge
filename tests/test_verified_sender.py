"""Verified mode: the wrapper looks the request up in Switch and checks its sender."""

import datetime
import http.server
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

try:
    from tests.test_peerbridge_call import BAD_ORDER, ROOT, free_port, pbcall
except ImportError:
    from test_peerbridge_call import BAD_ORDER, ROOT, free_port, pbcall

ROOM, ME, FRONTEND = "room-1", "agent-backend", "agent-frontend"


def now(minutes_ago=0):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes_ago)
    return t.isoformat().replace("+00:00", "Z")


def block(request):
    return "```json\n" + json.dumps(request) + "\n```"


def message(mid, kind="agent", agent_id=FRONTEND, named=(ME,), minutes_ago=0, body=None, replies=0):
    return {
        "messageId": mid,
        "sender": {"kind": kind, "name": f"{kind}-{mid}", "agentId": agent_id if kind == "agent" else None},
        "namedAgentIds": list(named),
        "mentions": [],
        "sentAt": now(minutes_ago),
        "body": body if body is not None else "@backend-agent run this\n" + block(
            {"method": "POST", "path": "/v2/checkout", "body": BAD_ORDER}),
        "threadReplyCount": replies,
    }


ROOTS = [
    message("m-agent"),
    message("m-sam", kind="human"),
    message("m-self", agent_id=ME),
    message("m-unaddressed", named=()),
    message("m-stale", minutes_ago=60),
    message("m-nojson", body="@backend-agent hello"),
    message("m-delete", body="@backend-agent\n" + block({"method": "DELETE", "path": "/users"})),
    message("m-root", kind="human", replies=1),
]
THREAD = {"m-root": [message("m-reply")]}


class FakeSwitch(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, payload, cookie=False):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        if cookie:
            self.send_header("Set-Cookie", "session=ok; Path=/")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/gateway/auth/login" and body.get("password") == "pw":
            return self._send(200, {"id": "verifier"}, cookie=True)
        self._send(401, {"detail": "bad login"})

    def do_GET(self):
        if "session=ok" not in (self.headers.get("Cookie") or ""):
            return self._send(401, {"detail": "no session"})
        prefix = f"/gateway/chats/{ROOM}/"
        path = self.path.split("?")[0]
        if path == prefix + "messages":
            return self._send(200, {"messages": ROOTS})
        if path.startswith(prefix + "threads/"):
            root = path[len(prefix + "threads/"):].split("/")[0]
            return self._send(200, {"messages": THREAD.get(root, [])})
        self._send(404, {"detail": "not found"})


class VerifiedSenderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.log = Path(cls.tmp.name) / "access.log"
        cls.port = free_port()
        env = dict(os.environ, PEERBRIDGE_ACCESS_LOG=str(cls.log))
        cls.server = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "app:app", "--host", "127.0.0.1",
             "--port", str(cls.port), "--no-access-log", "--log-level", "warning"],
            cwd=ROOT / "sample" / "backend", env=env)
        cls.switch = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeSwitch)
        threading.Thread(target=cls.switch.serve_forever, daemon=True).start()
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", cls.port), 0.1).close()
                break
            except OSError:
                time.sleep(0.05)
        cls.pw = Path(cls.tmp.name) / "verifier.password"
        cls.pw.write_text("pw\n")

    @classmethod
    def tearDownClass(cls):
        cls.switch.shutdown()
        cls.server.terminate()
        cls.server.wait(5)
        cls.tmp.cleanup()

    def setUp(self):
        self.state = tempfile.TemporaryDirectory()
        self.env = {
            "PEERBRIDGE_BACKEND_PORT": str(self.port),
            "PEERBRIDGE_ACCESS_LOG": str(self.log),
            "PEERBRIDGE_ROUTES": str(ROOT / "peerbridge.routes"),
            "PEERBRIDGE_STATE_DIR": self.state.name,
            "PEERBRIDGE_SWITCH_URL": f"http://127.0.0.1:{self.switch.server_address[1]}",
            "PEERBRIDGE_ROOM_ID": ROOM,
            "PEERBRIDGE_AGENT_ID": ME,
            "PEERBRIDGE_VERIFIER_EMAIL": "verifier@test",
            "PEERBRIDGE_VERIFIER_PASSWORD_FILE": str(self.pw),
        }
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.state.cleanup()

    def lines(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def call(self, *args, stdin="{}"):
        return pbcall.run(list(args), io.StringIO(stdin))

    def refused(self, mid, reason):
        before = len(self.lines())
        code, out = self.call("--message-id", mid)
        time.sleep(0.2)
        self.assertEqual(code, 2, out)
        self.assertIn(reason, out)
        self.assertEqual(len(self.lines()), before, "a refused request reached the backend")

    def test_agent_message_runs_its_own_request(self):
        code, out = self.call("--message-id", "m-agent")
        self.assertEqual(code, 0, out)
        self.assertIn("POST /v2/checkout -> 422", out)
        self.assertIn("verified: sent by agent-m-agent (agent)", out)

    def test_payload_comes_from_the_message_not_the_agent(self):
        forged = json.dumps({"method": "GET", "path": "/health"})
        code, out = self.call("--message-id", "m-agent", stdin=forged)
        self.assertEqual(code, 0, out)
        self.assertIn("POST /v2/checkout", out)
        self.assertNotIn("GET /health", out)

    def test_reply_in_a_thread_is_found(self):
        code, out = self.call("--message-id", "m-reply")
        self.assertEqual(code, 0, out)
        self.assertIn("-> 422", out)

    def test_person_is_refused(self):
        self.refused("m-sam", "a person")

    def test_backend_agent_itself_is_refused(self):
        self.refused("m-self", "backend-agent itself")

    def test_message_that_doesnt_mention_backend_agent_is_refused(self):
        self.refused("m-unaddressed", "doesn't mention backend-agent")

    def test_stale_message_is_refused(self):
        self.refused("m-stale", "minutes old")

    def test_unknown_message_is_refused(self):
        self.refused("m-nope", "isn't among this room's recent messages")

    def test_message_without_json_is_refused(self):
        self.refused("m-nojson", "no JSON request block")

    def test_allowlist_still_applies(self):
        self.refused("m-delete", "isn't in the route allowlist")

    def test_message_id_is_required(self):
        code, out = self.call()
        self.assertEqual(code, 2)
        self.assertIn("--message-id is required", out)

    def test_bad_verifier_login_is_refused(self):
        bad = Path(self.state.name) / "bad.password"
        bad.write_text("wrong")
        os.environ["PEERBRIDGE_VERIFIER_PASSWORD_FILE"] = str(bad)
        self.refused("m-agent", "couldn't sign in")

    def test_switch_down_is_reported(self):
        os.environ["PEERBRIDGE_SWITCH_URL"] = f"http://127.0.0.1:{free_port()}"
        code, out = self.call("--message-id", "m-agent")
        self.assertEqual(code, 3)
        self.assertIn("Couldn't verify the sender", out)


if __name__ == "__main__":
    unittest.main()
