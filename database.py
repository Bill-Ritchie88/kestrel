"""
Project Kestrel - database smoke test.

Verifies that the pooler connection works and that
reaccommodate_passenger_atomic behaves correctly end to end, then rolls
everything back so the demonstration state is untouched.

Nothing is hardcoded. The previous version of this file carried a PNR
("KQX89A") and a flight UUID from an early seed; both vanish the moment the
dataset is regenerated, so the script reported a failure that was an artefact
of its own stale constants rather than a defect in the procedure. Every
identifier below is discovered at runtime.

    python database.py
"""

import asyncio
import os
import sys
from pathlib import Path

import asyncpg
from dotenv import load_dotenv

load_dotenv(dotenv_path=Path(__file__).resolve().parent / ".env")
DATABASE_URL = os.getenv("DATABASE_URL")


FIND_DISRUPTED = """
    SELECT b.pnr_code, p.last_name, f.origin, f.destination
    FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    JOIN flights    f ON f.flight_id    = b.original_flight_id
    WHERE b.booking_status = 'DISRUPTED'
    LIMIT 1
"""

FIND_ALTERNATIVE = """
    SELECT f.flight_id, f.flight_number, f.departure_time
    FROM flights f
    WHERE f.origin = $1 AND f.destination = $2
      AND f.status = 'SCHEDULED'
      AND f.departure_time > now()
      AND EXISTS (
          SELECT 1 FROM seats s
          WHERE s.flight_id = f.flight_id AND s.status = 'AVAILABLE'
      )
    ORDER BY f.departure_time
    LIMIT 1
"""


class _Rollback(Exception):
    """Raised to unwind the verification transaction once checks are done."""


async def main() -> int:
    if not DATABASE_URL:
        print("[ERROR] DATABASE_URL is not set. Copy .env.example to .env first.")
        return 1

    print("[INFO] Connecting to Supabase PostgreSQL via the pooler...")
    pool = await asyncpg.create_pool(
        dsn=DATABASE_URL, min_size=1, max_size=5, statement_cache_size=0
    )

    ok = False
    try:
        async with pool.acquire() as conn:
            version = await conn.fetchval("SELECT version()")
            print(f"[OK]   {version.split(',')[0]}")

            booking = await conn.fetchrow(FIND_DISRUPTED)
            if booking is None:
                print("[ERROR] No DISRUPTED bookings found.")
                print("        Run scripts/dataset_generator.py, or "
                      "sql/Reset_demo_state.sql to recreate the disruption.")
                return 1

            print(f"[OK]   Disrupted booking {booking['pnr_code']} "
                  f"({booking['last_name']}) on "
                  f"{booking['origin']}-{booking['destination']}")

            target = await conn.fetchrow(
                FIND_ALTERNATIVE, booking["origin"], booking["destination"]
            )
            if target is None:
                print("[ERROR] No alternative flight with free seats on "
                      f"{booking['origin']}-{booking['destination']}.")
                print("        Increase --days or lower --load-factor when "
                      "generating the dataset.")
                return 1

            print(f"[OK]   Alternative {target['flight_number']} departs "
                  f"{target['departure_time']:%d %b %H:%M}")

            # Everything below runs inside a transaction that is always rolled
            # back, so running this script never changes the demo state.
            try:
                async with conn.transaction():
                    first = await conn.fetchrow(
                        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
                        booking["pnr_code"], target["flight_id"], "SMOKE_TEST",
                    )
                    print(f"\n  1st call  success={first['success']}  "
                          f"seat={first['assigned_seat_number']}  "
                          f"{first['message']}")

                    # The idempotency guard added in migration 003: a repeat
                    # call must be refused rather than consume a second seat.
                    second = await conn.fetchrow(
                        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
                        booking["pnr_code"], target["flight_id"], "SMOKE_TEST",
                    )
                    print(f"  2nd call  success={second['success']}  "
                          f"{second['message']}")

                    ok = bool(first["success"]) and not second["success"]
                    raise _Rollback
            except _Rollback:
                print("\n[INFO] Transaction rolled back; demo state unchanged.")

    except (asyncpg.PostgresError, OSError) as exc:
        print(f"[ERROR] {type(exc).__name__}: {exc}")
        return 1
    finally:
        await pool.close()

    if ok:
        print("[PASS] Re-accommodation succeeded and the repeat call was refused.")
        return 0
    print("[FAIL] Expected the first call to succeed and the second to be refused.")
    return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
