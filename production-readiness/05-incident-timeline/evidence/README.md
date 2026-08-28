# Incident timeline evidence

Supporting captures for the inventory-outage drill (2026-08-28). Use with probe log timestamps from the operator terminal.

| File | Timeline use |
|---|---|
| `cloudwatch-5xx-spike-during-inventory-outage.png` | T1/T2 — metric signal and alarm in **In alarm** (~12:00 UTC) |
| `slack-alarm-ok-after-recovery.png` | T6 — Slack shows alarm **resolved** after recovery (~12:00:15 UTC) |
| `cloudwatch-alarms-ok-after-recovery.png` | T6 — all alarms back to **OK** |
| `cloudwatch-dashboard-during-recovery.png` | Full dashboard — 5xx spike, 0% availability, recovery to 100% (~11:40–12:05 UTC) |

**Suggested timestamps (UTC, from operator session):**

- T0 ~11:43 — inventory scaled to 0
- T1 ~11:43:18 — first probe `http=502`
- T2 ~11:46:16 — Lambda invoked (Slack ALARM; check Slack history if captured separately)
- T6 ~12:00:15 — Slack `[OK]` + successful checkout validation
