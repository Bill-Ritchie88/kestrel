# Usability session script: Kestrel Web

Project Kestrel · Sprint III · FR-08 · facilitator copy

This is what you say and do in each session. It follows the [usability test plan](../01-usability-test-plan.md),
with two changes. The bookings now come from `scripts/data/create_usability_bookings.py` (the plan's KQ600 table
is no longer used). The five tasks are reworded so they match the screens without naming them. Kit:

| File | Use |
|---|---|
| `02-session-script.md` | This script |
| [`03-participant-sheet.md`](03-participant-sheet.md) | One card per participant: booking reference and surname |
| [`04-sus-questionnaire.md`](04-sus-questionnaire.md) | Handed out after the tasks |
| [`05-results-template-tasks.csv`](05-results-template-tasks.csv), [`05-results-template-sus.csv`](05-results-template-sus.csv) | Where you type the results; scored by `scripts/evaluation/score_usability.py` |
| [`06-findings-template.md`](06-findings-template.md) | Problems found, severity, fixes |

Site: **https://kestrel-web-a20.pages.dev** · about 20 minutes per participant.

---

## 1. Before test day

- [ ] Print one participant sheet per person (P1–P6; P6 is a spare). Print one SUS questionnaire per person,
  and one notes sheet (section 6) per person.
- [ ] Phone stopwatch ready. Use a pen for notes. No screen or audio recording.
- [ ] If you can, run one session with yourself on a seventh booking first. Re-running the script gives you
  fresh bookings afterwards.

## 2. On the morning of the test

From the repo root, in PowerShell, with `.env` in place:

```powershell
.\.venv\Scripts\python.exe scripts\data\create_usability_bookings.py --dry-run   # does everything, then rolls back
.\tasks.ps1 usability                                                           # creates the six bookings
```

The second command prints six lines: `P1  <reference>  <surname>` to `P6`. Copy each reference and surname
onto the matching participant sheet. If the script says the schedule has run out, run `.\tasks.ps1 reset` and
then `.\tasks.ps1 usability` again.

Running `.\tasks.ps1 usability` again later keeps the same six references. It puts all six back to the
starting state (cancelled, not rebooked, no vouchers, no assistant history), **including anyone already
tested**. Use it only between whole rounds.

**Between creating the bookings and the last session, do not run** `.\tasks.ps1 reset`, `test-all`, `smoke` or
`agent`. Each of them can reset every booking in the database, these six included. If one ran by mistake, run
`.\tasks.ps1 usability` again. The references stay the same.

Five minutes before the first session:
- [ ] Open the site yourself. The Render services sleep after 15 minutes without traffic, and the first request
  takes about a minute to wake them. Sign in with P6 and check that the trip page loads. Do not rebook P6.
- [ ] Keep the site open (or reload it) between sessions so the services stay awake.

Things that can go wrong during a session:

| What | Why | What to do |
|---|---|---|
| "Too many failed attempts" at sign-in | 5 wrong tries on one booking lock it for 5 minutes | Give the participant the spare sheet (P6); record the lockout as a finding |
| Signed out in the middle of a task | A guest session lasts 15 minutes | Let them sign in again; note it; the time keeps running |
| The assistant says it has reached a usage limit | Gemini free tier, about 20 typed questions a day | Task 3 counts as not completed for a system reason; note it separately, not as a usability failure |
| Rebooking fails or the participant gives up on task 4 | No vouchers are issued until the booking is moved | Before task 5, say "I'll do this step for you" and rebook them onto the first flight shown; task 4 stays N |

## 3. Introduction and consent (read aloud)

> "Thanks for helping. I'm testing a website called Kestrel, not you. There are no wrong answers. If something
> is confusing, that's the website's fault, and it's exactly what I need to know.
>
> Kestrel helps airline passengers whose flight has been cancelled. I'll read you five short situations, one at
> a time, and ask you to do something on the site. Please think aloud as you go: say what you're looking for,
> what you expect to happen and anything that surprises you. I won't help unless you're really stuck, because
> I want to see how the site works on its own.
>
> Everything is made up. The booking on this card belongs to a fake passenger, so please don't type anything
> about yourself, and don't sign in with your own Google or email account. I won't record your name, your
> voice or your screen. I'll only write notes and times against a participant number. You can stop at any
> time, for any reason. Afterwards there's a one-page questionnaire.
>
> Is that OK? Do you have any questions before we start?"

Record only: participant number, device (phone or laptop), browser, date and time. Hand over the participant
sheet, open the site's home page and give them the device (or let them use their own phone).

## 4. The tasks

For each task: read the scenario aloud exactly as written. Start the stopwatch when you finish reading. Stop it
when the success criterion is met, when they say they're done or give up, or at the time limit. Then go on to
the next task. Say nothing while they work except the neutral prompts in section 5.

**Outcome:** **Y** means completed without help within the time limit. **N** means anything else: wrong
answer, gave up, needed a hint, or ran out of time. **Errors** means wrong turns: a tap or click on something
that did not lead towards the goal, a dead end, or a wrong entry such as a mistyped reference. Count each one.

The "where it is" notes are for you only. Never read them out.

### Task 1: Sign in with a booking reference (limit 3 min) · FR-06

> "Your Kenya Airways flight has been cancelled. This card has your booking details. Use them to get into
> Kestrel and see your trip."

- **Success:** their own trip is on screen. It greets the passenger by first name and shows the cancelled
  flight.
- **Where it is:** the home page offers Google, email and booking-reference sign-in. The guest route takes the
  booking reference and the surname. Watch which option they try first.
- **Note:** they head for Google or email sign-in, or type the reference into the surname box. A mistyped
  reference counts as an error.

### Task 2: Find out what you're entitled to (limit 3 min) · FR-04

> "Find out why your flight was cancelled and what the airline will give you because of it. Tell me when you
> know."

- **Success:** they say the reason (a technical problem) **and** at least one thing they are entitled to (a
  meal voucher, Asante Rewards goodwill points, or a seat on another flight at no cost).
- **Where it is:** the reason is on the trip ticket. The entitlements are on the trip page ("What you're
  entitled to"), on the vouchers page and through the assistant's suggested question. Any of these counts.
- **Note:** before rebooking the entitlements are a decision, not voucher codes. Note if they expect codes now,
  or if "hotel is decided once you are rebooked" confuses them.

### Task 3: Ask the assistant a policy question (limit 4 min) · FR-02, FR-05

> "You're not sure you still want to travel. Ask Kestrel, in your own words, whether you could get your money
> back instead of taking another flight."

- **Success:** they read an answer that cites at least one policy source (listed under the answer), **or** they
  are told a member of staff will take over. They should be able to say in a sentence what the answer was.
- **Where it is:** the Assistant. A suggested question about refunds exists. If they tap it instead of typing,
  record "used suggestion". It still counts as Y.
- **Note:** the time to the first word of the answer (Render may be slow), whether they notice the sources, and
  what they say about trusting the answer.

### Task 4: Rebook and choose a seat (limit 4 min) · FR-03, FR-07, FR-16

> "Move yourself to the first flight you can get that still has seats, and pick a window seat on it."

- **Success:** they choose a window seat (A, or the last letter of the row) on the seat map, confirm, and the
  confirmation shows the new flight and that seat. They can tell you the seat number.
- **Partial:** they rebook with "Let Kestrel choose" instead of picking a seat. Record N for success and note
  "auto seat", and in the debrief ask whether they saw the seat map.
- **If two participants pick the same seat at once,** the second sees "That seat was just taken. Please pick
  another" and the map reloads. That is the system working; let them pick again and note it.
- **Where it is:** flights are listed on the trip page, on Flights and in the Assistant, earliest arrival first.
  The first one is marked as recommended. Choosing a flight opens the seat map, then the Confirm screen.
- **Note:** whether they chose the first flight listed (write "not first" if not), any hesitation on the
  confirm screen, and whether "no charge for this change" reassures them.
- If they do not finish, rebook them yourself before task 5 (section 2).

### Task 5: Find your voucher code (limit 2 min) · FR-04, FR-08

> "At the airport, the Kenya Airways desk asks for your voucher code. Find it and read it out to me."

- **Success:** they read out any voucher code (format `KQ-XX-1234-ABCD`).
- **Where it is:** the rebooking confirmation, the trip page once rebooked, and the vouchers page. Every
  booking gets at least the goodwill-points voucher. Meal, hotel and transfer vouchers depend on how long the
  wait is.
- **Note:** whether they copy the code or read it out, and whether they understand what each voucher is for.

## 5. Think-aloud prompts (neutral only)

Use these when the participant goes quiet for more than about 15 seconds:

- "What are you thinking right now?"
- "What are you looking for?"
- "What do you expect to happen if you tap that?"
- "Is that what you expected?"
- "Keep going. Tell me what you're seeing."

When asked "Is this right?" or "Where is it?", answer: "What would you do if I weren't here?" Never point at
the screen, name a button or say "almost". If they have been stuck for 2 minutes, or hit the time limit, say:
"Thanks, that's really useful. Let's move on to the next one." Record **N**.

## 6. Notes sheet (one per participant)

Participant: P__ · Device: phone / laptop · Browser: ________ · Date/time: ________

| Task | Outcome (Y / N) | Time (m:ss) | Errors | What happened, in their words |
|---|---|---|---|---|
| 1 Sign in | | | | |
| 2 Reason and entitlements | | | | |
| 3 Policy question | | | | |
| 4 Rebook and seat | | | | |
| 5 Voucher code | | | | |

## 7. Debrief (about 3 minutes, then the questionnaire)

1. "What was the most confusing moment?"
2. "Was anything easier than you expected?"
3. "You asked about a refund. Did you believe the answer? Why or why not?"
4. "Was it clear what your vouchers were and how you'd use them?"
5. "If this really happened to you, would you rather use this or phone the airline? Why?"
6. "Anything else you'd change?"

Then hand over the [SUS questionnaire](04-sus-questionnaire.md). Say: "Answer with your first reaction; don't
think about each one for long." Thank them. Take back the participant sheet and keep it with your notes.

## 8. After the sessions

1. Type the notes into `05-results-template-tasks.csv` and the questionnaires into
   `05-results-template-sus.csv`. Use one row per participant and task. Times can be `75` or `1:15`. Leave
   unused rows blank.
2. Score them, and paste the tables into Chapter 5:

   ```powershell
   .\.venv\Scripts\python.exe scripts\evaluation\score_usability.py
   ```

3. Write the problems up in [`06-findings-template.md`](06-findings-template.md).
4. Remove the test bookings:

   ```powershell
   .\tasks.ps1 usability-cleanup
   ```

   This removes the flight, the six passengers and bookings, their vouchers, hand-off cases and assistant
   history. It also frees the seats they were rebooked into. `audit_logs` rows are kept as evidence.
