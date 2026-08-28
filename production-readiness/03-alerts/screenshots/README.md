# Alert evidence screenshots

Captured during the inventory-outage drill (2026-08-28).

| File | What it shows |
|---|---|
| `cloudwatch-checkout-availability-in-alarm.png` | `devops-g3-iac-pr-checkout-availability-degraded` in **In alarm**; `HTTPCode_Target_5XX_Count` spike (~11) during inventory outage |
| `cloudwatch-all-alarms-ok-after-recovery.png` | All four production-readiness alarms **OK** after inventory restored; 5XX spike visible in history |
| `slack-checkout-availability-alarm-ok-resolved.png` | Slack `#group-3-alerts` — `[OK]` resolved notification with WHAT/WHY/WHERE runbook text |

**Drill context:** inventory `desiredCount` set to 0 → checkout probe returned 502 → alarm fired → inventory restored → checkout succeeded → alarm cleared.
