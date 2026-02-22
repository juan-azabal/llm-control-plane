# ADR-008: Per-Tenant PII Handling Policy

**Status:** Accepted

## Context

Employees will sometimes include PII (email addresses, phone numbers, SSNs) in their LLM prompts. Should we block, strip, or allow this? And should the behavior differ by tenant?

## Decision

PII handling is **per-tenant**, implemented in `custom_guardrails/pii_detector.py`:

| Tenant | Policy | Behavior |
|--------|--------|----------|
| Marketing | Strip silently | PII redacted before reaching cloud LLM. Request continues. |
| Engineering | Warn | PII logged as a warning. Request continues unmodified. |
| Support | Block hard | Request rejected with an error. Customer PII must not leave the perimeter. |

## Rationale

**Marketing — strip silently:** Marketers may legitimately include example customer emails in persona-building prompts ("Draft a message from the perspective of john@example.com"). Blocking this entirely is too restrictive. Stripping the PII before it reaches OpenAI preserves privacy while allowing the request to proceed.

**Engineering — warn and allow:** Developers need full stack traces, database query samples, and log snippets in their prompts for debugging. These often contain email addresses or user IDs. Blocking or stripping would break their workflow. We log the incident for audit purposes but don't interfere. Engineers are expected to understand that submitting PII to external services is their responsibility.

**Support — block hard:** Customer data is the most sensitive category. Support agents must never send a customer's PII to a cloud LLM. The risk of a GDPR violation or data breach far outweighs the convenience. The correct workflow is to anonymize before querying.

## Trade-offs Accepted

- **Regex-based detection.** PII detection uses regular expressions, which have false positives (not every `xxx-xx-xxxx` pattern is a SSN) and false negatives (non-standard formats bypass). A proper DLP tool (Google Cloud DLP, AWS Macie) is more accurate.
- **Stripping changes semantics.** When marketing's PII is stripped, the prompt semantics change. The LLM might produce a less relevant response. This is accepted as the cost of privacy.
- **Engineering alert fatigue.** If engineering generates many PII warnings, the signals become noise. Need monitoring to track trends.

## Invalidation Signal

A data breach or regulatory audit finding that traces back to PII in LLM prompts that our detection missed. At that point, replace regex-based detection with a dedicated DLP API.
