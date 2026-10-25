"""
Conversation memory per booking (Phase 4; table chat_messages, migration 010).

The agent service appends both turns after each completed reply, so a
passenger who comes back later continues the same conversation; "Start over"
deletes it. Only the token's own booking is ever read or written.
"""

from __future__ import annotations

HISTORY_TURNS = 20
MAX_CONTENT = 4000  # also enforced by the table's CHECK constraint

# The last HISTORY_TURNS messages, oldest first.
SQL_HISTORY = """
    SELECT role, content, created_at
    FROM (
        SELECT message_id, role, content, created_at
        FROM chat_messages
        WHERE pnr_code = $1
        ORDER BY created_at DESC, message_id DESC
        LIMIT $2
    ) recent
    ORDER BY created_at ASC, message_id ASC;
"""

SQL_APPEND = """
    INSERT INTO chat_messages (pnr_code, role, content)
    VALUES ($1, $2, $3)
    RETURNING role, content, created_at;
"""

SQL_CLEAR = "DELETE FROM chat_messages WHERE pnr_code = $1;"


def turn_to_dict(row) -> dict:
    return {
        "role": row["role"],
        "content": row["content"],
        "created_at": row["created_at"].isoformat() if row["created_at"] else None,
    }
