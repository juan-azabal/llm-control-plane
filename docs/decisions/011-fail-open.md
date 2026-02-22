# ADR-011: Fail Open When Semantic Rails Are Unavailable

**Status:** Accepted

## Context

When NeMo Guardrails is unavailable (container crash, network partition, slow restart), what should happen to in-flight requests?

Options:
- **Fail closed:** Block all requests until NeMo recovers. Maximum safety, maximum disruption.
- **Fail open:** Allow requests to pass through. Some semantic protection is lost; deterministic protection remains.
- **Fail partially:** Block for high-risk tenants (Support), allow for low-risk (Engineering).

## Decision

**Fail open.** When NeMo is unavailable, `nemo_bridge.py` catches the connection error and returns `None` from `async_pre_call_hook`, allowing the request to continue. An alert should fire immediately. Deterministic rails (secrets, PII, budget) remain active.

## Rationale

1. **Deterministic rails are the primary defense.** Secrets detection and PII blocking run in `secrets_detector.py` and `pii_detector.py`, which are independent of NeMo. These run for every request regardless of NeMo status. The deterministic rails catch the highest-severity, most clear-cut violations.

2. **Semantic rails are probabilistic.** NeMo with a 3B model will have false negatives on novel jailbreaks even when running normally. The incremental risk of NeMo being down for minutes vs. running with imperfect accuracy is smaller than it appears.

3. **Availability matters for business adoption.** If a brief NeMo restart (30 seconds) blocks all marketing and support employees from using AI tools, the trust in the platform erodes. Teams will find workarounds. An observable, alerting fail-open is better than an opaque fail-closed that frustrates users and causes them to circumvent controls.

4. **The outage is observable.** The `nemo_bridge.py` logs a warning for every request that passes through without NeMo validation. These logs flow to the observability stack. A meaningful NeMo outage generates a high-volume alert signal.

## The Alert Requirement

Fail-open without alerting would be unacceptable. The design requires:
- Log `WARNING: NeMo unavailable, fail-open for tenant <X>` for every affected request
- Alert PagerDuty / Slack within 60 seconds of NeMo becoming unreachable
- Auto-resolve when NeMo recovers

(Alert integration is out of scope for this demo but documented in `docs/observability-design.md`.)

## Trade-offs Accepted

- **Window of exposure.** During NeMo downtime, Marketing can ask about the roadmap, Support can go off-topic. This is a real risk. The bet is that outages are short (seconds to minutes) and the alert escalation kicks in quickly.
- **Operator trust required.** This design assumes operators will respond to the NeMo-down alert quickly. If on-call response time is measured in hours, reconsider fail-closed for Support.

## Invalidation Signal

A security incident during a NeMo outage where semantic rail bypass caused real harm that the deterministic rails would not have caught. At that point, implement fail-closed for Support (the highest-risk tenant) while keeping fail-open for Marketing and Engineering.
