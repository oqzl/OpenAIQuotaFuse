import datetime as dt
import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "refresh-model-policy.py"
SPEC = importlib.util.spec_from_file_location("refresh_model_policy", MODULE_PATH)
assert SPEC and SPEC.loader
refresh = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(refresh)


class RefreshModelPolicyTests(unittest.TestCase):
    def test_staleness_uses_strictly_more_than_interval(self):
        selection = {"last_reviewed": "2026-09-27", "review_interval_days": 30}
        self.assertFalse(refresh.policy_is_stale(selection, dt.date(2026, 10, 27)))
        self.assertTrue(refresh.policy_is_stale(selection, dt.date(2026, 10, 28)))

    def test_relevant_model_snapshot_keeps_policy_and_current_families(self):
        api_models = {
            "data": [
                {"id": "gpt-6.1-sol", "owned_by": "openai", "shutdown_date": None},
                {"id": "gpt-5.6-terra", "owned_by": "openai", "shutdown_date": None},
                {"id": "unrelated-model", "owned_by": "openai", "shutdown_date": None},
            ]
        }
        models = {
            "quota_groups": {
                "high_volume": {
                    "models": ["gpt-5.6-terra"],
                    "daily_token_limits": {"tier_1_2": 1},
                }
            }
        }
        selection = {
            "default_candidates": ["gpt-5.6-terra"],
            "paid_fallback": {"quality_profiles": {"low": ["gpt-6.1-sol"]}},
        }
        snapshot = refresh.relevant_model_snapshot(api_models, models, selection)
        self.assertEqual(
            [item["id"] for item in snapshot],
            ["gpt-5.6-terra", "gpt-6.1-sol"],
        )

    def test_validate_refresh_accepts_consistent_policy(self):
        today = dt.date(2026, 10, 27)
        models = {
            "schema_version": 1,
            "last_reviewed": "2026-10-27",
            "source": "https://help.openai.com/example",
            "quota_groups": {
                "standard": {
                    "daily_token_limits": {"tier_1_2": 250000},
                    "models": ["gpt-6-astra"],
                },
                "high_volume": {
                    "daily_token_limits": {"tier_1_2": 2500000},
                    "models": ["gpt-5.6-terra"],
                },
            },
        }
        selection = {
            "schema_version": 1,
            "last_reviewed": "2026-10-27",
            "review_interval_days": 30,
            "default_candidates": ["gpt-5.6-terra", "gpt-6-astra"],
            "quality_profiles": {
                "low": ["gpt-5.6-terra", "gpt-6-astra"],
                "high": ["gpt-6-astra", "gpt-5.6-terra"],
            },
            "auto_quality": {"classifier_model": "gpt-5.6-terra"},
            "paid_fallback": {
                "quality_profiles": {
                    "low": ["gpt-6-luna"],
                    "high": ["gpt-6.1-sol"],
                },
                "pricing_usd_per_million_tokens": {
                    "gpt-6-luna": {"input": 0.1, "output": 0.5},
                    "gpt-6.1-sol": {"input": 2, "output": 10},
                },
            },
        }
        sources = refresh.validate_refresh(
            models,
            selection,
            today,
            [
                "https://help.openai.com/en/articles/example?utm_source=test",
                "https://developers.openai.com/api/docs/models",
            ],
        )
        self.assertEqual(
            sources,
            [
                "https://help.openai.com/en/articles/example",
                "https://developers.openai.com/api/docs/models",
            ],
        )

    def test_validate_sources_rejects_non_openai_domain(self):
        with self.assertRaises(ValueError):
            refresh.validate_sources(
                [
                    "https://help.openai.com/en/articles/example",
                    "https://example.com/not-allowed",
                ]
            )


if __name__ == "__main__":
    unittest.main()
