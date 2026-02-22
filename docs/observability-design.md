# Observability Design

How to know what's happening inside the control plane.

---

## What to Observe

### Layer 1 (Deterministic) Events

| Event | Signal | Action |
|-------|--------|--------|
| Secret detected | `SecretsDetector: blocked [pattern_name]` in LiteLLM logs | Investigate: was this accidental or intentional? Notify the team. |
| PII detected (support) | `PIIDetector: hard-blocked for tenant support` | Investigate: what data was the agent trying to share? |
| PII stripped (marketing) | `PIIDetector: stripped for tenant marketing` | Track volume; high rates may indicate workflow issues. |
| Budget exhausted | LiteLLM returns 429 with budget error | Alert the team lead; consider emergency budget extension. |
| Budget >80% used | LiteLLM spend tracking | Proactive alert before hard cap hits. |

### Layer 2 (Semantic) Events

| Event | Signal | Action |
|-------|--------|--------|
| Topic blocked (marketing) | `NemoGuardrailBridge: blocked, rail activated` | Useful data point; high rates may indicate policy is too broad. |
| Off-topic blocked (support) | Same | Track which topics are most often blocked. |
| Jailbreak detected | `self_check_input` fires, rail activated | Alert security; track attempts over time for patterns. |
| NeMo unavailable (fail-open) | `WARNING: NeMo unavailable, fail-open` | **P1 alert.** Page on-call. Check NeMo container health. |
| NeMo slow (>10s) | Latency spike in LiteLLM response time | Check Ollama resource utilization; consider model upgrade or GPU. |

---

## Log Format

Current log output is unstructured (goes to stdout). For production, structure logs as JSON.

Recommended fields for each guardrail event:

```json
{
  "timestamp": "2024-01-15T10:23:45Z",
  "event_type": "guardrail_block",
  "layer": 1,
  "rail": "secrets_detection",
  "tenant": "marketing",
  "pattern_name": "openai_api_key",
  "model_requested": "gpt-4o-mini",
  "action": "blocked",
  "request_id": "req_abc123"
}
```

**Never log:** prompt content, response content, the matched secret value, PII.

---

## Metrics to Track

### Business Metrics
- **Requests per tenant per day** — usage trend, detect adoption or abandonment
- **Spend per tenant per month** — compare against budgets; predict overage
- **Block rate per tenant** — high block rate may indicate policy mismatch or attack

### Security Metrics
- **Secret detection events per week** — trend over time
- **Jailbreak attempt rate** — rising trend may indicate coordinated attack
- **NeMo uptime** — should be >99.9%; fail-open window is a security exposure

### Performance Metrics
- **P50/P95/P99 latency per tenant** — detect NeMo slowness
- **NeMo response time** — Ollama inference latency
- **Database connection pool saturation** — Postgres under LiteLLM load

---

## Alert Runbook

### NeMo Down (P1)

**Trigger:** `WARNING: NeMo unavailable` appears in logs for >3 consecutive requests

**Impact:** Semantic rails are bypassed. Topic control, jailbreak detection, and fact-checking are inactive. Deterministic rails (secrets, PII, budget) still active.

**Response:**
1. `docker compose ps nemo` — check container status
2. `docker compose logs nemo --tail=50` — check for OOM or crash
3. `docker compose restart nemo` — restart if crashed
4. Verify recovery: `curl http://localhost:8000/v1/rails/configs`
5. Verify Ollama is healthy: `curl http://localhost:11434/api/tags`

**Escalation:** If NeMo doesn't recover in 10 minutes, page the platform team.

### Budget Exhausted (P2)

**Trigger:** A tenant receives 429 errors with "budget exceeded" message

**Response:**
1. Confirm which tenant hit the cap
2. Check spend for the month: `GET /team/info?team_id=<id>` with master key
3. Notify team lead with current spend and reset date
4. If legitimate emergency, extend budget via API: `POST /team/update` with increased `max_budget`
5. Document why the cap was hit — was it expected or anomalous?

### High Secret Detection Rate (P2)

**Trigger:** >5 secret detections in 1 hour from a single tenant

**Response:**
1. Identify the pattern type — is it a specific secret type?
2. Reach out to the team lead — is this a workflow issue (employees copy-pasting credentials into prompts)?
3. If anomalous, escalate to security — could indicate key leakage or malicious insider

---

## Current Observability Gaps (To Do)

- [ ] Structured JSON logging for all guardrail events
- [ ] Metrics export to Prometheus (LiteLLM has built-in Prometheus support)
- [ ] Grafana dashboard for spend, block rates, latency
- [ ] PagerDuty integration for NeMo-down alert
- [ ] Slack webhook for budget threshold alerts
- [ ] Distributed tracing (OpenTelemetry) for end-to-end request tracing
