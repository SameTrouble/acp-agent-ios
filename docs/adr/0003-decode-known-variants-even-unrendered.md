# ADR-003: Decode known wire variants even when not rendered

**Status**: Accepted.
**Issue**: #6 — iOS 会话视图 (code-review follow-up)
**Date**: 2026-08-06

## Context

Issue #6's spec did not ask for thought bubbles or plan rendering, but both
`agent_thought_chunk` and `plan` are variants opencode's ACP mode really
emits (see ADR-002's table). Code review flagged them as scope creep and
asked: keep or remove?

## Decision

Keep both, with a deliberate decode/render split:

- **`agent_thought_chunk`**: decoded and rendered (purple "Thinking"
  bubbles). Removing it would hide real agent output from users.
- **`plan`**: decoded into `SessionTranscript.planEntries`, deliberately
  not rendered. Nothing reads it yet; it becomes live when an issue asks
  for plan display.

The general rule: **every known wire variant is decoded structurally, even
if nothing renders it; rendering scope is decided by the issue spec.**
Letting a real variant fall through to `.unsupported` is a last resort for
variants we have never observed, not a scope-control tool.

## Consequences

- `planEntries` is temporarily dead state — accepted and intentional, not
  an oversight.
- Future "is this scope creep?" reviews have a written line: decoding a
  real variant is defense, rendering beyond spec is creep.
