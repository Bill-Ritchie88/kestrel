"""
Request model tests.

The point of these is the boundary values in main.py's Field constraints. A
PNR is six characters in this dataset, but the model accepts 5-8 so that other
record-locator formats do not 422 at the edge of the range.
"""

import pytest
from pydantic import ValidationError

from main import AuthRequest, ReaccommodateRequest


class TestAuthRequest:
    def test_accepts_a_valid_pnr_and_surname(self):
        req = AuthRequest(pnr_code="S958PC", last_name="Whitehead")
        assert req.pnr_code == "S958PC"

    @pytest.mark.parametrize("pnr", ["ABCDE", "ABCDEFGH"])
    def test_accepts_the_boundary_lengths(self, pnr):
        AuthRequest(pnr_code=pnr, last_name="Otieno")

    @pytest.mark.parametrize("pnr", ["ABCD", "ABCDEFGHI", ""])
    def test_rejects_out_of_range_pnr(self, pnr):
        with pytest.raises(ValidationError):
            AuthRequest(pnr_code=pnr, last_name="Otieno")

    def test_rejects_empty_surname(self):
        with pytest.raises(ValidationError):
            AuthRequest(pnr_code="S958PC", last_name="")

    def test_rejects_surname_over_80_characters(self):
        with pytest.raises(ValidationError):
            AuthRequest(pnr_code="S958PC", last_name="A" * 81)


class TestReaccommodateRequest:
    def test_carries_only_the_target_flight(self):
        """
        Regression guard for the privilege escalation fix.

        pnr_code and agent_id must NOT be accepted from the request body: the
        PNR comes from the session and the actor is derived server-side, or
        the audit trail written by reaccommodate_passenger_atomic is forgeable.
        """
        assert set(ReaccommodateRequest.model_fields) == {"target_flight_id"}

    def test_requires_a_target_flight_id(self):
        with pytest.raises(ValidationError):
            ReaccommodateRequest()
