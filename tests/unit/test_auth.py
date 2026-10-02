"""
Unit tests for the session token scheme in auth.py.

These are the tests that matter for NFR security claims: a bearer token is the
only thing standing between a caller and another passenger's booking, so the
signature check and the expiry check are tested directly rather than through
the API.
"""

import json
import time

import pytest

from kestrel.api import auth


class TestTokenRoundTrip:
    def test_issued_token_decodes_to_the_same_session(self, session_kwargs):
        token, ttl = auth.issue_token(**session_kwargs)
        session = auth._decode_token(token)

        assert session.pnr_code == session_kwargs["pnr_code"]
        assert session.passenger_id == session_kwargs["passenger_id"]
        assert session.last_name == session_kwargs["last_name"]
        assert session.rewards_tier == session_kwargs["rewards_tier"]
        assert ttl == auth.TOKEN_TTL_SECONDS

    def test_token_has_payload_and_signature_segments(self, session_kwargs):
        token, _ = auth.issue_token(**session_kwargs)
        assert token.count(".") == 1


class TestTamperResistance:
    """A forged or altered token must be rejected, not merely mis-parsed."""

    def test_altered_payload_is_rejected(self, session_kwargs):
        token, _ = auth.issue_token(**session_kwargs)
        payload_b64, signature = token.split(".")

        payload = json.loads(auth._b64url_decode(payload_b64))
        payload["pnr_code"] = "AAAAAA"  # someone else's booking
        forged_b64 = auth._b64url_encode(json.dumps(payload, separators=(",", ":")).encode())

        with pytest.raises(ValueError):
            auth._decode_token(f"{forged_b64}.{signature}")

    def test_altered_signature_is_rejected(self, session_kwargs):
        token, _ = auth.issue_token(**session_kwargs)
        payload_b64, signature = token.split(".")
        flipped = ("A" if signature[0] != "A" else "B") + signature[1:]

        with pytest.raises(ValueError):
            auth._decode_token(f"{payload_b64}.{flipped}")

    @pytest.mark.parametrize(
        "bad_token",
        ["", "not-a-token", "only-one-segment", "a.b.c", "....", "."],
    )
    def test_malformed_tokens_raise_valueerror(self, bad_token):
        with pytest.raises(ValueError):
            auth._decode_token(bad_token)


class TestExpiry:
    def test_expired_token_is_rejected(self, session_kwargs, monkeypatch):
        # Issue a token, then move the clock past its expiry. real_time is
        # captured first: auth.py does `import time` and calls time.time(),
        # so patching that attribute replaces the function the lambda would
        # otherwise call recursively.
        token, ttl = auth.issue_token(**session_kwargs)
        real_time = time.time
        monkeypatch.setattr(auth.time, "time", lambda: real_time() + ttl + 1)

        with pytest.raises(ValueError):
            auth._decode_token(token)

    def test_token_valid_just_before_expiry(self, session_kwargs, monkeypatch):
        token, ttl = auth.issue_token(**session_kwargs)
        real_time = time.time
        monkeypatch.setattr(auth.time, "time", lambda: real_time() + ttl - 5)

        assert auth._decode_token(token).pnr_code == session_kwargs["pnr_code"]


class TestLoginThrottling:
    """Brute-forcing a surname against a known PNR must be rate limited."""

    def setup_method(self):
        auth._failed_attempts.clear()

    def test_not_throttled_below_the_limit(self):
        for _ in range(auth.MAX_FAILED_ATTEMPTS - 1):
            auth.register_failed_attempt("S958PC")
        assert auth.is_throttled("S958PC") is False

    def test_throttled_at_the_limit(self):
        for _ in range(auth.MAX_FAILED_ATTEMPTS):
            auth.register_failed_attempt("S958PC")
        assert auth.is_throttled("S958PC") is True

    def test_successful_login_clears_the_counter(self):
        for _ in range(auth.MAX_FAILED_ATTEMPTS):
            auth.register_failed_attempt("S958PC")
        auth.clear_attempts("S958PC")
        assert auth.is_throttled("S958PC") is False

    def test_throttling_is_case_and_whitespace_insensitive(self):
        """Otherwise ' s958pc ' is a free extra five attempts."""
        for _ in range(auth.MAX_FAILED_ATTEMPTS):
            auth.register_failed_attempt("S958PC")
        assert auth.is_throttled("  s958pc  ") is True

    def test_throttle_is_per_pnr(self):
        for _ in range(auth.MAX_FAILED_ATTEMPTS):
            auth.register_failed_attempt("S958PC")
        assert auth.is_throttled("X111AA") is False

    def test_old_attempts_fall_out_of_the_window(self, monkeypatch):
        for _ in range(auth.MAX_FAILED_ATTEMPTS):
            auth.register_failed_attempt("S958PC")
        real_time = time.time
        monkeypatch.setattr(
            auth.time,
            "time",
            lambda: real_time() + auth.THROTTLE_WINDOW_SECONDS + 1,
        )
        assert auth.is_throttled("S958PC") is False
