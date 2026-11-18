"""Run inside a selected container; only normalized usage leaves stdout.

Credentials are never copied to the host. Collection is read-only.
A separately confirmed Claude or Codex reset performs one guarded POST.
GPTMock owns token renewal. Claude Code owns its credentials and renewal.
"""
import base64
import fcntl
import uuid
import asyncio
import contextlib
import datetime as dt
import hashlib
import io
import importlib.metadata
import json
import math
import os
import re
import subprocess
import sys
import time
import tempfile
import urllib.error
import urllib.request
import urllib.parse


COLLECTOR_PROTOCOL_VERSION = 1
RESET_DIAGNOSTICS = None


def reset_event(stage, **fields):
    if RESET_DIAGNOSTICS is not None:
        RESET_DIAGNOSTICS.append(dict(stage=stage, **fields))


def reset_preflight_request(url, headers, budget, stage):
    """Retry at most one read, never a reset POST, after provider throttling."""
    try:
        data = request(url, headers)
        reset_event(stage, outcome="ok")
        return data
    except FetchError as error:
        reset_event(stage, outcome=error.code, seconds=error.retry_after)
        delay = max(60, error.retry_after or 0)
        if error.code != "http_429" or budget["waited"] or delay > 60:
            raise
        budget["waited"] = True
        reset_event("preflight_wait", seconds=delay)
        time.sleep(delay)
        try:
            data = request(url, headers)
            reset_event(stage, outcome="ok_after_wait")
            return data
        except FetchError as retry_error:
            reset_event(stage, outcome=retry_error.code, seconds=retry_error.retry_after)
            raise

# Exact runtime bindings are additive: never repoint an older release to a new adapter.
RUNTIME_ADAPTERS = {
    "gptmock": {"2026.9.29": "codex-wham-v1", "2026.11.16": "codex-wham-v1"},
    "claude": {"2.1.325": "claude-oauth-v1"},
}
# Populate only with demonstrated incompatibilities, mapping exact versions to reasons.
UNSUPPORTED_RUNTIMES = {"gptmock": {}, "claude": {}}
READ_ONLY_FALLBACKS = {"gptmock": "codex-wham-v1", "claude": "claude-oauth-v1"}


def detect_runtime_version(provider):
    try:
        if provider == "gptmock":
            return importlib.metadata.version("gptmock")
        if provider == "claude":
            result = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=8)
            match = re.search(r"\b\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", result.stdout)
            if result.returncode == 0 and match:
                return match.group(0)
    except (OSError, subprocess.SubprocessError, importlib.metadata.PackageNotFoundError):
        pass
    return "unknown"


def runtime_info(provider):
    version = detect_runtime_version(provider)
    reason = UNSUPPORTED_RUNTIMES.get(provider, {}).get(version)
    adapter_id = RUNTIME_ADAPTERS.get(provider, {}).get(version)
    status = "verified" if adapter_id else "unverified"
    if not adapter_id:
        adapter_id = READ_ONLY_FALLBACKS.get(provider)
    adapter = ADAPTERS.get(adapter_id)
    if reason or adapter is None or adapter.provider != provider:
        status, adapter_id = "unsupported", "none"
        reason = reason or "No compatible adapter is included in this app."
    messages = {
        "verified": "This runtime is validated with the selected adapter. Live schema and reset eligibility checks still apply.",
        "unverified": "This runtime has not been validated. Read-only fallback; direct resets are disabled.",
        "unsupported": reason or "No compatible adapter is available.",
    }
    return dict(providerVersion=version, adapterID=adapter_id,
                protocolVersion=COLLECTOR_PROTOCOL_VERSION, resetSupported=status == "verified",
                compatibilityStatus=status, compatibility=messages[status])


def selected_adapter(runtime):
    if runtime.get("compatibilityStatus") == "unsupported":
        raise FetchError("unsupported_runtime")
    adapter = ADAPTERS.get(runtime["adapterID"])
    if adapter is None:
        raise FetchError("unsupported_runtime")
    return adapter


def require_reset_runtime(provider, intent):
    runtime = runtime_info(provider)
    if not runtime["resetSupported"]:
        raise FetchError("reset_runtime_version_not_validated")
    if intent.get("runtimeVersion") != runtime["providerVersion"] or intent.get("adapterID") != runtime["adapterID"]:
        raise FetchError("reset_runtime_changed_review_again")
    return runtime


def emit(payload):
    if RESET_DIAGNOSTICS is not None:
        payload["diagnostics"] = RESET_DIAGNOSTICS
    print(json.dumps({"protocolVersion": COLLECTOR_PROTOCOL_VERSION, **payload}, allow_nan=False))


def number(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        return None
    return value if math.isfinite(value) else None


def timestamp(value):
    try:
        if isinstance(value, str):
            return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        return number(value)
    except (ValueError, OverflowError):
        return None


def text(value, fallback=""):
    return value[:160] if isinstance(value, str) else fallback


def fingerprint(*parts):
    if not all(isinstance(p, str) and p for p in parts):
        return None
    return hashlib.sha256("|".join(parts).encode()).hexdigest()


def window(identifier, title, scope, percent, resets, seconds=None):
    percent = number(percent)
    if percent is None or percent < 0 or percent > 100:
        return None
    return dict(id=identifier, title=title, scope=scope, usedPercent=percent,
                resetsAt=timestamp(resets), durationSeconds=number(seconds))


def duration_title(seconds, fallback):
    return {18000: "5-hour window", 604800: "Weekly window", 2592000: "30-day window"}.get(seconds, fallback)


def money(value):
    if not isinstance(value, dict):
        return None
    amount, exponent = number(value.get("amount_minor")), number(value.get("exponent"))
    if amount is None or exponent is None or not 0 <= exponent <= 6:
        return None
    return dict(amount=amount / 10 ** exponent, currency=text(value.get("currency"), "USD"))


def claude_extras(data):
    spend = data.get("spend")
    if isinstance(spend, dict):
        used, limit, balance = money(spend.get("used")), money(spend.get("limit")), money(spend.get("balance"))
        currency = (used or limit or balance or {}).get("currency", "USD")
        return dict(enabled=spend.get("enabled") if isinstance(spend.get("enabled"), bool) else None,
                    used=used["amount"] if used else None, limit=limit["amount"] if limit else None,
                    balance=balance["amount"] if balance else None, unit=currency,
                    usedPercent=number(spend.get("percent")), title="Extra usage · monthly")
    extra = data.get("extra_usage")
    if not isinstance(extra, dict):
        return None
    decimals = number(extra.get("decimal_places", 2))
    if decimals is None or not 0 <= decimals <= 6:
        return None
    used, cap = number(extra.get("used_credits")), number(extra.get("monthly_limit"))
    return dict(enabled=extra.get("is_enabled") if isinstance(extra.get("is_enabled"), bool) else None,
                used=used / 10 ** decimals if used is not None else None,
                limit=cap / 10 ** decimals if cap is not None else None,
                balance=None, unit=text(extra.get("currency"), "USD"),
                usedPercent=number(extra.get("utilization")), title="Extra usage · monthly")


def reset_presentation(grant):
    clears = grant.get("clears")
    clears = clears if isinstance(clears, list) and all(isinstance(k, str) for k in clears) else []
    label = text(grant.get("label"), text(grant.get("title"), ""))
    fable = "fable" in label.lower() and set(clears) == {"five_hour", "seven_day_overage_included"}
    full = "seven_day" in clears
    name = "Full reset" if full else "Fable reset" if fable else "Limit reset"
    names = {"five_hour": "your 5-hour limit", "seven_day": "your weekly limit",
             "seven_day_overage_included": "your Fable allowance" if fable else "your included model allowance"}
    detail = "Refills " + ", ".join(names.get(k, k) for k in clears) + "." if clears else "Reset scope is not supplied. Verify it in Claude."
    if grant.get("gives_back_weekly") is True:
        detail += " Gives back what Fable used on your weekly limit." if fable else " Gives back the affected model usage on your weekly limit."
    if clears and not full:
        detail += " It does not reset your whole week."
    usage = grant.get("percent_used")
    values = [number(usage.get(k)) for k in clears] if isinstance(usage, dict) else []
    complete = bool(clears) and len(values) == len(clears) and all(v is not None and 0 <= v <= 100 for v in values)
    nothing = complete and all(v == 0 for v in values)
    usable = grant.get("usable_now")
    if nothing:
        status = "Nothing to reset — there is no Fable or 5-hour usage right now." if fable else "Nothing to reset — all affected limits currently have zero usage."
        can_review = False
    elif usable is False:
        status = "Not usable now — Claude currently blocks this reset."
        reason = text(grant.get("unavailable_reason"))
        if reason:
            status += " Reason: " + reason
        can_review = False
    elif usable is True and complete:
        status, can_review = "Ready to use — affected usage is present.", True
    else:
        status, can_review = "Current usability is not fully known. Verify it in Claude.", True
    return dict(actionTitle=name, detail=detail, availabilityMessage=status, canReview=can_review)


def reset_binding(grant):
    fields = {k: grant.get(k) for k in ("id", "label", "clears", "ends_at", "resets_left", "gives_back_weekly")}
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


def claude_resets(data, now):
    block = data.get("cedar_ember")
    if not isinstance(block, dict):
        return dict(state="unavailable", message="Reset inventory not supplied by this source", items=[])
    if block.get("eligible") is not True:
        reason = text(block.get("ineligible_reason"), "not_eligible")
        return dict(state="ineligible", message="Provider eligibility: " + reason, items=[])
    grants = block.get("grants")
    if not isinstance(grants, list) or len(grants) > 200:
        return dict(state="unavailable", message="Unrecognized reset inventory", items=[])
    result = []
    malformed = False
    for i, grant in enumerate(grants):
        if not isinstance(grant, dict):
            malformed = True
            continue
        left, total = number(grant.get("resets_left")), number(grant.get("resets_total"))
        start, end = timestamp(grant.get("starts_at")), timestamp(grant.get("ends_at"))
        if (left is None or total is None or start is None or end is None
                or not isinstance(grant.get("paused"), bool) or left < 0 or left > total
                or int(left) != left or total > 50):
            malformed = True
            continue
        if grant["paused"] or not start <= now < end or left == 0:
            continue
        scope_names = {"five_hour": "5-hour window", "seven_day": "Weekly window",
                       "seven_day_overage_included": "Included model allowance"}
        clears = grant.get("clears")
        scope = " + ".join(scope_names.get(k, text(k)) for k in clears if isinstance(k, str)) if isinstance(clears, list) else "Review scope in Claude"
        result.append(dict(id=str(i), providerGrantID=grant.get("id") if isinstance(grant.get("id"), str) and re.fullmatch(r"[a-z0-9_-]{1,40}", grant["id"]) else None,
                           confirmationBinding=reset_binding(grant), title=text(grant.get("label"), text(grant.get("title"), "Claude limit reset")),
                           scope=scope,
                           count=int(left), expiresAt=end,
                           usableNow=grant.get("usable_now") if isinstance(grant.get("usable_now"), bool) else None,
                           **reset_presentation(grant)))
    if sum(r["count"] for r in result) > 50:
        return dict(state="unavailable", message="Unrecognized reset inventory", items=[])
    return dict(state="partial" if malformed else "available",
                message="Some reset records could not be read" if malformed else "Saved resets; redeem in Claude", items=result)


def normalize_claude(data, profile, now):
    windows = []
    for key, title, scope, seconds in [
        ("five_hour", "5-hour window", "All models", 18000),
        ("seven_day", "Weekly window", "All models", 604800),
        ("seven_day_sonnet", "Weekly window", "Sonnet", 604800),
        ("seven_day_opus", "Weekly window", "Opus", 604800),
        ("seven_day_cowork", "Weekly window", "Cowork", 604800)]:
        block = data.get(key)
        if key == "seven_day" and not isinstance(block, dict):
            block = data.get("seven_day_oauth_apps")
        if isinstance(block, dict):
            w = window(key, title, scope, block.get("utilization"), block.get("resets_at"), seconds)
            if w:
                windows.append(w)
    for i, item in enumerate(data.get("limits") or []):
        if not isinstance(item, dict) or item.get("kind") != "weekly_scoped":
            continue
        model = ((item.get("scope") or {}).get("model") or {})
        label = text(model.get("display_name"), "Model-specific")
        if label.lower() == "all models" or any(w["scope"] == label for w in windows):
            continue
        w = window("scoped-" + str(i), "Weekly window", label, item.get("percent"), item.get("resets_at"), 604800)
        if w:
            windows.append(w)
    account, org = profile.get("account") or {}, profile.get("organization") or {}
    offers = []
    for share in data.get("weekly_scoped_shares") or []:
        if not isinstance(share, dict):
            continue
        index, allowance = number(share.get("limit_index")), number(share.get("allowance_percent_of_weekly"))
        limits = data.get("limits") or []
        if index is None or int(index) != index or not 0 <= index < len(limits) or allowance is None:
            continue
        item = limits[int(index)]
        model = (((item.get("scope") or {}).get("model") or {}).get("display_name"))
        if isinstance(model, str):
            offers.append(dict(title=text(model) + " · included allowance",
                               detail=f"Up to {allowance:g}% of the shared weekly quota. Offer expiry is not supplied by this source.", expiresAt=None))
    # This block is a provider-reported cloud credit offer, not prepaid balance.
    cloud = data.get("iguana_necktie")
    if isinstance(cloud, dict):
        remaining = number(cloud.get("remaining_dollars"))
        if remaining is not None:
            offers.append(dict(title="Cloud-session credits", detail=f"USD {remaining:g} remaining",
                               expiresAt=timestamp(cloud.get("resets_at"))))
    return dict(provider="claude", accountKey=fingerprint("claude", account.get("uuid"), org.get("uuid")),
                plan=text(org.get("organization_type"), "Claude"), capturedAt=now, windows=windows,
                extra=claude_extras(data), resets=claude_resets(data, now), offers=offers,
                models=[], warnings=[])


def gpt_reset_binding(credit):
    fields = {k: credit.get(k) for k in ("id", "title", "reset_type", "expires_at", "status", "is_supported_by_plan")}
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


def gpt_reset_usage(usage):
    block = (usage or {}).get("rate_limit")
    if not isinstance(block, dict) or not isinstance(block.get("primary_window"), dict):
        return None
    values = []
    for key in ("primary_window", "secondary_window"):
        window = block.get(key)
        if window is None:
            continue
        value = number(window.get("used_percent")) if isinstance(window, dict) else None
        if value is None or not 0 <= value <= 100:
            return None
        values.append(value)
    return any(v > 0 for v in values) if values else None


def gpt_resets(data, now, usage=None):
    if not isinstance(data, dict) or not isinstance(data.get("credits"), list):
        return dict(state="unavailable", message="Reset inventory could not be read", items=[])
    result = []
    for i, credit in enumerate(data["credits"]):
        if not isinstance(credit, dict):
            continue
        expiry = timestamp(credit.get("expires_at"))
        if (credit.get("status") != "available" or credit.get("is_supported_by_plan") is not True
                or expiry is None or expiry <= now):
            continue
        supported = credit.get("reset_type") == "codex_rate_limits"
        has_usage = gpt_reset_usage(usage)
        credit_id = credit.get("id")
        valid_id = isinstance(credit_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,160}", credit_id)
        ready = supported and bool(valid_id) and has_usage is True
        message = ("Ready to use — affected usage is present." if ready else
                   "Nothing to reset — all reported Codex quota windows have zero usage." if supported and has_usage is False else
                   "Current usability or reset scope is not fully known. Refresh before using this reset.")
        result.append(dict(id=str(i), title=text(credit.get("title"), "Codex limit reset"),
                           actionTitle=text(credit.get("title"), "Codex limit reset"),
                           providerGrantID=credit_id if valid_id else None,
                           confirmationBinding=gpt_reset_binding(credit),
                           scope=text(credit.get("reset_type"), "Unknown reset scope"),
                           detail="Refills eligible Codex usage limits, including the weekly and 5-hour windows when present. Does not add purchased credits or enable paid usage." if supported else "This reset type is not supported for direct redemption.",
                           availabilityMessage=message, canReview=ready,
                           count=1, expiresAt=expiry, usableNow=ready))
    return dict(state="available", message="Saved resets; review in Codex", items=result)


def normalize_gpt(data, resets, now):
    windows = []
    limits = [("account", "All models", data.get("rate_limit"))]
    for i, item in enumerate(data.get("additional_rate_limits") or []):
        if isinstance(item, dict):
            limits.append(("model-" + str(i), text(item.get("limit_name"), text(item.get("metered_feature"), "Model-specific")), item.get("rate_limit")))
    for prefix, scope, block in limits:
        if not isinstance(block, dict):
            continue
        for key, fallback in [("primary_window", "Primary window"), ("secondary_window", "Secondary window")]:
            value = block.get(key)
            if isinstance(value, dict):
                seconds = number(value.get("limit_window_seconds"))
                reset = value.get("reset_at")
                if reset is None and number(value.get("reset_after_seconds")) is not None:
                    reset = now + value["reset_after_seconds"]
                w = window(prefix + key, duration_title(seconds, fallback), scope, value.get("used_percent"), reset, seconds)
                if w:
                    windows.append(w)
    credits = data.get("credits")
    extra = None
    if isinstance(credits, dict):
        try:
            balance = float(credits.get("balance"))
            if not math.isfinite(balance):
                balance = None
        except (ValueError, TypeError):
            balance = None
        extra = dict(title="Codex credits", enabled=credits.get("has_credits"), used=None, limit=None,
                     balance=balance, unit="credits", usedPercent=None)
    models = []
    for model, value in (data.get("model_usage") or {}).items():
        if isinstance(value, dict):
            models.append(dict(name=text(model), available=value.get("available") if isinstance(value.get("available"), bool) else None,
                               availableAt=timestamp(value.get("available_at"))))
    return dict(provider="gptmock", accountKey=fingerprint("gptmock", data.get("user_id"), data.get("account_id")),
                plan=text(data.get("plan_type"), "Codex"), capturedAt=now, windows=windows,
                extra=extra, resets=gpt_resets(resets, now, data), offers=[], models=models, warnings=[])


class FetchError(Exception):
    def __init__(self, code, retry_after=None):
        self.code, self.retry_after = code, retry_after


def request(url, headers):
    try:
        req = urllib.request.Request(url, headers={**headers, "Cache-Control": "no-cache"})
        with urllib.request.urlopen(req, timeout=15) as response:
            data = json.loads(response.read(2_000_000))
        if not isinstance(data, dict):
            raise FetchError("invalid_response")
        return data
    except urllib.error.HTTPError as error:
        retry = error.headers.get("Retry-After", "")
        raise FetchError("http_" + str(error.code), int(retry) if retry.isdigit() else None) from None
    except (urllib.error.URLError, TimeoutError):
        raise FetchError("network_error") from None


def claude_headers(now):
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    with open(os.path.join(home, ".credentials.json")) as f:
        auth = json.load(f).get("claudeAiOauth") or {}
    token = auth.get("accessToken")
    if not token:
        raise FetchError("missing_credentials")
    expires = number(auth.get("expiresAt"))
    if expires is not None and expires / 1000 <= now:
        raise FetchError("credentials_expired")
    # Query the installed owner; do not impersonate an invented CLI release.
    version = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=8)
    match = re.search(r"\b\d+\.\d+\.\d+\b", version.stdout)
    headers = {"Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"}
    if match:
        headers["User-Agent"] = "claude-cli/" + match.group(0) + " (external, cli)"
    return headers


def gpt_headers():
    # Delegate renewal to GPTMock's existing lock-aware credential owner.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from gptmock.infra.auth import load_chatgpt_tokens
        token, account, _ = asyncio.run(load_chatgpt_tokens())
    if not token or not account:
        raise FetchError("missing_credentials")
    headers = {"Authorization": "Bearer " + token, "ChatGPT-Account-Id": account, "User-Agent": "MockUsage/0.1"}
    return headers


def claude_preflight_cache_path():
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(home, "mockusage-preflight.json")


def save_claude_preflight(data, profile, headers, captured_at):
    """Container-local, short-lived usage proof; never export credentials."""
    account = profile.get("account") or {}
    org = profile.get("organization") or {}
    identity = fingerprint("claude", account.get("uuid"), org.get("uuid"))
    if not identity or not headers.get("Authorization") or not isinstance(data.get("cedar_ember"), dict):
        return
    path = claude_preflight_cache_path()
    temporary = None
    try:
        payload = dict(capturedAt=captured_at, accountKey=identity,
                       credentialFingerprint=hashlib.sha256(headers["Authorization"].encode()).hexdigest(),
                       runtimeVersion=detect_runtime_version("claude"), data={"cedar_ember": data["cedar_ember"]})
        with tempfile.NamedTemporaryFile(mode="w", dir=os.path.dirname(path), prefix=".mockusage-preflight-", delete=False) as file:
            temporary = file.name
            json.dump(payload, file)
        os.replace(temporary, path)
    except (OSError, TypeError, ValueError):
        pass  # Cache failure must never break read-only monitoring.
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def load_claude_preflight(intent, profile, headers, now):
    try:
        with open(claude_preflight_cache_path()) as file:
            cached = json.load(file)
        identity = fingerprint("claude", (profile.get("account") or {}).get("uuid"), (profile.get("organization") or {}).get("uuid"))
        captured = number(cached.get("capturedAt"))
        if (captured is None or not 0 <= now - captured <= 15 or not identity
                or identity != intent.get("accountKey") or cached.get("accountKey") != identity
                or cached.get("runtimeVersion") != intent.get("runtimeVersion")
                or not headers.get("Authorization")
                or cached.get("credentialFingerprint") != hashlib.sha256(headers["Authorization"].encode()).hexdigest()):
            return None
        data = cached.get("data")
        if isinstance(data, dict) and isinstance(data.get("cedar_ember"), dict):
            reset_event("usage", outcome="fresh_container_cache", seconds=int(now-captured))
            return data
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return None


def clear_claude_preflight():
    try:
        os.unlink(claude_preflight_cache_path())
    except OSError:
        pass


def collect_claude_v1():
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    headers = claude_headers(now)
    try:
        data = request("https://api.anthropic.com/api/oauth/usage?cedar_ember=1", headers)
    except FetchError as error:
        if error.code not in ("http_400", "http_403"):
            raise
        data = request("https://api.anthropic.com/api/oauth/usage", headers)
    profile = {}
    try:
        profile = request("https://api.anthropic.com/api/oauth/profile", headers)
    except FetchError:
        pass
    result = normalize_claude(data, profile, now)
    save_claude_preflight(data, profile, headers, now)
    return result


def collect_gpt_v1():
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    headers = gpt_headers()
    data = request("https://chatgpt.com/backend-api/wham/usage", headers)
    resets = None
    try:
        resets = request("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers)
    except FetchError:
        pass
    result = normalize_gpt(data, resets, now)
    return result


def collect(provider, runtime=None):
    runtime = runtime if runtime is not None else runtime_info(provider)
    result = selected_adapter(runtime).collect()
    if not result["accountKey"]:
        result["warnings"].append("Account identity unavailable; this source is not merged with other containers")
    result["runtime"] = runtime
    if not runtime["resetSupported"]:
        for grant in result["resets"]["items"]:
            grant.update(usableNow=False, canReview=False,
                         availabilityMessage="Direct reset disabled: runtime " + runtime["providerVersion"] + " has not been validated by this app version.")
    return result


class NoResetRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post_reset(org, grant_id, request_id, headers):
    # Never retry or follow redirects for this consumable action.
    payload = dict(program="cedar_ember", grant_id=grant_id, request_id=request_id)
    req = urllib.request.Request(
        "https://api.anthropic.com/api/organizations/" + org + "/reset_rate_limits",
        data=json.dumps(payload).encode(), method="POST",
        headers={**headers, "Content-Type": "application/json"})
    try:
        reset_event("post_attempt", outcome="single_attempt")
        with urllib.request.build_opener(NoResetRedirect()).open(req, timeout=25) as response:
            status = response.status
            data = json.loads(response.read(100_000))
        result = data.get("result") if isinstance(data, dict) else None
        known = {"reset", "already_used", "not_limited", "cooldown", "ineligible", "unavailable"}
        reason = data.get("reason") if isinstance(data, dict) else None
        reasons = {"cooldown", "paused", "expired", "unknown_grant", "not_next_grant", "grant_id_required", "not_limited", "already_used", "stamp_indeterminate", "reset_unconfirmed", "unavailable", "cli_version", "surface", "seat", "tier", "needs_limit"}
        reset_event("post_response", httpStatus=status if isinstance(status, int) else None,
                    outcome=result if result in known else "unknown_response", reason=reason if reason in reasons else None)
        return result if result in known else "uncertain"
    except urllib.error.HTTPError as error:
        reset_event("post_response", httpStatus=error.code, outcome="http_error")
        # Auth/rate-limit rejections are explicit; all other errors remain uncertain.
        return "rate_limited" if error.code == 429 else "auth_error" if error.code in (401, 403) else "uncertain"
    except Exception:
        reset_event("post_response", outcome="transport_or_schema_error")
        return "uncertain"


def validate_reset(intent, profile, data, now):
    account, org = profile.get("account") or {}, profile.get("organization") or {}
    identity = fingerprint("claude", account.get("uuid"), org.get("uuid"))
    if not identity or identity != intent.get("accountKey"):
        raise FetchError("reset_account_changed")
    organization = org.get("uuid")
    if not isinstance(organization, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", organization):
        raise FetchError("reset_identity_unavailable")
    issued = number(intent.get("confirmedAt"))
    if issued is None or not 0 <= now - issued <= 120:
        raise FetchError("reset_confirmation_expired")
    block = data.get("cedar_ember") or {}
    cooldown = timestamp(block.get("cooldown_until"))
    if cooldown is not None and cooldown > now:
        raise FetchError("reset_cooldown")
    items = claude_resets(data, now)["items"]
    matches = [g for g in items if g.get("providerGrantID") == intent.get("grantID") and g.get("providerGrantID")]
    if len(matches) != 1:
        raise FetchError("reset_no_longer_available")
    grant = matches[0]
    if grant["confirmationBinding"] != intent.get("binding"):
        raise FetchError("reset_changed_review_again")
    if grant.get("usableNow") is not True or not grant["availabilityMessage"].startswith("Ready to use"):
        raise FetchError("reset_not_usable_or_nothing_to_reset")
    raw = next(g for g in block["grants"] if g.get("id") == intent["grantID"])
    if raw.get("blocking"):
        raise FetchError("reset_blocked")
    return organization


def redeem_claude_v1(intent):
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    headers = claude_headers(now)
    # Identity and grant selection are refreshed inside the same container.
    budget = {"waited": False}
    profile = reset_preflight_request("https://api.anthropic.com/api/oauth/profile", headers, budget, "profile")
    data = load_claude_preflight(intent, profile, headers, dt.datetime.now(dt.timezone.utc).timestamp())
    if data is None:
        data = reset_preflight_request("https://api.anthropic.com/api/oauth/usage?cedar_ember=1", headers, budget, "usage")
    # Evaluate confirmation age and grant expiry AFTER any network wait.
    org = validate_reset(intent, profile, data, dt.datetime.now(dt.timezone.utc).timestamp())
    reset_event("validated", outcome="account_grant_usage_match")
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    try:
        return submit_once(home, intent, lambda request_id: post_reset(org, intent["grantID"], request_id, headers))
    finally:
        clear_claude_preflight()


def submit_once(home, intent, submit):
    journal = os.path.join(home, "mockusage-reset-journal")
    os.makedirs(journal, mode=0o700, exist_ok=True)
    key = hashlib.sha256((intent["accountKey"] + intent["binding"]).encode()).hexdigest()
    # Durable reservation prevents concurrent sends and retries after an unknown
    # result, including across app restarts. Contains no tokens or raw identity.
    path = os.path.join(journal, key)
    with open(os.path.join(journal, "lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if os.path.exists(path):
            reset_event("journal", outcome="duplicate_blocked")
            return dict(result="uncertain", message="This reset was already submitted. Refresh usage; it will not be sent again.")
        request_id = str(uuid.uuid4())
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as record:
            json.dump({"requestID": request_id, "state": "submitted"}, record)
            record.flush()
            os.fsync(record.fileno())
        directory_fd = os.open(journal, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        result = submit(request_id)
        with open(path, "w") as record:
            json.dump({"requestID": request_id, "state": result}, record)
            record.flush()
            os.fsync(record.fileno())
        if result not in {"reset", "already_used", "uncertain"}:
            os.unlink(path)
        return dict(result=result)


def validate_gpt_reset(intent, usage, credits, account, now):
    identity = fingerprint("gptmock", usage.get("user_id"), usage.get("account_id"))
    if not identity or identity != intent.get("accountKey") or usage.get("account_id") != account:
        raise FetchError("reset_account_changed")
    issued = number(intent.get("confirmedAt"))
    if issued is None or not 0 <= now - issued <= 120:
        raise FetchError("reset_confirmation_expired")
    matches = [g for g in gpt_resets(credits, now, usage)["items"]
               if g.get("providerGrantID") and g["providerGrantID"] == intent.get("grantID")]
    if len(matches) != 1:
        raise FetchError("reset_no_longer_available")
    grant = matches[0]
    if grant["confirmationBinding"] != intent.get("binding"):
        raise FetchError("reset_changed_review_again")
    if grant["usableNow"] is not True:
        raise FetchError("reset_not_usable_or_nothing_to_reset")


def post_gpt_reset(credit_id, request_id, headers):
    payload = dict(credit_id=credit_id, redeem_request_id=request_id)
    req = urllib.request.Request("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume",
        data=json.dumps(payload).encode(), method="POST", headers={**headers, "Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(NoResetRedirect()).open(req, timeout=25) as response:
            data = json.loads(response.read(100_000))
        if not isinstance(data, dict):
            return "uncertain"
        code = data.get("code")
        if code == "reset":
            windows = number(data.get("windows_reset"))
            return "reset" if windows is not None and windows > 0 else "uncertain"
        return {"nothing_to_reset": "not_limited", "no_credit": "unavailable", "already_redeemed": "already_used"}.get(code, "uncertain")
    except Exception:
        return "uncertain"


def redeem_gpt_v1(intent):
    headers = gpt_headers()
    usage = request("https://chatgpt.com/backend-api/wham/usage", headers)
    credits = request("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers)
    validate_gpt_reset(intent, usage, credits, headers["ChatGPT-Account-Id"], dt.datetime.now(dt.timezone.utc).timestamp())
    from gptmock.infra.auth import get_home_dir
    return submit_once(get_home_dir(), intent, lambda request_id: post_gpt_reset(intent["grantID"], request_id, headers))


def parse_gpt_models(data, usage, local_models):
    raw = data.get("models")
    if not isinstance(raw, list) or not raw or len(raw) > 500:
        raise FetchError("invalid_model_catalog")
    result = {}
    for model in raw:
        if not isinstance(model, dict) or model.get("visibility") != "list":
            continue
        name = model.get("slug")
        if not isinstance(name, str) or not name or len(name) > 200:
            continue
        plans = model.get("available_in_plans")
        available = usage.get("plan_type") in plans if isinstance(plans, list) and usage.get("plan_type") else None
        if model.get("allow_only_codex_cloud_agent_orchestrator") or model.get("allow_only_chatgpt_workspace_executor"):
            available = None
        note = "Account catalog; no inference test. "
        if local_models is None:
            note += "Container model support is unknown."
        elif name not in local_models:
            note += "Not listed in this GPTMock container’s registry; container update may be required."
        else:
            note += "Listed in the GPTMock container registry."
        result[name] = dict(name=name, available=available, containerSupported=name in local_models if local_models is not None else None, note=note)
    if not result:
        raise FetchError("empty_model_catalog")
    return list(result.values())


def parse_claude_models(raw, bootstrap):
    result = {}
    for model in raw:
        if not isinstance(model, dict):
            continue
        name = model.get("id")
        if isinstance(name, str) and 0 < len(name) <= 200:
            result[name] = dict(name=name, available=None, note="Listed by the provider API; Claude Code account access is not confirmed.")
    for model in (bootstrap or {}).get("additional_model_options") or []:
        if not isinstance(model, dict):
            continue
        name = model.get("model")
        if not isinstance(name, str) or not 0 < len(name) <= 200:
            continue
        name = name.split("[")[0]
        # Missing disabled_reason is not an affirmative access signal.
        available = None if "disabled_reason" not in model else model["disabled_reason"] is None
        result[name] = dict(name=name, available=available,
            note="Claude Code account option." if available else "Claude Code option is disabled or its availability is unknown.")
    if not result:
        raise FetchError("empty_model_catalog")
    return list(result.values())


def models_gpt_v1(client_version):
    provider = "gptmock"
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    headers = gpt_headers()
    usage = request("https://chatgpt.com/backend-api/wham/usage", headers)
    identity = fingerprint(provider, usage.get("user_id"), usage.get("account_id"))
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.\-]*", client_version):
        raise FetchError("installed_codex_version_unavailable")
    data = request("https://chatgpt.com/backend-api/codex/models?client_version=" + urllib.parse.quote(client_version), headers)
    try:
        from gptmock.services.model_registry import MODEL_GROUPS
        local_models = {item[0] for item in MODEL_GROUPS}
    except (ImportError, TypeError):
        local_models = None
    entries = parse_gpt_models(data, usage, local_models)
    if not identity:
        raise FetchError("model_account_identity_unavailable")
    return dict(accountKey=identity, entries=entries, checkedAt=now)


def models_claude_v1(client_version):
    provider = "claude"
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    headers = claude_headers(now)
    profile = request("https://api.anthropic.com/api/oauth/profile", headers)
    identity = fingerprint(provider, (profile.get("account") or {}).get("uuid"), (profile.get("organization") or {}).get("uuid"))
    headers["anthropic-version"] = "2023-06-01"
    raw, after = [], None
    for _ in range(5):
        url = "https://api.anthropic.com/v1/models?limit=100" + ("&after_id=" + urllib.parse.quote(after) if after else "")
        page = request(url, headers)
        if not isinstance(page.get("data"), list):
            raise FetchError("invalid_model_catalog")
        raw.extend(page["data"])
        if page.get("has_more") is not True:
            break
        next_id = page.get("last_id")
        if not isinstance(next_id, str) or not next_id or next_id == after:
            raise FetchError("invalid_model_pagination")
        after = next_id
    else:
        raise FetchError("model_catalog_too_large")
    try:
        bootstrap = request("https://api.anthropic.com/api/claude_cli/bootstrap?entrypoint=cli", headers)
    except FetchError:
        bootstrap = {}
    entries = parse_claude_models(raw, bootstrap)
    if not identity:
        raise FetchError("model_account_identity_unavailable")
    return dict(accountKey=identity, entries=entries, checkedAt=now)


class CodexWhamV1Adapter:
    provider = "gptmock"

    def collect(self):
        return collect_gpt_v1()

    def models(self, client_version):
        return models_gpt_v1(client_version)

    def redeem(self, intent):
        return redeem_gpt_v1(intent)


class ClaudeOAuthV1Adapter:
    provider = "claude"

    def collect(self):
        return collect_claude_v1()

    def models(self, client_version):
        return models_claude_v1(client_version)

    def redeem(self, intent):
        return redeem_claude_v1(intent)


ADAPTERS = {
    "codex-wham-v1": CodexWhamV1Adapter(),
    "claude-oauth-v1": ClaudeOAuthV1Adapter(),
}


def collect_models(provider, client_version, runtime=None):
    runtime = runtime if runtime is not None else runtime_info(provider)
    return selected_adapter(runtime).models(client_version)


def redeem_reset(intent):
    runtime = require_reset_runtime("claude", intent)
    return selected_adapter(runtime).redeem(intent)


def redeem_gpt_reset(intent):
    runtime = require_reset_runtime("gptmock", intent)
    return selected_adapter(runtime).redeem(intent)


def main():
    global RESET_DIAGNOSTICS
    RESET_DIAGNOSTICS = [] if len(sys.argv) == 4 and sys.argv[2] == "--confirmed-reset" else None
    runtime = None
    try:
        runtime = runtime_info(sys.argv[1])
        if len(sys.argv) == 4 and sys.argv[2] == "--models":
            emit(dict(catalog=collect_models(sys.argv[1], sys.argv[3], runtime)))
            return
        if len(sys.argv) == 4 and sys.argv[1] in {"claude", "gptmock"} and sys.argv[2] == "--confirmed-reset":
            intent = json.loads(base64.b64decode(sys.argv[3], validate=True))
            emit(redeem_reset(intent) if sys.argv[1] == "claude" else redeem_gpt_reset(intent))
            return
        result = collect(sys.argv[1], runtime)
        emit(dict(snapshot=result))
    except FetchError as error:
        emit(dict(error=error.code, retryAfter=error.retry_after, runtime=runtime))
    except FileNotFoundError:
        emit(dict(error="missing_credentials_or_runtime", runtime=runtime))
    except Exception:
        # Do not expose exception strings, raw responses, headers, or credentials.
        emit(dict(error="collector_error", runtime=runtime))


if __name__ == "__main__":
    main()
