# Kestrel issues list (18 Oct 2026)

These are the issues found when Ponytail (`/ponytail-audit`), Agent Skills (`/agent-skills:review`) and Claude Code's built-in `/review` were run on Kestrel. Issues found by more than one tool are merged into one entry. The full write-up is in [review-tools-evaluation.md](review-tools-evaluation.md).

**Legend:**
- **Found by:** PT = Ponytail, AS = Agent Skills, BR = built-in `/review`
- **Checked:** ✅ = I checked it against the code; blank = reported by the plugins but not checked by me
- **Priority:** P0 fix before real users · P1 should fix · P2 nice to have · P3 small cleanups

---

## P0: fix before real users

### 1. Booking reference + surname gives permanent access to all of a passenger's bookings ✅
- **Where:** `src/kestrel/api/main.py:378-408`, `src/kestrel/accounts.py:43` (`SQL_LATEST_BOOKING`)
- **Found by:** AS, BR
- **Problem:** The `PNR_SURNAME` path links *any* verified Google or email account to the passenger, without comparing the account's email with the passenger's email. Later sign-ins can open any of that passenger's bookings, including future ones. The real owner then gets a 409 error, and there is no way to unlink. Booking references and surnames are printed on boarding passes and bag tags.
- **Fix:** Only link an account when its verified email matches the email on the booking. For reference + surname, issue the normal one-booking session without linking. Add a way to unlink, and email the address on file when a link is made.

### 2. Rebooking procedure doesn't check the route ✅
- **Where:** `db/migrations/004_reaccommodate_cabin_class.sql:77-99`, `src/kestrel/api/main.py:543-566`
- **Found by:** PT
- **Problem:** The procedure checks that the target flight exists, is scheduled and hasn't left, but never checks its origin or destination. Flight ids are visible through `/api/me` and the alternatives list. So a passenger on Nairobi–Mombasa can send a Nairobi–London flight id and be moved onto it. Only the AI prompt stands in the way.
- **Fix:** Add migration 011 that compares the target's `origin` and `destination` with the current flight and refuses with `DIFFERENT_ROUTE` if they differ. Keep `SET search_path = public`, which `CREATE OR REPLACE` would otherwise drop. Add an integration test that tries a flight on another route.

### 3. Login limit can be beaten by sending guesses all at once ✅
- **Where:** `src/kestrel/api/main.py:301-311` (PNR sign-in), `:373-385` (account sign-in)
- **Found by:** PT
- **Problem:** The limit is checked (L301), then the code waits for the database (L308), and only then counts the failure (L311). Hundreds of guesses sent at the same moment all pass the check before any failure is counted.
- **Fix:** Count the attempt right after the check, before any `await`, and keep clearing it on success. Add a test that sends 10 guesses at once with `asyncio.gather` and expects at most 5 database lookups.

### 4. "Yes, the first one" opens a staff case instead of rebooking
- **Where:** `src/kestrel/frustration.py:47-50`, `:81-87` (`accepts_offer`)
- **Found by:** PT, BR
- **Problem:** Any reply of 6 words or fewer that starts with yes, ok, sure or please counts as accepting the offer of a person. So "yes, KQ116 please", "ok the first one" and "please book the first flight" open a FRUSTRATION case, and the flight the passenger chose is dropped.
- **Fix:** Match the whole message (end the pattern with `( please| thanks)?$`) and remove the word-count check. Add a test: `assess("yes the first one", offer_history).action != "handoff"`.

---

## P1: should fix

### 5. Assistant uses out-of-date booking details for 120 s after a rebooking in the app
- **Where:** `src/kestrel/agent_service.py:141-195` (the `_briefings` cache)
- **Found by:** PT, AS, BR
- **Problem:** The cache is only cleared when the *assistant* rebooks or hands over. The confirm screen rebooks through the REST API directly (`kestrel_client/lib/screens/confirm_screen.dart:43`). For up to 2 minutes the assistant still thinks the passenger is DISRUPTED, shows the wrong suggestion chips, and could rebook a second time.
- **Fix:** Simplest: drop the cache and fetch `/api/trip` on every turn. That removes about 40 lines and costs about 0.5 s per turn. Otherwise, include the booking's `updated_at` in the cache key.

### 6. Staff queue loses new cases after 200 ✅
- **Where:** `kestrel_client/lib/screens/staff_desk_screen.dart:67`, `src/kestrel/handoff.py:77`
- **Found by:** BR
- **Problem:** The staff desk loads `status: 'ALL', limit: 200` and filters on the device, but the server sorts oldest first (`ORDER BY created_at ASC`). Once 200 cases exist, every new open case is cut off. Low-similarity policy questions open cases automatically, so this fills up quickly.
- **Fix:** Ask the server for `status: 'OPEN'`, or sort newest first.

### 7. Repeating a short reply counts as frustration
- **Where:** `src/kestrel/frustration.py:57-58`
- **Found by:** AS
- **Problem:** `token_set_similarity("yes", "yes")` is 1.0, so a second "yes", "ok" or "thanks" counts as asking the same question again. Retyping after a network error also counts. If an earlier turn had a frustration sign, this opens a FRUSTRATION case automatically.
- **Fix:** Only count a repeat when both messages have at least 4 words. Add a test: history `[user "yes", assistant "Book KQ101?"]` plus the message `"yes"`.

### 8. The app's own suggestion chips count as repeated questions
- **Where:** `src/kestrel/frustration.py:72-78` (`earlier_signal`), `src/kestrel/suggestions.py:71`, `kestrel_client/lib/state/chat.dart:185-202`
- **Found by:** PT, BR
- **Problem:** Chip taps are saved as ordinary user messages, and the same chip (for example the refund one) is offered again after it's answered. `earlier_signal` re-checks the whole history, so a repeated chip label counts as an earlier sign of frustration. The next mild complaint then skips the apology and opens a case.
- **Fix:** Keep the chip labels in one set (`QUICK_REPLY_LABELS`) and have `earlier_signal` skip messages with exactly those texts. Count a policy answer as shown. Add a test with the three-tap history.

### 9. Every later sign of frustration opens another duplicate case
- **Where:** `src/kestrel/agent_service.py:223`
- **Found by:** BR
- **Problem:** Once an earlier turn had a sign of frustration, every later one goes to `run_handoff`, which opens a new FRUSTRATION case and replies with the same canned message. Nothing checks for an existing open case. The staff queue fills with duplicates and the passenger never gets an answer.
- **Fix:** If the trip already has an open case, answer normally, or remind the passenger that a case is open.

### 10. Gemini rate limit holds a database connection for up to about 120 s
- **Where:** `src/kestrel/api/main.py:146-148`, `:617-619`, `src/kestrel/policy/embeddings.py:145-150`
- **Found by:** PT
- **Problem:** On a 429 (rate limit), the single retry waits as long as Gemini asks, up to 120 s, while holding `pool.acquire()`. Ten of these use up all 10 pooled connections, and then sign-in and rebooking stall too.
- **Fix:** `GeminiEmbedder(api_key, max_retries=0)`, and compute the vector (`await retriever.vector(q)`) before acquiring the connection.

### 11. Personal data written to logs
- **Where:** `src/kestrel/agent_service.py:239-246`, `:267-277`, `src/kestrel/agent.py:691-692`
- **Found by:** PT, BR
- **Problem:** Each turn logs `message[:200]` to `logs/agent-turns.jsonl`, and with `LOG_TO_STDOUT=1` it also goes to the hosting platform's logs. Tool results, including voucher codes, are printed to the console. This contradicts `jsonlog.py`'s "never request bodies".
- **Fix:** Remove the `"message"` field from both `_log_turn` calls and remove the `[TOOL RESULT]` print.

### 12. No limit on stored chat history, and fake assistant messages can be stored
- **Where:** `src/kestrel/api/main.py:715`, `src/kestrel/api/history.py:27-31`, `db/migrations/010_chat_memory_and_frustration.sql:8`
- **Found by:** PT, AS, BR
- **Problem:** `POST /api/chat/history` can be called with a passenger token and accepts up to 4,000 characters per message, with no limit on how many are stored. A script can fill the free tier's 500 MB. It also accepts `role: assistant`, so fake assistant messages get replayed to the model on the next visit. Migration 010 says the server caps turns, but it only caps reads.
- **Fix:** After each insert, delete anything older than the newest 100 messages for that booking. Reject `assistant` messages from the client, or rate-limit the endpoint.

### 13. Cash compensation depends on the day you ask
- **Where:** `src/kestrel/entitlements.py:374-387`, `src/kestrel/api/booking.py:169-182`
- **Found by:** PT
- **Problem:** The EU261 notice rule reads `notified_at`, but nothing stores when the passenger was told, so the rule uses "now". The same passenger can get "no compensation" on one day and "€300" a few days later. Demo flights are all within 7 days, so the demo hides this.
- **Fix:** Add a `flights.cancelled_at` column in a migration, set it wherever flights get cancelled, and pass it as `notified_at`.

### 14. Hand-off message tells the passenger something untrue
- **Where:** `src/kestrel/agent.py:840-842`, `:872-873`
- **Found by:** PT, AS
- **Problem:** The reply says staff "can see your booking and what we've discussed", but the staff queue only shows a summary and the last question. Nothing on the staff side reads `chat_messages`.
- **Fix:** Change the wording (for example "They can see your booking and your last question"), or build a conversation view for staff.

### 15. `POST /api/entitlements/issue` has no caller and lets a passenger extend a voucher
- **Where:** `src/kestrel/api/main.py:676-685`, `src/kestrel/entitlements.py:272`
- **Found by:** PT
- **Problem:** Nothing calls this endpoint. For a booking that isn't rebooked yet, each call moves the meal voucher's `valid_until` to now + 24 h, so it never expires.
- **Fix:** Delete the endpoint and its line in the docstring (about 10 lines).

### 16. Voucher codes can collide, and then the passenger gets no vouchers
- **Where:** `src/kestrel/api/booking.py:99-103`
- **Found by:** PT
- **Problem:** Codes have about 5.8 million combinations per voucher type, so there is about an 8% chance of a collision per 1,000 passengers. When it happens, the insert fails, `/api/reaccommodate` returns `entitlements: null`, and the passenger silently loses their vouchers.
- **Fix:** Use 4 letters instead of 2 (`range(2)` → `range(4)`), and retry on `UniqueViolationError`.

### 17. Background task that keeps database connections open can stop silently
- **Where:** `src/kestrel/api/db.py:67`
- **Found by:** AS
- **Problem:** It only catches `PostgresError` and `OSError`. `InterfaceError`, `ConnectionDoesNotExistError` or `TimeoutError` ends the task for the rest of the process's life.
- **Fix:** Catch `Exception`. Cancellation still works because `CancelledError` is not an `Exception`.

### 18. Folders that shouldn't be committed aren't in `.gitignore` ✅
- **Where:** `.gitignore`
- **Found by:** AS
- **Problem:** `site/` (only `node_modules/`, `dist/` and a build file), `graphify-out/` and `.claude/skills/ui-ux-pro-max/` are all untracked. One `git add -A` would commit thousands of files, including `.exe` and `.node` binaries.
- **Fix:** Add them to `.gitignore`, or commit the site's source if it's meant to be in the repo.

### 19. The uncommitted change is too big for one commit
- **Where:** the Sprint 2 working branch
- **Found by:** AS
- **Problem:** About 12,000 lines across sign-in, performance, streaming, frustration and memory, the staff desk, the site, deployment and fonts.
- **Fix:** Split it into one commit per feature, with items 1–5 on their own so they're easy to check.

---

## P2: nice to have

| # | Issue | Where | Found by | Fix |
|---|---|---|---|---|
| 20 | `open_case` looks then inserts without a lock, so two requests at once open two cases | `src/kestrel/handoff.py:130-141` | PT | Start the transaction with `SELECT 1 FROM pnr_bookings WHERE pnr_code=$1 FOR UPDATE` |
| 21 | The early policy search triggers on common words (cancel, delay, right, care) and matches inside words ("alright", "careful"). Its results are rarely reused, and `future.result(timeout=20)` can block for 20 s | `src/kestrel/agent.py:476-479` | PT, AS, BR | Remove "cancel"/"delay", match whole words, use "rights" |
| 22 | A Gemini network error (`httpx.HTTPError`) becomes a plain 500 and breaks the start-up pre-loading silently | `src/kestrel/policy/embeddings.py:132-134` | PT | Wrap it as `EmbeddingError` so it becomes a 502 |
| 23 | `task.add_done_callback(lambda _: None)` does nothing, and the stream task is kept alive only by a closure | `src/kestrel/agent_service.py:378-382` | PT, AS, BR | Remove it, and hold the task in a module-level set until it finishes |
| 24 | `faker` is a runtime dependency only because it quietly installs the `tzdata` time-zone package Windows needs | `requirements.txt` | PT | Replace it with `tzdata`, and move `faker` to `requirements-dev.txt` |
| 25 | Flight option text says "-12 hours after your original flight" when the option leaves earlier | `src/kestrel/api/explain.py:100` | BR | Handle negative waits ("12 hours before…") |
| 26 | The integration test skip only covers migration 009, not 010 (`chat_messages`) | `tests/integration/test_sql_statements.py:45` | AS, BR | Also skip when the `chat_messages` table is missing |
| 27 | The timing middleware writes to the log file without `await` on every request, blocking other requests | `src/kestrel/api/timing.py:64` | PT, BR | Move the write off the event loop, or buffer it |
| 28 | The `_briefings` cap of 1,000 only removes expired entries, so it doesn't actually limit memory | `src/kestrel/agent_service.py:185` | BR | Remove the oldest entries (LRU), or remove the cache (see #5) |
| 29 | `/api/trip` holds 4 of the 10 pooled connections at once | `src/kestrel/api/main.py:521` | AS | Fine for a demo; fix before real traffic |
| 30 | Each sign-in opens a new HTTP client to Supabase | `src/kestrel/accounts.py:138` | AS | Reuse one client |
| 31 | No rate limit on `/api/auth/account` | `src/kestrel/api/main.py` | AS | Add the same login limit |
| 32 | The Dockerfile uses Python 3.12, but the project and ruff target 3.13 | `Dockerfile`, `pyproject.toml` | AS | Use `python:3.13-slim` |
| 33 | Test fakes `FakeConn`/`FakePool` are copied, and `tests/test_accounts.py` is outside `tests/unit/` | `tests/` | AS | Move both fakes into `conftest.py` |

## P3: small cleanups

| # | Issue | Found by |
|---|---|---|
| 34 | Two copies of the "Mon 19 Oct at 05:26" date formatter | PT |
| 35 | `evaluate_booking` is a wrapper that's only used once | PT |
| 36 | The login-limit dictionary grows with every wrong PNR (already noted in the README) | PT |
| 37 | The agent's 10 s timeout is shorter than a slow rebooking | PT |
| 38 | `explain._CITIES` copies the client's `city()` map | AS |
| 39 | For unknown URLs, `masked_path` only masks path segments that contain a digit, so an all-letter PNR would appear in the logs | AS |

---

## Plugin and setup issues (not Kestrel code)

| # | Issue | Suggested action |
|---|---|---|
| T1 | Agent Skills' `/review` clashes with Claude Code's built-in `/review` | Always use the full names: `/agent-skills:review`, `/agent-skills:spec`, and so on |
| T2 | The Agent Skills install failed over SSH (no GitHub host key on this machine) | It worked after downloading over HTTPS. Set up GitHub SSH or a git HTTPS rewrite if updates fail |
| T3 | Graphify's map is skewed by `.claude/skills/ui-ux-pro-max/` (446 of 2,678 nodes) | Add a `.graphifyignore` with `.claude/`, `site/`, `kestrel_client/web/` and rebuild |
| T4 | Graphify skipped all 12 SQL migrations | `pip install "graphifyy[sql]"` and rebuild |
| T5 | Graphify's 110× token saving compares against reading the whole repo | Treat it as a best case, not a measured saving |
| T6 | Agent Skills adds about 3,700 tokens to every session | Disable it in projects that don't need it |
| T7 | `graphify install` created a global `~/.claude/CLAUDE.md` | Keep it or remove it; it's 3 lines |

**Not checked by anyone:** no tests were run, most of the Flutter UI wasn't read line by line, and the dependencies in `pubspec.lock` weren't reviewed.
