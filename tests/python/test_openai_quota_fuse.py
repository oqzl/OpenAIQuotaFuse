import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[2] / "python" / "openai_quota_fuse.py"
spec = importlib.util.spec_from_file_location("qf", MODULE)
qf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qf)

MODELS = {"quota_groups": {"standard": {"daily_token_limits": {"tier_1_2": 100, "tier_3_5": 200}, "models": ["sol"]}, "high_volume": {"daily_token_limits": {"tier_1_2": 1000, "tier_3_5": 2000}, "models": ["terra", "luna"]}}}
SELECTION = {"quality_profiles": {"low": ["terra", "luna", "sol"], "high": ["sol", "terra", "luna"]}, "paid_fallback": {"pricing_usd_per_million_tokens": {"luna": {"input": .2, "output": 1.2}}, "long_context_threshold_input_tokens": 272000, "long_context_input_multiplier": 2.0, "long_context_output_multiplier": 1.5}}


class FuseTests(unittest.TestCase):
    def setUp(self):
        os.environ["OPENAI_USAGE_TIER"] = "1"
        os.environ["OPENAI_QUOTA_RESERVE_PERCENT"] = "5"

    def test_usage_is_grouped_and_reserved(self):
        raw = {"data": [{"results": [{"model": "terra", "input_tokens": 100, "output_tokens": 20}, {"model": "sol", "input_tokens": 10, "output_tokens": 5}]}]}
        usage = qf.summarize_usage(raw, MODELS)
        self.assertEqual(usage, {"standard": 15, "high_volume": 120})
        self.assertEqual(qf.available_for_group("standard", 15, MODELS), 80)
        self.assertEqual(qf.available_for_group("high_volume", 120, MODELS), 830)

    def test_price_estimate_and_long_context_multiplier(self):
        self.assertAlmostEqual(qf.price_estimate("luna", 1000, 1000, SELECTION), .0014)
        self.assertAlmostEqual(qf.price_estimate("luna", 300000, 1000, SELECTION), .1218)

    def test_output_text(self):
        response = {"output": [{"type": "message", "content": [{"type": "output_text", "text": "a"}, {"type": "output_text", "text": "b"}]}]}
        self.assertEqual(qf.output_text(response), "a\nb")

    def test_ledger_guard_unknown_and_recent_completed(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["OPENAI_QUOTA_FUSE_PAID_LEDGER"] = str(Path(td) / "paid.json")
            now = int(qf.time.time())
            year = str(qf.dt.datetime.now(qf.dt.timezone.utc).year)
            qf.write_ledger({"schema_version": 2, "requests": [{"year": year, "state": "unknown", "reserved_usd": .4, "created_epoch": 1}, {"year": year, "state": "completed", "reserved_usd": .3, "actual_usd": .2, "created_epoch": now}]})
            self.assertAlmostEqual(qf.local_guard_spent(), .6)


if __name__ == "__main__":
    unittest.main()
