# Architecture Decision Records (ADRs)

This directory documents the key architectural and design decisions made throughout the lifecycle of the **SmartScale AI (AWS KEDA EKS Autoscaling)** project.

---

## What is an Architecture Decision Record?

An Architecture Decision Record (ADR) is a lightweight document capturing an important architectural decision, along with its context, considered options, evaluation criteria, and consequences.

ADRs preserve institutional knowledge, explain *why* systems are designed the way they are, and prevent re-debating settled decisions without new context.

---

## ADR Index

| ADR | Title | Status | Date | Decision Summary |
|---|---|---|---|---|
| [**0001**](0001-keda-event-driven-autoscaling.md) | Adoption of KEDA for Event-Driven Autoscaling | Accepted | 2026-10-13 | Replaced standard CPU/Mem HPA with KEDA to enable direct SQS backlog tracking and true scale-to-zero. |
| [**0002**](0002-arima-predictive-scaling.md) | Predictive Autoscaling Strategy: ARIMA vs Pure Reactive | Accepted | 2026-10-13 | Adopted ARIMA(1,1,1) time-series forecasting with automated confidence fallback to eliminate pod startup latency spikes. |
| [**0003**](0003-htmx-dashboard-architecture.md) | HTMX-Driven Real-Time Dashboard over SPA Frameworks | Accepted | 2026-10-13 | Selected server-rendered HTML with HTMX partial swapping over React/SPAs to eliminate Node.js build dependencies. |

---

## ADR Lifecycle & Template

When proposing a new architectural change, use the following structure:

```markdown
# ADR [NUMBER]: [TITLE]

* **Status:** [Proposed | Accepted | Deprecated | Superseded]
* **Date:** YYYY-MM-DD
* **Deciders:** [Team / Names]
* **Consulted:** [Stakeholders]

## 1. Context & Problem Statement
[What problem are we trying to solve? What are the constraints?]

## 2. Decision Drivers
[What business or technical requirements guide the choice?]

## 3. Considered Options
[List of viable alternatives]

## 4. Evaluation of Options
[Pros and cons for each option]

## 5. Decision Outcome
[Which option was selected and why?]

## 6. Consequences & Operational Mitigations
[Positive and negative impacts, plus how risks are mitigated]
```
