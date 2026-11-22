"""
Compensation and refund claims (migration 016).

The rules engine says what a booking is owed (R4 cash compensation); a claim
is the passenger asking for it, and staff approving or rejecting it and then
recording the payout. The states and their order are enforced by the
database (trg_compensation_claim_guard), which also writes every change to
audit_logs; each UPDATE below names the state it expects, so a stale click
changes nothing and the REST tier answers 409.
"""

from __future__ import annotations

# The SQL below is assembled from this constant column list only; every value
# is a bind parameter, so S608 (string-built SQL) does not apply.
_COLUMNS = """claim_id, pnr_code, kind, status, amount, currency, rule_id, basis, claimed_by,
    decided_by, reason, paid_by, payout_reference, created_at, decided_at, paid_at"""

SQL_CLAIMS_FOR_PNR = f"""
    SELECT {_COLUMNS} FROM compensation_claims WHERE pnr_code = $1 ORDER BY created_at;
"""  # noqa: S608

# One compensation claim per booking: a second tap returns no row (409).
SQL_INSERT_CLAIM = f"""
    INSERT INTO compensation_claims (pnr_code, kind, amount, currency, rule_id, basis, claimed_by)
    VALUES ($1, 'COMPENSATION', $2, $3, $4, $5, $6)
    ON CONFLICT (pnr_code, kind) DO NOTHING
    RETURNING {_COLUMNS};
"""  # noqa: S608

# Staff only: newest first, with the passenger's name.
SQL_LIST_CLAIMS = f"""
    SELECT {", ".join("c." + col.strip() for col in _COLUMNS.split(","))},
           p.first_name, p.last_name, b.booking_status::text AS booking_status
    FROM compensation_claims c
    JOIN pnr_bookings b ON b.pnr_code = c.pnr_code
    JOIN passengers p ON p.passenger_id = b.passenger_id
    WHERE ($1::text IS NULL OR c.status = $1)
    ORDER BY c.created_at DESC
    LIMIT $2;
"""  # noqa: S608

SQL_APPROVE = f"""
    UPDATE compensation_claims SET status = 'APPROVED', decided_by = $2, decided_at = now()
    WHERE claim_id = $1 AND status = 'CLAIMED'
    RETURNING {_COLUMNS};
"""  # noqa: S608

SQL_REJECT = f"""
    UPDATE compensation_claims SET status = 'REJECTED', decided_by = $2, reason = $3, decided_at = now()
    WHERE claim_id = $1 AND status = 'CLAIMED'
    RETURNING {_COLUMNS};
"""  # noqa: S608

SQL_PAY = f"""
    UPDATE compensation_claims SET status = 'PAID', paid_by = $2, payout_reference = $3, paid_at = now()
    WHERE claim_id = $1 AND status = 'APPROVED'
    RETURNING {_COLUMNS};
"""  # noqa: S608

SQL_CLAIM_STATUS = "SELECT status FROM compensation_claims WHERE claim_id = $1;"

SQL_CANCEL_FOR_REFUND = "SELECT * FROM cancel_booking_for_refund($1, $2, $3);"


def claim_to_dict(row) -> dict:
    def iso(key):
        return row[key].isoformat() if row[key] else None

    return {
        "claim_id": row["claim_id"],
        "pnr_code": row["pnr_code"],
        "kind": row["kind"],
        "status": row["status"],
        "amount": float(row["amount"]) if row["amount"] is not None else None,
        "currency": row["currency"],
        "rule_id": row["rule_id"],
        "basis": row["basis"],
        "claimed_by": row["claimed_by"],
        "decided_by": row["decided_by"],
        "reason": row["reason"],
        "paid_by": row["paid_by"],
        "payout_reference": row["payout_reference"],
        "created_at": iso("created_at"),
        "decided_at": iso("decided_at"),
        "paid_at": iso("paid_at"),
        # Staff list only.
        "passenger": (
            {"first_name": row["first_name"], "last_name": row["last_name"]} if row.get("last_name") else None
        ),
        "booking_status": row.get("booking_status"),
    }
