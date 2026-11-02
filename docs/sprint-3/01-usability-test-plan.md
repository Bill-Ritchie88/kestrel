# Usability test plan — Kestrel Web

Project Kestrel · Bill Ritchie · test day Sunday 1 November 2026

## 1. Purpose
Check whether passengers can complete the main recovery tasks on Kestrel Web without help, on a phone and on a
laptop, and find the problems that stop them. Supports FR-08 (passenger interface) and the Chapter 5 usability
results.

## 2. Participants and set-up
- **Who:** 5 classmates (minimum 3), none involved in building Kestrel. Aim for at least 2 who will use their own
  phone and 2 on a laptop.
- **Where:** a quiet room; about 15 minutes per person.
- **What they use:** the **live** Kestrel Web site (Cloudflare Pages address). Open it yourself 5 minutes before the
  first session so the Render services are awake.
- **Data:** synthetic bookings only. Each participant gets a different disrupted booking (they can only be rebooked
  once), all on the cancelled Nairobi → Mombasa flight KQ600:

| Participant | Booking reference | Surname |
|---|---|---|
| P1 | XCNGHW | Hicks |
| P2 | NL6GAJ | Trujillo |
| P3 | PW849Z | Romero |
| P4 | VYLZEJ | Thompson |
| P5 | DKCTDW | Bryant |

  Check on the morning of the test that all five are still DISRUPTED.
- **Gemini quota:** task 3 uses one typed question per person (5 in total), well within the free daily limit.

## 3. Consent and ethics (read out before each session)
> "I'm testing the website, not you. There are no wrong answers. Please think aloud as you go. I won't help unless
> you're stuck. Everything uses made-up bookings, I won't record your name or your screen, and you can stop at any
> time. Is that OK?"

Record only the participant number (P1–P5), device and browser. Check with your supervisor whether a peer
usability session needs any formal ethics approval in your unit.

## 4. Tasks
Read each scenario aloud, then say nothing unless the participant is stuck for more than 2 minutes.

| # | Scenario read to the participant | Success when | Covers |
|---|---|---|---|
| 1 | "Your Kenya Airways flight to Mombasa was cancelled. Sign in to Kestrel with your booking reference and surname." (hand them the card) | The trip page shows their booking | FR-06 |
| 2 | "Find out why the flight was cancelled and what the airline owes you." | They state the reason and at least one entitlement (meal, hotel, points or compensation) | FR-04 |
| 3 | "Ask Kestrel, in your own words, whether you could get a refund instead of a new flight." | They read an answer that cites a policy clause, or are told a person will help | FR-02, FR-05 |
| 4 | "Move yourself to the earliest flight that still has seats, and confirm it." | The rebooked confirmation shows the new flight | FR-03, FR-07 |
| 5 | "Find the vouchers you've been given and the new departure time." | They point to the vouchers and the new time | FR-04, FR-08 |

## 5. What to record (per task)
- **Outcome:** ✓ completed alone · H completed with help · ✗ not completed.
- **Time** from the end of the scenario to success (phone stopwatch).
- **Problems:** where they hesitated, tapped the wrong thing, or said something was unclear — in their words.

## 6. Questionnaire (after the tasks)

### System Usability Scale (SUS)
1 = strongly disagree … 5 = strongly agree.

| # | Statement | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| 1 | I think that I would like to use this system frequently. | | | | | |
| 2 | I found the system unnecessarily complex. | | | | | |
| 3 | I thought the system was easy to use. | | | | | |
| 4 | I think that I would need the support of a technical person to be able to use this system. | | | | | |
| 5 | I found the various functions in this system were well integrated. | | | | | |
| 6 | I thought there was too much inconsistency in this system. | | | | | |
| 7 | I would imagine that most people would learn to use this system very quickly. | | | | | |
| 8 | I found the system very cumbersome to use. | | | | | |
| 9 | I felt very confident using the system. | | | | | |
| 10 | I needed to learn a lot of things before I could get going with this system. | | | | | |

**Scoring:** odd items: score − 1; even items: 5 − score; add the ten values and multiply by 2.5 (range 0–100).
68 is the commonly used average; report each participant's score and the mean.

### Three short questions
1. What was the most confusing moment?
2. Did you trust the assistant's answer about refunds? Why or why not?
3. Would you rather use this or call the airline? Why?

## 7. Notes sheet (one per participant)

Participant: P__ · Device: phone / laptop · Browser: ________ · Date/time: ________

| Task | Outcome (✓ / H / ✗) | Time | Problems observed (their words) |
|---|---|---|---|
| 1 Sign in | | | |
| 2 Reason + entitlements | | | |
| 3 Refund question | | | |
| 4 Rebook earliest flight | | | |
| 5 Vouchers + new time | | | |

SUS score: ____ · Answers to the three questions: ____________________________________________

## 8. Analysis for Chapter 5
- Task success rate per task (completed alone / total) and median time.
- SUS per participant and the mean, compared with 68.
- Problems grouped by screen, each rated: **blocker** (task failed), **major** (needed help), **minor**
  (hesitation). For each blocker or major problem: the fix made, or why it is left as future work.
- Limitations to state: 3–5 classmates are not representative passengers; tasks were scripted; one session each.
