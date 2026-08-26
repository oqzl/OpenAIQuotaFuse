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


class MockState:
    usage_exhausted = False
    official_costs = 0.0
    classifier_result = "low"
    requests: list[tuple[str, dict]] = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if not length:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _send(self, payload: dict, status: int = 200) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        MockState.requests.append((path, {}))
        if path == "/v1/organization/usage/completions":
            results = []
            if MockState.usage_exhausted:
                results = [
                    {"model": "gpt-5.6-luna", "input_tokens": 2_500_000, "output_tokens": 0},
                    {"model": "gpt-5.6-sol", "input_tokens": 250_000, "output_tokens": 0},
                ]
            self._send({"object": "page", "data": [{"object": "bucket", "results": results}], "has_more": False, "next_page": None})
            return
        if path == "/v1/organization/costs":
            self._send({
                "object": "page",
                "data": [{"object": "bucket", "results": [{
                    "object": "organization.costs.result",
                    "amount": {"value": MockState.official_costs, "currency": "usd"},
                }]}],
                "has_more": False,
                "next_page": None,
            })
            return
        self._send({"error": "unexpected GET"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._json_body()
        MockState.requests.append((path, body))
        if path == "/v1/responses/input_tokens":
            self._send({"object": "response.input_tokens", "input_tokens": 7})
            return
        if path == "/v1/responses":
            if "instructions" in body:
                self._send({
                    "id": "resp_classifier",
                    "output": [{"type": "message", "content": [{"type": "output_text", "text": MockState.classifier_result}]}],
                    "usage": {"input_tokens": 7, "output_tokens": 1, "total_tokens": 8},
                })
            else:
                self._send({
                    "id": "resp_mock",
                    "output": [{"type": "message", "content": [{"type": "output_text", "text": "mock answer"}]}],
                    "usage": {"input_tokens": 7, "output_tokens": 3, "total_tokens": 10},
                })
            return
        self._send({"error": "unexpected POST"}, 404)


class MockedE2ETest(unittest.TestCase):
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
        MockState.usage_exhausted = False
        MockState.official_costs = 0.0
        MockState.classifier_result = "low"
        MockState.requests = []
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = Path(self.tmp.name) / "paid.json"

    def run_cli(self, *args: str, stdin: str | None = None, budget: str = "5") -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update({
            "OPENAI_ADMIN_KEY": "test-admin",
            "OPENAI_API_KEY": "test-api",
            "OPENAI_USAGE_TIER": "1",
            "OPENAI_QUOTA_RESERVE_PERCENT": "0",
            "OPENAI_ANNUAL_PAID_BUDGET_USD": budget,
            "OPENAI_QUOTA_FUSE_PAID_LEDGER": str(self.ledger),
            "OPENAI_QUOTA_FUSE_API_BASE": self.base,
        })
        return subprocess.run(
            [sys.executable, str(CLI), *args],
            input=stdin,
            text=True,
            capture_output=True,
            cwd=ROOT,
            env=env,
            check=False,
        )

    def classifier_calls(self) -> list[dict]:
        return [body for path, body in MockState.requests if path == "/v1/responses" and "instructions" in body]

    def inference_calls(self) -> list[dict]:
        return [body for path, body in MockState.requests if path == "/v1/responses" and "instructions" not in body]

    def test_explicit_model_bypasses_classifier_and_preserves_effort(self):
        result = self.run_cli("run", "-e", "high", "-m", "gpt-5.6-luna", "-o", "20", "-i", "hello")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "mock answer")
        self.assertIn("quota: OK (input=7 + max_output=20 => reserve=27 tokens)", result.stderr)
        self.assertIn("reasoning effort: high", result.stderr)
        self.assertFalse(self.classifier_calls())
        self.assertEqual(self.inference_calls()[-1]["reasoning"]["effort"], "high")

    def test_auto_high_routes_to_sol(self):
        MockState.classifier_result = "high"
        result = self.run_cli("run", "-o", "20", "-i", "design and implement a multi-step repository refactor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("quality: auto -> high", result.stderr)
        self.assertIn("model: gpt-5.6-sol", result.stderr)
        self.assertEqual(len(self.classifier_calls()), 1)
        self.assertEqual(self.inference_calls()[-1]["model"], "gpt-5.6-sol")

    def test_explicit_low_bypasses_classifier_and_routes_to_terra(self):
        result = self.run_cli("run", "-q", "low", "-o", "20", "-i", "explicit low")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("model: gpt-5.6-terra", result.stderr)
        self.assertFalse(self.classifier_calls())

    def test_stdin_and_raw_output(self):
        result = self.run_cli("run", "-m", "gpt-5.6-luna", "-o", "20", stdin="hello from stdin")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "mock answer")

        raw = self.run_cli("run", "-r", "-m", "gpt-5.6-luna", "-o", "20", "-i", "raw")
        self.assertEqual(raw.returncode, 0, raw.stderr)
        payload = json.loads(raw.stdout)
        self.assertEqual(payload["id"], "resp_mock")
        self.assertEqual(payload["usage"]["total_tokens"], 10)

    def test_costs_command_uses_official_spend(self):
        MockState.official_costs = 0.25
        result = self.run_cli("costs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("official_costs_usd=0.25", result.stdout)
        self.assertIn("effective_budget_spend_usd=0.25", result.stdout)

    def test_paid_fallback_records_completed_reservation(self):
        MockState.usage_exhausted = True
        result = self.run_cli("run", "-e", "low", "-q", "low", "-o", "20", "-i", "paid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "mock answer")
        self.assertIn("paid fallback reserved", result.stderr)
        self.assertIn("model: gpt-5.6-luna", result.stderr)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(ledger["schema_version"], 2)
        self.assertEqual(len(ledger["requests"]), 1)
        self.assertEqual(ledger["requests"][0]["state"], "completed")
        self.assertGreater(ledger["requests"][0]["actual_usd"], 0)

    def test_official_costs_and_zero_budget_block_paid_fallback(self):
        MockState.usage_exhausted = True
        MockState.official_costs = 4.99999
        blocked = self.run_cli("run", "-q", "low", "-o", "20", "-i", "blocked by direct spend")
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("paid fallback blocked", blocked.stderr)

        MockState.official_costs = 0.0
        if self.ledger.exists():
            self.ledger.unlink()
        zero = self.run_cli("run", "-q", "low", "-o", "20", "-i", "blocked", budget="0")
        self.assertNotEqual(zero.returncode, 0)
        self.assertIn("paid fallback blocked", zero.stderr)


if __name__ == "__main__":
    unittest.main()
