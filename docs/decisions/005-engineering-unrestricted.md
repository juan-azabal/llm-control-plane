# ADR-005: Engineering Tenant Has No Topic Control

**Status:** Accepted

## Context

Should engineering be subject to the same topic controls as marketing? Specifically: should engineers be blocked from asking about the product roadmap, financials, or architectural details?

## Decision

**No.** Engineering has no topic control. The engineering NeMo config has only a heuristic jailbreak check, no topic rails.

## Rationale

1. **Restricting engineers causes shadow AI adoption.** If the official AI tool blocks questions that engineers legitimately need answered for technical planning, they'll route around it — using personal accounts, unapproved tools, or manual workarounds. Invisible usage is more dangerous than visible but controlled usage.

2. **Engineers have different information entitlement.** A marketing employee asking "Who heads up the engineering team?" may be a legitimate concern (don't name employees in marketing materials without permission). An engineer asking the same question is probably just looking for a colleague's contact. The risk profile is different.

3. **Topic controls are a social/policy tool, not a technical one.** Engineers understand that LLM outputs are not authoritative. They cross-reference. Marketing may take outputs at face value in customer-facing communications.

4. **Jailbreak detection still applies.** Just because there's no topic control doesn't mean there's no protection. `self_check_input` still runs to catch structural manipulation attempts.

## Trade-offs Accepted

- **Information asymmetry.** Engineers can ask the LLM questions that marketing cannot. This must be communicated clearly in company AI policy.
- **Potential misuse.** A bad actor with an engineering key can ask about anything. Budget monitoring and key rotation are the mitigations.

## Invalidation Signal

A documented case where an engineering team member used the LLM to extract, aggregate, or leak sensitive company information in a way that caused real harm. At that point, add logging and review processes rather than blanket topic blocking.
