# AI-use log — Sprint II

Project Kestrel · Bill Ritchie · 29 October 2026

This log records where AI tools were used in Sprint II, one AI suggestion examined in full (what was accepted,
what was rejected and why), and the other suggestions that were checked before they were acted on. I remain
responsible for the code and the conclusions in the report; nothing below was accepted without a check I can
show.

## 1. Tools and how they were used

| Tool | Used for | Not used for |
|---|---|---|
| Claude (chat assistant, claude.ai) | Planning, explaining options, reviewing results, drafting documents and Claude Code instructions | Deciding scope or accepting results on my behalf |
| Claude Code (on my PC) | Writing and refactoring code to written instructions, running the tests, preparing commits | Pushing without my approval; committing under its own name |
| AI code-review plugins in Claude Code: Ponytail (`/ponytail-audit`), Agent Skills (`/agent-skills:review`), built-in `/review` | Independent review of the Sprint II code on 18 Oct | — |
| Gemini (`gemini-3.6-flash`, `gemini-embedding-001`) | Part of the product: the assistant and policy retrieval | Development |

Working rules I set and kept:
- Every change is reviewed and tested before it is committed; the full suite (291 Python + 74 Flutter tests) runs
  before each push, and CI runs it again.
- No credentials are given to the AI in prompts; `.env` values are never printed or committed.

## 2. One suggestion examined in full: account linking (review issue #1)

**What the AI said.** On 18 Oct, two of the three review tools (Agent Skills and the built-in `/review`) reported
that signing in with Google or an emailed code, then entering a booking reference and surname, *linked that
account to the passenger permanently* — without comparing the account's email with the passenger's email. Since
booking references and surnames are printed on boarding passes and bag tags, anyone holding a boarding pass could
link their own Google account and keep access to all of that passenger's current and future bookings. The tools
proposed: (a) link only when the verified email equals the passenger's email; (b) for reference + surname, give
the normal one-booking session without linking; (c) add a way to unlink; (d) email the passenger whenever a link is
made.

**How it was checked.**
1. Read the linking path (`src/kestrel/api/main.py`, `src/kestrel/api/accounts.py`): the reference + surname branch
   inserted into `passenger_accounts` with no email comparison. The report was correct.
2. Confirmed the impact against the design: Kestrel's own rule is that booking reference + surname gives access to
   *one* booking for *one* visit (FR-01). A permanent link breaks that rule, so this is a security defect, not a
   style point.
3. After the fix, wrote tests for each path and ran them; then checked the live behaviour on 21 Oct: my Google
   account linked only to the demo passenger whose email had been set to mine.

**What I accepted.**
- (a) Link only on a verified email match (case-insensitive).
- (b) Reference + surname of someone else's booking signs in for that booking without linking.
- (c) `DELETE /api/auth/account/link` and an "Unlink this booking" menu item; links and unlinks are written to
  `audit_logs`.

**What I rejected, and why.**
- (d) Emailing the passenger on every link. Kestrel has no mail service, and adding one (provider, templates,
  delivery failures) is outside the project's scope. The risk it addressed is removed by (a): a link can now only
  be made by someone who controls the passenger's own email address. Recorded as future work.

**Evidence.**
- Code: commit `0b680cb` *fix(security): link accounts only on a matching verified email; throttle sign-in before
  any await*.
- Tests (all passing): `test_reference_and_surname_of_someone_else_signs_in_without_linking`,
  `test_reference_and_surname_under_the_verified_email_links`, `test_case_of_the_email_does_not_matter`,
  `test_unlink_removes_only_the_signed_in_accounts_link_and_audits_it`, `test_unlink_without_a_link_changes_nothing`,
  `test_unlink_needs_a_valid_account_token` — rows RV-01 to RV-03 in `docs/sprint-2/02-test-log.md`.
- Issue record: `docs/sprint-2/ai-code-review/issues-found-and-fixed.md`, issue 1.

## 3. Other suggestions checked before acting

| # | AI suggestion or claim | How it was checked | Decision | Why / evidence |
|---|---|---|---|---|
| 1 | A fixed hand-off threshold τ = 0.75 (first draft of FR-05) | Retrieval evaluation on 88 labelled questions, τ chosen on the calibration split, reported on the held-out test split, 5-fold cross-validation | **Rejected**, replaced by calibration | At 0.75, F0.5 = 0.603 and 77 % of answerable questions were handed off; calibrated τ = 0.66 gives F0.5 = 0.918, stable across folds (0.668 ± 0.011). `docs/sprint-2/03-retrieval-evaluation.md`, commits `1e70652`, `5e648e1`, `ed7feea` |
| 2 | The F0.5 definition: the code treated "answer" as the positive class, Chapter 3 described "escalate" | Compared the code with the report line by line | **Accepted the code's definition**, report reworded | Precision of *answers* is the safety property (no unsupported entitlement claims). Report and code now say the same |
| 3 | Review issue #2: rebooking onto a flight on a different route was possible | Read the stored procedure; wrote an integration test that tried it | **Accepted** | Migration 011 refuses with `DIFFERENT_ROUTE`; tests RV-04, RV-05 |
| 4 | Review issue #3: the login limit could be beaten by sending guesses at the same time | Test with 10 concurrent wrong guesses | **Accepted** | Before: 10 database lookups; after: at most 5. Test RV-06 |
| 5 | Review issue #29: the connection pool holds four connections | Measured against the free Supabase plan's limit and the expected load | **Partly accepted**: documented, not re-engineered | Acceptable for a prototype; reasons in `docs/design/database-connection-pool.md` |
| 6 | Review items T1–T7 (tool set-up notes) | Read each | **Rejected** as not applicable | They concerned the tools' installation on my PC, not Kestrel's code |
| 7 | Claude Code reported that `.env` lacked the Supabase settings | Checked `.env` myself | **Rejected** — the claim was wrong | The settings were present; the site build already used them |
| 8 | Six labels in the evaluation question set flagged for review (Q005, Q043, Q063, Q065, Q068, Q078) | Each compared with the policy clauses stored in the database | **Kept as labelled** | E.g. Q068 "change destination to Paris" stays out of scope, matching the `DIFFERENT_ROUTE` rule |
| 9 | During the 25 Oct restructure, Claude Code ran the evaluation by accident and then deleted its output | Read its progress log | **Corrected**: evaluation rerun deliberately on 29 Oct | Results committed as `ed7feea`; the log shows the accidental run was read-only |
| 10 | 29 Oct: CI failed after a push; first assumption could have been that the new code broke it | Reran the 25 Oct commit that had passed — it failed the same way | **Diagnosed as an upstream package release**, not Kestrel's code | Fixed by installing locked versions (`requirements.lock.txt`, commit `c543a39`); CI green |

## 4. What this taught me
- AI review found real defects (issues 1–3) that my own tests had missed, because my tests checked what the code
  was meant to do, not how it could be misused.
- AI output also contained mistakes (item 7) and over-reach (item 6, part (d) of issue 1), so every suggestion
  needs a check I can show — a test, a measurement, or a line of code.
- The most important research decision (item 1) came from rejecting a convenient fixed value and measuring instead.
