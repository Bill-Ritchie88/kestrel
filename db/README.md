# Database migrations

`db/migrations/` holds every change to the Supabase (PostgreSQL) schema, applied in number order.
**The files are never renamed or edited after they are applied:** Supabase records each migration by its
file name, so a renamed file would look like a new, unapplied migration. A correction is always a new file.

Requirements: FR-01 sign-in · FR-02 policy corpus · FR-03 alternative flights · FR-04 entitlements ·
FR-05 hand-off and scope guard · FR-06 booking-reference authentication · FR-07 atomic rebooking with audit ·
FR-08 passenger interface · FR-09 staff queue · NFR-01/02 response time and concurrency · NFR-03 data
integrity · DR-xx data requirements.

| Migration | What it adds | Sprint | Requirement |
|---|---|---|---|
| `000_base_schema.sql` | Base schema (bookings, passengers, flights, seats, vouchers, audit), exported from the deployed database by `scripts/export_schema.py` | 1 (committed in 2) | NFR-03 |
| `001_baseline_reaccommodate_passenger_atomic.sql` | The rebooking procedure exactly as deployed on 12 September 2026, kept as the baseline | 1 | FR-03, FR-07 |
| `002_indexes_and_rls.sql` | Indexes for sign-in and flight lookups; row-level security on the passenger tables | 1 | FR-01, FR-06 |
| `003_reaccommodate_passenger_atomic_v2.sql` | Corrected atomic rebooking procedure (same signature as 001) | 1 | FR-07, NFR-03 |
| `004_reaccommodate_cabin_class.sql` | Rebooking v3: cabin class enforced, disruption eligibility, an audit row for every rejection | 2 | FR-07 |
| `005_policy_retrieval.sql` | Policy clause store with pgvector embeddings and the `match_policy_chunks` search | 2 | FR-02, DR-07 |
| `006_entitlements_and_handoff.sql` | Entitlement records, hand-off cases and the cancellation reason the rules use | 2 | FR-04, FR-05, FR-09, DR-06, DR-08 |
| `007_flights_rls.sql` | Row-level security on `flights` (missed by 002) | 2 | NFR-03 |
| `008_advisor_fixes.sql` | Fixes from the Supabase security and performance advisors (pinned `search_path`, indexes) | 2 | NFR-03 |
| `009_passenger_accounts.sql` | Passenger accounts for Google and email-code sign-in, linked to a booking | 2 | FR-01 |
| `010_chat_memory_and_frustration.sql` | Conversation memory per booking (`chat_messages`) and the frustration hand-off trigger | 2 | FR-05, FR-08 |
| `011_rebooking_same_route.sql` | Rebooking refuses a flight on another route (`DIFFERENT_ROUTE`, issue #2) | 2 | FR-03, FR-07 |
| `012_cancelled_at_and_history_cap.sql` | `flights.cancelled_at` set by a trigger (issue #13); chat history capped at 100 turns per booking (issue #12) | 2 | FR-04, FR-05 |
