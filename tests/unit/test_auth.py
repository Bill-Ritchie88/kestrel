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


def test_the_login_limit_dictionary_does_not_keep_every_guess(monkeypatch):
    """Issue #36: a key with no recent attempt is dropped; checking a booking
    stores nothing."""
    from kestrel.api import auth

    auth._failed_attempts.clear()
    for i in range(50):
        auth.is_throttled(f"NOPE{i:02d}")
    assert auth._failed_attempts == {}
    monkeypatch.setattr(auth, "_SWEEP_ABOVE", 10)
    old = __import__("time").time() - auth.THROTTLE_WINDOW_SECONDS - 1
    for i in range(10):
        auth._failed_attempts[f"OLD{i}"] = [old]
    auth.register_failed_attempt("NEW001")
    assert set(auth._failed_attempts) == {"NEW001"}
    auth._failed_attempts.clear()


# -- FR-17 rebooking confirmation tokens ----------------------------------------

FLIGHT = "0B6F4A3C-1E2D-4F5A-8B9C-7D6E5F4A3B2C"
SEAT = "5f0c3e1a-8d2b-4c6e-9a1f-0b7d2e4c6a88"


def _verify(token, pnr_code="S958PC", flight_id=FLIGHT, seat_id=None):
    return auth.verify_confirmation(token, pnr_code=pnr_code, flight_id=flight_id, seat_id=seat_id)


@pytest.fixture
def confirmation():
    auth._used_confirmations.clear()
    token, ttl = auth.issue_confirmation(pnr_code="S958PC", flight_id=FLIGHT, seat_id=None)
    assert ttl == auth.CONFIRMATION_TTL_SECONDS == 300
    return token


class TestConfirmationToken:
    def test_verifies_for_its_own_booking_flight_and_seat_choice(self, confirmation):
        assert _verify(confirmation, flight_id=FLIGHT.lower())

    @pytest.mark.parametrize(
        ("kwargs", "reason"),
        [
            ({"pnr_code": "OTHER1"}, "another booking"),
            ({"flight_id": "f-other"}, "another flight"),
            ({"seat_id": SEAT}, "another seat"),
        ],
    )
    def test_refused_for_any_other_rebooking(self, confirmation, kwargs, reason):
        with pytest.raises(ValueError, match=reason):
            _verify(confirmation, **kwargs)

    def test_bound_to_a_chosen_seat(self):
        token, _ = auth.issue_confirmation(pnr_code="S958PC", flight_id=FLIGHT, seat_id=SEAT)
        assert _verify(token, seat_id=SEAT.upper())
        with pytest.raises(ValueError, match="another seat"):
            _verify(token, seat_id=None)

    def test_tampered_payload_is_refused(self, confirmation):
        payload_b64, sig = confirmation.split(".")
        payload = json.loads(auth._b64url_decode(payload_b64))
        payload["flight"] = "f-other"
        forged = auth._b64url_encode(json.dumps(payload).encode()) + "." + sig
        with pytest.raises(ValueError, match="Invalid"):
            _verify(forged, flight_id="f-other")

    @pytest.mark.parametrize("token", ["", "no-dot", "a.b.c"])
    def test_malformed_is_refused(self, token):
        with pytest.raises(ValueError):
            _verify(token)

    def test_expired_is_refused(self, monkeypatch, confirmation):
        real_time = time.time
        monkeypatch.setattr(auth.time, "time", lambda: real_time() + auth.CONFIRMATION_TTL_SECONDS + 1)
        with pytest.raises(ValueError, match="expired"):
            _verify(confirmation)

    def test_replay_after_use_is_refused(self, confirmation):
        auth.spend_confirmation(_verify(confirmation))
        with pytest.raises(ValueError, match="already been used"):
            _verify(confirmation)

    def test_a_session_token_is_not_a_confirmation_and_vice_versa(self, confirmation):
        session_token, _ = auth.issue_token(
            pnr_code="S958PC", passenger_id="p-1", last_name="Whitehead", rewards_tier=None
        )
        with pytest.raises(ValueError, match="Invalid"):
            _verify(session_token)
        with pytest.raises(ValueError, match="signature"):
            auth._decode_token(confirmation)
