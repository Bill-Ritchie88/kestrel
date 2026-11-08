# Questionnaire: Kestrel usability test

Participant: P__ · Date: ________

Please circle one number for each statement, with your first reaction. Don't think about each one for long.
**1 = strongly disagree, 5 = strongly agree.** Answer every statement. If you're unsure, circle 3.

## Part A: System Usability Scale

"The system" means the Kestrel website you just used.

| # | Statement | Strongly disagree | | | | Strongly agree |
|---|---|:-:|:-:|:-:|:-:|:-:|
| 1 | I think that I would like to use this system frequently. | 1 | 2 | 3 | 4 | 5 |
| 2 | I found the system unnecessarily complex. | 1 | 2 | 3 | 4 | 5 |
| 3 | I thought the system was easy to use. | 1 | 2 | 3 | 4 | 5 |
| 4 | I think that I would need the support of a technical person to be able to use this system. | 1 | 2 | 3 | 4 | 5 |
| 5 | I found the various functions in this system were well integrated. | 1 | 2 | 3 | 4 | 5 |
| 6 | I thought there was too much inconsistency in this system. | 1 | 2 | 3 | 4 | 5 |
| 7 | I would imagine that most people would learn to use this system very quickly. | 1 | 2 | 3 | 4 | 5 |
| 8 | I found the system very cumbersome to use. | 1 | 2 | 3 | 4 | 5 |
| 9 | I felt very confident using the system. | 1 | 2 | 3 | 4 | 5 |
| 10 | I needed to learn a lot of things before I could get going with this system. | 1 | 2 | 3 | 4 | 5 |

## Part B: About Kestrel

| # | Statement | Strongly disagree | | | | Strongly agree |
|---|---|:-:|:-:|:-:|:-:|:-:|
| 11 | I trusted the answers Kestrel gave me. | 1 | 2 | 3 | 4 | 5 |
| 12 | It was clear what my vouchers were and how to use them. | 1 | 2 | 3 | 4 | 5 |
| 13 | I would use Kestrel instead of calling the airline. | 1 | 2 | 3 | 4 | 5 |

Anything else you'd like to say about Kestrel?

&nbsp;

&nbsp;

&nbsp;

---

*For the facilitator, not the participant.* Part A is the System Usability Scale (Brooke, 1996), with the
standard wording and order. To score it, take score − 1 for odd items and 5 − score for even items. Add the ten
values and multiply by 2.5, which gives 0–100 (68 is the commonly used average). Part B is not part of the SUS
score. Type the answers into `05-results-template-sus.csv`: items 1–10 go in `q1`–`q10`, item 11 in `trust`,
item 12 in `voucher_clarity`, item 13 in `instead_of_calling`, and the free text in `comments`.
`scripts/evaluation/score_usability.py` does the arithmetic.
