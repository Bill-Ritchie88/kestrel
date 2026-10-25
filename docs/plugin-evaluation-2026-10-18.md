# Plugin evaluation on Project Kestrel (18 Oct 2026)

This report covers the four Claude Code plugins from the Instagram reel by @adilet.fndr: what was installed, whether each one worked, and what each found when run on Kestrel (`dev/kestrel`, branch `sprint-2/easyfly-layout`, including its uncommitted changes).

## Summary

| Plugin | Installed | Worked on Kestrel | Verdict |
|---|---|---|---|
| **Ponytail** 5.3.2 (DietrichGebert/ponytail) | Yes, for all projects | Yes. `/ponytail-audit` produced a ranked audit with 17 findings | **Keep.** It found the most useful issues. |
| **Agent Skills** 0.6.13 (addyosmani/agent-skills) | Yes, for all projects (34 skills, 4 agents) | Yes, but only under its full name `/agent-skills:review`. Plain `/review` runs Claude Code's built-in review instead. | **Keep.** It found a critical security bug the others missed. |
| **Graphify** 0.9.92 (Graphify-Labs/graphify, PyPI `graphifyy`) | Yes, for your user account (Python package + Claude skill) | Yes. The graph took 51 s to build and used no AI model. | **Keep, but tune it.** The results are skewed by third-party code bundled in the repo. |
| **OmniRoute** | **Skipped, as you asked** | Not applicable | Not installed. See the note at the end. |

**Overall:** the three installed plugins all work. On Kestrel the main result is the bugs and security holes they found, not the reel's token-saving claims. **4 of their findings are real problems that should be fixed before real passengers use the app** (marked ✅ below; I checked each one against the code).

---

## What was installed and where

| Item | Location | Applies to |
|---|---|---|
| Ponytail plugin + marketplace | `~/.claude/plugins/…/ponytail` (user scope) | Every Claude Code project |
| Agent Skills plugin + marketplace | `~/.claude/plugins/…/addy-agent-skills` (user scope) | Every Claude Code project |
| Graphify Python package | User site-packages (`graphify.exe` in Python 3.13's user `Scripts` folder) | Command line, any folder |
| Graphify skill | `~/.claude/skills/graphify/` | Every Claude Code project (`/graphify`) |
| **New global file** `~/.claude/CLAUDE.md` | Created by `graphify install` | **Every** Claude Code session. It adds 3 lines telling Claude about `/graphify`. |
| Kestrel graph | `dev/kestrel/graphify-out/` (untracked, not committed) | Kestrel only |

Installation problems and how they were handled:
- Agent Skills first failed to install because Claude Code tried to download it over SSH, and this machine has no SSH key set up for GitHub. I reran the install with a git setting, applied to that one command only, that makes it download over HTTPS. Nothing in your git config was changed.
- Graphify skipped all 12 `.sql` migration files because SQL support is an optional extra (`pip install "graphifyy[sql]"`). That means the stored procedures, which hold the rebooking rules, are not in the graph.
- Ponytail has four optional settings for a task board and webhooks. I left them unset because none are needed.

---

## 1. Ponytail: `/ponytail-audit` on the Python backend

**Did it work?** Yes. It ran read-only on `src/kestrel` and `tests/`, assumed the load was a demo or small pilot, and returned 3 must-fix, 9 should-fix and 5 nice-to-have findings. Each finding came with a concrete failure case and a fix. It says plainly what it didn't read (the Flutter client and most scripts) and that it didn't run the tests.

**Top findings:**
1. ✅ **Rebooking never checks the route.** The rebooking procedure (`db/migrations/004_reaccommodate_cabin_class.sql`) checks the target flight's status and departure time, but never its origin or destination. Flight ids are visible through `/api/me`, so a passenger stuck on Nairobi–Mombasa can send the id of a Nairobi–London flight and be moved onto it. *Fix:* a new migration that adds a `DIFFERENT_ROUTE` check.
2. ✅ **Sending many login guesses at once gets past the limit.** In `main.py`, the limit is checked at line 301, the database lookup waits at line 308, and the failed attempt is only counted at line 311. Hundreds of surname guesses sent at the same moment all get past the check. *Fix:* count the attempt before the `await`.
3. **"Yes, the first one" opens a staff case instead of rebooking.** `frustration.accepts_offer` treats any reply of 6 words or fewer that starts with "yes" or "ok" as accepting the offer of a person, so "yes, KQ116 please" sends the passenger to staff. (Agent Skills found this too.)
4. A Gemini rate limit holds a database connection for up to 120 s. Ten of these lock up the whole API.
5. The tool's own suggestion chips count as "asking the same question again" in frustration detection.
6. Personal data goes into `logs/agent-turns.jsonl` (`message[:200]`), even though `jsonlog.py` says logs never contain message text.
7. `POST /api/entitlements/issue` has no caller and lets a passenger keep extending a meal voucher's expiry.
8. Voucher codes have about an 8% chance of colliding per 1,000 passengers, and when they collide the passenger silently gets no vouchers.

**Lean result:** about 58 fewer lines and one fewer runtime dependency possible. It also noticed that `faker` is quietly supplying the time-zone data (`tzdata`) Windows needs.

**Feedback on the plugin:**
- 👍 The best report of the three. It goes deep where a mistake costs the most (money, sign-in, data writes), explains in plain English, says what each finding costs if skipped, and is honest about what it didn't check.
- 👍 Low overhead: about 640 tokens added to every session.
- ⚠️ The reel's claim of about 50% less token burn is about Ponytail *writing* code. That needs an implementation task to test, and this evaluation didn't measure it. The project's own benchmark is about 54% fewer lines and 22% fewer tokens, revised down from the viral 80–94%.
- ⚠️ It adds 3 hooks (SessionStart, SubagentStart, UserPromptSubmit) to every session, which push Claude toward minimal code. If you want fuller output on a task, say so in the prompt.

---

## 2. Agent Skills: `/agent-skills:review` on the uncommitted changes

**Did it work?** Yes, but only on the second try:
- **First run, `/review`:** Claude Code's **built-in** `/review` ran, not the plugin's. Its output said "Skills/agents used: none". The plugin's command has the same short name, so the built-in one wins.
- **Second run, `/agent-skills:review`:** the plugin ran its `code-review-and-quality` skill, a review across correctness, readability, architecture, security and performance, and gave the verdict **"Request changes"**.

**Top findings:**
1. ✅ **Critical: a leaked booking reference and surname gives permanent access to all of that passenger's bookings.** `main.py:378-408` links *any* Google or email account to the passenger after a booking reference and surname check, without comparing the account's email with the passenger's. Later sign-ins can open any of that passenger's bookings, and the real passenger gets a 409 error they can't undo. Booking references and surnames are printed on boarding passes and bag tags. *Fix:* only link when the verified email matches the booking. For reference + surname, give the usual one-booking session without linking.
2. Repeating a short reply ("yes", "ok") counts as frustration, because two identical short messages score as 100% similar.
3. After a rebooking on the confirm screen, the assistant keeps using the old booking details for up to 120 s. (Ponytail found this too.)
4. The hand-off message says staff can see the conversation, but staff only see a summary.
5. `POST /api/chat/history` has no limit on how many messages it stores. (Ponytail found this too.)
6. The database connection-pool background task in `db.py` stops for good on `InterfaceError` or `TimeoutError`.
7. `site/`, `graphify-out/` and `.claude/skills/ui-ux-pro-max/` are not in `.gitignore`, so one `git add -A` would commit thousands of files, including `.exe` and `.node` binaries.
8. The uncommitted change is about 12,000 lines across 8 features and should be split into one commit per feature.

The built-in `/review` run (the first try) also found:
- ✅ The staff desk loads at most 200 cases (`staff_desk_screen.dart:67`), and the server sorts them oldest first (`handoff.py:77`). Once there are more than 200 cases, every new hand-off is cut off.
- Negative waits show up as "-12 hours after your original flight".

**Feedback on the plugin:**
- 👍 The only plugin that found the account-takeover hole, the most serious issue in the whole evaluation. It also lists what's good, which is useful for a project report.
- ⚠️ **Name clash:** `/review`, `/plan`, `/test` and others may be taken by Claude Code's own commands. Always use the full name (`/agent-skills:review`, `/agent-skills:spec`, and so on). This means the reel's "the right one activates on its own" doesn't hold for `/review`.
- ⚠️ The heaviest of the three: about **3,700 tokens added to every session** across 34 skills and 4 agents. If that adds up, disable it in projects that don't need it.
- ⚠️ It ran the review itself instead of handing it to its `code-reviewer` subagent, so the 4 subagents weren't tested here.

---

## 3. Graphify: knowledge graph of Kestrel

**Did it work?** Yes. `graphify extract --code-only` parsed 151 code files with tree-sitter in **51 s**, entirely on your machine, with no API key and no AI model. The result was **2,678 nodes, 4,693 edges and 131 groups** (`graphify-out/graph.json`, `graph.html`, `GRAPH_REPORT.md`).

**Benchmark (`graphify benchmark`):** about 1,600 tokens per query, compared with about 178,500 tokens to read the whole repo, which Graphify reports as **110× fewer**. The reel says 71.5×.

**Feedback on the plugin:**
- ⚠️ **The 110× figure is generous.** It compares one graph query against reading *every* file. In real use Claude reads a few relevant files, not the whole repo, so the real saving is much smaller.
- ⚠️ **The graph is skewed by third-party code.** 446 of the 2,678 nodes (17%) come from `.claude/skills/ui-ux-pro-max/`. The top "most connected" items are `search()`, `DesignSystemGenerator` and `search_stack()`, all from that skill rather than from Kestrel. Kestrel's real hubs (`evaluate()`, `PassengerSession`, `PolicyRetriever`) come lower down.
- ⚠️ **The sample query was weak.** I asked "how does a flight rebooking request flow from the API to the database". The answer included test files from the bundled skill and was cut off at 39 of 202 nodes. Matching on keywords isn't the same as understanding the code.
- ⚠️ The SQL migrations (where the rebooking rules live) were skipped without the `[sql]` extra, and group names stay "Community N" unless you let an AI model name them.
- 👍 Fast, free and offline. `graphify update .` refreshes the graph after code changes at no cost.

**To make it useful on Kestrel:**
1. Add a `.graphifyignore` file containing `.claude/`, `site/` and `client/web/`, then rebuild.
2. Run `pip install "graphifyy[sql]"` to include the migrations.
3. Optionally run `graphify claude install` in the repo. This edits the project's CLAUDE.md and adds a hook so Claude checks the graph before searching. I haven't done this because it changes your repo.
4. Add `graphify-out/` to `.gitignore`, or commit it on purpose.

---

## Combined priority list for Kestrel

| # | Issue | Found by | Checked |
|---|---|---|---|
| 1 | Account linking with a booking reference + surname gives permanent access to all of a passenger's bookings | Agent Skills, built-in review | ✅ |
| 2 | Rebooking procedure doesn't check the route, so a passenger can take any flight | Ponytail | ✅ |
| 3 | Login limit can be beaten by sending guesses all at once | Ponytail | ✅ |
| 4 | "Yes, the first one" / repeated "yes" sends the passenger to staff instead of rebooking | All three reviews | reported by all |
| 5 | Assistant uses out-of-date booking details for 120 s after a rebooking in the app | All three reviews | reported by all |
| 6 | Staff queue loses new cases after 200 | Built-in review | ✅ |
| 7 | No limit on stored chat history | All three reviews | reported by all |
| 8 | Personal data written to logs | Ponytail, built-in review | reported by both |
| 9 | Gemini rate limit holds database connections and can freeze the API | Ponytail | not checked |
| 10 | `.gitignore` gaps (`site/`, `graphify-out/`, bundled skill) | Agent Skills | ✅ (seen in `git status`) |

Items not marked ✅ were reported by the plugins but not checked against the code by me. Findings that 2 or 3 tools reported independently are more likely to be real.

---

## Limits of this evaluation
- All runs were read-only. I changed nothing in Kestrel except adding `graphify-out/` and this report (both untracked).
- No tests were run, by me or by the plugins.
- The reel's token-saving claims (Ponytail about 50%, Graphify 71.5×) were not measured in real coding sessions. That would need the same task run with and without each plugin.
- Star counts in the reel (142k, 119k, 96k) were not checked.

## OmniRoute (skipped)
OmniRoute isn't a Claude Code plugin. It's a local proxy that sends Claude Code's requests to other model providers (`ANTHROPIC_BASE_URL` → `localhost:20128`). Setting it up means:
- signing in with your own keys for each provider,
- sending your code to those third-party providers,
- changing a setting that affects every Claude Code session.

Security reviewers have also raised concerns about it. If you want it later, test it in a separate account or VM first.

## Sources
- [Ponytail benchmark (MindStudio)](https://www.mindstudio.ai/blog/ponytail-benchmark-lines-of-code-reduction)
- [Ponytail token comparison (Pasquale Pillitteri)](https://pasqualepillitteri.it/en/news/7881/caveman-rtk-pxpipe-headroom-claude-code-tokens)
- [OmniRoute security review (Pinggy)](https://pinggy.io/blog/omniroute_ai_gateway_security/)
- [OmniRoute critique (Level Up Coding)](https://levelup.gitconnected.com/the-ai-tool-that-promises-1-6-billion-free-claude-tokens-and-why-you-shouldnt-touch-it-a63c687f7d91)
- [Graphify review (CodeConductor)](https://codeconductor.ai/blog/graphify-review/)
- [graphifyy on PyPI](https://pypi.org/project/graphifyy/)
- [Agent Skills commands (RuntimeWire)](https://runtimewire.com/article/addy-osmani-agent-skills-claude-code-slash-commands)
