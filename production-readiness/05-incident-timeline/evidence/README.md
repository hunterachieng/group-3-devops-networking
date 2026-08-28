# Incident timeline evidence

**Drill date:** 2026-08-28 (UTC)

| File | Use in timeline |
|---|---|
| `cloudwatch-5xx-spike-during-inventory-outage.png` | T1/T2 - 5xx metric spike + alarm graph |
| `cloudwatch-dashboard-during-recovery.png` | T1–T6 - SLI drop and recovery |
| `cloudwatch-alarms-ok-after-recovery.png` | T6 - alarm cleared, metric near zero |
| `slack-alarm-ok-after-recovery.png` | T2/T6 - Slack notifications to #group-3-alerts |

## Key timestamps (UTC)

| Time | Event |
|---|---|
| ~11:43:00 | T0 - inventory scaled to 0 |
| ~11:43:18 | T1 - first probe 502 |
| 11:46:15 | T2 - alarm ALARM + Slack |
| ~11:46–12:00 | T3/T4 - diagnose + scale inventory to 1 |
| 12:00:15 | T6 - alarm OK + checkout restored |

CLI backup: `../04-runbook/test-evidence/alarm-history.txt`
