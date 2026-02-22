# ADR-006: Block-list vs Allow-list Topic Control

**Status:** Accepted

## Context

For tenants that have topic control (Marketing, Support), there are two fundamental modes:

- **Block-list (deny-list):** Open by default. Specific dangerous topics are blocked. Everything else passes.
- **Allow-list (permit-list):** Closed by default. Only explicitly defined safe topics pass. Everything else is blocked.

## Decision

- **Marketing uses block-list mode.** Block specific dangerous topics (roadmap, financials, employees, source code). All other queries pass.
- **Support uses allow-list mode.** Only product-related queries pass (features, billing, troubleshooting, account management). Everything else is blocked.

## Rationale

The right mode depends on the breadth of the tenant's legitimate use cases and the consequence of a miss.

**Marketing needs broad LLM usage.** Copywriting, market research, competitive analysis, email drafting, persona development — the range is wide. A block-list is appropriate because the dangerous topics are known and narrow (internal company data). If we used an allow-list, we'd need to enumerate all legitimate marketing tasks, which is impossible.

**Support's scope is narrow and well-defined.** The support bot handles product questions. Full stop. An off-topic response (e.g., helping a customer write a cover letter) creates:
- Brand inconsistency ("this isn't what our support bot is for")
- Liability (if the advice is wrong)
- Scope creep (why does support have a general assistant?)

With a narrow, defined scope, allow-list is more appropriate. The cost of a false positive (blocking a legitimate product question) is low — the customer asks again more specifically.

## Trade-offs Accepted

**Block-list (Marketing):**
- New dangerous topics that we didn't enumerate are not blocked. The list must be maintained.
- Semantic miss: "What's the timeline?" is ambiguous — roadmap or project? May be incorrectly blocked or passed.

**Allow-list (Support):**
- Legitimate product questions with unusual phrasing may be blocked. Support agents may need to rephrase.
- The allow-list must be kept current as the product evolves.

## Invalidation Signal

If Marketing is frequently complaining about blocked queries that are legitimate, or if Support is frequently helping with off-topic requests that should be blocked, re-evaluate the mode or the specific topic definitions.
