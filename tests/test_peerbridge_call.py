import importlib.machinery
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("pbcall", str(ROOT / "bin" / "peerbridge-call"))
spec = importlib.util.spec_from_loader("pbcall", loader)
pbcall = importlib.util.module_from_spec(spec)
loader.exec_module(pbcall)

BAD_ORDER = {"price_cents": 4999, "currency": "usd", "items": [{"sku": "mug", "quantity": 1}]}
GOOD_ORDER = {"amount_cents": 4999, "currency": "usd", "items": [{"sku": "mug", "quantity": 1}]}


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class WrapperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.log = Path(cls.tmp.name) / "access.log"
        cls.port = free_port()
        env = dict(os.environ, PEERBRIDGE_ACCESS_LOG=str(cls.log))
        cls.server = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "app:app", "--host", "127.0.0.1",
             "--port", str(cls.port), "--no-access-log", "--log-level", "warning"],
            cwd=ROOT / "sample" / "backend", env=env,
        )
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", cls.port), 0.1).close()
                break
            except OSError:
                time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(5)
        cls.tmp.cleanup()

    def setUp(self):
        self.state = tempfile.TemporaryDirectory()
        os.environ.update(
            PEERBRIDGE_BACKEND_PORT=str(self.port),
            PEERBRIDGE_ACCESS_LOG=str(self.log),
            PEERBRIDGE_ROUTES=str(ROOT / "peerbridge.routes"),
            PEERBRIDGE_STATE_DIR=self.state.name,
        )

    def tearDown(self):
        self.state.cleanup()

    def call(self, request, *args):
        return pbcall.run(list(args), io.StringIO(json.dumps(request)))

    def log_lines(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_real_422_with_log_line(self):
        code, out = self.call({"method": "POST", "path": "/v2/checkout", "body": BAD_ORDER})
        self.assertEqual(code, 0)
        self.assertIn("POST /v2/checkout -> 422", out)
        self.assertIn("amount_cents", out)
        self.assertRegex(out, r"access log: .*127\.0\.0\.1 POST /v2/checkout -> 422")

    def test_real_200(self):
        code, out = self.call({"method": "POST", "path": "/v2/checkout", "body": GOOD_ORDER})
        self.assertEqual(code, 0)
        self.assertIn("-> 200 OK", out)
        self.assertIn('"status": "accepted"', out)

    def assert_refused_without_request(self, request, reason):
        before = len(self.log_lines())
        code, out = self.call(request)
        self.assertEqual(code, 2, out)
        self.assertIn("REFUSED", out)
        self.assertIn(reason, out)
        time.sleep(0.2)
        self.assertEqual(len(self.log_lines()), before)

    def test_refuses_route_not_in_allowlist(self):
        self.assert_refused_without_request({"method": "DELETE", "path": "/users"}, "allowlist")

    def test_refuses_other_method_on_allowed_path(self):
        self.assert_refused_without_request({"method": "GET", "path": "/v2/checkout"}, "allowlist")

    def test_refuses_host_field(self):
        self.assert_refused_without_request(
            {"method": "POST", "path": "/v2/checkout", "host": "10.0.0.5"}, "only go to 127.0.0.1")

    def test_refuses_absolute_url_in_path(self):
        self.assert_refused_without_request(
            {"method": "GET", "path": "//evil.example/health"}, "plain path")
        self.assert_refused_without_request(
            {"method": "GET", "path": "http://evil.example/health"}, "plain path")

    def test_refuses_traversal_and_encoding(self):
        self.assert_refused_without_request({"method": "GET", "path": "/v2/../health"}, "'..'")
        self.assert_refused_without_request({"method": "GET", "path": "/%68ealth"}, "encoded")

    def test_refuses_bad_json(self):
        code, out = pbcall.run([], io.StringIO("{not json"))
        self.assertEqual(code, 2)
        self.assertIn("valid JSON", out)

    def test_drops_auth_headers(self):
        code, out = self.call({"method": "GET", "path": "/health",
                               "headers": {"Authorization": "Bearer x", "X-Trace": "1"}})
        self.assertEqual(code, 0)
        self.assertIn("dropped headers: Authorization", out)
        self.assertNotIn("Bearer", out)

    def test_same_message_id_sends_once(self):
        req = {"method": "POST", "path": "/v2/checkout", "body": BAD_ORDER}
        before = len(self.log_lines())
        first = self.call(req, "--message-id", "msg-1")
        second = self.call(req, "--message-id", "msg-1")
        time.sleep(0.2)
        self.assertEqual(len(self.log_lines()), before + 1)
        self.assertIn("not sent again", second[1])
        self.assertTrue(second[1].startswith(first[1]))

    def test_rerun_sends_again_and_refreshes_result(self):
        req = {"method": "POST", "path": "/v2/checkout", "body": BAD_ORDER}
        before = len(self.log_lines())
        self.call(req, "--message-id", "msg-fix")
        code, out = self.call(req, "--message-id", "msg-fix", "--rerun")
        time.sleep(0.2)
        self.assertEqual(code, 0)
        self.assertNotIn("not sent again", out)
        self.assertEqual(len(self.log_lines()), before + 2)
        replay = self.call(req, "--message-id", "msg-fix")[1]
        self.assertTrue(replay.startswith(out))

    def test_output_names_message_id(self):
        code, out = self.call({"method": "GET", "path": "/health"}, "--message-id", "sw_abc")
        self.assertIn("[re: sw_abc]", out.splitlines()[0])
        code, out = self.call({"method": "DELETE", "path": "/users"}, "--message-id", "sw_def")
        self.assertEqual(code, 2)
        self.assertIn("[re: sw_def]", out)

    def test_defaults_resolve_from_repo_not_cwd(self):
        for key in ("PEERBRIDGE_ROUTES", "PEERBRIDGE_STATE_DIR", "PEERBRIDGE_ACCESS_LOG"):
            os.environ.pop(key)
        cwd = os.getcwd()
        os.chdir(tempfile.gettempdir())
        try:
            code, out = self.call({"method": "GET", "path": "/health"})
        finally:
            os.chdir(cwd)
        self.assertEqual(code, 0, out)

    def test_config_file_overrides_environment(self):
        cfg = ROOT / "peerbridge.env"
        self.assertFalse(cfg.exists(), "remove a stray peerbridge.env before testing")
        restrictive = Path(self.state.name) / "routes"
        restrictive.write_text("GET /health\n")
        cfg.write_text(f"PEERBRIDGE_ROUTES={restrictive}\n")
        try:
            os.environ["PEERBRIDGE_ROUTES"] = str(ROOT / "peerbridge.routes")
            code, out = self.call({"method": "POST", "path": "/v2/checkout", "body": GOOD_ORDER})
        finally:
            cfg.unlink()
        self.assertEqual(code, 2)
        self.assertIn("allowlist", out)

    def test_unreachable_backend(self):
        os.environ["PEERBRIDGE_BACKEND_PORT"] = str(free_port())
        code, out = self.call({"method": "GET", "path": "/health"})
        self.assertEqual(code, 3)
        self.assertIn("unreachable", out)

    def test_body_truncated_to_2kb(self):
        text = pbcall.format_body(b"x" * 5000)
        self.assertLessEqual(len(text.split("\n...")[0].encode()), 2048)
        self.assertIn("truncated", text)


if __name__ == "__main__":
    unittest.main()
