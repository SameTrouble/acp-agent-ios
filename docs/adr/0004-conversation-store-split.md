# ADR-004: Extract ConversationStore; ACPClient stays the only view seam

**Status**: Accepted.
**Issue**: #6 — iOS 会话视图 (code-review follow-up)
**Date**: 2026-08-06

## Context

Code review flagged divergent change in `ACPClient`: it mixes connection
lifecycle + credentials, the session list, and per-session conversation
state. Issue #7 (approval cards) is about to add more conversation state
and RPC actions to exactly that third area.

## Decision

Extract a `ConversationStore` now — before #7 lands — that owns the
`conversations` map and the conversation actions (resume, send, cancel;
approve/reject later). `ACPClient` keeps connection lifecycle,
credentials, and the session list, and delegates conversation work to
the store.

Hard constraint: **`ACPClient` remains the sole `@EnvironmentObject`
seam** from ADR-001. Views do not see `ConversationStore` directly;
ADR-001 continues to hold unchanged.

## Considered Options

- *Split during #7*: rejected — mixes a refactor diff with a feature
  diff, burdening review and TDD seam agreement on one ticket.
- *Don't split*: rejected — #8/#9 also grow the conversation area; the
  divergence compounds.

## Consequences

- Naming deliberately avoids `SessionConversationController` — too close
  to the `SessionConversation` struct. See `CONTEXT.md`.
- #7's approval state and actions go straight into `ConversationStore`.
