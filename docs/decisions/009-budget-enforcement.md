# ADR-009: Budget Enforcement via LiteLLM Teams

**Status:** Accepted

## Context

Each business unit has a different appetite for AI spend. Marketing might be cost-sensitive; engineering might need headroom for large context windows and long coding sessions. We need guardrails on spend.

Options:
- Rate limiting (requests/minute) — doesn't capture cost, a cheap 3-token query is treated same as a 4000-token context
- Token budgets (count tokens directly) — more accurate but complex to implement
- Dollar budgets via LiteLLM's team spend tracking — built-in, accurate, resets on schedule

## Decision

Use **LiteLLM's built-in team budget system**. Each team has a `max_budget` (dollars) and `budget_duration` (reset period). The budget is tracked per-team in Postgres based on actual API costs.

| Tenant | Budget | Type | Duration |
|--------|--------|------|----------|
| Marketing | $200 | Hard cap | 30 days |
| Engineering | $2,000 | Soft cap | 30 days |
| Support | $500 | Hard cap | 30 days |

## Hard vs Soft Caps

**Hard cap:** When the budget is exhausted, all requests from that team are blocked until the budget resets. LiteLLM enforces this automatically.

**Engineering has a soft cap:** Engineering goes over budget, an alert should fire, but requests are not blocked. Engineers in the middle of a critical debugging session or code review should not be cut off. The soft cap is a signal for budget review, not an automatic block.

## Rationale

1. **Built-in, battle-tested.** LiteLLM's spend tracking handles model price lookups, completion token counting, and budget enforcement. Building this from scratch is significant engineering work.

2. **Dollar-denominated budgets are business-friendly.** Finance teams think in dollars, not tokens. Reporting on "we spent $147 in March" is more useful than "we used 2.3M tokens."

3. **Per-team isolation.** A single engineer doing a large code review doesn't consume the marketing budget. Budgets are isolated at the team level, not shared.

## Trade-offs Accepted

- **Postgres dependency.** Budget enforcement requires Postgres. If the database is unavailable, LiteLLM may fail open or closed depending on configuration. Document the failure mode.
- **Budget reset timing.** The 30-day reset is calendar-based, not necessarily aligned with billing cycles. Edge cases around month boundaries should be tested.
- **Price list staleness.** LiteLLM maintains a price list for known models. If OpenAI changes pricing, LiteLLM may undercount spend until the price list is updated.

## Invalidation Signal

If actual cloud spend exceeds the configured budgets by more than 20% (indicating the tracking is inaccurate), investigate and potentially add cloud-side billing alerts as a secondary control.
