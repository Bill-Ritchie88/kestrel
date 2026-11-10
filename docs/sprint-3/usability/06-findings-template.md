# Usability findings: Kestrel Web

Project Kestrel · Sprint III · FR-08 · test day: ________ · participants: __ (phone __, laptop __)

Fill this in after scoring (`scripts/evaluation/score_usability.py`). The finished version feeds Chapter 5.

## 1. Results summary

Paste the scorer's tables here: task outcomes, success rate and mean time per task, SUS per participant with
the mean and sample SD, and the Kestrel questions.

*(paste here)*

In two or three sentences: which tasks worked, which did not, and how the mean SUS compares with 68.

## 2. Severity scale

Each problem is rated on Nielsen's severity scale (Nielsen, 1994). The rating combines how many participants
hit the problem, how badly it stopped them, and whether they would hit it again every time.

| Rating | Meaning | Rule of thumb in this test |
|---|---|---|
| 0 | Not a usability problem | Raised by someone, but nothing in the sessions shows it gets in the way |
| 1 | Cosmetic. Fix only if there is spare time | Noticed or commented on; no hesitation, no error |
| 2 | Minor. Low priority | Hesitation or one wrong turn; task still completed alone in time |
| 3 | Major. Important to fix, high priority | Several wrong turns, a hint needed, or the task completed only after the time limit |
| 4 | Catastrophe. Must fix before release | Task failed: the participant could not complete it, or completed it wrongly without knowing |

## 3. Findings

One block per problem, highest severity first. Group repeats of the same problem under one finding.

### F1. *(short name of the problem)*

| | |
|---|---|
| Task(s) | *e.g. 4 Rebook and seat* |
| Screen | *e.g. Confirm your new flight* |
| Participants affected | *e.g. P2, P4 (2 of 5)* |
| Severity (0–4) | |
| Evidence | *What happened, the errors counted, and quotes in their words* |
| Likely cause | |
| Recommended fix | |
| Status | *Fixed in commit … / Left as future work, because …* |

### F2. *(short name)*

| | |
|---|---|
| Task(s) | |
| Screen | |
| Participants affected | |
| Severity (0–4) | |
| Evidence | |
| Likely cause | |
| Recommended fix | |
| Status | |

*(copy the block for each further finding)*

## 4. What worked well

Things participants did quickly or praised. Keep them, and mention them in Chapter 5 as evidence.

-
-

## 5. Recommended fixes, in priority order

| Priority | Finding | Fix | Effort (S / M / L) | Decision |
|---|---|---|---|---|
| 1 | F_ | | | fix now / future work |
| 2 | F_ | | | |
| 3 | F_ | | | |

Every finding rated 3 or 4 needs a fix here, or a reason it is left as future work.

## 6. Limitations

- 3–6 classmates are not representative Kenya Airways passengers. They are younger, more used to technology,
  and not stressed by a real cancellation.
- The scenarios were scripted and read aloud. Real passengers start with their own goal.
- One session per person, so there is no learning over time. The order of the tasks was the same for everyone.
- Synthetic bookings on a single cancelled flight and route, with one cancellation reason (technical).
- The live free-tier deployment: Render cold starts and the Gemini daily quota may have affected times on task 3.
- A small sample: treat the SUS mean as an indication, not a precise score. Report the SD and n with it.
