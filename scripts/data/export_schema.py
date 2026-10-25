"""
Export the deployed base schema into db/migrations/000_base_schema.sql.

Chapter 5 records that "the base table definitions exist only in the hosted
database and must be exported into the repository as migration 0". Until they
are, the repository cannot be used to rebuild the database from scratch, so
nobody else can reproduce the results - the migrations in db/migrations/ all assume the
tables already exist.

This reads the live catalogue and writes the DDL, so migration 0 is generated
from the real schema rather than transcribed by hand from the ERD, which is
how the ERD and the deployment drifted apart in the first place.

    python scripts/data/export_schema.py
    python scripts/data/export_schema.py --out db/migrations/000_base_schema.sql

Requires DATABASE_URL. Writes a file; changes nothing in the database.
"""

import argparse
import asyncio
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

import asyncpg
from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parents[2]
load_dotenv(dotenv_path=PROJECT_ROOT / ".env")

TABLES = ["passengers", "flights", "seats", "pnr_bookings", "vouchers", "audit_logs"]

ENUMS_SQL = """
    SELECT t.typname AS name,
           array_agg(e.enumlabel ORDER BY e.enumsortorder) AS labels
    FROM pg_type t
    JOIN pg_enum e ON e.enumtypid = t.oid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
    GROUP BY t.typname
    ORDER BY t.typname
"""

COLUMNS_SQL = """
    SELECT a.attname AS name,
           format_type(a.atttypid, a.atttypmod) AS type,
           a.attnotnull AS not_null,
           pg_get_expr(d.adbin, d.adrelid) AS default_expr
    FROM pg_attribute a
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = to_regclass($1)
      AND a.attnum > 0 AND NOT a.attisdropped
    ORDER BY a.attnum
"""

CONSTRAINTS_SQL = """
    SELECT conname AS name, pg_get_constraintdef(oid) AS definition, contype::text AS kind
    FROM pg_constraint
    WHERE conrelid = to_regclass($1)
    ORDER BY CASE contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 ELSE 3 END,
             conname
"""

INDEXES_SQL = """
    SELECT indexname AS name, indexdef AS definition
    FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = $1
      AND indexname NOT IN (
          SELECT conname FROM pg_constraint WHERE conrelid = to_regclass($2)
      )
    ORDER BY indexname
"""


async def build(conn) -> str:
    out: list[str] = [
        "-- Project Kestrel - migration 000 (BASE SCHEMA)",
        "--",
        "-- Generated from the deployed Supabase database by",
        "-- scripts/data/export_schema.py. Do not hand-edit: regenerate instead, so",
        "-- this file cannot drift from the database the way the ERD did.",
        "--",
        f"-- Generated: {datetime.now(UTC):%Y-%m-%d %H:%M} UTC",
        "--",
        "-- Apply FIRST, before the migrations in Table 5.4:",
        "--   000_base_schema.sql   <- this file",
        "--   001_baseline_reaccommodate_passenger_atomic.sql",
        "--   002_indexes_and_rls.sql",
        "--   003_reaccommodate_passenger_atomic_v2.sql",
        "--   ../seeds/reset_demo_state.sql",
        "",
        "BEGIN;",
        "",
        "-- " + "-" * 73,
        "-- Enumerated types",
        "-- " + "-" * 73,
        "",
    ]

    for row in await conn.fetch(ENUMS_SQL):
        labels = ", ".join(f"'{lbl}'" for lbl in row["labels"])
        out += [
            "DO $$ BEGIN",
            f"    CREATE TYPE {row['name']} AS ENUM ({labels});",
            "EXCEPTION WHEN duplicate_object THEN NULL;",
            "END $$;",
            "",
        ]

    out += ["-- " + "-" * 73, "-- Tables", "-- " + "-" * 73, ""]

    present = []
    for table in TABLES:
        qualified = f"public.{table}"
        if not await conn.fetchval("SELECT to_regclass($1) IS NOT NULL", qualified):
            print(f"[WARN] {qualified} does not exist; skipped.")
            continue
        present.append(table)

        columns = await conn.fetch(COLUMNS_SQL, qualified)
        constraints = await conn.fetch(CONSTRAINTS_SQL, qualified)

        lines = []
        for col in columns:
            piece = f"    {col['name']} {col['type']}"
            if col["default_expr"]:
                piece += f" DEFAULT {col['default_expr']}"
            if col["not_null"]:
                piece += " NOT NULL"
            lines.append(piece)

        # Table-level constraints inline; foreign keys are added afterwards so
        # the tables can be created in any order.
        for con in constraints:
            if con["kind"] != "f":
                lines.append(f"    CONSTRAINT {con['name']} {con['definition']}")

        out += [
            f"CREATE TABLE IF NOT EXISTS {qualified} (",
            ",\n".join(lines),
            ");",
            "",
        ]

    out += ["-- " + "-" * 73, "-- Foreign keys", "-- " + "-" * 73, ""]
    for table in present:
        qualified = f"public.{table}"
        for con in await conn.fetch(CONSTRAINTS_SQL, qualified):
            if con["kind"] == "f":
                out += [
                    f"ALTER TABLE {qualified} DROP CONSTRAINT IF EXISTS {con['name']};",
                    f"ALTER TABLE {qualified} ADD CONSTRAINT {con['name']} {con['definition']};",
                    "",
                ]

    out += ["-- " + "-" * 73, "-- Indexes", "-- " + "-" * 73, ""]
    for table in present:
        for idx in await conn.fetch(INDEXES_SQL, table, f"public.{table}"):
            definition = (
                idx["definition"]
                .replace("CREATE INDEX", "CREATE INDEX IF NOT EXISTS", 1)
                .replace("CREATE UNIQUE INDEX", "CREATE UNIQUE INDEX IF NOT EXISTS", 1)
            )
            out.append(f"{definition};")
    out += ["", "COMMIT;", ""]

    return "\n".join(out)


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", default=str(PROJECT_ROOT / "db" / "migrations" / "000_base_schema.sql")
    )
    args = parser.parse_args()

    url = os.getenv("DATABASE_URL")
    if not url:
        print("[ERROR] DATABASE_URL is not set. Copy .env.example to .env first.")
        return 1

    conn = await asyncpg.connect(url, statement_cache_size=0)
    try:
        ddl = await build(conn)
    finally:
        await conn.close()

    target = Path(args.out)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(ddl, encoding="utf-8", newline="\n")
    print(f"[OK] Wrote {target} ({len(ddl.splitlines())} lines)")
    print("     Review it, then commit it as migration 000.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
