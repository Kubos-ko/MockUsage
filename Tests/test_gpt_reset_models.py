"""Read-only catalog fixtures and fully mocked Codex redemption tests."""
import json
import tempfile
import unittest
from unittest.mock import patch
from test_collector import c


class GPTResetTests(unittest.TestCase):
    def setUp(self):
        self.now = 100
        self.credit = dict(id="credit-test", reset_type="codex_rate_limits", title="Full reset",
                           status="available", is_supported_by_plan=True, expires_at=200)
        self.credits = {"credits": [self.credit]}
        self.usage = dict(user_id="test-user", account_id="test-account", rate_limit={
            "primary_window": {"used_percent": 7}, "secondary_window": None})
        self.intent = dict(accountKey=c.fingerprint("gptmock", "test-user", "test-account"),
            grantID="credit-test", binding=c.gpt_reset_binding(self.credit), confirmedAt=100)

    def test_current_supported_credit_is_ready(self):
        c.validate_gpt_reset(self.intent, self.usage, self.credits, "test-account", self.now)
        item = c.gpt_resets(self.credits, self.now, self.usage)["items"][0]
        self.assertTrue(item["usableNow"])
        self.assertEqual(item["providerGrantID"], "credit-test")

    def test_account_selection_confirmation_and_binding_are_checked(self):
        for change in [{"accountKey": "other"}, {"grantID": "different"}, {"binding": "changed"}, {"confirmedAt": -21}]:
            with self.subTest(change=change), self.assertRaises(c.FetchError):
                c.validate_gpt_reset({**self.intent, **change}, self.usage, self.credits, "test-account", 100)
        with self.assertRaises(c.FetchError):
            c.validate_gpt_reset(self.intent, self.usage, self.credits, "different-header-account", 100)

    def test_zero_and_unknown_quota_never_redeem(self):
        for limit in [{}, {"primary_window": {"used_percent": 0}},
                      {"primary_window": {"used_percent": True}},
                      {"primary_window": {"used_percent": 5}, "secondary_window": {}},
                      {"primary_window": {"used_percent": 101}}]:
            with self.subTest(limit=limit), self.assertRaises(c.FetchError):
                c.validate_gpt_reset(self.intent, {**self.usage, "rate_limit": limit}, self.credits, "test-account", 100)

    def test_expired_used_unsupported_or_changed_credit_never_redeems(self):
        for change in [{"expires_at": 99}, {"status": "redeemed"}, {"is_supported_by_plan": False},
                       {"reset_type": "unknown"}, {"expires_at": 300}]:
            with self.subTest(change=change), self.assertRaises(c.FetchError):
                c.validate_gpt_reset(self.intent, self.usage, {"credits": [{**self.credit, **change}]}, "test-account", 100)

    def test_transport_sends_exact_credit_and_maps_outcomes(self):
        with patch.object(c.urllib.request, "build_opener") as build:
            response = build.return_value.open.return_value.__enter__.return_value
            for raw, expected in [({"code": "reset", "windows_reset": 1}, "reset"),
                                  ({"code": "nothing_to_reset"}, "not_limited"),
                                  ({"code": "already_redeemed"}, "already_used"),
                                  ({"code": "no_credit"}, "unavailable"),
                                  ({"code": "reset", "windows_reset": 0}, "uncertain"),
                                  ({"code": "new_status"}, "uncertain")]:
                response.read.return_value = json.dumps(raw).encode()
                self.assertEqual(c.post_gpt_reset("credit-test", "request-test", {}), expected)
            req = build.return_value.open.call_args.args[0]
            self.assertEqual(req.get_method(), "POST")
            self.assertEqual(json.loads(req.data), {"credit_id": "credit-test", "redeem_request_id": "request-test"})
            self.assertTrue(req.full_url.endswith('/wham/rate-limit-reset-credits/consume'))
            build.return_value.open.side_effect = TimeoutError()
            self.assertEqual(c.post_gpt_reset("credit-test", "request-test", {}), "uncertain")

    def test_durable_gpt_reservation_never_repeats_unknown_request(self):
        with tempfile.TemporaryDirectory() as home, patch.object(c, "post_gpt_reset", return_value="uncertain") as post:
            send = lambda request_id: c.post_gpt_reset(self.intent["grantID"], request_id, {})
            c.submit_once(home, self.intent, send)
            c.submit_once(home, self.intent, send)
            post.assert_called_once()


class ModelCatalogTests(unittest.TestCase):
    def test_gpt_filters_hidden_models_and_marks_container_mismatch(self):
        data = {"models": [{"slug": "new-model", "visibility": "list", "available_in_plans": ["plus"]},
                           {"slug": "hidden", "visibility": "hide"}]}
        result = c.parse_gpt_models(data, {"plan_type": "plus"}, {"old-model"})
        self.assertEqual(len(result), 1)
        self.assertTrue(result[0]["available"])
        self.assertIn("Not listed", result[0]["note"])

    def test_gpt_missing_plan_is_unknown_and_excluded_plan_is_unavailable(self):
        data = {"models": [{"slug": "model", "visibility": "list", "available_in_plans": ["pro"]}]}
        self.assertIsNone(c.parse_gpt_models(data, {}, None)[0]["available"])
        self.assertFalse(c.parse_gpt_models(data, {"plan_type": "plus"}, None)[0]["available"])

    def test_claude_api_listing_is_not_an_access_claim(self):
        result = c.parse_claude_models([{"id": "claude-test"}], {})
        self.assertIsNone(result[0]["available"])

    def test_claude_account_options_override_api_listing(self):
        raw = [{"id": "claude-fable"}, {"id": "claude-other"}]
        bootstrap = {"additional_model_options": [{"model": "claude-fable[1m]", "disabled_reason": None},
                                                  {"model": "claude-other", "disabled_reason": "org_policy"}]}
        result = c.parse_claude_models(raw, bootstrap)
        self.assertEqual(len(result), 2)
        self.assertTrue(result[0]["available"])
        self.assertFalse(result[1]["available"])

    def test_empty_catalog_is_an_error_not_an_empty_success(self):
        with self.assertRaises(c.FetchError): c.parse_gpt_models({"models": []}, {}, set())
        with self.assertRaises(c.FetchError): c.parse_claude_models([], {})

    def test_claude_catalog_paginates_without_inference(self):
        pages = [{"account": {"uuid": "test"}, "organization": {"uuid": "org"}},
                 {"data": [{"id": "claude-a"}], "has_more": True, "last_id": "claude-a"},
                 {"data": [{"id": "claude-b"}], "has_more": False}, {}]
        with patch.object(c, "claude_headers", return_value={}), patch.object(c, "request", side_effect=pages) as get:
            result = c.collect_models("claude", "unused")
            self.assertEqual(len(result["entries"]), 2)
            self.assertIn("after_id=claude-a", get.call_args_list[2].args[0])
            self.assertTrue(all("messages" not in call.args[0] for call in get.call_args_list))

    def test_catalog_output_never_exports_raw_profile(self):
        with patch.object(c, "claude_headers", return_value={}), patch.object(c, "request", side_effect=[
            {"account": {"uuid": "secret-user", "email": "private@example.test"}, "organization": {"uuid": "secret-org"}},
            {"data": [{"id": "claude-a", "secret": "should-not-export"}], "has_more": False}, {}]):
            result = str(c.collect_models("claude", "unused"))
            for value in ["secret-user", "secret-org", "private@example.test", "should-not-export"]:
                self.assertNotIn(value, result)
