# Service Level Objectives (SLO) & Burn Rate Guide

> A comprehensive reference on Site Reliability Engineering (SRE) practices,
> error budget mathematics, and multi-window multi-burn-rate alerting for SmartScale AI.

---

## 1. Fundamentals: SLI vs SLO vs SLA

| Term | Definition | SmartScale AI Target |
|---|---|---|
| **SLI** (Service Level Indicator) | A quantifiable metric of service performance. | Successful message ratio, P99 processing duration. |
| **SLO** (Service Level Objective) | A target reliability level agreed upon internally. | **99.0% availability**, **P99 <= 5.0s**. |
| **SLA** (Service Level Agreement) | A contractual agreement with external penalties. | Typically 95.0% - 98.0% (looser than SLO). |

---

## 2. The Mathematics of Error Budgets

### What is an Error Budget?
An error budget represents the acceptable amount of unreliability over a time period:

$$\text{Error Budget} = 100\% - \text{SLO Target}$$

For SmartScale AI:
- **SLO Target:** $99.0\%$ availability
- **Error Budget:** $1.0\%$ ($0.01$)
- **Measurement Window:** $30\text{ days rolling}$

### Worked Example:
If SmartScale AI processes $1,000,000$ messages over a 30-day window:
- Allowed failures: $1,000,000 \times 0.01 = 10,000\text{ messages}$.
- If $2,500$ messages fail, **$75\%$ of the budget remains**.
- If $10,000$ messages fail, **budget is exhausted ($0\%$ remaining)**.
- If $12,000$ messages fail, **SLO is breached ($-20\%$ budget)**.

---

## 3. Why Traditional Alerting Fails

Traditional threshold alerts (e.g., `error_rate > 1% for 5m`) suffer from two major flaws:

1. **Alert Fatigue / False Alarms:** A 1-minute burst of errors during a brief network hiccup triggers a page, even though it consumed only $0.001\%$ of the monthly budget.
2. **Slow Detection:** An incident causing a $2\%$ error rate will take hours to reach a simplistic $5\%$ threshold, quietly destroying the monthly budget before anyone is notified.

---

## 4. Google SRE Multi-Window Multi-Burn-Rate Model

### What is a Burn Rate?
**Burn rate** is the rate at which your error budget is being consumed relative to the window size:
- **Burn Rate = 1x:** Consumes $100\%$ of the budget in exactly $30\text{ days}$ ($100\% / 30 = 3.33\%/\text{day}$).
- **Burn Rate = 14.4x:** Consumes $2\%$ of the budget in $1\text{ hour}$.
- **Burn Rate = 6.0x:** Consumes $5\%$ of the budget in $6\text{ hours}$.

$$\text{Burn Rate} = \frac{\text{Failure Rate}}{1 - \text{SLO Target}} = \frac{\text{Failed} / \text{Total}}{0.01}$$

### Multi-Window Alerting Rule
To prevent flapping and ensure immediate reset after resolution, alerts check **both** a long window and a short window:

```
Alert Condition = (Long Window Burn Rate > Threshold) AND (Short Window Burn Rate > Threshold)
```

- **Long Window (e.g., 1 hour):** Ensures the error was sustained enough to actually consume significant budget.
- **Short Window (e.g., 5 minutes):** Ensures that as soon as the problem is fixed, the alert ceases firing within 5 minutes (does not stay red for an hour).

---

## 5. SmartScale AI Alerting Matrix

| Alert Name | Long Window | Short Window | Burn Rate | % Budget Consumed | Severity | Action |
|---|---|---|---|---|---|---|
| `KedaDemoSLOAvailabilityFastBurnCritical` | 1 hour | 5 minutes | **14.4x** | 2% | **Critical** | Page on-call immediately (<15m SLA) |
| `KedaDemoSLOAvailabilitySlowBurnWarning` | 6 hours | 30 minutes | **6.0x** | 5% | **Warning** | File ticket, triage within 2 hours |
| `KedaDemoSLOAvailabilitySustainedBurnWarning` | 24 hours | 2 hours | **3.0x** | 10% | **Warning** | Review in next business hours |
| `KedaDemoSLOErrorBudgetExhausted` | 30 days | 5 minutes | **N/A** | 100% | **Critical** | Enforce deployment change freeze |
| `KedaDemoSLOLatencyBudgetBurnWarning` | 1 hour | 5 minutes | **P99 > 5s**| N/A | **Warning** | Investigate CPU throttling/network |

---

## 6. Policy When Budget is Exhausted

When `KedaDemoSLOErrorBudgetExhausted` fires:
1. **Feature Freeze:** All non-critical feature deployments to production are suspended.
2. **Reliability Focus:** Engineering effort shifts 100% to bug fixing, test coverage, and infrastructure resilience.
3. **Deployment Gate:** CI/CD deployment pipelines reject non-hotfix pull requests until the rolling 30-day budget returns to $\ge 99.0\%$.

---

## 7. Operational Runbooks

### Remediating Fast Burn (Critical)
1. **Check Grafana Overview & SLO Dashboard:**
   - URL: `http://localhost:3000/d/smartscale-slo-burn-rate`
   - Observe if burn rate is accelerating.
2. **Isolate Failing Pods:**
   ```bash
   kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --tail=100 | grep ERROR
   ```
3. **Check SQS DLQ Ingestion:**
   ```bash
   kubectl describe scaledobject -n keda-demo
   ```
4. **Rollback if Caused by Recent Release:**
   ```bash
   kubectl rollout undo deployment/keda-demo -n keda-demo
   ```

### Latency SLO Remediation
1. Run micro-benchmark tests:
   ```bash
   cd application && pytest performance_test.py -v
   ```
2. Check pod CPU throttling and resource limits:
   ```bash
   kubectl top pods -n keda-demo
   ```
3. Inspect OpenTelemetry traces in Jaeger:
   - URL: `http://localhost:16686`
   - Filter by spans taking longer than 5.0s.

---

## 8. Importing the Grafana Dashboard

1. Navigate to **Grafana** (`http://localhost:3000`).
2. Click **Dashboards** → **New** → **Import**.
3. Upload `monitoring/dashboards/slo-burn-rate.json`.
4. Select the **Prometheus** data source and click **Import**.
