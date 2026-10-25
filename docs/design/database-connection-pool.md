# Database connections (issue #29)

The REST tier keeps one asyncpg pool (`src/kestrel/api/db.py`): **4 connections ready, 10 at
most**, pinged every 60 s so asyncpg's 5-minute idle timeout never closes them.

`GET /api/trip` runs its four reads at once, each on its own pooled connection (booking,
alternatives, vouchers, cases): one query's round trips (~0.4 s from Nairobi to Frankfurt)
instead of four. That holds **4 of the 10 connections for the length of one query**.

What that means:

- Two passengers opening My trip at the same moment use 8 connections; a third waits a few
  hundred milliseconds for one to come back. Sign-in and rebooking need one connection each.
- Fine for the presentation and for a handful of concurrent passengers.
- Before real traffic, one of: raise `POOL_MAX_SIZE` (Supabase's session pooler allows more),
  run the four reads in one round trip on one connection (one SQL statement returning the four
  parts), or cap `/api/trip` at two connections with a semaphore.

Policy search holds no connection while the question is embedded (issue #10): the vector is
computed first, then a connection is taken for the vector query only.
