"""Runtime changes must not silently authorize a destructive operation."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch
from test_collector import c


class VersionCompatibilityTests(unittest.TestCase):
    def test_gptmock_runtime_is_read_from_installed_package(self):
        with patch.object(c.importlib.metadata, "version", return_value="2026.11.16"):
            runtime = c.runtime_info("gptmock")
        self.assertEqual(runtime["providerVersion"], "2026.11.16")
        self.assertEqual(runtime["adapterID"], "codex-wham-v1")
        self.assertTrue(runtime["resetSupported"])

    def test_new_runtime_stays_read_only_until_validated(self):
        with patch.object(c.importlib.metadata, "version", return_value="2027.1.1"):
            runtime = c.runtime_info("gptmock")
            self.assertFalse(runtime["resetSupported"])
            with patch.object(c, "gpt_headers") as auth, self.assertRaises(c.FetchError):
                c.redeem_gpt_reset({"runtimeVersion": "2027.1.1", "adapterID": "codex-wham-v1"})
            auth.assert_not_called()

    def test_version_change_after_confirmation_blocks_before_auth(self):
        runtime = dict(providerVersion="2.1.325", adapterID="claude-oauth-v1", resetSupported=True)
        with patch.object(c, "runtime_info", return_value=runtime), patch.object(c, "claude_headers") as auth:
            for intent in [{"runtimeVersion": "2.1.324", "adapterID": "claude-oauth-v1"},
                           {"runtimeVersion": "2.1.325", "adapterID": "unknown"}]:
                with self.assertRaises(c.FetchError): c.redeem_reset(intent)
            auth.assert_not_called()

    def test_response_envelope_identifies_collector_protocol(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output): c.emit({"error": "synthetic"})
        self.assertEqual(json.loads(output.getvalue()), {"protocolVersion": 1, "error": "synthetic"})

class AdapterRoutingTests(unittest.TestCase):
    def test_existing_versions_keep_exact_adapter_bindings(self):
        expected = {"gptmock": {"2026.9.29": "codex-wham-v1", "2026.11.16": "codex-wham-v1"},
                    "claude": {"2.1.325": "claude-oauth-v1"}}
        for provider, versions in expected.items():
            for version, adapter_id in versions.items():
                with self.subTest(provider=provider, version=version), patch.object(c, "detect_runtime_version", return_value=version):
                    runtime = c.runtime_info(provider)
                    self.assertEqual(runtime["adapterID"], adapter_id)
                    self.assertEqual(runtime["compatibilityStatus"], "verified")

    def test_new_adapter_routes_all_operations_without_changing_old_versions(self):
        from unittest.mock import Mock
        new = Mock(provider="gptmock")
        new.collect.return_value = {"accountKey": "synthetic", "resets": {"items": []}}
        new.models.return_value = {"entries": []}
        new.redeem.return_value = {"result": "synthetic-no-network"}
        with patch.dict(c.ADAPTERS, {"codex-wham-v2-test": new}), patch.dict(c.RUNTIME_ADAPTERS["gptmock"], {"2099.1.1": "codex-wham-v2-test"}):
            with patch.object(c, "detect_runtime_version", return_value="2099.1.1"):
                runtime = c.runtime_info("gptmock")
                self.assertEqual(c.collect("gptmock")["runtime"]["adapterID"], "codex-wham-v2-test")
                c.collect_models("gptmock", "1.0.0")
                c.redeem_gpt_reset({"runtimeVersion": "2099.1.1", "adapterID": runtime["adapterID"]})
                new.collect.assert_called_once()
                new.models.assert_called_once_with("1.0.0")
                new.redeem.assert_called_once()
            for version in ("2026.9.29", "2026.11.16"):
                with patch.object(c, "detect_runtime_version", return_value=version):
                    self.assertIs(c.selected_adapter(c.runtime_info("gptmock")), c.ADAPTERS["codex-wham-v1"])

    def test_unknown_runtime_uses_read_only_adapter_and_disables_grants(self):
        adapter = c.ADAPTERS["claude-oauth-v1"]
        with patch.object(c, "detect_runtime_version", return_value="2.1.326-beta.1"), patch.object(adapter, "collect", return_value={"accountKey": "synthetic", "resets": {"items": [{"usableNow": True}]}}), patch.object(adapter, "redeem") as redeem:
            snapshot = c.collect("claude")
            self.assertEqual(snapshot["runtime"]["compatibilityStatus"], "unverified")
            self.assertFalse(snapshot["resets"]["items"][0]["usableNow"])
            with self.assertRaises(c.FetchError):
                c.redeem_reset({"runtimeVersion": "2.1.326-beta.1", "adapterID": "claude-oauth-v1"})
            redeem.assert_not_called()

    def test_unsupported_version_blocks_all_operations_before_auth(self):
        with patch.object(c, "detect_runtime_version", return_value="2099.1.1"), patch.dict(c.UNSUPPORTED_RUNTIMES["gptmock"], {"2099.1.1": "Synthetic incompatible schema."}), patch.object(c, "gpt_headers") as auth:
            runtime = c.runtime_info("gptmock")
            self.assertEqual(runtime["compatibilityStatus"], "unsupported")
            self.assertFalse(runtime["resetSupported"])
            for operation in [lambda: c.collect("gptmock"), lambda: c.collect_models("gptmock", "1.0.0"), lambda: c.redeem_gpt_reset({})]:
                with self.assertRaises(c.FetchError): operation()
            auth.assert_not_called()
            output = io.StringIO()
            with patch.object(c.sys, "argv", ["collector.py", "gptmock"]), contextlib.redirect_stdout(output):
                c.main()
            envelope = json.loads(output.getvalue())
            self.assertEqual(envelope["error"], "unsupported_runtime")
            self.assertEqual(envelope["runtime"], runtime)

    def test_missing_or_cross_provider_adapter_fails_closed(self):
        for adapter_id in ["missing-adapter", "claude-oauth-v1"]:
            with patch.object(c, "detect_runtime_version", return_value="2099.1.1"), patch.dict(c.RUNTIME_ADAPTERS["gptmock"], {"2099.1.1": adapter_id}):
                self.assertEqual(c.runtime_info("gptmock")["compatibilityStatus"], "unsupported")

    def test_prerelease_does_not_inherit_release_validation(self):
        from types import SimpleNamespace
        with patch.object(c.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="2.1.325-beta.1 (Claude Code)")):
            runtime = c.runtime_info("claude")
            self.assertEqual(runtime["providerVersion"], "2.1.325-beta.1")
            self.assertEqual(runtime["compatibilityStatus"], "unverified")

    def test_provider_error_still_reports_detected_runtime(self):
        output = io.StringIO()
        with patch.object(c, "detect_runtime_version", return_value="2026.11.16"), patch.object(c.ADAPTERS["codex-wham-v1"], "collect", side_effect=c.FetchError("http_429")), patch.object(c.sys, "argv", ["collector.py", "gptmock"]), contextlib.redirect_stdout(output):
            c.main()
        result = json.loads(output.getvalue())
        self.assertEqual(result["error"], "http_429")
        self.assertEqual(result["runtime"]["compatibilityStatus"], "verified")
