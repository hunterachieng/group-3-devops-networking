# Incident timeline evidence

**Drill date:** 2026-08-28 (UTC)

Each capture exists in **two versions** from the same drill — Hunter's session captures (`*-hunter.png`) and the team's submission captures (`*-team.png`). Both are valid evidence.

| Base name | Hunter capture | Team capture | Use in timeline |
|---|---|---|---|
| 5xx spike | `cloudwatch-5xx-spike-during-inventory-outage-hunter.png` | `cloudwatch-5xx-spike-during-inventory-outage-team.png` | T1/T2 — 5xx metric + alarm |
| Dashboard | `cloudwatch-dashboard-during-recovery-hunter.png` | `cloudwatch-dashboard-during-recovery-team.png` | T1–T6 — SLI drop and recovery |
| Alarms OK | `cloudwatch-alarms-ok-after-recovery-hunter.png` | `cloudwatch-alarms-ok-after-recovery-team.png` | T6 — alarm cleared |
| Slack | `slack-alarm-ok-after-recovery-hunter.png` | `slack-alarm-ok-after-recovery-team.png` | T2/T6 — `#group-3-alerts` |

## Key timestamps (UTC)

| Time | Event |
|---|---|
| ~11:43:00 | T0 — inventory scaled to 0 |
| ~11:43:18 | T1 — first probe 502 |
| 11:46:15 | T2 — alarm ALARM + Slack |
| ~11:46–12:00 | T3/T4 — diagnose + scale inventory to 1 |
| 12:00:15 | T6 — alarm OK + checkout restored |

CLI backup: [alarm-history.txt](../../04-runbook/test-evidence/alarm-history.txt)
