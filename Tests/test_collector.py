"""Synthetic provider fixtures only; never record real account responses."""
import importlib.util
import pathlib
import unittest
import sys

sys.dont_write_bytecode = True

path = pathlib.Path(__file__).parents[1] / "Sources/MockUsage/Resources/collector.py"
spec = importlib.util.spec_from_file_location("collector", path)
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class CollectorTests(unittest.TestCase):
    def test_missing_is_not_zero(self):
        result = c.normalize_claude({}, {}, 100)
        self.assertEqual(result["windows"], [])
        self.assertIsNone(result["extra"])
        self.assertEqual(result["resets"]["state"], "unavailable")

    def test_zero_usage_is_a_real_measurement(self):
        result = c.normalize_claude({"five_hour": {"utilization": 0}}, {}, 100)
        self.assertEqual(result["windows"][0]["usedPercent"], 0)

    def test_invalid_percent_is_not_rendered(self):
        for invalid in [True, "50", -1, 101, float("nan"), float("inf")]:
            self.assertIsNone(c.window("a", "a", "a", invalid, None))

    def test_gpt_primary_can_be_weekly(self):
        result = c.normalize_gpt({"rate_limit": {"primary_window": {
            "used_percent": 2, "limit_window_seconds": 604800, "reset_after_seconds": 90}}}, None, 100)
        self.assertEqual(result["windows"][0]["title"], "Weekly window")
        self.assertEqual(result["windows"][0]["resetsAt"], 190)

    def test_currency_exponent_and_zero_cap(self):
        result = c.claude_extras({"extra_usage": {"is_enabled": True, "used_credits": 420,
            "monthly_limit": 2000, "currency": "EUR", "decimal_places": 2}})
        self.assertEqual(result["used"], 4.2)
        self.assertEqual(result["limit"], 20)
        self.assertEqual(result["unit"], "EUR")
        result = c.claude_extras({"spend": {"used": {"amount_minor": 0, "currency": "EUR", "exponent": 2},
            "limit": {"amount_minor": 0, "currency": "EUR", "exponent": 2}, "enabled": True}})
        self.assertEqual(result["limit"], 0)
        self.assertIsNone(result["usedPercent"])

    def test_scoped_limits_and_allowance(self):
        data = {"limits": [{"kind": "weekly_scoped", "percent": 12,
            "scope": {"model": {"display_name": "Fable"}}, "resets_at": 500}],
            "weekly_scoped_shares": [{"limit_index": 0, "allowance_percent_of_weekly": 50}]}
        result = c.normalize_claude(data, {}, 100)
        self.assertEqual(result["windows"][0]["scope"], "Fable")
        self.assertIn("50%", result["offers"][0]["detail"])
        self.assertIsNone(result["offers"][0]["expiresAt"])

    def grant(self, **kwargs):
        return dict(resets_left=1, resets_total=1, paused=False, starts_at=50, ends_at=200,
                    label="Model launch", clears=["five_hour", "seven_day_overage_included"], **kwargs)

    def test_claude_grants_use_scope_and_expiry(self):
        result = c.claude_resets({"cedar_ember": {"eligible": True, "grants": [self.grant()]}}, 100)
        self.assertEqual(result["items"][0]["title"], "Model launch")
        self.assertIn("Included model allowance", result["items"][0]["scope"])
        self.assertEqual(c.claude_resets({"cedar_ember": {"eligible": True, "grants": [self.grant()]}}, 201)["items"], [])

    def test_fable_reset_zero_usage_is_disabled_even_when_provider_allows_it(self):
        grant = {**self.grant(), "label": "Fable launch", "usable_now": True,
                 "gives_back_weekly": True,
                 "percent_used": {"five_hour": 0, "seven_day_overage_included": 0}}
        result = c.reset_presentation(grant)
        self.assertEqual(result["actionTitle"], "Fable reset")
        self.assertFalse(result["canReview"])
        self.assertIn("Nothing to reset", result["availabilityMessage"])
        self.assertIn("Gives back what Fable used", result["detail"])
        self.assertIn("does not reset your whole week", result["detail"])

    def test_full_reset_with_weekly_usage_is_ready(self):
        grant = {**self.grant(), "usable_now": True,
                 "clears": ["five_hour", "seven_day", "seven_day_overage_included"],
                 "percent_used": {"five_hour": 0, "seven_day": 4, "seven_day_overage_included": 0}}
        result = c.reset_presentation(grant)
        self.assertEqual(result["actionTitle"], "Full reset")
        self.assertTrue(result["canReview"])
        self.assertIn("Ready to use", result["availabilityMessage"])
        self.assertNotIn("Gives back", result["detail"])

    def test_missing_or_invalid_reset_usage_is_unknown_not_zero(self):
        for usage in [None, {}, {"five_hour": 0}, {"five_hour": True},
                      {"five_hour": -1, "seven_day_overage_included": 0}]:
            result = c.reset_presentation({**self.grant(), "usable_now": True, "percent_used": usage})
            self.assertIn("not fully known", result["availabilityMessage"])
            self.assertTrue(result["canReview"])

    def test_provider_block_overrides_nonzero_usage(self):
        result = c.reset_presentation({**self.grant(), "usable_now": False,
            "unavailable_reason": "cooldown", "percent_used": {"five_hour": 10, "seven_day_overage_included": 0}})
        self.assertFalse(result["canReview"])
        self.assertIn("cooldown", result["availabilityMessage"])

    def test_malformed_grant_does_not_hide_valid_grant(self):
        result = c.claude_resets({"cedar_ember": {"eligible": True, "grants": [{}, self.grant()]}}, 100)
        self.assertEqual(result["state"], "partial")
        self.assertEqual(len(result["items"]), 1)

    def test_ineligible_is_not_empty_inventory(self):
        result = c.claude_resets({"cedar_ember": {"eligible": False, "ineligible_reason": "cli_version"}}, 100)
        self.assertEqual(result["state"], "ineligible")
        self.assertIn("cli_version", result["message"])

    def test_gpt_used_expired_or_unsupported_resets_are_excluded(self):
        good = dict(status="available", is_supported_by_plan=True, expires_at=200, title="Full reset")
        credits = [good, {**good, "status": "redeemed"}, {**good, "expires_at": 90},
                   {**good, "is_supported_by_plan": False}, {**good, "expires_at": None}]
        self.assertEqual(len(c.gpt_resets({"credits": credits}, 100)["items"]), 1)

    def test_no_raw_account_identifiers_are_exported(self):
        result = c.normalize_claude({}, {"account": {"uuid": "secret-user", "email": "private@example.com"},
                                       "organization": {"uuid": "secret-org"}}, 100)
        self.assertEqual(len(result["accountKey"]), 64)
        self.assertNotIn("secret-user", str(result))
        self.assertNotIn("private@example.com", str(result))

    def test_cloud_credit_is_not_divided_by_one_hundred(self):
        result = c.normalize_claude({"iguana_necktie": {"remaining_dollars": 25, "resets_at": 200}}, {}, 100)
        self.assertIn("25", result["offers"][0]["detail"])
        self.assertIsNone(result["extra"])


if __name__ == "__main__":
    unittest.main()
