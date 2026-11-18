"""Reset safety tests: synthetic identities, mocked transport, no live requests."""
import copy
import json
import os
import tempfile
import unittest
from unittest.mock import patch
from test_collector import c


class ResetTests(unittest.TestCase):
    def setUp(self):
        self.now = c.dt.datetime.now(c.dt.timezone.utc).timestamp()
        self.profile = {"account": {"uuid": "test-account"}, "organization": {"uuid": "test-org"}}
        self.grant = dict(id="test_full", label="Full reset", resets_left=1, resets_total=1,
            starts_at=self.now-100, ends_at=self.now+1000, paused=False, usable_now=True,
            clears=["five_hour", "seven_day"], percent_used={"five_hour": 0, "seven_day": 4}, blocking=[])
        self.data = {"cedar_ember": {"eligible": True, "grants": [self.grant]}}
        self.intent = dict(accountKey=c.fingerprint("claude", "test-account", "test-org"),
            grantID="test_full", binding=c.reset_binding(self.grant), confirmedAt=self.now,
            runtimeVersion="2.1.325", adapterID="claude-oauth-v1")
        # Any accidentally unmocked provider transport must fail locally.
        self.net = patch.object(c.urllib.request, "urlopen", side_effect=AssertionError("Live network forbidden"))
        runtime = patch.object(c, "runtime_info", return_value={"providerVersion": "2.1.325", "adapterID": "claude-oauth-v1", "resetSupported": True})
        runtime.start()
        self.addCleanup(runtime.stop)
        self.net.start()
        self.addCleanup(self.net.stop)

    def test_rate_limited_preflight_waits_once_then_posts_once(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": tmp}), \
             patch.object(c, "claude_headers", return_value={}), \
             patch.object(c, "request", side_effect=[self.profile, c.FetchError("http_429", 0), self.data]) as read, \
             patch.object(c.time, "sleep") as wait, patch.object(c, "post_reset", return_value="reset") as post:
            self.assertEqual(c.redeem_reset(self.intent)["result"], "reset")
            wait.assert_called_once_with(60)
            self.assertEqual(read.call_count, 3)
            post.assert_called_once()

    def test_repeated_throttling_or_long_retry_after_never_posts(self):
        for responses in [[self.profile, c.FetchError("http_429", 0), c.FetchError("http_429", 0)],
                          [self.profile, c.FetchError("http_429", 300)],
                          [c.FetchError("http_429", 0), self.profile, c.FetchError("http_429", 0)]]:
            with patch.object(c, "claude_headers", return_value={}), patch.object(c, "request", side_effect=responses), \
                 patch.object(c.time, "sleep") as wait, patch.object(c, "post_reset") as post:
                with self.assertRaises(c.FetchError): c.redeem_reset(self.intent)
                self.assertLessEqual(wait.call_count, 1)
                post.assert_not_called()

    def test_confirmation_expiry_is_checked_after_preflight_wait(self):
        before = c.dt.datetime.fromtimestamp(self.now, c.dt.timezone.utc)
        after = c.dt.datetime.fromtimestamp(self.now+121, c.dt.timezone.utc)
        with patch.object(c, "claude_headers", return_value={}), \
             patch.object(c, "request", side_effect=[self.profile, c.FetchError("http_429", 0), self.data]), \
             patch.object(c.time, "sleep"), patch.object(c.dt, "datetime") as dates, patch.object(c, "post_reset") as post:
            dates.now.side_effect = [before, before, after]
            with self.assertRaises(c.FetchError) as failure: c.redeem_reset(self.intent)
            self.assertEqual(failure.exception.code, "reset_confirmation_expired")
            post.assert_not_called()

    def test_diagnostics_do_not_capture_headers_or_freeform_response_fields(self):
        with patch.object(c, "RESET_DIAGNOSTICS", []), patch.object(c.urllib.request, "build_opener") as build:
            response = build.return_value.open.return_value.__enter__.return_value
            response.status = 200
            response.read.return_value = b'{"result":"reset","reason":"secret-sensitive-text","message":"private-account@example.com"}'
            self.assertEqual(c.post_reset("private-org", "private-grant", "private-request", {"Authorization":"Bearer private-token"}), "reset")
            serialized = json.dumps(c.RESET_DIAGNOSTICS)
            for secret in ["private", "secret-sensitive-text", "Authorization", "Bearer"]:
                self.assertNotIn(secret, serialized)
            self.assertEqual(c.RESET_DIAGNOSTICS[-1]["httpStatus"], 200)

    def test_fresh_cache_avoids_duplicate_usage_read_and_is_cleared_after_submission(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": tmp}), \
             patch.object(c, "detect_runtime_version", return_value="2.1.325"):
            headers = {"Authorization": "Bearer synthetic-token"}
            c.save_claude_preflight(self.data, self.profile, headers, self.now)
            self.assertEqual(os.stat(c.claude_preflight_cache_path()).st_mode & 0o777, 0o600)
            with open(c.claude_preflight_cache_path()) as file:
                self.assertNotIn("synthetic-token", file.read())
            with patch.object(c, "claude_headers", return_value=headers), patch.object(c, "request", return_value=self.profile) as read, \
                 patch.object(c, "post_reset", return_value="reset") as post:
                self.assertEqual(c.redeem_reset(self.intent)["result"], "reset")
                read.assert_called_once_with("https://api.anthropic.com/api/oauth/profile", headers)
                post.assert_called_once()
                self.assertFalse(os.path.exists(c.claude_preflight_cache_path()))

    def test_cache_rejects_age_clock_changes_account_token_and_runtime_changes(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": tmp}), \
             patch.object(c, "detect_runtime_version", return_value="2.1.325"):
            headers = {"Authorization": "Bearer synthetic-token"}
            c.save_claude_preflight(self.data, self.profile, headers, self.now)
            self.assertIsNotNone(c.load_claude_preflight(self.intent, self.profile, headers, self.now+1))
            for intent, profile, auth, now in [
                (self.intent, self.profile, headers, self.now+16), (self.intent, self.profile, headers, self.now-1),
                ({**self.intent, "accountKey": "changed"}, self.profile, headers, self.now),
                (self.intent, {"account": {"uuid":"other"},"organization":{"uuid":"other"}}, headers, self.now),
                (self.intent, self.profile, {"Authorization":"Bearer changed"}, self.now),
                ({**self.intent, "runtimeVersion":"new-version"}, self.profile, headers, self.now)]:
                self.assertIsNone(c.load_claude_preflight(intent, profile, auth, now))

    def test_preflight_accepts_exact_current_grant(self):
        self.assertEqual(c.validate_reset(self.intent, self.profile, self.data, self.now), "test-org")

    def test_account_change_expired_confirmation_and_wrong_grant_fail_closed(self):
        for changes in [{"accountKey": "wrong"}, {"confirmedAt": self.now-121}, {"grantID": "missing"}, {"binding": "changed"}]:
            with self.subTest(changes=changes), self.assertRaises(c.FetchError):
                c.validate_reset({**self.intent, **changes}, self.profile, self.data, self.now)

    def test_zero_missing_usage_expiry_and_provider_blocks_fail_closed(self):
        for changes in [{"percent_used": {"five_hour": 0, "seven_day": 0}}, {"percent_used": {}},
                        {"usable_now": False}, {"paused": True}, {"ends_at": self.now-1},
                        {"resets_left": 0}, {"blocking": ["seven_day"]}]:
            data = copy.deepcopy(self.data)
            data["cedar_ember"]["grants"][0].update(changes)
            intent = {**self.intent, "binding": c.reset_binding(data["cedar_ember"]["grants"][0])}
            with self.subTest(changes=changes), self.assertRaises(c.FetchError):
                c.validate_reset(intent, self.profile, data, self.now)

    def test_changed_scope_requires_new_confirmation(self):
        self.grant["clears"] = ["five_hour"]
        with self.assertRaises(c.FetchError):
            c.validate_reset(self.intent, self.profile, self.data, self.now)

    def test_fable_has_its_own_provider_id_and_binding(self):
        self.grant.update(id="test_fable", label="Fable reset", clears=["five_hour", "seven_day_overage_included"],
                          percent_used={"five_hour": 2, "seven_day_overage_included": 1}, gives_back_weekly=True)
        intent = {**self.intent, "grantID": "test_fable", "binding": c.reset_binding(self.grant)}
        self.assertEqual(c.validate_reset(intent, self.profile, self.data, self.now), "test-org")

    def run_mocked(self, outcome, twice=False, intent=None):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": tmp}), \
             patch.object(c, "claude_headers", return_value={}), \
             patch.object(c, "request", side_effect=lambda url, headers: self.profile if url.endswith("profile") else self.data), \
             patch.object(c, "post_reset", return_value=outcome) as post:
            result = c.redeem_reset(intent or self.intent)
            if twice:
                again = c.redeem_reset(intent or self.intent)
                self.assertEqual(again["result"], "uncertain")
            self.assertEqual(post.call_count, 1)
            self.assertEqual(post.call_args.args[:2], ("test-org", "test_full"))
            return result

    def test_success_sends_once_and_durable_journal_blocks_duplicate(self):
        self.assertEqual(self.run_mocked("reset", twice=True)["result"], "reset")

    def test_uncertain_outcome_never_retries(self):
        self.assertEqual(self.run_mocked("uncertain", twice=True)["result"], "uncertain")

    def test_preflight_failure_never_posts(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": tmp}), \
             patch.object(c, "claude_headers", return_value={}), \
             patch.object(c, "request", side_effect=[self.profile, self.data]), patch.object(c, "post_reset") as post:
            with self.assertRaises(c.FetchError):
                c.redeem_reset({**self.intent, "accountKey": "wrong"})
            post.assert_not_called()

    def test_post_payload_and_response_are_checked_without_network(self):
        with patch.object(c.urllib.request, "build_opener") as build:
            build.return_value.open.return_value.__enter__.return_value.read.return_value = b'{"result":"reset"}'
            self.assertEqual(c.post_reset("test-org", "test_full", "test-request", {}), "reset")
            req = build.return_value.open.call_args.args[0]
            self.assertEqual(req.get_method(), "POST")
            self.assertEqual(req.full_url, "https://api.anthropic.com/api/organizations/test-org/reset_rate_limits")
            self.assertEqual(json.loads(req.data), {"program": "cedar_ember", "grant_id": "test_full", "request_id": "test-request"})
            build.return_value.open.side_effect = TimeoutError()
            self.assertEqual(c.post_reset("test-org", "test_full", "test-request", {}), "uncertain")

    def test_unknown_response_is_not_success_and_redirects_are_refused(self):
        with patch.object(c.urllib.request, "build_opener") as build:
            build.return_value.open.return_value.__enter__.return_value.read.return_value = b'{"result":"new_status"}'
            self.assertEqual(c.post_reset("test-org", "test_full", "test-request", {}), "uncertain")
        self.assertIsNone(c.NoResetRedirect().redirect_request(None, None, 307, "", {}, "https://other.invalid"))


if __name__ == "__main__":
    unittest.main()
