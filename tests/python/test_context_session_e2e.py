from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "python" / "openai_quota_fuse.py"


class State:
    requests: list[tuple[str, dict]] = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length).decode()) if length else {}

    def _send(self, payload: dict, status: int = 200) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        State.requests.append((path, {}))
        if path == "/v1/organization/usage/completions":
            self._send({"object": "page", "data": [{"object": "bucket", "results": []}], "has_more": False})
        else:
            self._send({"error": "unexpected GET"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._body()
        State.requests.append((path, body))
        if path == "/v1/responses/input_tokens":
            # Keep the mock strict enough to catch the original regression.
            self.assert_no_response_only_fields(body)
            self._send({"object": "response.input_tokens", "input_tokens": 7})
            return
        if path == "/v1/responses":
            text = "low" if "instructions" in body else "mock answer"
            self._send({
                "id": "resp_mock",
                "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}],
                "usage": {"input_tokens": 7, "output_tokens": 3, "total_tokens": 10},
            })
            return
        self._send({"error": "unexpected POST"}, 404)

    def assert_no_response_only_fields(self, body: dict) -> None:
        forbidden = {"max_output_tokens"}
        unknown = forbidden & set(body)
        if unknown:
            self._send({"error": {"message": f"Unknown parameter: {sorted(unknown)[0]}"}}, 400)
            raise RuntimeError("response-only field sent to input_tokens")


class ContextSessionE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}/v1"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=5)
        cls.server.server_close()

    def setUp(self):
        State.requests = []
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update({
            "OPENAI_ADMIN_KEY": "test-admin",
            "OPENAI_API_KEY": "test-api",
            "OPENAI_USAGE_TIER": "1",
            "OPENAI_QUOTA_RESERVE_PERCENT": "0",
            "OPENAI_QUOTA_FUSE_API_BASE": self.base,
            "OPENAI_QUOTA_FUSE_SESSION_DIR": str(Path(self.tmp.name) / "sessions"),
            "OPENAI_QUOTA_FUSE_PAID_LEDGER": str(Path(self.tmp.name) / "paid.json"),
        })
        return subprocess.run([sys.executable, str(CLI), *args], text=True, capture_output=True, cwd=ROOT, env=env)

    def token_count_requests(self) -> list[dict]:
        return [body for path, body in State.requests if path == "/v1/responses/input_tokens"]

    def inference_requests(self) -> list[dict]:
        return [body for path, body in State.requests if path == "/v1/responses" and "instructions" not in body]

    def test_classifier_omits_response_only_max_output_tokens_from_input_count(self):
        result = self.run_cli("run", "-o", "20", "富士山の高さは？")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("quality: auto -> low", result.stderr)
        self.assertTrue(self.token_count_requests())
        for body in self.token_count_requests():
            self.assertNotIn("max_output_tokens", body)

    def test_context_file_is_included_in_count_and_inference(self):
        context = Path(self.tmp.name) / "notes.txt"
        context.write_text("important context", encoding="utf-8")
        result = self.run_cli("run", "-q", "low", "-o", "20", "-c", str(context), "要約して")
        self.assertEqual(result.returncode, 0, result.stderr)
        counted = self.token_count_requests()[-1]["input"]
        inferred = self.inference_requests()[-1]["input"]
        self.assertIn("important context", counted)
        self.assertEqual(counted, inferred)

    def test_session_reuses_previous_response_id(self):
        first = self.run_cli("run", "-q", "low", "-o", "20", "-s", "design", "最初の質問")
        self.assertEqual(first.returncode, 0, first.stderr)
        State.requests = []
        second = self.run_cli("run", "-q", "low", "-o", "20", "-s", "design", "続きの質問")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.inference_requests()[-1]["previous_response_id"], "resp_mock")
        self.assertEqual(self.token_count_requests()[-1]["previous_response_id"], "resp_mock")


if __name__ == "__main__":
    unittest.main()
