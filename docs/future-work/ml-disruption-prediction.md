# Proposal: flight disruption prediction

Status: **proposed, pending supervisor approval** (1 October 2026).

Adds a classical supervised ML component to Kestrel. The agent and the
transaction layer stay as they are; the trained model gives the system
foresight.

---

## 1. Problem

> Given what is known about a flight before it departs, predict the probability
> that it will be cancelled.

Binary classification on real, labelled, tabular data. Primary target
`cancelled`; optional second target `severely_disrupted` (cancelled, or arriving
three or more hours late).

**Why not train on Kestrel's own data:** the synthetic dataset is produced by
rules written in `scripts/dataset_generator.py`. A model trained on it would
rediscover those rules, and its accuracy would mean nothing. The trained
component must use real data; the synthetic data stays for testing the
re-accommodation system.

## 2. Data

US Bureau of Transportation Statistics, *Reporting Carrier On-Time
Performance* (transtats.bts.gov): every domestic flight of the large US
carriers, public and free. Two years, about 12-14 million flights, stored as
Parquet. Cancellations are roughly 1-3% of flights.

**Used:** flight date, carrier, origin, destination, scheduled departure and
arrival, distance, tail number, `Cancelled`.

**Excluded as leakage** (known only after the event): actual departure time,
departure delay, taxi times, arrival delay, cancellation code, diverted.

**Stretch goal:** hourly weather at the origin airport from NOAA Local
Climatological Data.

## 3. Features

| Group | Features |
|---|---|
| Time | month, day of week, departure hour, days to nearest public holiday |
| Route | origin, destination, distance, daily frequency on the route |
| Carrier | airline |
| Congestion | scheduled departures at the origin in that hour |
| Aircraft rotation | leg number of the day for the tail, planned turnaround before it |
| History | past cancellation rate of route, origin and carrier, computed from the training period only |

## 4. Split

By time, not at random: train on year 1, validate on the first half of year 2
(tuning and threshold), test once on the second half of year 2. A random split
leaks information between neighbouring days.

## 5. Models

1. Majority-class baseline (~98% accuracy, zero cancellations caught, showing why accuracy is the wrong metric)
2. Historical route-rate baseline
3. Logistic regression
4. Random forest
5. Gradient boosting (LightGBM / XGBoost), the expected final model

Imbalance handled with class weights or undersampling, and a threshold chosen
on validation data.

## 6. Evaluation

- **Headline: PR-AUC.** ROC-AUC reported too, but it is flattering at ~2% positives.
- Precision, recall, F1 and confusion matrix at the chosen threshold.
- Calibration: reliability curve and Brier score, since the probability drives decisions.
- Explainability: feature importance / SHAP.
- Error analysis by carrier, airport and month.

## 7. Integration with Kestrel

1. **Risk-aware re-accommodation.** Alternatives returned to the agent carry a
   risk score, so a stranded passenger is not moved onto another flight likely
   to be cancelled. The model informs; the stored procedure still enforces.
2. **Proactive alerts.** A scheduled job scores upcoming flights.
3. **API.** `GET /api/flights/{id}/risk`; a `risk` field on `/api/flights/alternatives`.

```
src/kestrel/ml/   data.py  features.py  train.py  evaluate.py  predict.py
notebooks/        exploratory analysis only
models/, data/    gitignored; rebuilt by the pipeline
db/migrations/004_flight_risk.sql
```

New dependencies: pandas, pyarrow, scikit-learn, lightgbm, matplotlib, shap.

## 8. Limitation, stated up front

The model is trained and validated on US flights; Kestrel simulates Kenya
Airways, which publishes no flight-level cancellation data. The features exist
in Kestrel's schema, so the trained model is applied to the simulated network
to demonstrate risk-aware re-accommodation. Its predictions on simulated
flights are illustrative, not validated.

## 9. System-level evaluation

Rebook the disrupted passengers twice on the synthetic data, once with
earliest-flight selection and once with earliest-low-risk selection, and
compare how many land on flights the model rates high-risk. This is a
simulation and is reported as such.

## 10. Timeline

| Sprint | Work |
|---|---|
| 2a | BTS download and cleaning, EDA, leakage audit, time split, baselines |
| 2b | Features; logistic regression, random forest, LightGBM; imbalance; tuning; calibration |
| 3a | Final test evaluation, SHAP, error analysis, model saved |
| 3b | Risk API, migration 004, risk-aware agent tool, simulation, report chapters |

Conflicts with the current Sprint 2 scope (policy RAG, entitlement rules,
Fix 5); the supervisor decides what moves.

## 11. Questions for the supervisor

1. Is US training data with Kenya Airways synthetic demonstration acceptable, framed as in section 8?
2. Does this replace or join the Sprint 2 items?
3. Cancellation only, or the delay-based target as well?
4. Is weather data required or a stretch goal?
5. Which report chapters change: methodology, evaluation, scope?
