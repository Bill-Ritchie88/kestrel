"""
Hand-off cases (FR-05, FR-09).

A case is the system admitting that a decision needs a person: a policy
question it cannot ground (best similarity below tau), a passenger with no
alternative flight in their cabin, an agent that ran out of steps, or a
passenger who asked for a human. The case carries enough context (PNR,
booking status, question, similarity scores, summary) that a desk agent does
not have to start again.
"""

from __future__ import annotations

import json

TRIGGERS = frozenset(
    {"LOW_SIMILARITY", "NO_ALTERNATIVES", "STEP_LIMIT", "REBOOKING_FAILED", "PASSENGER_REQUEST"}
)
# Triggers a passenger session may raise directly. LOW_SIMILARITY is only ever
# raised by the REST tier itself, from a real retrieval result.
PASSENGER_TRIGGERS = TRIGGERS - {"LOW_SIMILARITY"}

# The SQL below is assembled from this constant column list only; every value
# is a bind parameter ($1, $2 ...), so S608 (string-built SQL) does not apply.
_COLUMNS = """case_id, pnr_code, trigger, booking_status, question, top_similarity,
    similarity_scores, summary, status, created_at, resolved_at, resolved_by, resolution_note"""

# One OPEN case per booking and trigger: a passenger who asks three
# out-of-scope questions in a row gets one case with the latest question,
# not three tickets for the same desk agent.
SQL_FIND_OPEN = f"""
    SELECT {_COLUMNS} FROM handoff_cases
    WHERE pnr_code = $1 AND trigger = $2 AND status = 'OPEN'
    ORDER BY created_at DESC LIMIT 1;
"""  # noqa: S608

# Every parameter is cast explicitly. Postgres infers a parameter's type from
# where it is used; the first version used the PNR both as a SELECT output
# (inferred text) and in a comparison with a varchar column, and the server
# refused it ("inconsistent types deduced for parameter $1"). The unit tests,
# which use a fake connection, could not see this; the integration test did.
SQL_UPDATE_OPEN = f"""
    UPDATE handoff_cases
    SET question = COALESCE($2::text, question),
        top_similarity = COALESCE($3::double precision, top_similarity),
        similarity_scores = COALESCE($4::jsonb, similarity_scores),
        summary = COALESCE($5::text, summary)
    WHERE case_id = $1::bigint
    RETURNING {_COLUMNS};
"""  # noqa: S608

SQL_INSERT = f"""
    INSERT INTO handoff_cases (pnr_code, trigger, booking_status, question,
                               top_similarity, similarity_scores, summary)
    SELECT b.pnr_code, $2::text, b.booking_status::text, $3::text,
           $4::double precision, $5::jsonb, $6::text
    FROM pnr_bookings b WHERE b.pnr_code = $1::varchar
    RETURNING {_COLUMNS};
"""  # noqa: S608

SQL_LIST_FOR_PNR = f"""
    SELECT {_COLUMNS} FROM handoff_cases WHERE pnr_code = $1 ORDER BY created_at DESC;
"""  # noqa: S608

SQL_LIST_BY_STATUS = f"""
    SELECT {_COLUMNS} FROM handoff_cases
    WHERE ($1::text IS NULL OR status = $1)
    ORDER BY created_at ASC
    LIMIT $2;
"""  # noqa: S608

SQL_RESOLVE = f"""
    UPDATE handoff_cases
    SET status = 'RESOLVED', resolved_at = now(), resolved_by = $2, resolution_note = $3
    WHERE case_id = $1 AND status = 'OPEN'
    RETURNING {_COLUMNS};
"""  # noqa: S608

SQL_AUDIT = """
    INSERT INTO audit_logs (pnr_code, actor, action, details)
    VALUES ($1, $2, $3, $4::jsonb);
"""


def case_to_dict(row) -> dict:
    scores = row["similarity_scores"]
    if isinstance(scores, str):
        scores = json.loads(scores)
    return {
        "case_id": row["case_id"],
        "pnr_code": row["pnr_code"],
        "trigger": row["trigger"],
        "booking_status": row["booking_status"],
        "question": row["question"],
        "top_similarity": row["top_similarity"],
        "similarity_scores": scores,
        "summary": row["summary"],
        "status": row["status"],
        "created_at": row["created_at"].isoformat() if row["created_at"] else None,
        "resolved_at": row["resolved_at"].isoformat() if row["resolved_at"] else None,
        "resolved_by": row["resolved_by"],
        "resolution_note": row["resolution_note"],
    }


async def open_case(
    conn,
    *,
    pnr_code: str,
    trigger: str,
    actor: str,
    question: str | None = None,
    summary: str | None = None,
    top_similarity: float | None = None,
    similarity_scores: list[dict] | None = None,
) -> dict:
    """Open a case, or refresh the booking's existing open case for the same trigger."""
    if trigger not in TRIGGERS:
        raise ValueError(f"Unknown hand-off trigger: {trigger}")
    scores_json = json.dumps(similarity_scores) if similarity_scores is not None else None
    async with conn.transaction():
        existing = await conn.fetchrow(SQL_FIND_OPEN, pnr_code, trigger)
        if existing is not None:
            row = await conn.fetchrow(
                SQL_UPDATE_OPEN, existing["case_id"], question, top_similarity, scores_json, summary
            )
            created = False
        else:
            row = await conn.fetchrow(
                SQL_INSERT, pnr_code, trigger, question, top_similarity, scores_json, summary
            )
            created = True
        if row is None:
            raise LookupError("Booking not found.")
        await conn.execute(
            SQL_AUDIT,
            pnr_code,
            actor,
            "HANDOFF_OPENED" if created else "HANDOFF_UPDATED",
            json.dumps({"case_id": row["case_id"], "trigger": trigger}),
        )
    result = case_to_dict(row)
    result["created"] = created
    return result
