# Usability test day: checklist

One page to tick off on the day. The facilitator script is [02-session-script.md](02-session-script.md);
this list is only the order of things around it. Run every command from `C:\Users\billr\dev\kestrel` in
PowerShell, with `.env` present.

**Never run between creating the bookings and the last session:** `.\tasks.ps1 reset`, `test-all`, `smoke`
or `agent`. Each of them can reset every booking in the database, the participants' and the KQ606 demo
included.

## The day before

- [ ] Print one participant sheet per participant from [03-participant-sheet.md](03-participant-sheet.md)
      (P1–P6; P6 is the spare) and one [SUS questionnaire](04-sus-questionnaire.md) each. Leave the booking
      reference and surname blank.
- [ ] Print a copy of the results table (the two CSVs in this folder) or have them open on the laptop.
- [ ] Check the schedule still has flights: the bookings script needs scheduled flights at least 25 hours
      after it runs. If its dry run (below) says "the schedule has run out", the demo data must be reset first,
      which also resets the KQ606 presentation set-up, so only do that after the presentation.

## Morning of the test (30 minutes before the first session)

1. **Wake the services.** Render's free services sleep after 15 minutes without traffic.
   - [ ] Open https://kestrel-myd3.onrender.com/health and https://kestrel-agent.onrender.com/health and
         wait until both say they are online (about a minute each the first time).
   - [ ] Open https://kestrel-web-a20.pages.dev on the participant's device.
2. **Create the bookings.**
   - [ ] Dry run first (does everything, then rolls it back):
         `.\.venv\Scripts\python.exe scripts\data\create_usability_bookings.py --dry-run`
   - [ ] Create them: `.\tasks.ps1 usability`. It prints `P1  <reference>  <surname>` to P6.
   - [ ] Write each reference and surname on its participant sheet. Running the command again keeps the same
         references but resets all six bookings to the start, so do it only between participants if one needs a
         fresh booking, and never during a session.
3. **Recording.** No screen, audio or video recording, and no names (consent text in the script, section 3).
   - [ ] Stopwatch on the phone, a pen, the results table.
   - [ ] For each participant record only: participant number, device, browser, date and time.

## During each session

- [ ] Follow [02-session-script.md](02-session-script.md): consent, five tasks with time limits, think-aloud,
      SUS, debrief.
- [ ] After the session, enter the results: success Y/N, time (m:ss), errors and notes per task in
      `05-results-template-tasks.csv`; the ten SUS answers and the three Kestrel questions in
      `05-results-template-sus.csv`.

## After the last session

1. **Score.**
   - [ ] `.\.venv\Scripts\python.exe scripts\evaluation\score_usability.py`
   - [ ] Paste the Markdown tables it prints into Chapter 5.
   - [ ] Write the problems into [06-findings-template.md](06-findings-template.md) with a severity (0–4)
         and a recommended fix each.
2. **Clean up.**
   - [ ] `.\tasks.ps1 usability-cleanup`. It removes KQ0901, the six passengers, their bookings, vouchers,
         hand-off cases and chat history, and frees the seats they were rebooked into. `audit_logs` rows stay
         as evidence of the sessions.
   - [ ] Keep the filled-in CSVs; do not commit them if any note could identify a participant.
